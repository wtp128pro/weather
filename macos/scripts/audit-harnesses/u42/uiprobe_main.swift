// U42 UI probe main: renders the view code that gen_ui.py copied verbatim from the pre-fix or the
// fixed sources (DayList, DayTemperatureBar, ForecastPageView's isMetric argument, the hover-pill
// rate text) and the compiled DetailRainChart of the products it is linked with, with ImageRenderer.
@testable import Neginato_Mezora
@testable import WeatherCore
import AppKit
import SwiftUI

struct Band { let name: String; let r, g, b: Double }
let bands = [Band(name: "icy cyan", r: 0.28, g: 0.82, b: 1.00), Band(name: "cold azure", r: 0.24, g: 0.68, b: 0.98),
             Band(name: "cool teal", r: 0.22, g: 0.84, b: 0.72), Band(name: "mild green-gold", r: 0.52, g: 0.86, b: 0.34),
             Band(name: "warm amber-gold", r: 0.98, g: 0.76, b: 0.14), Band(name: "hot orange", r: 1.00, g: 0.54, b: 0.12),
             Band(name: "scorching coral-red", r: 0.96, g: 0.30, b: 0.26)]

@MainActor func bitmap<V: View>(_ v: V) -> NSBitmapImageRep {
    let r = ImageRenderer(content: v)
    r.scale = 1
    return NSBitmapImageRep(cgImage: r.cgImage!)
}

func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Double, Double, Double) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
}

/// Which band a WeatherTheme colour is (the real function in the linked products).
@MainActor func bandName(_ v: Int, _ isMetric: Bool) -> String {
    let c = WeatherTheme.temperatureColor(for: v, isMetric: isMetric)
    for b in bands where c == Color(red: b.r, green: b.g, blue: b.b) { return b.name }
    return "other"
}

@MainActor func dayBars(units: WxUnits, nowS: Int64, label: String) {
    let item = DetailViewModel.Item(place: DetailPreviewData.place!, forecast: DetailPreviewData.forecast(),
                                    fetchedS: DetailPreviewData.nowS - 300, loading: false, stale: false,
                                    offline: false, units: units, nowS: nowS, errorText: nil)
    guard case .forecast(let page) = DetailPreviewData.page(item) else { print(label, "no forecast page"); return }
    let isMetric = callSiteIsMetric(page: page, units: units)
    let first = page.days.first
    print("U19-F1 \(label): now.temperature=\(page.now.temperature) -> isMetric=\(isMetric);",
          "day 1 low/high \(first?.lowValue ?? -999)/\(first?.highValue ?? -999) ->",
          bandName(first?.lowValue ?? 0, isMetric), "/", bandName(first?.highValue ?? 0, isMetric))
    // DayList hands isMetric unchanged to each row's DayTemperatureBar (`isMetric: isMetric`); its glass
    // card does not render in ImageRenderer, so the rows' bars are rendered one by one, as DayList lays
    // them out (130 x 6 pt, the page's overall low/high), and each coloured fill pixel is given the
    // nearest WeatherTheme band.
    let lows = page.days.compactMap(\.lowValue), highs = page.days.compactMap(\.highValue)
    guard let oLow = lows.min(), let oHigh = highs.max() else { return }
    var counts = [Int](repeating: 0, count: bands.count)
    for row in page.days {
        let rep = bitmap(ProbeDayTemperatureBar(low: row.lowValue, high: row.highValue, overallLow: oLow, overallHigh: oHigh,
                                           currentTemp: nil, isMetric: isMetric).frame(width: 130, height: 6)
            .background(Color.white))
        for x in 0..<rep.pixelsWide {
            let (r, g, b) = rgb(rep, x, 3)
            guard max(r, g, b) - min(r, g, b) > 0.25 else { continue }
            let d = bands.map { ($0.r - r) * ($0.r - r) + ($0.g - g) * ($0.g - g) + ($0.b - b) * ($0.b - b) }
            counts[d.firstIndex(of: d.min()!)!] += 1
        }
    }
    print("U19-F1 \(label): day-bar fill pixels by nearest band:",
          zip(bands, counts).filter { $1 > 0 }.map { "\($0.name)=\($1)" }.joined(separator: " "))
}

@MainActor func bar(_ low: Int, _ high: Int, _ oLow: Int, _ oHigh: Int) {
    let rep = bitmap(HStack(spacing: 0) {
        ProbeDayTemperatureBar(low: low, high: high, overallLow: oLow, overallHigh: oHigh, currentTemp: nil, isMetric: true)
            .frame(width: 130, height: 6)
        Color.clear.frame(width: 30, height: 6)
    }.background(Color.white))
    var inside = 0, outside = 0, minX = Int.max, maxX = -1
    for x in 0..<rep.pixelsWide {
        let (r, g, b) = rgb(rep, x, 3)
        if max(r, g, b) - min(r, g, b) > 0.25 {  // the coloured fill (the track is grey)
            if x >= 130 { outside += 1 } else { inside += 1 }
            minX = min(minX, x); maxX = max(maxX, x)
        }
    }
    print("U19-F2 bar \(low)..\(high) within \(oLow)..\(oHigh) on the 130-pt track: fill px inside=\(inside)",
          "outside=\(outside) x=\(minX)..\(maxX)")
}

@MainActor func main() {
    // U19-F1: a metric place with no current hour (now.temperature is the em dash), a metric place
    // with one, and the imperial sample place (the controls).
    dayBars(units: .metric, nowS: DetailPreviewData.hour0 + 200 * 3600, label: "metric, no current")
    dayBars(units: .metric, nowS: DetailPreviewData.nowS, label: "metric, with current")
    dayBars(units: .imperial, nowS: DetailPreviewData.nowS, label: "imperial (control)")

    // U19-F2: today's 1-hour row at the top of the range; the shipped example and a general row.
    bar(14, 14, -2, 14)
    bar(29, 29, 0, 30)
    bar(5, 9, 0, 30)

    // U21-F4: a nowcast with two quarters: slot 0 dry, slot 1 wet, slots 2-7 unknown.
    let q0 = DetailPreviewData.nowS
    let chart = RainChartData(hours: [], quarters: [WxQuarter(tS: q0, precipMm: 0), WxQuarter(tS: q0 + 900, precipMm: 0.5)],
                              units: .metric, nowS: q0, view: .nowcast, zone: .utc)
    print("U21-F4 rateMmH =", chart.rateMmH.prefix(4).map { $0.isNaN ? "NaN" : String($0) },
          "| hover 'Bar:' text slots 0-3 =", (0..<4).map { hoverRateText(chart: chart, slot: $0) })

    // U21-F5: the compiled DetailRainChart; which horizontal line is the solid 'crisp baseline'.
    let rep = bitmap(DetailRainChart(chart: DetailPreviewData.chart(.nowcast)).frame(width: 560, height: 170)
        .background(Color.black))
    // Per row: grey pixels (r = g = b, the grid lines' white over black) and the longest grey run. The solid
    // 'crisp baseline' gives long runs (broken only by bars); a dashed line gives runs of about 3 px.
    var lines: [String] = []
    var barBottom = -1
    for y in 0..<rep.pixelsHigh {
        var run = 0, best = 0, grey = 0
        for x in 0..<rep.pixelsWide {
            let (r, g, b) = rgb(rep, x, y)
            if max(r, g, b) - min(r, g, b) < 0.03 && r > 0.2 && r < 0.5 { grey += 1; run += 1; best = max(best, run) } else { run = 0 }
            if b > 0.6 && b - r > 0.3 { barBottom = max(barBottom, y) }
        }
        if grey >= 100 { lines.append("y=\(y) grey=\(grey) longestRun=\(best)") }
    }
    print("U21-F5 rain chart \(rep.pixelsWide)x\(rep.pixelsHigh), bars end at row \(barBottom) (the floor):",
          lines.joined(separator: "; "))
}

MainActor.assumeIsolated { main() }

// Debug dumps when U42_DUMP is set: a column profile of the rain chart on stdout, and dump-chart.png
// and dump-days.png written into the directory U42_DUMP names (run_all.sh passes it through).
@MainActor func dump(into dir: String) {
    let rep = bitmap(DetailRainChart(chart: DetailPreviewData.chart(.nowcast)).frame(width: 560, height: 170)
        .background(Color.black))
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dump-chart.png"))
    for y in 0..<rep.pixelsHigh {
        let row = stride(from: 40, to: 540, by: 50).map { x -> String in
            let (r, g, b) = rgb(rep, x, y); return String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255)) }
        print(y, row.joined(separator: " "))
    }
    let item = DetailViewModel.Item(place: DetailPreviewData.place!, forecast: DetailPreviewData.forecast(),
                                    fetchedS: DetailPreviewData.nowS - 300, loading: false, stale: false,
                                    offline: false, units: .metric, nowS: DetailPreviewData.nowS, errorText: nil)
    if case .forecast(let page) = DetailPreviewData.page(item) {
        let d = bitmap(ProbeDayList(rows: page.days, currentTemperature: nil, isMetric: true).frame(width: 700).background(Color.black))
        try? d.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dump-days.png"))
    }
}
if let dir = ProcessInfo.processInfo.environment["U42_DUMP"] { MainActor.assumeIsolated { dump(into: dir) } }
