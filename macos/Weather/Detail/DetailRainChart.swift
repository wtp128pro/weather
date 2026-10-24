// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailRainChart.swift - the rain chart of the detail pane (WxRainChart,
// src/widgets/wx-rain-chart.{h,c}), drawn in a SwiftUI Canvas from
// RainChartData.geometry(width:height:percentTopSize:axisLabelWidths:), the
// port of wx_rain_chart_snapshot (wx-rain-chart.c:490-589).
//
// The view only measures and paints. It measures RainChartData.percentTopText
// and every RainChartData.axisLabels text in the chart font, then asks the view
// model for the geometry and paints what comes back with macOS 27 multi-stop
// gradients, smooth cubic Bézier probability curves, soft area fills, and
// glowing data nodes:
// - a softly tinted plot backdrop and dashed reference grid lines;
// - rounded capsule bars (the expected rain RATE, rising from the baseline)
//   filled with a 3-stop aqua-to-cobalt vertical gradient and top specular highlight;
// - smooth monotone cubic Bézier chance curves with a translucent gradient area
//   fill beneath the curve, vibrant amber-to-violet gradient stroke, and glowing
//   circular markers for lone points and local extrema;
// - the texts (scale label, 100% / 0%, the time labels the C overlap rule
//   keeps) at their positions.
// Without data it shows RainChartData.noDataText, centred and dim. The chart is
// one accessibility element (image trait, label RainChartData.accessibilityLabel,
// value RainChartData.accessibilityDescription) and is always laid out left to
// right.

import SwiftUI
import WeatherCore

/// One rain chart (the HOURLY or NOWCAST view of the pane).
struct DetailRainChart: View {
    let chart: RainChartData

    /// The chart's small font (PANGO_SCALE_SMALL layouts, wx-rain-chart.c:692-712).
    static let font = Font.caption2.weight(.medium)

    var body: some View {
        content
            .frame(minWidth: CGFloat(RainChartData.minimumSize.width),
                   idealWidth: CGFloat(RainChartData.naturalSize.width),
                   maxWidth: .infinity,
                   minHeight: CGFloat(RainChartData.minimumSize.height),
                   idealHeight: CGFloat(RainChartData.naturalSize.height))
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(RainChartData.accessibilityLabel)
            .accessibilityValue(chart.accessibilityDescription)
    }

    @ViewBuilder private var content: some View {
        if chart.hasData {
            Canvas { context, size in
                Self.paint(chart, in: context, size: size)
            }
        } else {
            Text(RainChartData.noDataText)
                .font(Self.font)
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Series Palettes

    private static let barTopColor = Color(red: 0.22, green: 0.86, blue: 1.00)
    private static let barMidColor = Color(red: 0.06, green: 0.58, blue: 0.96)
    private static let barBottomColor = Color(red: 0.14, green: 0.34, blue: 0.88)

    private static let chanceHighColor = Color(red: 0.98, green: 0.62, blue: 0.16)
    private static let chanceMidColor = Color(red: 0.92, green: 0.36, blue: 0.58)
    private static let chanceLowColor = Color(red: 0.56, green: 0.38, blue: 0.96)

    /// Measures the labels, takes the view model's geometry for `size` and paints it.
    private static func paint(_ chart: RainChartData, in context: GraphicsContext, size: CGSize) {
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        let top = context.resolve(Text(RainChartData.percentTopText).font(font)).measure(in: unbounded)
        let widths = chart.axisLabels.map {
            Float(context.resolve(Text($0.text).font(font)).measure(in: unbounded).width)
        }
        guard let geometry = chart.geometry(width: Float(size.width), height: Float(size.height),
                                            percentTopSize: (width: Float(top.width), height: Float(top.height)),
                                            axisLabelWidths: widths) else {
            return
        }

        let plotRect = cgRect(geometry.plot)

        // 1. Softly rounded plot well backdrop.
        if plotRect.width > 4 && plotRect.height > 4 {
            let plotRounded = Path(roundedRect: plotRect, cornerRadius: 6, style: .continuous)
            context.fill(
                plotRounded,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.10),
                    ]),
                    startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
                    endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY)
                )
            )
        }

        // 2. Grid lines: crisp baseline + dashed reference lines (including 25% / 75% subdivisions).
        for (idx, line) in geometry.gridLines.enumerated() {
            let r = cgRect(line)
            let isBaseline = idx == geometry.gridLines.count - 1
            if isBaseline {
                context.fill(Path(r), with: .color(Color.white.opacity(0.32)))
            } else {
                var dashPath = Path()
                dashPath.move(to: CGPoint(x: r.minX, y: r.midY))
                dashPath.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                context.stroke(
                    dashPath,
                    with: .color(Color.white.opacity(0.22)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3])
                )
            }
        }
        if plotRect.height >= 36 {
            for frac in [0.25, 0.75] {
                let y = plotRect.minY + plotRect.height * frac
                var subPath = Path()
                subPath.move(to: CGPoint(x: plotRect.minX, y: y))
                subPath.addLine(to: CGPoint(x: plotRect.maxX, y: y))
                context.stroke(
                    subPath,
                    with: .color(Color.white.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 3.5])
                )
            }
        }

        // 3. Translucent gradient area fill beneath the smooth probability runs.
        for run in geometry.lineRuns {
            let pts = run.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            guard pts.count >= 2 else { continue }
            let curvePath = smoothPath(points: pts, minY: plotRect.minY, maxY: plotRect.maxY)
            var areaPath = curvePath
            if let last = pts.last, let first = pts.first {
                areaPath.addLine(to: CGPoint(x: last.x, y: plotRect.maxY))
                areaPath.addLine(to: CGPoint(x: first.x, y: plotRect.maxY))
                areaPath.closeSubpath()
                context.fill(
                    areaPath,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: chanceHighColor.opacity(0.28), location: 0.0),
                            .init(color: chanceMidColor.opacity(0.16), location: 0.55),
                            .init(color: chanceLowColor.opacity(0.02), location: 1.0),
                        ]),
                        startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
                        endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY)
                    )
                )
            }
        }

        // 4. Precipitation rate bars with 3-stop vertical aqua-to-cobalt gradient and top highlight cap.
        for bar in geometry.bars {
            let r = cgRect(bar)
            guard r.width > 0 && r.height > 0 else { continue }
            let corner = min(r.width * 0.45, min(r.height * 0.5, 4.5))
            let barPath = UnevenRoundedRectangle(
                topLeadingRadius: corner,
                bottomLeadingRadius: min(1.5, corner),
                bottomTrailingRadius: min(1.5, corner),
                topTrailingRadius: corner,
                style: .continuous
            ).path(in: r)

            // Soft outer glow for taller bars.
            if r.height >= 6 {
                var glowCtx = context
                glowCtx.opacity = 0.22
                let glowRect = r.insetBy(dx: -0.75, dy: -0.5)
                glowCtx.fill(
                    Path(roundedRect: glowRect, cornerRadius: corner + 1),
                    with: .color(barTopColor)
                )
            }

            context.fill(
                barPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: barTopColor, location: 0.0),
                        .init(color: barMidColor, location: 0.48),
                        .init(color: barBottomColor, location: 1.0),
                    ]),
                    startPoint: CGPoint(x: r.midX, y: r.minY),
                    endPoint: CGPoint(x: r.midX, y: r.maxY)
                )
            )

            // Specular top cap highlight.
            if r.height >= 3 {
                let capRect = CGRect(x: r.minX + 0.5, y: r.minY, width: max(0, r.width - 1), height: min(2.0, r.height * 0.35))
                context.fill(
                    Path(roundedRect: capRect, cornerRadius: corner),
                    with: .color(.white.opacity(0.48))
                )
            }
        }

        // 5. Smooth cubic Bézier probability curve stroke + vertex nodes.
        let chanceGradient = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: chanceHighColor, location: 0.0),
                .init(color: chanceMidColor, location: 0.52),
                .init(color: chanceLowColor, location: 1.0),
            ]),
            startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
            endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY)
        )

        for run in geometry.lineRuns {
            let pts = run.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            guard pts.count >= 2 else { continue }
            let path = smoothPath(points: pts, minY: plotRect.minY, maxY: plotRect.maxY)

            // Soft glow halo along the probability line.
            var glowCtx = context
            glowCtx.opacity = 0.30
            glowCtx.stroke(
                path,
                with: chanceGradient,
                style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round)
            )

            // Main curve stroke.
            context.stroke(
                path,
                with: chanceGradient,
                style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
            )

            // Subtle circular data nodes at endpoints and local extrema.
            for (idx, pt) in pts.enumerated() {
                let isEndpoint = idx == 0 || idx == pts.count - 1
                let isLocalPeak: Bool = {
                    guard idx > 0 && idx + 1 < pts.count else { return false }
                    let prevY = pts[idx - 1].y
                    let nextY = pts[idx + 1].y
                    return (pt.y < prevY - 1.5 && pt.y <= nextY) || (pt.y > prevY + 1.5 && pt.y >= nextY)
                }()
                if isEndpoint || isLocalPeak {
                    drawNode(at: pt, in: context, plotRect: plotRect)
                }
            }
        }

        // 6. Lone probability points as glowing circular nodes.
        for square in geometry.loneSquares {
            let r = cgRect(square)
            drawNode(at: CGPoint(x: r.midX, y: r.midY), in: context, plotRect: plotRect)
        }

        // 7. Scale and axis labels (high-contrast crisp white on dark-slate card).
        for text in geometry.texts {
            context.draw(
                context.resolve(Text(text.text).font(font).foregroundStyle(Color.white.opacity(0.92))),
                at: CGPoint(x: CGFloat(text.origin.x), y: CGFloat(text.origin.y)),
                anchor: .topLeading
            )
        }
    }

    /// Draws a glowing circular node on the probability curve.
    private static func drawNode(at point: CGPoint, in context: GraphicsContext, plotRect: CGRect) {
        let frac = plotRect.height > 0 ? max(0, min(1, (point.y - plotRect.minY) / plotRect.height)) : 0.5
        let nodeColor = frac < 0.45 ? chanceHighColor : (frac < 0.75 ? chanceMidColor : chanceLowColor)
        let haloRect = CGRect(x: point.x - 4.0, y: point.y - 4.0, width: 8.0, height: 8.0)
        let outerRect = CGRect(x: point.x - 2.6, y: point.y - 2.6, width: 5.2, height: 5.2)
        let innerRect = CGRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)
        context.fill(Path(ellipseIn: haloRect), with: .color(nodeColor.opacity(0.28)))
        context.fill(Path(ellipseIn: outerRect), with: .color(nodeColor))
        context.fill(Path(ellipseIn: innerRect), with: .color(.white.opacity(0.9)))
    }

    /// Constructs a smooth monotone cubic Hermite / Bézier path through `points`, clamping
    /// control-point Y values to `[minY, maxY]` so the curve never overshoots 0% or 100%.
    private static func smoothPath(points: [CGPoint], minY: CGFloat, maxY: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        let n = points.count
        var tangents = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            if i == 0 {
                let dx = points[1].x - points[0].x
                tangents[i] = dx > 0 ? (points[1].y - points[0].y) / dx : 0
            } else if i == n - 1 {
                let dx = points[n - 1].x - points[n - 2].x
                tangents[i] = dx > 0 ? (points[n - 1].y - points[n - 2].y) / dx : 0
            } else {
                let dxPrev = points[i].x - points[i - 1].x
                let dxNext = points[i + 1].x - points[i].x
                let mPrev = dxPrev > 0 ? (points[i].y - points[i - 1].y) / dxPrev : 0
                let mNext = dxNext > 0 ? (points[i + 1].y - points[i].y) / dxNext : 0
                if mPrev * mNext <= 0 {
                    tangents[i] = 0
                } else {
                    tangents[i] = (mPrev + mNext) * 0.5
                }
            }
        }

        for i in 0..<(n - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let dx = p1.x - p0.x
            let cp1 = CGPoint(
                x: p0.x + dx / 3.0,
                y: min(maxY, max(minY, p0.y + tangents[i] * dx / 3.0))
            )
            let cp2 = CGPoint(
                x: p1.x - dx / 3.0,
                y: min(maxY, max(minY, p1.y - tangents[i + 1] * dx / 3.0))
            )
            path.addCurve(to: p1, control1: cp1, control2: cp2)
        }
        return path
    }

    private static func cgRect(_ r: RainChartData.Rect) -> CGRect {
        CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height))
    }
}

// MARK: - Previews (one per chart state: no data, hourly, nowcast; and the narrow minimum size)

#Preview("Rain chart - no data") {
    DetailRainChart(chart: RainChartData(view: .hourly, units: .metric))
        .padding()
}

#Preview("Rain chart - hourly") {
    DetailRainChart(chart: DetailPreviewData.chart(.hourly))
        .padding()
}

#Preview("Rain chart - nowcast") {
    DetailRainChart(chart: DetailPreviewData.chart(.nowcast))
        .padding()
}

#Preview("Rain chart - hourly, dark") {
    DetailRainChart(chart: DetailPreviewData.chart(.hourly))
        .padding()
        .preferredColorScheme(.dark)
}
