// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoGeocoderTests.swift - the geocoder/ group of
// src/providers/openmeteo/test-openmeteo.c (registrations :4973-4985) against
// the loopback fake of OpenMeteoProviderFake.swift. The search-text oracle is
// the C test's (test-openmeteo.c:3554-3663), typed in from the header's own
// lists (wx-openmeteo.h:76-124); it does not call WxText. Inputs with
// non-ASCII or control bytes are written as [UInt8] so that no editing tool
// can decode an escape. GRand is replaced by SeededRNG (DECISIONS #16-#17).

import Foundation
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(10)))
struct OpenMeteoGeocoderTests {
    typealias Fake = OpenMeteoProviderFake

    // MARK: - Oracle (test-openmeteo.c:3554-3663)

    /// SEARCH_EMPTY / SEARCH_INVALID / SEARCH_REQUEST (test-openmeteo.c:3557).
    enum Kind: Int {
        case empty = 0, invalid = 1, request = 2
    }

    /// oracle_is_trim_byte (test-openmeteo.c:3563-3567).
    static func isTrimByte(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
    }

    /// oracle_forbidden (test-openmeteo.c:3570-3575).
    static func forbidden(_ c: UInt32) -> Bool {
        (c >= 0x01 && c <= 0x1F) || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || c == 0x061C
            || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)
    }

    /// oracle_space (test-openmeteo.c:3578-3583).
    static func space(_ c: UInt32) -> Bool {
        c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x205F
            || c == 0x3000
    }

    /// oracle_utf8_decode (test-openmeteo.c:3587-3624): the length of the character at `i`, 0 when
    /// the bytes are not valid UTF-8 (RFC 3629).
    static func decode(_ p: ArraySlice<UInt8>, _ i: Int, _ c: inout UInt32) -> Int {
        let b = p[i]
        if b < 0x80 {
            c = UInt32(b)
            return 1
        }
        let n: Int
        var v: UInt32
        let min: UInt32
        if b >= 0xC2 && b <= 0xDF {
            n = 2; v = UInt32(b & 0x1F); min = 0x80
        } else if b >= 0xE0 && b <= 0xEF {
            n = 3; v = UInt32(b & 0x0F); min = 0x800
        } else if b >= 0xF0 && b <= 0xF4 {
            n = 4; v = UInt32(b & 0x07); min = 0x10000
        } else {
            return 0
        }
        if p.endIndex - i < n {
            return 0
        }
        for k in 1..<n {
            let x = p[i + k]
            if x & 0xC0 != 0x80 {
                return 0
            }
            v = (v << 6) | UInt32(x & 0x3F)
        }
        if v < min || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
            return 0
        }
        c = v
        return n
    }

    /// oracle_search (test-openmeteo.c:3626-3663): the outcome and, for a request, the exact path.
    /// `text` is a C string: no 0x00 byte.
    static func oracle(_ text: [UInt8]) -> (Kind, String?) {
        var a = 0
        var b = text.count
        while a < b && isTrimByte(text[a]) { a += 1 }
        while b > a && isTrimByte(text[b - 1]) { b -= 1 }
        if b - a < 2 { return (.empty, nil) }
        if b - a > 64 { return (.invalid, nil) }
        let t = text[a..<b]
        var visible = false
        var i = a
        while i < b {
            var c: UInt32 = 0
            let n = decode(t, i, &c)
            if n == 0 || forbidden(c) { return (.invalid, nil) }
            if !space(c) { visible = true }
            i += n
        }
        if !visible { return (.invalid, nil) }
        var esc = ""
        for c in t {
            if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2D
                || c == 0x2E || c == 0x5F || c == 0x7E
            {
                esc.unicodeScalars.append(Unicode.Scalar(c))
            } else {
                esc += String(format: "%%%02X", c)
            }
        }
        return (.request, "/v1/search?name=\(esc)&count=10&language=en&format=json")
    }

    /// The UTF-8 bytes of a text (ASCII literals only in this file).
    static func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// g_unichar_to_utf8 of a Unicode scalar value (not a surrogate).
    static func utf8(_ c: UInt32) -> [UInt8] { Array(String(Unicode.Scalar(c)!).utf8) }

    /// describe_bytes (test-openmeteo.c:3665-3673).
    static func describe(_ text: [UInt8]) -> String {
        text.map { String(format: "%02X ", $0) }.joined()
    }

    static let unacceptable = WxError(.invalidArg, "unacceptable search text")

    // MARK: - Sweep driver (test-openmeteo.c:4138-4297)

    /// SWEEP_WINDOW searches at once, every outcome checked against the oracle (sweep_flush).
    struct Sweep {
        static let window = 8  // SWEEP_WINDOW (test-openmeteo.c:4142)
        let geo: OpenMeteoGeocoder
        let fake: Fake.Server
        var queued: [[UInt8]] = []
        var outcomes = [0, 0, 0]
        var failures = 0

        init(_ fake: Fake.Server, _ geo: OpenMeteoGeocoder) {
            self.fake = fake
            self.geo = geo
        }

        /// sweep_add (test-openmeteo.c:4247-4261).
        mutating func add(_ text: [UInt8]) async {
            queued.append(text)
            outcomes[OpenMeteoGeocoderTests.oracle(text).0.rawValue] += 1
            if queued.count == Self.window {
                await flush()
            }
        }

        /// sweep_flush (test-openmeteo.c:4174-4245).
        mutating func flush() async {
            if queued.isEmpty { return }
            let texts = queued
            queued = []
            let before = fake.requestCount
            let geo = self.geo
            let ops = await withTaskGroup(of: (Int, Fake.Op<[WxPlace]>).self) { group in
                for (i, t) in texts.enumerated() {
                    group.addTask { (i, await Fake.search(geo, t)) }
                }
                var out = [Fake.Op<[WxPlace]>?](repeating: nil, count: texts.count)
                for await (i, op) in group { out[i] = op }
                return out.map { $0! }
            }
            var want: [String] = []
            for (text, op) in zip(texts, ops) {
                let (kind, path) = OpenMeteoGeocoderTests.oracle(text)
                let ok: Bool
                switch kind {
                case .empty:
                    ok = op.value == []
                case .invalid:
                    ok = op.wxError == OpenMeteoGeocoderTests.unacceptable
                case .request:
                    ok = op.value != nil
                    want.append(path!)
                }
                if !ok {
                    failures += 1
                    Issue.record("bytes \(OpenMeteoGeocoderTests.describe(text)): expected \(kind), got \(op.outcome)")
                }
            }
            let seen = Array(fake.paths.dropFirst(before))
            if seen.sorted() != want.sorted() || fake.requestCount - before != want.count {
                failures += 1
                Issue.record("window of \(texts.count): paths \(seen), expected \(want)")
            }
        }

        /// sweep_scalar (test-openmeteo.c:4263-4277): 'ab' c 'cd', c c, c alone, c with trim padding.
        mutating func scalar(_ c: UInt32) async {
            let u = OpenMeteoGeocoderTests.utf8(c)
            await add(OpenMeteoGeocoderTests.b("ab") + u + OpenMeteoGeocoderTests.b("cd"))
            await add(u + u)
            await add(u)
            await add([0x20, 0x20, 0x09] + u + [0x0A, 0x20, 0x20])
        }

        /// sweep_scalar_range (test-openmeteo.c:4279-4286): surrogates and U+0000 skipped.
        mutating func scalarRange(_ first: UInt32, _ last: UInt32, stride step: UInt32 = 1) async {
            guard first <= last else { return }
            for c in Swift.stride(from: first, through: last, by: Int(step)) where c != 0 && !(0xD800...0xDFFF).contains(c) {
                await scalar(c)
            }
        }

        /// sweep_raw (test-openmeteo.c:4288-4296).
        mutating func raw(_ seq: [UInt8]) async {
            await add(OpenMeteoGeocoderTests.b("ab") + seq + OpenMeteoGeocoderTests.b("cd"))
        }
    }

    static func makeSweep() throws -> (Fake.Server, OpenMeteoGeocoder) {
        let fake = try Fake.Server(try Fake.Script.ok())
        return (fake, try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10))
    }

    // MARK: - geocoder/

    // C: /openmeteo/geocoder/success (test-openmeteo.c:3475-3503)
    @Test("/openmeteo/geocoder/success")
    func geocoderSuccess() async throws {
        var script = try Fake.Script.ok()
        script.geo.gzip = true
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let geo = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10)
        let op = await Fake.search(geo, Self.b("Miami"))
        let places = try #require(op.value, "\(op.outcome)")
        #expect(places.count == 10)                                                // test-openmeteo.c:3488
        #expect(places.first?.label == "Miami, Florida, United States")            // test-openmeteo.c:3490
        #expect(fake.requestCount == 1)                                            // test-openmeteo.c:3491
        #expect(fake.paths.first == "/v1/search?name=Miami&count=10&language=en&format=json") // :3492
        let head = try #require(fake.heads.first)
        let lower = head.lowercased()
        #expect(head.hasPrefix("GET /v1/search?name=Miami&count=10&language=en&format=json HTTP/1.1\r\n")) // :3495
        #expect(head.contains("\r\nUser-Agent: \(Fake.ua)\r\n"))                   // test-openmeteo.c:3496
        #expect(lower.contains("\r\naccept: application/json\r\n"))                // test-openmeteo.c:3497
        #expect(!lower.contains("cookie"))                                         // test-openmeteo.c:3498
        #expect(!lower.contains("authorization"))                                  // test-openmeteo.c:3499
        #expect(!lower.contains("referer"))                                        // test-openmeteo.c:3500
    }

    // C: /openmeteo/geocoder/escaping (test-openmeteo.c:3505-3539)
    @Test("/openmeteo/geocoder/escaping")
    func geocoderEscaping() async throws {
        let cases: [([UInt8], String)] = [
            (Self.b("Miami"), "Miami"),
            (Self.b("  Miami ") + [0x0A], "Miami"),
            ([0x09] + Self.b(" San Jose") + [0x0D, 0x0A], "San%20Jose"),
            (Self.b("S") + [0xC3, 0xA3] + Self.b("o Paulo"), "S%C3%A3o%20Paulo"),
            ([0xE6, 0x9D, 0xB1, 0xE4, 0xBA, 0xAC], "%E6%9D%B1%E4%BA%AC"),
            (Self.b("a&b=c#d?e/f%g+h"), "a%26b%3Dc%23d%3Fe%2Ff%25g%2Bh"),
            ([0x78, 0x5C, 0x79, 0x22, 0x7A, 0x27, 0x3C, 0x3E, 0x7C, 0x7B, 0x7D, 0x5E, 0x60],
             "x%5Cy%22z%27%3C%3E%7C%7B%7D%5E%60"),
            (Self.b("a-b_c.d~e"), "a-b_c.d~e"),
            (Self.b("ab"), "ab"),
            ([0xC3, 0xA9], "%C3%A9"),  // two bytes: long enough
            (Self.b("New York, NY"), "New%20York%2C%20NY"),
            (Self.b("x%00y"), "x%2500y"),
            (Self.b(".."), ".."),
            (Self.b("a b  c"), "a%20b%20%20c"),
        ]  // test-openmeteo.c:3512-3526
        for (text, escaped) in cases {
            let fake = try Fake.Server(try Fake.Script.ok())
            defer { fake.stop() }
            let geo = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10)
            let op = await Fake.search(geo, text)
            #expect(op.value != nil, "\(Self.describe(text)): \(op.outcome)")
            #expect(fake.requestCount == 1)                                        // test-openmeteo.c:3535
            let expect = "/v1/search?name=\(escaped)&count=10&language=en&format=json" // test-openmeteo.c:3536
            #expect(fake.paths.first == expect, "\(Self.describe(text))")         // test-openmeteo.c:3537
            #expect(HTTPPolicy.isValidPath(expect))                                // test-openmeteo.c:3539
        }
    }

    // C: /openmeteo/geocoder/header-lists-match-runtime (test-openmeteo.c:3675-3727), every part but
    // g_unichar_isspace() (a GLib table): the header's lists against WxText for every scalar value.
    @Test("/openmeteo/geocoder/header-lists-match-runtime (without g_unichar_isspace)")
    func geocoderHeaderListsMatchRuntime() {
        var forbiddenCount = 0
        var spaces = 0
        var mismatches: [String] = []
        let max = OpenMeteoShared.searchMaxBytes
        for c in UInt32(1)...0x10FFFF where !(0xD800...0xDFFF).contains(c) {
            let u = Self.utf8(c)
            let mid = [0x61, 0x62] + u + [0x63, 0x64]
            let twice = u + u
            let forb = Self.forbidden(c)
            let sp = Self.space(c)
            if forb { forbiddenCount += 1 }
            if sp { spaces += 1 }
            if WxText.isUsableName(bytes: mid, maxBytes: max) == forb {
                mismatches.append(String(format: "U+%04X ab c cd", c))
            }
            if WxText.isUsableName(bytes: twice, maxBytes: max) != (!forb && !sp) {
                mismatches.append(String(format: "U+%04X c c", c))
            }
            let clean = WxText.sanitize(bytes: mid, maxBytes: WxLimits.placeNameMax)
            if Array(clean.utf8) != (forb ? [0x61, 0x62, 0x63, 0x64] : mid) {
                mismatches.append(String(format: "U+%04X sanitize", c))
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")                    // test-openmeteo.c:3695
        #expect(forbiddenCount == 78)  // 64 control + 2 separators + 12 bidi (test-openmeteo.c:3707)
        #expect(spaces == 17)                                                      // test-openmeteo.c:3708
        // Not detected, and documented so: format characters (Cf) alone count as visible.
        let formatOnly: [UInt32] = [0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xE0001, 0xE0020] // :3710
        for c in formatOnly {
            let u = Self.utf8(c)
            #expect(!Self.forbidden(c))
            #expect(!Self.space(c))
            #expect(WxText.isUsableName(bytes: u + u, maxBytes: max), "U+\(String(c, radix: 16))") // :3720
        }
    }

    // C: /openmeteo/geocoder/text-validation (test-openmeteo.c:4308-4414)
    @Test("/openmeteo/geocoder/text-validation")
    func geocoderTextValidation() async throws {
        let ab = Self.b("ab")
        let cd = Self.b("cd")
        let cases: [([UInt8], Kind)] = [
            // trimmed away or a single byte: EMPTY, whatever the byte is
            ([], .empty), (Self.b(" "), .empty), (Self.b("a"), .empty), (Self.b("  a  "), .empty),
            ([0x0A, 0x09], .empty), ([0x09, 0x0A], .empty), ([0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20], .empty),
            ([0x0B], .empty), ([0x01], .empty), ([0xFF], .empty), ([0x20, 0x7F, 0x20], .empty),
            // ordinary text: a request
            (ab, .request), (Self.b("  ab  "), .request), (Self.b("a b"), .request), (Self.b("Paris"), .request),
            (Self.b("S") + [0xC3, 0xA3] + Self.b("o Paulo"), .request),
            // white space that is not trimmed: space separators only (step 3 d)
            ([0xC2, 0xA0], .invalid), ([0xE3, 0x80, 0x80], .invalid), (Self.b("  ") + [0xE3, 0x80, 0x80] + Self.b("  "), .invalid),
            ([0xC2, 0xA0, 0xC2, 0xA0], .invalid), ([0xE2, 0x80, 0x83, 0xE2, 0x80, 0x83], .invalid),
            ([0xE3, 0x80, 0x80, 0x20, 0xC2, 0xA0], .invalid), ([0xC2, 0xA0, 0x61], .request),
            // invalid UTF-8 (step 3 b)
            ([0xFF, 0xFE], .invalid), ([0x61, 0xFF, 0x7A], .invalid), (ab + [0xED, 0xA0, 0x80], .invalid),
            (ab + [0xF4, 0x90, 0x80, 0x80], .invalid), (ab + [0xC0, 0xAF], .invalid),
            // ASCII controls anywhere, also in the middle (step 3 c)
            (ab + [0x01], .invalid), ([0x61, 0x01, 0x62], .invalid), (ab + [0x7F], .invalid),
            ([0x61, 0x09, 0x62], .invalid), ([0x61, 0x0A, 0x62], .invalid), ([0x61, 0x0B, 0x62], .invalid),
            ([0x0B] + Self.b("Paris"), .invalid),
            // C1 controls
            (ab + [0xC2, 0x80], .invalid), (ab + [0xC2, 0x85] + cd, .invalid), (ab + [0xC2, 0x9F], .invalid),
            // line and paragraph separators U+2028 / U+2029 (step 3 c), at the end, inside and alone
            (ab + [0xE2, 0x80, 0xA8], .invalid), (ab + [0xE2, 0x80, 0xA9], .invalid),
            (Self.b("New") + [0xE2, 0x80, 0xA8] + Self.b("York"), .invalid),
            (Self.b("Paris") + [0xE2, 0x80, 0xA8] + Self.b("Texas"), .invalid),
            (Self.b("Paris") + [0xE2, 0x80, 0xA9] + Self.b("Texas"), .invalid), (ab + [0xE2, 0x80, 0xA8] + cd, .invalid),
            (ab + [0xE2, 0x80, 0xA9] + cd, .invalid), ([0xE2, 0x80, 0xA8, 0xE2, 0x80, 0xA8], .invalid),
            ([0xE2, 0x80, 0xA9, 0xE2, 0x80, 0xA9], .invalid),
            // bidirectional formatting characters (step 3 c)
            (ab + [0xD8, 0x9C], .invalid), (ab + [0xE2, 0x80, 0x8E], .invalid), (ab + [0xE2, 0x80, 0x8F], .invalid),
            (ab + [0xE2, 0x80, 0xAE] + cd, .invalid), (ab + [0xE2, 0x81, 0xA6] + cd, .invalid),
            (ab + [0xE2, 0x81, 0xA9] + cd, .invalid),
            // neighbours of the forbidden characters are fine
            (ab + [0xD8, 0x9B], .request), (ab + [0xD8, 0x9D], .request), (ab + [0xE2, 0x80, 0x8D], .request),
            (ab + [0xE2, 0x80, 0xAF], .request), (ab + [0xE2, 0x81, 0xA5], .request), (ab + [0xE2, 0x81, 0xAA], .request),
            (ab + [0xE2, 0x80, 0xA7], .request), (ab + [0xC2, 0xA0], .request),
            // text made only of format characters (Cf) is NOT detected: it is sent
            ([0xE2, 0x80, 0x8B, 0xE2, 0x80, 0x8B], .request), ([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], .request),
            ([0xE2, 0x81, 0xA0, 0xE2, 0x81, 0xA0], .request), ([0xC2, 0xAD, 0xC2, 0xAD], .request),
            ([0xE1, 0xA0, 0x8E, 0xE1, 0xA0, 0x8E], .request), ([0xE2, 0x80, 0x8C, 0xE2, 0x80, 0x8D], .request),
            ([0xF3, 0xA0, 0x80, 0x81, 0xF3, 0xA0, 0x80, 0x81], .request), ([0xE2, 0x80, 0x8B], .request),
            ([0xE2, 0x80, 0x8B, 0x20, 0xE2, 0x80, 0x8B], .request),
        ]  // test-openmeteo.c:4323-4372
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let geo = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10)
        var expectedRequests = 0
        for (text, kind) in cases {
            // The table and the oracle (the header's lists) must agree before the runtime is asked.
            let (oracleKind, oraclePath) = Self.oracle(text)
            #expect(oracleKind == kind, "\(Self.describe(text)): the table disagrees with the oracle") // :4372
            let op = await Fake.search(geo, text)
            switch kind {
            case .empty:
                #expect(op.value == [], "\(Self.describe(text)): \(op.outcome)")    // test-openmeteo.c:4380
            case .invalid:
                #expect(op.wxError == Self.unacceptable, "\(Self.describe(text)): \(op.outcome)") // :4384
            case .request:
                #expect(op.value != nil, "\(Self.describe(text)): \(op.outcome)")   // test-openmeteo.c:4388
                expectedRequests += 1
                #expect(fake.paths.last == oraclePath, "\(Self.describe(text))")    // test-openmeteo.c:4389
            }
            #expect(fake.requestCount == expectedRequests, "\(Self.describe(text))") // test-openmeteo.c:4391
        }
        // The byte limits (after trimming): 64 passes, 65 does not; bytes count, not characters.
        let atMax = [UInt8](repeating: 0x61, count: 64)
        let overMax = [UInt8](repeating: 0x61, count: 65)
        let wide = Array([[UInt8]](repeating: [0xC3, 0xA9], count: 32).joined())   // 64 bytes, 32 characters
        let wideOver = wide + [0xC3, 0xA9]
        let limits: [[UInt8]] = [
            atMax, Self.b("   ") + atMax + Self.b("   "), wide, overMax, Self.b("  ") + overMax + Self.b("  "), wideOver,  // test-openmeteo.c:4395
        ]  // test-openmeteo.c:4404
        for (i, text) in limits.enumerated() {
            let op = await Fake.search(geo, text)
            if i < 3 {
                #expect(op.value != nil, "limit \(i): \(op.outcome)")               // test-openmeteo.c:4401
                expectedRequests += 1
            } else {
                #expect(op.wxError == Self.unacceptable, "limit \(i): \(op.outcome)") // test-openmeteo.c:4404
            }
            #expect(fake.requestCount == expectedRequests, "limit \(i)")            // test-openmeteo.c:4407
        }
    }

    // Executor-added (L5 sweep; WxGeocoder contract in Provider.swift, C: the text is a `const char *`):
    // the text ends at its first 0x00 byte, and the oracle judges the bytes before it.
    @Test("search text ends at the first 0x00 byte (C string)")
    func geocoderTextEndsAtNUL() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let geo = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10)
        let cases: [([UInt8], [UInt8])] = [
            (Self.b("Paris") + [0x00, 0x01, 0x02], Self.b("Paris")),
            (Self.b(" ab ") + [0x00] + Self.b("cd"), Self.b(" ab ")),
            ([0x61, 0x00, 0x62, 0x63], [0x61]),
            ([0x00] + Self.b("Paris"), []),
            (Self.b("ab") + [0x00, 0xFF, 0xFE], Self.b("ab")),
        ]
        var expectedRequests = 0
        for (text, cString) in cases {
            let (kind, path) = Self.oracle(cString)
            let op = await Fake.search(geo, text)
            switch kind {
            case .empty:
                #expect(op.value == [], "\(Self.describe(text)): \(op.outcome)")
            case .invalid:
                #expect(op.wxError == Self.unacceptable, "\(Self.describe(text)): \(op.outcome)")
            case .request:
                #expect(op.value != nil, "\(Self.describe(text)): \(op.outcome)")
                expectedRequests += 1
                #expect(fake.paths.last == path, "\(Self.describe(text))")
            }
            #expect(fake.requestCount == expectedRequests, "\(Self.describe(text))")
        }
    }

    // C: /openmeteo/geocoder/every-byte (test-openmeteo.c:4416-4486)
    @Test("/openmeteo/geocoder/every-byte")
    func geocoderEveryByte() async throws {
        // The trimmed set is asserted at runtime, not assumed (C: g_ascii_isspace vs the oracle).
        for c in 1...255 {
            let byte = UInt8(c)
            let trimmedAway = OpenMeteoGeocoder.trimmed([byte, 0x5F, byte]).elementsEqual([0x5F])
            #expect(trimmedAway == Self.isTrimByte(byte), "byte \(c)")
        }
        #expect(!Self.isTrimByte(0x0B))                                            // test-openmeteo.c:4421
        // Every byte 1..255 as pre + copies * byte + post (test-openmeteo.c:4429).
        let templates: [([UInt8], Int, [UInt8])] = [
            ([], 1, []), ([], 2, []), (Self.b("ab"), 1, []), ([], 1, Self.b("ab")),
            ([0x20], 1, [0x20]), ([0x20], 2, [0x20]), (Self.b("ab"), 1, Self.b("ab")),
            ([0x09, 0x0A, 0x0C, 0x0D, 0x20], 1, [0x20, 0x0D, 0x0C, 0x0A, 0x09]),
            ([0x20, 0x09], 2, [0x0A, 0x20]), (Self.b("a"), 1, []), ([], 1, Self.b("a")), ([0x20], 1, Self.b("b")),
        ]
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        for byte in 1...255 {
            for (pre, copies, post) in templates {
                await sweep.add(pre + [UInt8](repeating: UInt8(byte), count: copies) + post)
            }
        }
        await sweep.flush()
        #expect(sweep.outcomes[Kind.empty.rawValue] > 0)                           // test-openmeteo.c:4451
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 0)                         // test-openmeteo.c:4452
        #expect(sweep.outcomes[Kind.request.rawValue] > 0)                         // test-openmeteo.c:4453
        // Pinned examples of the reported class (test-openmeteo.c:4458).
        let pinned: [([UInt8], Kind)] = [
            ([0x0B, 0x0B], .invalid), ([0x20, 0x0B, 0x0B, 0x20], .invalid), ([0x0B] + Self.b("Paris"), .invalid),
            (Self.b("Paris") + [0x0B], .invalid), ([0x0B], .empty), ([0x20, 0x0B, 0x20], .empty),
            (Self.b("Pa") + [0x0B] + Self.b("ris"), .invalid),
        ]
        for (text, kind) in pinned {
            #expect(Self.oracle(text).0 == kind, "\(Self.describe(text))")         // test-openmeteo.c:4463
            let before = fake.requestCount
            let op = await Fake.search(geo, text)
            if kind == .empty {
                #expect(op.value == [], "\(Self.describe(text)): \(op.outcome)")    // test-openmeteo.c:4469
            } else {
                #expect(op.wxError?.code == .invalidArg, "\(Self.describe(text)): \(op.outcome)") // :4471
            }
            #expect(fake.requestCount == before)                                   // test-openmeteo.c:4472
        }
    }

    // C: /openmeteo/geocoder/scalar-classes (test-openmeteo.c:4487-4527)
    @Test("/openmeteo/geocoder/scalar-classes")
    func geocoderScalarClasses() async throws {
        let classes: [(UInt32, UInt32)] = [
            // forbidden (step 3 c)
            (0x01, 0x1F), (0x7F, 0x9F), (0x2028, 0x2029), (0x061C, 0x061C), (0x200E, 0x200F), (0x202A, 0x202E),
            (0x2066, 0x2069),
            // space separators (step 3 d)
            (0x20, 0x20), (0xA0, 0xA0), (0x1680, 0x1680), (0x2000, 0x200A), (0x202F, 0x202F), (0x205F, 0x205F),
            (0x3000, 0x3000),
            // format characters: not detected
            (0xAD, 0xAD), (0x600, 0x605), (0x180E, 0x180E), (0x200B, 0x200D), (0x2060, 0x2064), (0xFEFF, 0xFEFF),
            (0xFFF9, 0xFFFB), (0xE0001, 0xE0001), (0xE0020, 0xE007F),
            // printable ASCII, the ends of each UTF-8 length, the astral planes, the surrogate gap
            (0x21, 0x7E), (0x80, 0x80), (0x7FF, 0x800), (0xD7FE, 0xD7FF), (0xE000, 0xE001), (0xFFFC, 0xFFFF),
            (0x10000, 0x10001), (0x1F600, 0x1F602), (0x1FFFE, 0x1FFFF), (0xE0000, 0xE0000), (0xF0000, 0xF0001),
            (0x10FFFC, 0x10FFFF),
            // letters and marks, non-characters, unassigned and private use
            (0xC0, 0xC2), (0xE9, 0xE9), (0x300, 0x302), (0x378, 0x379), (0x5D0, 0x5D2), (0x4E00, 0x4E01),
            (0xAC00, 0xAC01), (0xF8FF, 0xF8FF), (0xFDD0, 0xFDD1), (0xFFFD, 0xFFFD),
        ]  // test-openmeteo.c:4492
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        for (first, last) in classes {
            await sweep.scalarRange(first >= 3 ? first - 2 : 1, first - 1)          // two neighbours below
            await sweep.scalarRange(first, last)                                    // every member
            await sweep.scalarRange(last + 1, min(last + 2, 0x10FFFF))              // two above
        }
        await sweep.flush()
        #expect(sweep.outcomes[Kind.empty.rawValue] > 0)                           // test-openmeteo.c:4522
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 0)                         // test-openmeteo.c:4523
        #expect(sweep.outcomes[Kind.request.rawValue] > 0)                         // test-openmeteo.c:4524
    }

    // C: /openmeteo/geocoder/scalar-sweep-exhaustive (test-openmeteo.c:4529-4598), a slow test in C
    // (-m slow / WX_TEST_EXHAUSTIVE=1). With WEATHER_SLOW_TESTS set this runs the full sweep and
    // the C totals; the default run takes every 4099th scalar value and every 211th raw sequence
    // through the same templates (no skip: the suite gate allows none).
    @Test("/openmeteo/geocoder/scalar-sweep-exhaustive (sampled unless WEATHER_SLOW_TESTS)")
    func geocoderScalarSweepExhaustive() async throws {
        let full = TestEnvironment.slowTestsEnabled
            || ProcessInfo.processInfo.environment["WEATHER_SLOW_TESTS"] == "1"
        let scalarStride: UInt32 = full ? 1 : 4099
        let rawStride = full ? 1 : 211
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        await sweep.scalarRange(1, 0x10FFFF, stride: scalarStride)
        await sweep.flush()
        let total = sweep.outcomes.reduce(0, +)
        if full {
            #expect(total == 4 * 1_112_063)                                        // test-openmeteo.c:4544-4545
        } else {
            let sampled = stride(from: UInt32(1), through: 0x10FFFF, by: Int(scalarStride))
                .filter { !(0xD800...0xDFFF).contains($0) }.count
            #expect(total == 4 * sampled)
        }
        #expect(sweep.outcomes[Kind.empty.rawValue] > 0)                           // test-openmeteo.c:4546
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 0)                         // test-openmeteo.c:4547
        #expect(sweep.outcomes[Kind.request.rawValue] > 0)                         // test-openmeteo.c:4548
        // Raw byte sequences that cannot be a character (test-openmeteo.c:4554-4594).
        let invalidBefore = sweep.outcomes[Kind.invalid.rawValue]
        var n = 0
        func rawIfSampled(_ seq: [UInt8]) async {
            n += 1
            if n % rawStride == 0 { await sweep.raw(seq) }
        }
        for b1 in 0x80...0xFF {
            for b2 in 0x01...0xFF { await rawIfSampled([UInt8(b1), UInt8(b2)]) }
        }
        var c: UInt32 = 0
        for b1 in 0xE0...0xEF {
            for b2 in 0x80...0xFF {
                for b3 in 0x80...0xFF {
                    let seq = [UInt8(b1), UInt8(b2), UInt8(b3)]
                    if Self.decode(seq[...], 0, &c) == 0 { await rawIfSampled(seq) }
                }
            }
        }
        for b1 in 0xF0...0xF7 {
            for b2 in 0x80...0xBF {
                for b3 in 0x80...0xBF {
                    for b4 in stride(from: 0x80, through: 0xBF, by: (b1 == 0xF0 || b1 == 0xF4) ? 1 : 0x3F) {
                        let seq = [UInt8(b1), UInt8(b2), UInt8(b3), UInt8(b4)]
                        if Self.decode(seq[...], 0, &c) == 0 { await rawIfSampled(seq) }
                    }
                }
            }
        }
        let edge: [UInt8] = [0x01, 0x7F, 0x80, 0x8F, 0x90, 0xBF, 0xC0, 0xC2, 0xFF]
        for b1 in 0xF0...0xFF {
            for e1 in edge {
                for e2 in edge {
                    for e3 in edge {
                        let seq = [UInt8(b1), e1, e2, e3]
                        if Self.decode(seq[...], 0, &c) == 0 { await rawIfSampled(seq) }
                    }
                }
            }
        }
        await sweep.raw([0xF8, 0x88, 0x80, 0x80, 0x80])
        await sweep.raw([0xFC, 0x84, 0x80, 0x80, 0x80, 0x80])
        await sweep.flush()
        // C: more than 400000 invalid sequences (test-openmeteo.c:4596); the sampled run keeps the
        // same bound scaled by its stride (valid 2-byte pairs are requests, as in C).
        let invalidRaw = sweep.outcomes[Kind.invalid.rawValue] - invalidBefore
        #expect(invalidRaw > 400_000 / rawStride, "\(invalidRaw) invalid of \(n / rawStride + 2) sampled")
        #expect(sweep.failures == 0)
    }

    // C: /openmeteo/geocoder/utf8-edges (test-openmeteo.c:4600-4646)
    @Test("/openmeteo/geocoder/utf8-edges")
    func geocoderUTF8Edges() async throws {
        let pats: [[UInt8]] = [
            // overlong, surrogate, out of range, legacy lengths, stray and truncated: invalid
            [0xC0, 0x80], [0xC0, 0xAF], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF],
            [0xED, 0xA0, 0x80], [0xED, 0xAD, 0xBF], [0xED, 0xBF, 0xBF], [0xF0, 0x80, 0x80, 0x80],
            [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF4, 0xBF, 0xBF, 0xBF],
            [0xF5, 0x80, 0x80, 0x80], [0xF7, 0xBF, 0xBF, 0xBF], [0xF8, 0x88, 0x80, 0x80, 0x80],
            [0xFC, 0x84, 0x80, 0x80, 0x80, 0x80], [0x80], [0xBF], [0xC2], [0xE2, 0x80],
            [0xF0, 0x9F, 0x98], [0xFE], [0xFF], [0xC2, 0x41], [0xE2, 0x80, 0x41],
            [0xF0, 0x9F, 0x98, 0x41],
            // the valid neighbours of those forms
            [0xC2, 0xA1], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBD], [0xEF, 0xBF, 0xBE], [0xF0, 0x90, 0x80, 0x80],
            [0xF4, 0x8F, 0xBF, 0xBF],
        ]  // test-openmeteo.c:4606
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        for t in pats {
            await sweep.add(t)
            await sweep.add([0x20, 0x20] + t + [0x20, 0x20])
            await sweep.add(Self.b("ab") + t + Self.b("cd"))
            await sweep.add(Self.b("ab") + t)
            await sweep.add(t + Self.b("cd"))
        }
        await sweep.flush()
        #expect(sweep.outcomes[Kind.empty.rawValue] > 0)                           // test-openmeteo.c:4640
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 0)                         // test-openmeteo.c:4641
        #expect(sweep.outcomes[Kind.request.rawValue] > 0)                         // test-openmeteo.c:4642
    }

    // C: /openmeteo/geocoder/byte-limit-by-width (test-openmeteo.c:4647-4685)
    @Test("/openmeteo/geocoder/byte-limit-by-width")
    func geocoderByteLimitByWidth() async throws {
        let samples: [UInt32] = [0x61, 0xE9, 0x4E2D, 0x1F600]  // 1, 2, 3 and 4 bytes (test-openmeteo.c:4650)
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        for w in 1...4 {
            for fill in 0..<w {
                var k = 1
                while fill + k * w <= 72 {
                    let t = [UInt8](repeating: 0x61, count: fill)
                        + Array([[UInt8]](repeating: Self.utf8(samples[w - 1]), count: k).joined())
                    if t.count >= 56 {
                        let padded = [0x20, 0x09, 0x20] + t + [0x20, 0x0D, 0x0A]
                        // explicit expectation, independent of the oracle: up to 64 bytes is searched
                        let want: Kind = t.count <= 64 ? .request : .invalid       // test-openmeteo.c:4669
                        #expect(Self.oracle(t).0 == want)                          // test-openmeteo.c:4670
                        #expect(Self.oracle(padded).0 == want)                     // test-openmeteo.c:4671
                        await sweep.add(t)
                        await sweep.add(padded)
                    }
                    k += 1
                }
            }
        }
        await sweep.flush()
        #expect(sweep.outcomes[Kind.request.rawValue] > 20)                        // test-openmeteo.c:4680
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 20)                        // test-openmeteo.c:4681
    }

    // C: /openmeteo/geocoder/differential-fuzz (test-openmeteo.c:4686-4743); GRand(0x5ea5c) is
    // SeededRNG(0x5ea5c), the oracle and the bounds are the C ones.
    @Test("/openmeteo/geocoder/differential-fuzz")
    func geocoderDifferentialFuzz() async throws {
        let interesting: [UInt32] = [
            0x01, 0x09, 0x0B, 0x1F, 0x7F, 0x80, 0x85, 0x9F, 0xA0, 0xAD, 0x61C, 0x1680, 0x2000, 0x200A, 0x200B,
            0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202E, 0x202F, 0x205F, 0x2060, 0x2066, 0x2069, 0x3000,
            0xFEFF, 0xFFFD, 0xE0001, 0x10FFFF, 0x1F600, 0x4E2D, 0xE9,
        ]  // test-openmeteo.c:4689
        let trim: [UInt8] = [0x20, 0x09, 0x0A, 0x0C, 0x0D]                         // test-openmeteo.c:4693
        let (fake, geo) = try Self.makeSweep()
        defer { fake.stop() }
        var sweep = Sweep(fake, geo)
        var rng = SeededRNG(seed: 0x5ea5c)
        for _ in 0..<fuzzIterations(6000) {                                        // test-openmeteo.c:4700
            var t: [UInt8] = []
            let parts = Int.random(in: 0..<14, using: &rng)
            for _ in 0..<parts {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0, 1, 2:
                    t.append(UInt8.random(in: 0x61...0x7A, using: &rng))
                case 3:
                    t.append(trim[Int.random(in: 0..<5, using: &rng)])
                case 4:
                    t.append(UInt8.random(in: 0x80...0xFF, using: &rng))  // a raw high byte
                case 5:
                    t.append(UInt8.random(in: 0x01..<0x20, using: &rng))  // a raw control byte
                case 6, 7:
                    t += Self.utf8(interesting[Int.random(in: 0..<interesting.count, using: &rng)])
                case 8:
                    let c = UInt32.random(in: 0x21..<0x110000, using: &rng)
                    t += (0xD800...0xDFFF).contains(c) ? [0x78] : Self.utf8(c)
                default:
                    t += Self.b("ab")
                }
            }
            await sweep.add(t)
        }
        await sweep.flush()
        #expect(sweep.outcomes[Kind.empty.rawValue] > 100)                         // test-openmeteo.c:4738
        #expect(sweep.outcomes[Kind.invalid.rawValue] > 100)                       // test-openmeteo.c:4739
        #expect(sweep.outcomes[Kind.request.rawValue] > 100)                       // test-openmeteo.c:4740
    }

    // C: /openmeteo/geocoder/failures (test-openmeteo.c:4745-4794)
    @Test("/openmeteo/geocoder/failures")
    func geocoderFailures() async throws {
        let cases: [(Fake.Reply, WxError.Code, String?)] = [
            (Fake.Reply(.reply, 404, "{}"), .notFound, nil),
            (Fake.Reply(.reply, 429, "{}"), .rateLimited, nil),
            (Fake.Reply(.reply, 400, #"{"error":true,"reason":"x"}"#), .http, nil),
            (Fake.Reply(.reply, 500, "{}"), .http, nil),
            (Fake.Reply(.reply, 302, "{}"), .http, nil),
            (Fake.Reply(.reply, 200, "not json"), .parse, nil),
            (Fake.Reply(.reply, 200, ""), .parse, nil),
            (Fake.Reply(.reply, 200, "[]"), .parse, nil),
            (Fake.Reply(.reply, 200, #"{"results":"x"}"#), .parse, "unexpected search response shape"),
            (Fake.Reply(.reply, 200, #"{"error":true,"reason":"Rate"}"#), .http, "Open-Meteo reported an error: Rate"),
            (Fake.Reply(.close), .network, nil),
            (Fake.Reply(.cut, 200, #"{"results":"#), .network, nil),
            (Fake.Reply(.hang), .timeout, nil),
        ]  // test-openmeteo.c:4751
        for (i, (reply, code, message)) in cases.enumerated() {
            var script = try Fake.Script.ok()
            script.geo = reply
            let fake = try Fake.Server(script)
            defer { fake.stop() }
            let geo = try Fake.geocoder(fake, timeoutMs: 250, backoffMs: 5)
            let op = await Fake.search(geo, Self.b("Miami"))
            #expect(op.wxError?.code == code, "case \(i): \(op.outcome)")           // test-openmeteo.c:4774
            if let message {
                #expect(op.wxError?.message == message, "case \(i)")               // test-openmeteo.c:4777
            }
        }
        // A body without results is a success with no place.
        var script = try Fake.Script.ok()
        script.geo.body = #"{"generationtime_ms":0.7}"#                             // test-openmeteo.c:4783
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let geo = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 5)
        let op = await Fake.search(geo, Self.b("Nowhereville"))
        #expect(op.value == [], "\(op.outcome)")                                   // test-openmeteo.c:4790
    }

    // C: /openmeteo/geocoder/cancel-lifecycle (test-openmeteo.c:4796-4842), without the "cancelled in
    // the callback, before finish" step (Swift has no finish call; the provider's grace-window tests
    // pin the cancel-wins-over-a-ready-result rule).
    @Test("/openmeteo/geocoder/cancel-lifecycle")
    func geocoderCancelLifecycle() async throws {
        var script = try Fake.Script.ok()
        script.geo = Fake.Reply(.hang)
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let geo = try Fake.geocoder(fake, timeoutMs: 10000, backoffMs: 10)
        let task = Task { await Fake.search(geo, Self.b("Miami")) }
        try await Task.sleep(for: .milliseconds(150))                              // test-openmeteo.c:4805
        task.cancel()
        var op = await task.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:4807
        #expect(op.elapsedMs < 3000, "\(op.elapsedMs)")                            // test-openmeteo.c:4808
        // already cancelled: no request
        let before = fake.requestCount
        op = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Fake.search(geo, Self.b("Miami"))
        }.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:4815
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requestCount == before)                                       // test-openmeteo.c:4817
        // the object dropped in flight
        var ok = try Fake.Script.ok()
        ok.geo.delayMs = 200                                                       // test-openmeteo.c:4832
        let fake2 = try Fake.Server(ok)
        defer { fake2.stop() }
        weak var weakGeo: OpenMeteoGeocoder?
        let dropped: Task<Fake.Op<[WxPlace]>, Never>
        do {
            let geo2 = try Fake.geocoder(fake2, timeoutMs: 5000, backoffMs: 10)
            weakGeo = geo2
            dropped = Task { [geo2] in await Fake.search(geo2, Self.b("Miami")) }
        }
        op = await dropped.value
        #expect(op.value?.count == 10, "\(op.outcome)")                            // test-openmeteo.c:4838
        #expect(await OpenMeteoProviderTests.waitFor(timeoutMs: 100) { weakGeo == nil })
    }

    // C: /openmeteo/geocoder/registry (test-openmeteo.c:4844-4860)
    @Test("/openmeteo/geocoder/registry")
    @MainActor
    func geocoderRegistry() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let reg = WxRegistry()
        reg.geocoder = try Fake.geocoder(fake, timeoutMs: 5000, backoffMs: 10)
        let geo = try #require(reg.geocoder as? OpenMeteoGeocoder)
        let op = await Fake.search(geo, Self.b("Miami"))
        #expect(op.value?.count == 10, "\(op.outcome)")                            // test-openmeteo.c:4855
    }
}
