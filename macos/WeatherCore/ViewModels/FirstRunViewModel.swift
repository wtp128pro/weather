// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FirstRunViewModel.swift - the data of the main window's "empty" page (the
// first run, wx-window.c:978-1015 as mapped in the run's cartography,
// ui-widgets.md:98-114): the title, the hint, the five suggestion chips
// (PickerViewModel.suggestedPlaces) with their "Add <label>" tooltips, and the
// "Add a city" button. A chip adds its place through AppModel.add (which also
// selects it); a refused add does nothing and shows no message.
//
// The units the chip's place is saved with are the page's units choice
// (`units`, PickerViewModel.unitsChoices / unitsTitle(_:)): the user's pick
// (`setUnits(_:)`), else WxGeo.defaultUnits of the highlighted chip's country
// code (`highlight(at:)`: hover or keyboard focus; a click highlights its chip
// first), else AppModel's default units. The add always passes them to
// AppModel explicitly (DECISIONS #34).

import Foundation
import Observation

/// The first-run (empty) page of the main window.
@MainActor
@Observable
public final class FirstRunViewModel {
    /// The page title (CSS wx-empty-title).
    public nonisolated static let title = "No places yet"
    /// The hint under the title.
    public nonisolated static let hint = "Pick a city to see its weather and when it will rain."
    /// The button that opens the picker (action win.add).
    public nonisolated static let addCityTitle = "Add a city"

    /// One suggestion chip.
    public struct Chip: Sendable, Identifiable {
        /// place.key.
        public let id: String
        /// The place the chip adds.
        public let place: WxPlace
        /// The chip text: the city name.
        public let title: String
        /// The tooltip: "Add " + place.label.
        public let tooltip: String
    }

    /// The five chips, in the order of PickerViewModel.suggestedPlaces().
    public let chips: [Chip]

    /// The index of the highlighted chip (hover or keyboard focus), nil for none.
    public private(set) var highlightedIndex: Int?
    /// The units the user picked (`setUnits(_:)`), nil while the country preselection applies.
    public private(set) var unitsOverride: WxUnits?

    @ObservationIgnored private let model: AppModel

    /// The page over `model`.
    public init(model: AppModel) {
        self.model = model
        chips = PickerViewModel.suggestedPlaces().map { place in
            Chip(id: place.key, place: place, title: place.name, tooltip: "Add " + place.label)
        }
    }

    /// Whether the empty page is shown: the places list is empty (the "empty" stack page).
    public var isShown: Bool { model.places.isEmpty }

    /// The units choice of the place being added: the user's pick, else the preselection of the
    /// highlighted chip's country (WxGeo.defaultUnits), else AppModel's default units. Reading it
    /// observes AppModel.defaultUnits.
    public var units: WxUnits {
        if let unitsOverride {
            return unitsOverride
        }
        let code = highlightedIndex.map { chips[$0].place.countryCode } ?? ""
        return WxGeo.defaultUnits(countryCode: code, fallback: model.defaultUnits)
    }

    /// The user picked the units: the country preselection no longer applies on this page.
    public var isUnitsOverridden: Bool { unitsOverride != nil }

    /// The chip at `index` is highlighted (nil or an index without a chip: none). Without a user
    /// pick, `units` follows its place's country.
    public func highlight(at index: Int?) {
        highlightedIndex = index.flatMap { chips.indices.contains($0) ? $0 : nil }
    }

    /// The user picked `units`: they hold, whatever is highlighted later, for every chip added.
    public func setUnits(_ units: WxUnits) {
        unitsOverride = units
    }

    /// A click on the chip at `index`: highlights it, then adds and selects its place with the
    /// chosen `units` (AppModel.add). A refused add changes nothing and shows nothing.
    /// - Returns: the add's result, nil when no chip has that index.
    @discardableResult
    public func addSuggestion(at index: Int) -> AppModel.AddResult? {
        guard chips.indices.contains(index) else {
            return nil
        }
        highlight(at: index)
        return model.add(chips[index].place, units: units)
    }
}
