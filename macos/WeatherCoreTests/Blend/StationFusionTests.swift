// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationFusionTests.swift - the multi-network station pool (StationFusion.swift):
// search-box geometry, same-site merge, elevation reduction, kernel weighting,
// Shepard de-clustering, the MAD buddy check, present weather and cloud fusion.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct StationFusionTests {
    /// 2026-01-15T00:00Z: night at (45N, 0E).
    static let nightS: Int64 = 1_768_435_200
    /// 2026-07-15T12:00Z: day at (45N, 0E).
    static let dayS: Int64 = 1_784_116_800
    static let lat = 45.0
    static let lon = 0.0

    /// A point `km` from (lat, lon) along `bearingDeg` (flat-earth offset; fine below 100 km).
    static func offset(_ km: Double, _ bearingDeg: Double) -> (lat: Double, lon: Double) {
        let b = bearingDeg * .pi / 180.0
        let dLat = km * cos(b) / 111.2
        let dLon = km * sin(b) / (111.2 * cos(lat * .pi / 180.0))
        return (lat + dLat, lon + dLon)
    }

    static func obs(
        _ network: WxStationNetwork = .metar, id: String, km: Double, bearing: Double = 0,
        tempC: Double, ageS: Int64 = 0, nowS: Int64 = nightS, elevM: Double? = nil,
        dewpC: Double? = nil, humidityPct: Double? = nil, windKmh: Double? = nil, gustKmh: Double? = nil,
        windDirDeg: Double? = nil, cloudPct: Double? = nil, precipMmH: Double? = nil, wx: String? = nil, condition: WxCondition? = nil
    ) -> WxStationObservation {
        let p = offset(km, bearing)
        return WxStationObservation(
            network: network, id: id, name: id, lat: p.lat, lon: p.lon, elevM: elevM, obsTimeS: nowS - ageS,
            tempC: tempC, dewpC: dewpC, humidityPct: humidityPct, windKmh: windKmh, gustKmh: gustKmh,
            windDirDeg: windDirDeg, cloudPct: cloudPct, precipMmH: precipMmH, wxString: wx, condition: condition)
    }

    static func blend(
        _ o: [WxStationObservation], elevM: Double? = nil, upper: Double? = nil, nowS: Int64 = nightS
    ) -> WxStationBlend? {
        WxStationFusion.blend(o, lat: lat, lon: lon, targetElevationM: elevM, upperCloudPct: upper, nowS: nowS)
    }

    // MARK: - Geometry

    @Test func searchBoxCoversRadiusAtAllLatitudes() {
        for lat in [0.0, 30.0, 45.0, 52.0, 60.0, 70.0] {
            let box = WxStationFusion.searchBox(lat: lat, lon: 10.0, radiusKm: 95.0)
            let north = WxGeo.distanceKm(aLat: lat, aLon: 10.0, bLat: box.maxLat, bLon: 10.0)
            let east = WxGeo.distanceKm(aLat: lat, aLon: 10.0, bLat: lat, bLon: box.maxLon)
            #expect(north >= 95.0, "lat \(lat)")
            #expect(east >= 95.0, "lat \(lat): east-west reach \(east) km")
            #expect(east < 100.0, "lat \(lat): box not oversized east-west")
        }
        // a square-degree box at 52N would have reached only ~62% as far east-west
        let box = WxStationFusion.searchBox(lat: 52.0, lon: 4.9, radiusKm: 60.0)
        #expect((box.maxLon - 4.9) / (box.maxLat - 52.0) > 1.6)
        let polar = WxStationFusion.searchBox(lat: 89.5, lon: 0, radiusKm: 95.0)
        #expect(polar.maxLat == 89.9)
        #expect(polar.maxLon <= 179.9 && polar.minLon >= -179.9)
    }

    // MARK: - Same-site merge

    @Test func sameSiteReportsMergeFreshestFirst() {
        let metar = Self.obs(.metar, id: "CYYZ", km: 20, tempC: 18.0, ageS: 1500, cloudPct: 75, wx: "-RA")
        var swob = Self.obs(.ecccSWOB, id: "Toronto/Pearson", km: 20.5, tempC: 18.4, ageS: 60, humidityPct: 50)
        swob.lat += 0.002  // ~200 m away: the same airport
        let merged = WxStationFusion.mergeSameSite([metar, swob])
        #expect(merged.count == 1)
        let site = merged[0]
        #expect(site.tempC == 18.4)  // the fresh minute report wins
        #expect(site.humidityPct == 50)
        #expect(site.cloudPct == 75)  // filled from the METAR
        #expect(site.wxString == "-RA")
        #expect(site.cloudIsCeilometerLimited)
        #expect(site.reportsPresentWeather)

        let apart = Self.obs(.ecccSWOB, id: "Far", km: 25, bearing: 90, tempC: 17.0)
        #expect(WxStationFusion.mergeSameSite([metar, apart]).count == 2)
        // reports without a finite temperature or position are dropped
        var bad = metar
        bad.tempC = .nan
        #expect(WxStationFusion.mergeSameSite([bad]).isEmpty)
    }

    // MARK: - Fusion

    @Test func emptyOrOutOfRangeGivesNil() {
        #expect(Self.blend([]) == nil)
        #expect(Self.blend([Self.obs(id: "FAR", km: 120, tempC: 10)]) == nil)
        #expect(Self.blend([Self.obs(id: "OLD", km: 3, tempC: 10, ageS: 4 * 3600)]) == nil)
    }

    @Test func singleStationAtThePlace() throws {
        let b = try #require(Self.blend([Self.obs(id: "KXYZ", km: 0.5, tempC: 12.0, dewpC: 6.0, windKmh: 10)]))
        #expect(abs(b.tempC - 12.0) < 1e-9)
        #expect(b.stationID == "KXYZ")
        #expect(b.stationCount == 1)
        #expect(abs(b.stationDistanceKm - 0.5) < 0.05)
        let rh = WxStationFusion.relativeHumidity(tempC: 12.0, dewpC: 6.0)
        #expect(abs(try #require(b.humidityPct) - rh) < 1e-9)
        #expect(b.windKmh == 10)
    }

    @Test func elevationReductionUsesDayAndNightLapseRates() throws {
        // station 500 m above the place: descending warms by Γ·500 m
        let night = try #require(Self.blend(
            [Self.obs(id: "HILL", km: 1, tempC: 5.0, elevM: 600)], elevM: 100, nowS: Self.nightS))
        #expect(abs(night.tempC - (5.0 + 0.0042 * 500)) < 1e-9)
        let day = try #require(Self.blend(
            [Self.obs(id: "HILL", km: 1, tempC: 5.0, nowS: Self.dayS, elevM: 600)], elevM: 100, nowS: Self.dayS))
        #expect(abs(day.tempC - (5.0 + 0.0068 * 500)) < 1e-9)
    }

    @Test func nearStationDominatesFarStation() throws {
        let b = try #require(Self.blend([
            Self.obs(id: "NEAR", km: 2, tempC: 10.0),
            Self.obs(id: "FAR", km: 40, bearing: 180, tempC: 20.0),
        ]))
        #expect(b.tempC < 10.5)
        #expect(b.stationID == "NEAR")
        #expect(b.stationCount == 2)
        #expect(b.effectiveDistanceKm < 4.0)
    }

    @Test func clusterOnOneBearingDoesNotOutvoteIsolatedStation() throws {
        let b = try #require(Self.blend([
            Self.obs(id: "N1", km: 10, bearing: 355, tempC: 10.0),
            Self.obs(id: "N2", km: 10, bearing: 0, tempC: 10.0),
            Self.obs(id: "N3", km: 10, bearing: 5, tempC: 10.0),
            Self.obs(id: "S", km: 10, bearing: 180, tempC: 14.0),
        ]))
        // a plain kernel average would give 11.0; de-clustering moves toward the even split 12.0
        #expect(b.tempC > 11.6)
        #expect(b.tempC < 12.4)
    }

    @Test func buddyCheckSuppressesBrokenSensor() throws {
        let b = try #require(Self.blend([
            Self.obs(id: "A", km: 5, bearing: 0, tempC: 10.0),
            Self.obs(id: "B", km: 6, bearing: 90, tempC: 10.4),
            Self.obs(id: "C", km: 7, bearing: 180, tempC: 9.7),
            Self.obs(id: "BAD", km: 4, bearing: 270, tempC: 31.0),
        ]))
        #expect(b.tempC < 11.0)
        // within 3 sigma (sigma floor 1.5 °C) nothing is penalized
        let ok = try #require(Self.blend([
            Self.obs(id: "A", km: 5, bearing: 0, tempC: 10.0),
            Self.obs(id: "B", km: 5, bearing: 90, tempC: 11.0),
            Self.obs(id: "C", km: 5, bearing: 180, tempC: 12.0),
            Self.obs(id: "D", km: 5, bearing: 270, tempC: 12.5),
        ]))
        #expect(abs(ok.tempC - 11.375) < 0.05)
    }

    @Test func fresherReportsWeighMore() throws {
        let b = try #require(Self.blend([
            Self.obs(id: "FRESH", km: 5, bearing: 0, tempC: 10.0, ageS: 60),
            Self.obs(id: "STALE", km: 5, bearing: 180, tempC: 14.0, ageS: 3000),
        ]))
        #expect(b.tempC < 12.0)
    }

    @Test func gustIsWindPlusRMSExcess() throws {
        let b = try #require(Self.blend([
            Self.obs(id: "A", km: 1, tempC: 10, windKmh: 20, gustKmh: 40),
        ]))
        #expect(b.windKmh == 20)
        #expect(abs(try #require(b.gustKmh) - 40) < 1e-9)
        let calm = try #require(Self.blend([Self.obs(id: "A", km: 1, tempC: 10, windKmh: 20, gustKmh: 22)]))
        #expect(calm.gustKmh == nil)  // excess below 3.5 km/h is not a gust
    }

    @Test func humidityFromRelativeHumidityOnlyReports() throws {
        let b = try #require(Self.blend([Self.obs(.ecccSWOB, id: "XTO", km: 1, tempC: 17.0, humidityPct: 51)]))
        #expect(abs(try #require(b.humidityPct) - 51.0) < 0.01)
        let td = try #require(WxStationFusion.dewpointC(tempC: 17.0, humidityPct: 51))
        #expect(abs(WxStationFusion.relativeHumidity(tempC: 17.0, dewpC: td) - 51.0) < 1e-6)
        #expect(WxStationFusion.dewpointC(tempC: 17.0, humidityPct: 0) == nil)
    }

    // MARK: - Present weather and sky

    @Test func presentWeatherFromNearestReportingSite() throws {
        // The nearest site is a SWOB station (no present weather): the METAR 10 km away decides.
        let rain = try #require(Self.blend([
            Self.obs(.ecccSWOB, id: "XTO", km: 1, tempC: 12),
            Self.obs(.metar, id: "CYTZ", km: 10, bearing: 180, tempC: 12, cloudPct: 100, wx: "-RA BR"),
        ]))
        #expect(rain.condition == .lightRain)
        #expect(rain.stationID == "XTO")
        #expect(try #require(rain.precipMmH) > 0)  // guessed from the weather class

        // A METAR without weather groups means "no weather": the sky class follows the cloud.
        let dry = try #require(Self.blend([
            Self.obs(.metar, id: "CYTZ", km: 3, tempC: 12, cloudPct: 100, wx: ""),
            Self.obs(.metar, id: "CYYZ", km: 20, bearing: 90, tempC: 12, cloudPct: 100, wx: "RA"),
        ]))
        #expect(dry.condition == .overcast)

        // Beyond 38 km present weather is not used.
        let far = try #require(Self.blend([Self.obs(.metar, id: "FAR", km: 45, tempC: 12, cloudPct: 10, wx: "TSRA")]))
        #expect(far.condition == .clear)

        // A decoded text condition (NWS / DWD) wins over the METAR groups of the same site.
        let text = try #require(Self.blend([
            Self.obs(.nwsASOS, id: "KABC", km: 2, tempC: -3, humidityPct: 90, condition: .snow),
        ]))
        #expect(text.condition == .snow)
    }

    @Test func snowPhaseFollowsWetBulb() throws {
        let warm = try #require(Self.blend([Self.obs(id: "A", km: 1, tempC: 6.0, dewpC: 5.0, cloudPct: 100, wx: "SN")]))
        #expect(warm.condition == .rain)
        let cold = try #require(Self.blend([Self.obs(id: "A", km: 1, tempC: -2.0, dewpC: -4.0, cloudPct: 100, wx: "SN")]))
        #expect(cold.condition == .snow)
    }

    @Test func ceilometerClearReportIsFusedWithCloudAloft() throws {
        let metar = try #require(Self.blend([Self.obs(.metar, id: "KAAA", km: 1, tempC: 10, cloudPct: 0)], upper: 60))
        #expect(abs(try #require(metar.cloudPct) - 60.0) < 1e-9)
        // a DWD SYNOP total cloud already sees all levels
        let synop = try #require(Self.blend([Self.obs(.dwdSYNOP, id: "10384", km: 1, tempC: 10, cloudPct: 0)], upper: 60))
        #expect(synop.cloudPct == 0)
        // a cloudy ceilometer report is kept
        #expect(WxStationFusion.fuseUpperCloud(stationCloudPct: 80, upperCloudPct: 60) == 80)
    }

    // MARK: - Trust, health and testing

    @Test func trustAndHealthWeighTheSites() throws {
        let gauge = Self.obs(.iemMesonet, id: "GAUGE", km: 3, bearing: 0, tempC: 14.0)
        var airport = Self.obs(.metar, id: "KAAA", km: 3, bearing: 180, tempC: 10.0)
        airport.trust = 1.0
        var lowTrust = gauge
        lowTrust.trust = 0.25
        // equal trust: the even split; a low-trust gauge counts a quarter
        #expect(abs(try #require(Self.blend([gauge, airport])).tempC - 12.0) < 1e-9)
        #expect(abs(try #require(Self.blend([lowTrust, airport])).tempC - 10.8) < 1e-9)
        // a site the catalog excludes (health 0) is not used at all
        let excluded = try #require(WxStationFusion.blend(
            [gauge, airport], lat: Self.lat, lon: Self.lon, targetElevationM: nil, upperCloudPct: nil,
            nowS: Self.nightS, health: { $0 == gauge.key ? 0 : 1 }))
        #expect(excluded.tempC == 10.0)
        #expect(excluded.stationCount == 1)
    }

    @Test func poolKeepsTheMostInfluentialSites() throws {
        // twelve low-trust gauges close by must not push a first-class station out of the pool
        var obs: [WxStationObservation] = (0..<14).map { i in
            var o = Self.obs(.iemMesonet, id: "G\(i)", km: 2 + Double(i) * 0.4, bearing: Double(i) * 25, tempC: 12.0)
            o.trust = 0.02
            return o
        }
        obs.append(Self.obs(.metar, id: "KFAR", km: 9, bearing: 200, tempC: 10.0))
        let b = try #require(Self.blend(obs))
        #expect(b.stationCount == WxStationFusion.poolMaxStations)
        #expect(b.tempC < 11.0)  // the airport dominates
    }

    @Test func crossValidationFindsTheBiasedSensor() throws {
        // a ring of sites around the place; one reads 5 °C warm
        var obs = (0..<6).map { i in
            Self.obs(.iemMesonet, id: "S\(i)", km: 8, bearing: Double(i) * 60, tempC: 10.0 + Double(i % 2) * 0.4)
        }
        obs.append(Self.obs(.iemMesonet, id: "HOT", km: 1, bearing: 0, tempC: 15.0))
        let residuals = WxStationFusion.crossValidate(obs, nowS: Self.nightS)
        #expect(residuals.count == 7)
        let hot = try #require(residuals["iemMesonet:HOT"])
        #expect(hot > 4.0 && hot < 5.5)
        for i in 0..<6 {  // the hot neighbour leaks into theirs, but it stands out at least twice as clearly
            #expect(abs(try #require(residuals["iemMesonet:S\(i)"])) < hot / 2, "S\(i)")
        }
        // an excluded neighbour does not condemn the others; it is still tested itself
        let withHealth = WxStationFusion.crossValidate(
            obs, nowS: Self.nightS, health: { $0 == "iemMesonet:HOT" ? 0 : 1 })
        #expect(abs(try #require(withHealth["iemMesonet:S0"])) < 0.5)
        #expect(try #require(withHealth["iemMesonet:HOT"]) > 4.0)
        // isolated or stale sites are not tested
        let lonely = [Self.obs(id: "A", km: 1, tempC: 10), Self.obs(id: "B", km: 70, tempC: 10),
                      Self.obs(id: "C", km: 2, bearing: 90, tempC: 10, ageS: 3 * 3600)]
        #expect(WxStationFusion.crossValidate(lonely, nowS: Self.nightS).isEmpty)
    }

    @Test func mixedNetworksFormOnePool() throws {
        // Canada-like pool: an hourly airport METAR plus minute SWOB sites around the place.
        let b = try #require(Self.blend([
            Self.obs(.metar, id: "CYUL", km: 13, bearing: 250, tempC: 16.8, ageS: 1100, cloudPct: 44, wx: ""),
            Self.obs(.ecccSWOB, id: "WTA", km: 0.9, bearing: 300, tempC: 16.9, ageS: 60),
            Self.obs(.ecccSWOB, id: "Quai M-3", km: 2.0, bearing: 90, tempC: 16.9, ageS: 300),
            Self.obs(.ecccSWOB, id: "Quai 55", km: 7.4, bearing: 60, tempC: 16.8, ageS: 300),
        ]))
        #expect(b.stationCount == 4)
        #expect(b.stationID == "WTA")
        #expect(abs(b.tempC - 16.9) < 0.1)
        #expect(b.effectiveAgeS < 600)
        #expect(b.condition == .partlyCloudy)  // the METAR reported no weather; its sky decides
    }

    // MARK: - Wind direction (speed-weighted circular mean)

    /// Smallest angle between two bearings, degrees in [0, 180].
    static func angDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(d, 360 - d)
    }

    /// Two equally weighted METARs 5 km east and west of the target.
    static func pair(_ a: (Double?, Double?), _ b: (Double?, Double?)) -> WxStationBlend? {
        blend([obs(id: "E", km: 5, bearing: 90, tempC: 10, windKmh: a.0, windDirDeg: a.1),
               obs(id: "W", km: 5, bearing: 270, tempC: 10, windKmh: b.0, windDirDeg: b.1)])
    }

    @Test func directionWrapsAroundNorth() throws {
        // 350° and 10° are both northerlies: the mean is 0°, never the arithmetic 180°
        let d = try #require(Self.pair((20, 350), (20, 10))?.windDirDeg)
        #expect(Self.angDiff(d, 0) < 0.5)
        #expect(d >= 0 && d < 360)
        let d2 = try #require(Self.pair((20, 300), (20, 60))?.windDirDeg)
        #expect(Self.angDiff(d2, 0) < 0.5)
        #expect(Self.angDiff(d2, 180) > 179)
    }

    @Test func directionIsSpeedWeighted() throws {
        // u = 20·sin(-10°) + 10·sin(10°), v = 30·cos(10°): atan2 gives -3.36°, i.e. 356.64°
        let d = try #require(Self.pair((20, 350), (10, 10))?.windDirDeg)
        #expect(abs(d - 356.64) < 0.1)
    }

    @Test func opposingOrSpreadWindsHaveNoDirection() throws {
        let opposing = try #require(Self.pair((15, 90), (15, 270)))
        #expect(opposing.windDirDeg == nil)
        #expect(opposing.windKmh != nil)  // the speed is still fused
        // three equal winds 120° apart cancel as well
        let spread = try #require(Self.blend([
            Self.obs(id: "A", km: 5, bearing: 0, tempC: 10, windKmh: 15, windDirDeg: 0),
            Self.obs(id: "B", km: 5, bearing: 120, tempC: 10, windKmh: 15, windDirDeg: 120),
            Self.obs(id: "C", km: 5, bearing: 240, tempC: 10, windKmh: 15, windDirDeg: 240),
        ]))
        #expect(spread.windDirDeg == nil)
    }

    @Test func calmHasNoDirection() throws {
        #expect(try #require(Self.pair((0, 0), (0, 0))).windDirDeg == nil)
        // a resultant below 1 km/h is calm even when the directions agree
        #expect(try #require(Self.pair((0.6, 90), (0.6, 90))).windDirDeg == nil)
        #expect(try #require(Self.pair((5, 90), (5, 90))).windDirDeg.map { Self.angDiff($0, 90) < 0.5 } == true)
    }

    @Test func mostlyCalmPoolHasNoDirection() throws {
        // calm reports are zero vectors: 3 km/h from 200° among three calm sites is a 0.75 km/h resultant
        let o = try #require(Self.blend([
            Self.obs(id: "A", km: 5, bearing: 0, tempC: 10, windKmh: 3, windDirDeg: 200),
            Self.obs(id: "B", km: 5, bearing: 90, tempC: 10, windKmh: 0),
            Self.obs(id: "C", km: 5, bearing: 180, tempC: 10, windKmh: 0),
            Self.obs(id: "D", km: 5, bearing: 270, tempC: 10, windKmh: 0),
        ]))
        #expect(o.windDirDeg == nil)
        #expect(o.windKmh.map { $0 > 0 && $0 < 1 } == true)  // speed is still fused (about 0.75)
    }

    @Test func directionOnlyFromStationsThatReportOne() throws {
        let none = try #require(Self.pair((15, nil), (25, nil)))
        #expect(none.windDirDeg == nil)
        #expect(none.windKmh != nil)
        // a faster station without direction neither biases nor dilutes the one bearing
        let one = try #require(Self.pair((10, 200), (40, nil)))
        #expect(one.windDirDeg.map { Self.angDiff($0, 200) < 0.01 } == true)
        // a direction without a speed, or an invalid one, is not used
        #expect(try #require(Self.pair((nil, 200), (15, nil))).windDirDeg == nil)
        #expect(try #require(Self.pair((15, -1), (15, .nan))).windDirDeg == nil)
        #expect(try #require(Self.pair((15, 360), (15, nil))).windDirDeg == 0)
    }

    @Test func sameSiteMergeTakesSpeedAndDirectionTogether() {
        let old = Self.obs(id: "OLD", km: 5, tempC: 10, ageS: 1200, windKmh: 20, gustKmh: 35, windDirDeg: 90)
        let fresh = Self.obs(.iemMesonet, id: "NEW", km: 5.2, tempC: 10.5, windKmh: 10)
        let m = WxStationFusion.mergeSameSite([old, fresh], nowS: Self.nightS)
        #expect(m.count == 1 && m[0].windKmh == 10 && m[0].windDirDeg == nil)
        let freshNoWind = Self.obs(.iemMesonet, id: "NEW", km: 5.2, tempC: 10.5)
        let m2 = WxStationFusion.mergeSameSite([freshNoWind, old], nowS: Self.nightS)
        #expect(m2.count == 1 && m2[0].windKmh == 20 && m2[0].gustKmh == 35 && m2[0].windDirDeg == 90)
    }

    @Test func circularMeanNormalisesToZeroThroughThreeSixty() {
        #expect(WxStationFusion.circularMeanDeg(u: -0.0, v: 10, meanSpeed: 10) == 0)
        #expect(WxStationFusion.circularMeanDeg(u: -1e-15, v: 10, meanSpeed: 10) == 0)
        #expect(WxStationFusion.circularMeanDeg(u: -10, v: 0, meanSpeed: 10) == 270)
        #expect(WxStationFusion.circularMeanDeg(u: nil, v: nil, meanSpeed: nil) == nil)
        #expect(WxStationFusion.circularMeanDeg(u: 2, v: 0, meanSpeed: 10) == nil)  // 20% < 25%
    }
}
