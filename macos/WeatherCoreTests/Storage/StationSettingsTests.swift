// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationSettingsTests.swift - the station-layer preferences: defaults, the
// round trip, a file from another version, an unreadable file.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct StationSettingsTests {
    @Test func defaultsAndRoundTrip() throws {
        let dir = try TemporaryDirectory("station-settings")
        let path = WxStationSettings.defaultPath(configDirectory: dir.appending("config").path)
        #expect(path.hasSuffix("/config/weather/station-settings.json"))
        let missing = WxStationSettings.load(path: path)
        #expect(missing.localCorrectionsEnabled && missing.disabledNetworks.isEmpty)
        #expect(missing.isEnabled(.metar) && missing.isEnabled(.aemet))
        var s = WxStationSettings()
        s.localCorrectionsEnabled = false
        s.disabledNetworks = [.iemMesonet, .frost]
        s.save(path: path)
        #expect(WxStationSettings.load(path: path) == s)
        #expect(!WxStationSettings.load(path: path).isEnabled(.frost))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("\"disabledNetworks\" : [\n    \"frost\",\n    \"iemMesonet\"\n  ]"))
    }

    @Test func otherVersionsAndDamage() throws {
        let dir = try TemporaryDirectory("station-settings-other")
        let path = dir.appending("s.json").path
        // a network this version does not know, and a missing field
        try Data(#"{"disabledNetworks": ["dmi", "future-net"]}"#.utf8).write(to: URL(fileURLWithPath: path))
        let other = WxStationSettings.load(path: path)
        #expect(other.disabledNetworks == [.dmi] && other.localCorrectionsEnabled)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(WxStationSettings.load(path: path) == WxStationSettings())
        #expect(WxStationSettings.load(path: "") == WxStationSettings())
    }
}
