// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// NWSProvider.swift - the National Weather Service (api.weather.gov) provider:
// the network half of src/providers/nws/wx-nws.c (WxNws) on the U13 HTTPClient.
// The parsers are NWSParse (NWSParse.swift); this file is the two-step fetch,
// the per-point caches and the 429 pause.
//
// Contract (wx-nws.h:6-27, ported as written):
//  - One HTTPClient per provider, built from the FIXED https base URL
//    `NWSProvider.baseURL` with the NWS User-Agent and the default timing
//    (wx_nws_new, wx-nws.c:533-536). The only other constructor is the
//    internal test initialiser, which accepts loopback http origins only
//    (DECISIONS #34 condition 10, #36 condition 11), so production traffic goes
//    to api.weather.gov and nowhere else.
//  - Step 1: GET /points/<lat>,<lon>, both WxGeo.round4()ed and printed "%.4f"
//    locale independently (point_key, wx-nws.c:860-866). HTTP 404 means the
//    point is outside NWS coverage: the fetch fails with UNSUPPORTED, the
//    client does not retry it, and the point is remembered as unsupported (at
//    most cacheMax points, oldest forgotten first, for the life of the
//    instance), so later fetches of it fail without traffic. A resolved cell
//    is cached per point (at most cacheMax points, oldest evicted first, for
//    gridTTLSeconds of monotonic time).
//  - Step 2: GET /gridpoints/<GRID>/<x>,<y>, built from the validated
//    NWSParse.Grid only (wx-nws.c:744); a 404 forgets the cached cell of the
//    point and stays NOT_FOUND (wx-nws.c:820-826).
//  - Any RATE_LIMITED from the client - a real 429 and the client's own
//    in-flight cap refusal alike - makes the instance refuse every new request,
//    including the second request of a fetch in progress, for
//    rateLimitSeconds of monotonic time, answering RATE_LIMITED without
//    traffic (note_failure keys on the error CODE, wx-nws.c:689-697). A 429
//    that the platform reports as NETWORK, or as RATE_LIMITED only at the
//    attempt deadline (DECISIONS #34 item 3, #36 N1/N3), is handled exactly as
//    the code it arrives with: no compensation here.
//  - The member's fetchedS is the injected clock's wall time, whole seconds,
//    when the second response was received (wx-nws.h:50-51, wx-nws.c:834).
//  - Cancellation: a task cancelled before fetch returns gets
//    CancellationError, also when the outcome was a refusal or already ready
//    (GTask check_cancellable, wx-provider.h:32-35); a request finished for a
//    cancelled task changes no provider state (WxHttp's GTask, wx-http.c:2054).
//
// The caches and the pause read the injected WxClock's monotonic time (C: the
// now_us() hook of the test flavour, wx-nws.c:59-66); production passes
// SystemClock().
//
// Concurrency: the C provider runs on one main loop and each callback is
// atomic. Here every decision step (fetch start, end of step 1, start of step
// 2, end of step 2) is one critical section of `state`; the requests run
// outside the lock, so concurrent fetches interleave at the same points as the
// C callbacks.

import Foundation
import Synchronization

/// The National Weather Service provider (C: WxNws, src/providers/nws/wx-nws.{h,c}).
public final class NWSProvider: WxProvider {

    // MARK: Constants (wx-nws.h:67-78, wx-nws.c:19-22)

    /// Base URL of the service; the host of the production instance is fixed
    /// to it (WX_NWS_BASE_URL, wx-nws.h:68).
    public static let baseURL = "https://api.weather.gov"
    /// User-Agent of every request: product, version and contact
    /// (WX_NWS_USER_AGENT, wx-nws.h:70).
    public static let userAgent = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// Most points remembered per cache (resolved cells; unsupported points)
    /// (WX_NWS_CACHE_MAX, wx-nws.h:74).
    public static let cacheMax = 64
    /// Lifetime of a cached grid cell, seconds: 7 days (WX_NWS_GRID_TTL_S, wx-nws.h:76).
    public static let gridTTLSeconds = 7 * 86400
    /// Time after a RATE_LIMITED answer during which no request is made,
    /// seconds (WX_NWS_RATE_LIMIT_S, wx-nws.h:78).
    public static let rateLimitSeconds = 5
    /// Accept header of both requests (NWS_ACCEPT, wx-nws.c:22).
    public static let accept = "application/geo+json"
    /// Source name (NWS_NAME, wx-nws.c:19).
    public static let displayName = "National Weather Service"
    /// Credit line (NWS_ATTRIBUTION, wx-nws.c:20).
    public static let attributionText = "Source: NOAA/National Weather Service"
    /// https URL of the credit link (NWS_ATTRIBUTION_URL, wx-nws.c:21).
    public static let attributionLink = "https://www.weather.gov/"

    /// The provider's own fixed messages.
    public enum Message {
        /// UNSUPPORTED: outside the coverage box, a remembered 404 point, or a
        /// /points 404 (wx-nws.c:777, :900, :906).
        public static let outsideCoverage = "place is outside the NWS coverage"
        /// RATE_LIMITED while the pause runs (wx-nws.c:715-716, %d = WX_NWS_RATE_LIMIT_S).
        public static let rateLimited = "NWS asked for fewer requests; waiting \(NWSProvider.rateLimitSeconds) seconds"
    }

    // MARK: WxProvider identity

    public var id: String { NWSParse.id }
    public var name: String { Self.displayName }
    public var attribution: String { Self.attributionText }
    public var attributionURL: String { Self.attributionLink }

    // MARK: State

    /// The provider's HTTP client (C: self->http). Internal so tests can read
    /// its policy (origin, User-Agent, timing).
    let http: HTTPClient
    /// Time source of the caches, the pause and fetchedS.
    private let clock: any WxClock
    private let state = Mutex(State())

    /// One remembered point: a grid cell, or an "unsupported" mark (grid nil)
    /// (C: CacheEntry, wx-nws.c:346-350).
    private struct CacheEntry: Sendable {
        let key: String
        let grid: NWSParse.Grid?
        /// Monotonic microseconds; Int64.max never.
        let expiresUs: Int64
    }

    /// C: struct _WxNws (wx-nws.c:352-358), as initialised by wx_nws_init (:466-472).
    private struct State: Sendable {
        /// Resolved cells, oldest first, at most cacheMax.
        var grids: [CacheEntry] = []
        /// Unsupported marks, oldest first, at most cacheMax.
        var unsupported: [CacheEntry] = []
        /// No request before this monotonic time (G_MININT64 at start).
        var blockedUntilUs: Int64 = .min
    }

    // MARK: Construction

    /// wx_nws_new: the production provider for `NWSProvider.baseURL` with the
    /// NWS User-Agent and the default client timing (HTTPPolicy.timeoutMs,
    /// HTTPPolicy.backoffBaseMs, no pacing). `clock` drives the caches, the
    /// pause, fetchedS and the client's deadlines; production passes
    /// SystemClock().
    ///
    /// - Throws: `WxError` `.invalidArg` from the client (not expected: every
    ///   argument is a constant).
    public convenience init(clock: any WxClock = SystemClock()) throws(WxError) {
        let http = try HTTPClient(
            baseURL: Self.baseURL, userAgent: Self.userAgent, timeoutMs: HTTPPolicy.timeoutMs,
            backoffBaseMs: HTTPPolicy.backoffBaseMs, minGapMs: 0, clock: clock)
        self.init(http: http, clock: clock)
    }

    /// TEST ONLY (C: wx_nws_new_custom, the hook of the tests): a provider for a
    /// loopback http origin with short timing. The base URL is validated by
    /// HTTPClientPolicy first (its INVALID_ARG messages, "unacceptable base URL"
    /// and "invalid timing argument" for C's criticals); then anything but an
    /// http origin (which the policy allows only towards a loopback host) is
    /// refused with INVALID_ARG "unacceptable base URL", so no https host other
    /// than `baseURL` can ever be reached (difference from C, which accepted any
    /// https origin here; DECISIONS #34 condition 10).
    ///
    /// - Parameters:
    ///   - clock: drives the caches, the pause and fetchedS (C: the
    ///     wx_nws_test_set_clock hook).
    ///   - httpClock: drives the client's deadlines and back-off (C: WxHttp
    ///     keeps the real clock when the hook is set).
    init(
        testBaseURL: String, timeoutMs: Int, backoffBaseMs: Int, clock: any WxClock,
        httpClock: any WxClock = SystemClock()
    ) throws(WxError) {
        let policy = try HTTPClientPolicy(
            baseURL: testBaseURL, userAgent: Self.userAgent, timeoutMs: timeoutMs,
            backoffBaseMs: backoffBaseMs, minGapMs: 0)
        guard policy.origin.hasPrefix("http://") else {
            throw WxError(.invalidArg, HTTPPolicy.Message.unacceptableBaseURL)
        }
        http = try HTTPClient(policy: policy, clock: httpClock)
        self.clock = clock
    }

    private init(http: HTTPClient, clock: any WxClock) {
        self.http = http
        self.clock = clock
    }

    // MARK: WxProvider

    /// nws_covers: the coarse US pre-filter, no I/O (wx-nws.c:646-650).
    public func covers(_ place: WxPlace) -> Bool {
        WxGeo.inUSNWS(place: place)
    }

    /// nws_fetch_async + nws_fetch_finish: consults the coverage box, the
    /// caches and the pause, then runs the two requests.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   this returns (whatever the outcome); otherwise `WxError`:
    ///   `.unsupported` (outside the box, remembered or new /points 404),
    ///   `.rateLimited` (the pause, or the client's 429 / cap refusal), the
    ///   client's other errors (a /gridpoints 404 stays `.notFound`), or the
    ///   parsers' `.parse` / `.invalidArg` / `.notFound`.
    public func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        let outcome: Result<WxSourceResult, any Error>
        do {
            outcome = .success(try await run(place))
        } catch {
            outcome = .failure(error)
        }
        // C: g_task_return_* with check_cancellable: a cancellation before
        // finish wins over every other outcome (wx-provider.h:32-35).
        try Task.checkCancellation()
        return try outcome.get()
    }

    // MARK: The fetch

    /// What the cache and pause checks at the start of a fetch decided.
    private enum Start {
        case unsupported
        case rateLimited
        case cached(NWSParse.Grid)
        case resolve
    }

    /// nws_fetch_async (wx-nws.c:888-922), on_points_done (:764-792),
    /// start_gridpoints (:736-746) and on_grid_done (:810-842) in sequence.
    private func run(_ place: WxPlace) async throws -> WxSourceResult {
        // WxPlace is valid by construction: the C "invalid place" path (:896-897) does not exist.
        guard WxGeo.inUSNWS(place: place) else {
            throw WxError(.unsupported, Message.outsideCoverage)
        }
        let key = Self.pointKey(place)
        let start: Start = state.withLock { s in
            if Self.lookup(&s.unsupported, key, now: clock.monotonicMicroseconds) != nil {
                return .unsupported
            }
            if clock.monotonicMicroseconds < s.blockedUntilUs {
                return .rateLimited
            }
            if let cached = Self.lookup(&s.grids, key, now: clock.monotonicMicroseconds), let grid = cached.grid {
                return .cached(grid)
            }
            return .resolve
        }
        let grid: NWSParse.Grid
        switch start {
        case .unsupported:
            throw WxError(.unsupported, Message.outsideCoverage)
        case .rateLimited:
            throw WxError(.rateLimited, Message.rateLimited)
        case .cached(let cachedGrid):
            grid = cachedGrid
        case .resolve:
            grid = try await resolve(key)
        }
        return try await gridpoints(grid, key: key)
    }

    /// Step 1 (wx-nws.c:915-917 and on_points_done :764-792): resolves and
    /// caches the cell of the point `key`.
    private func resolve(_ key: String) async throws -> NWSParse.Grid {
        let response: HTTPClient.Response
        do {
            response = try await request("/points/" + key)
        } catch let error as WxError {
            let notFound = state.withLock { s in
                noteFailure(&s, error)
                if error.code == .notFound {
                    Self.store(&s.unsupported, key, grid: nil, expiresUs: .max)
                    return true
                }
                return false
            }
            if notFound {
                throw WxError(.unsupported, Message.outsideCoverage)
            }
            throw error
        }
        let grid = try NWSParse.parsePoints(response.body)
        state.withLock { s in
            Self.store(
                &s.grids, key, grid: grid,
                expiresUs: Self.deadlineAfter(clock.monotonicMicroseconds, seconds: Self.gridTTLSeconds))
        }
        return grid
    }

    /// Step 2 (start_gridpoints :736-746, on_grid_done :810-842).
    private func gridpoints(_ grid: NWSParse.Grid, key: String) async throws -> WxSourceResult {
        let blocked = state.withLock { s in clock.monotonicMicroseconds < s.blockedUntilUs }
        if blocked {
            throw WxError(.rateLimited, Message.rateLimited)
        }
        let response: HTTPClient.Response
        do {
            response = try await request("/gridpoints/\(grid.gridID)/\(grid.x),\(grid.y)")
        } catch let error as WxError {
            state.withLock { s in
                noteFailure(&s, error)
                if error.code == .notFound, let index = s.grids.firstIndex(where: { $0.key == key }) {
                    s.grids.remove(at: index)
                }
            }
            throw error
        }
        let member = try NWSParse.parseGridpoints(response.body, fetchedS: clock.wallSeconds)
        var result = try WxSourceResult(providerID: NWSParse.id)
        result.members.append(member)
        return result
    }

    /// wx_http_get_async + wx_http_get_finish as the C callbacks see them. WxHttp's GTask
    /// carries the caller's cancellable with check_cancellable left on (wx-http.c:2054), so a
    /// caller that is cancelled when on_points_done / on_grid_done finishes the request gets
    /// G_IO_ERROR_CANCELLED whatever the client answered - its in-flight cap refusal included
    /// (wx-http.c:2063-2067) - and the provider changes no state: no pause, no unsupported
    /// mark, no cell stored or forgotten. HTTPClient.get reports its cap refusal before it
    /// checks cancellation, so the check is made here on both outcomes.
    private func request(_ path: String) async throws -> HTTPClient.Response {
        let response: HTTPClient.Response
        do {
            response = try await http.get(path, accept: Self.accept)
        } catch let error as WxError {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return response
    }

    // MARK: Helpers (C statics)

    /// note_failure (wx-nws.c:689-697): a RATE_LIMITED error code starts the
    /// pause, which then ends rateLimitSeconds from now (never earlier than
    /// before).
    private func noteFailure(_ s: inout State, _ error: WxError) {
        guard error.code == .rateLimited else { return }
        let until = Self.deadlineAfter(clock.monotonicMicroseconds, seconds: Self.rateLimitSeconds)
        if until > s.blockedUntilUs {
            s.blockedUntilUs = until
        }
    }

    /// point_key (wx-nws.c:860-866): "<lat>,<lon>", both WxGeo.round4()ed and
    /// printed "%.4f" with a dot whatever the locale (String(format:) without a
    /// locale is not localised), e.g. "25.7617,-80.1918".
    static func pointKey(_ place: WxPlace) -> String {
        String(format: "%.4f", WxGeo.round4(place.lat)) + "," + String(format: "%.4f", WxGeo.round4(place.lon))
    }

    /// deadline_after (wx-nws.c:85-90): `now` + `seconds` s, saturated at Int64.max.
    static func deadlineAfter(_ now: Int64, seconds: Int) -> Int64 {
        let span = Int64(seconds) * 1_000_000
        return now > Int64.max - span ? Int64.max : now + span
    }

    /// cache_lookup (wx-nws.c:402-415): the first entry of `key` if it is live;
    /// an expired one is removed.
    private static func lookup(_ cache: inout [CacheEntry], _ key: String, now: Int64) -> CacheEntry? {
        guard let index = cache.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = cache[index]
        if now < entry.expiresUs {
            return entry
        }
        cache.remove(at: index)
        return nil
    }

    /// cache_store (wx-nws.c:434-451): stores or replaces the entry of `key` as
    /// the newest one; when the cache is full the oldest entry is evicted.
    private static func store(_ cache: inout [CacheEntry], _ key: String, grid: NWSParse.Grid?, expiresUs: Int64) {
        if let index = cache.firstIndex(where: { $0.key == key }) {
            cache.remove(at: index)
        }
        if cache.count >= cacheMax {
            cache.remove(at: 0)
        }
        cache.append(CacheEntry(key: key, grid: grid, expiresUs: expiresUs))
    }
}
