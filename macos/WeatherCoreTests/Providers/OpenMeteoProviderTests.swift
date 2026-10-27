// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// OpenMeteoProviderTests.swift - the provider/ and net/ groups of
// src/providers/openmeteo/test-openmeteo.c (registrations :4941-4971) against
// the loopback fake of OpenMeteoProviderFake.swift. Expected values are the C
// test literals, cited as test-openmeteo.c:LINE (and wx-openmeteo.h:LINE for
// the header's own pinned numbers). Timings are real (SystemClock), with the C
// tolerances; the suite is serialized.

import Foundation
import Testing
@testable import WeatherCore

@Suite(.serialized, .timeLimit(.minutes(5)))
struct OpenMeteoProviderTests {
    typealias Fake = OpenMeteoProviderFake

    /// The member ids of a CONUS fetch without / with the nowcast (test-openmeteo.c:2529, :2809).
    static let conusIDs = ["hrrr", "nbm", "gfs", "ecmwf", "icon", "gem"]
    static let conusWithNowcast = ["hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", "hrrr15"]
    /// london_ids (test-openmeteo.c:170).
    static let londonIDs = ["ecmwf", "icon", "gem", "gfs", "ukmo", "meteofrance"]
    /// The model lists of test_net_model_selection (test-openmeteo.c:2577-2580).
    static let conusModels = "ncep_hrrr_conus,ncep_nbm_conus,gfs_seamless,ecmwf_ifs,icon_seamless,gem_seamless"
    static let usOtherModels = "gfs_seamless,ecmwf_ifs,icon_seamless,gem_seamless"
    static let worldModels = "ecmwf_ifs,icon_seamless,gem_seamless,gfs_seamless"
    static let europeModels =
        "ecmwf_ifs,icon_seamless,gem_seamless,gfs_seamless,ukmo_seamless,meteofrance_seamless"

    /// expect_path_a (test-openmeteo.c:2487-2496).
    static func expectPathA(_ lat: String, _ lon: String, _ models: String) -> String {
        "/v1/forecast?latitude=\(lat)&longitude=\(lon)&hourly=temperature_2m,apparent_temperature,"
            + "relative_humidity_2m,precipitation,precipitation_probability,cloud_cover,wind_speed_10m,"
            + "wind_gusts_10m,weather_code&models=\(models)&timeformat=unixtime&timezone=GMT&forecast_days=10"
            + "&wind_speed_unit=kmh&temperature_unit=celsius&precipitation_unit=mm"
    }

    /// expect_path_b (test-openmeteo.c:2498-2505).
    static func expectPathB(_ lat: String, _ lon: String) -> String {
        "/v1/forecast?latitude=\(lat)&longitude=\(lon)&minutely_15=precipitation&models=ncep_hrrr_conus"
            + "&forecast_minutely_15=12&timeformat=unixtime&timezone=GMT&precipitation_unit=mm"
    }

    static func miami() throws -> WxPlace { try Fake.place("Miami", 25.7617, -80.1918) }
    static func london() throws -> WxPlace { try Fake.place("London", 51.5072, -0.1276) }

    static func ms(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    /// Polls `condition` every millisecond for at most `timeoutMs`.
    static func waitFor(timeoutMs: Int = 5000, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    // MARK: - provider/

    // C: /openmeteo/provider/metadata (test-openmeteo.c:2338-2367)
    @Test("/openmeteo/provider/metadata")
    func providerMetadata() throws {
        let om = try OpenMeteoProvider()
        #expect(om.id == "open-meteo")                                             // test-openmeteo.c:2344
        #expect(om.id == OpenMeteoShared.providerID)                               // test-openmeteo.c:2345
        #expect(om.name == "Open-Meteo")                                           // test-openmeteo.c:2346
        #expect(om.attribution == "Weather data by Open-Meteo.com")                // test-openmeteo.c:2347
        #expect(om.attributionURL == "https://open-meteo.com/")                    // test-openmeteo.c:2348
        #expect(WxLimits.isValidID(om.id))                                         // test-openmeteo.c:2349
        #expect(!om.id.contains("."))                                              // test-openmeteo.c:2350
        #expect(OpenMeteoShared.baseURL == "https://api.open-meteo.com")           // test-openmeteo.c:2351
        #expect(OpenMeteoShared.geocodingBaseURL == "https://geocoding-api.open-meteo.com") // test-openmeteo.c:2352
        #expect(OpenMeteoShared.nowcastGraceMs == 2000)                            // test-openmeteo.c:2353
        #expect(OpenMeteoShared.searchMinBytes == 2)                               // test-openmeteo.c:2354
        #expect(OpenMeteoShared.searchMaxBytes == 64)                              // test-openmeteo.c:2355
        // The production client is built from the FIXED https origin with the default timing and the
        // project User-Agent (wx-openmeteo.h:201-207; wx_open_meteo_new, wx-openmeteo.c:1410-1414).
        #expect(om.http.policy.origin == "https://api.open-meteo.com")
        #expect(om.http.policy.userAgent == Fake.ua)                               // test-openmeteo.c:1873
        #expect(om.http.policy.timeoutMs == HTTPPolicy.timeoutMs)
        #expect(om.http.policy.backoffBaseMs == HTTPPolicy.backoffBaseMs)
        #expect(om.http.policy.minGapMs == 0)
        // the constants are accepted by the engine (https hosts) (test-openmeteo.c:2356-2360)
        let again = try OpenMeteoProvider(customBaseURL: OpenMeteoShared.baseURL, timeoutMs: 1000, backoffBaseMs: 0)
        #expect(again.http.policy.origin == "https://api.open-meteo.com")
        let geo: any WxGeocoder = try OpenMeteoGeocoder()                         // test-openmeteo.c:2361-2363
        let geocoder = try #require(geo as? OpenMeteoGeocoder)
        #expect(geocoder.http.policy.origin == "https://geocoding-api.open-meteo.com")
        #expect(geocoder.http.policy.userAgent == Fake.ua)
        #expect(geocoder.http.policy.timeoutMs == HTTPPolicy.timeoutMs)
        #expect(geocoder.http.policy.backoffBaseMs == HTTPPolicy.backoffBaseMs)
        let geo2 = try OpenMeteoGeocoder(
            customBaseURL: OpenMeteoShared.geocodingBaseURL, timeoutMs: 1000, backoffBaseMs: 0) // :2364-2366
        #expect(geo2.http.policy.origin == "https://geocoding-api.open-meteo.com")
    }

    // C: /openmeteo/provider/covers (test-openmeteo.c:2369-2390). The hand-built invalid places
    // (lat 91, NaN, lon infinity; NULL place) cannot exist in Swift: WxPlace refuses them.
    @Test("/openmeteo/provider/covers")
    func providerCovers() throws {
        let om = try OpenMeteoProvider()
        let places: [(Double, Double)] = [
            (25.7617, -80.1918), (51.5, -0.12), (-33.87, 151.2), (90, 180), (-90, -180), (0, 0), (64.1, -21.9),
        ]  // test-openmeteo.c:2375
        for (lat, lon) in places {
            #expect(om.covers(try Fake.place("P", lat, lon)), "\(lat), \(lon)")
        }
        for (lat, lon) in [(91.0, 0.0), (Double.nan, 0.0), (0.0, Double.infinity)] {  // test-openmeteo.c:2382-2388
            #expect(throws: WxError(.invalidArg, "coordinates out of range")) { try Fake.place("P", lat, lon) }
        }
    }

    // C: /openmeteo/provider/registry (test-openmeteo.c:2392-2411)
    @Test("/openmeteo/provider/registry")
    @MainActor
    func providerRegistry() throws {
        let reg = WxRegistry()
        let om = try OpenMeteoProvider()
        let geo = try OpenMeteoGeocoder()
        try reg.addProvider(om)
        reg.geocoder = geo
        #expect(reg.findProvider(id: "open-meteo") === om)
        #expect(reg.geocoder === geo)
        #expect(reg.listCovering(try Self.miami()).count == 1)
        // A second Open-Meteo provider is a duplicate id.
        let other = try OpenMeteoProvider()
        #expect(throws: WxError.self) { try reg.addProvider(other) }
        do {
            try reg.addProvider(other)
        } catch {
            #expect(error.code == .invalidArg)
        }
    }

    // C: /openmeteo/provider/constructors (test-openmeteo.c:2413-2459). The C criticals for an
    // out-of-range timing argument are WxError .invalidArg "invalid timing argument" (U13 mapping).
    @Test("/openmeteo/provider/constructors")
    func providerConstructors() throws {
        let badURLs = [
            "http://example.com", "ftp://127.0.0.1", "https://user:pw@example.com", "https://example.com?x=1",
            "https://example.com/v1", "", "not a url",
        ]  // test-openmeteo.c:2416-2424
        let unacceptable = WxError(.invalidArg, "unacceptable base URL")         // test-openmeteo.c:2429, :2433
        for url in badURLs {
            #expect(throws: unacceptable, "\(url)") {
                try OpenMeteoProvider(customBaseURL: url, timeoutMs: 1000, backoffBaseMs: 10)
            }
            #expect(throws: unacceptable, "\(url)") {
                try OpenMeteoGeocoder(customBaseURL: url, timeoutMs: 1000, backoffBaseMs: 10)
            }
        }
        let timing = WxError(.invalidArg, HTTPPolicy.Message.invalidTiming)
        for (timeout, backoff) in [(0, 10), (600_001, 10), (1000, 600_001)] {     // test-openmeteo.c:2438-2443
            #expect(throws: timing) {
                try OpenMeteoProvider(customBaseURL: "https://a.example", timeoutMs: timeout, backoffBaseMs: backoff)
            }
        }
        for (timeout, backoff) in [(0, 10), (1000, 600_001)] {                    // test-openmeteo.c:2446-2449
            #expect(throws: timing) {
                try OpenMeteoGeocoder(customBaseURL: "https://a.example", timeoutMs: timeout, backoffBaseMs: backoff)
            }
        }
        // the limits themselves are fine (test-openmeteo.c:2451-2458)
        _ = try OpenMeteoProvider(customBaseURL: "https://a.example", timeoutMs: 1, backoffBaseMs: 0)
        _ = try OpenMeteoProvider(customBaseURL: "https://a.example", timeoutMs: 600_000, backoffBaseMs: 600_000)
        _ = try OpenMeteoGeocoder(customBaseURL: "https://a.example", timeoutMs: 1, backoffBaseMs: 0)
        _ = try OpenMeteoGeocoder(customBaseURL: "https://a.example", timeoutMs: 600_000, backoffBaseMs: 600_000)
    }

    // MARK: - net/: requests

    // C: /openmeteo/net/miami-success (test-openmeteo.c:2507-2551)
    @Test("/openmeteo/net/miami-success")
    func netMiamiSuccess() async throws {
        var script = try Fake.Script.ok()
        script.a = Fake.Reply(.reply, 200, try Fixtures.string("forecast_miami_multi.json"), gzip: true)
        script.b.gzip = true  // the real API serves gzip
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let before = SystemClock().wallSeconds
        let op = await Fake.fetch(om, try Self.miami())
        let after = SystemClock().wallSeconds
        let result = try op.outcome.get()
        #expect(result.providerID == "open-meteo")                                 // test-openmeteo.c:2525
        #expect(Fake.memberIDs(result) == Self.conusWithNowcast)                   // test-openmeteo.c:2527
        for member in result.members {                                            // test-openmeteo.c:2531-2535
            #expect(member.fetchedS >= before && member.fetchedS <= after)  // test-openmeteo.c:2530
        }
        try #require(result.members.count == 7)
        #expect(result.members[2].hours.count == 241)                              // test-openmeteo.c:2535
        #expect(result.members[6].hours.isEmpty)                                   // test-openmeteo.c:2537
        #expect(result.members[6].quarters.count == 12)                            // test-openmeteo.c:2539
        let q0: Int64? = result.members[6].quarters.first?.tS
        let q0Expected: Int64 = 1_791_832_500 - 900
        #expect(q0 == q0Expected, "\(String(describing: q0))")                    // test-openmeteo.c:2540
        #expect(fake.requestCount == 2)                                            // test-openmeteo.c:2541
        let a = Self.expectPathA("25.7617", "-80.1918", Self.conusModels)
        let b = Self.expectPathB("25.7617", "-80.1918")
        #expect(fake.path(with: nil) == a)                                         // test-openmeteo.c:2545
        #expect(fake.path(with: "minutely_15") == b)                               // test-openmeteo.c:2546
        #expect(HTTPPolicy.isValidPath(a))  // test-openmeteo.c:2547
        #expect(HTTPPolicy.isValidPath(b))  // test-openmeteo.c:2548
    }

    // C: /openmeteo/net/london-success (test-openmeteo.c:2553-2572)
    @Test("/openmeteo/net/london-success")
    func netLondonSuccess() async throws {
        var script = try Fake.Script.ok()
        script.a.body = try Fixtures.string("forecast_london_multi.json")
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.london())
        #expect(Fake.memberIDs(op.value) == Self.londonIDs, "\(op.outcome)")       // test-openmeteo.c:2565
        #expect(fake.requestCount == 1)  // no request B outside the CONUS branch (test-openmeteo.c:2566)
        #expect(fake.paths.first == Self.expectPathA("51.5072", "-0.1276", Self.europeModels)) // :2569
    }

    // C: /openmeteo/net/model-selection (test-openmeteo.c:2574-2650)
    @Test("/openmeteo/net/model-selection")
    func netModelSelection() async throws {
        let cases: [(String, Double, Double, String, String, String, Bool)] = [
            ("Miami", 25.7617, -80.1918, "25.7617", "-80.1918", Self.conusModels, true),
            ("New York", 40.7128, -74.006, "40.7128", "-74.0060", Self.conusModels, true),
            ("Seattle", 47.6062, -122.3321, "47.6062", "-122.3321", Self.conusModels, true),
            ("Toronto", 43.6532, -79.3832, "43.6532", "-79.3832", Self.conusModels, true),
            ("Honolulu", 21.3069, -157.8583, "21.3069", "-157.8583", Self.usOtherModels, false),
            ("Anchorage", 61.2181, -149.9003, "61.2181", "-149.9003", Self.usOtherModels, false),
            ("San Juan", 18.4655, -66.1057, "18.4655", "-66.1057", Self.usOtherModels, false),
            ("Guam", 13.4443, 144.7937, "13.4443", "144.7937", Self.usOtherModels, false),
            ("Calgary", 51.0447, -114.0719, "51.0447", "-114.0719", Self.worldModels, false),
            ("Mexico City", 19.4326, -99.1332, "19.4326", "-99.1332", Self.worldModels, false),
            ("Sydney", -33.8688, 151.2093, "-33.8688", "151.2093", Self.worldModels, false),
            ("Tokyo", 35.6762, 139.6503, "35.6762", "139.6503", Self.worldModels, false),
            ("Moscow", 55.7558, 37.6173, "55.7558", "37.6173", Self.europeModels, false),
            ("London", 51.5072, -0.1276, "51.5072", "-0.1276", Self.europeModels, false),
            ("Reykjavik", 64.1466, -21.9426, "64.1466", "-21.9426", Self.europeModels, false),
            ("Origin", 0, 0, "0.0000", "0.0000", Self.worldModels, false),
            ("Neg zero", -0.00001, -0.00001, "0.0000", "0.0000", Self.worldModels, false),
            ("Rounding up", 25.76176, -80.19184, "25.7618", "-80.1918", Self.conusModels, true),
            ("Rounding down", 25.76174, -80.19186, "25.7617", "-80.1919", Self.conusModels, true),
            ("Pole", 90, 180, "90.0000", "180.0000", Self.worldModels, false),
            ("Antarctica", -90, -180, "-90.0000", "-180.0000", Self.worldModels, false),
        ]  // test-openmeteo.c:2586-2608
        let allow = [
            "ncep_hrrr_conus", "ncep_nbm_conus", "gfs_seamless", "ecmwf_ifs025", "ecmwf_ifs", "icon_seamless",
            "gem_seamless",
            "ukmo_seamless", "meteofrance_seamless", "knmi_seamless",
        ]  // test-openmeteo.c:2609-2610
        for (name, lat, lon, latText, lonText, models, nowcast) in cases {
            let fake = try Fake.Server(try Fake.Script.ok())
            defer { fake.stop() }
            let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
            let op = await Fake.fetch(om, try Fake.place(name, lat, lon))
            let result = try #require(op.value, "\(name): \(op.outcome)")
            let a = Self.expectPathA(latText, lonText, models)
            #expect(fake.path(with: nil) == a, "\(name)")                         // test-openmeteo.c:2625
            #expect(fake.requestCount == (nowcast ? 2 : 1), "\(name)")            // test-openmeteo.c:2627
            if nowcast {
                #expect(fake.path(with: "minutely_15") == Self.expectPathB(latText, lonText), "\(name)") // :2630
            }
            // every requested model is on the allow-list, once; the synthetic body has data for each
            let names = models.split(separator: ",").map(String.init)
            #expect(names.count == result.members.count - (nowcast ? 1 : 0), "\(name)") // test-openmeteo.c:2636
            for (k, model) in names.enumerated() {
                #expect(allow.contains(model), "\(name): \(model)")               // test-openmeteo.c:2641
                #expect(result.members[k].hours.count == 5, "\(name): \(model)")  // test-openmeteo.c:2645
            }
        }
    }

    // C: /openmeteo/net/locale-independent (test-openmeteo.c:2652-2685). Swift tests never change the
    // process locale (brief); the premise is checked on a de_DE formatter, and the run_suite
    // RUN_SUITE_LOCALE=de_DE run executes this test under a comma-decimal test region.
    @Test("/openmeteo/net/locale-independent")
    func netLocaleIndependent() async throws {
        let probe = String(format: "%f", locale: Locale(identifier: "de_DE"), 1.5)
        #expect(probe.contains(","))  // the premise: a localized printf writes a decimal comma (:2667)
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.miami())
        #expect(op.value != nil, "\(op.outcome)")
        #expect(fake.path(with: "minutely_15") == Self.expectPathB("25.7617", "-80.1918")) // test-openmeteo.c:2677
        let pathA = try #require(fake.path(with: nil))
        #expect(pathA.contains("latitude=25.7617&longitude=-80.1918&"))            // test-openmeteo.c:2681
    }

    // C: /openmeteo/net/request-shape (test-openmeteo.c:2687-2719)
    @Test("/openmeteo/net/request-shape")
    func netRequestShape() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.miami())
        #expect(op.value != nil, "\(op.outcome)")
        let heads = fake.heads
        let paths = fake.paths
        #expect(heads.count == 2)                                                  // test-openmeteo.c:2698
        for (head, path) in zip(heads, paths) {
            let lower = head.lowercased()
            #expect(head.hasPrefix("GET \(path) HTTP/1.1\r\n"))                    // test-openmeteo.c:2704
            #expect(head.contains("\r\nUser-Agent: \(Fake.ua)\r\n"))               // test-openmeteo.c:2705
            #expect(lower.contains("\r\naccept: application/json\r\n"))            // test-openmeteo.c:2706
            for forbidden in ["cookie", "authorization", "referer", "mozilla", "if-modified-since", "api-key", "apikey"] {
                #expect(!lower.contains(forbidden), "\(forbidden)")                // test-openmeteo.c:2707-2713
            }
            #expect(lower.contains("\r\nhost: 127.0.0.1:\(fake.server.port)\r\n")) // test-openmeteo.c:2714-2715
        }
    }

    // MARK: - net/: request B tolerated, request A fatal

    // C: /openmeteo/net/b-failure-tolerated (test-openmeteo.c:2725-2769)
    @Test("/openmeteo/net/b-failure-tolerated")
    func netBFailureTolerated() async throws {
        let garbage = "this is not json"
        let apiError = #"{"error":true,"reason":"Too many requests"}"#
        let noQuarters = #"{"minutely_15":{"time":[],"precipitation":[]}}"#
        let allNull = #"{"minutely_15":{"time":[1791832500],"precipitation":[null]}}"#
        let cases: [(Fake.Reply, Int)] = [
            (Fake.Reply(.reply, 404, "{}"), 2),
            (Fake.Reply(.reply, 400, #"{"error":true,"reason":"x"}"#), 2),
            (Fake.Reply(.reply, 429, "{}"), 2),
            (Fake.Reply(.reply, 500, "{}"), 4),  // WxHttp retries 5xx twice
            (Fake.Reply(.reply, 200, garbage), 2),
            (Fake.Reply(.reply, 200, "{}"), 2),
            (Fake.Reply(.reply, 200, apiError), 2),
            (Fake.Reply(.reply, 200, noQuarters), 2),
            (Fake.Reply(.reply, 200, allNull), 2),
            (Fake.Reply(.reply, 204, ""), 2),
            (Fake.Reply(.close), 4),
            (Fake.Reply(.cut, 200, #"{"minutely_15":{}}"#), 4),
        ]  // test-openmeteo.c:2735-2748
        for (i, (reply, expectRequests)) in cases.enumerated() {
            var script = try Fake.Script.ok()
            script.b = reply
            let fake = try Fake.Server(script)
            defer { fake.stop() }
            let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 5)
            let op = await Fake.fetch(om, try Self.miami())
            #expect(op.value != nil, "case \(i): \(op.outcome)")                   // test-openmeteo.c:2759
            #expect(Fake.memberIDs(op.value) == Self.conusIDs, "case \(i)")        // test-openmeteo.c:2762
            try await Task.sleep(for: .milliseconds(150))  // let B's retries finish (test-openmeteo.c:2763)
            #expect(fake.requestCount == expectRequests, "case \(i)")              // test-openmeteo.c:2764
        }
    }

    // C: /openmeteo/net/b-hang-grace (test-openmeteo.c:2771-2791)
    @Test("/openmeteo/net/b-hang-grace")
    func netBHangGrace() async throws {
        var script = try Fake.Script.ok()
        script.b = Fake.Reply(.hang)
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.miami())
        #expect(Fake.memberIDs(op.value) == Self.conusIDs, "\(op.outcome)")        // test-openmeteo.c:2784
        // A answered at once: the result came when the window for B ran out, not at the 10 s timeout.
        #expect(op.elapsedMs >= Int64(OpenMeteoShared.nowcastGraceMs - 200), "\(op.elapsedMs)") // :2786
        #expect(op.elapsedMs < Int64(OpenMeteoShared.nowcastGraceMs + 4000), "\(op.elapsedMs)") // :2787
        #expect(fake.requestCount == 2)                                            // test-openmeteo.c:2788
    }

    // C: /openmeteo/net/b-within-grace (test-openmeteo.c:2793-2814)
    @Test("/openmeteo/net/b-within-grace")
    func netBWithinGrace() async throws {
        for k in 0..<2 {
            var script = try Fake.Script.ok()
            if k == 0 {
                script.b.delayMs = 400  // B after A (test-openmeteo.c:2799)
            } else {
                script.a.delayMs = 400  // A after B (test-openmeteo.c:2801)
            }
            let fake = try Fake.Server(script)
            defer { fake.stop() }
            let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
            let op = await Fake.fetch(om, try Self.miami())
            #expect(Fake.memberIDs(op.value) == Self.conusWithNowcast, "k=\(k): \(op.outcome)") // :2810
            #expect(op.elapsedMs < Int64(OpenMeteoShared.nowcastGraceMs), "k=\(k): \(op.elapsedMs)") // :2811
        }
    }

    // C: /openmeteo/net/b-window-from-start (test-openmeteo.c:2816-2875)
    @Test("/openmeteo/net/b-window-from-start")
    func netBWindowFromStart() async throws {
        struct Case {
            let name: String
            let aDelayMs: Int, aFirstFail: Int, backoffMs: Int
            let bKind: Fake.Reply.Kind
            let bDelayMs: Int
            let expectNowcast: Bool
            let expectAAttempts: Int
            let minTotalMs: Int64
        }
        let cases = [
            Case(name: "a-late-delayed-b-hang", aDelayMs: 2500, aFirstFail: 0, backoffMs: 10, bKind: .hang,
                 bDelayMs: 0, expectNowcast: false, expectAAttempts: 1, minTotalMs: 2400),
            Case(name: "a-late-503-retries-b-hang", aDelayMs: 0, aFirstFail: 2, backoffMs: 700, bKind: .hang,
                 bDelayMs: 0, expectNowcast: false, expectAAttempts: 3, minTotalMs: 2000),
            Case(name: "a-late-b-answers-after-window", aDelayMs: 2300, aFirstFail: 0, backoffMs: 10, bKind: .reply,
                 bDelayMs: 2600, expectNowcast: false, expectAAttempts: 1, minTotalMs: 2300),
            Case(name: "a-late-b-answered-early", aDelayMs: 2300, aFirstFail: 0, backoffMs: 10, bKind: .reply,
                 bDelayMs: 0, expectNowcast: true, expectAAttempts: 1, minTotalMs: 2300),
            Case(name: "a-1500-b-1800", aDelayMs: 1500, aFirstFail: 0, backoffMs: 10, bKind: .reply,
                 bDelayMs: 1800, expectNowcast: true, expectAAttempts: 1, minTotalMs: 1700),
            Case(name: "a-1000-b-hang", aDelayMs: 1000, aFirstFail: 0, backoffMs: 10, bKind: .hang,
                 bDelayMs: 0, expectNowcast: false, expectAAttempts: 1, minTotalMs: 1900),
        ]  // test-openmeteo.c:2832-2839
        for c in cases {
            var script = try Fake.Script.ok()
            script.a.delayMs = c.aDelayMs
            script.aFirstFail = c.aFirstFail
            script.b.kind = c.bKind
            script.b.delayMs = c.bDelayMs
            let fake = try Fake.Server(script)
            defer { fake.stop() }
            let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: c.backoffMs)
            let op = await Fake.fetch(om, try Self.miami())
            #expect(op.value != nil, "\(c.name): \(op.outcome)")                   // test-openmeteo.c:2853
            #expect(
                Fake.memberIDs(op.value) == (c.expectNowcast ? Self.conusWithNowcast : Self.conusIDs), "\(c.name)") // :2857
            #expect(fake.aSeen == c.expectAAttempts, "\(c.name): \(fake.aSeen) attempts of A") // :2858
            let aAnswer = try #require(fake.aAnswer, "\(c.name)")
            #expect(aAnswer > op.start, "\(c.name)")                               // test-openmeteo.c:2860
            let windowEnd = op.start + .milliseconds(OpenMeteoShared.nowcastGraceMs)
            let due = max(aAnswer, windowEnd)                                      // test-openmeteo.c:2862
            #expect(op.elapsedMs >= c.minTotalMs, "\(c.name): \(op.elapsedMs) ms")  // test-openmeteo.c:2863
            #expect(op.end <= due + .milliseconds(700), "\(c.name): \(Self.ms(op.end - due)) ms after due") // :2866
            if c.bKind == .hang {
                #expect(op.end >= due - .milliseconds(50), "\(c.name): \(Self.ms(due - op.end)) ms early") // :2869
            }
        }
    }

    // C: /openmeteo/net/slot-lifetime-refill (test-openmeteo.c:2972-2989), a PINNED DIFFERENCE: C
    // counts A's slot while the completion callback runs and B's slot for several dispatches after
    // the window (15 results + 1 RATE_LIMITED, wx-openmeteo.h:133-147); in Swift every slot is free
    // when fetch returns, which is C's "after the callback returned they give 16 results"
    // (wx-openmeteo.h:139-140, test-openmeteo.c:2981).
    @Test("/openmeteo/net/slot-lifetime-refill (pinned difference: 16 results)")
    func netSlotLifetimeRefill() async throws {
        for (lat, lon, bHangs) in [(51.5072, -0.1276, false), (25.7617, -80.1918, true)] {
            var script = try Fake.Script.ok()
            if bHangs {
                script.b = Fake.Reply(.hang)
            }
            let fake = try Fake.Server(script)
            defer { fake.stop() }
            let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: 10)
            let first = await Fake.fetch(om, try Fake.place("First", lat, lon))
            #expect(first.value != nil, "\(first.outcome)")
            #expect(om.http.outstandingCount == 0)
            let london = try Self.london()
            let outcomes = await withTaskGroup(of: Fake.Op<WxSourceResult>.self) { group in
                for _ in 0..<16 {
                    group.addTask { await Fake.fetch(om, london) }
                }
                var out: [Fake.Op<WxSourceResult>] = []
                for await op in group { out.append(op) }
                return out
            }
            #expect(outcomes.filter { $0.value != nil }.count == 16, "b hangs: \(bHangs)")
            #expect(outcomes.filter { $0.wxError?.code == .rateLimited }.count == 0)
        }
    }

    // C: /openmeteo/net/a-failure (test-openmeteo.c:2991-3043)
    @Test("/openmeteo/net/a-failure")
    func netAFailure() async throws {
        let noModels = #"{"hourly":{"time":[1791763200],"temperature_2m_gfs_seamless":[null]}}"#
        let wrongKeys = #"{"hourly":{"time":[1791763200],"temperature_2m":[5]}}"#
        let cases: [(String, Fake.Reply, WxError.Code, Int)] = [
            ("404", Fake.Reply(.reply, 404, "{}"), .notFound, 2),
            ("429", Fake.Reply(.reply, 429, "{}"), .rateLimited, 2),
            ("400", Fake.Reply(.reply, 400, #"{"error":true,"reason":"bad"}"#), .http, 2),
            ("403", Fake.Reply(.reply, 403, "{}"), .http, 2),
            ("301", Fake.Reply(.reply, 301, "{}"), .http, 2),
            ("500", Fake.Reply(.reply, 500, "{}"), .http, 4),
            ("503", Fake.Reply(.reply, 503, "{}"), .http, 4),
            ("garbage", Fake.Reply(.reply, 200, "<html>nope</html>"), .parse, 2),
            ("empty object", Fake.Reply(.reply, 200, "{}"), .parse, 2),
            ("empty body", Fake.Reply(.reply, 200, ""), .parse, 2),
            ("no content", Fake.Reply(.reply, 204, ""), .parse, 2),
            ("array root", Fake.Reply(.reply, 200, "[]"), .parse, 2),
            ("error body 200", Fake.Reply(.reply, 200, #"{"error":true,"reason":"Cannot initialize"}"#), .http, 2),
            ("no model data", Fake.Reply(.reply, 200, noModels), .notFound, 2),
            ("unsuffixed keys", Fake.Reply(.reply, 200, wrongKeys), .notFound, 2),
            ("closed", Fake.Reply(.close), .network, 4),
            ("truncated", Fake.Reply(.cut, 200, #"{"hourly":"#), .network, 4),
            ("hang", Fake.Reply(.hang), .timeout, 0),
        ]  // test-openmeteo.c:2996-3015
        for (name, reply, code, expectRequests) in cases {
            for region in 0..<2 {
                var script = try Fake.Script.ok()  // request B is healthy: it cannot rescue a failed A
                script.a = reply
                let fake = try Fake.Server(script)
                defer { fake.stop() }
                let om = try Fake.provider(fake, timeoutMs: 250, backoffMs: 5)
                let place = region == 0 ? try Self.miami() : try Self.london()
                let op = await Fake.fetch(om, place)
                #expect(op.wxError?.code == code, "case \(name) region \(region): \(op.outcome)") // :3028
                if name == "error body 200" {
                    #expect(op.wxError?.message == "Open-Meteo reported an error: Cannot initialize") // :3032
                }
                if name == "no model data" {
                    #expect(op.wxError?.message == "no usable forecast data")       // test-openmeteo.c:3034
                }
                if expectRequests > 0 && region == 1 {
                    try await Task.sleep(for: .milliseconds(100))
                    #expect(fake.requestCount == expectRequests - 1, "case \(name)")  // test-openmeteo.c:3037
                }
            }
        }
    }

    // C: /openmeteo/net/a-failure-no-wait-for-b (test-openmeteo.c:3045-3062)
    @Test("/openmeteo/net/a-failure-no-wait-for-b")
    func netAFailureNoWaitForB() async throws {
        var script = try Fake.Script.ok()
        script.a = Fake.Reply(.reply, 404, "{}")
        script.b = Fake.Reply(.hang)
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.miami())
        #expect(op.wxError?.code == .notFound, "\(op.outcome)")                   // test-openmeteo.c:3057
        #expect(op.elapsedMs < 1500, "\(op.elapsedMs)")                            // test-openmeteo.c:3059
    }

    // C: /openmeteo/net/b-alone-not-enough (test-openmeteo.c:3064-3080)
    @Test("/openmeteo/net/b-alone-not-enough")
    func netBAloneNotEnough() async throws {
        var script = try Fake.Script.ok()
        script.a = Fake.Reply(.reply, 200, #"{"hourly":{"time":[]}}"#)
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let op = await Fake.fetch(om, try Self.miami())
        #expect(op.wxError?.code == .notFound, "\(op.outcome)")                   // test-openmeteo.c:3076
    }

    // MARK: - net/: invalid places, cancellation, lifecycle

    // C: /openmeteo/net/invalid-places (test-openmeteo.c:3085-3115). C answers INVALID_ARG "invalid
    // place" without traffic; in Swift none of these places can be constructed (WxPlace validates),
    // so no fetch of them can start and the fake sees no request.
    @Test("/openmeteo/net/invalid-places (such places cannot be constructed)")
    func netInvalidPlaces() throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        _ = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        // (name, countryCode, timezone, lat, lon) of test-openmeteo.c:3091-3102
        let cases: [(String?, String, String, Double, Double)] = [
            ("P", "", "", 91, 0), ("P", "", "", -91, 0), ("P", "", "", 0, 181), ("P", "", "", .nan, 0),
            ("P", "", "", 0, .infinity), (nil, "", "", 1, 1), ("", "", "", 1, 1), ("P", "us", "", 1, 1),
            ("P", "", "/etc/passwd", 1, 1), ("P\n", "", "", 1, 1),
        ]
        for (i, (name, countryCode, timezone, lat, lon)) in cases.enumerated() {
            do {
                _ = try WxPlace(
                    name: name, admin1: "", country: "", countryCode: countryCode, lat: lat, lon: lon, timezone: timezone)
                Issue.record("case \(i): the place was accepted")
            } catch {
                #expect(error.code == .invalidArg, "case \(i)")                    // test-openmeteo.c:3108
            }
        }
        #expect(fake.requestCount == 0)                                            // test-openmeteo.c:3113
    }

    // C: /openmeteo/net/cancel-before-start (test-openmeteo.c:3117-3136)
    @Test("/openmeteo/net/cancel-before-start")
    func netCancelBeforeStart() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let place = try Self.miami()
        let op = await Task {
            withUnsafeCurrentTask { $0?.cancel() }  // cancelled before the call
            return await Fake.fetch(om, place)
        }.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:3130
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.requestCount == 0)                                            // test-openmeteo.c:3133
    }

    // C: /openmeteo/net/cancel-during-a (test-openmeteo.c:3145-3163)
    @Test("/openmeteo/net/cancel-during-a")
    func netCancelDuringA() async throws {
        var script = try Fake.Script.ok()
        script.a = Fake.Reply(.hang)
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: 10)
        let place = try Self.miami()
        let task = Task { await Fake.fetch(om, place) }
        try await Task.sleep(for: .milliseconds(150))                              // test-openmeteo.c:3156
        task.cancel()
        let op = await task.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:3158
        #expect(op.elapsedMs < 3000, "\(op.elapsedMs)")                            // test-openmeteo.c:3160
    }

    // C: /openmeteo/net/cancel-during-grace (test-openmeteo.c:3165-3190): A succeeded, B pending; the
    // caller cancels inside the window: the cancellation is reported, and nothing keeps the
    // provider alive afterwards.
    @Test("/openmeteo/net/cancel-during-grace")
    func netCancelDuringGrace() async throws {
        var script = try Fake.Script.ok()
        script.b = Fake.Reply(.hang)  // A done, B pending: inside the window
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        weak var weakOM: OpenMeteoProvider?
        let op: Fake.Op<WxSourceResult>
        do {
            let om = try Fake.provider(fake, timeoutMs: 10000, backoffMs: 10)
            weakOM = om
            let place = try Self.miami()
            let task = Task { await Fake.fetch(om, place) }
            // U28-F7: wait for A's request to reach the fake (aAnswer is set then, before the client
            // holds A's result), then the REQUIRED 500 ms (test-openmeteo.c:3178) so the client has
            // finished A and the cancel lands inside B's grace window, not during A.
            #expect(await Self.waitFor { fake.aAnswer != nil })  // A was answered before the cancellation
            try await Task.sleep(for: .milliseconds(500))                          // test-openmeteo.c:3178
            task.cancel()
            op = await task.value
        }
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:3181
        #expect(op.elapsedMs < Int64(OpenMeteoShared.nowcastGraceMs), "\(op.elapsedMs)") // test-openmeteo.c:3183
        #expect(await Self.waitFor(timeoutMs: 100) { weakOM == nil })              // test-openmeteo.c:3186-3188
    }

    // C: /openmeteo/net/cancel-before-finish (test-openmeteo.c:3192-3208). Swift has no separate
    // finish call: the rule is "a cancellation before fetch returns wins over a ready result". Here
    // A's members are ready and B answers inside the window, after the cancellation.
    @Test("/openmeteo/net/cancel-before-finish")
    func netCancelBeforeFinish() async throws {
        var script = try Fake.Script.ok()
        script.b.delayMs = 400
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let place = try Self.miami()
        let task = Task { await Fake.fetch(om, place) }
        // U28-F8: wait for A's request to reach the fake, then a 50 ms positioning wait so the
        // client has A's members when the cancel lands (B answers 400 ms after its request).
        #expect(await Self.waitFor { fake.aAnswer != nil })
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let op = await task.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:3204
    }

    // C: /openmeteo/net/cancel-other-thread (test-openmeteo.c:3227-3259): a cancellation from another
    // task at every stage from "just started" to "already finished": always exactly one outcome,
    // the full result or the cancellation, and some rounds are cancelled.
    @Test("/openmeteo/net/cancel-other-thread")
    func netCancelOtherThread() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let place = try Self.miami()
        var cancelled = 0
        var succeeded = 0
        let rounds = fuzzIterations(4000) / 40                                     // test-openmeteo.c:3236
        for i in 0..<rounds {
            let task = Task { await Fake.fetch(om, place) }
            let canceller = Task {
                try? await Task.sleep(for: .microseconds((i % 20) * 300))          // test-openmeteo.c:3238
                task.cancel()
            }
            let op = await task.value
            await canceller.value
            if op.isCancelled {
                cancelled += 1
            } else {
                #expect(op.value?.members.count == 7, "round \(i): \(op.outcome)")  // test-openmeteo.c:3250
                succeeded += 1
            }
        }
        #expect(cancelled + succeeded == rounds)                                   // test-openmeteo.c:3255
        #expect(cancelled > 0)                                                     // test-openmeteo.c:3256
    }

    // C: /openmeteo/net/dispose-in-flight (test-openmeteo.c:3288-3325), the parts with a Swift
    // counterpart: the last caller reference goes while the fetch is in flight (with and without a
    // later cancellation); g_object_run_dispose has none.
    @Test("/openmeteo/net/dispose-in-flight (last reference dropped)")
    func netDisposeInFlight() async throws {
        var script = try Fake.Script.ok()
        script.a.delayMs = 250
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let place = try Self.miami()
        var task = Task { [om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)] in
            await Fake.fetch(om, place)
        }
        var op = await task.value
        #expect(op.value?.members.count == 7, "\(op.outcome)")                     // test-openmeteo.c:3301
        // U28-F9: the cancelled half runs against its own fake whose A hangs, so the cancel can only
        // land while the fetch is in flight; the 50 ms only positions it (no completion race).
        var hangScript = try Fake.Script.ok()
        hangScript.a = Fake.Reply(.hang)
        let hangFake = try Fake.Server(hangScript)
        defer { hangFake.stop() }
        task = Task { [om = try Fake.provider(hangFake, timeoutMs: 5000, backoffMs: 10)] in
            await Fake.fetch(om, place)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        op = await task.value
        #expect(op.isCancelled, "\(op.outcome)")                                   // test-openmeteo.c:3310
    }

    // C: /openmeteo/net/concurrent-fetches (test-openmeteo.c:3327-3351)
    @Test("/openmeteo/net/concurrent-fetches")
    func netConcurrentFetches() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let honolulu = try Fake.place("Honolulu", 21.3069, -157.8583)
        let places = [try Self.miami(), try Self.london(), honolulu, try Self.miami(), try Self.london(), honolulu]
        let ops = await withTaskGroup(of: (Int, Fake.Op<WxSourceResult>).self) { group in
            for (i, place) in places.enumerated() {
                group.addTask { (i, await Fake.fetch(om, place)) }
            }
            var out = [Int: Fake.Op<WxSourceResult>]()
            for await (i, op) in group { out[i] = op }
            return out
        }
        for i in 0..<6 {
            #expect(ops[i]?.value != nil, "fetch \(i): \(String(describing: ops[i]?.outcome))") // :3342
        }
        #expect(ops[0]?.value?.members.count == 7)                                 // test-openmeteo.c:3344
        #expect(ops[1]?.value?.members.count == 6)                                 // test-openmeteo.c:3345
        #expect(ops[2]?.value?.members.count == 4)                                 // test-openmeteo.c:3346
        #expect(fake.requestCount == 2 + 1 + 1 + 2 + 1 + 1)                        // test-openmeteo.c:3347
    }

    /// Starts fetches in order, each only after the previous one has taken its client slots (C
    /// starts them synchronously, one wx_provider_fetch_async after the other), and returns their
    /// tasks. `slots[i]` is the number of slots fetch i takes (0: refused at once).
    static func startInOrder(
        _ om: OpenMeteoProvider, _ places: [WxPlace], slots: [Int]
    ) async -> [Task<Fake.Op<WxSourceResult>, Never>] {
        var tasks: [Task<Fake.Op<WxSourceResult>, Never>] = []
        var held = om.http.outstandingCount
        for (place, n) in zip(places, slots) {
            let task = Task { await Fake.fetch(om, place) }
            tasks.append(task)
            if n == 0 {
                _ = await task.value
            } else {
                held += n
                let target = held
                let reached = await waitFor { om.http.outstandingCount >= target }
                #expect(reached, "outstanding \(om.http.outstandingCount), expected \(target)")
            }
        }
        return tasks
    }

    // C: /openmeteo/net/inflight-cap (test-openmeteo.c:3353-3392): a CONUS fetch holds two client
    // slots (A and B): 8 fit into the 16 of the client, the 9th and 10th are RATE_LIMITED.
    @Test("/openmeteo/net/inflight-cap")
    func netInflightCap() async throws {
        #expect(HTTPPolicy.maxInflight == 16)                                      // test-openmeteo.c:3357
        var script = try Fake.Script.ok()
        script.a.delayMs = 100                                                     // test-openmeteo.c:3362
        script.b.delayMs = 100                                                     // test-openmeteo.c:3363
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let place = try Self.miami()
        let tasks = await Self.startInOrder(
            om, Array(repeating: place, count: 10), slots: Array(repeating: 2, count: 8) + [0, 0])
        for (i, task) in tasks.enumerated() {
            let op = await task.value
            if i < 8 {
                #expect(op.value?.members.count == 7, "fetch \(i): \(op.outcome)")  // test-openmeteo.c:3374
            } else {
                #expect(op.wxError?.code == .rateLimited, "fetch \(i): \(op.outcome)") // test-openmeteo.c:3376
            }
        }
        #expect(fake.requestCount == 16)                                           // test-openmeteo.c:3380
        // the slots come back: the next fetch works
        let op = await Fake.fetch(om, place)
        #expect(op.value != nil, "\(op.outcome)")                                  // test-openmeteo.c:3387
    }

    // C: /openmeteo/net/inflight-cap-single-slot (test-openmeteo.c:3394-3451)
    @Test("/openmeteo/net/inflight-cap-single-slot")
    func netInflightCapSingleSlot() async throws {
        var script = try Fake.Script.ok()
        script.a.delayMs = 300                                                     // test-openmeteo.c:3398
        script.b.delayMs = 300                                                     // test-openmeteo.c:3399
        let fake = try Fake.Server(script)
        defer { fake.stop() }
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 10)
        let sydney = try Fake.place("Sydney", -33.8688, 151.2093)
        let miami = try Self.miami()
        // 18 single-slot fetches: 16 fit, the 17th and 18th are refused
        var tasks = await Self.startInOrder(
            om, Array(repeating: sydney, count: 18), slots: Array(repeating: 1, count: 16) + [0, 0])
        for (i, task) in tasks.enumerated() {
            let op = await task.value
            if i < 16 {
                #expect(op.value?.members.count == 4, "fetch \(i): \(op.outcome)")  // test-openmeteo.c:3411
            } else {
                #expect(op.wxError?.code == .rateLimited, "fetch \(i): \(op.outcome)") // test-openmeteo.c:3413
            }
        }
        #expect(fake.requestCount == 16)                                           // test-openmeteo.c:3417
        // one CONUS fetch (2 slots) + 14 single-slot fetches fill the 16 slots; the 15th is refused
        var before = fake.requestCount
        tasks = await Self.startInOrder(
            om, [miami] + Array(repeating: sydney, count: 15), slots: [2] + Array(repeating: 1, count: 14) + [0])
        for (i, task) in tasks.enumerated() {
            let op = await task.value
            if i < 15 {
                #expect(op.value?.members.count == (i == 0 ? 7 : 4), "fetch \(i): \(op.outcome)") // :3429
            } else {
                #expect(op.wxError?.code == .rateLimited, "fetch \(i): \(op.outcome)") // test-openmeteo.c:3431
            }
        }
        #expect(fake.requestCount - before == 2 + 14)                              // test-openmeteo.c:3434
        // A CONUS fetch that finds exactly one free slot sends A and loses B (tolerated): 6 members.
        before = fake.requestCount
        tasks = await Self.startInOrder(
            om, Array(repeating: sydney, count: 15) + [miami], slots: Array(repeating: 1, count: 15) + [1])
        for (i, task) in tasks.enumerated() {
            let op = await task.value
            #expect(op.value?.members.count == (i == 15 ? 6 : 4), "fetch \(i): \(op.outcome)") // :3445
        }
        #expect(fake.requestCount - before == 15 + 1)                              // test-openmeteo.c:3447
    }

    // C: /openmeteo/net/refused (test-openmeteo.c:3453-3469)
    @Test("/openmeteo/net/refused")
    func netRefused() async throws {
        let fake = try Fake.Server(try Fake.Script.ok())
        let om = try Fake.provider(fake, timeoutMs: 5000, backoffMs: 5)
        fake.stop()  // nothing listens
        let op = await Fake.fetch(om, try Self.miami())
        #expect(op.wxError?.code == .network, "\(op.outcome)")                    // test-openmeteo.c:3466
    }
}
