// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Nowcast.swift - the HRRR 15-minute nowcast of the blend: the usable run of
// open-meteo:hrrr15, the hourly sums that override open-meteo:hrrr's
// precipitation, and the rescaled forecast quarters. Port of find_nowcast,
// nowcast_hour_sums and build_quarters (src/blend/wx-blend.c:323-530,
// contract src/blend/wx-blend.h:125-148).
//
// Bit-for-bit with the C code (do not "simplify"): the sums are
// ((q0 + q1) + q2) + q3; ratio = blended / raw is computed once; the three
// smaller quarters are rescaled and accumulated in index order; the largest
// one (the FIRST largest, strict >) takes the remainder; every quarter is then
// clamped with the GLib CLAMP ternary into [0, MIN(blended, 500)]. fmin/fmax
// are the C functions' semantics (NaN-ignoring, -0 below +0).

/// The HRRR 15-minute nowcast of the blend (wx-blend.c:323-530).
enum WxNowcast {
    /// QUARTER_S and HOUR_S (wx-blend.c:14-15).
    static let quarterS: Int64 = 900
    static let hourS: Int64 = 3600
    /// NOWCAST_MIN_RAW_MM (wx-blend.c:23): below this blended amount or raw
    /// sum the blended amount is spread evenly.
    static let minRawMm = 1e-9

    /// The usable run of 15-minute quarters of open-meteo:hrrr15 (Nowcast,
    /// wx-blend.c:328-333).
    struct Run {
        /// All quarters of the member.
        let quarters: [WxQuarter]
        /// Index of the quarter containing now.
        let first: Int
        /// Quarters kept for the forecast, at most `WxBlend.maxQuarters`.
        let count: Int
    }

    /// quarter_is_ok (wx-blend.c:348-352): finite within [0, precipMaxMmH].
    static func quarterIsOK(_ quarter: WxQuarter) -> Bool {
        WxLimits.valueInRange(quarter.precipMm, 0.0, WxLimits.precipMaxMmH)
    }

    /// find_nowcast (wx-blend.c:373-408): the first member open-meteo:hrrr15
    /// of `members` (the blend's taking-part members, in order) with 1 to
    /// `memberMaxQuarters` quarters that are ALL strictly ascending multiples
    /// of 900 within the time range, and an unbroken run of valid quarters
    /// that starts with the quarter containing `nowS` and ends at or after
    /// `nowS` + 1800. nil otherwise. `nowS` is within the time range.
    static func find(_ members: [WxMember], nowS: Int64) -> Run? {
        guard let m = members.first(where: { WxBlend.isMember($0, "open-meteo", "hrrr15") }) else {
            return nil
        }
        let qs = m.quarters
        if qs.isEmpty || qs.count > WxLimits.memberMaxQuarters {
            return nil
        }
        for i in qs.indices {
            let t = qs[i].tS
            if t < WxLimits.timeMinS || t >= WxLimits.timeMaxS || t % quarterS != 0
                || (i > 0 && t <= qs[i - 1].tS)
            {
                return nil
            }
        }

        let q0 = nowS - nowS % quarterS
        var first = 0
        while first < qs.count && qs[first].tS != q0 {
            first += 1
        }
        var run = 0
        while first + run < qs.count && qs[first + run].tS == q0 + Int64(run) * quarterS
            && quarterIsOK(qs[first + run])
        {
            run += 1
        }
        if run == 0 || q0 + Int64(run) * quarterS < nowS + 1800 {
            return nil
        }
        // MIN(run, WX_BLEND_MAX_QUARTERS)
        return Run(quarters: qs, first: first, count: run < WxBlend.maxQuarters ? run : WxBlend.maxQuarters)
    }

    /// nowcast_hour_sums (wx-blend.c:426-445): for bucket i (starting at
    /// `startS` + i * 3600) the sum ((q0 + q1) + q2) + q3 of four valid
    /// quarters of the member (ALL its quarters, not only the run) that start
    /// on that hour, when the sum is within [0, precipMaxMmH]; NaN otherwise.
    static func hourSums(_ run: Run, startS: Int64, buckets: Int) -> [Double] {
        var sums = [Double](repeating: .nan, count: buckets)
        let q = run.quarters
        var j = 0
        while j + 3 < q.count {
            defer { j += 1 }
            let t = q[j].tS
            // strictly ascending multiples of 900: the last one 2700 s later means all four
            if t % hourS != 0 || t < startS || q[j + 3].tS != t + 3 * quarterS {
                continue
            }
            if !quarterIsOK(q[j]) || !quarterIsOK(q[j + 1]) || !quarterIsOK(q[j + 2]) || !quarterIsOK(q[j + 3]) {
                continue
            }
            let bucket = (t - startS) / hourS
            let sum = ((q[j].precipMm + q[j + 1].precipMm) + q[j + 2].precipMm) + q[j + 3].precipMm
            if UInt64(bitPattern: bucket) < UInt64(buckets)
                && WxLimits.valueInRange(sum, 0.0, WxLimits.precipMaxMmH)
            {
                sums[Int(bucket)] = sum
            }
        }
        return sums
    }

    /// build_quarters (wx-blend.c:489-530): the run's quarters, with every
    /// hour that starts on the hour, is covered by four of them and has a
    /// finite blended precipMm rescaled to sum to that amount (see the
    /// header comment of this file and wx-blend.c:461-485). `hours` are the
    /// blended buckets (before WxForecast's normalisation), bucket 0 at
    /// `startS`.
    static func buildQuarters(_ run: Run, hours: [WxBlendHour], startS: Int64) -> [WxQuarter] {
        var out = Array(run.quarters[run.first..<(run.first + run.count)])

        var j = 0
        while j + 3 < run.count {
            defer { j += 1 }
            let t = out[j].tS
            if t % hourS != 0 {
                continue
            }
            // checked, never asserted (wx-blend.c:500-504)
            let bucket = (t - startS) / hourS
            if UInt64(bitPattern: bucket) >= UInt64(hours.count) || !hours[Int(bucket)].precipMm.isFinite {
                continue
            }
            let blended = hours[Int(bucket)].precipMm
            let cap = cFmin(blended, WxLimits.precipMaxMmH)
            let raw = ((out[j].precipMm + out[j + 1].precipMm) + out[j + 2].precipMm) + out[j + 3].precipMm
            let even = blended < minRawMm || raw < minRawMm
            var big = 0
            for k in 1..<4 where out[j + k].precipMm > out[j + big].precipMm {
                big = k
            }
            let ratio = even ? 0.0 : blended / raw
            var rest = 0.0
            for k in 0..<4 {
                if k == big {
                    continue
                }
                out[j + k].precipMm = even ? blended / 4.0 : cFmin(out[j + k].precipMm * ratio, blended)
                rest += out[j + k].precipMm
            }
            out[j + big].precipMm = even ? blended / 4.0 : cFmax(0.0, blended - rest)
            for k in 0..<4 {
                // CLAMP(x, 0.0, cap): the GLib ternary
                let x = out[j + k].precipMm
                out[j + k].precipMm = x > cap ? cap : (x < 0.0 ? 0.0 : x)
            }
            j += 3
        }
        return out
    }

    /// C fmin on this platform: a NaN operand gives the other one; -0 is
    /// below +0.
    static func cFmin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN {
            return b
        }
        if b.isNaN || a < b {
            return a
        }
        if b < a {
            return b
        }
        return a.sign == .minus ? a : b
    }

    /// C fmax on this platform: a NaN operand gives the other one; +0 is
    /// above -0.
    static func cFmax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN {
            return b
        }
        if b.isNaN || a > b {
            return a
        }
        if b > a {
            return b
        }
        return a.sign == .plus ? a : b
    }
}
