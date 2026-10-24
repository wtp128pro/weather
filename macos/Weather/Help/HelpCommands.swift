// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// HelpCommands.swift - Replaces the default macOS Help menu item with Neginato Mezora's
// bundled HTML Help Book viewer.

import SwiftUI

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Neginato Mezora Help") {
                HelpWindowManager.shared.showHelp()
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button("Rain Graph & Bars Guide") {
                HelpWindowManager.shared.showHelp(page: "rain-chart.html")
            }

            Button("Data Sources & Blend Weights") {
                HelpWindowManager.shared.showHelp(page: "sources-weights.html")
            }

            Button("Forecast Algorithms & Citations") {
                HelpWindowManager.shared.showHelp(page: "algorithms.html")
            }

            Button("Live Station 3D Assimilation") {
                HelpWindowManager.shared.showHelp(page: "live-stations.html")
            }
        }
    }
}
