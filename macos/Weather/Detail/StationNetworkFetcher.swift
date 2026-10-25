// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationNetworkFetcher.swift - fetches every surface-observation network that
// covers a place (WxStationNetworks builds the requests and parses the answers),
// records each fetch in the station catalog (reports, and silence of the stations
// that should have reported), falls back to the catalog's recent reports when a
// network cannot be reached, and fills the station elevations a network does not
// give from the Open-Meteo 90 m DEM (once per station; the catalog keeps them).

import Foundation
import WeatherCore

/// HTTP for the station networks: concurrent identical requests share one, and successful
/// bodies are cached for a per-call time, so the places of one area cost one request per refresh.
actor StationHTTP {
    static let shared = StationHTTP()

    /// The NWS points lookup of a place: its forecast office and hourly forecast.
    struct NWSPoints: Sendable {
        let cwa: String?
        let forecastHourly: String?
    }

    /// The outcome of a GET.
    enum Outcome: Sendable {
        case ok(Data)
        /// The service answered with this HTTP status (401/403: the key was refused; 429: too many
        /// requests).
        case status(Int)
        /// No answer (offline, timeout, TLS failure).
        case unreachable

        var data: Data? {
            if case .ok(let data) = self { return data }
            return nil
        }
    }

    private var cache: [String: (data: Data, expiresS: TimeInterval)] = [:]
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    /// Keys of resources known to have no usable data, until a time (e.g. precipitation-only
    /// DWD stations).
    private var noData: [String: TimeInterval] = [:]
    private static let maxCacheEntries = 400

    /// The body of a GET (HTTP 200, or 204 as an empty body), nil on any failure.
    func get(_ url: String, ttlS: TimeInterval, accept: String? = nil, timeoutS: TimeInterval = 8) async -> Data? {
        await fetch(url, accept: accept, ttlS: ttlS, timeoutS: timeoutS).data
    }

    /// A GET with extra request headers (a network's key): concurrent identical requests share
    /// one, and 200 bodies are cached for `ttlS`. The cache key includes the headers, so a new
    /// key is never answered from the old key's cache.
    func fetch(
        _ url: String, headers: [String: String] = [:], accept: String? = nil, ttlS: TimeInterval,
        timeoutS: TimeInterval = 8, bypassCache: Bool = false
    ) async -> Outcome {
        let now = Date().timeIntervalSince1970
        let cacheKey = headers.isEmpty
            ? url : url + "\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        if !bypassCache, let hit = cache[cacheKey], hit.expiresS > now {
            return .ok(hit.data)
        }
        if let running = inFlight[cacheKey] {
            return await running.value
        }
        let task = Task<Outcome, Never> {
            guard let u = URL(string: url) else { return .unreachable }
            var req = URLRequest(url: u)
            req.setValue(HTTPPolicy.userAgent, forHTTPHeaderField: "User-Agent")
            if let accept {
                req.setValue(accept, forHTTPHeaderField: "Accept")
            }
            for (name, value) in headers {
                req.setValue(value, forHTTPHeaderField: name)
            }
            req.timeoutInterval = timeoutS
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse
            else {
                return .unreachable
            }
            switch http.statusCode {
            case 200: return .ok(data)
            case 204: return .ok(Data())
            default: return .status(http.statusCode)
            }
        }
        inFlight[cacheKey] = task
        let outcome = await task.value
        inFlight[cacheKey] = nil
        if case .ok(let data) = outcome, ttlS > 0 {
            if cache.count >= Self.maxCacheEntries {
                cache = cache.filter { $0.value.expiresS > now }
                if cache.count >= Self.maxCacheEntries {
                    cache.removeAll()
                }
            }
            cache[cacheKey] = (data, Date().timeIntervalSince1970 + ttlS)
        }
        return outcome
    }

    func markNoData(_ key: String, forS seconds: TimeInterval) {
        noData[key] = Date().timeIntervalSince1970 + seconds
    }

    func hasNoData(_ key: String) -> Bool {
        guard let until = noData[key] else { return false }
        return until > Date().timeIntervalSince1970
    }

    /// The NWS points lookup (cached for a day).
    func nwsPoints(lat: Double, lon: Double) async -> NWSPoints? {
        let url = String(format: "https://api.weather.gov/points/%.4f,%.4f", lat, lon)
        guard let data = await get(url, ttlS: 86_400, accept: "application/geo+json"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = root["properties"] as? [String: Any]
        else {
            return nil
        }
        return NWSPoints(
            cwa: (p["cwa"] as? String) ?? (p["gridId"] as? String),
            forecastHourly: p["forecastHourly"] as? String)
    }
}

/// The outcome of a network's latest fetch, as Settings > Stations shows it.
nonisolated struct StationNetworkStatus: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// Answered: this many reports within reach of the place.
        case ok(reports: Int)
        /// The service refused the key (HTTP 401 or 403).
        case keyRejected(status: Int)
        /// Too many requests (HTTP 429): the service's limit for the key was reached.
        case rateLimited
        /// Another HTTP error.
        case failed(status: Int)
        /// No answer (offline, timeout).
        case unreachable
    }

    let outcome: Outcome
    /// When, UTC unix seconds.
    let atS: Int64
    /// The place it was fetched for.
    let placeName: String
}

/// Gathers the reports of every network covering a place (see the file header).
nonisolated enum StationNetworkFetcher {
    typealias Box = (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)

    /// What the user allows: the networks turned off, and the keys of the networks that need one.
    struct Configuration: Sendable {
        var disabled: Set<WxStationNetwork> = []
        var keys: [WxStationNetwork: String] = [:]
    }

    /// One network fetch: its reports (nil when the network could not be reached), what it
    /// should have contained, and how the service answered.
    struct Fetch: Sendable {
        let network: WxStationNetwork
        let observations: [WxStationObservation]?
        let coverage: WxStationCoverage
        var failure: StationNetworkStatus.Outcome? = nil

        /// A fetch that got no reports, with the reason.
        static func failed(_ network: WxStationNetwork, _ outcome: StationHTTP.Outcome, coverage: WxStationCoverage) -> Fetch {
            let reason: StationNetworkStatus.Outcome = switch outcome {
            case .status(let code) where code == 401 || code == 403: .keyRejected(status: code)
            case .status(429): .rateLimited
            case .status(let code): .failed(status: code)
            case .ok, .unreachable: .unreachable
            }
            return Fetch(network: network, observations: nil, coverage: coverage, failure: reason)
        }
    }

    /// The nearest US airports upgraded with their latest NWS 5-minute report.
    static let nwsUpgradeMaxStations = 3
    /// DWD and GeoSphere stations requested one by one: at most this many, nearest first.
    static let perStationMax = 8
    static let http = StationHTTP.shared

    static func gather(
        lat: Double, lon: Double, region: WxRegion, wfo: String?, placeName: String = "",
        configuration: Configuration = Configuration(), store: LiveStationStore
    ) async -> [WxStationObservation] {
        let nowS = Int64(Date().timeIntervalSince1970)
        let searchBox = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.searchRadiusKm)
        let poolBox = WxStationFusion.searchBox(lat: lat, lon: lon, radiusKm: WxStationFusion.poolRadiusKm)
        let covers = { (n: WxStationNetwork) in
            !configuration.disabled.contains(n) && WxStationNetworks.covers(n, lat: lat, lon: lon, region: region)
                && (!n.requiresKey || configuration.keys[n] != nil)
        }

        var fetches = await withTaskGroup(of: Fetch.self) { group -> [Fetch] in
            if covers(.metar) {
                group.addTask { await metar(lat: lat, lon: lon, box: searchBox) }
            }
            if covers(.ecccSWOB) {
                group.addTask { await swob(lat: lat, lon: lon, nowS: nowS, box: poolBox) }
            }
            if covers(.iemMesonet), let wfo {
                group.addTask { await iem(wfo: wfo) }
            }
            if covers(.dwdSYNOP) {
                group.addTask { await brightSky(lat: lat, lon: lon, nowS: nowS) }
            }
            if covers(.dmi) {
                group.addTask { await dmi(lat: lat, lon: lon, nowS: nowS, box: poolBox) }
            }
            if covers(.fmi) {
                group.addTask { await fmi(lat: lat, lon: lon, nowS: nowS, box: poolBox) }
            }
            if covers(.smhi) {
                group.addTask { await smhi(box: searchBox) }
            }
            if covers(.geosphere) {
                group.addTask { await geosphere(lat: lat, lon: lon) }
            }
            if covers(.meteoSwiss) {
                group.addTask { await meteoSwiss(lat: lat, lon: lon) }
            }
            if covers(.aemet), let key = configuration.keys[.aemet] {
                group.addTask { await aemet(key: key, box: searchBox) }
            }
            if covers(.frost), let key = configuration.keys[.frost] {
                group.addTask { await frost(lat: lat, lon: lon, clientID: key) }
            }
            if covers(.knmi), let key = configuration.keys[.knmi] {
                group.addTask { await knmi(key: key, box: searchBox, nowS: nowS) }
            }
            if covers(.meteoFrance), let key = configuration.keys[.meteoFrance] {
                group.addTask { await meteoFrance(key: key, box: searchBox, nowS: nowS) }
            }
            if covers(.metOffice), let key = configuration.keys[.metOffice] {
                group.addTask { await metOffice(lat: lat, lon: lon, key: key) }
            }
            var out: [Fetch] = []
            for await f in group {
                out.append(f)
            }
            return out
        }
        if covers(.nwsASOS), let metars = fetches.first(where: { $0.network == .metar })?.observations {
            fetches.append(await nwsUpgrades(metars, lat: lat, lon: lon))
        }

        // Catalog: record every fetch; the recent reports of a network that could not be reached.
        let catalog = await store.catalog
        var all: [WxStationObservation] = []
        for f in fetches {
            let outcome: StationNetworkStatus.Outcome
            if let obs = f.observations {
                await store.recordFetch(obs, coverage: f.coverage, nowS: nowS)
                all += obs
                outcome = .ok(reports: obs.filter {
                    WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon) <= WxStationFusion.searchRadiusKm
                }.count)
            } else {
                all += catalog.cachedObservations(network: f.network, box: f.coverage.box ?? searchBox, nowS: nowS)
                outcome = f.failure ?? .unreachable
            }
            await store.recordStatus(
                StationNetworkStatus(outcome: outcome, atS: nowS, placeName: placeName), for: f.network)
        }

        // DEM elevations of the stations whose network gives none (once per station).
        let missing = Set(await store.catalog.keysMissingElevation(all))
        if !missing.isEmpty {
            var seen: Set<String> = []
            let targets = all.filter { missing.contains($0.key) && seen.insert($0.key).inserted }
            var found: [String: Double] = [:]
            for start in stride(from: 0, to: targets.count, by: 100) {
                let chunk = Array(targets[start..<min(start + 100, targets.count)])
                let url = WxStationNetworks.elevationURL(chunk.map { (lat: $0.lat, lon: $0.lon) })
                guard let data = await http.get(url, ttlS: 0) else { continue }
                for (obs, elev) in zip(chunk, WxStationNetworks.parseElevations(data)) where elev.isFinite {
                    found[obs.key] = elev
                }
            }
            await store.setDEMElevations(found)
        }
        return await store.catalog.enrich(all).filter {
            WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon) <= WxStationFusion.searchRadiusKm
        }
    }

    // MARK: - Networks

    static func metar(lat: Double, lon: Double, box: Box) async -> Fetch {
        let data = await http.get(WxStationNetworks.metarURL(lat: lat, lon: lon), ttlS: 240, timeoutS: 8)
        return Fetch(
            network: .metar, observations: data.map(WxStationNetworks.parseMETARs),
            coverage: WxStationCoverage(network: .metar, box: box))
    }

    static func nwsUpgrades(_ metars: [WxStationObservation], lat: Double, lon: Double) async -> Fetch {
        let airports = metars
            .filter { $0.id.count == 4 && ["K", "P", "T"].contains($0.id.first.map(String.init) ?? "") }
            .map { ($0, WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon)) }
            .filter { $0.1 <= WxStationFusion.poolRadiusKm }
            .sorted { $0.1 < $1.1 }
            .prefix(nwsUpgradeMaxStations)
            .map(\.0)
        var answered: Set<String> = []
        var upgrades: [WxStationObservation] = []
        await withTaskGroup(of: (String, Data?).self) { group in
            for airport in airports {
                group.addTask {
                    (airport.id, await http.get(
                        WxStationNetworks.nwsLatestURL(stationID: airport.id), ttlS: 120,
                        accept: "application/geo+json", timeoutS: 5))
                }
            }
            for await (id, data) in group {
                guard let data, let site = airports.first(where: { $0.id == id }) else { continue }
                answered.insert(id)
                if let obs = WxStationNetworks.parseNWSLatest(data, site: site) {
                    upgrades.append(obs)
                }
            }
        }
        return Fetch(
            network: .nwsASOS, observations: upgrades,
            coverage: WxStationCoverage(network: .nwsASOS, stationIDs: answered))
    }

    static func swob(lat: Double, lon: Double, nowS: Int64, box: Box) async -> Fetch {
        let data = await http.get(
            WxStationNetworks.swobURL(lat: lat, lon: lon, nowS: nowS), ttlS: 120, accept: "application/geo+json")
        return Fetch(
            network: .ecccSWOB, observations: data.map(WxStationNetworks.parseSWOB),
            coverage: WxStationCoverage(network: .ecccSWOB, box: box))
    }

    static func iem(wfo: String) async -> Fetch {
        let data = await http.get(WxStationNetworks.iemURL(wfo: wfo), ttlS: 300)
        return Fetch(
            network: .iemMesonet, observations: data.map(WxStationNetworks.parseIEM),
            coverage: WxStationCoverage(network: .iemMesonet, areaTag: "iem:\(wfo)"))
    }

    static func brightSky(lat: Double, lon: Double, nowS: Int64) async -> Fetch {
        guard let sourcesData = await http.get(WxStationNetworks.brightSkySourcesURL(lat: lat, lon: lon), ttlS: 6 * 3600)
        else {
            return Fetch(network: .dwdSYNOP, observations: nil, coverage: WxStationCoverage(network: .dwdSYNOP))
        }
        var sources: [WxStationNetworks.BrightSkySource] = []
        for source in WxStationNetworks.parseBrightSkySources(sourcesData, nowS: nowS)
        where !(await http.hasNoData("brightsky:\(source.id)")) {
            sources.append(source)
            if sources.count == perStationMax { break }
        }
        var answered: Set<String> = []
        var observations: [WxStationObservation] = []
        await withTaskGroup(of: (WxStationNetworks.BrightSkySource, Data?).self) { group in
            for source in sources {
                group.addTask {
                    (source, await http.get(WxStationNetworks.brightSkyCurrentURL(sourceID: source.id), ttlS: 300))
                }
            }
            for await (source, data) in group {
                guard let data else { continue }
                answered.insert(source.site.id)
                if let obs = WxStationNetworks.parseBrightSkyCurrent(data, source: source) {
                    observations.append(obs)
                } else {
                    // e.g. a precipitation-only station: do not ask again for a while
                    await http.markNoData("brightsky:\(source.id)", forS: 6 * 3600)
                }
            }
        }
        return Fetch(
            network: .dwdSYNOP, observations: observations,
            coverage: WxStationCoverage(network: .dwdSYNOP, stationIDs: answered))
    }

    static func dmi(lat: Double, lon: Double, nowS: Int64, box: Box) async -> Fetch {
        async let stationsData = http.get(WxStationNetworks.dmiStationsURL(lat: lat, lon: lon), ttlS: 86_400)
        async let obsData = http.get(
            WxStationNetworks.dmiObservationsURL(lat: lat, lon: lon, nowS: nowS), ttlS: 120,
            accept: "application/geo+json")
        let stations = await stationsData.map(WxStationNetworks.parseDMIStations) ?? [:]
        let observations = await obsData.map { WxStationNetworks.parseDMIObservations($0, stations: stations) }
        return Fetch(network: .dmi, observations: observations, coverage: WxStationCoverage(network: .dmi, box: box))
    }

    static func fmi(lat: Double, lon: Double, nowS: Int64, box: Box) async -> Fetch {
        let data = await http.get(WxStationNetworks.fmiURL(lat: lat, lon: lon, nowS: nowS), ttlS: 120)
        return Fetch(
            network: .fmi, observations: data.map(WxStationNetworks.parseFMI),
            coverage: WxStationCoverage(network: .fmi, box: box))
    }

    static func smhi(box: Box) async -> Fetch {
        // Every parameter covers all of Sweden: shared by every Swedish place (cached 10 min).
        var responses: [Int: Data] = [:]
        await withTaskGroup(of: (Int, Data?).self) { group in
            for parameter in WxStationNetworks.smhiParameters {
                group.addTask { (parameter, await http.get(WxStationNetworks.smhiURL(parameter: parameter), ttlS: 600)) }
            }
            for await (parameter, data) in group {
                if let data {
                    responses[parameter] = data
                }
            }
        }
        guard responses[1] != nil else {  // no temperature, no fetch
            return Fetch(network: .smhi, observations: nil, coverage: WxStationCoverage(network: .smhi, box: box))
        }
        let inBox = WxStationNetworks.parseSMHI(responses).filter { within(box, $0) }
        return Fetch(network: .smhi, observations: inBox, coverage: WxStationCoverage(network: .smhi, box: box))
    }

    static func geosphere(lat: Double, lon: Double) async -> Fetch {
        guard let stationsData = await http.get(WxStationNetworks.geosphereStationsURL, ttlS: 86_400) else {
            return Fetch(network: .geosphere, observations: nil, coverage: WxStationCoverage(network: .geosphere))
        }
        let nearest = WxStationNetworks.parseGeoSphereStations(stationsData)
            .map { ($0, WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon)) }
            .filter { $0.1 <= WxStationFusion.poolRadiusKm }
            .sorted { $0.1 < $1.1 }
            .prefix(perStationMax * 2)
            .map(\.0)
        guard !nearest.isEmpty else {
            return Fetch(network: .geosphere, observations: [], coverage: WxStationCoverage(network: .geosphere, stationIDs: []))
        }
        let ids = nearest.map(\.id)
        let sites = Dictionary(nearest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let data = await http.get(WxStationNetworks.geosphereCurrentURL(stationIDs: ids), ttlS: 300)
        return Fetch(
            network: .geosphere, observations: data.map { WxStationNetworks.parseGeoSphereCurrent($0, stations: sites) },
            coverage: WxStationCoverage(network: .geosphere, stationIDs: Set(ids)))
    }

    static func meteoSwiss(lat: Double, lon: Double) async -> Fetch {
        guard let stationsData = await http.get(WxStationNetworks.meteoSwissStationsURL, ttlS: 86_400) else {
            return Fetch(network: .meteoSwiss, observations: nil, coverage: WxStationCoverage(network: .meteoSwiss))
        }
        let nearest = WxStationNetworks.parseMeteoSwissStations(stationsData).values
            .map { ($0, WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon)) }
            .filter { $0.1 <= WxStationFusion.poolRadiusKm }
            .sorted { $0.1 < $1.1 }
            .prefix(perStationMax)
            .map(\.0)
        var answered: Set<String> = []
        var observations: [WxStationObservation] = []
        await withTaskGroup(of: (WxStationSite, Data?).self) { group in
            for site in nearest {
                group.addTask { (site, await http.get(WxStationNetworks.meteoSwissStationURL(abbr: site.id), ttlS: 300)) }
            }
            for await (site, data) in group {
                guard let data else { continue }
                answered.insert(site.id)
                if let obs = WxStationNetworks.parseMeteoSwissStation(data, site: site) {
                    observations.append(obs)
                }
            }
        }
        return Fetch(
            network: .meteoSwiss, observations: observations,
            coverage: WxStationCoverage(network: .meteoSwiss, stationIDs: answered))
    }

    // MARK: - Networks with the user's key

    /// AEMET: the first request names a data URL valid for about 5 minutes; an expired one is asked
    /// for again once. All of Spain comes in one answer (~830 stations), kept 15 minutes (the data is
    /// hourly) and shared by every Spanish place.
    static func aemet(key: String, box: Box) async -> Fetch {
        let coverage = WxStationCoverage(network: .aemet, box: box)
        for attempt in 0..<2 {
            let first = await http.fetch(
                WxStationNetworks.aemetObservationsURL, headers: ["api_key": key], accept: "application/json",
                ttlS: 900, timeoutS: 20, bypassCache: attempt > 0)
            guard case .ok(let envelope) = first else {
                return .failed(.aemet, first, coverage: coverage)
            }
            switch WxStationNetworks.parseAEMETEnvelope(envelope) {
            case .data(let url):
                let second = await http.fetch(url, ttlS: 900, timeoutS: 30, bypassCache: attempt > 0)
                guard case .ok(let data) = second else {
                    return .failed(.aemet, second, coverage: coverage)
                }
                if WxStationNetworks.aemetDataExpired(data) {
                    continue
                }
                let observations = WxStationNetworks.parseAEMET(data).filter { within(box, $0) }
                return Fetch(network: .aemet, observations: observations, coverage: coverage)
            case .noData:
                return Fetch(network: .aemet, observations: [], coverage: coverage)
            case .refused(let status, _):
                return .failed(.aemet, .status(status > 0 ? status : 502), coverage: coverage)
            }
        }
        return .failed(.aemet, .unreachable, coverage: coverage)
    }

    /// MET Norway Frost: the nearest stations that measure temperature (kept a day), then the latest
    /// values of those within reach. 404 and 412 mean "no data in the window", not a failure.
    static func frost(lat: Double, lon: Double, clientID: String) async -> Fetch {
        let auth = ["Authorization": WxStationNetworks.frostAuthorization(clientID: clientID)]
        let listed = await http.fetch(
            WxStationNetworks.frostSourcesURL(lat: lat, lon: lon), headers: auth, ttlS: 86_400, timeoutS: 15)
        guard case .ok(let sourcesData) = listed else {
            return .failed(.frost, listed, coverage: WxStationCoverage(network: .frost))
        }
        let sites = WxStationNetworks.parseFrostSources(sourcesData).filter {
            WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: $0.lat, bLon: $0.lon) <= WxStationFusion.searchRadiusKm
        }
        let ids = sites.map(\.id)
        let coverage = WxStationCoverage(network: .frost, stationIDs: Set(ids))
        guard !ids.isEmpty else {
            return Fetch(network: .frost, observations: [], coverage: coverage)
        }
        let latest = await http.fetch(
            WxStationNetworks.frostObservationsURL(stationIDs: ids), headers: auth, ttlS: 300, timeoutS: 15)
        switch latest {
        case .ok(let data):
            let byID = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return Fetch(
                network: .frost, observations: WxStationNetworks.parseFrostObservations(data, sites: byID),
                coverage: coverage)
        case .status(404), .status(412):
            return Fetch(network: .frost, observations: [], coverage: coverage)
        default:
            return .failed(.frost, latest, coverage: coverage)
        }
    }

    /// KNMI EDR API: the last hour of 10-minute data of the stations in the box (CoverageJSON), with
    /// the station names and heights (kept a day).
    static func knmi(key: String, box: Box, nowS: Int64) async -> Fetch {
        let auth = ["Authorization": key]
        let coverage = WxStationCoverage(network: .knmi, box: box)
        async let locations = http.fetch(WxStationNetworks.knmiLocationsURL, headers: auth, ttlS: 86_400, timeoutS: 15)
        let cube = await http.fetch(
            WxStationNetworks.knmiCubeURL(box: box, nowS: nowS), headers: auth,
            accept: "application/prs.coverage+json", ttlS: 300, timeoutS: 20)
        guard case .ok(let data) = cube else {
            _ = await locations
            return .failed(.knmi, cube, coverage: coverage)
        }
        let stations = await locations.data.map(WxStationNetworks.parseKNMILocations) ?? [:]
        return Fetch(
            network: .knmi, observations: WxStationNetworks.parseKNMICoverage(data, stations: stations),
            coverage: coverage)
    }

    /// Météo-France: one 6-minute slot of every French station (kept until the next slot, shared by
    /// every French place), with the station list (kept a day).
    static func meteoFrance(key: String, box: Box, nowS: Int64) async -> Fetch {
        let auth = ["apikey": key]
        let coverage = WxStationCoverage(network: .meteoFrance, box: box)
        async let list = http.fetch(WxStationNetworks.meteoFranceStationsURL, headers: auth, ttlS: 86_400, timeoutS: 20)
        let slot = await http.fetch(
            WxStationNetworks.meteoFranceSlotURL(slotS: WxStationNetworks.meteoFranceSlotS(nowS: nowS)),
            headers: auth, accept: "application/json", ttlS: 360, timeoutS: 20)
        guard case .ok(let data) = slot else {
            _ = await list
            return .failed(.meteoFrance, slot, coverage: coverage)
        }
        let stations = await list.data.map(WxStationNetworks.parseMeteoFranceStations) ?? [:]
        let observations = WxStationNetworks.parseMeteoFrance(data, stations: stations).filter { within(box, $0) }
        return Fetch(network: .meteoFrance, observations: observations, coverage: coverage)
    }

    /// Met Office DataHub: the free plan allows 360 calls a day, so the nearest stations are kept a
    /// week and each station's hourly reports an hour, and at most `metOfficeMaxStations` stations
    /// within the search radius are read.
    static let metOfficeMaxStations = 3

    static func metOffice(lat: Double, lon: Double, key: String) async -> Fetch {
        let auth = ["apikey": key]
        let nearest = await http.fetch(
            WxStationNetworks.metOfficeNearestURL(lat: lat, lon: lon), headers: auth, ttlS: 7 * 86_400, timeoutS: 15)
        guard case .ok(let listData) = nearest else {
            return .failed(.metOffice, nearest, coverage: WxStationCoverage(network: .metOffice))
        }
        let stations = WxStationNetworks.parseMetOfficeNearest(listData).filter {
            guard let p = WxStationNetworks.decodeGeohash($0.geohash) else { return false }
            return WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: p.lat, bLon: p.lon) <= WxStationFusion.searchRadiusKm
        }.prefix(metOfficeMaxStations)
        var answered: Set<String> = []
        var observations: [WxStationObservation] = []
        var failure: StationHTTP.Outcome?
        await withTaskGroup(of: (String, String?, StationHTTP.Outcome).self) { group in
            for s in stations {
                group.addTask {
                    (s.geohash, s.area, await http.fetch(
                        WxStationNetworks.metOfficeStationURL(geohash: s.geohash), headers: auth, ttlS: 3600,
                        timeoutS: 15))
                }
            }
            for await (hash, area, outcome) in group {
                switch outcome {
                case .ok(let data):
                    answered.insert(hash)
                    if let obs = WxStationNetworks.parseMetOfficeStation(data, geohash: hash, area: area) {
                        observations.append(obs)
                    }
                case .status(404):
                    answered.insert(hash)  // no data at this station now
                default:
                    failure = outcome
                }
            }
        }
        let coverage = WxStationCoverage(network: .metOffice, stationIDs: answered)
        if answered.isEmpty, let failure {
            return .failed(.metOffice, failure, coverage: coverage)
        }
        return Fetch(network: .metOffice, observations: observations, coverage: coverage)
    }

    static func within(_ box: Box, _ obs: WxStationObservation) -> Bool {
        obs.lat >= box.minLat && obs.lat <= box.maxLat && obs.lon >= box.minLon && obs.lon <= box.maxLon
    }
}
