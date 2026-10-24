// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// METNorwayProvider.swift - the network half of the MET Norway locationforecast
// 2.0 "complete" provider (C: src/providers/metno/wx-metno.c, WxMetno): the
// polite per-place cache, the 10-minute request floor, the 60 s throttle after
// HTTP 429, shared requests per place, the in-flight cap and cancellation, on
// one HTTPClient. The pure rules (request target, cache key, freshness, Expires
// cap, floor and throttle tests, Last-Modified bookkeeping, the parser) are
// METNorwayParse (U20); this file composes them in metno_fetch_async order.
//
// Contract (wx-metno.h:3-123), as ported:
//  - Identity: id "met-no", name "MET Norway", attribution "Data from MET
//    Norway", attribution URL "https://api.met.no/" (wx-metno.c:1018, :1040,
//    :1062, :1084); covers every place with valid coordinates.
//  - Production traffic goes only to METNorwayParse.baseURL
//    ("https://api.met.no"): `init(clock:)` builds the one HTTPClient from that
//    constant and nothing else. Other origins (loopback http for tests) exist
//    only through the internal `init(testingBaseURL:...)`, the counterpart of
//    wx_metno_new_custom, which only the test bundle reaches (@testable).
//  - One GET per refresh: METNorwayParse.forecastPath (coordinates "%.4f"),
//    Accept "application/json", If-Modified-Since = the entry's Last-Modified.
//  - Cache: at most METNorwayParse.cacheMax places keyed by the "%.4f" texts;
//    an entry is fresh while fewer than 600 s passed since its last successful
//    answer or before its Expires time (capped at 24 h after that answer); a
//    fresh entry is served with no traffic; LRU eviction ("used" = stored or
//    served); a 304 renews the entry with the validated member (also after an
//    eviction); a failure changes no entry.
//  - Floor: a per-place record of the clock reading at which a request was
//    handed to the HTTP client (answered, failed or cancelled); within 600 s
//    the stale entry is served, or RATE_LIMITED "a request for this place was
//    sent less than 10 minutes ago" without one; at most cacheMax records,
//    the oldest dropped first; a record in the future of the clock is ignored.
//  - Throttle: after a RATE_LIMITED answer no new request for 60 s (RATE_LIMITED
//    "requests are paused after HTTP 429"); keyed on the error CODE as C does
//    (wx-metno.c:980-981). Fresh/floor serving, joining and requests already in
//    flight are not affected; a clock earlier than the 429 lifts it.
//  - Shared requests: concurrent fetches of one place wait for one request;
//    it is cancelled only when every waiter has been cancelled; a fetch after
//    that does not join it.
//  - In-flight cap: at most HTTPPolicy.maxInflight outstanding requests per
//    provider; the next fetch that needs a request fails at once with
//    RATE_LIMITED "too many outstanding requests (limit 16)" (no throttle).
//
// TWO CLOCKS (as in C): the HTTP client parses Expires against its own clock's
// wall time (C: WxHttp, g_get_real_time(), wx-http.c:1403-1404); the provider
// reads `clock` (C: clock_now_s, the test hook) for the floor, freshness, the
// 24 h cap and the throttle. Expires text is never re-parsed here.
//
// Swift mapping:
//  - GCancellable -> task cancellation; a fetch whose task is cancelled before
//    it returns throws CancellationError, also when its outcome was already
//    available (wx-provider.h:32-35; U14 contract).
//  - The C provider is main-thread only; here the state lives behind one
//    Mutex and each request runs in its own unstructured Task (the "flight"),
//    which holds the provider alive until it has finished (C: the flight's
//    provider reference).
//  - The C test hook wx_metno_test_set_clock (a process-wide writable function
//    pointer in the test flavour only) becomes the injected, immutable `clock`.

import Foundation
import Synchronization

/// The MET Norway provider (C: WxMetno). Create one and share it; it is safe to
/// use from any task.
public final class METNorwayProvider: WxProvider {

    // MARK: Identity (wx-metno.c:1014-1133)

    public var id: String { METNorwayParse.providerID }
    public var name: String { "MET Norway" }
    public var attribution: String { "Data from MET Norway" }
    public var attributionURL: String { "https://api.met.no/" }

    /// The one HTTP client of the provider (C: self->http).
    let http: HTTPClient
    /// The provider's time source (C: clock_now_s).
    let clock: any WxClock
#if DEBUG
    /// Test-only probe run when a fetch has its outcome, right before the
    /// cancellation check that decides what it returns (lets a test cancel a
    /// fetch "between completion and finish", test-metno.c:3654-3670). Always
    /// nil in production; immutable once constructed.
    private let outcomeProbe: (@Sendable () -> Void)?
    /// Test-only probe run in `runFlight` after parsing the response and before
    /// the final lock that commits the result to the cache.
    private let parseProbe: (@Sendable () -> Void)?
#endif
    private let state = Mutex(State())

    // MARK: Construction (wx-metno.c:1248-1270)

    /// wx_metno_new: the production provider, talking to METNorwayParse.baseURL
    /// ("https://api.met.no") with the default HTTP timing (HTTPPolicy) and an
    /// empty cache. `clock` is the provider's clock (floor, freshness, Expires
    /// cap, throttle); the HTTP client keeps the system clock, as WxHttp did.
    public convenience init(clock: any WxClock = SystemClock()) {
        let http: HTTPClient
        do {
            http = try HTTPClient(
                baseURL: METNorwayParse.baseURL, userAgent: METNorwayParse.userAgent,
                timeoutMs: HTTPPolicy.timeoutMs, backoffBaseMs: HTTPPolicy.backoffBaseMs, minGapMs: 0,
                clock: SystemClock())
        } catch {
            // C: g_assert_no_error - constants the HTTP client accepts.
            preconditionFailure("METNorwayParse.baseURL refused: \(error)")
        }
        self.init(http: http, clock: clock)
    }

#if DEBUG
    /// wx_metno_new_custom (TEST ONLY, reached through @testable): another
    /// origin or timing, e.g. a loopback fake server and short delays. The
    /// origin is validated by HTTPClientPolicy ("https://" origins, "http://"
    /// only towards 127.0.0.1, ::1 or localhost); a refused origin or timing is
    /// WxError .invalidArg. `clock` is the provider's clock, `httpClock` the
    /// HTTP client's (deadlines, back-off and the Expires reference time).
    init(
        testingBaseURL baseURL: String, timeoutMs: Int, backoffBaseMs: Int,
        clock: any WxClock, httpClock: any WxClock = SystemClock(),
        outcomeProbe: (@Sendable () -> Void)? = nil,
        parseProbe: (@Sendable () -> Void)? = nil
    ) throws(WxError) {
        let http = try HTTPClient(
            baseURL: baseURL, userAgent: METNorwayParse.userAgent, timeoutMs: timeoutMs,
            backoffBaseMs: backoffBaseMs, minGapMs: 0, clock: httpClock)
        self.http = http
        self.clock = clock
        self.outcomeProbe = outcomeProbe
        self.parseProbe = parseProbe
    }
#endif

    private init(http: HTTPClient, clock: any WxClock) {
        self.http = http
        self.clock = clock
#if DEBUG
        self.outcomeProbe = nil
        self.parseProbe = nil
#endif
    }

    // MARK: WxProvider

    /// metno_covers: every place with valid coordinates (wx_geo_valid).
    public func covers(_ place: WxPlace) -> Bool {
        WxGeo.isValid(lat: place.lat, lon: place.lon)
    }

    /// metno_fetch_async + metno_fetch_finish (wx-metno.c:1135-1232): a fresh
    /// entry is answered at once, a fetch joins the request in flight for the
    /// place, the floor serves the stale entry or refuses, then the throttle
    /// and the in-flight cap may refuse, and otherwise a request is started
    /// (only a started request makes a floor record).
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   this returns; otherwise `WxError` (RATE_LIMITED for the floor, the
    ///   throttle and the cap; the HTTP client's errors; the parser's errors).
    public func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        let call = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        // The handler covers the whole decision, so a cancellation that comes
        // while this call waits for a flight removes it at once (C: the waiter's
        // cancellable source; flight_is_abandoned is then never needed).
        let outcome = await withTaskCancellationHandler {
            await self.decideAndWait(place, call: call)
        } onCancel: {
            self.cancelWaiter(call)
        }
#if DEBUG
        outcomeProbe?()
#endif
        // A cancelled task always gets CancellationError (wx-provider.h:32-35).
        try Task.checkCancellation()
        switch outcome {
        case .member(let member):
            var result = try WxSourceResult(providerID: METNorwayParse.providerID)
            result.members = [member]
            return result
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    // MARK: State

    /// What the last successful answer for one place left behind (C: CacheEntry).
    private struct CacheEntry {
        var member: WxMember
        var lastModified: String?
        /// Validated Expires time, already capped (<= checkedS + 24 h), 0 = none.
        var expiresS: Int64
        var checkedS: Int64
        var used: UInt64
    }

    /// When the last request for one place was handed to the HTTP client (C: RequestRecord).
    private struct RequestRecord {
        var sentS: Int64
        var used: UInt64
    }

    /// One request for one place and the fetches waiting for it (C: Flight).
    private struct Flight {
        let key: String
        /// If-Modified-Since sent, nil when none.
        let ims: String?
        /// The member that validator belongs to, nil when no validator.
        let base: WxMember?
        var waiters: Set<UInt64> = []
        var task: Task<Void, Never>?
    }

    /// One fetch waiting for a flight (C: Waiter).
    private enum Waiter {
        /// Added to the flight; its continuation is not installed yet.
        case added(flight: UInt64)
        case waiting(flight: UInt64, CheckedContinuation<Outcome, Never>)
        /// Completed (or cancelled) before its continuation was installed.
        case finished(Outcome)
    }

    /// The outcome a fetch is completed with.
    private enum Outcome: Sendable {
        case member(WxMember)
        case failure(WxError)
        case cancelled
    }

    private struct State {
        var cache: [String: CacheEntry] = [:]
        var records: [String: RequestRecord] = [:]
        /// Listed flights (C: WxMetno::flights): key -> flight id.
        var listed: [String: UInt64] = [:]
        /// Every flight whose request is not finished, listed or not.
        var flights: [UInt64: Flight] = [:]
        var waiters: [UInt64: Waiter] = [:]
        /// Requests whose HTTP operation is not yet released (C: outstanding).
        var outstanding = 0
        /// Source of the LRU stamps (C: tick).
        var tick: UInt64 = 0
        /// No new request before this clock reading (after an HTTP 429).
        var throttleUntilS: Int64 = 0
        /// Source of call and flight ids.
        var nextID: UInt64 = 0

        /// cache_store (wx-metno.c:479-512).
        mutating func store(_ key: String, _ member: WxMember, lastModified: String?, expiresS: Int64, nowS: Int64) {
            if cache[key] == nil, cache.count >= METNorwayParse.cacheMax,
               let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key {
                cache[oldest] = nil
            }
            tick += 1
            cache[key] = CacheEntry(
                member: member, lastModified: lastModified,
                expiresS: METNorwayParse.storedExpiresS(expiresS, answerS: nowS), checkedS: nowS, used: tick)
        }

        /// request_record (wx-metno.c:561-590).
        mutating func record(_ key: String, nowS: Int64) {
            if records[key] == nil, records.count >= METNorwayParse.cacheMax,
               let oldest = records.min(by: { $0.value.used < $1.value.used })?.key {
                records[oldest] = nil
            }
            tick += 1
            records[key] = RequestRecord(sentS: nowS, used: tick)
        }

        /// flight_delist (wx-metno.c:654-661).
        mutating func delist(_ flightID: UInt64) {
            guard let key = flights[flightID]?.key, listed[key] == flightID else { return }
            listed[key] = nil
        }
    }

    /// clock_now_s (wx-metno.c:60-69): UTC seconds, clamped to [0, Int64.max / 4].
    private func nowS() -> Int64 {
        METNorwayParse.clampedClockS(clock.wallSeconds)
    }

    // MARK: Fetch

    private enum Decision {
        case done(Outcome)
        case wait
        case start(flight: UInt64, path: String, ims: String?, base: WxMember?, key: String)
    }

    /// The decision of metno_fetch_async under the lock, then the wait for the
    /// flight when the fetch joined or started one.
    private func decideAndWait(_ place: WxPlace, call: UInt64) async -> Outcome {
        // wx_place_copy() refused it (wx-metno.c:1144-1147); unreachable for a WxPlace.
        guard let texts = METNorwayParse.coordinateTexts(lat: place.lat, lon: place.lon),
              let path = METNorwayParse.forecastPath(lat: place.lat, lon: place.lon)
        else {
            return .failure(WxError(.invalidArg, "invalid place"))
        }
        let key = texts.lat + "," + texts.lon
        let decision: Decision = state.withLock { s in
            // g_task_return_error_if_cancelled (:1148-1149).
            if Task.isCancelled {
                return .done(.cancelled)
            }
            let now = nowS()
            if var entry = s.cache[key],
               METNorwayParse.entryIsFresh(nowS: now, checkedS: entry.checkedS, expiresS: entry.expiresS) {
                s.tick += 1
                entry.used = s.tick
                s.cache[key] = entry
                return .done(.member(entry.member))
            }
            if let flightID = s.listed[key] {
                s.flights[flightID]?.waiters.insert(call)
                s.waiters[call] = .added(flight: flightID)
                return .wait
            }
            if METNorwayParse.floorApplies(nowS: now, sentS: s.records[key]?.sentS) {
                if var entry = s.cache[key] {
                    s.tick += 1
                    entry.used = s.tick
                    s.cache[key] = entry
                    return .done(.member(entry.member))
                }
                return .done(.failure(WxError(.rateLimited, METNorwayParse.Message.floorRefused)))
            }
            if METNorwayParse.throttleApplies(nowS: now, untilS: s.throttleUntilS) {
                return .done(.failure(WxError(.rateLimited, METNorwayParse.Message.throttled)))
            }
            if s.outstanding >= HTTPPolicy.maxInflight {
                return .done(.failure(WxError(.rateLimited, HTTPPolicy.Message.tooManyOutstanding)))
            }
            // flight_new + request_record + flight_add_waiter (:1186-1188).
            let entry = s.cache[key]
            let validated = entry?.lastModified != nil
            s.nextID += 1
            let flightID = s.nextID
            var flight = Flight(
                key: key, ims: validated ? entry?.lastModified : nil, base: validated ? entry?.member : nil)
            flight.waiters.insert(call)
            s.flights[flightID] = flight
            s.listed[key] = flightID
            s.outstanding += 1
            s.record(key, nowS: now)
            s.waiters[call] = .added(flight: flightID)
            return .start(flight: flightID, path: path, ims: flight.ims, base: flight.base, key: key)
        }
        switch decision {
        case .done(let outcome):
            return outcome
        case .wait:
            break
        case .start(let flightID, let path, let ims, let base, let key):
            let task = Task {
                await self.runFlight(flightID, key: key, path: path, ims: ims, base: base)
            }
            let abandoned = state.withLock { s in
                guard s.flights[flightID] != nil else { return false }
                s.flights[flightID]?.task = task
                return s.flights[flightID]?.waiters.isEmpty ?? false
            }
            if abandoned {
                task.cancel()  // every waiter was cancelled before the handle was stored
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let ready: Outcome? = state.withLock { s in
                switch s.waiters[call] {
                case .added(let flightID):
                    s.waiters[call] = .waiting(flight: flightID, continuation)
                    return nil
                case .finished(let outcome):
                    s.waiters[call] = nil
                    return outcome
                case .waiting, nil:
                    return .cancelled  // unreachable: each call installs one continuation
                }
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// on_waiter_cancelled (wx-metno.c:736-755): the fetch `call` leaves its
    /// flight with CancellationError; when it was the last waiter the flight is
    /// delisted and its request cancelled.
    private func cancelWaiter(_ call: UInt64) {
        let (continuation, task): (CheckedContinuation<Outcome, Never>?, Task<Void, Never>?) = state.withLock { s in
            let flightID: UInt64
            var continuation: CheckedContinuation<Outcome, Never>?
            switch s.waiters[call] {
            case .added(let id):
                flightID = id
                s.waiters[call] = .finished(.cancelled)
            case .waiting(let id, let c):
                flightID = id
                continuation = c
                s.waiters[call] = nil
            case .finished, nil:
                return (nil, nil)
            }
            s.flights[flightID]?.waiters.remove(call)
            guard let flight = s.flights[flightID], flight.waiters.isEmpty else {
                return (continuation, nil)
            }
            s.delist(flightID)
            return (continuation, flight.task)
        }
        continuation?.resume(returning: .cancelled)
        task?.cancel()
    }

    // MARK: Flight

    /// wx_http_get_async + on_http_done + flight_resolve (wx-metno.c:927-1003):
    /// one request; then the cache or the throttle is updated and every waiter
    /// is completed with the same outcome; the slot is released last.
    private func runFlight(_ flightID: UInt64, key: String, path: String, ims: String?, base: WxMember?) async {
        var outcome: Outcome
        var response: HTTPClient.Response?
        do {
            response = try await http.get(path, accept: METNorwayParse.accept, ifModifiedSince: ims)
            outcome = .cancelled  // replaced below
        } catch let error as WxError {
            outcome = .failure(error)
        } catch {
            outcome = .cancelled
        }
        // C: a cancelled flight is finished by WxHttp with G_IO_ERROR_CANCELLED
        // (cancel before finish wins), so it stores nothing and starts no throttle.
        if Task.isCancelled {
            outcome = .cancelled
            response = nil
        }
        let now = nowS()
        var storeLastModified: String?
        if let response {
            if response.status == 304, let base {
                outcome = .member(base)
                storeLastModified = METNorwayParse.lastModifiedToStore(
                    status: response.status, revalidated: true, responseLastModified: response.lastModified,
                    sentIfModifiedSince: ims)
            } else {
                // A 304 without validator cannot come from the client; it would be an
                // empty body, hence a parse error (flight_resolve comment).
                do throws(WxError) {
                    outcome = .member(try METNorwayParse.parseForecast(response.body, fetchedS: now))
                    storeLastModified = METNorwayParse.lastModifiedToStore(
                        status: response.status, revalidated: false, responseLastModified: response.lastModified,
                        sentIfModifiedSince: ims)
                } catch {
                    outcome = .failure(error)
                }
            }
        }
#if DEBUG
        parseProbe?()
#endif
        let resolvedOutcome = outcome
        let (continuations, resolved): ([CheckedContinuation<Outcome, Never>], Outcome) = state.withLock { s in
            s.delist(flightID)
            let cancelled = (s.flights[flightID]?.waiters.isEmpty ?? true) || Task.isCancelled
            let finalOutcome = cancelled ? .cancelled : resolvedOutcome
            switch finalOutcome {
            case .member(let member):
                if let response {
                    s.store(key, member, lastModified: storeLastModified, expiresS: response.expiresS, nowS: now)
                }
            case .failure(let error) where error.code == .rateLimited:
                s.throttleUntilS = METNorwayParse.throttleUntilS(answeredAtS: now)
            case .failure, .cancelled:
                break
            }
            var ready: [CheckedContinuation<Outcome, Never>] = []
            for call in s.flights[flightID]?.waiters ?? [] {
                switch s.waiters[call] {
                case .waiting(_, let continuation):
                    ready.append(continuation)
                    s.waiters[call] = nil
                case .added:
                    s.waiters[call] = .finished(finalOutcome)
                case .finished, nil:
                    break
                }
            }
            s.flights[flightID] = nil
            return (ready, finalOutcome)
        }
        for continuation in continuations {
            continuation.resume(returning: resolved)
        }
        // on_result_released: the slot is free once the completion has been handled.
        state.withLock { $0.outstanding -= 1 }
    }

#if DEBUG
    // MARK: Test support

    /// The number of requests whose HTTP operation is not yet released (C: outstanding).
    var outstandingCount: Int { state.withLock { $0.outstanding } }

    /// The number of fetches waiting for a request in flight.
    var waiterCount: Int { state.withLock { s in s.flights.values.reduce(0) { $0 + $1.waiters.count } } }

    /// The number of cached entries currently held.
    var cacheEntryCount: Int { state.withLock { $0.cache.count } }
#endif
}
