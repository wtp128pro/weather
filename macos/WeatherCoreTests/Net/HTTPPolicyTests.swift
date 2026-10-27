// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HTTPPolicyTests.swift - ports of the pure/ group and the policy parts of the net/ group of
// src/net/test-http.c. Expected values are the C test's literals, cited as path:line.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct HTTPPolicyTests {
    /// src/net/test-http.c:34
    static let ua = "weather-app/0.1 (github.com/wtp128pro/weather)"
    /// src/net/test-http.c:35
    static let jsonAccept = "application/json"

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: /http/pure/constants

    @Test("/http/pure/constants") // C: /http/pure/constants (src/net/test-http.c:1488-1497)
    func constants() {
        #expect(HTTPPolicy.timeoutMs == 10000)
        #expect(HTTPPolicy.totalDeadlineMs == 45000)
        #expect(HTTPPolicy.backoffBaseMs == 1000)
        #expect(HTTPPolicy.maxRetries == 2)
        #expect(HTTPPolicy.maxBodyBytes == 4 * 1024 * 1024)
        #expect(HTTPPolicy.maxInflight == 16)
        #expect(HTTPPolicy.readChunk == 16384)
        // src/net/test-http.c:1261
        #expect(HTTPPolicy.pathMax == 2048)
        // net-providers.md:46 / wx-http.h:290-292 and the project User-Agent (src/net/test-http.c:34)
        #expect(HTTPPolicy.headerValueMax == 200)
        #expect(HTTPPolicy.validatorMax == 64)
        #expect(HTTPPolicy.userAgent == Self.ua)
        #expect(HTTPPolicy.acceptEncoding == "gzip")
        #expect(HTTPPolicy.Message.tooManyOutstanding == "too many outstanding requests (limit 16)")
    }

    // MARK: /http/pure/path-validation

    @Test("/http/pure/path-validation lists") // C: /http/pure/path-validation (src/net/test-http.c:1237-1249)
    func pathValidationLists() {
        let accepted = ["/", "/a", "/v1/forecast?latitude=25.7617&longitude=-80.1918&x=a,b;c",
                        "/a%20b?c=d%26e", "/a/b/c/", "/?x", "/..", "/a/../b",
                        "/!$&'()*+,;=:@~._-", "/\"<>[]{}|^`"]
        for path in accepted {
            #expect(HTTPPolicy.isValidPath(path), "accepted: \(path)")
        }
        let rejected: [[UInt8]] = [
            Self.bytes(""), Self.bytes("a"), Self.bytes("?x"), Self.bytes("x/y"), Self.bytes("//"),
            Self.bytes("//x"), Self.bytes("//x/y"), Self.bytes("/a b"), Self.bytes("/a#b"), Self.bytes("/#"),
            [0x2F, 0x61, 0x5C, 0x62], [0x5C], Self.bytes("/ "), Self.bytes(" /"), [0x2F, 0x61, 0x09, 0x62],
            [0x2F, 0x61, 0x0A, 0x62], [0x2F, 0x61, 0x0D, 0x62], Self.bytes("/a\r\nHost: evil"), [0x2F, 0x7F],
            [0x2F, 0xC3, 0xA9], [0x2F, 0x80], [0x2F, 0xFF], Self.bytes("http://evil/"),
            [0x2F, 0x61, 0x01], [0x2F, 0x1F], Self.bytes("@evil.com/"),
        ]
        for path in rejected {
            #expect(!HTTPPolicy.isValidPath(bytes: path), "rejected: \(path)")
        }
        #expect(!HTTPPolicy.isValidPath(nil))
    }

    @Test("/http/pure/path-validation every byte") // C: /http/pure/path-validation (src/net/test-http.c:1251-1258)
    func pathValidationEveryByte() {
        for b in 1..<256 {
            let byte = UInt8(b)
            let expect = b > 0x20 && b < 0x7F && b != 0x23 && b != 0x5C
            #expect(HTTPPolicy.isValidPath(bytes: [0x2F, 0x61, byte, 0]) == expect, "byte \(b) after /a")
            #expect(HTTPPolicy.isValidPath(bytes: [0x2F, byte, 0]) == (expect && b != 0x2F), "byte \(b) after /")
        }
    }

    @Test("/http/pure/path-validation length") // C: /http/pure/path-validation (src/net/test-http.c:1260-1270)
    func pathValidationLength() {
        var max = [UInt8](repeating: 0x61, count: 2048)
        max[0] = 0x2F
        #expect(HTTPPolicy.isValidPath(bytes: max + [0]))
        #expect(!HTTPPolicy.isValidPath(bytes: max + [0x61, 0]))
        #expect(!HTTPPolicy.isValidPath(bytes: [0x2F] + [UInt8](repeating: 0x61, count: 64) + [0x01]))
    }

    // MARK: /http/pure/path-validation-guard-page (behavioural part: the read bound)

    @Test("/http/pure/path-validation-guard-page read bound") // C: /http/pure/path-validation-guard-page (src/net/test-http.c:1275-1303)
    func pathValidationReadBound() {
        for b in 0..<256 {
            var window = [UInt8](repeating: 0x61, count: 2048 + 1)
            window[0] = b == 0 ? 0x62 : UInt8(b)
            #expect(!HTTPPolicy.isValidPath(bytes: window), "unterminated window, first byte \(b)")
            window[0] = 0x2F
            #expect(!HTTPPolicy.isValidPath(bytes: window), "unterminated 2049-byte path")
        }
        var terminated = [UInt8](repeating: 0x61, count: 2048 + 1)
        terminated[0] = 0x2F
        terminated[2048] = 0
        #expect(HTTPPolicy.isValidPath(bytes: terminated))
        for n in 1..<40 {
            var s = [UInt8](repeating: 0x78, count: n + 1)
            s[0] = 0x2F
            s[n] = 0
            #expect(HTTPPolicy.isValidPath(bytes: s), "short path of \(n) bytes")
        }
    }

    // MARK: /http/pure/parse-expires

    /// 1994-11-06T08:49:37Z (src/net/test-http.c:1306-1307).
    static let exampleDateS: Int64 = 784111777

    @Test("/http/pure/parse-expires formats and window") // C: /http/pure/parse-expires (src/net/test-http.c:1312-1335)
    func parseExpiresFormatsAndWindow() {
        let t = Self.exampleDateS
        let rfc1123 = "Sun, 06 Nov 1994 08:49:37 GMT"
        let rfc850 = "Sunday, 06-Nov-94 08:49:37 GMT"
        let asctime = "Sun Nov  6 08:49:37 1994"
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t - 1) == t)
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t - 3600) == t)
        #expect(HTTPPolicy.parseExpires(rfc850, nowS: t - 1) == t)
        #expect(HTTPPolicy.parseExpires(asctime, nowS: t - 1) == t)
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t + 1) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t + 86400) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t - 86400) == t)
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t - 86401) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: t - 86399) == t)
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: Int64.min) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: Int64.max) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: Int64.min + 1) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: Int64.max - 1) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: 0) == Int64(0))
        #expect(HTTPPolicy.parseExpires(rfc1123, nowS: -1) == Int64(0))
    }

    @Test("/http/pure/parse-expires garbage and bounds") // C: /http/pure/parse-expires (src/net/test-http.c:1336-1370)
    func parseExpiresGarbageAndBounds() {
        let t = Self.exampleDateS
        #expect(HTTPPolicy.parseExpires(nil, nowS: t - 1) == Int64(0))
        let garbage: [[UInt8]] = [
            Self.bytes(""), Self.bytes(" "), Self.bytes("0"), Self.bytes("-1"), Self.bytes("99999999999999999999"),
            Self.bytes("now"), Self.bytes("Sun, 32 Nov 1994 08:49:37 GMT"), Self.bytes("Sun, 06 Nov 1994 25:49:37 GMT"),
            Self.bytes("Sun, 06 Foo 1994 08:49:37 GMT"), [0x01, 0x02],
            Self.bytes("Sun, 06 Nov 1994 08:49:37 GMT garbage that is far too long to be a date but < 64"),
            [0xFF, 0xFE], Self.bytes("Sun, 06 Nov 1994"),
        ]
        for value in garbage {
            #expect(HTTPPolicy.parseExpires(bytes: value, nowS: t - 1) == Int64(0), "garbage \(value)")
        }
        let rfc1123 = Self.bytes("Sun, 06 Nov 1994 08:49:37 GMT")
        // Longer than 64 bytes: refused even if it starts like a date (:1342-1346).
        var padded = [UInt8](repeating: 0x20, count: 64 + 1)
        padded.replaceSubrange(0..<rfc1123.count, with: rfc1123)
        #expect(HTTPPolicy.parseExpires(bytes: padded + [0], nowS: t - 1) == Int64(0))
        // The bound is a read bound as well (:1348-1354): 65 bytes without a terminator.
        var window = [UInt8](repeating: 0x78, count: 64 + 1)
        #expect(HTTPPolicy.parseExpires(bytes: window, nowS: t - 1) == Int64(0))
        window.replaceSubrange(0..<rfc1123.count, with: rfc1123)
        #expect(HTTPPolicy.parseExpires(bytes: window, nowS: t - 1) == Int64(0))
        // 64 bytes + NUL must not fault; the result is the parser's call (:1356-1361).
        var exact = [UInt8](repeating: 0x20, count: 64 + 1)
        exact.replaceSubrange(0..<rfc1123.count, with: rfc1123)
        exact[64] = 0
        _ = HTTPPolicy.parseExpires(bytes: exact, nowS: t - 1)
        for n in 1..<40 {
            var s = [UInt8](repeating: 0x78, count: n + 1)
            s[n] = 0
            #expect(HTTPPolicy.parseExpires(bytes: s, nowS: t - 1) == Int64(0), "\(n) x bytes")
        }
    }

    // MARK: /http/pure/parse-expires (libsoup quirks)

    /// The C test defers to libsoup for every other text ("the result is the parser's call",
    /// src/net/test-http.c:1356-1361). Expected values come from the C ORACLE, not from the Swift
    /// code: libsoup 3.6.6 libsoup/soup-date-utils.c:123-342 copied verbatim, with
    /// src/net/wx-http.c:101-114 (wx_http_parse_expires) verbatim, compiled against Homebrew
    /// GLib 2.90.1 (scratch harness u09i2/h/c_harness, inputs in_pin.txt, outputs c_pin.out).
    /// Each row: value, raw soup_date_time_new_from_http_string -> g_date_time_to_unix (nil =
    /// NULL), and wx_http_parse_expires(value, 784111776).
    static let libsoupQuirks: [(String, Int64?, Int64)] = [
        // US zones: -60 * (5 * strcspn("ECMP", rest)) minutes, +60 for 'D' (soup-date-utils.c:238).
        ("Sun, 06 Nov 1994 08:49:37 EST", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 EDT", 784108177, 0),
        ("Sun, 06 Nov 1994 08:49:37 CST", 784129777, 784129777),
        ("Sun, 06 Nov 1994 08:49:37 CDT", 784126177, 784126177),
        ("Sun, 06 Nov 1994 08:49:37 MST", 784147777, 784147777),
        ("Sun, 06 Nov 1994 08:49:37 MDT", 784144177, 784144177),
        ("Sun, 06 Nov 1994 08:49:37 PST", 784165777, 784165777),
        ("Sun, 06 Nov 1994 08:49:37 PDT", 784162177, 784162177),
        ("Sun, 06 Nov 1994 08:49:37 PST EXTRA", 784111777, 784111777),
        ("Sun Nov  6 08:49:37 1994 PST", 784165777, 784165777),
        // The JFMASOND gate (soup-date-utils.c:336-339).
        ("06 nov 1994 08:49:37 GMT", 784111777, 784111777),
        ("06 nov 1994 08:49:37", nil, 0),
        ("06 nov 1994 08:49:37 utc", nil, 0),
        ("23 feb 2015 21:34:38", nil, 0),
        // parse_year: 1...9998 (soup-date-utils.c:175).
        ("Fri, 31 Dec 9999 23:59:59 GMT", nil, 0),
        ("Fri, 31 Dec 9998 23:59:59 GMT", 253370764799, 0),
        // Numeric zones: strtoul, > 9999 or a colon part > 99 is no zone, |offset| > 24:59 is UTC.
        ("Sun, 06 Nov 1994 08:49:37 +2500", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 +12345", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 +2459", 784021837, 0),
        ("Sun, 06 Nov 1994 08:49:37 +1500", 784057777, 0),
        ("Sun, 06 Nov 1994 08:49:37 -2500", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 + 0100", 784108177, 0),
        ("Sun, 06 Nov 1994 08:49:37 ++1", 784111717, 0),
        ("Sun, 06 Nov 1994 08:49:37 +-1", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 +01:00", 784108177, 0),
        ("Sun, 06 Nov 1994 08:49:37 +99:99", 784111777, 784111777),
        ("Sun, 06 Nov 1994 08:49:37 +100:00", 784111777, 784111777),
        // g_ascii_isspace skips TAB but not VT (soup-date-utils.c:325-326).
        ("\u{0B}Sun, 06 Nov 1994 08:49:37 GMT", nil, 0),
        ("\tSun, 06 Nov 1994 08:49:37 GMT", 784111777, 784111777),
        // Range and calendar checks.
        ("Sun, 00 Nov 1994 08:49:37 GMT", nil, 0),
        ("Sun, 06 Nov 1994 08:49:60 GMT", nil, 0),
        ("Sun, 29 Feb 1900 08:49:37 GMT", nil, 0),
        ("Tue, 29 Feb 2000 08:49:37 GMT", 951814177, 0),
        // Two-digit and three-digit years.
        ("Sun, 06 Nov 94 08:49:37 GMT", 784111777, 784111777),
        ("Sun, 06 Nov 069 08:49:37 GMT", -4806623, 0),
    ]

    @Test("/http/pure/parse-expires libsoup quirks (C oracle)") // C: /http/pure/parse-expires (src/net/test-http.c:1356-1361)
    func parseExpiresLibsoupQuirks() {
        #expect(Self.libsoupQuirks.count == 35)
        for (value, raw, windowed) in Self.libsoupQuirks {
            #expect(HTTPPolicy.HTTPDate.parse(Array(value.utf8)) == raw, "raw \(value.debugDescription)")
            #expect(HTTPPolicy.parseExpires(value, nowS: 784111776) == windowed, "windowed \(value.debugDescription)")
        }
        // The VT row really carries the 0x0B byte.
        #expect(Array(Self.libsoupQuirks[27].0.utf8.prefix(1)) == [0x0B])
    }

    // MARK: /http/pure/parse-expires-window

    @Test("/http/pure/parse-expires-window") // C: /http/pure/parse-expires-window (src/net/test-http.c:1373-1385)
    func parseExpiresWindowProperty() {
        // GRand seed 7 becomes SeededRNG seed 7 (DECISIONS: C fuzz tests keep their oracles).
        var rng = SeededRNG(seed: 7)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for _ in 0..<fuzzIterations(20000) {
            let t = Int64.random(in: 946684800..<2000000000, using: &rng)
            let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
            let now = t + Int64.random(in: -100000..<100000, using: &rng)
            let expect: Int64 = (t > now && t - now <= 86400) ? t : 0
            #expect(HTTPPolicy.parseExpires(text, nowS: now) == expect, "\(text) now \(now)")
        }
    }

    // MARK: /http/pure/constructor-policy

    @Test("/http/pure/constructor-policy rejected base URLs") // C: /http/pure/constructor-policy (src/net/test-http.c:1391-1415)
    func constructorRejectsBaseURLs() {
        let rejected: [[UInt8]] = [
            "http://api.met.no", "http://example.com:8080", "ftp://127.0.0.1", "https://api.met.no/path",
            "https://api.met.no/x/", "https://user@api.met.no", "https://user:pw@api.met.no",
            "https://:@api.met.no", "https://api.met.no?x=1", "https://api.met.no?", "https://api.met.no#f",
            "https://api.met.no#", "api.met.no", "//api.met.no", "http://127.0.0.1.evil.com", "http://localhost.evil.com",
            "http://127.0.0.2", "http://127.1", "http://0x7f.1", "http://2130706433", "http://0.0.0.0",
            "http://[::2]", "http://[::ffff:127.0.0.1]", "http://", "https://", "https:///x", "file:///etc/passwd",
            "javascript:alert(1)", "", " ", " https://api.met.no", "https://api.met.no ", "https://a b.com",
            "https://api.met.no\\@evil.com", "https://api.met.no%2Fx", "https://api.met.no:0", "https://api.met.no:65536",
            "https://api.met.no:99999999999", "https://api.met.no:abc", "https://exa%6dple.com%2f", "https://-",
            "https://[fe80::1%25eth0]", "http://localhost@evil.com", "http://127.0.0.1@evil.com",
            "https://api.met.no/\n", "https://api.met.no\r\n", "https://api.met.no/%00",
        ].map(Self.bytes) + [[0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F, 0xC3, 0xA9, 0x2E, 0x63, 0x6F, 0x6D, 0x01]] + [
            "https://api.met.no//", "https://api.met.no/x/..//", "https://api.met.no.",
            "https://.api.met.no", "https://api..met.no", "https://api-.met.no", "https://-api.met.no",
            "https://api.met.no-", "https://a_b.com", "https://[::1]x", "https://[xyz::1]",
        ].map(Self.bytes)
        #expect(rejected.count == 59) // the 59 literals of :1391-1415
        for url in rejected {
            do {
                _ = try HTTPClientPolicy(baseURLBytes: url, userAgentBytes: Self.bytes(Self.ua), timeoutMs: 1000,
                                         backoffBaseMs: 0, minGapMs: 0)
                Issue.record("accepted base URL \(String(decoding: url, as: UTF8.self))")
            } catch {
                #expect(error.code == .invalidArg)
                #expect(!error.message.contains("evil"))
            }
            #expect(HTTPPolicy.normaliseBaseURL(bytes: url) == nil)
        }
    }

    @Test("/http/pure/constructor-policy accepted base URLs") // C: /http/pure/constructor-policy (src/net/test-http.c:1425-1438)
    func constructorAcceptsBaseURLs() throws {
        let accepted: [[UInt8]] = [
            "https://api.met.no", "https://api.met.no/", "HTTPS://API.MET.NO", "https://api.met.no:443",
            "https://api.met.no:8443/", "http://127.0.0.1:8080", "http://localhost", "http://LOCALHOST:9/",
            "http://[::1]:9/", "http://[::1]", "https://api.open-meteo.com", "https://geocoding-api.open-meteo.com",
            "https://1.2.3.4", "https://[2001:db8::1]:443", "https://%61pi.met.no", "https://xn--n-nga1b.com",
        ].map(Self.bytes) + [[0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F, 0xC3, 0xBC, 0x6E, 0xC3, 0xAF, 0x2E, 0x63, 0x6F, 0x6D]] + [
            "http://%6C%6F%63alhost", "https://api.met.no:", "https://api.met.no/.", "https://api.met.no/./",
        ].map(Self.bytes)
        #expect(accepted.count == 21)
        for url in accepted {
            #expect(throws: Never.self, "\(String(decoding: url, as: UTF8.self))") {
                _ = try HTTPClientPolicy(baseURLBytes: url, userAgentBytes: Self.bytes(Self.ua), timeoutMs: 1000,
                                         backoffBaseMs: 0, minGapMs: 0)
            }
        }
        // wx_http_new with the default timing (:1439-1440).
        let def = try HTTPClientPolicy(baseURL: "https://api.met.no", userAgent: Self.ua)
        #expect(def.timeoutMs == 10000)
        #expect(def.backoffBaseMs == 1000)
        #expect(def.minGapMs == 0)
    }

    @Test("/http/pure/constructor-policy IDN hosts (GLib oracle)") // C: /http/pure/constructor-policy (src/net/test-http.c:1425-1438)
    func constructorIDNHosts() {
        // Expected origins from the GLib oracle (verbatim wx-http.c normalise_base_url over real
        // g_uri_parse / g_hostname_to_ascii, Homebrew GLib 2.90.1; u09i2/h/c_pin2.out).
        let softHyphen: [UInt8] = [0xC2, 0xAD]
        let cases: [([UInt8], String?)] = [
            (Self.bytes("https://\u{E000}.com"), nil),                       // private use is prohibited
            (Self.bytes("https://a%EF%BC%8E"), "https://a"),                  // NFKC dot, trailing dot dropped
            (Self.bytes("https://\u{1F88}.com"), "https://xn--8qg.com"),      // Lt alone is not lower-cased
            (Self.bytes("https://\u{03A3}\u{038A}\u{03A3}\u{03A5}\u{03A6}\u{039F}\u{03A3}.gr"),
             "https://xn--kxa6ajbbmh.gr"),                                     // final sigma
            (Self.bytes("https://a\u{00A0}b.gr"), nil),                       // Zs is prohibited
            (Self.bytes("https://a\u{200B}b.com"), "https://ab.com"),          // junk removed
            (Self.bytes("https://") + Array(repeating: softHyphen, count: 600).flatMap { $0 } + Self.bytes("a.com"), nil),
            (Self.bytes("https://") + Array(repeating: softHyphen, count: 500).flatMap { $0 } + Self.bytes("a.com"),
             "https://a.com"),                                                 // 1005 bytes: under the 4*255 gate
            (Self.bytes("https://B\u{00FC}cher.de"), "https://xn--bcher-kva.de"),
            (Self.bytes("https://\u{FF21}.com"), "https://a.com"),
            (Self.bytes("https://xn--a\u{00FC}.com"), nil),
            (Self.bytes("https://\u{0130}x.com"), "https://xn--ix-rub.com"),
        ]
        for (url, origin) in cases {
            #expect(HTTPPolicy.normaliseBaseURL(bytes: url) == origin, "\(String(decoding: url, as: UTF8.self))")
        }
    }

    @Test("/http/pure/constructor-policy host lengths") // C: /http/pure/constructor-policy (src/net/test-http.c:1442-1460)
    func constructorHostLengths() {
        let label63 = String(repeating: "a", count: 63)
        let label64 = String(repeating: "a", count: 64)
        let host253 = [label63, label63, label63, String(repeating: "a", count: 61)].joined(separator: ".")
        let host254 = [label63, label63, label63, String(repeating: "a", count: 62)].joined(separator: ".")
        #expect(host253.utf8.count == 253)
        #expect(host254.utf8.count == 254)
        let hosts: [(String, Bool)] = [(label63, true), (label64, false), (host253, true), (host254, false)]
        for (host, accepted) in hosts {
            let made = (try? HTTPClientPolicy(baseURL: "https://" + host, userAgent: Self.ua, timeoutMs: 1000,
                                              backoffBaseMs: 0, minGapMs: 0)) != nil
            #expect(made == accepted, "host of \(host.utf8.count) bytes")
        }
    }

    @Test("/http/pure/constructor-policy User-Agent") // C: /http/pure/constructor-policy (src/net/test-http.c:1462-1475)
    func constructorUserAgent() {
        let ua201 = Self.bytes(String(repeating: "a", count: 201))
        let bad: [[UInt8]] = [Self.bytes(""), Self.bytes("ua\r\nX-Evil: 1"), Self.bytes("ua\n"), Self.bytes("ua\t"),
                              [0x75, 0x61, 0x01], [0x75, 0x61, 0x7F], [0x75, 0x61, 0xC3, 0xA9], [0xFF], ua201]
        for ua in bad {
            do {
                _ = try HTTPClientPolicy(baseURLBytes: Self.bytes("https://api.met.no"), userAgentBytes: ua,
                                         timeoutMs: 1000, backoffBaseMs: 0, minGapMs: 0)
                Issue.record("accepted User-Agent \(ua)")
            } catch {
                #expect(error.code == .invalidArg)
                #expect(error.message.contains("User-Agent"))
            }
        }
        #expect(throws: Never.self) {
            _ = try HTTPClientPolicy(baseURL: "https://api.met.no", userAgent: String(repeating: "a", count: 200))
        }
        #expect(throws: Never.self) {
            _ = try HTTPClientPolicy(baseURL: "https://api.met.no", userAgent: " weather app ~!")
        }
    }

    @Test("/http/pure/constructor-policy timing ranges") // C: /http/pure/constructor-policy (src/net/test-http.c:1477-1485)
    func constructorTimingRanges() {
        // The C criticals (timeout 0 or 600001, back-off 600001, gap 600001) are thrown INVALID_ARG here.
        let bad: [(Int, Int, Int)] = [(0, 0, 0), (600001, 0, 0), (1000, 600001, 0), (1000, 0, 600001)]
        for (timeout, backoff, gap) in bad {
            #expect(throws: WxError.self) {
                _ = try HTTPClientPolicy(baseURL: "https://a.b", userAgent: Self.ua, timeoutMs: timeout,
                                         backoffBaseMs: backoff, minGapMs: gap)
            }
        }
        #expect(throws: Never.self) {
            _ = try HTTPClientPolicy(baseURL: "https://a.b", userAgent: Self.ua, timeoutMs: 1, backoffBaseMs: 0, minGapMs: 0)
        }
        #expect(throws: Never.self) {
            _ = try HTTPClientPolicy(baseURL: "https://a.b", userAgent: Self.ua, timeoutMs: 600000,
                                     backoffBaseMs: 600000, minGapMs: 600000)
        }
    }

    // MARK: /http/net/base-url-normalisation (policy part: the pinned origin)

    @Test("/http/net/base-url-normalisation origin") // C: /http/net/base-url-normalisation (src/net/test-http.c:4715-4729)
    func baseURLNormalisation() throws {
        let port = 8080
        let forms: [(String, String)] = [("http://LOCALHOST:", ""), ("http://localhost:", "/"), ("HTTP://127.0.0.1:", ""),
                                         ("http://%6C%6F%63alhost:", "")]
        for (index, (prefix, suffix)) in forms.enumerated() {
            let client = try HTTPClientPolicy(baseURL: "\(prefix)\(port)\(suffix)", userAgent: Self.ua, timeoutMs: 2000,
                                              backoffBaseMs: 5, minGapMs: 0)
            let host = index == 2 ? "127.0.0.1" : "localhost"
            #expect(client.origin == "http://\(host):\(port)")
            let plan = try client.plan(pathAndQuery: "/n", accept: Self.jsonAccept)
            #expect(URL(string: plan.url)?.host == host)
            #expect(URL(string: plan.url)?.port == port)
        }
    }

    // MARK: /http/net/success-request-shape (policy part: the header set)

    @Test("/http/net/success-request-shape headers") // C: /http/net/success-request-shape (src/net/test-http.c:1987-2025)
    func requestShapeHeaders() throws {
        let client = try HTTPClientPolicy(baseURL: "http://127.0.0.1:8080", userAgent: Self.ua)
        let plan = try client.plan(pathAndQuery: "/v1/forecast?latitude=25.7617&longitude=-80.1918", accept: Self.jsonAccept)
        #expect(plan.target == "/v1/forecast?latitude=25.7617&longitude=-80.1918")
        #expect(plan.url == "http://127.0.0.1:8080/v1/forecast?latitude=25.7617&longitude=-80.1918")
        let allowed: Set<String> = ["host", "user-agent", "accept", "accept-encoding", "connection"] // :2005-2006
        #expect(HTTPPolicy.allowedRequestHeaderNames == allowed)
        for field in plan.headers {
            #expect(allowed.contains(field.name.lowercased()), "unexpected header \(field.name)")
        }
        #expect(plan.headers.first { $0.name.lowercased() == "user-agent" }?.value == Self.ua)
        #expect(plan.headers.first { $0.name.lowercased() == "accept" }?.value == Self.jsonAccept)
        #expect(plan.headers.first { $0.name.lowercased() == "accept-encoding" }?.value == "gzip")
        #expect(!plan.sendsIfModifiedSince)
        let head = plan.headers.map { "\($0.name): \($0.value)\r\n" }.joined()
        // The public list is exactly the C literal list of :2022-2023.
        #expect(HTTPPolicy.forbiddenRequestHeadTexts == ["Cookie", "Authorization", "Referer", "Origin", "Mozilla",
                                                         "If-Modified-Since", "Proxy-Authorization", "X-"])
        for forbidden in HTTPPolicy.forbiddenRequestHeadTexts {
            #expect(!head.contains(forbidden), "head contains \(forbidden)")
        }
        // The transport rules U13 must apply: no redirects, cookies, credentials or URL cache.
        #expect(!HTTPPolicy.TransportRules.followsRedirects)
        #expect(!HTTPPolicy.TransportRules.sendsCookies)
        #expect(!HTTPPolicy.TransportRules.usesURLCache)
        #expect(!HTTPPolicy.TransportRules.sendsCredentials)
        // With a validator, If-Modified-Since is the one extra header (wx-http.c:1582-1583).
        let ims = try client.plan(pathAndQuery: "/x", accept: Self.jsonAccept, ifModifiedSince: "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(ims.headers.map(\.name) == ["User-Agent", "Accept", "Accept-Encoding", "If-Modified-Since"])
        #expect(ims.sendsIfModifiedSince)
    }

    // MARK: /http/net/invalid-args

    @Test("/http/net/invalid-args") // C: /http/net/invalid-args (src/net/test-http.c:2032-2099)
    func invalidArguments() throws {
        let client = try HTTPClientPolicy(baseURL: "http://127.0.0.1:8080", userAgent: Self.ua, timeoutMs: 2000,
                                          backoffBaseMs: 10, minGapMs: 0)
        let json = Self.bytes(Self.jsonAccept)
        let cases: [([UInt8], [UInt8], [UInt8]?)] = [
            (Self.bytes("//x"), json, nil), (Self.bytes("/a b"), json, nil), (Self.bytes("/a#b"), json, nil),
            ([0x2F, 0x61, 0x01], json, nil), (Self.bytes("/a\r\nHost: evil"), json, nil), (Self.bytes(""), json, nil),
            (Self.bytes("relative"), json, nil), (Self.bytes("/a%zz"), json, nil), (Self.bytes("/a%"), json, nil),
            (Self.bytes("/ok"), Self.bytes(""), nil), (Self.bytes("/ok"), Self.bytes("application/json\r\nCookie: x=1"), nil),
            (Self.bytes("/ok"), Self.bytes("application/json\n"), nil), (Self.bytes("/ok"), Self.bytes("application/") + [0xC3, 0xA9], nil),
            (Self.bytes("/ok"), json, Self.bytes("")), (Self.bytes("/ok"), json, Self.bytes("Sun, 06 Nov 1994 08:49:37 GMT\r\nX: y")),
            (Self.bytes("/ok"), json, [0xC3, 0xA9]),
        ]
        var longPath = [UInt8](repeating: 0x61, count: 2048 + 1)
        longPath[0] = 0x2F
        let long: [([UInt8], [UInt8], [UInt8]?)] = [
            (longPath, json, nil), (Self.bytes("/ok"), [UInt8](repeating: 0x61, count: 200 + 1), nil),
            (Self.bytes("/ok"), json, [UInt8](repeating: 0x61, count: 64 + 1)),
        ]
        for (path, accept, ims) in cases + long {
            do {
                _ = try client.plan(pathAndQueryBytes: path, acceptBytes: accept, ifModifiedSinceBytes: ims)
                Issue.record("planned \(path) / \(accept) / \(String(describing: ims))")
            } catch {
                #expect(error.code == .invalidArg)
                #expect(!error.message.contains("evil"))
                #expect(!error.message.contains("Cookie"))
            }
        }
        var maxPath = [UInt8](repeating: 0x61, count: 2048)
        maxPath[0] = 0x2F
        #expect(throws: Never.self) {
            _ = try client.plan(pathAndQueryBytes: maxPath, acceptBytes: [UInt8](repeating: 0x61, count: 200),
                                ifModifiedSinceBytes: [UInt8](repeating: 0x61, count: 64))
        }
    }

    // MARK: /http/net/status-mapping (policy part: verdict and number of requests)

    /// Requests a failure costs under the retry table: 1 + the retries shouldRetry allows.
    private static func requests(_ code: WxError.Code, status: Int) -> Int {
        var attempt = 0
        while HTTPPolicy.shouldRetry(code, httpStatus: status, attempt: attempt, totalDeadlineExpired: false) {
            attempt += 1
        }
        return attempt + 1
    }

    @Test("/http/net/status-mapping") // C: /http/net/status-mapping (src/net/test-http.c:2190-2224)
    func statusMapping() {
        let cases: [(Int, WxError.Code, Int)] = [
            (404, .notFound, 1), (429, .rateLimited, 1), (400, .http, 1), (401, .http, 1), (403, .http, 1),
            (410, .http, 1), (422, .http, 1), (301, .http, 1), (302, .http, 1), (307, .http, 1), (304, .http, 1),
            (600, .http, 1), (999, .http, 1), (500, .http, 1 + 2), (503, .http, 1 + 2), (599, .http, 1 + 2),
        ]
        for (status, code, requests) in cases {
            guard case .failure(let error) = HTTPPolicy.classify(status: status, sentIfModifiedSince: false) else {
                Issue.record("status \(status) was a success")
                continue
            }
            #expect(error.code == code, "status \(status)")
            #expect(Self.requests(error.code, status: status) == requests, "status \(status)")
        }
        // STEP_CLOSE: a closed connection is NETWORK, retried twice (:2211).
        #expect(Self.requests(.network, status: 0) == 1 + 2)
        for status in [200, 201, 202, 204, 206, 299] { // :2213
            #expect(HTTPPolicy.classify(status: status, sentIfModifiedSince: false) == .success, "status \(status)")
        }
    }

    @Test("/http/net/status-mapping phrases") // C: /http/net/status-mapping (src/net/wx-http.c:665)
    func statusPhrases() {
        // "HTTP %u %s" with soup_status_get_phrase (wx-http.c:665); the phrases are libsoup 3.6.6
        // libsoup/soup-status.c:150-210, which lists 103 and has no 421 entry.
        #expect(HTTPPolicy.statusError(421).message == "HTTP 421 Unknown Error")
        #expect(HTTPPolicy.statusError(421).code == .http)
        #expect(HTTPPolicy.statusPhrase(103) == "Early Hints")
        #expect(HTTPPolicy.statusError(500).message == "HTTP 500 Internal Server Error")
        #expect(HTTPPolicy.statusError(503).message == "HTTP 503 Service Unavailable")
        #expect(HTTPPolicy.statusError(308).message == "HTTP 308 Permanent Redirect")
        #expect(HTTPPolicy.statusError(418).message == "HTTP 418 Unknown Error")
        #expect(HTTPPolicy.statusError(429).message == "HTTP 429: rate limited") // wx-http.c:662
        #expect(HTTPPolicy.statusError(404).message == "HTTP 404: not found") // wx-http.c:664
        let listed = (100..<600).filter { HTTPPolicy.statusPhrase($0) != "Unknown Error" }
        #expect(listed.count == 49) // the 49 entries of reason_phrases[]
    }

    @Test("/http/net/if-modified-since-304 verdict") // C: /http/net/if-modified-since-304 (wx-http.h:36-38)
    func notModifiedVerdict() {
        #expect(HTTPPolicy.classify(status: 304, sentIfModifiedSince: true) == .success)
        guard case .failure(let error) = HTTPPolicy.classify(status: 304, sentIfModifiedSince: false) else {
            Issue.record("304 without If-Modified-Since was a success")
            return
        }
        #expect(error.code == .http)
    }

    // MARK: /http/net/retry-backoff, /http/net/backoff-doubles (policy part: the table)

    @Test("/http/net/backoff-doubles table") // C: /http/net/backoff-doubles, /http/net/retry-backoff (wx-http.h:31-35)
    func backoffTable() throws {
        // "waiting backoff, 2 * backoff" with WX_HTTP_BACKOFF_BASE_MS 1000: 1 s then 2 s.
        #expect(HTTPPolicy.backoffDelayMs(attempt: 0) == 1000)
        #expect(HTTPPolicy.backoffDelayMs(attempt: 1) == 2000)
        let client = try HTTPClientPolicy(baseURL: "https://api.met.no", userAgent: Self.ua, backoffBaseMs: 5)
        #expect(client.backoffDelayMs(attempt: 0) == 5)
        #expect(client.backoffDelayMs(attempt: 1) == 10)
        // At most WX_HTTP_MAX_RETRIES retries; the deadline and final codes stop them.
        #expect(HTTPPolicy.shouldRetry(.timeout, httpStatus: 0, attempt: 1, totalDeadlineExpired: false))
        #expect(!HTTPPolicy.shouldRetry(.timeout, httpStatus: 0, attempt: 2, totalDeadlineExpired: false))
        #expect(!HTTPPolicy.shouldRetry(.timeout, httpStatus: 0, attempt: 0, totalDeadlineExpired: true))
        for code in [WxError.Code.parse, .notFound, .rateLimited, .invalidArg, .unsupported] {
            #expect(!HTTPPolicy.shouldRetry(code, httpStatus: 503, attempt: 0, totalDeadlineExpired: false), "\(code)")
        }
    }

    // MARK: /http/net/host-pinning-fuzz (policy part: every planned request stays on the origin)

    @Test("/http/net/host-pinning-fuzz '//' targets stay on the origin") // C: /http/net/host-pinning-fuzz (src/net/test-http.c:4662-4705)
    func doubleSlashTargets() throws {
        // Expected targets from the GLib oracle (verbatim wx-http.c request_uri over real
        // g_uri_parse with SOUP_HTTP_URI_FLAGS, Homebrew GLib 2.90.1; u09i2/h/c_pin2.out): dot
        // removal can leave a target that begins with "//". It must be sent on the pinned origin
        // and never resolved as a relative reference.
        let client = try HTTPClientPolicy(baseURL: "https://api.met.no", userAgent: Self.ua)
        let cases: [(String, String)] = [
            ("/.//evil.com", "//evil.com"), ("/.//evil.com/x?y=1", "//evil.com/x?y=1"),
            ("/a/..//evil.com", "//evil.com"), ("/%2E%2E//evil.com", "//evil.com"),
        ]
        for (path, target) in cases {
            let plan = try client.plan(pathAndQuery: path, accept: Self.jsonAccept)
            #expect(plan.target == target, "\(path)")
            #expect(plan.url == "https://api.met.no" + target, "\(path)")
            #expect(URL(string: plan.url)?.host == "api.met.no", "\(path)")
            #expect(URLComponents(string: plan.url)?.percentEncodedHost == "api.met.no", "\(path)")
        }
        // The hazard the HTTPRequestPlan.target documentation forbids: resolving the target
        // against the origin leaves it.
        let plan = try client.plan(pathAndQuery: "/.//evil.com", accept: Self.jsonAccept)
        #expect(URL(string: plan.target, relativeTo: URL(string: client.origin))?.host == "evil.com")
    }

    @Test("/http/pure/constants production hosts") // C: /http/pure/constructor-policy (src/net/test-http.c:1425-1438)
    func productionHosts() throws {
        // WX_OPEN_METEO_BASE_URL (wx-openmeteo.h:182), WX_OPEN_METEO_GEOCODING_BASE_URL (:184),
        // WX_NWS_BASE_URL (wx-nws.h:68), WX_METNO_BASE_URL (wx-metno.h:144).
        // Then the MeteoAlarm feed host of the alert fetchers (WxAlertsFetchers.origin(of: .meteoAlarm)).
        let cBaseURLs = ["https://api.open-meteo.com", "https://geocoding-api.open-meteo.com",
                         "https://api.weather.gov", "https://api.met.no", "https://feeds.meteoalarm.org"]
        #expect(HTTPPolicy.productionHosts == ["api.open-meteo.com", "geocoding-api.open-meteo.com",
                                               "api.weather.gov", "api.met.no", "feeds.meteoalarm.org"])
        #expect(HTTPPolicy.productionHosts.count == cBaseURLs.count)
        for (host, base) in zip(HTTPPolicy.productionHosts, cBaseURLs) {
            let client = try HTTPClientPolicy(baseURL: base, userAgent: Self.ua)
            #expect(client.origin == "https://" + host)
        }
        // The decoded-body cap: 16 MiB for the MeteoAlarm feed host alone (any case), the general
        // 4 MiB for every other production host, alert host and loopback host.
        #expect(HTTPPolicy.meteoAlarmHost == "feeds.meteoalarm.org")
        #expect(HTTPPolicy.meteoAlarmMaxBodyBytes == 16 * 1024 * 1024)
        for host in HTTPPolicy.productionHosts + ["api.brightsky.dev", "api.weather.gc.ca", "127.0.0.1",
                                                  "meteoalarm.org", "feeds.meteoalarm.org.evil"] {
            let cap = host == "feeds.meteoalarm.org" ? 16 * 1024 * 1024 : 4 * 1024 * 1024
            #expect(HTTPPolicy.maxBodyBytes(host: host) == cap, "\(host)")
        }
        #expect(HTTPPolicy.maxBodyBytes(host: "Feeds.MeteoAlarm.ORG") == 16 * 1024 * 1024)
        // Informational only: like C's WxHttp the policy does not restrict hosts.
        #expect(throws: Never.self) { _ = try HTTPClientPolicy(baseURL: "https://example.org", userAgent: Self.ua) }
    }

    /// normalise_target of the C test (src/net/test-http.c:4620-4657), the oracle of the fuzz.
    private static func normaliseTarget(_ target: String) -> String {
        var input = target
        var query = ""
        if let q = target.firstIndex(of: "?") {
            input = String(target[..<q])
            query = String(target[q...])
        }
        var out = ""
        var p = Substring(input)
        func dropLastSegment() {
            if let slash = out.lastIndex(of: "/") { out = String(out[..<slash]) }
        }
        while !p.isEmpty {
            if p.hasPrefix("../") { p = p.dropFirst(3) }
            else if p.hasPrefix("./") { p = p.dropFirst(2) }
            else if p.hasPrefix("/./") { p = p.dropFirst(2) }
            else if p == "/." { p = "/" }
            else if p.hasPrefix("/../") { p = p.dropFirst(3); dropLastSegment() }
            else if p == "/.." { p = "/"; dropLastSegment() }
            else if p == "." || p == ".." { p = "" }
            else {
                let from = p.first == "/" ? p.index(after: p.startIndex) : p.startIndex
                let next = p[from...].firstIndex(of: "/") ?? p.endIndex
                out += p[..<next]
                p = p[next...]
            }
        }
        return out + query
    }

    @Test("/http/net/host-pinning-fuzz targets") // C: /http/net/host-pinning-fuzz (src/net/test-http.c:4662-4705)
    func hostPinningFuzz() throws {
        let otherPort = 9
        let client = try HTTPClientPolicy(baseURL: "http://127.0.0.1:8080", userAgent: Self.ua, timeoutMs: 2000,
                                          backoffBaseMs: 5, minGapMs: 0)
        var rng = SeededRNG(seed: 11)
        // The C alphabet (src/net/test-http.c:4670) without its terminating NUL.
        let alphabet: [UInt8] = Array("/?&=%@:.~-_+!$'()*,;[]{}|^\"<> \\#\t".utf8) + [0xC3, 0xA9] + Array("aZ09".utf8)
        var sent = 0
        for i in 0..<fuzzIterations(600) {
            let n = Int.random(in: 1..<14, using: &rng)
            var path: [UInt8] = [0x2F]
            for _ in 1..<n { path.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }
            let target = i % 7 == 0 ? Self.bytes("/@127.0.0.1:\(otherPort)/x") : path
            do {
                let plan = try client.plan(pathAndQueryBytes: target, acceptBytes: Self.bytes(Self.jsonAccept),
                                           ifModifiedSinceBytes: nil)
                #expect(HTTPPolicy.isValidPath(bytes: target))
                let text = String(decoding: target, as: UTF8.self)
                // NARROWING: C compares every accepted target with normalise_target
                // (src/net/test-http.c:4692-4694). Here only targets without '%' are compared,
                // because the oracle does not model GLib's %-escape normalisation (unreserved
                // escapes decoded, others upper-cased) and SeededRNG draws other paths than GRand.
                // The %-targets are covered by the 140,000-plan differential against real GLib
                // recorded in the U09 debrief, and by the pinned-origin checks below.
                if !text.contains("%") {
                    #expect(plan.target == Self.normaliseTarget(text), "target \(text)")
                }
                #expect(plan.url.hasPrefix("http://127.0.0.1:8080/"), "url \(plan.url)")
                let url = URL(string: plan.url)
                #expect(url?.host == "127.0.0.1" && url?.port == 8080, "url \(plan.url)")
                sent += 1
            } catch {
                #expect(error.code == .invalidArg)
                if HTTPPolicy.isValidPath(bytes: target) {
                    // Accepted by the validator but refused by the URI parser: a bad %-escape.
                    #expect(target.contains(0x25))
                }
            }
        }
        #expect(sent > 100) // the property was exercised, not vacuous (:4696)
    }
}
