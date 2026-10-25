// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoParseFuzzTests.swift - the weather-code rule, the differential and
// mutation fuzz cases of the /openmeteo/parse/ group of
// src/providers/openmeteo/test-openmeteo.c, and the pinned values of the
// shared Open-Meteo constants and request builders (OpenMeteoShared), all in
// suite OpenMeteoParseTests. The fuzz cases keep the C generators and oracles
// with SeededRNG in place of GRand (DECISIONS #17): the exact random
// sequences of C are not reproduced.

import Foundation
import Testing
@testable import WeatherCore

extension OpenMeteoParseTests {
    // MARK: - Weather code

    // C: /openmeteo/parse/weather-code-rule (test-openmeteo.c:4098-4137)
    @Test func parseWeatherCodeRule() {
        var codes: [String] = []
        var want: [Int] = []
        for v in -5...104 {
            codes.append(String(v))
            want.append((v >= 0 && v <= 99) ? v : -1)
        }
        let special: [(String, Int)] = [
            ("7.0", 7), ("7e0", 7), ("0.0", 0), ("-0.0", 0), ("99.0", 99),
            ("99.0000001", -1), ("1e2", -1), ("3.5", -1), ("-0.5", -1), ("\"3\"", -1),
            ("true", -1), ("null", -1), ("[]", -1), ("{}", -1), ("1e999", -1),
            ("9223372036854775807", -1), ("-9223372036854775808", -1), ("4.9e-324", -1),
        ]  // :4110-4113
        for (text, code) in special {
            codes.append(text)
            want.append(code)
        }
        let n = codes.count
        let times = Self.list((0..<n).map { Self.t0 + Int64($0) * 3600 })
        let temps = "[" + Array(repeating: "10", count: n).joined(separator: ",") + "]"
        let text = "{\"hourly\":{\"time\":" + times + ",\"temperature_2m\":" + temps + ",\"weather_code\":["
            + codes.joined(separator: ",") + "]}}"
        guard let r = Self.ok(Self.forecast(text, Self.gfsOnly)), let m = r.members.first else { return }
        for i in 0..<n {
            let h = Self.hourAt(m, Self.t0 + Int64(i) * 3600)
            #expect(h != nil, "index \(i)")
            if let h, h.wmo != want[i] {
                Issue.record("weather code index \(i) (\(codes[i])): stored \(h.wmo), expected \(want[i])")
            }
        }
    }

    // MARK: - Differential fuzz (test-openmeteo.c:1622-1804)

    /// GRand stand-ins over SeededRNG: g_rand_int_range [lo, hi), g_rand_double [0, 1), g_rand_boolean.
    struct GRandLike {
        var rng: SeededRNG

        mutating func intRange(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo..<hi, using: &rng) }
        mutating func double() -> Double { Double.random(in: 0..<1, using: &rng) }
        mutating func boolean() -> Bool { Bool.random(using: &rng) }
    }

    /// g_ascii_formatd("%.17g").
    static func g17(_ v: Double) -> String {
        String(format: "%.17g", locale: nil, v)
    }

    /// rand_number_text (test-openmeteo.c:1622-1657).
    static func randNumberText(_ g: inout GRandLike, _ s: inout String, _ lo: Double, _ hi: Double) {
        let k = g.intRange(0, 100)
        if k < 62 {
            let v = lo + (hi - lo) * g.double()
            if g.boolean() {
                s += String(Int32(v))  // (int)v: truncation toward zero
            } else {
                s += g17(v)
            }
        } else if k < 68 {
            s += "null"
        } else if k < 72 {
            s += g17(hi + 1.0 + g.double() * 1000)
        } else if k < 76 {
            s += g17(lo - 1.0 - g.double() * 1000)
        } else if k < 79 {
            s += "\"12\""
        } else if k < 81 {
            s += g.boolean() ? "true" : "false"
        } else if k < 83 {
            s += "-0.0"
        } else if k < 85 {
            s += g.boolean() ? "1e999" : "-1e999"
        } else if k < 87 {
            s += g.boolean() ? "{\"a\":1}" : "[1,2]"
        } else if k < 90 {
            s += g17(g.boolean() ? lo : hi)
        } else if k < 92 {
            s += "5e-324"
        } else if k < 94 {
            s += g.boolean() ? "9223372036854775807" : "-9223372036854775808"
        } else {
            s += String(g.intRange(Int(Int32(lo)), Int(Int32(hi)) + 1))
        }
    }

    /// rand_time_text (test-openmeteo.c:1660-1687).
    static func randTimeText(_ g: inout GRandLike, _ s: inout String, _ t: inout Int64) {
        let k = g.intRange(0, 100)
        if k < 72 {
            t += 3600 * Int64(g.intRange(0, 12) == 0 ? g.intRange(2, 6) : 1)
            s += String(t)
        } else if k < 77 {
            s += String(t)  // duplicate
        } else if k < 81 {
            s += String(t - 3600 * Int64(g.intRange(1, 5)))  // descending
        } else if k < 85 {
            s += String(t + 1800)  // misaligned
        } else if k < 87 {
            s += "\"x\""
        } else if k < 89 {
            s += "null"
        } else if k < 91 {
            s += String(t + 3600) + ".5"
        } else if k < 93 {
            s += g.boolean() ? "1e30" : "-5"
        } else if k < 95 {
            s += g.boolean() ? "true" : "[]"
        } else if k < 97 {
            s += String(timeMin + 3600 * Int64(g.intRange(-1, 2)))
        } else {
            s += String(timeMax - 3600 * Int64(g.intRange(0, 3)))
        }
    }

    /// random_body (test-openmeteo.c:1690-1750).
    static func randomBody(_ g: inout GRandLike) -> (text: String, models: [OpenMeteoModel]) {
        let all: [OpenMeteoModel] = [
            .ncepHrrrConus, .ncepNbmConus, .gfsSeamless, .ecmwfIfs025, .iconSeamless, .gemSeamless, .ukmoSeamless,
            .meteofranceSeamless,
        ]
        let n = g.intRange(1, 9)
        var order = Array(0..<8)
        for i in stride(from: 7, to: 0, by: -1) {
            let j = g.intRange(0, i + 1)
            order.swapAt(i, j)
        }
        let models = (0..<n).map { all[order[$0]] }
        let nT = g.intRange(0, 40)
        var t = t0 + 3600 * Int64(g.intRange(-3, 400))
        if g.intRange(0, 30) == 0 {
            t = timeMin - 3600
        }
        var s = "{\"hourly\":{\"time\":["
        for i in 0..<nT {
            if i > 0 { s += "," }
            randTimeText(&g, &s, &t)
        }
        s += "]"
        let vars: [(String, Double, Double)] = [
            ("temperature_2m", -100, 70), ("apparent_temperature", -100, 70), ("relative_humidity_2m", 0, 100),
            ("precipitation", 0, 500), ("precipitation_probability", 0, 100), ("cloud_cover", 0, 100),
            ("wind_speed_10m", 0, 500), ("wind_gusts_10m", 0, 500), ("weather_code", 0, 99),
        ]
        for m in 0..<n {
            for (key, lo, hi) in vars {
                let shape = g.intRange(0, 100)
                if shape < 12 {
                    continue  // missing array
                }
                if g.intRange(0, 6) == 0 && m % 2 == 1 {
                    continue  // whole models tend to drop
                }
                s += ",\"" + key + (n > 1 ? "_" + models[m].rawValue : "") + "\":"
                if shape < 15 {
                    s += shape < 13 ? "\"x\"" : (shape < 14 ? "null" : "{}")
                    continue
                }
                var len = nT
                if shape < 35 {
                    let delta = nT + g.intRange(-3, 3)
                    len = delta < 0 ? 0 : delta
                }
                s += "["
                for i in 0..<len {
                    if i > 0 { s += "," }
                    randNumberText(&g, &s, lo, hi)
                }
                s += "]"
            }
        }
        s += "}}"
        return (s, models)
    }

    // C: /openmeteo/parse/differential-fuzz (test-openmeteo.c:1760-1805)
    @Test func parseDifferentialFuzz() {
        var g = GRandLike(rng: SeededRNG(seed: 0x0e17e0))
        let nIter = fuzzIterations(4000)
        var okCount = 0
        var empty = 0
        for iter in 0..<nIter {
            let (text, models) = Self.randomBody(&g)
            let bytes = Self.b(text)
            let result = Self.forecast(bytes: bytes, models)
            guard let root = try? WxJSON.parseObject(bytes, maxLength: 4 * 1024 * 1024) else {
                Self.fails(result, .parse, nil, "iteration \(iter)")
                continue
            }
            let hourly = root.object("hourly")
            var expected = 0
            for model in models {
                if let hourly, Self.oracleHours(hourly, model.rawValue, models.count > 1) != nil {
                    expected += 1
                }
            }
            if expected == 0 {
                Self.fails(result, .notFound, nil, "iteration \(iter)")
                empty += 1
                continue
            }
            guard let r = Self.ok(result, "iteration \(iter)") else {
                return
            }
            if !Self.expectMatchesOracle(bytes, models, r) {
                Issue.record("iteration \(iter): \(text.prefix(400))")
                return
            }
            okCount += 1
        }
        if nIter >= 1000 {
            #expect(okCount > nIter / 4)  // :1800
            #expect(empty > 0)
        }
    }

    // C: /openmeteo/parse/mutation-fuzz (test-openmeteo.c:1808-1868)
    @Test func parseMutationFuzz() throws {
        var g = GRandLike(rng: SeededRNG(seed: 0xfeed))
        let names = ["forecast_miami_multi.json", "nowcast_miami.json", "geocode_miami.json"]
        let texts = try names.map { try Self.fixture($0) }
        let punct = Array("{}[],:\"-0.e9".utf8)
        let nIter = fuzzIterations(4000) / 2
        for _ in 0..<nIter {
            let which = g.intRange(0, 3)
            var copy = texts[which]
            var outLen = copy.count
            let edits = g.intRange(1, 6)
            for _ in 0..<edits {
                let pos = g.intRange(0, outLen)
                switch g.intRange(0, 4) {
                case 0:
                    copy[pos] = UInt8(g.intRange(0, 256))
                case 1:
                    copy[pos] = punct[g.intRange(0, 12)]
                case 2:
                    outLen = pos == 0 ? 1 : pos  // truncation
                default:
                    copy[pos] = 0x20
                }
            }
            let body = Array(copy[0..<outLen])
            if which == 0 {
                if case .success(let r) = Self.forecast(bytes: body, Self.miamiModels) {
                    for m in r.members {
                        for h in m.hours {
                            #expect(h.tS % 3600 == 0)
                            #expect(h.tempC.isNaN || (h.tempC >= -100 && h.tempC <= 70))
                            #expect(h.precipMm.isNaN || (h.precipMm >= 0 && h.precipMm <= 500))
                            #expect(h.wmo >= -1 && h.wmo <= 99)
                        }
                    }
                }
            } else if which == 1 {
                _ = Self.nowcast(bytes: body)  // a member or a WxError (typed throws), never a crash
            } else if case .success(let p) = Self.geocode(bytes: body) {
                #expect(p.count <= 20)  // WX_GEOCODER_MAX_HITS
            }
        }
    }

    // MARK: - Shared constants and request builders (OpenMeteoShared)

    // C: /openmeteo/provider/metadata (test-openmeteo.c:2339-2368), the
    // constant literals only; the provider object is the provider unit's.
    @Test func sharedConstantsMatchC() {
        #expect(OpenMeteoShared.providerID == "open-meteo")  // :2344
        #expect(OpenMeteoShared.name == "Open-Meteo")  // :2346
        #expect(OpenMeteoShared.attribution == "Weather data by Open-Meteo.com")  // :2347
        #expect(OpenMeteoShared.attributionURL == "https://open-meteo.com/")  // :2348
        #expect(OpenMeteoShared.baseURL == "https://api.open-meteo.com")  // :2351
        #expect(OpenMeteoShared.geocodingBaseURL == "https://geocoding-api.open-meteo.com")  // :2352
        #expect(OpenMeteoShared.nowcastGraceMs == 2000)  // :2353
        #expect(OpenMeteoShared.searchMinBytes == 2)  // :2354
        #expect(OpenMeteoShared.searchMaxBytes == 64)  // :2355
        // wx-openmeteo.h:207 / wx-openmeteo.c:17-18
        #expect(OpenMeteoShared.userAgent == "weather-app/0.1 (github.com/wtp128pro/weather)")
        #expect(OpenMeteoShared.userAgent == HTTPPolicy.userAgent)
        #expect(OpenMeteoShared.accept == "application/json")
        // the allow-list, API name -> model id (wx-openmeteo.h:23-25)
        let table: [(String, String)] = [
            ("ncep_hrrr_conus", "hrrr"), ("ncep_nbm_conus", "nbm"), ("gfs_seamless", "gfs"), ("ecmwf_ifs025", "ecmwf"),
            ("ecmwf_ifs", "ecmwf"),
            ("icon_seamless", "icon"), ("gem_seamless", "gem"), ("ukmo_seamless", "ukmo"),
            ("meteofrance_seamless", "meteofrance"), ("knmi_seamless", "knmi"),
        ]
        #expect(OpenMeteoModel.allCases.map(\.apiName) == table.map(\.0))
        #expect(OpenMeteoModel.allCases.map(\.memberID) == table.map(\.1))
    }

    // C: /openmeteo/net/model-selection (test-openmeteo.c:2575-2651), the
    // request paths and model lists only; the fetch itself is the provider unit's.
    @Test func sharedModelSelectionAndPaths() {
        let conus = "ncep_hrrr_conus,ncep_nbm_conus,gfs_seamless,ecmwf_ifs,icon_seamless,gem_seamless"
        let usOther = "gfs_seamless,ecmwf_ifs,icon_seamless,gem_seamless"
        let world = "ecmwf_ifs,icon_seamless,gem_seamless,gfs_seamless"
        let europe = "ecmwf_ifs,icon_seamless,gem_seamless,gfs_seamless,ukmo_seamless,meteofrance_seamless"
        let cases: [(String, Double, Double, String, String, String, Bool)] = [
            ("Miami", 25.7617, -80.1918, "25.7617", "-80.1918", conus, true),
            ("New York", 40.7128, -74.006, "40.7128", "-74.0060", conus, true),
            ("Seattle", 47.6062, -122.3321, "47.6062", "-122.3321", conus, true),
            ("Toronto", 43.6532, -79.3832, "43.6532", "-79.3832", conus, true),
            ("Honolulu", 21.3069, -157.8583, "21.3069", "-157.8583", usOther, false),
            ("Anchorage", 61.2181, -149.9003, "61.2181", "-149.9003", usOther, false),
            ("San Juan", 18.4655, -66.1057, "18.4655", "-66.1057", usOther, false),
            ("Guam", 13.4443, 144.7937, "13.4443", "144.7937", usOther, false),
            ("Calgary", 51.0447, -114.0719, "51.0447", "-114.0719", world, false),
            ("Mexico City", 19.4326, -99.1332, "19.4326", "-99.1332", world, false),
            ("Sydney", -33.8688, 151.2093, "-33.8688", "151.2093", world, false),
            ("Tokyo", 35.6762, 139.6503, "35.6762", "139.6503", world, false),
            ("Moscow", 55.7558, 37.6173, "55.7558", "37.6173", europe, false),
            ("London", 51.5072, -0.1276, "51.5072", "-0.1276", europe, false),
            ("Reykjavik", 64.1466, -21.9426, "64.1466", "-21.9426", europe, false),
            ("Origin", 0, 0, "0.0000", "0.0000", world, false),
            ("Neg zero", -0.00001, -0.00001, "0.0000", "0.0000", world, false),
            ("Rounding up", 25.76176, -80.19184, "25.7618", "-80.1918", conus, true),
            ("Rounding down", 25.76174, -80.19186, "25.7617", "-80.1919", conus, true),
            ("Pole", 90, 180, "90.0000", "180.0000", world, false),
            ("Antarctica", -90, -180, "-90.0000", "-180.0000", world, false),
        ]  // :2586-2607
        for (name, lat, lon, latText, lonText, models, nowcast) in cases {
            let chosen = OpenMeteoShared.models(lat: lat, lon: lon)
            #expect(chosen.models.map(\.apiName).joined(separator: ",") == models, "\(name)")
            #expect(chosen.conus == nowcast, "\(name)")
            // expect_path_a / expect_path_b (test-openmeteo.c:2488-2505)
            let a = "/v1/forecast?latitude=" + latText + "&longitude=" + lonText + "&hourly=temperature_2m,apparent_temperature,"
                + "relative_humidity_2m,precipitation,precipitation_probability,cloud_cover,wind_speed_10m,"
                + "wind_gusts_10m,weather_code&models=" + models + "&timeformat=unixtime&timezone=GMT&forecast_days=10"
                + "&wind_speed_unit=kmh&temperature_unit=celsius&precipitation_unit=mm"
            let bPath = "/v1/forecast?latitude=" + latText + "&longitude=" + lonText
                + "&minutely_15=precipitation&models=ncep_hrrr_conus"
                + "&forecast_minutely_15=12&timeformat=unixtime&timezone=GMT&precipitation_unit=mm"
            #expect(OpenMeteoShared.forecastPath(lat: lat, lon: lon, models: chosen.models) == a, "\(name)")
            #expect(OpenMeteoShared.nowcastPath(lat: lat, lon: lon) == bPath, "\(name)")
        }
    }

    // C: /openmeteo/geocoder/escaping (test-openmeteo.c:3506-3544), the
    // escaping of already-trimmed texts only; trimming and validation are the
    // place-search unit's.
    @Test func sharedSearchPathEscaping() {
        let cases: [(String, String)] = [
            ("Miami", "Miami"),
            ("S\u{E3}o Paulo", "S%C3%A3o%20Paulo"),
            ("\u{6771}\u{4EAC}", "%E6%9D%B1%E4%BA%AC"),
            ("a&b=c#d?e/f%g+h", "a%26b%3Dc%23d%3Fe%2Ff%25g%2Bh"),
            ("x\\y\"z'<>|{}^`", "x%5Cy%22z%27%3C%3E%7C%7B%7D%5E%60"),
            ("a-b_c.d~e", "a-b_c.d~e"),
            ("ab", "ab"),
            ("\u{E9}", "%C3%A9"),
            ("New York, NY", "New%20York%2C%20NY"),
            ("x%00y", "x%2500y"),
            ("..", ".."),
            ("a b  c", "a%20b%20%20c"),
        ]  // :3511-3525
        for (text, escaped) in cases {
            #expect(OpenMeteoShared.searchPath(escaping: text) == "/v1/search?name=" + escaped + "&count=10&language=en&format=json",
                    "\(text)")
        }
    }

    @Test func regionalModelSelectionAndProviders() throws {
        let london = try WxPlace(name: "London", admin1: "England", country: "United Kingdom", countryCode: "GB",
                                 lat: 51.5072, lon: -0.1276, timezone: "Europe/London")
        let amsterdam = try WxPlace(name: "Amsterdam", admin1: "North Holland", country: "Netherlands", countryCode: "NL",
                                    lat: 52.3676, lon: 4.9041, timezone: "Europe/Amsterdam")
        let berlin = try WxPlace(name: "Berlin", admin1: "Berlin", country: "Germany", countryCode: "DE",
                                 lat: 52.5200, lon: 13.4050, timezone: "Europe/Berlin")
        let calgary = try WxPlace(name: "Calgary", admin1: "Alberta", country: "Canada", countryCode: "CA",
                                  lat: 51.0447, lon: -114.0719, timezone: "America/Edmonton")

        let ukSel = OpenMeteoShared.models(for: london)
        #expect(ukSel.models.contains(.ukmoSeamless))
        #expect(ukSel.nowcastPath?.contains("models=ukmo_seamless") == true)

        let nlSel = OpenMeteoShared.models(for: amsterdam)
        #expect(nlSel.models.contains(.knmiSeamless))
        #expect(nlSel.nowcastPath?.contains("models=knmi_seamless") == true)

        let deSel = OpenMeteoShared.models(for: berlin)
        #expect(deSel.models.contains(.iconSeamless))
        #expect(deSel.nowcastPath?.contains("models=icon_seamless") == true)

        let caSel = OpenMeteoShared.models(for: calgary)
        #expect(caSel.models.contains(.gemSeamless))
        #expect(caSel.models.contains(.ncepHrrrConus))
        #expect(caSel.nowcastPath?.contains("models=ncep_hrrr_conus") == true)

        // NWS must reject Canadian places even when near the US border
        let toronto = try WxPlace(name: "Toronto", admin1: "Ontario", country: "Canada", countryCode: "CA",
                                  lat: 43.6532, lon: -79.3832, timezone: "America/Toronto")
        #expect(!WxGeo.inUSNWS(place: toronto))

        // BrightSkyProvider parser test
        let bsJSON = """
        {
          "weather": [
            {
              "timestamp": "2026-04-20T12:00:00+00:00",
              "temperature": 16.5,
              "dew_point": 8.0,
              "relative_humidity": 58,
              "precipitation": 0.2,
              "precipitation_probability": 35,
              "cloud_cover": 45,
              "wind_speed": 18.0,
              "wind_gust_speed": 28.0,
              "condition": "dry",
              "icon": "partly-cloudy-day"
            }
          ]
        }
        """
        let bsResult = try BrightSkyProvider.parseForecast(Array(bsJSON.utf8), fetchedS: 1_776_686_400)
        #expect(bsResult.members.count == 1)
        #expect(bsResult.members[0].modelID == "mosmix")
        #expect(bsResult.members[0].hours.count == 1)
        #expect(bsResult.members[0].hours[0].tempC == 16.5)
        #expect(bsResult.members[0].hours[0].precipProb == 35.0)

        // ECCCProvider parser test
        let ecccJSON = """
        {
          "features": [
            {
              "geometry": { "coordinates": [-79.3832, 43.6532] },
              "properties": {
                "hourlyForecastGroup": {
                  "hourlyForecasts": [
                    {
                      "timestamp": "2026-04-20T12:00:00Z",
                      "condition": { "en": "Partly cloudy" },
                      "temperature": { "value": { "en": 14.0 } },
                      "lop": { "value": { "en": 20.0 } },
                      "relativeHumidity": { "value": { "en": 62.0 } },
                      "wind": {
                        "speed": { "value": { "en": 15.0 } },
                        "gust": { "value": { "en": 24.0 } }
                      }
                    }
                  ]
                }
              }
            }
          ]
        }
        """
        let ecccResult = try ECCCProvider.parseForecast(
            Array(ecccJSON.utf8),
            placeLat: toronto.lat,
            placeLon: toronto.lon,
            fetchedS: 1_776_686_400
        )
        #expect(ecccResult.members.count == 1)
        #expect(ecccResult.members[0].modelID == "hrdps")
        #expect(ecccResult.members[0].hours.count == 1)
        #expect(ecccResult.members[0].hours[0].tempC == 14.0)
        #expect(ecccResult.members[0].hours[0].precipProb == 20.0)
    }
}
