// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U41AuditFixTests.swift - regression tests for the verified audit findings
// of slices P17 (detail view model, lists, chart data) and P18 (row, picker,
// sources, About):
//   U17-F5  DetailViewModel.now drew the "now" icon from the effective
//           condition (iconAssetName) but gave it the raw condition's
//           accessible label: "Partly cloudy" over wx-showers-day, "Rain" over
//           wx-snow-day.
// The other fixed findings (U17-F1, U17-F2, U18-F1) are doc-comment-only and
// carry command evidence in units/U41/fixes.json instead of a test.
// The visible condition text stays the C label (wx-detail.c refresh_now); only
// the icon's accessible label changes, and only where effectiveHourlyCondition
// changes the condition.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct U41AuditFixTests {
    // MARK: - U17-F5: the "now" icon's accessible label names the drawn icon

    static let start: Int64 = 1_791_741_600  // 2026-10-11 18:00Z, on the hour

    /// The "now" block of a 48-hour forecast whose every hour is the given
    /// condition, temperature, model precipitation and chance; "now" is half
    /// past the first hour.
    static func now(_ condition: WxCondition, tempC: Double, mm: Double, prob: Double) throws
        -> DetailViewModel.Now? {
        let place = try WxPlace(name: "New York", lat: 40.71, lon: -74.01, timezone: "America/New_York")
        let hours = (0..<48).map {
            WxBlendHour(tS: start + Int64($0) * 3600, tempC: tempC, feelsC: tempC, precipMm: mm,
                        precipMmMax: mm, precipProb: prob, cloudPct: 40, windKmh: 19, gustKmh: 30,
                        humidityPct: 60, tempSpreadC: .nan, nMembers: 2, condition: condition, isDay: true)
        }
        let forecast = try WxForecast(place: place, generatedS: start + 60, hours: hours)
        let item = DetailViewModel.Item(place: place, forecast: forecast, units: .metric, nowS: start + 1800)
        guard case .forecast(let page) = DetailViewModel.makePage(item, placeZone: .utc, forecastZone: .utc)
        else { return nil }
        return page.now
    }

    /// A dry sky at 50 % with model rain is drawn as showers. Before the fix
    /// the icon's label was the raw "Partly cloudy", the same as the text.
    @Test func nowIconLabelNamesShowersDrawnOverPartlyCloudy() throws {
        let now = try #require(try Self.now(.partlyCloudy, tempC: 25, mm: 0.2, prob: 50))
        #expect(now.iconAssetName == "wx-showers-day")
        #expect(now.iconAccessibilityLabel == "Showers")
        #expect(now.condition == "Partly cloudy")  // C text, unchanged
        #expect(now.iconAccessibilityLabel != now.condition)
    }

    /// Rain at 0.2 C is drawn as snow. Before the fix the icon's label was
    /// "Rain", the same as the text.
    @Test func nowIconLabelNamesSnowDrawnForColdRain() throws {
        let now = try #require(try Self.now(.rain, tempC: 0.2, mm: 1.0, prob: 80))
        #expect(now.iconAssetName == "wx-snow-day")
        #expect(now.iconAccessibilityLabel == "Snow")
        #expect(now.condition == "Rain")  // C text, unchanged
        #expect(now.iconAccessibilityLabel != now.condition)
    }

    /// Every condition x temperature x chance x amount: the icon's label is the
    /// label of the condition the icon is drawn from (before the fix, 291 of
    /// the 675 cases disagreed).
    @Test func nowIconLabelMatchesDrawnConditionSweep() throws {
        let conditions: [WxCondition] = [.clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .overcast, .fog,
                                         .drizzle, .lightRain, .showers, .rain, .heavyRain, .thunderstorm,
                                         .snow, .sleet, .unknown]
        var total = 0
        var mismatches: [String] = []
        for condition in conditions {
            for tempC in [-5.0, 0.2, 1.5, 10, 25] {
                for prob in [0.0, 35, 60] {
                    for mm in [0.0, 0.2, 3.0] {
                        let now = try #require(try Self.now(condition, tempC: tempC, mm: mm, prob: prob))
                        total += 1
                        if now.iconAccessibilityLabel != WxConditionRules.label(now.conditionCode) {
                            mismatches.append("\(condition) \(tempC)C \(prob)% \(mm)mm")
                        }
                    }
                }
            }
        }
        #expect(total == 675)
        #expect(mismatches.count == 0, "first: \(Array(mismatches.prefix(3)))")
    }
}
