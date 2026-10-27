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
// logged and treated as empty), then applies the persisted default units and
// disabled providers, gives every place saved without units the settings' units
// (once: the migration of a places.json from before per-place units, saved like
// any edit), builds the items (painted from the cache, with their age), restores
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
// Alerts (no C counterpart; DECISIONS #41): each item carries its official
// alerts, exactly what the alerts service (AlertsService in the app, injected;
// an inert one that never requests anything and reports every place not
// fetched when none is given) reports for the place. When a request of a place
// completes - a forecast or a failure, not a cancelled request - and only after
// it was applied and reported to the engine, the service's refresh(place) is
// kicked and never awaited, unless the network is down or shutdown has begun:
// alert sources are asked exactly as often as the forecast is refreshed, and
// whatever they do (fail, hang) cannot reach the forecast path. Every item's
// state is re-read from the service when a kick's result lands (only the
// place's newest kick counts), on every display tick, whenever the items are
// rebuilt (syncItems), at once when the window becomes visible and at once when
// the system clock is set (NSSystemClockDidChange, DECISIONS #43 b); and,
// while the window is visible (online or offline: the display clock stops
// offline), by a wake-up on the injected clock at the earliest upcoming alert
// expiry or end of a source window among the items, but never more than
// alertWakeMaxS (60 s, the display clock's period) away, so a system sleep or
// a clock change is caught up within it (#43 a).
// The answer time is whole seconds (WxAlertsResult.fetchedS), so a window ends
// somewhere in the second after fetchedS + window: the wake-up re-reads at its
// start, then every alertWindowStepUS (10 ms) until the set reads stale.
// Every re-read re-arms the wake-up (#43 c); it fetches nothing. A removed
// place's alert work is cancelled and forgotten (a late result is dropped);
// shutdown cancels it all (AlertsService.cancelAll, at shutdown only) and
// writes no alert state any more; flush neither waits for nor reports alert
// work; a units change touches none of it.
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
// Units: every place keeps its own unit system in places.json (WxPlaces
// units(forKey:)); an item's units are always derived from it (else the default
// units) by syncItems, so a units change is an edit of the list that changes one
// item and never touches its forecast or its requests. settings.json "units" is
// the default given to places added later (setDefaultUnits); units, setUnits(_:)
// and toggleUnits() act on the selected place, else on the default.
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
    /// The longest the alert wake-up sleeps while the window is visible, seconds: the display
    /// clock's period, so the items follow a system sleep or a clock change offline as soon as
    /// they would online (DECISIONS #43 a). A re-read, never a fetch.
    static let alertWakeMaxS = RefreshEngine.clockTickS
    /// The step of the alert re-reads within the second a current set's window ends in,
    /// microseconds (10 ms): fetchedS is whole seconds, so that is as late as the item can turn
    /// stale after the service did.
    static let alertWindowStepUS: Int64 = 10_000

    // MARK: - Public types

    /// The state of one saved place (the WxRowItem of src/ui/wx-row.h).
    public struct Place: Sendable, Identifiable {
        /// The saved place.
        public let place: WxPlace
        /// `place.key`, the identity of the item.
        public let key: String
        public var id: String { key }
        /// The forecast shown: the latest successful refresh, else the cached one; nil before either.
        /// The blend corrected by the place's learned local bias (WxLocalBias), if any.
        public internal(set) var forecast: WxForecast?
        /// The same forecast as blended, before the local bias correction (what the bias is learned on).
        public internal(set) var modelForecast: WxForecast?
        /// When `forecast` was fetched, UTC unix seconds; 0 without a forecast ("Updated N ago").
        public internal(set) var fetchedS: Int64 = 0
        /// A request of the place is in flight ("Updating…").
        public internal(set) var loading = false
        /// The latest completed request of the place failed ("Stale").
        public internal(set) var stale = false
        /// The network is unavailable ("Offline").
        public internal(set) var offline = false
        /// The unit system the item is shown in: the place's saved units, else the default units
        /// (set by syncItems only, from WxPlaces.units(forKey:)).
        public internal(set) var units: WxUnits = .imperial
        /// The item's "now", UTC unix seconds (the rain hint and the ages are derived from it).
        public internal(set) var nowS: Int64
        /// The sanitised reason of the latest failed refresh (at most errorTextMaxBytes bytes),
        /// nil after a success or before any failure.
        public internal(set) var errorText: String?
        /// The place's official alerts as the alerts service reports them now (not fetched,
        /// current, stale, unavailable or not covered; the alerts still current and when they
        /// were fetched). Never invented here: always the service's result(for:) of the place.
        public internal(set) var alerts = AppModel.alertsNotFetched
    }

    /// The alert state of a place nothing has been asked about yet.
    public nonisolated static let alertsNotFetched = WxAlertsResult(state: .notFetched, source: nil, alerts: [],
                                                                    fetchedS: nil)

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
    /// The unit system new places get (settings.json "units"; wx_app_get_units); imperial until
    /// the settings are loaded. Saved places keep their own.
    public private(set) var defaultUnits: WxUnits = .imperial
    /// The selected place's unit system, else the default units (the toolbar's °F/°C, ⌘U). A
    /// mirror written by syncUnits() only when its value changes, so its observers hear of a
    /// units change and of nothing else (/window/app/properties).
    public private(set) var units: WxUnits = .imperial
    /// True while the network is unavailable (wx_app_get_offline).
    public private(set) var isOffline: Bool
    /// The start-up load has finished (C "loaded").
    public private(set) var isLoaded = false
    /// flush(timeout:) has begun (C "shutting_down"): state-changing calls do nothing.
    public private(set) var isShuttingDown = false
    /// The wall time last given to the items by the display clock, UTC unix seconds.
    public private(set) var displayNowS: Int64
    /// User-configurable source and model weight multipliers for blending.
    public private(set) var weightMultipliers = WxWeightMultipliers()
    /// The station-layer preferences (learned corrections on/off, networks turned off).
    public private(set) var stationSettings = WxStationSettings()
    /// Bumped by every change of the learned local corrections; `localCorrections` reads it.
    public private(set) var localBiasRevision: UInt64 = 0
    /// Bumped by every change of the registry (provider switch); `sources` reads it.
    private var registryRevision: UInt64 = 0

    // MARK: - Owned objects

    /// The registry of data sources (and the place-search geocoder) (wx_app_get_registry).
    @ObservationIgnored public let registry: WxRegistry
    /// The forecast and place-search service (wx_app_get_service).
    @ObservationIgnored public let service: ServiceOrchestrator
    /// Where the three files live.
    @ObservationIgnored public let storage: AppEnvironment.StorageRoot
    /// The places' official alerts (AlertsService in the app; inert when none was injected).
    @ObservationIgnored public let alertsService: any WxAlertsServing
    @ObservationIgnored private let clock: any WxClock
    @ObservationIgnored private let log: LogSink
    @ObservationIgnored private var placeList: WxPlaces
    @ObservationIgnored private var settings: WxSettings
    @ObservationIgnored private var cache: WxForecastCache
    /// The learned local temperature bias of the places' forecasts.
    @ObservationIgnored private var localBias = WxLocalBias()
    @ObservationIgnored private let engine: RefreshEngine
    @ObservationIgnored private let relay: Relay
    @ObservationIgnored private var registryHandler: WxRegistry.ChangeHandlerID?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var focused = false
    /// appendPlace(_:units:) is editing the list twice (the place, then its units):
    /// placesChanged() only notes the change and runs once when the edit ends.
    @ObservationIgnored private var placeEditOpen = false
    @ObservationIgnored private var placesChangedPending = false
    /// The window is on screen (setVisible): the alert wake-up runs only then.
    @ObservationIgnored private var windowVisible = false

    /// The alert kicks whose result has not landed, by kick id: the place and the task waiting
    /// for the service (cancelled with the place or at shutdown).
    @ObservationIgnored private var alertWaiters: [UInt64: (key: String, task: Task<Void, Never>)] = [:]
    /// The newest kick of each place whose result has not landed: only its landing is read.
    @ObservationIgnored private var alertNewest: [String: UInt64] = [:]
    @ObservationIgnored private var alertKickID: UInt64 = 0
    /// The armed alert wake-up: the next alert edge among the items (wall microseconds; nil:
    /// none), when it fires (monotonic microseconds) and its task.
    @ObservationIgnored private var alertWake: (edgeUS: Int64?, deadlineUS: Int64, task: Task<Void, Never>)?
    @ObservationIgnored private var alertWakeToken: UInt64 = 0
    /// Where the system clock's changes are posted, and the model's observer there.
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var clockObserver: (any NSObjectProtocol)?

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

    #if DEBUG
    // MARK: - Test seams (reached only through @testable import in DEBUG builds)

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
    #endif

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
    ///   - alerts: the places' alerts service (the app: AlertsService over the production
    ///     fetchers, AppEnvironment); nil gives an inert one that never requests anything and
    ///     reports every place not fetched (DECISIONS #41 A7).
    ///   - notificationCenter: where the system posts NSSystemClockDidChange (tests post their
    ///     own); a clock change re-reads every item's alerts at once.
    public init(registry: WxRegistry, storage: AppEnvironment.StorageRoot, clock: any WxClock = SystemClock(),
                online: Bool = true, log: LogSink? = nil, alerts: (any WxAlertsServing)? = nil,
                notificationCenter: NotificationCenter = .default) {
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
        self.alertsService = alerts ?? InertAlertsService()
        self.notificationCenter = notificationCenter
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
        // A set's age and an alert's expiry are wall-clock times: when the clock is set, every
        // item re-reads at once (DECISIONS #43 b). Posted on any thread; read on the main actor.
        clockObserver = notificationCenter.addObserver(forName: .NSSystemClockDidChange, object: nil,
                                                       queue: nil) { [relay] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { relay.model?.systemClockChanged() }
            } else {
                Task { @MainActor in relay.model?.systemClockChanged() }
            }
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
        // The alert waiters hold the model weakly and end with the service's work.
        alertWake?.task.cancel()
        if let clockObserver {
            notificationCenter.removeObserver(clockObserver)
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
        #if DEBUG
        let workerFirst = testLoadWorkerFirst
        let afterResume = workerFirst ? testLoadAfterWorkerResume : nil
        #endif
        let outcome: LoadOutcome = await withCheckedContinuation { continuation in
            #if DEBUG
            let resumed = workerFirst ? DispatchSemaphore(value: 0) : nil
            #endif
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.loadFiles(paths, clock: clock))
                #if DEBUG
                afterResume?()
                resumed?.signal()
                #endif
            }
            #if DEBUG
            // Test seam only: wait until the worker has resumed the continuation, so the await
            // below finds the result ready and does not suspend (an order the scheduler can produce).
            resumed?.wait()
            #endif
        }
        // load_done is a GTask callback, always dispatched by a later main-loop iteration
        // (wx-app.c:1914-1931): a continuation resumed before it is awaited does not suspend, so
        // yield once - a flush(timeout:) requested in the same turn is then always seen first.
        // If the task running load() was cancelled during startup (e.g. ShellState.quit /
        // requestTermination), enter shutdown before loadDone so loadDone takes its shutting-down
        // branch without autoselecting or dirtying settings (wx-app.c:1815-1816).
        if Task.isCancelled {
            enterShutdown()
        }
        await Task.yield()
        if Task.isCancelled {
            enterShutdown()
        }
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
        localBias = WxLocalBias.load(path: localBiasPath)
        stationSettings = WxStationSettings.load(path: stationSettingsPath)
        applySettings()
        migratePlaceUnits()
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
        // The units of the restored selection, or the loaded default units.
        syncUnits()
    }

    /// apply_settings (wx-app.c:1740-1755).
    private func applySettings() {
        if settings.units != defaultUnits {
            defaultUnits = settings.units
        }
        for provider in registry.listProviders() {
            registry.setEnabled(!settings.isProviderDisabled(provider.id), id: provider.id)
        }
        let loadedWeights = WxWeightMultipliers.load(fromPath: weightsPath)
        weightMultipliers = loadedWeights
        WxWeights.activeMultipliers = loadedWeights
    }

    /// Gives every place loaded without units (a places.json from before per-place units) the
    /// settings' units - what the app showed it in - and schedules one save of the list. Runs
    /// once, at the load and before the list announces changes; a relaunch finds every place
    /// with units, changes nothing and saves nothing.
    private func migratePlaceUnits() {
        var migrated = false
        for place in placeList.places where placeList.units(forKey: place.key) == nil {
            if placeList.setUnits(settings.units, forKey: place.key) {
                migrated = true
            }
        }
        if migrated {
            scheduleSave()
        }
    }

    // MARK: - Local bias

    /// "<config>/weather/local-bias.json".
    private var localBiasPath: String {
        storage.configDirectory.isEmpty ? "" : WxLocalBias.defaultPath(configDirectory: storage.configDirectory)
    }

    /// Learns the place's local forecast bias from a trustworthy fused station temperature observed
    /// at `nowS` (close, fresh stations: the caller decides), and re-applies the correction to its
    /// forecast. The model value compared is the uncorrected blend at `nowS`.
    public func learnLocalBias(key: String, observedTempC: Double, nowS: Int64) {
        guard let i = itemIndex(key), let model = places[i].modelForecast,
              let modelNow = WxBlend.now(model, nowS: nowS)?.tempC, modelNow.isFinite,
              localBias.addSample(
                placeKey: key, lon: places[i].place.lon, modelTempC: modelNow, observedTempC: observedTempC,
                nowS: nowS)
        else {
            return
        }
        saveLocalBias()
        localBiasRevision &+= 1
        let corrected = shown(model, key: key, nowS: nowS)
        if places[i].forecast != corrected {
            places[i].forecast = corrected
        }
    }

    /// The forecast to show for a blend: corrected by the learned local bias when the corrections
    /// are on.
    private func shown(_ forecast: WxForecast, key: String, nowS: Int64? = nil) -> WxForecast {
        guard stationSettings.localCorrectionsEnabled else { return forecast }
        return localBias.corrected(forecast, placeKey: key, nowS: nowS ?? clock.wallSeconds)
    }

    /// Re-derives every shown forecast from its blend (after the corrections changed).
    private func reapplyLocalCorrections() {
        for i in places.indices {
            guard let model = places[i].modelForecast else { continue }
            let next = shown(model, key: places[i].key)
            if places[i].forecast != next {
                places[i].forecast = next
            }
        }
    }

    /// What has been learned for one place, for the Settings list.
    public struct LocalCorrection: Sendable, Identifiable, Equatable {
        /// One local clock hour of today.
        public struct Hour: Sendable, Equatable {
            /// The local clock hour, 0...23.
            public let hour: Int
            /// Its middle, UTC unix seconds; 0 for an hour the clock skips that day (spring
            /// forward), which has nothing learned and is never now.
            public let tS: Int64
            /// The correction applied at that time, °C (0 until enough is learned).
            public let correctionC: Double
            /// The samples learned for that time of day.
            public let samples: Int
        }

        public let key: String
        public var id: String { key }
        public let place: WxPlace
        /// Samples learned, all hours together (0: nothing yet).
        public let samples: Int
        /// Hours of the day with at least one sample, of 24.
        public let hoursLearned: Int
        /// The newest sample, UTC unix seconds; nil when nothing is learned.
        public let lastUpdateS: Int64?
        /// 1 while fresh; below 1 when fading (no sample for more than 30 days).
        public let strength: Double
        /// The correction applied now, °C.
        public let nowC: Double
        /// Today's 24 local hours.
        public let hours: [Hour]
    }

    /// The learned corrections of the places, in list order (also places with nothing learned).
    public var localCorrections: [LocalCorrection] {
        _ = localBiasRevision
        let nowS = clock.wallSeconds
        return places.map { item in
            let p = item.place
            let summary = localBias.summary(placeKey: item.key, nowS: nowS)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: p.timezone) ?? TimeZone(secondsFromGMT: 0) ?? .current
            let now = Date(timeIntervalSince1970: TimeInterval(nowS))
            let hours = (0..<24).map { h -> LocalCorrection.Hour in
                let date = calendar.date(bySettingHour: h, minute: 30, second: 0, of: now) ?? now
                // A skipped hour resolves to the next one (03:00 for 02:30 on a spring-forward
                // day), whose solar bin and time the next row already shows - or, when it is the
                // day's last hour (America/Nuuk 23:00), to the same hour of the next day.
                guard calendar.component(.hour, from: date) == h, calendar.isDate(date, inSameDayAs: now) else {
                    return LocalCorrection.Hour(hour: h, tS: 0, correctionC: 0, samples: 0)
                }
                let tS = Int64(date.timeIntervalSince1970)
                return LocalCorrection.Hour(
                    hour: h, tS: tS,
                    correctionC: localBias.correctionC(placeKey: item.key, lon: p.lon, at: tS, nowS: nowS),
                    samples: localBias.samples(placeKey: item.key, lon: p.lon, at: tS))
            }
            return LocalCorrection(
                key: item.key, place: p, samples: summary?.samples ?? 0, hoursLearned: summary?.hoursLearned ?? 0,
                lastUpdateS: summary?.lastUpdateS, strength: summary?.strength ?? 1.0,
                nowC: localBias.correctionC(placeKey: item.key, lon: p.lon, at: nowS, nowS: nowS), hours: hours)
        }
    }

    /// Turns the learned local corrections on or off for every forecast shown (learning goes on).
    public func setLocalCorrectionsEnabled(_ enabled: Bool) {
        guard !isShuttingDown, isLoaded, stationSettings.localCorrectionsEnabled != enabled else { return }
        stationSettings.localCorrectionsEnabled = enabled
        saveStationSettings()
        reapplyLocalCorrections()
    }

    /// Forgets what was learned for one place; its forecast is the blend again.
    public func resetLocalCorrections(key: String) {
        guard !isShuttingDown, isLoaded, localBias.places[key] != nil else { return }
        localBias.remove(placeKey: key)
        saveLocalBias()
        localBiasRevision &+= 1
        reapplyLocalCorrections()
    }

    /// Forgets what was learned for every place.
    public func resetAllLocalCorrections() {
        guard !isShuttingDown, isLoaded, !localBias.places.isEmpty else { return }
        localBias = WxLocalBias()
        saveLocalBias()
        localBiasRevision &+= 1
        reapplyLocalCorrections()
    }

    // MARK: - Station settings

    /// "<config>/weather/station-settings.json".
    private var stationSettingsPath: String {
        storage.configDirectory.isEmpty ? "" : WxStationSettings.defaultPath(configDirectory: storage.configDirectory)
    }

    /// Turns one station network on or off (off: not fetched, not blended).
    public func setStationNetworkEnabled(_ network: WxStationNetwork, _ enabled: Bool) {
        guard !isShuttingDown, isLoaded, stationSettings.isEnabled(network) != enabled else { return }
        if enabled {
            stationSettings.disabledNetworks.remove(network)
        } else {
            stationSettings.disabledNetworks.insert(network)
        }
        saveStationSettings()
    }

    private func saveStationSettings() {
        if !stationSettings.save(path: stationSettingsPath) {
            log(.warning, "Could not save the station settings")
        }
    }

    /// The learned correction (°C, added to the model temperature) of a place at `tS`; 0 until
    /// enough is learned.
    public func localBiasCorrection(key: String, at tS: Int64) -> Double {
        guard let i = itemIndex(key) else { return 0 }
        return localBias.correctionC(placeKey: key, lon: places[i].place.lon, at: tS, nowS: clock.wallSeconds)
    }

    /// Writes the local bias (a few KB, at most a few times an hour per place) in place, as the
    /// weights are: writes started on other tasks could land out of order and keep an older one.
    private func saveLocalBias() {
        localBias.save(path: localBiasPath)
    }

    private var weightsPath: String {
        guard !storage.settingsPath.isEmpty else { return "" }
        return URL(fileURLWithPath: storage.settingsPath)
            .deletingLastPathComponent()
            .appendingPathComponent("weights.json")
            .path
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
    /// leave the cache (which schedules a save). Every item's units are the place's saved
    /// units, else the default units (a kept item keeps its forecast and request state). Every
    /// item's alerts are what the alerts service reports for its place (a new item: at once, so
    /// a place no source covers reads not covered); a removed place's alert work is cancelled
    /// and the service forgets it, so a late result of it is dropped; the alert wake-up is armed
    /// anew for what the items now show (DECISIONS #43 c).
    private func syncItems() {
        let old = Dictionary(places.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Place] = []
        next.reserveCapacity(placeList.count)
        for place in placeList.places {
            let key = place.key
            let units = placeList.units(forKey: key) ?? defaultUnits
            if var item = old[key] {
                if item.place != place {
                    item = Place(
                        place: place, key: key, forecast: item.forecast, modelForecast: item.modelForecast,
                        fetchedS: item.fetchedS,
                        loading: item.loading, stale: item.stale, offline: item.offline,
                        units: item.units, nowS: item.nowS, errorText: item.errorText, alerts: item.alerts
                    )
                }
                if item.units != units {
                    item.units = units
                }
                readAlerts(&item)
                next.append(item)
                continue
            }
            var item = Place(place: place, key: key, nowS: clock.wallSeconds)
            item.units = units
            item.offline = isOffline
            applyCache(&item)
            readAlerts(&item)
            next.append(item)
        }
        let kept = Set(next.map(\.key))
        places = next
        for key in old.keys where !kept.contains(key) {
            forgetAlerts(key: key)
            if cache.remove(key: key) {
                scheduleSave()
            }
            if localBias.places[key] != nil {
                localBias.remove(placeKey: key)
                saveLocalBias()
                localBiasRevision &+= 1
            }
        }
        syncAlertWake()
    }

    /// apply_cache (wx-app.c:600-607): the cached forecast with fetched time now minus its age.
    private func applyCache(_ item: inout Place) {
        guard let hit = cache.get(key: item.key) else {
            return
        }
        item.modelForecast = hit.forecast
        item.forecast = shown(hit.forecast, key: item.key)
        item.fetchedS = clock.wallSeconds - hit.ageMs / 1000
    }

    /// on_places_changed (wx-app.c:1306-1318) with the window's selection rules.
    private func placesChanged() {
        guard isLoaded else {
            return
        }
        if placeEditOpen {
            placesChangedPending = true
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
        // The selected item's units may have changed, or the selection (removal: the
        // neighbour, or none).
        syncUnits()
        scheduleSave()
    }

    /// tick_items (wx-app.c:1371-1379): every item gets the current wall time.
    private func tickItems(_ nowS: Int64) {
        displayNowS = nowS
        for i in places.indices where places[i].nowS != nowS {
            places[i].nowS = nowS
        }
        refreshAlertStates()
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
    /// with `units` (nil: the default units) and selects it (the picker's and the suggestion's
    /// add, wx-window.c:573-587, 646-654).
    public func add(_ place: WxPlace, units: WxUnits? = nil) -> AddResult {
        guard isLoaded, !isShuttingDown else {
            return .failed
        }
        guard appendPlace(place, units: units) else {
            return refusal(for: place)
        }
        selectInternal(place.key)
        return .added
    }

    /// WxPlaces.add then WxPlaces.setUnits (`units`, else the default units) as ONE change of
    /// the list: the item appears once, already in its units. False when WxPlaces refuses it.
    private func appendPlace(_ place: WxPlace, units: WxUnits?) -> Bool {
        placeEditOpen = true
        let added = placeList.add(place)
        if added {
            placeList.setUnits(units ?? defaultUnits, forKey: place.key)
        }
        placeEditOpen = false
        if placesChangedPending {
            placesChangedPending = false
            placesChanged()
        }
        return added
    }

    /// Saves a user-specified street address or custom-named location (e.g. "Home", "Work",
    /// "Friend's place") and selects it. Multiple named locations within the same city (< 5 km)
    /// are supported; if another location with a different name shares the exact 4-decimal
    /// coordinate key, the coordinate is nudged by 0.0001° (~10 m) so both keys remain distinct.
    /// `units` (nil: the default units) are saved with the place.
    public func addCustomLocation(
        _ place: WxPlace,
        customName: String? = nil,
        streetAddress: String? = nil,
        units: WxUnits? = nil
    ) -> AddResult {
        guard isLoaded, !isShuttingDown else {
            return .failed
        }
        if placeList.count >= WxPlaces.maxPlaces {
            return .full
        }
        let trimmedCustom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedStreet = streetAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isCustom = place.isCustomLocation || !trimmedCustom.isEmpty || !trimmedStreet.isEmpty

        guard var candidate = try? (isCustom
            ? place.withCustomLocation(
                customName: trimmedCustom.isEmpty ? (place.customName.isEmpty ? nil : place.customName) : trimmedCustom,
                streetAddress: trimmedStreet.isEmpty ? (place.streetAddress.isEmpty ? nil : place.streetAddress) : trimmedStreet,
                isCustomLocation: true
            )
            : place)
        else {
            return .failed
        }

        if !candidate.isCustomLocation {
            return add(candidate, units: units)
        }

        // Reject only if an identical custom place (same name and same rounded coordinate) is already saved.
        if placeList.places.contains(where: {
            WxGeo.distanceKm(aLat: $0.lat, aLon: $0.lon, bLat: candidate.lat, bLon: candidate.lon) < 0.05
                && $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame
                && $0.admin1.caseInsensitiveCompare(candidate.admin1) == .orderedSame
        }) {
            return .duplicate
        }

        // Ensure a distinct 4-decimal coordinate key if another place with a different name is at the exact same rounded key.
        var step = 1
        while placeList.index(ofKey: candidate.key) != nil && step <= 25 {
            let delta = Double(step) * 0.0001
            let newLon = candidate.lon + (candidate.lon < 179.99 ? delta : -delta)
            if let nudged = try? candidate.withCoordinates(lat: candidate.lat, lon: newLon) {
                candidate = nudged
            }
            step += 1
        }

        guard appendPlace(candidate, units: units) else {
            return refusal(for: candidate)
        }
        selectInternal(candidate.key)
        return .added
    }

    /// Updates a saved place's custom name (e.g. "Home", "Work", "Friend's place", or "" to clear)
    /// and/or its street address in-place without losing its forecast or position in the list.
    @discardableResult
    public func renamePlace(
        key: String?,
        customName: String?,
        streetAddress: String? = nil
    ) -> Bool {
        guard isLoaded, !isShuttingDown,
              let idx = placeList.index(ofKey: key),
              let existing = placeList.place(at: idx)
        else {
            return false
        }
        let trimmedCustom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keepCustomFlag = existing.isCustomLocation || !trimmedCustom.isEmpty || !(streetAddress ?? "").isEmpty
        guard let updated = try? existing.withCustomLocation(
            customName: trimmedCustom.isEmpty ? nil : trimmedCustom,
            streetAddress: streetAddress,
            isCustomLocation: keepCustomFlag
        ) else {
            return false
        }
        return placeList.updatePlace(key: existing.key, with: updated)
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
        syncUnits()
        log(.debug, "select \(newKey ?? "(none)")")
        if settings.setSelected(newKey) {
            scheduleSave()
        }
        engine.select(newKey)
    }

    // MARK: - Units

    /// The selected place's units (setUnits(_:forKey:)), else, with no selection, the default
    /// units (setDefaultUnits); nothing happens when unchanged, before the load or once
    /// shutting down.
    public func setUnits(_ units: WxUnits) {
        if let key = selectedPlace?.key {
            setUnits(units, forKey: key)
        } else {
            setDefaultUnits(units)
        }
    }

    /// Saves `units` with the place whose key is `key` (places.json): only that item changes,
    /// it keeps its forecast and no request is started or cancelled. False (nothing changes)
    /// for an unknown key, unchanged units, before the load or once shutting down.
    @discardableResult
    public func setUnits(_ units: WxUnits, forKey key: String?) -> Bool {
        guard !isShuttingDown, isLoaded else {
            return false
        }
        return placeList.setUnits(units, forKey: key)
    }

    /// wx_app_set_units (wx-app.c:1538-1553) for the default: the units new places get, stored
    /// in settings.json (a save is scheduled); saved places keep theirs. Nothing happens when
    /// unchanged, before the load or once shutting down.
    public func setDefaultUnits(_ units: WxUnits) {
        guard !isShuttingDown, isLoaded, defaultUnits != units else {
            return
        }
        defaultUnits = units
        syncUnits()
        settings.setUnits(units)
        scheduleSave()
    }

    /// Writes the `units` mirror (the selected item's units, else the default units) only when
    /// its value changes (U49 handoff, DECISIONS #41 A13).
    private func syncUnits() {
        let now = selectedPlace?.units ?? defaultUnits
        if units != now {
            units = now
        }
    }

    /// The window's "toggle-units" action (Ctrl+U / ⌘U): flips the selected place's units,
    /// else the default units.
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

    // MARK: - Source & Model Weights

    /// Current blend weight multiplier for a provider (`0.0 ... 3.0`, default `1.0`).
    public func sourceWeight(for providerID: String) -> Double {
        weightMultipliers.sourceMultiplier(for: providerID)
    }

    /// Updates a provider's blend weight multiplier, persists to `weights.json`, and re-fetches/re-blends.
    public func setSourceWeight(_ multiplier: Double, for providerID: String) {
        guard !isShuttingDown, isLoaded else { return }
        var next = weightMultipliers
        next.setSourceMultiplier(multiplier, for: providerID)
        guard next != weightMultipliers else { return }
        weightMultipliers = next
        WxWeights.activeMultipliers = next
        next.save(toPath: weightsPath)
        engine.sourcesChanged()
    }

    /// Current blend weight multiplier for a specific model (`0.0 ... 3.0`, default `1.0`).
    public func modelWeight(sourceID: String, modelID: String) -> Double {
        weightMultipliers.modelMultiplier(sourceID: sourceID, modelID: modelID)
    }

    /// Updates a specific model's blend weight multiplier, persists to `weights.json`, and re-fetches/re-blends.
    public func setModelWeight(_ multiplier: Double, sourceID: String, modelID: String) {
        guard !isShuttingDown, isLoaded else { return }
        var next = weightMultipliers
        next.setModelMultiplier(multiplier, sourceID: sourceID, modelID: modelID)
        guard next != weightMultipliers else { return }
        weightMultipliers = next
        WxWeights.activeMultipliers = next
        next.save(toPath: weightsPath)
        engine.sourcesChanged()
    }

    /// Resets all source and model weight multipliers back to `1.0` (the baseline heuristic table).
    public func resetWeights() {
        guard !isShuttingDown, isLoaded else { return }
        let defaults = WxWeightMultipliers()
        guard weightMultipliers != defaults else { return }
        weightMultipliers = defaults
        WxWeights.activeMultipliers = defaults
        defaults.save(toPath: weightsPath)
        engine.sourcesChanged()
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
        #if DEBUG
        let search: @MainActor ([UInt8]) async throws -> [WxPlace] = testSearch ?? { [service] bytes in
            try await service.search(textBytes: bytes)
        }
        let hits = try await search(textBytes)
        #else
        let hits = try await service.search(textBytes: textBytes)
        #endif
        if Task.isCancelled {
            throw CancellationError()
        }
        return hits
    }

    // MARK: - Window and network

    /// wx_app_set_window_visible (wx-app.c:1557-1571): the main window is on screen (mapped,
    /// not minimised, not hidden). Becoming visible starts a refresh round and the display
    /// clock (while online); becoming hidden cancels every request and stops the clock.
    /// Becoming visible also re-reads every item's alerts at once and arms their wake-up;
    /// becoming hidden disarms it (alert work in flight goes on, DECISIONS #41 A9).
    public func setVisible(_ visible: Bool) {
        guard !isShuttingDown else {
            return
        }
        log(.debug, "window visible=\(visible ? 1 : 0)")
        windowVisible = visible
        engine.setVisible(visible)
        if visible {
            refreshAlertStates()
        } else {
            syncAlertWake()
        }
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
        #if DEBUG
        requestsStarted += 1
        let refresh: @MainActor (WxPlace) async throws -> WxForecast = testRefresh ?? { [service] place in
            try await service.refresh(place)
        }
        #else
        let service = self.service
        let refresh: @MainActor (WxPlace) async throws -> WxForecast = { place in
            try await service.refresh(place)
        }
        #endif
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
        // Only now, with the forecast path done: a completed request (a forecast or a failure,
        // never a cancelled one) kicks the place's alerts.
        if completion != .cancelled {
            kickAlerts(key: key)
        }
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
        places[i].modelForecast = forecast
        places[i].forecast = shown(forecast, key: key)
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

    // MARK: - Alerts

    /// Kicks the alerts of the place `key` after a completed request, without waiting: nothing
    /// while offline, once shutting down or for a place no longer saved. The kick's result is
    /// read when the service's work ends, if it is still the place's newest kick.
    private func kickAlerts(key: String) {
        guard !isShuttingDown, !isOffline, let i = itemIndex(key) else {
            return
        }
        alertKickID &+= 1
        let id = alertKickID
        let work = alertsService.refresh(places[i].place)
        let waiter = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            self?.alertsLanded(key: key, id: id)
        }
        alertWaiters[id] = (key, waiter)
        alertNewest[key] = id
    }

    /// The work of kick `id` of the place `key` ended: the items re-read their alerts unless a
    /// newer kick of the place is pending, the place was removed or shutdown has begun.
    private func alertsLanded(key: String, id: UInt64) {
        alertWaiters[id] = nil
        guard !isShuttingDown, alertNewest[key] == id else {
            return
        }
        alertNewest[key] = nil
        guard itemIndex(key) != nil else {
            return
        }
        refreshAlertStates()
    }

    /// The item's alerts as the service reports them now, written only when they changed.
    private func readAlerts(_ item: inout Place) {
        guard !isShuttingDown else {
            return
        }
        let now = alertsService.result(for: item.place)
        if item.alerts != now {
            item.alerts = now
        }
    }

    /// Every item re-reads its alerts (expired alerts leave, a set past its window turns
    /// stale), then the wake-up is armed for the next such change. Nothing is fetched.
    private func refreshAlertStates() {
        guard isLoaded, !isShuttingDown else {
            return
        }
        for i in places.indices {
            readAlerts(&places[i])
        }
        syncAlertWake()
    }

    /// The system clock was set (NSSystemClockDidChange): every item re-reads its alerts at
    /// once and the wake-up is armed from the new wall time (DECISIONS #43 b).
    private func systemClockChanged() {
        refreshAlertStates()
    }

    /// The removed place `key`: its kicks are cancelled and dropped, the service forgets it.
    private func forgetAlerts(key: String) {
        alertNewest[key] = nil
        for (id, waiter) in alertWaiters where waiter.key == key {
            alertWaiters[id] = nil
            waiter.task.cancel()
        }
        alertsService.remove(placeKey: key)
    }

    /// Shutdown: every kick and the wake-up are cancelled, the service's work too (its
    /// cancelAll, which is for shutdown only: nothing is kicked after it).
    private func stopAlerts() {
        alertNewest = [:]
        for waiter in alertWaiters.values {
            waiter.task.cancel()
        }
        alertWaiters = [:]
        syncAlertWake()
        alertsService.cancelAll()
    }

    /// Arms the wake-up anew (after every re-read, DECISIONS #43 c): while the window is visible
    /// it fires at the next alert edge among the items, or alertWakeMaxS from now when that is
    /// sooner or there is none (#43 a): a wall-clock edge is turned into a monotonic deadline
    /// here, and a system sleep or a clock change moves one against the other. Disarmed when
    /// hidden or once shutdown has begun. It re-reads every item and fetches nothing.
    private func syncAlertWake() {
        alertWake?.task.cancel()
        alertWake = nil
        alertWakeToken &+= 1
        guard windowVisible, isLoaded, !isShuttingDown else {
            return
        }
        let token = alertWakeToken
        let clock = self.clock
        let edge = nextAlertEdgeUS()
        let nowUS = clock.monotonicMicroseconds
        let latest = Self.saturating(nowUS, plus: Self.saturating(Self.alertWakeMaxS, times: 1_000_000), minus: 0)
        let deadline = edge.map { min(Self.saturating(nowUS, plus: $0, minus: clock.wallMicroseconds), latest) } ?? latest
        let task = Task.immediate { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self, token == self.alertWakeToken else {
                return
            }
            self.alertWake = nil
            self.alertWakeToken &+= 1
            self.refreshAlertStates()
        }
        // A wake-up that already fired (its deadline passed meanwhile) re-armed itself.
        if token == alertWakeToken {
            alertWake = (edge, deadline, task)
        }
    }

    /// The earliest wall time after now, microseconds, at which an item's alerts read
    /// differently: an alert's expiry or end (WxAlert.isCurrent), or the end of a current set's
    /// source window. fetchedS is truncated to the second, so a window ends somewhere in
    /// [fetchedS, fetchedS + 1 s) + window: its first instant, then, while the set still reads
    /// current inside that second, the next alertWindowStepUS step (at most the second's end).
    private func nextAlertEdgeUS() -> Int64? {
        let nowUS = clock.wallMicroseconds
        var next: Int64?
        func consider(_ edgeUS: Int64) {
            if edgeUS > nowUS, next.map({ edgeUS < $0 }) ?? true {
                next = edgeUS
            }
        }
        for item in places {
            let r = item.alerts
            guard r.state == .current || r.state == .stale else {
                continue
            }
            for alert in r.alerts {
                for edgeS in [alert.expiresS, alert.endsS].compactMap({ $0 }) {
                    consider(Self.saturating(edgeS, times: 1_000_000))
                }
            }
            if r.state == .current, let fetchedS = r.fetchedS, let source = r.source {
                let windowUS = source == .meteoAlarm ? AlertsService.feedWindowUS : AlertsService.pointWindowUS
                let first = Self.saturating(Self.saturating(fetchedS, times: 1_000_000), plus: windowUS, minus: 0)
                if first > nowUS {
                    consider(first)
                } else {
                    let steps = Self.saturating(nowUS, plus: 0, minus: first) / Self.alertWindowStepUS + 1
                    let step = Self.saturating(first, plus: Self.saturating(steps, times: Self.alertWindowStepUS), minus: 0)
                    consider(min(step, Self.saturating(first, plus: 1_000_000, minus: 0)))
                }
            }
        }
        return next
    }

    /// `a * b`, clamped to the Int64 range (alert times are parsed, untrusted values).
    private nonisolated static func saturating(_ a: Int64, times b: Int64) -> Int64 {
        let (r, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? ((a < 0) != (b < 0) ? .min : .max) : r
    }

    /// `a + b - c`, clamped to the Int64 range.
    private nonisolated static func saturating(_ a: Int64, plus b: Int64, minus c: Int64) -> Int64 {
        let d = c == .min ? Int64.max : -c
        let (bd, o1) = b.addingReportingOverflow(d)
        if o1 {
            return b > 0 ? .max : .min
        }
        let (r, o2) = a.addingReportingOverflow(bd)
        return o2 ? (bd > 0 ? .max : .min) : r
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
            #if DEBUG
            let hook = testSaveHook
            #endif
            let log = self.log
            let places = placeList
            let settings = self.settings
            let cache = self.cache
            Task.immediate { @MainActor [relay] in
                #if DEBUG
                if let hook {
                    await hook(kind)
                }
                #endif
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
        enterShutdown()
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
                relay.model?.drainTimedOut(token: token)
            }
        }
    }

    private func enterShutdown() {
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        log(.debug, "shutdown: saving and waiting for \(requests.count) request(s)")
        saveTask?.cancel()
        saveTask = nil
        stopAlerts()
        engine.shutdown()
        if isLoaded {
            startSaves()
        }
    }

    /// drain_timeout (wx-app.c:1999-2006).
    private func drainTimedOut(token: UInt64) {
        drainTimers[token] = nil
        guard let waiter = drainWaiters.removeValue(forKey: token) else {
            return
        }
        log(.warning, "Gave up waiting for pending saves/requests after \(Self.shutdownWaitMs) ms")
        waiter.resume(returning: false)
    }

    #if DEBUG
    // MARK: - Internal views for tests

    /// The RefreshEngine (read-only use in tests).
    var refreshEngine: RefreshEngine { engine }
    /// Requests started and not yet finished.
    var requestsInFlight: Int { requests.count }
    /// Saves running now.
    var savesInFlight: Int { saving.count }
    /// Whether the save debounce timer is armed.
    var saveTimerArmed: Bool { saveTask != nil }
    /// Alert kicks whose result has not landed (cancelled ones until their task ends).
    var alertKicksInFlight: Int { alertWaiters.count }
    /// The tasks waiting for the alert kicks of the place `key` (each ends after its landing
    /// was handled).
    func alertKickTasks(forKey key: String) -> [Task<Void, Never>] {
        alertWaiters.values.filter { $0.key == key }.map(\.task)
    }
    /// The next alert edge among the items when the wake-up was armed, wall microseconds (it
    /// fires there or alertWakeMaxS after its arming, whichever is sooner); nil when disarmed or
    /// when there is none.
    var alertWakeEdgeUS: Int64? { alertWake?.edgeUS }
    /// When the alert wake-up fires, monotonic microseconds; nil when disarmed.
    var alertWakeDeadlineUS: Int64? { alertWake?.deadlineUS }
    #endif
}

// MARK: - Alerts service

/// What AppModel asks of the places' alerts service: AlertsService in the app (see its file
/// comment for the routing, the cadence and the currency rules), a fake in tests.
@MainActor
public protocol WxAlertsServing: AnyObject {
    /// Starts updating the alerts of `place` in the background and returns at once; the task
    /// ends once the result can be read (never awaited by the forecast path).
    @discardableResult
    func refresh(_ place: WxPlace) -> Task<Void, Never>
    /// The alerts of `place` at the time of the call.
    func result(for place: WxPlace) -> WxAlertsResult
    /// Forgets a removed place (by WxPlace.key) and cancels its work.
    func remove(placeKey: String)
    /// Cancels all work (shutdown only).
    func cancelAll()
}

extension AlertsService: WxAlertsServing {}

/// The alerts service of a model given none (tests, previews): it never requests anything and
/// reports every place not fetched (DECISIONS #41 A7).
@MainActor
final class InertAlertsService: WxAlertsServing {
    func refresh(_ place: WxPlace) -> Task<Void, Never> {
        Task {}
    }

    func result(for place: WxPlace) -> WxAlertsResult {
        AppModel.alertsNotFetched
    }

    func remove(placeKey: String) {}

    func cancelAll() {}
}
