// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxAlertTests.swift - the alert model, the coverage result and the one
// severity scale against real answers (Fixtures/alerts, captured on
// 2026-10-26 between 14:29 and 15:33 UTC): NWS Alaska and a Kansas point,
// Bright Sky Berlin and all of Germany, MET Norway all of Norway; the
// expected values were read from the same files independently.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct WxAlertTests {
    /// The NWS capture time (the collection's `updated`).
    static let nowS: Int64 = 1_793_025_010

    /// A recorded fixture with each `edits` pair replaced; every original must occur.
    static func edited(_ name: String, _ edits: [(String, String)]) throws -> Data {
        var s = try Fixtures.string(name)
        for (old, new) in edits {
            try #require(s.contains(old), "\(old) not in \(name)")
            s = s.replacingOccurrences(of: old, with: new)
        }
        return Data(s.utf8)
    }

    @Test func modelFieldsAndCoverage() throws {
        let ak = try Fixtures.data("alerts-nws-area-ak-trim3.json")
        let coverage = try #require(WxPointAlerts.parseNWS(ak, status: 200, nowS: Self.nowS))
        #expect(coverage.alerts.count == 3)
        let a = try #require(coverage.alerts.first {
            $0.id == "nws:urn:oid:2.49.0.1.840.0.4832ad168def4e4e0bcb3afb952a187d4c9f31d0.003.1"
        })
        #expect(a.source == .nws && a.event == "High Surf Advisory")
        #expect(a.headline == "High Surf Advisory issued October 26 at 2:58AM AKDT until October 28 at 4:00AM AKDT"
            + " by NWS Fairbanks AK")
        #expect(a.description.hasPrefix("* WHAT...Large breaking waves between 2 and 4 feet above the\nnormal high"))
        #expect(a.instruction == "Precautions should be taken to protect property.")
        #expect(a.level == .minor && a.issuerSeverity == "Minor")
        // Onset 02:58 AKDT; the message expires 22:00 AKDT, the event ends 28 Oct 04:00 AKDT.
        #expect(a.onsetS == 1_793_012_280 && a.expiresS == 1_793_080_800 && a.endsS == 1_793_188_800)
        #expect(a.untilS == a.endsS)
        #expect(a.web == "http://www.weather.gov")
        // The same message keeps its id; the three zones' messages are distinct.
        #expect(WxPointAlerts.parseNWS(ak, status: 200, nowS: Self.nowS + 3600) == coverage)
        #expect(Set(coverage.alerts.map(\.id)).count == 3)

        // Bright Sky: English texts, the DWD link, no event end.
        let de = try #require(WxPointAlerts.parseBrightSky(try Fixtures.data("alerts-brightsky-all-trim2.json"),
                                                            status: 200, nowS: Self.nowS))
        let gust = try #require(de.alerts.first { $0.id == "dwd:3045641" })
        #expect(gust.source == .dwd && gust.event == "gale-force gusts" && gust.headline == "Official WARNING of GALE-FORCE GUSTS")
        #expect(gust.description.hasPrefix("There is a risk of gale-force gusts (level 2 of 4)."))
        #expect(gust.instruction.hasPrefix("Hazard(s) caused by: single branches falling;"))
        #expect(gust.level == .orange && gust.issuerSeverity == "moderate")
        #expect(gust.onsetS == 1_792_972_800 && gust.expiresS == 1_793_034_000 && gust.endsS == nil)
        #expect(gust.web == WxPointAlerts.dwdWarningsURL)

        // Covered with alerts, covered without, not covered: three different answers.
        let empty = WxPointAlerts.parseNWS(try Fixtures.data("alerts-nws-point-empty.json"), status: 200, nowS: Self.nowS)
        let outside = WxPointAlerts.parseNWS(try Fixtures.data("alerts-nws-point-out-of-bounds-400.json"),
                                             status: 400, nowS: Self.nowS)
        #expect(empty == .noAlerts && outside == .notCovered)
        #expect(empty?.alerts == [] && outside?.alerts == [])
        if case .alerts(let list) = coverage {
            #expect(!list.isEmpty)
        } else {
            Issue.record("the Alaska answer is not covered-with-alerts: \(coverage)")
        }
        #expect(WxAlertCoverage.covered([], nowS: Self.nowS) == .noAlerts)
        #expect(WxAlertCoverage.covered([a], nowS: a.expiresS ?? 0) == .noAlerts)

        // Which point source covers a country; MET Norway's empty answer cannot say.
        #expect(WxAlert.pointSource(countryCode: "US") == .nws && WxAlert.pointSource(countryCode: "pr") == .nws)
        #expect(WxAlert.pointSource(countryCode: "GU") == .nws && WxAlert.pointSource(countryCode: "UM") == .nws)
        #expect(WxAlert.pointSource(countryCode: "DE") == .dwd && WxAlert.pointSource(countryCode: "NO") == .metNorway)
        #expect(WxAlert.pointSource(countryCode: "SJ") == nil && WxAlert.pointSource(countryCode: "FR") == nil)
        #expect(WxAlert.pointSource(countryCode: "CA") == nil && WxAlert.pointSource(countryCode: "MX") == nil)
    }

    /// CARTOGRAPHY.md §3: the issuer's colour or level wins; CAP severity only for NWS.
    @Test func severityScaleMapsEachSource() throws {
        // NWS (CAP severity).
        #expect(WxAlert.level(nwsSeverity: "Extreme") == .red && WxAlert.level(nwsSeverity: "Severe") == .orange)
        #expect(WxAlert.level(nwsSeverity: "Moderate") == .yellow && WxAlert.level(nwsSeverity: "Minor") == .minor)
        #expect(WxAlert.level(nwsSeverity: "Unknown") == .unknown && WxAlert.level(nwsSeverity: nil) == .unknown)
        // DWD via Bright Sky (DWD levels 1-4).
        #expect(WxAlert.level(dwdSeverity: "extreme") == .red && WxAlert.level(dwdSeverity: "severe") == .red)
        #expect(WxAlert.level(dwdSeverity: "moderate") == .orange && WxAlert.level(dwdSeverity: "minor") == .yellow)
        #expect(WxAlert.level(dwdSeverity: nil) == .unknown)
        // MET Norway and MeteoAlarm awareness levels: the colour wins over the CAP name.
        #expect(WxAlert.level(awareness: "4; red; Extreme") == .red)
        #expect(WxAlert.level(awareness: "3; orange; Severe") == .orange)
        #expect(WxAlert.level(awareness: "3; Orange; Moderate") == .orange)
        #expect(WxAlert.level(awareness: "2; yellow; Moderate") == .yellow)
        #expect(WxAlert.level(awareness: "1; green; Minor") == nil && WxAlert.level(awareness: "1") == nil)
        #expect(WxAlert.level(awareness: "4") == .red && WxAlert.level(awareness: "3") == .orange)
        #expect(WxAlert.level(awareness: nil) == .unknown && WxAlert.level(awareness: "x; purple; y") == .unknown)
        // ECCC risk colours; an uncoloured statement is minor.
        #expect(WxAlert.level(ecccColour: "red") == .red && WxAlert.level(ecccColour: "orange") == .orange)
        #expect(WxAlert.level(ecccColour: "yellow") == .yellow && WxAlert.level(ecccColour: nil) == .minor)
        #expect(WxAlert.level(ecccColour: "") == .minor && WxAlert.level(ecccColour: "blue") == .unknown)
        // The order the sidebar takes the highest of.
        #expect(WxAlert.Level.allCases.sorted() == [.unknown, .minor, .yellow, .orange, .red])

        // The parsers apply it to what each issuer published.
        let nws = try #require(WxPointAlerts.parseNWS(try Fixtures.data("alerts-nws-area-ak-trim3.json"),
                                                      status: 200, nowS: Self.nowS))
        #expect(nws.alerts.map(\.level) == [.minor, .minor, .minor])
        let severe = try Self.edited("alerts-nws-area-ak-trim3.json", [(#""severity": "Minor""#, #""severity": "Extreme""#)])
        #expect(WxPointAlerts.parseNWS(severe, status: 200, nowS: Self.nowS)?.alerts.map(\.level) == [.red, .red, .red])
        let dwd = try #require(WxPointAlerts.parseBrightSky(try Fixtures.data("alerts-brightsky-all-trim2.json"),
                                                            status: 200, nowS: Self.nowS))
        #expect(dwd.alerts.map(\.level) == [.orange, .orange])
        let met = try #require(WxPointAlerts.parseMETNorway(try Fixtures.data("alerts-metno-current-en-trim2.json"),
                                                            status: 200, nowS: Self.nowS))
        #expect(met.alerts.map(\.level) == [.yellow, .yellow])
        #expect(met.alerts.map(\.issuerSeverity) == ["2; yellow; Moderate", "2; yellow; Moderate"])
        // A green MET Norway level is no warning.
        let green = try Self.edited("alerts-metno-current-en-trim2.json",
                                    [(#""2; yellow; Moderate""#, #""1; green; Minor""#)])
        #expect(WxPointAlerts.parseMETNorway(green, status: 200, nowS: Self.nowS) == .noAlerts)
    }

    @Test func testMessagesDropped() throws {
        #expect(WxAlert.isActual(status: "Actual") && WxAlert.isActual(status: "actual"))
        for s in ["Test", "test", "Exercise", "System", "Draft", ""] {
            #expect(!WxAlert.isActual(status: s), "\(s)")
        }
        #expect(!WxAlert.isActual(status: nil))
        // NWS test and exercise messages, and cancellations.
        for status in ["Test", "Exercise"] {
            let d = try Self.edited("alerts-nws-area-ak-trim3.json", [(#""status": "Actual""#, "\"status\": \"\(status)\"")])
            #expect(WxPointAlerts.parseNWS(d, status: 200, nowS: Self.nowS) == .noAlerts)
        }
        let cancel = try Self.edited("alerts-nws-area-ak-trim3.json", [(#""messageType": "Update""#, #""messageType": "Cancel""#)])
        #expect(WxPointAlerts.parseNWS(cancel, status: 200, nowS: Self.nowS) == .noAlerts)
        // Bright Sky status test.
        let dwd = try Self.edited("alerts-brightsky-all-trim2.json", [(#""status": "actual""#, #""status": "test""#)])
        #expect(WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: Self.nowS) == .noAlerts)
        // MET Norway status Test.
        let met = try Self.edited("alerts-metno-current-en-trim2.json", [(#""status": "Actual""#, #""status": "Test""#)])
        #expect(WxPointAlerts.parseMETNorway(met, status: 200, nowS: Self.nowS) == .noAlerts)
    }

    /// The builders and parsers are nonisolated: a detached task calls them synchronously.
    @Test func parsersRunOffMainActor() async throws {
        let nws = try Fixtures.data("alerts-nws-area-ak-trim3.json")
        let dwd = try Fixtures.data("alerts-brightsky-all-trim2.json")
        let met = try Fixtures.data("alerts-metno-current-en-trim2.json")
        let nowS = Self.nowS
        let (urls, counts) = await Task.detached {
            ([WxPointAlerts.nwsURL(lat: 64.5, lon: -165.4), WxPointAlerts.brightSkyURL(lat: 52.52, lon: 13.4),
              WxPointAlerts.metNorwayURL(lat: 62, lon: 5.1)],
             [WxPointAlerts.parseNWS(nws, status: 200, nowS: nowS)?.alerts.count,
              WxPointAlerts.parseBrightSky(dwd, status: 200, nowS: nowS)?.alerts.count,
              WxPointAlerts.parseMETNorway(met, status: 200, nowS: nowS)?.alerts.count,
              WxAlertCoverage.covered([], nowS: nowS).alerts.count])
        }.value
        #expect(urls.count == 3 && urls.allSatisfy { $0.hasPrefix("https://") })
        #expect(counts == [3, 2, 2, 0])
    }
}
