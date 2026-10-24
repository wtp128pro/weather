// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WxCondition.swift - the plain-language sky/precipitation class derived by
// the blend. Port of WxCondition (src/core/wx-types.h:629-646).
//
// The raw values are the C enum ordinals (UNKNOWN = 0 ... SLEET = 14). The
// forecast cache stores them as integers ("cond"), so they must never change.

/// Plain-language sky/precipitation class (WxCondition). `rawValue` is the C
/// ordinal persisted by the forecast cache.
public enum WxCondition: Int, CaseIterable, Sendable {
    case unknown = 0
    case clear = 1
    case mostlyClear = 2
    case partlyCloudy = 3
    case mostlyCloudy = 4
    case overcast = 5
    case fog = 6
    case drizzle = 7
    case lightRain = 8
    case rain = 9
    case heavyRain = 10
    case showers = 11
    case thunderstorm = 12
    case snow = 13
    case sleet = 14

    /// WX_COND_COUNT: the number of conditions (not a valid condition itself).
    public static let count = 15
}
