// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsAppModelTests.swift - the places' alerts in AppModel (U51, DECISIONS
// #41): every item carries what the alerts service reports for its place; a
// completed forecast request (not a cancelled one, not while offline) kicks
// the service without waiting; the forecast path is the same whatever the
// alerts do (a hanging or failing fetcher behind the real AlertsService); a
// removed place's alert work is cancelled and its late result dropped; a units
// change touches none of it; shutdown cancels it all and writes nothing more;
// the state follows expiry and the source window by itself (a wake-up on the
// model's clock, offline too, at the next edge but never more than 60 s away;
// DECISIONS #43), including a window that ends inside a second, a system sleep
// or a clock set either way (wall and monotonic time moved apart), and at once
// on a system clock change; every re-read re-arms it; it fetches nothing.
//
// No network: the forecast is scripted through AppModel.testRefresh, the
// alerts come from FakeAlerts (a WxAlertsServing that records its calls and
// lands each kick when told) or from a real AlertsService over a fake fetcher.
// No sleeps: every wait suspends on an observation of the model, a latch or
// a bounded run of main-actor yields; time is a ManualClock.

import Foundation
import Observation
import Synchronization
import Testing
@testable import WeatherCore

// MARK: - Fixture

/// A one-shot gate: wait() returns once open() was called or the waiting task is cancelled.
private final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var next: UInt64 = 0
    }
    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for w in waiters {
            w.resume()
        }
    }

    /// Like wait(), but only open() ends it (a fetcher that ignores cancellation).
    nonisolated(nonsending) func waitIgnoringCancellation() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.open {
                    return true
                }
                s.next += 1
                s.waiters[s.next] = c
                return false
            }
            if now {
                c.resume()
            }
        }
    }

    /// Runs on the caller's actor (no hop through the global executor).
    nonisolated(nonsending) func wait() async {
        let token = state.withLock { s -> UInt64 in
            s.next += 1
            return s.next
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // A task cancelled before it got here (onCancel found no waiter) does not park.
                let now = state.withLock { s -> Bool in
                    if s.open || Task.isCancelled {
                        return true
                    }
                    s.waiters[token] = c
                    return false
                }
                if now {
                    c.resume()
                }
            }
        } onCancel: {
            let w = state.withLock { $0.waiters.removeValue(forKey: token) }
            w?.resume()
        }
    }
}

/// Counts arrivals (fetches) and lets a test wait until a number is reached.
private final class Arrivals: Sendable {
    private struct State {
        var count = 0
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    func arrive() {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.count += 1
            let n = s.count
            let r = s.waiters.filter { $0.0 <= n }.map(\.1)
            s.waiters.removeAll { $0.0 <= n }
            return r
        }
        for c in ready {
            c.resume()
        }
    }

    nonisolated(nonsending) func wait(for n: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.count >= n {
                    return true
                }
                s.waiters.append((n, c))
                return false
            }
            if now {
                c.resume()
            }
        }
    }
}

/// A WxAlertsServing that records every call. Each refresh(_:) returns a task that ends when
/// the test lands it (land(_:_:): the result is published first, as the service does) or when
/// it is cancelled; result(for:) reports the published result, else not fetched.
@MainActor
private final class FakeAlerts: WxAlertsServing {
    struct Kick {
        let place: WxPlace
        let latch: Latch
        let task: Task<Void, Never>
    }
    private(set) var kicks: [Kick] = []
    private(set) var removed: [String] = []
    private(set) var cancelAllCount = 0
    /// Kicks made after cancelAll() (the U48 ruling: never in the same turn or later).
    private(set) var kicksAfterCancelAll = 0
    var results: [String: WxAlertsResult] = [:]
    /// The tasks of later kicks end only when landed, cancelled or not.
    var ignoresCancellation = false
    /// Whether remove(placeKey:) cancels the place's kicks (false: a service that cancels nothing,
    /// so only AppModel can cancel its own waiter).
    var removeCancelsKicks = true
    /// The kicks remove(placeKey:) itself has cancelled.
    private(set) var removeCancels = 0

    func refresh(_ place: WxPlace) -> Task<Void, Never> {
        if cancelAllCount > 0 {
            kicksAfterCancelAll += 1
        }
        let latch = Latch()
        let task = ignoresCancellation
            ? Task { await latch.waitIgnoringCancellation() } : Task { await latch.wait() }
        kicks.append(Kick(place: place, latch: latch, task: task))
        return task
    }

    func result(for place: WxPlace) -> WxAlertsResult {
        results[place.key] ?? AppModel.alertsNotFetched
    }

    func remove(placeKey: String) {
        removed.append(placeKey)
        results[placeKey] = nil
        guard removeCancelsKicks else {
            return
        }
        for k in kicks where k.place.key == placeKey {
            removeCancels += 1
            k.task.cancel()
        }
    }

    func cancelAll() {
        cancelAllCount += 1
        for k in kicks {
            k.task.cancel()
        }
    }

    /// Kick `n` ends: `result` is published for its place, then its task ends.
    func land(_ n: Int, _ result: WxAlertsResult) {
        results[kicks[n].place.key] = result
        kicks[n].latch.open()
    }

    func kicks(of key: String) -> Int {
        kicks.filter { $0.place.key == key }.count
    }
}

/// A NotificationCenter that records the observers added and removed through it and counts the
/// notifications delivered to their blocks (to see that the model's NSSystemClockDidChange
/// observer goes away with the model).
private final class RecordingCenter: NotificationCenter, @unchecked Sendable {
    private struct State {
        var added: [ObjectIdentifier] = []
        var removed: [ObjectIdentifier] = []
        var delivered = 0
    }

    private let state = Mutex(State())

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue) { [weak self] note in
            self?.state.withLock { $0.delivered += 1 }
            block(note)
        }
        state.withLock { $0.added.append(ObjectIdentifier(token)) }
        return token
    }

    override func removeObserver(_ observer: Any) {
        state.withLock { $0.removed.append(ObjectIdentifier(observer as AnyObject)) }
        super.removeObserver(observer)
    }

    /// The observers added, in order.
    var added: [ObjectIdentifier] { state.withLock { $0.added } }
    /// The observers removed, in order.
    var removed: [ObjectIdentifier] { state.withLock { $0.removed } }
    /// The notifications delivered to an observer's block so far.
    var delivered: Int { state.withLock { $0.delivered } }
}

/// How the scripted forecast refresh answers.
private enum RefreshMode {
    case ok
    case fail
    /// Answers a forecast once `Fx.hold` is opened (ignores cancellation, as a late answer).
    case held
}

/// The model over a temporary storage, a ManualClock and a scripted forecast refresh.
@MainActor
private final class Fx {
    let dir: TemporaryDirectory
    let storage: AppEnvironment.StorageRoot
    let clock = ManualClock()
    /// The model's own center: a test posts NSSystemClockDidChange there (and reads what the
    /// model added to it and removed from it).
    let notifications = RecordingCenter()
    var model: AppModel?
    var mode = RefreshMode.ok
    var hold = Latch()
    var logs: [String] = []

    init(_ label: String) throws {
        dir = try TemporaryDirectory("alerts-appmodel-\(label)")
        storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                             cacheDirectory: dir.appending("cache").path)
    }

    func storePlaces(_ places: [WxPlace], units: WxUnits = .imperial) throws {
        let list = try #require(WxPlaces(path: storage.placesPath))
        for p in places {
            #expect(list.add(p))
            #expect(list.setUnits(units, forKey: p.key))
        }
        try list.save()
    }

    /// The model, loaded; the window made visible when asked (which starts a refresh round).
    func start(alerts: (any WxAlertsServing)?, visible: Bool = true, online: Bool = true) async -> AppModel {
        let m = AppModel(registry: WxRegistry(), storage: storage, clock: clock, online: online,
                         log: { [weak self] _, message in self?.logs.append(message) }, alerts: alerts,
                         notificationCenter: notifications)
        let clock = self.clock
        m.testRefresh = { [weak self] place in
            switch self?.mode ?? .ok {
            case .ok:
                return try WxForecast(place: place, generatedS: clock.wallSeconds)
            case .fail:
                throw WxError(.network, "forecast source down")
            case .held:
                await self?.hold.wait()
                return try WxForecast(place: place, generatedS: clock.wallSeconds)
            }
        }
        model = m
        await m.load()
        if visible {
            m.setVisible(true)
        }
        return m
    }

    /// Advances the clock by `seconds` (the model's timers run on it).
    func advance(_ seconds: Int64) async {
        await clock.advance(by: seconds * 1_000_000)
    }
}

private func place(_ name: String, _ cc: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, admin1: "", country: "", countryCode: cc, lat: lat, lon: lon, timezone: "UTC")
}

private func miami() throws -> WxPlace { try place("Miami", "US", 25.7743, -80.1937) }
private func orlando() throws -> WxPlace { try place("Orlando", "US", 28.5383, -81.3792) }
private func tampa() throws -> WxPlace { try place("Tampa", "US", 27.9475, -82.4584) }

/// Suspends until `condition` holds, re-checking it on every change of the observed state it
/// reads (no polling, no sleep). A condition that never comes true ends in the suite's limit.
@MainActor
private func until(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                c.resume()
            }
        }
    }
}

/// Lets the main actor run the work already queued on it (a bounded run of yields) until
/// `condition` holds; for state the model does not publish. False when it never did.
@MainActor
private func settle(_ condition: @MainActor () -> Bool = { false }) async -> Bool {
    for _ in 0 ..< 2_000 {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

/// The request number `n` of the model (counted from 1) has been started and finished.
@MainActor
private func refreshed(_ m: AppModel, _ n: Int) async {
    await until { m.requestsStarted >= n && m.places.allSatisfy { !$0.loading } }
}

/// One NWS alert answer with these alerts (id, expires, ends; ISO 8601 UTC).
private func nwsBody(_ alerts: [(id: String, expires: String, ends: String?)]) -> Data {
    let features = alerts.map { a in
        #"{"id":"https://api.weather.gov/alerts/\#(a.id)","properties":{"id":"\#(a.id)","#
            + #""event":"Wind Advisory","headline":"Wind Advisory \#(a.id)","severity":"Moderate","#
            + #""status":"Actual","messageType":"Alert","effective":"2026-10-10T22:00:00Z","#
            + #""onset":"2026-10-10T22:00:00Z","expires":"\#(a.expires)","ends":"#
            + (a.ends.map { #""\#($0)""# } ?? "null") + "}}"
    }
    return Data((#"{"features":["# + features.joined(separator: ",") + "]}").utf8)
}

/// A fake alert fetcher behind a real AlertsService.
private final class Fetcher: Sendable {
    enum Mode: Sendable {
        /// Never answers (until cancelled).
        case hang
        /// Throws a network error.
        case fail
        /// Answers 200 with `body` once `gate` is open.
        case reply(Data, Latch)
    }
    let arrivals = Arrivals()
    private let mode: Mode
    private let clock: ManualClock

    init(_ mode: Mode, clock: ManualClock) {
        self.mode = mode
        self.clock = clock
    }

    var fetch: WxAlertsFetch {
        { [self] _, _ in
            arrivals.arrive()
            switch mode {
            case .hang:
                try await clock.sleep(until: .max)
                throw CancellationError()
            case .fail:
                throw WxError(.network, "alert source down")
            case .reply(let body, let gate):
                await gate.wait()
                try Task.checkCancellation()
                return WxAlertsResponse(status: 200, body: body)
            }
        }
    }
}

/// A result as the fake publishes it.
private func result(_ state: WxAlertsResult.State, alerts: [WxAlert] = [], fetchedS: Int64? = nil,
                    source: WxAlert.Source? = .nws) -> WxAlertsResult {
    WxAlertsResult(state: state, source: source, alerts: alerts, fetchedS: fetchedS)
}

private func alert(_ id: String, expiresS: Int64?) -> WxAlert {
    WxAlert(id: id, source: .nws, event: "Wind Advisory", headline: "Wind Advisory \(id)", description: "",
            instruction: "", level: .yellow, issuerSeverity: "Moderate", onsetS: nil, expiresS: expiresS,
            endsS: nil, web: nil)
}

/// Two NWS alerts of an answer at T0 (2026-10-11T00:00:00Z, the ManualClock's start): "soon"
/// expires at T0 + 300 s, "later" at T0 + 10830 s (3 h 30 s: off the 60 s re-read grid).
private let soonAndLater: [(id: String, expires: String, ends: String?)] = [
    (id: "soon", expires: "2026-10-11T00:05:00Z", ends: nil),
    (id: "later", expires: "2026-10-11T03:00:30Z", ends: nil),
]
private let laterExpiryOffsetS: Int64 = 10_830

/// The real AlertsService over a fetcher answering every place with `alerts` (one NWS answer
/// each), the model on it with `places` saved, loaded and visible and every set landed
/// (current), then the network down: no display tick, only the alert wake-up re-reads.
@MainActor
private func offlineWithAlerts(_ fx: Fx, _ places: [WxPlace],
                               _ alerts: [(id: String, expires: String, ends: String?)]) async throws
    -> (model: AppModel, service: AlertsService, fetcher: Fetcher) {
    try fx.storePlaces(places)
    let gate = Latch()
    gate.open()
    let fetcher = Fetcher(.reply(nwsBody(alerts), gate), clock: fx.clock)
    let service = AlertsService(clock: fx.clock, fetch: fetcher.fetch)
    let m = await fx.start(alerts: service)
    await refreshed(m, places.count)
    await until { m.places.allSatisfy { $0.alerts.state == .current } }
    m.setOnline(false)
    return (m, service, fetcher)
}

// MARK: - Suite

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct AlertsAppModelTests {
    // MARK: AC1 - each item carries its alert state; the kick and its cadence

    // A completed successful request kicks the place's alerts once, after the forecast was
    // applied and reported; the alerts are asked exactly as often as the forecast is refreshed
    // (display ticks fetch nothing).
    @Test func alertsKickedAfterSuccess() async throws {
        let fx = try Fx("success")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        let key = try miami().key
        await refreshed(m, 1)
        let item = try #require(m.place(forKey: key))
        #expect(item.fetchedS == fx.clock.wallSeconds && item.forecast != nil && item.errorText == nil)
        #expect(fake.kicks.map(\.place.key) == [key])
        // A second, manual refresh (after the 10 s gap): one more kick, no more.
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        await refreshed(m, 2)
        #expect(m.requestsStarted == 2)
        #expect(fake.kicks(of: key) == 2)
        // Display ticks and the alert wake-up re-read, they never kick: 9 minutes, no refresh due.
        for _ in 0 ..< 9 {
            await fx.advance(RefreshEngine.clockTickS)
        }
        #expect(m.requestsStarted == 2)
        #expect(fake.kicks.count == 2)
        // The periodic refresh (600 s after the last success): one request, one kick.
        await fx.advance(60)
        await refreshed(m, 3)
        #expect(fake.kicks.count == m.requestsStarted)
        await m.flush()
    }

    // A failed request kicks too (the forecast keeps its error and stale mark); a cancelled
    // request (the window hidden mid-flight) does not (DECISIONS #41 A3).
    @Test func alertsKickedAfterFailure() async throws {
        let fx = try Fx("failure")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        fx.mode = .fail
        let m = await fx.start(alerts: fake)
        let key = try miami().key
        await refreshed(m, 1)
        let item = try #require(m.place(forKey: key))
        #expect(item.errorText == "forecast source down")
        #expect(item.stale)
        #expect(fake.kicks.map(\.place.key) == [key])
        // Cancelled: hidden while the request is held; the late forecast is not applied and
        // kicks nothing.
        fx.mode = .held
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        #expect(m.requestsStarted == 2)
        m.setVisible(false)
        fx.hold.open()
        await refreshed(m, 2)
        #expect(await settle { m.requestsInFlight == 0 })
        #expect(fake.kicks.count == 1)
        await m.flush()
    }

    // Offline: a request cut off by the network going down kicks nothing, nothing is requested
    // or kicked while offline, and the next completed request online kicks again.
    @Test func alertsSkippedOffline() async throws {
        let fx = try Fx("offline")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        fx.mode = .held
        let m = await fx.start(alerts: fake)
        #expect(m.requestsStarted == 1)
        m.setOnline(false)
        fx.hold.open()  // the late answer arrives while offline
        await refreshed(m, 1)
        #expect(await settle { m.requestsInFlight == 0 })
        #expect(fake.kicks.isEmpty)
        m.refresh()
        for _ in 0 ..< 25 {  // 25 minutes offline: two periods and more
            await fx.advance(RefreshEngine.clockTickS)
        }
        #expect(m.requestsStarted == 1)
        #expect(fake.kicks.isEmpty)
        fx.mode = .ok
        m.setOnline(true)
        await refreshed(m, 2)
        #expect(fake.kicks.count == 1)
        await m.flush()
    }

    // Each item carries exactly what the service reports for its place: at once for a new item
    // (not covered without any request), then every state with its alerts and fetched time as
    // the kicks land. A model given no service gets an inert one (DECISIONS #41 A1, A7).
    @Test func itemCarriesAlertState() async throws {
        let fx = try Fx("state")
        let uncovered = try place("Nowhere", "ZZ", 10, 10)
        try fx.storePlaces([try miami(), uncovered])
        let fake = FakeAlerts()
        fake.results[uncovered.key] = result(.notCovered, source: nil)
        let m = await fx.start(alerts: fake, visible: false)
        let key = try miami().key
        #expect(m.place(forKey: uncovered.key)?.alerts == result(.notCovered, source: nil))
        #expect(m.place(forKey: key)?.alerts == AppModel.alertsNotFetched)
        m.setVisible(true)
        await refreshed(m, 2)
        #expect(fake.kicks.count == 2)
        let now = fx.clock.wallSeconds
        let n = try #require(fake.kicks.firstIndex { $0.place.key == key })
        let current = result(.current, alerts: [alert("a1", expiresS: now + 3600)], fetchedS: now)
        fake.land(n, current)
        await until { m.place(forKey: key)?.alerts == current }
        #expect(m.place(forKey: key)?.alerts.alerts.map(\.id) == ["a1"])
        #expect(m.place(forKey: key)?.alerts.fetchedS == now)
        // The next kicks land stale, then unavailable: the item follows each.
        for (i, state) in [WxAlertsResult.State.stale, .unavailable].enumerated() {
            await fx.advance(RefreshEngine.refreshMinGapS + 1)
            m.refresh()
            await refreshed(m, 3 + i)
            let next = result(state, alerts: state == .stale ? current.alerts : [], fetchedS: now)
            fake.land(fake.kicks.count - 1, next)
            await until { m.place(forKey: key)?.alerts == next }
        }
        await m.flush()

        // No service injected: the inert one, never asked anything, every place not fetched.
        let fx2 = try Fx("state-inert")
        try fx2.storePlaces([try miami(), uncovered])
        let m2 = await fx2.start(alerts: nil)
        await refreshed(m2, 2)
        #expect(m2.alertsService is InertAlertsService)
        #expect(m2.places.allSatisfy { $0.alerts == AppModel.alertsNotFetched })
        await m2.flush()
    }

    // MARK: AC2 - the forecast path whatever the alerts do

    // The real AlertsService behind a fetcher that never answers: every request is applied and
    // reported to the engine as before, the next refresh runs, and flush neither waits for the
    // alert work nor reports it (DECISIONS #41 A5).
    @Test func hangingAlertsDoNotDelayForecast() async throws {
        let fx = try Fx("hanging")
        try fx.storePlaces([try miami()])
        let fetcher = Fetcher(.hang, clock: fx.clock)
        let service = AlertsService(clock: fx.clock, fetch: fetcher.fetch)
        let m = await fx.start(alerts: service)
        let key = try miami().key
        await refreshed(m, 1)
        await fetcher.arrivals.wait(for: 1)  // the alert fetch is running and hangs
        var item = try #require(m.place(forKey: key))
        #expect(item.forecast != nil && item.fetchedS == fx.clock.wallSeconds && item.errorText == nil)
        #expect(!item.loading && !item.stale && m.requestsInFlight == 0)
        #expect(m.refreshEngine.state(of: key)?.loading == false)
        #expect(item.alerts.state == .notFetched)
        #expect(m.alertKicksInFlight == 1)
        // The next request runs and is applied while the first alert fetch still hangs.
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        await refreshed(m, 2)
        item = try #require(m.place(forKey: key))
        #expect(item.fetchedS == fx.clock.wallSeconds && item.errorText == nil && !item.stale)
        #expect(m.requestsInFlight == 0)
        #expect(fetcher.arrivals.count == 1)  // the service joined the running refresh
        let t0 = fx.clock.monotonicMicroseconds
        #expect(await m.flush())
        #expect(fx.clock.monotonicMicroseconds == t0)  // no wait on the model's clock
        #expect(!fx.logs.contains { $0.localizedCaseInsensitiveContains("alert") })
    }

    // The real AlertsService behind a fetcher that throws: the place reads "unavailable", and
    // the forecast is applied, reported and shown exactly as without alerts.
    @Test func failingAlertsDoNotAffectForecast() async throws {
        let fx = try Fx("failing")
        try fx.storePlaces([try miami()])
        let fetcher = Fetcher(.fail, clock: fx.clock)
        let m = await fx.start(alerts: AlertsService(clock: fx.clock, fetch: fetcher.fetch))
        let key = try miami().key
        await refreshed(m, 1)
        await until { m.place(forKey: key)?.alerts.state == .unavailable }
        let item = try #require(m.place(forKey: key))
        #expect(item.forecast != nil && item.fetchedS == fx.clock.wallSeconds)
        #expect(item.errorText == nil && !item.stale && !item.loading)
        #expect(m.refreshEngine.state(of: key)?.stale == false)
        #expect(item.alerts.alerts.isEmpty && item.alerts.source == .nws)
        // A failing forecast with failing alerts: the error text is the forecast's alone.
        fx.mode = .fail
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        await refreshed(m, 2)
        await fetcher.arrivals.wait(for: 2)
        let failed = try #require(m.place(forKey: key))
        #expect(failed.errorText == "forecast source down" && failed.stale && failed.forecast != nil)
        #expect(m.requestsInFlight == 0)
        #expect(await m.flush())
    }

    // MARK: AC3 - removal, shutdown, late results, units

    // Removing a place cancels its alert work and makes the service forget it; the other
    // place's work goes on. Shutdown cancels the rest (cancelAll, at shutdown only, nothing
    // kicked after it), does not wait for it, and no alert state is written after it (A6).
    @Test func removalCancelsAlerts() async throws {
        let fx = try Fx("removal")
        try fx.storePlaces([try miami(), try orlando()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        await refreshed(m, 2)
        #expect(fake.kicks.count == 2)
        let gone = try miami().key
        let kept = try orlando().key
        let goneWaiters = m.alertKickTasks(forKey: gone)
        let keptWaiters = m.alertKickTasks(forKey: kept)
        #expect(goneWaiters.count == 1 && keptWaiters.count == 1)
        #expect(m.remove(key: gone))
        #expect(fake.removed == [gone])
        #expect(fake.removeCancels == 1)
        let goneKick = try #require(fake.kicks.first { $0.place.key == gone })
        let keptKick = try #require(fake.kicks.first { $0.place.key == kept })
        #expect(goneKick.task.isCancelled)
        #expect(!keptKick.task.isCancelled)
        for t in goneWaiters {
            await t.value
        }
        #expect(m.alertKicksInFlight == 1)
        // Hiding the window or losing the network cancels no alert work (A9).
        m.setVisible(false)
        m.setOnline(false)
        #expect(!keptKick.task.isCancelled)
        #expect(m.alertKicksInFlight == 1)
        #expect(fake.cancelAllCount == 0)
        // Shutdown: everything cancelled, flush returns without waiting for it.
        let t0 = fx.clock.monotonicMicroseconds
        #expect(await m.flush())
        #expect(fx.clock.monotonicMicroseconds == t0)
        #expect(fake.cancelAllCount == 1)
        #expect(keptKick.task.isCancelled)
        #expect(fake.kicksAfterCancelAll == 0)
        // A result published after shutdown began is never written to the item.
        let late = result(.current, fetchedS: fx.clock.wallSeconds)
        fake.land(try #require(fake.kicks.firstIndex { $0.place.key == kept }), late)
        for t in keptWaiters {
            await t.value
        }
        #expect(m.alertKicksInFlight == 0)
        m.setVisible(true)
        m.setOnline(true)
        await fx.advance(RefreshEngine.clockTickS)
        #expect(m.place(forKey: kept)?.alerts == AppModel.alertsNotFetched)
    }

    // A late answer for a removed place, through the real AlertsService: the place removed
    // and saved again while its fetch runs (offline, so nothing new is kicked) stays not
    // fetched, and the other place, shifted to another index, gets its own answer (A9, A11).
    @Test func lateResultForRemovedPlaceDiscarded() async throws {
        let fx = try Fx("late")
        let p = try miami()
        let q = try orlando()
        try fx.storePlaces([p, q])
        let gate = Latch()
        let body = nwsBody([(id: "x1", expires: "2026-10-11T03:00:00Z", ends: nil)])
        let fetcher = Fetcher(.reply(body, gate), clock: fx.clock)
        let m = await fx.start(alerts: AlertsService(clock: fx.clock, fetch: fetcher.fetch))
        await refreshed(m, 2)
        await fetcher.arrivals.wait(for: 2)
        m.setOnline(false)  // in-flight alert work goes on (A9)
        #expect(m.alertKicksInFlight == 2)
        let pWaiters = m.alertKickTasks(forKey: p.key)
        #expect(m.remove(key: p.key))
        #expect(m.add(p) == .added)
        #expect(m.places.map(\.key) == [q.key, p.key])
        gate.open()
        await until { m.place(forKey: q.key)?.alerts.state == .current }
        #expect(m.place(forKey: q.key)?.alerts.alerts.map(\.id) == ["nws:x1"])
        for t in pWaiters {
            await t.value
        }
        #expect(m.alertKicksInFlight == 0)
        #expect(m.place(forKey: p.key)?.alerts.state == .notFetched)
        #expect(m.places[1].alerts.state == .notFetched)  // the index the removed place had is q's no more
        await m.flush()
    }

    // A units change (one place's, the default's, the toggle) neither cancels nor drops an
    // alert kick or a forecast request in flight; both are applied when they land.
    @Test func unitsChangeKeepsInFlightAlerts() async throws {
        let fx = try Fx("units")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        let key = try miami().key
        await refreshed(m, 1)
        #expect(fake.kicks.count == 1)
        #expect(m.setUnits(.metric, forKey: key))
        m.toggleUnits()
        m.setDefaultUnits(.metric)
        #expect(m.place(forKey: key)?.units == .imperial)
        #expect(fake.removed.isEmpty && fake.cancelAllCount == 0)
        #expect(!fake.kicks[0].task.isCancelled)
        // A forecast request in flight across a units change.
        fx.mode = .held
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        #expect(m.requestsStarted == 2)
        m.toggleUnits()
        #expect(m.place(forKey: key)?.units == .metric)
        let current = result(.current, fetchedS: fx.clock.wallSeconds)
        fake.land(0, current)
        await until { m.place(forKey: key)?.alerts == current }
        let generated = fx.clock.wallSeconds
        fx.hold.open()
        await refreshed(m, 2)
        #expect(m.place(forKey: key)?.forecast?.generatedS == generated)
        #expect(m.place(forKey: key)?.errorText == nil)
        #expect(fake.kicks.count == 2)
        #expect(m.place(forKey: key)?.units == .metric)
        await m.flush()
    }

    // MARK: DECISIONS #41 rulings

    // U48 ruling: cancelAll() is called at shutdown only, once, and nothing is kicked after it -
    // not even by a request that completes during the shutdown (it ends cancelled, A3/A6).
    @Test func cancelAllOnlyAtShutdown() async throws {
        let fx = try Fx("cancel-all")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        await refreshed(m, 1)
        let key = try miami().key
        #expect(m.setUnits(.metric, forKey: key))
        m.setVisible(false)
        m.setVisible(true)
        fx.mode = .held
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        #expect(m.requestsStarted == 2)
        #expect(fake.cancelAllCount == 0)
        let flush = Task { @MainActor in await m.flush() }
        #expect(await settle { m.isShuttingDown })
        #expect(fake.cancelAllCount == 1)
        fx.hold.open()  // the request answers during the shutdown
        #expect(await flush.value)
        #expect(m.requestsInFlight == 0)
        #expect(fake.cancelAllCount == 1)
        #expect(fake.kicks.count == 1 && fake.kicksAfterCancelAll == 0)
    }

    // A2: the state honours expiry and the source window without any fetch: through the real
    // AlertsService, offline (no display tick), the one-shot wake-up re-reads at the alert's
    // expiry and at the window's end; hidden, it is disarmed; visible again, re-read at once.
    @Test func alertStateFollowsExpiryAndWindowOffline() async throws {
        let fx = try Fx("wake")
        try fx.storePlaces([try miami()])
        let gate = Latch()
        gate.open()
        // T0 = 2026-10-11T00:00:00Z: one alert expires at T0 + 300 s, one at T0 + 3 h.
        let body = nwsBody([(id: "soon", expires: "2026-10-11T00:05:00Z", ends: nil),
                            (id: "later", expires: "2026-10-11T03:00:00Z", ends: nil)])
        let fetcher = Fetcher(.reply(body, gate), clock: fx.clock)
        let m = await fx.start(alerts: AlertsService(clock: fx.clock, fetch: fetcher.fetch))
        let key = try miami().key
        let t0 = fx.clock.wallSeconds
        await refreshed(m, 1)
        await until { m.place(forKey: key)?.alerts.state == .current }
        #expect(Set(m.place(forKey: key)?.alerts.alerts.map(\.id) ?? []) == ["nws:soon", "nws:later"])
        #expect(m.alertWakeEdgeUS == (t0 + 300) * 1_000_000)
        m.setOnline(false)
        await fx.advance(300)
        #expect(m.place(forKey: key)?.alerts.alerts.map(\.id) == ["nws:later"])
        #expect(m.place(forKey: key)?.alerts.state == .current)
        #expect(m.alertWakeEdgeUS == (t0 + 600) * 1_000_000)
        await fx.advance(299)
        #expect(m.place(forKey: key)?.alerts.state == .current)
        await fx.advance(1)
        #expect(m.place(forKey: key)?.alerts.state == .stale)
        #expect(m.place(forKey: key)?.alerts.alerts.map(\.id) == ["nws:later"])
        #expect(fetcher.arrivals.count == 1)
        // Hidden: no wake-up; the "later" alert expires unseen; visible again: re-read at once.
        m.setVisible(false)
        #expect(m.alertWakeEdgeUS == nil && m.alertWakeDeadlineUS == nil)
        await fx.advance(3 * 3600)
        #expect(m.place(forKey: key)?.alerts.alerts.map(\.id) == ["nws:later"])
        m.setVisible(true)
        #expect(m.place(forKey: key)?.alerts.alerts.isEmpty == true)
        #expect(m.place(forKey: key)?.alerts.state == .stale)
        // No edge left; visible, the wake-up still re-reads within 60 s (DECISIONS #43 a).
        #expect(m.alertWakeEdgeUS == nil)
        #expect(m.alertWakeDeadlineUS == fx.clock.monotonicMicroseconds + AppModel.alertWakeMaxS * 1_000_000)
        #expect(fetcher.arrivals.count == 1)
        await m.flush()
    }

    // A8: of two kicks of one place, the newest one's landing is read; the older one landing
    // late does not make the item re-read (here it would show the older result).
    @Test func newestKickWins() async throws {
        let fx = try Fx("newest")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        let key = try miami().key
        await refreshed(m, 1)
        await fx.advance(RefreshEngine.refreshMinGapS + 1)
        m.refresh()
        await refreshed(m, 2)
        #expect(fake.kicks.count == 2)
        let waiters = m.alertKickTasks(forKey: key)
        #expect(waiters.count == 2)
        let newer = result(.current, fetchedS: fx.clock.wallSeconds)
        fake.land(1, newer)
        await until { m.place(forKey: key)?.alerts == newer }
        let older = result(.unavailable, fetchedS: fx.clock.wallSeconds - 11)
        fake.land(0, older)
        for t in waiters {
            await t.value
        }
        #expect(m.alertKicksInFlight == 0)
        #expect(m.place(forKey: key)?.alerts == newer)
        await m.flush()
    }

    // A6: once shutdown has begun no alert state is written: a service that ignores the
    // cancellation and publishes its result after the shutdown began changes no item, and
    // neither the display clock nor the wake-up re-reads any more.
    @Test func noAlertWritesAfterShutdown() async throws {
        let fx = try Fx("after-shutdown")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        fake.ignoresCancellation = true
        let m = await fx.start(alerts: fake)
        let key = try miami().key
        await refreshed(m, 1)
        let waiters = m.alertKickTasks(forKey: key)
        #expect(waiters.count == 1)
        let t0 = fx.clock.monotonicMicroseconds
        #expect(await m.flush())  // does not wait for the kick (A5)
        #expect(fx.clock.monotonicMicroseconds == t0)
        #expect(fake.kicks[0].task.isCancelled)
        let late = result(.current, alerts: [alert("late", expiresS: fx.clock.wallSeconds + 60)],
                          fetchedS: fx.clock.wallSeconds)
        fake.land(0, late)  // published after the shutdown began
        for t in waiters {
            await t.value
        }
        #expect(m.alertKicksInFlight == 0)
        await fx.advance(2 * RefreshEngine.clockTickS)
        #expect(m.place(forKey: key)?.alerts == AppModel.alertsNotFetched)
        #expect(m.alertWakeEdgeUS == nil && m.alertWakeDeadlineUS == nil)
    }

    // A10: alert work in flight does not keep the model alive.
    @Test func alertWorkDoesNotRetainModel() async throws {
        let fx = try Fx("retain")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        weak var weakModel: AppModel?
        do {
            let m = await fx.start(alerts: fake)
            weakModel = m
            await refreshed(m, 1)
            #expect(m.alertKicksInFlight == 1)
            fx.model = nil
        }
        #expect(await settle { weakModel == nil })
        #expect(!fake.kicks[0].task.isCancelled)
        fake.land(0, result(.current, fetchedS: 0))  // lands on nothing
        await fake.kicks[0].task.value
    }

    // MARK: DECISIONS #43 - wall and monotonic time apart, clock changes, re-arming

    // #43 a: a system sleep moves the wall clock and not the monotonic one (SystemClock reads
    // CLOCK_UPTIME_RAW and sleeps on SuspendingClock); so does, here, a clock set forward while
    // awake. Visible and offline (no display tick), the item reads what the service reports
    // again within alertWakeMaxS (60 s) of monotonic time - the alert that expired meanwhile and
    // the set past its window included - however far the wall clock jumped. Nothing is fetched.
    @Test func alertStateFollowsSystemSleepOffline() async throws {
        let fx = try Fx("sleep")
        let p = try miami()
        let (m, service, fetcher) = try await offlineWithAlerts(fx, [p], soonAndLater)
        let maxS = AppModel.alertWakeMaxS
        await fx.advance(10)
        let deadlineUS = try #require(m.alertWakeDeadlineUS)
        #expect(deadlineUS - fx.clock.monotonicMicroseconds <= maxS * 1_000_000)
        for (label, jumpS) in [("a 2 h system sleep", Int64(2 * 3600)), ("the clock set 1 h forward", Int64(3600))] {
            fx.clock.advanceWall(by: jumpS * 1_000_000)
            #expect(m.place(forKey: p.key)?.alerts != service.result(for: p), "\(label) changed nothing")
            var lastDifferent: Int64 = 0
            for s in Int64(1) ... 3 * maxS {
                await fx.advance(1)
                if m.place(forKey: p.key)?.alerts != service.result(for: p) {
                    lastDifferent = s
                }
            }
            #expect(lastDifferent < maxS, "after \(label) the item read differently for \(lastDifferent) s")
        }
        // The sleep made the set stale and dropped "soon"; the jump forward expired "later".
        let item = try #require(m.place(forKey: p.key)).alerts
        #expect(item.state == .stale && item.alerts.isEmpty)
        #expect(fetcher.arrivals.count == 1)
        await m.flush()
    }

    // #43 a: the wall clock set back an hour while awake. The service's age has the monotonic
    // time since the answer as its floor, so the set turns stale 600 s after it arrived although
    // its wall-clock window end (and the expiry of "soon", current again) moved an hour away.
    // Visible and offline, the item follows within alertWakeMaxS; the units change right after
    // the set-back re-reads and re-arms (#43 c) off the 60 s grid of the earlier re-reads.
    @Test func alertStateFollowsClockSetBackOffline() async throws {
        let fx = try Fx("set-back")
        let p = try miami()
        let (m, service, fetcher) = try await offlineWithAlerts(fx, [p], soonAndLater)
        let maxS = AppModel.alertWakeMaxS
        await fx.advance(10)
        fx.clock.advanceWall(by: -3600 * 1_000_000)
        #expect(m.setUnits(.metric, forKey: p.key))
        var serviceCurrent: [Int64] = [], different: [Int64] = []
        for s in Int64(11) ... 1200 {  // monotonic seconds since the answer
            await fx.advance(1)
            let item = try #require(m.place(forKey: p.key)).alerts
            let truth = service.result(for: p)
            if truth.state == .current {
                serviceCurrent.append(s)
            }
            if item != truth {
                different.append(s)
            }
        }
        #expect(serviceCurrent.last == 599)  // the monotonic floor, not the wall clock, ended it
        #expect(different.allSatisfy { $0 >= 600 && $0 < 600 + maxS }, "differed at \(different)")
        let item = try #require(m.place(forKey: p.key)).alerts
        #expect(item.state == .stale && Set(item.alerts.map(\.id)) == ["nws:soon", "nws:later"])
        #expect(fetcher.arrivals.count == 1)
        await m.flush()
    }

    // #43 b: a system clock change (NSSystemClockDidChange posted to the model's center) makes
    // every item re-read at once - no clock advance, no fetch - and arms the wake-up from the
    // new wall time; posted on another thread, the items re-read on the main actor.
    @Test func systemClockChangeRereadsAtOnce() async throws {
        let fx = try Fx("clock-change")
        let t0 = fx.clock.wallSeconds
        let (m, service, fetcher) = try await offlineWithAlerts(fx, [try miami(), try orlando()], soonAndLater)
        let monoUS = fx.clock.monotonicMicroseconds
        fx.clock.advanceWall(by: 2 * 3600 * 1_000_000)
        #expect(m.places.allSatisfy { $0.alerts.state == .current && $0.alerts.alerts.count == 2 })
        fx.notifications.post(name: .NSSystemClockDidChange, object: nil)
        for item in m.places {
            #expect(item.alerts == service.result(for: item.place))
            #expect(item.alerts.state == .stale && item.alerts.alerts.map(\.id) == ["nws:later"])
        }
        #expect(m.alertWakeEdgeUS == (t0 + laterExpiryOffsetS) * 1_000_000)
        #expect(m.alertWakeDeadlineUS == monoUS + AppModel.alertWakeMaxS * 1_000_000)
        // Two more hours by the wall clock, posted off the main thread: "later" leaves too.
        fx.clock.advanceWall(by: 2 * 3600 * 1_000_000)
        let center = fx.notifications
        await Task.detached { center.post(name: .NSSystemClockDidChange, object: nil) }.value
        #expect(await settle { m.places.allSatisfy { $0.alerts.alerts.isEmpty } })
        #expect(m.places.allSatisfy { $0.alerts == service.result(for: $0.place) })
        #expect(fx.clock.monotonicMicroseconds == monoUS)
        #expect(fetcher.arrivals.count == 2)
        await m.flush()
    }

    // #43 c: every path that re-reads the items re-arms the wake-up for what they now show. After
    // a 2 h sleep, syncItems (another place's units change) re-reads the stale set, and the
    // wake-up is for that set's next edge ("later" expiring), not for the edge read before.
    @Test func syncItemsRereadRearmsWake() async throws {
        let fx = try Fx("rearm")
        let t0 = fx.clock.wallSeconds
        let p = try miami()
        let q = try orlando()
        let (m, service, _) = try await offlineWithAlerts(fx, [p, q], soonAndLater)
        #expect(m.alertWakeEdgeUS == (t0 + 300) * 1_000_000)
        await fx.advance(10)
        fx.clock.advanceWall(by: 2 * 3600 * 1_000_000)
        #expect(m.setUnits(.metric, forKey: q.key))
        #expect(m.place(forKey: p.key)?.alerts == service.result(for: p))
        #expect(m.place(forKey: p.key)?.alerts.state == .stale)
        #expect(m.alertWakeEdgeUS == (t0 + laterExpiryOffsetS) * 1_000_000)
        #expect(m.alertWakeDeadlineUS == fx.clock.monotonicMicroseconds + AppModel.alertWakeMaxS * 1_000_000)
        await m.flush()
    }

    // An answer arriving 0.4 s into a second: fetchedS (whole seconds) is 0.4 s before it, so its
    // window ends 0.4 s after fetchedS + 600 s. Visible and offline, the item reads current up to
    // that instant and stale from it, as the service does, at every 100 ms step (the wake-up
    // re-reads at fetchedS + 600 s, then every 10 ms of that second). Nothing is fetched.
    @Test func windowEndsInsideASecondOffline() async throws {
        let fx = try Fx("fraction")
        let p = try miami()
        await fx.clock.advance(by: 400_000)
        let (m, service, fetcher) = try await offlineWithAlerts(fx, [p], [soonAndLater[1]])
        let fetchedS = try #require(m.place(forKey: p.key)?.alerts.fetchedS)
        #expect(fx.clock.wallMicroseconds == fetchedS * 1_000_000 + 400_000)
        await fx.clock.advance(by: 600 * 1_000_000 - 500_000)  // fetchedS + 599.9 s
        var states: [WxAlertsResult.State] = []
        for _ in 0 ..< 10 {  // fetchedS + 600.0 s ... + 600.9 s
            await fx.clock.advance(by: 100_000)
            let item = try #require(m.place(forKey: p.key)).alerts
            #expect(item == service.result(for: p), "at \(fx.clock.wallMicroseconds - fetchedS * 1_000_000) us")
            states.append(item.state)
        }
        #expect(states == Array(repeating: .current, count: 4) + Array(repeating: .stale, count: 6))
        #expect(fetcher.arrivals.count == 1)
        await m.flush()
    }

    // A stale set's alerts still leave at their expiry: visible and offline past the window, the
    // remaining alert is dropped at the very second it expires (not at the next 60 s re-read),
    // by the wake-up alone, with no fetch.
    @Test func staleSetAlertExpiresOffline() async throws {
        let fx = try Fx("stale-expiry")
        let p = try miami()
        let (m, service, fetcher) = try await offlineWithAlerts(
            fx, [p], [soonAndLater[0], (id: "hour", expires: "2026-10-11T01:00:30Z", ends: nil)])
        await fx.advance(600)
        #expect(m.place(forKey: p.key)?.alerts.state == .stale)
        #expect(m.place(forKey: p.key)?.alerts.alerts.map(\.id) == ["nws:hour"])
        await fx.advance(3629 - 600)
        #expect(m.place(forKey: p.key)?.alerts.alerts.map(\.id) == ["nws:hour"])
        await fx.advance(1)  // T0 + 3630 s: "hour" expires
        let item = try #require(m.place(forKey: p.key)).alerts
        #expect(item == service.result(for: p))
        #expect(item.state == .stale && item.alerts.isEmpty)
        #expect(fetcher.arrivals.count == 1)
        await m.flush()
    }

    // MARK: Ownership pins (U51 iteration-2 handoffs: M6, M7, RMG)

    // A6 / #43: once shutdown has begun the alert wake-up stays disarmed - flush leaves none
    // armed, and neither a system clock change nor a result landing afterwards arms one again.
    @Test func noAlertWakeArmedAfterShutdown() async throws {
        let fx = try Fx("wake-after-shutdown")
        try fx.storePlaces([try miami()])
        let fake = FakeAlerts()
        let m = await fx.start(alerts: fake)
        await refreshed(m, 1)
        #expect(m.alertWakeDeadlineUS != nil)  // visible and loaded: armed (the 60 s re-read)
        #expect(await m.flush())
        #expect(m.alertWakeDeadlineUS == nil && m.alertWakeEdgeUS == nil)
        fx.notifications.post(name: .NSSystemClockDidChange, object: nil)
        #expect(m.alertWakeDeadlineUS == nil)
        fake.land(0, result(.current, alerts: [alert("late", expiresS: fx.clock.wallSeconds + 60)],
                            fetchedS: fx.clock.wallSeconds))
        #expect(await settle { m.alertKicksInFlight == 0 })
        #expect(m.alertWakeDeadlineUS == nil && m.alertWakeEdgeUS == nil)
    }

    // #43 b: the model removes its NSSystemClockDidChange observer when it goes away (isolated
    // deinit): the center keeps no block of a dead model, and a later post reaches none.
    @Test func clockObserverRemovedWhenModelGoesAway() async throws {
        let fx = try Fx("observer-deinit")
        try fx.storePlaces([try miami()])
        let center = fx.notifications
        weak var weakModel: AppModel?
        do {
            let m = await fx.start(alerts: FakeAlerts())
            weakModel = m
            await refreshed(m, 1)
            #expect(center.added.count == 1)
            #expect(center.removed.isEmpty)
            center.post(name: .NSSystemClockDidChange, object: nil)
            #expect(center.delivered == 1)
            fx.model = nil
        }
        #expect(await settle { weakModel == nil })
        #expect(center.added.count == 1)
        #expect(center.removed == center.added)
        center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(center.delivered == 1)  // no block left to run
    }

    // AppModel itself cancels and drops a removed place's alert waiter: with a service whose
    // remove(placeKey:) cancels nothing, the waiter is still cancelled at once, the other place's
    // is not, and the service's late answer for the removed place lands on nothing. (The service's
    // task is cancelled too, by the waiter's cancellation handler, but right after remove only if
    // the waiter has already started - else when it starts - so its state there is not asserted;
    // what the fake's remove(placeKey:) cancelled itself is.)
    @Test func removalCancelsWaiterWhateverTheService() async throws {
        let fx = try Fx("removal-model")
        try fx.storePlaces([try miami(), try orlando()])
        let fake = FakeAlerts()
        fake.removeCancelsKicks = false
        let m = await fx.start(alerts: fake)
        await refreshed(m, 2)
        let gone = try miami().key
        let kept = try orlando().key
        let goneWaiters = m.alertKickTasks(forKey: gone)
        let keptWaiters = m.alertKickTasks(forKey: kept)
        #expect(goneWaiters.count == 1 && keptWaiters.count == 1)
        #expect(m.remove(key: gone))
        #expect(fake.removed == [gone])
        let goneKick = try #require(fake.kicks.firstIndex { $0.place.key == gone })
        #expect(fake.removeCancels == 0)  // the service cancelled nothing
        #expect(goneWaiters.allSatisfy { $0.isCancelled })  // AppModel did
        #expect(!keptWaiters.contains { $0.isCancelled })
        #expect(m.alertKickTasks(forKey: gone).isEmpty)
        #expect(m.alertKicksInFlight == 1)
        fake.land(goneKick, result(.current, alerts: [alert("late", expiresS: fx.clock.wallSeconds + 600)],
                                   fetchedS: fx.clock.wallSeconds))
        for t in goneWaiters {
            await t.value
        }
        #expect(m.place(forKey: gone) == nil)
        #expect(m.place(forKey: kept)?.alerts == AppModel.alertsNotFetched)
        await m.flush()
    }
}
