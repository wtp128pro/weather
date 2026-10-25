// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AirQualityTests.swift - the Air Quality card's sources against real
// responses captured on 2026-10-25 21:52 UTC (Fixtures/airquality): AirNow's
// current and hourly layers around Los Angeles, Open-Meteo's air-quality API
// for Paris; the expected values were read from the same files independently.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct AirQualityTests {
    static func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

    static let la = (lat: 34.0522, lon: -118.2437)
    /// The capture time; the newest AirNow hour is 21:00 UTC (2 PM in Los Angeles).
    static let nowS: Int64 = 1_792_965_153
    static let hourS: Int64 = 1_792_962_000

    static func current() throws -> [WxAirQuality.MonitorReading] {
        try #require(WxAirQuality.parseAirNow(try fixture("aqi-airnow-current.json"), lat: la.lat, lon: la.lon))
    }

    static func history() throws -> [WxAirQuality.MonitorReading] {
        try #require(WxAirQuality.parseAirNow(try fixture("aqi-airnow-dayago.json"), lat: la.lat, lon: la.lon))
    }

    @Test func requestsAskForTheRightHours() {
        let dayAgo = WxAirQuality.dayAgoWindow(nowS: Self.nowS)
        #expect(dayAgo.startS == Self.hourS - 27 * 3600 && dayAgo.endS == Self.hourS - 23 * 3600)
        let recent = WxAirQuality.recentWindow(nowS: Self.nowS)
        #expect(recent.startS == Self.hourS - 3 * 3600 && recent.endS == Self.hourS + 3600)
        let url = WxAirQuality.airNowHourlyURL(lat: Self.la.lat, lon: Self.la.lon, startS: 10, endS: 20)
        #expect(url.contains("Air_Now_Monitor_Data_Public") && url.contains("&time=10000,20000&"))
        #expect(url.contains("geometry=-118.2437,34.0522&") && url.contains("distance=45000&"))
        #expect(WxAirQuality.openMeteoURL(lat: 48.8566, lon: 2.3522).contains(
            "latitude=48.8566&longitude=2.3522&") == true)
        #expect(WxAirQuality.openMeteoURL(lat: 0, lon: 0).hasSuffix("&timeformat=unixtime"))
    }

    @Test func nearestMonitorAsReported() throws {
        let readings = try Self.current()
        #expect(readings.count == 13)
        let m = try #require(WxAirQuality.nearestMonitor(readings, nowS: Self.nowS))
        #expect(m.id == "060371103" && m.name == "Los Angeles - N. Main Street" && m.agency == "South Coast AQMD")
        #expect(m.aqi == 44 && m.tS == Self.hourS)
        #expect(abs(m.distKm - 2.223) < 0.01)
        // The reported value, not a blend with the next monitors (EBAM-10 41, Pasadena 45).
        let pasadena = try #require(readings.first { $0.name == "Pasadena" })
        #expect(pasadena.aqi == 45 && abs(pasadena.distKm - 13.971) < 0.01)
        // Older than three hours: not shown.
        #expect(WxAirQuality.nearestMonitor(readings, nowS: Self.hourS + 3 * 3600 + 1) == nil)
        #expect(WxAirQuality.nearestMonitor(readings, nowS: Self.hourS + 3 * 3600)?.id == "060371103")
        // Farther than 45 km: not used.
        let far = WxAirQuality.MonitorReading(id: "x", name: "X", agency: "", distKm: 45.1, aqi: 10, tS: Self.hourS)
        #expect(WxAirQuality.nearestMonitor([far], nowS: Self.nowS) == nil)
    }

    @Test func yesterdayIsTheSameMonitorTwentyFourHoursEarlier() throws {
        let history = try Self.history()
        #expect(history.count == 84)
        let m = try #require(WxAirQuality.nearestMonitor(try Self.current(), nowS: Self.nowS))
        // N. Main Street read 25, 31, 37, 37, 43, 43 from 19:00 to 00:00 UTC on 24 Oct: 37 at 21:00.
        #expect(WxAirQuality.dayAgoAQI(of: m, in: history) == 37)
        let ebam = try #require(try Self.current().first { $0.id == "840MMSC00010" })
        #expect(WxAirQuality.dayAgoAQI(of: ebam, in: history) == 37)  // EBAM-10: 40, 37, 41 around 21:00
        let silent = WxAirQuality.MonitorReading(id: "060371103", name: "", agency: "", distKm: 2, aqi: 44,
                                                 tS: Self.hourS + 5 * 3600)
        #expect(WxAirQuality.dayAgoAQI(of: silent, in: history) == nil)  // no record 24 h before
    }

    @Test func monitorCard() throws {
        let m = try #require(WxAirQuality.nearestMonitor(try Self.current(), nowS: Self.nowS))
        let zone = WxFormat.Zone(timezone: "America/Los_Angeles")
        let card = WxAirQuality.card(monitor: m, dayAgoAQI: 37, units: .imperial, zone: zone)
        #expect(card.index == 44 && card.valueText == "44" && card.category == "Good")
        #expect(card.summary == "Air quality index is 44, similar to yesterday at this time (37).")
        #expect(card.source == "Measured at Los Angeles - N. Main Street, 1.4 mi away, at 2 PM. Preliminary data.")
        #expect(card.validS == Self.hourS)
        #expect(card.credit == WxStationNetworks.Credit(
            text: "Air quality: South Coast AQMD via U.S. EPA AirNow (preliminary data)", url: "https://www.airnow.gov/"))
        let metric = WxAirQuality.card(monitor: m, dayAgoAQI: nil, units: .metric, zone: zone)
        #expect(metric.summary == "Air quality index is 44, which is good.")
        #expect(metric.source?.contains(", 2.2 km away, ") == true)
    }

    @Test func notAnAirNowAnswer() throws {
        #expect(WxAirQuality.parseAirNow(Data(#"{"error":{"code":400,"message":"Invalid query"}}"#.utf8),
                                         lat: 0, lon: 0) == nil)
        #expect(WxAirQuality.parseAirNow(Data("<html>".utf8), lat: 0, lon: 0) == nil)
        #expect(WxAirQuality.parseAirNow(Data(#"{"features":[]}"#.utf8), lat: 0, lon: 0) == [])
        // Missing value, time or position, an index out of range: skipped.
        let json = #"""
        {"features":[
          {"attributes":{"AQSID":"a","SiteName":"A","OZONEPM_AQI":null,"ValidTime":1792962000000},"geometry":{"x":0,"y":0}},
          {"attributes":{"AQSID":"b","SiteName":"B","OZONEPM_AQI":40,"ValidTime":null},"geometry":{"x":0,"y":0}},
          {"attributes":{"AQSID":"c","SiteName":"C","OZONEPM_AQI":40,"ValidTime":1792962000000}},
          {"attributes":{"AQSID":"d","SiteName":"D","OZONEPM_AQI":501,"ValidTime":1792962000000},"geometry":{"x":0,"y":0}},
          {"attributes":{"SiteName":"  E \n site ","DataSource":"","OZONEPM_AQI":12.6,"ValidTime":1792962000000,
                         "Latitude":0.1,"Longitude":0}}
        ]}
        """#
        let r = try #require(WxAirQuality.parseAirNow(Data(json.utf8), lat: 0, lon: 0))
        #expect(r == [WxAirQuality.MonitorReading(id: "E site", name: "E site", agency: "",
                                                  distKm: r.first?.distKm ?? 0, aqi: 13, tS: 1_792_962_000)])
        #expect(abs((r.first?.distKm ?? 0) - 11.12) < 0.01)
    }

    @Test func camsForecast() throws {
        let m = try #require(WxAirQuality.parseOpenMeteo(try Self.fixture("aqi-openmeteo.json")))
        #expect(m == WxAirQuality.ModelReading(aqi: 30, tS: Self.hourS, dayAgoAQI: 30, europeanAQI: 29,
                                               pm25: 5.7, no2: 16.6))
        let card = WxAirQuality.card(model: m, inEurope: true, zone: WxFormat.Zone(timezone: "Europe/Paris"))
        #expect(card.summary == "Air quality index is 30, similar to yesterday at this time (30).")
        #expect(card.source == "CAMS model forecast for 10 PM, not a local measurement. "
            + "PM2.5 6 \u{00B5}g/m\u{00B3}, NO\u{2082} 17 \u{00B5}g/m\u{00B3}, European AQI 29.")
        #expect(card.credit == WxAirQuality.camsCredit)
        let elsewhere = WxAirQuality.card(model: m, inEurope: false, zone: WxFormat.Zone(timezone: "UTC"))
        #expect(elsewhere.source?.hasSuffix("NO\u{2082} 17 \u{00B5}g/m\u{00B3}.") == true)
    }

    /// The old code took the 24th value from the end after dropping missing hours: 00:00 UTC
    /// today, shifted further by every gap. The day-ago value is now found by its time.
    @Test func camsDayAgoIsFoundByTime() throws {
        let t0: Int64 = 1_792_800_000  // 24 Oct 00:00 UTC
        var values: [String] = (0..<48).map { "\($0 + 10)" }
        values[3] = "null"
        values[4] = "null"
        values[21] = "77"
        let json = """
        {"current":{"time":\(t0 + 45 * 3600 + 900),"us_aqi":61.4,"european_aqi":null,"pm2_5":null,"nitrogen_dioxide":-1},
         "hourly":{"time":[\((0..<48).map { "\(t0 + Int64($0) * 3600)" }.joined(separator: ","))],
                   "us_aqi":[\(values.joined(separator: ","))]}}
        """
        let m = try #require(WxAirQuality.parseOpenMeteo(Data(json.utf8)))
        #expect(m.aqi == 61 && m.dayAgoAQI == 77 && m.europeanAQI == nil && m.pm25 == nil && m.no2 == nil)
        #expect(DetailViewModel.AirQualityCard.summarySentence(aqi: m.aqi, dayAgoAQI: m.dayAgoAQI)
            == "Air quality index is 61, better than yesterday at this time (77).")
        // No current US AQI: no reading.
        #expect(WxAirQuality.parseOpenMeteo(Data(#"{"current":{"time":1792962000}}"#.utf8)) == nil)
        #expect(WxAirQuality.parseOpenMeteo(Data(#"{"error":true,"reason":"x"}"#.utf8)) == nil)
    }

    @Test func sentences() {
        typealias Card = DetailViewModel.AirQualityCard
        #expect(Card.summarySentence(aqi: 44, dayAgoAQI: 36) == "Air quality index is 44, similar to yesterday at this time (36).")
        #expect(Card.summarySentence(aqi: 44, dayAgoAQI: 53) == "Air quality index is 44, better than yesterday at this time (53).")
        #expect(Card.summarySentence(aqi: 60, dayAgoAQI: 44) == "Air quality index is 60, worse than yesterday at this time (44).")
        #expect(Card.summarySentence(aqi: 120, dayAgoAQI: nil)
            == "Air quality index is 120, which is unhealthy for sensitive groups.")
        let none = Card.unavailable(offline: false)
        #expect(none.index == nil && none.valueText == "\u{2014}" && none.category == "No data")
        #expect(none.source == nil && none.validS == nil && none.credit == nil)
        #expect(none.summary == "No air-quality reading for this place yet. It is checked again at every refresh.")
        #expect(Card.unavailable(offline: true).summary == "Air quality needs a network connection.")
    }

    /// Every value sits inside its own category's band of the six equal bands.
    @Test func scaleBands() {
        typealias Card = DetailViewModel.AirQualityCard
        let categories = ["Good", "Moderate", "Unhealthy for Sensitive Groups", "Unhealthy", "Very Unhealthy", "Hazardous"]
        var last = -1.0
        for aqi in 0...500 {
            let p = Card.scalePosition(aqi)
            #expect(p > last && p > 0 && p < 1)
            #expect(categories[Int(p * 6)] == Card.categoryLabel(for: aqi), "AQI \(aqi)")
            last = p
        }
        #expect(Card.scalePosition(-5) == Card.scalePosition(0) && Card.scalePosition(900) == Card.scalePosition(500))
    }

    @Test func distanceText() {
        #expect(WxFormat.distance(2.223, units: .imperial) == "1.4 mi")
        #expect(WxFormat.distance(2.25, units: .metric) == "2.2 km")  // printf rounding of the binary value
        #expect(WxFormat.distance(0, units: .metric) == "0.0 km")
        #expect(WxFormat.distance(.nan, units: .metric) == "\u{2014}" && WxFormat.distance(-1, units: .metric) == "\u{2014}")
    }
}
