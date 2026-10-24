// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ShellCommands.swift - the menu bar (wx-app.c:1884-1891; ui-widgets.md §2 items 11-12) on the
// standard Mac menus (DECISIONS #16): File > "Add a City…" ⌘N replaces New Window / New Item;
// View > Refresh ⌘R (enabled from AppModel.isRefreshEnabled) and the unit switch ⌘U; the app
// menu's About shows the About panel (SourcesAboutPanel); Quit ⌘Q, Edit and Window stay standard.
// F5 is not bound (DECISIONS #13).

import SwiftUI
import WeatherCore

/// The app's menu commands.
struct ShellCommands: Commands {
    /// The File menu's add item (Mac title case; the ellipsis because it opens a window).
    static let addTitle = "Add a City\u{2026}"
    static let aboutTitle = "About Weather"

    let shell: ShellState

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(Self.aboutTitle) {
                SourcesAboutPanel.show()
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(Self.addTitle) {
                openWindow(id: PickerWindow.windowID)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(shell.model == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(ShellPage.refreshLabel) {
                shell.model?.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(shell.model?.isRefreshEnabled ?? false))

            Button(ShellPage.unitsTooltip(shell.model?.units ?? .imperial)) {
                shell.model?.toggleUnits()
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(shell.model == nil)

            Divider()
        }
    }
}
