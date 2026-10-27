// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FormatSymbols.swift - the condition-to-icon table. Port of wx_icon_name
// (src/widgets/wx-icons.{h,c}): the GTK app shows Adwaita symbolic theme
// icons, which do not exist on macOS, so every row maps to an SF Symbol and
// keeps the GTK icon name it replaces beside it. The GROUPING of the C table
// is kept exactly (wx-icons.h:23-36): only clear and mostly-clear /
// partly-cloudy skies have a night variant; mostly cloudy and overcast share
// one glyph; drizzle, light rain and showers share the scattered-showers
// glyph; rain and heavy rain share the showers glyph; sleet shares the snow
// glyph (Adwaita has no freezing-rain icon, and the table is not changed
// although SF Symbols has one); UNKNOWN and every raw value outside the enum
// (a value read from a cache file) get the question mark.
//
// | condition                        | SF Symbol (day / night)  | GTK icon (day / night)                                        |
// | unknown, any other raw value     | questionmark.circle      | dialog-question-symbolic                                      |
// | clear                            | sun.max / moon.stars     | weather-clear-symbolic / weather-clear-night-symbolic         |
// | mostlyClear, partlyCloudy        | cloud.sun / cloud.moon   | weather-few-clouds-symbolic / weather-few-clouds-night-symbolic |
// | mostlyCloudy, overcast           | cloud                    | weather-overcast-symbolic                                     |
// | fog                              | cloud.fog                | weather-fog-symbolic                                          |
// | drizzle, lightRain, showers      | cloud.drizzle            | weather-showers-scattered-symbolic                            |
// | rain, heavyRain                  | cloud.rain               | weather-showers-symbolic                                      |
// | thunderstorm                     | cloud.bolt.rain          | weather-storm-symbolic                                        |
// | snow, sleet                      | cloud.snow               | weather-snow-symbolic                                         |

/// The condition-to-symbol mapping (wx-icons.h).
public enum WxConditionSymbol {
    /// One row of the table: the SF Symbol and the GTK icon name it replaces.
    public struct Entry: Sendable, Equatable {
        /// SF Symbol name (exists in the macOS 27 SDK; FormatTests checks it).
        public let symbolName: String
        /// The Adwaita icon name of the C app (wx_icon_name) that it replaces.
        public let gtkIconName: String
    }

    /// The entry for `condition` (`isDay` false selects the night variant
    /// where one exists).
    public static func entry(_ condition: WxCondition, isDay: Bool) -> Entry {
        entry(conditionRawValue: condition.rawValue, isDay: isDay)
    }

    /// The entry for a raw condition value: total, every value outside the
    /// enum is treated like `.unknown` (wx-icons.h:21-22, 39-41).
    public static func entry(conditionRawValue raw: Int, isDay: Bool) -> Entry {
        switch WxCondition(rawValue: raw) {
        case .clear:
            return isDay
                ? Entry(symbolName: "sun.max", gtkIconName: "weather-clear-symbolic")
                : Entry(symbolName: "moon.stars", gtkIconName: "weather-clear-night-symbolic")
        case .mostlyClear, .partlyCloudy:
            return isDay
                ? Entry(symbolName: "cloud.sun", gtkIconName: "weather-few-clouds-symbolic")
                : Entry(symbolName: "cloud.moon", gtkIconName: "weather-few-clouds-night-symbolic")
        case .mostlyCloudy, .overcast:
            return Entry(symbolName: "cloud", gtkIconName: "weather-overcast-symbolic")
        case .fog:
            return Entry(symbolName: "cloud.fog", gtkIconName: "weather-fog-symbolic")
        case .drizzle, .lightRain, .showers:
            return Entry(symbolName: "cloud.drizzle", gtkIconName: "weather-showers-scattered-symbolic")
        case .rain, .heavyRain:
            return Entry(symbolName: "cloud.rain", gtkIconName: "weather-showers-symbolic")
        case .thunderstorm:
            return Entry(symbolName: "cloud.bolt.rain", gtkIconName: "weather-storm-symbolic")
        case .snow, .sleet:
            return Entry(symbolName: "cloud.snow", gtkIconName: "weather-snow-symbolic")
        case .unknown, nil:
            return Entry(symbolName: "questionmark.circle", gtkIconName: "dialog-question-symbolic")
        }
    }

    /// The SF Symbol name for `condition`.
    public static func symbolName(_ condition: WxCondition, isDay: Bool) -> String {
        entry(condition, isDay: isDay).symbolName
    }

    /// The bundled rich weather icon asset name for `condition` (`isDay` false selects the night
    /// variant where one exists).
    public static func assetName(_ condition: WxCondition, isDay: Bool) -> String {
        assetName(conditionRawValue: condition.rawValue, isDay: isDay)
    }

    /// The bundled rich weather icon asset name for a raw condition value.
    public static func assetName(conditionRawValue raw: Int, isDay: Bool) -> String {
        switch WxCondition(rawValue: raw) {
        case .clear:
            return isDay ? "wx-clear-day" : "wx-clear-night"
        case .mostlyClear:
            return isDay ? "wx-mostly-clear-day" : "wx-mostly-clear-night"
        case .partlyCloudy:
            return isDay ? "wx-partly-cloudy-day" : "wx-partly-cloudy-night"
        case .mostlyCloudy:
            return isDay ? "wx-mostly-cloudy-day" : "wx-mostly-cloudy-night"
        case .overcast:
            return "wx-overcast"
        case .fog:
            return isDay ? "wx-fog-day" : "wx-fog-night"
        case .drizzle:
            return isDay ? "wx-drizzle-day" : "wx-drizzle-night"
        case .lightRain:
            return isDay ? "wx-light-rain-day" : "wx-light-rain-night"
        case .showers:
            return isDay ? "wx-showers-day" : "wx-showers-night"
        case .rain:
            return isDay ? "wx-rain-day" : "wx-rain-night"
        case .heavyRain:
            return isDay ? "wx-heavy-rain-day" : "wx-heavy-rain-night"
        case .thunderstorm:
            return isDay ? "wx-thunderstorm-day" : "wx-thunderstorm-night"
        case .snow:
            return isDay ? "wx-snow-day" : "wx-snow-night"
        case .sleet:
            return isDay ? "wx-sleet-day" : "wx-sleet-night"
        case .unknown, nil:
            return "wx-unknown"
        }
    }

    /// Precipitation severity rank used to ensure daily forecast icons never show dry clouds when
    /// hourly slots on the same day show rain, snow, sleet, or thunderstorms.
    public static func precipitationRank(_ condition: WxCondition) -> Int {
        switch condition {
        case .thunderstorm: return 8
        case .snow: return 7
        case .sleet: return 6
        case .heavyRain: return 5
        case .rain: return 4
        case .showers: return 3
        case .lightRain: return 2
        case .drizzle: return 1
        default: return 0
        }
    }

    /// Resolves the visual condition for an hourly slot so that sub-freezing wet hours display
    /// snow/sleet and probable wet hours display a rain/snow icon rather than a dry cloud icon:
    /// a dry-sky hour is overridden at >= 30% chance with model precipitation (precipMm >= 0.05 mm
    /// or precipMmMax >= 0.1 mm), or at >= 40% chance on probability alone.
    public static func effectiveHourlyCondition(for h: WxBlendHour) -> WxCondition {
        let base = h.condition
        let isRainClass: Bool = switch base {
        case .drizzle, .lightRain, .showers, .rain, .heavyRain: true
        default: false
        }
        if isRainClass {
            if h.tempC.isFinite && h.tempC <= 0.5 {
                return .snow
            }
            if h.tempC.isFinite && h.tempC <= 1.8 {
                return .sleet
            }
            if base == .showers, h.precipMm.isFinite, h.precipMm >= 2.5 {
                return .rain
            }
            return base
        }

        let isDrySky: Bool = switch base {
        case .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast: true
        default: false
        }
        if isDrySky, h.precipProb.isFinite, h.precipProb >= 30.0 {
            let hasModelPrecip = (h.precipMm.isFinite && h.precipMm >= 0.05)
                || (h.precipMmMax.isFinite && h.precipMmMax >= 0.1)
                || h.precipProb >= 40.0
            if hasModelPrecip {
                if h.tempC.isFinite && h.tempC <= 0.5 {
                    return .snow
                }
                if h.tempC.isFinite && h.tempC <= 1.8 {
                    return .sleet
                }
                let rate = max(
                    h.precipMm.isFinite ? h.precipMm : 0.0,
                    h.precipMmMax.isFinite ? h.precipMmMax * 0.5 : 0.3,
                    0.3
                )
                return WxConditionRules.rainClass(cloudPct: h.cloudPct, precipMmH: rate)
            }
        }
        return base
    }

    /// Resolves the visual condition for a daily forecast row so that any day whose hourly
    /// forecast (or 15-minute nowcast of >= 0.1 mm, or daily precipitation probability >= 30%
    /// with >= 0.1 mm, or >= 35% on probability alone) includes rain, snow, sleet, or
    /// thunderstorms displays a clear precipitation icon rather than a dry cloud icon.
    public static func effectiveDailyCondition(
        for d: WxDay,
        hours: [WxBlendHour],
        quarters: [WxQuarter] = [],
        zone: WxFormat.Zone
    ) -> WxCondition {
        let dayStart = d.startS
        let rawEnd = WxFormat.localDayEnd(d.startS, zone: zone)
        let dayEnd = rawEnd > dayStart ? rawEnd : (dayStart + 86_400)

        var dayCond = d.condition
        switch dayCond {
        case .drizzle, .lightRain, .showers, .rain, .heavyRain:
            if d.tempMaxC.isFinite && d.tempMaxC <= 1.0 {
                dayCond = .snow
            } else if d.tempMinC.isFinite && d.tempMinC <= 0.0 && d.tempMaxC.isFinite && d.tempMaxC <= 2.5 {
                dayCond = .sleet
            }
        default:
            break
        }

        // Check all hourly slots belonging to this local calendar day
        var bestHourPrecip: WxCondition = .unknown
        for h in hours where h.tS >= dayStart && h.tS < dayEnd {
            let hc = effectiveHourlyCondition(for: h)
            if precipitationRank(hc) > precipitationRank(bestHourPrecip) {
                bestHourPrecip = hc
            }
        }
        if precipitationRank(bestHourPrecip) > precipitationRank(dayCond) {
            dayCond = bestHourPrecip
        }

        // Check 15-minute nowcast quarters within this local calendar day
        if precipitationRank(dayCond) == 0 {
            let hasNowcastRain = quarters.contains { q in
                q.tS >= dayStart && q.tS < dayEnd && q.precipMm.isFinite && q.precipMm >= 0.1
            }
            if hasNowcastRain {
                dayCond = (d.tempMaxC.isFinite && d.tempMaxC <= 1.0) ? .snow : .rain
            }
        }

        // Check daily precipitation totals & probability (e.g. days beyond the 48h hourly horizon
        // or days with 30%-49% rain probability where WxDaily's strict 50%/1mm gate fell back to clouds)
        if precipitationRank(dayCond) == 0,
           d.precipProbMax.isFinite,
           d.precipProbMax >= 30.0,
           (d.precipMm.isFinite && d.precipMm >= 0.1) || d.precipProbMax >= 35.0
        {
            if d.tempMaxC.isFinite && d.tempMaxC <= 1.0 {
                dayCond = .snow
            } else if d.tempMinC.isFinite && d.tempMinC <= 0.0 && d.tempMaxC.isFinite && d.tempMaxC <= 2.5 {
                dayCond = .sleet
            } else {
                let rate = max(d.precipMm.isFinite ? d.precipMm / 4.0 : 0.6, 0.6)
                dayCond = WxConditionRules.rainClass(cloudPct: d.cloudPct, precipMmH: rate)
            }
        }

        return dayCond
    }
}
