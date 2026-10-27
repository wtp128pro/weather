// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PickerViewModel.swift - the presentation logic of the "Add a city" window
// (WxPicker, src/ui/wx-picker.{h,c}) without any widget: the entry text and
// its limits, the query that is searched, the 300 ms debounce, the Enter
// auto-repeat guard, the status line, the result rows with their "Added"
// marks and accessibility text, adding a row (refusals worked out by
// AppModel.add), and the keys the window handles itself (Escape).
//
// The view binds to it as follows:
//  - the search field shows `text`; its edits go to `textChanged(to:)` (the
//    whole new text, as a SwiftUI binding delivers it) or, for an editor that
//    reports insertions, `insertText(_:at:)` / `deleteText(from:to:)`; Return
//    in the field calls `submit()`;
//  - the status line shows `statusText` while `isStatusVisible`, styled by
//    `statusStyle` (.error for errors, .dim otherwise);
//  - the list shows `rows` (label, "Added" mark, accessibility label and
//    description, tooltip); Return / Space on a row and a double click call
//    `activateRow(at:)` (or `handleRowKey(_:modifiers:at:)`);
//  - the window's key handler calls `handleKey(_:modifiers:)` first (the C
//    capture-phase controller): a plain Escape requests the close;
//  - the units choice of the place being added shows `units` among
//    `unitsChoices` (titles `unitsTitle(_:)`); the list's keyboard cursor goes
//    to `highlightRow(at:)` (or `highlight(_:)` for a place that is not one of
//    `rows`), which preselects WxGeo.defaultUnits of the highlighted place's
//    country code (the default units for none or a malformed code) until the
//    user picks units with `setUnits(_:)`; that choice then holds for every
//    place this picker adds. Every add passes the chosen units to AppModel
//    explicitly (DECISIONS #34): `activateRow(at:)`, and for the view's own
//    add paths `addPlace(_:)` / `addCustomLocation(_:customName:streetAddress:)`;
//  - `onPlaceAdded` and `onCloseRequest` stand for the "place-added" signal
//    and gtk_window_close(); the owner calls `invalidate()` when the window
//    goes away for good (gtk_window_destroy): only that cancels the search.
//
// Time comes only from the injected WxClock (the debounce sleep and the Enter
// guard); every completion is applied only while its request is still the
// current one, re-checked after each resume (DECISIONS #50).

import Foundation
import Observation

/// The "Add a city" window's model (WxPicker, src/ui/wx-picker.h).
@MainActor
@Observable
public final class PickerViewModel {
    // MARK: - Constants (src/ui/wx-picker.h:141-150 and the widget texts of wx-picker.c)

    /// Quiet time after the last edit before a search starts, and the Enter repeat guard
    /// (WX_PICKER_SEARCH_DELAY_MS).
    public nonisolated static let searchDelayMs = 300
    /// Most characters (Unicode scalars, as GTK counts them) of the entry (WX_PICKER_MAX_QUERY_CHARS).
    public nonisolated static let maxQueryChars = 64
    /// Most UTF-8 bytes of the entry (WX_PICKER_MAX_QUERY_BYTES).
    public nonisolated static let maxQueryBytes = 64
    /// A query shorter than this many bytes starts no search (WX_PICKER_MIN_QUERY_BYTES).
    public nonisolated static let minQueryBytes = 2
    /// Most bytes of the error text of a failed search (WX_PICKER_MAX_MESSAGE_BYTES).
    public nonisolated static let maxMessageBytes = 200
    /// Most rows a search lists (WX_GEOCODER_MAX_HITS).
    public nonisolated static let maxResults = WxLimits.geocoderMaxHits

    /// Window title (wx-picker.c:1248).
    public nonisolated static let windowTitle = "Add a city"
    /// Default window size (wx-picker.c:1249).
    public nonisolated static let defaultWidth = 460
    /// Default window size (wx-picker.c:1249).
    public nonisolated static let defaultHeight = 520
    /// Placeholder of the search field (wx-picker.c:1270).
    public nonisolated static let searchPlaceholder = "Search for a city"
    /// Accessibility label of the search field (wx-picker.c:1272).
    public nonisolated static let searchAccessibilityLabel = "Search for a city"
    /// The marker of a saved place, and its rows' accessibility description (wx-picker.c:364, 410).
    public nonisolated static let addedText = "Added"

    // MARK: - Types

    /// The style of the status line (the CSS classes "dim-label" and "error").
    public enum StatusStyle: Sendable, Equatable {
        /// Information ("Suggestions", "Searching…", "Type at least 2 letters", "No results").
        case dim
        /// A failed search or a refused add.
        case error
    }

    /// One row of the results list.
    public struct Row: Sendable, Identifiable {
        /// The row's position in the list.
        public let id: Int
        /// The place the row adds.
        public let place: WxPlace
        /// place.key.
        public let key: String
        /// The row text: exactly place.label ("Name, Admin1, Country").
        public let label: String
        /// Whether the place is in the places list (the "Added" marker is shown).
        public let isAdded: Bool

        /// The accessibility label of the row: the label.
        public var accessibilityLabel: String { label }
        /// The accessibility description of the row: "Added" while saved, else "".
        public var accessibilityDescription: String { isAdded ? PickerViewModel.addedText : "" }
        /// The tooltip of the (ellipsised) label: the full label.
        public var tooltip: String { label }
    }

    /// The keys the picker reacts to.
    public enum Key: Sendable, Equatable {
        /// Escape.
        case escape
        /// Return / Enter (also the keypad's).
        case enter
        /// The space bar.
        case space
        /// Any other key.
        case other
    }

    /// The modifier keys held with a key. Caps Lock is not a modifier of GTK's default mask
    /// (gtk_accelerator_get_default_mod_mask), so it never changes what a key does.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)

        /// The modifiers that count (all but Caps Lock).
        fileprivate var significant: Modifiers { subtracting(.capsLock) }
    }

    // MARK: - State

    /// The text of the search field, exactly as typed (within the limits).
    public private(set) var text = ""
    /// The status line text; "" hides the line.
    public private(set) var statusText = ""
    /// The status line style.
    public private(set) var statusStyle: StatusStyle = .dim
    /// The places listed, in order (at most `maxResults`).
    public private(set) var results: [WxPlace] = []
    /// True once `invalidate()` ran: no search, no add, no callback any more.
    public private(set) var isInvalidated = false
    /// The highlighted place (the list's keyboard cursor), nil for none.
    public private(set) var highlightedPlace: WxPlace?
    /// The units the user picked (`setUnits(_:)`), nil while the country preselection applies.
    public private(set) var unitsOverride: WxUnits?

    /// "place-added": called once per place this picker added, with its key, before the close
    /// request. Not called for refusals or for changes made elsewhere.
    @ObservationIgnored public var onPlaceAdded: ((String) -> Void)?
    /// gtk_window_close(): the picker asks its window to close (after an add, on Escape).
    @ObservationIgnored public var onCloseRequest: (() -> Void)?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let clock: any WxClock
    /// The debounce timer (debounce_id) and its generation.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var debounceToken: UInt64 = 0
    /// The request in flight (search_cancellable): its token while it is current.
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var currentRequest: UInt64?
    @ObservationIgnored private var nextRequest: UInt64 = 0
    /// The query of the latest search (last_query) and when it was answered (answered_us).
    @ObservationIgnored private var lastQuery: String?
    @ObservationIgnored private var answeredUs: Int64 = 0

    /// wx_picker_new: a picker over `model` (its places list and its place search) that shows
    /// the suggestions under "Suggestions" with no search pending.
    /// - Parameters:
    ///   - model: the application model; the picker adds through `AppModel.add` and searches
    ///     through `AppModel.search`.
    ///   - clock: the time source of the debounce timer and the Enter guard.
    public init(model: AppModel, clock: any WxClock = SystemClock()) {
        self.model = model
        self.clock = clock
        showSuggestions()
    }

    // MARK: - Derived

    /// Whether the status line is shown (set_status: hidden while its text is empty).
    public var isStatusVisible: Bool { !statusText.isEmpty }

    /// The rows of `results`, each with its "Added" mark as the places list is now. Reading it
    /// observes `AppModel.places`, so a change made elsewhere is reflected at once.
    public var rows: [Row] {
        _ = model.places  // observation: the marks follow the places list (on_places_changed)
        return results.enumerated().map { i, place in
            let key = place.key
            return Row(id: i, place: place, key: key, label: place.label, isAdded: model.isSaved(key: key))
        }
    }

    /// The units choice of the place being added: the user's pick, else the preselection of the
    /// highlighted place's country (WxGeo.defaultUnits: imperial for the US, its territories,
    /// Liberia and Myanmar, metric elsewhere), else, with nothing highlighted or no usable country
    /// code, AppModel's default units. Reading it observes AppModel.defaultUnits.
    public var units: WxUnits {
        if let unitsOverride {
            return unitsOverride
        }
        return WxGeo.defaultUnits(countryCode: highlightedPlace?.countryCode ?? "", fallback: model.defaultUnits)
    }

    /// The user picked the units: the country preselection no longer applies in this picker.
    public var isUnitsOverridden: Bool { unitsOverride != nil }

    /// Whether a debounced search is pending (debounce_id != 0).
    var isDebouncePending: Bool { debounceTask != nil }
    /// Whether a search is in flight (search_cancellable != NULL).
    var isSearchInFlight: Bool { currentRequest != nil }

    // MARK: - Suggestions

    /// wx_suggested_places_new: the five first-run places of Florida, in this order.
    public nonisolated static func suggestedPlaces() -> [WxPlace] {
        let table: [(String, Double, Double)] = [  // wx-picker.c:34-36
            ("Miami", 25.7743, -80.1937), ("Orlando", 28.5383, -81.3792),
            ("Tampa", 27.9475, -82.4584), ("Jacksonville", 30.3322, -81.6557),
            ("Key West", 24.5551, -81.7800),
        ]
        return table.compactMap { name, lat, lon in
            try? WxPlace(name: name, admin1: "Florida", country: "United States", countryCode: "US",
                         lat: lat, lon: lon, timezone: "America/New_York")  // wx-picker.c:45-46
        }
    }

    // MARK: - Units choice

    /// The units the add flow offers, in their order.
    public nonisolated static let unitsChoices: [WxUnits] = [.imperial, .metric]

    /// The title of a units choice (the wording of Settings > General).
    public nonisolated static func unitsTitle(_ units: WxUnits) -> String {
        units == .metric ? "Metric (\u{00B0}C, km/h, mm)" : "Imperial (\u{00B0}F, mph, in)"
    }

    /// The list's cursor moved to the row at `position` (nil or a position without a row: none).
    /// Without a user pick, `units` follows the new place's country.
    public func highlightRow(at position: Int?) {
        guard let position, results.indices.contains(position) else {
            highlight(nil)
            return
        }
        highlight(results[position])
    }

    /// `place` is highlighted (a place the view lists apart from `rows`, such as an address
    /// match), nil for none. Without a user pick, `units` follows its country.
    public func highlight(_ place: WxPlace?) {
        highlightedPlace = place
    }

    /// The user picked `units` for the place being added: it holds, whatever is highlighted
    /// later, for every add of this picker.
    public func setUnits(_ units: WxUnits) {
        unitsOverride = units
    }

    // MARK: - Query rules

    /// entry_query: the text that is searched for `text`: the forbidden characters of
    /// WxText.sanitize removed, then the surrounding ASCII white space (g_strstrip).
    nonisolated static func query(from text: String) -> String {
        let clean = WxText.sanitize(text, maxBytes: text.utf8.count)
        let bytes = Array(clean.utf8)
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || (b >= 0x09 && b <= 0x0D) }  // g_ascii_isspace
        var start = 0
        var end = bytes.count
        while start < end && isSpace(bytes[start]) { start += 1 }
        while end > start && isSpace(bytes[end - 1]) { end -= 1 }
        return String(decoding: bytes[start ..< end], as: UTF8.self)
    }

    /// query_is_searchable: at least `minQueryBytes` bytes and accepted by the geocoder's rule.
    nonisolated static func isSearchable(_ query: String) -> Bool {
        query.utf8.count >= minQueryBytes && WxText.isUsableName(query, maxBytes: maxQueryBytes)
    }

    // MARK: - Editing the entry

    /// The SwiftUI binding's setter: the field now holds `newText`. The edit is worked out as one
    /// replacement (common prefix and suffix kept) whose inserted part is cut like an insertion
    /// (`insertText(_:at:)`); the resulting text is what the field shows.
    public func textChanged(to newText: String) {
        let old = Array(text.unicodeScalars)
        let new = Array(newText.unicodeScalars)
        var prefix = 0
        while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix && suffix < new.count - prefix
            && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let kept = Array(old[..<prefix]) + Array(old[(old.count - suffix)...])
        let inserted = new[prefix ..< (new.count - suffix)]
        let fitting = Self.fitting(inserted, into: kept)
        let result = Array(old[..<prefix]) + fitting + Array(old[(old.count - suffix)...])
        apply(result)
    }

    /// gtk_editable_set_text: replaces the whole text; the new text is cut like an insertion
    /// into an empty field. A different `newText` is a delete plus an insert, so the "changed"
    /// handler runs even when the cut text equals the old one.
    public func setText(_ newText: String) {
        guard !newText.utf8.elementsEqual(text.utf8) else {
            return  // gtk_text_set_text returns early for the same UTF-8 bytes
        }
        apply(Self.fitting(Array(newText.unicodeScalars)[...], into: []), always: true)
    }

    /// gtk_editable_insert_text: inserts `inserted` at the character position `position`
    /// (clamped to the text). An insertion that would exceed `maxQueryBytes` bytes is cut to the
    /// largest prefix that fits on a character boundary (on_insert_text), then to the characters
    /// left of `maxQueryChars` (the entry's max-length).
    /// - Returns: the position after the inserted characters.
    @discardableResult
    public func insertText(_ inserted: String, at position: Int) -> Int {
        var scalars = Array(text.unicodeScalars)
        let at = min(max(position, 0), scalars.count)
        let fitting = Self.fitting(Array(inserted.unicodeScalars)[...], into: scalars)
        if fitting.isEmpty {
            return at
        }
        scalars.insert(contentsOf: fitting, at: at)
        apply(scalars)
        return at + fitting.count
    }

    /// gtk_editable_delete_text: deletes the characters `start ..< end` (clamped; end < 0 means
    /// the end of the text).
    public func deleteText(from start: Int, to end: Int) {
        var scalars = Array(text.unicodeScalars)
        let lo = min(max(start, 0), scalars.count)
        let hi = end < 0 ? scalars.count : min(max(end, lo), scalars.count)
        guard lo < hi else {
            return
        }
        scalars.removeSubrange(lo ..< hi)
        apply(scalars)
    }

    /// The part of `inserted` that fits into a text of `existing`: within the bytes left of
    /// `maxQueryBytes` (cut on a character boundary) and the characters left of `maxQueryChars`.
    private nonisolated static func fitting(_ inserted: ArraySlice<Unicode.Scalar>,
                                            into existing: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let haveBytes = existing.reduce(0) { $0 + UTF8.width($1) }
        var bytesLeft = max(0, maxQueryBytes - haveBytes)
        var charsLeft = max(0, maxQueryChars - existing.count)
        var out: [Unicode.Scalar] = []
        for scalar in inserted {
            let width = UTF8.width(scalar)
            guard width <= bytesLeft, charsLeft > 0 else {
                break
            }
            out.append(scalar)
            bytesLeft -= width
            charsLeft -= 1
        }
        return out
    }

    /// Stores `scalars` as the text and runs the "changed" handler if the text changed (or
    /// `always`).
    private func apply(_ scalars: [Unicode.Scalar], always: Bool = false) {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let newText = String(view)
        guard always || !newText.utf8.elementsEqual(text.utf8) else {
            return
        }
        text = newText
        searchChanged()
    }

    /// on_search_changed: cancels the pending and in-flight search, then shows the suggestions
    /// (empty query), asks for more letters (not searchable) or restarts the debounce timer.
    private func searchChanged() {
        guard !isInvalidated else {
            return
        }
        cancelSearch()
        let query = Self.query(from: text)
        if query.isEmpty {
            showSuggestions()
        } else if !Self.isSearchable(query) {
            results = []
            setStatus("Type at least \(Self.minQueryBytes) letters", .dim)  // wx-picker.c:945
        } else {
            armDebounce()
        }
    }

    // MARK: - Searching

    /// g_timeout_add(WX_PICKER_SEARCH_DELAY_MS, on_debounce_fired).
    private func armDebounce() {
        debounceToken &+= 1
        let token = debounceToken
        let clock = self.clock
        let deadline = clock.monotonicMicroseconds + Int64(Self.searchDelayMs) * 1000
        debounceTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return  // cancelled: the timer was removed
            }
            guard let self, self.debounceTask != nil, self.debounceToken == token else {
                return
            }
            self.debounceFired()
        }
    }

    /// on_debounce_fired: starts the search for the entry's query.
    private func debounceFired() {
        debounceTask = nil
        guard !isInvalidated else {
            return
        }
        startSearch(Self.query(from: text))
    }

    /// cancel_search: removes the timer, forgets the latest search and cancels the request in
    /// flight (which stops being current BEFORE it is cancelled).
    private func cancelSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        debounceToken &+= 1
        lastQuery = nil
        let task = searchTask
        searchTask = nil
        currentRequest = nil
        task?.cancel()
    }

    /// start_search: a new current request for `query`, "Searching…" (U+2026), the service call.
    private func startSearch(_ query: String) {
        nextRequest &+= 1
        let token = nextRequest
        currentRequest = token
        lastQuery = query
        setStatus("Searching\u{2026}", .dim)  // wx-picker.c:835
        let model = self.model
        searchTask = Task { [weak self] in
            let outcome: Result<[WxPlace], any Error>
            do {
                outcome = .success(try await model.search(query))
            } catch {
                outcome = .failure(error)
            }
            self?.searchDone(token, outcome)
        }
    }

    /// on_search_done: applies the outcome only if `token` is still the current request.
    private func searchDone(_ token: UInt64, _ outcome: Result<[WxPlace], any Error>) {
        guard !isInvalidated, currentRequest == token else {
            return  // cancelled, superseded or the picker is gone
        }
        currentRequest = nil
        searchTask = nil
        answeredUs = clock.monotonicMicroseconds
        switch outcome {
        case .success(let places):
            results = Array(places.prefix(Self.maxResults))  // fill_results
            setStatus(results.isEmpty ? "No results" : nil, .dim)  // wx-picker.c:788
        case .failure(let error) where error is CancellationError:
            lastQuery = nil  // no answer: Enter may ask again at once
            setStatus(nil, .dim)
        case .failure(let error):
            let message = (error as? WxError)?.message ?? error.localizedDescription
            let text = WxText.sanitize(message, maxBytes: Self.maxMessageBytes)
            results = []
            setStatus("Search failed: " + text, .error)  // wx-picker.c:794
        }
    }

    /// repeats_latest_search: the same query (by UTF-8 bytes, g_strcmp0) as the latest search,
    /// which is in flight or was answered less than `searchDelayMs` ago.
    private func repeatsLatestSearch(_ query: String) -> Bool {
        guard let lastQuery, lastQuery.utf8.elementsEqual(query.utf8) else {
            return false
        }
        return currentRequest != nil
            || clock.monotonicMicroseconds - answeredUs < Int64(Self.searchDelayMs) * 1000
    }

    /// on_search_activate (Return in the field): searches at once unless the query is not
    /// searchable or would only repeat the latest search.
    public func submit() {
        let query = Self.query(from: text)
        guard !isInvalidated, Self.isSearchable(query), !repeatsLatestSearch(query) else {
            return
        }
        cancelSearch()
        startSearch(query)
    }

    // MARK: - Adding

    /// on_list_activate (Return / Space on a row, a double click): highlights the row and adds
    /// its place with the chosen `units`. Nothing happens for a position without a row.
    public func activateRow(at position: Int) {
        guard results.indices.contains(position) else {
            return
        }
        add(results[position])
    }

    /// The view's own add of `place` (a row it lists, such as an address match): highlights it and
    /// adds it with the chosen `units` through AppModel.add. No signal, close request or status:
    /// the caller handles the result. `.failed` once the picker is invalidated.
    @discardableResult
    public func addPlace(_ place: WxPlace) -> AppModel.AddResult {
        guard !isInvalidated else {
            return .failed
        }
        highlight(place)
        return model.add(place, units: units)
    }

    /// The view's own custom-location add (a location name or a street address): highlights
    /// `place` and adds it with the chosen `units` through AppModel.addCustomLocation. No signal,
    /// close request or status: the caller handles the result. `.failed` once invalidated.
    @discardableResult
    public func addCustomLocation(_ place: WxPlace, customName: String?, streetAddress: String?)
        -> AppModel.AddResult
    {
        guard !isInvalidated else {
            return .failed
        }
        highlight(place)
        return model.addCustomLocation(place, customName: customName, streetAddress: streetAddress, units: units)
    }

    /// add_item: AppModel.add with the chosen `units` of the highlighted `place`; on success
    /// "place-added" then the close request, on refusal the reason in the status line (class
    /// "error").
    private func add(_ place: WxPlace) {
        guard !isInvalidated else {
            return
        }
        highlight(place)
        let result = model.add(place, units: units)
        switch result {
        case .added:
            onPlaceAdded?(place.key)
            if !isInvalidated {
                requestClose()
            }
        case .full, .duplicate, .failed:
            setStatus(Self.refusalMessage(result), .error)
        }
    }

    /// refusal_message (wx-picker.c:563-577) for the classification of AppModel.add.
    nonisolated static func refusalMessage(_ result: AppModel.AddResult) -> String {
        switch result {
        case .full:
            return "You can save up to 50 places"
        case .duplicate:
            return "Already in your places"
        case .failed, .added:
            return "Could not add this place"
        }
    }

    // MARK: - Keys and closing

    /// The window's capture-phase key handler (on_key_pressed): Escape without a modifier
    /// requests the close.
    /// - Returns: true when the key was handled (the event stops), false to let it propagate.
    @discardableResult
    public func handleKey(_ key: Key, modifiers: Modifiers = []) -> Bool {
        guard key == .escape, modifiers.significant.isEmpty else {
            return false
        }
        requestClose()
        return true
    }

    /// A key on the focused row: Return or Space without a modifier adds the row.
    /// - Returns: true when the key was handled.
    @discardableResult
    public func handleRowKey(_ key: Key, modifiers: Modifiers = [], at position: Int) -> Bool {
        guard key == .enter || key == .space, modifiers.significant.isEmpty else {
            return false
        }
        activateRow(at: position)
        return true
    }

    /// gtk_window_close: asks the owner to close the window. It cancels nothing (a close may
    /// be vetoed or only hide the window); `invalidate()` does.
    public func requestClose() {
        guard !isInvalidated else {
            return
        }
        onCloseRequest?()
    }

    /// The window is gone for good (on_toplevels_changed / dispose): the timer and the search
    /// are cancelled and the status line cleared; from now on the picker searches, adds and
    /// reports nothing. Idempotent.
    public func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        cancelSearch()
        setStatus(nil, .dim)  // no "Searching…" without a request
        onPlaceAdded = nil
        onCloseRequest = nil
    }

    // MARK: - Status

    /// show_suggestions: the suggested places under "Suggestions".
    private func showSuggestions() {
        results = Self.suggestedPlaces()
        setStatus("Suggestions", .dim)  // wx-picker.c:741
    }

    /// set_status: the text ("" or nil hides the line) and its style.
    private func setStatus(_ message: String?, _ style: StatusStyle) {
        statusText = message ?? ""
        statusStyle = style
    }
}
