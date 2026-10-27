// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WindCompassView.swift - the wind compass dial on the right of the Now card: a thin
// luminous ring with light minor ticks and four cardinal ticks, N/E/S/W, the speed and
// its unit in the centre, a dot riding the ring at the bearing the wind blows FROM and a
// slender arrow crossing the centre toward the downwind side, and a caption under the dial
// ("Gusts 25 mph · from NNE 31°"). Pure SwiftUI drawing in WeatherTheme's white-on-slate
// vocabulary (no accent colour, so nothing competes with the temperature).
// Calm wind shows "Calm" and an unknown direction shows the speed only; neither draws the
// dot or the arrow. All values and the VoiceOver label come from DetailViewModel.NowWind.
// View-local strings (the exception to DetailView.swift's view-model rule): the compass
// letters "N" "E" "S" "W", "Calm" and the caption prefix "Gusts ".

import SwiftUI
import WeatherCore

struct WindCompassView: View {
    /// large: a 100 pt dial with the two-line caption to its left (wide cards); side: the same
    /// at 72 pt, sized to sit beside the temperature line; compact: a 72 pt dial with the
    /// caption under it, for the narrowest cards.
    enum Size { case large, side, compact }

    let wind: DetailViewModel.NowWind
    var size: Size = .large

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The angle last drawn, unwrapped (it may leave 0..<360) so a change swings the short way.
    @State private var vaneAngle: Double?

    private var diameter: CGFloat { size == .large ? 100 : 72 }

    private var gustCaption: String? { wind.gustText.map { "Gusts " + $0 } }

    /// "Gusts 25 mph · from NNE 31°" (tooltip); the gust part only when there are gusts.
    private var fullCaption: String? {
        let parts = [gustCaption, wind.directionText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The caption as laid out: gusts, then "from NNE 31°", one per line.
    private var caption: String? {
        let lines = [gustCaption, wind.directionText].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var body: some View {
        Group {
            if size == .compact {
                VStack(spacing: 2) {
                    sizedDial
                    captionText(alignment: .center)
                }
            } else {
                HStack(spacing: 8) {
                    captionText(alignment: .trailing)
                    sizedDial
                }
            }
        }
        .help(fullCaption ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text(wind.accessibilityLabel))
        .onChange(of: wind.directionDeg, initial: true) { _, target in swing(to: target) }
    }

    @ViewBuilder private func captionText(alignment: TextAlignment) -> some View {
        if let caption {
            Text(caption)
                .font(.system(size: size == .large ? 11 : 10, weight: .medium, design: .rounded))
                .foregroundStyle(WeatherTheme.secondaryText)
                .multilineTextAlignment(alignment)
                .lineLimit(2)
                .fixedSize()
        }
    }

    private var sizedDial: some View {
        dial.frame(width: diameter, height: diameter)
    }

    /// Moves the vane to a new bearing by the shorter way round (at most 180°): a short ease
    /// normally, an instant jump under Reduce Motion or on first appearance.
    private func swing(to target: Double?) {
        guard let target else { vaneAngle = nil; return }
        guard let from = vaneAngle else { vaneAngle = target; return }
        var delta = (target - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        if reduceMotion {
            vaneAngle = from + delta
        } else {
            withAnimation(.easeOut(duration: 0.45)) { vaneAngle = from + delta }
        }
    }

    private var dial: some View {
        let s = diameter / 92
        return ZStack {
            CompassFace(scale: s)
            CompassLetters(scale: s, vaneBearing: wind.isCalm ? nil : (vaneAngle ?? wind.directionDeg))
            centre(scale: s)
            if let bearing = wind.directionDeg, !wind.isCalm {
                WindVane(scale: s)
                    .rotationEffect(.degrees(vaneAngle ?? bearing))
            }
        }
    }

    private func centre(scale s: CGFloat) -> some View {
        VStack(spacing: -2 * s) {
            Text(wind.isCalm ? "Calm" : wind.speedText)
                .font(.system(size: (wind.isCalm ? 14 : wind.speedText.count >= 3 ? 23 : 27) * s,
                              weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WeatherTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !wind.isCalm {
                Text(wind.unitText)
                    .font(.system(size: 9 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(WeatherTheme.secondaryText.opacity(0.9))
            }
        }
        .frame(width: 44 * s)
        .offset(y: -1 * s)
    }
}

/// The ring geometry shared by the face and the vane (a 92 pt dial at scale 1).
private enum CompassMetrics {
    static let ringInset: CGFloat = 4      // ring line from the frame edge (room for the dot)
    static let tickGap: CGFloat = 3        // ticks start this far inside the ring
    static let letterInset: CGFloat = 14.5 // letter centres inside the ring (clear of the cardinal ticks)
    static let hubRadius: CGFloat = 21     // the arrow keeps clear of the speed number
}

/// Faint glass disc, a top-lit hairline ring and the tick ring (a light tick every 15°, 4 cardinal).
private struct CompassFace: View {
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            Circle()
                .inset(by: CompassMetrics.ringInset * s)
                .fill(RadialGradient(colors: [Color.white.opacity(0.07), Color.black.opacity(0.10)],
                                     center: .center, startRadius: 0, endRadius: 44 * s))
            Circle()
                .inset(by: CompassMetrics.ringInset * s)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let rOut = size.width / 2 - (CompassMetrics.ringInset + CompassMetrics.tickGap) * s
                for i in 0..<24 {
                    let major = i % 6 == 0
                    let len = (major ? 3.8 : 2.4) * s
                    let a = Double(i) * .pi / 12
                    let dx = CGFloat(sin(a)), dy = CGFloat(-cos(a))
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + dx * rOut, y: c.y + dy * rOut))
                    p.addLine(to: CGPoint(x: c.x + dx * (rOut - len), y: c.y + dy * (rOut - len)))
                    let alpha = major ? (i == 0 ? 0.95 : 0.7) : 0.24
                    ctx.stroke(p, with: .color(.white.opacity(alpha)),
                               style: StrokeStyle(lineWidth: major ? 1.5 : 0.8, lineCap: .round))
                }
            }
        }
    }
}

/// N/E/S/W in a small rounded face, E/S/W at 72% so the bold N stays the strongest. A letter the
/// vane crosses (within 20° of the bearing or of its downwind side) fades out of its way.
private struct CompassLetters: View {
    let scale: CGFloat
    let vaneBearing: Double?

    private func clearance(_ letterDeg: Double) -> Double {
        guard let b = vaneBearing else { return 1 }
        let d = abs((letterDeg - b).truncatingRemainder(dividingBy: 180))
        return min(1, min(d, 180 - d) / 20)
    }

    var body: some View {
        GeometryReader { geo in
            let r = geo.size.width / 2 - (CompassMetrics.ringInset + CompassMetrics.letterInset) * scale
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ForEach(Array(["N", "E", "S", "W"].enumerated()), id: \.offset) { i, letter in
                let a = Double(i) * .pi / 2
                Text(letter)
                    .font(.system(size: 8.5 * scale, weight: i == 0 ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(WeatherTheme.secondaryText.opacity((i == 0 ? 1.0 : 0.72) * clearance(Double(i) * 90)))
                    .position(x: c.x + CGFloat(sin(a)) * r, y: c.y - CGFloat(cos(a)) * r)
            }
        }
    }
}

/// Drawn for a wind FROM north (dot at the top, arrowhead pointing south) and rotated by the
/// bearing: the dot rides the ring, a hairline tail runs in toward the hub, and a tapered
/// shaft with a swept arrowhead leaves the hub on the downwind side.
private struct WindVane: View {
    let scale: CGFloat

    var body: some View {
        let s = scale
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = size.width / 2 - CompassMetrics.ringInset * s
            let hub = CompassMetrics.hubRadius * s
            let tipY = c.y + ring - 6 * s
            // Tail: dot edge -> hub, tapering from a hairline to 1.2 pt.
            var tail = Path()
            tail.move(to: CGPoint(x: c.x - 0.3 * s, y: c.y - ring + 4 * s))
            tail.addLine(to: CGPoint(x: c.x + 0.3 * s, y: c.y - ring + 4 * s))
            tail.addLine(to: CGPoint(x: c.x + 0.6 * s, y: c.y - hub))
            tail.addLine(to: CGPoint(x: c.x - 0.6 * s, y: c.y - hub))
            tail.closeSubpath()
            ctx.fill(tail, with: .linearGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0.25)]),
                                                 startPoint: CGPoint(x: c.x, y: c.y - ring),
                                                 endPoint: CGPoint(x: c.x, y: c.y - hub)))
            // Head: hub -> tip, a 1.6 pt shaft into a swept arrowhead.
            let headLen = 11 * s, headHalf = 4.6 * s, notch = 3.2 * s
            var head = Path()
            head.move(to: CGPoint(x: c.x - 0.5 * s, y: c.y + hub))
            head.addLine(to: CGPoint(x: c.x + 0.5 * s, y: c.y + hub))
            head.addLine(to: CGPoint(x: c.x + 1.0 * s, y: tipY - headLen + notch))
            head.addLine(to: CGPoint(x: c.x + headHalf, y: tipY - headLen))
            head.addLine(to: CGPoint(x: c.x, y: tipY))
            head.addLine(to: CGPoint(x: c.x - headHalf, y: tipY - headLen))
            head.addLine(to: CGPoint(x: c.x - 1.0 * s, y: tipY - headLen + notch))
            head.closeSubpath()
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .white.opacity(0.55), radius: 3 * s))
                layer.fill(head, with: .linearGradient(Gradient(colors: [.white.opacity(0.35), .white]),
                                                       startPoint: CGPoint(x: c.x, y: c.y + hub),
                                                       endPoint: CGPoint(x: c.x, y: tipY)))
                // The dot at the "from" bearing, on the ring line, with a slate halo.
                let d = 7 * s
                let dot = Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - ring - d / 2, width: d, height: d))
                layer.fill(dot, with: .color(.white))
            }
            let d = 7 * s
            let halo = Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - ring - d / 2, width: d, height: d))
            ctx.stroke(halo, with: .color(Color(red: 0.24, green: 0.30, blue: 0.38).opacity(0.9)), lineWidth: 1.2 * s)
        }
    }
}
