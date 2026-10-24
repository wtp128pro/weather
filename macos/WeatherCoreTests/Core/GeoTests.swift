// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// GeoTests.swift - port of the geo cases of src/core/test-core.c (registered
// at src/core/test-core.c:3540-3541 and 3555-3560). Expected values are the C
// test literals, cited as path:line.

import Foundation
import Testing
@testable import WeatherCore

/// T0 = 2026-10-11T00:00:00Z (src/core/test-core.c:18).
private let geoT0: Int64 = 1_791_676_800

/// A box of src/core/test-core.c:3137-3142.
private struct GeoBox {
    let name: String
    let latMin, latMax, lonMin, lonMax: Double
}

/// assert_box_edges (src/core/test-core.c:3144-3161).
private func expectBoxEdges(
    _ inBox: (Double, Double) -> Bool, _ b: GeoBox, sourceLocation: SourceLocation = #_sourceLocation
) {
    let midLat = 0.5 * (b.latMin + b.latMax)
    let midLon = 0.5 * (b.lonMin + b.lonMax)
    #expect(inBox(b.latMin, b.lonMin), "\(b.name)", sourceLocation: sourceLocation)
    #expect(inBox(b.latMin, b.lonMax), "\(b.name)", sourceLocation: sourceLocation)
    #expect(inBox(b.latMax, b.lonMin), "\(b.name)", sourceLocation: sourceLocation)
    #expect(inBox(b.latMax, b.lonMax), "\(b.name)", sourceLocation: sourceLocation)
    #expect(inBox(midLat, midLon), "\(b.name)", sourceLocation: sourceLocation)
    #expect(!inBox(b.latMin - 0.001, midLon), "\(b.name)", sourceLocation: sourceLocation)
    #expect(!inBox(b.latMax + 0.001, midLon), "\(b.name)", sourceLocation: sourceLocation)
    if b.lonMin - 0.001 >= -180.0 {
        #expect(!inBox(midLat, b.lonMin - 0.001), "\(b.name)", sourceLocation: sourceLocation)
    }
    if b.lonMax + 0.001 <= 180.0 {
        #expect(!inBox(midLat, b.lonMax + 0.001), "\(b.name)", sourceLocation: sourceLocation)
    }
}

/// A row of sun_events (src/core/test-core.c:2130-2152).
private struct SunEvent {
    let city: String
    let lat, lon: Double
    let when: String
    let rising: Bool
}

/// sun_up_minutes (src/core/test-core.c:2246-2254).
private func sunUpMinutes(_ lat: Double, _ lon: Double, _ dayStart: Int64) -> Int {
    var up = 0
    var t = dayStart
    while t < dayStart + 86400 {
        up += WxGeo.sunIsUp(lat: lat, lon: lon, t: t) ? 1 : 0
        t += 60
    }
    return up
}

@Suite struct GeoTests {
    // C: /core/geo/round-valid
    @Test func roundValid() {
        // src/core/test-core.c:2006-2042
        expectNaN(WxGeo.round4(1e305))
        expectNaN(WxGeo.round4(-1e305))
        expectNaN(WxGeo.round4(.greatestFiniteMagnitude))
        expectNaN(WxGeo.round4(-.greatestFiniteMagnitude))
        #expect(abs(WxGeo.round4(1e300) - 1e300) <= 1e286)
        #expect(WxGeo.round4(1e-300) == 0.0)
        #expect(WxGeo.round4(-1e-300).sign == .plus)
        #expect(WxGeo.round4(90.00004) == 90.0)
        #expect(WxGeo.round4(-180.00004) == -180.0)
        #expect(WxGeo.isValid(lat: WxGeo.round4(89.99996), lon: WxGeo.round4(179.99996)))
        #expect(WxGeo.round4(25.76174) == 25.7617)
        #expect(WxGeo.round4(25.76176) == 25.7618)
        #expect(WxGeo.round4(-80.19184) == -80.1918)
        #expect(WxGeo.round4(-80.19186) == -80.1919)
        #expect(WxGeo.round4(0.0) == 0.0)
        #expect(WxGeo.round4(-0.00001).sign == .plus)  // -0 normalised
        #expect(WxGeo.round4(-0.0).sign == .plus)
        #expect(WxGeo.round4(180.0) == 180.0)
        #expect(WxGeo.round4(-90.0) == -90.0)
        expectNaN(WxGeo.round4(.nan))
        expectNaN(WxGeo.round4(.infinity))
        expectNaN(WxGeo.round4(-.infinity))

        #expect(WxGeo.isValid(lat: 0, lon: 0))
        #expect(WxGeo.isValid(lat: 90, lon: 180))
        #expect(WxGeo.isValid(lat: -90, lon: -180))
        #expect(!WxGeo.isValid(lat: 90.0001, lon: 0))
        #expect(!WxGeo.isValid(lat: 0, lon: 180.0001))
        #expect(!WxGeo.isValid(lat: -91, lon: 0))
        #expect(!WxGeo.isValid(lat: 0, lon: -181))
        #expect(!WxGeo.isValid(lat: .nan, lon: 0))
        #expect(!WxGeo.isValid(lat: 0, lon: .nan))
        #expect(!WxGeo.isValid(lat: .infinity, lon: 0))
        #expect(!WxGeo.isValid(lat: 0, lon: -.infinity))
    }

    // C: /core/geo/boxes
    @Test func boxes() {
        // NWS coverage, src/core/test-core.c:2048-2075
        let nwsIn: [(Double, Double)] = [
            (25.7617, -80.1918), (24.55, -81.78), (40.71, -74.0), (47.61, -122.33), (32.72, -117.16),
            (44.8, -68.8), (61.22, -149.9), (64.84, -147.72), (71.29, -156.79), (53.89, -166.54),
            (52.2, 174.2), (21.31, -157.86), (19.7, -155.09), (18.47, -66.1), (18.34, -64.93),
            (13.47, 144.75),
        ]
        for (lat, lon) in nwsIn {
            #expect(WxGeo.inUSNWS(lat: lat, lon: lon), "\(lat),\(lon)")
        }
        let nwsOut: [(Double, Double)] = [
            (51.5074, -0.1278), (-33.87, 151.21), (35.68, 139.69), (19.43, -99.13), (23.1, -82.4),
            (0, 0), (-89, 0), (.nan, -80), (25, .nan), (.infinity, -80), (95, -80), (40, 260),
        ]
        for (lat, lon) in nwsOut {
            #expect(!WxGeo.inUSNWS(lat: lat, lon: lon), "\(lat),\(lon)")
        }

        // CONUS box, src/core/test-core.c:2078-2087
        #expect(WxGeo.inCONUS(lat: 25.7617, lon: -80.1918))
        #expect(WxGeo.inCONUS(lat: 21.0, lon: -135.0))
        #expect(WxGeo.inCONUS(lat: 53.0, lon: -60.0))
        #expect(!WxGeo.inCONUS(lat: 20.99, lon: -100.0))
        #expect(!WxGeo.inCONUS(lat: 53.01, lon: -100.0))
        #expect(!WxGeo.inCONUS(lat: 40.0, lon: -135.01))
        #expect(!WxGeo.inCONUS(lat: 40.0, lon: -59.99))
        #expect(!WxGeo.inCONUS(lat: 51.5, lon: -0.12))
        #expect(!WxGeo.inCONUS(lat: 21.31, lon: -157.86))  // Hawaii is outside HRRR conus
        #expect(!WxGeo.inCONUS(lat: .nan, lon: -100))

        // Europe box, src/core/test-core.c:2090-2100
        #expect(WxGeo.inEurope(lat: 51.5074, lon: -0.1278))
        #expect(WxGeo.inEurope(lat: 34.0, lon: -25.0))
        #expect(WxGeo.inEurope(lat: 72.0, lon: 45.0))
        #expect(WxGeo.inEurope(lat: 59.91, lon: 10.75))
        #expect(!WxGeo.inEurope(lat: 33.99, lon: 10))
        #expect(!WxGeo.inEurope(lat: 72.01, lon: 10))
        #expect(!WxGeo.inEurope(lat: 50, lon: -25.01))
        #expect(!WxGeo.inEurope(lat: 50, lon: 45.01))
        #expect(!WxGeo.inEurope(lat: 25.76, lon: -80.19))
        #expect(!WxGeo.inEurope(lat: .nan, lon: 0))
        #expect(!WxGeo.inEurope(lat: 0, lon: .infinity))
    }

    // C: /core/geo/box-edges
    @Test func boxEdges() {
        // the numbers documented in wx-geo.h, src/core/test-core.c:3167-3184
        let nws = [
            GeoBox(name: "contiguous US", latMin: 24.0, latMax: 50.0, lonMin: -125.0, lonMax: -66.5),
            GeoBox(name: "Alaska", latMin: 51.0, latMax: 72.0, lonMin: -180.0, lonMax: -129.0),
            GeoBox(name: "western Aleutians", latMin: 51.0, latMax: 56.0, lonMin: 172.0, lonMax: 180.0),
            GeoBox(name: "Hawaii", latMin: 18.5, latMax: 22.5, lonMin: -161.0, lonMax: -154.0),
            GeoBox(name: "Puerto Rico / USVI", latMin: 17.5, latMax: 18.8, lonMin: -68.0, lonMax: -64.5),
            GeoBox(name: "Guam", latMin: 13.0, latMax: 14.0, lonMin: 144.0, lonMax: 145.2),
        ]
        for b in nws {
            expectBoxEdges({ WxGeo.inUSNWS(lat: $0, lon: $1) }, b)
        }
        expectBoxEdges(
            { WxGeo.inCONUS(lat: $0, lon: $1) },
            GeoBox(name: "HRRR box", latMin: 21.0, latMax: 53.0, lonMin: -135.0, lonMax: -60.0))
        expectBoxEdges(
            { WxGeo.inEurope(lat: $0, lon: $1) },
            GeoBox(name: "Europe box", latMin: 34.0, latMax: 72.0, lonMin: -25.0, lonMax: 45.0))
    }

    // C: /core/geo/distance (SeededRNG replaces GRand seed 5)
    @Test func distance() {
        // src/core/test-core.c:2106-2127
        #expect(WxGeo.distanceKm(aLat: 10, aLon: 20, bLat: 10, bLon: 20) == 0.0)
        expectNear(WxGeo.distanceKm(aLat: 25.7617, aLon: -80.1918, bLat: 51.5074, bLon: -0.1278), 7126.9, eps: 1.0)
        expectNear(WxGeo.distanceKm(aLat: 0, aLon: 0, bLat: 0, bLon: 1), 111.195, eps: 0.01)
        expectNear(WxGeo.distanceKm(aLat: 0, aLon: 0, bLat: 1, bLon: 0), 111.195, eps: 0.01)
        expectNear(WxGeo.distanceKm(aLat: 0, aLon: 0, bLat: 0, bLon: 180), 20015.1, eps: 0.1)  // antipodes
        expectNear(WxGeo.distanceKm(aLat: 90, aLon: 0, bLat: -90, bLon: 0), 20015.1, eps: 0.1)  // poles
        expectNear(WxGeo.distanceKm(aLat: 0, aLon: 179.9, bLat: 0, bLon: -179.9), 22.239, eps: 0.01)  // date line
        // symmetric and never negative
        #expect(
            WxGeo.distanceKm(aLat: -33.87, aLon: 151.21, bLat: 51.5, bLon: -0.12)
                == WxGeo.distanceKm(aLat: 51.5, aLon: -0.12, bLat: -33.87, bLon: 151.21))
        var rng = SeededRNG(seed: 5)
        for _ in 0..<5000 {
            let a = Double.random(in: -90..<90, using: &rng)
            let b = Double.random(in: -180..<180, using: &rng)
            let c = Double.random(in: -90..<90, using: &rng)
            let d = Double.random(in: -180..<180, using: &rng)
            let km = WxGeo.distanceKm(aLat: a, aLon: b, bLat: c, bLon: d)
            #expect(km >= 0.0 && km <= 20015.12, "\(a),\(b) -> \(c),\(d): \(km)")
        }
        // invalid points are NaN, not a crash
        expectNaN(WxGeo.distanceKm(aLat: .nan, aLon: 0, bLat: 0, bLon: 0))
        expectNaN(WxGeo.distanceKm(aLat: 0, aLon: 0, bLat: 91, bLon: 0))
        expectNaN(WxGeo.distanceKm(aLat: 0, aLon: 0, bLat: 0, bLon: 181))
        expectNaN(WxGeo.distanceKm(aLat: 0, aLon: .infinity, bLat: 0, bLon: 0))
    }

    // C: /core/geo/rounding-clamps
    @Test func roundingClamps() {
        // the sun exactly overhead / at the nadir, src/core/test-core.c:3076-3080
        #expect(WxGeo.sunIsUp(lat: -22.977484256883766, lon: 6.4150193887007436, t: 1_767_267_474))
        #expect(WxGeo.sunIsUp(lat: -22.95178723335215, lon: -101.55816157199749, t: 1_767_293_396))
        #expect(!WxGeo.sunIsUp(lat: 23.015200120310002, lon: -9.5844338919206038, t: 1_767_228_101))
        #expect(!WxGeo.sunIsUp(lat: 23.013826171322677, lon: -15.682435367175831, t: 1_767_229_565))
        // antipodal points: half the circumference, src/core/test-core.c:3087-3095
        let lats = [-43.449997000000003, -42.999996099999997, -39.299988700000007, -34.999980100000002,
                    -29.299968700000004]
        let lons = [-175.0, -174.09999999999999, -166.69999999999999, -158.09999999999999, -146.69999999999999]
        for i in lats.indices {
            let km = WxGeo.distanceKm(aLat: lats[i], aLon: lons[i], bLat: -lats[i], bLon: lons[i] + 180.0)
            #expect(km.isFinite)
            expectNear(km, 20015.114, eps: 0.01)
        }
    }

    // C: /core/geo/sun-usno-transitions
    @Test func sunUSNOTransitions() throws {
        // src/core/test-core.c:2127-2152 (tolerances 90 s / 150 s)
        let events = [
            SunEvent(city: "Miami 2026-10-11", lat: 25.7617, lon: -80.1918, when: "2026-10-11T07:18:00-04:00", rising: true),
            SunEvent(city: "Miami 2026-10-11", lat: 25.7617, lon: -80.1918, when: "2026-10-11T18:57:00-04:00", rising: false),
            SunEvent(city: "London 2026-10-11", lat: 51.5074, lon: -0.1278, when: "2026-10-11T07:18:00+01:00", rising: true),
            SunEvent(city: "London 2026-10-11", lat: 51.5074, lon: -0.1278, when: "2026-10-11T18:16:00+01:00", rising: false),
            SunEvent(city: "Sydney 2026-10-11", lat: -33.8688, lon: 151.2093, when: "2026-10-11T06:19:00+11:00", rising: true),
            SunEvent(city: "Sydney 2026-10-11", lat: -33.8688, lon: 151.2093, when: "2026-10-11T19:05:00+11:00", rising: false),
            SunEvent(city: "London 2026-06-21", lat: 51.5074, lon: -0.1278, when: "2026-06-21T04:43:00+01:00", rising: true),
            SunEvent(city: "London 2026-06-21", lat: 51.5074, lon: -0.1278, when: "2026-06-21T21:22:00+01:00", rising: false),
            SunEvent(city: "Miami 2026-12-21", lat: 25.7617, lon: -80.1918, when: "2026-12-21T07:03:00-05:00", rising: true),
            SunEvent(city: "Miami 2026-12-21", lat: 25.7617, lon: -80.1918, when: "2026-12-21T17:35:00-05:00", rising: false),
            SunEvent(city: "Sydney 2026-12-21", lat: -33.8688, lon: 151.2093, when: "2026-12-21T05:41:00+11:00", rising: true),
            SunEvent(city: "Sydney 2026-12-21", lat: -33.8688, lon: 151.2093, when: "2026-12-21T20:05:00+11:00", rising: false),
            SunEvent(city: "Reykjavik 2026-06-21", lat: 64.1466, lon: -21.9426, when: "2026-06-21T00:04:00+00:00", rising: false),
            SunEvent(city: "Reykjavik 2026-06-21", lat: 64.1466, lon: -21.9426, when: "2026-06-21T02:55:00+00:00", rising: true),
            SunEvent(city: "Fairbanks 2026-06-21", lat: 64.8378, lon: -147.7164, when: "2026-06-21T00:47:00-08:00", rising: false),
            SunEvent(city: "Fairbanks 2026-06-21", lat: 64.8378, lon: -147.7164, when: "2026-06-21T02:58:00-08:00", rising: true),
            SunEvent(city: "Murmansk 2026-07-25", lat: 68.9585, lon: 33.0827, when: "2026-07-25T00:02:00+03:00", rising: false),
            SunEvent(city: "Murmansk 2026-07-25", lat: 68.9585, lon: 33.0827, when: "2026-07-25T01:47:00+03:00", rising: true),
            SunEvent(city: "Murmansk 2026-07-25", lat: 68.9585, lon: 33.0827, when: "2026-07-25T23:52:00+03:00", rising: false),
            SunEvent(city: "Tromso 2026-07-26", lat: 69.6492, lon: 18.9553, when: "2026-07-26T00:36:00+02:00", rising: false),
            SunEvent(city: "Tromso 2026-07-26", lat: 69.6492, lon: 18.9553, when: "2026-07-26T01:06:00+02:00", rising: true),
        ]
        for e in events {
            let want = try #require(WxTime.parseISO8601(e.when), "\(e.when)")
            // src/core/test-core.c:2160-2186
            var lo = want - 600
            var hi = want + 600
            #expect(WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: lo) == !e.rising, "\(e.city)")
            #expect(WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: hi) == e.rising, "\(e.city)")
            let atLo = WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: lo)
            while hi - lo > 1 {
                let mid = lo + (hi - lo) / 2
                if WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: mid) == atLo {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            #expect(WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: hi) == e.rising, "\(e.city)")
            #expect(WxGeo.sunIsUp(lat: e.lat, lon: e.lon, t: hi - 1) == !e.rising, "\(e.city)")
            let tolerance: Int64 = abs(e.lat) > 60.0 ? 150 : 90
            #expect(abs(hi - want) <= tolerance, "\(e.city) \(e.rising ? "rise" : "set"): off by \(hi - want) s")
        }
    }

    // C: /core/geo/sun-is-up
    @Test func sunIsUpSanity() throws {
        // src/core/test-core.c:2205-2253
        let noonUTC = geoT0 + 12 * 3600
        #expect(WxGeo.sunIsUp(lat: 51.5, lon: 0.0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 51.5, lon: 0.0, t: geoT0))
        #expect(WxGeo.sunIsUp(lat: 0.0, lon: 0.0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: noonUTC))
        #expect(WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: geoT0))
        let equinox = try #require(WxTime.parseISO8601("2026-03-20T00:00:00Z"))
        var up: Int64 = 0
        var t = equinox
        while t < equinox + 86400 {
            up += WxGeo.sunIsUp(lat: 0.0, lon: 0.0, t: t) ? 60 : 0
            t += 60
        }
        #expect(up >= 12 * 3600 - 15 * 60)
        #expect(up <= 12 * 3600 + 15 * 60)

        // hostile arguments are "night"
        #expect(!WxGeo.sunIsUp(lat: .nan, lon: 0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: .nan, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: .infinity, lon: 0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: -.infinity, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 89.5, lon: 0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: -89.5, lon: 0, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 181, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: -181, t: noonUTC))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: 0))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: -1))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: 946_684_800 - 1))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: .max))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: .min))
        #expect(!WxGeo.sunIsUp(lat: 0, lon: 0, t: 4_133_980_800))
        // the time range is half open [WX_TIME_MIN_S, WX_TIME_MAX_S)
        #expect(WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: 946_684_800))
        #expect(!WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: 946_684_800 - 1))
        #expect(WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: 4_133_980_800 - 1))
        #expect(!WxGeo.sunIsUp(lat: 0.0, lon: 180.0, t: 4_133_980_800))
    }

    // C: /core/geo/sun-polar
    @Test func sunPolar() throws {
        // src/core/test-core.c:2259-2289
        let june = try #require(WxTime.parseISO8601("2026-06-21T00:00:00Z"))
        let dec = try #require(WxTime.parseISO8601("2026-12-21T00:00:00Z"))
        #expect(sunUpMinutes(69.6492, 18.9553, june) == 1440)
        #expect(sunUpMinutes(69.6492, 18.9553, dec) == 0)
        #expect(sunUpMinutes(80.0, 20.0, june) == 1440)
        #expect(sunUpMinutes(80.0, 20.0, dec) == 0)
        #expect(sunUpMinutes(89.0, 0.0, june) == 1440)
        #expect(sunUpMinutes(89.0, 0.0, dec) == 0)
        #expect(sunUpMinutes(-89.0, 0.0, june) == 0)
        #expect(sunUpMinutes(-89.0, 0.0, dec) == 1440)
        #expect(sunUpMinutes(-77.85, 166.67, dec) == 1440)  // McMurdo
        #expect(sunUpMinutes(-77.85, 166.67, june) == 0)
        let autumn = try #require(WxTime.parseISO8601("2026-10-10T22:00:00Z"))
        let up = sunUpMinutes(69.6492, 18.9553, autumn)
        #expect(up > 5 * 60)
        #expect(up < 10 * 60)
        // beyond 89 degrees the function refuses
        #expect(sunUpMinutes(89.0001, 0.0, june) == 0)
        #expect(sunUpMinutes(90.0, 0.0, june) == 0)
        #expect(sunUpMinutes(-89.0001, 0.0, dec) == 0)
        #expect(sunUpMinutes(-90.0, 0.0, dec) == 0)
    }
}
