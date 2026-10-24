// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// NWSParseTests.swift - port of the /nws/points/ and /nws/grid/ groups of
// src/providers/nws/test-nws.c (test functions at test-nws.c:252-1466,
// registrations at :2752-2776). Every test's display name is the C
// g_test_add path. Expected values are the C literals (cited path:line).
// JSON inputs keep the C bytes: C escapes that Swift spells the same way
// (\" \\ \n) are copied verbatim, so the C "M\\u00c9L" is the six-character
// backslash-u text here too; C \xNN bytes are written as byte arrays.
//
// The C fuzz tests keep their oracles and iteration counts; SeededRNG replaces
// GRand (DECISIONS #17), so the exact random sequences differ from C.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct NWSParseTests {
    // MARK: - Constants (test-nws.c:40-45, wx-types.h:90-92, wx-http.h:282)

    /// T0, 2026-10-12T12:00:00Z (test-nws.c:40).
    private static let t0: Int64 = 1_791_806_400
    /// HOUR (test-nws.c:41).
    private static let hour: Int64 = 3600
    /// MSG_NO_GRID (test-nws.c:43).
    private static let msgNoGrid = "no valid forecast grid in response"
    /// MSG_NO_PROPS (test-nws.c:44).
    private static let msgNoProps = "response has no properties"
    /// MSG_NO_DATA (test-nws.c:45).
    private static let msgNoData = "response has no usable forecast"
    /// WX_HTTP_MAX_BODY_BYTES (src/net/wx-http.h:282).
    private static let bodyCap = 4 * 1024 * 1024
    /// WX_TIME_MIN_S / WX_TIME_MAX_S (src/core/wx-types.h:90, :92).
    private static let timeMinS: Int64 = 946_684_800
    private static let timeMaxS: Int64 = 4_133_980_800
    /// WX_MEMBER_MAX_HOURS.
    private static let maxHours = 400

    // MARK: - Layers (kLayers, test-nws.c:407-416)

    private struct LayerInfo {
        let name: String
        let uom: String
        let total: Bool
    }

    private static let kLayers: [LayerInfo] = [
        LayerInfo(name: "temperature", uom: "wmoUnit:degC", total: false),
        LayerInfo(name: "apparentTemperature", uom: "wmoUnit:degC", total: false),
        LayerInfo(name: "relativeHumidity", uom: "wmoUnit:percent", total: false),
        LayerInfo(name: "skyCover", uom: "wmoUnit:percent", total: false),
        LayerInfo(name: "windSpeed", uom: "wmoUnit:km_h-1", total: false),
        LayerInfo(name: "windGust", uom: "wmoUnit:km_h-1", total: false),
        LayerInfo(name: "probabilityOfPrecipitation", uom: "wmoUnit:percent", total: false),
        LayerInfo(name: "quantitativePrecipitation", uom: "wmoUnit:mm", total: true),
    ]

    /// field_of (test-nws.c:418-422): the WxHour field layer `k` fills.
    private static func field(_ h: WxHour, _ k: Int) -> Double {
        switch k {
        case 0: return h.tempC
        case 1: return h.feelsC
        case 2: return h.humidityPct
        case 3: return h.cloudPct
        case 4: return h.windKmh
        case 5: return h.gustKmh
        case 6: return h.precipProb
        default: return h.precipMm
        }
    }

    private static func layerIndex(_ name: String) -> Int {
        kLayers.firstIndex { $0.name == name } ?? -1
    }

    // MARK: - Helpers (test-nws.c:48-249)

    private static func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// same_double (test-nws.c:117-121): NaNs equal, -0.0 == +0.0.
    private static func same(_ a: Double, _ b: Double) -> Bool {
        (a.isNaN && b.isNaN) || a == b
    }

    /// hour_at (test-nws.c:106-115).
    private static func hourAt(_ m: WxMember, _ t: Int64) -> WxHour? {
        m.hours.first { $0.tS == t }
    }

    /// check_member (test-nws.c:138-169): the documented invariants of a member.
    private static func checkMember(_ m: WxMember, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(m.sourceID == "nws", sourceLocation: sourceLocation)
        #expect(m.modelID == "nws", sourceLocation: sourceLocation)
        #expect(m.hours.count >= 1 && m.hours.count <= maxHours, sourceLocation: sourceLocation)
        #expect(m.quarters.isEmpty, sourceLocation: sourceLocation)
        for (i, h) in m.hours.enumerated() {
            let ok =
                h.tS % hour == 0 && (i == 0 || h.tS > m.hours[i - 1].tS) && h.wmo == -1
                && [h.tempC, h.feelsC, h.precipMm, h.precipProb, h.cloudPct, h.windKmh, h.gustKmh,
                    h.humidityPct].contains { $0.isFinite }
                && (WxLimits.valueInRange(h.tempC, -100, 70) || h.tempC.isNaN)
                && (WxLimits.valueInRange(h.feelsC, -100, 70) || h.feelsC.isNaN)
                && (WxLimits.valueInRange(h.windKmh, 0, 500) || h.windKmh.isNaN)
                && (WxLimits.valueInRange(h.gustKmh, 0, 500) || h.gustKmh.isNaN)
                && (WxLimits.valueInRange(h.precipMm, 0, 500) || h.precipMm.isNaN)
                && (WxLimits.valueInRange(h.precipProb, 0, 100) || h.precipProb.isNaN)
                && (WxLimits.valueInRange(h.cloudPct, 0, 100) || h.cloudPct.isNaN)
                && (WxLimits.valueInRange(h.humidityPct, 0, 100) || h.humidityPct.isNaN)
            #expect(ok, "hour \(i) breaks the member invariants: \(h)", sourceLocation: sourceLocation)
        }
    }

    /// parse_grid (test-nws.c:171-180): the body must parse.
    private static func parseGrid(
        _ body: some Collection<UInt8>, _ fetchedS: Int64, sourceLocation: SourceLocation = #_sourceLocation
    ) -> WxMember? {
        do {
            let m = try NWSParse.parseGridpoints(body, fetchedS: fetchedS)
            checkMember(m, sourceLocation: sourceLocation)
            return m
        } catch {
            Issue.record("rejected: \(error.code) \(error.message)", sourceLocation: sourceLocation)
            return nil
        }
    }

    private static func parseGrid(
        _ body: String, _ fetchedS: Int64, sourceLocation: SourceLocation = #_sourceLocation
    ) -> WxMember? {
        parseGrid(b(body), fetchedS, sourceLocation: sourceLocation)
    }

    /// assert_grid_error_len / assert_grid_error (test-nws.c:182-197), fetched_s T0.
    private static func expectGridError(
        _ body: [UInt8], _ code: WxError.Code, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let m = try NWSParse.parseGridpoints(body, fetchedS: t0)
            Issue.record("accepted with \(m.hours.count) hours, wanted \(code) \(message)",
                         sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == code && error.message == message,
                    "got \(error.code) \(error.message), wanted \(code) \(message)", sourceLocation: sourceLocation)
        }
    }

    private static func expectGridError(
        _ body: String, _ code: WxError.Code, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectGridError(b(body), code, message, sourceLocation: sourceLocation)
    }

    /// assert_points_error_len / assert_points_error (test-nws.c:199-216). The
    /// C check that the out-grid stays untouched has no Swift counterpart: a
    /// throwing function returns no grid.
    private static func expectPointsError(
        _ body: [UInt8], _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let grid = try NWSParse.parsePoints(body)
            Issue.record("accepted as \(grid), wanted \(message)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == .parse && error.message == message,
                    "got \(error.code) \(error.message), wanted \(message)", sourceLocation: sourceLocation)
        }
    }

    private static func expectPointsError(
        _ body: String, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectPointsError(b(body), message, sourceLocation: sourceLocation)
    }

    /// layer_json (test-nws.c:218-223).
    private static func layerJSON(_ name: String, _ uom: String, _ elements: String) -> String {
        "\"\(name)\":{\"uom\":\"\(uom)\",\"values\":[\(elements)]}"
    }

    /// grid_body (test-nws.c:225-229).
    private static func gridBody(_ layers: String) -> String {
        "{\"properties\":{\(layers)}}"
    }

    /// element_json (test-nws.c:231-238): "<UTC start>+00:00/<duration>".
    private static func elementJSON(_ startS: Int64, _ duration: String, _ value: String) -> String {
        "{\"validTime\":\"\(utcText(startS))+00:00/\(duration)\",\"value\":\(value)}"
    }

    /// temp_body (test-nws.c:240-246).
    private static func tempBody(_ elements: String) -> String {
        gridBody(layerJSON("temperature", "wmoUnit:degC", elements))
    }

    /// "%Y-%m-%dT%H:%M:%S" of a UTC unix time (g_date_time_format of
    /// g_date_time_new_from_unix_utc), by H. Hinnant's civil_from_days.
    private static func utcText(_ t: Int64) -> String {
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
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(secs / 3600, 2)):\(pad(secs % 3600 / 60, 2)):\(pad(secs % 60, 2))"
    }

    private static func pad(_ v: Int64, _ width: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    // MARK: - Fixtures (copied byte for byte from src/providers/nws/fixtures)

    /// The repository root, from this file's path (macos/WeatherCoreTests/Providers/).
    private static func repositoryRoot(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    // Executor case (FIXTURES acceptance criterion): the bundled fixtures and
    // their in-tree copies are byte-identical to the C fixtures.
    @Test("fixtures: points_miami.json and gridpoints_miami.json are byte-identical to src/providers/nws/fixtures",
          arguments: ["points_miami.json", "gridpoints_miami.json"])
    func fixturesAreByteIdentical(_ name: String) throws {
        let root = Self.repositoryRoot()
        let original = try Data(contentsOf: root.appendingPathComponent("src/providers/nws/fixtures/\(name)"))
        let inTree = try Data(contentsOf: root.appendingPathComponent("macos/WeatherCoreTests/Fixtures/nws/\(name)"))
        let bundled = try Fixtures.data(name)
        #expect(!original.isEmpty)
        #expect(inTree == original, "macos/WeatherCoreTests/Fixtures/nws/\(name) differs from the C fixture")
        #expect(bundled == original, "the bundled \(name) differs from the C fixture")
    }

    // MARK: - /nws/points/

    @Test("/nws/points/fixture")
    func pointsFixture() throws {
        // C: /nws/points/fixture (test-nws.c:252-265; MFL, 110, 50 at :262-264)
        let grid = try NWSParse.parsePoints(Fixtures.data("points_miami.json"))
        #expect(grid.gridID == "MFL")
        #expect(grid.x == 110)
        #expect(grid.y == 50)
    }

    // Executor case (PARSE acceptance criterion; wx-nws.h:146-147 "Everything
    // else is ignored"): a server-supplied grid URL never steers the cell.
    @Test("/nws/points/fixture: server-supplied grid URLs are ignored")
    func pointsIgnoreServerURLs() throws {
        let body = "{\"properties\":{\"forecastGridData\":\"https://evil.example/gridpoints/XYZ/1,2\","
            + "\"forecast\":\"http://127.0.0.1/gridpoints/ABC/3,4/forecast\",\"@id\":\"https://evil.example/\","
            + "\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}"
        let grid = try NWSParse.parsePoints(Self.b(body))
        #expect(grid == NWSParse.Grid(gridID: "MFL", x: 110, y: 50))
        // A URL alone is no grid cell.
        Self.expectPointsError("{\"properties\":{\"forecastGridData\":\"https://api.weather.gov/gridpoints/MFL/110,50\"}}",
                               Self.msgNoGrid)
        // The fixture's own forecastGridData agrees with its cell, but the cell comes from gridId/gridX/gridY.
        let fixture = try Fixtures.string("points_miami.json")
        let steered = fixture.replacingOccurrences(of: "\"gridId\": \"MFL\"", with: "\"gridId\": \"BOX\"")
        #expect(steered != fixture)
        #expect(try NWSParse.parsePoints(Self.b(steered)).gridID == "BOX")
    }

    @Test("/nws/points/accepts-shapes")
    func pointsAcceptsShapes() throws {
        // C: /nws/points/accepts-shapes (test-nws.c:267-290; table at :275-281)
        let cases: [(String, String, UInt32, UInt32)] = [
            ("{\"properties\":{\"gridId\":\"AAA\",\"gridX\":0,\"gridY\":0}}", "AAA", 0, 0),
            ("{\"properties\":{\"gridId\":\"ZZZ\",\"gridX\":999,\"gridY\":999}}", "ZZZ", 999, 999),
            ("{\"properties\":{\"gridId\":\"BOX\",\"gridX\":7.0,\"gridY\":1e2}}", "BOX", 7, 100),
            ("{\"x\":1,\"properties\":{\"gridY\":5,\"extra\":[1,2],\"gridX\":4,\"gridId\":\"HFO\"}}", "HFO", 4, 5),
        ]
        for (body, id, x, y) in cases {
            let grid = try NWSParse.parsePoints(Self.b(body))
            #expect(grid.gridID == id && grid.x == x && grid.y == y, "\(body) -> \(grid)")
        }
    }

    @Test("/nws/points/rejects-bad-grid")
    func pointsRejectsBadGrid() {
        // C: /nws/points/rejects-bad-grid (test-nws.c:292-329; table at :295-326)
        let bad = [
            "{}",
            "{\"properties\":null}",
            "{\"properties\":[]}",
            "{\"properties\":{}}",
            "{\"properties\":{\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1}}",
            "{\"properties\":{\"gridId\":\"mfl\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MF\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFLL\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"M/L\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"M\\u00c9L\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MF1\",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MF \",\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":5,\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":null,\"gridX\":1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":-1,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":-1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1000,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":1000}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":999.5,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1.5,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":\"1\",\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":true}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":null}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1e999,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":99999999999999999999,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":-0.5,\"gridY\":1}}",
            "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":[1],\"gridY\":1}}",
        ]
        #expect(bad.count == 30)
        for body in bad {
            Self.expectPointsError(body, Self.msgNoGrid)
        }
    }

    @Test("/nws/points/rejects-bad-json")
    func pointsRejectsBadJSON() {
        // C: /nws/points/rejects-bad-json (test-nws.c:331-355)
        Self.expectPointsError("", "empty response")
        Self.expectPointsError("[]", "response is not a JSON object")
        Self.expectPointsError("\"x\"", "response is not a JSON object")
        Self.expectPointsError("{", "malformed JSON")
        Self.expectPointsError("{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":1}} x", "malformed JSON")
        Self.expectPointsError(
            "{\"properties\":{\"gridId\":\"MFL\",\"gridId\":\"MFL\",\"gridX\":1," + "\"gridY\":1}}", "malformed JSON")
        // C "MF\xff": the byte 0xFF inside the string (test-nws.c:341).
        Self.expectPointsError(
            Self.b("{\"properties\":{\"gridId\":\"MF") + [0xFF] + Self.b("\",\"gridX\":1,\"gridY\":1}}"),
            "response is not valid UTF-8")
        let deep = "{\"a\":" + String(repeating: "[", count: 100_000)
        Self.expectPointsError(deep, "malformed JSON")
        Self.expectPointsError([UInt8](), "empty response")  // NULL, 0
        // One byte over the body cap is refused before it is examined.
        Self.expectPointsError([UInt8](repeating: 0x20, count: Self.bodyCap + 1), "response too large")
    }

    @Test("/nws/points/programmer-errors (behavioural remainder)")
    func pointsProgrammerErrors() throws {
        // C: /nws/points/programmer-errors (test-nws.c:357-375). The criticals
        // (NULL data with len > 0, NULL grid, preset error) are GLIB-INTERNAL:
        // unrepresentable in Swift. Kept: a failure and a success without an
        // error location.
        #expect((try? NWSParse.parsePoints(Self.b("{}"))) == nil)
        let grid = try #require(
            try? NWSParse.parsePoints(Self.b("{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":2}}")))
        #expect(grid.y == 2)
    }

    @Test("/nws/points/guard-page (exact-length slices)")
    func pointsGuardPage() {
        // C: /nws/points/guard-page (test-nws.c:377-394). The guard page itself
        // is GLIB-INTERNAL (memory layout); the behaviour it protects, that
        // exactly the given bytes are read, is checked by handing the parser a
        // slice of a larger buffer whose following bytes would change the
        // outcome if they were read.
        let good = "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}"
        let bodies: [(String, String)] = [
            (good, " x"),
            ("{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1", ",\"gridY\":1}}"),
            ("{", "\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":1}}"),
            ("[1,2]", "]"),
            ("{\"properties\":{\"gridId\":\"mfl\",\"gridX\":1,\"gridY\":1}}", ""),
            ("x", "}"),
        ]
        for (i, (body, tail)) in bodies.enumerated() {
            let prefix = Self.b("{\"properties\":{\"gridId\":\"AAA\",\"gridX\":1,\"gridY\":1}}")
            let buffer = Data(prefix + Self.b(body) + Self.b(tail))
            let slice = buffer[prefix.count..<(prefix.count + body.utf8.count)]
            let ok = (try? NWSParse.parsePoints(slice)) != nil
            #expect(ok == (i == 0), "body \(i)")
        }
    }

    // MARK: - /nws/grid/ over the real fixture

    /// The independent fixture oracle's view of one layer (test-nws.c:418-450):
    /// read with JSONDecoder, times with ISO8601DateFormatter, durations
    /// "PT<n>H" by hand, and a linear search per hour.
    private struct OracleElement {
        let start: Int64
        let hours: Int64
        let value: Double
    }

    private struct DecodedElement: Decodable {
        let validTime: String
        let value: Double?
    }

    private struct DecodedLayer: Decodable {
        let values: [DecodedElement]
    }

    private struct DecodedProperties: Decodable {
        let layers: [String: DecodedLayer]

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            var out: [String: DecodedLayer] = [:]
            for layer in NWSParseTests.kLayers {
                out[layer.name] = try c.decode(DecodedLayer.self, forKey: Key(stringValue: layer.name))
            }
            layers = out
        }
    }

    private struct DecodedRoot: Decodable {
        let properties: DecodedProperties
    }

    private static func oracleLayers(_ data: Data) throws -> [[OracleElement]] {
        let root = try JSONDecoder().decode(DecodedRoot.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var result: [[OracleElement]] = []
        for layer in kLayers {
            var elements: [OracleElement] = []
            for e in try #require(root.properties.layers[layer.name]).values {
                let parts = e.validTime.split(separator: "/", omittingEmptySubsequences: false)
                try #require(parts.count == 2, "validTime \(e.validTime)")
                let start = try #require(iso.date(from: String(parts[0])), "start \(parts[0])")
                let dur = parts[1]
                try #require(dur.hasPrefix("PT") && dur.hasSuffix("H"), "duration \(dur)")
                let hours = try #require(Int64(dur.dropFirst(2).dropLast()), "duration \(dur)")
                let value = try #require(e.value, "null value in \(layer.name)")
                elements.append(OracleElement(start: Int64(start.timeIntervalSince1970), hours: hours, value: value))
            }
            result.append(elements)
        }
        return result
    }

    /// oracle_fixture_value (test-nws.c:433-450).
    private static func oracleValue(_ elements: [OracleElement], _ total: Bool, _ t: Int64) -> Double {
        for e in elements where t >= e.start && t < e.start + e.hours * hour {
            return total ? e.value / Double(e.hours) : e.value
        }
        return .nan
    }

    @Test("/nws/grid/fixture-vs-oracle")
    func gridFixtureVsOracle() throws {
        // C: /nws/grid/fixture-vs-oracle (test-nws.c:452-521)
        let data = try Fixtures.data("gridpoints_miami.json")
        #expect(data.count <= 200 * 1024)  // test-nws.c:458
        let m = try NWSParse.parseGridpoints(data, fetchedS: 1_791_676_800)
        Self.checkMember(m)
        #expect(m.fetchedS == 1_791_676_800)
        // 186 distinct hours, 2026-10-12T12:00Z .. 2026-10-20T01:00Z (test-nws.c:469-471).
        #expect(m.hours.count == 186)
        #expect(m.hours.first?.tS == 1_791_806_400)
        #expect(m.hours.last?.tS == 1_792_472_400)

        let oracle = try Self.oracleLayers(data)
        var finiteCount = [Int](repeating: 0, count: Self.kLayers.count)
        for h in m.hours {
            for k in Self.kLayers.indices {
                let expect = Self.oracleValue(oracle[k], Self.kLayers[k].total, h.tS)
                let got = Self.field(h, k)
                #expect(Self.same(got, expect), "\(Self.kLayers[k].name) at \(h.tS): got \(got), oracle \(expect)")
                finiteCount[k] += expect.isFinite ? 1 : 0
            }
        }
        // Every layer contributed (test-nws.c:486-487).
        for k in Self.kLayers.indices {
            #expect(finiteCount[k] >= 80, "\(Self.kLayers[k].name): \(finiteCount[k]) finite hours")
        }

        // Hand-checked values of the first hours (test-nws.c:490-515).
        let h12 = try #require(Self.hourAt(m, Self.t0))
        let h13 = try #require(Self.hourAt(m, Self.t0 + Self.hour))
        let h14 = try #require(Self.hourAt(m, Self.t0 + 2 * Self.hour))
        let h15 = try #require(Self.hourAt(m, Self.t0 + 3 * Self.hour))
        #expect(h12.tempC == 27.77777777777778)  // PT2H
        #expect(h13.tempC == 27.77777777777778)
        #expect(h14.tempC == 28.88888888888889)
        #expect(h12.feelsC == 32.77777777777778)
        #expect(h12.humidityPct == 88)
        #expect(h12.cloudPct == 16)
        #expect(h12.windKmh == 9.26)  // PT3H
        #expect(h14.windKmh == 9.26)
        #expect(h15.windKmh == 11.112)
        #expect(h12.gustKmh == 11.112)
        #expect(h13.gustKmh == 12.964)  // PT2H
        #expect(h14.gustKmh == 12.964)
        #expect(h12.precipProb == 6)
        #expect(h13.precipProb == 3)  // PT3H
        #expect(h15.precipProb == 3)
        #expect(h12.precipMm == 0.254 / 6)  // 0.254 mm over PT6H
        #expect(h15.precipMm == 0.254 / 6)
        #expect(h12.wmo == -1)
        // The six hours of the first precipitation interval sum back to the total (test-nws.c:517-520).
        var sum = 0.0
        for i in 0..<Int64(6) {
            sum += try #require(Self.hourAt(m, Self.t0 + i * Self.hour)).precipMm
        }
        #expect(abs(sum - 0.254) < 1e-12)
    }

    @Test("/nws/grid/fixture-stable")
    func gridFixtureStable() throws {
        // C: /nws/grid/fixture-stable (test-nws.c:523-542)
        let data = try Fixtures.data("gridpoints_miami.json")
        let a = try NWSParse.parseGridpoints(data, fetchedS: 1_791_676_800)
        let b = try NWSParse.parseGridpoints(data, fetchedS: 1_791_676_801)
        #expect(a.hours.count == b.hours.count)
        for (ha, hb) in zip(a.hours, b.hours) {
            #expect(ha.tS == hb.tS)
            #expect(Self.same(ha.tempC, hb.tempC))
            #expect(Self.same(ha.precipMm, hb.precipMm))
        }
        #expect(b.fetchedS == 1_791_676_801)
    }

    // MARK: - /nws/grid/ over synthetic bodies

    @Test("/nws/grid/each-layer-and-unit")
    func gridEachLayerAndUnit() throws {
        // C: /nws/grid/each-layer-and-unit (test-nws.c:548-596)
        let wrong = ["wmoUnit:degF", "wmoUnit:m", "", "degC", "wmoUnit:degC ", "WMOUNIT:DEGC", "nwsUnit:s",
                     "wmoUnit:km_h-1x"]
        for (k, layer) in Self.kLayers.enumerated() {
            let elem = Self.elementJSON(Self.t0, "PT1H", "5")
            let m = try #require(Self.parseGrid(Self.gridBody(Self.layerJSON(layer.name, layer.uom, elem)), 1_791_676_800))
            #expect(m.hours.count == 1)
            #expect(m.hours.first?.tS == Self.t0)
            let h = try #require(m.hours.first)
            #expect(Self.field(h, k) == 5.0, "\(layer.name)")
            // Every other field of the hour is NAN.
            for j in Self.kLayers.indices where j != k {
                #expect(Self.field(h, j).isNaN, "\(layer.name): field \(j)")
            }
            for w in wrong where w != layer.uom {
                Self.expectGridError(Self.gridBody(Self.layerJSON(layer.name, w, elem)), .notFound, Self.msgNoData)
            }
            // No uom, uom of another type, values of another type, missing values, layer of another type.
            let n = layer.name
            let u = layer.uom
            let others = [
                "\"\(n)\":{\"values\":[\(elem)]}",
                "\"\(n)\":{\"uom\":5,\"values\":[\(elem)]}",
                "\"\(n)\":{\"uom\":null,\"values\":[\(elem)]}",
                "\"\(n)\":{\"uom\":\"\(u)\"}",
                "\"\(n)\":{\"uom\":\"\(u)\",\"values\":{}}",
                "\"\(n)\":{\"uom\":\"\(u)\",\"values\":null}",
                "\"\(n)\":{\"uom\":\"\(u)\",\"values\":\"x\"}",
                "\"\(n)\":[1]",
                "\"\(n)\":null",
                "\"\(n)\":5",
            ]
            for l in others {
                Self.expectGridError(Self.gridBody(l), .notFound, Self.msgNoData)
            }
        }
    }

    @Test("/nws/grid/ignores-other-layers")
    func gridIgnoresOtherLayers() {
        // C: /nws/grid/ignores-other-layers (test-nws.c:598-609)
        let elem = Self.elementJSON(Self.t0, "PT1H", "5")
        let layers = [
            Self.layerJSON("dewpoint", "wmoUnit:degC", elem), Self.layerJSON("maxTemperature", "wmoUnit:degC", elem),
            Self.layerJSON("windChill", "wmoUnit:degC", elem),
        ].joined(separator: ",")
        Self.expectGridError(Self.gridBody(layers), .notFound, Self.msgNoData)
    }

    @Test("/nws/grid/expansion")
    func gridExpansion() throws {
        // C: /nws/grid/expansion (test-nws.c:611-631)
        let elems = Self.elementJSON(Self.t0, "PT3H", "20") + "," + Self.elementJSON(Self.t0 + 5 * Self.hour, "PT1H", "21.5")
        let m = try #require(Self.parseGrid(Self.tempBody(elems), 1_791_676_800))
        try #require(m.hours.count == 4)
        for i in 0..<3 {
            #expect(m.hours[i].tS == Self.t0 + Int64(i) * Self.hour)
            #expect(m.hours[i].tempC == 20.0)
        }
        #expect(m.hours[3].tS == Self.t0 + 5 * Self.hour)
        #expect(m.hours[3].tempC == 21.5)
        #expect(Self.hourAt(m, Self.t0 + 3 * Self.hour) == nil)
        #expect(Self.hourAt(m, Self.t0 + 4 * Self.hour) == nil)
        #expect(Self.hourAt(m, Self.t0 - Self.hour) == nil)
    }

    @Test("/nws/grid/precipitation-divided")
    func gridPrecipitationDivided() throws {
        // C: /nws/grid/precipitation-divided (test-nws.c:633-665; table at :641-651)
        let cases: [(String, String, Int, Double)] = [
            ("PT1H", "2.5", 1, 2.5),
            ("PT3H", "3", 3, 1.0),
            ("PT6H", "0.254", 6, 0.254 / 6),
            ("P1D", "24", 24, 1.0),
            ("P1DT6H", "30", 30, 1.0),
            ("PT2H", "1e-320", 2, 1e-320 / 2),  // subnormal
            ("PT12H", "0", 12, 0.0),
            ("PT180M", "3", 3, 1.0),  // the duration parser also reads minutes and seconds
            ("PT7200S", "4", 2, 2.0),
        ]
        for (duration, value, hours, each) in cases {
            let body = Self.gridBody(Self.layerJSON("quantitativePrecipitation", "wmoUnit:mm",
                                                    Self.elementJSON(Self.t0, duration, value)))
            let m = try #require(Self.parseGrid(body, 1_791_676_800))
            #expect(m.hours.count == hours, "\(duration) \(value)")
            for (h, hr) in m.hours.enumerated() {
                #expect(hr.tS == Self.t0 + Int64(h) * Self.hour)
                #expect(hr.precipMm == each, "\(duration) \(value): hour \(h) = \(hr.precipMm)")
            }
        }
    }

    @Test("/nws/grid/value-ranges")
    func gridValueRanges() throws {
        // C: /nws/grid/value-ranges (test-nws.c:667-752; table at :670-729)
        let nan = Double.nan
        let cases: [(String, String, String, Double)] = [
            ("temperature", "PT1H", "-100", -100.0),
            ("temperature", "PT1H", "-100.0000001", nan),
            ("temperature", "PT1H", "70", 70.0),
            ("temperature", "PT1H", "70.0000001", nan),
            ("temperature", "PT1H", "1e308", nan),
            ("temperature", "PT1H", "-1e308", nan),
            ("temperature", "PT1H", "1e999", nan),
            ("temperature", "PT1H", "-1e999", nan),
            ("temperature", "PT1H", "9223372036854775807", nan),
            ("temperature", "PT1H", "-9223372036854775808", nan),
            ("temperature", "PT1H", "99999999999999999999", nan),
            ("temperature", "PT1H", "\"12\"", nan),
            ("temperature", "PT1H", "true", nan),
            ("temperature", "PT1H", "null", nan),
            ("temperature", "PT1H", "[1]", nan),
            ("temperature", "PT1H", "{}", nan),
            ("temperature", "PT1H", "-0.0", 0.0),
            ("temperature", "PT1H", "4.9e-324", 4.9e-324),
            ("apparentTemperature", "PT1H", "70", 70.0),
            ("apparentTemperature", "PT1H", "71", nan),
            ("apparentTemperature", "PT1H", "-101", nan),
            ("relativeHumidity", "PT1H", "0", 0.0),
            ("relativeHumidity", "PT1H", "100", 100.0),
            ("relativeHumidity", "PT1H", "100.0000001", nan),
            ("relativeHumidity", "PT1H", "-0.0000001", nan),
            ("skyCover", "PT1H", "100", 100.0),
            ("skyCover", "PT1H", "101", nan),
            ("skyCover", "PT1H", "-1", nan),
            ("probabilityOfPrecipitation", "PT1H", "100", 100.0),
            ("probabilityOfPrecipitation", "PT1H", "100.5", nan),
            ("probabilityOfPrecipitation", "PT1H", "-5", nan),
            ("windSpeed", "PT1H", "0", 0.0),
            ("windSpeed", "PT1H", "500", 500.0),
            ("windSpeed", "PT1H", "500.0000001", nan),
            ("windSpeed", "PT1H", "-0.0000001", nan),
            ("windGust", "PT1H", "500", 500.0),
            ("windGust", "PT1H", "501", nan),
            ("windGust", "PT1H", "-1", nan),
            ("quantitativePrecipitation", "PT1H", "500", 500.0),
            ("quantitativePrecipitation", "PT1H", "500.0000001", nan),
            ("quantitativePrecipitation", "PT2H", "1000", 500.0),
            ("quantitativePrecipitation", "PT2H", "1000.000001", nan),
            ("quantitativePrecipitation", "PT3H", "1500", 500.0),
            ("quantitativePrecipitation", "PT1H", "-0.0", 0.0),
            ("quantitativePrecipitation", "PT1H", "-0.1", nan),
            ("quantitativePrecipitation", "PT2H", "-1e-320", nan),
            ("quantitativePrecipitation", "PT1H", "1e308", nan),
            ("quantitativePrecipitation", "P31D", "1e308", nan),
            ("quantitativePrecipitation", "P31D", "372000", 500.0),
        ]
        #expect(cases.count == 49)
        for (name, duration, value, expect) in cases {
            let k = Self.layerIndex(name)
            try #require(k >= 0)
            // The element under test, then a companion (another layer) that always survives.
            let comp = name == "skyCover" ? 4 : 3
            let l1 = Self.layerJSON(name, Self.kLayers[k].uom, Self.elementJSON(Self.t0, duration, value))
            let l2 = Self.layerJSON(Self.kLayers[comp].name, Self.kLayers[comp].uom,
                                    Self.elementJSON(Self.t0 - 10 * Self.hour, "PT1H", "1"))
            let m = try #require(Self.parseGrid(Self.gridBody(l1 + "," + l2), 1_791_676_800))
            let h = Self.hourAt(m, Self.t0)
            if expect.isNaN {
                #expect(h == nil, "\(name) \(duration) \(value) was not dropped")
            } else {
                let got = try #require(h, "\(name) \(duration) \(value) was dropped")
                let f = Self.field(got, k)
                #expect(Self.same(f, expect), "\(name) \(duration) \(value): got \(f)")
                #expect(!(f.sign == .minus && expect == 0.0), "\(name) \(value): negative zero stored")
            }
            #expect(Self.hourAt(m, Self.t0 - 10 * Self.hour) != nil)
        }
    }

    @Test("/nws/grid/bad-elements-skipped")
    func gridBadElementsSkipped() throws {
        // C: /nws/grid/bad-elements-skipped (test-nws.c:754-807; table at :757-793)
        let bad = [
            "{\"validTime\":\"\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/\",\"value\":1}",
            "{\"validTime\":\"/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT0S\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT0H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/P1W\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/P1M\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:30:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:01+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT90M\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H30M\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1800S\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/P32D\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT745H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT99999999H\",\"value\":1}",
            "{\"validTime\":\"1999-12-31T23:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2101-01-01T00:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12 12:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-10-12t12:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\"2026-13-12T12:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":\" 2026-10-12T12:00:00+00:00/PT1H\",\"value\":1}",
            "{\"validTime\":5,\"value\":1}",
            "{\"validTime\":null,\"value\":1}",
            "{\"validTime\":[\"2026-10-12T12:00:00+00:00/PT1H\"],\"value\":1}",
            "{\"value\":1}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\"}",
            "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\",\"value\":null}",
            "{}",
            "[]",
            "5",
            "\"2026-10-12T12:00:00+00:00/PT1H\"",
            "null",
            "true",
        ]
        #expect(bad.count == 35)
        for elem in bad {
            let good = Self.elementJSON(Self.t0 + 10 * Self.hour, "PT1H", "7")
            let m = try #require(Self.parseGrid(Self.tempBody(elem + "," + good), 1_791_676_800), "\(elem)")
            #expect(m.hours.count == 1, "\(elem)")
            #expect(Self.hourAt(m, Self.t0 + 10 * Self.hour) != nil, "\(elem)")
            // ... and alone it leaves nothing usable.
            Self.expectGridError(Self.tempBody(elem), .notFound, Self.msgNoData)
        }
    }

    @Test("/nws/grid/time-zones-and-bounds")
    func gridTimeZonesAndBounds() throws {
        // C: /nws/grid/time-zones-and-bounds (test-nws.c:809-837; table at :816-826)
        let cases: [(String, Int64, Int)] = [
            ("2026-10-12T08:00:00-04:00/PT1H", Self.t0, 1),
            ("2026-10-12T17:30:00+05:30/PT2H", Self.t0, 2),
            ("2026-10-12T12:00:00Z/PT1H", Self.t0, 1),
            ("2026-10-12T12:00:00.750Z/PT1H", Self.t0, 1),
            ("2000-01-01T00:00:00Z/PT1H", Self.timeMinS, 1),
            // 2100-12-31: only the 24 hours before WX_TIME_MAX_S (2101-01-01) exist.
            ("2100-12-31T00:00:00Z/P2D", 4_133_894_400, 24),
            ("2100-12-31T23:00:00Z/PT2H", 4_133_980_800 - Self.hour, 1),
            ("2100-12-31T23:00:00Z/PT1H", 4_133_980_800 - Self.hour, 1),
        ]
        for (validTime, first, hours) in cases {
            let m = try #require(Self.parseGrid(Self.tempBody("{\"validTime\":\"\(validTime)\",\"value\":3}"),
                                                1_791_676_800), "\(validTime)")
            #expect(m.hours.count == hours, "\(validTime)")
            #expect(m.hours.first?.tS == first, "\(validTime)")
            #expect((m.hours.last?.tS ?? Self.timeMaxS) < Self.timeMaxS)
        }
    }

    @Test("/nws/grid/overlap-first-wins")
    func gridOverlapFirstWins() throws {
        // C: /nws/grid/overlap-first-wins (test-nws.c:839-855)
        let elems = [
            Self.elementJSON(Self.t0, "PT3H", "10"), Self.elementJSON(Self.t0 + Self.hour, "PT3H", "20"),
            Self.elementJSON(Self.t0, "PT1H", "30"),
        ].joined(separator: ",")
        let m = try #require(Self.parseGrid(Self.tempBody(elems), 1_791_676_800))
        try #require(m.hours.count == 4)
        #expect(m.hours[0].tempC == 10)
        #expect(m.hours[1].tempC == 10)
        #expect(m.hours[2].tempC == 10)
        #expect(m.hours[3].tempC == 20)
    }

    @Test("/nws/grid/union-ascending")
    func gridUnionAscending() throws {
        // C: /nws/grid/union-ascending (test-nws.c:857-879)
        // Elements in descending array order and layers with disjoint hours.
        let telems = Self.elementJSON(Self.t0 + 5 * Self.hour, "PT1H", "5") + ","
            + Self.elementJSON(Self.t0 + 4 * Self.hour, "PT1H", "4")
        let w = Self.elementJSON(Self.t0 + 1 * Self.hour, "PT1H", "11")
        let q = Self.elementJSON(Self.t0 + 3 * Self.hour, "PT2H", "4")
        let layers = [
            Self.layerJSON("temperature", "wmoUnit:degC", telems), Self.layerJSON("windSpeed", "wmoUnit:km_h-1", w),
            Self.layerJSON("quantitativePrecipitation", "wmoUnit:mm", q),
        ].joined(separator: ",")
        let m = try #require(Self.parseGrid(Self.gridBody(layers), 1_791_676_800))
        try #require(m.hours.count == 4)  // hours +1 (wind), +3 and +4 (precipitation, +4 also temperature), +5
        #expect(m.hours[0].tS == Self.t0 + 1 * Self.hour)
        #expect(m.hours[1].tS == Self.t0 + 3 * Self.hour)
        #expect(m.hours[2].tS == Self.t0 + 4 * Self.hour)
        #expect(m.hours[3].tS == Self.t0 + 5 * Self.hour)
    }

    @Test("/nws/grid/caps")
    func gridCaps() throws {
        // C: /nws/grid/caps (test-nws.c:881-960)
        let hr = Self.hour
        let t0 = Self.t0
        // 450 consecutive one-hour elements: the first 400 hours.
        let s1 = (0..<Int64(450)).map { Self.elementJSON(t0 + $0 * hr, "PT1H", "1") }.joined(separator: ",")
        var m = try #require(Self.parseGrid(Self.tempBody(s1), 1_791_676_800))
        #expect(m.hours.count == Self.maxHours)
        #expect(m.hours.last?.tS == t0 + 399 * hr)

        // Elements 0..399 are read, element 400 and later are not: duplicates of one hour first.
        for last in 399...400 {
            let dup = [String](repeating: Self.elementJSON(t0, "PT1H", "1"), count: last).joined(separator: ",")
            let body = Self.tempBody(dup + "," + Self.elementJSON(t0 + 10 * hr, "PT1H", "2"))
            m = try #require(Self.parseGrid(body, 1_791_676_800))
            #expect((Self.hourAt(m, t0 + 10 * hr) != nil) == (last == 399), "last \(last)")
        }

        // A 31 day interval gives 400 of its 744 hours.
        m = try #require(Self.parseGrid(Self.tempBody(Self.elementJSON(t0, "P31D", "1")), 1_791_676_800))
        #expect(m.hours.count == Self.maxHours)
        #expect(m.hours.first?.tS == t0)
        #expect(m.hours.last?.tS == t0 + 399 * hr)

        // Overlapping 10-day elements: distinct hours stop at 400 (3rd element adds only 40).
        let abc = [
            Self.elementJSON(t0, "P10D", "1"), Self.elementJSON(t0 + 120 * hr, "P10D", "2"),
            Self.elementJSON(t0 + 240 * hr, "P10D", "3"),
        ].joined(separator: ",")
        m = try #require(Self.parseGrid(Self.tempBody(abc), 1_791_676_800))
        #expect(m.hours.count == Self.maxHours)
        #expect(Self.hourAt(m, t0 + 119 * hr)?.tempC == 1)
        #expect(Self.hourAt(m, t0 + 120 * hr)?.tempC == 1)  // first element wins
        #expect(Self.hourAt(m, t0 + 239 * hr)?.tempC == 1)
        #expect(Self.hourAt(m, t0 + 240 * hr)?.tempC == 2)
        #expect(Self.hourAt(m, t0 + 359 * hr)?.tempC == 2)
        #expect(Self.hourAt(m, t0 + 360 * hr)?.tempC == 3)
        #expect(Self.hourAt(m, t0 + 399 * hr)?.tempC == 3)
        #expect(Self.hourAt(m, t0 + 400 * hr) == nil)

        // The union of two layers is cut at 400 hours, earliest first.
        let telems = Self.elementJSON(t0, "P16D", "1") + "," + Self.elementJSON(t0 + 384 * hr, "P1D", "1")
        let layers = Self.layerJSON("temperature", "wmoUnit:degC", telems) + ","
            + Self.layerJSON("windSpeed", "wmoUnit:km_h-1", Self.elementJSON(t0 + 500 * hr, "PT3H", "9"))
        m = try #require(Self.parseGrid(Self.gridBody(layers), 1_791_676_800))
        #expect(m.hours.count == Self.maxHours)
        #expect(m.hours.last?.tS == t0 + 399 * hr)
        #expect(m.hours.allSatisfy { $0.windKmh.isNaN })
    }

    @Test("/nws/grid/large-hostile-bodies")
    func gridLargeHostileBodies() throws {
        // C: /nws/grid/large-hostile-bodies (test-nws.c:962-993)
        // ~3 MB of one-hour elements (only 400 are read) and copies of a 31-day interval.
        let one = "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\",\"value\":1}"
        let body1 = Self.tempBody([String](repeating: one, count: 40000).joined(separator: ","))
        #expect(body1.utf8.count < Self.bodyCap)
        let m1 = try #require(Self.parseGrid(body1, 1_791_676_800))
        #expect(m1.hours.count == 1)

        let month = "{\"validTime\":\"2026-10-12T12:00:00+00:00/P31D\",\"value\":1}"
        let m2 = try #require(Self.parseGrid(Self.tempBody([String](repeating: month, count: 2000).joined(separator: ",")),
                                             1_791_676_800))
        #expect(m2.hours.count == Self.maxHours)

        // Hash-flooding names are refused by wx_json_parse() (1025 members).
        let flood = "{\"properties\":{" + (0..<1025).map { "\"k\($0)\":1" }.joined(separator: ",") + "}}"
        Self.expectGridError(flood, .parse, "malformed JSON")
    }

    @Test("/nws/grid/parse-errors")
    func gridParseErrors() {
        // C: /nws/grid/parse-errors (test-nws.c:995-1018)
        Self.expectGridError("", .parse, "empty response")
        Self.expectGridError("[]", .parse, "response is not a JSON object")
        Self.expectGridError("null", .parse, "response is not a JSON object")
        Self.expectGridError("{", .parse, "malformed JSON")
        Self.expectGridError("{\"properties\":{}} {}", .parse, "malformed JSON")
        // C "\xff": the byte 0xFF inside the string (test-nws.c:1003).
        Self.expectGridError(Self.b("{\"properties\":{\"a\":\"") + [0xFF] + Self.b("\"}}"), .parse,
                             "response is not valid UTF-8")
        Self.expectGridError("{}", .parse, Self.msgNoProps)
        Self.expectGridError("{\"properties\":null}", .parse, Self.msgNoProps)
        Self.expectGridError("{\"properties\":[]}", .parse, Self.msgNoProps)
        Self.expectGridError("{\"properties\":5}", .parse, Self.msgNoProps)
        Self.expectGridError("{\"properties\":{}}", .notFound, Self.msgNoData)
        Self.expectGridError([UInt8](), .parse, "empty response")  // NULL, 0
        Self.expectGridError("{\"properties\":" + String(repeating: "[", count: 5000), .parse, "malformed JSON")
        Self.expectGridError([UInt8](repeating: 0x20, count: Self.bodyCap + 1), .parse, "response too large")
    }

    @Test("/nws/grid/fetched-time")
    func gridFetchedTime() throws {
        // C: /nws/grid/fetched-time (test-nws.c:1020-1043)
        let body = Self.b("{\"properties\":{}}")
        let bad: [Int64] = [0, -1, Int64.min, Int64.max, Self.timeMinS - 1, Self.timeMaxS]
        for t in bad {
            do {
                _ = try NWSParse.parseGridpoints(body, fetchedS: t)
                Issue.record("fetched_s \(t) accepted")
            } catch {
                #expect(error.code == .invalidArg && error.message == "fetch time out of range", "\(t): \(error)")
            }
        }
        // A body error is reported before the time is looked at.
        do {
            _ = try NWSParse.parseGridpoints(Self.b("{}"), fetchedS: 0)
            Issue.record("accepted")
        } catch {
            #expect(error.code == .parse && error.message == Self.msgNoProps)
        }
        let good = Self.tempBody(Self.elementJSON(Self.t0, "PT1H", "1"))
        for t in [Self.timeMinS, Self.timeMaxS - 1] {
            let m = try #require(Self.parseGrid(good, t))
            #expect(m.fetchedS == t)
        }
    }

    @Test("/nws/grid/programmer-errors (behavioural remainder)")
    func gridProgrammerErrors() {
        // C: /nws/grid/programmer-errors (test-nws.c:1045-1059). The criticals
        // (NULL data with len > 0, preset error) are GLIB-INTERNAL. Kept: the
        // failures without an error location.
        #expect((try? NWSParse.parseGridpoints(Self.b("{}"), fetchedS: Self.t0)) == nil)
        #expect((try? NWSParse.parseGridpoints(Self.b("{\"properties\":{}}"), fetchedS: Self.t0)) == nil)
    }

    @Test("/nws/grid/guard-page (exact-length slices)")
    func gridGuardPage() throws {
        // C: /nws/grid/guard-page (test-nws.c:1061-1092). As for points: a
        // slice of a larger buffer whose following bytes would change the
        // outcome if they were read.
        let good = Self.tempBody(Self.elementJSON(Self.t0, "PT2H", "3"))
        let bodies: [(String, String)] = [
            (good, " x"),
            ("{\"properties\":{\"temperature\":{\"uom\":", "\"wmoUnit:degC\",\"values\":[]}}}"),
            ("{", "\"properties\":{}}"),
            ("[1,2]", "]"),
            ("x", ""),
            ("{\"properties\":{}}", ""),
        ]
        let prefix = Self.b(good)
        for (i, (body, tail)) in bodies.enumerated() {
            let buffer = Data(prefix + Self.b(body) + Self.b(tail))
            let slice = buffer[prefix.count..<(prefix.count + body.utf8.count)]
            let m = try? NWSParse.parseGridpoints(slice, fetchedS: Self.t0)
            #expect((m != nil) == (i == 0), "body \(i)")
            if let m {
                Self.checkMember(m)
            }
        }
        // The real fixture, as a slice ending where the buffer goes on.
        let fixture = try Fixtures.data("gridpoints_miami.json")
        let buffer = Data(Self.b("xx") + Array(fixture) + Self.b("}}"))
        #expect((try? NWSParse.parseGridpoints(buffer[2..<(2 + fixture.count)], fetchedS: Self.t0)) != nil)
    }

    // MARK: - /nws/grid/differential-fuzz (test-nws.c:1094-1380)

    /// One generated element (GenElement, test-nws.c:1096-1103).
    private struct GenElement {
        var usable = false
        var startS: Int64 = 0
        var hours = 0
        var value = 0.0
        var json = ""
    }

    /// kValues (test-nws.c:1109-1117): JSON text and whether it is a finite number the reader accepts.
    private static let kValues: [(text: String, number: Bool)] = [
        ("0", true), ("-0.0", true), ("1", true), ("17.25", true), ("99.9", true),
        ("100", true), ("250.5", true), ("499", true), ("500", true), ("-5", true),
        ("-100", true), ("69.5", true), ("70", true), ("-20.125", true), ("0.254", true),
        ("70.5", true), ("100.5", true), ("-0.5", true), ("700", true), ("-101", true),
        ("1000", true), ("1e308", true), ("-1e308", true), ("500.5", true), ("2.5e2", true),
        ("null", false), ("\"3\"", false), ("true", false), ("[1]", false), ("{}", false),
        ("1e999", false), ("-1e999", false), ("9223372036854775807", false),
    ]

    /// g_rand_int_range: uniform in [lo, hi).
    private static func r(_ rng: inout SeededRNG, _ lo: Int, _ hi: Int) -> Int {
        Int.random(in: lo..<hi, using: &rng)
    }

    /// layer_range (test-nws.c:1120-1142).
    private static func layerRange(_ k: Int) -> (Double, Double) {
        switch k {
        case 0, 1: return (-100, 70)
        case 4, 5: return (0, 500)
        case 7: return (0, 500)
        default: return (0, 100)
        }
    }

    /// format_duration (test-nws.c:1144-1154).
    private static func formatDuration(_ rng: inout SeededRNG, _ hours: Int) -> String {
        if hours % 24 == 0 && Bool.random(using: &rng) {
            return "P\(hours / 24)D"
        }
        if hours >= 24 && Bool.random(using: &rng) {
            return hours % 24 != 0 ? "P\(hours / 24)DT\(hours % 24)H" : "P\(hours / 24)D"
        }
        return "PT\(hours)H"
    }

    /// gen_element (test-nws.c:1156-1235).
    private static func genElement(_ rng: inout SeededRNG, _ k: Int) -> GenElement {
        var e = GenElement()
        // Start: mostly near T0, sometimes at the edges of the supported years.
        var start: Int64
        switch r(&rng, 0, 12) {
        case 0: start = timeMinS + hour * Int64(r(&rng, 0, 5))
        case 1: start = timeMaxS - hour * Int64(r(&rng, 1, 30))
        default: start = t0 + hour * Int64(r(&rng, -50, 350))
        }
        let hours = Bool.random(using: &rng) ? r(&rng, 1, 7) : r(&rng, 1, 745)
        var okTime = true
        var when: String?
        var dur = formatDuration(&rng, hours)
        var offsetS: Int64 = 0
        switch r(&rng, 0, 20) {
        case 1: start += 1800; okTime = false  // misaligned start
        case 2: dur = "PT\(hours)H30M"; okTime = false
        case 3: dur = "PT\(hours * 60)M"  // same length, minutes
        case 4: dur = "PT0H"; okTime = false
        case 5: dur = "P\(32 + r(&rng, 0, 4))D"; okTime = false
        case 6: when = "garbage"; okTime = false
        case 7: offsetS = 3600 * Int64(r(&rng, -12, 13))
        case 8: offsetS = 1800 * Int64(r(&rng, -23, 24))
        case 9: dur = "PT\(hours * 3600)S"  // same length, seconds
        default: break
        }
        // An offset moves the local text; keep it inside the accepted years.
        if offsetS != 0 && (start < t0 - 100 * hour || start > t0 + 400 * hour) {
            offsetS = 0
        }
        let whenText: String
        if let when {
            whenText = when
        } else {
            let a = abs(offsetS)
            whenText = utcText(start + offsetS) + (offsetS < 0 ? "-" : "+") + pad(a / 3600, 2) + ":" + pad(a % 3600 / 60, 2)
        }
        // Value.
        var vt: (text: String, number: Bool)?
        if r(&rng, 0, 12) != 0 {
            vt = kValues[r(&rng, 0, kValues.count)]
        }
        let object = r(&rng, 0, 25) != 0
        if !object {
            let junk = ["5", "\"x\"", "null", "[]", "true"]
            e.json = junk[r(&rng, 0, junk.count)]
            return e
        }
        if let vt {
            e.json = "{\"validTime\":\"\(whenText)/\(dur)\",\"value\":\(vt.text)}"
        } else {
            e.json = "{\"validTime\":\"\(whenText)/\(dur)\"}"
        }
        guard okTime, let vt, vt.number, var v = Double(vt.text) else {
            return e
        }
        // The reference reading: value, hours, range.
        let (lo, hi) = layerRange(k)
        if k == 7 {
            v /= Double(hours)
        }
        if !(v >= lo && v <= hi) {
            return e
        }
        // Year bounds of the text (local time of the start).
        let localS = start + offsetS
        if localS < timeMinS || localS >= timeMaxS {
            return e
        }
        // 31 days at most.
        if hours > 744 {
            return e
        }
        e.usable = true
        e.startS = start
        e.hours = hours
        e.value = v == 0 ? 0.0 : v
        return e
    }

    /// oracle_read (test-nws.c:1242-1290): the documented reading of one
    /// generated body, with plain arrays and a sort at the end.
    private static func oracleRead(_ perLayer: [[GenElement]], _ layerOK: [Bool]) -> [(t: Int64, v: [Double])] {
        var out: [(t: Int64, v: [Double])] = []
        var index: [Int64: Int] = [:]
        for k in kLayers.indices where layerOK[k] {
            var seen = Set<Int64>()
            for e in perLayer[k].prefix(maxHours) where e.usable {
                if seen.count >= maxHours {
                    break
                }
                for h in 0..<e.hours where seen.count < maxHours {
                    let t = e.startS + Int64(h) * hour
                    if t < timeMinS || t >= timeMaxS || seen.contains(t) {
                        continue
                    }
                    seen.insert(t)
                    if index[t] == nil {
                        index[t] = out.count
                        out.append((t, [Double](repeating: .nan, count: kLayers.count)))
                    }
                    out[index[t]!].v[k] = e.value
                }
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// differential_once (test-nws.c:1298-1360).
    private static func differentialOnce(_ rng: inout SeededRNG, _ iteration: Int) {
        var elems = [[GenElement]](repeating: [], count: kLayers.count)
        var layerOK = [Bool](repeating: false, count: kLayers.count)
        var body = "{\"properties\":{"
        var firstLayer = true
        for k in kLayers.indices {
            let present = r(&rng, 0, 6)
            if present == 0 {
                continue
            }
            let n = r(&rng, 0, 4) == 0 ? r(&rng, 0, 450) : r(&rng, 0, 12)
            for _ in 0..<n {
                elems[k].append(genElement(&rng, k))
            }
            let uom = present == 1 ? "wmoUnit:other" : kLayers[k].uom
            layerOK[k] = present != 1
            body += (firstLayer ? "" : ",") + "\"\(kLayers[k].name)\":{\"uom\":\"\(uom)\",\"values\":["
            body += elems[k].map(\.json).joined(separator: ",")
            body += "]}"
            firstLayer = false
        }
        body += "}}"

        let expect = oracleRead(elems, layerOK)
        let want = min(expect.count, maxHours)
        do {
            let m = try NWSParse.parseGridpoints(b(body), fetchedS: t0)
            if want == 0 {
                Issue.record("iteration \(iteration): accepted \(m.hours.count) hours, oracle has none")
                return
            }
            checkMember(m)
            guard m.hours.count == want else {
                Issue.record("iteration \(iteration): \(m.hours.count) hours, oracle \(want)")
                return
            }
            for (i, h) in m.hours.enumerated() {
                let oh = expect[i]
                var ok = h.tS == oh.t
                for k in kLayers.indices {
                    let got = field(h, k)
                    ok = ok && same(got, oh.v[k]) && !(got == 0.0 && got.sign == .minus)
                }
                if !ok {
                    Issue.record("iteration \(iteration), hour \(i): got \(h), oracle t \(oh.t) \(oh.v)")
                    return
                }
            }
        } catch {
            #expect(want == 0, "iteration \(iteration): rejected (\(error.message)), oracle has \(want) hours")
            #expect(error.code == .notFound && error.message == msgNoData, "iteration \(iteration): \(error)")
        }
    }

    @Test("/nws/grid/differential-fuzz")
    func gridDifferentialFuzz() {
        // C: /nws/grid/differential-fuzz (test-nws.c:1373-1380; seed 20261012, 4000 iterations at :1376-1377)
        var rng = SeededRNG(seed: 20_261_012)
        for i in 0..<fuzzIterations(4000) {
            Self.differentialOnce(&rng, i)
        }
    }

    // MARK: - /nws/grid/mutation-fuzz (test-nws.c:1382-1466)

    /// The mutation alphabet (test-nws.c:1389), without the C terminator.
    private static let alphabet: [UInt8] = Array("{}[]\",:0123456789.eE+-tnfruaslTZP/H\\ \n".utf8) + [0xFF, 0x80]

    /// mutate (test-nws.c:1384-1423): byte changes, cuts, duplications.
    private static func mutate(_ rng: inout SeededRNG, _ data: [UInt8]) -> [UInt8] {
        var out = data
        let rounds = r(&rng, 1, 5)
        var round = 0
        while round < rounds && out.count > 2 {
            let pos = r(&rng, 0, out.count)
            switch r(&rng, 0, 5) {
            case 0:
                out[pos] = alphabet[r(&rng, 0, alphabet.count)]
            case 1:
                out[pos] ^= UInt8(1 << r(&rng, 0, 8))
            case 2:
                out.removeSubrange((pos + 1)...)
            case 3:
                let cut = min(r(&rng, 1, 40), out.count - pos)
                out.removeSubrange(pos..<(pos + cut))
            default:
                let oldLen = out.count
                let copy = min(r(&rng, 1, 60), oldLen - pos)
                let at = r(&rng, 0, oldLen)
                out.insert(contentsOf: Array(out[pos..<(pos + copy)]), at: at)
            }
            round += 1
        }
        return out
    }

    /// fuzz_grid_text (test-nws.c:1425-1452).
    private static func fuzzText(_ rng: inout SeededRNG, _ seed: [UInt8], _ iterations: Int) {
        for i in 0..<iterations {
            let text = mutate(&rng, seed)
            do {
                let m = try NWSParse.parseGridpoints(text, fetchedS: t0)
                checkMember(m)
            } catch {
                #expect(error.code == .parse || error.code == .notFound, "iteration \(i): \(error.code)")
            }
            do {
                let grid = try NWSParse.parsePoints(text)
                #expect(grid.x <= 999 && grid.y <= 999 && grid.gridID.utf8.count == 3, "iteration \(i): \(grid)")
            } catch {
                #expect(error.code == .parse, "iteration \(i): \(error.code)")
            }
        }
    }

    @Test("/nws/grid/mutation-fuzz")
    func gridMutationFuzz() throws {
        // C: /nws/grid/mutation-fuzz (test-nws.c:1454-1466; seed 424242, 1500 + 150 iterations at :1457-1464)
        var rng = SeededRNG(seed: 424_242)
        Self.fuzzText(&rng, Array(try Fixtures.data("points_miami.json")), fuzzIterations(1500))
        Self.fuzzText(&rng, Array(try Fixtures.data("gridpoints_miami.json")), fuzzIterations(150))
    }
}
