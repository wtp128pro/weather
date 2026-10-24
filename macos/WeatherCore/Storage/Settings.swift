// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Settings.swift - the user's preferences and settings.json; a port of
// src/storage/wx-settings.{h,c}.

import Foundation

/// The persisted preferences (WxSettings): units, the disabled providers and
/// the selected place key.
///
/// Not Sendable: one isolation domain owns the object (typically the main
/// actor); `saveAsync` writes on a background queue and resumes on the
/// caller's isolation. Providers are enabled unless listed, so a new
/// provider is enabled automatically.
///
/// File format (wx-settings.c:427-446):
/// `{\n  "version": 1,\n  "units": "imperial",\n  "disabled_providers": ["a", "b"],\n  "selected": "<key>"\n}\n`,
/// where the "selected" line is omitted when nothing is selected.
public final class WxSettings {
    /// Largest settings.json that `load` reads (WX_SETTINGS_MAX_FILE_BYTES, wx-settings.h:44).
    public static let maxFileBytes = 64 * 1024
    /// The most disabled provider ids kept (WX_SETTINGS_MAX_DISABLED, wx-settings.h:46).
    public static let maxDisabledProviders = 16
    /// The file name under the "weather" configuration folder.
    public static let fileName = "settings.json"

    /// The only supported "version" (SETTINGS_VERSION, wx-settings.c:13).
    static let version: Int64 = 1

    /// The persisted values (Values, wx-settings.c:20-25); the defaults are
    /// imperial, nothing disabled, nothing selected (values_init).
    private struct Values {
        var units: WxUnits = .imperial
        var disabled: [String] = [] // valid provider ids, no repeats, in insertion order
        var selected: String? // a valid place key
    }

    /// The file `load` and `save` use.
    public let path: String
    /// Called once after every successful setter and after every load that
    /// did not fail with `.pending` (the "changed" signal), on the thread
    /// that made the change.
    public var onChanged: (() -> Void)?

    private var v = Values()
    private var generation: UInt64 = 0 // bumped by every successful setter
    private var savedGeneration: UInt64 = 0
    /// True while `saveAsync` (or a job from `beginSave`) is running.
    private(set) var isSaveInFlight = false

    /// New default settings stored at `path`; nil if `path` is empty
    /// (wx_settings_new, wx-settings.c:240-250; C: critical + NULL).
    public init?(path: String) {
        guard !path.isEmpty else {
            return nil
        }
        self.path = path
    }

    /// The C default location relative to a configuration directory:
    /// "<directory>/weather/settings.json" (wx-settings.c:248).
    public static func defaultPath(configDirectory: String) -> String {
        (configDirectory as NSString).appendingPathComponent("weather/" + fileName)
    }

    // MARK: - Units

    /// The display units (default imperial).
    public var units: WxUnits { v.units }

    /// Sets the units; false (nothing announced) if unchanged
    /// (wx_settings_set_units, wx-settings.c:268-280).
    @discardableResult
    public func setUnits(_ units: WxUnits) -> Bool {
        guard units != v.units else {
            return false
        }
        v.units = units
        changed()
        return true
    }

    // MARK: - Providers

    /// The disabled provider ids in the order they were disabled.
    public var disabledProviders: [String] { v.disabled }

    /// True iff `id` is a valid provider id that is disabled
    /// (wx_settings_is_provider_disabled, wx-settings.c:282-288).
    public func isProviderDisabled(_ id: String?) -> Bool {
        guard let id = Self.cString(id), WxLimits.isValidID(id) else {
            return false
        }
        return v.disabled.contains { Array($0.utf8) == Array(id.utf8) }
    }

    /// Disables or re-enables provider `id` (wx_settings_set_provider_disabled,
    /// wx-settings.c:290-310). False, nothing announced, if `id` is not a
    /// valid provider id, already in that state, or 16 ids are disabled.
    @discardableResult
    public func setProviderDisabled(_ id: String?, _ disabled: Bool) -> Bool {
        guard let id = Self.cString(id), WxLimits.isValidID(id) else {
            return false
        }
        let i = v.disabled.firstIndex { Array($0.utf8) == Array(id.utf8) }
        if disabled {
            guard i == nil, v.disabled.count < Self.maxDisabledProviders else {
                return false
            }
            v.disabled.append(id)
        } else {
            guard let i else {
                return false
            }
            v.disabled.remove(at: i)
        }
        changed()
        return true
    }

    // MARK: - Selection

    /// The key (`WxPlace.key`) of the selected place, or nil.
    public var selected: String? { v.selected }

    /// Selects a place by key, or clears the selection with nil
    /// (wx_settings_set_selected, wx-settings.c:320-334). False, nothing
    /// announced, if `key` is not a valid key or equals the current one.
    @discardableResult
    public func setSelected(_ key: String?) -> Bool {
        let key = Self.cString(key)
        if let key, !Self.isValidKey(key) {
            return false
        }
        guard key.map({ Array($0.utf8) }) != v.selected.map({ Array($0.utf8) }) else {
            return false
        }
        v.selected = key
        changed()
        return true
    }

    /// The place-key grammar of `selected` (key_is_valid, wx-settings.c:146-176):
    /// at most 23 bytes of `-?D{1,3}.DDDD,-?D{1,3}.DDDD` (ASCII digits) whose
    /// two numbers are a valid latitude and longitude. The key ends at its
    /// first U+0000, like a C string.
    public static func isValidKey(_ key: String?) -> Bool {
        guard let b = WxPlaces.keyBytes(key) else {
            return false
        }
        func at(_ p: Int) -> UInt8 { p < b.count ? b[p] : 0 }
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        var p = 0
        var coord: [Double] = [0, 0]
        for part in 0 ..< 2 {
            let start = p
            if at(p) == UInt8(ascii: "-") {
                p += 1
            }
            var digits = 0
            while isDigit(at(p)) {
                p += 1
                digits += 1
            }
            if digits < 1 || digits > 3 || at(p) != UInt8(ascii: ".") {
                return false
            }
            p += 1
            for _ in 0 ..< 4 {
                if !isDigit(at(p)) {
                    return false
                }
                p += 1
            }
            // g_ascii_strtod of "-ddd.dddd": always a well-formed decimal here.
            guard let value = Double(String(decoding: b[start ..< p], as: UTF8.self)) else {
                return false
            }
            coord[part] = value
            if part == 0 {
                if at(p) != UInt8(ascii: ",") {
                    return false
                }
                p += 1
            }
        }
        return at(p) == 0 && WxGeo.isValid(lat: coord[0], lon: coord[1])
    }

    /// `s` up to its first U+0000 (what a C function sees of the argument).
    private static func cString(_ s: String?) -> String? {
        guard let s else {
            return nil
        }
        guard let nul = s.utf8.firstIndex(of: 0) else {
            return s
        }
        return String(decoding: s.utf8[..<nul], as: UTF8.self)
    }

    private func changed() {
        generation &+= 1
        onChanged?()
    }

    // MARK: - Persistence

    /// True iff a setter changed a value since the last load or the last
    /// successful save snapshot (wx_settings_is_dirty).
    public var isDirty: Bool { generation != savedGeneration }

    /// Replaces the values with the content of `path` (wx_settings_load,
    /// wx-settings.c:376-405). Unknown members are ignored; "units" is metric
    /// only for exactly "metric"; invalid, repeated or surplus (beyond 16)
    /// provider ids are skipped; an invalid "selected" is ignored. Also
    /// removes stale "<path>.wx-tmp-XXXXXX" files. Blocking file I/O.
    ///
    /// While a save runs it throws `.pending` and changes nothing. Every
    /// other outcome - success or failure (`.file`, e.g. `isNotFound`, or
    /// `.parse`) - leaves the object clean, with the DEFAULTS after a failure,
    /// and announces the change once, even when nothing changed.
    public func load() throws(WxStoreError) {
        if isSaveInFlight {
            throw StoreJSON.pendingError("settings")
        }
        var loaded = Values()
        var failure: WxStoreError?
        do {
            let root = try StoreJSON.load(path: path, maxBytes: Self.maxFileBytes, what: "settings")
            let obj = try StoreJSON.rootObject(root, what: "settings", version: Self.version)
            Self.read(obj, into: &loaded)
        } catch {
            failure = error
        }
        v = loaded
        savedGeneration = generation
        onChanged?()
        if let failure {
            throw failure
        }
    }

    /// values_from_json (wx-settings.c:355-374).
    private static func read(_ obj: StoreJSON.Object, into v: inout Values) {
        if let units = StoreJSON.nodeString(obj.member("units")), units == Array("metric".utf8) {
            v.units = .metric
        }
        for element in StoreJSON.nodeArray(obj.member("disabled_providers")) ?? [] {
            guard let id = StoreJSON.nodeString(element), WxLimits.isValidID(bytes: id) else {
                continue
            }
            if !v.disabled.contains(where: { Array($0.utf8) == id }) && v.disabled.count < maxDisabledProviders {
                v.disabled.append(String(decoding: id, as: UTF8.self))
            }
        }
        if let selected = StoreJSON.nodeString(obj.member("selected")) {
            let key = String(decoding: selected, as: UTF8.self)
            if isValidKey(key) {
                v.selected = key
            }
        }
    }

    /// The document for `v` (serialize_values, wx-settings.c:427-446).
    private static func serialize(_ v: Values) -> String {
        var out = "{\n  \"version\": \(version),\n  \"units\": "
        StrictJSON.appendString(v.units == .metric ? "metric" : "imperial", to: &out)
        out += ",\n  \"disabled_providers\": ["
        for (i, id) in v.disabled.enumerated() {
            out += i > 0 ? ", " : ""
            StrictJSON.appendString(id, to: &out)
        }
        out += "]"
        if let selected = v.selected {
            out += ",\n  \"selected\": "
            StrictJSON.appendString(selected, to: &out)
        }
        out += "\n}\n"
        return out
    }

    /// Writes the settings to `path` atomically (mode 0600, missing parents
    /// 0700) and marks them clean (wx_settings_save, wx-settings.c:456-473).
    /// Blocking. Throws `.pending` while an asynchronous save runs, `.file`
    /// on an I/O failure (the object stays dirty, the old file survives).
    public func save() throws(WxStoreError) {
        if isSaveInFlight {
            throw StoreJSON.pendingError("settings")
        }
        do {
            try FileIO.writeAtomic(path: path, data: Data(Self.serialize(v).utf8))
        } catch {
            throw .file(error)
        }
        savedGeneration = generation
    }

    /// Saves a snapshot on a background queue (wx_settings_save_async/_finish,
    /// wx-settings.c:588-630); same contract as `WxPlaces.saveAsync`.
    public func saveAsync(isolation: isolated (any Actor)? = #isolation) async throws(WxStoreError) {
        let job = try beginSave()
        let outcome = await job.perform()
        try finishSave(job, outcome)
    }

    /// The synchronous half of `saveAsync`: refuses with `.pending` if a save
    /// runs, else snapshots the values and marks the save in flight.
    func beginSave() throws(WxStoreError) -> StoreJSON.SaveJob {
        if isSaveInFlight {
            throw StoreJSON.pendingError("settings")
        }
        isSaveInFlight = true
        return StoreJSON.SaveJob(path: path, data: Data(Self.serialize(v).utf8), generation: generation)
    }

    /// The completion half of `saveAsync` (save_done, wx-settings.c:567-586).
    func finishSave(_ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError) {
        isSaveInFlight = false
        switch outcome {
        case .success:
            savedGeneration = job.generation
        case .failure(let error):
            throw error
        }
    }
}
