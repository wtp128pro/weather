// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// AlertRegionsTests.swift - MeteoAlarm warning placement: the bundled region
// table (loaded once), even-odd point-in-polygon with holes and multipolygons
// (synthetic squares and real regions), inline-polygon precedence over
// geocodes, unknown geocodes, Met Eireann's FIPS 10-4 county codes (aliased to
// the EMMA_ID region of the same county), the country feed table and coverage
// (by a bundled region of a type, code series or code the country's feed
// files, or by country code for the polygon-only feeds). The expected regions
// and coverage of the real points were found independently, with a Python
// even-odd test over MeteoAlarmRegions.json and the filedRegions rules applied
// to the api/v1 feeds as recorded on 2026-10-26, not with this code; the FIPS
// pairs from FIPS PUB 10-4 (NIST, 1995), not from fipsAliases.

import Foundation
import Synchronization
import Testing
@testable import WeatherCore

@Suite struct AlertRegionsTests {
    typealias R = WxAlertRegions

    /// A closed axis-aligned square ring, [lon, lat] as the resource stores it.
    static func square(_ lat0: Double, _ lon0: Double, _ lat1: Double, _ lon1: Double) -> String {
        "[[\(lon0),\(lat0)],[\(lon1),\(lat0)],[\(lon1),\(lat1)],[\(lon0),\(lat1)],[\(lon0),\(lat0)]]"
    }

    /// A one-region table in the resource's format with these polygons (each a list of rings).
    static func table(_ polygons: [[String]], type: String = "EMMA_ID", code: String = "XX001") throws -> R.Table {
        let rings = polygons.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: ",")
        let json = #"{"format":1,"regions":[{"type":"\#(type)","code":"\#(code)","country":"XX","name":"t","#
            + #""polygons":[\#(rings)]}]}"#
        return try R.Table(json: Data(json.utf8))
    }

    /// The bundled table (fails the test when it cannot be loaded).
    static func bundled() throws -> R.Table {
        try #require(R.table)
    }

    /// "TYPE/CODE" of every bundled region containing the point.
    static func keys(_ lat: Double, _ lon: Double) throws -> Set<String> {
        Set(try bundled().regions(atLat: lat, lon: lon).map { "\($0.geocode.type)/\($0.geocode.code)" })
    }

    static func geocode(_ type: String, _ code: String) -> R.Geocode {
        R.Geocode(type: type, code: code)
    }

    @Test func loadsTableOnce() async throws {
        let counts = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<8 {
                group.addTask { R.table?.regions.count }
            }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 2238, count: 8))
        #expect(R.loads.withLock { $0 } == 1)
        let t = try Self.bundled()
        let byType = Dictionary(grouping: t.regions, by: \.geocode.type).mapValues(\.count)
        #expect(byType == ["EMMA_ID": 2006, "NUTS3": 214, "NUTS2": 18])
        #expect(t.index.count == 2238)
        #expect(R.loads.withLock { $0 } == 1)
    }

    @Test func pointInPolygonWithHoles() throws {
        // A 10 x 10 square with a 2 x 2 hole in the middle.
        let t = try Self.table([[Self.square(0, 0, 10, 10), Self.square(4, 4, 6, 6)]])
        let g = Self.geocode("EMMA_ID", "XX001")
        #expect(t.contains(g, lat: 2, lon: 2))
        #expect(t.contains(g, lat: 5, lon: 8))
        #expect(!t.contains(g, lat: 5, lon: 5))
        #expect(!t.contains(g, lat: 11, lon: 5))
        // Real: Graz-Umgebung (AT606) surrounds Graz (Stadt) (AT601) with a hole.
        #expect(try Self.bundled().region(Self.geocode("EMMA_ID", "AT606"))?.polygons.first?.count == 2)
        #expect(R.contains(type: "EMMA_ID", code: "AT606", lat: 47.13, lon: 15.33))
        #expect(!R.contains(type: "EMMA_ID", code: "AT606", lat: 47.0707, lon: 15.4395))
        #expect(try Self.keys(47.0707, 15.4395) == ["EMMA_ID/AT601"])
    }

    @Test func multipolygonContainment() throws {
        // Two disjoint squares, the second with a hole: any polygon contains, holes stay per polygon.
        let t = try Self.table([[Self.square(0, 0, 2, 2)],
                                [Self.square(10, 10, 14, 14), Self.square(11, 11, 13, 13)]])
        let g = Self.geocode("EMMA_ID", "XX001")
        #expect(t.contains(g, lat: 1, lon: 1))
        #expect(t.contains(g, lat: 10.5, lon: 13.5))
        #expect(!t.contains(g, lat: 12, lon: 12))
        #expect(!t.contains(g, lat: 5, lon: 5))
        // Real: Kyklades (GR012) is 20 islands; Naxos, Mykonos and Fira (Santorini) are in it,
        // the sea west of Paros is not.
        #expect(try Self.bundled().region(Self.geocode("EMMA_ID", "GR012"))?.polygons.count == 20)
        for (lat, lon) in [(37.1036, 25.3763), (37.4467, 25.3289), (36.4166, 25.4318)] {
            #expect(R.contains(type: "EMMA_ID", code: "GR012", lat: lat, lon: lon))
        }
        #expect(!R.contains(type: "EMMA_ID", code: "GR012", lat: 37.0, lon: 24.9))
        #expect(try Self.keys(37.0, 24.9).isEmpty)
    }

    @Test func inlinePolygonWins() throws {
        // CAP order is "lat,lon": a box around Venice (45.3-45.6 N, 12.2-12.5 E), closed.
        let box = try #require(R.capPolygon("45.3,12.2 45.3,12.5 45.6,12.5 45.6,12.2 45.3,12.2"))
        #expect(box.first == R.Point(lat: 45.3, lon: 12.2) && box.count == 5)
        let veneto = Self.geocode("EMMA_ID", "IT006")
        let area = R.Area(polygons: [box], geocodes: [veneto])
        // Venice: inside the polygon.
        #expect(R.matches([area], lat: 45.4371, lon: 12.3326))
        // Verona: inside Veneto's region but outside the polygon, which decides alone.
        #expect(R.contains(type: "EMMA_ID", code: "IT006", lat: 45.4384, lon: 10.9916))
        #expect(!R.matches([area], lat: 45.4384, lon: 10.9916))
        // The same area without its polygon is placed by the geocode.
        #expect(R.matches([R.Area(polygons: [], geocodes: [veneto])], lat: 45.4384, lon: 10.9916))
        // A polygon containing the place matches whatever its geocodes are (EI05: no FIPS alias).
        let unknown = R.Area(polygons: [box], geocodes: [Self.geocode("FIPS", "EI05")])
        #expect(R.matches([unknown], lat: 45.4371, lon: 12.3326))
        // An open CAP ring reads too; unreadable or degenerate ones do not.
        #expect(R.matches([R.Area(polygons: [Array(box.dropLast())], geocodes: [])], lat: 45.4371, lon: 12.3326))
        #expect(R.capPolygon("45.3,12.2 45.6") == nil)
        #expect(R.capPolygon("45.3;12.2 45.3,12.5 45.6,12.5") == nil)
        #expect(R.capPolygon("95,12.2 45.3,12.5 45.6,12.5") == nil)
        #expect(R.capPolygon("45.3,12.2 45.3,12.5 45.3,12.2") == nil)
        #expect(R.capPolygon("") == nil)
    }

    @Test func geocodeLookupMatches() throws {
        let cases: [(R.Geocode, Double, Double)] = [
            (Self.geocode("EMMA_ID", "IT006"), 45.4371, 12.3326),   // Venice, Veneto
            (Self.geocode("NUTS3", "HR037"), 42.6407, 18.1077),     // Dubrovnik
            (Self.geocode("NUTS3", "HR031"), 45.3271, 14.4422),     // Rijeka, 2021 code
            (Self.geocode("NUTS2", "BE34"), 49.6833, 5.8167),       // Arlon: in no BE EMMA_ID region
            (Self.geocode("NUTS2", "HU10"), 47.4979, 19.0402),      // Budapest, 2013 code
        ]
        for (g, lat, lon) in cases {
            #expect(R.contains(type: g.type, code: g.code, lat: lat, lon: lon), "\(g)")
            #expect(R.matches([R.Area(polygons: [], geocodes: [g])], lat: lat, lon: lon), "\(g)")
        }
        // Any geocode of any area places the warning.
        let lisbon = (38.7223, -9.1393)
        let areas = [R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "IT006")]),
                     R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI01"), Self.geocode("EMMA_ID", "PT016")])]
        #expect(R.matches(areas, lat: lisbon.0, lon: lisbon.1))
        #expect(!R.matches(Array(areas.prefix(1)), lat: lisbon.0, lon: lisbon.1))
    }

    @Test func unknownGeocodeNeverMatches() throws {
        let dublin = (53.3498, -6.2603)
        #expect(try Self.keys(dublin.0, dublin.1) == ["EMMA_ID/IE012"])
        // Only FIPS county codes are aliased (unknownFipsCodeNeverMatches): IE012 under another
        // type, or the FIPS code under EMMA_ID, is not carried.
        for g in [Self.geocode("NUTS3", "IE012"), Self.geocode("EMMA_ID", "EI07")] {
            #expect(!R.matches([R.Area(polygons: [], geocodes: [g])], lat: dublin.0, lon: dublin.1), "\(g)")
        }
        // The key is type and code: NUTS3/HR031 is carried, EMMA_ID/HR031 is not.
        let rijeka = (45.3271, 14.4422)
        #expect(R.contains(type: "NUTS3", code: "HR031", lat: rijeka.0, lon: rijeka.1))
        #expect(!R.contains(type: "EMMA_ID", code: "HR031", lat: rijeka.0, lon: rijeka.1))
        #expect(!R.contains(type: "emma_id", code: "HR006", lat: rijeka.0, lon: rijeka.1))
        // Other types and unknown codes.
        let berlin = (52.52, 13.405)
        #expect(!R.matches([R.Area(polygons: [], geocodes: [Self.geocode("WARNCELLID", "111000000")])],
                           lat: berlin.0, lon: berlin.1))
        #expect(!R.contains(type: "EMMA_ID", code: "XX999", lat: berlin.0, lon: berlin.1))
        // No nearest-region fallback: 30 km off Malta, MT001 does not match; an area with no
        // polygon and no geocode matches nothing.
        #expect(!R.contains(type: "EMMA_ID", code: "MT001", lat: 35.7, lon: 14.2))
        #expect(!R.matches([R.Area(polygons: [], geocodes: [])], lat: 35.8989, lon: 14.5146))
        #expect(!R.matches([], lat: 35.8989, lon: 14.5146))
    }

    @Test func countryTableExcludesDEandNO() throws {
        #expect(R.feedSlug(countryCode: "DE") == nil)
        #expect(R.feedSlug(countryCode: "NO") == nil)
        for cc in ["US", "AD", "SJ", ""] {
            #expect(R.feedSlug(countryCode: cc) == nil, "\(cc)")
        }
        #expect(R.feedSlugs.count == 36)
        #expect(R.feedSlug(countryCode: "it") == "italy")
        #expect(R.feedSlug(countryCode: "MK") == "republic-of-north-macedonia")
        #expect(R.feedSlug(countryCode: "BA") == "bosnia-herzegovina")
        #expect(R.feedSlug(countryCode: "GR") == "greece")
        #expect(R.feedURL(countryCode: "AT") == "https://feeds.meteoalarm.org/api/v1/warnings/feeds-austria")
        #expect(R.feedURL(countryCode: "DE") == nil)
        // The table's countries are exactly the bundled ones less DE, plus the polygon-only ones,
        // which have no bundled region.
        let bundledCountries = Set(try Self.bundled().byCountry.keys)
        #expect(bundledCountries.isDisjoint(with: R.polygonOnlyCountries))
        #expect(Set(R.feedSlugs.keys) == bundledCountries.subtracting(["DE"]).union(R.polygonOnlyCountries))
        // Berlin lies in a bundled DE region, still MeteoAlarm does not cover it; nor Oslo.
        #expect(try Self.keys(52.52, 13.405) == ["EMMA_ID/DE202"])
        #expect(!R.covers(countryCode: "DE", lat: 52.52, lon: 13.405))
        #expect(!R.covers(countryCode: "NO", lat: 59.9139, lon: 10.7522))
    }

    @Test func outsideEveryRegionIsNotCovered() throws {
        // Positive control.
        #expect(R.covers(countryCode: "FR", lat: 48.8566, lon: 2.3522))
        // At sea: Bay of Biscay (FR), mid-Adriatic (IT, HR).
        #expect(!R.covers(countryCode: "FR", lat: 45.5, lon: -3.0))
        #expect(!R.covers(countryCode: "IT", lat: 43.0, lon: 15.0))
        #expect(!R.covers(countryCode: "HR", lat: 43.0, lon: 15.0))
        // Inside a region, but of another country.
        #expect(!R.covers(countryCode: "HR", lat: 45.4371, lon: 12.3326))
        // A country without a feed here (Andorra, between FR and ES regions).
        #expect(!R.covers(countryCode: "AD", lat: 42.5063, lon: 1.5218))
        // A synthetic table: one XX region, XX has no feed, so nothing in it is covered either.
        let t = try Self.table([[Self.square(0, 0, 10, 10)]])
        #expect(t.contains(Self.geocode("EMMA_ID", "XX001"), lat: 5, lon: 5))
        #expect(!t.covers(countryCode: "XX", lat: 5, lon: 5))
    }

    @Test func polygonOnlyCountriesCoveredByCode() throws {
        // (country, slug, capital): no bundled region contains the capital, yet it is covered.
        let feeds: [(String, String, Double, Double)] = [
            ("EE", "estonia", 59.437, 24.7536), ("LU", "luxembourg", 49.6116, 6.1319),
            ("SE", "sweden", 59.3293, 18.0686), ("CH", "switzerland", 47.3769, 8.5417),
            ("UA", "ukraine", 50.4501, 30.5234), ("GB", "united-kingdom", 51.5074, -0.1278),
            ("IL", "israel", 32.0853, 34.7818),
        ]
        let t = try Self.bundled()
        for (cc, slug, lat, lon) in feeds {
            #expect(R.feedSlug(countryCode: cc) == slug)
            #expect(t.byCountry[cc] == nil, "\(cc)")
            #expect(try Self.keys(lat, lon).isEmpty, "\(cc)")
            #expect(R.covers(countryCode: cc, lat: lat, lon: lon), "\(cc)")
        }
        // By the code alone, whatever the point.
        #expect(R.covers(countryCode: "gb", lat: 0, lon: 0))
        // A GB warning with its own polygon (CAP lat,lon) around London matches London, not Manchester.
        let london = (51.5074, -0.1278), manchester = (53.4808, -2.2426)
        let box = try #require(R.capPolygon("51.3,-0.5 51.3,0.3 51.7,0.3 51.7,-0.5 51.3,-0.5"))
        let polygonWarning = [R.Area(polygons: [box], geocodes: [Self.geocode("EMMA_ID", "UK012")])]
        #expect(R.matches(polygonWarning, lat: london.0, lon: london.1))
        #expect(!R.matches(polygonWarning, lat: manchester.0, lon: manchester.1))
        // A GB warning with geocodes only never matches: the table has no GB code.
        let codeWarning = [R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "UK012"),
                                                           Self.geocode("NUTS2", "UKI3")])]
        #expect(!R.matches(codeWarning, lat: london.0, lon: london.1))
    }

    /// Calls the API synchronously from a detached (nonisolated, Sendable) task: it compiles only
    /// because the API is nonisolated, and runs off the main thread.
    @Test func matchingRunsOffMainActor() async throws {
        let (onMain, covered, matched, slug) = await Task.detached {
            (pthread_main_np() != 0,
             R.covers(countryCode: "MT", lat: 35.8989, lon: 14.5146),
             R.matches([R.Area(polygons: [], geocodes: [R.Geocode(type: "EMMA_ID", code: "MT001")])],
                       lat: 35.8989, lon: 14.5146),
             R.feedSlug(countryCode: "MT"))
        }.value
        #expect(!onMain)
        #expect(covered && matched && slug == "malta")
        #expect(R.loads.withLock { $0 } == 1)
    }

    @Test func coastalAndBorderPoints() throws {
        // (country, lat, lon, every bundled region containing it); coordinates as the
        // builder's --self-check towns; Gorizia sits on the IT-SI border and the simplified rings
        // put it in both countries' regions.
        let towns: [(String, String, Double, Double, Set<String>)] = [
            ("Venice", "IT", 45.4371, 12.3326, ["EMMA_ID/IT006"]),
            ("Lisbon", "PT", 38.7223, -9.1393, ["EMMA_ID/PT016"]),
            ("Valletta", "MT", 35.8989, 14.5146, ["EMMA_ID/MT001"]),
            // Simplification moves Dubrovnik's old town out of EMMA_ID/HR007; NUTS3/HR037 places it.
            ("Dubrovnik", "HR", 42.6407, 18.1077, ["NUTS3/HR037"]),
            ("Gorizia", "IT", 45.9415, 13.6219, ["EMMA_ID/IT020", "EMMA_ID/SI008"]),
            ("Nova Gorica", "SI", 45.9558, 13.6483, ["EMMA_ID/SI008"]),
        ]
        let t = try Self.bundled()
        for (name, cc, lat, lon, expected) in towns {
            #expect(try Self.keys(lat, lon) == expected, "\(name)")
            #expect(t.regions(atLat: lat, lon: lon).contains { $0.country == cc }, "\(name)")
            #expect(R.covers(countryCode: cc, lat: lat, lon: lon), "\(name)")
        }
        #expect(!R.contains(type: "EMMA_ID", code: "HR007", lat: 42.6407, lon: 18.1077))
    }

    /// FIPS PUB 10-4 (NIST, 1995, pp. 23-24), "EI IRELAND, county": code, county, and a county
    /// town inside the bundled county region alone (found in Python).
    static let fipsCounties: [(String, String, String, Double, Double)] = [
        ("EI01", "Carlow", "IE020", 52.8365, -6.9341), ("EI02", "Cavan", "IE027", 53.9908, -7.3606),
        ("EI03", "Clare", "IE014", 52.8436, -8.9864), ("EI04", "Cork", "IE007", 51.8985, -8.4756),
        ("EI06", "Donegal", "IE018", 54.9558, -7.7342), ("EI07", "Dublin", "IE012", 53.3498, -6.2603),
        ("EI10", "Galway", "IE015", 53.2707, -9.0568), ("EI11", "Kerry", "IE008", 52.2713, -9.6999),
        ("EI12", "Kildare", "IE030", 53.2159, -6.6669), ("EI13", "Kilkenny", "IE021", 52.6541, -7.2448),
        ("EI14", "Leitrim", "IE029", 54.3047, -8.1758), ("EI15", "Laois", "IE022", 53.0344, -7.2998),
        ("EI16", "Limerick", "IE013", 52.6638, -8.6267), ("EI18", "Longford", "IE025", 53.7276, -7.7932),
        ("EI19", "Louth", "IE019", 54.0090, -6.4049), ("EI20", "Mayo", "IE016", 53.8550, -9.2880),
        ("EI21", "Meath", "IE023", 53.6528, -6.6814), ("EI22", "Monaghan", "IE031", 54.2492, -6.9683),
        ("EI23", "Offaly", "IE028", 53.2739, -7.4889), ("EI24", "Roscommon", "IE026", 53.6333, -8.1833),
        ("EI25", "Sligo", "IE017", 54.2766, -8.4761), ("EI26", "Tipperary", "IE006", 52.3550, -7.7039),
        ("EI27", "Waterford", "IE009", 52.0845, -7.6397), ("EI29", "Westmeath", "IE024", 53.5259, -7.3381),
        ("EI30", "Wexford", "IE010", 52.3369, -6.4633), ("EI31", "Wicklow", "IE011", 52.9808, -6.0446),
    ]

    @Test func irishFipsCountiesMapToTheirRegions() throws {
        // Every one of the 26 codes Met Eireann files, and nothing else, is aliased.
        #expect(Self.fipsCounties.count == 26)
        #expect(R.fipsAliases.count == 26)
        #expect(Set(R.fipsAliases.keys) == Set(Self.fipsCounties.map(\.0)))
        let t = try Self.bundled()
        for (fips, county, emma, lat, lon) in Self.fipsCounties {
            // The alias is the EMMA_ID region the geocodes file names after the same county.
            #expect(R.fipsAliases[fips] == emma, "\(fips)")
            let region = try #require(t.region(Self.geocode("FIPS", fips)), "\(fips)")
            #expect(region.geocode == Self.geocode("EMMA_ID", emma), "\(fips)")
            #expect(region.name == "County \(county)" && region.country == "IE", "\(fips)")
            // A warning filed under the code alone matches the county town and only that code
            // does; the town is covered.
            #expect(try Self.keys(lat, lon) == ["EMMA_ID/\(emma)"], "\(county)")
            let codes = Self.fipsCounties.map(\.0).filter {
                R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", $0)])], lat: lat, lon: lon)
            }
            #expect(codes == [fips], "\(county)")
            #expect(R.contains(type: "FIPS", code: fips, lat: lat, lon: lon), "\(county)")
            #expect(R.covers(countryCode: "IE", lat: lat, lon: lon), "\(county)")
        }
        // 26 distinct county regions: all of IE006-IE031, none of the sea or offshore ones.
        #expect(Set(R.fipsAliases.values) == Set((6...31).map { String(format: "IE%03d", $0) }))
    }

    @Test func dublinFipsWarningMatchesDublin() throws {
        // "Orange Rain | Dublin, Wexford, Wicklow" (ireland feed, sent 2026-10-21T10:41:22+01:00),
        // its geocodes verbatim: FIPS only.
        let orangeRain = [R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI07"), Self.geocode("FIPS", "EI30"),
                                                         Self.geocode("FIPS", "EI31")])]
        let dublin = (53.3498, -6.2603), dunLaoghaire = (53.2940, -6.1340)
        let wexford = (52.3369, -6.4633), wicklow = (52.9808, -6.0446)
        for (lat, lon) in [dublin, dunLaoghaire, wexford, wicklow] {
            #expect(R.matches(orangeRain, lat: lat, lon: lon), "\(lat),\(lon)")
        }
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI07")])],
                          lat: dublin.0, lon: dublin.1))
        // Not the counties it does not name: Cork, Galway, Naas (Kildare, next to Dublin).
        for (lat, lon) in [(51.8985, -8.4756), (53.2707, -9.0568), (53.2159, -6.6669)] {
            #expect(!R.matches(orangeRain, lat: lat, lon: lon), "\(lat),\(lon)")
        }
        // Code to code: an area filed under Wexford's code alone does not reach Dublin.
        #expect(!R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI30")])],
                           lat: dublin.0, lon: dublin.1))
        // The Irish feed is requested without any key.
        #expect(R.feedURL(countryCode: "IE") == "https://feeds.meteoalarm.org/api/v1/warnings/feeds-ireland")
    }

    @Test func irishLandPlaceIsCovered() throws {
        // Dublin, Cork, Galway and Athlone each lie in their county region alone, which Met Eireann
        // files through FIPS: covered.
        let land: [(Double, Double, String)] = [(53.3498, -6.2603, "EMMA_ID/IE012"), (51.8985, -8.4756, "EMMA_ID/IE007"),
                                                (53.2707, -9.0568, "EMMA_ID/IE015"), (53.4239, -7.9407, "EMMA_ID/IE024")]
        for (lat, lon, key) in land {
            #expect(try Self.keys(lat, lon) == [key])
            #expect(R.covers(countryCode: "IE", lat: lat, lon: lon), "\(key)")
        }
        #expect(R.isFiled(Self.geocode("EMMA_ID", "IE012"), country: "IE"))
        // Killybegs lies in the Erris-Rossan sea area EI820 and in County Donegal: the Donegal land
        // warning (verbatim "Orange Wind | Donegal", FIPS EI06) and the marine one both reach it.
        let killybegs = (54.6353, -8.4497)
        #expect(try Self.keys(killybegs.0, killybegs.1) == ["EMMA_ID/EI820", "EMMA_ID/IE018"])
        #expect(R.covers(countryCode: "IE", lat: killybegs.0, lon: killybegs.1))
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI06")])],
                          lat: killybegs.0, lon: killybegs.1))
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "EI820")])],
                          lat: killybegs.0, lon: killybegs.1))
        // The EI8xx sea areas stay covered: the sea off Wicklow (EI810) and the mid Irish Sea (EI824).
        let wicklowSea = (53.2, -5.9), irishSea = (53.5, -5.3)
        #expect(try Self.keys(wicklowSea.0, wicklowSea.1) == ["EMMA_ID/EI810", "EMMA_ID/IE803"])
        #expect(R.covers(countryCode: "IE", lat: wicklowSea.0, lon: wicklowSea.1))
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "EI810")])],
                          lat: wicklowSea.0, lon: wicklowSea.1))
        #expect(try Self.keys(irishSea.0, irishSea.1) == ["EMMA_ID/EI824"])
        #expect(R.covers(countryCode: "ie", lat: irishSea.0, lon: irishSea.1))
        // Inside only an IE80x offshore region, never filed, or in no region: not covered.
        #expect(try Self.keys(54.27631, -10.02821) == ["EMMA_ID/IE801"])
        #expect(!R.covers(countryCode: "IE", lat: 54.27631, lon: -10.02821))
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "IE801"), country: "IE"))
        #expect(!R.covers(countryCode: "IE", lat: 53.0, lon: -12.0))
    }

    @Test func unknownFipsCodeNeverMatches() throws {
        let dublin = (53.3498, -6.2603), berlin = (52.52, 13.405)
        // FIPS 10-4's gaps, the later GEC codes for Dublin's city and administrative counties
        // (EI33-EI35, EI39) and Cork city (EI32), which Met Eireann does not file: never at Dublin.
        let unknown = ["EI00", "EI05", "EI08", "EI09", "EI17", "EI28", "EI32", "EI33", "EI34", "EI35", "EI39", "EI44", "EI99"]
        for code in unknown {
            #expect(R.tableKey(Self.geocode("FIPS", code)) == nil, "\(code)")
            #expect(!R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", code)])],
                               lat: dublin.0, lon: dublin.1), "\(code)")
            #expect(!R.contains(type: "FIPS", code: code, lat: dublin.0, lon: dublin.1), "\(code)")
        }
        // Another country's FIPS code (GM16 Berlin, UK, EMMA-style or Irish ISO codes), never.
        for code in ["GM16", "UK01", "IE012", "IE-D", "IE07"] {
            #expect(!R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", code)])],
                               lat: dublin.0, lon: dublin.1), "\(code)")
            #expect(!R.matches([R.Area(polygons: [], geocodes: [Self.geocode("FIPS", code)])],
                               lat: berlin.0, lon: berlin.1), "\(code)")
        }
        // Exact type and code: no case folding, trimming or padding.
        for g in [Self.geocode("fips", "EI07"), Self.geocode("FIPS", "ei07"), Self.geocode("FIPS", " EI07"),
                  Self.geocode("FIPS", "EI7"), Self.geocode("FIPS 10-4", "EI07"), Self.geocode("FIPS", "EI007")] {
            #expect(!R.matches([R.Area(polygons: [], geocodes: [g])], lat: dublin.0, lon: dublin.1), "\(g)")
        }
        // An unknown code beside a known one: only the known one places the warning.
        let mixed = [R.Area(polygons: [], geocodes: [Self.geocode("FIPS", "EI33"), Self.geocode("FIPS", "EI04")])]
        #expect(!R.matches(mixed, lat: dublin.0, lon: dublin.1))
        #expect(R.matches(mixed, lat: 51.8985, lon: -8.4756))
        // An alias never makes coverage outside Ireland: FIPS counts only in the Irish entry.
        #expect(R.filedRegions.filter { $0.value["FIPS"] != nil }.map(\.key) == ["IE"])
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "IE012"), country: "GB"))
    }

    @Test func unfiledTypeRegionsDoNotCount() throws {
        // FR, BG, RO and MK file NUTS3 only and HU NUTS2 only: a point inside only an EMMA_ID
        // region of its country is not covered, one inside its NUTS region is. Collioure's coast,
        // in FR006 only, against Perpignan in NUTS3/FR815.
        #expect(try Self.keys(42.59601, 3.04449) == ["EMMA_ID/FR006"])
        #expect(!R.covers(countryCode: "FR", lat: 42.59601, lon: 3.04449))
        #expect(try Self.keys(42.6887, 2.8948) == ["EMMA_ID/FR006", "NUTS3/FR815"])
        #expect(R.covers(countryCode: "FR", lat: 42.6887, lon: 2.8948))
        // The verifier's 28 cross-check points covered only by an unfiled EMMA_ID region (RO 7,
        // HU 9, FR 8, BG 3, MK 1).
        let unfiled: [(String, Double, Double)] = [
            ("RO", 45.16633, 29.67512), ("RO", 44.03411, 26.39819), ("RO", 45.23971, 21.30369),
            ("RO", 43.957132, 27.859474), ("RO", 46.86841, 21.60309), ("RO", 47.89761, 24.21849),
            ("RO", 44.10991, 27.28409),
            ("HU", 47.566106, 16.624183), ("HU", 47.290173, 16.466537), ("HU", 46.33591, 16.87999),
            ("HU", 45.93681, 17.36439), ("HU", 47.72751, 22.27949), ("HU", 47.03611, 21.65969),
            ("HU", 46.66431, 16.39649), ("HU", 46.38421, 16.75809), ("HU", 46.321463, 16.874821),
            ("FR", 49.96201, 4.21849), ("FR", 42.59601, 3.04449), ("FR", 49.03321, -1.53181),
            ("FR", 48.16361, 2.93859), ("FR", 42.78741, 9.48579), ("FR", 50.72281, 2.84839),
            ("FR", 47.30001, -2.03191), ("FR", 46.14091, 6.04779),
            ("BG", 42.04941, 28.00459), ("BG", 41.55061, 26.17969), ("BG", 42.506043, 27.492639),
            ("MK", 41.55791, 22.97789),
        ]
        for (cc, lat, lon) in unfiled {
            let own = try Self.bundled().regions(atLat: lat, lon: lon).filter { $0.country == cc }
            #expect(!own.isEmpty && own.allSatisfy { $0.geocode.type == "EMMA_ID" }, "\(cc) \(lat),\(lon)")
            #expect(!R.covers(countryCode: cc, lat: lat, lon: lon), "\(cc) \(lat),\(lon)")
        }
        // Croatia files land under NUTS3 and from the table only its HR8xx sea areas under
        // EMMA_ID: a point in HR006 alone is not covered, Split (HR008 + NUTS3/HR035) is.
        #expect(try Self.keys(44.52741, 14.45479) == ["EMMA_ID/HR006"])
        #expect(!R.covers(countryCode: "HR", lat: 44.52741, lon: 14.45479))
        #expect(R.covers(countryCode: "HR", lat: 43.5081, lon: 16.4402))
        // Croatia files NUTS3 under its 21 NUTS 2021 codes, never the superseded 2013 ones
        // (HR041-HR04E): Stara Gradiska on the Sava, inside only 2013 HR04A, is not covered, and no
        // Croatian warning could reach it; Slavonski Brod (2021 HR024 too) is.
        #expect(try Self.keys(45.1497, 17.2453) == ["EMMA_ID/HR005", "NUTS3/HR04A"])
        #expect(!R.covers(countryCode: "HR", lat: 45.1497, lon: 17.2453))
        #expect(try Self.keys(45.1603, 18.0156) == ["EMMA_ID/HR005", "NUTS3/HR024", "NUTS3/HR04A"])
        #expect(R.covers(countryCode: "HR", lat: 45.1603, lon: 18.0156))
        #expect(!R.isFiled(Self.geocode("NUTS3", "HR04A"), country: "HR"))
        #expect(R.isFiled(Self.geocode("NUTS3", "HR024"), country: "HR"))
        // The verifier's real coastal and border towns all lie in a filed region (Ajaccio's centre
        // lies in none: a simplification gap, not covered either way).
        let towns: [(String, String, Double, Double)] = [
            ("Sulina", "RO", 45.1556, 29.6531), ("Mangalia", "RO", 43.8167, 28.5833),
            ("Constanta", "RO", 44.1733, 28.6383), ("Giurgiu", "RO", 43.9037, 25.9699),
            ("Szentgotthard", "HU", 46.9525, 16.2736), ("Sopron", "HU", 47.6817, 16.5845),
            ("Mohacs", "HU", 45.9931, 18.6831), ("Esztergom", "HU", 47.7928, 18.7403),
            ("Collioure", "FR", 42.5253, 3.0831), ("Hendaye", "FR", 43.3586, -1.7744),
            ("Menton", "FR", 43.7747, 7.4975), ("Saint-Malo", "FR", 48.6493, -2.0257),
            ("Granville", "FR", 48.8378, -1.5975), ("Calais", "FR", 50.9513, 1.8587),
            ("Bonifacio", "FR", 41.3874, 9.1593), ("Burgas", "BG", 42.5048, 27.4626),
            ("Sozopol", "BG", 42.4170, 27.6956), ("Vidin", "BG", 43.9962, 22.8679),
            ("Ohrid", "MK", 41.1172, 20.8016), ("Gevgelija", "MK", 41.1392, 22.5025),
        ]
        for (name, cc, lat, lon) in towns {
            #expect(R.covers(countryCode: cc, lat: lat, lon: lon), "\(name)")
        }
        #expect(!R.covers(countryCode: "FR", lat: 41.9192, lon: 8.7386))
    }

    @Test func frenchOverseasIsNotCovered() throws {
        // The table carries France's overseas NUTS3 (FRA10-FRA50), the France feed files none.
        let saintDenis = (-20.8823, 55.4504), cayenne = (4.9224, -52.3135)
        #expect(try Self.keys(saintDenis.0, saintDenis.1) == ["NUTS3/FRA40"])
        #expect(!R.covers(countryCode: "FR", lat: saintDenis.0, lon: saintDenis.1))
        #expect(try Self.keys(cayenne.0, cayenne.1) == ["NUTS3/FRA30"])
        #expect(!R.covers(countryCode: "FR", lat: cayenne.0, lon: cayenne.1))
        // Matching is unchanged: a FRA40 warning would still place.
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("NUTS3", "FRA40")])],
                          lat: saintDenis.0, lon: saintDenis.1))
        #expect(!R.isFiled(Self.geocode("NUTS3", "FRA40"), country: "FR"))
        #expect(R.isFiled(Self.geocode("NUTS3", "FR815"), country: "FR"))
    }

    @Test func filedRegionsTableIsConsistent() throws {
        // One entry per country with bundled regions and a feed (all but DE); every type, code
        // series and code it names is carried for that country.
        let t = try Self.bundled()
        #expect(Set(R.filedRegions.keys) == Set(t.byCountry.keys).subtracting(["DE"]))
        #expect(Set(R.filedRegions.keys).isSubset(of: Set(R.feedSlugs.keys)))
        for (cc, types) in R.filedRegions {
            let carried = t.byCountry[cc, default: []].map { t.regions[$0].geocode }
            for (type, filed) in types where type == "FIPS" {
                // FIPS is not carried: each filed code's alias is, for this country.
                for (fips, emma) in R.fipsAliases where filed.contains(fips) {
                    #expect(carried.contains(Self.geocode("EMMA_ID", emma)), "\(cc) \(fips)")
                }
            }
            for (type, filed) in types where type != "FIPS" {
                #expect(carried.contains { $0.type == type }, "\(cc) \(type)")
                switch filed {
                case .all:
                    break
                case .series(let series):
                    for s in series {
                        #expect(carried.contains { $0.type == type && $0.code.hasPrefix(s) }, "\(cc) \(type) \(s)")
                    }
                case .codes(let codes):
                    for c in codes {
                        #expect(carried.contains(Self.geocode(type, c)), "\(cc) \(type) \(c)")
                    }
                }
            }
        }
        // The rules the feeds recorded on 2026-10-26 gave.
        #expect(R.filedRegions["IE"] == ["EMMA_ID": .series(["EI8"]), "FIPS": .all])
        let hr2021 = (1...8).map { "HR02\($0)" } + (1...7).map { "HR03\($0)" } + ["HR050"] + (1...5).map { "HR06\($0)" }
        #expect(R.filedRegions["HR"] == ["EMMA_ID": .series(["HR8"]), "NUTS3": .codes(Set(hr2021))])
        #expect(R.filedRegions["HU"] == ["NUTS2": .all])
        for cc in ["BG", "RO", "MK"] {
            #expect(R.filedRegions[cc] == ["NUTS3": .all], "\(cc)")
        }
        #expect(R.filedRegions["FR"] == ["NUTS3": .series((1...8).map { "FR\($0)" })])
        #expect(R.filedRegions["BE"] == ["EMMA_ID": .codes(["BE004", "BE801"]),
                                         "NUTS2": .codes(["BE21", "BE22", "BE23", "BE25", "BE32", "BE33", "BE34", "BE35"])])
        #expect(R.filedRegions.values.filter { $0 == ["EMMA_ID": .all] }.count == 21)
        // Slovenia files every area by its own polygon: its regions are its footprint.
        #expect(R.covers(countryCode: "SI", lat: 46.0569, lon: 14.5058))
        // A type or series not listed never counts; an unlisted country has no filed region.
        #expect(R.isFiled(Self.geocode("EMMA_ID", "IE012"), country: "IE"))
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "IE804"), country: "IE"))
        #expect(R.isFiled(Self.geocode("EMMA_ID", "EI810"), country: "IE"))
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "FR006"), country: "FR"))
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "DE202"), country: "DE"))
        #expect(R.isFiled(Self.geocode("NUTS2", "BE22"), country: "BE"))
        #expect(!R.isFiled(Self.geocode("NUTS2", "BE24"), country: "BE"))
        #expect(!R.isFiled(Self.geocode("EMMA_ID", "BE007"), country: "BE"))
    }

    @Test func belgiumCoversOnlyItsFiledCodes() throws {
        // The Belgian feed files the same ten codes every day, Green included: EMMA_ID BE004
        // (Brabant) and BE801 (coast), NUTS2 BE21-BE23, BE25 and BE32-BE35. Its other codes are
        // never filed, so a town inside only those is not covered (never "no alerts"), and no
        // warning the feed files could reach it.
        let filed = [R.Area(polygons: [], geocodes: ["BE004", "BE801"].map { Self.geocode("EMMA_ID", $0) }
            + ["BE21", "BE22", "BE23", "BE25", "BE32", "BE33", "BE34", "BE35"].map { Self.geocode("NUTS2", $0) })]
        let unfiled: [(String, Double, Double, Set<String>)] = [
            ("Diest", 50.9893, 5.0510, ["EMMA_ID/BE007", "NUTS2/BE24"]),
            ("Landen", 50.7531, 5.0820, ["EMMA_ID/BE007", "NUTS2/BE24"]),
            ("Zoutleeuw", 50.8333, 5.1036, ["EMMA_ID/BE007", "NUTS2/BE24"]),
            ("Geetbets", 50.8939, 5.1131, ["EMMA_ID/BE007", "NUTS2/BE24"]),
            ("Kortenaken", 50.9097, 5.0597, ["EMMA_ID/BE007", "NUTS2/BE24"]),
            ("Nivelles", 50.5978, 4.3286, ["EMMA_ID/BE005", "NUTS2/BE31"]),
            ("Rebecq", 50.6644, 4.1336, ["EMMA_ID/BE005", "NUTS2/BE31"]),
        ]
        for (name, lat, lon, keys) in unfiled {
            #expect(try Self.keys(lat, lon) == keys, "\(name)")
            #expect(!R.covers(countryCode: "BE", lat: lat, lon: lon), "\(name)")
            #expect(!R.matches(filed, lat: lat, lon: lon), "\(name)")
        }
        // A place inside a filed region stays covered and the feed's warnings reach it: Brussels
        // and Wavre (BE004, with the unfiled NUTS2 BE10 and BE31), Leuven (BE004), Antwerp (BE21),
        // Arlon (BE34 only).
        let covered: [(String, Double, Double, Set<String>)] = [
            ("Brussels", 50.8503, 4.3517, ["EMMA_ID/BE004", "NUTS2/BE10"]),
            ("Leuven", 50.8798, 4.7005, ["EMMA_ID/BE004", "NUTS2/BE24"]),
            ("Wavre", 50.7170, 4.6010, ["EMMA_ID/BE004", "NUTS2/BE31"]),
            ("Antwerp", 51.2194, 4.4025, ["EMMA_ID/BE002", "NUTS2/BE21"]),
            ("Arlon", 49.6833, 5.8167, ["NUTS2/BE34"]),
        ]
        for (name, lat, lon, keys) in covered {
            #expect(try Self.keys(lat, lon) == keys, "\(name)")
            #expect(R.covers(countryCode: "BE", lat: lat, lon: lon), "\(name)")
            #expect(R.matches(filed, lat: lat, lon: lon), "\(name)")
        }
        // Matching is unchanged: a BE004 warning places at Leuven, and a warning filed under the
        // unfiled BE007 would still place at Diest.
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "BE004")])],
                          lat: 50.8798, lon: 4.7005))
        #expect(R.matches([R.Area(polygons: [], geocodes: [Self.geocode("EMMA_ID", "BE007")])],
                          lat: 50.9893, lon: 5.0510))
        // Over a 0.05 deg grid, a point inside a Belgian region is covered exactly when a warning
        // filed under all ten codes reaches it (counts found independently in Python).
        let t = try Self.bundled()
        var inside = 0, coveredPoints = 0
        for i in 0...42 {
            for j in 0..<80 {
                let lat = 49.45 + 0.05 * Double(i), lon = 2.5 + 0.05 * Double(j)
                guard t.regions(atLat: lat, lon: lon).contains(where: { $0.country == "BE" }) else {
                    continue
                }
                inside += 1
                let c = R.covers(countryCode: "BE", lat: lat, lon: lon)
                coveredPoints += c ? 1 : 0
                #expect(c == R.matches(filed, lat: lat, lon: lon), "\(lat),\(lon)")
            }
        }
        #expect(inside == 1731)
        #expect(coveredPoints == 1640)
    }
}
