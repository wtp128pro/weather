// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// PlacesTests.swift - port of the places groups of src/storage/test-storage.c
// (/places/*, and the places half of the generic /store/* cases). Expected
// values are the C test literals, cited as test-storage.c:LINE; the golden
// file text is derived by hand from the C writer code (cited).

import Darwin
import Foundation
import Testing
@testable import WeatherCore

/// The places row of the StoreOps table (k_places_ops, test-storage.c:1110-1139, 1236-1246).
private enum PlacesOps: StoreJSONTests.StoreOps {
    static let name = "places"
    static let maxFileBytes = WxPlaces.maxFileBytes
    static let docPrefix = "{\"version\":1,\"places\":[]"

    static func create(_ path: String) throws -> WxPlaces {
        try #require(WxPlaces(path: path))
    }

    static func mutate(_ s: WxPlaces, _ step: Int) throws {
        #expect(s.add(try gridPlace(step)), "places_mutate \(step)")
    }

    static func isDirty(_ s: WxPlaces) -> Bool { s.isDirty }
    static func save(_ s: WxPlaces) throws(WxStoreError) { try s.save() }
    static func load(_ s: WxPlaces) throws(WxStoreError) { try s.load() }
    static func fingerprint(_ s: WxPlaces) -> String { placesFingerprint(s) }
    static func setOnChanged(_ s: WxPlaces, _ body: @escaping () -> Void) { s.onChanged = body }
    static func beginSave(_ s: WxPlaces) throws(WxStoreError) -> StoreJSON.SaveJob { try s.beginSave() }
    static func finishSave(_ s: WxPlaces, _ job: StoreJSON.SaveJob, _ outcome: Result<Void, WxStoreError>) throws(WxStoreError) {
        try s.finishSave(job, outcome)
    }

    static func saveAsync(_ s: WxPlaces) async throws(WxStoreError) { try await s.saveAsync() }
}

/// A valid place at (lat, lon) named "Place <tag>" (make_place, test-storage.c:705-715).
private func makePlace(_ tag: String, _ lat: Double, _ lon: Double) throws -> WxPlace {
    try WxPlace(
        name: "Place \(tag)", admin1: "Region", country: "Country", countryCode: "US", lat: lat, lon: lon,
        timezone: "America/New_York")
}

/// Place number `i` of a grid whose neighbours are more than 20 km apart
/// (grid_place, test-storage.c:717-722).
private func gridPlace(_ i: Int) throws -> WxPlace {
    try makePlace("\(i)", -60.0 + 0.5 * Double(i % 100), -170.0 + 0.7 * Double(i / 100) * 10.0)
}

/// places_fingerprint (test-storage.c:1129-1139); %a is replaced by the bit pattern.
private func placesFingerprint(_ pl: WxPlaces) -> String {
    pl.places.map {
        "\($0.name)|\($0.admin1)|\($0.country)|\($0.countryCode)|\($0.timezone)|"
            + "\(String($0.lat.bitPattern, radix: 16))|\(String($0.lon.bitPattern, radix: 16));"
    }.joined()
}

private func keys(_ pl: WxPlaces) -> [String] {
    pl.places.map(\.key)
}

@Suite struct PlacesTests {
    // MARK: - Generic store cases, places row

    @Test func storeRoundtrip() throws {
        // C: /store/roundtrip
        try StoreJSONTests.roundtripAndFiles(PlacesOps.self)
    }

    @Test func storeLoadErrors() throws {
        // C: /store/load-errors
        try StoreJSONTests.loadErrors(PlacesOps.self)
    }

    @Test func storeHostileNesting() throws {
        // C: /store/hostile-nesting
        try StoreJSONTests.hostileNesting(PlacesOps.self)
    }

    @Test func storeSaveFailure() throws {
        // C: /store/save-failure
        try StoreJSONTests.saveFailure(PlacesOps.self)
    }

    @Test func storeSaveAsync() async throws {
        // C: /store/save-async
        try await StoreJSONTests.saveAsyncSnapshot(PlacesOps.self)
    }

    @Test func storeSaveAsyncFailureAndCancel() async throws {
        // C: /store/save-async-failure-and-cancel
        try await StoreJSONTests.saveAsyncFailureAndCancel(PlacesOps.self)
    }

    @Test func storeSaveAsyncMany() async throws {
        // C: /store/save-async-many
        try await StoreJSONTests.saveAsyncMany(PlacesOps.self)
    }

    @Test func storeStaleTemps() throws {
        // C: /store/stale-temps
        try StoreJSONTests.staleTemps(PlacesOps.self)
    }

    @Test func storeFuzz() throws {
        // C: /store/fuzz (GRand seed 777 + k with k = 0 for places, test-storage.c:4042)
        try StoreJSONTests.fuzz(PlacesOps.self, seed: 777)
    }

    // C: /store/save-async-context (test-storage.c:4358-4387): the completion is
    // delivered in the caller's context - here the caller's actor.
    @MainActor @Test func storeSaveAsyncContext() async throws {
        let tmp = try TemporaryDirectory("places-ctx")
        let pl = try PlacesOps.create(tmp.appending("ctx.json").path)
        try PlacesOps.mutate(pl, 0)
        try await pl.saveAsync()
        #expect(pthread_main_np() != 0, "resumed on the main actor")
        #expect(!pl.isDirty)
    }

    // C: /store/load-on-worker-thread (test-storage.c:4426-4460): load() on a
    // worker, hand-off, use on the caller; "changed" is emitted on the worker.
    @Test func storeLoadOnWorkerThread() async throws {
        let tmp = try TemporaryDirectory("places-worker")
        let path = tmp.appending("load.json").path
        let w = try PlacesOps.create(path)
        for i in 0 ..< 3 {
            try PlacesOps.mutate(w, i)
        }
        #expect(throws: Never.self) { try w.save() }
        let want = placesFingerprint(w)
        let (loaded, changedOnMain, ok): (WxPlaces?, Bool?, Bool) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let pl = WxPlaces(path: path) else {
                    cont.resume(returning: (nil, nil, false))
                    return
                }
                var onMain: Bool?
                pl.onChanged = { onMain = pthread_main_np() != 0 }
                let ok = (try? pl.load()) != nil
                pl.onChanged = nil
                cont.resume(returning: (pl, onMain, ok))
            }
        }
        #expect(ok)
        #expect(changedOnMain == false, "emitted on the worker")
        let pl = try #require(loaded)
        #expect(placesFingerprint(pl) == want, "usable after the hand-off")
    }

    // C: /store/default-paths (test-storage.c:1964-1993), places part. The C
    // default is <XDG config>/weather/places.json; the macOS app passes its
    // container directory. The critical for "" is GLIB-INTERNAL; here it is nil.
    @Test func storeDefaultPaths() throws {
        #expect(WxPlaces.defaultPath(configDirectory: "/cfg") == "/cfg/weather/places.json")
        let pl = try #require(WxPlaces(path: "/tmp/x/y.json"))
        #expect(pl.path == "/tmp/x/y.json")
        #expect(WxPlaces(path: "") == nil)
    }

    // C: /store/nul-escape-places (test_store_nul_escape_places, test-storage.c:3884-3919)
    @Test func storeNulEscapePlaces() throws {
        let tmp = try TemporaryDirectory("places-nul")
        let path = tmp.appending("places.json").path
        let valid = "{\"name\":\"Fine\",\"lat\":1.5,\"lon\":2.5}"
        let bad: [(String, String)] = [
            ("name", "{\"name\":\"Miami\\u0000\\u001b[31mjunk\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("name, whole value", "{\"name\":\"\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("admin1", "{\"name\":\"Miami\",\"admin1\":\"Flo\\u0000rida\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("country", "{\"name\":\"Miami\",\"country\":\"\\u0000US\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("country code", "{\"name\":\"Miami\",\"country_code\":\"U\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("timezone", "{\"name\":\"Miami\",\"timezone\":\"America/New_York\\u0000\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("member name", "{\"na\\u0000me\":\"Miami\",\"lat\":25.7617,\"lon\":-80.1918}"),
            ("unknown member", "{\"name\":\"Miami\",\"lat\":25.7617,\"lon\":-80.1918,\"x\":[\"\\u0000\"]}"),
        ]
        for (label, element) in bad {
            // The valid sibling before and after does not rescue the file: the gate refuses all of it.
            try StoreJSONTests.expectRejected(
                PlacesOps.self, path, "{\"version\":1,\"places\":[\(valid),\(element),\(valid)]}", label)
        }
        try StoreJSONTests.expectRejected(
            PlacesOps.self, path, "{\"version\":1,\"pla\\u0000ces\":[{\"name\":\"A\",\"lat\":1,\"lon\":2}]}",
            "places member name")

        // The escaped-backslash form is ordinary text: the element loads with that name.
        try StoreJSONTests.putText(
            path, "{\"version\":1,\"places\":[{\"name\":\"Miami\\\\u0000junk\",\"lat\":1,\"lon\":2}]}")
        let pl = try PlacesOps.create(path)
        #expect(throws: Never.self) { try pl.load() }
        #expect(pl.count == 1)
        #expect(pl.place(at: 0)?.name == "Miami\\u0000junk") // test-storage.c:3918
    }

    // MARK: - /places/*

    // C: /places/basic (test_places_basic, test-storage.c:1811-1913)
    @Test func placesBasic() throws {
        let pl = try PlacesOps.create("/nonexistent/never-used.json")
        var changed = 0
        pl.onChanged = { changed += 1 }
        let miami = try makePlace("Miami", 25.7617, -80.1918)
        let tampa = try makePlace("Tampa", 27.9506, -82.4572)
        let orlando = try makePlace("Orlando", 28.5383, -81.3792)
        let london = try makePlace("London", 51.5072, -0.1276)

        #expect(pl.add(miami))
        #expect(pl.add(tampa))
        #expect(pl.add(orlando))
        #expect(pl.add(london))
        #expect(changed == 4)
        #expect(keys(pl) == ["25.7617,-80.1918", "27.9506,-82.4572", "28.5383,-81.3792", "51.5072,-0.1276"])
        #expect(pl.place(at: 4) == nil)
        #expect(pl.place(at: Int(UInt32.max)) == nil)
        #expect(pl.place(at: -1) == nil)
        #expect(pl.place(at: 0)?.name == "Place Miami")
        #expect(pl.place(at: 0)?.countryCode == "US")
        let p0 = pl.place(at: 0)
        let p3 = pl.place(at: 3)

        #expect(pl.index(ofKey: "27.9506,-82.4572") == 1)
        #expect(pl.index(ofKey: "51.5072,-0.1276") == 3)
        #expect(pl.index(ofKey: "0.0000,0.0000") == nil)
        #expect(pl.index(ofKey: nil) == nil)
        #expect(pl.index(ofKey: "") == nil)
        #expect(pl.index(ofKey: "../etc") == nil)
        #expect(pl.index(ofKey: "25.7617,-80.191") == nil) // prefix of a key
        #expect(pl.index(ofKey: "25.7617,-80.19180") == nil)
        #expect(pl.index(ofKey: "123456789012345678901234567890") == nil) // > 23 bytes

        // Duplicates are rejected without a signal: the same place, the same key, and every
        // place closer than 5 km (Miami -> 0.04 degrees of latitude is 4.4 km).
        let sameKey = try makePlace("Other name", 25.7617, -80.1918)
        let rounding = try makePlace("Rounded", 25.76171, -80.19181)
        let nearMiami = try makePlace("Near", 25.8017, -80.1918)
        #expect(!pl.add(miami))
        #expect(!pl.add(sameKey))
        #expect(!pl.add(rounding))
        #expect(!pl.add(nearMiami))
        #expect(!pl.canAdd(nearMiami))
        #expect(changed == 4)
        #expect(pl.count == 4)

        // Invalid places cannot reach the list: WxPlace refuses them (C: wx_place_copy re-validation).
        #expect(throws: WxError.self) { try WxPlace(name: nil, lat: 1, lon: 1) } // NULL strings
        #expect(throws: WxError.self) { try makePlace("Miami", 95.0, -80.1918) }
        #expect(throws: WxError.self) { try makePlace("Tampa", 27.9506, .nan) }
        #expect(throws: WxError.self) { try WxPlace(name: "bad\u{01}name", lat: 40.0, lon: -0.1276) }
        #expect(!pl.add(nil))
        #expect(changed == 4)

        // Moving keeps the same places (values here; C compares pointers).
        #expect(pl.move(from: 0, to: 2))
        #expect(keys(pl) == ["27.9506,-82.4572", "28.5383,-81.3792", "25.7617,-80.1918", "51.5072,-0.1276"])
        #expect(pl.place(at: 2) == p0)
        #expect(pl.move(from: 3, to: 0))
        #expect(keys(pl) == ["51.5072,-0.1276", "27.9506,-82.4572", "28.5383,-81.3792", "25.7617,-80.1918"])
        #expect(pl.place(at: 0) == p3)
        #expect(pl.move(from: 1, to: 2))
        #expect(keys(pl) == ["51.5072,-0.1276", "28.5383,-81.3792", "27.9506,-82.4572", "25.7617,-80.1918"])
        let before = changed
        #expect(!pl.move(from: 2, to: 2))
        #expect(!pl.move(from: 4, to: 0))
        #expect(!pl.move(from: 0, to: 4))
        #expect(!pl.move(from: Int(UInt32.max), to: 0))
        #expect(!pl.move(from: -1, to: 0))
        #expect(changed == before)

        #expect(pl.remove(key: "28.5383,-81.3792"))
        #expect(changed == before + 1)
        #expect(!pl.remove(key: "28.5383,-81.3792"))
        #expect(!pl.remove(key: nil))
        #expect(!pl.remove(key: "nope"))
        #expect(!pl.remove(key: "123456789012345678901234567890"))
        #expect(changed == before + 1)
        #expect(keys(pl) == ["51.5072,-0.1276", "27.9506,-82.4572", "25.7617,-80.1918"])
        // Everything is order-preserving: re-adding the removed one appends.
        #expect(pl.add(orlando))
        #expect(pl.path == "/nonexistent/never-used.json")
    }

    // C: /places/duplicate-boundaries (test_places_duplicate_boundaries, test-storage.c:1915-1944)
    @Test func placesDuplicateBoundaries() throws {
        // 1 degree of latitude is 111.19 km on the model sphere: 0.0449 deg = 4.99 km, 0.0451 = 5.01 km.
        let pl = try PlacesOps.create("/nonexistent/never-used.json")
        let a = try makePlace("A", 10.0, 10.0)
        let justInside = try makePlace("B", 10.0449, 10.0)
        let justOutside = try makePlace("C", 10.0451, 10.0)
        #expect(pl.add(a))
        #expect(!pl.add(justInside))
        #expect(WxPlaces.isDuplicate(a, justInside))
        #expect(pl.add(justOutside))
        #expect(!WxPlaces.isDuplicate(a, justOutside))

        // Across the antimeridian and over the pole.
        let p2 = try PlacesOps.create("/nonexistent/never-used.json")
        let e1 = try makePlace("E1", 0.0, 179.99)
        let e2 = try makePlace("E2", 0.0, -179.99)
        let n1 = try makePlace("N1", 89.99, 0.0)
        let n2 = try makePlace("N2", 89.99, 180.0)
        let pole1 = try makePlace("P1", 90.0, 0.0)
        let pole2 = try makePlace("P2", 90.0, 123.0)
        #expect(p2.add(e1))
        #expect(!p2.add(e2))
        #expect(p2.add(n1))
        #expect(!p2.add(n2))
        #expect(!p2.add(pole1)) // 1.1 km from n1
        #expect(p2.count == 2)
        let p3 = try PlacesOps.create("/nonexistent/never-used.json")
        #expect(p3.add(pole1))
        #expect(!p3.add(pole2)) // the same point: longitude is meaningless
    }

    // C: /places/capacity (test_places_capacity, test-storage.c:1946-1962)
    @Test func placesCapacity() throws {
        #expect(WxPlaces.maxPlaces == 50) // WX_PLACE_MAX, core/wx-types.h:66
        let pl = try PlacesOps.create("/nonexistent/never-used.json")
        for i in 0 ..< 50 {
            #expect(pl.add(try gridPlace(i)), "\(i)")
        }
        let more = try gridPlace(50)
        #expect(!pl.canAdd(more))
        #expect(!pl.add(more))
        #expect(pl.count == 50)
        // A removal makes room again.
        #expect(pl.remove(key: try gridPlace(0).key))
        #expect(pl.canAdd(more))
        #expect(pl.add(more))
    }

    // C: /places/roundtrip-exact (test_places_roundtrip_exact, test-storage.c:1995-2043)
    @Test func placesRoundtripExact() throws {
        let tmp = try TemporaryDirectory("places-exact")
        let path = tmp.appending("cfg/weather/places.json").path
        let pl = try PlacesOps.create(path)
        let quotes = String(repeating: "\"", count: WxLimits.placeNameMax)
        let slashes = String(repeating: "\\", count: WxLimits.placeNameMax)
        let rows: [(String, String?, String?, String?, String?, Double, Double)] = [
            ("Zürich Straße 日本 🚀", "Kanton Zürich", "Schweiz", "CH", "Europe/Zurich", 47.3769, 8.5417),
            ("quote \" backslash \\ slash / percent %s", "", "", "", "", -33.8688, 151.2093),
            ("Südpol", "", "Antarctica", "", "Etc/GMT+5", -90.0, 0.0),
            ("Nordpol", nil, nil, nil, nil, 90.0, 12.5),
            ("Ost", "", "", "", "", 1e-300, 180.0),
            ("West", "", "", "", "", -0.0, -100.0),
            ("Long", "Long", "Long", "US", "America/Argentina/ComodRivadavia", 12.3456789012345678, -98.7654321098765432),
            (quotes, quotes, slashes, "DE", "UTC", 50.0, 10.0),
            (slashes, slashes, quotes, "", "", -50.0, -10.0),
        ]
        for r in rows {
            let p = try WxPlace(name: r.0, admin1: r.1, country: r.2, countryCode: r.3, lat: r.5, lon: r.6, timezone: r.4)
            #expect(pl.add(p), "\(r.0)")
        }
        #expect(throws: Never.self) { try pl.save() }
        let back = try PlacesOps.create(path)
        var dropped = 9
        #expect(throws: Never.self) { dropped = try back.load() }
        #expect(dropped == 0)
        #expect(back.count == rows.count)
        for i in 0 ..< rows.count {
            let a = try #require(pl.place(at: i))
            let b = try #require(back.place(at: i))
            #expect(a.name == b.name)
            #expect(a.admin1 == b.admin1)
            #expect(a.country == b.country)
            #expect(a.countryCode == b.countryCode)
            #expect(a.timezone == b.timezone)
            #expect(a.lat.bitPattern == b.lat.bitPattern, "assert_same_double lat \(i)")
            #expect(a.lon.bitPattern == b.lon.bitPattern, "assert_same_double lon \(i)")
        }
    }

    // C: /places/max-file-size (test_places_max_file_size, test-storage.c:2046-2067)
    @Test func placesMaxFileSize() throws {
        let tmp = try TemporaryDirectory("places-max")
        let path = tmp.appending("places.json").path
        let pl = try PlacesOps.create(path)
        let quotes = String(repeating: "\"", count: WxLimits.placeNameMax)
        for i in 0 ..< 50 {
            let p = try WxPlace(
                name: quotes, admin1: quotes, country: quotes, countryCode: "US",
                lat: -12.345678901234567 + Double(i), lon: -123.45678901234567 + 2 * Double(i),
                timezone: "America/Argentina/ComodRivadavia")
            #expect(pl.add(p), "\(i)")
        }
        #expect(throws: Never.self) { try pl.save() }
        let text = try StoreJSONTests.readAll(path)
        #expect(text.utf8.count < WxPlaces.maxFileBytes / 4) // test-storage.c:2063
        let back = try PlacesOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(back.count == 50)
    }

    // C: /places/load-partial (test_places_load_partial, test-storage.c:2074-2193)
    @Test func placesLoadPartial() throws {
        let toolong = String(repeating: "n", count: WxLimits.placeNameMax + 1)
        let longOK = String(repeating: "n", count: WxLimits.placeNameMax)
        let cases: [(String, String?)] = [
            ("{\"name\":\"Minimal\",\"lat\":1.5,\"lon\":2.5}", "Minimal"),
            ("{\"name\":\"Full\",\"admin1\":\"A\",\"country\":\"C\",\"country_code\":\"US\","
                + "\"lat\":10,\"lon\":20,\"timezone\":\"America/New_York\"}", "Full"),
            ("{\"name\":\"Ints\",\"lat\":-30,\"lon\":-40}", "Ints"),
            ("{\"name\":\"Exp\",\"lat\":5e1,\"lon\":-1.5E+1}", "Exp"),
            ("{\"name\":\"\(longOK)\",\"lat\":3,\"lon\":4}", longOK),
            ("{\"name\":\"Unicode \\u00e9\\u65e5\",\"lat\":6,\"lon\":7}", "Unicode \u{E9}\u{65E5}"),
            ("{\"name\":\"Extra\",\"lat\":8,\"lon\":9,\"unknown\":[1,2,{\"x\":null}]}", "Extra"),
            // Wrong shapes.
            ("5", nil), ("\"x\"", nil), ("null", nil), ("[]", nil), ("true", nil), ("{}", nil),
            ("{\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":5,\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":null,\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"B1\",\"lat\":\"1\",\"lon\":2}", nil),
            ("{\"name\":\"B2\",\"lat\":1,\"lon\":null}", nil),
            ("{\"name\":\"B3\",\"lon\":2}", nil),
            ("{\"name\":\"B4\",\"lat\":1}", nil),
            ("{\"name\":\"B5\",\"lat\":true,\"lon\":2}", nil),
            ("{\"name\":\"B6\",\"lat\":[1],\"lon\":2}", nil),
            // Out-of-range coordinates.
            ("{\"name\":\"C1\",\"lat\":91,\"lon\":0}", nil),
            ("{\"name\":\"C2\",\"lat\":-91,\"lon\":0}", nil),
            ("{\"name\":\"C3\",\"lat\":0,\"lon\":181}", nil),
            ("{\"name\":\"C4\",\"lat\":0,\"lon\":-180.0001}", nil),
            ("{\"name\":\"C5\",\"lat\":1e30,\"lon\":0}", nil),
            ("{\"name\":\"C6\",\"lat\":9223372036854775807,\"lon\":0}", nil),
            // Names the core rules refuse.
            ("{\"name\":\"\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"   \",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"x\\u0001y\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"x\\u007fy\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"x\\u202ey\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"x\\u2066y\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"\(toolong)\",\"lat\":1,\"lon\":2}", nil),
            // Optional members of the wrong type or value.
            ("{\"name\":\"D1\",\"admin1\":5,\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D2\",\"country\":null,\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D3\",\"country_code\":\"us\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D4\",\"country_code\":\"USA\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D5\",\"timezone\":\"/etc/passwd\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D6\",\"timezone\":\"a/../b\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D7\",\"timezone\":\"-x\",\"lat\":1,\"lon\":2}", nil),
            ("{\"name\":\"D8\",\"timezone\":7,\"lat\":1,\"lon\":2}", nil),
            // Duplicates of kept places: the same coordinates, and within 5 km.
            ("{\"name\":\"Dup1\",\"lat\":1.5,\"lon\":2.5}", nil),
            ("{\"name\":\"Dup2\",\"lat\":1.5,\"lon\":2.52}", nil),
            ("{\"name\":\"Far\",\"lat\":1.5,\"lon\":2.6}", "Far"),
        ]
        let kept = cases.compactMap(\.1)
        let droppedExpected = cases.count - kept.count
        let doc = "{\"version\":1,\"places\":[" + cases.map(\.0).joined(separator: ",") + "],\"extra\":{\"x\":[]}}"
        let tmp = try TemporaryDirectory("places-partial")
        let path = tmp.appending("places.json").path
        try StoreJSONTests.putText(path, doc)

        let pl = try PlacesOps.create(path)
        var changed = 0
        pl.onChanged = { changed += 1 }
        var dropped = 99
        #expect(throws: Never.self) { dropped = try pl.load() }
        #expect(dropped == droppedExpected)
        #expect(pl.places.map(\.name) == kept)
        #expect(changed == 1)
        #expect(!pl.isDirty)

        // Loading again replaces the content.
        #expect(throws: Never.self) { try pl.load() }
        #expect(pl.count == kept.count)
        #expect(changed == 2)

        // Empty array: success, empty list, one signal because it was non-empty.
        try StoreJSONTests.putText(path, "{\"version\":1,\"places\":[]}")
        #expect(throws: Never.self) { dropped = try pl.load() }
        #expect(dropped == 0)
        #expect(pl.count == 0)
        #expect(changed == 3)
        #expect(throws: Never.self) { try pl.load() }
        #expect(changed == 3) // empty -> empty: nothing to announce

        // Invalid UTF-8 and a lone surrogate inside a name: the element is dropped (or the
        // document refused), never a crash.
        let odd: [[UInt8]] = [
            Array("{\"version\":1,\"places\":[{\"name\":\"a".utf8) + [0xFF, 0xFE]
                + Array("\",\"lat\":1,\"lon\":2},{\"name\":\"".utf8) + [0xC3, 0x28]
                + Array("\",\"lat\":3,\"lon\":4}]}".utf8),
            Array("{\"version\":1,\"places\":[{\"name\":\"\\ud800\",\"lat\":1,\"lon\":2}]}".utf8),
        ]
        for doc in odd {
            try StoreJSONTests.putFile(path, doc)
            let e = StoreJSONTests.caught { () throws(WxStoreError) in try pl.load() }
            if e == nil {
                #expect(pl.count == 0)
            } else {
                #expect(StoreJSONTests.isParse(e), "\(String(describing: e))")
            }
        }
    }

    // C: /places/load-cap (test_places_load_cap, test-storage.c:2195-2216)
    @Test func placesLoadCap() throws {
        var doc = "{\"version\":1,\"places\":["
        for i in 0 ..< 70 {
            let p = try gridPlace(i)
            doc += (i > 0 ? "," : "") + "{\"name\":\"N\(i)\",\"lat\":" + String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), p.lat)
                + ",\"lon\":" + String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), p.lon) + "}"
        }
        doc += "]}"
        let tmp = try TemporaryDirectory("places-cap")
        let path = tmp.appending("places.json").path
        try StoreJSONTests.putText(path, doc)
        let pl = try PlacesOps.create(path)
        var dropped = 0
        #expect(throws: Never.self) { dropped = try pl.load() }
        #expect(pl.count == 50)
        #expect(dropped == 20) // test-storage.c:2213
        #expect(pl.place(at: 0)?.name == "N0")
        #expect(pl.place(at: 49)?.name == "N49")
    }

    // C: /places/dirty-and-signals (test_places_dirty_and_signals, test-storage.c:2218-2258)
    @Test func placesDirtyAndSignals() throws {
        let tmp = try TemporaryDirectory("places-dirty")
        let path = tmp.appending("pl.json").path
        let pl = try PlacesOps.create(path)
        let a = try makePlace("A", 10, 10)
        let b = try makePlace("B", 20, 20)
        var changed = 0
        pl.onChanged = { changed += 1 }
        #expect(!pl.isDirty)
        #expect(!pl.add(nil))
        #expect(!pl.isDirty)
        #expect(pl.add(a))
        #expect(pl.isDirty)
        #expect(throws: Never.self) { try pl.save() }
        #expect(!pl.isDirty)
        #expect(!pl.add(a)) // a rejected edit is not an edit
        #expect(!pl.isDirty)
        #expect(pl.add(b))
        #expect(throws: Never.self) { try pl.save() }
        #expect(pl.move(from: 0, to: 1))
        #expect(pl.isDirty)
        #expect(throws: Never.self) { try pl.save() }
        #expect(pl.remove(key: "10.0000,10.0000"))
        #expect(pl.isDirty)
        #expect(changed == 4)
        // Saving does not announce anything.
        #expect(throws: Never.self) { try pl.save() }
        #expect(changed == 4) // test-storage.c:2247
        // A successful or failed load leaves the list clean.
        let w2 = try PlacesOps.create(path)
        #expect(throws: Never.self) { try w2.load() }
        #expect(!w2.isDirty)
        let w3 = try PlacesOps.create(tmp.appending("missing.json").path)
        #expect(w3.add(a))
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try w3.load() } != nil)
        #expect(!w3.isDirty)
        #expect(w3.count == 0)
    }

    // C: /places/load-failure-effects (test_places_load_failure_effects, test-storage.c:4316-4354)
    @Test func placesLoadFailureEffects() async throws {
        let tmp = try TemporaryDirectory("places-failure")
        let pl = try PlacesOps.create(tmp.appending("missing.json").path)
        let a = try makePlace("A", 10, 10)
        #expect(pl.add(a))
        var changed = 0
        pl.onChanged = { changed += 1 }
        // A failing load empties the list, announces that once and reports nothing dropped
        // (it throws, so there is no count).
        let e = StoreJSONTests.caught { () throws(WxStoreError) in try pl.load() }
        #expect(e?.isNotFound == true)
        #expect(changed == 1)
        #expect(pl.count == 0)
        #expect(!pl.isDirty)
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try pl.load() } != nil)
        #expect(changed == 1) // empty -> empty: no signal

        // While a save runs the load is refused and changes nothing.
        let p2 = try PlacesOps.create(tmp.appending("pl2.json").path)
        #expect(p2.add(a))
        let job = try p2.beginSave()
        #expect(StoreJSONTests.isPending(StoreJSONTests.caught { () throws(WxStoreError) in try p2.load() }))
        #expect(p2.count == 1)
        let outcome = await job.perform()
        #expect(StoreJSONTests.caught { () throws(WxStoreError) in try p2.finishSave(job, outcome) } == nil)
    }

    // MARK: - File format (executor golden, derived by hand from the C writer)

    // FORMAT: serialize_entries (src/storage/wx-places.c:490-495), wx_store_append_place
    // (src/storage/wx-store-json.c:185-199), wx_json_append_string (src/storage/wx-fileio.c:404-416:
    // '"' and '\' escaped) and wx_json_append_double (src/storage/wx-fileio.c:425-440: NaN/inf ->
    // null, -0 -> "-0.0", else the shortest of %.15g/%.16g/%.17g that reads back: 47.3769 and
    // -100 at 15 digits, 1/3 needs 16, 0.1 + 0.2 needs 17).
    @Test func placesFileGolden() throws {
        let tmp = try TemporaryDirectory("places-golden")
        let path = tmp.appending("places.json").path
        let pl = try PlacesOps.create(path)
        #expect(throws: Never.self) { try pl.save() }
        #expect(try StoreJSONTests.readAll(path) == "{\n  \"version\": 1,\n  \"places\": []\n}\n")

        #expect(pl.add(try WxPlace(
            name: "Zürich", admin1: "Kanton Zürich", country: "Schweiz", countryCode: "CH",
            lat: 47.3769, lon: 8.5417, timezone: "Europe/Zurich")))
        #expect(pl.add(try WxPlace(name: "quote \" back \\", lat: -0.0, lon: -100.0)))
        #expect(pl.add(try WxPlace(name: "Thirds", lat: 0.1 + 0.2, lon: 1.0 / 3.0)))
        #expect(pl.add(try WxPlace(name: "Tiny", lat: 1e-300, lon: 180.0)))
        #expect(throws: Never.self) { try pl.save() }
        let want = "{\n  \"version\": 1,\n  \"places\": [\n"
            + "    {\"name\": \"Zürich\", \"admin1\": \"Kanton Zürich\", \"country\": \"Schweiz\", \"country_code\": \"CH\", \"lat\": 47.3769, \"lon\": 8.5417, \"timezone\": \"Europe/Zurich\"},\n"
            + "    {\"name\": \"quote \\\" back \\\\\", \"admin1\": \"\", \"country\": \"\", \"country_code\": \"\", \"lat\": -0.0, \"lon\": -100, \"timezone\": \"\"},\n"
            + "    {\"name\": \"Thirds\", \"admin1\": \"\", \"country\": \"\", \"country_code\": \"\", \"lat\": 0.30000000000000004, \"lon\": 0.3333333333333333, \"timezone\": \"\"},\n"
            + "    {\"name\": \"Tiny\", \"admin1\": \"\", \"country\": \"\", \"country_code\": \"\", \"lat\": 1e-300, \"lon\": 180, \"timezone\": \"\"}\n"
            + "  ]\n}\n"
        #expect(try StoreJSONTests.readAll(path) == want)

        // And it reads back bit-identically, -0.0 included.
        let back = try PlacesOps.create(path)
        #expect(throws: Never.self) { try back.load() }
        #expect(placesFingerprint(back) == placesFingerprint(pl))
    }
}
