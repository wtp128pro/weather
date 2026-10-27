// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsPointSourcesTests.swift - the NWS, Bright Sky and MET Norway alert
// requests and parsers against real answers captured on 2026-10-26
// (Fixtures/alerts): NWS Alaska (3 of 14 alerts), a Kansas point (none) and
// Paris (400 out of bounds); Bright Sky all of Germany (2 of 10, and 2 of 8
// at 15:32 UTC with an open-ended alert), Berlin (none) and Paris (404); MET
// Norway all of Norway (2 of 30) and Paris (none). Malformed answers are the
// recorded ones truncated or with one field broken.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct AlertsPointSourcesTests {
    /// The NWS capture time; every fixture alert but none of the open-ended ones is current then.
    static let nowS: Int64 = 1_793_025_010

    static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    static func edited(_ name: String, _ edits: [(String, String)]) throws -> Data {
        try WxAlertTests.edited(name, edits)
    }

    static func truncated(_ name: String) throws -> Data {
        let d = try fixture(name)
        return d.prefix(d.count / 2)
    }

    // MARK: - Requests

    @Test func requestsCarryNoAPIKey() throws {
        let urls = [
            (WxPointAlerts.nwsURL(lat: 39.7456, lon: -97.0892), "api.weather.gov", "/alerts/active", ["point"]),
            (WxPointAlerts.brightSkyURL(lat: 52.52, lon: 13.4), "api.brightsky.dev", "/alerts", ["lat", "lon"]),
            (WxPointAlerts.metNorwayURL(lat: 60.3913, lon: 5.3221), "api.met.no",
             "/weatherapi/metalerts/2.0/current.json", ["lat", "lon", "lang"]),
        ]
        for (url, host, path, names) in urls {
            let c = try #require(URLComponents(string: url))
            #expect(c.scheme == "https" && c.host == host && c.path == path && c.user == nil && c.password == nil)
            #expect((c.queryItems ?? []).map(\.name) == names, "\(url)")
            #expect(url.range(of: "key|token|appid|auth|secret", options: [.regularExpression, .caseInsensitive]) == nil)
        }
        #expect(WxPointAlerts.nwsURL(lat: 39.7456, lon: -97.0892)
            == "https://api.weather.gov/alerts/active?point=39.7456,-97.0892")
        #expect(WxPointAlerts.brightSkyURL(lat: 52.52, lon: 13.4) == "https://api.brightsky.dev/alerts?lat=52.5200&lon=13.4000")
    }

    @Test func metnoRequestsEnglishWithFourDecimals() throws {
        #expect(WxPointAlerts.metNorwayURL(lat: 60.391263, lon: 5.322054)
            == "https://api.met.no/weatherapi/metalerts/2.0/current.json?lat=60.3913&lon=5.3221&lang=en")
        for (lat, lon) in [(78.223_23, 15.626_72), (-33.868_82, 151.209_29), (0.000_04, -0.000_06), (59.9, 10.75)] {
            let c = try #require(URLComponents(string: WxPointAlerts.metNorwayURL(lat: lat, lon: lon)))
            let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(q["lang"] == "en")
            for key in ["lat", "lon"] {
                let v = try #require(q[key])
                let decimals = v.split(separator: ".").last?.count ?? 0
                #expect(v.contains(".") && decimals <= 4, "\(key)=\(v)")
                #expect(abs((Double(v) ?? .nan) - (key == "lat" ? lat : lon)) <= 0.000_05)
            }
        }
    }

    // MARK: - NWS

    @Test func nwsEmpty() throws {
        let c = WxPointAlerts.parseNWS(try Self.fixture("alerts-nws-point-empty.json"), status: 200, nowS: Self.nowS)
        #expect(c == .noAlerts)
    }

    @Test func nwsOutOfBoundsIsNotCovered() throws {
        let body = try Self.fixture("alerts-nws-point-out-of-bounds-400.json")
        #expect(WxPointAlerts.parseNWS(body, status: 400, nowS: Self.nowS) == .notCovered)
        // Another 400, the problem body on another status, a server error: not an answer.
        let badFormat = try Self.edited("alerts-nws-point-out-of-bounds-400.json", [("out of bounds", "bad format")])
        #expect(WxPointAlerts.parseNWS(badFormat, status: 400, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(body, status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(body, status: 500, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(Data("<html>".utf8), status: 400, nowS: Self.nowS) == nil)
    }

    @Test func nwsDropsExpired() throws {
        let ak = try Self.fixture("alerts-nws-area-ak-trim3.json")
        // The messages expire at 22:00 AKDT (06:00 UTC on 27 Oct), before their events end.
        let expires: Int64 = 1_793_080_800
        #expect(WxPointAlerts.parseNWS(ak, status: 200, nowS: expires - 1)?.alerts.count == 3)
        #expect(WxPointAlerts.parseNWS(ak, status: 200, nowS: expires) == .noAlerts)
        // An event that has ended is not current even while its message is.
        let ended = try Self.edited("alerts-nws-area-ak-trim3.json",
                                    [(#""ends": "2026-10-28T04:00:00-08:00""#, #""ends": "2026-10-26T06:30:00-08:00""#)])
        #expect(WxPointAlerts.parseNWS(ended, status: 200, nowS: Self.nowS) == .noAlerts)
        // No end of the event: shown until the message expires.
        let noEnd = try Self.edited("alerts-nws-area-ak-trim3.json",
                                    [(#""ends": "2026-10-28T04:00:00-08:00""#, #""ends": null"#)])
        let open = try #require(WxPointAlerts.parseNWS(noEnd, status: 200, nowS: Self.nowS))
        #expect(open.alerts.count == 3 && open.alerts.allSatisfy { $0.endsS == nil && $0.untilS == expires })
    }

    @Test func nwsMalformed() throws {
        let name = "alerts-nws-area-ak-trim3.json"
        #expect(WxPointAlerts.parseNWS(try Self.truncated(name), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(Data("<html>".utf8), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(Data(#"{"type":"FeatureCollection"}"#.utf8), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseNWS(Data(#"{"features":[{"id":"x"}]}"#.utf8), status: 200, nowS: Self.nowS) == nil)
        // An alert whose expiry cannot be read hides nothing behind a false "no alerts".
        let badTime = try Self.edited(name, [(#""expires": "2026-10-26T22:00:00-08:00""#, #""expires": "tonight""#)])
        #expect(WxPointAlerts.parseNWS(badTime, status: 200, nowS: Self.nowS) == nil)
        let noExpiry = try Self.edited(name, [(#""expires": "2026-10-26T22:00:00-08:00""#, #""expires": null"#)])
        #expect(WxPointAlerts.parseNWS(noExpiry, status: 200, nowS: Self.nowS) == nil)
        let noName = try Self.edited(name, [(#""event": "High Surf Advisory""#, #""event": null"#),
                                            (#""headline": "High Surf Advisory issued"#, #""x": "issued"#)])
        #expect(WxPointAlerts.parseNWS(noName, status: 200, nowS: Self.nowS) == nil)
    }

    // MARK: - Bright Sky

    @Test func brightSkyEmpty() throws {
        let c = WxPointAlerts.parseBrightSky(try Self.fixture("alerts-brightsky-berlin-empty.json"), status: 200,
                                             nowS: Self.nowS)
        #expect(c == .noAlerts)
    }

    @Test func brightSkyNotFoundIsNotCovered() throws {
        let body = try Self.fixture("alerts-brightsky-not-covered-404.json")
        #expect(WxPointAlerts.parseBrightSky(body, status: 404, nowS: Self.nowS) == .notCovered)
        #expect(WxPointAlerts.parseBrightSky(Data(#"{"detail":"Not Found"}"#.utf8), status: 404, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseBrightSky(body, status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseBrightSky(body, status: 422, nowS: Self.nowS) == nil)
    }

    @Test func brightSkyNullExpiresKept() throws {
        let d = try Self.fixture("alerts-brightsky-all-nullexpires-trim2.json")
        let captured: Int64 = 1_793_028_770  // 15:32:50 UTC
        let c = try #require(WxPointAlerts.parseBrightSky(d, status: 200, nowS: captured))
        #expect(c.alerts.map(\.id) == ["dwd:3046172", "dwd:3046177"])
        let open = try #require(c.alerts.last)
        #expect(open.expiresS == nil && open.endsS == nil && open.untilS == nil && open.onsetS == 1_793_025_180)
        #expect(open.event == "near gale" && open.level == .yellow && open.issuerSeverity == "minor")
        // A week later the dated alert (until 27 Oct 08:00 UTC) is gone, the open-ended one is not.
        let later = try #require(WxPointAlerts.parseBrightSky(d, status: 200, nowS: captured + 7 * 86_400))
        #expect(later.alerts.map(\.id) == ["dwd:3046177"])
        #expect(WxPointAlerts.parseBrightSky(d, status: 200, nowS: 1_793_088_000)?.alerts.count == 1)
    }

    @Test func brightSkyTestStatusDropped() throws {
        // The first alert (3045641) only: its status is followed by its first warn cell.
        let d = try Self.edited("alerts-brightsky-all-trim2.json", [
            (#""status": "actual",\#n   "warn_cell_ids": [\#n    813073078"#,
             #""status": "test",\#n   "warn_cell_ids": [\#n    813073078"#),
        ])
        let c = try #require(WxPointAlerts.parseBrightSky(d, status: 200, nowS: Self.nowS))
        #expect(c.alerts.map(\.id) == ["dwd:3045968"])
    }

    @Test func brightSkyMalformed() throws {
        let name = "alerts-brightsky-all-trim2.json"
        #expect(WxPointAlerts.parseBrightSky(try Self.truncated(name), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseBrightSky(Data("<html>".utf8), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseBrightSky(Data(#"{"location":{"warn_cell_id":1}}"#.utf8), status: 200,
                                             nowS: Self.nowS) == nil)
        let badTime = try Self.edited(name, [(#""expires": "2026-10-26T17:00:00+00:00""#, #""expires": "17:00""#)])
        #expect(WxPointAlerts.parseBrightSky(badTime, status: 200, nowS: Self.nowS) == nil)
        let noID = try Self.edited(name, [(#""id": 3045641,"#, ""), (#""alert_id": 3045641,"#, "")])
        #expect(WxPointAlerts.parseBrightSky(noID, status: 200, nowS: Self.nowS) == nil)
        // The id as the documented CAP identifier string is read too.
        let stringID = try Self.edited(name, [(#""alert_id": 3045641"#, #""alert_id": "2.49.0.0.276.0.DWD.x""#)])
        #expect(WxPointAlerts.parseBrightSky(stringID, status: 200, nowS: Self.nowS)?.alerts.first?.id
            == "dwd:2.49.0.0.276.0.DWD.x")
    }

    // MARK: - MET Norway

    @Test func metnoEmpty() throws {
        let c = WxPointAlerts.parseMETNorway(try Self.fixture("alerts-metno-outside-norway-empty.json"), status: 200,
                                             nowS: Self.nowS)
        #expect(c == .noAlerts)
    }

    @Test func metnoValidityFromInterval() throws {
        let d = try Self.fixture("alerts-metno-current-en-trim2.json")
        let c = try #require(WxPointAlerts.parseMETNorway(d, status: 200, nowS: Self.nowS))
        #expect(c.alerts.map(\.id) == ["metno:2.49.0.1.578.0.20261026080722.092", "metno:2.49.0.1.578.0.20261026081330.059"])
        let a = try #require(c.alerts.first)
        // when.interval = [21:00 UTC 26 Oct, 13:00 UTC 27 Oct]: starts in the future, expires at the end.
        #expect(a.onsetS == 1_793_048_400 && a.expiresS == 1_793_106_000 && a.endsS == nil && a.untilS == 1_793_106_000)
        #expect(a.onsetS ?? 0 > Self.nowS)
        #expect(a.event == "Storm" && a.headline.hasPrefix("Storm, yellow level, Maaloey - Stad,"))
        #expect(a.instruction.hasPrefix("Do not go out in a small boat:") && a.description.hasPrefix("From Monday evening"))
        #expect(a.web?.hasPrefix("https://www.met.no/") == true)
        #expect(WxPointAlerts.parseMETNorway(d, status: 200, nowS: 1_793_105_999)?.alerts.count == 2)
        #expect(WxPointAlerts.parseMETNorway(d, status: 200, nowS: 1_793_106_000) == .noAlerts)
        // An earlier event end in the properties ends it sooner.
        let ending = try Self.edited("alerts-metno-current-en-trim2.json",
                                     [(#""geographicDomain": "marine","#,
                                       #""geographicDomain": "marine", "eventEndingTime": "2026-10-27T01:00:00+00:00","#)])
        let e = try #require(WxPointAlerts.parseMETNorway(ending, status: 200, nowS: Self.nowS))
        #expect(e.alerts.allSatisfy { $0.endsS == 1_793_062_800 && $0.untilS == 1_793_062_800 })
        #expect(WxPointAlerts.parseMETNorway(ending, status: 200, nowS: 1_793_062_800) == .noAlerts)
    }

    @Test func metnoMalformed() throws {
        let name = "alerts-metno-current-en-trim2.json"
        #expect(WxPointAlerts.parseMETNorway(try Self.truncated(name), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseMETNorway(Data(#"{"type":"FeatureCollection"}"#.utf8), status: 200,
                                             nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseMETNorway(try Self.fixture(name), status: 403, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseMETNorway(try Self.fixture(name), status: 429, nowS: Self.nowS) == nil)
        let badTime = try Self.edited(name, [(#""2026-10-27T13:00:00+00:00""#, #""tomorrow""#)])
        #expect(WxPointAlerts.parseMETNorway(badTime, status: 200, nowS: Self.nowS) == nil)
        let noWhen = try Self.edited(name, [(#""when""#, #""whence""#)])
        #expect(WxPointAlerts.parseMETNorway(noWhen, status: 200, nowS: Self.nowS) == nil)
        // An interval with only its start.
        let oneEnd = try Self.edited(name, [(#""2026-10-26T21:00:00+00:00",\#n     "2026-10-27T13:00:00+00:00""#,
                                             #""2026-10-26T21:00:00+00:00""#)])
        #expect(WxPointAlerts.parseMETNorway(oneEnd, status: 200, nowS: Self.nowS) == nil)
    }

    // MARK: - All three

    /// CAP requires a status: an alert without one (missing, null or blank) that would otherwise
    /// be current could be a real warning or a test, so the answer is unreadable (nil), never a
    /// false "no alerts". The minimal objects are the ones U29's verifier probed.
    @Test func statuslessCurrentAlertIsUnavailable() throws {
        let nwsTornado = #"{"features":[{"id":"x","properties":{"id":"a","event":"Tornado Warning","#
            + #""severity":"Extreme","expires":"2026-10-27T00:00:00Z"}}]}"#
        for body in [nwsTornado, #"{"features":[{"id":"x","properties":{}}]}"#] {
            #expect(WxPointAlerts.parseNWS(Data(body.utf8), status: 200, nowS: Self.nowS) == nil, "\(body)")
        }
        #expect(WxPointAlerts.parseBrightSky(Data(#"{"alerts":[{}]}"#.utf8), status: 200, nowS: Self.nowS) == nil)
        #expect(WxPointAlerts.parseMETNorway(Data(#"{"features":[{"properties":{}}]}"#.utf8), status: 200,
                                             nowS: Self.nowS) == nil)
        for state in ["null", #""""#, #"" ""#] {
            let nws = try Self.edited("alerts-nws-area-ak-trim3.json", [(#""status": "Actual""#, "\"status\": \(state)")])
            #expect(WxPointAlerts.parseNWS(nws, status: 200, nowS: Self.nowS) == nil, "\(state)")
            let dwd = try Self.edited("alerts-brightsky-all-trim2.json", [(#""status": "actual""#, "\"status\": \(state)")])
            #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: Self.nowS) == nil, "\(state)")
            let met = try Self.edited("alerts-metno-current-en-trim2.json",
                                      [(#""status": "Actual""#, "\"status\": \(state)")])
            #expect(WxPointAlerts.parseMETNorway(met, status: 200, nowS: Self.nowS) == nil, "\(state)")
        }
        // An open-ended Bright Sky alert without a status is never over.
        let open = try Self.edited("alerts-brightsky-all-nullexpires-trim2.json",
                                   [(#""status": "actual""#, #""x": "actual""#)])
        #expect(WxPointAlerts.parseBrightSky(open, status: 200, nowS: 1_793_028_770 + 7 * 86_400) == nil)
    }

    /// A status-less alert already over by a readable expiry or end is dropped like any expired
    /// alert, while a real alert next to it is still shown; a status-less Cancel is never shown.
    @Test func statuslessExpiredAlertIsDropped() throws {
        let ak = "alerts-nws-area-ak-trim3.json", noStatus = (#""status": "Actual""#, #""x": "Actual""#)
        #expect(WxPointAlerts.parseNWS(try Self.edited(ak, [noStatus]), status: 200, nowS: 1_793_080_800) == .noAlerts)
        let ended = try Self.edited(ak, [
            noStatus, (#""ends": "2026-10-28T04:00:00-08:00""#, #""ends": "2026-10-26T06:30:00-08:00""#),
        ])
        #expect(WxPointAlerts.parseNWS(ended, status: 200, nowS: Self.nowS) == .noAlerts)
        let cancel = try Self.edited(ak, [noStatus, (#""messageType": "Update""#, #""messageType": "Cancel""#)])
        #expect(WxPointAlerts.parseNWS(cancel, status: 200, nowS: Self.nowS) == .noAlerts)
        // Bright Sky: only the first alert (until 17:00 UTC) loses its status; at 17:00 it is
        // dropped and the real second alert (until 03:00 UTC) is still shown.
        let dwd = try Self.edited("alerts-brightsky-all-trim2.json", [
            (#""status": "actual",\#n   "warn_cell_ids": [\#n    813073078"#, #""warn_cell_ids": [\#n    813073078"#),
        ])
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: Self.nowS) == nil)
        let later = try #require(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: 1_793_034_000))
        #expect(later.alerts.map(\.id) == ["dwd:3045968"] && later.alerts.allSatisfy { $0.isCurrent(atS: 1_793_034_000) })
        let metno = "alerts-metno-current-en-trim2.json"
        let met = try Self.edited(metno, [noStatus])
        #expect(WxPointAlerts.parseMETNorway(met, status: 200, nowS: 1_793_106_000) == .noAlerts)
        let metEnded = try Self.edited(metno, [
            noStatus, (#""geographicDomain": "marine","#,
                       #""geographicDomain": "marine", "eventEndingTime": "2026-10-26T14:00:00+00:00","#),
        ])
        #expect(WxPointAlerts.parseMETNorway(metEnded, status: 200, nowS: Self.nowS) == .noAlerts)
    }

    @Test func expiredAlertsDropped() throws {
        let nws = try Self.fixture("alerts-nws-area-ak-trim3.json")
        let dwd = try Self.fixture("alerts-brightsky-all-trim2.json")
        let met = try Self.fixture("alerts-metno-current-en-trim2.json")
        // Bright Sky: the first alert expires at 17:00 UTC, the second at 03:00 UTC on 27 Oct.
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: Self.nowS)?.alerts.count == 2)
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: 1_793_034_000)?.alerts.map(\.id) == ["dwd:3045968"])
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: 1_793_070_000) == .noAlerts)
        // After the last expiry nothing is current anywhere.
        let late: Int64 = 1_793_188_800
        #expect(WxPointAlerts.parseNWS(nws, status: 200, nowS: late) == .noAlerts)
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: late) == .noAlerts)
        #expect(WxPointAlerts.parseMETNorway(met, status: 200, nowS: late) == .noAlerts)
        // Whatever is returned is current at the time asked.
        for t in stride(from: Self.nowS, through: late, by: 3_600) {
            let all = [WxPointAlerts.parseNWS(nws, status: 200, nowS: t), WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: t),
                       WxPointAlerts.parseMETNorway(met, status: 200, nowS: t)].compactMap { $0?.alerts }.joined()
            #expect(all.allSatisfy { $0.isCurrent(atS: t) && ($0.untilS ?? .max) > t }, "at \(t)")
        }
    }
}
