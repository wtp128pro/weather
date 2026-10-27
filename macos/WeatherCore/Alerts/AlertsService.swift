// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsService.swift - the official alerts of each place: routes a place to
// the one keyless issuer that answers for it, fetches through an injected
// fetcher (the app's HTTP transport, a fake in tests), shares one MeteoAlarm
// country feed among all the places in that country, and publishes one result
// per place on the main actor. It never touches the forecast: AppModel kicks
// refresh(_:) after a forecast refresh and never awaits it; nothing here
// throws, and every failure becomes the place's "unavailable" result.
//
// Routing, by ISO 3166-1 country code (two ASCII letters, any case), exactly
// one source per place: the US and its territories to NWS, DE to DWD via
// Bright Sky, NO to MET Norway (WxAlert.pointSource), CA to Environment
// Canada, a country with a MeteoAlarm feed (WxAlertRegions.feedSlug, the only
// country -> feed table) to that feed; an empty code falls back to
// WxGeo.inUSNWS (NWS or nothing); anything else, a code that is not two ASCII
// letters included, is not covered. A MeteoAlarm place is covered only where
// WxAlertRegions.covers says so; any other place in that country is reported
// not covered and no feed is fetched for it.
//
// Cadence: nothing fetches except refresh(_:) (no timer), so an alert source
// is never asked more often than the forecast is refreshed. A country feed is
// fetched at most once per 30 minutes (feedWindowUS) however many places and
// refreshes ask: concurrent requests join the one in flight, later ones reuse
// its answer. A failed feed answer (a thrown error, the deadline, a non-2xx,
// unreadable or oversized body) is shared and reused the same way but only
// for failedFeedHoldUS (RefreshScheduler.freshUS, 120 s of the answer's age;
// the hold is time-based, not tied to a refresh round), so the places of a
// country asking within 120 s of it, those whose coverage check was still
// running when it arrived included, cost one download, and a later ask tries
// again: a round longer than 120 s can cost one more download per further
// 120 s. An attempt ended by cancelAll() is never reused (DECISIONS #35,
// #38). A point answer (NWS,
// Bright Sky, MET Norway, ECCC) younger than 5 minutes (pointReuseUS) is
// reused, so is one for another place at the same rounded point; a moved place
// has another point and is asked again; a failed point answer is not reused.
//
// Currency: a result is computed when it is asked for (result(for:)), against
// the injected clock: alerts whose message expired or whose event ended by
// then are left out (WxAlert.isCurrent), and an answer as old as its source's
// window or older (30 minutes for a feed, the forecast period
// RefreshScheduler.periodUS for a point source) is stale, never current. An
// age is wall-clock time, so a system sleep (during which monotonic time
// stands still) makes an answer stale; the monotonic time elapsed is its
// floor, so a wall clock set back does not make an old answer look new.
//
// Failure isolation: each fetch races a deadline on the injected clock
// (fetchTimeoutUS, above the transport's own) and the caller's cancellation,
// and returns as soon as one of the three ends, so a fetcher that hangs or
// ignores cancellation costs its places an "unavailable" result at the
// deadline and nothing else. A thrown error, a timeout, a cancellation, a body
// over the source's cap (feedMaxBytes for a feed, HTTPPolicy.maxBodyBytes for
// a point) and a parser's nil (an unreadable answer) are all "unavailable",
// never "no alerts" - except that a place whose previous alert set is still
// within its source's window keeps that set (current until the window passes,
// then stale) rather than lose a valid warning to one failed refetch
// (DECISIONS #35).
//
// Isolation: the service is @MainActor, like its owner (AppModel) and the
// views. refresh(_:) is then a synchronous call that cannot suspend, throw or
// wait; results are read without a hop; and the in-flight lookup-and-insert
// that shares a feed is atomic (no suspension point between the lookup and the
// insert), which is what keeps concurrent refreshes of one country to one
// download. The heavy work - waiting for the transport, decoding and parsing,
// the region table and point-in-polygon matching - runs in @concurrent
// functions (AlertsWork) on the global executor; only the finished answer is
// written back on the main actor.

import Foundation
import Observation
import Synchronization

/// One answer of an alert fetcher: the HTTP status and the (content-decoded) body.
public struct WxAlertsResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Fetches one alert URL of one source: the app's HTTP transport for that issuer's host. It
/// returns every HTTP answer with its status (an NWS 400 or a Bright Sky 404 body says "not
/// covered") and throws when there is none (offline, timeout, refused, body over the
/// transport's cap). It should honour cancellation; the service does not rely on it.
public typealias WxAlertsFetch = @Sendable (_ source: WxAlert.Source, _ url: String) async throws -> WxAlertsResponse

/// The alerts of one place as shown at one time.
public struct WxAlertsResult: Sendable, Equatable {
    /// Exactly one of these per place.
    public enum State: String, Sendable, CaseIterable {
        /// A source covers the place but no answer has been published yet (never refreshed,
        /// or the first refresh is still running).
        case notFetched
        /// The source's latest answer is within its window; `alerts` empty means no current
        /// alert.
        case current
        /// The latest answer is older than its source's window: never shown as current.
        case stale
        /// The latest attempt failed (error, timeout, cancellation, oversized or unreadable
        /// answer): alerts are not available, which is not "no alerts".
        case unavailable
        /// No source answers for the place, or the one routed to does not cover its point.
        case notCovered
    }

    public let state: State
    /// The one issuer routed to; nil when none covers the place's country.
    public let source: WxAlert.Source?
    /// The alerts of the answer still current at the time asked (expired and ended ones left
    /// out), highest level first; empty unless `.current` or `.stale`.
    public let alerts: [WxAlert]
    /// When the answer (or the failed attempt) arrived, UTC unix seconds; nil when there is none.
    public let fetchedS: Int64?

    public init(state: State, source: WxAlert.Source?, alerts: [WxAlert], fetchedS: Int64?) {
        self.state = state
        self.source = source
        self.alerts = alerts
        self.fetchedS = fetchedS
    }
}

/// The per-place alerts of the app (see the file comment).
@MainActor @Observable
public final class AlertsService {
    // MARK: Windows and caps

    /// A country feed is fetched at most once per this, and its answer is stale from this age,
    /// microseconds (30 minutes).
    nonisolated public static let feedWindowUS: Int64 = 30 * 60 * 1_000_000
    /// A failed feed answer younger than this is reused instead of fetched again, microseconds
    /// (120 s, the scheduler's freshness skip, below its period). Time-based: a round longer than
    /// 120 s can cost one more download per further 120 s.
    nonisolated public static let failedFeedHoldUS: Int64 = RefreshScheduler.freshUS
    /// A point answer younger than this is reused instead of fetched, microseconds (5 minutes).
    nonisolated public static let pointReuseUS: Int64 = 5 * 60 * 1_000_000
    /// A point answer is stale from the age of the forecast period, microseconds (600 s).
    nonisolated public static let pointWindowUS: Int64 = RefreshScheduler.periodUS
    /// The service's own deadline for one fetch, microseconds (120 s): a backstop above the
    /// transport's deadline (HTTPPolicy.totalDeadlineMs, 45 s) for a fetcher that never ends.
    nonisolated public static let fetchTimeoutUS: Int64 = 120 * 1_000_000
    /// The largest country feed body read (16 MiB; the Swiss feed is about 9 MB).
    nonisolated public static let feedMaxBytes = 16 * 1024 * 1024
    /// The largest point answer body read (the transport's general cap, 4 MiB).
    nonisolated public static let pointMaxBytes = HTTPPolicy.maxBodyBytes

    // MARK: State

    /// The latest published answer of each place (by WxPlace.key) with the source it came from.
    private var records: [String: Record] = [:]
    private let clock: any WxClock
    private let fetch: WxAlertsFetch
    private let observer: AlertsWork.Observer?
    /// The refresh running for each place; `id` tells a superseded or removed one.
    @ObservationIgnored private var running: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    /// Point answers by request URL, and the point fetches in flight.
    @ObservationIgnored private var pointCache: [String: AlertsAnswer<AlertsOutcome>] = [:]
    @ObservationIgnored private var pointInFlight: [String: (id: UInt64, task: Task<AlertsAnswer<AlertsOutcome>, Never>)] = [:]
    /// The latest feed answer by feed URL (nil warnings: a failed attempt), and the feed fetches
    /// in flight.
    @ObservationIgnored private var feedCache: [String: AlertsAnswer<[WxMeteoAlarm.Warning]?>] = [:]
    @ObservationIgnored private var feedInFlight: [String: (id: UInt64, task: Task<AlertsAnswer<[WxMeteoAlarm.Warning]?>, Never>)] = [:]
    @ObservationIgnored private var lastID: UInt64 = 0

    private struct Record {
        let source: WxAlert.Source
        let answer: AlertsAnswer<AlertsOutcome>
    }

    /// A service fetching through `fetch`, timing everything on `clock`.
    public convenience init(clock: any WxClock, fetch: @escaping WxAlertsFetch) {
        self.init(clock: clock, fetch: fetch, observer: nil)
    }

    /// As the public init; `observer` is told each stage of the work, where it runs (tests).
    init(clock: any WxClock, fetch: @escaping WxAlertsFetch, observer: AlertsWork.Observer?) {
        self.clock = clock
        self.fetch = fetch
        self.observer = observer
    }

    // MARK: Routing

    /// The one source that answers for `place`, nil when none covers its country (see the file
    /// comment). A `.meteoAlarm` place may still be not covered at its point.
    nonisolated public static func source(for place: WxPlace) -> WxAlert.Source? {
        source(countryCode: place.countryCode, lat: place.lat, lon: place.lon)
    }

    /// `source(for:)` of a country code (two ASCII letters, any case; empty: the point decides)
    /// and a point.
    nonisolated public static func source(countryCode: String, lat: Double, lon: Double) -> WxAlert.Source? {
        if countryCode.isEmpty {
            return WxGeo.inUSNWS(lat: lat, lon: lon) ? .nws : nil
        }
        // The ASCII check precedes uppercased(), which can fold a non-ASCII letter into an
        // ASCII one ("u\u{17F}" -> "US", "\u{FB01}" -> "FI"), as in WxGeo.defaultUnits.
        guard countryCode.count == 2, countryCode.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        let cc = countryCode.uppercased()
        if let point = WxAlert.pointSource(countryCode: cc) {
            return point
        }
        if cc == "CA" {
            return .eccc
        }
        return WxAlertRegions.feedSlug(countryCode: cc) != nil ? .meteoAlarm : nil
    }

    /// The request URL of `source` for a point (a MeteoAlarm place: its country's feed).
    nonisolated static func url(of source: WxAlert.Source, for place: WxPlace) -> String? {
        switch source {
        case .nws: WxPointAlerts.nwsURL(lat: place.lat, lon: place.lon)
        case .dwd: WxPointAlerts.brightSkyURL(lat: place.lat, lon: place.lon)
        case .metNorway: WxPointAlerts.metNorwayURL(lat: place.lat, lon: place.lon)
        case .eccc: WxECCCAlerts.url(lat: place.lat, lon: place.lon)
        case .meteoAlarm: WxAlertRegions.feedURL(countryCode: place.countryCode)
        }
    }

    // MARK: Refresh and results

    /// Starts updating the alerts of `place` in the background and returns at once; the
    /// result is published on the main actor when it is known. A refresh already running for
    /// the place is returned instead of starting another. The task never throws; awaiting it
    /// is optional (tests).
    @discardableResult
    public func refresh(_ place: WxPlace) -> Task<Void, Never> {
        let key = place.key
        if let current = running[key] {
            return current.task
        }
        guard let source = Self.source(for: place) else {
            records[key] = nil
            return Task {}
        }
        let id = nextID()
        let task = Task {
            let answer = source == .meteoAlarm
                ? await self.feedAnswer(for: place) : await self.pointAnswer(for: place, source: source)
            self.publish(answer, source: source, key: key, id: id)
        }
        running[key] = (id, task)
        return task
    }

    /// The alerts of `place` now: its state, and the alerts of its latest answer that are
    /// still current at the clock's wall time.
    public func result(for place: WxPlace) -> WxAlertsResult {
        guard let source = Self.source(for: place) else {
            return WxAlertsResult(state: .notCovered, source: nil, alerts: [], fetchedS: nil)
        }
        guard let record = records[place.key], record.source == source else {
            return WxAlertsResult(state: .notFetched, source: source, alerts: [], fetchedS: nil)
        }
        let fetchedS = record.answer.wallUS / 1_000_000
        switch record.answer.value {
        case .unavailable:
            return WxAlertsResult(state: .unavailable, source: source, alerts: [], fetchedS: fetchedS)
        case .notCovered:
            return WxAlertsResult(state: .notCovered, source: source, alerts: [], fetchedS: fetchedS)
        case .alerts(let alerts):
            let nowS = clock.wallSeconds
            return WxAlertsResult(state: isWithinWindow(record) ? .current : .stale, source: source,
                                  alerts: alerts.filter { $0.isCurrent(atS: nowS) }, fetchedS: fetchedS)
        }
    }

    /// Forgets a removed place (by WxPlace.key) and cancels its running refresh; a fetch it
    /// shares with other places goes on.
    public func remove(placeKey: String) {
        running.removeValue(forKey: placeKey)?.task.cancel()
        records[placeKey] = nil
    }

    /// Cancels every running refresh and fetch (shutdown): the places waiting for them become
    /// unavailable (or keep an in-window alert set), and nothing cancelled is reused later.
    public func cancelAll() {
        for entry in running.values {
            entry.task.cancel()
        }
        for entry in pointInFlight.values {
            entry.task.cancel()
        }
        for entry in feedInFlight.values {
            entry.task.cancel()
        }
        pointInFlight.removeAll()
        feedInFlight.removeAll()
    }

    // MARK: Work

    private func nextID() -> UInt64 {
        lastID += 1
        return lastID
    }

    /// The wall-clock time since `answer` arrived, microseconds, but never less than the
    /// monotonic time since (a wall clock set back does not make an answer younger).
    private func age<Value>(of answer: AlertsAnswer<Value>) -> Int64 {
        max(clock.wallMicroseconds - answer.wallUS, clock.monotonicMicroseconds - answer.monoUS)
    }

    /// Whether a place's alert set is younger than its source's window (current, not stale).
    private func isWithinWindow(_ record: Record) -> Bool {
        age(of: record.answer) < (record.source == .meteoAlarm ? Self.feedWindowUS : Self.pointWindowUS)
    }

    /// An answer arriving now.
    private func now(_ outcome: AlertsOutcome) -> AlertsAnswer<AlertsOutcome> {
        AlertsAnswer(value: outcome, wallUS: clock.wallMicroseconds, monoUS: clock.monotonicMicroseconds)
    }

    /// Writes a place's answer unless its refresh was removed or superseded meanwhile. An
    /// unavailable answer does not replace an alert set of the same source still within its
    /// window (DECISIONS #35): that set stays, current until its window passes, then stale.
    private func publish(_ answer: AlertsAnswer<AlertsOutcome>, source: WxAlert.Source, key: String, id: UInt64) {
        guard running[key]?.id == id else {
            return
        }
        running[key] = nil
        observer?(.publish)
        if answer.value == .unavailable, let previous = records[key], previous.source == source,
           case .alerts = previous.answer.value, isWithinWindow(previous) {
            return
        }
        records[key] = Record(source: source, answer: answer)
    }

    /// A point source's answer for `place`: reused when younger than pointReuseUS, else the
    /// fetch in flight for the same URL, else a new one.
    private func pointAnswer(for place: WxPlace, source: WxAlert.Source) async -> AlertsAnswer<AlertsOutcome> {
        guard let url = Self.url(of: source, for: place) else {
            return now(.notCovered)
        }
        if let cached = pointCache[url], age(of: cached) < Self.pointReuseUS {
            return cached
        }
        let shared = pointInFlight[url]?.task ?? startPoint(url, source: source)
        observer?(.wait)
        return await AlertsWork.value(of: shared) ?? now(.unavailable)
    }

    private func startPoint(_ url: String, source: WxAlert.Source) -> Task<AlertsAnswer<AlertsOutcome>, Never> {
        let id = nextID()
        let (fetch, clock, observer) = (self.fetch, self.clock, self.observer)
        let task = Task {
            let answer = await AlertsWork.loadPoint(source, url: url, fetch: fetch, clock: clock, observer: observer)
            if self.pointInFlight[url]?.id == id {
                self.pointInFlight[url] = nil
                if answer.value != .unavailable {
                    self.pointCache = self.pointCache.filter { self.age(of: $0.value) < Self.pointReuseUS }
                    self.pointCache[url] = answer
                }
            }
            return answer
        }
        pointInFlight[url] = (id, task)
        return task
    }

    /// A MeteoAlarm place's answer: not covered (and nothing fetched) outside the regions its
    /// country's feed files, else its feed - the latest answer while it is reused, else the
    /// fetch in flight, else a new one - matched to the point.
    private func feedAnswer(for place: WxPlace) async -> AlertsAnswer<AlertsOutcome> {
        let cc = place.countryCode.uppercased()
        guard let url = WxAlertRegions.feedURL(countryCode: cc) else {
            return now(.notCovered)
        }
        let covered = await AlertsWork.covers(countryCode: cc, lat: place.lat, lon: place.lon, observer: observer)
        if Task.isCancelled {
            return now(.unavailable)
        }
        guard covered else {
            return now(.notCovered)
        }
        let feed: AlertsAnswer<[WxMeteoAlarm.Warning]?>
        if let cached = feedCache[url], isReused(cached) {
            feed = cached
        } else {
            let shared = feedInFlight[url]?.task ?? startFeed(url)
            observer?(.wait)
            guard let answer = await AlertsWork.value(of: shared) else {
                return now(.unavailable)
            }
            feed = answer
        }
        guard let warnings = feed.value else {
            return AlertsAnswer(value: .unavailable, wallUS: feed.wallUS, monoUS: feed.monoUS)
        }
        let outcome = await AlertsWork.match(warnings, lat: place.lat, lon: place.lon, clock: clock, observer: observer)
        return AlertsAnswer(value: outcome, wallUS: feed.wallUS, monoUS: feed.monoUS)
    }

    /// Whether a feed answer is reused instead of fetched: a usable one within feedWindowUS, a
    /// failed one within failedFeedHoldUS (120 s of its age; a later ask fetches again).
    private func isReused(_ feed: AlertsAnswer<[WxMeteoAlarm.Warning]?>) -> Bool {
        age(of: feed) < (feed.value == nil ? Self.failedFeedHoldUS : Self.feedWindowUS)
    }

    /// Starts the one fetch of a feed. Its answer, a failed one too, is kept for the places
    /// asking after it (isReused) unless cancelAll() ended it meanwhile.
    private func startFeed(_ url: String) -> Task<AlertsAnswer<[WxMeteoAlarm.Warning]?>, Never> {
        let id = nextID()
        let (fetch, clock, observer) = (self.fetch, self.clock, self.observer)
        let task = Task {
            let answer = await AlertsWork.loadFeed(url, fetch: fetch, clock: clock, observer: observer)
            if self.feedInFlight[url]?.id == id {
                self.feedInFlight[url] = nil
                self.feedCache[url] = answer
            }
            return answer
        }
        feedInFlight[url] = (id, task)
        return task
    }
}

// MARK: - Answers

/// What one answer says about a place, before the expiry filter of the time it is shown.
enum AlertsOutcome: Sendable, Equatable {
    /// Covered: the alerts current when it arrived (empty: no alerts).
    case alerts([WxAlert])
    /// The source does not cover the point.
    case notCovered
    /// No usable answer.
    case unavailable

    /// A parser's coverage (nil: unreadable, so unavailable).
    init(_ coverage: WxAlertCoverage?) {
        switch coverage {
        case .alerts(let alerts): self = .alerts(alerts)
        case .noAlerts: self = .alerts([])
        case .notCovered: self = .notCovered
        case nil: self = .unavailable
        }
    }
}

/// An answer and when it arrived (wall and monotonic microseconds of the injected clock).
/// A usable one is cached (pointReuseUS, feedWindowUS), a failed feed answer only for
/// failedFeedHoldUS; a failed point answer and an attempt ended by cancelAll() are not kept.
struct AlertsAnswer<Value: Sendable>: Sendable {
    let value: Value
    let wallUS: Int64
    let monoUS: Int64
}

// MARK: - Off the main actor

/// The work of AlertsService that must not run on the main actor: every function that waits
/// for the transport, decodes, parses or matches is @concurrent (the global executor whatever
/// the caller's isolation).
enum AlertsWork {
    /// A stage of the work, reported to a test observer from where it runs.
    enum Stage: Sendable, Equatable {
        /// Asking the region table whether MeteoAlarm covers a point.
        case covers
        /// A place starting to wait for a fetch in flight (main-actor bookkeeping).
        case wait
        /// Decoding and parsing an answer of this source.
        case parse(WxAlert.Source)
        /// Matching a feed's warnings to a point.
        case match
        /// Writing a place's answer (main actor).
        case publish
    }

    typealias Observer = @Sendable (Stage) -> Void

    /// How one fetch ended.
    enum Fetched: Sendable {
        case response(WxAlertsResponse)
        /// The fetcher threw (whatever the error, its own CancellationError included).
        case failed
        /// The deadline passed first.
        case timedOut
        /// The caller was cancelled first.
        case cancelled
    }

    /// Fetches `url`, returning when the fetcher answers or throws, the deadline
    /// (`AlertsService.fetchTimeoutUS` on `clock`) passes, or the caller is cancelled -
    /// whichever comes first; it never waits for a fetcher that ignores cancellation (that
    /// fetch is cancelled and left to end on its own).
    @concurrent
    static func fetchBounded(_ fetch: @escaping WxAlertsFetch, _ source: WxAlert.Source, url: String,
                             clock: any WxClock) async -> Fetched {
        if Task.isCancelled {
            return .cancelled
        }
        let deadline = clock.monotonicMicroseconds + AlertsService.fetchTimeoutUS
        let first = FirstOf<Fetched>()
        let fetching = Task {
            do {
                let response = try await fetch(source, url)
                first.resolve(.response(response))
            } catch {
                first.resolve(.failed)
            }
        }
        let timer = Task {
            do {
                try await clock.sleep(until: deadline)
                first.resolve(.timedOut)
            } catch {
                // Cancelled: the fetch ended first.
            }
        }
        let fetched = await withTaskCancellationHandler {
            await withCheckedContinuation { first.wait($0) }
        } onCancel: {
            first.resolve(.cancelled)
        }
        fetching.cancel()
        timer.cancel()
        return fetched
    }

    /// Fetches and parses a point source's answer.
    @concurrent
    static func loadPoint(_ source: WxAlert.Source, url: String, fetch: @escaping WxAlertsFetch,
                          clock: any WxClock, observer: Observer?) async -> AlertsAnswer<AlertsOutcome> {
        let fetched = await fetchBounded(fetch, source, url: url, clock: clock)
        let wallUS = clock.wallMicroseconds, monoUS = clock.monotonicMicroseconds
        var outcome = AlertsOutcome.unavailable
        if case .response(let r) = fetched, r.body.count <= AlertsService.pointMaxBytes {
            observer?(.parse(source))
            let nowS = clock.wallSeconds
            switch source {
            case .nws: outcome = AlertsOutcome(WxPointAlerts.parseNWS(r.body, status: r.status, nowS: nowS))
            case .dwd: outcome = AlertsOutcome(WxPointAlerts.parseBrightSky(r.body, status: r.status, nowS: nowS))
            case .metNorway: outcome = AlertsOutcome(WxPointAlerts.parseMETNorway(r.body, status: r.status, nowS: nowS))
            case .eccc: outcome = AlertsOutcome(WxECCCAlerts.parse(r.body, status: r.status, nowS: nowS))
            case .meteoAlarm: outcome = .unavailable  // not a point source
            }
        }
        return AlertsAnswer(value: outcome, wallUS: wallUS, monoUS: monoUS)
    }

    /// Fetches and parses a country feed: its current warnings, nil when unavailable.
    @concurrent
    static func loadFeed(_ url: String, fetch: @escaping WxAlertsFetch, clock: any WxClock,
                         observer: Observer?) async -> AlertsAnswer<[WxMeteoAlarm.Warning]?> {
        let fetched = await fetchBounded(fetch, .meteoAlarm, url: url, clock: clock)
        let wallUS = clock.wallMicroseconds, monoUS = clock.monotonicMicroseconds
        var warnings: [WxMeteoAlarm.Warning]?
        if case .response(let r) = fetched, r.body.count <= AlertsService.feedMaxBytes {
            observer?(.parse(.meteoAlarm))
            warnings = WxMeteoAlarm.parse(r.body, status: r.status, nowS: clock.wallSeconds)
        }
        return AlertsAnswer(value: warnings, wallUS: wallUS, monoUS: monoUS)
    }

    /// Whether MeteoAlarm covers the point (the first call loads the region table).
    @concurrent
    static func covers(countryCode: String, lat: Double, lon: Double, observer: Observer?) async -> Bool {
        observer?(.covers)
        return WxAlertRegions.covers(countryCode: countryCode, lat: lat, lon: lon)
    }

    /// The warnings of a feed that apply to the point, current at the clock's time.
    @concurrent
    static func match(_ warnings: [WxMeteoAlarm.Warning], lat: Double, lon: Double, clock: any WxClock,
                      observer: Observer?) async -> AlertsOutcome {
        observer?(.match)
        let placed = warnings.filter { WxAlertRegions.matches($0.areas.map(regionArea), lat: lat, lon: lon) }
        return .alerts(WxAlertCoverage.covered(placed.map(\.alert), nowS: clock.wallSeconds).alerts)
    }

    /// A feed area as the region matcher takes it (geocode valueName -> type, value -> code).
    static func regionArea(_ area: WxMeteoAlarm.Area) -> WxAlertRegions.Area {
        WxAlertRegions.Area(
            polygons: area.polygons.map { $0.map { WxAlertRegions.Point(lat: $0.lat, lon: $0.lon) } },
            geocodes: area.geocodes.map { WxAlertRegions.Geocode(type: $0.name, code: $0.value) })
    }

    /// The value of a task shared by several places, or nil as soon as the caller is cancelled
    /// (the shared task goes on for the others).
    static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
        if Task.isCancelled {
            return nil
        }
        let first = FirstOf<T?>()
        let waiting = Task {
            let value = await task.value
            first.resolve(value)
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { first.wait($0) }
        } onCancel: {
            first.resolve(nil)
        }
        waiting.cancel()
        return value
    }
}

/// The first of several racing results: later ones are dropped, and the one waiter is resumed
/// exactly once, whether it starts waiting before or after the first result.
final class FirstOf<T: Sendable>: Sendable {
    private struct State {
        var result: T?
        var resolved = false
        var waiter: CheckedContinuation<T, Never>?
    }

    private let state = Mutex(State())

    /// Offers a result; ignored when one was offered already.
    func resolve(_ value: T) {
        let waiter: CheckedContinuation<T, Never>? = state.withLock { s in
            if s.resolved {
                return nil
            }
            s.resolved = true
            s.result = value
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: value)
    }

    /// Resumes `continuation` with the first result, now or when it is offered.
    func wait(_ continuation: CheckedContinuation<T, Never>) {
        let ready: T?? = state.withLock { s in
            if s.resolved {
                return .some(s.result)
            }
            s.waiter = continuation
            return .none
        }
        if case .some(.some(let value)) = ready {
            continuation.resume(returning: value)
        }
    }
}
