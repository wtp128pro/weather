// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FakeProvider.swift - TEST-ONLY scripted implementations of WxProvider and
// WxGeocoder, shared by the tests of every module that consumes the protocols
// (registry, service, app model ...). Port of src/net/wx-fake-provider.{h,c}.
// They live in the test bundle only, never touch the network, and honour the
// protocol contract of Provider.swift:
//  - the outcome (scripted failure, members / hits) is prepared when the call
//    starts (wx-fake-provider.c:446-470, 675-696) and the call is counted
//    whatever its outcome;
//  - a task that is already cancelled ends with CancellationError at once
//    (g_task_return_error_if_cancelled, wx-fake-provider.c:192);
//  - with a delay, the call sleeps on the injected WxClock until start +
//    delay; a cancellation during the wait ends it at once with
//    CancellationError (wx-fake-provider.c:198-207);
//  - a cancellation that arrives before the call returns wins over the
//    prepared outcome, success or failure (GTask propagate semantics,
//    wx-provider.h:32-35);
//  - a place the fake provider does not cover is WxError .unsupported
//    "place not covered"; a scripted failure is WxError(code,
//    "scripted failure"); unusable search text is .invalidArg "invalid search
//    text" (wx-fake-provider.c:457-462, 685-688).
// Both fakes are Sendable (state behind a Mutex), so they can be used from
// any task; tests that need determinism inject a ManualClock.

import Foundation
import Synchronization
@testable import WeatherCore

/// Scripted WxProvider (WxFakeProvider).
final class FakeProvider: WxProvider {
    private struct State {
        var coversAll = true
        var failure: WxError.Code?
        var delayMs: UInt32 = 0
        var fetchCount = 0
        var members: [WxMember] = []
    }

    /// The id given to `init`, NOT validated (the registry tests need invalid
    /// ids).
    let id: String
    /// "Fake <id>".
    let name: String
    /// "Fake data (<id>)".
    let attribution: String
    /// "https://example.invalid/".
    let attributionURL = "https://example.invalid/"

    private let clock: any WxClock
    private let state = Mutex(State())

    /// A provider covering every place, answering immediately with an empty
    /// result (wx_fake_provider_new). Delays are measured on `clock`.
    init(id: String, clock: any WxClock = .system) {
        self.id = id
        self.name = "Fake " + id
        self.attribution = "Fake data (" + id + ")"
        self.clock = clock
    }

    /// Covers every place (`true`) or none (`false`) from now on
    /// (wx_fake_provider_set_covers).
    func setCovers(_ coversAll: Bool) {
        state.withLock { $0.coversAll = coversAll }
    }

    /// Adds a member that every later successful fetch returns, after the
    /// members added earlier (wx_fake_provider_add_member).
    func addMember(_ member: WxMember) {
        state.withLock { $0.members.append(member) }
    }

    /// Later fetches of covered places fail with `code` (after the delay), or
    /// succeed again when `code` is nil (wx_fake_provider_fail_with; nil is
    /// the C -1).
    func failWith(_ code: WxError.Code?) {
        state.withLock { $0.failure = code }
    }

    /// Later fetches complete `delayMs` after they start; 0 completes at once,
    /// a very large delay "hangs" until cancelled
    /// (wx_fake_provider_set_delay_ms).
    func setDelayMs(_ delayMs: UInt32) {
        state.withLock { $0.delayMs = delayMs }
    }

    /// How many times `fetch` reached this provider, whatever the outcome
    /// (wx_fake_provider_get_fetch_count).
    var fetchCount: Int {
        state.withLock { $0.fetchCount }
    }

    func covers(_ place: WxPlace) -> Bool {
        state.withLock { $0.coversAll }
    }

    func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        let startUs = clock.monotonicMicroseconds
        let id = self.id
        let (outcome, delayMs) = state.withLock { s -> (Result<WxSourceResult, WxError>, UInt32) in
            s.fetchCount += 1
            // A WxPlace is valid by construction, so the C "invalid place"
            // branch (wx-fake-provider.c:457-458) has no counterpart.
            let outcome: Result<WxSourceResult, WxError>
            if !s.coversAll {
                outcome = .failure(WxError(.unsupported, "place not covered"))
            } else if let code = s.failure {
                outcome = .failure(WxError(code, "scripted failure"))
            } else {
                let members = s.members
                outcome = Result { () throws(WxError) -> WxSourceResult in
                    var result = try WxSourceResult(providerID: id)
                    result.members = members
                    return result
                }
            }
            return (outcome, s.delayMs)
        }
        return try await FakeCompletion.deliver(outcome, clock: clock, startUs: startUs, delayMs: delayMs)
    }
}

/// Scripted WxGeocoder (WxFakeGeocoder).
final class FakeGeocoder: WxGeocoder {
    /// Longest search text the fake accepts, bytes (FAKE_SEARCH_TEXT_MAX,
    /// wx-fake-provider.c:9).
    static let searchTextMax = 64

    private struct State {
        var hits: [WxPlace] = []
        var failure: WxError.Code?
        var delayMs: UInt32 = 0
        var searchCount = 0
    }

    private let clock: any WxClock
    private let state = Mutex(State())

    /// A geocoder answering every search immediately with the places added
    /// by `addHit` (initially none) (wx_fake_geocoder_new).
    init(clock: any WxClock = .system) {
        self.clock = clock
    }

    /// Adds `place` to every later successful search result, after the
    /// earlier hits; at most `WxLimits.geocoderMaxHits` are returned (extra
    /// hits are kept but cut from the result) (wx_fake_geocoder_add_hit).
    func addHit(_ place: WxPlace) {
        state.withLock { $0.hits.append(place) }
    }

    /// Later searches fail with `code` (after the delay), or succeed again
    /// when `code` is nil (wx_fake_geocoder_fail_with).
    func failWith(_ code: WxError.Code?) {
        state.withLock { $0.failure = code }
    }

    /// Later searches complete `delayMs` after they start
    /// (wx_fake_geocoder_set_delay_ms).
    func setDelayMs(_ delayMs: UInt32) {
        state.withLock { $0.delayMs = delayMs }
    }

    /// How many times `search` reached this geocoder
    /// (wx_fake_geocoder_get_search_count).
    var searchCount: Int {
        state.withLock { $0.searchCount }
    }

    func search(textBytes: [UInt8]) async throws -> [WxPlace] {
        let startUs = clock.monotonicMicroseconds
        let usable = WxText.isUsableName(bytes: textBytes, maxBytes: Self.searchTextMax)
        let (outcome, delayMs) = state.withLock { s -> (Result<[WxPlace], WxError>, UInt32) in
            s.searchCount += 1
            let outcome: Result<[WxPlace], WxError>
            if !usable {
                outcome = .failure(WxError(.invalidArg, "invalid search text"))
            } else if let code = s.failure {
                outcome = .failure(WxError(code, "scripted failure"))
            } else {
                outcome = .success(Array(s.hits.prefix(WxLimits.geocoderMaxHits)))
            }
            return (outcome, s.delayMs)
        }
        return try await FakeCompletion.deliver(outcome, clock: clock, startUs: startUs, delayMs: delayMs)
    }
}

/// Delayed completion shared by both fakes (fake_complete,
/// wx-fake-provider.c:183-208).
private enum FakeCompletion {
    static func deliver<T: Sendable>(
        _ outcome: Result<T, WxError>, clock: any WxClock, startUs: Int64, delayMs: UInt32
    ) async throws -> T {
        try Task.checkCancellation()
        if delayMs > 0 {
            // Throws CancellationError when the task is cancelled meanwhile.
            try await clock.sleep(until: startUs + Int64(delayMs) * 1000)
        }
        // Cancelled before the result was handed over: cancellation wins.
        try Task.checkCancellation()
        return try outcome.get()
    }
}
