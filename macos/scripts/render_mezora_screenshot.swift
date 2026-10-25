import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor
func savePNG<V: View>(_ view: V, width: CGFloat, height: CGFloat, to path: String) {
    let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, .dark))
    renderer.scale = 1.0
    guard let cgImage = renderer.cgImage else {
        fatalError("Failed to render CGImage for \(path)")
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Failed to create CGImageDestination for \(path)")
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Failed to finalize PNG at \(path)")
    }
    print("Saved \(path) (\(cgImage.width)x\(cgImage.height))")
}

struct PillLegend: View {
    let isBar: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            if isBar {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinearGradient(colors: [
                        Color(red: 0.22, green: 0.86, blue: 1.00),
                        Color(red: 0.14, green: 0.34, blue: 0.88)
                    ], startPoint: .top, endPoint: .bottom))
                    .frame(width: 9, height: 11)
            } else {
                ZStack {
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(red: 0.98, green: 0.62, blue: 0.16),
                            Color(red: 0.92, green: 0.36, blue: 0.58)
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 14, height: 2.5)
                    Circle()
                        .fill(Color(red: 0.98, green: 0.62, blue: 0.16))
                        .frame(width: 6, height: 6)
                }
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.94))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Color.white.opacity(0.09), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
    }
}

struct NowcastChartCanvas: View {
    let rates: [CGFloat] = [0.02, 0.05, 0.09, 0.10, 0.07, 0.04, 0.01, 0.00]
    let times = ["Now", "+15m", "+30m", "+45m", "+1h", "+1h15", "+1h30", "+1h45"]

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let leftPad: CGFloat = 68
                let rightPad: CGFloat = 10
                let topPad: CGFloat = 18
                let botPad: CGFloat = 20
                let plotW = w - leftPad - rightPad
                let plotH = h - topPad - botPad

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .frame(width: plotW, height: plotH)
                        .offset(x: leftPad, y: topPad)

                    // Grid lines
                    ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                        Path { p in
                            let y = topPad + plotH * CGFloat(frac)
                            p.move(to: CGPoint(x: leftPad, y: y))
                            p.addLine(to: CGPoint(x: leftPad + plotW, y: y))
                        }
                        .stroke(Color.white.opacity(frac == 1.0 ? 0.35 : 0.20),
                                style: StrokeStyle(lineWidth: 1, dash: frac == 1.0 ? [] : [3, 3]))
                    }

                    // Left axis labels
                    Text("Rate · 0.10 in/h")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00))
                        .position(x: leftPad / 2 - 2, y: topPad + 4)

                    Text("0.05 in/h")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00).opacity(0.85))
                        .position(x: leftPad / 2 + 8, y: topPad + plotH * 0.5)

                    Text("0 in/h")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00).opacity(0.8))
                        .position(x: leftPad / 2 + 12, y: topPad + plotH - 2)

                    // Bars
                    ForEach(0..<rates.count, id: \.self) { i in
                        let slotW = plotW / CGFloat(rates.count)
                        let barW = max(8, slotW * 0.56)
                        let frac = rates[i] / 0.10
                        let barH = max(frac > 0 ? 4 : 0, plotH * frac)
                        let x = leftPad + slotW * (CGFloat(i) + 0.5)
                        let y = topPad + plotH - barH / 2

                        if barH > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(LinearGradient(colors: [
                                    Color(red: 0.22, green: 0.86, blue: 1.00),
                                    Color(red: 0.06, green: 0.58, blue: 0.96),
                                    Color(red: 0.14, green: 0.34, blue: 0.88)
                                ], startPoint: .top, endPoint: .bottom))
                                .frame(width: barW, height: barH)
                                .position(x: x, y: y)
                        }
                        if i == 3 {
                            Text("0.10 in/h")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.68, green: 0.94, blue: 1.00))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.black.opacity(0.45), in: Capsule())
                                .position(x: x, y: topPad - 7)
                        }
                    }

                    // X labels
                    ForEach([0, 2, 4, 6], id: \.self) { i in
                        let slotW = plotW / CGFloat(rates.count)
                        let x = leftPad + slotW * (CGFloat(i) + 0.5)
                        Text(times[i])
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.86))
                            .position(x: x, y: topPad + plotH + 11)
                    }
                }
            }
        }
    }
}

struct HourlyChartCanvas: View {
    let rates: [CGFloat] = [
        0.04, 0.08, 0.10, 0.07, 0.03, 0.01, 0.00, 0.00,
        0.00, 0.00, 0.01, 0.03, 0.05, 0.04, 0.02, 0.00,
        0.00, 0.00, 0.00, 0.00, 0.01, 0.02, 0.01, 0.00
    ]
    let probs: [CGFloat] = [
        0.55, 0.78, 0.85, 0.72, 0.45, 0.25, 0.12, 0.08,
        0.08, 0.12, 0.28, 0.48, 0.62, 0.52, 0.30, 0.14,
        0.10, 0.08, 0.10, 0.15, 0.25, 0.34, 0.22, 0.12
    ]
    var showHoverBanner: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let leftPad: CGFloat = 68
            let rightPad: CGFloat = 38
            let topPad: CGFloat = 22
            let botPad: CGFloat = 20
            let plotW = w - leftPad - rightPad
            let plotH = h - topPad - botPad

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .frame(width: plotW, height: plotH)
                    .offset(x: leftPad, y: topPad)

                // Grid lines
                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                    Path { p in
                        let y = topPad + plotH * CGFloat(frac)
                        p.move(to: CGPoint(x: leftPad, y: y))
                        p.addLine(to: CGPoint(x: leftPad + plotW, y: y))
                    }
                    .stroke(Color.white.opacity(frac == 1.0 ? 0.35 : 0.20),
                            style: StrokeStyle(lineWidth: 1, dash: frac == 1.0 ? [] : [3, 3]))
                }

                // Left axis labels
                Text("Rate · 0.10 in/h")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00))
                    .position(x: leftPad / 2 - 2, y: topPad + 4)

                Text("0.05 in/h")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00).opacity(0.85))
                    .position(x: leftPad / 2 + 8, y: topPad + plotH * 0.5)

                Text("0 in/h")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.60, green: 0.92, blue: 1.00).opacity(0.8))
                    .position(x: leftPad / 2 + 12, y: topPad + plotH - 2)

                // Right axis labels
                Text("100%")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 1.00, green: 0.80, blue: 0.54))
                    .position(x: leftPad + plotW + 19, y: topPad + 4)

                Text("50%")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1.00, green: 0.80, blue: 0.54).opacity(0.85))
                    .position(x: leftPad + plotW + 17, y: topPad + plotH * 0.5)

                Text("0%")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1.00, green: 0.80, blue: 0.54).opacity(0.8))
                    .position(x: leftPad + plotW + 15, y: topPad + plotH - 2)

                // Bars
                ForEach(0..<rates.count, id: \.self) { i in
                    let slotW = plotW / CGFloat(rates.count)
                    let barW = max(4.5, slotW * 0.58)
                    let frac = rates[i] / 0.10
                    let barH = max(frac > 0 ? 3 : 0, plotH * frac)
                    let x = leftPad + slotW * (CGFloat(i) + 0.5)
                    let y = topPad + plotH - barH / 2

                    if barH > 0 {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(LinearGradient(colors: [
                                Color(red: 0.22, green: 0.86, blue: 1.00),
                                Color(red: 0.06, green: 0.58, blue: 0.96),
                                Color(red: 0.14, green: 0.34, blue: 0.88)
                            ], startPoint: .top, endPoint: .bottom))
                            .frame(width: barW, height: barH)
                            .position(x: x, y: y)
                    }
                }

                // Smooth curve area + line
                let points: [CGPoint] = (0..<probs.count).map { i in
                    let slotW = plotW / CGFloat(probs.count)
                    let x = leftPad + slotW * (CGFloat(i) + 0.5)
                    let y = topPad + plotH * (1.0 - probs[i])
                    return CGPoint(x: x, y: y)
                }

                Path { p in
                    guard let first = points.first, let last = points.last else { return }
                    p.move(to: CGPoint(x: first.x, y: topPad + plotH))
                    p.addLine(to: first)
                    for i in 1..<points.count {
                        let prev = points[i - 1]
                        let cur = points[i]
                        let midX = (prev.x + cur.x) / 2
                        p.addCurve(to: cur, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: cur.y))
                    }
                    p.addLine(to: CGPoint(x: last.x, y: topPad + plotH))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [
                    Color(red: 0.98, green: 0.62, blue: 0.16).opacity(0.26),
                    Color(red: 0.92, green: 0.36, blue: 0.58).opacity(0.12),
                    Color.clear
                ], startPoint: .top, endPoint: .bottom))

                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for i in 1..<points.count {
                        let prev = points[i - 1]
                        let cur = points[i]
                        let midX = (prev.x + cur.x) / 2
                        p.addCurve(to: cur, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: cur.y))
                    }
                }
                .stroke(LinearGradient(colors: [
                    Color(red: 0.98, green: 0.62, blue: 0.16),
                    Color(red: 0.92, green: 0.36, blue: 0.58),
                    Color(red: 0.68, green: 0.44, blue: 0.96)
                ], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

                // Peak node
                if points.count > 2 {
                    let pk = points[2]
                    Circle()
                        .fill(Color(red: 0.98, green: 0.62, blue: 0.16))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
                        .position(pk)

                    if showHoverBanner {
                        Path { p in
                            p.move(to: CGPoint(x: pk.x, y: topPad))
                            p.addLine(to: CGPoint(x: pk.x, y: topPad + plotH))
                        }
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                        Text("4 PM · Bar: 0.10 in/h · Chance: 85%")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.12, green: 0.16, blue: 0.24).opacity(0.92), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7))
                            .position(x: pk.x + 76, y: topPad + 10)
                    } else {
                        Text("85%")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 1.00, green: 0.84, blue: 0.58))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.45), in: Capsule())
                            .position(x: pk.x + 18, y: pk.y - 10)
                    }
                }

                // X axis labels
                let xLabels: [(Int, String)] = [(0, "2 PM"), (6, "8 PM"), (12, "2 AM"), (18, "8 AM")]
                ForEach(xLabels, id: \.0) { (idx, label) in
                    let slotW = plotW / CGFloat(probs.count)
                    let x = leftPad + slotW * (CGFloat(idx) + 0.5)
                    Text(label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .position(x: x, y: topPad + plotH + 11)
                }
            }
        }
    }
}

struct RainCardShowcase: View {
    var showHoverBanner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "umbrella.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                Text("RAIN")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color(red: 0.84, green: 0.89, blue: 0.96))
                Spacer()
                Text("15-min Nowcast + 13-Model Regional Ensemble")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.75))
            }

            Text("Raining now, peaking around 4 PM, easing by 7 PM")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Next 2 hours: up to 0.10 in/h · 24-hour total: 0.42 in (85% chance)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.92, green: 0.95, blue: 0.99))

            HStack(alignment: .top, spacing: 14) {
                // Left chart: Next 2 hours
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Next 2 hours")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("· 15-min bars")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                        Spacer()
                    }
                    PillLegend(isBar: true, text: "Bars: Rain rate (in/h, left)")
                    NowcastChartCanvas()
                        .frame(height: 126)
                }
                .padding(11)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))

                // Right chart: Next 24 hours
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Next 24 hours")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("· Hourly bars & curve")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        PillLegend(isBar: true, text: "Bars: Rain rate (in/h, left)")
                        PillLegend(isBar: false, text: "Line: Rain chance (%, right)")
                    }
                    HourlyChartCanvas(showHoverBanner: showHoverBanner)
                        .frame(height: 126)
                }
                .padding(11)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
            }
            .padding(.top, 2)
        }
        .padding(18)
        .background(Color(red: 0.28, green: 0.35, blue: 0.45).opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.26), lineWidth: 0.9))
    }
}

struct SidebarPlaceItem: View {
    let title: String
    let subtitle: String
    let temp: String
    let condition: String
    let symbol: String
    let selected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.black.opacity(0.32), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.76))
                Text(condition)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.84, green: 0.91, blue: 0.99))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 20))
                Text(temp)
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(selected
                      ? Color(red: 0.25, green: 0.42, blue: 0.62).opacity(0.92)
                      : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.36 : 0.10), lineWidth: selected ? 1.0 : 0.6)
        )
    }
}

struct MezoraWindowView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.38, green: 0.46, blue: 0.56),
                    Color(red: 0.31, green: 0.39, blue: 0.49),
                    Color(red: 0.24, green: 0.31, blue: 0.41)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                // macOS Titlebar
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                    }
                    .padding(.leading, 8)

                    HStack(spacing: 6) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 24)
                            .background(Color.white.opacity(0.14), in: Capsule())
                        Image(systemName: "plus")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 24)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }

                    Spacer()

                    Text("Neginato Mezora")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))

                    Spacer()

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(Color(red: 0.31, green: 0.88, blue: 0.65)).frame(width: 7, height: 7)
                            Text("13 NWP + 15 STATION NETS")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.28), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.6))

                        ForEach(["arrow.clockwise", "°F", "gearshape"], id: \.self) { item in
                            Group {
                                if item == "°F" {
                                    Text("°F").font(.system(size: 12, weight: .bold, design: .rounded))
                                } else {
                                    Image(systemName: item).font(.system(size: 12, weight: .bold))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 24)
                            .background(Color.black.opacity(0.28), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.7))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color(red: 0.16, green: 0.21, blue: 0.28).opacity(0.92))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
                }

                // Main Split View
                HStack(spacing: 0) {
                    // Left Sidebar
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PLACES")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .padding(.horizontal, 6)
                            .padding(.top, 4)

                        SidebarPlaceItem(
                            title: "New York",
                            subtitle: "350 5th Ave · Manhattan, NY",
                            temp: "64°",
                            condition: "Light Rain · H:68° L:54°",
                            symbol: "cloud.rain.fill",
                            selected: true,
                            badge: "NWS + HRRR"
                        )
                        SidebarPlaceItem(
                            title: "Amsterdam",
                            subtitle: "North Holland · Netherlands",
                            temp: "58°",
                            condition: "Showers · H:60° L:49°",
                            symbol: "cloud.sun.rain.fill",
                            selected: false,
                            badge: "KNMI 2km"
                        )
                        SidebarPlaceItem(
                            title: "Munich",
                            subtitle: "Bavaria · Germany",
                            temp: "61°",
                            condition: "Partly Cloudy · H:64° L:47°",
                            symbol: "cloud.sun.fill",
                            selected: false,
                            badge: "DWD MOSMIX"
                        )
                        SidebarPlaceItem(
                            title: "London",
                            subtitle: "England · United Kingdom",
                            temp: "59°",
                            condition: "Overcast · H:62° L:51°",
                            symbol: "cloud.fill",
                            selected: false,
                            badge: "UKV 2km"
                        )
                        SidebarPlaceItem(
                            title: "Toronto",
                            subtitle: "Ontario · Canada",
                            temp: "55°",
                            condition: "Mostly Clear · H:59° L:44°",
                            symbol: "sun.max.fill",
                            selected: false,
                            badge: "ECCC HRDPS"
                        )
                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                            Text("Open-Meteo · NWS · MET No · DWD · ECCC")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.75))
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                    .padding(14)
                    .frame(width: 288)
                    .background(Color(red: 0.14, green: 0.19, blue: 0.26).opacity(0.78))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
                    }

                    // Detail Pane
                    VStack(alignment: .leading, spacing: 14) {
                        // Header + Now row
                        HStack(alignment: .center, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(Color(red: 0.48, green: 0.86, blue: 1.00))
                                    Text("New York")
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("350 5th Ave, Manhattan, NY · 42m DEM")
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.84))
                                }

                                HStack(spacing: 8) {
                                    ForEach([
                                        ("thermometer.medium", "Feels like 62°F · Dew point 58°F"),
                                        ("arrow.up.and.down", "High 68° · Low 54°"),
                                        ("wind", "Wind 11 mph SSW (gusts 19 mph)"),
                                        ("antenna.radiowaves.left.and.right", "12 stations (METAR/ASOS/IEM) · −1.2°F learned bias")
                                    ], id: \.1) { (sym, label) in
                                        HStack(spacing: 5) {
                                            Image(systemName: sym)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                                            Text(label)
                                                .font(.system(size: 11.5, weight: .medium))
                                                .foregroundStyle(Color.white.opacity(0.94))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4.5)
                                        .background(Color.black.opacity(0.24), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
                                    }
                                }
                            }
                            Spacer()
                            HStack(spacing: 12) {
                                Image(systemName: "cloud.rain.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .font(.system(size: 46))
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text("64°F")
                                        .font(.system(size: 46, weight: .thin, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("Light Rain")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.88, green: 0.94, blue: 1.0))
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.28, green: 0.35, blue: 0.45).opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.26), lineWidth: 0.9))

                        // Rain Card
                        RainCardShowcase(showHoverBanner: true)

                        // Bottom Row: Air Quality + Clouds + Ensemble Weights summary
                        HStack(alignment: .top, spacing: 14) {
                            // Air Quality Card
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "aqi.medium")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color(red: 0.31, green: 0.88, blue: 0.65))
                                    Text("AIR QUALITY · US EPA AIRNOW (PRELIMINARY)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .tracking(0.7)
                                        .foregroundStyle(Color(red: 0.84, green: 0.89, blue: 0.96))
                                    Spacer()
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("28 — Good")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("PM2.5 (6.8 µg/m³) · 4 pts lower than yesterday")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                }
                                ZStack(alignment: .leading) {
                                    HStack(spacing: 2) {
                                        Rectangle().fill(Color(red: 0.19, green: 0.82, blue: 0.35))
                                        Rectangle().fill(Color(red: 1.00, green: 0.84, blue: 0.04))
                                        Rectangle().fill(Color(red: 1.00, green: 0.62, blue: 0.04))
                                        Rectangle().fill(Color(red: 1.00, green: 0.27, blue: 0.23))
                                        Rectangle().fill(Color(red: 0.75, green: 0.35, blue: 0.95))
                                        Rectangle().fill(Color(red: 0.52, green: 0.14, blue: 0.24))
                                    }
                                    .frame(height: 7)
                                    .clipShape(Capsule())
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5))
                                        .offset(x: 42)
                                }
                                Text("Nearest monitor within 45 km as reported · compared with same monitor 24h ago.")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.82))
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(Color(red: 0.28, green: 0.35, blue: 0.45).opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8))

                            // Clouds & Ensemble Status Card
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "cloud.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                                    Text("CLOUDS & ENSEMBLE BLEND")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .tracking(0.7)
                                        .foregroundStyle(Color(red: 0.84, green: 0.89, blue: 0.96))
                                    Spacer()
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("78% Overcast")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("Clearing around 8 PM · Wet-bulb 60°F")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                }
                                HStack(spacing: 6) {
                                    ForEach(["NWS Grid", "HRRR 3km", "ECMWF IFS", "UKV 2km", "KNMI 2km", "DWD MOSMIX", "ECCC HRDPS"], id: \.self) { m in
                                        Text(m)
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.92))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                }
                                Text("13 NWP models · 15 station networks · learned hourly local bias (±4°C).")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.82))
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .background(Color(red: 0.28, green: 0.35, blue: 0.45).opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8))
                        }

                        // Hourly Forecast Strip
                        VStack(alignment: .leading, spacing: 8) {
                            Text("NEXT 48 HOURS")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(Color(red: 0.84, green: 0.89, blue: 0.96))

                            HStack(spacing: 10) {
                                let hrs: [(String, String, String, String)] = [
                                    ("Now", "cloud.rain.fill", "75%", "64°"),
                                    ("3 PM", "cloud.rain.fill", "80%", "64°"),
                                    ("4 PM", "cloud.heavyrain.fill", "85%", "63°"),
                                    ("5 PM", "cloud.rain.fill", "70%", "63°"),
                                    ("6 PM", "cloud.drizzle.fill", "45%", "62°"),
                                    ("7 PM", "cloud.fill", "25%", "61°"),
                                    ("8 PM", "cloud.moon.fill", "12%", "60°"),
                                    ("9 PM", "moon.stars.fill", "8%", "59°"),
                                    ("10 PM", "moon.stars.fill", "8%", "58°"),
                                    ("11 PM", "moon.stars.fill", "10%", "57°")
                                ]
                                ForEach(hrs, id: \.0) { (t, sym, pct, tmp) in
                                    VStack(spacing: 5) {
                                        Text(t)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.white.opacity(0.9))
                                        Image(systemName: sym)
                                            .symbolRenderingMode(.multicolor)
                                            .font(.system(size: 18))
                                        Text(pct)
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 1.00))
                                        Text(tmp)
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(red: 0.28, green: 0.35, blue: 0.45).opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8))

                        Spacer(minLength: 0)
                    }
                    .padding(18)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

@main
struct RenderMain {
    static func main() {
        MainActor.assumeIsolated {
            savePNG(
                MezoraWindowView(),
                width: 1308,
                height: 902,
                to: "/Users/mborodia/Developer/neginato.app/assets/screenshot-mezora-20261025b.png"
            )
            savePNG(
                RainCardShowcase(showHoverBanner: true)
                    .padding(12)
                    .background(Color(red: 0.20, green: 0.26, blue: 0.35)),
                width: 1308,
                height: 312,
                to: "/Users/mborodia/Developer/neginato.app/assets/screenshot-mezora-rain-20261025b.png"
            )
        }
    }
}
