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
//
// Alerts section (not in the GTK pane): one card per alert current at the
// item's "now" (RowViewModel.currentAlerts: only a `.current` result, nothing
// expired or ended at "now"), highest level first, with its event, level,
// effective and end times ("Today 3:00 PM", "Friday 6:00 AM"; formatted with
// the held zone of the ITEM's place, the zone of the pane's texts), headline,
// description, instruction and the issuer's https link (an NWS card always
// has one: the NWS's own http weather.gov page upgraded to https, else the NWS
// site; another issuer's http page is never linked); and one text per state of
// the result: checking (not fetched), "No active alerts" (current, none),
// could not be checked (unavailable; stale, with the last check when known: a
// stale set is never shown as cards) and "Alerts not available" (not covered).

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

        public init(
            startS: Int64,
            isNow: Bool,
            hour: String,
            symbolName: String,
            gtkIconName: String,
            temp: String,
            rain: String,
            cloud: String,
            tooltip: String,
            conditionCode: WxCondition,
            isDay: Bool
        ) {
            self.startS = startS
            self.isNow = isNow
            self.hour = hour
            self.symbolName = symbolName
            self.gtkIconName = gtkIconName
            self.temp = temp
            self.rain = rain
            self.cloud = cloud
            self.tooltip = tooltip
            self.conditionCode = conditionCode
            self.isDay = isDay
        }

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

        public init(
            startS: Int64,
            day: String,
            symbolName: String,
            gtkIconName: String,
            rain: String,
            low: String,
            high: String,
            tooltip: String,
            conditionCode: WxCondition
        ) {
            self.startS = startS
            self.day = day
            self.symbolName = symbolName
            self.gtkIconName = gtkIconName
            self.rain = rain
            self.low = low
            self.high = high
            self.tooltip = tooltip
            self.conditionCode = conditionCode
        }

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

    /// One card of the alerts section: a current official alert of the place.
    public struct AlertCard: Sendable, Equatable, Identifiable {
        /// The alert's id ("<source>:<issuer id>", stable across refreshes).
        public let id: String
        /// The event name ("Tornado Warning").
        public let event: String
        /// The normalized level (the card's colour).
        public let level: WxAlert.Level
        /// The level's name (RowViewModel.alertLevelTitle): "Red", "Orange", "Yellow", "Minor",
        /// "Unknown".
        public let severity: String
        /// When the event begins (WxAlert.onsetS) in the place's zone, "Today 3:00 PM"; nil when
        /// unknown or outside the time range.
        public let effective: String?
        /// When it ends (WxAlert.untilS: the event end, else the message expiry) in the place's
        /// zone, "Tomorrow 6:00 AM"; nil when open-ended or outside the time range.
        public let expires: String?
        /// The issuer's headline.
        public let headline: String
        /// The description ("" when missing; shown expandable).
        public let description: String
        /// The recommended actions ("" when missing).
        public let instruction: String
        /// The issuer's name ("National Weather Service").
        public let sourceName: String
        /// The issuer's page for the alert, always https (link(_:)): nil when a non-NWS issuer gave
        /// none or no linkable https URL.
        public let link: String?

        public init(id: String, event: String, level: WxAlert.Level, severity: String, effective: String?,
                    expires: String?, headline: String, description: String, instruction: String,
                    sourceName: String, link: String?) {
            self.id = id
            self.event = event
            self.level = level
            self.severity = severity
            self.effective = effective
            self.expires = expires
            self.headline = headline
            self.description = description
            self.instruction = instruction
            self.sourceName = sourceName
            self.link = link
        }

        /// The NWS site, linked by an NWS card whose own page is not an https one, as Bright Sky
        /// and ECCC alerts link their issuer's site (WxPointAlerts.dwdWarningsURL,
        /// WxECCCAlerts.weatherURL).
        public static let nwsWebURL = "https://www.weather.gov/"

        /// The card of `alert`, its times in `zone` relative to `nowS`.
        nonisolated static func card(_ alert: WxAlert, nowS: Int64, zone: WxFormat.Zone) -> AlertCard {
            AlertCard(
                id: alert.id, event: alert.event, level: alert.level,
                severity: RowViewModel.alertLevelTitle(alert.level),
                effective: alert.onsetS.flatMap { AlertsSection.when($0, nowS: nowS, zone: zone) },
                expires: alert.untilS.flatMap { AlertsSection.when($0, nowS: nowS, zone: zone) },
                headline: alert.headline, description: alert.description, instruction: alert.instruction,
                sourceName: AlertsSection.sourceName(alert.source), link: link(alert))
        }

        /// The card's link: the alert's page when it is linkable (DetailViewModel.isLinkable: https
        /// only). An NWS alert always has one: its own http page on weather.gov upgraded to https
        /// (the NWS sends "http://www.weather.gov" on every alert), else nwsWebURL. Any other
        /// issuer's http page stays unlinked: no other host is upgraded.
        nonisolated static func link(_ alert: WxAlert) -> String? {
            if let web = alert.web, DetailViewModel.isLinkable(urlBytes: Array(web.utf8)) {
                return web
            }
            guard alert.source == .nws else {
                return nil
            }
            if let upgraded = alert.web.flatMap(httpsWeatherGov),
               DetailViewModel.isLinkable(urlBytes: Array(upgraded.utf8)) {
                return upgraded
            }
            return nwsWebURL
        }

        /// `url` over https when it is an http URL whose host is weather.gov or one of its
        /// subdomains (non-empty labels of ASCII letters, digits and '-'; no user, no port), with
        /// its path, query and fragment kept ("/" when there is none); nil for any other URL.
        nonisolated static func httpsWeatherGov(_ url: String) -> String? {
            let bytes = Array(url.utf8), scheme = Array("http://".utf8)
            guard bytes.starts(with: scheme) else {
                return nil
            }
            let rest = bytes[scheme.count...]
            let end = rest.firstIndex {
                $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#")
            } ?? rest.endIndex
            let host = rest[..<end]
            let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
            let hostByte = { (c: UInt8) in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) || c == UInt8(ascii: "-")
            }
            guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(hostByte) }),
                  labels.suffix(2).map({ String(decoding: $0, as: UTF8.self).lowercased() }) == ["weather", "gov"]
            else {
                return nil
            }
            let tail = rest[end...]
            return "https://" + String(decoding: host, as: UTF8.self)
                + (tail.isEmpty ? "/" : String(decoding: tail, as: UTF8.self))
        }
    }

    /// The alerts section of the pane: the cards of the current alerts, else the text of the state.
    public struct AlertsSection: Sendable, Equatable {
        public static let title = "Alerts"
        /// Not fetched: the first answer is still to come.
        public static let checkingText = "Checking for alerts\u{2026}"
        /// Current, without an alert at "now".
        public static let noAlertsText = "No active alerts"
        /// Unavailable: the latest attempt failed.
        public static let unavailableText = "Alerts could not be checked right now."
        /// Stale: the latest answer is older than its source's window (followed by the last check).
        public static let staleText = "Alerts could not be checked recently."
        /// Not covered: no source answers for the place.
        public static let notCoveredText = "Alerts not available"

        /// The state of the place's alerts result.
        public let state: WxAlertsResult.State
        /// One card per alert current at "now", highest level first; empty unless `.current`.
        public let cards: [AlertCard]
        /// The text of the state; nil while cards are shown.
        public let text: String?
        /// A spinner is shown beside the text (not fetched: checking).
        public let showsSpinner: Bool
        /// The issuer routed to ("MET Norway"); nil when none covers the place.
        public let sourceName: String?

        public init(state: WxAlertsResult.State, cards: [AlertCard], text: String?, showsSpinner: Bool,
                    sourceName: String?) {
            self.state = state
            self.cards = cards
            self.text = text
            self.showsSpinner = showsSpinner
            self.sourceName = sourceName
        }

        /// The section of `result` at `nowS`, times in `zone` (the item's place zone).
        nonisolated static func section(_ result: WxAlertsResult, nowS: Int64, zone: WxFormat.Zone) -> AlertsSection {
            let cards = RowViewModel.currentAlerts(result, nowS: nowS).map {
                AlertCard.card($0, nowS: nowS, zone: zone)
            }
            let text: String?
            switch result.state {
            case .notFetched:
                text = checkingText
            case .current:
                text = cards.isEmpty ? noAlertsText : nil
            case .stale:
                text = staleText + (result.fetchedS.flatMap { when($0, nowS: nowS, zone: zone) }
                    .map { " Last checked: " + $0 + "." } ?? "")
            case .unavailable:
                text = unavailableText
            case .notCovered:
                text = notCoveredText
            }
            return AlertsSection(state: result.state, cards: cards, text: text,
                                 showsSpinner: result.state == .notFetched,
                                 sourceName: result.source.map(sourceName))
        }

        /// "<day> <clock>" of `tS` in `zone`: "Today 3:00 PM", "Tomorrow 6:00 AM", "Friday 4:30 PM"
        /// (WxFormat.weekday relative to `nowS`, WxFormat.clock); nil outside the time range.
        nonisolated static func when(_ tS: Int64, nowS: Int64, zone: WxFormat.Zone) -> String? {
            guard WxFormat.timeOK(tS) else {
                return nil
            }
            return WxFormat.weekday(tS, zone: zone, nowS: nowS) + " " + WxFormat.clock(tS, zone: zone)
        }

        /// The issuer's name (WxAlert.Source).
        public nonisolated static func sourceName(_ source: WxAlert.Source) -> String {
            switch source {
            case .nws: "National Weather Service"
            case .dwd: "Deutscher Wetterdienst"
            case .metNorway: "MET Norway"
            case .eccc: "Environment and Climate Change Canada"
            case .meteoAlarm: "MeteoAlarm"
            }
        }
    }
}
