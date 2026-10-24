// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RainRulesTests.swift - port of the /blend/rain/* cases of
// src/blend/test-blend.c (registered at src/blend/test-blend.c:5537-5548).
// Expected values are the C test literals, cited as test-blend.c:LINE.
// The fuzz cases keep their oracles (ref_outlook, the invariants) with
// SeededRNG instead of GLib's GRand.

import Testing
@testable import WeatherCore

@Suite struct RainRulesTests {
    /// 2026-10-11T00:00:00Z (T0, test-blend.c:26).
    static let t0: Int64 = 1_791_676_800
    static let h: Int64 = 3600
    /// 2026-10-11T12:37:00Z (NOW_S, test-blend.c:29).
    static let nowS: Int64 = t0 + 12 * h + 37 * 60
    /// Rain forecasts have the hours 11:00 .. 70:00 (RFIRST, RN, test-blend.c:2429-2430).
    static let rFirst = 11
    static let rN = 60

    /// bh (test-blend.c:2238-2258).
    static func bh(
        _ t: Int64, _ temp: Double, _ precip: Double, _ prob: Double, _ cloud: Double, _ cond: WxCondition,
        _ isDay: Bool, _ members: UInt8
    ) -> WxBlendHour {
        WxBlendHour(
            tS: t, tempC: temp, feelsC: temp, precipMm: precip, precipMmMax: precip, precipProb: prob,
            cloudPct: cloud, nMembers: members, condition: cond, isDay: isDay)
    }

    /// rain_hours (test-blend.c:2433-2439): dry with a 10 % chance.
    static func rainHours() -> [WxBlendHour] {
        (0..<rN).map { bh(t0 + Int64(rFirst + $0) * h, 20, 0.0, 10, 50, .partlyCloudy, true, 1) }
    }

    /// set_wet (test-blend.c:2443-2449): makes the hours [from, to) wet.
    static func setWet(_ a: inout [WxBlendHour], _ from: Int, _ to: Int, _ mm: Double, _ prob: Double) {
        for hour in from..<to {
            a[hour - rFirst].precipMm = mm
            a[hour - rFirst].precipProb = prob
        }
    }

    /// outlook_of (test-blend.c:2452-2460): through wx_forecast_new, as C's make_forecast.
    static func outlookOf(_ hours: [WxBlendHour], _ q: [WxQuarter] = [], _ now: Int64 = nowS) throws -> WxRainOutlook {
        let place = try WxPlace(
            name: "Testville", admin1: "Region", country: "Country", countryCode: "US", lat: 51.5074,
            lon: -0.1278, timezone: "Europe/London")
        let fc = try WxForecast(place: place, generatedS: nowS, hours: hours, quarters: q)
        return WxRainRules.outlook(fc, nowS: now)
    }

    /// assert_outlook (test-blend.c:2463-2476), ASSERT_NEAR's 1e-9.
    static func expectOutlook(
        _ o: WxRainOutlook, _ state: WxRainState, _ start: Int64, _ end: Int64, _ known: Bool, _ peakS: Int64,
        _ peakMm: Double, _ peakProb: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(o.state == state, sourceLocation: sourceLocation)
        #expect(o.startS == start, sourceLocation: sourceLocation)
        #expect(o.endS == end, sourceLocation: sourceLocation)
        #expect(o.endsKnown == known, sourceLocation: sourceLocation)
        #expect(o.peakS == peakS, sourceLocation: sourceLocation)
        expectNear(o.peakMmH, peakMm, eps: 1e-9, sourceLocation: sourceLocation)
        if peakProb.isNaN {
            expectNaN(o.peakProb, sourceLocation: sourceLocation)
        } else {
            expectNear(o.peakProb, peakProb, eps: 1e-9, sourceLocation: sourceLocation)
        }
    }

    /// assert_dry (test-blend.c:2479-2482).
    static func expectDry(_ o: WxRainOutlook, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(o.state == .dry, comment, sourceLocation: sourceLocation)
        expectOutlook(o, .dry, 0, 0, false, 0, 0.0, 0.0, sourceLocation: sourceLocation)
    }

    /// quarters_from (test-blend.c:2715-2721).
    static func quartersFrom(_ first: Int64, _ amounts: [Double], _ n: Int) -> [WxQuarter] {
        (0..<n).map { WxQuarter(tS: first + Int64($0) * 900, precipMm: amounts[$0]) }
    }

    // C: /blend/rain/dry-possible (test-blend.c:2485-2535)
    @Test("/blend/rain/dry-possible") func dryAndPossible() throws {
        let t0 = Self.t0, h = Self.h
        var a = Self.rainHours()
        Self.expectDry(try Self.outlookOf(a))
        // 39.99 % is not enough, 40 % is (test-blend.c:2491-2497)
        a[20 - 11].precipProb = 39.99
        Self.expectDry(try Self.outlookOf(a))
        a[20 - 11].precipProb = 40.0
        Self.expectOutlook(try Self.outlookOf(a), .possible, 0, 0, false, t0 + 20 * h, 0.0, 40.0)
        // the highest probability, the first of equal ones; its own precipitation (test-blend.c:2499-2505)
        a[20 - 11].precipProb = 45.0
        a[22 - 11].precipProb = 60.0
        a[22 - 11].precipMm = 0.05
        a[23 - 11].precipProb = 60.0
        Self.expectOutlook(try Self.outlookOf(a), .possible, 0, 0, false, t0 + 22 * h, 0.05, 60.0)
        // an unknown amount is reported as 0 (test-blend.c:2506-2508)
        a[22 - 11].precipMm = .nan
        Self.expectOutlook(try Self.outlookOf(a), .possible, 0, 0, false, t0 + 22 * h, 0.0, 60.0)
        // unknown probabilities never qualify (test-blend.c:2509-2514)
        var b = Self.rainHours()
        for i in b.indices {
            b[i].precipProb = .nan
        }
        Self.expectDry(try Self.outlookOf(b))
        // only hours that end after now and start before now + 48 h count (test-blend.c:2516-2534)
        var c = Self.rainHours()
        c[11 - 11].precipProb = 90
        Self.expectDry(try Self.outlookOf(c))
        c[12 - 11].precipProb = 90
        Self.expectOutlook(try Self.outlookOf(c), .possible, 0, 0, false, t0 + 12 * h, 0.0, 90.0)
        var d = Self.rainHours()
        d[61 - 11].precipProb = 90
        Self.expectDry(try Self.outlookOf(d))
        d[60 - 11].precipProb = 90
        Self.expectOutlook(try Self.outlookOf(d), .possible, 0, 0, false, t0 + 60 * h, 0.0, 90.0)
        Self.expectDry(try Self.outlookOf(d, [], t0 + 12 * h))  // test-blend.c:2533-2534
    }

    // C: /blend/rain/now (test-blend.c:2538-2584)
    @Test("/blend/rain/now") func rainNow() throws {
        let t0 = Self.t0, h = Self.h
        var a = Self.rainHours()
        Self.setWet(&a, 11, 14, 0.5, 60)
        a[12 - 11].precipProb = 70
        a[13 - 11].precipMm = 1.2
        // test-blend.c:2545-2546
        Self.expectOutlook(try Self.outlookOf(a), .now, t0 + 11 * h, t0 + 14 * h, true, t0 + 13 * h, 1.2, 70.0)
        var b = Self.rainHours()
        Self.setWet(&b, 12, 13, 0.8, 50)
        Self.expectOutlook(try Self.outlookOf(b), .now, t0 + 12 * h, t0 + 13 * h, true, t0 + 12 * h, 0.8, 50.0)
        // the instant the hour starts, its last second, and after it (test-blend.c:2553-2558)
        #expect(try Self.outlookOf(b, [], t0 + 12 * h).state == .now)
        #expect(try Self.outlookOf(b, [], t0 + 13 * h - 1).state == .now)
        Self.expectDry(try Self.outlookOf(b, [], t0 + 13 * h))
        // the data ends while it rains: the end is unknown (test-blend.c:2560-2564)
        var c = Self.rainHours()
        Self.setWet(&c, 11, 21, 0.5, 60)
        Self.expectOutlook(try Self.outlookOf(Array(c.prefix(10))), .now, t0 + 11 * h, 0, false, t0 + 11 * h, 0.5, 60.0)
        // wet all the way past the 48 h horizon (test-blend.c:2566-2570)
        var d = Self.rainHours()
        Self.setWet(&d, 11, 71, 0.5, 60)
        Self.expectOutlook(try Self.outlookOf(d), .now, t0 + 11 * h, 0, false, t0 + 11 * h, 0.5, 60.0)
        // test-blend.c:2572-2583
        var e = Self.rainHours()
        Self.setWet(&e, 12, 61, 0.5, 60)
        Self.expectOutlook(try Self.outlookOf(e), .now, t0 + 12 * h, 0, false, t0 + 12 * h, 0.5, 60.0)
        var f = Self.rainHours()
        Self.setWet(&f, 12, 60, 0.5, 60)
        Self.expectOutlook(try Self.outlookOf(f), .now, t0 + 12 * h, t0 + 60 * h, true, t0 + 12 * h, 0.5, 60.0)
    }

    // C: /blend/rain/expected (test-blend.c:2587-2632)
    @Test("/blend/rain/expected") func rainExpected() throws {
        let t0 = Self.t0, h = Self.h
        var a = Self.rainHours()
        Self.setWet(&a, 16, 18, 0.3, 40)
        a[17 - 11].precipMm = 0.9
        Self.setWet(&a, 22, 23, 0.5, 50)
        // the first run only (test-blend.c:2593-2595)
        Self.expectOutlook(try Self.outlookOf(a), .expected, t0 + 16 * h, t0 + 18 * h, true, t0 + 17 * h, 0.9, 40.0)
        var b = Self.rainHours()
        Self.setWet(&b, 13, 14, 0.4, 35)
        Self.expectOutlook(try Self.outlookOf(b), .expected, t0 + 13 * h, t0 + 14 * h, true, t0 + 13 * h, 0.4, 35.0)
        var c = Self.rainHours()
        Self.setWet(&c, 59, 71, 0.4, 60)
        Self.expectOutlook(try Self.outlookOf(c), .expected, t0 + 59 * h, 0, false, t0 + 59 * h, 0.4, 60.0)
        // starting at 60:00 (inside 60:37) counts; at 61:00 it does not (test-blend.c:2607-2615)
        var d = Self.rainHours()
        Self.setWet(&d, 60, 61, 0.4, 60)
        Self.expectOutlook(try Self.outlookOf(d), .expected, t0 + 60 * h, 0, false, t0 + 60 * h, 0.4, 60.0)
        var e = Self.rainHours()
        Self.setWet(&e, 61, 62, 0.4, 60)
        Self.expectDry(try Self.outlookOf(e))
        // with now on the hour the horizon is exactly 60:00 (test-blend.c:2616-2623)
        var f = Self.rainHours()
        Self.setWet(&f, 60, 61, 0.4, 60)
        Self.expectDry(try Self.outlookOf(f, [], t0 + 12 * h))
        Self.setWet(&f, 59, 60, 0.4, 60)
        Self.expectOutlook(
            try Self.outlookOf(f, [], t0 + 12 * h), .expected, t0 + 59 * h, 0, false, t0 + 59 * h, 0.4, 60.0)
        // a wet run in the past does not make "expected" (test-blend.c:2625-2631)
        var g = Self.rainHours()
        Self.setWet(&g, 11, 12, 0.5, 60)
        let o = try Self.outlookOf(g)
        #expect(o.state != .expected)
        #expect(o.state != .now)
    }

    // C: /blend/rain/wet-thresholds (test-blend.c:2635-2666)
    @Test("/blend/rain/wet-thresholds") func wetThresholds() throws {
        let t0 = Self.t0, h = Self.h
        // test-blend.c:2642-2646
        let cases: [(mm: Double, prob: Double, state: WxRainState)] = [
            (0.1, 30.0, .expected), (0.1, 29.99, .dry), (1.0, 29.9, .dry),
            (0.1, .nan, .expected), (0.0999, 90.0, .possible), (5.0, 100.0, .expected),
            (0.0999, .nan, .dry), (.nan, 90.0, .possible), (.nan, .nan, .dry),
            (0.0, 40.0, .possible),
        ]
        for (i, c) in cases.enumerated() {
            var a = Self.rainHours()
            a[16 - 11].precipMm = c.mm
            a[16 - 11].precipProb = c.prob
            #expect(try Self.outlookOf(a).state == c.state, "case \(i)")
        }
        // an unknown probability on a wet hour leaves peak_prob unknown (test-blend.c:2655-2660)
        var b = Self.rainHours()
        b[16 - 11].precipMm = 0.3
        b[16 - 11].precipProb = .nan
        Self.expectOutlook(try Self.outlookOf(b), .expected, t0 + 16 * h, t0 + 17 * h, true, t0 + 16 * h, 0.3, .nan)
        // a peak with the same rate: the first one (test-blend.c:2661-2665)
        var c = Self.rainHours()
        Self.setWet(&c, 16, 19, 0.7, 50)
        Self.expectOutlook(try Self.outlookOf(c), .expected, t0 + 16 * h, t0 + 19 * h, true, t0 + 16 * h, 0.7, 50.0)
    }

    // C: /blend/rain/gaps-empty (test-blend.c:2669-2712)
    @Test("/blend/rain/gaps-empty") func gapsAndEmpty() throws {
        let t0 = Self.t0, h = Self.h
        let a = [
            Self.bh(t0 + 11 * h, 20, 0.5, 60, 50, .rain, true, 1), Self.bh(t0 + 12 * h, 20, 0.5, 60, 50, .rain, true, 1),
            Self.bh(t0 + 14 * h, 20, 0.5, 60, 50, .rain, true, 1), Self.bh(t0 + 15 * h, 20, 0.0, 10, 50, .clear, true, 1),
        ]
        // test-blend.c:2677-2678
        Self.expectOutlook(try Self.outlookOf(a), .now, t0 + 11 * h, 0, false, t0 + 11 * h, 0.5, 60.0)
        let pre = [
            Self.bh(t0 + 10 * h, 20, 0.5, 60, 50, .rain, true, 1), Self.bh(t0 + 12 * h, 20, 0.5, 60, 50, .rain, true, 1),
            Self.bh(t0 + 13 * h, 20, 0.0, 10, 50, .clear, true, 1),
        ]
        // test-blend.c:2685-2686
        Self.expectOutlook(try Self.outlookOf(pre), .now, t0 + 12 * h, t0 + 13 * h, true, t0 + 12 * h, 0.5, 60.0)
        var b = [
            Self.bh(t0 + 12 * h, 20, 0.0, 10, 50, .clear, true, 1), Self.bh(t0 + 14 * h, 20, 0.5, 60, 50, .rain, true, 1),
            Self.bh(t0 + 15 * h, 20, 0.5, 60, 50, .rain, true, 1), Self.bh(t0 + 17 * h, 20, 0.5, 60, 50, .rain, true, 1),
        ]
        // test-blend.c:2694-2695
        Self.expectOutlook(try Self.outlookOf(b), .expected, t0 + 14 * h, 0, false, t0 + 14 * h, 0.5, 60.0)
        b[3] = Self.bh(t0 + 16 * h, 20, 0.0, 10, 50, .clear, true, 1)
        // test-blend.c:2698-2700
        Self.expectOutlook(try Self.outlookOf(b), .expected, t0 + 14 * h, t0 + 16 * h, true, t0 + 14 * h, 0.5, 60.0)
        // no hours at all, and no hour covering now (test-blend.c:2702-2707)
        Self.expectDry(try Self.outlookOf([]))
        Self.expectDry(try Self.outlookOf([Self.bh(t0 + 2 * h, 20, 5.0, 90, 50, .rain, true, 1)]))
        // the forecast starts in the future and rains (test-blend.c:2708-2711)
        Self.expectOutlook(
            try Self.outlookOf([Self.bh(t0 + 15 * h, 20, 5.0, 90, 50, .rain, true, 1)]), .expected, t0 + 15 * h, 0,
            false, t0 + 15 * h, 5.0, 90.0)
    }

    // C: /blend/rain/quarters (test-blend.c:2724-2827)
    @Test("/blend/rain/quarters") func quarters() throws {
        let t0 = Self.t0, h = Self.h
        let q1230 = t0 + 12 * h + 1800
        var amounts = [Double](repeating: 0, count: 16)
        // (a) test-blend.c:2730-2736
        let a = Self.rainHours()
        amounts[0] = 0.06
        amounts[1] = 0.06
        Self.expectOutlook(
            try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)), .now, q1230, t0 + 13 * h, true, q1230, 0.24,
            .nan)
        // (e) the 0.05 mm threshold (test-blend.c:2738-2747)
        amounts = [Double](repeating: 0, count: 16)
        amounts[0] = 0.05
        Self.expectOutlook(
            try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)), .now, q1230, q1230 + 900, true, q1230, 0.2,
            .nan)
        amounts[0] = 0.0499
        Self.expectDry(try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)))
        // wet quarters later in the first two hours (test-blend.c:2749-2755)
        amounts = [Double](repeating: 0, count: 16)
        amounts[3] = 0.1
        amounts[4] = 0.2
        Self.expectOutlook(
            try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)), .expected, q1230 + 3 * 900, q1230 + 5 * 900,
            true, q1230 + 4 * 900, 0.8, .nan)
        // a quarter beyond 2 hours from now is not used (test-blend.c:2756-2766)
        amounts = [Double](repeating: 0, count: 16)
        amounts[9] = 0.3
        Self.expectDry(try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)))
        amounts[9] = 0
        amounts[8] = 0.3
        Self.expectOutlook(
            try Self.outlookOf(a, Self.quartersFrom(q1230, amounts, 12)), .expected, q1230 + 8 * 900, q1230 + 9 * 900,
            true, q1230 + 8 * 900, 1.2, .nan)
        // (b) test-blend.c:2768-2776
        var b = Self.rainHours()
        Self.setWet(&b, 12, 13, 2.0, 60)
        Self.setWet(&b, 14, 15, 0.5, 50)
        amounts = [Double](repeating: 0, count: 16)
        let dry12 = Self.quartersFrom(q1230, amounts, 12)
        Self.expectOutlook(
            try Self.outlookOf(b, dry12), .expected, t0 + 14 * h + 2700, t0 + 15 * h, true, t0 + 14 * h + 2700, 0.5,
            50.0)
        // (d) test-blend.c:2778-2786
        var d = Self.rainHours()
        Self.setWet(&d, 13, 14, 9.0, 100)
        Self.expectOutlook(try Self.outlookOf(d, dry12), .possible, 0, 0, false, t0 + 13 * h, 9.0, 100.0)
        Self.expectOutlook(try Self.outlookOf(d), .expected, t0 + 13 * h, t0 + 14 * h, true, t0 + 13 * h, 9.0, 100.0)
        // (c) test-blend.c:2788-2801
        var c = Self.rainHours()
        Self.setWet(&c, 14, 15, 0.3, 50)
        Self.setWet(&c, 15, 16, 0.9, 70)
        amounts = [Double](repeating: 0.1, count: 16)
        let wet12 = Self.quartersFrom(q1230, amounts, 12)
        Self.expectOutlook(try Self.outlookOf(c, wet12), .now, q1230, t0 + 16 * h, true, t0 + 15 * h, 0.9, 70.0)
        Self.setWet(&c, 12, 13, 0.2, 40)
        Self.expectOutlook(try Self.outlookOf(c, wet12), .now, t0 + 12 * h, t0 + 16 * h, true, t0 + 15 * h, 0.9, 70.0)
        // (f) the quarter containing now is not the first one (test-blend.c:2803-2809)
        var f = Self.rainHours()
        Self.setWet(&f, 12, 13, 0.8, 50)
        amounts[0] = 5.0
        Self.expectOutlook(
            try Self.outlookOf(f, Self.quartersFrom(q1230 + 900, amounts, 4)), .now, t0 + 12 * h, t0 + 13 * h, true,
            t0 + 12 * h, 0.8, 50.0)
        // (g) a gap in the quarters (test-blend.c:2811-2815)
        let g = Self.rainHours()
        let gq = [
            WxQuarter(tS: q1230, precipMm: 0.1), WxQuarter(tS: q1230 + 900, precipMm: 0.1),
            WxQuarter(tS: q1230 + 2700, precipMm: 5.0),
        ]
        Self.expectOutlook(try Self.outlookOf(g, gq), .now, q1230, t0 + 13 * h, true, q1230, 0.4, .nan)
        // quarters without any hours (test-blend.c:2817-2819)
        Self.expectOutlook(try Self.outlookOf([], Array(gq.prefix(2))), .now, q1230, 0, false, q1230, 0.4, .nan)
        // stale quarters are ignored (test-blend.c:2821-2826)
        var s = Self.rainHours()
        Self.setWet(&s, 16, 17, 0.5, 60)
        Self.expectOutlook(
            try Self.outlookOf(s, Self.quartersFrom(t0 + 10 * h, amounts, 8)), .expected, t0 + 16 * h, t0 + 17 * h,
            true, t0 + 16 * h, 0.5, 60.0)
    }

    // C: /blend/rain/criticals (test-blend.c:2830-2854). The NULL-out and
    // NULL-forecast rows are not representable in Swift (non-optional
    // parameters); the out-of-range "now" rows give the DRY outlook.
    @Test("/blend/rain/criticals") func criticals() throws {
        for now in [WxLimits.timeMinS - 1, WxLimits.timeMaxS, Int64.max, Int64.min] {
            Self.expectDry(try Self.outlookOf([], [], now), "now \(now)")  // test-blend.c:2840-2848
            Self.expectDry(WxRainRules.outlook(hours: Self.rainHours(), quarters: [], nowS: now), "now \(now)")
        }
        // the ends of the range are fine (test-blend.c:2850-2853)
        Self.expectDry(try Self.outlookOf([], [], WxLimits.timeMinS))
        Self.expectDry(try Self.outlookOf([], [], WxLimits.timeMaxS - 1))
    }

    /// RefHour (test-blend.c:2858-2862).
    struct RefHour {
        var t: Int64
        var mm: Double
        var prob: Double
    }

    /// ref_at, ref_wet and ref_outlook (test-blend.c:2864-2944): the rules of
    /// wx-rain.h written with time arithmetic on the hour grid.
    static func refOutlook(_ hs: [RefHour], _ now: Int64) -> WxRainOutlook {
        func at(_ t: Int64) -> RefHour? { hs.first { $0.t == t } }
        func wet(_ r: RefHour?) -> Bool {
            guard let r else { return false }
            return r.mm >= 0.1 && (r.prob.isNaN || r.prob >= 30.0)
        }
        let horizon = now + 172_800
        var o = WxRainOutlook()
        var first: Int64 = 0
        var have = false
        var cover: RefHour?
        for r in hs where r.t <= now && now < r.t + 3600 {
            cover = r
        }
        if let cover, wet(cover) {
            first = cover.t
            while wet(at(first - 3600)) {
                first -= 3600
            }
            o.state = .now
            have = true
        } else {
            var c: RefHour?
            for r in hs where wet(r) && r.t >= now && r.t < horizon && (c == nil || r.t < c!.t) {
                c = r
            }
            if let c {
                first = c.t
                o.state = .expected
                have = true
            }
        }
        if have {
            var last = first
            while wet(at(last + 3600)) && last + 3600 < horizon {
                last += 3600
            }
            let next = at(last + 3600)
            o.startS = first
            o.endsKnown = next != nil && last + 3600 < horizon && !wet(next)
            o.endS = o.endsKnown ? last + 3600 : 0
            o.peakMmH = -1
            o.peakProb = .nan
            var t = first
            while t <= last {
                let c = at(t)!
                if c.mm > o.peakMmH {
                    o.peakMmH = c.mm
                    o.peakS = t
                }
                if !c.prob.isNaN && (o.peakProb.isNaN || c.prob > o.peakProb) {
                    o.peakProb = c.prob
                }
                t += 3600
            }
            return o
        }
        var best: RefHour?
        for r in hs where r.t + 3600 > now && r.t < horizon && r.prob >= 40.0 && (best == nil || r.prob > best!.prob) {
            best = r
        }
        if let best {
            o.state = .possible
            o.peakS = best.t
            o.peakProb = best.prob
            o.peakMmH = best.mm.isFinite ? best.mm : 0.0
        }
        return o
    }

    /// assert_close_or_nan (test-blend.c:2948-2955).
    static func closeOrNaN(_ got: Double, _ want: Double) -> Bool {
        want.isNaN ? got.isNaN : abs(got - want) <= 1e-12 * max(1.0, abs(want))
    }

    // C: /blend/rain/fuzz-reference (test-blend.c:2958-3015)
    @Test("/blend/rain/fuzz-reference") func fuzzAgainstReference() throws {
        let t0 = Self.t0, h = Self.h
        var rng = SeededRNG(seed: 424_242)
        let mms: [Double] = [0.0, 0.0, 0.05, 0.0999, 0.1, 0.5, 2.0, .nan]  // test-blend.c:2963
        let probs: [Double] = [.nan, 0.0, 20.0, 29.99, 30.0, 39.99, 40.0, 45.0, 80.0]  // test-blend.c:2964
        let place = try WxPlace(name: "Testville", lat: 51.5074, lon: -0.1278, timezone: "Europe/London")
        var seen = [Int](repeating: 0, count: 4)
        var failures = 0
        for iter in 0..<fuzzIterations(20_000) {
            let n = Int.random(in: 0..<90, using: &rng)
            let base = t0 + Int64.random(in: 0..<100, using: &rng) * h
            var ref: [RefHour] = []
            var hrs: [WxBlendHour] = []
            let sticky = Double.random(in: 0..<1, using: &rng) < 0.5
            var raining = false
            for i in 0..<n {
                if Double.random(in: 0..<1, using: &rng) < 0.05 {
                    continue
                }
                if !sticky || Double.random(in: 0..<1, using: &rng) < 0.3 {
                    raining = Bool.random(using: &rng)
                }
                let mm = raining ? mms[Int.random(in: 4..<mms.count, using: &rng)] : mms[Int.random(in: 0..<4, using: &rng)]
                let prob = probs[Int.random(in: 0..<probs.count, using: &rng)]
                let t = base + Int64(i) * h
                ref.append(RefHour(t: t, mm: mm, prob: prob))
                hrs.append(Self.bh(t, 20, mm, prob, 50, .clear, true, 1))
            }
            let hourIndex = Int64.random(in: -4..<Int64(60 + n), using: &rng)
            let second = Int64.random(in: 0..<h, using: &rng)
            var now = base + hourIndex * h + second
            if Double.random(in: 0..<1, using: &rng) < 0.1 {
                now = base + Int64.random(in: 0..<60, using: &rng) * h
            }
            let fc = try WxForecast(place: place, generatedS: Self.nowS, hours: hrs)
            let got = WxRainRules.outlook(fc, nowS: now)
            let want = Self.refOutlook(ref, now)
            var same = got.state == want.state && got.startS == want.startS && got.endS == want.endS
            same = same && got.endsKnown == want.endsKnown && got.peakS == want.peakS
            same = same && Self.closeOrNaN(got.peakMmH, want.peakMmH) && Self.closeOrNaN(got.peakProb, want.peakProb)
            // invariants of the result (test-blend.c:3002-3011)
            var invariants = got.endsKnown == (got.endS != 0)
            invariants = invariants && (got.state != .now || got.startS <= now)
            invariants = invariants && (got.state != .expected || got.startS >= now)
            invariants = invariants && (got.endS == 0 || (got.startS <= got.peakS && got.peakS < got.endS))
            if !same || !invariants {
                failures += 1
                if failures <= 5 {
                    Issue.record("iteration \(iter): got \(got), wanted \(want)")
                }
            }
            seen[got.state.rawValue] += 1
        }
        #expect(failures == 0)
        for s in 0..<4 {
            #expect(seen[s] > 500, "state \(s) seen \(seen[s]) times")  // test-blend.c:3013-3014
        }
    }

    // C: /blend/rain/fuzz-quarters (test-blend.c:3019-3061)
    @Test("/blend/rain/fuzz-quarters") func fuzzQuartersInvariants() throws {
        let t0 = Self.t0, h = Self.h
        var rng = SeededRNG(seed: 99)
        let place = try WxPlace(name: "Testville", lat: 51.5074, lon: -0.1278, timezone: "Europe/London")
        var failures = 0
        for iter in 0..<fuzzIterations(5_000) {
            let n = Int.random(in: 0..<40, using: &rng)
            let base = t0 + Int64.random(in: 0..<100, using: &rng) * h
            var hrs: [WxBlendHour] = []
            for i in 0..<n {
                let mm = Double.random(in: 0..<1, using: &rng) < 0.6 ? 0.0 : Double.random(in: 0..<3, using: &rng)
                let prob = Double.random(in: 0..<1, using: &rng) < 0.2 ? Double.nan : Double.random(in: 0..<100, using: &rng)
                hrs.append(Self.bh(base + Int64(i) * h, 20, mm, prob, 50, .clear, true, 1))
            }
            let now = base + Int64.random(in: 0..<40, using: &rng) * h + Int64.random(in: 0..<h, using: &rng)
            let q0 = now - now % 900 - 900 * Int64.random(in: 0..<2, using: &rng)
            let nq = Int.random(in: 0..<14, using: &rng)
            var q: [WxQuarter] = []
            for i in 0..<nq {
                let mm = Double.random(in: 0..<1, using: &rng) < 0.5 ? 0.0 : Double.random(in: 0..<1, using: &rng)
                q.append(WxQuarter(tS: q0 + Int64(i) * 900, precipMm: mm))
            }
            let fc = try WxForecast(place: place, generatedS: Self.nowS, hours: hrs, quarters: q)
            let o = WxRainRules.outlook(fc, nowS: now)
            var ok = o.endsKnown == (o.endS != 0)
            if o.state == .dry {
                ok = ok && o.startS == 0 && o.endS == 0
            }
            if o.state == .now || o.state == .expected {
                ok = ok && o.startS <= o.peakS && o.peakMmH.isFinite && o.peakMmH >= 0 && o.startS < now + 172_800
                ok = ok && (o.endS == 0 || o.peakS < o.endS)
            }
            if o.state == .possible {
                ok = ok && o.peakProb >= 40.0
            }
            if !ok {
                failures += 1
                if failures <= 5 {
                    Issue.record("iteration \(iter): \(o)")
                }
            }
        }
        #expect(failures == 0)
    }

    // C: /blend/rain/hours-bound (test-blend.c:4510-4549). A G_MAXUINT count
    // is not representable (Swift arrays carry their count).
    @Test("/blend/rain/hours-bound") func hoursBound() {
        let t0 = Self.t0, h = Self.h
        let big = (0..<(WxLimits.forecastMaxHours + 200)).map { Self.bh(t0 + Int64($0) * h, 20, 5.0, 90, 50, .rain, true, 1) }
        // more hours than allowed: DRY (test-blend.c:4521-4528)
        Self.expectDry(WxRainRules.outlook(hours: big, quarters: [], nowS: t0 + 12 * h))
        Self.expectDry(
            WxRainRules.outlook(hours: Array(big.prefix(WxLimits.forecastMaxHours + 1)), quarters: [], nowS: t0 + 12 * h))
        // exactly the maximum works, with and without nowcast quarters (test-blend.c:4533-4548)
        let max = Array(big.prefix(WxLimits.forecastMaxHours))
        Self.expectOutlook(
            WxRainRules.outlook(hours: max, quarters: [], nowS: t0 + 12 * h + 7 * 60), .now, t0, 0, false, t0, 5.0, 90.0)
        let q = (0..<12).map { WxQuarter(tS: t0 + 12 * h + Int64($0) * 900, precipMm: 1.0) }
        let o = WxRainRules.outlook(hours: max, quarters: q, nowS: t0 + 12 * h + 7 * 60)
        #expect(o.state == .now)
        #expect(o.startS == t0)
        #expect(o.endsKnown == false)
    }

    // C: /blend/rain/hostile-hours (test-blend.c:4579-4667). The NULL-array
    // rows (test-blend.c:4627-4632) and the G_MAXUINT count are not
    // representable in Swift.
    @Test("/blend/rain/hostile-hours") func hostileHours() {
        let t0 = Self.t0, h = Self.h
        let now: Int64 = 1_791_720_900  // 12:15Z (test-blend.c:4583)
        var qs = [WxQuarter(tS: now, precipMm: 0.2)]
        // the same hour 2 .. 400 times against a one quarter span (test-blend.c:4586-4593)
        for count in [2, 205, 206, 399, 400] {
            let hrs = [WxBlendHour](repeating: Self.bh(1_791_720_000, 20, 1.0, 90, 50, .rain, true, 1), count: count)
            Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: qs, nowS: now), "count \(count)")
        }
        // strictly ascending but unaligned (test-blend.c:4594-4600)
        var hrs = (0..<WxLimits.forecastMaxHours).map { Self.bh(1_791_719_400 + Int64($0), 20, 1.0, 90, 50, .rain, true, 1) }
        Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: qs, nowS: 1_791_720_000))
        Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: [], nowS: 1_791_720_000))
        // descending, and a duplicate (test-blend.c:4602-4611)
        hrs = (0..<10).map { Self.bh(t0 + (30 - Int64($0)) * h, 20, 1.0, 90, 50, .rain, true, 1) }
        Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: [], nowS: Self.nowS))
        hrs = (0..<10).map { Self.bh(t0 + (10 + Int64($0)) * h, 20, 1.0, 90, 50, .rain, true, 1) }
        hrs[6].tS = hrs[5].tS
        Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: [], nowS: Self.nowS))
        // out of the time range, one bad hour in a good list (test-blend.c:4613-4625)
        let badT: [Int64] = [
            0, -3600, Int64.min, Int64.max, WxLimits.timeMinS - 3600, WxLimits.timeMaxS, WxLimits.timeMaxS + 3600,
            Int64.max - 3599,
        ]
        for bad in badT {
            for pos in [0, 3] {
                var four = (0..<4).map { Self.bh(t0 + (10 + Int64($0)) * h, 20, 1.0, 90, 50, .rain, true, 1) }
                four[pos].tS = bad
                Self.expectDry(WxRainRules.outlook(hours: four, quarters: [], nowS: Self.nowS), "t \(bad) at \(pos)")
            }
        }
        // no hours at all: fine (test-blend.c:4633-4637)
        Self.expectDry(WxRainRules.outlook(hours: [], quarters: [], nowS: Self.nowS))
        // the worst valid case for the sample list (test-blend.c:4639-4648)
        hrs = (0..<WxLimits.forecastMaxHours).map { Self.bh(t0 + (12 + Int64($0)) * h, 20, 0.5, 90, 50, .rain, true, 1) }
        qs = [WxQuarter(tS: t0 + 12 * h + 900, precipMm: 0.2)]
        var o = WxRainRules.outlook(hours: hrs, quarters: qs, nowS: t0 + 12 * h + 1200)
        #expect(o.state == .now)
        #expect(o.startS == t0 + 12 * h)
        #expect(o.endsKnown == false)
        // the maximum number of quarters, all valid (test-blend.c:4650-4661)
        qs = (0..<WxLimits.forecastMaxQuarters).map { WxQuarter(tS: t0 + Int64($0) * 900, precipMm: 1.0) }
        hrs = (0..<WxLimits.forecastMaxHours).map { Self.bh(t0 + Int64($0) * h, 20, 0.0, 10, 50, .clear, true, 1) }
        o = WxRainRules.outlook(hours: hrs, quarters: qs, nowS: t0 + 12 * h + 7 * 60)
        #expect(o.state == .now)
        #expect(o.startS == t0 + 12 * h)
        #expect(o.endS == t0 + 14 * h + 900)
        #expect(o.endsKnown == true)
        // one more than the limit (test-blend.c:4662-4665)
        qs = (0..<(WxLimits.forecastMaxQuarters + 1)).map { WxQuarter(tS: t0 + Int64($0) * 900, precipMm: 1.0) }
        Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: qs, nowS: t0 + 12 * h + 7 * 60))
    }

    // C: /blend/rain/hostile-quarters (test-blend.c:4670-4708)
    @Test("/blend/rain/hostile-quarters") func hostileQuarters() {
        let t0 = Self.t0, h = Self.h
        let hrs = (0..<8).map { Self.bh(t0 + (10 + Int64($0)) * h, 20, 0.0, 10, 50, .clear, true, 1) }
        let q0 = t0 + 12 * h
        func q(_ t: Int64, _ mm: Double) -> WxQuarter { WxQuarter(tS: t, precipMm: mm) }
        let good = [q(q0, 0.1), q(q0 + 900, 0.1), q(q0 + 1800, 0.1), q(q0 + 2700, 0.1)]
        #expect(WxRainRules.outlook(hours: hrs, quarters: good, nowS: q0 + 420).state == .now)  // test-blend.c:4678-4679
        let maxS = WxLimits.timeMaxS
        // test-blend.c:4685-4697
        let cases: [(String, [WxQuarter])] = [
            ("unaligned", [q(q0 + 1, 0.1), q(q0 + 901, 0.1), q(q0 + 1801, 0.1), q(q0 + 2701, 0.1)]),
            ("duplicate", [q(q0, 0.1), q(q0 + 900, 0.1), q(q0 + 900, 0.1), q(q0 + 2700, 0.1)]),
            ("descending", [q(q0 + 2700, 0.1), q(q0 + 1800, 0.1), q(q0 + 900, 0.1), q(q0, 0.1)]),
            ("NaN", [q(q0, 0.1), q(q0 + 900, .nan), q(q0 + 1800, 0.1), q(q0 + 2700, 0.1)]),
            ("inf", [q(q0, 0.1), q(q0 + 900, .infinity), q(q0 + 1800, 0.1), q(q0 + 2700, 0.1)]),
            ("negative", [q(q0, 0.1), q(q0 + 900, -0.001), q(q0 + 1800, 0.1), q(q0 + 2700, 0.1)]),
            ("above max", [q(q0, 0.1), q(q0 + 900, 500.5), q(q0 + 1800, 0.1), q(q0 + 2700, 0.1)]),
            ("time zero", [q(0, 0.1), q(900, 0.1), q(1800, 0.1), q(2700, 0.1)]),
            ("time max", [q(maxS, 0.1), q(maxS + 900, 0.1), q(maxS + 1800, 0.1), q(maxS + 2700, 0.1)]),
            ("time int64 max", [q(Int64.max, 0.1), q(Int64.max, 0.1), q(Int64.max, 0.1), q(Int64.max, 0.1)]),
            ("time int64 min", [q(Int64.min, 0.1), q(Int64.min + 900, 0.1), q(q0, 0.1), q(q0 + 900, 0.1)]),
        ]
        for (what, qs) in cases {
            Self.expectDry(WxRainRules.outlook(hours: hrs, quarters: qs, nowS: q0 + 420), "\(what)")
        }
        // -0.0 and the exact maximum are valid amounts (test-blend.c:4703-4707)
        let edge = [q(q0, -0.0), q(q0 + 900, 500.0), q(q0 + 1800, 0.0), q(q0 + 2700, 4.9e-324)]
        let o = WxRainRules.outlook(hours: hrs, quarters: edge, nowS: q0 + 420)
        #expect(o.state == .expected)
        expectNear(o.peakMmH, 2000.0, eps: 1e-9)
    }
}
