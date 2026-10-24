// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PlaceTests.swift - port of the error, value/id and place cases of
// src/core/test-core.c (registered at src/core/test-core.c:3503-3535).
// Expected values are the C test literals, cited as path:line. C string
// literals with escapes are written as byte arrays (the bytes the C compiler
// produced), never as Swift escapes.

import Foundation
import Testing
@testable import WeatherCore

/// T0 = 2026-10-11T00:00:00Z (src/core/test-core.c:18).
private let placeT0: Int64 = 1_791_676_800

/// The UTF-8 bytes of an escape-free literal.
private func u(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

/// n copies of `byte` (g_strnfill).
private func fill(_ n: Int, _ byte: UInt8 = 0x78) -> [UInt8] {
    [UInt8](repeating: byte, count: n)
}

/// make_miami (src/core/test-core.c:38-47).
private func makeMiami() throws -> WxPlace {
    try WxPlace(
        name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
        lat: 25.7617, lon: -80.1918, timezone: "America/New_York")
}

/// assert_place_rejected (src/core/test-core.c:49-60): the bytes initialiser
/// throws WxError.invalidArg; when every argument is valid UTF-8 the String
/// initialiser is checked too.
private func expectRejected(
    _ name: [UInt8]?,
    _ admin1: [UInt8]? = nil,
    _ country: [UInt8]? = nil,
    _ cc: [UInt8]? = nil,
    _ lat: Double = 0,
    _ lon: Double = 0,
    _ tz: [UInt8]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let p = try WxPlace(
            nameBytes: name, admin1Bytes: admin1, countryBytes: country, countryCodeBytes: cc,
            lat: lat, lon: lon, timezoneBytes: tz)
        Issue.record("accepted (bytes): \(p)", sourceLocation: sourceLocation)
    } catch {
        #expect(error.code == .invalidArg, sourceLocation: sourceLocation)
    }
    func text(_ b: [UInt8]?) -> (ok: Bool, s: String?) {
        guard let b else {
            return (true, nil)
        }
        guard let s = String(bytes: b, encoding: .utf8) else {
            return (false, nil)
        }
        return (true, s)
    }
    let args = [text(name), text(admin1), text(country), text(cc), text(tz)]
    if args.allSatisfy(\.ok) {
        do {
            let p = try WxPlace(
                name: args[0].s, admin1: args[1].s, country: args[2].s, countryCode: args[3].s,
                lat: lat, lon: lon, timezone: args[4].s)
            Issue.record("accepted (String): \(p)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == .invalidArg, sourceLocation: sourceLocation)
        }
    }
}

/// The message of the WxError thrown by `body` (nil if nothing was thrown).
private func message(_ body: () throws(WxError) -> WxPlace) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return error.message
    }
}

@Suite struct PlaceTests {
    // MARK: - errors, limits, values, ids

    // C: /core/types/error-domain (the quark half is GLIB-INTERNAL)
    @Test func errorOrdinalsAndLimits() {
        // src/core/test-core.c:149-151
        #expect(WxError.Code.network.rawValue == 0)
        #expect(WxError.Code.unsupported.rawValue == 7)
        #expect(WxError.Code.timeout != WxError.Code.http)
        // every ordinal, src/core/wx-types.h:28-37
        let ordinals: [(WxError.Code, Int)] = [
            (.network, 0), (.timeout, 1), (.http, 2), (.rateLimited, 3),
            (.parse, 4), (.notFound, 5), (.invalidArg, 6), (.unsupported, 7),
        ]
        for (code, ordinal) in ordinals {
            #expect(code.rawValue == ordinal, "\(code)")
            #expect(WxError.Code(rawValue: ordinal) == code)
        }
        #expect(WxError.Code.allCases.count == 8)
        #expect(WxError.Code(rawValue: -1) == nil)
        #expect(WxError.Code(rawValue: 8) == nil)
        // g_error_matches(err, WX_ERROR, WX_ERROR_RATE_LIMITED), src/core/test-core.c:146-147
        let err = WxError(.rateLimited, "slow down")
        #expect(err.code == .rateLimited)
        #expect(err.message == "slow down")
        #expect(err.localizedDescription == "slow down")
        // src/core/test-core.c:156-161
        #expect(WxLimits.memberMaxHours == 400)
        #expect(WxLimits.memberMaxQuarters == 1536)
        #expect(WxLimits.placeNameMax == 256)
        #expect(WxLimits.placeMax == 50)
        #expect(WxLimits.timeMinS == Int64(946_684_800))
        #expect(WxLimits.timeMaxS == Int64(4_133_980_800))
    }

    // C: /core/types/value-in-range
    @Test func valueInRange() {
        // src/core/test-core.c:168-181
        #expect(WxLimits.valueInRange(0.0, 0.0, 100.0))
        #expect(WxLimits.valueInRange(100.0, 0.0, 100.0))
        #expect(WxLimits.valueInRange(-100.0, WxLimits.tempMinC, WxLimits.tempMaxC))
        #expect(WxLimits.valueInRange(70.0, WxLimits.tempMinC, WxLimits.tempMaxC))
        #expect(!WxLimits.valueInRange(-100.0001, WxLimits.tempMinC, WxLimits.tempMaxC))
        #expect(!WxLimits.valueInRange(70.0001, WxLimits.tempMinC, WxLimits.tempMaxC))
        #expect(!WxLimits.valueInRange(100.0001, 0.0, 100.0))
        #expect(!WxLimits.valueInRange(.nan, 0.0, 100.0))
        #expect(!WxLimits.valueInRange(.infinity, 0.0, .infinity))
        #expect(!WxLimits.valueInRange(-.infinity, -.infinity, 0.0))
        #expect(!WxLimits.valueInRange(1.0, .nan, 2.0))
        #expect(!WxLimits.valueInRange(1.0, 0.0, .nan))
        #expect(WxLimits.valueInRange(WxLimits.windMaxKmh, 0.0, WxLimits.windMaxKmh))
        #expect(WxLimits.valueInRange(WxLimits.precipMaxMmH, 0.0, WxLimits.precipMaxMmH))
    }

    // C: /core/types/id-validation (the wx_member_new / wx_source_result_new /
    // wx_source_status_new lines, src/core/test-core.c:235-239, belong to U07)
    @Test func idValidation() {
        // src/core/test-core.c:187-232
        let good = [
            "open-meteo", "ecmwf_ifs025", "met-no", "a", "a.b_c-9",
            "abcdefghijklmnopqrstuvwxyz012345",  // 32
            "a.b", "a..b", "a-", "a.", "0.25", "9", "ecmwf_ifs0.25",
        ]
        for id in good {
            #expect(WxLimits.isValidID(id), "\(id)")
            #expect(WxLimits.isValidID(bytes: u(id)), "\(id)")
        }
        let bad = [
            "abcdefghijklmnopqrstuvwxyz0123456",  // 33
            "", "Open", "a b", "a/b", "../x", "a%00",
            ".", "..", "...", ".x", ".hidden", "-x", "-", "--help", "_x", "_", "../etc", "..x",
        ]
        for id in bad {
            #expect(!WxLimits.isValidID(id), "\(id)")
        }
        #expect(!WxLimits.isValidID(nil))
        #expect(!WxLimits.isValidID(bytes: [0x61, 0x0A]))  // "a\n"
        #expect(!WxLimits.isValidID(bytes: [0xC3, 0xA9]))  // "\xc3\xa9"
        // unterminated long buffer: only WX_ID_MAX + 1 bytes are examined
        #expect(!WxLimits.isValidID(bytes: fill(200, 0x61)))
    }

    // C: /core/types/time-range-edges (the member and forecast edges belong to U07)
    @Test func timeRangeEdges() {
        // src/core/test-core.c:2502-2504
        #expect(WxLimits.timeMinS % 3600 == 0)
        #expect(WxLimits.timeMaxS % 3600 == 0)
        #expect(WxLimits.timeMaxS % 900 == 0)
    }

    // MARK: - places

    // C: /core/types/place-valid
    @Test func placeValid() throws {
        // src/core/test-core.c:244-275
        let p = try makeMiami()
        #expect(p.name == "Miami")
        #expect(p.admin1 == "Florida")
        #expect(p.country == "United States")
        #expect(p.countryCode == "US")
        #expect(p.lat == 25.7617)
        #expect(p.lon == -80.1918)
        #expect(p.timezone == "America/New_York")

        // NULL and "" optional fields become ""
        let q = try WxPlace(name: "Oslo", lat: 59.91, lon: 10.75)
        #expect(q.admin1 == "")
        #expect(q.country == "")
        #expect(q.countryCode == "")
        #expect(q.timezone == "")
        let r = try WxPlace(name: "Oslo", admin1: "", country: "", countryCode: "", lat: 59.91, lon: 10.75, timezone: "")
        #expect(r.admin1 == "")
        #expect(r.countryCode == "")

        // non-ASCII names are fine: "S\xc3\xa3o Paulo" and "\xe6\x9d\xb1\xe4\xba\xac"
        let saoPaulo: [UInt8] = [0x53, 0xC3, 0xA3, 0x6F, 0x20, 0x50, 0x61, 0x75, 0x6C, 0x6F]
        let u1 = try WxPlace(
            nameBytes: saoPaulo, admin1Bytes: saoPaulo, countryBytes: u("Brasil"), countryCodeBytes: u("BR"),
            lat: -23.55, lon: -46.63, timezoneBytes: u("America/Sao_Paulo"))
        #expect(Array(u1.name.utf8) == saoPaulo)
        let tokyo: [UInt8] = [0xE6, 0x9D, 0xB1, 0xE4, 0xBA, 0xAC]
        let cjk = try WxPlace(
            nameBytes: tokyo, countryCodeBytes: u("JP"), lat: 35.68, lon: 139.69, timezoneBytes: u("Asia/Tokyo"))
        #expect(Array(cjk.name.utf8) == tokyo)
        let tz = try WxPlace(name: "X", lat: 0, lon: 0, timezone: "Etc/GMT+5")
        #expect(tz.timezone == "Etc/GMT+5")
    }

    // C: /core/types/place-boundaries
    @Test func placeBoundaries() throws {
        // src/core/test-core.c:279-307
        _ = try WxPlace(name: "N", lat: 90.0, lon: 180.0)
        _ = try WxPlace(name: "S", lat: -90.0, lon: -180.0)

        let n256 = fill(256)
        let n257 = fill(257)
        let c = try WxPlace(nameBytes: n256, admin1Bytes: n256, countryBytes: n256, lat: 0, lon: 0)
        #expect(c.name.utf8.count == 256)
        let s256 = String(repeating: "x", count: 256)
        _ = try WxPlace(name: s256, admin1: s256, country: s256, lat: 0, lon: 0)
        expectRejected(n257)
        expectRejected(u("x"), n257)
        expectRejected(u("x"), nil, n257)

        // a 2-byte character straddling the limit is still a plain length failure
        expectRejected(fill(255) + [0xC3, 0xA9])  // 257 bytes

        let tz64 = fill(64, 0x61)
        let tz65 = fill(65, 0x61)
        let d = try WxPlace(nameBytes: u("x"), lat: 0, lon: 0, timezoneBytes: tz64)
        #expect(d.timezone.utf8.count == 64)
        expectRejected(u("x"), nil, nil, nil, 0, 0, tz65)

        expectRejected(u("x"), nil, nil, nil, 90.0001, 0)
        expectRejected(u("x"), nil, nil, nil, -90.0001, 0)
        expectRejected(u("x"), nil, nil, nil, 0, 180.0001)
        expectRejected(u("x"), nil, nil, nil, 0, -180.0001)
    }

    // C: /core/types/place-hostile
    @Test func placeHostile() {
        // src/core/test-core.c:312-365
        expectRejected(nil)
        expectRejected(u(""))
        expectRejected(u("   "))
        expectRejected([0x09, 0x0A])  // "\t\n"
        expectRejected([0x4D, 0x69, 0x61, 0x0A, 0x6D, 0x69])  // "Mia\nmi"
        expectRejected([0x4D, 0x69, 0x61, 0x09, 0x6D, 0x69])  // "Mia\tmi"
        expectRejected([0x4D, 0x69, 0x61, 0x7F])  // "Mia\x7f"
        expectRejected([0x4D, 0x69, 0x61, 0x1B, 0x5B, 0x33, 0x31, 0x6D])  // "Mia\x1b[31m"
        expectRejected([0x4D, 0x69, 0x61, 0xC2, 0x85, 0x6D, 0x69])  // C1 NEL
        expectRejected([0x61, 0xE2, 0x80, 0xAA, 0x62])  // U+202A
        expectRejected([0x61, 0xE2, 0x80, 0xAE, 0x62])  // U+202E RLO
        expectRejected([0x61, 0xE2, 0x81, 0xA6, 0x62])  // U+2066 LRI
        expectRejected([0x61, 0xE2, 0x80, 0x8F, 0x62])  // U+200F RLM
        expectRejected([0x61, 0xE2, 0x80, 0xA8, 0x62])  // U+2028
        expectRejected([0x61, 0xFF, 0x62])  // invalid UTF-8
        expectRejected([0x61, 0xC3])  // truncated
        expectRejected([0x61, 0xC0, 0x80, 0x62])  // overlong NUL
        expectRejected([0x61, 0xED, 0xA0, 0x80, 0x62])  // surrogate
        expectRejected(u("x"), [0x62, 0x61, 0x64, 0x0A, 0x61, 0x64, 0x6D, 0x69, 0x6E])  // "bad\nadmin"
        expectRejected(u("x"), nil, [0x62, 0x61, 0x64, 0xFF])  // "bad\xff"
        expectRejected(u("x"), u("  "))  // whitespace-only optional text

        // country codes
        expectRejected(u("x"), nil, nil, u("us"))
        expectRejected(u("x"), nil, nil, u("U"))
        expectRejected(u("x"), nil, nil, u("USA"))
        expectRejected(u("x"), nil, nil, u("U1"))
        expectRejected(u("x"), nil, nil, u("U "))
        expectRejected(u("x"), nil, nil, [0xC3, 0x9C, 0x53])  // "\xc3\x9c" "S"

        // coordinates
        expectRejected(u("x"), nil, nil, nil, .nan, 0)
        expectRejected(u("x"), nil, nil, nil, 0, .nan)
        expectRejected(u("x"), nil, nil, nil, .infinity, 0)
        expectRejected(u("x"), nil, nil, nil, 0, -.infinity)
        expectRejected(u("x"), nil, nil, nil, 1e308, 0)

        // time zones
        let badTZ: [[UInt8]] = [
            u("America/New York"),
            u("../etc/passwd") + [0x0A],
            u("UTC;rm"), u("/etc/passwd"), u("/dev/stdin"), u("/"), u("//"), u("-"), u("America/"),
            u("America//New_York"), u("/usr/share/zoneinfo/Asia/Tokyo"), u("./x"), u("a/../b"),
            [0x5A, 0xC3, 0xBC, 0x72, 0x69, 0x63, 0x68],  // "Z\xc3\xbcrich"
            u("A%20B"),
        ]
        for tz in badTZ {
            expectRejected(u("x"), nil, nil, nil, 0, 0, tz)
        }
    }

    // C: /core/types/place-error-text
    @Test func placeErrorText() {
        // src/core/test-core.c:370-374: "secret\nname"
        let secret: [UInt8] = [0x73, 0x65, 0x63, 0x72, 0x65, 0x74, 0x0A, 0x6E, 0x61, 0x6D, 0x65]
        let msg = message { () throws(WxError) in try WxPlace(nameBytes: secret, lat: 0, lon: 0) }
        #expect(msg != nil)
        #expect(msg?.contains("secret") == false)
    }

    // C: /core/types/error-messages-no-echo (the place half; the member, source
    // result and source status lines, src/core/test-core.c:2421-2435, belong to U07)
    @Test func errorMessagesDoNotEcho() {
        // src/core/test-core.c:2400-2420
        let secret = "SECRETZZ"
        let evil = u(secret) + [0x0A, 0xFF]  // secret "\n\xff"
        let evilTZ = u("/" + secret)
        let messages = [
            message { () throws(WxError) in try WxPlace(nameBytes: evil, lat: 0, lon: 0) },
            message { () throws(WxError) in try WxPlace(nameBytes: u("x"), admin1Bytes: evil, lat: 0, lon: 0) },
            message { () throws(WxError) in try WxPlace(nameBytes: u("x"), countryBytes: evil, lat: 0, lon: 0) },
            message { () throws(WxError) in try WxPlace(name: "x", countryCode: secret, lat: 0, lon: 0) },
            message { () throws(WxError) in try WxPlace(nameBytes: u("x"), lat: 0, lon: 0, timezoneBytes: evilTZ) },
        ]
        for m in messages {
            #expect(m != nil)
            #expect(m?.contains(secret) == false, "\(m ?? "nil")")
        }
    }

    // The constant messages and the order of the checks (src/core/wx-types.c:292-315);
    // executor-added: the C tests only assert that the messages do not echo input.
    @Test func errorMessageForFirstFailingRule() {
        let bad = [UInt8]([0x0A])
        #expect(message { () throws(WxError) in try WxPlace(nameBytes: nil, admin1Bytes: bad, lat: .nan, lon: 0) }
            == "invalid place name")
        #expect(message { () throws(WxError) in try WxPlace(nameBytes: u("x"), admin1Bytes: bad, countryBytes: bad, lat: 0, lon: 0) }
            == "invalid region name")
        #expect(message { () throws(WxError) in try WxPlace(nameBytes: u("x"), countryBytes: bad, countryCodeBytes: u("u"), lat: 0, lon: 0) }
            == "invalid country name")
        #expect(message { () throws(WxError) in try WxPlace(name: "x", countryCode: "u", lat: 91, lon: 0) }
            == "invalid country code")
        #expect(message { () throws(WxError) in try WxPlace(name: "x", lat: 0, lon: 181, timezone: "/") }
            == "coordinates out of range")
        #expect(message { () throws(WxError) in try WxPlace(name: "x", lat: 0, lon: 0, timezone: "/") }
            == "invalid time zone name")
    }

    // C: /core/types/place-timezone-shapes (the forecast-copy line, src/core/test-core.c:3235,
    // belongs to U07; wx_place_copy of a hand-built place is impossible: WxPlace has no
    // unvalidated initialiser)
    @Test func placeTimezoneShapes() throws {
        // src/core/test-core.c:3191-3195
        let good = [
            "UTC", "GMT", "EST5EDT", "America/New_York", "Etc/GMT+5", "Etc/GMT-14",
            "America/Port-au-Prince", "America/Argentina/ComodRivadavia",
            "America/North_Dakota/New_Salem", "Asia/Ho_Chi_Minh", "Africa/Dar_es_Salaam", "",
        ]
        for tz in good {
            let p = try WxPlace(name: "x", lat: 0, lon: 0, timezone: tz)
            #expect(p.timezone == tz)
        }
        // src/core/test-core.c:3203-3209
        let bad: [[UInt8]] = [
            u("/etc/passwd"), u("/dev/stdin"), u("/"), u("//"), u("///"), u("-"), u("--help"), u("-x"),
            u("+05"), u("_x"), u("1abc"),
            u("America/"), u("America//New_York"), u("/America/New_York"), u("America/New_York/"),
            u("/usr/share/zoneinfo/Asia/Tokyo"), u("./x"), u("../x"), u("a/../b"), u("a/./b"), u(".."), u("."),
            u("a/.."), u("a/."), u("a/-b"), u("a/+b"), u("a/_b"), u("a/1b"), u("Etc/+5"), u("a b"), u(" UTC"),
            u("UTC "),
            [0x61, 0x5C, 0x62],  // "a\\b"
            u("a:b"), u("a%2Fb"),
            [0x61, 0x09, 0x62],  // "a\tb"
            [0x61, 0x0A, 0x62],  // "a\nb"
            [0x5A, 0xC3, 0xBC, 0x72, 0x69, 0x63, 0x68],  // "Z\xc3\xbcrich"
            u("a;b"), u("a$b"), u("a~b"), u("a.b"), u("America/New.York"),
        ]
        for tz in bad {
            expectRejected(u("x"), nil, nil, nil, 0, 0, tz)
        }
        // exactly 64 bytes pass, 65 fail, also when built from components (src/core/test-core.c:3215-3227)
        let tz63 = fill(31, 0x61) + [0x2F] + fill(31, 0x61)
        let tz64 = fill(32, 0x61) + [0x2F] + fill(31, 0x61)
        let tz65 = fill(32, 0x61) + [0x2F] + fill(32, 0x61)
        #expect(tz63.count == 63)
        #expect(tz64.count == 64)
        #expect(tz65.count == 65)
        _ = try WxPlace(nameBytes: u("x"), lat: 0, lon: 0, timezoneBytes: tz63)
        _ = try WxPlace(nameBytes: u("x"), lat: 0, lon: 0, timezoneBytes: tz64)
        expectRejected(u("x"), nil, nil, nil, 0, 0, tz65)
    }

    // C: /core/types/place-key-label
    @Test func placeKeyLabel() throws {
        // src/core/test-core.c:380-415
        let p = try makeMiami()
        #expect(p.key == "25.7617,-80.1918")
        #expect(p.label == "Miami, Florida, United States")

        let a = try WxPlace(name: "Oslo", country: "Norway", countryCode: "NO", lat: 59.9139, lon: 10.7522)
        #expect(a.label == "Oslo, Norway")
        let b = try WxPlace(name: "Oslo", admin1: "", country: "", lat: 59.9139, lon: 10.7522)
        #expect(b.label == "Oslo")
        let c = try WxPlace(name: "Texas", admin1: "Texas", country: "", lat: 31.0, lon: -100.0)
        #expect(c.label == "Texas, Texas")

        // rounding to 4 decimals, zero padding, negative zero
        #expect(try WxPlace(name: "x", lat: 1.0, lon: -0.00001).key == "1.0000,0.0000")
        #expect(try WxPlace(name: "x", lat: -33.86882, lon: 151.20929).key == "-33.8688,151.2093")
        #expect(try WxPlace(name: "x", lat: -90.0, lon: 180.0).key == "-90.0000,180.0000")
        // places 0.00004 degrees apart share a key; 0.0001 apart do not
        let k1 = try WxPlace(name: "x", lat: 10.12341, lon: 20.0).key
        let k2 = try WxPlace(name: "x", lat: 10.12344, lon: 20.0).key
        let k3 = try WxPlace(name: "x", lat: 10.12351, lon: 20.0).key
        #expect(k1 == k2)
        #expect(k1 != k3)
    }

    // C: /core/types/place-key-locale. Swift analogue: the key takes no Locale.
    // Locale.current cannot be switched per test, so this checks the C literals
    // and that a comma-decimal formatter WOULD change the inputs (non-vacuity).
    @Test func placeKeyLocaleIndependent() throws {
        // src/core/test-core.c:417-438
        let p = try makeMiami()
        #expect(p.key == "25.7617,-80.1918")
        #expect(WxTime.parseISO8601("2026-10-11T00:00:00.5Z") == placeT0)
        let german = String(format: "%.4f", locale: Locale(identifier: "de_DE"), 25.7617)
        #expect(german == "25,7617")
        #expect(!p.key.contains(german))
    }

    // C: /core/types/place-key-charset (SeededRNG replaces GRand seed 31415)
    @Test func placeKeyCharset() throws {
        // src/core/test-core.c:2447-2474
        var rng = SeededRNG(seed: 31415)
        var sawLeadingMinus = false
        let allowed = Set("0123456789.,-".utf8)
        for i in 0..<5000 {
            var lat = Double.random(in: -90.0..<90.0, using: &rng)
            var lon = Double.random(in: -180.0..<180.0, using: &rng)
            if i == 0 {
                lat = -90.0
                lon = -180.0
            } else if i == 1 {
                lat = 90.0
                lon = 180.0
            } else if i == 2 {
                lat = -0.0
                lon = -0.00004
            }
            let key = try WxPlace(name: "x", lat: lat, lon: lon).key
            #expect(key.contains(","), "\(key)")
            #expect(key.utf8.allSatisfy { allowed.contains($0) }, "\(key)")
            #expect(!key.contains("-0.0000"), "\(key)")
            let first = key.utf8.first ?? 0
            if first == UInt8(ascii: "-") {
                sawLeadingMinus = true
            }
            #expect(first == UInt8(ascii: "-") || (first >= 0x30 && first <= 0x39), "\(key)")
        }
        #expect(sawLeadingMinus)
    }

    // NUL-terminated input model (executor-added; wx-types.h:203-205: strings are
    // examined only up to their bound plus one byte, and C stops at the NUL).
    @Test func textEndsAtFirstNul() throws {
        let p = try WxPlace(
            nameBytes: u("Mia") + [0x00] + u("mi"), countryCodeBytes: u("US") + [0x00, 0x58],
            lat: 0, lon: 0, timezoneBytes: u("UTC") + [0x00] + u("/../x"))
        #expect(p.name == "Mia")
        #expect(p.countryCode == "US")
        #expect(p.timezone == "UTC")
        expectRejected([0x00, 0x41])  // "" before the NUL
    }
}
