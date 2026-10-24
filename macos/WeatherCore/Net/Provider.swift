// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Provider.swift - WxProvider and WxGeocoder: the only network surface of the
// weather app. Port of src/net/wx-provider.{h,c}.
//
// A WxProvider turns one place into forecast members (one data source: NWS,
// Open-Meteo, MET Norway ...); a WxGeocoder turns user text into places. Every
// other module obtains weather data exclusively through these protocols, and a
// new data source is added by writing another conforming type and registering
// it with a WxRegistry (Registry.swift).
//
// Mapping of the C contract (src/net/wx-provider.h:15-43)
// ------------------------------------------------------
//  - GIO async/finish pairs become one `async throws` method. The C promise
//    "the callback is never invoked before the *_async function has returned"
//    has no counterpart: there is no callback, the caller simply awaits.
//  - GCancellable becomes Swift task cancellation. When the calling task is
//    cancelled before the method returns, the method throws
//    `CancellationError` - also when the outcome was already available
//    (C: "If the cancellable is cancelled before the *_finish function is
//    called, *_finish reports G_IO_ERROR_CANCELLED even if the operation had
//    already succeeded", wx-provider.h:32-35). Cancellation is the only
//    non-`WxError` error a conforming method may throw.
//  - Every other failure is a `WxError` (.network, .timeout, .http,
//    .rateLimited, .parse, .notFound, .invalidArg, .unsupported).
//  - A place that the provider does not cover is `.unsupported` without
//    network traffic (a provider that can only learn it from the server, e.g.
//    an HTTP 404, reports it after its request).
//  - The C "invalid place -> WX_ERROR_INVALID_ARG" path cannot occur: a
//    `WxPlace` value can only be made by its validating initialisers (the
//    wx_place_new() rules), so every place a provider receives is valid.
//  - Results are values (transfer full by construction); an implementation
//    keeps no reference to them. `self` stays alive for the whole call, so
//    dropping the last other reference while a fetch is in flight is safe
//    (C: "keeps itself alive until every operation it started has completed").
//  - The C "main thread only" rule becomes `Sendable`: the registry calls the
//    synchronous members on the main actor; `fetch` / `search` are ordinary
//    nonisolated async methods (they run on the concurrent executor unless
//    the conforming type is an actor) and may be called from any task.

/// Limits of the provider protocols.
extension WxLimits {
    /// Most places a `WxGeocoder` returns from one search
    /// (WX_GEOCODER_MAX_HITS, src/net/wx-provider.h:55).
    public static let geocoderMaxHits = 20
}

/// One weather data source (WxProviderInterface, src/net/wx-provider.h:60-88).
///
/// Every requirement is mandatory (the C dispatchers' "implementation left a
/// virtual function NULL" criticals are compile-time errors in Swift).
public protocol WxProvider: AnyObject, Sendable {
    /// Constant provider id: `WxLimits.isValidID` and without '.', i.e.
    /// `[a-z0-9][a-z0-9_-]{0,31}` (the registry refuses anything else); the
    /// same string for the whole life of the instance. The registry reads it
    /// once, at registration, and keys the provider by that copy.
    var id: String { get }

    /// Human readable source name, e.g. "National Weather Service"; constant.
    var name: String { get }

    /// Credit line, e.g. "Weather data by Open-Meteo.com"; constant.
    var attribution: String { get }

    /// https URL of the credit link; constant.
    var attributionURL: String { get }

    /// Cheap coverage test, no I/O and no suspension (wx_provider_covers).
    /// `true` is a pre-filter (the server may still say the place is not
    /// covered); `false` means `fetch` would throw `.unsupported`.
    ///
    /// The registry calls it on the main actor while it walks its list, so an
    /// implementation may call back into the registry (`MainActor
    /// .assumeIsolated`), e.g. to register another provider; see
    /// `WxRegistry.listCovering(_:)`.
    func covers(_ place: WxPlace) -> Bool

    /// Fetches the forecast members of `place` (wx_provider_fetch_async +
    /// wx_provider_fetch_finish).
    ///
    /// - Returns: the members of this provider, possibly none; the result's
    ///   `providerID` is `id`. The members follow the normalisation contract
    ///   (`WxMember.addHour` / `addQuarter` enforce it).
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   the method returns (even if the result was ready); otherwise a
    ///   `WxError`: `.unsupported` for an uncovered place (no traffic when
    ///   `covers` already says so), or the failure of the request / parse.
    func fetch(_ place: WxPlace) async throws -> WxSourceResult
}

/// Turns user text into places (WxGeocoderInterface,
/// src/net/wx-provider.h:246-323).
public protocol WxGeocoder: AnyObject, Sendable {
    /// Searches places for the text in `textBytes` (wx_geocoder_search_async +
    /// wx_geocoder_search_finish).
    ///
    /// `textBytes` is the text as the C `const char *`: it ends at the first
    /// 0x00 byte (or at the end of the array) and may be invalid UTF-8, so
    /// byte-level validation stays testable. An implementation reports text it
    /// cannot use (too short, too long, invalid UTF-8, control characters) as
    /// `WxError` `.invalidArg` - or, where it documents so, as an empty result
    /// - without network traffic.
    ///
    /// - Returns: at most `WxLimits.geocoderMaxHits` places in the geocoder's
    ///   order (possibly none).
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   the method returns (even if the result was ready); otherwise a
    ///   `WxError`.
    func search(textBytes: [UInt8]) async throws -> [WxPlace]
}

extension WxGeocoder {
    /// `search(textBytes:)` with the UTF-8 bytes of `text` (what a text field
    /// delivers).
    public func search(_ text: String) async throws -> [WxPlace] {
        try await search(textBytes: Array(text.utf8))
    }
}
