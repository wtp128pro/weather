// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U32AuditFixTests.swift - regression tests for the verified audit findings of
// slice P01 (AppModel / AppEnvironment) fixed by U32. U01-F1/F2 are comment-only
// and pinned by AppEnvironmentTests.defaultWiringRegistersTheProductionSetInCOrder.

import Foundation
import Testing
@testable import WeatherCore

@MainActor
@Suite struct U32AuditFixTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory("u32-audit-fixes")
    }

    // U01-F3: on a spring-forward day (America/New_York, 2026-03-08) the clock skips 02:00-03:00.
    // The Settings row for hour 2 resolved to 03:00 EDT, so it showed solar bin 2 (row 3's
    // learning) a second time, and its now-window overlapped rows 1 and 3. The skipped hour has
    // nothing learned and is never now; every other row keeps its own clock hour.
    @Test func springForwardSkippedHourShowsNothingAndIsNeverNow() async throws {
        let storage = AppEnvironment.StorageRoot(configDirectory: dir.appending("config").path,
                                                 cacheDirectory: dir.appending("cache").path)
        let place = try WxPlace(name: "New York", admin1: "New York", country: "United States", countryCode: "US",
                                lat: 40.7128, lon: -74.006, timezone: "America/New_York")
        let list = try #require(WxPlaces(path: storage.placesPath))
        #expect(list.add(place))
        try list.save()
        // Three samples (-1 degC) in solar bin 2: 07:00Z-07:40Z, just after the 02:00 EST jump.
        let jumpS: Int64 = 1_772_953_200  // 2026-03-08 07:00Z = 03:00 EDT
        var bias = WxLocalBias()
        for i in 0..<3 {
            let t = jumpS + Int64(i) * WxLocalBias.minSpacingS
            #expect(WxLocalBias.solarHour(t, lon: place.lon) == 2)
            let added = bias.addSample(placeKey: place.key, lon: place.lon, modelTempC: 24, observedTempC: 23, nowS: t)
            #expect(added)
        }
        bias.save(path: WxLocalBias.defaultPath(configDirectory: storage.configDirectory))

        let clock = ManualClock(wallMicroseconds: 1_772_964_000 * 1_000_000)  // 2026-03-08 10:00Z
        let m = AppModel(registry: WxRegistry(), storage: storage, clock: clock, online: false)
        await m.load()
        let hours = try #require(m.localCorrections.first).hours
        #expect(hours.count == 24 && hours.map(\.hour) == Array(0..<24))

        // Row 3 (03:30 EDT, solar 02:34) shows the learning (3 of 6 samples: half the -1 error);
        // row 2 does not repeat it.
        #expect(hours[3].samples == 3 && abs(hours[3].correctionC + 0.5) < 1e-9)
        #expect(hours[2].samples == 0 && hours[2].correctionC == 0)
        // The skipped row carries the documented "no such hour" time, 0, not a 02:30 of another
        // day (U32 verifier handoff: the rejected .strict variant resolves it to 2026-03-09 02:30).
        #expect(hours[2].tS == 0)

        // Every other row is the middle of its own clock hour.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for h in hours where h.hour != 2 {
            let date = Date(timeIntervalSince1970: TimeInterval(h.tS))
            #expect(calendar.component(.hour, from: date) == h.hour && calendar.component(.minute, from: date) == 30)
        }
        // At most one row is now at any time: the rows' [tS - 1800, tS + 1800) windows are disjoint.
        for i in hours.indices {
            for j in hours.indices where j > i {
                #expect(abs(hours[i].tS - hours[j].tS) >= 3600, "rows \(i) and \(j)")
            }
        }
        #expect(await m.flush())
    }
}
