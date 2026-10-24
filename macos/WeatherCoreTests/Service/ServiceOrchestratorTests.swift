// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ServiceOrchestratorTests.swift - port of the orchestration cases of
// src/service/test-service.c (refresh fan-out, deadline, cancellation,
// statuses, the blend call, dispose and re-entrancy, search) and of
// src/service/test-service-production.c (the real 30 s deadline) against
// ServiceOrchestrator. Every test names its C case (the g_test_add path) and
// cites the C lines its expected literals come from.
//
// As in C, time is real: the deadline paths run with a shortened deadline
// (the internal `testDeadlineMs` seam, wx-service-testing.h) and assert real
// elapsed bounds; the production case waits the real 30 s. Providers are the
// shared fakes (Support/FakeProvider.swift, wx-fake-provider.c) and the
// scripted ScriptedProvider / ScriptedGeocoder below (TestProv / TestGeo,
// test-service.c:150-500), which can ignore cancellation, hold their answer
// until released, call hooks and fail with any error.
//
// Not representable in Swift (listed with reasons in the U26 debrief): hand-
// built invalid places, NULL results / members / hits, results that come with
// an error, WX_ERROR codes outside the enum, GObject criticals and ref counts,
// GMainContext selection, and the C callback's "never inside the call".

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

@MainActor
@Suite(.serialized)
struct ServiceOrchestratorTests {

    // MARK: - Scripted fakes (TestProv / TestGeo)

    /// TestProv (test-service.c:150-410): a scripted provider that can misbehave.
    final class ScriptedProvider: WxProvider {
        enum Mode: Sendable {
            /// TP_ANSWER: answers after the delay, IGNORING cancellation.
            case answer(delayMs: UInt32)
            /// TP_HOLD: keeps the fetch until `release()`, ignoring cancellation.
            case hold
        }

        struct State {
            var id: String
            var name: String
            var attribution = "Test data"
            var url = "https://example.invalid/"
            var covers = true
            var coversCalls = 0
            var fetches = 0
            var mode = Mode.answer(delayMs: 0)
            var members: [WxMember] = []
            var failure: (any Error)?
            var seenKey: String?
            var sawCancellation = false
            var held: [CheckedContinuation<Void, Never>] = []
            var onCovers: (@MainActor @Sendable (ScriptedProvider) -> Void)?
            var onFetch: (@Sendable (ScriptedProvider) -> Void)?
        }

        let state: Mutex<State>

        /// test_prov_new: name "Test <id>", attribution "Test data", URL
        /// "https://example.invalid/" (test-service.c:355-364).
        init(_ id: String) {
            state = Mutex(State(id: id, name: "Test " + id))
        }

        var id: String { state.withLock { $0.id } }
        var name: String { state.withLock { $0.name } }
        var attribution: String { state.withLock { $0.attribution } }
        var attributionURL: String { state.withLock { $0.url } }

        var coversCalls: Int { state.withLock { $0.coversCalls } }
        var fetches: Int { state.withLock { $0.fetches } }
        var heldCount: Int { state.withLock { $0.held.count } }
        var sawCancellation: Bool { state.withLock { $0.sawCancellation } }
        var seenKey: String? { state.withLock { $0.seenKey } }

        func set(_ change: (inout State) -> Void) {
            state.withLock { change(&$0) }
        }

        func addMember(_ member: WxMember) {
            state.withLock { $0.members.append(member) }
        }

        /// tp_covers: counts, runs the hook (on the main actor, where the
        /// registry calls it), answers the scripted flag.
        func covers(_ place: WxPlace) -> Bool {
            let hook = state.withLock { s -> (@MainActor @Sendable (ScriptedProvider) -> Void)? in
                s.coversCalls += 1
                return s.onCovers
            }
            if let hook {
                MainActor.assumeIsolated { hook(self) }
            }
            return state.withLock { $0.covers }
        }

        /// tp_fetch_async / tp_fetch_finish.
        func fetch(_ place: WxPlace) async throws -> WxSourceResult {
            let (mode, hook) = state.withLock { s in
                s.fetches += 1
                s.seenKey = place.key
                return (s.mode, s.onFetch)
            }
            hook?(self)
            await withTaskCancellationHandler {
                switch mode {
                case .answer(let delayMs):
                    if delayMs > 0 {
                        // g_timeout_add: the delay ignores the cancellation.
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) {
                                c.resume()
                            }
                        }
                    }
                case .hold:
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        state.withLock { $0.held.append(c) }
                    }
                }
            } onCancel: {
                state.withLock { $0.sawCancellation = true }
            }
            return try deliver()
        }

        /// test_prov_release: delivers every held fetch, in start order.
        func release() {
            let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                let held = s.held
                s.held = []
                return held
            }
            for c in held {
                c.resume()
            }
        }

        /// tp_deliver (TPR_MEMBERS): the scripted failure, or a result of the
        /// provider's id ("test-hostile" when that id is not valid) holding
        /// the members.
        private func deliver() throws -> WxSourceResult {
            let (id, members, failure) = state.withLock { ($0.id, $0.members, $0.failure) }
            if let failure {
                throw failure
            }
            var result: WxSourceResult
            if let valid = try? WxSourceResult(providerID: id) {
                result = valid
            } else {
                result = try WxSourceResult(providerID: "test-hostile")  // a hostile id: any valid one will do
            }
            result.members = members
            return result
        }
    }

    /// TestGeo (test-service.c:400-500): a scripted geocoder that can misbehave.
    final class ScriptedGeocoder: WxGeocoder {
        struct State {
            var hits: [WxPlace] = []
            var failure: (any Error)?
            var searches = 0
            var delayMs: UInt32 = 0
            var lastText: [UInt8]?
            var onSearch: (@MainActor @Sendable () -> Void)?
            /// Cancels the calling task right before answering (the cancellation
            /// lands after the geocoder has its answer, before search returns).
            var cancelCallerBeforeAnswer = false
        }

        let state = Mutex(State())

        var searches: Int { state.withLock { $0.searches } }
        var lastText: [UInt8]? { state.withLock { $0.lastText } }

        func set(_ change: (inout State) -> Void) {
            state.withLock { change(&$0) }
        }

        func search(textBytes: [UInt8]) async throws -> [WxPlace] {
            let (hook, delayMs) = state.withLock { s in
                s.searches += 1
                s.lastText = textBytes
                return (s.onSearch, s.delayMs)
            }
            if let hook {
                await hook()
            }
            if delayMs > 0 {
                // g_timeout_add without a cancellable: the delay ignores cancellation.
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(delayMs))) { c.resume() }
                }
            }
            let (hits, failure, cancelCaller) = state.withLock { ($0.hits, $0.failure, $0.cancelCallerBeforeAnswer) }
            if let failure {
                throw failure
            }
            if cancelCaller {
                withUnsafeCurrentTask { $0?.cancel() }  // the geocoder runs in the caller's task
            }
            return hits
        }
    }

    /// A Sendable lock box that escaping closures can capture (a Mutex is
    /// noncopyable and cannot be captured by them).
    final class Locked<Value: Sendable>: Sendable {
        private let mutex: Mutex<Value>
        init(_ value: Value) { mutex = Mutex(value) }
        var value: Value { mutex.withLock { $0 } }
        func set(_ value: Value) { mutex.withLock { $0 = value } }
    }

    /// The outcome of an async throwing call as a value.
    static func capture<T: Sendable>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// "fake-%02u" (test-service.c:2603).
    static func twoDigits(_ prefix: String, _ i: Int) -> String {
        prefix + (i < 10 ? "0" : "") + String(i)
    }

    /// "m%03u" (test-service.c:2773).
    static func model(_ i: Int) -> String {
        "m" + String(repeating: "0", count: max(0, 3 - String(i).count)) + String(i)
    }

    /// An error outside the WxError domain (a GLib G_FILE_ERROR / G_IO_ERROR
    /// in C): its text is its localizedDescription.
    struct ForeignError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // MARK: - Rig and outcomes

    /// Rig (test-service.c:505-590): a registry, a service and the fakes.
    @MainActor
    final class Rig {
        let registry = WxRegistry()
        let service: ServiceOrchestrator
        var fakes: [FakeProvider] = []
        var members: [WxMember] = []  // the member of each fake, same order

        init(deadlineMs: UInt32 = 0) {
            service = ServiceOrchestrator(registry: registry)
            service.testDeadlineMs = deadlineMs  // 0: WX_SERVICE_DEADLINE_MS (run_test, :4327-4333)
        }

        /// rig_add_member.
        @discardableResult
        func add(_ id: String, member: WxMember) throws -> FakeProvider {
            let fake = FakeProvider(id: id)
            fake.addMember(member)
            try registry.addProvider(fake)
            fakes.append(fake)
            members.append(member)
            return fake
        }

        /// rig_add: one 48-hour member of source `id` at `tempC`.
        @discardableResult
        func add(_ id: String, _ tempC: Double) throws -> FakeProvider {
            try add(id, member: try ServiceOrchestratorTests.member(id, tempC))
        }

        /// rig_add_hang: a fake that never answers by itself and honours cancellation.
        @discardableResult
        func addHang(_ id: String) throws -> FakeProvider {
            let fake = try add(id, 20.0)
            fake.setDelayMs(UInt32.max)
            return fake
        }

        /// rig_add_prov.
        func add(_ provider: any WxProvider) throws {
            try registry.addProvider(provider)
        }

        /// rig_results: one result per fake (the first `n`), registration order.
        func results(_ n: Int) throws -> [WxSourceResult] {
            try (0..<n).map { try ServiceOrchestratorTests.result(fakes[$0].id, [members[$0]]) }
        }
    }

    struct Outcome: Sendable {
        let result: Result<WxForecast, any Error>
        let elapsedMs: Int64

        var forecast: WxForecast? { try? result.get() }
        var error: (any Error)? {
            if case .failure(let error) = result { return error }
            return nil
        }
    }

    static func milliseconds(_ d: Duration) -> Int64 {
        let (s, attos) = d.components
        return s * 1000 + attos / 1_000_000_000_000_000
    }

    /// run_refresh + out_wait: one refresh, its elapsed real time, and C's
    /// guard that no test waits for the production deadline by accident
    /// (test-service.c:657-659).
    static func run(_ service: ServiceOrchestrator, _ place: WxPlace, limitMs: Int64 = 10000) async -> Outcome {
        let start = ContinuousClock.now
        let result: Result<WxForecast, any Error>
        do {
            result = .success(try await service.refresh(place))
        } catch {
            result = .failure(error)
        }
        let elapsed = milliseconds(start.duration(to: .now))
        #expect(elapsed < limitMs, "the refresh took \(elapsed) ms")
        return Outcome(result: result, elapsedMs: elapsed)
    }

    /// A refresh from a task that is already cancelled when it calls.
    static func runPreCancelled(_ service: ServiceOrchestrator, _ place: WxPlace) async -> Outcome {
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await run(service, place)
        }.value
    }

    /// assert_failed (test-service.c:673-679).
    static func expectFailed(
        _ o: Outcome, _ code: WxError.Code, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let error = o.error as? WxError else {
            Issue.record("expected WxError(\(code), \(message)), got \(o.result)", sourceLocation: sourceLocation)
            return
        }
        #expect(error.code == code, sourceLocation: sourceLocation)
        #expect(error.message == message, sourceLocation: sourceLocation)
    }

    /// assert_cancelled (test-service.c:681-687).
    static func expectCancelled(_ o: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(o.error is CancellationError, "got \(o.result)", sourceLocation: sourceLocation)
    }

    /// assert_succeeded (test-service.c:689-694).
    static func succeeded(_ o: Outcome, sourceLocation: SourceLocation = #_sourceLocation) -> WxForecast? {
        guard let forecast = o.forecast else {
            Issue.record("expected a forecast, got \(o.result)", sourceLocation: sourceLocation)
            return nil
        }
        return forecast
    }

    /// assert_status (test-service.c:696-707); `code` nil is C's -1.
    static func expectStatus(
        _ fc: WxForecast, _ i: Int, _ id: String, _ state: WxSourceState, _ code: WxError.Code?, _ nMembers: UInt32,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard i < fc.sources.count else {
            Issue.record("no status \(i) of \(fc.sources.count)", sourceLocation: sourceLocation)
            return
        }
        let s = fc.sources[i]
        #expect(s.providerID == id, sourceLocation: sourceLocation)
        #expect(s.state == state, "\(id)", sourceLocation: sourceLocation)
        #expect(s.errorCode == code, "\(id)", sourceLocation: sourceLocation)
        #expect(s.nMembers == nMembers, "\(id)", sourceLocation: sourceLocation)
    }

    /// Waits (polling) until `condition` holds, at most `timeoutMs` (SPIN_UNTIL, test-service.c:38-49).
    static func waitUntil(_ timeoutMs: Int = 10000, _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(timeoutMs)
        while !condition() {
            if ContinuousClock.now > end {
                return false
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// drain_ms.
    static func drain(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Members, places, oracle

    static func nowS() -> Int64 { SystemClock().wallSeconds }

    /// miami (test-service.c:73-85).
    static func miami() throws -> WxPlace {
        try place("Miami", 25.7617, -80.1918, "America/New_York")
    }

    static func place(_ name: String, _ lat: Double, _ lon: Double, _ tz: String) throws -> WxPlace {
        try WxPlace(
            name: name, admin1: "Florida", country: "United States", countryCode: "US", lat: lat, lon: lon,
            timezone: tz)
    }

    /// make_member_n (test-service.c:91-112): `nHours` buckets starting an
    /// hour before now, every variable set, temperature `tempC`.
    static func member(_ source: String, _ model: String = "m", _ tempC: Double, hours nHours: Int = 48) throws
        -> WxMember
    {
        let now = nowS()
        var member = try WxMember(sourceID: source, modelID: model, fetchedS: now)
        for i in 0..<nHours {
            let hour = WxHour(
                tS: now / 3600 * 3600 - 3600 + Int64(i) * 3600, tempC: tempC, feelsC: tempC, precipMm: 0.0,
                precipProb: 10.0, cloudPct: 40.0, windKmh: 10.0, gustKmh: 15.0, humidityPct: 50.0, wmo: 1)
            let added = member.addHour(hour)
            #expect(added)
        }
        return member
    }

    /// make_member: 48 hours of model "m".
    static func member(_ source: String, _ tempC: Double) throws -> WxMember {
        try member(source, "m", tempC, hours: 48)
    }

    /// make_result.
    static func result(_ id: String, _ members: [WxMember]) throws -> WxSourceResult {
        var r = try WxSourceResult(providerID: id)
        r.members = members
        return r
    }

    /// same_double (test-service.c:712-716).
    static func same(_ a: Double, _ b: Double) -> Bool {
        (a.isNaN && b.isNaN) || a == b
    }

    /// assert_same_blend (test-service.c:719-760), NaN-aware field by field.
    static func expectSameBlend(_ a: WxForecast, _ b: WxForecast, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.generatedS == b.generatedS, sourceLocation: sourceLocation)
        #expect(a.hours.count == b.hours.count, sourceLocation: sourceLocation)
        for (x, y) in zip(a.hours, b.hours) {
            let ok =
                x.tS == y.tS && same(x.tempC, y.tempC) && same(x.feelsC, y.feelsC) && same(x.precipMm, y.precipMm)
                && same(x.precipMmMax, y.precipMmMax) && same(x.precipProb, y.precipProb)
                && same(x.cloudPct, y.cloudPct) && same(x.windKmh, y.windKmh) && same(x.gustKmh, y.gustKmh)
                && same(x.humidityPct, y.humidityPct) && same(x.tempSpreadC, y.tempSpreadC)
                && x.nMembers == y.nMembers && x.condition == y.condition && x.isDay == y.isDay
            #expect(ok, "hour \(x.tS): \(x) vs \(y)", sourceLocation: sourceLocation)
        }
        #expect(a.quarters.count == b.quarters.count, sourceLocation: sourceLocation)
        for (x, y) in zip(a.quarters, b.quarters) {
            #expect(x.tS == y.tS && same(x.precipMm, y.precipMm), sourceLocation: sourceLocation)
        }
        #expect(a.days.count == b.days.count, sourceLocation: sourceLocation)
        for (x, y) in zip(a.days, b.days) {
            let ok =
                x.startS == y.startS && same(x.tempMaxC, y.tempMaxC) && same(x.tempMinC, y.tempMinC)
                && same(x.precipMm, y.precipMm) && same(x.precipProbMax, y.precipProbMax)
                && same(x.cloudPct, y.cloudPct) && x.condition == y.condition
            #expect(ok, "day \(x.startS)", sourceLocation: sourceLocation)
        }
    }

    /// assert_matches_oracle (test-service.c:764-776): the blend of `results`
    /// at the forecast's time and with its statuses gives the same forecast.
    static func expectMatchesOracle(
        _ got: WxForecast, _ place: WxPlace, _ results: [WxSourceResult],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let expected = try WxBlend.forecast(
                place: place, results: results, statuses: got.sources, nowS: got.generatedS)
            expectSameBlend(got, expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("the oracle blend failed: \(error)", sourceLocation: sourceLocation)
        }
    }

    /// all_codes (test-service.c:978-980).
    static let allCodes: [WxError.Code] = [
        .network, .timeout, .http, .rateLimited, .parse, .notFound, .invalidArg, .unsupported,
    ]

    /// code_rank (test-service.c:983-987).
    static func codeRank(_ code: WxError.Code) -> Int {
        switch code {
        case .network, .timeout: return 0
        case .rateLimited: return 1
        case .http: return 2
        case .parse: return 3
        case .notFound: return 4
        case .unsupported: return 5
        case .invalidArg: return 6
        }
    }

    // MARK: - Construction

    // C: /service/constants (test-service.c:781-785); /service-production/constant
    // (test-service-production.c:241-245).
    @Test("/service/constants and /service-production/constant")
    func constants() {
        #expect(ServiceOrchestrator.deadlineMs == 30000)  // test-service.c:783
        #expect(WxRegistry.maxProviders <= WxLimits.forecastMaxSources)  // test-service.c:784
        let service = ServiceOrchestrator(registry: WxRegistry())
        #expect(service.testDeadlineMs == 30000)  // the production value
        service.testDeadlineMs = 100
        #expect(service.testDeadlineMs == 100)
        service.testDeadlineMs = 0  // wx-service-testing.h:22-23 (0 restores WX_SERVICE_DEADLINE_MS)
        #expect(service.testDeadlineMs == 30000)
    }

    // C: /service/new (test-service.c:788-806), the reference part: the service
    // holds its own registry and drops it with itself.
    @Test("/service/new")
    func newHoldsRegistry() {
        weak var weakRegistry: WxRegistry?
        var service: ServiceOrchestrator?
        do {
            let registry = WxRegistry()
            weakRegistry = registry
            service = ServiceOrchestrator(registry: registry)
        }
        #expect(weakRegistry != nil)  // test-service.c:802: the service holds its own reference ...
        service = nil
        _ = service
        #expect(weakRegistry == nil)  // test-service.c:804: ... and drops it when it is finalized
    }

    // MARK: - Refresh: success paths

    // C: /service/refresh/all-ok (test-service.c:810-850)
    @Test("/service/refresh/all-ok")
    func allOK() async throws {
        let rig = Rig()
        let a = try rig.add("fake-a", 10.0)
        let b = try rig.add("fake-b", 20.0)
        let c = try rig.add("fake-c", 30.0)
        let place = try Self.miami()
        let before = Self.nowS()
        let out = await Self.run(rig.service, place)
        let after = Self.nowS()
        let fc = try #require(Self.succeeded(out))
        #expect(fc.generatedS >= before && fc.generatedS <= after)  // :822-823
        #expect(fc.place.key == place.key)  // :824-826
        #expect(fc.place.name == "Miami")  // :827
        #expect(a.fetchCount == 1 && b.fetchCount == 1 && c.fetchCount == 1)  // :828-830
        #expect(fc.sources.count == 3)  // :832
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :833
        Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
        #expect(fc.sources[1].name == "Fake fake-b")  // :836
        #expect(fc.sources[1].attribution == "Fake data (fake-b)")  // :837
        #expect(fc.sources[1].attributionURL == "https://example.invalid/")  // :838
        #expect(fc.hours.count >= WxBlend.minHours)  // :840
        for h in fc.hours {
            #expect(h.nMembers == 3)  // :842
            #expect(h.tempC == 20.0)  // :846 the median of 10, 20, 30
        }
        Self.expectMatchesOracle(fc, place, try rig.results(3))  // :848-849
    }

    // C: /service/refresh/starts-all-at-once (test-service.c:855-900). Every
    // covering provider is called before any answers, none is cancelled while
    // the refresh waits, and the refresh waits for all of them. (The shared
    // private GCancellable identity has no Swift counterpart: each fetch runs
    // in its own unstructured task.)
    @Test("/service/refresh/starts-all-at-once")
    func startsAllAtOnce() async throws {
        let rig = Rig()
        let ids = ["hold-a", "hold-b", "hold-c"]
        var prov: [ScriptedProvider] = []
        for (i, id) in ids.enumerated() {
            let p = ScriptedProvider(id)
            p.set { $0.mode = .hold }
            p.addMember(try Self.member(id, 10.0 * Double(i + 1)))
            try rig.add(p)
            prov.append(p)
        }
        let place = try Self.miami()
        let service = rig.service
        let task = Task { @MainActor in await Self.run(service, place) }
        #expect(await Self.waitUntil { prov.allSatisfy { $0.heldCount == 1 } })  // :871-874
        for p in prov {
            #expect(p.fetches == 1)
            #expect(!p.sawCancellation)  // :879
        }
        await Self.drain(30)
        #expect(prov.allSatisfy { $0.heldCount == 1 })  // :881 still waiting for all of them
        prov[2].release()
        prov[0].release()
        await Self.drain(30)
        #expect(prov[1].heldCount == 1)  // :886 two of three are not enough
        prov[1].release()
        let out = await task.value
        let fc = try #require(Self.succeeded(out))
        #expect(fc.sources.count == 3)  // :891
        Self.expectStatus(fc, 0, "hold-a", .ok, nil, 1)
        Self.expectStatus(fc, 1, "hold-b", .ok, nil, 1)
        Self.expectStatus(fc, 2, "hold-c", .ok, nil, 1)
        #expect(!task.isCancelled)  // :895 the caller is left alone
        #expect(prov.allSatisfy { !$0.sawCancellation })
    }

    // C: /service/refresh/order-independent (test-service.c:903-927)
    @Test("/service/refresh/order-independent")
    func orderIndependent() async throws {
        let rig = Rig()
        let a = try rig.add("fake-a", 10.0)
        let b = try rig.add("fake-b", 20.0)
        let c = try rig.add("fake-c", 45.0)
        let place = try Self.miami()
        let results = try rig.results(3)
        let delays: [[UInt32]] = [[0, 40, 80], [80, 40, 0]]  // :911
        for round in delays {
            a.setDelayMs(round[0])
            b.setDelayMs(round[1])
            c.setDelayMs(round[2])
            let out = await Self.run(rig.service, place)
            let fc = try #require(Self.succeeded(out))
            #expect(fc.sources.count == 3)
            Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)
            Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
            Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
            Self.expectMatchesOracle(fc, place, results)  // :923
        }
    }

    // C: /service/refresh/duplicate-members (test-service.c:930-972), with the
    // blend half (hours, temperatures, oracle) that ServicePipelineTests leaves out.
    @Test("/service/refresh/duplicate-members")
    func duplicateMembers() async throws {
        for swap in [false, true] {
            let rig = Rig()
            let low = try Self.member("shared", "m", 10.0, hours: 48)
            let high = try Self.member("shared", "m", 60.0, hours: 48)
            let first = try rig.add("fake-a", member: swap ? high : low)
            let second = try rig.add("fake-b", member: swap ? low : high)
            first.setDelayMs(60)  // :939 the first registered one answers last
            second.setDelayMs(0)
            let place = try Self.miami()
            let out = await Self.run(rig.service, place)
            let fc = try #require(Self.succeeded(out))
            Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :945
            Self.expectStatus(fc, 1, "fake-b", .ok, nil, 0)  // :947
            for h in fc.hours {
                #expect(h.nMembers == 1)  // :949
                #expect(h.tempC == (swap ? 60.0 : 10.0))  // :950
            }
            Self.expectMatchesOracle(fc, place, try rig.results(2))  // :952-953
        }
        let rig = Rig()
        let low = try Self.member("shared", "m", 10.0, hours: 48)
        let high = try Self.member("shared", "m", 60.0, hours: 48)
        let twice = try rig.add("fake-a", member: low)
        twice.addMember(high)
        let out = await Self.run(rig.service, try Self.miami())
        let fc = try #require(Self.succeeded(out))
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :967
        for h in fc.hours {
            #expect(h.tempC == 10.0)  // :969
        }
    }

    // MARK: - Refresh: failures, error selection

    // C: /service/refresh/one-fails (test-service.c:990-1019)
    @Test("/service/refresh/one-fails")
    func oneFails() async throws {
        let rig = Rig()
        let a = try rig.add("fake-a", 10.0)
        let b = try rig.add("fake-b", 20.0)
        let c = try rig.add("fake-c", 30.0)
        b.failWith(.network)
        let place = try Self.miami()
        let out = await Self.run(rig.service, place)
        let fc = try #require(Self.succeeded(out))
        #expect(fc.sources.count == 3)
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)
        Self.expectStatus(fc, 1, "fake-b", .failed, .network, 0)  // :1004
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
        #expect(a.fetchCount == 1 && b.fetchCount == 1 && c.fetchCount == 1)
        for h in fc.hours {
            #expect(h.nMembers == 2)  // :1010
            #expect(h.tempC == 20.0)  // :1011 the mean of 10 and 30
        }
        let results = [try Self.result("fake-a", [rig.members[0]]), try Self.result("fake-c", [rig.members[2]])]
        Self.expectMatchesOracle(fc, place, results)  // :1013-1016
    }

    // C: /service/refresh/each-error-code (test-service.c:1022-1047)
    @Test("/service/refresh/each-error-code")
    func eachErrorCode() async throws {
        for code in Self.allCodes {
            let rig = Rig()
            try rig.add("fake-a", 10.0)
            let b = try rig.add("fake-b", 20.0)
            b.failWith(code)
            let place = try Self.miami()
            let out = await Self.run(rig.service, place)
            let fc = try #require(Self.succeeded(out))
            #expect(fc.sources.count == 2)
            Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)
            if code == .unsupported {
                Self.expectStatus(fc, 1, "fake-b", .skipped, nil, 0)  // :1038
            } else {
                Self.expectStatus(fc, 1, "fake-b", .failed, code, 0)  // :1040
            }
            #expect(b.fetchCount == 1)
            Self.expectMatchesOracle(fc, place, try rig.results(1))  // :1042-1043
        }
    }

    // C: /service/refresh/all-fail-single (test-service.c:1050-1065)
    @Test("/service/refresh/all-fail-single")
    func allFailSingle() async throws {
        for code in Self.allCodes {
            let rig = Rig()
            let a = try rig.add("fake-a", 10.0)
            a.failWith(code)
            let out = await Self.run(rig.service, try Self.miami())
            Self.expectFailed(out, code, "fake-a: scripted failure")  // :1060
            #expect(a.fetchCount == 1)
        }
    }

    // C: /service/refresh/error-ranking (test-service.c:1068-1091)
    @Test("/service/refresh/error-ranking")
    func errorRanking() async throws {
        for first in Self.allCodes {
            for second in Self.allCodes {
                let rig = Rig()
                try rig.add("fake-a", 10.0).failWith(first)
                try rig.add("fake-b", 20.0).failWith(second)
                let out = await Self.run(rig.service, try Self.miami())
                if Self.codeRank(first) <= Self.codeRank(second) {
                    Self.expectFailed(out, first, "fake-a: scripted failure")  // :1083
                } else {
                    Self.expectFailed(out, second, "fake-b: scripted failure")  // :1085
                }
            }
        }
    }

    // C: /service/refresh/error-ranking-blend (test-service.c:1094-1112)
    @Test("/service/refresh/error-ranking-blend")
    func errorRankingBlend() async throws {
        for code in Self.allCodes {
            let rig = Rig()
            try rig.add("fake-a", member: try Self.member("fake-a", "m", 10.0, hours: 5))  // :1099
            try rig.add("fake-b", 20.0).failWith(code)
            let out = await Self.run(rig.service, try Self.miami())
            if Self.codeRank(code) <= Self.codeRank(.notFound) {
                Self.expectFailed(out, code, "fake-b: scripted failure")  // :1106
            } else {
                Self.expectFailed(out, .notFound, "no usable forecast data")  // :1108
            }
        }
    }

    /// add_refusing (test-service.c:1115-1121).
    static func addRefusing(_ rig: Rig, _ id: String, _ code: WxError.Code, _ message: String) throws {
        let p = ScriptedProvider(id)
        p.set { $0.failure = WxError(code, message) }
        try rig.add(p)
    }

    static let floorText = "a request for this place was sent less than 10 minutes ago"  // test-service.c:1122
    static let capText = "too many outstanding requests (limit 16)"  // test-service.c:1123

    // C: /service/refresh/local-refusal-ranks-last (test-service.c:1132-1186)
    @Test("/service/refresh/local-refusal-ranks-last")
    func localRefusalRanksLast() async throws {
        let texts = [Self.floorText, Self.capText]
        for text in texts {
            for code in Self.allCodes {
                let rig = Rig()
                try Self.addRefusing(rig, "met-no", .rateLimited, text)  // registered FIRST
                try rig.add("fake-b", 20.0).failWith(code)
                let out = await Self.run(rig.service, try Self.miami())
                Self.expectFailed(out, code, "fake-b: scripted failure")  // :1143
            }
        }
        for text in texts {
            let rig = Rig()
            try Self.addRefusing(rig, "met-no", .rateLimited, text)
            let out = await Self.run(rig.service, try Self.miami())
            Self.expectFailed(out, .notFound, "met-no: " + text)  // :1155-1156
        }
        do {
            let rig = Rig()
            try Self.addRefusing(rig, "met-no", .rateLimited, Self.floorText)
            try rig.add("fake-b", member: try Self.member("fake-b", "m", 10.0, hours: 5))
            let out = await Self.run(rig.service, try Self.miami())
            Self.expectFailed(out, .notFound, "no usable forecast data")  // :1171
        }
        do {
            let rig = Rig()
            try Self.addRefusing(rig, "met-no", .rateLimited, Self.floorText)
            try rig.add("fake-b", 20.0)
            let out = await Self.run(rig.service, try Self.miami())
            let fc = try #require(Self.succeeded(out))
            Self.expectStatus(fc, 0, "met-no", .failed, .rateLimited, 0)  // :1182
            Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)  // :1183
        }
    }

    // C: /service/refresh/genuine-rate-limit-keeps-rank (test-service.c:1194-1221)
    @Test("/service/refresh/genuine-rate-limit-keeps-rank")
    func genuineRateLimitKeepsRank() async throws {
        let genuine = [
            "HTTP 429: rate limited", "requests are paused after HTTP 429",
            "NWS asked for fewer requests; waiting 5 seconds", "x " + Self.floorText, "the " + Self.capText, "",
        ]  // :1196-1198
        for text in genuine {
            let rig = Rig()
            try Self.addRefusing(rig, "met-no", .rateLimited, text)
            try rig.add("fake-b", 20.0).failWith(.http)
            let out = await Self.run(rig.service, try Self.miami())
            Self.expectFailed(out, .rateLimited, "met-no: " + text)  // :1205-1206
        }
        let rig = Rig()
        try Self.addRefusing(rig, "met-no", .http, Self.floorText)
        try rig.add("fake-b", 20.0).failWith(.parse)
        let out = await Self.run(rig.service, try Self.miami())
        Self.expectFailed(out, .http, "met-no: " + Self.floorText)  // :1219
    }

    // C: /service/refresh/blend-not-found (test-service.c:1224-1247)
    @Test("/service/refresh/blend-not-found")
    func blendNotFound() async throws {
        let rig = Rig()
        try rig.add("fake-a", member: try Self.member("fake-a", "m", 10.0, hours: 5))
        try rig.add("fake-b", member: try Self.member("fake-b", "m", 20.0, hours: 1))
        let place = try Self.miami()
        Self.expectFailed(await Self.run(rig.service, place), .notFound, "no usable forecast data")  // :1234
        try rig.add("fake-c", 30.0)
        let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        #expect(fc.sources.count == 3)
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :1242-1244
        Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
    }

    // C: /service/refresh/no-members (test-service.c:1250-1271)
    @Test("/service/refresh/no-members")
    func noMembers() async throws {
        let rig = Rig()
        try rig.add(FakeProvider(id: "fake-b"))
        let place = try Self.miami()
        Self.expectFailed(
            await Self.run(rig.service, place), .notFound, "fake-b: the provider returned no forecast data")  // :1258
        let good = try rig.add("fake-c", 20.0)
        let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        #expect(fc.sources.count == 2)
        Self.expectStatus(fc, 0, "fake-b", .failed, .notFound, 0)  // :1266
        Self.expectStatus(fc, 1, "fake-c", .ok, nil, 1)
        #expect(good.fetchCount == 1)
    }

    /// check_bad_provider (test-service.c:1281-1318); `alone` nil = ALONE_OK,
    /// `.cancelled` = ALONE_CANCELLED, else the expected error.
    enum Alone {
        case ok
        case cancelled
        case failed(WxError.Code, String)
    }

    static func checkBadProvider(
        _ bad: ScriptedProvider, _ state: WxSourceState, _ code: WxError.Code?, _ nMembers: UInt32, _ alone: Alone,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let place = try miami()
        do {
            let rig = Rig()
            try rig.add("fake-a", 20.0)
            try rig.add(bad)
            let out = await run(rig.service, place)
            let fc = try #require(succeeded(out, sourceLocation: sourceLocation), sourceLocation: sourceLocation)
            #expect(fc.sources.count == 2, sourceLocation: sourceLocation)
            expectStatus(fc, 0, "fake-a", .ok, nil, 1, sourceLocation: sourceLocation)
            expectStatus(fc, 1, "bad-x", state, code, nMembers, sourceLocation: sourceLocation)
            var results = try rig.results(1)
            let members = bad.state.withLock { $0.members }
            if state == .ok, let first = members.first {
                results.append(try result("bad-x", [first]))
            }
            expectMatchesOracle(fc, place, results, sourceLocation: sourceLocation)
        }
        do {
            let rig = Rig()
            try rig.add(bad)
            let out = await run(rig.service, place)
            switch alone {
            case .ok:
                _ = succeeded(out, sourceLocation: sourceLocation)
            case .cancelled:
                expectCancelled(out, sourceLocation: sourceLocation)
            case .failed(let code, let message):
                expectFailed(out, code, message, sourceLocation: sourceLocation)
            }
        }
    }

    // C: /service/refresh/garbage-results (test-service.c:1326-1368), the cases a
    // Swift provider can produce (NULL results, NULL member arrays and NULL
    // entries cannot be returned).
    @Test("/service/refresh/garbage-results")
    func garbageResults() async throws {
        // a member without any hour or quarter does not count (:1355-1360)
        let p5 = ScriptedProvider("bad-x")
        p5.addMember(try WxMember(sourceID: "bad-x", modelID: "m", fetchedS: Self.nowS()))
        try await Self.checkBadProvider(
            p5, .failed, .notFound, 0, .failed(.notFound, "bad-x: the provider returned no forecast data"))
        // quarters only: counts, but cannot make a forecast alone (:1362-1367)
        let p6 = ScriptedProvider("bad-x")
        var quarters = try WxMember(sourceID: "bad-x", modelID: "m", fetchedS: Self.nowS())
        let added = quarters.addQuarter(WxQuarter(tS: Self.nowS() / 900 * 900, precipMm: 0.5))
        #expect(added)
        p6.addMember(quarters)
        try await Self.checkBadProvider(p6, .ok, nil, 1, .failed(.notFound, "no usable forecast data"))
        // a real member (C p4 without its NULL neighbours, :1350-1353)
        let p4 = ScriptedProvider("bad-x")
        p4.addMember(try Self.member("bad-x", 30.0))
        try await Self.checkBadProvider(p4, .ok, nil, 1, .ok)
    }

    /// "ba" U+202E "d" BEL 0xFF then 300 'x' (test-service.c:1402-1404) as the
    /// bytes C has, decoded as a String does (0xFF becomes U+FFFD).
    static let hostileBytes: [UInt8] = [0x62, 0x61, 0xE2, 0x80, 0xAE, 0x64, 0x07, 0xFF] + [UInt8](repeating: 0x78, count: 300)

    // C: /service/refresh/foreign-errors (test-service.c:1372-1413), without the
    // WX_ERROR codes 99 / -3 (WxError.Code is an enum).
    @Test("/service/refresh/foreign-errors")
    func foreignErrors() async throws {
        let p1 = ScriptedProvider("bad-x")
        p1.set { $0.failure = ForeignError(text: "no such thing") }  // :1376
        try await Self.checkBadProvider(p1, .failed, .network, 0, .failed(.network, "bad-x: no such thing"))  // :1378
        let p2 = ScriptedProvider("bad-x")
        p2.set { $0.failure = URLError(.timedOut) as any Error }
        let p2Text = URLError(.timedOut).localizedDescription
        try await Self.checkBadProvider(p2, .failed, .network, 0, .failed(.network, "bad-x: " + p2Text))  // :1380-1384
        // a cancellation the provider reports itself: a failure without a code;
        // alone it makes the refresh cancelled (:1396-1399)
        let p5 = ScriptedProvider("bad-x")
        p5.set { $0.failure = CancellationError() }
        try await Self.checkBadProvider(p5, .failed, nil, 0, .cancelled)
        // sanitised and cut at 200 bytes: "bad" + U+FFFD + 194 x (:1402-1412)
        let p6 = ScriptedProvider("bad-x")
        p6.set { $0.failure = ForeignError(text: String(decoding: Self.hostileBytes, as: UTF8.self)) }
        let want = String(decoding: [0x62, 0x61, 0x64, 0xEF, 0xBF, 0xBD] as [UInt8], as: UTF8.self)
            + String(repeating: "x", count: 194)  // :1409-1411
        try await Self.checkBadProvider(p6, .failed, .network, 0, .failed(.network, "bad-x: " + want))
    }

    // C: /service/refresh/cancelled-providers (test-service.c:1441-1470)
    @Test("/service/refresh/cancelled-providers")
    func cancelledProviders() async throws {
        let rig = Rig()
        let c1 = ScriptedProvider("cancel-a")
        let c2 = ScriptedProvider("cancel-b")
        c1.set { $0.failure = CancellationError() }
        c2.set { $0.failure = CancellationError() }
        try rig.add(c1)
        try rig.add(c2)
        let place = try Self.miami()
        Self.expectCancelled(await Self.run(rig.service, place))  // :1452
        let failing = try rig.add("fake-c", 10.0)
        failing.failWith(.rateLimited)
        Self.expectFailed(await Self.run(rig.service, place), .rateLimited, "fake-c: scripted failure")  // :1458
        failing.failWith(nil)
        let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        Self.expectStatus(fc, 0, "cancel-a", .failed, nil, 0)  // :1464-1466
        Self.expectStatus(fc, 1, "cancel-b", .failed, nil, 0)
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
    }

    // C: /service/refresh/source-fields (test-service.c:1473-1524). C's NULL
    // name / attribution / URL become "" (a Swift provider's text is never nil).
    @Test("/service/refresh/source-fields")
    func sourceFields() async throws {
        let rig = Rig()
        let nice = ScriptedProvider("prov-nice")
        nice.set {
            $0.name = "Nice Name"
            $0.attribution = "Nice credit"
            $0.url = "https://example.invalid/path?x=1"
        }
        let odd = ScriptedProvider("prov-odd")
        // "A\x01" "B\xE2\x80\xAE" "C" (:1485) as bytes
        let oddName = String(decoding: [0x41, 0x01, 0x42, 0xE2, 0x80, 0xAE, 0x43] as [UInt8], as: UTF8.self)
        odd.set {
            $0.name = oddName
            $0.attribution = ""
            $0.url = "http://insecure.invalid/"
        }
        let renamed = ScriptedProvider("prov-renamed")
        let bare = ScriptedProvider("prov-bare")
        bare.set {
            $0.name = ""
            $0.url = ""
        }
        for (i, p) in [nice, odd, renamed, bare].enumerated() {
            p.addMember(try Self.member(p.id, 10.0 + Double(i)))
            try rig.add(p)
        }
        renamed.set { $0.id = "BAD ID" }  // :1501-1502 changed after the registry accepted it
        let out = await Self.run(rig.service, try Self.miami())
        let fc = try #require(Self.succeeded(out))
        #expect(renamed.fetches == 0)  // :1508
        #expect(renamed.coversCalls == 1)  // :1509
        #expect(fc.sources.count == 3)  // :1511
        Self.expectStatus(fc, 0, "prov-nice", .ok, nil, 1)
        #expect(fc.sources[0].name == "Nice Name")  // :1513
        #expect(fc.sources[0].attribution == "Nice credit")
        #expect(fc.sources[0].attributionURL == "https://example.invalid/path?x=1")
        Self.expectStatus(fc, 1, "prov-odd", .ok, nil, 1)
        #expect(fc.sources[1].name == "ABC")  // :1517
        #expect(fc.sources[1].attribution == "")
        #expect(fc.sources[1].attributionURL == "")  // :1519 rejected: replaced
        Self.expectStatus(fc, 2, "prov-bare", .ok, nil, 1)
        #expect(fc.sources[2].name == "")  // :1521
        #expect(fc.sources[2].attributionURL == "")
    }

    // C: /service/refresh/skipped (test-service.c:1528-1579)
    @Test("/service/refresh/skipped")
    func skipped() async throws {
        let rig = Rig()
        let a = ScriptedProvider("prov-a")
        let b = ScriptedProvider("prov-b")
        let c = ScriptedProvider("prov-c")
        for (i, p) in [a, b, c].enumerated() {
            p.addMember(try Self.member(p.id, 10.0 * Double(i + 1)))
            try rig.add(p)
        }
        c.set { $0.covers = false }
        let d = try rig.add("fake-d", 40.0)
        d.failWith(.unsupported)  // learned from the server
        #expect(rig.registry.setEnabled(false, id: "prov-b"))
        let place = try Self.miami()
        var fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        #expect(fc.sources.count == 4)
        Self.expectStatus(fc, 0, "prov-a", .ok, nil, 1)  // :1547-1550
        Self.expectStatus(fc, 1, "prov-b", .skipped, nil, 0)
        Self.expectStatus(fc, 2, "prov-c", .skipped, nil, 0)
        Self.expectStatus(fc, 3, "fake-d", .skipped, nil, 0)
        #expect(a.fetches == 1 && b.fetches == 0 && c.fetches == 0 && d.fetchCount == 1)  // :1551-1554
        #expect(a.coversCalls == 1 && b.coversCalls == 0 && c.coversCalls == 1)  // :1555-1557
        for h in fc.hours {
            #expect(h.nMembers == 1)  // :1559
        }
        #expect(rig.registry.setEnabled(true, id: "prov-b"))
        c.set { $0.covers = true }
        fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        Self.expectStatus(fc, 0, "prov-a", .ok, nil, 1)  // :1567-1570
        Self.expectStatus(fc, 1, "prov-b", .ok, nil, 1)
        Self.expectStatus(fc, 2, "prov-c", .ok, nil, 1)
        Self.expectStatus(fc, 3, "fake-d", .skipped, nil, 0)
        #expect(a.coversCalls == 2 && b.coversCalls == 1 && c.coversCalls == 2)  // :1571-1573
    }

    // C: /service/refresh/no-covering (test-service.c:1582-1623)
    @Test("/service/refresh/no-covering")
    func noCovering() async throws {
        let message = "no enabled data source covers this place"  // :1584
        let place = try Self.miami()
        let empty = Rig()
        Self.expectFailed(await Self.run(empty.service, place), .unsupported, message)  // :1590
        let rig = Rig()
        let a = try rig.add("fake-a", 10.0)
        let b = try rig.add("fake-b", 20.0)
        #expect(rig.registry.setEnabled(false, id: "fake-a"))
        #expect(rig.registry.setEnabled(false, id: "fake-b"))
        Self.expectFailed(await Self.run(rig.service, place), .unsupported, message)  // :1599 all disabled
        #expect(rig.registry.setEnabled(true, id: "fake-a"))
        #expect(rig.registry.setEnabled(true, id: "fake-b"))
        a.setCovers(false)
        b.setCovers(false)
        Self.expectFailed(await Self.run(rig.service, place), .unsupported, message)  // :1607 all non-covering
        #expect(a.fetchCount == 0 && b.fetchCount == 0)  // :1609-1610
        let odd = Rig()
        let renamed = ScriptedProvider("prov-renamed")
        try odd.add(renamed)
        renamed.set { $0.id = "Not Valid" }  // :1617-1618
        Self.expectFailed(await Self.run(odd.service, place), .unsupported, message)  // :1620
        #expect(renamed.fetches == 0)  // :1621
    }

    // U15 HANDOFF GAP (3), wx-service.c:675 and wx-service.h:39-42, 121-127: the
    // refresh error is prefixed with the provider id read when the refresh
    // started (not a later id, not the result's providerID), and a result's
    // providerID / member source ids are never compared with the provider id.
    @Test("/service/refresh (contract): the error prefix is the id read at refresh time")
    func errorPrefixIsRefreshTimeID() async throws {
        let place = try Self.miami()
        do {
            let rig = Rig()
            let p = ScriptedProvider("prov-a")
            p.set {
                $0.failure = WxError(.parse, "bad")
                $0.onFetch = { prov in prov.set { $0.id = "prov-z" } }  // renames itself while fetching
            }
            try rig.add(p)
            Self.expectFailed(await Self.run(rig.service, place), .parse, "prov-a: bad")
        }
        do {
            let rig = Rig()
            let q = ScriptedProvider("prov-b")
            q.addMember(try Self.member("foreign-src", "x", 20.0, hours: 48))
            q.set { $0.onFetch = { prov in prov.set { $0.id = "other-id" } } }  // result providerID "other-id"
            try rig.add(q)
            let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
            Self.expectStatus(fc, 0, "prov-b", .ok, nil, 1)
            #expect(fc.hours.allSatisfy { $0.nMembers == 1 && $0.tempC == 20.0 })
        }
    }

    // C: /service/refresh/place-is-copied (test-service.c:1716-1742): the
    // provider gets the same place (by key) while the caller's own copy may go.
    @Test("/service/refresh/place-is-copied")
    func placeIsCopied() async throws {
        let rig = Rig()
        let prov = ScriptedProvider("prov-a")
        prov.addMember(try Self.member("prov-a", 10.0))
        prov.set { $0.mode = .answer(delayMs: 40) }  // :1722
        try rig.add(prov)
        let service = rig.service
        var place: WxPlace? = try Self.place("Miami", 25.7617, -80.1918, "America/New_York")
        let wantKey = try #require(place).key
        let task = Task { @MainActor [p = try #require(place)] in await Self.run(service, p) }
        place = nil  // before any provider has answered
        _ = place
        #expect(await Self.waitUntil { prov.fetches == 1 })  // :1733
        #expect(prov.seenKey == wantKey)  // :1735
        let fc = try #require(Self.succeeded(await task.value))
        #expect(fc.place.name == "Miami")  // :1738
        #expect(fc.place.timezone == "America/New_York")  // :1739
        #expect(fc.place.key == wantKey)  // :1740-1741
    }

    // C: /service/refresh/limits (test-service.c:2599-2640)
    @Test("/service/refresh/limits")
    func limits() async throws {
        let rig = Rig()
        for i in 0..<WxRegistry.maxProviders {
            try rig.add(Self.twoDigits("fake-", i), 10.0 + Double(i))
        }
        #expect(throws: WxError.self) { try rig.registry.addProvider(FakeProvider(id: "fake-extra")) }  // :2607-2609
        let place = try Self.miami()
        let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
        #expect(fc.sources.count == WxRegistry.maxProviders)  // :2614
        for i in 0..<WxRegistry.maxProviders {
            Self.expectStatus(fc, i, Self.twoDigits("fake-", i), .ok, nil, 1)  // :2617
        }
        Self.expectMatchesOracle(fc, place, try rig.results(WxRegistry.maxProviders))  // :2619-2620
        // one provider returning 200 members: 128 forwarded and counted (:2623-2637)
        let many = Rig()
        let big = FakeProvider(id: "fake-big")
        for i in 0..<200 {
            big.addMember(try Self.member("fake-big", "m\(i)", 10.0 + Double(i % 20), hours: 48))
        }
        try many.add(big)
        let fc2 = try #require(Self.succeeded(await Self.run(many.service, place)))
        Self.expectStatus(fc2, 0, "fake-big", .ok, nil, UInt32(ServicePipeline.blendMaxMembers))  // :2634
        #expect(fc2.hours.first?.nMembers == UInt8(ServicePipeline.blendMaxMembers))  // :2635
    }

    // MARK: - Share (the blend halves of the share cases)

    // C: /service/share/big-provider-first (test-service.c:3089-3112): the blend half.
    @Test("/service/share/big-provider-first")
    func shareBigProviderFirst() async throws {
        let rig = Rig()
        let a = FakeProvider(id: "fake-00")
        for m in 0..<ServicePipeline.blendMaxMembers {
            a.addMember(try Self.member("fake-a", Self.model(m), 10.0, hours: 1))
        }
        let b = FakeProvider(id: "fake-01")
        let bMember = try Self.member("fake-b", "m000", 30.0, hours: 48)
        b.addMember(bMember)
        try rig.add(a)
        try rig.add(b)
        let fc = try #require(Self.succeeded(await Self.run(rig.service, try Self.miami())))
        Self.expectStatus(fc, 0, "fake-00", .ok, nil, UInt32(ServicePipeline.blendMaxMembers - 1))  // :3102
        Self.expectStatus(fc, 1, "fake-01", .ok, nil, 1)  // :3103
        let t0 = try #require(bMember.hours.first).tS
        #expect(fc.hours.first { $0.tS == t0 }?.nMembers == UInt8(ServicePipeline.blendMaxMembers))  // :3105-3106
        let next = fc.hours.first { $0.tS == t0 + 3600 }
        #expect(next?.nMembers == 1)  // :3108
        #expect(next?.tempC == 30.0)  // :3109
    }

    // C: /service/share/many-providers (test-service.c:3173-3217): statuses,
    // the most members in one hour, and the blend of the forwarded prefixes.
    @Test("/service/share/many-providers")
    func shareManyProviders() async throws {
        let rows: [(lens: [Int], want: [Int])] = [  // :3175-3193
            ([200, 1], [127, 1]), ([1, 200], [1, 127]), ([128, 128], [64, 64]), ([129, 1], [127, 1]),
            ([128, 1], [127, 1]), ([127, 1], [127, 1]), ([5, 300, 5], [5, 118, 5]),
            ([0, 50, 0, 200], [0, 50, 0, 78]),
            ([10, 20, 30, 40, 50, 60, 70, 80], [10, 17, 17, 17, 17, 17, 17, 16]),
            (Array(repeating: 8, count: 16), Array(repeating: 8, count: 16)),
            (Array(repeating: 9, count: 16), Array(repeating: 8, count: 16)),
            (Array(repeating: 200, count: 16), Array(repeating: 8, count: 16)),
            (Array(1...16), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 12, 12]),
        ]
        let place = try Self.miami()
        for row in rows {
            let rig = Rig()
            var chosen: [WxSourceResult] = []
            for (i, len) in row.lens.enumerated() {
                let id = Self.twoDigits("fake-", i)
                let fake = FakeProvider(id: id)
                var members: [WxMember] = []
                for m in 0..<len {
                    let member = try Self.member(id, Self.model(m), 5.0 + 0.05 * Double(m) + 0.5 * Double(i))
                    members.append(member)
                    fake.addMember(member)
                }
                try rig.add(fake)
                if row.want[i] > 0 {
                    chosen.append(try Self.result(id, Array(members.prefix(row.want[i]))))
                }
            }
            let fc = try #require(Self.succeeded(await Self.run(rig.service, place)))
            for i in row.lens.indices {
                #expect(fc.sources[i].nMembers == UInt32(row.want[i]), "row \(row.lens)")  // :3208
                #expect(fc.sources[i].state == (row.lens[i] > 0 ? .ok : .failed))  // :3209-3210
            }
            #expect(Int(fc.hours.map(\.nMembers).max() ?? 0) == row.want.reduce(0, +))  // :3212
            Self.expectMatchesOracle(fc, place, chosen)  // check_share :3049-3050
        }
    }

    // MARK: - Deadline

    // C: /service/deadline/partial (test-service.c:1764-1791)
    @Test("/service/deadline/partial")
    func deadlinePartial() async throws {
        let rig = Rig(deadlineMs: 300)  // :1766
        try rig.add("fake-a", 10.0)
        let hang = try rig.addHang("fake-hang")
        try rig.add("fake-c", 30.0)
        let place = try Self.miami()
        let out = await Self.run(rig.service, place)
        let fc = try #require(Self.succeeded(out))
        #expect(out.elapsedMs >= 300 && out.elapsedMs < 300 + 2000, "\(out.elapsedMs) ms")  // :1776-1777
        #expect(fc.sources.count == 3)
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :1779-1781
        Self.expectStatus(fc, 1, "fake-hang", .failed, .timeout, 0)
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
        #expect(hang.fetchCount == 1)
        for h in fc.hours {
            #expect(h.nMembers == 2)  // :1784
        }
        let results = [try Self.result("fake-a", [rig.members[0]]), try Self.result("fake-c", [rig.members[2]])]
        Self.expectMatchesOracle(fc, place, results)  // :1785-1788
    }

    // C: /service/deadline/cancels-stragglers (test-service.c:1794-1812): the
    // straggler is told to stop, and as it honours that its fetch ends.
    @Test("/service/deadline/cancels-stragglers")
    func deadlineCancelsStragglers() async throws {
        weak var weakHang: FakeProvider?
        var rig: Rig? = Rig(deadlineMs: 300)
        try rig?.add("fake-a", 10.0)
        weakHang = try rig?.addHang("fake-hang")
        let out = await Self.run(try #require(rig).service, try Self.miami())
        _ = Self.succeeded(out)
        rig = nil
        _ = rig
        #expect(await Self.waitUntil { weakHang == nil })  // :1811 it ends only if it was cancelled
    }

    // C: /service/deadline/all-hang (test-service.c:1815-1840)
    @Test("/service/deadline/all-hang")
    func deadlineAllHang() async throws {
        let place = try Self.miami()
        do {
            let rig = Rig(deadlineMs: 300)
            try rig.addHang("fake-a")
            try rig.addHang("fake-b")
            let out = await Self.run(rig.service, place)
            Self.expectFailed(out, .timeout, "fake-a: no answer within 300 ms")  // :1825
            #expect(out.elapsedMs >= 300 && out.elapsedMs < 300 + 2000, "\(out.elapsedMs) ms")  // :1826-1827
        }
        do {
            let rig = Rig(deadlineMs: 300)
            try rig.add("fake-a", 10.0).failWith(.parse)
            try rig.addHang("fake-b")
            Self.expectFailed(await Self.run(rig.service, place), .timeout, "fake-b: no answer within 300 ms")  // :1836
        }
    }

    // C: /service/deadline/ignoring-provider (test-service.c:1846-1903): a
    // provider that ignores cancellation costs the deadline, not more; its late
    // deliveries are dropped and change nothing.
    @Test("/service/deadline/ignoring-provider")
    func deadlineIgnoringProvider() async throws {
        let rig = Rig(deadlineMs: 300)
        let hold = ScriptedProvider("hold-a")
        hold.set { $0.mode = .hold }
        hold.addMember(try Self.member("hold-a", 25.0))
        try rig.add(hold)
        try rig.add("fake-b", 10.0)
        let place = try Self.miami()
        let out = await Self.run(rig.service, place)
        let fc = try #require(Self.succeeded(out))
        #expect(out.elapsedMs >= 300 && out.elapsedMs < 300 + 2000, "\(out.elapsedMs) ms")  // :1861-1862
        #expect(fc.sources.count == 2)
        Self.expectStatus(fc, 0, "hold-a", .failed, .timeout, 0)  // :1864
        Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
        #expect(hold.heldCount == 1)  // :1866 the service did not wait for it
        #expect(hold.sawCancellation)  // :1868 but it was told to stop
        hold.release()  // the late delivery: a good result after the refresh is over
        await Self.drain(50)
        Self.expectStatus(fc, 0, "hold-a", .failed, .timeout, 0)  // :1875 not reopened
        for h in fc.hours {
            #expect(h.nMembers == 1)  // :1877
        }
        // a late failure and a late result are dropped as well (:1881-1902)
        let lateFail = ScriptedProvider("hold-b")
        lateFail.set {
            $0.mode = .hold
            $0.failure = WxError(.http, "late")
        }
        let lateOther = ScriptedProvider("hold-c")
        lateOther.set { $0.mode = .hold }
        lateOther.addMember(try Self.member("hold-a", 25.0))
        try rig.add(lateFail)
        try rig.add(lateOther)
        let out2 = await Self.run(rig.service, place)
        let fc2 = try #require(Self.succeeded(out2))
        #expect(fc2.sources.count == 4)
        Self.expectStatus(fc2, 2, "hold-b", .failed, .timeout, 0)  // :1895
        Self.expectStatus(fc2, 3, "hold-c", .failed, .timeout, 0)  // :1896
        lateFail.release()
        lateOther.release()
        hold.release()
        await Self.drain(50)
        Self.expectStatus(fc2, 2, "hold-b", .failed, .timeout, 0)
    }

    // C: /service/deadline/not-before-all-done (test-service.c:1906-1925)
    @Test("/service/deadline/not-before-all-done")
    func deadlineNotBeforeAllDone() async throws {
        let rig = Rig(deadlineMs: 800)  // :1908
        try rig.add("fake-a", 10.0).setDelayMs(20)
        try rig.add("fake-b", 20.0).setDelayMs(40)
        let probeCount = Locked(0)
        rig.service.completionProbe = { probeCount.set(probeCount.value + 1) }
        let out = await Self.run(rig.service, try Self.miami())
        #expect(out.elapsedMs >= 40 && out.elapsedMs < 800, "\(out.elapsedMs) ms")  // :1916-1917
        let fc = try #require(Self.succeeded(out))
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)
        Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
        await Self.drain(1000)  // :1921 well past the deadline
        #expect(probeCount.value == 1)  // :1922 the timer never completes it again
    }

    // C: /service/deadline/per-refresh (test-service.c:1928-1960)
    @Test("/service/deadline/per-refresh")
    func deadlinePerRefresh() async throws {
        let rig = Rig(deadlineMs: 300)
        try rig.add("fake-a", 10.0)
        try rig.addHang("fake-b")
        let place = try Self.miami()
        for _ in 0..<3 {
            let out = await Self.run(rig.service, place)
            let fc = try #require(Self.succeeded(out))
            #expect(out.elapsedMs >= 300 && out.elapsedMs < 300 + 2000, "\(out.elapsedMs) ms")  // :1939-1940
            Self.expectStatus(fc, 1, "fake-b", .failed, .timeout, 0)  // :1941
        }
        // the deadline is read when a refresh starts (:1944-1959)
        rig.service.testDeadlineMs = 10000
        let service = rig.service
        let task = Task { @MainActor in await Self.run(service, place) }
        await Self.drain(20)
        rig.service.testDeadlineMs = 100
        await Self.drain(400)
        let finished = Locked(false)
        let watcher = Task {
            _ = await task.value
            finished.set(true)
        }
        await Self.drain(10)
        #expect(!finished.value)  // :1953 still waiting: it keeps its 10 s
        task.cancel()
        Self.expectCancelled(await task.value)  // :1956
        _ = await watcher.value
    }

    // MARK: - Cancellation

    // C: /service/cancel/pre-cancelled (test-service.c:1963-1986)
    @Test("/service/cancel/pre-cancelled")
    func cancelPreCancelled() async throws {
        let rig = Rig()
        let a = try rig.add("fake-a", 10.0)
        let place = try Self.miami()
        Self.expectCancelled(await Self.runPreCancelled(rig.service, place))  // :1974
        #expect(a.fetchCount == 0)  // :1975 no provider was called
        // checked before anything else: no provider at all is not seen (:1983-1985)
        let empty = Rig()
        Self.expectCancelled(await Self.runPreCancelled(empty.service, place))
        // ... and the registry is not consulted: covers() is not called
        let prov = ScriptedProvider("prov-a")
        try rig.add(prov)
        Self.expectCancelled(await Self.runPreCancelled(rig.service, place))
        #expect(prov.coversCalls == 0)
    }

    // C: /service/cancel/in-flight (test-service.c:1989-2023)
    @Test("/service/cancel/in-flight")
    func cancelInFlight() async throws {
        let rig = Rig()
        let hang = try rig.addHang("fake-a")
        let hold = ScriptedProvider("hold-b")
        hold.set { $0.mode = .hold }
        try rig.add(hold)
        try rig.add("fake-c", 30.0)
        let place = try Self.miami()
        let service = rig.service
        let task = Task { @MainActor in await Self.run(service, place) }
        #expect(await Self.waitUntil { hold.heldCount == 1 })
        await Self.drain(30)
        #expect(!hold.sawCancellation)  // :2002
        task.cancel()
        let out = await task.value
        Self.expectCancelled(out)  // :2009
        #expect(out.elapsedMs < 5000)  // :2010 nowhere near the deadline
        #expect(hold.sawCancellation)  // :2011 the children were told to stop
        #expect(hang.fetchCount == 1)  // :2012
        #expect(hold.heldCount == 1)  // :2013 ... though this one never answers
        hold.release()
        await Self.drain(30)
    }

    // C: /service/cancel/after-completion (test-service.c:2035-2064): cancelled
    // after the refresh completed but before it returned -> cancelled.
    @Test("/service/cancel/after-completion")
    func cancelAfterCompletion() async throws {
        let rig = Rig()
        try rig.add("fake-a", 10.0)
        let place = try Self.miami()
        let service = rig.service
        let box = Locked<Task<Outcome, Never>?>(nil)
        let completed = Locked(false)
        service.completionProbe = {
            completed.set(true)
            box.value?.cancel()  // between completion and the return (C: before finish)
        }
        let task = Task { @MainActor in
            await Self.drain(20)  // the box is filled before the refresh starts
            return await Self.run(service, place)
        }
        box.set(task)
        Self.expectCancelled(await task.value)  // :2046-2047
        #expect(completed.value)  // the refresh had completed
        // without the cancellation the same refresh delivers its forecast (:2051-2063)
        service.completionProbe = nil
        _ = Self.succeeded(await Self.run(service, place))
    }

    // C: /service/cancel/ignoring-provider (test-service.c:2067-2088)
    @Test("/service/cancel/ignoring-provider")
    func cancelIgnoringProvider() async throws {
        let rig = Rig()
        let hold = ScriptedProvider("hold-a")
        hold.set { $0.mode = .hold }
        hold.addMember(try Self.member("hold-a", 20.0))
        try rig.add(hold)
        let place = try Self.miami()
        let service = rig.service
        let task = Task { @MainActor in await Self.run(service, place) }
        #expect(await Self.waitUntil { hold.heldCount == 1 })
        task.cancel()
        let out = await task.value
        Self.expectCancelled(out)  // :2079
        #expect(out.elapsedMs < 5000)  // :2080
        hold.release()  // delivered late, dropped
        await Self.drain(30)
    }

    // C: /service/cancel/from-thread (test-service.c:2100-2115): cancelling from
    // another thread is safe and the refresh ends on the main actor.
    @Test("/service/cancel/from-thread")
    func cancelFromThread() async throws {
        let rig = Rig()
        try rig.addHang("fake-a")
        let place = try Self.miami()
        let service = rig.service
        let onMain = Locked(false)
        let task = Task { @MainActor in
            let out = await Self.run(service, place)
            onMain.set(pthread_main_np() != 0)
            return out
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(40)) { task.cancel() }  // :2091-2096
        Self.expectCancelled(await task.value)  // :2113
        #expect(onMain.value)  // :2114
    }

    // C: /service/cancel/deadline-leaves-caller-alone (test-service.c:2118-2139)
    @Test("/service/cancel/deadline-leaves-caller-alone")
    func cancelDeadlineLeavesCallerAlone() async throws {
        let rig = Rig(deadlineMs: 300)
        try rig.add("fake-a", 10.0)
        try rig.addHang("fake-b")
        let place = try Self.miami()
        let service = rig.service
        let task = Task { @MainActor () -> (Outcome, Bool) in
            let out = await Self.run(service, place)
            return (out, Task.isCancelled)
        }
        let (out, callerCancelled) = await task.value
        let fc = try #require(Self.succeeded(out))
        Self.expectStatus(fc, 1, "fake-b", .failed, .timeout, 0)  // :2131
        #expect(!callerCancelled)  // :2132
        // the same caller serves another refresh (:2134-2137)
        let again = await Task { @MainActor in await Self.run(service, place) }.value
        _ = Self.succeeded(again)
    }

    // MARK: - Dispose in flight

    // C: /service/dispose/last-reference (test-service.c:2151-2173)
    @Test("/service/dispose/last-reference")
    func disposeLastReference() async throws {
        weak var weakService: ServiceOrchestrator?
        var rig: Rig? = Rig()
        try rig?.add("fake-a", 10.0).setDelayMs(40)
        try rig?.add("fake-b", 30.0).setDelayMs(60)
        let place = try Self.miami()
        let task: Task<Outcome, Never>
        do {
            let service = try #require(rig?.service)
            weakService = service
            task = Task { @MainActor [service] in await Self.run(service, place) }
        }
        rig = nil  // the service, the registry and the fakes lose the caller's references
        _ = rig
        #expect(weakService != nil)  // :2165 the operation keeps the service alive ...
        let fc = try #require(Self.succeeded(await task.value))
        Self.expectStatus(fc, 0, "fake-a", .ok, nil, 1)  // :2168-2169
        Self.expectStatus(fc, 1, "fake-b", .ok, nil, 1)
        #expect(await Self.waitUntil { weakService == nil })  // :2171 ... and lets go afterwards
    }

    // C: /service/dispose/late-completion (test-service.c:2203-2228): the
    // service goes away while a provider still owes its answer.
    @Test("/service/dispose/late-completion")
    func disposeLateCompletion() async throws {
        weak var weakService: ServiceOrchestrator?
        let hold = ScriptedProvider("hold-a")
        hold.set { $0.mode = .hold }
        hold.addMember(try Self.member("hold-a", 25.0))
        do {
            let rig = Rig(deadlineMs: 300)
            try rig.add(hold)
            try rig.add("fake-b", 10.0)
            weakService = rig.service
            _ = Self.succeeded(await Self.run(rig.service, try Self.miami()))
        }
        #expect(await Self.waitUntil { weakService == nil })  // :2223 the service is gone ...
        #expect(hold.heldCount == 1)  // :2224 ... the provider still owes its answer
        hold.release()
        await Self.drain(50)
    }

    // C: /service/dispose/registry-dropped (test-service.c:2231-2253)
    @Test("/service/dispose/registry-dropped")
    func disposeRegistryDropped() async throws {
        var registry: WxRegistry? = WxRegistry()
        let fake = FakeProvider(id: "fake-a")
        fake.addMember(try Self.member("fake-a", 10.0))
        fake.setDelayMs(40)
        try registry?.addProvider(fake)
        let service = ServiceOrchestrator(registry: try #require(registry))
        let place = try Self.miami()
        let task = Task { @MainActor in await Self.run(service, place) }
        registry = nil
        _ = registry
        _ = Self.succeeded(await task.value)  // :2246
        _ = Self.succeeded(await Self.run(service, place))  // :2249 the registry lives on inside
    }

    // MARK: - Re-entrancy

    // C: /service/reentrancy/refresh-from-callback (test-service.c:2273-2297):
    // the next refresh starts as soon as the previous one returned, five in a row.
    @Test("/service/reentrancy/refresh-from-callback")
    func reentrancyRefreshFromCallback() async throws {
        let rig = Rig()
        try rig.add("fake-a", 10.0)
        try rig.add("fake-b", 20.0)
        let place = try Self.miami()
        for _ in 0..<5 {
            _ = Self.succeeded(await Self.run(rig.service, place))  // :2292-2295
        }
    }

    // C: /service/reentrancy/drop-service-in-callback (test-service.c:2312-2350)
    @Test("/service/reentrancy/drop-service-in-callback")
    func reentrancyDropServiceInCallback() async throws {
        let place = try Self.miami()
        do {
            weak var weakService: ServiceOrchestrator?
            do {
                let registry = WxRegistry()
                let fake = FakeProvider(id: "fake-a")
                fake.addMember(try Self.member("fake-a", 10.0))
                try registry.addProvider(fake)
                let service = ServiceOrchestrator(registry: registry)
                weakService = service
                _ = Self.succeeded(await Self.run(service, place))  // :2331
            }
            #expect(await Self.waitUntil { weakService == nil })  // :2332
        }
        do {
            weak var weakService: ServiceOrchestrator?
            do {
                let registry = WxRegistry()
                let hang = FakeProvider(id: "fake-h")
                hang.setDelayMs(UInt32.max)
                try registry.addProvider(hang)
                let service = ServiceOrchestrator(registry: registry)
                service.testDeadlineMs = 100  // :2336
                weakService = service
                let out = await Self.run(service, place)
                #expect((out.error as? WxError)?.code == .timeout)  // :2347
            }
            #expect(await Self.waitUntil { weakService == nil })  // :2348
        }
    }

    // C: /service/reentrancy/registry-changes-in-covers (test-service.c:2364-2393)
    @Test("/service/reentrancy/registry-changes-in-covers")
    func reentrancyRegistryChangesInCovers() async throws {
        let rig = Rig()
        let a = ScriptedProvider("prov-a")
        let b = ScriptedProvider("prov-b")
        a.addMember(try Self.member("prov-a", 10.0))
        b.addMember(try Self.member("prov-b", 20.0))
        let c = FakeProvider(id: "fake-c")
        c.addMember(try Self.member("fake-c", 30.0))
        a.set {
            $0.onCovers = { [rig] prov in  // covers_changes_registry (:2353-2361)
                guard prov.coversCalls == 1 else { return }
                #expect(rig.registry.setEnabled(false, id: "prov-b"))
                do {
                    try rig.registry.addProvider(c)
                } catch {
                    Issue.record("addProvider in covers(): \(error)")
                }
            }
        }
        try rig.add(a)
        try rig.add(b)
        let fc = try #require(Self.succeeded(await Self.run(rig.service, try Self.miami())))
        #expect(fc.sources.count == 3)  // :2382
        Self.expectStatus(fc, 0, "prov-a", .ok, nil, 1)  // :2383-2385
        Self.expectStatus(fc, 1, "prov-b", .skipped, nil, 0)
        Self.expectStatus(fc, 2, "fake-c", .ok, nil, 1)
        #expect(a.fetches == 1 && b.fetches == 0 && b.coversCalls == 0)  // :2386-2388
        #expect(c.fetchCount == 1)  // :2389
    }

    // C: /service/reentrancy/synchronous-provider (test-service.c:2396-2463):
    // providers that answer without suspending are handled like any other.
    @Test("/service/reentrancy/synchronous-provider")
    func reentrancySynchronousProvider() async throws {
        let place = try Self.miami()
        do {
            let rig = Rig()
            let sync = ScriptedProvider("sync-a")
            sync.addMember(try Self.member("sync-a", 10.0))
            try rig.add(sync)
            let slow = ScriptedProvider("hold-b")
            slow.set { $0.mode = .hold }
            slow.addMember(try Self.member("hold-b", 30.0))
            try rig.add(slow)
            let service = rig.service
            let task = Task { @MainActor in await Self.run(service, place) }
            #expect(await Self.waitUntil { slow.heldCount == 1 })  // :2414-2415
            #expect(sync.fetches == 1)
            await Self.drain(20)
            slow.release()
            let out = await task.value
            let fc = try #require(Self.succeeded(out))
            #expect(out.elapsedMs < 5000)  // :2423 not at the 30 s deadline
            Self.expectStatus(fc, 0, "sync-a", .ok, nil, 1)  // :2424-2425
            Self.expectStatus(fc, 1, "hold-b", .ok, nil, 1)
        }
        do {
            let rig = Rig()
            let s1 = ScriptedProvider("sync-a")
            let s2 = ScriptedProvider("sync-b")
            let s3 = ScriptedProvider("sync-c")
            s1.addMember(try Self.member("sync-a", 10.0))
            s3.addMember(try Self.member("sync-c", 30.0))
            s2.set { $0.failure = WxError(.http, "sync failure") }
            for p in [s1, s2, s3] {
                try rig.add(p)
            }
            let out = await Self.run(rig.service, place)
            let fc = try #require(Self.succeeded(out))
            #expect(out.elapsedMs < 5000)
            Self.expectStatus(fc, 0, "sync-a", .ok, nil, 1)  // :2446-2448
            Self.expectStatus(fc, 1, "sync-b", .failed, .http, 0)
            Self.expectStatus(fc, 2, "sync-c", .ok, nil, 1)
        }
        do {
            let rig = Rig()
            let s1 = ScriptedProvider("sync-a")
            s1.set { $0.failure = WxError(.parse, "bad") }
            try rig.add(s1)
            let out = await Self.run(rig.service, place)
            Self.expectFailed(out, .parse, "sync-a: bad")  // :2459
            #expect(out.elapsedMs < 5000)
        }
    }

    // C: /service/reentrancy/cancel-during-start (test-service.c:2479-2507): a
    // provider that cancels the caller from inside its fetch: the refresh is
    // cancelled and the provider's answer is dropped. (Whether a later
    // provider was started depends on C's nested main-loop iteration inside
    // fetch_async, which a Swift fetch cannot perform: not ported.)
    @Test("/service/reentrancy/cancel-during-start")
    func reentrancyCancelDuringStart() async throws {
        let rig = Rig()
        let box = Locked<Task<Outcome, Never>?>(nil)
        let first = ScriptedProvider("prov-a")
        first.addMember(try Self.member("prov-a", 10.0))
        first.set { $0.onFetch = { _ in box.value?.cancel() } }  // cancel_and_spin (:2466-2475)
        try rig.add(first)
        try rig.add("fake-b", 20.0)
        let place = try Self.miami()
        let service = rig.service
        let task = Task { @MainActor in
            await Self.drain(20)
            return await Self.run(service, place)
        }
        box.set(task)
        Self.expectCancelled(await task.value)  // :2497
        #expect(first.fetches == 1)  // :2498
    }

    // C: /service/reentrancy/refresh-from-provider (test-service.c:2523-2553)
    @Test("/service/reentrancy/refresh-from-provider")
    func reentrancyRefreshFromProvider() async throws {
        let rig = Rig()
        let first = ScriptedProvider("prov-a")
        first.addMember(try Self.member("prov-a", 10.0))
        let place = try Self.miami()
        let service = rig.service
        let inner = Locked<Task<Outcome, Never>?>(nil)
        first.set {
            $0.onFetch = { prov in  // start_nested_refresh (:2513-2520)
                guard prov.fetches == 1 else { return }
                let t = Task { @MainActor in await Self.run(service, place) }
                inner.set(t)
            }
        }
        try rig.add(first)
        try rig.add("fake-b", 20.0)
        let outer = await Self.run(service, place)
        let innerTask = try #require(inner.value)
        let innerOut = await innerTask.value
        let fo = try #require(Self.succeeded(outer))  // :2545-2546
        let fi = try #require(Self.succeeded(innerOut))
        #expect(first.fetches == 2)  // :2547
        #expect(fo.sources.count == 2 && fi.sources.count == 2)  // :2548-2549
    }

    // MARK: - Random scenarios against an independent model

    enum Kind: CaseIterable {
        case ok, short, fail, empty, cancelled, hangFake, hangIgnore
    }

    struct FuzzProv {
        var kind: Kind
        var enabled: Bool
        var covers: Bool
        var code: WxError.Code
        var delayMs: UInt32
        var id: String
        var prov: ScriptedProvider?
        var member: WxMember?
    }

    /// pick_kind (test-service.c:4091-4108) with the same odds; C's
    /// K_NULL_RESULT (8 %, "NULL without an error") cannot be produced by a
    /// Swift provider and is drawn again.
    static func pickKind(_ rng: inout SeededRNG, allowHang: Bool) -> Kind {
        while true {
            let roll = Int.random(in: 0..<100, using: &rng)
            if roll < 34 { return .ok }
            if roll < 42 { return .short }
            if roll < 64 { return .fail }
            if roll < 72 { return .empty }
            if roll < 79 { return .cancelled }
            if roll < 86 && allowHang { return .hangFake }
            if roll < 92 && roll >= 86 && allowHang { return .hangIgnore }
        }
    }

    static let fuzzDeadlineMs: UInt32 = 250  // FUZZ_DEADLINE_MS, test-service.c:4107

    /// The delays of fuzz_build (test-service.c:4121).
    static let fuzzDelays: [UInt32] = [0, 0, 0, 5, 15]

    // C: /service/refresh/random-scenarios (test-service.c:4268-4312) with the
    // model fuzz_check (:4171-4265); SeededRNG replaces g_test_rand.
    @Test("/service/refresh/random-scenarios")
    func randomScenarios() async throws {
        var rng = SeededRNG(seed: 0x5E2_1CE5)
        let nScenarios = TestEnvironment.slowTestsEnabled ? 3000 : 300  // :4270
        var hangBudget = TestEnvironment.slowTestsEnabled ? 100 : 20  // :4271
        let place = try Self.miami()
        for _ in 0..<nScenarios {
            let rig = Rig()
            var provs: [FuzzProv] = []
            let n = Int.random(in: 0..<7, using: &rng)
            var hangs = false
            for i in 0..<n {  // fuzz_build (:4112-4168)
                var p = FuzzProv(
                    kind: Self.pickKind(&rng, allowHang: hangBudget > 0),
                    enabled: Int.random(in: 0..<100, using: &rng) < 85,
                    covers: Int.random(in: 0..<100, using: &rng) < 85,
                    code: Self.allCodes[Int.random(in: 0..<Self.allCodes.count, using: &rng)],
                    delayMs: Self.fuzzDelays[Int.random(in: 0..<Self.fuzzDelays.count, using: &rng)], id: "p\(i)")
                switch p.kind {
                case .ok, .short, .fail, .hangFake:
                    let member = try Self.member(p.id, "m", 10.0 + Double(i), hours: p.kind == .short ? 3 : 48)
                    p.member = member
                    let fake = try rig.add(p.id, member: member)
                    fake.setCovers(p.covers)
                    fake.setDelayMs(p.kind == .hangFake ? UInt32.max : p.delayMs)
                    if p.kind == .fail {
                        fake.failWith(p.code)
                    }
                case .empty:
                    let fake = FakeProvider(id: p.id)
                    fake.setCovers(p.covers)
                    fake.setDelayMs(p.delayMs)
                    try rig.add(fake)
                case .cancelled, .hangIgnore:
                    let prov = ScriptedProvider(p.id)
                    let (covers, delayMs, kind) = (p.covers, p.delayMs, p.kind)
                    prov.set {
                        $0.covers = covers
                        $0.mode = kind == .hangIgnore ? .hold : .answer(delayMs: delayMs)
                        if kind == .cancelled {
                            $0.failure = CancellationError()
                        }
                    }
                    p.prov = prov
                    try rig.add(prov)
                }
                if !p.enabled {
                    #expect(rig.registry.setEnabled(false, id: p.id))
                }
                if p.enabled && p.covers && (p.kind == .hangFake || p.kind == .hangIgnore) {
                    hangs = true
                }
                provs.append(p)
            }
            if hangs {
                hangBudget -= 1
            }
            let deadlineMs = hangs ? Self.fuzzDeadlineMs : ServiceOrchestrator.deadlineMs
            rig.service.testDeadlineMs = hangs ? Self.fuzzDeadlineMs : 0
            let out = await Self.run(rig.service, place)
            Self.fuzzCheck(provs, out, place, deadlineMs)
            if hangs {
                #expect(out.elapsedMs >= Int64(Self.fuzzDeadlineMs))  // :4294
            }
            for p in provs {
                p.prov?.release()  // late deliveries
            }
        }
    }

    /// fuzz_check (test-service.c:4171-4265).
    static func fuzzCheck(_ provs: [FuzzProv], _ out: Outcome, _ place: WxPlace, _ deadlineMs: UInt32) {
        var want: [(state: WxSourceState, code: WxError.Code?, n: UInt32)] = []
        var results: [WxSourceResult] = []
        var anyFetched = false
        var anyCounted = false
        var anyFull = false
        var bestRank = Int.max
        var best: (code: WxError.Code, message: String)?
        for p in provs {
            var w: (state: WxSourceState, code: WxError.Code?, n: UInt32) = (.skipped, nil, 0)
            defer { want.append(w) }
            if !p.enabled || !p.covers {
                continue
            }
            anyFetched = true
            var fail: (code: WxError.Code, text: String)?
            switch p.kind {
            case .ok, .short:
                w = (.ok, nil, 1)
                anyCounted = true
                anyFull = anyFull || p.kind == .ok
                if let member = p.member, let r = try? result(p.id, [member]) {
                    results.append(r)
                }
            case .fail:
                fail = (p.code, "\(p.id): scripted failure")  // :4205
                w = p.code == .unsupported ? (.skipped, nil, 0) : (.failed, p.code, 0)
            case .empty:
                w = (.failed, .notFound, 0)
                fail = (.notFound, "\(p.id): the provider returned no forecast data")  // :4216
            case .cancelled:
                w = (.failed, nil, 0)  // no code and no candidate for the error
            case .hangFake, .hangIgnore:
                w = (.failed, .timeout, 0)
                fail = (.timeout, "\(p.id): no answer within \(deadlineMs) ms")
            }
            if let fail, codeRank(fail.code) < bestRank {
                bestRank = codeRank(fail.code)
                best = (fail.code, fail.text)
            }
        }
        if !anyFetched {
            expectFailed(out, .unsupported, "no enabled data source covers this place")  // :4246
        } else if anyFull {
            guard let fc = succeeded(out) else { return }
            #expect(fc.sources.count == provs.count)
            for (i, p) in provs.enumerated() {
                expectStatus(fc, i, p.id, want[i].state, want[i].code, want[i].n)
            }
            expectMatchesOracle(fc, place, results)  // :4253
        } else if anyCounted && codeRank(.notFound) < bestRank {
            expectFailed(out, .notFound, "no usable forecast data")  // :4257
        } else if let best {
            expectFailed(out, best.code, best.message)
        } else {
            expectCancelled(out)  // nobody failed except by cancelling
        }
    }

    // MARK: - Search

    // C: /service/search/ok (test-service.c:3639-3675)
    @Test("/service/search/ok")
    func searchOK() async throws {
        let rig = Rig()
        let geo = FakeGeocoder()
        let names = ["Miami", "Orlando", "Tampa"]
        for (i, name) in names.enumerated() {
            geo.addHit(try Self.place(name, 25.0 + Double(i), -80.0 - Double(i), "America/New_York"))
        }
        rig.registry.geocoder = geo
        let hits = try await rig.service.search("Mia")
        #expect(hits.map(\.name) == names)  // :3655-3659
        #expect(hits.map(\.lat) == [25.0, 26.0, 27.0])
        #expect(geo.searchCount == 1)  // :3660
        rig.registry.geocoder = FakeGeocoder()
        #expect(try await rig.service.search("Nowhere").isEmpty)  // :3668-3672 no hit: empty, no error
    }

    // C: /service/search/pass-through (test-service.c:3678-3711)
    @Test("/service/search/pass-through")
    func searchPassThrough() async throws {
        let rig = Rig()
        let geo = ScriptedGeocoder()
        let two = [
            try Self.place("Miami", 25.7617, -80.1918, "America/New_York"),
            try Self.place("Orlando", 28.5383, -81.3792, "America/New_York"),
        ]  // make_two_hits (:3629-3636)
        geo.set { $0.hits = two }
        rig.registry.geocoder = geo
        let text: [UInt8] = [0x20, 0x20, 0x4D, 0x69, 0xC3, 0xA1, 0x6D, 0x69, 0x2C, 0x20, 0x46, 0x4C, 0x20, 0x09]  // :3685
        let hits = try await rig.service.search(textBytes: text)
        #expect(hits.count == 2)  // :3693
        #expect(geo.lastText == text)  // :3694 not trimmed, not validated
        #expect(geo.searches == 1)  // :3696
        // the geocoder replaced after the call is not the one that was asked (:3700-3710)
        let later = ScriptedGeocoder()
        later.set {
            $0.hits = two
            $0.delayMs = 40
        }
        geo.set { $0.delayMs = 40 }
        let service = rig.service
        let task = Task { @MainActor in try await service.search("again") }
        await Self.drain(10)
        rig.registry.geocoder = later
        #expect(try await task.value.count == 2)
        #expect(geo.searches == 2)  // :3708
        #expect(later.searches == 0)  // :3709
    }

    // C: /service/search/pass-through, the cancellable half: the geocoder runs in
    // the caller's task and so sees the caller's cancellation (C passes the
    // caller's cancellable on unchanged, test-service.c:3695).
    @Test("/service/search/pass-through (caller's cancellation reaches the geocoder)")
    func searchCancellationPassedOn() async throws {
        let rig = Rig()
        let geo = FakeGeocoder()
        geo.addHit(try Self.miami())
        geo.setDelayMs(10000)
        rig.registry.geocoder = geo
        let service = rig.service
        let start = ContinuousClock.now
        let task = Task { @MainActor in try await service.search("Miami") }
        #expect(await Self.waitUntil { geo.searchCount == 1 })
        task.cancel()
        let result = await task.result
        #expect((try? result.get()) == nil)
        if case .failure(let error) = result {
            #expect(error is CancellationError)
        }
        #expect(Self.milliseconds(start.duration(to: .now)) < 5000)  // the fake honoured it
    }

    // C: /service/search/no-geocoder (test-service.c:3714-3738)
    @Test("/service/search/no-geocoder")
    func searchNoGeocoder() async throws {
        let rig = Rig()
        await #expect(throws: WxError(.unsupported, "no geocoder is registered")) {  // :3721-3722
            try await rig.service.search("Miami")
        }
        let geo = FakeGeocoder()
        rig.registry.geocoder = geo
        _ = try await rig.service.search("Miami")  // :3728
        rig.registry.geocoder = nil
        await #expect(throws: WxError(.unsupported, "no geocoder is registered")) {
            try await rig.service.search("Miami")
        }
        #expect(geo.searchCount == 1)  // :3736
    }

    // C: /service/search/errors (test-service.c:3741-3799), without WX_ERROR code
    // 99 (not a WxError.Code) and the NULL answer (a geocoder returns an array).
    @Test("/service/search/errors")
    func searchErrors() async throws {
        let rig = Rig()
        let geo = FakeGeocoder()
        rig.registry.geocoder = geo
        for code in Self.allCodes {
            geo.failWith(code)
            await #expect(throws: WxError(code, "scripted failure")) {  // :3751-3753 no prefix
                try await rig.service.search("Miami")
            }
        }
        let odd = ScriptedGeocoder()
        rig.registry.geocoder = odd
        odd.set { $0.failure = ForeignError(text: "no such thing") }  // :3760
        await #expect(throws: WxError(.network, "no such thing")) {  // :3763-3764
            try await rig.service.search("Miami")
        }
        odd.set { $0.failure = CancellationError() }  // :3776 "gave up"
        await #expect(throws: CancellationError.self) {  // :3779
            try await rig.service.search("Miami")
        }
        // "ba\x07\xff" "d\xE2\x80\xAE!" (:3783) -> "ba\xEF\xBF\xBD" "d!" (:3787)
        let hostile = String(decoding: [0x62, 0x61, 0x07, 0xFF, 0x64, 0xE2, 0x80, 0xAE, 0x21] as [UInt8], as: UTF8.self)
        let want = String(decoding: [0x62, 0x61, 0xEF, 0xBF, 0xBD, 0x64, 0x21] as [UInt8], as: UTF8.self)
        odd.set { $0.failure = ForeignError(text: hostile) }
        await #expect(throws: WxError(.network, want)) {
            try await rig.service.search("Miami")
        }
    }

    // C: /service/search/invalid-text (test-service.c:3802-3819)
    @Test("/service/search/invalid-text")
    func searchInvalidText() async throws {
        let rig = Rig()
        let geo = FakeGeocoder()
        rig.registry.geocoder = geo
        let texts: [[UInt8]] = [[], [0x20], [UInt8](repeating: 0x61, count: 65), [0x61, 0x01, 0x62], [0xFF]]  // :3808
        for text in texts {
            await #expect(throws: WxError(.invalidArg, "invalid search text")) {  // :3813-3815
                try await rig.service.search(textBytes: text)
            }
        }
        #expect(geo.searchCount == texts.count)  // :3818
    }

    // C: /service/search/cancel (test-service.c:3822-3862)
    @Test("/service/search/cancel")
    func searchCancel() async throws {
        let rig = Rig()
        let geo = FakeGeocoder()
        geo.addHit(try Self.miami())
        rig.registry.geocoder = geo
        let service = rig.service
        let pre = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.capture { try await service.search("Miami") }
        }.value
        #expect(throws: CancellationError.self) { try pre.get() }  // :3832
        #expect(geo.searchCount == 0)  // :3833 the geocoder was not asked
        // in flight (:3836-3846)
        geo.setDelayMs(10000)
        let start = ContinuousClock.now
        let task = Task { @MainActor in try await service.search("Miami") }
        await Self.drain(20)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.milliseconds(start.duration(to: .now)) < 5000)  // :3845
        // cancelled after the geocoder answered but before search returned (:3848-3861)
        let late = ScriptedGeocoder()
        let hit = try Self.miami()
        late.set {
            $0.hits = [hit]
            $0.cancelCallerBeforeAnswer = true
        }
        rig.registry.geocoder = late
        let after = await Task { @MainActor in await Self.capture { try await service.search("Miami") } }.value
        #expect(throws: CancellationError.self) { try after.get() }  // :3858-3859
        #expect(late.searches == 1)
    }

    // C: /service/search/hostile-hits (test-service.c:3884-3919): the cap of
    // WxLimits.geocoderMaxHits (NULL and invalid hits cannot be returned).
    @Test("/service/search/hostile-hits")
    func searchHostileHits() async throws {
        let rig = Rig()
        let geo = ScriptedGeocoder()
        rig.registry.geocoder = geo
        func cities(_ nValid: Int) throws -> [WxPlace] {  // make_hostile_hits without the bad ones
            try (0...nValid).map { i in
                try Self.place("City\(i)", 25.0 + Double(i) * 0.01, -80.0, "America/New_York")
            }
        }
        let many = try cities(24)
        geo.set { $0.hits = many }
        let hits = try await rig.service.search("City")
        #expect(hits.count == WxLimits.geocoderMaxHits)  // :3898
        #expect(hits.map(\.name) == (0..<20).map { "City\($0)" })  // :3899-3902
        let few = try cities(2)
        geo.set { $0.hits = few }
        let fewer = try await rig.service.search("City")
        #expect(fewer.count == 3)  // :3908
        #expect(fewer.last?.name == "City2")  // :3909
    }

    // C: /service/search/geocoder-replaced (test-service.c:3930-3951): a
    // geocoder removed from the registry while it runs is kept alive.
    @Test("/service/search/geocoder-replaced")
    func searchGeocoderReplaced() async throws {
        let rig = Rig()
        weak var weakGeo: ScriptedGeocoder?
        do {
            let geo = ScriptedGeocoder()
            let two = [
                try Self.place("Miami", 25.7617, -80.1918, "America/New_York"),
                try Self.place("Orlando", 28.5383, -81.3792, "America/New_York"),
            ]
            let registry = rig.registry
            geo.set {
                $0.hits = two
                $0.onSearch = { registry.geocoder = nil }  // replace_geocoder (:3922-3927)
            }
            rig.registry.geocoder = geo
            weakGeo = geo
        }
        let hits = try await rig.service.search("Miami")
        #expect(hits.count == 2)  // :3946
        #expect(rig.registry.geocoder == nil)  // :3947
        #expect(await Self.waitUntil { weakGeo == nil })  // :3948
    }

    // C: /service/search/dispose-in-flight (test-service.c:3954-3974)
    @Test("/service/search/dispose-in-flight")
    func searchDisposeInFlight() async throws {
        weak var weakService: ServiceOrchestrator?
        var rig: Rig? = Rig()
        let geo = ScriptedGeocoder()
        let hit = try Self.miami()
        geo.set {
            $0.hits = [hit]
            $0.delayMs = 40
        }
        rig?.registry.geocoder = geo
        let task: Task<[WxPlace], any Error>
        do {
            let service = try #require(rig?.service)
            weakService = service
            task = Task { @MainActor [service] in try await service.search("Miami") }
        }
        rig = nil  // the caller lets go of everything in flight
        _ = rig
        #expect(weakService != nil)
        #expect(try await task.value.count == 1)  // the search still completes
        #expect(await Self.waitUntil { weakService == nil })
    }

    // C: /service/finish/errors (test-service.c:4001-4060), the behavioural part:
    // a refresh and a search of one service in flight together both succeed.
    @Test("/service/finish/errors")
    func finishErrors() async throws {
        let rig = Rig()
        try rig.add("fake-a", 10.0)
        let geo = FakeGeocoder()
        geo.addHit(try Self.miami())
        rig.registry.geocoder = geo
        let service = rig.service
        let place = try Self.miami()
        async let refreshed = Self.run(service, place)
        async let found = Self.capture { try await service.search("Miami") }
        _ = Self.succeeded(await refreshed)  // :4047-4050
        #expect((try? await found.get())?.count == 1)  // :4051-4054
    }

    // MARK: - Production flavour (test-service-production.c)

    /// MuteProvider (test-service-production.c:83-205): never answers and
    /// ignores its cancellation; released, it answers late with an error.
    final class MuteProvider: WxProvider {
        let id = "mute-silent"
        let name = "Mute"
        let attribution = "Mute data"
        let attributionURL = "https://example.invalid/"
        let state = Mutex((held: [CheckedContinuation<Void, Never>](), sawCancellation: false))

        var heldCount: Int { state.withLock { $0.held.count } }
        var sawCancellation: Bool { state.withLock { $0.sawCancellation } }

        func covers(_ place: WxPlace) -> Bool { true }

        func fetch(_ place: WxPlace) async throws -> WxSourceResult {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.held.append(c) }
                }
            } onCancel: {
                state.withLock { $0.sawCancellation = true }
            }
            throw WxError(.network, "late answer")  // mute_provider_release (:200-210)
        }

        func release() {
            let held = state.withLock { s in
                let h = s.held
                s.held = []
                return h
            }
            for c in held {
                c.resume()
            }
        }
    }

    // C: /service-production/smoke (test-service-production.c:320-358)
    @Test("/service-production/smoke")
    func productionSmoke() async throws {
        let registry = WxRegistry()
        let a = FakeProvider(id: "fake-a")
        let b = FakeProvider(id: "fake-b")
        a.addMember(try Self.member("fake-a", 10.0))
        b.addMember(try Self.member("fake-b", 30.0))
        try registry.addProvider(a)
        try registry.addProvider(b)
        let geo = FakeGeocoder()
        let place = try Self.miami()
        geo.addHit(place)
        registry.geocoder = geo
        let service = ServiceOrchestrator(registry: registry)
        let out = await Self.run(service, place)
        let fc = try #require(Self.succeeded(out))
        #expect(out.elapsedMs < 5000)  // :345
        #expect(fc.sources.count == 2)  // :348
        #expect(fc.sources[0].state == .ok && fc.sources[1].state == .ok)  // :349-350
        #expect(try await service.search("Miami").count == 1)  // :356
    }

    // C: /service-production/real-deadline (test-service-production.c:258-317):
    // the production service (public init, SystemClock, 30 s) completes at the
    // real deadline with the answering provider's forecast; both silent
    // providers time out, both were told to stop, the mute one's late answer
    // is harmless and nothing keeps it alive.
    @Test("/service-production/real-deadline")
    func productionRealDeadline() async throws {
        weak var weakMute: MuteProvider?
        do {
            let mute = MuteProvider()
            weakMute = mute
            let registry = WxRegistry()
            let good = FakeProvider(id: "fake-good")
            let silent = FakeProvider(id: "fake-silent")
            good.addMember(try Self.member("fake-good", 20.0))
            silent.setDelayMs(UInt32.max)  // :271 never, within the test
            try registry.addProvider(good)
            try registry.addProvider(silent)
            try registry.addProvider(mute)
            let service = ServiceOrchestrator(registry: registry)
            let out = await Self.run(service, try Self.miami(), limitMs: 40000)
            let fc = try #require(Self.succeeded(out))
            #expect(out.elapsedMs >= Int64(ServiceOrchestrator.deadlineMs))  // :287
            #expect(out.elapsedMs < Int64(ServiceOrchestrator.deadlineMs) + 3000)  // :288
            #expect(fc.sources.count == 3)  // :291
            Self.expectStatus(fc, 0, "fake-good", .ok, nil, 1)  // :292-294
            Self.expectStatus(fc, 1, "fake-silent", .failed, .timeout, 0)  // :295-297
            #expect(silent.fetchCount == 1)  // :298
            Self.expectStatus(fc, 2, "mute-silent", .failed, .timeout, 0)  // :299-302
            #expect(mute.heldCount == 1)  // :303 it never answered ...
            #expect(mute.sawCancellation)  // :305 ... though it was told to stop
            mute.release()
            await Self.drain(50)
        }
        #expect(await Self.waitUntil { weakMute == nil })  // :316 nothing still holds the provider
    }
}
