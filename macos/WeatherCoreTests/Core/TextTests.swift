// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// TextTests.swift - port of the text cases of src/core/test-core.c
// (registered at src/core/test-core.c:3536-3545). Inputs and expected
// outputs are the C literals, written with the C escapes (`\xHH`, `\n`, `\t`,
// `\r`) inside raw strings and turned into bytes by `cBytes`, so they can be
// compared with the C source line by line.

import Foundation
import Testing
@testable import WeatherCore

/// The bytes of a C string literal body: `\xHH` (exactly two hex digits, as
/// every literal in test-core.c), `\n`, `\t`, `\r`, `\\`; anything else is
/// its UTF-8 encoding.
private func cBytes(_ literal: String) -> [UInt8] {
    var out: [UInt8] = []
    let src = Array(literal.utf8)
    var i = 0
    while i < src.count {
        if src[i] == UInt8(ascii: "\\") && i + 1 < src.count {
            switch src[i + 1] {
            case UInt8(ascii: "x"):
                let hex = String(decoding: src[(i + 2)..<(i + 4)], as: UTF8.self)
                out.append(UInt8(hex, radix: 16)!)
                i += 4
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "t"): out.append(0x09); i += 2
            case UInt8(ascii: "r"): out.append(0x0D); i += 2
            default: out.append(src[i + 1]); i += 2
            }
        } else {
            out.append(src[i])
            i += 1
        }
    }
    return out
}

/// assert_utf8_clean (src/core/test-core.c:127-138), with Unicode properties
/// as the independent classifier: no Cc character (g_unichar_iscntrl), none
/// of U+2028, U+2029, U+061C, U+200E, U+200F, U+202A...U+202E, U+2066...U+2069.
/// (Validity is guaranteed by `String`; byte checks are done by the callers.)
private func expectUTF8Clean(_ s: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for c in s.unicodeScalars {
        let v = c.value
        let bad = c.properties.generalCategory == .control || v == 0x2028 || v == 0x2029 || v == 0x061C
            || v == 0x200E || v == 0x200F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
        #expect(!bad, "forbidden U+\(String(v, radix: 16)) in output", sourceLocation: sourceLocation)
    }
}

/// assert_sanitized (src/core/test-core.c:1340-1347): exact bytes, clean, <= max bytes.
private func expectSanitized(
    _ input: String?, _ max: Int, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    let out = input.map { WxText.sanitize(bytes: cBytes($0), maxBytes: max) } ?? WxText.sanitize(nil, maxBytes: max)
    #expect(Array(out.utf8) == cBytes(expected), "sanitize(\(input ?? "NULL"), \(max))", sourceLocation: sourceLocation)
    if let input {
        // the C literal is NUL-terminated: the same bytes followed by NUL and junk give the same result
        let terminated = WxText.sanitize(bytes: cBytes(input) + [0, 0x41, 0x80], maxBytes: max)
        #expect(Array(terminated.utf8) == cBytes(expected), "NUL-terminated \(input)", sourceLocation: sourceLocation)
    }
    expectUTF8Clean(out, sourceLocation: sourceLocation)
    #expect(out.utf8.count <= max, sourceLocation: sourceLocation)
}

/// A byte collection that records which offsets were read and answers 0x00
/// (instead of trapping) for a read past its end, so a test can assert the
/// documented read bounds - the Swift analogue of the C tests' PROT_NONE
/// guard page (test-core.c:1452-1494, 2700-2760) without crashing the process.
private struct ReadTrackingBytes: Collection {
    final class Log: @unchecked Sendable {
        var maxOffset = -1
        var outOfBounds = 0
    }

    let storage: [UInt8]
    let log = Log()

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }
    func index(after i: Int) -> Int { i + 1 }

    subscript(position: Int) -> UInt8 {
        if position >= storage.count || position < 0 {
            log.outOfBounds += 1
            return 0
        }
        log.maxOffset = Swift.max(log.maxOffset, position)
        return storage[position]
    }
}

@Suite struct TextTests {
    // C: /core/text/sanitize-basic (src/core/test-core.c:1350-1382)
    @Test func sanitizeBasic() {
        expectSanitized(nil, 100, "")
        expectSanitized("", 100, "")
        expectSanitized("Miami", 100, "Miami")
        expectSanitized("Miami", 0, "")
        expectSanitized(#"S\xc3\xa3o Paulo"#, 100, #"S\xc3\xa3o Paulo"#)
        expectSanitized(#"\xe6\x9d\xb1\xe4\xba\xac"#, 100, #"\xe6\x9d\xb1\xe4\xba\xac"#)
        expectSanitized(#"\xf0\x9f\x8c\xa7 rain"#, 100, #"\xf0\x9f\x8c\xa7 rain"#)  // astral plane
        // controls are stripped
        expectSanitized(#"a\nb\tc\rd"#, 100, "abcd")
        expectSanitized(#"a\x01\x02\x1fb"#, 100, "ab")
        expectSanitized(#"a\x7fb"#, 100, "ab")
        expectSanitized(#"a\xc2\x80\xc2\x9fb"#, 100, "ab")  // C1
        expectSanitized(#"\x1b[31mred\x1b[0m"#, 100, "[31mred[0m")
        expectSanitized(#"\n\n\n"#, 100, "")
        // bidi and format overrides
        expectSanitized(#"a\xe2\x80\xaab"#, 100, "ab")
        expectSanitized(#"a\xe2\x80\xabb"#, 100, "ab")
        expectSanitized(#"a\xe2\x80\xacb"#, 100, "ab")
        expectSanitized(#"a\xe2\x80\xadb"#, 100, "ab")
        expectSanitized(#"a\xe2\x80\xaeb"#, 100, "ab")
        expectSanitized(#"a\xe2\x81\xa6b\xe2\x81\xa7c\xe2\x81\xa8d\xe2\x81\xa9e"#, 100, "abcde")
        expectSanitized(#"a\xe2\x80\x8eb\xe2\x80\x8fc"#, 100, "abc")
        expectSanitized(#"a\xd8\x9cb"#, 100, "ab")  // U+061C
        expectSanitized(#"a\xe2\x80\xa8b\xe2\x80\xa9c"#, 100, "abc")  // U+2028/9
        // characters next to the forbidden ranges survive
        expectSanitized(#"a\xe2\x80\xa7b"#, 100, #"a\xe2\x80\xa7b"#)  // U+2027
        expectSanitized(#"a\xe2\x80\xafb"#, 100, #"a\xe2\x80\xafb"#)  // U+202F
        expectSanitized(#"a\xe2\x81\xa5b"#, 100, #"a\xe2\x81\xa5b"#)  // U+2065
        expectSanitized(#"a\xe2\x81\xaab"#, 100, #"a\xe2\x81\xaab"#)  // U+206A
        expectSanitized(#"a\xe2\x80\x8db"#, 100, #"a\xe2\x80\x8db"#)  // ZWJ is kept
    }

    // C: /core/text/sanitize-invalid-utf8 (src/core/test-core.c:1385-1409)
    @Test func sanitizeInvalidUTF8() {
        let r = #"\xef\xbf\xbd"#  // U+FFFD
        expectSanitized(#"a\xffb"#, 100, "a\(r)b")
        expectSanitized(#"a\xfeb"#, 100, "a\(r)b")
        expectSanitized(#"a\x80b"#, 100, "a\(r)b")  // lone continuation
        expectSanitized(#"a\xc3"#, 100, "a\(r)")  // truncated 2-byte
        expectSanitized(#"a\xe2\x82"#, 100, "a\(r)\(r)")  // truncated 3-byte
        expectSanitized(#"a\xf0\x9f\x8c"#, 100, "a\(r)\(r)\(r)")  // truncated 4-byte
        expectSanitized(#"\xc0\x80"#, 100, "\(r)\(r)")  // overlong NUL
        expectSanitized(#"\xc1\xbf"#, 100, "\(r)\(r)")  // overlong 0x7f
        expectSanitized(#"\xed\xa0\x80"#, 100, "\(r)\(r)\(r)")  // surrogate D800
        expectSanitized(#"\xf4\x90\x80\x80"#, 100, "\(r)\(r)\(r)\(r)")  // > U+10FFFF
        expectSanitized(#"\xf8\x88\x80\x80\x80"#, 100, #"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"#)  // 5-byte
        // invalid followed by forbidden
        expectSanitized(#"\xff\nx"#, 100, "\(r)x")
    }

    // C: /core/text/sanitize-truncation (src/core/test-core.c:1412-1450)
    @Test func sanitizeTruncation() {
        expectSanitized("abcdef", 3, "abc")
        expectSanitized("abcdef", 6, "abcdef")
        expectSanitized("abcdef", 7, "abcdef")
        expectSanitized("abcdef", 1, "a")
        // never splits a multi-byte character
        expectSanitized(#"\xc3\xa9\xc3\xa9\xc3\xa9"#, 5, #"\xc3\xa9\xc3\xa9"#)
        expectSanitized(#"\xc3\xa9\xc3\xa9\xc3\xa9"#, 6, #"\xc3\xa9\xc3\xa9\xc3\xa9"#)
        expectSanitized(#"\xc3\xa9"#, 1, "")
        expectSanitized(#"\xe6\x9d\xb1\xe4\xba\xac"#, 5, #"\xe6\x9d\xb1"#)
        expectSanitized(#"\xe6\x9d\xb1\xe4\xba\xac"#, 2, "")
        expectSanitized(#"\xf0\x9f\x8c\xa7x"#, 3, "")
        expectSanitized(#"\xf0\x9f\x8c\xa7x"#, 4, #"\xf0\x9f\x8c\xa7"#)
        // the documented empty results: nothing fits in fewer bytes than the first kept character
        expectSanitized(#"\xc3\xa9"#, 1, "")  // 2-byte character
        expectSanitized(#"\xe6\x9d\xb1"#, 2, "")  // 3-byte character
        expectSanitized(#"\xf0\x9f\x8c\xa7"#, 3, "")  // 4-byte character
        expectSanitized(#"\xf0\x9f\x8c\xa7"#, 4, #"\xf0\x9f\x8c\xa7"#)
        expectSanitized(#"\xff"#, 1, "")  // U+FFFD needs 3 bytes
        expectSanitized(#"\xff"#, 2, "")
        expectSanitized(#"\xff"#, 3, #"\xef\xbf\xbd"#)
        expectSanitized(#"\x01\x02\x7f"#, 100, "")  // only forbidden characters
        expectSanitized(#"\xe2\x80\xae\xe2\x80\xac"#, 100, "")
        expectSanitized(#"\x01\xc3\xa9"#, 1, "")  // forbidden first, kept one too big
        expectSanitized(#"a\xc3\xa9"#, 2, "a")
        // stripping happens before counting: forbidden characters use no budget
        expectSanitized(#"a\nb\nc\nd"#, 3, "abc")
        // the replacement character counts as three bytes
        expectSanitized(#"\xff\xff\xff"#, 7, #"\xef\xbf\xbd\xef\xbf\xbd"#)

        // a huge input is cut quickly and exactly (test-core.c:1444-1449)
        let huge = [UInt8](repeating: UInt8(ascii: "x"), count: 5 * 1024 * 1024)
        #expect(WxText.sanitize(bytes: huge, maxBytes: 256).utf8.count == 256)
        #expect(WxText.sanitize(bytes: huge, maxBytes: 0) == "")
    }

    // C: /core/text/sanitize-stops-when-full (src/core/test-core.c:1459-1494). The guard page is
    // replaced by ReadTrackingBytes: an unterminated buffer whose reads are recorded.
    @Test func sanitizeStopsWhenFull() {
        let page = 4096
        // output exactly full, then only forbidden characters (C0 controls) until the end
        var bytes = [UInt8](repeating: 0x01, count: page)
        bytes.replaceSubrange(0..<3, with: Array("abc".utf8))
        var tracked = ReadTrackingBytes(storage: bytes)
        #expect(WxText.sanitize(bytes: tracked, maxBytes: 3) == "abc")
        #expect(tracked.log.maxOffset == 2, "read past the full output")
        #expect(tracked.log.outOfBounds == 0)

        // the next kept character does not fit: stop there, even with forbidden text behind it
        bytes = [UInt8](repeating: 0x01, count: page)
        bytes.replaceSubrange(0..<4, with: cBytes(#"ab\xc3\xa9"#))
        tracked = ReadTrackingBytes(storage: bytes)
        #expect(WxText.sanitize(bytes: tracked, maxBytes: 3) == "ab")
        #expect(tracked.log.maxOffset == 3, "read past the character that does not fit")

        // invalid UTF-8 run behind a full output (each byte would become U+FFFD)
        bytes = [UInt8](repeating: 0xFF, count: page)
        bytes.replaceSubrange(0..<3, with: Array("abc".utf8))
        tracked = ReadTrackingBytes(storage: bytes)
        #expect(WxText.sanitize(bytes: tracked, maxBytes: 3) == "abc")
        #expect(tracked.log.maxOffset == 2)

        // a huge forbidden-only tail still yields the right bytes (linear scan is documented)
        var huge = [UInt8](repeating: 0x01, count: 8 * 1024 * 1024 + 1)
        huge.replaceSubrange(0..<3, with: Array("abc".utf8))
        huge[8 * 1024 * 1024] = 0
        #expect(WxText.sanitize(bytes: huge, maxBytes: 3) == "abc")
    }

    // C: /core/text/sanitize-long-forbidden-run (src/core/test-core.c:3124-3138)
    @Test func sanitizeLongForbiddenRun() {
        let run = 4 * 1024 * 1024
        var s = [UInt8](repeating: 0x01, count: run)
        s.append(contentsOf: Array("abc".utf8) + [0])
        #expect(WxText.sanitize(bytes: s, maxBytes: 3) == "abc")
        // a run of overlong-looking invalid bytes is replaced one by one until the output is full
        s.replaceSubrange(0..<run, with: [UInt8](repeating: 0xFF, count: run))
        #expect(Array(WxText.sanitize(bytes: s, maxBytes: 9).utf8) == cBytes(#"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"#))
    }

    // C: /core/text/legacy-lead-bytes (src/core/test-core.c:2722-2755). guard_place() puts the
    // content right before a guard page; ReadTrackingBytes asserts the same bound.
    @Test(arguments: [
        ([0x61, 0x62, 0x63, 0xFC, 0x80, 0x80, 0x80], 6, #"abc\xef\xbf\xbd"#),
        ([0x61, 0x62, 0x63, 0xF8, 0x80, 0x80, 0x80], 6, #"abc\xef\xbf\xbd"#),
        ([0x61, 0x62, 0x63, 0xF8, 0x80, 0x80, 0x80], 4, "abc"),
        ([0x61, 0x62, 0x63, 0xFC, 0x80, 0x80, 0x80, 0x80], 4, "abc"),
        ([0x61, 0x62, 0x63, 0xFD, 0x80, 0x80, 0x80], 5, "abc"),
        ([0x61, 0x62, 0x63, 0xFE, 0x80, 0x80, 0x80], 6, #"abc\xef\xbf\xbd"#),
        ([0x61, 0x62, 0x63, 0xFF, 0x80, 0x80, 0x80], 3, "abc"),
        ([0x61, 0x62, 0x63, 0xF5, 0x80, 0x80, 0x80], 6, #"abc\xef\xbf\xbd"#),
        ([0x61, 0x62, 0x63, 0xC0, 0x80], 6, #"abc\xef\xbf\xbd"#),
    ] as [([UInt8], Int, String)])
    func legacyLeadBytes(bytes: [UInt8], max: Int, want: String) {
        let tracked = ReadTrackingBytes(storage: bytes)
        #expect(Array(WxText.sanitize(bytes: tracked, maxBytes: max).utf8) == cBytes(want))
        #expect(tracked.log.outOfBounds == 0, "read beyond the content")
        // three characters copied: the lead byte is never read
        let copyTracked = ReadTrackingBytes(storage: bytes)
        #expect(WxText.truncatedCopy(bytes: copyTracked, maxScalars: 3) == "abc")
        #expect(copyTracked.log.maxOffset == 2, "truncatedCopy read the lead byte")
    }

    // C: /core/text/legacy-lead-bytes (src/core/test-core.c:2750-2753)
    @Test func legacyLeadReplacementRereadsContinuations() {
        // the replacement of a legacy lead is exactly U+FFFD and the continuation bytes are re-read
        #expect(
            Array(WxText.sanitize(bytes: cBytes(#"\xfc\x80\x80\x80\x80\x80"#), maxBytes: 100).utf8)
                == cBytes(#"\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"#))
    }

    // C: /core/text/sanitize-fuzz (src/core/test-core.c:1497-1522). GRand is replaced by SeededRNG
    // (seed kept); the C oracles are kept as properties.
    @Test func sanitizeFuzz() {
        var rng = SeededRNG(seed: 20_261_011)
        let interesting: [UInt8] = [0x00, 0x0a, 0x1b, 0x7f, 0x80, 0xc2, 0xc3, 0xe2, 0xe0, 0xed,
                                    0xf0, 0xf4, 0xf8, 0xfe, 0xff, 0x9c, 0x8e, 0xae, 0xa8, UInt8(ascii: "a")]
        for _ in 0..<fuzzIterations(20_000) {
            let len = Int.random(in: 0..<48, using: &rng)
            var buf: [UInt8] = []
            for _ in 0..<len {
                buf.append(Int.random(in: 0..<3, using: &rng) == 0
                    ? UInt8.random(in: 0...255, using: &rng)
                    : interesting[Int.random(in: 0..<interesting.count, using: &rng)])
            }
            buf.append(0)
            let max = Int.random(in: 0..<70, using: &rng)
            let out = WxText.sanitize(bytes: buf, maxBytes: max)
            #expect(out.utf8.count <= max)
            expectUTF8Clean(out)
            // idempotent: sanitising clean text changes nothing
            #expect(WxText.sanitize(out, maxBytes: max) == out)
            // truncated copy: a valid UTF-8 byte prefix of the input
            let tc = WxText.truncatedCopy(bytes: buf, maxScalars: Int.random(in: 0..<20, using: &rng))
            #expect(buf.starts(with: Array(tc.utf8)), "truncatedCopy is not a byte prefix of its input")
        }
    }

    // C: /core/text/usable-name (src/core/test-core.c:1525-1562)
    @Test func usableName() {
        func usable(_ s: String, _ max: Int) -> Bool { WxText.isUsableName(bytes: cBytes(s), maxBytes: max) }
        #expect(usable("Miami", 256))
        #expect(usable("a", 1))
        #expect(usable(#"S\xc3\xa3o Paulo"#, 256))
        #expect(usable(" x ", 256))
        #expect(usable(#"a\xe2\x80\x8db"#, 256))  // ZWJ
        #expect(!WxText.isUsableName(nil, maxBytes: 256))
        #expect(!usable("", 256))
        #expect(!usable("abc", 0))
        #expect(!usable("abc", 2))
        #expect(usable("abc", 3))
        #expect(!usable(#"\xc3\xa9"#, 1))
        #expect(usable(#"\xc3\xa9"#, 2))
        #expect(!usable("   ", 256))
        #expect(!usable(#"\xe3\x80\x80"#, 256))  // ideographic space only
        #expect(!usable(#"a\nb"#, 256))
        #expect(!usable(#"a\x01b"#, 256))
        #expect(!usable(#"a\x7f"#, 256))
        #expect(!usable(#"a\xc2\x9b"#, 256))
        #expect(!usable(#"a\xe2\x80\xae"#, 256))
        #expect(!usable(#"a\xe2\x80\x8e"#, 256))
        #expect(!usable(#"a\xe2\x81\xa9"#, 256))
        #expect(!usable(#"a\xd8\x9c"#, 256))
        #expect(!usable(#"a\xe2\x80\xa9"#, 256))
        #expect(!usable(#"a\xff"#, 256))
        #expect(!usable(#"a\xed\xa0\x80"#, 256))
        #expect(!usable(#"a\xc3"#, 256))
        // unterminated: nothing past max + 1 is read
        let big = ReadTrackingBytes(storage: [UInt8](repeating: UInt8(ascii: "x"), count: 512))
        #expect(!WxText.isUsableName(bytes: big, maxBytes: 256))
        #expect(big.log.maxOffset <= 256, "read more than max + 1 bytes")
        #expect(usable("abc", Int.max))  // max + 1 must not overflow (G_MAXSIZE)
        #expect(WxText.isUsableName(String(repeating: "x", count: 256), maxBytes: 256))
        #expect(!WxText.isUsableName(String(repeating: "x", count: 257), maxBytes: 256))
    }

    // C: /core/text/truncated-copy (src/core/test-core.c:1565-1607)
    @Test func truncatedCopy() {
        func copy(_ s: String, _ n: Int) -> [UInt8] {
            let plain = Array(WxText.truncatedCopy(bytes: cBytes(s), maxScalars: n).utf8)
            let terminated = Array(WxText.truncatedCopy(bytes: cBytes(s) + [0, 0x41], maxScalars: n).utf8)
            #expect(plain == terminated, "NUL-terminated \(s) differs")
            return plain
        }
        #expect(WxText.truncatedCopy("hello world", maxScalars: 5) == "hello")
        #expect(WxText.truncatedCopy("hello", maxScalars: 5) == "hello")
        #expect(WxText.truncatedCopy("hello", maxScalars: 50) == "hello")
        #expect(WxText.truncatedCopy("hello", maxScalars: 0) == "")
        #expect(WxText.truncatedCopy(nil, maxScalars: 5) == "")
        #expect(WxText.truncatedCopy("", maxScalars: 5) == "")
        // characters, not bytes
        #expect(copy(#"\xc3\xa9\xc3\xa9\xc3\xa9"#, 2) == cBytes(#"\xc3\xa9\xc3\xa9"#))
        #expect(copy(#"\xe6\x9d\xb1\xe4\xba\xac\xe9\x83\xbd"#, 1) == cBytes(#"\xe6\x9d\xb1"#))
        #expect(copy(#"\xf0\x9f\x8c\xa7x"#, 1) == cBytes(#"\xf0\x9f\x8c\xa7"#))
        // stops before invalid UTF-8
        #expect(copy(#"ab\xffzz"#, 10) == cBytes("ab"))
        #expect(copy(#"ab\xc3"#, 10) == cBytes("ab"))
        #expect(copy(#"\xff"#, 10) == [])
        #expect(copy(#"ab\xed\xa0\x80cd"#, 10) == cBytes("ab"))  // surrogate
        #expect(copy(#"ab\xf4\x90\x80\x80"#, 10) == cBytes("ab"))  // above U+10FFFF
        #expect(copy(#"ab\xc0\xafcd"#, 10) == cBytes("ab"))  // overlong '/'
        // does not read the whole of a huge string
        let huge = ReadTrackingBytes(storage: [UInt8](repeating: UInt8(ascii: "x"), count: 4 * 1024 * 1024))
        #expect(WxText.truncatedCopy(bytes: huge, maxScalars: 8) == "xxxxxxxx")
        #expect(huge.log.maxOffset == 7)
    }

    // Executor-added (CX1): the hard-coded classification of WxText (GLib g_unichar_type /
    // g_unichar_isspace semantics) agrees with the platform's Unicode tables for every scalar.
    @Test func classificationMatchesUnicodeProperties() {
        let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                 0x2066, 0x2067, 0x2068, 0x2069]
        var mismatches: [String] = []
        for v in UInt32(0)...0x10FFFF {
            guard let c = Unicode.Scalar(v) else { continue }
            let cat = c.properties.generalCategory
            let forbidden = cat == .control || cat == .lineSeparator || cat == .paragraphSeparator || bidi.contains(v)
            let space = [0x09, 0x0A, 0x0D, 0x0C].contains(v)
                || cat == .spaceSeparator || cat == .lineSeparator || cat == .paragraphSeparator
            if WxText.isForbidden(c) != forbidden || WxText.isSpace(c) != space {
                mismatches.append(String(v, radix: 16))
            }
        }
        #expect(mismatches.isEmpty, "classification differs at U+\(mismatches.prefix(10))")
    }

    // Executor-added (CX1): a String input ends at an embedded U+0000 exactly like the C string.
    @Test func stringInputEndsAtNUL() {
        #expect(WxText.sanitize("ab\u{0}cd", maxBytes: 100) == "ab")
        #expect(WxText.truncatedCopy("ab\u{0}cd", maxScalars: 100) == "ab")
        #expect(WxText.isUsableName("ab\u{0}cd", maxBytes: 2))
    }
}
