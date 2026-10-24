// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailLists.swift - the data of the hour strip (src/widgets/wx-hour-strip.{h,c})
// and of the day list (src/widgets/wx-day-list.{h,c}) of the detail pane.
//
// Hour strip: at most 48 cards, the first is the first hour that has not ended
// at "now" (t_s > now - 3600); it is "Now" when it has begun, and then shows
// the values AT now (WxBlend.now: interpolated temperature, feels-like, wind
// and cloud, the sun at now) with the clock of now in its tooltip. Nothing
// without a forecast or with "now" outside the valid time range.
//
// Day list: at most 10 rows from the first day whose own local end
// (WxFormat.localDayEnd in the held zone) has not passed; day labels
// "Today" / "Tomorrow" / weekday by local dates; the icon is always the day
// variant; the tooltip of a day the forecast covers only partly says "Covers
// the rest of the day, from 2 PM." (WxFormat.dayCoveredFrom).
//
// Both are formatted with the held zone of the forecast's place
// (WxFormat.Zone), never with a lookup.

extension DetailViewModel {
    /// One card of the hour strip (wx-hour-strip.c:119-138).
    public struct HourCard: Sendable, Equatable, Identifiable {
        /// WX_HOUR_STRIP_MAX_CARDS (wx-hour-strip.h:46).
        public static let maxCards = 48

        /// The start of the card's hour, UTC unix seconds (its identity; the "Now" card shows the
        /// values and, in its tooltip, the clock time AT now).
        public let startS: Int64
        public var id: Int64 { startS }
        /// The first card, begun at "now".
        public let isNow: Bool
        /// "Now", else the local hour ("3 PM").
        public let hour: String
        /// SF Symbol of the condition (day or night by the hour's isDay).
        public let symbolName: String
        /// The C icon name it replaces (wx_icon_name).
        public let gtkIconName: String
        /// The temperature without unit ("77°").
        public let temp: String
        /// "Rain 20%" (dim).
        public let rain: String
        /// "Cloud 40%" (dim).
        public let cloud: String
        /// "<clock>\nFeels like <temp with unit>\nWind <wind>\nRain <amount>".
        public let tooltip: String
        /// The hour's sky/precipitation condition enum.
        public let conditionCode: WxCondition
        /// Whether this hour is during daylight.
        public let isDay: Bool

        /// Bundled rich multi-color weather icon asset name.
        public var iconAssetName: String {
            WxConditionSymbol.assetName(conditionCode, isDay: isDay)
        }

        /// Parsed integer display temperature, nil when unknown ("—").
        public var tempValue: Int? {
            guard let degIdx = temp.firstIndex(of: "\u{00B0}") else { return nil }
            return Int(temp[..<degIdx])
        }

        /// Parsed integer rain probability (0...100), nil when unknown.
        public var rainPercent: Int? {
            guard let pctIdx = rain.firstIndex(of: "%"),
                  let spaceIdx = rain[..<pctIdx].lastIndex(of: " ")
            else { return nil }
            return Int(rain[rain.index(after: spaceIdx)..<pctIdx])
        }

        /// Parsed integer cloud cover (0...100), nil when unknown.
        public var cloudPercent: Int? {
            guard let pctIdx = cloud.firstIndex(of: "%"),
                  let spaceIdx = cloud[..<pctIdx].lastIndex(of: " ")
            else { return nil }
            return Int(cloud[cloud.index(after: spaceIdx)..<pctIdx])
        }

        /// wx_hour_strip_set_forecast (wx-hour-strip.c:240-293): the cards of `forecast` at
        /// `nowS` in `units`, formatted with `zone` (the held zone of `forecast.place.timezone`).
        public static func cards(forecast: WxForecast?, units: WxUnits, nowS: Int64,
                                 zone: WxFormat.Zone) -> [HourCard] {
            guard let forecast, nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
                return []
            }
            let hours = forecast.hours
            var first = 0
            while first < hours.count && hours[first].tS <= nowS - 3600 {
                first += 1
            }
            let n = min(hours.count - first, maxCards)
            var out: [HourCard] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                var h = hours[first + i]
                let startS = h.tS
                let isNow = i == 0 && h.tS <= nowS
                if isNow, let current = WxBlend.now(forecast, nowS: nowS) {
                    h = current
                }
                let entry = WxConditionSymbol.entry(h.condition, isDay: h.isDay)
                let tooltip = WxFormat.clock(h.tS, zone: zone)
                    + "\nFeels like " + WxFormat.temp(h.feelsC, units: units, withUnit: true)
                    + "\nWind " + WxFormat.wind(h.windKmh, units: units)
                    + "\nRain " + WxFormat.precip(h.precipMm, units: units)
                out.append(HourCard(
                    startS: startS, isNow: isNow, hour: isNow ? "Now" : WxFormat.hourLabel(h.tS, zone: zone),
                    symbolName: entry.symbolName, gtkIconName: entry.gtkIconName,
                    temp: WxFormat.temp(h.tempC, units: units, withUnit: false),
                    rain: "Rain " + WxFormat.percent(h.precipProb),
                    cloud: "Cloud " + WxFormat.percent(h.cloudPct), tooltip: tooltip,
                    conditionCode: WxConditionSymbol.effectiveHourlyCondition(for: h), isDay: h.isDay))
            }
            return out
        }
    }

    /// One row of the day list (wx-day-list.c:121-141).
    public struct DayRow: Sendable, Equatable, Identifiable {
        /// WX_DAY_LIST_MAX_ROWS (wx-day-list.h:39).
        public static let maxRows = 10

        /// The day's start, UTC unix seconds.
        public let startS: Int64
        public var id: Int64 { startS }
        /// "Today", "Tomorrow" or the weekday ("Saturday").
        public let day: String
        /// SF Symbol of the condition, always the day variant.
        public let symbolName: String
        /// The C icon name it replaces (wx_icon_name(condition, TRUE)).
        public let gtkIconName: String
        /// The chance of rain ("10%", dim).
        public let rain: String
        /// The low temperature without unit (dim).
        public let low: String
        /// The high temperature without unit.
        public let high: String
        /// "Rain <amount>, <chance> chance\nCloud cover <pct>" plus
        /// "\nCovers the rest of the day, from 2 PM." for a partly covered day.
        public let tooltip: String
        /// The day's sky/precipitation condition enum.
        public let conditionCode: WxCondition

        /// Bundled rich multi-color weather icon asset name (always day variant).
        public var iconAssetName: String {
            WxConditionSymbol.assetName(conditionCode, isDay: true)
        }

        /// Parsed integer low temperature, nil when unknown ("—").
        public var lowValue: Int? {
            guard let degIdx = low.firstIndex(of: "\u{00B0}") else { return nil }
            return Int(low[..<degIdx])
        }

        /// Parsed integer high temperature, nil when unknown ("—").
        public var highValue: Int? {
            guard let degIdx = high.firstIndex(of: "\u{00B0}") else { return nil }
            return Int(high[..<degIdx])
        }

        /// Parsed integer rain chance (0...100), nil when unknown ("—").
        public var rainPercent: Int? {
            guard let pctIdx = rain.firstIndex(of: "%") else { return nil }
            return Int(rain[..<pctIdx])
        }

        /// wx_day_list_set_forecast (wx-day-list.c:268-329): the rows of `forecast` at `nowS`
        /// in `units`, with day ends and labels in `zone` (the held zone of
        /// `forecast.place.timezone`).
        public static func rows(forecast: WxForecast?, units: WxUnits, nowS: Int64,
                                zone: WxFormat.Zone) -> [DayRow] {
            guard let forecast, nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
                return []
            }
            let days = forecast.days
            var first = 0
            // A day is over when ITS OWN local end has passed, whether or not the next day is listed.
            while first < days.count && days[first].startS <= nowS {
                let end = WxFormat.localDayEnd(days[first].startS, zone: zone)
                if end == 0 || end > nowS {
                    break
                }
                first += 1
            }
            let n = min(days.count - first, maxRows)
            var out: [DayRow] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                let d = days[first + i]
                let prob = WxFormat.percent(d.precipProbMax)
                let fromS = WxFormat.dayCoveredFrom(forecast, day: d, nowS: nowS)
                let partial = fromS != 0
                    ? "\nCovers the rest of the day, from \(WxFormat.hourLabel(fromS, zone: zone))." : ""
                let entry = WxConditionSymbol.entry(d.condition, isDay: true)
                let effectiveCond = WxConditionSymbol.effectiveDailyCondition(
                    for: d,
                    hours: forecast.hours,
                    quarters: forecast.quarters,
                    zone: zone
                )
                out.append(DayRow(
                    startS: d.startS, day: WxFormat.weekday(d.startS, zone: zone, nowS: nowS),
                    symbolName: entry.symbolName, gtkIconName: entry.gtkIconName, rain: prob,
                    low: WxFormat.temp(d.tempMinC, units: units, withUnit: false),
                    high: WxFormat.temp(d.tempMaxC, units: units, withUnit: false),
                    tooltip: "Rain \(WxFormat.precip(d.precipMm, units: units)), \(prob) chance\nCloud cover "
                        + WxFormat.percent(d.cloudPct) + partial,
                    conditionCode: effectiveCond))
            }
            return out
        }
    }
}
