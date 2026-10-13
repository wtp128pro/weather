/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-daily.h - the daily summary: blended hours grouped into the place's local
 * calendar days.
 *
 * Pure apart from reading the system's IANA time-zone database for the zone
 * named by the place (never the process' local zone or locale).
 */
#ifndef WX_DAILY_H
#define WX_DAILY_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Most days wx_daily_build() produces. */
#define WX_DAILY_MAX_DAYS 10
/** A local day other than the current one needs at least this many covered hours (n_members > 0). */
#define WX_DAILY_MIN_HOURS 12
/** The current local day (the one containing now_s) needs only this many: the list is cut at now. */
#define WX_DAILY_MIN_HOURS_TODAY 1

/**
 * wx_daily_build:
 * @timezone: (nullable): IANA zone name of the place ("America/New_York").
 *   THE TIMEZONE RULE (shared with the widgets module): the name is looked up
 *   in the zone database only if it contains at least one '/' ("Area/Location")
 *   and has the shape accepted by wx_place_new() (the name is used to read a
 *   file, so no leading '/', no "..", no component starting with a digit, '-',
 *   '+', '_' or '.', and at most WX_PLACE_TIMEZONE_MAX bytes). EVERY other
 *   string is UTC: "UTC" itself, NULL, "", legacy bare aliases ("Japan",
 *   "Singapore", "EST5EDT"), non-zone files of the database ("leapseconds"),
 *   anything of a bad shape ("../x", "/etc/passwd") and a name with a '/' that
 *   the zone database does not know ("America/Nowhere", a directory such as
 *   "America/Argentina"). Never a critical, whatever the string.
 * @hours: (array length=n_hours) (nullable): the blended hours, strictly
 *   ascending, multiples of 3600 within [WX_TIME_MIN_S, WX_TIME_MAX_S); NULL
 *   only when @n_hours is 0.
 * @n_hours: number of hours, at most WX_FORECAST_MAX_HOURS.
 * @now_s: the current time, UTC unix seconds, in [WX_TIME_MIN_S,
 *   WX_TIME_MAX_S): decides which local day is today (see below).
 * @days: (out caller-allocates) (array fixed-size=10): room for
 *   WX_DAILY_MAX_DAYS entries; the first return-value entries are written.
 *
 * Groups the hours into local calendar days of the zone (an hour belongs to
 * the day containing its instant t_s; a day with a DST change has 23 or 25
 * hours; hours at which the clock has been set back across midnight and reads
 * the previous date again stay in the day that is running) and summarises each
 * day that has enough covered hours (covered = n_members > 0), in order. The
 * day that contains @now_s ("today") needs at least WX_DAILY_MIN_HOURS_TODAY
 * covered hours, every other day at least WX_DAILY_MIN_HOURS (a day before
 * today is no exception). So today stays in the list for as long as the list
 * holds a covered hour of it, however few are left, while the one hour of
 * yesterday that a list cut one hour before now still holds just after local
 * midnight is not a day. At most WX_DAILY_MAX_DAYS days, the earliest ones.
 *
 * WHICH HOURS A DAY SUMMARISES: exactly the entries of @hours that belong to
 * it, nothing else. wx_blend_forecast() starts its list one hour before the
 * hour that contains now, so the summary of today covers the hours of today
 * from that one on: the whole day only while no hour of today precedes the
 * list (the early hours of the day), otherwise only the rest of the day, and
 * an extreme that occurred earlier today is not in it. For a day:
 *  - start_s: local midnight as UTC unix seconds: the first instant of the
 *    local date (when the clock is set back across midnight so that it
 *    happens twice, even shortly after it, the first one; when midnight does
 *    not exist, the first valid instant of the day); it may lie before the
 *    first hour (then the summary starts at the first hour). A day whose
 *    start lies before WX_TIME_MIN_S is skipped.
 *  - temp_max_c / temp_min_c: extremes of the finite hourly temp_c, NAN when
 *    there is none.
 *  - precip_mm: sum of the finite hourly precip_mm, NAN when there is none,
 *    at most WX_PRECIP_MAX_MM_DAY (a 25 hour day at the hourly maximum would
 *    exceed it; the sum is clamped, which does not change the condition).
 *  - precip_prob_max: largest finite hourly precip_prob, NAN when there is none.
 *  - cloud_pct: mean of the finite cloud_pct of the daylight (is_day) hours;
 *    when the day has no daylight hour with a value (polar night) the mean over
 *    all of its hours with a value; NAN when there is none.
 *  - condition: WX_COND_THUNDERSTORM, else WX_COND_SNOW, else WX_COND_SLEET
 *    when some hour has that condition and either two hours at consecutive
 *    instants (t_s and t_s + 3600) of the day have it or that hour's
 *    precip_prob is >= 40; else, if precip_mm >= 1 and precip_prob_max >= 50, a
 *    rain class: wx_condition_rain_class(cloud_pct, largest hourly
 *    precip_mm); else wx_cloud_condition(cloud_pct) (WX_COND_UNKNOWN when the
 *    cloud cover is NAN).
 *
 * Preconditions:
 *  - @days is non-NULL with room for WX_DAILY_MAX_DAYS entries; @hours is
 *    non-NULL when @n_hours > 0; @n_hours <= WX_FORECAST_MAX_HOURS; the hours
 *    are strictly ascending multiples of 3600 in the time range; @now_s is in
 *    [WX_TIME_MIN_S, WX_TIME_MAX_S) (otherwise critical, 0 returned, @days
 *    untouched).
 * Postconditions:
 *  - the returned number of entries of @days are written, ascending and
 *    strictly increasing in start_s, all conditions valid; the rest of @days
 *    and @hours are untouched.
 * Thread affinity: any thread (the zone is created and released inside).
 * Ownership: nothing is retained.
 *
 * Returns: the number of days written, 0 .. WX_DAILY_MAX_DAYS.
 */
guint wx_daily_build(const char *timezone, const WxBlendHour *hours, guint n_hours, gint64 now_s,
                     WxDay *days);

/**
 * wx_daily_interval_offset:
 * @tz: non-NULL zone.
 * @interval: an interval index as returned by g_time_zone_find_interval(), or
 *   a negative number.
 *
 * THE INTERVAL GUARD. g_time_zone_find_interval() documents -1 as its failure
 * value, and g_time_zone_get_offset() must not receive it. Every use of an
 * interval index in wx-daily.c goes through this function (or, for the loop
 * bounds of the midnight search, is clamped to >= 0 first), so a negative
 * index is treated as "cannot resolve": the UTC offset 0. No such failure
 * has been observed for G_TIME_TYPE_UNIVERSAL (the only type used), so the
 * guard is only reachable directly; it is exposed for the tests.
 *
 * Preconditions:
 *  - @tz is non-NULL (NULL: critical, 0 returned); a non-negative @interval
 *    came from g_time_zone_find_interval() of the same zone.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the offset in seconds east of UTC of the interval; 0 for a
 *   negative @interval.
 */
gint wx_daily_interval_offset(GTimeZone *tz, gint interval);

G_END_DECLS

#endif /* WX_DAILY_H */
