// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Format.swift - fixed-English, locale-independent text formatting for the
// weather UI: temperatures, wind, precipitation and percentages in the
// user's unit system, 12-hour clock and weekday labels in a place's time
// zone, the "Updated ..." age text, the plain-language rain headline /
// detail / cloud sentences and today's High/Low label. Port of
// src/widgets/wx-format.{h,c} (contract wx-format.h:3-526) and of the
// High/Low label of src/ui/wx-detail.c:475-483.
//
// Rules kept literally (do not replace with Foundation formatters):
//  - digits and decimal points are always ASCII and the words are fixed
//    English; neither Locale.current nor TimeZone.current is ever read
//    (DateFormatter/MeasurementFormatter would localise "PM", the decimal
//    separator and the rounding);
//  - whole numbers are C lround (halves away from zero; a value that rounds
//    to zero prints "0", never "-0");
//  - decimals are printf "%.1f"/"%.2f" of the exact binary value (ties to
//    even, 6.35 -> "6.3"), computed here with integer arithmetic;
//  - a missing or implausible number (NaN, infinity, outside the documented
//    range) and a time outside [WxLimits.timeMinS, WxLimits.timeMaxS) print
//    as an em dash U+2014;
//  - time zones follow THE TIME ZONE RULE (FormatZone.swift).
//
// Not representable in Swift (C programmer errors that log a critical and
// return NULL): an invalid WxUnits or WxRainState value, a NULL outlook,
// forecast, day or zone. Every function here is total and pure (no I/O
// beyond Foundation's in-memory zone data) and safe from any thread.

import Foundation

/// The formatting module (wx-format.h).
public enum WxFormat {
    /// EM_DASH (wx-format.c:17): the text of a missing value.
    public static let emDash = "\u{2014}"

    // MARK: - Numbers

    /// wx_format_temp (wx-format.c:533-544): a temperature rounded to a
    /// whole degree; imperial converts to Fahrenheit (c * 9 / 5 + 32):
    /// "77°" / "77°F", metric "25°" / "25°C". The dash (never a unit letter)
    /// when `c` is outside [-100, 70] or not finite.
    public static func temp(_ c: Double, units: WxUnits, withUnit: Bool) -> String {
        guard WxLimits.valueInRange(c, WxLimits.tempMinC, WxLimits.tempMaxC) else {
            return emDash
        }
        let metric = units == .metric
        let v = cLround(metric ? c : c * 9.0 / 5.0 + 32.0)
        if !withUnit {
            return "\(v)\u{00B0}"
        }
        return "\(v)\u{00B0}\(metric ? "C" : "F")"
    }

    /// wx_format_wind (wx-format.c:547-556): "12 mph" (kmh * 0.621371192237334)
    /// or "19 km/h", rounded with lround; the dash outside [0, 500] or not finite.
    public static func wind(_ kmh: Double, units: WxUnits) -> String {
        guard WxLimits.valueInRange(kmh, 0.0, WxLimits.windMaxKmh) else {
            return emDash
        }
        if units == .metric {
            return "\(cLround(kmh)) km/h"
        }
        return "\(cLround(kmh * mphPerKmh)) mph"
    }

    /// wx_format_precip (wx-format.c:559-583): "0 in" / "0 mm" for zero;
    /// inches (mm / 25.4) keep two decimals while the two-decimal text is
    /// below 1 ("0.25 in"), else one ("1.5 in"); millimetres keep one
    /// ("2.5 mm"); a positive amount whose text would be zero is "<0.01 in" /
    /// "<0.1 mm". The dash outside [0, 12000] or not finite.
    public static func precip(_ mm: Double, units: WxUnits) -> String {
        guard WxLimits.valueInRange(mm, 0.0, WxLimits.precipMaxMmDay) else {
            return emDash
        }
        if mm == 0.0 {
            return units == .metric ? "0 mm" : "0 in"
        }
        // The decisions are taken on the printed digits, as C decides on the printf text.
        if units == .metric {
            let tenths = fixedScaled(mm, scale: 10)
            if tenths == 0 {
                return "<0.1 mm"
            }
            return "\(fixedText(tenths, scale: 10)) mm"
        }
        let inches = mm / mmPerInch
        let hundredths = fixedScaled(inches, scale: 100)
        if hundredths == 0 {
            return "<0.01 in"
        }
        if hundredths >= 100 {  // g_ascii_strtod("%.2f" text) >= 1.0
            return "\(fixedText(fixedScaled(inches, scale: 10), scale: 10)) in"
        }
        return "\(fixedText(hundredths, scale: 100)) in"
    }

    /// wx_format_percent (wx-format.c:586-592): "40%" (lround); the dash
    /// outside [0, 100] or not finite.
    public static func percent(_ pct: Double) -> String {
        guard WxLimits.valueInRange(pct, WxLimits.percentMin, WxLimits.percentMax) else {
            return emDash
        }
        return "\(cLround(pct))%"
    }

    // MARK: - Times

    /// wx_format_hour_label_z (wx-format.c:595-601): the local 12-hour clock
    /// hour, "3 PM", "12 AM" (midnight), "12 PM" (noon); "11:30 PM" when the
    /// local time is not on the hour; seconds dropped. The dash outside the
    /// time range.
    public static func hourLabel(_ tS: Int64, zone: Zone) -> String {
        guard let dt = localTime(tS, zone) else {
            return emDash
        }
        return clockText(dt, minutes: false)
    }

    /// wx_format_hour_label (wx-format.c:604-609).
    public static func hourLabel(_ tS: Int64, timezone: String?) -> String {
        hourLabel(tS, zone: Zone(timezone: timezone))
    }

    /// wx_format_clock_z (wx-format.c:612-618): "3:45 PM", "12:05 AM",
    /// "12:00 PM"; seconds dropped. The dash outside the time range.
    public static func clock(_ tS: Int64, zone: Zone) -> String {
        guard let dt = localTime(tS, zone) else {
            return emDash
        }
        return clockText(dt, minutes: true)
    }

    /// wx_format_clock (wx-format.c:621-626).
    public static func clock(_ tS: Int64, timezone: String?) -> String {
        clock(tS, zone: Zone(timezone: timezone))
    }

    /// wx_format_weekday_z (wx-format.c:629-643): "Today", "Tomorrow" or the
    /// English weekday name (also for past days and when `nowS` is outside
    /// the time range), by local calendar dates. The dash when `tS` is
    /// outside the time range.
    public static func weekday(_ tS: Int64, zone: Zone, nowS: Int64) -> String {
        guard let dt = localTime(tS, zone) else {
            return emDash
        }
        let diff = localTime(nowS, zone).map { dt.dayNumber - $0.dayNumber } ?? -1
        if diff == 0 {
            return "Today"
        }
        if diff == 1 {
            return "Tomorrow"
        }
        return dt.weekdayName
    }

    /// wx_format_weekday (wx-format.c:646-651).
    public static func weekday(_ tS: Int64, timezone: String?, nowS: Int64) -> String {
        weekday(tS, zone: Zone(timezone: timezone), nowS: nowS)
    }

    /// wx_format_day_covered_from (wx-format.c:722-736; contract
    /// wx-format.h:244-277): the forecast's first hour when it starts in
    /// [day.startS + 3600, nowS] and both it and day.startS are in the time
    /// range (the day's numbers cover only the rest of the day); 0 otherwise.
    public static func dayCoveredFrom(_ forecast: WxForecast, day: WxDay, nowS: Int64) -> Int64 {
        guard let first = forecast.hours.first?.tS else {
            return 0
        }
        // the range checks make first - 3600 and the comparison free of overflow
        if !timeOK(first) || first > nowS || !timeOK(day.startS) || first - hourS < day.startS {
            return 0
        }
        return first
    }

    /// wx_format_updated (wx-format.c:739-752): "Updated just now" (negative
    /// or under 60 s), "Updated 5 min ago", "Updated 2 h ago",
    /// "Updated 1 day ago" / "Updated 3 days ago" (1...29 days) and
    /// "Updated over a month ago".
    public static func updated(ageS: Int64) -> String {
        if ageS < 60 {
            return "Updated just now"
        }
        if ageS < 3600 {
            return "Updated \(ageS / 60) min ago"
        }
        if ageS < 86400 {
            return "Updated \(ageS / 3600) h ago"
        }
        let days = ageS / 86400
        if days >= 30 {
            return "Updated over a month ago"
        }
        return "Updated \(days) day\(days == 1 ? "" : "s") ago"
    }

    // MARK: - Sentences

    /// wx_rain_headline (wx-format.c:781-825; contract wx-format.h:408-450):
    /// the one-line rain headline, without a final period.
    public static func rainHeadline(_ outlook: WxRainOutlook, nowS: Int64, zone: Zone) -> String {
        if outlook.state == .dry {
            return "No rain expected for the next 48 hours"
        }
        if !timeOK(nowS) {
            return "Rain outlook unavailable"
        }
        switch outlook.state {
        case .dry:
            return "No rain expected for the next 48 hours"  // handled above
        case .now:
            if !outlook.endsKnown {
                return "Raining now, expected to continue for hours"
            }
            if !timeOK(outlook.endS) {
                return "Raining now"
            }
            if outlook.endS <= nowS {
                return "Raining now, easing soon"
            }
            return "Raining now, easing \(whenPhrase(outlook.endS, nowS: nowS, zone: zone))"
        case .expected:
            if !timeOK(outlook.startS) {
                return "Rain expected in the next 48 hours"
            }
            let delta = outlook.startS - nowS  // both in the time range: no overflow
            if delta <= 0 {
                return "Rain starting now"
            }
            if delta < minutesPhraseBelowS {
                let minutes = (delta + 59) / 60
                return "Rain starting in \(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "Rain expected \(whenPhrase(outlook.startS, nowS: nowS, zone: zone))"
        case .possible:
            let chance = chanceText(outlook.peakProb, prefix: " (", suffix: " chance)")
            if !timeOK(outlook.peakS) {
                return "Showers possible in the next 48 hours\(chance)"
            }
            if outlook.peakS <= nowS {
                return "Showers possible now\(chance)"
            }
            return "Showers possible \(whenPhrase(outlook.peakS, nowS: nowS, zone: zone))\(chance)"
        }
    }

    /// wx_rain_headline with a zone name.
    public static func rainHeadline(_ outlook: WxRainOutlook, nowS: Int64, timezone: String?) -> String {
        rainHeadline(outlook, nowS: nowS, zone: Zone(timezone: timezone))
    }

    /// wx_rain_detail (wx-format.c:853-888; contract wx-format.h:452-485):
    /// the optional second line, possibly "".
    public static func rainDetail(_ outlook: WxRainOutlook, nowS: Int64, zone: Zone) -> String {
        if !timeOK(nowS) || outlook.state == .dry {
            return ""
        }
        if outlook.state == .possible {
            return "No steady rain in the forecast, just a chance."
        }
        // The outlook's peak covers the whole run, past samples included, so a
        // peak that is not in the future is reported as past ("peaked") and never
        // as the current rate.
        var intensity: String?
        if outlook.peakMmH.isFinite && outlook.peakMmH >= 0.0 {
            let word = intensityWord(outlook.peakMmH)
            if !timeOK(outlook.peakS) {
                intensity = "\(word) rain at its heaviest."
            } else {
                let when = whenPhrase(outlook.peakS, nowS: nowS, zone: zone)
                if outlook.peakS > nowS {
                    intensity = "\(word) rain, heaviest \(when)."
                } else {
                    intensity = "Rain peaked \(when) (\(asciiLower(word)))."
                }
            }
        }
        // "N% chance of rain" is only meaningful while no rain has started.
        let chance = outlook.state == .expected ? chanceText(outlook.peakProb, prefix: "", suffix: " chance of rain.") : ""
        if let intensity, !chance.isEmpty {
            return "\(intensity) \(chance)"
        }
        return intensity ?? chance
    }

    /// wx_rain_detail with a zone name.
    public static func rainDetail(_ outlook: WxRainOutlook, nowS: Int64, timezone: String?) -> String {
        rainDetail(outlook, nowS: nowS, zone: Zone(timezone: timezone))
    }

    /// wx_cloud_sentence (wx-format.c:923-961; contract wx-format.h:487-522):
    /// the sky now (the band of the cloud cover WxBlend.now reports) and the
    /// first change within the next 24 hours, without a final period;
    /// "Cloud cover unknown" when `nowS` is outside the time range, no hour
    /// contains it or the current cloud cover is unknown.
    public static func cloudSentence(_ forecast: WxForecast, nowS: Int64, zone: Zone) -> String {
        cloudSentence(hours: forecast.hours, lat: forecast.place.lat, lon: forecast.place.lon, nowS: nowS, zone: zone)
    }

    /// wx_cloud_sentence with a zone name.
    public static func cloudSentence(_ forecast: WxForecast, nowS: Int64, timezone: String?) -> String {
        cloudSentence(forecast, nowS: nowS, zone: Zone(timezone: timezone))
    }

    /// wx_cloud_sentence over hand-built hours (any stamps; the C tests'
    /// raw WxForecast { .hours, .n_hours }). `lat`/`lon` only feed isDay.
    static func cloudSentence(hours: [WxBlendHour], lat: Double, lon: Double, nowS: Int64, zone: Zone) -> String {
        let n = hours.count
        if !timeOK(nowS) {
            return "Cloud cover unknown"
        }
        // The current band is that of the cloud cover wx_forecast_now() reports (the
        // interpolated one), the same value the detail pane shows as cover and condition.
        var i = 0
        while i < n && !(hours[i].tS <= nowS && hours[i].tS > nowS - hourS) {  // no overflow
            i += 1
        }
        guard i < n, let current = WxBlend.now(hours: hours, lat: lat, lon: lon, nowS: nowS) else {
            return "Cloud cover unknown"
        }
        guard let cur = cloudBand(current.cloudPct) else {
            return "Cloud cover unknown"
        }
        // Wrapping arithmetic as C's (a WxForecast has ascending in-range hours, where
        // nothing wraps; only hand-built hour arrays can reach the wrap).
        var coveredUntil = hours[i].tS &+ hourS
        i += 1
        while i < n && hours[i].tS < nowS + cloudLookaheadS {
            if let band = cloudBand(hours[i].cloudPct) {
                if band != cur {
                    let when = whenPhrase(hours[i].tS, nowS: nowS, zone: zone)
                    return "\(bandNow[cur]) now, \(bandTarget[band]) \(when)"
                }
                coveredUntil = hours[i].tS &+ hourS
            }
            i += 1
        }
        if coveredUntil >= nowS + cloudLookaheadS {
            return "\(bandSteady[cur]) for the next 24 hours"
        }
        let left = (coveredUntil &- nowS) / hourS
        if left < 2 {
            return "\(bandSteady[cur]) for the next hour"
        }
        return "\(bandSteady[cur]) for the next \(Int32(truncatingIfNeeded: left)) hours"
    }

    /// The High/Low label of today (src/ui/wx-detail.c:475-483, contract
    /// src/ui/wx-detail.h:48-53): "High 80° · Low 65°", plus " (from 2 PM)"
    /// (the hour label of the forecast's first hour) when
    /// `dayCoveredFrom` is not 0. `day` is the caller's "today".
    public static func highLowLabel(
        day: WxDay, forecast: WxForecast, nowS: Int64, timezone: String?, units: WxUnits
    ) -> String {
        let high = temp(day.tempMaxC, units: units, withUnit: false)
        let low = temp(day.tempMinC, units: units, withUnit: false)
        let fromS = dayCoveredFrom(forecast, day: day, nowS: nowS)
        let from = fromS != 0 ? " (from \(hourLabel(fromS, timezone: timezone)))" : ""
        return "High \(high)\(separator)Low \(low)\(from)"
    }

    // MARK: - Private

    /// MM_PER_INCH, MPH_PER_KMH (wx-format.c:27-28).
    private static let mmPerInch = 25.4
    private static let mphPerKmh = 0.621371192237334
    /// MINUTES_PHRASE_BELOW_S (wx-format.c:25).
    private static let minutesPhraseBelowS: Int64 = 90 * 60
    /// CLOUD_LOOKAHEAD_S (wx-format.c:31).
    private static let cloudLookaheadS: Int64 = 24 * 3600
    /// Rain intensity bounds, mm/h (wx-format.c:20-22).
    private static let veryLightBelowMmH = 0.5
    private static let lightBelowMmH = 2.5
    private static let moderateBelowMmH = 7.6
    /// SEPARATOR of the detail pane (src/ui/wx-detail.c:22): " · ".
    private static let separator = " \u{00B7} "

    /// Cloud texts indexed by band (wx-format.c:39-47).
    private static let bandNow = ["Clear", "Mostly clear", "Partly cloudy", "Mostly cloudy", "Overcast"]
    private static let bandSteady = ["Clear skies", "Mostly clear skies", "Partly cloudy", "Mostly cloudy", "Overcast"]
    private static let bandTarget = ["clearing", "mostly clear", "partly cloudy", "mostly cloudy", "clouding over"]

    /// lround for the bounded values of this module (|x| < 2^53): halves away from zero.
    private static func cLround(_ x: Double) -> Int64 {
        Int64(x.rounded(.toNearestOrAwayFromZero))
    }

    /// round(x * scale) of the EXACT binary value of x, ties to even: the
    /// integer that printf "%.Nf" prints (scale = 10^N), for a finite
    /// 0 <= x < 2^53 (callers pass at most 12000).
    private static func fixedScaled(_ x: Double, scale: UInt64) -> UInt64 {
        if x == 0 {
            return 0
        }
        let frac = x.significandBitPattern
        let biased = Int(x.exponentBitPattern)
        // x = m * 2^e exactly
        let m: UInt64 = biased == 0 ? frac : frac | (1 << 52)
        let e = biased == 0 ? -1074 : biased - 1075
        let p = m * scale  // m < 2^53, scale <= 100: below 2^60
        if e >= 0 {
            return p << UInt64(e)  // not reached for the callers' range
        }
        let s = -e
        if s >= 64 {
            return 0  // p * 2^-s < 2^-4
        }
        let q = p >> UInt64(s)
        let r = p & ((1 << UInt64(s)) - 1)
        let half: UInt64 = 1 << UInt64(s - 1)
        if r > half || (r == half && q & 1 == 1) {
            return q + 1
        }
        return q
    }

    /// The ASCII text of n / scale with log10(scale) decimals ("0.25", "100.0").
    private static func fixedText(_ n: UInt64, scale: UInt64) -> String {
        var digits = String(n % scale)
        let width = scale == 10 ? 1 : 2
        while digits.count < width {
            digits = "0" + digits
        }
        return "\(n / scale).\(digits)"
    }

    /// clock_text (wx-format.c:396-406): "3 PM" (on the hour, `minutes`
    /// false) or "3:45 PM".
    private static func clockText(_ dt: LocalTime, minutes: Bool) -> String {
        let h = dt.hour
        let m = dt.minute
        let ampm = h < 12 ? "AM" : "PM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        if m == 0 && !minutes {
            return "\(h12) \(ampm)"
        }
        return "\(h12):\(m < 10 ? "0" : "")\(m) \(ampm)"
    }

    /// when_phrase (wx-format.c:474-491): "around 4 PM" today, "tomorrow
    /// around 4 PM", "yesterday around 4 PM", "Friday around 4 PM" for any
    /// other day; "later" when either time is outside the time range.
    private static func whenPhrase(_ tS: Int64, nowS: Int64, zone: Zone) -> String {
        guard let dt = localTime(tS, zone), let now = localTime(nowS, zone) else {
            return "later"
        }
        let clock = clockText(dt, minutes: false)
        let diff = dt.dayNumber - now.dayNumber
        if diff == 0 {
            return "around \(clock)"
        }
        if diff == 1 {
            return "tomorrow around \(clock)"
        }
        if diff == -1 {
            return "yesterday around \(clock)"
        }
        return "\(dt.weekdayName) around \(clock)"
    }

    /// chance_text (wx-format.c:772-778): prefix + "40%" + suffix, or "" when
    /// `prob` is not a percentage.
    private static func chanceText(_ prob: Double, prefix: String, suffix: String) -> String {
        guard WxLimits.valueInRange(prob, WxLimits.percentMin, WxLimits.percentMax) else {
            return ""
        }
        return "\(prefix)\(cLround(prob))%\(suffix)"
    }

    /// intensity_word (wx-format.c:840-850), for a finite mm_h >= 0.
    private static func intensityWord(_ mmH: Double) -> String {
        if mmH < veryLightBelowMmH {
            return "Very light"
        }
        if mmH < lightBelowMmH {
            return "Light"
        }
        if mmH < moderateBelowMmH {
            return "Moderate"
        }
        return "Heavy"
    }

    /// g_ascii_strdown: only A-Z change.
    private static func asciiLower(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    /// cloud_band (wx-format.c:906-920): 0 Clear [0,12.5), 1 Mostly clear
    /// [12.5,37.5), 2 Partly cloudy [37.5,62.5), 3 Mostly cloudy
    /// [62.5,87.5), 4 Overcast [87.5,100]; nil when not a percentage.
    private static func cloudBand(_ pct: Double) -> Int? {
        guard WxLimits.valueInRange(pct, WxLimits.percentMin, WxLimits.percentMax) else {
            return nil
        }
        if pct < 12.5 {
            return 0
        }
        if pct < 37.5 {
            return 1
        }
        if pct < 62.5 {
            return 2
        }
        if pct < 87.5 {
            return 3
        }
        return 4
    }
}
