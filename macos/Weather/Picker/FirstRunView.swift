// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FirstRunView.swift - the first-run ("empty") page (wx-window.c:978-1015;
// ui-widgets.md §2 item 13): the title, the hint, the five suggestion chips and the
// "Add a city" button. Texts and tooltips come from FirstRunViewModel. The main window
// shows this page while FirstRunViewModel.isShown and the main page otherwise.

import AppKit
import SwiftUI
import WeatherCore

/// The first-run page.
struct FirstRunView: View {
    /// The page's view model (its chips; adding a chip adds and selects the place).
    let viewModel: FirstRunViewModel
    /// The "Add a city" button: the add command (it opens the picker).
    let onAddCity: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(FirstRunViewModel.title)
                .font(.system(size: NSFont.systemFontSize * 1.6, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(FirstRunViewModel.hint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            FirstRunChipFlow(spacing: 8) {
                ForEach(Array(viewModel.chips.enumerated()), id: \.element.id) { index, chip in
                    Button(chip.title) {
                        // A refused add shows nothing (wx-window.c:646-654).
                        viewModel.addSuggestion(at: index)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .help(chip.tooltip)
                }
            }
            Button(FirstRunViewModel.addCityTitle, action: onAddCity)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A centred flow of chips (GtkFlowBox): as many per line as fit, lines centred.
private struct FirstRunChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty {
            lines.append(line)
        }
        return lines
    }
}

#if DEBUG
/// Preview fixture: an app model with no places on a throw-away directory.
private struct FirstRunViewPreview: View {
    @State private var page: FirstRunViewModel?

    var body: some View {
        Group {
            if let page {
                FirstRunView(viewModel: page, onAddCity: {})
            } else {
                Color.clear
            }
        }
        .frame(width: 640, height: 480)
        .task {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "weather-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
            let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending(path: "config").path,
                                                     cacheDirectory: dir.appending(path: "cache").path)
            let model = AppModel(registry: WxRegistry(), storage: storage, online: false, log: { _, _ in })
            await model.load()
            page = FirstRunViewModel(model: model)
        }
    }
}

#Preview("No places yet") { FirstRunViewPreview() }
#endif
