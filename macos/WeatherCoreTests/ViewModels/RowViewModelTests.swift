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

    func start() async -> AppModel {
        let m = AppModel(registry: WxRegistry(), storage: storage, clock: clock, online: true,
                         log: { _, _ in })
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
        // test-window.c:1264, 2537, 2538, 2543.
        #expect(row.accessibilityLabel == "Miami, Florida, United States: 77\u{00B0}, Raining until 5:00 PM, Stale")
        row = RowViewModel(place: p, forecast: f, nowS: tNow)
        #expect(row.accessibilityLabel == "Miami, Florida, United States: 77\u{00B0}, Raining until 5:00 PM")
        row = RowViewModel(place: p, forecast: nil, nowS: tNow)
        // test-window.c:1264, 2518, 2519: no marker without data.
        #expect(row.accessibilityLabel == "Miami, Florida, United States: \u{2014}, No data yet")
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
}
