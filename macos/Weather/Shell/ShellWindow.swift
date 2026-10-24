// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellWindow.swift - the main window's content (WxWindow, wx-window.c:1100-1160; ui-widgets.md
// §2 items 5-10, 13, 36): the page for the model state (nothing while loading, the first-run
// page with no places, the sidebar and detail otherwise), the toolbar (leading: Add; trailing,
// left to right: Refresh, °F/°C, the sources menu button with its popover) and the window's
// lifecycle reports (visible / focused to the shell; closing the window quits the app and
// closes the picker with it, wx-window.c:617-625).

import AppKit
import SwiftUI
import WeatherCore

/// The root view of the main Window scene.
struct ShellWindow: View {
    /// The main Window scene's id.
    static let windowID = "main"
    /// The window title (wx-window.c:1112).
    static let title = "Weather"
    /// The default size 1040x720 (wx-window.c:1113).
    static let defaultWidth: CGFloat = 1040
    static let defaultHeight: CGFloat = 720

    let shell: ShellState

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ShellPage(page: shell.page, model: shell.model, firstRun: shell.firstRun, sources: shell.sources)
            .background(ShellWindowObserver(
                onChange: { visible, focused in
                    shell.windowStateChanged(visible: visible, focused: focused)
                },
                onClose: {
                    // The picker is destroyed with the main window; closing the window ends the app.
                    dismissWindow(id: PickerWindow.windowID)
                    shell.requestTermination()
                }))
    }
}

/// A page of the main window with its toolbar; previews render it directly.
struct ShellPage: View {
    // Header-bar texts (wx-window.c:290-297, 1043-1075). The shortcut in a tooltip names the
    // Mac shortcut (⌘N, ⌘R) instead of Ctrl+N / F5 (platform convention, DECISIONS #13/#16).
    static let addTooltip = "Add a city (\u{2318}N)"
    static let addLabel = "Add a city"
    static let refreshTooltip = "Refresh this place (\u{2318}R)"
    static let refreshLabel = "Refresh"
    static let sourcesLabel = "Data sources and about"

    /// The units button shows the CURRENT unit (wx-window.c:290-297).
    static func unitsLabel(_ units: WxUnits) -> String { units == .metric ? "\u{00B0}C" : "\u{00B0}F" }
    /// Its tooltip and accessible label name the other unit.
    static func unitsTooltip(_ units: WxUnits) -> String {
        units == .metric ? "Switch to Fahrenheit" : "Switch to Celsius"
    }

    let page: ShellState.Page
    let model: AppModel?
    let firstRun: FirstRunViewModel?
    let sources: SourcesViewModel?

    @Environment(\.openWindow) private var openWindow
    @State private var showSources = false

    var body: some View {
        content
            .navigationTitle(ShellWindow.title)
            .preferredColorScheme(.dark)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: openPicker) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(TitlebarPillButtonStyle())
                    .help(Self.addTooltip)
                    .accessibilityLabel(Self.addLabel)
                    .disabled(model == nil)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model?.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(TitlebarPillButtonStyle())
                    .help(Self.refreshTooltip)
                    .accessibilityLabel(Self.refreshLabel)
                    .disabled(!(model?.isRefreshEnabled ?? false))

                    Button {
                        model?.toggleUnits()
                    } label: {
                        Text(Self.unitsLabel(model?.units ?? .imperial))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(TitlebarPillButtonStyle())
                    .help(Self.unitsTooltip(model?.units ?? .imperial))
                    .accessibilityLabel(Self.unitsTooltip(model?.units ?? .imperial))
                    .disabled(model == nil)

                    Button {
                        showSources.toggle()
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(TitlebarPillButtonStyle())
                    .help(Self.sourcesLabel)
                    .accessibilityLabel(Self.sourcesLabel)
                    .disabled(sources == nil)
                    .popover(isPresented: $showSources, arrowEdge: .bottom) {
                        if let sources {
                            SourcesPopover(viewModel: sources)
                        }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .loading:
            // Neutral until AppEnvironment.make has returned a loaded model (DECISIONS #58).
            Color.clear
                .frame(minWidth: ShellSidebar.sidebarMinWidth + ShellSidebar.detailMinWidth,
                       maxWidth: .infinity, maxHeight: .infinity)
        case .firstRun:
            if let firstRun {
                FirstRunView(viewModel: firstRun, onAddCity: openPicker)
                    .frame(minWidth: ShellSidebar.sidebarMinWidth + ShellSidebar.detailMinWidth)
            }
        case .places:
            if let model {
                ShellSidebar(model: model)
            }
        }
    }

    /// win.add: opens the picker, or brings the open one to the front (wx-window.c:611-625).
    private func openPicker() {
        guard model != nil else {
            return
        }
        openWindow(id: PickerWindow.windowID)
    }
}

/// High-contrast dark-slate capsule button style for titlebar toolbar items, matching
/// Apple Weather's titlebar control contrast in both Light and Dark system appearances.
private struct TitlebarPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(isEnabled ? 1.0 : 0.55))
            .frame(minWidth: 30, minHeight: 26)
            .padding(.horizontal, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color(red: 0.16, green: 0.20, blue: 0.26).opacity(0.95)
                            : Color(red: 0.23, green: 0.27, blue: 0.33).opacity(isEnabled ? 0.90 : 0.65)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.34 : 0.18), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)
    }
}

#if DEBUG
private struct ShellPagePreview: View {
    let withPlace: Bool
    @State private var model: AppModel?
    @State private var firstRun: FirstRunViewModel?
    @State private var sources: SourcesViewModel?

    var body: some View {
        NavigationStack {
            ShellPage(page: ShellState.page(model: model, firstRun: firstRun), model: model,
                      firstRun: firstRun, sources: sources)
        }
        .frame(width: ShellWindow.defaultWidth, height: ShellWindow.defaultHeight)
        .task {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "weather-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
            let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending(path: "config").path,
                                                     cacheDirectory: dir.appending(path: "cache").path)
            let model = AppModel(registry: WxRegistry(), storage: storage, online: false, log: { _, _ in })
            await model.load()
            if withPlace, let place = DetailPreviewData.place {
                _ = model.add(place)
            }
            firstRun = FirstRunViewModel(model: model)
            sources = SourcesViewModel(model: model)
            self.model = model
        }
    }
}

#Preview("Loading (no model yet)") {
    NavigationStack {
        ShellPage(page: .loading, model: nil, firstRun: nil, sources: nil)
    }
    .frame(width: ShellWindow.defaultWidth, height: ShellWindow.defaultHeight)
}

#Preview("Shell window (loading: ShellState.init starts nothing)") {
    ShellWindow(shell: ShellState())
        .frame(width: ShellWindow.defaultWidth, height: ShellWindow.defaultHeight)
}

#Preview("First run (no places)") { ShellPagePreview(withPlace: false) }
#Preview("Places") { ShellPagePreview(withPlace: true) }
#endif
