// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoParseTests.swift - port of the /openmeteo/parse/ group of
// src/providers/openmeteo/test-openmeteo.c (registrations at
// test-openmeteo.c:4907-4939). This file: helpers, the independent stamp
// oracle and the forecast / nowcast / error cases. The geocode cases are in
// OpenMeteoParseGeocodeTests.swift, the fuzz cases and the shared-constant
// checks in OpenMeteoParseFuzzTests.swift (all in suite OpenMeteoParseTests).
//
// Inputs are the C literals with the same bytes: C escapes that Swift spells
// the same way (\\ \" \n) are kept verbatim, so a JSON "\\u0001" in C is the
// six characters backslash-u-0-0-0-1 here too; C \xNN bytes are written as
// byte arrays or as the equivalent \u{...} scalar of valid UTF-8. Expected
// values are the C test literals (test-openmeteo.c:LINE), never output of the
// code under test.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct OpenMeteoParseTests {
    // MARK: - Helpers (test-openmeteo.c:55-178)

    /// T0: 2026-10-12T00:00:00Z, the first stamp of the fixtures (test-openmeteo.c:56).
    static let t0: Int64 = 1_791_763_200
    /// FETCHED (test-openmeteo.c:57).
    static let fetched: Int64 = 1_791_800_000
    /// WX_TIME_MIN_S / WX_TIME_MAX_S (src/core/wx-types.h).
    static let timeMin: Int64 = 946_684_800
    static let timeMax: Int64 = 4_133_980_800

    /// miami_models / london_models / gfs_only (test-openmeteo.c:165-171).
    static let miamiModels: [OpenMeteoModel] = [
        .ncepHrrrConus, .ncepNbmConus, .gfsSeamless, .ecmwfIfs025, .iconSeamless, .gemSeamless,
    ]
    static let miamiIDs = ["hrrr", "nbm", "gfs", "ecmwf", "icon", "gem"]
    static let londonModels: [OpenMeteoModel] = [
        .ecmwfIfs025, .iconSeamless, .gemSeamless, .gfsSeamless, .ukmoSeamless, .meteofranceSeamless,
    ]
    static let londonIDs = ["ecmwf", "icon", "gem", "gfs", "ukmo", "meteofrance"]
    static let gfsOnly: [OpenMeteoModel] = [.gfsSeamless]

    static func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The fixture bytes (fixture_text, test-openmeteo.c:95-114).
    static func fixture(_ name: String) throws -> [UInt8] {
        Array(try Fixtures.data(name))
    }

    /// same_double (test-openmeteo.c:117-122): both NaN, or equal with the same sign.
    static func same(_ a: Double, _ b: Double) -> Bool {
        if a.isNaN || b.isNaN {
            return a.isNaN && b.isNaN
        }
        return a == b && a.sign == b.sign
    }

    /// strcmp-style equality: the same UTF-8 bytes (Swift == is canonical equivalence).
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        Array(a.utf8) == Array(b.utf8)
    }

    static func run<T>(_ body: () throws(WxError) -> T) -> Result<T, WxError> {
        do {
            return .success(try body())
        } catch {
            return .failure(error)
        }
    }

    /// The value of a call that must succeed (g_assert_no_error + g_assert_nonnull).
    static func ok<T>(_ r: Result<T, WxError>, _ what: String = "", sourceLocation: SourceLocation = #_sourceLocation) -> T? {
        switch r {
        case .success(let v):
            return v
        case .failure(let e):
            Issue.record("\(what): unexpected error \(e.code) '\(e.message)'", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// A call that must fail with `code` (and `message` when given): g_assert_error.
    static func fails<T>(
        _ r: Result<T, WxError>, _ code: WxError.Code, _ message: String? = nil, _ what: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch r {
        case .success:
            Issue.record("\(what): expected error \(code), got a result", sourceLocation: sourceLocation)
        case .failure(let e):
            #expect(e.code == code, "\(what): code \(e.code) '\(e.message)'", sourceLocation: sourceLocation)
            if let message {
                #expect(sameBytes(e.message, message), "\(what): message '\(e.message)' != '\(message)'",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// forecast() (test-openmeteo.c:153-160): parse with FETCHED.
    static func forecast(_ text: String, _ models: [OpenMeteoModel]) -> Result<WxSourceResult, WxError> {
        forecast(bytes: b(text), models)
    }

    static func forecast(bytes: [UInt8], _ models: [OpenMeteoModel]) -> Result<WxSourceResult, WxError> {
        run { () throws(WxError) in try OpenMeteoParse.forecast(bytes, models: models, fetchedS: fetched) }
    }

    /// nowcast() (test-openmeteo.c:1244-1248).
    static func nowcast(_ text: String) -> Result<WxMember, WxError> {
        nowcast(bytes: b(text))
    }

    static func nowcast(bytes: [UInt8]) -> Result<WxMember, WxError> {
        run { () throws(WxError) in try OpenMeteoParse.nowcast(bytes, fetchedS: fetched) }
    }

    /// geocode() (test-openmeteo.c:1384-1388).
    static func geocode(_ text: String) -> Result<[WxPlace], WxError> {
        geocode(bytes: b(text))
    }

    static func geocode(bytes: [UInt8]) -> Result<[WxPlace], WxError> {
        run { () throws(WxError) in try OpenMeteoParse.geocode(bytes) }
    }

    /// assert_result_model_ids (test-openmeteo.c:131-139).
    static func expectModelIDs(_ result: WxSourceResult, _ ids: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.members.count == ids.count, sourceLocation: sourceLocation)
        for (i, id) in ids.enumerated() where i < result.members.count {
            #expect(result.members[i].sourceID == "open-meteo", sourceLocation: sourceLocation)
            #expect(result.members[i].modelID == id, sourceLocation: sourceLocation)
        }
    }

    /// hour_at (test-openmeteo.c:141-150).
    static func hourAt(_ member: WxMember, _ t: Int64) -> WxHour? {
        member.hours.first { $0.tS == t }
    }

    /// assert_hour (test-openmeteo.c:666-680).
    static func expectHour(
        _ h: WxHour?, _ t: Int64, _ temp: Double, _ feels: Double, _ hum: Double, _ precip: Double, _ prob: Double,
        _ cloud: Double, _ wind: Double, _ gust: Double, _ wmo: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let h else {
            Issue.record("no hour at \(t)", sourceLocation: sourceLocation)
            return
        }
        let fields: [(String, Double, Double)] = [
            ("temp", h.tempC, temp), ("feels", h.feelsC, feels), ("humidity", h.humidityPct, hum),
            ("precip", h.precipMm, precip), ("prob", h.precipProb, prob), ("cloud", h.cloudPct, cloud),
            ("wind", h.windKmh, wind), ("gust", h.gustKmh, gust),
        ]
        #expect(h.tS == t, "tS \(h.tS) != \(t)", sourceLocation: sourceLocation)
        for (name, got, want) in fields {
            #expect(same(got, want), "hour \(t) \(name): \(got) != \(want)", sourceLocation: sourceLocation)
        }
        #expect(h.wmo == wmo, "hour \(t) wmo: \(h.wmo) != \(wmo)", sourceLocation: sourceLocation)
    }

    /// body3 (test-openmeteo.c:655-663): a one-model body with 3 values per variable.
    static func body3(_ times: String) -> String {
        "{\"hourly\":{\"time\":" + times + ",\"temperature_2m\":[10,11,12],\"apparent_temperature\":[9,10,11],"
            + "\"relative_humidity_2m\":[50,51,52],\"precipitation\":[0.1,0.2,0.3],"
            + "\"precipitation_probability\":[10,20,30],\"cloud_cover\":[1,2,3],\"wind_speed_10m\":[5,6,7],"
            + "\"wind_gusts_10m\":[8,9,10],\"weather_code\":[0,3,61]}}"
    }

    static func list(_ values: [Int64]) -> String {
        "[" + values.map(String.init).joined(separator: ",") + "]"
    }

    /// times_text (test-openmeteo.c:790-798): n hourly stamps from T0.
    static func timesText(_ n: Int) -> String {
        list((0..<n).map { t0 + Int64($0) * 3600 })
    }

    // MARK: - Independent oracle (test-openmeteo.c:177-373)

    /// ExpHour (test-openmeteo.c:178-181): the 8 numbers in the order
    /// temp, feels, precip, prob, cloud, wind, gust, humidity.
    struct ExpHour {
        var t: Int64
        var v: [Double]
        var wmo: Int
    }

    /// onode_number (test-openmeteo.c:186-207), restated on WxJSON nodes.
    static func onodeNumber(_ node: WxJSON.Node?) -> Double? {
        switch node {
        case .some(.integer(let i)):
            if i == Int64.max || i == Int64.min {
                return nil
            }
            return Double(i)
        case .some(.double(let d)):
            return d.isFinite ? d : nil
        default:
            return nil
        }
    }

    /// oval (test-openmeteo.c:209-222).
    static func oval(_ hourly: WxJSON.Object, _ key: String, _ i: Int, _ lo: Double, _ hi: Double) -> Double {
        guard case .some(.array(let a)) = hourly.member(key), i < a.count, let v = onodeNumber(a[i]) else {
            return .nan
        }
        if v < lo || v > hi {
            return .nan
        }
        return v == 0 ? 0.0 : v
    }

    /// oracle_hours (test-openmeteo.c:233-316): the expected hours of one
    /// model, nil when it must be dropped. The C oracle scans every used stamp
    /// per bucket; used stamps are unique, so a stamp -> index map gives the
    /// same matches.
    static func oracleHours(_ hourly: WxJSON.Object, _ api: String, _ suffixed: Bool) -> [ExpHour]? {
        guard case .some(.array(let times)) = hourly.member("time") else {
            Issue.record("oracle: no time array")
            return nil
        }
        var stamps: [Int64] = []
        var indexOf: [Int64: Int] = [:]
        for i in 0..<times.count {
            guard let v = onodeNumber(times[i]) else {
                continue
            }
            if v < Double(timeMin) || v > Double(timeMax - 1) || v != v.rounded(.down) {
                continue
            }
            let t = Int64(v)
            if t % 3600 != 0 {
                continue
            }
            if let last = stamps.last, t <= last {
                continue
            }
            stamps.append(t)
            indexOf[t] = i
        }
        var buckets: [Int64] = []
        for t in stamps {
            buckets.append(t)
            buckets.append(t - 3600)
        }
        buckets.sort()
        // slots: temp 0, feels 1, precip 2, prob 3, cloud 4, wind 5, gust 6, humidity 7
        let vars: [(key: String, lo: Double, hi: Double, slot: Int)] = [
            ("temperature_2m", -100, 70, 0), ("apparent_temperature", -100, 70, 1),
            ("precipitation", 0, 500, 2), ("precipitation_probability", 0, 100, 3),
            ("cloud_cover", 0, 100, 4), ("wind_speed_10m", 0, 500, 5),
            ("wind_gusts_10m", 0, 500, 6), ("relative_humidity_2m", 0, 100, 7),
        ]
        let keys = vars.map { suffixed ? $0.key + "_" + api : $0.key }
        let wmoKey = suffixed ? "weather_code_" + api : "weather_code"
        var out: [ExpHour] = []
        var finiteTotal = 0
        var prev: Int64 = -1
        for t in buckets {
            if t == prev || t < timeMin {
                continue
            }
            prev = t
            var h = ExpHour(t: t, v: Array(repeating: .nan, count: 8), wmo: -1)
            for (n, v) in vars.enumerated() {
                let precipLike = v.slot == 2 || v.slot == 3
                if let i = indexOf[precipLike ? t + 3600 : t] {
                    h.v[v.slot] = oval(hourly, keys[n], i, v.lo, v.hi)
                }
            }
            if let i = indexOf[t] {
                let w = oval(hourly, wmoKey, i, 0, 99)
                h.wmo = (w.isNaN || w != w.rounded(.down)) ? -1 : Int(w)
            }
            let finite = h.v.reduce(0) { $0 + ($1.isFinite ? 1 : 0) }
            if finite == 0 && h.wmo < 0 {
                continue
            }
            finiteTotal += finite
            out.append(h)
        }
        return finiteTotal == 0 ? nil : out
    }

    /// assert_member_matches (test-openmeteo.c:319-337).
    static func expectMemberMatches(_ member: WxMember, _ exp: [ExpHour], sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let hours = member.hours
        guard hours.count == exp.count else {
            Issue.record("\(member.modelID): \(hours.count) hours, oracle \(exp.count)", sourceLocation: sourceLocation)
            return false
        }
        for (h, e) in zip(hours, exp) {
            let got = [h.tempC, h.feelsC, h.precipMm, h.precipProb, h.cloudPct, h.windKmh, h.gustKmh, h.humidityPct]
            var good = h.tS == e.t && h.wmo == e.wmo
            for s in 0..<8 {
                good = good && same(got[s], e.v[s])
            }
            if !good {
                Issue.record("\(member.modelID) hour \(h.tS): \(got) wmo \(h.wmo) != oracle \(e.t) \(e.v) wmo \(e.wmo)",
                             sourceLocation: sourceLocation)
                return false
            }
        }
        return true
    }

    /// assert_forecast_matches_oracle (test-openmeteo.c:341-374).
    @discardableResult
    static func expectMatchesOracle(
        _ text: [UInt8], _ models: [OpenMeteoModel], _ result: WxSourceResult, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        guard let root = try? WxJSON.parseObject(text, maxLength: 4 * 1024 * 1024), let hourly = root.object("hourly") else {
            Issue.record("oracle: body does not parse", sourceLocation: sourceLocation)
            return false
        }
        let ids = [
            "ncep_hrrr_conus": "hrrr", "ncep_nbm_conus": "nbm", "gfs_seamless": "gfs", "ecmwf_ifs025": "ecmwf",
            "icon_seamless": "icon", "gem_seamless": "gem", "ukmo_seamless": "ukmo", "meteofrance_seamless": "meteofrance",
        ]
        var next = 0
        for model in models {
            guard let id = ids[model.rawValue] else {
                Issue.record("oracle: unknown model \(model.rawValue)", sourceLocation: sourceLocation)
                return false
            }
            guard let exp = oracleHours(hourly, model.rawValue, models.count > 1) else {
                continue
            }
            guard next < result.members.count else {
                Issue.record("oracle: member \(id) missing", sourceLocation: sourceLocation)
                return false
            }
            let member = result.members[next]
            next += 1
            if member.modelID != id || member.sourceID != "open-meteo" || member.fetchedS != fetched
                || !member.quarters.isEmpty
            {
                Issue.record("oracle: member \(member.modelID) != \(id) or bad identity", sourceLocation: sourceLocation)
                return false
            }
            if !expectMemberMatches(member, exp, sourceLocation: sourceLocation) {
                return false
            }
        }
        if result.members.count != next {
            Issue.record("oracle: \(result.members.count) members, expected \(next)", sourceLocation: sourceLocation)
            return false
        }
        return true
    }

    // MARK: - Fixtures

    // C: /openmeteo/parse/miami-fixture (test-openmeteo.c:381-461)
    @Test func parseMiamiFixture() throws {
        let text = try Self.fixture("forecast_miami_multi.json")
        #expect(text.count <= 200 * 1024)  // :385
        guard let result = Self.ok(Self.forecast(bytes: text, Self.miamiModels)) else { return }
        #expect(result.providerID == "open-meteo")  // :390
        Self.expectModelIDs(result, Self.miamiIDs)
        guard result.members.count == 6 else { return }

        // GFS: 240 instants + the bucket of the first precipitation (:393-403)
        var hours = result.members[2].hours
        #expect(hours.count == 241)
        guard hours.count == 241 else { return }
        #expect(hours[0].tS == Self.t0 - 3600)
        #expect(hours[240].tS == Self.t0 + 239 * 3600)
        for i in 0..<hours.count {
            #expect(hours[i].tS % 3600 == 0)
            if i > 0 {
                #expect(hours[i].tS == hours[i - 1].tS + 3600)
            }
        }
        // Bucket T0 - 3600 holds ONLY the precipitation values stamped T0 (:405-414)
        #expect(Self.same(hours[0].precipMm, 0.0))
        #expect(Self.same(hours[0].precipProb, 1.0))
        #expect(hours[0].tempC.isNaN && hours[0].feelsC.isNaN && hours[0].cloudPct.isNaN)
        #expect(hours[0].windKmh.isNaN && hours[0].gustKmh.isNaN && hours[0].humidityPct.isNaN)
        #expect(hours[0].wmo == -1)
        // Bucket T0 (:415-425)
        #expect(Self.same(hours[1].tempC, 27.7))
        #expect(Self.same(hours[1].feelsC, 33.9))
        #expect(Self.same(hours[1].humidityPct, 86.0))
        #expect(Self.same(hours[1].cloudPct, 2.0))
        #expect(Self.same(hours[1].windKmh, 4.4))
        #expect(Self.same(hours[1].gustKmh, 9.7))
        #expect(hours[1].wmo == 0)
        #expect(Self.same(hours[1].precipMm, 0.0))
        #expect(Self.same(hours[1].precipProb, 1.0))
        // The last bucket: instants only (:426-429)
        #expect(!hours[240].tempC.isNaN)
        #expect(hours[240].precipMm.isNaN)
        #expect(hours[240].precipProb.isNaN)

        // HRRR (:431-441)
        hours = result.members[0].hours
        #expect(hours.count == 240)
        if hours.count == 240 {
            #expect(hours[0].tS == Self.t0 - 3600)
            #expect(!hours[61].tempC.isNaN)
            #expect(hours[61].tS == Self.t0 + 60 * 3600)
            #expect(hours[62].tempC.isNaN)
            #expect(hours[62].precipMm.isNaN)
            #expect(!hours[62].precipProb.isNaN)
            #expect(hours[62].wmo == -1)
        }
        // ICON (:442-444)
        #expect(result.members[4].hours.count == 194)
        // Every member (:445-459)
        for member in result.members {
            #expect(member.fetchedS == Self.fetched)
            #expect(member.quarters.isEmpty)
            for h in member.hours {
                #expect(h.tempC.isNaN || (h.tempC >= -100 && h.tempC <= 70))
                #expect(h.windKmh.isNaN || (h.windKmh >= 0 && h.windKmh <= 500))
                #expect(h.precipProb.isNaN || (h.precipProb >= 0 && h.precipProb <= 100))
            }
        }
        #expect(Self.expectMatchesOracle(text, Self.miamiModels, result))  // :459
    }

    // C: /openmeteo/parse/london-fixture (test-openmeteo.c:463-491)
    @Test func parseLondonFixture() throws {
        let text = try Self.fixture("forecast_london_multi.json")
        guard let result = Self.ok(Self.forecast(bytes: text, Self.londonModels)) else { return }
        Self.expectModelIDs(result, Self.londonIDs)
        guard result.members.count == 6 else { return }
        #expect(result.members[0].hours.count == 241)  // :474
        let mf = result.members[5].hours
        #expect(mf.count == 116)  // :476
        for h in mf {
            #expect(h.precipProb.isNaN)
        }
        if mf.count > 1 {
            #expect(Self.same(mf[1].tempC, 13.8))  // :479
            #expect(Self.same(mf[1].humidityPct, 74.0))
            #expect(mf[1].wmo == 3)
        }
        let ukmo = result.members[4].hours
        #expect(ukmo.count == 240)  // :484
        if ukmo.count == 240 {
            #expect(ukmo[169].tS == Self.t0 + 168 * 3600)
            #expect(!ukmo[169].tempC.isNaN)
            #expect(ukmo[170].tempC.isNaN)
            #expect(!ukmo[170].precipProb.isNaN)
        }
        #expect(Self.expectMatchesOracle(text, Self.londonModels, result))  // :489
    }

    /// A JSON text of `node` (json_generator_to_data stand-in for the test).
    private static func jsonText(_ node: WxJSON.Node, _ out: inout String) {
        switch node {
        case .object(let o):
            out += "{"
            for (k, name) in o.names.enumerated() {
                if k > 0 { out += "," }
                jsonText(.string(name), &out)
                out += ":"
                if let m = o.member(name) { jsonText(m, &out) }
            }
            out += "}"
        case .array(let a):
            out += "["
            for (k, e) in a.enumerated() {
                if k > 0 { out += "," }
                jsonText(e, &out)
            }
            out += "]"
        case .string(let s):
            out += "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            out += "\""
        case .integer(let i): out += String(i)
        case .double(let d): out += "\(d)"
        case .bool(let v): out += v ? "true" : "false"
        case .null: out += "null"
        }
    }

    // C: /openmeteo/parse/single-model-keys (test-openmeteo.c:493-549)
    @Test func parseSingleModelKeysAreNotSuffixed() throws {
        let text = try Self.fixture("forecast_miami_multi.json")
        let root = try WxJSON.parseObject(text, maxLength: 4 * 1024 * 1024)
        let hourly = try #require(root.object("hourly"))
        let vars = [
            "temperature_2m", "apparent_temperature", "relative_humidity_2m", "precipitation",
            "precipitation_probability", "cloud_cover", "wind_speed_10m", "wind_gusts_10m", "weather_code",
        ]
        var single = "{\"hourly\":{\"time\":"
        Self.jsonText(try #require(hourly.member("time")), &single)
        for v in vars {
            single += ",\"" + v + "\":"
            Self.jsonText(try #require(hourly.member(v + "_ecmwf_ifs025")), &single)
        }
        single += "}}"

        let one: [OpenMeteoModel] = [.ecmwfIfs025]
        guard let result = Self.ok(Self.forecast(single, one)) else { return }
        Self.expectModelIDs(result, ["ecmwf"])
        guard let multi = Self.ok(Self.forecast(bytes: text, Self.miamiModels)), multi.members.count > 3,
              let a = result.members.first?.hours else { return }
        let bh = multi.members[3].hours
        #expect(a.count == bh.count)  // :529
        for (x, y) in zip(a, bh) {
            Self.expectHour(x, y.tS, y.tempC, y.feelsC, y.humidityPct, y.precipMm, y.precipProb, y.cloudPct,
                            y.windKmh, y.gustKmh, y.wmo)
        }
        // Keys of the other form are not found (:534-548)
        Self.fails(Self.forecast(single, Self.miamiModels), .notFound)
        Self.fails(Self.forecast(single, [.ecmwfIfs025, .gfsSeamless]), .notFound)
        Self.fails(Self.forecast(bytes: text, one), .notFound)
    }

    // C: /openmeteo/parse/nowcast-fixture (test-openmeteo.c:551-576)
    @Test func parseNowcastFixture() throws {
        let text = try Self.fixture("nowcast_miami.json")
        guard let member = Self.ok(Self.nowcast(bytes: text)) else { return }
        #expect(member.sourceID == "open-meteo")
        #expect(member.modelID == "hrrr15")
        #expect(member.fetchedS == Self.fetched)
        #expect(member.hours.isEmpty)
        let q = member.quarters
        #expect(q.count == 12)  // :565
        guard q.count == 12 else { return }
        #expect(q[0].tS == 1_791_832_500 - 900)  // :567
        #expect(q[11].tS == 1_791_842_400 - 900)  // :568
        for i in 0..<q.count {
            #expect(q[i].tS % 900 == 0)
            #expect(Self.same(q[i].precipMm, 0.0))
            if i > 0 {
                #expect(q[i].tS == q[i - 1].tS + 900)
            }
        }
    }

    // C: /openmeteo/parse/error-fixture (test-openmeteo.c:607-648)
    @Test func parseErrorFixture() throws {
        let text = try Self.fixture("error_400.json")
        Self.fails(Self.forecast(bytes: text, Self.miamiModels), .http,
                   "Open-Meteo reported an error: Invalid value: Cannot initialize MultiDomains from "
                       + "invalid String value bogus_model")  // :615-616
        Self.fails(Self.nowcast(bytes: text), .http)
        Self.fails(Self.geocode(bytes: text), .http)
        // Variants (:627-647)
        Self.fails(Self.forecast("{\"error\":true}", Self.miamiModels), .http, "Open-Meteo reported an error: ")
        Self.fails(Self.forecast("{\"error\":true,\"reason\":\"a\\u0001b\\u202ec\\n%s%n\"}", Self.miamiModels), .http,
                   "Open-Meteo reported an error: abc%s%n")
        let longer = "{\"error\":true,\"reason\":\"" + String(repeating: "0", count: 199) + "7\"}"  // "%0200d" of 7
        if case .failure(let e) = Self.forecast(longer, Self.miamiModels) {
            #expect(e.code == .http)
            #expect(e.message.utf8.count == "Open-Meteo reported an error: ".utf8.count + 120)  // :642
        } else {
            Issue.record("long reason: expected an error")
        }
        Self.fails(Self.forecast("{\"error\":false,\"reason\":\"x\"}", Self.miamiModels), .parse)  // :644-647
    }

    // MARK: - Stamp and bucket semantics

    // C: /openmeteo/parse/bucket-times (test-openmeteo.c:683-715)
    @Test func parseBucketTimes() {
        let t0 = Self.t0
        let nan = Double.nan
        if let r = Self.ok(Self.forecast(Self.body3(Self.list([t0, t0 + 3600, t0 + 7200])), Self.gfsOnly)),
           let h = r.members.first?.hours
        {
            #expect(h.count == 4)
            if h.count == 4 {
                Self.expectHour(h[0], t0 - 3600, nan, nan, nan, 0.1, 10, nan, nan, nan, -1)
                Self.expectHour(h[1], t0, 10, 9, 50, 0.2, 20, 1, 5, 8, 0)
                Self.expectHour(h[2], t0 + 3600, 11, 10, 51, 0.3, 30, 2, 6, 9, 3)
                Self.expectHour(h[3], t0 + 7200, 12, 11, 52, nan, nan, 3, 7, 10, 61)
            }
        }
        // A gap (:701-713)
        if let r = Self.ok(Self.forecast(Self.body3(Self.list([t0, t0 + 3 * 3600, t0 + 4 * 3600])), Self.gfsOnly)),
           let h = r.members.first?.hours
        {
            #expect(h.count == 5)
            if h.count == 5 {
                Self.expectHour(h[0], t0 - 3600, nan, nan, nan, 0.1, 10, nan, nan, nan, -1)
                Self.expectHour(h[1], t0, 10, 9, 50, nan, nan, 1, 5, 8, 0)
                Self.expectHour(h[2], t0 + 2 * 3600, nan, nan, nan, 0.2, 20, nan, nan, nan, -1)
                Self.expectHour(h[3], t0 + 3 * 3600, 11, 10, 51, 0.3, 30, 2, 6, 9, 3)
                Self.expectHour(h[4], t0 + 4 * 3600, 12, 11, 52, nan, nan, 3, 7, 10, 61)
            }
        }
    }

    /// assert_used_stamps (test-openmeteo.c:716-727).
    static func expectUsedStamps(_ times: String, _ hours: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        if let r = ok(forecast(body3(times), gfsOnly), times, sourceLocation: sourceLocation) {
            #expect(r.members.first?.hours.count == hours, "\(times)", sourceLocation: sourceLocation)
        }
    }

    // C: /openmeteo/parse/time-entries-skipped (test-openmeteo.c:730-789)
    @Test func parseTimeEntriesSkipped() {
        let t0 = Self.t0
        let nan = Double.nan
        let t = String(t0)
        Self.expectUsedStamps("[\(t),\(t),\(t)]", 2)
        Self.expectUsedStamps("[\(t),\(t0 - 3600),\(t0 - 7200)]", 2)
        Self.expectUsedStamps("[\(t),\(t0 + 1800),\(t0 + 3601)]", 2)
        Self.expectUsedStamps("[\(t),\(t0 + 3600).5,\(t0 + 7200).25]", 2)
        Self.expectUsedStamps("[\(t),\"\(t0 + 3600)\",null]", 2)
        Self.expectUsedStamps("[\(t),true,{},[],-1,1e30,1e999,9223372036854775807]", 2)
        // The skipped index contributes nothing (:746-762)
        let second = ["[\(t),\(t),\(t0 + 3600)]", "[\(t),\(t0 - 3600),\(t0 + 3600)]", "[\(t),\(t0 + 1800),\(t0 + 3600)]"]
        for times in second {
            guard let r = Self.ok(Self.forecast(Self.body3(times), Self.gfsOnly), times), let sh = r.members.first?.hours
            else { continue }
            #expect(sh.count == 3, "\(times)")
            if sh.count == 3 {
                Self.expectHour(sh[0], t0 - 3600, nan, nan, nan, 0.1, 10, nan, nan, nan, -1)
                Self.expectHour(sh[1], t0, 10, 9, 50, 0.3, 30, 1, 5, 8, 0)
                Self.expectHour(sh[2], t0 + 3600, 12, 11, 52, nan, nan, 3, 7, 10, 61)
            }
        }
        // the epoch bounds (:764-788)
        let min = Self.timeMin
        let max = Self.timeMax
        if let r = Self.ok(Self.forecast(Self.body3(Self.list([min - 3600, min, min + 3600])), Self.gfsOnly)),
           let h = r.members.first?.hours
        {
            #expect(h.count == 2)
            if h.count == 2 {
                #expect(h[0].tS == min)
                #expect(Self.same(h[0].tempC, 11))
                #expect(Self.same(h[0].precipMm, 0.3))
                #expect(h[1].tS == min + 3600)
            }
        }
        if let r = Self.ok(Self.forecast(Self.body3(Self.list([max - 3600, max])), Self.gfsOnly)),
           let h = r.members.first?.hours
        {
            #expect(h.count == 2)
            if h.count == 2 {
                #expect(h[1].tS == max - 3600)
            }
        }
    }

    // C: /openmeteo/parse/time-step-limit (test-openmeteo.c:801-839)
    @Test func parseTimeStepLimit() {
        #expect(OpenMeteoShared.maxTimeSteps == 384)  // :803
        let at = Self.timesText(384)
        if let r = Self.ok(Self.forecast(Self.body3(at), Self.gfsOnly)) {
            #expect(r.members.first?.hours.count == 3 + 1)  // :811
        }
        Self.fails(Self.forecast(Self.body3(Self.timesText(385)), Self.gfsOnly), .parse,
                   "response has too many time steps")  // :818
        // A full 384-stamp series fills 385 buckets (:821-838)
        var s = "{\"hourly\":{\"time\":" + at + ",\"temperature_2m\":["
        s += (0..<384).map { String($0 % 40) }.joined(separator: ",")
        s += "],\"precipitation\":["
        s += Array(repeating: "0.5", count: 384).joined(separator: ",")
        s += "]}}"
        if let r = Self.ok(Self.forecast(s, Self.gfsOnly)), let h = r.members.first?.hours {
            #expect(h.count == 384 + 1)
            #expect(h.count <= 400)
            if let last = h.last {
                #expect(Self.same(last.tempC, Double((384 - 1) % 40)))
            }
        }
    }

    // C: /openmeteo/parse/gapped-series-member-limit (test-openmeteo.c:843-879)
    @Test func parseGappedSeriesIsCutAtMemberLimit() {
        let t0 = Self.t0
        var s = "{\"hourly\":{\"time\":" + Self.list((0..<384).map { t0 + Int64($0) * 7200 }) + ",\"temperature_2m\":["
        s += (0..<384).map { String($0 % 40) }.joined(separator: ",")
        s += "],\"precipitation\":["
        s += Array(repeating: "0.5", count: 384).joined(separator: ",")
        s += "]}}"
        guard let r = Self.ok(Self.forecast(s, Self.gfsOnly)), let h = r.members.first?.hours else { return }
        #expect(h.count == 400)  // :861
        guard h.count == 400 else { return }
        for b in 0..<h.count {
            let k = Int64(b / 2)
            if b % 2 == 0 {
                #expect(h[b].tS == t0 + k * 7200 - 3600)
                #expect(Self.same(h[b].precipMm, 0.5))
                #expect(h[b].tempC.isNaN)
            } else {
                #expect(h[b].tS == t0 + k * 7200)
                #expect(Self.same(h[b].tempC, Double(k % 40)))
                #expect(h[b].precipMm.isNaN)
            }
        }
        #expect(h[399].tS == t0 + 199 * 7200)  // :875
        #expect(Self.same(h[399].tempC, 39.0))
    }

    // C: /openmeteo/parse/value-ranges (test-openmeteo.c:881-967)
    @Test func parseValueRanges() {
        let t0 = Self.t0
        let nan = Double.nan
        let rows: [(key: String, values: String, expect: [Double], field: (WxHour) -> Double)] = [
            ("temperature_2m", "[-100,70,-100.0001,70.0001,-101,71,1e308,-1e308]", [-100, 70, nan, nan, nan, nan, nan, nan], { $0.tempC }),
            ("apparent_temperature", "[-100,70,-100.1,70.1,0,-0.0,5e-324,\"3\"]", [-100, 70, nan, nan, 0, 0, 5e-324, nan], { $0.feelsC }),
            ("relative_humidity_2m", "[0,100,-0.1,100.1,-1,101,true,null]", [0, 100, nan, nan, nan, nan, nan, nan], { $0.humidityPct }),
            ("cloud_cover", "[0,100,-1,101,1e999,-1e999,[1],{\"a\":1}]", [0, 100, nan, nan, nan, nan, nan, nan], { $0.cloudPct }),
            ("wind_speed_10m", "[0,500,-0.01,500.01,-5,501,1e30,9223372036854775807]", [0, 500, nan, nan, nan, nan, nan, nan], { $0.windKmh }),
            ("wind_gusts_10m", "[0,500,-0.01,500.01,-9223372036854775808,2,2.5,\"x\"]", [0, 500, nan, nan, nan, 2, 2.5, nan], { $0.gustKmh }),
        ]
        let times = Self.list((0..<8).map { t0 + Int64($0) * 3600 })
        for row in rows {
            let text = "{\"hourly\":{\"time\":" + times + ",\"" + row.key + "\":" + row.values + "}}"
            guard let r = Self.ok(Self.forecast(text, Self.gfsOnly), row.key), let m = r.members.first else { continue }
            for i in 0..<8 {
                let got = Self.hourAt(m, t0 + Int64(i) * 3600).map(row.field) ?? nan
                #expect(Self.same(got, row.expect[i]), "\(row.key) index \(i): got \(got) expected \(row.expect[i])")
            }
        }
        // Precipitation and probability land in bucket T - 3600 (:933-963)
        let text = "{\"hourly\":{\"time\":" + times + ",\"precipitation\":[0,500,-0.1,500.5,2,1e999,null,\"1\"],"
            + "\"precipitation_probability\":[0,100,-1,100.5,50,1e999,null,\"1\"],\"weather_code\":[0,99,100,-1,3.5,\"3\",null,7]}}"
        guard let r = Self.ok(Self.forecast(text, Self.gfsOnly)), let m = r.members.first else { return }
        let pe: [Double] = [0, 500, nan, nan, 2, nan, nan, nan]
        let qe: [Double] = [0, 100, nan, nan, 50, nan, nan, nan]
        let we = [0, 99, -1, -1, -1, -1, -1, 7]
        for i in 0..<8 {
            let p = Self.hourAt(m, t0 + Int64(i) * 3600 - 3600)
            if !pe[i].isNaN || !qe[i].isNaN {
                #expect(p != nil, "index \(i)")
            }
            if let p {
                #expect(Self.same(p.precipMm, pe[i]), "precip index \(i)")
                #expect(Self.same(p.precipProb, qe[i]), "prob index \(i)")
            }
            let w = Self.hourAt(m, t0 + Int64(i) * 3600)
            if we[i] >= 0 {
                #expect(w?.wmo == we[i], "wmo index \(i)")
            } else if let w {
                #expect(w.wmo == -1, "wmo index \(i)")
            }
        }
    }

    // C: /openmeteo/parse/negative-zero-subnormal (test-openmeteo.c:969-988)
    @Test func parseNegativeZeroAndSubnormal() {
        let text = "{\"hourly\":{\"time\":[\(Self.t0)],\"temperature_2m\":[-0.0],\"precipitation\":[-0.0],"
            + "\"wind_speed_10m\":[-0],\"cloud_cover\":[4.9e-324]}}"
        guard let r = Self.ok(Self.forecast(text, Self.gfsOnly)), let m = r.members.first else { return }
        let h = Self.hourAt(m, Self.t0)
        #expect(h != nil)
        #expect(Self.same(h?.tempC ?? .nan, 0.0))  // +0, not -0 (:981)
        #expect(Self.same(h?.windKmh ?? .nan, 0.0))
        #expect(Self.same(h?.cloudPct ?? .nan, 4.9e-324))
        let p = Self.hourAt(m, Self.t0 - 3600)
        #expect(Self.same(p?.precipMm ?? .nan, 0.0))  // :986
    }

    // C: /openmeteo/parse/ragged-arrays (test-openmeteo.c:990-1013)
    @Test func parseRaggedArrays() {
        let t0 = Self.t0
        let nan = Double.nan
        let text = "{\"hourly\":{\"time\":" + Self.timesText(4) + ",\"temperature_2m\":[1,null,3],\"apparent_temperature\":\"x\","
            + "\"relative_humidity_2m\":{\"a\":1},\"precipitation\":[0.5,0.5,0.5,0.5,0.5,0.5,0.5],"
            + "\"precipitation_probability\":null,\"cloud_cover\":[],\"wind_speed_10m\":[7,8,9,10],"
            + "\"wind_gusts_10m\":[1],\"weather_code\":[1,2]}}"
        guard let r = Self.ok(Self.forecast(text, Self.gfsOnly)), let h = r.members.first?.hours else { return }
        #expect(h.count == 5)
        if h.count == 5 {
            Self.expectHour(h[0], t0 - 3600, nan, nan, nan, 0.5, nan, nan, nan, nan, -1)
            Self.expectHour(h[1], t0, 1, nan, nan, 0.5, nan, nan, 7, 1, 1)
            Self.expectHour(h[2], t0 + 3600, nan, nan, nan, 0.5, nan, nan, 8, nan, 2)
            Self.expectHour(h[3], t0 + 7200, 3, nan, nan, 0.5, nan, nan, 9, nan, -1)
            Self.expectHour(h[4], t0 + 10800, nan, nan, nan, nan, nan, nan, 10, nan, -1)
        }
        #expect(Self.expectMatchesOracle(Self.b(text), Self.gfsOnly, r))
    }

    // C: /openmeteo/parse/dropped-models (test-openmeteo.c:1015-1052)
    @Test func parseDroppedModels() {
        let times = Self.timesText(3)
        let text = "{\"hourly\":{\"time\":" + times + ","
            + "\"temperature_2m_gfs_seamless\":[1,2,3],"
            + "\"temperature_2m_ecmwf_ifs025\":[null,null,null],\"precipitation_ecmwf_ifs025\":[],"
            + "\"weather_code_icon_seamless\":[1,2,3]}}"
        let three: [OpenMeteoModel] = [.gfsSeamless, .ecmwfIfs025, .iconSeamless]
        if let r = Self.ok(Self.forecast(text, three)) {
            Self.expectModelIDs(r, ["gfs"])
            #expect(Self.expectMatchesOracle(Self.b(text), three, r))
        }
        Self.fails(Self.forecast(text, [.ecmwfIfs025, .iconSeamless]), .notFound, "no usable forecast data")  // :1039
        Self.fails(Self.forecast("{\"hourly\":{\"time\":" + times + "}}", Self.miamiModels), .notFound)
        Self.fails(Self.forecast("{\"hourly\":{\"time\":[1,2,3],\"temperature_2m\":[1,2,3]}}", Self.gfsOnly), .notFound)
    }

    // C: /openmeteo/parse/hostile-bodies (test-openmeteo.c:1054-1135)
    @Test func parseHostileBodies() {
        let syntaxBad: [[UInt8]] = [
            Self.b(""),
            Self.b("{"),
            Self.b("[]"),
            Self.b("[{}]"),
            Self.b("null"),
            Self.b("\"{}\""),
            Self.b("{}{}"),
            Self.b("{\"hourly\":"),
            [0xEF, 0xBB, 0xBF] + Self.b("{\"hourly\":{\"time\":[]}}"),
            Self.b("{\"hourly\":{\"time\":[]},\"hourly\":{}}"),
            Self.b("{\"hourly\":{\"time\":[1],\"temperature_2m\":[") + [0xFF] + Self.b("]}}"),
            Self.b("{\"hourly\":{\"time\":[1],\"temperature_2m\":[01]}}"),
            Self.b("{\"hourly\":{\"time\":[1],\"temperature_2m\":[1e]}}"),
        ]
        for (i, body) in syntaxBad.enumerated() {
            Self.fails(Self.forecast(bytes: body, Self.miamiModels), .parse, nil, "syntax_bad[\(i)]")
        }
        let shapeBad = [
            "{\"hourly\":\"x\"}",
            "{\"hourly\":[]}",
            "{\"hourly\":null}",
            "{\"hourly\":{}}",
            "{\"hourly\":{\"time\":null}}",
            "{\"hourly\":{\"time\":{}}}",
            "{\"hourly\":{\"time\":\"2026\"}}",
            "{\"hourly\":{\"time\":5}}",
            "{\"other\":{\"time\":[1]}}",
            "{}",
        ]
        for text in shapeBad {
            Self.fails(Self.forecast(text, Self.miamiModels), .parse, "response has no hourly time array", text)
        }
        Self.fails(Self.forecast("{\"hourly\":{\"time\":[]}}", Self.miamiModels), .notFound)  // :1098-1102
        // Deep nesting, >1024 members, a body above the cap (:1105-1133)
        let deep = "{\"hourly\":{\"time\":[],\"x\":" + String(repeating: "[", count: 40) + String(repeating: "]", count: 40) + "}}"
        Self.fails(Self.forecast(deep, Self.miamiModels), .parse)
        let many = "{\"hourly\":{\"time\":[]" + (0..<1100).map { ",\"k\($0)\":1" }.joined() + "}}"
        Self.fails(Self.forecast(many, Self.miamiModels), .parse)
        // WX_HTTP_MAX_BODY_BYTES + 1 spaces (4 MiB, src/net/wx-http.h)
        Self.fails(Self.forecast(bytes: [UInt8](repeating: 0x20, count: 4 * 1024 * 1024 + 1), Self.miamiModels), .parse)
    }

    // C: /openmeteo/parse/programmer-errors (test-openmeteo.c:1137-1202) - the
    // behavioural part. The criticals of C (NULL data with a length, unknown,
    // repeated or too many models) are argument errors in Swift: an unknown
    // name has no OpenMeteoModel, and a bad list throws .invalidArg.
    @Test func parseProgrammerErrorsAndFetchTime() {
        let text = "{\"hourly\":{\"time\":[]}}"
        for name in ["bogus_model", "GFS_SEAMLESS", "gfs", "", "gfs_seamless "] {
            #expect(OpenMeteoModel(apiName: name) == nil, "\(name)")  // :1149-1153
        }
        #expect(OpenMeteoModel(apiName: nil) == nil)  // :1157 (a NULL name)
        #expect(OpenMeteoModel(apiName: "gfs_seamless") == .gfsSeamless)
        Self.fails(Self.forecast(text, []), .invalidArg)  // :1146 (n_models 0)
        Self.fails(Self.forecast(text, [.gfsSeamless, .ecmwfIfs025, .gfsSeamless]), .invalidArg)  // :1155
        Self.fails(Self.forecast(text, OpenMeteoModel.allCases + [.gfsSeamless]), .invalidArg)  // :1148 (9 models)
        // An empty body is a parse error (:1165-1172)
        Self.fails(Self.forecast(bytes: [], Self.miamiModels), .parse)
        Self.fails(Self.nowcast(bytes: []), .parse)
        Self.fails(Self.geocode(bytes: []), .parse)
        Self.fails(Self.forecast("x", Self.miamiModels), .parse)  // :1175-1178
        Self.fails(Self.nowcast("x"), .parse)
        Self.fails(Self.geocode("x"), .parse)
        // fetched_s outside [MIN, MAX) is INVALID_ARG, checked before the body (:1180-1190)
        let badTimes: [Int64] = [Int64.min, -1, 0, Self.timeMin - 1, Self.timeMax, Int64.max]
        for t in badTimes {
            Self.fails(Self.run { () throws(WxError) in
                try OpenMeteoParse.forecast(Self.b("not json"), models: Self.miamiModels, fetchedS: t)
            }, .invalidArg, "invalid fetch time", "\(t)")
            Self.fails(Self.run { () throws(WxError) in try OpenMeteoParse.nowcast(Self.b("not json"), fetchedS: t) },
                       .invalidArg, nil, "\(t)")
        }
        let body = Self.b("{\"hourly\":{\"time\":[1791763200],\"temperature_2m\":[1]}}")
        _ = Self.ok(Self.run { () throws(WxError) in
            try OpenMeteoParse.forecast(body, models: Self.gfsOnly, fetchedS: Self.timeMin)
        })
        let hi = Self.ok(Self.run { () throws(WxError) in
            try OpenMeteoParse.forecast(body, models: Self.gfsOnly, fetchedS: Self.timeMax - 1)
        })
        #expect(hi?.members.first?.fetchedS == Self.timeMax - 1)  // :1200
    }

    // C: /openmeteo/parse/guard-pages (test-openmeteo.c:1204-1239) - the
    // behavioural part: a body cut at every length below min(len, 64) is a
    // parse error (the guard-page read check itself is memory layout, which
    // Swift's bounds-checked collections make moot).
    @Test func parseTruncatedBodiesFail() throws {
        let texts = [
            try Self.fixture("forecast_miami_multi.json"), try Self.fixture("nowcast_miami.json"),
            try Self.fixture("geocode_miami.json"), Self.b("{\"hourly\":{\"time\":[]}}"), Self.b("{}"), Self.b("x"),
        ]
        for text in texts {
            // the whole text never crashes any parser
            _ = Self.forecast(bytes: text, Self.miamiModels)
            _ = Self.nowcast(bytes: text)
            _ = Self.geocode(bytes: text)
            for cut in 0..<Swift.min(text.count, 64) {
                if case .success = Self.forecast(bytes: Array(text[0..<cut]), Self.miamiModels) {
                    Issue.record("a body cut at \(cut) bytes parsed")
                }
            }
        }
    }

    // MARK: - Nowcast

    // C: /openmeteo/parse/nowcast-semantics (test-openmeteo.c:1251-1321)
    @Test func parseNowcastSemantics() {
        let b: Int64 = 1_791_832_500
        let text = "{\"minutely_15\":{\"time\":[\(b),\(b + 900),\(b + 1800),\(b + 2700),\(b + 3600)],"
            + "\"precipitation\":[0.25,1.5,null,\"2\",500]}}"
        if let m = Self.ok(Self.nowcast(text)) {
            let q = m.quarters
            #expect(q.count == 3)
            if q.count == 3 {
                #expect(q[0].tS == b - 900)
                #expect(Self.same(q[0].precipMm, 0.25))
                #expect(q[1].tS == b)
                #expect(Self.same(q[1].precipMm, 1.5))
                #expect(q[2].tS == b + 2700)
                #expect(Self.same(q[2].precipMm, 500.0))
            }
        }
        // Skipped entries (:1272-1286)
        let odd = "{\"minutely_15\":{\"time\":[\(b),\(b + 450),\(b),\(b - 900),\(b + 900),\"x\",null,1e30,\(b + 1800).5,\(b + 2700)],"
            + "\"precipitation\":[1,1,1,1,1,1,1,1,1,0.5,7]}}"
        if let m = Self.ok(Self.nowcast(odd)) {
            let q = m.quarters
            #expect(q.count == 3)
            if q.count == 3 {
                #expect(q[0].tS == b - 900)
                #expect(q[1].tS == b)
                #expect(q[2].tS == b + 1800)
                #expect(Self.same(q[2].precipMm, 0.5))
            }
        }
        // Bad amounts (:1287-1297)
        let amounts = "{\"minutely_15\":{\"time\":[\(b),\(b + 900),\(b + 1800),\(b + 2700)],"
            + "\"precipitation\":[-0.01,500.01,1e999,-0.0]}}"
        if let m = Self.ok(Self.nowcast(amounts)) {
            #expect(m.quarters.count == 1)
            #expect(Self.same(m.quarters.first?.precipMm ?? .nan, 0.0))  // -0.0 is stored as +0
        }
        // Shorter amounts array (:1299-1307)
        let shorter = "{\"minutely_15\":{\"time\":[\(b),\(b + 900)],\"precipitation\":[3]}}"
        if let m = Self.ok(Self.nowcast(shorter)) {
            #expect(m.quarters.count == 1)
            #expect(m.quarters.first?.tS == b - 900)
        }
        // Epoch edges (:1310-1318)
        let edge = "{\"minutely_15\":{\"time\":[\(Self.timeMin),\(Self.timeMin + 900)],\"precipitation\":[1,2]}}"
        if let m = Self.ok(Self.nowcast(edge)) {
            #expect(m.quarters.count == 1)
            #expect(m.quarters.first?.tS == Self.timeMin)
        }
    }

    // C: /openmeteo/parse/nowcast-errors (test-openmeteo.c:1323-1379)
    @Test func parseNowcastErrors() {
        let noData = "response has no 15-minute data"
        let cases: [(String, WxError.Code, String?)] = [
            ("", .parse, nil),
            ("[]", .parse, nil),
            ("{", .parse, nil),
            ("{}", .parse, noData),
            ("{\"minutely_15\":null}", .parse, noData),
            ("{\"minutely_15\":[]}", .parse, noData),
            ("{\"minutely_15\":{\"time\":[1]}}", .parse, noData),
            ("{\"minutely_15\":{\"precipitation\":[1]}}", .parse, noData),
            ("{\"minutely_15\":{\"time\":\"x\",\"precipitation\":[1]}}", .parse, noData),
            ("{\"minutely_15\":{\"time\":[1],\"precipitation\":{}}}", .parse, noData),
            ("{\"minutely_15\":{\"time\":[],\"precipitation\":[]}}", .notFound, "no usable nowcast data"),
            ("{\"minutely_15\":{\"time\":[1791832500],\"precipitation\":[null]}}", .notFound, "no usable nowcast data"),
            ("{\"minutely_15\":{\"time\":[1791832501],\"precipitation\":[1]}}", .notFound, "no usable nowcast data"),
            ("{\"minutely_15_x\":{\"time\":[1791832500],\"precipitation_hourly\":[1]}}", .parse, noData),
            ("{\"error\":true,\"reason\":\"nope\"}", .http, "Open-Meteo reported an error: nope"),
        ]
        for (text, code, message) in cases {
            Self.fails(Self.nowcast(text), code, message, text)
        }
        // WX_MEMBER_MAX_QUARTERS (1536) entries are accepted, one more is refused (:1354-1374)
        for k in 0..<2 {
            let n = 1536 + k
            let s = "{\"minutely_15\":{\"time\":" + Self.list((0..<n).map { 1_791_832_500 + Int64($0) * 900 })
                + ",\"precipitation\":[" + Array(repeating: "0.1", count: n).joined(separator: ",") + "]}}"
            if k == 0 {
                #expect(Self.ok(Self.nowcast(s))?.quarters.count == 1536)
            } else {
                Self.fails(Self.nowcast(s), .parse, "response has too many time steps")
            }
        }
    }
}
