// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellSidebar.swift - the "main" page: the place list beside the detail pane
// (wx-window.c:928-947, 1125-1137; ui-widgets.md §2 items 5, 14, 15). Sidebar ideal width 340
// (resizable down to 220 or collapsible via the toolbar button, menu command, or divider drag)
// and detail minimum 480 (wx-window.c:11-12).
// Single selection that cannot be emptied (GtkSingleSelection, wx-window.c:928-930): the List
// uses the non-optional selection binding, so the table keeps a highlighted row, and only a
// saved place's key is passed to AppModel.select (nil or an unknown key would empty the
// selection, test-window.c:2351-2356); AppModel itself selects the first row / a neighbour
// (autoselect, wx-window.c:929-930, 1150).

import AppKit
import SwiftUI
import WeatherCore

/// The sidebar of saved places and the detail pane of the selected one.
struct ShellSidebar: View {
    /// Minimum width before collapsing when dragging the split-view divider.
    static let sidebarCollapseMinWidth: CGFloat = 220
    /// MIN_SIDEBAR_WIDTH / ideal width (wx-window.c:11).
    static let sidebarMinWidth: CGFloat = 340
    /// Maximum width when dragging the split-view divider wider.
    static let sidebarMaxWidth: CGFloat = 480
    /// MIN_DETAIL_WIDTH (wx-window.c:12).
    static let detailMinWidth: CGFloat = 480

    let model: AppModel
    private let liveStore = LiveStationStore.shared

    /// Column visibility state for showing or hiding the places sidebar.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: selection) {
                // Recomputed from model.places on every change; never cached (U28).
                ForEach(liveRows) { row in
                    ShellRow(
                        row: row,
                        onAction: { action in _ = row.perform(action, in: model) },
                        onDrop: { text in row.acceptDrop(text, in: model) },
                        onRename: { customName, streetAddress in
                            _ = model.renamePlace(key: row.key, customName: customName, streetAddress: streetAddress)
                        }
                    )
                    .tag(row.key)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.34, green: 0.38, blue: 0.43),
                        Color(red: 0.26, green: 0.30, blue: 0.35),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .environment(\.colorScheme, .dark)
            .accessibilityLabel(RowViewModel.listAccessibilityLabel)
            .navigationSplitViewColumnWidth(
                min: Self.sidebarCollapseMinWidth,
                ideal: Self.sidebarMinWidth,
                max: Self.sidebarMaxWidth
            )
        } detail: {
            DetailView(
                place: model.selectedPlace,
                onRename: { customName, streetAddress in
                    guard let key = model.selectedKey else { return }
                    _ = model.renamePlace(key: key, customName: customName, streetAddress: streetAddress)
                }
            )
            .frame(minWidth: Self.detailMinWidth)
            .background(SidebarSplitViewConfigurator())
        }
        .task(id: sidebarLiveTaskKey) {
            await liveStore.refreshAll(model: model)
        }
    }

    private var liveRows: [RowViewModel] {
        model.places.map { place in
            let base = RowViewModel(place)
            guard let snap = liveStore.snapshot(for: place) else { return base }
            return snap.apply(to: base, units: place.units, nowS: place.nowS)
        }
    }

    private var sidebarLiveTaskKey: [String] {
        model.places.map { "\($0.key):\($0.fetchedS):\($0.offline):\($0.units)" }
    }

    /// Ensures the enclosing NSSplitViewController allows collapsing the sidebar via both the
    /// divider slider and the toolbar/menu toggle button even when the sidebar is collapsed and no
    /// longer in the responder chain.
    private struct SidebarSplitViewConfigurator: NSViewRepresentable {
        func makeNSView(context: Context) -> ConfiguratorView {
            ConfiguratorView()
        }

        func updateNSView(_ nsView: ConfiguratorView, context: Context) {
            nsView.configureSplitView()
        }

        final class ConfiguratorView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                configureSplitView()
            }

            override func layout() {
                super.layout()
                configureSplitView()
            }

            func configureSplitView() {
                var current: NSView? = self
                while let view = current {
                    if let splitView = view as? NSSplitView,
                       let controller = splitView.delegate as? NSSplitViewController,
                       let sidebarItem = controller.splitViewItems.first
                    {
                        if !sidebarItem.canCollapse {
                            sidebarItem.canCollapse = true
                        }
                        if let items = window?.toolbar?.items {
                            for item in items where item.itemIdentifier == .toggleSidebar
                                || item.action == #selector(NSSplitViewController.toggleSidebar(_:))
                            {
                                if item.target !== controller {
                                    item.target = controller
                                }
                            }
                        }
                        break
                    }
                    current = view.superview
                }
            }
        }
    }

    /// The list's selection: reads AppModel.selectedKey; forwards only a saved place's key (never
    /// nil, never an unknown key). The binding is non-optional, so the table cannot be left without
    /// a highlighted row while AppModel keeps its selection (SwiftUI List(selection: Binding<T>)).
    private var selection: Binding<String> {
        Binding(get: { model.selectedKey ?? "" },
                set: { key in
                    if model.place(forKey: key) != nil {
                        model.select(key)
                    }
                })
    }
}

#if DEBUG
private struct ShellSidebarPreview: View {
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                ShellSidebar(model: model)
            } else {
                Color.clear
            }
        }
        .frame(width: 1040, height: 720)
        .task {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "weather-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
            let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending(path: "config").path,
                                                     cacheDirectory: dir.appending(path: "cache").path)
            let model = AppModel(registry: WxRegistry(), storage: storage, online: false, log: { _, _ in })
            await model.load()
            for name in ["Miami", "Orlando"] {
                if let place = try? WxPlace(name: name, admin1: "Florida", country: "United States",
                                            countryCode: "US", lat: name == "Miami" ? 25.7743 : 28.5383,
                                            lon: name == "Miami" ? -80.1937 : -81.3792, timezone: "America/New_York") {
                    _ = model.add(place)
                }
            }
            self.model = model
        }
    }
}

#Preview("Places (offline, no forecast)") { ShellSidebarPreview() }
#endif
