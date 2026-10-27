// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SettingsView.swift - Native macOS Settings dialogue for Neginato Mezora,
// replacing the legacy hamburger popover. Configures weather data sources,
// provider and per-model blend weights, and general application preferences.

import AppKit
import SwiftUI
import WeatherCore

/// Manages a standalone NSWindow for the Settings dialogue so that toolbar
/// buttons, keyboard shortcuts, and programmatic calls always open the Settings window
/// reliably regardless of focus state.
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var windowController: NSWindowController?
    /// The window's tab, set by every request.
    private let tabSelection = SettingsTabSelection(.sources)

    private init() {}

    func showSettings(state: ShellState, initialTab: SettingsTab = .sources) {
        present(rootView: SettingsView(state: state, selection: tabSelection), tab: initialTab)
    }

    func showSettings(model: AppModel?, sources: SourcesViewModel?, initialTab: SettingsTab = .sources) {
        present(rootView: SettingsView(model: model, sources: sources, selection: tabSelection), tab: initialTab)
    }

    private func present<Content: View>(rootView: Content, tab: SettingsTab) {
        tabSelection.tab = tab
        if let wc = windowController, let window = wc.window {
            // An open (or minimised) window keeps its views, so a request only switches the tab
            // and the user's unsaved edits survive (a key being typed, Replace… mode, the Weights
            // pickers). A closed window starts again from fresh views: closing discards them.
            if !window.isVisible && !window.isMiniaturized {
                window.contentViewController = NSHostingController(rootView: rootView)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Neginato Mezora Settings"
        window.center()
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NeginatoMezoraSettingsWindow")
        window.minSize = NSSize(width: 660, height: 500)

        let wc = NSWindowController(window: window)
        self.windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case sources
    case weights
    case stations
    case general

    var id: String { rawValue }
}

/// The selected Settings tab. SettingsWindowManager owns its window's, so a request for a tab
/// can switch the open window without rebuilding its views.
@MainActor
@Observable
final class SettingsTabSelection {
    var tab: SettingsTab

    init(_ tab: SettingsTab) {
        self.tab = tab
    }
}

/// The main Settings dialogue (`⌘,` and toolbar gear button).
struct SettingsView: View {
    private let state: ShellState?
    private let explicitModel: AppModel?
    private let explicitSources: SourcesViewModel?
    @State private var selection: SettingsTabSelection

    init(state: ShellState, initialTab: SettingsTab = .sources) {
        self.init(state: state, selection: SettingsTabSelection(initialTab))
    }

    init(state: ShellState, selection: SettingsTabSelection) {
        self.state = state
        self.explicitModel = nil
        self.explicitSources = nil
        self._selection = State(initialValue: selection)
    }

    init(model: AppModel?, sources: SourcesViewModel?, selection: SettingsTabSelection) {
        self.state = nil
        self.explicitModel = model
        self.explicitSources = sources
        self._selection = State(initialValue: selection)
    }

    private var appModel: AppModel? { explicitModel ?? state?.model }
    private var sourcesVM: SourcesViewModel? { explicitSources ?? state?.sources }

    var body: some View {
        TabView(selection: $selection.tab) {
            SourcesSettingsTab(appModel: appModel, sourcesVM: sourcesVM)
                .tabItem {
                    Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(SettingsTab.sources)

            WeightsSettingsTab(appModel: appModel)
                .tabItem {
                    Label("Weights", systemImage: "slider.horizontal.3")
                }
                .tag(SettingsTab.weights)

            StationsSettingsTab(appModel: appModel)
                .tabItem {
                    Label("Stations", systemImage: "sensor")
                }
                .tag(SettingsTab.stations)

            GeneralSettingsTab(appModel: appModel)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 600)
    }
}

// MARK: - Tab 1: Sources & Provider Weights

private struct SourcesSettingsTab: View {
    let appModel: AppModel?
    let sourcesVM: SourcesViewModel?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let sourcesVM, let appModel {
                Section {
                    ForEach(sourcesVM.rows) { row in
                        SourceSettingsRow(
                            row: row,
                            weight: appModel.sourceWeight(for: row.id),
                            onToggle: { enabled in
                                sourcesVM.setEnabled(enabled, forProviderID: row.id)
                            },
                            onWeightChange: { newWeight in
                                appModel.setSourceWeight(newWeight, for: row.id)
                            },
                            onOpenURL: { url in
                                openURL(url)
                            }
                        )
                    }
                } header: {
                    HStack {
                        Text(SourcesViewModel.title)
                        Spacer()
                        if !appModel.weightMultipliers.sources.isEmpty {
                            Button("Reset Source Weights") {
                                for row in sourcesVM.rows {
                                    appModel.setSourceWeight(1.0, for: row.id)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                } footer: {
                    Text(SourcesViewModel.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            } else {
                Section {
                    ProgressView("Loading data sources…")
                }
            }

            Section("Live Station Observations") {
                Text("The forecast's \u{201C}now\u{201D} is grounded in live readings of nearby weather stations, "
                    + "which also teach each place's local forecast corrections. Station networks, their keys, "
                    + "station health and the learned corrections are in the Stations tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourceSettingsRow: View {
    let row: SourcesViewModel.Row
    let weight: Double
    let onToggle: (Bool) -> Void
    let onWeightChange: (Double) -> Void
    let onOpenURL: (URL) -> Void

    private var statusColor: Color {
        if !row.isEnabled {
            return .secondary
        }
        if row.status.hasPrefix("Used for this place") {
            return .green
        }
        if row.status.hasPrefix("Could not load") {
            return .orange
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.headline)
                    Text(row.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { row.isEnabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(row.accessibilityLabel)
            }

            // Source-level blend weight slider
            HStack(spacing: 10) {
                Text("Source weight multiplier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { weight },
                        set: { onWeightChange($0) }
                    ),
                    in: 0.10...3.00,
                    step: 0.05
                )
                .disabled(!row.isEnabled)

                Text(String(format: "%.2f×", weight))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 46, alignment: .trailing)

                Button("1.0×") {
                    onWeightChange(1.0)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(abs(weight - 1.0) < 0.01)
            }

            if row.attribution != nil || row.licence != nil {
                HStack(spacing: 12) {
                    if let attribution = row.attribution {
                        SettingsTextLineView(line: attribution, onOpenURL: onOpenURL)
                    }
                    if let licence = row.licence {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        SettingsTextLineView(line: licence, onOpenURL: onOpenURL)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsTextLineView: View {
    let line: SourcesViewModel.TextLine
    let onOpenURL: (URL) -> Void

    var body: some View {
        if let link = line.link, let url = link.url {
            HStack(spacing: 0) {
                if !line.before.isEmpty {
                    Text(line.before)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(link.text) {
                    onOpenURL(url)
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
                .underline()
                if !line.after.isEmpty {
                    Text(line.after)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(line.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tab 2: Weights & Model Matrix

private struct WeightsSettingsTab: View {
    let appModel: AppModel?
    @State private var selectedVariable: WxVar = .temp
    @State private var selectedRegion: WxRegion = .us

    private var descriptors: [WxModelWeightDescriptor] { WxWeights.modelDescriptors }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Multi-Model Ensemble Weight Configuration")
                            .font(.subheadline.weight(.semibold))
                        Text("Continuous variables are blended with a weighted median (50% cumulative weight threshold); precipitation probability uses a weighted arithmetic mean.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset All to 1.00×") {
                        appModel?.resetWeights()
                    }
                    .disabled(appModel?.weightMultipliers.isDefault ?? true)
                }
                .padding(.vertical, 2)
            }

            Section {
                Picker("Inspect Regional Profile", selection: $selectedRegion) {
                    Text("United States (HRRR + NWS + GFS)").tag(WxRegion.us)
                    Text("UK & Ireland (UKMO 2 km + ECMWF + ICON)").tag(WxRegion.ukIreland)
                    Text("Netherlands & Benelux (KNMI 2 km + DWD + UKMO)").tag(WxRegion.beneluxNorthSea)
                    Text("Germany & Central Europe (DWD ICON-D2 + MOSMIX + ECMWF)").tag(WxRegion.centralEurope)
                    Text("Canada (ECCC HRDPS + GEM + HRRR)").tag(WxRegion.canada)
                    Text("Nordic & Baltic (MET Norway + ECMWF + ICON)").tag(WxRegion.nordic)
                    Text("Rest of Europe (ARPEGE + ICON-EU + ECMWF)").tag(WxRegion.europeOther)
                    Text("Rest of World (ECMWF + ICON + GFS)").tag(WxRegion.world)
                }
                .pickerStyle(.menu)

                Picker("Inspect Baseline Variable Group", selection: $selectedVariable) {
                    Text("Temperature & Feels Like").tag(WxVar.temp)
                    Text("Wind & Gusts").tag(WxVar.wind)
                    Text("Cloud Cover").tag(WxVar.cloud)
                    Text("Relative Humidity").tag(WxVar.humidity)
                    Text("Precipitation Amount (mm/h)").tag(WxVar.precipMm)
                    Text("Precipitation Chance (%)").tag(WxVar.precipProb)
                }
                .pickerStyle(.menu)

                ForEach(descriptors) { desc in
                    ModelWeightRow(
                        descriptor: desc,
                        selectedRegion: selectedRegion,
                        selectedVariable: selectedVariable,
                        sourceMultiplier: appModel?.sourceWeight(for: desc.sourceID) ?? 1.0,
                        modelMultiplier: appModel?.modelWeight(sourceID: desc.sourceID, modelID: desc.modelID) ?? 1.0,
                        onModelWeightChange: { newValue in
                            appModel?.setModelWeight(newValue, sourceID: desc.sourceID, modelID: desc.modelID)
                        }
                    )
                }
            } header: {
                Text("Per-Model Multipliers & Baseline Horizon Weights")
            } footer: {
                Text("Horizon bands: H0 = 0–3h, H1 = 3–18h, H2 = 18–72h, H3 = 72h+. Effective weight = Regional Horizon Weight × Source Multiplier × Model Multiplier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let place = appModel?.selectedPlace?.place {
                selectedRegion = WxGeo.region(for: place, hasNWS: WxGeo.inUSNWS(place: place))
            }
        }
        .onChange(of: appModel?.selectedKey) { _, _ in
            if let place = appModel?.selectedPlace?.place {
                selectedRegion = WxGeo.region(for: place, hasNWS: WxGeo.inUSNWS(place: place))
            }
        }
    }
}

private struct ModelWeightRow: View {
    let descriptor: WxModelWeightDescriptor
    let selectedRegion: WxRegion
    let selectedVariable: WxVar
    let sourceMultiplier: Double
    let modelMultiplier: Double
    let onModelWeightChange: (Double) -> Void

    private var combinedMultiplier: Double {
        sourceMultiplier * modelMultiplier
    }

    private var regionBands: [Double] {
        let repHours: [Double] = [1.0, 6.0, 36.0, 96.0]
        return repHours.map { h in
            WxWeights.baseWeight(
                sourceID: descriptor.sourceID,
                modelID: descriptor.modelID,
                variable: selectedVariable,
                horizonH: h,
                region: selectedRegion
            )
        }
    }

    private var worldBase: Double {
        descriptor.worldWeights[selectedVariable.rawValue]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("(\(descriptor.sourceID):\(descriptor.modelID))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(descriptor.coverageSummary)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }

            Text(descriptor.resolutionSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Model multiplier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { modelMultiplier },
                        set: { onModelWeightChange($0) }
                    ),
                    in: 0.00...3.00,
                    step: 0.05
                )

                Text(String(format: "%.2f×", modelMultiplier))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 44, alignment: .trailing)

                Button("1.0×") {
                    onModelWeightChange(1.0)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(abs(modelMultiplier - 1.0) < 0.01)
            }

            // Horizon weight badges for the selected region and variable
            HStack(spacing: 6) {
                let bands = regionBands
                ForEach(0..<4, id: \.self) { band in
                    let labels = ["H0 (0–3h)", "H1 (3–18h)", "H2 (18–72h)", "H3 (72h+)"]
                    let base = bands[band]
                    let eff = base * combinedMultiplier
                    WeightBandBadge(
                        title: labels[band],
                        base: base,
                        effective: eff,
                        isScaled: abs(combinedMultiplier - 1.0) >= 0.01
                    )
                }
                if !descriptor.usOnly {
                    WeightBandBadge(
                        title: "World",
                        base: worldBase,
                        effective: worldBase * combinedMultiplier,
                        isScaled: abs(combinedMultiplier - 1.0) >= 0.01
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WeightBandBadge: View {
    let title: String
    let base: Double
    let effective: Double
    let isScaled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            if isScaled && base > 0 {
                Text(String(format: "%.2f (base %.1f)", effective, base))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tint)
            } else {
                Text(String(format: "%.1f", base))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(base > 0 ? .primary : .tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Tab 3: General

private struct GeneralSettingsTab: View {
    let appModel: AppModel?

    var body: some View {
        Form {
            // The default for places added later (settings.json "units"); saved places keep theirs.
            Section("Measurement Units") {
                Picker(
                    "Default Units for New Places",
                    selection: Binding(
                        get: { appModel?.defaultUnits ?? .imperial },
                        set: { appModel?.setDefaultUnits($0) }
                    )
                ) {
                    Text("Imperial (°F, mph, in)").tag(WxUnits.imperial)
                    Text("Metric (°C, km/h, mm)").tag(WxUnits.metric)
                }
                .pickerStyle(.radioGroup)
                .disabled(appModel == nil)
                Text("Places you have already added keep their own units: switch the selected place "
                    + "with the \u{00B0}F/\u{00B0}C toolbar button or \u{2318}U.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Documentation & About") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Neginato Mezora Documentation & Help Book")
                            .font(.subheadline.weight(.medium))
                        Text("Full guide to rain charts, data sources, ensemble weights, and meteorological citations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Help (⌘?)") {
                        HelpWindowManager.shared.showHelp()
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AboutInfo.programName)
                            .font(.subheadline.weight(.medium))
                        Text("Version \(AboutInfo.version) · Bundle ID: \(AppModel.appID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(SourcesViewModel.aboutButtonTitle) {
                        SourcesAboutPanel.show()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
