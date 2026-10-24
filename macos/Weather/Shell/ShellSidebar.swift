// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellSidebar.swift - the "main" page: the place list beside the detail pane
// (wx-window.c:928-947, 1125-1137; ui-widgets.md §2 items 5, 14, 15). Sidebar minimum 340 and
// detail minimum 480 (wx-window.c:11-12). The GTK paned's start child cannot shrink
// (wx-window.c:1135): SidebarSplitViewGuard sets the sidebar NSSplitViewItem.canCollapse = false
// and strips the hidden Toggle Sidebar (⌥⌘S) key equivalent so toggleSidebar: validates disabled
// and never collapses or bounces the sidebar, while the column visibility binding is also forced
// back to .all whenever it changes as a backstop (no toolbar toggle; SidebarCommands is not added,
// so there is no Hide Sidebar menu item).
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
    /// MIN_SIDEBAR_WIDTH (wx-window.c:11).
    static let sidebarMinWidth: CGFloat = 340
    /// MIN_DETAIL_WIDTH (wx-window.c:12).
    static let detailMinWidth: CGFloat = 480

    let model: AppModel
    private let liveStore = LiveStationStore.shared

    /// Always .all; any collapse (divider drag, toggleSidebar:) is undone at once.
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
            .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: Self.sidebarMinWidth)
            .background(SidebarSplitViewGuard())
        } detail: {
            DetailView(
                place: model.selectedPlace,
                onRename: { customName, streetAddress in
                    guard let key = model.selectedKey else { return }
                    _ = model.renamePlace(key: key, customName: customName, streetAddress: streetAddress)
                }
            )
            .frame(minWidth: Self.detailMinWidth)
        }
        .toolbar(removing: .sidebarToggle)
        .onChange(of: columns) { _, new in
            if new != .all {
                columns = .all
            }
        }
        .task(id: sidebarLiveTaskKey) {
            await liveStore.refreshAll(places: model.places)
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

    /// Prevents the enclosing NSSplitViewController from collapsing the sidebar on divider drag or
    /// toggleSidebar: (⌥⌘S), and disables the hidden Toggle Sidebar key equivalent in the main menu.
    private struct SidebarSplitViewGuard: NSViewRepresentable {
        func makeNSView(context: Context) -> GuardView {
            GuardView()
        }

        func updateNSView(_ nsView: GuardView, context: Context) {
            nsView.configureSplitView()
        }

        final class GuardView: NSView {
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
                        if sidebarItem.canCollapse {
                            sidebarItem.canCollapse = false
                        }
                        break
                    }
                    current = view.superview
                }
                if let mainMenu = NSApp?.mainMenu {
                    Self.disableToggleSidebarMenuItems(in: mainMenu)
                }
            }

            private static func disableToggleSidebarMenuItems(in menu: NSMenu) {
                for item in menu.items {
                    if item.action == #selector(NSSplitViewController.toggleSidebar(_:)) {
                        item.allowsKeyEquivalentWhenHidden = false
                        item.keyEquivalent = ""
                    }
                    if let submenu = item.submenu {
                        disableToggleSidebarMenuItems(in: submenu)
                    }
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
