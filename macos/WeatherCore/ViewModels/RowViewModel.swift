// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RowViewModel.swift - the presentation of one row of the place list: a port of
// the display logic of src/ui/wx-row.{h,c} (WxRow's refresh(), region_text(),
// hint_text(), marker_text(), wx_row_rain_hint() and the values WxRowItem
// derives from its forecast and "now": item_recompute() / covers_dry_claim()).
//
// The view model is a plain value computed from an AppModel item
// (AppModel.Place, the WxRowItem state). It never reads a clock: every
// time-dependent text comes from the item's "now" (wx-row.h:19-23), so a row
// and the detail pane that show the same item agree. Texts, their order and
// the conditions under which they appear are the GTK row's, verbatim:
//  - name; region "Admin1, Country" (whichever part exists), hidden when empty;
//  - temperature without unit letter ("77°"), an em dash without current conditions,
//    in the place's own units (the item's units), and beside it the unit label
//    of those units, "°F" or "°C" (per-place units, not in the GTK row); the
//    row shows the unit suffix, so that it reads "77°F" / "— °F" like the
//    accessible label;
//  - one-line hint: the rain hint when the item has an outlook, else the first of
//    "No rain data" (forecast present), "Loading…", "Can't load forecast",
//    "Offline", "No data yet";
//  - marker (needs a forecast): "Offline", then "Stale", then "Updating…";
//  - dim while a forecast is shown and offline or stale; empty without forecast;
//  - the alert indicator (not in the GTK row): the highest normalized level of
//    the place's current alerts and, above one, their number; none without a
//    current alert. Current alerts are those of a `.current` result
//    (WxAlertsResult, AppModel.Place.alerts) that have not expired or ended at
//    the item's "now" - a stale set, an unavailable or uncovered place and one
//    not fetched yet show no indicator (a set older than its source's window is
//    never shown as current);
//  - tooltip: the full place label; accessible label
//    "<label>: <temp>, <hint>[, <marker>][, <alerts>]" whose temperature carries
//    its unit ("77°F"; "— °F" without current conditions) and whose alerts part
//    names the current alerts ("Alert: Tornado Warning (red)", "2 alerts: ..."):
//    the row is one accessibility element that ignores its children, so the
//    unit and the alerts are spoken only here.
//
// The row actions ("Move up", "Move down", "Remove" and a drop of text on the
// row) are entry points that hand the row's key to AppModel; the row never edits
// the places itself and never interprets a dropped text (wx-row.h:34-38).

/// The presentation of one place-list row (WxRow over a WxRowItem, src/ui/wx-row.h).
public struct RowViewModel: Sendable, Identifiable {
    // MARK: - Constants

    /// A rain that starts less than this many minutes ahead is announced as
    /// "Rain in N min" (HINT_SOON_MINUTES, wx-row.c:16).
    public static let hintSoonMinutes: Int64 = 90

    /// Text of the row's menu button (gtk_label_new("…"), wx-row.c:1144).
    public static let menuButtonText = "\u{2026}"
    /// Tooltip and accessible label of the row's menu button (wx-row.c:1150-1152).
    public static let menuButtonLabel = "Place actions"
    /// Accessible label of the place list (wx-window.c:940-941).
    public static let listAccessibilityLabel = "Saved places"
    /// Tooltip of the "Offline" badge (make_badge, wx-detail.c:1067-1068).
    public static let offlineTooltip = "No network connection: showing the last forecast"

    /// Tooltip of the "Stale" badge (wx-detail.c:404-405): "The last refresh failed: <error>",
    /// or "The last refresh failed" without error text (nil or empty).
    public static func staleTooltip(errorText: String?) -> String {
        if let errorText, !errorText.isEmpty {
            return "The last refresh failed: " + errorText
        }
        return "The last refresh failed"
    }

    // MARK: - Public types

    /// The marker pill of a row that shows a forecast (marker_text, wx-row.c:645-657).
    public enum Marker: String, Sendable, CaseIterable {
        /// The network is unavailable.
        case offline = "Offline"
        /// The latest refresh of the place failed.
        case stale = "Stale"
        /// A refresh of the place is in flight.
        case updating = "Updating\u{2026}"

        /// The text shown in the pill.
        public var text: String { rawValue }
    }

    /// The alert indicator of a row whose place has current alerts (not in the GTK row): a warning
    /// symbol coloured by the highest level, with the number of alerts when there is more than one.
    public struct AlertIndicator: Sendable, Equatable {
        /// SF Symbol of the indicator.
        public static let symbolName = "exclamationmark.triangle.fill"
        /// The highest normalized level of the current alerts (the indicator's colour).
        public let level: WxAlert.Level
        /// The number of current alerts, at least 1.
        public let count: Int
        /// The number shown beside the symbol: "3" for more than one alert, nil for one.
        public var countText: String? { count > 1 ? String(count) : nil }
    }

    /// The items of the row's menu (row_menu, wx-row.c:866-874), always enabled.
    public enum Action: Sendable, CaseIterable {
        case moveUp
        case moveDown
        case remove

        /// The menu label.
        public var title: String {
            switch self {
            case .moveUp: "Move up"
            case .moveDown: "Move down"
            case .remove: "Remove"
            }
        }
    }

    /// The menu items in their order: "Move up", "Move down", "Remove".
    public static let menuActions: [Action] = [.moveUp, .moveDown, .remove]

    // MARK: - Displayed values

    /// The place key (wx_row_item_get_key): the identity of the row and the payload of a drag.
    public let key: String
    public var id: String { key }
    /// The place shown.
    public let place: WxPlace
    /// The conditions at the item's "now" (wx_row_item_get_current), nil when there is no forecast
    /// or no hour of it contains "now".
    public let current: WxBlendHour?
    /// The rain outlook at the item's "now" (wx_row_item_get_outlook), nil when the item makes no
    /// rain claim (see `derive(forecast:nowS:)`). The detail pane shows "Rain outlook unavailable"
    /// for nil.
    public let outlook: WxRainOutlook?
    /// The item holds a forecast.
    public let hasForecast: Bool

    /// The place name (label "wx-row-name").
    public let name: String
    /// "Florida, United States" or whichever part exists, "" for neither (label "wx-row-region").
    public let region: String
    /// The temperature without unit letter, an em dash without current conditions ("wx-row-temp"),
    /// in `units`.
    public let temperature: String
    /// The unit system of the row's temperature: the place's units (AppModel.Place.units).
    public let units: WxUnits
    /// The unit label of `units`: "°F" or "°C" (`unitLabel(_:)` of `units`).
    public var unitLabel: String { Self.unitLabel(units) }
    /// What the row shows right after `temperature`, so that it reads as the accessible label
    /// does: the unit letter "F" / "C" after a temperature that ends with the degree sign ("77°"
    /// "F": "77°F"), the unit label "°F" / "°C" after the em dash ("—" "°F": "— °F").
    public var unitSuffix: String {
        temperature.hasSuffix("\u{00B0}") ? (units == .metric ? "C" : "F") : unitLabel
    }
    /// The one-line hint ("wx-row-hint").
    public let hint: String
    /// The marker pill, nil while none is shown ("wx-row-marker").
    public let marker: Marker?
    /// The place's current alerts at the item's "now" (`currentAlerts(_:nowS:)`), highest level
    /// first; empty unless the place's alerts result is `.current`.
    public let alerts: [WxAlert]
    /// SF Symbol of the condition at "now" (questionmark.circle without current conditions).
    public let symbolName: String
    /// The GTK icon name of the same condition (wx_icon_name; dialog-question-symbolic fallback).
    public let gtkIconName: String

    /// The bundled rich weather icon asset name for the row's current condition.
    public var iconAssetName: String {
        let cond = current.map(WxConditionSymbol.effectiveHourlyCondition(for:)) ?? .unknown
        return WxConditionSymbol.assetName(cond, isDay: current?.isDay ?? true)
    }

    /// The region line is shown (it is hidden when empty, wx-row.c:710).
    public var isRegionVisible: Bool { !region.isEmpty }
    /// The marker text, "" while none is shown.
    public var markerText: String { marker?.text ?? "" }
    /// The marker pill is shown (wx-row.c:714).
    public var isMarkerVisible: Bool { marker != nil }
    /// The alert indicator: the highest level of `alerts` and their number; nil without a current
    /// alert.
    public var alertIndicator: AlertIndicator? {
        alerts.map(\.level).max().map { AlertIndicator(level: $0, count: alerts.count) }
    }
    /// CSS class "dim": a forecast is shown and the place is offline or stale (wx-row.c:718-720).
    public let isDim: Bool
    /// CSS class "empty": the item has no forecast (wx-row.c:721).
    public let isEmpty: Bool
    /// The row's tooltip: the full place label (wx-row.c:726).
    public var tooltip: String { place.label }
    /// The row's accessible label "<label>: <temp>, <hint>[, <marker>][, <alerts>]" (wx-row.c:723-727),
    /// the temperature with its units: "77°F" (WxFormat.temp's text with the unit letter), or the em
    /// dash and the unit label ("— °C") without current conditions; then the current alerts
    /// (`alertsSpoken(_:)`).
    public var accessibilityLabel: String {
        let marker = markerText
        let temp = temperature.hasSuffix("\u{00B0}")
            ? temperature + (units == .metric ? "C" : "F")
            : temperature + " " + unitLabel
        let spoken = Self.alertsSpoken(alerts)
        return "\(place.label): \(temp), \(hint)\(marker.isEmpty ? "" : ", ")\(marker)"
            + (spoken.isEmpty ? "" : ", " + spoken)
    }
    /// The drag payload of the row: its place key as text (on_drag_prepare, wx-row.c:922-932).
    public var dragPayload: String { key }

    // MARK: - Construction

    /// The row of an AppModel item (wx_row_bind + refresh).
    public init(_ item: AppModel.Place) {
        self.init(key: item.key, place: item.place, forecast: item.forecast, loading: item.loading,
                  stale: item.stale, offline: item.offline, units: item.units, nowS: item.nowS,
                  errorText: item.errorText, alerts: item.alerts)
    }

    /// The row of the given item state (refresh, wx-row.c:677-728).
    /// - Parameters:
    ///   - key: the place key (wx_place_key); `place.key` when nil.
    ///   - place: the place shown.
    ///   - forecast: the forecast held, nil for none.
    ///   - loading: a refresh of the place is in flight.
    ///   - stale: the latest refresh of the place failed.
    ///   - offline: the network is unavailable.
    ///   - units: the unit system of the temperature and of the unit label (the place's units).
    ///   - nowS: the item's "now", UTC unix seconds (any value).
    ///   - errorText: the sanitised reason of the latest failed refresh, nil (or "") for none.
    ///   - alerts: the place's alerts as the alerts service reports them (AppModel.Place.alerts).
    public init(key: String? = nil, place: WxPlace, forecast: WxForecast?, loading: Bool = false,
                stale: Bool = false, offline: Bool = false, units: WxUnits = .imperial, nowS: Int64,
                errorText: String? = nil, alerts: WxAlertsResult = AppModel.alertsNotFetched) {
        let derived = Self.derive(forecast: forecast, nowS: nowS)
        self.key = key ?? place.key
        self.place = place
        self.current = derived.current
        self.outlook = derived.outlook
        self.hasForecast = forecast != nil
        self.name = place.name
        self.region = Self.regionText(place)
        self.temperature = WxFormat.temp(derived.current?.tempC ?? .nan, units: units, withUnit: false)
        self.units = units
        // hint_text (wx-row.c:612-625): the first matching rule wins.
        if let outlook = derived.outlook {
            self.hint = Self.rainHint(outlook, nowS: nowS, timezone: place.timezone)
        } else if forecast != nil {
            self.hint = "No rain data"
        } else if loading {
            self.hint = "Loading\u{2026}"
        } else if let errorText, !errorText.isEmpty {
            self.hint = "Can't load forecast"
        } else if offline {
            self.hint = "Offline"
        } else {
            self.hint = "No data yet"
        }
        // marker_text (wx-row.c:646-656): only with data; offline, then stale, then loading.
        if forecast == nil {
            self.marker = nil
        } else if offline {
            self.marker = .offline
        } else if stale {
            self.marker = .stale
        } else if loading {
            self.marker = .updating
        } else {
            self.marker = nil
        }
        let icon = WxConditionSymbol.entry(derived.current?.condition ?? .unknown,
                                           isDay: derived.current?.isDay ?? true)
        self.symbolName = icon.symbolName
        self.gtkIconName = icon.gtkIconName
        self.isDim = forecast != nil && (offline || stale)
        self.isEmpty = forecast == nil
        self.alerts = Self.currentAlerts(alerts, nowS: nowS)
    }

    private init(
        key: String, place: WxPlace, current: WxBlendHour?, outlook: WxRainOutlook?,
        hasForecast: Bool, name: String, region: String, temperature: String, units: WxUnits, hint: String,
        marker: Marker?, alerts: [WxAlert], symbolName: String, gtkIconName: String, isDim: Bool, isEmpty: Bool
    ) {
        self.key = key
        self.place = place
        self.current = current
        self.outlook = outlook
        self.hasForecast = hasForecast
        self.name = name
        self.region = region
        self.temperature = temperature
        self.units = units
        self.hint = hint
        self.marker = marker
        self.alerts = alerts
        self.symbolName = symbolName
        self.gtkIconName = gtkIconName
        self.isDim = isDim
        self.isEmpty = isEmpty
    }

    /// Returns a copy of this row with live station conditions applied to its current display; its
    /// temperature and unit label are in `units` (the caller passes the place's units).
    public func withLiveCurrent(_ liveCurrent: WxBlendHour, liveHint: String? = nil, units: WxUnits) -> RowViewModel {
        let effectiveCond = WxConditionSymbol.effectiveHourlyCondition(for: liveCurrent)
        let icon = WxConditionSymbol.entry(effectiveCond, isDay: liveCurrent.isDay)
        return RowViewModel(
            key: key,
            place: place,
            current: liveCurrent,
            outlook: outlook,
            hasForecast: hasForecast,
            name: name,
            region: region,
            temperature: WxFormat.temp(liveCurrent.tempC, units: units, withUnit: false),
            units: units,
            hint: liveHint ?? hint,
            marker: marker,
            alerts: alerts,
            symbolName: icon.symbolName,
            gtkIconName: icon.gtkIconName,
            isDim: isDim,
            isEmpty: isEmpty
        )
    }

    /// The rows of the model's items, in the list's order.
    @MainActor
    public static func rows(of model: AppModel) -> [RowViewModel] {
        model.places.map(RowViewModel.init)
    }

    /// The unit label of `units`: "°F" (imperial) or "°C" (metric).
    public static func unitLabel(_ units: WxUnits) -> String {
        units == .metric ? "\u{00B0}C" : "\u{00B0}F"
    }

    // MARK: - Alerts

    /// The alerts of `result` that are current at `nowS`: those of a `.current` result that have
    /// neither expired nor ended at `nowS` (WxAlert.isCurrent: one expiring at `nowS` is gone), in
    /// the result's order (highest level first). Empty for every other state: a stale set (older
    /// than its source's window) is never current, whatever it holds. The service already left
    /// out what had expired when it was read; this filter is on top of that one, at the item's
    /// "now", so that the row and the detail pane of the same item agree.
    public static func currentAlerts(_ result: WxAlertsResult, nowS: Int64) -> [WxAlert] {
        guard result.state == .current else {
            return []
        }
        return result.alerts.filter { $0.isCurrent(atS: nowS) }
    }

    /// The name of a normalized alert level: "Red", "Orange", "Yellow", "Minor", "Unknown" (the
    /// issuer gave none).
    public static func alertLevelTitle(_ level: WxAlert.Level) -> String {
        switch level {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .minor: "Minor"
        case .unknown: "Unknown"
        }
    }

    /// The alerts part of the accessible label: "" without alerts, "Alert: Tornado Warning (red)"
    /// for one, "2 alerts: Tornado Warning (red), Flood Watch (yellow)" for several, in their
    /// order; an unknown level is not spoken, and an alert without an event name is named by its
    /// headline.
    static func alertsSpoken(_ alerts: [WxAlert]) -> String {
        guard !alerts.isEmpty else {
            return ""
        }
        let names = alerts.map { a in
            let name = a.event.isEmpty ? a.headline : a.event
            return a.level == .unknown ? name : name + " (" + alertLevelTitle(a.level).lowercased() + ")"
        }
        return (alerts.count == 1 ? "Alert: " : "\(alerts.count) alerts: ") + names.joined(separator: ", ")
    }

    // MARK: - Actions (they only carry keys; AppModel validates and acts)

    /// The menu item `action` (on_remove / on_move_up / on_move_down, wx-row.c:795-847, handled
    /// by the window's on_row_remove / on_row_move, wx-window.c:750-786). A move past either end
    /// and an action of a place that is no longer saved change nothing.
    /// - Returns: whether AppModel changed the places.
    @MainActor
    @discardableResult
    public func perform(_ action: Action, in model: AppModel) -> Bool {
        switch action {
        case .moveUp: moveUp(in: model)
        case .moveDown: moveDown(in: model)
        case .remove: remove(in: model)
        }
    }

    /// "Move up": asks AppModel to move this row's place one position up.
    @MainActor
    @discardableResult
    public func moveUp(in model: AppModel) -> Bool {
        model.moveUp(key: key)
    }

    /// "Move down": asks AppModel to move this row's place one position down.
    @MainActor
    @discardableResult
    public func moveDown(in model: AppModel) -> Bool {
        model.moveDown(key: key)
    }

    /// "Remove": asks AppModel to remove this row's place at once (no confirmation, no undo).
    @MainActor
    @discardableResult
    public func remove(in model: AppModel) -> Bool {
        model.remove(key: key)
    }

    /// A drop of `text` on this row (on_drop, wx-row.c:981-998): any text is handed to AppModel,
    /// UNTRUSTED and uninterpreted, as a request to move the place with that key to this row's
    /// position; AppModel ignores anything that is not a saved key (wx-window.c:809-817).
    /// - Returns: whether the drop was accepted (true for any text, false for nil), as GTK's
    ///   drop handler; whether the places changed is AppModel's business.
    @MainActor
    @discardableResult
    public func acceptDrop(_ text: String?, in model: AppModel) -> Bool {
        guard let text else {
            return false
        }
        model.moveKey(text, onto: key)
        return true
    }

    // MARK: - The rain hint

    /// wx_row_rain_hint (wx-row.c:74-110, wx-row.h:59-89): the one-line hint of a row.
    ///  - now: "Raining until 3:30 PM" when the end is known, valid and after `nowS`, else
    ///    "Raining now";
    ///  - expected: "Rain in 25 min" (rounded up) when the start is less than 90 minutes ahead,
    ///    "Rain starting now" when it is not after `nowS`, else "Rain at 4 PM",
    ///    "Rain tomorrow, 4 PM" or "Rain Friday, 4 PM"; "Rain expected" for an invalid start;
    ///  - possible: "Showers possible"; dry: "Dry for 48 h".
    /// Except for dry, a `nowS` outside [timeMinS, timeMaxS) gives "". Never overflows.
    public static func rainHint(_ outlook: WxRainOutlook, nowS: Int64, timezone: String?) -> String {
        if outlook.state == .dry {
            return "Dry for 48 h"
        }
        guard timeValid(nowS) else {
            return ""
        }
        switch outlook.state {
        case .now:
            if outlook.endsKnown && timeValid(outlook.endS) && outlook.endS > nowS {
                return "Raining until \(WxFormat.clock(outlook.endS, timezone: timezone))"
            }
            return "Raining now"
        case .expected:
            guard timeValid(outlook.startS) else {
                return "Rain expected"
            }
            if outlook.startS <= nowS {
                return "Rain starting now"
            }
            let aheadS = outlook.startS - nowS  // both valid: no overflow
            if aheadS < hintSoonMinutes * 60 {
                return "Rain in \((aheadS + 59) / 60) min"
            }
            return hintAt(outlook.startS, nowS: nowS, timezone: timezone)
        case .possible, .dry:
            return "Showers possible"
        }
    }

    // MARK: - Derived item values

    /// item_recompute (wx-row.c:268-281): the current conditions and the rain outlook of
    /// `forecast` at `nowS`. The outlook is only claimed as far as the forecast covers: not at all
    /// without current conditions (a stale forecast) or for `nowS` outside [timeMinS, timeMaxS),
    /// and "dry" only when the amounts of the next 48 hours are all known (covers_dry_claim). A
    /// rain that is raining, expected or possible is reported whatever the coverage.
    public static func derive(forecast: WxForecast?, nowS: Int64) -> (current: WxBlendHour?, outlook: WxRainOutlook?) {
        guard let forecast else {
            return (nil, nil)
        }
        guard let current = WxBlend.now(forecast, nowS: nowS) else {
            return (nil, nil)
        }
        guard timeValid(nowS) else {
            return (current, nil)
        }
        let outlook = WxRainRules.outlook(forecast, nowS: nowS)
        if outlook.state != .dry || coversDryClaim(forecast, nowS: nowS) {
            return (current, outlook)
        }
        return (current, nil)
    }

    /// covers_dry_claim (wx-row.c:230-246): starting with the hour that contains `nowS`, hour
    /// after hour without a gap, every hour has a finite amount up to `nowS` + 48 h. False when no
    /// hour contains `nowS` (and for an invalid `nowS`).
    static func coversDryClaim(_ forecast: WxForecast, nowS: Int64) -> Bool {
        guard timeValid(nowS) else {
            return false
        }
        var untilS: Int64 = 0  // the end of what is known so far; 0 until the hour of nowS is found
        for h in forecast.hours {
            if untilS == 0 {
                // forecast hours are valid times, nowS is valid: the difference cannot overflow
                guard h.tS <= nowS && nowS - h.tS < 3600 else {
                    continue
                }
                untilS = h.tS
            }
            if h.tS != untilS || !h.precipMm.isFinite {
                break
            }
            untilS += 3600
        }
        return untilS != 0 && untilS - nowS >= WxRainRules.horizonS
    }

    // MARK: - Private helpers

    /// time_valid (wx-row.c:37-41).
    private static func timeValid(_ tS: Int64) -> Bool {
        tS >= WxLimits.timeMinS && tS < WxLimits.timeMaxS
    }

    /// hint_at (wx-row.c:61-71): "Rain at 4 PM", "Rain tomorrow, 4 PM" or "Rain Friday, 4 PM".
    private static func hintAt(_ startS: Int64, nowS: Int64, timezone: String?) -> String {
        let clock = WxFormat.hourLabel(startS, timezone: timezone)
        let day = WxFormat.weekday(startS, timezone: timezone, nowS: nowS)
        if day == "Today" {
            return "Rain at \(clock)"
        }
        if day == "Tomorrow" {
            return "Rain tomorrow, \(clock)"
        }
        return "Rain \(day), \(clock)"
    }

    /// region_text (wx-row.c:587-593): "Admin1, Country", the parts that are not empty.
    private static func regionText(_ place: WxPlace) -> String {
        if !place.admin1.isEmpty && !place.country.isEmpty {
            return place.admin1 + ", " + place.country
        }
        return !place.admin1.isEmpty ? place.admin1 : place.country
    }
}
