// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StrictJSONTests.swift - ports the /fileio/json-* cases of
// src/storage/test-storage.c (registrations :4626-4632): the strict JSON
// gate and the two JSON writers. Nested in FileIOTests so that
// `-only-testing:WeatherCoreTests/FileIOTests` runs them. Byte literals are
// the C literals decoded (C escapes \" \\ \xNN \0 \f \v), cited path:line.
// The C inputs that hold the JSON escape TEXT backslash-u-HHHH of a printable
// code point (test-storage.c:480, :507, :3708, :3741-3743, :3790-3793) spell
// the backslash as the interpolated one-byte constant `bs` (\#(bs)uHHHH), so
// no tool can decode that text into the character it denotes (the U05
// iteration-1 defect). Every such table also checks its byte counts against
// the C strlen of the cited literal (measured by compiling the C lines).
// GLib's GRand is replaced by SeededRNG (DECISIONS #17): the C oracles are
// kept, the random sequences are not.

import Darwin
import Foundation
import Testing
@testable import WeatherCore

/// One backslash byte (0x5C), interpolated into raw strings as \#(bs).
private let bs = String(UnicodeScalar(UInt8(0x5C)))

extension FileIOTests {
    @Suite struct StrictGate {
        private static func gate(_ bytes: [UInt8], _ depth: Int) -> Bool {
            StrictJSON.check(bytes, maxDepth: depth)
        }

        private static func gate(_ text: String, _ depth: Int) -> Bool {
            StrictJSON.check(Array(text.utf8), maxDepth: depth)
        }

        private static func nested(_ depth: Int, _ open: String, _ close: String) -> String {
            String(repeating: open, count: depth) + String(repeating: close, count: depth)
        }

        // C: /fileio/json-depth (test-storage.c:442-493)
        @Test func jsonDepth() {
            let ok = Self.nested(32, "[", "]")
            let deep = Self.nested(33, "[", "]")
            let deepObj = #"{"a":"# + deep + "}"
            #expect(Self.gate(ok, 32)) // :447
            #expect(!Self.gate(deep, 32)) // :448
            #expect(!Self.gate(deepObj, 32)) // :449
            // Brackets in strings (with escaped quotes) do not count (:450-452).
            #expect(Self.gate(#"["[[[[[[\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["]"#, 1))
            #expect(Self.gate([UInt8](), 0)) // :453
            #expect(!Self.gate("[", 0)) // :454

            // Structure: closers underflow, mismatch, unclosed containers (:457-459).
            for bad in ["]]]][", "[}", "{]", "[[]", "]", "[]]", #"{"a":[}]"#, "[{]}"] {
                #expect(!Self.gate(bad, 32), "\(bad)")
            }

            // Lenient json-glib syntax and stray bytes outside strings (:462-470).
            let badLex: [[UInt8]] = [
                Array(#"['"',[[["#.utf8), Array(#"/*"*/[[["#.utf8), [0x2F, 0x2F, 0x20, 0x22, 0x0A, 0x5B],
                Array("['a']".utf8), Array("{'a':1}".utf8), Array("[1] # x".utf8), Array("[/**/]".utf8),
                Array("[b]".utf8), Array("[x]".utf8),
                [0x5B, 0x74, 0x72, 0x75, 0x20, 0x65, 0x2C, 0xC3, 0xA9, 0x5D], // "[tru e,\xc3\xa9]"
                [0x5B, 0x0C, 0x31, 0x5D], [0x5B, 0x0B, 0x31, 0x5D], [0x5B, 0x01, 0x5D], // "[\f1]" "[\v1]" "[\x01]"
                [0x5B, 0x31, 0x5D, 0x7F], [0x5B, 0x22, 0x61, 0x22, 0x5D, 0xFF], // "[1]\x7f" "[\"a\"]\xff"
                [0x00, 0x5B, 0x5D], // "\0[]" with length 3 (:467)
            ]
            for bad in badLex {
                #expect(!Self.gate(bad, 32), "\(bad)")
            }

            // Strings: raw control bytes, bad/truncated escapes, unterminated (:472-475).
            let badStr: [[UInt8]] = [
                [0x5B, 0x22, 0x61, 0x0A, 0x62, 0x22, 0x5D], [0x5B, 0x22, 0x61, 0x09, 0x62, 0x22, 0x5D],
                Array(#"["\x"]"#.utf8), Array(#"["\u12"]"#.utf8), Array(#"["\u12G4"]"#.utf8),
                Array(#"["\"#.utf8), Array(#"["abc"#.utf8), Array(#"["\"]"#.utf8), Array(#"["\u123"#.utf8),
            ]
            for bad in badStr {
                #expect(!Self.gate(bad, 32), "\(bad)")
            }
            #expect(!Self.gate([0x5B, 0x22, 0x61, 0x00, 0x62, 0x22, 0x5D], 32)) // :476 NUL inside a string

            // Valid text, including every escape, non-ASCII bytes and ' / # inside strings (:478-483).
            let good: [UInt8] = Array(#"{"a": [1, -2.5e+10, true, false, null, "x\"\\\/\b\f\n\r\t\#(bs)u00e9\#(bs)uD83D", "'/#\\", ""#.utf8)
                + [0xC3, 0xA9, 0xFF] + Array(#""], "b":{}, "c":[]}"#.utf8) + [0x0A, 0x09, 0x0D, 0x20]
            #expect(good.count == 108, "strlen of the :480-481 literal")
            #expect(Self.gate(good, 2)) // :482
            #expect(!Self.gate(good, 1)) // :483

            // Siblings do not accumulate (:485-490).
            let many = "[" + String(repeating: "[],", count: 5000) + "[]]"
            #expect(Self.gate(many, 2))
        }

        // C: /fileio/json-strict-random (test-storage.c:539-596)
        @Test func jsonStrictRandom() {
            // Guard: byte counts equal the C strlen of each :507-508 fragment.
            #expect(GateOracle.stringFragments.map(\.count) == [1, 1, 1, 1, 1, 1, 2, 2, 6, 2, 2, 2, 1, 1])
            var rng = SeededRNG(seed: 12345) // C seed :541
            for n in 0 ..< fuzzIterations(3000) {
                var doc: [UInt8] = []
                let budget = Int.random(in: 0 ..< 12, using: &rng)
                GateOracle.randomValue(&doc, &rng, budget)
                #expect(Self.gate(doc, 32), "iteration \(n)")
                // A valid document of depth <= 12 is accepted at exactly its depth and refused one below.
                let (maxd, _, _) = GateOracle.scanDepth(doc[...])
                #expect(Self.gate(doc, maxd), "iteration \(n)")
                if maxd > 0 {
                    #expect(!Self.gate(doc, maxd - 1), "iteration \(n)")
                }
                // Truncation: a strict prefix passes only when it is itself balanced.
                if !doc.isEmpty && maxd > 0 {
                    let cut = Int.random(in: 0 ..< doc.count, using: &rng)
                    let prefix = Array(doc[0 ..< cut])
                    if Self.gate(prefix, 32) {
                        let (_, d2, inString) = GateOracle.scanDepth(prefix[...])
                        #expect(d2 == 0 && !inString, "iteration \(n): prefix of \(cut) bytes")
                    }
                }
                // A forbidden byte placed between tokens (outside any string) is refused.
                let forbidden: [UInt8] = [0x27, 0x2F, 0x23, 0x01, 0xFF] // "'/#\x01\xff" :592
                doc.insert(forbidden[Int.random(in: 0 ..< 5, using: &rng)], at: 0)
                #expect(!Self.gate(doc, 32), "iteration \(n)")
            }
        }

        // C: /fileio/json-strict-differential (test-storage.c:3706-3762)
        @Test func jsonStrictDifferential() {
            let alphabet: [UInt8] = Array(#"[]{}"\#(bs)u0123456789abcdefABCDEF-+.,: "#.utf8) + [0x09, 0x0A, 0x0D]
                + Array("truefalsn'/#xzE".utf8) // :3708
            // Guard: the C alphabet (:3708) has strlen 53 and holds the backslash,
            // 'u' and '0'-'3', so random buffers can form the escape of U+0000.
            #expect(alphabet.count == 53, "strlen of the :3708 alphabet")
            for c: UInt8 in [0x5C, 0x75, 0x30, 0x31, 0x32, 0x33] {
                #expect(alphabet.contains(c), "the :3708 alphabet holds byte \(c)")
            }
            let extra: [UInt8] = [0x00, 0x01, 0x1F, 0x20, 0x7F, 0x80, 0xC3, 0xFF, 0x0C, 0x0B] // :3709
            let biasedSet: [UInt8] = Array(#"[]{}"\ ,:"#.utf8) // :3717
            var rng = SeededRNG(seed: 2026) // :3710
            var accepted = 0
            for _ in 0 ..< fuzzIterations(600_000) {
                let n = Int.random(in: 0 ..< 26, using: &rng)
                let biased = Bool.random(using: &rng)
                var buf = [UInt8](repeating: 0, count: n)
                for i in 0 ..< n {
                    let pick = Int.random(in: 0 ..< (biased ? 100 : 10), using: &rng)
                    if pick < 8 && biased {
                        buf[i] = biasedSet[Int.random(in: 0 ..< 9, using: &rng)]
                    } else if pick < 8 {
                        buf[i] = extra[Int.random(in: 0 ..< extra.count, using: &rng)]
                    } else {
                        buf[i] = alphabet[Int.random(in: 0 ..< alphabet.count, using: &rng)]
                    }
                }
                let depth = Int.random(in: 0 ..< 5, using: &rng)
                let a = Self.gate(buf, depth)
                let b = GateOracle.refCheck(buf, depth)
                if a != b {
                    Issue.record("gate says \(a), reference says \(b) for \(buf) at depth \(depth)")
                    return
                }
                accepted += a ? 1 : 0
            }
            #expect(accepted > 1000, "the generator reaches the accepting paths") // :3734

            // Strings assembled from well-formed fragments: accepted exactly when no
            // fragment is the escape of U+0000 (:3738-3760).
            let frag: [[UInt8]] = [
                Array("a".utf8), Array(#"\#(bs)u00e9"#.utf8), Array(#"\u0001"#.utf8), Array(#"\uD83D"#.utf8),
                Array(#"\u0000"#.utf8), Array(#"\\u0000"#.utf8), Array(#"\\"#.utf8), Array(#"\""#.utf8),
                Array(#"\/"#.utf8), Array(#"\n"#.utf8), Array(#"\u00000"#.utf8), [0xC3, 0xA9],
                Array("'".utf8), Array("/".utf8), Array("#".utf8), Array(#"\u0010"#.utf8), Array(#"\#(bs)uFFFF"#.utf8),
            ]
            // Guard: byte counts equal the C strlen of each :3741-3743 fragment.
            #expect(frag.map(\.count) == [1, 6, 6, 6, 6, 7, 2, 2, 2, 2, 7, 2, 1, 1, 1, 6, 6])
            let nulFragments: Set<Int> = [4, 10] // "\\u0000" and "\\u00000" (:3750)
            var rejected = 0
            for iter in 0 ..< fuzzIterations(20_000) {
                var doc: [UInt8] = Array(#"{"k":[""#.utf8)
                var hasNul = false
                for _ in 0 ..< Int.random(in: 0 ..< 8, using: &rng) {
                    let pick = Int.random(in: 0 ..< frag.count, using: &rng)
                    doc += frag[pick]
                    hasNul = hasNul || nulFragments.contains(pick)
                }
                doc += Array(#""]}"#.utf8)
                #expect(Self.gate(doc, 32) == !hasNul, "iteration \(iter)") // :3754
                #expect(GateOracle.refCheck(doc, 32) == !hasNul, "iteration \(iter)") // :3755
                rejected += hasNul ? 1 : 0
            }
            #expect(rejected > 1000) // :3758
        }

        // C: /fileio/json-strict-nul-escape (test-storage.c:3767-3820)
        @Test func jsonStrictNulEscape() {
            // Rows :3773-3799 in order; len is the C strlen of each row's literal.
            let table: [(text: String, ok: Bool, len: Int)] = [ // :3772-3799
                (#"["\u0000"]"#, false, 10), (#"["a\u0000b"]"#, false, 12), (#"["\u0000a"]"#, false, 11),
                (#"["a\u0000"]"#, false, 11), (#"["\u00000"]"#, false, 11), (#"["\u0000\u0000"]"#, false, 16),
                (#"{"\u0000":1}"#, false, 12), (#"{"k":"\u0000"}"#, false, 14),
                (#"{"k":{"j":["x","\u0000"]}}"#, false, 26),
                (#""\u0000""#, false, 8), (#"["\\\u0000"]"#, false, 12), (#"["Miami\u0000\u001b[31mjunk"]"#, false, 29),
                (#"["\\u0000"]"#, true, 11), (#"["\\\\u0000"]"#, true, 13), (#"["u0000"]"#, true, 9),
                (#"["\u0001"]"#, true, 10), (#"["\u0010"]"#, true, 10),
                (#"["\#(bs)u0100"]"#, true, 10), // :3790
                (#"["\#(bs)u1000"]"#, true, 10), // :3791
                (#"["\u001f"]"#, true, 10),
                (#"["\#(bs)u00e9\#(bs)u00E9\#(bs)uD83D\#(bs)uDE80"]"#, true, 28), // :3793
                (#"["\u000"]"#, false, 9), (#"["\u00"]"#, false, 8), (#"["\u"]"#, false, 6), (#"["\u000g"]"#, false, 10),
                (#"["\U0000"]"#, false, 10), (#"["\u0000"#, false, 8),
            ]
            #expect(table.count == 27, "rows :3773-3799")
            for (index, row) in table.enumerated() {
                let line = 3773 + index
                #expect(row.text.utf8.count == row.len, "test-storage.c:\(line) strlen guard: \(row.text)")
                #expect(Self.gate(row.text, 32) == row.ok, "test-storage.c:\(line) \(row.text)") // :3803
                #expect(GateOracle.refCheck(Array(row.text.utf8), 32) == row.ok, "test-storage.c:\(line) \(row.text)") // :3805
            }
            // Every prefix of the interesting documents (:3809-3818; the guard page
            // itself is C memory-safety machinery): gate and reference agree.
            for doc in [#"["\u0000"]"#, #"["\u0001\u0000"]"#, #"{"\u0000":"\u0000"}"#] {
                let bytes = Array(doc.utf8)
                for n in 0 ... bytes.count {
                    let prefix = Array(bytes[0 ..< n])
                    #expect(Self.gate(prefix, 32) == GateOracle.refCheck(prefix, 32), "\(doc) prefix \(n)")
                }
            }
        }

        // C: /fileio/json-append-string (test-storage.c:610-631)
        @Test func jsonAppendString() {
            // special_bytes (:598-608): 0x01-0x1f, 0x7f, '"' and '\\'.
            let special: [UInt8] = Array(0x01 ... 0x1F) + [0x7F, 0x22, 0x5C]
            #expect(special.count == 34)
            for c in special {
                var out = ""
                StrictJSON.appendString(String(decoding: [0x61, c, 0x62], as: UTF8.self), to: &out)
                #expect(Self.gate(out, 1), "byte \(c)") // :619
                let want: String
                if c == 0x22 || c == 0x5C {
                    want = "\"a\\" + String(UnicodeScalar(c)) + "b\"" // "\"a\\%cb\"" :623
                } else if c < 0x20 {
                    want = "\"a\\u" + String(format: "%04x", c) + "b\"" // "\"a\\u%04xb\"" :625
                } else {
                    want = "\"a" + String(UnicodeScalar(c)) + "b\"" // "\"a%cb\"" :627
                }
                #expect(out == want, "byte \(c)") // :628
            }
            var out = "x"
            StrictJSON.appendString("", to: &out)
            #expect(out == "x\"\"") // :630
            // Bytes >= 0x80 are copied unchanged (wx-fileio.h:208).
            var utf = ""
            StrictJSON.appendString("Zürich", to: &utf)
            #expect(Array(utf.utf8) == [0x22] + Array("Zürich".utf8) + [0x22])
        }

        // Executor-added, no C counterpart (extends /fileio/json-append-string,
        // test-storage.c:610-631): the C writer walks a NUL-terminated string
        // (wx-fileio.c:405), so text after U+0000 never reaches the file; the
        // Swift writer stops there too and its output passes the gate.
        @Test func jsonAppendStringStopsAtNul() {
            var out = ""
            StrictJSON.appendString("a\u{0}b", to: &out)
            #expect(out == "\"a\"")
            #expect(Self.gate(out, 1))
        }

        // C: /fileio/json-append-double (test-storage.c:788-818), check_double_roundtrip :763-786
        @Test func jsonAppendDouble() throws {
            let specials: [Double] = [ // :790-794
                0.0, -0.0, 1.0, -1.0, 0.1, 1.0 / 3.0,
                1e300, -1e300, 5e-324, -5e-324, 2.2250738585072014e-308,
                Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 123456789012345678.0, 1e15, 1e16, 1e17,
                0.30000000000000004, 9007199254740993.0, .nan, .infinity, -.infinity,
                25.7617, -80.1918, 100.0, 1e-5, 1e21, 1.7976931348623157e308,
            ]
            for v in specials {
                try GateOracle.checkDoubleRoundtrip(v, parser: true)
            }
            // Random bit patterns, including subnormals (:798-805).
            var rng = SeededRNG(seed: 4711)
            for _ in 0 ..< fuzzIterations(100_000) {
                try GateOracle.checkDoubleRoundtrip(Double(bitPattern: rng.next()), parser: true)
            }
            for _ in 0 ..< fuzzIterations(20_000) {
                try GateOracle.checkDoubleRoundtrip(Double.random(in: -200.0 ..< 200.0, using: &rng), parser: true)
            }
            // Appends, never replaces (:810-812).
            var out = "x"
            StrictJSON.appendDouble(2.5, to: &out)
            #expect(out == "x2.5")
            // NaN and +-inf are null, -0 is -0.0 (wx-fileio.h:234-237).
            var special = ""
            StrictJSON.appendDouble(-0.0, to: &special)
            StrictJSON.appendDouble(.nan, to: &special)
            #expect(special == "-0.0null")
        }
    }
}

/// The C test's independent oracles: ref_check (test-storage.c:3637-3703),
/// random_value (:494-537), check_double_roundtrip (:762-786) and the depth
/// scan of /fileio/json-strict-random (:548-560).
private enum GateOracle {
    /// ref_check: a stack-based reference implementation of the gate.
    static func refCheck(_ t: [UInt8], _ maxDepth: Int) -> Bool {
        var stack = [UInt8](repeating: 0, count: 32)
        var depth = 0
        var i = 0
        let n = t.count
        let escapes = Array(#""\/bfnrt"#.utf8)
        let plain = Array(" \t\n\r,:0123456789-+.eEtruflsna".utf8)
        while i < n {
            let c = t[i]
            if c == 0x22 {
                i += 1
                while true {
                    if i >= n { return false }
                    let s = t[i]
                    if s == 0x22 { i += 1; break }
                    if s < 0x20 { return false }
                    if s == 0x5C {
                        if i + 1 >= n { return false }
                        let e = t[i + 1]
                        if e != 0 && escapes.contains(e) { i += 2; continue }
                        if e != UInt8(ascii: "u") || i + 6 > n { return false }
                        var allZero = true
                        for k in 2 ..< 6 {
                            let h = t[i + k]
                            let isHex = (h >= 0x30 && h <= 0x39) || (h >= 0x41 && h <= 0x46) || (h >= 0x61 && h <= 0x66)
                            if !isHex { return false }
                            allZero = allZero && h == 0x30
                        }
                        if allZero { return false } // the escape of U+0000
                        i += 6
                        continue
                    }
                    i += 1
                }
                continue
            }
            if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") {
                if depth >= maxDepth { return false }
                stack[depth] = c
                depth += 1
                i += 1
                continue
            }
            if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") {
                let opener = c == UInt8(ascii: "]") ? UInt8(ascii: "[") : UInt8(ascii: "{")
                if depth == 0 || stack[depth - 1] != opener { return false }
                depth -= 1
                i += 1
                continue
            }
            if c != 0 && plain.contains(c) {
                i += 1
                continue
            }
            return false
        }
        return depth == 0
    }

    /// The depth scan of :548-560 / :571-579: maximum depth, final depth and
    /// whether the scan ends inside a string.
    static func scanDepth(_ doc: ArraySlice<UInt8>) -> (max: Int, final: Int, inString: Bool) {
        var depth = 0
        var maxd = 0
        var inString = false
        var i = doc.startIndex
        while i < doc.endIndex {
            let c = doc[i]
            if inString {
                if c == 0x5C { i += 1 } else if c == 0x22 { inString = false }
            } else if c == 0x22 {
                inString = true
            } else if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") {
                depth += 1
                maxd = max(maxd, depth)
            } else if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") {
                depth -= 1
            }
            i += 1
        }
        return (maxd, depth, inString)
    }

    /// The string fragments of random_value (test-storage.c:507-508).
    static let stringFragments: [[UInt8]] = [
        Array("a".utf8), Array("'".utf8), Array("/".utf8), Array("#".utf8), Array("[".utf8), Array("{".utf8),
        Array(#"\""#.utf8), Array(#"\\"#.utf8), Array(#"\#(bs)u00e9"#.utf8), [0xC3, 0xA9],
        Array("/*".utf8), Array(#"\n"#.utf8), Array(" ".utf8), Array("]".utf8),
    ]

    /// random_value: appends a random JSON value of nesting at most `budget`.
    static func randomValue(_ out: inout [UInt8], _ r: inout SeededRNG, _ budget: Int) {
        let ws = ["", " ", "\n", "\t ", "\r\n"]
        out += Array(ws[Int.random(in: 0 ..< 5, using: &r)].utf8)
        let kind = Int.random(in: 0 ..< (budget > 0 ? 8 : 5), using: &r)
        switch kind {
        case 0:
            out += Array("null".utf8)
        case 1:
            out += Array((Bool.random(using: &r) ? "true" : "false").utf8)
        case 2:
            out += Array(String(Int.random(in: -100_000 ..< 100_000, using: &r)).utf8)
        case 3:
            out += Array(String(format: "%.3e", Double.random(in: -1e9 ..< 1e9, using: &r)).utf8)
        case 4:
            out.append(0x22)
            for _ in 0 ..< Int.random(in: 0 ..< 8, using: &r) {
                out += stringFragments[Int.random(in: 0 ..< 14, using: &r)]
            }
            out.append(0x22)
        case 5, 6:
            out.append(UInt8(ascii: "["))
            var i = Int.random(in: 0 ..< 4, using: &r)
            while i > 0 {
                randomValue(&out, &r, budget - 1)
                out.append(i > 1 ? UInt8(ascii: ",") : UInt8(ascii: " "))
                i -= 1
            }
            out.append(UInt8(ascii: "]"))
        default:
            out.append(UInt8(ascii: "{"))
            var i = Int.random(in: 0 ..< 4, using: &r)
            while i > 0 {
                out += Array("\"k\(i)\":".utf8)
                randomValue(&out, &r, budget - 1)
                out.append(i > 1 ? UInt8(ascii: ",") : UInt8(ascii: " "))
                i -= 1
            }
            out.append(UInt8(ascii: "}"))
        }
        out += Array(ws[Int.random(in: 0 ..< 5, using: &r)].utf8)
    }

    /// check_double_roundtrip: at most 24 bytes, "null" for non-finite values,
    /// otherwise passes the gate and reads back bit-identical (-0.0 included);
    /// with `parser`, Foundation's JSONDecoder (the Swift stand-in for
    /// json-glib, :778-784) decodes the same bits.
    static func checkDoubleRoundtrip(_ v: Double, parser: Bool) throws {
        var out = ""
        StrictJSON.appendDouble(v, to: &out)
        #expect(out.utf8.count <= 24, "\(out)") // :767
        if !v.isFinite {
            #expect(out == "null") // :769
            return
        }
        #expect(StrictJSON.check(Array(out.utf8), maxDepth: 1), "\(out)") // :772
        var end: UnsafeMutablePointer<CChar>?
        let back = out.withCString { start in
            let value = strtod(start, &end) // the xctest process never calls setlocale: C locale
            #expect(end == UnsafeMutablePointer(mutating: start) + strlen(start), "\(out) not fully parsed") // :775
            return value
        }
        #expect(back.bitPattern == v.bitPattern, "\(out) reads back as \(back), not \(v)") // :776
        if parser {
            // Foundation's JSONDecoder is the Swift stand-in for json-glib (:778-784).
            // (JSONSerialization is NOT used: it mis-rounds some 17-digit numbers by 1 ULP.)
            let back = try JSONDecoder().decode([Double].self, from: Data("[\(out)]".utf8))
            #expect(back.first?.bitPattern == v.bitPattern, "\(out) decoded as \(String(describing: back.first))") // :782-784
        }
    }
}
