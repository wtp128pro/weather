// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ChartData.swift - the data of the rain chart (src/widgets/wx-rain-chart.{h,c}):
// the copied window of the next 24 hours (or 2 hours of 15-minute nowcast
// quarters), its vertical scale, the time-axis labels, the accessible
// description and the drawing geometry of wx_rain_chart_snapshot(), so that a
// SwiftUI Canvas only paints what this type computed.
//
// Window (build_window, wx-rain-chart.c:148-189): "now" outside
// [WxLimits.timeMinS, WxLimits.timeMaxS) or no forecast gives no slots. The
// 15-minute view is used when the view is not .hourly and the forecast holds a
// quarter starting exactly at the 15-minute slot of "now" with an amount in
// [0, precipMaxMmH] (nowcast_covers, :112-118); .nowcast without such a quarter
// gives no slots. Hourly: 24 slots, one per UTC hour from the hour of "now";
// the bar is the hour's expected rain RATE precipMm (mm/h), the line its
// chance precipProb. Quarters: 8 slots; the bar is amount x 4 (a rate); no
// chance. Values outside their valid range are NaN (a gap). The arrays are
// scanned in order and the scan stops at the first entry past the window, as
// in C.
//
// Scale (window_scale, :202-212): 2.5 mm/h (metric) or 0.1 in/h = 2.54 mm/h
// (imperial), doubled at most 24 times until the largest finite bar fits.
//
// Everything is computed with a held zone (WxFormat.Zone): no zone is looked up
// while drawing. Pure value type; no clock, no I/O.

/// The rain chart's data and drawing geometry (WxRainChart).
public struct RainChartData: Sendable, Equatable {
    /// WxRainChartView (wx-rain-chart.h:75-80).
    public enum View: Sendable, Equatable {
        /// 15-minute view while the nowcast covers "now", else hourly.
        case auto
        /// Always the next 24 hours, hour by hour.
        case hourly
        /// The next 2 hours in 15 minutes, only while the nowcast covers "now".
        case nowcast
    }

    /// A point of the drawing, in the widget's coordinates (GTK floats).
    public struct Point: Sendable, Equatable {
        public let x: Float
        public let y: Float
    }

    /// A filled rectangle of the drawing (fill_rect).
    public struct Rect: Sendable, Equatable {
        public let x: Float
        public let y: Float
        public let width: Float
        public let height: Float
    }

    /// One time-axis label candidate: the slot it names and its text.
    public struct AxisLabel: Sendable, Equatable {
        public let slot: Int
        public let text: String
    }

    /// A text placed by the geometry: its text and its top-left corner.
    public struct PlacedText: Sendable, Equatable {
        public let text: String
        public let origin: Point
    }

    /// What wx_rain_chart_snapshot() draws for a chart that has data.
    public struct Geometry: Sendable, Equatable {
        /// The plot area (px, py, pw, ph).
        public let plot: Rect
        /// Grid lines at the bottom, the middle and the top (alpha `gridAlpha` of the parent colour).
        public let gridLines: [Rect]
        /// One bar per slot with a rate > 0 (the CSS colour, accent fallback `barFallbackColorHex`).
        public let bars: [Rect]
        /// The chance line (hourly view only): runs of at least two consecutive known chances.
        public let lineRuns: [[Point]]
        /// A known chance without a known neighbour: a 3x3 square instead of a line.
        public let loneSquares: [Rect]
        /// "<top of scale>/h" inside the plot, then "100%" and "0%" on the right (hourly only),
        /// then the time labels that do not overlap; every one dimmed (alpha `dimAlpha`).
        public let texts: [PlacedText]
    }

    /// WX_RAIN_CHART_HOURS (wx-rain-chart.h:69).
    public static let hourSlots = 24
    /// WX_RAIN_CHART_QUARTER_SLOTS (wx-rain-chart.h:72).
    public static let quarterSlots = 8
    /// MAX_X_LABELS (wx-rain-chart.c:25).
    public static let maxAxisLabels = 5
    /// The accessible label of the chart (wx-rain-chart.c:721-722); its role is image.
    public static let accessibilityLabel = "Rain chart"
    /// The text drawn without data (wx-rain-chart.c:514).
    public static let noDataText = "No data"
    /// Labels of the chance scale on the right (hourly view, wx-rain-chart.c:532-533).
    public static let percentTopText = "100%"
    public static let percentMidText = "50%"
    public static let percentBottomText = "0%"
    /// Baseline label of the rain-rate scale on the left.
    public static let rateZeroText = "0"
    /// MIN_WIDTH/MIN_HEIGHT, NAT_WIDTH/NAT_HEIGHT (wx-rain-chart.c:19-22).
    public static let minimumSize = (width: 160, height: 96)
    public static let naturalSize = (width: 360, height: 140)
    /// Alpha of the dimmed labels and of the grid (wx-rain-chart.c:505-508).
    public static let dimAlpha: Float = 0.6
    public static let gridAlpha: Float = 0.2
    /// Bar width as a fraction of the slot (wx-rain-chart.c:552).
    public static let barWidthFraction: Float = 0.7
    /// The fallback bar colour (wx-rain-chart.c:680-681).
    public static let barFallbackColorHex = "#3584e4"

    /// The view the window was built for.
    public let view: View
    /// 15-minute slots (the nowcast) instead of hours.
    public let isQuarters: Bool
    /// Start of slot 0, UTC unix seconds (0 without slots).
    public let startS: Int64
    /// Rain rate of each slot in mm/h, NaN = no value; empty without slots.
    public let rateMmH: [Double]
    /// Chance of rain of each slot in percent, NaN = no value; empty without slots.
    public let probability: [Double]
    /// The unit system of the labels.
    public let units: WxUnits
    /// window_has_data: some slot has a rate or a chance ("No data" otherwise).
    public let hasData: Bool
    /// Top of the bar scale in mm/h.
    public let scaleTopMmH: Double
    /// The top-of-scale label, "<precip>/h" (wx-rain-chart.c:528-529).
    public let scaleLabel: String
    /// The 5 time-axis candidates in drawing order (slots 0 6 12 17 23 / 0 2 4 5 7); empty without data.
    public let axisLabels: [AxisLabel]
    /// The accessible description (describe, wx-rain-chart.c:280-316).
    public let accessibilityDescription: String

    /// A chart without data ("No data", wx_rain_chart_new / set_forecast(NULL)).
    public init(view: View = .auto, units: WxUnits = .imperial) {
        self.init(window: Window(isQuarters: false, startS: 0, mmh: [], prob: []), view: view, units: units,
                  zone: .utc)
    }

    /// wx_rain_chart_set_forecast: the window of `view` at `nowS`, formatted with `zone` (the
    /// held zone of `forecast.place.timezone`).
    public init(forecast: WxForecast?, units: WxUnits, nowS: Int64, view: View, zone: WxFormat.Zone) {
        guard let forecast else {
            self.init(view: view, units: units)
            return
        }
        self.init(hours: forecast.hours, quarters: forecast.quarters, units: units, nowS: nowS, view: view,
                  zone: zone)
    }

    /// The window over hand-built arrays (any order, any values: the range checks of
    /// build_window are applied here as in C).
    init(hours: [WxBlendHour], quarters: [WxQuarter], units: WxUnits, nowS: Int64, view: View,
         zone: WxFormat.Zone) {
        self.init(window: Self.buildWindow(hours: hours, quarters: quarters, nowS: nowS, view: view),
                  view: view, units: units, zone: zone)
    }

    private init(window: Window, view: View, units: WxUnits, zone: WxFormat.Zone) {
        self.view = view
        isQuarters = window.isQuarters
        startS = window.startS
        rateMmH = window.mmh
        probability = window.prob
        self.units = units
        let has = zip(window.mmh, window.prob).contains { !$0.isNaN || !$1.isNaN }
        hasData = has
        let top = Self.scale(window.mmh, units: units)
        scaleTopMmH = top
        scaleLabel = WxFormat.precip(top, units: units) + "/h"
        let n = window.mmh.count
        var labels: [AxisLabel] = []
        if has {
            for k in 0..<Self.maxAxisLabels {
                let slot = Int((Double(k) * Double(n - 1) / Double(Self.maxAxisLabels - 1))
                    .rounded(.toNearestOrAwayFromZero))  // lround
                labels.append(AxisLabel(slot: slot, text: Self.slotLabel(window, slot, zone)))
            }
        }
        axisLabels = labels
        accessibilityDescription = Self.describe(window, has: has, units: units, zone: zone)
    }

    /// Number of slots: 0 without a window, 24 hourly, 8 quarters.
    public var slotCount: Int { rateMmH.count }

    /// The chance line is drawn (the hourly view of a chart with data).
    public var showsProbabilityLine: Bool { hasData && !isQuarters }

    /// The midpoint label of the left rain-rate scale (`scaleTopMmH / 2`).
    public var midScaleLabel: String {
        WxFormat.precip(scaleTopMmH * 0.5, units: units) + "/h"
    }

    /// Short unit string for the rain-rate scale (`"in/h"` or `"mm/h"`).
    public var rateUnitShort: String {
        units == .imperial ? "in/h" : "mm/h"
    }

    /// Formatted rain rate for a specific slot (e.g. `"0.06 in/h"` or `"1.5 mm/h"`), or `nil` if dry/unknown.
    public func formattedRate(forSlot slot: Int) -> String? {
        guard rateMmH.indices.contains(slot) else { return nil }
        let mmh = rateMmH[slot]
        guard mmh.isFinite, mmh > 0 else { return nil }
        return WxFormat.precip(mmh, units: units) + "/h"
    }

    /// Compact numeric value for a bar callout on the canvas (e.g. `"0.06 in"` or `"1.5 mm"`).
    public func compactBarLabel(forSlot slot: Int) -> String? {
        guard rateMmH.indices.contains(slot) else { return nil }
        let mmh = rateMmH[slot]
        guard mmh.isFinite, mmh > 0 else { return nil }
        return WxFormat.precip(mmh, units: units) + "/h"
    }

    /// Formatted probability percentage for a specific slot (e.g. `"80%"`), or `nil` if unknown.
    public func formattedProbability(forSlot slot: Int) -> String? {
        guard probability.indices.contains(slot) else { return nil }
        let p = probability[slot]
        guard p.isFinite, p >= 0 else { return nil }
        return WxFormat.percent(p)
    }

    /// The slots that get a bar: a known rate above 0.
    public var barSlots: [Int] {
        guard hasData else {
            return []
        }
        return rateMmH.indices.filter { !rateMmH[$0].isNaN && rateMmH[$0] > 0.0 }
    }

    /// The slots of the chance line, as runs of at least two consecutive known chances.
    public var probabilityRuns: [[Int]] {
        guard showsProbabilityLine else {
            return []
        }
        var runs: [[Int]] = []
        var run: [Int] = []
        for i in probability.indices {
            if probability[i].isNaN {
                if run.count >= 2 {
                    runs.append(run)
                }
                run = []
            } else {
                run.append(i)
            }
        }
        if run.count >= 2 {
            runs.append(run)
        }
        return runs
    }

    /// The slots whose known chance has no known neighbour (drawn as a square).
    public var loneProbabilitySlots: [Int] {
        guard showsProbabilityLine else {
            return []
        }
        return probability.indices.filter { i in
            !probability[i].isNaN && !(i > 0 && !probability[i - 1].isNaN)
                && !(i + 1 < probability.count && !probability[i + 1].isNaN)
        }
    }

    /// wx_rain_chart_snapshot (wx-rain-chart.c:490-589) for a widget of `width` x `height`:
    /// `percentTopSize` is the measured size of "100%" (its height is the text height of
    /// every label) and `axisLabelWidths[k]` the measured width of `axisLabels[k].text`.
    /// nil when nothing but "No data" (or nothing at all) is drawn: no data, no size, or a plot
    /// of at most 1 px.
    public func geometry(width w: Float, height h: Float, percentTopSize: (width: Float, height: Float),
                         axisLabelWidths: [Float]) -> Geometry? {
        guard hasData, w > 0, h > 0 else {
            return nil
        }
        let pad: Float = 3, gap: Float = 4  // PAD, LABEL_GAP (wx-rain-chart.c:26-27)
        let hourly = !isQuarters
        let tw = percentTopSize.width, th = percentTopSize.height
        let right: Float = hourly ? tw + gap : 0
        let axisH = th + gap
        let px: Float = 0, pw = w - right
        let py = pad, y1 = h - axisH
        let ph = y1 - py
        guard pw > 1, ph > 1 else {
            return nil
        }
        let grid = [Rect(x: px, y: y1 - 1, width: pw, height: 1),
                    Rect(x: px, y: py + ph / 2, width: pw, height: 1),
                    Rect(x: px, y: py, width: pw, height: 1)]
        let n = Float(slotCount)
        let sw = pw / n
        let bw = max(1, sw * Self.barWidthFraction)
        var bars: [Rect] = []
        for i in rateMmH.indices where !rateMmH[i].isNaN && rateMmH[i] > 0.0 {
            let bh = min(ph, max(1, Float(rateMmH[i] / scaleTopMmH) * ph))
            bars.append(Rect(x: px + Float(i) * sw + (sw - bw) / 2, y: y1 - bh, width: bw, height: bh))
        }
        var runs: [[Point]] = []
        var lone: [Rect] = []
        if hourly {
            var run: [Point] = []
            for i in probability.indices {
                if probability[i].isNaN {
                    continue
                }
                let x = px + Float(i) * sw + sw / 2
                let y = y1 - Float(probability[i] / 100.0) * ph
                let prev = i > 0 && !probability[i - 1].isNaN
                let next = i + 1 < probability.count && !probability[i + 1].isNaN
                if !prev && !next {
                    lone.append(Rect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                    continue
                }
                if !prev && !run.isEmpty {
                    runs.append(run)
                    run = []
                }
                run.append(Point(x: x, y: y))
            }
            if !run.isEmpty {
                runs.append(run)
            }
        }
        var texts = [PlacedText(text: scaleLabel, origin: Point(x: px + 2, y: py + 1))]
        if hourly {
            texts.append(PlacedText(text: Self.percentTopText, origin: Point(x: pw + gap, y: py - 1)))
            texts.append(PlacedText(text: Self.percentBottomText, origin: Point(x: pw + gap, y: y1 - th)))
        }
        var lastRight: Float = -gap
        for (k, label) in axisLabels.enumerated() {
            let lw = k < axisLabelWidths.count ? axisLabelWidths[k] : 0
            let cx = px + Float(label.slot) * sw + sw / 2
            let x = min(max(0, cx - lw / 2), w - lw)
            if x < lastRight + gap {
                continue
            }
            texts.append(PlacedText(text: label.text, origin: Point(x: x.rounded(.down), y: y1 + 2)))
            lastRight = x + lw
        }
        return Geometry(plot: Rect(x: px, y: py, width: pw, height: ph), gridLines: grid, bars: bars,
                        lineRuns: runs, loneSquares: lone, texts: texts)
    }

    /// window_equal (wx-rain-chart.c:86-95) plus the view, the units and the derived texts:
    /// NaN equals NaN.
    public static func == (a: RainChartData, b: RainChartData) -> Bool {
        a.view == b.view && a.isQuarters == b.isQuarters && a.startS == b.startS && a.units == b.units
            && a.rateMmH.count == b.rateMmH.count && a.probability.count == b.probability.count
            && zip(a.rateMmH, b.rateMmH).allSatisfy { WxFormat.sameValue($0, $1) }
            && zip(a.probability, b.probability).allSatisfy { WxFormat.sameValue($0, $1) }
            && a.hasData == b.hasData && WxFormat.sameValue(a.scaleTopMmH, b.scaleTopMmH)
            && a.scaleLabel == b.scaleLabel && a.axisLabels == b.axisLabels
            && a.accessibilityDescription == b.accessibilityDescription
    }

    // MARK: - Private

    /// The copied window (Window, wx-rain-chart.c:45-51).
    private struct Window {
        var isQuarters: Bool
        var startS: Int64
        var mmh: [Double]
        var prob: [Double]
    }

    /// BASE_SCALE_MM_H, BASE_SCALE_IN_H, MAX_SCALE_DOUBLINGS (wx-rain-chart.c:31-33).
    private static let baseScaleMmH = 2.5
    private static let baseScaleInH = 0.1
    private static let maxScaleDoublings = 24

    /// build_window (wx-rain-chart.c:148-189).
    private static func buildWindow(hours: [WxBlendHour], quarters: [WxQuarter], nowS: Int64,
                                    view: View) -> Window {
        let empty = Window(isQuarters: false, startS: 0, mmh: [], prob: [])
        guard nowS >= WxLimits.timeMinS && nowS < WxLimits.timeMaxS else {
            return empty
        }
        let useQuarters = view != .hourly && nowcastCovers(quarters, nowS - nowS % 900)
        if view == .nowcast && !useQuarters {
            return Window(isQuarters: false, startS: 0, mmh: [], prob: [])
        }
        let step: Int64 = useQuarters ? 900 : 3600
        let slots = useQuarters ? quarterSlots : hourSlots
        let start = nowS - nowS % step
        var mmh = [Double](repeating: .nan, count: slots)
        var prob = [Double](repeating: .nan, count: slots)
        let end = start + Int64(slots) * step
        if !useQuarters {
            var k = 0
            while k < hours.count && hours[k].tS < end {
                let h = hours[k]
                k += 1
                if h.tS < start {
                    continue
                }
                let i = Int((h.tS - start) / step)
                mmh[i] = WxLimits.valueInRange(h.precipMm, 0.0, WxLimits.precipMaxMmH) ? h.precipMm : .nan
                prob[i] = WxLimits.valueInRange(h.precipProb, WxLimits.percentMin, WxLimits.percentMax)
                    ? h.precipProb : .nan
            }
        } else {
            var k = 0
            while k < quarters.count && quarters[k].tS < end {
                let q = quarters[k]
                k += 1
                if q.tS < start {
                    continue
                }
                let i = Int((q.tS - start) / step)
                mmh[i] = WxLimits.valueInRange(q.precipMm, 0.0, WxLimits.precipMaxMmH) ? q.precipMm * 4.0 : .nan
            }
        }
        return Window(isQuarters: useQuarters, startS: start, mmh: mmh, prob: prob)
    }

    /// nowcast_covers (wx-rain-chart.c:112-118).
    private static func nowcastCovers(_ quarters: [WxQuarter], _ quarterS: Int64) -> Bool {
        var k = 0
        while k < quarters.count && quarters[k].tS <= quarterS {
            if quarters[k].tS == quarterS {
                return WxLimits.valueInRange(quarters[k].precipMm, 0.0, WxLimits.precipMaxMmH)
            }
            k += 1
        }
        return false
    }

    /// window_scale (wx-rain-chart.c:202-212).
    private static func scale(_ mmh: [Double], units: WxUnits) -> Double {
        var top = units == .metric ? baseScaleMmH : baseScaleInH * 25.4
        var maxV = 0.0
        for v in mmh where v > maxV {
            maxV = v
        }
        var k = 0
        while k < maxScaleDoublings && top < maxV {
            top *= 2.0
            k += 1
        }
        return top
    }

    /// slot_label (wx-rain-chart.c:255-263).
    private static func slotLabel(_ w: Window, _ i: Int, _ zone: WxFormat.Zone) -> String {
        if i == 0 {
            return "Now"
        }
        if !w.isQuarters {
            return WxFormat.hourLabel(w.startS + Int64(i) * 3600, zone: zone)
        }
        return WxFormat.clock(w.startS + Int64(i) * 900, zone: zone)
    }

    /// describe (wx-rain-chart.c:280-316).
    private static func describe(_ w: Window, has: Bool, units: WxUnits, zone: WxFormat.Zone) -> String {
        if !has {
            return "No rain data."
        }
        let hourly = !w.isQuarters
        var span = hourly ? "Rain chance by hour for the next 24 hours."
            : "Rain intensity every 15 minutes for the next 2 hours."
        var best = 0
        var useProb = false
        var bestV = -1.0
        if hourly {
            for i in w.prob.indices where !w.prob[i].isNaN && w.prob[i] > bestV {
                bestV = w.prob[i]
                best = i
                useProb = true
            }
        }
        if !useProb {
            if hourly {
                span = "Rain amount by hour for the next 24 hours."
            }
            for i in w.mmh.indices where !w.mmh[i].isNaN && w.mmh[i] > bestV {
                bestV = w.mmh[i]
                best = i
            }
            if bestV <= 0.0 {
                return "\(span) No rain expected."
            }
        }
        let when = slotLabel(w, best, zone)
        if useProb {
            return "\(span) Highest chance: \(WxFormat.percent(bestV)) at \(best == 0 ? "the current hour" : when)."
        }
        return "\(span) Heaviest: \(WxFormat.precip(bestV, units: units)) per hour at "
            + "\(best == 0 ? "the current time" : when)."
    }
}
