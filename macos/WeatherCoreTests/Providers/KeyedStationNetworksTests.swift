// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// KeyedStationNetworksTests.swift - the parsers of the networks that need the
// user's key (KeyedStationNetworks.swift). Without keys, the fixtures come from
// published material: Met Office responses captured from the live API by a
// third-party client (verbatim); KNMI values from the live 10-minute files of
// 2026-10-25 21:00Z and 21:10Z put in the EDR API's documented CoverageJSON
// shape; AEMET's documented envelope, its live "expired" answer and real
// records (in its ISO-8859-15 encoding); Météo-France's documented station-list
// rows (plus rows built for two of the reporting stations) and real 6-minute
// reports; Frost's documented formats. The expected values
// were computed from the same data independently.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct KeyedStationNetworksTests {
    static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    static func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tol
    }

    // MARK: - KNMI

    @Test func knmiCoverageNearAmsterdam() throws {
        let stations = WxStationNetworks.parseKNMILocations(try Self.fixture("stations-knmi-locations.json"))
        #expect(stations.count == 4)
        #expect(stations["0-20000-0-06240"]?.name == "Schiphol Airport")
        let obs = WxStationNetworks.parseKNMICoverage(try Self.fixture("stations-knmi-cube.json"), stations: stations)
        #expect(obs.count == 3)  // Assendelft measures no temperature
        #expect(!obs.contains { $0.id == "0-528-0-06233" })
        let schiphol = try #require(obs.first { $0.id == "0-20000-0-06240" })
        #expect(schiphol.network == .knmi && schiphol.name == "Schiphol Airport")
        #expect(schiphol.obsTimeS == 1_792_962_600)  // 21:10Z, the newest of the two times
        #expect(schiphol.tempC == 12.3 && schiphol.humidityPct == 55 && schiphol.dewpC == 3.5)
        #expect(Self.near(schiphol.windKmh, 11.88 * 3.6) && Self.near(schiphol.gustKmh, 16.25 * 3.6))
        #expect(schiphol.cloudPct == 87.5)  // 7 okta
        #expect(schiphol.elevM == -3.87 && schiphol.lat == 52.3172 && schiphol.lon == 4.7897)
        #expect(schiphol.reportsPresentWeather && schiphol.condition == nil)  // wawa 1: no weather
        #expect(schiphol.cloudIsCeilometerLimited)
        let deBilt = try #require(obs.first { $0.id == "0-20000-0-06260" })
        #expect(deBilt.condition == .showers)  // wawa 81
        #expect(deBilt.precipMmH == 0.534 && deBilt.cloudPct == 100)
        // without the station list: the position comes from the coverage, no name
        let bare = WxStationNetworks.parseKNMICoverage(try Self.fixture("stations-knmi-cube.json"), stations: [:])
        let voorschoten = try #require(bare.first { $0.id == "0-20000-0-06215" })
        #expect(voorschoten.name == nil && voorschoten.lat == 52.1397 && voorschoten.tempC == 12.0)
        #expect(WxStationNetworks.parseKNMICoverage(Data("{}".utf8), stations: [:]).isEmpty)
    }

    @Test func knmiRequest() {
        let url = WxStationNetworks.knmiCubeURL(box: (minLat: 52.0, minLon: 4.4, maxLat: 52.7, maxLon: 5.3),
                                                nowS: 1_792_962_600 + 250)
        #expect(url.hasPrefix(
            "https://api.dataplatform.knmi.nl/edr/v1/collections/10-minute-in-situ-meteorological-observations/cube?"))
        #expect(url.contains("bbox=4.400,52.000,5.300,52.700"))
        #expect(url.contains("datetime=2026-10-25T20:10:00Z/2026-10-25T21:20:00Z"))
        #expect(url.contains("parameter-name=ta,t10,rh,rh10,td,td10,ff,gff,fx,rg,n,nc,ww"))
    }

    // MARK: - Met Office

    @Test func metOfficeNearestAndStation() throws {
        let nearest = WxStationNetworks.parseMetOfficeNearest(try Self.fixture("stations-metoffice-nearest.json"))
        #expect(nearest.map(\.geohash) == ["gcpvj0"] && nearest.first?.area == "Greater London")
        let london = try #require(WxStationNetworks.decodeGeohash("gcpvj0"))
        #expect(Self.near(london.lat, 51.50665283203125) && Self.near(london.lon, -0.1263427734375))
        #expect(WxStationNetworks.decodeGeohash("gcpvjb") != nil && WxStationNetworks.decodeGeohash("gcpvja") == nil)
        let exeter = try #require(WxStationNetworks.parseMetOfficeStation(
            try Self.fixture("stations-metoffice-station.json"), geohash: "gcj8ds", area: "Devon"))
        #expect(exeter.network == .metOffice && exeter.id == "gcj8ds" && exeter.name == "Devon")
        #expect(exeter.obsTimeS == 1_785_614_400)  // the newest of 48 hours, 2026-08-01T20:00Z
        #expect(exeter.tempC == 16.83 && exeter.humidityPct == 55)
        #expect(Self.near(exeter.windKmh, 2.7 * 3.6) && Self.near(exeter.gustKmh, 6.3 * 3.6))
        #expect(exeter.condition == nil && exeter.cloudPct == 5 && exeter.reportsPresentWeather)  // 0: clear night
        #expect(Self.near(exeter.lat, 50.73760986328125) && Self.near(exeter.lon, -3.4002685546875))
        #expect(exeter.elevM == nil && exeter.dewpC == nil)  // the DEM fills the elevation
        #expect(WxStationNetworks.parseMetOfficeStation(Data("[]".utf8), geohash: "gcj8ds", area: nil) == nil)
    }

    @Test func metOfficeWeatherCodes() {
        #expect(WxStationNetworks.metOfficeWeather(8) == (nil, 100))
        #expect(WxStationNetworks.metOfficeWeather(3) == (nil, 45))
        #expect(WxStationNetworks.metOfficeWeather(6).condition == .fog)
        #expect(WxStationNetworks.metOfficeWeather(5) == (nil, nil))  // mist
        #expect(WxStationNetworks.metOfficeWeather(10).condition == .showers)
        #expect(WxStationNetworks.metOfficeWeather(15).condition == .heavyRain)
        #expect(WxStationNetworks.metOfficeWeather(20).condition == .sleet)  // hail shower
        #expect(WxStationNetworks.metOfficeWeather(24).condition == .snow)
        #expect(WxStationNetworks.metOfficeWeather(30).condition == .thunderstorm)
        #expect(WxStationNetworks.metOfficeNearestURL(lat: 51.5074, lon: -0.1278)
            == "https://data.hub.api.metoffice.gov.uk/observation-land/1/nearest?lat=51.51&lon=-0.13&max=5")
    }

    // MARK: - AEMET

    @Test func aemetTwoSteps() throws {
        #expect(WxStationNetworks.parseAEMETEnvelope(try Self.fixture("stations-aemet-envelope.json"))
            == .data(url: "https://opendata.aemet.es/opendata/sh/0d469581"))
        #expect(WxStationNetworks.parseAEMETEnvelope(Data()) == .refused(status: 401, message: nil))  // no key
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"descripcion" : "API key invalido", "estado" : 401}"#.utf8))
            == .refused(status: 401, message: "API key invalido"))
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"descripcion": "Too Many Requests", "estado": 429}"#.utf8))
            == .refused(status: 429, message: "Too Many Requests"))
        #expect(WxStationNetworks.parseAEMETEnvelope(Data(#"{"descripcion": " No hay datos", "estado": 404}"#.utf8))
            == .noData)
        // a data URL elsewhere is not followed
        #expect(WxStationNetworks.parseAEMETEnvelope(
            Data(#"{"estado": 200, "datos": "https://example.com/x", "descripcion": "exito"}"#.utf8))
            == .refused(status: 0, message: "exito"))
        #expect(WxStationNetworks.aemetDataExpired(try Self.fixture("stations-aemet-expired.json")))
        #expect(!WxStationNetworks.aemetDataExpired(try Self.fixture("stations-aemet-todas.json")))
    }

    @Test func aemetRecords() throws {
        let obs = WxStationNetworks.parseAEMET(try Self.fixture("stations-aemet-todas.json"))
        #expect(obs.count == 7)  // 8 records of 7 stations
        let retiro = try #require(obs.first { $0.id == "3195" })
        #expect(retiro.network == .aemet && retiro.name == "MADRID RETIRO" && retiro.elevM == 667)
        #expect(retiro.obsTimeS == 1_787_655_600 && retiro.tempC == 23.6 && retiro.dewpC == 12.8)
        #expect(retiro.humidityPct == 51 && Self.near(retiro.windKmh, 3.8 * 3.6) && Self.near(retiro.gustKmh, 9.0 * 3.6))
        #expect(retiro.precipMmH == 0)
        // the newest of a station's hours, wherever it is in the list
        let fuente = try #require(obs.first { $0.id == "2517A" })
        #expect(fuente.obsTimeS == 1_747_098_000 && fuente.tempC == 8.8 && fuente.humidityPct == 95)
        // ISO-8859-15 names, doubled spaces, missing values
        #expect(obs.first { $0.id == "3194Y" }?.name == "POZUELO DE ALARCON (AUTOMÁTICA)")
        #expect(obs.first { $0.id == "3194Y" }?.windKmh == nil)
        #expect(obs.first { $0.id == "3194U" }?.name == "MADRID C. UNIVERSITARIA")
        #expect(WxStationNetworks.parseISO8601("2025-05-13T10:00:00+0000") == 1_747_130_400)
        #expect(WxStationNetworks.parseAEMET(Data("[]".utf8)).isEmpty)
    }

    // MARK: - Météo-France

    @Test func meteoFranceSlot() throws {
        let stations = WxStationNetworks.parseMeteoFranceStations(try Self.fixture("stations-meteofrance-list.csv"))
        #expect(stations.count == 6)
        #expect(stations["75114001"]?.name == "PARIS-MONTSOURIS" && stations["75114001"]?.elevM == 75)
        #expect(stations["01014002"]?.lat == 46.278167)  // the leading zero is kept
        #expect(stations["97401520"]?.kind == "ETENDU")
        let obs = WxStationNetworks.parseMeteoFrance(try Self.fixture("stations-meteofrance-6m.json"), stations: stations)
        #expect(obs.count == 4)
        let aigoual = try #require(obs.first { $0.id == "30339001" })
        #expect(aigoual.network == .meteoFrance && aigoual.name == "MONT AIGOUAL" && aigoual.elevM == 1567)
        #expect(Self.near(aigoual.tempC, 10.2) && Self.near(aigoual.dewpC, 10.2) && aigoual.humidityPct == 100)
        #expect(Self.near(aigoual.windKmh, 14.1 * 3.6) && Self.near(aigoual.gustKmh, 20.2 * 3.6))
        #expect(aigoual.trust == 1 && aigoual.windTrust == 1)
        let tevelave = try #require(obs.first { $0.id == "97401520" })  // temperature and rain only
        #expect(Self.near(tevelave.tempC, 19.9) && tevelave.dewpC == nil && tevelave.windKmh == nil)
        #expect(tevelave.obsTimeS == 1_792_646_280 && tevelave.precipMmH == 0)
        #expect(tevelave.trust == 0.85 && tevelave.windTrust == 0.6)  // extended network
        let gillot = try #require(obs.first { $0.id == "97418110" })
        #expect(Self.near(gillot.tempC, 27.9) && Self.near(gillot.dewpC, 20.5) && gillot.humidityPct == 64)
        // the newest slot at least 10 minutes old, minutes a multiple of 6
        #expect(WxStationNetworks.meteoFranceSlotS(nowS: 1_792_647_080) == 1_792_646_280)
        #expect(WxStationNetworks.meteoFranceSlotURL(slotS: 1_792_646_280).hasSuffix(
            "/DPPaquetObs/v2/paquet/stations/infrahoraire-6m?date=2026-10-22T05:18:00Z&format=json"))
    }

    // MARK: - Frost

    @Test func frostSourcesAndObservations() throws {
        let sites = WxStationNetworks.parseFrostSources(try Self.fixture("stations-frost-sources.json"))
        #expect(sites.map(\.id) == ["SN18700", "SN18815"])  // a source without a position is skipped
        #expect(sites.first?.lat == 59.9423 && sites.first?.lon == 10.72 && sites.first?.elevM == 94)
        #expect(sites.last?.elevM == 77 && sites.last?.kind == "STATENS VEGVESEN")
        let byID = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        let obs = WxStationNetworks.parseFrostObservations(try Self.fixture("stations-frost-obs.json"), sites: byID)
        #expect(obs.count == 2)  // SN99999 is not a listed site
        let blindern = try #require(obs.first { $0.id == "SN18700" })
        #expect(blindern.tempC == 0.4)  // 2 m, not 10 m; not the parallel sensor's 9.9
        #expect(blindern.obsTimeS == 1_740_554_220 && blindern.humidityPct == 88 && blindern.dewpC == -1.2)
        #expect(Self.near(blindern.windKmh, 2.4 * 3.6))
        #expect(Self.near(blindern.gustKmh, 4.1 * 3.6))  // the 10-minute gust is newer than the hourly one
        #expect(Self.near(blindern.precipMmH, 0.2 * 6))
        #expect(blindern.trust == 1 && blindern.windTrust == 1)
        let bryn = try #require(obs.first { $0.id == "SN18815" })
        #expect(bryn.tempC == 1.6 && bryn.windKmh == nil && bryn.humidityPct == nil)  // erroneous / impossible
        #expect(bryn.trust == 0.7 && bryn.windTrust == 0.4)
        #expect(WxStationNetworks.frostAuthorization(clientID: "abc") == "Basic YWJjOg==")
        #expect(WxStationNetworks.frostSourcesURL(lat: 59.9423, lon: 10.72).contains("nearest(POINT(10.7200%2059.9423))"))
        let url = WxStationNetworks.frostObservationsURL(stationIDs: ["SN18700", "SN18815"])
        #expect(url.contains("sources=SN18700,SN18815&referencetime=latest&maxage=PT3H"))
        #expect(url.contains("max(wind_speed_of_gust%20PT10M)") && !url.contains(" "))
    }

    // MARK: - Keys, credits, coverage

    @Test func keyExpiryAndInfo() {
        #expect(WxStationKeyInfo.expiry(ofKey: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiAieCIsICJleHAiOiAxODAwMDAwMDAwfQ.sig")
            == 1_800_000_000)
        #expect(WxStationKeyInfo.expiry(ofKey: "eyJvcmciOiI1ZTU1NGUxOTI3NGE5NjAwMDEyYTNlYjEifQ") == nil)  // not a JWT
        #expect(WxStationKeyInfo.expiry(ofKey: "a.b.c") == nil)
        for network in WxStationNetwork.allCases {
            #expect((network.keyInfo != nil) == network.requiresKey)
            if let info = network.keyInfo {
                #expect(info.signUpURL.hasPrefix("https://") && info.steps.count >= 3 && !info.limits.isEmpty)
            }
            #expect(!network.displayName.isEmpty && !network.coverageText.isEmpty && !network.detailText.isEmpty)
        }
    }

    @Test func datedCreditsAndCoverage() {
        let credits = WxStationNetworks.credits(
            for: [.aemet, .meteoFrance, .knmi], newestReportS: [.aemet: 1_787_655_600, .meteoFrance: 1_792_646_280])
        #expect(credits.map(\.text) == [
            "Source: KNMI", "Source: Météo-France, data of 22 Oct 05:18 UTC", "Source: AEMET, data of 25 Aug 11:00 UTC",
            WxStationNetworks.ccByNote.text,
        ])
        #expect(WxStationNetworks.credits(for: [.metOffice]).map(\.text) == ["Powered by Met Office data"])
        #expect(WxStationNetworks.covers(.metOffice, lat: 51.51, lon: -0.13))
        #expect(WxStationNetworks.covers(.knmi, lat: 52.37, lon: 4.90))
        #expect(WxStationNetworks.covers(.frost, lat: 59.91, lon: 10.75))
        #expect(WxStationNetworks.covers(.meteoFrance, lat: 48.86, lon: 2.35))
        #expect(WxStationNetworks.covers(.aemet, lat: 40.42, lon: -3.70))
        #expect(WxStationNetworks.covers(.aemet, lat: 28.12, lon: -15.43))  // Canary Islands
        #expect(!WxStationNetworks.covers(.aemet, lat: 48.86, lon: 2.35))
        #expect(!WxStationNetworks.covers(.metOffice, lat: 48.86, lon: 2.35))
    }
}
