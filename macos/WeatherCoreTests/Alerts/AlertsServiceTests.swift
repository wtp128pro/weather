// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsServiceTests.swift - the alerts service end to end through refresh(_:)
// and result(for:), with the real routing, parsers and region matching but a
// fake fetcher and a ManualClock (no network, no sleeps): routing (the empty
// country code included; only two ASCII letters are a code), one MeteoAlarm
// fetch per country shared by its places and at most one per 30 minutes, a
// failed feed answer shared by every place asking within 120 s of its age (a
// time-based hold, failedFeedHoldUS) and asked again after it (DECISIONS #38),
// 5-minute reuse of point answers, no fetch
// without a refresh call, expiry and staleness at the clock's time, the five
// result states, failures, hangs and cancellations isolated as "unavailable"
// (or a kept in-window set, DECISIONS #35), and where the work runs. The fetcher's bodies are minimal valid answers of each issuer, built
// inline (no fixture files).

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

/// Whether the calling code runs on the main thread (the main actor's executor).
private func onMainThread() -> Bool {
    Thread.isMainThread
}

/// Events recorded from any thread; a test waits for them without sleeping.
private final class Events: Sendable {
    private struct Waiter {
        let prefix: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var list: [String] = []
        var waiters: [Waiter] = []

        func count(_ prefix: String) -> Int {
            list.filter { $0.hasPrefix(prefix) }.count
        }
    }

    private let state = Mutex(State())

    func add(_ event: String) {
        let ready: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.list.append(event)
            let snapshot = s
            let done = s.waiters.filter { snapshot.count($0.prefix) >= $0.count }
            s.waiters.removeAll { snapshot.count($0.prefix) >= $0.count }
            return done.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    /// How many events start with `prefix`.
    func count(_ prefix: String) -> Int {
        state.withLock { $0.count(prefix) }
    }

    /// Returns once at least `count` events start with `prefix`.
    func wait(_ prefix: String, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = state.withLock { s in
                if s.count(prefix) >= count {
                    return true
                }
                s.waiters.append(Waiter(prefix: prefix, count: count, continuation: continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }
}

/// A fetcher answering per URL or per source, recording every call.
private final class FakeFetcher: Sendable {
    enum Behavior: Sendable {
        /// Answers at once.
        case reply(Int, Data)
        /// Throws a transport error.
        case fail
        /// Throws CancellationError.
        case cancel
        /// Answers once `openGate()` is called (at once after it).
        case gate(Int, Data)
        /// As the wrapped behavior, once `openGate()` is called (at once after it).
        indirect case gated(Behavior)
        /// Never answers, ignoring cancellation, until `releaseHung()`.
        case hang
        /// As `hang` on the first call of its URL (ended by the service's deadline); throws a
        /// transport error on later ones.
        case hangFirst
    }

    struct Call: Sendable, Equatable {
        let source: WxAlert.Source
        let url: String
    }

    private struct State {
        var bySource: [WxAlert.Source: Behavior] = [:]
        var byURL: [String: Behavior] = [:]
        var calls: [Call] = []
        var gateOpen = false
        var gated: [CheckedContinuation<Void, Never>] = []
        var hung: [CheckedContinuation<Void, Never>] = []
    }

    let events = Events()
    private let state = Mutex(State())

    func set(_ source: WxAlert.Source, _ behavior: Behavior) {
        state.withLock { $0.bySource[source] = behavior }
    }

    func set(url: String, _ behavior: Behavior) {
        state.withLock { $0.byURL[url] = behavior }
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func count(_ source: WxAlert.Source) -> Int {
        calls.filter { $0.source == source }.count
    }

    func count(url: String) -> Int {
        calls.filter { $0.url == url }.count
    }

    func openGate() {
        let waiting = state.withLock { s in
            s.gateOpen = true
            defer { s.gated = [] }
            return s.gated
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    func releaseHung() {
        let waiting = state.withLock { s in
            defer { s.hung = [] }
            return s.hung
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    var fetch: WxAlertsFetch {
        { source, url in try await self.answer(source, url) }
    }

    private func answer(_ source: WxAlert.Source, _ url: String) async throws -> WxAlertsResponse {
        let (behavior, first) = state.withLock { s in
            let first = !s.calls.contains { $0.url == url }
            s.calls.append(Call(source: source, url: url))
            return (s.byURL[url] ?? s.bySource[source] ?? .reply(200, Bodies.empty(source)), first)
        }
        events.add("fetch \(source.rawValue) main=\(onMainThread())")
        return try await respond(behavior, first: first)
    }

    private func respond(_ behavior: Behavior, first: Bool) async throws -> WxAlertsResponse {
        switch behavior {
        case .reply(let status, let body):
            return WxAlertsResponse(status: status, body: body)
        case .fail:
            throw URLError(.notConnectedToInternet)
        case .cancel:
            throw CancellationError()
        case .gate(let status, let body):
            await passGate()
            return WxAlertsResponse(status: status, body: body)
        case .gated(let then):
            await passGate()
            return try await respond(then, first: first)
        case .hang:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.withLock { $0.hung.append(continuation) }
            }
            throw URLError(.timedOut)
        case .hangFirst:
            if first {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.hung.append(continuation) }
                }
            }
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Returns once `openGate()` has been called.
    private func passGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open: Bool = state.withLock { s in
                if s.gateOpen {
                    return true
                }
                s.gated.append(continuation)
                return false
            }
            if open {
                continuation.resume()
            }
        }
    }
}

/// Minimal valid answers of each issuer.
private enum Bodies {
    static let past = "2026-10-10T23:00:00Z"  // T0 - 1 h
    static let plus1m = "2026-10-11T00:01:00Z"
    static let plus3m = "2026-10-11T00:03:00Z"
    static let plus20m = "2026-10-11T00:20:00Z"
    static let plus6h = "2026-10-11T06:00:00Z"
    /// A square around Zurich (not Bern, not Geneva), as a CAP polygon "lat,lon ...".
    static let zurichSquare = "47.0,8.0 47.0,9.0 47.8,9.0 47.8,8.0 47.0,8.0"

    static func empty(_ source: WxAlert.Source) -> Data {
        switch source {
        case .nws, .metNorway, .eccc: Data(#"{"features":[]}"#.utf8)
        case .dwd: Data(#"{"alerts":[]}"#.utf8)
        case .meteoAlarm: Data(#"{"warnings":[]}"#.utf8)
        }
    }

    /// An NWS alerts/active answer with these alerts (id, expires, ends).
    static func nws(_ alerts: [(id: String, expires: String, ends: String?)]) -> Data {
        let features = alerts.map { a in
            #"{"id":"https://api.weather.gov/alerts/\#(a.id)","properties":{"id":"\#(a.id)","#
                + #""event":"Wind Advisory","headline":"Wind Advisory \#(a.id)","severity":"Moderate","#
                + #""status":"Actual","messageType":"Alert","effective":"2026-10-10T22:00:00Z","#
                + #""onset":"2026-10-10T22:00:00Z","expires":"\#(a.expires)","ends":"#
                + (a.ends.map { #""\#($0)""# } ?? "null") + "}}"
        }
        return Data((#"{"features":["# + features.joined(separator: ",") + "]}").utf8)
    }

    /// One MeteoAlarm feed entry with one area, by polygon or by one geocode.
    static func warning(_ id: String, expires: String, polygon: String? = nil,
                        geocode: (type: String, code: String)? = nil) -> String {
        var area: [String] = [#""areaDesc":"Area \#(id)""#]
        if let polygon {
            area.append(#""polygon":["\#(polygon)"]"#)
        }
        if let geocode {
            area.append(#""geocode":[{"valueName":"\#(geocode.type)","value":"\#(geocode.code)"}]"#)
        }
        return #"{"alert":{"identifier":"\#(id)","sender":"test@example.org","status":"Actual","#
            + #""msgType":"Alert","info":[{"language":"en-GB","event":"Wind","headline":"Wind \#(id)","#
            + #""effective":"2026-10-10T22:00:00Z","onset":"2026-10-10T22:00:00Z","expires":"\#(expires)","#
            + #""parameter":[{"valueName":"awareness_level","value":"2; yellow; Moderate"}],"#
            + #""area":[{"# + area.joined(separator: ",") + "}]}]}}"
    }

    static func feed(_ warnings: [String]) -> Data {
        Data((#"{"warnings":["# + warnings.joined(separator: ",") + "]}").utf8)
    }

    /// `json` followed by spaces up to `size` bytes (still valid JSON).
    static func padded(_ json: String, to size: Int) -> Data {
        var data = Data(json.utf8)
        data.append(Data(repeating: 0x20, count: size - data.count))
        return data
    }
}

/// Places (valid by construction).
private enum P {
    static func make(_ name: String, _ cc: String, _ lat: Double, _ lon: Double) -> WxPlace {
        try! WxPlace(name: name, countryCode: cc.isEmpty ? nil : cc, lat: lat, lon: lon)
    }

    static let miami = make("Miami", "US", 25.7617, -80.1918)
    static let miamiBeach = make("Miami Beach", "US", 25.7907, -80.1300)
    static let sanJuan = make("San Juan", "PR", 18.4655, -66.1057)
    static let berlin = make("Berlin", "DE", 52.5200, 13.4050)
    static let oslo = make("Oslo", "NO", 59.9139, 10.7522)
    static let toronto = make("Toronto", "CA", 43.6532, -79.3832)
    static let zurich = make("Zurich", "CH", 47.3769, 8.5417)
    static let bern = make("Bern", "CH", 46.9480, 7.4474)
    static let geneva = make("Geneva", "CH", 46.2044, 6.1432)
    static let lugano = make("Lugano", "CH", 46.0037, 8.9511)
    static let basel = make("Basel", "CH", 47.5596, 7.5886)
    static let paris = make("Paris", "FR", 48.8566, 2.3522)
    static let saintDenis = make("Saint-Denis", "FR", -20.8823, 55.4504)  // Reunion
    static let andorra = make("Andorra la Vella", "AD", 42.5063, 1.5218)
    static let tokyo = make("Tokyo", "JP", 35.6762, 139.6503)
    static let sydney = make("Sydney", "AU", -33.8688, 151.2093)
    static let tijuana = make("Tijuana", "MX", 32.5149, -117.0382)
}

/// How a country feed fetch fails (DECISIONS #38: each one is shared by every place asking
/// within failedFeedHoldUS, 120 s of the failed answer's age).
enum AlertsFeedFailure: String, CaseIterable, Sendable {
    case status503, unreadable200, oversized, thrown, timeout

    fileprivate var behavior: FakeFetcher.Behavior {
        switch self {
        case .status503: .reply(503, Data("busy".utf8))
        // A 2xx the parser rejects.
        case .unreadable200: .reply(200, Data("<html><body>busy</body></html>".utf8))
        case .oversized: .reply(200, Bodies.padded(#"{"warnings":[]}"#, to: AlertsService.feedMaxBytes + 1))
        case .thrown: .fail
        // Ended by the service's deadline (fetchTimeoutUS).
        case .timeout: .hangFirst
        }
    }
}

/// A test observer holding the second coverage check until a place has published: two refreshes
/// issued in one turn whose checks interleave with a fetch that ends in between (D36).
///
/// The order is scripted, not left to the scheduler: the test's fetcher is gated, and the test
/// opens the gate (or, for a timeout, moves the clock) only once `events` shows the second check
/// has begun, so no place can publish before it starts; the hold then keeps that check until a
/// place has published. `spanned` confirms the interleaving ran.
///
/// The observer is synchronous (AlertsWork.Observer) and covers() runs on the cooperative pool, so
/// the hold necessarily blocks the one pool thread running the held check; the place that
/// publishes needs another pool thread meanwhile. That is why AlertsServiceTests is .serialized:
/// at most one hold blocks at a time, so the suite needs two cooperative threads whatever the core
/// count (it no longer runs six holds at once, which starved a 4-thread pool). On a one-thread
/// pool the held check would occupy the only thread the fetch needs, so the tests that hold are
/// enabled only where the pool has two threads (poolCanHold); elsewhere they are reported
/// skipped, never passed.
private final class HoldSecondCovers: Sendable {
    /// Whether the cooperative pool has the two threads a hold needs: false on a one-CPU Mac and
    /// under LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 (a one-thread pool), where no coverage check
    /// can overlap a fetch.
    static var poolCanHold: Bool {
        ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] != "1"
            && ProcessInfo.processInfo.activeProcessorCount >= 2
    }

    private struct State {
        var covers = 0
        var published = 0
        /// The second check waited, then returned only after a publication (the interleaving ran).
        var spanned = false
    }

    private let state = Mutex(State())
    private let published = DispatchSemaphore(value: 0)
    private let timedOut = Mutex(false)
    /// "covers" once per coverage check begun (a test waits for the second one).
    let events = Events()

    /// Whether the hold gave up waiting (a deadlock guard; never expected).
    var gaveUp: Bool {
        timedOut.withLock { $0 }
    }

    /// Whether the second coverage check began before any place published and ended after one:
    /// the interleaving the test is about actually happened (false for a hold that does not hold).
    var spanned: Bool {
        state.withLock { $0.spanned }
    }

    func observe(_ stage: AlertsWork.Stage) {
        switch stage {
        case .covers:
            let (second, earlier) = state.withLock { s in
                s.covers += 1
                return (s.covers == 2, s.published)
            }
            events.add("covers")
            guard second else {
                return
            }
            if published.wait(timeout: .now() + 20) == .timedOut {
                timedOut.withLock { $0 = true }
                return
            }
            state.withLock { s in
                s.spanned = earlier == 0 && s.published >= 1
            }
        case .publish:
            state.withLock { $0.published += 1 }
            published.signal()
        default:
            break
        }
    }
}

private let t0S: Int64 = 1_791_676_800  // ManualClock's default wall time, 2026-10-11T00:00:00Z
private let second: Int64 = 1_000_000
private let minute: Int64 = 60 * second

// .serialized: HoldSecondCovers blocks one cooperative thread per held check (see its comment); run
// one at a time, the holds need two pool threads in all, on any core count and under a pool hog.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AlertsServiceTests {
    private static func service(_ fake: FakeFetcher, _ clock: ManualClock) -> AlertsService {
        AlertsService(clock: clock, fetch: fake.fetch, observer: { stage in
            let name = switch stage {
            case .covers: "covers"
            case .wait: "wait"
            case .parse: "parse"
            case .match: "match"
            case .publish: "publish"
            }
            fake.events.add("stage \(name) main=\(onMainThread())")
        })
    }

    private static func feedURL(_ cc: String) throws -> String {
        try #require(WxAlertRegions.feedURL(countryCode: cc))
    }

    private static func ids(_ r: WxAlertsResult) -> Set<String> {
        Set(r.alerts.map(\.id))
    }

    /// No alert of `r` has expired or ended at `nowS`.
    private static func noneExpired(_ r: WxAlertsResult, nowS: Int64) -> Bool {
        r.alerts.allSatisfy { a in (a.expiresS.map { $0 > nowS } ?? true) && (a.endsS.map { $0 > nowS } ?? true) }
    }

    // MARK: - Routing (AC 1)

    @Test func routesEachCountryToOneSource() async throws {
        var expected: [String: WxAlert.Source] = [
            "US": .nws, "PR": .nws, "VI": .nws, "GU": .nws, "AS": .nws, "MP": .nws, "UM": .nws,
            "DE": .dwd, "NO": .metNorway, "CA": .eccc,
        ]
        for cc in WxAlertRegions.feedSlugs.keys {
            #expect(expected[cc] == nil, "\(cc) is in two routing tables")
            expected[cc] = .meteoAlarm
        }
        #expect(expected.count == 10 + 36)
        // A point inside no coordinate test: the code alone decides, in any case (ruling 6).
        for (cc, source) in expected {
            for code in [cc, cc.lowercased(), String(cc.prefix(1)) + cc.suffix(1).lowercased()] {
                #expect(AlertsService.source(countryCode: code, lat: 0.5, lon: 0.5) == source, "\(code)")
            }
            #expect(AlertsService.source(for: P.make("P", cc, 0.5, 0.5)) == source, "\(cc)")
        }

        // Through refresh: exactly one fetch per place, of its source, at that source's URL.
        let fake = FakeFetcher(), clock = ManualClock()
        let service = Self.service(fake, clock)
        let cases: [(WxPlace, WxAlert.Source, String)] = [
            (P.miami, .nws, WxPointAlerts.nwsURL(lat: P.miami.lat, lon: P.miami.lon)),
            (P.sanJuan, .nws, WxPointAlerts.nwsURL(lat: P.sanJuan.lat, lon: P.sanJuan.lon)),
            (P.berlin, .dwd, WxPointAlerts.brightSkyURL(lat: P.berlin.lat, lon: P.berlin.lon)),
            (P.oslo, .metNorway, WxPointAlerts.metNorwayURL(lat: P.oslo.lat, lon: P.oslo.lon)),
            (P.toronto, .eccc, WxECCCAlerts.url(lat: P.toronto.lat, lon: P.toronto.lon)),
            (P.zurich, .meteoAlarm, try Self.feedURL("CH")),
            (P.paris, .meteoAlarm, try Self.feedURL("FR")),
        ]
        #expect(try Self.feedURL("ch") == "https://feeds.meteoalarm.org/api/v1/warnings/feeds-switzerland")
        for (place, source, url) in cases {
            let before = fake.calls.count
            await service.refresh(place).value
            #expect(Array(fake.calls.dropFirst(before)) == [FakeFetcher.Call(source: source, url: url)], "\(place.name)")
            let r = service.result(for: place)
            #expect(r.source == source && r.state == .current && r.alerts.isEmpty, "\(place.name): \(r)")
        }
    }

    @Test func emptyCountryCodeUsesCoordinateUSTest() async throws {
        let denver = P.make("Denver", "", 39.7392, -104.9903)
        let honolulu = P.make("Honolulu", "", 21.3069, -157.8583)
        let parisNoCode = P.make("Paris", "", 48.8566, 2.3522)
        // Toronto lies inside the coarse contiguous-US box: without a code it goes to NWS (which
        // answers "out of bounds"), with "CA" to Environment Canada.
        let torontoNoCode = P.make("Toronto", "", 43.6532, -79.3832)
        #expect(WxGeo.inUSNWS(lat: denver.lat, lon: denver.lon) && WxGeo.inUSNWS(lat: honolulu.lat, lon: honolulu.lon))
        #expect(AlertsService.source(for: denver) == .nws)
        #expect(AlertsService.source(for: honolulu) == .nws)
        #expect(AlertsService.source(for: torontoNoCode) == .nws)
        #expect(AlertsService.source(for: P.toronto) == .eccc)
        #expect(AlertsService.source(for: parisNoCode) == nil)

        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: WxPointAlerts.nwsURL(lat: torontoNoCode.lat, lon: torontoNoCode.lon),
                 .reply(400, Data(#"{"detail":"Data for 43.6532,-79.3832 is out of bounds"}"#.utf8)))
        let service = Self.service(fake, clock)
        for place in [denver, honolulu, parisNoCode, torontoNoCode] {
            await service.refresh(place).value
        }
        #expect(service.result(for: torontoNoCode).state == .notCovered)
        #expect(service.result(for: torontoNoCode).source == .nws)
        // The same place identity (WxPlace.key) with the code "CA" is routed again, to ECCC.
        await service.refresh(P.toronto).value
        #expect(fake.calls == [
            FakeFetcher.Call(source: .nws, url: WxPointAlerts.nwsURL(lat: denver.lat, lon: denver.lon)),
            FakeFetcher.Call(source: .nws, url: WxPointAlerts.nwsURL(lat: honolulu.lat, lon: honolulu.lon)),
            FakeFetcher.Call(source: .nws, url: WxPointAlerts.nwsURL(lat: torontoNoCode.lat, lon: torontoNoCode.lon)),
            FakeFetcher.Call(source: .eccc, url: WxECCCAlerts.url(lat: P.toronto.lat, lon: P.toronto.lon)),
        ])
        #expect(service.result(for: denver) == WxAlertsResult(state: .current, source: .nws, alerts: [], fetchedS: t0S))
        #expect(service.result(for: honolulu).state == .current)
        #expect(service.result(for: parisNoCode) == WxAlertsResult(state: .notCovered, source: nil, alerts: [], fetchedS: nil))
        #expect(service.result(for: P.toronto) == WxAlertsResult(state: .current, source: .eccc, alerts: [], fetchedS: t0S))
    }

    @Test func uncoveredCountryIsNotCovered() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        let service = Self.service(fake, clock)
        // No source for the country (Tijuana is inside the coarse US box: the code decides).
        for place in [P.tokyo, P.sydney, P.tijuana, P.andorra] {
            #expect(AlertsService.source(for: place) == nil)
            #expect(service.result(for: place).state == .notCovered)
            await service.refresh(place).value
            #expect(service.result(for: place) == WxAlertsResult(state: .notCovered, source: nil, alerts: [], fetchedS: nil))
        }
        // A MeteoAlarm country, but outside every region its feed files (Reunion: the French
        // feed files no overseas NUTS3, ruling 5): not covered, and its feed is never downloaded.
        #expect(AlertsService.source(for: P.saintDenis) == .meteoAlarm)
        #expect(!WxAlertRegions.covers(countryCode: "FR", lat: P.saintDenis.lat, lon: P.saintDenis.lon))
        await service.refresh(P.saintDenis).value
        await service.refresh(P.saintDenis).value
        let r = service.result(for: P.saintDenis)
        #expect(r.state == .notCovered && r.source == .meteoAlarm && r.alerts.isEmpty)
        #expect(fake.calls.isEmpty)
    }

    /// Iteration 1's routing (no ASCII check), the reference every ASCII code must still match.
    private static func iteration1Source(_ countryCode: String, lat: Double, lon: Double) -> WxAlert.Source? {
        let cc = countryCode.uppercased()
        if cc.isEmpty {
            return WxGeo.inUSNWS(lat: lat, lon: lon) ? .nws : nil
        }
        if let point = WxAlert.pointSource(countryCode: cc) {
            return point
        }
        if cc == "CA" {
            return .eccc
        }
        return WxAlertRegions.feedSlug(countryCode: cc) != nil ? .meteoAlarm : nil
    }

    @Test func countryCodesAreTwoASCIILetters() {
        var expected: [String: WxAlert.Source] = [
            "US": .nws, "PR": .nws, "VI": .nws, "GU": .nws, "AS": .nws, "MP": .nws, "UM": .nws,
            "DE": .dwd, "NO": .metNorway, "CA": .eccc,
        ]
        for cc in WxAlertRegions.feedSlugs.keys {
            expected[cc] = .meteoAlarm
        }
        // All 676 codes in all four cases: the table above (nil for the other 630), as iteration 1.
        let letters = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(UnicodeScalar($0)) }
        var codes = 0, covered = 0, wrong: [String] = []
        for a in letters {
            for b in letters {
                let want = expected[a + b]
                covered += want == nil ? 0 : 1
                for code in [a + b, (a + b).lowercased(), a + b.lowercased(), a.lowercased() + b] {
                    codes += 1
                    let got = AlertsService.source(countryCode: code, lat: 0.5, lon: 0.5)
                    if got != want || got != Self.iteration1Source(code, lat: 0.5, lon: 0.5) {
                        wrong.append(code)
                    }
                }
            }
        }
        #expect(codes == 676 * 4 && covered == 46)
        #expect(wrong.isEmpty, "\(wrong)")
        // Every other ASCII string up to two characters (the empty one at a US and a non-US point)
        // and some three-letter ones route as in iteration 1: not covered, or the point decides.
        let printable = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }
        var ascii = [""] + printable + ["USA", "usa", "DEU", "CAN", "FRA", "U.S"]
        for a in printable {
            ascii += printable.map { a + $0 }
        }
        for (lat, lon) in [(0.5, 0.5), (39.7392, -104.9903)] {
            wrong = ascii.filter {
                AlertsService.source(countryCode: $0, lat: lat, lon: lon) != Self.iteration1Source($0, lat: lat, lon: lon)
            }
            #expect(wrong.isEmpty, "\(wrong)")
        }
        #expect(AlertsService.source(countryCode: "", lat: 39.7392, lon: -104.9903) == .nws)
        // Non-ASCII letters that uppercased() folds into ASCII codes are not codes: not covered,
        // and never the coordinate fallback (iteration 1 routed them to NWS or MeteoAlarm).
        let folded: [(code: String, iteration1: WxAlert.Source)] = [
            ("u\u{17F}", .nws), ("U\u{17F}", .nws), ("\u{131}t", .meteoAlarm), ("\u{FB01}", .meteoAlarm),
        ]
        for (code, iteration1) in folded {
            let scalars = code.unicodeScalars.map { String($0.value, radix: 16) }
            #expect(Self.iteration1Source(code, lat: 38.5, lon: -98.5) == iteration1, "\(scalars)")
            #expect(AlertsService.source(countryCode: code, lat: 38.5, lon: -98.5) == nil, "\(scalars)")
        }
        for code in ["\u{FF35}\u{FF33}", "D\u{C9}", "\u{DC}S", "U\u{301}S"] {
            #expect(AlertsService.source(countryCode: code, lat: 38.5, lon: -98.5) == nil, "\(code)")
        }
    }

    // MARK: - Sharing and cadence (AC 2)

    @Test func sameCountryRequestsShareOneFetch() async throws {
        let ch = try Self.feedURL("CH"), fr = try Self.feedURL("FR")
        #expect(WxAlertRegions.contains(type: "NUTS3", code: "FR101", lat: P.paris.lat, lon: P.paris.lon))
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .gate(200, Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])))
        fake.set(url: fr, .gate(200, Bodies.feed([Bodies.warning("fr1", expires: Bodies.plus6h, geocode: ("NUTS3", "FR101"))])))
        let service = Self.service(fake, clock)
        let places = [P.zurich, P.bern, P.geneva, P.paris]
        let tasks = places.map { service.refresh($0) }
        // A repeated request while one is running joins it.
        #expect(service.refresh(P.zurich) == tasks[0])
        // All four places wait on a fetch in flight before any answer arrives.
        await fake.events.wait("stage wait", count: 4)
        await fake.events.wait("fetch meteoAlarm", count: 2)
        fake.openGate()
        for task in tasks {
            await task.value
        }
        #expect(fake.count(url: ch) == 1)
        #expect(fake.count(url: fr) == 1)
        #expect(fake.calls.count == 2)
        // Each place gets its own match of the one shared feed.
        #expect(Self.ids(service.result(for: P.zurich)) == ["meteoAlarm:ch1"])
        #expect(Self.ids(service.result(for: P.paris)) == ["meteoAlarm:fr1"])
        for place in places {
            #expect(service.result(for: place).state == .current, "\(place.name)")
        }
        #expect(service.result(for: P.bern).alerts.isEmpty && service.result(for: P.geneva).alerts.isEmpty)
        // Repeated refreshes of every place reuse the answer.
        for place in places {
            await service.refresh(place).value
        }
        #expect(fake.calls.count == 2)
    }

    // A failing fetch is shared too, by a refresh issued in the same turn whose coverage check
    // ends only after the failed answer has arrived and been published (D36, DECISIONS #38).
    // (Formerly the second half of sameCountryRequestsShareOneFetch; on its own so that only the
    // held part needs the two-thread pool.)
    @Test(.enabled(if: HoldSecondCovers.poolCanHold, "a held coverage check needs two cooperative threads"))
    func sameTurnFailingFetchShared() async throws {
        let ch = try Self.feedURL("CH")
        let fake2 = FakeFetcher(), hold = HoldSecondCovers()
        fake2.set(url: ch, .gate(503, Data("busy".utf8)))
        let service2 = AlertsService(clock: ManualClock(), fetch: fake2.fetch, observer: { hold.observe($0) })
        let zurich = service2.refresh(P.zurich), bern = service2.refresh(P.bern)
        // The fetch answers only once the second check has begun (and is held): no place has
        // published before that check starts.
        await hold.events.wait("covers", count: 2)
        fake2.openGate()
        await zurich.value
        await bern.value
        #expect(!hold.gaveUp)
        #expect(hold.spanned)  // the second check really ended after the failed answer was published
        #expect(fake2.count(url: ch) == 1)
        #expect(service2.result(for: P.zurich).state == .unavailable && service2.result(for: P.bern).state == .unavailable)
    }

    @Test func meteoAlarmAtMostEvery30Minutes() async throws {
        let ch = try Self.feedURL("CH")
        let feed = Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .reply(200, feed))
        let service = Self.service(fake, clock)
        await service.refresh(P.zurich).value
        #expect(fake.count(url: ch) == 1)
        await clock.advance(by: 10 * minute)
        await service.refresh(P.zurich).value
        await service.refresh(P.bern).value
        #expect(fake.count(url: ch) == 1)
        #expect(service.result(for: P.bern).fetchedS == t0S)
        await clock.advance(by: 19 * minute + 59 * second)  // 29:59
        await service.refresh(P.zurich).value
        await service.refresh(P.geneva).value
        #expect(fake.count(url: ch) == 1)
        await clock.advance(by: second)  // 30:00
        await service.refresh(P.zurich).value
        await service.refresh(P.bern).value
        #expect(fake.count(url: ch) == 2)
        #expect(service.result(for: P.zurich).fetchedS == t0S + 1800)
        #expect(service.result(for: P.bern).fetchedS == t0S + 1800)

        // A failed fetch does not start the window (ruling 2) but is held for 120 s of its age
        // (failedFeedHoldUS): the other places of the country refreshed within that time cost no
        // download (DECISIONS #38).
        // The next round tries again, and the first good answer is then reused for 30 minutes.
        let fake2 = FakeFetcher(), clock2 = ManualClock()
        fake2.set(url: ch, .fail)
        let service2 = Self.service(fake2, clock2)
        await service2.refresh(P.zurich).value
        #expect(service2.result(for: P.zurich).state == .unavailable)
        for place in [P.bern, P.geneva] {
            await clock2.advance(by: 2 * second)
            await service2.refresh(place).value
            #expect(service2.result(for: place) == WxAlertsResult(state: .unavailable, source: .meteoAlarm, alerts: [],
                                                                    fetchedS: t0S))
        }
        #expect(fake2.count(url: ch) == 1)
        fake2.set(url: ch, .reply(200, feed))
        await clock2.advance(by: 10 * minute)
        await service2.refresh(P.zurich).value
        #expect(fake2.count(url: ch) == 2)
        #expect(service2.result(for: P.zurich).state == .current)
        await clock2.advance(by: 29 * minute)
        await service2.refresh(P.zurich).value
        await service2.refresh(P.bern).value
        #expect(fake2.count(url: ch) == 2)
    }

    @Test func pointResultsReusedFor5Minutes() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        let service = Self.service(fake, clock)
        await service.refresh(P.miami).value
        #expect(fake.count(.nws) == 1)
        await clock.advance(by: 4 * minute + 59 * second)
        await service.refresh(P.miami).value
        // Another place at the same point shares the answer.
        let twin = P.make("Miami (home)", "US", P.miami.lat, P.miami.lon)
        await service.refresh(twin).value
        #expect(fake.count(.nws) == 1)
        #expect(service.result(for: P.miami) == WxAlertsResult(state: .current, source: .nws, alerts: [], fetchedS: t0S))
        #expect(service.result(for: twin).fetchedS == t0S)
        // A moved place is asked again at once, never given the old point's answer (ruling 7).
        await service.refresh(P.miamiBeach).value
        #expect(fake.count(.nws) == 2)
        #expect(fake.calls.last?.url == WxPointAlerts.nwsURL(lat: P.miamiBeach.lat, lon: P.miamiBeach.lon))
        #expect(service.result(for: P.miamiBeach).fetchedS == t0S + 299)
        await clock.advance(by: second)  // 5:00
        await service.refresh(P.miami).value
        #expect(fake.count(.nws) == 3)
        #expect(service.result(for: P.miami).fetchedS == t0S + 300)

        // Only a usable answer is reused: after a failure the next refresh asks again (ruling 2).
        fake.set(.dwd, .fail)
        await service.refresh(P.berlin).value
        #expect(service.result(for: P.berlin).state == .unavailable)
        fake.set(.dwd, .reply(200, Bodies.empty(.dwd)))
        await service.refresh(P.berlin).value
        #expect(fake.count(.dwd) == 2)
        #expect(service.result(for: P.berlin).state == .current)
        await clock.advance(by: 4 * minute)
        await service.refresh(P.berlin).value
        #expect(fake.count(.dwd) == 2)
    }

    @Test func noFetchWithoutRefreshCall() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        let service = Self.service(fake, clock)
        let places = [P.miami, P.berlin, P.oslo, P.toronto, P.zurich, P.paris]
        for place in places {
            #expect(service.result(for: place).state == .notFetched, "\(place.name)")
        }
        await clock.advance(by: 180 * minute)
        for place in places {
            #expect(service.result(for: place).state == .notFetched, "\(place.name)")
        }
        #expect(fake.calls.isEmpty)
        await service.refresh(P.miami).value
        #expect(fake.calls.count == 1)
        // Time passing and results being read never fetch: the service has no timer.
        await clock.advance(by: 180 * minute)
        for _ in 0..<10 {
            _ = service.result(for: P.miami)
        }
        #expect(fake.calls.count == 1)
        #expect(clock.pendingSleeperCount == 0)
        #expect(service.result(for: P.miami).state == .stale)
    }

    // MARK: - Failed feeds (DECISIONS #38)

    /// Refreshes `places` one after another, `gapUS` apart, as their forecast requests complete
    /// in one refresh round; the first one's hanging fetch (`.timeout`) ends at the deadline.
    private static func round(_ places: [WxPlace], _ service: AlertsService, _ clock: ManualClock,
                              _ failure: AlertsFeedFailure, gapUS: Int64 = 2 * second) async {
        for (i, place) in places.enumerated() {
            if i > 0 {
                await clock.advance(by: gapUS)
            }
            let task = service.refresh(place)
            if i == 0, failure == .timeout {
                await clock.waitForSleepers(1)
                await clock.advance(by: AlertsService.fetchTimeoutUS)
            }
            await task.value
        }
    }

    @Test(arguments: AlertsFeedFailure.allCases)
    func failedFeedFetchedOncePerRound(_ failure: AlertsFeedFailure) async throws {
        let ch = try Self.feedURL("CH")
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, failure.behavior)
        let service = Self.service(fake, clock)
        let places = [P.zurich, P.bern, P.geneva, P.lugano]
        // One round: the first place downloads the feed, the other three take its failed answer.
        await Self.round(places, service, clock, failure)
        let failedS = t0S + (failure == .timeout ? AlertsService.fetchTimeoutUS / second : 0)
        #expect(fake.count(url: ch) == 1)
        for place in places {
            #expect(service.result(for: place) == WxAlertsResult(state: .unavailable, source: .meteoAlarm, alerts: [],
                                                                  fetchedS: failedS), "\(place.name)")
        }
        // Held until it is failedFeedHoldUS old (the service's age rule), then asked again once by
        // the next round.
        let arrivedUS = (failedS - t0S) * second
        await clock.advance(by: arrivedUS + AlertsService.failedFeedHoldUS - 1 - clock.monotonicMicroseconds)
        await service.refresh(P.basel).value
        #expect(fake.count(url: ch) == 1)
        #expect(service.result(for: P.basel).fetchedS == failedS)
        await clock.advance(by: 1)
        await Self.round(places + [P.basel], service, clock, .thrown)
        #expect(fake.count(url: ch) == 2)
        for place in places + [P.basel] {
            let r = service.result(for: place)
            #expect(r.state == .unavailable && r.fetchedS == failedS + 120, "\(place.name): \(r)")
        }
        #expect(AlertsService.failedFeedHoldUS == RefreshScheduler.freshUS)
        fake.releaseHung()
    }

    @Test(.enabled(if: HoldSecondCovers.poolCanHold, "a held coverage check needs two cooperative threads"),
          arguments: AlertsFeedFailure.allCases)
    func sameTurnRefreshesShareFailedFeed(_ failure: AlertsFeedFailure) async throws {
        let ch = try Self.feedURL("CH")
        let fake = FakeFetcher(), clock = ManualClock(), hold = HoldSecondCovers()
        fake.set(url: ch, .gated(failure.behavior))
        let service = AlertsService(clock: clock, fetch: fake.fetch, observer: { hold.observe($0) })
        // Issued in one turn, before any answer. The fetch fails only once the second coverage
        // check has begun (the gate opens, or the deadline passes, after it), and that check is
        // held until the first place has published its failed answer.
        let zurich = service.refresh(P.zurich), bern = service.refresh(P.bern)
        await hold.events.wait("covers", count: 2)
        fake.openGate()
        if failure == .timeout {
            await clock.waitForSleepers(1)
            await clock.advance(by: AlertsService.fetchTimeoutUS)
        }
        await zurich.value
        await bern.value
        #expect(!hold.gaveUp)
        #expect(hold.spanned)  // the second check really ended after the failed answer was published
        #expect(fake.count(url: ch) == 1)
        for place in [P.zurich, P.bern] {
            #expect(service.result(for: place).state == .unavailable, "\(place.name)")
        }
        #expect(service.result(for: P.zurich).fetchedS == service.result(for: P.bern).fetchedS)
        fake.releaseHung()
    }

    @Test func cancelAllEndedFeedIsNotHeld() async throws {
        let ch = try Self.feedURL("CH")
        let feed = Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .gate(503, Data("busy".utf8)))
        let service = Self.service(fake, clock)
        let zurich = service.refresh(P.zurich)
        await fake.events.wait("fetch meteoAlarm", count: 1)
        service.cancelAll()
        await zurich.value
        #expect(service.result(for: P.zurich).state == .unavailable)
        // The same instant: an attempt ended by cancelAll() is no failed answer to hold, so the
        // next refresh downloads the feed.
        fake.set(url: ch, .reply(200, feed))
        await service.refresh(P.zurich).value
        await service.refresh(P.bern).value
        #expect(fake.count(url: ch) == 2)
        #expect(Self.ids(service.result(for: P.zurich)) == ["meteoAlarm:ch1"])
        #expect(service.result(for: P.bern).state == .current)
        fake.openGate()
    }

    // The hold is measured by the service's age rule (the larger of the wall-clock and the
    // monotonic time since the failed answer): a wall clock set back does not lengthen it, and a
    // system sleep (wall time moving alone) ends it (U48 iteration-2 handoff, CF4).
    @Test func failedFeedHoldUsesServiceAgeRule() async throws {
        let ch = try Self.feedURL("CH")
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .fail)
        let service = Self.service(fake, clock)
        await service.refresh(P.zurich).value
        #expect(fake.count(url: ch) == 1)
        // Wall clock set back 10 minutes during the hold: the monotonic age still ends it at 120 s.
        clock.advanceWall(by: -10 * minute)
        await clock.advance(by: AlertsService.failedFeedHoldUS - 1)
        await service.refresh(P.bern).value
        #expect(fake.count(url: ch) == 1)  // 119.999999 s of monotonic age: still held
        await clock.advance(by: 1)
        await service.refresh(P.geneva).value
        #expect(fake.count(url: ch) == 2)  // 120 s of monotonic age (wall age -480 s): asked again

        // Wall time moving alone (a system sleep): 120 s of wall age ends the hold although no
        // monotonic time passed.
        await clock.advance(by: 10 * second)
        let restarted = fake.count(url: ch)
        clock.advanceWall(by: AlertsService.failedFeedHoldUS - 10 * second - 1)
        await service.refresh(P.lugano).value
        #expect(fake.count(url: ch) == restarted)  // 119.999999 s of wall age: still held
        clock.advanceWall(by: 1)
        await service.refresh(P.basel).value
        #expect(fake.count(url: ch) == restarted + 1)
    }

    @Test func recoveredFeedReusedFor30Minutes() async throws {
        let ch = try Self.feedURL("CH")
        let feed = Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .reply(503, Data("busy".utf8)))
        let service = Self.service(fake, clock)
        let places = [P.zurich, P.bern, P.geneva]
        await Self.round(places, service, clock, .status503)
        #expect(fake.count(url: ch) == 1)
        // The next round gets a good answer, which keeps the 30-minute window (not the hold's).
        fake.set(url: ch, .reply(200, feed))
        await clock.advance(by: AlertsService.failedFeedHoldUS - 4 * second)
        let goodS = clock.wallSeconds
        await Self.round(places, service, clock, .status503)
        #expect(fake.count(url: ch) == 2)
        #expect(places.allSatisfy { service.result(for: $0).state == .current && service.result(for: $0).fetchedS == goodS })
        await clock.advance(by: AlertsService.feedWindowUS - 4 * second - 1)  // 29:59.999999 old
        await Self.round(places + [P.lugano], service, clock, .status503, gapUS: 0)
        #expect(fake.count(url: ch) == 2)
        #expect(Self.ids(service.result(for: P.zurich)) == ["meteoAlarm:ch1"])
        await clock.advance(by: 1)  // 30:00
        await Self.round(places, service, clock, .status503)
        #expect(fake.count(url: ch) == 3)
        #expect(service.result(for: P.bern).fetchedS == goodS + 1800)
    }

    // MARK: - Expiry and staleness (AC 3)

    @Test func expiredAlertsExcluded() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(.nws, .reply(200, Bodies.nws([
            ("past", Bodies.past, nil), ("soon", Bodies.plus3m, nil),
            ("ending", Bodies.plus6h, Bodies.plus1m), ("later", Bodies.plus6h, nil),
        ])))
        let service = Self.service(fake, clock)
        await service.refresh(P.miami).value
        var r = service.result(for: P.miami)
        #expect(r.state == .current)
        #expect(Self.ids(r) == ["nws:soon", "nws:ending", "nws:later"])
        await clock.advance(by: minute)  // the event of "ending" is over
        r = service.result(for: P.miami)
        #expect(Self.ids(r) == ["nws:soon", "nws:later"])
        await clock.advance(by: 2 * minute)  // "soon" expires exactly now: expired
        r = service.result(for: P.miami)
        #expect(r.state == .current)
        #expect(Self.ids(r) == ["nws:later"])
        #expect(Self.noneExpired(r, nowS: clock.wallSeconds))

        // A feed: the expired warning never shows, the 20-minute one only until it expires.
        let ch = try Self.feedURL("CH")
        fake.set(url: ch, .reply(200, Bodies.feed([
            Bodies.warning("w-past", expires: Bodies.past, polygon: Bodies.zurichSquare),
            Bodies.warning("w-20m", expires: Bodies.plus20m, polygon: Bodies.zurichSquare),
            Bodies.warning("w-6h", expires: Bodies.plus6h, polygon: Bodies.zurichSquare),
        ])))
        await service.refresh(P.zurich).value  // at T0 + 3 min
        r = service.result(for: P.zurich)
        #expect(Self.ids(r) == ["meteoAlarm:w-20m", "meteoAlarm:w-6h"])
        await clock.advance(by: 17 * minute)  // T0 + 20 min
        r = service.result(for: P.zurich)
        #expect(r.state == .current)
        #expect(Self.ids(r) == ["meteoAlarm:w-6h"])
        #expect(Self.noneExpired(r, nowS: clock.wallSeconds))
    }

    @Test func oldResultIsStaleNotCurrent() async throws {
        let body = Bodies.nws([("later", Bodies.plus6h, nil)])
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(.nws, .reply(200, body))
        let service = Self.service(fake, clock)
        // A point answer: current until the forecast period, stale from it (ruling 3).
        await service.refresh(P.miami).value
        await clock.advance(by: AlertsService.pointWindowUS - 1)
        #expect(service.result(for: P.miami).state == .current)
        await clock.advance(by: 1)
        var r = service.result(for: P.miami)
        #expect(r.state == .stale)
        #expect(Self.ids(r) == ["nws:later"] && r.fetchedS == t0S)
        await service.refresh(P.miami).value
        #expect(service.result(for: P.miami).state == .current)

        // A feed answer: stale from 30 minutes.
        let ch = try Self.feedURL("CH")
        let fake2 = FakeFetcher(), clock2 = ManualClock()
        fake2.set(url: ch, .reply(200, Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])))
        let service2 = Self.service(fake2, clock2)
        await service2.refresh(P.zurich).value
        await clock2.advance(by: AlertsService.feedWindowUS - 1)
        #expect(service2.result(for: P.zurich).state == .current)
        await clock2.advance(by: 1)
        r = service2.result(for: P.zurich)
        #expect(r.state == .stale && Self.ids(r) == ["meteoAlarm:ch1"])

        // A system sleep (wall time moves, monotonic time does not) makes an answer stale
        // (ruling 4); a wall clock set back does not make it younger.
        let clock3 = ManualClock()
        let service3 = Self.service(fake, clock3)
        await service3.refresh(P.miami).value
        clock3.advanceWall(by: 120 * minute)
        #expect(service3.result(for: P.miami).state == .stale)
        let clock4 = ManualClock()
        let service4 = Self.service(fake, clock4)
        await service4.refresh(P.miami).value
        clock4.advanceWall(by: -120 * minute)
        #expect(service4.result(for: P.miami).state == .current)
        await clock4.advance(by: AlertsService.pointWindowUS)
        #expect(service4.result(for: P.miami).state == .stale)
    }

    @Test func resultStatesAreDistinct() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(.dwd, .fail)
        // A 200 that is not a readable answer is unavailable, never "no alerts".
        fake.set(url: WxPointAlerts.nwsURL(lat: P.sanJuan.lat, lon: P.sanJuan.lon), .reply(200, Data("<html>".utf8)))
        let service = Self.service(fake, clock)
        await service.refresh(P.oslo).value
        await clock.advance(by: AlertsService.pointWindowUS)
        await service.refresh(P.miami).value
        await service.refresh(P.berlin).value
        await service.refresh(P.sanJuan).value
        let results = [P.oslo, P.miami, P.berlin, P.toronto, P.tokyo].map { service.result(for: $0) }
        #expect(results.map(\.state) == [.stale, .current, .unavailable, .notFetched, .notCovered])
        #expect(Set(results.map(\.state)) == Set(WxAlertsResult.State.allCases))
        #expect(WxAlertsResult.State.allCases.count == 5)
        #expect(service.result(for: P.sanJuan) == WxAlertsResult(state: .unavailable, source: .nws, alerts: [],
                                                                  fetchedS: t0S + 600))
        #expect(results.map(\.fetchedS) == [t0S, t0S + 600, t0S + 600, nil, nil])
    }

    // MARK: - Failure isolation and isolation (AC 4)

    @Test func fetcherFailureIsUnavailable() async throws {
        let ch = try Self.feedURL("CH"), fr = try Self.feedURL("FR")
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(.nws, .fail)
        fake.set(.dwd, .reply(500, Data("{}".utf8)))
        // Over the caps though valid JSON: the cap, not the parser, decides.
        fake.set(.metNorway, .reply(200, Bodies.padded(#"{"features":[]}"#, to: AlertsService.pointMaxBytes + 1)))
        fake.set(url: ch, .gate(200, Bodies.padded(#"{"warnings":[]}"#, to: AlertsService.feedMaxBytes + 1)))
        fake.set(url: fr, .reply(200, Data("not a feed".utf8)))
        let service = Self.service(fake, clock)
        let failing = [P.miami, P.berlin, P.oslo, P.zurich, P.bern, P.paris]
        let tasks = (failing + [P.toronto]).map { service.refresh($0) }
        await fake.events.wait("stage wait", count: 7)  // both Swiss places wait on the one feed fetch
        fake.openGate()
        for task in tasks {
            await task.value
        }
        for place in failing {
            let r = service.result(for: place)
            #expect(r.state == .unavailable && r.alerts.isEmpty, "\(place.name): \(r)")
        }
        // The other places are unaffected, and one feed fetch served both Swiss places.
        #expect(service.result(for: P.toronto).state == .current)
        #expect(fake.count(url: ch) == 1)
        // At the cap the same body is read.
        fake.set(.metNorway, .reply(200, Bodies.padded(#"{"features":[]}"#, to: AlertsService.pointMaxBytes)))
        await service.refresh(P.oslo).value
        #expect(service.result(for: P.oslo).state == .current)

        // A failed refetch keeps a previous alert set still within its window (ruling 1), and is
        // unavailable once that set is out of its window.
        fake.set(.nws, .reply(200, Bodies.nws([("later", Bodies.plus6h, nil)])))
        await service.refresh(P.miami).value
        fake.set(.nws, .fail)
        await clock.advance(by: AlertsService.pointReuseUS)
        await service.refresh(P.miami).value
        var r = service.result(for: P.miami)
        #expect(r.state == .current && Self.ids(r) == ["nws:later"] && r.fetchedS == t0S)
        await clock.advance(by: AlertsService.pointWindowUS - AlertsService.pointReuseUS)
        #expect(service.result(for: P.miami).state == .stale)
        await service.refresh(P.miami).value
        r = service.result(for: P.miami)
        #expect(r.state == .unavailable && r.alerts.isEmpty)
        #expect(fake.count(.nws) == 4)
    }

    @Test func fetcherHangDoesNotBlockCaller() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(.nws, .hang)
        let service = Self.service(fake, clock)
        let hung = service.refresh(P.miami)  // returns at once
        #expect(service.result(for: P.miami).state == .notFetched)
        await fake.events.wait("fetch nws", count: 1)
        // While the fetch hangs, the main actor is free: another place refreshes and publishes.
        await service.refresh(P.berlin).value
        #expect(service.result(for: P.berlin).state == .current)
        #expect(service.result(for: P.miami).state == .notFetched)
        // The service's own deadline ends the wait though the fetcher ignores cancellation.
        await clock.waitForSleepers(1)
        await clock.advance(by: AlertsService.fetchTimeoutUS)
        await hung.value
        #expect(service.result(for: P.miami) == WxAlertsResult(state: .unavailable, source: .nws, alerts: [],
                                                                fetchedS: t0S + 120))
        fake.releaseHung()
    }

    @Test func cancellationIsUnavailable() async throws {
        let fake = FakeFetcher(), clock = ManualClock()
        // The fetcher itself reports a cancellation.
        fake.set(.dwd, .cancel)
        let service = Self.service(fake, clock)
        await service.refresh(P.berlin).value
        #expect(service.result(for: P.berlin).state == .unavailable)

        // The refresh is cancelled while its fetch hangs: it ends at once, unavailable.
        fake.set(.nws, .hang)
        let task = service.refresh(P.miami)
        await fake.events.wait("fetch nws", count: 1)
        task.cancel()
        await task.value
        #expect(service.result(for: P.miami).state == .unavailable)

        // Shutdown while two places share a feed fetch: both unavailable; nothing cancelled is
        // reused, so a later refresh fetches again.
        let ch = try Self.feedURL("CH")
        fake.set(url: ch, .gate(200, Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])))
        let zurich = service.refresh(P.zurich), bern = service.refresh(P.bern)
        await fake.events.wait("stage wait", count: 4)  // Berlin's, Miami's, then the two Swiss places'
        await fake.events.wait("fetch meteoAlarm", count: 1)
        service.cancelAll()
        await zurich.value
        await bern.value
        #expect(service.result(for: P.zurich).state == .unavailable)
        #expect(service.result(for: P.bern).state == .unavailable)
        fake.openGate()
        await service.refresh(P.zurich).value
        #expect(fake.count(url: ch) == 2)
        #expect(Self.ids(service.result(for: P.zurich)) == ["meteoAlarm:ch1"])
        // A cancelled refetch keeps an alert set still within its window (ruling 1).
        await service.refresh(P.oslo).value
        fake.set(.metNorway, .hang)
        await clock.advance(by: AlertsService.pointReuseUS)
        let refetch = service.refresh(P.oslo)
        await fake.events.wait("fetch metNorway", count: 2)
        refetch.cancel()
        await refetch.value
        #expect(service.result(for: P.oslo) == WxAlertsResult(state: .current, source: .metNorway, alerts: [],
                                                               fetchedS: t0S))
        fake.releaseHung()
    }

    @Test func workRunsOffMainActor() async throws {
        let ch = try Self.feedURL("CH"), fr = try Self.feedURL("FR")
        let fake = FakeFetcher(), clock = ManualClock()
        fake.set(url: ch, .reply(200, Bodies.feed([Bodies.warning("ch1", expires: Bodies.plus6h, polygon: Bodies.zurichSquare)])))
        fake.set(url: fr, .reply(200, Bodies.feed([Bodies.warning("fr1", expires: Bodies.plus6h, geocode: ("NUTS3", "FR101"))])))
        fake.set(.nws, .reply(200, Bodies.nws([("later", Bodies.plus6h, nil)])))
        let service = Self.service(fake, clock)
        let places = [P.zurich, P.paris, P.miami, P.berlin, P.oslo, P.toronto]
        let tasks = places.map { service.refresh($0) }
        for task in tasks {
            await task.value
        }
        let e = fake.events
        // Transport, decoding and parsing, the region table and matching: never on the main actor.
        #expect(e.count("fetch") == 6 && e.count("fetch meteoAlarm main=false") == 2)
        #expect(e.count("stage parse main=false") == 6 && e.count("stage parse main=true") == 0)
        #expect(e.count("stage covers main=false") == 2 && e.count("stage covers main=true") == 0)
        #expect(e.count("stage match main=false") == 2 && e.count("stage match main=true") == 0)
        #expect(WxAlert.Source.allCases.allSatisfy { e.count("fetch \($0.rawValue) main=true") == 0 })
        // Only the result is published on it.
        #expect(e.count("stage publish main=true") == 6 && e.count("stage publish main=false") == 0)
        #expect(Self.ids(service.result(for: P.zurich)) == ["meteoAlarm:ch1"])
        #expect(Self.ids(service.result(for: P.paris)) == ["meteoAlarm:fr1"])
        #expect(Self.ids(service.result(for: P.miami)) == ["nws:later"])
    }
}
