// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsECCCTests.swift - the Environment Canada alerts request and parser
// against real GeoMet answers captured on 2026-10-26 (Fixtures/alerts): the
// point query at Toronto (a frost advisory, 16:15 UTC), the same query at
// Paris (none) and the first feature of the national set (an ended blizzard
// warning whose message had not expired yet, 14:30 UTC). Malformed answers
// are the recorded ones truncated or with one field broken.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct AlertsECCCTests {
    /// The Toronto capture time (16:15 UTC).
    static let nowS: Int64 = 1_793_031_300
    /// The Toronto frost advisory: event start, message expiry, event end.
    static let torontoOnset: Int64 = 1_793_077_200
    static let torontoExpires: Int64 = 1_793_082_067
    static let torontoEnds: Int64 = 1_793_109_600
    /// The national-set capture time (14:30 UTC), before the ended blizzard warning expired.
    static let ivujivikNowS: Int64 = 1_793_025_027

    static let toronto = "alerts-eccc-toronto-point.json"
    static let ivujivik = "alerts-eccc-ivujivik-ended-limit1.json"

    static func parse(_ data: Data, nowS: Int64 = nowS) -> WxAlertCoverage? {
        WxECCCAlerts.parse(data, status: 200, nowS: nowS)
    }

    static func edited(_ name: String, _ edits: [(String, String)]) throws -> Data {
        try WxAlertTests.edited(name, edits)
    }

    // MARK: - Request

    @Test func requestUsesIntersectsPoint() throws {
        let url = WxECCCAlerts.url(lat: 43.653_226, lon: -79.383_184)
        #expect(url == "https://api.weather.gc.ca/collections/weather-alerts/items?f=json&skipGeometry=true"
            + "&limit=100&filter=INTERSECTS(geometry,POINT(-79.3832%2043.6532))")
        // The filter is a CQL2 point, longitude first, at 4 decimals.
        let c = try #require(URLComponents(string: url))
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["filter"] == "INTERSECTS(geometry,POINT(-79.3832 43.6532))")
        #expect(q["skipGeometry"] == "true" && q["f"] == "json" && q["bbox"] == nil)
        let north = try #require(URLComponents(string: WxECCCAlerts.url(lat: 82.5018, lon: -62.3481)))
        #expect(north.queryItems?.first { $0.name == "filter" }?.value
            == "INTERSECTS(geometry,POINT(-62.3481 82.5018))")
    }

    @Test func requestsCarryNoAPIKey() throws {
        for (lat, lon) in [(43.6532, -79.3832), (49.2827, -123.1207), (62.4540, -114.3718)] {
            let url = WxECCCAlerts.url(lat: lat, lon: lon)
            let c = try #require(URLComponents(string: url))
            #expect(c.scheme == "https" && c.host == "api.weather.gc.ca" && c.user == nil && c.password == nil)
            #expect(c.path == "/collections/weather-alerts/items")
            #expect((c.queryItems ?? []).map(\.name) == ["f", "skipGeometry", "limit", "filter"], "\(url)")
            #expect(url.range(of: "key|token|appid|auth|secret", options: [.regularExpression, .caseInsensitive])
                == nil)
        }
    }

    // MARK: - Parser

    @Test func englishText() throws {
        let c = try #require(Self.parse(try Fixtures.data(Self.toronto)))
        #expect(c.alerts.count == 1)
        let a = try #require(c.alerts.first)
        #expect(a.id == "eccc:1227305499199632202610260503" && a.source == .eccc)
        #expect(a.event == "frost advisory" && a.headline == "frost advisory")
        #expect(a.description.hasPrefix("Frost is expected tonight.\n\nPatchy frost is expected to develop"))
        #expect(a.description.range(of: "gel|prévu", options: .regularExpression) == nil)
        #expect(a.instruction.isEmpty)
        #expect(a.level == .yellow && a.issuerSeverity == "yellow")
        #expect(a.onsetS == Self.torontoOnset && a.expiresS == Self.torontoExpires && a.endsS == Self.torontoEnds)
        #expect(a.web == WxECCCAlerts.weatherURL)
        // No English name at all: the short name, else not an answer.
        let short = try Self.edited(Self.toronto, [(#""alert_name_en":"frost advisory""#, #""alert_name_en":null"#)])
        #expect(Self.parse(short)?.alerts.first?.event == "Frost (advisory)")
        let unnamed = try Self.edited(Self.toronto, [(#""alert_name_en":"frost advisory""#, #""alert_name_en":"""#),
                                                     (#""alert_short_name_en":"Frost (advisory)""#,
                                                      #""alert_short_name_en":null"#)])
        #expect(Self.parse(unnamed) == nil)
    }

    @Test func dropsEndedAndCancelled() throws {
        // The blizzard warning has ended although its message expires 7 hours later.
        let ended = try Fixtures.data(Self.ivujivik)
        #expect(Self.parse(ended, nowS: Self.ivujivikNowS) == .noAlerts)
        let live = try Self.edited(Self.ivujivik, [(#""status_en":"ended""#, #""status_en":"continued""#)])
        #expect(Self.parse(live, nowS: Self.ivujivikNowS)?.alerts.map(\.event) == ["blizzard warning"])
        for state in ["ended", "cancelled", "Cancelled", " ended "] {
            let over = try Self.edited(Self.toronto, [(#""status_en":"issued""#, "\"status_en\":\"\(state)\"")])
            #expect(Self.parse(over) == .noAlerts, "\(state)")
        }
        let continued = try Self.edited(Self.toronto, [(#""status_en":"issued""#, #""status_en":"continued""#)])
        #expect(Self.parse(continued)?.alerts.count == 1)
    }

    @Test func dropsPastExpiration() throws {
        let data = try Fixtures.data(Self.toronto)
        #expect(Self.parse(data, nowS: Self.torontoExpires - 1)?.alerts.count == 1)
        #expect(Self.parse(data, nowS: Self.torontoExpires) == .noAlerts)
        #expect(Self.parse(data, nowS: Self.torontoEnds + 3600) == .noAlerts)
        // An event that has ended is not current even while its message is.
        let over = try Self.edited(Self.toronto, [(#""event_end_datetime":"2026-10-27T14:00:00.000Z""#,
                                                   #""event_end_datetime":"2026-10-26T16:00:00.000Z""#)])
        #expect(Self.parse(over) == .noAlerts)
        // No event end: shown until the message expires.
        let open = try Self.edited(Self.toronto, [(#""event_end_datetime":"2026-10-27T14:00:00.000Z""#,
                                                   #""event_end_datetime":null"#)])
        #expect(Self.parse(open)?.alerts.first?.untilS == Self.torontoExpires)
    }

    /// A feature for each area of one alert around the point: the alert is listed once.
    @Test func listedOncePerAlert() throws {
        let s = try Fixtures.string(Self.toronto)
        let open = try #require(s.range(of: #""features":["#)), close = try #require(s.range(of: #"],"numberMatched""#))
        let feature = String(s[open.upperBound..<close.lowerBound])
        let other = feature.replacingOccurrences(of: "fea1-1185", with: "fea1-1269")
        let twice = s.replacingCharacters(in: open.upperBound..<close.lowerBound, with: feature + "," + other)
        #expect(Self.parse(Data(twice.utf8))?.alerts.map(\.id) == ["eccc:1227305499199632202610260503"])
    }

    /// ECCC's loader gives an area without a feature_id a fresh UUID ("<alert id>_<uuid>") on
    /// every ingest: the alert is still listed once, by the part of the id before the first "_",
    /// and keeps that id from one refresh to the next.
    @Test func featureSuffixesCollapseToOneStableAlert() throws {
        let s = try Fixtures.string(Self.toronto)
        let open = try #require(s.range(of: #""features":["#)), close = try #require(s.range(of: #"],"numberMatched""#))
        let feature = String(s[open.upperBound..<close.lowerBound])
        func areas(_ suffixes: [String]) -> Data {
            let list = suffixes.map {
                feature.replacingOccurrences(of: "_fea1-1185\"", with: "_\($0)\"")
                    .replacingOccurrences(of: #""feature_id":"fea1-1185""#, with: #""feature_id":null"#)
            }
            return Data(s.replacingCharacters(in: open.upperBound..<close.lowerBound,
                                              with: list.joined(separator: ",")).utf8)
        }
        // The last refresh's suffixes contain "_" themselves: only the split at the FIRST "_" keeps
        // the id (a split at the last one would list "1227..._fea1" and "1227..._area"; U64 handoff).
        let refreshes = [["6f1c2b9e-4a0d-4c39-9b1e-0d6f3c2a8e11", "b7e0c9d2-1f3a-4e5b-8c6d-7a9b0c1d2e3f"],
                         ["0e8d7c6b-5a49-4382-9170-6f5e4d3c2b1a", "fea1-1185", "3c2b1a09-8f7e-4d6c-b5a4-938271605f4e"],
                         ["fea1_1185", "area_2_9b1e-0d6f3c2a8e11"]]
        for suffixes in refreshes {
            let d = areas(suffixes)
            #expect(Self.parse(d)?.alerts.map(\.id) == ["eccc:1227305499199632202610260503"], "\(suffixes)")
            #expect(Self.parse(d)?.alerts.allSatisfy { $0.isCurrent(atS: Self.nowS) } == true)
            #expect(Self.parse(d, nowS: Self.torontoExpires) == .noAlerts)
        }
    }

    @Test func empty() throws {
        #expect(Self.parse(try Fixtures.data("alerts-eccc-paris-point-empty.json")) == .noAlerts)
    }

    @Test func malformed() throws {
        let d = try Fixtures.data(Self.toronto)
        #expect(Self.parse(d.prefix(d.count / 2)) == nil)
        #expect(Self.parse(Data("<html>".utf8)) == nil)
        #expect(Self.parse(Data(#"{"type":"FeatureCollection"}"#.utf8)) == nil)
        #expect(WxECCCAlerts.parse(d, status: 500, nowS: Self.nowS) == nil)
        #expect(WxECCCAlerts.parse(try Fixtures.data(Self.ivujivik), status: 404, nowS: Self.ivujivikNowS) == nil)
        let badTime = try Self.edited(Self.toronto, [(#""expiration_datetime":"2026-10-27T06:21:07.462Z""#,
                                                      #""expiration_datetime":"tomorrow""#)])
        #expect(Self.parse(badTime) == nil)
        let noExpiry = try Self.edited(Self.toronto, [(#""expiration_datetime":"2026-10-27T06:21:07.462Z""#,
                                                       #""expiration_datetime":null"#)])
        #expect(Self.parse(noExpiry) == nil)
        let badOnset = try Self.edited(Self.toronto, [(#""validity_datetime":"2026-10-27T05:00:00.000Z""#,
                                                       #""validity_datetime":"05:00""#)])
        #expect(Self.parse(badOnset) == nil)
    }

    /// status_en is ECCC's only "ended early" signal: an alert that is otherwise current but whose
    /// status is missing or unknown is not shown and not hidden; the answer is unreadable. One
    /// whose message has expired is dropped all the same.
    @Test func statuslessAlertIsUnreadable() throws {
        for state in ["null", #""""#, #""upgraded""#] {
            let d = try Self.edited(Self.toronto, [(#""status_en":"issued""#, "\"status_en\":\(state)")])
            #expect(Self.parse(d) == nil, "\(state)")
            #expect(Self.parse(d, nowS: Self.torontoExpires) == .noAlerts, "\(state)")
        }
        let absent = try Self.edited(Self.toronto, [(#""status_en":"issued","#, "")])
        #expect(Self.parse(absent) == nil)
    }
}
