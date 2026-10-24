// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoParseGeocodeTests.swift - the geocode cases of the
// /openmeteo/parse/ group of src/providers/openmeteo/test-openmeteo.c (suite
// OpenMeteoParseTests; helpers in OpenMeteoParseTests.swift). Strings are
// compared byte for byte (strcmp), never with Swift's canonical-equivalence
// ==. C \xNN sequences of valid UTF-8 are written as the same scalar
// (\u{...}); C JSON escapes such as "\\u0001" stay backslash-u text.

import Foundation
import Testing
@testable import WeatherCore

extension OpenMeteoParseTests {
    // MARK: - Helpers (test-openmeteo.c:3564-3583, :3730-3773)

    /// oracle_forbidden (test-openmeteo.c:3571-3575): the forbidden characters as the header lists them.
    static func oracleForbidden(_ c: UInt32) -> Bool {
        (c >= 0x01 && c <= 0x1F) || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || c == 0x061C
            || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)
    }

    /// oracle_space (test-openmeteo.c:3579-3583): the white space that is not forbidden (category Zs).
    static func oracleSpace(_ c: UInt32) -> Bool {
        c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x205F
            || c == 0x3000
    }

    /// json_escape (test-openmeteo.c:3730-3742): quote and backslash escaped,
    /// bytes below 0x20 as \u00xx, every other byte raw.
    static func jsonEscape(_ out: inout [UInt8], _ text: String) {
        let hex = Array("0123456789abcdef".utf8)
        for p in text.utf8 {
            if p == 0x22 || p == 0x5C {
                out.append(0x5C)
                out.append(p)
            } else if p < 0x20 {
                out += Array("\\u00".utf8) + [hex[Int(p >> 4)], hex[Int(p & 0x0F)]]
            } else {
                out.append(p)
            }
        }
    }

    /// append_hit (test-openmeteo.c:3746-3762): one hit with the given texts (nil: member absent).
    static func appendHit(
        _ body: inout [UInt8], _ name: String?, _ admin1: String?, _ country: String?, _ code: String?, _ tz: String?
    ) {
        let keys = ["name", "admin1", "country", "country_code", "timezone"]
        let vals = [name, admin1, country, code, tz]
        if body.last != 0x5B {
            body.append(0x2C)
        }
        body += b("{\"latitude\":1,\"longitude\":2")
        for (key, val) in zip(keys, vals) {
            guard let val else { continue }
            body += b(",\"" + key + "\":\"")
            jsonEscape(&body, val)
            body.append(0x22)
        }
        body.append(0x7D)
    }

    /// parse_hits (test-openmeteo.c:3765-3773): closes the body, parses it, expects success.
    static func parseHits(_ body: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) -> [WxPlace] {
        ok(geocode(bytes: body + b("]}")), "parse_hits", sourceLocation: sourceLocation) ?? []
    }

    static func scalarString(_ c: UInt32) -> String {
        String(Character(Unicode.Scalar(c)!))
    }

    static func expectPlaceTexts(
        _ p: WxPlace, _ name: String, _ admin1: String, _ country: String, _ what: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(sameBytes(p.name, name), "\(what) name '\(p.name)' != '\(name)'", sourceLocation: sourceLocation)
        #expect(sameBytes(p.admin1, admin1), "\(what) admin1 '\(p.admin1)' != '\(admin1)'", sourceLocation: sourceLocation)
        #expect(sameBytes(p.country, country), "\(what) country '\(p.country)' != '\(country)'", sourceLocation: sourceLocation)
    }

    // MARK: - Fixture

    // C: /openmeteo/parse/geocode-fixture (test-openmeteo.c:578-605)
    @Test func parseGeocodeFixture() throws {
        let text = try Self.fixture("geocode_miami.json")
        guard let places = Self.ok(Self.geocode(bytes: text)) else { return }
        #expect(places.count == 10)  // :585
        guard places.count == 10 else { return }
        let first = places[0]
        #expect(first.name == "Miami")
        #expect(first.admin1 == "Florida")
        #expect(first.country == "United States")
        #expect(first.countryCode == "US")
        #expect(first.timezone == "America/New_York")
        #expect(Self.same(first.lat, 25.77427))  // :592
        #expect(Self.same(first.lon, -80.19366))
        #expect(first.label == "Miami, Florida, United States")  // :595
        #expect(first.key == "25.7743,-80.1937")  // :597
        #expect(places[9].admin1 == "Manitoba")
        #expect(places[9].countryCode == "CA")
        #expect(places[9].timezone == "America/Winnipeg")
        #expect(places[7].timezone == "America/Indiana/Indianapolis")  // :603
    }

    // MARK: - Shapes and texts

    // C: /openmeteo/parse/geocode-shapes (test-openmeteo.c:1391-1431)
    @Test func parseGeocodeShapes() {
        for text in ["{}", "{\"generationtime_ms\":0.5}", "{\"results\":null}", "{\"results\":[]}"] {
            #expect(Self.ok(Self.geocode(text), text)?.count == 0, "\(text)")
        }
        for text in ["{\"results\":{}}", "{\"results\":\"x\"}", "{\"results\":5}", "{\"results\":true}", "[]", "",
                     "{\"results\":["] {
            Self.fails(Self.geocode(text), .parse, nil, text)
        }
        let text = "{\"results\":[1,null,\"x\",[],{},{\"name\":\"A\"},{\"name\":\"A\",\"latitude\":1},"
            + "{\"name\":\"A\",\"latitude\":\"1\",\"longitude\":2},{\"latitude\":1,\"longitude\":2},"
            + "{\"name\":5,\"latitude\":1,\"longitude\":2},{\"name\":\"Ok1\",\"latitude\":1,\"longitude\":2},"
            + "{\"name\":\"Ok2\",\"latitude\":-90,\"longitude\":180},"
            + "{\"name\":\"BadLat\",\"latitude\":90.0001,\"longitude\":0},{\"name\":\"BadLon\",\"latitude\":0,\"longitude\":-180.1},"
            + "{\"name\":\"Inf\",\"latitude\":1e999,\"longitude\":0},{\"name\":\"Ok3\",\"latitude\":90,\"longitude\":-180}]}"
        guard let places = Self.ok(Self.geocode(text)) else { return }
        #expect(places.map(\.name) == ["Ok1", "Ok2", "Ok3"])  // :1422-1424
        if let ok1 = places.first {
            #expect(ok1.admin1 == "" && ok1.country == "" && ok1.countryCode == "" && ok1.timezone == "")
        }
    }

    // C: /openmeteo/parse/geocode-sanitising (test-openmeteo.c:1433-1502)
    @Test func parseGeocodeSanitising() {
        // "\\u0000" is refused by the JSON parser: the whole body (:1439-1444)
        Self.fails(Self.geocode(
            "{\"results\":["
                + "{\"name\":\"Mi\\u0001a\\u202emi\\n\",\"latitude\":1,\"longitude\":2,\"admin1\":\"Fl\\u0007or\\u2066ida\","
                + "\"country\":\"United\\u0000\\u202aS\"},"
                + "{\"name\":\"x\"}]}"), .parse)
        let text = "{\"results\":["
            + "{\"name\":\"Mi\\u0001a\\u202emi\\n\",\"latitude\":1,\"longitude\":2,\"admin1\":\"Fl\\u0007or\\u2066ida\","
            + "\"country\":\"Un\\u200eited\\u2029 States\",\"country_code\":\"US\",\"timezone\":\"America/New_York\"},"
            + "{\"name\":\"\\u0001\\u202e\",\"latitude\":1,\"longitude\":2},"
            + "{\"name\":\"   \",\"latitude\":1,\"longitude\":2},"
            + "{\"name\":\"\",\"latitude\":1,\"longitude\":2},"
            + "{\"name\":\"CC lower\",\"latitude\":1,\"longitude\":2,\"country_code\":\"us\"},"
            + "{\"name\":\"CC three\",\"latitude\":1,\"longitude\":2,\"country_code\":\"USA\"},"
            + "{\"name\":\"CC digits\",\"latitude\":1,\"longitude\":2,\"country_code\":\"1A\"},"
            + "{\"name\":\"CC type\",\"latitude\":1,\"longitude\":2,\"country_code\":5},"
            + "{\"name\":\"CC ok\",\"latitude\":1,\"longitude\":2,\"country_code\":\"ZZ\"},"
            + "{\"name\":\"TZ abs\",\"latitude\":1,\"longitude\":2,\"timezone\":\"/etc/passwd\"},"
            + "{\"name\":\"TZ dots\",\"latitude\":1,\"longitude\":2,\"timezone\":\"a/../b\"},"
            + "{\"name\":\"TZ space\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Europe/New York\"},"
            + "{\"name\":\"TZ long\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Europe/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"},"
            + "{\"name\":\"TZ type\",\"latitude\":1,\"longitude\":2,\"timezone\":7},"
            + "{\"name\":\"TZ utc\",\"latitude\":1,\"longitude\":2,\"timezone\":\"UTC\"},"
            + "{\"name\":\"TZ plus\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Etc/GMT+5\"}"
            + "]}"
        guard let places = Self.ok(Self.geocode(text)) else { return }
        let expect: [(String, String, String, String, String)] = [
            ("Miami", "Florida", "United States", "US", "America/New_York"),
            ("CC lower", "", "", "", ""),
            ("CC three", "", "", "", ""),
            ("CC digits", "", "", "", ""),
            ("CC type", "", "", "", ""),
            ("CC ok", "", "", "ZZ", ""),
            ("TZ abs", "", "", "", ""),
            ("TZ dots", "", "", "", ""),
            ("TZ space", "", "", "", ""),
            ("TZ long", "", "", "", ""),
            ("TZ type", "", "", "", ""),
            ("TZ utc", "", "", "", "UTC"),
            ("TZ plus", "", "", "", "Etc/GMT+5"),
        ]
        #expect(places.count == expect.count)  // :1486
        for (p, e) in zip(places, expect) {
            Self.expectPlaceTexts(p, e.0, e.1, e.2, e.0)
            #expect(Self.sameBytes(p.countryCode, e.3), "\(e.0) code '\(p.countryCode)'")
            #expect(Self.sameBytes(p.timezone, e.4), "\(e.0) timezone '\(p.timezone)'")
        }
    }

    // C: /openmeteo/parse/geocode-optional-text-cleared (test-openmeteo.c:1504-1527)
    @Test func parseGeocodeOptionalTextCleared() {
        let text = "{\"results\":["
            + "{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"admin1\":\" \"},"
            + "{\"name\":\"B\",\"latitude\":1,\"longitude\":2,\"country\":\"\\u3000\"},"
            + "{\"name\":\"C\",\"latitude\":1,\"longitude\":2,\"admin1\":\"\\u00a0\",\"country\":\"\\u3000\"},"
            + "{\"name\":\"D\",\"latitude\":1,\"longitude\":2,\"admin1\":\"\\u0001\",\"country\":\" X \"}"
            + "]}"
        guard let places = Self.ok(Self.geocode(text)) else { return }
        #expect(places.count == 4)
        let names = ["A", "B", "C", "D"]
        let countries = ["", "", "", " X "]
        for (i, p) in places.enumerated() where i < 4 {
            Self.expectPlaceTexts(p, names[i], "", countries[i])
        }
    }

    // C: /openmeteo/parse/geocode-limits (test-openmeteo.c:1529-1579)
    @Test func parseGeocodeLimits() {
        let hits = (0..<45).map { "{\"name\":\"P\($0)\",\"latitude\":\($0 % 80),\"longitude\":\($0)}" }
        if let places = Self.ok(Self.geocode("{\"results\":[" + hits.joined(separator: ",") + "]}")) {
            #expect(places.count == 20)  // WX_GEOCODER_MAX_HITS (:1540-1541)
            #expect(OpenMeteoShared.geocoderMaxHits == 20)
            #expect(places.first?.name == "P0")
            #expect(places.last?.name == "P19")
        }
        var s = "{\"results\":[" + (0..<30).map { "{\"name\":\"B\($0)\",\"latitude\":999,\"longitude\":0}" }.joined(separator: ",")
        s += (0..<25).map { ",{\"name\":\"G\($0)\",\"latitude\":1,\"longitude\":1}" }.joined() + "]}"
        if let mixed = Self.ok(Self.geocode(s)) {
            #expect(mixed.count == 20)  // :1554
            #expect(mixed.first?.name == "G0")
        }
        // Over-long names are cut to WX_PLACE_NAME_MAX bytes on a character boundary (:1557-1571)
        let longname = String(repeating: "a", count: 300)
        let wide = String(repeating: "\u{E9}", count: 200)  // "\xc3\xa9" x 200: 400 bytes
        let text = "{\"results\":[{\"name\":\"" + longname + "\",\"latitude\":1,\"longitude\":2,\"admin1\":\"" + wide + "\"}]}"
        if let cut = Self.ok(Self.geocode(text)) {
            #expect(cut.count == 1)
            #expect(cut.first?.name.utf8.count == 256)
            #expect(cut.first?.admin1.utf8.count == 256)
        }
        // Exactly the byte limit passes unchanged (:1572-1577)
        let at = String(repeating: "b", count: 256)
        if let exact = Self.ok(Self.geocode("{\"results\":[{\"name\":\"" + at + "\",\"latitude\":1,\"longitude\":2}]}")) {
            #expect(exact.first.map { Self.sameBytes($0.name, at) } == true)
        }
    }

    // C: /openmeteo/parse/geocode-hostile (test-openmeteo.c:1581-1616)
    @Test func parseGeocodeHostile() {
        let bad: [[UInt8]] = [
            Self.b("{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"name\":\"B\"}]}"),
            Self.b("{\"results\":[{\"name\":\"") + [0xFF] + Self.b("\",\"latitude\":1,\"longitude\":2}]}"),
            Self.b("{\"results\":[{\"name\":\"\\ud800\",\"latitude\":1,\"longitude\":2}]}"),
            Self.b("{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2},]}"),
            [0xEF, 0xBB, 0xBF] + Self.b("{}"),
        ]
        for (i, body) in bad.enumerated() {
            Self.fails(Self.geocode(bytes: body), .parse, nil, "bad[\(i)]")
        }
        let deep = "{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"x\":" + String(repeating: "[", count: 40)
            + String(repeating: "]", count: 40) + "}]}"
        Self.fails(Self.geocode(deep), .parse)
        // Format-string and markup text is data (:1609-1614)
        if let fmt = Self.ok(Self.geocode(
            "{\"results\":[{\"name\":\"%s%n<b>&amp;\",\"latitude\":1,\"longitude\":2,\"country\":\"%d\"}]}"))
        {
            #expect(fmt.first?.name == "%s%n<b>&amp;")
            #expect(fmt.first?.country == "%d")
        }
    }

    // C: /openmeteo/parse/geocode-forbidden-sweep (test-openmeteo.c:3778-3805)
    @Test func parseGeocodeForbiddenSweep() {
        var c: UInt32 = 1
        while c <= 0x10FFFF {
            let first = c
            var chars = "N"
            var kept = "N"
            var i = 0
            while i < 40 && c <= 0x10FFFF {
                defer { c += 1 }
                if c >= 0xD800 && c <= 0xDFFF {
                    continue
                }
                let u = Unicode.Scalar(c)!
                chars.unicodeScalars.append(u)
                if !Self.oracleForbidden(c) {
                    kept.unicodeScalars.append(u)
                }
                i += 1
            }
            var body = Self.b("{\"results\":[")
            Self.appendHit(&body, chars, chars, chars, nil, nil)
            let places = Self.parseHits(body)
            if places.count != 1 {
                Issue.record("batch from U+\(String(first, radix: 16)): \(places.count) hits")
                return
            }
            let p = places[0]
            if !Self.sameBytes(p.name, kept) || !Self.sameBytes(p.admin1, kept) || !Self.sameBytes(p.country, kept) {
                Issue.record("batch from U+\(String(first, radix: 16)): texts differ from the header's forbidden list")
                return
            }
        }
    }

    // C: /openmeteo/parse/geocode-whitespace-rules (test-openmeteo.c:3808-3872)
    @Test func parseGeocodeWhitespaceRules() {
        var spaces = 0
        for c in UInt32(1)...0x10FFFF where Self.oracleSpace(c) {
            spaces += 1
            let u = Self.scalarString(c)
            let two = u + u
            let mixed = u + "\u{01}" + u + "\u{2028}"  // white space and forbidden only
            var body = Self.b("{\"results\":[")
            Self.appendHit(&body, u, nil, nil, nil, nil)
            Self.appendHit(&body, mixed, nil, nil, nil, nil)
            Self.appendHit(&body, "A", two, u, nil, nil)
            let places = Self.parseHits(body)
            #expect(places.count == 1, "space U+\(String(c, radix: 16)): \(places.count) hits")
            if let p = places.first {
                Self.expectPlaceTexts(p, "A", "", "", "space U+\(String(c, radix: 16))")
            }
        }
        #expect(spaces == 17)  // :3833
        // Format characters only are visible and kept (:3834-3846)
        let cf = ["\u{200B}\u{200B}", "\u{FEFF}", "\u{2060}", "\u{AD}", "\u{180E}", "\u{E0001}"]
        for f in cf {
            var body = Self.b("{\"results\":[")
            Self.appendHit(&body, f, f, f, nil, nil)
            let places = Self.parseHits(body)
            #expect(places.count == 1)
            if let p = places.first {
                Self.expectPlaceTexts(p, f, f, f, "format \(f.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
        // White space around visible text is neither trimmed nor collapsed (:3847-3855)
        var body = Self.b("{\"results\":[")
        Self.appendHit(&body, " Miami ", "\u{3000}FL\u{A0}", "  United   States ", nil, nil)
        let kept = Self.parseHits(body)
        #expect(kept.count == 1)
        if let p = kept.first {
            Self.expectPlaceTexts(p, " Miami ", "\u{3000}FL\u{A0}", "  United   States ")
        }
        // Non-string members (:3856-3869)
        let typed = Self.ok(Self.geocode(
            "{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"admin1\":5,\"country\":true},"
                + "{\"name\":\"B\",\"latitude\":1,\"longitude\":2,\"admin1\":null,\"country\":[\"X\"]},"
                + "{\"name\":7,\"latitude\":1,\"longitude\":2,\"admin1\":\"X\"}]}")) ?? []
        #expect(typed.count == 2)
        for t in typed {
            #expect(t.admin1 == "" && t.country == "")
        }
    }

    // C: /openmeteo/parse/geocode-truncation (test-openmeteo.c:3876-3934)
    @Test func parseGeocodeTruncation() {
        let samples: [UInt32] = [0x62, 0xE9, 0x4E2D, 0x1F600]  // 'b', 1, 2, 3 and 4 bytes
        for w in 1...4 {
            var body = Self.b("{\"results\":[")
            var expect: [String] = []
            for n in 250...256 {
                for noise in 0..<2 {
                    var text = String(repeating: "a", count: n)
                    if noise == 1 {
                        text += "\u{01}\u{2028}\u{200E}\u{85}\u{7F}"  // "\x01\xe2\x80\xa8\xe2\x80\x8e\xc2\x85\x7f"
                    }
                    text += Self.scalarString(samples[w - 1])
                    text += "zzzzzzzzzz"
                    var want = String(repeating: "a", count: n)
                    if n + w <= 256 {
                        want += Self.scalarString(samples[w - 1])
                        var i = 0
                        while i < 10 && want.utf8.count < 256 {
                            want += "z"
                            i += 1
                        }
                    }
                    Self.appendHit(&body, text, text, text, nil, nil)
                    expect.append(want)
                }
            }
            let places = Self.parseHits(body)
            #expect(places.count == expect.count)
            for (p, want) in zip(places, expect) {
                #expect(want.utf8.count <= 256)
                Self.expectPlaceTexts(p, want, want, want, "width \(w)")
            }
        }
        // Cut to white space only (:3919-3933)
        let blank = String(repeating: " ", count: 300)
        let blankThenText = String(repeating: " ", count: 256) + "X"  // "%.256s" "X"
        let wideBlank = String(repeating: " ", count: 257)
        var body = Self.b("{\"results\":[")
        Self.appendHit(&body, blank, nil, nil, nil, nil)
        Self.appendHit(&body, wideBlank, nil, nil, nil, nil)
        Self.appendHit(&body, "A", blankThenText, blank, nil, nil)
        let places = Self.parseHits(body)
        #expect(places.count == 1)
        if let p = places.first {
            Self.expectPlaceTexts(p, "A", "", "")
        }
    }

    // C: /openmeteo/parse/geocode-country-code-rule (test-openmeteo.c:3937-3994)
    @Test func parseGeocodeCountryCodeRule() {
        var codes: [String] = []
        for a in UInt32(1)..<0x80 {
            for c in UInt32(1)..<0x80 {
                codes.append(Self.scalarString(a) + Self.scalarString(c))
            }
        }
        for a in UInt32(1)..<0x80 {
            codes.append(Self.scalarString(a))
            codes.append("US" + Self.scalarString(a))
            codes.append(Self.scalarString(a) + "US")
        }
        for c in UInt32(0x80)...0x7FF {
            codes.append(Self.scalarString(c))
        }
        codes += ["", "\u{FF35}\u{FF33}", "U\u{301}", "US\u{200B}", " US", "US ", "uS", "Us", "\u{C0}B", "ABC", "A",
                  "\u{C9}\u{C9}", "U\u{DC}"]  // :3956-3957
        var kept = 0
        var start = 0
        while start < codes.count {
            let end = Swift.min(start + 20, codes.count)
            var body = Self.b("{\"results\":[")
            for i in start..<end {
                Self.appendHit(&body, "N", nil, nil, codes[i], nil)
            }
            let places = Self.parseHits(body)
            #expect(places.count == end - start)
            if places.count == end - start {
                for i in start..<end {
                    let code = Array(codes[i].utf8)
                    let good = code.count == 2 && code[0] >= 0x41 && code[0] <= 0x5A && code[1] >= 0x41 && code[1] <= 0x5A
                    let got = places[i - start].countryCode
                    if !Self.sameBytes(got, good ? codes[i] : "") {
                        Issue.record("country_code bytes \(code): got '\(got)'")
                    }
                    kept += good ? 1 : 0
                }
            }
            start = end
        }
        #expect(kept == 26 * 26)  // :3980
        for typed in ["5", "null", "true", "[]", "{}", "[\"US\"]", "1.5"] {
            let text = "{\"results\":[{\"name\":\"N\",\"latitude\":1,\"longitude\":2,\"country_code\":" + typed + "}]}"
            let places = Self.ok(Self.geocode(text), typed)
            #expect(places?.count == 1)
            #expect(places?.first?.countryCode == "", "\(typed)")
        }
    }

    // C: /openmeteo/parse/geocode-timezone-rule (test-openmeteo.c:3997-4055)
    @Test func parseGeocodeTimezoneRule() {
        let pinned: [(String, String)] = [
            ("", ""), ("UTC", "UTC"), ("America/New_York", "America/New_York"), ("Etc/GMT+5", "Etc/GMT+5"),
            ("America/Argentina/Buenos_Aires", "America/Argentina/Buenos_Aires"), ("/etc/passwd", ""),
            ("a/../b", ""), ("../x", ""), ("./x", ""), ("-", ""), ("Europe/New York", ""), ("a//b", ""), ("a/", ""),
            ("/a", ""), ("1/a", ""), ("a/1", ""), ("a/-b", ""), ("a/_b", ""), ("a/.b", ""), ("Europe/Z\u{FC}rich", ""),
            ("a/b\\c", ""), ("a/b%2fc", ""), ("a/b\nc", ""), ("a/b\u{7F}", ""),
        ]
        var tzs = pinned.map(\.0)
        var want = pinned.map(\.1)
        // WX_PLACE_TIMEZONE_MAX (64) characters pass, one more does not (:4015-4019)
        for len in 60...70 {
            let tz = "A/" + String(repeating: "x", count: len - 2)
            tzs.append(tz)
            want.append(len <= 64 ? tz : "")
        }
        // every ASCII character next to a valid zone (:4021-4029)
        for c in UInt32(1)..<0x80 {
            let ch = Self.scalarString(c)
            let isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            let nameChar = isAlpha || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
            tzs.append("Area/Loc" + ch)
            want.append(nameChar ? "Area/Loc" + ch : "")
            tzs.append(ch + "Area/Loc")
            want.append(isAlpha ? ch + "Area/Loc" : "")
        }
        var start = 0
        while start < tzs.count {
            let end = Swift.min(start + 20, tzs.count)
            var body = Self.b("{\"results\":[")
            for i in start..<end {
                Self.appendHit(&body, "N", nil, nil, nil, tzs[i])
            }
            let places = Self.parseHits(body)
            #expect(places.count == end - start)
            if places.count == end - start {
                for i in start..<end {
                    let p = places[i - start]
                    // the header's sentence: kept iff wx_place_new() accepts it
                    let probe = try? WxPlace(name: "N", admin1: "", country: "", countryCode: "", lat: 1, lon: 2, timezone: tzs[i])
                    let byPlaceNew = probe != nil ? tzs[i] : ""
                    #expect(Self.sameBytes(p.timezone, byPlaceNew), "timezone \(Array(tzs[i].utf8)): kept '\(p.timezone)'")
                    #expect(Self.sameBytes(p.timezone, want[i]), "timezone \(Array(tzs[i].utf8)): kept '\(p.timezone)', expected '\(want[i])'")
                    #expect(p.lat == 1.0)
                }
            }
            start = end
        }
    }

    // C: /openmeteo/parse/error-reason-length (test-openmeteo.c:4059-4095)
    @Test func parseErrorReasonLength() {
        let samples: [UInt32] = [0x78, 0xE9, 0x4E2D, 0x1F600]  // 'x', 1, 2, 3 and 4 bytes
        let prefix = "Open-Meteo reported an error: "
        for w in 1...4 {
            for count in 118...122 {
                for noise in 0..<2 {
                    var reason = ""
                    var want = prefix
                    for i in 0..<count {
                        if noise == 1 {
                            reason += "\u{01}\u{2028}\u{200E}\u{85}"  // "\x01\xe2\x80\xa8\xe2\x80\x8e\xc2\x85"
                        }
                        reason += Self.scalarString(samples[w - 1])
                        if i < 120 {
                            want += Self.scalarString(samples[w - 1])
                        }
                    }
                    var body = Self.b("{\"error\":true,\"reason\":\"")
                    Self.jsonEscape(&body, reason)
                    body += Self.b("\"}")
                    let what = "width \(w) count \(count) noise \(noise)"
                    Self.fails(Self.forecast(bytes: body, Self.miamiModels), .http, want, what)
                    Self.fails(Self.nowcast(bytes: body), .http, want, what)
                    Self.fails(Self.geocode(bytes: body), .http, want, what)
                }
            }
        }
    }
}
