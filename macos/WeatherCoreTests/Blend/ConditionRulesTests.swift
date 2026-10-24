// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ConditionRulesTests.swift - port of the /blend/condition/* cases of
// src/blend/test-blend.c (registered at src/blend/test-blend.c:5500-5506
// and :5551). Expected values are the C test literals, cited as
// test-blend.c:LINE.

import Testing
@testable import WeatherCore

@Suite struct ConditionRulesTests {
    /// DBL_MAX.
    static let dblMax = Double.greatestFiniteMagnitude

    /// derive (test-blend.c:714-718).
    static func derive(_ cloud: Double, _ prob: Double, _ mm: Double, _ temp: Double, _ votes: [Int] = []) -> WxCondition {
        WxConditionRules.derive(WxConditionInput(cloudPct: cloud, precipProb: prob, precipMmH: mm, tempC: temp, wmoVotes: votes))
    }

    // C: /blend/condition/cloud-label (test-blend.c:671-698)
    @Test("/blend/condition/cloud-label") func cloudLabel() {
        let cases: [(pct: Double, label: String, cond: WxCondition)] = [
            (0.0, "Clear", .clear),  // test-blend.c:678
            (12.499, "Clear", .clear),  // test-blend.c:679
            (12.5, "Mostly clear", .mostlyClear),  // test-blend.c:680
            (37.499, "Mostly clear", .mostlyClear),  // test-blend.c:681
            (37.5, "Partly cloudy", .partlyCloudy),  // test-blend.c:682
            (62.499, "Partly cloudy", .partlyCloudy),  // test-blend.c:683
            (62.5, "Mostly cloudy", .mostlyCloudy),  // test-blend.c:684
            (87.499, "Mostly cloudy", .mostlyCloudy),  // test-blend.c:685
            (87.5, "Overcast", .overcast),  // test-blend.c:686
            (100.0, "Overcast", .overcast),  // test-blend.c:687
            (-5.0, "Clear", .clear),  // test-blend.c:688
            (-.infinity, "Clear", .clear),  // test-blend.c:689
            (1000.0, "Overcast", .overcast),  // test-blend.c:690
            (.infinity, "Overcast", .overcast),  // test-blend.c:691
            (.nan, "Unknown", .unknown),  // test-blend.c:692
        ]
        for c in cases {
            #expect(WxConditionRules.cloudLabel(c.pct) == c.label, "pct \(c.pct)")  // test-blend.c:695
            #expect(WxConditionRules.cloudCondition(c.pct) == c.cond, "pct \(c.pct)")  // test-blend.c:696
        }
    }

    // C: /blend/condition/labels (test-blend.c:701-711). The out-of-range criticals
    // (:709-710, WX_COND_COUNT and -1) are GLIB-INTERNAL: no such WxCondition exists.
    @Test("/blend/condition/labels") func labels() {
        let labels = [
            "Unknown", "Clear", "Mostly clear", "Partly cloudy", "Mostly cloudy", "Overcast", "Fog",  // test-blend.c:704
            "Drizzle", "Light rain", "Rain", "Heavy rain", "Showers", "Thunderstorm", "Snow", "Sleet",  // test-blend.c:705
        ]
        #expect(labels.count == WxCondition.count)
        for c in 0..<WxCondition.count {  // test-blend.c:707
            let cond = WxCondition(rawValue: c)
            #expect(cond.map(WxConditionRules.label) == labels[c], "condition \(c)")  // test-blend.c:708
        }
        // the conditions the C criticals pass cannot be built in Swift
        #expect(WxCondition(rawValue: WxCondition.count) == nil)  // test-blend.c:709
        #expect(WxCondition(rawValue: -1) == nil)  // test-blend.c:710
    }

    // C: /blend/condition/wmo-rules (test-blend.c:721-752)
    @Test("/blend/condition/wmo-rules") func wmoRules() {
        let thunder = [95, 96, 97, 99], snow = [71, 73, 75, 77, 85, 86]  // test-blend.c:723
        let sleet = [56, 57, 66, 67], fog = [45, 48]  // test-blend.c:724
        for code in thunder {
            #expect(Self.derive(50, .nan, 0, 20, [code]) == .thunderstorm, "code \(code)")  // test-blend.c:727
        }
        for code in snow {
            #expect(Self.derive(50, .nan, 0, 2.0, [code]) == .snow, "code \(code)")  // test-blend.c:731
            #expect(Self.derive(50, .nan, 0, -10.0, [code]) == .snow, "code \(code)")  // test-blend.c:732
            // too warm for snow: falls through to the sky class
            #expect(Self.derive(50, .nan, 0, 2.01, [code]) == .partlyCloudy, "code \(code)")  // test-blend.c:734
            // unknown temperature fails the temperature test
            #expect(Self.derive(50, .nan, 0, .nan, [code]) == .partlyCloudy, "code \(code)")  // test-blend.c:736
        }
        for code in sleet {
            #expect(Self.derive(50, .nan, 0, 20, [code]) == .sleet, "code \(code)")  // test-blend.c:740
        }
        for code in fog {
            #expect(Self.derive(50, .nan, 0, 20, [code]) == .fog, "code \(code)")  // test-blend.c:744
        }
        // neighbouring codes are not in the sets
        let others = [0, 1, 3, 44, 46, 49, 55, 58, 65, 68, 70, 72, 76, 78, 84, 87, 94, 98]  // test-blend.c:747
        for code in others {
            #expect(Self.derive(50, .nan, 0, 0, [code]) == .partlyCloudy, "code \(code)")  // test-blend.c:750
        }
    }

    // C: /blend/condition/majority (test-blend.c:755-794)
    @Test("/blend/condition/majority") func majority() {
        // exactly 50 % of the codes counts; below does not
        #expect(Self.derive(0, .nan, 0, 20, [95, 0]) == .thunderstorm)  // test-blend.c:758-759
        #expect(Self.derive(0, .nan, 0, 20, [95, 0, 0]) == .clear)  // test-blend.c:760-761
        #expect(Self.derive(0, .nan, 0, 20, [45, 45, 3, 3]) == .fog)  // test-blend.c:762-763
        // negative codes do not take part in the count at all
        #expect(Self.derive(0, .nan, 0, 20, [-1, -1, -1, 95]) == .thunderstorm)  // test-blend.c:765-766
        #expect(Self.derive(0, .nan, 0, 20, [-1, -1]) == .clear)  // test-blend.c:767-768
        #expect(Self.derive(0, .nan, 0, 20, []) == .clear)  // test-blend.c:769 (C: NULL, 0)
        // a code beyond 99 supplies a code but belongs to no class
        #expect(Self.derive(0, .nan, 0, 20, [95, 150, 150]) == .clear)  // test-blend.c:771-772
        #expect(Self.derive(0, .nan, 0, 20, [95, 150]) == .thunderstorm)  // test-blend.c:773-774
        // priority: thunder > snow > sleet > fog > rain > sky; a class needs its own majority
        #expect(Self.derive(0, .nan, 0, 0, [95, 95, 71, 71]) == .thunderstorm)  // test-blend.c:776-777
        #expect(Self.derive(0, .nan, 0, 0, [71, 71, 56, 56]) == .snow)  // test-blend.c:778-779
        #expect(Self.derive(0, .nan, 0, 5, [71, 71, 56, 56]) == .sleet)  // test-blend.c:780
        #expect(Self.derive(0, .nan, 0, 0, [56, 56, 45, 45]) == .sleet)  // test-blend.c:781-782
        // a thunder code beats rain intensity
        #expect(Self.derive(100, 100, 20, 20, [96]) == .thunderstorm)  // test-blend.c:784-785
        // fog beats rain
        #expect(Self.derive(100, 100, 5, 20, [45]) == .fog)  // test-blend.c:787-788
        // many votes: the count arithmetic is exact (3 of 6 is half, 2 of 5 is not)
        #expect(Self.derive(0, .nan, 0, 20, [95, 95, 95, 0, 0, 0]) == .thunderstorm)  // test-blend.c:790-791
        #expect(Self.derive(0, .nan, 0, 20, [95, 95, 0, 0, 0]) == .clear)  // test-blend.c:792-793
    }

    // C: /blend/condition/wet-intensity (test-blend.c:797-842)
    @Test("/blend/condition/wet-intensity") func wetAndIntensity() {
        // wet = >= 0.1 mm and (probability unknown or >= 30 %)
        #expect(WxConditionRules.isWetHour(precipMm: 0.1, precipProb: .nan))  // test-blend.c:800
        #expect(WxConditionRules.isWetHour(precipMm: 0.1, precipProb: 30.0))  // test-blend.c:801
        #expect(!WxConditionRules.isWetHour(precipMm: 0.1, precipProb: 29.999))  // test-blend.c:802
        #expect(!WxConditionRules.isWetHour(precipMm: 0.0999, precipProb: .nan))  // test-blend.c:803
        #expect(!WxConditionRules.isWetHour(precipMm: 0.0999, precipProb: 100.0))  // test-blend.c:804
        #expect(!WxConditionRules.isWetHour(precipMm: .nan, precipProb: 100.0))  // test-blend.c:805
        #expect(!WxConditionRules.isWetHour(precipMm: .nan, precipProb: .nan))  // test-blend.c:806
        #expect(WxConditionRules.isWetHour(precipMm: 50.0, precipProb: 0.0 + 30.0))  // test-blend.c:807
        #expect(!WxConditionRules.isWetHour(precipMm: -1.0, precipProb: .nan))  // test-blend.c:808
        #expect(WxConditionRules.wetHourMm == 0.1 && WxConditionRules.wetProbPct == 30.0)  // src/blend/wx-condition.h:20-22

        // intensity, overcast (no showers): 0.5 / 2.5 / 7.6
        #expect(Self.derive(100, .nan, 0.1, 20) == .drizzle)  // test-blend.c:811
        #expect(Self.derive(100, .nan, 0.4999, 20) == .drizzle)  // test-blend.c:812
        #expect(Self.derive(100, .nan, 0.5, 20) == .lightRain)  // test-blend.c:813
        #expect(Self.derive(100, .nan, 2.4999, 20) == .lightRain)  // test-blend.c:814
        #expect(Self.derive(100, .nan, 2.5, 20) == .rain)  // test-blend.c:815
        #expect(Self.derive(100, .nan, 7.5999, 20) == .rain)  // test-blend.c:816
        #expect(Self.derive(100, .nan, 7.6, 20) == .heavyRain)  // test-blend.c:817
        #expect(Self.derive(100, .nan, 400, 20) == .heavyRain)  // test-blend.c:818
        // showers: cloud < 87.5 and rate < 7.6
        #expect(Self.derive(87.499, .nan, 0.3, 20) == .showers)  // test-blend.c:820
        #expect(Self.derive(0, 50, 3.0, 20) == .showers)  // test-blend.c:821
        #expect(Self.derive(50, 50, 7.5999, 20) == .showers)  // test-blend.c:822
        #expect(Self.derive(50, 50, 7.6, 20) == .heavyRain)  // test-blend.c:823
        #expect(Self.derive(87.5, 50, 3.0, 20) == .rain)  // test-blend.c:824
        // unknown cloud never gives showers
        #expect(Self.derive(.nan, 50, 3.0, 20) == .rain)  // test-blend.c:826
        #expect(Self.derive(.nan, .nan, 0.2, 20) == .drizzle)  // test-blend.c:827
        // not wet: sky class (rain below 0.1 mm or a probability below 30 %)
        #expect(Self.derive(100, 29.9, 5.0, 20) == .overcast)  // test-blend.c:829
        #expect(Self.derive(10, .nan, 0.09, 20) == .clear)  // test-blend.c:830
        #expect(Self.derive(.nan, .nan, 0, 20) == .unknown)  // test-blend.c:831
        #expect(Self.derive(.nan, .nan, .nan, .nan) == .unknown)  // test-blend.c:832
        #expect(Self.derive(30, .nan, .nan, 20) == .mostlyClear)  // test-blend.c:833
        #expect(Self.derive(50, 0, 0, 20) == .partlyCloudy)  // test-blend.c:834
        #expect(Self.derive(70, 0, 0, 20) == .mostlyCloudy)  // test-blend.c:835

        // the rain class helper
        #expect(WxConditionRules.rainClass(cloudPct: .nan, precipMmH: .nan) == .unknown)  // test-blend.c:838
        #expect(WxConditionRules.rainClass(cloudPct: 50, precipMmH: .nan) == .unknown)  // test-blend.c:839
        #expect(WxConditionRules.rainClass(cloudPct: .nan, precipMmH: 0.2) == .drizzle)  // test-blend.c:840
        #expect(WxConditionRules.rainClass(cloudPct: 50, precipMmH: 0.0) == .showers)  // test-blend.c:841
    }

    // C: /blend/condition/guard-page (test-blend.c:854-867). The guard page itself is
    // memory-safety plumbing (Swift arrays are bounds-checked); the values are ported.
    @Test("/blend/condition/guard-page (values)") func guardPage() {
        for n in 1...6 {  // test-blend.c:857
            let votes = [Int](repeating: 45, count: n)  // test-blend.c:862-863
            #expect(Self.derive(0, .nan, 0, 20, votes) == .fog, "n \(n)")  // test-blend.c:864
        }
    }

    // C: /blend/condition/hostile (test-blend.c:4813-4833)
    // PROPERTY TEST: seeded hostile vote lists (SeededRNG, not GRand).
    @Test("/blend/condition/hostile (property test: seeded hostile votes)") func hostile() {
        let pool = [Int(Int32.min), Int(Int32.max), -1, 0, 95, 100, 1000, -1000, 45, 71]  // test-blend.c:4816 (G_MININT, G_MAXINT)
        var rng = SeededRNG(seed: 77)  // C seed: test-blend.c:4817
        for iter in 0..<fuzzIterations(5000) {  // test-blend.c:4818
            let n = Int.random(in: 0...WxWeightedMedian.maxEntries, using: &rng)  // test-blend.c:4819 (0 ..< WX_BLEND_MAX_MEMBERS + 1)
            var votes: [Int] = []
            for _ in 0..<n {
                votes.append(pool[Int.random(in: 0..<pool.count, using: &rng)])  // test-blend.c:4821
            }
            let input = WxConditionInput(  // test-blend.c:4822-4823
                cloudPct: iter % 2 != 0 ? .nan : -.infinity, precipProb: .infinity, precipMmH: Self.dblMax,
                tempC: iter % 3 != 0 ? .nan : -Self.dblMax, wmoVotes: votes)
            let c = WxConditionRules.derive(input)
            #expect(c.rawValue >= 0 && c.rawValue < WxCondition.count)  // test-blend.c:4825-4826
        }
        #expect(!WxConditionRules.isWetHour(precipMm: -.infinity, precipProb: .nan))  // test-blend.c:4828
        #expect(WxConditionRules.isWetHour(precipMm: .infinity, precipProb: .nan))  // test-blend.c:4829
        #expect(WxConditionRules.isWetHour(precipMm: Self.dblMax, precipProb: .infinity))  // test-blend.c:4830
        #expect(!WxConditionRules.isWetHour(precipMm: Self.dblMax, precipProb: -.infinity))  // test-blend.c:4831
    }
}
