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

            Button("Reading the Forecast") {
                HelpWindowManager.shared.showHelp(page: "forecast-page.html")
            }

            Button("Rain Graph & Bars Guide") {
                HelpWindowManager.shared.showHelp(page: "rain-chart.html")
            }

            Divider()

            Button("Data Sources & Blend Weights") {
                HelpWindowManager.shared.showHelp(page: "sources-weights.html")
            }

            Button("Station Settings") {
                HelpWindowManager.shared.showHelp(page: "stations-settings.html")
            }

            Button("Free Keys for More Stations") {
                HelpWindowManager.shared.showHelp(page: "station-keys.html")
            }

            Divider()

            Button("Live Station Observations") {
                HelpWindowManager.shared.showHelp(page: "live-stations.html")
            }

            Button("Learned Local Corrections") {
                HelpWindowManager.shared.showHelp(page: "local-corrections.html")
            }

            Button("Forecast Algorithms & Citations") {
                HelpWindowManager.shared.showHelp(page: "algorithms.html")
            }

            Divider()

            Button("Troubleshooting & FAQ") {
                HelpWindowManager.shared.showHelp(page: "troubleshooting.html")
            }
        }
    }
}
