// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeatherTheme.swift - shared macOS 27 Apple Weather visual primitives, rich bundled
// weather condition icons, high-contrast slate backdrops and card surfaces, AQI
// spectrum bar gradients, and temperature-spectrum color gradients.

import AppKit
import SwiftUI
import WeatherCore

/// Renders a rich multi-color vector weather icon from `Assets.xcassets`, falling back to
/// the SF Symbol when an asset is unavailable.
struct WeatherIconView: View {
    let assetName: String
    let symbolName: String
    var size: CGFloat = 32
    var shadowRadius: CGFloat = 4

    var body: some View {
        Group {
            if let nsImage = NSImage(named: assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.multicolor)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: shadowRadius, x: 0, y: 2)
    }
}

/// Subdued Apple Weather-style vertical sky backdrop using medium steel and cloud-slate
/// hues during the day and deep midnight-slate hues at night so crisp white hero text and
/// darker slate-blue Liquid Glass cards always have high contrast.
struct WeatherSkyBackground: View {
    var condition: WxCondition = .clear
    var isDay: Bool = true

    var body: some View {
        let palette = Self.palette(for: condition, isDay: isDay)
        LinearGradient(
            stops: [
                .init(color: palette.top, location: 0.0),
                .init(color: palette.middle, location: 0.48),
                .init(color: palette.bottom, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private struct Palette {
        let top: Color
        let middle: Color
        let bottom: Color
    }

    private static func palette(for condition: WxCondition, isDay: Bool) -> Palette {
        if !isDay {
            switch condition {
            case .thunderstorm:
                return Palette(
                    top: Color(red: 0.16, green: 0.18, blue: 0.25),
                    middle: Color(red: 0.13, green: 0.15, blue: 0.21),
                    bottom: Color(red: 0.10, green: 0.12, blue: 0.17)
                )
            default:
                return Palette(
                    top: Color(red: 0.17, green: 0.21, blue: 0.29),
                    middle: Color(red: 0.14, green: 0.18, blue: 0.25),
                    bottom: Color(red: 0.11, green: 0.14, blue: 0.20)
                )
            }
        }

        switch condition {
        case .clear, .mostlyClear:
            return Palette(
                top: Color(red: 0.40, green: 0.54, blue: 0.69),
                middle: Color(red: 0.46, green: 0.59, blue: 0.73),
                bottom: Color(red: 0.39, green: 0.52, blue: 0.66)
            )

        case .partlyCloudy, .mostlyCloudy:
            // Matches Apple Weather's daytime cloudy/partly-cloudy slate sky (#8595A8 -> #6E7F93).
            return Palette(
                top: Color(red: 0.52, green: 0.59, blue: 0.67),
                middle: Color(red: 0.48, green: 0.55, blue: 0.64),
                bottom: Color(red: 0.43, green: 0.50, blue: 0.59)
            )

        case .overcast, .fog:
            return Palette(
                top: Color(red: 0.49, green: 0.55, blue: 0.62),
                middle: Color(red: 0.45, green: 0.51, blue: 0.58),
                bottom: Color(red: 0.40, green: 0.46, blue: 0.53)
            )

        case .drizzle, .lightRain, .showers, .rain, .heavyRain:
            return Palette(
                top: Color(red: 0.44, green: 0.51, blue: 0.60),
                middle: Color(red: 0.40, green: 0.47, blue: 0.56),
                bottom: Color(red: 0.36, green: 0.43, blue: 0.52)
            )

        case .thunderstorm:
            return Palette(
                top: Color(red: 0.38, green: 0.43, blue: 0.52),
                middle: Color(red: 0.34, green: 0.39, blue: 0.48),
                bottom: Color(red: 0.30, green: 0.35, blue: 0.44)
            )

        case .snow, .sleet:
            return Palette(
                top: Color(red: 0.50, green: 0.58, blue: 0.67),
                middle: Color(red: 0.46, green: 0.54, blue: 0.63),
                bottom: Color(red: 0.42, green: 0.50, blue: 0.59)
            )

        case .unknown:
            return Palette(
                top: Color(red: 0.48, green: 0.55, blue: 0.64),
                middle: Color(red: 0.44, green: 0.51, blue: 0.60),
                bottom: Color(red: 0.40, green: 0.47, blue: 0.56)
            )
        }
    }
}

/// High-contrast Apple Weather surface tokens, AQI gradient bar, and temperature color helpers.
enum WeatherTheme {
    /// Crisp pure white for primary numbers, titles, and values on slate cards.
    static let primaryText = Color.white
    /// High-contrast 92% ice-white for secondary descriptions, lows, and subtitles (never grey-on-blue).
    static let secondaryText = Color(red: 0.92, green: 0.95, blue: 0.99)
    /// Uppercase card section header tint (e.g. AIR QUALITY, RAIN, CLOUDS).
    static let cardHeaderText = Color(red: 0.84, green: 0.89, blue: 0.96)
    /// Vibrant sky-cyan used by Apple Weather for precipitation probabilities (35%, 70%).
    static let rainCyan = Color(red: 0.44, green: 0.88, blue: 1.00)

    /// Medium-deep slate-blue card backing color matching Apple Weather's frosted slate modules.
    static let cardBacking = Color(red: 0.33, green: 0.40, blue: 0.49).opacity(0.86)
    /// Liquid Glass tint for weather cards.
    static let cardGlassTint = Color(red: 0.31, green: 0.38, blue: 0.47).opacity(0.65)

    /// The AQI scale of the Air Quality card, Good -> Hazardous.
    static let aqiGradient: LinearGradient = {
        // The EPA category colours (AQI Technical Assistance Document, Sept 2018), one equal band
        // per category: Good, Moderate, Unhealthy for Sensitive Groups, Unhealthy, Very
        // Unhealthy, Hazardous.
        let colors: [Color] = [
            Color(red: 0 / 255, green: 228 / 255, blue: 0 / 255),
            Color(red: 255 / 255, green: 255 / 255, blue: 0 / 255),
            Color(red: 255 / 255, green: 126 / 255, blue: 0 / 255),
            Color(red: 255 / 255, green: 0 / 255, blue: 0 / 255),
            Color(red: 143 / 255, green: 63 / 255, blue: 151 / 255),
            Color(red: 126 / 255, green: 0 / 255, blue: 35 / 255),
        ]
        let stops = colors.enumerated().flatMap { i, color in
            [Gradient.Stop(color: color, location: Double(i) / 6), Gradient.Stop(color: color, location: Double(i + 1) / 6)]
        }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }()

    /// Detects whether `now.temperature` is formatted in Celsius (`°C`).
    static func isMetric(temperatureText: String) -> Bool {
        temperatureText.contains("C")
    }

    /// Maps a temperature in the active unit (`isMetric`: °C vs °F) to an Apple Weather
    /// spectrum color (icy cyan -> sky blue -> emerald teal -> warm gold -> amber -> coral red).
    static func temperatureColor(for value: Int, isMetric: Bool) -> Color {
        let celsius = isMetric ? Double(value) : (Double(value) - 32.0) * 5.0 / 9.0
        switch celsius {
        case ..<(-5):
            return Color(red: 0.28, green: 0.82, blue: 1.00) // icy cyan
        case -5..<5:
            return Color(red: 0.24, green: 0.68, blue: 0.98) // cold azure
        case 5..<14:
            return Color(red: 0.22, green: 0.84, blue: 0.72) // cool teal
        case 14..<20:
            return Color(red: 0.52, green: 0.86, blue: 0.34) // mild green-gold
        case 20..<26:
            return Color(red: 0.98, green: 0.76, blue: 0.14) // warm amber-gold
        case 26..<32:
            return Color(red: 1.00, green: 0.54, blue: 0.12) // hot orange
        default:
            return Color(red: 0.96, green: 0.30, blue: 0.26) // scorching coral-red
        }
    }

    /// Builds a smooth horizontal gradient spanning from `low` to `high`.
    static func temperatureGradient(low: Int, high: Int, isMetric: Bool) -> LinearGradient {
        let mid = (low + high) / 2
        let colors: [Color]
        if high - low <= 3 {
            colors = [
                temperatureColor(for: low, isMetric: isMetric),
                temperatureColor(for: high, isMetric: isMetric),
            ]
        } else {
            colors = [
                temperatureColor(for: low, isMetric: isMetric),
                temperatureColor(for: mid, isMetric: isMetric),
                temperatureColor(for: high, isMetric: isMetric),
            ]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// Reusable modifier that gives any card Apple Weather's medium-deep slate-glass surface
/// and high-contrast white rim border.
struct WeatherGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(WeatherTheme.cardBacking, in: shape)
            .glassEffect(.regular.tint(WeatherTheme.cardGlassTint), in: shape)
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(0.26), lineWidth: 0.8)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func weatherGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(WeatherGlassCardModifier(cornerRadius: cornerRadius))
    }
}
