// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U39AuditFixTests.swift - regression tests for the storage audit fixes
// (slice P13): a station-settings save that cannot write reports it (U13-F1),
// and a places.json or settings.json that could not be loaded is moved aside
// by the next save instead of being overwritten (U13-F3).

import Darwin
import Foundation
import Testing
@testable import WeatherCore

/// A valid place at (lat, lon) named "Place <tag>".
private func place(_ tag: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(
        name: "Place \(tag)", admin1: "Region", country: "Country", countryCode: "US", lat: lat, lon: lon,
        timezone: "Europe/Oslo")
}

/// The names `FileIO.moveAside` gave to files that were at `path`.
private func keptFiles(of path: String) throws -> [String] {
    let dir = (path as NSString).deletingLastPathComponent
    let prefix = (path as NSString).lastPathComponent + FileIO.keptInfix
    return try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(prefix) }
        .map { "\(dir)/\($0)" }
}

@Suite struct U39AuditFixTests {
    // U13-F1: StationSettings.save swallowed the error of a failed write.
    @Test func stationSettingsSaveReportsWriteFailure() throws {
        let tmp = try TemporaryDirectory("u39-station")
        let dir = tmp.appending("weather").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        let path = "\(dir)/station-settings.json"
        var s = WxStationSettings()
        #expect(s.save(path: path))
        // A folder that cannot be written: the save fails, says so, and the old file survives.
        #expect(chmod(dir, 0o500) == 0)
        defer { _ = chmod(dir, 0o700) }
        s.localCorrectionsEnabled = false
        #expect(!s.save(path: path), "a station-settings write that failed is reported")
        #expect(WxStationSettings.load(path: path).localCorrectionsEnabled)
        // No configuration folder: nothing is saved, and that is not a failure.
        #expect(s.save(path: ""))
    }

    // U13-F3: a places.json the load could not read was replaced by the next save.
    @Test func unreadablePlacesFileSurvivesNextSave() throws {
        let tmp = try TemporaryDirectory("u39-places")
        let path = tmp.appending("places.json").path
        // A missing file is not kept: the first save writes places.json in place.
        let old = try #require(WxPlaces(path: path))
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try old.load() }?.isNotFound == true)
        #expect(old.add(try place("Oslo", 59.91, 10.75)))
        #expect(old.add(try place("Bergen", 60.39, 5.32)))
        try old.save()
        #expect(try keptFiles(of: path).isEmpty)
        // The same document with a version this build does not know.
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let foreign = Data(text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2").utf8)
        #expect(foreign != Data(text.utf8))
        try foreign.write(to: URL(fileURLWithPath: path))

        let pl = try #require(WxPlaces(path: path))
        let e = StoreJSONTests.caught { () throws(WxStoreError) in try pl.load() }
        #expect(e != nil && e?.isNotFound == false)
        #expect(pl.count == 0 && !pl.isDirty)
        // The load itself leaves the file alone.
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == foreign)
        #expect(try keptFiles(of: path).isEmpty)

        #expect(pl.add(try place("Paris", 48.86, 2.35)))
        try pl.save()
        let kept = try keptFiles(of: path)
        #expect(kept.count == 1, "the unreadable file is moved aside, not overwritten")
        if let first = kept.first {
            #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == foreign)
        }
        let reread = try #require(WxPlaces(path: path))
        #expect(try reread.load() == 0)
        #expect(reread.places.map(\.name) == ["Place Paris"])

        // Only the first save moves the file; later saves, and saves after a
        // valid load, replace the new one as usual.
        #expect(pl.add(try place("Lyon", 45.76, 4.84)))
        try pl.save()
        #expect(reread.add(try place("Nice", 43.70, 7.27)))
        try reread.save()
        #expect(try keptFiles(of: path).count == 1)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == WxPlaces.serialize(reread.places))
    }

    // U13-F3, the asynchronous save the app uses (AppModel.startSaves).
    @Test func unreadablePlacesFileSurvivesAsyncSave() async throws {
        let tmp = try TemporaryDirectory("u39-places-async")
        let path = tmp.appending("places.json").path
        // A hand edit that left a trailing comma: not strict JSON.
        let damaged = Data(#"{"version": 1, "places": [{"name": "Oslo"},]}"#.utf8)
        try damaged.write(to: URL(fileURLWithPath: path))
        let pl = try #require(WxPlaces(path: path))
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try pl.load() } != nil)
        #expect(pl.add(try place("Paris", 48.86, 2.35)))
        try await pl.saveAsync()
        #expect(!pl.isDirty)
        let kept = try keptFiles(of: path)
        #expect(kept.count == 1, "the unreadable file is moved aside, not overwritten")
        if let first = kept.first {
            #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == damaged)
        }
        let reread = try #require(WxPlaces(path: path))
        #expect(try reread.load() == 0 && reread.count == 1)

        // Only the first save moves the file: a second asynchronous save, and a synchronous one
        // after it, replace places.json in place (U39 verifier handoff, mutant M4).
        #expect(pl.add(try place("Lyon", 45.76, 4.84)))
        try await pl.saveAsync()
        #expect(try keptFiles(of: path).count == 1)
        #expect(pl.add(try place("Nice", 43.70, 7.27)))
        try pl.save()
        #expect(try keptFiles(of: path).count == 1)
    }

    // U13-F3, the settings.json sibling.
    @Test func unreadableSettingsFileSurvivesNextSave() async throws {
        let tmp = try TemporaryDirectory("u39-settings")
        let path = tmp.appending("settings.json").path
        let fresh = try #require(WxSettings(path: path))
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try fresh.load() }?.isNotFound == true)
        #expect(fresh.setProviderDisabled("met-no", true))
        try fresh.save()
        #expect(try keptFiles(of: path).isEmpty)
        let damaged = Data("{\n  \"version\": 1,\n  \"units\": \"metric\",\n  \"disabled_providers\": [\"met-no\",]\n}\n".utf8)
        try damaged.write(to: URL(fileURLWithPath: path))
        let s = try #require(WxSettings(path: path))
        let e = StoreJSONTests.caught { () throws(WxStoreError) in try s.load() }
        #expect(e != nil && e?.isNotFound == false)
        #expect(s.disabledProviders.isEmpty && !s.isDirty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == damaged)

        #expect(s.setSelected(try place("Oslo", 59.91, 10.75).key))
        try s.save()
        var kept = try keptFiles(of: path)
        #expect(kept.count == 1, "the unreadable file is moved aside, not overwritten")
        if let first = kept.first {
            #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == damaged)
        }
        // Only the first save moves the file: the next one replaces settings.json in place
        // (U39 verifier handoff, mutant M5).
        #expect(s.setProviderDisabled("met-no", true))
        try s.save()
        #expect(try keptFiles(of: path).count == 1)

        // The asynchronous save does the same.
        try damaged.write(to: URL(fileURLWithPath: path))
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try s.load() } != nil)
        #expect(s.setUnits(.metric))
        try await s.saveAsync()
        kept = try keptFiles(of: path)
        #expect(kept.count == 2)
        // Again only that first save moves the file: a second asynchronous save and a synchronous
        // one keep the two moved-aside files (mutant M4).
        #expect(s.setProviderDisabled("met-no", true))
        try await s.saveAsync()
        #expect(try keptFiles(of: path).count == 2)
        #expect(s.setProviderDisabled("met-no", false))
        try s.save()
        #expect(try keptFiles(of: path).count == 2)
        let reread = try #require(WxSettings(path: path))
        try reread.load()
        #expect(reread.units == .metric)
    }
}
