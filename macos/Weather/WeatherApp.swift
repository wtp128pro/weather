// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// WeatherApp.swift - entry point of the macOS app (main.c, wx-app.c:1897-1955): ONE main Window
// scene (not a WindowGroup, so a second activation presents the same window and there is no
// New Window or tab, wx-app.c:1950-1955), the "Add a city" picker window (U33) and the menu
// commands. The process lifecycle (load, network, signals, quit flush) lives in
// Shell/ShellAppDelegate.swift and Shell/ShellState.swift. The app target's default actor
// isolation is MainActor.

import SwiftUI
import WeatherCore

@main
struct WeatherApp: App {
    @NSApplicationDelegateAdaptor(ShellAppDelegate.self) private var delegate

    var body: some Scene {
        Window(ShellWindow.title, id: ShellWindow.windowID) {
            ShellWindow(shell: delegate.shell)
        }
        .defaultSize(width: ShellWindow.defaultWidth, height: ShellWindow.defaultHeight)
        .defaultLaunchBehavior(.presented)
        .commands {
            ShellCommands(shell: delegate.shell)
            HelpCommands()
        }

        PickerScene(model: delegate.shell.model)

        Settings {
            SettingsView(state: delegate.shell)
        }
    }
}
