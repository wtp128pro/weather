// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoGeocoder.swift - the Open-Meteo place search (C:
// WxOpenMeteoGeocoder, src/providers/openmeteo/wx-openmeteo.c:1416-1659,
// contract src/providers/openmeteo/wx-openmeteo.h:65-124 and :225-246).
//
// Contract, as in C:
//  - The production initialiser builds its one HTTPClient from the FIXED
//    https origin OpenMeteoShared.geocodingBaseURL
//    ("https://geocoding-api.open-meteo.com") with the default timing and the
//    project User-Agent (wx_open_meteo_geocoder_new). Other origins (loopback
//    http for the tests) only through the internal test initialiser.
//  - search(textBytes:) checks the text in this order, every failure without
//    network traffic (geocoder_search_async, wx-openmeteo.c:1564-1587):
//     0. a task cancelled before the call: CancellationError;
//     1. the text (up to its first 0x00 byte) is trimmed of the bytes 0x20,
//        \t, \n, \f and \r at both ends (g_strstrip(); NOT \v);
//     2. fewer than OpenMeteoShared.searchMinBytes bytes left: an EMPTY result;
//     3. WxText.isUsableName(trimmed, maxBytes: OpenMeteoShared.searchMaxBytes)
//        must accept it, else WxError .invalidArg "unacceptable search text";
//     4. otherwise GET OpenMeteoShared.searchPath(escaping:) of the trimmed
//        text ("/v1/search?name=<escaped>&count=10&language=en&format=json"),
//        Accept "application/json"; the body goes to OpenMeteoParse.geocode.
//    The errors of the HTTPClient and of the parser are returned unchanged.
//  - Cancellation is Swift task cancellation: cancelled at any time before
//    search returns, the call throws CancellationError, also when the result
//    (hits, empty result or a WxError) was already known (GTask
//    check_cancellable, wx-provider.h:32-35).

import Foundation

/// The Open-Meteo place search (C: WxOpenMeteoGeocoder), a `WxGeocoder`.
public final class OpenMeteoGeocoder: WxGeocoder {

    /// The geocoder's one HTTP client (C: self->http). Internal for tests.
    let http: HTTPClient

    /// wx_open_meteo_geocoder_new: the production place search. Its client is
    /// built from the fixed https origin `OpenMeteoShared.geocodingBaseURL`
    /// with the default timing and the project User-Agent.
    ///
    /// - Throws: `WxError` `.invalidArg` only if the HTTP client refused the
    ///   constant origin (C: NULL; does not happen for the shipped constants).
    public convenience init() throws(WxError) {
        let http = try HTTPClient(
            baseURL: OpenMeteoShared.geocodingBaseURL, userAgent: OpenMeteoShared.userAgent,
            timeoutMs: HTTPPolicy.timeoutMs, backoffBaseMs: HTTPPolicy.backoffBaseMs, minGapMs: 0,
            clock: SystemClock())
        self.init(http: http)
    }

    /// wx_open_meteo_geocoder_new_custom - TEST HOOK, not for production code:
    /// another origin (https, or http towards a loopback host) and timing.
    ///
    /// - Throws: `WxError` `.invalidArg` "invalid timing argument" (C: a
    ///   critical and NULL) or "unacceptable base URL".
    convenience init(
        customBaseURL: String, timeoutMs: Int, backoffBaseMs: Int, clock: any WxClock = SystemClock()
    ) throws(WxError) {
        let http = try HTTPClient(
            baseURL: customBaseURL, userAgent: OpenMeteoShared.userAgent, timeoutMs: timeoutMs,
            backoffBaseMs: backoffBaseMs, minGapMs: 0, clock: clock)
        self.init(http: http)
    }

    private init(http: HTTPClient) {
        self.http = http
    }

    /// geocoder_search_async + geocoder_search_finish (see the file comment).
    ///
    /// - Returns: 0...20 places in body order; an empty array for text that is
    ///   shorter than 2 bytes after trimming.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   search returns; `WxError` `.invalidArg` "unacceptable search text";
    ///   otherwise the `WxError` of the request or of the parser.
    public func search(textBytes: [UInt8]) async throws -> [WxPlace] {
        try Task.checkCancellation()  // g_task_return_error_if_cancelled: nothing is sent
        let outcome: Result<[WxPlace], any Error>
        do {
            outcome = .success(try await searchSteps(textBytes))
        } catch {
            outcome = .failure(error)
        }
        try Task.checkCancellation()  // cancelled before finish: the cancellation wins
        return try outcome.get()
    }

    /// Steps 1-4 of the file comment.
    private func searchSteps(_ textBytes: [UInt8]) async throws -> [WxPlace] {
        let trimmed = Self.trimmed(textBytes)
        if trimmed.count < OpenMeteoShared.searchMinBytes {
            return []
        }
        guard WxText.isUsableName(bytes: trimmed, maxBytes: OpenMeteoShared.searchMaxBytes) else {
            throw WxError(.invalidArg, "unacceptable search text")
        }
        // isUsableName accepted the bytes, so they are valid UTF-8 and the String round trip is exact.
        let path = OpenMeteoShared.searchPath(escaping: String(decoding: trimmed, as: UTF8.self))
        let response = try await http.get(path, accept: OpenMeteoShared.accept)
        return try OpenMeteoParse.geocode(response.body)
    }

    /// g_strstrip() of the C string in `bytes`: the bytes before the first 0x00,
    /// without the g_ascii_isspace() bytes (0x20, 0x09, 0x0A, 0x0C, 0x0D) at
    /// either end.
    static func trimmed(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        let text = bytes.prefix { $0 != 0 }
        let isTrim = { (b: UInt8) -> Bool in b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }
        guard let first = text.firstIndex(where: { !isTrim($0) }) else {
            return text[text.endIndex...]
        }
        let last = text.lastIndex(where: { !isTrim($0) })!
        return text[first...last]
    }
}
