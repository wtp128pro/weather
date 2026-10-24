// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DailyTests.swift - port of the /blend/daily/* cases of
// src/blend/test-blend.c (registered at src/blend/test-blend.c:5550 and
// :5554-5568). Expected values are the C test literals, cited as
// test-blend.c:LINE. The zone sweeps keep their oracle (the first instant of
// the local date, scanned back minute by minute) with Foundation's offsets
// in place of GLib's.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct DailyTests {
    /// 2026-10-11T00:00:00Z (T0, test-blend.c:26).
    static let t0: Int64 = 1_791_676_800
    static let h: Int64 = 3600
    /// 2026-10-11T12:37:00Z (NOW_S, test-blend.c:29).
    static let nowS: Int64 = t0 + 12 * h + 37 * 60
    /// 2026-10-12T00:00 EDT (MIAMI_M, test-blend.c:3696).
    static let miamiM: Int64 = 1_791_777_600

    /// daily_hours (test-blend.c:3071-3081): 15 degC, dry, 10 %, 50 % cloud,
    /// night, one member; `fn` adjusts them.
    static func dailyHours(_ first: Int64, _ n: Int, _ fn: ((inout WxBlendHour, Int) -> Void)? = nil) -> [WxBlendHour] {
        (0..<n).map { i in
            var b = WxBlendHour(
                tS: first + Int64(i) * h, tempC: 15, feelsC: 15, precipMm: 0.0, precipMmMax: 0.0, precipProb: 10,
                cloudPct: 50, nMembers: 1, condition: .partlyCloudy, isDay: false)
            fn?(&b, i)
            return b
        }
    }

    /// days_of_at (test-blend.c:3084-3098): the days, checked to ascend.
    static func daysOfAt(
        _ tz: String?, _ hours: [WxBlendHour], _ now: Int64, sourceLocation: SourceLocation = #_sourceLocation
    ) -> [WxDay] {
        let d = WxDaily.build(timezone: tz, hours: hours, nowS: now)
        #expect(d.count <= WxDaily.maxDays, sourceLocation: sourceLocation)
        for i in d.indices.dropFirst() {
            #expect(d[i].startS > d[i - 1].startS, sourceLocation: sourceLocation)
        }
        return d
    }

    /// days_of (test-blend.c:3101-3114): "now" long before every hour.
    static func daysOf(_ tz: String?, _ hours: [WxBlendHour], sourceLocation: SourceLocation = #_sourceLocation) -> [WxDay] {
        daysOfAt(tz, hours, WxLimits.timeMinS, sourceLocation: sourceLocation)
    }

    /// fill_pattern (test-blend.c:3135-3145).
    static func fillPattern(_ b: inout WxBlendHour, _ i: Int) {
        let lh = i % 24, di = i / 24
        b.tempC = Double(10 + lh + 2 * di)
        b.precipMm = 0.02
        b.precipProb = Double(lh * 4)
        b.cloudPct = Double(lh * 4)
        b.isDay = lh >= 7 && lh <= 18
    }

    /// fill_one_mm (test-blend.c:3219-3227).
    static func fillOneMm(_ b: inout WxBlendHour, _ i: Int) {
        b.precipMm = 1.0
        b.precipProb = 10
        b.cloudPct = .nan
        b.tempC = 10
    }

    // C: /blend/daily/basic (test-blend.c:3150-3172)
    @Test("/blend/daily/basic") func basic() {
        let first: Int64 = 1_791_777_600  // test-blend.c:3154
        let a = Self.dailyHours(first, 72, Self.fillPattern)
        var d = Self.daysOf("America/New_York", a)
        #expect(d.count == 3)
        for i in 0..<min(3, d.count) {
            #expect(d[i].startS == first + Int64(i) * 86400)  // test-blend.c:3160
            expectNear(d[i].tempMaxC, 33.0 + 2 * Double(i), eps: 1e-9)
            expectNear(d[i].tempMinC, 10.0 + 2 * Double(i), eps: 1e-9)
            expectNear(d[i].precipMm, 0.48, eps: 1e-9)
            expectNear(d[i].precipProbMax, 92.0, eps: 1e-9)
            expectNear(d[i].cloudPct, 50.0, eps: 1e-9)  // test-blend.c:3165
            #expect(d[i].condition == .partlyCloudy)
        }
        d = Self.daysOf("UTC", a)
        #expect(d.count == 3)
        #expect(d.first?.startS == 1_791_763_200)  // test-blend.c:3171
    }

    // C: /blend/daily/covered-hours (test-blend.c:3175-3216)
    @Test("/blend/daily/covered-hours") func coveredHours() {
        let midnight: Int64 = 1_791_777_600
        let h = Self.h
        for extra in 10...13 {
            let n = Self.daysOf("America/New_York", Self.dailyHours(midnight, 24 + extra)).count
            #expect(n == (extra >= WxDaily.minHours ? 2 : 1), "extra \(extra)")
        }
        // the first day may be partial (test-blend.c:3186-3191)
        var d = Self.daysOf("America/New_York", Self.dailyHours(midnight + 12 * h, 12))
        #expect(d.count == 1)
        #expect(d.first?.startS == midnight)
        #expect(Self.daysOf("America/New_York", Self.dailyHours(midnight + 13 * h, 11)).isEmpty)
        // only hours with a member count as covered (test-blend.c:3192-3199)
        for uncovered in 11...13 {
            var a = Self.dailyHours(midnight, 48)
            for i in 24..<(24 + uncovered) {
                a[i].nMembers = 0
            }
            #expect(Self.daysOf("America/New_York", a).count == (24 - uncovered >= WxDaily.minHours ? 2 : 1))
        }
        // a skipped day does not stop the next one (test-blend.c:3200-3204)
        d = Self.daysOf("America/New_York", Self.dailyHours(midnight + 13 * h, 11 + 24 + 12))
        #expect(d.count == 2)
        #expect(d.map(\.startS) == [midnight + 86400, midnight + 2 * 86400])
        // at most WX_DAILY_MAX_DAYS days, the earliest (test-blend.c:3206-3210)
        d = Self.daysOf("America/New_York", Self.dailyHours(midnight, 14 * 24))
        #expect(d.count == WxDaily.maxDays)
        #expect(d.first?.startS == midnight)
        #expect(d.last?.startS == midnight + 9 * 86400)
        // the largest accepted hour count, and no hours (test-blend.c:3211-3215)
        #expect(Self.daysOf("America/New_York", Self.dailyHours(midnight, WxLimits.forecastMaxHours)).count == WxDaily.maxDays)
        #expect(Self.daysOf("America/New_York", []).isEmpty)
    }

    // C: /blend/daily/today (test-blend.c:3800-3842)
    @Test("/blend/daily/today") func today() {
        let m = Self.miamiM, h = Self.h
        for left in 1...11 {
            let first = m + Int64(24 - left) * h
            let a = Self.dailyHours(first, left)
            let d = Self.daysOfAt("America/New_York", a, first + 60)
            #expect(d.count == 1, "left \(left)")
            #expect(d.first?.startS == m)
            #expect(Self.daysOf("America/New_York", a).isEmpty)
            #expect(Self.daysOfAt("America/New_York", a, m - 3600).isEmpty)
            #expect(Self.daysOfAt("America/New_York", a, m + 86400).isEmpty)
        }
        // an uncovered today is not listed (test-blend.c:3817-3823)
        var u = Self.dailyHours(m + 20 * h, 4 + 24 + 12)
        for i in 0..<4 {
            u[i].nMembers = 0
        }
        var d = Self.daysOfAt("America/New_York", u, m + 20 * h + 60)
        #expect(d.map(\.startS) == [m + 86400, m + 2 * 86400])
        // the one hour of yesterday is no day (test-blend.c:3824-3829)
        let o = Self.dailyHours(m - h, 1 + 24 + 12)
        d = Self.daysOfAt("America/New_York", o, m + 30 * 60)
        #expect(d.map(\.startS) == [m, m + 86400])
        // until the last second of yesterday it is yesterday that is today (test-blend.c:3830-3833)
        d = Self.daysOfAt("America/New_York", o, m - 1)
        #expect(d.count == 3)
        #expect(Array(d.prefix(2).map(\.startS)) == [m - 86400, m])
        // the ends of the time range are accepted as "now" (test-blend.c:3834-3837)
        let e = Self.dailyHours(Self.t0, 24)
        #expect(Self.daysOfAt("UTC", e, WxLimits.timeMinS).count == 1)
        #expect(Self.daysOfAt("UTC", e, WxLimits.timeMaxS - 1).count == 1)
        // at most ten days (test-blend.c:3838-3841)
        d = Self.daysOfAt("America/New_York", Self.dailyHours(m, 12 * 24), m + 30 * 60)
        #expect(d.count == WxDaily.maxDays)
        #expect(d.first?.startS == m)
        #expect(d.last?.startS == m + 9 * 86400)
    }

    /// assert_dst_days (test-blend.c:3231-3243).
    static func expectDSTDays(
        _ tz: String, _ first: Int64, _ n: Int, _ starts: [Int64], _ sums: [Double],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let d = daysOf(tz, dailyHours(first, n, fillOneMm), sourceLocation: sourceLocation)
        #expect(d.map(\.startS) == starts, "\(tz)", sourceLocation: sourceLocation)
        for i in 0..<min(d.count, sums.count) {
            expectNear(d[i].precipMm, sums[i], eps: 1e-9, "\(tz) day \(i)", sourceLocation: sourceLocation)
        }
    }

    // C: /blend/daily/dst (test-blend.c:3246-3284)
    @Test("/blend/daily/dst") func dst() {
        let s25: [Double] = [24, 25, 24, 12], s23: [Double] = [24, 23, 24, 12]
        // test-blend.c:3253-3271
        Self.expectDSTDays("America/New_York", 1_793_419_200, 85, [1_793_419_200, 1_793_505_600, 1_793_595_600, 1_793_682_000], s25)
        Self.expectDSTDays("America/New_York", 1_772_859_600, 83, [1_772_859_600, 1_772_946_000, 1_773_028_800, 1_773_115_200], s23)
        Self.expectDSTDays("Europe/London", 1_792_796_400, 85, [1_792_796_400, 1_792_882_800, 1_792_972_800, 1_793_059_200], s25)
        Self.expectDSTDays("Australia/Sydney", 1_790_949_600, 83, [1_790_949_600, 1_791_036_000, 1_791_118_800, 1_791_205_200], s23)
        Self.expectDSTDays("America/Havana", 1_772_859_600, 83, [1_772_859_600, 1_772_946_000, 1_773_028_800, 1_773_115_200], s23)
        Self.expectDSTDays("America/Havana", 1_793_419_200, 85, [1_793_419_200, 1_793_505_600, 1_793_595_600, 1_793_682_000], s25)
        // an hour belongs to the day of its instant (test-blend.c:3273-3283)
        var a = Self.dailyHours(1_793_419_200, 85, Self.fillOneMm)
        a[24 + 24].tempC = 40
        a[24 + 25].tempC = 41
        #expect(a[48].tS == 1_793_595_600 - Self.h)
        let d = Self.daysOf("America/New_York", a)
        #expect(d.count == 4)
        if d.count == 4 {
            expectNear(d[1].tempMaxC, 40.0, eps: 1e-9)
            expectNear(d[2].tempMaxC, 41.0, eps: 1e-9)
            expectNear(d[0].tempMaxC, 10.0, eps: 1e-9)
        }
    }

    // C: /blend/daily/zones-invalid-names (test-blend.c:3287-3345). Not
    // ported: the TZ environment rows (test-blend.c:3315-3323; tests never
    // setenv TZ, and WxDaily never reads TimeZone.current) and the two
    // guard-page rows' memory layout (a 65-byte name without a terminator is
    // kept as bytes; the hour-array guard page is not representable).
    @Test("/blend/daily/zones-invalid-names") func zonesAndInvalidNames() {
        let t0 = Self.t0
        let a = Self.dailyHours(t0, 72, Self.fillPattern)
        let ref = Self.daysOf("UTC", a)
        #expect(ref.count == 3)
        #expect(ref.first?.startS == t0)
        #expect(ref.last?.startS == t0 + 2 * 86400)
        let etc = Self.daysOf("Etc/UTC", a)
        #expect(etc.count == 3)
        #expect(etc.dropFirst().first?.startS == t0 + 86400)
        // test-blend.c:3302-3305
        let longName = String(repeating: "a", count: WxLimits.placeTimezoneMax + 1)
        let bad: [String?] = [
            nil, "", "Nope/Zone", "Foo", "/etc/passwd", "/usr/share/zoneinfo/UTC", "../../etc/passwd", "..", ".", "/",
            "America/New_York/", "America//New_York", "America/New York", "-", "+05:00", "UTC+0:00",
            "America/./New_York", "a\nb", "Z", "/dev/zero", "America/New_York\n", longName,
        ]
        for name in bad {
            let d = Self.daysOf(name, a)
            #expect(d.map(\.startS) == ref.map(\.startS), "\(String(describing: name))")
        }
        // "\xff\xfe" (test-blend.c:3305) and the unterminated 65-byte name (test-blend.c:3325-3334)
        for bytes in [[0xFF, 0xFE] as [UInt8], [UInt8](repeating: 0x61, count: WxLimits.placeTimezoneMax + 1)] {
            let d = WxDaily.build(timezoneBytes: bytes, hours: a, nowS: WxLimits.timeMinS)
            #expect(d.map(\.startS) == ref.map(\.startS))
        }
        // a name with '/' is resolved (test-blend.c:3321-3322)
        let ny = Self.daysOf("America/New_York", a)
        #expect(ny.count == 3)
        #expect(ny.first?.startS == t0 + 4 * Self.h)
        // the hour array is read only up to its count (test-blend.c:3337-3344)
        #expect(Self.daysOf("UTC", Self.dailyHours(t0, 12)).count == 1)
    }

    /// fill_unknowns (test-blend.c:3348-3357).
    static func fillUnknowns(_ b: inout WxBlendHour, _ i: Int) {
        b.tempC = .nan
        b.precipMm = .nan
        b.precipProb = .nan
        b.cloudPct = .nan
        b.condition = .unknown
    }

    /// fill_aggregates (test-blend.c:3359-3370).
    static func fillAggregates(_ b: inout WxBlendHour, _ i: Int) {
        b.tempC = (i % 3 == 0) ? .nan : Double(i) - 5.0
        b.precipMm = (i % 4 == 0) ? .nan : 0.1 * Double(i)
        b.precipProb = (i % 5 == 0) ? .nan : 3.0 * Double(i)
        b.isDay = i >= 6 && i < 18
        b.cloudPct = (i == 7) ? .nan : (b.isDay ? 10.0 : 100.0)
    }

    // C: /blend/daily/aggregates (test-blend.c:3373-3430)
    @Test("/blend/daily/aggregates") func aggregates() throws {
        var d = Self.daysOf("UTC", Self.dailyHours(Self.t0, 24, Self.fillUnknowns))
        try #require(d.count == 1)
        expectNaN(d[0].tempMaxC)
        expectNaN(d[0].tempMinC)
        expectNaN(d[0].precipMm)
        expectNaN(d[0].precipProbMax)
        expectNaN(d[0].cloudPct)
        #expect(d[0].condition == .unknown)

        d = Self.daysOf("UTC", Self.dailyHours(Self.t0, 24, Self.fillAggregates))
        try #require(d.count == 1)
        expectNear(d[0].tempMaxC, 18.0, eps: 1e-9)  // test-blend.c:3389
        expectNear(d[0].tempMinC, -4.0, eps: 1e-9)
        var sum = 0.0  // test-blend.c:3392-3397 (the oracle sum of the C test)
        for i in 0..<24 where i % 4 != 0 {
            sum += 0.1 * Double(i)
        }
        expectNear(d[0].precipMm, sum, eps: 1e-9)
        expectNear(d[0].precipProbMax, 69.0, eps: 1e-9)
        expectNear(d[0].cloudPct, 10.0, eps: 1e-9)
        #expect(d[0].condition == .showers)  // test-blend.c:3404

        // polar night (test-blend.c:3406-3415)
        var n = Self.dailyHours(Self.t0, 24)
        for i in 0..<24 {
            n[i].isDay = false
            n[i].cloudPct = (i % 2 != 0) ? 20.0 : 40.0
        }
        d = Self.daysOf("UTC", n)
        try #require(d.count == 1)
        expectNear(d[0].cloudPct, 30.0, eps: 1e-9)  // test-blend.c:3413
        #expect(d[0].condition == .mostlyClear)
        // daylight hours without a cloud value (test-blend.c:3416-3421)
        for i in 0..<24 {
            n[i].isDay = i < 12
            n[i].cloudPct = i < 12 ? .nan : 80.0
        }
        d = Self.daysOf("UTC", n)
        try #require(d.count == 1)
        expectNear(d[0].cloudPct, 80.0, eps: 1e-9)  // test-blend.c:3421
        // daylight clouds only count by day (test-blend.c:3422-3429)
        for i in 0..<24 {
            n[i].isDay = i >= 6 && i < 18
            n[i].cloudPct = n[i].isDay ? 0.0 : 100.0
        }
        d = Self.daysOf("UTC", n)
        try #require(d.count == 1)
        expectNear(d[0].cloudPct, 0.0, eps: 1e-9)
        #expect(d[0].condition == .clear)
    }

    /// Mark and CondDay (test-blend.c:3432-3446).
    struct Mark {
        var cond: WxCondition
        var from: Int
        var to: Int
        var prob: Double
    }

    struct CondDay {
        var marks: [Mark]
        var cloud: Double
        var precip: Double
        var prob: Double
        var rateHour: Int
        var rate: Double
    }

    /// fill_cond_day (test-blend.c:3448-3463).
    static func fill(_ c: CondDay) -> (inout WxBlendHour, Int) -> Void {
        { b, i in
            b.isDay = true
            b.cloudPct = c.cloud
            b.precipMm = c.precip
            b.precipProb = c.prob
            if i == c.rateHour {
                b.precipMm = c.rate
            }
            for m in c.marks where i >= m.from && i < m.to {
                b.condition = m.cond
                b.precipProb = m.prob
            }
        }
    }

    /// day_condition (test-blend.c:3465-3473).
    static func dayCondition(_ c: CondDay, sourceLocation: SourceLocation = #_sourceLocation) -> WxCondition? {
        let d = daysOf("UTC", dailyHours(t0, 24, fill(c)), sourceLocation: sourceLocation)
        #expect(d.count == 1, sourceLocation: sourceLocation)
        return d.first?.condition
    }

    // C: /blend/daily/conditions-severe (test-blend.c:3476-3535)
    @Test("/blend/daily/conditions-severe") func conditionsSevere() {
        func day(_ marks: [Mark], _ cloud: Double = 20, _ precip: Double = 0, _ prob: Double = 10) -> CondDay {
            CondDay(marks: marks, cloud: cloud, precip: precip, prob: prob, rateHour: -1, rate: 0)
        }
        // two consecutive hours (test-blend.c:3478-3487)
        #expect(Self.dayCondition(day([Mark(cond: .thunderstorm, from: 10, to: 12, prob: 10)])) == .thunderstorm)
        #expect(Self.dayCondition(day([Mark(cond: .snow, from: 3, to: 5, prob: 10)])) == .snow)
        #expect(Self.dayCondition(day([Mark(cond: .sleet, from: 22, to: 24, prob: 10)])) == .sleet)
        // a single hour needs 40 % (test-blend.c:3489-3500)
        for cls in [WxCondition.thunderstorm, .snow, .sleet] {
            #expect(Self.dayCondition(day([Mark(cond: cls, from: 10, to: 11, prob: 39.99)])) == .mostlyClear)
            #expect(Self.dayCondition(day([Mark(cond: cls, from: 10, to: 11, prob: 40.0)])) == cls)
            #expect(Self.dayCondition(day([Mark(cond: cls, from: 10, to: 11, prob: 100.0)])) == cls)
            #expect(Self.dayCondition(day([Mark(cond: cls, from: 10, to: 11, prob: .nan)])) == .mostlyClear)
        }
        // not consecutive (test-blend.c:3502-3505)
        let apart = day([Mark(cond: .thunderstorm, from: 10, to: 11, prob: 10), Mark(cond: .thunderstorm, from: 12, to: 13, prob: 10)])
        #expect(Self.dayCondition(apart) == .mostlyClear)
        // adjacent in the array but an hour apart in time (test-blend.c:3506-3511)
        var gap = Self.dailyHours(Self.t0, 24, Self.fill(apart))
        gap.remove(at: 11)
        let g = Self.daysOf("UTC", gap)
        #expect(g.count == 1)
        #expect(g.first?.condition == .mostlyClear)
        // split by midnight (test-blend.c:3512-3518)
        let two = Self.daysOf("UTC", Self.dailyHours(Self.t0, 48, Self.fill(day([Mark(cond: .thunderstorm, from: 23, to: 25, prob: 10)]))))
        #expect(two.map(\.condition) == [.mostlyClear, .mostlyClear])
        // priority (test-blend.c:3520-3531)
        let ts = [
            Mark(cond: .thunderstorm, from: 2, to: 4, prob: 10), Mark(cond: .snow, from: 6, to: 8, prob: 10),
            Mark(cond: .sleet, from: 10, to: 12, prob: 10),
        ]
        #expect(Self.dayCondition(day(ts)) == .thunderstorm)
        #expect(Self.dayCondition(day(Array(ts[1...]))) == .snow)
        #expect(Self.dayCondition(day(Array(ts[2...]))) == .sleet)
        let weak = [Mark(cond: .thunderstorm, from: 2, to: 3, prob: 10), Mark(cond: .snow, from: 6, to: 8, prob: 10)]
        #expect(Self.dayCondition(day(weak)) == .snow)
        // a severe class beats a rainy day (test-blend.c:3532-3534)
        #expect(Self.dayCondition(day([Mark(cond: .sleet, from: 2, to: 4, prob: 10)], 100.0, 1.0, 90.0)) == .sleet)
    }

    // C: /blend/daily/conditions-rain-cloud (test-blend.c:3538-3590)
    @Test("/blend/daily/conditions-rain-cloud") func conditionsRainAndCloud() {
        var c = CondDay(marks: [], cloud: 50.0, precip: 0.05, prob: 50.0, rateHour: -1, rate: 0)
        #expect(Self.dayCondition(c) == .showers)  // test-blend.c:3542
        c.cloud = 100.0
        #expect(Self.dayCondition(c) == .drizzle)
        c.rateHour = 5
        c.rate = 0.5
        #expect(Self.dayCondition(c) == .lightRain)
        c.rate = 2.5
        #expect(Self.dayCondition(c) == .rain)
        c.rate = 7.6
        #expect(Self.dayCondition(c) == .heavyRain)
        c.cloud = 50.0
        c.rate = 7.5
        #expect(Self.dayCondition(c) == .showers)
        c.rate = 7.6
        #expect(Self.dayCondition(c) == .heavyRain)
        c.cloud = 87.5
        c.rate = 3.0
        #expect(Self.dayCondition(c) == .rain)  // test-blend.c:3558
        // the thresholds: 1 mm and 50 % (test-blend.c:3560-3570)
        c = CondDay(marks: [], cloud: 100.0, precip: 0.0, prob: 50.0, rateHour: 3, rate: 0.99)
        #expect(Self.dayCondition(c) == .overcast)
        c.rate = 1.0
        #expect(Self.dayCondition(c) == .lightRain)
        c.prob = 49.99
        #expect(Self.dayCondition(c) == .overcast)
        c.prob = .nan
        #expect(Self.dayCondition(c) == .overcast)
        c.prob = 50.0
        c.cloud = 0.0
        #expect(Self.dayCondition(c) == .showers)
        // a dry day: the cloud words (test-blend.c:3576-3581)
        let words: [(Double, WxCondition)] = [
            (0, .clear), (12.49, .clear), (12.5, .mostlyClear), (37.49, .mostlyClear), (37.5, .partlyCloudy),
            (62.49, .partlyCloudy), (62.5, .mostlyCloudy), (87.49, .mostlyCloudy), (87.5, .overcast), (100, .overcast),
            (.nan, .unknown),
        ]
        for (cloud, cond) in words {
            #expect(Self.dayCondition(CondDay(marks: [], cloud: cloud, precip: 0.0, prob: 10.0, rateHour: -1, rate: 0)) == cond, "cloud \(cloud)")
        }
        // lots of rain but a low probability (test-blend.c:3587-3589)
        #expect(Self.dayCondition(CondDay(marks: [], cloud: 100.0, precip: 1.0, prob: 20.0, rateHour: -1, rate: 0)) == .overcast)
    }

    // C: /blend/daily/range-and-criticals (test-blend.c:3593-3644). The NULL
    // days / NULL hours rows are not representable; "nothing written" is the
    // empty result.
    @Test("/blend/daily/range-and-criticals") func timeRangeAndCriticals() {
        let h = Self.h
        let a = Self.dailyHours(WxLimits.timeMinS, 48)
        var d = Self.daysOf("Etc/GMT+12", a)
        #expect(d.map(\.startS) == [WxLimits.timeMinS + 12 * h, WxLimits.timeMinS + 36 * h])  // test-blend.c:3600-3602
        d = Self.daysOf("UTC", a)
        #expect(d.count == 2)
        #expect(d.first?.startS == WxLimits.timeMinS)
        #expect(Self.daysOf("UTC", Self.dailyHours(WxLimits.timeMaxS - 12 * h, 12)).count == 1)  // test-blend.c:3607-3609
        // programmer errors: nothing returned (test-blend.c:3616-3633)
        let ok = Self.dailyHours(Self.t0, 24)
        #expect(WxDaily.build(timezone: "UTC", hours: Self.dailyHours(Self.t0, WxLimits.forecastMaxHours + 1), nowS: Self.t0).isEmpty)
        var bad = Self.dailyHours(Self.t0, 24)
        bad[5].tS = bad[4].tS
        #expect(WxDaily.build(timezone: "UTC", hours: bad, nowS: Self.t0).isEmpty)
        bad[5].tS = bad[4].tS - h
        #expect(WxDaily.build(timezone: "UTC", hours: bad, nowS: Self.t0).isEmpty)
        bad[5].tS = bad[4].tS + 1800
        #expect(WxDaily.build(timezone: "UTC", hours: bad, nowS: Self.t0).isEmpty)
        bad[5].tS = bad[4].tS + h
        bad[0].tS = WxLimits.timeMinS - h
        #expect(WxDaily.build(timezone: "UTC", hours: bad, nowS: Self.t0).isEmpty)
        bad[0].tS = WxLimits.timeMaxS
        #expect(WxDaily.build(timezone: "UTC", hours: Array(bad.prefix(1)), nowS: Self.t0).isEmpty)
        for now in [WxLimits.timeMinS - 1, WxLimits.timeMaxS, Int64.min, Int64.max, 0, -1] {  // test-blend.c:3632
            #expect(WxDaily.build(timezone: "UTC", hours: ok, nowS: now).isEmpty, "now \(now)")
        }
        #expect(WxDaily.build(timezone: "UTC", hours: ok, nowS: Self.t0).count == 1)  // test-blend.c:3642
    }

    /// assert_day_starts (test-blend.c:4284-4297).
    static func expectDayStarts(
        _ tz: String, _ first: Int64, _ n: Int, _ starts: [Int64], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let d = daysOf(tz, dailyHours(first, n), sourceLocation: sourceLocation)
        #expect(d.map(\.startS) == starts, "\(tz)", sourceLocation: sourceLocation)
    }

    // C: /blend/daily/first-midnight (test-blend.c:4300-4317)
    @Test("/blend/daily/first-midnight") func firstMidnight() {
        // test-blend.c:4307-4316
        Self.expectDayStarts("America/St_Johns", 1_194_004_800, 120, [1_193_970_600, 1_194_057_000, 1_194_143_400, 1_194_233_400, 1_194_319_800])
        Self.expectDayStarts("America/Goose_Bay", 1_194_004_800, 120, [1_193_972_400, 1_194_058_800, 1_194_145_200, 1_194_235_200, 1_194_321_600])
        Self.expectDayStarts("America/Moncton", 1_161_864_000, 120, [1_161_831_600, 1_161_918_000, 1_162_004_400, 1_162_090_800, 1_162_180_800])
        Self.expectDayStarts("America/Sao_Paulo", 1_455_796_800, 120, [1_455_760_800, 1_455_847_200, 1_455_933_600, 1_456_023_600, 1_456_110_000])
    }

    /// first_instant_back_scan (test-blend.c:4323-4337) on Foundation offsets.
    static func firstInstantBackScan(_ tz: TimeZone, _ start: Int64) -> Int64 {
        func offset(_ t: Int64) -> Int64 { Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t)))) }
        let date = (start + offset(start)) / 86400
        var first = start
        var t = start - 60
        while t > start - 2 * 86400 {
            if (t + offset(t)) / 86400 == date {
                first = t
            }
            t -= 60
        }
        return first
    }

    /// sweep_zone (test-blend.c:4340-4365); returns the number of failures.
    static func sweepZone(_ name: String, _ firsts: [Int64]) -> [String] {
        guard let tz = TimeZone(identifier: name),
            let place = try? WxPlace(name: "Testville", admin1: "Region", country: "Country", countryCode: "US", lat: 0, lon: 0, timezone: name)
        else {
            return []  // the database of this machine lacks it
        }
        var failures: [String] = []
        for first in firsts {
            let a = dailyHours(first, 120)
            let d = WxDaily.build(timezone: name, hours: a, nowS: WxLimits.timeMinS)
            if d.count < 3 {
                failures.append("\(name) from \(first): \(d.count) days")
            }
            for (i, day) in d.enumerated() {
                if i > 0 && day.startS <= d[i - 1].startS {
                    failures.append("\(name) from \(first): day \(i) does not ascend")
                }
                let want = firstInstantBackScan(tz, day.startS)
                if day.startS != want {
                    failures.append("\(name) from \(first): day \(i) starts \(day.startS), the first instant of its date is \(want)")
                }
            }
            if (try? WxForecast(place: place, generatedS: first, hours: a, days: d)) == nil {
                failures.append("\(name) from \(first): wx_forecast_new refuses the days")
            }
        }
        return failures
    }

    /// sweep_zones (test-blend.c:4367-4376).
    static let sweepZones = [
        "America/St_Johns", "America/Goose_Bay", "America/Moncton", "America/Halifax", "America/Havana",
        "America/Sao_Paulo", "America/Asuncion", "America/Santiago", "America/Miami", "America/New_York",
        "America/Los_Angeles", "America/Anchorage", "America/Caracas", "America/Godthab", "America/Scoresbysund",
        "Pacific/Honolulu", "Pacific/Apia", "Pacific/Kiritimati", "Pacific/Chatham", "Pacific/Auckland",
        "Pacific/Norfolk", "Pacific/Tongatapu", "Pacific/Fiji", "Pacific/Pago_Pago", "Australia/Lord_Howe",
        "Australia/Adelaide", "Australia/Eucla", "Australia/Sydney", "Asia/Kolkata", "Asia/Kathmandu",
        "Asia/Tehran", "Asia/Beirut", "Asia/Gaza", "Asia/Pyongyang", "Asia/Tokyo", "Africa/Cairo",
        "Africa/Casablanca", "Africa/Windhoek", "Europe/London", "Europe/Dublin", "Europe/Moscow",
        "Europe/Istanbul", "Antarctica/Troll", "Etc/GMT+12", "Etc/GMT-14", "Atlantic/Azores",
    ]

    // C: /blend/daily/zone-sweep (test-blend.c:4379-4395)
    @Test("/blend/daily/zone-sweep") func zoneSweep() {
        // test-blend.c:4382-4392
        let firsts: [Int64] = [
            1_194_004_800, 1_161_864_000, 1_455_796_800, 1_445_000_000 - 1_445_000_000 % 3600, 1_793_419_200,
            1_772_859_600, 1_791_676_800, 1_790_000_000 - 1_790_000_000 % 3600, 1_325_203_200, 1_230_768_000,
        ]
        var failures: [String] = []
        for zone in Self.sweepZones {
            failures += Self.sweepZone(zone, firsts)
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    // C: /blend/daily/zone-sweep-all (test-blend.c:4399-4425): every zone of
    // tzdata.zi with a '/' (Z and L lines), as in C.
    @Test("/blend/daily/zone-sweep-all") func zoneSweepAll() throws {
        let zi = try String(contentsOfFile: "/usr/share/zoneinfo/tzdata.zi", encoding: .utf8)
        let firsts: [Int64] = [1_194_004_800, 1_161_864_000, 1_455_796_800, 1_793_419_200, 1_772_859_600]  // test-blend.c:4407
        var count = 0
        var failures: [String] = []
        for line in zi.split(separator: "\n", omittingEmptySubsequences: false) {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            var name: Substring?
            if f.count >= 2 && f[0] == "Z" {
                name = f[1].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first
            } else if f.count >= 3 && f[0] == "L" {
                name = f[2][...]
            }
            if let name, name.contains("/") {
                failures += Self.sweepZone(String(name), firsts)
                count += 1
            }
        }
        #expect(count > 300)  // test-blend.c:4422
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    // C: /blend/daily/day-sum-clamp (test-blend.c:4469-4505)
    @Test("/blend/daily/day-sum-clamp") func daySumClamp() throws {
        let h = Self.h
        let first: Int64 = 1_793_505_600 - 24 * h
        var a = Self.dailyHours(first, 24 + 25 + 24)
        for i in a.indices {
            a[i].precipMm = 500.0
            a[i].precipMmMax = 500.0
            a[i].precipProb = 100.0
        }
        let d = Self.daysOf("America/New_York", a)
        try #require(d.count == 3)
        #expect(d[1].startS == 1_793_505_600)
        #expect(d[2].startS == 1_793_505_600 + 25 * h)
        expectNear(d[0].precipMm, 12000.0, eps: 1e-9)  // test-blend.c:4486
        expectNear(d[1].precipMm, WxLimits.precipMaxMmDay, eps: 1e-9)
        #expect(d[1].condition == .heavyRain)
        // the forecast keeps the number and the condition (test-blend.c:4490-4499)
        let place = try WxPlace(
            name: "Testville", admin1: "Region", country: "Country", countryCode: "US", lat: 25.7617, lon: -80.1918,
            timezone: "America/New_York")
        let fc = try WxForecast(place: place, generatedS: Self.nowS, hours: a, days: d)
        try #require(fc.days.count == 3)
        #expect(fc.days[1].precipMm.isFinite)
        expectNear(fc.days[1].precipMm, WxLimits.precipMaxMmDay, eps: 1e-9)
        #expect(fc.days[1].condition == .heavyRain)
        // a 23 hour day below the cap is not touched (test-blend.c:4500-4504)
        var b = Self.dailyHours(1_772_946_000 - 24 * h, 24 + 23 + 24)
        for i in b.indices {
            b[i].precipMm = 500.0
        }
        let e = Self.daysOf("America/New_York", b)
        try #require(e.count == 3)
        expectNear(e[1].precipMm, 11500.0, eps: 1e-9)  // test-blend.c:4504
    }

    // C: /blend/daily/hostile-values (test-blend.c:4778-4808). Garbage
    // condition values outside the enum are not representable (WxCondition).
    @Test("/blend/daily/hostile-values") func hostileValues() {
        // test-blend.c:4783-4784
        let pool: [Double] = [
            .nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, -0.0, 0.0, 4.9e-324,
            1e300, -1e300, 100.0, -1.0, 500.0, 12.5, 87.5, 40.0, 50.0, 1.0,
        ]
        var rng = SeededRNG(seed: 1234)
        var failures = 0
        for iter in 0..<fuzzIterations(300) {
            let n = Int.random(in: 0...WxLimits.forecastMaxHours, using: &rng)
            let first = Self.t0 + Int64.random(in: -100..<100, using: &rng) * Self.h
            var hs: [WxBlendHour] = []
            for i in 0..<n {
                let temp = pool.randomElement(using: &rng)!
                let precip = pool.randomElement(using: &rng)!
                let prob = pool.randomElement(using: &rng)!
                let cloud = pool.randomElement(using: &rng)!
                hs.append(
                    WxBlendHour(
                        tS: first + Int64(i) * Self.h, tempC: temp, feelsC: temp, precipMm: precip, precipMmMax: precip,
                        precipProb: prob, cloudPct: cloud, nMembers: UInt8.random(in: 0...255, using: &rng),
                        condition: WxCondition.allCases.randomElement(using: &rng)!, isDay: Bool.random(using: &rng)))
            }
            let now = first + Int64.random(in: -10..<300, using: &rng) * Self.h
            let d = WxDaily.build(timezone: iter % 3 == 0 ? "America/New_York" : nil, hours: hs, nowS: now)
            var ok = d.count <= WxDaily.maxDays
            for i in d.indices.dropFirst() where d[i].startS <= d[i - 1].startS {
                ok = false
            }
            if !ok {
                failures += 1
            }
        }
        #expect(failures == 0)
    }

    /// UTC_DAY_START (test-blend.c:4869).
    static let utcDayStart: Int64 = 1_791_849_600

    // C: /blend/daily/timezone-rule (test-blend.c:4871-4936)
    @Test("/blend/daily/timezone-rule") func timezoneRule() {
        let u = Self.utcDayStart
        // test-blend.c:4880-4917
        let table: [(String?, Int64)] = [
            ("UTC", u), ("Etc/UTC", u), ("America/New_York", 1_791_777_600), ("Asia/Kolkata", 1_791_829_800),
            ("Australia/Lord_Howe", 1_791_810_000), ("Asia/Tokyo", 1_791_817_200), ("Etc/GMT-14", 1_791_799_200),
            ("Japan", u), ("Singapore", u), ("EST5EDT", u), ("Cuba", u), ("leapseconds", u), ("tzdata.zi", u),
            ("zone.tab", u), ("posixrules", u), ("localtime", u), ("GMT+5", u), ("Z", u), ("+05:00", u), ("", u),
            (nil, u), ("America/Nowhere", u), ("America/Argentina", u), ("asia/tokyo", u), ("Asia/Tokyo/", u),
            ("/Asia/Tokyo", u), ("/etc/passwd", u), ("../x", u), ("Asia/../Asia/Tokyo", u), ("Asia//Tokyo", u),
            ("Asia/Tokyo\n", u), ("Asia/Tok yo", u), ("Asia/\u{20AC}", u), ("-", u), ("1/2", u), ("a/.b", u),
        ]
        let tMid: Int64 = 1_791_849_600  // test-blend.c:4919
        let a = Self.dailyHours(Self.t0, 120)
        for (tz, want) in table {
            let d = Self.daysOf(tz, a)
            #expect(d.count >= 3, "\(String(describing: tz))")
            var got: Int64 = 0
            for day in d where day.startS <= tMid {
                got = day.startS
            }
            #expect(got == want, "zone '\(tz ?? "(null)")'")
        }
    }

    // PINNED DIFFERENCES (executor rows, not C literals): the platform zone
    // database is Foundation's (ICU), filtered by WxFormat.Zone.legacyICUTimezones.
    //  - Case: C on a case-insensitive APFS volume opens "asia/tokyo" (its own
    //    test row test-blend.c:4903 fails there); Swift keeps the contract
    //    ("names are case sensitive") and gives UTC.
    //  - ICU-only legacy names with a '/' that macOS' zoneinfo (2026e) lacks
    //    ("SystemV/AST4", "US/Pacific-New", etc.) are rejected and give UTC
    //    just as C does (DECISIONS #41).
    @Test("pinned: zone names are case sensitive; ICU-only legacy names fall back to UTC") func pinnedZoneDatabase() {
        let a = Self.dailyHours(Self.t0, 120)
        func dayOfMid(_ tz: String) -> Int64 {
            var got: Int64 = 0
            for day in Self.daysOf(tz, a) where day.startS <= Self.utcDayStart {
                got = day.startS
            }
            return got
        }
        for tz in ["asia/tokyo", "AMERICA/NEW_YORK", "america/new_york"] {
            #expect(dayOfMid(tz) == Self.utcDayStart, "\(tz)")  // test-blend.c:4869, :4903
        }
        for tz in WxFormat.Zone.legacyICUTimezones {
            #expect(dayOfMid(tz) == Self.utcDayStart, "\(tz)")
        }
    }
}
