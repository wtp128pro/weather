// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// ServiceEndToEndTests.swift - the real NWS, Open-Meteo and MET Norway
// providers, each on its own loopback server (127.0.0.1 only) serving the
// captured C fixtures (src/providers/{nws,openmeteo,metno}/fixtures), feed the
// real ServiceOrchestrator and WxBlend. There is no C test of this exact
// composition; the assertions are:
//  - every member that reached the blend has a (source, model) pair with a
//    real row of the weights table (no unknown-pair fallback, wx-weights.c:22-87);
//  - the statuses carry the providers' C identities (wx-nws.c:19-21,
//    wx-openmeteo.c:14-16, wx-metno.c:1040-1084) in the registration order of
//    ui/wx-app.c:295-297 and the forwarded member counts;
//  - the forecast equals the blend of the same providers' members fetched
//    directly from the same servers (the oracle of test-service.c:764-776);
//  - at the named hour 2026-10-22T00:00:00Z only MET Norway has data, so the
//    blended values are MET's own values of that entry of complete_miami.json,
//    the values test-metno.c:458-465 asserts the parser delivers
//    (/metno/parse/fixture-miami, test-metno.c:471-481, :4286).
// The service and the providers run on ManualClocks pinned to
// 2026-10-12T19:30:00Z (the fixtures were captured that afternoon); the NWS
// and MET Norway HTTP clients run on the system clock, Open-Meteo's (which
// shares its provider's clock) on the ManualClock, so its 2 s nowcast window
// cannot expire under CPU load. A watchdog advances the service's clock
// past its deadline if a provider ever failed to answer, so the test fails
// instead of hanging.

import Foundation
import Testing
@testable import WeatherCore

@MainActor
@Suite(.serialized)
struct ServiceEndToEndTests {
    /// 2026-10-12T19:30:00Z: T0 of the Open-Meteo fixture (1791763200,
    /// 2026-10-12T00:00Z, test-openmeteo.c T0) + 19.5 h.
    nonisolated static let nowS: Int64 = 1_791_763_200 + 19 * 3600 + 1800

    /// The named hour: 2026-10-22T00:00:00Z, the last entry of complete_miami.json.
    nonisolated static let metOnlyHourS: Int64 = 1_791_763_200 + 10 * 86400

    /// miami (test-service.c:73-85; test-nws.c:104-108; test-metno.c:409).
    static func miami() throws -> WxPlace {
        try WxPlace(
            name: "Miami", admin1: "Florida", country: "United States", countryCode: "US", lat: 25.7617,
            lon: -80.1918, timezone: "America/New_York")
    }

    nonisolated static func clock() -> ManualClock {
        ManualClock(wallMicroseconds: nowS * 1_000_000)
    }

    /// The three fake origins (C: the path-routed fakes of test-nws.c:1792-1801,
    /// test-metno.c:2006, test-openmeteo.c:2511).
    struct Servers {
        let nws: LoopbackServer
        let openMeteo: LoopbackServer
        let metNo: LoopbackServer

        func stop() {
            nws.stop()
            openMeteo.stop()
            metNo.stop()
        }

        static func start(nwsPoints: LoopbackServer.Step? = nil, metNo metStep: LoopbackServer.Step? = nil) throws
            -> Servers
        {
            let points = try Fixtures.data("points_miami.json")
            let grid = try Fixtures.data("gridpoints_miami.json")
            let forecast = try Fixtures.data("forecast_miami_multi.json")
            let nowcast = try Fixtures.data("nowcast_miami.json")
            let complete = try Fixtures.data("complete_miami.json")
            let nws = try LoopbackServer(routes: [
                .init("/points/", [nwsPoints ?? .respond(body: points)]),
                .init("/gridpoints/MFL/110,50", [.respond(body: grid)]),
            ])
            let openMeteo = try LoopbackServer(routes: [
                .init(
                    "/v1/forecast",
                    [
                        .compute { _, request in
                            // request B (minutely_15 nowcast) or request A (hourly multi-model)
                            request.path.contains("minutely_15=") ? .respond(body: nowcast) : .respond(body: forecast)
                        }
                    ])
            ])
            let metNo = try LoopbackServer(routes: [
                .init("/weatherapi/locationforecast/2.0/complete", [metStep ?? .respond(body: complete)])
            ])
            return Servers(nws: nws, openMeteo: openMeteo, metNo: metNo)
        }

        /// The real providers on these origins, in the order of ui/wx-app.c:295-297.
        func providers() throws -> (NWSProvider, OpenMeteoProvider, METNorwayProvider) {
            let nws = try NWSProvider(
                testBaseURL: "http://127.0.0.1:\(nws.port)", timeoutMs: 5000, backoffBaseMs: 5,
                clock: ServiceEndToEndTests.clock())
            // Its nowcast window (OpenMeteoShared.nowcastGraceMs) and its client run on a
            // ManualClock: under CPU load request B must not lose a real-time race.
            let om = try OpenMeteoProvider(
                customBaseURL: "http://127.0.0.1:\(openMeteo.port)", timeoutMs: 5000, backoffBaseMs: 5,
                clock: ServiceEndToEndTests.clock())
            let met = try METNorwayProvider(
                testingBaseURL: "http://127.0.0.1:\(metNo.port)", timeoutMs: 5000, backoffBaseMs: 5,
                clock: ServiceEndToEndTests.clock())
            return (nws, om, met)
        }
    }

    /// Refreshes `place` with a watchdog that pushes the service's clock past
    /// its deadline after 20 s of real time (a hung provider then shows as a
    /// TIMEOUT status instead of hanging the test).
    static func refresh(_ service: ServiceOrchestrator, _ clock: ManualClock, _ place: WxPlace) async
        -> Result<WxForecast, any Error>
    {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            await clock.advance(by: Int64(ServiceOrchestrator.deadlineMs) * 1000 + 1_000_000)
        }
        defer { watchdog.cancel() }
        return await ServiceOrchestratorTests.capture { try await service.refresh(place) }
    }

    /// The members each provider delivers when asked directly (fresh
    /// instances on the same servers), registration order.
    static func directResults(_ servers: Servers, _ place: WxPlace) async throws -> [WxSourceResult] {
        let (nws, om, met) = try servers.providers()
        return [try await nws.fetch(place), try await om.fetch(place), try await met.fetch(place)]
    }

    // END-TO-END (U26 acceptance criterion 2): real providers on loopback ->
    // service -> blend.
    @Test("end to end: NWS + Open-Meteo + MET Norway fixtures through the service and the blend")
    func realProvidersThroughServiceAndBlend() async throws {
        let servers = try Servers.start()
        defer { servers.stop() }
        let place = try Self.miami()
        let registry = WxRegistry()
        let (nws, om, met) = try servers.providers()
        try registry.addProvider(nws)  // ui/wx-app.c:295
        try registry.addProvider(om)  // :296
        try registry.addProvider(met)  // :297
        let clock = Self.clock()
        let service = ServiceOrchestrator(registry: registry, clock: clock)

        let fc = try await Self.refresh(service, clock, place).get()

        // The real providers really went to their (loopback) origins.
        #expect(servers.nws.requests.map(\.path) == ["/points/25.7617,-80.1918", "/gridpoints/MFL/110,50"])  // test-nws.c:1967-1969
        #expect(servers.openMeteo.requests.count == 2)  // request A and request B (CONUS)
        #expect(
            servers.metNo.requests.map(\.path) == [
                "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918"
            ])  // test-metno.c:307

        // The members the service blended: the providers' own answers.
        let direct = try await Self.directResults(servers, place)
        #expect(direct.map(\.providerID) == ["nws", "open-meteo", "met-no"])
        // nws:nws (wx-nws.h); the Miami models and the nowcast member in request
        // order (test-openmeteo.c:2526); met-no:ecmwf (wx-metno.h:150).
        let pairs = direct.flatMap { $0.members.map { "\($0.sourceID):\($0.modelID)" } }
        #expect(
            pairs == [
                "nws:nws", "open-meteo:hrrr", "open-meteo:nbm", "open-meteo:gfs", "open-meteo:ecmwf",
                "open-meteo:icon", "open-meteo:gem", "open-meteo:hrrr15", "met-no:ecmwf",
            ])
        // Every member hits a real row of the weights table: no unknown-pair fallback.
        for result in direct {
            for m in result.members {
                #expect(WxWeights.hasTableRow(sourceID: m.sourceID, modelID: m.modelID), "\(m.sourceID):\(m.modelID)")
                for variable in WxVar.allCases {
                    let lookup = WxWeights.lookup(
                        sourceID: m.sourceID, modelID: m.modelID, variable: variable, horizonH: 1.0, usRegion: true)
                    #expect(lookup.origin == .tableRow, "\(m.sourceID):\(m.modelID) \(variable)")
                }
            }
        }

        // Statuses: registration order, the providers' identities, the forwarded counts.
        #expect(fc.sources.count == 3)
        ServiceOrchestratorTests.expectStatus(fc, 0, "nws", .ok, nil, UInt32(direct[0].members.count))
        ServiceOrchestratorTests.expectStatus(fc, 1, "open-meteo", .ok, nil, UInt32(direct[1].members.count))
        ServiceOrchestratorTests.expectStatus(fc, 2, "met-no", .ok, nil, UInt32(direct[2].members.count))
        #expect(fc.sources.map(\.name) == ["National Weather Service", "Open-Meteo", "MET Norway"])  // wx-nws.c:19, wx-openmeteo.c:14, wx-metno.c:1040
        #expect(
            fc.sources.map(\.attribution) == [
                "Source: NOAA/National Weather Service", "Weather data by Open-Meteo.com", "Data from MET Norway",
            ])  // wx-nws.c:20, wx-openmeteo.c:15, wx-metno.c:1062
        #expect(
            fc.sources.map(\.attributionURL) == [
                "https://www.weather.gov/", "https://open-meteo.com/", "https://api.met.no/",
            ])  // wx-nws.c:21, wx-openmeteo.c:16, wx-metno.c:1084

        // The forecast: generated at the service's clock, for the place, with a nowcast.
        #expect(fc.generatedS == Self.nowS)
        #expect(fc.place.key == place.key)
        #expect(!fc.quarters.isEmpty)  // the hrrr15 nowcast member took part
        #expect(fc.hours.first?.tS == Self.nowS / 3600 * 3600 - 3600)  // wx-blend.h: the hour of now minus one
        ServiceOrchestratorTests.expectMatchesOracle(fc, place, direct)

        // The named hour: only MET Norway's last entry (complete_miami.json,
        // "2026-10-22T00:00:00Z": air_temperature 25.8, apparent_air_temperature
        // 25.8, cloud_area_fraction 32.8, relative_humidity 72.3, wind_speed 3.5,
        // no gust, no next_1_hours) - values test-metno.c:458-465 asserts.
        let hour = try #require(fc.hours.first { $0.tS == Self.metOnlyHourS })
        #expect(fc.hours.last?.tS == Self.metOnlyHourS)  // the latest hour with a value
        #expect(hour.nMembers == 1)
        #expect(hour.tempC == 25.8)  // test-metno.c:458
        #expect(hour.feelsC == 25.8)  // :459
        #expect(hour.cloudPct == 32.8)  // :460
        #expect(hour.humidityPct == 72.3)  // :461
        #expect(hour.windKmh == 3.5 * 3.6)  // :462 wind_speed (m/s) x 3.6
        #expect(hour.gustKmh.isNaN)  // :463 no wind_speed_of_gust
        #expect(hour.precipMm.isNaN)  // :464 no next_1_hours
        #expect(hour.precipProb.isNaN)  // :465 MET has no probability
        #expect(hour.tempSpreadC.isNaN)  // one temperature only
    }

    // END-TO-END, failures of real providers: NWS learns from /points (404)
    // that it does not cover the place (SKIPPED, wx-service.h:107-108), MET
    // Norway gets HTTP 429 (FAILED, RATE_LIMITED, :113-116); Open-Meteo alone
    // makes the forecast, which equals the blend of its own members.
    @Test("end to end: real provider failures become statuses; the forecast is Open-Meteo's")
    func realProviderFailures() async throws {
        let servers = try Servers.start(
            nwsPoints: .text("{}", status: 404), metNo: .text("{}", status: 429))
        defer { servers.stop() }
        let place = try Self.miami()
        let registry = WxRegistry()
        let (nws, om, met) = try servers.providers()
        try registry.addProvider(nws)
        try registry.addProvider(om)
        try registry.addProvider(met)
        let clock = Self.clock()
        let service = ServiceOrchestrator(registry: registry, clock: clock)

        let fc = try await Self.refresh(service, clock, place).get()

        let (_, omDirect, _) = try servers.providers()
        let omResult = try await omDirect.fetch(place)
        ServiceOrchestratorTests.expectStatus(fc, 0, "nws", .skipped, nil, 0)
        ServiceOrchestratorTests.expectStatus(fc, 1, "open-meteo", .ok, nil, UInt32(omResult.members.count))
        ServiceOrchestratorTests.expectStatus(fc, 2, "met-no", .failed, .rateLimited, 0)
        ServiceOrchestratorTests.expectMatchesOracle(fc, place, [omResult])
        #expect(fc.hours.allSatisfy { $0.tS != Self.metOnlyHourS || $0.nMembers == 0 })
    }
}
