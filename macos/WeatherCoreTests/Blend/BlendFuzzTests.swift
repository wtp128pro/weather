// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// BlendFuzzTests.swift - the ported /blend/determinism/* and /blend/fuzz/*
// groups (except /blend/fuzz/nowcast, in NowcastTests.swift) of
// src/blend/test-blend.c. Part of the BlendTests suite.
//
// PROPERTY TESTS, NOT PARITY EVIDENCE: the fuzz tests keep the C tests'
// generators, oracles and thresholds, but draw from SeededRNG instead of
// GLib's GRand (DECISIONS #16-#17), so they run different random cases than
// the C suite. Bit parity with the C code is shown by the U21 C differential
// (scratch harness, see the debrief), not by these tests.
//
// Not ported: the process time zone and locale part of
// /blend/determinism/environment (test-blend.c:4998-5018) sets TZ and calls
// setlocale, which the test rules forbid (process-global state); locale
// independence is instead shown by running BlendTests under de_DE
// (RUN_SUITE_LOCALE=de_DE). WxBlend reads neither.

import Foundation
import Testing

@testable import WeatherCore

extension BlendTests {
    /// nc_fixture (test-blend.c:1896-1909) with the NcVals of :4976-4977.
    static func determinismFixture() throws -> F.Fx {
        try NowcastTests.ncFixture(
            others: [0.2, 0.4, 0.0], hrrr: [5.0, 5.0, 0.0], dflt: 0.1, qFirst: t0 + 12 * h,
            quarters: [0.4, 0.2, 0.2, 0.0, 0, 0, 0, 0, 0.4, 0.2, 0.2, 0.0])
    }

    /// The bit patterns of every input number (fx_digest, test-blend.c:4943-4969).
    static func digest(_ fx: F.Fx) -> [UInt64] {
        var out: [UInt64] = []
        for r in fx.results {
            for m in r.members {
                out += m.sourceID.utf8.map { UInt64($0) } + m.modelID.utf8.map { UInt64($0) }
                for x in m.hours {
                    out += [UInt64(bitPattern: x.tS)]
                    out += [x.tempC, x.feelsC, x.precipMm, x.precipProb, x.cloudPct, x.windKmh, x.gustKmh, x.humidityPct].map(\.bitPattern)
                    out += [UInt64(bitPattern: Int64(x.wmo))]
                }
                for q in m.quarters {
                    out += [UInt64(bitPattern: q.tS), q.precipMm.bitPattern]
                }
            }
        }
        return out
    }

    // C: /blend/determinism/environment (test-blend.c:4971-5026), without the TZ/locale part
    @Test func determinismEnvironment() throws {
        let p = try F.miami()
        let fx = try Self.determinismFixture()
        let now = Self.t0 + 12 * Self.h + 7 * 60
        let before = Self.digest(fx)
        let a = try F.blend(fx, p, now)
        let b = try F.blend(fx, p, now)
        F.expectIdentical(a, b)  // :4983

        // the same members in the opposite order: the same forecast (:4985-4996)
        var rev = F.Fx()
        for r in fx.results.reversed() {
            var copy = try WxSourceResult(providerID: r.providerID)
            copy.members = r.members.reversed()
            rev.results.append(copy)
        }
        F.expectIdentical(a, try F.blend(rev, p, now))

        // the inputs are not modified (:5020-5022)
        #expect(Self.digest(fx) == before)
    }

    // C: /blend/determinism/threads (test-blend.c:5028-5068)
    @Test func determinismThreads() async throws {
        let p = try F.miami()
        let fx = try Self.determinismFixture()
        let now = Self.t0 + 12 * Self.h + 7 * 60
        let reference = try F.blend(fx, p, now)
        let results = fx.results
        // 8 concurrent tasks x 40 blends of the shared (immutable) members, reading the shared forecast too
        let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var bad = 0
                    for _ in 0..<40 {
                        let fc = try WxBlend.forecast(place: p, results: results, nowS: now)
                        if fc.hours.map(F.bits) != reference.hours.map(F.bits)
                            || fc.quarters.map(\.precipMm.bitPattern) != reference.quarters.map(\.precipMm.bitPattern)
                            || fc.days.count != reference.days.count
                        {
                            bad += 1
                        }
                        if WxBlend.now(reference, nowS: now) == nil {
                            bad += 1
                        }
                        _ = WxRainRules.outlook(reference, nowS: now)
                    }
                    return bad
                }
            }
            var total = 0
            for try await bad in group {
                total += bad
            }
            return total
        }
        #expect(mismatches == 0)
    }

    /// The valid range and group of each variable, as a second statement of the rules (OField,
    /// test-blend.c:5103-5124), in the order temp, feels, humidity, wind, gust, cloud, precip, prob.
    static let ofields: [(variable: WxVar, lo: Double, hi: Double, get: @Sendable (WxHour) -> Double)] = [
        (.temp, -100, 70, { $0.tempC }), (.temp, -100, 70, { $0.feelsC }), (.humidity, 0, 100, { $0.humidityPct }),
        (.wind, 0, 500, { $0.windKmh }), (.wind, 0, 500, { $0.gustKmh }), (.cloud, 0, 100, { $0.cloudPct }),
        (.precipMm, 0, 500, { $0.precipMm }), (.precipProb, 0, 100, { $0.precipProb }),
    ]

    /// fuzz_member (test-blend.c:5076-5101).
    static func fuzzMember(_ r: inout F.Rand, _ id: (src: String, model: String), base: Int64) throws -> WxMember {
        func maybe(_ r: inout F.Rand, _ lo: Double, _ hi: Double) -> Double { r.double() < 0.3 ? .nan : r.rnd(lo, hi) }  // :5070-5074
        var m = try F.newMember(id.src, id.model)
        let first = r.intRange(-6, 8)
        let len = r.double() < 0.3 ? r.intRange(0, 9) : r.intRange(0, 260)
        let sparse = r.double() < 0.2
        for i in 0..<len {
            if r.double() < (sparse ? 0.6 : 0.03) {
                continue
            }
            var x = WxHour(tS: base + Int64(first + i) * h)
            x.tempC = maybe(&r, -30, 45)
            x.feelsC = maybe(&r, -35, 50)
            x.precipMm = r.double() < 0.4 ? 0.0 : maybe(&r, 0, 20)
            x.precipProb = maybe(&r, 0, 100)
            x.cloudPct = maybe(&r, 0, 100)
            x.windKmh = maybe(&r, 0, 80)
            x.gustKmh = maybe(&r, 0, 120)
            x.humidityPct = maybe(&r, 0, 100)
            x.wmo = r.double() < 0.5 ? -1 : r.intRange(0, 100)
            let added = m.addHour(x)
            #expect(added)
        }
        return m
    }

    /// check_fuzz_case (test-blend.c:5192-5358): a blend of `members` (no HRRR 15) against the oracle.
    /// Returns whether the blend succeeded (the C test blends a third time only to count that).
    @discardableResult
    static func checkFuzzCase(_ place: WxPlace, _ members: [WxMember], _ now: Int64) throws -> Bool {
        let start = now - now % h - h
        var us = WxGeo.inUSNWS(lat: place.lat, lon: place.lon) || WxGeo.inCONUS(lat: place.lat, lon: place.lon)
        for m in members where m.sourceID == "nws" {
            us = true
        }
        var last: Int64 = 0
        var any = false
        for m in members {
            for x in m.hours where x.tS >= start {
                for f in ofields where F.inRange(f.get(x), f.lo, f.hi) {
                    if !any || x.tS > last { last = x.tS }
                    any = true
                }
            }
        }
        var fc: WxForecast?
        var err: WxError?
        do { fc = try F.blendRaw(place, members, now: now) } catch { err = error }

        let nb = any ? Int(min((last - start) / h + 1, Int64(WxBlend.maxHours))) : 0
        // member_hour (:5126-5135) as a lookup table
        let byTime = members.map { m in Dictionary(m.hours.map { ($0.tS, $0) }, uniquingKeysWith: { a, _ in a }) }
        var contrib = [Int](repeating: 0, count: members.count)
        var want: [(v: [Double], maxPrecip: Double, spread: Double, nmem: Int)] = []
        for b in 0..<nb {
            let t = start + Int64(b) * h
            let horizon = max(Double(t - now), 0.0) / Double(h)
            var vals = [[Double]](repeating: [], count: 8)
            var wts = [[Double]](repeating: [], count: 8)
            var nmem = 0
            for (i, m) in members.enumerated() {
                guard let x = byTime[i][t] else { continue }
                var gave = false
                for (fi, f) in ofields.enumerated() {
                    let v = f.get(x)
                    if !F.inRange(v, f.lo, f.hi) { continue }
                    let w = WxWeights.weight(sourceID: m.sourceID, modelID: m.modelID, variable: f.variable, horizonH: horizon, usRegion: us)
                    if !(w > 0) { continue }
                    vals[fi].append(v)
                    wts[fi].append(w)
                    gave = true
                }
                if gave {
                    nmem += 1
                    contrib[i] += 1
                }
            }
            // oracle_median (:5143-5153): the independent reference with integer weights x2
            var v = [Double](repeating: .nan, count: 8)
            for fi in 0..<8 {
                let wi = wts[fi].map { Int(($0 * 2.0).rounded()) }
                for (k, w) in wts[fi].enumerated() { #expect(Double(wi[k]) / 2.0 == w) }
                v[fi] = F.referenceMedian(vals[fi], wi)
            }
            var maxPrecip = Double.nan
            for x in vals[6] { maxPrecip = maxPrecip.isNaN ? x : max(maxPrecip, x) }
            var spread = Double.nan
            if vals[0].count >= 2, let lo = vals[0].min(), let hi = vals[0].max() { spread = hi - lo }
            if vals[7].isEmpty && !vals[6].isEmpty {
                var wet = 0.0
                var all = 0.0
                for (k, x) in vals[6].enumerated() {
                    all += wts[6][k]
                    if x >= 0.1 { wet += wts[6][k] }
                }
                v[7] = 100.0 * wet / all
            }
            want.append((v, maxPrecip, spread, nmem))
        }
        if (contrib.max() ?? 0) < WxBlend.minHours {
            #expect(fc == nil)
            #expect(err?.code == .notFound)  // :5289-5295
            return false
        }
        let f = try #require(fc, "blend failed: \(String(describing: err))")
        try #require(f.hours.count == nb)
        for (b, x) in f.hours.enumerated() {
            let w = want[b]
            #expect(x.tS == start + Int64(b) * h)
            F.expectCloseOrNaN(x.tempC, w.v[0], "temp")
            F.expectCloseOrNaN(x.feelsC, w.v[1], "feels")
            F.expectCloseOrNaN(x.humidityPct, w.v[2], "humidity")
            F.expectCloseOrNaN(x.windKmh, w.v[3], "wind")
            F.expectCloseOrNaN(x.gustKmh, w.v[4], "gust")
            F.expectCloseOrNaN(x.cloudPct, w.v[5], "cloud")
            F.expectCloseOrNaN(x.precipMm, w.v[6], "precip")
            F.expectCloseOrNaN(x.precipMmMax, w.maxPrecip, "precip max")
            F.expectCloseOrNaN(x.precipProb, w.v[7], "prob")
            F.expectCloseOrNaN(x.tempSpreadC, w.spread, "spread")
            #expect(Int(x.nMembers) == w.nmem)
            // ranges, and a member count of 0 means nothing at all (:5315-5334)
            #expect(x.tempC.isNaN || F.inRange(x.tempC, -100, 70))
            #expect(x.precipProb.isNaN || F.inRange(x.precipProb, 0, 100))
            #expect(x.feelsC.isNaN || F.inRange(x.feelsC, -100, 70))
            #expect(x.humidityPct.isNaN || F.inRange(x.humidityPct, 0, 100))
            #expect(x.cloudPct.isNaN || F.inRange(x.cloudPct, 0, 100))
            #expect(x.windKmh.isNaN || F.inRange(x.windKmh, 0, 500))
            #expect(x.gustKmh.isNaN || F.inRange(x.gustKmh, 0, 500))
            #expect(x.precipMmMax.isNaN || F.inRange(x.precipMmMax, 0, 500))
            #expect(x.tempSpreadC.isNaN || F.inRange(x.tempSpreadC, 0, 170))
            #expect(x.precipMm.isNaN || (x.precipMm >= 0 && x.precipMm <= x.precipMmMax))
            #expect(x.isDay == WxGeo.sunIsUp(lat: place.lat, lon: place.lon, t: x.tS))
            if w.nmem == 0 {
                expectNaN(x.tempC)
                expectNaN(x.precipProb)
                #expect(x.condition == .unknown)
            }
        }
        #expect(f.quarters.isEmpty)  // :5338
        #expect(f.days.count <= WxDaily.maxDays)
        for (i, d) in f.days.enumerated() {
            if i > 0 { #expect(d.startS > f.days[i - 1].startS) }
            #expect(d.tempMaxC.isNaN || d.tempMaxC >= d.tempMinC)
            #expect(d.precipMm.isNaN || d.precipMm >= 0)
        }
        F.expectDaysInRange(f)
        // the member order does not matter (:5350-5356)
        F.expectIdentical(f, try F.blendRaw(place, members.reversed(), now: now))
        return true
    }

    // C: /blend/fuzz/oracle (test-blend.c:5360-5411) - property test (SeededRNG), not parity evidence
    @Test func fuzzOracle() throws {
        var r = F.Rand(seed: 20_261_011)
        let places: [(Double, Double, String)] = [  // :5367-5371
            (25.7617, -80.1918, "America/New_York"), (51.5074, -0.1278, "Europe/London"),
            (-33.8688, 151.2093, "Australia/Sydney"), (61.2, -149.9, ""), (35.68, 139.69, "Asia/Tokyo"),
            (69.65, 18.96, "Europe/Oslo"),
        ]
        var successes = 0
        var failures = 0
        for _ in 0..<fuzzIterations(1500) {
            let pl = places[r.intRange(0, places.count)]
            let place = try F.place(pl.0, pl.1, pl.2)
            let now = Self.t0 + Int64(r.intRange(0, 20 * 86400)) + Int64(r.intRange(0, 86400))
            let base = now - now % Self.h
            var members: [WxMember] = []
            for id in F.fuzzIDs where r.double() < 0.45 {
                members.append(try Self.fuzzMember(&r, id, base: base))
            }
            // shuffle the order a little (:5389-5395)
            var i = members.count
            while i > 1 {
                let j = r.intRange(0, i)
                members.swapAt(i - 1, j)
                i -= 1
            }
            // :5396-5402 (the outcome of the same, deterministic blend)
            if try Self.checkFuzzCase(place, members, now) { successes += 1 } else { failures += 1 }
        }
        #expect(successes > 500)  // :5408
        #expect(failures > 20)  // :5409
    }

    /// nasty_precip (test-blend.c:4064-4074).
    static let nastyPool: [Double] = [
        0.0, 4.9e-324, 1e-310, 1e-9, 0.05, 0.073, 0.1, 0.21, 0.37, 1.0, 7.6, 100.0, 499.99999999999994, 500.0,
        2 * F.dmin, 3 * F.dmin, 4 * F.dmin, 5 * F.dmin, 8 * F.dmin, 11 * F.dmin, 47 * F.dmin, 113 * F.dmin,
        1465 * F.dmin, 1e-323, 3.78e-321, Double.leastNormalMagnitude, 1e-300, 1e-12, 0.9999999e-9, 1.0000001e-9,
    ]

    /// nasty_pick (test-blend.c:4076-4093).
    static func nastyPick(_ r: inout F.Rand, _ lo: Double, _ hi: Double) -> Double {
        switch r.intRange(0, 6) {
        case 0: lo
        case 1: hi
        case 2: .nan
        case 3: lo.nextUp  // nextafter(lo, hi): every caller has lo < hi
        case 4: hi.nextDown  // nextafter(hi, lo)
        default: r.rnd(lo, hi)
        }
    }

    /// nasty_member (test-blend.c:4095-4119).
    static func nastyMember(_ r: inout F.Rand, _ id: (src: String, model: String), base: Int64) throws -> WxMember {
        var m = try F.newMember(id.src, id.model)
        let first = r.intRange(-3, 6)
        let len = r.intRange(0, 80)
        for i in 0..<len {
            var x = WxHour(tS: base + Int64(first + i) * h)
            x.tempC = nastyPick(&r, WxLimits.tempMinC, WxLimits.tempMaxC)
            x.feelsC = nastyPick(&r, WxLimits.tempMinC, WxLimits.tempMaxC)
            x.precipMm = r.double() < 0.3 ? .nan : nastyPool[r.intRange(0, nastyPool.count)]
            x.precipProb = nastyPick(&r, 0, 100)
            x.cloudPct = nastyPick(&r, 0, 100)
            x.windKmh = nastyPick(&r, 0, WxLimits.windMaxKmh)
            x.gustKmh = nastyPick(&r, 0, WxLimits.windMaxKmh)
            x.humidityPct = nastyPick(&r, 0, 100)
            x.wmo = r.double() < 0.5 ? -1 : r.intRange(0, 100)
            // near the ends of the supported range the builder refuses the hour: skip it (:4114-4116)
            if x.tS >= WxLimits.timeMinS && x.tS < WxLimits.timeMaxS {
                let added = m.addHour(x)
                #expect(added)
            }
        }
        return m
    }

    // C: /blend/fuzz/only-not-found-fails (test-blend.c:4121-4196) - property test (SeededRNG)
    @Test func fuzzOnlyNotFoundFails() throws {
        var r = F.Rand(seed: 31337)
        let cases: [(Double, Double, String, Int64)] = [  // :4130-4141
            (47.56, -52.71, "America/St_Johns", 1_194_004_800 + 36 * 3600), (-23.55, -46.63, "America/Sao_Paulo", 1_455_796_800 + 48 * 3600),
            (23.11, -82.37, "America/Havana", 1_793_419_200 + 24 * 3600), (-13.83, -171.76, "Pacific/Apia", 1_325_203_200),
            (-31.55, 159.08, "Australia/Lord_Howe", 1_791_676_800), (27.7, 85.3, "Asia/Kathmandu", 1_791_676_800),
            (1.87, -157.4, "Pacific/Kiritimati", 1_791_676_800), (25.7617, -80.1918, "America/New_York", 1_793_419_200),
            (51.5074, -0.1278, "Europe/London", 1_792_796_400), (0.0, 0.0, "", 1_791_676_800),
        ]
        var ok = 0
        var notFound = 0
        var withQuarters = 0
        for iter in 0..<fuzzIterations(2500) {
            let c = cases[r.intRange(0, cases.count)]
            let place = try F.place(c.0, c.1, c.2)
            var now = c.3 + Int64(r.intRange(-5 * 86400, 5 * 86400))
            if r.double() < 0.1 {
                now = r.boolean() ? WxLimits.timeMinS + Int64(r.intRange(0, 100)) * 600 : WxLimits.timeMaxS - 1 - Int64(r.intRange(0, 100)) * 600
            }
            let base = now - now % Self.h
            var members: [WxMember] = []
            for id in F.fuzzIDs where r.double() < 0.5 {
                members.append(try Self.nastyMember(&r, id, base: base))
            }
            // HRRR 15-minute member: random runs of nasty amounts (:4160-4173)
            var q = try F.newMember("open-meteo", "hrrr15")
            let qfirst = (now - now % 900) - 900 * Int64(r.intRange(-1, 3))
            let nq = r.intRange(0, 20)
            let uniform = r.boolean()
            let u = Self.nastyPool[r.intRange(0, Self.nastyPool.count)]
            for i in 0..<nq {
                if r.double() < 0.03 { continue }
                let qq = WxQuarter(tS: qfirst + Int64(i) * 900, precipMm: uniform ? u : Self.nastyPool[r.intRange(0, Self.nastyPool.count)])
                if qq.tS >= WxLimits.timeMinS && qq.tS < WxLimits.timeMaxS { q.addQuarter(qq) }
            }
            members.append(q)
            do {
                let fc = try F.blendRaw(place, members, now: now)
                ok += 1
                F.expectDaysInRange(fc)
                if !fc.quarters.isEmpty { withQuarters += 1 }
            } catch {
                #expect(error.code == .notFound, "iteration \(iter): blend failed with \(error.message)")  // :4184-4185
                notFound += 1
            }
        }
        #expect(ok > 1000)  // :4192
        #expect(notFound > 10)  // :4193
        #expect(withQuarters > 100)  // :4194
    }
}
