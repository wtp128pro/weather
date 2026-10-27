// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailViewModel.swift - the presentation logic of the detail pane, a port of
// src/ui/wx-detail.{h,c} (WxDetail) without GTK.
//
// The pane shows ONE item (the selected place: AppModel.Place, or a hand-built
// DetailViewModel.Item) and derives everything from it: its forecast, place,
// units, "now", loading / stale / offline flags, error text and fetch time; the
// current conditions (WxBlend.now) and the rain outlook (WxRainRules.outlook,
// claimed only as wx_row_item_get_outlook does, wx-row.c:230-282). It never
// reads a clock, never mutates the item and does no I/O.
//
// Pages (wx-detail.h:7-36): .placeholder without a forecast - in the order no
// item, loading, error, offline, otherwise - and .forecast with, in order, the
// header, the "now" block, the Rain card (headline, detail, the 2-hour nowcast
// chart only while it has data, the 24-hour chart always), the Clouds card, the
// 48-hour strip, the day list, the footer row (updated + sources, refresh
// spinner, Offline / Stale badges), the attribution line and the partial line.
//
// Alerts (not in the GTK pane): `alerts` is the alerts section of the shown
// item (DetailLists.swift: the cards of its current alerts, else the text of
// the state of its WxAlertsResult), nil without an item. It is held beside
// `page`, not in it: it does not depend on the forecast (a place without one
// has alerts too) and it changes on its own (compare before set as well; a
// change of the alerts alone does not touch `page` or `revision`).
//
// Compare before set (wx-detail.h:98-101): show(_:) assigns `page` only when
// the new page differs from the shown one, so an unchanged refresh notifies no
// observer and leaves `revision` alone.
//
// Zones: the view model holds one WxFormat.HeldZone per zone name the C pane
// resolves - the item's place zone (the texts of the pane: High/Low day end,
// rain and cloud sentences) and the forecast's place zone (the zone the C
// chart, strip and day list hold) - and formats with the zone: overloads only.

import Observation

/// The detail pane (WxDetail, src/ui/wx-detail.h).
@MainActor
@Observable
public final class DetailViewModel {
    /// What the pane shows of one place (the WxRowItem state the pane reads).
    public struct Item: Sendable {
        /// The place (wx_row_item_get_place).
        public let place: WxPlace
        /// The forecast, nil for none.
        public let forecast: WxForecast?
        /// When `forecast` was fetched, UTC unix seconds (any value).
        public let fetchedS: Int64
        /// A request is in flight.
        public let loading: Bool
        /// The latest request failed.
        public let stale: Bool
        /// The network is unavailable.
        public let offline: Bool
        /// The unit system.
        public let units: WxUnits
        /// The item's "now", UTC unix seconds (any value).
        public let nowS: Int64
        /// The error text: sanitised like wx_row_item_set_error (wx-row.c:504-516) to at most
        /// AppModel.errorTextMaxBytes bytes; nil when none or empty after sanitising.
        public let errorText: String?
        /// The place's alerts as the alerts service reports them (AppModel.Place.alerts).
        public let alerts: WxAlertsResult

        public init(place: WxPlace, forecast: WxForecast? = nil, fetchedS: Int64 = 0, loading: Bool = false,
                    stale: Bool = false, offline: Bool = false, units: WxUnits = .imperial, nowS: Int64,
                    errorText: String? = nil, alerts: WxAlertsResult = AppModel.alertsNotFetched) {
            self.place = place
            self.forecast = forecast
            self.fetchedS = fetchedS
            self.loading = loading
            self.stale = stale
            self.offline = offline
            self.units = units
            self.nowS = nowS
            let clean = errorText.map { WxText.sanitize($0, maxBytes: AppModel.errorTextMaxBytes) }
            self.errorText = clean?.isEmpty == false ? clean : nil
            self.alerts = alerts
        }

        /// The item of a place of the application model (selectedPlace).
        public init(_ p: AppModel.Place) {
            self.init(place: p.place, forecast: p.forecast, fetchedS: p.fetchedS, loading: p.loading,
                      stale: p.stale, offline: p.offline, units: p.units, nowS: p.nowS, errorText: p.errorText,
                      alerts: p.alerts)
        }
    }

    /// The placeholder page (wx-detail.h:22-36).
    public struct Placeholder: Sendable, Equatable {
        /// "wx-detail-placeholder-title".
        public let title: String
        /// "wx-detail-placeholder-text" (wrapping, centred).
        public let text: String
        /// "wx-detail-spinner": visible and spinning iff the item is loading (and has no forecast).
        public let showsSpinner: Bool
        /// The spinner's accessible label.
        public static let spinnerAccessibilityLabel = "Loading"
    }

    /// The "now" block (wx-detail.h:44-61).
    public struct Now: Sendable, Equatable {
        /// SF Symbol of the current condition ("questionmark.circle" without conditions).
        public let symbolName: String
        /// The C icon name it replaces (wx_icon_name).
        public let gtkIconName: String
        /// The image's accessible label: the condition label ("Partly cloudy", "Unknown").
        public let iconAccessibilityLabel: String
        /// The temperature with unit ("77°F").
        public let temperature: String
        /// The condition label.
        public let condition: String
        /// "Feels like 75°".
        public let feelsLike: String
        /// "High 80° · Low 65°" (+ " (from 2 PM)") of today; nil (hidden) when no day contains "now".
        public let highLow: String?
        /// "Wind 12 mph, gusts 20 mph".
        public let wind: String
        /// The current sky/precipitation condition enum.
        public let conditionCode: WxCondition
        /// Whether it is currently daytime at the place.
        public let isDay: Bool
        /// The structured wind for the dial (speed, gusts, direction, VoiceOver label).
        public let windDial: NowWind
        /// "Humidity 40%"; nil when not supplied.
        public let humidity: String?

        public init(
            symbolName: String,
            gtkIconName: String,
            iconAccessibilityLabel: String,
            temperature: String,
            condition: String,
            feelsLike: String,
            highLow: String?,
            wind: String,
            conditionCode: WxCondition,
            isDay: Bool,
            windDial: NowWind = NowWind.make(windKmh: .nan, gustKmh: .nan, directionDeg: nil, units: .imperial,
                                             gustMarginKmh: 0),
            humidity: String? = nil
        ) {
            self.symbolName = symbolName
            self.gtkIconName = gtkIconName
            self.iconAccessibilityLabel = iconAccessibilityLabel
            self.temperature = temperature
            self.condition = condition
            self.feelsLike = feelsLike
            self.highLow = highLow
            self.wind = wind
            self.conditionCode = conditionCode
            self.isDay = isDay
            self.windDial = windDial
            self.humidity = humidity
        }

        /// Bundled rich multi-color weather icon asset name.
        public var iconAssetName: String {
            WxConditionSymbol.assetName(conditionCode, isDay: isDay)
        }

        /// Parsed integer display temperature (in the current unit), nil when unknown ("—").
        public var temperatureValue: Int? {
            guard let degIdx = temperature.firstIndex(of: "\u{00B0}") else { return nil }
            return Int(temperature[..<degIdx])
        }
    }

    /// The now block's wind dial (Swift-only; the C app shows only the wind text).
    public struct NowWind: Sendable, Equatable {
        /// The speed as a whole number in the place's unit ("15"), rounded like WxFormat.wind; "—" when unknown.
        public let speedText: String
        /// "mph" or "km/h".
        public let unitText: String
        /// "25 mph" when the gust reaches the wind plus the producer's margin, else nil.
        public let gustText: String?
        /// The bearing the wind comes from in [0, 360); nil when unknown or calm.
        public let directionDeg: Double?
        /// "from NNE 31°"; nil when unknown or calm.
        public let directionText: String?
        /// A known speed below 1 km/h.
        public let isCalm: Bool
        /// The VoiceOver sentence, words only: "Wind 15 miles per hour from north-northeast, gusts 25 miles per hour".
        public let accessibilityLabel: String

        /// Spoken names of WxFormat.compassPoints, index for index.
        private static let spokenPoints = [
            "north", "north-northeast", "northeast", "east-northeast",
            "east", "east-southeast", "southeast", "south-southeast",
            "south", "south-southwest", "southwest", "west-southwest",
            "west", "west-northwest", "northwest", "north-northwest",
        ]

        /// Builds the dial value; the gust shows when it is finite and at least windKmh + gustMarginKmh
        /// (0 on the forecast path, 4 on the live-station path).
        public static func make(windKmh: Double, gustKmh: Double, directionDeg: Double?, units: WxUnits,
                                gustMarginKmh: Double) -> NowWind {
            let metric = units == .metric
            let unitText = metric ? "km/h" : "mph"
            let known = WxLimits.valueInRange(windKmh, 0.0, WxLimits.windMaxKmh)
            let isCalm = known && windKmh < 1.0
            // The number part of WxFormat.wind keeps its rounding and range rules.
            let speedText = known ? number(WxFormat.wind(windKmh, units: units)) : WxFormat.emDash
            let gustKnown = WxLimits.valueInRange(gustKmh, 0.0, WxLimits.windMaxKmh)
            let gustShown = gustKnown && gustKmh >= windKmh + gustMarginKmh
            let gustText = gustShown ? WxFormat.wind(gustKmh, units: units) : nil
            var direction: (deg: Double, point: String)?
            if !isCalm, let raw = directionDeg, let point = WxFormat.compassPoint(raw) {
                let d = raw.truncatingRemainder(dividingBy: 360.0)
                direction = (d < 0 ? d + 360.0 : d, point)
            }
            // Degrees rounded; 359.6 reads "0", not "360".
            let directionText = direction.map { "from \($0.point) \(Int($0.deg.rounded()) % 360)\u{00B0}" }
            let label: String
            if !known {
                label = "Wind speed unknown"
            } else if isCalm {
                label = "Wind calm"
            } else {
                var words = "Wind " + spoken(speedText, metric: metric)
                if let point = direction?.point, let i = WxFormat.compassPoints.firstIndex(of: point) {
                    words += " from " + spokenPoints[i]
                }
                if let gustText {
                    words += ", gusts " + spoken(number(gustText), metric: metric)
                }
                label = words
            }
            return NowWind(speedText: speedText, unitText: unitText, gustText: gustText, directionDeg: direction?.deg,
                           directionText: directionText, isCalm: isCalm, accessibilityLabel: label)
        }

        /// "15" from "15 mph".
        private static func number(_ formatted: String) -> String {
            String(formatted.prefix { $0 != " " })
        }

        /// "15 miles per hour" / "1 kilometer per hour".
        private static func spoken(_ number: String, metric: Bool) -> String {
            let unit = metric ? "kilometer" : "mile"
            return number + " " + unit + (number == "1" ? "" : "s") + " per hour"
        }
    }

    /// The "Rain" card (wx-detail.h:62-75).
    public struct RainCard: Sendable, Equatable {
        public static let title = "Rain"
        public static let nowcastCaption = "Next 2 hours"
        public static let hourlyCaption = "Next 24 hours"
        /// wx_rain_headline(), "Rain outlook unavailable" without an outlook.
        public let headline: String
        /// wx_rain_detail(); nil (hidden) when empty.
        public let detail: String?
        /// The 2-hour chart (view .nowcast): shown with its caption iff `showsNowcast`.
        public let nowcast: RainChartData
        /// The 24-hour chart (view .hourly): always shown.
        public let hourly: RainChartData
        /// The nowcast chart has data (the nowcast covers "now"); the two charts then share the width.
        public var showsNowcast: Bool { nowcast.hasData }

        public init(headline: String, detail: String?, nowcast: RainChartData, hourly: RainChartData) {
            self.headline = headline
            self.detail = detail
            self.nowcast = nowcast
            self.hourly = hourly
        }
    }

    /// The "Clouds" card (wx-detail.h:76-79).
    public struct CloudCard: Sendable, Equatable {
        public static let title = "Clouds"
        /// "Cloud cover 40% · Partly cloudy".
        public let cover: String
        /// wx_cloud_sentence().
        public let sentence: String

        public init(cover: String, sentence: String) {
            self.cover = cover
            self.sentence = sentence
        }

        /// Parsed integer cloud cover percentage (0...100), nil when unknown ("—").
        public var cloudPercent: Int? {
            guard let pctIdx = cover.firstIndex(of: "%") else { return nil }
            let prefix = cover[..<pctIdx]
            guard let spaceIdx = prefix.lastIndex(of: " ") else { return nil }
            return Int(prefix[prefix.index(after: spaceIdx)...])
        }
    }

    /// The "Air Quality" card: the US AQI of the nearest AirNow monitor as reported, else the CAMS
    /// model's forecast (WxAirQuality), compared with the same source 24 hours earlier. Never
    /// estimated from the weather: without a reading the card shows the dash.
    public struct AirQualityCard: Sendable, Equatable {
        public static let title = "Air Quality"
        /// The category of a card without a reading.
        public static let unavailableCategory = "No data"
        /// Numeric US AQI (0...500), nil without a reading.
        public let index: Int?
        /// Display string for the AQI value ("40" or "—").
        public let valueText: String
        /// Category label ("Good", "Moderate", etc.).
        public let category: String
        /// The comparison with yesterday, or why there is no value.
        public let summary: String
        /// Where and when the value was measured or forecast; nil without a reading.
        public let source: String?
        /// The hour the value is valid for, UTC unix seconds; nil without a reading.
        public let validS: Int64?
        /// The credit its source's terms ask for on the attribution line; nil without a reading.
        public let credit: WxStationNetworks.Credit?

        public init(index: Int?, valueText: String, category: String, summary: String,
                    source: String? = nil, validS: Int64? = nil, credit: WxStationNetworks.Credit? = nil) {
            self.index = index
            self.valueText = valueText
            self.category = category
            self.summary = summary
            self.source = source
            self.validS = validS
            self.credit = credit
        }

        /// The card without a reading: offline, before the first air-quality fetch or when no
        /// source answered.
        public nonisolated static func unavailable(offline: Bool) -> AirQualityCard {
            AirQualityCard(
                index: nil,
                valueText: WxFormat.emDash,
                category: unavailableCategory,
                summary: offline
                    ? "Air quality needs a network connection."
                    : "No air-quality reading for this place yet. It is checked again at every refresh."
            )
        }

        /// Category label for a US AQI value.
        public nonisolated static func categoryLabel(for aqi: Int) -> String {
            switch aqi {
            case ..<51: return "Good"
            case 51..<101: return "Moderate"
            case 101..<151: return "Unhealthy for Sensitive Groups"
            case 151..<201: return "Unhealthy"
            case 201..<301: return "Very Unhealthy"
            default: return "Hazardous"
            }
        }

        /// "Air quality index is 44, similar to yesterday at this time (37)." when the same source
        /// had a value 24 hours earlier (within 8 points: similar), else "Air quality index is 44,
        /// which is good."
        public nonisolated static func summarySentence(aqi: Int, dayAgoAQI: Int?) -> String {
            guard let dayAgoAQI else {
                return "Air quality index is \(aqi), which is \(categoryLabel(for: aqi).lowercased())."
            }
            let delta = aqi - dayAgoAQI
            let comparison = abs(delta) <= 8 ? "similar to" : delta < 0 ? "better than" : "worse than"
            return "Air quality index is \(aqi), \(comparison) yesterday at this time (\(dayAgoAQI))."
        }

        /// The category bounds of the US AQI (the lower bound of each of the six categories, then 501).
        nonisolated static let categoryBounds = [0, 51, 101, 151, 201, 301, 501]

        /// Where `aqi` sits on the card's scale, 0...1: the six categories take equal widths (as
        /// the scale's six colour bands do), and a value sits inside its own category's band.
        public nonisolated static func scalePosition(_ aqi: Int) -> Double {
            let v = max(0, min(500, aqi))
            let band = (categoryBounds.lastIndex { $0 <= v } ?? 0)
            let lo = Double(categoryBounds[band])
            let hi = Double(categoryBounds[band + 1])
            return (Double(band) + (Double(v) - lo + 0.5) / (hi - lo)) / 6.0
        }
    }

    /// One entry of the attribution line: the text, a link only for a linkable URL.
    public struct AttributionEntry: Sendable, Equatable {
        public let text: String
        /// The link target (url_is_linkable), nil for plain text.
        public let url: String?
    }

    /// The sections of the forecast page, in the order they are shown (wx-detail.c:939-1069).
    public enum Section: Sendable, Equatable, CaseIterable {
        case header, now, rain, clouds, hours, days, footer, attribution, partial
    }

    /// The forecast page (wx-detail.h:38-96).
    public struct ForecastPage: Sendable, Equatable {
        public static let sections = Section.allCases
        public static let hoursTitle = "Next 48 hours"
        public static let daysTitle = "Next days"
        public static let offlineBadgeText = "Offline"
        public static let staleBadgeText = "Stale"
        public static let offlineBadgeTooltip = "No network connection: showing the last forecast"
        /// The refresh spinner's accessible label.
        public static let refreshingAccessibilityLabel = "Refreshing"

        /// "wx-detail-place": the place label.
        public let place: String
        /// The Offline badge is visible (the item is offline).
        public let showsOfflineBadge: Bool
        /// The Stale badge is visible (stale and NOT offline).
        public let showsStaleBadge: Bool
        /// "The last refresh failed: <error>" / "The last refresh failed".
        public let staleBadgeTooltip: String
        public let now: Now
        public let rain: RainCard
        public let clouds: CloudCard
        public let airQuality: AirQualityCard
        /// The 48-hour strip.
        public let hours: [HourCard]
        /// The day list.
        public let days: [DayRow]
        /// "Updated 5 min ago · Sources: A, B" (one label).
        public let footer: String
        /// "wx-detail-refreshing": visible and spinning iff the item is loading.
        public let showsRefreshing: Bool
        /// The attribution entries (empty: the line is hidden).
        public let attribution: [AttributionEntry]
        /// The Pango markup of the attribution label (wx-detail.c:224-247), "" when hidden.
        public let attributionMarkup: String
        /// The attribution text as displayed: the entries joined with " · ".
        public var attributionText: String { attribution.map(\.text).joined(separator: " \u{00B7} ") }
        /// "Not available right now: X, Y"; nil (hidden) when no source failed.
        public let partial: String?

        public init(
            place: String,
            showsOfflineBadge: Bool,
            showsStaleBadge: Bool,
            staleBadgeTooltip: String,
            now: Now,
            rain: RainCard,
            clouds: CloudCard,
            airQuality: AirQualityCard,
            hours: [HourCard],
            days: [DayRow],
            footer: String,
            showsRefreshing: Bool,
            attribution: [AttributionEntry],
            attributionMarkup: String,
            partial: String?
        ) {
            self.place = place
            self.showsOfflineBadge = showsOfflineBadge
            self.showsStaleBadge = showsStaleBadge
            self.staleBadgeTooltip = staleBadgeTooltip
            self.now = now
            self.rain = rain
            self.clouds = clouds
            self.airQuality = airQuality
            self.hours = hours
            self.days = days
            self.footer = footer
            self.showsRefreshing = showsRefreshing
            self.attribution = attribution
            self.attributionMarkup = attributionMarkup
            self.partial = partial
        }
    }

    /// The page shown.
    public enum Page: Sendable, Equatable {
        case placeholder(Placeholder)
        case forecast(ForecastPage)
    }

    /// The page shown (compare before set: only assigned when it changes).
    public private(set) var page: Page
    /// Incremented each time `page` changes.
    public private(set) var revision: UInt64 = 0
    /// The alerts section of the shown item (only assigned when it changes); nil without an item.
    public private(set) var alerts: AlertsSection?

    @ObservationIgnored private var placeZone = WxFormat.HeldZone()
    @ObservationIgnored private var forecastZone = WxFormat.HeldZone()

    /// wx_detail_new: no item, "Select a place".
    public init() {
        page = Self.makePage(nil, placeZone: .utc, forecastZone: .utc)
    }

    /// wx_detail_set_item + refresh: shows `item` (nil for none). Call it again whenever the
    /// item changes (the "changed" signal); an unchanged item changes nothing.
    public func show(_ item: Item?) {
        placeZone.update(item?.place.timezone ?? "")
        forecastZone.update(item?.forecast?.place.timezone ?? "")
        let next = Self.makePage(item, placeZone: placeZone.zone, forecastZone: forecastZone.zone)
        if next != page {
            page = next
            revision &+= 1
        }
        let nextAlerts = item.map { AlertsSection.section($0.alerts, nowS: $0.nowS, zone: placeZone.zone) }
        if nextAlerts != alerts {
            alerts = nextAlerts
        }
    }

    /// Shows a place of the application model (`show(place: model.selectedPlace)`), nil for none.
    public func show(place: AppModel.Place?) {
        show(place.map(Item.init))
    }

    /// The page of `item` (refresh, wx-detail.c:614-641), with the two held zones.
    nonisolated static func makePage(_ item: Item?, placeZone: WxFormat.Zone, forecastZone: WxFormat.Zone) -> Page {
        guard let item else {
            return .placeholder(Placeholder(title: "Select a place",
                                            text: "Pick a place on the left, or add one with the + button.",
                                            showsSpinner: false))
        }
        guard let forecast = item.forecast else {
            return .placeholder(placeholder(item))
        }
        let current = WxBlend.now(forecast, nowS: item.nowS)
        let outlook = outlook(forecast, nowS: item.nowS, hasCurrent: current != nil)
        let ok = joinSources(forecast.sources, .ok)
        let failed = joinSources(forecast.sources, .failed)
        let attribution = attributionEntries(forecast.sources.map {
            SourceText(state: $0.state, attribution: Array($0.attribution.utf8), url: Array($0.attributionURL.utf8))
        })
        let stale = item.errorText.map { "The last refresh failed: " + $0 } ?? "The last refresh failed"
        return .forecast(ForecastPage(
            place: item.place.label, showsOfflineBadge: item.offline, showsStaleBadge: !item.offline && item.stale,
            staleBadgeTooltip: stale,
            now: now(item, forecast: forecast, current: current, zone: placeZone),
            rain: rainCard(item, forecast: forecast, outlook: outlook, placeZone: placeZone,
                           forecastZone: forecastZone),
            clouds: cloudCard(item, forecast: forecast, current: current, zone: placeZone),
            airQuality: .unavailable(offline: item.offline),
            hours: HourCard.cards(forecast: forecast, units: item.units, nowS: item.nowS, zone: forecastZone),
            days: DayRow.rows(forecast: forecast, units: item.units, nowS: item.nowS, zone: forecastZone),
            footer: WxFormat.updated(ageS: ageS(item.nowS, item.fetchedS)) + separator + "Sources: "
                + (ok.isEmpty ? "none" : ok),
            showsRefreshing: item.loading, attribution: attribution.map(\.entry),
            attributionMarkup: attribution.map(\.markup).joined(separator: separator),
            partial: failed.isEmpty ? nil : "Not available right now: " + failed))
    }

    // MARK: - Texts (internal for the tests)

    /// One source's display data as the C pane reads it (raw bytes: a hand-built forecast).
    struct SourceText {
        var state: WxSourceState
        var attribution: [UInt8]
        var url: [UInt8]
    }

    /// SEPARATOR (wx-detail.c:22): " · ".
    nonisolated static let separator = " \u{00B7} "
    /// RETRY_HINT (wx-detail.c:24).
    nonisolated static let retryHint = "Check your internet connection; the app tries again automatically."

    /// age_s (wx-detail.c:99-107): 0 when `fetchedS` is not before `nowS`, Int64.max when the
    /// difference does not fit, else nowS - fetchedS.
    nonisolated static func ageS(_ nowS: Int64, _ fetchedS: Int64) -> Int64 {
        if fetchedS >= nowS {
            return 0
        }
        if fetchedS < 0 && nowS > Int64.max + fetchedS {
            return Int64.max
        }
        return nowS - fetchedS
    }

    /// error_sentence (wx-detail.c:295-302).
    nonisolated static func errorSentence(_ error: String?) -> String {
        let text = error ?? ""
        let glue: String
        if let last = text.utf8.last {
            glue = last == UInt8(ascii: ".") || last == UInt8(ascii: "!") || last == UInt8(ascii: "?") ? " " : ". "
        } else {
            glue = ""
        }
        return text + glue + retryHint
    }

    /// url_is_linkable (wx-detail.c:128-144) over the bytes of a C string (read up to the first
    /// 0x00): "https://" plus at least one byte, at most WxLimits.sourceURLMax bytes, valid
    /// UTF-8, no byte <= 0x20, no 0x7f and none of '<', '>', '"'.
    nonisolated static func isLinkable(urlBytes raw: [UInt8]) -> Bool {
        let prefix = Array("https://".utf8)
        let url = Array(raw.prefix { $0 != 0 })
        guard url.starts(with: prefix), url.count > prefix.count, url.count <= WxLimits.sourceURLMax else {
            return false
        }
        for c in url where c <= 0x20 || c == 0x7f || c == UInt8(ascii: "<") || c == UInt8(ascii: ">")
            || c == UInt8(ascii: "\"") {
            return false
        }
        return String(validating: url, as: UTF8.self) != nil
    }

    /// g_markup_escape_text: & < > ' " as entities; U+0001-U+0008, U+000B-U+000C, U+000E-U+001F,
    /// U+007F-U+0084 and U+0086-U+009F as "&#x..;".
    nonisolated static func markupEscape(_ text: String) -> String {
        var out = ""
        for s in text.unicodeScalars {
            switch s {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            default:
                let c = s.value
                if (0x1...0x8).contains(c) || (0xB...0xC).contains(c) || (0xE...0x1F).contains(c)
                    || (0x7F...0x84).contains(c) || (0x86...0x9F).contains(c) {
                    out += "&#x" + String(c, radix: 16) + ";"
                } else {
                    out.unicodeScalars.append(s)
                }
            }
        }
        return out
    }

    /// build_attribution (wx-detail.c:224-247): per OK source with a non-empty (sanitised)
    /// attribution text, its entry and its markup (an escaped link when isLinkable).
    nonisolated static func attributionEntries(_ sources: [SourceText]) -> [(entry: AttributionEntry, markup: String)] {
        var out: [(entry: AttributionEntry, markup: String)] = []
        for s in sources where s.state == .ok {
            let text = WxText.sanitize(bytes: s.attribution, maxBytes: WxLimits.sourceTextMax)
            if text.isEmpty {
                continue
            }
            let escaped = markupEscape(text)
            if isLinkable(urlBytes: s.url) {
                let url = String(decoding: s.url.prefix { $0 != 0 }, as: UTF8.self)
                out.append((AttributionEntry(text: text, url: url), "<a href=\"\(markupEscape(url))\">\(escaped)</a>"))
            } else {
                out.append((AttributionEntry(text: text, url: nil), escaped))
            }
        }
        return out
    }

    /// join_sources (wx-detail.c:185-204): the sanitised names of the sources in `state`, in
    /// forecast order, ", "-separated; a name empty after sanitising is replaced by the provider id.
    nonisolated static func joinSources(_ sources: [WxSourceStatus], _ state: WxSourceState) -> String {
        var names: [String] = []
        for s in sources where s.state == state {
            var name = WxText.sanitize(s.name, maxBytes: WxLimits.sourceTextMax)
            if name.isEmpty {
                name = WxText.sanitize(s.providerID, maxBytes: WxLimits.sourceTextMax)
            }
            names.append(name)
        }
        return names.joined(separator: ", ")
    }

    /// find_today (wx-detail.c:266-276): the first day with startS <= nowS < its local day end.
    nonisolated static func today(_ forecast: WxForecast, nowS: Int64, zone: WxFormat.Zone) -> WxDay? {
        forecast.days.first { $0.startS <= nowS && nowS < WxFormat.localDayEnd($0.startS, zone: zone) }
    }

    /// item_recompute / covers_dry_claim (wx-row.c:230-282): the outlook only when an hour
    /// contains "now", "now" is in the valid time range, and a DRY outlook only when the
    /// amounts of the next 48 hours are all known.
    nonisolated static func outlook(_ forecast: WxForecast, nowS: Int64, hasCurrent: Bool) -> WxRainOutlook? {
        guard hasCurrent, nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
            return nil
        }
        let o = WxRainRules.outlook(forecast, nowS: nowS)
        if o.state != .dry {
            return o
        }
        var untilS: Int64 = 0
        for h in forecast.hours {
            if untilS == 0 {
                if !(h.tS <= nowS && nowS &- h.tS < 3600) {
                    continue
                }
                untilS = h.tS
            }
            if h.tS != untilS || !h.precipMm.isFinite {
                break
            }
            untilS &+= 3600
        }
        return untilS != 0 && untilS &- nowS >= WxRainRules.horizonS ? o : nil
    }

    // MARK: - Private

    /// refresh_placeholder (wx-detail.c:344-375) for an item without forecast.
    private nonisolated static func placeholder(_ item: Item) -> Placeholder {
        if item.loading {
            return Placeholder(title: "Loading forecast\u{2026}", text: "This takes a few seconds.", showsSpinner: true)
        }
        if let error = item.errorText {
            return Placeholder(title: "Couldn't load the forecast", text: errorSentence(error), showsSpinner: false)
        }
        if item.offline {
            return Placeholder(title: "You are offline", text: "The forecast loads when the network is back.",
                               showsSpinner: false)
        }
        return Placeholder(title: "No forecast yet", text: "", showsSpinner: false)
    }

    /// refresh_now (wx-detail.c:451-500).
    private nonisolated static func now(_ item: Item, forecast: WxForecast, current cur: WxBlendHour?,
                                        zone: WxFormat.Zone) -> Now {
        let units = item.units
        let condition = cur?.condition ?? .unknown
        let label = WxConditionRules.label(condition)
        let entry = WxConditionSymbol.entry(condition, isDay: cur?.isDay ?? true)
        let highLow = today(forecast, nowS: item.nowS, zone: zone).map {
            WxFormat.highLowLabel(day: $0, forecast: forecast, nowS: item.nowS, timezone: item.place.timezone,
                                  units: units)
        }
        let windKmh = cur?.windKmh ?? .nan
        let gustKmh = cur?.gustKmh ?? .nan
        let gust = gustKmh.isFinite && gustKmh >= windKmh ? ", gusts " + WxFormat.wind(gustKmh, units: units) : ""
        let wind = "Wind " + WxFormat.wind(windKmh, units: units) + gust
        let windDial = NowWind.make(windKmh: windKmh, gustKmh: gustKmh, directionDeg: nil, units: units,
                                    gustMarginKmh: 0)
        let humidity = "Humidity " + WxFormat.percent(cur?.humidityPct ?? .nan)
        let effectiveCond = cur.map(WxConditionSymbol.effectiveHourlyCondition(for:)) ?? condition
        // The icon is drawn from effectiveCond (iconAssetName), so its accessible label names
        // that condition; the visible condition text stays the C label.
        return Now(symbolName: entry.symbolName, gtkIconName: entry.gtkIconName,
                   iconAccessibilityLabel: WxConditionRules.label(effectiveCond),
                   temperature: WxFormat.temp(cur?.tempC ?? .nan, units: units, withUnit: true), condition: label,
                   feelsLike: "Feels like " + WxFormat.temp(cur?.feelsC ?? .nan, units: units, withUnit: false),
                   highLow: highLow, wind: wind, conditionCode: effectiveCond, isDay: cur?.isDay ?? true,
                   windDial: windDial, humidity: humidity)
    }

    /// refresh_cards, rain part (wx-detail.c:517-536).
    private nonisolated static func rainCard(_ item: Item, forecast: WxForecast, outlook: WxRainOutlook?,
                                             placeZone: WxFormat.Zone, forecastZone: WxFormat.Zone) -> RainCard {
        let headline = outlook.map { WxFormat.rainHeadline($0, nowS: item.nowS, zone: placeZone) }
            ?? "Rain outlook unavailable"
        let detail = outlook.map { WxFormat.rainDetail($0, nowS: item.nowS, zone: placeZone) }
        return RainCard(
            headline: headline, detail: detail?.isEmpty == false ? detail : nil,
            nowcast: RainChartData(forecast: forecast, units: item.units, nowS: item.nowS, view: .nowcast,
                                   zone: forecastZone),
            hourly: RainChartData(forecast: forecast, units: item.units, nowS: item.nowS, view: .hourly,
                                  zone: forecastZone))
    }

    /// refresh_cards, cloud part (wx-detail.c:538-546).
    private nonisolated static func cloudCard(_ item: Item, forecast: WxForecast, current: WxBlendHour?,
                                              zone: WxFormat.Zone) -> CloudCard {
        let cloud = current?.cloudPct ?? .nan
        return CloudCard(cover: "Cloud cover " + WxFormat.percent(cloud) + separator
                            + WxConditionRules.cloudLabel(cloud),
                         sentence: WxFormat.cloudSentence(forecast, nowS: item.nowS, zone: zone))
    }
}

extension DetailViewModel.ForecastPage {
    /// The page with `credits` appended to its attribution line (entries and markup built as the
    /// sources' are); a credit whose text is already on the line is not repeated.
    public func addingAttribution(_ credits: [WxStationNetworks.Credit]) -> Self {
        var shown = Set(attribution.map(\.text))
        var fresh: [DetailViewModel.SourceText] = []
        for c in credits where shown.insert(c.text).inserted {
            fresh.append(.init(state: .ok, attribution: Array(c.text.utf8), url: Array(c.url.utf8)))
        }
        let added = DetailViewModel.attributionEntries(fresh)
        guard !added.isEmpty else { return self }
        let markup = ([attributionMarkup].filter { !$0.isEmpty } + added.map(\.markup))
            .joined(separator: DetailViewModel.separator)
        return Self(
            place: place, showsOfflineBadge: showsOfflineBadge, showsStaleBadge: showsStaleBadge,
            staleBadgeTooltip: staleBadgeTooltip, now: now, rain: rain, clouds: clouds, airQuality: airQuality,
            hours: hours, days: days, footer: footer, showsRefreshing: showsRefreshing,
            attribution: attribution + added.map(\.entry), attributionMarkup: markup, partial: partial)
    }
}
