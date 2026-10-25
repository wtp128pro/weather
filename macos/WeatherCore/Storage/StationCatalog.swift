// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// StationCatalog.swift - the persistent record of every surface station the app
// has received a report from, and how much each one can be trusted.
//
// Per station: its metadata (position, elevation - from the network or, when the
// network gives none, the Open-Meteo 90 m DEM), its newest report (the fallback
// when its network cannot be reached), its reachability, and its track record
// from leave-one-out testing against its neighbours (WxStationFusion.crossValidate).
//
// Reachability: every successful fetch of an area either brings a station's
// report or advances its silence clock. The clock only advances while the app
// is checking (at most `maxSilenceStepS` per check, so time with the app closed
// never counts); a station silent for `silenceLimitS` of checking is dropped,
// and if it comes back it starts over on probation.
//
// Health (0...1, the weight multiplier of WxStationFusion):
//   - probation: 0.6 rising to 1 over the first `probationTests` tests;
//   - error: e = sqrt(bias^2 + scatter^2) from the exponentially weighted
//     residuals (bias tracked separately by day and by night: a sun-exposed
//     sensor reads warm only by day); weight 1 up to 1.5 °C, then
//     1 / (1 + ((e - 1.5) / 1.5)^2); excluded from `excludeErrorC`;
//   - stuck: a 0.1 °C-resolution sensor unchanged for `stuckAfterS` is excluded.
// An excluded station keeps being tested, so it can recover.
//
// Pure value type; the app persists it with `save(path:)` / `load(path:)`.

import Foundation

/// One catalogued station.
public struct WxStationRecord: Sendable, Equatable, Codable {
    public var network: WxStationNetwork
    public var id: String
    public var name: String?
    public var lat: Double
    public var lon: Double
    public var elevM: Double?
    /// The elevation came from the DEM, not from the network.
    public var elevFromDEM: Bool
    /// Area tag of the fetch that reports the station when that area is not a box (an NWS
    /// forecast office for IEM), else nil.
    public var areaTag: String?
    public var firstSeenS: Int64
    /// Observation time of the newest report.
    public var lastReportS: Int64
    /// The newest report.
    public var lastObservation: WxStationObservation?
    /// Time of the last successful fetch that should have contained the station.
    public var lastCheckedS: Int64
    /// Checking time without a new report, s (see the file header).
    public var silentS: Int64
    /// Since when (observation time) the temperature has not changed.
    public var steadySinceS: Int64?
    // Track record (residual = station minus what its neighbours predict, °C).
    public var tests: Int
    public var lastTestS: Int64
    public var meanSquareC2: Double
    public var biasDayC: Double
    public var testsDay: Int
    public var biasNightC: Double
    public var testsNight: Int

    public var key: String { "\(network.rawValue):\(id)" }
}

/// What one successful fetch should have contained: the records of its network inside its box,
/// carrying its area tag, or among its requested ids.
public struct WxStationCoverage: Sendable {
    public var network: WxStationNetwork
    public var box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)?
    public var areaTag: String?
    public var stationIDs: Set<String>?

    public init(
        network: WxStationNetwork, box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? = nil,
        areaTag: String? = nil, stationIDs: Set<String>? = nil
    ) {
        self.network = network
        self.box = box
        self.areaTag = areaTag
        self.stationIDs = stationIDs
    }

    func expects(_ r: WxStationRecord) -> Bool {
        guard r.network == network else { return false }
        if let stationIDs {
            return stationIDs.contains(r.id)
        }
        if let areaTag {
            return r.areaTag == areaTag
        }
        if let b = box {
            return r.lat >= b.minLat && r.lat <= b.maxLat && r.lon >= b.minLon && r.lon <= b.maxLon
        }
        return true
    }
}

/// The catalog of stations (see the file header).
public struct WxStationCatalog: Sendable, Equatable, Codable {
    /// A station silent for this much checking time is dropped, s (3 days).
    public static let silenceLimitS: Int64 = 72 * 3600
    /// The most one check adds to a silence clock, s (time with the app closed never counts).
    public static let maxSilenceStepS: Int64 = 3600
    /// Most records kept (the least recently checked go first).
    public static let maxRecords = 6000
    /// At most one test per station per this interval, s.
    public static let testIntervalS: Int64 = 9 * 60
    /// Tests before a station leaves probation.
    public static let probationTests = 6
    /// Error (°C) up to which a station keeps full weight, and from which it is excluded.
    public static let fullWeightErrorC = 1.5
    public static let excludeErrorC = 8.0
    /// A 0.1 °C sensor unchanged this long is stuck, s.
    public static let stuckAfterS: Int64 = 8 * 3600
    /// EWMA memory of the track record (weight of a new test once warmed up).
    static let alpha = 0.08
    /// Residuals are clamped to this before they enter the record, °C.
    static let maxResidualC = 15.0

    public private(set) var records: [String: WxStationRecord] = [:]

    public init() {}

    // MARK: - Fetches

    /// Records a successful fetch at `nowS`: every report updates (or creates) its record, and
    /// every other record the fetch should have contained advances its silence clock.
    public mutating func recordFetch(
        _ observations: [WxStationObservation], coverage: WxStationCoverage, nowS: Int64
    ) {
        var reported: Set<String> = []
        for obs in observations where obs.network == coverage.network {
            let key = obs.key
            reported.insert(key)
            let obsTime = obs.obsTimeS ?? nowS
            if var r = records[key] {
                let isNew = obsTime > r.lastReportS
                if isNew {
                    if let prev = r.lastObservation, abs(prev.tempC - obs.tempC) < 0.05 {
                        r.steadySinceS = r.steadySinceS ?? r.lastReportS
                    } else {
                        r.steadySinceS = nil
                    }
                    r.lastReportS = obsTime
                    r.silentS = 0
                    r.lastObservation = obs
                } else {
                    r.silentS += step(r.lastCheckedS, nowS)
                }
                r.name = obs.name ?? r.name
                r.lat = obs.lat
                r.lon = obs.lon
                if let elev = obs.elevM, elev.isFinite {
                    r.elevM = elev
                    r.elevFromDEM = false
                }
                r.areaTag = coverage.areaTag ?? r.areaTag
                r.lastCheckedS = max(r.lastCheckedS, nowS)  // a clock set back never rewinds it
                records[key] = r
            } else {
                records[key] = WxStationRecord(
                    network: obs.network, id: obs.id, name: obs.name, lat: obs.lat, lon: obs.lon,
                    elevM: obs.elevM, elevFromDEM: false, areaTag: coverage.areaTag, firstSeenS: nowS,
                    lastReportS: obsTime, lastObservation: obs, lastCheckedS: nowS, silentS: 0,
                    steadySinceS: nil, tests: 0, lastTestS: 0, meanSquareC2: 0, biasDayC: 0, testsDay: 0,
                    biasNightC: 0, testsNight: 0)
            }
        }
        for (key, var r) in records where !reported.contains(key) && coverage.expects(r) {
            r.silentS += step(r.lastCheckedS, nowS)
            r.lastCheckedS = max(r.lastCheckedS, nowS)
            records[key] = r
        }
        prune()
    }

    private func step(_ lastCheckedS: Int64, _ nowS: Int64) -> Int64 {
        max(0, min(Self.maxSilenceStepS, nowS - lastCheckedS))
    }

    /// Drops the stations silent for `silenceLimitS` of checking, then the least recently
    /// checked beyond `maxRecords`.
    public mutating func prune() {
        records = records.filter { $0.value.silentS < Self.silenceLimitS }
        if records.count > Self.maxRecords {
            let keep = records.values.sorted { $0.lastCheckedS > $1.lastCheckedS }.prefix(Self.maxRecords)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
        }
    }

    // MARK: - Testing

    /// Updates the track records from leave-one-out residuals (°C, by key) of fresh reports.
    public mutating func recordTests(_ residuals: [String: Double], nowS: Int64) {
        for (key, raw) in residuals {
            guard var r = records[key], raw.isFinite, nowS - r.lastTestS >= Self.testIntervalS else { continue }
            let e = max(-Self.maxResidualC, min(Self.maxResidualC, raw))
            let a = max(Self.alpha, 1.0 / Double(r.tests + 1))
            r.meanSquareC2 += a * (e * e - r.meanSquareC2)
            if WxGeo.sunIsUp(lat: r.lat, lon: r.lon, t: nowS) {
                r.biasDayC += max(Self.alpha, 1.0 / Double(r.testsDay + 1)) * (e - r.biasDayC)
                r.testsDay += 1
            } else {
                r.biasNightC += max(Self.alpha, 1.0 / Double(r.testsNight + 1)) * (e - r.biasNightC)
                r.testsNight += 1
            }
            r.tests += 1
            r.lastTestS = nowS
            records[key] = r
        }
    }

    /// Health 0...1 of a station (see the file header); 1 for a station not in the catalog.
    public func health(_ key: String, nowS: Int64) -> Double {
        assessment(key, nowS: nowS).health
    }

    /// Why a station has the weight it has.
    public enum HealthState: String, Sendable, Equatable {
        /// Fewer than `probationTests` tests: weight rising from 0.6.
        case probation
        /// Error within `fullWeightErrorC`: full weight.
        case good
        /// Error above `fullWeightErrorC`: weight reduced.
        case reduced
        /// Error of `excludeErrorC` or more: not used (still tested, so it can recover).
        case excluded
        /// Reading unchanged for `stuckAfterS`: not used until it changes.
        case stuck
        /// Not in the catalog.
        case unknown
    }

    /// A station's health (the weight multiplier), its state, and the error behind it.
    public struct Assessment: Sendable, Equatable {
        public let health: Double
        public let state: HealthState
        /// sqrt(bias^2 + scatter^2) of the current day/night half, °C; nil before 3 tests.
        public let errorC: Double?
        /// The bias used (the current half's once it has 3 tests, else the mean), °C; nil before 3 tests.
        public let biasC: Double?
    }

    public func assessment(_ key: String, nowS: Int64) -> Assessment {
        guard let r = records[key] else { return Assessment(health: 1.0, state: .unknown, errorC: nil, biasC: nil) }
        if let since = r.steadySinceS, r.network != .metar, r.lastReportS - since >= Self.stuckAfterS {
            // METARs report whole degrees, so a steady METAR is not suspicious
            return Assessment(health: 0.0, state: .stuck, errorC: nil, biasC: nil)
        }
        let probation = min(1.0, 0.6 + 0.4 * Double(r.tests) / Double(Self.probationTests))
        guard r.tests >= 3 else { return Assessment(health: probation, state: .probation, errorC: nil, biasC: nil) }
        let n = Double(r.testsDay + r.testsNight)
        let meanBias = n > 0 ? (r.biasDayC * Double(r.testsDay) + r.biasNightC * Double(r.testsNight)) / n : 0
        let scatter2 = max(0.0, r.meanSquareC2 - meanBias * meanBias)
        let isDay = WxGeo.sunIsUp(lat: r.lat, lon: r.lon, t: nowS)
        let phaseTests = isDay ? r.testsDay : r.testsNight
        let bias = phaseTests >= 3 ? (isDay ? r.biasDayC : r.biasNightC) : meanBias
        let error = sqrt(scatter2 + bias * bias)
        if error >= Self.excludeErrorC {
            return Assessment(health: 0.0, state: .excluded, errorC: error, biasC: bias)
        }
        let excess = max(0.0, error - Self.fullWeightErrorC) / Self.fullWeightErrorC
        let state: HealthState = r.tests < Self.probationTests ? .probation : (excess > 0 ? .reduced : .good)
        return Assessment(health: probation / (1.0 + excess * excess), state: state, errorC: error, biasC: bias)
    }

    /// One station as the Settings list shows it.
    public struct Nearby: Sendable, Equatable, Identifiable {
        public let record: WxStationRecord
        public let distanceKm: Double
        public let assessment: Assessment
        public var id: String { record.key }
    }

    /// The catalogued stations within `radiusKm` of a point, nearest first.
    public func nearby(lat: Double, lon: Double, radiusKm: Double, nowS: Int64) -> [Nearby] {
        records.values.compactMap { r -> Nearby? in
            let d = WxGeo.distanceKm(aLat: lat, aLon: lon, bLat: r.lat, bLon: r.lon)
            guard d.isFinite, d <= radiusKm else { return nil }
            return Nearby(record: r, distanceKm: d, assessment: assessment(r.key, nowS: nowS))
        }
        .sorted { $0.distanceKm != $1.distanceKm ? $0.distanceKm < $1.distanceKm : $0.id < $1.id }
    }

    /// Forgets every station (they are found again on the next refresh, on probation).
    public mutating func removeAll() {
        records.removeAll()
    }

    // MARK: - Enrichment and fallback

    /// The reports with the catalog's elevation and name where the report has none.
    public func enrich(_ observations: [WxStationObservation]) -> [WxStationObservation] {
        observations.map { obs in
            guard let r = records[obs.key] else { return obs }
            var o = obs
            if o.elevM == nil {
                o.elevM = r.elevM
            }
            if o.name == nil {
                o.name = r.name
            }
            return o
        }
    }

    /// Keys of catalogued stations without an elevation (to look up in the DEM).
    public func keysMissingElevation(_ observations: [WxStationObservation]) -> [String] {
        observations.compactMap { obs in
            guard obs.elevM == nil, let r = records[obs.key], r.elevM == nil else { return nil }
            return obs.key
        }
    }

    /// Sets a DEM elevation of a station whose network gives none.
    public mutating func setDEMElevation(_ elevM: Double, key: String) {
        guard elevM.isFinite, var r = records[key], r.elevM == nil || r.elevFromDEM else { return }
        r.elevM = elevM
        r.elevFromDEM = true
        records[key] = r
    }

    /// The newest reports of a network's stations inside a box no older than `maxAgeS`: the
    /// fallback when that network cannot be reached.
    public func cachedObservations(
        network: WxStationNetwork, box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double),
        nowS: Int64, maxAgeS: Int64 = 90 * 60
    ) -> [WxStationObservation] {
        records.values.compactMap { r in
            guard r.network == network, r.lat >= box.minLat, r.lat <= box.maxLat, r.lon >= box.minLon,
                  r.lon <= box.maxLon, nowS - r.lastReportS <= maxAgeS
            else {
                return nil
            }
            return r.lastObservation
        }
    }

    /// The catalogued stations of a network (e.g. the ids to request from a per-station API).
    public func stations(network: WxStationNetwork) -> [WxStationRecord] {
        records.values.filter { $0.network == network }
    }

    // MARK: - Persistence

    /// The catalog file, "<config>/weather/stations.json".
    public static func defaultPath(configDirectory: String) -> String {
        let base = configDirectory.hasSuffix("/") ? String(configDirectory.dropLast()) : configDirectory
        return "\(base)/weather/stations.json"
    }

    /// The catalog saved at `path`, or an empty one (missing, unreadable or corrupt file).
    public static func load(path: String) -> WxStationCatalog {
        guard !path.isEmpty,
              let data = try? FileIO.readBounded(path: path, maxBytes: 32 * 1024 * 1024),
              let catalog = try? JSONDecoder().decode(WxStationCatalog.self, from: data)
        else {
            return WxStationCatalog()
        }
        return catalog
    }

    /// Writes the catalog atomically (temp file, full fsync, rename).
    public func save(path: String) {
        guard !path.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileIO.writeAtomic(path: path, data: data)
    }
}
