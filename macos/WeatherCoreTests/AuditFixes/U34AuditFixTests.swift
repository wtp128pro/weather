// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U34AuditFixTests.swift - regression tests of the audit fixes of the blend,
// weights and local bias (findings U03-F1, U03-F2 and U04-F1):
//   - U03-F1: every Blend test uses the legacy "Testville" place, so the
//     precipitation-probability consensus mix of the regional path
//     (Blend.swift, blendBucket) ran in no test; pinned here on a real place;
//   - U03-F2: the blend looks each weight up once per member, variable and
//     horizon class; every blended value must stay what one
//     WxWeights.weight call per member, field and hour gives (the speed-up
//     itself is a measurement, not a test: RUN/work/u34/bench, U34 verifier;
//     a wall-clock comparison here would fail under load for the wrong reason);
//   - U04-F1: WxLocalBias.load keeps only well-formed place records, so a
//     hand-edited local-bias.json cannot trap the app at every launch.

import Foundation
import Testing

@testable import WeatherCore

@Suite struct U34AuditFixTests {
    typealias F = BlendFixture
    static let h = BlendFixture.h
    static let t0 = BlendFixture.t0
    static let nowS = BlendFixture.nowS

    static func place(_ name: String, _ admin1: String, _ country: String, _ code: String,
                      _ lat: Double, _ lon: Double, _ tz: String) throws(WxError) -> WxPlace {
        try WxPlace(name: name, admin1: admin1, country: country, countryCode: code, lat: lat, lon: lon, timezone: tz)
    }

    // MARK: - U03-F1: the consensus mix of the regional path

    /// Five precipitation members at Berlin, only open-meteo:gfs reports a probability (10 %):
    /// fewer than half report, and their probability weight (1.0) is below 0.35 of the amount
    /// weight (11.5), so a real place mixes in the wet share of the amounts; the legacy test
    /// place at the same spot keeps the one reported value.
    @Test func regionalPathMixesConsensusIntoSparseProbability() throws {
        let specs: [(src: String, model: String, mm: Double, prob: Double)] = [
            ("open-meteo", "ecmwf", 1.0, .nan), ("open-meteo", "icon", 0.5, .nan), ("open-meteo", "gfs", 0.0, 10),
            ("open-meteo", "ukmo", 0.0, .nan), ("met-no", "ecmwf", 0.2, .nan),
        ]
        var fx = F.Fx()
        for s in specs {
            try fx.add(s.src, try F.member(s.src, s.model, first: Self.t0 + 11 * Self.h, count: 6, F.Vals(precip: s.mm, prob: s.prob)))
        }
        let tS = Self.t0 + 12 * Self.h  // horizon 0: band 0
        let berlin = try Self.place("Berlin", "Berlin", "Germany", "DE", 52.52, 13.405, "Europe/Berlin")
        let region = WxGeo.region(for: berlin)
        #expect(region == .centralEurope)
        var all = 0.0, wet = 0.0, probWeight = 0.0
        for s in specs {
            let w = WxWeights.weight(sourceID: s.src, modelID: s.model, variable: .precipMm, horizonH: 0, region: region)
            all += w
            wet += s.mm >= 0.1 ? w : 0
            if s.prob.isFinite {
                probWeight += WxWeights.weight(sourceID: s.src, modelID: s.model, variable: .precipProb, horizonH: 0, region: region)
            }
        }
        try #require(probWeight > 0 && probWeight < 0.35 * all, "the mix needs a sparse reporter: \(probWeight) of \(all)")
        let consensus = 100.0 * wet / all
        let want = (10.0 * probWeight + consensus * (all - probWeight)) / all
        let real = try F.hourAt(try F.blend(fx, berlin, Self.nowS), tS)
        #expect(abs(real.precipProb - want) <= 1e-9, "Berlin: got \(real.precipProb) want \(want)")
        #expect(real.precipProb > 60)  // 10 % reported, about 74 % of the amount weight wet

        let legacy = try F.hourAt(try F.blend(fx, try F.place(52.52, 13.405, "Europe/Berlin"), Self.nowS), tS)
        #expect(legacy.precipProb == 10, "legacy Testville path: \(legacy.precipProb)")
    }

    // MARK: - U03-F2: the per-blend weight memo keeps every value

    /// A member with distinct values per member (`salt`) and hour, so the weights decide the medians.
    static func member(_ src: String, _ model: String, hours n: Int, salt k: Int) throws(WxError) -> WxMember {
        try F.member(src, model, first: t0 + 11 * h, count: n) { hour, i in
            let x = Double((i + k) % 24)
            hour.tempC = 10 + x * 0.3 + Double(k) * 0.37
            hour.feelsC = 9 + x * 0.3 - Double(k) * 0.21
            hour.precipMm = (i + k) % 5 == 0 ? 0.4 + Double(k) * 0.05 : 0
            hour.precipProb = src == "met-no" || src == "dwd-brightsky" ? .nan : Double((i * 7 + k * 11) % 100)
            hour.cloudPct = Double((i * 13 + k * 17) % 100)
            hour.windKmh = 12 + Double(k) + Double(i % 7)
            hour.gustKmh = 20 + Double(k) * 1.5 + Double(i % 5)
            hour.humidityPct = 60 + Double(k * 3) - Double(i % 9)
            hour.wmo = [0, 3, 61, 80, 45][(i + k) % 5]
        }
    }

    /// The members in the blend's order, one result per source in first-use order.
    static func results(_ specs: [(String, String, Int)]) throws(WxError) -> [WxSourceResult] {
        var fx = F.Fx()
        for (k, s) in specs.enumerated() {
            try fx.add(s.0, try member(s.0, s.1, hours: s.2, salt: k))
        }
        return fx.results
    }

    /// The real places of every weight path: .us (nws, hrrr past its 48 h cutoff), .canada (eccc,
    /// hrrr), .centralEurope (dwd, knmi), .world (an unknown pair).
    static func memoCases() throws(WxError) -> [(place: WxPlace, results: [WxSourceResult])] {
        [
            (try place("New York", "New York", "United States", "US", 40.71, -74.0, "America/New_York"),
             try results([("nws", "nws", 100), ("open-meteo", "hrrr", 72), ("open-meteo", "nbm", 100),
                          ("open-meteo", "ecmwf", 100), ("open-meteo", "gfs", 100), ("met-no", "ecmwf", 100)])),
            (try place("Toronto", "Ontario", "Canada", "CA", 43.65, -79.38, "America/Toronto"),
             try results([("eccc", "hrdps", 48), ("open-meteo", "hrrr", 72), ("open-meteo", "gem", 100),
                          ("open-meteo", "ecmwf", 100), ("met-no", "ecmwf", 100)])),
            (try place("Berlin", "Berlin", "Germany", "DE", 52.52, 13.405, "Europe/Berlin"),
             try results([("open-meteo", "icon", 100), ("dwd-brightsky", "mosmix", 100), ("open-meteo", "knmi", 60),
                          ("open-meteo", "ecmwf", 100), ("open-meteo", "gfs", 100), ("met-no", "ecmwf", 100)])),
            (try place("Tokyo", "Tokyo", "Japan", "JP", 35.68, 139.69, "Asia/Tokyo"),
             try results([("open-meteo", "ecmwf", 100), ("open-meteo", "gfs", 100), ("open-meteo", "icon", 100),
                          ("other", "x1", 100)])),
        ]
    }

    /// Every hour of the blend of a real place equals, bit for bit, the weighted median of its
    /// members with one WxWeights.weight call per member, field and hour (what the blend computed
    /// before the memo): temperature, feels-like, humidity, wind, gust, cloud and amount, and the
    /// probability wherever at least half the amount members report one (no consensus mix).
    /// `now` is on the hour (U34 verifier handoff), so one hour is exactly 48 h ahead: HRRR's last
    /// weighted hour, which a memo class boundary at ">= 48 h" would merge with the hours after it.
    @Test func weightMemoKeepsEveryBlendedValue() throws {
        let nowS = Self.t0 + 12 * Self.h
        for c in try Self.memoCases() {
            let checked = try Self.expectBlendMatchesPerCallMedians(c.place, c.results, nowS: nowS)
            #expect(checked >= 8 * 90, "\(c.place.name): \(checked) values checked")
        }
    }

    /// Checks every blended value of `place` against one WxWeights.weight call per member, field
    /// and hour; returns how many values it compared.
    static func expectBlendMatchesPerCallMedians(_ place: WxPlace, _ results: [WxSourceResult], nowS: Int64,
                                                 sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let fields: [(name: String, variable: WxVar, lo: Double, hi: Double, get: (WxHour) -> Double, out: (WxBlendHour) -> Double)] = [
            ("temp", .temp, WxLimits.tempMinC, WxLimits.tempMaxC, \.tempC, \.tempC),
            ("feels", .temp, WxLimits.tempMinC, WxLimits.tempMaxC, \.feelsC, \.feelsC),
            ("humidity", .humidity, WxLimits.percentMin, WxLimits.percentMax, \.humidityPct, \.humidityPct),
            ("wind", .wind, 0, WxLimits.windMaxKmh, \.windKmh, \.windKmh),
            ("gust", .wind, 0, WxLimits.windMaxKmh, \.gustKmh, \.gustKmh),
            ("cloud", .cloud, WxLimits.percentMin, WxLimits.percentMax, \.cloudPct, \.cloudPct),
            ("precip", .precipMm, 0, WxLimits.precipMaxMmH, \.precipMm, \.precipMm),
            ("prob", .precipProb, WxLimits.percentMin, WxLimits.percentMax, \.precipProb, \.precipProb),
        ]
        let fc = try WxBlend.forecast(place: place, results: results, nowS: nowS)
        let members = results.flatMap(\.members)
        let region = WxGeo.region(for: place, hasNWS: members.contains { $0.sourceID == "nws" })
        var checked = 0
        for out in fc.hours {
            let ahead = Double(out.tS - nowS)
            let horizonH = (ahead > 0 ? ahead : 0) / Double(Self.h)
            let hours = members.map { m in m.hours.first { $0.tS == out.tS } }
            var counts: [String: Int] = [:]
            for f in fields {
                var values: [Double] = [], weights: [Double] = []
                for (m, hour) in zip(members, hours) {
                    guard let hour, WxLimits.valueInRange(f.get(hour), f.lo, f.hi) else { continue }
                    let w = WxWeights.weight(
                        sourceID: m.sourceID, modelID: m.modelID, variable: f.variable, horizonH: horizonH, region: region)
                    guard w > 0 else { continue }
                    values.append(f.get(hour))
                    weights.append(w)
                }
                counts[f.name] = values.count
                if f.name == "prob" && values.count * 2 < (counts["precip"] ?? 0) {
                    continue  // the consensus mix applies (pinned above)
                }
                let want = WxWeightedMedian.median(values: values, weights: weights)
                #expect(F.sameBits(f.out(out), want), "\(place.name) \(f.name) at +\(horizonH) h: \(f.out(out)) vs \(want)",
                        sourceLocation: sourceLocation)
                checked += 1
            }
        }
        return checked
    }

    // MARK: - U04-F1: malformed local-bias.json records

    /// One stored place record as JSON; the arrays default to the 24 zeros of a new record.
    static func record(
        biasC: [Double] = Array(repeating: 0, count: 24), counts: [Int] = Array(repeating: 0, count: 24),
        lastSampleS: [Int64] = Array(repeating: 0, count: 24), lastUpdateS: Int64 = 0
    ) -> String {
        func list<T>(_ a: [T]) -> String { "[" + a.map { "\($0)" }.joined(separator: ",") + "]" }
        return "{\"biasC\":\(list(biasC)),\"counts\":\(list(counts)),\"lastSampleS\":\(list(lastSampleS)),\"lastUpdateS\":\(lastUpdateS)}"
    }

    /// A well-formed record: six samples of -2 °C at solar hour 5 (lon 0), the last at t0 + 5 h.
    static func goodRecord() -> String {
        var biasC = Array(repeating: 0.0, count: 24), counts = Array(repeating: 0, count: 24)
        var lastSampleS = Array(repeating: Int64(0), count: 24)
        biasC[5] = -2.0
        counts[5] = 6
        lastSampleS[5] = LocalBiasTests.t0 + 5 * 3600
        return record(biasC: biasC, counts: counts, lastSampleS: lastSampleS, lastUpdateS: LocalBiasTests.t0 + 5 * 3600)
    }

    /// Writes `{"places": {key: record, ...}}` and loads it back.
    static func load(_ records: [(String, String)], in dir: TemporaryDirectory) throws -> WxLocalBias {
        let path = dir.appending("local-bias.json").path
        let body = records.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        try Data("{\"places\":{\(body)}}".utf8).write(to: URL(fileURLWithPath: path))
        return WxLocalBias.load(path: path)
    }

    /// The good record is kept as stored and every bad key behaves as a place with nothing learned:
    /// no correction, no summary, no samples, and a new sample is learned from scratch (no trap).
    static func expectOnlyGoodKept(_ loaded: WxLocalBias, bad: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let t0 = LocalBiasTests.t0
        #expect(loaded.places.keys.sorted() == ["good"], sourceLocation: sourceLocation)
        let c = loaded.correctionC(placeKey: "good", lon: 0, at: t0 + 5 * 3600, nowS: t0 + 6 * 3600)
        #expect(abs(c - (-2.0)) < 1e-9, "good record correction \(c)", sourceLocation: sourceLocation)
        for key in bad {
            #expect(loaded.correctionC(placeKey: key, lon: 0, at: t0 + 5 * 3600, nowS: t0 + 6 * 3600) == 0, sourceLocation: sourceLocation)
            #expect(loaded.summary(placeKey: key, nowS: t0 + 6 * 3600) == nil, sourceLocation: sourceLocation)
            #expect(loaded.samples(placeKey: key, lon: 0, at: t0 + 5 * 3600) == 0, sourceLocation: sourceLocation)
            var b = loaded
            let took = b.addSample(placeKey: key, lon: 0, modelTempC: 10, observedTempC: 9, nowS: t0 + 5 * 3600)
            #expect(took, "\(key): sample not taken", sourceLocation: sourceLocation)
            #expect(b.places[key]?.biasC[5] == -1.0, "\(key): \(String(describing: b.places[key]?.biasC[5]))", sourceLocation: sourceLocation)
        }
    }

    /// Arrays that are not 24 long (what an out-of-band edit leaves) are dropped on load; before the
    /// fix the record was installed and the first correctionC / addSample / samples trapped.
    @Test func loadDropsRecordsWithWrongArrayLengths() throws {
        let dir = try TemporaryDirectory("u34-local-bias")
        let loaded = try Self.load(
            [("good", Self.goodRecord()), ("short", Self.record(biasC: [], counts: [], lastSampleS: [])),
             ("long", Self.record(counts: Array(repeating: 1, count: 25))),
             // Each array's own length check (U34 verifier handoff): only biasC short, only
             // lastSampleS short.
             ("shortBias", Self.record(biasC: Array(repeating: 0, count: 23))),
             ("shortSample", Self.record(lastSampleS: Array(repeating: 0, count: 23)))], in: dir)
        Self.expectOnlyGoodKept(loaded, bad: ["short", "long", "shortBias", "shortSample"])
    }

    /// A negative count is dropped on load; before the fix a count of -1 made the next sample's
    /// weight 1 / 0 = +inf and the learned bias non-finite.
    @Test func loadDropsRecordsWithNegativeCounts() throws {
        let dir = try TemporaryDirectory("u34-local-bias")
        var counts = Array(repeating: 0, count: 24)
        counts[5] = -1
        let loaded = try Self.load([("good", Self.goodRecord()), ("negative", Self.record(counts: counts))], in: dir)
        Self.expectOnlyGoodKept(loaded, bad: ["negative"])
    }

    /// Negative stored times (Int64.min) are dropped on load; before the fix `nowS - lastUpdateS`
    /// (strength) and `nowS - lastSampleS[h]` (addSample) overflowed and trapped.
    @Test func loadDropsRecordsWithNegativeTimestamps() throws {
        let dir = try TemporaryDirectory("u34-local-bias")
        var minSample = Array(repeating: Int64(0), count: 24)
        minSample[5] = .min
        var counts = Array(repeating: 0, count: 24)
        counts[5] = 6
        let loaded = try Self.load(
            [("good", Self.goodRecord()), ("minUpdate", Self.record(counts: counts, lastUpdateS: .min)),
             ("minSample", Self.record(lastSampleS: minSample))], in: dir)
        Self.expectOnlyGoodKept(loaded, bad: ["minUpdate", "minSample"])
    }
    /// The 10-member, 240-hour New York blend that measured the memo's speed-up (U03-F2) keeps
    /// every value too, out to 240 h and past each member's own end. Formerly
    /// weightMemoCutsBlendTime(), which compared the blend's wall-clock time with a replay of the
    /// weight calls: a relative timing that a loaded machine could fail for the wrong reason
    /// (U34 verifier handoff); the speed-up stays evidenced by RUN/work/u34/bench.
    @Test func weightMemoKeepsTenMemberBlend() throws {
        let p = try Self.place("New York", "New York", "United States", "US", 40.71, -74.0, "America/New_York")
        let r = try Self.results([
            ("nws", "nws", 156), ("open-meteo", "hrrr", 72), ("open-meteo", "nbm", 240), ("open-meteo", "ecmwf", 240),
            ("open-meteo", "gfs", 240), ("open-meteo", "icon", 240), ("open-meteo", "gem", 240), ("open-meteo", "ukmo", 168),
            ("open-meteo", "meteofrance", 102), ("met-no", "ecmwf", 240),
        ])
        for nowS in [Self.nowS, Self.t0 + 12 * Self.h] {
            let checked = try Self.expectBlendMatchesPerCallMedians(p, r, nowS: nowS)
            #expect(checked >= 7 * 200, "\(checked) values checked at now \(nowS)")
        }
    }
}
