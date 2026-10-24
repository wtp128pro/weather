// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PickerViewModelTests.swift - the BEHAVIOURAL cases of src/ui/test-picker.c
// (registrations test-picker.c:2738-2807) on PickerViewModel, plus the
// first-run page data (cartography ui-widgets.md:98-114) on FirstRunViewModel.
// The C fixture's fake service (fake_pending / fake_complete / fake_fail /
// fake_is_cancelled) is PendingGeocoder below, registered as the geocoder of
// a loaded AppModel, so every search goes through AppModel.search and the
// ServiceOrchestrator like the C picker's goes through WxService. The C tests'
// wall-clock waits are ManualClock steps of the picker's clock.

import Foundation
import Observation
import Synchronization
import Testing
@testable import WeatherCore

/// The C fixture's fake geocoder (test-picker.c fake_*): every search stays pending until the
/// test completes it; a cancellation is recorded and, unless `ignoreCancel`, ends the search.
private final class PendingGeocoder: WxGeocoder {
    private struct Request {
        let text: String
        var cancelled = false
        var outcome: Result<[WxPlace], any Error>?
        var continuation: CheckedContinuation<[WxPlace], any Error>?
    }

    private struct State {
        var requests: [Request] = []
        var ignoreCancel = false
    }

    private let state = Mutex(State())

    /// fake->ignore_cancel.
    var ignoreCancel: Bool {
        get { state.withLock { $0.ignoreCancel } }
        set { state.withLock { $0.ignoreCancel = newValue } }
    }

    /// fake_n: how many searches reached the geocoder.
    var count: Int { state.withLock { $0.requests.count } }

    /// fake_pending(i)->text.
    func text(_ i: Int) -> String? {
        state.withLock { $0.requests.indices.contains(i) ? $0.requests[i].text : nil }
    }

    /// fake_is_cancelled(i).
    func isCancelled(_ i: Int) -> Bool {
        state.withLock { $0.requests.indices.contains(i) && $0.requests[i].cancelled }
    }

    /// fake_complete / fake_fail / fake_fail_cancelled.
    func finish(_ i: Int, _ outcome: Result<[WxPlace], any Error>) {
        let continuation: CheckedContinuation<[WxPlace], any Error>? = state.withLock { s in
            guard s.requests.indices.contains(i), s.requests[i].outcome == nil else {
                return nil
            }
            s.requests[i].outcome = outcome
            let c = s.requests[i].continuation
            s.requests[i].continuation = nil
            return c
        }
        continuation?.resume(with: outcome)
    }

    func complete(_ i: Int, _ places: [WxPlace]) { finish(i, .success(places)) }
    func fail(_ i: Int, _ error: any Error) { finish(i, .failure(error)) }
    func failCancelled(_ i: Int) { finish(i, .failure(CancellationError())) }

    /// Ends every search still pending (end of a test).
    func finishAll() {
        for i in 0 ..< count {
            failCancelled(i)
        }
    }

    func search(textBytes: [UInt8]) async throws -> [WxPlace] {
        let index = state.withLock { s in
            s.requests.append(Request(text: String(decoding: textBytes, as: UTF8.self)))
            return s.requests.count - 1
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[WxPlace], any Error>) in
                let ready: Result<[WxPlace], any Error>? = state.withLock { s in
                    if let outcome = s.requests[index].outcome {
                        return outcome
                    }
                    s.requests[index].continuation = c
                    return nil
                }
                if let ready {
                    c.resume(with: ready)
                }
            }
        } onCancel: {
            let ignore = state.withLock { s -> Bool in
                s.requests[index].cancelled = true
                return s.ignoreCancel
            }
            if !ignore {
                failCancelled(index)
            }
        }
    }
}

/// A flag an observation callback can set from any context.
private final class Flag: Sendable {
    private let state = Mutex(false)
    var value: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// An error of another domain (G_FILE_ERROR in /picker/errors/foreign-and-missing).
private struct ForeignError: LocalizedError {
    let errorDescription: String?
}

/// The C Fx: an AppModel over a registry whose geocoder is the pending fake, and a picker.
@MainActor
private final class Fx {
    let dir: TemporaryDirectory
    let geocoder = PendingGeocoder()
    /// The registry the model searches through (wx_registry_set_geocoder).
    let registry: WxRegistry
    /// The picker's clock (debounce and Enter guard).
    let clock = ManualClock()
    let model: AppModel
    let vm: PickerViewModel
    var addedKeys: [String] = []
    var closeRequests = 0
    /// What the owner does on a close request: by default the window is destroyed.
    var destroyOnClose = true

    private init(dir: TemporaryDirectory, registry: WxRegistry, model: AppModel) {
        self.dir = dir
        self.registry = registry
        self.model = model
        vm = PickerViewModel(model: model, clock: clock)
        vm.onPlaceAdded = { [unowned self] key in self.addedKeys.append(key) }
        vm.onCloseRequest = { [unowned self] in
            self.closeRequests += 1
            if self.destroyOnClose {
                self.vm.invalidate()
            }
        }
    }

    static func make(_ label: String, geocoder custom: (any WxGeocoder)? = nil) async throws -> Fx {
        let dir = try TemporaryDirectory("picker-\(label)")
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let registry = WxRegistry()
        let model = AppModel(registry: registry, storage: storage, clock: ManualClock(), online: true,
                             log: { _, _ in })
        await model.load()
        let fx = Fx(dir: dir, registry: registry, model: model)
        registry.geocoder = custom ?? fx.geocoder
        return fx
    }

    func finish() {
        geocoder.finishAll()
        vm.invalidate()
    }

    /// Waits (at most `timeoutMs`; the full scheme runs other suites on the main actor at the
    /// same time) until `n` searches reached the geocoder.
    func waitRequests(_ n: Int, timeoutMs: Int = 5_000) async -> Bool {
        await waitFor(timeoutMs) { self.geocoder.count >= n }
    }

    /// Lets an armed debounce timer reach its sleep (at most 1 s, so that a picker that armed
    /// none fails its expectations instead of hanging). The deadline is fixed when the timer is
    /// armed, so advancing the clock before the sleep starts changes nothing.
    func waitTimer() async {
        _ = await waitFor(1_000) { self.clock.pendingSleeperCount >= 1 }
    }

    /// search_for: sets the text, lets the debounce timer fire, waits for the request.
    /// - Returns: the index of the request.
    func searchFor(_ text: String) async -> Int {
        let n = geocoder.count
        vm.setText(text)
        await waitTimer()
        await clock.advance(by: Int64(PickerViewModel.searchDelayMs) * 1000)
        let arrived = await waitRequests(n + 1)
        #expect(arrived, "no search for \(text)")
        return n
    }

    /// show_results: a search for `text` answered with `places`; waits for `n` rows.
    func showResults(_ text: String, _ places: [WxPlace], _ n: Int) async {
        let i = await searchFor(text)
        geocoder.complete(i, places)
        let shown = await waitFor { self.vm.results.count == n && !self.vm.isSearchInFlight }
        #expect(shown, "rows for \(text)")
    }

    var labels: [String] { vm.rows.map(\.label) }
}

/// Polls `condition` (the C WXT_WAIT_FOR) for up to `timeoutMs` of real time.
@MainActor
private func waitFor(_ timeoutMs: Int = 5_000, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// mk_place (test-picker.c:170-177).
private func mkPlace(_ name: String, _ admin1: String, _ country: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, admin1: admin1, country: country, countryCode: "US", lat: lat, lon: lon,
                timezone: "America/New_York")
}

/// sample_places (test-picker.c:188-197): "Springfield <i>", Illinois, 2-degree grid.
private func samplePlaces(_ n: Int) throws -> [WxPlace] {
    try (0 ..< n).map { i in
        try mkPlace("Springfield \(i)", "Illinois", "United States", 40.0 + Double(i / 10) * 2.0,
                    -100.0 + Double(i % 10) * 2.0)
    }
}

/// sample_hits (test-picker.c:200-207).
private func sampleHits() throws -> [WxPlace] {
    [try mkPlace("Miami", "Florida", "United States", 25.7743, -80.1937),
     try mkPlace("Miami", "Oklahoma", "United States", 36.8748, -94.8775),
     try mkPlace("Miami Beach", "Florida", "United States", 25.7907, -80.1300)]
}

private let searching = "Searching\u{2026}"
private let delayUs = Int64(PickerViewModel.searchDelayMs) * 1000

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct PickerViewModelTests {
    // MARK: - Construct and constants

    // C: /picker/construct/initial-state
    @Test("/picker/construct/initial-state")
    func initialState() async throws {
        let fx = try await Fx.make("initial")
        defer { fx.finish() }
        #expect(PickerViewModel.windowTitle == "Add a city")  // test-picker.c:583
        #expect(fx.vm.text == "")  // test-picker.c:598
        #expect(PickerViewModel.searchPlaceholder == "Search for a city")  // test-picker.c:599
        #expect(PickerViewModel.searchAccessibilityLabel == "Search for a city")  // test-picker.c:602
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:612
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusStyle == .dim)
        #expect(!fx.vm.isDebouncePending)
        #expect(!fx.vm.isSearchInFlight)
        #expect(PickerViewModel.defaultWidth == 460 && PickerViewModel.defaultHeight == 520)  // wx-picker.c:1249
    }

    // C: /picker/construct/constants
    @Test("/picker/construct/constants")
    func constants() {
        #expect(PickerViewModel.searchDelayMs == 300)  // test-picker.c:633
        #expect(PickerViewModel.maxQueryChars == 64)  // test-picker.c:634
        #expect(PickerViewModel.minQueryBytes == 2)  // test-picker.c:635
        #expect(PickerViewModel.maxMessageBytes == 200)  // test-picker.c:636
        #expect(PickerViewModel.maxQueryBytes == 64)  // test-picker.c:2036
        #expect(PickerViewModel.maxResults == 20)  // test-picker.c:1332
    }

    // MARK: - Suggestions

    // C: /picker/suggestions/places
    @Test("/picker/suggestions/places")
    func suggestedPlaces() {
        let expect: [(String, String, String, Double, Double)] = [  // test-picker.c:649-655
            ("Miami", "25.7743,-80.1937", "Miami, Florida, United States", 25.7743, -80.1937),
            ("Orlando", "28.5383,-81.3792", "Orlando, Florida, United States", 28.5383, -81.3792),
            ("Tampa", "27.9475,-82.4584", "Tampa, Florida, United States", 27.9475, -82.4584),
            ("Jacksonville", "30.3322,-81.6557", "Jacksonville, Florida, United States", 30.3322, -81.6557),
            ("Key West", "24.5551,-81.7800", "Key West, Florida, United States", 24.5551, -81.7800),
        ]
        let a = PickerViewModel.suggestedPlaces()
        #expect(a.count == expect.count)
        for (p, e) in zip(a, expect) {
            #expect(p.name == e.0)
            #expect(p.admin1 == "Florida")  // test-picker.c:664
            #expect(p.country == "United States")  // test-picker.c:665
            #expect(p.countryCode == "US")  // test-picker.c:666
            #expect(p.timezone == "America/New_York")  // test-picker.c:667
            #expect(p.lat == e.3 && p.lon == e.4)
            #expect(p.key == e.1)
            #expect(p.label == e.2)
        }
    }

    // C: /picker/suggestions/rows
    @Test("/picker/suggestions/rows")
    func initialRows() async throws {
        let fx = try await Fx.make("rows")
        defer { fx.finish() }
        #expect(fx.vm.results == PickerViewModel.suggestedPlaces())
        #expect(fx.vm.rows.count == 5)  // test-picker.c:692
        #expect(fx.vm.rows.allSatisfy { !$0.isAdded })
    }

    // MARK: - Empty text

    // C: /picker/empty/restores-suggestions
    @Test("/picker/empty/restores-suggestions")
    func emptyRestoresSuggestions() async throws {
        let fx = try await Fx.make("empty-restore")
        defer { fx.finish() }
        await fx.showResults("mia", try sampleHits(), 3)
        fx.vm.setText("")
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:712
        #expect(fx.vm.results == PickerViewModel.suggestedPlaces())
    }

    // C: /picker/empty/cancels
    @Test("/picker/empty/cancels")
    func emptyCancels() async throws {
        let fx = try await Fx.make("empty-cancel")
        defer { fx.finish() }
        let i = await fx.searchFor("mia")
        #expect(fx.vm.statusText == searching)  // test-picker.c:727
        fx.vm.setText("")
        #expect(fx.geocoder.isCancelled(i))
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:730
        // a pending timer is cancelled too
        fx.vm.setText("mia")
        #expect(fx.vm.isDebouncePending)
        fx.vm.setText("   ")
        #expect(!fx.vm.isDebouncePending)
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:742
        await fx.clock.advance(by: delayUs + 250_000)
        #expect(fx.geocoder.count == 1)
    }

    // MARK: - Debounce

    // C: /picker/debounce/not-early
    @Test("/picker/debounce/not-early")
    func debounceNotEarly() async throws {
        let fx = try await Fx.make("not-early")
        defer { fx.finish() }
        fx.vm.setText("mia")
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs - 1_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 0)  // test-picker.c:768
        #expect(fx.vm.statusText == "Suggestions")
        await fx.clock.advance(by: 1_000)
        #expect(await fx.waitRequests(1))  // test-picker.c:769
    }

    // C: /picker/debounce/one-request
    @Test("/picker/debounce/one-request")
    func debounceOneRequest() async throws {
        let fx = try await Fx.make("one-request")
        defer { fx.finish() }
        _ = await fx.searchFor("mia")
        await fx.clock.advance(by: delayUs + 200_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(fx.geocoder.text(0) == "mia")  // test-picker.c:784
        #expect(!fx.geocoder.isCancelled(0))
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusText == searching)  // test-picker.c:787
        #expect(fx.vm.statusStyle == .dim)
    }

    // C: /picker/debounce/restarts
    @Test("/picker/debounce/restarts")
    func debounceRestarts() async throws {
        let fx = try await Fx.make("restarts")
        defer { fx.finish() }
        for text in ["ma", "mia", "miam", "miami"] {  // test-picker.c:799
            fx.vm.setText(text)
            await fx.waitTimer()
            await fx.clock.advance(by: 100_000)
            #expect(fx.geocoder.count == 0)
        }
        await fx.clock.advance(by: delayUs - 100_000)
        #expect(await fx.waitRequests(1))
        await fx.clock.advance(by: delayUs + 100_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(fx.geocoder.text(0) == "miami")  // test-picker.c:812
    }

    // C: /picker/debounce/trims
    @Test("/picker/debounce/trims")
    func debounceTrims() async throws {
        let fx = try await Fx.make("trims")
        defer { fx.finish() }
        let i = await fx.searchFor("  \t Key  West \n ")
        #expect(fx.geocoder.text(i) == "Key  West")  // test-picker.c:822
    }

    // C: /picker/debounce/many-edits
    @Test("/picker/debounce/many-edits")
    func manyQuickEdits() async throws {
        let fx = try await Fx.make("many-edits")
        defer { fx.finish() }
        var s = ""
        for i in 0 ..< 40 {
            s += String(UnicodeScalar(UInt8(ascii: "a") + UInt8(i % 26)))
            fx.vm.setText(s)
            await fx.clock.advance(by: 10_000)
        }
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await fx.waitRequests(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(fx.geocoder.text(0) == s)  // test-picker.c:840 (the final text)
    }

    // C: /picker/debounce/edit-cancels-in-flight
    @Test("/picker/debounce/edit-cancels-in-flight")
    func editCancelsInFlight() async throws {
        let fx = try await Fx.make("edit-cancels")
        defer { fx.finish() }
        let a = await fx.searchFor("mia")
        fx.vm.setText("miam")
        #expect(fx.geocoder.isCancelled(a))
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await fx.waitRequests(2))
        #expect(fx.geocoder.text(1) == "miam")  // test-picker.c:855
    }

    // MARK: - Short text

    // C: /picker/short/one-character
    @Test("/picker/short/one-character")
    func oneCharacter() async throws {
        let fx = try await Fx.make("one-char")
        defer { fx.finish() }
        fx.vm.setText("m")
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:874
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusStyle == .dim)
        #expect(fx.vm.results.isEmpty)  // test-picker.c:878
        await fx.clock.advance(by: delayUs + 250_000)
        #expect(fx.geocoder.count == 0)
        fx.vm.setText("  q \t")
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:884
        await fx.clock.advance(by: delayUs + 250_000)
        #expect(fx.geocoder.count == 0)
        let i = await fx.searchFor("mia")
        fx.vm.setText("m")
        #expect(fx.geocoder.isCancelled(i))
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:892
        fx.vm.setText("mi")
        fx.vm.setText("m")
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        let j = await fx.searchFor("\u{E9}")
        #expect(fx.geocoder.text(j) == "\u{E9}")  // test-picker.c:901
        let k = await fx.searchFor("ab")
        #expect(fx.geocoder.text(k) == "ab")  // test-picker.c:903
    }

    // MARK: - Enter

    // C: /picker/enter/at-once
    @Test("/picker/enter/at-once")
    func enterAtOnce() async throws {
        let fx = try await Fx.make("enter-at-once")
        defer { fx.finish() }
        fx.vm.setText(" mia ")
        #expect(fx.geocoder.count == 0)
        fx.vm.submit()
        #expect(await fx.waitRequests(1))
        #expect(fx.geocoder.text(0) == "mia")  // test-picker.c:922
        #expect(fx.vm.statusText == searching)  // test-picker.c:923
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(!fx.geocoder.isCancelled(0))
    }

    // C: /picker/enter/in-flight-is-not-replaced
    @Test("/picker/enter/in-flight-is-not-replaced")
    func enterInFlightNotReplaced() async throws {
        let fx = try await Fx.make("enter-in-flight")
        defer { fx.finish() }
        let a = await fx.searchFor("mia")
        fx.vm.submit()
        #expect(fx.geocoder.count == 1)
        #expect(!fx.geocoder.isCancelled(a))
        #expect(fx.vm.statusText == searching)  // test-picker.c:955
        fx.vm.setText("mia ")
        #expect(fx.geocoder.isCancelled(a))
        fx.vm.submit()
        #expect(await fx.waitRequests(2))
        #expect(fx.geocoder.text(1) == "mia")  // test-picker.c:963
        fx.vm.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 2)
        #expect(!fx.geocoder.isCancelled(1))
        fx.vm.setText("mia b")
        fx.vm.submit()
        #expect(await fx.waitRequests(3))
        #expect(fx.geocoder.isCancelled(1))
        #expect(fx.geocoder.text(2) == "mia b")  // test-picker.c:973
    }

    // C: /picker/enter/held-down-starts-one-search
    @Test("/picker/enter/held-down-starts-one-search")
    func enterHeldDown() async throws {
        let fx = try await Fx.make("enter-held")
        defer { fx.finish() }
        _ = await fx.searchFor("Miami")
        for _ in 0 ..< 60 {  // test-picker.c:990
            fx.vm.submit()
            await fx.clock.advance(by: 33_000)
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(!fx.geocoder.isCancelled(0))
        #expect(fx.vm.statusText == searching)  // test-picker.c:996
        fx.vm.setText("Orlando")
        for _ in 0 ..< 60 {
            fx.vm.submit()
            await fx.clock.advance(by: 33_000)
        }
        #expect(await fx.waitRequests(2))
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 2)
        #expect(fx.geocoder.isCancelled(0))
        #expect(!fx.geocoder.isCancelled(1))
        #expect(fx.geocoder.text(1) == "Orlando")  // test-picker.c:1007
    }

    // C: /picker/enter/answered-repeats-after-the-delay
    @Test("/picker/enter/answered-repeats-after-the-delay")
    func enterRepeatsAfterDelay() async throws {
        let fx = try await Fx.make("enter-repeat")
        defer { fx.finish() }
        let a = await fx.searchFor("mia")
        fx.geocoder.complete(a, try sampleHits())
        #expect(await waitFor { !fx.vm.isStatusVisible })
        for _ in 0 ..< 60 { fx.vm.submit() }  // all within the delay
        #expect(fx.geocoder.count == 1)
        #expect(!fx.vm.isStatusVisible)
        await fx.clock.advance(by: delayUs + 50_000)
        fx.vm.submit()
        #expect(await fx.waitRequests(2))
        #expect(fx.vm.statusText == searching)  // test-picker.c:1037
        fx.geocoder.fail(1, WxError(.network, "offline"))  // test-picker.c:1041
        #expect(await waitFor { fx.vm.statusStyle == .error })
        for _ in 0 ..< 60 { fx.vm.submit() }
        #expect(fx.geocoder.count == 2)
        #expect(fx.vm.statusStyle == .error)
        await fx.clock.advance(by: delayUs + 50_000)
        fx.vm.submit()  // the retry
        #expect(await fx.waitRequests(3))
        #expect(fx.vm.statusText == searching)  // test-picker.c:1053
        #expect(fx.vm.statusStyle == .dim)
    }

    // C: /picker/enter/edit-or-cancellation-forgets
    @Test("/picker/enter/edit-or-cancellation-forgets")
    func enterAfterEditOrCancellation() async throws {
        let fx = try await Fx.make("enter-forgets")
        defer { fx.finish() }
        let a = await fx.searchFor("mia")
        fx.geocoder.complete(a, try sampleHits())
        #expect(await waitFor { !fx.vm.isStatusVisible })
        fx.vm.setText("mia ")
        fx.vm.submit()
        #expect(await fx.waitRequests(2))
        #expect(fx.geocoder.text(1) == "mia")  // test-picker.c:1075
        fx.geocoder.failCancelled(1)
        #expect(await waitFor { !fx.vm.isStatusVisible })
        fx.vm.submit()
        #expect(await fx.waitRequests(3))
        #expect(fx.vm.statusText == searching)  // test-picker.c:1082
    }

    // C: /picker/enter/short-text
    @Test("/picker/enter/short-text")
    func enterShortText() async throws {
        let fx = try await Fx.make("enter-short")
        defer { fx.finish() }
        fx.vm.submit()
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:1095
        fx.vm.setText(" m ")
        fx.vm.submit()
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1098
        fx.vm.setText("   ")
        fx.vm.submit()
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:1101
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 0)
    }

    // MARK: - Query normalisation

    // C: /picker/query/bidi-marks-removed
    @Test("/picker/query/bidi-marks-removed")
    func bidiMarksRemoved() async throws {
        let fx = try await Fx.make("bidi")
        defer { fx.finish() }
        let arabic = "\u{627}\u{644}\u{642}\u{627}\u{647}\u{631}\u{629}"
        let cases: [(String, String)] = [  // test-picker.c:1125-1130
            ("\u{200F}Cairo", "Cairo"), ("Cairo\u{200E}", "Cairo"), ("Ca\u{202E}iro", "Cairo"),
            (arabic + "\u{200F}", arabic), (" \u{200F} Cairo \u{200E} ", "Cairo"),
        ]
        for (typed, query) in cases {
            let a = await fx.searchFor(typed)
            #expect(fx.geocoder.text(a) == query)  // test-picker.c:1135
            #expect(fx.vm.statusText == searching)
            #expect(fx.vm.text == typed)  // the entry is untouched
            fx.vm.setText("")
            let n = fx.geocoder.count
            fx.vm.setText(typed)
            fx.vm.submit()
            #expect(await fx.waitRequests(n + 1))
            #expect(fx.geocoder.text(n) == query)  // test-picker.c:1144
            #expect(WxText.isUsableName(fx.geocoder.text(n), maxBytes: PickerViewModel.maxQueryBytes))
            #expect(fx.vm.statusStyle == .dim)
        }
    }

    // C: /picker/query/unsearchable-has-a-hint
    @Test("/picker/query/unsearchable-has-a-hint")
    func unsearchableHasHint() async throws {
        let fx = try await Fx.make("unsearchable")
        defer { fx.finish() }
        let nbspOnly = ["\u{A0}\u{A0}", " \u{A0}\u{A0} ", "\u{3000}\u{3000}",
                        "\u{200F}\u{A0}\u{A0}\u{200E}"]  // test-picker.c:1163-1166
        for text in nbspOnly {
            fx.vm.setText("")
            fx.vm.setText(text)
            #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1171
            #expect(fx.vm.statusStyle == .dim)
            #expect(fx.vm.results.isEmpty)
            fx.vm.submit()
            await fx.clock.advance(by: delayUs + 250_000)
            #expect(fx.geocoder.count == 0)
            #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1177
        }
        fx.vm.setText("")
        fx.vm.setText("\u{200E}\u{200F}")
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:1182
        fx.vm.submit()
        await fx.clock.advance(by: delayUs + 250_000)
        #expect(fx.geocoder.count == 0)
        fx.vm.setText("")
        fx.vm.setText("m\u{200F}")
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1189
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 0)
        let i = await fx.searchFor("mia")
        fx.vm.setText("")
        fx.vm.setText("\u{A0}\u{A0}")
        #expect(fx.geocoder.isCancelled(i))
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1197
    }

    /// oracle_forbidden (test-picker.c:1205-1211), independent of WxText.
    private static func oracleForbidden(_ c: UInt32) -> Bool {
        (0x01 ... 0x1F).contains(c) || c == 0x7F || (0x80 ... 0x9F).contains(c) || c == 0x2028 || c == 0x2029
            || c == 0x061C || c == 0x200E || c == 0x200F || (0x202A ... 0x202E).contains(c)
            || (0x2066 ... 0x2069).contains(c)
    }

    /// oracle_query (test-picker.c:1213-1230).
    private static func oracleQuery(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.filter { !oracleForbidden($0.value) })
        let q = Array(String(view).utf8)
        func space(_ b: UInt8) -> Bool { b == 0x20 || (0x09 ... 0x0D).contains(b) }
        var start = 0
        var end = q.count
        while start < end && space(q[start]) { start += 1 }
        while end > start && space(q[end - 1]) { end -= 1 }
        return String(decoding: q[start ..< end], as: UTF8.self)
    }

    // C: /picker/query/matches-the-geocoder-rule (GRand replaced by SeededRNG, DECISIONS #17)
    @Test("/picker/query/matches-the-geocoder-rule")
    func queryMatchesGeocoderRule() async throws {
        let fx = try await Fx.make("query-rule")
        defer { fx.finish() }
        let atoms = ["a", "b", "Cairo", " ", "  ", "\u{E9}", "\u{200E}", "\u{200F}", "\u{202E}",
                     "\u{2066}", "\u{61C}", "\u{A0}", "\u{3000}", "\u{2003}", "\u{200B}",
                     "\u{FEFF}", "\u{85}", "\u{2028}", "\t", "\u{01}", "\u{7F}", "\u{1F327}",
                     "\u{627}\u{644}\u{642}\u{627}\u{647}\u{631}\u{629}"]  // test-picker.c:1240-1245
        var rng = SeededRNG(seed: 20260713)  // test-picker.c:1246
        var started = 0
        var refused = 0
        for _ in 0 ..< 600 {  // test-picker.c:1249
            var text = ""
            for _ in 0 ..< Int.random(in: 1 ..< 7, using: &rng) {
                text += atoms[Int.random(in: 0 ..< atoms.count, using: &rng)]
            }
            fx.vm.setText("")
            fx.vm.setText(text)
            let want = Self.oracleQuery(fx.vm.text)
            let searchable = want.utf8.count >= PickerViewModel.minQueryBytes
                && WxText.isUsableName(want, maxBytes: PickerViewModel.maxQueryBytes)
            let before = fx.geocoder.count
            fx.vm.submit()
            if searchable {
                let arrived = await fx.waitRequests(before + 1, timeoutMs: 10_000)
                #expect(arrived, "typed \(Array(text.unicodeScalars))")
                guard arrived else {
                    return  // fail fast instead of waiting in every round
                }
                #expect(fx.geocoder.text(before) == want, "typed \(Array(text.unicodeScalars))")
                started += 1
            } else {
                #expect(fx.geocoder.count == before)
                refused += 1
            }
            #expect(fx.vm.statusStyle == .dim)
        }
        #expect(started > 100)  // test-picker.c:1275
        #expect(refused > 20)  // test-picker.c:1276
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == started)
    }

    // MARK: - Results

    // C: /picker/results/rows
    @Test("/picker/results/rows")
    func resultsRows() async throws {
        let fx = try await Fx.make("results-rows")
        defer { fx.finish() }
        await fx.showResults("mia", try sampleHits(), 3)
        #expect(!fx.vm.isStatusVisible)
        #expect(fx.vm.statusText == "")  // test-picker.c:1295
        #expect(fx.labels == ["Miami, Florida, United States",  // test-picker.c:1298
                              "Miami, Oklahoma, United States",  // test-picker.c:1299
                              "Miami Beach, Florida, United States"])  // test-picker.c:1300
        for row in fx.vm.rows {
            #expect(row.tooltip == row.label)
            #expect(!row.isAdded)
        }
        #expect(PickerViewModel.addedText == "Added")  // test-picker.c:1309
        await fx.showResults("spring", try samplePlaces(2), 2)
        #expect(fx.labels == ["Springfield 0, Illinois, United States", "Springfield 1, Illinois, United States"])
    }

    // C: /picker/results/cap
    @Test("/picker/results/cap")
    func resultCap() async throws {
        let fx = try await Fx.make("results-cap")
        defer { fx.finish() }
        let hits = try samplePlaces(30)
        let i = await fx.searchFor("spring")
        fx.geocoder.complete(i, hits)
        #expect(await waitFor { fx.vm.results.count == 20 })  // test-picker.c:1330
        #expect(fx.vm.results == Array(hits.prefix(20)))
        #expect(!fx.labels.contains("Springfield 20, Illinois, United States"))  // test-picker.c:1333
        #expect(fx.labels.contains("Springfield 19, Illinois, United States"))  // test-picker.c:1334
        #expect(!fx.vm.isStatusVisible)
    }

    // C: /picker/results/none
    @Test("/picker/results/none")
    func noResults() async throws {
        let fx = try await Fx.make("results-none")
        defer { fx.finish() }
        let i = await fx.searchFor("zzzz")
        #expect(fx.vm.results.count == 5)  // the previous list stays while the search runs
        fx.geocoder.complete(i, [])
        #expect(await waitFor { fx.vm.statusText == "No results" })  // test-picker.c:1374
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusStyle == .dim)
        #expect(fx.vm.results.isEmpty)
    }

    // MARK: - Errors

    // C: /picker/errors/every-code
    @Test("/picker/errors/every-code")
    func errorCodes() async throws {
        let fx = try await Fx.make("every-code")
        defer { fx.finish() }
        for code in WxError.Code.allCases {  // test-picker.c:1389-1392
            await fx.showResults("mia", try sampleHits(), 3)
            #expect(fx.vm.statusStyle == .dim)
            let msg = "failure number \(code.rawValue)"  // test-picker.c:1401
            let i = await fx.searchFor("miami")
            fx.geocoder.fail(i, WxError(code, msg))
            #expect(await waitFor { fx.vm.statusStyle == .error })
            #expect(fx.vm.statusText == "Search failed: " + msg)  // test-picker.c:1404-1406
            #expect(fx.vm.isStatusVisible)
            #expect(fx.vm.results.isEmpty)
        }
    }

    // C: /picker/errors/foreign-and-missing
    @Test("/picker/errors/foreign-and-missing")
    func errorForeignAndMissing() async throws {
        let fx = try await Fx.make("foreign")
        defer { fx.finish() }
        let i = await fx.searchFor("mia")
        fx.geocoder.fail(i, ForeignError(errorDescription: "no such thing"))
        #expect(await waitFor { fx.vm.statusStyle == .error })
        #expect(fx.vm.statusText == "Search failed: no such thing")  // test-picker.c:1425
        // (the NULL answer of test-picker.c:1427-1431 cannot be expressed: see the debrief)
        fx.registry.geocoder = nil
        fx.vm.setText("miami")
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await waitFor { fx.vm.statusText == "Search failed: no geocoder is registered" })  // test-picker.c:1436
        #expect(fx.vm.statusStyle == .error)
        #expect(fx.geocoder.count == 1)
        fx.registry.geocoder = fx.geocoder
        let j = await fx.searchFor("miami!")
        fx.geocoder.complete(j, try sampleHits())
        #expect(await waitFor { !fx.vm.isStatusVisible })
        #expect(fx.vm.statusStyle == .dim)
    }

    // C: /picker/errors/cancelled-is-silent
    @Test("/picker/errors/cancelled-is-silent")
    func errorCancelledIsSilent() async throws {
        let fx = try await Fx.make("cancelled-silent")
        defer { fx.finish() }
        let hits = try sampleHits()
        await fx.showResults("mia", hits, 3)
        let i = await fx.searchFor("miam")
        #expect(fx.vm.isStatusVisible)
        fx.geocoder.failCancelled(i)
        #expect(await waitFor { !fx.vm.isStatusVisible })
        #expect(fx.vm.statusStyle == .dim)
        #expect(fx.vm.statusText == "")  // test-picker.c:1465
        #expect(fx.vm.results == hits)
    }

    // C: /picker/errors/sanitised
    @Test("/picker/errors/sanitised")
    func errorTextSanitised() async throws {
        let fx = try await Fx.make("sanitised")
        defer { fx.finish() }
        var i = await fx.searchFor("one")
        fx.geocoder.fail(i, WxError(.network, "boom\u{01}\n\t\u{202E}<b>x</b>\u{2029} & \u{2066}done\u{7F}"))  // test-picker.c:1481-1482
        #expect(await waitFor { fx.vm.statusStyle == .error })
        #expect(fx.vm.statusText == "Search failed: boom<b>x</b> & done")  // test-picker.c:1484
        i = await fx.searchFor("two")
        fx.geocoder.fail(i, WxError(.http, "\u{01}\u{02}\u{202E}"))
        #expect(await waitFor { fx.vm.statusText == "Search failed: " })  // test-picker.c:1489
        #expect(fx.vm.statusStyle == .error)
        i = await fx.searchFor("three")
        fx.geocoder.fail(i, WxError(.http, String(repeating: "x", count: 10 * 1024)))
        #expect(await waitFor { fx.vm.statusText.utf8.count > 20 })
        #expect(fx.vm.statusText.utf8.count == "Search failed: ".utf8.count + 200)  // test-picker.c:1497-1498
        i = await fx.searchFor("five")
        fx.geocoder.fail(i, WxError(.parse, String(repeating: "\u{20AC}", count: 500)))
        #expect(await waitFor { fx.vm.statusText.contains("\u{20AC}") })
        #expect(fx.vm.statusText.utf8.count == "Search failed: ".utf8.count + 66 * 3)  // test-picker.c:1516
        i = await fx.searchFor("six")
        fx.geocoder.fail(i, WxError(.parse, "%s%n%d %%"))
        #expect(await waitFor { fx.vm.statusText.contains("%s%n%d %%") })
        #expect(fx.vm.statusText == "Search failed: %s%n%d %%")  // test-picker.c:1522
    }

    // C: /picker/errors/hostile-places (only the valid place can exist as a WxPlace)
    @Test("/picker/errors/hostile-places")
    func hostilePlacesDropped() async throws {
        let fx = try await Fx.make("hostile")
        defer { fx.finish() }
        // The hostile records of test-picker.c:1527-1553 are refused by WxPlace's validating
        // initialiser, so no geocoder can hand them over.
        #expect(throws: WxError.self) { try WxPlace(name: "Ev\u{01}il\n", lat: 999.0, lon: 0) }
        #expect(throws: WxError.self) { try WxPlace(name: "Bidi \u{202E}name", lat: 0, lon: 0) }
        #expect(throws: WxError.self) { try WxPlace(name: "Nowhere", lat: .nan, lon: 1.0, timezone: "../../etc") }
        let good = try mkPlace("Good Place", "Region", "Country", 10.0, 10.0)  // test-picker.c:1544
        await fx.showResults("evil", [good], 1)
        #expect(fx.vm.results == [good])
        #expect(!fx.vm.isStatusVisible)
        let i = await fx.searchFor("evil2")
        fx.geocoder.complete(i, [])
        #expect(await waitFor { fx.vm.statusText == "No results" })  // test-picker.c:1574
        #expect(fx.vm.results.isEmpty)
    }

    // MARK: - Stale completions

    private func runStale(honoursCancel: Bool, staleFirst: Bool, staleFails: Bool) async throws {
        let fx = try await Fx.make("stale")
        defer { fx.finish() }
        fx.geocoder.ignoreCancel = !honoursCancel
        let a = await fx.searchFor("old")
        fx.vm.setText("new")
        #expect(fx.geocoder.isCancelled(a))
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await fx.waitRequests(2))
        #expect(!fx.geocoder.isCancelled(1))
        #expect(fx.geocoder.text(1) == "new")  // test-picker.c:1606
        let newer = [try mkPlace("Newer", "Region", "Country", 11.0, 11.0)]
        func completeStale() throws {
            if staleFails {
                fx.geocoder.fail(a, WxError(.network, "stale boom"))
            } else {
                fx.geocoder.complete(a, try sampleHits())
            }
        }
        if staleFirst {
            try completeStale()
            try await Task.sleep(for: .milliseconds(50))
            #expect(fx.vm.statusText == searching)  // test-picker.c:1615
            #expect(fx.vm.statusStyle == .dim)
            #expect(fx.vm.results.count == 5)
            fx.geocoder.complete(1, newer)
            #expect(await waitFor { fx.vm.results == newer })
        } else {
            fx.geocoder.complete(1, newer)
            #expect(await waitFor { fx.vm.results == newer })
            try completeStale()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!fx.vm.isStatusVisible)
        #expect(fx.vm.statusStyle == .dim)
        #expect(!fx.vm.statusText.contains("boom"))
        #expect(fx.vm.results == newer)
    }

    // C: /picker/stale/combinations
    @Test("/picker/stale/combinations")
    func staleResults() async throws {
        for honours in [false, true] {
            for first in [false, true] {
                for fails in [false, true] {
                    try await runStale(honoursCancel: honours, staleFirst: first, staleFails: fails)
                }
            }
        }
    }

    // C: /picker/stale/after-enter
    @Test("/picker/stale/after-enter")
    func staleAfterEnter() async throws {
        let fx = try await Fx.make("stale-enter")
        defer { fx.finish() }
        fx.geocoder.ignoreCancel = true
        let a = await fx.searchFor("mia")
        fx.vm.setText("mia ")
        fx.vm.submit()
        #expect(await fx.waitRequests(2))
        fx.geocoder.failCancelled(a)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fx.vm.statusText == searching)  // test-picker.c:1656
        fx.geocoder.complete(1, try sampleHits())
        #expect(await waitFor { fx.vm.results.count == 3 })
    }

    // MARK: - Adding

    // C: /picker/add/activate
    @Test("/picker/add/activate")
    func addByActivate() async throws {
        let fx = try await Fx.make("add-activate")
        defer { fx.finish() }
        var openAtSignal = false
        var closesBeforeSignal = -1
        fx.vm.onPlaceAdded = { [unowned fx] key in
            fx.addedKeys.append(key)
            openAtSignal = !fx.vm.isInvalidated
            closesBeforeSignal = fx.closeRequests
        }
        fx.vm.activateRow(at: 1)  // Orlando
        #expect(fx.model.places.count == 1)
        let saved = fx.model.places.first?.place
        #expect(saved?.name == "Orlando")  // test-picker.c:1677
        #expect(saved?.admin1 == "Florida")  // test-picker.c:1678
        #expect(saved?.timezone == "America/New_York")  // test-picker.c:1679
        #expect(fx.addedKeys == ["28.5383,-81.3792"])  // test-picker.c:1684
        #expect(openAtSignal)
        #expect(closesBeforeSignal == 0)
        #expect(fx.closeRequests == 1)
        #expect(fx.vm.isInvalidated)
        fx.vm.activateRow(at: 2)  // a gone picker adds nothing
        #expect(fx.addedKeys.count == 1)
        #expect(fx.closeRequests == 1)
        #expect(fx.model.places.count == 1)
    }

    // C: /picker/add/from-results
    @Test("/picker/add/from-results")
    func addFromResults() async throws {
        let fx = try await Fx.make("add-results")
        defer { fx.finish() }
        await fx.showResults("mia", try sampleHits(), 3)
        fx.vm.activateRow(at: 2)  // Miami Beach
        #expect(fx.model.places.count == 1)
        #expect(fx.model.places.first?.place.name == "Miami Beach")  // test-picker.c:1703
        #expect(fx.addedKeys == ["25.7907,-80.1300"])  // test-picker.c:1705
        #expect(fx.closeRequests == 1)
    }

    // C: /picker/add/action (the list's activation of a position) and
    // C: /picker/keyboard/arrows-and-activate (Return / Space on the focused row)
    @Test("/picker/add/action and /picker/keyboard/arrows-and-activate")
    func addByActionAndKeys() async throws {
        let fx = try await Fx.make("add-action")
        defer { fx.finish() }
        fx.destroyOnClose = false
        #expect(!fx.vm.handleRowKey(.other, at: 4))
        #expect(!fx.vm.handleRowKey(.enter, modifiers: [.control], at: 4))
        #expect(fx.model.places.isEmpty)
        #expect(fx.vm.handleRowKey(.enter, at: 4))
        #expect(fx.model.places.first?.place.name == "Key West")  // test-picker.c:1721
        #expect(fx.addedKeys.count == 1)
        #expect(fx.vm.handleRowKey(.space, at: 1))
        #expect(fx.model.places.map(\.place.name) == ["Key West", "Orlando"])
        #expect(fx.addedKeys.count == 2)
    }

    // C: /picker/add/out-of-range
    @Test("/picker/add/out-of-range")
    func addOutOfRange() async throws {
        let fx = try await Fx.make("add-range")
        defer { fx.finish() }
        fx.vm.activateRow(at: 99)  // test-picker.c:1732
        fx.vm.activateRow(at: -1)
        #expect(fx.model.places.isEmpty)
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
    }

    // C: /picker/add/refused-duplicate
    @Test("/picker/add/refused-duplicate")
    func addRefusedDuplicate() async throws {
        let fx = try await Fx.make("dup")
        defer { fx.finish() }
        let sug = PickerViewModel.suggestedPlaces()
        #expect(fx.model.add(sug[0]) == .added)
        fx.vm.activateRow(at: 0)
        #expect(fx.model.places.count == 1)
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusText == "Already in your places")  // test-picker.c:1752
        #expect(fx.vm.statusStyle == .error)
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
        #expect(!fx.vm.isInvalidated)
        fx.vm.activateRow(at: 1)
        #expect(fx.model.places.count == 2)
        #expect(fx.addedKeys.count == 1)
    }

    // C: /picker/add/refused-near-duplicate
    @Test("/picker/add/refused-near-duplicate")
    func addRefusedNearDuplicate() async throws {
        let fx = try await Fx.make("near-dup")
        defer { fx.finish() }
        let orlando = PickerViewModel.suggestedPlaces()[1]
        let near = try mkPlace("Orlando Downtown", "Florida", "United States", orlando.lat + 0.02, orlando.lon)  // test-picker.c:1775-1776
        let far = try mkPlace("Orlando Far", "Florida", "United States", orlando.lat + 0.06, orlando.lon)  // test-picker.c:1777-1778
        #expect(WxGeo.distanceKm(aLat: orlando.lat, aLon: orlando.lon, bLat: near.lat, bLon: near.lon) < WxPlaces.duplicateKm)
        #expect(WxGeo.distanceKm(aLat: orlando.lat, aLon: orlando.lon, bLat: far.lat, bLon: far.lon) > WxPlaces.duplicateKm)
        #expect(near.key != orlando.key)
        #expect(fx.model.add(near) == .added)
        fx.vm.activateRow(at: 1)
        #expect(fx.model.places.count == 1)
        #expect(fx.vm.statusText == "Already in your places")  // test-picker.c:1792
        #expect(fx.vm.statusStyle == .error)
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
        #expect(fx.model.remove(key: near.key))
        #expect(fx.model.add(far) == .added)
        fx.vm.activateRow(at: 1)
        #expect(fx.model.places.count == 2)
        #expect(fx.addedKeys == [orlando.key])
    }

    // C: /picker/add/refused-full
    @Test("/picker/add/refused-full")
    func addRefusedFull() async throws {
        let fx = try await Fx.make("full")
        defer { fx.finish() }
        let sug = PickerViewModel.suggestedPlaces()
        for p in try samplePlaces(50) {
            #expect(fx.model.add(p) == .added)
        }
        #expect(fx.model.places.count == 50)  // test-picker.c:1833 (WX_PLACE_MAX)
        fx.vm.activateRow(at: 2)
        #expect(fx.model.places.count == 50)
        #expect(fx.vm.isStatusVisible)
        #expect(fx.vm.statusText == "You can save up to 50 places")  // test-picker.c:1829
        #expect(fx.vm.statusStyle == .error)
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
        // full is checked first: even a saved place is reported as the limit
        #expect(fx.model.remove(key: "40.0000,-100.0000"))  // test-picker.c:1836
        #expect(fx.model.add(sug[0]) == .added)
        #expect(fx.model.places.count == 50)
        fx.vm.setText("m")
        #expect(fx.vm.statusText == "Type at least 2 letters")  // test-picker.c:1840
        fx.vm.setText("")
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:1842
        fx.vm.activateRow(at: 0)
        #expect(fx.vm.statusText == "You can save up to 50 places")  // test-picker.c:1844
        #expect(fx.model.remove(key: "40.0000,-98.0000"))  // test-picker.c:1847
        fx.vm.activateRow(at: 2)
        #expect(fx.model.places.count == 50)
        #expect(fx.addedKeys.count == 1)
    }

    // C: /picker/add/refusal-replaced
    @Test("/picker/add/refusal-replaced")
    func refusalReplacedByNextStatus() async throws {
        let fx = try await Fx.make("refusal-replaced")
        defer { fx.finish() }
        #expect(fx.model.add(PickerViewModel.suggestedPlaces()[0]) == .added)
        fx.vm.activateRow(at: 0)
        #expect(fx.vm.statusStyle == .error)
        let i = await fx.searchFor("mia")
        #expect(fx.vm.statusText == searching)  // test-picker.c:1867
        #expect(fx.vm.statusStyle == .dim)
        fx.geocoder.complete(i, try sampleHits())
        #expect(await waitFor { !fx.vm.isStatusVisible })
        #expect(fx.vm.statusStyle == .dim)
    }

    // C: /picker/add/refused-in-results
    @Test("/picker/add/refused-in-results")
    func addRefusedInResults() async throws {
        let fx = try await Fx.make("refused-results")
        defer { fx.finish() }
        let hits = try sampleHits()
        #expect(fx.model.add(hits[0]) == .added)
        await fx.showResults("mia", hits, 3)
        fx.vm.activateRow(at: 0)
        #expect(fx.vm.statusText == "Already in your places")  // test-picker.c:1885
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.vm.results.count == 3)
    }

    // C: /picker/add/signal-only-for-own-adds
    @Test("/picker/add/signal-only-for-own-adds")
    func placeAddedOnlyForOwnAdds() async throws {
        let fx = try await Fx.make("own-adds")
        defer { fx.finish() }
        let sug = PickerViewModel.suggestedPlaces()
        #expect(fx.model.add(sug[0]) == .added)
        #expect(fx.model.add(sug[2]) == .added)
        #expect(fx.model.remove(key: "25.7743,-80.1937"))  // test-picker.c:1900
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
        #expect(!fx.vm.isInvalidated)
    }

    // C: /picker/destroy/in-place-added (a "place-added" handler that destroys the picker)
    @Test("/picker/destroy/in-place-added")
    func destroyInPlaceAdded() async throws {
        let fx = try await Fx.make("destroy-added")
        defer { fx.finish() }
        fx.vm.onPlaceAdded = { [unowned fx] key in
            fx.addedKeys.append(key)
            fx.vm.invalidate()
        }
        fx.vm.activateRow(at: 0)
        #expect(fx.model.places.count == 1)  // the add stands
        #expect(fx.addedKeys == ["25.7743,-80.1937"])
        #expect(fx.closeRequests == 0)  // a destroyed picker is not closed again
    }

    // MARK: - "Added" marker and accessibility

    // C: /picker/added-marker/follows-places
    @Test("/picker/added-marker/follows-places")
    func addedMarkerFollowsPlaces() async throws {
        let fx = try await Fx.make("marker-follows")
        defer { fx.finish() }
        let sug = PickerViewModel.suggestedPlaces()
        #expect(fx.model.add(sug[0]) == .added)
        func row(_ label: String) -> PickerViewModel.Row? { fx.vm.rows.first { $0.label == label } }
        let miami = "Miami, Florida, United States"  // test-picker.c:1921
        let tampa = "Tampa, Florida, United States"  // test-picker.c:1922
        #expect(row(miami)?.isAdded == true)
        #expect(row(miami)?.accessibilityDescription == "Added")  // test-picker.c:1928
        #expect(row(tampa)?.isAdded == false)
        #expect(fx.model.add(sug[2]) == .added)
        #expect(row(tampa)?.isAdded == true)
        #expect(row(tampa)?.accessibilityDescription == "Added")  // test-picker.c:1933
        #expect(fx.model.remove(key: "25.7743,-80.1937"))  // test-picker.c:1934
        #expect(row(miami)?.isAdded == false)
        #expect(row(miami)?.accessibilityDescription == "")  // test-picker.c:1936
        #expect(row(tampa)?.isAdded == true)
        #expect(fx.model.add(sug[0]) == .added)
        #expect(fx.model.move(from: 0, to: 1))
        #expect(row(miami)?.isAdded == true)
        #expect(row(tampa)?.isAdded == true)
        #expect(fx.addedKeys.isEmpty)
    }

    // The marks are observable: a change of the places list made elsewhere notifies a view
    // that read `rows` (on_places_changed).
    // C: /picker/added-marker/follows-places
    @Test("/picker/added-marker/follows-places (observation)")
    func addedMarkerIsObserved() async throws {
        let fx = try await Fx.make("marker-observed")
        defer { fx.finish() }
        let changed = Flag()
        withObservationTracking {
            _ = fx.vm.rows
        } onChange: {
            changed.set()
        }
        #expect(fx.model.add(PickerViewModel.suggestedPlaces()[2]) == .added)
        #expect(changed.value)
    }

    // C: /picker/added-marker/in-results
    @Test("/picker/added-marker/in-results")
    func addedMarkerInResults() async throws {
        let fx = try await Fx.make("marker-results")
        defer { fx.finish() }
        let hits = try sampleHits()
        await fx.showResults("mia", hits, 3)
        let beach = "Miami Beach, Florida, United States"  // test-picker.c:1956
        #expect(fx.vm.rows.first { $0.label == beach }?.isAdded == false)
        #expect(fx.model.add(hits[2]) == .added)
        #expect(fx.vm.rows.first { $0.label == beach }?.isAdded == true)
        await fx.showResults("miami", Array(hits.dropFirst()), 2)
        #expect(fx.vm.rows.first { $0.label == "Miami, Oklahoma, United States" }?.isAdded == false)  // test-picker.c:1965
        #expect(fx.vm.rows.first { $0.label == beach }?.isAdded == true)
    }

    // C: /picker/added-marker/places-outlive
    @Test("/picker/added-marker/places-outlive")
    func placesOutlivePicker() async throws {
        let fx = try await Fx.make("outlive")
        defer { fx.finish() }
        fx.vm.invalidate()
        let sug = PickerViewModel.suggestedPlaces()
        #expect(fx.model.add(sug[0]) == .added)
        #expect(fx.model.remove(key: "25.7743,-80.1937"))  // test-picker.c:1983
        #expect(fx.addedKeys.isEmpty)
        #expect(fx.closeRequests == 0)
    }

    // C: /picker/accessible/labels
    @Test("/picker/accessible/labels")
    func accessibleLabels() async throws {
        let fx = try await Fx.make("a11y")
        defer { fx.finish() }
        #expect(PickerViewModel.searchAccessibilityLabel == "Search for a city")  // test-picker.c:1998
        #expect(fx.vm.rows.count == 5)
        for row in fx.vm.rows {
            #expect(row.accessibilityLabel == row.label)
            #expect(row.accessibilityDescription == "")
        }
        await fx.showResults("mia", try sampleHits(), 3)
        #expect(fx.vm.rows.map(\.accessibilityLabel) == fx.labels)
    }

    // MARK: - Entry limits

    // C: /picker/entry/max-length
    @Test("/picker/entry/max-length")
    func entryMaxLength() async throws {
        let fx = try await Fx.make("max-length")
        defer { fx.finish() }
        fx.vm.setText(String(repeating: "q", count: 100_000))  // test-picker.c:2041
        #expect(fx.vm.text.unicodeScalars.count == 64)  // test-picker.c:2044
        #expect(fx.vm.text.utf8.count == 64)  // test-picker.c:2045
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await fx.waitRequests(1))
        #expect(fx.geocoder.text(0)?.utf8.count == 64)  // test-picker.c:2047
        #expect(WxText.isUsableName(fx.geocoder.text(0), maxBytes: 64))
    }

    // C: /picker/entry/byte-limit
    @Test("/picker/entry/byte-limit")
    func entryByteLimit() async throws {
        let cases: [(String, Int)] = [("q", 64), ("\u{E9}", 32), ("\u{20AC}", 21), ("\u{1F600}", 16)]  // test-picker.c:2068-2071
        for (unit, kept) in cases {
            let fx = try await Fx.make("byte-limit")
            fx.vm.setText(String(repeating: unit, count: 100))  // test-picker.c:2080
            let text = fx.vm.text
            #expect(text.unicodeScalars.count == kept)
            #expect(text.utf8.count == kept * unit.utf8.count)
            #expect(text.utf8.count <= PickerViewModel.maxQueryBytes)
            #expect(WxText.isUsableName(text, maxBytes: 64))
            await fx.waitTimer()
            await fx.clock.advance(by: delayUs)
            #expect(await fx.waitRequests(1))
            #expect(fx.geocoder.text(0) == text)
            fx.finish()
        }
    }

    // C: /picker/entry/byte-limit-edits
    @Test("/picker/entry/byte-limit-edits")
    func entryByteLimitEdits() async throws {
        let fx = try await Fx.make("byte-edits")
        defer { fx.finish() }
        fx.vm.setText("a" + String(repeating: "\u{E9}", count: 31))  // test-picker.c:2105-2106
        #expect(fx.vm.text.utf8.count == 63)
        var pos = fx.vm.insertText("\u{E9}", at: 5)  // test-picker.c:2111: refused whole
        #expect(fx.vm.text.utf8.count == 63)
        pos = fx.vm.insertText("z", at: pos)  // fits, in the middle
        #expect(fx.vm.text.utf8.count == 64)
        #expect(pos == 6)  // test-picker.c:2115
        #expect(fx.vm.text.hasPrefix("a\u{E9}\u{E9}\u{E9}\u{E9}z"))  // test-picker.c:2116
        pos = fx.vm.insertText("x", at: 0)  // full: nothing
        #expect(fx.vm.text.utf8.count == 64)
        _ = fx.vm.insertText("", at: pos)
        #expect(fx.vm.text.utf8.count == 64)
        fx.vm.deleteText(from: 0, to: -1)
        #expect(fx.vm.text == "")  // test-picker.c:2128
        pos = fx.vm.insertText(String(repeating: "p", count: 200), at: 0)
        #expect(fx.vm.text.utf8.count == PickerViewModel.maxQueryBytes)
        #expect(pos == 64)  // test-picker.c:2132
        // The SwiftUI binding path: a whole new text is one replacement cut like an insertion.
        fx.vm.setText("")
        fx.vm.textChanged(to: "a" + String(repeating: "\u{E9}", count: 31))
        fx.vm.textChanged(to: "a\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}" + String(repeating: "\u{E9}", count: 27))
        #expect(fx.vm.text.utf8.count == 63)
        fx.vm.textChanged(to: "a\u{E9}\u{E9}\u{E9}\u{E9}z" + String(repeating: "\u{E9}", count: 27))
        #expect(fx.vm.text.utf8.count == 64)
        #expect(fx.vm.text.hasPrefix("a\u{E9}\u{E9}\u{E9}\u{E9}z"))
        fx.vm.textChanged(to: String(repeating: "p", count: 200))  // a paste over everything
        #expect(fx.vm.text == String(repeating: "p", count: 64))
    }

    // MARK: - Escape and closing

    // C: /picker/close/escape
    @Test("/picker/close/escape")
    func escapeCloses() async throws {
        var fx = try await Fx.make("escape")
        #expect(!fx.vm.handleKey(.other))  // test-picker.c:2248
        #expect(!fx.vm.handleKey(.escape, modifiers: [.control]))  // test-picker.c:2249
        #expect(fx.closeRequests == 0)
        let a = await fx.searchFor("abc")
        fx.vm.setText("abcd")  // cancels #0, arms the timer again
        #expect(fx.vm.handleKey(.escape))
        #expect(fx.closeRequests == 1)  // test-picker.c:2260
        await fx.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx.geocoder.count == 1)
        #expect(fx.geocoder.isCancelled(a))
        #expect(fx.addedKeys.isEmpty)
        fx.finish()
        fx = try await Fx.make("escape-list")
        #expect(fx.vm.handleKey(.escape))
        #expect(fx.closeRequests == 1)
        #expect(fx.model.places.isEmpty)
        fx.finish()
        fx = try await Fx.make("escape-flight")
        let b = await fx.searchFor("abc")
        #expect(!fx.geocoder.isCancelled(b))
        #expect(fx.vm.handleKey(.escape))
        #expect(fx.geocoder.isCancelled(b))
        fx.finish()
    }

    // C: /picker/close/veto, /picker/close/hide-on-close (closing as such cancels nothing,
    // wx-picker.h:96-101)
    @Test("/picker/close/veto and /picker/close/hide-on-close")
    func closeRequestKeepsSearch() async throws {
        let fx = try await Fx.make("veto")
        defer { fx.finish() }
        fx.destroyOnClose = false  // the owner vetoes or only hides
        let a = await fx.searchFor("abc")
        #expect(fx.vm.handleKey(.escape))
        #expect(fx.closeRequests == 1)
        #expect(!fx.geocoder.isCancelled(a))
        #expect(fx.vm.statusText == searching)
        fx.geocoder.complete(a, try sampleHits())
        #expect(await waitFor { fx.vm.results.count == 3 })
    }

    // C: /picker/destroy/cancels-search, /picker/destroy/in-flight, /picker/destroy/pending-timer
    @Test("/picker/destroy/cancels-search, in-flight, pending-timer")
    func destroyCancelsSearch() async throws {
        let fx = try await Fx.make("destroy")
        defer { fx.finish() }
        let a = await fx.searchFor("abc")
        fx.vm.invalidate()
        #expect(fx.geocoder.isCancelled(a))
        #expect(!fx.vm.isStatusVisible)  // no "Searching…" without a request
        let fx2 = try await Fx.make("destroy-timer")
        defer { fx2.finish() }
        fx2.vm.setText("abc")
        await fx2.waitTimer()
        fx2.vm.invalidate()
        await fx2.clock.advance(by: delayUs + 250_000)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx2.geocoder.count == 0)
        fx2.vm.setText("abcd")
        fx2.vm.submit()
        fx2.vm.activateRow(at: 0)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fx2.geocoder.count == 0)
        #expect(fx2.model.places.isEmpty)
    }

    // MARK: - End to end (the TestSupport FakeGeocoder through the real service)

    // C: /picker/e2e/search-and-add
    @Test("/picker/e2e/search-and-add")
    func e2eSearchAndAdd() async throws {
        let geocoder = FakeGeocoder()
        let fx = try await Fx.make("e2e-add", geocoder: geocoder)
        defer { fx.finish() }
        let hits = try sampleHits()
        for h in hits { geocoder.addHit(h) }
        fx.vm.setText("mia")
        await fx.waitTimer()
        await fx.clock.advance(by: delayUs)
        #expect(await waitFor { geocoder.searchCount == 1 })
        #expect(await waitFor { fx.vm.results == hits })
        #expect(!fx.vm.isStatusVisible)
        fx.vm.activateRow(at: 0)
        #expect(fx.model.places.count == 1)
        #expect(fx.model.places.first?.place.name == "Miami")  // test-picker.c:2688
        #expect(fx.closeRequests == 1)
    }

    // C: /picker/e2e/failure-and-cancel
    @Test("/picker/e2e/failure-and-cancel")
    func e2eFailureAndCancel() async throws {
        let geocoder = FakeGeocoder()
        let fx = try await Fx.make("e2e-fail", geocoder: geocoder)
        defer { fx.finish() }
        geocoder.failWith(.rateLimited)  // test-picker.c:2698
        geocoder.setDelayMs(20)
        fx.vm.setText("mia")
        fx.vm.submit()
        #expect(fx.vm.statusText == searching)  // test-picker.c:2702
        #expect(await waitFor { fx.vm.statusStyle == .error })
        #expect(fx.vm.statusText.hasPrefix("Search failed: "))  // test-picker.c:2704
        #expect(fx.vm.results.isEmpty)
        #expect(geocoder.searchCount == 1)
        geocoder.failWith(nil)
        geocoder.setDelayMs(400)
        await fx.clock.advance(by: delayUs + 50_000)
        fx.vm.submit()
        #expect(await waitFor { geocoder.searchCount == 2 })
        fx.vm.setText("")
        try await Task.sleep(for: .milliseconds(600))
        #expect(fx.vm.statusStyle == .dim)
        #expect(fx.vm.statusText == "Suggestions")  // test-picker.c:2718
        #expect(fx.vm.results.count == 5)
    }

    // MARK: - First run (ui-widgets.md:98-114)

    @Test("first run: the 'No places yet' page and its five chips")
    func firstRunPage() async throws {
        let fx = try await Fx.make("first-run")
        defer { fx.finish() }
        let page = FirstRunViewModel(model: fx.model)
        #expect(FirstRunViewModel.title == "No places yet")  // ui-widgets.md:102
        #expect(FirstRunViewModel.hint == "Pick a city to see its weather and when it will rain.")  // ui-widgets.md:103
        #expect(FirstRunViewModel.addCityTitle == "Add a city")  // ui-widgets.md:110
        #expect(page.chips.map(\.title) == ["Miami", "Orlando", "Tampa", "Jacksonville", "Key West"])  // ui-widgets.md:104-105
        #expect(page.chips.first?.tooltip == "Add Miami, Florida, United States")  // ui-widgets.md:105-106
        #expect(page.chips.map(\.tooltip) == ["Add Miami, Florida, United States",
                                              "Add Orlando, Florida, United States",
                                              "Add Tampa, Florida, United States",
                                              "Add Jacksonville, Florida, United States",
                                              "Add Key West, Florida, United States"])
        for chip in page.chips {
            #expect(chip.place.admin1 == "Florida" && chip.place.country == "United States")  // ui-widgets.md:108-109
            #expect(chip.place.countryCode == "US" && chip.place.timezone == "America/New_York")
        }
        #expect(page.isShown)
    }

    @Test("first run: a chip adds and selects its place; a refused add does nothing")
    func firstRunChipAdds() async throws {
        let fx = try await Fx.make("first-run-add")
        defer { fx.finish() }
        let page = FirstRunViewModel(model: fx.model)
        #expect(page.addSuggestion(at: 2) == .added)  // Tampa
        #expect(fx.model.places.map(\.place.name) == ["Tampa"])
        #expect(fx.model.selectedKey == page.chips[2].place.key)
        #expect(!page.isShown)
        #expect(page.addSuggestion(at: 2) == .duplicate)  // refused: no change
        #expect(fx.model.places.count == 1)
        #expect(page.addSuggestion(at: 5) == nil)
        #expect(page.addSuggestion(at: -1) == nil)
        #expect(fx.model.places.count == 1)
    }

    @Test("utf8 byte equality: replacing NFC with NFD updates bytes and triggers a fresh search")
    func utf8ByteEqualityNfcAndNfd() async throws {
        let fx = try await Fx.make("utf8-nfc-nfd")
        defer { fx.finish() }
        let nfc = "\u{00E9}"          // [0xC3, 0xA9] (2 UTF-8 bytes, 1 letter -> searchable)
        let nfd = "e\u{0301}"         // [0x65, 0xCC, 0x81] (3 UTF-8 bytes)
        #expect(nfc == nfd)
        #expect(!nfc.utf8.elementsEqual(nfd.utf8))

        fx.vm.setText(nfc)
        #expect(Array(fx.vm.text.utf8) == [0xC3, 0xA9])
        fx.vm.submit()
        #expect(await fx.waitRequests(1))
        #expect(fx.geocoder.text(0).map { Array($0.utf8) } == [0xC3, 0xA9])

        // Replacing NFC with NFD via textChanged updates the stored UTF-8 bytes and triggers a
        // fresh search on submit (not suppressed by repeatsLatestSearch).
        fx.vm.textChanged(to: nfd)
        #expect(Array(fx.vm.text.utf8) == [0x65, 0xCC, 0x81])
        fx.vm.submit()
        #expect(await fx.waitRequests(2))
        #expect(fx.geocoder.text(1).map { Array($0.utf8) } == [0x65, 0xCC, 0x81])

        // Replacing NFD back with NFC via setText also updates the stored UTF-8 bytes and searches
        // after the debounce timer fires.
        fx.vm.setText(nfc)
        #expect(Array(fx.vm.text.utf8) == [0xC3, 0xA9])
        await fx.clock.advance(by: delayUs)
        #expect(await fx.waitRequests(3))
        #expect(fx.geocoder.text(2).map { Array($0.utf8) } == [0xC3, 0xA9])
    }
}
