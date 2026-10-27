// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsFetchersTests.swift - the production alert transport (WxAlertsFetchers)
// over LoopbackServer, driven through AlertsService as the app drives it: one
// host-pinned client per source with the shared User-Agent and no key, the
// 16 MiB cap of the MeteoAlarm feed host alone, MET Norway's 4 decimals and
// Expires / If-Modified-Since, and every failed or oversized answer
// "unavailable". One ManualClock times the service, the fetcher and the
// HTTP clients, so the Expires / Last-Modified the server sends are dated on
// it. The transport enforces each client's own cap and hands the declared
// "not covered" answers (NWS 400, Bright Sky 404; the other sources declare
// none) over with their bodies (U69), so a 9.1 MB feed passes and those
// places read not covered. The time limit turns a retry waiting on the
// ManualClock (an answer the transport wrongly retries) into a failure
// instead of a hang.

import Foundation
import Testing
@testable import WeatherCore

@Suite(.timeLimit(.minutes(1)))
struct AlertsFetchersTests {
    /// 2026-10-27T00:00:00Z: the two MET Norway fixture alerts (21:00Z to 13:00Z) are current.
    static let t0S: Int64 = 1_793_059_200
    static let mib = 1024 * 1024
    /// The live Swiss MeteoAlarm feed's size on 2026-10-26 (feeds-switzerland, U60 probe): over
    /// the 4 MiB point cap, under the feed host's 16 MiB.
    static let swissFeedBytes = 9_115_185

    static func place(_ name: String, _ cc: String, _ lat: Double, _ lon: Double) -> WxPlace {
        try! WxPlace(name: name, countryCode: cc, lat: lat, lon: lon)
    }

    static let miami = place("Miami", "US", 25.7617, -80.1918)
    static let berlin = place("Berlin", "DE", 52.5200, 13.4050)
    static let oslo = place("Oslo", "NO", 59.913868, 10.752245)
    static let toronto = place("Toronto", "CA", 43.6532, -79.3832)
    static let paris = place("Paris", "FR", 48.8566, 2.3522)
    /// One place per source, with the source it routes to and the request path prefix.
    static let five: [(WxPlace, WxAlert.Source, String)] = [
        (miami, .nws, "/alerts/active?point="),
        (berlin, .dwd, "/alerts?lat="),
        (oslo, .metNorway, "/weatherapi/metalerts/2.0/current.json?"),
        (toronto, .eccc, "/collections/weather-alerts/items?"),
        (paris, .meteoAlarm, "/api/v1/warnings/feeds-france"),
    ]

    /// An HTTP-date (RFC 9110 IMF-fixdate) of unix seconds `s`.
    static func httpDate(_ s: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(s)))
    }

    static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    /// `json` followed by spaces up to `size` bytes (still valid JSON).
    static func padded(_ json: String, to size: Int) -> Data {
        Data(json.utf8) + Data(repeating: 0x20, count: size - json.utf8.count)
    }

    /// A loopback server answering each source's path with `steps[source]`.
    static func server(_ steps: [WxAlert.Source: [LoopbackServer.Step]]) throws -> LoopbackServer {
        try LoopbackServer(routes: five.compactMap { _, source, prefix in
            steps[source].map { LoopbackServer.Route(prefix, $0) }
        })
    }

    /// The five sources' covered, current answers (vendor fixtures).
    static func coveredSteps() throws -> [WxAlert.Source: [LoopbackServer.Step]] {
        [.nws: [.respond(body: try fixture("alerts-nws-point-empty.json"))],
         .dwd: [.respond(body: try fixture("alerts-brightsky-berlin-empty.json"))],
         .metNorway: [.respond(body: try fixture("alerts-metno-current-en-trim2.json"))],
         .eccc: [.respond(body: try fixture("alerts-eccc-toronto-point.json"))],
         .meteoAlarm: [.respond(body: try fixture("alerts-meteoalarm-france-trim3.json"))]]
    }

    @MainActor
    static func service(_ server: LoopbackServer, _ clock: ManualClock) throws -> (AlertsService, WxAlertsFetchers) {
        let fetchers = try WxAlertsFetchers(testBaseURL: "http://127.0.0.1:\(server.port)", clock: clock)
        return (AlertsService(clock: clock, fetch: fetchers.fetcher), fetchers)
    }

    static func clock() -> ManualClock { ManualClock(wallMicroseconds: t0S * 1_000_000) }

    // MARK: - Conformance, User-Agent, no key

    @Test @MainActor func allFiveFetchersConform() async throws {
        // Production: one client per source, pinned to the origin its URLs are built for, with
        // the shared User-Agent; the URL builders of every source start with that origin.
        let production = try WxAlertsFetchers()
        let fetch: WxAlertsFetch = production.fetcher
        _ = fetch
        var origins = Set<String>()
        for (place, source, _) in Self.five {
            let client = production.client(for: source)
            #expect(client.policy.origin == WxAlertsFetchers.origin(of: source), "\(source)")
            #expect(client.policy.userAgent == HTTPPolicy.userAgent, "\(source)")
            let url = try #require(AlertsService.url(of: source, for: place))
            #expect(url.hasPrefix(WxAlertsFetchers.origin(of: source) + "/"), "\(url)")
            origins.insert(client.policy.origin)
        }
        #expect(origins.count == 5)

        // Through AlertsService over loopback: each place is fetched once, by its own source,
        // and its answer is current.
        let server = try Self.server(try Self.coveredSteps())
        defer { server.stop() }
        let clock = Self.clock()
        let (service, fetchers) = try Self.service(server, clock)
        for (place, source, prefix) in Self.five {
            let before = server.requests.count
            await service.refresh(place).value
            let r = service.result(for: place)
            #expect(r.source == source && r.state == .current, "\(place.name): \(r)")
            #expect(server.requests.dropFirst(before).map { $0.path.hasPrefix(prefix) } == [true], "\(place.name)")
        }
        #expect(service.result(for: Self.oslo).alerts.count == 2)

        // A URL of another host is refused before any traffic.
        let sent = server.requests.count
        for url in ["https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=1&lon=1",
                    "https://api.weather.gov.example.org/alerts/active?point=1,1", "http://api.weather.gov/alerts"] {
            await #expect(throws: WxError.self) { _ = try await fetchers.fetch(.nws, url) }
        }
        #expect(server.requests.count == sent)
        // The fetchers' own origin guard (not HTTPClient's path check): a host as long as the
        // source's origin leaves a valid path once the origin's length is cut off, so only the
        // guard refuses it; also another source's URL, a port, userinfo, and a fifth MET decimal.
        let foreign: [(WxAlert.Source, String)] = [
            (.nws, "https://api.weather.gox/alerts/active?point=1,1"),
            (.dwd, "https://api.brightsky.dex/alerts?lat=1&lon=1"),
            (.eccc, "https://api.weather.gc.cb/collections/weather-alerts/items?f=json"),
            (.meteoAlarm, "https://feeds.meteoalarm.orh/api/v1/warnings/feeds-france"),
            (.metNorway, "https://api.met.nx/weatherapi/metalerts/2.0/current.json?lat=1&lon=1"),
            (.dwd, WxPointAlerts.nwsURL(lat: 1, lon: 1)),
            (.nws, "https://api.weather.gov:8443/alerts/active?point=1,1"),
            (.nws, "https://api.weather.gov@evil.example/alerts/active?point=1,1"),
            (.metNorway, "https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=-59.91387&lon=10.7522"),
        ]
        for (source, url) in foreign {
            await #expect(throws: WxError.self, "\(source) \(url)") { _ = try await fetchers.fetch(source, url) }
        }
        #expect(server.requests.count == sent)
    }

    @Test @MainActor func requestsCarryUserAgentNoKey() async throws {
        let server = try Self.server(try Self.coveredSteps())
        defer { server.stop() }
        let (service, _) = try Self.service(server, Self.clock())
        for (place, _, _) in Self.five {
            await service.refresh(place).value
        }
        let requests = server.requests
        #expect(requests.count == 5)
        let keyNames: Set<String> = ["key", "apikey", "api_key", "api-key", "appid", "token", "access_token",
                                     "client_id", "client_secret", "subscription-key"]
        for request in requests {
            #expect(request.headers("User-Agent") == [HTTPPolicy.userAgent], "\(request.path)")
            for name in ["Authorization", "Proxy-Authorization", "Cookie", "X-API-Key", "apikey"] {
                #expect(request.header(name) == nil, "\(name) \(request.path)")
            }
            let query = request.path.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
            let names = query.split(separator: "&").map { String($0.split(separator: "=").first ?? "").lowercased() }
            #expect(Set(names).isDisjoint(with: keyNames), "\(request.path)")
            #expect(!request.head.lowercased().contains("key="), "\(request.path)")
        }
    }

    @Test @MainActor func nwsAndMetnoUserAgentHeader() async throws {
        let server = try Self.server(try Self.coveredSteps())
        defer { server.stop() }
        let (service, _) = try Self.service(server, Self.clock())
        await service.refresh(Self.miami).value
        await service.refresh(Self.oslo).value
        let nws = server.requests.filter { $0.path.hasPrefix("/alerts/active?point=") }
        let metno = server.requests.filter { $0.path.hasPrefix("/weatherapi/metalerts/2.0/current.json?") }
        #expect(nws.count == 1 && metno.count == 1)
        for request in nws + metno {
            #expect(request.header("User-Agent") == "weather-app/0.1 (github.com/wtp128pro/weather)", "\(request.path)")
            #expect(request.headers("User-Agent").count == 1)
        }
    }

    // MARK: - Body caps

    @Test func meteoAlarmCap16MiBOnly() async throws {
        // Policy and clients: 16 MiB for the MeteoAlarm feed client alone, production and loopback.
        #expect(HTTPPolicy.productionHosts.contains("feeds.meteoalarm.org"))
        #expect(AlertsService.feedMaxBytes == HTTPPolicy.meteoAlarmMaxBodyBytes)
        #expect(AlertsService.pointMaxBytes == HTTPPolicy.maxBodyBytes)
        let server = try Self.server([
            .nws: [.respond(body: Data(repeating: 0x20, count: 5 * Self.mib))],
            .meteoAlarm: [.respond(body: Self.padded(#"{"warnings":[]}"#, to: Self.swissFeedBytes))],
        ])
        defer { server.stop() }
        let loopback = try WxAlertsFetchers(testBaseURL: "http://127.0.0.1:\(server.port)", clock: SystemClock())
        for fetchers in [try WxAlertsFetchers(), loopback] {
            for source in WxAlert.Source.allCases {
                let cap = source == .meteoAlarm ? 16 * Self.mib : 4 * Self.mib
                #expect(fetchers.client(for: source).maxBodyBytes == cap, "\(source)")
            }
        }

        // On the wire: a 5 MiB point answer is refused (the 4 MiB cap is kept).
        let nwsURL = WxPointAlerts.nwsURL(lat: Self.miami.lat, lon: Self.miami.lon)
        await #expect(throws: WxError(.parse, HTTPPolicy.Message.responseTooLarge)) {
            _ = try await loopback.fetch(.nws, nwsURL)
        }
        // A 9.1 MB feed (the live Swiss feed's size) passes the feed client's 16 MiB cap.
        let feedURL = try #require(WxAlertRegions.feedURL(countryCode: "FR"))
        let r = try await loopback.fetch(.meteoAlarm, feedURL)
        #expect(r.status == 200 && r.body.count == Self.swissFeedBytes)
    }

    // MARK: - MET Norway terms

    @Test @MainActor func metnoConditionalGetKeepsSet() async throws {
        let t0 = Self.t0S
        let lastModified = Self.httpDate(t0 - 60)
        let body = try Self.fixture("alerts-metno-current-en-trim2.json")
        let server = try Self.server([.metNorway: [.compute { index, request in
            if index == 0 {
                return .respond(headers: ["Last-Modified: \(lastModified)", "Expires: \(Self.httpDate(t0 + 60))"],
                                body: body)
            }
            // A re-request carrying the validator is answered 304 (bodiless), anything else with an
            // empty set, so a lost validator shows as lost alerts.
            if request.header("If-Modified-Since") == lastModified {
                return .respond(status: 304, headers: ["Expires: \(Self.httpDate(t0 + 420))"])
            }
            return .respond(body: try! Self.fixture("alerts-metno-outside-norway-empty.json"))
        }]])
        defer { server.stop() }
        let clock = Self.clock()
        let (service, fetchers) = try Self.service(server, clock)
        let url = WxPointAlerts.metNorwayURL(lat: Self.oslo.lat, lon: Self.oslo.lon)

        await service.refresh(Self.oslo).value
        let first = service.result(for: Self.oslo)
        #expect(first.state == .current && first.alerts.count == 2 && first.fetchedS == t0)
        #expect(server.requests.count == 1 && server.requests[0].header("If-Modified-Since") == nil)

        // Before the answer's Expires: answered from the kept body, no request.
        clock.advanceWall(by: 30 * 1_000_000)
        let kept = try await fetchers.fetch(.metNorway, url)
        #expect(kept == WxAlertsResponse(status: 200, body: body))
        #expect(server.requests.count == 1)

        // After Expires and the service's 5-minute reuse: If-Modified-Since, 304, the same set,
        // published as a new (current) answer - never a 304 handed to the service.
        clock.advanceWall(by: 330 * 1_000_000)
        await service.refresh(Self.oslo).value
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.header("If-Modified-Since") == lastModified)
        let second = service.result(for: Self.oslo)
        #expect(second.state == .current && second.alerts == first.alerts && second.fetchedS == t0 + 360)

        // 660 s after the first answer (stale at 600 s) the 304's answer is 300 s old: current.
        clock.advanceWall(by: 300 * 1_000_000)
        #expect(service.result(for: Self.oslo).state == .current)
        // The 304's Expires (t0 + 420) has passed: the next fetch asks again, with the validator.
        _ = try await fetchers.fetch(.metNorway, url)
        #expect(server.requests.count == 3 && server.requests.last?.header("If-Modified-Since") == lastModified)
    }

    // MET Norway's Expires is honoured for the 200 AND for a later 304: no request before each
    // one's own Expires, one at it with the kept validator (U60 verifier handoff).
    @Test @MainActor func metno304ExpiresHonoured() async throws {
        let t0 = Self.t0S
        let lastModified = Self.httpDate(t0 - 60)
        let body = try Self.fixture("alerts-metno-current-en-trim2.json")
        let server = try Self.server([.metNorway: [.compute { index, request in
            if index == 0 {
                return .respond(headers: ["Last-Modified: \(lastModified)", "Expires: \(Self.httpDate(t0 + 60))"],
                                body: body)
            }
            if request.header("If-Modified-Since") == lastModified {
                return .respond(status: 304, headers: ["Expires: \(Self.httpDate(t0 + 600))"])
            }
            return .respond(body: try! Self.fixture("alerts-metno-outside-norway-empty.json"))
        }]])
        defer { server.stop() }
        let clock = Self.clock()
        let (_, fetchers) = try Self.service(server, clock)
        let url = WxPointAlerts.metNorwayURL(lat: Self.oslo.lat, lon: Self.oslo.lon)
        let kept = WxAlertsResponse(status: 200, body: body)
        #expect(try await fetchers.fetch(.metNorway, url) == kept)
        clock.advanceWall(by: 59 * 1_000_000)  // t0 + 59: before the 200's Expires
        #expect(try await fetchers.fetch(.metNorway, url) == kept)
        #expect(server.requests.count == 1)
        clock.advanceWall(by: 1 * 1_000_000)  // t0 + 60: asked again, with the validator: 304
        #expect(try await fetchers.fetch(.metNorway, url) == kept)
        #expect(server.requests.count == 2 && server.requests.last?.header("If-Modified-Since") == lastModified)
        clock.advanceWall(by: 539 * 1_000_000)  // t0 + 599: before the 304's own Expires
        #expect(try await fetchers.fetch(.metNorway, url) == kept)
        #expect(server.requests.count == 2, "re-requested before the 304's Expires")
        clock.advanceWall(by: 1 * 1_000_000)  // t0 + 600
        #expect(try await fetchers.fetch(.metNorway, url) == kept)
        #expect(server.requests.count == 3 && server.requests.last?.header("If-Modified-Since") == lastModified)
    }

    @Test @MainActor func metnoFourDecimals() async throws {
        let server = try Self.server(try Self.coveredSteps())
        defer { server.stop() }
        let (service, fetchers) = try Self.service(server, Self.clock())
        await service.refresh(Self.oslo).value
        let paths = server.requests.map(\.path)
        #expect(paths == ["/weatherapi/metalerts/2.0/current.json?lat=59.9139&lon=10.7522&lang=en"])

        // A URL with 5 or more decimals is refused without traffic (MET Norway answers 403).
        for (lat, lon) in [("59.91387", "10.7522"), ("59.9139", "10.752245"), ("59.913868", "10.752245")] {
            let url = "https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=\(lat)&lon=\(lon)&lang=en"
            await #expect(throws: WxError(.invalidArg, HTTPPolicy.Message.malformedRequestPath)) {
                _ = try await fetchers.fetch(.metNorway, url)
            }
        }
        #expect(server.requests.count == 1)
        #expect(WxAlertsFetchers.atMostFourDecimals("/x?lat=1&lon=-2.5&lang=en"))
        #expect(!WxAlertsFetchers.atMostFourDecimals("/x?lang=en&lon=10.12345"))
    }

    // MARK: - Not covered, failed, oversized

    @Test @MainActor func notCoveredStatusCodes() async throws {
        let nwsBody = try Self.fixture("alerts-nws-point-out-of-bounds-400.json")
        let bsBody = try Self.fixture("alerts-brightsky-not-covered-404.json")
        let server = try Self.server([
            .nws: [.respond(status: 400, body: nwsBody)],
            .dwd: [.respond(status: 404, body: bsBody)],
        ])
        defer { server.stop() }
        let (service, fetchers) = try Self.service(server, Self.clock())
        // Each source's declared "not covered" status comes back with its body, once each.
        let nwsURL = WxPointAlerts.nwsURL(lat: Self.miami.lat, lon: Self.miami.lon)
        let bsURL = WxPointAlerts.brightSkyURL(lat: Self.berlin.lat, lon: Self.berlin.lon)
        #expect(try await fetchers.fetch(.nws, nwsURL) == WxAlertsResponse(status: 400, body: nwsBody))
        #expect(try await fetchers.fetch(.dwd, bsURL) == WxAlertsResponse(status: 404, body: bsBody))
        #expect(server.requests.count == 2)

        for place in [Self.miami, Self.berlin] {
            await service.refresh(place).value
            let r = service.result(for: place)
            // Not covered by its source, never "no alerts".
            #expect(r.state == .notCovered && r.alerts.isEmpty, "\(place.name): \(r)")
        }

        // Only the source's own status is an answer: NWS 404 and Bright Sky 400 stay errors.
        let swapped = try Self.server([
            .nws: [.respond(status: 404, body: nwsBody)],
            .dwd: [.respond(status: 400, body: bsBody)],
        ])
        defer { swapped.stop() }
        let other = try WxAlertsFetchers(testBaseURL: "http://127.0.0.1:\(swapped.port)", clock: Self.clock())
        await #expect(throws: WxError(.notFound, "HTTP 404: not found")) { _ = try await other.fetch(.nws, nwsURL) }
        await #expect(throws: WxError(.http, "HTTP 400 Bad Request")) { _ = try await other.fetch(.dwd, bsURL) }
        #expect(swapped.requests.count == 2)
    }

    // Only NWS (400) and Bright Sky (404) declare a status (answering(of:)). MET Norway, ECCC and
    // MeteoAlarm declare none, so their 400 and 404 stay thrown on the wire (MET Norway's
    // conditional path passes no declaration either), each after 1 request.
    @Test func otherSourcesDeclareNoStatus() async throws {
        let declared = Dictionary(uniqueKeysWithValues: WxAlert.Source.allCases.map {
            ($0, WxAlertsFetchers.answering(of: $0))
        })
        #expect(declared == [.nws: [400], .dwd: [404], .metNorway: [], .eccc: [], .meteoAlarm: []])

        let body = Data(#"{"detail":"not here"}"#.utf8)
        let both: [LoopbackServer.Step] = [.respond(status: 400, body: body), .respond(status: 404, body: body)]
        let server = try Self.server([.metNorway: both, .eccc: both, .meteoAlarm: both])
        defer { server.stop() }
        let fetchers = try WxAlertsFetchers(testBaseURL: "http://127.0.0.1:\(server.port)", clock: SystemClock())
        let urls: [WxAlert.Source: String] = [
            .metNorway: WxPointAlerts.metNorwayURL(lat: Self.oslo.lat, lon: Self.oslo.lon),
            .eccc: WxECCCAlerts.url(lat: Self.toronto.lat, lon: Self.toronto.lon),
            .meteoAlarm: try #require(WxAlertRegions.feedURL(countryCode: "FR")),
        ]
        for (_, source, prefix) in Self.five {
            guard let url = urls[source] else { continue }
            await #expect(throws: WxError(.http, "HTTP 400 Bad Request"), "\(source)") {
                _ = try await fetchers.fetch(source, url)
            }
            await #expect(throws: WxError(.notFound, "HTTP 404: not found"), "\(source)") {
                _ = try await fetchers.fetch(source, url)
            }
            #expect(server.requests.filter { $0.path.hasPrefix(prefix) }.count == 2, "\(source)")
        }
    }

    @Test @MainActor func oversizedOrFailedIsUnavailable() async throws {
        let server = try Self.server([
            .nws: [.respond(body: Self.padded(#"{"features":[]}"#, to: 4 * Self.mib + 1))],
            .dwd: [.respond(status: 403, body: Data(#"{"detail":"forbidden"}"#.utf8))],
            .metNorway: [.text("<html>maintenance</html>")],
            .eccc: [.bigDeclared(size: 4 * Self.mib + 1)],
            .meteoAlarm: [.bigDeclared(size: 16 * Self.mib + 1)],
        ])
        defer { server.stop() }
        let (service, _) = try Self.service(server, Self.clock())
        for (place, source, prefix) in Self.five {
            await service.refresh(place).value
            let r = service.result(for: place)
            #expect(r == WxAlertsResult(state: .unavailable, source: source, alerts: [], fetchedS: Self.t0S),
                    "\(place.name): \(r)")
            #expect(server.requests.filter { $0.path.hasPrefix(prefix) }.count == 1, "\(place.name)")
        }
    }
}
