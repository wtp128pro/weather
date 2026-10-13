/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-geo.h"

#include <math.h>

#include "wx-types.h"

#define EARTH_RADIUS_KM 6371.0088
#define DEG2RAD (G_PI / 180.0)
#define RAD2DEG (180.0 / G_PI)
/* Standard sunrise/sunset altitude: refraction (34') + solar semi-diameter (16'). */
#define SUN_HORIZON_DEG (-0.833)
#define SUN_MAX_ABS_LAT 89.0

/* Documented in wx-geo.h. */
double
wx_geo_round4(double v)
{
  if (!isfinite(v))
    return NAN;
  double r = round(v * 10000.0) / 10000.0;
  if (!isfinite(r)) /* v * 10000 overflowed (|v| above ~1.8e304) */
    return NAN;
  return r == 0.0 ? 0.0 : r; /* -0.0 -> +0.0 */
}

/* Documented in wx-geo.h. */
gboolean
wx_geo_valid(double lat, double lon)
{
  return wx_value_in_range(lat, -90.0, 90.0) && wx_value_in_range(lon, -180.0, 180.0);
}

/**
 * in_box:
 * @lat: latitude.
 * @lon: longitude.
 * @lat_min: inclusive south bound.
 * @lat_max: inclusive north bound.
 * @lon_min: inclusive west bound.
 * @lon_max: inclusive east bound.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the point is inside the box (NAN is never inside).
 */
static gboolean
in_box(double lat, double lon, double lat_min, double lat_max, double lon_min, double lon_max)
{
  return lat >= lat_min && lat <= lat_max && lon >= lon_min && lon <= lon_max;
}

/* Documented in wx-geo.h. */
gboolean
wx_geo_in_us_nws(double lat, double lon)
{
  if (!wx_geo_valid(lat, lon))
    return FALSE;
  return in_box(lat, lon, 24.0, 50.0, -125.0, -66.5) ||   /* contiguous US */
         in_box(lat, lon, 51.0, 72.0, -180.0, -129.0) ||  /* Alaska */
         in_box(lat, lon, 51.0, 56.0, 172.0, 180.0) ||    /* Aleutians west of 180 */
         in_box(lat, lon, 18.5, 22.5, -161.0, -154.0) ||  /* Hawaii */
         in_box(lat, lon, 17.5, 18.8, -68.0, -64.5) ||    /* Puerto Rico, USVI */
         in_box(lat, lon, 13.0, 14.0, 144.0, 145.2);      /* Guam */
}

/* Documented in wx-geo.h. */
gboolean
wx_geo_in_conus(double lat, double lon)
{
  return wx_geo_valid(lat, lon) && in_box(lat, lon, 21.0, 53.0, -135.0, -60.0);
}

/* Documented in wx-geo.h. */
gboolean
wx_geo_in_europe(double lat, double lon)
{
  return wx_geo_valid(lat, lon) && in_box(lat, lon, 34.0, 72.0, -25.0, 45.0);
}

/* Documented in wx-geo.h. */
double
wx_geo_distance_km(double a_lat, double a_lon, double b_lat, double b_lon)
{
  if (!wx_geo_valid(a_lat, a_lon) || !wx_geo_valid(b_lat, b_lon))
    return NAN;
  double phi1 = a_lat * DEG2RAD;
  double phi2 = b_lat * DEG2RAD;
  double dphi = (b_lat - a_lat) * DEG2RAD;
  double dlambda = (b_lon - a_lon) * DEG2RAD;
  double s1 = sin(dphi / 2.0);
  double s2 = sin(dlambda / 2.0);
  double h = s1 * s1 + cos(phi1) * cos(phi2) * s2 * s2;
  /* h >= 0 by construction. At antipodes rounding pushes it above 1 (seen: 1.0000000000000002,
   * which sqrt() rounds back to 1.0); the cap keeps a larger overshoot from making asin() NAN. */
  h = MIN(h, 1.0);
  return 2.0 * EARTH_RADIUS_KM * asin(sqrt(h));
}

/**
 * sun_altitude_deg:
 * @lat: latitude in degrees, |lat| <= 89.
 * @lon: longitude in degrees east, [-180, 180].
 * @t_s: UTC unix time in whole seconds, within [WX_TIME_MIN_S, WX_TIME_MAX_S).
 *
 * Solar altitude above the horizon by the NOAA solar position algorithm
 * (Meeus: geometric mean longitude/anomaly, equation of centre, apparent
 * longitude, obliquity, declination, equation of time, hour angle). No
 * refraction is added: the only caller, wx_sun_is_up(), compares against
 * SUN_HORIZON_DEG.
 *
 * Preconditions:
 *  - the arguments are within the ranges above (checked by wx_sun_is_up()).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the altitude in degrees, [-90, 90].
 */
static double
sun_altitude_deg(double lat, double lon, gint64 t_s)
{
  double jd = (double)t_s / 86400.0 + 2440587.5;
  double T = (jd - 2451545.0) / 36525.0; /* Julian centuries since J2000 */

  double l0 = fmod(280.46646 + T * (36000.76983 + T * 0.0003032), 360.0);
  double m = (357.52911 + T * (35999.05029 - 0.0001537 * T)) * DEG2RAD;
  double ecc = 0.016708634 - T * (0.000042037 + 0.0000001267 * T);
  double centre = sin(m) * (1.914602 - T * (0.004817 + 0.000014 * T)) +
                  sin(2.0 * m) * (0.019993 - 0.000101 * T) + sin(3.0 * m) * 0.000289;
  double true_long = l0 + centre;
  double omega = (125.04 - 1934.136 * T) * DEG2RAD;
  double lambda = (true_long - 0.00569 - 0.00478 * sin(omega)) * DEG2RAD;
  double eps0 =
    23.0 + (26.0 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60.0) / 60.0;
  double eps = (eps0 + 0.00256 * cos(omega)) * DEG2RAD;
  double decl = asin(sin(eps) * sin(lambda));

  double y = tan(eps / 2.0);
  y *= y;
  double l0r = l0 * DEG2RAD;
  double eqtime_min =
    4.0 * RAD2DEG *
    (y * sin(2.0 * l0r) - 2.0 * ecc * sin(m) + 4.0 * ecc * y * sin(m) * cos(2.0 * l0r) -
     0.5 * y * y * sin(4.0 * l0r) - 1.25 * ecc * ecc * sin(2.0 * m));

  /* t_s >= WX_TIME_MIN_S > 0 (checked by wx_sun_is_up()), so the remainder is not negative. */
  double utc_min = (double)(t_s % 86400) / 60.0;
  double true_solar_min = utc_min + eqtime_min + 4.0 * lon;
  double hour_angle = (true_solar_min / 4.0 - 180.0) * DEG2RAD;

  double phi = lat * DEG2RAD;
  double cos_zenith = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(hour_angle);
  cos_zenith = CLAMP(cos_zenith, -1.0, 1.0); /* rounding can leave it a hair outside */
  return 90.0 - acos(cos_zenith) * RAD2DEG;
}

/* Documented in wx-geo.h. */
gboolean
wx_sun_is_up(double lat, double lon, gint64 t_s)
{
  if (!wx_value_in_range(lat, -SUN_MAX_ABS_LAT, SUN_MAX_ABS_LAT) ||
      !wx_value_in_range(lon, -180.0, 180.0) || t_s < WX_TIME_MIN_S || t_s >= WX_TIME_MAX_S)
    return FALSE;
  return sun_altitude_deg(lat, lon, t_s) > SUN_HORIZON_DEG;
}
