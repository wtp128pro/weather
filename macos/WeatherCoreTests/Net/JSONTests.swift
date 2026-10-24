// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// JSONTests.swift - port of the /http/json/ group of src/net/test-http.c
// (test functions at test-http.c:116-1230, registrations at :5107-5120).
// Every input is the C literal with the same bytes: C escapes that Swift
// spells the same way (\\ \" \n \t \r \0) are kept verbatim, so a JSON
// "\\u0041" in C is the six characters backslash-u-0-0-4-1 here too; C
// \xNN bytes of valid UTF-8 are written as the equivalent \u{...} scalar, and
// invalid UTF-8 is written as byte arrays.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct JSONTests {
    // MARK: - Helpers (test-http.c:83-114)

    /// WX_HTTP_MAX_BODY_BYTES (4 MiB, the HTTP body cap).
    private static let bodyCap = 4 * 1024 * 1024

    private static func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// parse_ok (test-http.c:85-93): max_len 1 MiB.
    private static func parseOK(
        _ text: [UInt8], _ root: WxJSON.Root, sourceLocation: SourceLocation = #_sourceLocation
    ) -> WxJSON.Node? {
        do {
            return try WxJSON.parse(text, maxLength: 1024 * 1024, root: root)
        } catch {
            Issue.record("rejected (\(error.message)): \(String(decoding: text.prefix(120), as: UTF8.self))",
                         sourceLocation: sourceLocation)
            return nil
        }
    }

    private static func parseOKObject(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> WxJSON.Object? {
        parseOK(b(text), .object, sourceLocation: sourceLocation)?.object
    }

    /// assert_parse_error_len (test-http.c:95-102): fails with a .parse error.
    private static func expectParseError(
        _ data: [UInt8], maxLength: Int = 1024 * 1024, _ root: WxJSON.Root,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try WxJSON.parse(data, maxLength: maxLength, root: root)
            Issue.record("accepted: \(String(decoding: data.prefix(120), as: UTF8.self))", sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == .parse, "\(error.message)", sourceLocation: sourceLocation)
        }
    }

    private static func expectRejectedBoth(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectParseError(b(text), .object, sourceLocation: sourceLocation)
        expectParseError(b(text), .array, sourceLocation: sourceLocation)
    }

    /// The error thrown for `data`, or nil when it parses.
    private static func parseError(_ data: [UInt8], maxLength: Int, _ root: WxJSON.Root = .object) -> WxError? {
        do {
            _ = try WxJSON.parse(data, maxLength: maxLength, root: root)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - /http/json/accepts

    // C: /http/json/accepts (test-http.c:116-160)
    @Test("/http/json/accepts") func accepts() {
        let objects = [  // test-http.c:118-136
            "{}",
            " \t\r\n{ }\n\r\t ",
            "{\"a\":1}",
            "{\"a\":-0}",
            "{\"a\":1E+5}",
            "{\"a\":1.5e-3}",
            "{\"a\":0.5,\"b\":10,\"c\":-12.25e2}",
            "{\"a\":[]}",
            "{\"a\":{}}",
            "{\"a\":[[],{},[{}]]}",
            "{\"a\":\"\\u0041\\u00e9\\ud83d\\ude00\\n\\/\\\\\\\"\\b\\f\\r\\t\"}",
            "{\"a\":\"\\u0001\\u001f\\u007f\"}",
            "{\"a\":null,\"b\":true,\"c\":false}",
            "{\"a\":1,\"A\":2}",
            "{\"\u{E9}\":\"\u{FC}\"}",  // C "\xc3\xa9" / "\xc3\xbc"
            "{\"a\":\"\u{1F600}\"}",  // C "\xf0\x9f\x98\x80"
            "{\"a\" : 1 , \"b\" : [ 1 , 2 ] }",
        ]
        for text in objects {
            let node = Self.parseOK(Self.b(text), .object)
            #expect(node?.object != nil, "\(text)")
            Self.expectParseError(Self.b(text), .array)  // the root kind is enforced
        }
        let arrays = ["[]", "[1,2,3]", "[{}]", " [ ] ", "[[[]]]", "[\"a\",null]"]  // test-http.c:142
        for text in arrays {
            let node = Self.parseOK(Self.b(text), .array)
            #expect(node?.array != nil, "\(text)")
            Self.expectParseError(Self.b(text), .object)
        }

        // Decoded values (test-http.c:149-159).
        let obj = Self.parseOKObject("{\"s\":\"\\u0041\\u00e9\\ud83d\\ude00\\n\",\"n\":-12.25e2,\"i\":7}")
        #expect(obj?.string("s").map { Array($0.utf8) } == [0x41, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x0A])
        #expect(obj?.number("n") == -1225.0)
        #expect(obj?.number("i") == 7.0)
    }

    // MARK: - /http/json/rejects-grammar

    // C: /http/json/rejects-grammar (test-http.c:162-250)
    @Test("/http/json/rejects-grammar") func rejectsGrammar() {
        let bad = [  // test-http.c:164-245
            "",
            " ",
            "{",
            "}",
            "[",
            "]",
            "{}{}",
            "{} {}",
            "{}x",
            "{} x",
            "{}}",
            "[]]",
            "[1][2]",
            "{\"a\":1}{\"b\":2}",
            "{'a':1}",
            "{\"a\":'x'}",
            "{\"a\":1,}",
            "[1,]",
            "{,}",
            "[,1]",
            "[1,,2]",
            "{\"a\"}",
            "{\"a\":}",
            "{a:1}",
            "{1:1}",
            "{\"a\" 1}",
            "{\"a\":1 \"b\":2}",
            "[1 2]",
            "{\"a\":01}",
            "{\"a\":-01}",
            "{\"a\":+1}",
            "{\"a\":.5}",
            "{\"a\":1.}",
            "{\"a\":1e}",
            "{\"a\":1e+}",
            "{\"a\":0x10}",
            "{\"a\":--1}",
            "{\"a\":-}",
            "{\"a\":NaN}",
            "{\"a\":nan}",
            "{\"a\":Infinity}",
            "{\"a\":-Infinity}",
            "{\"a\":tru}",
            "{\"a\":True}",
            "{\"a\":nul}",
            "{\"a\":truefalse}",
            "{\"a\":\"\\x\"}",
            "{\"a\":\"\\u12\"}",
            "{\"a\":\"\\u12G4\"}",
            "{\"a\":\"\\u\"}",
            "{\"a\":\"\\",
            "{\"a\":\"abc}",
            "{\"a\":\"tab\there\"}",
            "{\"a\":\"nl\nx\"}",
            "{\"a\":\"\u{01}\"}",  // C "\x01"
            "// c\n{}",
            "/* c */{}",
            "#{}",
            "\u{FEFF}{}",  // C "\xEF\xBB\xBF{}"
            "\u{0B}{}",  // C "\x0b{}"
            "\u{0C}{}",  // C "\f{}"
            "{}\u{0B}",  // C "{}\x0b"
            "{\"a\":[1,2}",
            "{\"a\":{]}",
            "[}",
            "{\"a\":\"\\u0000\"}",
            "{\"a\":\"\\u0000x\"}",
            "{\"\\u0000\":1}",
            "{\"a\":\"\\uD800\"}",
            "{\"a\":\"\\uDC00\"}",
            "{\"a\":\"\\uD800\\u0041\"}",
            "{\"a\":\"\\uDC00\\uD800\"}",
            "{\"a\":\"\\uD800\\uD800\"}",
            "null",
            "true",
            "123",
            "\"s\"",
        ]
        #expect(Self.b("\u{FEFF}{}") == [0xEF, 0xBB, 0xBF, 0x7B, 0x7D])
        for text in bad {
            Self.expectRejectedBoth(text)
        }
        // Raw DEL and C1 controls inside a string are legal JSON text (test-http.c:247-249).
        let obj = Self.parseOKObject("{\"a\":\"\u{7F}\u{80}\"}")  // C "\x7f\xc2\x80"
        #expect(obj?.string("a").map { Array($0.utf8) } == [0x7F, 0xC2, 0x80])
    }

    // MARK: - /http/json/duplicate-names

    // C: /http/json/duplicate-names (test-http.c:259-311)
    @Test("/http/json/duplicate-names") func duplicateNames() {
        let duplicates = [  // test-http.c:263-281
            "{\"a\":1,\"a\":2}",
            "{\"a\":1,\"a\":1}",
            "{\"a\":1,\"b\":2,\"a\":3}",
            "{\"\":1,\"\":2}",
            "{\"a\":1,\"\\u0061\":2}",  // spelled differently, same name
            "{\"\\u0061\":1,\"a\":2}",
            "{\"\\u00e9\":1,\"\u{E9}\":2}",  // C "\xc3\xa9"
            "{\"\u{E9}\":1,\"\\u00E9\":2}",
            "{\"\\ud83d\\ude00\":1,\"\u{1F600}\":2}",  // C "\xf0\x9f\x98\x80"
            "{\"a\\/b\":1,\"a/b\":2}",
            "{\"a\\nb\":1,\"a\\u000ab\":2}",
            "{\"a\\\\b\":1,\"a\\u005cb\":2}",
            "{\"a\\\"\":1,\"a\\u0022\":2}",
            "{\"o\":{\"x\":1,\"x\":2}}",  // in a nested object
            "{\"o\":[{\"x\":1},{\"y\":1,\"y\":2}]}",
            "{\"o\":{\"x\":1},\"o\":{\"y\":2}}",  // repeated name with object values
            "{\"a\":{\"b\":1},\"c\":2,\"a\":3}",
        ]
        for text in duplicates {
            Self.expectRejectedBoth(text)
        }
        // In an array's object as well (test-http.c:284-287).
        Self.expectParseError(Self.b("[{\"a\":1,\"a\":2}]"), .array)
        Self.expectParseError(Self.b("[{\"a\":1},{\"b\":1,\"b\":2}]"), .array)
        Self.expectParseError(Self.b("[[{\"a\":1,\"a\":2}]]"), .array)

        // The same name in different objects, and names that merely look alike, are fine.
        let fine = [  // test-http.c:290-299
            "{\"a\":{\"a\":1},\"b\":{\"a\":2}}",
            "{\"a\":1,\"A\":2}",
            "{\"a\":1,\"a \":2,\" a\":3,\"aa\":4,\"\":5}",
            "{\"a\":1,\"b\":{\"a\":2,\"b\":{\"a\":3}}}",
            "{\"\\u00e9\":1,\"e\":2,\"\\u00e8\":3}",
            "{\"a\\nb\":1,\"a\\\\nb\":2}",
            "{\"a\":[{\"x\":1},{\"x\":2},{\"x\":3}]}",
            "{\"x\":1,\"y\":{\"x\":1},\"z\":[{\"x\":1}]}",
        ]
        for text in fine {
            #expect(Self.parseOK(Self.b(text), .object) != nil, "\(text)")
        }
        #expect(Self.parseOK(Self.b("[{\"a\":1},{\"a\":2},{\"a\":3}]"), .array) != nil)
        // Names are scoped to an object: after one closes, its names are forgotten (test-http.c:306-309).
        #expect(Self.parseOK(Self.b("{\"a\":{\"k\":1},\"b\":{\"k\":2},\"c\":[{\"k\":3},{\"k\":4}]}"), .object) != nil)
    }

    // MARK: - /http/json/member-limit

    /// object_with_members (test-http.c:313-321).
    private static func objectWithMembers(_ n: Int, _ prefix: String) -> String {
        var s = "{"
        for i in 0..<n {
            s += "\(i > 0 ? "," : "")\"\(prefix)\(i)\":\(i)"
        }
        return s + "}"
    }

    // C: /http/json/member-limit (test-http.c:323-347)
    @Test("/http/json/member-limit") func memberLimit() {
        #expect(WxJSON.maxMembers == 1024)  // test-http.c:325
        let atLimit = Self.objectWithMembers(WxJSON.maxMembers, "k")
        let over = Self.objectWithMembers(WxJSON.maxMembers + 1, "k")
        #expect(Self.parseOKObject(atLimit)?.count == 1024)
        Self.expectParseError(Self.b(over), .object)

        // The limit is per object (test-http.c:332-335).
        let inner = Self.objectWithMembers(WxJSON.maxMembers - 1, "i")
        let nestedAtLimit = "{\"o1\":\(inner),\"o2\":\(inner),\"o3\":[\(inner),\(inner)]}"
        #expect(Self.parseOKObject(nestedAtLimit) != nil)
        // ... and an inner object over the limit is refused.
        Self.expectParseError(Self.b("{\"o\":\(over)}"), .object)
        // Arrays have no member limit (test-http.c:340-346).
        var big = "[0"
        for i in 1..<100_000 {
            big += ",\(i)"
        }
        big += "]"
        #expect(Self.parseOK(Self.b(big), .array)?.array?.count == 100_000)
    }

    // MARK: - /http/json/duplicate-flood-is-fast

    /// parse_ms (test-http.c:350-362): the parse time in ms, checking the outcome.
    private static func parseMS(
        _ text: [UInt8], expectOK: Bool, _ root: WxJSON.Root = .object,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Int64 {
        let clock = ContinuousClock()
        var error: WxError?
        let elapsed = clock.measure {
            error = parseError(text, maxLength: text.count, root)
        }
        #expect((error == nil) == expectOK, sourceLocation: sourceLocation)
        if !expectOK {
            #expect(error?.code == .parse, sourceLocation: sourceLocation)
        }
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    /// limit_ms (test-http.c:370-388): factor times the time of a 4 MiB valid
    /// array, plus one second.
    private static func limitMS(_ factor: Int64, baseline: Int64) -> Int64 {
        factor * baseline + 1000
    }

    private static func baselineMS() -> Int64 {
        var array = [UInt8]("[".utf8)
        array.reserveCapacity(bodyCap)
        while array.count + 3 < bodyCap {
            array += [0x30, 0x2C]  // "0,"
        }
        array += Array("0]".utf8)
        return parseMS(array, expectOK: true, .array)
    }

    // C: /http/json/duplicate-flood-is-fast (test-http.c:395-436)
    @Test("/http/json/duplicate-flood-is-fast") func duplicateFloodIsFast() {
        let cap = Self.bodyCap
        let baseline = Self.baselineMS()
        // (a) one name repeated for the whole body.
        var flood = Self.b("{\"k\":0")
        let rep = Self.b(",\"k\":0")
        while flood.count + 7 < cap {
            flood += rep
        }
        flood.append(0x7D)
        #expect(flood.count > cap - 16)
        #expect(Self.parseMS(flood, expectOK: false) < Self.limitMS(20, baseline: baseline))

        // (b) many distinct names, then repeats of the last.
        var mixed = "{\"k0\":0"
        for i in 1..<WxJSON.maxMembers {
            mixed += ",\"k\(i)\":0"
        }
        var mixedBytes = Self.b(mixed)
        let last = Self.b(",\"k1023\":0")
        while mixedBytes.count + 12 < cap {
            mixedBytes += last
        }
        mixedBytes.append(0x7D)
        #expect(Self.parseMS(mixedBytes, expectOK: false) < Self.limitMS(20, baseline: baseline))

        // (c) one distinct member beyond the limit followed by 4 MiB of members: stops at the limit.
        var many = Self.b("{\"k0\":0")
        var i = 1
        while many.count + 16 < cap {
            many += Self.b(",\"k\(i)\":0")
            i += 1
        }
        many.append(0x7D)
        #expect(Self.parseMS(many, expectOK: false) < Self.limitMS(20, baseline: baseline))

        // (d) a large, valid document: 100000 small objects in an array.
        var objects = "{\"a\":["
        for k in 0..<100_000 {
            objects += "\(k > 0 ? "," : ""){\"x\":\(k),\"y\":[1,2,3]}"
        }
        objects += "]}"
        #expect(Self.parseMS(Self.b(objects), expectOK: true) < Self.limitMS(100, baseline: baseline))
    }

    // MARK: - /http/json/hash-collisions (behavioural part)

    /// colliding_object (test-http.c:440-455): names built from "Ez"/"FY" blocks.
    private static func collidingObject(_ members: Int) -> String {
        var bits = 1
        while (1 << bits) < members {
            bits += 1
        }
        var s = "{"
        for i in 0..<members {
            s += i > 0 ? ",\"" : "\""
            for bit in 0..<bits {
                s += (i >> bit) & 1 == 1 ? "FY" : "Ez"
            }
            s += "\":0"
        }
        return s + "}"
    }

    // C: /http/json/hash-collisions (test-http.c:457-485). The premise
    // g_str_hash("Ez") == g_str_hash("FY") is GLIB-INTERNAL (Swift's Hasher is
    // seeded per process); the member bound and the time bounds are ported.
    @Test("/http/json/hash-collisions") func hashCollisions() {
        let baseline = Self.baselineMS()
        let atLimit = Self.b(Self.collidingObject(WxJSON.maxMembers))
        let over = Self.b(Self.collidingObject(WxJSON.maxMembers + 1))
        #expect(Self.parseMS(atLimit, expectOK: true) < Self.limitMS(20, baseline: baseline))
        #expect(Self.parseMS(over, expectOK: false) < Self.limitMS(20, baseline: baseline))
        #expect(Self.parseOK(atLimit, .object)?.object?.count == WxJSON.maxMembers)

        var array: [UInt8] = [0x5B]
        var n = 0
        while array.count + atLimit.count + 2 < Self.bodyCap {
            if n > 0 {
                array.append(0x2C)
            }
            array += atLimit
            n += 1
        }
        array.append(0x5D)
        let clock = ContinuousClock()
        var count: Int?
        let elapsed = clock.measure {
            count = (try? WxJSON.parse(array, maxLength: array.count, root: .array))?.array?.count
        }
        #expect((count ?? 0) > 150)
        #expect(elapsed.components.seconds * 1000 < Self.limitMS(500, baseline: baseline))
    }

    // MARK: - /http/json/rejects-encoding-size

    // C: /http/json/rejects-encoding-size (test-http.c:487-544)
    @Test("/http/json/rejects-encoding-size") func rejectsEncodingAndSize() {
        // Empty (test-http.c:491-499).
        #expect(Self.parseError([], maxLength: 10)?.code == .parse)
        #expect(Self.parseError(Array(Self.b("{}").prefix(0)), maxLength: 10)?.code == .parse)
        #expect(Self.parseError([], maxLength: 10)?.message == "empty response")  // wx-json.c:475

        // Size: len == max_len is accepted, one more is not (test-http.c:501-509).
        #expect(Self.parseError(Self.b("{}"), maxLength: 2) == nil)
        Self.expectParseError(Self.b("{}"), maxLength: 1, .object)
        Self.expectParseError([0xFF, 0xFF, 0xFF], maxLength: 2, .object)  // size before UTF-8
        #expect(Self.parseError([0xFF, 0xFF, 0xFF], maxLength: 2)?.message.contains("too large") == true)
        #expect(Self.parseError(Self.b("{}"), maxLength: 1)?.message.contains("too large") == true)

        // Invalid UTF-8 (test-http.c:511-531).
        let pre = Self.b("{\"a\":\"")
        let post = Self.b("\"}")
        let badUTF8: [[UInt8]] = [
            pre + [0xFF] + post,
            pre + [0xC0, 0xAF] + post,
            pre + [0xE2, 0x82] + post,
            pre + [0xED, 0xA0, 0x80] + post,
            pre + [0xF4, 0x90, 0x80, 0x80] + post,
            pre + [0x80] + post,
            Self.b("{\"a\":\"a\0b\"}"),
            Self.b("{}\0"),
            Self.b("\0{}"),
        ]
        // The C test passes these lengths, so the first seven bodies stop
        // before their closing brace (the UTF-8 check comes first anyway).
        let lengths = [8, 9, 9, 10, 11, 8, 10, 3, 3]
        for (literal, len) in zip(badUTF8, lengths) {
            #expect(literal.count >= len)
            let data = Array(literal.prefix(len))
            let error = Self.parseError(data, maxLength: 1024)
            #expect(error?.code == .parse)
            #expect(error?.message == "response is not valid UTF-8")  // wx-json.c:484
        }

        // Error messages never echo the body (test-http.c:533-543).
        for text in ["{\"SECRET-TEXT\":}", "[\"SECRET-TEXT\"]", "\"SECRET-TEXT\""] {
            let error = Self.parseError(Self.b(text), maxLength: 1024)
            #expect(error?.code == .parse)
            #expect(error.map { !$0.message.contains("SECRET") } == true)
        }
        // The fixed messages (wx-json.c:488, :501-502).
        #expect(Self.parseError(Self.b("{\"SECRET-TEXT\":}"), maxLength: 1024)?.message == "malformed JSON")
        #expect(Self.parseError(Self.b("[\"SECRET-TEXT\"]"), maxLength: 1024)?.message == "response is not a JSON object")
        #expect(Self.parseError(Self.b("{}"), maxLength: 1024, .array)?.message == "response is not a JSON array")
    }

    // MARK: - /http/json/depth

    /// nested (test-http.c:561-572): exactly `depth` nested containers.
    private static func nested(_ objects: Bool, _ depth: Int) -> [UInt8] {
        var s = ""
        for _ in 0..<(depth - 1) {
            s += objects ? "{\"a\":" : "["
        }
        s += objects ? "{}" : "[]"
        for _ in 0..<(depth - 1) {
            s += objects ? "}" : "]"
        }
        return b(s)
    }

    // C: /http/json/depth (test-http.c:574-607)
    @Test("/http/json/depth") func depth() {
        #expect(WxJSON.maxDepth == 32)  // test-http.c:576
        // The root container is level 1: 32 levels are accepted, 33 are not.
        for objects in [false, true] {
            let root: WxJSON.Root = objects ? .object : .array
            #expect(Self.parseOK(Self.nested(objects, 1), root) != nil)
            #expect(Self.parseOK(Self.nested(objects, WxJSON.maxDepth), root) != nil)
            Self.expectParseError(Self.nested(objects, WxJSON.maxDepth + 1), root)
        }
        // Hostile nesting (test-http.c:588-606).
        let big = 200_000
        let opens = [UInt8](repeating: 0x5B, count: big)
        Self.expectParseError(opens, maxLength: 1024 * 1024, .array)
        Self.expectParseError(opens, maxLength: 1024 * 1024, .object)
        let many = [UInt8](repeating: 0x7B, count: Self.bodyCap)
        Self.expectParseError(many, maxLength: Self.bodyCap, .object)
        let mixed = (0..<big).map { $0 % 2 == 1 ? UInt8(0x5B) : UInt8(0x7B) }
        Self.expectParseError(mixed, maxLength: big, .object)
        var quoted: [UInt8] = []
        quoted.reserveCapacity(big * 5)
        let piece = Self.b("{\"a\":")
        for _ in 0..<big {
            quoted += piece
        }
        Self.expectParseError(quoted, maxLength: big * 5, .object)
    }

    // MARK: - /http/json/accessors

    // C: /http/json/accessors (test-http.c:609-677). The NULL-argument
    // criticals (:669-676) are not representable: names and outputs are
    // non-optional in Swift.
    @Test("/http/json/accessors") func accessors() throws {
        let text: String = [
            "{\"o\":{\"x\":1},\"a\":[1,2],\"s\":\"text\",\"e\":\"\",\"n\":1.5,\"i\":-3,\"b\":true,\"z\":null,",
            "\"big\":12345678901234567890,\"nbig\":-12345678901234567890,\"max\":9223372036854775807,",
            "\"min\":-9223372036854775808,\"ok\":9223372036854775806,\"inf\":1e999,\"ninf\":-1e999,",
            "\"str\":\"12\"}",
        ].joined()
        let obj = try #require(Self.parseOKObject(text))

        // Types (test-http.c:619-637).
        #expect(obj.object("o") != nil)
        #expect(obj.object("a") == nil)
        #expect(obj.object("s") == nil)
        #expect(obj.object("z") == nil)
        #expect(obj.object("missing") == nil)
        #expect(obj.array("a") != nil)
        #expect(obj.array("a")?.count == 2)
        #expect(obj.array("o") == nil)
        #expect(obj.array("n") == nil)
        #expect(obj.array("z") == nil)
        #expect(obj.array("missing") == nil)
        #expect(obj.string("s") == "text")
        #expect(obj.string("e") == "")
        #expect(obj.string("n") == nil)
        #expect(obj.string("b") == nil)
        #expect(obj.string("o") == nil)
        #expect(obj.string("z") == nil)
        #expect(obj.string("missing") == nil)

        // NULL objects are tolerated (test-http.c:639-647).
        let none: WxJSON.Object? = nil
        let noNode: WxJSON.Node? = nil
        #expect(none?.object("o") == nil)
        #expect(none?.array("a") == nil)
        #expect(none?.string("s") == nil)
        #expect(none?.number("n") == nil)
        #expect(noNode?.number == nil)
        #expect(noNode?.numberInRange(0, 1) == nil)

        // Numbers (test-http.c:649-667).
        #expect(obj.number("n") == 1.5)
        #expect(obj.number("i") == -3.0)
        #expect(obj.number("ok") == 9223372036854775806.0)
        for name in ["s", "str", "b", "z", "o", "a", "missing", "e", "big", "nbig", "max", "min", "inf", "ninf"] {
            #expect(obj.number(name) == nil, "\(name)")
        }
        let node = obj.member("n")
        #expect(node?.number == 1.5)
        #expect(obj.member("s")?.number == nil)

        // The int/float lexical distinction and "true is not 1" (wx-json.h:155-159).
        #expect(obj.member("i") == .integer(-3))
        #expect(obj.member("n") == .double(1.5))
        #expect(obj.member("b") == .bool(true))
    }

    // MARK: - /http/json/number-in-range

    // C: /http/json/number-in-range (test-http.c:679-705)
    @Test("/http/json/number-in-range") func numberInRange() throws {
        let obj = try #require(Self.parseOKObject("{\"v\":5,\"f\":5.5,\"neg\":-40.0,\"inf\":1e999,\"s\":\"5\"}"))
        let v = try #require(obj.member("v"))
        let f = try #require(obj.member("f"))
        #expect(v.numberInRange(5.0, 5.0) == 5.0)  // both bounds inclusive
        #expect(f.numberInRange(0.0, 5.5) == 5.5)
        #expect(f.numberInRange(5.5, 100.0) != nil)
        #expect(v.numberInRange(5.1, 10.0) == nil)
        #expect(v.numberInRange(0.0, 4.9) == nil)
        #expect(v.numberInRange(10.0, 0.0) == nil)  // empty range
        #expect(v.numberInRange(.nan, 10.0) == nil)
        #expect(v.numberInRange(0.0, .nan) == nil)
        #expect(obj.member("inf")?.numberInRange(-.infinity, .infinity) == nil)
        #expect(obj.member("s")?.numberInRange(0.0, 10.0) == nil)
        #expect(obj.member("neg")?.numberInRange(WxLimits.tempMinC, WxLimits.tempMaxC) == -40.0)
    }

    // MARK: - /http/json/error-reason

    // C: /http/json/error-reason (test-http.c:707-778)
    @Test("/http/json/error-reason") func errorReason() throws {
        let text: String = [
            "{\"a\":{\"error\":true,\"reason\":\"Cannot initialize WeatherVariable\"},",
            "\"b\":{\"error\":true},",
            "\"c\":{\"error\":true,\"reason\":42},",
            "\"d\":{\"error\":false,\"reason\":\"no\"},",
            "\"e\":{\"error\":\"true\",\"reason\":\"no\"},",
            "\"f\":{\"reason\":\"no\"},",
            "\"g\":{\"error\":true,\"reason\":\"a\\u0001b\\u202ec\\u2066d\\u0085e\"},",
            "\"h\":{\"error\":true,\"reason\":\"\\u0007\\u202e\"},",
            "\"i\":{\"error\":true,\"reason\":\"\u{1F600}\u{1F600}\u{1F600}\"},",  // C "\xf0\x9f\x98\x80" x3
            "\"j\":{\"error\":1,\"reason\":\"no\"},",
            "\"k\":{\"error\":null,\"reason\":\"no\"},",
            "\"l\":{\"error\":true,\"reason\":\"%s%n %d\"}}",
        ].joined()
        let obj = try #require(Self.parseOKObject(text))
        #expect(obj.object("a")?.errorReason(maxChars: 80) == "Cannot initialize WeatherVariable")
        #expect(obj.object("a")?.errorReason(maxChars: 6) == "Cannot")  // cut to 6 characters
        #expect(obj.object("a")?.errorReason(maxChars: 1) == "C")
        #expect(obj.object("b")?.errorReason(maxChars: 80) == "")  // error without reason
        #expect(obj.object("c")?.errorReason(maxChars: 80) == "")  // reason of the wrong type
        for name in ["d", "e", "f", "j", "k"] {
            #expect(obj.object(name) != nil)
            #expect(obj.object(name)?.errorReason(maxChars: 80) == nil, "\(name)")
        }
        let none: WxJSON.Object? = nil
        #expect(none?.errorReason(maxChars: 80) == nil)
        // Controls and bidi overrides are removed, then the text is cut (test-http.c:744-753).
        #expect(obj.object("g")?.errorReason(maxChars: 80) == "abcde")
        #expect(obj.object("g")?.errorReason(maxChars: 3) == "abc")
        #expect(obj.object("h")?.errorReason(maxChars: 80) == "")
        // Cut on a character boundary (test-http.c:754-758).
        #expect(obj.object("i")?.errorReason(maxChars: 2).map { Array($0.utf8) }
            == [0xF0, 0x9F, 0x98, 0x80, 0xF0, 0x9F, 0x98, 0x80])
        // A format string stays data (test-http.c:759-762).
        #expect(obj.object("l")?.errorReason(maxChars: 80) == "%s%n %d")
        // The longest accepted limit works on a long reason (test-http.c:763-773).
        var long = "{\"error\":true,\"reason\":\""
        for _ in 0..<5000 {
            long += "\u{1F600}"
        }
        long += "\"}"
        let r = try #require(Self.parseOKObject(long)?.errorReason(maxChars: WxJSON.reasonCharsMax))
        #expect(r.unicodeScalars.count == WxJSON.reasonCharsMax)
        #expect(r.utf8.count == WxJSON.reasonCharsMax * 4)
        #expect(WxJSON.reasonCharsMax == 1024)  // wx-json.h:36
        // Out-of-range limits return NULL (test-http.c:775-777; C also logs a critical).
        #expect(obj.errorReason(maxChars: 0) == nil)
        #expect(obj.errorReason(maxChars: WxJSON.reasonCharsMax + 1) == nil)
    }

    // MARK: - /http/json/differential-fuzz

    /// Reference RFC 8259 validator (test-http.c:780-1012): recursive and
    /// structurally unlike the production scanner.
    private struct Reference {
        let t: [UInt8]
        var p = 0
        var dupRefused = 0

        static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func ws() {
            while p < t.count && (t[p] == 0x20 || t[p] == 0x09 || t[p] == 0x0D || t[p] == 0x0A) {
                p += 1
            }
        }

        func hex4(_ at: Int) -> Int {
            var v = 0
            for i in 0..<4 {
                let c = t[at + i]
                let digit: Int
                switch c {
                case 0x30...0x39: digit = Int(c) - 0x30
                case 0x61...0x66: digit = Int(c) - 0x61 + 10
                case 0x41...0x46: digit = Int(c) - 0x41 + 10
                default: return -1
                }
                v = v * 16 + digit
            }
            return v
        }

        mutating func string() -> Bool {
            if p >= t.count || t[p] != 0x22 {
                return false
            }
            p += 1
            while p < t.count {
                let c = t[p]
                p += 1
                if c == 0x22 {
                    return true
                }
                if c < 0x20 {
                    return false
                }
                if c != 0x5C {
                    continue
                }
                if p >= t.count {
                    return false
                }
                let e = t[p]
                p += 1
                if e == 0x75 {
                    if t.count - p < 4 {
                        return false
                    }
                    let v = hex4(p)
                    if v <= 0 {  // bad hex, or U+0000
                        return false
                    }
                    p += 4
                    if v >= 0xDC00 && v <= 0xDFFF {
                        return false  // lone low surrogate
                    }
                    if v >= 0xD800 && v <= 0xDBFF {
                        if t.count - p < 6 || t[p] != 0x5C || t[p + 1] != 0x75 {
                            return false
                        }
                        let lo = hex4(p + 2)
                        if lo < 0xDC00 || lo > 0xDFFF {
                            return false
                        }
                        p += 6
                    }
                } else if !Array("\"\\/bfnrt".utf8).contains(e) {
                    return false
                }
            }
            return false
        }

        mutating func number() -> Bool {
            var q = p
            if q < t.count && t[q] == 0x2D {
                q += 1
            }
            if q >= t.count {
                return false
            }
            if t[q] == 0x30 {
                q += 1
            } else if t[q] >= 0x31 && t[q] <= 0x39 {
                while q < t.count && Self.isDigit(t[q]) { q += 1 }
            } else {
                return false
            }
            if q < t.count && t[q] == 0x2E {
                q += 1
                if q >= t.count || !Self.isDigit(t[q]) {
                    return false
                }
                while q < t.count && Self.isDigit(t[q]) { q += 1 }
            }
            if q < t.count && (t[q] == 0x65 || t[q] == 0x45) {
                q += 1
                if q < t.count && (t[q] == 0x2B || t[q] == 0x2D) {
                    q += 1
                }
                if q >= t.count || !Self.isDigit(t[q]) {
                    return false
                }
                while q < t.count && Self.isDigit(t[q]) { q += 1 }
            }
            p = q
            return true
        }

        mutating func word(_ w: String) -> Bool {
            let wb = Array(w.utf8)
            if t.count - p < wb.count || Array(t[p..<(p + wb.count)]) != wb {
                return false
            }
            p += wb.count
            return true
        }

        /// ref_decode (test-http.c:917-947): a plain state machine.
        func decode(_ from: Int, _ end: Int) -> [UInt8] {
            var out: [UInt8] = []
            var q = from
            while q < end {
                if t[q] != 0x5C {
                    out.append(t[q])
                    q += 1
                    continue
                }
                let e = t[q + 1]
                q += 2
                if e == 0x75 {
                    var v = UInt32(hex4(q))
                    q += 4
                    if v >= 0xD800 && v <= 0xDBFF {
                        let lo = UInt32(hex4(q + 2))
                        q += 6
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    out += Array(String(Character(Unicode.Scalar(v)!)).utf8)
                } else {
                    switch e {
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    default: out.append(e)
                    }
                }
            }
            return out
        }

        mutating func container(_ depth: Int, _ open: UInt8, _ close: UInt8) -> Bool {
            if depth > WxJSON.maxDepth {
                return false
            }
            p += 1
            ws()
            if p < t.count && t[p] == close {
                p += 1
                return true
            }
            var names = Set<[UInt8]>()
            while true {
                ws()
                if open == 0x7B {
                    let start = p
                    if !string() {
                        return false
                    }
                    let name = decode(start + 1, p - 1)
                    if names.contains(name) || names.count >= WxJSON.maxMembers {
                        dupRefused += 1
                        return false
                    }
                    names.insert(name)
                    ws()
                    if p >= t.count || t[p] != 0x3A {
                        return false
                    }
                    p += 1
                    ws()
                }
                if !value(depth + 1) {
                    return false
                }
                ws()
                if p >= t.count {
                    return false
                }
                if t[p] == 0x2C {
                    p += 1
                    continue
                }
                if t[p] == close {
                    p += 1
                    return true
                }
                return false
            }
        }

        mutating func value(_ depth: Int) -> Bool {
            if p >= t.count {
                return false
            }
            switch t[p] {
            case 0x7B: return container(depth, 0x7B, 0x7D)
            case 0x5B: return container(depth, 0x5B, 0x5D)
            case 0x22: return string()
            case 0x74: return word("true")
            case 0x66: return word("false")
            case 0x6E: return word("null")
            default: return number()
            }
        }

        /// ref_root_kind (test-http.c:1000-1012): "{" or "[" for one valid container, else 0.
        mutating func rootKind() -> UInt8 {
            ws()
            if p >= t.count || (t[p] != 0x7B && t[p] != 0x5B) {
                return 0
            }
            let kind = t[p]
            if !value(1) {
                return 0
            }
            ws()
            return p == t.count ? kind : 0
        }
    }

    /// Strict UTF-8 validity as g_utf8_validate sees it (no 0x00 byte),
    /// computed with the standard library, independently of WxJSON.
    private static func isUTF8(_ bytes: [UInt8]) -> Bool {
        !bytes.contains(0) && String(validating: bytes, as: UTF8.self) != nil
    }

    private struct FuzzCounters {
        var accepted = 0
        var dupRefused = 0
    }

    /// differential (test-http.c:1036-1062).
    private static func differential(_ text: [UInt8], _ counters: inout FuzzCounters) {
        var kind: UInt8 = 0
        if isUTF8(text) {
            var r = Reference(t: text)
            kind = r.rootKind()
            counters.dupRefused += r.dupRefused
        }
        let asObject = text.isEmpty ? nil : try? WxJSON.parse(text, maxLength: text.count, root: .object)
        let asArray = text.isEmpty ? nil : try? WxJSON.parse(text, maxLength: text.count, root: .array)
        if kind != 0 {
            counters.accepted += 1
        }
        let shown = String(decoding: text.prefix(200), as: UTF8.self)
        if kind == 0x7B {
            #expect(asObject?.object != nil && asArray == nil, "\(shown)")
        } else if kind == 0x5B {
            #expect(asArray?.array != nil && asObject == nil, "\(shown)")
        } else {
            #expect(asObject == nil && asArray == nil, "production accepted what the reference rejects: \(shown)")
        }
    }

    /// gen_value (test-http.c:1065-1127).
    private static func genValue(_ rng: inout SeededRNG, _ out: inout [UInt8], _ depth: Int) {
        switch Int.random(in: 0..<(depth > 6 ? 6 : 8), using: &rng) {
        case 0:
            out += b("null")
        case 1:
            out += b(Bool.random(using: &rng) ? "true" : "false")
        case 2:
            let nums = ["0", "-0", "1", "-12", "3.25", "1e5", "-2.5E-3", "123456789012345678901",
                        "1e999", "0.000001", "10", "99.5"]
            out += b(nums[Int.random(in: 0..<nums.count, using: &rng)])
        case 3, 4, 5:
            let strs = ["\"\"", "\"abc\"", "\"\\u0041\"", "\"\\ud83d\\ude00\"", "\"\u{E9}\"",
                        "\"a\\nb\"", "\"\\\\\"", "\"\\/\"", "\"x y\"", "\"\\u00e9\\u20ac\""]
            out += b(strs[Int.random(in: 0..<strs.count, using: &rng)])
        default:
            let object = Bool.random(using: &rng)
            out.append(object ? 0x7B : 0x5B)
            let n = Int.random(in: 0..<4, using: &rng)
            for i in 0..<n {
                if i > 0 {
                    out += b(Bool.random(using: &rng) ? "," : " , ")
                }
                if object {
                    // Mostly unique names; sometimes a name from a small pool (repeats, other spellings).
                    let pool = ["\"a\"", "\"\\u0061\"", "\"b\"", "\"\\u00e9\"", "\"\u{E9}\"",
                                "\"\"", "\"a\\/b\"", "\"a/b\"", "\"\\ud83d\\ude00\""]
                    if Int.random(in: 0..<2, using: &rng) == 0 {
                        out += b(pool[Int.random(in: 0..<pool.count, using: &rng)])
                    } else {
                        out += b("\"k\(i)\"")
                    }
                    out.append(0x3A)
                }
                genValue(&rng, &out, depth + 1)
            }
            out.append(object ? 0x7D : 0x5D)
        }
    }

    // C: /http/json/differential-fuzz (test-http.c:1129-1195). SeededRNG
    // replaces GRand (DECISIONS #17): the oracle and the non-vacuity bounds
    // are the C test's, the random sequence is not.
    @Test("/http/json/differential-fuzz") func differentialFuzz() {
        var rng = SeededRNG(seed: 20_261_011)
        let tokens: [[UInt8]] = [
            "{", "}", "[", "]", ",", ":", "\"", "\\", "\"a\"", "\"\\u0041\"", "\"\\ud83d\\ude00\"", "\"\\ud83d\"",
            "\"\\u0000\"", "1", "-", "0", "01", "1.5", "1e5", "1e", ".", "+", "true", "false", "null", "nul", "NaN",
            " ", "\n", "\t", "\r", "\u{0B}", "\u{E9}",
        ].map { Self.b($0) } + [[0xFF], [0xEF, 0xBB, 0xBF]] + ["'", "/", "*", "#", "\\u", "e", "E", "x"].map { Self.b($0) }
        #expect(tokens.count == 43)  // test-http.c:1133-1136
        let iterations = fuzzIterations(150_000)
        var counters = FuzzCounters()

        // 1. Random token soup.
        for _ in 0..<iterations {
            var s: [UInt8] = []
            let n = Int.random(in: 1..<14, using: &rng)
            for _ in 0..<n {
                s += tokens[Int.random(in: 0..<tokens.count, using: &rng)]
            }
            Self.differential(s, &counters)
        }

        // 2. Grammar-generated documents, valid and then damaged at a random byte.
        for _ in 0..<iterations {
            let object = Bool.random(using: &rng)
            var s: [UInt8] = [object ? 0x7B : 0x5B]
            if object {
                s += Self.b("\"k\":")
            }
            Self.genValue(&rng, &s, 0)
            s.append(object ? 0x7D : 0x5D)
            Self.differential(s, &counters)
            for _ in 0..<3 where !s.isEmpty {
                let pos = Int.random(in: 0..<s.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: s[pos] = UInt8(Int.random(in: 1..<256, using: &rng))
                case 1: s.insert(tokens[Int.random(in: 0..<12, using: &rng)][0], at: pos)
                default: s.remove(at: pos)
                }
                Self.differential(s, &counters)
            }
        }

        // 3. Every prefix of a rich document, and every single-byte value.
        let rich = Self.b("{\"a\":[1,2.5e3,\"x\\u00e9\\ud83d\\ude00\",{\"b\":null,\"c\":[true,false]}],\"d\":{\"e\":\"\\n\"}}")
        for n in 0...rich.count {
            Self.differential(Array(rich.prefix(n)), &counters)
        }
        for byte in 0..<256 {
            Self.differential([UInt8(byte)], &counters)
            Self.differential(Self.b("{\"a\":\"") + [UInt8(byte)] + Self.b("\"}"), &counters)
        }
        // The property was exercised, not vacuous (test-http.c:1193-1194).
        #expect(counters.accepted > 10000)
        #expect(counters.dupRefused > 1000)
    }

    // MARK: - /http/json/guard-page (behavioural part)

    // C: /http/json/guard-page (test-http.c:1197-1228). The guard page itself
    // (a read past `len` faults) is GLIB-INTERNAL memory layout; Swift arrays
    // are bounds-checked. The accept/reject outcomes are ported.
    @Test("/http/json/guard-page") func guardPageOutcomes() {
        for byte in 0..<256 {
            #expect(Self.parseError([UInt8(byte)], maxLength: 1) != nil, "\(byte)")
        }
        let doc = Self.b("{\"a\":[1,2.5e3,\"x\\u00e9\\ud83d\\ude00\",{\"b\":null}],\"d\":\"\u{E9}\u{1F600}\"}")
        for n in 1...doc.count {
            let accepted = Self.parseError(Array(doc.prefix(n)), maxLength: doc.count) == nil
            #expect(accepted == (n == doc.count), "\(n)")
        }
        let cuts: [[UInt8]] = ["{\"a\":\"\\", "{\"a\":\"\\u00", "{\"a\":-", "{\"a\":1e", "{\"a\":tru"].map { Self.b($0) }
            + [Self.b("{\"a\":\"") + [0xF0, 0x9F]]
        for cut in cuts {
            #expect(Self.parseError(cut, maxLength: cut.count) != nil)
        }
    }

    // MARK: - Programmer errors

    // C: /http/json/programmer-errors (test-http.c:546-558) is GLIB-INTERNAL
    // (g_return_val_if_fail criticals). Its only representable case, max_len
    // 0, maps to a thrown .invalidArg instead of a critical.
    @Test("max_len outside 1...Int.max is refused (Swift form of /http/json/programmer-errors)")
    func invalidMaxLength() {
        #expect(Self.parseError(Self.b("{}"), maxLength: 0)?.code == .invalidArg)
    }
}
