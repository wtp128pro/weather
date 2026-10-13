/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-geo.h - coordinate validation, coarse coverage boxes, great-circle
 * distance and the day/night test (NOAA solar position algorithm).
 *
 * Latitude is degrees north (-90..90), longitude degrees east (-180..180).
 * Every function is pure (no allocation, no global state, no locale or
 * time-zone use) and rejects non-finite arguments instead of asserting, so it
 * is safe to call with coordinates that came from outside the process.
 */
#ifndef WX_GEO_H
#define WX_GEO_H

#include <glib.h>

G_BEGIN_DECLS

/**
 * wx_geo_round4:
 * @v: a coordinate in degrees.
 *
 * Rounds to four decimals (about 11 m), the precision providers accept
 * (MET Norway answers 403 for more).
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed; negative zero is normalised to +0.0.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: round(v * 10000) / 10000, or NAN when @v is not finite or the
 *   scaled value overflows (|v| above about 1.8e304).
 */
double wx_geo_round4(double v);

/**
 * wx_geo_valid:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff both are finite, lat in [-90, 90] and lon in [-180, 180].
 */
gboolean wx_geo_valid(double lat, double lon);

/**
 * wx_geo_in_us_nws:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 *
 * Coarse pre-filter for National Weather Service coverage: boxes for the
 * contiguous US (lat 24..50, lon -125..-66.5), Alaska (lat 51..72, lon
 * -180..-129, plus the western Aleutians: lat 51..56, lon 172..180), Hawaii
 * (lat 18.5..22.5, lon -161..-154), Puerto Rico / US
 * Virgin Islands (lat 17.5..18.8, lon -68..-64.5) and Guam (lat 13..14, lon
 * 144..145.2). The boxes include neighbouring Canadian/Mexican/Cuban
 * land; the NWS "404 outside coverage" answer stays authoritative.
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the valid coordinate lies in one of the boxes.
 */
gboolean wx_geo_in_us_nws(double lat, double lon);

/**
 * wx_geo_in_conus:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 *
 * Simple box approximating the HRRR domain: lat 21..53, lon -135..-60.
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the valid coordinate lies in the box.
 */
gboolean wx_geo_in_conus(double lat, double lon);

/**
 * wx_geo_in_europe:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 *
 * Simple box: lat 34..72, lon -25..45.
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the valid coordinate lies in the box.
 */
gboolean wx_geo_in_europe(double lat, double lon);

/**
 * wx_geo_distance_km:
 * @a_lat: latitude of point A.
 * @a_lon: longitude of point A.
 * @b_lat: latitude of point B.
 * @b_lon: longitude of point B.
 *
 * Great-circle distance by the haversine formula on a sphere of radius
 * 6371.0088 km (a sphere, not the WGS84 ellipsoid).
 *
 * Preconditions: none (invalid points are reported with NAN).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the distance in kilometres, in [0, 20015.12] (half the sphere's
 *   circumference), or NAN when either point fails wx_geo_valid().
 */
double wx_geo_distance_km(double a_lat, double a_lon, double b_lat, double b_lon);

/**
 * wx_sun_is_up:
 * @lat: latitude in degrees, [-89, 89].
 * @lon: longitude in degrees, [-180, 180].
 * @t_s: UTC unix seconds, within [WX_TIME_MIN_S, WX_TIME_MAX_S).
 *
 * Day/night test for icon selection: whether the sun's upper limb is above
 * the horizon, i.e. the solar altitude (NOAA solar position algorithm, no
 * extra refraction term) is greater than -0.833 degrees (the standard
 * sunrise/sunset definition: refraction plus the solar semi-diameter).
 * Against the U.S. Naval Observatory sunrise/sunset tables (minute
 * resolution) the day/night transition is within 90 s at Miami, London and
 * Sydney, on 2026-10-11 and on a 2026 solstice day (tested). Where the sun only
 * skims the horizon (high-latitude summer, the altitude changes by about
 * 0.005 degree per minute) a 0.01 degree model difference already moves the
 * transition by two minutes, so there it is tested only to within 150 s
 * (Reykjavik, Fairbanks, Murmansk, Tromso). Polar day and polar night are
 * handled by the same test: the sun is reported up for every minute of
 * 2026-06-21 at Tromso, 80 degrees north and 89 degrees north, and down for
 * every minute of 2026-12-21 (tested). The algorithm is not meant for the
 * immediate neighbourhood of the poles, so latitudes beyond 89 degrees are
 * refused (reported as "not up").
 *
 * Preconditions: none (invalid arguments are reported as night, no critical).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the sun is up; FALSE at night and also for invalid
 *   arguments (non-finite, |lat| > 89, lon out of range, t_s out of range).
 */
gboolean wx_sun_is_up(double lat, double lon, gint64 t_s);

G_END_DECLS

#endif /* WX_GEO_H */
