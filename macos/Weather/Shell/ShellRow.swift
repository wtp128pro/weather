// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellRow.swift - one sidebar row (WxRow, wx-row.c:1105-1180, style.css:6-49; ui-widgets.md §2
// items 16-18): the 32 pt condition icon, the bold name with the alert indicator after it (a
// warning triangle coloured by the highest current alert level, with the count when there is more
// than one, on a dark plate; not in the GTK row), the region and the hint (0.85em, opacity 0.7),
// the temperature (1.6em, weight 300, tabular digits) and its unit suffix ("77°" "F", "—" "°F":
// the place's own units) with the marker pill below, and the flat "…" menu (Move up,
// Move down, Remove; always enabled, no confirmation). The row
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
    /// Optional callback to update the place's custom name ("Home", "Work", "Friend's place", etc.)
    /// and/or street address.
    var onRename: ((String?, String?) -> Void)? = nil

    @State private var isDropTargeted = false
    @State private var showRenameSheet = false

    private var customSymbol: String? {
        Self.symbolForPlace(row.place)
    }

    /// The badge of a name's meaning, matched by whole words ("Mom's house", "Apt 4B"), first
    /// match wins. A substring test badged places that merely contain a keyword: Munich and
    /// Union Station as schools, Homestead as a home, Miami-Dade as family.
    private static let badgeWords: [(symbol: String, words: Set<String>)] = [
        ("house.fill", ["home", "homes", "homeoffice", "house", "houses", "apt", "apartment", "apartments"]),
        ("briefcase.fill", ["work", "workplace", "office", "offices", "coworking"]),
        ("person.2.fill", ["friend", "friends", "family", "mom", "moms", "mommy", "dad", "dads", "daddy",
                           "granddad"]),
        ("graduationcap.fill", ["school", "schools", "preschool", "highschool", "college", "uni", "university"]),
        ("dumbbell.fill", ["gym", "gyms", "fitness"]),
    ]

    static func symbolForPlace(_ place: WxPlace) -> String? {
        let lower = (!place.customName.isEmpty ? place.customName : (place.isCustomLocation ? place.name : "")).lowercased()
        if !lower.isEmpty {
            let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
            if let badge = badgeWords.first(where: { !$0.words.isDisjoint(with: words) }) {
                return badge.symbol
            }
            if !place.customName.isEmpty {
                return "tag.fill"
            }
        }
        if place.isCustomLocation || !place.streetAddress.isEmpty {
            return "mappin.and.ellipse"
        }
        return nil
    }

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
                HStack(spacing: 5) {
                    if let customSymbol {
                        Image(systemName: customSymbol)
                            .font(.system(size: Self.baseSize * 0.82, weight: .semibold))
                            .foregroundStyle(Color(red: 0.45, green: 0.84, blue: 1.00))
                    }
                    Text(row.name)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let indicator = row.alertIndicator {
                        AlertIndicatorView(indicator: indicator, size: Self.baseSize * 0.9)
                    }
                }
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
                // The temperature in the place's own units and its suffix: "77°" "F" read as one
                // "77°F" (no gap), "—" "°F" keep a gap (unitSuffix is then the unit label).
                HStack(alignment: .firstTextBaseline, spacing: row.unitSuffix == row.unitLabel ? 2 : 0) {
                    Text(row.temperature)
                        .font(.system(size: Self.baseSize * 1.65, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .frame(minWidth: Self.charWidth(fontSize: Self.baseSize * 1.65) * 4, alignment: .trailing)
                    Text(row.unitSuffix)
                        .font(.system(size: Self.baseSize * 0.85, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .lineLimit(1)
                        .fixedSize()
                }
                .opacity(Self.temperatureOpacity(row))
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
                if let onRename {
                    Button("Name / Edit Location\u{2026}") {
                        showRenameSheet = true
                    }
                    Menu("Set Location Name") {
                        ForEach(WxAddressGeocoder.presetLocationNames, id: \.label) { preset in
                            Button(preset.label) {
                                onRename(preset.label, nil)
                            }
                        }
                        if !row.place.customName.isEmpty {
                            Divider()
                            Button("Clear Custom Name") {
                                onRename("", nil)
                            }
                        }
                    }
                    Divider()
                }
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
        .sheet(isPresented: $showRenameSheet) {
            LocationNameEditorSheet(
                place: row.place,
                onSave: { customName, streetAddress in
                    onRename?(customName, streetAddress)
                }
            )
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

/// The colour of an alert level (WxAlert.Level): the red / orange / yellow of the issuers' warning
/// scales; minor (no colour from its issuer) and unknown are neutral. Always drawn with the
/// warning symbol and a text, never as colour alone, and on `plate`.
enum AlertLevelStyle {
    /// The opaque dark slate the level colour is drawn on (the row's indicator, the card's level
    /// badge): every level reads at 4.7:1 or more on it (WCAG relative luminance; red 4.72,
    /// orange 7.79, yellow 11.42, minor 10.78, unknown 10.71), where on the row's or the card's
    /// slate red alone fell to 1.3-1.7:1.
    static let plate = Color(red: 0.11, green: 0.13, blue: 0.17)

    static func color(_ level: WxAlert.Level) -> Color {
        switch level {
        case .red: Color(red: 1.00, green: 0.27, blue: 0.23)
        case .orange: Color(red: 1.00, green: 0.62, blue: 0.04)
        case .yellow: Color(red: 1.00, green: 0.84, blue: 0.04)
        case .minor: Color(red: 0.62, green: 0.86, blue: 1.00)
        case .unknown: Color.white.opacity(0.80)
        }
    }
}

/// A row's alert indicator (RowViewModel.alertIndicator): the warning triangle in the level's
/// colour, then the count when there is more than one, on AlertLevelStyle.plate. The plate is a
/// background drawn 3 pt beyond the indicator's frame (2 pt above and below), so it takes no
/// layout: the name line keeps its height and the name its room. The row's accessibility label
/// names the alerts, so the indicator itself is hidden from VoiceOver.
private struct AlertIndicatorView: View {
    let indicator: RowViewModel.AlertIndicator
    let size: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: RowViewModel.AlertIndicator.symbolName)
                .font(.system(size: size, weight: .semibold))
            if let count = indicator.countText {
                Text(count)
                    .font(.system(size: size, weight: .bold).monospacedDigit())
            }
        }
        .foregroundStyle(AlertLevelStyle.color(indicator.level))
        .background {
            Capsule()
                .fill(AlertLevelStyle.plate)
                .padding(.horizontal, -3)
                .padding(.vertical, -2)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// Modal sheet for setting or editing a saved location's custom name (e.g. "Home", "Work",
/// "Friend's place") and street address description.
struct LocationNameEditorSheet: View {
    let place: WxPlace
    let onSave: (String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customName: String = ""
    @State private var streetAddress: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Name & Address Details")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Location Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. Home, Work, Friend's place", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAndClose() }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(WxAddressGeocoder.presetLocationNames, id: \.label) { preset in
                            let selected = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                                .caseInsensitiveCompare(preset.label) == .orderedSame
                            Button {
                                customName = selected ? "" : preset.label
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: preset.symbol)
                                        .font(.caption2)
                                    Text(preset.label)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                                )
                                .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Street Address / Locality Subtitle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Street address or city, region", text: $streetAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAndClose() }
                Text(String(format: "Coordinates: %.4f\u{00B0}, %.4f\u{00B0}", place.lat, place.lon))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if !place.customName.isEmpty || !customName.isEmpty {
                    Button("Clear Name") {
                        onSave("", streetAddress.isEmpty ? nil : streetAddress)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    saveAndClose()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 400)
        .onAppear {
            customName = place.customName
            if !place.streetAddress.isEmpty {
                streetAddress = place.streetAddress
            } else if !place.admin1.isEmpty {
                streetAddress = !place.customName.isEmpty ? place.admin1 : "\(place.name), \(place.admin1)"
            } else {
                streetAddress = place.name
            }
        }
    }

    private func saveAndClose() {
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddr = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmedName, trimmedAddr.isEmpty ? nil : trimmedAddr)
        dismiss()
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
