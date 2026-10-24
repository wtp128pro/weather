// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// CustomLocationTests.swift - tests for street-address locations, custom location
// naming ("Home", "Work", "Friend's place", etc.), in-place renaming, < 5 km
// neighborhood co-existence, and JSON persistence round-tripping.

import Foundation
import Testing
@testable import WeatherCore

@Suite struct CustomLocationTests {
    @Test func customLocationNamingAndSubtitle() throws {
        let base = try WxPlace(
            name: "1600 Pennsylvania Ave NW",
            admin1: "Washington, District of Columbia",
            country: "United States",
            countryCode: "US",
            lat: 38.8977,
            lon: -77.0365,
            timezone: "America/New_York"
        )
        let work = try base.withCustomLocation(
            customName: "Work",
            streetAddress: "1600 Pennsylvania Ave NW, Washington, DC",
            isCustomLocation: true
        )
        #expect(work.isCustomLocation == true)
        #expect(work.customName == "Work")
        #expect(work.name == "Work")
        #expect(work.displayTitle == "Work")
        #expect(work.streetAddress == "1600 Pennsylvania Ave NW, Washington, DC")
        #expect(work.displayAddressSubtitle.contains("1600 Pennsylvania Ave NW"))
        #expect(work.displayAddressSubtitle.contains("United States"))

        // Clearing custom name restores the street address as the primary name.
        let cleared = try work.withCustomLocation(customName: "", isCustomLocation: true)
        #expect(cleared.customName.isEmpty)
        #expect(cleared.name == "1600 Pennsylvania Ave NW")
        #expect(cleared.admin1 == "Washington, DC")
        #expect(cleared.isCustomLocation == true)
    }

    @Test func multipleCustomLocationsWithinSameCityAllowed() throws {
        let dir = try TemporaryDirectory("custom-places")
        let path = dir.appending("places.json").path
        let places = try #require(WxPlaces(path: path))

        let homeBase = try WxPlace(
            name: "100 Main St",
            admin1: "Miami, Florida",
            country: "United States",
            countryCode: "US",
            lat: 25.7743,
            lon: -80.1937,
            timezone: "America/New_York"
        )
        let workBase = try WxPlace(
            name: "400 Brickell Ave",
            admin1: "Miami, Florida",
            country: "United States",
            countryCode: "US",
            lat: 25.7689,
            lon: -80.1901,
            timezone: "America/New_York"
        )
        let friendBase = try WxPlace(
            name: "800 Ocean Dr",
            admin1: "Miami Beach, Florida",
            country: "United States",
            countryCode: "US",
            lat: 25.7781,
            lon: -80.1314,
            timezone: "America/New_York"
        )

        let home = try homeBase.withCustomLocation(customName: "Home", streetAddress: "100 Main St, Miami, FL")
        let work = try workBase.withCustomLocation(customName: "Work", streetAddress: "400 Brickell Ave, Miami, FL")
        let friend = try friendBase.withCustomLocation(
            customName: "Friend's place",
            streetAddress: "800 Ocean Dr, Miami Beach, FL"
        )

        // All three are < 5 km apart, yet all three are allowed because they are custom locations.
        #expect(places.add(home) == true)
        #expect(places.add(work) == true)
        #expect(places.add(friend) == true)
        #expect(places.count == 3)

        try places.save()

        let reloaded = try #require(WxPlaces(path: path))
        let dropped = try reloaded.load()
        #expect(dropped == 0)
        #expect(reloaded.count == 3)
        #expect(reloaded.place(at: 0)?.customName == "Home")
        #expect(reloaded.place(at: 0)?.streetAddress == "100 Main St, Miami, FL")
        #expect(reloaded.place(at: 1)?.customName == "Work")
        #expect(reloaded.place(at: 2)?.customName == "Friend's place")
    }

    @Test @MainActor func appModelAddAndRenameCustomLocations() async throws {
        let dir = try TemporaryDirectory("custom-appmodel")
        let storage = AppEnvironment.StorageRoot(
            configDirectory: dir.appending("config").path,
            cacheDirectory: dir.appending("cache").path
        )
        let model = AppModel(registry: WxRegistry(), storage: storage, online: false, log: { _, _ in })
        await model.load()

        let addr = try WxPlace(
            name: "350 Fifth Ave",
            admin1: "New York, New York",
            country: "United States",
            countryCode: "US",
            lat: 40.7484,
            lon: -73.9857,
            timezone: "America/New_York"
        )

        // Add "Work" at 350 Fifth Ave
        let res1 = model.addCustomLocation(addr, customName: "Work", streetAddress: "350 Fifth Ave, New York, NY")
        #expect(res1 == .added)
        #expect(model.places.count == 1)
        #expect(model.places[0].place.displayTitle == "Work")

        // Add "Friend's place" at the exact same building coordinates (nudged key so both co-exist)
        let res2 = model.addCustomLocation(
            addr,
            customName: "Friend's place",
            streetAddress: "350 Fifth Ave Apt 42B, New York, NY"
        )
        #expect(res2 == .added)
        #expect(model.places.count == 2)
        #expect(model.places[1].place.displayTitle == "Friend's place")

        // Rename "Work" to "Home Office" in-place
        let key0 = model.places[0].key
        let renamed = model.renamePlace(
            key: key0,
            customName: "Home Office",
            streetAddress: "350 Fifth Ave, Manhattan, NY"
        )
        #expect(renamed == true)
        #expect(model.places[0].place.displayTitle == "Home Office")
        #expect(model.places[0].place.streetAddress == "350 Fifth Ave, Manhattan, NY")
    }

    @Test func presetLocationNamesCatalog() {
        let labels = WxAddressGeocoder.presetLocationNames.map(\.label)
        #expect(labels.contains("Home"))
        #expect(labels.contains("Work"))
        #expect(labels.contains("Friend's place"))
    }
}
