// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FormatTests.swift - port of src/widgets/test-format.c (registered at
// test-format.c:1803-1841), of /widgets/icons-exist-in-theme
// (src/widgets/test-widgets.c:2791) and of the High/Low label texts of
// src/ui/test-detail.c. Expected values are the C test literals, cited as
// test-format.c:LINE (and test-detail.c:LINE). The C zone-cache mechanics
// (load counters, loader/clock hooks, the negative ring) have no Swift
// analogue; their result assertions are ported, the counters are not (see
// the U25 debrief). The process locale and TZ are never changed here: the
// suite is also run under de_DE (RUN_SUITE_LOCALE) for the locale cases.

import AppKit
import Foundation
import Testing
@testable import WeatherCore

@Suite struct FormatTests {
    /// DASH / DEG (test-format.c:18-19).
    static let dash = "\u{2014}"
    static let deg = "\u{00B0}"
    /// NY (test-format.c:53).
    static let ny = "America/New_York"

    /// ts (test-format.c:45-51): UTC unix seconds of a civil date-time
    /// (days_from_civil, independent of the code under test).
    static func ts(_ y: Int64, _ mo: Int64, _ d: Int64, _ h: Int64, _ mi: Int64, _ s: Int64) -> Int64 {
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return days * 86400 + h * 3600 + mi * 60 + s
    }

    /// NOW_S (test-format.c:706): 2 PM EDT, a Sunday.
    static let nowS = ts(2026, 10, 11, 18, 0, 0)

    /// outlook (test-format.c:708-714).
    static func outlook(
        _ state: WxRainState, _ start: Int64, _ end: Int64, _ known: Bool, _ peak: Int64, _ mm: Double, _ prob: Double
    ) -> WxRainOutlook {
        WxRainOutlook(state: state, startS: start, endS: end, peakS: peak, peakMmH: mm, peakProb: prob, endsKnown: known)
    }

    /// cloud_hour (test-format.c:949-957).
    static func cloudHour(_ t: Int64, _ cloud: Double) -> WxBlendHour {
        WxBlendHour(tS: t, cloudPct: cloud, nMembers: 1, condition: .unknown, isDay: true)
    }

    /// make_forecast (test-format.c:960-975): Miami, zone NY, generated at NOW_S.
    static func makeForecast(_ t0: Int64, _ cloud: [Double]) throws -> WxForecast {
        let place = try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US", lat: 25.76, lon: -80.19,
            timezone: ny)
        let hours = cloud.enumerated().map { cloudHour(t0 + Int64($0.offset) * 3600, $0.element) }
        return try WxForecast(place: place, generatedS: nowS, hours: hours)
    }

    // MARK: - numbers

    // C: /format/temp
    @Test("/format/temp") func temp() {
        let d = Self.deg, x = Self.dash
        // test-format.c:66-83
        let t: [(Double, String, String, String, String)] = [
            (0, "32\(d)", "32\(d)F", "0\(d)", "0\(d)C"),
            (25, "77\(d)", "77\(d)F", "25\(d)", "25\(d)C"),
            (-40, "-40\(d)", "-40\(d)F", "-40\(d)", "-40\(d)C"),
            (24.5, "76\(d)", "76\(d)F", "25\(d)", "25\(d)C"),
            (24.4, "76\(d)", "76\(d)F", "24\(d)", "24\(d)C"),
            (-0.4, "31\(d)", "31\(d)F", "0\(d)", "0\(d)C"),
            (-0.5, "31\(d)", "31\(d)F", "-1\(d)", "-1\(d)C"),
            (-0.0, "32\(d)", "32\(d)F", "0\(d)", "0\(d)C"),
            (-17.7778, "0\(d)", "0\(d)F", "-18\(d)", "-18\(d)C"),
            (-18.0, "0\(d)", "0\(d)F", "-18\(d)", "-18\(d)C"),
            (70.0, "158\(d)", "158\(d)F", "70\(d)", "70\(d)C"),
            (-100.0, "-148\(d)", "-148\(d)F", "-100\(d)", "-100\(d)C"),
            (70.0001, x, x, x, x),
            (-100.0001, x, x, x, x),
            (.nan, x, x, x, x),
            (.infinity, x, x, x, x),
            (-.infinity, x, x, x, x),
            (1e300, x, x, x, x),
        ]
        for r in t {
            #expect(WxFormat.temp(r.0, units: .imperial, withUnit: false) == r.1, "\(r.0)")
            #expect(WxFormat.temp(r.0, units: .imperial, withUnit: true) == r.2, "\(r.0)")
            #expect(WxFormat.temp(r.0, units: .metric, withUnit: false) == r.3, "\(r.0)")
            #expect(WxFormat.temp(r.0, units: .metric, withUnit: true) == r.4, "\(r.0)")
        }
    }

    // C: /format/wind
    @Test("/format/wind") func wind() {
        let x = Self.dash
        // test-format.c:102-113
        let t: [(Double, String, String)] = [
            (0, "0 mph", "0 km/h"), (0.4, "0 mph", "0 km/h"), (0.5, "0 mph", "1 km/h"), (1.0, "1 mph", "1 km/h"),
            (19.3, "12 mph", "19 km/h"), (100, "62 mph", "100 km/h"), (500, "311 mph", "500 km/h"),
            (500.0001, x, x), (-0.0001, x, x), (.nan, x, x), (.infinity, x, x), (-.infinity, x, x),
        ]
        for r in t {
            #expect(WxFormat.wind(r.0, units: .imperial) == r.1, "\(r.0)")
            #expect(WxFormat.wind(r.0, units: .metric) == r.2, "\(r.0)")
        }
    }

    // C: /format/precip
    @Test("/format/precip") func precip() {
        let x = Self.dash
        // test-format.c:129-145
        let t: [(Double, String, String)] = [
            (0, "0 in", "0 mm"), (-0.0, "0 in", "0 mm"), (0.04, "<0.01 in", "<0.1 mm"), (0.1, "<0.01 in", "0.1 mm"),
            (0.2, "0.01 in", "0.2 mm"), (2.5, "0.10 in", "2.5 mm"), (6.35, "0.25 in", "6.3 mm"),
            (25.3, "1.0 in", "25.3 mm"), (25.4, "1.0 in", "25.4 mm"), (24.9, "0.98 in", "24.9 mm"),
            (38.1, "1.5 in", "38.1 mm"), (100, "3.9 in", "100.0 mm"), (12000, "472.4 in", "12000.0 mm"),
            (12000.0001, x, x), (-0.0001, x, x), (.nan, x, x), (.infinity, x, x),
        ]
        for r in t {
            #expect(WxFormat.precip(r.0, units: .imperial) == r.1, "\(r.0)")
            #expect(WxFormat.precip(r.0, units: .metric) == r.2, "\(r.0)")
        }
        // a positive amount is never printed as zero (test-format.c:152-158)
        var mm = 0.0001
        while mm < 0.3 {
            #expect(!WxFormat.precip(mm, units: .imperial).hasPrefix("0.00"), "\(mm)")
            #expect(!WxFormat.precip(mm, units: .metric).hasPrefix("0.0 "), "\(mm)")
            mm += 0.0001
        }
    }

    // C: /format/percent
    @Test("/format/percent") func percent() {
        // test-format.c:164-174
        #expect(WxFormat.percent(0) == "0%")
        #expect(WxFormat.percent(-0.0) == "0%")
        #expect(WxFormat.percent(40.4) == "40%")
        #expect(WxFormat.percent(40.5) == "41%")
        #expect(WxFormat.percent(99.5) == "100%")
        #expect(WxFormat.percent(100) == "100%")
        #expect(WxFormat.percent(100.0001) == Self.dash)
        #expect(WxFormat.percent(-0.0001) == Self.dash)
        #expect(WxFormat.percent(.nan) == Self.dash)
        #expect(WxFormat.percent(.infinity) == Self.dash)
        #expect(WxFormat.percent(-.infinity) == Self.dash)
    }

    // C: /format/locale-independent (setlocale is not called: the suite runs
    // under the process locale, and RUN_SUITE_LOCALE=de_DE runs it with a
    // decimal comma)
    @Test("/format/locale-independent") func localeIndependent() {
        // test-format.c:185-190
        #expect(WxFormat.precip(6.35, units: .imperial) == "0.25 in")
        #expect(WxFormat.precip(2.5, units: .metric) == "2.5 mm")
        #expect(WxFormat.temp(1234.0 / 100.0, units: .metric, withUnit: true) == "12\(Self.deg)C")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 19, 0, 0), timezone: Self.ny) == "3 PM")
        #expect(WxFormat.clock(Self.ts(2026, 10, 11, 19, 45, 0), timezone: Self.ny) == "3:45 PM")
        #expect(WxFormat.weekday(Self.ts(2026, 10, 11, 19, 0, 0), timezone: "UTC", nowS: 0) == "Sunday")
    }

    // MARK: - times

    // C: /format/hour-label-and-clock
    @Test("/format/hour-label-and-clock") func hourLabelAndClock() {
        let ny = Self.ny
        let t = Self.ts(2026, 10, 11, 19, 0, 0)  // test-format.c:202
        // test-format.c:203-215
        #expect(WxFormat.hourLabel(t, timezone: ny) == "3 PM")
        #expect(WxFormat.clock(t, timezone: ny) == "3:00 PM")
        #expect(WxFormat.clock(t + 45 * 60, timezone: ny) == "3:45 PM")
        #expect(WxFormat.hourLabel(t + 45 * 60, timezone: ny) == "3:45 PM")
        #expect(WxFormat.hourLabel(t + 59, timezone: ny) == "3 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 4, 0, 0), timezone: ny) == "12 AM")
        #expect(WxFormat.clock(Self.ts(2026, 10, 11, 4, 5, 0), timezone: ny) == "12:05 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 16, 0, 0), timezone: ny) == "12 PM")
        #expect(WxFormat.clock(Self.ts(2026, 10, 11, 16, 0, 0), timezone: ny) == "12:00 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 15, 59, 59), timezone: ny) == "11:59 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 15, 0, 59), timezone: ny) == "11 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 17, 0, 0), timezone: ny) == "1 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 12, 3, 59, 0), timezone: ny) == "11:59 PM")
        // DST (test-format.c:218-222)
        #expect(WxFormat.clock(Self.ts(2026, 3, 8, 6, 59, 59), timezone: ny) == "1:59 AM")
        #expect(WxFormat.clock(Self.ts(2026, 3, 8, 7, 0, 0), timezone: ny) == "3:00 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 11, 1, 5, 0, 0), timezone: ny) == "1 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 11, 1, 6, 0, 0), timezone: ny) == "1 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 11, 1, 7, 0, 0), timezone: ny) == "2 AM")
        // other zones (test-format.c:225-231)
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 0, 0, 0), timezone: "Australia/Sydney") == "11 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 12, 0, 0), timezone: "Europe/London") == "1 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 1, 11, 12, 0, 0), timezone: "Europe/London") == "12 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 18, 0, 0), timezone: "Asia/Kolkata") == "11:30 PM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 0, 0, 0), timezone: "Asia/Kathmandu") == "5:45 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 12, 0, 0), timezone: "Etc/GMT+5") == "7 AM")
        #expect(WxFormat.hourLabel(Self.ts(2026, 10, 11, 12, 0, 0), timezone: "Pacific/Kiritimati") == "2 AM")
        // UTC for NULL, "", unknown, wrongly shaped and non-zone names (test-format.c:234-241); "\xff\xfe"
        // is not a Swift String, so it goes through the byte initialiser
        let utcNames: [String?] = [
            nil, "", "UTC", "Nowhere/Land", "/etc/passwd", "../x", "a//b", "America/", "/America/New_York", ".",
            "..", "-x", "9x", "A b", "America/New_York\n", "America", "leapseconds", "posix", "America/New_York/x",
            "SECURITY", "Japan", "EST5EDT", "Etc",
        ]
        for name in utcNames {
            #expect(WxFormat.hourLabel(t, timezone: name) == "7 PM", "\(name ?? "nil")")
            #expect(WxFormat.clock(t, timezone: name) == "7:00 PM", "\(name ?? "nil")")
        }
        let ff = WxFormat.Zone(timezoneBytes: [0xFF, 0xFE])
        #expect(WxFormat.hourLabel(t, zone: ff) == "7 PM")
        #expect(WxFormat.clock(t, zone: ff) == "7:00 PM")
        // test-format.c:242-245: 65 bytes is one too many; 64 is shaped but unknown
        #expect(WxFormat.hourLabel(t, timezone: String(repeating: "A", count: 65)) == "7 PM")
        #expect(WxFormat.hourLabel(t, timezone: String(repeating: "A", count: 64)) == "7 PM")
        // the valid range is [WX_TIME_MIN_S, WX_TIME_MAX_S) (test-format.c:248-256)
        #expect(WxFormat.hourLabel(WxLimits.timeMinS - 1, timezone: ny) == Self.dash)
        #expect(WxFormat.hourLabel(WxLimits.timeMaxS, timezone: ny) == Self.dash)
        #expect(WxFormat.hourLabel(.min, timezone: ny) == Self.dash)
        #expect(WxFormat.hourLabel(.max, timezone: ny) == Self.dash)
        #expect(WxFormat.hourLabel(0, timezone: ny) == Self.dash)
        #expect(WxFormat.clock(.min, timezone: ny) == Self.dash)
        #expect(WxFormat.clock(WxLimits.timeMaxS, timezone: nil) == Self.dash)
        #expect(WxFormat.clock(WxLimits.timeMinS, timezone: "UTC") == "12:00 AM")
        #expect(WxFormat.clock(WxLimits.timeMaxS - 1, timezone: "UTC") == "11:59 PM")
    }

    // C: /format/tz-read-bound (no guard page in Swift: the name is a byte
    // array of exactly 65 bytes without a NUL, read through the zone rule)
    @Test("/format/tz-read-bound") func tzReadBound() {
        let n = WxLimits.placeTimezoneMax + 1
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        for first in 1..<256 {
            var buf = [UInt8](repeating: UInt8(ascii: "A"), count: n)
            buf[0] = UInt8(first)
            let zone = WxFormat.Zone(timezoneBytes: buf)
            // test-format.c:277-294
            #expect(WxFormat.hourLabel(t, zone: zone) == "7 PM", "\(first)")
            #expect(WxFormat.clock(t, zone: zone) == "7:00 PM", "\(first)")
            #expect(WxFormat.weekday(t, zone: zone, nowS: t) == "Today", "\(first)")
            var o = WxRainOutlook(state: .now, endS: t + 7200, endsKnown: true)
            #expect(WxFormat.rainHeadline(o, nowS: t, zone: zone) == "Raining now, easing around 9 PM", "\(first)")
            o.peakS = t + 3600
            o.peakMmH = 1.0
            o.peakProb = .nan
            #expect(WxFormat.rainDetail(o, nowS: t, zone: zone) == "Light rain, heaviest around 8 PM.", "\(first)")
            let h0 = t - 1800 - (t - 1800) % 3600
            let hs = [Self.cloudHour(h0, 70), Self.cloudHour(h0 + 3600, 10)]
            #expect(
                WxFormat.cloudSentence(hours: hs, lat: 0, lon: 0, nowS: t - 600, zone: zone)
                    == "Mostly clear now, clearing around 7 PM", "\(first)")
        }
        // a name that ends with a NUL inside the window is read up to the NUL only (test-format.c:297-301)
        var buf = Array(Self.ny.utf8) + [0]
        buf += [UInt8](repeating: UInt8(ascii: "x"), count: n - buf.count)
        #expect(WxFormat.hourLabel(t, zone: WxFormat.Zone(timezoneBytes: buf)) == "3 PM")
    }

    // C: /format/zone-rule-table
    @Test("/format/zone-rule-table") func zoneRuleTable() {
        let winter = Self.ts(2026, 7, 11, 12, 0, 0)  // test-format.c:310
        let summer = Self.ts(2026, 10, 11, 12, 0, 0)  // test-format.c:311
        // test-format.c:317-346
        let t: [(String?, Int64, Int64)] = [
            ("America/New_York", -4 * 3600, -4 * 3600), ("Asia/Kolkata", 19800, 19800),
            ("Australia/Lord_Howe", 11 * 3600, 10 * 3600 + 1800), ("Australia/Sydney", 11 * 3600, 10 * 3600),
            ("Asia/Kathmandu", 20700, 20700), ("Etc/GMT+5", -5 * 3600, -5 * 3600), ("UTC", 0, 0), (nil, 0, 0),
            ("", 0, 0), ("Japan", 0, 0), ("Singapore", 0, 0), ("EST5EDT", 0, 0), ("Zulu", 0, 0),
            ("leapseconds", 0, 0), ("tzdata.zi", 0, 0), ("utc", 0, 0), ("Etc", 0, 0), ("../x", 0, 0),
            ("/etc/passwd", 0, 0), ("America/New_York/", 0, 0), ("America//New_York", 0, 0),
            ("America/../New_York", 0, 0), ("America/.New_York", 0, 0), ("America/9x", 0, 0),
            (" America/New_York", 0, 0), ("America/New York", 0, 0), ("Nowhere/Land", 0, 0),
        ]
        for r in t {
            for k in 0..<2 {
                let instant = k == 1 ? winter : summer
                let local = instant + (k == 1 ? r.2 : r.1)  // what the clock shows (test-format.c:352-356)
                let sod = ((local % 86400) + 86400) % 86400
                let h = sod / 3600, m = sod % 3600 / 60
                let expect = "\(h % 12 == 0 ? 12 : h % 12):\(m < 10 ? "0" : "")\(m) \(h < 12 ? "AM" : "PM")"
                #expect(WxFormat.clock(instant, timezone: r.0) == expect, "zone '\(r.0 ?? "(null)")' at \(instant)")
            }
        }
        // spot values written out by hand (test-format.c:364-370)
        #expect(WxFormat.clock(summer, timezone: "Australia/Lord_Howe") == "11:00 PM")
        #expect(WxFormat.clock(winter, timezone: "Australia/Lord_Howe") == "10:30 PM")
        #expect(WxFormat.clock(summer, timezone: "Asia/Kolkata") == "5:30 PM")
        #expect(WxFormat.clock(summer, timezone: "Japan") == "12:00 PM")
        #expect(WxFormat.clock(summer, timezone: "Singapore") == "12:00 PM")
        #expect(WxFormat.clock(summer, timezone: "EST5EDT") == "12:00 PM")
        #expect(WxFormat.clock(summer, timezone: "leapseconds") == "12:00 PM")
    }

    // C: /format/zone-cache, /format/zone-cache-is-lru (the results; the load
    // counters are GLib-cache mechanics, see the debrief)
    @Test("/format/zone-cache and /format/zone-cache-is-lru (results)") func zoneCacheResults() {
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        #expect(WxFormat.hourLabel(t, timezone: "Africa/Nairobi") == "10 PM")  // test-format.c:389
        for _ in 0..<5 {
            #expect(WxFormat.hourLabel(t, timezone: "Mars/Olympus") == "7 PM")  // test-format.c:404
        }
        for i in 1...8 {
            _ = WxFormat.hourLabel(t, timezone: "Etc/GMT+\(i)")
        }
        #expect(WxFormat.hourLabel(t, timezone: "Africa/Nairobi") == "10 PM")  // test-format.c:416
        #expect(WxFormat.hourLabel(t, timezone: "Etc/GMT+8") == "11 AM")  // test-format.c:419
        #expect(WxFormat.hourLabel(t, timezone: "Etc/GMT+1") == "6 PM")  // test-format.c:420
        #expect(WxFormat.hourLabel(t, timezone: "Etc/GMT+4") == "3 PM")  // test-format.c:1701
        #expect(WxFormat.hourLabel(t, timezone: "Etc/GMT+5") == "2 PM")  // test-format.c:1703
    }

    // C: /format/local-day-end
    @Test("/format/local-day-end") func localDayEnd() {
        let ny = Self.ny
        let ts = Self.ts
        // test-format.c:427-446
        #expect(WxFormat.localDayEnd(ts(2026, 10, 11, 18, 0, 0), timezone: ny) == ts(2026, 10, 12, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 12, 3, 59, 59), timezone: ny) == ts(2026, 10, 12, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 12, 4, 0, 0), timezone: ny) == ts(2026, 10, 13, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 11, 1, 12, 0, 0), timezone: ny) == ts(2026, 11, 2, 5, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 3, 8, 12, 0, 0), timezone: ny) == ts(2026, 3, 9, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 11, 18, 0, 0), timezone: nil) == ts(2026, 10, 12, 0, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 11, 18, 0, 0), timezone: "Japan") == ts(2026, 10, 12, 0, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 11, 18, 0, 0), timezone: "Asia/Kolkata") == ts(2026, 10, 11, 18, 30, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 3, 7, 12, 0, 0), timezone: "America/Havana") == ts(2026, 3, 8, 5, 0, 0))
        #expect(WxFormat.localDayEnd(WxLimits.timeMinS, timezone: "UTC") == WxLimits.timeMinS + 86400)
        #expect(WxFormat.localDayEnd(WxLimits.timeMaxS - 1, timezone: "UTC") == WxLimits.timeMaxS)
        #expect(WxFormat.localDayEnd(WxLimits.timeMinS - 1, timezone: ny) == 0)
        #expect(WxFormat.localDayEnd(WxLimits.timeMaxS, timezone: ny) == 0)
        #expect(WxFormat.localDayEnd(0, timezone: ny) == 0)
        #expect(WxFormat.localDayEnd(.min, timezone: ny) == 0)
        #expect(WxFormat.localDayEnd(.max, timezone: nil) == 0)
    }

    /// next_day_length (test-format.c:450-455).
    static func nextDayLength(_ tz: String, _ insidePrevDay: Int64) -> Int64 {
        let start = WxFormat.localDayEnd(insidePrevDay, timezone: tz)
        return WxFormat.localDayEnd(start, timezone: tz) - start
    }

    // C: /format/local-day-end/day-lengths
    @Test("/format/local-day-end/day-lengths") func localDayLengths() {
        let ts = Self.ts
        // test-format.c:461-471
        #expect(Self.nextDayLength(Self.ny, ts(2026, 3, 7, 12, 0, 0)) == 23 * 3600)
        #expect(Self.nextDayLength(Self.ny, ts(2026, 10, 31, 12, 0, 0)) == 25 * 3600)
        #expect(Self.nextDayLength(Self.ny, ts(2026, 5, 1, 12, 0, 0)) == 24 * 3600)
        #expect(Self.nextDayLength("Antarctica/Troll", ts(2026, 3, 28, 12, 0, 0)) == 22 * 3600)
        #expect(Self.nextDayLength("Antarctica/Troll", ts(2026, 10, 24, 12, 0, 0)) == 26 * 3600)
        #expect(Self.nextDayLength("Australia/Lord_Howe", ts(2026, 4, 4, 12, 0, 0)) == 24 * 3600 + 1800)
        #expect(Self.nextDayLength("Australia/Lord_Howe", ts(2026, 10, 3, 12, 0, 0)) == 23 * 3600 + 1800)
        #expect(Self.nextDayLength("Pacific/Apia", ts(2011, 12, 28, 20, 0, 0)) == 24 * 3600)
        #expect(WxFormat.localDayEnd(ts(2011, 12, 29, 20, 0, 0), timezone: "Pacific/Apia") == ts(2011, 12, 30, 10, 0, 0))
        #expect(Self.nextDayLength("Pacific/Apia", ts(2011, 12, 29, 20, 0, 0)) == 24 * 3600)
    }

    // C: /format/local-day-end/repeated-midnight
    @Test("/format/local-day-end/repeated-midnight") func localDayEndRepeatedMidnight() {
        let ts = Self.ts
        let az = "Atlantic/Azores", hv = "America/Havana", sj = "America/St_Johns"
        // test-format.c:481-502
        #expect(WxFormat.localDayEnd(ts(2026, 10, 24, 12, 0, 0), timezone: az) == ts(2026, 10, 25, 0, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 24, 0, 0, 0), timezone: az) == ts(2026, 10, 25, 0, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 24, 23, 59, 59), timezone: az) == ts(2026, 10, 25, 0, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 25, 0, 0, 0), timezone: az) == ts(2026, 10, 26, 1, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 25, 0, 30, 0), timezone: az) == ts(2026, 10, 26, 1, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 25, 1, 30, 0), timezone: az) == ts(2026, 10, 26, 1, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 31, 12, 0, 0), timezone: hv) == ts(2026, 11, 1, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 10, 31, 16, 0, 0), timezone: hv) == ts(2026, 11, 1, 4, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2007, 11, 3, 12, 0, 0), timezone: sj) == ts(2007, 11, 4, 2, 30, 0))
        #expect(WxFormat.localDayEnd(ts(2007, 11, 4, 2, 30, 0), timezone: sj) == ts(2007, 11, 5, 3, 30, 0))
        #expect(WxFormat.localDayEnd(ts(2007, 11, 4, 2, 30, 59), timezone: sj) == ts(2007, 11, 5, 3, 30, 0))
        #expect(WxFormat.localDayEnd(ts(2007, 11, 4, 2, 40, 0), timezone: sj) == ts(2007, 11, 4, 3, 30, 0))
        #expect(WxFormat.localDayEnd(ts(2026, 3, 7, 12, 0, 0), timezone: hv) == ts(2026, 3, 8, 5, 0, 0))
        #expect(WxFormat.localDayEnd(ts(2011, 12, 30, 9, 0, 0), timezone: "Pacific/Apia") == ts(2011, 12, 30, 10, 0, 0))
    }

    /// The local date (days since 1970) at `t` from Foundation's offset only.
    static func bruteDate(_ z: TimeZone, _ t: Int64) -> Int64 {
        let local = t + Int64(z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))))
        return local >= 0 ? local / 86400 : (local - 86399) / 86400
    }

    /// brute_day_end (test-format.c:510-531): the first instant after `t`
    /// whose local date is later, by a one-minute scan and a bisection of
    /// the last minute. Independent of the production code.
    static func bruteDayEnd(_ z: TimeZone, _ t: Int64) -> Int64? {
        let date = bruteDate(z, t)
        var c = t + 60
        while c - t < 4 * 86400 {
            if bruteDate(z, c) > date {
                var lo = c - 60, hi = c
                while hi - lo > 1 {
                    let mid = lo + (hi - lo) / 2
                    if bruteDate(z, mid) > date { hi = mid } else { lo = mid }
                }
                return hi
            }
            c += 60
        }
        return nil
    }

    /// One zone of /format/local-day-end/all-zones: mismatches as text.
    static func allZonesCheck(_ name: String) -> (checked: Int, failures: [String]) {
        let zone = WxFormat.Zone(timezone: name)
        guard zone.resolved, let z = TimeZone(identifier: name) else {
            return (0, [])
        }
        // test-format.c:584-593
        var offs: [Int64] = stride(from: -30, through: 30, by: 6).map { Int64($0) * 3600 }
        offs += [-1, 1, -3600, 3600, -13 * 3600, 13 * 3600]
        // test-format.c:601-602
        let spans: [(Int64, Int64)] = [(1_767_225_600, 1_830_297_600), (1_167_609_600, 1_199_145_600), (1_322_697_600, 1_328_054_400)]
        var checked = 0
        var failures: [String] = []
        for sp in spans {
            var prev = z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(sp.0)))
            var c = sp.0 + 3600
            while c < sp.1 {
                let off = z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(c)))
                if off != prev {
                    prev = off
                    var lo = c - 3600, hi = c  // bisect the transition to the second
                    while hi - lo > 1 {
                        let mid = lo + (hi - lo) / 2
                        if z.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(mid))) == off { hi = mid } else { lo = mid }
                    }
                    for k in offs {
                        let t = hi + k
                        let want = bruteDayEnd(z, t)
                        let got = WxFormat.localDayEnd(t, zone: zone)
                        if got != want {
                            failures.append("zone \(name) t=\(t) (transition \(hi)): got \(got) want \(want.map(String.init) ?? "none")")
                        }
                        checked += 1
                    }
                }
                c += 3600
            }
        }
        return (checked, failures)
    }

    // C: /format/local-day-end/all-zones (every Area/Location zone that
    // Foundation knows instead of the files of /usr/share/zoneinfo; offset
    // changes found from Foundation's offsets instead of GLib's intervals)
    @Test("/format/local-day-end/all-zones") func localDayEndAllZones() async {
        let names = TimeZone.knownTimeZoneIdentifiers.filter { WxDaily.lookedUpName(Array($0.utf8)) != nil }.sorted()
        #expect(names.count >= 100, "no zone database")
        let results = await withTaskGroup(of: (Int, [String]).self) { group in
            for name in names {
                group.addTask { Self.allZonesCheck(name) }
            }
            var all: [(Int, [String])] = []
            for await r in group {
                all.append(r)
            }
            return all
        }
        let checked = results.reduce(0) { $0 + $1.0 }
        let failures = results.flatMap(\.1)
        #expect(checked > 0)
        #expect(failures.isEmpty, "\(failures.count) mismatches, first: \(failures.prefix(5))")
    }

    // C: /format/weekday
    @Test("/format/weekday") func weekday() {
        let ny = Self.ny
        let ts = Self.ts
        let now = ts(2026, 10, 11, 12, 0, 0)  // test-format.c:639
        // test-format.c:640-648
        #expect(WxFormat.weekday(now, timezone: ny, nowS: now) == "Today")
        #expect(WxFormat.weekday(ts(2026, 10, 12, 3, 59, 59), timezone: ny, nowS: now) == "Today")
        #expect(WxFormat.weekday(ts(2026, 10, 12, 4, 0, 0), timezone: ny, nowS: now) == "Tomorrow")
        #expect(WxFormat.weekday(ts(2026, 10, 13, 3, 59, 59), timezone: ny, nowS: now) == "Tomorrow")
        #expect(WxFormat.weekday(ts(2026, 10, 13, 4, 0, 0), timezone: ny, nowS: now) == "Tuesday")
        #expect(WxFormat.weekday(ts(2026, 10, 17, 12, 0, 0), timezone: ny, nowS: now) == "Saturday")
        #expect(WxFormat.weekday(ts(2026, 10, 18, 12, 0, 0), timezone: ny, nowS: now) == "Sunday")
        #expect(WxFormat.weekday(ts(2026, 10, 10, 12, 0, 0), timezone: ny, nowS: now) == "Saturday")
        #expect(WxFormat.weekday(ts(2026, 10, 9, 12, 0, 0), timezone: ny, nowS: now) == "Friday")
        // the zone, not UTC, decides (test-format.c:650-654)
        let late = ts(2026, 10, 12, 2, 0, 0)
        let next = ts(2026, 10, 12, 5, 0, 0)
        #expect(WxFormat.weekday(next, timezone: ny, nowS: late) == "Tomorrow")
        #expect(WxFormat.weekday(next, timezone: "UTC", nowS: late) == "Today")
        #expect(WxFormat.weekday(next, timezone: nil, nowS: late) == "Today")
        // test-format.c:656-660
        #expect(WxFormat.weekday(ts(2027, 1, 1, 12, 0, 0), timezone: "UTC", nowS: ts(2026, 12, 31, 12, 0, 0)) == "Tomorrow")
        #expect(WxFormat.weekday(ts(2026, 11, 1, 12, 0, 0), timezone: "UTC", nowS: ts(2026, 10, 31, 23, 0, 0)) == "Tomorrow")
        #expect(WxFormat.weekday(ts(2028, 2, 29, 12, 0, 0), timezone: "UTC", nowS: ts(2028, 2, 28, 12, 0, 0)) == "Tomorrow")
        #expect(WxFormat.weekday(ts(2028, 3, 1, 12, 0, 0), timezone: "UTC", nowS: ts(2028, 2, 28, 12, 0, 0)) == "Wednesday")
        #expect(WxFormat.weekday(ts(2027, 3, 1, 12, 0, 0), timezone: "UTC", nowS: ts(2027, 2, 28, 12, 0, 0)) == "Tomorrow")
        // every weekday name (test-format.c:662-664)
        let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        for i in 0..<7 {
            #expect(WxFormat.weekday(ts(2026, 10, 12 + Int64(i), 12, 0, 0), timezone: "UTC", nowS: 0) == days[i])
        }
        // bad now: weekday names only; bad t: dash (test-format.c:666-671)
        #expect(WxFormat.weekday(now, timezone: ny, nowS: 0) == "Sunday")
        #expect(WxFormat.weekday(now, timezone: ny, nowS: WxLimits.timeMaxS) == "Sunday")
        #expect(WxFormat.weekday(now, timezone: ny, nowS: .min) == "Sunday")
        #expect(WxFormat.weekday(0, timezone: ny, nowS: now) == Self.dash)
        #expect(WxFormat.weekday(WxLimits.timeMaxS, timezone: ny, nowS: now) == Self.dash)
        #expect(WxFormat.weekday(.max, timezone: ny, nowS: now) == Self.dash)
    }

    // C: /format/updated
    @Test("/format/updated") func updated() {
        // test-format.c:681-696
        let t: [(Int64, String)] = [
            (.min, "Updated just now"), (-1, "Updated just now"), (0, "Updated just now"), (59, "Updated just now"),
            (60, "Updated 1 min ago"), (119, "Updated 1 min ago"), (5 * 60, "Updated 5 min ago"),
            (3599, "Updated 59 min ago"), (3600, "Updated 1 h ago"), (2 * 3600 + 59, "Updated 2 h ago"),
            (86399, "Updated 23 h ago"), (86400, "Updated 1 day ago"), (2 * 86400, "Updated 2 days ago"),
            (29 * 86400 + 86399, "Updated 29 days ago"), (30 * 86400, "Updated over a month ago"),
            (.max, "Updated over a month ago"),
        ]
        for r in t {
            #expect(WxFormat.updated(ageS: r.0) == r.1, "\(r.0)")
        }
    }

    // MARK: - rain headline / detail

    // C: /format/headline/dry
    @Test("/format/headline/dry") func headlineDry() {
        let o = Self.outlook(.dry, 0, 0, false, 0, .nan, .nan)
        // test-format.c:720-722
        #expect(WxFormat.rainHeadline(o, nowS: Self.nowS, timezone: Self.ny) == "No rain expected for the next 48 hours")
        #expect(WxFormat.rainHeadline(o, nowS: 0, timezone: Self.ny) == "No rain expected for the next 48 hours")
        #expect(WxFormat.rainHeadline(o, nowS: .max, timezone: nil) == "No rain expected for the next 48 hours")
    }

    // C: /format/headline/now
    @Test("/format/headline/now") func headlineNow() {
        let ny = Self.ny, now = Self.nowS, ts = Self.ts
        var o = Self.outlook(.now, now - 600, now + 90 * 60, true, now, 1, 80)
        // test-format.c:730-766
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing around 3:30 PM")
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: "UTC") == "Raining now, easing around 7:30 PM")
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: nil) == "Raining now, easing around 7:30 PM")
        o.endS = now + 2 * 3600
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing around 4 PM")
        o.endS = now + 1
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing around 2 PM")
        o.endS = ts(2026, 10, 12, 7, 0, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing tomorrow around 3 AM")
        o.endS = ts(2026, 10, 13, 20, 0, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing Tuesday around 4 PM")
        o.endS = ts(2026, 10, 12, 3, 59, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing around 11:59 PM")
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: "UTC") == "Raining now, easing tomorrow around 3:59 AM")
        o.endsKnown = false
        o.endS = 0
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, expected to continue for hours")
        o.endS = now + 3600
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, expected to continue for hours")
        o.endsKnown = true
        o.endS = now
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing soon")
        o.endS = now - 5000
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now, easing soon")
        o.endS = 0
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now")
        o.endS = .max
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now")
        o.endS = WxLimits.timeMaxS
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Raining now")
        o.endS = now + 3600
        #expect(WxFormat.rainHeadline(o, nowS: 0, timezone: ny) == "Rain outlook unavailable")
        #expect(WxFormat.rainHeadline(o, nowS: WxLimits.timeMaxS, timezone: ny) == "Rain outlook unavailable")
        #expect(WxFormat.rainHeadline(o, nowS: WxLimits.timeMinS - 1, timezone: ny) == "Rain outlook unavailable")
    }

    // C: /format/headline/expected
    @Test("/format/headline/expected") func headlineExpected() {
        let ny = Self.ny, now = Self.nowS, ts = Self.ts
        var o = Self.outlook(.expected, now + 25 * 60, now + 3 * 3600, true, now + 3600, 2, 70)
        // test-format.c:774-810
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting in 25 minutes")
        for s: Int64 in [1, 59, 60] {
            o.startS = now + s
            #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting in 1 minute", "\(s)")
        }
        o.startS = now + 61
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting in 2 minutes")
        o.startS = now + 89 * 60
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting in 89 minutes")
        o.startS = now + 90 * 60 - 1
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting in 90 minutes")
        o.startS = now + 90 * 60
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected around 3:30 PM")
        o.startS = now + 2 * 3600
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected around 4 PM")
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: "UTC") == "Rain expected around 8 PM")
        o.startS = ts(2026, 10, 12, 20, 0, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected tomorrow around 4 PM")
        o.startS = ts(2026, 10, 13, 20, 0, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected Tuesday around 4 PM")
        o.startS = now
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting now")
        o.startS = now - 3600
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain starting now")
        o.startS = 0
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected in the next 48 hours")
        o.startS = .max
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected in the next 48 hours")
        o.startS = WxLimits.timeMaxS
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Rain expected in the next 48 hours")
        o.startS = now + 3600
        #expect(WxFormat.rainHeadline(o, nowS: 0, timezone: ny) == "Rain outlook unavailable")
        #expect(WxFormat.rainHeadline(o, nowS: .min, timezone: ny) == "Rain outlook unavailable")
    }

    // C: /format/headline/possible
    @Test("/format/headline/possible") func headlinePossible() {
        let ny = Self.ny, now = Self.nowS, ts = Self.ts
        var o = Self.outlook(.possible, 0, 0, false, now + 2 * 3600, .nan, 40)
        // test-format.c:818-844
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible around 4 PM (40% chance)")
        o.peakProb = 39.6
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible around 4 PM (40% chance)")
        o.peakProb = 100
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible around 4 PM (100% chance)")
        for p in [Double.nan, 100.5, -1, .infinity] {
            o.peakProb = p
            #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible around 4 PM", "\(p)")
        }
        o.peakProb = 55
        o.peakS = ts(2026, 10, 12, 20, 30, 0)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible tomorrow around 4:30 PM (55% chance)")
        o.peakS = now
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible now (55% chance)")
        o.peakS = now - 1800
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible now (55% chance)")
        o.peakS = 0
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible in the next 48 hours (55% chance)")
        o.peakS = .min
        o.peakProb = .nan
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny) == "Showers possible in the next 48 hours")
        o.peakS = now + 3600
        #expect(WxFormat.rainHeadline(o, nowS: WxLimits.timeMaxS, timezone: ny) == "Rain outlook unavailable")
    }

    // C: /format/detail
    @Test("/format/detail") func detail() {
        let ny = Self.ny, now = Self.nowS, ts = Self.ts
        var o = Self.outlook(.expected, now + 600, now + 3 * 3600, true, now + 3600, 1.0, 60)
        // test-format.c:867-871
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Light rain, heaviest around 3 PM. 60% chance of rain.")
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: "UTC") == "Light rain, heaviest around 7 PM. 60% chance of rain.")
        o.state = .now
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Light rain, heaviest around 3 PM.")
        o.state = .expected
        // test-format.c:873-884
        let mm: [Double] = [0.0, 0.49, 0.5, 2.49, 2.5, 7.59, 7.6, 500]
        let word = ["Very light", "Very light", "Light", "Light", "Moderate", "Moderate", "Heavy", "Heavy"]
        let lower = ["very light", "very light", "light", "light", "moderate", "moderate", "heavy", "heavy"]
        for i in mm.indices {
            o.peakMmH = mm[i]
            #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "\(word[i]) rain, heaviest around 3 PM. 60% chance of rain.")
            o.peakS = now - 3600
            #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Rain peaked around 1 PM (\(lower[i])). 60% chance of rain.")
            o.peakS = now + 3600
        }
        o.peakMmH = 3
        // test-format.c:887-927
        o.peakS = now + 1
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Moderate rain, heaviest around 2 PM. 60% chance of rain.")
        o.peakS = now
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Rain peaked around 2 PM (moderate). 60% chance of rain.")
        o.peakS = now - 1
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Rain peaked around 1:59 PM (moderate). 60% chance of rain.")
        o.peakS = ts(2026, 10, 12, 20, 0, 0)
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Moderate rain, heaviest tomorrow around 4 PM. 60% chance of rain.")
        o.peakS = ts(2026, 10, 10, 20, 30, 0)
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Rain peaked yesterday around 4:30 PM (moderate). 60% chance of rain.")
        o.peakS = ts(2026, 10, 9, 20, 0, 0)
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Rain peaked Friday around 4 PM (moderate). 60% chance of rain.")
        o.peakS = 0
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Moderate rain at its heaviest. 60% chance of rain.")
        o.peakS = now + 3600
        o.peakProb = .nan
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Moderate rain, heaviest around 3 PM.")
        o.peakProb = 101
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "Moderate rain, heaviest around 3 PM.")
        o.peakProb = 60
        for v in [Double.nan, -1, .infinity] {
            o.peakMmH = v
            #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "60% chance of rain.", "\(v)")
        }
        o.peakProb = .nan
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "")
        o.state = .now
        o.peakProb = 60
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "")
        o.state = .expected
        o.peakMmH = 3
        o.peakProb = 60
        #expect(WxFormat.rainDetail(o, nowS: 0, timezone: ny) == "")
        #expect(WxFormat.rainDetail(o, nowS: WxLimits.timeMaxS, timezone: ny) == "")
        o.state = .possible
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "No steady rain in the forecast, just a chance.")
        o.state = .dry
        #expect(WxFormat.rainDetail(o, nowS: now, timezone: ny) == "")
    }

    // C: /format/detail/past-peak
    @Test("/format/detail/past-peak") func detailPastPeak() {
        let peak = Self.ts(2026, 10, 11, 17, 0, 0)
        let now = Self.ts(2026, 10, 11, 18, 10, 0)
        let o = Self.outlook(.now, peak - 3600, now + 3600, true, peak, 8.0, 90)
        let d = WxFormat.rainDetail(o, nowS: now, timezone: Self.ny)
        // test-format.c:939-942
        #expect(d == "Rain peaked around 1 PM (heavy).")
        #expect(!d.contains("right now"))
        #expect(!d.contains("heaviest"))
        #expect(!d.contains("chance"))
    }

    // MARK: - cloud sentence

    // C: /format/cloud/bands
    @Test("/format/cloud/bands") func cloudBands() throws {
        let t0 = Self.ts(2026, 10, 11, 18, 0, 0)
        // test-format.c:985-998
        let t: [(Double, String)] = [
            (0, "Clear skies for the next hour"), (12.49, "Clear skies for the next hour"),
            (12.5, "Mostly clear skies for the next hour"), (37.49, "Mostly clear skies for the next hour"),
            (37.5, "Partly cloudy for the next hour"), (62.49, "Partly cloudy for the next hour"),
            (62.5, "Mostly cloudy for the next hour"), (87.49, "Mostly cloudy for the next hour"),
            (87.5, "Overcast for the next hour"), (100, "Overcast for the next hour"), (.nan, "Cloud cover unknown"),
            (-1, "Cloud cover unknown"), (100.01, "Cloud cover unknown"), (.infinity, "Cloud cover unknown"),
        ]
        for r in t {
            let f = try Self.makeForecast(t0, [r.0])
            #expect(WxFormat.cloudSentence(f, nowS: t0 + 600, timezone: Self.ny) == r.1, "\(r.0)")
        }
    }

    // C: /format/cloud/transitions
    @Test("/format/cloud/transitions") func cloudTransitions() throws {
        let t0 = Self.ts(2026, 10, 11, 18, 0, 0)
        let f = try Self.makeForecast(t0, (0..<30).map { $0 < 7 ? 70 : 5 })
        // test-format.c:1016-1018
        #expect(WxFormat.cloudSentence(f, nowS: t0 + 1800, timezone: Self.ny) == "Mostly cloudy now, clearing around 9 PM")
        #expect(WxFormat.cloudSentence(f, nowS: t0 + 1800, timezone: "UTC") == "Mostly cloudy now, clearing tomorrow around 1 AM")
    }

    // C: /format/cloud/targets
    @Test("/format/cloud/targets") func cloudTargets() throws {
        let t0 = Self.ts(2026, 10, 11, 18, 0, 0)
        // test-format.c:1029-1035
        let t: [(Double, Double, String)] = [
            (50, 0, "Partly cloudy now, clearing around 4 PM"), (50, 20, "Partly cloudy now, mostly clear around 4 PM"),
            (20, 50, "Mostly clear now, partly cloudy around 4 PM"), (50, 70, "Partly cloudy now, mostly cloudy around 4 PM"),
            (50, 100, "Partly cloudy now, clouding over around 4 PM"), (0, 100, "Clear now, clouding over around 4 PM"),
            (100, 0, "Overcast now, clearing around 4 PM"),
        ]
        for r in t {
            let f = try Self.makeForecast(t0, [r.0, r.0, r.1, r.1, r.1, r.1])
            #expect(WxFormat.cloudSentence(f, nowS: t0 + 60, timezone: Self.ny) == r.2)
        }
    }

    // C: /format/cloud/days-and-lookahead
    @Test("/format/cloud/days-and-lookahead") func cloudDaysAndLookahead() throws {
        let ny = Self.ny
        let t0 = Self.ts(2026, 10, 11, 18, 0, 0)
        // test-format.c:1050-1083
        let f = try Self.makeForecast(t0, (0..<40).map { $0 < 22 ? 90 : 10 })
        #expect(WxFormat.cloudSentence(f, nowS: t0, timezone: ny) == "Overcast now, clearing tomorrow around 12 PM")
        #expect(WxFormat.cloudSentence(f, nowS: t0, timezone: "UTC") == "Overcast now, clearing tomorrow around 4 PM")
        let g = try Self.makeForecast(t0, (0..<40).map { $0 < 24 ? 90 : 10 })
        #expect(WxFormat.cloudSentence(g, nowS: t0, timezone: ny) == "Overcast for the next 24 hours")
        #expect(WxFormat.cloudSentence(g, nowS: t0 + 1, timezone: ny) == "Overcast now, clearing tomorrow around 2 PM")
        let h = try Self.makeForecast(Self.ts(2026, 10, 13, 2, 0, 0), [90, 90, 10])
        #expect(WxFormat.cloudSentence(h, nowS: Self.ts(2026, 10, 13, 2, 30, 0), timezone: ny) == "Overcast now, clearing tomorrow around 12 AM")
        let k = try Self.makeForecast(t0, [20, .nan, 20, .nan, 20, 20])
        #expect(WxFormat.cloudSentence(k, nowS: t0, timezone: ny) == "Mostly clear skies for the next 6 hours")
        let k2 = try Self.makeForecast(t0, [20, 20, 20, .nan, .nan, .nan])
        #expect(WxFormat.cloudSentence(k2, nowS: t0, timezone: ny) == "Mostly clear skies for the next 3 hours")
        let k3 = try Self.makeForecast(t0, [20, 20, 90])
        #expect(WxFormat.cloudSentence(k3, nowS: t0, timezone: ny) == "Mostly clear now, clouding over around 4 PM")
        let m = try Self.makeForecast(t0, [Double](repeating: 0, count: 24))
        #expect(WxFormat.cloudSentence(m, nowS: t0, timezone: ny) == "Clear skies for the next 24 hours")
        #expect(WxFormat.cloudSentence(m, nowS: t0 + 3599, timezone: ny) == "Clear skies for the next 23 hours")
    }

    // C: /format/cloud/unknown
    @Test("/format/cloud/unknown") func cloudUnknown() throws {
        let ny = Self.ny
        let t0 = Self.ts(2026, 10, 11, 18, 0, 0)
        let f = try Self.makeForecast(t0, [10, 10, .nan, 10])
        // test-format.c:1092-1106
        #expect(WxFormat.cloudSentence(f, nowS: t0 - 1, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f, nowS: t0 + 4 * 3600, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f, nowS: t0 + 2 * 3600 + 5, timezone: ny) == "Clear skies for the next hour")
        let f2 = try Self.makeForecast(t0, [10, 10, .nan, .nan])
        #expect(WxFormat.cloudSentence(f2, nowS: t0 + 2 * 3600 + 5, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f2, nowS: t0 + 3 * 3600 + 5, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f, nowS: 0, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f, nowS: WxLimits.timeMaxS, timezone: ny) == "Cloud cover unknown")
        #expect(WxFormat.cloudSentence(f, nowS: .min, timezone: ny) == "Cloud cover unknown")
        let none = try Self.makeForecast(t0, [])
        #expect(WxFormat.cloudSentence(none, nowS: t0, timezone: ny) == "Cloud cover unknown")
        // a hand-built forecast whose later hour is not a valid time falls back to "later" (test-format.c:1109-1111)
        let hs = [Self.cloudHour(WxLimits.timeMaxS - 3600, 70), Self.cloudHour(WxLimits.timeMaxS, 10)]
        #expect(
            WxFormat.cloudSentence(hours: hs, lat: 0, lon: 0, nowS: WxLimits.timeMaxS - 3599, zone: WxFormat.Zone(timezone: ny))
                == "Mostly cloudy now, clearing later")
    }

    // MARK: - icons / symbols

    // C: /format/icons (the GTK names kept beside each SF Symbol)
    @Test("/format/icons") func icons() {
        // test-format.c:1125-1142 (WX_COND_COUNT = 15, -1 and 9999 are the invalid values)
        let t: [(Int, String, String)] = [
            (0, "dialog-question-symbolic", "dialog-question-symbolic"),
            (1, "weather-clear-symbolic", "weather-clear-night-symbolic"),
            (2, "weather-few-clouds-symbolic", "weather-few-clouds-night-symbolic"),
            (3, "weather-few-clouds-symbolic", "weather-few-clouds-night-symbolic"),
            (4, "weather-overcast-symbolic", "weather-overcast-symbolic"),
            (5, "weather-overcast-symbolic", "weather-overcast-symbolic"),
            (6, "weather-fog-symbolic", "weather-fog-symbolic"),
            (7, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic"),
            (8, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic"),
            (9, "weather-showers-symbolic", "weather-showers-symbolic"),
            (10, "weather-showers-symbolic", "weather-showers-symbolic"),
            (11, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic"),
            (12, "weather-storm-symbolic", "weather-storm-symbolic"),
            (13, "weather-snow-symbolic", "weather-snow-symbolic"),
            (14, "weather-snow-symbolic", "weather-snow-symbolic"),
            (15, "dialog-question-symbolic", "dialog-question-symbolic"),
            (-1, "dialog-question-symbolic", "dialog-question-symbolic"),
            (9999, "dialog-question-symbolic", "dialog-question-symbolic"),
        ]
        #expect(t.count - 3 == WxCondition.count)  // test-format.c:1144
        for r in t {
            let d = WxConditionSymbol.entry(conditionRawValue: r.0, isDay: true)
            let n = WxConditionSymbol.entry(conditionRawValue: r.0, isDay: false)
            #expect(d.gtkIconName == r.1, "\(r.0)")
            #expect(n.gtkIconName == r.2, "\(r.0)")
            #expect(d.gtkIconName.hasSuffix("-symbolic") && n.gtkIconName.hasSuffix("-symbolic"))
            // the grouping of the table: one SF Symbol per GTK icon, day and night alike
            #expect(d.symbolName == Self.symbolFor[r.1], "\(r.0)")
            #expect(n.symbolName == Self.symbolFor[r.2], "\(r.0)")
            if let c = WxCondition(rawValue: r.0) {
                #expect(WxConditionSymbol.entry(c, isDay: true) == d)
                #expect(WxConditionSymbol.symbolName(c, isDay: false) == n.symbolName)
            }
        }
    }

    /// The SF Symbol chosen for each GTK icon name (FormatSymbols.swift table).
    static let symbolFor: [String: String] = [
        "dialog-question-symbolic": "questionmark.circle", "weather-clear-symbolic": "sun.max",
        "weather-clear-night-symbolic": "moon.stars", "weather-few-clouds-symbolic": "cloud.sun",
        "weather-few-clouds-night-symbolic": "cloud.moon", "weather-overcast-symbolic": "cloud",
        "weather-fog-symbolic": "cloud.fog", "weather-showers-scattered-symbolic": "cloud.drizzle",
        "weather-showers-symbolic": "cloud.rain", "weather-storm-symbolic": "cloud.bolt.rain",
        "weather-snow-symbolic": "cloud.snow",
    ]

    // C: /widgets/icons-exist-in-theme (the SF Symbol of every condition and
    // day flag exists in the system symbol set of the SDK the tests run on)
    @Test("/widgets/icons-exist-in-theme") func iconsExistInSystemSymbols() {
        // test-widgets.c:2439-2445: every condition 0...WX_COND_COUNT, both day flags
        for c in 0...WxCondition.count {
            for day in [false, true] {
                let name = WxConditionSymbol.entry(conditionRawValue: c, isDay: day).symbolName
                #expect(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "symbol '\(name)' (condition \(c), day \(day)) is missing")
            }
        }
    }

    // MARK: - fuzz, environment, threads

    /// rand_double (test-format.c:1161-1182) on SeededRNG.
    static func randDouble(_ r: inout SeededRNG) -> Double {
        switch Int.random(in: 0..<8, using: &r) {
        case 0: return .nan
        case 1: return Bool.random(using: &r) ? .infinity : -.infinity
        case 2: return Double.random(in: -150..<150, using: &r)
        case 3: return Double.random(in: -1e300..<1e300, using: &r)
        case 4: return Double(Int.random(in: -2..<1002, using: &r)) / 10.0
        case 5: return Double.random(in: 0..<13000, using: &r)
        case 6: return Double(Int.random(in: -3..<3, using: &r)) * 0.5
        default: return Double.random(in: -1..<101, using: &r)
        }
    }

    /// rand_time (test-format.c:1184-1199).
    static func randTime(_ r: inout SeededRNG) -> Int64 {
        switch Int.random(in: 0..<6, using: &r) {
        case 0: return Int64(bitPattern: r.next())
        case 1: return Bool.random(using: &r) ? .max : .min
        case 2: return WxLimits.timeMinS + Int64.random(in: -3..<3, using: &r)
        case 3: return WxLimits.timeMaxS + Int64.random(in: -3..<3, using: &r)
        default: return WxLimits.timeMinS + Int64(UInt32.random(in: 0...UInt32.max, using: &r)) % (WxLimits.timeMaxS - WxLimits.timeMinS)
        }
    }

    /// rand_tz (test-format.c:1208-1221): a pool name or random bytes 1...255.
    static func randTZ(_ r: inout SeededRNG) -> [UInt8]? {
        let pool: [String?] = [nil, "", "UTC", ny, "Australia/Sydney", "Asia/Kolkata", "/etc/passwd", "../..", "a//b", "Nowhere/Land"]
        let k = Int.random(in: 0..<12, using: &r)
        if k < 10 {
            return pool[k].map { Array($0.utf8) }
        }
        let len = Int.random(in: 0..<99, using: &r)
        return (0..<len).map { _ in UInt8.random(in: 1...255, using: &r) }
    }

    // C: /format/fuzz (oracles kept: total, never empty where C never
    // returns "", the day-end property; GRand replaced by SeededRNG)
    @Test("/format/fuzz") func fuzz() {
        var r = SeededRNG(seed: 20_261_011)
        for _ in 0..<fuzzIterations(60000) {
            let u: WxUnits = Bool.random(using: &r) ? .imperial : .metric
            let v = Self.randDouble(&r)
            let t = Self.randTime(&r)
            var now = Self.randTime(&r)
            let zone = WxFormat.Zone(timezoneBytes: Self.randTZ(&r))
            #expect(!WxFormat.temp(v, units: u, withUnit: Bool.random(using: &r)).isEmpty)
            #expect(!WxFormat.wind(v, units: u).isEmpty)
            #expect(!WxFormat.precip(v, units: u).isEmpty)
            #expect(!WxFormat.percent(v).isEmpty)
            #expect(!WxFormat.hourLabel(t, zone: zone).isEmpty)
            #expect(!WxFormat.clock(t, zone: zone).isEmpty)
            #expect(!WxFormat.weekday(t, zone: zone, nowS: now).isEmpty)
            #expect(!WxFormat.updated(ageS: t).isEmpty)
            // test-format.c:1250-1251
            let end = WxFormat.localDayEnd(t, zone: zone)
            #expect(end == 0 ? !(t >= WxLimits.timeMinS && t < WxLimits.timeMaxS) : end > t, "t=\(t)")
            var o = Self.outlook(
                WxRainState(rawValue: Int.random(in: 0..<4, using: &r))!, Self.randTime(&r), Self.randTime(&r),
                Bool.random(using: &r), Self.randTime(&r), Self.randDouble(&r), Self.randDouble(&r))
            if Bool.random(using: &r) { o.startS = now &+ Int64.random(in: -4000..<200_000, using: &r) }
            if Bool.random(using: &r) { o.endS = now &+ Int64.random(in: -4000..<200_000, using: &r) }
            if Bool.random(using: &r) { o.peakS = now &+ Int64.random(in: -4000..<200_000, using: &r) }
            if Bool.random(using: &r) { now = WxLimits.timeMinS + Int64.random(in: 0..<100_000_000, using: &r) }
            #expect(!WxFormat.rainHeadline(o, nowS: now, zone: zone).isEmpty)
            _ = WxFormat.rainDetail(o, nowS: now, zone: zone)  // "" is a valid detail
            let base = Int64(bitPattern: UInt64(bitPattern: now - now % 3600) &- 3600)
            let hs = (0..<3).map { Self.cloudHour(Int64(bitPattern: UInt64(bitPattern: base) &+ UInt64($0) * 3600), Self.randDouble(&r)) }
            let n = Int.random(in: 0..<4, using: &r)
            let hours = Array(hs.prefix(n))
            #expect(!WxFormat.cloudSentence(hours: hours, lat: 0, lon: 0, nowS: now, zone: zone).isEmpty)
            #expect(!WxFormat.cloudSentence(hours: hours, lat: 0, lon: 0, nowS: hs[1].tS &+ 1, zone: zone).isEmpty)
        }
    }

    // C: /format/process-tz-independent (TZ is never set here; the
    // functions never read TimeZone.current, so these are the C literals)
    @Test("/format/process-tz-independent") func processTZIndependent() {
        let ts = Self.ts
        // test-format.c:1282-1287
        #expect(WxFormat.hourLabel(ts(2026, 10, 11, 19, 0, 0), timezone: Self.ny) == "3 PM")
        #expect(WxFormat.hourLabel(ts(2026, 10, 11, 19, 0, 0), timezone: nil) == "7 PM")
        #expect(WxFormat.weekday(ts(2026, 10, 11, 23, 0, 0), timezone: nil, nowS: ts(2026, 10, 11, 1, 0, 0)) == "Today")
        #expect(WxFormat.clock(ts(2026, 10, 11, 19, 45, 0), timezone: "UTC") == "7:45 PM")
    }

    // C: /format/threads
    @Test("/format/threads") func threads() async {
        // test-format.c:1298-1305 (19:00Z on 2026-10-11)
        let z: [(String?, String)] = [
            (Self.ny, "3 PM"), ("Australia/Sydney", "6 AM"), ("Asia/Kolkata", "12:30 AM"), ("Europe/London", "8 PM"),
            ("Asia/Tokyo", "4 AM"), ("America/Chicago", "2 PM"), ("Africa/Cairo", "10 PM"), ("Pacific/Auckland", "8 AM"),
            ("America/Sao_Paulo", "4 PM"), ("Asia/Dubai", "11 PM"), ("Europe/Moscow", "10 PM"),
            ("Pacific/Honolulu", "9 AM"), ("Mars/Olympus", "7 PM"), ("Japan", "7 PM"), (nil, "7 PM"),
        ]
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        let bad = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    var wrong = 0
                    for i in 0..<2000 {
                        let k = i % z.count
                        if WxFormat.hourLabel(t, timezone: z[k].0) != z[k].1 { wrong += 1 }
                        if WxFormat.clock(t, timezone: z[k].0).isEmpty { wrong += 1 }
                        if !(WxFormat.localDayEnd(t, timezone: z[k].0) > t) { wrong += 1 }
                        if WxFormat.temp(Double(i % 100), units: .imperial, withUnit: true).isEmpty { wrong += 1 }
                    }
                    return wrong
                }
            }
            return await group.reduce(0, +)
        }
        #expect(bad == 0)
    }

    // MARK: - resolved zones

    // C: /format/zone-new-resolved-flag (a lookup that fails: a well-shaped
    // name the database does not know; the simulated transient failure and
    // its 30-second retry are GLib-cache mechanics)
    @Test("/format/zone-new-resolved-flag") func zoneNewResolvedFlag() {
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        let z = WxFormat.Zone(timezone: Self.ny)
        #expect(z.resolved)  // test-format.c:1514
        #expect(WxFormat.hourLabel(t, zone: z) == "3 PM")  // test-format.c:1515
        // test-format.c:1517-1523
        for name: String? in [nil, "", "UTC", "Japan", "../x", "a//b", "/etc/passwd", "leapseconds", "utc"] {
            let u = WxFormat.Zone(timezone: name)
            #expect(u.resolved, "\(name ?? "nil")")
            #expect(WxFormat.hourLabel(t, zone: u) == "7 PM", "\(name ?? "nil")")
        }
        // test-format.c:1527-1532: not resolved, UTC fallback (wx-format.h:283-285)
        for _ in 0..<3 {
            let f = WxFormat.Zone(timezone: "Nowhere/Land")
            #expect(!f.resolved)
            #expect(WxFormat.hourLabel(t, zone: f) == "7 PM")
        }
        #expect(WxFormat.hourLabel(t, zone: WxFormat.Zone(timezone: "Asia/Kathmandu")) == "12:45 AM")  // test-format.c:1539
    }

    // C: /format/zone-taking-functions
    @Test("/format/zone-taking-functions") func zoneTakingFunctions() {
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        let kath = WxFormat.Zone(timezone: "Asia/Kathmandu")
        let utcNull = WxFormat.Zone(timezone: nil)
        let utcBad = WxFormat.Zone(timezone: "Japan")
        // test-format.c:1726-1742
        #expect(WxFormat.hourLabel(t, zone: kath) == "12:45 AM")
        #expect(WxFormat.clock(t, zone: kath) == "12:45 AM")
        #expect(WxFormat.weekday(t, zone: kath, nowS: t) == "Today")
        #expect(WxFormat.weekday(t + 86400, zone: kath, nowS: t) == "Tomorrow")
        #expect(WxFormat.hourLabel(t, zone: utcNull) == "7 PM")
        #expect(WxFormat.clock(t, zone: utcBad) == "7:00 PM")
        #expect(WxFormat.localDayEnd(t, zone: kath) == Self.ts(2026, 10, 12, 18, 15, 0))
        #expect(WxFormat.localDayEnd(t, zone: utcNull) == Self.ts(2026, 10, 12, 0, 0, 0))
        #expect(WxFormat.hourLabel(WxLimits.timeMaxS, zone: kath) == Self.dash)
        #expect(WxFormat.clock(0, zone: kath) == Self.dash)
        #expect(WxFormat.weekday(0, zone: kath, nowS: t) == Self.dash)
        #expect(WxFormat.localDayEnd(0, zone: kath) == 0)
        #expect(WxFormat.hourLabel(t, timezone: "Asia/Kathmandu") == "12:45 AM")
        #expect(WxFormat.localDayEnd(t, timezone: "Asia/Kathmandu") == WxFormat.localDayEnd(t, zone: kath))
    }

    // PINNED DIFFERENCES of THE TIME ZONE RULE (DECISIONS #41, shared with
    // WxDaily.lookedUpName): case variants are UTC (as test-blend.c:4907
    // asserts; unmodified C on case-insensitive APFS opens the zone), and
    // the 15 ICU-only legacy names absent from /usr/share/zoneinfo are
    // rejected so they fall back to UTC (unresolved) as in C.
    @Test("pinned: zone names are case sensitive; ICU-only legacy names fall back to UTC (DECISIONS #41)") func pinnedZoneNames() {
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        for name in ["america/new_york", "AMERICA/NEW_YORK", "asia/kathmandu"] {
            #expect(WxFormat.hourLabel(t, timezone: name) == "7 PM", "\(name)")
            #expect(!WxFormat.Zone(timezone: name).resolved, "\(name)")
        }
        let legacyNames = [
            "SystemV/AST4", "SystemV/AST4ADT", "SystemV/CST6", "SystemV/CST6CDT",
            "SystemV/EST5", "SystemV/EST5EDT", "SystemV/HST10", "SystemV/MST7",
            "SystemV/MST7MDT", "SystemV/PST8", "SystemV/PST8PDT", "SystemV/YST9",
            "SystemV/YST9YDT", "US/Pacific-New", "Canada/East-Saskatchewan",
        ]
        #expect(Set(legacyNames) == WxFormat.Zone.legacyICUTimezones)
        for name in legacyNames {
            let zone = WxFormat.Zone(timezone: name)
            #expect(!zone.resolved, "\(name)")
            #expect(WxFormat.hourLabel(t, zone: zone) == "7 PM", "\(name)")
        }
    }

    // C contract: WxHeldZone (src/widgets/wx-widget-util.h:52-104,
    // wx-widget-util.c:19-35); no GTK-free C test drives it directly
    @Test("held zone: init, change, same name, failed retry (wx-widget-util.h:52-104)") func heldZone() {
        let t = Self.ts(2026, 10, 11, 19, 0, 0)
        var held = WxFormat.HeldZone()
        #expect(held.nameBytes.isEmpty && held.resolved)  // wx-widget-util.h:59-60: UTC for "", resolved
        #expect(WxFormat.hourLabel(t, zone: held.zone) == "7 PM")
        let c1 = held.update("")
        #expect(!c1)  // same name, resolved: nothing changes (wx-widget-util.h:76)
        let c2 = held.update(Self.ny)
        #expect(c2)  // a new name is resolved
        #expect(held.resolved && WxFormat.hourLabel(t, zone: held.zone) == "3 PM")
        let c3 = held.update(Self.ny)
        #expect(!c3)  // never looked up again
        let c4 = held.update("Nowhere/Land")
        #expect(c4)  // name changed: TRUE, fallback held
        #expect(!held.resolved && WxFormat.hourLabel(t, zone: held.zone) == "7 PM")
        let c5 = held.update("Nowhere/Land")
        #expect(!c5)  // the retry fails again: nothing changes (wx-widget-util.h:74-75)
        let c6 = held.update("Asia/Kolkata")
        #expect(c6)  // a name change while the fallback is held
        #expect(held.resolved && Array(held.nameBytes) == Array("Asia/Kolkata".utf8))
        #expect(WxFormat.sameValue(.nan, .nan) && WxFormat.sameValue(1, 1) && !WxFormat.sameValue(.nan, 1))
    }

    // MARK: - High/Low label (src/ui/wx-detail.c:475-483)

    /// The detail test fixture (test-detail.c:26-31, 104-119): hours from
    /// T_H0 = 2026-10-12 18:00Z (2 PM in New York), now 18:30Z, today starts
    /// at NY_DAY0 = 04:00Z with high 27 C and low 16 C.
    static let tH0: Int64 = 1_791_828_000
    static let nyDay0: Int64 = 1_791_777_600

    @Test("High/Low label, test-detail.c:1223,1253,1255") func highLowLabel() throws {
        let place = try WxPlace(name: "New York", lat: 40.71, lon: -74.01, timezone: Self.ny)
        let hours = (0..<72).map { WxBlendHour(tS: Self.tH0 + Int64($0) * 3600) }
        let f = try WxForecast(place: place, generatedS: Self.tH0 + 1800, hours: hours)
        let dot = " \u{00B7} "
        let today = WxDay(startS: Self.nyDay0, tempMaxC: 27, tempMinC: 16)
        // test-detail.c:1253
        #expect(
            WxFormat.highLowLabel(day: today, forecast: f, nowS: Self.tH0 + 1800, timezone: Self.ny, units: .imperial)
                == "High 81\(Self.deg)\(dot)Low 61\(Self.deg) (from 2 PM)")
        // test-detail.c:1223
        let unknown = WxDay(startS: Self.nyDay0, tempMaxC: .nan, tempMinC: .nan)
        #expect(
            WxFormat.highLowLabel(day: unknown, forecast: f, nowS: Self.tH0 + 1800, timezone: Self.ny, units: .imperial)
                == "High \(Self.dash)\(dot)Low \(Self.dash) (from 2 PM)")
        // test-detail.c:1249,1255: the next day (20 C / 10 C) at its 01:00 is whole
        let next = WxDay(startS: Self.nyDay0 + 86400, tempMaxC: 20, tempMinC: 10)
        #expect(
            WxFormat.highLowLabel(day: next, forecast: f, nowS: Self.nyDay0 + 86400 + 3600, timezone: Self.ny, units: .imperial)
                == "High 68\(Self.deg)\(dot)Low 50\(Self.deg)")
    }
}
