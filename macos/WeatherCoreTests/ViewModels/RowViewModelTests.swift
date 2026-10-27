// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// RowViewModelTests.swift - ports the row cases of src/ui/test-window.c (the rain hint, the
// values a WxRowItem derives, what a WxRow shows, its menu, drag and drop) to RowViewModel.
// Expected values are the C tests' literals (cited as test-window.c:LINE / test-detail.c:LINE);
// a few constant texts without a C test literal cite the C source line that defines them.

import Foundation
import Testing
@testable import WeatherCore

// MARK: - Fixtures (test-window.c:160-190, 728-848, 1000-1022)

/// ts(): a UTC civil time as unix seconds (test-window.c:731-737), by the days-from-civil rule.
private func ts(_ y: Int64, _ mo: Int64, _ d: Int64, _ h: Int64, _ mi: Int64) -> Int64 {
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let mp = (mo + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return days * 86_400 + h * 3600 + mi * 60
}

/// T_NOW: Sunday 2026-10-11 18:30Z = 2:30 PM in New York (test-window.c:727, 739).
private let tNow = ts(2026, 10, 11, 18, 30)
/// NY (test-window.c:49).
private let ny = "America/New_York"

/// place_new (test-window.c:164-171): "Florida", "United States", "US", NY.
private func place(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, admin1: "Florida", country: "United States", countryCode: "US", lat: lat, lon: lon,
                timezone: ny)
}

private func miami() throws -> WxPlace { try place("Miami", 25.7743, -80.1937) }  // test-window.c:176
private func orlando() throws -> WxPlace { try place("Orlando", 28.5383, -81.3792) }  // test-window.c:182
private func tampa() throws -> WxPlace { try place("Tampa", 27.9475, -82.4584) }  // test-window.c:188

/// make_forecast (test-window.c:827-848): 72 hours from the hour of T_NOW, 25 degC, dry, or wet
/// (2 mm, 80 %, rain) in the first 3 hours.
private func makeForecast(_ p: WxPlace, wet: Bool) throws -> WxForecast {
    let base = tNow - tNow % 3600
    let hours = (0 ..< 72).map { i in
        let w = wet && i < 3
        return WxBlendHour(tS: base + Int64(i) * 3600, tempC: 25, feelsC: 27, precipMm: w ? 2.0 : 0.0,
                           precipMmMax: w ? 2.0 : 0.0, precipProb: w ? 80 : 5, cloudPct: 50, windKmh: 10,
                           gustKmh: 15, humidityPct: 60, tempSpreadC: .nan, nMembers: 2,
                           condition: w ? .rain : .partlyCloudy, isDay: true)
    }
    return try WxForecast(place: p, generatedS: tNow, hours: hours)
}

/// coverage_forecast (test-window.c:1000-1022): `n` hours from the hour of T_NOW, dry, without
/// the hour index `gap` (-1: none), an unknown amount at `nanHour` (-1: none), wet below `wetTo`.
private func coverageForecast(_ p: WxPlace, _ n: Int, gap: Int, nanHour: Int, wetTo: Int) throws -> WxForecast {
    let base = tNow - tNow % 3600
    var hours: [WxBlendHour] = []
    for i in 0 ..< n where i != gap {
        let wet = i < wetTo
        hours.append(WxBlendHour(tS: base + Int64(i) * 3600, tempC: 25, feelsC: 27,
                                 precipMm: i == nanHour ? .nan : (wet ? 2.0 : 0.0), precipMmMax: 0,
                                 precipProb: wet ? 80 : 5, cloudPct: 50, windKmh: 10, gustKmh: 15,
                                 humidityPct: 60, tempSpreadC: .nan, nMembers: 2,
                                 condition: wet ? .rain : .partlyCloudy, isDay: true))
    }
    return try WxForecast(place: p, generatedS: tNow, hours: hours)
}

/// outlook_shown (test-window.c:1025-1037): whether the row holds an outlook and its hint.
private func outlookShown(_ p: WxPlace, _ f: WxForecast, _ nowS: Int64) -> (shown: Bool, hint: String) {
    let row = RowViewModel(place: p, forecast: f, nowS: nowS)
    return (row.outlook != nil, row.hint)
}

/// check_hint (test-window.c:741-747).
private func checkHint(_ state: WxRainState, _ start: Int64, _ end: Int64, _ endsKnown: Bool, _ expected: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
    let o = WxRainOutlook(state: state, startS: start, endS: end, peakS: start, peakMmH: 1, peakProb: 50,
                          endsKnown: endsKnown)
    #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: ny) == expected, "\(state) \(start) \(end)",
            sourceLocation: sourceLocation)
}

/// make_member (test-window.c:205-252) blended: hours from 2 h before to 72 h after the hour of
/// T_NOW, 24 degC, 40 % cloud, and the rain of the kind (test-window.c:235-245).
private enum RainKind {
    case dry, now, soon, later

    func isWet(_ i: Int) -> Bool {
        switch self {
        case .dry: false
        case .now: i >= -1 && i < 4
        case .soon: i >= 1 && i < 4
        case .later: i >= 4 && i < 7
        }
    }

    func forecast(_ p: WxPlace) throws -> WxForecast {
        let base = tNow - tNow % 3600
        let hours = (-2 ..< 72).map { i in
            let wet = isWet(i)
            return WxBlendHour(tS: base + Int64(i) * 3600, tempC: 24, feelsC: 26, precipMm: wet ? 2.0 : 0,
                               precipMmMax: wet ? 2.0 : 0, precipProb: wet ? 80 : 5, cloudPct: 40, windKmh: 12,
                               gustKmh: 20, humidityPct: 70, nMembers: 2, condition: wet ? .rain : .partlyCloudy,
                               isDay: true)
        }
        return try WxForecast(place: p, generatedS: tNow, hours: hours)
    }
}

/// A loaded AppModel over `places` (store_places + fx_start without providers: nothing is fetched).
@MainActor
private final class ModelFx {
    let dir: TemporaryDirectory
    let storage: AppEnvironment.StorageRoot
    let clock = ManualClock()

    init(_ label: String, _ places: [WxPlace]) throws {
        dir = try TemporaryDirectory("rowvm-\(label)")
        storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                             cacheDirectory: dir.appending("cache").path)
        let list = try #require(WxPlaces(path: storage.placesPath))
        for p in places {
            #expect(list.add(p))
        }
        try list.save()
    }

    func start(alerts: (any WxAlertsServing)? = nil) async -> AppModel {
        let m = AppModel(registry: WxRegistry(), storage: storage, clock: clock, online: true,
                         log: { _, _ in }, alerts: alerts)
        await m.load()
        return m
    }
}

/// order_of / model_order_of (test-window.c:409-425): the names in the model's order.
@MainActor
private func order(_ m: AppModel) -> String {
    m.places.map(\.place.name).joined(separator: ",")
}

/// row_named (test-window.c): the row of the place called `name`.
@MainActor
private func row(_ m: AppModel, _ name: String) throws -> RowViewModel {
    try #require(RowViewModel.rows(of: m).first { $0.name == name }, "no row \(name)")
}

// MARK: - Alerts (U52)

/// An NWS alert named `event` at `level`, its message expiring at `expiresS` and its event ending
/// at `endsS` (nil: not given).
private func alertFx(_ id: String, _ event: String, _ level: WxAlert.Level, expiresS: Int64? = nil,
                     endsS: Int64? = nil) -> WxAlert {
    WxAlert(id: "nws:" + id, source: .nws, event: event, headline: event + " in effect", description: "",
            instruction: "", level: level, issuerSeverity: "", onsetS: nil, expiresS: expiresS, endsS: endsS,
            web: nil)
}

/// An answer of the alerts service for a place: `state`, the alerts it holds, fetched a minute
/// before T_NOW.
private func alertsResult(_ state: WxAlertsResult.State, _ alerts: [WxAlert] = []) -> WxAlertsResult {
    WxAlertsResult(state: state, source: .nws, alerts: alerts, fetchedS: tNow - 60)
}

/// An alerts service that answers fixed results by place key and fetches nothing.
@MainActor
private final class RowFixedAlerts: WxAlertsServing {
    var results: [String: WxAlertsResult] = [:]

    func refresh(_ place: WxPlace) -> Task<Void, Never> { Task {} }
    func result(for place: WxPlace) -> WxAlertsResult { results[place.key] ?? AppModel.alertsNotFetched }
    func remove(placeKey: String) { results[placeKey] = nil }
    func cancelAll() {}
}

// MARK: - Suite

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct RowViewModelTests {
    // MARK: The rain hint (wx_row_rain_hint)

    @Test func hintTable() {  // C: /window/hint/table (test-window.c:749-771)
        checkHint(.now, tNow - 1800, tNow + 3600, true, "Raining until 3:30 PM")  // test-window.c:752
        checkHint(.now, tNow - 1800, 0, false, "Raining now")  // test-window.c:753
        checkHint(.now, tNow - 1800, tNow - 60, true, "Raining now")  // test-window.c:754
        checkHint(.now, tNow - 1800, 5, true, "Raining now")  // test-window.c:755
        checkHint(.expected, tNow + 25 * 60, 0, false, "Rain in 25 min")  // test-window.c:756
        checkHint(.expected, tNow + 1, 0, false, "Rain in 1 min")  // test-window.c:757
        checkHint(.expected, tNow + 60, 0, false, "Rain in 1 min")  // test-window.c:758
        checkHint(.expected, tNow + 61, 0, false, "Rain in 2 min")  // test-window.c:759
        checkHint(.expected, tNow + 89 * 60, 0, false, "Rain in 89 min")  // test-window.c:760
        checkHint(.expected, tNow + 90 * 60 - 1, 0, false, "Rain in 90 min")  // test-window.c:761
        checkHint(.expected, tNow + 90 * 60, 0, false, "Rain at 4 PM")  // test-window.c:762
        checkHint(.expected, tNow + 2 * 3600 + 15 * 60, 0, false, "Rain at 4:45 PM")  // test-window.c:763
        checkHint(.expected, tNow, 0, false, "Rain starting now")  // test-window.c:764
        checkHint(.expected, tNow - 100, 0, false, "Rain starting now")  // test-window.c:765
        checkHint(.expected, ts(2026, 10, 12, 20, 0), 0, false, "Rain tomorrow, 4 PM")  // test-window.c:766
        checkHint(.expected, ts(2026, 10, 13, 20, 0), 0, false, "Rain Tuesday, 4 PM")  // test-window.c:767
        checkHint(.expected, 7, 0, false, "Rain expected")  // test-window.c:768
        checkHint(.possible, 0, 0, false, "Showers possible")  // test-window.c:769
        checkHint(.dry, 0, 0, false, "Dry for 48 h")  // test-window.c:770
        #expect(RowViewModel.hintSoonMinutes == 90)  // HINT_SOON_MINUTES, wx-row.c:16
    }

    @Test func hintEdges() {  // C: /window/hint/edges (test-window.c:773-802)
        var o = WxRainOutlook(state: .expected, startS: tNow + 600)
        // A now outside the valid time range gives "", except for the dry sentence.
        #expect(RowViewModel.rainHint(o, nowS: 0, timezone: ny) == "")  // test-window.c:778
        #expect(RowViewModel.rainHint(o, nowS: .max, timezone: ny) == "")  // test-window.c:780
        #expect(RowViewModel.rainHint(o, nowS: .min, timezone: ny) == "")  // test-window.c:782
        o.state = .dry
        #expect(RowViewModel.rainHint(o, nowS: .min, timezone: ny) == "Dry for 48 h")  // test-window.c:786
        // Extreme stamps never overflow.
        o = WxRainOutlook(state: .expected, startS: .max)
        #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: ny) == "Rain expected")  // test-window.c:790
        o = WxRainOutlook(state: .now, endS: .min, endsKnown: true)
        #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: ny) == "Raining now")  // test-window.c:793
        // The zone decides the clock; a bad zone is UTC.
        o = WxRainOutlook(state: .expected, startS: tNow + 3 * 3600)
        #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: "Asia/Tokyo") == "Rain at 6:30 AM")  // :797
        #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: "../etc/passwd") == "Rain at 9:30 PM")  // :799
        #expect(RowViewModel.rainHint(o, nowS: tNow, timezone: nil) == "Rain at 9:30 PM")  // :801
    }

    // MARK: Derived item values

    @Test func itemDefaultsWithoutForecast() throws {  // C: /window/item/defaults-and-arguments
        let p = try miami()
        let row = RowViewModel(place: p, forecast: nil, nowS: tNow)
        #expect(row.key == p.key)  // test-window.c:864-865
        #expect(row.name == "Miami")  // test-window.c:866
        #expect(row.outlook == nil)  // test-window.c:875
        #expect(row.current == nil)  // test-window.c:877
        #expect(!row.hasForecast)  // test-window.c:868
    }

    @Test func itemForecastAndNow() throws {  // C: /window/item/forecast-and-now (test-window.c:946-998)
        let p = try miami()
        let f = try makeForecast(p, wet: false)
        let wet = try makeForecast(p, wet: true)
        var row = RowViewModel(place: p, forecast: f, nowS: tNow)
        let cur = try #require(row.current)
        #expect(cur.tempC == 25)  // test-window.c:967
        #expect(try #require(row.outlook).state == .dry)  // test-window.c:970
        row = RowViewModel(place: p, forecast: wet, nowS: tNow)
        #expect(try #require(row.outlook).state == .now)  // test-window.c:974
        // "now" far past the data: no current conditions and no outlook (test-window.c:976-980).
        row = RowViewModel(place: p, forecast: wet, nowS: tNow + 400 * 3600)
        #expect(row.current == nil)
        #expect(row.outlook == nil)
        // "now" outside the valid time range: neither (test-window.c:982-989).
        for now in [Int64(5), .max, .min] {
            row = RowViewModel(place: p, forecast: wet, nowS: now)
            #expect(row.outlook == nil, "now \(now)")
            #expect(row.current == nil, "now \(now)")
        }
        // No forecast: no derived values (test-window.c:992-995).
        row = RowViewModel(place: p, forecast: nil, nowS: tNow)
        #expect(row.outlook == nil)
        #expect(row.current == nil)
        let derived = RowViewModel.derive(forecast: nil, nowS: tNow)
        #expect(derived.current == nil && derived.outlook == nil)
    }

    @Test func itemDryClaimNeedsCoverage() throws {  // C: /window/item/dry-claim-needs-coverage
        let p = try miami()
        let f49 = try coverageForecast(p, 49, gap: -1, nanHour: -1, wetTo: 0)
        let f48 = try coverageForecast(p, 48, gap: -1, nanHour: -1, wetTo: 0)
        var r = outlookShown(p, f49, tNow)
        #expect(r.shown)  // test-window.c:1052
        #expect(r.hint == "Dry for 48 h")  // test-window.c:1053
        #expect(outlookShown(p, f49, tNow + 1800 - 1).shown)  // test-window.c:1055
        r = outlookShown(p, f49, tNow + 1800 + 1)
        #expect(!r.shown)  // test-window.c:1057
        #expect(r.hint == "No rain data")  // test-window.c:1058
        r = outlookShown(p, f48, tNow)
        #expect(!r.shown)  // test-window.c:1061
        #expect(r.hint == "No rain data")  // test-window.c:1062
        // A missing hour or an unknown amount inside the horizon: not covered; past it: covered.
        #expect(!outlookShown(p, try coverageForecast(p, 72, gap: 10, nanHour: -1, wetTo: 0), tNow).shown)  // :1067
        #expect(outlookShown(p, try coverageForecast(p, 72, gap: 49, nanHour: -1, wetTo: 0), tNow).shown)  // :1070
        #expect(!outlookShown(p, try coverageForecast(p, 72, gap: -1, nanHour: 30, wetTo: 0), tNow).shown)  // :1073
        #expect(!outlookShown(p, try coverageForecast(p, 72, gap: -1, nanHour: 0, wetTo: 0), tNow).shown)  // :1076
        #expect(outlookShown(p, try coverageForecast(p, 72, gap: -1, nanHour: 49, wetTo: 0), tNow).shown)  // :1079
        // The hour of "now" missing: no current conditions either, and a later rain is no claim.
        #expect(!outlookShown(p, try coverageForecast(p, 72, gap: 0, nanHour: -1, wetTo: 0), tNow).shown)  // :1083
        r = outlookShown(p, try coverageForecast(p, 72, gap: 0, nanHour: -1, wetTo: 3), tNow)
        #expect(!r.shown)  // test-window.c:1087
        #expect(r.hint == "No rain data")  // test-window.c:1088
        // Rain in a short forecast is still reported: raining now, expected, possible.
        r = outlookShown(p, try coverageForecast(p, 4, gap: -1, nanHour: -1, wetTo: 2), tNow)
        #expect(r.shown)  // test-window.c:1093
        #expect(r.hint == "Raining until 4:00 PM")  // test-window.c:1094
        let base = tNow - tNow % 3600
        var soon = (0 ..< 4).map { i in  // test-window.c:1097-1104
            WxBlendHour(tS: base + Int64(i) * 3600, tempC: 25, feelsC: 27, precipMm: i == 2 ? 2.0 : 0.0,
                        precipMmMax: 0, precipProb: i == 2 ? 80 : 50, cloudPct: 50, windKmh: 10, gustKmh: 15,
                        humidityPct: 60, tempSpreadC: .nan, nMembers: 2, condition: .partlyCloudy, isDay: true)
        }
        r = outlookShown(p, try WxForecast(place: p, generatedS: tNow, hours: soon), tNow)
        #expect(r.shown)  // test-window.c:1107
        #expect(r.hint == "Rain at 4 PM")  // test-window.c:1108
        soon[2].precipMm = 0
        soon[2].precipProb = 50
        r = outlookShown(p, try WxForecast(place: p, generatedS: tNow, hours: soon), tNow)
        #expect(r.shown)  // test-window.c:1114
        #expect(r.hint == "Showers possible")  // test-window.c:1115
    }

    // MARK: What a row shows

    @Test func bindingFollowsItem() throws {  // C: /window/row/binding-follows-item (test-window.c:2509-2571)
        let p = try miami()
        var row = RowViewModel(place: p, forecast: nil, nowS: tNow)
        #expect(row.name == "Miami")  // test-window.c:2516
        #expect(row.region == "Florida, United States")  // test-window.c:2517
        #expect(row.isRegionVisible)
        #expect(row.hint == "No data yet")  // test-window.c:2518
        #expect(row.temperature == "\u{2014}")  // test-window.c:2519
        #expect(row.markerText == "")  // test-window.c:2520
        #expect(!row.isMarkerVisible)
        #expect(row.isEmpty)  // test-window.c:2521
        #expect(!row.isDim)  // test-window.c:2522
        #expect(row.gtkIconName == "dialog-question-symbolic")  // no current conditions (wx-row.c:705-706)
        row = RowViewModel(place: p, forecast: nil, loading: true, nowS: tNow)
        #expect(row.hint == "Loading\u{2026}")  // test-window.c:2524
        row = RowViewModel(place: p, forecast: nil, nowS: tNow, errorText: "boom")
        #expect(row.hint == "Can't load forecast")  // test-window.c:2527
        row = RowViewModel(place: p, forecast: nil, offline: true, nowS: tNow)
        #expect(row.hint == "Offline")  // test-window.c:2530
        #expect(row.markerText == "")  // test-window.c:2531: no data, no marker
        // With a forecast.
        let f = try makeForecast(p, wet: true)
        row = RowViewModel(place: p, forecast: f, nowS: tNow)
        #expect(row.temperature == "77\u{00B0}")  // test-window.c:2537
        #expect(row.hint == "Raining until 5:00 PM")  // test-window.c:2538
        #expect(!row.isEmpty)  // test-window.c:2539
        row = RowViewModel(place: p, forecast: f, units: .metric, nowS: tNow)
        #expect(row.temperature == "25\u{00B0}")  // test-window.c:2541
        row = RowViewModel(place: p, forecast: f, stale: true, units: .metric, nowS: tNow)
        #expect(row.markerText == "Stale")  // test-window.c:2543
        #expect(row.marker == .stale)
        #expect(row.isMarkerVisible)
        #expect(row.isDim)  // test-window.c:2544
        row = RowViewModel(place: p, forecast: f, stale: true, offline: true, units: .metric, nowS: tNow)
        #expect(row.markerText == "Offline")  // test-window.c:2546: offline wins
        row = RowViewModel(place: p, forecast: f, loading: true, units: .metric, nowS: tNow)
        #expect(row.markerText == "Updating\u{2026}")  // test-window.c:2550
        #expect(!row.isDim)  // test-window.c:2551
        // A place without region shows no region line (test-window.c:2553-2557).
        let bare = try WxPlace(name: "Oslo", lat: 59.9, lon: 10.7, timezone: "Europe/Oslo")
        row = RowViewModel(place: bare, forecast: nil, nowS: tNow)
        #expect(row.region == "")  // test-window.c:2556
        #expect(!row.isRegionVisible)  // test-window.c:2557
    }

    @Test func noRainData() throws {  // C: /window/row/no-rain-data (test-window.c:3870-3884)
        let p = try miami()
        let row = RowViewModel(place: p, forecast: try makeForecast(p, wet: false), nowS: 5)
        #expect(row.outlook == nil)  // test-window.c:3880
        #expect(row.hint == "No rain data")  // test-window.c:3881
        #expect(row.temperature == "\u{2014}")  // test-window.c:3882
    }

    @Test func tooltipAndAccessibility() throws {  // C: wx-row.c:722-727 (summary), wx-detail.c:404-405
        let p = try miami()
        let f = try makeForecast(p, wet: true)
        // The tooltip is the full place label ("Miami, Florida, United States", test-window.c:1264).
        var row = RowViewModel(place: p, forecast: f, stale: true, nowS: tNow)
        #expect(row.tooltip == "Miami, Florida, United States")
        // "<label>: <temp>, <hint>[, <marker>]" (wx-row.c:724-725) of the literals of
        // test-window.c:1264, 2537, 2538, 2543; the temperature carries its units (U50: "77°F",
        // "— °F"; the C label had none).
        #expect(row.accessibilityLabel == "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM, Stale")
        row = RowViewModel(place: p, forecast: f, nowS: tNow)
        #expect(row.accessibilityLabel == "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM")
        row = RowViewModel(place: p, forecast: nil, nowS: tNow)
        // test-window.c:1264, 2518, 2519: no marker without data.
        #expect(row.accessibilityLabel == "Miami, Florida, United States: \u{2014} \u{00B0}F, No data yet")
        // The badge tooltips (test-detail.c:1764, 1773, 1776, 1778-1779, 1781).
        #expect(RowViewModel.offlineTooltip == "No network connection: showing the last forecast")
        #expect(RowViewModel.staleTooltip(errorText: nil) == "The last refresh failed")
        #expect(RowViewModel.staleTooltip(errorText: "HTTP 503") == "The last refresh failed: HTTP 503")
        #expect(RowViewModel.staleTooltip(errorText: "<b>x</b> & y") == "The last refresh failed: <b>x</b> & y")
        #expect(RowViewModel.staleTooltip(errorText: "") == "The last refresh failed")
        // Constant labels without a C test literal: wx-window.c:941, wx-row.c:1144, 1150-1152.
        #expect(RowViewModel.listAccessibilityLabel == "Saved places")
        #expect(RowViewModel.menuButtonLabel == "Place actions")
        #expect(RowViewModel.menuButtonText == "\u{2026}")
    }

    // MARK: Rain texts of the row and the same item's headline

    private func rainCase(_ kind: RainKind, headlinePrefix: String, hintPrefix: String, hasDetail: Bool) throws {
        let p = try miami()
        let row = RowViewModel(place: p, forecast: try kind.forecast(p), nowS: tNow)
        let o = try #require(row.outlook)
        // The hint is exactly the pure text of the item's outlook, and the detail headline of the
        // same outlook agrees (test-window.c:2152-2165).
        #expect(row.hint == RowViewModel.rainHint(o, nowS: tNow, timezone: ny))
        #expect(row.hint.hasPrefix(hintPrefix), "\(row.hint)")
        let headline = WxFormat.rainHeadline(o, nowS: tNow, timezone: ny)
        #expect(headline.hasPrefix(headlinePrefix), "\(headline)")
        #expect(!WxFormat.rainDetail(o, nowS: tNow, timezone: ny).isEmpty == hasDetail)
    }

    @Test func rainDry() throws {  // C: /window/rain/dry (test-window.c:2184)
        try rainCase(.dry, headlinePrefix: "No rain expected for the next 48 hours", hintPrefix: "Dry for 48 h",
                     hasDetail: false)
    }

    @Test func rainNow() throws {  // C: /window/rain/now (test-window.c:2190)
        try rainCase(.now, headlinePrefix: "Raining now", hintPrefix: "Raining", hasDetail: true)
    }

    @Test func rainSoon() throws {  // C: /window/rain/soon (test-window.c:2196)
        try rainCase(.soon, headlinePrefix: "Rain starting", hintPrefix: "Rain in", hasDetail: true)
    }

    @Test func rainLater() throws {  // C: /window/rain/later (test-window.c:2202)
        try rainCase(.later, headlinePrefix: "Rain expected", hintPrefix: "Rain ", hasDetail: true)
    }

    // MARK: Per-place units (U50)

    /// A loaded model over Miami and Orlando, the default units imperial, Orlando's own units
    /// metric (AppModel.setUnits(_:forKey:)); the items of both with the 25 degC wet forecast
    /// at T_NOW (the item's forecast and "now" are what a refresh would set).
    private func unitsItems(_ label: String) async throws -> (AppModel, [AppModel.Place]) {
        let fx = try ModelFx(label, [try miami(), try orlando()])
        let m = await fx.start()
        #expect(m.defaultUnits == .imperial)
        #expect(m.setUnits(.metric, forKey: try orlando().key))
        let items = try m.places.map { item in
            var copy = item
            copy.forecast = try makeForecast(item.place, wet: true)
            copy.nowS = tNow
            return copy
        }
        return (m, items)
    }

    @Test func unitLabelPerPlace() async throws {
        #expect(RowViewModel.unitLabel(.imperial) == "\u{00B0}F")
        #expect(RowViewModel.unitLabel(.metric) == "\u{00B0}C")
        let (m, items) = try await unitsItems("unit-label")
        // The rows of the model: each place's own units, whatever the default.
        let rows = RowViewModel.rows(of: m)
        #expect(rows.map(\.name) == ["Miami", "Orlando"])
        #expect(rows.map(\.units) == [.imperial, .metric])
        #expect(rows.map(\.unitLabel) == ["\u{00B0}F", "\u{00B0}C"])
        #expect(items.map { RowViewModel($0).unitLabel } == ["\u{00B0}F", "\u{00B0}C"])
        // The default changes nothing for a place with its own units.
        m.setDefaultUnits(.metric)
        #expect(RowViewModel.rows(of: m).map(\.unitLabel) == ["\u{00B0}F", "\u{00B0}C"])
        // Live conditions keep the units they are given (the place's).
        let live = try #require(items[1].forecast?.hours.first)
        #expect(RowViewModel(items[1]).withLiveCurrent(live, units: items[1].units).unitLabel == "\u{00B0}C")
        _ = await m.flush()
    }

    @Test func temperatureInPlaceUnits() async throws {
        let (m, items) = try await unitsItems("temperature")
        // 25 degC: 77 deg in Miami (imperial), 25 deg in Orlando (metric) (test-window.c:2537, 2541).
        #expect(items.map { RowViewModel($0).temperature } == ["77\u{00B0}", "25\u{00B0}"])
        // Live conditions, 10 degC: 50 deg F and 10 deg C.
        var live = try #require(items[0].forecast?.hours.first)
        live.tempC = 10
        #expect(items.map { RowViewModel($0).withLiveCurrent(live, units: $0.units).temperature }
            == ["50\u{00B0}", "10\u{00B0}"])
        // Without current conditions: the em dash in either system.
        #expect(RowViewModel.rows(of: m).map(\.temperature) == ["\u{2014}", "\u{2014}"])
        _ = await m.flush()
    }

    @Test func accessibilityIncludesUnits() async throws {
        let (m, items) = try await unitsItems("accessibility")
        #expect(items.map { RowViewModel($0).accessibilityLabel } == [
            "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM",
            "Orlando, Florida, United States: 25\u{00B0}C, Raining until 5:00 PM",
        ])
        // No temperature: the units are still spoken after the em dash.
        #expect(RowViewModel.rows(of: m).map(\.accessibilityLabel) == [
            "Miami, Florida, United States: \u{2014} \u{00B0}F, No data yet",
            "Orlando, Florida, United States: \u{2014} \u{00B0}C, No data yet",
        ])
        // With a marker, and with live conditions in the place's units.
        var stale = items[1]
        stale.stale = true
        #expect(RowViewModel(stale).accessibilityLabel
            == "Orlando, Florida, United States: 25\u{00B0}C, Raining until 5:00 PM, Stale")
        var live = try #require(items[1].forecast?.hours.first)
        live.tempC = 10
        #expect(RowViewModel(items[1]).withLiveCurrent(live, units: items[1].units).accessibilityLabel
            == "Orlando, Florida, United States: 10\u{00B0}C, Raining until 5:00 PM")
        _ = await m.flush()
    }

    @Test func rowsFollowTheItemClock() async throws {  // C: /window/rain/rows-follow-item-clock
        let p = try miami()
        let f = try RainKind.later.forecast(p)
        let fetchedS = tNow
        let before = RowViewModel(place: p, forecast: f, nowS: tNow).hint
        // Four hours on, the rain (4 to 5 hours after the start of the hour) is under way.
        let now = fetchedS + 4 * 3600
        let after = RowViewModel(place: p, forecast: f, nowS: now)
        #expect(after.hint != before)  // test-window.c:2224
        #expect(after.hint.hasPrefix("Raining"), "\(after.hint)")  // test-window.c:2225
        let o = try #require(after.outlook)
        #expect(WxFormat.rainHeadline(o, nowS: now, timezone: ny).hasPrefix("Raining now"))  // :2226
        #expect(WxFormat.updated(ageS: now - fetchedS) == "Updated 4 h ago")  // test-window.c:2227
        // The rows of a real model follow its items' "now" the same way.
        let fx = try ModelFx("clock", [p])
        let m = await fx.start()
        let item = try #require(m.places.first)
        var copy = item
        copy.forecast = f
        copy.nowS = now
        #expect(RowViewModel(copy).hint.hasPrefix("Raining"))
        _ = await m.flush()
    }

    // MARK: The row's menu, drag and drop, and the actions on AppModel

    @Test func menuAndDragAndDrop() async throws {  // C: /window/row/menu-and-drag-and-drop
        // The menu: Move up, Move down, Remove (test-window.c:3939-3945).
        #expect(RowViewModel.menuActions.map(\.title) == ["Move up", "Move down", "Remove"])
        let fx = try ModelFx("dnd", [try miami(), try orlando(), try tampa()])
        let m = await fx.start()
        let miamiRow = try row(m, "Miami")
        // Drag source: the payload of a row is its key (test-window.c:3959).
        #expect(miamiRow.dragPayload == (try miami()).key)
        // Drop target: any text is handed on and accepted; nothing else (test-window.c:3971-3980).
        #expect(miamiRow.acceptDrop("some text from elsewhere", in: m))
        #expect(order(m) == "Miami,Orlando,Tampa")  // test-window.c:2476
        #expect(!miamiRow.acceptDrop(nil, in: m))
        #expect(order(m) == "Miami,Orlando,Tampa")
        _ = await m.flush()
    }

    @Test func moveUpAndDown() async throws {  // C: /window/places/move-up-down (test-window.c:2427-2453)
        let fx = try ModelFx("move", [try miami(), try orlando(), try tampa()])
        var m = await fx.start()
        #expect(try row(m, "Tampa").moveUp(in: m))
        #expect(order(m) == "Miami,Tampa,Orlando")  // test-window.c:2437, 2439
        #expect(try row(m, "Miami").perform(.moveDown, in: m))
        #expect(order(m) == "Tampa,Miami,Orlando")  // test-window.c:2442
        // Moving past either end does nothing.
        #expect(!(try row(m, "Tampa").perform(.moveUp, in: m)))
        #expect(!(try row(m, "Orlando").moveDown(in: m)))
        #expect(order(m) == "Tampa,Miami,Orlando")  // test-window.c:2447
        // The order is stored and restored.
        #expect(await m.flush())
        m = await fx.start()
        #expect(order(m) == "Tampa,Miami,Orlando")  // test-window.c:2451
        _ = await m.flush()
    }

    @Test func reorderByDropAndHostilePayloads() async throws {  // C: /window/places/reorder-by-drop
        let fx = try ModelFx("drop", [try miami(), try orlando(), try tampa()])
        let m = await fx.start()
        let tampaRow = try row(m, "Tampa")
        let miamiRow = try row(m, "Miami")
        // Hostile payloads change nothing (test-window.c:2469-2476); "\xFF\xFE" cannot be a Swift
        // String, so its decoded form (two U+FFFD) stands in for it.
        let bad = ["", "x", "../../etc/passwd", "%s%s%s", "99.0000,99.0000", String(repeating: "9", count: 10000),
                   "25.7743,-80.1937 ", String(decoding: [0xFF, 0xFE] as [UInt8], as: UTF8.self)]
        for text in bad {
            #expect(tampaRow.acceptDrop(text, in: m))
        }
        #expect(order(m) == "Miami,Orlando,Tampa")  // test-window.c:2476
        // A drop of a valid key moves that place to the target's position.
        #expect(tampaRow.acceptDrop(miamiRow.dragPayload, in: m))
        #expect(order(m) == "Orlando,Tampa,Miami")  // test-window.c:2480
        #expect(miamiRow.acceptDrop(tampaRow.dragPayload, in: m))
        #expect(order(m) == "Orlando,Miami,Tampa")  // test-window.c:2483
        // A row's own key as source is a no-op.
        #expect(miamiRow.acceptDrop(miamiRow.dragPayload, in: m))
        #expect(order(m) == "Orlando,Miami,Tampa")  // test-window.c:2487
        _ = await m.flush()
    }

    @Test func removeThroughTheRow() async throws {  // C: /window/places/remove-selects-neighbour (2358-2392)
        let fx = try ModelFx("remove", [try miami(), try orlando(), try tampa()])
        let m = await fx.start()
        let okey = (try orlando()).key
        m.select(okey)
        #expect(m.selectedKey == okey)  // test-window.c:2370
        let orlandoRow = try row(m, "Orlando")
        // The model's item is what the row shows (no data yet: nothing was fetched).
        #expect(orlandoRow.hint == "No data yet")  // test-window.c:2518
        #expect(orlandoRow.remove(in: m))
        #expect(m.places.count == 2)  // test-window.c:2377
        #expect(m.place(forKey: okey) == nil)  // test-window.c:2378-2379
        #expect(m.selectedKey != nil)  // test-window.c:2380
        #expect(m.selectedKey != okey)  // test-window.c:2381
        // C: /window/row/unbound-emits-nothing (analogue): the actions of a row whose place is gone
        // change nothing.
        #expect(!orlandoRow.perform(.remove, in: m))
        #expect(!orlandoRow.moveUp(in: m))
        #expect(!orlandoRow.moveDown(in: m))
        #expect(order(m) == "Miami,Tampa")
        // Removing the others leaves nothing selected.
        #expect(try row(m, "Miami").perform(.remove, in: m))
        #expect(try row(m, "Tampa").remove(in: m))
        #expect(m.places.isEmpty)
        #expect(m.selectedKey == nil)  // test-window.c:2389
        #expect(RowViewModel.rows(of: m).isEmpty)
        _ = await m.flush()
    }

    // MARK: The unit suffix and the alert indicator (U52)

    @Test func unitSuffixBothForms() async throws {
        let (m, items) = try await unitsItems("unit-suffix")
        // With a temperature: the unit letter after the degree sign, "77°F" / "25°C".
        let rows = items.map(RowViewModel.init)
        #expect(rows.map(\.unitSuffix) == ["F", "C"])
        #expect(rows.map { $0.temperature + $0.unitSuffix } == ["77\u{00B0}F", "25\u{00B0}C"])
        // The temperature and the unit label are unchanged (U50).
        #expect(rows.map(\.temperature) == ["77\u{00B0}", "25\u{00B0}"])
        #expect(rows.map(\.unitLabel) == ["\u{00B0}F", "\u{00B0}C"])
        // Live conditions: the same form in the units given.
        var live = try #require(items[0].forecast?.hours.first)
        live.tempC = 10
        #expect(items.map { r in
            let row = RowViewModel(r).withLiveCurrent(live, units: r.units)
            return row.temperature + row.unitSuffix
        } == ["50\u{00B0}F", "10\u{00B0}C"])
        // Without current conditions: the em dash, then the unit label, "— °F" / "— °C".
        let empty = RowViewModel.rows(of: m)
        #expect(empty.map(\.unitSuffix) == ["\u{00B0}F", "\u{00B0}C"])
        #expect(empty.map { $0.temperature + " " + $0.unitSuffix } == ["\u{2014} \u{00B0}F", "\u{2014} \u{00B0}C"])
        // The row reads as its accessible label says.
        for row in rows + empty {
            let shown = row.temperature + (row.temperature.hasSuffix("\u{00B0}") ? "" : " ") + row.unitSuffix
            #expect(row.accessibilityLabel.contains(": " + shown + ", "), "\(row.accessibilityLabel)")
        }
        _ = await m.flush()
    }

    @Test func alertIndicatorHighestSeverity() async throws {
        let (m, items) = try await unitsItems("alert-level")
        var mia = items[0]
        // One alert: its own level, whichever it is.
        for level in WxAlert.Level.allCases {
            mia.alerts = alertsResult(.current, [alertFx("1", "Alert", level, expiresS: tNow + 3600)])
            #expect(RowViewModel(mia).alertIndicator == RowViewModel.AlertIndicator(level: level, count: 1))
        }
        // Several: the highest level, wherever it stands in the list (not the first one's).
        mia.alerts = alertsResult(.current, [
            alertFx("1", "Wind Advisory", .yellow, expiresS: tNow + 3600),
            alertFx("2", "Special Statement", .unknown),
            alertFx("3", "Tornado Warning", .red, expiresS: tNow + 3600),
            alertFx("4", "Flood Watch", .orange, endsS: tNow + 7200),
        ])
        #expect(RowViewModel(mia).alertIndicator == RowViewModel.AlertIndicator(level: .red, count: 4))
        // Live conditions keep the indicator.
        let live = try #require(mia.forecast?.hours.first)
        #expect(RowViewModel(mia).withLiveCurrent(live, units: mia.units).alertIndicator?.level == .red)
        // An expired red alert is not the highest any more: orange is.
        mia.alerts = alertsResult(.current, [
            alertFx("1", "Wind Advisory", .yellow, expiresS: tNow + 3600),
            alertFx("3", "Tornado Warning", .red, expiresS: tNow),
            alertFx("4", "Flood Watch", .orange, endsS: tNow + 7200),
        ])
        #expect(RowViewModel(mia).alertIndicator == RowViewModel.AlertIndicator(level: .orange, count: 2))
        #expect(RowViewModel.AlertIndicator.symbolName == "exclamationmark.triangle.fill")
        _ = await m.flush()

        // The rows of a model: the alerts service's result for the place reaches its row.
        let fx = try ModelFx("alert-model", [try miami(), try orlando()])
        let now = fx.clock.wallSeconds
        let service = RowFixedAlerts()
        service.results[try miami().key] = WxAlertsResult(state: .current, source: .nws, alerts: [
            alertFx("a", "Flood Watch", .orange, expiresS: now + 3600),
            alertFx("b", "Tornado Warning", .red, expiresS: now + 3600),
        ], fetchedS: now)
        let model = await fx.start(alerts: service)
        let modelRows = RowViewModel.rows(of: model)
        #expect(modelRows.map(\.name) == ["Miami", "Orlando"])
        #expect(modelRows.map(\.alertIndicator) == [RowViewModel.AlertIndicator(level: .red, count: 2), nil])
        _ = await model.flush()
    }

    @Test func alertIndicatorCount() async throws {
        let (m, items) = try await unitsItems("alert-count")
        var mia = items[0]
        let gale = alertFx("1", "Gale Warning", .orange, expiresS: tNow + 3600)
        let surf = alertFx("2", "High Surf Advisory", .yellow, expiresS: tNow + 3600)
        let heat = alertFx("3", "Heat Advisory", .yellow)
        // One alert: no number; two and three: their number.
        for (list, count, text) in [([gale], 1, nil), ([gale, surf], 2, "2"), ([gale, surf, heat], 3, "3")]
            as [([WxAlert], Int, String?)] {
            mia.alerts = alertsResult(.current, list)
            let indicator = RowViewModel(mia).alertIndicator
            #expect(indicator?.count == count)
            #expect(indicator?.countText == text)
        }
        // Expiry at the item's "now": an alert expiring or ending at nowS is gone, one a second
        // later and an open-ended one count.
        mia.alerts = alertsResult(.current, [
            alertFx("x", "Expired Warning", .red, expiresS: tNow),
            alertFx("y", "Ended Warning", .red, expiresS: tNow + 3600, endsS: tNow),
            alertFx("z", "Wind Advisory", .yellow, expiresS: tNow + 1),
            heat,
        ])
        var row = RowViewModel(mia)
        #expect(row.alerts.map(\.id) == ["nws:z", "nws:3"])
        #expect(row.alertIndicator == RowViewModel.AlertIndicator(level: .yellow, count: 2))
        // One second on, the advisory has expired too: one alert, no number.
        mia.nowS = tNow + 1
        row = RowViewModel(mia)
        #expect(row.alerts.map(\.id) == ["nws:3"])
        #expect(row.alertIndicator == RowViewModel.AlertIndicator(level: .yellow, count: 1))
        #expect(row.alertIndicator?.countText == nil)
        _ = await m.flush()
    }

    @Test func noIndicatorWithoutAlerts() async throws {
        let (m, items) = try await unitsItems("alert-none")
        let label = "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM"
        let held = [alertFx("1", "Tornado Warning", .red, expiresS: tNow + 3600)]
        // No service answer yet, the default, and a current answer without alerts.
        var mia = items[0]
        #expect(mia.alerts == AppModel.alertsNotFetched)
        for row in [RowViewModel(mia), RowViewModel(place: mia.place, forecast: mia.forecast, nowS: tNow)] {
            #expect(row.alertIndicator == nil)
            #expect(row.alerts.isEmpty)
            #expect(row.accessibilityLabel == label)
        }
        // Every state but current shows nothing, even with alerts held (a stale set is never current).
        for state in WxAlertsResult.State.allCases where state != .current {
            mia.alerts = alertsResult(state, held)
            let row = RowViewModel(mia)
            #expect(row.alertIndicator == nil, "\(state)")
            #expect(row.alerts.isEmpty, "\(state)")
            #expect(row.accessibilityLabel == label, "\(state)")
        }
        // Current without alerts, and current with only alerts expired at nowS.
        for list in [[], [alertFx("1", "Tornado Warning", .red, expiresS: tNow)]] as [[WxAlert]] {
            mia.alerts = alertsResult(.current, list)
            #expect(RowViewModel(mia).alertIndicator == nil)
            #expect(RowViewModel(mia).accessibilityLabel == label)
        }
        // The rows of a model with no alerts service: no indicator anywhere.
        #expect(RowViewModel.rows(of: m).allSatisfy { $0.alertIndicator == nil && $0.alerts.isEmpty })
        _ = await m.flush()
    }

    @Test func accessibilityNamesAlerts() async throws {
        let (m, items) = try await unitsItems("alert-a11y")
        var mia = items[0]
        let tornado = alertFx("1", "Tornado Warning", .red, expiresS: tNow + 3600)
        // One alert: named with its level.
        mia.alerts = alertsResult(.current, [tornado])
        #expect(RowViewModel(mia).accessibilityLabel
            == "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM, Alert: Tornado Warning (red)")
        // Several, after the marker, in their order; an unknown level is not spoken and an alert
        // without an event name is named by its headline.
        let nameless = WxAlert(id: "nws:5", source: .nws, event: "", headline: "Coastal Flood Statement",
                               description: "", instruction: "", level: .minor, issuerSeverity: "Minor", onsetS: nil,
                               expiresS: nil, endsS: nil, web: nil)
        mia.alerts = alertsResult(.current, [
            tornado, alertFx("2", "Flood Watch", .orange), alertFx("3", "Special Statement", .unknown), nameless,
        ])
        mia.stale = true
        #expect(RowViewModel(mia).accessibilityLabel
            == "Miami, Florida, United States: 77\u{00B0}F, Raining until 5:00 PM, Stale, 4 alerts: "
            + "Tornado Warning (red), Flood Watch (orange), Special Statement, Coastal Flood Statement (minor)")
        // Metric, and live conditions: the units part is unchanged, the alerts follow it.
        var orl = items[1]
        orl.alerts = alertsResult(.current, [alertFx("4", "Wind Advisory", .yellow)])
        var live = try #require(orl.forecast?.hours.first)
        live.tempC = 10
        #expect(RowViewModel(orl).withLiveCurrent(live, units: orl.units).accessibilityLabel
            == "Orlando, Florida, United States: 10\u{00B0}C, Raining until 5:00 PM, Alert: Wind Advisory (yellow)")
        // An expired alert and a stale set are not spoken.
        orl.alerts = alertsResult(.current, [alertFx("4", "Wind Advisory", .yellow, expiresS: tNow)])
        #expect(RowViewModel(orl).accessibilityLabel
            == "Orlando, Florida, United States: 25\u{00B0}C, Raining until 5:00 PM")
        orl.alerts = alertsResult(.stale, [alertFx("4", "Wind Advisory", .yellow)])
        #expect(RowViewModel(orl).accessibilityLabel
            == "Orlando, Florida, United States: 25\u{00B0}C, Raining until 5:00 PM")
        _ = await m.flush()

        // A model's row without a temperature: the em dash form, then the alerts.
        let fx = try ModelFx("alert-a11y-model", [try miami()])
        let now = fx.clock.wallSeconds
        let service = RowFixedAlerts()
        service.results[try miami().key] = WxAlertsResult(state: .current, source: .nws, alerts: [
            alertFx("b", "Tornado Warning", .red, expiresS: now + 3600),
            alertFx("a", "Flood Watch", .orange, expiresS: now + 3600),
        ], fetchedS: now)
        let model = await fx.start(alerts: service)
        #expect(RowViewModel.rows(of: model).map(\.accessibilityLabel) == [
            "Miami, Florida, United States: \u{2014} \u{00B0}F, No data yet, 2 alerts: Tornado Warning (red), "
                + "Flood Watch (orange)",
        ])
        _ = await model.flush()
    }
}
