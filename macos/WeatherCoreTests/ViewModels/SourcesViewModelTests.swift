// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourcesViewModelTests.swift - port of the BEHAVIOURAL cases of
// src/ui/test-sources.c (registrations test-sources.c:1620-1694) for
// SourcesViewModel and AboutInfo. Expected values are the C tests' literals,
// cited as test-sources.c:LINE (or the C source line for the About fields and
// provider identities). Inputs with C escapes are written as byte arrays.

import Foundation
import Testing
@testable import WeatherCore

@MainActor
@Suite struct SourcesViewModelTests {
    // MARK: - Fixtures

    /// add_test_provider (test-sources.c:139-150): a provider with the given texts.
    private final class TextProvider: WxProvider {
        let id: String
        let name: String
        let attribution: String
        let attributionURL: String
        init(_ id: String, _ name: String, _ attribution: String, _ url: String) {
            self.id = id
            self.name = name
            self.attribution = attribution
            self.attributionURL = url
        }
        func covers(_ place: WxPlace) -> Bool { false }
        func fetch(_ place: WxPlace) async throws -> WxSourceResult {
            throw WxError(.unsupported, "test provider")
        }
    }

    /// Records the "provider-toggled" emissions (Toggles, test-sources.c:283-330);
    /// `applyTo` applies each request to the registry like the C `apply_to`.
    @MainActor private final class Toggles {
        var count = 0
        var id: String?
        var enabled: Bool?
        var applyTo: WxRegistry?
        func handle(_ id: String, _ enabled: Bool) {
            count += 1
            self.id = id
            self.enabled = enabled
            applyTo?.setEnabled(enabled, id: id)
        }
    }

    /// make_registry (test-sources.c:157-168): one wx_fake_provider per id.
    private func makeRegistry(_ ids: [String]) throws -> WxRegistry {
        let registry = WxRegistry()
        for id in ids {
            try registry.addProvider(FakeProvider(id: id))
        }
        return registry
    }

    private func makeModel(_ registry: WxRegistry, _ toggles: Toggles) -> SourcesViewModel {
        SourcesViewModel(registry: registry, onToggle: { toggles.handle($0, $1) })
    }

    /// make_status (test-sources.c:248-257) and make_forecast (test-sources.c:259-274).
    private func forecast(_ statuses: [(String, WxSourceState, WxError.Code?, UInt32)]) throws -> WxForecast {
        let place = try WxPlace(name: "Miami", lat: 25.77, lon: -80.19, timezone: "America/New_York")
        let sources = try statuses.map { s in
            try WxSourceStatus(
                providerID: s.0, name: "Name", attribution: "Attribution",
                attributionURL: "https://example.invalid/", state: s.1, errorCode: s.2, nMembers: s.3)
        }
        return try WxForecast(place: place, generatedS: 1_791_676_800, sources: sources)
    }

    private func status(_ vm: SourcesViewModel, _ i: Int) -> String { vm.rows[i].status }

    // MARK: - Layout and rows

    @Test func emptyRegistryLayout() throws {
        // C: /sources/layout/empty-registry
        let vm = makeModel(WxRegistry(), Toggles())
        #expect(vm.rows.isEmpty)  // test-sources.c:383
        #expect(SourcesViewModel.title == "Data sources")  // test-sources.c:386
        #expect(SourcesViewModel.aboutButtonTitle == "About Weather")  // test-sources.c:391
    }

    @Test func rowsFollowRegistryOrder() throws {
        // C: /sources/rows/registry-order
        let ids = ["open-meteo", "zeta", "alpha", "met-no"]  // test-sources.c:398
        let vm = makeModel(try makeRegistry(ids), Toggles())
        #expect(vm.rows.count == 4)  // test-sources.c:401
        for (i, id) in ids.enumerated() {
            #expect(vm.rows[i].id == id)
            #expect(vm.rows[i].name == "Fake \(id)")  // test-sources.c:403
        }
    }

    @Test func sixteenProviders() throws {
        // C: /sources/rows/sixteen
        let registry = try makeRegistry((0..<16).map { "p\($0)" })  // test-sources.c:421-424
        let vm = makeModel(registry, Toggles())
        #expect(vm.rows.count == 16)  // test-sources.c:426 (WX_REGISTRY_MAX_PROVIDERS)
        #expect(vm.rows[15].name == "Fake p15")  // test-sources.c:427
        #expect(throws: WxError.self) { try registry.addProvider(FakeProvider(id: "extra")) }  // :429-432
        #expect(vm.rows.count == 16)  // test-sources.c:433
    }

    @Test func switchMatchesEnabledFlag() throws {
        // C: /sources/switch/matches-enabled
        let registry = try makeRegistry(["a", "b", "c"])  // test-sources.c:439
        registry.setEnabled(false, id: "b")  // test-sources.c:441
        let vm = makeModel(registry, Toggles())
        #expect(vm.rows.map(\.isEnabled) == [true, false, true])  // test-sources.c:443-445
    }

    // MARK: - Toggles

    @Test func toggleEmitsOnceAndDoesNotTouchRegistry() throws {
        // C: /sources/toggle/emits-once-registry-untouched
        let registry = try makeRegistry(["a", "b"])  // test-sources.c:457
        let toggles = Toggles()
        let vm = makeModel(registry, toggles)
        var changed = 0
        let handler = registry.addChangeHandler { changed += 1 }
        defer { registry.removeChangeHandler(handler) }
        vm.setEnabled(false, forProviderID: "b")  // test-sources.c:464
        #expect(toggles.count == 1)  // test-sources.c:465
        #expect(toggles.id == "b")  // test-sources.c:466
        #expect(toggles.enabled == false)  // test-sources.c:467
        #expect(registry.isEnabled(id: "b"))  // test-sources.c:468
        #expect(registry.isEnabled(id: "a"))  // test-sources.c:469
        #expect(changed == 0)  // test-sources.c:470
    }

    @Test func refusedToggleSnapsBack() throws {
        // C: /sources/toggle/refused-snaps-back
        let registry = try makeRegistry(["a"])
        let toggles = Toggles()
        let vm = makeModel(registry, toggles)
        vm.setEnabled(false, forProviderID: "a")  // test-sources.c:482
        #expect(toggles.count == 1)  // test-sources.c:483
        #expect(vm.rows[0].isEnabled)  // test-sources.c:484
        registry.setEnabled(false, id: "a")  // test-sources.c:487
        #expect(!vm.rows[0].isEnabled)  // test-sources.c:488
        vm.setEnabled(true, forProviderID: "a")  // test-sources.c:489
        #expect(toggles.count == 2)  // test-sources.c:490
        #expect(toggles.enabled == true)  // test-sources.c:491
        #expect(!vm.rows[0].isEnabled)  // test-sources.c:492
    }

    @Test func appliedToggleSticks() throws {
        // C: /sources/toggle/applied-sticks
        let registry = try makeRegistry(["a", "b"])
        let toggles = Toggles()
        toggles.applyTo = registry
        let vm = makeModel(registry, toggles)
        vm.setEnabled(false, forProviderID: "a")
        #expect(toggles.count == 1)  // test-sources.c:565
        #expect(!registry.isEnabled(id: "a"))  // test-sources.c:566
        #expect(!vm.rows[0].isEnabled)  // test-sources.c:567
        #expect(status(vm, 0) == "Turned off")  // test-sources.c:569
        #expect(vm.rows[1].isEnabled)  // test-sources.c:570
        vm.setEnabled(true, forProviderID: "a")
        #expect(toggles.count == 2)  // test-sources.c:572
        #expect(toggles.enabled == true)  // test-sources.c:573
        #expect(registry.isEnabled(id: "a"))  // test-sources.c:574
        #expect(vm.rows[0].isEnabled)  // test-sources.c:575
        #expect(status(vm, 0) == "No forecast loaded yet")  // test-sources.c:576
    }

    @Test func ownerRevertingTheRequest() throws {
        // C: /sources/toggle/owner-reverts (flip_flop, test-sources.c:580-588)
        let registry = try makeRegistry(["a"])
        let vm = SourcesViewModel(registry: registry, onToggle: { id, _ in
            registry.setEnabled(false, id: id)
            registry.setEnabled(true, id: id)
        })
        vm.setEnabled(false, forProviderID: "a")
        #expect(registry.isEnabled(id: "a"))  // test-sources.c:598
        #expect(vm.rows[0].isEnabled)  // test-sources.c:599-600
    }

    @Test func toggleIDIsTheProviderID() throws {
        // C: /sources/toggle/id-is-a-copy (Swift strings are values; the pointer check
        // test-sources.c:614 has no Swift counterpart)
        let registry = try makeRegistry(["a"])
        let toggles = Toggles()
        let vm = makeModel(registry, toggles)
        vm.setEnabled(false, forProviderID: "a")
        #expect(toggles.id == registry.findProvider(id: "a")?.id)  // test-sources.c:613
    }

    @Test func eachUserToggleEmitsOnce() throws {
        // C: /sources/toggle/each-user-toggle-once
        let registry = try makeRegistry(["a"])
        let toggles = Toggles()
        toggles.applyTo = registry
        let vm = makeModel(registry, toggles)
        vm.setEnabled(false, forProviderID: "a")  // test-sources.c:627
        vm.setEnabled(true, forProviderID: "a")  // test-sources.c:628
        vm.setEnabled(true, forProviderID: "a")  // test-sources.c:629 (no change: not a toggle)
        vm.setEnabled(false, forProviderID: "a")  // test-sources.c:630
        #expect(toggles.count == 3)  // test-sources.c:631
        #expect(toggles.enabled == false)  // test-sources.c:632
    }

    @Test func unknownIDIsNotAToggle() throws {
        // C: /sources/toggle/emits-once-registry-untouched (a switch exists only for a row)
        let toggles = Toggles()
        let vm = makeModel(try makeRegistry(["a"]), toggles)
        vm.setEnabled(false, forProviderID: "zzz")
        #expect(toggles.count == 0)
    }

    @Test func registryChangesResyncWithoutSignal() throws {
        // C: /sources/registry/resync-without-signal
        let registry = try makeRegistry(["a", "b"])
        let toggles = Toggles()
        let vm = makeModel(registry, toggles)
        registry.setEnabled(false, id: "b")  // test-sources.c:644
        #expect(!vm.rows[1].isEnabled)  // test-sources.c:645
        #expect(status(vm, 1) == "Turned off")  // test-sources.c:647
        #expect(vm.rows[0].isEnabled)  // test-sources.c:648
        registry.setEnabled(true, id: "b")  // test-sources.c:649
        #expect(vm.rows[1].isEnabled)  // test-sources.c:650
        #expect(status(vm, 1) == "No forecast loaded yet")  // test-sources.c:651
        #expect(toggles.count == 0)  // test-sources.c:652
    }

    @Test func addedProviderGetsARow() throws {
        // C: /sources/registry/added-provider-row
        let registry = try makeRegistry(["a"])
        let toggles = Toggles()
        let vm = makeModel(registry, toggles)
        try registry.addProvider(FakeProvider(id: "b"))  // test-sources.c:666
        #expect(vm.rows.count == 2)  // test-sources.c:667
        #expect(vm.rows[1].name == "Fake b")  // test-sources.c:668
        #expect(vm.rows[1].isEnabled)  // test-sources.c:669
        #expect(vm.rows[0].id == "a")  // test-sources.c:671 (the existing row is kept)
        #expect(toggles.count == 0)  // test-sources.c:673
        vm.setEnabled(false, forProviderID: "b")  // test-sources.c:675
        #expect(toggles.count == 1)  // test-sources.c:676
        #expect(toggles.id == "b")  // test-sources.c:677
    }

    @Test func twoViewModelsOneRegistry() throws {
        // C: /sources/registry/two-popovers
        let registry = try makeRegistry(["a"])
        let vm1 = makeModel(registry, Toggles())
        var vm2: SourcesViewModel? = makeModel(registry, Toggles())
        registry.setEnabled(false, id: "a")  // test-sources.c:1485
        #expect(!vm1.rows[0].isEnabled)  // test-sources.c:1486
        #expect(vm2?.rows[0].isEnabled == false)  // test-sources.c:1487
        weak let released = vm2
        vm2 = nil  // test-sources.c:1488 (the change handler holds no strong reference)
        #expect(released == nil)
        registry.setEnabled(true, id: "a")  // test-sources.c:1489
        #expect(vm1.rows[0].isEnabled)  // test-sources.c:1490
    }

    // MARK: - Status lines

    @Test func statusNoForecast() throws {
        // C: /sources/status/no-forecast
        let vm = makeModel(try makeRegistry(["a", "b"]), Toggles())
        vm.setForecast(nil)
        #expect(status(vm, 0) == "No forecast loaded yet")  // test-sources.c:691
        #expect(status(vm, 1) == "No forecast loaded yet")  // test-sources.c:692
    }

    @Test func statusOKCounts() throws {
        // C: /sources/status/ok-counts
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        let cases: [(UInt32, String)] = [
            (1, "Used for this place (1 forecast model)"),  // test-sources.c:708
            (2, "Used for this place (2 forecast models)"),  // test-sources.c:709
            (0, "Used for this place (0 forecast models)"),  // test-sources.c:710
            (17, "Used for this place (17 forecast models)"),  // test-sources.c:711
        ]
        for (n, text) in cases {
            vm.setForecast(try forecast([("a", .ok, nil, n)]))
            #expect(status(vm, 0) == text)
        }
    }

    @Test func statusFailedReasons() throws {
        // C: /sources/status/failed-reasons
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        let cases: [(WxError.Code, String)] = [
            (.network, "Could not load: network error"),  // test-sources.c:730
            (.timeout, "Could not load: timed out"),  // test-sources.c:731
            (.http, "Could not load: server error"),  // test-sources.c:732
            (.rateLimited, "Could not load: rate limited"),  // test-sources.c:733
            (.parse, "Could not load: unreadable answer"),  // test-sources.c:734
            (.notFound, "Could not load: no data"),  // test-sources.c:735
            (.invalidArg, "Could not load: invalid request"),  // test-sources.c:736
            (.unsupported, "Could not load: not available"),  // test-sources.c:737
        ]
        #expect(cases.count == WxError.Code.allCases.count)
        for (code, text) in cases {
            vm.setForecast(try forecast([("a", .failed, code, 0)]))
            #expect(status(vm, 0) == text)
        }
    }

    @Test func statusFailedUnknownCode() throws {
        // C: /sources/status/failed-unknown-code (WxForecast refuses unknown codes, so the
        // entry is built by hand, like the C test's hand-made WxForecast)
        for code in [99, -5, 8, Int(Int32.max)] {  // test-sources.c:757 (G_MAXINT)
            let entry = SourcesViewModel.Entry(id: "a", state: .failed, errorCode: code, nMembers: 0)
            #expect(
                SourcesViewModel.statusText(enabled: true, entries: [entry], id: "a")
                    == "Could not load: unknown error")  // test-sources.c:764
        }
        // -1 (no code) is "unknown error" too (wx-sources.h:50).
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        vm.setForecast(try forecast([("a", .failed, nil, 0)]))
        #expect(status(vm, 0) == "Could not load: unknown error")  // test-sources.c:764
    }

    @Test func statusSkippedAndMissing() throws {
        // C: /sources/status/skipped-and-missing
        let vm = makeModel(try makeRegistry(["a", "b"]), Toggles())
        vm.setForecast(try forecast([("a", .skipped, nil, 0)]))  // test-sources.c:774
        #expect(status(vm, 0) == "Not used for this place")  // test-sources.c:776
        #expect(status(vm, 1) == "Not used for this place")  // test-sources.c:777
        vm.setForecast(try forecast([]))  // test-sources.c:778
        #expect(status(vm, 0) == "Not used for this place")  // test-sources.c:780
        #expect(status(vm, 1) == "Not used for this place")  // test-sources.c:781
    }

    @Test func statusPicksEntryByID() throws {
        // C: /sources/status/entry-by-id
        let vm = makeModel(try makeRegistry(["a", "b", "c"]), Toggles())
        vm.setForecast(try forecast([("c", .failed, .timeout, 0), ("a", .ok, nil, 3), ("other", .ok, nil, 9)]))
        #expect(status(vm, 0) == "Used for this place (3 forecast models)")  // test-sources.c:796
        #expect(status(vm, 1) == "Not used for this place")  // test-sources.c:797
        #expect(status(vm, 2) == "Could not load: timed out")  // test-sources.c:798
    }

    @Test func statusTurnedOffTakesPrecedence() throws {
        // C: /sources/status/turned-off-precedence
        let registry = try makeRegistry(["a", "b", "c"])
        for id in ["a", "b", "c"] {
            registry.setEnabled(false, id: id)  // test-sources.c:806-808
        }
        let vm = makeModel(registry, Toggles())
        #expect(status(vm, 0) == "Turned off")  // test-sources.c:810
        vm.setForecast(try forecast([("a", .ok, nil, 2), ("b", .failed, .http, 0), ("c", .skipped, nil, 0)]))
        for i in 0..<3 {
            #expect(status(vm, i) == "Turned off")  // test-sources.c:818
        }
    }

    @Test func statusForecastReplacedAndCleared() throws {
        // C: /sources/status/replaced-and-cleared
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        vm.setForecast(try forecast([("a", .ok, nil, 2)]))
        #expect(status(vm, 0) == "Used for this place (2 forecast models)")  // test-sources.c:830
        vm.setForecast(try forecast([("a", .failed, .network, 0)]))
        #expect(status(vm, 0) == "Could not load: network error")  // test-sources.c:832
        vm.setForecast(nil)
        #expect(status(vm, 0) == "No forecast loaded yet")  // test-sources.c:834
        vm.setForecast(try forecast([("other", .ok, nil, 1)]))
        #expect(status(vm, 0) == "Not used for this place")  // test-sources.c:839
    }

    @Test func statusDuplicateEntriesFirstWins() throws {
        // C: /sources/status/duplicates-first-wins
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        vm.setForecast(try forecast([("a", .failed, .parse, 0), ("a", .ok, nil, 4)]))
        #expect(status(vm, 0) == "Could not load: unreadable answer")  // test-sources.c:853
        vm.setForecast(try forecast([("a", .ok, nil, 4), ("a", .failed, .parse, 0)]))
        #expect(status(vm, 0) == "Used for this place (4 forecast models)")  // test-sources.c:857
        vm.setForecast(try forecast([("a", .skipped, nil, 0), ("a", .ok, nil, 4)]))
        #expect(status(vm, 0) == "Not used for this place")  // test-sources.c:863
    }

    @Test func statusFollowsRegistryAfterForecastIsGone() throws {
        // C: /sources/status/follows-registry-no-forecast-ref
        let registry = try makeRegistry(["a", "b"])
        let vm = makeModel(registry, Toggles())
        do {
            let f = try forecast([("a", .ok, nil, 2)])
            vm.setForecast(f)
        }  // the only reference is gone (test-sources.c:875)
        registry.setEnabled(false, id: "a")
        #expect(status(vm, 0) == "Turned off")  // test-sources.c:878
        registry.setEnabled(true, id: "a")
        #expect(status(vm, 0) == "Used for this place (2 forecast models)")  // test-sources.c:880
        #expect(status(vm, 1) == "Not used for this place")  // test-sources.c:881
        try registry.addProvider(FakeProvider(id: "c"))  // test-sources.c:882
        #expect(status(vm, 2) == "Not used for this place")  // test-sources.c:883
    }

    @Test func statusNewRowUsesStoredForecast() throws {
        // C: /sources/status/new-row-uses-forecast
        let registry = try makeRegistry(["a"])
        let vm = makeModel(registry, Toggles())
        vm.setForecast(try forecast([("b", .failed, .rateLimited, 0)]))
        try registry.addProvider(FakeProvider(id: "b"))  // test-sources.c:895
        #expect(status(vm, 0) == "Not used for this place")  // test-sources.c:896
        #expect(status(vm, 1) == "Could not load: rate limited")  // test-sources.c:897
    }

    // MARK: - Licence lines

    @Test func licenceKnownIDs() throws {
        // C: /sources/licence/known-ids
        let vm = makeModel(try makeRegistry(["open-meteo", "met-no", "nws"]), Toggles())  // test-sources.c:907
        let om = try #require(vm.rows[0].licence)
        #expect(om.text == "Open-Meteo data is licensed CC BY 4.0")  // test-sources.c:912
        #expect(om.before == "Open-Meteo data is licensed ")  // test-sources.c:915
        #expect(om.link?.text == "CC BY 4.0")  // test-sources.c:916
        #expect(om.link?.urlString == "https://creativecommons.org/licenses/by/4.0/")  // test-sources.c:916
        let mn = try #require(vm.rows[1].licence)
        #expect(mn.text == "MET Norway data: CC BY 4.0 / NLOD")  // test-sources.c:919
        #expect(mn.before == "MET Norway data: ")  // test-sources.c:921
        #expect(mn.link?.text == "CC BY 4.0 / NLOD")  // test-sources.c:922
        #expect(mn.link?.urlString == "https://api.met.no/doc/License")  // test-sources.c:922
        let nws = try #require(vm.rows[2].licence)
        #expect(
            nws.text
                == "NOAA/National Weather Service data is US government work, "
                + "credited as a courtesy")  // test-sources.c:926-927
        #expect(nws.link == nil)  // test-sources.c:928
    }

    @Test func licenceAbsentForOtherIDs() throws {
        // C: /sources/licence/absent-for-other-ids
        let ids = ["fake", "open-meteo2", "nws-x", "x", "met", "open", "xopen-meteo", "a_b"]  // test-sources.c:939-940
        let vm = makeModel(try makeRegistry(ids), Toggles())
        #expect(vm.rows.count == 8)  // test-sources.c:943
        for row in vm.rows {
            #expect(row.licence == nil)  // test-sources.c:946-947
            #expect(row.status == "No forecast loaded yet")  // test-sources.c:950
        }
    }

    // MARK: - Attribution

    @Test func attributionHTTPSLink() throws {
        // C: /sources/attribution/https-link
        let vm = makeModel(try makeRegistry(["a"]), Toggles())
        let a = try #require(vm.rows[0].attribution)
        #expect(a.text == "Fake data (a)")  // test-sources.c:966
        #expect(a.link?.text == "Fake data (a)")  // test-sources.c:968
        #expect(a.link?.urlString == "https://example.invalid/")  // test-sources.c:968
        #expect(a.link?.url != nil)
    }

    @Test func attributionURLAcceptedEdgeCases() throws {
        // C: /sources/attribution/url-accepted-edges
        let maxURL = "https://" + String(repeating: "a", count: WxLimits.sourceURLMax - 8)  // test-sources.c:975-976
        #expect(maxURL.utf8.count == 512)  // test-sources.c:977 (WX_SOURCE_URL_MAX)
        let registry = WxRegistry()
        try registry.addProvider(TextProvider("max", "Max", "T", maxURL))  // test-sources.c:979
        try registry.addProvider(TextProvider("one", "One", "T", "https://x"))  // test-sources.c:980
        try registry.addProvider(TextProvider("uni", "Uni", "T", "https://exämple.invalid/ü?a=1&b=2"))  // test-sources.c:981
        let vm = makeModel(registry, Toggles())
        for row in vm.rows {
            #expect(row.attribution?.link != nil, "\(row.id)")  // test-sources.c:983-984
        }
        #expect(vm.rows[0].attribution?.link?.urlString == maxURL)  // test-sources.c:985-987
        #expect(vm.rows[0].attribution?.link?.text == "T")  // test-sources.c:985
        #expect(vm.rows[2].attribution?.link?.urlString == "https://exämple.invalid/ü?a=1&b=2")  // test-sources.c:989
    }

    @Test func attributionUnacceptableURLsGivePlainText() throws {
        // C: /sources/attribution/unacceptable-urls-plain
        let tooLong = "https://" + String(repeating: "a", count: WxLimits.sourceURLMax - 7)  // test-sources.c:995-996
        #expect(tooLong.utf8.count == 513)  // test-sources.c:997
        let veryLong = "https://" + String(repeating: "a", count: 100000)  // test-sources.c:998-999
        let texts: [String] = [
            "http://example.invalid/",  // test-sources.c:1001
            "javascript:alert(1)",  // test-sources.c:1002
            "ftp://example.invalid/",  // test-sources.c:1003
            "HTTPS://example.invalid/",  // test-sources.c:1004
            " https://example.invalid/",  // test-sources.c:1005
            "//example.invalid/",  // test-sources.c:1006
            "https://",  // test-sources.c:1007
            "https:/",  // test-sources.c:1008
            "https:example.invalid/",  // test-sources.c:1009
            "https//example.invalid/",  // test-sources.c:1010
            "httpss://example.invalid/",  // test-sources.c:1011
            "https:\\\\example.invalid/",  // test-sources.c:1012
            "https://example.invalid/a<b",  // test-sources.c:1013
            "https://example.invalid/a b",  // test-sources.c:1015
            "https://example.invalid/<b>",  // test-sources.c:1020
            "https://example.invalid/a>b",  // test-sources.c:1021
            "https://example.invalid/\"x\"",  // test-sources.c:1022
            "https://example.invalid/\"onmouseover=\"x",  // test-sources.c:1023
        ]
        let base = Array("https://example.invalid/a".utf8)
        let slash = Array("https://example.invalid/".utf8)
        let byteURLs: [[UInt8]] = [
            Array(tooLong.utf8), Array(veryLong.utf8),
            base + [0x09, 0x62],  // "a\tb", test-sources.c:1016
            base + [0x0A, 0x62],  // "a\nb", test-sources.c:1017
            base + [0x01, 0x62],  // "a\x01" "b", test-sources.c:1018
            base + [0x7F, 0x62],  // "a\x7f" "b", test-sources.c:1019
            slash + [0xFF],  // test-sources.c:1024
            slash + [0xC3],  // test-sources.c:1025
            slash + [0xE2, 0x80, 0xAE, 0x78],  // U+202E, test-sources.c:1026
            slash + [0xC2, 0xA0, 0x78],  // U+00A0, test-sources.c:1027
            slash + [0xE2, 0x80, 0xA8, 0x78],  // U+2028, test-sources.c:1028
            slash + [0xC2, 0x85, 0x78],  // U+0085, test-sources.c:1029
        ] + texts.map { Array($0.utf8) }
        for (i, url) in byteURLs.enumerated() {
            #expect(!SourcesViewModel.isAcceptableURL(bytes: url), "url #\(i)")
            let row = SourcesViewModel.makeRow(
                id: "p", nameBytes: Array("Name".utf8), attributionBytes: Array("Credit line".utf8),
                attributionURLBytes: url, enabled: true, status: "")
            #expect(row.attribution == SourcesViewModel.TextLine(before: "Credit line", link: nil, after: ""),
                    "url #\(i)")  // test-sources.c:1040-1041 (plain, visible)
        }
        // The String-typed path through a registered provider gives the same plain text.
        let registry = WxRegistry()
        try registry.addProvider(TextProvider("p", "Name", "Credit line", "http://example.invalid/"))
        let vm = makeModel(registry, Toggles())
        #expect(vm.rows[0].attribution?.text == "Credit line")  // test-sources.c:1040
        #expect(vm.rows[0].attribution?.link == nil)  // test-sources.c:1039
    }

    @Test func attributionTextAndURLAreNotInterpreted() throws {
        // C: /sources/attribution/escaped (no markup in SwiftUI: the texts stay literal)
        let registry = WxRegistry()
        try registry.addProvider(TextProvider(
            "evil", "<b>&amp;\"", "<b>&amp;\" </a><a href='x'>",
            "https://example.invalid/?a=1&b='2'&c=%3Cb%3E"))  // test-sources.c:1051-1052
        let row = makeModel(registry, Toggles()).rows[0]
        #expect(row.name == "<b>&amp;\"")  // test-sources.c:1056
        #expect(row.attribution?.text == "<b>&amp;\" </a><a href='x'>")  // test-sources.c:1059
        #expect(row.attribution?.link?.urlString == "https://example.invalid/?a=1&b='2'&c=%3Cb%3E")  // :1061
        #expect(row.attribution?.text.unicodeScalars.count == 26)  // test-sources.c:1064
    }

    @Test func hostileTextsAreSanitised() throws {
        // C: /sources/attribution/hostile-sanitised; the C bytes, test-sources.c:1072-1073
        let name: [UInt8] = [0x41, 0x01, 0x42, 0x0A, 0x43, 0x09, 0x44, 0xFF, 0x45, 0xE2, 0x80, 0xAE, 0x46]
        let attribution: [UInt8] = [0x58, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x59, 0x0D, 0x0A, 0x5A, 0xC3]
        let row = SourcesViewModel.makeRow(
            id: "ctl", nameBytes: name, attributionBytes: attribution,
            attributionURLBytes: Array("https://example.invalid/".utf8), enabled: true, status: "")
        #expect(Array(row.name.utf8) == [0x41, 0x42, 0x43, 0x44, 0xEF, 0xBF, 0xBD, 0x45, 0x46])  // :1076
        #expect(Array((row.attribution?.text ?? "").utf8)
                == [0x58, 0x5B, 0x33, 0x31, 0x6D, 0x59, 0x5A, 0xEF, 0xBF, 0xBD])  // test-sources.c:1079
        #expect(Array(row.accessibilityLabel.utf8)
                == Array("Use ".utf8) + [0x41, 0x42, 0x43, 0x44, 0xEF, 0xBF, 0xBD, 0x45, 0x46])  // :1080-1081
    }

    @Test func emptyNameShowsIDAndEmptyAttributionHides() throws {
        // C: /sources/attribution/empty-name-and-text (test-sources.c:1088-1090)
        let cases: [(String, [UInt8]?, [UInt8]?, [UInt8]?)] = [
            ("blank", [0x01, 0x02, 0x0A], [0x03, 0x09], Array("https://example.invalid/".utf8)),
            ("none", [], [], []),
            ("null", nil, nil, nil),
        ]
        for (id, name, attribution, url) in cases {
            let row = SourcesViewModel.makeRow(
                id: id, nameBytes: name, attributionBytes: attribution, attributionURLBytes: url,
                enabled: true, status: "")
            #expect(row.name == id)  // test-sources.c:1094
            #expect(row.attribution == nil)  // test-sources.c:1096-1097
            #expect(row.accessibilityLabel == "Use " + id)  // test-sources.c:1098-1099
        }
        let registry = WxRegistry()
        try registry.addProvider(TextProvider("none", "", "", ""))  // test-sources.c:1089
        let row = makeModel(registry, Toggles()).rows[0]
        #expect(row.name == "none")  // test-sources.c:1094
        #expect(row.attribution == nil)  // test-sources.c:1096
    }

    @Test func missingURLGivesPlainText() throws {
        // C: /sources/attribution/missing-url-plain
        let row = SourcesViewModel.makeRow(
            id: "nourl", nameBytes: Array("No URL".utf8), attributionBytes: Array("Credit".utf8),
            attributionURLBytes: nil, enabled: true, status: "")  // test-sources.c:1107
        #expect(row.attribution == SourcesViewModel.TextLine(before: "Credit", link: nil, after: ""))  // :1111-1112
    }

    // MARK: - Bounds

    @Test func labelsAreBounded() throws {
        // C: /sources/bounds/labels-wrap (the width bound; wrapping is the view's job)
        #expect(SourcesViewModel.maxWidthChars == 40)  // test-sources.c:1134
    }

    @Test func hugeTextsAreBounded() throws {
        // C: /sources/bounds/huge-texts
        let hugeWord = String(repeating: "W", count: 5000)  // test-sources.c:1152
        let hugeText = hugeWord + " " + hugeWord  // test-sources.c:1153
        let registry = WxRegistry()
        try registry.addProvider(TextProvider("a", hugeText, hugeText, "https://example.invalid/"))
        for i in 1..<16 {
            try registry.addProvider(TextProvider("p\(i)", hugeWord, hugeWord, "https://example.invalid/"))
        }
        let vm = makeModel(registry, Toggles())
        #expect(vm.rows.count == 16)  // test-sources.c:1165
        for row in vm.rows {
            #expect(row.name.utf8.count <= 256)  // test-sources.c:1167 (WX_SOURCE_TEXT_MAX)
            #expect((row.attribution?.text.utf8.count ?? 0) <= 256)  // test-sources.c:1168
        }
    }

    // MARK: - Note and About

    @Test func noteTextExact() throws {
        // C: /sources/note/text-exact
        #expect(
            SourcesViewModel.note
                == "Forecasts blend several sources with fixed, documented weights. These "
                + "weights are rules of thumb, not statistics measured from past accuracy, so "
                + "no accuracy figure is claimed.")  // test-sources.c:1187-1190
    }

    @Test func aboutEmitsSignal() throws {
        // C: /sources/about/emits-signal
        var about = 0
        let toggles = Toggles()
        let vm = SourcesViewModel(registry: WxRegistry(), onToggle: { toggles.handle($0, $1) }, onAbout: { about += 1 })
        vm.requestAbout()
        #expect(about == 1)  // test-sources.c:1205
        vm.requestAbout()
        #expect(about == 2)  // test-sources.c:1207
        #expect(toggles.count == 0)  // test-sources.c:1208
    }

    @Test func aboutFieldsVerbatim() throws {
        // C: /window/sources/about-dialog (show_about, src/ui/wx-window.c:672-678)
        #expect(AboutInfo.programName == "Weather")  // wx-window.c:672
        #expect(AboutInfo.version == "0.1.0")  // meson.build:3 (WX_APP_VERSION, src/ui/meson.build:52)
        #expect(AboutInfo.comments
                == "Weather forecasts from several free sources, with the rain you can expect and when.")  // wx-window.c:673-675
        #expect(Array(AboutInfo.copyright.utf8)
                == Array("Copyright ".utf8) + [0xC2, 0xA9] + Array(" 2026 wtp128pro".utf8))  // wx-window.c:676
        #expect(AboutInfo.licenseSPDX == "GPL-3.0-or-later")  // GTK_LICENSE_GPL_3_0, wx-window.c:676-677
        #expect(AboutInfo.website == "https://github.com/wtp128pro/weather")  // wx-window.c:677
        #expect(AboutInfo.logoIconName == AppModel.appID)  // "logo-icon-name", WX_APP_ID, wx-window.c:678
    }

    // MARK: - The shipped providers and the app model

    @Test func shippedProvidersVerbatim() throws {
        // C: /window/sources/attribution-and-failed-status (provider identities)
        let vm = makeModel(AppEnvironment.makeRegistry(), Toggles())
        let byID = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.id, $0) })
        let expected: [(String, String, String, String)] = [
            ("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/"),  // wx-openmeteo.c:14-16
            ("nws", "National Weather Service", "Source: NOAA/National Weather Service", "https://www.weather.gov/"),  // wx-nws.c:19-21
            ("met-no", "MET Norway", "Data from MET Norway", "https://api.met.no/"),  // wx-metno.h:13-14
        ]
        #expect(vm.rows.count == expected.count)
        for (id, name, text, url) in expected {
            let row = try #require(byID[id])
            #expect(row.name == name)
            #expect(row.accessibilityLabel == "Use " + name)
            #expect(row.attribution?.link == SourcesViewModel.Link(text: text, urlString: url))
            #expect(row.attribution?.link?.url?.absoluteString == url)
            #expect(row.licence != nil)  // test-sources.c:907 (the three table ids)
            #expect(row.isEnabled)
            #expect(row.status == "No forecast loaded yet")
        }
    }

    @Test func modelBackedTogglesGoThroughTheAppModel() async throws {
        // C: /window/sources/status-and-toggle (the owner applies the toggle)
        let dir = try TemporaryDirectory("sources-vm")
        let home = dir.url
        let registry = try makeRegistry(["a", "b"])
        let model = AppModel(
            registry: registry, storage: AppEnvironment.StorageRoot(home: home),
            clock: ManualClock(), online: false, log: { _, _ in })
        let vm = SourcesViewModel(model: model)
        vm.setEnabled(false, forProviderID: "a")  // refused before the load: snaps back
        #expect(vm.rows[0].isEnabled)
        await model.load()
        vm.setEnabled(false, forProviderID: "a")
        #expect(!registry.isEnabled(id: "a"))
        #expect(vm.rows.map(\.status) == ["Turned off", "No forecast loaded yet"])  // test-sources.c:569, :576
        vm.setForecast(try forecast([("b", .ok, nil, 2)]))  // ignored: follows the selection
        #expect(vm.rows[1].status == "No forecast loaded yet")
        withExtendedLifetime(dir) {}
    }
}
