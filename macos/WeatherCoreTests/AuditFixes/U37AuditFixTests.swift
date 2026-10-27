// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// U37AuditFixTests.swift - regression tests for the audit fixes of slice P10:
// WxAddressGeocoder timezone inference, merge-loop zone resolution and query
// escaping, and WxGeo.inCanada. Each test names the finding (U10-Fn) it pins.
// Coordinates are /usr/share/zoneinfo/zone.tab points where one exists. No
// test touches the network.

import Foundation
import Testing
@testable import WeatherCore

/// Whole-hour UTC offset of `zone` at the instant `iso`, or nil for an unknown zone.
private func offsetHours(_ zone: String, _ iso: String) -> Int? {
    guard let tz = TimeZone(identifier: zone), let date = ISO8601DateFormatter().date(from: iso) else {
        return nil
    }
    return tz.secondsFromGMT(for: date) / 3600
}

/// A Mexican place, the zone the US bands gave it before the fix, the zone it gets now and
/// its IANA zone (zone.tab region text).
private struct MXCase {
    let name: String
    let lat, lon: Double
    let admin1, before, after, truth: String
}

/// The 28 cities of the U10 verifier's oracle (RUN/work/vt/v-U10-2/driver.swift).
private let mxCases: [MXCase] = [
    MXCase(name: "Monterrey", lat: 25.6667, lon: -100.3167, admin1: "Nuevo León", before: "America/Chicago", after: "America/Chicago", truth: "America/Monterrey"),
    MXCase(name: "Saltillo", lat: 25.4232, lon: -101.0053, admin1: "Coahuila de Zaragoza", before: "America/Chicago", after: "America/Chicago", truth: "America/Monterrey"),
    MXCase(name: "Monclova", lat: 26.9080, lon: -101.4215, admin1: "Coahuila de Zaragoza", before: "America/Chicago", after: "America/Chicago", truth: "America/Monterrey"),
    MXCase(name: "Torreon", lat: 25.5428, lon: -103.4068, admin1: "Coahuila de Zaragoza", before: "America/Denver", after: "America/Monterrey", truth: "America/Monterrey"),
    MXCase(name: "Durango", lat: 24.0277, lon: -104.6532, admin1: "Durango", before: "America/Denver", after: "America/Monterrey", truth: "America/Monterrey"),
    MXCase(name: "Chihuahua", lat: 28.6333, lon: -106.0833, admin1: "Chihuahua", before: "America/Denver", after: "America/Chihuahua", truth: "America/Chihuahua"),
    MXCase(name: "Ciudad Juarez", lat: 31.7333, lon: -106.4833, admin1: "Chihuahua", before: "America/Denver", after: "America/Denver", truth: "America/Ciudad_Juarez"),
    MXCase(name: "Ojinaga", lat: 29.5667, lon: -104.4167, admin1: "Chihuahua", before: "America/Denver", after: "America/Denver", truth: "America/Ojinaga"),
    MXCase(name: "Hermosillo", lat: 29.0667, lon: -110.9667, admin1: "Sonora", before: "America/Denver", after: "America/Hermosillo", truth: "America/Hermosillo"),
    MXCase(name: "Ciudad Obregon", lat: 27.4828, lon: -109.9304, admin1: "Sonora", before: "America/Denver", after: "America/Hermosillo", truth: "America/Hermosillo"),
    MXCase(name: "Nogales", lat: 31.3086, lon: -110.9422, admin1: "Sonora", before: "America/Denver", after: "America/Hermosillo", truth: "America/Hermosillo"),
    MXCase(name: "Culiacan", lat: 24.8091, lon: -107.3940, admin1: "Sinaloa", before: "America/Denver", after: "America/Mazatlan", truth: "America/Mazatlan"),
    MXCase(name: "Los Mochis", lat: 25.7904, lon: -108.9858, admin1: "Sinaloa", before: "America/Denver", after: "America/Mazatlan", truth: "America/Mazatlan"),
    MXCase(name: "La Paz", lat: 24.1426, lon: -110.3128, admin1: "Baja California Sur", before: "America/Denver", after: "America/Mazatlan", truth: "America/Mazatlan"),
    MXCase(name: "Tijuana", lat: 32.5333, lon: -117.0167, admin1: "Baja California", before: "America/Los_Angeles", after: "America/Tijuana", truth: "America/Tijuana"),
    MXCase(name: "Mexicali", lat: 32.6245, lon: -115.4523, admin1: "Baja California", before: "America/Los_Angeles", after: "America/Tijuana", truth: "America/Tijuana"),
    MXCase(name: "Ensenada", lat: 31.8667, lon: -116.5964, admin1: "Baja California", before: "America/Los_Angeles", after: "America/Tijuana", truth: "America/Tijuana"),
    MXCase(name: "Matamoros", lat: 25.8333, lon: -97.5000, admin1: "Tamaulipas", before: "America/Chicago", after: "America/Chicago", truth: "America/Matamoros"),
    MXCase(name: "Nuevo Laredo", lat: 27.4763, lon: -99.5164, admin1: "Tamaulipas", before: "America/Chicago", after: "America/Chicago", truth: "America/Matamoros"),
    MXCase(name: "Reynosa", lat: 26.0508, lon: -98.2979, admin1: "Tamaulipas", before: "America/Chicago", after: "America/Chicago", truth: "America/Matamoros"),
    MXCase(name: "Piedras Negras", lat: 28.7000, lon: -100.5236, admin1: "Coahuila de Zaragoza", before: "America/Chicago", after: "America/Chicago", truth: "America/Matamoros"),
    MXCase(name: "Ciudad Acuna", lat: 29.3232, lon: -100.9522, admin1: "Coahuila de Zaragoza", before: "America/Chicago", after: "America/Chicago", truth: "America/Matamoros"),
    MXCase(name: "Mazatlan", lat: 23.2167, lon: -106.4167, admin1: "Sinaloa", before: "Etc/GMT+7", after: "America/Mazatlan", truth: "America/Mazatlan"),
    MXCase(name: "Mexico City", lat: 19.4000, lon: -99.1500, admin1: "Ciudad de México", before: "Etc/GMT+7", after: "America/Mexico_City", truth: "America/Mexico_City"),
    MXCase(name: "Guadalajara", lat: 20.6597, lon: -103.3496, admin1: "Jalisco", before: "Etc/GMT+7", after: "America/Mexico_City", truth: "America/Mexico_City"),
    MXCase(name: "Cancun", lat: 21.0833, lon: -86.7667, admin1: "Quintana Roo", before: "Etc/GMT+6", after: "America/Cancun", truth: "America/Cancun"),
    MXCase(name: "Merida", lat: 20.9667, lon: -89.6167, admin1: "Yucatán", before: "Etc/GMT+6", after: "America/Mexico_City", truth: "America/Merida"),
    MXCase(name: "Bahia de Banderas", lat: 20.8000, lon: -105.2500, admin1: "Nayarit", before: "Etc/GMT+7", after: "America/Mazatlan", truth: "America/Bahia_Banderas"),
]

@Suite struct U37AuditFixTests {
    // MARK: - U10-F1: Guam and the western Aleutians

    @Test func guamAndWesternAleutiansGetTheirOwnZones() {
        // Hagatna (zone.tab +1328+14445) with code "GU" and code-less (the coordinate fallback).
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 13.4667, lon: 144.75, countryCode: "GU", admin1: "") == "Pacific/Guam")
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 13.4667, lon: 144.75, countryCode: "", admin1: "") == "Pacific/Guam")
        // Attu, west of 180.
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 52.85, lon: 173.2, countryCode: "US", admin1: "Alaska") == "America/Adak")
        // The western-hemisphere bands are untouched.
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 25.7617, lon: -80.1918, countryCode: "US", admin1: "Florida") == "America/New_York")
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 61.2181, lon: -149.9003, countryCode: "US", admin1: "Alaska") == "America/Anchorage")
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 21.3069, lon: -157.8583, countryCode: "US", admin1: "Hawaii") == "Pacific/Honolulu")
    }

    // MARK: - U10-F2: inferred zones yield to a known exact zone

    @Test func inferredZoneYieldsToAKnownZoneWithin75Km() {
        // A Cincinnati Nominatim hit: the bands give Chicago; MapKit knows New York nearby.
        let known: [(lat: Double, lon: Double, tz: String)] = [(lat: 39.1, lon: -84.51, tz: "America/New_York")]
        #expect(WxAddressGeocoder.mergedTimezone(
            current: "America/Chicago", inferred: true, lat: 39.1031, lon: -84.5120,
            countryCode: "US", admin1: "Cincinnati, OH 45202", known: known
        ) == "America/New_York")
        // An exact zone (MapKit, Open-Meteo) is kept; an empty one is resolved as before.
        #expect(WxAddressGeocoder.mergedTimezone(
            current: "America/Chicago", inferred: false, lat: 39.1031, lon: -84.5120,
            countryCode: "US", admin1: "Cincinnati, OH 45202", known: known
        ) == "America/Chicago")
        #expect(WxAddressGeocoder.mergedTimezone(
            current: "", inferred: false, lat: 39.1031, lon: -84.5120,
            countryCode: "US", admin1: "Cincinnati, OH 45202", known: known
        ) == "America/New_York")
        // A Phoenix Census hit got America/Phoenix from the raw state "AZ"; with no known zone
        // within 75 km it stands (re-inferring from "Phoenix, AZ 85004" would give Denver).
        let farAway: [(lat: Double, lon: Double, tz: String)] = [(lat: 39.7392, lon: -104.9903, tz: "America/Denver")]
        #expect(WxAddressGeocoder.mergedTimezone(
            current: "America/Phoenix", inferred: true, lat: 33.4484, lon: -112.0740,
            countryCode: "US", admin1: "Phoenix, AZ 85004", known: farAway
        ) == "America/Phoenix")
    }

    // MARK: - U10-F3: query values keep '&', '=' and '+'

    @Test func queryValueEscapingKeepsDelimitersInsideTheValue() throws {
        for query in ["AT&T Stadium, Arlington", "Barnes & Noble", "a=b", "C+ Building"] {
            let escaped = try #require(query.addingPercentEncoding(withAllowedCharacters: WxAddressGeocoder.queryValueAllowed))
            #expect(!escaped.contains("&") && !escaped.contains("=") && !escaped.contains("+"), "\(escaped)")
            let url = try #require(URLComponents(string: "https://nominatim.openstreetmap.org/search?q=\(escaped)&format=jsonv2"))
            #expect(url.queryItems?.map(\.name) == ["q", "format"])
            #expect(url.queryItems?.first?.value == query)
        }
    }

    // MARK: - U10-F6: Mexican zones by state, border strip unchanged

    @Test func mexicanStatesGetMexicanZonesWithoutRegressingTheBorderStrip() {
        let dates = ["2026-01-15T12:00:00Z", "2026-07-15T12:00:00Z", "2026-12-15T12:00:00Z"]
        for c in mxCases {
            let got = WxAddressGeocoder.inferFallbackTimezone(lat: c.lat, lon: c.lon, countryCode: "MX", admin1: c.admin1)
            #expect(got == c.after, "\(c.name): \(got)")
            // No city is wrong on a date where the pre-fix zone was right.
            for d in dates where offsetHours(c.before, d) == offsetHours(c.truth, d) {
                #expect(offsetHours(got, d) == offsetHours(c.truth, d), "\(c.name) \(d): \(got)")
            }
        }
        // An empty state still falls through to the bands (Tijuana stays on Pacific time).
        #expect(WxAddressGeocoder.inferFallbackTimezone(lat: 32.5333, lon: -117.0167, countryCode: "MX", admin1: "") == "America/Los_Angeles")
    }

    // MARK: - U10-F7: Yukon without a country code

    @Test func yukonWithoutCountryCodeIsCanadaNotAlaska() throws {
        // Whitehorse and Dawson (zone.tab), code-less as on the coordinate fallback.
        for (lat, lon) in [(60.7167, -135.05), (64.0667, -139.4167)] {
            #expect(WxGeo.inCanada(lat: lat, lon: lon, countryCode: ""))
            #expect(WxAddressGeocoder.inferFallbackTimezone(lat: lat, lon: lon, countryCode: "", admin1: "") == "America/Vancouver")
            let place = try WxPlace(name: "Yukon", lat: lat, lon: lon)
            #expect(WxGeo.region(for: place) == .canada)
        }
        // The Alaska panhandle (Juneau, Skagway, Yakutat) stays Alaska.
        for (lat, lon) in [(58.3019, -134.4197), (59.4583, -135.3139), (59.5469, -139.7272)] {
            #expect(!WxGeo.inCanada(lat: lat, lon: lon, countryCode: ""))
            #expect(WxAddressGeocoder.inferFallbackTimezone(lat: lat, lon: lon, countryCode: "", admin1: "") == "America/Anchorage")
        }
    }
}
