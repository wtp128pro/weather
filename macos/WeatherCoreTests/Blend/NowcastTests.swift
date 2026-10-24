// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// NowcastTests.swift - the ported /blend/nowcast/* group, /blend/blend/
// hostile-nowcast-member and /blend/fuzz/nowcast of src/blend/test-blend.c
// (the HRRR 15-minute nowcast of WxBlend.forecast, Nowcast.swift).
// Expected values are the C tests' literals, cited as test-blend.c:LINE.
//
// Hand-built hrrr15 members (raw_member) whose quarters break WxMember's
// invariants are unrepresentable (WxMember.addQuarter refuses descending,
// unaligned, out-of-range, NaN, negative or > 500 quarters and the 1537th
// quarter); those cases are ported through the builder and assert the C
// outcome (no nowcast / the same run) on what the builder keeps. The fuzz
// tests are property tests on SeededRNG, not parity evidence.

import Foundation
import Testing

@testable import WeatherCore

// .serialized: see BlendTests (CPU-bound fuzz and rescale sweeps run one at a time).
@Suite(.serialized) struct NowcastTests {
    typealias F = BlendFixture
    static let t0 = BlendFixture.t0
    static let h = BlendFixture.h

    /// nc_fill (test-blend.c:1871-1878): temp 20, cloud 50, precipitation by hour 12..14 else dflt.
    static func ncFill(_ x: inout WxHour, _ byHour: [Double], _ dflt: Double) {
        let hour = (x.tS - t0) / h
        x.tempC = 20
        x.cloudPct = 50
        x.precipMm = (hour >= 12 && hour <= 14) ? byHour[Int(hour - 12)] : dflt
    }

    /// nc_fixture (test-blend.c:1896-1909): NWS, NBM, ECMWF, HRRR and the HRRR 15-minute member.
    static func ncFixture(others: [Double], hrrr: [Double], dflt: Double, qFirst: Int64, quarters: [Double]) throws -> F.Fx {
        var fx = F.Fx()
        try fx.add("nws", F.member("nws", "nws", first: t0 + 9 * h, count: 40) { x, _ in ncFill(&x, others, dflt) })
        try fx.add("open-meteo", F.member("open-meteo", "nbm", first: t0 + 9 * h, count: 40) { x, _ in ncFill(&x, others, dflt) })
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40) { x, _ in ncFill(&x, others, dflt) })
        try fx.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 9 * h, count: 40) { x, _ in ncFill(&x, hrrr, dflt) })
        var q = try F.newMember("open-meteo", "hrrr15")
        F.addQuarters(&q, first: qFirst, quarters)
        try fx.add("open-meteo", q)
        return fx
    }

    // C: /blend/nowcast/override-rescale (test-blend.c:1924-1958)
    @Test func nowcastOverrideAndRescale() throws {
        let (t0, h) = (Self.t0, Self.h)
        let fx = try Self.ncFixture(
            others: [0.2, 0.4, 0.0], hrrr: [5.0, 5.0, 0.0], dflt: 0.1, qFirst: t0 + 12 * h,
            quarters: [0.4, 0.2, 0.2, 0.0, 0, 0, 0, 0, 0.4, 0.2, 0.2, 0.0])  // :1934-1935
        let fc = try F.blend(fx, try F.miami(), t0 + 12 * h + 7 * 60)
        expectNear(try F.hourAt(fc, t0 + 12 * h).precipMm, 0.2, eps: 1e-9)  // :1939
        expectNear(try F.hourAt(fc, t0 + 12 * h).precipMmMax, 0.8, eps: 1e-9)  // :1940
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMm, 0.4, eps: 1e-9)
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMmMax, 0.4, eps: 1e-9)
        expectNear(try F.hourAt(fc, t0 + 14 * h).precipMm, 0.0, eps: 1e-9)
        expectNear(try F.hourAt(fc, t0 + 14 * h).precipMmMax, 0.8, eps: 1e-9)  // :1944
        expectNear(try F.hourAt(fc, t0 + 15 * h).precipMm, 0.1, eps: 1e-9)  // :1946
        F.expectQuarters(fc, first: t0 + 12 * h, [0.1, 0.05, 0.05, 0.0, 0.1, 0.1, 0.1, 0.1, 0, 0, 0, 0])  // :1947-1948
        // each fully covered hour sums to its blended precipitation (:1949-1956)
        try #require(fc.quarters.count == 12)
        for hh in 0..<3 {
            let q = fc.quarters
            let sum = q[4 * hh].precipMm + q[4 * hh + 1].precipMm + q[4 * hh + 2].precipMm + q[4 * hh + 3].precipMm
            expectNear(sum, try F.hourAt(fc, t0 + (12 + Int64(hh)) * h).precipMm, eps: 1e-9)
        }
    }

    // C: /blend/nowcast/partial-hours (test-blend.c:1960-1978)
    @Test func nowcastPartialHours() throws {
        let (t0, h) = (Self.t0, Self.h)
        let fx = try Self.ncFixture(
            others: [0.1, 0.2, 0.4], hrrr: [5.0, 5.0, 0.0], dflt: 0.1, qFirst: t0 + 12 * h + 1800,
            quarters: [0.1, 0.1, 0.2, 0.2, 0.2, 0.2, 0, 0, 0, 0, 0.3, 0.3])  // :1967-1968
        let fc = try F.blend(fx, try F.miami(), BlendFixture.nowS)
        expectNear(try F.hourAt(fc, t0 + 12 * h).precipMmMax, 5.0, eps: 1e-9)  // :1971
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMm, 0.2, eps: 1e-9)  // :1973
        expectNear(try F.hourAt(fc, t0 + 14 * h).precipMm, 0.4, eps: 1e-9)  // :1974
        F.expectQuarters(fc, first: t0 + 12 * h + 1800, [0.1, 0.1, 0.05, 0.05, 0.05, 0.05, 0.1, 0.1, 0.1, 0.1, 0.3, 0.3])  // :1975-1976
    }

    /// nc_count (test-blend.c:1980-2001): the nowcast quarters of Miami with ECMWF 0.8 mm/h and a
    /// quarter-only member; nil count on a failed blend.
    static func ncCount(_ now: Int64, _ qFirst: Int64, _ quarters: [Double], _ src: String, _ model: String) throws -> (Int, Int64?) {
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 0.8
        var fx = F.Fx()
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec))
        var q = try F.newMember(src, model)
        F.addQuarters(&q, first: qFirst, quarters)
        try fx.add(src, q)
        let fc = try F.blend(fx, try F.miami(), now)
        return (fc.quarters.count, fc.quarters.first?.tS)
    }

    // C: /blend/nowcast/coverage-rules (test-blend.c:2003-2075)
    @Test func nowcastCoverageRules() throws {
        let (t0, h) = (Self.t0, Self.h)
        let nowS = BlendFixture.nowS
        let z = [Double](repeating: 0.1, count: 24)
        let q1230 = t0 + 12 * h + 1800
        func zs(_ n: Int) -> [Double] { Array(z.prefix(n)) }

        // quarter 12:30 contains now (12:37); the run must end at or after 13:07 (:2012-2016)
        var r = try Self.ncCount(nowS, q1230, zs(3), "open-meteo", "hrrr15")
        #expect(r.0 == 3)
        #expect(r.1 == q1230)
        #expect(try Self.ncCount(nowS, q1230, zs(2), "open-meteo", "hrrr15").0 == 0)  // ends 13:00
        #expect(try Self.ncCount(nowS, q1230, zs(1), "open-meteo", "hrrr15").0 == 0)
        // boundary: now 12:30:00, run ends exactly at now + 30 min (:2017-2019)
        #expect(try Self.ncCount(q1230, q1230, zs(2), "open-meteo", "hrrr15").0 == 2)
        #expect(try Self.ncCount(q1230, q1230, zs(1), "open-meteo", "hrrr15").0 == 0)
        // now 12:44:59 is still the 12:30 quarter (:2020-2021)
        #expect(try Self.ncCount(q1230 + 899, q1230, zs(3), "open-meteo", "hrrr15").0 == 3)
        // the quarter containing now is missing (:2022-2023)
        #expect(try Self.ncCount(nowS, q1230 + 900, zs(4), "open-meteo", "hrrr15").0 == 0)
        // quarters before the one containing now are not part of the list (:2024-2026)
        r = try Self.ncCount(nowS, q1230 - 900, zs(4), "open-meteo", "hrrr15")
        #expect(r.0 == 3)
        #expect(r.1 == q1230)
        // the run is cut at the 12 quarter limit (:2027-2030)
        #expect(try Self.ncCount(nowS, q1230, zs(20), "open-meteo", "hrrr15").0 == WxBlend.maxQuarters)
        #expect(try Self.ncCount(nowS, q1230, zs(13), "open-meteo", "hrrr15").0 == WxBlend.maxQuarters)
        #expect(try Self.ncCount(nowS, q1230, zs(12), "open-meteo", "hrrr15").0 == 12)
        #expect(WxBlend.maxQuarters == 12)  // WX_BLEND_MAX_QUARTERS (wx-blend.h:32)
        // only the HRRR 15-minute member of open-meteo is a nowcast (:2031-2034)
        #expect(try Self.ncCount(nowS, q1230, zs(6), "met-no", "hrrr15").0 == 0)
        #expect(try Self.ncCount(nowS, q1230, zs(6), "open-meteo", "hrrr").0 == 0)
        #expect(try Self.ncCount(nowS, q1230, zs(6), "open-meteo", "gfs").0 == 0)

        // an interior gap cuts the run; it must still reach now + 30 min (:2036-2065)
        let p = try F.miami()
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 0.8
        let ecm = try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec)
        var gap = try F.newMember("open-meteo", "hrrr15")
        for t in [q1230, q1230 + 900, q1230 + 1800, q1230 + 2700 + 900] {
            let added = gap.addQuarter(WxQuarter(tS: t, precipMm: 0.1))
            #expect(added)
        }
        #expect(try F.blendRaw(p, [ecm, gap]).quarters.count == 3)  // :2053
        var gap2 = try F.newMember("open-meteo", "hrrr15")
        let added1 = gap2.addQuarter(WxQuarter(tS: q1230, precipMm: 0.1))
        #expect(added1)
        let added2 = gap2.addQuarter(WxQuarter(tS: q1230 + 1800, precipMm: 0.1))
        #expect(added2)
        #expect(try F.blendRaw(p, [ecm, gap2]).quarters.isEmpty)  // :2064
        // a member without quarters, and without any data, is no nowcast (:2067-2074)
        #expect(try F.blendRaw(p, [ecm, try F.newMember("open-meteo", "hrrr15")]).quarters.isEmpty)
    }

    // C: /blend/nowcast/without-hrrr-hours (test-blend.c:2077-2116)
    @Test func nowcastWithoutHRRRHours() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 0.8
        let qs = [Double](repeating: 0.1, count: 12)
        var q = try F.newMember("open-meteo", "hrrr15")
        F.addQuarters(&q, first: t0 + 12 * h, qs)
        let fc = try F.blendRaw(p, [try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec), q], now: t0 + 12 * h + 7 * 60)
        F.expectQuarters(fc, first: t0 + 12 * h, [Double](repeating: 0.2, count: 12))  // :2094-2097
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMm, 0.8, eps: 1e-9)  // :2099
        #expect(try F.hourAt(fc, t0 + 13 * h).nMembers == 1)  // :2100

        // no data of other members for those hours: the quarters keep their raw amounts (:2103-2115)
        var t = F.Vals()
        t.temp = 20
        let c2 = try F.blendRaw(p, [try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, t), q], now: t0 + 12 * h + 7 * 60)
        expectNaN(try F.hourAt(c2, t0 + 13 * h).precipMm)
        F.expectQuarters(c2, first: t0 + 12 * h, qs)
    }

    // C: /blend/nowcast/garbage-quarters (test-blend.c:2118-2168), through the builder
    @Test func nowcastGarbageQuarters() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 0.8
        let real = try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec)
        let q0 = t0 + 12 * h
        let now = q0 + 7 * 60
        let cases: [(String, [WxQuarter], Int)] = [  // :2127-2150
            ("ok", [.init(tS: q0, precipMm: 0.1), .init(tS: q0 + 900, precipMm: 0.1), .init(tS: q0 + 1800, precipMm: 0.1), .init(tS: q0 + 2700, precipMm: 0.1)], 4),
            ("desc", [.init(tS: q0 + 2700, precipMm: 0.1), .init(tS: q0 + 1800, precipMm: 0.1), .init(tS: q0 + 900, precipMm: 0.1), .init(tS: q0, precipMm: 0.1)], 0),
            ("misaligned", [.init(tS: q0 + 1, precipMm: 0.1), .init(tS: q0 + 901, precipMm: 0.1), .init(tS: q0 + 1801, precipMm: 0.1), .init(tS: q0 + 2701, precipMm: 0.1)], 0),
            ("nan", [.init(tS: q0, precipMm: 0.1), .init(tS: q0 + 900, precipMm: .nan), .init(tS: q0 + 1800, precipMm: 0.1), .init(tS: q0 + 2700, precipMm: 0.1)], 0),
            ("negative", [.init(tS: q0, precipMm: 0.1), .init(tS: q0 + 900, precipMm: -0.1), .init(tS: q0 + 1800, precipMm: 0.1), .init(tS: q0 + 2700, precipMm: 0.1)], 0),
            ("huge", [.init(tS: q0, precipMm: 0.1), .init(tS: q0 + 900, precipMm: 501.0), .init(tS: q0 + 1800, precipMm: 0.1), .init(tS: q0 + 2700, precipMm: 0.1)], 0),
            ("out of range", [.init(tS: 0, precipMm: 0.1), .init(tS: 900, precipMm: 0.1), .init(tS: 1800, precipMm: 0.1), .init(tS: 2700, precipMm: 0.1)], 0),
            ("none", [], 0),
        ]
        for (what, qs, expect) in cases {
            var m = try F.newMember("open-meteo", "hrrr15")
            for q in qs { m.addQuarter(q) }
            let fc = try F.blendRaw(p, [real, m], now: now)
            #expect(fc.quarters.count == expect, "case \(what)")
        }
    }

    // C: /blend/nowcast/hour-sums-validity (test-blend.c:2170-2203), the NaN quarter refused by the builder
    @Test func nowcastHourSumsValidity() throws {
        let (t0, h) = (Self.t0, Self.h)
        let p = try F.miami()
        let others = [0.2, 0.2, 0.2], hrrr = [5.0, 5.0, 5.0]
        let nws = try F.member("nws", "nws", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) }
        let nbm = try F.member("open-meteo", "nbm", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) }
        let ec = try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) }
        let hr = try F.member("open-meteo", "hrrr", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, hrrr, 0.1) }
        // four quarters of 10:00 first, then 12:00 .. 14:45; 13:00 sums to 1600 mm; 14:30 is NaN (:2181-2188)
        var q15 = try F.newMember("open-meteo", "hrrr15")
        for i in 0..<16 {
            let first = i < 4 ? t0 + 10 * h : t0 + 12 * h - 4 * 900
            let mm = i == 14 ? Double.nan : ((i >= 8 && i < 12) ? 400.0 : 0.2)
            let added = q15.addQuarter(WxQuarter(tS: first + Int64(i) * 900, precipMm: mm))
            #expect(added == (i != 14))
        }
        let fc = try F.blendRaw(p, [nws, nbm, ec, hr, q15], now: t0 + 12 * h + 7 * 60)
        expectNear(try F.hourAt(fc, t0 + 12 * h).precipMmMax, 0.8, eps: 1e-9)  // :2196
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMmMax, 5.0, eps: 1e-9)  // :2197
        expectNear(try F.hourAt(fc, t0 + 14 * h).precipMmMax, 5.0, eps: 1e-9)  // :2198
        F.expectQuarters(fc, first: t0 + 12 * h, [0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.2, 0.2])  // :2201-2202
    }

    // C: /blend/nowcast/hrrr-without-hour (test-blend.c:2205-2231)
    @Test func nowcastHRRRWithoutHour() throws {
        let (t0, h) = (Self.t0, Self.h)
        let others = [0.2, 0.2, 0.2], hrrr = [5.0, 5.0, 5.0]
        var fx = F.Fx()
        try fx.add("nws", F.member("nws", "nws", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) })
        try fx.add("open-meteo", F.member("open-meteo", "nbm", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) })
        try fx.add("open-meteo", F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40) { x, _ in Self.ncFill(&x, others, 0.1) })
        try fx.add("open-meteo", F.member("open-meteo", "hrrr", first: t0 + 14 * h, count: 20) { x, _ in Self.ncFill(&x, hrrr, 0.1) })
        var q = try F.newMember("open-meteo", "hrrr15")
        F.addQuarters(&q, first: t0 + 12 * h, [Double](repeating: 0.2, count: 12))
        try fx.add("open-meteo", q)
        let fc = try F.blend(fx, try F.miami(), t0 + 12 * h + 7 * 60)
        expectNear(try F.hourAt(fc, t0 + 12 * h).precipMmMax, 0.2, eps: 1e-9)  // :2223
        expectNear(try F.hourAt(fc, t0 + 13 * h).precipMmMax, 0.2, eps: 1e-9)  // :2224
        expectNear(try F.hourAt(fc, t0 + 14 * h).precipMmMax, 0.8, eps: 1e-9)  // :2225
        F.expectQuarters(fc, first: t0 + 12 * h, [Double](repeating: 0.05, count: 12))  // :2226-2229
    }

    // C: /blend/blend/hostile-nowcast-member (test-blend.c:4837-4863), through the builder
    @Test func blendHostileNowcastMember() throws {
        let (t0, h) = (Self.t0, Self.h)
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 0.4
        let real = try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec)
        var q15 = try F.newMember("open-meteo", "hrrr15")
        for i in 0..<WxLimits.memberMaxQuarters {
            let added = q15.addQuarter(WxQuarter(tS: t0 - 100 * 900 + Int64(i) * 900, precipMm: 0.1))
            #expect(added)
        }
        let fc = try F.blendRaw(try F.miami(), [real, q15], now: t0 + 12 * h + 7 * 60)
        #expect(fc.quarters.count == WxBlend.maxQuarters)  // :4855
        // one quarter too long (:4856-4862): the builder refuses the 1537th quarter, so such a member
        // (no nowcast in C) cannot exist
        let added = q15.addQuarter(WxQuarter(tS: t0 - 100 * 900 + Int64(WxLimits.memberMaxQuarters) * 900, precipMm: 0.1))
        #expect(!added)
    }

    /// check_rescaled_quarters (test-blend.c:3854-3904): ECMWF `blended` mm every hour plus quarters
    /// repeating `pattern`, at 12:07; returns the sum of the first hour's quarters (nil on failure).
    @discardableResult
    static func checkRescaledQuarters(
        _ blended: Double, _ pattern: [Double], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Double {
        let p = try F.miami()
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = blended
        var q = try F.newMember("open-meteo", "hrrr15")
        F.addQuarters(&q, first: t0 + 12 * h, (0..<12).map { pattern[$0 % 4] }, sourceLocation: sourceLocation)
        let fc: WxForecast
        do {
            fc = try F.blendRaw(p, [try F.member("open-meteo", "ecmwf", first: t0 + 11 * h, count: 8, ec), q], now: t0 + 12 * h + 7 * 60)
        } catch {
            Issue.record("blend of \(blended) mm with pattern \(pattern) failed: \(error.message)", sourceLocation: sourceLocation)
            throw error
        }
        try #require(fc.quarters.count == 12, sourceLocation: sourceLocation)  // :3881
        var firstSum = 0.0
        for hh in 0..<3 {
            let want = try F.hourAt(fc, t0 + (12 + Int64(hh)) * h, sourceLocation: sourceLocation).precipMm
            #expect(want == blended, sourceLocation: sourceLocation)  // :3885
            var sum = 0.0
            for k in 0..<4 {
                let v = fc.quarters[4 * hh + k].precipMm
                #expect(v.isFinite && v >= 0.0 && v <= blended, "\(blended) \(pattern): quarter \(v)", sourceLocation: sourceLocation)
                sum += v
            }
            #expect(abs(sum - want) <= 1e-9, sourceLocation: sourceLocation)  // :3894
            if blended < F.nowcastMinMm {
                #expect(abs(sum - want) <= 4 * F.dmin, "\(blended) \(pattern): sum \(sum)", sourceLocation: sourceLocation)  // :3897-3898
            }
            if hh == 0 { firstSum = sum }
        }
        return firstSum
    }

    // C: /blend/nowcast/rescale-in-range (test-blend.c:3906-3949)
    @Test func nowcastRescaleInRange() throws {
        let (t0, h) = (Self.t0, Self.h)
        let singles = [0.073, 0.21, 0.37, 1.0, 499.99999999999994, 500.0, 1e-9, 1e-310, 4.9e-324]  // :3911-3912
        let blendeds = [500.0, 499.99999999999994, 7.6, 0.3, 1e-9, 1e-300, 4.9e-324]  // :3913
        let others: [[Double]] = [  // :3922-3928
            [0.073, 0.073, 0.073, 0.073], [500, 500, 500, 500], [0, 0, 0, 0], [1e-310, 1e-310, 1e-310, 1e-310],
            [4.9e-324, 0, 4.9e-324, 0], [0.25e-9, 0.25e-9, 0.25e-9, 0.25e-9], [0.249e-9, 0.25e-9, 0.25e-9, 0.25e-9],
            [0.1, 0.2, 0.3, 0.4], [500, 0, 0, 1e-300], [0.5, 0.5, 0.5, 0.5],
        ]
        for b in blendeds {
            for s in singles {
                for pos in 0..<4 {
                    var pattern = [0.0, 0.0, 0.0, 0.0]
                    pattern[pos] = s
                    try Self.checkRescaledQuarters(b, pattern)
                }
            }
            for o in others { try Self.checkRescaledQuarters(b, o) }
        }
        try Self.checkRescaledQuarters(0.0, [0.073, 0.2, 0, 0])  // :3932

        // the exact values: the largest quarter keeps the remainder (:3934-3948)
        var ec = F.Vals()
        ec.temp = 20
        ec.precip = 500.0
        var q = try F.newMember("open-meteo", "hrrr15")
        F.addQuarters(&q, first: t0 + 12 * h, [0.073, 0, 0, 0, 0, 0, 0, 0.21, 1e-310, 0, 0, 0])
        let fc = try F.blendRaw(try F.miami(), [try F.member("open-meteo", "ecmwf", first: t0 + 9 * h, count: 40, ec), q], now: t0 + 12 * h + 7 * 60)
        F.expectQuarters(fc, first: t0 + 12 * h, [500, 0, 0, 0, 0, 0, 0, 500, 125, 125, 125, 125])  // :3946
    }

    // C: /blend/nowcast/rescale-spread-both-directions (test-blend.c:3951-3976)
    @Test func nowcastRescaleSpreadBothDirections() throws {
        let dmin = F.dmin
        let pat = [0.6, 0.6, 0.6, 0.6]
        #expect(try Self.checkRescaledQuarters(3 * dmin, pat) == 4 * dmin)  // :3958
        #expect(try Self.checkRescaledQuarters(5 * dmin, pat) == 4 * dmin)  // :3960
        #expect(try Self.checkRescaledQuarters(4 * dmin, pat) == 4 * dmin)  // :3962
        #expect(try Self.checkRescaledQuarters(dmin, pat) == 0.0)  // :3963
        #expect(try Self.checkRescaledQuarters(2 * dmin, pat) == 0.0)  // :3964
        #expect(try Self.checkRescaledQuarters(7e-10, pat) == 7e-10)  // :3966
        var above = false
        var below = false
        for k in 1...2000 {  // :3969-3975
            let s = try Self.checkRescaledQuarters(Double(k) * dmin, pat)
            above = above || s > Double(k) * dmin
            below = below || s < Double(k) * dmin
            #expect(abs(s - Double(k) * dmin) <= 2 * dmin, "k \(k)")
        }
        #expect(above && below)
    }

    /// stress_patterns (test-blend.c:3980-3985).
    static let stressPatterns: [[Double]] = [
        [0.175, 0.175, 0.175, 0.175], [300, 300, 300, 301], [1e-12, 2e-12, 3e-12, 4e-12], [500, 500, 500, 500],
        [0.6, 0.6, 0.6, 0.6], [377.97, 500, 0.76, 500], [0.073, 0, 0, 0], [1e-310, 1e-310, 1e-310, 1e-310],
        [0.1, 0.2, 0.3, 0.4],
    ]

    // C: /blend/nowcast/rescale-subnormal (test-blend.c:3987-4012)
    @Test func nowcastRescaleSubnormal() throws {
        let dmin = 4.9406564584124654e-324  // :3992
        try Self.checkRescaledQuarters(1e-323, [0.6, 0.6, 0.6, 0.6])  // :3993
        try Self.checkRescaledQuarters(3.78e-321, [377.97, 500, 0.76, 500])  // :3994
        for pat in Self.stressPatterns {
            for k in 1...5000 {
                try Self.checkRescaledQuarters(Double(k) * dmin, pat)  // :3995-3998
            }
        }
        let blendeds = [0.9999999e-9, 1e-9, 1.0000001e-9, (1e-9).nextDown, (1e-9).nextUp, Double.leastNormalMagnitude,
                        Double.leastNormalMagnitude.nextDown, Double.leastNormalMagnitude.nextUp, 1e-300, 1e-12, 1e-6, 500.0,
                        (500.0).nextDown]  // :3999-4002
        for b in blendeds {
            for pat in Self.stressPatterns { try Self.checkRescaledQuarters(b, pat) }
        }
        // negative zero is in range (:4007-4011)
        try Self.checkRescaledQuarters(-0.0, Self.stressPatterns[0])
        try Self.checkRescaledQuarters(0.3, [-0.0, -0.0, -0.0, 0.2])
        try Self.checkRescaledQuarters(0.3, [-0.0, -0.0, -0.0, -0.0])
        try Self.checkRescaledQuarters(-0.0, [-0.0, -0.0, -0.0, -0.0])
    }

    // C: /blend/nowcast/rescale-fuzz (test-blend.c:4014-4060) - property test (SeededRNG)
    @Test func nowcastRescaleFuzz() throws {
        var r = F.Rand(seed: 8_675_309)
        let dmin = 4.9406564584124654e-324
        // ldexp(1.0, e) for e in [-1074, 8]: exact powers of two
        func pow2(_ e: Int) -> Double { e >= -1022 ? Double(sign: .plus, exponent: e, significand: 1.0) : dmin * Double(sign: .plus, exponent: e + 1074, significand: 1.0) }
        for _ in 0..<fuzzIterations(20000) {
            var blended: Double
            switch r.intRange(0, 5) {
            case 0: blended = dmin * Double(r.intRange(1, 100_000))
            case 1: blended = pow2(r.intRange(-1074, 9)) * (1.0 + r.double())
            case 2: blended = r.boolean() ? (1e-9).nextDown : (1e-9).nextUp
            default: blended = r.double() * 500.0
            }
            if blended > 500.0 { blended = 500.0 }
            var pat = [Double](repeating: 0, count: 4)
            for k in 0..<4 {
                switch r.intRange(0, 4) {
                case 0: pat[k] = dmin * Double(r.intRange(0, 1000))
                case 1: pat[k] = pow2(r.intRange(-1074, 9))
                case 2: pat[k] = k == 0 ? 0.175 : pat[k - 1]  // near-equal quarters
                default: pat[k] = r.double() * 500.0
                }
                pat[k] = pat[k] > 500.0 ? 500.0 : (pat[k] < 0.0 ? 0.0 : pat[k])  // CLAMP
            }
            try Self.checkRescaledQuarters(blended, pat)
        }
    }

    // C: /blend/fuzz/nowcast (test-blend.c:5413-5477) - property test (SeededRNG), not parity evidence
    @Test func fuzzNowcastInvariants() throws {
        var r = F.Rand(seed: 777)
        let place = try F.miami()
        var withQuarters = 0
        for _ in 0..<fuzzIterations(600) {
            let now = Self.t0 + Int64(r.intRange(0, 10 * 86400))
            let base = now - now % Self.h
            var members: [WxMember] = []
            for k in 1..<7 where r.double() < 0.7 {
                members.append(try BlendTests.fuzzMember(&r, F.fuzzIDs[k], base: base))
            }
            var q = try F.newMember("open-meteo", "hrrr15")
            let qfirst = (now - now % 900) - 900 * Int64(r.intRange(-2, 5))
            let nq = r.intRange(0, 20)
            for i in 0..<nq {
                if r.double() < 0.05 { continue }
                let mm = r.double() < 0.4 ? 0.0 : r.rnd(0, 3)
                let added = q.addQuarter(WxQuarter(tS: qfirst + Int64(i) * 900, precipMm: mm))
                #expect(added)
            }
            members.append(q)
            let fc: WxForecast
            do {
                fc = try F.blendRaw(place, members, now: now)
            } catch {
                #expect(error.code == .notFound)  // :5442
                continue
            }
            let hs = fc.hours
            let fq = fc.quarters
            #expect(fq.count <= WxBlend.maxQuarters)
            if !fq.isEmpty {
                withQuarters += 1
                #expect(fq[0].tS == now - now % 900)  // :5451
                #expect(fq[fq.count - 1].tS + 900 >= now + 1800)  // :5452
                for (i, x) in fq.enumerated() {
                    if i > 0 { #expect(x.tS - fq[i - 1].tS == 900) }
                    #expect(x.precipMm.isFinite && x.precipMm >= 0)
                    // a fully covered hour sums to its blended precipitation (:5457-5464)
                    if x.tS % Self.h == 0 && i + 3 < fq.count, let first = hs.first {
                        let b = Int((x.tS - first.tS) / Self.h)
                        if b < hs.count && hs[b].precipMm.isFinite {
                            let s = x.precipMm + fq[i + 1].precipMm + fq[i + 2].precipMm + fq[i + 3].precipMm
                            expectNear(s, hs[b].precipMm, eps: 1e-9 * (1 + hs[b].precipMm))
                        }
                    }
                }
            }
            for x in hs {
                #expect(x.precipMm.isNaN || (x.precipMm >= 0 && x.precipMm <= 500))
                #expect(x.precipMmMax.isNaN || x.precipMmMax >= x.precipMm)
            }
        }
        #expect(withQuarters > 30)  // :5475
    }
}
