// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RegistryTests.swift - port of src/net/test-registry.c: the WxProvider /
// WxGeocoder protocols, WxRegistry and the test fakes (Support/FakeProvider).
// Every test names its C g_test_add path; expected values are the C test's
// literals (test-registry.c:LINE) or, for error messages the C test does not
// check, the C source literals (wx-registry.c:LINE, wx-fake-provider.c:LINE).
//
// Not ported (GLib-only behaviour; see the U14 debrief): the g_return_*
// criticals of /registry/interfaces/dispatch, /registry/programmer-errors and
// /registry/fake/programmer-errors (NULL receivers, missing vtable entries,
// out-of-range codes and non-geocoder objects do not type-check in Swift),
// /registry/after-dispose (no g_object_run_dispose in Swift) and
// /registry/fake/dropped-in-flight (`self` is retained for the whole call by
// the language).

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RegistryTests {
    // MARK: - Helpers

    /// make_place (test-registry.c:28-33).
    private static func makePlace(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
        try WxPlace(
            name: name, admin1: "Florida", country: "United States", countryCode: "US", lat: lat, lon: lon,
            timezone: "America/New_York")
    }

    /// make_member (test-registry.c:35-46): fetched 1791676800, one hour at
    /// 1791676800 with 25.0 degC.
    private static func makeMember(_ source: String, _ model: String) throws -> WxMember {
        var member = try WxMember(sourceID: source, modelID: model, fetchedS: 1_791_676_800)
        var hour = WxHour()
        hour.tS = 1_791_676_800
        hour.tempC = 25.0
        let added = member.addHour(hour)
        #expect(added)  // test-registry.c:44
        return member
    }

    private static var miami: WxPlace {
        get throws { try makePlace("Miami", 25.7617, -80.1918) }
    }

    /// What a call ended with (the Outcome struct of test-registry.c:48-54).
    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case wx(WxError)
        case cancelled
        case other(String)

        init(_ result: Result<T, any Error>) {
            switch result {
            case .success(let value): self = .value(value)
            case .failure(let error as WxError): self = .wx(error)
            case .failure(is CancellationError): self = .cancelled
            case .failure(let error): self = .other(String(describing: error))
            }
        }

        var value: T? {
            if case .value(let value) = self { return value }
            return nil
        }

        var code: WxError.Code? {
            if case .wx(let error) = self { return error.code }
            return nil
        }

        var isCancelled: Bool {
            if case .cancelled = self { return true }
            return false
        }
    }

    private static func fetch(_ provider: any WxProvider, _ place: WxPlace) async -> Outcome<WxSourceResult> {
        do {
            return .value(try await provider.fetch(place))
        } catch {
            return Outcome(.failure(error))
        }
    }

    private static func search(_ geocoder: any WxGeocoder, _ bytes: [UInt8]) async -> Outcome<[WxPlace]> {
        do {
            return .value(try await geocoder.search(textBytes: bytes))
        } catch {
            return Outcome(.failure(error))
        }
    }

    /// Counts change notifications (on_changed, test-registry.c:97-103).
    private final class Counter {
        var count = 0
    }

    private static func countChanges(_ registry: WxRegistry) -> Counter {
        let counter = Counter()
        registry.addChangeHandler { counter.count += 1 }
        return counter
    }

    /// TestProv (test-registry.c:137-211): a provider with a settable id and
    /// a covers() that registers another provider while the registry walks.
    private final class TestProv: WxProvider {
        private struct State {
            var id: String
            weak var registry: WxRegistry?
            var toAdd: (any WxProvider)?
            var coversCalls = 0
        }

        private let state: Mutex<State>

        init(id: String) {
            state = Mutex(State(id: id))
        }

        var id: String { state.withLock { $0.id } }
        var name: String { "text" }
        var attribution: String { "text" }
        var attributionURL: String { "text" }
        var coversCalls: Int { state.withLock { $0.coversCalls } }
        var hasPendingAdd: Bool { state.withLock { $0.toAdd != nil } }

        func setID(_ id: String) {
            state.withLock { $0.id = id }
        }

        func arm(registry: WxRegistry, toAdd: any WxProvider) {
            state.withLock {
                $0.registry = registry
                $0.toAdd = toAdd
            }
        }

        func covers(_ place: WxPlace) -> Bool {
            let (registry, toAdd) = state.withLock { s in
                s.coversCalls += 1
                defer { s.toAdd = nil }
                return (s.registry, s.toAdd)
            }
            if let registry, let toAdd {
                // The registry calls covers() on the main actor.
                MainActor.assumeIsolated {
                    do {
                        try registry.addProvider(toAdd)
                    } catch {
                        Issue.record("add from covers() failed: \(error)")
                    }
                }
            }
            return true
        }

        func fetch(_ place: WxPlace) async throws -> WxSourceResult {
            throw WxError(.unsupported, "not used")
        }
    }

    // MARK: - Interface dispatch

    // C: /registry/interfaces/dispatch (behavioural part; the criticals are GLib-only)
    @Test("/registry/interfaces/dispatch")
    func interfacesDispatch() throws {
        let fake = FakeProvider(id: "open-meteo")  // test-registry.c:220
        let provider: any WxProvider = fake
        #expect(provider.id == "open-meteo")  // test-registry.c:224
        #expect(provider.name == "Fake open-meteo")  // test-registry.c:225
        #expect(provider.attribution == "Fake data (open-meteo)")  // test-registry.c:226
        #expect(provider.attributionURL == "https://example.invalid/")  // test-registry.c:227
        let place = try Self.miami
        #expect(provider.covers(place))  // test-registry.c:229
        fake.setCovers(false)
        #expect(!provider.covers(place))  // test-registry.c:231
        #expect(!(fake as AnyObject is any WxGeocoder))  // test-registry.c:223
        #expect(!(FakeGeocoder() as AnyObject is any WxProvider))  // test-registry.c:488
        #expect(fake.fetchCount == 0)  // test-registry.c:269
    }

    // MARK: - Fake provider / geocoder

    // C: /registry/fake/provider-fetch
    @Test("/registry/fake/provider-fetch")
    func fakeProviderFetch() async throws {
        let fake = FakeProvider(id: "nws")  // test-registry.c:280
        let place = try Self.miami
        fake.addMember(try Self.makeMember("nws", "gridpoint"))  // test-registry.c:283
        fake.addMember(try Self.makeMember("nws", "second"))  // test-registry.c:284

        var o = await Self.fetch(fake, place)
        let result = try #require(o.value, "first fetch: \(o)")
        #expect(result.providerID == "nws")  // test-registry.c:294
        #expect(result.members.count == 2)  // test-registry.c:295
        // In order (test-registry.c:296-297); members are values, compared field-wise.
        #expect(result.members.map(\.modelID) == ["gridpoint", "second"])
        #expect(result.members.allSatisfy { $0.sourceID == "nws" && $0.fetchedS == 1_791_676_800 })
        #expect(result.members.allSatisfy { $0.hours.count == 1 && $0.hours[0].tS == 1_791_676_800 })
        #expect(result.members.allSatisfy { $0.hours[0].tempC == 25.0 })
        #expect(fake.fetchCount == 1)  // test-registry.c:298

        // The result does not alias provider state (test-registry.c:301-305).
        o = await Self.fetch(fake, place)
        #expect(o.value?.members.count == 2)  // test-registry.c:304

        // Not covered (test-registry.c:307-315).
        fake.setCovers(false)
        o = await Self.fetch(fake, place)
        #expect(o.value == nil)  // test-registry.c:312
        #expect(o.code == .unsupported)  // test-registry.c:313
        if case .wx(let error) = o {
            #expect(error.message == "place not covered")  // wx-fake-provider.c:460
        }
        fake.setCovers(true)

        // Scripted failures: every code, then back to success (test-registry.c:325-338).
        for code in WxError.Code.allCases {
            fake.failWith(code)
            o = await Self.fetch(fake, place)
            #expect(o.value == nil, "code \(code)")  // test-registry.c:330
            #expect(o.code == code, "code \(code)")  // test-registry.c:331
        }
        #expect(WxError.Code.allCases.map(\.rawValue) == Array(0...7))  // code <= WX_ERROR_UNSUPPORTED, test-registry.c:326
        fake.failWith(nil)
        o = await Self.fetch(fake, place)
        #expect(o.value != nil, "back to success: \(o)")  // test-registry.c:337

        // An invalid provider id cannot build a result (test-registry.c:342-347).
        let odd = FakeProvider(id: "Not Valid!")
        o = await Self.fetch(odd, place)
        #expect(o.code == .invalidArg)  // test-registry.c:346
        #expect(fake.fetchCount == 2 + 1 + WxError.Code.allCases.count + 1)  // every call counts
    }

    // C: /registry/fake/provider-delay-cancel (literal timings, real clock)
    @Test("/registry/fake/provider-delay-cancel (system clock)")
    func fakeProviderDelayAndCancelSystemClock() async throws {
        let clock = SystemClock()
        let fake = FakeProvider(id: "slow", clock: clock)  // test-registry.c:353
        let place = try Self.miami
        fake.addMember(try Self.makeMember("slow", "m"))  // test-registry.c:356

        // A delay (test-registry.c:359-367).
        fake.setDelayMs(120)  // test-registry.c:360
        var start = clock.monotonicMicroseconds
        var o = await Self.fetch(fake, place)
        var finished = clock.monotonicMicroseconds
        #expect(o.value != nil, "\(o)")
        #expect((finished - start) / 1000 >= 110)  // test-registry.c:366

        // Cancelled while waiting: the success is dropped (test-registry.c:376-386).
        fake.setDelayMs(60000)  // test-registry.c:377
        start = clock.monotonicMicroseconds
        let task = Task { await Self.fetch(fake, place) }
        try await Task.sleep(for: .milliseconds(80))  // test-registry.c:381
        task.cancel()
        o = await task.value
        finished = clock.monotonicMicroseconds
        #expect(o.value == nil)  // test-registry.c:383
        #expect(o.isCancelled, "\(o)")  // test-registry.c:384
        #expect((finished - start) / 1000 < 5000)  // test-registry.c:385
    }

    // C: /registry/fake/provider-delay-cancel (deterministic, ManualClock)
    @Test("/registry/fake/provider-delay-cancel (manual clock)")
    func fakeProviderDelayAndCancelManualClock() async throws {
        let clock = ManualClock()
        let fake = FakeProvider(id: "slow", clock: clock)  // test-registry.c:353
        let place = try Self.miami
        fake.addMember(try Self.makeMember("slow", "m"))  // test-registry.c:356

        // A delay of 120 ms (test-registry.c:360): still waiting just before it ends.
        fake.setDelayMs(120)
        let start = clock.monotonicMicroseconds
        var task = Task { await Self.fetch(fake, place) }
        await clock.waitForSleepers(1)
        await clock.advance(by: 119_999)
        #expect(clock.pendingSleeperCount == 1)
        await clock.advance(by: 1)
        var o = await task.value
        #expect(o.value?.members.count == 1, "\(o)")
        #expect((clock.monotonicMicroseconds - start) / 1000 >= 110)  // test-registry.c:366

        // A delay with a task that is never cancelled (the quiet cancellable, test-registry.c:369-374).
        task = Task { await Self.fetch(fake, place) }
        await clock.waitForSleepers(1)
        await clock.advance(by: 120_000)
        o = await task.value
        #expect(o.value != nil, "\(o)")  // test-registry.c:373

        // Cancelled while waiting (test-registry.c:376-386): ends without time passing.
        fake.setDelayMs(60000)  // test-registry.c:377
        task = Task { await Self.fetch(fake, place) }
        await clock.waitForSleepers(1)
        let cancelledAt = clock.monotonicMicroseconds
        task.cancel()
        o = await task.value
        #expect(o.isCancelled, "\(o)")  // test-registry.c:384
        #expect(clock.monotonicMicroseconds == cancelledAt)
        #expect(clock.pendingSleeperCount == 0)

        // Cancelled while waiting for a scripted failure (test-registry.c:388-395).
        fake.failWith(.network)  // test-registry.c:389
        task = Task { await Self.fetch(fake, place) }
        await clock.waitForSleepers(1)
        task.cancel()
        o = await task.value
        #expect(o.isCancelled, "\(o)")  // test-registry.c:394

        // Pre-cancelled (test-registry.c:397-404): the task body starts only
        // after this test yields, so it is already cancelled; nothing sleeps.
        let countBefore = fake.fetchCount
        task = Task { @MainActor in await Self.fetch(fake, place) }
        task.cancel()
        o = await task.value
        #expect(o.isCancelled, "\(o)")  // test-registry.c:403
        #expect(clock.pendingSleeperCount == 0)
        #expect(fake.fetchCount == countBefore + 1)  // the call still reached the provider

        // Cancelled before the result is handed over wins, with no delay and
        // no failure (test-registry.c:406-414).
        fake.setDelayMs(0)  // test-registry.c:407
        fake.failWith(nil)  // test-registry.c:408
        task = Task { @MainActor in await Self.fetch(fake, place) }
        task.cancel()
        o = await task.value
        #expect(o.isCancelled, "\(o)")  // test-registry.c:413
    }

    // C: /registry/fake/geocoder-search
    @Test("/registry/fake/geocoder-search")
    func fakeGeocoderSearch() async throws {
        let clock = ManualClock()
        let fake = FakeGeocoder(clock: clock)
        let geocoder: any WxGeocoder = fake
        fake.addHit(try Self.makePlace("Miami", 25.7617, -80.1918))  // test-registry.c:489
        fake.addHit(try Self.makePlace("Oslo", 59.9139, 10.7522))  // test-registry.c:490

        var o = await Self.search(geocoder, Array("Mia".utf8))  // test-registry.c:495
        let hits = try #require(o.value, "\(o)")
        #expect(hits.count == 2)  // test-registry.c:499
        #expect(hits.map(\.name) == ["Miami", "Oslo"])  // test-registry.c:502-503
        #expect(fake.searchCount == 1)  // test-registry.c:504

        // Invalid text: reported as an error (test-registry.c:507-516).
        let badText: [[UInt8]] = [[], [0x20, 0x20, 0x20], [0x61, 0x01], [0xFF, 0xFE]]  // test-registry.c:508
        for bytes in badText {
            o = await Self.search(geocoder, bytes)
            #expect(o.value == nil, "\(bytes)")  // test-registry.c:513
            #expect(o.code == .invalidArg, "\(bytes)")  // test-registry.c:514
        }
        o = await Self.search(geocoder, [UInt8](repeating: 0x61, count: 65))  // test-registry.c:517
        #expect(o.code == .invalidArg)  // test-registry.c:520
        o = await Self.search(geocoder, [UInt8](repeating: 0x61, count: 64))  // FAKE_SEARCH_TEXT_MAX, wx-fake-provider.c:9
        #expect(o.value != nil, "\(o)")

        // Failure, delay, cancellation (test-registry.c:523-536).
        fake.failWith(.rateLimited)  // test-registry.c:524
        o = await Self.search(geocoder, Array("Mia".utf8))
        #expect(o.code == .rateLimited)  // test-registry.c:527
        fake.failWith(nil)
        fake.setDelayMs(60000)  // test-registry.c:530
        let task = Task { await Self.search(geocoder, Array("Mia".utf8)) }
        await clock.waitForSleepers(1)
        task.cancel()
        o = await task.value
        #expect(o.isCancelled, "\(o)")  // test-registry.c:535

        // The result is capped at WX_GEOCODER_MAX_HITS (test-registry.c:538-548).
        fake.setDelayMs(0)
        for i in 0..<(WxLimits.geocoderMaxHits + 5) {
            fake.addHit(try Self.makePlace("Extra", 10.0 + Double(i), 20.0))  // test-registry.c:541
        }
        o = await Self.search(geocoder, Array("Mia".utf8))
        #expect(o.value?.count == 20)  // test-registry.c:546 (WX_GEOCODER_MAX_HITS)
        #expect(o.value?.prefix(2).map(\.name) == ["Miami", "Oslo"])
        #expect(WxLimits.geocoderMaxHits == 20)  // test-registry.c:548
    }

    // MARK: - Registry

    // C: /registry/empty
    @Test("/registry/empty")
    func registryEmpty() throws {
        let registry = WxRegistry()
        #expect(registry.listProviders().isEmpty)  // test-registry.c:561
        #expect(registry.findProvider(id: "nws") == nil)  // test-registry.c:562
        #expect(!registry.isEnabled(id: "nws"))  // test-registry.c:563
        #expect(!registry.setEnabled(false, id: "nws"))  // test-registry.c:564
        #expect(registry.geocoder == nil)  // test-registry.c:565
        #expect(registry.listCovering(try Self.miami).isEmpty)  // test-registry.c:568
    }

    // C: /registry/add-find-order
    @Test("/registry/add-find-order")
    func registryAddFindOrder() throws {
        let registry = WxRegistry()
        let changed = Self.countChanges(registry)
        let a = FakeProvider(id: "nws")  // test-registry.c:577
        let b = FakeProvider(id: "open-meteo")  // test-registry.c:578
        let c = FakeProvider(id: "met-no")  // test-registry.c:579
        try registry.addProvider(a)
        #expect(changed.count == 1)  // test-registry.c:583
        try registry.addProvider(b)
        try registry.addProvider(c)
        #expect(changed.count == 3)  // test-registry.c:586

        let list = registry.listProviders()
        #expect(list.count == 3)  // test-registry.c:592
        #expect(list[0] === a)  // registration order, test-registry.c:593-595
        #expect(list[1] === b)
        #expect(list[2] === c)
        #expect(registry.findProvider(id: "nws") === a)  // test-registry.c:596
        #expect(registry.findProvider(id: "open-meteo") === b)  // test-registry.c:597
        #expect(registry.findProvider(id: "met-no") === c)  // test-registry.c:598
        #expect(registry.findProvider(id: "NWS") == nil)  // test-registry.c:599
        #expect(registry.findProvider(id: "nws ") == nil)  // test-registry.c:600
        #expect(registry.findProvider(id: "") == nil)  // test-registry.c:601
        #expect(registry.isEnabled(id: "nws"))  // test-registry.c:602

        // The snapshot does not change when more providers are added (test-registry.c:604-611).
        let d = FakeProvider(id: "later")  // test-registry.c:605
        try registry.addProvider(d)
        #expect(list.count == 3)  // test-registry.c:607
        let list2 = registry.listProviders()
        #expect(list2.count == 4)  // test-registry.c:609
        #expect(list2[3] === d)  // test-registry.c:610
        #expect(changed.count == 4)  // test-registry.c:611
    }

    // C: /registry/rejects-bad-and-duplicate-ids
    @Test("/registry/rejects-bad-and-duplicate-ids")
    func registryRejectsBadAndDuplicateIDs() throws {
        let registry = WxRegistry()
        let changed = Self.countChanges(registry)
        let id32 = String(repeating: "a", count: 32)  // test-registry.c:620
        let id33 = String(repeating: "a", count: 33)  // test-registry.c:621
        // test-registry.c:622-623. "a\xff" cannot be a Swift String (the id is
        // a String); its decoded form "a\u{FFFD}" is rejected for the same
        // reason (a byte outside [a-z0-9_-]).
        let bad = [
            "", ".", "..", "a.b", ".a", "-a", "_a", "A", "nWs", "a b", "a/b", "a\\b", "a:b", "../x",
            "a\n", "caf\u{E9}", "a\u{FFFD}", "a%2e", "a\u{01}", id33,
        ]
        #expect(Array("caf\u{E9}".utf8) == [0x63, 0x61, 0x66, 0xC3, 0xA9])  // "caf\xc3\xa9"
        for id in bad {
            weak var retained: FakeProvider?
            do {
                let p = FakeProvider(id: id)
                retained = p
                // wx-registry.c:184 (the C test checks WX_ERROR_INVALID_ARG, test-registry.c:628)
                #expect(throws: WxError(.invalidArg, "invalid provider id"), "\(Array(id.utf8))") {
                    try registry.addProvider(p)
                }
                #expect(throws: WxError.self) { try registry.addProvider(p) }  // test-registry.c:629
            }
            #expect(retained == nil, "nothing was retained: \(Array(id.utf8))")  // test-registry.c:630
        }
        #expect(changed.count == 0)  // test-registry.c:632
        #expect(registry.listProviders().isEmpty)

        // Valid boundary ids (test-registry.c:634-642).
        let good = ["a", "0", "9z", "a-b", "a_b", "a-", "a_", "a--b", id32]  // test-registry.c:635
        for id in good {
            #expect(throws: Never.self, "\(id)") { try registry.addProvider(FakeProvider(id: id)) }
        }
        #expect(changed.count == good.count)  // test-registry.c:642

        // Duplicates: another instance with the same id, and the same instance twice (test-registry.c:652-665).
        let first = FakeProvider(id: "dup")  // test-registry.c:653
        weak var weakSecond: FakeProvider?
        try registry.addProvider(first)
        let before = changed.count
        do {
            let second = FakeProvider(id: "dup")  // test-registry.c:654
            weakSecond = second
            // wx-registry.c:188-189 (C: WX_ERROR_INVALID_ARG, test-registry.c:659)
            #expect(throws: WxError(.invalidArg, "a provider with this id is already registered")) {
                try registry.addProvider(second)
            }
        }
        #expect(throws: WxError(.invalidArg, "a provider with this id is already registered")) {
            try registry.addProvider(first)  // test-registry.c:661-662
        }
        #expect(changed.count == before)  // test-registry.c:663
        #expect(registry.findProvider(id: "dup") === first)  // test-registry.c:664
        #expect(weakSecond == nil)  // test-registry.c:665

        // The id is read once: a later change is not followed (test-registry.c:667-676).
        let morph = TestProv(id: "one")  // test-registry.c:668
        try registry.addProvider(morph)
        morph.setID("two")  // test-registry.c:671
        #expect(registry.findProvider(id: "one") === morph)  // test-registry.c:672
        #expect(registry.findProvider(id: "two") == nil)  // test-registry.c:673
        #expect(registry.isEnabled(id: "one"))  // test-registry.c:674
        #expect(!registry.isEnabled(id: "two"))  // test-registry.c:675
        #expect(registry.setEnabled(false, id: "one"))  // test-registry.c:676
    }

    // C: /registry/cap
    @Test("/registry/cap")
    func registryCap() throws {
        let registry = WxRegistry()
        let changed = Self.countChanges(registry)
        #expect(WxRegistry.maxProviders == 16)  // test-registry.c:685
        for i in 0..<16 {
            #expect(throws: Never.self) { try registry.addProvider(FakeProvider(id: "p\(i)")) }  // test-registry.c:687
        }
        #expect(changed.count == 16)  // test-registry.c:693
        weak var weakExtra: FakeProvider?
        do {
            let extra = FakeProvider(id: "one-too-many")  // test-registry.c:694
            weakExtra = extra
            // wx-registry.c:193-194 with %d = 16 (C: WX_ERROR_INVALID_ARG, test-registry.c:697)
            #expect(throws: WxError(.invalidArg, "too many providers (limit 16)")) {
                try registry.addProvider(extra)
            }
        }
        #expect(changed.count == 16)  // test-registry.c:698
        #expect(weakExtra == nil)  // test-registry.c:699
        #expect(registry.listProviders().count == 16)  // test-registry.c:701
        // A duplicate id is reported as such even when full (test-registry.c:702-706).
        #expect(throws: WxError(.invalidArg, "a provider with this id is already registered")) {
            try registry.addProvider(FakeProvider(id: "p3"))  // test-registry.c:703
        }
        #expect(changed.count == 16)
    }

    // C: /registry/enable-covering-signals
    @Test("/registry/enable-covering-signals")
    func registryEnableCoveringAndSignals() throws {
        let registry = WxRegistry()
        let a = FakeProvider(id: "a")  // test-registry.c:713
        let b = FakeProvider(id: "b")  // test-registry.c:714
        let c = FakeProvider(id: "c")  // test-registry.c:715
        b.setCovers(false)  // test-registry.c:716
        try registry.addProvider(a)
        try registry.addProvider(b)
        try registry.addProvider(c)
        let changed = Self.countChanges(registry)
        let place = try Self.miami

        // enabled AND covers (test-registry.c:724-728).
        let covering = registry.listCovering(place)
        #expect(covering.count == 2)  // test-registry.c:726
        #expect(covering.first === a)  // test-registry.c:727
        #expect(covering.last === c)  // test-registry.c:728

        // Disabling emits once; repeating it is silent (test-registry.c:730-742).
        #expect(registry.setEnabled(false, id: "a"))  // test-registry.c:731
        #expect(changed.count == 1)  // test-registry.c:732
        #expect(!registry.isEnabled(id: "a"))  // test-registry.c:733
        #expect(registry.setEnabled(false, id: "a"))  // test-registry.c:734
        #expect(changed.count == 1)  // test-registry.c:735
        let covering2 = registry.listCovering(place)
        #expect(covering2.count == 1)  // test-registry.c:737
        #expect(covering2.first === c)  // test-registry.c:738
        #expect(registry.listProviders().count == 3)  // test-registry.c:741
        #expect(registry.findProvider(id: "a") === a)  // test-registry.c:742

        // Re-enabling (test-registry.c:744-749; the C "any non-zero value" is a Swift Bool).
        #expect(registry.setEnabled(true, id: "a"))  // test-registry.c:745
        #expect(changed.count == 2)  // test-registry.c:746
        #expect(registry.isEnabled(id: "a"))  // test-registry.c:747
        #expect(registry.setEnabled(true, id: "a"))  // test-registry.c:748
        #expect(changed.count == 2)  // test-registry.c:749

        // Disabled-and-not-covering: both filters apply (test-registry.c:751-757).
        #expect(registry.setEnabled(false, id: "b"))  // test-registry.c:752
        #expect(registry.setEnabled(false, id: "c"))  // test-registry.c:753
        #expect(changed.count == 4)  // test-registry.c:754
        let covering3 = registry.listCovering(place)
        #expect(covering3.count == 1)  // test-registry.c:756
        #expect(covering3.first === a)  // test-registry.c:757

        // Unknown ids: false, no change, no notification (test-registry.c:759-767).
        let unknown = ["zzz", "A", "a ", "", "a\u{01}", "../a", "\u{FFFD}"]  // test-registry.c:760 ("\xff" decoded)
        for id in unknown {
            #expect(!registry.setEnabled(true, id: id), "\(id)")  // test-registry.c:762
            #expect(!registry.setEnabled(false, id: id), "\(id)")  // test-registry.c:763
            #expect(!registry.isEnabled(id: id), "\(id)")  // test-registry.c:764
            #expect(registry.findProvider(id: id) == nil, "\(id)")  // test-registry.c:765
        }
        #expect(changed.count == 4)  // test-registry.c:767

        // The geocoder does not notify (test-registry.c:769-772).
        registry.geocoder = FakeGeocoder()
        #expect(changed.count == 4)  // test-registry.c:772
    }

    // C: /registry/geocoder
    @Test("/registry/geocoder")
    func registryGeocoder() async throws {
        let registry = WxRegistry()
        var g1: FakeGeocoder? = FakeGeocoder()
        weak let weakG1 = g1
        #expect(registry.geocoder == nil)  // test-registry.c:781
        registry.geocoder = g1
        #expect(registry.geocoder === g1)  // test-registry.c:783
        registry.geocoder = g1  // same object again, test-registry.c:785
        #expect(registry.geocoder === g1)
        do {
            var g2: FakeGeocoder? = FakeGeocoder()
            weak let weakG2 = g2
            registry.geocoder = g2  // test-registry.c:787
            #expect(registry.geocoder === g2)  // test-registry.c:788
            g2 = nil
            #expect(weakG2 != nil)  // the registry holds a reference, test-registry.c:790
            registry.geocoder = nil  // test-registry.c:791
            #expect(registry.geocoder == nil)  // test-registry.c:792
            #expect(weakG2 == nil)  // released, test-registry.c:793
        }
        registry.geocoder = g1  // test-registry.c:794
        g1 = nil
        #expect(weakG1 != nil)  // the registry holds a reference, test-registry.c:784

        // The geocoder is usable through the registry (test-registry.c:796-804).
        let hit = try Self.miami
        (registry.geocoder as? FakeGeocoder)?.addHit(hit)
        let geocoder = try #require(registry.geocoder)
        let o = await Self.search(geocoder, Array("Mia".utf8))
        #expect(o.value?.count == 1, "\(o)")  // test-registry.c:803
    }

    // C: /registry/covers-reenter
    @Test("/registry/covers-reenter")
    func registryCoversMayReenter() throws {
        let registry = WxRegistry()
        let adder = TestProv(id: "adder")  // test-registry.c:842
        adder.arm(registry: registry, toAdd: FakeProvider(id: "added"))  // test-registry.c:843-844
        let other = FakeProvider(id: "other")  // test-registry.c:845
        try registry.addProvider(adder)
        try registry.addProvider(other)
        // covers() of the first provider registers a third: the walk visits it (test-registry.c:849-857).
        let covering = registry.listCovering(try Self.miami)
        #expect(adder.coversCalls == 1)  // test-registry.c:851
        #expect(!adder.hasPendingAdd)  // test-registry.c:852
        #expect(covering.map(\.id) == ["adder", "other", "added"])  // test-registry.c:853-856
        #expect(registry.findProvider(id: "added") != nil)  // test-registry.c:857
    }

    // C: /registry/dispose (as release of the registry's references)
    @Test("/registry/dispose")
    func registryReleasesEverything() throws {
        weak var weakP: FakeProvider?
        weak var weakG: FakeGeocoder?
        var registry: WxRegistry? = WxRegistry()
        do {
            let p = FakeProvider(id: "p")  // test-registry.c:864
            let g = FakeGeocoder()  // test-registry.c:865
            weakP = p
            weakG = g
            try registry?.addProvider(p)
            registry?.geocoder = g
        }
        #expect(weakP != nil)  // the registry holds them, test-registry.c:868-869
        #expect(weakG != nil)
        registry = nil  // test-registry.c:870
        #expect(weakP == nil)  // test-registry.c:871 (the caller's own reference is gone here)
        #expect(weakG == nil)  // test-registry.c:872
    }

    // C: /registry/handler-reentrancy
    @Test("/registry/handler-reentrancy")
    func registryHandlerReentrancy() throws {
        let registry = WxRegistry()
        let calls = Counter()
        let x = FakeProvider(id: "x")  // test-registry.c:973
        registry.addChangeHandler { [unowned registry] in  // reenter_handler, test-registry.c:954-966
            calls.count += 1
            #expect(registry.isEnabled(id: "x"))  // test-registry.c:959
            #expect(registry.listProviders().count >= 1)  // test-registry.c:961
            if calls.count == 1 {
                #expect(throws: Never.self) { try registry.addProvider(FakeProvider(id: "y")) }  // test-registry.c:963-964
            }
        }
        try registry.addProvider(x)
        #expect(calls.count == 2)  // test-registry.c:976
        #expect(registry.listProviders().map(\.id) == ["x", "y"])  // test-registry.c:978
    }

    // Executor case: removing a change handler stops its notifications
    // (g_signal_handler_disconnect; used by /registry/after-dispose, test-registry.c:933-935).
    @Test("change handler removal")
    func changeHandlerRemoval() throws {
        let registry = WxRegistry()
        let first = Counter()
        let second = Counter()
        let firstID = registry.addChangeHandler { first.count += 1 }
        registry.addChangeHandler { second.count += 1 }
        try registry.addProvider(FakeProvider(id: "p"))
        registry.removeChangeHandler(firstID)
        #expect(registry.setEnabled(false, id: "p"))
        #expect(first.count == 1)
        #expect(second.count == 2)
    }
}
