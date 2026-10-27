// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// UnitsAppModelTests.swift - per-place units in AppModel (U49): every item's
// units are its place's saved units (WxPlaces.units(forKey:)), else the
// default units; a places.json from before per-place units is migrated once at
// the load to the settings.json units and saved; setUnits(_:forKey:) changes
// one place, setDefaultUnits only the places added afterwards, and
// units/setUnits(_:)/toggleUnits() act on the selected place, else on the
// default; add, addCustomLocation and the first-run chips save the units.
//
// Fixture: UnitsFx is AppModelTests' Fx reduced to what these cases need (a
// FakeProvider covering every place, optionally the gate provider that holds
// a fetch until released, a ManualClock, the three files in a temporary
// directory). Everything runs through the real AppModel, WxPlaces and
// WxSettings; nothing is stubbed between them.

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

// MARK: - Fixture

/// Covers every place and answers a fetch only when released; a cancelled fetch throws
/// CancellationError (AppModelTests' GateProvider).
private final class UnitsGate: WxProvider {
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

    var fetches: Int { state.withLock { $0.fetches } }
    var cancelled: Int { state.withLock { $0.cancelled } }
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

@MainActor
private final class UnitsLog {
    var lines: [(AppModel.LogLevel, String)] = []
    var warnings: [String] { lines.filter { $0.0 == .warning }.map(\.1) }
}

/// The save kinds started, in order (AppModel.testSaveHook).
@MainActor
private final class SaveLog {
    var kinds: [AppModel.SaveKind] = []
    var places: Int { kinds.filter { $0 == .places }.count }
}

@MainActor
private final class UnitsFx {
    let dir: TemporaryDirectory
    let storage: AppEnvironment.StorageRoot
    let clock = ManualClock()
    let registry = WxRegistry()
    let a: FakeProvider?
    let gate: UnitsGate?
    let logs = UnitsLog()
    var model: AppModel?

    /// gated: the gate is the only provider (a refresh stays in flight until released).
    init(_ label: String, gated: Bool = false) throws {
        dir = try TemporaryDirectory("units-appmodel-\(label)")
        storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                             cacheDirectory: dir.appending("cache").path)
        if gated {
            let g = UnitsGate(member: try Self.member("gate", clock))
            try registry.addProvider(g)
            gate = g
            a = nil
        } else {
            let p = FakeProvider(id: "fake-a", clock: SystemClock())
            p.addMember(try Self.member("fake-a", clock))
            try registry.addProvider(p)
            a = p
            gate = nil
        }
    }

    /// AppModelTests' make_member: hourly data from 2 h ago to 72 h ahead at 24 degC.
    static func member(_ source: String, _ clock: ManualClock) throws -> WxMember {
        let now = clock.wallSeconds
        let base = now - now % 3600
        var m = try WxMember(sourceID: source, modelID: "m1", fetchedS: now)
        for i in -2 ..< 72 {
            let added = m.addHour(WxHour(tS: base + Int64(i) * 3600, tempC: 24, feelsC: 26, precipMm: 0,
                                         precipProb: 5, cloudPct: 40, windKmh: 12, gustKmh: 20, humidityPct: 70))
            #expect(added)
        }
        return m
    }

    /// A model over the fixture (not loaded), its log lines kept and its saves recorded.
    func make(saves: SaveLog? = nil) -> AppModel {
        let logs = self.logs
        let m = AppModel(registry: registry, storage: storage, clock: clock, online: true,
                         log: { level, message in logs.lines.append((level, message)) })
        if let saves {
            m.testSaveHook = { kind in saves.kinds.append(kind) }
        }
        model = m
        return m
    }

    @discardableResult
    func start(visible: Bool = false, saves: SaveLog? = nil) async -> AppModel {
        let m = make(saves: saves)
        await m.load()
        if visible {
            m.setVisible(true)
        }
        return m
    }

    /// The shutdown: saves everything dirty and releases the model.
    func stop() async {
        if let m = model {
            #expect(await m.flush())
        }
        model = nil
    }

    @discardableResult
    func restart(saves: SaveLog? = nil) async -> AppModel {
        await stop()
        return await start(saves: saves)
    }

    /// Writes places.json: `units[i]` saved with `places[i]` (nil: no units member, the format
    /// from before per-place units).
    func storePlaces(_ places: [WxPlace], units: [WxUnits?]) throws {
        #expect(places.count == units.count)
        let list = try #require(WxPlaces(path: storage.placesPath))
        for (p, u) in zip(places, units) {
            #expect(list.add(p))
            if let u {
                #expect(list.setUnits(u, forKey: p.key))
            }
        }
        try list.save()
    }

    /// Writes settings.json; `selected` saves the selection too, so the load's autoselect
    /// changes nothing and arms no save.
    func storeSettings(_ units: WxUnits, selected: WxPlace? = nil) throws {
        let s = try #require(WxSettings(path: storage.settingsPath))
        if units != .imperial {
            #expect(s.setUnits(units))
        }
        if let selected {
            #expect(s.setSelected(selected.key))
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

    var placesText: String? {
        FileManager.default.contents(atPath: storage.placesPath).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Advances past the save delay and waits until no save runs and none is armed.
    func flushSaves() async -> Bool {
        await clock.advance(by: (AppModel.saveDelayMs / 1000 + 1) * 1_000_000)
        return await waitUntil { self.model?.savesInFlight == 0 && self.model?.saveTimerArmed == false }
    }
}

private func usPlace(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, admin1: "Florida", country: "United States", countryCode: "US", lat: lat, lon: lon,
                timezone: "America/New_York")
}

private func miami() throws -> WxPlace { try usPlace("Miami", 25.7743, -80.1937) }
private func orlando() throws -> WxPlace { try usPlace("Orlando", 28.5383, -81.3792) }
private func tampa() throws -> WxPlace { try usPlace("Tampa", 27.9475, -82.4584) }

/// Polls `condition` (real time, bounded) while the main actor runs other work.
@MainActor
private func waitUntil(_ timeoutMs: Int = 15_000, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while !condition() {
        if ContinuousClock.now > deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// The units of every item, in list order.
@MainActor
private func itemUnits(_ m: AppModel) -> [WxUnits] {
    m.places.map(\.units)
}

// MARK: - Suite

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UnitsAppModelTests {
    // MARK: Derivation

    // Every item shows its place's saved units, not the default; a change of the saved units is
    // what the item shows at once, and `units` is the selected item's.
    @Test func itemUnitsDeriveFromPlace() async throws {
        let fx = try UnitsFx("derive")
        try fx.storePlaces([try miami(), try orlando()], units: [.imperial, .metric])
        try fx.storeSettings(.metric, selected: try miami())
        let m = await fx.start()
        #expect(m.defaultUnits == .metric)
        #expect(itemUnits(m) == [.imperial, .metric])  // the places', not the default
        #expect(m.selectedKey == (try miami().key) && m.units == .imperial)
        #expect(!m.saveTimerArmed)  // a current places.json loads without a save
        #expect(m.setUnits(.imperial, forKey: try orlando().key))
        #expect(itemUnits(m) == [.imperial, .imperial])
        #expect(m.place(forKey: try orlando().key)?.units == .imperial)
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.imperial, .imperial])
        #expect(try fx.loadSettings().units == .metric)
    }

    // One place's units change: that item only; the others, the selection and the default stay,
    // and its forecast is kept with nothing fetched again.
    @Test func setOnePlaceChangesOnlyIt() async throws {
        let fx = try UnitsFx("set-one")
        try fx.storePlaces([try miami(), try orlando(), try tampa()], units: [.imperial, .imperial, .imperial])
        let m = await fx.start(visible: true)
        #expect(await waitUntil { m.places.allSatisfy { $0.forecast != nil && !$0.loading } })
        let okey = try orlando().key
        m.select(okey)
        let before = m.places
        let started = m.requestsStarted
        let fetches = fx.a?.fetchCount ?? -1
        #expect(m.setUnits(.metric, forKey: okey))
        #expect(itemUnits(m) == [.imperial, .metric, .imperial])
        #expect(m.selectedKey == okey && m.units == .metric && m.defaultUnits == .imperial)
        for (old, new) in zip(before, m.places) {
            #expect(old.key == new.key && old.fetchedS == new.fetchedS && old.loading == new.loading)
            #expect(old.forecast?.generatedS == new.forecast?.generatedS && new.forecast != nil)
            #expect(old.forecast?.hours.count == new.forecast?.hours.count)
        }
        m.toggleUnits()  // the selected place again
        #expect(itemUnits(m) == [.imperial, .imperial, .imperial])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(m.requestsStarted == started && fx.a?.fetchCount == fetches)
        await fx.stop()
    }

    // A units change while the place's request is in flight: the request is neither cancelled
    // nor started again, and its forecast is applied to the item, in the new units.
    @Test func unitsToggleDuringRefreshCompletes() async throws {
        let fx = try UnitsFx("in-flight", gated: true)
        let gate = try #require(fx.gate)
        try fx.storePlaces([try miami()], units: [.imperial])
        let m = await fx.start(visible: true)
        #expect(await waitUntil { gate.held == 1 && m.places.first?.loading == true })
        #expect(m.places.first?.forecast == nil)
        m.toggleUnits()
        #expect(m.places.first?.units == .metric && m.units == .metric)
        #expect(m.setUnits(.imperial, forKey: try miami().key))
        m.toggleUnits()
        #expect(m.places.first?.loading == true && m.requestsInFlight == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(gate.held == 1 && gate.cancelled == 0 && gate.fetches == 1)
        gate.release()
        #expect(await waitUntil { m.places.first?.forecast != nil && m.places.first?.loading == false })
        let item = try #require(m.places.first)
        #expect(item.units == .metric && !item.stale && item.errorText == nil && item.fetchedS != 0)
        #expect(gate.fetches == 1 && gate.cancelled == 0 && m.requestsInFlight == 0)
        await fx.stop()
    }

    // MARK: Migration

    // A places.json from before per-place units: its places take settings.json's units (what the
    // app showed them in); a place that has units keeps them; both files load.
    @Test func migrationTakesSettingsUnits() async throws {
        let fx = try UnitsFx("migrate")
        try fx.storePlaces([try miami(), try orlando(), try tampa()], units: [nil, .imperial, nil])
        try fx.storeSettings(.metric, selected: try miami())
        #expect(fx.placesText?.components(separatedBy: "\"units\"").count == 2)  // only Orlando has units
        let m = await fx.start()
        #expect(fx.logs.warnings.isEmpty)  // nothing failed to load
        #expect(m.places.map(\.place.name) == ["Miami", "Orlando", "Tampa"])
        #expect(m.defaultUnits == .metric)
        #expect(itemUnits(m) == [.metric, .imperial, .metric])
        #expect(m.saveTimerArmed)  // the migrated list is saved
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.count == 3)
        #expect(list.places.map { list.units(forKey: $0.key) } == [.metric, .imperial, .metric])
        #expect(try fx.loadSettings().units == .metric)  // the settings are left as they were
    }

    // The migration is saved once, by the debounced save, without any edit; a relaunch finds
    // every place with units, saves nothing and leaves places.json as it is.
    @Test func migrationSavedOnce() async throws {
        let fx = try UnitsFx("migrate-once")
        try fx.storePlaces([try miami(), try orlando()], units: [nil, nil])
        try fx.storeSettings(.imperial, selected: try miami())
        let saves = SaveLog()
        let m = await fx.start(saves: saves)
        #expect(m.saveTimerArmed)
        #expect(await fx.flushSaves())
        #expect(saves.kinds == [.places])
        let migrated = try #require(fx.placesText)
        #expect(migrated.components(separatedBy: "\"units\": \"imperial\"").count == 3)
        await fx.clock.advance(by: 10 * AppModel.saveDelayMs * 1000)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(saves.kinds == [.places] && !m.saveTimerArmed)
        await fx.stop()
        #expect(saves.kinds == [.places])  // nothing dirty at the shutdown
        // The relaunch is a no-op.
        let again = SaveLog()
        let m2 = await fx.start(saves: again)
        #expect(!m2.saveTimerArmed)
        #expect(itemUnits(m2) == [.imperial, .imperial])
        await fx.stop()
        #expect(again.kinds.isEmpty)
        #expect(fx.placesText == migrated)
    }

    // The units survive relaunches: a migrated place keeps the settings' units of the upgrade
    // even after the default changes; a place set by key keeps its own.
    @Test func relaunchKeepsUnits() async throws {
        let fx = try UnitsFx("relaunch")
        try fx.storePlaces([try miami(), try orlando()], units: [nil, nil])
        try fx.storeSettings(.metric, selected: try miami())
        var m = await fx.start()
        #expect(itemUnits(m) == [.metric, .metric])
        #expect(m.setUnits(.imperial, forKey: try orlando().key))
        m.setDefaultUnits(.imperial)
        #expect(itemUnits(m) == [.metric, .imperial])
        m = await fx.restart()
        #expect(m.defaultUnits == .imperial)
        #expect(itemUnits(m) == [.metric, .imperial])
        await fx.stop()
        let text = fx.placesText
        m = await fx.start()
        #expect(itemUnits(m) == [.metric, .imperial] && m.defaultUnits == .imperial)
        #expect(!m.saveTimerArmed)
        await fx.stop()
        #expect(fx.placesText == text)
    }

    // MARK: Setters

    // setUnits(_:forKey:): true when it changed a place's units (saved in places.json); false for
    // an unknown key, unchanged units, before the load and once shutting down.
    @Test func setUnitsForKey() async throws {
        let fx = try UnitsFx("set-key")
        try fx.storePlaces([try miami(), try orlando()], units: [.imperial, .imperial])
        try fx.storeSettings(.imperial, selected: try miami())
        let early = fx.make()
        #expect(!early.setUnits(.metric, forKey: try miami().key))  // before the load
        await early.load()
        let m = early
        #expect(itemUnits(m) == [.imperial, .imperial])
        #expect(!m.setUnits(.metric, forKey: "1.0000,1.0000"))  // unknown
        #expect(!m.setUnits(.metric, forKey: nil))
        #expect(!m.setUnits(.imperial, forKey: try orlando().key))  // unchanged
        #expect(!m.saveTimerArmed)
        #expect(m.setUnits(.metric, forKey: try orlando().key))
        #expect(m.saveTimerArmed)
        #expect(itemUnits(m) == [.imperial, .metric])
        #expect(m.defaultUnits == .imperial && m.units == .imperial)  // Miami is selected
        #expect(await m.flush())
        #expect(!m.setUnits(.imperial, forKey: try orlando().key))  // shutting down
        #expect(itemUnits(m) == [.imperial, .metric])
        fx.model = nil
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.imperial, .metric])
        #expect(try fx.loadSettings().units == .imperial)
    }

    // setDefaultUnits: persisted in settings.json; saved places keep theirs, places added
    // afterwards get it.
    @Test func defaultUnitsAffectOnlyNewPlaces() async throws {
        let fx = try UnitsFx("default")
        try fx.storePlaces([try miami()], units: [.imperial])
        var m = await fx.start()
        m.setDefaultUnits(.metric)
        #expect(m.defaultUnits == .metric)
        #expect(itemUnits(m) == [.imperial] && m.units == .imperial)  // Miami is selected
        #expect(m.add(try orlando()) == .added)
        #expect(itemUnits(m) == [.imperial, .metric] && m.units == .metric)
        m.setDefaultUnits(.imperial)
        #expect(itemUnits(m) == [.imperial, .metric])
        m.setDefaultUnits(.metric)
        m = await fx.restart()
        #expect(m.defaultUnits == .metric && itemUnits(m) == [.imperial, .metric])
        await fx.stop()
        #expect(try fx.loadSettings().units == .metric)
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.imperial, .metric])
    }

    // toggleUnits(): the selected place's units flip; the other places and the default stay.
    @Test func toggleFlipsSelected() async throws {
        let fx = try UnitsFx("toggle")
        try fx.storePlaces([try miami(), try orlando(), try tampa()], units: [.imperial, .imperial, .metric])
        let m = await fx.start()
        m.select(try orlando().key)
        m.toggleUnits()
        #expect(itemUnits(m) == [.imperial, .metric, .metric] && m.units == .metric)
        #expect(m.defaultUnits == .imperial)
        m.select(try tampa().key)
        m.toggleUnits()
        #expect(itemUnits(m) == [.imperial, .metric, .imperial] && m.units == .imperial)
        m.toggleUnits()
        #expect(itemUnits(m) == [.imperial, .metric, .metric] && m.units == .metric)
        #expect(m.defaultUnits == .imperial)
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.imperial, .metric, .metric])
        #expect(try fx.loadSettings().units == .imperial)
    }

    // With no selection (no place), toggleUnits() flips the default (settings.json), which the
    // next place added gets.
    @Test func toggleWithoutSelectionFlipsDefault() async throws {
        let fx = try UnitsFx("toggle-default")
        let m = await fx.start()
        #expect(m.selectedKey == nil && m.places.isEmpty)
        #expect(m.units == .imperial)
        m.toggleUnits()
        #expect(m.defaultUnits == .metric && m.units == .metric)
        #expect(m.add(try miami()) == .added)
        #expect(itemUnits(m) == [.metric])
        #expect(m.remove(key: try miami().key))
        #expect(m.selectedKey == nil)
        m.toggleUnits()
        #expect(m.defaultUnits == .imperial && m.units == .imperial)
        m.toggleUnits()
        await fx.stop()
        #expect(try fx.loadSettings().units == .metric)
    }

    // With places but no selection (select(nil)), toggleUnits() flips the default too, and no
    // place's units change (U49 panel handoff: the empty list alone cannot tell "the default"
    // from "the first place").
    @Test func toggleWithPlacesButNoSelectionFlipsDefault() async throws {
        let fx = try UnitsFx("toggle-default-places")
        try fx.storePlaces([try miami(), try orlando()], units: [.imperial, .metric])
        let m = await fx.start()
        m.select(nil)
        #expect(m.selectedKey == nil && m.places.count == 2)
        #expect(m.defaultUnits == .imperial && m.units == .imperial)
        m.toggleUnits()
        #expect(m.defaultUnits == .metric && m.units == .metric)
        #expect(itemUnits(m) == [.imperial, .metric])
        m.toggleUnits()
        #expect(m.defaultUnits == .imperial && m.units == .imperial)
        #expect(itemUnits(m) == [.imperial, .metric])
        m.toggleUnits()
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.imperial, .metric])
        #expect(try fx.loadSettings().units == .metric)
    }

    // The members from before per-place units: `units` is the selected place's (else the
    // default), setUnits(_:) sets the selected place's (else the default).
    @Test func legacyMembersActOnSelected() async throws {
        let fx = try UnitsFx("legacy-members")
        try fx.storePlaces([try miami(), try orlando()], units: [.imperial, .metric])
        let m = await fx.start()
        let units: WxUnits = m.units
        let mkey = try miami().key
        #expect(units == .imperial && m.selectedKey == mkey)
        m.select(try orlando().key)
        #expect(m.units == .metric)
        m.setUnits(.imperial)
        #expect(itemUnits(m) == [.imperial, .imperial] && m.defaultUnits == .imperial)
        m.setUnits(.metric)
        #expect(itemUnits(m) == [.imperial, .metric] && m.units == .metric && m.defaultUnits == .imperial)
        m.select(try miami().key)
        m.setUnits(.metric)
        #expect(itemUnits(m) == [.metric, .metric] && m.defaultUnits == .imperial)
        #expect(m.remove(key: mkey))
        #expect(m.remove(key: try orlando().key))
        #expect(m.selectedKey == nil && m.units == .imperial)
        m.setUnits(.metric)  // no selection: the default
        #expect(m.defaultUnits == .metric && m.units == .metric)
        await fx.stop()
        #expect(try fx.loadSettings().units == .metric)
    }

    // MARK: Add paths

    // add(_:units:) saves the units given, else the default units; a refused add changes no
    // place's units.
    @Test func addSavesUnits() async throws {
        let fx = try UnitsFx("add")
        try fx.storeSettings(.imperial)
        let m = await fx.start()
        #expect(m.add(try miami(), units: .metric) == .added)
        #expect(m.selectedKey == (try miami().key) && itemUnits(m) == [.metric] && m.units == .metric)
        #expect(m.add(try orlando()) == .added)  // none given: the default
        #expect(itemUnits(m) == [.metric, .imperial])
        #expect(m.add(try miami(), units: .imperial) == .duplicate)
        #expect(itemUnits(m) == [.metric, .imperial])
        #expect(m.add(try tampa(), units: .imperial) == .added)
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.places.map(\.name) == ["Miami", "Orlando", "Tampa"])
        #expect(list.places.map { list.units(forKey: $0.key) } == [.metric, .imperial, .imperial])
    }

    // addCustomLocation(_:customName:streetAddress:units:) saves the units on both of its paths
    // (a plain place goes through add; a named one under its own, possibly nudged, key).
    @Test func addCustomLocationSavesUnits() async throws {
        let fx = try UnitsFx("add-custom")
        try fx.storeSettings(.imperial)
        let m = await fx.start()
        #expect(m.addCustomLocation(try miami(), customName: "Home", units: .metric) == .added)
        let home = try #require(m.selectedPlace)
        #expect(home.place.isCustomLocation && home.units == .metric)
        // The same coordinate under another name: the key is nudged, the units go with it.
        #expect(m.addCustomLocation(try miami(), customName: "Office", units: .metric) == .added)
        let office = try #require(m.selectedPlace)
        #expect(office.key != home.key && office.units == .metric)
        #expect(m.addCustomLocation(try orlando(), units: .metric) == .added)  // the plain path
        #expect(m.selectedPlace?.place.isCustomLocation == false && m.selectedPlace?.units == .metric)
        #expect(m.addCustomLocation(try tampa(), customName: "Work") == .added)  // none given
        #expect(itemUnits(m) == [.metric, .metric, .metric, .imperial])
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.places.map { list.units(forKey: $0.key) } == [.metric, .metric, .metric, .imperial])
        #expect(list.units(forKey: office.key) == .metric)
    }

    // The first-run page's chip (FirstRunViewModel.addSuggestion -> add) saves exactly the units
    // the page passes (DECISIONS #34): the country preselection of the chip's place (a US chip:
    // imperial, over a metric default), else the user's pick (metric, over the US preselection
    // and an imperial default). Each expected value differs from the default units.
    @Test func firstRunAddSavesUnits() async throws {
        // The preselection.
        let fx = try UnitsFx("first-run")
        try fx.storeSettings(.metric)
        let m = await fx.start()
        let page = FirstRunViewModel(model: m)
        #expect(page.isShown)
        let chip = try #require(page.chips.first)
        #expect(chip.place.countryCode == "US")
        page.highlight(at: 0)
        #expect(page.units == .imperial && !page.isUnitsOverridden)
        #expect(page.addSuggestion(at: 0) == .added)
        #expect(!page.isShown)
        #expect(m.selectedKey == chip.place.key && itemUnits(m) == [.imperial])
        await fx.stop()
        let list = try fx.loadPlaces()
        #expect(list.count == 1 && list.units(forKey: chip.place.key) == .imperial)

        // The user's pick.
        let fx2 = try UnitsFx("first-run-override")
        try fx2.storeSettings(.imperial)
        let m2 = await fx2.start()
        let page2 = FirstRunViewModel(model: m2)
        page2.setUnits(.metric)
        #expect(page2.isShown && page2.isUnitsOverridden)
        #expect(page2.addSuggestion(at: 0) == .added)
        #expect(page2.units == .metric)
        #expect(m2.selectedKey == chip.place.key && itemUnits(m2) == [.metric])
        await fx2.stop()
        let list2 = try fx2.loadPlaces()
        #expect(list2.count == 1 && list2.units(forKey: chip.place.key) == .metric)
    }
}
