// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// NWSProviderTests.swift - the /nws/net/ group of src/providers/nws/test-nws.c
// (registrations :2777-2798) against NWSProvider on a loopback server.
//
// Porting notes:
//  - The C path-routed fake (test-nws.c:1472-1488 Route, :1576-1650
//    find_route/http_message/handle_request) is `Fake` below, a reply table on
//    the U03 LoopbackServer; answers carry C's exact head (http_message,
//    :1589-1602) except delayed (`.respond`), gzip (`.gzip`) and held answers,
//    whose Content-Type is application/json instead of application/geo+json.
//  - The C clock hook (wx_nws_test_set_clock) is the provider's ManualClock;
//    the HTTP client keeps a real clock as in C (only now_us() is hooked).
//  - The C callbacks become async calls: `fetch_start` + `wait_for` is a Task
//    and its value. The GLib-only parts (callback deferral, run_dispose,
//    g_task_is_valid) are listed in the U23 debrief.
//  - Expected values are test-nws.c literals, cited path:line.

import Foundation
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct NWSProviderTests {

    // test-nws.c:40, :43-47
    private static let t0: Int64 = 1_791_806_400
    private static let msgNoGrid = "no valid forecast grid in response"
    private static let msgNoProps = "response has no properties"
    private static let msgNoData = "response has no usable forecast"
    private static let msgOutside = "place is outside the NWS coverage"
    // test-nws.c:2198, :2202
    private static let msgPaused = "NWS asked for fewer requests; waiting 5 seconds"
    private static let usec: Int64 = 1_000_000
    // WX_NWS_GRID_TTL_S, wx-nws.h:76 (the C test uses the macro, test-nws.c:2130)
    private static let ttlS: Int64 = 7 * 86400

    typealias Outcome = Result<WxSourceResult, any Error>

    // MARK: Fake server (test-nws.c:1472-1650)

    /// test-nws.c Fake: a route table answered on a LoopbackServer.
    private final class Fake: Sendable {
        /// test-nws.c RouteKind (:1472-1477), plus `.hold` (LoopbackServer's
        /// held answer, released by the test).
        enum Kind: Sendable { case reply, hang, truncated, gzip, hold }

        /// test-nws.c Route (:1479-1488).
        struct Route: Sendable {
            var path: String
            var kind: Kind = .reply
            var status: Int
            var body: Data
            var delayMs: Int = 0
            var failStatus: Int = 0
            var failCount: Int = 0
            var hits: Int = 0
        }

        let table: LoopbackServer.Shared<[Route]>
        let server: LoopbackServer

        init() throws {
            let table = LoopbackServer.Shared<[Route]>([])
            self.table = table
            server = try LoopbackServer(reply: { _, request in Fake.answer(table, request.path) })
        }

        deinit { server.stop() }

        var base: String { "http://127.0.0.1:\(server.port)" }
        var paths: [String] { server.paths }
        var count: Int { server.requestCount }

        /// fake_route / fake_route_text: appended, matched in order.
        func route(_ path: String, _ status: Int, _ body: Data = Data("{}".utf8), kind: Kind = .reply) {
            table.withLock { $0.append(Route(path: path, kind: kind, status: status, body: body)) }
        }

        func route(_ path: String, _ status: Int, text: String) {
            route(path, status, Data(text.utf8))
        }

        /// fake_route_front: matched before the routes added earlier.
        func routeFront(_ path: String, _ status: Int, text: String) {
            table.withLock { $0.insert(Route(path: path, status: status, body: Data(text.utf8)), at: 0) }
        }

        func update(_ index: Int, _ change: @Sendable (inout Route) -> Void) {
            table.withLock { change(&$0[index]) }
        }

        /// find_route (:1576-1587): exact path, or a prefix when it ends in '*'.
        private static func find(_ routes: [Route], _ path: String) -> Int? {
            routes.firstIndex { r in
                r.path.hasSuffix("*") ? path.hasPrefix(String(r.path.dropLast())) : path == r.path
            }
        }

        /// http_message (:1589-1602).
        private static func message(_ status: Int, _ body: Data, extra: String = "", declared: Int) -> Data {
            var all = Data(("HTTP/1.1 \(status) X\r\nContent-Type: application/geo+json\r\n\(extra)"
                + "Content-Length: \(declared)\r\nConnection: close\r\n\r\n").utf8)
            all.append(body)
            return all
        }

        private static func reply(_ status: Int, _ body: Data, delayMs: Int) -> LoopbackServer.Step {
            delayMs > 0
                ? .respond(status: status, body: body, delay: .milliseconds(delayMs))
                : .raw(message(status, body, declared: body.count))
        }

        /// handle_request (:1604-1651).
        private static func answer(_ table: LoopbackServer.Shared<[Route]>, _ path: String) -> LoopbackServer.Step {
            table.withLock { routes in
                let empty = Data("{}".utf8)
                guard let i = find(routes, path) else { return .raw(message(404, empty, declared: 2)) }
                routes[i].hits += 1
                let r = routes[i]
                if r.failCount > 0 && r.hits <= r.failCount {
                    return reply(r.failStatus, empty, delayMs: r.delayMs)
                }
                switch r.kind {
                case .hang: return .hang
                case .truncated: return .raw(message(200, r.body, declared: r.body.count + 1000))
                case .gzip: return .gzip(body: r.body)
                case .hold: return .hold(status: r.status, body: r.body)
                case .reply: return reply(r.status, r.body, delayMs: r.delayMs)
                }
            }
        }
    }

    // MARK: Helpers (test-nws.c:90-170, :1780-1876)

    private static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    /// place_at (test-nws.c:93-102).
    private static func place(_ lat: Double, _ lon: Double) throws -> WxPlace {
        try WxPlace(
            name: "Testville", admin1: "Florida", country: "United States", countryCode: "US", lat: lat,
            lon: lon, timezone: "America/New_York")
    }

    /// miami (test-nws.c:104-108).
    private static func miami() throws -> WxPlace { try place(25.7617, -80.1918) }

    /// miami_fake (test-nws.c:1792-1801).
    private static func miamiFake() throws -> Fake {
        let fake = try Fake()
        fake.route("/points/*", 200, try fixture("points_miami.json"))
        fake.route("/gridpoints/MFL/110,50", 200, try fixture("gridpoints_miami.json"))
        return fake
    }

    /// nws_for (test-nws.c:1780-1789).
    private static func nws(
        _ fake: Fake, _ timeoutMs: Int, _ backoffMs: Int, clock: any WxClock = ManualClock(),
        httpClock: any WxClock = SystemClock()
    ) throws -> NWSProvider {
        try NWSProvider(
            testBaseURL: fake.base, timeoutMs: timeoutMs, backoffBaseMs: backoffMs, clock: clock,
            httpClock: httpClock)
    }

    private static func fetch(_ nws: NWSProvider, _ place: WxPlace) async -> Outcome {
        do { return .success(try await nws.fetch(place)) } catch { return .failure(error) }
    }

    private static func start(_ nws: NWSProvider, _ place: WxPlace) -> Task<Outcome, Never> {
        Task { await fetch(nws, place) }
    }

    /// A fetch from a task that is already cancelled when it calls.
    private static func preCancelled(_ nws: NWSProvider, _ place: WxPlace) async -> Outcome {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fetch(nws, place)
        }.value
    }

    private static func wxError(_ o: Outcome) -> WxError? {
        if case .failure(let e as WxError) = o { return e }
        return nil
    }

    private static func isCancelled(_ o: Outcome) -> Bool {
        if case .failure(let e) = o { return e is CancellationError }
        return false
    }

    /// Moves a monotonic ManualClock to an absolute time (C: fake_clock_now = ...).
    private static func set(_ clock: ManualClock, _ us: Int64) async {
        await clock.advance(by: us - clock.monotonicMicroseconds)
    }

    /// assert_failed (test-nws.c:1860-1866).
    private static func expectFailed(
        _ o: Outcome, _ code: WxError.Code, _ message: String? = nil, _ label: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let e = wxError(o)
        #expect(e?.code == code, "\(label): \(o)", sourceLocation: sourceLocation)
        if let message {
            #expect(e?.message == message, "\(label): \(o)", sourceLocation: sourceLocation)
        }
    }

    /// assert_ok (test-nws.c:1868-1876) with check_member (:137-169).
    private static func expectOK(_ o: Outcome, _ label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .success(let r) = o else {
            Issue.record("\(label): expected success, got \(o)", sourceLocation: sourceLocation)
            return
        }
        #expect(r.providerID == "nws", sourceLocation: sourceLocation)
        #expect(r.members.count == 1, sourceLocation: sourceLocation)
        guard let m = r.members.first else { return }
        #expect(m.sourceID == "nws" && m.modelID == "nws", sourceLocation: sourceLocation)
        #expect(m.hours.count >= 1 && m.hours.count <= 400, sourceLocation: sourceLocation)
        #expect(m.quarters.isEmpty, sourceLocation: sourceLocation)
        for (i, h) in m.hours.enumerated() {
            let ok =
                h.tS % 3600 == 0 && (i == 0 || h.tS > m.hours[i - 1].tS) && h.wmo == -1
                && [h.tempC, h.feelsC, h.precipMm, h.precipProb, h.cloudPct, h.windKmh, h.gustKmh,
                    h.humidityPct].contains { $0.isFinite }
                && (WxLimits.valueInRange(h.tempC, -100, 70) || h.tempC.isNaN)
                && (WxLimits.valueInRange(h.feelsC, -100, 70) || h.feelsC.isNaN)
                && (WxLimits.valueInRange(h.windKmh, 0, 500) || h.windKmh.isNaN)
                && (WxLimits.valueInRange(h.gustKmh, 0, 500) || h.gustKmh.isNaN)
                && (WxLimits.valueInRange(h.precipMm, 0, 500) || h.precipMm.isNaN)
                && (WxLimits.valueInRange(h.precipProb, 0, 100) || h.precipProb.isNaN)
                && (WxLimits.valueInRange(h.cloudPct, 0, 100) || h.cloudPct.isNaN)
                && (WxLimits.valueInRange(h.humidityPct, 0, 100) || h.humidityPct.isNaN)
            #expect(ok, "\(label): hour \(i) breaks the member invariants", sourceLocation: sourceLocation)
        }
    }

    /// fake_path (test-nws.c:1765-1770): the path of request `index`. A missing request fails the
    /// test (C: g_assert_cmpuint(index, <, len), :1768) instead of trapping the test process.
    private static func path(_ fake: Fake, _ index: Int, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        let paths = fake.paths
        guard paths.indices.contains(index) else {
            Issue.record("request \(index) missing: \(paths.count) requests \(paths)", sourceLocation: sourceLocation)
            return nil
        }
        return paths[index]
    }

    private static func member(_ o: Outcome) -> WxMember? {
        if case .success(let r) = o { return r.members.first }
        return nil
    }

    // MARK: /nws/net/

    // C: /nws/net/identity (test-nws.c:1887-1927)
    @MainActor @Test func identity() throws {
        let nws = try NWSProvider()
        #expect(nws.id == "nws")                                                    // test-nws.c:1895
        #expect(WxLimits.isValidID(nws.id))                                         // test-nws.c:1896
        #expect(nws.name == "National Weather Service")                             // test-nws.c:1897
        #expect(nws.attribution == "Source: NOAA/National Weather Service")         // test-nws.c:1898
        #expect(nws.attributionURL == "https://www.weather.gov/")                   // test-nws.c:1899
        #expect(NWSProvider.baseURL == "https://api.weather.gov")                   // test-nws.c:1900
        #expect(NWSProvider.userAgent.contains("github.com/wtp128pro/weather"))     // test-nws.c:1901

        let mia = try Self.miami()
        let london = try Self.place(51.5072, -0.1276)                               // test-nws.c:1908
        let sydney = try Self.place(-33.8688, 151.2093)                             // test-nws.c:1909
        #expect(nws.covers(mia))                                                    // test-nws.c:1910
        #expect(nws.covers(try Self.place(61.2181, -149.9003)))                     // test-nws.c:1904, :1911
        #expect(nws.covers(try Self.place(21.3069, -157.8583)))                     // test-nws.c:1905, :1912
        #expect(nws.covers(try Self.place(18.4655, -66.1057)))                      // test-nws.c:1906, :1913
        #expect(nws.covers(try Self.place(13.4443, 144.7937)))                      // test-nws.c:1907, :1914
        #expect(!nws.covers(london))                                                // test-nws.c:1915
        #expect(!nws.covers(sydney))                                                // test-nws.c:1916

        let registry = WxRegistry()
        try registry.addProvider(nws)                                               // test-nws.c:1920-1921
        #expect(registry.findProvider(id: "nws") === nws)                           // test-nws.c:1922
        #expect(registry.listCovering(mia).count == 1)                              // test-nws.c:1924
        #expect(registry.listCovering(london).isEmpty)                              // test-nws.c:1926
    }

    // C: /nws/net/constructors (test-nws.c:1929-1954). C's timing criticals are INVALID_ARG
    // "invalid timing argument" here (HTTPClientPolicy); a NULL base URL cannot be passed.
    @Test func constructors() throws {
        func refusal(_ base: String, _ timeoutMs: Int, _ backoffMs: Int) -> WxError? {
            do {
                _ = try NWSProvider(testBaseURL: base, timeoutMs: timeoutMs, backoffBaseMs: backoffMs, clock: SystemClock())
                return nil
            } catch {
                return error
            }
        }
        #expect(refusal("ftp://127.0.0.1", 1000, 10) == WxError(.invalidArg, "unacceptable base URL"))  // :1933-1935
        #expect(refusal("http://example.com", 1000, 10)?.code == .invalidArg)                          // :1937-1938
        #expect(refusal("http://127.0.0.1:1", 0, 10) == WxError(.invalidArg, "invalid timing argument"))      // :1940
        #expect(refusal("http://127.0.0.1:1", 600_001, 10) == WxError(.invalidArg, "invalid timing argument")) // :1941
        #expect(refusal("http://127.0.0.1:1", 1000, 600_001) == WxError(.invalidArg, "invalid timing argument")) // :1942
        #expect(refusal("http://127.0.0.1:1", 600_000, 0) == nil)                                      // :1944-1946
        #expect(refusal("http://127.0.0.1:1", 1000, 10) == nil)                                        // :1949-1951
        _ = try NWSProvider()                                                                           // :1952-1953
    }

    // C: /nws/net/success-and-request-shape (test-nws.c:1956-1998). fetched_s is checked against
    // the real wall clock as in C: the provider gets SystemClock().
    @Test func successAndRequestShape() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 10, clock: SystemClock())
        let mia = try Self.miami()
        let before = SystemClock().wallSeconds
        let o = await Self.fetch(nws, mia)
        let after = SystemClock().wallSeconds
        Self.expectOK(o)
        #expect(fake.paths == ["/points/25.7617,-80.1918", "/gridpoints/MFL/110,50"]) // test-nws.c:1967-1969
        for (i, request) in fake.server.requests.enumerated() {
            let head = request.head
            #expect(head.hasPrefix("GET \(request.path) HTTP/1.1\r\n"), "\(i)")       // test-nws.c:1972-1973
            #expect(head.contains("\r\nUser-Agent: weather-app/0.1 (github.com/wtp128pro/weather)\r\n"), "\(i)") // :1974
            #expect(head.contains("\r\nAccept: application/geo+json\r\n"), "\(i)")    // test-nws.c:1975
            for absent in ["Cookie", "Authorization", "Referer", "Mozilla", "If-Modified-Since"] {
                #expect(!head.contains(absent), "\(i): \(absent)")                    // test-nws.c:1976-1980
            }
        }
        let m = try #require(Self.member(o))
        #expect(m.fetchedS >= before && m.fetchedS <= after)                        // test-nws.c:1983-1984
        #expect(m.hours.count == 186)                                               // test-nws.c:1987
        #expect(m.hours.first?.tS == Self.t0)                                       // test-nws.c:1988

        // The second fetch of the same point uses the cached cell: gridpoints only.
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 3)                                                    // test-nws.c:1994
        #expect(fake.paths.last == "/gridpoints/MFL/110,50")                        // test-nws.c:1995
    }

    // C: /nws/net/gzip (test-nws.c:2000-2016)
    @Test func gzipAnswers() async throws {
        let fake = try Fake()
        fake.route("/points/*", 200, try Self.fixture("points_miami.json"), kind: .gzip)          // :2006
        fake.route("/gridpoints/MFL/110,50", 200, try Self.fixture("gridpoints_miami.json"), kind: .gzip) // :2007
        let nws = try Self.nws(fake, 5000, 10)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))                      // test-nws.c:2012
        #expect(fake.server.requests.first?.head.contains("Accept-Encoding: gzip") == true) // test-nws.c:2013
    }

    // C: /nws/net/coordinates-rounded (test-nws.c:2018-2052). The C de_DE setlocale part is
    // covered by running this suite with RUN_SUITE_LOCALE=de_DE (no process-global locale here).
    @Test func coordinatesRounded() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 10)
        let cases: [(Double, Double, String)] = [
            (25.123456, -80.987654, "/points/25.1235,-80.9877"),                    // test-nws.c:2027
            (49.99996, -100.00004, "/points/50.0000,-100.0000"),                    // test-nws.c:2028
            (30.5, -90.25, "/points/30.5000,-90.2500"),                             // test-nws.c:2029
            (24.5, -70.25, "/points/24.5000,-70.2500"),                             // test-nws.c:2030
        ]
        for (i, c) in cases.enumerated() {
            Self.expectOK(await Self.fetch(nws, try Self.place(c.0, c.1)), "\(i)")
            #expect(Self.path(fake, 2 * i) == c.2)                                       // test-nws.c:2038
        }
        Self.expectOK(await Self.fetch(nws, try Self.place(31.25, -91.75)))         // test-nws.c:2044-2047
        #expect(Self.path(fake, 8) == "/points/31.2500,-91.7500")                        // test-nws.c:2049
    }

    // C: /nws/net/unsupported-remembered (test-nws.c:2054-2082)
    @Test func unsupportedRemembered() async throws {
        let fake = try Self.miamiFake()
        fake.routeFront("/points/45.5000,-73.6000", 404, text: "{}")                // test-nws.c:2058
        let nws = try Self.nws(fake, 5000, 10)
        let montreal = try Self.place(45.5, -73.6)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside) // test-nws.c:2063
        #expect(fake.count == 1)                                                    // test-nws.c:2065
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside) // test-nws.c:2068
        Self.expectFailed(
            await Self.fetch(nws, try Self.place(45.500004, -73.599996)), .unsupported, Self.msgOutside) // :2070-2072
        #expect(fake.count == 1)                                                    // test-nws.c:2074
        Self.expectOK(await Self.fetch(nws, try Self.miami()))                      // test-nws.c:2078
        #expect(fake.count == 3)                                                    // test-nws.c:2080
    }

    // C: /nws/net/unsupported-bounded (test-nws.c:2084-2114)
    @Test func unsupportedBounded() async throws {
        let fake = try Fake()
        fake.route("/points/*", 404, text: "{}")                                    // test-nws.c:2088
        let nws = try Self.nws(fake, 5000, 10)
        #expect(NWSProvider.cacheMax == 64)                                         // test-nws.c:2090
        for i in 0..<65 {
            let o = await Self.fetch(nws, try Self.place(30.0 + Double(i) * 0.01, -90.0))
            Self.expectFailed(o, .unsupported, Self.msgOutside, "\(i)")             // test-nws.c:2095
        }
        #expect(fake.count == 65)                                                   // test-nws.c:2098
        for i in 1..<65 {
            let o = await Self.fetch(nws, try Self.place(30.0 + Double(i) * 0.01, -90.0))
            Self.expectFailed(o, .unsupported, Self.msgOutside, "\(i)")             // test-nws.c:2103
        }
        #expect(fake.count == 65)                                                   // test-nws.c:2106
        Self.expectFailed(await Self.fetch(nws, try Self.place(30.0, -90.0)), .unsupported, Self.msgOutside) // :2109
        #expect(fake.count == 66)                                                   // test-nws.c:2111
        #expect(Self.path(fake, 65) == "/points/30.0000,-90.0000")                       // test-nws.c:2112
    }

    // C: /nws/net/grid-cache (test-nws.c:2116-2174). C rewinds its hook clock to (1000 + TTL) s
    // before the cap phase (:2151); a ManualClock only moves forward, so the cap phase runs at
    // (1000 + 2 TTL) s - 1 us, where Miami's refreshed cell (expiring at (1000 + 2 TTL) s) is
    // still live, the same precondition the rewind establishes.
    @Test func gridCache() async throws {
        let fake = try Self.miamiFake()
        let clock = ManualClock(monotonicMicroseconds: 1000 * Self.usec)           // test-nws.c:2123
        let nws = try Self.nws(fake, 5000, 10, clock: clock)
        let mia = try Self.miami()
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 2)                                                    // test-nws.c:2128
        await Self.set(clock, (1000 + Self.ttlS) * Self.usec - 1)                   // test-nws.c:2130
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 3)                                                    // test-nws.c:2134
        #expect(Self.path(fake, 2) == "/gridpoints/MFL/110,50")                          // test-nws.c:2135
        await Self.set(clock, (1000 + Self.ttlS) * Self.usec)                       // test-nws.c:2137
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 5)                                                    // test-nws.c:2141
        #expect(Self.path(fake, 3) == "/points/25.7617,-80.1918")                        // test-nws.c:2142
        await clock.advance(by: Self.ttlS * Self.usec - 1)                          // test-nws.c:2144
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 6)                                                    // test-nws.c:2148
        #expect(Self.path(fake, 5) == "/gridpoints/MFL/110,50")                          // test-nws.c:2149

        for i in 0..<64 {
            Self.expectOK(await Self.fetch(nws, try Self.place(30.0 + Double(i) * 0.01, -90.0)), "\(i)") // :2153-2157
        }
        var before = fake.count
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == before + 2)                                           // test-nws.c:2163
        #expect(Self.path(fake, before) == "/points/25.7617,-80.1918")                   // test-nws.c:2164
        before = fake.count
        Self.expectOK(await Self.fetch(nws, try Self.place(30.01, -90.0)))          // test-nws.c:2167-2169
        #expect(fake.count == before + 1)                                           // test-nws.c:2171
    }

    // C: /nws/net/rate-limit-429 (test-nws.c:2176-2214)
    @Test func rateLimit429() async throws {
        let fake = try Self.miamiFake()
        fake.routeFront("/points/30.0000,-90.0000", 429, text: "{}")                // test-nws.c:2180
        let clock = ManualClock(monotonicMicroseconds: 50 * Self.usec)             // test-nws.c:2185
        let nws = try Self.nws(fake, 5000, 10, clock: clock)
        let limited = try Self.place(30.0, -90.0)
        let mia = try Self.miami()
        Self.expectFailed(await Self.fetch(nws, limited), .rateLimited)             // test-nws.c:2188-2189
        #expect(fake.count == 1)                                                    // test-nws.c:2191
        for offset in [0, 1, 2 * Self.usec, 5 * Self.usec - 1] {                    // test-nws.c:2193
            await Self.set(clock, 50 * Self.usec + offset)                          // test-nws.c:2195
            Self.expectFailed(await Self.fetch(nws, mia), .rateLimited, Self.msgPaused, "\(offset)")     // :2197-2198
            Self.expectFailed(await Self.fetch(nws, limited), .rateLimited, Self.msgPaused, "\(offset)") // :2201-2202
        }
        #expect(fake.count == 1)                                                    // test-nws.c:2205
        await Self.set(clock, 50 * Self.usec + 5 * Self.usec)                       // test-nws.c:2207
        Self.expectOK(await Self.fetch(nws, mia))                                   // test-nws.c:2209
        #expect(fake.count == 3)                                                    // test-nws.c:2211
    }

    // C: /nws/net/rate-limit-steps (test-nws.c:2216-2259). In part 2 B is started once A's
    // /points request has reached the server (C: fetch_start(A) sends it before B starts).
    @Test func rateLimitSteps() async throws {
        let fake = try Fake()
        fake.route("/gridpoints/MFL/110,50", 429, text: "{}")                       // test-nws.c:2221
        fake.route("/points/*", 200, try Self.fixture("points_miami.json"))         // test-nws.c:2222
        let clock = ManualClock(monotonicMicroseconds: 70 * Self.usec)             // test-nws.c:2226
        let nws = try Self.nws(fake, 5000, 10, clock: clock)
        let mia = try Self.miami()
        Self.expectFailed(await Self.fetch(nws, mia), .rateLimited)                 // test-nws.c:2229
        #expect(fake.count == 2)                                                    // test-nws.c:2231
        Self.expectFailed(await Self.fetch(nws, mia), .rateLimited)                 // test-nws.c:2233
        #expect(fake.count == 2)                                                    // test-nws.c:2235

        let fake2 = try Fake()
        fake2.route("/points/25.7617,-80.1918", 200, try Self.fixture("points_miami.json")) // :2242
        fake2.update(0) { $0.delayMs = 300 }                                        // test-nws.c:2243
        fake2.route("/points/30.0000,-90.0000", 429, text: "{}")                    // test-nws.c:2244
        fake2.route("/gridpoints/MFL/110,50", 200, try Self.fixture("gridpoints_miami.json")) // :2245
        let nws2 = try Self.nws(fake2, 5000, 10)
        let a = Self.start(nws2, mia)
        #expect(await fake2.server.waitForRequests(1))
        let b = Self.start(nws2, try Self.place(30.0, -90.0))
        Self.expectFailed(await b.value, .rateLimited, nil, "b")                    // test-nws.c:2252
        Self.expectFailed(await a.value, .rateLimited, nil, "a")                    // test-nws.c:2254
        #expect(fake2.count == 2)                                                   // test-nws.c:2255
    }

    // C: /nws/net/http-errors (test-nws.c:2261-2292)
    @Test func httpErrors() async throws {
        let cases: [(points: Int, grid: Int, code: WxError.Code, requests: Int)] = [
            (500, 200, .http, 3),                                                   // test-nws.c:2270
            (403, 200, .http, 1),                                                   // test-nws.c:2271
            (301, 200, .http, 1),                                                   // test-nws.c:2272
            (200, 500, .http, 4),                                                   // test-nws.c:2273
            (200, 404, .notFound, 2),                                               // test-nws.c:2274
            (200, 403, .http, 2),                                                   // test-nws.c:2275
        ]
        for c in cases {
            let fake = try Fake()
            fake.route("/points/*", c.points, c.points == 200 ? try Self.fixture("points_miami.json") : Data("{}".utf8))
            fake.route("/gridpoints/MFL/110,50", c.grid, text: "{}")
            let nws = try Self.nws(fake, 5000, 5)
            Self.expectFailed(await Self.fetch(nws, try Self.miami()), c.code, nil, "\(c)") // test-nws.c:2286-2287
            #expect(fake.count == c.requests, "\(c)")                               // test-nws.c:2288
        }
    }

    // C: /nws/net/transient-5xx (test-nws.c:2294-2310)
    @Test func transient5xx() async throws {
        let fake = try Self.miamiFake()
        fake.update(0) { $0.failStatus = 503; $0.failCount = 1 }                    // test-nws.c:2298-2299
        fake.update(1) { $0.failStatus = 500; $0.failCount = 2 }                    // test-nws.c:2300-2301
        let nws = try Self.nws(fake, 5000, 5)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))                      // test-nws.c:2306
        #expect(fake.count == 5)                                                    // test-nws.c:2307
    }

    // C: /nws/net/grid-404 (test-nws.c:2312-2337)
    @Test func grid404ForgetsTheCell() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let mia = try Self.miami()
        Self.expectOK(await Self.fetch(nws, mia))                                   // test-nws.c:2320
        #expect(fake.count == 2)                                                    // test-nws.c:2322
        fake.update(1) { $0.status = 404 }                                          // test-nws.c:2324
        Self.expectFailed(await Self.fetch(nws, mia), .notFound)                    // test-nws.c:2326
        #expect(fake.count == 3)                                                    // test-nws.c:2328
        fake.update(1) { $0.status = 200 }                                          // test-nws.c:2330
        Self.expectOK(await Self.fetch(nws, mia))                                   // test-nws.c:2332
        #expect(fake.count == 5)                                                    // test-nws.c:2334
        #expect(Self.path(fake, 3) == "/points/25.7617,-80.1918")                        // test-nws.c:2335
    }

    // C: /nws/net/bad-bodies (test-nws.c:2339-2377)
    @Test func badBodies() async throws {
        let grid = "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}"
        let cases: [(points: String, grid: String, code: WxError.Code, message: String, requests: Int)] = [
            ("{}", "{}", .parse, Self.msgNoGrid, 1),                                // test-nws.c:2349
            ("not json", "{}", .parse, "malformed JSON", 1),                        // test-nws.c:2350
            ("[]", "{}", .parse, "response is not a JSON object", 1),               // test-nws.c:2351
            (grid, "{}", .parse, Self.msgNoProps, 2),                               // test-nws.c:2352-2353
            (grid, "{\"properties\":{}}", .notFound, Self.msgNoData, 2),            // test-nws.c:2354-2355
            (grid, "", .parse, "empty response", 2),                                // test-nws.c:2356-2357
            ("{\"properties\":{\"gridId\":\"M/L\",\"gridX\":110,\"gridY\":50}}", "{}", .parse, Self.msgNoGrid, 1), // :2359-2360
            ("{\"properties\":{\"gridId\":\"../\",\"gridX\":1,\"gridY\":50}}", "{}", .parse, Self.msgNoGrid, 1),   // :2361-2362
        ]
        for (i, c) in cases.enumerated() {
            let fake = try Fake()
            fake.route("/points/*", 200, text: c.points)
            fake.route("/gridpoints/MFL/110,50", 200, text: c.grid)
            let nws = try Self.nws(fake, 5000, 5)
            Self.expectFailed(await Self.fetch(nws, try Self.miami()), c.code, c.message, "\(i)") // test-nws.c:2372
            #expect(fake.count == c.requests, "\(i)")                               // test-nws.c:2373
        }
    }

    // C: /nws/net/truncated-and-hanging (test-nws.c:2379-2405)
    @Test func truncatedAndHanging() async throws {
        let fake = try Self.miamiFake()
        fake.update(0) { $0.kind = .truncated }                                     // test-nws.c:2384
        let nws = try Self.nws(fake, 5000, 5)
        Self.expectFailed(await Self.fetch(nws, try Self.miami()), .network)        // test-nws.c:2389-2390
        #expect(fake.count == 3)                                                    // test-nws.c:2391

        let fake2 = try Self.miamiFake()
        fake2.update(1) { $0.kind = .hang }                                         // test-nws.c:2397
        let nws2 = try Self.nws(fake2, 150, 5)                                      // test-nws.c:2398
        Self.expectFailed(await Self.fetch(nws2, try Self.miami()), .timeout)       // test-nws.c:2400-2401
        #expect(fake2.count == 4)                                                   // test-nws.c:2402
    }

    // C: /nws/net/cancellation (test-nws.c:2407-2466), parts 1-3. Part 4, "cancelled after
    // success but before finish" (:2456-2463), is not ported: fetch has no suspension point
    // between the last response and its return, so that window cannot be reached
    // deterministically (the final Task.checkCancellation is pinned for refusals by
    // cancelledBeatsRefusals). The last block below is an executor case instead: cancelled while
    // the /gridpoints answer is held on its way, then released.
    @Test func cancellation() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let mia = try Self.miami()

        #expect(Self.isCancelled(await Self.preCancelled(nws, mia)))                // test-nws.c:2421
        #expect(fake.count == 0)                                                    // test-nws.c:2422

        fake.update(0) { $0.kind = .hang }                                          // test-nws.c:2426
        let t1 = Self.start(nws, mia)
        #expect(await fake.server.waitForRequests(1))                               // test-nws.c:2429-2430
        t1.cancel()
        #expect(Self.isCancelled(await t1.value))                                   // test-nws.c:2434
        #expect(fake.count == 1)                                                    // test-nws.c:2435

        fake.update(0) { $0.kind = .reply }                                         // test-nws.c:2439
        fake.update(1) { $0.kind = .hang }                                          // test-nws.c:2440
        let t2 = Self.start(nws, mia)
        #expect(await fake.server.waitForRequests(3))                               // test-nws.c:2443-2444
        t2.cancel()
        #expect(Self.isCancelled(await t2.value))                                   // test-nws.c:2447
        fake.update(1) { $0.kind = .reply }                                         // test-nws.c:2449
        let before = fake.count
        Self.expectOK(await Self.fetch(nws, mia))                                   // test-nws.c:2452
        #expect(fake.count == before + 1)                                           // test-nws.c:2453

        // C: none - cancelled while the /gridpoints answer is held, then released.
        fake.update(1) { $0.kind = .hold }
        let t3 = Self.start(nws, mia)
        #expect(await fake.server.waitUntil { $0.heldCount == 1 })
        t3.cancel()
        _ = fake.server.release()
        #expect(Self.isCancelled(await t3.value))
    }

    // C: /nws/net/cancelled-beats-refusals (test-nws.c:2468-2502). C's hand-built invalid place
    // (:2480) cannot exist: WxPlace is valid by construction (see invalidAndUncovered).
    @Test func cancelledBeatsRefusals() async throws {
        let fake = try Fake()
        fake.route("/points/45.5000,-73.6000", 404, text: "{}")                     // test-nws.c:2474
        fake.route("/points/30.0000,-90.0000", 429, text: "{}")                     // test-nws.c:2475
        let nws = try Self.nws(fake, 5000, 5)
        let montreal = try Self.place(45.5, -73.6)
        let limited = try Self.place(30.0, -90.0)
        let sydney = try Self.place(-33.8688, 151.2093)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside) // test-nws.c:2483
        Self.expectFailed(await Self.fetch(nws, limited), .rateLimited)             // test-nws.c:2486
        #expect(fake.count == 2)                                                    // test-nws.c:2488
        for (i, p) in [montreal, limited, sydney].enumerated() {
            #expect(Self.isCancelled(await Self.preCancelled(nws, p)), "\(i)")      // test-nws.c:2497
        }
        #expect(fake.count == 2)                                                    // test-nws.c:2500
    }

    // C: /nws/net/dispose-in-flight (test-nws.c:2504-2541), parts 1 and 3: dropping the last
    // reference of the provider while fetches run does not stop them. Part 2
    // (g_object_run_dispose) has no Swift counterpart.
    @Test func droppedProviderInFlight() async throws {
        let fake = try Self.miamiFake()
        fake.update(0) { $0.delayMs = 150 }                                         // test-nws.c:2508
        fake.update(1) { $0.delayMs = 150 }                                         // test-nws.c:2509
        let mia = try Self.miami()
        var nws: NWSProvider? = try Self.nws(fake, 5000, 5)
        let o = Self.start(nws!, mia)
        nws = nil                                                                   // test-nws.c:2514
        Self.expectOK(await o.value)                                                // test-nws.c:2516

        nws = try Self.nws(fake, 5000, 5)
        let p1 = Self.start(nws!, mia)
        let p2 = Self.start(nws!, mia)
        nws = nil                                                                   // test-nws.c:2533
        Self.expectOK(await p1.value)                                               // test-nws.c:2536
        Self.expectOK(await p2.value)                                               // test-nws.c:2537
    }

    // C: /nws/net/callback-not-before-return (test-nws.c:2559-2623): the outcomes of the
    // refusals. "The callback never runs before the call returns" is a GLib callback rule with
    // no async/await counterpart; the invalid place cannot be built (see invalidAndUncovered).
    @Test func refusalsWithoutTraffic() async throws {
        let fake = try Self.miamiFake()
        fake.routeFront("/points/45.5000,-73.6000", 404, text: "{}")                // test-nws.c:2563
        let nws = try Self.nws(fake, 5000, 5)
        let montreal = try Self.place(45.5, -73.6)
        let mia = try Self.miami()
        _ = await Self.fetch(nws, montreal)                                         // test-nws.c:2574
        Self.expectFailed(await Self.fetch(nws, try Self.place(51.5, -0.12)), .unsupported, Self.msgOutside) // :2582, :2590
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside) // test-nws.c:2583, :2590
        #expect(Self.isCancelled(await Self.preCancelled(nws, mia)))                // test-nws.c:2600
        #expect(fake.count == 1)                                                    // test-nws.c:2602

        let fake2 = try Fake()
        fake2.route("/points/*", 429, text: "{}")                                   // test-nws.c:2610
        let nws2 = try Self.nws(fake2, 5000, 5)
        Self.expectFailed(await Self.fetch(nws2, mia), .rateLimited)                // test-nws.c:2613
        Self.expectFailed(await Self.fetch(nws2, mia), .rateLimited)                // test-nws.c:2619
        #expect(fake2.count == 1)                                                   // test-nws.c:2621
    }

    // C: /nws/net/invalid-and-uncovered (test-nws.c:2625-2646). The three invalid places
    // (:2631-2633) cannot be built: WxPlace's initialiser refuses them with INVALID_ARG (its own
    // messages, not C's "invalid place"), so no fetch of an invalid place exists.
    @Test func invalidAndUncovered() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let invalid: [(name: String?, lat: Double, lon: Double)] = [
            ("X", .nan, -80.0),                                                     // test-nws.c:2631
            ("X", 95.0, -80.0),                                                     // test-nws.c:2632
            (nil, 30.0, -80.0),                                                     // test-nws.c:2633
        ]
        for (i, c) in invalid.enumerated() {
            do {
                _ = try WxPlace(name: c.name, lat: c.lat, lon: c.lon)
                Issue.record("\(i): an invalid place was built")
            } catch {
                #expect(error.code == .invalidArg, "\(i)")                         // test-nws.c:2637
            }
        }
        Self.expectFailed(
            await Self.fetch(nws, try Self.place(-33.8688, 151.2093)), .unsupported, Self.msgOutside) // :2640-2642
        #expect(fake.count == 0)                                                    // test-nws.c:2644
    }

    // C: /nws/net/concurrent (test-nws.c:2668-2689)
    @Test func concurrentFetches() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let a = try Self.miami()
        let b = try Self.place(30.0, -90.0)                                         // test-nws.c:2674
        let oa = Self.start(nws, a), ob = Self.start(nws, b), oc = Self.start(nws, a)
        Self.expectOK(await oa.value, "a")                                          // test-nws.c:2682
        Self.expectOK(await ob.value, "b")                                          // test-nws.c:2683
        Self.expectOK(await oc.value, "c")                                          // test-nws.c:2684
    }

    // MARK: Contract rows beyond the C tests (wx-nws.h; L5 sweep)

    // C: none (contract wx-nws.h:24-27, wx-nws.c:689-697): the client's own in-flight cap
    // refusal (RATE_LIMITED, no traffic) starts the same 5 s pause as a 429.
    @Test func capRefusalStartsThePause() async throws {
        let clock = ManualClock(monotonicMicroseconds: 10 * Self.usec)
        let (fake, nws, hanging) = try await Self.fullCap(clock)
        #expect(nws.http.outstandingCount == 16)
        Self.expectFailed(
            await Self.fetch(nws, try Self.place(31.0, -90.0)), .rateLimited,
            "too many outstanding requests (limit 16)")                             // wx-http.c:2065-2066
        Self.expectFailed(await Self.fetch(nws, try Self.miami()), .rateLimited, Self.msgPaused)
        await clock.advance(by: 5 * Self.usec - 1)
        Self.expectFailed(await Self.fetch(nws, try Self.miami()), .rateLimited, Self.msgPaused)
        // Only 2 of the 16 hanging /points/30.xx requests are on the wire (2 connections per host),
        // and they may still be arriving; the refused fetches themselves made no request.
        #expect(Self.refusedTraffic(fake).isEmpty, "\(fake.paths)")
        for t in hanging { t.cancel() }
        for t in hanging { #expect(Self.isCancelled(await t.value)) }
        await clock.advance(by: 1)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))
    }

    /// Requests of the places the cap tests refuse (31.0000,-90.0000 and Miami) or of step 2.
    private static func refusedTraffic(_ fake: Fake) -> [String] {
        fake.paths.filter {
            $0.hasPrefix("/points/31.0000") || $0.hasPrefix("/points/25.7617") || $0.hasPrefix("/gridpoints/")
        }
    }

    /// 16 fetches of 30.00..30.15,-90 that hang until cancelled (the client's cap is full), with
    /// Miami served; the client's deadlines run on a clock that never moves.
    private static func fullCap(_ clock: ManualClock) async throws -> (Fake, NWSProvider, [Task<Outcome, Never>]) {
        let fake = try Fake()
        fake.route("/points/30.*", 200, kind: .hang)
        fake.route("/points/25.7617,-80.1918", 200, try Self.fixture("points_miami.json"))
        fake.route("/gridpoints/MFL/110,50", 200, try Self.fixture("gridpoints_miami.json"))
        let nws = try Self.nws(fake, 5000, 5, clock: clock, httpClock: ManualClock())
        let hanging = try (0..<16).map { i in Self.start(nws, try Self.place(30.0 + Double(i) * 0.01, -90.0)) }
        let deadline = ContinuousClock.now + .seconds(10)
        while nws.http.outstandingCount < 16 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return (fake, nws, hanging)
    }

    // C: none (GTask check_cancellable: WxHttp's task carries the caller's cancellable,
    // wx-http.c:2054, so a cancelled caller gets G_IO_ERROR_CANCELLED even for the cap refusal,
    // :2063-2067, and note_failure, wx-nws.c:692, starts no pause): a cancelled fetch refused at
    // the client's cap starts no pause, so Miami succeeds afterwards with the clock unmoved.
    @Test func cancelledCapRefusalStartsNoPause() async throws {
        let clock = ManualClock(monotonicMicroseconds: 10 * Self.usec)
        let (fake, nws, hanging) = try await Self.fullCap(clock)
        #expect(nws.http.outstandingCount == 16)
        #expect(Self.isCancelled(await Self.preCancelled(nws, try Self.place(31.0, -90.0))))
        for t in hanging { t.cancel() }
        for t in hanging { #expect(Self.isCancelled(await t.value)) }
        Self.expectOK(await Self.fetch(nws, try Self.miami()))
        #expect(!fake.paths.contains { $0.hasPrefix("/points/31.0000") })
    }

    // C: none (point_key wx-nws.c:860-866: wx_geo_round4, then "%.4f"). Coordinates whose binary
    // value lies near a half-way point, where printf alone rounds the other way. Expected keys:
    // the unmodified C point_key (U23 differential harness, scratchpad U23-cdiff).
    @Test func pointKeyUsesRound4() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let cases: [(Double, Double, String)] = [
            (37.11935, -70.63965, "/points/37.1194,-70.6397"),
            (28.76675, -108.22444, "/points/28.7668,-108.2244"),
            (31.36409, -89.92165, "/points/31.3641,-89.9217"),
        ]
        for (i, c) in cases.enumerated() {
            Self.expectOK(await Self.fetch(nws, try Self.place(c.0, c.1)), "\(i)")
            #expect(Self.path(fake, 2 * i) == c.2, "\(i)")
        }
    }

    // C: none (cache_lookup wx-nws.c:402-415 never reorders; cache_store :434-451 evicts index 0):
    // the grid cache is FIFO by store, not LRU - a cache hit does not save a cell from eviction.
    @Test func gridCacheIsFIFONotLRU() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let mia = try Self.miami()
        Self.expectOK(await Self.fetch(nws, mia))                                   // stored 1st
        for i in 0..<63 {                                                           // stored 2nd..64th
            Self.expectOK(await Self.fetch(nws, try Self.place(30.0 + Double(i) * 0.01, -90.0)), "\(i)")
        }
        var before = fake.count
        Self.expectOK(await Self.fetch(nws, mia))                                   // a hit
        #expect(fake.count == before + 1)
        Self.expectOK(await Self.fetch(nws, try Self.place(30.63, -90.0)))          // 65th store evicts Miami
        before = fake.count
        Self.expectOK(await Self.fetch(nws, try Self.place(30.0, -90.0)))           // still cached
        #expect(fake.count == before + 1)
        before = fake.count
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == before + 2)
        #expect(Self.path(fake, before) == "/points/25.7617,-80.1918")
    }

    // C: none (on_grid_done wx-nws.c:820-826 removes the entry of the fetch's own key): a /gridpoints
    // 404 forgets only that point's cell, also when another point shares the same grid.
    @Test func grid404ForgetsOnlyThatPoint() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let mia = try Self.miami()
        let other = try Self.place(30.0, -90.0)                                     // also MFL 110,50
        Self.expectOK(await Self.fetch(nws, mia))
        Self.expectOK(await Self.fetch(nws, other))
        #expect(fake.count == 4)
        fake.update(1) { $0.status = 404 }
        Self.expectFailed(await Self.fetch(nws, mia), .notFound)
        #expect(fake.count == 5)
        fake.update(1) { $0.status = 200 }
        Self.expectOK(await Self.fetch(nws, other))
        #expect(fake.count == 6)                                                    // other's cell kept
        #expect(Self.path(fake, 5) == "/gridpoints/MFL/110,50")
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 8)                                                    // Miami resolved again
        #expect(Self.path(fake, 6) == "/points/25.7617,-80.1918")
    }

    // C: none (on_grid_done wx-nws.c:816-828 forgets the cell on NOT_FOUND only): a /gridpoints
    // 500 (retried by the client, then HTTP) keeps the cell.
    @Test func grid500KeepsTheCell() async throws {
        let fake = try Self.miamiFake()
        let nws = try Self.nws(fake, 5000, 5)
        let mia = try Self.miami()
        Self.expectOK(await Self.fetch(nws, mia))
        fake.update(1) { $0.status = 500 }
        Self.expectFailed(await Self.fetch(nws, mia), .http)
        let afterError = fake.count
        #expect(!fake.paths.dropFirst(2).contains { $0.hasPrefix("/points/") })
        fake.update(1) { $0.status = 200 }
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == afterError + 1)
        #expect(fake.paths.last == "/gridpoints/MFL/110,50")
    }

    // C: none (note_failure wx-nws.c:692 reacts to RATE_LIMITED only; the brief forbids
    // compensating other codes, DECISIONS #45 N16): a TIMEOUT starts no pause.
    @Test func timeoutStartsNoPause() async throws {
        let fake = try Fake()
        fake.route("/points/30.0000,-90.0000", 200, kind: .hang)
        fake.route("/points/*", 200, try Self.fixture("points_miami.json"))
        fake.route("/gridpoints/MFL/110,50", 200, try Self.fixture("gridpoints_miami.json"))
        let nws = try Self.nws(fake, 150, 5)
        Self.expectFailed(await Self.fetch(nws, try Self.place(30.0, -90.0)), .timeout)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))                      // clock unmoved
    }

    // C: none (contract wx-nws.c:689-697 "never earlier than before"): a later RATE_LIMITED
    // answer moves the end of the pause to 5 s after it.
    @Test func laterRateLimitExtendsThePause() async throws {
        let fake = try Fake()
        fake.route("/points/31.0000,-90.0000", 429, Data("{}".utf8), kind: .hold)
        fake.route("/points/30.0000,-90.0000", 429, text: "{}")
        fake.route("/points/25.7617,-80.1918", 200, try Self.fixture("points_miami.json"))
        fake.route("/gridpoints/MFL/110,50", 200, try Self.fixture("gridpoints_miami.json"))
        let clock = ManualClock(monotonicMicroseconds: 100 * Self.usec)
        let nws = try Self.nws(fake, 5000, 5, clock: clock)
        let held = Self.start(nws, try Self.place(31.0, -90.0))
        #expect(await fake.server.waitUntil { $0.heldCount == 1 })
        Self.expectFailed(await Self.fetch(nws, try Self.place(30.0, -90.0)), .rateLimited) // pause until 105 s
        await clock.advance(by: 2 * Self.usec)
        _ = fake.server.release()
        Self.expectFailed(await held.value, .rateLimited)                           // pause until 107 s
        await Self.set(clock, 107 * Self.usec - 1)
        let sent = fake.count
        Self.expectFailed(await Self.fetch(nws, try Self.miami()), .rateLimited, Self.msgPaused)
        #expect(fake.count == sent)
        await clock.advance(by: 1)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))
    }

    // C: none (order of the checks in nws_fetch_async, wx-nws.c:898-918): the coverage box,
    // then a remembered 404, then the pause; all without traffic.
    @Test func refusalOrderAtFetchStart() async throws {
        let fake = try Self.miamiFake()
        fake.routeFront("/points/45.5000,-73.6000", 404, text: "{}")
        fake.routeFront("/points/30.0000,-90.0000", 429, text: "{}")
        let nws = try Self.nws(fake, 5000, 5)
        let montreal = try Self.place(45.5, -73.6)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside)
        Self.expectFailed(await Self.fetch(nws, try Self.place(30.0, -90.0)), .rateLimited)
        #expect(fake.count == 2)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside)
        Self.expectFailed(
            await Self.fetch(nws, try Self.place(-33.8688, 151.2093)), .unsupported, Self.msgOutside)
        Self.expectFailed(await Self.fetch(nws, try Self.miami()), .rateLimited, Self.msgPaused)
        #expect(fake.count == 2)
    }

    // C: none (contract wx-nws.c:774-790, :820-826): only a /points 404 remembers a point and
    // only a /gridpoints 404 forgets the cell; other failures leave both caches unchanged, and
    // an unsupported mark never expires (G_MAXINT64, :775).
    @Test func otherFailuresKeepTheCaches() async throws {
        let fake = try Self.miamiFake()
        let clock = ManualClock()
        let nws = try Self.nws(fake, 5000, 5, clock: clock)
        let mia = try Self.miami()
        let points = try Self.fixture("points_miami.json")
        let grid = try Self.fixture("gridpoints_miami.json")
        fake.update(0) { $0.status = 500 }
        Self.expectFailed(await Self.fetch(nws, mia), .http)
        fake.update(0) { $0.status = 200; $0.body = Data("{}".utf8) }
        Self.expectFailed(await Self.fetch(nws, mia), .parse, Self.msgNoGrid)
        #expect(fake.count == 4)
        fake.update(0) { $0.body = points }
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == 6)                                                    // not remembered: /points again
        fake.update(1) { $0.status = 500 }
        Self.expectFailed(await Self.fetch(nws, mia), .http)
        fake.update(1) { $0.status = 200; $0.body = Data("{}".utf8) }
        Self.expectFailed(await Self.fetch(nws, mia), .parse, Self.msgNoProps)
        fake.update(1) { $0.body = grid }
        let before = fake.count
        Self.expectOK(await Self.fetch(nws, mia))
        #expect(fake.count == before + 1)                                           // the cell was kept
        #expect(fake.paths.last == "/gridpoints/MFL/110,50")

        fake.routeFront("/points/45.5000,-73.6000", 404, text: "{}")
        let montreal = try Self.place(45.5, -73.6)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside)
        let sent = fake.count
        await clock.advance(by: 100 * Self.ttlS * Self.usec)
        Self.expectFailed(await Self.fetch(nws, montreal), .unsupported, Self.msgOutside)
        #expect(fake.count == sent)
    }

    // C: none (contract wx-nws.h:146-147, net-providers.md:242): the /gridpoints path comes from
    // the validated gridId/gridX/gridY only; server-supplied URLs are never followed.
    @Test func gridpointsPathFromValidatedCellOnly() async throws {
        let fake = try Fake()
        fake.route("/points/*", 200, text: "{\"properties\":{\"gridId\":\"ABC\",\"gridX\":0,\"gridY\":999,"
            + "\"forecastGridData\":\"https://evil.example/gridpoints/XYZ/1,2\","
            + "\"forecastHourly\":\"http://127.0.0.1:1/x\"}}")
        fake.route("/gridpoints/ABC/0,999", 200, try Self.fixture("gridpoints_miami.json"))
        let nws = try Self.nws(fake, 5000, 5)
        Self.expectOK(await Self.fetch(nws, try Self.miami()))
        #expect(fake.paths == ["/points/25.7617,-80.1918", "/gridpoints/ABC/0,999"])
    }

    // C: none (wx-nws.h:50-51): fetchedS is the wall clock when the second response arrived;
    // here the injected clock's wall time (C reads g_get_real_time(), unhooked).
    @Test func fetchedTimeFromTheInjectedClock() async throws {
        let fake = try Self.miamiFake()
        let clock = ManualClock(wallMicroseconds: 1_791_806_400_123_456)
        let nws = try Self.nws(fake, 5000, 5, clock: clock)
        let m = try #require(Self.member(await Self.fetch(nws, try Self.miami())))
        #expect(m.fetchedS == 1_791_806_400)
    }

    // C: none (DECISIONS #34 condition 10): the production client is built from the fixed https
    // base URL with the NWS User-Agent and the default timing; the test initialiser refuses
    // every https origin (C's wx_nws_new_custom accepted any), so no other host is reachable.
    @Test func productionOriginIsFixed() throws {
        let nws = try NWSProvider()
        #expect(nws.http.policy.origin == "https://api.weather.gov")
        #expect(nws.http.policy.userAgent == "weather-app/0.1 (github.com/wtp128pro/weather)") // wx-nws.h:70
        #expect(nws.http.policy.timeoutMs == 10_000)                                // wx-http.h WX_HTTP_TIMEOUT_MS
        #expect(nws.http.policy.backoffBaseMs == 1_000)                             // WX_HTTP_BACKOFF_BASE_MS
        #expect(nws.http.policy.minGapMs == 0)                                      // wx-nws.c:523 (no pacing)
        for base in ["https://api.weather.gov", "https://example.com", "https://127.0.0.1:1"] {
            #expect(throws: WxError(.invalidArg, "unacceptable base URL"), "\(base)") {
                _ = try NWSProvider(testBaseURL: base, timeoutMs: 1000, backoffBaseMs: 10, clock: SystemClock())
            }
        }
    }

    // C: none (documented difference, DECISIONS #34 item 3 / #36 N1, not compensated): a 429
    // head that CFNetwork refuses arrives as NETWORK after 3 requests, so no pause starts.
    @Test func refused429HeadStartsNoPause() async throws {
        let head = "HTTP/1.1 429 X\r\nContent-Type: application/json\r\nContent-Length: 2\r\n"
            + "Content-Length: 3\r\nConnection: close\r\n\r\n{}"
        let server = try LoopbackServer(routes: [
            .init("/points/30.0000,-90.0000", [.rawText(head)]),
        ], fallback: [.text("{}", status: 404)])
        defer { server.stop() }
        let nws = try NWSProvider(
            testBaseURL: "http://127.0.0.1:\(server.port)", timeoutMs: 5000, backoffBaseMs: 5, clock: ManualClock())
        Self.expectFailed(await Self.fetch(nws, try Self.place(30.0, -90.0)), .network)
        #expect(server.requestCount == 3)
        // Not paused: the next fetch reaches the server (the fallback 404 marks it unsupported).
        Self.expectFailed(await Self.fetch(nws, try Self.place(31.0, -90.0)), .unsupported, Self.msgOutside)
        #expect(server.requestCount == 4)
    }
}
