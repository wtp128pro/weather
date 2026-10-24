// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RefreshEngine.swift - the application-level refresh policy of src/ui/wx-app.c
// (scheduler driving, forced refreshes, rate-limit cool-down, display clock).
//
// The engine feeds a RefreshScheduler (Sched/Scheduler.swift) with the places, the
// window's visibility and focus, the selection and the network state, and executes
// its actions through callbacks: `fetch(id, key)` starts a request, `cancel(id)` asks
// for a request to be cancelled. The host reports EVERY started request exactly once
// through requestFinished(id:result:), also when it ended by cancellation (it may do so
// from inside the cancel callback, like a GCancellable that completes synchronously).
// `display(nowS)` is the display clock (tick_items): it gives the items the current wall
// time in seconds.
//
// Time comes only from the injected WxClock: monotonic microseconds for every deadline
// and wall milliseconds for the scheduler (sched_now(), wx-app.c:124-127). There are at
// most two timers, both tasks that sleep on that clock: the refresh timer (rearm_timer,
// wake_timeout) and the display clock (sync_clock, clock_timeout).
//
// Policy (wx-app.h:47-102):
//  - A forced refresh (refreshSelected(), sourcesChanged()) makes the scheduler forget the
//    place and see it again, so it is fetched at once regardless of the freshness windows.
//  - Forced refreshes of a place are held back while it is loading, for refreshMinGapS
//    after its latest request started or succeeded and for rateLimitCooldownS after a
//    failure with WxError.Code.rateLimited. The Refresh button's request is DROPPED in
//    such a period; sourcesChanged() marks every place to be asked once when allowed.
//  - A place that failed with .rateLimited is out of the scheduler's set of places for
//    rateLimitCooldownS; when that has ended (and the engine is active) it is given back
//    and fetched once. Any other failure starts no cool-down.
//  - Hiding the window or losing the network cancels every request in flight and stops
//    the display clock; nothing is fetched then.
//  - The stale flag of a place changes only by the outcome of one of its requests: OK
//    clears it, FAILED sets it, CANCELLED leaves it.

/// The app-layer refresh policy of wx-app.c, driven by a WxClock and a RefreshScheduler.
/// All members run on the main actor (wx-app.h:18-32: main-thread only).
@MainActor public final class RefreshEngine {
    /// Period of the display clock while visible and online, seconds (WX_APP_CLOCK_TICK_S, wx-app.h:155).
    public static let clockTickS: Int64 = 60
    /// Minimum time between a place's latest request start or success and a forced refresh,
    /// seconds (WX_APP_REFRESH_MIN_GAP_S, wx-app.h:158).
    public static let refreshMinGapS: Int64 = 10
    /// Cool-down after a refresh failed with WxError.Code.rateLimited, seconds
    /// (WX_APP_RATE_LIMIT_COOLDOWN_S, wx-app.h:161).
    public static let rateLimitCooldownS: Int64 = 60

    private static let usecPerSec: Int64 = 1_000_000

    /// How a request ended, as the host reports it (outcome(), wx-app.c:869-878 and the
    /// rate-limit test of refresh_done, wx-app.c:1012-1013).
    public enum Completion: Sendable, Equatable {
        /// A forecast was delivered.
        case ok
        /// The request was cancelled (G_IO_ERROR_CANCELLED).
        case cancelled
        /// Any other end; nil is the C "unknown error". Only `.rateLimited` starts the cool-down.
        case failed(WxError?)
    }

    /// What the window shows of a place's refresh state.
    public struct PlaceState: Sendable, Equatable {
        /// A request of the place is in flight.
        public var loading: Bool
        /// The place's latest completed request failed (cleared only by an OK result).
        public var stale: Bool

        public init(loading: Bool, stale: Bool) {
            self.loading = loading
            self.stale = stale
        }
    }

    private struct Entry {
        var loading = false
        var stale = false
        /// A forced refresh is pending (Refresh button or provider switch).
        var refetch = false
        /// Monotonic µs before which no forced refresh starts.
        var nextForcedUS: Int64 = 0
        /// Monotonic µs at which the rate-limit cool-down ends; 0 = none.
        var coolUntilUS: Int64 = 0
    }

    private let clock: any WxClock
    private let fetchHandler: @MainActor (UInt64, String) -> Void
    private let cancelHandler: @MainActor (UInt64) -> Void
    private let displayHandler: @MainActor (Int64) -> Void
    private let changeHandler: @MainActor (String) -> Void

    private var scheduler = RefreshScheduler()
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private var requests: [UInt64: String] = [:]
    private var selectedKey: String?
    private var visible = false
    private var offline: Bool
    private var shuttingDown = false

    private var wakeTask: Task<Void, Never>?
    private var wakeUS: Int64 = -1
    private var wakeToken: UInt64 = 0
    private var clockTask: Task<Void, Never>?
    private var clockToken: UInt64 = 0

    /// Creates the engine (window hidden, no place, nothing in flight, no timer).
    /// - Parameters:
    ///   - clock: the only time source.
    ///   - online: whether the network is available now (wx-app.c:1922-1925).
    ///   - fetch: starts the request `id` for the place `key`.
    ///   - cancel: cancels the request `id`; its end is still reported by requestFinished.
    ///   - display: gives the items the current wall time, seconds (tick_items).
    ///   - stateChanged: the PlaceState of `key` changed.
    public init(clock: any WxClock,
                online: Bool,
                fetch: @escaping @MainActor (UInt64, String) -> Void,
                cancel: @escaping @MainActor (UInt64) -> Void,
                display: @escaping @MainActor (Int64) -> Void,
                stateChanged: @escaping @MainActor (String) -> Void = { _ in }) {
        self.clock = clock
        self.offline = !online
        fetchHandler = fetch
        cancelHandler = cancel
        displayHandler = display
        changeHandler = stateChanged
        scheduler.setOnline(online, now: schedNow())
    }

    // MARK: - Getters

    /// The place keys in display order.
    public var places: [String] { order }
    /// The selected place, nil for none.
    public var selected: String? { selectedKey }
    /// True while the network is unavailable (wx_app_get_offline).
    public var isOffline: Bool { offline }
    /// The refresh state of a place, nil for an unknown key.
    public func state(of key: String) -> PlaceState? {
        entries[key].map { PlaceState(loading: $0.loading, stale: $0.stale) }
    }
    /// Whether the Refresh action is enabled: a selected place that is not loading while the
    /// window is visible and the network available (wx-window.c:362, wx-app.h:436-454).
    public var canRefresh: Bool {
        guard isActive, let key = selectedKey, let e = entries[key] else { return false }
        return !e.loading
    }
    /// Number of requests started and not yet reported.
    public var requestsInFlight: Int { requests.count }
    /// Whether the refresh timer is armed (rearm_timer's wake_id != 0).
    public var refreshTimerArmed: Bool { wakeTask != nil }
    /// Whether the display clock runs (sync_clock's clock_id != 0).
    public var displayClockRunning: Bool { clockTask != nil }

    // MARK: - Inputs

    /// The places in display order (on_places_changed, wx-app.c). Invalid or repeated keys
    /// are kept out of the scheduler by it; a removed place's late result is dropped.
    public func setPlaces(_ keys: [String]) {
        guard !shuttingDown else { return }
        var seen = Set<String>()
        let newOrder = keys.filter { seen.insert($0).inserted }
        for key in order where !seen.contains(key) {
            entries[key] = nil
        }
        for key in newOrder where entries[key] == nil {
            entries[key] = Entry()
        }
        order = newOrder
        setSchedulerPlaces(skip: [])
        if let sel = selectedKey, entries[sel] == nil {
            selectedKey = nil
            scheduler.setSelection(nil, now: schedNow())
            pumpActions()
        }
    }

    /// wx_app_select: the place the detail pane shows (fetched first). Unknown keys count as none.
    public func select(_ key: String?) {
        guard !shuttingDown else { return }
        let newKey = key.flatMap { entries[$0] != nil ? $0 : nil }
        guard newKey != selectedKey else { return }
        selectedKey = newKey
        scheduler.setSelection(newKey, now: schedNow())
        pumpActions()
    }

    /// wx_app_set_window_visible (wx-app.c:1557-1571).
    public func setVisible(_ visible: Bool) {
        guard !shuttingDown else { return }
        let changed = self.visible != visible
        self.visible = visible
        if changed {
            tickItems()
        }
        syncClock()
        scheduler.setVisible(visible, now: schedNow())
        pumpActions()
        serveRefetches()
    }

    /// wx_app_window_focused (wx-app.c:1574-1582).
    public func windowFocused() {
        guard !shuttingDown else { return }
        scheduler.focusRegained(now: schedNow())
        pumpActions()
    }

    /// The network monitor's report (set_offline, wx-app.c:1352-1367).
    public func setOnline(_ online: Bool) {
        let offline = !online
        guard self.offline != offline else { return }
        self.offline = offline
        tickItems()
        syncClock()
        scheduler.setOnline(online, now: schedNow())
        pumpActions()
        serveRefetches()
    }

    /// wx_app_refresh_selected (wx-app.c:1616-1628): fetches the selected place again unless
    /// inactive, loading, inside the minimum gap or inside a rate-limit cool-down; then the
    /// call is dropped, not queued.
    public func refreshSelected() {
        guard let key = selectedKey, isActive, var e = entries[key] else { return }
        guard !e.loading, clock.monotonicMicroseconds >= e.nextForcedUS else { return }
        e.refetch = true
        entries[key] = e
        serveRefetches()
    }

    /// The refresh part of wx_app_set_provider_enabled (wx-app.c:1631-1655): every place is
    /// asked again, once however often this is called, as soon as it is allowed.
    public func sourcesChanged() {
        guard !shuttingDown else { return }
        for key in order {
            entries[key]?.refetch = true
        }
        serveRefetches()
    }

    /// Reports the end of request `id` (refresh_done + finish_request, wx-app.c:906-1014).
    /// Every request started through `fetch` is reported exactly once; an unknown id is ignored.
    public func requestFinished(id: UInt64, result: Completion) {
        guard let key = requests.removeValue(forKey: id) else { return }
        let outcome: RefreshScheduler.Outcome
        var rateLimited = false
        switch result {
        case .ok:
            outcome = .ok
        case .cancelled:
            outcome = .cancelled
        case .failed(let error):
            outcome = .failed
            rateLimited = error?.code == .rateLimited
        }
        scheduler.requestDone(id: id, outcome: outcome, now: schedNow())
        if var e = entries[key] {
            e.loading = false
            let nowUS = clock.monotonicMicroseconds
            switch outcome {
            case .ok:
                e.stale = false
                Self.hold(&e, nowUS + Self.refreshMinGapS * Self.usecPerSec)
            case .failed:
                e.stale = true
                if rateLimited {
                    let untilUS = nowUS + Self.rateLimitCooldownS * Self.usecPerSec
                    Self.hold(&e, untilUS)
                    e.coolUntilUS = untilUS
                }
            case .cancelled:
                break
            }
            entries[key] = e
            changeHandler(key)
            if rateLimited && !shuttingDown {
                setSchedulerPlaces(skip: [])
            }
        }
        pumpActions()
        serveRefetches()
    }

    /// The refresh part of wx_app_shutdown (wx-app.c:2028-2040): from now on every input is
    /// ignored, the display clock stops, every request in flight is cancelled and the refresh
    /// timer is removed. Late completions are still accepted.
    public func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        stopClock()
        scheduler.setVisible(false, now: schedNow())
        pumpActions()
        cancelWakeTimer()
    }

    // MARK: - Policy (wx-app.c:742-1389)

    private var isActive: Bool { visible && !offline && !shuttingDown }

    private func schedNow() -> RefreshScheduler.Time {
        RefreshScheduler.Time(monoUS: clock.monotonicMicroseconds, wallMS: clock.wallMilliseconds)
    }

    private static func hold(_ e: inout Entry, _ untilUS: Int64) {
        e.nextForcedUS = max(e.nextForcedUS, untilUS)
    }

    private func refetchWakeUS() -> Int64 {
        guard isActive else { return -1 }
        var wake: Int64 = -1
        for key in order {
            guard let e = entries[key] else { continue }
            if e.refetch && !e.loading && (wake < 0 || e.nextForcedUS < wake) {
                wake = e.nextForcedUS
            }
            if e.coolUntilUS != 0 && (wake < 0 || e.coolUntilUS < wake) {
                wake = e.coolUntilUS
            }
        }
        return wake
    }

    private func runAction(_ a: RefreshScheduler.Action) {
        switch a.kind {
        case .cancel:
            if requests[a.id] != nil {
                cancelHandler(a.id)  // may report the end synchronously
            }
        case .fetch:
            guard !shuttingDown, var e = entries[a.key] else { return }
            requests[a.id] = a.key
            e.refetch = false
            Self.hold(&e, clock.monotonicMicroseconds + Self.refreshMinGapS * Self.usecPerSec)
            e.loading = true
            entries[a.key] = e
            changeHandler(a.key)
            fetchHandler(a.id, a.key)
        }
    }

    private func pumpActions() {
        while true {
            let actions = scheduler.takeActions()
            if actions.isEmpty {
                break
            }
            for a in actions {
                runAction(a)
            }
        }
        rearmTimer()
    }

    private func setSchedulerPlaces(skip: Set<String>) {
        let keys = order.filter { key in
            let cooling = (entries[key]?.coolUntilUS ?? 0) != 0
            return !cooling && !skip.contains(key)
        }
        scheduler.setPlaces(keys, now: schedNow())
        pumpActions()
    }

    private func releaseCooled() {
        let nowUS = clock.monotonicMicroseconds
        var released = false
        for key in order {
            if let until = entries[key]?.coolUntilUS, until != 0, nowUS >= until {
                entries[key]?.coolUntilUS = 0
                released = true
            }
        }
        if released {
            setSchedulerPlaces(skip: [])
        }
    }

    private func serveRefetches() {
        if isActive {
            releaseCooled()
            let nowUS = clock.monotonicMicroseconds
            var ready = Set<String>()
            for key in order {
                guard var e = entries[key] else { continue }
                if e.refetch && !e.loading && nowUS >= e.nextForcedUS {
                    e.refetch = false
                    entries[key] = e
                    ready.insert(key)
                }
            }
            if !ready.isEmpty {
                setSchedulerPlaces(skip: ready)
                setSchedulerPlaces(skip: [])
            }
        }
        rearmTimer()
    }

    // MARK: - Timers (WxClock only)

    private func rearmTimer() {
        var wake = scheduler.nextWakeupUS
        let refetch = refetchWakeUS()
        if refetch >= 0 && (wake < 0 || refetch < wake) {
            wake = refetch
        }
        if wake < 0 {
            cancelWakeTimer()
            return
        }
        if wakeTask != nil && wakeUS == wake {
            return
        }
        cancelWakeTimer()
        let nowUS = clock.monotonicMicroseconds
        let delayUS = wake - nowUS
        // g_timeout_add takes whole milliseconds: the delay is rounded up (wx-app.c:1127-1129).
        let delayMS = delayUS <= 0 ? 0 : min((delayUS + 999) / 1000, Int64(Int32.max))
        let deadline = nowUS + delayMS * 1000
        wakeUS = wake
        wakeToken &+= 1
        let token = wakeToken
        let clock = self.clock
        // Task.immediate parks the sleeper before this returns, so a ManualClock advance that
        // is running sees it (time passes through every deadline in order, like GLib's loop).
        // A deadline that is already due must not fire inside this call: g_timeout_add never
        // dispatches synchronously, and the callers (pump_actions inside wake_timeout or
        // serve_refetches) re-arm again before they return. The timer then fires after one hop
        // through the main actor, like a 0 ms timeout at the next main-loop iteration.
        let due = deadline <= nowUS
        wakeTask = Task.immediate { @MainActor [weak self] in
            if due {
                await Task.yield()
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            self?.wakeTimeout(token: token)
        }
    }

    private func cancelWakeTimer() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeUS = -1
        wakeToken &+= 1
    }

    private func wakeTimeout(token: UInt64) {
        guard token == wakeToken, !Task.isCancelled else { return }
        wakeTask = nil
        wakeUS = -1
        scheduler.tick(now: schedNow())
        pumpActions()
        serveRefetches()
    }

    private func tickItems() {
        displayHandler(clock.wallSeconds)
    }

    private func syncClock() {
        if !isActive {
            stopClock()
        } else if clockTask == nil {
            clockToken &+= 1
            let token = clockToken
            let clock = self.clock
            let periodUS = Self.clockTickS * Self.usecPerSec
            clockTask = Task.immediate { @MainActor [weak self] in
                // g_timeout_add_seconds: the next expiry is set from the time of the dispatch.
                var deadline = clock.monotonicMicroseconds + periodUS
                while true {
                    do {
                        try await clock.sleep(until: deadline)
                    } catch {
                        return
                    }
                    guard let self, token == self.clockToken, !Task.isCancelled else { return }
                    self.tickItems()
                    deadline = clock.monotonicMicroseconds + periodUS
                }
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
        clockToken &+= 1
    }
}
