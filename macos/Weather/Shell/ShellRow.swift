// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellRow.swift - one sidebar row (WxRow, wx-row.c:1105-1180, style.css:6-49; ui-widgets.md §2
// items 16-18): the 32 pt condition icon, the bold name, the region and the hint (0.85em,
// opacity 0.7), the temperature (1.6em, weight 300, tabular digits) with the marker pill below,
// and the flat "…" menu (Move up, Move down, Remove; always enabled, no confirmation). The row
// is a MOVE-only drag source of its key and a drop target for one string (wx-row.c:1171-1179);
// a hovering drop draws a 2 px #3584e4 line at the top. Every text comes from RowViewModel.

import AppKit
import SwiftUI
import WeatherCore

/// The sidebar row of one saved place.
struct ShellRow: View {
    let row: RowViewModel
    /// A menu or accessibility action (RowViewModel.perform).
    let onAction: (RowViewModel.Action) -> Void
    /// A drop of the first dropped string (RowViewModel.acceptDrop); true when it moved a row.
    let onDrop: (String?) -> Bool

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            WeatherIconView(
                assetName: row.iconAssetName,
                symbolName: row.symbolName,
                size: 36,
                shadowRadius: 3
            )
            .opacity(Self.iconOpacity(row))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                    .modifier(Self.SingleLine(maxChars: 24, minChars: 10, fontSize: Self.baseSize))
                if row.isRegionVisible {
                    Text(row.region)
                        .font(.system(size: Self.baseSize * 0.85, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .modifier(Self.SingleLine(maxChars: 28, fontSize: Self.baseSize * 0.85))
                }
                Text(row.hint)
                    .font(.system(size: Self.baseSize * 0.85, weight: .medium))
                    .foregroundStyle(Color.white.opacity(row.isDim ? 0.72 : 0.92))
                    .modifier(Self.SingleLine(maxChars: 28, fontSize: Self.baseSize * 0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.temperature)
                    .font(.system(size: Self.baseSize * 1.65, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .opacity(Self.temperatureOpacity(row))
                    .lineLimit(1)
                    .frame(minWidth: Self.charWidth(fontSize: Self.baseSize * 1.65) * 4, alignment: .trailing)
                if row.isMarkerVisible {
                    Text(row.markerText)
                        .font(.system(size: Self.baseSize * 0.75, weight: .bold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.orange.opacity(0.55), in: Capsule())
                        .glassEffect(.regular.tint(.orange.opacity(0.45)), in: Capsule())
                }
            }
            Menu {
                ForEach(RowViewModel.menuActions, id: \.self) { action in
                    Button(action.title) { onAction(action) }
                }
            } label: {
                Text(RowViewModel.menuButtonText)
                    .foregroundStyle(Color.white.opacity(0.90))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(RowViewModel.menuButtonLabel)
            .accessibilityLabel(RowViewModel.menuButtonLabel)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.42, green: 0.50, blue: 0.59).opacity(0.88),
                            Color(red: 0.34, green: 0.42, blue: 0.51).opacity(0.88),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .help(row.tooltip)
        .overlay(alignment: .top) {
            if isDropTargeted {
                Rectangle()
                    .fill(Self.dropLine)
                    .frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        // One accessibility element; the row menu stays reachable as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityActions {
            ForEach(RowViewModel.menuActions, id: \.self) { action in
                Button(action.title) { onAction(action) }
            }
        }
        .draggable(row.dragPayload)
        .dragConfiguration(DragConfiguration(
            operationsWithinApp: .init(allowCopy: false, allowMove: true),
            operationsOutsideApp: .init(allowCopy: false, allowMove: true)))
        .dropDestination(for: String.self) { items, _ in
            onDrop(items.first)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .dropConfiguration { _ in DropConfiguration(operation: .move) }
    }

    // MARK: - Style (style.css:6-49)

    /// The GTK "1em": the system font size.
    private static let baseSize = NSFont.systemFontSize
    private static let markerBackground = Color(red: 0xf6 / 255.0, green: 0xd3 / 255.0, blue: 0x2d / 255.0)
    private static let markerText = Color(red: 0x5e / 255.0, green: 0x44 / 255.0, blue: 0x00 / 255.0)
    private static let dropLine = Color(red: 0x35 / 255.0, green: 0x84 / 255.0, blue: 0xe4 / 255.0)

    /// `.dim` sets 0.55 on the icon (style.css:36-40).
    static func iconOpacity(_ row: RowViewModel) -> Double { row.isDim ? 0.55 : 1 }
    /// The hint's 0.7 is REPLACED by `.dim`'s 0.55 (CSS opacity is one property; SwiftUI
    /// opacities multiply, so exactly one is applied).
    static func hintOpacity(_ row: RowViewModel) -> Double { row.isDim ? 0.55 : 0.7 }
    /// `.dim` 0.55, `.empty` 0.4 (style.css:36-44; the two are exclusive).
    static func temperatureOpacity(_ row: RowViewModel) -> Double {
        row.isDim ? 0.55 : (row.isEmpty ? 0.4 : 1)
    }

    /// The average character width of the system font at `fontSize` (GTK width-chars units).
    private static func charWidth(fontSize: CGFloat) -> CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" as NSString
        let width = sample.size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return width / CGFloat(sample.length)
    }

    /// gtk_label_set_ellipsize(END) + single line + width-chars / max-width-chars (make_label,
    /// wx-row.c:1120-1125).
    private struct SingleLine: ViewModifier {
        let maxChars: CGFloat
        var minChars: CGFloat = 0
        let fontSize: CGFloat

        func body(content: Content) -> some View {
            let char = ShellRow.charWidth(fontSize: fontSize)
            content
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: minChars * char, maxWidth: maxChars * char, alignment: .leading)
        }
    }
}

#if DEBUG
private enum ShellRowPreview {
    /// A place with no admin1 and no country: the region line is hidden (wx-row.c:709-710).
    static let placeWithoutRegion = try? WxPlace(name: "Null Island", lat: 0, lon: 0, timezone: "UTC")

    static func row(forecast: Bool = true, loading: Bool = false, stale: Bool = false,
                    offline: Bool = false, withRegion: Bool = true) -> some View {
        Group {
            if let place = withRegion ? DetailPreviewData.place : placeWithoutRegion {
                ShellRow(row: RowViewModel(place: place,
                                           forecast: forecast ? DetailPreviewData.forecast() : nil,
                                           loading: loading, stale: stale, offline: offline,
                                           nowS: DetailPreviewData.nowS),
                         onAction: { _ in }, onDrop: { _ in false })
            }
        }
        .frame(width: 340)
    }
}

#Preview("Forecast") { ShellRowPreview.row() }
#Preview("Updating (marker)") { ShellRowPreview.row(loading: true) }
#Preview("Stale (dim)") { ShellRowPreview.row(stale: true) }
#Preview("Offline (dim)") { ShellRowPreview.row(offline: true) }
#Preview("No forecast (empty)") { ShellRowPreview.row(forecast: false) }
#Preview("Loading, no forecast") { ShellRowPreview.row(forecast: false, loading: true) }
#Preview("No region line") { ShellRowPreview.row(withRegion: false) }
#endif
