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

    private enum Focus: Hashable {
        case search
        case results
    }

    @FocusState private var focus: Focus?
    /// The keyboard cursor of the list (GtkListBox's focus row). It is not a selection the
    /// picker reports: only Return, Space or a double click add a row.
    @State private var cursor: Int?
    /// What the field shows: always viewModel.text once an edit is applied, so an insertion
    /// the view model cuts (64 characters / 64 bytes) is cut on screen too, as in GTK.
    @State private var draft = ""
    /// The search field's place in AppKit, to show a cut edit at once (see `edit`).
    @State private var fieldAnchor = FieldAnchor()

    /// The keypad's Enter key (U+0003), which AppKit reports apart from Return.
    private static let keypadEnter = KeyEquivalent("\u{3}")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                PickerViewModel.searchPlaceholder,
                text: Binding(get: { draft }, set: { edit($0) }))
                .textFieldStyle(.roundedBorder)
                .background(FieldAnchorView(anchor: fieldAnchor))
                .accessibilityLabel(PickerViewModel.searchAccessibilityLabel)
                .focused($focus, equals: .search)
                .onSubmit { viewModel.submit() }
            if viewModel.isStatusVisible {
                Text(viewModel.statusText)
                    .foregroundStyle(viewModel.statusStyle == .error ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            List(selection: $cursor) {
                ForEach(viewModel.rows) { row in
                    PickerRowView(row: row)
                        .tag(row.id)
                }
            }
            .focused($focus, equals: .results)
            .onKeyPress(keys: [.return, .space, Self.keypadEnter], phases: .down) { press in
                guard let cursor else {
                    return .ignored
                }
                let key: PickerViewModel.Key = press.key == .space ? .space : .enter
                // handleRowKey is the only key path that adds: it adds for a key without a
                // modifier. Return, keypad Enter and Space with one are consumed too, so the
                // List's own Return action (the primaryAction below) never adds on them.
                viewModel.handleRowKey(key, modifiers: Keys.modifiers(press.modifiers), at: cursor)
                return .handled
            }
            .contextMenu(forSelectionType: Int.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                // A double click on a row.
                if let id = ids.first {
                    viewModel.activateRow(at: id)
                }
            })
            .onChange(of: viewModel.rows.count) {
                if let cursor, cursor >= viewModel.rows.count {
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
        .onChange(of: viewModel.text) {
            // A change of the view model's text (an edit it cut, or setText elsewhere). Applied
            // on the next turn: an update made while the field is still delivering the edit is
            // dropped by the field.
            Task { @MainActor in
                if draft != viewModel.text {
                    draft = viewModel.text
                }
            }
        }
    }

    /// A field edit: the view model applies it (cutting an over-long insertion, wx-picker.c
    /// on_insert_text), then the field shows exactly the view model's text. The field holds the
    /// uncut edit while it is delivered; on the next turn the cut text is written into the
    /// field's editor and `draft`, so what is shown is what will be searched (FieldAnchor.show).
    private func edit(_ newText: String) {
        viewModel.textChanged(to: newText)
        draft = newText
        if viewModel.text != newText {
            Task { @MainActor in
                draft = viewModel.text
                fieldAnchor.show(viewModel.text)
            }
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
            guard let editor, editor.string != text else {
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

/// One result: the semibold place label (ellipsised, the full label as its tooltip) and the dim
/// "Added" marker while the place is saved.
private struct PickerRowView: View {
    let row: PickerViewModel.Row

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label)
                .fontWeight(.semibold)  // .wx-picker-label { font-weight: 600 } (style.css:65-66)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.tooltip)
            Spacer(minLength: 8)
            if row.isAdded {
                Text(PickerViewModel.addedText)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)  // without a role the value ("Added") is not published
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityDescription)
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
