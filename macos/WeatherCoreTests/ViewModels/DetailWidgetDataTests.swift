// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailWidgetDataTests.swift - port of the data cases of src/widgets/test-widgets.c
// (registered at test-widgets.c:2749-2793): the rain chart's window, bars, chance
// line, views and labels, the hour strip and the day list, as data of the
// DetailViewModelTests suite. The C tests count render nodes (colour nodes = 3 grid
// lines + one per bar or lone chance square; one stroke node for the chance line);
// here the same counts are read from RainChartData. Expected values are the C test
// literals, cited as test-widgets.c:LINE; the description sentences are built from
// the string literals of wx-rain-chart.c:280-316 (the C tests do not assert them).

import Foundation
import Testing
@testable import WeatherCore

extension DetailViewModelTests {
    // MARK: - Fixtures (test-widgets.c:44-120)

    /// ts (test-widgets.c:46-52): UTC unix seconds of a civil date-time (days_from_civil).
    private static func ts(_ y: Int64, _ mo: Int64, _ d: Int64, _ h: Int64, _ mi: Int64) -> Int64 {
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146_097 + doe - 719_468) * 86400 + h * 3600 + mi * 60
    }

    /// T_HOUR0: Sunday 2026-10-11 18:00Z, NOW = 18:30Z = 2:30 PM in New York (test-widgets.c:55-57).
    private static let tHour0 = ts(2026, 10, 11, 18, 0)
    private static let wNow = tHour0 + 1800

    /// make_place_in (test-widgets.c:59-66).
    private static func wPlace(_ tz: String = ny) throws -> WxPlace {
        try WxPlace(name: "Miami", admin1: "Florida", country: "United States", countryCode: "US", lat: 25.76,
                    lon: -80.19, timezone: tz)
    }

    /// hour (test-widgets.c:74-81).
    private static func wHour(_ tS: Int64) -> WxBlendHour {
        WxBlendHour(tS: tS, tempC: 25, feelsC: 27, precipMm: 0, precipMmMax: 0, precipProb: 10, cloudPct: 40,
                    windKmh: 19, gustKmh: 30, humidityPct: 60, tempSpreadC: .nan, nMembers: 2,
                    condition: .partlyCloudy, isDay: true)
    }

    /// make_forecast_in (test-widgets.c:84-114): hour i rains 1.5 mm when i % 3 == 0, chance
    /// 10 * (i % 10) + 5, 20 + i % 10 C; quarter i rains 0.5 mm when even; day i from
    /// 2026-10-11 04:00Z, 30 + i / 20 - i C, 2 i mm, 10 i %, rain.
    private static func makeForecast(_ t0: Int64, _ n: Int, _ nq: Int, _ nd: Int, tz: String = ny) throws
        -> WxForecast {
        let hours = (0..<n).map { i -> WxBlendHour in
            var h = wHour(t0 + Int64(i) * 3600)
            h.precipMm = i % 3 == 0 ? 1.5 : 0.0
            h.precipProb = 10.0 * Double(i % 10) + 5.0
            h.tempC = 20.0 + Double(i % 10)
            return h
        }
        let quarters = (0..<nq).map { WxQuarter(tS: t0 + Int64($0) * 900, precipMm: $0 % 2 == 0 ? 0.5 : 0.0) }
        let days = (0..<nd).map {
            WxDay(startS: ts(2026, 10, 11, 4, 0) + Int64($0) * 86400, tempMaxC: 30 + Double($0),
                  tempMinC: 20 - Double($0), precipMm: 2.0 * Double($0), precipProbMax: 10.0 * Double($0),
                  cloudPct: 50, condition: .rain)
        }
        return try WxForecast(place: try wPlace(tz), generatedS: wNow, hours: hours, quarters: quarters, days: days)
    }

    private static func chart(_ f: WxForecast?, _ units: WxUnits = .metric, _ now: Int64 = wNow,
                              _ view: RainChartData.View = .auto) -> RainChartData {
        RainChartData(forecast: f, units: units, nowS: now, view: view,
                      zone: WxFormat.Zone(timezone: f?.place.timezone ?? ""))
    }

    /// counts().color of test-widgets.c:205-224: the grid (3, iff there is data) plus the bars
    /// and the lone chance squares; counts().stroke: one chance line.
    private static func colorNodes(_ c: RainChartData) -> Int {
        c.hasData ? 3 + c.barSlots.count + c.loneProbabilitySlots.count : 0
    }

    private static func strokeNodes(_ c: RainChartData) -> Int {
        c.probabilityRuns.isEmpty ? 0 : 1
    }

    private static func cards(_ f: WxForecast?, _ units: WxUnits, _ now: Int64) -> [DetailViewModel.HourCard] {
        DetailViewModel.HourCard.cards(forecast: f, units: units, nowS: now,
                                       zone: WxFormat.Zone(timezone: f?.place.timezone ?? ""))
    }

    private static func rows(_ f: WxForecast?, _ units: WxUnits, _ now: Int64) -> [DetailViewModel.DayRow] {
        DetailViewModel.DayRow.rows(forecast: f, units: units, nowS: now,
                                    zone: WxFormat.Zone(timezone: f?.place.timezone ?? ""))
    }

    /// The same drawn content (the C tests compare snapshots byte for byte).
    private static func sameDrawing(_ a: RainChartData, _ b: RainChartData) -> Bool {
        if !a.hasData && !b.hasData {
            return true  // both draw "No data" only
        }
        return a.isQuarters == b.isQuarters && a.startS == b.startS && a.hasData == b.hasData
            && a.rateMmH.count == b.rateMmH.count
            && zip(a.rateMmH, b.rateMmH).allSatisfy { WxFormat.sameValue($0, $1) }
            && zip(a.probability, b.probability).allSatisfy { WxFormat.sameValue($0, $1) }
            && a.scaleLabel == b.scaleLabel && a.axisLabels == b.axisLabels
            && a.accessibilityDescription == b.accessibilityDescription
    }

    // MARK: - Rain chart

    // C: /widgets/chart/no-data (test-widgets.c:285-318)
    @Test func chartNoData() throws {
        let empty = RainChartData()
        #expect(!empty.hasData)  // test-widgets.c:290
        #expect(Self.colorNodes(empty) == 0 && Self.strokeNodes(empty) == 0)  // test-widgets.c:293-294
        #expect(RainChartData.noDataText == "No data")  // the one text node, test-widgets.c:292
        #expect(empty.accessibilityDescription == "No rain data.")  // wx-rain-chart.c:283
        #expect(Self.sameDrawing(Self.chart(nil), empty))  // test-widgets.c:296-298
        #expect(!Self.chart(try Self.makeForecast(Self.tHour0, 0, 0, 0)).hasData)  // test-widgets.c:304
        let some = try Self.makeForecast(Self.tHour0, 30, 0, 0)
        // { 0, G_MAXINT64, G_MININT64, WX_TIME_MIN_S - 1, WX_TIME_MAX_S } (test-widgets.c:306)
        for now in [0, Int64.max, Int64.min, WxLimits.timeMinS - 1, WxLimits.timeMaxS] {
            let c = Self.chart(some, .metric, now)
            #expect(!c.hasData, "now \(now)")  // test-widgets.c:309
            #expect(c.slotCount == 0 && c.axisLabels.isEmpty, "now \(now)")  // test-widgets.c:310
        }
        #expect(!Self.chart(some, .metric, Self.tHour0 + 100 * 3600).hasData)  // test-widgets.c:314
    }

    // C: /widgets/chart/hourly (test-widgets.c:320-403)
    @Test func chartHourly() throws {
        // data starts one hour before the current hour: that hour must not be drawn
        let fc = try Self.makeForecast(Self.tHour0 - 3600, 40, 0, 0)
        let c = Self.chart(fc, .imperial)
        #expect(c.hasData)  // test-widgets.c:329
        #expect(Self.colorNodes(c) == 3 + 8)  // test-widgets.c:332
        #expect(c.barSlots == [2, 5, 8, 11, 14, 17, 20, 23])
        #expect(Self.strokeNodes(c) == 1)  // test-widgets.c:333
        #expect(c.probabilityRuns == [Array(0..<24)])
        // top-of-scale, 100%, 0% and up to 5 time labels (test-widgets.c:334-335)
        #expect(c.axisLabels.map(\.slot) == [0, 6, 12, 17, 23])  // wx-rain-chart.c:564
        #expect(c.axisLabels.first?.text == "Now")
        #expect(c.scaleLabel == "0.10 in/h")  // BASE_SCALE_IN_H 0.1 (wx-rain-chart.c:32) through wx_format_precip
        let metric = Self.chart(fc, .metric)
        #expect(metric.scaleLabel == "2.5 mm/h")  // BASE_SCALE_MM_H, wx-rain-chart.c:31
        #expect(!Self.sameDrawing(c, metric))  // test-widgets.c:338-340
        #expect(Self.sameDrawing(c, Self.chart(fc, .imperial)))  // test-widgets.c:341-343
        // a hole in the data breaks the line and drops the lone values to squares (test-widgets.c:345-368)
        let place = try Self.wPlace()
        var hs = (0..<5).map { i -> WxBlendHour in
            var h = Self.wHour(Self.tHour0 + Int64(i) * 3600)
            h.precipMm = .nan
            return h
        }
        hs[0].precipProb = 50
        hs[1].precipProb = .nan
        hs[2].precipProb = 60
        hs[3].precipProb = 70
        hs[4].precipProb = .nan
        let holes = Self.chart(try WxForecast(place: place, generatedS: Self.wNow, hours: hs))
        #expect(holes.hasData)  // test-widgets.c:365
        #expect(Self.strokeNodes(holes) == 1 && holes.probabilityRuns == [[2, 3]])  // test-widgets.c:367
        #expect(Self.colorNodes(holes) == 3 + 1 && holes.loneProbabilitySlots == [0])  // test-widgets.c:368
        hs[3].precipProb = .nan
        let lone = Self.chart(try WxForecast(place: place, generatedS: Self.wNow, hours: hs))
        #expect(Self.strokeNodes(lone) == 0)  // test-widgets.c:375
        #expect(Self.colorNodes(lone) == 3 + 2)  // test-widgets.c:376
        for i in 0..<5 {
            hs[i].precipProb = .nan
            hs[i].precipMm = i == 1 ? 3.0 : 0.0
        }
        let amounts = Self.chart(try WxForecast(place: place, generatedS: Self.wNow, hours: hs))
        #expect(amounts.hasData)  // test-widgets.c:385
        #expect(Self.strokeNodes(amounts) == 0)  // test-widgets.c:387
        #expect(Self.colorNodes(amounts) == 3 + 1)  // test-widgets.c:388
        // amounts only: describe() falls back to the amount (wx-rain-chart.c:299-308)
        #expect(amounts.accessibilityDescription
                    == "Rain amount by hour for the next 24 hours. Heaviest: 3.0 mm per hour at 3 PM.")
        #expect(!Self.chart(nil).hasData)  // test-widgets.c:392
    }

    // C: /widgets/chart/quarters (test-widgets.c:405-447)
    @Test func chartQuarters() throws {
        #expect(Self.strokeNodes(Self.chart(try Self.makeForecast(Self.tHour0, 30, 0, 0))) == 1)  // test-widgets.c:415-416
        let fc = try Self.makeForecast(Self.tHour0, 30, 12, 0)
        var c = Self.chart(fc)
        #expect(c.hasData && c.isQuarters)  // test-widgets.c:421
        #expect(Self.colorNodes(c) == 3 + 4)  // test-widgets.c:423
        #expect(Self.strokeNodes(c) == 0)  // test-widgets.c:424
        #expect(c.axisLabels.map(\.slot) == [0, 2, 4, 5, 7])  // wx-rain-chart.c:564
        #expect(c.axisLabels.map(\.text) == ["Now", "3:00 PM", "3:30 PM", "3:45 PM", "4:15 PM"])
        c = Self.chart(fc, .metric, Self.tHour0 + 45 * 60)
        #expect(Self.colorNodes(c) == 3 + 4 && Self.strokeNodes(c) == 0)  // test-widgets.c:431-432
        c = Self.chart(fc, .metric, Self.tHour0 + 90 * 60)
        #expect(Self.colorNodes(c) == 3 + 3 && Self.strokeNodes(c) == 0)  // test-widgets.c:436-437
        c = Self.chart(fc, .metric, Self.tHour0 + 4 * 3600)
        #expect(c.hasData && Self.strokeNodes(c) == 1)  // test-widgets.c:440-441
        #expect(!Self.chart(try Self.makeForecast(Self.tHour0, 0, 12, 0), .metric, Self.tHour0 + 4 * 3600).hasData)  // test-widgets.c:445
    }

    // C: /widgets/chart/view-follows-data (test-widgets.c:450-529)
    @Test func chartViewFollowsData() throws {
        let withNC = try Self.makeForecast(Self.tHour0, 30, 12, 0)
        let without = try Self.makeForecast(Self.tHour0, 30, 0, 0)
        let q = Self.chart(withNC)
        #expect(q.barSlots == [0, 2, 4, 6])  // test-widgets.c:461
        #expect(Self.strokeNodes(q) == 0)  // test-widgets.c:462
        let h = Self.chart(without)
        #expect(h.barSlots.count == 8)  // test-widgets.c:467
        #expect(Self.strokeNodes(h) == 1)  // test-widgets.c:468
        // geometry (test-widgets.c:470-485)
        let w: Float = 440
        let text = (width: Float(28), height: Float(15))
        let qg = try #require(q.geometry(width: w, height: 280, percentTopSize: text, axisLabelWidths: []))
        let hg = try #require(h.geometry(width: w, height: 280, percentTopSize: text, axisLabelWidths: []))
        let qSlot = w / 8
        #expect(abs((qg.bars[1].x - qg.bars[0].x) - 2 * qSlot) < 0.01)  // test-widgets.c:477
        #expect(abs(qg.bars[0].width - max(1, qSlot * 0.7)) < 0.01)  // test-widgets.c:478
        #expect(abs(qg.bars[0].x - (qSlot - qg.bars[0].width) / 2) < 0.01)  // test-widgets.c:479
        let hSlot = (hg.bars[1].x - hg.bars[0].x) / 3
        #expect(hSlot < qSlot / 2)  // test-widgets.c:481
        #expect(hSlot * 24 < w)  // test-widgets.c:482
        #expect(abs(hg.bars[0].width - max(1, hSlot * 0.7)) < 0.01)  // test-widgets.c:483
        #expect(abs(hg.bars[0].height / qg.bars[0].height - 0.75) < 0.01)  // test-widgets.c:484
        #expect(qg.gridLines.count == 3 && hg.lineRuns.count == 1 && qg.lineRuns.isEmpty)
        // back: identical (test-widgets.c:486-491)
        #expect(Self.sameDrawing(Self.chart(withNC), q) && Self.sameDrawing(Self.chart(without), h))
        // a nowcast that does not cover now (test-widgets.c:492-520)
        let place = try Self.wPlace()
        let later = [WxQuarter(tS: Self.tHour0 + 2700, precipMm: 1.0), WxQuarter(tS: Self.tHour0 + 3600, precipMm: 1.0)]
        #expect(!Self.chart(try WxForecast(place: place, generatedS: Self.wNow, quarters: later)).hasData)  // test-widgets.c:500
        let past = [WxQuarter(tS: Self.tHour0, precipMm: 1.0), WxQuarter(tS: Self.tHour0 + 900, precipMm: 1.0)]
        #expect(!Self.chart(try WxForecast(place: place, generatedS: Self.wNow, quarters: past)).hasData)  // test-widgets.c:504
        // hand-built quarters (wx_forecast_new() would refuse a NaN): the arrays directly
        let raw = { (q: [WxQuarter], now: Int64) in
            RainChartData(hours: [], quarters: q, units: .metric, nowS: now, view: .auto, zone: .utc)
        }
        #expect(!raw([WxQuarter(tS: Self.tHour0 + 1800, precipMm: .nan)], Self.wNow).hasData)  // test-widgets.c:509
        let ok = [WxQuarter(tS: Self.tHour0 + 1800, precipMm: 1.0)]
        #expect(raw(ok, Self.wNow).hasData)  // test-widgets.c:513
        #expect(raw(ok, Self.tHour0 + 1800 + 899).hasData)  // test-widgets.c:516
        #expect(!raw(ok, Self.tHour0 + 1800 + 900).hasData)  // test-widgets.c:518
        #expect(!raw(ok, Self.tHour0 + 1799).hasData)  // test-widgets.c:520
    }

    // C: /widgets/chart/fixed-views (test-widgets.c:533-627)
    @Test func chartFixedViews() throws {
        let withNC = try Self.makeForecast(Self.tHour0, 30, 12, 0)
        let without = try Self.makeForecast(Self.tHour0, 30, 0, 0)
        #expect(!RainChartData(view: .auto).hasData && !RainChartData(view: .hourly).hasData
                    && !RainChartData(view: .nowcast).hasData)  // test-widgets.c:546-548
        let autoHourly = Self.chart(without)
        let hourly = Self.chart(withNC, .metric, Self.wNow, .hourly)
        #expect(Self.sameDrawing(autoHourly, hourly))  // test-widgets.c:557
        #expect(Self.strokeNodes(hourly) == 1 && hourly.hasData)  // test-widgets.c:558-559
        let autoQuarters = Self.chart(withNC)
        let nowcast = Self.chart(withNC, .metric, Self.wNow, .nowcast)
        #expect(Self.sameDrawing(autoQuarters, nowcast))  // test-widgets.c:563
        #expect(Self.strokeNodes(nowcast) == 0 && nowcast.hasData)  // test-widgets.c:564-565
        #expect(!Self.sameDrawing(hourly, nowcast))  // test-widgets.c:566
        #expect(Self.sameDrawing(Self.chart(without, .metric, Self.wNow, .hourly), autoHourly))  // test-widgets.c:569-570
        let none = Self.chart(without, .metric, Self.wNow, .nowcast)
        #expect(!none.hasData)  // test-widgets.c:572
        #expect(Self.colorNodes(none) == 0 && Self.strokeNodes(none) == 0)  // test-widgets.c:574-576
        #expect(!Self.chart(nil, .metric, Self.wNow, .nowcast).hasData)  // test-widgets.c:579
        #expect(!Self.chart(nil, .metric, Self.wNow, .hourly).hasData)  // test-widgets.c:581
        #expect(Self.chart(withNC, .metric, Self.wNow, .nowcast).hasData)  // test-widgets.c:585
        #expect(!Self.chart(withNC, .metric, Self.tHour0 + 4 * 3600, .nowcast).hasData)  // test-widgets.c:587
    }

    // C: /widgets/chart/view-change-equal-first-slots (test-widgets.c:802-837)
    @Test func chartViewChangeWithEqualFirstSlots() throws {
        let place = try Self.wPlace()
        let qs = (0..<8).map { WxQuarter(tS: Self.tHour0 + Int64($0) * 900, precipMm: 0.0) }
        let hs = (0..<8).map { i -> WxBlendHour in
            var h = Self.wHour(Self.tHour0 + Int64(i) * 3600)
            h.precipMm = 0.0
            h.precipProb = .nan
            return h
        }
        let q = Self.chart(try WxForecast(place: place, generatedS: Self.wNow, quarters: qs), .metric, Self.tHour0)
        let h = Self.chart(try WxForecast(place: place, generatedS: Self.wNow, hours: hs), .metric, Self.tHour0)
        #expect(q != h)  // the view changed although slots 0..7 hold the same zeros, test-widgets.c:829-832
        #expect(!Self.sameDrawing(q, h))
    }

    // C: /widgets/chart/huge-inputs (test-widgets.c:954-1026)
    @Test func chartHugeInputs() throws {
        let place = try Self.wPlace()
        var hs = (0..<WxLimits.forecastMaxHours).map { i -> WxBlendHour in
            var h = Self.wHour(Self.tHour0 + Int64(i) * 3600)
            h.precipMm = 500.0
            h.precipProb = 100.0
            return h
        }
        let qs = (0..<WxLimits.forecastMaxQuarters).map { WxQuarter(tS: Self.tHour0 + Int64($0) * 900, precipMm: 500.0) }
        let fc = try WxForecast(place: place, generatedS: Self.wNow, hours: hs)
        let fq = try WxForecast(place: place, generatedS: Self.wNow, hours: hs, quarters: qs)
        let c = Self.chart(fc)
        #expect(Self.colorNodes(c) == 3 + RainChartData.hourSlots)  // test-widgets.c:981
        #expect(Self.strokeNodes(c) == 1)  // test-widgets.c:982
        #expect(c.axisLabels.count <= 5)  // test-widgets.c:983
        let cq = Self.chart(fq, .imperial)
        #expect(Self.colorNodes(cq) == 3 + RainChartData.quarterSlots)  // test-widgets.c:985
        #expect(RainChartData.hourSlots == 24 && RainChartData.quarterSlots == 8)
        for i in hs.indices {
            hs[i].precipMm = i % 2 == 1 ? .nan : -5.0
            hs[i].precipProb = i % 2 == 1 ? 1e300 : .infinity
        }
        #expect(!Self.chart(try WxForecast(place: place, generatedS: Self.wNow, hours: hs)).hasData)  // test-widgets.c:1000
        // hand-built: values wx_forecast_new() would have normalised (test-widgets.c:1002-1013)
        var raw = Array(hs.prefix(30))
        for i in raw.indices {
            raw[i].precipMm = i % 2 == 1 ? 1e300 : 500.0
            raw[i].precipProb = i % 2 == 1 ? -3 : 250
        }
        let rc = RainChartData(hours: raw, quarters: [], units: .metric, nowS: Self.wNow, view: .auto, zone: .utc)
        #expect(rc.hasData)  // test-widgets.c:1010
        #expect(Self.colorNodes(rc) == 3 + 12)  // test-widgets.c:1012
        #expect(Self.strokeNodes(rc) == 0)  // test-widgets.c:1013
        for now in [Int64.min, Int64.max, 0, -1, WxLimits.timeMaxS, WxLimits.timeMinS] {  // test-widgets.c:1016
            _ = Self.chart(fc, .metric, now).geometry(width: 360, height: 140, percentTopSize: (28, 15),
                                                      axisLabelWidths: [30, 30, 30, 30, 30])
            _ = Self.chart(fq, .metric, now)
        }
    }

    // C: /widgets/chart/narrow-skips-overlapping-labels (test-widgets.c:1029-1045)
    @Test func chartNarrowSkipsOverlappingLabels() throws {
        let fc = try Self.makeForecast(Self.tHour0, 30, 12, 0)
        let c = Self.chart(fc)
        let widths: [Float] = [28, 50, 50, 50, 50]  // "Now", "3:00 PM", ... at about 13 px per glyph pair
        let text = (width: Float(28), height: Float(15))
        let wide = try #require(c.geometry(width: 600, height: 200, percentTopSize: text, axisLabelWidths: widths))
        let narrow = try #require(c.geometry(width: Float(RainChartData.minimumSize.width), height: 96,
                                             percentTopSize: text, axisLabelWidths: widths))
        #expect(RainChartData.minimumSize.width == 160)  // test-widgets.c:1037
        #expect(wide.texts.count == 1 + 5)  // test-widgets.c:1040
        #expect(narrow.texts.count >= 1 + 1)  // test-widgets.c:1041
        #expect(narrow.texts.contains { $0.text == "Now" })
        #expect(narrow.texts.count < wide.texts.count)  // test-widgets.c:1042
    }

    // C: /widgets/chart/all-dry (test-widgets.c:1048-1063)
    @Test func chartAllDry() throws {
        let qs = (0..<8).map { WxQuarter(tS: Self.tHour0 + 1800 + Int64($0) * 900, precipMm: 0.0) }
        let c = Self.chart(try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow, quarters: qs))
        #expect(c.hasData)  // test-widgets.c:1058
        #expect(Self.colorNodes(c) == 3)  // test-widgets.c:1060
        #expect(Self.strokeNodes(c) == 0)  // test-widgets.c:1061
        // describe(): no amount above 0 (wx-rain-chart.c:307-308)
        #expect(c.accessibilityDescription == "Rain intensity every 15 minutes for the next 2 hours. No rain expected.")
    }

    // C: describe() of the hourly and the nowcast window (wx-rain-chart.c:280-316)
    @Test func chartAccessibleDescription() throws {
        let hourly = Self.chart(try Self.makeForecast(Self.tHour0 - 3600, 40, 0, 0), .imperial)
        // the highest chance (95 %) first at slot 8: 02:00Z = 10 PM in New York
        #expect(hourly.accessibilityDescription
                    == "Rain chance by hour for the next 24 hours. Highest chance: 95% at 10 PM.")
        let nowcast = Self.chart(try Self.makeForecast(Self.tHour0, 30, 12, 0))
        #expect(nowcast.accessibilityDescription
                    == "Rain intensity every 15 minutes for the next 2 hours. Heaviest: 2.0 mm per hour at the current time.")
        #expect(RainChartData.accessibilityLabel == "Rain chart")
    }

    // MARK: - Hour strip

    // C: /widgets/strip/basic (test-widgets.c:1202-1273)
    @Test func stripBasic() throws {
        #expect(Self.cards(nil, .imperial, Self.wNow).isEmpty)  // test-widgets.c:1209
        let fc = try Self.makeForecast(Self.tHour0 - 3600, 60, 0, 0)
        var c = Self.cards(fc, .imperial, Self.wNow)
        #expect(c.count == 48)  // test-widgets.c:1214
        #expect(c[0].hour == "Now")  // test-widgets.c:1218
        #expect(c[1].hour == "3 PM")  // test-widgets.c:1219
        #expect(c[47].hour == "1 PM")  // test-widgets.c:1220
        #expect(c[0].temp == "71\(Self.deg)")  // test-widgets.c:1224
        #expect(c[0].rain == "Rain 15%")  // test-widgets.c:1225
        #expect(c[0].cloud == "Cloud 40%")  // test-widgets.c:1226
        #expect(c[0].gtkIconName == "weather-few-clouds-symbolic")  // test-widgets.c:1227
        #expect(c[0].tooltip == "2:30 PM\nFeels like 81\(Self.deg)F\nWind 12 mph\nRain 0 in")  // test-widgets.c:1231
        c = Self.cards(fc, .metric, Self.wNow)
        #expect(c[0].temp == "22\(Self.deg)")  // test-widgets.c:1235
        #expect(c[0].tooltip == "2:30 PM\nFeels like 27\(Self.deg)C\nWind 19 km/h\nRain 0 mm")  // test-widgets.c:1236
        let few = Self.cards(try Self.makeForecast(Self.tHour0, 3, 0, 0), .metric, Self.wNow)
        #expect(few.count == 3)  // test-widgets.c:1241
        #expect(few[2].hour == "4 PM")  // test-widgets.c:1242
        c = Self.cards(fc, .metric, Self.wNow)
        #expect(c.count == 48 && c[47].hour == "1 PM")  // test-widgets.c:1244-1245
        c = Self.cards(fc, .metric, Self.wNow + 3600)
        #expect(c.count == 48)  // test-widgets.c:1249
        #expect(c[0].hour == "Now" && c[1].hour == "4 PM")  // test-widgets.c:1250-1251
        c = Self.cards(fc, .metric, Self.tHour0 + 3600)
        #expect(c[0].hour == "Now" && c[1].hour == "4 PM")  // test-widgets.c:1254-1255
        c = Self.cards(fc, .metric, Self.tHour0 - 3 * 3600)
        #expect(c[0].hour == "1 PM" && !c[0].isNow)  // test-widgets.c:1258
        #expect(Self.cards(fc, .metric, Self.tHour0 + 55 * 3600).count == 4)  // test-widgets.c:1262
        #expect(Self.cards(nil, .metric, Self.wNow).isEmpty)  // test-widgets.c:1266
        for now in [0, Int64.max, Int64.min, WxLimits.timeMaxS] {  // test-widgets.c:1267
            #expect(Self.cards(fc, .metric, now).isEmpty, "now \(now)")  // test-widgets.c:1270
        }
    }

    // C: /widgets/strip/missing-values (test-widgets.c:1275-1298)
    @Test func stripMissingValues() throws {
        let night = Self.ts(2026, 10, 12, 4, 0)
        var h = Self.wHour(night)
        h.tempC = .nan
        h.precipProb = .nan
        h.cloudPct = .nan
        h.isDay = false
        h.condition = .clear
        let fc = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow, hours: [h])
        let c0 = try #require(Self.cards(fc, .metric, night + 1800).first)
        #expect(c0.temp == Self.dash)  // test-widgets.c:1293
        #expect(c0.rain == "Rain " + Self.dash)  // test-widgets.c:1294
        #expect(c0.cloud == "Cloud " + Self.dash)  // test-widgets.c:1295
        #expect(c0.gtkIconName == "weather-clear-night-symbolic")  // test-widgets.c:1296
    }

    // C: /widgets/strip/compare-before-set (test-widgets.c:1301-1342): the data parts
    @Test func stripCompareBeforeSetData() throws {
        let fc = try Self.makeForecast(Self.tHour0, 10, 0, 0)
        let same = try Self.makeForecast(Self.tHour0, 10, 0, 0)
        // the cards after "Now" are unchanged (the Now card's clock moves with now), test-widgets.c:1312-1315
        #expect(Array(Self.cards(fc, .metric, Self.wNow).dropFirst())
                    == Array(Self.cards(same, .metric, Self.wNow + 100).dropFirst()))
        #expect(Self.cards(fc, .metric, Self.wNow) == Self.cards(same, .metric, Self.wNow))
        let utc = Self.cards(try Self.makeForecast(Self.tHour0, 10, 0, 0, tz: "UTC"), .metric, Self.wNow)
        #expect(utc[1].hour == "7 PM")  // test-widgets.c:1321
        var hs = (0..<10).map { i -> WxBlendHour in
            var h = Self.wHour(Self.tHour0 + Int64(i) * 3600)
            h.precipMm = i % 3 == 0 ? 1.5 : 0.0
            h.precipProb = 10.0 * Double(i % 10) + 5.0
            h.tempC = 20.0 + Double(i % 10)
            return h
        }
        hs[1].tempC = 99 - 40  // card 1 only (test-widgets.c:1335)
        let changed = Self.cards(try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow, hours: hs),
                                 .imperial, Self.wNow)
        #expect(changed[1].temp == "138\(Self.deg)")  // test-widgets.c:1339
        #expect(changed[2] == Self.cards(fc, .imperial, Self.wNow)[2])  // unchanged card, test-widgets.c:1340
    }

    // C: /widgets/no-zone-resolution-at-draw-time (test-widgets.c:879-951): the strip's labels
    // in the held Pacific/Chatham zone
    @Test func stripLabelsInHeldZone() throws {
        var hs = (0..<30).map { Self.wHour(Self.tHour0 + Int64($0) * 3600) }  // make_wet_or_dry_forecast (test-widgets.c:856-877)
        for i in hs.indices {
            hs[i].precipMm = 2.0
            hs[i].precipProb = 80.0
        }
        let fs = try WxForecast(place: try Self.wPlace("Pacific/Chatham"), generatedS: Self.wNow, hours: hs)
        var held = WxFormat.HeldZone()
        let changed = held.update("Pacific/Chatham")
        #expect(changed && held.resolved)
        let c = DetailViewModel.HourCard.cards(forecast: fs, units: .imperial, nowS: Self.wNow + 3600, zone: held.zone)
        #expect(c[1].hour == "9:45 AM")  // 20:00Z in Chatham, +13:45 (test-widgets.c:930)
    }

    // MARK: - Day list

    // C: /widgets/days/basic (test-widgets.c:1393-1450)
    @Test func daysBasic() throws {
        #expect(DetailViewModel.DayRow.maxRows == 10)
        let fc = try Self.makeForecast(Self.tHour0, 10, 0, 16)
        var r = Self.rows(fc, .imperial, Self.wNow)
        #expect(r.count == 10)  // test-widgets.c:1404
        #expect(r[0].day == "Today")  // test-widgets.c:1408
        #expect(r[1].day == "Tomorrow")  // test-widgets.c:1409
        #expect(r[2].day == "Tuesday")  // test-widgets.c:1410
        #expect(r[9].day == "Tuesday")  // test-widgets.c:1411
        #expect(r[0].high == "86\(Self.deg)")  // test-widgets.c:1413
        #expect(r[0].low == "68\(Self.deg)")  // test-widgets.c:1414
        #expect(r[0].rain == "0%")  // test-widgets.c:1415
        #expect(r[1].rain == "10%")  // test-widgets.c:1416
        #expect(r[1].high == "88\(Self.deg)")  // test-widgets.c:1417
        #expect(r[1].gtkIconName == "weather-showers-symbolic")  // test-widgets.c:1418
        #expect(r[1].symbolName == WxConditionSymbol.symbolName(.rain, isDay: true))
        #expect(r[1].tooltip == "Rain 0.08 in, 10% chance\nCloud cover 50%")  // test-widgets.c:1419
        // the forecast starts at 2 PM: today covers the rest of the day (wx-day-list.h:10-14)
        #expect(r[0].tooltip == "Rain 0 in, 0% chance\nCloud cover 50%\nCovers the rest of the day, from 2 PM.")
        r = Self.rows(fc, .metric, Self.wNow)
        #expect(r[0].high == "30\(Self.deg)")  // test-widgets.c:1422
        #expect(r[1].tooltip == "Rain 2.0 mm, 10% chance\nCloud cover 50%")  // test-widgets.c:1423
        r = Self.rows(fc, .metric, Self.ts(2026, 10, 12, 4, 0))
        #expect(r[0].day == "Today" && r[0].high == "31\(Self.deg)")  // test-widgets.c:1427-1428
        #expect(Self.rows(fc, .metric, Self.ts(2026, 10, 12, 3, 59))[0].high == "30\(Self.deg)")  // test-widgets.c:1430
        let three = try Self.makeForecast(Self.tHour0, 10, 0, 3)
        let lastStart = Self.ts(2026, 10, 11, 4, 0) + 2 * 86400
        #expect(Self.rows(three, .metric, lastStart + 24 * 3600 - 1).count == 1)  // test-widgets.c:1436
        #expect(Self.rows(three, .metric, lastStart + 24 * 3600).isEmpty)  // test-widgets.c:1438
        #expect(Self.rows(three, .metric, Self.wNow).count == 3)  // test-widgets.c:1440
        #expect(Self.rows(nil, .metric, Self.wNow).isEmpty)  // test-widgets.c:1443
        for now in [0, Int64.max, Int64.min, WxLimits.timeMaxS] {  // test-widgets.c:1444
            #expect(Self.rows(fc, .metric, now).isEmpty, "now \(now)")  // test-widgets.c:1447
        }
    }

    /// A day of the hand-built day tests (test-widgets.c:1460-1462 and following).
    private static func clearDay(_ startS: Int64, _ hi: Double = 20, _ lo: Double = 10) -> WxDay {
        WxDay(startS: startS, tempMaxC: hi, tempMinC: lo, precipMm: 0, precipProbMax: 0, cloudPct: 0, condition: .clear)
    }

    // C: /widgets/days/gap-day (test-widgets.c:1453-1491)
    @Test func daysGapDay() throws {
        let sun = Self.ts(2026, 10, 11, 4, 0)
        let fc = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow,
                                days: [Self.clearDay(sun), Self.clearDay(sun + 2 * 86400), Self.clearDay(sun + 3 * 86400)])
        let monNoon = Self.ts(2026, 10, 12, 16, 0)
        var r = Self.rows(fc, .metric, monNoon)
        #expect(r.count == 2)  // test-widgets.c:1470
        #expect(r.map(\.day) == ["Tomorrow", "Wednesday"])  // test-widgets.c:1471-1472
        r = Self.rows(fc, .metric, sun + 2 * 86400)
        #expect(r.count == 2)  // test-widgets.c:1475
        #expect(r.map(\.day) == ["Today", "Tomorrow"])  // test-widgets.c:1476-1477
        #expect(Self.rows(fc, .metric, monNoon).first?.day == "Tomorrow")  // test-widgets.c:1479
        r = Self.rows(fc, .metric, sun + 86400 - 1)
        #expect(r.count == 3)  // test-widgets.c:1482
        #expect(r[0].day == "Today" && r[1].day == "Tuesday")  // test-widgets.c:1483-1484
        #expect(Self.rows(fc, .metric, sun + 86400).count == 2)  // test-widgets.c:1486
        #expect(Self.rows(fc, .metric, sun + 4 * 86400).isEmpty)  // test-widgets.c:1489
    }

    // C: /widgets/days/dst-day (test-widgets.c:1494-1516)
    @Test func daysDSTDay() throws {
        let fc = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow,
                                days: [Self.clearDay(Self.ts(2026, 11, 1, 4, 0))])
        #expect(Self.rows(fc, .metric, Self.ts(2026, 11, 2, 4, 59)).count == 1)  // test-widgets.c:1504
        #expect(Self.rows(fc, .metric, Self.ts(2026, 11, 2, 5, 0)).isEmpty)  // test-widgets.c:1506
    }

    // C: /widgets/days/zone-change (test-widgets.c:1519-1556)
    @Test func daysZoneChange() throws {
        let fUTC = try WxForecast(place: try Self.wPlace("UTC"), generatedS: Self.wNow,
                                  days: [Self.clearDay(Self.ts(2026, 10, 11, 0, 0)), Self.clearDay(Self.ts(2026, 10, 12, 0, 0))])
        let fNY = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow,
                                 days: [Self.clearDay(Self.ts(2026, 10, 11, 4, 0)), Self.clearDay(Self.ts(2026, 10, 12, 4, 0))])
        let now = Self.ts(2026, 10, 12, 3, 0)
        #expect(Self.rows(fNY, .metric, now).map(\.day) == ["Today", "Tomorrow"])  // test-widgets.c:1537-1538
        let u = Self.rows(fUTC, .metric, now)
        #expect(u.count == 1)  // test-widgets.c:1540
        #expect(u.first?.day == "Today")  // test-widgets.c:1541
        let one = Self.clearDay(Self.ts(2026, 10, 11, 4, 0))
        let oneNY = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow, days: [one])
        let oneUTC = try WxForecast(place: try Self.wPlace("UTC"), generatedS: Self.wNow, days: [one])
        let at = Self.ts(2026, 10, 11, 3, 0)
        #expect(Self.rows(oneNY, .metric, at).first?.day == "Tomorrow")  // test-widgets.c:1550
        #expect(Self.rows(oneUTC, .metric, at).first?.day == "Today")  // test-widgets.c:1552
        #expect(Self.rows(oneNY, .metric, at).first?.day == "Tomorrow")  // test-widgets.c:1554
    }

    // C: /widgets/days/repeated-midnight (test-widgets.c:1560-1590)
    @Test func daysRepeatedMidnight() throws {
        let fc = try WxForecast(place: try Self.wPlace("Atlantic/Azores"), generatedS: Self.wNow,
                                days: [Self.clearDay(Self.ts(2026, 10, 24, 0, 0)), Self.clearDay(Self.ts(2026, 10, 25, 0, 0)),
                                       Self.clearDay(Self.ts(2026, 10, 26, 1, 0))])
        var r = Self.rows(fc, .metric, Self.ts(2026, 10, 24, 23, 59))
        #expect(r.count == 3 && r[0].day == "Today")  // test-widgets.c:1575-1576
        r = Self.rows(fc, .metric, Self.ts(2026, 10, 25, 0, 15))
        #expect(r.count == 2)  // test-widgets.c:1578
        #expect(r.map(\.day) == ["Today", "Tomorrow"])  // test-widgets.c:1579-1580
        #expect(r[0].high == "20\(Self.deg)")  // test-widgets.c:1581
        r = Self.rows(fc, .metric, Self.ts(2026, 10, 25, 1, 30))
        #expect(r.count == 2 && r[0].day == "Today")  // test-widgets.c:1584-1585
        #expect(Self.rows(fc, .metric, Self.ts(2026, 10, 25, 0, 0)).count == 2)  // test-widgets.c:1588
    }

    // C: /widgets/days/repeated-midnight-havana (test-widgets.c:1594-1618)
    @Test func daysRepeatedMidnightHavana() throws {
        let fc = try WxForecast(place: try Self.wPlace("America/Havana"), generatedS: Self.wNow,
                                days: [Self.clearDay(Self.ts(2026, 10, 31, 4, 0), 25, 18),
                                       Self.clearDay(Self.ts(2026, 11, 1, 4, 0), 25, 18),
                                       Self.clearDay(Self.ts(2026, 11, 2, 5, 0), 25, 18)])
        var r = Self.rows(fc, .metric, Self.ts(2026, 11, 1, 3, 59))
        #expect(r.count == 3 && r[0].day == "Today")  // test-widgets.c:1608-1609
        r = Self.rows(fc, .metric, Self.ts(2026, 11, 1, 4, 30))
        #expect(r.count == 2)  // test-widgets.c:1611
        #expect(r.map(\.day) == ["Today", "Tomorrow"])  // test-widgets.c:1612-1613
        r = Self.rows(fc, .metric, Self.ts(2026, 11, 1, 5, 30))
        #expect(r.count == 2 && r[0].day == "Today")  // test-widgets.c:1615-1616
    }

    // C: /widgets/days/missing-values (test-widgets.c:1620-1637)
    @Test func daysMissingValues() throws {
        let d = WxDay(startS: Self.ts(2026, 10, 11, 4, 0))
        let fc = try WxForecast(place: try Self.wPlace(), generatedS: Self.wNow, days: [d])
        let r0 = try #require(Self.rows(fc, .metric, Self.wNow).first)
        #expect(r0.high == Self.dash)  // test-widgets.c:1631
        #expect(r0.low == Self.dash)  // test-widgets.c:1632
        #expect(r0.rain == Self.dash)  // test-widgets.c:1633
        #expect(r0.gtkIconName == "dialog-question-symbolic")  // test-widgets.c:1634
        #expect(r0.tooltip == "Rain \(Self.dash), \(Self.dash) chance\nCloud cover \(Self.dash)")  // test-widgets.c:1635
    }

    // C: /widgets/days/compare-before-set (test-widgets.c:1639-1664): the data parts
    @Test func daysCompareBeforeSetData() throws {
        let fc = try Self.makeForecast(Self.tHour0, 10, 0, 5)
        let same = try Self.makeForecast(Self.tHour0, 10, 0, 5)
        #expect(Self.rows(fc, .metric, Self.wNow) == Self.rows(same, .metric, Self.wNow + 600))  // test-widgets.c:1650-1651
        #expect(Self.rows(fc, .metric, Self.wNow) == Self.rows(same, .metric, Self.wNow + 3 * 900))  // test-widgets.c:1653-1654
        let r = Self.rows(fc, .imperial, Self.wNow)
        #expect(r[3].high == "91\(Self.deg)")  // test-widgets.c:1656
        #expect(r[0].day == "Today")  // test-widgets.c:1659
        let next = Self.rows(fc, .imperial, Self.ts(2026, 10, 12, 4, 0))
        #expect(next[0].day == "Today" && next[1].day == "Tomorrow")  // test-widgets.c:1661-1662
    }
}
