// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ForecastCacheTests.swift - port of the cache groups of
// src/storage/test-storage.c (/cache/*, /store/nul-escape-cache and the cache
// row of every generic /store/* case). Expected values are the C test
// literals, cited as test-storage.c:LINE; the golden file text is derived by
// hand from the C writer (wx-cache.c, wx-store-json.c, wx-fileio.c, cited).
//
// Every file is written below a per-test TemporaryDirectory ($TMPDIR); the
// "/nonexistent/never-used.json" caches of the C tests are never loaded or
// saved. JSON escapes stay TEXT: "\\u0000" in this source is the six bytes
// backslash, 'u', '0', '0', '0', '0', exactly as the C literal "\\u0000".

import Darwin
import Foundation
import Testing
@testable import WeatherCore

/// The cache row of the StoreOps table (k_cache_ops, test-storage.c:1168-1203, 1258-1268).
private enum CacheOps: StoreJSONTests.StoreOps {
    static let name = "cache"
    static let maxFileBytes = WxForecastCache.maxFileBytes
    static let docPrefix = "{\"version\":1,\"entries\":[]" // doc_prefix, test-storage.c:1332

    static func create(_ path: String) throws -> WxForecastCache {
        try #require(WxForecastCache(path: path))
    }

    /// cache_mutate (test-storage.c:1174-1180).
    static func mutate(_ s: WxForecastCache, _ step: Int) throws {
        let f = try CacheData.makeForecast(try CacheData.gridPlace(step), 6, 2, 1, 1, step)
        #expect(s.put(f, fetchedAtMs: CacheData.t0 * 1000 + Int64(step)), "cache_mutate \(step)")
    }

    static func isDirty(_ s: WxForecastCache) -> Bool { s.isDirty }
    static func save(_ s: WxForecastCache) throws(WxStoreError) { try s.save() }
    static func load(_ s: WxForecastCache) throws(WxStoreError) { try s.load() }
    static func fingerprint(_ s: WxForecastCache) -> String { CacheData.fingerprint(s) }
    /// The cache emits no signals (wx-cache.h:17); the C tests skip the
    /// "changed" checks when g_signal_lookup finds none.
    static func setOnChanged(_ s: WxForecastCache, _ body: @escaping () -> Void) {}

    static func beginSave(_ s: WxForecastCache) throws(WxStoreError) -> StoreJSON.SaveJob {
        let snap = try s.beginSave()
        return StoreJSON.SaveJob(
            path: snap.path, data: Data(WxForecastCache.serialize(snap.entries).utf8), generation: snap.generation)
    }

    static func finishSave(
        _ s: WxForecastCache, _ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>
    ) throws(WxStoreError) {
        try s.finishSave(generation: job.generation, outcome)
    }

    static func saveAsync(_ s: WxForecastCache) async throws(WxStoreError) { try await s.saveAsync() }
}

/// The forecast builders and comparisons of test-storage.c:704-722, 883-1089.
private enum CacheData {
    /// T0 (test-storage.c:883): (1768000000 / 3600) * 3600.
    static let t0: Int64 = (1_768_000_000 / 3600) * 3600

    /// make_place (test-storage.c:705-715).
    static func makePlace(_ tag: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
        try WxPlace(
            name: "Place \(tag)", admin1: "Region", country: "Country", countryCode: "US", lat: lat, lon: lon,
            timezone: "America/New_York")
    }

    /// grid_place (test-storage.c:717-722): neighbours more than 20 km apart.
    static func gridPlace(_ i: Int) throws -> WxPlace {
        try makePlace("\(i)", -60.0 + 0.5 * Double(i % 100), -170.0 + 0.7 * Double(i / 100) * 10.0)
    }

    static func gridKey(_ i: Int) throws -> String { try gridPlace(i).key }

    /// make_forecast (test-storage.c:886-948): a valid forecast of the given
    /// shape; `variant` changes every value. Every field is set explicitly.
    static func makeForecast(
        _ place: WxPlace, _ nHours: Int, _ nQuarters: Int, _ nDays: Int, _ nSources: Int, _ variant: Int
    ) throws -> WxForecast {
        let v = Double(variant)
        let hours = (0 ..< nHours).map { i in
            let d = Double(i)
            let precip = Double(i % 5) * 0.31
            let wind = 5.5 + 0.1 * d
            return WxBlendHour(
                tS: t0 + Int64(i) * 3600, tempC: 20.5 + 0.37 * d + v, feelsC: 21.25 - 0.11 * d - v,
                precipMm: precip, precipMmMax: precip * 1.5, precipProb: Double((i * 7) % 101),
                cloudPct: Double((i * 3) % 101), windKmh: wind, gustKmh: wind * 1.5,
                humidityPct: Double(40 + i % 50), tempSpreadC: i % 2 != 0 ? .nan : 1.25,
                nMembers: UInt8(1 + i % 5), condition: WxCondition(rawValue: i % WxCondition.count)!,
                isDay: i % 2 != 0)
        }
        let quarters = (0 ..< nQuarters).map { i in
            WxQuarter(tS: t0 + Int64(i) * 900, precipMm: Double(i % 4) * 0.05 + v * 0.001)
        }
        let days = (0 ..< nDays).map { i in
            let d = Double(i)
            return WxDay(
                startS: t0 + Int64(i) * 86400, tempMaxC: 30.5 - d, tempMinC: 20.25 - d, precipMm: d * 1.75,
                precipProbMax: Double((i * 11) % 101), cloudPct: Double((i * 13) % 101),
                condition: WxCondition(rawValue: (i + 1) % WxCondition.count)!)
        }
        let sources = try (0 ..< nSources).map { i throws(WxError) in
            let state = WxSourceState(rawValue: i % 3)!
            return try WxSourceStatus(
                providerID: "src\(i)", name: "Source \(i)", attribution: "Data from source \(i)",
                attributionURL: "https://example.org/data?a=1&b=2", state: state,
                errorCode: state == .failed ? .http : nil, nMembers: UInt32(i))
        }
        return try WxForecast(
            place: place, generatedS: t0 + 100 + Int64(variant), hours: hours, quarters: quarters, days: days,
            sources: sources)
    }

    /// assert_same_double (test-storage.c:950-958): both NaN, or bit-identical.
    static func same(_ a: Double, _ b: Double) -> Bool {
        (a.isNaN && b.isNaN) || a.bitPattern == b.bitPattern
    }

    /// assert_forecast_equal (test-storage.c:960-1016), NaN-aware and field by field.
    static func expectEqual(_ a: WxForecast, _ b: WxForecast, _ label: String = "",
                            sourceLocation: SourceLocation = #_sourceLocation) {
        func check(_ ok: Bool, _ what: String) {
            #expect(ok, "\(label) \(what)", sourceLocation: sourceLocation)
        }
        check(a.place.name == b.place.name && a.place.admin1 == b.place.admin1, "place names")
        check(a.place.country == b.place.country && a.place.countryCode == b.place.countryCode, "place country")
        check(a.place.timezone == b.place.timezone, "place timezone")
        check(same(a.place.lat, b.place.lat) && same(a.place.lon, b.place.lon), "place coordinates")
        check(a.generatedS == b.generatedS, "generatedS")
        check(a.hours.count == b.hours.count && a.quarters.count == b.quarters.count, "hour/quarter counts")
        check(a.days.count == b.days.count && a.sources.count == b.sources.count, "day/source counts")
        for (i, (x, y)) in zip(a.hours, b.hours).enumerated() {
            check(x.tS == y.tS && x.nMembers == y.nMembers && x.condition == y.condition && x.isDay == y.isDay,
                  "hour \(i) ints")
            let pairs: [(Double, Double)] = [
                (x.tempC, y.tempC), (x.feelsC, y.feelsC), (x.precipMm, y.precipMm), (x.precipMmMax, y.precipMmMax),
                (x.precipProb, y.precipProb), (x.cloudPct, y.cloudPct), (x.windKmh, y.windKmh),
                (x.gustKmh, y.gustKmh), (x.humidityPct, y.humidityPct), (x.tempSpreadC, y.tempSpreadC),
            ]
            for (k, p) in pairs.enumerated() {
                check(same(p.0, p.1), "hour \(i) double \(k): \(p.0) vs \(p.1)")
            }
        }
        for (i, (x, y)) in zip(a.quarters, b.quarters).enumerated() {
            check(x.tS == y.tS && same(x.precipMm, y.precipMm), "quarter \(i)")
        }
        for (i, (x, y)) in zip(a.days, b.days).enumerated() {
            check(x.startS == y.startS && x.condition == y.condition, "day \(i) ints")
            check(same(x.tempMaxC, y.tempMaxC) && same(x.tempMinC, y.tempMinC) && same(x.precipMm, y.precipMm)
                  && same(x.precipProbMax, y.precipProbMax) && same(x.cloudPct, y.cloudPct), "day \(i) doubles")
        }
        for (i, (x, y)) in zip(a.sources, b.sources).enumerated() {
            check(Array(x.providerID.utf8) == Array(y.providerID.utf8) && Array(x.name.utf8) == Array(y.name.utf8)
                  && Array(x.attribution.utf8) == Array(y.attribution.utf8)
                  && Array(x.attributionURL.utf8) == Array(y.attributionURL.utf8), "source \(i) texts")
            check(x.state == y.state && x.errorCodeOrdinal == y.errorCodeOrdinal && x.nMembers == y.nMembers,
                  "source \(i) ints")
        }
    }

    /// forecast_digest (test-storage.c:1018-1089): FNV-1a over every field,
    /// NaN canonicalised.
    static func digest(_ f: WxForecast) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        func bytes<S: Sequence<UInt8>>(_ s: S) {
            for c in s {
                h = (h ^ UInt64(c)) &* 1_099_511_628_211
            }
        }
        func int(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { bytes($0) } }
        func dbl(_ v: Double) { int(Int64(bitPattern: (v.isNaN ? Double.nan : v).bitPattern)) }
        for s in [f.place.name, f.place.admin1, f.place.country, f.place.countryCode, f.place.timezone] {
            bytes(s.utf8)
        }
        dbl(f.place.lat)
        dbl(f.place.lon)
        int(f.generatedS)
        for x in f.hours {
            int(x.tS)
            for v in [x.tempC, x.feelsC, x.precipMm, x.precipMmMax, x.precipProb, x.cloudPct, x.windKmh,
                      x.gustKmh, x.humidityPct, x.tempSpreadC] {
                dbl(v)
            }
            int(Int64(x.nMembers))
            int(Int64(x.condition.rawValue))
            int(x.isDay ? 1 : 0)
        }
        for q in f.quarters {
            int(q.tS)
            dbl(q.precipMm)
        }
        for d in f.days {
            int(d.startS)
            for v in [d.tempMaxC, d.tempMinC, d.precipMm, d.precipProbMax, d.cloudPct] {
                dbl(v)
            }
            int(Int64(d.condition.rawValue))
        }
        for s in f.sources {
            for t in [s.providerID, s.name, s.attribution, s.attributionURL] {
                bytes(t.utf8)
            }
            int(Int64(s.state.rawValue))
            int(Int64(s.errorCodeOrdinal))
            int(Int64(s.nMembers))
        }
        return h
    }

    /// cache_fingerprint (test-storage.c:1182-1203): probes the grid keys
    /// 0..<120 in order with get() (which touches), so recency is part of
    /// the content.
    static func fingerprint(_ c: WxForecastCache) -> String {
        var s = ""
        for i in 0 ..< 120 {
            guard let key = try? gridKey(i) else {
                return "grid place \(i) invalid"
            }
            let before = c.count
            let got = c.get(key: key)
            #expect(c.count == before)
            if let f = got?.forecast {
                s += "\(key)@\(f.generatedS):\(f.hours.count)/\(f.quarters.count)/\(f.days.count)/\(f.sources.count):\(digest(f));"
            }
        }
        return s
    }

    /// put_grid (test-storage.c:2820-2826).
    static func putGrid(_ c: WxForecastCache, _ i: Int) throws {
        let f = try makeForecast(try gridPlace(i), 3, 0, 0, 0, i)
        #expect(c.put(f, fetchedAtMs: t0 * 1000 + Int64(i)), "put_grid \(i)")
    }

    /// has_grid (test-storage.c:2828-2836): a get, so a hit touches.
    static func hasGrid(_ c: WxForecastCache, _ i: Int) throws -> Bool {
        c.get(key: try gridKey(i)) != nil
    }

    /// now_ms (test-storage.c:2693-2697): the wall clock in ms.
    static func nowMs() -> Int64 { SystemClock().wallMilliseconds }

    /// mutate_re (test-storage.c:3035-3050): replaces the first match of
    /// `pattern` (DOTALL) with the literal `replacement`; requires a match.
    static func mutateRE(_ text: String, _ pattern: String, _ replacement: String) throws -> String {
        let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        let m = try #require(re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                             "no match for \(pattern)")
        return ns.replacingCharacters(in: m.range, with: replacement)
    }

    /// entry_text (test-storage.c:3052-3064): the inner text of the single
    /// entry the cache writes for `forecast`.
    static func entryText(_ dir: TemporaryDirectory, _ forecast: WxForecast, _ fetchedMs: Int64) throws -> String {
        let path = dir.appending("entry.json").path
        let c = try CacheOps.create(path)
        #expect(c.put(forecast, fetchedAtMs: fetchedMs))
        #expect(throws: Never.self) { try c.save() }
        let text = try StoreJSONTests.readAll(path)
        let prefix = "{\"version\":1,\"entries\":["
        #expect(text.hasPrefix(prefix)) // test-storage.c:3061
        #expect(text.hasSuffix("]}\n"))
        let bytes = Array(text.utf8)
        return String(decoding: bytes[prefix.utf8.count ..< bytes.count - 3], as: UTF8.self)
    }

    /// make_doc (test-storage.c:3066-3074).
    static func makeDoc(_ entries: [String]) -> String {
        "{\"version\":1,\"entries\":[" + entries.joined(separator: ",") + "]}"
    }

    /// extend_array (test-storage.c:3236-3262): inserts one more element
    /// before `marker`, a copy of the last element starting with `lastStart`
    /// whose first number of 6+ digits is increased by `step`.
    static func extendArray(_ text: String, _ marker: String, _ lastStart: String, _ step: Int64) throws -> String {
        let t = Array(text.utf8), mk = Array(marker.utf8), ls = Array(lastStart.utf8)
        func starts(_ p: Int, _ needle: [UInt8]) -> Bool {
            p + needle.count <= t.count && Array(t[p ..< p + needle.count]) == needle
        }
        let m = try #require((0 ..< t.count).first { starts($0, mk) }, "marker \(marker)")
        let s = try #require((0 ..< m).last { starts($0, ls) }, "element start \(lastStart)")
        let elem = String(decoding: t[s ..< m], as: UTF8.self)
        let re = try NSRegularExpression(pattern: "[0-9]{6,}")
        let match = try #require(re.firstMatch(in: elem, range: NSRange(location: 0, length: (elem as NSString).length)))
        let num = try #require(Int64((elem as NSString).substring(with: match.range)))
        let bumped = (elem as NSString).replacingCharacters(in: match.range, with: "\(num + step)")
        return String(decoding: t[..<m], as: UTF8.self) + "," + bumped + String(decoding: t[m...], as: UTF8.self)
    }
}

@Suite struct ForecastCacheTests {
    // MARK: - Generic /store/* cases, cache row

    @Test func storeRoundtrip() throws {
        // C: /store/roundtrip
        try StoreJSONTests.roundtripAndFiles(CacheOps.self)
    }

    // C: /store/load-errors (test_store_load_errors, test-storage.c:1380-1478), cache row. The
    // generic body asserts the "changed" signal; the C test skips that for the cache, which has none.
    @Test func storeLoadErrors() throws {
        let tmp = try TemporaryDirectory("cache-load-errors")
        let path = tmp.appending("data.json").path
        let fresh = CacheOps.fingerprint(try CacheOps.create("/nonexistent/never-used.json"))
        let o = try CacheOps.create(path)
        let missing = StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }
        #expect(missing?.isNotFound == true, "\(String(describing: missing))")
        #expect(!o.isDirty)
        for (i, doc) in StoreJSONTests.badDocuments.enumerated() {
            try CacheOps.mutate(o, 0) // the load must replace this
            try StoreJSONTests.putFile(path, doc)
            let e = StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }
            #expect(StoreJSONTests.isParse(e), "document \(i): \(String(describing: e))")
            #expect(CacheOps.fingerprint(o) == fresh, "document \(i): emptied")
            #expect(o.count == 0 && !o.isDirty, "document \(i)")
        }
        try StoreJSONTests.putText(path, "garbage")
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try o.load() } != nil)
        try StoreJSONTests.putFile(path, [UInt8](repeating: 0x20, count: CacheOps.maxFileBytes + 1))
        let big = StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }
        #expect(StoreJSONTests.fileKind(big) == .tooLarge(limit: 8 * 1024 * 1024), "\(String(describing: big))")
        try StoreJSONTests.putFile(path, [UInt8](repeating: 0x20, count: CacheOps.maxFileBytes))
        #expect(StoreJSONTests.isParse(StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }))
        #expect(unlink(path) == 0)
        #expect(mkdir(path, 0o700) == 0)
        #expect(StoreJSONTests.fileKind(StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }) == .notRegularFile)
        #expect(rmdir(path) == 0)
        #expect(mkfifo(path, 0o600) == 0)
        #expect(StoreJSONTests.fileKind(StoreJSONTests.caught { () throws(WxStoreError) in try o.load() }) == .notRegularFile)
        #expect(unlink(path) == 0)
    }

    @Test func storeHostileNesting() throws {
        // C: /store/hostile-nesting
        try StoreJSONTests.hostileNesting(CacheOps.self)
    }

    @Test func storeSaveFailure() throws {
        // C: /store/save-failure
        try StoreJSONTests.saveFailure(CacheOps.self)
    }

    @Test func storeSaveAsync() async throws {
        // C: /store/save-async
        try await StoreJSONTests.saveAsyncSnapshot(CacheOps.self)
    }

    @Test func storeSaveAsyncFailureAndCancel() async throws {
        // C: /store/save-async-failure-and-cancel
        try await StoreJSONTests.saveAsyncFailureAndCancel(CacheOps.self)
    }

    // C: /store/save-async-failure-and-cancel (test-storage.c:1643-1704), the cache's own worker:
    // the cache serialises on the worker (wx-cache.h:21-23), so its snapshot job is checked too.
    @Test func cacheSnapshotCancelledBeforeWrite() async throws {
        let tmp = try TemporaryDirectory("cache-cancel")
        let path = tmp.appending("dir/c.json").path
        let c = try CacheOps.create(path)
        try CacheOps.mutate(c, 0)
        let snap = try c.beginSave()
        #expect(StoreJSONTests.isPending(StoreJSONTests.caught { () throws(WxStoreError) in try c.save() }))
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await snap.perform()
        }.value
        let e = StoreJSONTests.caught { () throws(WxStoreError) in try c.finishSave(generation: snap.generation, outcome) }
        #expect(e == .cancelled)
        #expect(c.isDirty)
        #expect(!StoreJSONTests.exists(path), "nothing is written")
        // Not cancelled: the worker writes the snapshot and the cache becomes clean.
        let snap2 = try c.beginSave()
        let ok = await snap2.perform()
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try c.finishSave(generation: snap2.generation, ok) } == nil)
        #expect(!c.isDirty)
        #expect(StoreJSONTests.fileMode(path) == 0o600)
    }

    @Test func storeSaveAsyncMany() async throws {
        // C: /store/save-async-many
        try await StoreJSONTests.saveAsyncMany(CacheOps.self)
    }

    @Test func storeStaleTemps() throws {
        // C: /store/stale-temps (and the cache half of /fileio/stale-temps, test-storage.c:415-421)
        try StoreJSONTests.staleTemps(CacheOps.self)
    }

    @Test func storeFuzz() throws {
        // C: /store/fuzz (GRand seed 777 + k with k = 2 for the cache, test-storage.c:4042)
        try StoreJSONTests.fuzz(CacheOps.self, seed: 779)
    }

    // C: /store/save-async-context (test-storage.c:4358-4387): the completion is
    // delivered in the caller's context - here the caller's actor.
    @MainActor @Test func storeSaveAsyncContext() async throws {
        let tmp = try TemporaryDirectory("cache-ctx")
        let c = try CacheOps.create(tmp.appending("ctx.json").path)
        try CacheOps.mutate(c, 0)
        try await c.saveAsync()
        #expect(pthread_main_np() != 0, "resumed on the main actor")
        #expect(!c.isDirty)
    }

    // C: /store/load-on-worker-thread (test-storage.c:4426-4460): load() on a
    // worker, hand-off, use on the caller (the cache has no "changed" signal).
    @Test func storeLoadOnWorkerThread() async throws {
        let tmp = try TemporaryDirectory("cache-worker")
        let path = tmp.appending("load.json").path
        let w = try CacheOps.create(path)
        for i in 0 ..< 3 {
            try CacheOps.mutate(w, i)
        }
        #expect(throws: Never.self) { try w.save() }
        let want = CacheData.fingerprint(w)
        let (loaded, ok): (WxForecastCache?, Bool) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let c = WxForecastCache(path: path) else {
                    cont.resume(returning: (nil, false))
                    return
                }
                let ok = (try? c.load()) != nil
                cont.resume(returning: (c, ok))
            }
        }
        #expect(ok)
        let c = try #require(loaded)
        #expect(CacheData.fingerprint(c) == want, "usable after the hand-off")
    }

    // C: /store/default-paths (test-storage.c:1964-1993), cache part. The C default is
    // g_get_user_cache_dir()/weather/forecasts.json (:1976-1977); the macOS app passes its
    // container's Caches directory. wx_cache_new("") is NULL (:1991); here init? returns nil.
    @Test func storeDefaultPaths() throws {
        #expect(WxForecastCache.defaultPath(cacheDirectory: "/caches") == "/caches/weather/forecasts.json")
        let c = try #require(WxForecastCache(path: "/tmp/x/y.json"))
        #expect(c.path == "/tmp/x/y.json")
        #expect(WxForecastCache(path: "") == nil)
        #expect(c.count == 0 && !c.isDirty, "new caches are empty and clean (wx-cache.h:71-72)")
    }

    // C: /store/nul-escape-cache (test_store_nul_escape_cache, test-storage.c:3921-3970)
    @Test func storeNulEscapeCache() throws {
        let tmp = try TemporaryDirectory("cache-nul")
        let pa = try CacheData.makePlace("A", 10.0, 10.0)
        let pb = try CacheData.makePlace("B", 20.0, 20.0)
        let ea = try CacheData.entryText(tmp, try CacheData.makeForecast(pa, 4, 3, 2, 2, 1), CacheData.t0 * 1000)
        let eb = try CacheData.entryText(tmp, try CacheData.makeForecast(pb, 4, 3, 2, 2, 2), CacheData.t0 * 1000)
        let path = tmp.appending("c.json").path
        // test-storage.c:3934-3946
        let bad: [(String, String, String)] = [
            ("source id", "\"id\":\"src0\"", "\"id\":\"src0\\u0000x\""),
            ("source id, whole value", "\"id\":\"src0\"", "\"id\":\"\\u0000\""),
            ("source name", "\"name\":\"Source 0\"", "\"name\":\"Source 0\\u0000\\u001b[31mjunk\""),
            ("source attribution", "\"attribution\":\"Data from source 0\"", "\"attribution\":\"Data\\u0000\""),
            ("source url", "\"url\":\"https://example.org/data\\?a=1&b=2\"", "\"url\":\"https://example.org/\\u0000\""),
            ("place name", "\"name\": ?\"Place A\"", "\"name\":\"Place A\\u0000junk\""),
            ("place admin1", "\"admin1\": ?\"Region\"", "\"admin1\":\"\\u0000Region\""),
            ("place timezone", "\"timezone\": ?\"America/New_York\"", "\"timezone\":\"America\\u0000/New_York\""),
            ("entry member name", "\"forecast\":", "\"fore\\u0000cast\":"),
            ("place member name", "\"place\":", "\"pla\\u0000ce\":"),
            ("number member name", "\"generated_s\":", "\"generated\\u0000_s\":"),
        ]
        for (label, pattern, replacement) in bad {
            let mut = try CacheData.mutateRE(ea, pattern, replacement)
            try StoreJSONTests.expectRejected(CacheOps.self, path, CacheData.makeDoc([eb, mut, eb]), label)
        }
        try StoreJSONTests.expectRejected(
            CacheOps.self, path, "{\"version\":1,\"entr\\u0000ies\":[]}", "entries member name")
        try StoreJSONTests.expectRejected(
            CacheOps.self, path, "{\"version\":1,\"entries\":[],\"x\":\"\\u0000\"}", "trailing member")

        // The escaped-backslash form is data, not a NUL: the file loads (test-storage.c:3959-3969).
        let okForm = try CacheData.mutateRE(ea, "\"name\":\"Source 0\"", "\"name\":\"Source\\\\u0000 0\"")
        try StoreJSONTests.putText(path, CacheData.makeDoc([eb, okForm]))
        let c = try CacheOps.create(path)
        #expect(throws: Never.self) { try c.load() }
        #expect(c.count == 2)
        let got = try #require(c.get(key: "10.0000,10.0000"))
        #expect(got.forecast.sources.first?.name == "Source\\u0000 0") // test-storage.c:3969
    }

    // MARK: - /cache/*

    // C: /cache/put-get-age (test_cache_put_get_age, test-storage.c:2706-2776). The refcount and
    // pointer-identity checks become value checks: a WxForecast is an immutable value.
    @Test func cachePutGetAge() throws {
        let c = try CacheOps.create("/nonexistent/never-used.json")
        let miami = try CacheData.makePlace("Miami", 25.7617, -80.1918)
        let f1 = try CacheData.makeForecast(miami, 24, 4, 3, 2, 1)
        let f2 = try CacheData.makeForecast(miami, 24, 4, 3, 2, 2)
        #expect(c.count == 0)
        #expect(!c.isDirty)
        #expect(c.get(key: "25.7617,-80.1918") == nil)

        let t = CacheData.nowMs()
        #expect(c.put(f1, fetchedAtMs: t - 5000))
        #expect(c.isDirty)
        #expect(c.count == 1)
        var got = try #require(c.get(key: "25.7617,-80.1918"))
        CacheData.expectEqual(f1, got.forecast, "f1")
        #expect(got.ageMs >= 5000)
        #expect(got.ageMs < 5000 + 10000) // test-storage.c:2730

        // A replacement stores the new forecast.
        #expect(c.put(f1, fetchedAtMs: t - 4000))
        #expect(c.put(f2, fetchedAtMs: t - 1000))
        #expect(c.count == 1)
        got = try #require(c.get(key: "25.7617,-80.1918"))
        CacheData.expectEqual(f2, got.forecast, "f2")
        #expect(got.ageMs >= 1000)
        #expect(got.ageMs < 11000)

        // The age is clamped at 0 for a time in the future, and large for an old one.
        #expect(c.put(f2, fetchedAtMs: t + 3600 * 1000))
        #expect(c.get(key: "25.7617,-80.1918")?.ageMs == 0)
        #expect(c.put(f2, fetchedAtMs: WxLimits.timeMinS * 1000))
        #expect((c.get(key: "25.7617,-80.1918")?.ageMs ?? 0) > 3600 * 24 * 365 * 1000) // test-storage.c:2755
        #expect(c.put(f2, fetchedAtMs: WxLimits.timeMaxS * 1000 - 1))
        #expect(c.get(key: "25.7617,-80.1918")?.ageMs == 0)

        // Removing.
        #expect(c.remove(key: "25.7617,-80.1918"))
        #expect(c.count == 0)
        #expect(!c.remove(key: "25.7617,-80.1918"))
        #expect(!c.remove(key: nil))
        #expect(!c.remove(key: "nope"))
        #expect(c.get(key: nil) == nil)
        #expect(c.get(key: "") == nil)
        #expect(c.get(key: "123456789012345678901234567890") == nil)
        // A forecast in the cache outlives the caller's copy.
        do {
            let f3 = try CacheData.makeForecast(miami, 5, 0, 0, 0, 3)
            #expect(c.put(f3, fetchedAtMs: t))
        }
        #expect(c.get(key: "25.7617,-80.1918")?.forecast.hours.count == 5)
    }

    // C: /cache/put-get-age, the age rule of age_since (wx-cache.c:336-341) on an injected wall
    // clock: now/1000 - fetched (C integer division), clamped at 0.
    @Test func cacheAgeOnInjectedClock() throws {
        let clock = ManualClock(wallMicroseconds: 1_767_999_600_123_999)
        let c = try #require(WxForecastCache(path: "/nonexistent/never-used.json", clock: clock))
        let f = try CacheData.makeForecast(try CacheData.makePlace("Miami", 25.7617, -80.1918), 2, 0, 0, 0, 1)
        #expect(c.put(f, fetchedAtMs: 1_767_999_595_123))
        #expect(c.get(key: "25.7617,-80.1918")?.ageMs == 5000)
        clock.advanceWall(by: 1)
        #expect(c.get(key: "25.7617,-80.1918")?.ageMs == 5001)
        #expect(c.put(f, fetchedAtMs: 1_767_999_600_125))
        #expect(c.get(key: "25.7617,-80.1918")?.ageMs == 0)
    }

    // C: /cache/limits-reject (test_cache_limits_reject, test-storage.c:2778-2811)
    @Test func cacheLimitsReject() throws {
        let c = try CacheOps.create("/nonexistent/never-used.json")
        let p = try CacheData.makePlace("Limits", 25.0, -80.0)
        let t = CacheData.nowMs()
        let ok = try CacheData.makeForecast(p, 240, 96, 16, 16, 0)
        let manyHours = try CacheData.makeForecast(p, 240 + 1, 0, 0, 0, 0)
        let manyQuarters = try CacheData.makeForecast(p, 3, 96 + 1, 0, 0, 0)
        let maxForecast = try CacheData.makeForecast(p, WxLimits.forecastMaxHours, 0, 0, 0, 0)
        #expect(!c.put(manyHours, fetchedAtMs: t))
        #expect(!c.put(manyQuarters, fetchedAtMs: t))
        #expect(!c.put(maxForecast, fetchedAtMs: t))
        #expect(!c.put(nil, fetchedAtMs: t))
        // test-storage.c:2794-2795
        let badTimes: [Int64] = [-1, .min, .max, WxLimits.timeMinS * 1000 - 1, WxLimits.timeMaxS * 1000,
                                 WxLimits.timeMaxS * 1000 + 1, 0]
        for bt in badTimes {
            #expect(!c.put(ok, fetchedAtMs: bt), "\(bt)")
        }
        #expect(c.count == 0)
        #expect(!c.isDirty)
        // The boundary values are accepted.
        #expect(c.put(ok, fetchedAtMs: WxLimits.timeMinS * 1000))
        #expect(c.put(ok, fetchedAtMs: WxLimits.timeMaxS * 1000 - 1))
        #expect(c.put(ok, fetchedAtMs: t))
        #expect(c.count == 1)
        // A rejected put does not disturb the stored entry.
        #expect(!c.put(manyHours, fetchedAtMs: t))
        let got = try #require(c.get(key: "25.0000,-80.0000"))
        CacheData.expectEqual(ok, got.forecast)
        #expect(WxForecastCache.maxHours == 240 && WxForecastCache.maxQuarters == 96) // wx-cache.h:45,47
        #expect(WxForecastCache.maxPlaces == 50) // wx-cache.h:43
    }

    // C: /cache/lru (test_cache_lru, test-storage.c:2838-2883)
    @Test func cacheLRU() throws {
        let c = try CacheOps.create("/nonexistent/never-used.json")
        for i in 0 ..< 50 {
            try CacheData.putGrid(c, i)
        }
        #expect(c.count == 50)
        // Order now (oldest first): 0..49. get(0) touches it: 1..49,0.
        #expect(c.get(key: try CacheData.gridKey(0)) != nil)
        // A get does not mark the cache dirty by itself.
        let tmp = try TemporaryDirectory("cache-lru")
        let c3 = try CacheOps.create(tmp.appending("c.json").path)
        try CacheData.putGrid(c3, 0)
        #expect(throws: Never.self) { try c3.save() }
        #expect(!c3.isDirty)
        #expect(c3.get(key: try CacheData.gridKey(0)) != nil)
        #expect(!c3.isDirty)

        try CacheData.putGrid(c, 50) // evicts 1 (test-storage.c:2865)
        #expect(c.count == 50)
        #expect(try !CacheData.hasGrid(c, 1))
        #expect(try CacheData.hasGrid(c, 0))
        // Order: 2..49,50,0. Replace 2 (touch): 3..49,50,0,2.
        try CacheData.putGrid(c, 2)
        #expect(c.count == 50)
        try CacheData.putGrid(c, 51) // evicts 3
        #expect(try !CacheData.hasGrid(c, 3))
        #expect(try CacheData.hasGrid(c, 4))
        #expect(try CacheData.hasGrid(c, 2))
        // Removing frees a slot: no eviction on the next new key.
        #expect(c.remove(key: try CacheData.gridKey(5)))
        try CacheData.putGrid(c, 52)
        #expect(try CacheData.hasGrid(c, 4))
        #expect(try !CacheData.hasGrid(c, 5))
        #expect(c.count == 50)
    }

    /// make_extreme_forecast (test-storage.c:2886-2933); every field set explicitly.
    private static func makeExtremeForecast(_ place: WxPlace) throws -> WxForecast {
        let tiny = 1.2345678901234567e-300
        var hours: [WxBlendHour] = []
        for i in 0 ..< 6 {
            let temp: Double
            switch i {
            case 0: temp = -0.0
            case 1: temp = -100.0
            case 2: temp = 70.0
            case 3: temp = -tiny
            default: temp = 0.1 + Double(i)
            }
            let feels: Double = i == 0 ? 69.99999999999999 : .nan
            let precip: Double = i == 0 ? 0.0 : (i == 1 ? WxLimits.precipMaxMmH : tiny)
            let precipMax: Double = i == 1 ? 5e-324 : 1.0 / 3.0
            let prob: Double = i == 0 ? 100.0 : 0.30000000000000004
            let spread: Double = i == 0 ? -0.0 : 0.0
            let members: UInt8 = i == 0 ? 0 : 255
            let cond = try #require(WxCondition(rawValue: WxCondition.count - 1 - i))
            hours.append(WxBlendHour(
                tS: CacheData.t0 + Int64(i) * 3600, tempC: temp, feelsC: feels, precipMm: precip,
                precipMmMax: precipMax, precipProb: prob, cloudPct: 55.5, windKmh: WxLimits.windMaxKmh,
                gustKmh: .nan, humidityPct: 99.99999999999999, tempSpreadC: spread, nMembers: members,
                condition: cond, isDay: i % 2 == 0))
        }
        let quarters = [WxQuarter(tS: CacheData.t0, precipMm: -0.0),
                        WxQuarter(tS: CacheData.t0 + 900, precipMm: WxLimits.precipMaxMmH)]
        let days = [WxDay(startS: CacheData.t0 - 86400, tempMaxC: 70.0, tempMinC: -100.0,
                          precipMm: WxLimits.precipMaxMmDay, precipProbMax: .nan, cloudPct: 0.0, condition: .unknown)]
        let s0 = try WxSourceStatus(providerID: "a", name: "", attribution: "", attributionURL: "", state: .ok,
                                    errorCode: nil, nMembers: 0)
        // "Name \"q\" \\ \xc3\xa9\xe6\x97\xa5 \xf0\x9f\x9a\x80" (test-storage.c:2921), as bytes.
        let name1 = Array("Name \"q\" \\ ".utf8) + [0xC3, 0xA9, 0xE6, 0x97, 0xA5, 0x20, 0xF0, 0x9F, 0x9A, 0x80]
        let s1 = try WxSourceStatus(
            providerIDBytes: Array("b.c_d-e".utf8), nameBytes: name1, attributionBytes: Array("Attribution / 100%".utf8),
            attributionURLBytes: Array("https://example.org:8443/a/b?c=d&e=%C3%A9#frag".utf8), stateOrdinal: 1,
            errorCodeOrdinal: 7, nMembers: UInt32.max)
        return try WxForecast(place: place, generatedS: WxLimits.timeMaxS - 1, hours: hours, quarters: quarters,
                              days: days, sources: [s0, s1])
    }

    // C: /cache/roundtrip (test_cache_roundtrip, test-storage.c:2936-2995)
    @Test func cacheRoundtrip() throws {
        let tmp = try TemporaryDirectory("cache-roundtrip")
        let path = tmp.appending("cfg/weather/forecasts.json").path
        let c = try CacheOps.create(path)
        let p1 = try CacheData.makePlace("Miami", 25.7617, -80.1918)
        let p2 = try CacheData.makePlace(
            String(decoding: Array("Extreme \"quoted\" \\ ".utf8) + [0xC3, 0xBC], as: UTF8.self), -90.0, 180.0)
        let p3 = try CacheData.makePlace("Empty", 0.0, 0.0)
        let p4 = try CacheData.makePlace("Max", 51.5, -0.12)
        let all = [
            try CacheData.makeForecast(p1, 240, 96, 16, 16, 7), try Self.makeExtremeForecast(p2),
            try CacheData.makeForecast(p3, 0, 0, 0, 0, 0), try CacheData.makeForecast(p4, 1, 1, 1, 1, 9),
        ]
        // test-storage.c:2950-2953
        let stamps: [Int64] = [CacheData.t0 * 1000 + 1, 4_133_980_799_999, WxLimits.timeMinS * 1000, CacheData.nowMs()]
        let keys = ["25.7617,-80.1918", "-90.0000,180.0000", "0.0000,0.0000", "51.5000,-0.1200"]
        for i in 0 ..< 4 {
            #expect(c.put(all[i], fetchedAtMs: stamps[i]))
        }
        #expect(throws: Never.self) { try c.save() }
        #expect(!c.isDirty)
        #expect(StoreJSONTests.fileMode(path) == 0o600)
        #expect(StoreJSONTests.fileMode(tmp.appending("cfg/weather").path) == 0o700)

        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(!back.isDirty)
        #expect(back.count == 4)
        for i in 0 ..< 4 {
            let got = try #require(back.get(key: keys[i]), "\(keys[i])")
            CacheData.expectEqual(all[i], got.forecast, keys[i])
            // The fetch time survived: the age matches the stamp (the clock moved by at most seconds).
            let expectAge = max(0, CacheData.nowMs() - stamps[i])
            #expect(got.ageMs >= expectAge - 10000 && got.ageMs <= expectAge, "\(keys[i])")
        }
        for i in 0 ..< 46 {
            try CacheData.putGrid(back, i)
        }
        #expect(back.count == 50) // test-storage.c:2983
        // The stored recency order survives: a fresh load, fill to the cap, one more evicts fa.
        let order = try CacheOps.create(path)
        #expect(throws: Never.self) { try order.load() }
        #expect(order.keysByRecency == keys)
        for i in 0 ..< 46 {
            try CacheData.putGrid(order, i)
        }
        #expect(order.count == 50)
        try CacheData.putGrid(order, 46) // evicts the least recently used of the loaded: fa
        #expect(order.get(key: keys[0]) == nil)
        #expect(order.get(key: keys[1]) != nil)
    }

    // C: /cache/double-precision (test_cache_double_precision, test-storage.c:2996-3031), with
    // SeededRNG(99) instead of g_rand_new_with_seed(99) (test-storage.c:3003).
    @Test func cacheDoublePrecision() throws {
        let tmp = try TemporaryDirectory("cache-double")
        let path = tmp.appending("c.json").path
        let c = try CacheOps.create(path)
        let p = try CacheData.makePlace("Random", 33.3, 44.4)
        var r = SeededRNG(seed: 99)
        var hours: [WxBlendHour] = []
        for i in 0 ..< 240 {
            hours.append(WxBlendHour(
                tS: CacheData.t0 + Int64(i) * 3600,
                tempC: Double.random(in: WxLimits.tempMinC ..< WxLimits.tempMaxC, using: &r),
                feelsC: Double.random(in: -1e-3 ..< 1e-3, using: &r),
                precipMm: Double.random(in: 0 ..< 1e-9, using: &r),
                precipMmMax: Double.random(in: 0 ..< WxLimits.precipMaxMmH, using: &r),
                precipProb: Double.random(in: 0 ..< 100, using: &r),
                cloudPct: Double.random(in: 0 ..< 100, using: &r),
                windKmh: Double.random(in: 0 ..< WxLimits.windMaxKmh, using: &r),
                gustKmh: Double.random(in: 0 ..< WxLimits.windMaxKmh, using: &r),
                humidityPct: Double.random(in: 0 ..< 100, using: &r),
                tempSpreadC: Double.random(in: 0 ..< WxLimits.tempSpreadMaxC, using: &r),
                nMembers: 0, condition: .rain, isDay: false))
        }
        let fc = try WxForecast(place: p, generatedS: CacheData.t0, hours: hours)
        #expect(c.put(fc, fetchedAtMs: CacheData.t0 * 1000))
        #expect(throws: Never.self) { try c.save() }
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        let got = try #require(back.get(key: "33.3000,44.4000"))
        CacheData.expectEqual(fc, got.forecast)
    }

    // C: /cache/load-mutations (test_cache_load_mutations, test-storage.c:3082-3233); the table
    // is test-storage.c:3092-3194 (pattern, replacement, dropped), patterns applied with DOTALL.
    @Test func cacheLoadMutations() throws {
        let tmp = try TemporaryDirectory("cache-mutations")
        let pa = try CacheData.makePlace("A", 10.0, 10.0)
        let pb = try CacheData.makePlace("B", 20.0, 20.0)
        let fb = try CacheData.makeForecast(pb, 4, 3, 2, 2, 2)
        let ea = try CacheData.entryText(tmp, try CacheData.makeForecast(pa, 4, 3, 2, 2, 1), CacheData.t0 * 1000)
        let eb = try CacheData.entryText(tmp, fb, CacheData.t0 * 1000)
        let mutations: [(String, String, Bool)] = [
            // fetch time
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":-5", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":0", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":946684799999", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":4133980800000", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":99999999999999999", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":1.5e12", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":\"x\"", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":null", true),
            ("\"fetched_at_ms\":[0-9]+,", "", true),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":946684800000", false),
            ("\"fetched_at_ms\":[0-9]+", "\"fetched_at_ms\":4133980799999", false),
            // forecast object and its scalar members
            ("\"forecast\":", "\"forecastx\":", true),
            ("\"forecast\":\\{", "\"forecast\":[],\"fx\":{", true),
            ("\"generated_s\":[0-9]+", "\"generated_s\":\"1\"", true),
            ("\"generated_s\":[0-9]+", "\"generated_s\":5", true),
            ("\"generated_s\":[0-9]+", "\"generated_s\":4133980800", true),
            ("\"generated_s\":[0-9]+,", "", true),
            // arrays of the wrong type or missing
            ("\"hours\":\\[", "\"hours\":1,\"hx\":[", true),
            ("\"quarters\":\\[", "\"quarters\":null,\"qx\":[", true),
            ("\"days\":\\[", "\"days\":{},\"dx\":[", true),
            ("\"sources\":\\[", "\"sources\":\"s\",\"sx\":[", true),
            ("\"sources\":\\[", "\"sourcesx\":[", true),
            // hours
            ("\\{\"t\":[0-9]+,\"temp\"", "{\"t\":1,\"temp\"", true),
            ("\\{\"t\":[0-9]+,\"temp\"", "{\"t\":\"x\",\"temp\"", true),
            ("\\{\"t\":[0-9]+,\"temp\"", "{\"temp\"", true),
            ("\\{\"t\":[0-9]+,\"temp\"", "{\"t\":1.5,\"temp\"", true),
            ("\"temp\":[^,]+,", "\"temp\":\"hot\",", true),
            ("\"temp\":[^,]+,", "\"temp\":true,", true),
            ("\"temp\":[^,]+,", "\"temp\":[1],", true),
            ("\"temp\":[^,]+,", "", true),
            ("\"spread\":[^,]+,", "\"spread\":{},", true),
            ("\"members\":[0-9]+", "\"members\":256", true),
            ("\"members\":[0-9]+", "\"members\":-1", true),
            ("\"members\":[0-9]+", "\"members\":2.5", true),
            ("\"members\":[0-9]+", "\"members\":255", false),
            ("\"cond\":[0-9]+,\"day\"", "\"cond\":15,\"day\"", true),
            ("\"cond\":[0-9]+,\"day\"", "\"cond\":-1,\"day\"", true),
            ("\"cond\":[0-9]+,\"day\"", "\"cond\":\"rain\",\"day\"", true),
            ("\"cond\":[0-9]+,\"day\"", "\"cond\":14,\"day\"", false),
            ("\"day\":(true|false)", "\"day\":1", true),
            ("\"day\":(true|false)", "\"day\":null", true),
            ("\"day\":(true|false)", "\"day\":\"true\"", true),
            // numbers out of range are normalised to NAN, not rejected
            ("\"temp\":[^,]+,", "\"temp\":1e9,", false),
            ("\"temp\":[^,]+,", "\"temp\":-1e300,", false),
            ("\"prob\":[^,]+,", "\"prob\":150,", false),
            ("\"wind\":[^,]+,", "\"wind\":-5,", false),
            ("\"temp\":[^,]+,", "\"temp\":null,", false),
            // quarters
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1,2,3]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[\"a\",1]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[{\"t\":1}", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,null]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,-1]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999900,501]", true),
            ("\"quarters\":\\[\\[[0-9]+,[^\\]]*\\]", "\"quarters\":[[1767999901,1]", true),
            // days
            ("\\{\"start\":[0-9]+", "{\"start\":\"x\"", true),
            ("\\{\"start\":[0-9]+", "{\"start\":1.5", true),
            ("\\{\"start\":[0-9]+,", "{", true),
            ("\"tmax\":[^,]+,", "\"tmax\":\"x\",", true),
            ("\"cond\":[0-9]+\\}", "\"cond\":15}", true),
            // sources
            ("\"state\":[0-9]+", "\"state\":3", true),
            ("\"state\":[0-9]+", "\"state\":-1", true),
            ("\"error\":-?[0-9]+", "\"error\":8", true),
            ("\"error\":-?[0-9]+", "\"error\":-2", true),
            ("\"error\":-?[0-9]+", "\"error\":\"x\"", true),
            ("\"members\":[0-9]+\\}", "\"members\":4294967296}", true),
            ("\"members\":[0-9]+\\}", "\"members\":-1}", true),
            ("\"url\":\"[^\"]*\"", "\"url\":\"http://example.org/\"", true),
            ("\"url\":\"[^\"]*\"", "\"url\":\"javascript:alert(1)\"", true),
            ("\"url\":\"[^\"]*\"", "\"url\":\"https://user@example.org/\"", true),
            ("\"url\":\"[^\"]*\"", "\"url\":5", true),
            ("\"url\":\"[^\"]*\"", "\"url\":\"\"", false),
            ("\"id\":\"[^\"]*\"", "\"id\":\"../x\"", true),
            ("\"id\":\"[^\"]*\"", "\"id\":\"\"", true),
            ("\"id\":\"[^\"]*\"", "\"id\":\"UPPER\"", true),
            ("\"id\":\"[^\"]*\"", "\"id\":5", true),
            ("\"name\":\"Source 0\"", "\"name\":5", true),
            ("\"attribution\":\"[^\"]*\"", "\"attribution\":null", true),
            ("\"sources\":\\[", "\"sources\":[5,", true),
            ("\"sources\":\\[", "\"sources\":[null,", true),
            // place
            ("\"lat\":[^,]+", "\"lat\":91", true),
            ("\"lat\":[^,]+", "\"lat\":\"x\"", true),
            ("\"lon\":[^,]+", "\"lon\":181", true),
            ("\"lon\":[^,]+", "\"lon\":null", true),
            ("\"name\": ?\"Place A\"", "\"name\":\"\"", true),
            ("\"name\": ?\"Place A\"", "\"name\":\"a\\u0001b\"", true),
            ("\"name\": ?\"Place A\"", "\"name\":\"a\\u202eb\"", true),
            ("\"country_code\": ?\"US\"", "\"country_code\":\"us\"", true),
            ("\"timezone\": ?\"America/New_York\"", "\"timezone\":\"/etc/passwd\"", true),
            ("\"place\":\\{", "\"place\":[],\"px\":{", true),
            // well-formed variations that must still load
            ("\"admin1\": ?\"Region\"", "\"admin1\":\"R\\u00e9gion \\\"x\\\"\"", false), // test-storage.c:3193
        ]
        #expect(mutations.count == 91, "every row of the C table: test-storage.c:3093-3193 holds 91 rows and 10 comments")
        let path = tmp.appending("c.json").path
        for (i, (pattern, replacement, dropped)) in mutations.enumerated() {
            let bad = try CacheData.mutateRE(ea, pattern, replacement)
            #expect(bad != ea, "\(i)")
            try StoreJSONTests.putText(path, CacheData.makeDoc([bad, eb]))
            let c = try CacheOps.create(path)
            let e = StoreJSONTests.caught { () throws(WxStoreError) in try c.load() }
            #expect(e == nil, "\(i): \(pattern) -> \(replacement): \(String(describing: e))")
            #expect(c.count == (dropped ? 1 : 2), "\(i): \(pattern) -> \(replacement)") // test-storage.c:3207
            let b = try #require(c.get(key: "20.0000,20.0000"), "\(i): the sibling always loads")
            CacheData.expectEqual(fb, b.forecast, "\(i)")
            #expect((c.get(key: "10.0000,10.0000") != nil) == !dropped, "\(i): \(pattern) -> \(replacement)")
            #expect(!c.isDirty, "\(i)")
        }

        // Out-of-range numbers are NAN after loading (test-storage.c:3216-3232).
        let odd = try CacheData.mutateRE(ea, "\"temp\":[^,]+,", "\"temp\":1e9,")
        let odd2 = try CacheData.mutateRE(odd, "\"prob\":[^,]+,", "\"prob\":150,")
        try StoreJSONTests.putText(path, CacheData.makeDoc([odd2]))
        let c = try CacheOps.create(path)
        #expect(throws: Never.self) { try c.load() }
        let a = try #require(c.get(key: "10.0000,10.0000")).forecast
        #expect(a.hours[0].tempC.isNaN)
        #expect(a.hours[0].precipProb.isNaN)
        #expect(!a.hours[0].feelsC.isNaN)
        #expect(a.hours.count == 4) // test-storage.c:3231
    }

    // C: /cache/load-oversized-arrays (test_cache_load_oversized_arrays, test-storage.c:3264-3309);
    // cases test-storage.c:3274-3282.
    @Test func cacheLoadOversizedArrays() throws {
        let tmp = try TemporaryDirectory("cache-oversized")
        let pa = try CacheData.makePlace("A", 10.0, 10.0)
        let path = tmp.appending("c.json").path
        let cases: [(Int, Int, Int, Int, String, String, Int64, Bool)] = [
            (240, 2, 2, 2, "],\"quarters\"", "{\"t\":", 3600, false),
            (240 - 1, 2, 2, 2, "],\"quarters\"", "{\"t\":", 3600, true),
            (3, 96, 2, 2, "],\"days\"", "[", 900, false),
            (3, 96 - 1, 2, 2, "],\"days\"", "[", 900, true),
            (3, 2, 16, 2, "],\"sources\"", "{\"start\":", 86400, false),
            (3, 2, 16 - 1, 2, "],\"sources\"", "{\"start\":", 86400, true),
        ]
        for (i, k) in cases.enumerated() {
            let fa = try CacheData.makeForecast(pa, k.0, k.1, k.2, k.3, 1)
            let ea = try CacheData.entryText(tmp, fa, CacheData.t0 * 1000)
            let big = try CacheData.extendArray(ea, k.4, k.5, k.6)
            try StoreJSONTests.putText(path, CacheData.makeDoc([big]))
            let c = try CacheOps.create(path)
            #expect(throws: Never.self) { try c.load() }
            #expect(c.count == (k.7 ? 1 : 0), "case \(i)") // test-storage.c:3293
        }
        // Sources: 17 do not load.
        let fs = try CacheData.makeForecast(pa, 3, 0, 0, 16, 1)
        let es = try CacheData.entryText(tmp, fs, CacheData.t0 * 1000)
        let seventeen = try CacheData.mutateRE(
            es, "\"sources\":\\[",
            "\"sources\":[{\"id\":\"zz\",\"name\":\"\",\"attribution\":\"\",\"url\":\"\",\"state\":0,\"error\":-1,\"members\":0},")
        try StoreJSONTests.putText(path, CacheData.makeDoc([seventeen]))
        let c = try CacheOps.create(path)
        #expect(throws: Never.self) { try c.load() }
        #expect(c.count == 0)
        // Executor check: the unmodified 16-source entry does load (the drop above is the 17th).
        try StoreJSONTests.putText(path, CacheData.makeDoc([es]))
        #expect(throws: Never.self) { try c.load() }
        #expect(c.count == 1)
    }

    // C: /cache/load-duplicates-and-cap (test_cache_load_duplicates_and_cap, test-storage.c:3310-3410)
    @Test func cacheLoadDuplicatesAndCap() throws {
        let tmp = try TemporaryDirectory("cache-dups")
        let pa = try CacheData.makePlace("A", 10.0, 10.0)
        let ea1 = try CacheData.entryText(tmp, try CacheData.makeForecast(pa, 3, 0, 0, 0, 1), CacheData.t0 * 1000)
        let ea2 = try CacheData.entryText(tmp, try CacheData.makeForecast(pa, 4, 0, 0, 0, 2), CacheData.t0 * 1000 + 5)
        let path = tmp.appending("c.json").path
        do {
            try StoreJSONTests.putText(path, CacheData.makeDoc([ea1, ea2, ea1]))
            let c = try CacheOps.create(path)
            #expect(throws: Never.self) { try c.load() }
            #expect(c.count == 1)
            #expect(c.get(key: "10.0000,10.0000")?.forecast.hours.count == 3) // test-storage.c:3328
        }
        // More than 50 entries: the least recently used (first) are ignored.
        do {
            var entries: [String] = []
            for i in 0 ..< 70 {
                let fc = try CacheData.makeForecast(try CacheData.gridPlace(i), 2, 0, 0, 0, i)
                entries.append(try CacheData.entryText(tmp, fc, CacheData.t0 * 1000 + Int64(i)))
            }
            try StoreJSONTests.putText(path, CacheData.makeDoc(entries))
            let c = try CacheOps.create(path)
            #expect(throws: Never.self) { try c.load() }
            #expect(c.count == 50)
            #expect(!c.isDirty)
            for i in 0 ..< 70 {
                #expect(try CacheData.hasGrid(c, i) == (i >= 20), "\(i)") // test-storage.c:3346
            }
        }
        // A duplicate of an entry that was already evicted is still skipped: A, 50 others, A again.
        do {
            var entries = [ea1]
            for i in 1 ... 50 {
                let fc = try CacheData.makeForecast(try CacheData.gridPlace(i), 2, 0, 0, 0, i)
                entries.append(try CacheData.entryText(tmp, fc, CacheData.t0 * 1000 + Int64(i)))
            }
            entries.append(ea2)
            try StoreJSONTests.putText(path, CacheData.makeDoc(entries))
            let c = try CacheOps.create(path)
            #expect(throws: Never.self) { try c.load() }
            #expect(c.count == 50)
            #expect(c.get(key: "10.0000,10.0000") == nil)
            #expect(try CacheData.hasGrid(c, 1))
            #expect(try CacheData.hasGrid(c, 50))
        }
        // Invalid and duplicate elements do not use up slots: 50 valid entries between 100 bad ones.
        do {
            var entries: [String] = []
            for i in 0 ..< 50 {
                entries += ["{\"fetched_at_ms\":-1}", "{\"fetched_at_ms\":-1}"]
                let fc = try CacheData.makeForecast(try CacheData.gridPlace(i), 2, 0, 0, 0, i)
                entries.append(try CacheData.entryText(tmp, fc, CacheData.t0 * 1000 + Int64(i)))
            }
            try StoreJSONTests.putText(path, CacheData.makeDoc(entries))
            let c = try CacheOps.create(path)
            #expect(throws: Never.self) { try c.load() }
            #expect(c.count == 50)
            for i in 0 ..< 50 {
                #expect(try CacheData.hasGrid(c, i), "\(i)")
            }
        }
        // Non-object elements and a wrong shape of "entries" (test-storage.c:3392-3397).
        let junk = [
            "{\"version\":1,\"entries\":[1,\"x\",null,[],true,{}]}",
            "{\"version\":1,\"entries\":{}}",
            "{\"version\":1,\"entries\":null}",
            "{\"version\":1}",
        ]
        for (i, doc) in junk.enumerated() {
            try StoreJSONTests.putText(path, doc)
            let c = try CacheOps.create(path)
            let e = StoreJSONTests.caught { () throws(WxStoreError) in try c.load() }
            #expect((e == nil) == (i == 0), "\(i)") // test-storage.c:3403
            if let e {
                #expect(e == .parse("cache: missing entries array"), "\(i): \(e)") // wx-cache.c:998
            }
            #expect(c.count == 0)
        }
    }

    // C: /cache/max-file-size (test_cache_max_file_size, test-storage.c:3412-3510): the largest
    // file the module can write is below WX_CACHE_MAX_FILE_BYTES and loads back in full.
    @Test func cacheMaxFileSize() throws {
        let tmp = try TemporaryDirectory("cache-max-size")
        let path = tmp.appending("c.json").path
        let c = try CacheOps.create(path)
        let quotes = String(repeating: "\"", count: WxLimits.placeNameMax)
        let slashes = String(repeating: "\\", count: WxLimits.placeNameMax)
        let url = "https://example.org/" + String(repeating: "a", count: WxLimits.sourceURLMax - "https://example.org/".utf8.count)
        #expect(url.utf8.count == WxLimits.sourceURLMax)
        let tiny = 1.2345678901234567e-300
        let last = WxCondition(rawValue: WxCondition.count - 1)!
        var biggest = 0
        for i in 0 ..< 50 {
            let p = try WxPlace(name: quotes, admin1: slashes, country: quotes, countryCode: "US",
                                lat: -12.345678901234567 + Double(i), lon: -123.45678901234567 + 2 * Double(i),
                                timezone: "America/Argentina/ComodRivadavia")
            let hours = (0 ..< 240).map { h in
                WxBlendHour(tS: CacheData.t0 + Int64(h) * 3600, tempC: -tiny, feelsC: -tiny, precipMm: tiny,
                            precipMmMax: tiny, precipProb: tiny, cloudPct: tiny, windKmh: tiny, gustKmh: tiny,
                            humidityPct: tiny, tempSpreadC: tiny, nMembers: 255, condition: last, isDay: true)
            }
            let quarters = (0 ..< 96).map { WxQuarter(tS: CacheData.t0 + Int64($0) * 900, precipMm: tiny) }
            let days = (0 ..< 16).map { d in
                WxDay(startS: CacheData.t0 + Int64(d) * 86400, tempMaxC: -tiny, tempMinC: -tiny, precipMm: tiny,
                      precipProbMax: tiny, cloudPct: tiny, condition: last)
            }
            let sources = try (0 ..< 16).map { s throws(WxError) in
                // "%031u%c" with 'z' (test-storage.c:3468)
                let digits = String(s)
                let id = String(repeating: "0", count: 31 - digits.count) + digits + "z"
                return try WxSourceStatus(providerID: id, name: quotes, attribution: slashes, attributionURL: url,
                                          state: .failed, errorCode: .unsupported, nMembers: UInt32.max)
            }
            #expect(sources.allSatisfy { $0.name.utf8.count == WxLimits.placeNameMax })
            let fc = try WxForecast(place: p, generatedS: WxLimits.timeMaxS - 1, hours: hours, quarters: quarters,
                                    days: days, sources: sources)
            #expect(c.put(fc, fetchedAtMs: WxLimits.timeMaxS * 1000 - 1))
            if i == 0 {
                let single = tmp.appending("single.json").path
                let one = try CacheOps.create(single)
                #expect(one.put(fc, fetchedAtMs: WxLimits.timeMaxS * 1000 - 1))
                #expect(throws: Never.self) { try one.save() }
                biggest = try StoreJSONTests.readAll(single).utf8.count
            }
        }
        #expect(c.count == 50)
        #expect(throws: Never.self) { try c.save() }
        let text = Array(try StoreJSONTests.readAll(path).utf8)
        #expect(text.count < 8 * 1024 * 1024, "worst-case cache file: \(text.count) bytes (one forecast: \(biggest))") // test-storage.c:3501
        #expect(StrictJSON.check(text))
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(back.count == 50)
    }

    // C: /cache/control-bytes-roundtrip (test_cache_control_bytes_roundtrip, test-storage.c:3511-3547)
    @Test func cacheControlBytesRoundtrip() throws {
        let tmp = try TemporaryDirectory("cache-control")
        let path = tmp.appending("c.json").path
        let c = try CacheOps.create(path)
        // "Q \" B \\ S / P % U \xc3\xbc J \xe6\x97\xa5" (test-storage.c:3519), as bytes.
        let name = String(decoding: Array("Q \" B \\ S / P % U ".utf8) + [0xC3, 0xBC] + Array(" J ".utf8)
                          + [0xE6, 0x97, 0xA5], as: UTF8.self)
        let p = try CacheData.makePlace(name, 1.5, 2.5)
        #expect(throws: WxError.self) {
            try WxSourceStatus(providerID: "a", name: "n\"a\\me", attribution: "at\"tr\\",
                               attributionURL: "https://example.org/\"x", state: .ok, errorCode: nil, nMembers: 1)
        }
        // "n\"a\\me \x01 ctl \xe2\x80\xae" (test-storage.c:3525), as bytes.
        let rawName = Array("n\"a\\me ".utf8) + [0x01] + Array(" ctl ".utf8) + [0xE2, 0x80, 0xAE]
        let s = try WxSourceStatus(
            providerIDBytes: Array("a".utf8), nameBytes: rawName, attributionBytes: Array("at\"tr\\".utf8),
            attributionURLBytes: [], stateOrdinal: 0, errorCodeOrdinal: -1, nMembers: 1)
        #expect(s.name == "n\"a\\me  ctl ") // test-storage.c:3527
        // memset(&h, 0) then t_s and condition (test-storage.c:3530-3533): every double is 0.0.
        let h = WxBlendHour(tS: CacheData.t0, tempC: 0, feelsC: 0, precipMm: 0, precipMmMax: 0, precipProb: 0,
                            cloudPct: 0, windKmh: 0, gustKmh: 0, humidityPct: 0, tempSpreadC: 0, nMembers: 0,
                            condition: .clear, isDay: false)
        let fc = try WxForecast(place: p, generatedS: CacheData.t0, hours: [h], sources: [s])
        #expect(c.put(fc, fetchedAtMs: CacheData.t0 * 1000))
        #expect(throws: Never.self) { try c.save() }
        let text = Array(try StoreJSONTests.readAll(path).utf8)
        #expect(StrictJSON.check(text))
        #expect(text.allSatisfy { $0 >= 0x20 || $0 == 0x0A }, "no raw control byte in the file")
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        let got = try #require(back.get(key: "1.5000,2.5000"))
        CacheData.expectEqual(fc, got.forecast)
    }

    // C: /cache/snapshot-is-stable (test_cache_snapshot_is_stable, test-storage.c:3606-3628): edits
    // after the snapshot are not in the file. saveAsync is beginSave + perform + finishSave; the
    // steps are driven one by one so that the edits land between the snapshot and the write.
    @Test func cacheSnapshotIsStable() async throws {
        let tmp = try TemporaryDirectory("cache-snapshot")
        let path = tmp.appending("c.json").path
        let c = try CacheOps.create(path)
        for i in 0 ..< 5 {
            try CacheData.putGrid(c, i)
        }
        let snap = try c.beginSave()
        // Mutate everything while the worker may be serialising: replace, remove, evict.
        for i in 0 ..< 5 {
            #expect(c.remove(key: try CacheData.gridKey(i)))
        }
        for i in 10 ..< 60 {
            try CacheData.putGrid(c, i)
        }
        let outcome = await snap.perform()
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try c.finishSave(generation: snap.generation, outcome) } == nil)
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(back.count == 5) // test-storage.c:3627
        for i in 0 ..< 5 {
            #expect(try CacheData.hasGrid(back, i))
        }
        #expect(c.isDirty)
        // The public entry point: a save of the current content clears the flag.
        try await c.saveAsync()
        #expect(!c.isDirty)
    }

    // MARK: - Golden files (executor-added; hand-derived from the C writer)

    // FORMAT: wx-cache.c:604-613 (envelope), :541-578 (forecast), :473-492 (field names and order),
    // :514-517 (,"key":number), wx-store-json.c:181-200 (place object with ", " separators),
    // wx-fileio.c:400-417 (strings: only '"' and '\' escaped), :421-441 (doubles: shortest
    // %.15g/%.16g/%.17g, NaN -> null, -0.0 -> "-0.0").
    @Test func cacheFileGolden() throws {
        let tmp = try TemporaryDirectory("cache-golden")
        let path = tmp.appending("weather/forecasts.json").path
        let c = try CacheOps.create(path)
        #expect(throws: Never.self) { try c.save() }
        #expect(try StoreJSONTests.readAll(path) == "{\"version\":1,\"entries\":[]}\n")

        let pa = try CacheData.makePlace("A", 10.0, 10.0)
        let hour = WxBlendHour(tS: 1_767_999_600, tempC: 20.5, feelsC: .nan, precipMm: 0.31, precipMmMax: -0.0,
                               precipProb: 100, cloudPct: 0, windKmh: 5.5, gustKmh: 8.25, humidityPct: 40,
                               tempSpreadC: .nan, nMembers: 3, condition: .rain, isDay: true)
        let day = WxDay(startS: 1_767_999_600, tempMaxC: 30.5, tempMinC: 20.25, precipMm: 0, precipProbMax: 11,
                        cloudPct: 13, condition: .clear)
        let src = try WxSourceStatus(providerID: "src0", name: "Source \"0\"", attribution: "Data from source 0",
                                     attributionURL: "https://example.org/data?a=1&b=2", state: .failed,
                                     errorCode: .http, nMembers: 3)
        let fa = try WxForecast(place: pa, generatedS: 1_767_999_700, hours: [hour],
                                quarters: [WxQuarter(tS: 1_767_999_600, precipMm: 0.05)], days: [day], sources: [src])
        let pb = try CacheData.makePlace("B", -0.0, 1.0 / 3.0)
        let fb = try WxForecast(place: pb, generatedS: 1_767_999_600)
        #expect(c.put(fa, fetchedAtMs: 1_767_999_600_123))
        #expect(c.put(fb, fetchedAtMs: 946_684_800_000))
        #expect(c.get(key: "10.0000,10.0000") != nil) // touches A: B is now the least recently used
        #expect(throws: Never.self) { try c.save() }
        let want = "{\"version\":1,\"entries\":["
            + "{\"fetched_at_ms\":946684800000,\"forecast\":{\"place\":{\"name\": \"Place B\", \"admin1\": \"Region\", \"country\": \"Country\", \"country_code\": \"US\", \"lat\": -0.0, \"lon\": 0.3333333333333333, \"timezone\": \"America/New_York\"},\"generated_s\":1767999600,\"hours\":[],\"quarters\":[],\"days\":[],\"sources\":[]}},"
            + "{\"fetched_at_ms\":1767999600123,\"forecast\":{\"place\":{\"name\": \"Place A\", \"admin1\": \"Region\", \"country\": \"Country\", \"country_code\": \"US\", \"lat\": 10, \"lon\": 10, \"timezone\": \"America/New_York\"},\"generated_s\":1767999700,"
            + "\"hours\":[{\"t\":1767999600,\"temp\":20.5,\"feels\":null,\"precip\":0.31,\"precip_max\":-0.0,\"prob\":100,\"cloud\":0,\"wind\":5.5,\"gust\":8.25,\"humidity\":40,\"spread\":null,\"members\":3,\"cond\":9,\"day\":true}],"
            + "\"quarters\":[[1767999600,0.05]],"
            + "\"days\":[{\"start\":1767999600,\"tmax\":30.5,\"tmin\":20.25,\"precip\":0,\"prob\":11,\"cloud\":13,\"cond\":1}],"
            + "\"sources\":[{\"id\":\"src0\",\"name\":\"Source \\\"0\\\"\",\"attribution\":\"Data from source 0\",\"url\":\"https://example.org/data?a=1&b=2\",\"state\":1,\"error\":2,\"members\":3}]}}"
            + "]}\n"
        #expect(try StoreJSONTests.readAll(path) == want)

        // The golden document loads back (recency order included) and re-saves byte for byte.
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(back.keysByRecency == ["0.0000,0.3333", "10.0000,10.0000"]) // wx_place_key prints -0 as 0.0000
        #expect(throws: Never.self) { try back.save() }
        #expect(try StoreJSONTests.readAll(path) == want)
        CacheData.expectEqual(fa, try #require(back.get(key: "10.0000,10.0000")).forecast)
    }

    // RULES (executor-added): there is no expiry by age (wx-cache.h has no TTL; the age is only
    // reported). A forecast fetched at the earliest accepted time loads and is returned.
    @Test func cacheNoExpiryByAge() throws {
        let tmp = try TemporaryDirectory("cache-no-expiry")
        let path = tmp.appending("c.json").path
        let c = try CacheOps.create(path)
        let f = try CacheData.makeForecast(try CacheData.makePlace("Old", 1.0, 2.0), 2, 0, 0, 0, 1)
        #expect(c.put(f, fetchedAtMs: WxLimits.timeMinS * 1000))
        #expect(throws: Never.self) { try c.save() }
        let back = try CacheOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        let got = try #require(back.get(key: "1.0000,2.0000"))
        #expect(got.ageMs > 3600 * 24 * 365 * 1000)
        CacheData.expectEqual(f, got.forecast)
    }
}
