// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// BlendFixture.swift - the shared helpers of the ported blend, nowcast, now,
// determinism and fuzz groups of src/blend/test-blend.c (helpers at
// test-blend.c:25-255, 874-986, 1864-1922, 2237-2268, 4062-4119, 5070-5190).
// Every helper throws or records an issue instead of trapping.

import Foundation
import Testing

@testable import WeatherCore

/// Fixtures of the ported test-blend.c groups.
enum BlendFixture {
    /// T0 (test-blend.c:25-26): 2026-10-11T00:00:00Z.
    static let t0: Int64 = 1_791_676_800
    /// H (test-blend.c:27).
    static let h: Int64 = 3600
    /// NOW_S (test-blend.c:28-29): 2026-10-11T12:37:00Z.
    static let nowS: Int64 = t0 + 12 * h + 37 * 60
    /// DMIN (test-blend.c:3851-3852): the smallest positive double.
    static let dmin = 4.9406564584124654e-324
    /// NOWCAST_MIN_MM (test-blend.c:3849-3850).
    static let nowcastMinMm = 1e-9

    // MARK: - Places (test-blend.c:57-77)

    static func place(_ lat: Double, _ lon: Double, _ tz: String) throws(WxError) -> WxPlace {
        try WxPlace(name: "Testville", admin1: "Region", country: "Country", countryCode: "US", lat: lat, lon: lon, timezone: tz)
    }

    static func miami() throws(WxError) -> WxPlace { try place(25.7617, -80.1918, "America/New_York") }
    static func london() throws(WxError) -> WxPlace { try place(51.5074, -0.1278, "Europe/London") }

    // MARK: - Members (test-blend.c:79-141)

    /// Vals / vnone(): the values of a constant member, every field unknown by default.
    struct Vals {
        var temp = Double.nan, feels = Double.nan, precip = Double.nan, prob = Double.nan
        var cloud = Double.nan, wind = Double.nan, gust = Double.nan, hum = Double.nan
        var wmo = -1

        /// fill_const (test-blend.c:95-109).
        func fill(_ hour: inout WxHour) {
            hour.tempC = temp
            hour.feelsC = feels
            hour.precipMm = precip
            hour.precipProb = prob
            hour.cloudPct = cloud
            hour.windKmh = wind
            hour.gustKmh = gust
            hour.humidityPct = hum
            hour.wmo = wmo
        }
    }

    /// new_member (test-blend.c:979-986): fetched at NOW_S.
    static func newMember(_ src: String, _ model: String) throws(WxError) -> WxMember {
        try WxMember(sourceID: src, modelID: model, fetchedS: nowS)
    }

    /// mk_member_fn (test-blend.c:111-126): `n` hours from `first`, each filled by `fill(hour, i)`.
    static func member(
        _ src: String, _ model: String, first: Int64, count n: Int, sourceLocation: SourceLocation = #_sourceLocation,
        _ fill: (inout WxHour, Int) -> Void
    ) throws(WxError) -> WxMember {
        var m = try newMember(src, model)
        for i in 0..<n {
            var hour = WxHour(tS: first + Int64(i) * h)
            fill(&hour, i)
            let added = m.addHour(hour)
            #expect(added, "hour \(i) refused", sourceLocation: sourceLocation)
        }
        return m
    }

    /// mk_member (test-blend.c:128-132).
    static func member(
        _ src: String, _ model: String, first: Int64, count n: Int, _ v: Vals,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws(WxError) -> WxMember {
        try member(src, model, first: first, count: n, sourceLocation: sourceLocation) { hour, _ in v.fill(&hour) }
    }

    /// add_hour_vals (test-blend.c:969-977).
    static func addHour(_ m: inout WxMember, _ t: Int64, _ v: Vals, sourceLocation: SourceLocation = #_sourceLocation) {
        var hour = WxHour(tS: t)
        v.fill(&hour)
        let added = m.addHour(hour)
        #expect(added, sourceLocation: sourceLocation)
    }

    /// add_quarters (test-blend.c:134-141).
    static func addQuarters(
        _ m: inout WxMember, first: Int64, _ amounts: [Double], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (i, a) in amounts.enumerated() {
            let added = m.addQuarter(WxQuarter(tS: first + Int64(i) * 900, precipMm: a))
            #expect(added, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Results (Fx, test-blend.c:143-228)

    /// A set of provider results built from members (Fx).
    struct Fx {
        var results: [WxSourceResult] = []

        /// fx_add (test-blend.c:163-179): appends `m` to the result of `provider`, created on first use.
        mutating func add(_ provider: String, _ m: WxMember) throws(WxError) {
            if let i = results.firstIndex(where: { $0.providerID == provider }) {
                results[i].members.append(m)
            } else {
                var r = try WxSourceResult(providerID: provider)
                r.members.append(m)
                results.append(r)
            }
        }
    }

    /// fx_blend / fx_blend_at (test-blend.c:181-197): throws the blend's error.
    static func blend(_ fx: Fx, _ place: WxPlace, _ now: Int64) throws(WxError) -> WxForecast {
        try WxBlend.forecast(place: place, results: fx.results, nowS: now)
    }

    /// blend_raw_at (test-blend.c:950-967): the members in one result "raw", in order.
    static func blendRaw(_ place: WxPlace, _ members: [WxMember], now: Int64 = nowS) throws(WxError) -> WxForecast {
        var r = try WxSourceResult(providerID: "raw")
        r.members = members
        return try WxBlend.forecast(place: place, results: [r], nowS: now)
    }

    /// The blend's error, or nil when it succeeds.
    static func blendError(_ results: [WxSourceResult], _ place: WxPlace, _ now: Int64) -> WxError? {
        do {
            _ = try WxBlend.forecast(place: place, results: results, nowS: now)
            return nil
        } catch {
            return error
        }
    }

    /// assert_blend_fails (test-blend.c:220-228).
    static func expectBlendFails(
        _ fx: Fx, _ place: WxPlace, _ now: Int64, _ code: WxError.Code, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let err = blendError(fx.results, place, now)
        #expect(err?.code == code, "blend error \(String(describing: err)), wanted \(code)", sourceLocation: sourceLocation)
    }

    /// hour_at (test-blend.c:207-218): the hour starting at `t`; requires that it exists.
    static func hourAt(_ fc: WxForecast, _ t: Int64, sourceLocation: SourceLocation = #_sourceLocation) throws -> WxBlendHour {
        try #require(fc.hours.first(where: { $0.tS == t }), "no hour at \(t)", sourceLocation: sourceLocation)
    }

    /// assert_quarters (test-blend.c:1911-1922): count, time stamps and amounts within 1e-12.
    static func expectQuarters(
        _ fc: WxForecast, first: Int64, _ want: [Double], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(fc.quarters.count == want.count, "quarters \(fc.quarters.count)", sourceLocation: sourceLocation)
        for (i, q) in fc.quarters.enumerated() where i < want.count {
            #expect(q.tS == first + Int64(i) * 900, "quarter \(i) time", sourceLocation: sourceLocation)
            #expect(abs(q.precipMm - want[i]) <= 1e-12, "quarter \(i): got \(q.precipMm) want \(want[i])", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Hand-built blended hours (test-blend.c:2237-2268)

    /// bh (test-blend.c:2237-2258).
    static func bh(
        _ t: Int64, _ temp: Double, _ precip: Double, _ prob: Double, _ cloud: Double, _ cond: WxCondition,
        _ isDay: Bool, _ nMembers: UInt8
    ) -> WxBlendHour {
        WxBlendHour(
            tS: t, tempC: temp, feelsC: temp, precipMm: precip, precipMmMax: precip, precipProb: prob, cloudPct: cloud,
            windKmh: .nan, gustKmh: .nan, humidityPct: .nan, tempSpreadC: .nan, nMembers: nMembers, condition: cond,
            isDay: isDay)
    }

    /// make_forecast (test-blend.c:2260-2268).
    static func makeForecast(_ p: WxPlace, _ hours: [WxBlendHour]) throws(WxError) -> WxForecast {
        try WxForecast(place: p, generatedS: nowS, hours: hours)
    }

    // MARK: - Comparisons (test-blend.c:874-930, 5155-5160)

    /// same_bits (test-blend.c:874-878).
    static func sameBits(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern }

    /// same_or_both_nan (test-blend.c:5155-5160).
    static func sameOrBothNaN(_ a: Double, _ b: Double) -> Bool { (a.isNaN && b.isNaN) || a == b }

    /// The bit patterns of every field of an hour (assert_hours_identical, test-blend.c:880-903).
    static func bits(_ x: WxBlendHour) -> [UInt64] {
        [UInt64(bitPattern: x.tS)]
            + [x.tempC, x.feelsC, x.precipMm, x.precipMmMax, x.precipProb, x.cloudPct, x.windKmh, x.gustKmh,
               x.humidityPct, x.tempSpreadC].map(\.bitPattern)
            + [UInt64(x.nMembers), UInt64(x.condition.rawValue), x.isDay ? 1 : 0]
    }

    /// assert_forecasts_identical (test-blend.c:905-930): bit for bit.
    static func expectIdentical(_ a: WxForecast, _ b: WxForecast, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.hours.map(bits) == b.hours.map(bits), "hours differ", sourceLocation: sourceLocation)
        #expect(a.quarters.map { [UInt64(bitPattern: $0.tS), $0.precipMm.bitPattern] }
            == b.quarters.map { [UInt64(bitPattern: $0.tS), $0.precipMm.bitPattern] }, "quarters differ", sourceLocation: sourceLocation)
        let dayBits: (WxDay) -> [UInt64] = { d in
            [UInt64(bitPattern: d.startS)] + [d.tempMaxC, d.tempMinC, d.precipMm, d.precipProbMax, d.cloudPct].map(\.bitPattern)
                + [UInt64(d.condition.rawValue)]
        }
        #expect(a.days.map(dayBits) == b.days.map(dayBits), "days differ", sourceLocation: sourceLocation)
        #expect(a.generatedS == b.generatedS, sourceLocation: sourceLocation)
    }

    /// assert_forecast_days_in_range (test-blend.c:5162-5190): the days rebuilt from the forecast's
    /// hours equal its days, every field within the range WxForecast enforces.
    static func expectDaysInRange(_ fc: WxForecast, sourceLocation: SourceLocation = #_sourceLocation) {
        let built = WxDaily.build(timezone: fc.place.timezone, hours: fc.hours, nowS: fc.generatedS)
        #expect(built.count == fc.days.count, sourceLocation: sourceLocation)
        for (b, d) in zip(built, fc.days) {
            #expect(b.startS == d.startS, sourceLocation: sourceLocation)
            #expect(sameOrBothNaN(b.tempMaxC, d.tempMaxC) && sameOrBothNaN(b.tempMinC, d.tempMinC)
                && sameOrBothNaN(b.precipMm, d.precipMm) && sameOrBothNaN(b.precipProbMax, d.precipProbMax)
                && sameOrBothNaN(b.cloudPct, d.cloudPct) && b.condition == d.condition, sourceLocation: sourceLocation)
            #expect(d.tempMaxC.isNaN || inRange(d.tempMaxC, WxLimits.tempMinC, WxLimits.tempMaxC), sourceLocation: sourceLocation)
            #expect(d.tempMinC.isNaN || inRange(d.tempMinC, WxLimits.tempMinC, WxLimits.tempMaxC), sourceLocation: sourceLocation)
            #expect(d.precipMm.isNaN || inRange(d.precipMm, 0, WxLimits.precipMaxMmDay), sourceLocation: sourceLocation)
            #expect(d.precipProbMax.isNaN || inRange(d.precipProbMax, 0, 100), sourceLocation: sourceLocation)
            #expect(d.cloudPct.isNaN || inRange(d.cloudPct, 0, 100), sourceLocation: sourceLocation)
        }
    }

    /// in_range (test-blend.c:5137-5141).
    static func inRange(_ v: Double, _ lo: Double, _ hi: Double) -> Bool { v.isFinite && v >= lo && v <= hi }

    /// assert_close_or_nan (test-blend.c:2948-2955).
    static func expectCloseOrNaN(_ got: Double, _ want: Double, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if want.isNaN {
            #expect(got.isNaN, "\(what): \(got) is not NaN", sourceLocation: sourceLocation)
        } else {
            #expect(abs(got - want) <= 1e-12 * max(1.0, abs(want)), "\(what): got \(got) want \(want)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Fuzz support (test-blend.c:230-254, 367-393)

    /// GRand's g_rand_int_range / g_rand_double / g_rand_boolean over SeededRNG (DECISIONS #16-#17: the
    /// C oracles are kept, the GRand sequences are not reproduced).
    struct Rand {
        var g: SeededRNG

        init(seed: UInt64) { g = SeededRNG(seed: seed) }

        /// g_rand_int_range: uniform in [lo, hi).
        mutating func intRange(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo..<hi, using: &g) }
        /// g_rand_double: uniform in [0, 1).
        mutating func double() -> Double { Double.random(in: 0..<1, using: &g) }
        mutating func boolean() -> Bool { Bool.random(using: &g) }
        /// rnd (test-blend.c:237-242): lo + [0, 1) * (hi - lo).
        mutating func rnd(_ lo: Double, _ hi: Double) -> Double { lo + double() * (hi - lo) }
    }

    /// fuzz_ids (test-blend.c:244-254).
    static let fuzzIDs: [(src: String, model: String)] = [
        ("nws", "nws"), ("open-meteo", "hrrr"), ("open-meteo", "nbm"), ("open-meteo", "ecmwf"), ("open-meteo", "gfs"),
        ("open-meteo", "icon"), ("open-meteo", "gem"), ("open-meteo", "ukmo"), ("open-meteo", "meteofrance"),
        ("met-no", "ecmwf"), ("other", "x1"), ("other", "x2"),
    ]

    /// reference_median (test-blend.c:367-393): every value repeated by its integer weight, sorted,
    /// the middle one or the mean of the two middle ones.
    static func referenceMedian(_ v: [Double], _ w: [Int]) -> Double {
        var list: [Double] = []
        for (x, c) in zip(v, w) where c > 0 {
            list.append(contentsOf: repeatElement(x, count: c))
        }
        if list.isEmpty {
            return .nan
        }
        for i in 1..<max(1, list.count) {
            let x = list[i]
            var j = i
            while j > 0 && list[j - 1] > x {
                list[j] = list[j - 1]
                j -= 1
            }
            list[j] = x
        }
        let n = list.count
        return n % 2 == 1 ? list[n / 2] : (list[n / 2 - 1] + list[n / 2]) / 2
    }
}
