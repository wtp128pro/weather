// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AppModel.swift - the application's data owner: a port of the non-GTK part of
// src/ui/wx-app.{h,c} (WxApp) plus the selection rules of the single main
// window (src/ui/wx-window.c: GtkSingleSelection with autoselect, the row
// actions and the "Refresh" enabled state).
//
// AppModel owns the registry of data sources, the forecast service, the three
// stores (places.json, settings.json, forecasts.json), one item per saved place
// (the WxRowItem state: forecast, fetched time, loading, stale, offline, units,
// "now" and the last error text) and the RefreshEngine (U10) that decides when
// to fetch. Everything is main-actor only (wx-app.h:18-32).
//
// Start-up (wx-app.h:34-45, load_thread/load_done wx-app.c:1690-1820): init
// reads nothing and requests nothing; load() reads the three files once on a
// worker thread (a missing file is normal; an unreadable or corrupt one is
// logged and treated as empty), then applies the persisted units and disabled
// providers, builds the items (painted from the cache, with their age), restores
// the persisted selection when that place still exists and gives the places to
// the RefreshEngine. Until load() has finished every state-changing call is
// ignored (/window/app/api-before-load-ignored).
//
// Refreshing (wx-app.h:47-102): the RefreshEngine's fetch(id, key) starts one
// service.refresh(place) task per request; cancel(id) cancels it. Every request
// is reported to RefreshEngine.requestFinished exactly once, AFTER its outcome
// was applied to its item (refresh_done, wx-app.c:991-1014): a forecast replaces
// the item's forecast, clears its error text and goes into the cache (saved,
// debounced); a failure keeps the forecast and records the sanitised message
// (wx_row_item_set_error, wx-row.c:504-516); a cancelled request changes nothing.
// A request AppModel cancelled is reported as .cancelled even when a late
// forecast or error arrives (GTask: a cancelled cancellable makes *_finish
// return G_IO_ERROR_CANCELLED, wx-service.c:1173) - so a late 429 starts no
// cool-down and a late OK does not clear the stale mark. During shutdown no
// outcome is applied to the items.
//
// Persistence (wx-app.h:104-115, wx-app.c:307-578): edits of the places, the
// settings (units, disabled providers, selection) and cache updates arm ONE
// one-shot timer of saveDelayMs (3 s) on the injected clock; later edits do not
// move it. When it fires, every dirty store that is not already being saved is
// saved asynchronously (snapshot on the main actor, write off-main). A failed
// save is logged ("Could not save the %s: %s") and not retried until the next
// edit; a save that finds its store edited meanwhile schedules another one (or
// starts it at once during shutdown). flush(timeout:) is wx_app_shutdown: it
// stops the timers, cancels every request, saves everything dirty and waits,
// at most shutdownWaitMs (5 s), for the saves, the cancelled requests and a
// running load; at the limit it logs "Gave up waiting for pending
// saves/requests after %d ms" and returns false.
//
// Window rules folded in (the macOS app has exactly one window, a SwiftUI
// Window scene, so the GTK window's selection rules belong to the model): the
// persisted selection, else the first place, is selected after the load and
// whenever the list goes from empty to non-empty (gtk_single_selection_set_
// autoselect, wx-window.c:929-930, 1150-1151); removing the selected place
// selects the place now at its position, else the new last one (the
// autoselected neighbour); add(_:) selects the place it added (on_place_added,
// on_suggestion_clicked, wx-window.c:573-587, 646-654). select(_:) keeps the C
// contract: an unknown or invalid key selects nothing (wx-app.h:417-436).
//
// The 50-place cap and the 5 km duplicate rule are WxPlaces' (U12): add(_:)
// calls WxPlaces.add and only classifies a refusal with WxPlaces.maxPlaces and
// WxPlaces.isDuplicate (refusal_message, wx-picker.c:563-575).
//
// Log lines go to os.Logger (subsystem io.github.wtp128pro.Weather, category
// "app") with the C texts; g_warning lines at .warning, g_debug lines at .debug.
// Tests inject a sink instead.

import Dispatch
import Foundation
import Observation
import OSLog

/// The application model (WxApp, src/ui/wx-app.h).
@MainActor
@Observable
public final class AppModel {
    // MARK: - Constants

    /// The application id (WX_APP_ID, wx-app.h:149); also the os.Logger subsystem.
    public nonisolated static let appID = "io.github.wtp128pro.Weather"
    /// A save is started this long after the first unsaved change, milliseconds
    /// (WX_APP_SAVE_DELAY_MS, wx-app.h:151).
    public nonisolated static let saveDelayMs: Int64 = 3000
    /// Upper bound of the wait for pending saves and cancelled requests at exit,
    /// milliseconds (WX_APP_SHUTDOWN_WAIT_MS, wx-app.h:153).
    public nonisolated static let shutdownWaitMs: Int64 = 5000
    /// Longest error text an item keeps, UTF-8 bytes (WX_ROW_ERROR_MAX_BYTES, wx-row.h:57).
    public nonisolated static let errorTextMaxBytes = 200

    // MARK: - Public types

    /// The state of one saved place (the WxRowItem of src/ui/wx-row.h).
    public struct Place: Sendable, Identifiable {
        /// The saved place.
        public let place: WxPlace
        /// `place.key`, the identity of the item.
        public let key: String
        public var id: String { key }
        /// The forecast shown: the latest successful refresh, else the cached one; nil before either.
        public internal(set) var forecast: WxForecast?
        /// When `forecast` was fetched, UTC unix seconds; 0 without a forecast ("Updated N ago").
        public internal(set) var fetchedS: Int64 = 0
        /// A request of the place is in flight ("Updating…").
        public internal(set) var loading = false
        /// The latest completed request of the place failed ("Stale").
        public internal(set) var stale = false
        /// The network is unavailable ("Offline").
        public internal(set) var offline = false
        /// The unit system the item is shown in.
        public internal(set) var units: WxUnits = .imperial
        /// The item's "now", UTC unix seconds (the rain hint and the ages are derived from it).
        public internal(set) var nowS: Int64
        /// The sanitised reason of the latest failed refresh (at most errorTextMaxBytes bytes),
        /// nil after a success or before any failure.
        public internal(set) var errorText: String?
    }

    /// The result of add(_:) (the reasons of refusal_message, wx-picker.c:559-575).
    public enum AddResult: Sendable, Equatable {
        /// The place was saved (and selected).
        case added
        /// The list already holds WxPlaces.maxPlaces places ("You can save up to 50 places").
        case full
        /// The place's key is saved or a saved place is closer than WxPlaces.duplicateKm
        /// ("Already in your places").
        case duplicate
        /// Not added for another reason: the model is not loaded yet or shutting down
        /// ("Could not add this place").
        case failed
    }

    /// One registered data source and its switch.
    public struct Source: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let attribution: String
        public let attributionURL: String
        /// Whether the source takes part in refreshes (the registry's flag).
        public let enabled: Bool
    }

    /// The level of a log line (g_warning / g_debug).
    public enum LogLevel: Sendable, Equatable {
        case warning
        case debug
    }

    /// Receives every log line with its C text.
    public typealias LogSink = @MainActor (LogLevel, String) -> Void

    /// The production sink: os.Logger, subsystem `appID`, category "app".
    public static var systemLog: LogSink {
        let logger = Logger(subsystem: appID, category: "app")
        return { level, message in
            switch level {
            case .warning:
                logger.warning("\(message, privacy: .public)")
            case .debug:
                logger.debug("\(message, privacy: .public)")
            }
        }
    }

    // MARK: - Observed state

    /// One item per saved place, in the places' order (wx_app_get_items).
    public private(set) var places: [Place] = []
    /// The key of the place the detail pane shows, nil for none (wx_app_get_selected).
    public private(set) var selectedKey: String?
    /// The unit system (wx_app_get_units); imperial until the settings are loaded.
    public private(set) var units: WxUnits = .imperial
    /// True while the network is unavailable (wx_app_get_offline).
    public private(set) var isOffline: Bool
    /// The start-up load has finished (C "loaded").
    public private(set) var isLoaded = false
    /// flush(timeout:) has begun (C "shutting_down"): state-changing calls do nothing.
    public private(set) var isShuttingDown = false
    /// The wall time last given to the items by the display clock, UTC unix seconds.
    public private(set) var displayNowS: Int64
    /// Bumped by every change of the registry (provider switch); `sources` reads it.
    private var registryRevision: UInt64 = 0

    // MARK: - Owned objects

    /// The registry of data sources (and the place-search geocoder) (wx_app_get_registry).
    @ObservationIgnored public let registry: WxRegistry
    /// The forecast and place-search service (wx_app_get_service).
    @ObservationIgnored public let service: ServiceOrchestrator
    /// Where the three files live.
    @ObservationIgnored public let storage: AppEnvironment.StorageRoot
    @ObservationIgnored private let clock: any WxClock
    @ObservationIgnored private let log: LogSink
    @ObservationIgnored private var placeList: WxPlaces
    @ObservationIgnored private var settings: WxSettings
    @ObservationIgnored private var cache: WxForecastCache
    @ObservationIgnored private let engine: RefreshEngine
    @ObservationIgnored private let relay: Relay
    @ObservationIgnored private var registryHandler: WxRegistry.ChangeHandlerID?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var focused = false

    /// One in-flight request (Request, wx-app.c:27-32).
    private struct Request {
        let key: String
        var task: Task<Void, Never>?
        /// cancel(id) was called: the request ends as .cancelled whatever it returns.
        var cancelled = false
    }
    @ObservationIgnored private var requests: [UInt64: Request] = [:]

    /// The three files the model writes (SaveKind, wx-app.c:40).
    enum SaveKind: CaseIterable, Sendable {
        case places
        case settings
        case cache

        /// save_name (wx-app.c:397-402).
        var name: String {
            switch self {
            case .places: "places"
            case .settings: "settings"
            case .cache: "cache"
            }
        }
    }
    @ObservationIgnored private var saving: Set<SaveKind> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveToken: UInt64 = 0
    @ObservationIgnored private var drainWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var drainTimers: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var drainToken: UInt64 = 0

    // MARK: - Test seams (reached only through @testable import; nil in production)

    /// Runs before each save starts (the counted-save hook of test-window.c:82-147).
    @ObservationIgnored var testSaveHook: (@MainActor (SaveKind) async -> Void)?
    /// Replaces service.refresh(place) for every request started from now on.
    @ObservationIgnored var testRefresh: (@MainActor (WxPlace) async throws -> WxForecast)?
    /// Number of requests started so far (fetch actions executed).
    @ObservationIgnored private(set) var requestsStarted = 0
    /// Replaces service.search(textBytes:) for every search started from now on.
    @ObservationIgnored var testSearch: (@MainActor ([UInt8]) async throws -> [WxPlace])?
    /// load() waits until its worker has resumed the continuation before awaiting it.
    @ObservationIgnored var testLoadWorkerFirst = false
    /// With testLoadWorkerFirst: runs on the load worker after it resumed the continuation and
    /// before it releases the waiting main actor (e.g. to queue main-actor work in that window).
    @ObservationIgnored var testLoadAfterWorkerResume: (@Sendable () -> Void)?

    /// Forwards the engine's callbacks to the model without a retain cycle.
    @MainActor
    private final class Relay {
        weak var model: AppModel?
    }

    // MARK: - Construction

    /// wx_app_new_with_registry: a model over `registry` (used as is: nothing is added,
    /// removed or replaced), with its own service, the three stores of `storage` (empty:
    /// nothing is read until load()) and a RefreshEngine (window hidden, no place). No
    /// request is made and no timer exists.
    /// - Parameters:
    ///   - registry: the data sources and the geocoder.
    ///   - storage: where places.json, settings.json and forecasts.json live.
    ///   - clock: the only time source (save debounce, shutdown limit, ages, refresh policy).
    ///   - online: whether the network is available now.
    ///   - log: receives the log lines (default: os.Logger).
    public init(registry: WxRegistry, storage: AppEnvironment.StorageRoot, clock: any WxClock = SystemClock(),
                online: Bool = true, log: LogSink? = nil) {
        // wx_app_init (wx-app.c:2319-2326): the empty stores; nothing is read.
        guard let placeList = WxPlaces(path: storage.placesPath),
              let settings = WxSettings(path: storage.settingsPath),
              let cache = WxForecastCache(path: storage.cachePath, clock: clock)
        else {
            preconditionFailure("AppModel: a storage path is empty")  // unreachable: defaultPath is never ""
        }
        self.placeList = placeList
        self.settings = settings
        self.cache = cache
        // wx_app_constructed (wx-app.c:2134-2140): the registry, then the service on it.
        self.registry = registry
        self.service = ServiceOrchestrator(registry: registry, clock: clock)
        self.storage = storage
        self.clock = clock
        self.log = log ?? Self.systemLog
        self.isOffline = !online
        self.displayNowS = clock.wallSeconds
        let relay = Relay()
        self.relay = relay
        // wx_app_startup: the scheduler is told the network state (wx-app.c:1922-1925).
        self.engine = RefreshEngine(
            clock: clock, online: online,
            fetch: { [relay] id, key in relay.model?.startRequest(id: id, key: key) },
            cancel: { [relay] id in relay.model?.cancelRequest(id: id) },
            display: { [relay] nowS in relay.model?.tickItems(nowS) },
            stateChanged: { [relay] key in relay.model?.engineStateChanged(key) })
        relay.model = self
        registryHandler = registry.addChangeHandler { [relay] in
            relay.model?.registryRevision &+= 1
        }
    }

    isolated deinit {
        // wx_app_dispose (wx-app.c:2202-2225): timers removed, requests cancelled and
        // abandoned; pending saves finish on their own and only free themselves.
        saveTask?.cancel()
        for timer in drainTimers.values {
            timer.cancel()
        }
        for request in requests.values {
            request.task?.cancel()
        }
        engine.shutdown()
        if let registryHandler {
            registry.removeChangeHandler(registryHandler)
        }
    }

    // MARK: - Start-up load

    /// The start-up load (startup + load_thread + load_done, wx-app.c:1690-1820, 1917-1931):
    /// reads the three files on a worker thread, logs what could not be read, applies the
    /// settings, builds the items from the places and the cache, restores the selection (else
    /// selects the first place) and gives the places to the RefreshEngine. Does nothing when
    /// already loaded or loading, or once flush(timeout:) has begun. Makes no request by
    /// itself (the engine fetches once the window is visible and the network available).
    public func load() async {
        guard !isLoaded, !loading, !isShuttingDown else {
            return
        }
        loading = true
        let paths = (storage.placesPath, storage.settingsPath, storage.cachePath)
        let clock = self.clock
        let workerFirst = testLoadWorkerFirst
        let afterResume = workerFirst ? testLoadAfterWorkerResume : nil
        let outcome: LoadOutcome = await withCheckedContinuation { continuation in
            let resumed = workerFirst ? DispatchSemaphore(value: 0) : nil
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.loadFiles(paths, clock: clock))
                afterResume?()
                resumed?.signal()
            }
            // Test seam only: wait until the worker has resumed the continuation, so the await
            // below finds the result ready and does not suspend (an order the scheduler can produce).
            resumed?.wait()
        }
        // load_done is a GTask callback, always dispatched by a later main-loop iteration
        // (wx-app.c:1914-1931): a continuation resumed before it is awaited does not suspend, so
        // yield once - a flush(timeout:) requested in the same turn is then always seen first.
        await Task.yield()
        loadDone(outcome)
    }

    /// What load_thread hands to the main thread (LoadResult, wx-app.c:1666-1671).
    private struct LoadOutcome {
        let places: WxPlaces?
        let settings: WxSettings?
        let cache: WxForecastCache?
        var dropped = 0
        var placesError: String?
        var settingsError: String?
        var cacheError: String?
    }

    /// load_thread (wx-app.c:1690-1713): fresh stores read on the worker; a missing file
    /// (isNotFound) is not an error.
    private nonisolated static func loadFiles(_ paths: (String, String, String), clock: any WxClock) -> LoadOutcome {
        let places = WxPlaces(path: paths.0)
        let settings = WxSettings(path: paths.1)
        let cache = WxForecastCache(path: paths.2, clock: clock)
        var outcome = LoadOutcome(places: places, settings: settings, cache: cache)
        do {
            outcome.dropped = try places?.load() ?? 0
        } catch {
            if !error.isNotFound {
                outcome.placesError = error.message
            }
        }
        do {
            try settings?.load()
        } catch {
            if !error.isNotFound {
                outcome.settingsError = error.message
            }
        }
        do {
            try cache?.load()
        } catch {
            if !error.isNotFound {
                outcome.cacheError = error.message
            }
        }
        return outcome
    }

    /// load_done (wx-app.c:1777-1820).
    private func loadDone(_ r: LoadOutcome) {
        loading = false
        if let message = r.placesError {
            log(.warning, "Could not read the saved places (starting empty): \(message)")
        }
        if r.dropped > 0 {
            log(.warning, "\(r.dropped) invalid saved places were dropped")
        }
        if let message = r.settingsError {
            log(.warning, "Could not read the settings (using defaults): \(message)")
        }
        if let message = r.cacheError {
            log(.warning, "Could not read the forecast cache (starting empty): \(message)")
        }
        if let places = r.places, let settings = r.settings, let cache = r.cache {
            placeList = places
            self.settings = settings
            self.cache = cache
        }
        if isShuttingDown {
            drainProgress()
            return
        }
        log(.debug, "loaded \(placeList.count) places")
        isLoaded = true
        applySettings()
        placeList.onChanged = { [relay] in
            MainActor.assumeIsolated { relay.model?.placesChanged() }
        }
        syncItems()
        // The persisted selection when that place still exists (wx-app.c:1808-1812).
        if let sel = settings.selected, let i = itemIndex(sel) {
            selectedKey = places[i].key
        }
        engine.setPlaces(places.map(\.key))
        if let selectedKey {
            engine.select(selectedKey)
        }
        // The window's autoselect: the first row when nothing is selected (wx-window.c:1150).
        if selectedKey == nil, let first = places.first {
            selectInternal(first.key)
        }
    }

    /// apply_settings (wx-app.c:1740-1755).
    private func applySettings() {
        if settings.units != units {
            units = settings.units
        }
        for provider in registry.listProviders() {
            registry.setEnabled(!settings.isProviderDisabled(provider.id), id: provider.id)
        }
    }

    // MARK: - Items

    /// The index of the item whose key equals `key` read as a C string (lookup_item).
    private func itemIndex(_ key: String?) -> Int? {
        guard let bytes = WxPlaces.keyBytes(key) else {
            return nil
        }
        return places.firstIndex { Array($0.key.utf8) == bytes }
    }

    /// The item of a place, nil for an unknown key.
    public func place(forKey key: String?) -> Place? {
        itemIndex(key).map { places[$0] }
    }

    /// The selected place's item, nil for none.
    public var selectedPlace: Place? {
        place(forKey: selectedKey)
    }

    /// sync_items (wx-app.c:682-734): one item per place in list order; a new item is
    /// painted from the cache; the items of removed places are dropped and their forecasts
    /// leave the cache (which schedules a save).
    private func syncItems() {
        let old = Dictionary(places.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Place] = []
        next.reserveCapacity(placeList.count)
        for place in placeList.places {
            let key = place.key
            if let item = old[key] {
                next.append(item)
                continue
            }
            var item = Place(place: place, key: key, nowS: clock.wallSeconds)
            item.units = units
            item.offline = isOffline
            applyCache(&item)
            next.append(item)
        }
        let kept = Set(next.map(\.key))
        places = next
        for key in old.keys where !kept.contains(key) {
            if cache.remove(key: key) {
                scheduleSave()
            }
        }
    }

    /// apply_cache (wx-app.c:600-607): the cached forecast with fetched time now minus its age.
    private func applyCache(_ item: inout Place) {
        guard let hit = cache.get(key: item.key) else {
            return
        }
        item.forecast = hit.forecast
        item.fetchedS = clock.wallSeconds - hit.ageMs / 1000
    }

    /// on_places_changed (wx-app.c:1306-1318) with the window's selection rules.
    private func placesChanged() {
        guard isLoaded else {
            return
        }
        let oldKeys = places.map(\.key)
        let oldSelection = selectedKey
        syncItems()
        // GtkSingleSelection (autoselect, cannot unselect): the selected row was removed, so the
        // row now at its position, else the last one, is selected - inside the splice, before
        // the scheduler is given the new places.
        if let sel = oldSelection, itemIndex(sel) == nil, !places.isEmpty,
           let oldIndex = oldKeys.firstIndex(of: sel) {
            selectInternal(places[min(oldIndex, places.count - 1)].key)
        }
        engine.setPlaces(places.map(\.key))
        if let sel = selectedKey, itemIndex(sel) == nil {
            selectedKey = nil
            settings.setSelected(nil)
        }
        // Autoselect: the list was empty and is not any more.
        if selectedKey == nil, let first = places.first {
            selectInternal(first.key)
        }
        scheduleSave()
    }

    /// tick_items (wx-app.c:1371-1379): every item gets the current wall time.
    private func tickItems(_ nowS: Int64) {
        displayNowS = nowS
        for i in places.indices where places[i].nowS != nowS {
            places[i].nowS = nowS
        }
    }

    /// The engine changed the loading or stale state of `key` (wx_row_item_set_loading/_stale).
    private func engineStateChanged(_ key: String) {
        guard let i = itemIndex(key), let state = engine.state(of: key) else {
            return
        }
        if places[i].loading != state.loading {
            places[i].loading = state.loading
        }
        if places[i].stale != state.stale {
            places[i].stale = state.stale
        }
    }

    // MARK: - Places

    /// Whether add(place) would save the place, and if not why (it changes nothing).
    public func checkAdd(_ place: WxPlace) -> AddResult {
        guard isLoaded, !isShuttingDown else {
            return .failed
        }
        if placeList.canAdd(place) {
            return .added
        }
        return refusal(for: place)
    }

    /// Saves `place` at the end of the list (WxPlaces.add: the 50-place cap and the 5 km rule)
    /// and selects it (the picker's and the suggestion's add, wx-window.c:573-587, 646-654).
    public func add(_ place: WxPlace) -> AddResult {
        guard isLoaded, !isShuttingDown else {
            return .failed
        }
        guard placeList.add(place) else {
            return refusal(for: place)
        }
        selectInternal(place.key)
        return .added
    }

    /// refusal_message (wx-picker.c:563-575) on the list as it is now.
    private func refusal(for place: WxPlace) -> AddResult {
        if placeList.count >= WxPlaces.maxPlaces {
            return .full
        }
        if placeList.index(ofKey: place.key) != nil
            || placeList.places.contains(where: { WxPlaces.isDuplicate($0, place) }) {
            return .duplicate
        }
        return .failed
    }

    /// Whether a place with that key is saved (the picker's "Added" mark).
    public func isSaved(key: String?) -> Bool {
        placeList.index(ofKey: key) != nil
    }

    /// Removes the place with that key (the row's Remove, on_row_remove, wx-window.c:750-754).
    /// False when no saved place has that key.
    @discardableResult
    public func remove(key: String?) -> Bool {
        guard isLoaded, !isShuttingDown else {
            return false
        }
        return placeList.remove(key: key)
    }

    /// Moves the place at `from` to `to` (WxPlaces.move). False when an index is out of range
    /// or `from == to`.
    @discardableResult
    public func move(from: Int, to: Int) -> Bool {
        guard isLoaded, !isShuttingDown else {
            return false
        }
        return placeList.move(from: from, to: to)
    }

    /// Moves the place with that key by `delta` positions (on_row_move, wx-window.c:776-786):
    /// nothing happens for an unknown key or a target outside the list (no overflow).
    @discardableResult
    public func move(key: String?, by delta: Int) -> Bool {
        guard isLoaded, !isShuttingDown, let from = placeList.index(ofKey: key) else {
            return false
        }
        let (to, overflow) = from.addingReportingOverflow(delta)
        guard !overflow, to >= 0, to < placeList.count else {
            return false
        }
        return placeList.move(from: from, to: to)
    }

    /// The row's "Move up" (delta -1).
    @discardableResult
    public func moveUp(key: String?) -> Bool {
        move(key: key, by: -1)
    }

    /// The row's "Move down" (delta +1).
    @discardableResult
    public func moveDown(key: String?) -> Bool {
        move(key: key, by: 1)
    }

    /// A drop of the UNTRUSTED text `source` on the row of `target` (on_row_reorder,
    /// wx-window.c:809-817): when both are keys of saved places, the source place moves to the
    /// target's position; otherwise nothing changes. Neither text is stored.
    @discardableResult
    public func moveKey(_ source: String?, onto target: String?) -> Bool {
        guard isLoaded, !isShuttingDown,
              let from = placeList.index(ofKey: source), let to = placeList.index(ofKey: target)
        else {
            return false
        }
        return placeList.move(from: from, to: to)
    }

    // MARK: - Selection

    /// wx_app_select (wx-app.c:1595-1613): the place the detail pane shows; it is fetched
    /// first and the choice is saved (debounced). An unknown or invalid key (or nil) selects
    /// nothing. Ignored before the load and once shutting down.
    public func select(_ key: String?) {
        guard !isShuttingDown, isLoaded else {
            return
        }
        selectInternal(key)
    }

    private func selectInternal(_ key: String?) {
        let newKey = itemIndex(key).map { places[$0].key }
        guard newKey != selectedKey else {
            return
        }
        selectedKey = newKey
        log(.debug, "select \(newKey ?? "(none)")")
        if settings.setSelected(newKey) {
            scheduleSave()
        }
        engine.select(newKey)
    }

    // MARK: - Units

    /// wx_app_set_units (wx-app.c:1538-1553): every item gets the units, the settings store
    /// them and a save is scheduled; nothing happens when unchanged, before the load or once
    /// shutting down.
    public func setUnits(_ units: WxUnits) {
        guard !isShuttingDown, isLoaded, self.units != units else {
            return
        }
        self.units = units
        settings.setUnits(units)
        for i in places.indices {
            places[i].units = units
        }
        scheduleSave()
    }

    /// The window's "toggle-units" action (Ctrl+U / ⌘U).
    public func toggleUnits() {
        setUnits(units == .imperial ? .metric : .imperial)
    }

    // MARK: - Sources

    /// The registered data sources in registration order with their switches.
    public var sources: [Source] {
        _ = registryRevision
        return registry.listProviders().map {
            Source(id: $0.id, name: $0.name, attribution: $0.attribution, attributionURL: $0.attributionURL,
                   enabled: registry.isEnabled(id: $0.id))
        }
    }

    /// Whether the provider takes part in refreshes.
    public func isProviderEnabled(_ id: String) -> Bool {
        _ = registryRevision
        return registry.isEnabled(id: id)
    }

    /// wx_app_set_provider_enabled (wx-app.c:1632-1655): flips the registry, stores the choice
    /// (saved, debounced) and asks every place again once, as soon as it is allowed. An unknown
    /// id or an unchanged flag changes nothing; ignored before the load and once shutting down.
    public func setProviderEnabled(_ id: String, _ enabled: Bool) {
        guard !isShuttingDown, isLoaded else {
            return
        }
        guard registry.findProvider(id: id) != nil, registry.isEnabled(id: id) != enabled else {
            return
        }
        registry.setEnabled(enabled, id: id)
        settings.setProviderDisabled(id, !enabled)
        scheduleSave()
        engine.sourcesChanged()
    }

    /// The per-source statuses of the selected place's forecast (registration order), empty
    /// without a selected place or forecast.
    public var selectedSourceStatuses: [WxSourceStatus] {
        selectedPlace?.forecast?.sources ?? []
    }

    /// The status of one source for the selected place, nil when it has none.
    public func selectedSourceStatus(providerID: String) -> WxSourceStatus? {
        selectedSourceStatuses.first { $0.providerID == providerID }
    }

    // MARK: - Place search

    /// The place search of the picker (wx_service_search_async): at most 20 places. A caller
    /// whose task is cancelled before this returns gets CancellationError, also when the hits
    /// were ready (GTask; re-checked after the await resumes, DECISIONS #50).
    public func search(_ text: String) async throws -> [WxPlace] {
        try await search(textBytes: Array(text.utf8))
    }

    /// The place search on the raw bytes of a C string.
    public func search(textBytes: [UInt8]) async throws -> [WxPlace] {
        let search: @MainActor ([UInt8]) async throws -> [WxPlace] = testSearch ?? { [service] bytes in
            try await service.search(textBytes: bytes)
        }
        let hits = try await search(textBytes)
        if Task.isCancelled {
            throw CancellationError()
        }
        return hits
    }

    // MARK: - Window and network

    /// wx_app_set_window_visible (wx-app.c:1557-1571): the main window is on screen (mapped,
    /// not minimised, not hidden). Becoming visible starts a refresh round and the display
    /// clock (while online); becoming hidden cancels every request and stops the clock.
    public func setVisible(_ visible: Bool) {
        guard !isShuttingDown else {
            return
        }
        log(.debug, "window visible=\(visible ? 1 : 0)")
        engine.setVisible(visible)
    }

    /// The main window's active state (on_active_changed, wx-window.c:265-269): becoming the
    /// active window is wx_app_window_focused (wx-app.c:1574-1582).
    public func setFocused(_ focused: Bool) {
        guard !isShuttingDown else {
            return
        }
        let became = focused && !self.focused
        self.focused = focused
        if became {
            log(.debug, "window focused")
            engine.windowFocused()
        }
    }

    /// The network monitor's report (set_offline, wx-app.c:1352-1367): every item is marked,
    /// the items get the current time, and the engine resumes or cancels.
    public func setOnline(_ online: Bool) {
        let offline = !online
        guard isOffline != offline else {
            return
        }
        isOffline = offline
        for i in places.indices {
            places[i].offline = offline
        }
        engine.setOnline(online)
    }

    /// The Refresh action's enabled state (update_refresh, wx-window.c:319-324): a selected
    /// place that is not loading while the network is available. Visibility is NOT part of it.
    public var isRefreshEnabled: Bool {
        guard isLoaded, let place = selectedPlace else {
            return false
        }
        return !place.loading && !isOffline
    }

    /// wx_app_refresh_selected (wx-app.c:1616-1628): fetches the selected place again now
    /// unless it is loading, was started or succeeded less than 10 s ago or hit a rate limit
    /// less than 60 s ago (then the call is dropped), or the window is hidden or offline.
    public func refresh() {
        guard isLoaded, selectedKey != nil else {
            return
        }
        engine.refreshSelected()
    }

    // MARK: - Requests

    /// The engine's FETCH (run_action, wx-app.c:1040-1072).
    private func startRequest(id: UInt64, key: String) {
        guard !isShuttingDown, let i = itemIndex(key) else {
            // Cannot happen (the engine tracks exactly the items' keys and is hidden before
            // shutdown); the id is still reported once, outside the engine's action loop.
            Task { @MainActor [relay] in
                relay.model?.engine.requestFinished(id: id, result: .cancelled)
            }
            return
        }
        let place = places[i].place
        log(.debug, "request #\(id) \(key)")
        requestsStarted += 1
        let refresh: @MainActor (WxPlace) async throws -> WxForecast = testRefresh ?? { [service] place in
            try await service.refresh(place)
        }
        requests[id] = Request(key: key)
        let task = Task { @MainActor [relay] in
            let result: Result<WxForecast, any Error>
            do {
                result = .success(try await refresh(place))
            } catch {
                result = .failure(error)
            }
            relay.model?.refreshDone(id: id, result: result)
        }
        if requests[id] != nil {
            requests[id]?.task = task
        }
    }

    /// The engine's CANCEL (run_action, wx-app.c:1044-1052).
    private func cancelRequest(id: UInt64) {
        guard requests[id] != nil else {
            return
        }
        log(.debug, "cancel #\(id)")
        requests[id]?.cancelled = true
        requests[id]?.task?.cancel()
    }

    /// refresh_done + outcome (wx-app.c:870-878, 991-1014): applies the outcome to the item
    /// (not while shutting down), then reports the request to the engine.
    private func refreshDone(id: UInt64, result: Result<WxForecast, any Error>) {
        guard let request = requests.removeValue(forKey: id) else {
            return
        }
        let key = request.key
        var completion: RefreshEngine.Completion
        var forecast: WxForecast?
        var failure: String?
        switch result {
        case .success(let f):
            completion = .ok
            forecast = f
        case .failure(let error as WxError):
            completion = .failed(error)
            failure = error.message
        case .failure(is CancellationError):
            completion = .cancelled
        case .failure:
            completion = .failed(nil)
            failure = "unknown error"
        }
        if request.cancelled {
            // GTask: a cancelled request finishes CANCELLED whatever its operation returned. The
            // token is re-read here, after the await resumed: a cancel that lands after the service
            // completed (its no-covering path returns without suspending, DECISIONS #50) still wins.
            completion = .cancelled
            forecast = nil
            failure = nil
        }
        if let failure {
            log(.debug, "refresh \(key) failed: \(failure)")
        }
        if !isShuttingDown {
            if let forecast {
                applyForecast(key: key, forecast)
            } else if let failure, let i = itemIndex(key) {
                setErrorText(i, failure)
            }
        }
        engine.requestFinished(id: id, result: completion)
        drainProgress()
    }

    /// apply_forecast (wx-app.c:955-966): into the cache (saved, debounced; a forecast the
    /// cache refuses is still shown), then the item: no error, the forecast, fetched now.
    private func applyForecast(key: String, _ forecast: WxForecast) {
        guard let i = itemIndex(key) else {
            return  // a removed place's request is cancelled first
        }
        if cache.put(forecast, fetchedAtMs: clock.wallMilliseconds) {
            scheduleSave()
        }
        setErrorText(i, nil)
        places[i].forecast = forecast
        places[i].fetchedS = clock.wallSeconds
    }

    /// wx_row_item_set_error (wx-row.c:504-516): sanitised, at most errorTextMaxBytes bytes;
    /// an empty result counts as none.
    private func setErrorText(_ i: Int, _ message: String?) {
        let clean = message.map { WxText.sanitize($0, maxBytes: Self.errorTextMaxBytes) }
        let text = clean?.isEmpty == false ? clean : nil
        if places[i].errorText != text {
            places[i].errorText = text
        }
    }

    // MARK: - Persistence

    /// is_dirty (wx-app.c:421-434).
    private func isDirty(_ kind: SaveKind) -> Bool {
        switch kind {
        case .places: placeList.isDirty
        case .settings: settings.isDirty
        case .cache: cache.isDirty
        }
    }

    /// schedule_save (wx-app.c:573-578): arms the one-shot debounce timer unless it is armed
    /// or the model is shutting down; later changes do not move it.
    private func scheduleSave() {
        guard saveTask == nil, !isShuttingDown else {
            return
        }
        saveToken &+= 1
        let token = saveToken
        let deadline = clock.monotonicMicroseconds + Self.saveDelayMs * 1000
        let clock = self.clock
        saveTask = Task.immediate { @MainActor [relay] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            relay.model?.saveTimeout(token: token)
        }
    }

    /// save_timeout (wx-app.c:550-557).
    private func saveTimeout(token: UInt64) {
        guard token == saveToken, saveTask != nil else {
            return
        }
        saveTask = nil
        startSaves()
    }

    /// start_saves (wx-app.c:511-532): every dirty store with no save running is saved
    /// asynchronously; the snapshot is taken now, on the main actor.
    private func startSaves() {
        for kind in SaveKind.allCases where isDirty(kind) && !saving.contains(kind) {
            saving.insert(kind)
            let hook = testSaveHook
            let log = self.log
            let places = placeList
            let settings = self.settings
            let cache = self.cache
            Task.immediate { @MainActor [relay] in
                if let hook {
                    await hook(kind)
                }
                var failure: String?
                do throws(WxStoreError) {
                    switch kind {
                    case .places: try await places.saveAsync()
                    case .settings: try await settings.saveAsync()
                    case .cache: try await cache.saveAsync()
                    }
                } catch {
                    failure = error.message
                }
                // save_done (wx-app.c:460-492): the failure is logged even when the model is gone.
                if let failure {
                    log(.warning, "Could not save the \(kind.name): \(failure)")
                }
                relay.model?.saveDone(kind, saved: failure == nil)
            }
        }
    }

    /// The model's part of save_done (wx-app.c:486-491).
    private func saveDone(_ kind: SaveKind, saved: Bool) {
        saving.remove(kind)
        if saved && isDirty(kind) {  // edited while writing
            if isShuttingDown {
                startSaves()
            } else {
                scheduleSave()
            }
        }
        drainProgress()
    }

    /// pending_io (wx-app.c:322-327): the load, a save or a request is still pending.
    private var pendingIO: Bool {
        loading || !saving.isEmpty || !requests.isEmpty
    }

    /// drain_progress (wx-app.c:343-348): ends every flush wait once nothing is pending.
    private func drainProgress() {
        guard !pendingIO, !drainWaiters.isEmpty else {
            return
        }
        let waiters = drainWaiters
        drainWaiters = [:]
        for timer in drainTimers.values {
            timer.cancel()
        }
        drainTimers = [:]
        for waiter in waiters.values {
            waiter.resume(returning: true)
        }
    }

    /// wx_app_shutdown (wx-app.c:2009-2040): from now on every state-changing call does
    /// nothing; the save timer and the display clock stop, every request in flight is
    /// cancelled, everything dirty is saved, and the call waits until the saves, the cancelled
    /// requests and a running load have finished, or for at most `timeout` seconds (clamped to
    /// [0, shutdownWaitMs / 1000]) on the model's clock. Calling it again only waits again.
    /// - Returns: true when nothing was left pending; false when it stopped waiting at the
    ///   limit (logged "Gave up waiting for pending saves/requests after <ms> ms"); the
    ///   abandoned saves still finish and write their files.
    @discardableResult
    public func flush(timeout: TimeInterval = TimeInterval(AppModel.shutdownWaitMs) / 1000) async -> Bool {
        if !isShuttingDown {
            isShuttingDown = true
            log(.debug, "shutdown: saving and waiting for \(requests.count) request(s)")
            saveTask?.cancel()
            saveTask = nil
            engine.shutdown()
            if isLoaded {
                startSaves()
            }
        }
        guard pendingIO else {
            return true
        }
        let limitMs: Int64
        if timeout.isNaN || timeout <= 0 {
            limitMs = 0
        } else if timeout * 1000 >= Double(Self.shutdownWaitMs) {
            limitMs = Self.shutdownWaitMs
        } else {
            limitMs = Int64(timeout * 1000)
        }
        drainToken &+= 1
        let token = drainToken
        let deadline = clock.monotonicMicroseconds + limitMs * 1000
        let clock = self.clock
        return await withCheckedContinuation { continuation in
            drainWaiters[token] = continuation
            drainTimers[token] = Task.immediate { @MainActor [relay] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                relay.model?.drainTimedOut(token: token, limitMs: limitMs)
            }
        }
    }

    /// drain_timeout (wx-app.c:1999-2006).
    private func drainTimedOut(token: UInt64, limitMs: Int64) {
        drainTimers[token] = nil
        guard let waiter = drainWaiters.removeValue(forKey: token) else {
            return
        }
        log(.warning, "Gave up waiting for pending saves/requests after \(limitMs) ms")
        waiter.resume(returning: false)
    }

    // MARK: - Internal views for tests

    /// The RefreshEngine (read-only use in tests).
    var refreshEngine: RefreshEngine { engine }
    /// Requests started and not yet finished.
    var requestsInFlight: Int { requests.count }
    /// Saves running now.
    var savesInFlight: Int { saving.count }
    /// Whether the save debounce timer is armed.
    var saveTimerArmed: Bool { saveTask != nil }
}
