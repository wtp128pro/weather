// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Places.swift - the ordered list of saved places and places.json; a port of
// src/storage/wx-places.{h,c}. The 50-place cap and the 5 km duplicate rule
// live here and only here: every other unit asks `canAdd` / `add`.

import Foundation

/// The ordered list of saved places, persisted as places.json (WxPlaces).
///
/// Not Sendable: one isolation domain owns a list (C: "the thread that owns
/// the list"), typically the main actor; `saveAsync` writes on a background
/// queue and resumes on the caller's isolation. A list may be created and
/// loaded on a worker and then handed to its owner (the C start-up pattern).
///
/// File format (wx-places.c:486-498, wx-store-json.c:181-200):
/// `{\n  "version": 1,\n  "places": [\n    {...},\n    {...}\n  ]\n}\n`,
/// `{\n  "version": 1,\n  "places": []\n}\n` when empty. macOS adds an
/// optional per-place "units" member ("imperial"/"metric", written last when
/// set) and keeps "version" 1, so older builds still read the file and
/// ignore it; an element without a valid one loads with its units absent.
public final class WxPlaces {
    /// Largest places.json that `load` reads (WX_PLACES_MAX_FILE_BYTES, wx-places.h:47).
    public static let maxFileBytes = 1024 * 1024
    /// A place closer than this great-circle distance to a saved place is a
    /// duplicate (WX_PLACES_DUPLICATE_KM, wx-places.h:52; compared with `<`).
    public static let duplicateKm = 5.0
    /// The most places a list holds (WX_PLACE_MAX, core/wx-types.h:66).
    public static let maxPlaces = WxLimits.placeMax
    /// The file name under the "weather" configuration folder.
    public static let fileName = "places.json"

    /// The only supported "version" (PLACES_VERSION, wx-places.c:13).
    static let version: Int64 = 1
    /// Bytes of a caller's key examined (KEY_BUF_LEN, wx-places.c:17): a key
    /// must end within 24 bytes, i.e. be at most 23 bytes long.
    static let keyBufferLength = 24

    /// One saved place with its cached key (Entry, wx-places.c:20-24) and
    /// its own unit system; nil until set, meaning "the caller's default".
    /// The units live here, not in WxPlace, so they never affect a place's
    /// identity (== / hash / key).
    private struct Entry {
        let place: WxPlace
        let key: String
        var units: WxUnits?
    }

    /// The file `load` and `save` use.
    public let path: String
    /// Called once after every successful add/remove/move and after a load
    /// that emptied or filled the list (the "changed" signal), on the
    /// thread that made the change.
    public var onChanged: (() -> Void)?

    private var entries: [Entry] = []
    private var generation: UInt64 = 0 // bumped by every successful add/remove/move
    private var savedGeneration: UInt64 = 0
    /// True while `saveAsync` (or a job from `beginSave`) is running.
    private(set) var isSaveInFlight = false
    /// True after a load failed on a file that may exist (any failure but
    /// `isNotFound`) until a save has moved that file aside.
    private var keepsUnreadableFile = false

    /// A new empty list stored at `path`; nil if `path` is empty
    /// (wx_places_new, wx-places.c:211-221; C: critical + NULL).
    public init?(path: String) {
        guard !path.isEmpty else {
            return nil
        }
        self.path = path
    }

    /// The C default location relative to a configuration directory:
    /// "<directory>/weather/places.json" (wx-places.c:219). On macOS the app
    /// passes its container's Application Support directory.
    public static func defaultPath(configDirectory: String) -> String {
        (configDirectory as NSString).appendingPathComponent("weather/" + fileName)
    }

    // MARK: - Reading

    /// The number of places (at most `maxPlaces`).
    public var count: Int { entries.count }

    /// The places in list order.
    public var places: [WxPlace] { entries.map(\.place) }

    /// The place at `index`, or nil if out of range (wx_places_get_place).
    public func place(at index: Int) -> WxPlace? {
        guard index >= 0, index < entries.count else {
            return nil
        }
        return entries[index].place
    }

    /// The unit system saved for the place whose key is `key`; nil if there
    /// is no such place or it has none (the caller then applies its default).
    public func units(forKey key: String?) -> WxUnits? {
        guard let i = index(ofKey: key) else {
            return nil
        }
        return entries[i].units
    }

    /// The position of the place whose `WxPlace.key` equals `key`, or nil if
    /// there is none, `key` is nil or longer than 23 bytes
    /// (wx_places_index_of, wx-places.c:249-262). The key ends at its first
    /// U+0000, like a C string.
    public func index(ofKey key: String?) -> Int? {
        guard let bytes = Self.keyBytes(key) else {
            return nil
        }
        return entries.firstIndex { Array($0.key.utf8) == bytes }
    }

    /// The bytes of a C key argument: up to the first 0x00, nil if nil or if
    /// no 0x00/end falls within `keyBufferLength` bytes.
    static func keyBytes(_ key: String?) -> [UInt8]? {
        guard let key else {
            return nil
        }
        var bytes: [UInt8] = []
        for c in key.utf8 {
            if c == 0 {
                break
            }
            bytes.append(c)
            if bytes.count >= keyBufferLength {
                return nil
            }
        }
        return bytes
    }

    // MARK: - Rules

    /// True iff `a` and `b` lie closer than `duplicateKm` (great circle,
    /// WxGeo.distanceKm); the same key always qualifies (is_duplicate,
    /// wx-places.c:281-291). When either place is a user-specified address or
    /// custom-named location (`isCustomLocation`), multiple locations within the
    /// same city (< 5 km) are permitted as long as their coordinate keys differ.
    public static func isDuplicate(_ a: WxPlace, _ b: WxPlace) -> Bool {
        if a.isCustomLocation || b.isCustomLocation {
            return a.key == b.key
        }
        return WxGeo.distanceKm(aLat: a.lat, aLon: a.lon, bLat: b.lat, bLon: b.lon) < duplicateKm
    }

    /// True iff `add(place)` would succeed: the list holds fewer than
    /// `maxPlaces` places and none is a duplicate of `place`
    /// (append_place, wx-places.c:313-321).
    public func canAdd(_ place: WxPlace) -> Bool {
        entries.count < Self.maxPlaces && !entries.contains { Self.isDuplicate($0.place, place) }
    }

    // MARK: - Editing

    /// Appends without announcing; the single home of the cap and the
    /// duplicate rule (append_place, wx-places.c:313-321).
    private func append(_ place: WxPlace, units: WxUnits? = nil) -> Bool {
        guard canAdd(place) else {
            return false
        }
        entries.append(Entry(place: place, key: place.key, units: units))
        generation &+= 1
        return true
    }

    /// Appends `place` at the end (wx_places_add, wx-places.c:323-339).
    /// Returns false, with the list unchanged and nothing announced, if
    /// `place` is nil, the list is full, or a saved place lies closer than
    /// 5 km (this includes the same key). A WxPlace is always valid, so the C
    /// re-validation of wx_place_copy is the WxPlace initialiser's job.
    @discardableResult
    public func add(_ place: WxPlace?) -> Bool {
        guard let place, append(place) else {
            return false
        }
        onChanged?()
        return true
    }

    /// Removes the place with that key (wx_places_remove, wx-places.c:341-352).
    /// Returns false if no place has that key.
    @discardableResult
    public func remove(key: String?) -> Bool {
        guard let i = index(ofKey: key) else {
            return false
        }
        entries.remove(at: i)
        generation &+= 1
        onChanged?()
        return true
    }

    /// Moves the place at `from` so that it ends up at `to`; the places in
    /// between shift by one (wx_places_move, wx-places.c:354-375). Returns
    /// false (unchanged) if either index is out of range or `from == to`.
    @discardableResult
    public func move(from: Int, to: Int) -> Bool {
        let n = entries.count
        guard from >= 0, to >= 0, from < n, to < n, from != to else {
            return false
        }
        let moved = entries.remove(at: from)
        entries.insert(moved, at: to)
        generation &+= 1
        onChanged?()
        return true
    }

    /// Updates the saved place at `key` in-place (e.g. when renaming a location to "Home", "Work",
    /// "Friend's place", or updating its street address). Returns false if `key` is not found or
    /// the place is unchanged.
    @discardableResult
    public func updatePlace(key: String?, with updated: WxPlace) -> Bool {
        guard let i = index(ofKey: key) else {
            return false
        }
        if updated.key != entries[i].key && index(ofKey: updated.key) != nil {
            return false
        }
        guard entries[i].place != updated else {
            return false
        }
        entries[i] = Entry(place: updated, key: updated.key, units: entries[i].units)
        generation &+= 1
        onChanged?()
        return true
    }

    /// Sets the unit system of the place whose key is `key` (nil clears it).
    /// The place itself is unchanged; the list becomes dirty and the change
    /// is announced. Returns false (nothing announced) if no place has that
    /// key or its units are already `units`.
    @discardableResult
    public func setUnits(_ units: WxUnits?, forKey key: String?) -> Bool {
        guard let i = index(ofKey: key), entries[i].units != units else {
            return false
        }
        entries[i].units = units
        generation &+= 1
        onChanged?()
        return true
    }

    // MARK: - Persistence

    /// True iff add/remove/move/updatePlace/setUnits changed the list since
    /// the last load or the last successful save snapshot (wx_places_is_dirty).
    public var isDirty: Bool { generation != savedGeneration }

    /// Replaces the list with the content of `path` (wx_places_load,
    /// wx-places.c:432-460). Valid places are kept in file order; invalid
    /// elements, duplicates and elements beyond 50 are dropped and counted.
    /// Also removes stale "<path>.wx-tmp-XXXXXX" files. Blocking file I/O.
    ///
    /// Returns the number of dropped elements. While a save runs it throws
    /// `.pending` and changes nothing. Every other failure (`.file` - e.g. a
    /// missing file, `isNotFound` - or `.parse`) leaves the list EMPTY and
    /// clean and announces the change once if the list was non-empty; the
    /// file stays as it is, and unless it was missing the next save moves it
    /// aside (`FileIO.moveAside`) instead of overwriting it. On success the
    /// list is clean and the change is announced once if the list was or
    /// became non-empty.
    @discardableResult
    public func load() throws(WxStoreError) -> Int {
        if isSaveInFlight {
            throw StoreJSON.pendingError("places")
        }
        let hadPlaces = !entries.isEmpty
        entries.removeAll()
        var dropped = 0
        var failure: WxStoreError?
        do {
            let root = try StoreJSON.load(path: path, maxBytes: Self.maxFileBytes, what: "places")
            try fill(from: root, dropped: &dropped)
        } catch {
            failure = error
            entries.removeAll()
        }
        keepsUnreadableFile = failure.map { !$0.isNotFound } ?? false
        savedGeneration = generation
        if hadPlaces || !entries.isEmpty {
            onChanged?()
        }
        if let failure {
            throw failure
        }
        return dropped
    }

    /// Checks the envelope and the "places" array and appends every valid
    /// element (fill_from_json, wx-places.c:408-430).
    private func fill(from root: StoreJSON.Node?, dropped: inout Int) throws(WxStoreError) {
        let obj = try StoreJSON.rootObject(root, what: "places", version: Self.version)
        guard let arr = StoreJSON.nodeArray(obj.member("places")) else {
            throw .parse("places: missing places array")
        }
        for element in arr {
            if let place = StoreJSON.placeFromJSON(element),
               append(place, units: StoreJSON.placeUnits(element))
            {
                continue
            }
            dropped += 1
        }
    }

    /// The document for `places` (serialize_entries, wx-places.c:486-498);
    /// `units[i]`, if present and non-nil, is place i's "units" member.
    static func serialize(_ places: [WxPlace], units: [WxUnits?] = []) -> String {
        var out = "{\n  \"version\": \(version),\n  \"places\": ["
        for (i, place) in places.enumerated() {
            out += i > 0 ? ",\n    " : "\n    "
            StoreJSON.appendPlace(place, units: i < units.count ? units[i] : nil, to: &out)
        }
        out += places.isEmpty ? "]\n}\n" : "\n  ]\n}\n"
        return out
    }

    /// The list as places.json text, units included.
    private var document: String { Self.serialize(places, units: entries.map(\.units)) }

    /// Writes the list to `path` atomically (mode 0600, missing parents 0700)
    /// and marks it clean (wx_places_save, wx-places.c:508-525). Blocking:
    /// call it off the main thread or prefer `saveAsync`. Throws `.pending`
    /// while an asynchronous save runs, `.file` on an I/O failure (the list
    /// stays dirty and the old file survives). After a load that could not
    /// read the file, the file is first moved aside (see `load`).
    public func save() throws(WxStoreError) {
        if isSaveInFlight {
            throw StoreJSON.pendingError("places")
        }
        do {
            if keepsUnreadableFile {
                try FileIO.moveAside(path: path)
                keepsUnreadableFile = false
            }
            try FileIO.writeAtomic(path: path, data: Data(document.utf8))
        } catch {
            throw .file(error)
        }
        savedGeneration = generation
    }

    /// Saves a snapshot of the list on a background queue
    /// (wx_places_save_async/_finish, wx-places.c:640-680). The snapshot is
    /// taken before the first suspension; edits made meanwhile keep the list
    /// dirty. While it runs, `save`, `load` and another `saveAsync` throw
    /// `.pending`. Cancelling the calling task before the write starts throws
    /// `.cancelled` and writes nothing. Resumes on the caller's isolation.
    public func saveAsync(isolation: isolated (any Actor)? = #isolation) async throws(WxStoreError) {
        let job = try beginSave()
        let outcome = await job.perform()
        try finishSave(job, outcome)
    }

    /// The synchronous half of `saveAsync`: refuses with `.pending` if a save
    /// runs, else snapshots the list and marks the save in flight.
    func beginSave() throws(WxStoreError) -> StoreJSON.SaveJob {
        if isSaveInFlight {
            throw StoreJSON.pendingError("places")
        }
        isSaveInFlight = true
        return StoreJSON.SaveJob(
            path: path, data: Data(document.utf8), generation: generation,
            keepsExistingFile: keepsUnreadableFile)
    }

    /// The completion half of `saveAsync` (save_done, wx-places.c:619-638):
    /// clears the in-flight flag; on success the list is clean as of the
    /// snapshot generation.
    func finishSave(_ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError) {
        isSaveInFlight = false
        switch outcome {
        case .success:
            savedGeneration = job.generation
            keepsUnreadableFile = false
        case .failure(let error):
            throw error
        }
    }
}
