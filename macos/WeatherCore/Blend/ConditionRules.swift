// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ConditionRules.swift - plain-language sky / precipitation classes: the
// cloud-cover words, the condition derived for one blended hour, and their
// labels. Port of src/blend/wx-condition.{h,c}.
//
// Pure functions, total for every finite and non-finite input. Every NaN
// outcome follows the C comparisons literally (a comparison with NaN is
// false): an unknown cloud cover never gives showers, an unknown temperature
// never gives snow, an unknown probability does not stop a wet hour.
// C preconditions that Swift's types make unrepresentable (a NULL input, a
// NULL vote array with a count, a condition outside 0...14) have no port.

/// What `WxConditionRules.derive` looks at, for one hour (WxConditionInput,
/// src/blend/wx-condition.h:27-35).
public struct WxConditionInput: Sendable {
    /// Cloud cover 0...100, NaN unknown.
    public var cloudPct: Double
    /// Probability of precipitation 0...100, NaN unknown.
    public var precipProb: Double
    /// Precipitation over the hour, mm (= mm per hour).
    public var precipMmH: Double
    /// Air temperature, NaN unknown.
    public var tempC: Double
    /// WMO codes of the members at that hour; entries < 0 mean "no code".
    public var wmoVotes: [Int]

    public init(cloudPct: Double, precipProb: Double, precipMmH: Double, tempC: Double, wmoVotes: [Int] = []) {
        self.cloudPct = cloudPct
        self.precipProb = precipProb
        self.precipMmH = precipMmH
        self.tempC = tempC
        self.wmoVotes = wmoVotes
    }
}

/// The condition rules and labels (wx-condition.c).
public enum WxConditionRules {
    /// WX_WET_HOUR_MM (wx-condition.h:20): precipitation (mm per hour) from
    /// which an hour counts as wet.
    public static let wetHourMm = 0.1
    /// WX_WET_PROB_PCT (wx-condition.h:22): a wet hour whose probability is
    /// known must reach this many percent.
    public static let wetProbPct = 30.0

    /// Upper bounds of "clear", "mostly clear", ... in percent (wx-condition.c:10-13).
    private static let cloudClearMax = 12.5
    private static let cloudMostlyClearMax = 37.5
    private static let cloudPartlyMax = 62.5
    private static let cloudMostlyCloudyMax = 87.5

    /// Rain intensity bounds, mm per hour (wx-condition.c:16-18).
    private static let rateDrizzleMax = 0.5
    private static let rateLightMax = 2.5
    private static let rateRainMax = 7.6

    /// WMO code sets (wx-condition.c:119-122).
    private static let thunderCodes = [95, 96, 97, 99]
    private static let snowCodes = [71, 73, 75, 77, 85, 86]
    private static let sleetCodes = [56, 57, 66, 67]
    private static let fogCodes = [45, 48]

    /// SNOW_MAX_TEMP_C (wx-condition.c:125): highest air temperature at which
    /// snow codes are believed, degC.
    private static let snowMaxTempC = 2.0

    /// wx_is_wet_hour (wx-condition.c:21-25): `precipMm >= 0.1` and
    /// (`precipProb` is NaN or >= 30). Always false when `precipMm` is NaN.
    public static func isWetHour(precipMm: Double, precipProb: Double) -> Bool {
        precipMm >= wetHourMm && (precipProb.isNaN || precipProb >= wetProbPct)
    }

    /// wx_cloud_condition (wx-condition.c:28-42): [0, 12.5) clear, [12.5,
    /// 37.5) mostly clear, [37.5, 62.5) partly cloudy, [62.5, 87.5) mostly
    /// cloudy, from 87.5 overcast; below 0 clear, above 100 overcast (the
    /// infinities included); NaN unknown.
    public static func cloudCondition(_ cloudPct: Double) -> WxCondition {
        if cloudPct.isNaN {
            return .unknown
        }
        if cloudPct < cloudClearMax {
            return .clear
        }
        if cloudPct < cloudMostlyClearMax {
            return .mostlyClear
        }
        if cloudPct < cloudPartlyMax {
            return .partlyCloudy
        }
        if cloudPct < cloudMostlyCloudyMax {
            return .mostlyCloudy
        }
        return .overcast
    }

    /// wx_condition_rain_class (wx-condition.c:45-59): the class of a wet
    /// sample. Showers when `cloudPct < 87.5` and `precipMmH < 7.6` (a NaN
    /// cloud cover never gives showers), otherwise by intensity: below 0.5
    /// drizzle, below 2.5 light rain, below 7.6 rain, from 7.6 heavy rain.
    /// Unknown when `precipMmH` is NaN.
    public static func rainClass(cloudPct: Double, precipMmH: Double) -> WxCondition {
        if precipMmH.isNaN {
            return .unknown
        }
        if cloudPct < cloudMostlyCloudyMax && precipMmH < rateRainMax {
            return .showers
        }
        if precipMmH < rateDrizzleMax {
            return .drizzle
        }
        if precipMmH < rateLightMax {
            return .lightRain
        }
        if precipMmH < rateRainMax {
            return .rain
        }
        return .heavyRain
    }

    /// wx_condition_derive (wx-condition.c:128-147). First match wins:
    /// 1. at least half of the codes >= 0 (at least one needed) in
    ///    {95, 96, 97, 99}: thunderstorm;
    /// 2. `tempC <= 2` (NaN fails) and a majority in {71, 73, 75, 77, 85, 86}: snow;
    /// 3. a majority in {56, 57, 66, 67}: sleet;
    /// 4. a majority in {45, 48}: fog;
    /// 5. `isWetHour(precipMmH, precipProb)`: `rainClass(cloudPct, precipMmH)`;
    /// 6. otherwise `cloudCondition(cloudPct)`.
    /// Codes outside 0...99 count as supplying a code but are in no set.
    public static func derive(_ input: WxConditionInput) -> WxCondition {
        let v = input.wmoVotes
        if majorityIn(v, thunderCodes) {
            return .thunderstorm
        }
        if input.tempC <= snowMaxTempC && majorityIn(v, snowCodes) {
            return .snow
        }
        if majorityIn(v, sleetCodes) {
            return .sleet
        }
        if majorityIn(v, fogCodes) {
            return .fog
        }
        if isWetHour(precipMm: input.precipMmH, precipProb: input.precipProb) {
            return rainClass(cloudPct: input.cloudPct, precipMmH: input.precipMmH)
        }
        return cloudCondition(input.cloudPct)
    }

    /// wx_condition_label (wx-condition.c:149-173): the English label.
    public static func label(_ condition: WxCondition) -> String {
        switch condition {
        case .unknown: "Unknown"
        case .clear: "Clear"
        case .mostlyClear: "Mostly clear"
        case .partlyCloudy: "Partly cloudy"
        case .mostlyCloudy: "Mostly cloudy"
        case .overcast: "Overcast"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .lightRain: "Light rain"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .showers: "Showers"
        case .thunderstorm: "Thunderstorm"
        case .snow: "Snow"
        case .sleet: "Sleet"
        }
    }

    /// wx_cloud_label (wx-condition.c:176-180): `label(cloudCondition(cloudPct))`.
    public static func cloudLabel(_ cloudPct: Double) -> String {
        label(cloudCondition(cloudPct))
    }

    /// majority_in (wx-condition.c:103-117): true iff at least one code is
    /// >= 0 and at least half of the codes >= 0 are in `set` (a 50 % tie
    /// counts). The counts are compared in 64 bits as in C.
    private static func majorityIn(_ votes: [Int], _ set: [Int]) -> Bool {
        var supplied: UInt64 = 0
        var hits: UInt64 = 0
        for code in votes {
            if code < 0 {
                continue
            }
            supplied += 1
            if set.contains(code) {
                hits += 1
            }
        }
        return supplied > 0 && hits * 2 >= supplied
    }
}
