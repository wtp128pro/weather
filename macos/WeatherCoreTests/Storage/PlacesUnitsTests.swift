// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PlacesUnitsTests.swift - the per-place unit system of WxPlaces (macOS only;
// the C places.json has no "units"): the store entry with its getter and
// setter by key, and the lenient places.json member that keeps "version" 1.

import Foundation
import Testing
@testable import WeatherCore

/// places.json exactly as a release without per-place units writes it (no
/// "units" member): the earlier placesFileGolden bytes plus a custom location.
private let preUnitsFile = "{\n  \"version\": 1,\n  \"places\": [\n"
    + "    {\"name\": \"Zürich\", \"admin1\": \"Kanton Zürich\", \"country\": \"Schweiz\", \"country_code\": \"CH\", \"lat\": 47.3769, \"lon\": 8.5417, \"timezone\": \"Europe/Zurich\"},\n"
    + "    {\"name\": \"100 Main St\", \"admin1\": \"Miami, Florida\", \"country\": \"United States\", \"country_code\": \"US\", \"lat\": 25.7617, \"lon\": -80.1918, \"timezone\": \"America/New_York\", \"custom\": true, \"custom_name\": \"Home\", \"street_address\": \"100 Main St, Miami, FL\"},\n"
    + "    {\"name\": \"Tiny\", \"admin1\": \"\", \"country\": \"\", \"country_code\": \"\", \"lat\": 1e-300, \"lon\": 180, \"timezone\": \"\"}\n"
    + "  ]\n}\n"

/// A version-1 places.json whose elements are `members` (one place each,
/// 1 degree of latitude apart, so none is a duplicate).
private func placesFile(_ members: [String]) -> String {
    let elements = members.enumerated().map { i, extra in
        "{\"name\": \"P\(i)\", \"lat\": \(i), \"lon\": 10\(extra)}"
    }
    return "{\"version\": 1, \"places\": [" + elements.joined(separator: ", ") + "]}"
}

private func write(_ text: String, _ path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func place(_ name: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(name: name, lat: lat, lon: lon)
}

@Suite struct PlacesUnitsTests {
    // MARK: - The store entry

    @Test func unitsPerEntryByKey() throws {
        let tmp = try TemporaryDirectory("places-units-key")
        let path = tmp.appending("places.json").path
        let pl = try #require(WxPlaces(path: path))
        let a = try place("Paris", 48.8566, 2.3522)
        let b = try place("Lyon", 45.76, 4.84)
        #expect(pl.add(a))
        #expect(pl.add(b))
        try pl.save()
        var changes = 0
        pl.onChanged = { changes += 1 }

        // New places have none; each entry keeps its own.
        #expect(pl.units(forKey: a.key) == nil)
        #expect(pl.units(forKey: b.key) == nil)
        #expect(pl.setUnits(.metric, forKey: a.key))
        #expect(pl.units(forKey: a.key) == .metric)
        #expect(pl.units(forKey: b.key) == nil)
        #expect(pl.isDirty)
        #expect(changes == 1)
        #expect(pl.setUnits(.imperial, forKey: b.key))
        #expect(pl.units(forKey: a.key) == .metric)
        #expect(pl.units(forKey: b.key) == .imperial)
        #expect(changes == 2)

        // Unchanged or unknown: false, nothing announced.
        #expect(!pl.setUnits(.metric, forKey: a.key))
        #expect(!pl.setUnits(.metric, forKey: "nowhere"))
        #expect(!pl.setUnits(.metric, forKey: nil))
        #expect(pl.units(forKey: "nowhere") == nil)
        #expect(pl.units(forKey: nil) == nil)
        #expect(changes == 2)

        // The choice survives a relaunch (save, then a fresh list loads it).
        try pl.save()
        #expect(!pl.isDirty)
        let back = try #require(WxPlaces(path: path))
        #expect(try back.load() == 0)
        #expect(back.units(forKey: a.key) == .metric)
        #expect(back.units(forKey: b.key) == .imperial)

        // nil clears it again (the place then follows the caller's default).
        #expect(back.setUnits(nil, forKey: a.key))
        #expect(back.units(forKey: a.key) == nil)
        #expect(back.units(forKey: b.key) == .imperial)
    }

    @Test func unitsSurviveEntryUpdates() throws {
        let tmp = try TemporaryDirectory("places-units-updates")
        let path = tmp.appending("places.json").path
        let pl = try #require(WxPlaces(path: path))
        let paris = try place("Paris", 48.8566, 2.3522)
        let lyon = try place("Lyon", 45.76, 4.84)
        let nice = try place("Nice", 43.70, 7.27)
        for p in [paris, lyon, nice] {
            #expect(pl.add(p))
        }
        #expect(pl.setUnits(.metric, forKey: paris.key))
        #expect(pl.setUnits(.imperial, forKey: lyon.key))

        // Rename (custom name), then a street address: the same entry.
        let home = try paris.withCustomLocation(customName: "Home")
        #expect(pl.updatePlace(key: paris.key, with: home))
        #expect(pl.units(forKey: home.key) == .metric)
        let street = try home.withCustomLocation(customName: "Home", streetAddress: "1 Rue de Rivoli, Paris")
        #expect(pl.updatePlace(key: home.key, with: street))
        #expect(pl.units(forKey: street.key) == .metric)

        // New coordinates change the key; the units follow the entry.
        let moved = try lyon.withCoordinates(lat: 45.70, lon: 4.90)
        #expect(moved.key != lyon.key)
        #expect(pl.updatePlace(key: lyon.key, with: moved))
        #expect(pl.units(forKey: moved.key) == .imperial)
        #expect(pl.units(forKey: lyon.key) == nil)

        // Move and reorder: the units travel with their place.
        #expect(pl.move(from: 0, to: 2))
        #expect(pl.move(from: 2, to: 1))
        #expect(pl.move(from: 0, to: 2))
        #expect(pl.places.map(\.key) == [street.key, nice.key, moved.key])
        #expect(pl.units(forKey: street.key) == .metric)
        #expect(pl.units(forKey: moved.key) == .imperial)
        #expect(pl.units(forKey: nice.key) == nil)

        // And through a relaunch.
        try pl.save()
        let back = try #require(WxPlaces(path: path))
        #expect(try back.load() == 0)
        #expect(back.places == pl.places)
        #expect(back.places.map { back.units(forKey: $0.key) } == [.metric, nil, .imperial])
    }

    @Test func unitsChangeIsNotReplacement() throws {
        let tmp = try TemporaryDirectory("places-units-identity")
        let path = tmp.appending("places.json").path
        let pl = try #require(WxPlaces(path: path))
        let p = try place("Miami", 25.7617, -80.1918)
        #expect(pl.add(p))
        let before = pl.places

        #expect(pl.setUnits(.metric, forKey: p.key))
        let after = try #require(pl.place(at: 0))
        #expect(pl.places == before)
        #expect(after == p)
        #expect(after.hashValue == p.hashValue)
        #expect(Set(pl.places) == Set(before))
        #expect(after.key == p.key)
        #expect(pl.index(ofKey: p.key) == 0)
        // The place itself did not change, so it is no update...
        #expect(!pl.updatePlace(key: p.key, with: p))
        #expect(pl.units(forKey: p.key) == .metric)
        // ...and a second Miami is a duplicate whatever its units.
        #expect(!pl.canAdd(p))

        // The same element read with other units is the same WxPlace.
        let metricPath = tmp.appending("metric.json").path
        let imperialPath = tmp.appending("imperial.json").path
        try write(placesFile([", \"units\": \"metric\""]), metricPath)
        try write(placesFile([", \"units\": \"imperial\""]), imperialPath)
        let m = try #require(WxPlaces(path: metricPath))
        let i = try #require(WxPlaces(path: imperialPath))
        #expect(try m.load() == 0)
        #expect(try i.load() == 0)
        let pm = try #require(m.place(at: 0))
        let pi = try #require(i.place(at: 0))
        #expect(m.units(forKey: pm.key) == .metric)
        #expect(i.units(forKey: pi.key) == .imperial)
        #expect(pm == pi)
        #expect(pm.hashValue == pi.hashValue)
    }

    // MARK: - places.json

    @Test func writesUnitsMemberVersion1() async throws {
        let tmp = try TemporaryDirectory("places-units-write")
        let path = tmp.appending("places.json").path
        let pl = try #require(WxPlaces(path: path))
        let a = try place("Metric Town", 10, 10)
        let b = try place("Imperial Town", 20, 20)
        let c = try place("Default Town", 30, 30)
        for p in [a, b, c] {
            #expect(pl.add(p))
        }
        #expect(pl.setUnits(.metric, forKey: a.key))
        #expect(pl.setUnits(.imperial, forKey: b.key))
        try pl.save()
        let text = try StoreJSONTests.readAll(path)
        #expect(text.hasPrefix("{\n  \"version\": 1,\n  \"places\": [\n"))
        #expect(text.contains("\"timezone\": \"\", \"units\": \"metric\"},\n"))
        #expect(text.contains("\"timezone\": \"\", \"units\": \"imperial\"},\n"))
        #expect(text.components(separatedBy: "\"units\"").count == 3, "an unset place has no member")

        // The envelope is still version 1, and a reader that only knows the
        // older members (placeFromJSON) still reads every element.
        let root = try StoreJSON.load(path: path, maxBytes: WxPlaces.maxFileBytes, what: "places")
        let obj = try StoreJSON.rootObject(root, what: "places", version: 1)
        let arr = try #require(StoreJSON.nodeArray(obj.member("places")))
        #expect(arr.map { StoreJSON.placeFromJSON($0) } == [a, b, c])
        #expect(arr.map { StoreJSON.placeUnits($0) } == [.metric, .imperial, nil])

        // The asynchronous save the app uses writes the same document.
        try FileManager.default.removeItem(atPath: path)
        #expect(pl.setUnits(.metric, forKey: c.key))
        #expect(pl.setUnits(.metric, forKey: c.key) == false)
        try await pl.saveAsync()
        let asyncText = try StoreJSONTests.readAll(path)
        #expect(asyncText.contains("\"version\": 1,"))
        #expect(asyncText.components(separatedBy: "\"units\": \"metric\"").count == 3)
        #expect(!pl.isDirty)
    }

    @Test func missingUnitsKeepsPlace() throws {
        let tmp = try TemporaryDirectory("places-units-missing")
        let path = tmp.appending("places.json").path
        try write(preUnitsFile, path)
        let pl = try #require(WxPlaces(path: path))
        #expect(try pl.load() == 0)
        #expect(pl.places.map(\.name) == ["Zürich", "100 Main St", "Tiny"])
        #expect(pl.place(at: 1)?.customName == "Home")
        #expect(pl.places.allSatisfy { pl.units(forKey: $0.key) == nil })
        #expect(!pl.isDirty)

        // Absent means "the caller's default": every such place takes the
        // units of settings.json.
        let settingsPath = tmp.appending("settings.json").path
        let saved = try #require(WxSettings(path: settingsPath))
        #expect(saved.setUnits(.metric))
        try saved.save()
        let settings = try #require(WxSettings(path: settingsPath))
        try settings.load()
        #expect(pl.places.map { pl.units(forKey: $0.key) ?? settings.units } == [.metric, .metric, .metric])

        // Loading and saving never invents units: the file is unchanged.
        try pl.save()
        #expect(try StoreJSONTests.readAll(path) == preUnitsFile)
    }

    @Test func malformedUnitsKeepsPlace() throws {
        let tmp = try TemporaryDirectory("places-units-malformed")
        let path = tmp.appending("places.json").path
        let bad = [
            "1", "1.5", "true", "false", "null", "[]", "[\"metric\"]", "{}", "{\"units\": \"metric\"}",
            "\"\"", "\"Metric\"", "\"METRIC\"", "\"Imperial\"", "\"metric \"", "\"si\"", "\"us\"",
        ]
        try write(placesFile(bad.map { ", \"units\": \($0)" }), path)
        let pl = try #require(WxPlaces(path: path))
        #expect(try pl.load() == 0)
        #expect(pl.count == bad.count)
        for (i, p) in pl.places.enumerated() {
            #expect(p.name == "P\(i)")
            #expect(pl.units(forKey: p.key) == nil, "units: \(bad[i])")
        }
        #expect(!pl.isDirty)
    }

    @Test func validUnitsLoad() throws {
        let tmp = try TemporaryDirectory("places-units-valid")
        let path = tmp.appending("places.json").path
        try write(placesFile([", \"units\": \"metric\"", ", \"units\": \"imperial\"", "", ", \"units\": 7"]), path)
        let pl = try #require(WxPlaces(path: path))
        #expect(try pl.load() == 0)
        #expect(pl.places.map { pl.units(forKey: $0.key) } == [.metric, .imperial, nil, nil])

        // The member may stand anywhere in the element.
        try write(
            "{\"version\": 1, \"places\": [{\"units\": \"metric\", \"name\": \"First\", \"lat\": 1, \"lon\": 2}]}",
            path)
        #expect(try pl.load() == 0)
        let first = try #require(pl.place(at: 0))
        #expect(first.name == "First")
        #expect(pl.units(forKey: first.key) == .metric)
    }
}
