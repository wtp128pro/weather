// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// FirstRunViewModelTests.swift - the units choice of the first-run page (U50,
// DECISIONS #34): preselected by the highlighted chip's country
// (WxGeo.defaultUnits), else the default units; the user's pick holds over
// highlight changes; a chip's add passes the chosen units to AppModel, which
// saves them with the place. The page's texts and chips are covered in
// PickerViewModelTests (firstRunPage, firstRunChipAdds).
//
// Everything runs through a real, loaded AppModel (no providers, a
// ManualClock, its files in a temporary directory) and WxPlaces on disk.

import Foundation
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct FirstRunViewModelTests {
    @Test func firstRunPreselectsAndSaves() async throws {
        let dir = try TemporaryDirectory("first-run-units")
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let model = AppModel(registry: WxRegistry(), storage: storage, clock: ManualClock(), online: true,
                             log: { _, _ in })
        await model.load()
        model.setDefaultUnits(.metric)
        let page = FirstRunViewModel(model: model)
        // Nothing highlighted: the default units.
        #expect(page.highlightedIndex == nil && page.units == .metric && !page.isUnitsOverridden)
        // Every chip is a US place: imperial, whatever the default.
        for i in page.chips.indices {
            page.highlight(at: i)
            #expect(page.highlightedIndex == i)
            #expect(page.units == .imperial, "\(page.chips[i].title)")
        }
        page.highlight(at: page.chips.count)  // no chip there: none
        #expect(page.highlightedIndex == nil && page.units == .metric)
        // A click highlights its chip and saves the preselection, not the metric default.
        #expect(page.addSuggestion(at: 0) == .added)  // Miami
        #expect(page.highlightedIndex == 0)
        #expect(model.selectedPlace?.key == page.chips[0].place.key && model.selectedPlace?.units == .imperial)
        // The user's pick holds over highlight changes and is what the next chip saves.
        page.setUnits(.metric)
        page.highlight(at: 1)
        #expect(page.isUnitsOverridden && page.unitsOverride == .metric && page.units == .metric)
        page.highlight(at: nil)
        #expect(page.units == .metric)
        #expect(page.addSuggestion(at: 2) == .added)  // Tampa
        #expect(model.selectedPlace?.key == page.chips[2].place.key && model.selectedPlace?.units == .metric)
        // Saved with the places: the default no longer matters, in the model or on disk.
        model.setDefaultUnits(.imperial)
        #expect(model.places.map(\.units) == [.imperial, .metric])
        #expect(await model.flush())
        let list = try #require(WxPlaces(path: storage.placesPath))
        try list.load()
        #expect(list.units(forKey: page.chips[0].place.key) == .imperial)
        #expect(list.units(forKey: page.chips[2].place.key) == .metric)
    }
}
