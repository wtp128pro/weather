// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationNetworksTests.swift - the station-network parsers against real
// responses captured on 2026-10-25 (Fixtures/stations); the expected values
// were read from the same files independently.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct StationNetworksTests {
    static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    static func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tol
    }

    // MARK: - METAR

    @Test func metarAmsterdam() throws {
        let obs = WxStationNetworks.parseMETARs(try Self.fixture("stations-metar.json"))
        #expect(obs.count == 6)
        let eham = try #require(obs.first { $0.id == "EHAM" })
        #expect(eham.network == .metar)
        #expect(eham.tempC == 13)
        #expect(eham.dewpC == 4)
        #expect(Self.near(eham.windKmh, 24 * 1.852))
        #expect(Self.near(eham.gustKmh, 36 * 1.852))
        #expect(Self.near(eham.cloudPct, 44))  // SCT at 4,400 ft
        #expect(eham.obsTimeS == 1_792_958_100)
        #expect(eham.elevM == -2)
        #expect(eham.wxString == "")
        #expect(eham.reportsPresentWeather)  // no weather group: "no weather"
        #expect(eham.cloudIsCeilometerLimited)
        #expect(eham.trust == 1)
        let ehqn = try #require(obs.first { $0.id == "EHQN" })
        #expect(Self.near(ehqn.cloudPct, 100 * (1 - 0.82 * 0.56 * 0.25)))  // FEW + SCT + BKN, random overlap
        let ehle = try #require(obs.first { $0.id == "EHLE" })
        #expect(ehle.cloudPct == 0)  // CLR
        #expect(WxStationNetworks.parseMETARs(Data()).isEmpty)  // AWC answers an empty body for no airports
    }

    @Test func coverLayersAndCodes() {
        #expect(WxStationNetworks.randomOverlapCover([]) == nil)
        #expect(WxStationNetworks.randomOverlapCover([("OVC", 1000)]) == 100)
        #expect(Self.near(WxStationNetworks.randomOverlapCover([("OVC", 25_000)]), 30))  // thin cirrus
        #expect(Self.near(WxStationNetworks.randomOverlapCover([("BKN", 14_000)]), 75 * 0.72))
        #expect(WxStationNetworks.oktasCoverPercent("skc") == 0)
        #expect(WxStationNetworks.oktasCoverPercent("VV") == 100)
    }

    // MARK: - NWS

    @Test func nwsLatestTulsa() throws {
        let site = WxStationObservation(network: .metar, id: "KTUL", name: "Tulsa Intl", lat: 36.1984, lon: -95.8881, tempC: 0)
        let obs = try #require(WxStationNetworks.parseNWSLatest(try Self.fixture("stations-nws-latest.json"), site: site))
        #expect(obs.network == .nwsASOS)
        #expect(obs.id == "KTUL")
        #expect(obs.lat == site.lat && obs.lon == site.lon)
        #expect(obs.obsTimeS == 1_792_956_600)
        #expect(obs.tempC == 26)
        #expect(obs.dewpC == 11)
        #expect(Self.near(obs.humidityPct, 39.058443699936))
        #expect(Self.near(obs.windKmh, 7.416))  // already km/h
        #expect(obs.gustKmh == nil)
        #expect(obs.elevM == 206)
        #expect(obs.condition == .clear)
        #expect(obs.reportsPresentWeather)
    }

    @Test func nwsRejectedValuesAreDropped() throws {
        let body = """
            {"properties": {"timestamp": "2026-10-25T19:30:00+00:00", "textDescription": "",
             "temperature": {"unitCode": "wmoUnit:degC", "value": 26, "qualityControl": "V"},
             "dewpoint": {"unitCode": "wmoUnit:degC", "value": 30, "qualityControl": "X"},
             "windSpeed": {"unitCode": "wmoUnit:m_s-1", "value": 5, "qualityControl": "V"},
             "windGust": {"unitCode": "wmoUnit:m_s-1", "value": 40, "qualityControl": "Q"},
             "precipitationLastHour": {"unitCode": "wmoUnit:m", "value": 0.002, "qualityControl": "C"}}}
            """
        let site = WxStationObservation(network: .metar, id: "KXYZ", lat: 36, lon: -96, tempC: 0)
        let obs = try #require(WxStationNetworks.parseNWSLatest(Data(body.utf8), site: site))
        #expect(obs.dewpC == nil)  // X: rejected by MADIS QC
        #expect(obs.gustKmh == nil)  // Q: questioned
        #expect(Self.near(obs.windKmh, 18))
        #expect(Self.near(obs.precipMmH, 2))
        #expect(!obs.reportsPresentWeather)  // empty text: no weather information
        let rejected = body.replacingOccurrences(of: "\"value\": 26, \"qualityControl\": \"V\"", with: "\"value\": 26, \"qualityControl\": \"B\"")
        #expect(WxStationNetworks.parseNWSLatest(Data(rejected.utf8), site: site) == nil)
    }

    // MARK: - ECCC SWOB

    @Test func swobMontreal() throws {
        let obs = WxStationNetworks.parseSWOB(try Self.fixture("stations-swob.json"))
        #expect(obs.count == 7)  // the newest report of each station
        let wta = try #require(obs.first { $0.id == "WTA" })
        #expect(wta.name == "MCTAVISH")
        #expect(wta.tempC == 16.4)
        #expect(wta.dewpC == 0.7)
        #expect(wta.humidityPct == 34)
        #expect(wta.windKmh == 4.6)
        #expect(wta.gustKmh == 13.6)
        #expect(wta.precipMmH == 0)
        #expect(Self.near(wta.elevM, 72.583))
        #expect(wta.obsTimeS == 1_792_958_640)
        #expect(wta.trust == 1)
        #expect(!wta.reportsPresentWeather)
        let navCanada = try #require(obs.first { $0.name == "Montreal/Mirabel International" })
        #expect(navCanada.trust == 1)
        #expect(navCanada.tempC == 16.8)
    }

    @Test func swobPartnerStationsHaveLowerTrust() throws {
        let body = """
            {"features": [{"geometry": {"coordinates": [-73.55, 45.51, 10.0]}, "properties": {
              "stn_nam-value": "Quai 55", "data_pvdr-value": "POM", "msc_id-value": "pom-quai-55",
              "date_tm-value": "2026-10-25T19:40:00.000Z", "air_temp": 16.8, "rel_hum": 40,
              "avg_wnd_spd_10m_pst10mts": 12.0}}]}
            """
        let obs = try #require(WxStationNetworks.parseSWOB(Data(body.utf8)).first)
        #expect(obs.trust == 0.6)
        #expect(obs.windTrust == 0.35)
        #expect(obs.id == "pom-quai-55")
        #expect(obs.windKmh == 12)  // the 10-minute mean when the 2-minute one is missing
    }

    // MARK: - IEM

    @Test func iemTulsaArea() throws {
        let obs = WxStationNetworks.parseIEM(try Self.fixture("stations-iem.json"))
        #expect(obs.count == 7)  // 2 ASOS skipped (METAR has them), 2 gauges without temperature skipped
        #expect(!obs.contains { $0.id == "RKR" || $0.id == "PTAO2" })
        let gauge = try #require(obs.first { $0.id == "OOLO2" })
        #expect(Self.near(gauge.tempC, (74.77 - 32) * 5 / 9))
        #expect(Self.near(gauge.dewpC, (51.998272 - 32) * 5 / 9))
        #expect(gauge.humidityPct == 45)
        #expect(Self.near(gauge.windKmh, 1.8248501 * 1.852))
        #expect(gauge.precipMmH == 0)
        #expect(gauge.trust == 0.5 && gauge.windTrust == 0.3)
        #expect(gauge.obsTimeS == WxTime.parseISO8601("2026-10-25T19:00:00Z"))
        let road = try #require(obs.first { $0.id == "ARD30" })
        #expect(road.trust == 0.6 && road.windTrust == 0.35)
        #expect(Self.near(road.gustKmh, 10.115767 * 1.852))
        let crn = try #require(WxStationNetworks.iemTrust(network: "USCRN"))
        #expect(crn.temp == 1.0 && crn.wind == 0.8)
        #expect(WxStationNetworks.iemTrust(network: "IA_COOP") == nil)
    }

    // MARK: - DWD (Bright Sky)

    @Test func brightSkyBerlin() throws {
        let nowS: Int64 = 1_792_959_000  // 2026-10-25T20:10Z
        let sources = WxStationNetworks.parseBrightSkySources(try Self.fixture("stations-brightsky-sources.json"), nowS: nowS)
        #expect(sources.count == 1)  // one live SYNOP source; the old Tempelhof records are history
        let tempelhof = try #require(sources.first)
        #expect(tempelhof.id == 303_711)
        #expect(tempelhof.site.id == "10384")
        #expect(tempelhof.site.name == "Berlin-Tempelhof")
        #expect(Self.near(tempelhof.distanceKm, 5.835, 0.01))
        let obs = try #require(WxStationNetworks.parseBrightSkyCurrent(
            try Self.fixture("stations-brightsky-current.json"), source: tempelhof))
        #expect(obs.network == .dwdSYNOP)
        #expect(obs.tempC == 9.8)
        #expect(obs.dewpC == 6.22)
        #expect(obs.humidityPct == 78)
        #expect(obs.windKmh == 16.9)
        #expect(obs.gustKmh == 28.8)
        #expect(obs.cloudPct == 63)
        #expect(obs.precipMmH == 0)
        #expect(obs.obsTimeS == 1_792_958_400)
        #expect(obs.condition == .partlyCloudy)  // "dry": the icon partly-cloudy-night gives the sky
        #expect(obs.reportsPresentWeather)
    }

    @Test func brightSkyFallbackValuesAreNotThisStations() throws {
        let body = """
            {"weather": {"timestamp": "2026-10-25T20:00:00+00:00", "temperature": 9.8, "cloud_cover": 63,
             "wind_speed_10": 16.9, "condition": null,
             "fallback_source_ids": {"cloud_cover": 254907, "wind_speed_10": 254907}}}
            """
        let source = WxStationNetworks.BrightSkySource(
            id: 1, site: WxStationSite(id: "10384", lat: 52.47, lon: 13.40), distanceKm: 5)
        let obs = try #require(WxStationNetworks.parseBrightSkyCurrent(Data(body.utf8), source: source))
        #expect(obs.cloudPct == nil)
        #expect(obs.windKmh == nil)
        #expect(!obs.reportsPresentWeather)
        let noTemp = "{\"weather\": {\"timestamp\": \"2026-10-25T20:00:00+00:00\", \"temperature\": null}}"
        #expect(WxStationNetworks.parseBrightSkyCurrent(Data(noTemp.utf8), source: source) == nil)
    }

    // MARK: - DMI

    @Test func dmiCopenhagen() throws {
        let stations = WxStationNetworks.parseDMIStations(try Self.fixture("stations-dmi-stations.json"))
        #expect(stations["06180"]?.name == "Københavns Lufthavn")
        #expect(stations["06180"]?.kind == "Synop")
        let obs = WxStationNetworks.parseDMIObservations(try Self.fixture("stations-dmi-obs.json"), stations: stations)
        #expect(obs.count == 4)
        let cph = try #require(obs.first { $0.id == "06180" })
        #expect(cph.tempC == 10)
        #expect(cph.dewpC == 8.3)
        #expect(cph.humidityPct == 88.9)
        #expect(Self.near(cph.windKmh, 8.75 * 3.6))
        #expect(Self.near(cph.gustKmh, 11.83 * 3.6))
        #expect(cph.cloudPct == 90)
        #expect(cph.precipMmH == 0)
        #expect(cph.elevM == 5)
        #expect(cph.obsTimeS == 1_792_958_400)
        #expect(!cph.reportsPresentWeather)
        let drogden = try #require(obs.first { $0.id == "06183" })
        #expect(drogden.reportsPresentWeather)  // weather 100: automatic code 00, "no weather"
        #expect(drogden.condition == nil)
    }

    // MARK: - FMI

    @Test func fmiHelsinki() throws {
        let obs = WxStationNetworks.parseFMI(try Self.fixture("stations-fmi.xml"))
        #expect(obs.count == 6)
        let harmaja = try #require(obs.first { $0.id == "100996" })
        #expect(harmaja.name == "Helsinki Harmaja")
        #expect(harmaja.tempC == 12.1)
        #expect(harmaja.dewpC == 9.0)
        #expect(harmaja.humidityPct == 81)
        #expect(Self.near(harmaja.windKmh, 13.5 * 3.6))
        #expect(Self.near(harmaja.gustKmh, 16.6 * 3.6))
        #expect(harmaja.cloudPct == 50)  // 4 oktas
        #expect(harmaja.precipMmH == nil)
        #expect(harmaja.obsTimeS == 1_792_958_400)
        #expect(harmaja.reportsPresentWeather && harmaja.condition == nil)
        let sipoo = try #require(obs.first { $0.id == "105392" })
        #expect(!sipoo.reportsPresentWeather)  // no present-weather sensor
        let kaisaniemi = try #require(obs.first { $0.id == "100971" })
        #expect(kaisaniemi.precipMmH == 0)
    }

    // MARK: - SMHI

    @Test func smhiAllSweden() throws {
        var responses: [Int: Data] = [:]
        for p in WxStationNetworks.smhiParameters {
            responses[p] = try Self.fixture("stations-smhi-\(p).json")
        }
        let obs = WxStationNetworks.parseSMHI(responses)
        #expect(obs.count == 6)
        let abisko = try #require(obs.first { $0.id == "188790" })
        #expect(abisko.tempC == 5.8)
        #expect(abisko.dewpC == 2.4)
        #expect(abisko.humidityPct == 78)
        #expect(Self.near(abisko.windKmh, 4.1 * 3.6))
        #expect(Self.near(abisko.gustKmh, 18.3 * 3.6))
        #expect(abisko.cloudPct == 100)
        #expect(abisko.condition == .showers)  // 181: automatic 81, slight rain showers
        #expect(abisko.elevM == 392.235)
        #expect(abisko.obsTimeS == 1_792_954_800)
        #expect(abisko.trust == 1)
        let alskog = try #require(obs.first { $0.id == "9013" })
        #expect(alskog.trust == 0.9)  // an ADDITIONAL station
        #expect(!alskog.reportsPresentWeather)
        let adelso = try #require(obs.first { $0.id == "97280" })
        #expect(adelso.reportsPresentWeather && adelso.condition == nil)  // 123: rain ended in the past hour
    }

    // MARK: - GeoSphere

    @Test func geosphereVienna() throws {
        let sites = WxStationNetworks.parseGeoSphereStations(try Self.fixture("stations-geosphere-meta.json"))
        #expect(sites.count == 5)
        let byID = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        let obs = WxStationNetworks.parseGeoSphereCurrent(try Self.fixture("stations-geosphere-current.json"), stations: byID)
        #expect(obs.count == 5)
        let enzersdorf = try #require(obs.first { $0.id == "11037" })
        #expect(enzersdorf.name == "GROSSENZERSDORF")
        #expect(enzersdorf.tempC == 8.9)
        #expect(enzersdorf.dewpC == 6.9)
        #expect(enzersdorf.humidityPct == 88)
        #expect(Self.near(enzersdorf.windKmh, 4.3 * 3.6))
        #expect(Self.near(enzersdorf.gustKmh, 8.5 * 3.6))
        #expect(Self.near(enzersdorf.precipMmH, 5.4))  // 0.9 mm in 10 minutes
        #expect(enzersdorf.elevM == 154)
        #expect(enzersdorf.obsTimeS == 1_792_958_400)  // "2026-10-25T20:00+00:00", no seconds
    }

    // MARK: - MeteoSwiss

    @Test func meteoSwissBasel() throws {
        let sites = WxStationNetworks.parseMeteoSwissStations(try Self.fixture("stations-meteoswiss-stations.csv"))
        #expect(sites.count == 5)
        let bas = try #require(sites["BAS"])
        #expect(bas.name == "Basel / Binningen")  // Latin-1 file
        #expect(bas.lat == 47.541142 && bas.lon == 7.583525)
        #expect(bas.elevM == 316)
        #expect(sites["GVE"]?.name == "Genève / Cointrin")
        let obs = try #require(WxStationNetworks.parseMeteoSwissStation(
            try Self.fixture("stations-meteoswiss-bas.csv"), site: bas))
        #expect(obs.obsTimeS == WxTime.parseISO8601("2026-10-25T19:30:00Z"))  // the 19:40 row is still empty
        #expect(obs.tempC == 10.6)
        #expect(obs.humidityPct == 71.6)
        #expect(obs.dewpC == 5.7)
        #expect(obs.windKmh == 16.6)
        #expect(obs.gustKmh == 26.6)
        #expect(obs.precipMmH == 0)
        #expect(obs.trust == 1)
    }

    // MARK: - Shared

    @Test func elevationsAndTimes() {
        #expect(WxStationNetworks.parseElevations(Data("{\"elevation\":[38.0,35.5]}".utf8)) == [38.0, 35.5])
        #expect(WxStationNetworks.parseISO8601("2026-10-25T20:00+00:00") == 1_792_958_400)
        #expect(WxStationNetworks.parseISO8601("2026-10-25T20:00:00Z") == 1_792_958_400)
        #expect(WxStationNetworks.parseISO8601("2026-10-25T20:00:00.000Z") == 1_792_958_400)
        #expect(WxStationNetworks.parseISO8601("garbage") == nil)
        let url = WxStationNetworks.elevationURL([(52.52, 13.405), (48.85, 2.35)])
        #expect(url.hasSuffix("latitude=52.5200,48.8500&longitude=13.4050,2.3500"))
    }

    @Test func presentWeatherCodes() {
        #expect(WxPresentWeather.condition(ww: 0) == nil)
        #expect(WxPresentWeather.condition(ww: 45) == .fog)
        #expect(WxPresentWeather.condition(ww: 61) == .lightRain)
        #expect(WxPresentWeather.condition(ww: 65) == .heavyRain)
        #expect(WxPresentWeather.condition(ww: 73) == .snow)
        #expect(WxPresentWeather.condition(ww: 95) == .thunderstorm)
        #expect(WxPresentWeather.condition(wawa: 0, wetBulbC: 5) == nil)
        #expect(WxPresentWeather.condition(wawa: 41, wetBulbC: 5) == .rain)
        #expect(WxPresentWeather.condition(wawa: 41, wetBulbC: -1) == .snow)  // unknown type: phase by wet bulb
        #expect(WxPresentWeather.condition(wawa: 63, wetBulbC: 5) == .heavyRain)
        #expect(WxPresentWeather.condition(wawa: 92, wetBulbC: 5) == .thunderstorm)
        #expect(WxPresentWeather.condition(nationalCode: 151, wetBulbC: 5) == .drizzle)  // DMI/SMHI 100 + wawa
        #expect(WxPresentWeather.condition(nationalCode: 61, wetBulbC: 5) == .lightRain)  // manned ww
        #expect(WxPresentWeather.condition(nationalCode: 250, wetBulbC: 5) == nil)
    }

    @Test func coverageByCountry() throws {
        #expect(WxStationNetworks.covers(.dmi, lat: 55.68, lon: 12.57))
        #expect(WxStationNetworks.covers(.smhi, lat: 55.60, lon: 13.00))  // Malmö
        #expect(WxStationNetworks.covers(.dmi, lat: 55.60, lon: 13.00))  // ... and Copenhagen's stations nearby
        #expect(WxStationNetworks.covers(.fmi, lat: 60.17, lon: 24.94))
        #expect(WxStationNetworks.covers(.geosphere, lat: 48.21, lon: 16.37))
        #expect(WxStationNetworks.covers(.meteoSwiss, lat: 47.37, lon: 8.54))
        #expect(WxStationNetworks.covers(.dwdSYNOP, lat: 47.56, lon: 7.59))  // Basel: German stations across the Rhine
        #expect(!WxStationNetworks.covers(.dwdSYNOP, lat: 48.86, lon: 2.35))  // Paris
        #expect(WxStationNetworks.covers(.ecccSWOB, lat: 43.65, lon: -79.38, region: .canada))
        #expect(!WxStationNetworks.covers(.ecccSWOB, lat: 41.88, lon: -87.63, region: .us))  // Chicago
        #expect(WxStationNetworks.covers(.ecccSWOB, lat: 48.99, lon: -122.75, region: .us))  // Blaine, WA: BC within 60 km
        #expect(WxStationNetworks.covers(.iemMesonet, lat: 36.15, lon: -95.99, region: .us))
        #expect(!WxStationNetworks.covers(.iemMesonet, lat: 43.65, lon: -79.38, region: .canada))
    }

    @Test func creditsFollowTheNetworksUsed() {
        #expect(WxStationNetworks.credits(for: []).isEmpty)
        // public-domain US networks: their credits only, no CC BY note
        #expect(WxStationNetworks.credits(for: [.iemMesonet, .metar]).map(\.text) == [
            "Source: NOAA Aviation Weather Center", "Source: Iowa Environmental Mesonet, Iowa State University",
        ])
        // Canada: the licence's own statement, linked to the licence
        let canada = WxStationNetworks.credits(for: [.ecccSWOB])
        #expect(canada.first?.text.hasPrefix("Contains information licenced under the Data Server End-use Licence") == true)
        #expect(canada.first?.url == "https://eccc-msc.github.io/open-data/licence/readme_en/")
        // CC BY 4.0 networks: named, then one licence link with the change note
        let swiss = WxStationNetworks.credits(for: [.meteoSwiss, .dwdSYNOP, .metar])
        #expect(swiss.map(\.text) == [
            "Source: NOAA Aviation Weather Center", BrightSkyProvider.attributionText, "Source: MeteoSwiss",
            WxStationNetworks.ccByNote.text,
        ])
        #expect(swiss.last?.url == "https://creativecommons.org/licenses/by/4.0/")
        for network in WxStationNetwork.allCases {
            let c = WxStationNetworks.credit(network)
            #expect(c.url.hasPrefix("https://") && !c.text.isEmpty && c.text.utf8.count <= WxLimits.sourceTextMax)
        }
    }
}
