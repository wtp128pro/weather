// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// METNorwayProviderTests.swift - the provider/ and net/ groups of
// src/providers/metno/test-metno.c (registrations :4304-4346) and
// src/providers/metno/test-metno-production.c, ported to METNorwayProvider on
// the U03 LoopbackServer. Each test names its C path; expected values are the
// C tests' literals (file:LINE).
//
// C harness -> Swift:
//  - wx_metno_test_set_clock(test_clock) -> the provider's injected ManualClock
//    (clock_set(t) = `set(clock, t)`); clock_system() -> SystemClock. The HTTP
//    client keeps the real clock, as WxHttp did (its Expires reference time).
//  - metno_for (test-metno.c:1881-1890) -> `provider(server, clock:)`: loopback
//    origin, 3000 ms per attempt, 1 ms back-off.
//  - R_RESPOND/R_HOLD/R_HANG/R_CLOSE/R_GZIP -> .respond/.hold/.hang/.close/.gzip;
//    fake_new_fn -> `.compute` (state in LoopbackServer.Shared); fake_release ->
//    release(); closed_early / connections -> closedEarlyCount / connectionCount.
//  - GCancellable -> task cancellation (CancellationError stands for
//    G_IO_ERROR_CANCELLED). fetch_start -> `Pending` (a Task running fetch);
//    "the fetch has joined the request" (synchronous in C) is awaited through
//    the provider's waiterCount before the test goes on.
//  - Member identity: C compares WxMember pointers; WxMember is a value here, so
//    "the very same member" is value equality including fetchedS (NaN-aware,
//    `same`), and "a new member" is a different fetchedS or, where both
//    downloads happen at the same clock reading, the request count alone.
//
// Not ported (classes in the U24 debrief): /metno/net/works-after-dispose and
// /metno/net/programmer-errors (GLIB-INTERNAL: g_object_run_dispose, NULL place
// and foreign GTask criticals have no Swift counterpart).

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(3)))
struct METNorwayProviderTests {

    // MARK: Literals

    /// WX_METNO_USER_AGENT (wx-metno.h:146).
    static let ua = "weather-app/0.1 (github.com/wtp128pro/weather)"
    static let miamiLat = 25.7617  // test-metno.c:1902
    static let miamiLon = -80.1918  // test-metno.c:1903
    static let londonLat = 51.5072  // test-metno.c:1904
    static let londonLon = -0.1276  // test-metno.c:1905
    /// MIAMI_PATH (test-metno.c:1906).
    static let miamiPath = "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918"
    /// LONDON_PATH (test-metno.c:1907).
    static let londonPath = "/weatherapi/locationforecast/2.0/complete?lat=51.5072&lon=-0.1276"
    /// FLOOR_MESSAGE (test-metno.c:2569).
    static let floorMessage = "a request for this place was sent less than 10 minutes ago"
    /// test-metno.c:3280.
    static let pausedMessage = "requests are paused after HTTP 429"
    /// test-metno.c:3140.
    static let message429 = "HTTP 429: rate limited"
    /// test-metno.c:3760.
    static let capMessage = "too many outstanding requests (limit 16)"
    /// WX_METNO_CACHE_MAX (wx-metno.h:152).
    static let cacheMax = 32
    /// WX_HTTP_MAX_INFLIGHT (src/net/wx-http.h, "limit 16", test-metno.c:3760).
    static let maxInflight = 16

    // MARK: Harness

    static func miami() throws -> Data { try Fixtures.data("complete_miami.json") }
    static func london() throws -> Data { try Fixtures.data("complete_london.json") }

    /// real_now_s (test-metno.c:94-98).
    static func realNowS() -> Int64 { SystemClock().wallSeconds }

    /// clock_set (test-metno.c:1866-1872): the provider clock reads `t` seconds.
    static func set(_ clock: ManualClock, _ t: Int64) {
        clock.advanceWall(by: t * 1_000_000 - clock.wallMicroseconds)
    }

    /// A provider clock at `t` seconds.
    static func clockAt(_ t: Int64) -> ManualClock { ManualClock(wallMicroseconds: t * 1_000_000) }

    /// http_date (test-metno.c:123-137): "Mon, 12 Oct 2026 19:19:33 GMT", no locale.
    static func httpDate(_ t: Int64) -> String {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let dayNumber = t >= 0 ? t / 86_400 : (t - 86_399) / 86_400
        let secs = t - dayNumber * 86_400
        // civil_from_days (H. Hinnant).
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        let weekday = Int(((dayNumber % 7) + 7 + 3) % 7)  // 1970-01-01 was a Thursday
        func two(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(days[weekday]), \(two(d)) \(months[Int(m) - 1]) \(y) "
            + "\(two(secs / 3600)):\(two(secs / 60 % 60)):\(two(secs % 60)) GMT"
    }

    /// place_at (test-metno.c:1892-1900).
    static func place(_ lat: Double, _ lon: Double) throws -> WxPlace {
        try WxPlace(name: "Test place", lat: lat, lon: lon)
    }

    /// metno_for (test-metno.c:1881-1890): loopback origin, 3000 ms, 1 ms back-off.
    static func provider(
        _ server: LoopbackServer, clock: any WxClock, timeoutMs: Int = 3000,
        probe: (@Sendable () -> Void)? = nil,
        parseProbe: (@Sendable () -> Void)? = nil
    ) throws -> METNorwayProvider {
        try METNorwayProvider(
            testingBaseURL: "http://127.0.0.1:\(server.port)", timeoutMs: timeoutMs, backoffBaseMs: 1,
            clock: clock, outcomeProbe: probe, parseProbe: parseProbe)
    }

    /// ok_reply (test-metno.c:2003-2007).
    static func ok(_ headers: [String] = []) throws -> LoopbackServer.Step {
        .respond(status: 200, headers: headers, body: try miami())
    }

    typealias Outcome = Result<WxSourceResult, any Error>

    /// fetch (test-metno.c:1957-1962).
    static func fetch(_ provider: METNorwayProvider, _ place: WxPlace) async -> Outcome {
        do {
            return .success(try await provider.fetch(place))
        } catch {
            return .failure(error)
        }
    }

    /// outcome_member (test-metno.c:1965-1976).
    @discardableResult
    static func member(_ outcome: Outcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> WxMember {
        let result = try #require(try? outcome.get(), "fetch failed: \(outcome)", sourceLocation: sourceLocation)
        #expect(result.providerID == "met-no", sourceLocation: sourceLocation)
        try #require(result.members.count == 1, sourceLocation: sourceLocation)
        let member = result.members[0]
        #expect(member.sourceID == "met-no", sourceLocation: sourceLocation)
        #expect(member.modelID == "ecmwf", sourceLocation: sourceLocation)
        return member
    }

    /// fetch_ok (test-metno.c:1995-2001).
    @discardableResult
    static func fetchOK(
        _ provider: METNorwayProvider, _ place: WxPlace, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> WxMember {
        try member(await fetch(provider, place), sourceLocation: sourceLocation)
    }

    /// outcome_assert_failed (test-metno.c:1978-1983); a nil message is not asserted.
    static func expectFailed(
        _ outcome: Outcome, _ code: WxError.Code, _ message: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failure(let error) = outcome, let wx = error as? WxError else {
            Issue.record("expected WxError \(code), got \(outcome)", sourceLocation: sourceLocation)
            return
        }
        #expect(wx.code == code, "\(wx)", sourceLocation: sourceLocation)
        if let message {
            #expect(wx.message == message, sourceLocation: sourceLocation)
        }
    }

    /// outcome_assert_cancelled (test-metno.c:1985-1993).
    static func expectCancelled(_ outcome: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .failure(let error) = outcome, error is CancellationError else {
            Issue.record("expected CancellationError, got \(outcome)", sourceLocation: sourceLocation)
            return
        }
    }

    static func spin(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// assert_requests (test-metno.c:1796-1802).
    static func expectRequests(
        _ server: LoopbackServer, _ n: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await spin(25)
        #expect(server.requestCount == n, sourceLocation: sourceLocation)
    }

    /// assert_request (test-metno.c:1804-1849): one GET line for `path`, only the
    /// expected headers, the identifying User-Agent, the JSON Accept value,
    /// If-Modified-Since exactly when `ims` is given. Accept-Language: * is the
    /// documented difference of DECISIONS #30 (not a C literal).
    static func expectRequest(
        _ server: LoopbackServer, _ index: Int, _ path: String, _ ims: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let requests = server.requests
        guard index < requests.count else {
            Issue.record("request \(index) missing (\(requests.count))", sourceLocation: sourceLocation)
            return
        }
        let request = requests[index]
        let head = request.head
        #expect(head.hasPrefix("GET \(path) HTTP/1.1\r\n"), "\(head)", sourceLocation: sourceLocation)
        #expect(request.path == path, sourceLocation: sourceLocation)
        #expect(head.hasSuffix("\r\n\r\n"), sourceLocation: sourceLocation)
        let lines = head.components(separatedBy: "\r\n").prefix { !$0.isEmpty }
        #expect(lines.filter { $0.contains(" HTTP/1.") }.count == 1, sourceLocation: sourceLocation)
        let allowed: Set<String> = [
            "host", "user-agent", "accept", "accept-encoding", "connection", "if-modified-since", "accept-language",
        ]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                Issue.record("header line without colon: \(line)", sourceLocation: sourceLocation)
                continue
            }
            #expect(allowed.contains(line[..<colon].lowercased()), "\(line)", sourceLocation: sourceLocation)
        }
        #expect(request.header("User-Agent") == ua, sourceLocation: sourceLocation)
        #expect(request.header("Accept") == "application/json", sourceLocation: sourceLocation)
        #expect(request.header("Host") == "127.0.0.1:\(server.port)", sourceLocation: sourceLocation)
        #expect(request.headers("Accept-Language") == ["*"], sourceLocation: sourceLocation)  // DECISIONS #30
        #expect(request.headers("If-Modified-Since") == (ims.map { [$0] } ?? []), sourceLocation: sourceLocation)
        for forbidden in ["Cookie", "Authorization", "Referer", "Origin", "Mozilla", "Proxy-Authorization", "X-"] {
            #expect(!head.contains(forbidden), "\(forbidden)", sourceLocation: sourceLocation)
        }
    }

    /// assert_floor_refusal (test-metno.c:2573-2583).
    static func expectFloorRefusal(
        _ provider: METNorwayProvider, _ place: WxPlace, _ server: LoopbackServer, _ requests: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        expectFailed(await fetch(provider, place), .rateLimited, floorMessage, sourceLocation: sourceLocation)
        await expectRequests(server, requests, sourceLocation: sourceLocation)
    }

    /// WAIT_UNTIL (test-metno.c:1473-1483): polls for up to 20 s.
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await spin(1)
        }
        return true
    }

    /// The same member: C pointer equality, here value equality with NaN-aware
    /// Double fields (fetchedS included).
    static func same(_ a: WxMember, _ b: WxMember) -> Bool {
        func eq(_ x: Double, _ y: Double) -> Bool { x.bitPattern == y.bitPattern || (x.isNaN && y.isNaN) }
        guard a.sourceID == b.sourceID, a.modelID == b.modelID, a.fetchedS == b.fetchedS,
              a.hours.count == b.hours.count, a.quarters.isEmpty, b.quarters.isEmpty
        else { return false }
        return zip(a.hours, b.hours).allSatisfy { h, k in
            h.tS == k.tS && h.wmo == k.wmo && eq(h.tempC, k.tempC) && eq(h.feelsC, k.feelsC)
                && eq(h.precipMm, k.precipMm) && eq(h.precipProb, k.precipProb) && eq(h.cloudPct, k.cloudPct)
                && eq(h.windKmh, k.windKmh) && eq(h.gustKmh, k.gustKmh) && eq(h.humidityPct, k.humidityPct)
        }
    }

    /// assert_member_invariants (test-metno.c:186-222).
    static func expectInvariants(_ member: WxMember, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(member.sourceID == "met-no", sourceLocation: sourceLocation)
        #expect(member.modelID == "ecmwf", sourceLocation: sourceLocation)
        let hours = member.hours
        #expect(hours.count >= 1 && hours.count <= WxLimits.memberMaxHours, sourceLocation: sourceLocation)
        #expect(member.quarters.isEmpty, sourceLocation: sourceLocation)
        for (i, h) in hours.enumerated() {
            #expect(h.tS % 3600 == 0, sourceLocation: sourceLocation)
            #expect(h.tS >= WxLimits.timeMinS && h.tS < WxLimits.timeMaxS, sourceLocation: sourceLocation)
            if i > 0 { #expect(h.tS > hours[i - 1].tS, sourceLocation: sourceLocation) }
            let values = [h.tempC, h.feelsC, h.cloudPct, h.humidityPct, h.windKmh, h.gustKmh, h.precipMm]
            #expect(values.contains { !$0.isNaN }, sourceLocation: sourceLocation)
            #expect(h.tempC.isNaN || (h.tempC >= -100 && h.tempC <= 70), sourceLocation: sourceLocation)
            #expect(h.feelsC.isNaN || (h.feelsC >= -100 && h.feelsC <= 70), sourceLocation: sourceLocation)
            #expect(h.cloudPct.isNaN || (h.cloudPct >= 0 && h.cloudPct <= 100), sourceLocation: sourceLocation)
            #expect(h.humidityPct.isNaN || (h.humidityPct >= 0 && h.humidityPct <= 100), sourceLocation: sourceLocation)
            #expect(h.windKmh.isNaN || (h.windKmh >= 0 && h.windKmh <= 500), sourceLocation: sourceLocation)
            #expect(h.gustKmh.isNaN || (h.gustKmh >= 0 && h.gustKmh <= 500), sourceLocation: sourceLocation)
            #expect(h.precipMm.isNaN || (h.precipMm >= 0 && h.precipMm <= 500), sourceLocation: sourceLocation)
            #expect(h.precipProb.isNaN && h.wmo == -1, sourceLocation: sourceLocation)
        }
    }

    /// Independent oracle of the fixtures (test-metno.c:424-468): Foundation's
    /// JSONSerialization and ISO8601DateFormatter instead of json-glib/GDateTime.
    static func expectMatchesOracle(_ body: Data, _ member: WxMember) throws {
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let props = try #require(root["properties"] as? [String: Any])
        let series = try #require(props["timeseries"] as? [[String: Any]])
        let hours = member.hours
        #expect(hours.count == series.count)
        func number(_ details: [String: Any]?, _ name: String, _ factor: Double) -> Double {
            guard let v = details?[name] as? NSNumber else { return .nan }
            return v.doubleValue * factor
        }
        func expectSame(_ a: Double, _ b: Double, _ what: String) {
            #expect(a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN), "\(what): \(a) vs \(b)")
        }
        let formatter = ISO8601DateFormatter()
        for (i, entry) in series.enumerated() where i < hours.count {
            let time = try #require(entry["time"] as? String)
            let when = try #require(formatter.date(from: time))
            #expect(hours[i].tS == Int64(when.timeIntervalSince1970))
            let data = try #require(entry["data"] as? [String: Any])
            let instant = (data["instant"] as? [String: Any])?["details"] as? [String: Any]
            let next = (data["next_1_hours"] as? [String: Any])?["details"] as? [String: Any]
            expectSame(hours[i].tempC, number(instant, "air_temperature", 1.0), "temp \(i)")
            expectSame(hours[i].feelsC, number(instant, "apparent_air_temperature", 1.0), "feels \(i)")
            expectSame(hours[i].cloudPct, number(instant, "cloud_area_fraction", 1.0), "cloud \(i)")
            expectSame(hours[i].humidityPct, number(instant, "relative_humidity", 1.0), "humidity \(i)")
            expectSame(hours[i].windKmh, number(instant, "wind_speed", 3.6), "wind \(i)")
            expectSame(hours[i].gustKmh, number(instant, "wind_speed_of_gust", 3.6), "gust \(i)")
            expectSame(hours[i].precipMm, number(next, "precipitation_amount", 1.0), "precip \(i)")
            #expect(hours[i].precipProb.isNaN)
            #expect(hours[i].wmo == -1)
        }
    }

    /// fetch_start (test-metno.c:1943-1949): a fetch running in its own task;
    /// cancelling the task is g_cancellable_cancel.
    final class Pending: Sendable {
        private let box: LoopbackServer.Shared<Outcome?>
        let task: Task<Void, Never>

        init(_ provider: METNorwayProvider, _ place: WxPlace, preCancelled: Bool = false) {
            let box = LoopbackServer.Shared<Outcome?>(nil)
            self.box = box
            task = Task {
                if preCancelled {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                let outcome = await METNorwayProviderTests.fetch(provider, place)
                box.value = outcome
            }
        }

        var done: Bool { box.value != nil }

        func cancel() { task.cancel() }

        /// fetch_wait (test-metno.c:1951-1955).
        func wait() async -> Outcome {
            await task.value
            return box.value ?? .failure(CancellationError())
        }
    }

    // MARK: provider/

    // C: /metno/provider/identity (test-metno.c:2013-2050)
    @Test func providerIdentity() async throws {
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: SystemClock())
        #expect(!((provider as AnyObject) is any WxGeocoder))
        #expect(provider.id == "met-no")  // test-metno.c:2021
        #expect(provider.name == "MET Norway")  // test-metno.c:2022
        #expect(provider.attribution == "Data from MET Norway")  // test-metno.c:2023
        #expect(provider.attributionURL == "https://api.met.no/")  // test-metno.c:2024
        #expect(provider.attributionURL.hasPrefix("https://"))
        #expect(WxLimits.isValidID(bytes: Array(provider.id.utf8)))
        #expect(provider.id == provider.id)
        let lats = [25.7617, 51.5072, -33.8688, 90.0, -90.0, 0.0, 69.6492]  // test-metno.c:2033
        let lons = [-80.1918, -0.1276, 151.2093, 180.0, -180.0, 0.0, 18.9553]  // test-metno.c:2034
        for (lat, lon) in zip(lats, lons) {
            #expect(provider.covers(try Self.place(lat, lon)))
        }
        // The hand-made places of test-metno.c:2039-2045 (lat NAN; lon 181) cannot be
        // built: WxPlace validates its coordinates, so covers() never sees them.
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: .nan, lon: 0) }
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: 0, lon: 181) }
        #expect(provider.covers(try WxPlace(name: "x", lat: 0, lon: 0)))
        await Self.expectRequests(server, 0)
    }

    // C: /metno/provider/new-production (test-metno.c:2052-2067)
    @Test func providerNewProduction() throws {
        let provider = METNorwayProvider()
        #expect(provider.id == "met-no")
        #expect(provider.covers(try Self.place(Self.miamiLat, Self.miamiLon)))
        // The production origin: WX_METNO_BASE_URL (wx-metno.h:144), default timing.
        #expect(provider.http.policy.origin == "https://api.met.no")
        #expect(provider.http.policy.userAgent == Self.ua)
        #expect(provider.http.policy.timeoutMs == 10_000 && provider.http.policy.backoffBaseMs == 1_000)
        #expect(provider.http.policy.minGapMs == 0)
        // Nothing is sent until a fetch (no fetch here: the real origin is never contacted).
        #expect(provider.outstandingCount == 0 && provider.http.outstandingCount == 0)
    }

    // C: /metno/provider/new-custom-validation (test-metno.c:2069-2095)
    @Test func providerNewCustomValidation() throws {
        let bad = [
            "ftp://127.0.0.1:1", "http://example.com", "http://api.met.no", "https://user:pw@api.met.no",
            "https://api.met.no/x", "https://api.met.no?q=1", "https://api.met.no#f", "", "not a url", "https://",
        ]  // test-metno.c:2073-2075
        for base in bad {
            do {
                _ = try METNorwayProvider(testingBaseURL: base, timeoutMs: 1000, backoffBaseMs: 1, clock: SystemClock())
                Issue.record("accepted \(base)")
            } catch {
                #expect(error == WxError(.invalidArg, "unacceptable base URL"), "\(base)")  // test-metno.c:2078
            }
        }
        let good = ["https://api.met.no", "https://api.met.no/", "http://127.0.0.1:8080", "http://localhost:9",
                    "http://[::1]:9"]  // test-metno.c:2081-2082
        for base in good {
            #expect(throws: Never.self) {
                _ = try METNorwayProvider(testingBaseURL: base, timeoutMs: 1000, backoffBaseMs: 0, clock: SystemClock())
            }
        }
        // C: timeout_ms 0 is a critical (test-metno.c:2093); HTTPClientPolicy reports it as
        // INVALID_ARG "invalid timing argument" (the U09 replacement). A NULL base URL
        // (test-metno.c:2091) cannot be expressed with a String.
        #expect(throws: WxError(.invalidArg, "invalid timing argument")) {
            _ = try METNorwayProvider(testingBaseURL: "https://api.met.no", timeoutMs: 0, backoffBaseMs: 1, clock: SystemClock())
        }
    }

    // C: /metno/provider/registry (test-metno.c:2097-2123)
    @MainActor @Test func providerRegistry() async throws {
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: SystemClock())
        let registry = WxRegistry()
        try registry.addProvider(provider)
        #expect(registry.findProvider(id: "met-no") === provider)
        #expect(registry.isEnabled(id: "met-no"))
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let sydney = try Self.place(-33.8688, 151.2093)
        let covering = registry.listCovering(miami)
        #expect(covering.count == 1 && covering.first === provider)
        #expect(registry.listCovering(sydney).count == 1)
        #expect(registry.setEnabled(false, id: "met-no"))
        #expect(registry.listCovering(miami).isEmpty)
        #expect(throws: WxError.self) { try registry.addProvider(provider) }
        await Self.expectRequests(server, 0)
    }

    // MARK: metno-production/ (test-metno-production.c)

    // C: /metno-production/provider (test-metno-production.c:21-43)
    @MainActor @Test func productionProvider() throws {
        let provider = METNorwayProvider()
        #expect(provider.id == "met-no")  // test-metno-production.c:26
        #expect(provider.name == "MET Norway")  // :27
        #expect(provider.attribution == "Data from MET Norway")  // :28
        #expect(provider.attributionURL == "https://api.met.no/")  // :29
        let miami = try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US", lat: 25.7617,
            lon: -80.1918, timezone: "America/New_York")  // :31-32
        #expect(provider.covers(miami))
        let registry = WxRegistry()
        try registry.addProvider(provider)
        #expect(registry.listCovering(miami).count == 1)
        // The production origin is https and fixed: http://api.met.no is refused (:41-42).
        #expect(provider.http.policy.origin == METNorwayParse.baseURL)
        #expect(throws: WxError.self) {
            _ = try METNorwayProvider(testingBaseURL: "http://api.met.no", timeoutMs: 1000, backoffBaseMs: 1, clock: SystemClock())
        }
        do {
            _ = try METNorwayProvider(testingBaseURL: "http://api.met.no", timeoutMs: 1000, backoffBaseMs: 1, clock: SystemClock())
        } catch {
            #expect(error.code == .invalidArg)
        }
    }

    // C: /metno-production/pure (test-metno-production.c:46-61)
    @Test func productionPure() throws {
        #expect(METNorwayParse.forecastPath(lat: 25.7617, lon: -80.1918)
            == "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918")  // :49
        let member = try METNorwayParse.parseForecast(try Self.london(), fetchedS: 1_791_831_600 + 100)  // :55
        #expect(member.hours.count == 92)  // :58
        #expect(member.fetchedS == 1_791_831_700)  // :59
    }

    // MARK: net/ - requests and the cache

    // C: /metno/net/success-request-shape (test-metno.c:2129-2155)
    @Test func netSuccessRequestShape() async throws {
        let before = Self.realNowS()
        let headers = ["Last-Modified: \(Self.httpDate(before - 100))", "Expires: \(Self.httpDate(before + 1800))"]
        let server = try LoopbackServer([.gzip(body: try Self.miami(), headers: headers)])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: SystemClock())
        let outcome = await Self.fetch(provider, try Self.place(Self.miamiLat, Self.miamiLon))
        let member = try Self.member(outcome)
        await Self.expectRequests(server, 1)
        Self.expectRequest(server, 0, Self.miamiPath, nil)
        let after = Self.realNowS()
        #expect(member.fetchedS >= before && member.fetchedS <= after)
        Self.expectInvariants(member)
        try Self.expectMatchesOracle(try Self.miami(), member)
        #expect(member.hours.count == 92)  // test-metno.c:2150
    }

    // C: /metno/net/london-fixture (test-metno.c:2157-2172)
    @Test func netLondonFixture() async throws {
        let server = try LoopbackServer([.respond(status: 200, body: try Self.london())])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: SystemClock())
        let member = try await Self.fetchOK(provider, try Self.place(Self.londonLat, Self.londonLon))
        Self.expectRequest(server, 0, Self.londonPath, nil)
        try Self.expectMatchesOracle(try Self.london(), member)
    }

    // C: /metno/net/coordinates-rounded (test-metno.c:2175-2220)
    @Test func netCoordinatesRounded() async throws {
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: SystemClock())
        let cases: [(Double, Double, String)] = [
            (25.76174999, -80.19184999, Self.miamiPath),
            (25.76176, -80.19186, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919"),
            (-0.00001, 0.00001, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"),
            (-33.868812345, 151.209312345, "/weatherapi/locationforecast/2.0/complete?lat=-33.8688&lon=151.2093"),
            (90.0, -180.0, "/weatherapi/locationforecast/2.0/complete?lat=90.0000&lon=-180.0000"),
        ]  // test-metno.c:2185-2189
        for (i, (lat, lon, path)) in cases.enumerated() {
            try await Self.fetchOK(provider, try Self.place(lat, lon))
            await Self.expectRequests(server, i + 1)
            Self.expectRequest(server, i, path, nil)
        }
        // Random places: exactly four decimals on both coordinates (test-metno.c:2199-2219).
        let shape = /^\/weatherapi\/locationforecast\/2\.0\/complete\?lat=-?[0-9]{1,2}\.[0-9]{4}&lon=-?[0-9]{1,3}\.[0-9]{4}$/
        var rng = SeededRNG(seed: 77)  // test-metno.c:2204
        let base = server.requestCount
        for _ in 0..<40 {
            let lat = Double.random(in: -90..<90, using: &rng)
            let lon = Double.random(in: -180..<180, using: &rng)
            try await Self.fetchOK(provider, try Self.place(lat, lon))
        }
        #expect(server.requestCount == base + 40)
        for path in server.paths[base...] {
            #expect(path.wholeMatch(of: shape) != nil, "\(path)")
        }
    }

    // C: /metno/net/cache-key (test-metno.c:2222-2281)
    @Test func netCacheKey() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let a = try Self.place(25.76170, -80.19180)
        let b = try Self.place(25.761700004, -80.191799996)
        let c = try Self.place(25.76174, -80.19184)
        let d = try Self.place(25.76176, -80.19180)
        let keep = try await Self.fetchOK(provider, a)
        #expect(Self.same(try await Self.fetchOK(provider, b), keep))
        #expect(Self.same(try await Self.fetchOK(provider, c), keep))
        await Self.expectRequests(server, 1)
        try await Self.fetchOK(provider, d)
        await Self.expectRequests(server, 2)
        Self.expectRequest(server, 1, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1918", nil)
        let others: [(Double, Double, String)] = [
            (25.7617, -80.1919, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1919"),
            (25.7617, 80.1918, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=80.1918"),
            (-25.7617, -80.1918, "/weatherapi/locationforecast/2.0/complete?lat=-25.7617&lon=-80.1918"),
            (-25.7617, 80.1918, "/weatherapi/locationforecast/2.0/complete?lat=-25.7617&lon=80.1918"),
        ]  // test-metno.c:2247-2252
        for (i, (lat, lon, path)) in others.enumerated() {
            try await Self.fetchOK(provider, try Self.place(lat, lon))
            await Self.expectRequests(server, 3 + i)
            Self.expectRequest(server, 2 + i, path, nil)
        }
        let down = METNorwayParse.forecastPath(lat: 25.76174, lon: -80.19184)
        let sameText = METNorwayParse.forecastPath(lat: 25.76170, lon: -80.19180)
        let up = METNorwayParse.forecastPath(lat: 25.76176, lon: -80.19186)
        #expect(down == sameText)
        #expect(down != up)
        #expect(up == "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919")  // test-metno.c:2267
        let before = server.requestCount
        let e = try Self.place(25.76176, -80.19186)
        let g = try Self.place(25.76184, -80.19194)
        // C: me != keep (a request of its own; the same body at the same clock reading
        // gives an equal value here, so the request count is the evidence).
        let keepE = try await Self.fetchOK(provider, e)
        await Self.expectRequests(server, before + 1)
        Self.expectRequest(server, before, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919", nil)
        #expect(Self.same(try await Self.fetchOK(provider, g), keepE))
        await Self.expectRequests(server, before + 1)
    }

    // C: /metno/net/floor-and-revalidation (test-metno.c:2283-2334)
    @Test func netFloorAndRevalidation() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm1 = Self.httpDate(t0 - 500)
        let lm2 = Self.httpDate(t0 + 700)
        let server = try LoopbackServer([
            try Self.ok(["Last-Modified: \(lm1)"]), try Self.ok(["Last-Modified: \(lm2)"]), try Self.ok(),
        ])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.expectRequest(server, 0, Self.miamiPath, nil)
        #expect(a.fetchedS == t0)
        for t in [t0, t0 + 1, t0 + 300, t0 + 599] {
            Self.set(clock, t)
            #expect(Self.same(try await Self.fetchOK(provider, miami), a))
            await Self.expectRequests(server, 1)
        }
        Self.set(clock, t0 + 600)
        let b = try await Self.fetchOK(provider, miami)
        #expect(!Self.same(b, a))
        await Self.expectRequests(server, 2)
        Self.expectRequest(server, 1, Self.miamiPath, lm1)
        #expect(b.fetchedS == t0 + 600)
        Self.set(clock, t0 + 1199)
        #expect(Self.same(try await Self.fetchOK(provider, miami), b))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1200)
        #expect(!Self.same(try await Self.fetchOK(provider, miami), b))
        await Self.expectRequests(server, 3)
        Self.expectRequest(server, 2, Self.miamiPath, lm2)
        Self.set(clock, t0 + 1800)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 4)
        Self.expectRequest(server, 3, Self.miamiPath, nil)
    }

    // C: /metno/net/not-modified (test-metno.c:2336-2390)
    @Test func netNotModified() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm1 = Self.httpDate(t0 - 500)
        let lm2 = Self.httpDate(t0 + 900)
        let expires = Self.httpDate(t0 + 1800)
        let server = try LoopbackServer([
            try Self.ok(["Last-Modified: \(lm1)"]),
            .respond(status: 304, headers: ["Expires: \(expires)"]),  // no Last-Modified: the validator stays
            .respond(status: 304, headers: ["Last-Modified: \(lm2)"]),  // a new Last-Modified replaces it
            try Self.ok(),
        ])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 601)
        let outcome = await Self.fetch(provider, miami)
        let again = try Self.member(outcome)
        #expect(Self.same(again, a))
        #expect(again.fetchedS == t0)
        await Self.expectRequests(server, 2)
        Self.expectRequest(server, 1, Self.miamiPath, lm1)
        #expect((try? outcome.get())?.members.count == 1)
        Self.set(clock, t0 + 1200)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1799)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1800)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        Self.expectRequest(server, 2, Self.miamiPath, lm1)
        Self.set(clock, t0 + 1800 + 599)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        Self.set(clock, t0 + 1800 + 600)
        #expect(!Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 4)
        Self.expectRequest(server, 3, Self.miamiPath, lm2)
    }

    // C: /metno/net/validator-round-trip (test-metno.c:4044-4084)
    //
    // "The Last-Modified text is sent back as it came" (test-metno.c:4041): every
    // expected value below is C's literal, exact assertion test-metno.c:4073, and no
    // row differs from C (DECISIONS #40: HTTPClient.lastHeaderLine rule (b) returns a
    // single line that is not a list of HTTP dates unchanged).
    @Test func netValidatorRoundTrip() async throws {
        let t0 = Self.realNowS()
        let maxLen = String(repeating: "x", count: 64)  // WX_HTTP_VALIDATOR_MAX
        let tooLong = String(repeating: "x", count: 65)
        let cases: [(value: String, sentBack: String?)] = [
            ("not a date at all", "not a date at all"),
            ("W/\"abc\"; q=0.5, \\ ~!#$%&'()*+,-./", "W/\"abc\"; q=0.5, \\ ~!#$%&'()*+,-./"),  // test-metno.c:4054
            (maxLen, maxLen),
            (tooLong, nil),
            ("", nil),
        ]  // test-metno.c:4053-4058
        for c in cases {
            let clock = Self.clockAt(t0)
            let server = try LoopbackServer([try Self.ok(["Last-Modified: \(c.value)"]), .respond(status: 304)])
            defer { server.stop() }
            let provider = try Self.provider(server, clock: clock)
            let miami = try Self.place(Self.miamiLat, Self.miamiLon)
            let a = try await Self.fetchOK(provider, miami)
            Self.set(clock, t0 + 600)
            let outcome = await Self.fetch(provider, miami)
            await Self.expectRequests(server, 2)
            Self.expectRequest(server, 1, Self.miamiPath, c.sentBack)
            if c.sentBack != nil {
                #expect(Self.same(try Self.member(outcome), a), "\(c.value)")  // the 304 for the validator
            } else {
                Self.expectFailed(outcome, .http, "HTTP 304 Not Modified")
            }
        }
    }

    // C: /metno/net/expires (test-metno.c:2392-2422)
    @Test func netExpires() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let server = try LoopbackServer([
            try Self.ok(["Last-Modified: \(lm)", "Expires: \(Self.httpDate(t0 + 1800))"]), try Self.ok(),
        ])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        for t in [t0 + 601, t0 + 1000, t0 + 1799] {
            Self.set(clock, t)
            #expect(Self.same(try await Self.fetchOK(provider, miami), a))
            await Self.expectRequests(server, 1)
        }
        Self.set(clock, t0 + 1800)
        #expect(!Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.expectRequest(server, 1, Self.miamiPath, lm)
    }

    // C: /metno/net/implausible-expires (test-metno.c:2425-2455)
    @Test func netImplausibleExpires() async throws {
        let t0 = Self.realNowS()
        let headerSets: [[String]] = [
            ["Expires: \(Self.httpDate(t0 - 3600))"], ["Expires: \(Self.httpDate(t0 + 2 * 86400))"],
            ["Expires: soon"], ["Expires: 0"], ["Expires: -1"], [],
        ]  // test-metno.c:2429-2433
        for headers in headerSets {
            let clock = Self.clockAt(t0)
            let server = try LoopbackServer([try Self.ok(headers)])
            defer { server.stop() }
            let provider = try Self.provider(server, clock: clock)
            let miami = try Self.place(Self.miamiLat, Self.miamiLon)
            try await Self.fetchOK(provider, miami)
            Self.set(clock, t0 + 599)
            try await Self.fetchOK(provider, miami)
            await Self.expectRequests(server, 1)
            Self.set(clock, t0 + 600)
            try await Self.fetchOK(provider, miami)
            await Self.expectRequests(server, 2)
        }
    }

    // C: /metno/net/expires-cap-24h (test-metno.c:2457-2481). The provider clock is
    // two days behind the real time; the HTTP client checks Expires against the real
    // time (TWO CLOCKS), so an Expires 30 min after the real time is accepted.
    @Test func netExpiresCap24h() async throws {
        let real = Self.realNowS()
        let t0 = real - 2 * 86400
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([try Self.ok(["Expires: \(Self.httpDate(real + 1800))"]), try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 86399)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 1)
        Self.set(clock, t0 + 86400)
        #expect(!Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
    }

    // C: /metno/net/clock-backwards (test-metno.c:2483-2508)
    @Test func netClockBackwards() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 - 1)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 - 100_000)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 3)
        Self.set(clock, t0 - 100_000 + 599)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 3)
    }

    // C: /metno/net/clock-extremes (test-metno.c:2510-2566). C's extremes are seconds
    // from the test hook (test-metno.c:2523-2524); a WxClock reads Int64 MICROseconds,
    // so the extremes are taken in that unit (G_MININT64 -> Int64.min us, -1 s,
    // G_MAXINT64 -> Int64.max us). G_MAXINT64 / 4 and G_MAXINT64 / 4 + 1 seconds lie
    // beyond any WxClock reading (Int64.max us is 9223372036854 s) and are not
    // representable; every reachable reading is below the clamp's upper bound.
    @Test func netClockExtremes() async throws {
        let t0 = Self.realNowS()
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let extremesUs: [Int64] = [
            .min, .min + 1, -1_000_000, 0, .max, .max - 1,
            WxLimits.timeMaxS * 1_000_000, (WxLimits.timeMinS - 1) * 1_000_000,
        ]
        var expected = 0
        for extreme in extremesUs {
            let clock = Self.clockAt(t0)
            let provider = try Self.provider(server, clock: clock)
            try await Self.fetchOK(provider, miami)
            expected += 1
            clock.advanceWall(by: -clock.wallMicroseconds)  // to 0, then to the extreme (no overflow)
            clock.advanceWall(by: extreme)
            Self.expectFailed(await Self.fetch(provider, london), .invalidArg, "fetch time out of range")
            expected += 1
            Self.expectFailed(await Self.fetch(provider, miami), .invalidArg, "fetch time out of range")
            expected += 1
            await Self.expectRequests(server, expected)
        }
        let clock = Self.clockAt(t0)
        let provider = try Self.provider(server, clock: clock)
        try await Self.fetchOK(provider, miami)
        expected += 1
        Self.set(clock, t0 + 5)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, expected)
        Self.set(clock, WxLimits.timeMinS)
        #expect(try await Self.fetchOK(provider, london).fetchedS == WxLimits.timeMinS)
        Self.set(clock, WxLimits.timeMaxS - 1)
        #expect(try await Self.fetchOK(provider, miami).fetchedS == WxLimits.timeMaxS - 1)
    }

    // MARK: net/ - the floor

    // C: /metno/net/floor-after-failure (test-metno.c:2585-2632)
    @Test func netFloorAfterFailure() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let down = LoopbackServer.Step.text("{}", status: 500)
        let server = try LoopbackServer([
            try Self.ok(["Last-Modified: \(lm)", "Expires: \(Self.httpDate(t0 + 650))"]), down, down, down,
            .respond(status: 304),
        ])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 700)
        Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 500 Internal Server Error")
        await Self.expectRequests(server, 4)
        for i in 1..<4 {
            Self.expectRequest(server, i, Self.miamiPath, lm)
        }
        for held: Int64 in [700, 701, 702, 1000, 1299] {
            Self.set(clock, t0 + held)
            let served = try await Self.fetchOK(provider, miami)
            #expect(Self.same(served, a))
            #expect(served.fetchedS == t0)
            await Self.expectRequests(server, 4)
        }
        Self.set(clock, t0 + 1300)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 5)
        Self.expectRequest(server, 4, Self.miamiPath, lm)
        Self.set(clock, t0 + 1899)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 5)
    }

    // C: /metno/net/floor-counts-started-requests (test-metno.c:2634-2677)
    @Test func netFloorCountsStartedRequests() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.hang, try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        Self.expectCancelled(await Pending(provider, miami, preCancelled: true).wait())
        #expect(server.connectionCount == 0)
        let pending = Pending(provider, miami)
        #expect(await Self.waitUntil { server.requestCount == 1 })
        pending.cancel()
        Self.expectCancelled(await pending.wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == 1 })
        for held: Int64 in [0, 1, 599] {
            Self.set(clock, t0 + held)
            await Self.expectFloorRefusal(provider, miami, server, 1)
        }
        Self.set(clock, t0 + 600)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 2)
    }

    // C: /metno/net/floor-after-timeout (test-metno.c:2679-2712)
    @Test func netFloorAfterTimeout() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock, timeoutMs: 700)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        Self.expectFailed(await Self.fetch(provider, miami), .timeout, nil)
        await Self.spin(25)
        let first = server.requestCount
        #expect(first >= 1 && first <= 3)
        Self.set(clock, t0 + 599)
        await Self.expectFloorRefusal(provider, miami, server, first)
        Self.set(clock, t0 + 600)
        Self.expectFailed(await Self.fetch(provider, miami), .timeout, nil)
        await Self.spin(25)
        let second = server.requestCount
        #expect(second > first && second <= first + 3)
        Self.set(clock, t0 + 1199)
        await Self.expectFloorRefusal(provider, miami, server, second)
    }

    // C: /metno/net/floor-per-place (test-metno.c:2727-2766)
    @Test func netFloorPerPlace() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let londonBody = try Self.london()
        let server = try LoopbackServer { _, request in  // miami_down_reply (test-metno.c:2715-2725)
            request.path.contains("lat=25.7617") ? .text("{}", status: 503) : .respond(status: 200, body: londonBody)
        }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let sydney = try Self.place(-33.8688, 151.2093)
        Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 503 Service Unavailable")
        await Self.expectRequests(server, 3)
        Self.set(clock, t0 + 1)
        let londonMember = try await Self.fetchOK(provider, london)
        await Self.expectRequests(server, 4)
        Self.expectRequest(server, 3, Self.londonPath, nil)
        try await Self.fetchOK(provider, sydney)
        await Self.expectRequests(server, 5)
        Self.set(clock, t0 + 2)
        await Self.expectFloorRefusal(provider, miami, server, 5)
        #expect(Self.same(try await Self.fetchOK(provider, london), londonMember))
        await Self.expectRequests(server, 5)
        Self.set(clock, t0 + 599)
        await Self.expectFloorRefusal(provider, miami, server, 5)
        Self.set(clock, t0 + 600)
        Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 503 Service Unavailable")
        await Self.expectRequests(server, 8)
    }

    // C: /metno/net/floor-records-bounded (test-metno.c:2768-2859)
    @Test func netFloorRecordsBounded() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.text("{}", status: 403)])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let n = Self.cacheMax + 1
        let many = 200
        let places = try (0..<many).map { try Self.place(-60.0 + 0.5 * Double($0), 50.0) }
        let forbidden = "HTTP 403 Forbidden"
        for i in 0..<n {
            Self.set(clock, t0 + Int64(i))
            Self.expectFailed(await Self.fetch(provider, places[i]), .http, forbidden)
        }
        await Self.expectRequests(server, n)
        Self.set(clock, t0 + 40)
        await Self.expectFloorRefusal(provider, places[1], server, n)
        await Self.expectFloorRefusal(provider, places[n - 1], server, n)
        Self.expectFailed(await Self.fetch(provider, places[0]), .http, forbidden)
        await Self.expectRequests(server, n + 1)
        Self.expectFailed(await Self.fetch(provider, places[1]), .http, forbidden)
        await Self.expectRequests(server, n + 2)
        await Self.expectFloorRefusal(provider, places[3], server, n + 2)
        await Self.expectFloorRefusal(provider, places[n - 1], server, n + 2)
        await Self.expectFloorRefusal(provider, places[0], server, n + 2)
        Self.expectFailed(await Self.fetch(provider, places[2]), .http, forbidden)
        await Self.expectRequests(server, n + 3)

        let second = try Self.provider(server, clock: clock)
        let base = server.requestCount
        for i in 0..<Self.cacheMax {
            Self.set(clock, t0 + 1000 + Int64(i))
            _ = await Self.fetch(second, places[i])
        }
        await Self.expectRequests(server, base + Self.cacheMax)
        Self.set(clock, t0 + 1000 + 600)  // WX_METNO_MIN_REFRESH_S
        Self.expectFailed(await Self.fetch(second, places[0]), .http, forbidden)
        await Self.expectRequests(server, base + Self.cacheMax + 1)
        await Self.expectFloorRefusal(second, places[1], server, base + Self.cacheMax + 1)
        await Self.expectFloorRefusal(second, places[Self.cacheMax - 1], server, base + Self.cacheMax + 1)
        let afterRenewal = base + Self.cacheMax + 1
        Self.expectFailed(await Self.fetch(second, places[Self.cacheMax + 5]), .http, forbidden)
        await Self.expectRequests(server, afterRenewal + 1)
        await Self.expectFloorRefusal(second, places[0], server, afterRenewal + 1)
        await Self.expectFloorRefusal(second, places[2], server, afterRenewal + 1)
        Self.expectFailed(await Self.fetch(second, places[1]), .http, forbidden)
        await Self.expectRequests(server, afterRenewal + 2)

        let third = try Self.provider(server, clock: clock)
        let start = server.requestCount
        for i in 0..<many {
            Self.set(clock, t0 + 5000 + Int64(i))
            _ = await Self.fetch(third, places[i])
        }
        await Self.expectRequests(server, start + many)
        await Self.expectFloorRefusal(third, places[many - 1], server, start + many)
        await Self.expectFloorRefusal(third, places[many - Self.cacheMax], server, start + many)
        Self.expectFailed(await Self.fetch(third, places[many - Self.cacheMax - 1]), .http, forbidden)
        await Self.expectRequests(server, start + many + 1)
    }

    // C: /metno/net/floor-and-throttle-with-entry (test-metno.c:3338-3392)
    @Test func netFloorAndThrottleWithEntry() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let state = LoopbackServer.Shared<String?>(nil)
        let server = try LoopbackServer(reply: try Self.throttleReply(state, holdLondon: false))
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let a = try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 1)
        state.value = "lat=25.7617"
        Self.set(clock, t0 + 700)
        Self.expectFailed(await Self.fetch(provider, miami), .rateLimited, Self.message429)
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 701)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.expectFailed(await Self.fetch(provider, london), .rateLimited, Self.pausedMessage)
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 759)
        Self.expectFailed(await Self.fetch(provider, london), .rateLimited, Self.pausedMessage)
        Self.set(clock, t0 + 760)
        try await Self.fetchOK(provider, london)
        await Self.expectRequests(server, 3)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        Self.set(clock, t0 + 1299)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        state.value = nil
        Self.set(clock, t0 + 1300)
        #expect(!Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 4)
    }

    // C: /metno/net/floor-join-does-not-renew (test-metno.c:2861-2893)
    @Test func netFloorJoinDoesNotRenew() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.hold(status: 403, body: Data("{}".utf8)), .text("{}", status: 403)])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let first = Pending(provider, miami)
        #expect(await Self.waitUntil { server.requestCount == 1 })
        Self.set(clock, t0 + 500)
        let joiner = Pending(provider, miami)
        #expect(await Self.waitUntil { provider.waiterCount == 2 })
        #expect(!joiner.done)
        server.release()
        Self.expectFailed(await first.wait(), .http, "HTTP 403 Forbidden")
        Self.expectFailed(await joiner.wait(), .http, "HTTP 403 Forbidden")
        await Self.expectRequests(server, 1)
        Self.set(clock, t0 + 600)
        Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 403 Forbidden")
        await Self.expectRequests(server, 2)
    }

    // C: /metno/net/floor-clock-backwards (test-metno.c:2895-2928)
    @Test func netFloorClockBackwards() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.text("{}", status: 403)])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 403 Forbidden")
        var requests = 1
        for start in [t0 - 1, t0 - 100_000] {
            Self.set(clock, start)
            Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 403 Forbidden")
            requests += 1
            await Self.expectRequests(server, requests)
            Self.set(clock, start + 599)
            await Self.expectFloorRefusal(provider, miami, server, requests)
            Self.set(clock, start + 600)
            Self.expectFailed(await Self.fetch(provider, miami), .http, "HTTP 403 Forbidden")
            requests += 1
            await Self.expectRequests(server, requests)
        }
    }

    // C: /metno/net/floor-serve-counts-as-use (test-metno.c:2949-2996)
    @Test func netFloorServeCountsAsUse() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let firstRequests = LoopbackServer.Shared(0)
        let body = try Self.miami()
        let server = try LoopbackServer { _, request in  // first_down_reply (test-metno.c:2937-2947)
            if request.path.contains("lat=10.0000&") && firstRequests.withLock({ n in n += 1; return n - 1 }) > 0 {
                return .text("{}", status: 403)
            }
            return .respond(status: 200, body: body)
        }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let places = try (0...Self.cacheMax).map { try Self.place(10.0 + 0.5 * Double($0), 20.0) }
        var first: WxMember?
        for i in 0..<Self.cacheMax {
            let member = try await Self.fetchOK(provider, places[i])
            if i == 0 { first = member }
        }
        let firstMember = try #require(first)
        await Self.expectRequests(server, Self.cacheMax)
        Self.set(clock, t0 + 700)
        Self.expectFailed(await Self.fetch(provider, places[0]), .http, "HTTP 403 Forbidden")
        await Self.expectRequests(server, Self.cacheMax + 1)
        Self.set(clock, t0 + 701)
        #expect(Self.same(try await Self.fetchOK(provider, places[0]), firstMember))
        await Self.expectRequests(server, Self.cacheMax + 1)
        try await Self.fetchOK(provider, places[Self.cacheMax])
        await Self.expectRequests(server, Self.cacheMax + 2)
        Self.set(clock, t0 + 702)
        #expect(Self.same(try await Self.fetchOK(provider, places[0]), firstMember))
        await Self.expectRequests(server, Self.cacheMax + 2)
        try await Self.fetchOK(provider, places[1])
        await Self.expectRequests(server, Self.cacheMax + 3)
    }

    // C: /metno/net/lru-eviction (test-metno.c:2998-3060)
    @Test func netLRUEviction() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let server = try LoopbackServer([try Self.ok(["Last-Modified: \(lm)", "Expires: \(Self.httpDate(t0 + 1500))"])])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let places = try (0...Self.cacheMax).map { try Self.place(10.0 + 0.5 * Double($0), 20.0) }
        for i in 0..<Self.cacheMax {
            try await Self.fetchOK(provider, places[i])
        }
        await Self.expectRequests(server, Self.cacheMax)
        try await Self.fetchOK(provider, places[0])
        await Self.expectRequests(server, Self.cacheMax)
        try await Self.fetchOK(provider, places[Self.cacheMax])
        await Self.expectRequests(server, Self.cacheMax + 1)
        try await Self.fetchOK(provider, places[0])
        try await Self.fetchOK(provider, places[2])
        try await Self.fetchOK(provider, places[Self.cacheMax])
        await Self.expectRequests(server, Self.cacheMax + 1)
        await Self.expectFloorRefusal(provider, places[1], server, Self.cacheMax + 1)
        Self.set(clock, t0 + 601)
        try await Self.fetchOK(provider, places[1])
        await Self.expectRequests(server, Self.cacheMax + 2)
        Self.set(clock, t0 + 1600)
        for _ in 0..<5 {
            try await Self.fetchOK(provider, places[Self.cacheMax])
        }
        await Self.expectRequests(server, Self.cacheMax + 3)
        Self.expectRequest(
            server, Self.cacheMax + 2, "/weatherapi/locationforecast/2.0/complete?lat=26.0000&lon=20.0000", lm)
        try await Self.fetchOK(provider, places[1])
        await Self.expectRequests(server, Self.cacheMax + 4)
        Self.expectRequest(
            server, Self.cacheMax + 3, "/weatherapi/locationforecast/2.0/complete?lat=10.5000&lon=20.0000", lm)
        try await Self.fetchOK(provider, places[3])
        await Self.expectRequests(server, Self.cacheMax + 5)
        Self.expectRequest(
            server, Self.cacheMax + 4, "/weatherapi/locationforecast/2.0/complete?lat=11.5000&lon=20.0000", nil)
        try await Self.fetchOK(provider, places[2])
        await Self.expectRequests(server, Self.cacheMax + 6)
        Self.expectRequest(
            server, Self.cacheMax + 5, "/weatherapi/locationforecast/2.0/complete?lat=11.0000&lon=20.0000", lm)
    }

    // C: /metno/net/not-modified-after-eviction (test-metno.c:3076-3128)
    @Test func netNotModifiedAfterEviction() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let miamiRequests = LoopbackServer.Shared(0)
        let body = try Self.miami()
        let server = try LoopbackServer { _, request in  // evict_reply (test-metno.c:3062-3074)
            if !request.path.contains("lat=25.7617") {
                return .respond(status: 200, body: body)
            }
            if miamiRequests.withLock({ n in n += 1; return n - 1 }) == 0 {
                return .respond(status: 200, headers: ["Last-Modified: \(lm)"], body: body)
            }
            return .hold(status: 304)
        }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock, timeoutMs: 60_000)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 700)
        let pending = Pending(provider, miami)
        #expect(await Self.waitUntil { server.requestCount == 2 })
        for i in 0..<Self.cacheMax {
            try await Self.fetchOK(provider, try Self.place(10.0 + 0.5 * Double(i), 20.0))
        }
        #expect(!pending.done)
        server.release()
        #expect(Self.same(try Self.member(await pending.wait()), a))
        await Self.expectRequests(server, 2 + Self.cacheMax)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2 + Self.cacheMax)
    }

    // MARK: net/ - failures

    // C: /metno/net/failure-table (test-metno.c:3130-3201)
    @Test func netFailureTable() async throws {
        let t0 = Self.realNowS()
        let badUnits = "{\"properties\":{\"meta\":{\"units\":{\"wind_speed\":\"knots\"}},\"timeseries\":["
            + "{\"time\":\"2026-10-12T19:00:00Z\",\"data\":{\"instant\":{\"details\":{\"air_temperature\":20}}}}]}}"
        var truncated = Data("{\"properties\":{".utf8)
        let sent = truncated.count
        truncated.append(Data(repeating: 0x20, count: 5000 - sent))
        typealias Case = (what: String, step: LoopbackServer.Step, code: WxError.Code, message: String?, requests: Int)
        let cases: [Case] = [  // test-metno.c:3138-3165
            ("404", .text("{}", status: 404), .notFound, "HTTP 404: not found", 1),
            ("429", .text("{}", status: 429), .rateLimited, "HTTP 429: rate limited", 1),
            ("403", .text("{}", status: 403), .http, "HTTP 403 Forbidden", 1),
            ("400", .text("{}", status: 400), .http, "HTTP 400 Bad Request", 1),
            ("422", .text("{}", status: 422), .http, "HTTP 422 Unprocessable Entity", 1),
            ("301", .respond(status: 301, headers: ["Location: http://127.0.0.1:1/x"]), .http,
             "HTTP 301 Moved Permanently", 1),
            ("304 without validator", .respond(status: 304), .http, "HTTP 304 Not Modified", 1),
            ("500", .text("{}", status: 500), .http, "HTTP 500 Internal Server Error", 3),
            ("503", .text("{}", status: 503), .http, "HTTP 503 Service Unavailable", 3),
            ("closed", .close, .network, nil, 3),
            ("truncated body", .truncated(status: 200, body: truncated, sent: sent), .network, nil, 3),
            ("declared 50 MiB", .bigDeclared(size: 50 * 1024 * 1024), .parse, nil, 1),
            ("200 empty", .text("", status: 200), .parse, "empty response", 1),
            ("204", .respond(status: 204), .parse, "empty response", 1),
            ("200 html", .text("<html>Bad Gateway</html>"), .parse, "malformed JSON", 1),
            ("200 array", .text("[]"), .parse, "response is not a JSON object", 1),
            ("200 object", .text("{}"), .parse, "not a locationforecast document", 1),
            ("no series", .text("{\"properties\":{\"timeseries\":[]}}"), .parse, "no usable forecast data", 1),
            ("other units", .text(badUnits), .parse, "unexpected units", 1),
            ("gzip garbage", .gzip(body: Data("not json at all".utf8)), .parse, "malformed JSON", 1),
        ]
        for c in cases {
            let clock = Self.clockAt(t0)
            let server = try LoopbackServer([c.step])
            defer { server.stop() }
            let provider = try Self.provider(server, clock: clock)
            let miami = try Self.place(Self.miamiLat, Self.miamiLon)
            let outcome = await Self.fetch(provider, miami)
            Self.expectFailed(outcome, c.code, c.message)
            if case .failure(let error as WxError) = outcome {
                #expect(!error.message.contains("Bad Gateway</html>"), "\(c.what)")
            }
            await Self.expectRequests(server, c.requests)
            #expect(server.requestCount == c.requests, "case \(c.what)")
            for held: Int64 in [0, 1, 300, 599] {
                Self.set(clock, t0 + held)
                await Self.expectFloorRefusal(provider, miami, server, c.requests)
            }
            Self.set(clock, t0 + 600)
            Self.expectFailed(await Self.fetch(provider, miami), c.code, nil)
            await Self.expectRequests(server, 2 * c.requests)
            Self.expectRequest(server, c.requests, Self.miamiPath, nil)
            Self.set(clock, t0 + 1199)
            await Self.expectFloorRefusal(provider, miami, server, 2 * c.requests)
        }
    }

    // C: /metno/net/bad-body-keeps-cache (test-metno.c:3203-3240)
    @Test func netBadBodyKeepsCache() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let server = try LoopbackServer([
            try Self.ok(["Last-Modified: \(lm)"]), .text("{\"properties\":{\"timeseries\":[]}}"), .respond(status: 304),
        ])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 700)
        Self.expectFailed(await Self.fetch(provider, miami), .parse, "no usable forecast data")
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 701)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1300)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        Self.expectRequest(server, 2, Self.miamiPath, lm)
    }

    // MARK: net/ - the throttle

    /// throttle_reply (test-metno.c:3242-3252): London (held when asked), 429 for
    /// the path containing `state`, miami_text otherwise.
    static func throttleReply(_ state: LoopbackServer.Shared<String?>, holdLondon: Bool) throws
        -> @Sendable (Int, LoopbackServer.Request) -> LoopbackServer.Step
    {
        let londonBody = try london()
        let miamiBody = try miami()
        return { _, request in
            if request.path.contains("lat=51.5072") {
                return holdLondon ? .hold(status: 200, body: londonBody) : .respond(status: 200, body: londonBody)
            }
            if let fail = state.value, request.path.contains(fail) {
                return .text("{}", status: 429)
            }
            return .respond(status: 200, body: miamiBody)
        }
    }

    // C: /metno/net/throttle-429 (test-metno.c:3254-3336)
    @Test func netThrottle429() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let state = LoopbackServer.Shared<String?>("lat=25.7617")
        let server = try LoopbackServer(reply: try Self.throttleReply(state, holdLondon: false))
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let sydney = try Self.place(-33.8688, 151.2093)
        let tokyo = try Self.place(35.68, 139.69)
        let londonMember = try await Self.fetchOK(provider, london)
        await Self.expectRequests(server, 1)
        Self.expectFailed(await Self.fetch(provider, miami), .rateLimited, Self.message429)
        await Self.expectRequests(server, 2)
        let refused: [(WxPlace, String)] = [
            (miami, Self.floorMessage), (sydney, Self.pausedMessage), (miami, Self.floorMessage),
            (sydney, Self.pausedMessage),
        ]  // test-metno.c:3279-3282
        for (place, message) in refused {
            Self.expectFailed(await Self.fetch(provider, place), .rateLimited, message)
            await Self.expectRequests(server, 2)
        }
        #expect(Self.same(try await Self.fetchOK(provider, london), londonMember))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 59)
        Self.expectFailed(await Self.fetch(provider, sydney), .rateLimited, Self.pausedMessage)
        await Self.expectRequests(server, 2)
        state.value = "lat=-33.8688"
        Self.set(clock, t0 + 60)
        Self.expectFailed(await Self.fetch(provider, sydney), .rateLimited, Self.message429)
        await Self.expectRequests(server, 3)
        Self.set(clock, t0 + 60 + 59)
        Self.expectFailed(await Self.fetch(provider, tokyo), .rateLimited, Self.pausedMessage)
        await Self.expectRequests(server, 3)
        await Self.expectFloorRefusal(provider, sydney, server, 3)
        await Self.expectFloorRefusal(provider, miami, server, 3)
        state.value = nil
        Self.set(clock, t0 + 120)
        try await Self.fetchOK(provider, tokyo)
        await Self.expectRequests(server, 4)
        Self.set(clock, t0 + 2000)
        state.value = "lat=35.6800"
        Self.expectFailed(await Self.fetch(provider, tokyo), .rateLimited, Self.message429)
        Self.expectFailed(await Self.fetch(provider, london), .rateLimited, Self.pausedMessage)
        await Self.expectRequests(server, 5)
    }

    // C: /metno/net/throttle-clock-backwards (test-metno.c:3394-3422)
    @Test func netThrottleClockBackwards() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let state = LoopbackServer.Shared<String?>("lat=25.7617")
        let server = try LoopbackServer(reply: try Self.throttleReply(state, holdLondon: false))
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        Self.expectFailed(await Self.fetch(provider, miami), .rateLimited, Self.message429)
        Self.set(clock, t0 + 30)
        Self.expectFailed(await Self.fetch(provider, london), .rateLimited, Self.pausedMessage)
        await Self.expectRequests(server, 1)
        await Self.expectFloorRefusal(provider, miami, server, 1)
        Self.set(clock, t0 - 1)
        Self.expectFailed(await Self.fetch(provider, miami), .rateLimited, Self.message429)
        await Self.expectRequests(server, 2)
    }

    // C: /metno/net/throttle-spares-in-flight (test-metno.c:3424-3463)
    @Test func netThrottleSparesInFlight() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let state = LoopbackServer.Shared<String?>("lat=25.7617")
        let server = try LoopbackServer(reply: try Self.throttleReply(state, holdLondon: true))
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let slow = Pending(provider, london)
        #expect(await Self.waitUntil { server.requestCount == 1 })
        Self.expectFailed(await Self.fetch(provider, miami), .rateLimited, Self.message429)
        #expect(!slow.done)
        Self.expectFailed(await Self.fetch(provider, try Self.place(-33.8688, 151.2093)), .rateLimited, Self.pausedMessage)
        let joiner = Pending(provider, london)
        #expect(await Self.waitUntil { provider.waiterCount == 2 })
        #expect(!slow.done && !joiner.done)
        server.release()
        let slowMember = try Self.member(await slow.wait())
        #expect(Self.same(slowMember, try Self.member(await joiner.wait())))
        await Self.expectRequests(server, 2)
    }

    // MARK: net/ - shared requests, cancellation, cap, lifecycle

    // C: /metno/net/shared-request (test-metno.c:3466-3500). C answers after 120 ms
    // and relies on the synchronous fetch_start; here the answer is held until all
    // four fetches wait, so the sharing is not timing-dependent.
    @Test func netSharedRequest() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([.hold(status: 200, body: try Self.miami())])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        let pendings = [Pending(provider, miami), Pending(provider, miami), Pending(provider, miami),
                        Pending(provider, london)]
        #expect(await Self.waitUntil { provider.waiterCount == 4 && server.heldCount == 2 })
        server.release()
        var members: [WxMember] = []
        for pending in pendings {
            members.append(try Self.member(await pending.wait()))
        }
        await Self.expectRequests(server, 2)
        #expect(Self.same(members[0], members[1]) && Self.same(members[0], members[2]))
    }

    // C: /metno/net/cancel-one-of-shared (test-metno.c:3502-3542)
    @Test func netCancelOneOfShared() async throws {
        let clock = Self.clockAt(Self.realNowS())
        for victim in 0..<3 {
            let server = try LoopbackServer([.hold(status: 200, body: try Self.miami())])
            defer { server.stop() }
            let provider = try Self.provider(server, clock: clock)
            let miami = try Self.place(Self.miamiLat, Self.miamiLon)
            let pendings = (0..<3).map { _ in Pending(provider, miami) }
            #expect(await Self.waitUntil { server.requestCount == 1 && provider.waiterCount == 3 })
            pendings[victim].cancel()
            Self.expectCancelled(await pendings[victim].wait())
            for i in 0..<3 where i != victim {
                #expect(!pendings[i].done)
            }
            server.release()
            for i in 0..<3 where i != victim {
                try Self.member(await pendings[i].wait())
            }
            await Self.expectRequests(server, 1)
        }
    }

    // C: /metno/net/cancel-all-cancels-request (test-metno.c:3544-3593)
    @Test func netCancelAllCancelsRequest() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let server = try LoopbackServer([.hang, try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let pendings = (0..<3).map { _ in Pending(provider, miami) }
        #expect(await Self.waitUntil { server.requestCount == 1 && provider.waiterCount == 3 })
        pendings[1].cancel()
        Self.expectCancelled(await pendings[1].wait())
        #expect(!pendings[0].done)
        await Self.spin(25)
        #expect(server.closedEarlyCount == 0)  // two fetches still wait: the request goes on
        pendings[0].cancel()
        pendings[2].cancel()
        Self.expectCancelled(await pendings[0].wait())
        Self.expectCancelled(await pendings[2].wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == 1 })  // the HTTP request was aborted
        await Self.expectFloorRefusal(provider, miami, server, 1)
        Self.set(clock, t0 + 599)
        await Self.expectFloorRefusal(provider, miami, server, 1)
        Self.set(clock, t0 + 600)
        try await Self.fetchOK(provider, miami)
        await Self.expectRequests(server, 2)
    }

    // C: /metno/net/fetch-right-after-cancel-all (test-metno.c:3595-3631)
    @Test func netFetchRightAfterCancelAll() async throws {
        let t0 = Self.realNowS()
        for later: Int64 in 0..<2 {
            let clock = Self.clockAt(t0)
            let server = try LoopbackServer([.hang, try Self.ok()])
            defer { server.stop() }
            let provider = try Self.provider(server, clock: clock, timeoutMs: 60_000)
            let miami = try Self.place(Self.miamiLat, Self.miamiLon)
            let first = Pending(provider, miami)
            #expect(await Self.waitUntil { server.requestCount == 1 && provider.waiterCount == 1 })
            first.cancel()
            Self.set(clock, t0 + 600 * later)
            let second = await Self.fetch(provider, miami)
            Self.expectCancelled(await first.wait())
            if later == 0 {
                Self.expectFailed(second, .rateLimited, Self.floorMessage)
                await Self.expectRequests(server, 1)
            } else {
                try Self.member(second)
                await Self.expectRequests(server, 2)
            }
        }
    }

    // C: /metno/net/cancel-before-and-after (test-metno.c:3633-3698). "Cancelled
    // inside the callback, before finish" is the provider's test-only outcome probe
    // cancelling the fetch's task after its outcome is known and before it returns.
    @Test func netCancelBeforeAndAfter() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let cancelInProbe = LoopbackServer.Shared(false)
        let provider = try Self.provider(server, clock: clock) {
            if cancelInProbe.value {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        // Already cancelled: no request, not even a connection.
        Self.expectCancelled(await Pending(provider, miami, preCancelled: true).wait())
        await Self.spin(30)
        await Self.expectRequests(server, 0)
        #expect(server.connectionCount == 0)
        // Cancelled between completion and return: cancelled, the answer is cached.
        cancelInProbe.value = true
        Self.expectCancelled(await Pending(provider, miami).wait())
        await Self.expectRequests(server, 1)
        // The same for an answer served from the cache.
        Self.expectCancelled(await Pending(provider, miami).wait())
        await Self.expectRequests(server, 1)
        cancelInProbe.value = false
        // Cancelled after it returned: no effect on what was delivered.
        let after = Pending(provider, miami)
        let delivered = await after.wait()
        after.cancel()
        try Self.member(delivered)
        await Self.expectRequests(server, 1)
        // C's invalid place with a cancelled cancellable (test-metno.c:3687-3695) cannot be
        // built (WxPlace validates); a cancelled fetch of a valid place is covered above.
    }

    // C: /metno/net/cancel-in-flight (test-metno.c:3700-3734)
    @Test func netCancelInFlight() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let healthy = LoopbackServer.Shared(false)
        let body = try Self.miami()
        let server = try LoopbackServer { _, _ in healthy.value ? .respond(status: 200, body: body) : .hang }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let pending = Pending(provider, miami)
        #expect(await Self.waitUntil { server.requestCount == 1 })
        #expect(!pending.done)
        pending.cancel()
        Self.expectCancelled(await pending.wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == 1 })
        await Self.spin(30)
        await Self.expectRequests(server, 1)  // a cancelled request is not retried
        await Self.expectFloorRefusal(provider, miami, server, 1)
        healthy.value = true
        Self.set(clock, Self.realNowS() + 600)
        try await Self.fetchOK(provider, miami)
    }

    // C: /metno/net/cancelled-request-keeps-entry (test-metno.c:4087-4123)
    @Test func netCancelledRequestKeepsEntry() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let lm = Self.httpDate(t0 - 100)
        let server = try LoopbackServer([try Self.ok(["Last-Modified: \(lm)"]), .hang, .respond(status: 304)])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let a = try await Self.fetchOK(provider, miami)
        Self.set(clock, t0 + 700)
        let pending = Pending(provider, miami)
        #expect(await Self.waitUntil { server.requestCount == 2 })
        Self.expectRequest(server, 1, Self.miamiPath, lm)
        pending.cancel()
        Self.expectCancelled(await pending.wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == 1 })
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1299)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 2)
        Self.set(clock, t0 + 1300)
        #expect(Self.same(try await Self.fetchOK(provider, miami), a))
        await Self.expectRequests(server, 3)
        Self.expectRequest(server, 2, Self.miamiPath, lm)
    }

    // C: /metno/net/inflight-cap (test-metno.c:3736-3835)
    @Test func netInflightCap() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([.hang])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let places = try (0...Self.maxInflight).map { try Self.place(40.0 + 0.1 * Double($0), 10.0) }
        let outs = places.prefix(Self.maxInflight).map { Pending(provider, $0) }
        #expect(await Self.waitUntil { server.requestCount >= 1 && provider.outstandingCount == Self.maxInflight })
        await Self.spin(100)
        let onWire = server.requestCount
        #expect(onWire <= Self.maxInflight)
        // One more place: refused at once, without traffic, and not by a throttle.
        Self.expectFailed(await Self.fetch(provider, places[Self.maxInflight]), .rateLimited, Self.capMessage)
        await Self.expectRequests(server, onWire)
        // A fetch of a place in flight joins its request.
        let joiner = Pending(provider, places[0])
        await Self.spin(30)
        #expect(!joiner.done)
        await Self.expectRequests(server, onWire)
        for out in outs { out.cancel() }
        joiner.cancel()
        for out in outs { Self.expectCancelled(await out.wait()) }
        Self.expectCancelled(await joiner.wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == server.requestCount })
        // The slots come back: the refusal ends and the next fetch is a request.
        var before = server.requestCount
        var probe = Pending(provider, places[Self.maxInflight])
        while true {
            let current = probe
            let floor = before
            #expect(await Self.waitUntil { current.done || server.requestCount > floor })
            if !current.done { break }
            Self.expectFailed(await current.wait(), .rateLimited, Self.capMessage)
            await Self.spin(2)
            probe = Pending(provider, places[Self.maxInflight])
        }
        probe.cancel()
        Self.expectCancelled(await probe.wait())
        #expect(await Self.waitUntil { server.closedEarlyCount == server.requestCount })
        // And all 16 slots are usable again.
        await Self.spin(50)
        before = server.requestCount
        let again = try (0..<Self.maxInflight).map { Pending(provider, try Self.place(-20.0 - 0.1 * Double($0), 30.0)) }
        #expect(await Self.waitUntil { server.requestCount > before })
        await Self.spin(100)
        for pending in again {
            #expect(!pending.done)
            pending.cancel()
        }
        for pending in again {
            Self.expectCancelled(await pending.wait())
        }
        #expect(await Self.waitUntil { server.closedEarlyCount == server.requestCount })
    }

    // C: /metno/net/drop-provider-in-flight (test-metno.c:3837-3883)
    @Test func netDropProviderInFlight() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let hang = LoopbackServer.Shared(false)
        let body = try Self.miami()
        let server = try LoopbackServer { _, _ in
            hang.value ? .hang : .respond(status: 200, body: body, delay: .milliseconds(80))
        }
        defer { server.stop() }
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let london = try Self.place(Self.londonLat, Self.londonLon)
        weak var weakProvider: METNorwayProvider?
        var pendings: [Pending] = []
        do {
            let provider = try Self.provider(server, clock: clock)
            weakProvider = provider
            pendings = [Pending(provider, miami), Pending(provider, miami)]
        }  // the caller's last reference is gone
        #expect(weakProvider != nil)
        let first = try Self.member(await pendings[0].wait())
        #expect(Self.same(first, try Self.member(await pendings[1].wait())))
        Self.expectInvariants(first)
        pendings = []
        #expect(await Self.waitUntil { weakProvider == nil })  // released once the work is done

        hang.value = true
        var pending: Pending?
        do {
            let provider = try Self.provider(server, clock: clock)
            weakProvider = provider
            pending = Pending(provider, london)
        }
        #expect(await Self.waitUntil { server.requestCount == 2 })
        pending?.cancel()
        Self.expectCancelled(await pending!.wait())
        pending = nil
        #expect(await Self.waitUntil { weakProvider == nil })
    }

    // C: /metno/net/invalid-places (test-metno.c:3912-3949). The C test hands the
    // provider hand-built invalid places; a WxPlace cannot be invalid, so each of
    // them is refused where it would be built and never reaches fetch.
    @Test func netInvalidPlaces() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([try Self.ok()])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        #expect(throws: WxError.self) { try WxPlace(name: nil, lat: 10.0, lon: 20.0) }  // nulls
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: .nan, lon: 20.0) }
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: 10.0, lon: .infinity) }
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: 90.0000001, lon: 20.0) }
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: 10.0, lon: -180.0000001) }
        #expect(throws: WxError.self) { try WxPlace(name: "", lat: 10.0, lon: 20.0) }
        #expect(throws: WxError.self) { try WxPlace(name: "a\nb", lat: 10.0, lon: 20.0) }
        #expect(throws: WxError.self) { try WxPlace(name: "x", lat: 10.0, lon: 20.0, timezone: "../etc/passwd") }
        #expect(throws: WxError.self) { try WxPlace(name: "x", countryCode: "xy", lat: 10.0, lon: 20.0) }
        await Self.expectRequests(server, 0)
        try await Self.fetchOK(provider, try WxPlace(name: "x", lat: 10.0, lon: 20.0))
        await Self.expectRequests(server, 1)
    }

    // C: /metno/net/callbacks-once-never-nested (test-metno.c:3998-4042)
    @Test func netCallbacksOnceNeverNested() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([.respond(status: 200, body: try Self.miami(), delay: .milliseconds(20))])
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        try await Self.fetchOK(provider, miami)  // a network answer ...
        try await Self.fetchOK(provider, miami)  // ... then a cache hit started right after it
        await Self.spin(30)
        await Self.expectRequests(server, 1)
        // Fire and forget: the request is made, nothing is delivered.
        let london = try Self.place(Self.londonLat, Self.londonLon)
        Task { _ = try? await provider.fetch(london) }
        #expect(await Self.waitUntil { server.requestCount == 2 })
        await Self.spin(60)
        try await Self.fetchOK(provider, london)  // served from what it stored
        await Self.expectRequests(server, 2)
        try await Self.fetchOK(provider, miami)
    }

    // C: /metno/net/stress (test-metno.c:4152-4229), the default 25 rounds.
    @Test func netStress() async throws {
        let t0 = Self.realNowS()
        let clock = Self.clockAt(t0)
        let calm = LoopbackServer.Shared(false)
        let body = try Self.miami()
        let server = try LoopbackServer { index, _ in  // stress_reply (test-metno.c:4134-4147)
            if calm.value { return .respond(status: 200, body: body, delay: .milliseconds(40)) }
            let delay = Duration.milliseconds((index * 37) % 70)
            if index % 11 == 5 { return .close }
            if index % 13 == 7 { return .respond(status: 304, delay: delay) }
            return .respond(status: 200, body: body, delay: delay)
        }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        var rng = SeededRNG(seed: 4242)  // test-metno.c:4159
        let places = try (0..<12).map { try Self.place(30.0 + Double($0), -80.0) }
        for round in 0..<25 {
            Self.set(clock, t0 + Int64(round) * 400)
            var outs: [Pending] = []
            for _ in 0..<10 {
                let cancellable = Int.random(in: 0..<3, using: &rng) != 0
                let cancelAfter = cancellable && Bool.random(using: &rng) ? Int.random(in: 0..<40, using: &rng) : nil
                let pending = Pending(provider, places[Int.random(in: 0..<places.count, using: &rng)])
                if let cancelAfter {
                    Task {
                        try? await Task.sleep(for: .microseconds(500 * cancelAfter))
                        pending.cancel()
                    }
                }
                outs.append(pending)
            }
            for pending in outs {
                switch await pending.wait() {
                case .success:
                    Self.expectInvariants(try Self.member(await pending.wait()))
                case .failure(let error):
                    let wx = error as? WxError
                    let ok = error is CancellationError || wx?.code == .network || wx?.code == .http
                        || (wx?.code == .rateLimited && wx?.message == Self.floorMessage)
                    #expect(ok, "round \(round): \(error)")
                }
            }
        }
        calm.value = true
        Self.set(clock, t0 + 1_000_000)
        await Self.spin(200)
        let fresh = try (0..<Self.maxInflight).map { Pending(provider, try Self.place(-50.0 - Double($0), 100.0)) }
        for pending in fresh {
            try Self.member(await pending.wait())
        }
    }

    // C: none (contract wx-http.c:2054, 2080 + wx-metno.c:980-981, DECISIONS #68 D-O7): a
    // pre-cancelled fetch at the 16-request cap throws CancellationError and starts no throttle.
    @Test func netCancelledCapRefusalStartsNoThrottle() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let hang = LoopbackServer.Shared(true)
        let body = try Self.miami()
        let server = try LoopbackServer { _, _ in hang.value ? .hang : .respond(status: 200, body: body) }
        defer { server.stop() }
        let provider = try Self.provider(server, clock: clock)
        let places = try (0...Self.maxInflight).map { try Self.place(40.0 + 0.1 * Double($0), 10.0) }
        let outs = places.prefix(Self.maxInflight).map { Pending(provider, $0) }
        #expect(await Self.waitUntil { server.requestCount >= 1 && provider.http.outstandingCount == Self.maxInflight })
        await Self.spin(100)
        let onWire = server.requestCount
        // Pre-cancelled at the provider and HTTP client cap: CancellationError, no throttle.
        Self.expectCancelled(await Pending(provider, places[Self.maxInflight], preCancelled: true).wait())
        let cancelledClient: Result<HTTPClient.Response, any Error> = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return .success(try await provider.http.get(Self.miamiPath, accept: METNorwayParse.accept))
            } catch {
                return .failure(error)
            }
        }.value
        #expect(throws: CancellationError.self) { _ = try cancelledClient.get() }
        await Self.expectRequests(server, onWire)
        for out in outs { out.cancel() }
        for out in outs { Self.expectCancelled(await out.wait()) }
        #expect(await Self.waitUntil { provider.outstandingCount == 0 && provider.http.outstandingCount == 0 })
        hang.value = false
        try await Self.fetchOK(provider, try Self.place(Self.miamiLat, Self.miamiLon))
    }

    // C: none (contract wx-metno.h:56-58 "a cancelled one included changes no entry", DECISIONS #49):
    // when the sole waiter cancels while the response is being parsed, nothing is stored in the cache.
    @Test func netCancelledDuringParseStoresNothing() async throws {
        let clock = Self.clockAt(Self.realNowS())
        let server = try LoopbackServer([try Self.ok(), try Self.ok()])
        defer { server.stop() }
        let holder = LoopbackServer.Shared<Pending?>(nil)
        let provider = try Self.provider(server, clock: clock, parseProbe: {
            holder.value?.cancel()
        })
        let miami = try Self.place(Self.miamiLat, Self.miamiLon)
        let pending = Pending(provider, miami)
        holder.value = pending
        Self.expectCancelled(await pending.wait())
        #expect(await Self.waitUntil { provider.outstandingCount == 0 })
        #expect(provider.cacheEntryCount == 0)
        // Because the request was sent and nothing was cached, the 10-minute floor refuses a re-fetch.
        await Self.expectFloorRefusal(provider, miami, server, 1)
        Self.set(clock, Self.realNowS() + 600)
        try await Self.fetchOK(provider, miami)
        #expect(provider.cacheEntryCount == 1)
        await Self.expectRequests(server, 2)
    }
}
