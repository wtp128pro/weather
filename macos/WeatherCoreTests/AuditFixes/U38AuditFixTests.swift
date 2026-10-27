// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U38AuditFixTests.swift - regression tests for the audit fixes in the station
// pool: the same-site merge (excluded and stale twins, moisture), METAR present
// weather, the keyed parsers (out-of-range codes, stale Frost elements), the
// NWS text decoder, the coverage boxes and the stuck-sensor rule.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct U38AuditFixTests {
    /// 2026-01-15T00:00Z: night at (45N, 0E).
    static let nowS: Int64 = 1_768_435_200
    static let lat = 45.0
    static let lon = 0.0

    /// A point `km` from (lat, lon) along `bearingDeg` (flat-earth offset; fine below 100 km).
    static func offset(_ km: Double, _ bearingDeg: Double) -> (lat: Double, lon: Double) {
        let b = bearingDeg * .pi / 180.0
        return (lat + km * cos(b) / 111.2, lon + km * sin(b) / (111.2 * cos(lat * .pi / 180.0)))
    }

    static func obs(
        _ network: WxStationNetwork, _ id: String, at p: (lat: Double, lon: Double), tempC: Double, ageS: Int64,
        humidityPct: Double? = nil, dewpC: Double? = nil, windKmh: Double? = nil, cloudPct: Double? = nil,
        wx: String? = nil, trust: Double = 1.0
    ) -> WxStationObservation {
        WxStationObservation(
            network: network, id: id, name: id, lat: p.lat, lon: p.lon, obsTimeS: nowS - ageS, tempC: tempC,
            dewpC: dewpC, humidityPct: humidityPct, windKmh: windKmh, cloudPct: cloudPct, wxString: wx,
            trust: trust)
    }

    static func blend(
        _ o: [WxStationObservation], at p: (lat: Double, lon: Double) = (lat, lon),
        health: (String) -> Double = { _ in 1.0 }
    ) -> WxStationBlend? {
        WxStationFusion.blend(o, lat: p.lat, lon: p.lon, targetElevationM: nil, upperCloudPct: nil, nowS: nowS,
                              health: health)
    }

    /// `p` moved `km` north.
    static func north(_ p: (lat: Double, lon: Double), _ km: Double) -> (lat: Double, lon: Double) {
        (p.lat + km / 111.2, p.lon)
    }

    // MARK: - U11-F1: an excluded report must not take its healthy twin with it

    @Test func excludedReportDoesNotHideItsHealthyTwin() throws {
        // a stuck road sensor (health 0, 2 min old) 1 km from a healthy METAR (30 min old)
        let road = Self.obs(.iemMesonet, "ROAD", at: Self.offset(2, 0), tempC: 25, ageS: 120)
        let apt = Self.obs(.metar, "KAPT", at: Self.north(Self.offset(2, 0), 1), tempC: 15, ageS: 1800)
        let far = Self.obs(.metar, "KFAR", at: Self.offset(40, 180), tempC: 18, ageS: 600)
        let sick: (String) -> Double = { $0 == "iemMesonet:ROAD" ? 0 : 1 }
        // was nil: the METAR was merged into the sick site and dropped with it
        let b = try #require(Self.blend([road, apt], health: sick))
        #expect(b.stationID == "KAPT" && abs(b.tempC - 15) < 1e-9)
        // was 18.00 from KFAR alone
        let b2 = try #require(Self.blend([road, apt, far], health: sick))
        #expect(b2.stationID == "KAPT" && b2.stationCount == 2 && abs(b2.tempC - 15.04) < 0.005)
        // the excluded sensor is still tested (so it can recover), and so is the METAR beside it
        let n2 = Self.obs(.metar, "KN2", at: Self.offset(10, 90), tempC: 15, ageS: 600)
        let n3 = Self.obs(.metar, "KN3", at: Self.offset(10, 270), tempC: 15, ageS: 600)
        let residuals = WxStationFusion.crossValidate([road, apt, far, n2, n3], nowS: Self.nowS, health: sick)
        #expect(residuals["iemMesonet:ROAD"].map { abs($0 - 10) < 1e-9 } == true)
        #expect(residuals["metar:KAPT"] != nil)  // was never tested while its twin was sick
    }

    @Test func excludedOlderTwinNeitherFillsNorVouches() throws {
        // the same rule seen from the other side: the health-0 report is the OLDER twin (30 min)
        let swobP = Self.offset(3, 0)
        let swob = Self.obs(.ecccSWOB, "SWOB", at: swobP, tempC: 5, ageS: 120)
        let sickMet = Self.obs(.metar, "CYXX", at: Self.north(swobP, 0.445), tempC: 6, ageS: 1800, windKmh: 25,
                               cloudPct: 75, wx: "-RA")
        let sick: (String) -> Double = { $0 == "metar:CYXX" ? 0 : 1 }
        // was wind 25, cloud 75, showers with 1.0 mm/h from the excluded METAR; now the SWOB alone
        let b = Self.blend([swob, sickMet], health: sick)
        #expect(b != nil && b == Self.blend([swob], health: sick))
        #expect(b?.windKmh == nil && b?.cloudPct == nil && b?.precipMmH == nil && b?.condition == nil)
        // nor does it lend its trust to a low-trust road sensor: 10.49 °C before, 11.36 °C now, the
        // same as without it
        let road = Self.obs(.iemMesonet, "ROAD", at: swobP, tempC: 10, ageS: 120, trust: 0.3)
        let met = Self.obs(.metar, "CYXX", at: Self.north(swobP, 0.445), tempC: 12, ageS: 1800)
        let far = Self.obs(.metar, "CYFA", at: Self.offset(20, 180), tempC: 16, ageS: 600)
        let without = try #require(Self.blend([road, far], health: sick))
        let excluded = try #require(Self.blend([road, met, far], health: sick))
        #expect(abs(excluded.tempC - 11.36) < 0.005)
        #expect(abs(excluded.tempC - without.tempC) < 1e-9)
    }

    // MARK: - U11-F2: a stale twin lends neither weather, values nor trust

    @Test func staleTwinLendsNoPresentWeather() {
        // a fresh SWOB (no weather coding) beside a METAR "+RA" with wind 30
        let swobP = Self.offset(3, 0)
        let swob = Self.obs(.ecccSWOB, "SWOB", at: swobP, tempC: 5, ageS: 120)
        func metar(_ ageMin: Int64) -> WxStationObservation {
            Self.obs(.metar, "CYXX", at: Self.north(swobP, 0.45), tempC: 6, ageS: ageMin * 60, windKmh: 30, wx: "+RA")
        }
        // 160 min: the METAR alone gives no condition, so the merged site must not either
        // (was heavyRain with an inferred 8.5 mm/h); the wind fill is unchanged
        let b160 = Self.blend([swob, metar(160)])
        #expect(Self.blend([metar(160)])?.condition == nil)
        #expect(b160?.condition == nil && b160?.precipMmH == nil && b160?.windKmh.map { abs($0 - 30) < 1e-9 } == true)
        // 80 min: still current, as for the METAR alone
        let b80 = Self.blend([swob, metar(80)])
        #expect(b80?.condition == .heavyRain && b80?.precipMmH == 8.5)
    }

    @Test func reportOlderThanMaxAgeFillsNothing() {
        // the METAR alone (4 h old) is ignored; merged, it lent wind 30 and cloud 75 to the SWOB
        let swobP = Self.offset(3, 0)
        let swob = Self.obs(.ecccSWOB, "SWOB", at: swobP, tempC: 5, ageS: 120)
        let old = Self.obs(.metar, "CYXX", at: Self.north(swobP, 0.45), tempC: 6, ageS: 4 * 3600,
                           windKmh: 30, cloudPct: 75, wx: "")
        #expect(Self.blend([old]) == nil)
        let b = Self.blend([swob, old])
        #expect(b?.windKmh == nil && b?.cloudPct == nil && b?.condition == nil)
        #expect(b == Self.blend([swob]))
    }

    @Test func twinWithinMaxAgeStillFillsWindCloudAndPrecipitation() throws {
        // unchanged (no fill cutoff below maxAgeS): a METAR 100 or 170 min old still lends its wind,
        // cloud and precipitation to a fresh SWOB beside it; only its present weather is too old
        let swobP = Self.offset(3, 0)
        let swob = Self.obs(.ecccSWOB, "SWOB", at: swobP, tempC: 5, ageS: 120)
        for ageMin: Int64 in [100, 170] {
            var met = Self.obs(.metar, "CYXX", at: Self.north(swobP, 0.45), tempC: 6, ageS: ageMin * 60, windKmh: 30,
                               cloudPct: 75, wx: "")
            met.precipMmH = 0.5
            let b = try #require(Self.blend([swob, met]), "age \(ageMin)")
            #expect(b.windKmh == 30 && b.cloudPct == 75 && b.precipMmH == 0.5, "age \(ageMin)")
        }
    }

    @Test func staleTwinLendsNoTrustToTheBlend() throws {
        // expected change (StationFusion maxAgeS applied literally): a low-trust road sensor no longer
        // takes the trust of a co-located METAR older than 3 h: 10.49 °C before, 11.36 °C now, the same
        // as without the stale report
        let roadP = Self.offset(3, 0)
        let road = Self.obs(.iemMesonet, "ROAD", at: roadP, tempC: 10, ageS: 120, trust: 0.3)
        let far = Self.obs(.metar, "CYFA", at: Self.offset(20, 180), tempC: 16, ageS: 600)
        func metar(_ ageMin: Int64) -> WxStationObservation {
            Self.obs(.metar, "CYXX", at: Self.north(roadP, 0.445), tempC: 12, ageS: ageMin * 60)
        }
        let without = try #require(Self.blend([road, far]))
        let stale = try #require(Self.blend([road, metar(185), far]))
        #expect(abs(stale.tempC - 11.36) < 0.005)
        #expect(abs(stale.tempC - without.tempC) < 1e-9)
        // within 3 h the twin still vouches for the site: unchanged at 10.49 °C
        let current = try #require(Self.blend([road, metar(170), far]))
        #expect(abs(current.tempC - 10.49) < 0.005)
    }

    @Test func staleTwinLendsNoTrustToCrossValidation() {
        // a low-trust road sensor shares a site with a 120-min METAR (older than
        // crossValidationMaxAgeS): the METAR's trust made the road sensor a strong neighbour and
        // shifted N1-N3's residuals (N1 2.52 instead of 0.88)
        let roadP = Self.offset(2, 0)
        let road = Self.obs(.iemMesonet, "ROAD", at: roadP, tempC: 10, ageS: 120, trust: 0.3)
        let met = Self.obs(.metar, "KAPT", at: Self.north(roadP, 0.445), tempC: 12, ageS: 7200)
        let ns = [Self.obs(.iemMesonet, "N1", at: Self.offset(8, 60), tempC: 14, ageS: 300),
                  Self.obs(.iemMesonet, "N2", at: Self.offset(8, 180), tempC: 14.5, ageS: 300),
                  Self.obs(.iemMesonet, "N3", at: Self.offset(8, 300), tempC: 13.5, ageS: 300)]
        let with = WxStationFusion.crossValidate([road, met] + ns, nowS: Self.nowS)
        let without = WxStationFusion.crossValidate([road] + ns, nowS: Self.nowS)
        #expect(with.count == 4)
        #expect(with == without)
    }

    // MARK: - U11-F9: a twin's humidity belongs to its own temperature

    @Test func twinHumidityIsFilledAsItsOwnDewpoint() throws {
        // a fresh 20 °C report without moisture beside a 60-min-old 14 °C / RH 60 % report
        let fresh = Self.obs(.iemMesonet, "ROAD", at: Self.offset(3, 0), tempC: 20, ageS: 120)
        let twinP = Self.north(Self.offset(3, 0), 0.445)
        let td = try #require(WxStationFusion.dewpointC(tempC: 14, humidityPct: 60))
        let rh = Self.obs(.metOffice, "gcj8ds", at: twinP, tempC: 14, ageS: 3600, humidityPct: 60)
        let dew = Self.obs(.metOffice, "gcj8ds", at: twinP, tempC: 14, ageS: 3600, dewpC: td)
        // was 60 %: the RH was converted with the fresh report's 20 °C
        let expected = WxStationFusion.relativeHumidity(tempC: 20, dewpC: td)
        let viaRH = try #require(Self.blend([fresh, rh])?.humidityPct)
        let viaTd = try #require(Self.blend([fresh, dew])?.humidityPct)
        #expect(abs(viaRH - expected) < 1e-6 && abs(viaRH - 41.03) < 0.01)
        #expect(abs(viaRH - viaTd) < 1e-6)
    }

    // MARK: - U11-F5: METAR groups that are not precipitation at the station

    @Test func metarVicinityAndLiftedGroupsAreNotPrecipitation() {
        func decode(_ wx: String) -> WxCondition? {
            WxStationFusion.parseMETARPresentWeather(wx, tempC: -10, wetBulbC: -11, cloudPct: 20)
        }
        // were snow, snow, showers, fog
        #expect(decode("BLSN") == nil)
        #expect(decode("DRSN") == nil)
        #expect(decode("VCSH") == nil)
        #expect(decode("VCFG") == nil)
        #expect(decode("+BLSN") == nil)
        // unchanged: snow falling with the blowing snow, thunder in the vicinity, showers, fog
        #expect(decode("BLSN -SN") == .snow)
        #expect(decode("VCTS") == .thunderstorm)
        #expect(decode("SHRA") == .showers)
        #expect(decode("BR VCSH") == nil)
        #expect(decode("FG") == .fog)
        // a lone prairie METAR "BLSN": no snow and no inferred 3 mm/h
        let blsn = Self.obs(.metar, "KPRA", at: Self.offset(5, 0), tempC: -10, ageS: 600, dewpC: -14, cloudPct: 0,
                            wx: "BLSN")
        let b = Self.blend([blsn])
        #expect(b?.condition != .snow && b?.precipMmH == nil)
    }

    // MARK: - U11-F3: out-of-range codes from the keyed networks

    @Test func outOfRangeCodesAreAbsentNotATrap() throws {
        // each of these trapped in Int(Double) and took the app down
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": 1e19}"#.utf8)) == .refused(status: 0, message: nil))
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": "9.3e18"}"#.utf8))
                == .refused(status: 0, message: nil))
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": 404.0}"#.utf8)) == .noData)
        let metOffice = #"[{"datetime":"2026-07-30T21:00:00Z","temperature":16.9,"weather_code":-1e19}]"#
        let m = try #require(WxStationNetworks.parseMetOfficeStation(Data(metOffice.utf8), geohash: "gcj8ds", area: nil))
        #expect(m.condition == nil && m.cloudPct == nil && !m.reportsPresentWeather)
        let knmi = """
            {"type":"CoverageCollection","coverages":[{"eumetnet:locationId":"0-20000-0-06260",
             "domain":{"axes":{"x":{"values":[5.18]},"y":{"values":[52.1]},"t":{"values":["2026-01-15T00:00:00Z"]}}},
             "ranges":{"ta":{"values":[5.0]},"ww":{"values":[1e19]}}}]}
            """
        let k = WxStationNetworks.parseKNMICoverage(Data(knmi.utf8), stations: [:])
        #expect(k.count == 1 && k.first?.tempC == 5.0)
        #expect(k.first?.condition == nil && k.first?.reportsPresentWeather == false)
    }

    @Test func inRangeFractionalCodesAreStillTruncated() throws {
        // unchanged: an in-range code with a fraction is truncated as Int(Double) did, not refused
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": 404.7}"#.utf8)) == .noData)
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": "404.7"}"#.utf8)) == .noData)
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"estado": 429.9, "descripcion": "x"}"#.utf8))
                == .refused(status: 429, message: "x"))
        // Met Office weather_code 7.9: code 7, cloudy (80 %)
        let metOffice = #"[{"datetime":"2026-07-30T21:00:00Z","temperature":16.9,"weather_code":7.9}]"#
        let m = try #require(WxStationNetworks.parseMetOfficeStation(Data(metOffice.utf8), geohash: "gcj8ds", area: nil))
        #expect(m.cloudPct == 80 && m.condition == nil && m.reportsPresentWeather)
        // KNMI ww 61.5: wawa 61, light rain
        let knmi = """
            {"type":"CoverageCollection","coverages":[{"eumetnet:locationId":"0-20000-0-06260",
             "domain":{"axes":{"x":{"values":[5.18]},"y":{"values":[52.1]},"t":{"values":["2026-01-15T00:00:00Z"]}}},
             "ranges":{"ta":{"values":[5.0]},"ww":{"values":[61.5]}}}]}
            """
        let k = WxStationNetworks.parseKNMICoverage(Data(knmi.utf8), stations: [:])
        #expect(k.first?.condition == .lightRain && k.first?.reportsPresentWeather == true)
    }

    // MARK: - U11-F7: Frost elements that stopped reporting

    /// A Frost answer: a 2-min-old temperature and wind/gust/RH/hourly precipitation `lagMin` older.
    static func frost(lagMin: Int64) -> Data {
        let iso = ISO8601DateFormatter()
        let tTemp = iso.string(from: Date(timeIntervalSince1970: TimeInterval(nowS - 120)))
        let tOther = iso.string(from: Date(timeIntervalSince1970: TimeInterval(nowS - 120 - lagMin * 60)))
        return Data("""
            {"data":[{"sourceId":"SN18700:0","referenceTime":"\(tTemp)","observations":[
                {"elementId":"air_temperature","value":5.0,"level":{"value":2}}]},
              {"sourceId":"SN18700:0","referenceTime":"\(tOther)","observations":[
                {"elementId":"wind_speed","value":15.0,"level":{"value":10}},
                {"elementId":"max(wind_speed_of_gust PT1H)","value":20.0},
                {"elementId":"relative_humidity","value":80},
                {"elementId":"sum(precipitation_amount PT1H)","value":1.0}]}]}
            """.utf8)
    }

    @Test func frostElementsFarOlderThanTheTemperatureAreDropped() throws {
        let site = WxStationSite(id: "SN18700", name: "Blindern", lat: 59.94, lon: 10.72, elevM: 94, kind: "MET.NO")
        func parse(_ lag: Int64) throws -> WxStationObservation {
            try #require(WxStationNetworks.parseFrostObservations(Self.frost(lagMin: lag), sites: ["SN18700": site]).first)
        }
        // the hourly cadence is kept, up to 90 min behind the temperature
        for lag: Int64 in [50, 90] {
            let o = try parse(lag)
            #expect(o.windKmh == 54 && o.gustKmh == 72 && o.humidityPct == 80 && o.precipMmH == 1.0, "lag \(lag)")
        }
        // an anemometer and gauge silent for hours: were wind 54, gust 72, RH 80, precip 1.0 dated as
        // current; with a single source they are now absent
        for lag: Int64 in [91, 170] {
            let o = try parse(lag)
            #expect(o.windKmh == nil && o.gustKmh == nil && o.humidityPct == nil && o.precipMmH == nil, "lag \(lag)")
        }
        // the visible effect: with a fresh wind 15 km away the stale 54 km/h no longer dominates (was 47.67)
        let stale = try parse(170)
        let fresh = Self.obs(.metar, "ENFR", at: (59.94 - 15 / 111.2, 10.72), tempC: 5, ageS: 600, windKmh: 10)
        let b = try #require(Self.blend([stale, fresh], at: (59.94, 10.72)))
        #expect(b.windKmh.map { abs($0 - 10) < 0.01 } == true)
    }

    // MARK: - U12-F1: freezing fog is fog

    @Test func freezingFogIsFogNotSleet() {
        func decode(_ text: String, wetBulbC: Double = -3) -> WxCondition? {
            var cloud: Double? = nil
            return WxPresentWeather.condition(text: text, tempC: -2, wetBulbC: wetBulbC, cloudPct: &cloud)
        }
        // were sleet, sleet, sleet
        #expect(decode("Freezing Fog") == .fog)
        #expect(decode("Patches of Freezing Fog") == .fog)
        #expect(decode("Snow and Freezing Fog") == .snow)
        // freezing precipitation stays sleet
        #expect(decode("Light Freezing Rain") == .sleet)
        #expect(decode("Light Freezing Drizzle") == .sleet)
        #expect(decode("Light Freezing Rain and Snow") == .sleet)
        #expect(decode("Ice Pellets") == .sleet)
    }

    // MARK: - U12-F2: "Partly Sunny" is partly cloudy

    @Test func partlySunnyIsPartlyCloudy() {
        // the texts of a live NWS hourly forecast (BOU/63,62), decoded as the hourly-sky fetch does
        // (tempC 20, wet bulb 15, no cloud yet); only "Partly Sunny" changes (was clear, 5 %)
        let cases: [(String, WxCondition, Double?)] = [
            ("Partly Sunny", .partlyCloudy, 48), ("Sunny", .clear, 5), ("Mostly Sunny", .mostlyClear, 22),
            ("Partly Cloudy", .partlyCloudy, 48), ("Mostly Clear", .mostlyClear, 22), ("Clear", .clear, 5),
            ("Mostly Cloudy", .mostlyCloudy, 76), ("Patchy Fog", .fog, nil),
        ]
        for (text, condition, cloud) in cases {
            var inferred: Double? = nil
            let c = WxPresentWeather.condition(text: text, tempC: 20, wetBulbC: 15, cloudPct: &inferred)
            #expect(c == condition && inferred == cloud, "\(text)")
        }
    }

    // MARK: - U12-F3, U12-F6: coverage boxes

    @Test func metOfficeCoversTheChannelIslands() {
        #expect(WxStationNetworks.covers(.metOffice, lat: 49.186, lon: -2.107))  // St Helier (was outside)
        #expect(WxStationNetworks.covers(.metOffice, lat: 49.455, lon: -2.536))  // St Peter Port
        #expect(WxStationNetworks.covers(.metOffice, lat: 51.507, lon: -0.128))  // London
        // not Normandy or Brittany (DataHub's daily quota)
        #expect(!WxStationNetworks.covers(.metOffice, lat: 49.183, lon: -0.370))  // Caen
        #expect(!WxStationNetworks.covers(.metOffice, lat: 48.117, lon: -1.678))  // Rennes
        #expect(!WxStationNetworks.covers(.metOffice, lat: 48.857, lon: 2.352))  // Paris
    }

    @Test func dmiCoversGreenlandButNotItsNeighbours() {
        let outside: [(String, Double, Double)] = [
            ("Reykjavik", 64.15, -21.94), ("Akureyri", 65.68, -18.09), ("Iqaluit", 63.75, -68.52),
            ("Qikiqtarjuaq", 67.55, -64.03), ("Clyde River", 70.47, -68.59), ("Kangiqsujuaq", 61.60, -71.95),
        ]
        for (name, la, lo) in outside {
            #expect(!WxStationNetworks.covers(.dmi, lat: la, lon: lo), "\(name)")  // were all inside
        }
        let inside: [(String, Double, Double)] = [
            ("Nuuk", 64.18, -51.72), ("Tasiilaq", 65.61, -37.64), ("Prins Christian Sund", 60.05, -43.17),
            ("Kap Dalton", 69.42, -24.10), ("Ittoqqortoormiit", 70.49, -21.97), ("Upernavik", 72.79, -56.15),
            ("Danmarkshavn", 76.77, -18.67), ("Pituffik", 76.53, -68.70), ("Qaanaaq", 77.47, -69.23),
            ("Kap Morris Jesup", 83.65, -33.40), ("Copenhagen", 55.68, 12.57), ("Torshavn", 62.01, -6.77),
        ]
        for (name, la, lo) in inside {
            #expect(WxStationNetworks.covers(.dmi, lat: la, lon: lo), "\(name)")
        }
    }

    // MARK: - U12-F4: api.weather.gov whole-degree reports are not a stuck sensor

    @Test func steadyWholeDegreeNWSReportIsNotStuck() {
        var c = WxStationCatalog()
        let box = (minLat: 44.0, minLon: -1.0, maxLat: 46.0, maxLon: 1.0)
        let t0 = Self.nowS
        for i in 0...9 {  // the same whole 12 °C every hour for 9 hours (a steady overcast night)
            let t = t0 + Int64(i) * 3600
            let asos = WxStationObservation(network: .nwsASOS, id: "KXYZ", lat: 45, lon: 0, obsTimeS: t, tempC: 12)
            let road = WxStationObservation(network: .iemMesonet, id: "ROAD", lat: 45.1, lon: 0, obsTimeS: t, tempC: 12)
            c.recordFetch([asos], coverage: WxStationCoverage(network: .nwsASOS, box: box), nowS: t)
            c.recordFetch([road], coverage: WxStationCoverage(network: .iemMesonet, box: box), nowS: t)
        }
        // was .stuck with health 0, which dropped the whole airport from the blend
        #expect(c.assessment("nwsASOS:KXYZ", nowS: t0 + 9 * 3600).state != .stuck)
        #expect(c.health("nwsASOS:KXYZ", nowS: t0 + 9 * 3600) > 0)
        // a 0.1 °C sensor on the same value is still stuck
        #expect(c.assessment("iemMesonet:ROAD", nowS: t0 + 9 * 3600).state == .stuck)
    }
}
