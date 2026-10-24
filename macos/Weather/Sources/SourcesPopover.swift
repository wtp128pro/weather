// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourcesPopover.swift - the "Data sources" popover (WxSources, wx-sources.h:7-27;
// ui-widgets.md §2 items 30-34). Every text, link, tooltip and accessibility label
// comes from SourcesViewModel; this view only lays them out, top to bottom:
// the title, one row per provider in registry order (switch, name, status,
// attribution, licence), the honesty note and the "About Weather" button.

import AppKit
import SwiftUI
import WeatherCore

/// The content of the sources popover. Present it with
/// `.popover(isPresented:) { SourcesPopover(viewModel: vm) }`; keep `vm` alive as long as the
/// window (it owns a registry change handler).
struct SourcesPopover: View {
    /// The view model: rows, toggles and the About request.
    let viewModel: SourcesViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SourcesViewModel.title)
                .font(.headline)
                .textCase(nil)  // "Data sources", sentence case, verbatim
                .accessibilityAddTraits(.isHeader)
            ForEach(viewModel.rows) { row in
                SourcesRowView(row: row, viewModel: viewModel)
            }
            Divider()
            Text(SourcesViewModel.note)  // wx-sources-note: not a dim-label (wx-sources.c:741-743)
                .modifier(SourcesWrap())
            Button(SourcesViewModel.aboutButtonTitle) {
                // on_about_clicked: the popover closes first, then the About panel shows.
                dismiss()
                viewModel.requestAbout()
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One provider row: the switch ("Use <name>"), then the name, status, attribution and licence.
private struct SourcesRowView: View {
    let row: SourcesViewModel.Row
    let viewModel: SourcesViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(
                row.accessibilityLabel,
                isOn: Binding(
                    get: { row.isEnabled },
                    set: { viewModel.setEnabled($0, forProviderID: row.id) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(row.accessibilityLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)  // wx-sources-name: no weight rule in style.css
                    .modifier(SourcesWrap())
                Text(row.status)
                    .foregroundStyle(.secondary)
                    .modifier(SourcesWrap())
                if let attribution = row.attribution {
                    SourcesTextLineView(line: attribution, dim: false)
                }
                if let licence = row.licence {
                    // The licence line is dim; its link keeps the link colour, like GTK's
                    // link inside a dim-label.
                    SourcesTextLineView(line: licence, dim: true)
                }
            }
        }
    }
}

/// A line of text with an optional link in it: `before`, the link, `after`, in that order.
/// The link is a `Link` control (not a link run inside a Text), so it is a keyboard focus
/// stop like the switches and the About button (wx-sources.h:81-82). A link whose URL
/// Foundation does not parse (Link.url == nil) is shown as plain text, never repaired.
private struct SourcesTextLineView: View {
    let line: SourcesViewModel.TextLine
    /// Whether the plain-text parts are dim (secondary); the link never is.
    let dim: Bool

    var body: some View {
        if let link = line.link {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 0) { parts(link) }
                VStack(alignment: .leading, spacing: 0) { parts(link) }
            }
            .modifier(SourcesWrap())
        } else {
            plain(line.text)
                .modifier(SourcesWrap())
        }
    }

    private func plain(_ text: String) -> Text {
        dim ? Text(text).foregroundStyle(.secondary) : Text(text)
    }

    @ViewBuilder
    private func parts(_ link: SourcesViewModel.Link) -> some View {
        if !line.before.isEmpty {
            plain(line.before)
        }
        if let url = link.url {
            Link(link.text, destination: url)
        } else {
            plain(link.text)
        }
        if !line.after.isEmpty {
            plain(line.after)
        }
    }
}

/// Labels wrap and are at most `SourcesViewModel.maxWidthChars` characters wide
/// (WX_SOURCES_MAX_WIDTH_CHARS), measured with the system font's average character width.
private struct SourcesWrap: ViewModifier {
    private static let maxWidth: CGFloat = {
        let sample = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" as NSString
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let average = sample.size(withAttributes: [.font: font]).width / CGFloat(sample.length)
        return (average * CGFloat(SourcesViewModel.maxWidthChars)).rounded(.up)
    }()

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
    }
}

#if DEBUG
extension SourcesPopover {
    /// Preview fixtures: one view model per status-line rule and attribution branch. A fixture
    /// that cannot be built throws (the previews use try!, so a broken fixture is visible).
    enum PreviewFixture {
        enum State: CaseIterable {
            /// "No forecast loaded yet" on every row (the production registry).
            case noForecast
            /// "Used for this place (1 forecast model)", "(3 forecast models)" and
            /// "Could not load: timed out".
            case usedAndFailed
            /// "Turned off" (MET Norway disabled) and "Not used for this place" (NWS skipped).
            case offAndNotUsed
            /// A source whose attribution URL is not acceptable: the attribution is plain text.
            case plainAttribution
            /// A source with an empty attribution: the attribution label is hidden.
            case hiddenAttribution
        }

        /// A generation time inside [WxLimits.timeMinS, timeMaxS) (2023-11-14T22:13:20Z).
        static let generatedS: Int64 = 1_700_000_000

        /// A preview data source that never fetches.
        private final class StubProvider: WxProvider {
            let id: String
            let name: String
            let attribution: String
            let attributionURL: String

            init(id: String, name: String, attribution: String, attributionURL: String) {
                self.id = id
                self.name = name
                self.attribution = attribution
                self.attributionURL = attributionURL
            }

            func covers(_ place: WxPlace) -> Bool { true }

            func fetch(_ place: WxPlace) async throws -> WxSourceResult {
                throw WxError(.notFound, "preview")
            }
        }

        static func make(_ state: State) throws -> SourcesViewModel {
            let registry: WxRegistry
            switch state {
            case .noForecast, .usedAndFailed, .offAndNotUsed:
                registry = AppEnvironment.makeRegistry(log: { _, _ in })
            case .plainAttribution:
                registry = WxRegistry()
                try registry.addProvider(StubProvider(
                    id: "preview-plain", name: "Plain attribution", attribution: "Data from a preview source",
                    attributionURL: "http://example.invalid/"))
            case .hiddenAttribution:
                registry = WxRegistry()
                try registry.addProvider(StubProvider(
                    id: "preview-hidden", name: "Hidden attribution", attribution: "",
                    attributionURL: "https://example.invalid/"))
            }
            let vm = SourcesViewModel(registry: registry, onToggle: { id, enabled in
                _ = registry.setEnabled(enabled, id: id)
            })
            let place = try WxPlace(name: "Miami", lat: 25.7743, lon: -80.1937)
            func status(_ id: String, _ state: WxSourceState, _ code: WxError.Code?, _ n: UInt32) throws
                -> WxSourceStatus
            {
                try WxSourceStatus(providerID: id, name: nil, attribution: nil, attributionURL: nil,
                                   state: state, errorCode: code, nMembers: n)
            }
            switch state {
            case .noForecast, .plainAttribution, .hiddenAttribution:
                vm.setForecast(nil)
            case .usedAndFailed:
                vm.setForecast(try WxForecast(place: place, generatedS: generatedS, sources: [
                    status("nws", .ok, nil, 1), status("open-meteo", .ok, nil, 3),
                    status("met-no", .failed, .timeout, 0),
                ]))
            case .offAndNotUsed:
                _ = registry.setEnabled(false, id: "met-no")
                vm.setForecast(try WxForecast(place: place, generatedS: generatedS, sources: [
                    status("nws", .skipped, nil, 0), status("open-meteo", .ok, nil, 2),
                ]))
            }
            return vm
        }
    }
}

#Preview("No forecast loaded yet") {
    SourcesPopover(viewModel: try! SourcesPopover.PreviewFixture.make(.noForecast))
}

#Preview("Used and could not load") {
    SourcesPopover(viewModel: try! SourcesPopover.PreviewFixture.make(.usedAndFailed))
}

#Preview("Turned off and not used") {
    SourcesPopover(viewModel: try! SourcesPopover.PreviewFixture.make(.offAndNotUsed))
}

#Preview("Attribution as plain text") {
    SourcesPopover(viewModel: try! SourcesPopover.PreviewFixture.make(.plainAttribution))
}

#Preview("Attribution hidden") {
    SourcesPopover(viewModel: try! SourcesPopover.PreviewFixture.make(.hiddenAttribution))
}
#endif
