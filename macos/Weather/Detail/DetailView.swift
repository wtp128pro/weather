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
//   header, now, Rain card, Air Quality + Clouds cards, "Next 48 hours" + hour strip,
//   "Next days" + day list, footer row (text, refresh spinner, Offline / Stale
//   badges), attribution line, partial line.
// Card and section titles carry the header trait; tooltips (.help) and
// accessibility labels come only from view-model strings. Styled with high-contrast
// Apple Weather dark-slate Liquid Glass cards and crisp white typography.

import Foundation
import SwiftUI
import WeatherCore

/// The detail pane of the selected place (nil: none selected).
struct DetailView: View {
    let place: AppModel.Place?
    var onRename: ((String?, String?) -> Void)? = nil

    @State private var detail = DetailViewModel()
    private let liveStore = LiveStationStore.shared

    var body: some View {
        DetailPage(
            page: effectivePage,
            liveAirQuality: liveStore.snapshot(for: place)?.airQuality,
            wxPlace: place?.place,
            onRename: onRename
        )
        .onChange(of: ShowKey(place), initial: true) {
            detail.show(place: place)
        }
        .task(id: LiveFetchKey(place)) {
            guard let p = place, !p.offline else { return }
            await liveStore.refreshIfNeeded(for: p)
        }
    }

    private var effectivePage: DetailViewModel.Page {
        guard case .forecast(let forecastPage) = detail.page,
              let place,
              let snapshot = liveStore.snapshot(for: place)
        else {
            return detail.page
        }
        return .forecast(snapshot.apply(to: forecastPage, place: place))
    }

    private struct LiveFetchKey: Equatable {
        let key: String?
        let fetchedS: Int64
        let offline: Bool
        let units: WxUnits?

        init(_ p: AppModel.Place?) {
            key = p?.key
            fetchedS = p?.fetchedS ?? 0
            offline = p?.offline ?? false
            units = p?.units
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
    var liveAirQuality: DetailViewModel.AirQualityCard? = nil
    var wxPlace: WxPlace? = nil
    var onRename: ((String?, String?) -> Void)? = nil

    var body: some View {
        switch page {
        case .placeholder(let placeholder):
            ZStack {
                WeatherSkyBackground(condition: .partlyCloudy, isDay: true)
                PlaceholderPage(placeholder: placeholder)
            }
            .environment(\.colorScheme, .dark)
        case .forecast(let forecast):
            ZStack {
                WeatherSkyBackground(
                    condition: forecast.now.conditionCode,
                    isDay: forecast.now.isDay
                )
                ScrollView(.vertical) {
                    GlassEffectContainer(spacing: 18) {
                        ForecastPageView(
                            page: forecast,
                            airQuality: liveAirQuality ?? forecast.airQuality,
                            wxPlace: wxPlace,
                            onRename: onRename
                        )
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Placeholder (wx-detail.c:358-370)

private struct PlaceholderPage: View {
    let placeholder: DetailViewModel.Placeholder

    var body: some View {
        // C order: spinner, title, text (wx-detail.c:906-908), centred inside a dark-slate glass card.
        GlassEffectContainer {
            VStack(spacing: 12) {
                WeatherIconView(
                    assetName: "wx-partly-cloudy-day",
                    symbolName: "cloud.sun.fill",
                    size: 68,
                    shadowRadius: 6
                )
                .accessibilityHidden(true)

                if placeholder.showsSpinner {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel(Text(DetailViewModel.Placeholder.spinnerAccessibilityLabel))
                }
                Text(placeholder.title)
                    .font(.title2.bold())
                    .foregroundStyle(WeatherTheme.primaryText)
                if !placeholder.text.isEmpty {
                    Text(placeholder.text)
                        .foregroundStyle(WeatherTheme.secondaryText)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 28)
            .padding(.horizontal, 36)
            .weatherGlassCard(cornerRadius: 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Forecast page (wx-detail.c:939-1069)

private struct ForecastPageView: View {
    let page: DetailViewModel.ForecastPage
    let airQuality: DetailViewModel.AirQualityCard
    var wxPlace: WxPlace? = nil
    var onRename: ((String?, String?) -> Void)? = nil

    @State private var showRenameSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(DetailViewModel.ForecastPage.sections, id: \.self) { section in
                self.section(section)
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            if let wxPlace {
                LocationNameEditorSheet(
                    place: wxPlace,
                    onSave: { customName, streetAddress in
                        onRename?(customName, streetAddress)
                    }
                )
            }
        }
    }

    @ViewBuilder private func section(_ section: DetailViewModel.Section) -> some View {
        switch section {
        case .header:
            headerSection
        case .now:
            NowBlock(now: page.now)
        case .rain:
            RainCardView(rain: page.rain)
        case .clouds:
            HStack(alignment: .top, spacing: 16) {
                AirQualityCardView(airQuality: airQuality)
                CloudCardView(clouds: page.clouds)
            }
        case .hours:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: DetailViewModel.ForecastPage.hoursTitle, iconAsset: nil, isCardHeader: false)
                HourStrip(cards: page.hours)
            }
        case .days:
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: DetailViewModel.ForecastPage.daysTitle, iconAsset: nil, isCardHeader: false)
                DayList(
                    rows: page.days,
                    currentTemperature: page.now.temperatureValue,
                    isMetric: WeatherTheme.isMetric(temperatureText: page.now.temperature)
                )
            }
        case .footer:
            FooterRow(page: page)
        case .attribution:
            if !page.attribution.isEmpty {
                AttributionLine(entries: page.attribution, text: page.attributionText)
            }
        case .partial:
            if let partial = page.partial {
                Text(partial)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color(red: 1.00, green: 0.82, blue: 0.36))
            }
        }
    }

    @ViewBuilder private var headerSection: some View {
        if let wxPlace, wxPlace.isCustomLocation || !wxPlace.customName.isEmpty || !wxPlace.streetAddress.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let sym = ShellRow.symbolForPlace(wxPlace) {
                        Image(systemName: sym)
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(Color(red: 0.48, green: 0.86, blue: 1.00))
                            .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
                    }
                    Text(wxPlace.displayTitle)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(WeatherTheme.primaryText)
                        .shadow(color: .black.opacity(0.32), radius: 4, x: 0, y: 1.5)
                    if onRename != nil {
                        Button {
                            showRenameSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .font(.caption2)
                                Text(wxPlace.customName.isEmpty ? "Name Location" : "Edit Name")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(WeatherTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.24), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Set or edit location name (e.g. Home, Work, Friend's place)")
                    }
                }
                let subtitle = wxPlace.displayAddressSubtitle
                if !subtitle.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WeatherTheme.secondaryText)
                        Text(subtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(WeatherTheme.secondaryText)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(page.place)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(WeatherTheme.primaryText)
                    .shadow(color: .black.opacity(0.32), radius: 4, x: 0, y: 1.5)
                if wxPlace != nil && onRename != nil {
                    Button {
                        showRenameSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tag.fill")
                                .font(.caption2)
                            Text("Name Location")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(WeatherTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.24), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Assign a custom name (e.g. Home, Work, Friend's place)")
                }
            }
        }
    }
}

/// A card or section title (heading role, wx-detail.c) with an optional decorative icon.
private struct SectionTitle: View {
    let text: String
    var iconAsset: String? = nil
    var fallbackSymbol: String = "circle.fill"
    var isCardHeader: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if let iconAsset {
                WeatherIconView(
                    assetName: iconAsset,
                    symbolName: fallbackSymbol,
                    size: 18,
                    shadowRadius: 1.5
                )
                .accessibilityHidden(true)
            } else if isCardHeader {
                Image(systemName: fallbackSymbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WeatherTheme.cardHeaderText)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(isCardHeader ? .caption.weight(.semibold) : .headline.weight(.semibold))
                .textCase(isCardHeader ? .uppercase : nil)
                .tracking(isCardHeader ? 0.5 : 0)
                .foregroundStyle(isCardHeader ? WeatherTheme.cardHeaderText : WeatherTheme.primaryText)
                .shadow(color: isCardHeader ? .clear : .black.opacity(0.25), radius: 2, x: 0, y: 1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// "wx-card": a high-contrast dark-slate Liquid Glass container modeled after Apple Weather.
private struct DetailCard<Content: View>: View {
    let title: String
    var iconAsset: String? = nil
    var fallbackSymbol: String = "circle.fill"
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title, iconAsset: iconAsset, fallbackSymbol: fallbackSymbol, isCardHeader: true)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .weatherGlassCard(cornerRadius: 18)
    }
}

/// The current conditions: hero icon, temperature with unit, condition, feels like, High/Low, wind.
private struct NowBlock: View {
    let now: DetailViewModel.Now

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            WeatherIconView(
                assetName: now.iconAssetName,
                symbolName: now.symbolName,
                size: 92,
                shadowRadius: 8
            )
            .accessibilityLabel(Text(now.iconAccessibilityLabel))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(now.temperature)
                        .font(.system(size: 60, weight: .thin, design: .rounded))
                        .foregroundStyle(WeatherTheme.primaryText)
                        .monospacedDigit()
                    Text(now.condition)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(WeatherTheme.primaryText)
                }

                // Crisp white-on-slate pills for feels like, High/Low and wind.
                HStack(spacing: 10) {
                    NowMetricChip(iconAsset: "wx-thermometer", symbol: "thermometer.medium", text: now.feelsLike)
                    if let highLow = now.highLow {
                        NowMetricChip(iconAsset: nil, symbol: "arrow.up.and.down", text: highLow)
                    }
                    NowMetricChip(iconAsset: "wx-wind", symbol: "wind", text: now.wind)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .weatherGlassCard(cornerRadius: 22)
    }
}

private struct NowMetricChip: View {
    let iconAsset: String?
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let iconAsset {
                WeatherIconView(assetName: iconAsset, symbolName: symbol, size: 16, shadowRadius: 1)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WeatherTheme.secondaryText)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 11)
        .background(Color.black.opacity(0.22), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                .allowsHitTesting(false)
        )
    }
}

private struct RainCardView: View {
    let rain: DetailViewModel.RainCard

    var body: some View {
        DetailCard(title: DetailViewModel.RainCard.title, iconAsset: "wx-umbrella", fallbackSymbol: "umbrella.fill") {
            Text(rain.headline)
                .font(.title3.bold())
                .foregroundStyle(WeatherTheme.primaryText)
            if let detail = rain.detail {
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WeatherTheme.secondaryText)
            }
            HStack(alignment: .top, spacing: 14) {
                if rain.showsNowcast {
                    CaptionedChart(
                        caption: DetailViewModel.RainCard.nowcastCaption,
                        chart: rain.nowcast,
                        showsChanceLegend: false
                    )
                }
                CaptionedChart(
                    caption: DetailViewModel.RainCard.hourlyCaption,
                    chart: rain.hourly,
                    showsChanceLegend: true
                )
            }
            .padding(.top, 6)
        }
    }
}

/// A crisp caption, interval subtitle, and explicit series legend over a rain chart;
/// the two charts of the card share the width equally.
private struct CaptionedChart: View {
    let caption: String
    let chart: RainChartData
    var showsChanceLegend: Bool = false

    private var intervalSubtitle: String {
        chart.isQuarters ? "15-min bars" : "Hourly bars & curve"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WeatherTheme.primaryText)
                Text("· \(intervalSubtitle)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(WeatherTheme.secondaryText)
                Spacer(minLength: 4)
            }
            if chart.hasData {
                ChartSeriesLegend(
                    rateUnit: chart.rateUnitShort,
                    showsChance: showsChanceLegend
                )
            }
            DetailRainChart(chart: chart)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                .allowsHitTesting(false)
        )
    }
}

/// Labeled legend explaining what the cyan bars (Rain rate, left axis) and the
/// amber-rose curve (Rain chance %, right axis) represent.
private struct ChartSeriesLegend: View {
    let rateUnit: String
    let showsChance: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                rateItem
                if showsChance {
                    chanceItem
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                rateItem
                if showsChance {
                    chanceItem
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rateItem: some View {
        HStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 1.5) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barGradient)
                    .frame(width: 3.5, height: 6)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barGradient)
                    .frame(width: 3.5, height: 10)
            }
            Text("Bars: Rain rate (\(rateUnit), left)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.56, green: 0.90, blue: 1.00))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Color(red: 0.08, green: 0.42, blue: 0.78).opacity(0.24),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(red: 0.22, green: 0.86, blue: 1.00).opacity(0.35), lineWidth: 0.6)
        )
    }

    private var chanceItem: some View {
        HStack(spacing: 5) {
            ZStack {
                Capsule()
                    .fill(chanceGradient)
                    .frame(width: 14, height: 2.5)
                Circle()
                    .fill(Color(red: 0.98, green: 0.62, blue: 0.16))
                    .frame(width: 5, height: 5)
                    .overlay(Circle().fill(Color.white).frame(width: 2, height: 2))
            }
            Text("Line: Rain chance (%, right)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 1.00, green: 0.78, blue: 0.52))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Color(red: 0.68, green: 0.28, blue: 0.44).opacity(0.24),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(red: 0.98, green: 0.62, blue: 0.16).opacity(0.35), lineWidth: 0.6)
        )
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.22, green: 0.86, blue: 1.00),
                Color(red: 0.14, green: 0.34, blue: 0.88),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var chanceGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.62, blue: 0.16),
                Color(red: 0.92, green: 0.36, blue: 0.58),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// The Air Quality card: index, category, the AQI scale, the comparison with yesterday and where
/// the value comes from.
private struct AirQualityCardView: View {
    let airQuality: DetailViewModel.AirQualityCard

    var body: some View {
        DetailCard(
            title: DetailViewModel.AirQualityCard.title,
            iconAsset: nil,
            fallbackSymbol: "aqi.medium"
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(airQuality.valueText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(WeatherTheme.primaryText)
                    .monospacedDigit()
                Text(airQuality.category)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(WeatherTheme.primaryText)
            }
            AQIScaleBar(index: airQuality.index)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
            Text(airQuality.summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WeatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let source = airQuality.source {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(WeatherTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The AQI scale: six equal bands in the EPA category colours, with a white-ringed dot inside the
/// value's band.
private struct AQIScaleBar: View {
    let index: Int?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WeatherTheme.aqiGradient)
                    .frame(height: 6)

                if let index {
                    let frac = CGFloat(DetailViewModel.AirQualityCard.scalePosition(index))
                    let dotX = min(max(4, width * frac), max(4, width - 4))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.45), lineWidth: 1.4)
                        )
                        .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 0.5)
                        .offset(x: dotX - 4.5)
                }
            }
        }
        .frame(height: 9)
    }
}

private struct CloudCardView: View {
    let clouds: DetailViewModel.CloudCard

    var body: some View {
        DetailCard(
            title: DetailViewModel.CloudCard.title,
            iconAsset: "wx-mostly-cloudy-day",
            fallbackSymbol: "cloud.fill"
        ) {
            Text(clouds.cover)
                .font(.headline.weight(.semibold))
                .foregroundStyle(WeatherTheme.primaryText)
            if let pct = clouds.cloudPercent {
                CloudCoverGaugeBar(percent: pct)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
            }
            Text(clouds.sentence)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WeatherTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Visual cloud-cover gauge bar with a bright sky-cyan to silver-white gradient fill.
private struct CloudCoverGaugeBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { geo in
            let clamped = CGFloat(max(0, min(100, percent))) / 100.0
            let fillWidth = max(6, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.28))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.38, green: 0.84, blue: 1.00),
                                Color(red: 0.78, green: 0.88, blue: 0.98),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: 6)
            }
        }
        .frame(height: 9)
    }
}

/// The 48-hour strip (wx-hour-strip.c): hour, 36-pt icon, temperature, rain and cloud.
private struct HourStrip: View {
    let cards: [DetailViewModel.HourCard]

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(cards) { card in
                    let hasRain = WxConditionSymbol.precipitationRank(card.conditionCode) > 0
                        || (card.rainPercent ?? 0) >= 30
                    VStack(spacing: 5) {
                        Text(card.hour)
                            .font(.callout.weight(card.isNow ? .bold : .semibold))
                            .foregroundStyle(WeatherTheme.primaryText)
                        WeatherIconView(
                            assetName: card.iconAssetName,
                            symbolName: card.symbolName,
                            size: 36,
                            shadowRadius: 3
                        )
                        .frame(height: 40)
                        .accessibilityHidden(true)
                        Text(card.temp)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(WeatherTheme.primaryText)
                        Text(card.rain)
                            .font(.caption.weight(hasRain ? .bold : .medium))
                            .foregroundStyle(
                                hasRain
                                    ? WeatherTheme.rainCyan
                                    : WeatherTheme.secondaryText
                            )
                        Text(card.cloud)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WeatherTheme.secondaryText)
                    }
                    .monospacedDigit()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 68)
                    .weatherGlassCard(cornerRadius: 14)
                    .help(card.tooltip)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.automatic)
    }
}

/// The day list (wx-day-list.c): day, 28-pt icon, rain chance, low, Apple Weather-style
/// temperature range bar, and high inside a high-contrast dark-slate Liquid Glass card.
private struct DayList: View {
    let rows: [DetailViewModel.DayRow]
    var currentTemperature: Int? = nil
    var isMetric: Bool = true

    private var overallLow: Int? {
        rows.compactMap(\.lowValue).min()
    }

    private var overallHigh: Int? {
        rows.compactMap(\.highValue).max()
    }

    var body: some View {
        let minTemp = overallLow
        let maxTemp = overallHigh
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let hasRain = WxConditionSymbol.precipitationRank(row.conditionCode) > 0
                    || (row.rainPercent ?? 0) >= 30
                HStack(spacing: 12) {
                    Text(row.day)
                        .font(.body.weight(index == 0 ? .bold : .semibold))
                        .foregroundStyle(WeatherTheme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    WeatherIconView(
                        assetName: row.iconAssetName,
                        symbolName: row.symbolName,
                        size: 28,
                        shadowRadius: 2
                    )
                    .frame(width: 34)
                    .accessibilityHidden(true)
                    Text(row.rain)
                        .font(.callout.weight(hasRain ? .bold : .medium))
                        .foregroundStyle(
                            hasRain
                                ? WeatherTheme.rainCyan
                                : WeatherTheme.secondaryText
                        )
                        .frame(minWidth: 44, alignment: .trailing)
                    Text(row.low)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(WeatherTheme.secondaryText)
                        .frame(minWidth: 40, alignment: .trailing)
                    if let minTemp, let maxTemp {
                        DayTemperatureBar(
                            low: row.lowValue,
                            high: row.highValue,
                            overallLow: minTemp,
                            overallHigh: maxTemp,
                            currentTemp: index == 0 ? currentTemperature : nil,
                            isMetric: isMetric
                        )
                        .frame(width: 130, height: 6)
                        .accessibilityHidden(true)
                    }
                    Text(row.high)
                        .font(.body.weight(.bold))
                        .foregroundStyle(WeatherTheme.primaryText)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 9)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .help(row.tooltip)
                .accessibilityElement(children: .combine)
                if row.id != rows.last?.id {
                    Divider()
                        .overlay(Color.white.opacity(0.18))
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 6)
        .weatherGlassCard(cornerRadius: 18)
    }
}

/// Apple Weather-style horizontal temperature range capsule bar for a single day row.
private struct DayTemperatureBar: View {
    let low: Int?
    let high: Int?
    let overallLow: Int
    let overallHigh: Int
    let currentTemp: Int?
    let isMetric: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = CGFloat(max(1, overallHigh - overallLow))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.28))
                    .frame(height: 6)

                if let low, let high {
                    let startFrac = max(0, min(1, CGFloat(low - overallLow) / span))
                    let endFrac = max(startFrac, min(1, CGFloat(high - overallLow) / span))
                    let xOffset = width * startFrac
                    let barWidth = max(6, width * (endFrac - startFrac))

                    Capsule()
                        .fill(WeatherTheme.temperatureGradient(low: low, high: high, isMetric: isMetric))
                        .frame(width: barWidth, height: 6)
                        .offset(x: xOffset)

                    if let currentTemp {
                        let clampedNow = max(low, min(high, currentTemp))
                        let nowFrac = max(0, min(1, CGFloat(clampedNow - overallLow) / span))
                        let dotX = min(max(3, width * nowFrac), max(3, width - 3))
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .overlay(
                                Circle()
                                    .strokeBorder(.black.opacity(0.45), lineWidth: 1.3)
                            )
                            .shadow(color: .black.opacity(0.30), radius: 1.5, x: 0, y: 0.5)
                            .offset(x: dotX - 4)
                    }
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(WeatherTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if page.showsRefreshing {
                ProgressView()
                    .tint(.white)
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

/// A high-contrast amber pill (style.css:133-139) with a tooltip.
private struct Badge: View {
    let text: String
    let tooltip: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.45), in: Capsule())
            .glassEffect(.regular.tint(.orange.opacity(0.45)), in: Capsule())
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
                        .foregroundStyle(WeatherTheme.rainCyan)
                } else {
                    Text(piece.text)
                        .foregroundStyle(WeatherTheme.secondaryText)
                }
            }
        }
        .font(.footnote.weight(.medium))
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
