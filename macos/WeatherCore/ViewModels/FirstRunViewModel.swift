// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FirstRunViewModel.swift - the data of the main window's "empty" page (the
// first run, wx-window.c:978-1015 as mapped in the run's cartography,
// ui-widgets.md:98-114): the title, the hint, the five suggestion chips
// (PickerViewModel.suggestedPlaces) with their "Add <label>" tooltips, and the
// "Add a city" button. A chip adds its place through AppModel.add (which also
// selects it); a refused add does nothing and shows no message.

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

    /// A click on the chip at `index`: adds and selects its place (AppModel.add). A refused add
    /// changes nothing and shows nothing.
    /// - Returns: the add's result, nil when no chip has that index.
    @discardableResult
    public func addSuggestion(at index: Int) -> AppModel.AddResult? {
        guard chips.indices.contains(index) else {
            return nil
        }
        return model.add(chips[index].place)
    }
}
