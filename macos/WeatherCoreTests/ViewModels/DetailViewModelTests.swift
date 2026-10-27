// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailViewModelTests.swift - port of the behavioural cases of src/ui/test-detail.c
// (registered at test-detail.c:2539-2626) and of /window/refresh/partial
// (src/ui/test-window.c:1429-1440) at the view-model level. Expected values are the
// C test literals, cited as test-detail.c:LINE. The widget-data cases of
// src/widgets/test-widgets.c are in DetailWidgetDataTests.swift (same suite).
//
// The C pane follows a WxRowItem's "changed" signal; here the item is a value and
// every wx_row_item_set_*() of a C test is a new Item given to show(_:). GTK
// mechanics (widget names and types, the scrolled child, references, dispose,
// handler bookkeeping, mapping and widths) have no analogue; see the U29 debrief.

import Foundation
import Observation
import Synchronization
import Testing
@testable import WeatherCore

@MainActor
@Suite struct DetailViewModelTests {
    // MARK: - Fixtures (test-detail.c:23-211)

    /// NY, AKL (test-detail.c:23-24).
    nonisolated static let ny = "America/New_York"
    nonisolated static let akl = "Pacific/Auckland"
    /// T_H0: 2026-10-12 18:00:00Z (test-detail.c:27).
    nonisolated static let tH0: Int64 = 1_791_828_000
    /// NOW_S (test-detail.c:29).
    nonisolated static let nowS = tH0 + 1800
    /// NY_DAY0: 2026-10-12 00:00 in New York (test-detail.c:31).
    nonisolated static let nyDay0: Int64 = 1_791_777_600
    /// SECOND_SENTENCE, DASH, DOT (test-detail.c:33-35).
    nonisolated static let second = "Check your internet connection; the app tries again automatically."
    nonisolated static let dash = "\u{2014}"
    nonisolated static let dot = " \u{00B7} "
    nonisolated static let deg = "\u{00B0}"
    /// SPEC_HOURS (test-detail.c:102).
    nonisolated static let specHours = 72

    /// place_new (test-detail.c:50-64).
    nonisolated static func place(_ tz: String) throws -> WxPlace {
        if tz == akl {
            return try WxPlace(name: "Auckland", admin1: "Auckland", country: "New Zealand", countryCode: "NZ",
                               lat: -36.85, lon: 174.76, timezone: tz)
        }
        if tz == "UTC" {
            return try WxPlace(name: "Reykjavik", admin1: "", country: "Iceland", countryCode: "IS", lat: 64.14,
                               lon: -21.9, timezone: tz)
        }
        return try WxPlace(name: "New York", admin1: "New York", country: "United States", countryCode: "US",
                           lat: 40.71, lon: -74.0, timezone: tz)
    }

    /// hour_init (test-detail.c:80-96): 25 C, feels 24 C, wind 20, gusts 32, humidity 40 %,
    /// cloud 50 %, dry, partly cloudy, day.
    nonisolated static func hour(_ tS: Int64) -> WxBlendHour {
        WxBlendHour(tS: tS, tempC: 25, feelsC: 24, precipMm: 0, precipMmMax: 0, precipProb: 0, cloudPct: 50,
                    windKmh: 20, gustKmh: 32, humidityPct: 40, tempSpreadC: .nan, nMembers: 2,
                    condition: .partlyCloudy, isDay: true)
    }

    /// Spec (test-detail.c:67-76) with spec_init (test-detail.c:105-120).
    struct Spec {
        var hours: [WxBlendHour]
        var quarters: [WxQuarter] = []
        var days: [WxDay]
        var sources: [WxSourceStatus] = []

        init(_ nHours: Int) {
            hours = (0..<nHours).map { DetailViewModelTests.hour(DetailViewModelTests.tH0 + Int64($0) * 3600) }
            days = [WxDay(startS: DetailViewModelTests.nyDay0, tempMaxC: 27, tempMinC: 16, precipMm: 0,
                          precipProbMax: 10, cloudPct: 50, condition: .partlyCloudy)]
        }

        /// spec_add_source (test-detail.c:130-142).
        mutating func addSource(_ id: String, _ name: String, _ attribution: String, _ url: String,
                                _ state: WxSourceState) throws {
            sources.append(try WxSourceStatus(providerID: id, name: name, attribution: attribution,
                                              attributionURL: url, state: state,
                                              errorCode: state == .failed ? .network : nil,
                                              nMembers: state == .ok ? 1 : 0))
        }

        /// spec_add_day (test-detail.c:144-155).
        mutating func addDay(_ startS: Int64, _ hi: Double, _ lo: Double) {
            days.append(WxDay(startS: startS, tempMaxC: hi, tempMinC: lo, precipMm: 0, precipProbMax: 0,
                              cloudPct: 50, condition: .clear))
        }

        /// spec_wet (test-detail.c:157-164).
        mutating func wet(_ i: Int, _ mm: Double, _ prob: Double) {
            hours[i].precipMm = mm
            hours[i].precipMmMax = mm
            hours[i].precipProb = prob
            hours[i].condition = .rain
        }

        /// spec_forecast (test-detail.c:166-180).
        func forecast(_ place: WxPlace) throws -> WxForecast {
            try WxForecast(place: place, generatedS: DetailViewModelTests.nowS, hours: hours, quarters: quarters,
                           days: days, sources: sources)
        }
    }

    /// item_new (test-detail.c:182-190) with optional state.
    nonisolated static func item(_ place: WxPlace, forecast: WxForecast? = nil, fetchedS: Int64 = 0, loading: Bool = false,
                     stale: Bool = false, offline: Bool = false, units: WxUnits = .imperial,
                     nowS: Int64 = DetailViewModelTests.nowS, error: String? = nil) -> DetailViewModel.Item {
        DetailViewModel.Item(place: place, forecast: forecast, fetchedS: forecast == nil ? 0 : fetchedS,
                             loading: loading, stale: stale, offline: offline, units: units, nowS: nowS,
                             errorText: error)
    }

    /// item_with (test-detail.c:192-201): the forecast of `s`, fetched 2 minutes before "now".
    nonisolated static func item(_ s: Spec, _ tz: String) throws -> DetailViewModel.Item {
        let p = try place(tz)
        return item(p, forecast: try s.forecast(p), fetchedS: nowS - 120)
    }

    /// item_plain (test-detail.c:203-211).
    nonisolated static func plain(_ tz: String) throws -> DetailViewModel.Item {
        try item(Spec(specHours), tz)
    }

    /// The same item with other state (wx_row_item_set_*).
    nonisolated static func with(_ i: DetailViewModel.Item, forecast: WxForecast?? = nil, fetchedS: Int64? = nil,
                     loading: Bool? = nil, stale: Bool? = nil, offline: Bool? = nil, units: WxUnits? = nil,
                     nowS: Int64? = nil, error: String?? = nil, alerts: WxAlertsResult? = nil) -> DetailViewModel.Item {
        let f = forecast ?? i.forecast
        return DetailViewModel.Item(place: i.place, forecast: f, fetchedS: f == nil ? 0 : (fetchedS ?? i.fetchedS),
                                    loading: loading ?? i.loading, stale: stale ?? i.stale,
                                    offline: offline ?? i.offline, units: units ?? i.units, nowS: nowS ?? i.nowS,
                                    errorText: error ?? i.errorText, alerts: alerts ?? i.alerts)
    }

    static func shown(_ item: DetailViewModel.Item?) -> DetailViewModel {
        let vm = DetailViewModel()
        vm.show(item)
        return vm
    }

    static func placeholder(_ vm: DetailViewModel) -> DetailViewModel.Placeholder? {
        if case .placeholder(let p) = vm.page {
            return p
        }
        return nil
    }

    static func page(_ vm: DetailViewModel) -> DetailViewModel.ForecastPage? {
        if case .forecast(let p) = vm.page {
            return p
        }
        return nil
    }

    /// FOOTER_UPDATED / FOOTER_SOURCES (test-detail.c:223-235): the two parts of the footer.
    static func footerParts(_ vm: DetailViewModel) -> (updated: String, sources: String)? {
        guard let footer = page(vm)?.footer, let r = footer.range(of: dot + "Sources: ") else {
            return nil
        }
        return (String(footer[..<r.lowerBound]), String(footer[footer.index(r.lowerBound, offsetBy: dot.count)...]))
    }

    // MARK: - Placeholder

    // C: /detail/placeholder/no-item, /detail/null-arguments (test-detail.c:582-599, test-detail.c:565-576)
    @Test func placeholderNoItem() throws {
        let vm = DetailViewModel()
        let p = try #require(Self.placeholder(vm))  // test-detail.c:586
        #expect(p.title == "Select a place")  // test-detail.c:587
        #expect(p.text == "Pick a place on the left, or add one with the + button.")  // test-detail.c:588-589
        #expect(!p.showsSpinner)  // test-detail.c:590
        vm.show(nil)
        #expect(Self.placeholder(vm)?.title == "Select a place")  // test-detail.c:598
    }

    // C: /detail/placeholder/loading (test-detail.c:601-614)
    @Test func placeholderLoading() throws {
        let vm = Self.shown(Self.item(try Self.place(Self.ny), loading: true))
        let p = try #require(Self.placeholder(vm))  // test-detail.c:609
        #expect(p.title == "Loading forecast\u{2026}")  // test-detail.c:610
        #expect(p.text == "This takes a few seconds.")  // test-detail.c:611
        #expect(p.showsSpinner)  // test-detail.c:612-613
        #expect(DetailViewModel.Placeholder.spinnerAccessibilityLabel == "Loading")  // test-detail.c:546
    }

    // C: /detail/placeholder/error (test-detail.c:616-629)
    @Test func placeholderError() throws {
        let vm = Self.shown(Self.item(try Self.place(Self.ny), error: "Network error"))
        let p = try #require(Self.placeholder(vm))  // test-detail.c:624
        #expect(p.title == "Couldn't load the forecast")  // test-detail.c:625
        #expect(p.text == "Network error. " + Self.second)  // test-detail.c:626
        #expect(!p.showsSpinner)  // test-detail.c:627-628
    }

    // C: /detail/placeholder/error-punctuation (test-detail.c:631-651)
    @Test func placeholderErrorPunctuation() throws {
        let place = try Self.place(Self.ny)
        let cases = [("Timed out.", "Timed out. " + Self.second),  // test-detail.c:642
                     ("Server said no!", "Server said no! " + Self.second),  // test-detail.c:643
                     ("Why?", "Why? " + Self.second),  // test-detail.c:644
                     ("Code 503", "Code 503. " + Self.second)]  // test-detail.c:645
        let vm = DetailViewModel()
        for (error, text) in cases {
            vm.show(Self.item(place, error: error))
            #expect(Self.placeholder(vm)?.text == text, "error \(error)")  // test-detail.c:649
        }
    }

    // C: /detail/placeholder/error-hostile (test-detail.c:653-674)
    @Test func placeholderErrorHostile() throws {
        let place = try Self.place(Self.ny)
        // "<b>boom</b> & \"%s\" %n <a href='x'>\x01\x1b[31m\xff" (test-detail.c:660): the bytes go
        // through the item's sanitising as wx_row_item_set_error does.
        var raw = Array("<b>boom</b> & \"%s\" %n <a href='x'>".utf8)
        raw += [0x01, 0x1B] + Array("[31m".utf8) + [0xFF]
        let error = WxText.sanitize(bytes: raw, maxBytes: AppModel.errorTextMaxBytes)
        let vm = Self.shown(Self.item(place, error: error))
        let text = try #require(Self.placeholder(vm)?.text)
        #expect(text.hasPrefix("<b>boom</b> & \"%s\" %n <a href='x'>"))  // test-detail.c:664
        #expect(text.hasSuffix(". " + Self.second))  // test-detail.c:665
        #expect(!text.unicodeScalars.contains { $0.value == 0x01 || $0.value == 0x1B })
        let big = String(repeating: "x", count: 5000)  // test-detail.c:668
        vm.show(Self.item(place, error: big))
        let long = try #require(Self.placeholder(vm)?.text)
        #expect(long.hasSuffix(". " + Self.second))  // test-detail.c:670
        // WX_ROW_ERROR_MAX_BYTES + strlen(". " SECOND_SENTENCE) (test-detail.c:671-672)
        #expect(long.utf8.count == AppModel.errorTextMaxBytes + (". " + Self.second).utf8.count)
    }

    // C: /detail/placeholder/error-empty-text (test-detail.c:676-693)
    @Test func placeholderErrorEmptyText() throws {
        let place = try Self.place(Self.ny)
        let vm = DetailViewModel()
        vm.show(Self.item(place, error: "\u{01}\u{02}"))
        #expect(Self.placeholder(vm)?.title == "No forecast yet")  // test-detail.c:685
        vm.show(Self.item(place, error: ""))
        #expect(Self.placeholder(vm)?.title == "No forecast yet")  // test-detail.c:687
        #expect(Self.placeholder(vm)?.text == "")  // test-detail.c:688
        vm.show(Self.item(place, error: "x"))
        #expect(Self.placeholder(vm)?.title == "Couldn't load the forecast")  // test-detail.c:690
        vm.show(Self.item(place, error: nil))
        #expect(Self.placeholder(vm)?.title == "No forecast yet")  // test-detail.c:692
    }

    // C: /detail/placeholder/offline-and-none (test-detail.c:695-713)
    @Test func placeholderOfflineAndNone() throws {
        let place = try Self.place(Self.ny)
        let vm = Self.shown(Self.item(place))
        #expect(Self.placeholder(vm)?.title == "No forecast yet")  // test-detail.c:702
        #expect(Self.placeholder(vm)?.text == "")  // test-detail.c:703
        vm.show(Self.item(place, offline: true))
        #expect(Self.placeholder(vm)?.title == "You are offline")  // test-detail.c:705-706
        #expect(Self.placeholder(vm)?.text == "The forecast loads when the network is back.")  // test-detail.c:707-708
        vm.show(Self.item(place, offline: false))
        #expect(Self.placeholder(vm)?.title == "No forecast yet")  // test-detail.c:710
        #expect(Self.placeholder(vm)?.text == "")  // test-detail.c:711
        #expect(Self.placeholder(vm)?.showsSpinner == false)  // test-detail.c:712
    }

    // C: /detail/placeholder/precedence (test-detail.c:715-735)
    @Test func placeholderPrecedence() throws {
        let place = try Self.place(Self.ny)
        let vm = Self.shown(Self.item(place, offline: true, error: "Oops"))
        #expect(Self.placeholder(vm)?.title == "Couldn't load the forecast")  // test-detail.c:724
        vm.show(Self.item(place, loading: true, offline: true, error: "Oops"))
        #expect(Self.placeholder(vm)?.title == "Loading forecast\u{2026}")  // test-detail.c:726
        #expect(Self.placeholder(vm)?.text == "This takes a few seconds.")  // test-detail.c:727
        #expect(Self.placeholder(vm)?.showsSpinner == true)  // test-detail.c:728
        vm.show(Self.item(place, offline: true, error: "Oops"))
        #expect(Self.placeholder(vm)?.title == "Couldn't load the forecast")  // test-detail.c:730
        #expect(Self.placeholder(vm)?.showsSpinner == false)  // test-detail.c:731-732
        vm.show(Self.item(place, offline: true))
        #expect(Self.placeholder(vm)?.title == "You are offline")  // test-detail.c:734
    }

    // C: /detail/spinners (test-detail.c:737-770)
    @Test func spinnersFollowLoadingAndForecast() throws {
        let place = try Self.place(Self.ny)
        let vm = Self.shown(Self.item(place, loading: true))
        #expect(Self.placeholder(vm)?.showsSpinner == true)  // test-detail.c:745
        #expect(Self.page(vm) == nil)  // the refresh spinner is on the hidden page, test-detail.c:746-747
        let f = try Spec(Self.specHours).forecast(place)
        vm.show(Self.item(place, forecast: f, fetchedS: Self.nowS, loading: true))
        let p = try #require(Self.page(vm))  // test-detail.c:754
        #expect(p.showsRefreshing)  // test-detail.c:757-758
        #expect(DetailViewModel.ForecastPage.refreshingAccessibilityLabel == "Refreshing")  // test-detail.c:547
        vm.show(Self.item(place, forecast: f, fetchedS: Self.nowS, loading: false))
        #expect(Self.page(vm)?.showsRefreshing == false)  // test-detail.c:761-762
        vm.show(Self.item(place, loading: true))
        #expect(Self.placeholder(vm)?.showsSpinner == true)  // test-detail.c:767-768
    }

    // C: /detail/page-follows-forecast (test-detail.c:772-793)
    @Test func pageFollowsForecast() throws {
        let place = try Self.place(Self.ny)
        let f = try Spec(Self.specHours).forecast(place)
        let vm = Self.shown(Self.item(place))
        #expect(Self.placeholder(vm) != nil)  // test-detail.c:779
        vm.show(Self.item(place, forecast: f, fetchedS: Self.nowS))
        #expect(Self.page(vm) != nil)  // test-detail.c:785
        vm.show(Self.item(place))
        #expect(Self.placeholder(vm) != nil)  // test-detail.c:787
        vm.show(Self.item(place, forecast: f, fetchedS: Self.nowS))
        #expect(Self.page(vm) != nil)  // test-detail.c:789
        vm.show(nil)
        #expect(Self.placeholder(vm)?.title == "Select a place")  // test-detail.c:791-792
    }

    // C: /detail/item/switch, /detail/item/same-item-refreshes (test-detail.c:821-859, test-detail.c:861-875)
    @Test func switchItems() throws {
        var s = Spec(Self.specHours)
        let a = try Self.item(s, Self.ny)
        s.hours[0].tempC = 10
        s.hours[1].tempC = 10
        let b = try Self.item(s, Self.akl)
        let vm = Self.shown(a)
        #expect(Self.page(vm)?.now.temperature == "77\(Self.deg)F")  // test-detail.c:834
        #expect(Self.page(vm)?.place == "New York, New York, United States")  // test-detail.c:835
        vm.show(b)
        #expect(Self.page(vm)?.now.temperature == "50\(Self.deg)F")  // test-detail.c:839
        #expect(Self.page(vm)?.place == "Auckland, Auckland, New Zealand")  // test-detail.c:840
        vm.show(Self.with(b, units: .metric))
        #expect(Self.page(vm)?.now.temperature == "10\(Self.deg)C")  // test-detail.c:848
        vm.show(nil)
        #expect(Self.placeholder(vm)?.title == "Select a place")  // test-detail.c:852-854
        vm.show(Self.with(a, units: .metric))
        #expect(Self.page(vm)?.now.temperature == "25\(Self.deg)C")  // test-detail.c:857
        vm.show(a)
        vm.show(a)
        #expect(Self.page(vm)?.now.temperature == "77\(Self.deg)F")  // test-detail.c:870
    }

    // MARK: - Now block

    // C: /detail/now/imperial (test-detail.c:1019-1035)
    @Test func nowBlockImperial() throws {
        let p = try #require(Self.page(Self.shown(try Self.plain(Self.ny))))  // test-detail.c:1025
        #expect(p.place == "New York, New York, United States")  // test-detail.c:1026
        #expect(p.now.temperature == "77\(Self.deg)F")  // test-detail.c:1027
        #expect(p.now.condition == "Partly cloudy")  // test-detail.c:1028
        #expect(p.now.feelsLike == "Feels like 75\(Self.deg)")  // test-detail.c:1029
        #expect(p.now.highLow == "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg) (from 2 PM)")  // test-detail.c:1031
        #expect(p.now.wind == "Wind 12 mph, gusts 20 mph")  // test-detail.c:1032 (humidity moved out)
        #expect(p.now.humidity == "Humidity 40%")  // test-detail.c:1032
        #expect(p.now.windDial.speedText == "12" && p.now.windDial.unitText == "mph")
        #expect(p.now.windDial.gustText == "20 mph")
        #expect(p.now.windDial.directionDeg == nil && p.now.windDial.directionText == nil)
        #expect(p.now.windDial.accessibilityLabel == "Wind 12 miles per hour, gusts 20 miles per hour")
        #expect(p.now.gtkIconName == "weather-few-clouds-symbolic")  // test-detail.c:1033
        #expect(p.now.symbolName == WxConditionSymbol.symbolName(.partlyCloudy, isDay: true))
    }

    // C: /detail/now/metric-and-toggle (test-detail.c:1037-1053)
    @Test func nowBlockMetricAndToggle() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(Self.with(item, units: .metric))
        var p = try #require(Self.page(vm))
        #expect(p.now.temperature == "25\(Self.deg)C")  // test-detail.c:1044
        #expect(p.now.feelsLike == "Feels like 24\(Self.deg)")  // test-detail.c:1045
        #expect(p.now.highLow == "High 27\(Self.deg)" + Self.dot + "Low 16\(Self.deg) (from 2 PM)")  // test-detail.c:1046
        #expect(p.now.wind == "Wind 20 km/h, gusts 32 km/h")  // test-detail.c:1047 (humidity moved out)
        #expect(p.now.humidity == "Humidity 40%")
        #expect(p.now.windDial.speedText == "20" && p.now.windDial.unitText == "km/h")
        #expect(p.now.windDial.gustText == "32 km/h")
        vm.show(Self.with(item, units: .imperial))
        p = try #require(Self.page(vm))
        #expect(p.now.temperature == "77\(Self.deg)F")  // test-detail.c:1049
        #expect(p.now.feelsLike == "Feels like 75\(Self.deg)")  // test-detail.c:1050
        #expect(p.now.highLow == "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg) (from 2 PM)")  // test-detail.c:1051
        #expect(p.now.wind == "Wind 12 mph, gusts 20 mph")  // test-detail.c:1052 (humidity moved out)
        #expect(p.now.humidity == "Humidity 40%")
        #expect(p.now.windDial.speedText == "12" && p.now.windDial.unitText == "mph")
    }

    // C: /detail/now/units-reach-widgets (test-detail.c:1055-1073)
    @Test func unitsReachTheLists() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.hours.first?.temp == "77\(Self.deg)")  // test-detail.c:1061-1062
        #expect(Self.page(vm)?.days.first?.high == "81\(Self.deg)")  // test-detail.c:1063-1064
        vm.show(Self.with(item, units: .metric))
        #expect(Self.page(vm)?.hours.first?.temp == "25\(Self.deg)")  // test-detail.c:1066-1067
        #expect(Self.page(vm)?.days.first?.high == "27\(Self.deg)")  // test-detail.c:1068-1069
        vm.show(item)
        #expect(Self.page(vm)?.hours.first?.temp == "77\(Self.deg)")  // test-detail.c:1071-1072
    }

    // C: /detail/now/icon (test-detail.c:1075-1096)
    @Test func iconFollowsConditionAndDaylight() throws {
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].condition = .thunderstorm
        }
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.condition == "Thunderstorm")  // test-detail.c:1086
        #expect(Self.page(vm)?.now.gtkIconName == "weather-storm-symbolic")  // test-detail.c:1087
        let night = try Self.plain(Self.ny)
        vm.show(Self.with(night, nowS: Self.tH0 + 13 * 3600 + 1800))  // 3 AM in New York
        #expect(Self.page(vm)?.now.gtkIconName == "weather-few-clouds-night-symbolic")  // test-detail.c:1093
        vm.show(night)
        #expect(Self.page(vm)?.now.gtkIconName == "weather-few-clouds-symbolic")  // test-detail.c:1095
    }

    // C: /detail/now/gusts (test-detail.c:1098-1126)
    @Test func gustsRules() throws {
        var s = Spec(Self.specHours)
        s.hours[0].gustKmh = 20
        s.hours[1].gustKmh = 20
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.wind == "Wind 12 mph, gusts 12 mph")  // test-detail.c:1107 (humidity moved out)
        #expect(Self.page(vm)?.now.windDial.gustText == "12 mph")  // gust == wind shows (margin 0)
        s.hours[0].gustKmh = 10
        s.hours[1].gustKmh = 10
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.wind == "Wind 12 mph")  // test-detail.c:1112 (humidity moved out)
        #expect(Self.page(vm)?.now.windDial.gustText == nil)
        s.hours[0].gustKmh = .nan
        s.hours[1].gustKmh = .nan
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.wind == "Wind 12 mph")  // test-detail.c:1117 (humidity moved out)
        #expect(Self.page(vm)?.now.windDial.gustText == nil)
        s.hours[0].windKmh = .nan
        s.hours[1].windKmh = .nan
        s.hours[0].gustKmh = 30
        s.hours[1].gustKmh = 30
        s.hours[0].humidityPct = .nan
        s.hours[1].humidityPct = .nan
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.wind == "Wind " + Self.dash)  // test-detail.c:1125 (humidity moved out)
        #expect(Self.page(vm)?.now.humidity == "Humidity " + Self.dash)  // test-detail.c:1125
        #expect(Self.page(vm)?.now.windDial.gustText == nil)
        #expect(Self.page(vm)?.now.windDial.accessibilityLabel == "Wind speed unknown")
    }

    // C: /detail/now/no-current-conditions (test-detail.c:1128-1153)
    @Test func noCurrentConditions() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(Self.with(item, nowS: Self.tH0 + 100 * 3600))
        let p = try #require(Self.page(vm))  // test-detail.c:1135
        #expect(p.now.temperature == Self.dash)  // test-detail.c:1136
        #expect(p.now.condition == "Unknown")  // test-detail.c:1137
        #expect(p.now.iconAccessibilityLabel == "Unknown")
        #expect(p.now.feelsLike == "Feels like " + Self.dash)  // test-detail.c:1138
        #expect(p.now.wind == "Wind " + Self.dash)  // test-detail.c:1139 (humidity moved out)
        #expect(p.now.humidity == "Humidity " + Self.dash)  // test-detail.c:1139
        #expect(p.now.windDial.speedText == Self.dash && !p.now.windDial.isCalm)
        #expect(p.clouds.cover == "Cloud cover " + Self.dash + Self.dot + "Unknown")  // test-detail.c:1140
        #expect(p.clouds.sentence == "Cloud cover unknown")  // test-detail.c:1141
        #expect(p.now.gtkIconName == "dialog-question-symbolic")  // test-detail.c:1142
        #expect(p.now.highLow == nil)  // test-detail.c:1143
        #expect(p.rain.headline == "Rain outlook unavailable")  // test-detail.c:1145
        #expect(p.rain.detail == nil)  // test-detail.c:1146
        #expect(p.hours.isEmpty)  // test-detail.c:1147
        vm.show(item)
        #expect(Self.page(vm)?.now.temperature == "77\(Self.deg)F")  // test-detail.c:1150
        #expect(Self.page(vm)?.now.condition == "Partly cloudy")  // test-detail.c:1151
        #expect(Self.page(vm)?.now.highLow != nil)  // test-detail.c:1152
    }

    // Swift-only: the now block's wind dial value (DetailViewModel.NowWind.make).
    @Test func nowWindUnitsAndRounding() {
        let mph = DetailViewModel.NowWind.make(windKmh: 24.14, gustKmh: .nan, directionDeg: nil, units: .imperial,
                                               gustMarginKmh: 0)
        #expect(mph.speedText == "15" && mph.unitText == "mph" && mph.gustText == nil)
        #expect(mph.accessibilityLabel == "Wind 15 miles per hour")
        let kmh = DetailViewModel.NowWind.make(windKmh: 24.5, gustKmh: 40.23, directionDeg: nil, units: .metric,
                                               gustMarginKmh: 0)
        #expect(kmh.speedText == "25" && kmh.unitText == "km/h" && kmh.gustText == "40 km/h")  // lround: .5 up
        #expect(kmh.accessibilityLabel == "Wind 25 kilometers per hour, gusts 40 kilometers per hour")
        let one = DetailViewModel.NowWind.make(windKmh: 1, gustKmh: .nan, directionDeg: nil, units: .metric,
                                               gustMarginKmh: 0)
        #expect(!one.isCalm && one.accessibilityLabel == "Wind 1 kilometer per hour")
    }

    @Test func nowWindGustMargin() {
        func gust(_ g: Double) -> String? {
            DetailViewModel.NowWind.make(windKmh: 20, gustKmh: g, directionDeg: nil, units: .metric,
                                         gustMarginKmh: 4).gustText
        }
        #expect(gust(24) == "24 km/h")  // exactly wind + margin: shown
        #expect(gust(23.9) == nil)  // just below: hidden
        #expect(gust(.nan) == nil)
        #expect(gust(600) == nil)  // out of range
    }

    @Test func nowWindDirectionCaption() {
        func dial(_ d: Double?) -> DetailViewModel.NowWind {
            DetailViewModel.NowWind.make(windKmh: 24.14, gustKmh: 40.23, directionDeg: d, units: .imperial,
                                         gustMarginKmh: 4)
        }
        #expect(dial(31).directionText == "from NNE 31\(Self.deg)")
        #expect(dial(31).directionDeg == 31)
        #expect(dial(31).accessibilityLabel == "Wind 15 miles per hour from north-northeast, gusts 25 miles per hour")
        #expect(dial(359.6).directionText == "from N 0\(Self.deg)")  // rounded, 360 shown as 0
        #expect(dial(360).directionText == "from N 0\(Self.deg)")
        #expect(dial(360).directionDeg == 0)
        #expect(dial(-90).directionText == "from W 270\(Self.deg)")
        #expect(dial(-90).directionDeg == 270)
        #expect(dial(202.4).accessibilityLabel.contains(" from south-southwest, "))
        #expect(dial(nil).directionText == nil && dial(nil).directionDeg == nil)
        #expect(dial(.nan).directionText == nil && dial(.nan).directionDeg == nil)
        #expect(dial(nil).accessibilityLabel == "Wind 15 miles per hour, gusts 25 miles per hour")
    }

    @Test func nowWindCalmAndUnknown() {
        let calm = DetailViewModel.NowWind.make(windKmh: 0.4, gustKmh: 30, directionDeg: 200, units: .imperial,
                                                gustMarginKmh: 0)
        #expect(calm.isCalm)
        #expect(calm.directionDeg == nil)
        #expect(calm.directionText == nil)  // never a direction caption for a calm wind
        #expect(calm.accessibilityLabel == "Wind calm")
        let edge = DetailViewModel.NowWind.make(windKmh: 0.999, gustKmh: .nan, directionDeg: 90, units: .metric,
                                                gustMarginKmh: 0)
        #expect(edge.isCalm && edge.directionText == nil)
        for kmh in [Double.nan, .infinity, -1, 501] {
            let unknown = DetailViewModel.NowWind.make(windKmh: kmh, gustKmh: .nan, directionDeg: nil,
                                                       units: .imperial, gustMarginKmh: 0)
            #expect(unknown.speedText == Self.dash, "\(kmh)")
            #expect(!unknown.isCalm, "\(kmh)")
            #expect(unknown.accessibilityLabel == "Wind speed unknown", "\(kmh)")
        }
    }

    // C: /detail/now/hours-in-the-past (test-detail.c:1155-1166)
    @Test func hoursInThePast() throws {
        let vm = Self.shown(Self.with(try Self.plain(Self.ny), nowS: Self.tH0 - 3 * 3600))
        #expect(Self.page(vm)?.now.temperature == Self.dash)  // test-detail.c:1162
        #expect(Self.page(vm)?.now.condition == "Unknown")  // test-detail.c:1163
        #expect(Self.page(vm)?.rain.headline == "Rain outlook unavailable")  // test-detail.c:1165
    }

    // C: /detail/now/outside-valid-range (test-detail.c:1168-1184)
    @Test func nowOutsideValidRange() throws {
        let item = try Self.plain(Self.ny)
        let vm = DetailViewModel()
        // { 0, -1, G_MININT64, G_MAXINT64, WX_TIME_MAX_S, WX_TIME_MIN_S - 1 } (test-detail.c:1174)
        for now in [0, -1, Int64.min, Int64.max, WxLimits.timeMaxS, WxLimits.timeMinS - 1] {
            vm.show(Self.with(item, nowS: now))
            let p = try #require(Self.page(vm), "now \(now)")  // test-detail.c:1180
            #expect(p.rain.headline == "Rain outlook unavailable", "now \(now)")  // test-detail.c:1177
            #expect(p.rain.detail == nil, "now \(now)")  // test-detail.c:1178
            #expect(p.now.temperature == Self.dash, "now \(now)")  // test-detail.c:1179
        }
        vm.show(item)
        #expect(Self.page(vm)?.rain.headline == "No rain expected for the next 48 hours")  // test-detail.c:1183
    }

    // MARK: - High / low of today

    // C: /detail/highlow/missing-day (test-detail.c:1190-1209)
    @Test func highlowMissingDay() throws {
        var s = Spec(Self.specHours)
        s.days = []
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.highLow == nil)  // test-detail.c:1199
        s.days = Spec(Self.specHours).days
        s.days[0].startS = Self.nyDay0 - 86400
        s.addDay(Self.nyDay0 + 86400, 20, 10)
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.highLow == nil)  // test-detail.c:1208
    }

    // C: /detail/highlow/unknown-numbers (test-detail.c:1211-1224)
    @Test func highlowUnknownNumbers() throws {
        var s = Spec(Self.specHours)
        s.days[0].tempMaxC = .nan
        s.days[0].tempMinC = .nan
        let vm = Self.shown(try Self.item(s, Self.ny))
        // test-detail.c:1222-1223
        #expect(Self.page(vm)?.now.highLow == "High " + Self.dash + Self.dot + "Low " + Self.dash + " (from 2 PM)")
    }

    // C: /detail/highlow/day-boundaries (test-detail.c:1226-1241)
    @Test func highlowDayBoundaries() throws {
        let item = try Self.plain(Self.ny)
        let vm = DetailViewModel()
        let cases: [(Int64, Bool)] = [(Self.nyDay0 - 1, false),  // test-detail.c:1233-1234
                                      (Self.nyDay0, true),  // test-detail.c:1235-1236
                                      (Self.nyDay0 + 86400 - 1, true),  // test-detail.c:1237-1238
                                      (Self.nyDay0 + 86400, false)]  // test-detail.c:1239-1240
        for (now, shows) in cases {
            vm.show(Self.with(item, nowS: now))
            #expect((Self.page(vm)?.now.highLow != nil) == shows, "now \(now)")
        }
    }

    // C: /detail/highlow/picks-day-of-now (test-detail.c:1243-1256)
    @Test func highlowPicksTheDayOfNow() throws {
        var s = Spec(Self.specHours)
        s.addDay(Self.nyDay0 + 86400, 20, 10)
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.now.highLow == "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg) (from 2 PM)")  // test-detail.c:1253
        vm.show(Self.with(item, nowS: Self.nyDay0 + 86400 + 3600))
        #expect(Self.page(vm)?.now.highLow == "High 68\(Self.deg)" + Self.dot + "Low 50\(Self.deg)")  // test-detail.c:1255
    }

    // C: /detail/highlow/time-zones (test-detail.c:1258-1288)
    @Test func highlowTimeZones() throws {
        var s = Spec(Self.specHours)
        s.addDay(Self.nyDay0 + 86400, 20, 10)
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.highLow == "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg) (from 2 PM)")  // test-detail.c:1272
        vm.show(try Self.item(s, "UTC"))
        #expect(Self.page(vm)?.now.highLow == "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg) (from 6 PM)")  // test-detail.c:1274
        vm.show(try Self.item(s, Self.akl))
        #expect(Self.page(vm)?.now.highLow == nil)  // test-detail.c:1276
        var t = Spec(Self.specHours)
        t.days[0].startS = 1_791_802_800  // test-detail.c:1281
        t.days[0].tempMaxC = 22
        t.days[0].tempMinC = 12
        vm.show(try Self.item(t, Self.akl))
        #expect(Self.page(vm)?.now.highLow == "High 72\(Self.deg)" + Self.dot + "Low 54\(Self.deg) (from 7 AM)")  // test-detail.c:1287
    }

    // C: /detail/highlow/covered-from (test-detail.c:1292-1322)
    @Test func highlowCoveredFrom() throws {
        let hl = "High 81\(Self.deg)" + Self.dot + "Low 61\(Self.deg)"
        let cases: [(Int64, Int64, String)] = [
            (-3600, 1800, hl),  // test-detail.c:1301
            (0, 1800, hl),  // test-detail.c:1302
            (0, 7200, hl),  // test-detail.c:1303
            (3600, 7200, hl + " (from 1 AM)"),  // test-detail.c:1304
            (9 * 3600, 10 * 3600 + 1800, hl + " (from 9 AM)"),  // test-detail.c:1305
            (13 * 3600, 14 * 3600, hl + " (from 1 PM)"),  // test-detail.c:1306
            (22 * 3600, 23 * 3600 + 1800, hl + " (from 10 PM)"),  // test-detail.c:1307
        ]
        let vm = DetailViewModel()
        for (c, (firstOff, nowOff, text)) in cases.enumerated() {
            var s = Spec(Self.specHours)
            for i in s.hours.indices {
                s.hours[i].tS = Self.nyDay0 + firstOff + Int64(i) * 3600
            }
            vm.show(Self.with(try Self.item(s, Self.ny), nowS: Self.nyDay0 + nowOff))
            #expect(Self.page(vm)?.now.highLow == text, "case \(c)")  // test-detail.c:1319-1320
        }
    }

    // MARK: - Rain and clouds

    /// check_rain (test-detail.c:1328-1341).
    static func checkRain(_ setup: (inout Spec) -> Void, _ tz: String, _ headline: String, _ detail: String,
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        var s = Spec(specHours)
        setup(&s)
        let p = try #require(page(shown(try item(s, tz))), sourceLocation: sourceLocation)
        #expect(p.rain.headline == headline, sourceLocation: sourceLocation)  // test-detail.c:1338
        #expect((p.rain.detail ?? "") == detail, sourceLocation: sourceLocation)  // test-detail.c:1339
        #expect((p.rain.detail != nil) == !detail.isEmpty, sourceLocation: sourceLocation)  // test-detail.c:1340
    }

    /// setup_now, setup_now_peak_past, setup_now_unknown_end, setup_soon, setup_later_today,
    /// setup_tomorrow, setup_possible (test-detail.c:1347-1396).
    nonisolated static func setupNow(_ s: inout Spec) {
        s.wet(0, 1.0, 80)
        s.wet(1, 1.0, 80)
        s.wet(2, 1.5, 80)
    }

    nonisolated static func setupNowPeakPast(_ s: inout Spec) {
        s.wet(0, 1.5, 80)
        s.wet(1, 1.0, 80)
    }

    nonisolated static func setupNowUnknownEnd(_ s: inout Spec) {
        for i in s.hours.indices {
            s.wet(i, 3.0, 90)
        }
    }

    nonisolated static func setupSoon(_ s: inout Spec) {
        s.wet(1, 2.0, 70)
        s.wet(2, 1.0, 70)
    }

    nonisolated static func setupLaterToday(_ s: inout Spec) {
        s.wet(6, 4.0, 60)
    }

    nonisolated static func setupTomorrow(_ s: inout Spec) {
        s.wet(20, 8.0, 90)
    }

    nonisolated static func setupPossible(_ s: inout Spec) {
        s.hours[5].precipProb = 60
        s.hours[5].precipMm = 0.05
    }

    // C: /detail/rain/dry (test-detail.c:1397-1401)
    @Test func rainDry() throws {
        try Self.checkRain({ _ in }, Self.ny, "No rain expected for the next 48 hours", "")  // test-detail.c:1400
    }

    // C: /detail/rain/dry-needs-coverage (test-detail.c:1407-1438)
    @Test func rainDryNeedsCoverage() throws {
        let vm = DetailViewModel()
        for size in [24, 48, 49] {  // test-detail.c:1411
            vm.show(try Self.item(Spec(size), Self.ny))
            // test-detail.c:1418-1420
            #expect(Self.page(vm)?.rain.headline
                        == (size == 49 ? "No rain expected for the next 48 hours" : "Rain outlook unavailable"),
                    "size \(size)")
            #expect(Self.page(vm)?.rain.detail == nil, "size \(size)")  // test-detail.c:1421
        }
        var u = Spec(Self.specHours)
        u.hours[40].precipMm = .nan
        vm.show(try Self.item(u, Self.ny))
        #expect(Self.page(vm)?.rain.headline == "Rain outlook unavailable")  // test-detail.c:1429
        var w = Spec(6)
        w.wet(3, 2.0, 80)
        vm.show(try Self.item(w, Self.ny))
        #expect(Self.page(vm)?.rain.headline.hasPrefix("Rain ") == true)  // test-detail.c:1437
    }

    // C: /detail/rain/now, /detail/rain/now-peak-past, /detail/rain/now-unknown-end,
    // /detail/rain/expected-soon, /detail/rain/expected-later-today, /detail/rain/expected-tomorrow,
    // /detail/rain/possible (test-detail.c:1440-1486)
    @Test func rainOutlookTexts() throws {
        try Self.checkRain(Self.setupNow, Self.ny, "Raining now, easing around 5 PM",
                           "Light rain, heaviest around 4 PM.")  // test-detail.c:1443
        try Self.checkRain(Self.setupNowPeakPast, Self.ny, "Raining now, easing around 4 PM",
                           "Rain peaked around 2 PM (light).")  // test-detail.c:1449-1450
        try Self.checkRain(Self.setupNowUnknownEnd, Self.ny, "Raining now, expected to continue for hours",
                           "Rain peaked around 2 PM (moderate).")  // test-detail.c:1456-1457
        try Self.checkRain(Self.setupSoon, Self.ny, "Rain starting in 30 minutes",
                           "Light rain, heaviest around 3 PM. 70% chance of rain.")  // test-detail.c:1463-1464
        try Self.checkRain(Self.setupLaterToday, Self.ny, "Rain expected around 8 PM",
                           "Moderate rain, heaviest around 8 PM. 60% chance of rain.")  // test-detail.c:1470-1471
        try Self.checkRain(Self.setupTomorrow, Self.ny, "Rain expected tomorrow around 10 AM",
                           "Heavy rain, heaviest tomorrow around 10 AM. 90% chance of rain.")  // test-detail.c:1477-1478
        try Self.checkRain(Self.setupPossible, Self.ny, "Showers possible around 7 PM (60% chance)",
                           "No steady rain in the forecast, just a chance.")  // test-detail.c:1484-1485
    }

    // C: /detail/rain/time-zones (test-detail.c:1488-1499)
    @Test func rainTextsFollowTheZone() throws {
        try Self.checkRain(Self.setupNow, "UTC", "Raining now, easing around 9 PM",
                           "Light rain, heaviest around 8 PM.")  // test-detail.c:1491-1492
        try Self.checkRain(Self.setupNow, Self.akl, "Raining now, easing around 10 AM",
                           "Light rain, heaviest around 9 AM.")  // test-detail.c:1493-1494
        try Self.checkRain(Self.setupLaterToday, Self.akl, "Rain expected around 1 PM",
                           "Moderate rain, heaviest around 1 PM. 60% chance of rain.")  // test-detail.c:1495-1496
        try Self.checkRain(Self.setupTomorrow, Self.akl, "Rain expected tomorrow around 3 AM",
                           "Heavy rain, heaviest tomorrow around 3 AM. 90% chance of rain.")  // test-detail.c:1497-1498
    }

    // C: /detail/rain/follows-now (test-detail.c:1501-1516)
    @Test func rainUpdatesWithNow() throws {
        var s = Spec(Self.specHours)
        Self.setupSoon(&s)
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.rain.headline == "Rain starting in 30 minutes")  // test-detail.c:1511
        vm.show(Self.with(item, nowS: Self.nowS + 600))
        #expect(Self.page(vm)?.rain.headline == "Rain starting in 20 minutes")  // test-detail.c:1513
        vm.show(Self.with(item, nowS: Self.nowS + 1800))
        #expect(Self.page(vm)?.rain.headline == "Raining now, easing around 5 PM")  // test-detail.c:1515
    }

    /// add_quarters (test-detail.c:1518-1527): 8 quarters from NOW_S, the first four wet (0.5 mm).
    nonisolated static func addQuarters(_ s: inout Spec, wet: Bool) {
        s.quarters = (0..<8).map { WxQuarter(tS: nowS + Int64($0) * 900, precipMm: wet && $0 < 4 ? 0.5 : 0.0) }
    }

    // C: /detail/rain/nowcast-quarters (test-detail.c:1529-1549)
    @Test func rainWithNowcastQuarters() throws {
        var s = Spec(Self.specHours)
        Self.addQuarters(&s, wet: true)
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.rain.headline == "Raining now, easing around 3:30 PM")  // test-detail.c:1541
        #expect(Self.page(vm)?.rain.detail == "Rain peaked around 2:30 PM (light).")  // test-detail.c:1542
        vm.show(try Self.item(s, "UTC"))
        #expect(Self.page(vm)?.rain.headline == "Raining now, easing around 7:30 PM")  // test-detail.c:1544
        #expect(Self.page(vm)?.rain.detail == "Rain peaked around 6:30 PM (light).")  // test-detail.c:1545
        vm.show(try Self.item(s, Self.akl))
        #expect(Self.page(vm)?.rain.headline == "Raining now, easing around 8:30 AM")  // test-detail.c:1547
        #expect(Self.page(vm)?.rain.detail == "Rain peaked around 7:30 AM (light).")  // test-detail.c:1548
    }

    // C: /detail/chart/views (test-detail.c:1551-1617)
    @Test func chartViews() throws {
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].precipProb = 20
        }
        Self.setupSoon(&s)
        let hourly = try Self.item(s, Self.ny)
        Self.addQuarters(&s, wet: true)
        let quarters = try Self.item(s, Self.ny)
        // no nowcast: the 24 hour chart with its chance line, nothing else (test-detail.c:1567-1577)
        let vm = Self.shown(hourly)
        var rain = try #require(Self.page(vm)?.rain)
        #expect(rain.hourly.hasData && !rain.hourly.barSlots.isEmpty)  // test-detail.c:1571
        #expect(rain.hourly.showsProbabilityLine && !rain.hourly.probabilityRuns.isEmpty)  // test-detail.c:1572
        #expect(!rain.hourly.axisLabels.isEmpty)  // test-detail.c:1570
        #expect(!rain.showsNowcast)  // test-detail.c:1575-1576
        #expect(DetailViewModel.RainCard.hourlyCaption == "Next 24 hours")  // test-detail.c:1577
        // with a nowcast: BOTH charts (test-detail.c:1580-1595)
        vm.show(quarters)
        rain = try #require(Self.page(vm)?.rain)
        #expect(rain.hourly.hasData && !rain.hourly.isQuarters)  // test-detail.c:1585
        #expect(rain.hourly.showsProbabilityLine)  // test-detail.c:1586
        #expect(rain.showsNowcast)  // test-detail.c:1587-1588
        #expect(DetailViewModel.RainCard.nowcastCaption == "Next 2 hours")  // test-detail.c:1589
        #expect(rain.nowcast.isQuarters && !rain.nowcast.barSlots.isEmpty)  // test-detail.c:1591
        #expect(!rain.nowcast.showsProbabilityLine && rain.nowcast.probabilityRuns.isEmpty)  // test-detail.c:1592
        // and back (test-detail.c:1600-1604)
        vm.show(hourly)
        rain = try #require(Self.page(vm)?.rain)
        #expect(rain.hourly.showsProbabilityLine)  // test-detail.c:1602
        #expect(!rain.showsNowcast)  // test-detail.c:1603
        // a nowcast that is over (test-detail.c:1607-1617)
        vm.show(quarters)
        #expect(Self.page(vm)?.rain.showsNowcast == true)  // test-detail.c:1610
        vm.show(Self.with(quarters, nowS: Self.nowS + 3 * 3600))
        rain = try #require(Self.page(vm)?.rain)
        #expect(!rain.showsNowcast)  // test-detail.c:1613
        #expect(rain.hourly.showsProbabilityLine)  // test-detail.c:1615
    }

    // C: /detail/chart/follows-item (test-detail.c:1619-1645)
    @Test func chartFollowsItemChanges() throws {
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].precipProb = 20
        }
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.rain.hourly.probabilityRuns.isEmpty == false)  // test-detail.c:1631
        vm.show(Self.with(item, nowS: Self.tH0 + 200 * 3600))
        let chart = try #require(Self.page(vm)?.rain.hourly)
        #expect(!chart.hasData)  // "No data", test-detail.c:1637-1639
        #expect(chart.barSlots.isEmpty && chart.probabilityRuns.isEmpty)
        #expect(chart.geometry(width: 360, height: 140, percentTopSize: (28, 15), axisLabelWidths: []) == nil)
        vm.show(item)
        #expect(Self.page(vm)?.rain.hourly.probabilityRuns.isEmpty == false)  // test-detail.c:1643
    }

    // C: /detail/chart/cleared-without-forecast (test-detail.c:1647-1666)
    @Test func chartClearedWithoutForecast() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.rain.hourly.hasData == true)  // test-detail.c:1654
        vm.show(Self.with(item, forecast: .some(nil)))
        #expect(Self.page(vm) == nil)  // the page and its charts are gone, test-detail.c:1663-1664
        vm.show(nil)
        #expect(Self.page(vm) == nil)
        #expect(!RainChartData().hasData)  // a chart without forecast: "No data"
    }

    // C: /detail/clouds/texts (test-detail.c:1668-1696)
    @Test func cloudTexts() throws {
        let vm = Self.shown(try Self.plain(Self.ny))
        #expect(Self.page(vm)?.clouds.cover == "Cloud cover 50%" + Self.dot + "Partly cloudy")  // test-detail.c:1674
        #expect(Self.page(vm)?.clouds.sentence == "Partly cloudy for the next 24 hours")  // test-detail.c:1675
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].cloudPct = i < 3 ? 95 : 5
        }
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.clouds.cover == "Cloud cover 95%" + Self.dot + "Overcast")  // test-detail.c:1684
        #expect(Self.page(vm)?.clouds.sentence == "Overcast now, clearing around 5 PM")  // test-detail.c:1685
        var t = Spec(Self.specHours)
        t.hours[0].cloudPct = .nan
        t.hours[1].cloudPct = .nan
        vm.show(try Self.item(t, Self.ny))
        #expect(Self.page(vm)?.clouds.cover == "Cloud cover " + Self.dash + Self.dot + "Unknown")  // test-detail.c:1694
        #expect(Self.page(vm)?.clouds.sentence == "Cloud cover unknown")  // test-detail.c:1695
        #expect(DetailViewModel.CloudCard.title == "Clouds" && DetailViewModel.RainCard.title == "Rain")
    }

    // C: /detail/clouds/time-zones (test-detail.c:1698-1713)
    @Test func cloudSentenceFollowsTheZone() throws {
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].cloudPct = i < 3 ? 95 : 5
        }
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.clouds.sentence == "Overcast now, clearing around 5 PM")  // test-detail.c:1710
        vm.show(try Self.item(s, Self.akl))
        #expect(Self.page(vm)?.clouds.sentence == "Overcast now, clearing around 10 AM")  // test-detail.c:1712
    }

    // C: /detail/lists/hours-and-days (test-detail.c:1719-1741)
    @Test func hoursAndDaysAreFed() throws {
        var s = Spec(100)
        for i in 1..<4 {
            s.addDay(Self.nyDay0 + Int64(i) * 86400, 20, 10)
        }
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.hours.count == DetailViewModel.HourCard.maxCards)  // test-detail.c:1730-1731
        #expect(DetailViewModel.HourCard.maxCards == 48)
        #expect(Self.page(vm)?.days.count == 4)  // test-detail.c:1732
        #expect(Self.page(vm)?.hours.first?.hour == "Now")  // test-detail.c:1733
        #expect(Self.page(vm)?.days.first?.day == "Today")  // test-detail.c:1734
        vm.show(Self.with(item, nowS: Self.tH0 + 90 * 3600))
        #expect(Self.page(vm)?.hours.count == 10)  // test-detail.c:1737
        vm.show(nil)
        #expect(Self.page(vm) == nil)  // no card and no row, test-detail.c:1739-1740
        #expect(DetailViewModel.ForecastPage.hoursTitle == "Next 48 hours")
        #expect(DetailViewModel.ForecastPage.daysTitle == "Next days")
    }

    // C: /detail/badges (test-detail.c:1747-1786)
    @Test func badgesAndTooltips() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(item)
        #expect(DetailViewModel.ForecastPage.offlineBadgeText == "Offline")  // test-detail.c:1755
        #expect(DetailViewModel.ForecastPage.staleBadgeText == "Stale")  // test-detail.c:1756
        #expect(Self.page(vm)?.showsOfflineBadge == false && Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1757-1758
        vm.show(Self.with(item, offline: true))
        #expect(Self.page(vm)?.showsOfflineBadge == true && Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1760-1761
        // test-detail.c:1763-1764
        #expect(DetailViewModel.ForecastPage.offlineBadgeTooltip == "No network connection: showing the last forecast")
        vm.show(Self.with(item, stale: true, offline: true))  // both flags: offline wins
        #expect(Self.page(vm)?.showsOfflineBadge == true && Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1766-1767
        vm.show(Self.with(item, stale: true, offline: false))
        #expect(Self.page(vm)?.showsOfflineBadge == false && Self.page(vm)?.showsStaleBadge == true)  // test-detail.c:1769-1771
        #expect(Self.page(vm)?.staleBadgeTooltip == "The last refresh failed")  // test-detail.c:1773
        vm.show(Self.with(item, stale: true, error: "HTTP 503"))
        #expect(Self.page(vm)?.staleBadgeTooltip == "The last refresh failed: HTTP 503")  // test-detail.c:1776
        vm.show(Self.with(item, stale: true, error: "<b>x</b> & y"))
        #expect(Self.page(vm)?.staleBadgeTooltip == "The last refresh failed: <b>x</b> & y")  // test-detail.c:1778-1779
        vm.show(Self.with(item, stale: true, error: .some(nil)))
        #expect(Self.page(vm)?.staleBadgeTooltip == "The last refresh failed")  // test-detail.c:1781
        vm.show(Self.with(item, stale: false))
        #expect(Self.page(vm)?.showsOfflineBadge == false && Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1783-1784
    }

    // MARK: - Footer

    // C: /detail/footer/updated (test-detail.c:1799-1825)
    @Test func updatedTexts() throws {
        let place = try Self.place(Self.ny)
        let f = try Spec(Self.specHours).forecast(place)
        let n = Self.nowS
        let cases: [(Int64, String)] = [
            (n, "Updated just now"),  // test-detail.c:1810
            (n - 59, "Updated just now"),  // test-detail.c:1811
            (n - 60, "Updated 1 min ago"),  // test-detail.c:1812
            (n - 600, "Updated 10 min ago"),  // test-detail.c:1813
            (n - 3600, "Updated 1 h ago"),  // test-detail.c:1814
            (n - 7200 - 59, "Updated 2 h ago"),  // test-detail.c:1815
            (n - 86400, "Updated 1 day ago"),  // test-detail.c:1816
            (n - 40 * 86400, "Updated over a month ago"),  // test-detail.c:1817
            (n + 100, "Updated just now"),  // test-detail.c:1818
            (n + 100 * 86400, "Updated just now"),  // test-detail.c:1819
            (-5, "Updated over a month ago"),  // test-detail.c:1820
            (0, "Updated over a month ago"),  // test-detail.c:1821
            (Int64.min, "Updated over a month ago"),  // test-detail.c:1822
            (Int64.max, "Updated just now"),  // test-detail.c:1823
            (n - 120, "Updated 2 min ago"),  // test-detail.c:1824
        ]
        let vm = DetailViewModel()
        for (fetched, text) in cases {
            vm.show(Self.item(place, forecast: f, fetchedS: fetched))
            #expect(Self.footerParts(vm)?.updated == text, "fetched \(fetched)")  // test-detail.c:1796
        }
    }

    // C: /detail/footer/updated-extreme-now (test-detail.c:1827-1850)
    @Test func updatedExtremeNow() throws {
        let place = try Self.place(Self.ny)
        let f = try Spec(Self.specHours).forecast(place)
        let cases: [(Int64, Int64, String)] = [
            (-1, Int64.max, "Updated over a month ago"),  // test-detail.c:1838-1840
            (Int64.min, Int64.max, "Updated over a month ago"),  // test-detail.c:1841-1842
            (Int64.min, Int64.min, "Updated just now"),  // test-detail.c:1843-1844
            (Int64.max, Int64.min, "Updated just now"),  // test-detail.c:1845-1846
            (Int64.max, Int64.max, "Updated just now"),  // test-detail.c:1847-1848
        ]
        let vm = DetailViewModel()
        for (fetched, now, text) in cases {
            vm.show(Self.item(place, forecast: f, fetchedS: fetched, nowS: now))
            #expect(Self.footerParts(vm)?.updated == text, "fetched \(fetched) now \(now)")
        }
        #expect(Self.page(vm) != nil)  // test-detail.c:1849
        #expect(DetailViewModel.ageS(Int64.max, -1) == Int64.max)  // age_s: the difference does not fit
    }

    // C: /detail/footer/updated-no-clock (test-detail.c:1852-1866)
    @Test func updatedFollowsNowOnly() throws {
        let item = try Self.plain(Self.ny)
        let far: Int64 = 2_000_000_000  // test-detail.c:1860
        let vm = Self.shown(Self.with(item, fetchedS: far - 300, nowS: far))
        #expect(Self.footerParts(vm)?.updated == "Updated 5 min ago")  // test-detail.c:1863
        vm.show(Self.with(item, fetchedS: far - 300, nowS: far + 3600))
        #expect(Self.footerParts(vm)?.updated == "Updated 1 h ago")  // test-detail.c:1865
    }

    // C: /detail/footer/sources (test-detail.c:1868-1898)
    @Test func sourcesList() throws {
        let none = try Self.plain(Self.ny)
        let vm = Self.shown(none)
        #expect(Self.footerParts(vm)?.sources == "Sources: none")  // test-detail.c:1874
        #expect(Self.page(vm)?.attribution.isEmpty == true)  // test-detail.c:1876
        #expect(Self.page(vm)?.partial == nil)  // test-detail.c:1877
        var s = Spec(Self.specHours)
        try s.addSource("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/", .ok)
        try s.addSource("nws", "National Weather Service", "Source: NOAA/National Weather Service",
                        "https://www.weather.gov/", .failed)
        try s.addSource("met-no", "MET Norway", "Data from MET Norway", "https://api.met.no/", .ok)
        try s.addSource("other", "Skipped One", "never shown", "https://example.org/", .skipped)
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.footerParts(vm)?.sources == "Sources: Open-Meteo, MET Norway")  // test-detail.c:1892
        #expect(Self.page(vm)?.partial == "Not available right now: National Weather Service")  // test-detail.c:1893-1894
        vm.show(none)
        #expect(Self.footerParts(vm)?.sources == "Sources: none")  // test-detail.c:1896
        #expect(Self.page(vm)?.partial == nil)  // test-detail.c:1897
    }

    // C: /detail/footer/sources-failed-or-skipped (test-detail.c:1900-1916)
    @Test func sourcesOnlyFailedOrSkipped() throws {
        var s = Spec(Self.specHours)
        try s.addSource("a", "Alpha", "Alpha data", "https://a.example/", .failed)
        try s.addSource("b", "Beta", "Beta data", "https://b.example/", .failed)
        try s.addSource("c", "Gamma", "Gamma data", "https://c.example/", .skipped)
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.footerParts(vm)?.sources == "Sources: none")  // test-detail.c:1912
        #expect(Self.page(vm)?.partial == "Not available right now: Alpha, Beta")  // test-detail.c:1913
        #expect(Self.page(vm)?.attribution.isEmpty == true)  // test-detail.c:1914
        #expect(Self.page(vm)?.attributionMarkup == "")  // test-detail.c:1915
    }

    // C: /detail/footer/one-row-with-badges (test-detail.c:1920-1954)
    @Test func footerIsOneRowWithTheBadges() throws {
        var s = Spec(Self.specHours)
        try s.addSource("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/", .ok)
        try s.addSource("met-no", "MET Norway", "Data from MET Norway", "https://api.met.no/", .ok)
        let far: Int64 = 2_000_000_000
        let item = Self.with(try Self.item(s, Self.ny), fetchedS: far - 300, nowS: far)
        let vm = Self.shown(item)
        // test-detail.c:1936-1937
        #expect(Self.page(vm)?.footer == "Updated 5 min ago \u{00B7} Sources: Open-Meteo, MET Norway")
        // the order of the footer row and the lines below it (test-detail.c:1938-1943)
        let order = DetailViewModel.ForecastPage.sections
        let header = try #require(order.firstIndex(of: .header))
        let footer = try #require(order.firstIndex(of: .footer))
        #expect(header < footer)
        #expect(order.firstIndex(of: .attribution) == footer + 1)
        #expect(Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1948
        vm.show(Self.with(item, stale: true))
        #expect(Self.page(vm)?.showsStaleBadge == true)  // test-detail.c:1950
        vm.show(Self.with(item, stale: true, offline: true))
        #expect(Self.page(vm)?.showsOfflineBadge == true)  // test-detail.c:1952
        #expect(Self.page(vm)?.showsStaleBadge == false)  // test-detail.c:1953
    }

    // C: /detail/footer/source-without-name (test-detail.c:1956-1969)
    @Test func sourceWithoutNameUsesItsID() throws {
        var s = Spec(Self.specHours)
        try s.addSource("open-meteo", "", "Weather data", "", .ok)
        try s.addSource("nws", "\u{01}\u{02}", "", "", .failed)
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.footerParts(vm)?.sources == "Sources: open-meteo")  // test-detail.c:1967
        #expect(Self.page(vm)?.partial == "Not available right now: nws")  // test-detail.c:1968
    }

    // C: /detail/footer/attribution-link (test-detail.c:1971-1997)
    @Test func attributionLink() throws {
        var s = Spec(Self.specHours)
        try s.addSource("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/", .ok)
        try s.addSource("nws", "NWS", "Source: NOAA/National Weather Service", "https://www.weather.gov/", .failed)
        try s.addSource("met-no", "MET Norway", "Data from MET Norway", "", .ok)
        try s.addSource("q", "Query", "Has a query", "https://example.org/a?x=1&y=2&z='3'", .ok)
        let p = try #require(Self.page(Self.shown(try Self.item(s, Self.ny))))
        #expect(!p.attribution.isEmpty)  // test-detail.c:1989
        // test-detail.c:1990-1994
        #expect(p.attributionMarkup
                    == "<a href=\"https://open-meteo.com/\">Weather data by Open-Meteo.com</a>" + Self.dot
                    + "Data from MET Norway" + Self.dot
                    + "<a href=\"https://example.org/a?x=1&amp;y=2&amp;z=&apos;3&apos;\">Has a query</a>")
        // test-detail.c:1995-1996
        #expect(p.attributionText == "Weather data by Open-Meteo.com" + Self.dot + "Data from MET Norway" + Self.dot
                    + "Has a query")
        #expect(p.attribution.map(\.url) == ["https://open-meteo.com/", nil, "https://example.org/a?x=1&y=2&z='3'"])
    }

    /// item_with_hand_built_source (test-detail.c:2023-2042): the C test overwrites the URL of a
    /// built forecast; a WxSourceStatus cannot hold a refused URL, so the attribution builder is
    /// fed the raw source text directly.
    nonisolated static func handBuilt(_ url: [UInt8]) -> [(entry: DetailViewModel.AttributionEntry, markup: String)] {
        DetailViewModel.attributionEntries([DetailViewModel.SourceText(state: .ok, attribution: Array("Weather data".utf8),
                                                                       url: url)])
    }

    // C: /detail/footer/attribution-hostile-urls (test-detail.c:2040-2076)
    @Test func attributionRejectsHostileURLs() {
        let pad = String(repeating: "a", count: WxLimits.sourceURLMax + 1 - "https://e.example/".utf8.count)
        let tooLong = Array(("https://e.example/" + pad).utf8)  // test-detail.c:2047-2048
        #expect(tooLong.count == WxLimits.sourceURLMax + 1)  // test-detail.c:2046
        let bad: [[UInt8]] = [  // test-detail.c:2047-2066
            Array("javascript:alert(1)".utf8), Array("http://open-meteo.com/".utf8),
            Array("HTTPS://open-meteo.com/".utf8), Array("ftp://open-meteo.com/".utf8),
            Array("file:///etc/passwd".utf8), Array("//open-meteo.com/".utf8), Array("open-meteo.com".utf8),
            Array("https://".utf8), Array("https://open meteo.com/".utf8), Array("https://open-meteo.com/a b".utf8),
            Array("https://open-meteo.com/".utf8) + [0x09, 0x78], Array("https://open-meteo.com/".utf8) + [0x0A, 0x78],
            Array("https://open-meteo.com/".utf8) + [0x7F], Array("https://open-meteo.com/<b>".utf8),
            Array("https://open-meteo.com/>x".utf8), Array("https://open-meteo.com/\"onclick=\"x".utf8),
            Array("https://open-meteo.com/".utf8) + [0xFF], Array(" https://open-meteo.com/".utf8), tooLong,
        ]
        for (i, url) in bad.enumerated() {
            let entries = Self.handBuilt(url)
            #expect(entries.map(\.markup) == ["Weather data"], "URL \(i) was linked")  // test-detail.c:2071-2072
            #expect(entries.map(\.entry.text) == ["Weather data"], "URL \(i)")  // test-detail.c:2073-2074
            #expect(entries.first?.entry.url == nil, "URL \(i)")
        }
    }

    // C: /detail/footer/attribution-url-length (test-detail.c:2078-2090)
    @Test func attributionURLLengthLimit() {
        let pad = String(repeating: "a", count: WxLimits.sourceURLMax - "https://e.example/".utf8.count)
        let url = "https://e.example/" + pad
        #expect(url.utf8.count == WxLimits.sourceURLMax)  // test-detail.c:2084
        let entries = Self.handBuilt(Array(url.utf8))
        #expect(entries.map(\.markup) == ["<a href=\"" + url + "\">Weather data</a>"])  // test-detail.c:2087-2088
        #expect(entries.map(\.entry.text) == ["Weather data"])  // test-detail.c:2089
    }

    // C: /detail/footer/attribution-escapes-link (test-detail.c:2092-2100)
    @Test func attributionHandBuiltLinkIsEscaped() {
        let entries = Self.handBuilt(Array("https://e.example/?a=1&b=2".utf8))
        #expect(entries.map(\.markup) == ["<a href=\"https://e.example/?a=1&amp;b=2\">Weather data</a>"])  // test-detail.c:2098-2099
    }

    // C: /detail/footer/attribution-without-text (test-detail.c:2102-2123)
    @Test func attributionWithoutTextIsSkipped() throws {
        var s = Spec(Self.specHours)
        try s.addSource("a", "Alpha", "", "https://a.example/", .ok)
        let onlyEmpty = try Self.item(s, Self.ny)
        try s.addSource("b", "Beta", "Beta data", "https://b.example/", .ok)
        try s.addSource("c", "Gamma", "\u{01}", "https://c.example/", .ok)
        let mixed = try Self.item(s, Self.ny)
        let vm = Self.shown(onlyEmpty)
        #expect(Self.footerParts(vm)?.sources == "Sources: Alpha")  // test-detail.c:2115
        #expect(Self.page(vm)?.attribution.isEmpty == true)  // test-detail.c:2116
        #expect(Self.page(vm)?.attributionMarkup == "")  // test-detail.c:2117
        vm.show(mixed)
        #expect(Self.page(vm)?.attribution.isEmpty == false)  // test-detail.c:2119
        #expect(Self.footerParts(vm)?.sources == "Sources: Alpha, Beta, Gamma")  // test-detail.c:2120
        #expect(Self.page(vm)?.attributionMarkup == "<a href=\"https://b.example/\">Beta data</a>")  // test-detail.c:2121-2122
    }

    // C: /detail/item/not-mutated (test-detail.c:2132-2161)
    @Test func itemIsNotMutated() throws {
        let item = Self.with(try Self.plain(Self.ny), loading: true, stale: true, offline: true, units: .metric,
                             error: "Oops")
        let vm = Self.shown(item)
        vm.show(item)
        vm.show(nil)
        // the item is a value: every field is what it was (test-detail.c:2152-2160)
        #expect(item.fetchedS == Self.nowS - 120)
        #expect(item.nowS == Self.nowS)
        #expect(item.loading && item.stale && item.offline)
        #expect(item.errorText == "Oops")  // test-detail.c:2159
        #expect(item.units == .metric)
    }

    // C: /detail/footer/hostile-text (test-detail.c:2163-2186)
    @Test func hostileNamesAndAttributionsAreLiteral() throws {
        var s = Spec(Self.specHours)
        try s.addSource("a", "<b>&amp;\"", "<i>x</i> & \"<a href='y'>", "https://a.example/", .ok)
        try s.addSource("b", "%s%n</span>", "&#x41; &lt;", "", .failed)
        try s.addSource("c", "<big>", "&lt;/a>", "", .ok)
        let p = try #require(Self.page(Self.shown(try Self.item(s, Self.ny))))
        #expect(p.footer.hasSuffix("Sources: <b>&amp;\", <big>"))  // test-detail.c:2179
        #expect(p.partial == "Not available right now: %s%n</span>")  // test-detail.c:2180
        #expect(p.attributionText == "<i>x</i> & \"<a href='y'>" + Self.dot + "&lt;/a>")  // test-detail.c:2181-2182
        // test-detail.c:2183-2185
        #expect(p.attributionMarkup == "<a href=\"https://a.example/\">&lt;i&gt;x&lt;/i&gt; &amp; &quot;&lt;a "
                    + "href=&apos;y&apos;&gt;</a>" + Self.dot + "&amp;lt;/a&gt;")
    }

    // C: /detail/footer/invalid-utf8 (test-detail.c:2188-2203)
    @Test func invalidUTF8InNames() throws {
        var s = Spec(Self.specHours)
        // "bad\xff\xfe" "name\x01" / "attr\xc3(\x1b[1m" (test-detail.c:2193-2194) as raw bytes
        let name = Array("bad".utf8) + [0xFF, 0xFE] + Array("name".utf8) + [0x01]
        let attribution = Array("attr".utf8) + [0xC3] + Array("(".utf8) + [0x1B] + Array("[1m".utf8)
        s.sources = [try WxSourceStatus(providerIDBytes: Array("open-meteo".utf8), nameBytes: name,
                                        attributionBytes: attribution,
                                        attributionURLBytes: Array("https://open-meteo.com/".utf8),
                                        stateOrdinal: WxSourceState.ok.rawValue, errorCodeOrdinal: -1, nMembers: 1)]
        let vm = Self.shown(try Self.item(s, Self.ny))
        let sources = try #require(Self.footerParts(vm)?.sources)
        #expect(sources.hasPrefix("Sources: bad"))  // test-detail.c:2196
        #expect(!sources.unicodeScalars.contains { $0.value == 0x01 })  // test-detail.c:2198
        let text = try #require(Self.page(vm)?.attributionText)
        #expect(text.hasPrefix("attr"))  // test-detail.c:2201
        #expect(!text.unicodeScalars.contains { $0.value == 0x1B })
        #expect(Self.page(vm)?.attribution.isEmpty == false)  // test-detail.c:2202
    }

    // C: /detail/footer/sixteen-sources (test-detail.c:2205-2238)
    @Test func sixteenSources() throws {
        var s = Spec(Self.specHours)
        var names = "Sources: "
        var partial = "Not available right now: "
        var attribution = ""
        var ok = 0, failed = 0
        for i in 0..<WxLimits.forecastMaxSources {  // test-detail.c:2216-2230
            let state: WxSourceState = i % 3 == 0 ? .failed : (i % 3 == 1 ? .ok : .skipped)
            try s.addSource("src\(i)", "Source \(i)", "Data \(i)", "https://s\(i).example/", state)
            if state == .ok {
                names += (ok > 0 ? ", " : "") + "Source \(i)"
                ok += 1
                attribution += (ok > 1 ? Self.dot : "") + "<a href=\"https://s\(i).example/\">Data \(i)</a>"
            } else if state == .failed {
                partial += (failed > 0 ? ", " : "") + "Source \(i)"
                failed += 1
            }
        }
        let vm = Self.shown(try Self.item(s, Self.ny))
        #expect(Self.footerParts(vm)?.sources == names)  // test-detail.c:2232
        #expect(Self.page(vm)?.partial == partial)  // test-detail.c:2233
        #expect(Self.page(vm)?.attributionMarkup == attribution)  // test-detail.c:2234
    }

    // C: /detail/footer/long-names (test-detail.c:2240-2258)
    @Test func longNamesAreBounded() throws {
        let big = String(repeating: "N", count: WxLimits.sourceTextMax)
        var s = Spec(Self.specHours)
        for i in 0..<WxLimits.forecastMaxSources {
            try s.addSource("src\(i)", big, big, "https://s.example/", i % 2 == 1 ? .ok : .failed)
        }
        let vm = Self.shown(try Self.item(s, Self.ny))
        // strlen("Sources: ") + 8 * WX_SOURCE_TEXT_MAX + 7 * strlen(", ") (test-detail.c:2254-2255)
        #expect(Self.footerParts(vm)?.sources.utf8.count
                    == "Sources: ".utf8.count + 8 * WxLimits.sourceTextMax + 7 * ", ".utf8.count)
    }

    // MARK: - Compare before set

    /// Counts the observer notifications of `vm.page` while `body` runs.
    static func notifications(_ vm: DetailViewModel, _ body: () -> Void) -> Int {
        let count = Mutex(0)
        func track() {
            withObservationTracking {
                _ = vm.page
            } onChange: {
                count.withLock { $0 += 1 }
            }
        }
        track()
        body()
        return count.withLock { $0 }
    }

    // C: /detail/compare/unchanged-refresh (test-detail.c:2297-2333)
    @Test func unchangedRefreshChangesNothing() throws {
        var s = Spec(Self.specHours)
        Self.setupSoon(&s)
        try s.addSource("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/", .ok)
        try s.addSource("nws", "NWS", "NWS data", "", .failed)
        let item = Self.with(try Self.item(s, Self.ny), loading: true, stale: true, error: "HTTP 503")
        let vm = Self.shown(item)
        let markupBefore = try #require(Self.page(vm)?.attributionMarkup)
        #expect(markupBefore != "")  // test-detail.c:2318
        let revision = vm.revision
        // the unit toggle does change things (test-detail.c:2330)
        let afterToggle = Self.notifications(vm) {
            vm.show(Self.with(item, units: .metric))
            vm.show(item)
        }
        #expect(afterToggle > 0)
        #expect(vm.revision == revision + 2)
        // a refresh without any change of what is shown notifies nothing (test-detail.c:2324-2327)
        let unchanged = Self.notifications(vm) {
            vm.show(item)
            vm.show(item)
        }
        #expect(unchanged == 0)
        #expect(vm.revision == revision + 2)
        #expect(Self.page(vm)?.attributionMarkup == markupBefore)  // test-detail.c:2328
    }

    // C: /detail/compare/irrelevant-change (test-detail.c:2335-2359)
    @Test func irrelevantChangeChangesNothing() throws {
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(item)
        let temp = Self.page(vm)?.now.temperature
        let count = Self.notifications(vm) {
            vm.show(Self.with(item, nowS: Self.nowS + 1))
        }
        #expect(count == 0)  // test-detail.c:2353
        #expect(Self.page(vm)?.now.temperature == temp)  // test-detail.c:2354
    }

    // C: /detail/compare/attribution-cache (test-detail.c:2361-2393)
    @Test func attributionMarkupCache() throws {
        var s = Spec(Self.specHours)
        try s.addSource("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com", "https://open-meteo.com/", .ok)
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        let before = Self.page(vm)?.attributionMarkup
        vm.show(Self.with(item, loading: true))
        vm.show(Self.with(item, loading: false))
        vm.show(Self.with(item, nowS: Self.nowS + 60))
        #expect(Self.page(vm)?.attributionMarkup == before)  // test-detail.c:2380
        vm.show(try Self.plain(Self.ny))
        #expect(Self.page(vm)?.attribution.isEmpty == true)  // test-detail.c:2386
        #expect(Self.page(vm)?.attributionMarkup == "")  // test-detail.c:2387
        vm.show(item)
        #expect(Self.page(vm)?.attribution.isEmpty == false)  // test-detail.c:2389
        // test-detail.c:2390-2391
        #expect(Self.page(vm)?.attributionMarkup == "<a href=\"https://open-meteo.com/\">Weather data by Open-Meteo.com</a>")
    }

    // C: none - the station networks' credits appended to the line (executor-added)
    @Test func stationCreditsAreAppendedOnce() throws {
        var s = Spec(Self.specHours)
        try s.addSource("bright-sky", "Bright Sky", BrightSkyProvider.attributionText, BrightSkyProvider.attributionLink, .ok)
        let p = try #require(Self.page(Self.shown(try Self.item(s, Self.ny))))
        let fused = p.addingAttribution(WxStationNetworks.credits(for: [.dwdSYNOP, .metar]))
        // the DWD credit is already the provider's: only the METAR credit and the CC BY note are new
        #expect(fused.attribution.map(\.text) == [
            BrightSkyProvider.attributionText, "Source: NOAA Aviation Weather Center",
            "Station data CC BY 4.0, quality-checked and blended",
        ])
        #expect(fused.attributionMarkup == p.attributionMarkup
            + " \u{00B7} <a href=\"https://aviationweather.gov/\">Source: NOAA Aviation Weather Center</a>"
            + " \u{00B7} <a href=\"https://creativecommons.org/licenses/by/4.0/\">Station data CC BY 4.0, quality-checked and blended</a>")
        #expect(fused.now == p.now && fused.footer == p.footer && fused.days == p.days)
        #expect(p.addingAttribution([]) == p)
        #expect(fused.addingAttribution(WxStationNetworks.credits(for: [.metar])) == fused)
    }

    /// The page never makes up an air-quality value: the card shows the dash until a monitor or
    /// the CAMS forecast answers (LiveStationSnapshot).
    @Test func airQualityIsNeverEstimated() throws {
        let item = try Self.plain(Self.ny)
        #expect(Self.page(Self.shown(item))?.airQuality == .unavailable(offline: false))
        #expect(Self.page(Self.shown(Self.with(item, offline: true)))?.airQuality == .unavailable(offline: true))
    }

    // MARK: - Accessibility, big data, all states

    // C: /detail/accessible-labels, /detail/accessibility (test-detail.c:542-563, test-detail.c:514-531)
    @Test func accessibleLabels() throws {
        #expect(DetailViewModel.Placeholder.spinnerAccessibilityLabel == "Loading")  // test-detail.c:546
        #expect(DetailViewModel.ForecastPage.refreshingAccessibilityLabel == "Refreshing")  // test-detail.c:547
        #expect(RainChartData.accessibilityLabel == "Rain chart")  // wx-rain-chart.c:721-722
        let item = try Self.plain(Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.now.iconAccessibilityLabel == "Partly cloudy")  // test-detail.c:550
        vm.show(Self.with(item, nowS: Self.tH0 + 100 * 3600))
        #expect(Self.page(vm)?.now.iconAccessibilityLabel == "Unknown")  // test-detail.c:554
        var s = Spec(Self.specHours)
        for i in s.hours.indices {
            s.hours[i].condition = .thunderstorm
        }
        vm.show(try Self.item(s, Self.ny))
        #expect(Self.page(vm)?.now.iconAccessibilityLabel == "Thunderstorm")  // test-detail.c:562
        // the section order of the forecast page (wx-detail.c:939-1069, ui-widgets.md:28)
        #expect(DetailViewModel.ForecastPage.sections
                    == [.header, .now, .rain, .clouds, .hours, .days, .footer, .attribution, .partial])
    }

    // C: /detail/huge-forecast (test-detail.c:2399-2433)
    @Test func hugeForecast() throws {
        var s = Spec(WxLimits.forecastMaxHours)
        for i in s.hours.indices {
            s.wet(i, i % 5 == 0 ? 0 : 1.5, 70)
        }
        s.quarters = (0..<WxLimits.forecastMaxQuarters).map {
            WxQuarter(tS: Self.nowS - 900 * 100 + Int64($0) * 900, precipMm: $0 % 3 != 0 ? 0.2 : 0)
        }
        for i in 1..<WxLimits.forecastMaxDays {
            s.addDay(Self.nyDay0 + Int64(i) * 86400, 20, 10)
        }
        for i in 0..<WxLimits.forecastMaxSources {
            try s.addSource("src\(i)", "src\(i)", "src\(i)", "https://s.example/", i % 2 == 1 ? .ok : .failed)
        }
        let item = try Self.item(s, Self.ny)
        let vm = Self.shown(item)
        #expect(Self.page(vm)?.hours.count == 48)  // test-detail.c:2424
        #expect(Self.page(vm)?.days.count == DetailViewModel.DayRow.maxRows)  // test-detail.c:2425-2426
        #expect(Self.page(vm)?.now.temperature == "77\(Self.deg)F")  // test-detail.c:2427
        vm.show(Self.with(item, units: .metric, nowS: Self.nowS + 7 * 3600))
        #expect(Self.page(vm)?.now.temperature == "25\(Self.deg)C")  // test-detail.c:2430
    }

    // C: /detail/window/all-states (test-detail.c:2435-2474): what is visible in each state
    @Test func windowLayoutAllStates() throws {
        let place = try Self.place(Self.ny)
        let full = Self.with(try Self.plain(Self.ny), loading: true, stale: true, offline: true)
        let vm = DetailViewModel()
        #expect(Self.placeholder(vm)?.showsSpinner == false)  // test-detail.c:2454
        for item in [Self.item(place, loading: true), Self.item(place, error: "Network error"),
                     Self.item(place, offline: true), full] {
            vm.show(item)
        }
        vm.show(nil)
        vm.show(Self.item(place, loading: true))
        #expect(Self.placeholder(vm)?.showsSpinner == true)  // test-detail.c:2463
        vm.show(full)
        let p = try #require(Self.page(vm))  // test-detail.c:2466
        #expect(p.showsOfflineBadge)  // test-detail.c:2467
        #expect(!p.showsStaleBadge)  // test-detail.c:2468
        #expect(p.showsRefreshing)  // test-detail.c:2469
        #expect(!p.days.isEmpty)  // test-detail.c:2472
    }

    // C: /detail/window/hostile-data (test-detail.c:2476-2501)
    @Test func windowHostileData() throws {
        let entries = DetailViewModel.attributionEntries([DetailViewModel.SourceText(
            state: .ok, attribution: Array("<i>x</i> & \"".utf8), url: Array("https://a.example/?q=\"><script>".utf8))])
        #expect(entries.map(\.entry.text) == ["<i>x</i> & \""])  // test-detail.c:2497
        #expect(entries.map(\.markup) == ["&lt;i&gt;x&lt;/i&gt; &amp; &quot;"])  // test-detail.c:2498-2499
        let item = Self.with(try Self.plain(Self.ny), stale: true, error: "<span foreground='red'>&</span>")
        let p = try #require(Self.page(Self.shown(item)))
        #expect(p.showsStaleBadge)  // test-detail.c:2494
        #expect(p.staleBadgeTooltip == "The last refresh failed: <span foreground='red'>&</span>")  // test-detail.c:2495-2496
    }

    // MARK: - Per-place units (U50)

    /// A loaded model whose default units are `defaultUnits`, holding New York saved with
    /// `placeUnits` (AppModel.add(_:units:)) and refreshed from one fake source (24 degC, feels
    /// 26 degC, wind 12 km/h, gusts 20 km/h, 1.5 mm in each of the first 6 hours), and the
    /// detail page of its item (DetailViewModel.show(place:)). `dir` keeps the files alive.
    private func unitsPage(_ label: String, defaultUnits: WxUnits, placeUnits: WxUnits) async throws
        -> (dir: TemporaryDirectory, model: AppModel, item: AppModel.Place, page: DetailViewModel.ForecastPage)
    {
        let dir = try TemporaryDirectory("u50-detail-\(label)")
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let clock = ManualClock()
        let registry = WxRegistry()
        let fake = FakeProvider(id: "fake-a")
        let now = clock.wallSeconds
        var m = try WxMember(sourceID: "fake-a", modelID: "m1", fetchedS: now)
        for i in -2..<72 {
            let wet = i >= 0 && i < 6
            _ = m.addHour(WxHour(tS: now - now % 3600 + Int64(i) * 3600, tempC: 24, feelsC: 26,
                                 precipMm: wet ? 1.5 : 0, precipProb: wet ? 90 : 5, cloudPct: 40, windKmh: 12,
                                 gustKmh: 20, humidityPct: 70))
        }
        fake.addMember(m)
        try registry.addProvider(fake)
        let model = AppModel(registry: registry, storage: storage, clock: clock, online: true, log: { _, _ in })
        await model.load()
        model.setDefaultUnits(defaultUnits)
        #expect(model.add(try Self.place(Self.ny), units: placeUnits) == .added)
        model.setVisible(true)
        let deadline = ContinuousClock.now + .seconds(30)
        while !(model.selectedPlace?.forecast != nil && model.selectedPlace?.loading == false) {
            if ContinuousClock.now > deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let item = try #require(model.selectedPlace)
        #expect(model.defaultUnits == defaultUnits && item.units == placeUnits)
        let vm = DetailViewModel()
        vm.show(place: item)
        return (dir, model, item, try #require(Self.page(vm)))
    }

    /// The temperature, wind, rain and chart strings of `page` are in `units` and not in `other`.
    private func expectStrings(_ page: DetailViewModel.ForecastPage, _ item: AppModel.Place, in units: WxUnits)
        throws
    {
        let other: WxUnits = units == .metric ? .imperial : .metric
        let forecast = try #require(item.forecast)
        let cur = try #require(WxBlend.now(forecast, nowS: item.nowS))
        let deg = units == .metric ? "\(Self.deg)C" : "\(Self.deg)F"
        let (speed, otherSpeed) = units == .metric ? ("km/h", "mph") : ("mph", "km/h")
        let (depth, otherDepth) = units == .metric ? (" mm", " in") : (" in", " mm")
        // Temperature: the now block and the hour cards.
        #expect(page.now.temperature == WxFormat.temp(cur.tempC, units: units, withUnit: true))
        #expect(page.now.temperature.hasSuffix(deg))
        #expect(page.now.temperature != WxFormat.temp(cur.tempC, units: other, withUnit: true))
        #expect(page.now.feelsLike == "Feels like " + WxFormat.temp(cur.feelsC, units: units, withUnit: false))
        #expect(page.hours.first?.temp == WxFormat.temp(cur.tempC, units: units, withUnit: false))
        // Wind: the now block and every hour card's tooltip.
        #expect(page.now.wind.hasPrefix("Wind " + WxFormat.wind(cur.windKmh, units: units)))
        #expect(page.now.wind.contains(speed) && !page.now.wind.contains(otherSpeed))
        #expect(!page.hours.isEmpty)
        for card in page.hours {
            let lines = card.tooltip.split(separator: "\n").map(String.init)
            #expect(lines.count == 4, "\(card.tooltip)")
            #expect(lines.dropFirst().first?.hasSuffix(deg) == true, "\(card.tooltip)")
            #expect(lines.dropFirst(2).first?.hasSuffix(" " + speed) == true, "\(card.tooltip)")
            // Rain amounts.
            #expect(lines.last?.hasPrefix("Rain ") == true && lines.last?.hasSuffix(depth) == true,
                    "\(card.tooltip)")
            #expect(!card.tooltip.contains(otherDepth + "\n") && !card.tooltip.hasSuffix(otherDepth))
        }
        // The rain chart: its scale and its bars (its accessible description names the chance).
        let chart = page.rain.hourly
        #expect(chart.units == units && chart.hasData)
        #expect(chart.rateUnitShort == (units == .metric ? "mm/h" : "in/h"))
        #expect(chart.scaleLabel.hasSuffix(depth + "/h") && chart.midScaleLabel.hasSuffix(depth + "/h"))
        let wet = try #require(chart.rateMmH.firstIndex { $0 > 0 })
        #expect(chart.formattedRate(forSlot: wet) == WxFormat.precip(chart.rateMmH[wet], units: units) + "/h")
        #expect(chart.formattedRate(forSlot: wet)?.hasSuffix(depth + "/h") == true)
        #expect(chart.compactBarLabel(forSlot: wet)?.hasSuffix(depth + "/h") == true)
        // The nowcast chart (the other view of the rain card) is in the place's units too
        // (U50 verifier handoff: forcing either units there left every test green).
        let nowcast = page.rain.nowcast
        #expect(nowcast.units == units)
        #expect(nowcast.rateUnitShort == (units == .metric ? "mm/h" : "in/h"))
        #expect(nowcast.scaleLabel.hasSuffix(depth + "/h") && nowcast.midScaleLabel.hasSuffix(depth + "/h"))
    }

    @Test(.timeLimit(.minutes(1))) func metricPlaceWithImperialDefault() async throws {
        let r = try await unitsPage("metric", defaultUnits: .imperial, placeUnits: .metric)
        try expectStrings(r.page, r.item, in: .metric)
        _ = await r.model.flush()
        _ = r.dir
    }

    @Test(.timeLimit(.minutes(1))) func imperialPlaceWithMetricDefault() async throws {
        let r = try await unitsPage("imperial", defaultUnits: .metric, placeUnits: .imperial)
        try expectStrings(r.page, r.item, in: .imperial)
        _ = await r.model.flush()
        _ = r.dir
    }

    // MARK: - The application model's item (owned case /window/refresh/partial)

    // C: /window/refresh/partial (test_refresh_partial_one_source_fails, test-window.c:1429-1440)
    @Test(.timeLimit(.minutes(1))) func refreshPartialOneSourceFails() async throws {
        let dir = try TemporaryDirectory("u29-partial")
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let clock = ManualClock()
        let registry = WxRegistry()
        let a = FakeProvider(id: "fake-a")  // test-window.c:586
        let b = FakeProvider(id: "fake-b")  // test-window.c:587
        for (provider, id) in [(a, "fake-a"), (b, "fake-b")] {
            let now = clock.wallSeconds
            var m = try WxMember(sourceID: id, modelID: "m1", fetchedS: now)
            for i in -2..<72 {  // make_member (test-window.c:213-257)
                _ = m.addHour(WxHour(tS: now - now % 3600 + Int64(i) * 3600, tempC: 24, feelsC: 26, precipMm: 0,
                                     precipProb: 5, cloudPct: 40, windKmh: 12, gustKmh: 20, humidityPct: 70))
            }
            provider.addMember(m)
            try registry.addProvider(provider)
        }
        b.failWith(.network)  // FxConfig { RAIN_DRY, -1, WX_ERROR_NETWORK } (test-window.c:1431)
        let places = try #require(WxPlaces(path: storage.placesPath))
        #expect(places.add(try WxPlace(name: "Miami", admin1: "Florida", country: "United States", countryCode: "US",
                                       lat: 25.7743, lon: -80.1937, timezone: "America/New_York")))
        try places.save()
        let model = AppModel(registry: registry, storage: storage, clock: clock, online: true, log: { _, _ in })
        await model.load()
        model.setVisible(true)
        let deadline = ContinuousClock.now + .seconds(30)
        while !(model.selectedPlace?.forecast != nil && model.selectedPlace?.loading == false) {
            if ContinuousClock.now > deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let item = try #require(model.selectedPlace)
        #expect(item.forecast != nil)
        #expect(!item.stale)  // the refresh as a whole succeeded, test-window.c:1438
        let vm = DetailViewModel()
        vm.show(place: item)
        #expect(Self.footerParts(vm)?.sources == "Sources: Fake fake-a")  // test-window.c:1439
        #expect(Self.page(vm)?.partial == "Not available right now: Fake fake-b")  // test-window.c:1440
        _ = await model.flush()
    }

    // MARK: - Alerts (U52)

    /// An alert of `source` named `event` at `level`, with its headline, description, instruction
    /// and page.
    nonisolated static func alert(_ id: String, _ event: String, _ level: WxAlert.Level, onsetS: Int64? = nil,
                                  expiresS: Int64? = nil, endsS: Int64? = nil, web: String? = nil,
                                  source: WxAlert.Source = .nws) -> WxAlert {
        WxAlert(id: source.rawValue + ":" + id, source: source, event: event, headline: event + " until further notice",
                description: "Details of the " + event + ".", instruction: "Stay indoors.", level: level,
                issuerSeverity: "", onsetS: onsetS, expiresS: expiresS, endsS: endsS, web: web)
    }

    /// An answer of the alerts service: `state` from `source` with `alerts`, fetched at `fetchedS`.
    nonisolated static func alertsResult(_ state: WxAlertsResult.State, _ alerts: [WxAlert] = [],
                                         source: WxAlert.Source? = .nws, fetchedS: Int64? = nowS - 300)
        -> WxAlertsResult {
        WxAlertsResult(state: state, source: source, alerts: alerts, fetchedS: fetchedS)
    }

    /// The alerts section `vm` shows.
    static func alertsShown(_ vm: DetailViewModel) throws -> DetailViewModel.AlertsSection {
        try #require(vm.alerts)
    }

    /// A loaded model without forecast sources holding `places`, its alerts service answering
    /// `results` (by place key; given the model clock's "now"); `dir` keeps the files alive.
    private func alertsModel(_ label: String, _ places: [WxPlace],
                             _ results: (Int64) throws -> [String: WxAlertsResult]) async throws
        -> (dir: TemporaryDirectory, model: AppModel)
    {
        let dir = try TemporaryDirectory("u52-detail-\(label)")
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let list = try #require(WxPlaces(path: storage.placesPath))
        for p in places {
            #expect(list.add(p))
        }
        try list.save()
        let clock = ManualClock()
        let service = DetailFixedAlerts()
        service.results = try results(clock.wallSeconds)
        let model = AppModel(registry: WxRegistry(), storage: storage, clock: clock, online: true,
                             log: { _, _ in }, alerts: service)
        await model.load()
        return (dir, model)
    }

    @Test func alertCardsFormattedInPlaceZone() throws {
        let tornado = Self.alert("a", "Tornado Warning", .red, onsetS: Self.nowS - 2 * 3600,
                                 expiresS: Self.nowS + 6 * 3600, endsS: Self.nowS + 20 * 3600,
                                 web: "https://alerts.weather.gov/a")
        let gale = Self.alert("b", "Gale Warning", .yellow, onsetS: Self.nowS + 3 * 86_400,
                              web: "http://insecure.example/b")
        let statement = Self.alert("c", "Special Statement", .unknown, expiresS: Self.nowS + 3600)
        let result = Self.alertsResult(.current, [tornado, gale, statement])
        // The same alerts in three place zones (none of them the test machine's alone): the onset,
        // and the event end, else the message expiry, as "<day> <clock>" in the place's zone.
        let expected: [(tz: String, effective: [String?], expires: [String?])] = [
            (Self.ny, ["Today 12:30 PM", "Thursday 2:30 PM", nil], ["Tomorrow 10:30 AM", nil, "Today 3:30 PM"]),
            (Self.akl, ["Today 5:30 AM", "Friday 7:30 AM", nil], ["Tomorrow 3:30 AM", nil, "Today 8:30 AM"]),
            ("UTC", ["Today 4:30 PM", "Thursday 6:30 PM", nil], ["Tomorrow 2:30 PM", nil, "Today 7:30 PM"]),
        ]
        let vm = DetailViewModel()
        for e in expected {
            for item in [Self.with(try Self.plain(e.tz), alerts: result),
                         Self.with(Self.item(try Self.place(e.tz)), alerts: result)] {  // with and without forecast
                vm.show(item)
                let section = try Self.alertsShown(vm)
                #expect(section.state == .current)
                #expect(section.text == nil)
                #expect(!section.showsSpinner)
                #expect(section.sourceName == "National Weather Service")
                // One card per alert, in the result's order (highest level first).
                #expect(section.cards.map(\.id) == ["nws:a", "nws:b", "nws:c"])
                #expect(section.cards.map(\.event) == ["Tornado Warning", "Gale Warning", "Special Statement"])
                #expect(section.cards.map(\.level) == [.red, .yellow, .unknown])
                #expect(section.cards.map(\.severity) == ["Red", "Yellow", "Unknown"])
                #expect(section.cards.map(\.effective) == e.effective, "\(e.tz)")
                #expect(section.cards.map(\.expires) == e.expires, "\(e.tz)")
                #expect(section.cards.map(\.headline) == ["Tornado Warning until further notice",
                                                          "Gale Warning until further notice",
                                                          "Special Statement until further notice"])
                #expect(section.cards.map(\.description) == ["Details of the Tornado Warning.",
                                                             "Details of the Gale Warning.",
                                                             "Details of the Special Statement."])
                #expect(section.cards.allSatisfy { $0.instruction == "Stay indoors." })
                #expect(section.cards.allSatisfy { $0.sourceName == "National Weather Service" })
                // The issuer's page when it is a linkable https URL; an NWS alert without one (an
                // insecure page of another host, no page) links the NWS site, never the http page.
                #expect(section.cards.map(\.link) == ["https://alerts.weather.gov/a", "https://www.weather.gov/",
                                                      "https://www.weather.gov/"])
            }
        }
        // Each issuer's name.
        #expect(WxAlert.Source.allCases.map(DetailViewModel.AlertsSection.sourceName) == [
            "National Weather Service", "Deutscher Wetterdienst", "MET Norway",
            "Environment and Climate Change Canada", "MeteoAlarm",
        ])
    }

    @Test func alertExpiryFilteredAtNowS() throws {
        let result = Self.alertsResult(.current, [
            Self.alert("expired", "Tornado Warning", .red, expiresS: Self.nowS),
            Self.alert("ended", "Flood Warning", .red, expiresS: Self.nowS + 3600, endsS: Self.nowS),
            Self.alert("next", "Wind Advisory", .orange, expiresS: Self.nowS + 1),
            Self.alert("open", "Heat Advisory", .yellow),
        ])
        let item = Self.with(try Self.plain(Self.ny), alerts: result)
        let vm = Self.shown(item)
        // At nowS, an alert expiring or ending at nowS is gone; one a second later and an
        // open-ended one are shown.
        #expect(try Self.alertsShown(vm).cards.map(\.id) == ["nws:next", "nws:open"])
        #expect(try Self.alertsShown(vm).cards.map(\.expires) == ["Today 2:30 PM", nil])
        #expect(try Self.alertsShown(vm).text == nil)
        // The row of the same item shows the same alerts.
        #expect(RowViewModel(place: item.place, forecast: item.forecast, nowS: item.nowS, alerts: result)
            .alerts.map(\.id) == ["nws:next", "nws:open"])
        // One second on: the advisory has expired too.
        vm.show(Self.with(item, nowS: Self.nowS + 1))
        #expect(try Self.alertsShown(vm).cards.map(\.id) == ["nws:open"])
        // A current answer whose alerts have all expired at nowS: no active alerts.
        vm.show(Self.with(item, alerts: Self.alertsResult(.current, Array(result.alerts.prefix(2)))))
        #expect(try Self.alertsShown(vm).cards.isEmpty)
        #expect(try Self.alertsShown(vm).text == "No active alerts")
    }

    @Test func staleSetNotShownAsCurrent() throws {
        let held = [Self.alert("t", "Tornado Warning", .red, expiresS: Self.nowS + 3600)]
        let item = try Self.plain(Self.ny)
        // Current, the alert is a card.
        let vm = Self.shown(Self.with(item, alerts: Self.alertsResult(.current, held)))
        #expect(try Self.alertsShown(vm).cards.map(\.id) == ["nws:t"])
        // The same set past its source's window: no card, the could-not-check text and the last
        // check in the place's zone (90 minutes ago: 1:00 PM in New York, 6:00 AM in Auckland).
        let stale = Self.alertsResult(.stale, held, fetchedS: Self.nowS - 5400)
        vm.show(Self.with(item, alerts: stale))
        var section = try Self.alertsShown(vm)
        #expect(section.state == .stale)
        #expect(section.cards.isEmpty)
        #expect(section.text == "Alerts could not be checked recently. Last checked: Today 1:00 PM.")
        #expect(section.text != DetailViewModel.AlertsSection.noAlertsText)
        vm.show(Self.with(try Self.plain(Self.akl), alerts: stale))
        #expect(try Self.alertsShown(vm).text == "Alerts could not be checked recently. Last checked: Today 6:00 AM.")
        // Without a known check: the sentence alone.
        vm.show(Self.with(item, alerts: Self.alertsResult(.stale, held, fetchedS: nil)))
        section = try Self.alertsShown(vm)
        #expect(section.cards.isEmpty)
        #expect(section.text == "Alerts could not be checked recently.")
        // The row of a stale set has no indicator.
        #expect(RowViewModel(place: item.place, forecast: item.forecast, nowS: item.nowS, alerts: stale)
            .alertIndicator == nil)
    }

    @Test func alertStateTexts() async throws {
        let item = try Self.plain(Self.ny)
        let one = [Self.alert("t", "Tornado Warning", .red, expiresS: Self.nowS + 3600)]
        let cases: [(WxAlertsResult, text: String?, spinner: Bool)] = [
            (Self.alertsResult(.notFetched, source: .nws, fetchedS: nil), "Checking for alerts\u{2026}", true),
            (Self.alertsResult(.current), "No active alerts", false),
            (Self.alertsResult(.current, one), nil, false),
            (Self.alertsResult(.stale, one, fetchedS: nil), "Alerts could not be checked recently.", false),
            (Self.alertsResult(.unavailable), "Alerts could not be checked right now.", false),
            (Self.alertsResult(.notCovered, source: nil, fetchedS: nil), "Alerts not available", false),
        ]
        let vm = Self.shown(item)
        // The default item (nothing asked yet) is checking.
        #expect(try Self.alertsShown(vm).text == "Checking for alerts\u{2026}")
        var texts: [String] = []
        for c in cases {
            // A change of the alerts alone leaves the forecast page and its revision alone.
            let revision = vm.revision
            let pageChanges = Self.notifications(vm) { vm.show(Self.with(item, alerts: c.0)) }
            #expect(pageChanges == 0)
            #expect(vm.revision == revision)
            let section = try Self.alertsShown(vm)
            #expect(section.state == c.0.state)
            #expect(section.text == c.text, "\(c.0.state)")
            #expect(section.showsSpinner == c.spinner, "\(c.0.state)")
            #expect(section.cards.count == (c.text == nil ? 1 : 0), "\(c.0.state)")
            if let t = section.text {
                texts.append(t)
            }
        }
        // One text per state; only a current empty answer says "No active alerts", and both
        // unavailable and stale say alerts could not be checked.
        #expect(Set(texts).count == texts.count)
        #expect(texts.filter { $0 == "No active alerts" }.count == 1)
        #expect(texts.filter { $0.contains("could not be checked") }.count == 2)
        // No item, no section.
        vm.show(nil)
        #expect(vm.alerts == nil)

        // Through the model: each place's state as the service answers it (show(place:)).
        let places = try ["US", "DE", "NO", "CA", "FR"].enumerated().map { i, cc in
            try WxPlace(name: "Place \(i)", admin1: "", country: cc, countryCode: cc, lat: 10 + Double(i),
                        lon: 10, timezone: Self.ny)
        }
        let states: [WxAlertsResult.State] = [.notFetched, .current, .stale, .unavailable, .notCovered]
        let fx = try await alertsModel("states", places) { now in
            Dictionary(uniqueKeysWithValues: zip(places.map(\.key), states).map { key, state in
                (key, WxAlertsResult(state: state, source: state == .notCovered ? nil : .nws, alerts: [],
                                     fetchedS: state == .notFetched ? nil : now - 60))
            })
        }
        var modelTexts: [String] = []
        for p in places {
            vm.show(place: fx.model.place(forKey: p.key))
            modelTexts.append(try Self.alertsShown(vm).text ?? "")
        }
        #expect(modelTexts.count == 5)
        #expect(modelTexts[0] == "Checking for alerts\u{2026}")
        #expect(modelTexts[1] == "No active alerts")
        // The model clock starts at 2026-10-11 00:00Z: checked a minute before, 7:59 PM in New York.
        #expect(modelTexts[2] == "Alerts could not be checked recently. Last checked: Today 7:59 PM.")
        #expect(modelTexts[3] == "Alerts could not be checked right now.")
        #expect(modelTexts[4] == "Alerts not available")
        _ = await fx.model.flush()
    }

    @Test func uncoveredShowsNotAvailable() async throws {
        let nowhere = try WxPlace(name: "Nowhere", admin1: "", country: "Nowhere", countryCode: "ZZ", lat: 10,
                                  lon: 10, timezone: "UTC")
        // No source for the country, and a source that does not cover the point: not "no alerts".
        for source in [nil, WxAlert.Source.nws] {
            let vm = Self.shown(Self.with(Self.item(nowhere), alerts: Self.alertsResult(.notCovered, source: source)))
            let section = try Self.alertsShown(vm)
            #expect(section.state == .notCovered)
            #expect(section.text == "Alerts not available")
            #expect(section.text != DetailViewModel.AlertsSection.noAlertsText)
            #expect(section.cards.isEmpty)
            #expect(!section.showsSpinner)
            #expect(section.sourceName == source.map(DetailViewModel.AlertsSection.sourceName))
        }
        // Through the model: the service says the place is not covered.
        let fx = try await alertsModel("uncovered", [nowhere]) { now in
            [nowhere.key: WxAlertsResult(state: .notCovered, source: nil, alerts: [], fetchedS: now)]
        }
        let vm = DetailViewModel()
        vm.show(place: fx.model.place(forKey: nowhere.key))
        #expect(try Self.alertsShown(vm).text == "Alerts not available")
        #expect(try Self.alertsShown(vm).cards.isEmpty)
        _ = await fx.model.flush()
    }

    // MARK: - Alert links (U52 iteration 2: every NWS card links an https page)

    /// "Now" of the recorded NWS, Bright Sky and MET Norway answers (2026-10-26 14:30:10Z,
    /// WxAlertTests.nowS), and of the ECCC and MeteoAlarm ones (2026-10-26 16:15:00Z).
    nonisolated static let pointAlertsNowS: Int64 = 1_793_025_010
    nonisolated static let regionAlertsNowS: Int64 = 1_793_031_300
    /// The NWS site, linked by an NWS card whose own page is not an https one.
    nonisolated static let nwsSite = "https://www.weather.gov/"

    @Test func nwsRecordedAlertsCarryHTTPSLink() throws {
        // The recorded answer (api.weather.gov/alerts/active?area=AK, three alerts): each carries
        // the NWS's own page as plain http, which the pane never links as such.
        let nowS = Self.pointAlertsNowS
        let alerts = try #require(WxPointAlerts.parseNWS(try Fixtures.data("alerts-nws-area-ak-trim3.json"),
                                                         status: 200, nowS: nowS)).alerts
        #expect(alerts.count == 3)
        #expect(alerts.map(\.web) == Array(repeating: "http://www.weather.gov", count: 3))
        // Every card links that page over https.
        let cards = alerts.map { DetailViewModel.AlertCard.card($0, nowS: nowS, zone: .utc) }
        #expect(cards.map(\.link) == Array(repeating: Self.nwsSite, count: 3))
        #expect(cards.allSatisfy { $0.link.map { DetailViewModel.isLinkable(urlBytes: Array($0.utf8)) } == true })
        // Through the pane: an Alaska place whose current answer is the recorded one.
        let fairbanks = try WxPlace(name: "Fairbanks", admin1: "Alaska", country: "United States",
                                    countryCode: "US", lat: 64.84, lon: -147.72, timezone: "America/Anchorage")
        let vm = Self.shown(Self.with(Self.item(fairbanks, nowS: nowS),
                                      alerts: Self.alertsResult(.current, alerts, fetchedS: nowS - 60)))
        let section = try Self.alertsShown(vm)
        #expect(section.cards.map(\.id) == alerts.map(\.id))
        #expect(section.cards.map(\.link) == Array(repeating: Self.nwsSite, count: 3))
        #expect(section.cards.allSatisfy { $0.sourceName == "National Weather Service" })
    }

    @Test func nwsLinkUpgradeOnlyForWeatherGov() throws {
        func link(_ web: String?, _ source: WxAlert.Source = .nws) -> String? {
            DetailViewModel.AlertCard.card(Self.alert("x", "Flood Warning", .orange, web: web, source: source),
                                           nowS: Self.nowS, zone: .utc).link
        }
        // The NWS's own http pages, on weather.gov or a subdomain: https, with the path, query and
        // fragment kept ("/" for none).
        #expect(link("http://www.weather.gov") == "https://www.weather.gov/")
        #expect(link("http://www.weather.gov/") == "https://www.weather.gov/")
        #expect(link("http://weather.gov/safety/flood") == "https://weather.gov/safety/flood")
        #expect(link("http://forecast.weather.gov/MapClick.php?zoneid=AKZ803#alerts")
            == "https://forecast.weather.gov/MapClick.php?zoneid=AKZ803#alerts")
        #expect(link("http://alerts.weather.gov?area=AK") == "https://alerts.weather.gov?area=AK")
        #expect(link("http://WWW.Weather.GOV/afg") == "https://WWW.Weather.GOV/afg")
        // An https page is linked as published, whatever its host.
        #expect(link("https://alerts.weather.gov/a") == "https://alerts.weather.gov/a")
        #expect(link("https://www.spc.noaa.gov/products/") == "https://www.spc.noaa.gov/products/")
        // No page, another host's http page, one that only looks like weather.gov, or one that is
        // not linkable once upgraded: the NWS site, never the other host.
        let long = "http://www.weather.gov/" + String(repeating: "a", count: WxLimits.sourceURLMax - 23)
        #expect(long.utf8.count == WxLimits.sourceURLMax)
        let others: [String?] = [
            nil, "", "http://insecure.example/b", "http://www.weather.gov.example.com/x", "http://evilweather.gov/x",
            "http://www.weather.gov@example.com/x", "http://www.weather.gov:8080/x", "http://example.com/www.weather.gov",
            "http://.weather.gov/x", "http://www..weather.gov/x", "http://weather.gov./x", "ftp://www.weather.gov/x",
            "HTTP://www.weather.gov/x", " http://www.weather.gov", "http://www.weather.gov/a b",
            "http://www.weather.gov/<b>", long,
        ]
        for web in others {
            #expect(link(web) == Self.nwsSite, "\(web ?? "nil")")
        }
        // Every other issuer: its https page only; an http page stays unlinked, weather.gov
        // included (only the NWS's own page is upgraded).
        for source in [WxAlert.Source.dwd, .metNorway, .eccc, .meteoAlarm] {
            #expect(link("https://www.example.org/w", source) == "https://www.example.org/w", "\(source)")
            for web in [nil, "http://insecure.example/b", "http://www.weather.gov", "http://www.dwd.de/"] as [String?] {
                #expect(link(web, source) == nil, "\(source) \(web ?? "nil")")
            }
        }
    }

    @Test func otherIssuersLinksUnchanged() throws {
        // Each issuer's recorded answer through its parser: the card links exactly the page the
        // alert carries (Bright Sky and ECCC: their fixed https sites; MET Norway and MeteoAlarm:
        // the issuer's own https page).
        let point = Self.pointAlertsNowS, region = Self.regionAlertsNowS
        let dwd = try #require(WxPointAlerts.parseBrightSky(try Fixtures.data("alerts-brightsky-all-trim2.json"),
                                                            status: 200, nowS: point)).alerts
        let met = try #require(WxPointAlerts.parseMETNorway(try Fixtures.data("alerts-metno-current-en-trim2.json"),
                                                            status: 200, nowS: point)).alerts
        let eccc = try #require(WxECCCAlerts.parse(try Fixtures.data("alerts-eccc-toronto-point.json"), status: 200,
                                                   nowS: region)).alerts
        let meteoAlarm = try #require(WxMeteoAlarm.parse(try Fixtures.data("alerts-meteoalarm-france-trim3.json"),
                                                         status: 200, nowS: region)).map(\.alert)
        let cases: [(source: WxAlert.Source, alerts: [WxAlert], nowS: Int64, page: String)] = [
            (.dwd, dwd, point, WxPointAlerts.dwdWarningsURL),
            (.eccc, eccc, region, WxECCCAlerts.weatherURL),
            (.metNorway, met, point, "https://www.met.no/vaer-og-klima/ekstremvaervarsler-og-andre-farevarsler/"
                + "vaerfenomener-som-kan-gi-farevarsel-fra-met/kuling-stormvarsel-for-kyst-og-naere-fiskebanker"),
            (.meteoAlarm, meteoAlarm, region, "https://vigilance.meteofrance.fr/"),
        ]
        for c in cases {
            #expect(!c.alerts.isEmpty, "\(c.source)")
            #expect(c.alerts.allSatisfy { $0.source == c.source && $0.web == c.page }, "\(c.source)")
            let cards = c.alerts.map { DetailViewModel.AlertCard.card($0, nowS: c.nowS, zone: .utc) }
            #expect(cards.map(\.link) == Array(repeating: c.page, count: c.alerts.count), "\(c.source)")
        }
    }
}

/// An alerts service that answers fixed results by place key and fetches nothing.
@MainActor
private final class DetailFixedAlerts: WxAlertsServing {
    var results: [String: WxAlertsResult] = [:]

    func refresh(_ place: WxPlace) -> Task<Void, Never> { Task {} }
    func result(for place: WxPlace) -> WxAlertsResult { results[place.key] ?? AppModel.alertsNotFetched }
    func remove(placeKey: String) { results[placeKey] = nil }
    func cancelAll() {}
}
