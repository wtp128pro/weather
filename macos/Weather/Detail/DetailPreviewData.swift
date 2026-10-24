// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailPreviewData.swift - sample items for the #Preview blocks of the detail
// pane views. Every visible string is still produced by DetailViewModel /
// RainChartData from these inputs; nothing here is shown verbatim except the
// place, provider names and attributions that the view model passes through.

import SwiftUI
import WeatherCore

/// Preview inputs: a New York place and a 72-hour forecast at fixed times (no clock is read).
enum DetailPreviewData {
    /// 2026-10-12 18:00:00Z, an hour boundary.
    static let hour0: Int64 = 1_791_828_000
    /// "Now": half past the first hour (quarter-aligned).
    static let nowS: Int64 = hour0 + 1800
    /// 2026-10-12 00:00 in New York.
    static let day0: Int64 = 1_791_777_600

    static let place: WxPlace? = try? WxPlace(name: "New York", admin1: "New York", country: "United States",
                                              countryCode: "US", lat: 40.71, lon: -74.0,
                                              timezone: "America/New_York")

    /// A forecast with rain in the next hours, a gap and a lone chance in the chance line,
    /// 10 days and three sources (the third failed when `partial`; the second has no attribution
    /// URL, so its entry is plain text, when `unlinked`).
    static func forecast(nowcast: Bool = true, partial: Bool = true, unlinked: Bool = false) -> WxForecast? {
        guard let place else {
            return nil
        }
        var hours: [WxBlendHour] = (0..<72).map { i in
            let t = hour0 + Int64(i) * 3600
            let temp: Double = 18 + 6 * sin(Double(i) / 24 * 2 * Double.pi)
            return WxBlendHour(tS: t, tempC: temp, feelsC: temp - 1, precipMm: 0, precipMmMax: 0, precipProb: 10,
                               cloudPct: 40, windKmh: 18, gustKmh: 30, humidityPct: 55, tempSpreadC: .nan,
                               nMembers: 3, condition: .partlyCloudy, isDay: i % 24 < 6 || i % 24 > 20)
        }
        for (i, mm) in [(2, 0.3), (3, 1.2), (4, 2.6), (5, 0.8), (6, 0.1)] {
            hours[i].precipMm = mm
            hours[i].precipMmMax = mm * 1.5
            hours[i].precipProb = 40 + mm * 15
            hours[i].condition = .rain
        }
        hours[15].precipProb = .nan
        hours[17].precipProb = .nan
        let quarters: [WxQuarter] = nowcast
            ? (0..<9).map { (q: Int) -> WxQuarter in WxQuarter(tS: nowS + Int64(q) * 900, precipMm: Double(q % 4) * 0.2) }
            : []
        let days: [WxDay] = (0..<10).map { (d: Int) -> WxDay in
            let wet = d == 0
            let high: Double = 22 + Double(d % 3)
            let low: Double = 12 + Double(d % 2)
            return WxDay(startS: day0 + Int64(d) * 86400, tempMaxC: high, tempMinC: low,
                         precipMm: wet ? 5 : 0, precipProbMax: wet ? 70 : 10, cloudPct: 40,
                         condition: wet ? .rain : .partlyCloudy)
        }
        var sources: [WxSourceStatus] = []
        sources += [try? WxSourceStatus(providerID: "open-meteo", name: "Open-Meteo",
                                        attribution: "Weather data by Open-Meteo.com",
                                        attributionURL: "https://open-meteo.com/", state: .ok, errorCode: nil,
                                        nMembers: 1),
                    try? WxSourceStatus(providerID: "met-no", name: "MET Norway", attribution: "Data from MET Norway",
                                        attributionURL: unlinked ? "" : "https://api.met.no/", state: .ok, errorCode: nil,
                                        nMembers: 1),
                    try? WxSourceStatus(providerID: "nws", name: "National Weather Service",
                                        attribution: "Source: NOAA/National Weather Service",
                                        attributionURL: "https://www.weather.gov/", state: partial ? .failed : .ok,
                                        errorCode: partial ? .network : nil, nMembers: partial ? 0 : 1)]
            .compactMap { $0 }
        return try? WxForecast(place: place, generatedS: nowS, hours: hours, quarters: quarters, days: days,
                               sources: sources)
    }

    /// The page DetailViewModel shows for `item` (nil: no place selected).
    static func page(_ item: DetailViewModel.Item?) -> DetailViewModel.Page {
        let detail = DetailViewModel()
        detail.show(item)
        return detail.page
    }

    /// The page of the sample place with the given state.
    static func page(forecast: WxForecast? = nil, loading: Bool = false, stale: Bool = false, offline: Bool = false,
                     nowS: Int64 = nowS, error: String? = nil) -> DetailViewModel.Page {
        guard let place else {
            return page(nil)
        }
        return page(DetailViewModel.Item(place: place, forecast: forecast, fetchedS: Self.nowS - 300,
                                         loading: loading, stale: stale, offline: offline, units: .imperial,
                                         nowS: nowS, errorText: error))
    }

    /// A chart of the sample forecast.
    static func chart(_ view: RainChartData.View) -> RainChartData {
        RainChartData(forecast: forecast(), units: .imperial, nowS: nowS, view: view, zone: .utc)
    }
}
