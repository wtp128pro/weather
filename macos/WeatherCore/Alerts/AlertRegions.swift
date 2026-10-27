// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertRegions.swift - where a MeteoAlarm warning applies: the bundled region
// table (Resources/MeteoAlarmRegions.json, built by
// scripts/alerts/build_meteoalarm_regions.py; its README documents the
// format), point-in-polygon on it and on a warning's own polygons, and the
// country feeds (feeds.meteoalarm.org/api/v1/warnings/feeds-<slug>). Pure and
// nonisolated: the alerts service calls it off the main actor.
//
// Matching, per CAP area of a warning: an area that carries its own polygons
// is decided by them alone; otherwise by its geocodes, each looked up on both
// its type (the CAP valueName: EMMA_ID, NUTS3, NUTS2) and its code. The one
// alias: Met Eireann files every Irish land warning under FIPS 10-4 county
// codes (FIPS EI01-EI31, 26 codes with gaps), which the geocodes file does not
// carry, so a FIPS code in fipsAliases is looked up as the EMMA_ID region of
// the same county (code to code, from a fixed cited table). Any other code the
// table does not carry (an unlisted FIPS code, DE WARNCELLID, CZ CISORP, a
// region newer than the bundled edition) never matches: there is no
// nearest-region, country-wide or area-name fallback, and a warning that
// cannot be placed is dropped. A warning matches a place when any of its
// areas does.
//
// Coverage: in a country with bundled regions a place is covered only when
// it lies inside a region of that country whose geocode type, code series or
// code the country's feed actually files (filedRegions; for Ireland also a
// county region a filed FIPS code aliases to); anywhere else MeteoAlarm says
// nothing (not "no alerts"), since none of that feed's warnings could be
// placed there. So an Irish place is covered inside its county region (land
// warnings, via FIPS) or an EI8xx sea area (marine warnings), not inside only
// an IE80x offshore region; a French, Bulgarian, Romanian, Macedonian or
// Hungarian point inside only an EMMA_ID region is not (those feeds file
// NUTS), nor French overseas NUTS3, nor a Belgian place outside the ten codes
// the Belgian feed files every day, nor a Croatian place inside only a
// superseded NUTS 2013 county (HR041-HR04E). The polygon-only feeds (EE,
// LU, SE, CH, UA, GB, IL) file every warning with its own polygon and have no
// regions here: a place there is covered by its country code, and their
// warnings match by those polygons only. DE and NO are not MeteoAlarm
// countries here (DWD via Bright Sky and MET Norway answer for them, never
// merged).
//
// Geometry: the table's points are [lon, lat] (GeoJSON order), a CAP polygon
// is "lat,lon lat,lon ..."; even-odd ray casting over all rings of a polygon
// (ring 0 outer, further rings holes), a region contains a point when any of
// its polygons does. Simplification (0.004 deg) can move a coast or border by
// a few hundred metres; points that close may miss or land in the neighbour,
// accepted without buffering. Regions may overlap (marine EMMA regions, both
// Croatian NUTS editions).
//
// Data: MeteoAlarm geocodes (Data provided by EUMETNET members, CC BY 4.0);
// NUTS geometry (c) EuroGeographics for the administrative boundaries.

import Foundation
import Synchronization

/// The MeteoAlarm region table, warning-area matching and country feeds.
public enum WxAlertRegions {
    /// One point, WGS 84 degrees.
    public struct Point: Sendable, Equatable {
        public let lat: Double
        public let lon: Double

        public init(lat: Double, lon: Double) {
            self.lat = lat
            self.lon = lon
        }
    }

    /// A CAP geocode as a feed files it: `type` is the valueName ("EMMA_ID", "NUTS3", "NUTS2",
    /// "FIPS", ...), `code` the value; both are matched exactly.
    public struct Geocode: Sendable, Hashable {
        public let type: String
        public let code: String

        public init(type: String, code: String) {
            self.type = type
            self.code = code
        }
    }

    /// One CAP area of a warning.
    public struct Area: Sendable, Equatable {
        /// The area's own polygons, each one ring (CAP polygons have no holes); empty when it
        /// gave none. Leave out a polygon `capPolygon(_:)` cannot read: a present polygon decides
        /// the area alone.
        public let polygons: [[Point]]
        /// The area's geocodes; consulted only when `polygons` is empty.
        public let geocodes: [Geocode]

        public init(polygons: [[Point]], geocodes: [Geocode]) {
            self.polygons = polygons
            self.geocodes = geocodes
        }
    }

    // MARK: - Country feeds

    /// ISO 3166-1 alpha-2 code -> MeteoAlarm feed slug: the 38 api/v1 feeds less DE and NO
    /// (other issuers). Slugs as validated live on 2026-10-26.
    static let feedSlugs: [String: String] = [
        "AT": "austria", "BA": "bosnia-herzegovina", "BE": "belgium", "BG": "bulgaria",
        "CY": "cyprus", "CZ": "czechia", "DK": "denmark", "ES": "spain", "FI": "finland",
        "FR": "france", "GR": "greece", "HR": "croatia", "HU": "hungary", "IE": "ireland",
        "IS": "iceland", "IT": "italy", "LT": "lithuania", "LV": "latvia", "MD": "moldova",
        "ME": "montenegro", "MK": "republic-of-north-macedonia", "MT": "malta",
        "NL": "netherlands", "PL": "poland", "PT": "portugal", "RO": "romania", "RS": "serbia",
        "SI": "slovenia", "SK": "slovakia",
        "EE": "estonia", "LU": "luxembourg", "SE": "sweden", "CH": "switzerland", "UA": "ukraine",
        "GB": "united-kingdom", "IL": "israel",
    ]

    /// The feeds that place every warning by its own polygon; the table has no region for them.
    static let polygonOnlyCountries: Set<String> = ["EE", "LU", "SE", "CH", "UA", "GB", "IL"]

    /// Met Eireann's FIPS 10-4 county codes -> the EMMA_ID region of the same county. Met Eireann
    /// files every Irish land warning under these codes only (the 26 traditional counties: EI01-EI31
    /// with gaps EI05, EI08, EI09, EI17, EI28), and the geocodes file carries the counties only as
    /// EMMA_ID IE006-IE031 ("County Carlow" ...). Each pair: FIPS PUB 10-4 (NIST, 1995, "EI IRELAND,
    /// county", pp. 23-24), matched to the geocodes file's region name, and consistent with every
    /// FIPS-only area of the Irish feed (its areaDesc names exactly the counties its codes alias
    /// to); sources in scripts/alerts/README.md. A FIPS code not listed (a gap, a later GEC city or
    /// administrative-county code EI32-EI44, another country's) never matches.
    static let fipsAliases: [String: String] = [
        "EI01": "IE020", "EI02": "IE027", "EI03": "IE014", "EI04": "IE007",  // Carlow, Cavan, Clare, Cork
        "EI06": "IE018", "EI07": "IE012", "EI10": "IE015", "EI11": "IE008",  // Donegal, Dublin, Galway, Kerry
        "EI12": "IE030", "EI13": "IE021", "EI14": "IE029", "EI15": "IE022",  // Kildare, Kilkenny, Leitrim, Laois
        "EI16": "IE013", "EI18": "IE025", "EI19": "IE019", "EI20": "IE016",  // Limerick, Longford, Louth, Mayo
        "EI21": "IE023", "EI22": "IE031", "EI23": "IE028", "EI24": "IE026",  // Meath, Monaghan, Offaly, Roscommon
        "EI25": "IE017", "EI26": "IE006", "EI27": "IE009", "EI29": "IE024",  // Sligo, Tipperary, Waterford, Westmeath
        "EI30": "IE010", "EI31": "IE011",                                    // Wexford, Wicklow
    ]

    /// The bundled key a warning's geocode is looked up under: a FIPS code its EMMA_ID alias
    /// (`fipsAliases`), nil when it has none; any other geocode itself.
    static func tableKey(_ geocode: Geocode) -> Geocode? {
        guard geocode.type == "FIPS" else {
            return geocode
        }
        return fipsAliases[geocode.code].map { Geocode(type: "EMMA_ID", code: $0) }
    }

    /// The codes of one geocode type that a feed files (`filedRegions`).
    enum FiledCodes: Sendable, Equatable {
        /// Every code of the type.
        case all
        /// The codes in these series (a series is a code less its last two characters).
        case series([String])
        /// Exactly these codes.
        case codes(Set<String>)

        func contains(_ code: String) -> Bool {
            switch self {
            case .all: true
            case .series(let prefixes): prefixes.contains { code.hasPrefix($0) }
            case .codes(let codes): codes.contains(code)
            }
        }
    }

    /// The bundled regions that count as coverage, per country with regions here: geocode type ->
    /// the codes of it the country's feed files ("FIPS": the regions those codes alias to,
    /// `fipsAliases`). Derived from the 38 api/v1 feeds as recorded on 2026-10-26 (history from
    /// 2026-10-21; full UTC days 2026-10-22 to 25), by these rules (scripts/alerts/README.md tells
    /// how to re-derive them): (1) a feed with no warning recorded (CY, IS, MT, SK) is taken to
    /// file EMMA_ID, the only type carried for it; (2) a feed that files every area by its own
    /// polygon (SI) counts its regions as its footprint; (3) otherwise a type counts when the feed
    /// filed one of its codes, limited to the series filed when a series of 4 or more codes is
    /// filed in full beside one never filed; (4) a feed that files the same codes on every full
    /// day, Green included, counts exactly those codes; (5) the codes of a superseded NUTS edition
    /// the feed never files, beside a current edition it files in full, do not count. Hence FR,
    /// BG, RO and MK count NUTS3 only and HU NUTS2 only (their EMMA_ID regions never filed); FR
    /// none of its overseas NUTS3 (FRA10-FRA50); IE its EI8xx sea areas and, through FIPS (all 26
    /// county codes filed), its 26 county regions, not its IE80x offshore regions; HR only its
    /// HR8xx sea areas under EMMA_ID (it files land under NUTS3 and EMMA_ID codes newer than the
    /// table) and, by rule 5, its 21 NUTS 2021 counties, not the 14 NUTS 2013 codes HR041-HR04E
    /// (so Stara Gradiska, inside only HR04A of them, is not covered); BE only EMMA_ID BE004
    /// (Brabant) and BE801 (coast) and its eight provincial NUTS2 codes it files daily, its eight
    /// other EMMA_ID regions and BE10, BE24 and BE31 being never filed (so Diest or Nivelles is not
    /// covered). Rule 4 also holds for BG, DK and HU, whose daily set is every code counted already.
    static let filedRegions: [String: [String: FiledCodes]] = [
        "AT": ["EMMA_ID": .all], "BA": ["EMMA_ID": .all],
        "BE": ["EMMA_ID": .codes(["BE004", "BE801"]),
               "NUTS2": .codes(["BE21", "BE22", "BE23", "BE25", "BE32", "BE33", "BE34", "BE35"])],
        "BG": ["NUTS3": .all], "CY": ["EMMA_ID": .all], "CZ": ["EMMA_ID": .all], "DK": ["EMMA_ID": .all],
        "ES": ["EMMA_ID": .all], "FI": ["EMMA_ID": .all],
        "FR": ["NUTS3": .series(["FR1", "FR2", "FR3", "FR4", "FR5", "FR6", "FR7", "FR8"])],
        "GR": ["EMMA_ID": .all],
        "HR": ["EMMA_ID": .series(["HR8"]),
               "NUTS3": .codes(["HR021", "HR022", "HR023", "HR024", "HR025", "HR026", "HR027", "HR028",
                                "HR031", "HR032", "HR033", "HR034", "HR035", "HR036", "HR037", "HR050",
                                "HR061", "HR062", "HR063", "HR064", "HR065"])],
        "HU": ["NUTS2": .all], "IE": ["EMMA_ID": .series(["EI8"]), "FIPS": .all],
        "IS": ["EMMA_ID": .all], "IT": ["EMMA_ID": .all],
        "LT": ["EMMA_ID": .all], "LV": ["EMMA_ID": .all], "MD": ["EMMA_ID": .all], "ME": ["EMMA_ID": .all],
        "MK": ["NUTS3": .all], "MT": ["EMMA_ID": .all], "NL": ["EMMA_ID": .all], "PL": ["EMMA_ID": .all],
        "PT": ["EMMA_ID": .all], "RO": ["NUTS3": .all], "RS": ["EMMA_ID": .all], "SI": ["EMMA_ID": .all],
        "SK": ["EMMA_ID": .all],
    ]

    /// Whether a bundled region of `country` counts as its coverage (see `filedRegions`): its own
    /// type and code are filed, or a filed FIPS code aliases to it.
    static func isFiled(_ geocode: Geocode, country: String) -> Bool {
        guard let filed = filedRegions[country] else {
            return false
        }
        if filed[geocode.type]?.contains(geocode.code) == true {
            return true
        }
        guard let fips = filed["FIPS"], geocode.type == "EMMA_ID" else {
            return false
        }
        return fipsAliases.contains { $0.value == geocode.code && fips.contains($0.key) }
    }

    /// The MeteoAlarm feed slug for a country code; nil for a country MeteoAlarm does not answer
    /// for here (DE, NO, outside Europe).
    public static func feedSlug(countryCode: String) -> String? {
        feedSlugs[countryCode.uppercased()]
    }

    /// The api/v1 warnings feed of a country (JSON); nil as `feedSlug(countryCode:)`.
    public static func feedURL(countryCode: String) -> String? {
        feedSlug(countryCode: countryCode).map { "https://feeds.meteoalarm.org/api/v1/warnings/feeds-\($0)" }
    }

    // MARK: - Queries on the bundled table

    /// Whether MeteoAlarm covers a place: a polygon-only country by its code alone; any other
    /// country with a feed here when the point lies inside at least one bundled region of it
    /// that its feed files (`filedRegions`; false when the table cannot be loaded).
    public static func covers(countryCode: String, lat: Double, lon: Double) -> Bool {
        let cc = countryCode.uppercased()
        if polygonOnlyCountries.contains(cc) {
            return true
        }
        return table?.covers(countryCode: cc, lat: lat, lon: lon) ?? false
    }

    /// Whether the region `type`/`code` contains the point (a FIPS code by its alias); false for a
    /// code the table lacks.
    public static func contains(type: String, code: String, lat: Double, lon: Double) -> Bool {
        table?.contains(Geocode(type: type, code: code), lat: lat, lon: lon) ?? false
    }

    /// Whether a warning with these areas applies to the point (see the file header). Without a
    /// loadable table only areas with their own polygons can match.
    public static func matches(_ areas: [Area], lat: Double, lon: Double) -> Bool {
        areas.contains { area in
            if !area.polygons.isEmpty {
                return area.polygons.contains { ringContains($0, lat: lat, lon: lon) }
            }
            return area.geocodes.contains { table?.contains($0, lat: lat, lon: lon) ?? false }
        }
    }

    /// A CAP polygon "lat,lon lat,lon ..." (whitespace-separated pairs; the first pair repeated
    /// last, which is optional here); nil when a pair is unreadable or out of range, or when it
    /// has fewer than 3 distinct points.
    public static func capPolygon(_ text: String) -> [Point]? {
        var ring: [Point] = []
        for pair in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let f = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count == 2, let lat = Double(f[0]), let lon = Double(f[1]),
                  abs(lat) <= 90, abs(lon) <= 180 else {
                return nil
            }
            ring.append(Point(lat: lat, lon: lon))
        }
        var distinct: [Point] = []
        for p in ring where !distinct.contains(p) {
            distinct.append(p)
            if distinct.count == 3 {
                return ring
            }
        }
        return nil
    }

    // MARK: - Point in polygon

    /// Even-odd ray casting on one ring, closed or not (a repeated closing point is a zero-length
    /// edge and crosses nothing).
    static func ringContains(_ ring: [Point], lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > lat) != (b.lat > lat),
               lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Even-odd over all rings of a polygon: ring 0 outer, further rings holes.
    static func polygonContains(_ rings: [[Point]], lat: Double, lon: Double) -> Bool {
        rings.reduce(false) { $0 != ringContains($1, lat: lat, lon: lon) }
    }

    // MARK: - The table

    /// One bundled region.
    struct Region: Sendable {
        let geocode: Geocode
        /// ISO 3166-1 alpha-2 (EMMA country; GISCO CNTR_CODE).
        let country: String
        /// The source's name, for diagnostics only.
        let name: String
        /// Polygons -> rings -> points (a GeoJSON MultiPolygon).
        let polygons: [[[Point]]]
        /// The bounding box, to skip the polygons for most points.
        let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

        func contains(lat: Double, lon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
                && polygons.contains { WxAlertRegions.polygonContains($0, lat: lat, lon: lon) }
        }
    }

    /// The decoded region table with its lookups.
    struct Table: Sendable {
        /// Sorted by (type, code), as in the resource.
        let regions: [Region]
        let index: [Geocode: Int]
        let byCountry: [String: [Int]]

        /// Thrown for a resource this code does not read (another `format`, a ring of fewer than
        /// 4 points, a duplicate key).
        struct Invalid: Error, CustomStringConvertible {
            let description: String
        }

        private struct File: Decodable {
            let format: Int
            let regions: [Entry]
        }

        private struct Entry: Decodable {
            let type: String
            let code: String
            let country: String
            let name: String
            let polygons: [[[LonLat]]]
        }

        /// A GeoJSON position [lon, lat], decoded without an intermediate array.
        private struct LonLat: Decodable {
            let point: Point

            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                let lon = try c.decode(Double.self)
                point = Point(lat: try c.decode(Double.self), lon: lon)
            }
        }

        /// Decodes a region table (the resource's format 1).
        init(json: Data) throws {
            let file = try JSONDecoder().decode(File.self, from: json)
            guard file.format == 1 else {
                throw Invalid(description: "region table format \(file.format), expected 1")
            }
            var regions: [Region] = []
            var index: [Geocode: Int] = [:]
            var byCountry: [String: [Int]] = [:]
            regions.reserveCapacity(file.regions.count)
            for e in file.regions {
                let key = Geocode(type: e.type, code: e.code)
                let polygons = e.polygons.map { $0.map { $0.map(\.point) } }
                let points = polygons.joined().joined()
                guard index[key] == nil, !polygons.isEmpty, polygons.allSatisfy({ $0.allSatisfy { $0.count >= 4 } }),
                      let minLat = points.map(\.lat).min(), let maxLat = points.map(\.lat).max(),
                      let minLon = points.map(\.lon).min(), let maxLon = points.map(\.lon).max() else {
                    throw Invalid(description: "region \(e.type)/\(e.code): duplicate key or bad rings")
                }
                index[key] = regions.count
                byCountry[e.country, default: []].append(regions.count)
                regions.append(Region(geocode: key, country: e.country, name: e.name, polygons: polygons,
                                      minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon))
            }
            self.regions = regions
            self.index = index
            self.byCountry = byCountry
        }

        /// The region a geocode names, a FIPS code by its alias (`WxAlertRegions.tableKey`).
        func region(_ geocode: Geocode) -> Region? {
            tableKey(geocode).flatMap { index[$0] }.map { regions[$0] }
        }

        func contains(_ geocode: Geocode, lat: Double, lon: Double) -> Bool {
            region(geocode)?.contains(lat: lat, lon: lon) ?? false
        }

        /// Every region containing the point, in table order (diagnostics and tests).
        func regions(atLat lat: Double, lon: Double) -> [Region] {
            regions.filter { $0.contains(lat: lat, lon: lon) }
        }

        /// The bundled-region rule of `WxAlertRegions.covers`: a filed region of the country
        /// contains the point (a polygon-only country has no region here, so it is false for one).
        func covers(countryCode: String, lat: Double, lon: Double) -> Bool {
            let cc = countryCode.uppercased()
            guard feedSlugs[cc] != nil else {
                return false
            }
            return byCountry[cc, default: []].contains {
                isFiled(regions[$0].geocode, country: cc) && regions[$0].contains(lat: lat, lon: lon)
            }
        }
    }

    /// Anchors `Bundle(for:)` on the WeatherCore framework (not Bundle.main, the app or test runner).
    private final class BundleToken {}

    /// How many times the bundled table was read; a static let runs its initializer at most once
    /// per process (thread-safe), so this stays at most 1.
    static let loads = Mutex(0)

    /// The bundled table, read and decoded on first use; nil when the resource is missing or
    /// unreadable, which leaves no place covered and no geocode matched.
    static let table: Table? = {
        loads.withLock { $0 += 1 }
        guard let url = Bundle(for: BundleToken.self).url(forResource: "MeteoAlarmRegions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? Table(json: data)
    }()
}
