// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Weights.swift - how much each forecast member is trusted, per variable
// group and forecast horizon. Port of src/blend/wx-weights.{h,c}.
//
// HEURISTIC (wx-weights.c:6-13): the weights are hand-chosen, NOT fitted to
// forecast-verification data. Every number, band edge and rule below is the C
// table verbatim; change them here and in the C code together, never one alone.
// Pure and deterministic: the weight depends only on the arguments (and any
// user-configured source/model multipliers when customized in Settings).

import Foundation
import Synchronization

/// User-configurable weight multipliers per provider (`nws`, `open-meteo`, `met-no`)
/// and per NWP model (`nws:nws`, `open-meteo:hrrr`, `open-meteo:nbm`, `open-meteo:ecmwf`,
/// `open-meteo:gfs`, `open-meteo:icon`, `open-meteo:gem`, `open-meteo:ukmo`,
/// `open-meteo:meteofrance`, `met-no:ecmwf`).
///
/// A multiplier of `1.0` preserves the exact heuristic baseline weight table.
/// Multipliers are clamped to `[0.0, 3.0]`.
public struct WxWeightMultipliers: Sendable, Equatable, Codable {
    public static let minMultiplier: Double = 0.0
    public static let maxMultiplier: Double = 3.0
    public static let defaultMultiplier: Double = 1.0

    /// Per-provider overall weight multipliers (`providerID -> multiplier`).
    public var sources: [String: Double]
    /// Per-model weight multipliers (`"providerID:modelID" -> multiplier`).
    public var models: [String: Double]

    public init(sources: [String: Double] = [:], models: [String: Double] = [:]) {
        self.sources = sources
        self.models = models
    }

    /// True when all multipliers equal `1.0` (the default baseline).
    public var isDefault: Bool {
        sources.values.allSatisfy { abs($0 - 1.0) < 1e-9 }
            && models.values.allSatisfy { abs($0 - 1.0) < 1e-9 }
    }

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMultiplier }
        return min(maxMultiplier, max(minMultiplier, (value * 100.0).rounded() / 100.0))
    }

    public func sourceMultiplier(for sourceID: String) -> Double {
        let key = String(Substring(sourceID.utf8.prefix(while: { $0 != 0 })))
        guard let v = sources[key], v.isFinite else { return Self.defaultMultiplier }
        return Self.clamp(v)
    }

    public mutating func setSourceMultiplier(_ value: Double, for sourceID: String) {
        let clamped = Self.clamp(value)
        if abs(clamped - Self.defaultMultiplier) < 1e-9 {
            sources.removeValue(forKey: sourceID)
        } else {
            sources[sourceID] = clamped
        }
    }

    public static func canonicalModelKey(sourceID: String, modelID: String) -> String {
        let src = String(Substring(sourceID.utf8.prefix(while: { $0 != 0 })))
        let mdl = String(Substring(modelID.utf8.prefix(while: { $0 != 0 })))
        if src == "nws" {
            return "nws:nws"
        }
        if src == "open-meteo" && mdl == "hrrr15" {
            return "open-meteo:hrrr"
        }
        return "\(src):\(mdl)"
    }

    public func modelMultiplier(sourceID: String, modelID: String) -> Double {
        let key = Self.canonicalModelKey(sourceID: sourceID, modelID: modelID)
        guard let v = models[key], v.isFinite else { return Self.defaultMultiplier }
        return Self.clamp(v)
    }

    public mutating func setModelMultiplier(_ value: Double, sourceID: String, modelID: String) {
        let key = Self.canonicalModelKey(sourceID: sourceID, modelID: modelID)
        let clamped = Self.clamp(value)
        if abs(clamped - Self.defaultMultiplier) < 1e-9 {
            models.removeValue(forKey: key)
        } else {
            models[key] = clamped
        }
    }

    /// Combined source × model multiplier for `(sourceID, modelID)`.
    public func combinedMultiplier(sourceID: String, modelID: String) -> Double {
        sourceMultiplier(for: sourceID) * modelMultiplier(sourceID: sourceID, modelID: modelID)
    }

    /// Default path for persisted custom weights (`<configDirectory>/weather/weights.json`).
    public static func defaultPath(configDirectory: String) -> String {
        let base = configDirectory.hasSuffix("/") ? String(configDirectory.dropLast()) : configDirectory
        return "\(base)/weather/weights.json"
    }

    public static func load(fromPath path: String) -> WxWeightMultipliers {
        guard !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode(WxWeightMultipliers.self, from: data) else {
            return WxWeightMultipliers()
        }
        return decoded
    }

    public func save(toPath path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Descriptive metadata for each forecast model row in the weight table, exposed for
/// the Settings → Weights UI and technical documentation.
public struct WxModelWeightDescriptor: Sendable, Identifiable, Equatable {
    public var id: String { "\(sourceID):\(modelID)" }
    public let sourceID: String
    public let sourceName: String
    public let modelID: String
    public let displayName: String
    public let resolutionSummary: String
    public let coverageSummary: String
    public let usOnly: Bool
    public let limitedTo48h: Bool
    /// Baseline US weights `[WxVar][band 0..3]`.
    public let usWeights: [[Double]]
    /// Baseline World weights `[WxVar]`.
    public let worldWeights: [Double]
}

/// The variable groups that share one set of weights (WxVar,
/// src/blend/wx-weights.h:24-32). `.temp` covers temperature and apparent
/// temperature, `.wind` wind speed and gusts; the others are single variables.
/// The raw values are the C ordinals (the column order of the table).
public enum WxVar: Int, CaseIterable, Sendable {
    case temp = 0
    case wind = 1
    case cloud = 2
    case humidity = 3
    case precipMm = 4
    case precipProb = 5

    /// WX_VAR_COUNT: the number of groups (not a valid group itself).
    public static let count = 6
}

/// The member weights table and its lookup (wx_weight_for).
public enum WxWeights {
    /// WX_WEIGHT_UNKNOWN (wx-weights.h:35): the weight of a member whose
    /// source:model pair is not in the table, whatever the variable, horizon
    /// and region.
    public static let unknownWeight = 1.0

    /// WX_WEIGHT_HRRR_MAX_HORIZON_H (wx-weights.h:38): HRRR weighs 0 for a
    /// horizon above this many hours (exactly 48 h is still weighted).
    public static let hrrrMaxHorizonH = 48.0

    /// Where a lookup's weight came from.
    public enum Origin: Sendable, Equatable {
        /// The (source, model) pair hit a row of the table (find_row != NULL).
        case tableRow
        /// No row matched: the pair is unknown and weighs `unknownWeight`
        /// (unless the horizon is NaN, which weighs 0 first).
        case fallback
    }

    /// The result of `lookup`: the weight and whether the pair hit a real row.
    public struct Lookup: Sendable, Equatable {
        /// Exactly what `weight(...)` returns for the same arguments.
        public let weight: Double
        /// `.tableRow` when the pair matched a row of the table, else `.fallback`.
        public let origin: Origin
    }

    /// Thread-safe storage for active user-configured source and model weight multipliers.
    private static let activeMultipliersMutex = Mutex(WxWeightMultipliers())

    /// Active user-configured source and model weight multipliers.
    /// Defaults to all `1.0` (`isDefault == true`), preserving the exact baseline table.
    public static var activeMultipliers: WxWeightMultipliers {
        get { activeMultipliersMutex.withLock { $0 } }
        set { activeMultipliersMutex.withLock { $0 = newValue } }
    }

    /// Baseline heuristic table weight without any user multipliers applied.
    public static func baseWeight(
        sourceID: String, modelID: String, variable: WxVar, horizonH: Double, usRegion: Bool
    ) -> Double {
        if horizonH.isNaN {
            return 0.0
        }
        guard let row = findRow(sourceID: sourceID, modelID: modelID) else {
            return unknownWeight
        }
        if row.usOnly && !usRegion {
            return 0.0
        }
        if row.limitedTo48h && horizonH > hrrrMaxHorizonH {
            return 0.0
        }
        return usRegion ? row.us[variable.rawValue][bandOf(horizonH)] : row.world[variable.rawValue]
    }

    /// wx_weight_for (wx-weights.c:147-166), scaled by `activeMultipliers` when customized.
    ///
    /// - Parameters:
    ///   - sourceID: provider id of the member, e.g. "open-meteo", "nws", "met-no".
    ///   - modelID: model id of the member, e.g. "ecmwf", "hrrr", "nws".
    ///   - variable: the variable group.
    ///   - horizonH: (valid time - now) / 3600. Negative counts as band 0,
    ///     +infinity as the last band; NaN is "unknown" and weighs 0.
    ///   - usRegion: true when the place is in the US region.
    /// - Returns: a finite weight in [0, 5] for default multipliers (or scaled by custom multipliers); 0 means "exclude".
    ///
    /// The ids are compared byte for byte as C strings (strcmp: no case
    /// folding, no Unicode equivalence, read up to the first NUL). Rules, in
    /// the C order: NaN horizon -> 0; unknown pair -> `unknownWeight`; a
    /// US-only row outside the US region -> 0; a 48-hour row above
    /// `hrrrMaxHorizonH` -> 0; otherwise the US band value inside the US
    /// region, else the flat world value.
    public static func weight(
        sourceID: String, modelID: String, variable: WxVar, horizonH: Double, usRegion: Bool
    ) -> Double {
        let base = baseWeight(sourceID: sourceID, modelID: modelID, variable: variable, horizonH: horizonH, usRegion: usRegion)
        guard base > 0 else { return 0.0 }
        let mults = activeMultipliers
        if mults.isDefault {
            return base
        }
        return base * mults.combinedMultiplier(sourceID: sourceID, modelID: modelID)
    }

    /// Descriptive metadata for all 10 table rows so the Settings UI can inspect and tune them.
    public static var modelDescriptors: [WxModelWeightDescriptor] {
        [
            WxModelWeightDescriptor(
                sourceID: "nws", sourceName: "National Weather Service", modelID: "nws",
                displayName: "NOAA NWS Forecaster Grid",
                resolutionSummary: "2.5 km NDFD human-edited grid",
                coverageSummary: "US, territories & coastal waters",
                usOnly: true, limitedTo48h: false,
                usWeights: rows[0].us, worldWeights: rows[0].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "hrrr",
                displayName: "NOAA HRRR (Hourly & 15-min Nowcast)",
                resolutionSummary: "3 km convection-allowing rapid refresh",
                coverageSummary: "CONUS (0–48 h horizon)",
                usOnly: true, limitedTo48h: true,
                usWeights: rows[1].us, worldWeights: rows[1].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "nbm",
                displayName: "NOAA National Blend of Models (NBM)",
                resolutionSummary: "2.5 km calibrated multi-model ensemble",
                coverageSummary: "CONUS & Alaska",
                usOnly: true, limitedTo48h: false,
                usWeights: rows[2].us, worldWeights: rows[2].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "ecmwf",
                displayName: "ECMWF IFS (Open-Meteo)",
                resolutionSummary: "9 km / 0.25° global spectral model",
                coverageSummary: "Worldwide",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[3].us, worldWeights: rows[3].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "gfs",
                displayName: "NOAA GFS Seamless",
                resolutionSummary: "13–25 km global spectral model",
                coverageSummary: "Worldwide",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[4].us, worldWeights: rows[4].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "icon",
                displayName: "DWD ICON Seamless",
                resolutionSummary: "2–13 km icosahedral non-hydrostatic",
                coverageSummary: "Worldwide (nest in Europe)",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[5].us, worldWeights: rows[5].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "gem",
                displayName: "ECCC GEM Seamless",
                resolutionSummary: "2.5–15 km Canadian global/regional",
                coverageSummary: "Worldwide (nest in North America)",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[6].us, worldWeights: rows[6].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "ukmo",
                displayName: "UK Met Office Unified Model",
                resolutionSummary: "2–10 km global/regional seamless",
                coverageSummary: "Worldwide",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[7].us, worldWeights: rows[7].world
            ),
            WxModelWeightDescriptor(
                sourceID: "open-meteo", sourceName: "Open-Meteo", modelID: "meteofrance",
                displayName: "Météo-France ARPEGE / AROME",
                resolutionSummary: "1.5–10 km stretched-grid spectral",
                coverageSummary: "Worldwide (nest in Europe)",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[8].us, worldWeights: rows[8].world
            ),
            WxModelWeightDescriptor(
                sourceID: "met-no", sourceName: "MET Norway", modelID: "ecmwf",
                displayName: "MET Norway Locationforecast 2.0",
                resolutionSummary: "1 km Nordic MEPS + 9 km ECMWF IFS",
                coverageSummary: "Worldwide",
                usOnly: false, limitedTo48h: false,
                usWeights: rows[9].us, worldWeights: rows[9].world
            ),
        ]
    }

    /// The weight together with whether the (source, model) pair hit a real
    /// row of the table or the unknown-pair fallback. `weight` equals
    /// `weight(sourceID:modelID:variable:horizonH:usRegion:)`.
    public static func lookup(
        sourceID: String, modelID: String, variable: WxVar, horizonH: Double, usRegion: Bool
    ) -> Lookup {
        let origin: Origin = findRow(sourceID: sourceID, modelID: modelID) == nil ? .fallback : .tableRow
        let w = weight(sourceID: sourceID, modelID: modelID, variable: variable, horizonH: horizonH, usRegion: usRegion)
        return Lookup(weight: w, origin: origin)
    }

    /// True when the (source, model) pair hits a real row of the table
    /// ("hrrr15" of "open-meteo" is the "hrrr" row; "nws" matches any model).
    public static func hasTableRow(sourceID: String, modelID: String) -> Bool {
        findRow(sourceID: sourceID, modelID: modelID) != nil
    }

    // MARK: - The table (wx-weights.c:22-87)

    /// One member of the table (Row, wx-weights.c:31-38).
    private struct Row: Sendable {
        let sourceID: String
        /// nil: any model of the source.
        let modelID: String?
        /// Weight 0 outside the US region.
        let usOnly: Bool
        /// Weight 0 beyond `hrrrMaxHorizonH`.
        let limitedTo48h: Bool
        /// Weights in the US region: [variable][band H0, H1, H2, H3].
        let us: [[Double]]
        /// Flat weights elsewhere, per variable (unused when usOnly).
        let world: [Double]
    }

    /// FLAT(w): the same weight in every band (wx-weights.c:41).
    private static func flat(_ w: Double) -> [Double] { [w, w, w, w] }

    /// BANDS(a, b, c, d): band weights H0/H1/H2/H3 (wx-weights.c:43).
    private static func bands(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> [Double] { [a, b, c, d] }

    /// WORLD_MAIN(w) = WORLD(w, w, w, 1.0, w, 1.0) (wx-weights.c:48).
    private static func worldMain(_ w: Double) -> [Double] { [w, w, w, 1.0, w, 1.0] }

    /// The rows in the C order (first match wins). Variable order TEMP, WIND,
    /// CLOUD, HUMIDITY, PRECIP_MM, PRECIP_PROB (wx-weights.c:45).
    private static let rows: [Row] = [
        // NWS forecaster grid: US only (any model id). (wx-weights.c:52-54)
        Row(sourceID: "nws", modelID: nil, usOnly: true, limitedTo48h: false,
            us: [bands(4, 4, 4.5, 5), flat(3), flat(3), flat(1), bands(2, 3, 4, 4), flat(5)],
            world: [0, 0, 0, 0, 0, 0]),
        // HRRR (hourly) and, by alias in findRow, the 15-minute product. (:56-59)
        Row(sourceID: "open-meteo", modelID: "hrrr", usOnly: true, limitedTo48h: true,
            us: [bands(3, 3, 0.5, 0), bands(3, 3, 0.5, 0), bands(2, 2, 0.5, 0), flat(1), bands(4, 4, 1, 0),
                 flat(1)],
            world: [0, 0, 0, 0, 0, 0]),
        // NOAA National Blend of Models: CONUS only. (:61-63)
        Row(sourceID: "open-meteo", modelID: "nbm", usOnly: true, limitedTo48h: false,
            us: [bands(2.5, 3, 3, 2), flat(2), flat(2), flat(1), flat(2), flat(2)],
            world: [0, 0, 0, 0, 0, 0]),
        // (:64-66)
        Row(sourceID: "open-meteo", modelID: "ecmwf", usOnly: false, limitedTo48h: false,
            us: [bands(1, 1.5, 2, 2), flat(1.5), flat(1.5), flat(1), bands(1, 2, 2.5, 2.5), flat(1)],
            world: worldMain(3.0)),
        // (:67-69)
        Row(sourceID: "open-meteo", modelID: "gfs", usOnly: false, limitedTo48h: false,
            us: [bands(0.5, 1, 1, 1), flat(1), flat(1), flat(1), flat(1), flat(1)],
            world: worldMain(1.5)),
        // (:70-72)
        Row(sourceID: "open-meteo", modelID: "icon", usOnly: false, limitedTo48h: false,
            us: [bands(0.5, 1, 1, 1), flat(1), flat(1), flat(1), bands(1, 1, 1.5, 1.5), flat(1)],
            world: worldMain(2.5)),
        // (:73-75)
        Row(sourceID: "open-meteo", modelID: "gem", usOnly: false, limitedTo48h: false,
            us: [flat(0.5), flat(1), flat(1), flat(1), flat(1), flat(1)],
            world: worldMain(1.5)),
        // Not in the design's US table: same as in the rest of the world. (:77-79)
        Row(sourceID: "open-meteo", modelID: "ukmo", usOnly: false, limitedTo48h: false,
            us: [flat(2), flat(2), flat(2), flat(1), flat(2), flat(1)],
            world: worldMain(2.0)),
        // (:80-82)
        Row(sourceID: "open-meteo", modelID: "meteofrance", usOnly: false, limitedTo48h: false,
            us: [flat(2), flat(2), flat(2), flat(1), flat(2), flat(1)],
            world: worldMain(2.0)),
        // MET Norway worldwide product (ECMWF-derived): no probability of its own. (:84-86)
        Row(sourceID: "met-no", modelID: "ecmwf", usOnly: false, limitedTo48h: false,
            us: [flat(0.5), flat(1), flat(1), flat(1), flat(1), flat(1)],
            world: worldMain(1.5)),
    ]

    // MARK: - Lookup helpers

    /// strcmp(a, b) == 0 for a Swift string and a table id: the UTF-8 bytes
    /// of `a` up to its first NUL equal the bytes of `b` (table ids hold no NUL).
    private static func cStringEquals(_ a: String, _ b: String) -> Bool {
        a.utf8.prefix(while: { $0 != 0 }).elementsEqual(b.utf8)
    }

    /// find_row (wx-weights.c:106-118): "hrrr15" of "open-meteo" is an alias
    /// of "hrrr"; the first row whose source matches and whose model is nil
    /// (any) or equal wins; nil for an unknown pair.
    private static func findRow(sourceID: String, modelID: String) -> Row? {
        var model = modelID
        if cStringEquals(sourceID, "open-meteo") && cStringEquals(modelID, "hrrr15") {
            model = "hrrr"
        }
        for row in rows {
            if !cStringEquals(sourceID, row.sourceID) {
                continue
            }
            if let rowModel = row.modelID {
                if cStringEquals(model, rowModel) {
                    return row
                }
            } else {
                return row
            }
        }
        return nil
    }

    /// band_of (wx-weights.c:134-144): 0..3 for H0 [0,3), H1 [3,18), H2
    /// [18,72), H3 from 72 h; negative horizons are band 0. Not called with NaN.
    private static func bandOf(_ horizonH: Double) -> Int {
        if horizonH < 3.0 {
            return 0
        }
        if horizonH < 18.0 {
            return 1
        }
        if horizonH < 72.0 {
            return 2
        }
        return 3
    }
}
