// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// METNorwayParseTests.swift - port of the pure/ and parse/ groups of
// src/providers/metno/test-metno.c (registrations test-metno.c:4281-4303):
// constants, request target, rounding, locale independence, the captured
// fixtures (complete_miami.json, complete_london.json, byte-identical copies of
// src/providers/metno/fixtures), document shapes, units, element skipping,
// value ranges, gusts, the hour cap, the fetch time, size and JSON limits and
// both fuzzers. Expected values are the C tests' literals (cited
// test-metno.c:LINE). GRand is replaced by SeededRNG (DECISIONS #17): the
// oracles are kept, the exact random sequences are not.
//
// Also (executor-added, "CX" rows): the pure cache-key, freshness, Expires cap,
// floor and throttle rules of wx-metno.c, with the literals of wx-metno.h.

import Foundation
import Testing

@testable import WeatherCore

@Suite struct METNorwayParseTests {
    // MARK: Helpers (test-metno.c:89-282)

    /// real_now_s (test-metno.c:95-99).
    private static func nowS() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    /// days since 1970-01-01 of a proleptic Gregorian date (test infrastructure).
    private static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// at(): UTC unix seconds of y-m-d h:00:00 (test-metno.c:102-110).
    private static func at(_ y: Int64, _ m: Int64, _ d: Int64, _ h: Int64) -> Int64 {
        daysFromCivil(y, m, d) * 86400 + h * 3600
    }

    /// iso_of(): "2026-10-12T19:00:00Z" of t (test-metno.c:113-120,
    /// g_date_time_format_iso8601 of a UTC time with whole seconds).
    private static func isoOf(_ t: Int64) -> String {
        let days = t >= 0 ? t / 86400 : (t - 86399) / 86400
        let secs = t - days * 86400
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ", y, m, d, secs / 3600, secs / 60 % 60,
            secs % 60)
    }

    /// quoted_iso (test-metno.c:239-244).
    private static func quotedISO(_ t: Int64) -> String {
        "\"" + isoOf(t) + "\""
    }

    /// mk_entry (test-metno.c:225-236): a timeseries element; nil omits a part.
    private static func mkEntry(_ time: String?, _ instant: String?, _ next: String?) -> String {
        var s = "{"
        if let time {
            s += #""time":"# + time + ","
        }
        s += #""data":{"#
        s += #""instant":{"details":{"# + (instant ?? "") + "}}"
        if let next {
            s += #","next_1_hours":{"details":{"# + next + "}}"
        }
        s += "}}"
        return s
    }

    /// mk_doc (test-metno.c:246-257).
    private static func mkDoc(_ meta: String?, _ entries: [String]) -> String {
        var s = #"{"type":"Feature","properties":{"#
        if let meta {
            s += meta + ","
        }
        s += #""timeseries":["# + entries.joined(separator: ",") + "]}}"
        return s
    }

    /// doc_of (test-metno.c:267-282).
    private static func docOf(_ entries: String...) -> String {
        mkDoc(nil, entries)
    }

    private static func parse(_ text: String) throws(WxError) -> WxMember {
        try METNorwayParse.parseForecast(Array(text.utf8), fetchedS: nowS())
    }

    /// parse_ok (test-metno.c:166-174).
    private static func parseOK(_ text: String) throws -> WxMember {
        try parse(text)
    }

    /// assert_parse_fails (test-metno.c:176-183) over raw bytes.
    private static func expectFailure(
        _ body: [UInt8], fetchedS: Int64? = nil, _ code: WxError.Code, _ message: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try METNorwayParse.parseForecast(body, fetchedS: fetchedS ?? nowS())
            Issue.record("parse succeeded, expected \(code) \"\(message)\"", sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == code, sourceLocation: sourceLocation)
            #expect(error.message == message, sourceLocation: sourceLocation)
        }
    }

    private static func expectFailure(
        _ text: String, _ code: WxError.Code, _ message: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectFailure(Array(text.utf8), code, message, sourceLocation: sourceLocation)
    }

    /// assert_same_double (test-metno.c:139-149): both NaN, or equal with the same sign bit.
    private static func expectSame(
        _ got: Double, _ want: Double, _ what: String = "", sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if want.isNaN {
            #expect(got.isNaN, "\(what): \(got) should be NaN", sourceLocation: sourceLocation)
        } else {
            #expect(!got.isNaN, "\(what): NaN, want \(want)", sourceLocation: sourceLocation)
            #expect(got == want, "\(what): \(got) != \(want)", sourceLocation: sourceLocation)
            #expect(
                got.sign == want.sign, "\(what): sign of \(got) != sign of \(want)",
                sourceLocation: sourceLocation)
        }
    }

    /// assert_member_invariants (test-metno.c:186-222).
    private static func expectInvariants(_ member: WxMember, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(member.sourceID == "met-no", sourceLocation: sourceLocation)
        #expect(member.modelID == "ecmwf", sourceLocation: sourceLocation)
        let hours = member.hours
        #expect(hours.count >= 1, sourceLocation: sourceLocation)
        #expect(hours.count <= WxLimits.memberMaxHours, sourceLocation: sourceLocation)
        #expect(member.quarters.isEmpty, sourceLocation: sourceLocation)
        for (i, h) in hours.enumerated() {
            #expect(h.tS % 3600 == 0, sourceLocation: sourceLocation)
            #expect(h.tS >= WxLimits.timeMinS && h.tS < WxLimits.timeMaxS, sourceLocation: sourceLocation)
            if i > 0 {
                #expect(h.tS > hours[i - 1].tS, sourceLocation: sourceLocation)
            }
            let finite = [h.tempC, h.feelsC, h.cloudPct, h.humidityPct, h.windKmh, h.gustKmh, h.precipMm]
            #expect(finite.contains { !$0.isNaN }, "hour \(i) has no value", sourceLocation: sourceLocation)
            #expect(h.tempC.isNaN || (h.tempC >= -100 && h.tempC <= 70), sourceLocation: sourceLocation)
            #expect(h.feelsC.isNaN || (h.feelsC >= -100 && h.feelsC <= 70), sourceLocation: sourceLocation)
            #expect(h.cloudPct.isNaN || (h.cloudPct >= 0 && h.cloudPct <= 100), sourceLocation: sourceLocation)
            #expect(
                h.humidityPct.isNaN || (h.humidityPct >= 0 && h.humidityPct <= 100), sourceLocation: sourceLocation)
            #expect(h.windKmh.isNaN || (h.windKmh >= 0 && h.windKmh <= 500), sourceLocation: sourceLocation)
            #expect(h.gustKmh.isNaN || (h.gustKmh >= 0 && h.gustKmh <= 500), sourceLocation: sourceLocation)
            #expect(h.precipMm.isNaN || (h.precipMm >= 0 && h.precipMm <= 500), sourceLocation: sourceLocation)
            #expect(h.precipProb.isNaN, sourceLocation: sourceLocation)
            #expect(h.wmo == -1, sourceLocation: sourceLocation)
        }
    }

    private static func fixture(_ name: String) throws -> [UInt8] {
        Array(try Fixtures.data(name))
    }

    // Independent oracle of the fixtures: Foundation's JSONDecoder and
    // ISO8601DateFormatter instead of json-glib/GDateTime (test-metno.c:424-468).
    private struct OracleDoc: Decodable {
        struct Props: Decodable { let timeseries: [Entry] }
        struct Entry: Decodable {
            let time: String
            let data: EntryData
        }
        struct EntryData: Decodable {
            let instant: Details
            let next_1_hours: Details?
        }
        struct Details: Decodable { let details: [String: Double] }
        let properties: Props
    }

    /// oracle_number (test-metno.c:424-430).
    private static func oracleNumber(_ details: [String: Double]?, _ name: String, _ factor: Double) -> Double {
        guard let v = details?[name] else {
            return .nan
        }
        return v * factor
    }

    /// assert_matches_oracle (test-metno.c:434-468).
    private static func expectMatchesOracle(_ body: [UInt8], _ member: WxMember) throws {
        let doc = try JSONDecoder().decode(OracleDoc.self, from: Data(body))
        let series = doc.properties.timeseries
        let hours = member.hours
        #expect(hours.count == series.count)
        let formatter = ISO8601DateFormatter()
        for (i, entry) in series.enumerated() where i < hours.count {
            let when = try #require(formatter.date(from: entry.time))
            #expect(hours[i].tS == Int64(when.timeIntervalSince1970))
            let instant = entry.data.instant.details
            let next = entry.data.next_1_hours?.details
            expectSame(hours[i].tempC, oracleNumber(instant, "air_temperature", 1.0), "temp \(i)")
            expectSame(hours[i].feelsC, oracleNumber(instant, "apparent_air_temperature", 1.0), "feels \(i)")
            expectSame(hours[i].cloudPct, oracleNumber(instant, "cloud_area_fraction", 1.0), "cloud \(i)")
            expectSame(hours[i].humidityPct, oracleNumber(instant, "relative_humidity", 1.0), "humidity \(i)")
            expectSame(hours[i].windKmh, oracleNumber(instant, "wind_speed", 3.6), "wind \(i)")
            expectSame(hours[i].gustKmh, oracleNumber(instant, "wind_speed_of_gust", 3.6), "gust \(i)")
            expectSame(hours[i].precipMm, oracleNumber(next, "precipitation_amount", 1.0), "precip \(i)")
            #expect(hours[i].precipProb.isNaN)
            #expect(hours[i].wmo == -1)
        }
    }

    // MARK: pure/

    // C: /metno/pure/constants (test-metno.c:288-297)
    @Test func pureConstants() {
        #expect(METNorwayParse.baseURL == "https://api.met.no")  // test-metno.c:288
        #expect(METNorwayParse.userAgent == "weather-app/0.1 (github.com/wtp128pro/weather)")  // test-metno.c:289
        #expect(METNorwayParse.providerID == "met-no")  // test-metno.c:290
        #expect(METNorwayParse.modelID == "ecmwf")  // test-metno.c:291
        #expect(METNorwayParse.cacheMax == 32)  // test-metno.c:292
        #expect(METNorwayParse.minRefreshS == 600)  // test-metno.c:293
        #expect(METNorwayParse.throttleS == 60)  // test-metno.c:294
        #expect(WxLimits.isValidID(METNorwayParse.providerID))  // test-metno.c:295
        #expect(!METNorwayParse.providerID.contains("."))  // test-metno.c:296
        #expect(WxLimits.isValidID(METNorwayParse.modelID))  // test-metno.c:297
    }

    // C: /metno/pure/path-table (test-metno.c:301-331)
    @Test func purePathTable() throws {
        let p = "/weatherapi/locationforecast/2.0/complete?"
        let cases: [(Double, Double, String)] = [
            (25.7617, -80.1918, p + "lat=25.7617&lon=-80.1918"),
            (51.5072, -0.1276, p + "lat=51.5072&lon=-0.1276"),
            (-33.8688, 151.2093, p + "lat=-33.8688&lon=151.2093"),
            (0.0, 0.0, p + "lat=0.0000&lon=0.0000"),
            (-0.0, -0.0, p + "lat=0.0000&lon=0.0000"),
            (-0.00001, -0.00004, p + "lat=0.0000&lon=0.0000"),
            (-0.00006, 0.00006, p + "lat=-0.0001&lon=0.0001"),
            (25.76174999, -80.19184999, p + "lat=25.7617&lon=-80.1918"),
            (25.76176, -80.19186, p + "lat=25.7618&lon=-80.1919"),
            (25.5, 100.0, p + "lat=25.5000&lon=100.0000"),
            (90.0, 180.0, p + "lat=90.0000&lon=180.0000"),
            (-90.0, -180.0, p + "lat=-90.0000&lon=-180.0000"),
            (89.99996, 179.99996, p + "lat=90.0000&lon=180.0000"),
            (1e-300, -1e-300, p + "lat=0.0000&lon=0.0000"),
            (4.9e-324, -4.9e-324, p + "lat=0.0000&lon=0.0000"),
        ]  // test-metno.c:307-321
        for (lat, lon, want) in cases {
            let path = METNorwayParse.forecastPath(lat: lat, lon: lon)
            #expect(path == want, "lat \(lat) lon \(lon)")
            #expect(HTTPPolicy.isValidPath(path))
        }
        // The longest possible target is the one of the south-west corner (test-metno.c:330).
        let longest = try #require(METNorwayParse.forecastPath(lat: -90.0, lon: -180.0))
        #expect(longest.utf8.count == 68)
    }

    // C: /metno/pure/path-rejects-invalid (test-metno.c:334-351)
    @Test func purePathRejectsInvalid() {
        let bad: [Double] = [
            .nan, .infinity, -.infinity, 180.0000001, -180.0000001, 1e300, -1e300,
            Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
        ]  // test-metno.c:337-338
        let badLatOnly: [Double] = [90.0000001, -90.0000001, 100.0, -100.0, 179.9, -179.9]  // test-metno.c:339
        for b in bad {
            #expect(METNorwayParse.forecastPath(lat: b, lon: 0.0) == nil)
            #expect(METNorwayParse.forecastPath(lat: 0.0, lon: b) == nil)
            #expect(METNorwayParse.forecastPath(lat: b, lon: b) == nil)
            #expect(METNorwayParse.cacheKey(lat: b, lon: 0.0) == nil)
        }
        for b in badLatOnly {
            #expect(METNorwayParse.forecastPath(lat: b, lon: 0.0) == nil)
            #expect(METNorwayParse.forecastPath(lat: b, lon: b / 2) == nil)
        }
        #expect(METNorwayParse.forecastPath(lat: 0.0, lon: 200.0) == nil)  // test-metno.c:350
    }

    // C: /metno/pure/path-property (test-metno.c:355-387); GRand seed 0x4d45544e -> SeededRNG.
    @Test func purePathProperty() throws {
        var rng = SeededRNG(seed: 0x4d45_544e)
        let prefix = "/weatherapi/locationforecast/2.0/complete?"
        for i in 0..<20000 {
            var lat = Double.random(in: -90.0..<90.0, using: &rng)
            var lon = Double.random(in: -180.0..<180.0, using: &rng)
            if i % 4 == 0 {
                lat = (lat * 1e5).rounded(.down) / 1e5
                lon = (lon * 1e5).rounded(.down) / 1e5
            }
            let path = try #require(METNorwayParse.forecastPath(lat: lat, lon: lon))
            #expect(path.hasPrefix(prefix + "lat="))
            let parts = path.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false)
            try #require(parts.count == 2)
            #expect(parts[0].hasPrefix("lat="))
            #expect(parts[1].hasPrefix("lon="))
            let texts = [String(parts[0].dropFirst(4)), String(parts[1].dropFirst(4))]
            let values = [lat, lon]
            for k in 0..<2 {
                let text = texts[k]
                let dot = try #require(text.firstIndex(of: "."), "\(text)")
                #expect(text[text.index(after: dot)...].count == 4, "\(text)")
                for (j, c) in text.enumerated() {
                    #expect(c.isASCII && (c.isNumber || c == "." || (c == "-" && j == 0)), "\(text)")
                }
                #expect(text != "-0.0000")
                let back = try #require(Double(text), "\(text)")
                #expect(abs(back - values[k]) <= 0.00005 + 1e-9, "\(text) vs \(values[k])")  // test-metno.c:384
            }
        }
    }

    // C: /metno/pure/locale-independence (test-metno.c:391-418). The C test
    // switches LC_ALL to a decimal-comma locale; Swift tests never change the
    // process locale (TestSupport policy 2): the same assertions run here and
    // the suite is also run under de_DE (RUN_SUITE_LOCALE=de_DE run_suite.sh).
    @Test func pureLocaleIndependence() throws {
        #expect(
            METNorwayParse.forecastPath(lat: 25.7617, lon: -80.1918)
                == "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918")  // test-metno.c:408
        let member = try METNorwayParse.parseForecast(try Self.fixture("complete_miami.json"), fetchedS: Self.nowS())
        #expect(member.hours.count == 92)  // test-metno.c:414
        #expect(member.hours.first?.tempC == 30.5)  // test-metno.c:415
        #expect(member.hours.first?.humidityPct == 66.0)  // test-metno.c:416
    }

    // MARK: parse/ fixtures

    // C: /metno/parse/fixture-miami (test-metno.c:471-508)
    @Test func parseFixtureMiami() throws {
        let body = try Self.fixture("complete_miami.json")
        let fetched = Self.nowS()
        let member = try METNorwayParse.parseForecast(body, fetchedS: fetched)
        Self.expectInvariants(member)
        #expect(member.fetchedS == fetched)
        try Self.expectMatchesOracle(body, member)
        let hours = member.hours
        try #require(hours.count == 92)  // test-metno.c:484
        #expect(hours[0].tS == 1_791_831_600)  // test-metno.c:486
        #expect(hours[0].tempC == 30.5)  // test-metno.c:487
        #expect(hours[0].feelsC == 35.3)  // test-metno.c:488
        #expect(hours[0].cloudPct == 49.2)  // test-metno.c:489
        #expect(hours[0].humidityPct == 66.0)  // test-metno.c:490
        #expect(hours[0].windKmh == 5.8 * 3.6)  // test-metno.c:491
        #expect(abs(hours[0].windKmh - 20.88) < 1e-12)  // test-metno.c:492
        #expect(hours[0].gustKmh.isNaN)  // test-metno.c:493
        #expect(hours[0].precipMm == 0.5)  // test-metno.c:494
        #expect(hours[1].tS == hours[0].tS + 3600)  // test-metno.c:495
        #expect(hours[1].precipMm == 0.3)  // test-metno.c:496
        #expect(hours[2].precipMm == 0.1)  // test-metno.c:497
        #expect(hours[91].tS == 1_792_627_200)  // test-metno.c:499
        #expect(hours[91].tempC == 25.8)  // test-metno.c:500
        #expect(hours[91].windKmh == 3.5 * 3.6)  // test-metno.c:501
        #expect(hours[91].precipMm.isNaN)  // test-metno.c:502
        #expect(hours[91].tS - hours[90].tS == 6 * 3600)  // test-metno.c:503
        #expect(hours.filter { !$0.precipMm.isNaN }.count == 65)  // test-metno.c:507
    }

    // C: /metno/parse/fixture-london (test-metno.c:511-536)
    @Test func parseFixtureLondon() throws {
        let body = try Self.fixture("complete_london.json")
        let member = try METNorwayParse.parseForecast(body, fetchedS: Self.nowS())
        Self.expectInvariants(member)
        try Self.expectMatchesOracle(body, member)
        let hours = member.hours
        try #require(hours.count == 92)  // test-metno.c:522
        #expect(hours[0].tS == 1_791_831_600)  // test-metno.c:523
        #expect(hours[0].tempC == 17.6)  // test-metno.c:524
        #expect(hours[0].feelsC == 17.6)  // test-metno.c:525
        #expect(hours[0].cloudPct == 94.5)  // test-metno.c:526
        #expect(hours[0].humidityPct == 90.8)  // test-metno.c:527
        #expect(hours[0].windKmh == 4.3 * 3.6)  // test-metno.c:528
        #expect(abs(hours[0].windKmh - 15.48) < 1e-12)  // test-metno.c:529
        #expect(hours[0].precipMm == 0.0)  // test-metno.c:530
        #expect(hours[0].precipMm.sign == .plus)  // test-metno.c:531
        #expect(hours.filter { !$0.precipMm.isNaN && $0.precipMm > 0 }.count == 1)  // test-metno.c:535
    }

    // C: /metno/parse/fixture-limits (test-metno.c:540-553), plus the FIXTURES
    // acceptance criterion: the bundled copies are the captured documents
    // (sizes of net-providers.md section 6 and the first/last bytes of
    // src/providers/metno/fixtures).
    @Test func parseFixtureLimits() throws {
        for (name, size) in [("complete_miami.json", 64396), ("complete_london.json", 63992)] {
            let body = try Self.fixture(name)
            #expect(body.count <= 200 * 1024)  // test-metno.c:545
            #expect(body.count == size, "\(name) is not the captured document")
            #expect(body.starts(with: Array(#"{"type":"Feature","geometry":{"type":"Point","coordinates":["#.utf8)))
            _ = try WxJSON.parseObject(body, maxLength: HTTPPolicy.maxBodyBytes)
        }
    }

    // C: /metno/parse/fixture-dropped-elements (test-metno.c:556-581). The C test
    // rewrites the document with json-glib; here the "time" value of every fifth
    // element is replaced in the bytes ("time" occurs once per element).
    @Test func parseFixtureDroppedElements() throws {
        let src = try Self.fixture("complete_miami.json")
        let key = Array(#""time":""#.utf8)
        var out: [UInt8] = []
        var i = 0
        var element = 0
        var kept = 0
        while i < src.count {
            if src[i] == key[0] && i + key.count <= src.count && Array(src[i..<(i + key.count)]) == key {
                out += key
                var j = i + key.count
                while src[j] != UInt8(ascii: "\"") { j += 1 }
                if element % 5 == 0 {
                    out += Array("soon".utf8)
                } else {
                    out += src[(i + key.count)..<j]
                    kept += 1
                }
                element += 1
                i = j
                continue
            }
            out.append(src[i])
            i += 1
        }
        #expect(element == 92)
        let member = try METNorwayParse.parseForecast(out, fetchedS: Self.nowS())
        Self.expectInvariants(member)
        #expect(member.hours.count == kept)
        #expect(kept == 92 - 19)  // test-metno.c:579
        let firstT = try #require(member.hours.first).tS
        #expect(firstT == 1_791_831_600 + 3600, "first hour \(firstT), times \(member.hours.prefix(3).map(\.tS))")  // test-metno.c:580
    }

    // MARK: parse/ document shape and units

    // C: /metno/parse/document-shapes (test-metno.c:588-625)
    @Test func parseDocumentShapes() throws {
        let e = Self.mkEntry(#""2026-10-12T19:00:00Z""#, #""air_temperature":20"#, nil)
        let notForecast = [
            #"{}"#,
            #"{"properties":null}"#,
            #"{"properties":[]}"#,
            #"{"properties":"x"}"#,
            #"{"properties":{}}"#,
            #"{"properties":{"timeseries":null}}"#,
            #"{"properties":{"timeseries":{}}}"#,
            #"{"properties":{"timeseries":"x"}}"#,
            #"{"properties":{"timeseries":5}}"#,
            #"{"timeseries":[]}"#,
            #"{"Properties":{"timeseries":[]}}"#,
            #"{"properties":{"Timeseries":[]}}"#,
        ]  // test-metno.c:592-603
        for text in notForecast {
            Self.expectFailure(text, .parse, "not a locationforecast document")
        }
        Self.expectFailure(#"{"properties":{"timeseries":[]}}"#, .parse, "no usable forecast data")  // test-metno.c:608
        Self.expectFailure(#"{"properties":{"timeseries":[null,1,"a",[],{}]}}"#, .parse, "no usable forecast data")
        Self.expectFailure("", .parse, "empty response")  // test-metno.c:612
        Self.expectFailure("[]", .parse, "response is not a JSON object")
        Self.expectFailure("null", .parse, "response is not a JSON object")
        Self.expectFailure(#"{"properties""#, .parse, "malformed JSON")
        Self.expectFailure("<html>502 Bad Gateway</html>", .parse, "malformed JSON")
        Self.expectFailure(#"{"properties":{},"properties":{}}"#, .parse, "malformed JSON")  // test-metno.c:617
        // {"a":"\xff"} (test-metno.c:619): a raw 0xFF byte inside a string.
        let badUTF8: [UInt8] = [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]
        Self.expectFailure(badUTF8, .parse, "response is not valid UTF-8")
        let member = try Self.parseOK(Self.docOf(e))
        Self.expectInvariants(member)
    }

    // C: /metno/parse/errors-do-not-echo-body (test-metno.c:628-635)
    @Test func parseErrorsDoNotEchoBody() {
        Self.expectFailure(
            #"{"properties":{"timeseries":"SENTINEL-BODY-TEXT"}}"#, .parse, "not a locationforecast document")
        Self.expectFailure(
            #"{"properties":{"meta":{"units":{"air_temperature":"SENTINEL-BODY-TEXT"}},"timeseries":[]}}"#,
            .parse, "unexpected units")
    }

    // C: /metno/parse/units (test-metno.c:638-711)
    @Test func parseUnits() throws {
        let units: [(name: String, good: String, bad: String)] = [
            ("air_temperature", "celsius", "fahrenheit"),
            ("apparent_air_temperature", "celsius", "kelvin"),
            ("cloud_area_fraction", "%", "1"),
            ("relative_humidity", "%", "fraction"),
            ("wind_speed", "m/s", "km/h"),
            ("wind_speed_of_gust", "m/s", "knots"),
            ("precipitation_amount", "mm", "in"),
        ]  // test-metno.c:643-649 (units[] of test-metno.c:642)
        let e = Self.mkEntry(#""2026-10-12T19:00:00Z""#, #""air_temperature":20"#, nil)
        for unit in units {
            // pass 0: good; 1: bad; 2: ""; 3: "CELSIUS"; 4: "m/s "; 5: the number 5 (test-metno.c:656-679).
            let values: [String?] = [unit.good, unit.bad, "", "CELSIUS", "m/s ", nil]
            for (pass, value) in values.enumerated() {
                let meta =
                    value.map { #""meta":{"units":{""# + unit.name + #"":""# + $0 + #""}}"# }
                    ?? (#""meta":{"units":{""# + unit.name + #"":5}}"#)
                let text = Self.mkDoc(meta, [e])
                if pass == 0 {
                    Self.expectInvariants(try Self.parseOK(text))
                } else {
                    Self.expectFailure(text, .parse, "unexpected units")
                }
            }
        }
        // A mistyped (null) unit is a mismatch as well (test-metno.c:692-696).
        Self.expectFailure(Self.mkDoc(#""meta":{"units":{"wind_speed":null}}"#, [e]), .parse, "unexpected units")
        // Missing meta, missing units, other variables and an empty units object are accepted.
        let accepted = [
            #""meta":{}"#, #""meta":null"#, #""meta":{"units":{}}"#, #""meta":{"units":null}"#, #""meta":[]"#,
            #""meta":{"units":{"air_pressure_at_sea_level":"hPa"}}"#,
        ]  // test-metno.c:698-699
        for meta in accepted {
            Self.expectInvariants(try Self.parseOK(Self.mkDoc(meta, [e])))
        }
    }

    // MARK: parse/ elements and values

    /// assert_times (test-metno.c:713-723).
    private static func expectTimes(
        _ text: String, _ want: [Int64], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let member = try parseOK(text)
        expectInvariants(member, sourceLocation: sourceLocation)
        #expect(member.hours.map(\.tS) == want, sourceLocation: sourceLocation)
    }

    // C: /metno/parse/element-skipping (test-metno.c:726-859)
    @Test func parseElementSkipping() throws {
        let t0 = Self.at(2026, 10, 12, 19)
        #expect(t0 == 1_791_831_600)  // test-metno.c:486 (the same instant)
        let q0 = Self.quotedISO(t0)
        let q1 = Self.quotedISO(t0 + 3600)
        let q2 = Self.quotedISO(t0 + 7200)
        let q3 = Self.quotedISO(t0 + 10800)
        #expect(q0 == #""2026-10-12T19:00:00Z""#)
        let v = #""air_temperature":20"#
        let e0 = Self.mkEntry(q0, v, nil)
        let e1 = Self.mkEntry(q1, v, nil)
        let e2 = Self.mkEntry(q2, v, nil)
        let e3 = Self.mkEntry(q3, v, nil)

        // Order: duplicates and descending stamps are dropped (test-metno.c:740-749).
        try Self.expectTimes(Self.docOf(e0, e0, e1, e1, e0, e2), [t0, t0 + 3600, t0 + 7200])
        try Self.expectTimes(Self.docOf(e2, e1, e3, e0), [t0 + 7200, t0 + 10800])
        // Gaps are fine (test-metno.c:751-756).
        let ef = Self.mkEntry(Self.quotedISO(t0 + 6 * 3600), v, nil)
        try Self.expectTimes(Self.docOf(e0, ef), [t0, t0 + 6 * 3600])
        // Not objects, or lacking / mangled time (test-metno.c:758-767).
        let noTime = Self.mkEntry(nil, v, nil)
        let numTime = Self.mkEntry("1791831600", v, nil)
        let nullTime = Self.mkEntry("null", v, nil)
        let arrTime = Self.mkEntry(#"["2026-10-12T20:00:00Z"]"#, v, nil)
        try Self.expectTimes(
            Self.docOf("1", #""x""#, "null", "true", "[]", "[1]", noTime, numTime, nullTime, arrTime, e0, "{}", e1),
            [t0, t0 + 3600])
        // Off the hour, malformed or outside 2000..2100 (test-metno.c:769-781).
        let badTimes = [
            #""2026-10-12T19:30:00Z""#, #""2026-10-12T19:00:01Z""#, #""2026-10-12T19:59:59Z""#,
            #""2026-10-12t19:00:00z""#, #""2026-10-12 19:00:00Z""#, #""2026-10-12T19:00:00""#,
            #""2026-13-12T19:00:00Z""#, #""2026-02-30T19:00:00Z""#, #""1999-12-31T23:00:00Z""#,
            #""2101-01-01T00:00:00Z""#, #""""#, #""2026-10-12T19:00:00Z ""#, #"" 2026-10-12T19:00:00Z""#,
        ]
        for bad in badTimes {
            try Self.expectTimes(Self.docOf(Self.mkEntry(bad, v, nil), e1), [t0 + 3600])
        }
        // The ends of the range, offsets and fractions (test-metno.c:783-797).
        let first = Self.mkEntry(#""2000-01-01T00:00:00Z""#, v, nil)
        let last = Self.mkEntry(#""2100-12-31T23:00:00Z""#, v, nil)
        try Self.expectTimes(Self.docOf(first, last), [946_684_800, 4_133_980_800 - 3600])  // :789
        let zoned = Self.mkEntry(#""2026-10-12T21:00:00+02:00""#, v, nil)
        let frac = Self.mkEntry(#""2026-10-12T20:00:00.75Z""#, v, nil)
        let minus = Self.mkEntry(#""2026-10-12T14:00:00-05:00""#, v, nil)
        try Self.expectTimes(Self.docOf(zoned, frac, e2, minus), [t0, t0 + 3600, t0 + 7200])
        // Without a usable value: skipped; precipitation only: kept (test-metno.c:799-831).
        let junk = Self.docOf(
            "{\"time\":\(q0)}",
            "{\"time\":\(q0),\"data\":null}",
            "{\"time\":\(q0),\"data\":[]}",
            "{\"time\":\(q0),\"data\":{}}",
            "{\"time\":\(q0),\"data\":{\"instant\":{}}}",
            "{\"time\":\(q0),\"data\":{\"instant\":{\"details\":[1]}}}",
            Self.mkEntry(q0, "", nil),
            Self.mkEntry(q0, #""air_pressure_at_sea_level":1013,"wind_from_direction":55"#, nil),
            Self.mkEntry(
                q0,
                #""air_temperature":999,"cloud_area_fraction":-1,"relative_humidity":101,"#
                    + #""wind_speed":-3,"wind_speed_of_gust":"fast","apparent_air_temperature":null"#,
                #""precipitation_amount":-1"#),
            e1)
        try Self.expectTimes(junk, [t0 + 3600])
        let precipOnly = Self.mkEntry(q0, "", #""precipitation_amount":0.3"#)
        let member = try Self.parseOK(Self.docOf(precipOnly, e1))
        try #require(member.hours.count == 2)
        #expect(member.hours[0].precipMm == 0.3)  // test-metno.c:825
        #expect(member.hours[0].tempC.isNaN)
        #expect(member.hours[0].windKmh.isNaN)
        #expect(member.hours[1].tempC == 20)
        #expect(member.hours[1].precipMm.isNaN)
        // A next_1_hours that is no object (or lacks details) (test-metno.c:832-858).
        let odd1 = "{\"time\":\(q0),\"data\":{\"instant\":{\"details\":{\"air_temperature\":21}},\"next_1_hours\":5}}"
        let odd2 = "{\"time\":\(q1),\"data\":{\"instant\":{\"details\":{\"air_temperature\":22}},\"next_1_hours\":{}}}"
        let odd3 =
            "{\"time\":\(q2),\"data\":{\"instant\":{\"details\":{\"air_temperature\":23}},\"next_1_hours\":"
            + "{\"details\":{\"precipitation_amount\":\"1\"}}}}"
        let odd = try Self.parseOK(Self.docOf(odd1, odd2, odd3))
        try #require(odd.hours.count == 3)
        for i in 0..<3 {
            #expect(odd.hours[i].tempC == 21 + Double(i))
            #expect(odd.hours[i].precipMm.isNaN)
        }
    }

    /// Variable (test-metno.c:861-867).
    private struct Variable {
        let field: String
        let inNext: Bool
        let factor: Double
        let value: KeyPath<WxHour, Double>
        let carrier: String
    }

    /// assert_value_case (test-metno.c:867-882).
    private static func expectValue(
        _ v: Variable, _ literal: String, _ want: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let memberText = "\"\(v.field)\":" + literal
        let instant = v.inNext ? v.carrier : v.carrier + "," + memberText
        let entry = mkEntry(quotedISO(at(2026, 10, 12, 19)), instant, v.inNext ? memberText : nil)
        let member = try parseOK(docOf(entry))
        expectInvariants(member, sourceLocation: sourceLocation)
        try #require(member.hours.count == 1, sourceLocation: sourceLocation)
        expectSame(member.hours[0][keyPath: v.value], want, "\(v.field)=\(literal)", sourceLocation: sourceLocation)
    }

    // C: /metno/parse/value-ranges (test-metno.c:885-968)
    @Test func parseValueRanges() throws {
        let temp = Variable(
            field: "air_temperature", inNext: false, factor: 1.0, value: \.tempC, carrier: #""relative_humidity":50"#)
        let feels = Variable(
            field: "apparent_air_temperature", inNext: false, factor: 1.0, value: \.feelsC,
            carrier: #""relative_humidity":50"#)
        let cloud = Variable(
            field: "cloud_area_fraction", inNext: false, factor: 1.0, value: \.cloudPct,
            carrier: #""air_temperature":20"#)
        let humidity = Variable(
            field: "relative_humidity", inNext: false, factor: 1.0, value: \.humidityPct,
            carrier: #""air_temperature":20"#)
        let wind = Variable(
            field: "wind_speed", inNext: false, factor: 3.6, value: \.windKmh, carrier: #""air_temperature":20"#)
        let gust = Variable(
            field: "wind_speed_of_gust", inNext: false, factor: 3.6, value: \.gustKmh,
            carrier: #""air_temperature":20"#)
        let precip = Variable(
            field: "precipitation_amount", inNext: true, factor: 1.0, value: \.precipMm,
            carrier: #""air_temperature":20"#)
        let garbage = [
            #""20""#, "true", "false", "null", "[20]", "{}", "[]", #""""#, "1e999", "-1e999",
            "9223372036854775807", "-9223372036854775808", "18446744073709551615", "1e308", "-1e308",
            "1.7976931348623157e308", "-1.7976931348623157e308",
        ]  // test-metno.c:899-903
        for v in [temp, feels, cloud, humidity, wind, gust, precip] {
            for g in garbage {
                try Self.expectValue(v, g, .nan)
            }
            try Self.expectValue(v, "-0.0", 0.0)  // test-metno.c:908-912
            try Self.expectValue(v, "-0", 0.0)
            try Self.expectValue(v, "0", 0.0)
            try Self.expectValue(v, "0.0e5", 0.0)
            try Self.expectValue(v, "-0.0E-3", 0.0)
        }
        // Temperatures: -100..70 inclusive (test-metno.c:914-929).
        for v in [temp, feels] {
            try Self.expectValue(v, "-100", -100.0)
            try Self.expectValue(v, "-100.0", -100.0)
            try Self.expectValue(v, "70", 70.0)
            try Self.expectValue(v, "70.0", 70.0)
            try Self.expectValue(v, "20.5", 20.5)
            try Self.expectValue(v, "-40.25", -40.25)
            try Self.expectValue(v, "-100.0000001", .nan)
            try Self.expectValue(v, "70.0000001", .nan)
            try Self.expectValue(v, "-101", .nan)
            try Self.expectValue(v, "71", .nan)
            try Self.expectValue(v, "4.9e-324", 4.9e-324)
            try Self.expectValue(v, "-4.9e-324", -4.9e-324)
            try Self.expectValue(v, "2.2250738585072014e-308", 2.2250738585072014e-308)
        }
        // Percentages: 0..100 inclusive (test-metno.c:931-941).
        for v in [cloud, humidity] {
            try Self.expectValue(v, "100", 100.0)
            try Self.expectValue(v, "100.0", 100.0)
            try Self.expectValue(v, "49.2", 49.2)
            try Self.expectValue(v, "100.0000001", .nan)
            try Self.expectValue(v, "101", .nan)
            try Self.expectValue(v, "-0.0000001", .nan)
            try Self.expectValue(v, "-1", .nan)
            try Self.expectValue(v, "4.9e-324", 4.9e-324)
        }
        // Speeds: m/s times 3.6, result 0..500 km/h (test-metno.c:943-956).
        for v in [wind, gust] {
            try Self.expectValue(v, "1", 1 * 3.6)
            try Self.expectValue(v, "5.8", 5.8 * 3.6)
            try Self.expectValue(v, "100", 100 * 3.6)
            try Self.expectValue(v, "138.8", 138.8 * 3.6)  // 499.68 km/h
            try Self.expectValue(v, "138.9", .nan)  // 500.04 km/h
            try Self.expectValue(v, "500", .nan)
            try Self.expectValue(v, "-0.1", .nan)
            try Self.expectValue(v, "-4.9e-324", .nan)
            try Self.expectValue(v, "4.9e-324", 4.9e-324 * 3.6)
            try Self.expectValue(v, "1e-300", 1e-300 * 3.6)
            try Self.expectValue(v, "5e307", .nan)  // the product overflows to infinity
        }
        // Precipitation: 0..500 mm (test-metno.c:958-967).
        try Self.expectValue(precip, "500", 500.0)
        try Self.expectValue(precip, "500.0", 500.0)
        try Self.expectValue(precip, "0.1", 0.1)
        try Self.expectValue(precip, "12", 12.0)
        try Self.expectValue(precip, "500.0000001", .nan)
        try Self.expectValue(precip, "501", .nan)
        try Self.expectValue(precip, "-0.0000001", .nan)
        try Self.expectValue(precip, "-1", .nan)
        try Self.expectValue(precip, "4.9e-324", 4.9e-324)
    }

    // C: /metno/parse/gust (test-metno.c:971-989)
    @Test func parseGust() throws {
        let q = Self.quotedISO(Self.at(2026, 10, 12, 19))
        let m1 = try Self.parseOK(Self.docOf(Self.mkEntry(q, #""wind_speed":5,"wind_speed_of_gust":9.5"#, nil)))
        try #require(m1.hours.count == 1)
        #expect(m1.hours[0].windKmh == 5 * 3.6)  // test-metno.c:980
        #expect(m1.hours[0].gustKmh == 9.5 * 3.6)  // test-metno.c:981
        // A gust below the wind is kept as given.
        let m2 = try Self.parseOK(Self.docOf(Self.mkEntry(q, #""wind_speed":9,"wind_speed_of_gust":2"#, nil)))
        try #require(m2.hours.count == 1)
        #expect(m2.hours[0].windKmh == 9 * 3.6)  // test-metno.c:987
        #expect(m2.hours[0].gustKmh == 2 * 3.6)  // test-metno.c:988
    }

    // C: /metno/parse/hour-cap (test-metno.c:992-1032)
    @Test func parseHourCap() throws {
        let t0 = Self.at(2026, 10, 12, 0)
        let entries = (0..<1000).map { i in
            Self.mkEntry(Self.quotedISO(t0 + Int64(i) * 3600), #""air_temperature":20"#, nil)
        }
        let member = try Self.parseOK(Self.mkDoc(nil, entries))
        Self.expectInvariants(member)
        #expect(member.hours.count == 400)  // test-metno.c:1005 (WX_MEMBER_MAX_HOURS), :1013
        #expect(member.hours.first?.tS == t0)
        #expect(member.hours.last?.tS == t0 + Int64(400 - 1) * 3600)
        // Exactly 400 and 399 elements (test-metno.c:1008-1018).
        #expect(try Self.parseOK(Self.mkDoc(nil, Array(entries.prefix(400)))).hours.count == 400)
        #expect(try Self.parseOK(Self.mkDoc(nil, Array(entries.prefix(399)))).hours.count == 399)
        // Dropped elements do not count towards the cap (test-metno.c:1019-1031).
        var mixed = Array(repeating: #"{"time":"bad"}"#, count: 500)
        mixed += entries.prefix(450)
        let mm = try Self.parseOK(Self.mkDoc(nil, mixed))
        #expect(mm.hours.count == 400)
        #expect(mm.hours.first?.tS == t0)
    }

    // C: /metno/parse/fetched-time (test-metno.c:1035-1058)
    @Test func parseFetchedTime() throws {
        let good = Array(Self.docOf(Self.mkEntry(#""2026-10-12T19:00:00Z""#, #""air_temperature":20"#, nil)).utf8)
        let bad: [Int64] = [
            0, -1, WxLimits.timeMinS - 1, WxLimits.timeMaxS, WxLimits.timeMaxS + 1, Int64.min, Int64.max,
        ]  // test-metno.c:1039
        for b in bad {
            // Checked before the body is looked at: a garbage body gives the same error.
            Self.expectFailure(good, fetchedS: b, .invalidArg, "fetch time out of range")
            Self.expectFailure(Array("garbage".utf8), fetchedS: b, .invalidArg, "fetch time out of range")
        }
        for fine in [WxLimits.timeMinS, WxLimits.timeMaxS - 1, 1_791_831_600] {  // test-metno.c:1049
            let member = try METNorwayParse.parseForecast(good, fetchedS: fine)
            #expect(member.fetchedS == fine)
        }
        #expect((try? METNorwayParse.parseForecast(Array("{}".utf8), fetchedS: 1_791_831_600)) == nil)  // test-metno.c:1057
    }

    // C: /metno/parse/null-and-programmer-errors (test-metno.c:1061-1073), the
    // behavioural half: an empty body is data ("empty response"). The NULL-with-
    // length critical (GLIB-INTERNAL) has no Swift counterpart.
    @Test func parseEmptyBody() {
        Self.expectFailure([UInt8](), .parse, "empty response")  // test-metno.c:1065-1066
        do {
            _ = try METNorwayParse.parseForecast(Data(), fetchedS: Self.nowS())
            Issue.record("empty Data parsed")
        } catch {
            #expect(error.code == .parse && error.message == "empty response")
        }
    }

    // C: /metno/parse/guard-page (test-metno.c:1076-1103), the behavioural half:
    // every prefix of the document fails with PARSE, the whole one and a tiny one
    // parse. The PROT_NONE guard page itself is GLIB-INTERNAL (memory layout);
    // Swift collections are bounds-checked.
    @Test func parsePrefixesAndTinyDocument() throws {
        let miami = try Self.fixture("complete_miami.json")
        _ = try METNorwayParse.parseForecast(miami, fetchedS: Self.nowS())
        for cut in [0, 1, 2, 5, 17, 100, 1000, 4095, 4096, 4097, 30000, 64000] {  // test-metno.c:1084
            let n = min(cut, miami.count - 1)
            do {
                _ = try METNorwayParse.parseForecast(miami.prefix(n), fetchedS: Self.nowS())
                Issue.record("prefix \(n) parsed")
            } catch {
                #expect(error.code == .parse, "prefix \(n)")
            }
        }
        let tiny =
            #"{"properties":{"timeseries":[{"time":"2026-10-12T19:00:00Z","#
            + #""data":{"instant":{"details":{"air_temperature":1}}}}]}}"#
        _ = try Self.parseOK(tiny)
    }

    // C: /metno/parse/size-limits (test-metno.c:1106-1129)
    @Test func parseSizeLimits() {
        let blank = [UInt8](repeating: UInt8(ascii: " "), count: HTTPPolicy.maxBodyBytes + 1)
        Self.expectFailure(blank, .parse, "response too large")  // test-metno.c:1114
        var deep = #"{"properties":"#
        deep += String(repeating: #"{"a":"#, count: 40) + "1" + String(repeating: "}", count: 40) + "}"
        Self.expectFailure(deep, .parse, "malformed JSON")  // test-metno.c:1126
    }

    // C: /metno/parse/json-limits (test-metno.c:1132-1174)
    @Test func parseJSONLimits() throws {
        let q = Self.quotedISO(Self.at(2026, 10, 12, 19))
        for n in 1023...1026 {
            var instant = #""air_temperature":20"#
            for i in 1..<n {
                instant += ",\"k\(i)\":\(i)"
            }
            let text = Self.docOf(Self.mkEntry(q, instant, nil))
            if n <= 1024 {  // WX_JSON_PARSE_MAX_MEMBERS
                #expect(try Self.parseOK(text).hours.first?.tempC == 20)  // test-metno.c:1144
            } else {
                Self.expectFailure(text, .parse, "malformed JSON")
            }
        }
        for arrays in 27...30 {
            let extra = String(repeating: "[", count: arrays) + "1" + String(repeating: "]", count: arrays)
            let text =
                "{\"properties\":{\"timeseries\":[{\"time\":\(q),\"extra\":\(extra),\"data\":{\"instant\":{\"details\":"
                + "{\"air_temperature\":20}}}}]}}"
            if 4 + arrays <= 32 {  // WX_JSON_PARSE_MAX_DEPTH (test-metno.c:1163)
                Self.expectInvariants(try Self.parseOK(text))
            } else {
                Self.expectFailure(text, .parse, "malformed JSON")
            }
        }
    }

    // MARK: parse/ fuzzing (test-metno.c:1176-1467)

    /// ModelEntry (test-metno.c:1185-1189).
    private struct ModelEntry {
        var timeOK = false
        var tS: Int64 = 0
        var v: [Double] = Array(repeating: .nan, count: 7)
    }

    /// g_ascii_dtostr ("%.17g", '.' whatever the locale).
    private static func dtostr(_ v: Double) -> String {
        String(format: "%.17g", v)
    }

    /// random_value (test-metno.c:1193-1234).
    private static func randomValue(
        _ rng: inout SeededRNG, _ factor: Double, _ lo: Double, _ hi: Double, _ expected: inout Double
    ) -> String {
        expected = .nan
        switch Int.random(in: 0..<14, using: &rng) {
        case 0: return "null"
        case 1: return #""12""#
        case 2: return "true"
        case 3: return "[1]"
        case 4: return "1e999"
        case 5:
            var v =
                (Bool.random(using: &rng) ? 1.0 : -1.0) * (hi - lo + 1.0)
                * (1.0 + Double.random(in: 0..<1, using: &rng) * 1000.0)
            if lo >= 0 && v > 0 {
                v += hi / factor
            }
            return dtostr(v)
        default:
            var conv = lo + (hi - lo) * Double.random(in: 0..<1, using: &rng)
            if Int.random(in: 0..<8, using: &rng) == 0 {
                conv = Bool.random(using: &rng) ? lo : hi
            }
            var raw = conv / factor
            var product = raw * factor
            if !(product >= lo && product <= hi) {
                raw = raw > 0 ? raw.nextDown : (raw < 0 ? raw.nextUp : raw)  // nextafter(raw, 0.0)
                product = raw * factor
            }
            if !(product >= lo && product <= hi) {
                return "null"
            }
            expected = product == 0.0 ? 0.0 : product
            return dtostr(raw)
        }
    }

    /// random_document (test-metno.c:1238-1351).
    private static func randomDocument(_ rng: inout SeededRNG, _ want: inout [ModelEntry]) -> String {
        let lows: [Double] = [WxLimits.tempMinC, WxLimits.tempMinC, 0, 0, 0, 0, 0]
        let highs: [Double] = [
            WxLimits.tempMaxC, WxLimits.tempMaxC, 100, 100, WxLimits.windMaxKmh, WxLimits.windMaxKmh,
            WxLimits.precipMaxMmH,
        ]
        let factors: [Double] = [1, 1, 1, 1, 3.6, 3.6, 1]
        let names = [
            "air_temperature", "apparent_air_temperature", "cloud_area_fraction", "relative_humidity", "wind_speed",
            "wind_speed_of_gust", "precipitation_amount",
        ]
        let n = Int.random(in: 0..<60, using: &rng) + (Int.random(in: 0..<20, using: &rng) == 0 ? 450 : 0)
        var entries: [String] = []
        var t = at(2026, 10, 12, 0) + Int64(Int.random(in: -50..<50, using: &rng)) * 3600
        var lastAccepted = Int64.min
        var accepted = 0
        for _ in 0..<n {
            var m = ModelEntry()
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: break
            case 1: t -= Int64(Int.random(in: 1..<4, using: &rng)) * 3600
            case 2: t += Int64(Int.random(in: 5..<50, using: &rng)) * 3600
            default: t += Int64(Int.random(in: 1..<4, using: &rng)) * 3600
            }
            let stamp = t
            let timeJSON: String
            switch Int.random(in: 0..<14, using: &rng) {
            case 0: timeJSON = "null"
            case 1: timeJSON = "\(stamp)"
            case 2: timeJSON = quotedISO(stamp + 1800)
            case 3: timeJSON = #""not a time""#
            case 4:  // a zone offset: the same instant
                timeJSON = "\"" + isoOf(stamp + 7200).dropLast() + "+02:00\""
                m.timeOK = true
            default:
                timeJSON = quotedISO(stamp)
                m.timeOK = true
            }
            m.tS = stamp
            var instant = ""
            var next = ""
            for k in 0..<7 {
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    continue
                }
                var expected = Double.nan
                let literal = randomValue(&rng, factors[k], lows[k], highs[k], &expected)
                m.v[k] = expected
                if k == 6 {
                    next += (next.isEmpty ? "" : ",") + "\"\(names[k])\":" + literal
                } else {
                    instant += (instant.isEmpty ? "" : ",") + "\"\(names[k])\":" + literal
                }
            }
            let entry: String
            var structural = true
            switch Int.random(in: 0..<25, using: &rng) {
            case 0:
                entry = "7"
                structural = false
            case 1:
                entry = "null"
                structural = false
            case 2:
                entry = "{\"time\":\(timeJSON),\"data\":null}"
                structural = false
            case 3:
                entry = "{\"time\":\(timeJSON),\"data\":{\"instant\":[]}}"
                structural = false
            default:
                let omitNext = Int.random(in: 0..<5, using: &rng) == 0 && next.isEmpty
                entry = mkEntry(timeJSON, instant, omitNext ? nil : next)
            }
            if structural && m.timeOK && stamp % 3600 == 0 && stamp > lastAccepted {
                if m.v.contains(where: { !$0.isNaN }) && accepted < 400 {
                    want.append(m)
                    lastAccepted = stamp
                    accepted += 1
                }
            }
            entries.append(entry)
        }
        return mkDoc(nil, entries)
    }

    // C: /metno/parse/fuzz-model (test-metno.c:1354-1389); GRand seed 0x57584d4e -> SeededRNG.
    @Test func parseFuzzModel() throws {
        var rng = SeededRNG(seed: 0x5758_4d4e)
        let iterations = fuzzIterations(1500)  // test-metno.c:1357
        var successes = 0
        for it in 0..<iterations {
            var want: [ModelEntry] = []
            let text = Self.randomDocument(&rng, &want)
            let member: WxMember
            do {
                member = try Self.parse(text)
            } catch {
                #expect(want.isEmpty, "iteration \(it): \(error.message)")
                #expect(error.code == .parse && error.message == "no usable forecast data", "iteration \(it)")
                continue
            }
            try #require(!want.isEmpty, "iteration \(it): parsed although the model expects failure")
            successes += 1
            Self.expectInvariants(member)
            try #require(member.hours.count == want.count, "iteration \(it)")
            for (i, m) in want.enumerated() {
                let h = member.hours[i]
                #expect(h.tS == m.tS, "iteration \(it) hour \(i)")
                Self.expectSame(h.tempC, m.v[0], "it \(it) h \(i) temp")
                Self.expectSame(h.feelsC, m.v[1], "it \(it) h \(i) feels")
                Self.expectSame(h.cloudPct, m.v[2], "it \(it) h \(i) cloud")
                Self.expectSame(h.humidityPct, m.v[3], "it \(it) h \(i) humidity")
                Self.expectSame(h.windKmh, m.v[4], "it \(it) h \(i) wind")
                Self.expectSame(h.gustKmh, m.v[5], "it \(it) h \(i) gust")
                Self.expectSame(h.precipMm, m.v[6], "it \(it) h \(i) precip")
            }
        }
        #expect(successes > iterations / 4)  // test-metno.c:1388
    }

    // C: /metno/parse/fuzz-mutations (test-metno.c:1403-1467); GRand seed 0x4d555441 -> SeededRNG.
    @Test func parseFuzzMutations() throws {
        var rng = SeededRNG(seed: 0x4d55_5441)
        let iterations = fuzzIterations(300)  // test-metno.c:1406
        // test-metno.c:1407-1409, as bytes: "\\u0000" is the six-byte TEXT
        // backslash-u-0-0-0-0; "\xff" and "\xed\xa0\x80" are raw bytes.
        let tokens: [[UInt8]] = [
            Array("null".utf8), Array("1e999".utf8), Array("-1".utf8), [0x22], [0x7B], [0x7D], [0x5B], [0x5D],
            [0x2C], [0x3A], [0x5C, 0x75, 0x30, 0x30, 0x30, 0x30], Array("99999999999999999999".utf8),
            [0x22, 0x74, 0x69, 0x6D, 0x65, 0x22], [0x22, 0x64, 0x61, 0x74, 0x61, 0x22], Array("0.5e-400".utf8),
            [0xFF], [0xED, 0xA0, 0x80], [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D], Array("[[[[[[[[[[".utf8),
            [0x20],
        ]
        let sources = [try Self.fixture("complete_miami.json"), try Self.fixture("complete_london.json")]
        var ok = 0
        for it in 0..<iterations {
            var buf = sources[it % 2]
            let edits = Int.random(in: 1..<6, using: &rng)
            var e = 0
            while e < edits && !buf.isEmpty {
                let pos = Int.random(in: 0..<buf.count, using: &rng)
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    buf[pos] = UInt8(Int.random(in: 0..<256, using: &rng))
                case 1:
                    buf[pos] ^= UInt8(1) << UInt8(Int.random(in: 0..<8, using: &rng))
                case 2:
                    let len = min(Int.random(in: 1..<400, using: &rng), buf.count - pos)
                    buf.removeSubrange(pos..<(pos + len))
                case 3:
                    buf.insert(contentsOf: tokens[Int.random(in: 0..<tokens.count, using: &rng)], at: pos)
                case 4:
                    buf.removeSubrange(pos...)
                default:
                    let len = min(Int.random(in: 1..<300, using: &rng), buf.count - pos)
                    let chunk = Array(buf[pos..<(pos + len)])
                    buf.insert(contentsOf: chunk, at: Int.random(in: 0..<buf.count, using: &rng))
                }
                e += 1
            }
            do {
                let member = try METNorwayParse.parseForecast(buf, fetchedS: Self.nowS())
                Self.expectInvariants(member)
                ok += 1
            } catch {
                #expect(error.code == .parse, "iteration \(it): \(error.code)")
            }
        }
        #expect(ok > 0)  // test-metno.c:1466
    }

    // MARK: Executor-added: pure provider rules of wx-metno.c (CX rows)

    // wx-metno.h:30-35: the cache key is the two "%.4f" texts; 25.76170 and
    // 25.76174 are the same place (both print 25.7617), 25.76176 is another
    // one (it prints 25.7618).
    @Test func cacheKeyIsTheRoundedCoordinates() {
        #expect(METNorwayParse.cacheKey(lat: 25.76170, lon: -80.1918) == "25.7617,-80.1918")
        #expect(
            METNorwayParse.cacheKey(lat: 25.76174, lon: -80.1918)
                == METNorwayParse.cacheKey(lat: 25.76170, lon: -80.1918))
        #expect(METNorwayParse.cacheKey(lat: 25.76176, lon: -80.1918) == "25.7618,-80.1918")
        #expect(METNorwayParse.cacheKey(lat: -0.0, lon: -0.00004) == "0.0000,0.0000")  // test-metno.c:310-311
        #expect(METNorwayParse.cacheKey(lat: 90.0000001, lon: 0) == nil)
        #expect(METNorwayParse.accept == "application/json")  // wx-metno.c:18
    }

    // wx-metno.c:359-365 and wx-metno.h:42-53: fresh while fewer than 600 s
    // have passed since the answer, or before its Expires; never when the
    // answer lies in the future of the clock.
    @Test func entryFreshness() {
        let t: Int64 = 1_791_831_600
        #expect(METNorwayParse.entryIsFresh(nowS: t, checkedS: t, expiresS: 0))
        #expect(METNorwayParse.entryIsFresh(nowS: t + 599, checkedS: t, expiresS: 0))
        #expect(!METNorwayParse.entryIsFresh(nowS: t + 600, checkedS: t, expiresS: 0))
        #expect(METNorwayParse.entryIsFresh(nowS: t + 3599, checkedS: t, expiresS: t + 3600))
        #expect(!METNorwayParse.entryIsFresh(nowS: t + 3600, checkedS: t, expiresS: t + 3600))
        #expect(!METNorwayParse.entryIsFresh(nowS: t - 1, checkedS: t, expiresS: t + 3600))
    }

    // wx-metno.c:22 and :509: an Expires time is never honoured for longer than
    // 86400 s after the answer; 0 (none) stays 0.
    @Test func expiresIsCappedAt24Hours() {
        let t: Int64 = 1_791_831_600
        #expect(METNorwayParse.expiresMaxS == 86400)
        #expect(METNorwayParse.storedExpiresS(0, answerS: t) == 0)
        #expect(METNorwayParse.storedExpiresS(-5, answerS: t) == 0)
        #expect(METNorwayParse.storedExpiresS(t + 3600, answerS: t) == t + 3600)
        #expect(METNorwayParse.storedExpiresS(t + 86400, answerS: t) == t + 86400)
        #expect(METNorwayParse.storedExpiresS(t + 86401, answerS: t) == t + 86400)
        // The value comes from the HTTP layer's parser (HTTPPolicy.parseExpires); a
        // date in the past of its clock is implausible (wx-http.h: now < t <= now + 86400).
        #expect(HTTPPolicy.parseExpires("Mon, 12 Oct 2026 19:00:00 GMT", nowS: t + 1) == 0)
        #expect(HTTPPolicy.parseExpires("Mon, 12 Oct 2026 20:00:00 GMT", nowS: t) == t + 3600)
    }

    // wx-metno.c:534-541 and wx-metno.h:76-80: the floor ends exactly 600 s after
    // the record (+599 held back, +600 may send); a record in the future does not apply.
    @Test func requestFloor() {
        let t: Int64 = 1_791_831_600
        #expect(!METNorwayParse.floorApplies(nowS: t, sentS: nil))
        #expect(METNorwayParse.floorApplies(nowS: t, sentS: t))
        #expect(METNorwayParse.floorApplies(nowS: t + 599, sentS: t))
        #expect(!METNorwayParse.floorApplies(nowS: t + 600, sentS: t))
        #expect(!METNorwayParse.floorApplies(nowS: t - 1, sentS: t))
        #expect(METNorwayParse.Message.floorRefused == "a request for this place was sent less than 10 minutes ago")
    }

    // wx-metno.c:981, :1177 and wx-metno.h:106-114: 60 s without requests after a
    // 429; a clock that reads earlier than the 429 answer lifts the throttle.
    @Test func throttleAfter429() {
        let t: Int64 = 1_791_831_600
        let until = METNorwayParse.throttleUntilS(answeredAtS: t)
        #expect(until == t + 60)
        #expect(METNorwayParse.throttleApplies(nowS: t, untilS: until))
        #expect(METNorwayParse.throttleApplies(nowS: t + 59, untilS: until))
        #expect(!METNorwayParse.throttleApplies(nowS: t + 60, untilS: until))
        #expect(!METNorwayParse.throttleApplies(nowS: t - 1, untilS: until))
        #expect(!METNorwayParse.throttleApplies(nowS: t, untilS: 0))
        #expect(METNorwayParse.Message.throttled == "requests are paused after HTTP 429")
        // clock_now_s clamps to [0, G_MAXINT64 / 4] (wx-metno.c:60-69).
        #expect(METNorwayParse.clampedClockS(-5) == 0)
        #expect(METNorwayParse.clampedClockS(Int64.max) == Int64.max / 4)
        #expect(METNorwayParse.clampedClockS(t) == t)
    }

    // wx-metno.c:932-936: after a 304 that revalidated a cached member the sent
    // If-Modified-Since is kept when the answer carries no Last-Modified.
    @Test func lastModifiedAfterRevalidation() {
        let ims = "Mon, 12 Oct 2026 19:19:33 GMT"
        let lm = "Mon, 12 Oct 2026 20:19:33 GMT"
        #expect(
            METNorwayParse.lastModifiedToStore(
                status: 304, revalidated: true, responseLastModified: nil, sentIfModifiedSince: ims) == ims)
        #expect(
            METNorwayParse.lastModifiedToStore(
                status: 304, revalidated: true, responseLastModified: lm, sentIfModifiedSince: ims) == lm)
        #expect(
            METNorwayParse.lastModifiedToStore(
                status: 200, revalidated: true, responseLastModified: nil, sentIfModifiedSince: ims) == nil)
        #expect(
            METNorwayParse.lastModifiedToStore(
                status: 304, revalidated: false, responseLastModified: nil, sentIfModifiedSince: ims) == nil)
    }
}
