// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationCatalogTests.swift - the persistent station catalog: reachability
// (the silence clock that only runs while the app checks), health from the
// tested track record, stuck sensors, fallback reports and DEM elevations.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct StationCatalogTests {
    /// 2026-01-15T00:00Z: night at (45N, 0E); 2026-07-15T12:00Z: day there.
    static let nightS: Int64 = 1_768_435_200
    static let dayS: Int64 = 1_784_116_800
    static let box = (minLat: 44.0, minLon: -1.0, maxLat: 46.0, maxLon: 1.0)

    static func obs(
        _ id: String, _ network: WxStationNetwork = .iemMesonet, t: Int64, temp: Double = 10,
        lat: Double = 45.0, lon: Double = 0.0, elev: Double? = nil
    ) -> WxStationObservation {
        WxStationObservation(network: network, id: id, name: "Site \(id)", lat: lat, lon: lon, elevM: elev,
                             obsTimeS: t, tempC: temp)
    }

    static func coverage(_ network: WxStationNetwork = .iemMesonet) -> WxStationCoverage {
        WxStationCoverage(network: network, box: box)
    }

    @Test func fetchCreatesAndUpdatesRecords() throws {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("A", t: t0), Self.obs("B", t: t0, lat: 45.1)], coverage: Self.coverage(), nowS: t0)
        #expect(c.records.count == 2)
        let a = try #require(c.records["iemMesonet:A"])
        #expect(a.firstSeenS == t0 && a.lastReportS == t0 && a.silentS == 0 && a.tests == 0)
        #expect(a.lastObservation?.tempC == 10)
        // A reports again, B is silent: B's clock runs by the time between checks
        c.recordFetch([Self.obs("A", t: t0 + 600, temp: 11)], coverage: Self.coverage(), nowS: t0 + 600)
        #expect(c.records["iemMesonet:A"]?.lastReportS == t0 + 600)
        #expect(c.records["iemMesonet:A"]?.lastObservation?.tempC == 11)
        #expect(c.records["iemMesonet:B"]?.silentS == 600)
        // A station outside the fetched box, or of another network, is not expected
        c.recordFetch([Self.obs("FAR", t: t0, lat: 50)], coverage: WxStationCoverage(network: .iemMesonet), nowS: t0)
        c.recordFetch([], coverage: Self.coverage(), nowS: t0 + 1200)
        #expect(c.records["iemMesonet:FAR"]?.silentS == 0)
        c.recordFetch([], coverage: Self.coverage(.dmi), nowS: t0 + 1800)
        #expect(c.records["iemMesonet:A"]?.silentS == 600)
    }

    @Test func silenceOnlyRunsWhileTheAppChecks() throws {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("A", t: t0)], coverage: Self.coverage(), nowS: t0)
        // a week with the app closed, then one check: at most one hour of silence
        c.recordFetch([], coverage: Self.coverage(), nowS: t0 + 7 * 86_400)
        #expect(c.records["iemMesonet:A"]?.silentS == WxStationCatalog.maxSilenceStepS)
        // 3 days of hourly checks without a report: dropped
        var t = t0 + 7 * 86_400
        for _ in 0..<71 {
            t += 3600
            c.recordFetch([], coverage: Self.coverage(), nowS: t)
        }
        #expect(c.records["iemMesonet:A"] == nil)
    }

    @Test func aReportResetsTheSilence() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("A", t: t0)], coverage: Self.coverage(), nowS: t0)
        var t = t0
        for _ in 0..<60 {
            t += 3600
            c.recordFetch([], coverage: Self.coverage(), nowS: t)
        }
        #expect(c.records["iemMesonet:A"]?.silentS == Int64(60 * 3600))
        c.recordFetch([Self.obs("A", t: t)], coverage: Self.coverage(), nowS: t)
        #expect(c.records["iemMesonet:A"]?.silentS == 0)
        // the same old report again is no news
        c.recordFetch([Self.obs("A", t: t)], coverage: Self.coverage(), nowS: t + 600)
        #expect(c.records["iemMesonet:A"]?.silentS == 600)
    }

    @Test func areaTagsAndRequestedIDs() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("A", t: t0)], coverage: WxStationCoverage(network: .iemMesonet, areaTag: "iem:TSA"), nowS: t0)
        c.recordFetch([Self.obs("B", t: t0)], coverage: WxStationCoverage(network: .iemMesonet, areaTag: "iem:OUN"), nowS: t0)
        c.recordFetch([], coverage: WxStationCoverage(network: .iemMesonet, areaTag: "iem:TSA"), nowS: t0 + 600)
        #expect(c.records["iemMesonet:A"]?.silentS == 600)
        #expect(c.records["iemMesonet:B"]?.silentS == 0)  // another office's area was not fetched
        c.recordFetch([Self.obs("X", .geosphere, t: t0), Self.obs("Y", .geosphere, t: t0, lat: 45.2)],
                      coverage: WxStationCoverage(network: .geosphere, stationIDs: ["X", "Y"]), nowS: t0)
        c.recordFetch([], coverage: WxStationCoverage(network: .geosphere, stationIDs: ["X"]), nowS: t0 + 600)
        #expect(c.records["geosphere:X"]?.silentS == 600)
        #expect(c.records["geosphere:Y"]?.silentS == 0)
    }

    @Test func healthFollowsTheTrackRecord() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("GOOD", t: t0), Self.obs("BAD", t: t0, lat: 45.1)], coverage: Self.coverage(), nowS: t0)
        #expect(c.health("iemMesonet:GOOD", nowS: t0) == 0.6)  // probation
        #expect(c.health("unknown:key", nowS: t0) == 1.0)
        var t = t0
        for i in 0..<12 {
            t = t0 + Int64(i) * 600
            c.recordTests(["iemMesonet:GOOD": i % 2 == 0 ? 0.6 : -0.6, "iemMesonet:BAD": 4.5], nowS: t)
        }
        #expect(c.records["iemMesonet:GOOD"]?.tests == 12)
        #expect(c.health("iemMesonet:GOOD", nowS: t) == 1.0)
        let bad = c.health("iemMesonet:BAD", nowS: t)
        #expect(bad > 0 && bad < 0.25)  // a 4.5 °C bias: 1 / (1 + 2^2)
        // a gross error excludes the station
        for i in 0..<30 {
            c.recordTests(["iemMesonet:BAD": 12], nowS: t + Int64(i + 1) * 600)
        }
        #expect(c.health("iemMesonet:BAD", nowS: t + 31 * 600) == 0)
        // at most one test per interval
        let before = c.records["iemMesonet:GOOD"]?.tests
        c.recordTests(["iemMesonet:GOOD": 0], nowS: t + 60)
        #expect(c.records["iemMesonet:GOOD"]?.tests == before)
    }

    @Test func sunExposedSensorIsJudgedByDayAndNight() {
        var c = WxStationCatalog()
        c.recordFetch([Self.obs("SUN", t: Self.nightS)], coverage: Self.coverage(), nowS: Self.nightS)
        for i in 0..<10 {
            c.recordTests(["iemMesonet:SUN": 0.2], nowS: Self.nightS + Int64(i) * 600)  // fine at night
        }
        for i in 0..<10 {
            c.recordTests(["iemMesonet:SUN": 4.0], nowS: Self.dayS + Int64(i) * 600)  // warm in the sun
        }
        #expect(c.health("iemMesonet:SUN", nowS: Self.nightS + 7200) > 0.6)
        #expect(c.health("iemMesonet:SUN", nowS: Self.dayS + 7200) < 0.3)
    }

    @Test func stuckSensorIsExcluded() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        for i in 0...9 {  // the same 12.3 °C every hour for 9 hours
            let t = t0 + Int64(i) * 3600
            c.recordFetch([Self.obs("STUCK", t: t, temp: 12.3), Self.obs("KXYZ", .metar, t: t, temp: 12)],
                          coverage: Self.coverage(), nowS: t)
            c.recordFetch([Self.obs("KXYZ", .metar, t: t, temp: 12)], coverage: Self.coverage(.metar), nowS: t)
        }
        #expect(c.health("iemMesonet:STUCK", nowS: t0 + 9 * 3600) == 0)
        #expect(c.health("metar:KXYZ", nowS: t0 + 9 * 3600) > 0)  // whole-degree METARs are often steady
        c.recordFetch([Self.obs("STUCK", t: t0 + 10 * 3600, temp: 11.9)], coverage: Self.coverage(), nowS: t0 + 10 * 3600)
        #expect(c.health("iemMesonet:STUCK", nowS: t0 + 10 * 3600) > 0)  // it moved again
    }

    @Test func fallbackElevationAndEnrichment() throws {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("A", t: t0), Self.obs("B", t: t0 - 7200, lat: 45.1, elev: 120)],
                      coverage: Self.coverage(), nowS: t0)
        // the network cannot be reached: its reports of the last 90 minutes
        let cached = c.cachedObservations(network: .iemMesonet, box: Self.box, nowS: t0 + 1800)
        #expect(cached.map(\.id) == ["A"])
        #expect(c.cachedObservations(network: .dmi, box: Self.box, nowS: t0).isEmpty)
        // DEM elevation for the station whose network gives none
        let fresh = [Self.obs("A", t: t0 + 600), Self.obs("B", t: t0 + 600, lat: 45.1)]
        #expect(c.keysMissingElevation(fresh) == ["iemMesonet:A"])
        c.setDEMElevation(85, key: "iemMesonet:A")
        c.setDEMElevation(999, key: "iemMesonet:B")  // the network's own elevation wins
        let enriched = c.enrich(fresh)
        #expect(enriched[0].elevM == 85)
        #expect(enriched[1].elevM == 120)
        #expect(c.keysMissingElevation(fresh).isEmpty)
    }

    @Test func assessmentExplainsTheWeight() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        c.recordFetch([Self.obs("GOOD", t: t0), Self.obs("BAD", t: t0, lat: 45.1), Self.obs("NEW", t: t0, lat: 45.2)],
                      coverage: Self.coverage(), nowS: t0)
        #expect(c.assessment("iemMesonet:NEW", nowS: t0) == .init(health: 0.6, state: .probation, errorC: nil, biasC: nil))
        #expect(c.assessment("nope:X", nowS: t0).state == .unknown)
        var t = t0
        for i in 0..<12 {
            t = t0 + Int64(i) * 600
            c.recordTests(["iemMesonet:GOOD": 0.3, "iemMesonet:BAD": 4.5], nowS: t)
        }
        let good = c.assessment("iemMesonet:GOOD", nowS: t)
        #expect(good.state == .good && good.health == 1.0 && abs((good.biasC ?? 0) - 0.3) < 1e-9)
        let bad = c.assessment("iemMesonet:BAD", nowS: t)
        #expect(bad.state == .reduced && bad.health == c.health("iemMesonet:BAD", nowS: t))
        #expect(abs((bad.errorC ?? 0) - 4.5) < 1e-6)
        for i in 0..<30 {
            c.recordTests(["iemMesonet:BAD": 12], nowS: t + Int64(i + 1) * 600)
        }
        #expect(c.assessment("iemMesonet:BAD", nowS: t + 31 * 600).state == .excluded)
        // nearest first, within the radius only
        let near = c.nearby(lat: 45.0, lon: 0.0, radiusKm: 15, nowS: t)
        #expect(near.map(\.record.id) == ["GOOD", "BAD"])
        #expect(near.first?.distanceKm == 0)
        c.removeAll()
        #expect(c.records.isEmpty)
    }

    @Test func stuckStationIsExplained() {
        var c = WxStationCatalog()
        let t0 = Self.nightS
        for i in 0...9 {
            let t = t0 + Int64(i) * 3600
            c.recordFetch([Self.obs("STUCK", t: t, temp: 12.3)], coverage: Self.coverage(), nowS: t)
        }
        #expect(c.assessment("iemMesonet:STUCK", nowS: t0 + 9 * 3600).state == .stuck)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try TemporaryDirectory("station-catalog")
        let path = WxStationCatalog.defaultPath(configDirectory: dir.appending("config").path)
        #expect(path.hasSuffix("/config/weather/stations.json"))
        var c = WxStationCatalog()
        c.recordFetch([Self.obs("A", .dmi, t: Self.nightS, elev: 5)], coverage: Self.coverage(.dmi), nowS: Self.nightS)
        c.recordTests(["dmi:A": 0.4], nowS: Self.nightS)
        c.save(path: path)
        #expect(WxStationCatalog.load(path: path) == c)
        #expect(WxStationCatalog.load(path: dir.appending("missing.json").path).records.isEmpty)
    }
}
