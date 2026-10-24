// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Daily.swift - the daily summary: blended hours grouped into the place's
// local calendar days. Port of src/blend/wx-daily.{h,c}.
//
// Pure apart from reading the system's time-zone database (Foundation's
// TimeZone) for the zone named by the place; the process' own zone and
// locale are never used.
//
// Platform mapping (the C code uses GLib's GTimeZone):
//  - local_day_number: g_time_zone_find_interval(UNIVERSAL) + get_offset is
//    TimeZone.secondsFromGMT(for:) at the UTC instant; the day number is the
//    C integer division of a positive number (t is at least WX_TIME_MIN_S).
//  - local_midnight: C takes the earliest of GLib's own local midnight and
//    every "00:00 read with an offset in effect within two days" candidate
//    that really lies on the date, i.e. the first instant of the local date
//    (wx-daily.h:66-70). Swift takes the earliest of the same offset
//    candidates plus the zone transitions in that window (where a date that
//    begins inside a gap begins), which is that same first instant.
//  - wx_daily_interval_offset (the guard for GLib's -1 interval) has no
//    Foundation counterpart: TimeZone has no interval indices to fail.

import Foundation

/// The daily summary (wx_daily_build, src/blend/wx-daily.h:24-109).
public enum WxDaily {
    /// Most days `build` produces (WX_DAILY_MAX_DAYS, wx-daily.h:20).
    public static let maxDays = 10
    /// Covered hours (nMembers > 0) a local day other than today needs
    /// (WX_DAILY_MIN_HOURS, wx-daily.h:22).
    public static let minHours = 12
    /// Covered hours the day containing `nowS` needs (WX_DAILY_MIN_HOURS_TODAY, wx-daily.h:24).
    public static let minHoursToday = 1

    /// wx_daily_build on a Swift string (nil is C's NULL).
    ///
    /// THE TIMEZONE RULE: the name is looked up only if it passes the
    /// `WxPlace` time-zone shape check and contains a '/'; every other string
    /// (nil, "", "UTC", bare aliases such as "Japan", a bad shape, a name the
    /// zone database does not know, a directory) is UTC.
    ///
    /// Returns [] when a precondition of the C function fails (its critical
    /// path): more than `WxLimits.forecastMaxHours` hours, `nowS` outside
    /// [timeMinS, timeMaxS), or hours not strictly ascending multiples of
    /// 3600 in that range. Otherwise at most `maxDays` days, ascending.
    public static func build(timezone: String?, hours: [WxBlendHour], nowS: Int64) -> [WxDay] {
        build(timezoneBytes: timezone.map { Array($0.utf8) }, hours: hours, nowS: nowS)
    }

    /// wx_daily_build on raw bytes (for names that are not valid UTF-8); the
    /// name ends at its first 0x00 byte or at the end of the array.
    public static func build(timezoneBytes: [UInt8]?, hours: [WxBlendHour], nowS: Int64) -> [WxDay] {
        // g_return_val_if_fail order of wx-daily.c:267-275
        guard hours.count <= WxLimits.forecastMaxHours else {
            return []
        }
        guard nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
            return []
        }
        for i in hours.indices {
            let t = hours[i].tS
            guard t >= WxLimits.timeMinS && t < WxLimits.timeMaxS && t % hourS == 0
                && (i == 0 || t > hours[i - 1].tS)
            else {
                return []
            }
        }
        if hours.isEmpty {
            return []
        }

        let zone = Zone(timezoneBytes)
        let todayNo = zone.dayNumber(nowS)
        var days: [WxDay] = []
        var begin = 0
        var dayNo = zone.dayNumber(hours[0].tS)
        var i = 1
        while i <= hours.count && days.count < maxDays {
            var no: Int64 = 0
            if i < hours.count {
                no = zone.dayNumber(hours[i].tS)
                // same local day (a clock stepping back across midnight stays in the current day)
                if no <= dayNo {
                    i += 1
                    continue
                }
            }
            if let day = summarise(zone, hours[begin..<i], minHours: dayNo == todayNo ? minHoursToday : minHours) {
                days.append(day)
            }
            begin = i
            dayNo = no
            i += 1
        }
        return days
    }

    /// zone_is_looked_up (wx-daily.c:57-68): the name has the shape
    /// wx_place_new() accepts AND contains a '/'. Returns the name to look up
    /// (the bytes before the first 0x00), or nil for UTC.
    static func lookedUpName(_ bytes: [UInt8]?) -> String? {
        guard let bytes,
            let probe = try? WxPlace(nameBytes: Array("x".utf8), lat: 0.0, lon: 0.0, timezoneBytes: bytes)
        else {
            return nil
        }
        // the shape check proved that the name is ASCII and ends within the bound
        return probe.timezone.utf8.contains(0x2F) ? probe.timezone : nil
    }

    // MARK: - Private

    /// Seconds in a day and in an hour (wx-daily.c:11-12).
    private static let dayS: Int64 = 86_400
    private static let hourS: Int64 = 3_600
    /// A severe class needs this probability when not backed by two consecutive hours (wx-daily.c:16).
    private static let severeProbPct = 40.0
    /// A rain day needs this much precipitation and probability (wx-daily.c:18-19).
    private static let rainDayMm = 1.0
    private static let rainDayProbPct = 50.0

    /// The resolved zone: nil is UTC (offset 0, no transitions).
    private struct Zone {
        let tz: TimeZone?

        init(_ bytes: [UInt8]?) {
            // not looked up, or unknown to the database: UTC (wx-daily.c:277-279)
            tz = lookedUpName(bytes).flatMap { WxFormat.Zone.resolveTimeZone($0) }
        }

        /// Offset east of UTC in effect at the UTC instant `t`.
        func offset(_ t: Int64) -> Int64 {
            guard let tz else {
                return 0
            }
            return Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t))))
        }

        /// local_day_number (wx-daily.c:88-92).
        func dayNumber(_ t: Int64) -> Int64 {
            (t + offset(t)) / dayS
        }

        /// The zone's transitions in (lo, hi], each with the offset in effect from it on.
        func transitions(after lo: Int64, through hi: Int64) -> [(t: Int64, offset: Int64)] {
            guard let tz else {
                return []
            }
            var out: [(t: Int64, offset: Int64)] = []
            var from = Date(timeIntervalSince1970: TimeInterval(lo))
            while let next = tz.nextDaylightSavingTimeTransition(after: from) {
                let raw = next.timeIntervalSince1970
                let t = Int64(raw.rounded(.up))
                if t > hi || raw <= from.timeIntervalSince1970 {
                    break
                }
                out.append((t, offset(t)))
                from = next
            }
            return out
        }

        /// local_midnight (wx-daily.c:149-172): the first instant of the local date of `t`.
        func midnight(_ t: Int64) -> Int64 {
            let dayNo = dayNumber(t)
            var first = t  // t itself is on the date
            // the offsets in effect within two days of t, and the instants where they begin
            var offsets: [Int64] = [offset(t - 2 * dayS)]
            var starts: [Int64] = []
            for tr in transitions(after: t - 2 * dayS, through: t + 2 * dayS) {
                offsets.append(tr.offset)
                starts.append(tr.t)
            }
            for off in offsets {
                let c = dayNo * dayS - off
                if c < first && dayNumber(c) == dayNo {
                    first = c
                }
            }
            // a date that begins inside a gap (midnight does not exist) begins at the transition
            for c in starts where c < first && dayNumber(c) == dayNo {
                first = c
            }
            return first
        }
    }

    /// C fmax (wx-daily.c:203): the other operand when one is NaN; +0 over -0.
    private static func cFmax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN {
            return b
        }
        if b.isNaN {
            return a
        }
        if a == b {
            return a.sign == .minus ? b : a
        }
        return a > b ? a : b
    }

    /// C fmin (wx-daily.c:204): the other operand when one is NaN; -0 over +0.
    private static func cFmin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN {
            return b
        }
        if b.isNaN {
            return a
        }
        if a == b {
            return a.sign == .minus ? a : b
        }
        return a < b ? a : b
    }

    /// has_severe (wx-daily.c:117-130): some hour has `cls` and either its
    /// precipProb >= 40 or the next entry has `cls` at tS + 3600.
    private static func hasSevere(_ hours: ArraySlice<WxBlendHour>, _ cls: WxCondition) -> Bool {
        var i = hours.startIndex
        while i < hours.endIndex {
            defer { i += 1 }
            if hours[i].condition != cls {
                continue
            }
            if hours[i].precipProb >= severeProbPct {
                return true
            }
            if i + 1 < hours.endIndex && hours[i + 1].condition == cls && hours[i + 1].tS == hours[i].tS + hourS {
                return true
            }
        }
        return false
    }

    /// summarise_day (wx-daily.c:186-261): nil when the day has fewer than
    /// `minHours` covered hours or starts before WX_TIME_MIN_S.
    private static func summarise(_ zone: Zone, _ hours: ArraySlice<WxBlendHour>, minHours: Int) -> WxDay? {
        var covered = 0
        var tmax = Double.nan
        var tmin = Double.nan
        var psum = Double.nan
        var probMax = Double.nan
        var rateMax = Double.nan
        var daySum = 0.0
        var allSum = 0.0
        var dayN = 0
        var allN = 0

        for h in hours {
            if h.nMembers > 0 {
                covered += 1
            }
            if h.tempC.isFinite {
                tmax = cFmax(tmax, h.tempC)
                tmin = cFmin(tmin, h.tempC)
            }
            if h.precipMm.isFinite {
                psum = psum.isNaN ? h.precipMm : psum + h.precipMm
                rateMax = cFmax(rateMax, h.precipMm)
            }
            if h.precipProb.isFinite {
                probMax = cFmax(probMax, h.precipProb)
            }
            if h.cloudPct.isFinite {
                allSum += h.cloudPct
                allN += 1
                if h.isDay {
                    daySum += h.cloudPct
                    dayN += 1
                }
            }
        }
        if covered < minHours {
            return nil
        }

        let startS = zone.midnight(hours[hours.startIndex].tS)
        if startS < WxLimits.timeMinS {
            return nil
        }
        // a 25 hour day at the hourly maximum exceeds the daily maximum of WxDay
        if psum > WxLimits.precipMaxMmDay {
            psum = WxLimits.precipMaxMmDay
        }
        let cloud = dayN > 0 ? daySum / Double(dayN) : (allN > 0 ? allSum / Double(allN) : Double.nan)

        let cond: WxCondition
        if hasSevere(hours, .thunderstorm) {
            cond = .thunderstorm
        } else if hasSevere(hours, .snow) {
            cond = .snow
        } else if hasSevere(hours, .sleet) {
            cond = .sleet
        } else if psum >= rainDayMm && probMax >= rainDayProbPct {
            cond = WxConditionRules.rainClass(cloudPct: cloud, precipMmH: rateMax)
        } else {
            cond = WxConditionRules.cloudCondition(cloud)
        }
        return WxDay(
            startS: startS, tempMaxC: tmax, tempMinC: tmin, precipMm: psum, precipProbMax: probMax,
            cloudPct: cloud, condition: cond)
    }
}
