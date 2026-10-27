// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationsSettingsTab.swift - Settings > Stations: the learned local corrections
// (per place, by hour of the day, with reset), the station networks (on/off, the
// keys of the networks that need one, the outcome of their latest fetch), and
// the stations near the selected place with their tested health.

import SwiftUI
import WeatherCore

struct StationsSettingsTab: View {
    let appModel: AppModel?
    private let store = LiveStationStore.shared

    var body: some View {
        Form {
            if let appModel {
                LocalCorrectionsSection(appModel: appModel)
                NetworksSection(appModel: appModel, store: store, keyed: true)
                NetworksSection(appModel: appModel, store: store, keyed: false)
                NearbyStationsSection(appModel: appModel, store: store)
            } else {
                Section {
                    ProgressView("Loading stations…")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Texts

/// The texts of the Stations tab (the Help Book quotes them).
enum StationsSettingsText {
    /// The units the tab formats with: the selected place's own units (the °F/°C the toolbar
    /// shows), else the default units for new places when there is no place.
    static func units(of appModel: AppModel) -> WxUnits {
        appModel.selectedPlace?.units ?? appModel.defaultUnits
    }

    /// "5 min ago", "just now", "2 h ago".
    static func ago(_ ageS: Int64) -> String {
        let text = WxFormat.updated(ageS: max(0, ageS))
        return text.hasPrefix("Updated ") ? String(text.dropFirst("Updated ".count)) : text
    }

    /// A temperature difference in the display unit: "+1.2 °F", "−0.5 °C".
    static func delta(_ c: Double, units: WxUnits) -> String {
        let v = units == .metric ? c : c * 1.8
        let unit = units == .metric ? "°C" : "°F"
        if abs(v) < 0.05 {
            return "0.0 \(unit)"
        }
        return (v > 0 ? "+" : "\u{2212}") + String(format: "%.1f", abs(v)) + " " + unit
    }

    /// "expires 25 Jan 2027", "expires in 5 days", "expired on 3 Oct 2026".
    static func expiry(_ expiryS: Int64, nowS: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        let date = f.string(from: Date(timeIntervalSince1970: TimeInterval(expiryS)))
        let left = expiryS - nowS
        if left <= 0 {
            return "· expired on \(date): get a new one"
        }
        if left < 14 * 86_400 {
            let days = max(1, left / 86_400)
            return "· expires in \(days) day\(days == 1 ? "" : "s") (\(date))"
        }
        return "· expires \(date)"
    }

    /// A temperature difference's size in the display unit: "1.2 °F".
    static func amount(_ c: Double, units: WxUnits) -> String {
        let v = abs(units == .metric ? c : c * 1.8)
        return String(format: "%.1f", v) + (units == .metric ? " °C" : " °F")
    }

    static func correctionStatus(_ c: AppModel.LocalCorrection, nowS: Int64) -> String {
        guard c.samples > 0, let last = c.lastUpdateS else {
            return "Nothing learned yet: this needs station readings within about 25 km that are less "
                + "than 45 minutes old."
        }
        var text = "\(c.hoursLearned) of 24 hours learned from \(c.samples) reading\(c.samples == 1 ? "" : "s"), "
            + "last \(ago(nowS - last))"
        if c.strength < 0.995 {
            let days = max(0, nowS - last) / 86_400
            text += " · fading: no new readings for \(days) days"
        }
        return text
    }

    static func networkStatus(
        _ network: WxStationNetwork, status: StationNetworkStatus?, hasKey: Bool, enabled: Bool, nowS: Int64
    ) -> String {
        if !enabled {
            return "Turned off: not fetched and not used."
        }
        if network.requiresKey && !hasKey {
            let label = network.keyInfo?.keyLabel ?? "key"
            return "Needs your free \(label). Used for places in \(network.coverageText)."
        }
        guard let status else {
            return network.requiresKey
                ? "Key saved. It is tried on the next refresh of a place in \(network.coverageText)."
                : "Used for places in \(network.coverageText); not needed by your places yet."
        }
        let when = ago(nowS - status.atS)
        let place = status.placeName.isEmpty ? "" : " near \(status.placeName)"
        switch status.outcome {
        case .ok(let reports):
            return reports == 0
                ? "Working, but no stations within 95 km\(place) (\(when))."
                : "Working: \(reports) report\(reports == 1 ? "" : "s") within 95 km\(place) (\(when))."
        case .keyRejected(let code):
            return "The service refused the key (HTTP \(code), \(when)). Check that it was copied completely, "
                + "or create a new one."
        case .rateLimited:
            return "The service's limit for this key was reached (\(when)); the app tries again on the next refresh."
        case .failed(let code):
            return "The service answered with an error (HTTP \(code), \(when)); its last readings are used for "
                + "up to 90 minutes."
        case .unreachable:
            return "Could not reach the service (\(when)); its last readings are used for up to 90 minutes."
        }
    }

    static func healthText(_ a: WxStationCatalog.Assessment, tests: Int, units: WxUnits) -> String {
        switch a.state {
        case .good:
            return "Good"
        case .probation:
            return "On probation (\(min(tests, WxStationCatalog.probationTests)) of \(WxStationCatalog.probationTests) tests)"
        case .reduced:
            return "Reduced weight (off by \(amount(a.errorC ?? 0, units: units)))"
        case .excluded:
            return "Not used: off by \(amount(a.errorC ?? 0, units: units))"
        case .stuck:
            return "Not used: reading stuck"
        case .unknown:
            return "Not tested"
        }
    }
}

// MARK: - Learned local corrections

private struct LocalCorrectionsSection: View {
    let appModel: AppModel
    @State private var confirmResetAll = false

    var body: some View {
        let corrections = appModel.localCorrections
        let enabled = appModel.stationSettings.localCorrectionsEnabled
        let units = StationsSettingsText.units(of: appModel)
        Section {
            Toggle(isOn: Binding(
                get: { appModel.stationSettings.localCorrectionsEnabled },
                set: { appModel.setLocalCorrectionsEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Correct forecasts with what nearby stations measure")
                    Text("For each place and hour of the day, the app learns how far the models run from close, "
                        + "fresh station readings, and shifts the forecast temperatures (and feels-like, highs and "
                        + "lows) by up to ±\(StationsSettingsText.amount(WxLocalBias.maxCorrectionC, units: units)). "
                        + "Learning continues while this is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if corrections.isEmpty {
                Text("Add a place to start learning.")
                    .foregroundStyle(.secondary)
            }
            ForEach(corrections) { c in
                LocalCorrectionRow(
                    correction: c, units: units, applied: enabled, nowS: appModel.displayNowS,
                    onReset: { appModel.resetLocalCorrections(key: c.key) })
            }
        } header: {
            HStack {
                Text("Learned Local Corrections")
                Spacer()
                Button("Help") { HelpWindowManager.shared.showHelp(page: "local-corrections.html") }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Reset All…") { confirmResetAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(!corrections.contains { $0.samples > 0 })
            }
        } footer: {
            Text("Bars: the correction at each local hour of today (up: the forecast is raised; down: lowered). "
                + "An hour needs \(WxLocalBias.minSamples) readings, from different days, before it is corrected; "
                + "it is fully corrected from \(WxLocalBias.fullConfidenceSamples). The learning stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Forget the learned corrections of every place?", isPresented: $confirmResetAll, titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) { appModel.resetAllLocalCorrections() }
        } message: {
            Text("The forecasts go back to the plain model blend, and learning starts again from zero.")
        }
    }
}

private struct LocalCorrectionRow: View {
    let correction: AppModel.LocalCorrection
    let units: WxUnits
    let applied: Bool
    let nowS: Int64
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(correction.place.label)
                        .font(.headline)
                    Text(StationsSettingsText.correctionStatus(correction, nowS: nowS))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(StationsSettingsText.delta(correction.nowC, units: units))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(applied ? .primary : .secondary)
                }
                Button("Reset", action: onReset)
                    .controlSize(.small)
                    .disabled(correction.samples == 0)
                    .accessibilityLabel("Reset the learned corrections of \(correction.place.label)")
            }
            if correction.samples > 0 {
                HourlyCorrectionBars(hours: correction.hours, units: units, nowS: nowS,
                                     timeZone: correction.place.timezone, dimmed: !applied)
            }
        }
        .padding(.vertical, 3)
    }
}

/// 24 bars, one per local hour of today: the correction up (warmer) or down (colder) from a
/// middle line; a dot for an hour with readings but not enough to correct it yet.
private struct HourlyCorrectionBars: View {
    let hours: [AppModel.LocalCorrection.Hour]
    let units: WxUnits
    let nowS: Int64
    /// The place's zone (WxPlace.timezone), whose clock hour of nowS is the bar marked now.
    let timeZone: String
    let dimmed: Bool

    private static let halfHeight: CGFloat = 16

    /// The local clock hour of `nowS` in `timeZone`, as AppModel.localCorrections reads the zone.
    static func localHour(_ nowS: Int64, timeZone: String) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(nowS)))
    }

    var body: some View {
        let scale = max(1.0, hours.map { abs($0.correctionC) }.max() ?? 1.0)
        let nowHour = Self.localHour(nowS, timeZone: timeZone)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(hours, id: \.hour) { h in
                    bar(h, scale: scale, nowHour: nowHour)
                }
            }
            .frame(height: Self.halfHeight * 2)
            .background(alignment: .center) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 0.5)
            }
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(String(format: "%02d:00", h))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func bar(_ h: AppModel.LocalCorrection.Hour, scale: Double, nowHour: Int) -> some View {
        // By the place's clock hour, not ±30 min around tS: those windows left the hour a
        // fall-back day repeats unmarked. A skipped hour (tS 0) is never now.
        let isNow = h.tS != 0 && h.hour == nowHour
        let height = CGFloat(abs(h.correctionC) / scale) * Self.halfHeight
        return ZStack {
            if abs(h.correctionC) >= 0.05 {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(h.correctionC > 0 ? Color.orange : Color.blue)
                    .frame(height: max(2, height))
                    .offset(y: h.correctionC > 0 ? -max(2, height) / 2 : max(2, height) / 2)
            } else if h.samples > 0 {
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isNow ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 2))
        .help(String(format: "%02d:00", h.hour) + ": " + StationsSettingsText.delta(h.correctionC, units: units)
            + " (\(h.samples) reading\(h.samples == 1 ? "" : "s"))")
    }

    private var accessibilitySummary: String {
        guard let largest = hours.max(by: { abs($0.correctionC) < abs($1.correctionC) }),
              abs(largest.correctionC) >= 0.05
        else {
            return "No hour corrected yet"
        }
        let corrected = hours.filter { abs($0.correctionC) >= 0.05 }.count
        return "\(corrected) hours corrected; largest \(StationsSettingsText.delta(largest.correctionC, units: units)) "
            + "at " + String(format: "%02d:00", largest.hour)
    }
}

// MARK: - Networks

private struct NetworksSection: View {
    let appModel: AppModel
    let store: LiveStationStore
    let keyed: Bool

    var body: some View {
        let networks = WxStationNetwork.allCases.filter { $0.requiresKey == keyed }
        Section {
            ForEach(networks, id: \.self) { network in
                NetworkRow(network: network, appModel: appModel, store: store)
            }
        } header: {
            HStack {
                Text(keyed ? "Networks That Need Your Free Key" : "Networks Used Without a Key")
                Spacer()
                Button("Help") {
                    HelpWindowManager.shared.showHelp(page: keyed ? "station-keys.html" : "live-stations.html")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } footer: {
            Text(keyed
                ? "Each key is stored in your login Keychain and sent only to its own service, over HTTPS. "
                    + "Stations of these networks are used like all others: tested against their neighbours "
                    + "and blended."
                : "Every network covering a place is fetched at each refresh; a network that cannot be reached "
                    + "contributes its readings of the last 90 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NetworkRow: View {
    let network: WxStationNetwork
    let appModel: AppModel
    let store: LiveStationStore
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var replacing = false
    @State private var saveFailed = false

    var body: some View {
        let enabled = appModel.stationSettings.isEnabled(network)
        let hasKey = store.networksWithKeys.contains(network)
        let status = store.networkStatus[network]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(color(status: status, enabled: enabled, hasKey: hasKey))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(network.displayName).font(.headline)
                        Text(network.coverageText).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(StationsSettingsText.networkStatus(
                        network, status: status, hasKey: hasKey, enabled: enabled, nowS: appModel.displayNowS))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appModel.stationSettings.isEnabled(network) },
                    set: {
                        appModel.setStationNetworkEnabled(network, $0)
                        store.configurationChanged()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Use \(network.displayName)")
            }
            Text(network.detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if network.requiresKey, let info = network.keyInfo {
                keyEditor(info: info, hasKey: hasKey)
                DisclosureGroup("How to get a free \(info.keyLabel)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(info.steps.enumerated()), id: \.offset) { i, step in
                            Text("\(i + 1). \(step)")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(info.limits)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = URL(string: info.signUpURL) {
                            Button("Open \(info.serviceName)") { openURL(url) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }
                .font(.caption)
            }
            let credit = WxStationNetworks.credit(network)
            if let url = URL(string: credit.url) {
                Button(credit.text) { openURL(url) }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func keyEditor(info: WxStationKeyInfo, hasKey: Bool) -> some View {
        if hasKey && !replacing {
            HStack(spacing: 8) {
                Label("\(info.keyLabel.prefix(1).uppercased() + info.keyLabel.dropFirst()) saved in your Keychain",
                      systemImage: "key.fill")
                    .font(.caption)
                if let expiry = store.keyExpiries[network] {
                    let left = expiry - appModel.displayNowS
                    Text(StationsSettingsText.expiry(expiry, nowS: appModel.displayNowS))
                        .font(.caption)
                        .foregroundStyle(left <= 0 ? Color.red : (left < 14 * 86_400 ? Color.orange : Color.secondary))
                }
                Spacer()
                Button("Replace…") { replacing = true; draft = ""; saveFailed = false }
                    .controlSize(.small)
                Button("Remove") { store.setKey(nil, for: network) }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                SecureField(info.keyLabel, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit(save)
                Button("Save", action: save)
                    .controlSize(.small)
                    .disabled(StationKeys.normalized(draft) == nil)
                if replacing {
                    Button("Cancel") { replacing = false; draft = ""; saveFailed = false }
                        .controlSize(.small)
                }
            }
            if saveFailed {
                Text("The Keychain did not accept the key. Try again, or check Keychain Access.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        guard StationKeys.normalized(draft) != nil else { return }
        saveFailed = !store.setKey(draft, for: network)
        if !saveFailed {
            draft = ""
            replacing = false
        }
    }

    private func color(status: StationNetworkStatus?, enabled: Bool, hasKey: Bool) -> Color {
        guard enabled, !network.requiresKey || hasKey, let status else { return .secondary }
        switch status.outcome {
        case .ok: return .green
        case .keyRejected: return .red
        case .rateLimited, .failed, .unreachable: return .orange
        }
    }
}

// MARK: - Stations near the selected place

private struct NearbyStationsSection: View {
    let appModel: AppModel
    let store: LiveStationStore
    @State private var confirmForget = false
    @State private var showAll = false

    private static let shortList = 12

    var body: some View {
        let place = appModel.selectedPlace?.place
        let stations = place.map { store.nearbyStations(lat: $0.lat, lon: $0.lon) } ?? []
        let units = StationsSettingsText.units(of: appModel)
        Section {
            if place == nil {
                Text("Select a place to see its stations.")
                    .foregroundStyle(.secondary)
            } else if stations.isEmpty {
                Text("No stations known within 60 km yet. They appear after the place's first refresh.")
                    .foregroundStyle(.secondary)
            }
            ForEach(showAll ? stations : Array(stations.prefix(Self.shortList))) { s in
                StationRow(station: s, units: units, nowS: appModel.displayNowS)
            }
            if stations.count > Self.shortList {
                Button(showAll ? "Show Fewer" : "Show All \(stations.count) Stations") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } header: {
            HStack {
                Text(place.map { "Stations Near \($0.name)" } ?? "Stations Near the Selected Place")
                Spacer()
                Button("Forget All Stations…") { confirmForget = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } footer: {
            Text("Each station is tested at every refresh against what its neighbours predict for it. Its weight in "
                + "the blend follows its record: full while it stays within 1.5 °C (2.7 °F), less beyond that, none "
                + "from 8 °C (14 °F) or when its reading has not changed for 8 hours. New and returning stations start "
                + "on probation; a station silent for 3 days of app use is dropped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Forget every station and its track record?", isPresented: $confirmForget, titleVisibility: .visible
        ) {
            Button("Forget All Stations", role: .destructive) { store.forgetAllStations() }
        } message: {
            Text("The stations are found again at the next refresh, and start over on probation. Learned local "
                + "corrections are kept.")
        }
    }
}

private struct StationRow: View {
    let station: WxStationCatalog.Nearby
    let units: WxUnits
    let nowS: Int64

    var body: some View {
        let r = station.record
        let a = station.assessment
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color(a.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name.map { "\($0) (\(r.id))" } ?? r.id)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(r.network.displayName) · \(LiveStationSnapshot.formatDistance(km: station.distanceKm, units: units))"
                    + " · report \(StationsSettingsText.ago(nowS - r.lastReportS))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f%%", a.health * 100))
                    .font(.callout.monospacedDigit())
                Text(StationsSettingsText.healthText(a, tests: r.tests, units: units))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ state: WxStationCatalog.HealthState) -> Color {
        switch state {
        case .good: .green
        case .probation: .blue
        case .reduced: .yellow
        case .excluded, .stuck: .red
        case .unknown: .secondary
        }
    }
}
