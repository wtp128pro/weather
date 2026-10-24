// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoProvider.swift - the Open-Meteo forecast provider (C: WxOpenMeteo,
// src/providers/openmeteo/wx-openmeteo.c:829-1414, contract
// src/providers/openmeteo/wx-openmeteo.h:1-176). The pure parts (model
// allow-list, request paths, parsers) are OpenMeteoShared.swift and
// OpenMeteoParse.swift; this file is the fetch operation on one HTTPClient.
//
// Contract, as in C:
//  - id "open-meteo", name "Open-Meteo", attribution "Weather data by
//    Open-Meteo.com", attribution URL "https://open-meteo.com/"; covers every
//    place whose coordinates pass WxGeo.isValid (wx-openmeteo.c:1277-1281).
//  - The production initialiser builds its one HTTPClient from the FIXED
//    https origin OpenMeteoShared.baseURL ("https://api.open-meteo.com"), with
//    the default timing and the project User-Agent (wx_open_meteo_new,
//    wx-openmeteo.c:1410-1414). Other origins (loopback http for the tests)
//    are reachable only through the internal test initialiser
//    init(customBaseURL:timeoutMs:backoffBaseMs:clock:) (wx_open_meteo_new_custom).
//  - A fetch sends request A (hourly multi-model forecast) and, for a place in
//    the CONUS branch of the model choice, concurrently request B (15-minute
//    nowcast), A first (om_fetch_async, wx-openmeteo.c:1330-1336): both are
//    admitted by the client in that order before the fetch waits, so a CONUS
//    fetch that finds exactly one free client slot sends A and does without B.
//  - A failure of A fails the fetch with A's error (the HTTPClient's WxError
//    unchanged, or the parser's) and cancels B. A success of A is returned with
//    B's member appended LAST when B succeeded; every failure of B is
//    tolerated. B's window is OpenMeteoShared.nowcastGraceMs from the START of
//    the fetch (the moment request A is sent, on the monotonic clock): when A
//    succeeds earlier and B is pending, the fetch waits for the rest of the
//    window (rounded up to whole milliseconds, as g_timeout_source_new() of
//    wx-openmeteo.c:1035-1038); when A succeeds at or after the end of the
//    window it returns at once (on_forecast_done, wx-openmeteo.c:1004-1039).
//  - fetchedS of request A's members is the wall clock (WxClock.wallSeconds)
//    when A's answer is handled (wx-openmeteo.c:1017), that of the nowcast
//    member the wall clock when B's answer is handled (:1070).
//  - Cancellation is Swift task cancellation (wx-provider.h:32-35): a task
//    cancelled before the call sends nothing; cancelled at any time before
//    fetch returns, it gets CancellationError, also when the result was ready.
//
// Documented differences from C (the debrief's L5 sweep):
//  - C's "invalid place" (WX_ERROR_INVALID_ARG without traffic) cannot occur:
//    a WxPlace is valid by construction (Provider.swift).
//  - Slot lifetime: the fetch returns only after request B's cancellation has
//    been delivered by the HTTPClient (the task group awaits its children), so
//    every slot of a fetch is free when fetch returns. C keeps A's slot while
//    its completion callback runs and B's slot for several main-loop
//    dispatches after a fetch completed by the window (wx-openmeteo.h:125-147,
//    the "15 results and 1 RATE_LIMITED" refills); here such refills give 16
//    results. The total bound max(A's completion, start + window) is kept.

import Foundation

/// The Open-Meteo forecast provider (C: WxOpenMeteo): a `WxProvider` with id
/// "open-meteo" that blends nothing itself and returns one member per model.
public final class OpenMeteoProvider: WxProvider {

    /// WX_OPEN_METEO_ID.
    public var id: String { OpenMeteoShared.providerID }
    /// OPEN_METEO_NAME.
    public var name: String { OpenMeteoShared.name }
    /// OPEN_METEO_ATTRIBUTION (the CC BY 4.0 credit line).
    public var attribution: String { OpenMeteoShared.attribution }
    /// OPEN_METEO_ATTRIBUTION_URL.
    public var attributionURL: String { OpenMeteoShared.attributionURL }

    /// The provider's one HTTP client (C: self->http). Internal so tests can
    /// read `http.outstandingCount` and `http.policy`.
    let http: HTTPClient
    /// The time source of the nowcast window and of the fetch times.
    let clock: any WxClock

    /// wx_open_meteo_new: the production provider. Its client is built from the
    /// fixed https origin `OpenMeteoShared.baseURL` with the default timing
    /// (HTTPPolicy.timeoutMs, HTTPPolicy.backoffBaseMs, no pacing) and the
    /// project User-Agent; it uses the system clock.
    ///
    /// - Throws: `WxError` `.invalidArg` only if the HTTP client refused the
    ///   constant origin (C: NULL; does not happen for the shipped constants).
    public convenience init() throws(WxError) {
        let clock = SystemClock()
        let http = try HTTPClient(
            baseURL: OpenMeteoShared.baseURL, userAgent: OpenMeteoShared.userAgent,
            timeoutMs: HTTPPolicy.timeoutMs, backoffBaseMs: HTTPPolicy.backoffBaseMs, minGapMs: 0,
            clock: clock)
        self.init(http: http, clock: clock)
    }

    /// wx_open_meteo_new_custom - TEST HOOK, not for production code: like
    /// `init()` but with another origin (https, or http towards a loopback
    /// host) and timing.
    ///
    /// - Throws: `WxError` `.invalidArg`: "invalid timing argument" for a
    ///   timeout outside 1...600000 or a back-off outside 0...600000 (C: a
    ///   critical and NULL), "unacceptable base URL" for an origin the HTTP
    ///   client refuses.
    convenience init(
        customBaseURL: String, timeoutMs: Int, backoffBaseMs: Int, clock: any WxClock = SystemClock()
    ) throws(WxError) {
        let http = try HTTPClient(
            baseURL: customBaseURL, userAgent: OpenMeteoShared.userAgent, timeoutMs: timeoutMs,
            backoffBaseMs: backoffBaseMs, minGapMs: 0, clock: clock)
        self.init(http: http, clock: clock)
    }

    private init(http: HTTPClient, clock: any WxClock) {
        self.http = http
        self.clock = clock
    }

    /// om_covers: Open-Meteo answers for every valid coordinate.
    public func covers(_ place: WxPlace) -> Bool {
        WxGeo.isValid(lat: place.lat, lon: place.lon)
    }

    /// om_fetch_async + om_fetch_finish (see the file comment).
    ///
    /// - Returns: provider "open-meteo" with one member per model that has data,
    ///   in request order, plus the nowcast member "hrrr15" last when request B
    ///   succeeded in time.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   fetch returns; otherwise the `WxError` of request A (from the
    ///   HTTPClient unchanged, or from `OpenMeteoParse.forecast`).
    public func fetch(_ place: WxPlace) async throws -> WxSourceResult {
        // C: wx_place_copy() cannot fail for a WxPlace; then g_task_return_error_if_cancelled.
        try Task.checkCancellation()
        let choice = OpenMeteoShared.models(lat: place.lat, lon: place.lon)
        let pathA = OpenMeteoShared.forecastPath(lat: place.lat, lon: place.lon, models: choice.models)
        let pathB = choice.conus ? OpenMeteoShared.nowcastPath(lat: place.lat, lon: place.lon) : nil
        let outcome = await run(pathA: pathA, pathB: pathB, models: choice.models)
        // The caller's cancellation wins over every outcome (wx-provider.h:32-35).
        try Task.checkCancellation()
        return try outcome.get()
    }

    /// What a child task of one fetch reports.
    private enum Event: Sendable {
        case forecast(Result<HTTPClient.Response, any Error>)
        case nowcast(Result<HTTPClient.Response, any Error>)
        case graceElapsed
        case graceCancelled
    }

    /// One fetch operation (C: FetchOp and its callbacks, wx-openmeteo.c:833-1096).
    private func run(pathA: String, pathB: String?, models: [OpenMeteoModel]) async
        -> Result<WxSourceResult, any Error>
    {
        let http = self.http
        let clock = self.clock
        return await withTaskGroup(of: Event.self, returning: Result<WxSourceResult, any Error>.self) { group in
            // C: op->start_us = g_get_monotonic_time() right before request A is sent.
            let startUs = clock.monotonicMicroseconds
            // Immediate child tasks run synchronously up to their first suspension, so request A is
            // admitted by the client before request B is (C sends A, then B, in om_fetch_async).
            group.addImmediateTask { .forecast(await Self.request(http, pathA)) }
            if let pathB {
                group.addImmediateTask { .nowcast(await Self.request(http, pathB)) }
            }
            var aResult: WxSourceResult?
            var bMember: WxMember?
            var bDone = false
            var outcome: Result<WxSourceResult, any Error>?
            while outcome == nil, let event = await group.next() {
                switch event {
                case .forecast(.failure(let error)):
                    outcome = .failure(error)  // fetch_complete_error: A's error, B is cancelled
                case .forecast(.success(let response)):
                    let parsed: WxSourceResult
                    do {
                        parsed = try OpenMeteoParse.forecast(response.body, models: models, fetchedS: clock.wallSeconds)
                    } catch {
                        outcome = .failure(error)
                        continue
                    }
                    aResult = parsed
                    if pathB == nil || bDone {
                        outcome = .success(Self.complete(parsed, bMember))
                        continue
                    }
                    // B's window counts from the start of the fetch, not from A's completion.
                    let nowUs = clock.monotonicMicroseconds
                    let elapsedUs = nowUs - startUs
                    let windowUs = Int64(OpenMeteoShared.nowcastGraceMs) * 1000
                    if elapsedUs >= windowUs {
                        outcome = .success(Self.complete(parsed, bMember))
                        continue
                    }
                    let remainingMs = (windowUs - elapsedUs + 999) / 1000  // wx-openmeteo.c:1035
                    let deadline = nowUs + remainingMs * 1000
                    group.addTask {
                        do {
                            try await clock.sleep(until: deadline)
                            return .graceElapsed
                        } catch {
                            return .graceCancelled
                        }
                    }
                case .nowcast(let result):
                    // on_nowcast_done: every failure of B is tolerated.
                    bDone = true
                    if case .success(let response) = result {
                        bMember = try? OpenMeteoParse.nowcast(response.body, fetchedS: clock.wallSeconds)
                    }
                    if let aResult {
                        outcome = .success(Self.complete(aResult, bMember))
                    }
                case .graceElapsed:
                    // on_grace_elapsed: armed only after A succeeded.
                    if let aResult {
                        outcome = .success(Self.complete(aResult, bMember))
                    }
                case .graceCancelled:
                    break
                }
            }
            // fetch_op_stop: whatever is still running (B, the window timer) is cancelled; the group
            // awaits those children before it returns, so no slot outlives the fetch.
            group.cancelAll()
            // Request A always reports, so `outcome` is set here; the fallback is never used.
            return outcome ?? .failure(CancellationError())
        }
    }

    /// wx_http_get_async + wx_http_get_finish of one request, as a value.
    private static func request(_ http: HTTPClient, _ path: String) async -> Result<HTTPClient.Response, any Error> {
        do {
            return .success(try await http.get(path, accept: OpenMeteoShared.accept))
        } catch {
            return .failure(error)
        }
    }

    /// fetch_complete_ok: A's members, then the nowcast member when B succeeded.
    private static func complete(_ a: WxSourceResult, _ b: WxMember?) -> WxSourceResult {
        var result = a
        if let b {
            result.members.append(b)
        }
        return result
    }
}
