// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U42AuditFixTests.swift - regression tests of the audit fixes in WeatherCore for
// slices P19-P21 (U20-F9: server values that trapped in Int()/Int64() conversions of the
// Air Quality card's sources). The app-target fixes of the same unit have no test target;
// their evidence is recorded with the unit.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct U42AuditFixTests {
    /// An Open-Meteo air-quality body (the shape of Fixtures/airquality/aqi-openmeteo.json) with
    /// the given current PM2.5 and NO2 text.
    static func camsBody(pm25: String, no2: String) -> Data {
        Data(#"""
        {"current":{"time":1792962000,"interval":3600,"us_aqi":30,"european_aqi":29,
                    "pm2_5":\#(pm25),"nitrogen_dioxide":\#(no2)},
         "hourly":{"time":[1792962000],"us_aqi":[30]}}
        """#.utf8)
    }

    /// An AirNow layer body with one monitor whose ValidTime (ms) is `validMs`, and one valid one.
    static func airNowBody(validMs: String) -> Data {
        Data(#"""
        {"features":[
          {"attributes":{"AQSID":"far","SiteName":"Far","OZONEPM_AQI":40,"ValidTime":\#(validMs)},
           "geometry":{"x":0,"y":0}},
          {"attributes":{"AQSID":"ok","SiteName":"Ok","OZONEPM_AQI":41,"ValidTime":1792962000000},
           "geometry":{"x":0,"y":0}}
        ]}
        """#.utf8)
    }

    /// U20-F9: a CAMS concentration of 1e19 passed the isFinite/>= 0 filter and trapped in
    /// Int(pm25.rounded()) when the card was built; it is now not a concentration.
    @Test func u20F9HugeConcentrationsAreDropped() throws {
        let m = try #require(WxAirQuality.parseOpenMeteo(Self.camsBody(pm25: "1e19", no2: "9.3e18")))
        try #require(m.pm25 == nil && m.no2 == nil)
        let card = WxAirQuality.card(model: m, inEurope: false, zone: WxFormat.Zone(timezone: "UTC"))
        #expect(card.source?.contains("PM2.5") == false && card.source?.contains("NO\u{2082}") == false)
        // An ordinary reading is unchanged.
        let ok = try #require(WxAirQuality.parseOpenMeteo(Self.camsBody(pm25: "5.7", no2: "16.6")))
        #expect(ok.pm25 == 5.7 && ok.no2 == 16.6)
    }

    /// U20-F9: a ValidTime far past WxLimits.timeMaxS (5e15 ms, about the year 160 000) was taken
    /// as the reading's time; the monitor is now skipped like one without a time.
    @Test func u20F9ValidTimeOutsideTheLimitsIsSkipped() throws {
        let r = try #require(WxAirQuality.parseAirNow(Self.airNowBody(validMs: "5e15"), lat: 0, lon: 0))
        #expect(r.map(\.id) == ["ok"])
        #expect(r.first?.tS == 1_792_962_000)
    }

    /// U20-F9: a ValidTime of 1e22 ms trapped in Int64((validMs / 1000).rounded()) inside
    /// parseAirNow (the process crashed on a server value).
    @Test func u20F9HugeValidTimeDoesNotTrap() throws {
        let r = try #require(WxAirQuality.parseAirNow(Self.airNowBody(validMs: "1e22"), lat: 0, lon: 0))
        #expect(r.map(\.id) == ["ok"])
    }
}
