// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsFetchers.swift - the production transport of AlertsService: the
// fetcher (WxAlertsFetch) that sends each alert request of the five keyless
// issuers through that issuer's own host-pinned HTTPClient.
//
// One HTTPClient per source, each pinned to the origin its request URLs are
// built for (WxPointAlerts, WxECCCAlerts, WxAlertRegions.feedURL), each with
// HTTPPolicy.userAgent and the transport's fixed header set - no API key,
// token or credential (no source needs one) - and each with the body cap
// HTTPPolicy allows its host (HTTPPolicy.maxBodyBytes(host:): 16 MiB for
// feeds.meteoalarm.org, 4 MiB for the four point hosts). A URL is sent only
// when it starts with its source's origin, and only its path and query go to
// the client, so no URL can reach another host. Nothing here runs a timer:
// the service asks, at most once per forecast refresh.
//
// MET Norway (api.met.no Terms of Service): coordinates at most 4 decimals -
// the URL builder rounds them, and a URL with 5 or more is refused here
// without traffic (new products answer 403) - and Expires / If-Modified-Since
// honoured: an answer is reused, without a request, until the Expires of the
// response that brought it; after that the request carries its Last-Modified
// as If-Modified-Since, and a 304 is answered here as a 200 with the kept
// body (the service never sees a 304), its Expires extending the reuse. The
// service's own 5-minute point reuse comes first, so this only makes
// MET Norway requests rarer.
//
// Status codes: HTTPClient throws for every status but 2xx and a 304 to an
// If-Modified-Since (C parity), except the one each source declares as its
// "not covered" answer (`answering(of:)`): NWS's 400 "out of bounds" and
// Bright Sky's 404 "not covered" come back with their status and body, under
// the client's cap, for the service's parser to read as not covered. Every
// other non-2xx answer reaches the service as a thrown error: "unavailable",
// never "no alerts".

import Foundation
import Synchronization

/// The production alert fetcher (see the file comment). Create one per app and hand
/// `fetcher` to AlertsService; it is safe to use from any task.
public final class WxAlertsFetchers: Sendable {
    /// The most MET Norway answers kept for Expires / If-Modified-Since (one per refreshed
    /// point; WxError.placeMax places, with room for moved ones).
    static let keptMax = 64

    /// The origin every request URL of `source` starts with.
    public static func origin(of source: WxAlert.Source) -> String {
        switch source {
        case .nws: "https://api.weather.gov"
        case .dwd: "https://api.brightsky.dev"
        case .metNorway: "https://api.met.no"
        case .eccc: "https://api.weather.gc.ca"
        case .meteoAlarm: "https://" + HTTPPolicy.meteoAlarmHost
        }
    }

    /// The Accept value of the requests of `source` (the media type each answers with).
    static func accept(of source: WxAlert.Source) -> String {
        switch source {
        case .nws: "application/geo+json"
        case .dwd, .metNorway, .eccc, .meteoAlarm: "application/json"
        }
    }

    /// The non-2xx statuses `source` answers a request outside its area with ("not covered"),
    /// which its client returns with the body instead of throwing: NWS 400 ("out of bounds"),
    /// Bright Sky 404. The other sources answer such a point with an empty set or have none.
    static func answering(of source: WxAlert.Source) -> Set<Int> {
        switch source {
        case .nws: [400]
        case .dwd: [404]
        case .metNorway, .eccc, .meteoAlarm: []
        }
    }

    /// A MET Norway answer kept for its Expires and Last-Modified.
    private struct Kept: Sendable {
        let body: Data
        let lastModified: String?
        /// UTC unix seconds; 0 (absent or implausible): already expired.
        let expiresS: Int64
    }

    private let clients: [WxAlert.Source: HTTPClient]
    private let clock: any WxClock
    /// MET Norway answers by path and query.
    private let kept = Mutex<[String: Kept]>([:])

    /// The production fetcher: one client per source, pinned to `origin(of:)`, timed on `clock`.
    public convenience init(clock: any WxClock = SystemClock()) throws(WxError) {
        var clients: [WxAlert.Source: HTTPClient] = [:]
        for source in WxAlert.Source.allCases {
            clients[source] = try HTTPClient(baseURL: Self.origin(of: source), clock: clock)
        }
        self.init(clients: clients, clock: clock)
    }

    /// TEST ONLY: every source's client pinned to one loopback http origin (anything else is
    /// refused with INVALID_ARG "unacceptable base URL", as NWSProvider's test init), each with
    /// the body cap of its production host. Request URLs still have to start with
    /// `origin(of:)`; only their path and query reach `testBaseURL`.
    convenience init(testBaseURL: String, clock: any WxClock) throws(WxError) {
        let policy = try HTTPClientPolicy(baseURL: testBaseURL, userAgent: HTTPPolicy.userAgent)
        guard policy.origin.hasPrefix("http://") else {
            throw WxError(.invalidArg, HTTPPolicy.Message.unacceptableBaseURL)
        }
        var clients: [WxAlert.Source: HTTPClient] = [:]
        for source in WxAlert.Source.allCases {
            let host = URLComponents(string: Self.origin(of: source))?.host ?? ""
            clients[source] = try HTTPClient(
                policy: policy, clock: clock, totalDeadlineMs: HTTPPolicy.totalDeadlineMs,
                maxBodyBytes: HTTPPolicy.maxBodyBytes(host: host))
        }
        self.init(clients: clients, clock: clock)
    }

    private init(clients: [WxAlert.Source: HTTPClient], clock: any WxClock) {
        self.clients = clients
        self.clock = clock
    }

    /// The client of `source`.
    func client(for source: WxAlert.Source) -> HTTPClient {
        clients[source]!  // init fills every case
    }

    /// This fetcher as AlertsService takes it.
    public var fetcher: WxAlertsFetch {
        { [self] source, url in try await fetch(source, url) }
    }

    /// GETs `url` of `source` through its client: the answer's status and decoded body (a 2xx,
    /// or the source's `answering(of:)` status).
    ///
    /// - Throws: `WxError` INVALID_ARG (without traffic) for a URL that does not start with
    ///   `origin(of: source)` + "/" or, for MET Norway, has a coordinate with more than 4
    ///   decimals; whatever `HTTPClient.get` throws (any other non-2xx status, a body over the
    ///   cap, a timeout, the network); `CancellationError`.
    public func fetch(_ source: WxAlert.Source, _ url: String) async throws -> WxAlertsResponse {
        let origin = Self.origin(of: source)
        guard url.hasPrefix(origin + "/") else {
            throw WxError(.invalidArg, HTTPPolicy.Message.malformedRequestPath)
        }
        let path = String(url.dropFirst(origin.count))
        let http = client(for: source)
        guard source == .metNorway else {
            let response = try await http.get(
                path, accept: Self.accept(of: source), answering: Self.answering(of: source))
            return WxAlertsResponse(status: response.status, body: response.body)
        }
        guard Self.atMostFourDecimals(path) else {
            throw WxError(.invalidArg, HTTPPolicy.Message.malformedRequestPath)
        }
        return try await fetchConditional(path, client: http)
    }

    /// MET Norway: the kept answer before its Expires, else a request with If-Modified-Since
    /// (the kept Last-Modified), a 304 answered from the kept body.
    private func fetchConditional(_ path: String, client: HTTPClient) async throws -> WxAlertsResponse {
        let previous = kept.withLock { $0[path] }
        if let previous, clock.wallSeconds < previous.expiresS {
            return WxAlertsResponse(status: 200, body: previous.body)
        }
        let response = try await client.get(
            path, accept: Self.accept(of: .metNorway), ifModifiedSince: previous?.lastModified)
        if response.status == 304 {
            // Sent only with a validator, so there is a kept body; never hand a 304 on.
            guard let previous else { throw HTTPPolicy.statusError(304) }
            keep(path, Kept(body: previous.body, lastModified: response.lastModified ?? previous.lastModified,
                            expiresS: response.expiresS))
            return WxAlertsResponse(status: 200, body: previous.body)
        }
        if response.status == 200 {
            keep(path, Kept(body: response.body, lastModified: response.lastModified, expiresS: response.expiresS))
        }
        return WxAlertsResponse(status: response.status, body: response.body)
    }

    /// Keeps `answer` for `path`; past keptMax the answer expiring first makes room.
    private func keep(_ path: String, _ answer: Kept) {
        kept.withLock { kept in
            if kept[path] == nil, kept.count >= Self.keptMax,
               let first = kept.min(by: { $0.value.expiresS < $1.value.expiresS })?.key {
                kept[first] = nil
            }
            kept[path] = answer
        }
    }

    /// Whether every `lat` and `lon` value of the query of `path` has at most 4 decimals.
    static func atMostFourDecimals(_ path: String) -> Bool {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return true }
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == "lat" || pair[0] == "lon" else { continue }
            if let dot = pair[1].firstIndex(of: "."), pair[1][pair[1].index(after: dot)...].count > 4 {
                return false
            }
        }
        return true
    }
}
