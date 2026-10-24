// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AppModelTests.swift - the app-level places, persistence and lifecycle cases
// of src/ui/test-window.c, ported to AppModel (U27).
//
// Fixture mapping (test-window.c:534-683): fx_new -> Fx (two FakeProviders
// "fake-a"/"fake-b" covering every place, a FakeGeocoder, optionally the
// "gate" provider that answers only when released); fx_start -> a new AppModel
// over the fixture's registry, load(), then setVisible(true) (the window is
// mapped); fx_stop -> flush() and the model is released; warp_clocks(s) ->
// ManualClock.advance(by: s s); WXT_WAIT_FOR -> waitFor (bounded real-time
// polling). Expected values are the C literals cited as test-window.c:LINE.

import Foundation
import Observation
import Synchronization
import Testing
@testable import WeatherCore

// MARK: - Fixture

/// The C "gate" provider (test-window.c:387-528): covers every place and answers a
/// fetch only when the test releases it; a cancelled fetch throws CancellationError.
private final class GateProvider: WxProvider {
    private struct State {
        var fetches = 0
        var cancelled = 0
        var next: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var cancelledEarly: Set<UInt64> = []
    }

    let id = "gate"
    var name: String { "Gate" }
    var attribution: String { "Gate data" }
    var attributionURL: String { "https://example.invalid/" }
    private let member: WxMember
    private let state = Mutex(State())

    init(member: WxMember) {
        self.member = member
    }

    /// Number of fetches that reached the gate.
    var fetches: Int { state.withLock { $0.fetches } }
    /// Number of those that were cancelled while held.
    var cancelled: Int { state.withLock { $0.cancelled } }
    /// Number of fetches held now.
    var held: Int { state.withLock { $0.waiters.count } }

    func covers(_ place: WxPlace) -> Bool { true }

    func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        let token = state.withLock { s -> UInt64 in
            s.fetches += 1
            s.next += 1
            return s.next
        }
        let released = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.cancelledEarly.remove(token) != nil {
                        return true
                    }
                    s.waiters[token] = continuation
                    return false
                }
                if now {
                    continuation.resume(returning: false)
                }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                s.cancelled += 1
                if let w = s.waiters.removeValue(forKey: token) {
                    return w
                }
                s.cancelledEarly.insert(token)
                return nil
            }
            waiter?.resume(returning: false)
        }
        guard released else {
            throw CancellationError()
        }
        var result = try WxSourceResult(providerID: id)
        result.members = [member]
        return result
    }

    /// gate_release(gate, -1): every held fetch answers with the member.
    func release() {
        let waiters = state.withLock { s -> [CheckedContinuation<Bool, Never>] in
            let w = Array(s.waiters.values)
            s.waiters = [:]
            return w
        }
        for w in waiters {
            w.resume(returning: true)
        }
    }
}

/// Holds a test hook until released (saves, scripted refreshes).
@MainActor
private final class Hold {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if open {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let w = waiters
        waiters = []
        for c in w {
            c.resume()
        }
    }
}

@MainActor
private final class LogBox {
    var lines: [(AppModel.LogLevel, String)] = []
    var warnings: [String] { lines.filter { $0.0 == .warning }.map(\.1) }
}

/// The outcome of a flush started from a task the test does not await directly.
@MainActor
private final class FlushBox {
    var started = false
    var ok: Bool?
}

/// A notification counter shared with @Sendable onChange closures.
private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func bump() { value.withLock { $0 += 1 } }
}

/// fx_new / fx_start / fx_stop (test-window.c:580-683).
@MainActor
private final class Fx {
    let dir: TemporaryDirectory
    let storage: AppEnvironment.StorageRoot
    let clock = ManualClock()
    let registry = WxRegistry()
    let a: FakeProvider
    let b: FakeProvider
    let geocoder = FakeGeocoder()
    private(set) var gate: GateProvider?
    var model: AppModel?
    let logs = LogBox()

    init(_ label: String, delayMs: UInt32 = 0, gated: Bool = false, providerClock: (any WxClock)? = nil) throws {
        dir = try TemporaryDirectory("appmodel-\(label)")
        storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                             cacheDirectory: dir.appending("cache").path)
        a = FakeProvider(id: "fake-a", clock: providerClock ?? SystemClock())  // test-window.c:586
        b = FakeProvider(id: "fake-b", clock: providerClock ?? SystemClock())  // test-window.c:587
        a.addMember(try Self.member("fake-a", clock))
        b.addMember(try Self.member("fake-b", clock))
        a.setDelayMs(delayMs)
        b.setDelayMs(delayMs)
        try registry.addProvider(a)
        try registry.addProvider(b)
        registry.geocoder = geocoder
        if gated {
            try addGate()
        }
    }

    /// fx_add_gate (test-window.c:553-562).
    func addGate() throws {
        let g = GateProvider(member: try Self.member("gate", clock))
        try registry.addProvider(g)
        gate = g
    }

    /// make_member (test-window.c:213-255) on the fixture clock: hourly data from 2 h ago to
    /// 72 h ahead, 24 degC, 26 feels, 70 % humidity, 40 % cloud, wind 12, gust 20, dry 5 %.
    static func member(_ source: String, _ clock: ManualClock) throws -> WxMember {
        let now = clock.wallSeconds
        let base = now - now % 3600
        var m = try WxMember(sourceID: source, modelID: "m1", fetchedS: now)
        for i in -2 ..< 72 {  // test-window.c:221
            let h = WxHour(tS: base + Int64(i) * 3600, tempC: 24, feelsC: 26, precipMm: 0, precipProb: 5,
                           cloudPct: 40, windKmh: 12, gustKmh: 20, humidityPct: 70)  // test-window.c:225-232
            let added = m.addHour(h)
            #expect(added)
        }
        return m
    }

    /// fx_start: the model over the fixture's registry, loaded, the window visible.
    @discardableResult
    func start(visible: Bool = true) async -> AppModel {
        let logs = self.logs
        let m = AppModel(registry: registry, storage: storage, clock: clock, online: true,
                         log: { level, message in logs.lines.append((level, message)) })
        model = m
        await m.load()
        if visible {
            m.setVisible(true)
        }
        return m
    }

    /// fx_stop (test-window.c:648-661): flush (the shutdown) and release the model; returns the
    /// flush result and how long it took in milliseconds on the fixture clock - the clock the
    /// model's 5 s limit runs on, as C measures g_get_monotonic_time() for its own limit
    /// (test-window.c:651-653, wx-app.c:2047).
    @discardableResult
    func stop() async -> (ok: Bool, ms: Int64) {
        guard let m = model else {
            return (true, 0)
        }
        let t0 = clock.monotonicMicroseconds
        let ok = await m.flush()
        let elapsedUs = clock.monotonicMicroseconds - t0
        model = nil
        return (ok, elapsedUs / 1000)
    }

    /// fx_restart.
    @discardableResult
    func restart() async -> AppModel {
        await stop()
        return await start()
    }

    /// store_places (test-window.c:290-301).
    func storePlaces(_ places: [WxPlace]) throws {
        let list = try #require(WxPlaces(path: storage.placesPath))
        for p in places {
            #expect(list.add(p))
        }
        try list.save()
    }

    /// store_settings (test-window.c:303-315).
    func storeSettings(_ units: WxUnits, disabled: String? = nil, selected: String? = nil) throws {
        let s = try #require(WxSettings(path: storage.settingsPath))
        if units != .imperial {
            #expect(s.setUnits(units))
        }
        if let disabled {
            #expect(s.setProviderDisabled(disabled, true))
        }
        if let selected {
            #expect(s.setSelected(selected))
        }
        try s.save()
    }

    func loadPlaces() throws -> WxPlaces {
        let list = try #require(WxPlaces(path: storage.placesPath))
        try list.load()
        return list
    }

    func loadSettings() throws -> WxSettings {
        let s = try #require(WxSettings(path: storage.settingsPath))
        try s.load()
        return s
    }

    func loadCache() throws -> WxForecastCache {
        let c = try #require(WxForecastCache(path: storage.cachePath, clock: clock))
        try c.load()
        return c
    }

    func names() -> String {
        (model?.places ?? []).map(\.place.name).joined(separator: ",")
    }
}

/// place_new / miami / orlando / tampa (test-window.c:164-189).
private func place(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, admin1: "Florida", country: "United States", countryCode: "US", lat: lat, lon: lon,
                timezone: "America/New_York")  // test-window.c:168
}

private func miami() throws -> WxPlace { try place("Miami", 25.7743, -80.1937) }  // test-window.c:176
private func orlando() throws -> WxPlace { try place("Orlando", 28.5383, -81.3792) }  // test-window.c:182
private func tampa() throws -> WxPlace { try place("Tampa", 27.9475, -82.4584) }  // test-window.c:188

/// WXT_WAIT_FOR: polls `condition` (real time, bounded) while the main actor runs other work.
@MainActor
private func waitFor(_ timeoutMs: Int = 15_000, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while !condition() {
        if ContinuousClock.now > deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// WXT_WAIT_FOR for long runs: polls `condition` while `progress()` keeps changing; gives up only
/// after `stallMs` real milliseconds without progress (a loaded host slows it down, never fails it).
@MainActor
private func waitWhileProgressing(_ progress: () -> Int, stallMs: Int = 20_000, _ condition: () -> Bool) async -> Bool {
    var last = progress()
    var lastChange = ContinuousClock.now
    while !condition() {
        let now = progress()
        if now != last {
            last = now
            lastChange = ContinuousClock.now
        } else if ContinuousClock.now - lastChange > .milliseconds(stallMs) {
            return false
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// wxt_pump_ms: lets the main actor run other work for `ms` real milliseconds.
@MainActor
private func pump(_ ms: Int) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

private func fileText(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else {
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}

/// flush_saves (test-window.c:3547): advances past the debounce until every file holds its mark.
@MainActor
private func flushSaves(_ fx: Fx, _ marks: [(String, String)]) async -> Bool {
    for _ in 0 ..< 20 {
        await fx.clock.advance(by: (AppModel.saveDelayMs / 1000 + 1) * 1_000_000)
        let done = await waitFor(2_000) {
            fx.model?.savesInFlight == 0 && marks.allSatisfy { fileText($0.0)?.contains($0.1) == true }
        }
        if done && fx.model?.saveTimerArmed == false {
            return true
        }
    }
    return false
}

// MARK: - Suite

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AppModelTests {
    // MARK: Start-up and files

    // C: /window/app/api-before-load-ignored (test_api_before_the_load_has_finished_is_ignored,
    // test-window.c:2885-2903)
    @Test func apiBeforeLoadIgnored() async throws {
        let fx = try Fx("before-load")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.metric)
        let logs = fx.logs
        let m = AppModel(registry: fx.registry, storage: fx.storage, clock: fx.clock, online: true,
                         log: { level, message in logs.lines.append((level, message)) })
        fx.model = m
        m.setUnits(.metric)  // test-window.c:2893
        m.select("25.7743,-80.1937")  // test-window.c:2894
        m.setProviderEnabled("fake-a", false)  // test-window.c:2895
        m.refresh()  // test-window.c:2896
        #expect(m.add(try orlando()) == .failed)
        #expect(m.selectedKey == nil)  // test-window.c:2897
        #expect(fx.registry.isEnabled(id: "fake-a"))  // test-window.c:2898
        #expect(m.units == .imperial)
        #expect(m.places.isEmpty)
        #expect(m.requestsStarted == 0)
        await m.load()
        #expect(m.units == .metric)  // test-window.c:2901 (from the file)
        #expect(fx.registry.isEnabled(id: "fake-a"))
        #expect(fx.a.fetchCount == 0)
        await fx.stop()
    }

    // C: /window/refresh/cached-at-once (test_cached_forecast_is_shown_at_once,
    // test-window.c:1502-1520; prime_cache test-window.c:1480-1499)
    @Test func cachedForecastIsShownAtOnce() async throws {
        let fx = try Fx("cached")
        try fx.storePlaces([try miami()])
        // prime_cache(fx, 3 * 3600) (test-window.c:1507): one run fills the cache ...
        let first = await fx.start()
        #expect(await waitFor { first.places.first?.forecast != nil && first.places.first?.loading == false })
        await fx.stop()
        // ... and the entry is aged by 3 h.
        let ageS: Int64 = 3 * 3600
        let cache = try fx.loadCache()
        #expect(cache.count == 1)
        let key = try miami().key
        let hit = try #require(cache.get(key: key))
        #expect(cache.put(hit.forecast, fetchedAtMs: (fx.clock.wallSeconds - ageS) * 1000))
        try cache.save()
        // Now a refresh stays in flight (the gate): whatever is shown comes from the cache.
        try fx.addGate()
        let gate = try #require(fx.gate)
        let m = await fx.start(visible: false)
        let item = try #require(m.places.first)
        #expect(item.forecast != nil)  // test-window.c:1512, before the window is shown
        #expect(item.fetchedS == fx.clock.wallSeconds - ageS)  // "Updated 3 h ago", test-window.c:1514
        #expect(item.units == .imperial)  // the degF suffix, test-window.c:1516
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.loading == true })  // test-window.c:1513
        #expect(m.places.first?.forecast != nil)
        #expect(await waitFor { gate.held == 1 })
        await fx.stop()
    }

    // C: /window/files/corrupt-files (test_corrupt_files_start_empty_with_one_warning_each,
    // test-window.c:2932-2960)
    @Test func corruptFilesStartEmptyWithOneWarningEach() async throws {
        let fx = try Fx("corrupt")
        let fm = FileManager.default
        for path in [fx.storage.placesPath, fx.storage.cachePath] {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        #expect(fm.createFile(atPath: fx.storage.placesPath, contents: Data("{not json".utf8)))  // test-window.c:2943
        #expect(fm.createFile(atPath: fx.storage.settingsPath, contents: Data("[1,2,3]\n".utf8)))  // test-window.c:2944
        #expect(fm.createFile(atPath: fx.storage.cachePath, contents: Data([0x01, 0x02, 0x03])))  // test-window.c:2945
        let m = await fx.start()
        let warnings = fx.logs.warnings
        #expect(warnings.count == 3, "\(warnings)")
        #expect(warnings.count == 3
                && warnings[0].hasPrefix("Could not read the saved places (starting empty): ")  // test-window.c:2946
                && warnings[1].hasPrefix("Could not read the settings (using defaults): ")  // test-window.c:2947
                && warnings[2].hasPrefix("Could not read the forecast cache (starting empty): "),  // test-window.c:2948
                "\(warnings)")
        #expect(m.places.isEmpty)  // test-window.c:2951
        #expect(m.units == .imperial)  // test-window.c:2954
        // The app is usable: a place can be added.
        #expect(m.add(try miami()) == .added)
        #expect(await waitFor { m.places.first?.forecast != nil })  // test-window.c:2958
        await fx.stop()
    }

    // C: /window/files/invalid-places-dropped (test_some_invalid_places_are_dropped_with_one_warning,
    // test-window.c:2963-2981)
    @Test func someInvalidPlacesAreDroppedWithOneWarning() async throws {
        let fx = try Fx("dropped")
        try FileManager.default.createDirectory(
            atPath: (fx.storage.placesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let text = "{\"version\":1,\"places\":[{\"name\":\"Miami\",\"admin1\":\"Florida\",\"country\":\"United States\","
            + "\"country_code\":\"US\",\"lat\":25.7743,\"lon\":-80.1937,\"timezone\":\"America/New_York\"},"
            + "{\"name\":\"\",\"lat\":1,\"lon\":2},{\"name\":\"Far\",\"lat\":999,\"lon\":0}]}"  // test-window.c:2972-2974
        #expect(FileManager.default.createFile(atPath: fx.storage.placesPath, contents: Data(text.utf8)))
        let m = await fx.start()
        #expect(fx.logs.warnings == ["2 invalid saved places were dropped"])  // test-window.c:2976
        #expect(m.places.count == 1)  // test-window.c:2979
        await fx.stop()
    }

    // C: /window/app/shutdown-while-loading (test_shutdown_while_loading, test-window.c:3404-3420)
    @Test func shutdownWhileLoading() async throws {
        let fx = try Fx("shutdown-loading")
        try fx.storePlaces([try miami()])
        let m = AppModel(registry: fx.registry, storage: fx.storage, clock: fx.clock, online: true)
        fx.model = m
        let loader = Task.immediate { @MainActor in await m.load() }  // the load is running on its worker
        m.setVisible(true)
        let t0 = fx.clock.monotonicMicroseconds  // the clock of the model's limit, test-window.c:3412
        let ok = await m.flush()
        let elapsedUs = fx.clock.monotonicMicroseconds - t0
        await loader.value
        #expect(ok)
        #expect(elapsedUs < AppModel.shutdownWaitMs * 1000)  // test-window.c:3414
        #expect(m.places.isEmpty)  // test-window.c:3415
        #expect(!m.isLoaded)
        #expect(fx.a.fetchCount == 0)  // test-window.c:3417
        #expect(m.requestsStarted == 0)
        fx.model = nil
    }

    // MARK: Units

    // C: /window/units/toggle-and-persistence (test_units_toggle_and_persistence, test-window.c:2242-2284)
    @Test func unitsToggleAndPersistence() async throws {
        let fx = try Fx("units-toggle")
        try fx.storePlaces([try miami()])
        var m = await fx.start()
        #expect(m.units == .imperial)  // "°F", test-window.c:2249
        #expect(await waitFor { m.places.first?.forecast != nil })
        m.toggleUnits()  // click(button), test-window.c:2257
        #expect(m.units == .metric)  // test-window.c:2258
        #expect(m.places.first?.units == .metric)  // test-window.c:2264
        // The choice survives a restart (saved at shutdown at the latest).
        m = await fx.restart()
        #expect(m.units == .metric)  // test-window.c:2269
        #expect(m.places.first?.units == .metric)  // test-window.c:2272
        // And back, through the action (Ctrl+U).
        m.toggleUnits()  // test-window.c:2274
        #expect(m.units == .imperial)  // test-window.c:2275
        await fx.stop()
        #expect(try fx.loadSettings().units == .imperial)  // test-window.c:2282
    }

    // C: /window/units/from-settings (test_units_from_settings_at_start, test-window.c:2287-2302)
    @Test func unitsFromSettingsAtStart() async throws {
        let fx = try Fx("units-settings")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.metric)
        let m = await fx.start()
        #expect(m.units == .metric)  // test-window.c:2294
        #expect(m.places.first?.units == .metric)  // test-window.c:2297
        // Setting the current unit again changes nothing.
        m.setUnits(.metric)  // test-window.c:2299
        #expect(m.units == .metric)  // test-window.c:2300
        await fx.stop()
    }

    // C: /window/app/properties (test_app_properties, test-window.c:3340-3368): "offline" and
    // "units" notify only on a change.
    @Test func appPropertiesNotifyOnlyOnChange() async throws {
        let fx = try Fx("properties")
        let m = await fx.start()
        #expect(!m.isOffline)  // test-window.c:3348
        #expect(m.units == .imperial)  // test-window.c:3349
        let notified = Counter()
        func track() {
            withObservationTracking {
                _ = m.isOffline
                _ = m.units
            } onChange: {
                notified.bump()
            }
        }
        track()
        m.setOnline(true)  // no change: no notification
        #expect(notified.count == 0)  // test-window.c:3354
        m.setOnline(false)
        #expect(notified.count == 1)  // test-window.c:3356
        #expect(m.isOffline)  // test-window.c:3358
        track()
        m.setOnline(false)
        #expect(notified.count == 1)  // test-window.c:3360
        m.setOnline(true)
        #expect(notified.count == 2)  // test-window.c:3362
        track()
        m.setUnits(.metric)
        #expect(notified.count == 3)  // test-window.c:3364
        #expect(m.units == .metric)  // test-window.c:3366
        await fx.stop()
    }

    // MARK: Selection, removal, order

    // C: /window/places/selection-default-and-persist (test_selection_defaults_and_persists,
    // test-window.c:2315-2337)
    @Test func selectionDefaultsAndPersists() async throws {
        let fx = try Fx("selection")
        try fx.storePlaces([try miami(), try orlando(), try tampa()])
        var m = await fx.start()
        #expect(m.selectedKey == (try miami().key))  // the first row, test-window.c:2325
        #expect(m.selectedPlace?.place.label == "Miami, Florida, United States")  // test-window.c:2326
        m.select(try tampa().key)  // list.select-item 2, test-window.c:2330
        #expect(m.selectedKey == (try tampa().key))  // test-window.c:2331
        m = await fx.restart()
        #expect(m.selectedKey == (try tampa().key))  // test-window.c:2334
        #expect(m.selectedPlace?.place.label == "Tampa, Florida, United States")  // test-window.c:2335
        await fx.stop()
    }

    // C: /window/places/selection-of-vanished-place (test_selection_of_a_vanished_place_is_ignored,
    // test-window.c:2340-2358)
    @Test func selectionOfAVanishedPlaceIsIgnored() async throws {
        let fx = try Fx("vanished")
        try fx.storePlaces([try miami(), try orlando()])
        try fx.storeSettings(.imperial, selected: "10.0000,10.0000")  // test-window.c:2345
        let m = await fx.start()
        #expect(m.selectedKey == (try miami().key))  // test-window.c:2349
        m.select("99.0000,99.0000")  // test-window.c:2351
        #expect(m.selectedKey == nil)  // test-window.c:2352
        m.select("not a key")  // test-window.c:2353
        #expect(m.selectedKey == nil)  // test-window.c:2354
        m.select(nil)  // test-window.c:2355
        #expect(m.selectedKey == nil)  // test-window.c:2356
        await fx.stop()
    }

    // C: /window/places/remove-selects-neighbour (test_remove_place_selects_a_neighbour,
    // test-window.c:2361-2407)
    @Test func removePlaceSelectsANeighbour() async throws {
        let fx = try Fx("remove")
        try fx.storePlaces([try miami(), try orlando(), try tampa()])
        let m = await fx.start()
        let okey = try orlando().key
        m.select(okey)  // test-window.c:2370
        #expect(m.selectedKey == okey)  // test-window.c:2372
        #expect(await waitFor { m.place(forKey: okey)?.forecast != nil })  // test-window.c:2374
        // Remove it through the row's menu action.
        #expect(m.remove(key: okey))  // test-window.c:2376
        #expect(m.places.count == 2)  // test-window.c:2377 (list) and 2379 (items)
        #expect(!m.isSaved(key: okey))  // test-window.c:2378
        #expect(m.selectedKey != nil)  // test-window.c:2380
        #expect(m.selectedKey != okey)  // test-window.c:2381
        // Pinned (GtkSingleSelection autoselect): the row now at the removed row's position.
        #expect(m.selectedKey == (try tampa().key))
        // Removing the others leaves the empty state.
        #expect(m.remove(key: try miami().key))  // test-window.c:2384
        #expect(m.remove(key: try tampa().key))  // test-window.c:2386
        #expect(m.places.isEmpty)  // "empty", test-window.c:2387-2388
        #expect(m.selectedKey == nil)  // test-window.c:2389
        #expect(!m.isRefreshEnabled)  // test-window.c:2390
        // The files follow at shutdown: no place, no selection, no cached forecast left.
        await fx.stop()
        #expect(try fx.loadPlaces().count == 0)  // test-window.c:2397
        #expect(try fx.loadCache().count == 0)  // test-window.c:2401
        #expect(try fx.loadSettings().selected == nil)  // test-window.c:2405
    }

    // C: /window/places/move-up-down (test_move_up_and_down, test-window.c:2428-2453)
    @Test func moveUpAndDown() async throws {
        let fx = try Fx("move")
        try fx.storePlaces([try miami(), try orlando(), try tampa()])
        var m = await fx.start()
        #expect(m.moveUp(key: try tampa().key))  // row.move-up, test-window.c:2435
        #expect(fx.names() == "Miami,Tampa,Orlando")  // test-window.c:2437, 2439
        #expect(m.moveDown(key: try miami().key))  // test-window.c:2440
        #expect(fx.names() == "Tampa,Miami,Orlando")  // test-window.c:2442
        // Moving past either end does nothing (C: the actions run, test-window.c:2444-2445, and the
        // order stays, :2447). The false return values are Swift-only (executor-added).
        #expect(!m.moveUp(key: try tampa().key))
        #expect(!m.moveDown(key: try orlando().key))
        #expect(fx.names() == "Tampa,Miami,Orlando")  // test-window.c:2447
        // The order is stored (at shutdown at the latest) and restored.
        m = await fx.restart()
        #expect(fx.names() == "Tampa,Miami,Orlando")  // test-window.c:2451
        await fx.stop()
    }

    // C: /window/places/reorder-by-drop (test_reorder_by_drop_and_hostile_payloads,
    // test-window.c:2456-2490)
    @Test func reorderByDropAndHostilePayloads() async throws {
        let fx = try Fx("drop")
        try fx.storePlaces([try miami(), try orlando(), try tampa()])
        let m = await fx.start()
        let mkey = try miami().key
        let tkey = try tampa().key
        // Hostile payloads (they may come from another application) change nothing and log nothing.
        // "\xFF\xFE" (test-window.c:2472) is not representable in a Swift String: a drop payload
        // arrives decoded, so the invalid bytes are U+FFFD twice.
        let huge = String(repeating: "9", count: 10000)  // g_strnfill(10000, '9'), test-window.c:2470
        let bad = ["", "x", "../../etc/passwd", "%s%s%s", "99.0000,99.0000", huge, "25.7743,-80.1937 ",
                   String(decoding: [0xFF, 0xFE] as [UInt8], as: UTF8.self)]  // test-window.c:2471-2472
        let warningsBefore = fx.logs.warnings.count
        for payload in bad {
            #expect(!m.moveKey(payload, onto: tkey))
        }
        #expect(fx.names() == "Miami,Orlando,Tampa")  // test-window.c:2476
        #expect(fx.logs.warnings.count == warningsBefore)
        // A drop of a valid key moves that place to the target's position.
        #expect(m.moveKey(mkey, onto: tkey))  // test-window.c:2478
        #expect(fx.names() == "Orlando,Tampa,Miami")  // test-window.c:2480
        #expect(m.moveKey(tkey, onto: mkey))  // test-window.c:2481
        #expect(fx.names() == "Orlando,Miami,Tampa")  // test-window.c:2483
        // A row's own key as source is a no-op.
        #expect(!m.moveKey(mkey, onto: mkey))  // test-window.c:2485
        #expect(fx.names() == "Orlando,Miami,Tampa")  // test-window.c:2487
        await fx.stop()
    }

    // C: /window/window/hostile-move-request (test_hostile_move_request, test-window.c:3825-3848)
    @Test func hostileMoveRequest() async throws {
        let fx = try Fx("hostile-move")
        try fx.storePlaces([try miami(), try orlando()])
        let m = await fx.start()
        let mkey = try miami().key
        #expect(!m.move(key: "junk", by: -1))  // test-window.c:3835
        #expect(!m.move(key: "99.0000,99.0000", by: 1))  // test-window.c:3836
        #expect(!m.move(key: mkey, by: -1))  // past the start, test-window.c:3837
        #expect(!m.move(key: mkey, by: 2))  // past the end, test-window.c:3838
        #expect(!m.move(key: mkey, by: Int(Int32.max)))  // G_MAXINT, test-window.c:3839
        #expect(!m.move(key: mkey, by: Int(Int32.min)))  // G_MININT, test-window.c:3840
        #expect(!m.move(key: mkey, by: Int.max))  // no overflow at the Swift Int bounds either
        #expect(!m.move(key: mkey, by: Int.min))
        #expect(!m.remove(key: "junk"))  // test-window.c:3841
        #expect(fx.names() == "Miami,Orlando")  // test-window.c:3843
        #expect(m.move(key: mkey, by: 1))  // test-window.c:3844
        #expect(fx.names() == "Orlando,Miami")  // test-window.c:3846
        await fx.stop()
    }

    // C: /window/places/changed-elsewhere (test_places_changed_elsewhere_is_reflected,
    // test-window.c:2861-2882)
    @Test func placesChangedAreReflected() async throws {
        let fx = try Fx("changed")
        let m = await fx.start()
        #expect(m.places.isEmpty)  // "empty", test-window.c:2867
        #expect(m.add(try miami()) == .added)  // test-window.c:2869
        #expect(m.places.count == 1)  // test-window.c:2871
        #expect(m.selectedKey == (try miami().key))
        // The new place is fetched at once (the window is visible and online).
        #expect(await waitFor { m.places.first?.forecast != nil })  // test-window.c:2873
        #expect(fx.a.fetchCount == 1)  // test-window.c:2874
        // Re-adding the same place, or one within 5 km, is refused by the list.
        let near = try place("Miami Beach", 25.7743, -80.1900)  // test-window.c:2876
        #expect(m.add(near) == .duplicate)  // refused, test-window.c:2877; the reason is Swift-only (executor-added)
        #expect(m.add(try miami()) == .duplicate)
        #expect(m.places.count == 1)  // test-window.c:2878
        #expect(m.remove(key: m.places.first?.key))  // test-window.c:2879
        #expect(m.places.isEmpty)  // "empty", test-window.c:2880
        await fx.stop()
    }

    // C: /window/window/suggestion-refused-when-saved (test_suggestion_refused_when_saved,
    // test-window.c:3807-3822)
    @Test func suggestionRefusedWhenSaved() async throws {
        let fx = try Fx("suggestion")
        let m = await fx.start()
        #expect(m.add(try miami()) == .added)  // test-window.c:3815
        #expect(m.places.count == 1)  // test-window.c:3816
        // A late click on the (hidden) Miami suggestion is refused by the list: nothing changes.
        #expect(m.checkAdd(try miami()) == .duplicate)
        #expect(m.add(try miami()) == .duplicate)  // the late click, test-window.c:3818; the reason is Swift-only
        #expect(m.places.count == 1)  // nothing changes, test-window.c:3819-3820
        await fx.stop()
    }

    // C: /window/places/fifty (test_fifty_places, test-window.c:2596-2630)
    @Test func fiftyPlaces() async throws {
        let fx = try Fx("fifty", delayMs: 20)  // FxConfig {RAIN_DRY, -1, -1, 20, FALSE}, test-window.c:2598
        var places: [WxPlace] = []
        for i in 0 ..< WxPlaces.maxPlaces {
            places.append(try place(String(format: "City %02u", UInt32(i)), 25.0 + Double(i) * 0.5, -80.0))  // test-window.c:2602-2603
        }
        try fx.storePlaces(places)
        let m = await fx.start()
        #expect(m.places.count == 50)  // WX_PLACE_MAX, test-window.c:2608
        // Every place is fetched once by the visible round; all end up with a forecast.
        #expect(await waitWhileProgressing({ fx.a.fetchCount }) { fx.a.fetchCount == 50 })  // test-window.c:2611
        #expect(await waitWhileProgressing({ m.places.count { $0.forecast != nil } }) {
            m.places.allSatisfy { $0.forecast != nil }
        })  // test-window.c:2612-2613
        // The list is full: adding one more is refused by the list itself.
        let extra = try place("One too many", 10.0, 10.0)  // test-window.c:2621
        #expect(m.checkAdd(extra) == .full)
        #expect(m.add(extra) == .full)  // refused, test-window.c:2622; the reason is Swift-only (executor-added)
        #expect(m.places.count == 50)  // test-window.c:2623
        // Removing the last one from the end of the list works.
        let last = try place("City 49", 25.0 + 49 * 0.5, -80.0)  // test-window.c:2625
        #expect(m.remove(key: last.key))  // test-window.c:2627
        #expect(m.places.count == 49)  // test-window.c:2628
        await fx.stop()
    }

    // MARK: Sources

    // C: /window/sources/status-and-toggle (test_sources_page_status_and_toggle, test-window.c:2657-2725),
    // the registry/settings/refresh part (the status texts are the sources view model's).
    @Test func sourcesToggleIsAppliedAndPersisted() async throws {
        let fx = try Fx("sources", gated: true)  // test-window.c:2659
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami()])
        var m = await fx.start()
        #expect(m.selectedSourceStatuses.isEmpty)  // "No forecast loaded yet", test-window.c:2664
        #expect(await waitFor { m.places.first?.loading == true })  // test-window.c:2666
        #expect(await waitFor { gate.held >= 1 })  // the provider task has reached the gate
        gate.release()  // test-window.c:2667
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        #expect(m.selectedSourceStatuses.map(\.state) == [.ok, .ok, .ok])  // "Used for this place", test-window.c:2671-2673
        #expect(m.sources.map(\.enabled) == [true, true, true])  // test-window.c:2678-2679
        // Turning fake-b off: registry, settings and the forecast follow.
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)  // test-window.c:2683
        let aBefore = fx.a.fetchCount
        let bBefore = fx.b.fetchCount
        m.setProviderEnabled("fake-b", false)  // test-window.c:2686
        #expect(!fx.registry.isEnabled(id: "fake-b"))  // test-window.c:2687
        #expect(fx.registry.isEnabled(id: "fake-a"))  // test-window.c:2688
        #expect(!m.isProviderEnabled("fake-b"))
        #expect(await waitFor { fx.a.fetchCount == aBefore + 1 })  // test-window.c:2689
        #expect(await waitFor { gate.held == 1 })
        gate.release()  // test-window.c:2690
        #expect(await waitFor { m.places.first?.loading == false })  // test-window.c:2691
        await pump(100)  // test-window.c:2692
        #expect(fx.b.fetchCount == bBefore)  // not asked any more, test-window.c:2693
        #expect(m.selectedSourceStatus(providerID: "fake-b")?.state == .skipped)  // "Turned off", test-window.c:2696-2698
        #expect(m.selectedSourceStatus(providerID: "fake-a")?.state == .ok)
        // The choice is persisted and applied to the registry at the next start.
        fx.registry.setEnabled(true, id: "fake-b")  // a fresh process would start enabled, test-window.c:2701
        m = await fx.restart()
        #expect(!fx.registry.isEnabled(id: "fake-b"))  // test-window.c:2703
        #expect(fx.registry.isEnabled(id: "fake-a"))  // test-window.c:2704
        #expect(await waitFor { m.places.first?.loading == true })  // test-window.c:2710
        #expect(await waitFor { gate.held >= 1 })  // the provider task has reached the gate
        gate.release()  // test-window.c:2711
        #expect(await waitFor { m.places.first?.loading == false })  // test-window.c:2712
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)  // test-window.c:2713
        let aBefore2 = fx.a.fetchCount
        m.setProviderEnabled("fake-b", true)  // test-window.c:2715
        #expect(await waitFor { fx.registry.isEnabled(id: "fake-b") })  // test-window.c:2716
        #expect(await waitFor { fx.a.fetchCount > aBefore2 })  // test-window.c:2717
        await fx.stop()
        #expect(!(try fx.loadSettings().isProviderDisabled("fake-b")))  // test-window.c:2723
    }

    // MARK: Shutdown and saves

    // C: /window/lifecycle/close-with-refresh-in-flight (test_close_window_with_a_refresh_in_flight,
    // test-window.c:2797-2811); also the first test of RefreshEngine.shutdown() (U10 handoff).
    @Test func closeWithARefreshInFlight() async throws {
        let fx = try Fx("close", gated: true)  // the gate keeps the requests in flight, test-window.c:2799
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami(), try orlando()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.loading == true })  // test-window.c:2803
        #expect(await waitFor { gate.held == 2 })
        #expect(m.refreshEngine.displayClockRunning)
        let (ok, ms) = await fx.stop()
        #expect(ok)
        #expect(ms < 3000)  // test-window.c:2809
        #expect(gate.cancelled == 2)
        #expect(m.requestsInFlight == 0)
        // RefreshEngine.shutdown(): clock and timer gone, nothing in flight, inputs ignored.
        let engine = m.refreshEngine
        #expect(engine.requestsInFlight == 0)
        #expect(!engine.displayClockRunning)
        #expect(!engine.refreshTimerArmed)
        engine.setVisible(true)
        engine.windowFocused()
        m.setVisible(true)
        m.refresh()
        await pump(50)
        #expect(engine.requestsInFlight == 0)
        #expect(gate.fetches == 2)
        #expect(m.isShuttingDown)
    }

    // C: /window/lifecycle/shutdown-saves (test_shutdown_saves_everything_within_the_limit,
    // test-window.c:2814-2858)
    @Test func shutdownSavesEverythingWithinTheLimit() async throws {
        let fx = try Fx("shutdown-saves")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        // Edits made less than the 3 s save delay before the end: places, units, selection.
        let okey = try orlando().key
        #expect(m.add(try orlando()) == .added)  // test-window.c:2826
        m.select(okey)  // test-window.c:2827
        m.toggleUnits()  // test-window.c:2828
        #expect(m.saveTimerArmed)
        let (ok, ms) = await fx.stop()
        #expect(ok)
        #expect(ms < AppModel.shutdownWaitMs)  // test-window.c:2830
        let list = try fx.loadPlaces()
        #expect(list.count == 2)  // test-window.c:2835
        #expect(list.place(at: 1)?.name == "Orlando")  // test-window.c:2836
        let s = try fx.loadSettings()
        #expect(s.units == .metric)  // test-window.c:2840
        #expect(s.selected == okey)  // test-window.c:2841
        let cache = try fx.loadCache()
        #expect(cache.count >= 1)  // test-window.c:2845
        #expect(cache.get(key: try miami().key)?.forecast.place.name == "Miami")  // test-window.c:2848-2850
        // No temporary file is left behind.
        let dir = (fx.storage.placesPath as NSString).deletingLastPathComponent
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(!names.contains { $0.contains(".wx-tmp-") })  // test-window.c:2852-2856
    }

    // C: /window/app/save-failures-are-logged (test_save_failures_are_logged, test-window.c:3427-3450)
    @Test func saveFailuresAreLogged() async throws {
        let fx = try Fx("save-failures")
        let m = await fx.start()
        // A directory where a file must be written: the atomic rename cannot succeed.
        for path in [fx.storage.placesPath, fx.storage.settingsPath, fx.storage.cachePath] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        #expect(m.add(try miami()) == .added)  // the places and, once fetched, the cache, test-window.c:3440
        m.toggleUnits()  // the settings, test-window.c:3441
        #expect(await waitFor { m.places.first?.forecast != nil })  // test-window.c:3442
        let before = fx.logs.warnings.count
        let (ok, ms) = await fx.stop()
        let saveWarnings = fx.logs.warnings.dropFirst(before)
        #expect(saveWarnings.count == 3, "\(saveWarnings)")  // three g_test_expect_message, test-window.c:3443-3445
        #expect(saveWarnings.allSatisfy { $0.hasPrefix("Could not save the ") })  // test-window.c:3443
        #expect(Set(saveWarnings.compactMap { $0.split(separator: ":").first.map(String.init) })
                == ["Could not save the places", "Could not save the settings", "Could not save the cache"])
        #expect(ok)
        #expect(ms < AppModel.shutdownWaitMs)  // test-window.c:3448
    }

    // C: /window/app/edits-while-saving (test_edits_while_saving, test-window.c:3470-3493)
    @Test func editsWhileSaving() async throws {
        let fx = try Fx("edits")
        try fx.storePlaces([try miami(), try orlando()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil })
        // edit_tick every 5 ms for WX_APP_SAVE_DELAY_MS + 1500 (test-window.c:3456-3466, 3484).
        var ticks = 0
        let steps = (AppModel.saveDelayMs + 1500) / 5
        for _ in 0 ..< steps {
            ticks += 1
            m.move(from: ticks % 2 == 0 ? 1 : 0, to: ticks % 2 == 0 ? 0 : 1)
            m.setUnits(ticks % 2 == 0 ? .imperial : .metric)
            if ticks % 10 == 0 {
                m.refresh()
            }
            await fx.clock.advance(by: 5_000)
            await Task.yield()
        }
        #expect(ticks > 100)  // test-window.c:3484
        // The first edit armed the timer (t = 3 s); the saves it started found their objects edited
        // again when they completed, so a new save is scheduled (test-window.c:3480-3482).
        #expect(await waitFor { m.savesInFlight == 0 && m.saveTimerArmed })
        // At the end everything is stored once more and the files are readable.
        await fx.stop()
        #expect(try fx.loadPlaces().count == 2)  // test-window.c:3491
    }

    // C: /window/app/shutdown-stops-waiting-at-the-limit (test_shutdown_stops_waiting_at_the_limit,
    // test-window.c:3738-3774)
    @Test func shutdownStopsWaitingAtTheLimit() async throws {
        let fx = try Fx("limit")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil })
        #expect(await flushSaves(fx, [(fx.storage.settingsPath, "imperial"), (fx.storage.cachePath, "Miami")]))
        m.toggleUnits()  // the settings are dirty, test-window.c:3749
        #expect(m.add(try orlando()) == .added)  // so are the places, test-window.c:3751
        try FileManager.default.removeItem(atPath: fx.storage.placesPath)  // test-window.c:3755
        try FileManager.default.removeItem(atPath: fx.storage.settingsPath)  // test-window.c:3756
        let hold = Hold()
        m.testSaveHook = { _ in await hold.wait() }
        let t0 = fx.clock.monotonicMicroseconds
        let flushing = Task.immediate { @MainActor in await m.flush() }
        #expect(await waitFor { hold.entered >= 2 })
        let inFlight = m.savesInFlight
        await fx.clock.advance(by: (AppModel.shutdownWaitMs / 1000 + 1) * 1_000_000)  // test-window.c:3721
        let ok = await flushing.value
        #expect(!ok)
        #expect(fx.logs.warnings.last == "Gave up waiting for pending saves/requests after 5000 ms")  // test-window.c:3760-3761
        #expect(fx.clock.monotonicMicroseconds - t0 >= AppModel.shutdownWaitMs * 1000)  // test-window.c:3766
        #expect(inFlight >= 2)  // test-window.c:3769
        // The abandoned saves finish, and write their files.
        hold.release()
        #expect(await waitFor {
            fileText(fx.storage.placesPath)?.contains("Orlando") == true
                && fileText(fx.storage.settingsPath)?.contains("metric") == true
        })  // test-window.c:3754, 3772
        #expect(await waitFor { m.savesInFlight == 0 })
        fx.model = nil
    }

    // C: /window/app/disposed-while-saving (test_app_disposed_while_saving, test-window.c:3596-3637)
    @Test func modelReleasedWhileSaving() async throws {
        let fx = try Fx("disposed-saving")
        try fx.storePlaces([try miami()])
        let hold = Hold()
        do {
            let m = await fx.start()
            #expect(await waitFor { m.places.first?.forecast != nil })
            #expect(m.add(try orlando()) == .added)
            #expect(await waitFor { m.places.count == 2 && m.places[1].forecast != nil })
            #expect(await flushSaves(fx, [(fx.storage.placesPath, "Orlando"), (fx.storage.settingsPath, "imperial"),
                                          (fx.storage.cachePath, "Orlando")]))  // test-window.c:3609-3610
            // All three objects are edited in one turn: units, the removal of Orlando.
            m.toggleUnits()  // test-window.c:3614
            #expect(m.remove(key: try orlando().key))  // test-window.c:3616
            for path in [fx.storage.placesPath, fx.storage.settingsPath, fx.storage.cachePath] {
                try FileManager.default.removeItem(atPath: path)  // test-window.c:3620
            }
            m.testSaveHook = { _ in await hold.wait() }
            await fx.clock.advance(by: (AppModel.saveDelayMs / 1000 + 1) * 1_000_000)  // test-window.c:3626
            #expect(await waitFor { hold.entered == 3 })  // test-window.c:3627
            #expect(m.savesInFlight == 3)  // test-window.c:3628
        }
        weak let gone = fx.model
        fx.model = nil  // g_object_run_dispose, test-window.c:3629
        #expect(gone == nil)
        // The abandoned saves finish and write their files.
        hold.release()
        #expect(await waitFor {
            fileText(fx.storage.placesPath)?.contains("Miami") == true
                && fileText(fx.storage.placesPath)?.contains("Orlando") == false
                && fileText(fx.storage.settingsPath)?.contains("metric") == true
                && fileText(fx.storage.cachePath)?.contains("Miami") == true
        })  // marks Miami / metric / Miami, test-window.c:3618, 3634
    }

    // C: /window/app/disposed-with-request-in-flight (test_app_disposed_with_request_in_flight,
    // test-window.c:3658-3688)
    @Test func modelReleasedWithRequestsInFlight() async throws {
        let fx = try Fx("disposed-requests", gated: true)  // test-window.c:3660
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami(), try orlando(), try tampa()])
        do {
            let m = await fx.start()
            #expect(await waitFor { gate.fetches == 3 })  // test-window.c:3664
            #expect(m.places.first?.loading == true)  // test-window.c:3665
        }
        weak let gone = fx.model
        fx.model = nil  // test-window.c:3666
        #expect(gone == nil)
        #expect(await waitFor { gate.cancelled == 3 })  // test-window.c:3667
        gate.release()  // the answers arrive after the disposal, test-window.c:3669
        await pump(100)  // test-window.c:3670
        #expect(gate.fetches == 3)  // test-window.c:3682
        #expect(fx.registry.isEnabled(id: "fake-b"))  // test-window.c:3683
    }

    // C: /window/app/unref-with-cancelled-requests-pending (test_app_unref_with_cancelled_requests_pending,
    // test-window.c:3693-3705)
    @Test func releasedWithCancelledRequestsPending() async throws {
        let fx = try Fx("unref", gated: true)
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami(), try orlando()])
        do {
            let m = await fx.start()
            #expect(await waitFor { gate.fetches == 2 })  // test-window.c:3699
            m.setVisible(false)  // the window goes: the requests are cancelled
        }
        fx.model = nil  // test-window.c:3700
        #expect(await waitFor { gate.cancelled == 2 })  // test-window.c:3701
        gate.release()  // test-window.c:3702
        await pump(100)  // test-window.c:3703
        #expect(gate.fetches == 2)
    }

    // MARK: Persistence acceptance (U27)

    // C: /window/units/toggle-and-persistence, /window/places/move-up-down,
    // /window/sources/status-and-toggle, /window/places/selection-default-and-persist and
    // /window/refresh/cached-at-once together: model #1 changes everything, model #2 offline
    // restores it, shows the cached forecast marked offline and requests nothing.
    @Test func everythingPersistsAcrossLaunches() async throws {
        let fx = try Fx("roundtrip")
        let m1 = await fx.start()
        #expect(m1.add(try miami()) == .added)
        #expect(m1.add(try orlando()) == .added)
        #expect(m1.add(try tampa()) == .added)
        #expect(m1.moveUp(key: try tampa().key))
        m1.setUnits(.metric)
        m1.setProviderEnabled("fake-b", false)
        m1.select(try orlando().key)
        #expect(await waitFor { m1.places.allSatisfy { $0.forecast != nil && !$0.loading } })
        let names = fx.names()
        #expect(names == "Miami,Tampa,Orlando")
        let (ok, _) = await fx.stop()
        #expect(ok)
        fx.registry.setEnabled(true, id: "fake-b")  // a fresh process starts enabled
        let aBefore = fx.a.fetchCount
        let m2 = AppModel(registry: fx.registry, storage: fx.storage, clock: fx.clock, online: false)
        fx.model = m2
        await m2.load()
        m2.setVisible(true)
        m2.setFocused(true)
        #expect(fx.names() == "Miami,Tampa,Orlando")
        #expect(m2.units == .metric)
        #expect(!fx.registry.isEnabled(id: "fake-b"))
        #expect(m2.selectedKey == (try orlando().key))
        #expect(m2.isOffline)
        #expect(m2.places.allSatisfy { $0.forecast != nil && $0.offline && $0.units == .metric })
        #expect(m2.places.allSatisfy { $0.fetchedS == fx.clock.wallSeconds })
        await pump(100)
        #expect(m2.requestsStarted == 0)
        #expect(fx.a.fetchCount == aBefore)
        #expect(!m2.isRefreshEnabled)
        await fx.stop()
    }

    // wx-app.h:104-108, wx-app.c:573-578 (schedule_save) and storage-sched-service.md:251-253: the
    // first change arms ONE 3 s timer, later changes do not move it; the cache is saved the same way.
    // C: none - contract test of wx-app.h:104-108 (executor-added)
    @Test func saveIsDebouncedFromTheFirstChange() async throws {
        let fx = try Fx("debounce")
        try fx.storePlaces([try miami(), try orlando()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start(visible: false)
        #expect(!m.saveTimerArmed)  // nothing changed by the load
        m.setUnits(.metric)  // t = 0: the first change
        #expect(m.saveTimerArmed)
        await fx.clock.advance(by: 2_000_000)
        #expect(m.moveDown(key: try miami().key))  // t = 2 s: does not move the timer
        await fx.clock.advance(by: (AppModel.saveDelayMs - 2000) * 1000 - 1)  // t = 3 s - 1 us
        await pump(50)
        #expect(fileText(fx.storage.settingsPath)?.contains("imperial") == true)
        #expect(m.saveTimerArmed)
        await fx.clock.advance(by: 1)  // t = 3 s
        #expect(!m.saveTimerArmed)
        #expect(await waitFor {
            fileText(fx.storage.settingsPath)?.contains("metric") == true
                && (try? fx.loadPlaces().place(at: 0)?.name) == "Orlando"
        })
        // The cache: a forecast arms the timer the same way.
        #expect(fileText(fx.storage.cachePath) == nil)
        m.setVisible(true)
        #expect(await waitFor { m.places.allSatisfy { $0.forecast != nil } })
        #expect(m.saveTimerArmed)
        await fx.clock.advance(by: AppModel.saveDelayMs * 1000 - 1)
        await pump(50)
        #expect(fileText(fx.storage.cachePath) == nil)
        await fx.clock.advance(by: 1)
        #expect(await waitFor { fileText(fx.storage.cachePath)?.contains("Orlando") == true })
        await fx.stop()
    }

    // wx-app.h:110-115: flush(timeout:) never waits longer than WX_APP_SHUTDOWN_WAIT_MS (5000).
    // C: none - contract test of wx-app.h:108-111, 153 (executor-added)
    @Test func flushWaitsAtMostFiveSeconds() async throws {
        let fx = try Fx("flush-limit")
        let m = await fx.start()
        #expect(m.add(try miami()) == .added)
        let hold = Hold()
        m.testSaveHook = { _ in await hold.wait() }
        let t0 = fx.clock.monotonicMicroseconds
        let flushing = Task.immediate { @MainActor in await m.flush(timeout: 60) }
        #expect(await waitFor { hold.entered >= 1 })
        await fx.clock.advance(by: AppModel.shutdownWaitMs * 1000 - 1)
        await pump(20)
        #expect(fx.logs.warnings.isEmpty)
        await fx.clock.advance(by: 1)
        #expect(await flushing.value == false)
        #expect(fx.clock.monotonicMicroseconds - t0 == AppModel.shutdownWaitMs * 1000)
        #expect(fx.logs.warnings == ["Gave up waiting for pending saves/requests after 5000 ms"])  // wx-app.c:2004
        hold.release()
        #expect(await waitFor { m.savesInFlight == 0 })
        fx.model = nil
    }

    // MARK: RefreshEngine host contract (U10 verifiers)

    // wx-app.c:1621-1625 / wx-app.h:158: a manual refresh exactly WX_APP_REFRESH_MIN_GAP_S after
    // the latest request is fetched; 1 us earlier it is dropped (the `>=` of RefreshEngine).
    // C: none - contract test of wx-app.h:387-405, 158 (nearest: /window/refresh/rate-limited)
    @Test func manualRefreshAtExactlyTheMinimumGap() async throws {
        let fx = try Fx("gap")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        #expect(m.requestsStarted == 1)
        await fx.clock.advance(by: RefreshEngine.refreshMinGapS * 1_000_000 - 1)  // 10 s - 1 us
        m.refresh()
        #expect(m.requestsStarted == 1)  // dropped
        await fx.clock.advance(by: 1)  // exactly 10 s
        m.refresh()
        #expect(m.requestsStarted == 2)  // fetched
        #expect(m.places.first?.loading == true)
        #expect(await waitFor { m.places.first?.loading == false })
        await fx.stop()
    }

    // The due-deadline path after a system sleep (U10 verify_p2): the wall clock jumps 3600 s
    // ahead of the monotonic clock, then a focus event: the due timer fires after the input has
    // returned and re-arms for a future deadline, without recursion.
    // C: none - contract test of wx-app.h:328-343 (nearest: /window/clock/periodic-round)
    @Test func dueDeadlineAfterSleepFiresAfterTheInput() async throws {
        let fx = try Fx("sleep-wake")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        m.setFocused(true)
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        #expect(m.requestsStarted == 1)
        await fx.clock.advance(by: 570 * 1_000_000)  // inside the 600 s period
        #expect(m.requestsStarted == 1)
        fx.clock.advanceWall(by: 3600 * 1_000_000)  // the system slept for an hour
        m.setFocused(false)
        m.setFocused(true)  // the scheduler's deadline is due now; focus round
        #expect(m.requestsStarted == 2)  // the place is not fresh any more
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(m.refreshEngine.refreshTimerArmed)
        #expect(m.requestsStarted == 2)
        #expect(await waitFor { m.places.first?.loading == false })
        await fx.stop()
    }

    // U10 host contract (a): a request AppModel cancelled is reported .cancelled even when a late
    // RATE_LIMITED arrives (wx-service.c:1173, wx-app.c:958-959): no cool-down starts.
    // C: none - contract test of wx-app.h:54, 90-102 (nearest: /window/refresh/stale-kept-when-cancelled-by-hide)
    @Test func lateRateLimitAfterCancelStartsNoCoolDown() async throws {
        let fx = try Fx("late-429")
        try fx.storePlaces([try miami()])
        let hold = Hold()
        let m = await fx.start(visible: false)
        m.testRefresh = { _ in
            await hold.wait()  // ignores cancellation
            throw WxError(.rateLimited, "HTTP 429: rate limited")
        }
        m.setVisible(true)
        #expect(m.requestsStarted == 1)
        #expect(await waitFor { hold.entered == 1 })
        m.setVisible(false)  // cancels the request
        hold.release()  // the late 429
        #expect(await waitFor { m.requestsInFlight == 0 })
        #expect(m.places.first?.stale == false)
        #expect(m.places.first?.errorText == nil)
        m.testRefresh = nil
        m.setVisible(true)  // no cool-down: the visible round asks again at once
        #expect(m.requestsStarted == 2)
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        await fx.stop()
    }

    // U10 host contract (a): a late OK after a cancel does not clear the stale mark, and its
    // forecast is not applied.
    // C: none - contract test of wx-app.h:54-57 (nearest: /window/refresh/stale-kept-when-cancelled-by-hide)
    @Test func lateOKAfterCancelDoesNotClearStale() async throws {
        let fx = try Fx("late-ok")
        try fx.storePlaces([try miami()])
        let m = await fx.start(visible: false)
        let key = try miami().key
        m.testRefresh = { _ in throw WxError(.network, "network down") }
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.stale == true })
        #expect(m.places.first?.errorText == "network down")
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)
        let hold = Hold()
        let forecast = try WxForecast(place: try miami(), generatedS: fx.clock.wallSeconds)
        m.testRefresh = { _ in
            await hold.wait()
            return forecast
        }
        m.refresh()
        #expect(m.requestsStarted == 2)
        #expect(await waitFor { hold.entered == 1 })
        m.setVisible(false)  // cancels it
        hold.release()  // the late OK
        #expect(await waitFor { m.requestsInFlight == 0 })
        #expect(m.place(forKey: key)?.stale == true)
        #expect(m.place(forKey: key)?.forecast == nil)
        #expect(m.place(forKey: key)?.errorText == "network down")
        await fx.stop()
    }

    // U10 host contract (b), wx-window.c:319-324: Refresh is enabled iff a place is selected, it is
    // not loading and the network is available - with no visibility term.
    // C: none - contract test of wx-window.c:304-308, 319-324 (nearest: /window/keyboard/accelerators-and-actions)
    @Test func refreshEnabledHasNoVisibilityTerm() async throws {
        let fx = try Fx("refresh-enabled", gated: true)
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami()])
        let m = await fx.start(visible: false)
        #expect(m.isRefreshEnabled)  // hidden, selected, online, idle
        #expect(!m.refreshEngine.canRefresh)  // the engine's rule needs visibility
        m.setOnline(false)
        #expect(!m.isRefreshEnabled)
        m.setOnline(true)
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.loading == true })
        #expect(!m.isRefreshEnabled)  // loading
        #expect(await waitFor { gate.held >= 1 })  // the provider task has reached the gate
        gate.release()
        #expect(await waitFor { m.places.first?.loading == false })
        #expect(m.isRefreshEnabled)
        m.select(nil)
        #expect(!m.isRefreshEnabled)  // nothing selected
        await fx.stop()
    }

    // MARK: Contract sweep (wx-app.h comment blocks)

    // wx-app.h:52-54 + wx_row_item_set_error (wx-row.c:504-516): a failed refresh keeps the forecast,
    // records the sanitised reason (at most WX_ROW_ERROR_MAX_BYTES = 200 bytes, wx-row.h:57) and marks
    // the place stale; the next success clears both.
    // C: none - contract test of wx-app.h:52-54 (nearest: /window/refresh/stale-keeps-data)
    @Test func failedRefreshKeepsTheForecastAndRecordsTheSanitisedReason() async throws {
        let fx = try Fx("failure-text")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        let generated = m.places.first?.forecast?.generatedS
        let long = "bad\u{07}gateway " + String(repeating: "x", count: 300)
        m.testRefresh = { _ in throw WxError(.http, long) }
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)
        m.refresh()
        #expect(await waitFor { m.places.first?.stale == true })
        let item = try #require(m.places.first)
        #expect(item.forecast?.generatedS == generated)
        #expect(item.errorText == WxText.sanitize(long, maxBytes: 200))
        #expect((item.errorText?.utf8.count ?? 0) <= 200)
        #expect(item.errorText?.contains("\u{07}") == false)
        m.testRefresh = nil
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)
        m.refresh()
        #expect(await waitFor { m.places.first?.stale == false && m.places.first?.loading == false })
        #expect(m.places.first?.errorText == nil)
        await fx.stop()
    }

    // apply_forecast (wx-app.c:961-963): a forecast the cache refuses (a clock outside its range) is
    // still shown; nothing is cached and no save is scheduled for it.
    // C: none - contract test of wx-app.c:961-963 (executor-added)
    @Test func forecastRefusedByTheCacheIsStillShown() async throws {
        let fx = try Fx("cache-refused")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start(visible: false)
        let place = try miami()
        let forecast = try WxForecast(place: place, generatedS: fx.clock.wallSeconds)
        // The wall clock is moved below the cache's fetch-time range only for this delivery.
        let shift = (fx.clock.wallSeconds - WxLimits.timeMinS + 10) * 1_000_000
        m.testRefresh = { [clock = fx.clock] _ in
            clock.advanceWall(by: -shift)
            return forecast
        }
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.forecast != nil })
        #expect(m.places.first?.fetchedS == fx.clock.wallSeconds)
        #expect(!m.saveTimerArmed)
        fx.clock.advanceWall(by: shift)
        await fx.stop()
        #expect(!FileManager.default.fileExists(atPath: fx.storage.cachePath))  // the cache stayed clean
    }

    // wx-app.h:61-62: a place removed while a request is in flight has the late result dropped (its
    // request is cancelled; nothing reaches the cache).
    // C: none - contract test of wx-app.h:62-63 (executor-added)
    @Test func removedPlaceDropsTheLateResult() async throws {
        let fx = try Fx("removed-late", gated: true)
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami(), try orlando()])
        let m = await fx.start()
        #expect(await waitFor { gate.held == 2 })
        #expect(m.remove(key: try orlando().key))
        #expect(await waitFor { gate.cancelled == 1 })
        gate.release()
        #expect(await waitFor { m.requestsInFlight == 0 })
        #expect(m.places.map(\.place.name) == ["Miami"])
        #expect(m.places.first?.forecast != nil)
        await fx.stop()
        let cache = try fx.loadCache()
        #expect(cache.count == 1)
        #expect(cache.get(key: try orlando().key) == nil)
    }

    // wx-app.h:84-89 ("Clock"): every change of visibility or of the network state gives the items
    // the current time once.
    // C: none - contract test of wx-app.h:84-89 (nearest: /window/rain/rows-follow-item-clock)
    @Test func itemsGetTheTimeOnVisibilityAndNetworkChanges() async throws {
        let fx = try Fx("now")
        try fx.storePlaces([try miami()])
        let m = await fx.start(visible: false)
        let t0 = fx.clock.wallSeconds
        #expect(m.places.first?.nowS == t0)
        fx.clock.advanceWall(by: 90 * 1_000_000)
        m.setVisible(true)
        #expect(m.places.first?.nowS == t0 + 90)
        #expect(m.displayNowS == t0 + 90)
        fx.clock.advanceWall(by: 30 * 1_000_000)
        m.setOnline(false)
        #expect(m.places.first?.nowS == t0 + 120)
        #expect(m.places.first?.offline == true)
        fx.clock.advanceWall(by: 30 * 1_000_000)
        m.setOnline(false)  // no change: no new time
        #expect(m.places.first?.nowS == t0 + 120)
        await fx.stop()
    }

    // storage-sched-service.md:255 (wx-app.c:483-490): a failed save is logged and NOT retried
    // until the next edit.
    // C: none - contract test of wx-app.c:483-490 (nearest: /window/app/save-failures-are-logged)
    @Test func failedSaveIsNotRetriedUntilTheNextEdit() async throws {
        let fx = try Fx("no-retry")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start(visible: false)
        try FileManager.default.removeItem(atPath: fx.storage.settingsPath)
        try FileManager.default.createDirectory(atPath: fx.storage.settingsPath, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        m.setUnits(.metric)
        await fx.clock.advance(by: AppModel.saveDelayMs * 1000)
        #expect(await waitFor { m.savesInFlight == 0 && fx.logs.warnings.count == 1 })
        #expect(fx.logs.warnings.first?.hasPrefix("Could not save the settings: ") == true)  // wx-app.c:484
        #expect(!m.saveTimerArmed)
        await fx.clock.advance(by: 10 * AppModel.saveDelayMs * 1000)
        await pump(20)
        #expect(fx.logs.warnings.count == 1)
        m.setUnits(.imperial)  // the next edit
        #expect(m.saveTimerArmed)
        try FileManager.default.removeItem(atPath: fx.storage.settingsPath)
        await fx.stop()
        #expect(try fx.loadSettings().units == .imperial)
    }

    // wx-app.h:398-404, 470-475 and /window/app/refresh-and-switch-edge-cases (test-window.c:2906-2929),
    // the model part: an unknown provider id or an unchanged flag changes nothing; a switch while
    // offline flips the registry and fetches nothing; nothing changes once shutting down.
    // C: /window/app/refresh-and-switch-edge-cases (the model part; U10 ports the engine part)
    @Test func providerSwitchAndShutdownEdgeCases() async throws {
        let fx = try Fx("switch-edges")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start(visible: false)
        m.setProviderEnabled("no-such-provider", false)  // test-window.c:2924
        // The same state again (the rule of test-window.c:2925, where C repeats FALSE after disabling
        // fake-b; here fake-b is enabled and true is repeated).
        m.setProviderEnabled("fake-b", true)
        #expect(!m.saveTimerArmed)
        #expect(fx.registry.isEnabled(id: "fake-a") && fx.registry.isEnabled(id: "fake-b"))
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        let n = fx.a.fetchCount
        m.setOnline(false)
        m.refresh()  // offline, test-window.c:2918
        m.setProviderEnabled("fake-b", false)  // offline: switched, not fetched, test-window.c:2919
        await pump(200)  // test-window.c:2920
        #expect(fx.a.fetchCount == n)  // test-window.c:2921
        #expect(!fx.registry.isEnabled(id: "fake-b"))  // test-window.c:2922
        m.setOnline(true)
        #expect(await m.flush())
        m.setUnits(.metric)
        m.select(nil)
        m.setProviderEnabled("fake-b", true)
        #expect(m.add(try orlando()) == .failed)
        #expect(!m.remove(key: try miami().key))
        #expect(!m.moveDown(key: try miami().key))
        let mkey = try miami().key
        #expect(m.units == .imperial && m.selectedKey == mkey)
        #expect(!fx.registry.isEnabled(id: "fake-b"))
        fx.model = nil
    }

    // DECISIONS #50 (U26 verifier) + U10 host contract (a): on the service's no-covering-provider
    // path refresh returns without suspending; a cancel that lands after the service completed but
    // before AppModel resumed must still end the request CANCELLED (C: GTask defers the callback, so
    // refresh_done sees CANCELLED, wx-service.c:1173) - no stale mark, no error text, no cool-down.
    // C: none - contract test of wx-app.h:54 and wx-service.c:1173, DECISIONS #50 (executor-added)
    @Test func cancelAfterTheNoCoveringCompletionStillWins() async throws {
        let fx = try Fx("no-covering-cancel")
        fx.a.setCovers(false)
        fx.b.setCovers(false)
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start(visible: false)
        // The plain path: the request fails with the service's own message and marks the place.
        m.setVisible(true)
        #expect(await waitFor { m.places.first?.stale == true })
        #expect(m.places.first?.errorText == "no enabled data source covers this place")  // wx-service.c:1146
        m.setVisible(false)
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)
        // A second place, never fetched: its request is cancelled right after the real service
        // returned (the cancel comes from hiding the window, between return and resume).
        let okey = try orlando().key
        #expect(m.add(try orlando()) == .added)
        var serviceReturned = 0
        m.testRefresh = { [weak m, service = m.service] place in
            do {
                return try await service.refresh(place)
            } catch {
                serviceReturned += 1
                m?.setVisible(false)  // the engine cancels the request now
                throw error
            }
        }
        m.setVisible(true)
        #expect(await waitFor { serviceReturned >= 1 && m.requestsInFlight == 0 })
        #expect(m.place(forKey: okey)?.stale == false)
        #expect(m.place(forKey: okey)?.errorText == nil)
        // No cool-down and no failure recorded: the next visible round asks it again at once.
        m.testRefresh = nil
        let started = m.requestsStarted
        m.setVisible(true)
        #expect(m.requestsStarted > started)
        #expect(await waitFor { m.place(forKey: okey)?.stale == true })
        await fx.stop()
    }

    // DECISIONS #50 for the search: a caller cancelled before search returns gets
    // CancellationError even when the geocoder's hits were ready (wx-service.h:153-164).
    // C: none - contract test of wx-service.h:153-164, DECISIONS #50 (executor-added)
    @Test func searchCancelledBeforeItReturnsThrowsCancellation() async throws {
        let fx = try Fx("search-cancel")
        fx.geocoder.addHit(try orlando())
        let m = await fx.start(visible: false)
        #expect(try await m.search("Orlando").map(\.name) == ["Orlando"])
        let task = Task { @MainActor in try await m.search("Orlando") }
        task.cancel()
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        // The cancel lands after the service returned the hits and before AppModel resumes: only
        // AppModel's own re-check can turn it into CancellationError (the service has no
        // suspension point left after its check, so the seam stands in for that window).
        let served = Counter()
        m.testSearch = { [service = m.service] bytes in
            let hits = try await service.search(textBytes: bytes)
            served.bump()
            withUnsafeCurrentTask { $0?.cancel() }
            return hits
        }
        let late = Task { @MainActor in try await m.search("Orlando") }
        let lateOutcome = await late.result
        #expect(served.count == 1)
        #expect(throws: CancellationError.self) { try lateOutcome.get() }
        m.testSearch = nil
        await fx.stop()
    }

    // MARK: Retry 2 (U27 verify iteration 1)

    // C: /window/app/shutdown-while-loading (test_shutdown_while_loading, test-window.c:3404-3420),
    // with the worker forced to resume the load's continuation before load() awaits it: load_done is
    // a GTask callback that C always defers to the main loop, so a shutdown in the same turn wins.
    @Test func shutdownWhileLoadingWithTheWorkerFirst() async throws {
        let fx = try Fx("shutdown-loading-first")
        try fx.storePlaces([try miami()])
        let m = AppModel(registry: fx.registry, storage: fx.storage, clock: fx.clock, online: true)
        fx.model = m
        m.testLoadWorkerFirst = true
        let loader = Task.immediate { @MainActor in await m.load() }  // the worker has already finished
        m.setVisible(true)
        let t0 = fx.clock.monotonicMicroseconds  // the clock of the model's limit, test-window.c:3412
        let ok = await m.flush()  // test-window.c:3413
        let elapsedUs = fx.clock.monotonicMicroseconds - t0
        await loader.value
        #expect(ok)
        #expect(elapsedUs < AppModel.shutdownWaitMs * 1000)  // test-window.c:3414
        #expect(m.places.isEmpty)  // test-window.c:3415
        #expect(!m.isLoaded)
        #expect(fx.a.fetchCount == 0)  // test-window.c:3417
        #expect(m.requestsStarted == 0)
        fx.model = nil
    }

    // C: /window/app/shutdown-while-loading (test-window.c:3404-3420), pinning WHERE load() defers:
    // with the worker first, a flush is queued on the main actor from the worker thread after the
    // continuation was resumed and while load()'s own job is still running (blocked on the seam's
    // handshake). C delivers load_done by a later main-loop dispatch than anything queued before it,
    // so the queued quit wins. Only a deferral AFTER the continuation (and before loadDone) gives
    // that order; a yield before the hand-off to the worker, or none, loads the place first.
    @Test func flushQueuedWhileTheLoadTurnRunsWins() async throws {
        let fx = try Fx("shutdown-loading-queued")
        try fx.storePlaces([try miami()])
        let m = AppModel(registry: fx.registry, storage: fx.storage, clock: fx.clock, online: true)
        fx.model = m
        m.setVisible(true)
        let flushed = FlushBox()
        m.testLoadWorkerFirst = true
        m.testLoadAfterWorkerResume = { [m] in
            Task { @MainActor in  // queued on the main actor from the worker thread
                flushed.started = true
                flushed.ok = await m.flush()
            }
        }
        let t0 = fx.clock.monotonicMicroseconds  // test-window.c:3412
        await m.load()
        #expect(await waitFor { flushed.ok != nil })
        #expect(flushed.started)
        #expect(flushed.ok == true)
        #expect(fx.clock.monotonicMicroseconds - t0 < AppModel.shutdownWaitMs * 1000)  // test-window.c:3414
        #expect(m.places.isEmpty)  // test-window.c:3415
        #expect(!m.isLoaded)
        #expect(fx.a.fetchCount == 0)  // test-window.c:3417
        #expect(m.requestsStarted == 0)
        fx.model = nil
    }

    // C: /window/refresh/rate-limit-cool-down (test_rate_limited_place_waits_for_the_cool_down,
    // test-window.c:1715-1746) through AppModel and the real service: only a forwarded
    // WxError(.rateLimited) starts the 60 s cool-down (RefreshEngine host contract, wx-app.c:1012-1013).
    @Test func rateLimitStartsTheCoolDownThroughTheModel() async throws {
        let fx = try Fx("cool-down")
        try fx.storePlaces([try miami()])
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })  // test-window.c:1723-1724
        #expect(fx.a.fetchCount == 1)  // test-window.c:1726
        fx.a.failWith(.rateLimited)  // test-window.c:1728
        fx.b.failWith(.rateLimited)  // test-window.c:1729
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)  // test-window.c:1730
        m.refresh()  // test-window.c:1731
        #expect(await waitFor { fx.a.fetchCount == 2 })  // test-window.c:1732
        #expect(await waitFor { m.places.first?.stale == true })  // test-window.c:1733
        #expect(await waitFor { m.places.first?.loading == false })  // test-window.c:1734
        // The gap has passed, the cool-down has not.
        await fx.clock.advance(by: (RefreshEngine.refreshMinGapS + 1) * 1_000_000)  // test-window.c:1736
        #expect(m.isRefreshEnabled)  // test-window.c:1737
        for _ in 0 ..< 20 {  // test-window.c:1738-1739
            m.refresh()
        }
        m.setVisible(false)  // a visible round does not reach a cooling-down place either
        m.setVisible(true)
        await pump(100)  // test-window.c:1740
        #expect(fx.a.fetchCount == 2)  // test-window.c:1741
        // The cool-down is over: the place is given back to the scheduler, which asks it once.
        await fx.clock.advance(by: (RefreshEngine.rateLimitCooldownS - RefreshEngine.refreshMinGapS) * 1_000_000)  // test-window.c:1743
        #expect(await waitFor { fx.a.fetchCount == 3 })  // test-window.c:1744
        #expect(await waitFor { m.places.first?.loading == false })  // test-window.c:1745
        #expect(m.places.first?.stale == true)  // test-window.c:1746
        await fx.stop()
    }

    // C: none - contract test of save_done's shutdown branch (wx-app.c:489-490: saved, but edited
    // while writing, while shutting down -> the save starts at once). The edit and the flush happen
    // in the cache save's hook: after the settings snapshot, before its completion.
    @Test func editWhileWritingDuringShutdownIsSavedAtOnce() async throws {
        let fx = try Fx("shutdown-branch")
        try fx.storePlaces([try miami()])
        try fx.storeSettings(.imperial, selected: try miami().key)
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil && m.places.first?.loading == false })
        m.setUnits(.metric)
        #expect(m.saveTimerArmed)
        let edited = Counter()
        var flushing: Task<Bool, Never>?
        m.testSaveHook = { [weak m] kind in
            guard kind == .cache, edited.count == 0, let m else {
                return
            }
            edited.bump()
            m.setUnits(.imperial)  // the settings are dirty again after their "metric" snapshot
            flushing = Task.immediate { @MainActor in await m.flush() }
        }
        await fx.clock.advance(by: AppModel.saveDelayMs * 1000)  // the debounce starts the saves
        #expect(await waitFor { edited.count == 1 })
        #expect(m.isShuttingDown)
        let ok = await flushing?.value
        #expect(ok == true)
        #expect(fileText(fx.storage.settingsPath)?.contains("imperial") == true,
                "settings.json: \(fileText(fx.storage.settingsPath) ?? "nil")")
        #expect(m.savesInFlight == 0)
        fx.model = nil
    }

    // MARK: API surface for U28-U34 (compile-only use of every public member)

    // C: none - compile-only API test of the U27 brief (executor-added)
    @Test func publicSurfaceForTheViewModels() async throws {
        let fx = try Fx("surface")
        try fx.storePlaces([try miami()])
        fx.geocoder.addHit(try orlando())
        let m = await fx.start()
        #expect(await waitFor { m.places.first?.forecast != nil })
        let item: AppModel.Place? = m.places.first
        let forecast: WxForecast? = item?.forecast
        let fetchedS: Int64? = item?.fetchedS
        let flags: (Bool?, Bool?, Bool?) = (item?.loading, item?.stale, item?.offline)
        let itemUnits: WxUnits? = item?.units
        let nowS: Int64? = item?.nowS
        let error: String?? = item?.errorText
        let identity: (String?, String?, WxPlace?) = (item?.key, item?.id, item?.place)
        #expect(forecast != nil && fetchedS != nil && flags.0 == false && itemUnits == .imperial && nowS != nil)
        #expect(error != nil && identity.0 == identity.1 && identity.2?.name == "Miami")
        let displayNow: Int64 = m.displayNowS
        let selected: (String?, AppModel.Place?) = (m.selectedKey, m.selectedPlace)
        let byKey: AppModel.Place? = m.place(forKey: try miami().key)
        #expect(displayNow > 0 && selected.0 != nil && selected.1 != nil && byKey != nil)
        let mkey = try miami().key
        let okey = try orlando().key
        let refusal: AppModel.AddResult = m.checkAdd(try miami())
        let results: [AppModel.AddResult] = [.added, .full, .duplicate, .failed]
        #expect(refusal == .duplicate && results.count == 4 && m.isSaved(key: mkey))
        #expect(m.add(try orlando()) == .added)
        #expect(m.move(from: 0, to: 1) && m.move(key: mkey, by: -1))
        #expect(m.moveUp(key: okey) && m.moveDown(key: okey))
        #expect(m.moveKey(mkey, onto: okey))
        #expect(m.remove(key: okey))
        let units: WxUnits = m.units
        m.setUnits(.metric)
        m.toggleUnits()
        #expect(units == .imperial && m.units == .imperial)
        let sources: [AppModel.Source] = m.sources
        let source: AppModel.Source? = sources.first
        #expect(source?.id == "fake-a" && source?.name == "Fake fake-a" && source?.enabled == true)
        #expect(source?.attribution == "Fake data (fake-a)" && source?.attributionURL == "https://example.invalid/")
        #expect(m.isProviderEnabled("fake-a"))
        m.setProviderEnabled("fake-a", true)
        let statuses: [WxSourceStatus] = m.selectedSourceStatuses
        let status: WxSourceStatus? = m.selectedSourceStatus(providerID: "fake-a")
        #expect(statuses.count == 2 && status?.state == .ok)
        let hits: [WxPlace] = try await m.search("Orlando")
        let byteHits: [WxPlace] = try await m.search(textBytes: Array("Orlando".utf8))
        #expect(hits.map(\.name) == ["Orlando"] && byteHits.count == 1)
        m.setVisible(true)
        m.setFocused(true)
        m.setOnline(true)
        let enabled: Bool = m.isRefreshEnabled
        let offline: Bool = m.isOffline
        m.refresh()
        #expect(!offline && (enabled || m.selectedPlace?.loading == true))
        let state: (Bool, Bool) = (m.isLoaded, m.isShuttingDown)
        #expect(state == (true, false))
        let registry: WxRegistry = m.registry
        let service: ServiceOrchestrator = m.service
        let storage: AppEnvironment.StorageRoot = m.storage
        #expect(registry === fx.registry && storage == fx.storage)
        _ = service
        let constants: (String, Int64, Int64, Int) = (AppModel.appID, AppModel.saveDelayMs, AppModel.shutdownWaitMs,
                                                      AppModel.errorTextMaxBytes)
        #expect(constants == ("io.github.wtp128pro.Weather", 3000, 5000, 200))  // wx-app.h:149-153, wx-row.h:57
        let sink: AppModel.LogSink = AppModel.systemLog
        let levels: [AppModel.LogLevel] = [.warning, .debug]
        #expect(levels.count == 2)
        _ = sink
        await m.load()  // already loaded: no-op
        let flushed: Bool = await m.flush(timeout: 5)
        #expect(flushed)
        fx.model = nil
    }
}
