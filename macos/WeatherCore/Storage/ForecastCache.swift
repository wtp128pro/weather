// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ForecastCache.swift - the bounded on-disk cache of the latest blended
// WxForecast per place (forecasts.json); a port of src/storage/wx-cache.{h,c}.
// It shows stale data instantly and when offline.
//
// File: <cache directory>/weather/forecasts.json, compact JSON (no blanks)
// ending in one '\n', entries least recently used first (wx-cache.h:7-11,
// wx-cache.c:539-616):
//   {"version":1,"entries":[{"fetched_at_ms":N,"forecast":{
//      "place":{<as in places.json>},"generated_s":N,
//      "hours":[{"t":N,"temp":D,"feels":D,"precip":D,"precip_max":D,"prob":D,
//                "cloud":D,"wind":D,"gust":D,"humidity":D,"spread":D,
//                "members":U,"cond":I,"day":true|false},..],
//      "quarters":[[t,D],..],
//      "days":[{"start":N,"tmax":D,"tmin":D,"precip":D,"prob":D,"cloud":D,"cond":I},..],
//      "sources":[{"id":S,"name":S,"attribution":S,"url":S,"state":I,"error":I,"members":U},..]}}]}
// A NaN number is written as null. "cond", "state" and "error" are the C enum
// ordinals (WxCondition 0...14, WxSourceState 0...2, error -1 or 0...7).
//
// There is no expiry by age: an entry lives until it is evicted (50 places,
// least recently used first) or removed. The age returned by `get` is wall
// clock time since the fetch and is only for display.

import Foundation

/// The forecast cache (WxCache): at most `maxPlaces` forecasts keyed by
/// `WxPlace.key`, in recency order, persisted as forecasts.json.
///
/// Not Sendable: one isolation domain owns a cache (C: "the thread that owns
/// the cache"), normally the main actor. A cache may be created and loaded on
/// a worker and then handed to its owner (the C start-up pattern). The cache
/// never saves by itself: after `put`/`remove`, schedule a save when
/// `isDirty` is true. `load` and `save` are blocking file operations; prefer
/// `saveAsync` while the UI runs.
public final class WxForecastCache {
    /// Maximum number of forecasts held; storing a new one evicts the least
    /// recently used (WX_CACHE_MAX_PLACES, wx-cache.h:43).
    public static let maxPlaces = 50
    /// Largest number of hourly entries that `put` accepts and `load` keeps
    /// (WX_CACHE_MAX_HOURS, wx-cache.h:45).
    public static let maxHours = 240
    /// Largest number of 15-minute entries that `put` accepts and `load`
    /// keeps (WX_CACHE_MAX_QUARTERS, wx-cache.h:47).
    public static let maxQuarters = 96
    /// Largest forecasts.json that `load` reads (WX_CACHE_MAX_FILE_BYTES,
    /// wx-cache.h:56). Every file this type writes is smaller.
    public static let maxFileBytes = 8 * 1024 * 1024
    /// The file name under the "weather" cache folder (wx-cache.c:172).
    public static let fileName = "forecasts.json"

    /// The only supported "version" (CACHE_VERSION, wx-cache.c:12).
    static let version: Int64 = 1
    /// Fetch times are accepted in [fetchedMinMs, fetchedMaxMs): the time
    /// range of the core types, so a hostile file cannot pin a forecast as
    /// "fresh" with a fetch time in the far future (wx-cache.c:19-23).
    static let fetchedMinMs = WxLimits.timeMinS * 1000
    static let fetchedMaxMs = WxLimits.timeMaxS * 1000

    /// One cached forecast (Entry, wx-cache.c:29-34); also a snapshot element.
    struct Entry: Sendable {
        /// `WxPlace.key` of the forecast's place, as UTF-8 bytes.
        let key: [UInt8]
        var forecast: WxForecast
        var fetchedMs: Int64
    }

    /// A private, immutable view of the cache for one save (Snapshot,
    /// wx-cache.c:409-412): the entries least recently used first, the path
    /// and the generation counter at the time it was taken.
    struct SaveSnapshot: Sendable {
        let path: String
        let entries: [Entry]
        let generation: UInt64

        /// Serialises and writes the snapshot atomically on a background
        /// queue, never on the caller's thread (save_worker,
        /// wx-cache.c:1112-1124). A cancellation of the calling task that
        /// arrived before the worker started returns `.cancelled` and writes
        /// nothing; a cancellation after that does not turn a successful write
        /// into an error.
        func perform() async -> Result<Void, WxStoreError> {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            let path = path
            let entries = entries
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let data = Data(WxForecastCache.serialize(entries).utf8)
                    do throws(FileIOError) {
                        try FileIO.writeAtomic(path: path, data: data)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(.file(error)))
                    }
                }
            }
        }
    }

    /// The file `load` and `save` use.
    public let path: String
    /// The wall clock `get` measures ages with (C: g_get_real_time).
    private let clock: any WxClock

    /// Least recently used first (the C GQueue lru); keys are unique.
    private var entries: [Entry] = []
    private var generation: UInt64 = 0 // bumped by every successful put/remove
    private var savedGeneration: UInt64 = 0 // generation of the last load / successful save snapshot
    /// True while `saveAsync` (or a snapshot from `beginSave`) is running.
    private(set) var isSaveInFlight = false

    /// A new empty, clean cache stored at `path`; nil if `path` is empty
    /// (wx_cache_new, wx-cache.c:165-174; C: critical + NULL). Nothing is read
    /// until `load` is called. `clock` supplies the wall time for ages.
    public init?(path: String, clock: any WxClock = SystemClock()) {
        guard !path.isEmpty else {
            return nil
        }
        self.path = path
        self.clock = clock
    }

    /// The C default location relative to a cache directory:
    /// "<directory>/weather/forecasts.json" (wx-cache.c:172, where the C
    /// directory is g_get_user_cache_dir()). On macOS the app passes its
    /// container's Caches directory; nothing here resolves a directory.
    public static func defaultPath(cacheDirectory: String) -> String {
        (cacheDirectory as NSString).appendingPathComponent("weather/" + fileName)
    }

    // MARK: - Reading and editing

    /// The number of forecasts held (at most `maxPlaces`) (wx_cache_get_n_places).
    public var count: Int { entries.count }

    /// The keys held, least recently used first (no recency change).
    var keysByRecency: [String] {
        entries.map { String(decoding: $0.key, as: UTF8.self) }
    }

    /// The index of the entry for a caller's key (find_entry,
    /// wx-cache.c:235-241): nil if `key` is nil, does not end within 24 bytes
    /// (WxPlaces.keyBytes, KEY_BUF_LEN) or is unknown. Keys are compared byte
    /// for byte; a key ends at its first U+0000 like a C string.
    private func index(ofKey key: String?) -> Int? {
        guard let bytes = WxPlaces.keyBytes(key) else {
            return nil
        }
        return entries.firstIndex { $0.key == bytes }
    }

    /// Makes the entry at `i` the most recently used one (touch, wx-cache.c:208-215).
    private func touch(_ i: Int) {
        if i != entries.count - 1 {
            entries.append(entries.remove(at: i))
        }
    }

    /// Stores a forecast for a key not yet held as the most recently used one
    /// and evicts the surplus least recently used entries; the generation is
    /// not changed (insert_entry, wx-cache.c:285-297).
    private func insert(_ entry: Entry) {
        entries.append(entry)
        while entries.count > Self.maxPlaces {
            entries.removeFirst() // evict_oldest, wx-cache.c:258-263
        }
    }

    /// Stores `forecast` under `forecast.place.key` (wx_cache_put,
    /// wx-cache.c:344-366): replaces the forecast of the same key, makes the
    /// place the most recently used one and marks the cache dirty; a new key
    /// in a full cache evicts the least recently used place.
    ///
    /// Returns false, with the cache unchanged, if `forecast` is nil, has more
    /// than `maxHours` hours or `maxQuarters` quarters, or `fetchedAtMs`
    /// (milliseconds since the Unix epoch, UTC) is outside
    /// [WxLimits.timeMinS * 1000, WxLimits.timeMaxS * 1000).
    @discardableResult
    public func put(_ forecast: WxForecast?, fetchedAtMs: Int64) -> Bool {
        guard let forecast, forecast.hours.count <= Self.maxHours,
              forecast.quarters.count <= Self.maxQuarters, fetchedAtMs >= Self.fetchedMinMs,
              fetchedAtMs < Self.fetchedMaxMs
        else {
            return false
        }
        let key = Array(forecast.place.key.utf8)
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].forecast = forecast
            entries[i].fetchedMs = fetchedAtMs
            touch(i)
        } else {
            insert(Entry(key: key, forecast: forecast, fetchedMs: fetchedAtMs))
        }
        generation &+= 1
        return true
    }

    /// The cached forecast for `key` (a `WxPlace.key`) and the milliseconds
    /// elapsed since its fetch time by the wall clock, clamped to >= 0
    /// (wx_cache_get, wx-cache.c:369-380; age_since, :336-341). A hit makes
    /// the place the most recently used one; this does not mark the cache
    /// dirty. Nil (nothing changed) if `key` is nil, 24 bytes or longer, or
    /// has no forecast.
    public func get(key: String?) -> (forecast: WxForecast, ageMs: Int64)? {
        guard let i = index(ofKey: key) else {
            return nil
        }
        touch(i)
        let e = entries[entries.count - 1]
        let age = clock.wallMilliseconds - e.fetchedMs
        return (e.forecast, age > 0 ? age : 0)
    }

    /// Removes the forecast of `key` and marks the cache dirty
    /// (wx_cache_remove, wx-cache.c:383-394). Returns false (unchanged) if
    /// there is none.
    @discardableResult
    public func remove(key: String?) -> Bool {
        guard let i = index(ofKey: key) else {
            return false
        }
        entries.remove(at: i)
        generation &+= 1
        return true
    }

    /// True iff put/remove changed the cache since the last `load`
    /// (successful or not) or the last successful save snapshot
    /// (wx_cache_is_dirty). A save started before the latest change does not
    /// clear it.
    public var isDirty: Bool { generation != savedGeneration }

    // MARK: - Load (wx-cache.c:651-1035)

    /// Synchronously replaces the content with the file at `path`
    /// (wx_cache_load, wx-cache.c:1017-1035). Blocking file I/O.
    ///
    /// Invalid parts are skipped individually: an entry whose forecast is
    /// malformed in any element (place, hour, quarter, day, source, a
    /// non-ascending series, more than `maxHours` hours or `maxQuarters`
    /// quarters, a missing or out-of-range fetch time) is dropped as a whole;
    /// the rest keeps the stored recency order. Out-of-range numbers become
    /// NaN (WxForecast normalisation), they are not rejected. A place key
    /// that repeats an EARLIER accepted entry is skipped even if that entry
    /// was evicted meanwhile. Beyond `maxPlaces` valid entries the least
    /// recently used are dropped. Also removes stale
    /// "<path>.wx-tmp-XXXXXX" files.
    ///
    /// Throws `.pending` (cache untouched) while an asynchronous save runs.
    /// Any other failure leaves the cache EMPTY: `.file` (`isNotFound` for a
    /// missing file - normal on first run -, `.tooLarge` above
    /// `maxFileBytes`, other I/O errors) or `.parse` (not strict JSON, nested
    /// deeper than 32, a "\u0000" escape, wrong shape or unsupported
    /// version). Either way the cache is clean afterwards.
    public func load() throws(WxStoreError) {
        if isSaveInFlight {
            throw StoreJSON.pendingError("cache")
        }
        entries.removeAll()
        var failure: WxStoreError?
        do {
            let root = try StoreJSON.load(path: path, maxBytes: Self.maxFileBytes, what: "cache")
            try fill(from: root)
        } catch {
            failure = error
            entries.removeAll()
        }
        savedGeneration = generation
        if let failure {
            throw failure
        }
    }

    /// Checks the envelope and offers every element of "entries" to
    /// `loadEntry` in file order (load_document, wx-cache.c:990-1014).
    private func fill(from root: StoreJSON.Node?) throws(WxStoreError) {
        let obj = try StoreJSON.rootObject(root, what: "cache", version: Self.version)
        guard let arr = StoreJSON.nodeArray(obj.member("entries")) else {
            throw .parse("cache: missing entries array")
        }
        // Every key accepted earlier in this load, even after its entry was
        // evicted: the first accepted occurrence always wins (wx-cache.c:1002-1008).
        var seen = Set<[UInt8]>()
        for element in arr {
            loadEntry(element, seen: &seen)
        }
    }

    /// Adds one element of "entries" when it is well-formed and its place was
    /// not seen before; skips it silently otherwise (load_entry,
    /// wx-cache.c:947-965).
    private func loadEntry(_ node: StoreJSON.Node, seen: inout Set<[UInt8]>) {
        guard let o = StoreJSON.nodeObject(node),
              let fetched = Self.readInt(o, "fetched_at_ms", Self.fetchedMinMs, Self.fetchedMaxMs - 1),
              let fo = StoreJSON.nodeObject(o.member("forecast")),
              let forecast = Self.forecastFromJSON(fo)
        else {
            return
        }
        let key = Array(forecast.place.key.utf8)
        guard seen.insert(key).inserted else {
            return
        }
        insert(Entry(key: key, forecast: forecast, fetchedMs: fetched))
    }

    /// The double members of an hour and their JSON names, in file order
    /// (hour_fields, wx-cache.c:473-484).
    /// A double member and its JSON key (DoubleField, wx-cache.c:468-471).
    private typealias Field<T> = (name: String, path: WritableKeyPath<T, Double> & Sendable)

    private static let hourFields: [Field<WxBlendHour>] = [
        ("temp", \.tempC), ("feels", \.feelsC), ("precip", \.precipMm), ("precip_max", \.precipMmMax),
        ("prob", \.precipProb), ("cloud", \.cloudPct), ("wind", \.windKmh), ("gust", \.gustKmh),
        ("humidity", \.humidityPct), ("spread", \.tempSpreadC),
    ]

    /// The double members of a day (day_fields, wx-cache.c:486-492).
    private static let dayFields: [Field<WxDay>] = [
        ("tmax", \.tempMaxC), ("tmin", \.tempMinC), ("precip", \.precipMm), ("prob", \.precipProbMax),
        ("cloud", \.cloudPct),
    ]

    /// An integer member within [min, max] (read_int_member, wx-cache.c:700-708).
    private static func readInt(_ o: StoreJSON.Object, _ name: String, _ min: Int64, _ max: Int64) -> Int64? {
        guard let v = StoreJSON.nodeI64(o.member(name)), v >= min, v <= max else {
            return nil
        }
        return v
    }

    /// Every field as a finite number or null (NaN); a missing member or any
    /// other type fails (read_fields, wx-cache.c:671-681).
    private static func readFields<T>(
        _ o: StoreJSON.Object, _ base: inout T, _ fields: [Field<T>]
    ) -> Bool {
        for f in fields {
            guard let v = StoreJSON.nodeDouble(o.member(f.name), allowNull: true) else {
                return false
            }
            base[keyPath: f.path] = v
        }
        return true
    }

    /// One element of "hours" (parse_hour, wx-cache.c:726-743): members
    /// 0...255, cond 0...14, day a boolean; range checks of the numbers are
    /// left to WxForecast.
    private static func parseHour(_ node: StoreJSON.Node) -> WxBlendHour? {
        guard let o = StoreJSON.nodeObject(node), let t = readInt(o, "t", .min, .max) else {
            return nil
        }
        var h = WxBlendHour(tS: t)
        guard readFields(o, &h, hourFields),
              let members = readInt(o, "members", 0, Int64(UInt8.max)),
              let cond = readInt(o, "cond", 0, Int64(WxCondition.count - 1)),
              let condition = WxCondition(rawValue: Int(cond)),
              let day = StoreJSON.nodeBool(o.member("day"))
        else {
            return nil
        }
        h.nMembers = UInt8(members)
        h.condition = condition
        h.isDay = day
        return h
    }

    /// One element of "quarters": an array [t, mm] of an integer and a finite
    /// number (parse_quarter, wx-cache.c:760-773).
    private static func parseQuarter(_ node: StoreJSON.Node) -> WxQuarter? {
        guard let a = StoreJSON.nodeArray(node), a.count == 2, let t = StoreJSON.nodeI64(a[0]),
              let mm = StoreJSON.nodeDouble(a[1], allowNull: false)
        else {
            return nil
        }
        return WxQuarter(tS: t, precipMm: mm)
    }

    /// One element of "days" (parse_day, wx-cache.c:790-802).
    private static func parseDay(_ node: StoreJSON.Node) -> WxDay? {
        guard let o = StoreJSON.nodeObject(node), let start = readInt(o, "start", .min, .max) else {
            return nil
        }
        var d = WxDay(startS: start)
        guard readFields(o, &d, dayFields),
              let cond = readInt(o, "cond", 0, Int64(WxCondition.count - 1)),
              let condition = WxCondition(rawValue: Int(cond))
        else {
            return nil
        }
        d.condition = condition
        return d
    }

    /// One element of "sources" (parse_source, wx-cache.c:843-867): four
    /// strings, state 0...2, error -1...7, members 0...UInt32.max; the id,
    /// the https URL and the texts are then validated and sanitised as a new
    /// WxSourceStatus (C: by wx_forecast_new).
    private static func parseSource(_ node: StoreJSON.Node) -> WxSourceStatus? {
        guard let o = StoreJSON.nodeObject(node), let id = StoreJSON.nodeString(o.member("id")),
              let name = StoreJSON.nodeString(o.member("name")),
              let attribution = StoreJSON.nodeString(o.member("attribution")),
              let url = StoreJSON.nodeString(o.member("url")),
              let state = readInt(o, "state", Int64(WxSourceState.ok.rawValue), Int64(WxSourceState.skipped.rawValue)),
              let error = readInt(o, "error", -1, Int64(WxError.Code.unsupported.rawValue)),
              let members = readInt(o, "members", 0, Int64(UInt32.max))
        else {
            return nil
        }
        return try? WxSourceStatus(
            providerIDBytes: id, nameBytes: name, attributionBytes: attribution, attributionURLBytes: url,
            stateOrdinal: Int(state), errorCodeOrdinal: Int(error), nMembers: UInt32(members))
    }

    /// Builds a forecast from the stored "forecast" object; nil if any element
    /// is malformed, an array exceeds the cache limits (240 hours, 96
    /// quarters) or the forecast limits (16 days, 16 sources), or WxForecast
    /// rejects the series (forecast_from_json, wx-cache.c:888-928).
    static func forecastFromJSON(_ fo: StoreJSON.Object) -> WxForecast? {
        guard let place = StoreJSON.placeFromJSON(fo.member("place")),
              let ha = StoreJSON.nodeArray(fo.member("hours")),
              let qa = StoreJSON.nodeArray(fo.member("quarters")),
              let da = StoreJSON.nodeArray(fo.member("days")),
              let sa = StoreJSON.nodeArray(fo.member("sources")),
              let generated = readInt(fo, "generated_s", .min, .max)
        else {
            return nil
        }
        if ha.count > maxHours || qa.count > maxQuarters || da.count > WxLimits.forecastMaxDays
            || sa.count > WxLimits.forecastMaxSources
        {
            return nil
        }
        var hours: [WxBlendHour] = []
        var quarters: [WxQuarter] = []
        var days: [WxDay] = []
        var sources: [WxSourceStatus] = []
        for n in ha {
            guard let h = parseHour(n) else { return nil }
            hours.append(h)
        }
        for n in qa {
            guard let q = parseQuarter(n) else { return nil }
            quarters.append(q)
        }
        for n in da {
            guard let d = parseDay(n) else { return nil }
            days.append(d)
        }
        for n in sa {
            guard let s = parseSource(n) else { return nil }
            sources.append(s)
        }
        return try? WxForecast(
            place: place, generatedS: generated, hours: hours, quarters: quarters, days: days, sources: sources)
    }

    // MARK: - Serialisation (wx-cache.c:467-616)

    /// Appends ,"name":number for every field, null for NaN (append_fields,
    /// wx-cache.c:511-518).
    private static func appendFields<T>(
        _ base: T, _ fields: [Field<T>], to out: inout String
    ) {
        for f in fields {
            out += ",\"" + f.name + "\":"
            StrictJSON.appendDouble(base[keyPath: f.path], to: &out)
        }
    }

    /// Appends the JSON object of one forecast (append_forecast,
    /// wx-cache.c:538-579). Strings go through StrictJSON.appendString and
    /// numbers through StrictJSON.appendDouble, so no control byte is ever
    /// written raw.
    private static func appendForecast(_ f: WxForecast, to out: inout String) {
        out += "{\"place\":"
        StoreJSON.appendPlace(f.place, to: &out)
        out += ",\"generated_s\":\(f.generatedS),\"hours\":["
        for (i, h) in f.hours.enumerated() {
            out += (i > 0 ? "," : "") + "{\"t\":\(h.tS)"
            appendFields(h, hourFields, to: &out)
            out += ",\"members\":\(h.nMembers),\"cond\":\(h.condition.rawValue),\"day\":\(h.isDay ? "true" : "false")}"
        }
        out += "],\"quarters\":["
        for (i, q) in f.quarters.enumerated() {
            out += (i > 0 ? "," : "") + "[\(q.tS),"
            StrictJSON.appendDouble(q.precipMm, to: &out)
            out += "]"
        }
        out += "],\"days\":["
        for (i, d) in f.days.enumerated() {
            out += (i > 0 ? "," : "") + "{\"start\":\(d.startS)"
            appendFields(d, dayFields, to: &out)
            out += ",\"cond\":\(d.condition.rawValue)}"
        }
        out += "],\"sources\":["
        for (i, s) in f.sources.enumerated() {
            out += i > 0 ? ",{\"id\":" : "{\"id\":"
            StrictJSON.appendString(s.providerID, to: &out)
            out += ",\"name\":"
            StrictJSON.appendString(s.name, to: &out)
            out += ",\"attribution\":"
            StrictJSON.appendString(s.attribution, to: &out)
            out += ",\"url\":"
            StrictJSON.appendString(s.attributionURL, to: &out)
            out += ",\"state\":\(s.state.rawValue),\"error\":\(s.errorCodeOrdinal),\"members\":\(s.nMembers)}"
        }
        out += "]}"
    }

    /// The document for `entries`, in the given (stored) order
    /// (snapshot_serialize, wx-cache.c:601-616).
    static func serialize(_ entries: [Entry]) -> String {
        var out = "{\"version\":\(version),\"entries\":["
        out.reserveCapacity(512 + entries.count * 32768)
        for (i, e) in entries.enumerated() {
            out += (i > 0 ? "," : "") + "{\"fetched_at_ms\":\(e.fetchedMs),\"forecast\":"
            appendForecast(e.forecast, to: &out)
            out += "}"
        }
        out += "]}\n"
        return out
    }

    // MARK: - Save (wx-cache.c:1041-1206)

    /// Writes the whole cache (least recently used first) atomically - mode
    /// 0600, missing parents 0700, the old file intact on failure - and marks
    /// it clean (wx_cache_save, wx-cache.c:1042-1057). Saves even when clean.
    /// Blocking: call it off the main thread or prefer `saveAsync`. Throws
    /// `.pending` while an asynchronous save runs and `.file` on an I/O
    /// failure (the dirty flag and the old file are unchanged).
    public func save() throws(WxStoreError) {
        if isSaveInFlight {
            throw StoreJSON.pendingError("cache")
        }
        do {
            try FileIO.writeAtomic(path: path, data: Data(Self.serialize(entries).utf8))
        } catch {
            throw .file(error)
        }
        savedGeneration = generation
    }

    /// Saves a snapshot of the cache, serialised and written on a background
    /// queue (wx_cache_save_async/_finish, wx-cache.c:1170-1206). The snapshot
    /// is taken before the first suspension (cheap: the forecasts are
    /// immutable values); edits made meanwhile keep the cache dirty. While it
    /// runs, `save`, `load` and another `saveAsync` throw `.pending`.
    /// Cancelling the calling task before the write starts throws
    /// `.cancelled` and writes nothing. Saves even when clean. Resumes on the
    /// caller's isolation; the cache is kept alive until the save finishes.
    public func saveAsync(isolation: isolated (any Actor)? = #isolation) async throws(WxStoreError) {
        let snapshot = try beginSave()
        let outcome = await snapshot.perform()
        try finishSave(generation: snapshot.generation, outcome)
    }

    /// The synchronous half of `saveAsync`: refuses with `.pending` if a save
    /// runs, else snapshots the cache and marks the save in flight
    /// (snapshot_take, wx-cache.c:451-465).
    func beginSave() throws(WxStoreError) -> SaveSnapshot {
        if isSaveInFlight {
            throw StoreJSON.pendingError("cache")
        }
        isSaveInFlight = true
        return SaveSnapshot(path: path, entries: entries, generation: generation)
    }

    /// The completion half of `saveAsync` (save_done, wx-cache.c:1148-1167):
    /// clears the in-flight flag; on success the cache is clean as of the
    /// snapshot generation.
    func finishSave(generation snapshotGeneration: UInt64, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError) {
        isSaveInFlight = false
        switch outcome {
        case .success:
            savedGeneration = snapshotGeneration
        case .failure(let error):
            throw error
        }
    }
}
