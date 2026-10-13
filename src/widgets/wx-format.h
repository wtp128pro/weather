/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-format.h - GTK-free text formatting for the weather UI: temperatures,
 * wind, precipitation and percentages in the user's unit system, 12-hour
 * clock and weekday labels in a place's time zone, the "Updated ..." age text
 * and the plain-language rain headline / detail / cloud sentences.
 *
 * Common rules (every function):
 *  - no GTK, no network, no writes. (wx_cloud_sentence() calls
 *    wx_forecast_now() of the pure blend module, so that the sentence and the
 *    "Now" values of the UI come from one place; the format library therefore
 *    links the blend module, which itself needs nothing but the core.) The only global state is a small cache of
 *    resolved time zones (guarded by a mutex that is never held while a
 *    zoneinfo file is read). The first use of a zone name reads its file;
 *    afterwards, while the name is among the 8 most recently USED ones (a
 *    use refreshes it; loading a ninth name replaces the least recently
 *    used), no file is opened for it, whatever the formatter. A name that
 *    fails to load (unknown to GLib, or a transient error such as running
 *    out of file descriptors) is UTC, is never kept as a zone, and is only
 *    remembered as "failed" for 30 seconds (at most 4 such names; a later
 *    successful load of the name forgets the failure at once): within that
 *    time it costs no file access, after it the next call tries to load it
 *    again, so a transient failure heals and a persistently unknown name
 *    costs one failed lookup per 30 seconds per name (more when over 4 such
 *    names are in use). Two threads that load the same name at once both
 *    read it; one result is kept. The functions with a GTimeZone argument
 *    (_z) and wx_format_zone_new() hand the cache's result to the caller: a
 *    GTimeZone that is held does not depend on the cache any more, so a
 *    caller that resolves its zone once (a widget, on a place change) never
 *    reads a file again, whatever other zones are used meanwhile. Every
 *    other function is pure; all of them are safe to call from any thread;
 *  - locale independent: digits and decimal points are always ASCII and the
 *    English words are fixed (the process locale and the local time zone are
 *    never consulted; the "%p" of strftime is never used);
 *  - total: every returned string is newly allocated, valid UTF-8 and NEVER
 *    NULL for a valid enum argument; a missing or implausible number (NAN,
 *    infinity, outside the documented range) is rendered as an em dash
 *    U+2014 ("—") instead of a number, and a time outside
 *    [WX_TIME_MIN_S, WX_TIME_MAX_S) as an em dash too;
 *  - an invalid enum value (a WxUnits or WxRainState that is not a member of
 *    the enum) is a programmer error: g_return_val_if_fail() logs a critical
 *    and the function returns NULL;
 *  - TIME ZONE RULE (the same for every weather module): a time zone argument
 *    @tz is resolved as an IANA zone ONLY when it has the shape
 *    Area/Location, i.e. it contains at least one '/' and consists of
 *    "/"-separated components that each start with an ASCII letter and
 *    continue with [A-Za-z0-9_+-] (at most WX_PLACE_TIMEZONE_MAX bytes: never
 *    an absolute path or a traversal), or when it is exactly "UTC". EVERY
 *    other string (NULL, "", "Japan", "Singapore", "EST5EDT", "leapseconds",
 *    "../x", ...) is UTC, and so is a well-shaped name that GLib does not
 *    know. Only the first WX_PLACE_TIMEZONE_MAX + 1 bytes of @tz are examined.
 */
#ifndef WX_FORMAT_H
#define WX_FORMAT_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/**
 * wx_format_temp:
 * @c: temperature in degrees Celsius.
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 * @with_unit: whether to append the unit letter.
 *
 * Formats a temperature rounded to a whole degree (halves away from zero;
 * a value that rounds to zero prints "0", never "-0"): imperial converts to
 * Fahrenheit, "77°" without and "77°F" with the unit; metric "25°" / "25°C".
 *
 * Preconditions:
 *  - @units is a WxUnits member (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed; "—" when @c is outside [WX_TEMP_MIN_C,
 *    WX_TEMP_MAX_C] or not finite (never a unit letter for the dash).
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_temp(double c, WxUnits units, gboolean with_unit);

/**
 * wx_format_wind:
 * @kmh: wind speed in km/h.
 * @units: WX_UNITS_IMPERIAL ("12 mph") or WX_UNITS_METRIC ("19 km/h").
 *
 * Formats a wind speed rounded to a whole number (halves up).
 *
 * Preconditions:
 *  - @units is a WxUnits member (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed; "—" when @kmh is outside [0, WX_WIND_MAX_KMH] or
 *    not finite.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_wind(double kmh, WxUnits units);

/**
 * wx_format_precip:
 * @mm: precipitation amount in millimetres.
 * @units: WX_UNITS_IMPERIAL (inches) or WX_UNITS_METRIC (millimetres).
 *
 * Formats a precipitation amount. Zero prints "0 in" / "0 mm". Imperial
 * values that round (to two decimals) below one inch keep two decimals
 * ("0.25 in"), larger ones one ("1.5 in"); metric values keep one decimal
 * ("2.5 mm"). A positive amount too small to show is "<0.01 in" / "<0.1 mm"
 * so that rain is never shown as exactly zero.
 *
 * Preconditions:
 *  - @units is a WxUnits member (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed; "—" when @mm is outside [0, WX_PRECIP_MAX_MM_DAY]
 *    or not finite.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_precip(double mm, WxUnits units);

/**
 * wx_format_percent:
 * @pct: percentage, 0..100.
 *
 * Formats a percentage rounded to a whole number ("40%").
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed; "—" when @pct is outside [0, 100] or not finite.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_percent(double pct);

/**
 * wx_format_hour_label:
 * @t_s: UTC unix seconds.
 * @tz: (nullable): IANA time zone name (see the file comment).
 *
 * Formats the local 12-hour clock hour of @t_s: "3 PM", "12 AM" (midnight),
 * "12 PM" (noon). When the local time is not on the hour (zones with a
 * 30/45-minute offset) the minutes are kept ("11:30 PM"), so the label never
 * claims a wrong hour. Seconds are dropped (not rounded).
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_hour_label(gint64 t_s, const char *tz);

/**
 * wx_format_clock:
 * @t_s: UTC unix seconds.
 * @tz: (nullable): IANA time zone name (see the file comment).
 *
 * Formats the local 12-hour clock time of @t_s with minutes: "3:45 PM",
 * "12:05 AM", "12:00 PM". Seconds are dropped.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_clock(gint64 t_s, const char *tz);

/**
 * wx_format_weekday:
 * @t_s: UTC unix seconds inside the day to name.
 * @tz: (nullable): IANA time zone name (see the file comment).
 * @now_s: the current time, UTC unix seconds.
 *
 * Names the local calendar day of @t_s relative to the local calendar day of
 * @now_s: "Today", "Tomorrow", otherwise the English weekday name
 * ("Saturday"), which is also used for past days and when @now_s is outside
 * the valid time range.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_weekday(gint64 t_s, const char *tz, gint64 now_s);

/**
 * wx_format_local_day_end:
 * @t_s: UTC unix seconds inside the day.
 * @tz: (nullable): IANA time zone name (see the file comment).
 *
 * Finds where the local calendar day containing @t_s ends, so a caller can
 * tell whether that day is over. A day lasts as long as the clock makes it: 24
 * hours, or shorter or longer where the UTC offset changes (23 or 25 hours at
 * a DST change, 22 or 26 at Antarctica/Troll, 23.5 or 24.5 at
 * Australia/Lord_Howe, ...). A date that does not exist at all
 * (Pacific/Apia, 2011-12-30) does not lengthen the day before it: that day
 * ends where the skipped date would have begun, at the first instant of the
 * next existing date. (The tests compare this function with a brute-force scan
 * for every zone of the database around its transitions in 2007, 2011 (the
 * skipped date) and 2026-27.)
 *
 * The result is the EARLIEST UTC instant after @t_s whose local date is later
 * than the local date of @t_s: when the clock is set back across midnight
 * (Atlantic/Azores, America/Havana, America/St_Johns 2007) the first of the
 * two midnights counts, and when midnight does not exist (a clock set forward
 * across it) the first valid instant of the date does. For the start of a day
 * this is the rule by which the blend module starts the next day. (Only for an
 * @t_s inside the repeated hour after a clock set back across midnight, where
 * @t_s still has the earlier date, is it the SECOND midnight: the first one is
 * already past.)
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: the UTC unix seconds of that instant (greater than @t_s), or 0 when
 *   @t_s is outside [WX_TIME_MIN_S, WX_TIME_MAX_S).
 */
gint64 wx_format_local_day_end(gint64 t_s, const char *tz);

/**
 * wx_format_day_covered_from:
 * @forecast: non-NULL forecast.
 * @day: non-NULL day of @forecast.
 * @now_s: the current time, UTC unix seconds; the caller passes a day that
 *   contains it (day->start_s <= @now_s < the end of the local day).
 *
 * Tells whether the numbers of @day (high, low, rain sum, ...) cover the whole
 * local day or only the rest of it. The blend keeps no hour before the one
 * preceding the hour of its "now" (see wx-daily.h), so the day of "now" is
 * summarised from the forecast's first hour on, which may be late in that day.
 * A day summarises exactly the hours of the forecast whose start lies in it;
 * the day is partial iff the hour before the forecast's first hour starts in
 * the day too, i.e. first_hour_s - 3600 >= day->start_s, and the first hour
 * is not after @now_s (so that it is an hour of this day, not of a later one).
 *
 * Preconditions:
 *  - @forecast and @day are non-NULL (otherwise critical, 0 returned). Nothing
 *    else: the function is total for a hand-built forecast and day (any
 *    stamps and values; a NULL hour array with a count, a first hour or
 *    day->start_s outside the time range, @now_s of any value: no overflow).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the forecast's first hour (UTC unix seconds) when it starts in
 *   [day->start_s + 3600, @now_s] and both it and day->start_s are in the time
 *   range, i.e. when the day's numbers start there and the day began earlier;
 *   0 otherwise (the numbers cover the whole local day, the forecast has no
 *   hour, a stamp is outside the time range, or the first hour is after
 *   @now_s).
 */
gint64 wx_format_day_covered_from(const WxForecast *forecast, const WxDay *day, gint64 now_s);

/**
 * wx_format_zone_new:
 * @tz: (nullable): IANA time zone name (see the file comment).
 * @resolved: (out) (optional): receives whether the result is trustworthy.
 *
 * Resolves a place's time zone once, by the rule of the file comment, so that
 * a caller can use the _z functions below without any further lookup (and so
 * without any file access).
 *
 * A caller that keeps the zone MUST look at @resolved: it is FALSE exactly
 * when @tz is a name that the rule looks up (Area/Location shaped) but the
 * lookup FAILED (unknown to GLib, or a transient error such as running out of
 * file descriptors, or a failure remembered from the last 30 seconds): the
 * returned UTC zone is then only a fallback, and the caller should ask again
 * on its next opportunity (a repeat within 30 seconds costs no file access;
 * after that one new lookup is made). It is TRUE for a real zone and for the
 * legitimate UTC results that need no lookup (NULL, "", "UTC", every
 * ill-shaped name).
 *
 * Preconditions:
 *  - @tz is NULL or NUL-terminated (or has WX_PLACE_TIMEZONE_MAX + 1 readable
 *    bytes).
 * Postconditions:
 *  - the first use of a name reads its zoneinfo file, later uses come from
 *    the cache (see the file comment); never NULL; *@resolved (if given) is
 *    set as described.
 * Thread affinity: any thread.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the zone (UTC for every name the rule does not
 *   look up, and the fallback of a failed lookup); g_time_zone_unref() it.
 */
GTimeZone *wx_format_zone_new(const char *tz, gboolean *resolved);

/**
 * wx_format_hour_label_z:
 * @t_s: UTC unix seconds.
 * @zone: non-NULL time zone.
 *
 * Same as wx_format_hour_label() with an already resolved zone; no lookup, no
 * file access.
 *
 * Preconditions:
 *  - @zone is non-NULL (NULL: critical, NULL returned).
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread.
 * Ownership: @zone is borrowed; the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_hour_label_z(gint64 t_s, GTimeZone *zone);

/**
 * wx_format_clock_z:
 * @t_s: UTC unix seconds.
 * @zone: non-NULL time zone.
 *
 * Same as wx_format_clock() with an already resolved zone.
 *
 * Preconditions:
 *  - @zone is non-NULL (NULL: critical, NULL returned).
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread.
 * Ownership: @zone is borrowed; the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_clock_z(gint64 t_s, GTimeZone *zone);

/**
 * wx_format_weekday_z:
 * @t_s: UTC unix seconds inside the day to name.
 * @zone: non-NULL time zone.
 * @now_s: the current time, UTC unix seconds.
 *
 * Same as wx_format_weekday() with an already resolved zone.
 *
 * Preconditions:
 *  - @zone is non-NULL (NULL: critical, NULL returned).
 * Postconditions:
 *  - no state is changed; "—" when @t_s is outside the valid time range.
 * Thread affinity: any thread.
 * Ownership: @zone is borrowed; the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_weekday_z(gint64 t_s, GTimeZone *zone, gint64 now_s);

/**
 * wx_format_local_day_end_z:
 * @t_s: UTC unix seconds inside the day.
 * @zone: non-NULL time zone.
 *
 * Same as wx_format_local_day_end() with an already resolved zone.
 *
 * Preconditions:
 *  - @zone is non-NULL (NULL: critical, 0 returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: @zone is borrowed.
 *
 * Returns: the UTC unix seconds of the day end (greater than @t_s), or 0 when
 *   @t_s is outside [WX_TIME_MIN_S, WX_TIME_MAX_S).
 */
gint64 wx_format_local_day_end_z(gint64 t_s, GTimeZone *zone);

/**
 * wx_format_updated:
 * @age_s: seconds since the data was produced.
 *
 * Formats the data age: "Updated just now" (negative, or under 60 s),
 * "Updated 5 min ago" (1..59 minutes, rounded down), "Updated 2 h ago"
 * (1..23 hours), "Updated 1 day ago" / "Updated 3 days ago" (1..29 days) and
 * "Updated over a month ago" from 30 days on.
 *
 * Preconditions:
 *  - none (any gint64).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text; g_free() it.
 */
char *wx_format_updated(gint64 age_s);

/**
 * wx_rain_headline:
 * @outlook: non-NULL rain outlook (see wx_rain_outlook()).
 * @now_s: the current time, UTC unix seconds.
 * @tz: (nullable): IANA time zone name of the place.
 *
 * Builds the one-line plain-language rain headline. Times are local clock
 * times of @tz; a time on a later local day is introduced with "tomorrow" or
 * the weekday name ("Rain expected tomorrow around 4 PM", "Rain expected
 * Friday around 4 PM"); "around H PM" is used when the time is on the hour,
 * otherwise "around H:MM PM".
 *  - WX_RAIN_NOW: "Raining now, easing around 3:30 PM" when the end is known
 *    (ends_known and end_s after @now_s), "Raining now, easing soon" when
 *    ends_known but end_s is not after @now_s, "Raining now" when ends_known
 *    but end_s is not a valid time, and "Raining now, expected to continue
 *    for hours" when the end is not known.
 *  - WX_RAIN_EXPECTED: "Rain starting in 25 minutes" when start_s is more than
 *    0 and less than 90 minutes ahead (rounded up to whole minutes, "in 1
 *    minute" singular), "Rain starting now" when start_s is not after
 *    @now_s, otherwise "Rain expected around 4 PM" (with the day word when
 *    not today).
 *  - WX_RAIN_POSSIBLE: "Showers possible around 4 PM (40% chance)" using
 *    peak_s and peak_prob; "Showers possible now (40% chance)" when peak_s is
 *    not after @now_s; the chance part is left out when peak_prob is not a
 *    percentage; "Showers possible in the next 48 hours" when peak_s is not
 *    a valid time.
 *  - WX_RAIN_DRY: "No rain expected for the next 48 hours".
 * A start_s / peak_s that is not a valid time degrades its sentence to the
 * time-less form ("Rain expected in the next 48 hours"). Except for
 * WX_RAIN_DRY (a constant sentence), a @now_s outside the valid time range
 * gives "Rain outlook unavailable".
 *
 * Preconditions:
 *  - @outlook is non-NULL and outlook->state is a WxRainState member
 *    (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated sentence without a final period.
 */
char *wx_rain_headline(const WxRainOutlook *outlook, gint64 now_s, const char *tz);

/**
 * wx_rain_detail:
 * @outlook: non-NULL rain outlook.
 * @now_s: the current time, UTC unix seconds.
 * @tz: (nullable): IANA time zone name of the place.
 *
 * Builds the optional second line below the headline.
 *  - WX_RAIN_NOW / WX_RAIN_EXPECTED: the outlook's peak describes the whole
 *    run, samples that are already over included, so the text never claims a
 *    CURRENT rate. The intensity word comes from peak_mm_h: below 0.5 mm/h
 *    "Very light", below 2.5 "Light", below 7.6 "Moderate", otherwise
 *    "Heavy". When peak_s is after @now_s: "Light rain, heaviest around
 *    5 PM." When peak_s is not after @now_s (the peak sample has started or
 *    is over): "Rain peaked around 5 PM (light)." (a past day is introduced
 *    with "yesterday" or the weekday). When peak_s is not a valid time:
 *    "Light rain at its heaviest." WX_RAIN_EXPECTED adds " 70% chance of
 *    rain." (peak_prob); WX_RAIN_NOW never does. A sentence is left out when
 *    its number is missing (peak_mm_h not finite or negative / peak_prob
 *    not a percentage); with both missing the result is "".
 *  - WX_RAIN_POSSIBLE: "No steady rain in the forecast, just a chance."
 *  - WX_RAIN_DRY: "".
 * When @now_s is outside the valid time range the result is "".
 *
 * Preconditions:
 *  - @outlook is non-NULL and outlook->state is a WxRainState member
 *    (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated text, possibly empty.
 */
char *wx_rain_detail(const WxRainOutlook *outlook, gint64 now_s, const char *tz);

/**
 * wx_cloud_sentence:
 * @forecast: non-NULL forecast.
 * @now_s: the current time, UTC unix seconds.
 * @tz: (nullable): IANA time zone name of the place.
 *
 * Describes the sky now and what changes in the next 24 hours from the
 * hourly cloud cover. The cloud cover of an hour is put in one of five bands
 * (design 5.5): below 12.5 % Clear, below 37.5 % Mostly clear, below 62.5 %
 * Partly cloudy, below 87.5 % Mostly cloudy, otherwise Overcast. The current
 * band is that of the cloud cover wx_forecast_now() reports for @now_s (the
 * cloud cover of the hour containing @now_s interpolated towards the next
 * hour, the very value the detail pane shows as its cover and condition; when
 * only one of the two hours has a cloud value that value is used). Looking at
 * later hours that start before @now_s + 24 h (hours without a cloud value
 * are skipped), the first hour in another band gives "Mostly cloudy now, clearing around 9 PM"
 * (the target phrase is "clearing" for Clear, "mostly clear", "partly
 * cloudy", "mostly cloudy" or "clouding over" for Overcast; the day word of
 * wx_rain_headline() is added for a later day). If the band never changes
 * the result is "Clear skies for the next 24 hours" ("Mostly clear skies",
 * "Partly cloudy", "Mostly cloudy" or "Overcast" likewise) when the forecast
 * reaches 24 hours ahead, otherwise "... for the next 6 hours" with the number
 * of hours the forecast still covers ("for the next hour" below two).
 *
 * Preconditions:
 *  - @forecast is non-NULL (otherwise critical, NULL).
 * Postconditions:
 *  - no state is changed; "Cloud cover unknown" when @now_s is outside the
 *    valid time range, no hour contains @now_s, or the current cloud cover
 *    (wx_forecast_now()) is unknown.
 * Thread affinity: any thread (the forecast is immutable).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated sentence without a final period.
 */
char *wx_cloud_sentence(const WxForecast *forecast, gint64 now_s, const char *tz);

G_END_DECLS

#endif /* WX_FORMAT_H */
