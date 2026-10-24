// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// DetailView.swift - the detail pane (WxDetail, src/ui/wx-detail.{h,c}) in
// SwiftUI, drawn from DetailViewModel only: it never formats or composes a text.
//
// DetailView owns one DetailViewModel and calls show(place:) whenever the
// selected place changes; DetailPage renders DetailViewModel.Page:
// - .placeholder: the title, the text and, iff showsSpinner, a spinner whose
//   accessibility label is Placeholder.spinnerAccessibilityLabel;
// - .forecast, in the order of ForecastPage.sections (wx-detail.c:939-1069):
//   header, now, Rain card, Clouds card, "Next 48 hours" + hour strip,
//   "Next days" + day list, footer row (text, refresh spinner, Offline / Stale
//   badges), attribution line, partial line.
// Card and section titles carry the header trait; tooltips (.help) and
// accessibility labels come only from view-model strings. Labels are plain
// (not selectable). Colours are system colours; the charts use the accent.

import SwiftUI
import WeatherCore

/// The detail pane of the selected place (nil: none selected).
struct DetailView: View {
    let place: AppModel.Place?

    @State private var detail = DetailViewModel()

    var body: some View {
        DetailPage(page: detail.page)
            .onChange(of: ShowKey(place), initial: true) {
                detail.show(place: place)
            }
    }

    /// What of the place the pane reads (DetailViewModel.Item), as NaN-free values: a change
    /// re-runs show(place:), which assigns the page only when something visible changed. The
    /// forecast is keyed by its generation time and fetch time (AppModel replaces both together,
    /// AppModel.swift:498-499, :922-923) and the bit patterns of its numbers, so an unchanged
    /// place compares equal even though its forecast stores NaN (synthesized == is false then).
    private struct ShowKey: Equatable {
        let key: String?
        let place: WxPlace?
        let forecastBits: [UInt64]?
        let forecastPlace: WxPlace?
        let sources: [WxSourceStatus]?
        let fetchedS: Int64
        let loading: Bool
        let stale: Bool
        let offline: Bool
        let units: WxUnits?
        let nowS: Int64
        let errorText: String?

        init(_ p: AppModel.Place?) {
            key = p?.key
            place = p?.place
            forecastBits = p?.forecast.map(Self.bits)
            forecastPlace = p?.forecast?.place
            sources = p?.forecast?.sources
            fetchedS = p?.fetchedS ?? 0
            loading = p?.loading ?? false
            stale = p?.stale ?? false
            offline = p?.offline ?? false
            units = p?.units
            nowS = p?.nowS ?? 0
            errorText = p?.errorText
        }

        /// The generation time, the counts and the bit patterns of every hour, quarter and day
        /// number the pane reads (NaN compares equal to the same NaN).
        private static func bits(_ f: WxForecast) -> [UInt64] {
            var out: [UInt64] = [UInt64(bitPattern: f.generatedS), UInt64(f.hours.count), UInt64(f.quarters.count),
                                 UInt64(f.days.count), UInt64(f.sources.count)]
            out.reserveCapacity(5 + f.hours.count * 14 + f.quarters.count * 2 + f.days.count * 7)
            for h in f.hours {
                out += [UInt64(bitPattern: h.tS), h.tempC.bitPattern, h.feelsC.bitPattern, h.precipMm.bitPattern,
                        h.precipMmMax.bitPattern, h.precipProb.bitPattern, h.cloudPct.bitPattern,
                        h.windKmh.bitPattern, h.gustKmh.bitPattern, h.humidityPct.bitPattern,
                        h.tempSpreadC.bitPattern, UInt64(truncatingIfNeeded: h.nMembers),
                        UInt64(truncatingIfNeeded: h.condition.rawValue),
                        h.isDay ? 1 : 0]
            }
            for q in f.quarters {
                out += [UInt64(bitPattern: q.tS), q.precipMm.bitPattern]
            }
            for d in f.days {
                out += [UInt64(bitPattern: d.startS), d.tempMaxC.bitPattern, d.tempMinC.bitPattern,
                        d.precipMm.bitPattern, d.precipProbMax.bitPattern, d.cloudPct.bitPattern,
                        UInt64(truncatingIfNeeded: d.condition.rawValue)]
            }
            return out
        }
    }
}

/// One page of the pane (wx-detail.h:7-11): the placeholder or the forecast.
struct DetailPage: View {
    let page: DetailViewModel.Page

    var body: some View {
        switch page {
        case .placeholder(let placeholder):
            PlaceholderPage(placeholder: placeholder)
        case .forecast(let forecast):
            ScrollView(.vertical) {
                ForecastPageView(page: forecast)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Placeholder (wx-detail.c:358-370)

private struct PlaceholderPage: View {
    let placeholder: DetailViewModel.Placeholder

    var body: some View {
        // C order: spinner, title, text (wx-detail.c:906-908), centred.
        VStack(spacing: 10) {
            if placeholder.showsSpinner {
                ProgressView()
                    .accessibilityLabel(Text(DetailViewModel.Placeholder.spinnerAccessibilityLabel))
            }
            Text(placeholder.title)
                .font(.title2.bold())
            if !placeholder.text.isEmpty {
                Text(placeholder.text)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Forecast page (wx-detail.c:939-1069)

private struct ForecastPageView: View {
    let page: DetailViewModel.ForecastPage

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(DetailViewModel.ForecastPage.sections, id: \.self) { section in
                self.section(section)
            }
        }
    }

    @ViewBuilder private func section(_ section: DetailViewModel.Section) -> some View {
        switch section {
        case .header:
            Text(page.place)
                .font(.title2.bold())
        case .now:
            NowBlock(now: page.now)
        case .rain:
            RainCardView(rain: page.rain)
        case .clouds:
            CloudCardView(clouds: page.clouds)
        case .hours:
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: DetailViewModel.ForecastPage.hoursTitle)
                HourStrip(cards: page.hours)
            }
        case .days:
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: DetailViewModel.ForecastPage.daysTitle)
                DayList(rows: page.days)
            }
        case .footer:
            FooterRow(page: page)
        case .attribution:
            if !page.attribution.isEmpty {
                AttributionLine(entries: page.attribution, text: page.attributionText)
            }
        case .partial:
            if let partial = page.partial {
                // style.css:147-148 colours it #9a6700 (4.87:1 on white); the system orange
                // darkened toward the label colour keeps the hue at >= 4.5:1 in both appearances.
                Text(partial)
                    .font(.footnote)
                    .foregroundStyle(Color.orange.mix(with: .primary, by: 0.4))
            }
        }
    }
}

/// A card or section title (heading role, wx-detail.c).
private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "wx-card": a rounded, lightly filled box.
private struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The current conditions: icon, temperature with unit, condition, feels like, High/Low, wind.
private struct NowBlock: View {
    let now: DetailViewModel.Now

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: now.symbolName)
                .font(.system(size: 64))
                .frame(width: 80, height: 80)
                .accessibilityLabel(Text(now.iconAccessibilityLabel))
            VStack(alignment: .leading, spacing: 2) {
                Text(now.temperature)
                    .font(.system(size: 56, weight: .light))
                Text(now.condition)
                    .font(.title3.weight(.semibold))
                // style.css:110-114: feels like, High/Low and wind are dimmed.
                Group {
                    Text(now.feelsLike)
                    if let highLow = now.highLow {
                        Text(highLow)
                    }
                    Text(now.wind)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RainCardView: View {
    let rain: DetailViewModel.RainCard

    var body: some View {
        DetailCard(title: DetailViewModel.RainCard.title) {
            Text(rain.headline)
                .font(.title3.bold())
            if let detail = rain.detail {
                Text(detail)
            }
            HStack(alignment: .top, spacing: 12) {
                if rain.showsNowcast {
                    CaptionedChart(caption: DetailViewModel.RainCard.nowcastCaption, chart: rain.nowcast)
                }
                CaptionedChart(caption: DetailViewModel.RainCard.hourlyCaption, chart: rain.hourly)
            }
            .padding(.top, 6)
        }
    }
}

/// A dim caption over a chart; the two charts of the card share the width equally.
private struct CaptionedChart: View {
    let caption: String
    let chart: RainChartData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            DetailRainChart(chart: chart)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CloudCardView: View {
    let clouds: DetailViewModel.CloudCard

    var body: some View {
        DetailCard(title: DetailViewModel.CloudCard.title) {
            Text(clouds.cover)
            Text(clouds.sentence)
        }
    }
}

/// The 48-hour strip (wx-hour-strip.c): hour, 32-pt icon, temperature, rain and cloud (dim).
private struct HourStrip: View {
    let cards: [DetailViewModel.HourCard]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(cards) { card in
                    VStack(spacing: 4) {
                        Text(card.hour)
                            .font(.callout.weight(.medium))
                        Image(systemName: card.symbolName)
                            .font(.system(size: 32))
                                        .frame(height: 40)
                            .accessibilityHidden(true)
                        Text(card.temp)
                            .font(.title3)
                        Text(card.rain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(card.cloud)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 64)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help(card.tooltip)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }
}

/// The day list (wx-day-list.c): day, 24-pt icon, rain chance and low (dim), high.
private struct DayList: View {
    let rows: [DetailViewModel.DayRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.day)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: row.symbolName)
                        .font(.system(size: 24))
                                .frame(width: 32)
                        .accessibilityHidden(true)
                    Text(row.rain)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                    Text(row.low)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40, alignment: .trailing)
                    Text(row.high)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .help(row.tooltip)
                .accessibilityElement(children: .combine)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
    }
}

/// "Updated … · Sources: …", the refresh spinner and the Offline / Stale badges.
private struct FooterRow: View {
    let page: DetailViewModel.ForecastPage

    var body: some View {
        HStack(spacing: 8) {
            // dim-label, hexpand (wx-detail.c:1064-1065): the spinner and badges sit at the trailing edge.
            Text(page.footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if page.showsRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(DetailViewModel.ForecastPage.refreshingAccessibilityLabel))
            }
            if page.showsOfflineBadge {
                Badge(text: DetailViewModel.ForecastPage.offlineBadgeText,
                      tooltip: DetailViewModel.ForecastPage.offlineBadgeTooltip)
            }
            if page.showsStaleBadge {
                Badge(text: DetailViewModel.ForecastPage.staleBadgeText, tooltip: page.staleBadgeTooltip)
            }
        }
    }
}

/// A yellow pill (style.css:133-139) with a tooltip.
private struct Badge: View {
    let text: String
    let tooltip: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.yellow.opacity(0.35), in: Capsule())
            .help(tooltip)
            .accessibilityHint(Text(tooltip))
    }
}

/// The attribution line (dim-label, wx-detail.c:1076-1079): ForecastPage.attributionText cut into
/// its pieces - each entry with a URL is a Link (focusable with the keyboard), each other entry
/// and each separator between entries is plain text - laid out left to right, wrapping.
private struct AttributionLine: View {
    let entries: [DetailViewModel.AttributionEntry]
    let text: String

    var body: some View {
        AttributionFlow {
            ForEach(Array(Self.pieces(entries, in: text).enumerated()), id: \.offset) { _, piece in
                if let link = piece.link {
                    Link(piece.text, destination: link)
                } else {
                    Text(piece.text)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote)
    }

    fileprivate struct Piece {
        let text: String
        let link: URL?
    }

    /// `text` (the entries joined by the view model) split into the entries and what lies between
    /// them, each piece a substring of `text`.
    fileprivate static func pieces(_ entries: [DetailViewModel.AttributionEntry], in text: String) -> [Piece] {
        var out: [Piece] = []
        var cursor = text.startIndex
        for entry in entries {
            guard let range = text.range(of: entry.text, range: cursor..<text.endIndex) else {
                continue
            }
            if cursor < range.lowerBound {
                out.append(Piece(text: String(text[cursor..<range.lowerBound]), link: nil))
            }
            out.append(Piece(text: String(text[range]), link: entry.url.flatMap(URL.init(string:))))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            out.append(Piece(text: String(text[cursor...]), link: nil))
        }
        return out
    }
}

/// A left-to-right flow that wraps its pieces onto new lines (a piece wider than the line wraps itself).
private struct AttributionFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (k, frame) in rows.frames.enumerated() {
            subviews[k].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, used: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width {
                size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width
            used = max(used, x)
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, used, y + lineHeight)
    }
}

// MARK: - Previews (one per DetailViewModel state)

#Preview("Detail view - nothing selected") {
    DetailView(place: nil)
        .frame(width: 640, height: 480)
}

#Preview("Placeholder - no place") {
    DetailPage(page: DetailPreviewData.page(nil))
        .frame(width: 640, height: 480)
}

#Preview("Placeholder - loading") {
    DetailPage(page: DetailPreviewData.page(loading: true))
        .frame(width: 640, height: 480)
}

#Preview("Placeholder - error") {
    DetailPage(page: DetailPreviewData.page(error: "Could not reach the server"))
        .frame(width: 640, height: 480)
}

#Preview("Placeholder - offline") {
    DetailPage(page: DetailPreviewData.page(offline: true))
        .frame(width: 640, height: 480)
}

#Preview("Placeholder - no forecast yet") {
    DetailPage(page: DetailPreviewData.page())
        .frame(width: 640, height: 480)
}

#Preview("Forecast - nowcast, partial, attribution") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast()))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - no nowcast, all sources") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(nowcast: false, partial: false)))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - offline badge, refreshing") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(), loading: true, offline: true))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - stale badge") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(), stale: true,
                                            error: "HTTP 503"))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - stale badge, no error text") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(), stale: true))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - attribution entry without a link") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(partial: false, unlinked: true)))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - no current conditions") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast(),
                                            nowS: DetailPreviewData.hour0 + 200 * 3600))
        .frame(width: 760, height: 900)
}

#Preview("Forecast - dark") {
    DetailPage(page: DetailPreviewData.page(forecast: DetailPreviewData.forecast()))
        .frame(width: 760, height: 900)
        .preferredColorScheme(.dark)
}
