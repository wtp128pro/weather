// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U36AuditFixTests.swift - regression tests for the verified audit findings of
// slices P07-P09 (HTTPPolicy, the forecast providers and parsers) fixed by U36.
// U07-F2 and U09-F4 are comment-only and have no test.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct U36AuditFixTests {
    // U07-F3: a %-encoded ':' host decodes to a non-IP name such as "a:b"; the IPv6 branch of
    // host_is_acceptable checked only its characters, so the client was built for the origin
    // "https://[a:b]" and failed later, on every request, as a retryable network error. The
    // base URL is now refused at construction; real IPv6 literals are still accepted.
    @Test func encodedColonHostIsRefusedAtConstruction() {
        for url in ["https://a%3Ab", "https://cafe%3Abad", "https://1%3A2%3A3", "https://1.2.3.4%3A5"] {
            #expect(HTTPPolicy.normaliseBaseURL(url) == nil, "\(url)")
            #expect(throws: WxError(.invalidArg, HTTPPolicy.Message.unacceptableBaseURL)) {
                try HTTPClientPolicy(baseURL: url)
            }
        }
        #expect(HTTPPolicy.normaliseBaseURL("https://[2001:db8::1]:443") == "https://[2001:db8::1]:443")
        #expect(HTTPPolicy.normaliseBaseURL("http://[::1]:9/") == "http://[::1]:9")
    }

    /// A one-feature Citypage body with one hourly entry of `condition`.
    private static func ecccBody(geometry: String, condition: String) -> [UInt8] {
        Array("""
        {
          "features": [
            {
              "geometry": \(geometry),
              "properties": {
                "hourlyForecastGroup": {
                  "hourlyForecasts": [
                    {
                      "timestamp": "2026-04-20T12:00:00Z",
                      "condition": { "en": "\(condition)" },
                      "temperature": { "value": { "en": 1.0 } },
                      "lop": { "value": { "en": 60.0 } }
                    }
                  ]
                }
              }
            }
          ]
        }
        """.utf8)
    }

    private static let toronto = "{ \"coordinates\": [-79.3832, 43.6532] }"

    // U09-F2: the distance sentinel was Double.greatestFiniteMagnitude, which is finite, so when
    // no feature distance was measured (the public default place, or features without geometry)
    // the 75 km gate threw "no Environment Canada city forecast near the place" for a usable body.
    @Test func ecccFallbackFeatureParsesWhenNoDistanceIsMeasured() throws {
        let defaults = try ECCCProvider.parseForecast(
            Self.ecccBody(geometry: Self.toronto, condition: "Cloudy"), fetchedS: 1_776_686_400)
        #expect(defaults.members.count == 1 && defaults.members[0].hours.count == 1)
        #expect(defaults.members[0].hours[0].tempC == 1.0)

        let noGeometry = try ECCCProvider.parseForecast(
            Self.ecccBody(geometry: "null", condition: "Cloudy"),
            placeLat: 43.6532, placeLon: -79.3832, fetchedS: 1_776_686_400)
        #expect(noGeometry.members.count == 1 && noGeometry.members[0].hours.count == 1)

        // A measured feature beyond 75 km is still refused.
        #expect(throws: WxError(.notFound, "no Environment Canada city forecast near the place")) {
            try ECCCProvider.parseForecast(
                Self.ecccBody(geometry: Self.toronto, condition: "Cloudy"),
                placeLat: 45.4215, placeLon: -75.6972, fetchedS: 1_776_686_400)
        }
    }

    // U09-F6: "Risk of freezing drizzle" texts matched neither "freezing rain" nor "ice pellets"
    // and fell to plain drizzle (51), outside the sleet codes; "Risk of freezing rain" maps to 66.
    @Test func ecccFreezingDrizzleMapsToFreezingDrizzleCodes() throws {
        func wmo(_ condition: String) throws -> Int {
            let result = try ECCCProvider.parseForecast(
                Self.ecccBody(geometry: Self.toronto, condition: condition),
                placeLat: 43.6532, placeLon: -79.3832, fetchedS: 1_776_686_400)
            return try #require(result.members.first?.hours.first).wmo
        }
        #expect(try wmo("Periods of drizzle. Risk of freezing drizzle") == 56)
        #expect(try wmo("Heavy freezing drizzle") == 57)
        #expect(try wmo("Periods of drizzle") == 51)
        #expect(try wmo("Periods of rain. Risk of freezing rain") == 66)
        #expect(try wmo("Chance of flurries. Risk of freezing drizzle") == 71) // snow first, unchanged
    }

    // U09-F5: Bright Sky's precipitation and precipitation_probability cover the hour before the
    // record's timestamp, but were stored in bucket [T, T + 3600), one hour late. They now go in
    // bucket T - 3600, merged with the previous record's bucket; the other fields stay at T.
    // Old: [12:00 0.0 mm 5 %, 13:00 0.2 mm 80 %]. New: [11:00 0.0/5, 12:00 0.2/80, 13:00 none].
    // The 13:00 record's 0.2 mm is light enough that its condition reads drizzle (51) from the
    // record's own amount, rain (61) from the shifted bucket's missing one; its wind, gust and
    // humidity stay at 13:00 and the 12:00 record's at 12:00 (U36 verifier handoff: M5-M7).
    @Test func brightSkyPrecipitationLandsInThePreviousHourBucket() throws {
        let body = Array("""
        {
          "weather": [
            { "timestamp": "2026-04-20T12:00:00+00:00", "temperature": 10.0, "precipitation": 0.0,
              "precipitation_probability": 5, "cloud_cover": 80, "condition": "dry",
              "wind_speed": 10.0, "wind_gust_speed": 20.0, "relative_humidity": 60 },
            { "timestamp": "2026-04-20T13:00:00+00:00", "temperature": 9.0, "precipitation": 0.2,
              "precipitation_probability": 80, "cloud_cover": 100, "condition": "rain",
              "wind_speed": 15.0, "wind_gust_speed": 30.0, "relative_humidity": 90 }
          ]
        }
        """.utf8)
        let result = try BrightSkyProvider.parseForecast(body, fetchedS: 1_776_686_400)
        let hours = try #require(result.members.first).hours
        let t12: Int64 = 1_776_686_400 // 2026-04-20T12:00Z
        try #require(hours.map(\.tS) == [t12 - 3600, t12, t12 + 3600])
        #expect(hours[0].precipMm == 0.0 && hours[0].precipProb == 5.0 && hours[0].tempC.isNaN)
        #expect(hours[0].windKmh.isNaN && hours[0].gustKmh.isNaN && hours[0].humidityPct.isNaN)
        #expect(hours[1].precipMm == 0.2 && hours[1].precipProb == 80.0 && hours[1].tempC == 10.0)
        #expect(hours[1].windKmh == 10.0 && hours[1].gustKmh == 20.0 && hours[1].humidityPct == 60.0)
        #expect(hours[2].precipMm.isNaN && hours[2].precipProb.isNaN && hours[2].tempC == 9.0)
        #expect(hours[2].windKmh == 15.0 && hours[2].gustKmh == 30.0 && hours[2].humidityPct == 90.0)
        #expect(hours[2].wmo == 51) // the condition stays at T, its intensity from the record's amount
        // A record's 0.5-4 mm reads rain (61), from the same record's amount.
        let rain = Array("""
        { "weather": [ { "timestamp": "2026-04-20T13:00:00+00:00", "temperature": 9.0, "precipitation": 2.0,
                         "precipitation_probability": 80, "cloud_cover": 100, "condition": "rain" } ] }
        """.utf8)
        let rainResult = try BrightSkyProvider.parseForecast(rain, fetchedS: 1_776_686_400)
        let rainHours = try #require(rainResult.members.first).hours
        try #require(rainHours.map(\.tS) == [t12, t12 + 3600])
        #expect(rainHours[0].precipMm == 2.0 && rainHours[1].precipMm.isNaN)
        #expect(rainHours[1].wmo == 61)
    }
}
