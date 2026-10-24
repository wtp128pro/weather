// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Time.swift - strict, locale-independent parsers for the time formats the
// weather providers return (RFC 3339 timestamps, ISO 8601 durations and the
// NWS "start/duration" interval). Port of src/core/wx-time.{h,c}: the same
// inputs are accepted and rejected and the same Int64 values are returned.
//
// Common rules (wx-time.h:8-11): pure functions, no locale or time-zone
// database, never more than the documented bound + 1 bytes of the input are
// read. Input model (fidelity with NUL-terminated C strings): the input is
// read as UTF-8 bytes and ends at the first 0x00 byte or at the end of the
// collection, whichever comes first; `nil` behaves like a NULL pointer. A
// failed parse returns nil (the C out-parameters stay untouched).

/// Strict time parsers (port of src/core/wx-time.c).
public enum WxTime {
    /// Longest accepted timestamp, in bytes (WX_TIME_ISO8601_MAX_LEN, wx-time.h:20).
    public static let iso8601MaxLength = 40
    /// Longest accepted duration, in bytes (WX_TIME_DURATION_MAX_LEN, wx-time.h:22).
    public static let durationMaxLength = 40
    /// Longest accepted "start/duration" interval, in bytes (WX_TIME_INTERVAL_MAX_LEN, wx-time.h:24).
    public static let intervalMaxLength = 80
    /// Largest accepted duration: 31 days, in seconds (WX_TIME_DURATION_MAX_S, wx-time.h:26).
    public static let durationMaxSeconds: Int64 = 31 * 86400

    /// A parsed NWS "start/duration" interval.
    public struct Interval: Equatable, Hashable, Sendable {
        /// Start, UTC unix seconds.
        public let start: Int64
        /// Length in seconds, 1...WxTime.durationMaxSeconds.
        public let duration: Int64

        public init(start: Int64, duration: Int64) {
            self.start = start
            self.duration = duration
        }
    }

    // MARK: - Public API

    /// Parses the strict RFC 3339 profile `YYYY-MM-DDTHH:MM:SS[.f+](Z|+HH:MM|-HH:MM)`
    /// (wx_time_parse_iso8601, wx-time.c:122-171): upper-case 'T' and 'Z'; a
    /// fraction needs at least one digit and is truncated; year 2000...2100;
    /// the date must exist in the proleptic Gregorian calendar; hour 00...23,
    /// minute 00...59, second 00...59; offset at most 23:59; at most
    /// `iso8601MaxLength` bytes. Anything else is rejected.
    ///
    /// - Returns: the instant as UTC unix seconds (offset subtracted; it may
    ///   leave 2000...2100 by the offset), or nil.
    public static func parseISO8601<Bytes: Collection<UInt8>>(bytes: Bytes) -> Int64? {
        guard let s = terminated(bytes, maxLength: iso8601MaxLength) else {
            return nil
        }
        let len = s.count
        // "YYYY-MM-DDTHH:MM:SSZ" is the shortest valid form.
        if len < 20 {
            return nil
        }
        if s[4] != ascii("-") || s[7] != ascii("-") || s[10] != ascii("T") || s[13] != ascii(":")
            || s[16] != ascii(":")
        {
            return nil
        }
        guard let year = parseFixed(s, 0, 4), let month = parseFixed(s, 5, 2),
            let day = parseFixed(s, 8, 2), let hour = parseFixed(s, 11, 2),
            let minute = parseFixed(s, 14, 2), let second = parseFixed(s, 17, 2)
        else {
            return nil
        }
        if year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1
            || day > daysInMonth(year, month) || hour > 23 || minute > 59 || second > 59
        {
            return nil
        }

        var pos = 19
        if at(s, pos) == ascii(".") {
            pos += 1
            let first = pos
            while pos < len && isDigit(s[pos]) {
                pos += 1
            }
            if pos == first {
                return nil
            }
        }

        var offset: Int64 = 0
        let zone = at(s, pos)
        if zone == ascii("Z") {
            if pos + 1 != len {
                return nil
            }
        } else if zone == ascii("+") || zone == ascii("-") {
            guard len - pos == 6, at(s, pos + 3) == ascii(":"), let oh = parseFixed(s, pos + 1, 2),
                let om = parseFixed(s, pos + 4, 2), oh <= 23, om <= 59
            else {
                return nil
            }
            offset = Int64(oh * 3600 + om * 60)
            if zone == ascii("-") {
                offset = -offset
            }
        } else {
            return nil
        }

        return daysFromCivil(year, month, day) * 86400 + Int64(hour * 3600 + minute * 60 + second) - offset
    }

    /// `parseISO8601(bytes:)` of the UTF-8 bytes of `text`; nil for nil.
    public static func parseISO8601(_ text: String?) -> Int64? {
        guard let text else {
            return nil
        }
        return parseISO8601(bytes: text.utf8)
    }

    /// Parses `P[nD][T[nH][nM][nS]]` (wx_time_parse_iso8601_duration,
    /// wx-time.c:174-245): unsigned integers of 1...8 digits, upper-case
    /// designators in the order D, H, M, S; at least one component; a 'T'
    /// must be followed by at least one time component. Years, months, weeks,
    /// fractions, signs and whitespace are rejected; the total must not exceed
    /// `durationMaxSeconds`; zero ("PT0S") is accepted; at most
    /// `durationMaxLength` bytes.
    ///
    /// - Returns: the length in seconds, 0...durationMaxSeconds, or nil.
    public static func parseDuration<Bytes: Collection<UInt8>>(bytes: Bytes) -> Int64? {
        guard let s = terminated(bytes, maxLength: durationMaxLength) else {
            return nil
        }
        if at(s, 0) != ascii("P") {
            return nil
        }
        var p = 1
        var total: Int64 = 0
        var any = false
        var inTime = false
        var seenDays = false
        var lastRank = 0  // 1 = H, 2 = M, 3 = S

        while at(s, p) != 0 {
            if at(s, p) == ascii("T") {
                // Only one 'T', and it must be followed by a time component.
                if inTime || at(s, p + 1) == 0 {
                    return nil
                }
                inTime = true
                p += 1
                continue
            }
            var digits = 0
            var value: Int64 = 0
            while isDigit(at(s, p)) {
                digits += 1
                if digits > 8 {  // WX_DURATION_MAX_DIGITS: 8 digits * 86400 cannot overflow
                    return nil
                }
                value = value * 10 + Int64(at(s, p) - ascii("0"))
                p += 1
            }
            if digits == 0 {
                return nil
            }
            let unit = at(s, p)
            if unit == 0 {
                return nil
            }
            p += 1
            if !inTime {
                if unit != ascii("D") || seenDays {
                    return nil
                }
                seenDays = true
                total += value * 86400
            } else {
                let rank: Int
                let mult: Int64
                if unit == ascii("H") {
                    rank = 1
                    mult = 3600
                } else if unit == ascii("M") {
                    rank = 2
                    mult = 60
                } else if unit == ascii("S") {
                    rank = 3
                    mult = 1
                } else {
                    return nil
                }
                if rank <= lastRank {
                    return nil
                }
                lastRank = rank
                total += value * mult
            }
            any = true
            if total > durationMaxSeconds {
                return nil
            }
        }
        if !any {
            return nil
        }
        return total
    }

    /// `parseDuration(bytes:)` of the UTF-8 bytes of `text`; nil for nil.
    public static func parseDuration(_ text: String?) -> Int64? {
        guard let text else {
            return nil
        }
        return parseDuration(bytes: text.utf8)
    }

    /// Parses exactly one '/' separating `parseISO8601` and `parseDuration`
    /// text (wx_time_parse_interval, wx-time.c:248-275), at most
    /// `intervalMaxLength` bytes, the start part at most `iso8601MaxLength`.
    /// Unlike the plain duration parser, a zero duration is rejected.
    ///
    /// - Returns: start (UTC unix seconds) and duration (1...durationMaxSeconds), or nil.
    public static func parseInterval<Bytes: Collection<UInt8>>(bytes: Bytes) -> Interval? {
        guard let s = terminated(bytes, maxLength: intervalMaxLength) else {
            return nil
        }
        guard let slash = s.firstIndex(of: ascii("/")) else {
            return nil
        }
        if s[(slash + 1)...].contains(ascii("/")) {
            return nil
        }
        if slash > iso8601MaxLength {
            return nil
        }
        guard let start = parseISO8601(bytes: s[..<slash]),
            let duration = parseDuration(bytes: s[(slash + 1)...]), duration > 0
        else {
            return nil
        }
        return Interval(start: start, duration: duration)
    }

    /// `parseInterval(bytes:)` of the UTF-8 bytes of `text`; nil for nil.
    public static func parseInterval(_ text: String?) -> Interval? {
        guard let text else {
            return nil
        }
        return parseInterval(bytes: text.utf8)
    }

    // MARK: - Helpers (wx-time.c:10-119)

    /// The bytes before the terminator (the first 0x00 or the end of the
    /// collection), reading at most `maxLength` + 1 bytes; nil when there are
    /// more than `maxLength` bytes before the terminator (the C memchr over
    /// maxLength + 1 bytes found no NUL).
    private static func terminated<Bytes: Collection<UInt8>>(_ bytes: Bytes, maxLength: Int) -> [UInt8]? {
        let window = Array(bytes.prefix(maxLength + 1))
        if let nul = window.firstIndex(of: 0) {
            return Array(window[..<nul])
        }
        return window.count <= maxLength ? window : nil
    }

    /// The byte at `i`, or 0 (the C terminator) at or past the end.
    private static func at(_ s: [UInt8], _ i: Int) -> UInt8 {
        i < s.count ? s[i] : 0
    }

    private static func ascii(_ c: Unicode.Scalar) -> UInt8 {
        UInt8(c.value)
    }

    /// Locale-independent ASCII digit test.
    private static func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    /// Exactly `n` ASCII digits starting at `start` (parse_fixed), or nil.
    private static func parseFixed(_ s: [UInt8], _ start: Int, _ n: Int) -> Int? {
        var v = 0
        for i in start..<(start + n) {
            let c = at(s, i)
            if !isDigit(c) {
                return nil
            }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }

    private static func isLeapYear(_ y: Int) -> Bool {
        (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        let days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (m == 2 && isLeapYear(y)) ? 29 : days[m - 1]
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
    /// algorithm, days_from_civil, wx-time.c:108-118; Swift `/` truncates
    /// toward zero like C).
    private static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(year - (m <= 2 ? 1 : 0))
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = Int64((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
