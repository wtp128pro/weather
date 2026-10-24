// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 wtp128pro
//
// Geo.swift - coordinate validation, coarse coverage boxes, great-circle
// distance and the day/night test (NOAA solar position algorithm). Port of
// src/core/wx-geo.{h,c}: the same formulas in the same operation order, with
// the C libm functions (round, fmod, sin, cos, tan, asin, acos, sqrt).
//
// Latitude is degrees north (-90...90), longitude degrees east (-180...180).
// Every function is pure (no locale or time-zone use) and rejects non-finite
// arguments instead of trapping.

import Foundation

/// Geographic helpers (src/core/wx-geo.h).
public enum WxGeo {
    /// Sphere radius of the haversine distance, km (src/core/wx-geo.c:9).
    private static let earthRadiusKm = 6371.0088
    /// G_PI / 180.0 and 180.0 / G_PI (src/core/wx-geo.c:10-11).
    private static let deg2rad = Double.pi / 180.0
    private static let rad2deg = 180.0 / Double.pi
    /// Standard sunrise/sunset altitude: refraction (34') + solar semi-diameter (16')
    /// (src/core/wx-geo.c:13).
    private static let sunHorizonDeg = -0.833
    /// Latitudes beyond this are refused by sunIsUp (src/core/wx-geo.c:14).
    private static let sunMaxAbsLat = 89.0

    /// wx_geo_round4: `round(v * 10000) / 10000` (half away from zero), NaN when
    /// `v` is not finite or the scaled value overflows; -0 becomes +0.
    public static func round4(_ v: Double) -> Double {
        if !v.isFinite {
            return .nan
        }
        let r = Foundation.round(v * 10000.0) / 10000.0
        if !r.isFinite {  // v * 10000 overflowed (|v| above ~1.8e304)
            return .nan
        }
        return r == 0.0 ? 0.0 : r  // -0.0 -> +0.0
    }

    /// wx_geo_valid: both finite, lat in [-90, 90] and lon in [-180, 180].
    public static func isValid(lat: Double, lon: Double) -> Bool {
        WxLimits.valueInRange(lat, -90.0, 90.0) && WxLimits.valueInRange(lon, -180.0, 180.0)
    }

    /// in_box: inclusive on every side; NaN is never inside (src/core/wx-geo.c:52-55).
    private static func inBox(
        _ lat: Double, _ lon: Double, _ latMin: Double, _ latMax: Double, _ lonMin: Double, _ lonMax: Double
    ) -> Bool {
        lat >= latMin && lat <= latMax && lon >= lonMin && lon <= lonMax
    }

    /// wx_geo_in_us_nws: coarse NWS coverage pre-filter, the union of the
    /// inclusive boxes contiguous US (lat 24...50, lon -125...-66.5), Alaska
    /// (51...72, -180...-129), western Aleutians (51...56, 172...180), Hawaii
    /// (18.5...22.5, -161...-154), Puerto Rico / USVI (17.5...18.8, -68...-64.5)
    /// and Guam (13...14, 144...145.2). False for invalid coordinates.
    public static func inUSNWS(lat: Double, lon: Double) -> Bool {
        if !isValid(lat: lat, lon: lon) {
            return false
        }
        return inBox(lat, lon, 24.0, 50.0, -125.0, -66.5)  // contiguous US
            || inBox(lat, lon, 51.0, 72.0, -180.0, -129.0)  // Alaska
            || inBox(lat, lon, 51.0, 56.0, 172.0, 180.0)  // Aleutians west of 180
            || inBox(lat, lon, 18.5, 22.5, -161.0, -154.0)  // Hawaii
            || inBox(lat, lon, 17.5, 18.8, -68.0, -64.5)  // Puerto Rico, USVI
            || inBox(lat, lon, 13.0, 14.0, 144.0, 145.2)  // Guam
    }

    /// wx_geo_in_conus: the HRRR-domain box, lat 21...53, lon -135...-60 (inclusive).
    public static func inCONUS(lat: Double, lon: Double) -> Bool {
        isValid(lat: lat, lon: lon) && inBox(lat, lon, 21.0, 53.0, -135.0, -60.0)
    }

    /// wx_geo_in_europe: lat 34...72, lon -25...45 (inclusive).
    public static func inEurope(lat: Double, lon: Double) -> Bool {
        isValid(lat: lat, lon: lon) && inBox(lat, lon, 34.0, 72.0, -25.0, 45.0)
    }

    /// wx_geo_distance_km: haversine great-circle distance on a sphere of radius
    /// 6371.0088 km, in [0, 20015.12]; NaN when either point is invalid.
    public static func distanceKm(aLat: Double, aLon: Double, bLat: Double, bLon: Double) -> Double {
        if !isValid(lat: aLat, lon: aLon) || !isValid(lat: bLat, lon: bLon) {
            return .nan
        }
        let phi1 = aLat * deg2rad
        let phi2 = bLat * deg2rad
        let dphi = (bLat - aLat) * deg2rad
        let dlambda = (bLon - aLon) * deg2rad
        let s1 = sin(dphi / 2.0)
        let s2 = sin(dlambda / 2.0)
        var h = s1 * s1 + cos(phi1) * cos(phi2) * s2 * s2
        h = h < 1.0 ? h : 1.0  // MIN(h, 1.0), the ternary macro
        return 2.0 * earthRadiusKm * asin(sqrt(h))
    }

    /// sun_altitude_deg (src/core/wx-geo.c:121-161): NOAA solar altitude in
    /// degrees, without refraction. Arguments are range-checked by sunIsUp.
    private static func sunAltitudeDeg(lat: Double, lon: Double, t: Int64) -> Double {
        let jd = Double(t) / 86400.0 + 2440587.5
        let T = (jd - 2451545.0) / 36525.0  // Julian centuries since J2000

        let l0 = fmod(280.46646 + T * (36000.76983 + T * 0.0003032), 360.0)
        let m = (357.52911 + T * (35999.05029 - 0.0001537 * T)) * deg2rad
        let ecc = 0.016708634 - T * (0.000042037 + 0.0000001267 * T)
        let centre = sin(m) * (1.914602 - T * (0.004817 + 0.000014 * T))
            + sin(2.0 * m) * (0.019993 - 0.000101 * T) + sin(3.0 * m) * 0.000289
        let trueLong = l0 + centre
        let omega = (125.04 - 1934.136 * T) * deg2rad
        let lambda = (trueLong - 0.00569 - 0.00478 * sin(omega)) * deg2rad
        let eps0 = 23.0 + (26.0 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60.0) / 60.0
        let eps = (eps0 + 0.00256 * cos(omega)) * deg2rad
        let decl = asin(sin(eps) * sin(lambda))

        var y = tan(eps / 2.0)
        y *= y
        let l0r = l0 * deg2rad
        let eqtimeMin = 4.0 * rad2deg
            * (y * sin(2.0 * l0r) - 2.0 * ecc * sin(m) + 4.0 * ecc * y * sin(m) * cos(2.0 * l0r)
                - 0.5 * y * y * sin(4.0 * l0r) - 1.25 * ecc * ecc * sin(2.0 * m))

        // t >= WxLimits.timeMinS > 0 (checked by sunIsUp), so the remainder is not negative.
        let utcMin = Double(t % 86400) / 60.0
        let trueSolarMin = utcMin + eqtimeMin + 4.0 * lon
        let hourAngle = (trueSolarMin / 4.0 - 180.0) * deg2rad

        let phi = lat * deg2rad
        var cosZenith = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hourAngle)
        // CLAMP(cos_zenith, -1.0, 1.0), the ternary macro: rounding can leave it a hair outside.
        cosZenith = cosZenith > 1.0 ? 1.0 : (cosZenith < -1.0 ? -1.0 : cosZenith)
        return 90.0 - acos(cosZenith) * rad2deg
    }

    /// wx_sun_is_up: whether the sun's upper limb is above the horizon (NOAA
    /// solar altitude > -0.833 degrees) at `lat`, `lon` and UTC unix second `t`.
    /// False at night and for invalid arguments: non-finite, |lat| > 89, lon
    /// outside [-180, 180], `t` outside [WxLimits.timeMinS, WxLimits.timeMaxS).
    public static func sunIsUp(lat: Double, lon: Double, t: Int64) -> Bool {
        if !WxLimits.valueInRange(lat, -sunMaxAbsLat, sunMaxAbsLat) || !WxLimits.valueInRange(lon, -180.0, 180.0)
            || t < WxLimits.timeMinS || t >= WxLimits.timeMaxS
        {
            return false
        }
        return sunAltitudeDeg(lat: lat, lon: lon, t: t) > sunHorizonDeg
    }
}
