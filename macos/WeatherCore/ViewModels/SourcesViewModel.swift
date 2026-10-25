// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// SourcesViewModel.swift - presentation logic of the "Data sources" popover.
// Port of WxSources (src/ui/wx-sources.h:4-96, src/ui/wx-sources.c), minus the
// GTK widget mechanics:
//  - one Row per registered provider, in WxRegistry.listProviders() order;
//  - the switch shows the registry's enabled flag and never changes the
//    registry itself: a user toggle is handed to the owner (`onToggle`, the
//    "provider-toggled" signal) and the row then shows whatever the registry
//    says (a refused toggle snaps back);
//  - the five status rules, the attribution link (strict https, bounded),
//    the licence lines and the honesty note, verbatim from the C strings;
//  - the accessible switch label "Use <provider name>".
// Rows are recomputed from the registry and the forecast data on every read,
// so SwiftUI observation follows registry changes, forecast changes and (in
// the AppModel-backed form) the selected place.

import Foundation
import Observation

@MainActor
@Observable
public final class SourcesViewModel {
    // MARK: - Fixed texts (verbatim C strings)

    /// The popover title (wx-sources.c:735).
    public nonisolated static let title = "Data sources"

    /// The honesty note, verbatim (NOTE_TEXT, wx-sources.c:24-26).
    public nonisolated static let note =
        "Forecasts blend several sources with fixed, documented weights. These weights are rules "
        + "of thumb, not statistics measured from past accuracy, so no accuracy figure is claimed."

    /// The label of the About button (wx-sources.c:745).
    public nonisolated static let aboutButtonTitle = "About Neginato Mezora"

    /// The width bound of every wrapping label, in characters
    /// (WX_SOURCES_MAX_WIDTH_CHARS, wx-sources.h:109).
    public nonisolated static let maxWidthChars = 40

    // MARK: - Row model

    /// A link inside a text line: `text` is shown, `urlString` is the target,
    /// verbatim.
    public struct Link: Sendable, Equatable {
        public let text: String
        /// The target exactly as the provider (or the licence table) gave it.
        public let urlString: String
        /// `urlString` as a URL for SwiftUI's Link / openURL; nil only if
        /// Foundation cannot represent it (the view then shows plain text).
        public var url: URL? { URL(string: urlString) }
    }

    /// A display line: `before`, then the optional link, then `after`.
    public struct TextLine: Sendable, Equatable {
        public let before: String
        public let link: Link?
        public let after: String

        /// The text as it reads on screen (gtk_label_get_text()).
        public var text: String { before + (link?.text ?? "") + after }
    }

    /// One provider row of the popover.
    public struct Row: Sendable, Equatable, Identifiable {
        /// The provider id (the row identity).
        public let id: String
        /// The display name: the sanitised provider name, or the id when
        /// nothing is left of it.
        public let name: String
        /// The switch position: the registry's enabled flag.
        public let isEnabled: Bool
        /// The status line (rules in `statusText`).
        public let status: String
        /// The attribution line, a link when the URL is acceptable; nil when
        /// nothing is left of the attribution text (the label is hidden).
        public let attribution: TextLine?
        /// The licence line, nil for an id outside the licence table.
        public let licence: TextLine?
        /// The accessibility label of the switch: "Use <name>".
        public let accessibilityLabel: String
    }

    /// The copied part of a forecast source (Entry, wx-sources.c:58-63).
    struct Entry: Sendable, Equatable {
        let id: String
        let state: WxSourceState
        /// The C error code ordinal; -1 for none.
        let errorCode: Int
        let nMembers: UInt32
    }

    // MARK: - State

    @ObservationIgnored private let registry: WxRegistry
    @ObservationIgnored private let onToggle: @MainActor (String, Bool) -> Void
    @ObservationIgnored private let onAbout: (@MainActor () -> Void)?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let followsModel: Bool
    @ObservationIgnored private var changeHandler: WxRegistry.ChangeHandlerID?

    /// Bumped on every registry change and after every user toggle, so a view
    /// reading `rows` re-renders (a refused toggle visibly snaps back).
    private var revision: UInt64 = 0
    /// The forecast data of setForecast(_:); nil = no forecast.
    private var entries: [Entry]?

    /// A view model over `registry`. `onToggle(id, enabled)` receives every user
    /// toggle (the "provider-toggled" signal); applying it to the registry is the
    /// owner's choice. `onAbout` receives requestAbout() ("about-requested").
    public init(
        registry: WxRegistry, onToggle: @escaping @MainActor (String, Bool) -> Void,
        onAbout: (@MainActor () -> Void)? = nil
    ) {
        self.registry = registry
        self.onToggle = onToggle
        self.onAbout = onAbout
        self.followsModel = false
        subscribe()
    }

    /// A view model over the app model: toggles go to
    /// AppModel.setProviderEnabled(_:_:) (wx-window.c's "provider-toggled"
    /// handler) and the status lines follow the selected place's forecast.
    public init(model: AppModel, onAbout: (@MainActor () -> Void)? = nil) {
        self.registry = model.registry
        self.onToggle = { [weak model] id, enabled in model?.setProviderEnabled(id, enabled) }
        self.onAbout = onAbout
        self.model = model
        self.followsModel = true
        subscribe()
    }

    isolated deinit {
        if let changeHandler {
            registry.removeChangeHandler(changeHandler)
        }
    }

    private func subscribe() {
        changeHandler = registry.addChangeHandler { [weak self] in
            self?.revision &+= 1
        }
    }

    // MARK: - Reading

    /// The rows, one per registered provider in registration order.
    public var rows: [Row] {
        _ = revision
        let current = followsModel ? model?.selectedPlace?.forecast.map(Self.entries(of:)) : entries
        return registry.listProviders().map { provider in
            let id = provider.id
            let enabled = registry.isEnabled(id: id)
            return Self.makeRow(
                id: id, nameBytes: Array(provider.name.utf8),
                attributionBytes: Array(provider.attribution.utf8),
                attributionURLBytes: Array(provider.attributionURL.utf8), enabled: enabled,
                status: Self.statusText(enabled: enabled, entries: current, id: id))
        }
    }

    // MARK: - Actions

    /// wx_sources_set_forecast (wx-sources.c:771-789): the status lines follow
    /// `forecast` (nil: "No forecast loaded yet"); its sources are copied, no
    /// reference is kept. The AppModel-backed form follows the selection
    /// instead and ignores this call.
    public func setForecast(_ forecast: WxForecast?) {
        entries = forecast.map(Self.entries(of:))
    }

    /// A USER toggle of the switch of `id` to `enabled` (on_switch_state_set,
    /// wx-sources.c:427-444). When `enabled` differs from the switch position,
    /// `onToggle` runs once; the switch then shows the registry's flag. A
    /// request equal to the position, or for an id without a row, is not a
    /// toggle and does nothing.
    public func setEnabled(_ enabled: Bool, forProviderID id: String) {
        guard registry.findProvider(id: id) != nil, registry.isEnabled(id: id) != enabled else {
            return
        }
        onToggle(id, enabled)
        revision &+= 1
    }

    /// The About button (on_about_clicked, wx-sources.c:461-467): runs `onAbout`
    /// once. Dismissing the popover first is the view's job.
    public func requestAbout() {
        onAbout?()
    }

    // MARK: - Rules

    static func entries(of forecast: WxForecast) -> [Entry] {
        forecast.sources.map {
            Entry(id: $0.providerID, state: $0.state, errorCode: $0.errorCodeOrdinal, nMembers: $0.nMembers)
        }
    }

    /// The status line (status_text, wx-sources.c:297-315; rules in
    /// wx-sources.h:37-50); `entries` nil means no forecast.
    static func statusText(enabled: Bool, entries: [Entry]?, id: String) -> String {
        if !enabled {
            return "Turned off"
        }
        guard let entries else {
            return "No forecast loaded yet"
        }
        if let e = entries.first(where: { $0.id == id }) {
            switch e.state {
            case .ok:
                return "Used for this place (\(e.nMembers) forecast \(e.nMembers == 1 ? "model" : "models"))"
            case .failed:
                return "Could not load: " + errorReason(code: e.errorCode)
            case .skipped:
                break
            }
        }
        return "Not used for this place"
    }

    /// The reason after "Could not load: " (error_reason, wx-sources.c:256-278);
    /// `code` is a WxError.Code ordinal, -1 or anything else ("unknown error").
    public nonisolated static func errorReason(code: Int) -> String {
        switch WxError.Code(rawValue: code) {
        case .network: "network error"
        case .timeout: "timed out"
        case .http: "server error"
        case .rateLimited: "rate limited"
        case .parse: "unreadable answer"
        case .notFound: "no data"
        case .invalidArg: "invalid request"
        case .unsupported: "not available"
        case nil: "unknown error"
        }
    }

    /// url_is_acceptable (wx-sources.c:148-166): "https://" plus at least one
    /// byte, at most WxLimits.sourceURLMax bytes (read as a C string), valid
    /// UTF-8 without a forbidden wx-text character, no g_unichar_isspace()
    /// character and none of '<', '>' and '"'. At most sourceURLMax + 1 bytes
    /// are examined before a longer URL is rejected.
    public nonisolated static func isAcceptableURL(bytes: [UInt8]) -> Bool {
        let scan = bytes.prefix(WxLimits.sourceURLMax + 1)
        let len = scan.firstIndex(of: 0) ?? scan.count
        let prefix = Array("https://".utf8)
        guard len > prefix.count, len <= WxLimits.sourceURLMax, bytes.starts(with: prefix) else {
            return false
        }
        let url = bytes[..<len]
        let clean = WxText.sanitize(bytes: url, maxBytes: WxLimits.sourceURLMax)
        guard clean.utf8.elementsEqual(url) else {
            return false  // invalid UTF-8 or a forbidden character
        }
        for c in clean.unicodeScalars {
            if c == "<" || c == ">" || c == "\"" || isGLibSpace(c) {
                return false
            }
        }
        return true
    }

    /// g_unichar_isspace(): '\t', '\n', '\r', '\f' and the Unicode space,
    /// line and paragraph separators (Zs, Zl, Zp).
    private nonisolated static func isGLibSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0C, 0x0D:
            return true
        default:
            switch c.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// The licence line of a provider id (the table at wx-sources.c:41-47), nil
    /// for every other id.
    public nonisolated static func licence(forProviderID id: String) -> TextLine? {
        switch id {
        case "open-meteo":
            TextLine(
                before: "Open-Meteo data is licensed ",
                link: Link(text: "CC BY 4.0", urlString: "https://creativecommons.org/licenses/by/4.0/"),
                after: "")
        case "met-no":
            TextLine(
                before: "MET Norway data: ",
                link: Link(text: "CC BY 4.0 / NLOD", urlString: "https://api.met.no/doc/License"), after: "")
        case "nws":
            TextLine(
                before: "NOAA/National Weather Service data is US government work, credited as a courtesy",
                link: nil, after: "")
        case "dwd-brightsky":
            TextLine(
                before: "Deutscher Wetterdienst (DWD) OpenData is licensed ",
                link: Link(text: "CC BY 4.0", urlString: "https://www.dwd.de/EN/service/copyright/copyright_node.html"),
                after: "")
        case "eccc":
            TextLine(
                before: "Environment and Climate Change Canada data: ",
                link: Link(
                    text: "Data Server End-use Licence",
                    urlString: "https://eccc-msc.github.io/open-data/licence/readme_en/"),
                after: "")
        default:
            nil
        }
    }

    /// The row of one provider (add_row + set_attribution + set_licence,
    /// wx-sources.c:186-238, 515-560). The texts are read as C strings; nil is
    /// treated like "" (wx-sources.h:22-23).
    static func makeRow(
        id: String, nameBytes: [UInt8]?, attributionBytes: [UInt8]?, attributionURLBytes: [UInt8]?,
        enabled: Bool, status: String
    ) -> Row {
        var name = WxText.sanitize(bytes: nameBytes ?? [], maxBytes: WxLimits.sourceTextMax)
        if name.isEmpty {
            name = id
        }
        let text = WxText.sanitize(bytes: attributionBytes ?? [], maxBytes: WxLimits.sourceTextMax)
        var attribution: TextLine? = nil
        if !text.isEmpty {
            if let url = attributionURLBytes, isAcceptableURL(bytes: url) {
                let end = url.firstIndex(of: 0) ?? url.endIndex
                let target = String(decoding: url[..<end], as: UTF8.self)
                attribution = TextLine(before: "", link: Link(text: text, urlString: target), after: "")
            } else {
                attribution = TextLine(before: text, link: nil, after: "")
            }
        }
        return Row(
            id: id, name: name, isEnabled: enabled, status: status, attribution: attribution,
            licence: licence(forProviderID: id), accessibilityLabel: "Use " + name)
    }
}
