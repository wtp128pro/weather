// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// TimeTests.swift - port of the time cases of src/core/test-core.c
// (registered at src/core/test-core.c:3546-3553). Expected values are the C
// literals; the calendar and round-trip oracles use Foundation's Gregorian
// calendar in UTC in place of GDateTime.

import Foundation
import Testing
@testable import WeatherCore

/// T0 = 2026-10-11T00:00:00Z (src/core/test-core.c:18).
private let t0: Int64 = 1_791_676_800
/// WX_TIME_MIN_S / WX_TIME_MAX_S (src/core/wx-types.h:90,92).
private let timeMinS: Int64 = 946_684_800
private let timeMaxS: Int64 = 4_133_980_800

/// The bytes of a C literal body with `\xHH` (two hex digits), `\n`, `\0`.
private func timeBytes(_ literal: String) -> [UInt8] {
    var out: [UInt8] = []
    let src = Array(literal.utf8)
    var i = 0
    while i < src.count {
        if src[i] == UInt8(ascii: "\\") && i + 1 < src.count {
            switch src[i + 1] {
            case UInt8(ascii: "x"):
                out.append(UInt8(String(decoding: src[(i + 2)..<(i + 4)], as: UTF8.self), radix: 16)!)
                i += 4
            case UInt8(ascii: "n"): out.append(0x0A); i += 2
            case UInt8(ascii: "0"): out.append(0x00); i += 2
            default: out.append(src[i + 1]); i += 2
            }
        } else {
            out.append(src[i])
            i += 1
        }
    }
    return out
}

/// UTC Gregorian calendar used as the independent oracle (GDateTime in C).
private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

@Suite struct TimeTests {
    // C: /core/time/iso8601-valid (src/core/test-core.c:1627-1652)
    @Test(arguments: [
        ("2026-10-11T00:00:00Z", t0),
        ("2026-10-11T00:00:00+00:00", t0),
        ("2026-10-11T00:00:00-00:00", t0),
        ("2026-10-11T00:00:00.000Z", t0),
        ("2026-10-11T00:00:00.999Z", t0),  // fraction truncated
        ("2026-10-11T00:00:00.123456789012Z", t0),
        ("2026-10-11T00:00:00.5+00:00", t0),
        ("2026-10-11T01:00:00+01:00", t0),
        ("2026-10-10T20:00:00-04:00", t0),
        ("2026-10-11T05:30:00+05:30", t0),
        ("2026-10-11T05:45:00+05:45", t0),  // Nepal
        ("2026-10-10T12:15:00-11:45", t0),
        ("2026-10-11T23:59:00+23:59", t0),
        ("2026-10-10T00:01:00-23:59", t0),
        ("2000-01-01T00:00:00Z", 946_684_800),
        ("2000-02-29T12:00:00Z", 951_825_600),  // 2000 is leap (div by 400)
        ("2100-12-31T23:59:59Z", 4_133_980_799),
        ("2024-02-29T23:59:59Z", 1_709_251_199),
        ("2038-01-19T03:14:08Z", 2_147_483_648),  // past the 32-bit limit
        ("2026-10-11T00:00:00.5-04:00", t0 + 4 * 3600),
        // the converted instant may leave 2000..2100 by the offset
        ("2000-01-01T00:00:00+01:00", 946_684_800 - 3600),
        ("2100-12-31T23:59:59-01:00", 4_133_980_799 + 3600),
    ] as [(String, Int64)])
    func iso8601Valid(text: String, expected: Int64) {
        #expect(WxTime.parseISO8601(text) == expected)
    }

    // C: /core/time/iso8601-rejects (src/core/test-core.c:1655-1702)
    @Test(arguments: [
        "", "2026", "2026-10-11", "2026-10-11T00:00:00", "2026-10-11T00:00Z",
        "2026-10-11T00:00:00z", "2026-10-11t00:00:00Z", "2026-10-11 00:00:00Z",
        "2026-10-11T00:00:00 Z", " 2026-10-11T00:00:00Z", "2026-10-11T00:00:00Z ",
        #"2026-10-11T00:00:00Z\n"#, "2026-10-11T00:00:00ZZ", "2026-10-11T00:00:00+0000",
        "2026-10-11T00:00:00+00", "2026-10-11T00:00:00+00:0", "2026-10-11T00:00:00+0:00",
        "2026-10-11T00:00:00+00:000", "2026-10-11T00:00:00+00.00", "2026-10-11T00:00:00+24:00",
        "2026-10-11T00:00:00+00:60", "2026-10-11T00:00:00-24:00", "2026-10-11T00:00:00+ab:cd",
        "2026-10-11T00:00:00.Z", "2026-10-11T00:00:00.", "2026-10-11T00:00:00,5Z",
        "2026-10-11T00:00:00.5", "2026-10-11T00:00:00.5.5Z", "2026-10-11T00:00:00.5xZ",
        "2026-10-11T00:00:60Z", "2026-10-11T00:60:00Z", "2026-10-11T24:00:00Z",
        "2026-10-11T24:00:01Z", "2026-13-11T00:00:00Z", "2026-00-11T00:00:00Z",
        "2026-10-00T00:00:00Z", "2026-10-32T00:00:00Z", "2026-04-31T00:00:00Z",
        "2026-02-29T00:00:00Z", "2100-02-29T00:00:00Z", "1900-02-28T00:00:00Z",
        "1999-12-31T23:59:59Z", "2101-01-01T00:00:00Z", "9999-12-31T23:59:59Z",
        "0000-01-01T00:00:00Z", "2026/10/11T00:00:00Z", "2026-10-11T00-00-00Z",
        "26-10-11T00:00:00Z", "+2026-10-11T00:00:00Z", "2026-1-11T00:00:00Z",
        "2026-10-1T00:00:00Z", "2026-10-11T0:00:00Z", #"2026-10-11T00:00:00\xc2\xa0Z"#,
        "20261011T000000Z", "2026-W41-7T00:00:00Z", "2026-10-11T00:00:00Z+01:00",
        #"2026-10-11T00:00:0\00Z"#, "-026-10-11T00:00:00Z", "2026-10-11T00:00:+1Z",
        "2026-10-11T00:-1:00Z", "2026-10-11T 0:00:00Z", #"2026-10-11T00:00:00\xff"#,
        #"2026-10-11T00:00:00+00:00\n"#, "2026-10-11T00:00:00.123456789012345678901234567890Z",
    ])
    func iso8601Rejects(literal: String) {
        #expect(WxTime.parseISO8601(bytes: timeBytes(literal)) == nil, "accepted \(literal)")
    }

    // C: /core/time/iso8601-rejects (src/core/test-core.c:1684-1697)
    @Test func iso8601RejectsNullAndLengthBound() {
        #expect(WxTime.parseISO8601(nil) == nil)
        // length bound: 40 bytes accepted, 41 rejected
        let ok40 = "2026-10-11T00:00:00.1234567890123456789Z"
        #expect(ok40.utf8.count == 40)
        #expect(WxTime.parseISO8601(ok40) == t0)
        let bad41 = "2026-10-11T00:00:00.12345678901234567890Z"
        #expect(bad41.utf8.count == 41)
        #expect(WxTime.parseISO8601(bad41) == nil)
        // unterminated buffer: only 41 bytes are inspected
        #expect(WxTime.parseISO8601(bytes: [UInt8](repeating: UInt8(ascii: "1"), count: 256)) == nil)
    }

    // C: /core/time/iso8601-calendar (src/core/test-core.c:1705-1731)
    @Test func iso8601Calendar() {
        let cal = utcCalendar()
        for year in 2023...2024 {
            for month in 1...12 {
                for day in 1...31 {
                    let s = String(format: "%04ld-%02ld-%02ldT13:14:15Z", year, month, day)
                    let comps = DateComponents(calendar: cal, timeZone: cal.timeZone, year: year, month: month,
                                               day: day, hour: 13, minute: 14, second: 15)
                    if !comps.isValidDate {
                        #expect(WxTime.parseISO8601(s) == nil, "\(s) accepted")  // e.g. 2023-02-29, 04-31
                    } else {
                        let want = Int64(cal.date(from: comps)!.timeIntervalSince1970)
                        #expect(WxTime.parseISO8601(s) == want, "\(s)")
                    }
                }
            }
        }
        // century rules
        #expect(WxTime.parseISO8601("2000-02-29T00:00:00Z") != nil)
        #expect(WxTime.parseISO8601("2096-02-29T00:00:00Z") != nil)
        #expect(WxTime.parseISO8601("2100-02-29T00:00:00Z") == nil)
        #expect(WxTime.parseISO8601("2001-02-29T00:00:00Z") == nil)
        #expect(WxTime.parseISO8601("2025-02-29T00:00:00Z") == nil)
        #expect(WxTime.parseISO8601("2028-02-29T00:00:00Z") != nil)
    }

    // C: /core/time/iso8601-roundtrip-fuzz (src/core/test-core.c:1734-1758). SeededRNG (seed kept)
    // replaces GRand; Foundation's UTC calendar replaces GDateTime as the oracle.
    @Test func iso8601RoundtripFuzz() {
        var rng = SeededRNG(seed: 424_242)
        let cal = utcCalendar()
        for i in 0..<fuzzIterations(20_000) {
            let want = timeMinS + Int64(Double.random(in: 0..<Double(4_133_980_799 - timeMinS), using: &rng))
            let offsetMin = Int.random(in: (-23 * 60 - 59)..<(23 * 60 + 60), using: &rng)
            let local = want + Int64(offsetMin) * 60
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                       from: Date(timeIntervalSince1970: TimeInterval(local)))
            let y = c.year!
            if y < 2000 || y > 2100 {
                continue
            }
            let s = String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld%@%@%02ld:%02ld", y, c.month!, c.day!, c.hour!,
                           c.minute!, c.second!, i % 3 == 0 ? ".25" : "", offsetMin < 0 ? "-" : "+",
                           abs(offsetMin) / 60, abs(offsetMin) % 60)
            #expect(WxTime.parseISO8601(s) == want, "\(s)")
        }
    }

    // C: /core/time/iso8601-mutation-fuzz (src/core/test-core.c:1761-1795)
    @Test func iso8601MutationFuzz() {
        var rng = SeededRNG(seed: 77)
        let base = Array("2026-10-11T18:30:45.123+05:30".utf8)
        let junk = timeBytes(#"0129-:T.+Zz /\n\xff\x80a"#)
        #expect(junk.count == 17)  // sizeof junk - 1
        for _ in 0..<fuzzIterations(40_000) {
            var buf = base
            let flips = Int.random(in: 1..<4, using: &rng)
            for _ in 0..<flips {
                let pos = Int.random(in: 0..<(buf.count + 1), using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0:
                    if pos < buf.count { buf[pos] = junk[Int.random(in: 0..<junk.count, using: &rng)] }
                case 1:
                    if pos < buf.count { buf.remove(at: pos) }
                default:
                    if buf.count < 50 { buf.insert(junk[Int.random(in: 0..<junk.count, using: &rng)], at: pos) }
                }
            }
            if let t = WxTime.parseISO8601(bytes: buf) {
                // anything accepted must fit the profile
                #expect(buf.count <= WxTime.iso8601MaxLength)
                #expect(buf[10] == UInt8(ascii: "T"))
                #expect(t > timeMinS - 2 * 86400 && t < timeMaxS + 2 * 86400)
            }
        }
    }

    // C: /core/time/duration (src/core/test-core.c:1820-1908)
    @Test(arguments: [
        ("PT1H", 3600), ("PT3H", 3 * 3600), ("PT30M", 1800), ("PT45S", 45), ("PT1H30M", 5400),
        ("PT1H30M15S", 5415), ("PT0S", 0), ("PT0H", 0), ("P1D", 86400), ("P2D", 172_800),
        ("P1DT12H", 86400 + 43200), ("P1DT1H1M1S", 86400 + 3661), ("P0D", 0), ("PT24H", 86400),
        ("PT36H", 129_600), ("PT01H", 3600) /* leading zeros ok */, ("P31D", 31 * 86400),
        ("PT744H", 31 * 86400), ("P30DT24H", 31 * 86400), ("PT44640M", 31 * 86400),
        ("PT2678400S", 31 * 86400),
    ] as [(String, Int64)])
    func durationAccepts(text: String, expected: Int64) {
        #expect(WxTime.parseDuration(text) == expected)
    }

    // C: /core/time/duration (src/core/test-core.c:1843-1890)
    @Test(arguments: [
        "", "P", "PT", "P1DT", "T1H", "1H", "pt1h", "PT1h", "P1d", "PT1", "P1", "PTH", "PT1H1H",
        "PT30M1H", "PT1S1M", "P1D1D", "PT1HT1M", "P1H", "P1M", "P1Y", "P1W", "P1Y2M3DT4H", "PT1D",
        "-PT1H", "PT-1H", "+PT1H", "PT1.5H", "PT1,5H", "PT0.5S", "PT 1H", "PT1H ", " PT1H",
        #"PT1H\n"#, "PT1H/", #"PT\xd9\xa1H"#, "P32D", "P31DT1S", "PT745H", "PT44641M", "PT2678401S",
        "P99999999D", "P999999999D", "PT99999999999999999999S", "PT99999999H99999999M99999999S",
        "P1DT1H1M1SX", "PT0000000000000000000000000000000000000001S",
    ])
    func durationRejects(literal: String) {
        #expect(WxTime.parseDuration(bytes: timeBytes(literal)) == nil, "accepted \(literal)")
    }

    // C: /core/time/duration (src/core/test-core.c:1843, 1891-1903)
    @Test func durationRejectsNullAndUnterminated() {
        #expect(WxTime.parseDuration(nil) == nil)
        #expect(WxTime.parseDuration(bytes: [UInt8](repeating: UInt8(ascii: "P"), count: 256)) == nil)
        var big = [UInt8](repeating: UInt8(ascii: "1"), count: 256)
        big[0] = UInt8(ascii: "P")
        big[1] = UInt8(ascii: "T")
        #expect(WxTime.parseDuration(bytes: big) == nil)
    }

    // C: /core/time/interval (src/core/test-core.c:1911-1964)
    @Test func interval() {
        #expect(WxTime.parseInterval("2026-10-11T00:00:00+00:00/PT1H") == WxTime.Interval(start: t0, duration: 3600))
        #expect(WxTime.parseInterval("2026-10-10T20:00:00-04:00/PT3H30M") == WxTime.Interval(start: t0, duration: 3 * 3600 + 1800))
        #expect(WxTime.parseInterval("2026-10-11T00:00:00Z/P1DT6H")?.duration == Int64(86400 + 6 * 3600))
        #expect(WxTime.parseInterval("2026-10-11T00:00:00Z/P7D")?.duration == Int64(7 * 86400))

        let bad: [String?] = [
            nil, "", "/", "/PT1H", "2026-10-11T00:00:00Z/", "2026-10-11T00:00:00Z",
            "PT1H", "2026-10-11T00:00:00Z/PT0S", "2026-10-11T00:00:00Z/P0D",
            "2026-10-11T00:00:00Z/PT1H/", "2026-10-11T00:00:00Z//PT1H",
            "2026-10-11T00:00:00Z/PT1H/PT1H", "2026-10-11/PT1H", "2026-10-11T00:00:00/PT1H",
            "2026-10-11T00:00:00Z/1H", "2026-10-11T00:00:00Z/P32D", "2026-10-11T00:00:00Z/pt1h",
            "2026-10-11T00:00:00Z / PT1H", " 2026-10-11T00:00:00Z/PT1H", "2026-10-11T00:00:00Z/PT1H ",
            "2026-13-11T00:00:00Z/PT1H", "2026-10-11T00:00:00Z/PT1H\n",
            "PT1H/2026-10-11T00:00:00Z", "2026-10-11T00:00:00Z/2026-10-12T00:00:00Z",
        ]
        for s in bad {
            #expect(WxTime.parseInterval(s) == nil, "accepted \(s ?? "NULL")")
        }
        // length bound: whole interval <= 80 bytes, start part <= 40
        let longStart = "2026-10-11T00:00:00.12345678901234567890123456789012345Z/PT1H"
        #expect(WxTime.parseInterval(longStart) == nil)
        #expect(WxTime.parseInterval(bytes: [UInt8](repeating: UInt8(ascii: "/"), count: 300)) == nil)
        #expect(WxTime.parseInterval(bytes: [UInt8](repeating: UInt8(ascii: "x"), count: 300)) == nil)
    }

    // C: /core/time/duration-interval-fuzz (src/core/test-core.c:1967-2001)
    @Test func durationIntervalFuzz() {
        var rng = SeededRNG(seed: 99)
        let alphabet = timeBytes(#"PT0123456789DHMSYW.-+/:Z \n"#)
        #expect(alphabet.count == 26)  // sizeof alphabet - 1
        for _ in 0..<fuzzIterations(60_000) {
            let len = Int.random(in: 0..<60, using: &rng)
            let buf = (0..<len).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
            if let v = WxTime.parseDuration(bytes: buf) {
                #expect(v >= 0 && v <= WxTime.durationMaxSeconds)
            }
            if let iv = WxTime.parseInterval(bytes: buf) {
                #expect(iv.duration >= 1 && iv.duration <= WxTime.durationMaxSeconds)
            }
        }
        // structured mutation: valid durations with random single-character damage
        let base = Array("P1DT2H3M4S".utf8)
        for _ in 0..<fuzzIterations(20_000) {
            var buf = base
            buf[Int.random(in: 0..<base.count, using: &rng)] = alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
            if let v = WxTime.parseDuration(bytes: buf) {
                #expect(v >= 0 && v <= WxTime.durationMaxSeconds)
            }
        }
    }

    // Executor-added (CX2): the published bounds equal the C macros (wx-time.h:20-26).
    @Test func boundsMatchCMacros() {
        #expect(WxTime.iso8601MaxLength == 40)
        #expect(WxTime.durationMaxLength == 40)
        #expect(WxTime.intervalMaxLength == 80)
        #expect(WxTime.durationMaxSeconds == 31 * 86400)
    }
}
