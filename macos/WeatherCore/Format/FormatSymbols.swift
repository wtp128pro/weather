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
}
