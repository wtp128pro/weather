/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-daily.h"

#include <math.h>
#include <string.h>

#include "wx-condition.h"
#include "wx-types.h"

/* Seconds in a day and in an hour. */
#define DAY_S 86400
#define HOUR_S 3600

/* A severe class needs a probability of at least this many percent when it is
 * not backed by two consecutive hours. */
#define SEVERE_PROB_PCT 40.0
/* A rain day needs at least this much precipitation and probability. */
#define RAIN_DAY_MM 1.0
#define RAIN_DAY_PROB_PCT 50.0

/**
 * zone_is_looked_up:
 * @timezone: (nullable): candidate zone name.
 *
 * The one timezone rule: a name is resolved as an IANA zone only if it is of
 * the shape wx_place_new() accepts (it is used to read a file below the zone
 * database directory, so no leading '/', no "..", at most
 * WX_PLACE_TIMEZONE_MAX bytes) AND contains a '/' ("Area/Location"). Every
 * other string, "UTC" itself included, is UTC: bare names like "Japan",
 * "EST5EDT" or "leapseconds" are legacy aliases or non-zone files of the
 * database that are not wanted as place zones.
 *
 * Preconditions:
 *  - @timezone is NULL or NUL-terminated (or has WX_PLACE_TIMEZONE_MAX + 1
 *    readable bytes).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @timezone is to be looked up in the zone database.
 */
static gboolean
zone_is_looked_up(const char *timezone)
{
  if (timezone == NULL)
    return FALSE;
  WxPlace *probe = wx_place_new("x", NULL, NULL, NULL, 0.0, 0.0, timezone, NULL);
  if (probe == NULL)
    return FALSE;
  wx_place_free(probe);
  /* the shape check proved that a NUL follows within the bound */
  return strchr(timezone, '/') != NULL;
}

/* Documented in wx-daily.h. */
gint
wx_daily_interval_offset(GTimeZone *tz, gint interval)
{
  g_return_val_if_fail(tz != NULL, 0);
  if (interval < 0) /* "cannot resolve": the documented failure value of find_interval() */
    return 0;
  return g_time_zone_get_offset(tz, interval);
}

/**
 * local_day_number:
 * @tz: non-NULL zone.
 * @t_s: UTC unix seconds, at least WX_TIME_MIN_S.
 *
 * Every g_time_zone_find_interval() result in this file is either passed
 * through wx_daily_interval_offset() (which maps the failure value -1 to the
 * UTC offset 0) or clamped to a valid index; a negative interval is never
 * handed to g_time_zone_get_offset().
 *
 * Preconditions:
 *  - @tz is non-NULL and @t_s is in the time range.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the number of whole days since 1970-01-01 of the zone's local date
 *   at @t_s (the local clock reading is always positive in the time range).
 */
static gint64
local_day_number(GTimeZone *tz, gint64 t_s)
{
  gint interval = g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, t_s);
  return (t_s + wx_daily_interval_offset(tz, interval)) / DAY_S;
}

/**
 * has_severe:
 * @hours: (array length=n): the hours of one day.
 * @n: number of hours.
 * @cls: the class to look for.
 *
 * Preconditions:
 *  - @hours has @n readable entries.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff some hour has condition @cls and either its precip_prob is
 *   >= 40 or the hour at t_s + 3600 has @cls too.
 */
static gboolean
has_severe(const WxBlendHour *hours, guint n, WxCondition cls)
{
  for (guint i = 0; i < n; i++) {
    if (hours[i].condition != cls)
      continue;
    if (hours[i].precip_prob >= SEVERE_PROB_PCT)
      return TRUE;
    if (i + 1 < n && hours[i + 1].condition == cls &&
        hours[i + 1].t_s == hours[i].t_s + HOUR_S)
      return TRUE;
  }
  return FALSE;
}

/**
 * local_midnight:
 * @tz: non-NULL zone.
 * @t_s: an instant of the day, in the time range.
 *
 * Candidates for the first instant of the local date of @t_s: GLib's own
 * local midnight (which is the first valid instant after a gap when midnight
 * does not exist, but the second midnight when the clock is set back across
 * it), and 00:00 read with every UTC offset in effect within two days of
 * @t_s (accepted when the instant really is on that date). The earliest
 * candidate wins, so a clock set back across midnight (even shortly after it:
 * St. John's on 2007-11-04 went from 00:01 back to 23:01) gives the first
 * midnight.
 *
 * Preconditions:
 *  - @tz is non-NULL and @t_s is in the time range.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the first instant of that local date, UTC unix seconds.
 */
static gint64
local_midnight(GTimeZone *tz, gint64 t_s)
{
  gint64 day_no = local_day_number(tz, t_s);

  g_autoptr(GDateTime) utc = g_date_time_new_from_unix_utc(t_s);
  g_autoptr(GDateTime) local = g_date_time_to_timezone(utc, tz);
  gint y, m, d;
  g_date_time_get_ymd(local, &y, &m, &d);
  g_autoptr(GDateTime) midnight = g_date_time_new(tz, y, m, d, 0, 0, 0.0);
  /* the date came from GLib itself, so midnight exists; never asserted: fall back to t_s */
  gint64 first_s = midnight != NULL ? g_date_time_to_unix(midnight) : t_s;

  /* find_interval() answers -1 when it cannot resolve: use interval 0 then (always valid) */
  gint lo = MAX(g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, t_s - 2 * DAY_S), 0);
  gint hi = MAX(g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, t_s + 2 * DAY_S), 0);
  for (gint i = lo; i <= hi; i++) {
    gint64 c = day_no * DAY_S - wx_daily_interval_offset(tz, i);
    if (c < first_s && local_day_number(tz, c) == day_no)
      first_s = c;
  }
  return first_s;
}

/**
 * summarise_day:
 * @tz: non-NULL zone.
 * @hours: (array length=n): the hours of one local day, at least one.
 * @n: number of hours.
 * @min_hours: how many covered hours the day needs.
 * @day: (out): receives the summary.
 *
 * Preconditions:
 *  - @n >= 1, @hours valid as for wx_daily_build(), all in the same local day.
 * Postconditions:
 *  - *@day is filled field by field.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the day has at least @min_hours covered hours and
 *   its start lies in the time range (otherwise *@day is not written).
 */
static gboolean
summarise_day(GTimeZone *tz, const WxBlendHour *hours, guint n, guint min_hours, WxDay *day)
{
  guint covered = 0;
  double tmax = NAN, tmin = NAN, psum = NAN, prob_max = NAN, rate_max = NAN;
  double day_sum = 0.0, all_sum = 0.0;
  guint day_n = 0, all_n = 0;

  for (guint i = 0; i < n; i++) {
    const WxBlendHour *h = &hours[i];
    if (h->n_members > 0)
      covered++;
    /* fmax()/fmin() return the other operand when one is NAN */
    if (isfinite(h->temp_c)) {
      tmax = fmax(tmax, h->temp_c);
      tmin = fmin(tmin, h->temp_c);
    }
    if (isfinite(h->precip_mm)) {
      psum = isnan(psum) ? h->precip_mm : psum + h->precip_mm;
      rate_max = fmax(rate_max, h->precip_mm);
    }
    if (isfinite(h->precip_prob))
      prob_max = fmax(prob_max, h->precip_prob);
    if (isfinite(h->cloud_pct)) {
      all_sum += h->cloud_pct;
      all_n++;
      if (h->is_day) {
        day_sum += h->cloud_pct;
        day_n++;
      }
    }
  }
  if (covered < min_hours)
    return FALSE;

  gint64 start_s = local_midnight(tz, hours[0].t_s);
  /* start_s is never after the first hour (so below WX_TIME_MAX_S) but may precede the range */
  if (start_s < WX_TIME_MIN_S)
    return FALSE;

  /* a 25 hour day at the hourly maximum exceeds the daily maximum of WxDay */
  if (psum > WX_PRECIP_MAX_MM_DAY)
    psum = WX_PRECIP_MAX_MM_DAY;
  /* every cloud value is within [0, 100]; the sum of at most 240 of them is at most 100 * n
   * (an exactly representable integer), the rounded sum is not above it (rounding is
   * monotone) and the quotient by n is not above 100 either: the mean stays in range */
  double cloud = day_n > 0 ? day_sum / day_n : (all_n > 0 ? all_sum / all_n : NAN);

  WxCondition cond;
  if (has_severe(hours, n, WX_COND_THUNDERSTORM))
    cond = WX_COND_THUNDERSTORM;
  else if (has_severe(hours, n, WX_COND_SNOW))
    cond = WX_COND_SNOW;
  else if (has_severe(hours, n, WX_COND_SLEET))
    cond = WX_COND_SLEET;
  else if (psum >= RAIN_DAY_MM && prob_max >= RAIN_DAY_PROB_PCT)
    cond = wx_condition_rain_class(cloud, rate_max);
  else
    cond = wx_cloud_condition(cloud);

  day->start_s = start_s;
  day->temp_max_c = tmax;
  day->temp_min_c = tmin;
  day->precip_mm = psum;
  day->precip_prob_max = prob_max;
  day->cloud_pct = cloud;
  day->condition = cond;
  return TRUE;
}

/* Documented in wx-daily.h. */
guint
wx_daily_build(const char *timezone, const WxBlendHour *hours, guint n_hours, gint64 now_s,
               WxDay *days)
{
  g_return_val_if_fail(days != NULL, 0);
  g_return_val_if_fail(hours != NULL || n_hours == 0, 0);
  g_return_val_if_fail(n_hours <= WX_FORECAST_MAX_HOURS, 0);
  g_return_val_if_fail(now_s >= WX_TIME_MIN_S && now_s < WX_TIME_MAX_S, 0);
  for (guint i = 0; i < n_hours; i++) {
    g_return_val_if_fail(hours[i].t_s >= WX_TIME_MIN_S && hours[i].t_s < WX_TIME_MAX_S &&
                             hours[i].t_s % HOUR_S == 0 && (i == 0 || hours[i].t_s > hours[i - 1].t_s),
                         0);
  }
  if (n_hours == 0)
    return 0;

  GTimeZone *tz = zone_is_looked_up(timezone) ? g_time_zone_new_identifier(timezone) : NULL;
  if (tz == NULL) /* not looked up, or unknown to the database */
    tz = g_time_zone_new_utc();

  gint64 today_no = local_day_number(tz, now_s);
  guint n_days = 0;
  guint begin = 0;
  gint64 day_no = local_day_number(tz, hours[0].t_s);
  for (guint i = 1; i <= n_hours && n_days < WX_DAILY_MAX_DAYS; i++) {
    gint64 no = 0;
    if (i < n_hours) {
      no = local_day_number(tz, hours[i].t_s);
      /* same local day (a clock stepping back across midnight stays in the current day) */
      if (no <= day_no)
        continue;
    }
    /* today needs a single covered hour: the list is cut one hour before now, so only the hours
     * that are left are in it */
    if (summarise_day(tz, hours + begin, i - begin,
                      day_no == today_no ? WX_DAILY_MIN_HOURS_TODAY : WX_DAILY_MIN_HOURS,
                      &days[n_days]))
      n_days++;
    begin = i;
    day_no = no;
  }

  g_time_zone_unref(tz);
  return n_days;
}
