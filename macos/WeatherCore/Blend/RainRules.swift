// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RainRules.swift - the rain outlook: "raining now / rain expected / rain
// possible / dry" with start, end and peak, from a blended forecast. Port of
// src/blend/wx-rain.{h,c}. Pure: no global state, no locale or time-zone use.

/// The rain outlook (wx_rain_outlook, src/blend/wx-rain.h:30-82).
public enum WxRainRules {
    /// The outlook looks at the next 48 hours, in seconds (WX_RAIN_HORIZON_S).
    public static let horizonS: Int64 = 172_800
    /// Nowcast quarters are used for the first 2 hours, in seconds (WX_RAIN_QUARTER_SPAN_S).
    public static let quarterSpanS: Int64 = 7_200
    /// Precipitation (mm per 15 minutes) from which a quarter counts as wet (WX_RAIN_WET_QUARTER_MM).
    public static let wetQuarterMm = 0.05
    /// Hourly precipProb (percent) from which "rain possible" is reported (WX_RAIN_POSSIBLE_PROB_PCT).
    public static let possibleProbPct = 40.0

    /// wx_rain_outlook for a forecast (whose initialiser already guarantees
    /// the usable shape). `nowS` outside [timeMinS, timeMaxS) gives the DRY
    /// outlook (the C critical path).
    public static func outlook(_ forecast: WxForecast, nowS: Int64) -> WxRainOutlook {
        outlook(hours: forecast.hours, quarters: forecast.quarters, nowS: nowS)
    }

    /// wx_rain_outlook for hand-built arrays. A forecast that is not USABLE
    /// (more than `WxLimits.forecastMaxHours` hours or
    /// `WxLimits.forecastMaxQuarters` quarters; hours not strictly ascending
    /// multiples of 3600, or quarters not strictly ascending multiples of 900,
    /// within [timeMinS, timeMaxS); a quarter amount not finite within
    /// [0, precipMaxMmH]) or `nowS` outside the time range gives the DRY
    /// outlook, as C does after its critical.
    public static func outlook(hours: [WxBlendHour], quarters: [WxQuarter], nowS: Int64) -> WxRainOutlook {
        var out = WxRainOutlook()  // { .state = WX_RAIN_DRY }, every other field 0
        guard nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
            return out
        }
        guard isUsable(hours, quarters) else {
            return out
        }

        let samples = buildSamples(hours, quarters, nowS)
        let n = samples.count

        // the sample covering now, if any, and the first wet sample from now on
        var cover = n
        var nextWet = n
        for i in 0..<n {
            if samples[i].start <= nowS && nowS < samples[i].end {
                cover = i
            }
            if nextWet == n && samples[i].wet && samples[i].start >= nowS {
                nextWet = i
            }
        }

        if cover < n && samples[cover].wet {
            var first = cover
            while first > 0 && samples[first - 1].wet && samples[first - 1].end == samples[first].start {
                first -= 1
            }
            out.state = .now
            describeRun(samples, first, runEnd(samples, cover), &out)
        } else if nextWet < n {
            out.state = .expected
            describeRun(samples, nextWet, runEnd(samples, nextWet), &out)
        } else {
            possibleRain(hours, nowS, &out)
        }
        return out
    }

    // MARK: - Private

    private static let hourS: Int64 = 3_600
    private static let quarterS: Int64 = 900
    /// MAX_SAMPLES (wx-rain.c:27): the hours plus the quarters of the first 2
    /// hours, with slack; never reached for a usable forecast.
    private static let maxSamples = WxLimits.forecastMaxHours + 2 + 9

    /// One span of the time line: [start, end) with a rate in mm per hour.
    private struct Sample {
        var start: Int64
        var end: Int64
        /// NaN when unknown.
        var mmH: Double
        /// NaN for quarters and unknown probabilities.
        var prob: Double
        var wet: Bool
    }

    /// forecast_is_usable (wx-rain.c:48-70); the counts are checked before any element.
    private static func isUsable(_ hours: [WxBlendHour], _ quarters: [WxQuarter]) -> Bool {
        if hours.count > WxLimits.forecastMaxHours || quarters.count > WxLimits.forecastMaxQuarters {
            return false
        }
        for i in hours.indices {
            let t = hours[i].tS
            if t < WxLimits.timeMinS || t >= WxLimits.timeMaxS || t % hourS != 0 || (i > 0 && t <= hours[i - 1].tS) {
                return false
            }
        }
        for i in quarters.indices {
            let t = quarters[i].tS
            if t < WxLimits.timeMinS || t >= WxLimits.timeMaxS || t % quarterS != 0
                || (i > 0 && t <= quarters[i - 1].tS)
                || !WxLimits.valueInRange(quarters[i].precipMm, 0.0, WxLimits.precipMaxMmH)
            {
                return false
            }
        }
        return true
    }

    /// add_hours (wx-rain.c:95-112): one sample per hour clipped to [lo, hi),
    /// dropped when empty or starting at or after `horizonEnd`.
    private static func addHours(
        _ hours: [WxBlendHour], lo: Int64, hi: Int64, horizonEnd: Int64, _ samples: inout [Sample]
    ) {
        for h in hours {
            if samples.count >= maxSamples {
                break
            }
            let start = max(h.tS, lo)
            let end = min(h.tS + hourS, hi)
            if start >= end || start >= horizonEnd {
                continue
            }
            samples.append(
                Sample(
                    start: start, end: end, mmH: h.precipMm, prob: h.precipProb,
                    wet: WxConditionRules.isWetHour(precipMm: h.precipMm, precipProb: h.precipProb)))
        }
    }

    /// build_samples (wx-rain.c:132-168).
    private static func buildSamples(_ hours: [WxBlendHour], _ quarters: [WxQuarter], _ nowS: Int64) -> [Sample] {
        let horizonEnd = nowS + horizonS
        let q0 = nowS - nowS % quarterS
        var samples: [Sample] = []
        samples.reserveCapacity(min(hours.count + 12, maxSamples))

        // the contiguous quarters that start with the one containing now and begin before now + 2 h
        var first = 0
        var count = 0
        while first < quarters.count && quarters[first].tS != q0 {
            first += 1
        }
        while first + count < quarters.count && quarters[first + count].tS == q0 + Int64(count) * quarterS
            && quarters[first + count].tS < nowS + quarterSpanS
        {
            count += 1
        }

        if count == 0 {
            addHours(hours, lo: Int64.min, hi: Int64.max, horizonEnd: horizonEnd, &samples)
            return samples
        }

        let spanEnd = q0 + Int64(count) * quarterS
        addHours(hours, lo: Int64.min, hi: q0, horizonEnd: horizonEnd, &samples)
        for i in 0..<count where samples.count < maxSamples {
            let q = quarters[first + i]
            samples.append(
                Sample(
                    start: q.tS, end: q.tS + quarterS, mmH: q.precipMm * 4.0, prob: .nan,
                    wet: q.precipMm >= wetQuarterMm))
        }
        addHours(hours, lo: spanEnd, hi: Int64.max, horizonEnd: horizonEnd, &samples)
        return samples
    }

    /// run_end (wx-rain.c:186-192): the last sample of the contiguous wet run from `first`.
    private static func runEnd(_ samples: [Sample], _ first: Int) -> Int {
        var last = first
        while last + 1 < samples.count && samples[last + 1].wet && samples[last + 1].start == samples[last].end {
            last += 1
        }
        return last
    }

    /// C fmax (wx-rain.c:222): the other operand when one is NaN; +0 over -0.
    private static func cFmax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN {
            return b
        }
        if b.isNaN {
            return a
        }
        if a == b {
            return a.sign == .minus ? b : a
        }
        return a > b ? a : b
    }

    /// describe_run (wx-rain.c:209-226).
    private static func describeRun(_ samples: [Sample], _ first: Int, _ last: Int, _ out: inout WxRainOutlook) {
        out.startS = samples[first].start
        // known only if a dry sample directly follows the run
        out.endsKnown = last + 1 < samples.count && samples[last + 1].start == samples[last].end
        out.endS = out.endsKnown ? samples[last].end : 0
        out.peakMmH = -1.0
        out.peakS = samples[first].start
        out.peakProb = .nan
        for i in first...last {
            if samples[i].mmH > out.peakMmH {
                out.peakMmH = samples[i].mmH
                out.peakS = samples[i].start
            }
            out.peakProb = cFmax(out.peakProb, samples[i].prob)
        }
    }

    /// possible_rain (wx-rain.c:243-262): the first hour with the highest
    /// precipProb >= 40 among those that end after now and start before the horizon.
    private static func possibleRain(_ hours: [WxBlendHour], _ nowS: Int64, _ out: inout WxRainOutlook) {
        var best: WxBlendHour?
        for h in hours {
            if h.tS + hourS <= nowS || h.tS >= nowS + horizonS {
                continue
            }
            if h.precipProb >= possibleProbPct && (best == nil || h.precipProb > best!.precipProb) {
                best = h
            }
        }
        guard let best else {
            return
        }
        out.state = .possible
        out.peakS = best.tS
        out.peakProb = best.precipProb
        out.peakMmH = best.precipMm.isFinite ? best.precipMm : 0.0
    }
}
