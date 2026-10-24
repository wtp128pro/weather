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
// model for the geometry and paints exactly what comes back:
// - grid lines at the bottom, middle and top, in the parent colour at
//   RainChartData.gridAlpha;
// - bars (the expected rain RATE, rising from the baseline, 70 % of the slot,
//   at least 1 pt tall) in the accent colour, the chart's only series colour;
// - the chance line runs (1.5 pt, round caps and joins) and the lone-chance
//   squares in the parent colour;
// - the texts (scale label, 100% / 0%, the time labels the C overlap rule
//   keeps) at their positions, in the parent colour at RainChartData.dimAlpha.
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
    static let font = Font.caption2

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
                .foregroundStyle(Color.primary.opacity(Double(RainChartData.dimAlpha)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        var grid = context
        grid.opacity = Double(RainChartData.gridAlpha)
        for line in geometry.gridLines {
            grid.fill(Path(cgRect(line)), with: .foreground)
        }
        for bar in geometry.bars {
            context.fill(Path(cgRect(bar)), with: .color(.accentColor))
        }
        for run in geometry.lineRuns {
            var path = Path()
            for (k, point) in run.enumerated() {
                let p = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                if k == 0 {
                    path.move(to: p)
                } else {
                    path.addLine(to: p)
                }
            }
            context.stroke(path, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        for square in geometry.loneSquares {
            context.fill(Path(cgRect(square)), with: .foreground)
        }
        var dim = context
        dim.opacity = Double(RainChartData.dimAlpha)
        for text in geometry.texts {
            dim.draw(dim.resolve(Text(text.text).font(font)),
                     at: CGPoint(x: CGFloat(text.origin.x), y: CGFloat(text.origin.y)), anchor: .topLeading)
        }
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
