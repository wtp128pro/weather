// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertsMeteoAlarmTests.swift - the MeteoAlarm feed requests and parser
// against real feed warnings captured on 2026-10-26 (Fixtures/alerts): France
// (2 live warnings, one with an inline polygon, and an expired green Update,
// of 184), Croatia and Hungary (EMMA_ID with NUTS3, and NUTS2), Ukraine (an
// Alert and the Update that supersedes it, with three polygons) and Cyprus
// (no warnings). Malformed answers are the recorded ones truncated or with
// one field broken; the Switzerland-sized feed is synthesized.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct AlertsMeteoAlarmTests {
    /// 16:15 UTC on 26 October: the France, Croatia and Hungary warnings are live.
    static let nowS: Int64 = 1_793_031_300
    /// The France warnings' expiry (27 Oct 00:00 +01:00) and onset (26 Oct 06:00:08 +01:00).
    static let franceExpires: Int64 = 1_793_055_600
    static let franceOnset: Int64 = 1_792_990_808
    /// 06:00 UTC on 22 October, before the Ukraine warnings expired (18:00 UTC).
    static let ukraineNowS: Int64 = 1_792_648_800
    static let ukraineExpires: Int64 = 1_792_692_000
    /// The Ukraine Alert that the recorded (Actual) Update supersedes.
    static let ukraineAlertID = "meteoAlarm:2.49.0.0.804.0.GB.261021103948.ewCirE752W51gIdDEKGj"

    static let france = "alerts-meteoalarm-france-trim3.json"
    static let croatiaHungary = "alerts-meteoalarm-croatia-hungary-trim2.json"
    static let ukraine = "alerts-meteoalarm-ukraine-update-trim2.json"

    static func parse(_ data: Data, nowS: Int64 = nowS) -> [WxMeteoAlarm.Warning]? {
        WxMeteoAlarm.parse(data, status: 200, nowS: nowS)
    }

    static func edited(_ name: String, _ edits: [(String, String)]) throws -> Data {
        try WxAlertTests.edited(name, edits)
    }

    /// A recorded feed with `change` applied to every info block of warning `index` (of all
    /// warnings when nil).
    static func changingInfos(_ name: String, warning index: Int? = nil,
                              _ change: (inout [String: Any]) -> Void) throws -> Data {
        let root = try #require(try JSONSerialization.jsonObject(with: Fixtures.data(name)) as? [String: Any])
        var warnings = try #require(root["warnings"] as? [[String: Any]])
        for i in warnings.indices where index == nil || index == i {
            var alert = try #require(warnings[i]["alert"] as? [String: Any])
            var infos = try #require(alert["info"] as? [[String: Any]])
            for j in infos.indices {
                change(&infos[j])
            }
            alert["info"] = infos
            warnings[i]["alert"] = alert
        }
        return try JSONSerialization.data(withJSONObject: ["warnings": warnings])
    }

    /// A recorded feed with `change` applied to the CAP alert of warning `index`.
    static func changingAlert(_ name: String, warning index: Int,
                              _ change: (inout [String: Any]) -> Void) throws -> Data {
        let root = try #require(try JSONSerialization.jsonObject(with: Fixtures.data(name)) as? [String: Any])
        var warnings = try #require(root["warnings"] as? [[String: Any]])
        var alert = try #require(warnings[index]["alert"] as? [String: Any])
        change(&alert)
        warnings[index]["alert"] = alert
        return try JSONSerialization.data(withJSONObject: ["warnings": warnings])
    }

    /// `info` with one more CAP parameter.
    static func adding(_ name: String, _ value: String, to info: inout [String: Any]) {
        info["parameter"] = (info["parameter"] as? [Any] ?? []) + [["valueName": name, "value": value]]
    }

    // MARK: - Request

    @Test func feedURLCarriesNoAPIKey() throws {
        let url = WxMeteoAlarm.feedURL(slug: "france")
        #expect(url == "https://feeds.meteoalarm.org/api/v1/warnings/feeds-france")
        let c = try #require(URLComponents(string: url))
        #expect(c.scheme == "https" && c.host == "feeds.meteoalarm.org" && c.query == nil && c.user == nil)
        #expect(url.range(of: "key|token|appid|auth|secret", options: [.regularExpression, .caseInsensitive]) == nil)
    }

    // MARK: - Parser

    @Test func extractsEnglishInfoAndGeocodes() throws {
        let fr = try #require(Self.parse(try Fixtures.data(Self.france)))
        #expect(fr.map(\.alert.id) == ["meteoAlarm:2.49.0.0.250.0.FR.20261026060017.991021",
                                       "meteoAlarm:2.49.0.0.250.0.FR.20261026060023.745029"])
        let wind = try #require(fr.first)
        // The en-GB block, not the fr-FR one listed first.
        #expect(wind.alert.event == "Moderate wind warning" && wind.alert.headline == "Moderate wind warning")
        #expect(wind.alert.description.hasPrefix("Moderate damages may occur"))
        #expect(wind.alert.instruction.hasPrefix("Be careful, keep informed"))
        #expect(wind.alert.source == .meteoAlarm && wind.alert.level == .yellow)
        #expect(wind.alert.issuerSeverity == "2; yellow; Moderate")
        #expect(wind.alert.onsetS == Self.franceOnset && wind.alert.expiresS == Self.franceExpires)
        #expect(wind.alert.endsS == nil && wind.alert.web == "https://vigilance.meteofrance.fr/")
        #expect(wind.msgType == "Alert" && wind.references.isEmpty && !wind.polygonOverGeocode)
        #expect(wind.areas == [WxMeteoAlarm.Area(description: "Finistère",
                                                 geocodes: [.init(name: "NUTS3", value: "FR522")], polygons: [])])

        let hrhu = try #require(Self.parse(try Fixtures.data(Self.croatiaHungary)))
        #expect(hrhu.count == 2)
        let hr = try #require(hrhu.first), hu = try #require(hrhu.last)
        // Croatia: hr-HR first, en-GB second; no headline, so the event; onset in the future.
        #expect(hr.alert.event == "Yellow wind warning" && hr.alert.headline == "Yellow wind warning")
        #expect(hr.alert.onsetS == 1_793_199_600 && hr.alert.expiresS == 1_793_314_799 && hr.alert.web == nil)
        #expect(hr.areas.first?.description == "Zadarska")
        #expect(hr.areas.first?.geocodes(named: "EMMA_ID") == ["HR023"])
        #expect(hr.areas.first?.geocodes(named: "NUTS3") == ["HR033"])
        #expect(hu.alert.headline == "yellow thunderstorm warning for Hungary")
        #expect(hu.areas.first?.geocodes(named: "NUTS2") == ["HU33"] && hu.areas.first?.polygons == [])

        // No English block: the first block.
        let noEnglish = try Self.edited(Self.croatiaHungary, [(#""language": "en-GB""#, #""language": "de""#)])
        let first = try #require(Self.parse(noEnglish))
        #expect(first.map(\.alert.event) == ["Žuto upozorenje za vjetar", "sárga heves zivatar figyelmeztetés"])
        // "en" alone (Switzerland, Bosnia) is English too.
        let en = try Self.edited(Self.croatiaHungary, [(#""language": "en-GB""#, #""language": "en""#)])
        #expect(Self.parse(en)?.first?.alert.event == "Yellow wind warning")
    }

    @Test func dropsExpiredGreenAndCancelled() throws {
        let fr = try Fixtures.data(Self.france)
        // The third warning expired on 21 October (and was green).
        #expect(Self.parse(fr)?.count == 2)
        #expect(Self.parse(fr, nowS: Self.franceExpires - 1)?.count == 2)
        #expect(Self.parse(fr, nowS: Self.franceExpires) == [])
        // Level 1 green is no warning.
        let green = try Self.edited(Self.france, [("2; yellow; Moderate", "1; green; Minor")])
        #expect(Self.parse(green) == [])
        // A Cancel is not shown, and the warning it cancels is withdrawn.
        let ua = try Fixtures.data(Self.ukraine)
        #expect(Self.parse(ua, nowS: Self.ukraineNowS)?.count == 1)
        let cancel = try Self.edited(Self.ukraine, [(#""msgType": "Update""#, #""msgType": "Cancel""#)])
        #expect(Self.parse(cancel, nowS: Self.ukraineNowS) == [])
        for type in ["Ack", "Error"] {
            let d = try Self.edited(Self.france, [(#""msgType": "Alert""#, "\"msgType\": \"\(type)\"")])
            #expect(Self.parse(d) == [], "\(type)")
        }
        // Test, Exercise, System and Draft messages are not real.
        for state in ["Test", "Exercise", "System", "Draft"] {
            let d = try Self.edited(Self.france, [(#""status": "Actual""#, "\"status\": \"\(state)\"")])
            #expect(Self.parse(d) == [], "\(state)")
        }
        // An event that has ended (eventEndingTime) is not current while the message is.
        let ended = try Self.changingInfos(Self.croatiaHungary) {
            Self.adding("eventEndingTime", "2026-10-26T15:00:00+00:00", to: &$0)
        }
        #expect(Self.parse(ended) == [])
        #expect(Self.parse(ended, nowS: 1_793_026_799)?.count == 2)
    }

    @Test func supersededByReferences() throws {
        let ua = try #require(Self.parse(try Fixtures.data(Self.ukraine), nowS: Self.ukraineNowS))
        #expect(ua.map(\.alert.id) == ["meteoAlarm:2.49.0.0.804.0.GB.261021104009.ewCirE752W51gIdDEKGj"])
        let update = try #require(ua.first)
        #expect(update.msgType == "Update")
        #expect(update.references == [WxMeteoAlarm.Reference(
            sender: "cap@meteo.gov.ua", identifier: "2.49.0.0.804.0.GB.261021103948.ewCirE752W51gIdDEKGj",
            sent: "2026-10-21T13:39:48+03:00")])
        // A reference to another message, or to the same identifier from another sender, supersedes nothing.
        let other = try Self.edited(Self.ukraine, [(",2.49.0.0.804.0.GB.261021103948.", ",2.49.0.0.804.0.GB.261021000000.")])
        #expect(Self.parse(other, nowS: Self.ukraineNowS)?.count == 2)
        let sender = try Self.edited(Self.ukraine, [(#""references": "cap@meteo.gov.ua,"#, #""references": "x@y.example,"#)])
        #expect(Self.parse(sender, nowS: Self.ukraineNowS)?.count == 2)
        // An Update that has itself expired still withdraws what it updates.
        let expiredUpdate = try Self.changingInfos(Self.ukraine, warning: 1) {
            $0["expires"] = "2026-10-22T05:00:00+00:00"
        }
        #expect(Self.parse(expiredUpdate, nowS: Self.ukraineNowS) == [])
        #expect(Self.parse(try Fixtures.data(Self.ukraine), nowS: 1_792_692_000) == [])
    }

    @Test func inlinePolygonsExtracted() throws {
        let fr = try #require(Self.parse(try Fixtures.data(Self.france)))
        let coast = try #require(fr.last?.areas.first)
        #expect(coast.description == "Pas-de-Calais" && coast.geocodes.isEmpty && coast.polygons.count == 1)
        let ring = try #require(coast.polygons.first)
        #expect(ring.count == 13)
        #expect(ring[0] == WxMeteoAlarm.Point(lat: 51.0984, lon: 1.4893))
        #expect(ring[1] == WxMeteoAlarm.Point(lat: 51.1657, lon: 1.6758))
        #expect(ring.first == ring.last)
        // Ukraine: one area of three rings.
        let ua = try #require(Self.parse(try Fixtures.data(Self.ukraine), nowS: Self.ukraineNowS)?.first?.areas)
        #expect(ua.count == 1 && ua[0].polygons.map(\.count) == [85, 64, 82])
        #expect(ua[0].polygons[1].first == WxMeteoAlarm.Point(lat: 49.003553, lon: 22.868769))
        // The issuer's flag that the polygon is more precise than the geocodes.
        let flagged = try Self.changingInfos(Self.france) { Self.adding("use_polygon_over_geocode", "True", to: &$0) }
        #expect(Self.parse(flagged)?.map(\.polygonOverGeocode) == [true, true])
    }

    @Test func empty() throws {
        #expect(Self.parse(try Fixtures.data("alerts-meteoalarm-cyprus-empty.json")) == [])
    }

    @Test func malformed() throws {
        let d = try Fixtures.data(Self.france)
        #expect(Self.parse(d.prefix(d.count / 2)) == nil)
        #expect(Self.parse(Data("<html>".utf8)) == nil)
        #expect(Self.parse(Data("{}".utf8)) == nil)
        #expect(Self.parse(Data(#"{"warnings":[{"uuid":"x"}]}"#.utf8)) == nil)
        #expect(WxMeteoAlarm.parse(d, status: 404, nowS: Self.nowS) == nil)
        #expect(WxMeteoAlarm.parse(d, status: 500, nowS: Self.nowS) == nil)
        let badTime = try Self.edited(Self.france, [(#""expires": "2026-10-27T00:00:00+01:00""#, #""expires": "demain""#)])
        #expect(Self.parse(badTime) == nil)
        let badPolygon = try Self.edited(Self.france, [("51.0984,1.4893 51.1657,1.6758", "51.0984;1.4893 51.1657,1.6758")])
        #expect(Self.parse(badPolygon) == nil)
        let badReference = try Self.edited(Self.ukraine, [(
            #""references": "cap@meteo.gov.ua,2.49.0.0.804.0.GB.261021103948.ewCirE752W51gIdDEKGj,"#,
            #""references": "cap@meteo.gov.ua 2.49.0.0.804.0.GB.261021103948.ewCirE752W51gIdDEKGj,"#)])
        #expect(Self.parse(badReference, nowS: Self.ukraineNowS) == nil)
        let noType = try Self.edited(Self.france, [(#""msgType": "Alert""#, #""x": "Alert""#)])
        #expect(Self.parse(noType) == nil)
    }

    /// CAP requires a status: a warning that would otherwise be current but has none could be a
    /// test, so the feed is unreadable rather than shown or silently emptied. A status-less
    /// warning that has expired or is green is dropped all the same.
    @Test func statuslessWarningIsUnreadable() throws {
        let none = try Self.edited(Self.france, [(#""status": "Actual""#, #""x": "Actual""#)])
        #expect(Self.parse(none) == nil)
        #expect(Self.parse(none, nowS: Self.franceExpires) == [])
        let green = try Self.edited(Self.france, [(#""status": "Actual""#, #""status": """#),
                                                  ("2; yellow; Moderate", "1; green; Minor")])
        #expect(Self.parse(green) == [])
    }

    /// Only a real (Actual) Update withdraws the warning it references: a Test, Exercise, System
    /// or Draft Update is not shown itself and leaves the real warning in place until it expires.
    @Test func nonActualUpdateNeverWithdrawsARealWarning() throws {
        for state in ["Test", "Exercise", "System", "Draft"] {
            let d = try Self.changingAlert(Self.ukraine, warning: 1) { $0["status"] = state }
            let ua = try #require(Self.parse(d, nowS: Self.ukraineNowS), "\(state)")
            #expect(ua.map(\.alert.id) == [Self.ukraineAlertID], "\(state)")
            #expect(ua.allSatisfy { $0.alert.isCurrent(atS: Self.ukraineNowS) && $0.msgType == "Alert" })
            #expect(Self.parse(d, nowS: Self.ukraineExpires) == [], "\(state)")
        }
        // The recorded Actual Update still does.
        let real = try #require(Self.parse(try Fixtures.data(Self.ukraine), nowS: Self.ukraineNowS))
        #expect(!real.map(\.alert.id).contains(Self.ukraineAlertID))
    }

    /// A Test or Exercise Cancel withdraws nothing; a real one does. A Cancel without a status
    /// may be either, so the warning it names is neither shown nor hidden: the feed is unreadable
    /// until that warning expires.
    @Test func nonActualCancelNeverWithdrawsARealWarning() throws {
        for state in ["Test", "Exercise"] {
            let d = try Self.changingAlert(Self.ukraine, warning: 1) {
                $0["msgType"] = "Cancel"
                $0["status"] = state
            }
            let ua = try #require(Self.parse(d, nowS: Self.ukraineNowS), "\(state)")
            #expect(ua.map(\.alert.id) == [Self.ukraineAlertID], "\(state)")
            #expect(ua.allSatisfy { $0.alert.isCurrent(atS: Self.ukraineNowS) })
            #expect(Self.parse(d, nowS: Self.ukraineExpires) == [], "\(state)")
        }
        let real = try Self.changingAlert(Self.ukraine, warning: 1) { $0["msgType"] = "Cancel" }
        #expect(Self.parse(real, nowS: Self.ukraineNowS) == [])
        let statusless = try Self.changingAlert(Self.ukraine, warning: 1) {
            $0["msgType"] = "Cancel"
            $0["status"] = nil
        }
        #expect(Self.parse(statusless, nowS: Self.ukraineNowS) == nil)
        #expect(Self.parse(statusless, nowS: Self.ukraineExpires) == [])
    }

    /// The third France warning expired on 21 October: an unreadable event end on it (made yellow,
    /// so only its expiry drops it), or an unreadable expiry once its event has ended, does not
    /// make the feed unreadable; the two live warnings are returned.
    @Test func expiredWarningWithUnreadableEndIsDropped() throws {
        let yellow: [String: String] = ["valueName": "awareness_level", "value": "2; yellow; Moderate"]
        let badEnd = try Self.changingInfos(Self.france, warning: 2) {
            $0["parameter"] = [yellow, ["valueName": "eventEndingTime", "value": "soon"]]
        }
        let badExpiry = try Self.changingInfos(Self.france, warning: 2) {
            $0["expires"] = "demain"
            $0["parameter"] = [yellow, ["valueName": "eventEndingTime", "value": "2026-10-21T03:00:00+02:00"]]
        }
        for d in [badEnd, badExpiry] {
            let fr = try #require(Self.parse(d))
            #expect(fr.map(\.alert.id) == ["meteoAlarm:2.49.0.0.250.0.FR.20261026060017.991021",
                                           "meteoAlarm:2.49.0.0.250.0.FR.20261026060023.745029"])
            #expect(fr.allSatisfy { $0.alert.isCurrent(atS: Self.nowS) })
            #expect(Self.parse(d, nowS: Self.franceExpires) == [])
        }
    }

    /// A warning still current by its readable time but with an unreadable one (event end or
    /// expiry) could be current: the feed is unreadable (nil), never "no alerts". Once its
    /// readable time has passed it is dropped.
    @Test func currentUnreadableWarningMakesFeedUnavailable() throws {
        let badEnd = try Self.changingInfos(Self.france, warning: 0) { Self.adding("eventEndingTime", "soon", to: &$0) }
        let badExpiry = try Self.changingInfos(Self.france, warning: 0) {
            $0["expires"] = "demain"
            Self.adding("eventEndingTime", "2026-10-27T00:00:00+01:00", to: &$0)
        }
        for d in [badEnd, badExpiry] {
            #expect(Self.parse(d) == nil)
            #expect(Self.parse(d, nowS: Self.franceExpires) == [])
        }
    }

    /// CAP's msgType is Alert, Update, Cancel, Ack or Error: a current message of another type is
    /// not shown, and not hidden behind a false "no alerts" either (unless it is not real).
    @Test func unknownMsgTypeIsNotShown() throws {
        let bulletin = try Self.changingAlert(Self.france, warning: 0) { $0["msgType"] = "Bulletin" }
        #expect(Self.parse(bulletin) == nil)
        #expect(Self.parse(bulletin, nowS: Self.franceExpires) == [])
        let test = try Self.changingAlert(Self.france, warning: 0) {
            $0["msgType"] = "Bulletin"
            $0["status"] = "Test"
        }
        let fr = try #require(Self.parse(test))
        #expect(fr.map(\.alert.id) == ["meteoAlarm:2.49.0.0.250.0.FR.20261026060023.745029"])
        #expect(fr.allSatisfy { $0.alert.isCurrent(atS: Self.nowS) && $0.msgType == "Alert" })
        #expect(Self.parse(test, nowS: Self.franceExpires) == [])
    }

    /// A feed the size of Switzerland's (9.1 MB: 230 warnings in five languages, each with an
    /// inline polygon of about 190 points) parses in a detached task: the parsers are nonisolated.
    @Test func largeFeedParsesOffMainActor() async throws {
        let feed = Self.syntheticFeed(warnings: 260, points: 200)
        #expect(feed.count >= 9_115_185)
        let eccc = try Fixtures.data("alerts-eccc-toronto-point.json")
        let nowS = Self.nowS
        let (warnings, canada) = await Task.detached {
            (WxMeteoAlarm.parse(feed, status: 200, nowS: nowS), WxECCCAlerts.parse(eccc, status: 200, nowS: nowS))
        }.value
        let parsed = try #require(warnings)
        // Every fourth warning is green.
        #expect(parsed.count == 195)
        #expect(parsed.allSatisfy { $0.alert.event.hasPrefix("en ") && $0.areas.first?.polygons.first?.count == 200 })
        #expect(parsed.first?.alert.id == "meteoAlarm:synthetic.0" && parsed.last?.alert.id == "meteoAlarm:synthetic.258")
        #expect(canada?.alerts.count == 1)
    }

    /// `warnings` warnings in de, fr, it, en and rm, each area a closed ring of `points` points.
    static func syntheticFeed(warnings: Int, points: Int) -> Data {
        var out = #"{"warnings":["#
        for w in 0..<warnings {
            var ring: [String] = []
            for k in 0..<(points - 1) {
                let angle = Double(k) / Double(points - 1) * 2 * Double.pi
                ring.append("\(46.5 + 0.2 * sin(angle) + Double(w) * 1e-9),\(8.2 + 0.3 * cos(angle) + Double(k) * 1e-12)")
            }
            ring.append(ring[0])
            let polygon = ring.joined(separator: " ")
            let level = w % 4 == 3 ? "1; green; Minor" : "2; yellow; Moderate"
            let infos = ["de", "fr", "it", "en", "rm"].map { lang in
                #"{"language":"\#(lang)","event":"\#(lang) warning \#(w)","headline":"\#(lang) wind \#(w)","#
                    + #""onset":"2026-10-26T06:00:00+01:00","expires":"2026-10-27T00:00:00+01:00","#
                    + #""parameter":[{"valueName":"awareness_level","value":"\#(level)"}],"#
                    + #""area":[{"areaDesc":"Area \#(w)","polygon":["\#(polygon)"]}]}"#
            }
            out += (w == 0 ? "" : ",") + #"{"uuid":"\#(w)","alert":{"identifier":"synthetic.\#(w)","#
                + #""sender":"synthetic@example.invalid","sent":"2026-10-26T06:00:00+01:00","status":"Actual","#
                + #""msgType":"Alert","scope":"Public","info":["# + infos.joined(separator: ",") + "]}}"
        }
        return Data((out + "]}").utf8)
    }
}
