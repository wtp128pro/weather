// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PickerView.swift - the content of the "Add a city" window (WxPicker,
// wx-picker.h:8-31; ui-widgets.md §2 items 20-25): from top to bottom the search
// field, the status line and the results list. Every text, tooltip and accessibility
// label comes from PickerViewModel; keys go to its entry points.

import AppKit
import SwiftUI
import WeatherCore

/// The picker's content. `PickerWindow` hosts it with a fresh view model per presentation.
struct PickerView: View {
    /// The view model of this presentation.
    let viewModel: PickerViewModel
    /// Optional application model for street-address geocoding and custom-named locations.
    var model: AppModel? = nil
    /// Optional window dismissal callback when a custom/address location is added.
    var onDismiss: (() -> Void)? = nil

    private enum Focus: Hashable {
        case search
        case locationName
        case results
    }

    @FocusState private var focus: Focus?
    /// The keyboard cursor of the list (GtkListBox's focus row). It is not a selection the
    /// picker reports: only Return, Space or a double click add a row.
    @State private var cursor: Int?
    /// What the search field shows.
    @State private var draft = ""
    /// Optional custom name for the location (e.g. "Home", "Work", "Friend's place").
    @State private var locationName = ""
    /// Street-address & multi-provider geocoding results for the current query.
    @State private var addressCandidates: [WxAddressCandidate] = []
    /// Whether an address search is currently in flight.
    @State private var isSearchingAddresses = false
    /// Custom status or error message when adding/searching addresses.
    @State private var addressErrorText: String? = nil
    /// Debounced search task for street addresses.
    @State private var addressSearchTask: Task<Void, Never>? = nil
    /// The search field's place in AppKit, to show a cut edit at once (see `edit`).
    @State private var fieldAnchor = FieldAnchor()

    /// The keypad's Enter key (U+0003), which AppKit reports apart from Return.
    private static let keypadEnter = KeyEquivalent("\u{3}")

    private var trimmedQuery: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLocationName: String {
        locationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingAddressResults: Bool {
        trimmedQuery.utf8.count >= PickerViewModel.minQueryBytes && (!addressCandidates.isEmpty || isSearchingAddresses)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Address / City / Coordinate Search Field
            VStack(alignment: .leading, spacing: 4) {
                Text("Address, Landmark, or City")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        "Street address, ZIP/postal code, coordinates, or city\u{2026}",
                        text: Binding(get: { draft }, set: { edit($0) })
                    )
                    .textFieldStyle(.plain)
                    .background(FieldAnchorView(anchor: fieldAnchor))
                    .accessibilityLabel(PickerViewModel.searchAccessibilityLabel)
                    .focused($focus, equals: .search)
                    .onSubmit {
                        viewModel.submit()
                        triggerAddressSearch(immediate: true)
                    }
                    if !draft.isEmpty {
                        Button {
                            edit("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                )
            }

            // 2. Custom Location Name Field + Quick Preset Chips ("Home", "Work", "Friend's place", etc.)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Location Name (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !trimmedLocationName.isEmpty {
                        Button("Clear") {
                            locationName = ""
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                TextField(
                    "e.g. Home, Work, Friend's place, Mom's house\u{2026}",
                    text: $locationName
                )
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .locationName)
                .onSubmit {
                    if let cursor {
                        activateDisplayedRow(at: cursor)
                    } else if !displayedRows.isEmpty {
                        activateDisplayedRow(at: 0)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(WxAddressGeocoder.presetLocationNames, id: \.label) { preset in
                            let isSelected = trimmedLocationName.caseInsensitiveCompare(preset.label) == .orderedSame
                            Button {
                                if isSelected {
                                    locationName = ""
                                } else {
                                    locationName = preset.label
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: preset.symbol)
                                        .font(.caption2)
                                    Text(preset.label)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.14))
                                )
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 3. Status line
            if let addressErrorText {
                Text(addressErrorText)
                    .foregroundStyle(Color.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isSearchingAddresses && addressCandidates.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching addresses and weather locations\u{2026}")
                        .foregroundStyle(Color.secondary)
                }
            } else if isShowingAddressResults {
                Text("Matching addresses & locations (\(displayedRows.count))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.secondary)
            } else if viewModel.isStatusVisible {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.statusStyle == .error ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            // 4. Results list (Address candidates or PickerViewModel rows)
            List(selection: $cursor) {
                ForEach(displayedRows) { item in
                    PickerCandidateRowView(
                        item: item,
                        customLocationName: trimmedLocationName,
                        onAdd: { activateDisplayedRow(at: item.id) }
                    )
                    .tag(item.id)
                }
            }
            .focused($focus, equals: .results)
            .onKeyPress(keys: [.return, .space, Self.keypadEnter], phases: .down) { press in
                guard let cursor else {
                    return .ignored
                }
                let mods = Keys.modifiers(press.modifiers)
                let nonCaps = mods.subtracting(.capsLock)
                guard nonCaps.isEmpty else {
                    return .handled
                }
                activateDisplayedRow(at: cursor)
                return .handled
            }
            .contextMenu(forSelectionType: Int.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                // A double click on a row.
                if let id = ids.first {
                    activateDisplayedRow(at: id)
                }
            })
            .onChange(of: displayedRows.count) {
                if let cursor, cursor >= displayedRows.count {
                    self.cursor = nil
                }
            }
        }
        .padding(12)
        .defaultFocus($focus, .search)
        .onAppear {
            draft = viewModel.text
            focus = .search
        }
        .onDisappear {
            addressSearchTask?.cancel()
            addressSearchTask = nil
        }
        .onChange(of: viewModel.text) {
            Task { @MainActor in
                // Sync from viewModel only when draft is within the 64-byte city limit or was cleared.
                if viewModel.text.isEmpty && !draft.isEmpty {
                    draft = ""
                }
            }
        }
    }

    // MARK: - Displayed Rows & Activation

    fileprivate struct DisplayedRow: Identifiable {
        let id: Int
        let place: WxPlace
        let title: String
        let subtitle: String
        let isStreetAddress: Bool
        let isAdded: Bool
        let tooltip: String
    }

    private var displayedRows: [DisplayedRow] {
        if !addressCandidates.isEmpty {
            return addressCandidates.enumerated().map { idx, cand in
                let saved = isCandidateAlreadySaved(cand.place)
                return DisplayedRow(
                    id: idx,
                    place: cand.place,
                    title: cand.primaryTitle,
                    subtitle: cand.subtitle,
                    isStreetAddress: cand.kind != .city,
                    isAdded: saved,
                    tooltip: cand.fullAddress.isEmpty ? cand.place.label : cand.fullAddress
                )
            }
        }
        return viewModel.rows.map { row in
            let subParts = [row.place.admin1, row.place.country].filter { !$0.isEmpty }
            return DisplayedRow(
                id: row.id,
                place: row.place,
                title: row.place.name,
                subtitle: subParts.joined(separator: ", "),
                isStreetAddress: row.place.isCustomLocation || !row.place.streetAddress.isEmpty,
                isAdded: isCandidateAlreadySaved(row.place, defaultIsAdded: row.isAdded),
                tooltip: row.tooltip
            )
        }
    }

    private func isCandidateAlreadySaved(_ place: WxPlace, defaultIsAdded: Bool = false) -> Bool {
        guard let model else { return defaultIsAdded }
        if !trimmedLocationName.isEmpty {
            return model.places.contains {
                WxGeo.distanceKm(aLat: $0.place.lat, aLon: $0.place.lon, bLat: place.lat, bLon: place.lon) < 0.05
                    && $0.place.name.caseInsensitiveCompare(trimmedLocationName) == .orderedSame
            }
        }
        if place.isCustomLocation || !place.streetAddress.isEmpty {
            return model.places.contains {
                WxGeo.distanceKm(aLat: $0.place.lat, aLon: $0.place.lon, bLat: place.lat, bLon: place.lon) < 0.05
                    && $0.place.name.caseInsensitiveCompare(place.name) == .orderedSame
            }
        }
        return defaultIsAdded || model.isSaved(key: place.key)
    }

    private func activateDisplayedRow(at index: Int) {
        let rows = displayedRows
        guard index >= 0, index < rows.count else { return }
        let row = rows[index]
        addressErrorText = nil

        guard let model else {
            viewModel.activateRow(at: index)
            return
        }

        let customName = trimmedLocationName.isEmpty ? nil : trimmedLocationName
        let streetAddr: String? = {
            if !row.place.streetAddress.isEmpty {
                return row.place.streetAddress
            }
            if row.isStreetAddress {
                return row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)"
            }
            if customName != nil {
                return row.subtitle.isEmpty ? row.title : "\(row.title), \(row.subtitle)"
            }
            return nil
        }()

        let result: AppModel.AddResult
        if customName != nil || streetAddr != nil || row.place.isCustomLocation {
            result = model.addCustomLocation(
                row.place,
                customName: customName,
                streetAddress: streetAddr
            )
        } else {
            result = model.add(row.place)
        }

        switch result {
        case .added:
            onDismiss?()
        case .duplicate:
            addressErrorText = "This location is already in your list (tip: give it a distinct Location Name like \"Home\" or \"Work\")"
        case .full:
            addressErrorText = "You can save at most 50 places"
        case .failed:
            addressErrorText = "Could not add this location"
        }
    }

    /// Updates both `PickerViewModel` (for standard city suggestions/fallback) and schedules
    /// the full street-address geocoder search.
    private func edit(_ newText: String) {
        draft = newText
        addressErrorText = nil
        // Pass a 64-byte-safe prefix to PickerViewModel so long street addresses aren't truncated in `draft`.
        let vmText = String(newText.prefix(PickerViewModel.maxQueryChars))
        viewModel.textChanged(to: vmText)
        triggerAddressSearch(immediate: false)
    }

    private func triggerAddressSearch(immediate: Bool) {
        addressSearchTask?.cancel()
        let query = trimmedQuery
        guard query.utf8.count >= PickerViewModel.minQueryBytes else {
            addressCandidates = []
            isSearchingAddresses = false
            return
        }
        isSearchingAddresses = true
        addressSearchTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 280_000_000)
                if Task.isCancelled { return }
            }
            let candidates = await WxAddressGeocoder.search(query: query)
            if Task.isCancelled { return }
            self.addressCandidates = candidates
            self.isSearchingAddresses = false
        }
    }
}

extension PickerView {
    /// A weak handle on a view next to the search field, to reach the field's editor.
    @MainActor
    final class FieldAnchor {
        weak var view: NSView?
        private var observers: [NSObjectProtocol] = []

        /// Undo and Redo in a text field change its text without posting the text-did-change
        /// notification, so neither the field's own value nor SwiftUI's binding (nor the view
        /// model) hears of them. After each Undo or Redo in the search field the editor posts it
        /// (didChangeText, which registers nothing for undo), so the change reaches the view
        /// model through the binding like any edit, as GTK's "changed" signal does.
        init() {
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] note in
                    let manager = (note.object as AnyObject?).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        self?.replayed(manager)
                    }
                })
            }
        }

        isolated deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// The search field's editor while the user edits it (then the window's first responder).
        private var editor: NSTextView? {
            guard let editor = view?.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField,
                  field.placeholderString == PickerViewModel.searchPlaceholder
            else {
                return nil
            }
            return editor
        }

        private func replayed(_ manager: ObjectIdentifier?) {
            guard let editor, let undo = editor.undoManager, ObjectIdentifier(undo) == manager,
                  !editor.hasMarkedText()
            else {
                return
            }
            editor.didChangeText()
        }

        /// Writes `text` into the search field's editor while the user edits it. The caret stays
        /// after the kept part of the edit. The write is not an undoable edit, so the actions the
        /// editor recorded no longer match its text (Undo would raise NSRangeException): they are
        /// dropped, and the field's undo history starts again after a cut edit.
        func show(_ text: String) {
            guard let editor, !editor.string.utf8.elementsEqual(text.utf8) else {
                return
            }
            let removed = (editor.string as NSString).length - (text as NSString).length
            let caret = max(0, min(editor.selectedRange().location - max(removed, 0), (text as NSString).length))
            editor.string = text
            editor.setSelectedRange(NSRange(location: caret, length: 0))
            editor.undoManager?.removeAllActions()
        }
    }

    /// Hands its NSView to a FieldAnchor.
    struct FieldAnchorView: NSViewRepresentable {
        let anchor: FieldAnchor

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            anchor.view = nsView
        }
    }
}

/// One result row: displays a street address, landmark, coordinate, or city with an optional
/// custom location label badge ("Home", "Work", "Friend's place", etc.), subtitle, and an "Add"
/// button or "Added" indicator.
private struct PickerCandidateRowView: View {
    let item: PickerView.DisplayedRow
    let customLocationName: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isStreetAddress ? "mappin.and.ellipse" : "building.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.isStreetAddress ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !customLocationName.isEmpty {
                        Text(customLocationName)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(item.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .help(item.tooltip)

            Spacer(minLength: 8)

            if item.isAdded {
                Text(PickerViewModel.addedText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.tooltip)
        .accessibilityValue(item.isAdded ? PickerViewModel.addedText : "")
    }
}

extension PickerView {
    /// Key mapping between AppKit/SwiftUI events and PickerViewModel's keys.
    enum Keys {
        /// The view model's modifiers for SwiftUI's.
        static func modifiers(_ flags: EventModifiers) -> PickerViewModel.Modifiers {
            var result: PickerViewModel.Modifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.capsLock) { result.insert(.capsLock) }
            return result
        }

        /// The view model's modifiers for AppKit's.
        nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> PickerViewModel.Modifiers {
            var result: PickerViewModel.Modifiers = []
            if flags.contains(.shift) { result.insert(.shift) }
            if flags.contains(.control) { result.insert(.control) }
            if flags.contains(.option) { result.insert(.option) }
            if flags.contains(.command) { result.insert(.command) }
            if flags.contains(.capsLock) { result.insert(.capsLock) }
            return result
        }

        /// The view model's key for the virtual key code of an AppKit key-down event.
        nonisolated static func key(keyCode: UInt16) -> PickerViewModel.Key {
            switch keyCode {
            case 53: return .escape                // kVK_Escape
            case 36, 76: return .enter             // kVK_Return, kVK_ANSI_KeypadEnter
            case 49: return .space                 // kVK_Space
            default: return .other
            }
        }
    }
}

#if DEBUG
/// Preview fixtures: an app model on a throw-away directory, with a geocoder that answers
/// each preview's way, driven through the view model's own entry points.
private enum PickerViewPreview {
    enum State {
        case suggestions, tooShort, searching, results, noResults, failed, refused
    }

    private final class Geocoder: WxGeocoder {
        let state: State
        /// Never yields: iterating it waits until the search is cancelled.
        private let pending = AsyncStream<Void>.makeStream()
        init(_ state: State) { self.state = state }

        func search(textBytes: [UInt8]) async throws -> [WxPlace] {
            switch state {
            case .searching:
                // Never answers while the preview is shown; a cancelled search ends here.
                for await _ in pending.stream {}
                throw CancellationError()
            case .noResults:
                return []
            case .failed:
                throw WxError(.network, "The network is unreachable")
            default:
                return PickerViewModel.suggestedPlaces()
            }
        }
    }

    static func model(_ state: State) -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "weather-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending(path: "config").path,
                                                 cacheDirectory: dir.appending(path: "cache").path)
        let registry = WxRegistry()
        registry.geocoder = Geocoder(state)
        return AppModel(registry: registry, storage: storage, online: true, log: { _, _ in })
    }

    /// Brings `vm` into `state` (after the model is loaded).
    static func drive(_ vm: PickerViewModel, _ model: AppModel, _ state: State) {
        switch state {
        case .suggestions:
            break
        case .tooShort:
            vm.textChanged(to: "M")
        case .searching, .results, .noResults, .failed:
            if state == .results, let first = PickerViewModel.suggestedPlaces().first {
                _ = model.add(first)
            }
            vm.textChanged(to: "Miami")
            vm.submit()
        case .refused:
            if let first = PickerViewModel.suggestedPlaces().first {
                _ = model.add(first)
            }
            vm.activateRow(at: 0)
        }
    }

    struct Host: View {
        let state: State
        @State private var vm: PickerViewModel?

        var body: some View {
            Group {
                if let vm {
                    PickerView(viewModel: vm)
                } else {
                    Color.clear
                }
            }
            .frame(width: CGFloat(PickerViewModel.defaultWidth), height: CGFloat(PickerViewModel.defaultHeight))
            .task {
                let model = PickerViewPreview.model(state)
                await model.load()
                let vm = PickerViewModel(model: model)
                PickerViewPreview.drive(vm, model, state)
                self.vm = vm
            }
        }
    }
}

#Preview("Suggestions") { PickerViewPreview.Host(state: .suggestions) }
#Preview("Type at least 2 letters") { PickerViewPreview.Host(state: .tooShort) }
#Preview("Searching") { PickerViewPreview.Host(state: .searching) }
#Preview("Results with Added") { PickerViewPreview.Host(state: .results) }
#Preview("No results") { PickerViewPreview.Host(state: .noResults) }
#Preview("Search failed") { PickerViewPreview.Host(state: .failed) }
#Preview("Add refused") { PickerViewPreview.Host(state: .refused) }
#endif
