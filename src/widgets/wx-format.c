/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-format.c - GTK-free text formatting. See wx-format.h for the contract.
 *
 * All time handling converts UTC seconds to a GDateTime in the requested
 * IANA zone and reads its integer fields; the process locale and the local
 * time zone are never used.
 */
#include "wx-format.h"

#include <math.h>
#include <string.h>

#include "wx-blend.h"

#define EM_DASH "\xe2\x80\x94"

/* Rain intensity words, mm/h (same boundaries as the blend's condition rules). */
#define VERY_LIGHT_BELOW_MM_H 0.5
#define LIGHT_BELOW_MM_H 2.5
#define MODERATE_BELOW_MM_H 7.6

/* "Rain starting in N minutes" is used below this many seconds ahead. */
#define MINUTES_PHRASE_BELOW_S (90 * 60)

#define MM_PER_INCH 25.4
#define MPH_PER_KMH 0.621371192237334

/* Look-ahead of the cloud sentence. */
#define CLOUD_LOOKAHEAD_S (24 * 3600)

static const char *const weekday_names[7] = { "Monday",   "Tuesday", "Wednesday", "Thursday",
                                              "Friday",   "Saturday", "Sunday" };

/* Cloud bands, design 5.5. */
enum { BAND_CLEAR, BAND_MOSTLY_CLEAR, BAND_PARTLY, BAND_MOSTLY_CLOUDY, BAND_OVERCAST, N_BANDS };

/* "<Label> now" in the changing sentence, indexed by band. */
static const char *const band_now[N_BANDS] = { "Clear", "Mostly clear", "Partly cloudy",
                                               "Mostly cloudy", "Overcast" };
/* Steady sentence stem, indexed by band. */
static const char *const band_steady[N_BANDS] = { "Clear skies", "Mostly clear skies",
                                                  "Partly cloudy", "Mostly cloudy", "Overcast" };
/* What the sky is doing at a transition, indexed by the TARGET band. */
static const char *const band_target[N_BANDS] = { "clearing", "mostly clear", "partly cloudy",
                                                  "mostly cloudy", "clouding over" };

/**
 * time_ok:
 * @t_s: a UTC unix time.
 *
 * Range check for every time that is formatted.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff WX_TIME_MIN_S <= @t_s < WX_TIME_MAX_S.
 */
static gboolean
time_ok(gint64 t_s)
{
  return t_s >= WX_TIME_MIN_S && t_s < WX_TIME_MAX_S;
}

/**
 * tz_shape_ok:
 * @tz: NUL-terminated or at least WX_PLACE_TIMEZONE_MAX + 1 readable bytes.
 *
 * Accepts only IANA-shaped zone names (the rule of wx_place_new()): non-empty,
 * at most WX_PLACE_TIMEZONE_MAX bytes, "/"-separated components, each
 * starting with an ASCII letter and continuing with [A-Za-z0-9_+-]. This
 * keeps g_time_zone_new_identifier() away from absolute paths, "." / ".."
 * components and option-like text. A name without '/' is rejected here
 * ("UTC" is handled by the caller): the files at the top level of the
 * zoneinfo directory that are not zones ("leapseconds") make GLib log a
 * critical, and every real region name has the form Area/Location
 * ("America/New_York", "Etc/GMT+5"), so old one-word aliases ("Japan",
 * "EST5EDT") are shown in UTC.
 *
 * Preconditions:
 *  - @tz is non-NULL; at most WX_PLACE_TIMEZONE_MAX + 1 bytes are read.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @tz has the shape above and contains a '/'.
 */
static gboolean
tz_shape_ok(const char *tz)
{
  const char *nul = memchr(tz, '\0', WX_PLACE_TIMEZONE_MAX + 1);
  if (nul == NULL || nul == tz)
    return FALSE;
  gboolean at_start = TRUE;
  for (const char *p = tz; p < nul; p++) {
    char c = *p;
    if (c == '/') {
      if (at_start)
        return FALSE;
      at_start = TRUE;
      continue;
    }
    gboolean letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (at_start ? !letter : !(letter || (c >= '0' && c <= '9') || c == '_' || c == '+' || c == '-'))
      return FALSE;
    at_start = FALSE;
  }
  return !at_start && memchr(tz, '/', (size_t)(nul - tz)) != NULL;
}

/* Resolved zones. A hit does no I/O. The lock only guards the two small rings
 * below: it is NEVER held while a zone file is read, so a slow load cannot
 * stall a thread that uses a cached zone.
 *
 * positive ring: ZONE_CACHE_SIZE zones that were loaded; a hit marks its
 * entry as recently used and a new zone replaces the LEAST recently used one.
 * negative ring: NEG_CACHE_SIZE names GLib could not load, each remembered
 * for NEG_TTL_US so that an unknown name does not cost an open() per call. A
 * new failure takes a free slot, else an expired one, else replaces the
 * oldest live entry (so a live entry is only ever lost when all four slots are
 * live). A failure is never remembered for longer
 * than that, so a transient failure (EMFILE, ...) for a valid name heals
 * itself, and a successful load of a name forgets its failure at once. */
#define ZONE_CACHE_SIZE 8
#define NEG_CACHE_SIZE 4
#define NEG_TTL_US (30 * G_USEC_PER_SEC)

typedef struct {
  char name[WX_PLACE_TIMEZONE_MAX + 1];
  GTimeZone *zone; /* owned; NULL = free slot */
  guint64 used;    /* zone_tick of the last use */
} ZoneEntry;

typedef struct {
  char name[WX_PLACE_TIMEZONE_MAX + 1];
  gint64 expires_us; /* monotonic; 0 = free slot */
} NegEntry;

G_LOCK_DEFINE_STATIC(zone_lock);
static ZoneEntry zone_cache[ZONE_CACHE_SIZE];
static guint64 zone_tick;
static NegEntry neg_cache[NEG_CACHE_SIZE];

/* The loader, the clock and the load counter. In the production library these are the plain GLib
 * functions and there is no counter; the test build (-DWX_FORMAT_TESTING, see wx-format-testing.h)
 * can replace the first two and count loads. */
#ifdef WX_FORMAT_TESTING
#include "wx-format-testing.h"

static WxZoneLoader zone_loader = g_time_zone_new_identifier;
static WxZoneClock zone_clock = g_get_monotonic_time;
static gint zone_loads; /* loader calls so far (atomic) */
#define LOAD_ZONE(loader, name) ((g_atomic_int_inc(&zone_loads), (loader)(name)))
#define CURRENT_LOADER() zone_loader
#define NOW_US() zone_clock()

/* Documented in wx-format-testing.h. */
void
wx_format_test_set_hooks(WxZoneLoader loader, WxZoneClock clock)
{
  G_LOCK(zone_lock);
  zone_loader = loader != NULL ? loader : g_time_zone_new_identifier;
  zone_clock = clock != NULL ? clock : g_get_monotonic_time;
  for (guint i = 0; i < ZONE_CACHE_SIZE; i++)
    g_clear_pointer(&zone_cache[i].zone, g_time_zone_unref);
  memset(zone_cache, 0, sizeof zone_cache);
  memset(neg_cache, 0, sizeof neg_cache);
  zone_tick = 0;
  G_UNLOCK(zone_lock);
}

/* Documented in wx-format-testing.h. */
guint
wx_format_zone_loads(void)
{
  return (guint)g_atomic_int_get(&zone_loads);
}
#else
#define LOAD_ZONE(loader, name) ((loader)(name))
#define CURRENT_LOADER() g_time_zone_new_identifier
#define NOW_US() g_get_monotonic_time()
#endif

/**
 * find_cached:
 * @tz: shaped zone name.
 *
 * Preconditions:
 *  - zone_lock is held.
 * Postconditions:
 *  - a found entry is marked as the most recently used.
 * Thread affinity: any thread, under zone_lock.
 * Ownership: nothing is retained.
 *
 * Returns: the positive-ring entry of @tz, or NULL.
 */
static ZoneEntry *
find_cached(const char *tz)
{
  for (guint i = 0; i < ZONE_CACHE_SIZE; i++) {
    if (zone_cache[i].zone != NULL && strcmp(zone_cache[i].name, tz) == 0) {
      zone_cache[i].used = ++zone_tick;
      return &zone_cache[i];
    }
  }
  return NULL;
}

/**
 * zone_for:
 * @tz: (nullable): IANA zone name.
 * @resolved: (out): receives FALSE iff a name that is looked up (shaped
 *   Area/Location) could not be loaded and the result is the UTC fallback
 *   (including a name remembered as failed); TRUE otherwise.
 *
 * Resolves a zone name with the rule documented in wx-format.h: a name of the
 * shape Area/Location is looked up, "UTC" is UTC; NULL, "" and every other
 * string give UTC without any lookup (and count as resolved). A loaded zone is kept in the positive
 * ring (least recently used replaced): a cached name causes no file I/O. A
 * name that fails to load is UTC for NEG_TTL_US (then tried again). The
 * lookup happens with the lock released; when two threads load the same name
 * at once, the first to finish is kept and the other zone is dropped.
 *
 * Preconditions:
 *  - @tz is NULL or NUL-terminated (or has WX_PLACE_TIMEZONE_MAX + 1 readable
 *    bytes).
 * Postconditions:
 *  - never NULL.
 * Thread affinity: any thread (the rings are guarded by a mutex; GTimeZone is
 *   thread-safe).
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the zone; g_time_zone_unref() it.
 */
static GTimeZone *
zone_for(const char *tz, gboolean *resolved)
{
  *resolved = TRUE;
  if (tz == NULL || strcmp(tz, "UTC") == 0 || !tz_shape_ok(tz))
    return g_time_zone_new_utc();

  G_LOCK(zone_lock);
  ZoneEntry *hit = find_cached(tz);
  if (hit != NULL) {
    GTimeZone *zone = g_time_zone_ref(hit->zone);
    G_UNLOCK(zone_lock);
    return zone;
  }
  gint64 now_us = NOW_US();
  for (guint i = 0; i < NEG_CACHE_SIZE; i++) {
    if (neg_cache[i].expires_us > now_us && strcmp(neg_cache[i].name, tz) == 0) {
      G_UNLOCK(zone_lock);
      *resolved = FALSE;
      return g_time_zone_new_utc();
    }
  }
  GTimeZone *(*loader)(const char *) = CURRENT_LOADER();
  G_UNLOCK(zone_lock);

  GTimeZone *zone = LOAD_ZONE(loader, tz); /* file I/O, no lock held */

  G_LOCK(zone_lock);
  hit = find_cached(tz);
  if (hit != NULL) { /* another thread finished first */
    if (zone != NULL)
      g_time_zone_unref(zone);
    zone = g_time_zone_ref(hit->zone);
    G_UNLOCK(zone_lock);
    return zone;
  }
  if (zone == NULL) {
    /* The entry of the same name, else the slot with the smallest expiry time: a free slot (0), else
     * an expired one, else the oldest live entry. A live entry is only lost when all four are live. */
    gint64 now2_us = NOW_US();
    NegEntry *slot = &neg_cache[0];
    for (guint i = 0; i < NEG_CACHE_SIZE; i++) {
      NegEntry *e = &neg_cache[i];
      if (e->expires_us != 0 && strcmp(e->name, tz) == 0) {
        slot = e;
        break;
      }
      if (e->expires_us < slot->expires_us)
        slot = e; /* ties (equal times) keep the lower slot: the one filled first */
    }
    g_strlcpy(slot->name, tz, sizeof slot->name);
    slot->expires_us = now2_us + NEG_TTL_US;
    G_UNLOCK(zone_lock);
    *resolved = FALSE;
    return g_time_zone_new_utc();
  }
  /* It loads now: forget a failure another thread recorded while this load was running, or a
   * valid zone that is evicted later would be UTC until that entry expires. */
  for (guint i = 0; i < NEG_CACHE_SIZE; i++)
    if (neg_cache[i].expires_us != 0 && strcmp(neg_cache[i].name, tz) == 0)
      neg_cache[i].expires_us = 0;
  ZoneEntry *slot = &zone_cache[0]; /* a free slot, else the least recently used one */
  for (guint i = 0; i < ZONE_CACHE_SIZE; i++) {
    if (zone_cache[i].zone == NULL) {
      slot = &zone_cache[i];
      break;
    }
    if (zone_cache[i].used < slot->used)
      slot = &zone_cache[i];
  }
  if (slot->zone != NULL)
    g_time_zone_unref(slot->zone);
  g_strlcpy(slot->name, tz, sizeof slot->name);
  slot->zone = g_time_zone_ref(zone);
  slot->used = ++zone_tick;
  G_UNLOCK(zone_lock);
  return zone;
}

/**
 * zone_for_text:
 * @tz: (nullable): IANA zone name.
 *
 * zone_for() for the string formatters, which only need the zone: a failed
 * lookup is simply UTC for them.
 *
 * Preconditions:
 *  - as for zone_for().
 * Postconditions:
 *  - never NULL.
 * Thread affinity: any thread.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the zone; g_time_zone_unref() it.
 */
static GTimeZone *
zone_for_text(const char *tz)
{
  gboolean resolved;
  return zone_for(tz, &resolved);
}

/* Documented in wx-format.h. */
GTimeZone *
wx_format_zone_new(const char *tz, gboolean *resolved)
{
  gboolean ok;
  GTimeZone *zone = zone_for(tz, &ok);
  if (resolved != NULL)
    *resolved = ok;
  return zone;
}

/**
 * local_dt:
 * @t_s: UTC unix seconds.
 * @zone: non-NULL zone.
 *
 * Converts an instant to local calendar fields.
 *
 * Preconditions:
 *  - @zone is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the local time, NULL when @t_s is
 *   outside the valid time range.
 */
static GDateTime *
local_dt(gint64 t_s, GTimeZone *zone)
{
  if (!time_ok(t_s))
    return NULL;
  g_autoptr(GDateTime) utc = g_date_time_new_from_unix_utc(t_s);
  return utc != NULL ? g_date_time_to_timezone(utc, zone) : NULL;
}

/**
 * clock_text:
 * @dt: non-NULL local time.
 * @minutes: TRUE to always print the minutes.
 *
 * 12-hour clock text: "3 PM" (on the hour, @minutes FALSE) or "3:45 PM".
 *
 * Preconditions:
 *  - @dt is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): the text.
 */
static char *
clock_text(GDateTime *dt, gboolean minutes)
{
  int h = g_date_time_get_hour(dt);
  int m = g_date_time_get_minute(dt);
  const char *ampm = h < 12 ? "AM" : "PM";
  int h12 = h % 12 == 0 ? 12 : h % 12;
  if (m == 0 && !minutes)
    return g_strdup_printf("%d %s", h12, ampm);
  return g_strdup_printf("%d:%02d %s", h12, m, ampm);
}

/**
 * day_diff:
 * @dt: non-NULL local time.
 * @now: non-NULL local time of "now" in the same zone.
 *
 * Calendar days from @now's local date to @dt's local date.
 *
 * Preconditions:
 *  - both non-NULL, within years 2000..2100 (valid for GDate).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: 0 for the same day, 1 for the next day, negative for earlier days.
 */
static int
day_diff(GDateTime *dt, GDateTime *now)
{
  GDate a, b;
  g_date_set_dmy(&a, (GDateDay)g_date_time_get_day_of_month(dt),
                 (GDateMonth)g_date_time_get_month(dt), (GDateYear)g_date_time_get_year(dt));
  g_date_set_dmy(&b, (GDateDay)g_date_time_get_day_of_month(now),
                 (GDateMonth)g_date_time_get_month(now), (GDateYear)g_date_time_get_year(now));
  return (int)g_date_get_julian(&a) - (int)g_date_get_julian(&b);
}

/**
 * weekday_of:
 * @dt: non-NULL local time.
 *
 * Preconditions:
 *  - @dt is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the returned string is static.
 *
 * Returns: (transfer none): the English weekday name of @dt.
 */
static const char *
weekday_of(GDateTime *dt)
{
  return weekday_names[g_date_time_get_day_of_week(dt) - 1]; /* 1 = Monday .. 7 = Sunday */
}

/**
 * when_phrase:
 * @t_s: the time to describe.
 * @now_s: the current time.
 * @tz: (nullable): zone name.
 *
 * "around 4 PM" for today, "tomorrow around 4 PM" for the next local day,
 * "yesterday around 4 PM" for the previous one and "Friday around 4 PM" for
 * any other day; "around 3:30 PM" off the hour.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): the phrase; "later" when @t_s or @now_s is outside
 *   the valid time range.
 */
static char *
when_phrase(gint64 t_s, gint64 now_s, const char *tz)
{
  g_autoptr(GTimeZone) zone = zone_for_text(tz);
  g_autoptr(GDateTime) dt = local_dt(t_s, zone);
  g_autoptr(GDateTime) now = local_dt(now_s, zone);
  if (dt == NULL || now == NULL)
    return g_strdup("later");
  g_autofree char *clock = clock_text(dt, FALSE);
  int diff = day_diff(dt, now);
  if (diff == 0)
    return g_strdup_printf("around %s", clock);
  if (diff == 1)
    return g_strdup_printf("tomorrow around %s", clock);
  if (diff == -1)
    return g_strdup_printf("yesterday around %s", clock);
  return g_strdup_printf("%s around %s", weekday_of(dt), clock);
}

/**
 * valid_units:
 * @units: value to test.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: TRUE iff @units is a WxUnits member.
 */
static gboolean
valid_units(WxUnits units)
{
  return units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC;
}

/**
 * valid_state:
 * @state: value to test.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: TRUE iff @state is a WxRainState member.
 */
static gboolean
valid_state(WxRainState state)
{
  return state == WX_RAIN_DRY || state == WX_RAIN_NOW || state == WX_RAIN_EXPECTED ||
         state == WX_RAIN_POSSIBLE;
}

/* Documented in wx-format.h. */
char *
wx_format_temp(double c, WxUnits units, gboolean with_unit)
{
  g_return_val_if_fail(valid_units(units), NULL);
  if (!wx_value_in_range(c, WX_TEMP_MIN_C, WX_TEMP_MAX_C))
    return g_strdup(EM_DASH);
  gboolean metric = units == WX_UNITS_METRIC;
  long v = lround(metric ? c : c * 9.0 / 5.0 + 32.0); /* lround(-0.4) is 0, never "-0" */
  if (!with_unit)
    return g_strdup_printf("%ld\xc2\xb0", v);
  return g_strdup_printf("%ld\xc2\xb0%s", v, metric ? "C" : "F");
}

/* Documented in wx-format.h. */
char *
wx_format_wind(double kmh, WxUnits units)
{
  g_return_val_if_fail(valid_units(units), NULL);
  if (!wx_value_in_range(kmh, 0.0, WX_WIND_MAX_KMH))
    return g_strdup(EM_DASH);
  if (units == WX_UNITS_METRIC)
    return g_strdup_printf("%ld km/h", lround(kmh));
  return g_strdup_printf("%ld mph", lround(kmh * MPH_PER_KMH));
}

/* Documented in wx-format.h. */
char *
wx_format_precip(double mm, WxUnits units)
{
  g_return_val_if_fail(valid_units(units), NULL);
  if (!wx_value_in_range(mm, 0.0, WX_PRECIP_MAX_MM_DAY))
    return g_strdup(EM_DASH);
  char buf[G_ASCII_DTOSTR_BUF_SIZE];
  if (mm == 0.0)
    return g_strdup(units == WX_UNITS_METRIC ? "0 mm" : "0 in");
  /* Decide "too small" and "two or one decimals" from the text printf would
   * produce, so the text and the decision can never disagree on a tie. */
  if (units == WX_UNITS_METRIC) {
    g_ascii_formatd(buf, sizeof buf, "%.1f", mm);
    if (strcmp(buf, "0.0") == 0)
      return g_strdup("<0.1 mm");
    return g_strdup_printf("%s mm", buf);
  }
  double in = mm / MM_PER_INCH;
  g_ascii_formatd(buf, sizeof buf, "%.2f", in);
  if (strcmp(buf, "0.00") == 0)
    return g_strdup("<0.01 in");
  if (g_ascii_strtod(buf, NULL) >= 1.0)
    g_ascii_formatd(buf, sizeof buf, "%.1f", in);
  return g_strdup_printf("%s in", buf);
}

/* Documented in wx-format.h. */
char *
wx_format_percent(double pct)
{
  if (!wx_value_in_range(pct, WX_PERCENT_MIN, WX_PERCENT_MAX))
    return g_strdup(EM_DASH);
  return g_strdup_printf("%ld%%", lround(pct));
}

/* Documented in wx-format.h. */
char *
wx_format_hour_label_z(gint64 t_s, GTimeZone *zone)
{
  g_return_val_if_fail(zone != NULL, NULL);
  g_autoptr(GDateTime) dt = local_dt(t_s, zone);
  return dt != NULL ? clock_text(dt, FALSE) : g_strdup(EM_DASH);
}

/* Documented in wx-format.h. */
char *
wx_format_hour_label(gint64 t_s, const char *tz)
{
  g_autoptr(GTimeZone) zone = zone_for_text(tz);
  return wx_format_hour_label_z(t_s, zone);
}

/* Documented in wx-format.h. */
char *
wx_format_clock_z(gint64 t_s, GTimeZone *zone)
{
  g_return_val_if_fail(zone != NULL, NULL);
  g_autoptr(GDateTime) dt = local_dt(t_s, zone);
  return dt != NULL ? clock_text(dt, TRUE) : g_strdup(EM_DASH);
}

/* Documented in wx-format.h. */
char *
wx_format_clock(gint64 t_s, const char *tz)
{
  g_autoptr(GTimeZone) zone = zone_for_text(tz);
  return wx_format_clock_z(t_s, zone);
}

/* Documented in wx-format.h. */
char *
wx_format_weekday_z(gint64 t_s, GTimeZone *zone, gint64 now_s)
{
  g_return_val_if_fail(zone != NULL, NULL);
  g_autoptr(GDateTime) dt = local_dt(t_s, zone);
  if (dt == NULL)
    return g_strdup(EM_DASH);
  g_autoptr(GDateTime) now = local_dt(now_s, zone);
  int diff = now != NULL ? day_diff(dt, now) : -1;
  if (diff == 0)
    return g_strdup("Today");
  if (diff == 1)
    return g_strdup("Tomorrow");
  return g_strdup(weekday_of(dt));
}

/* Documented in wx-format.h. */
char *
wx_format_weekday(gint64 t_s, const char *tz, gint64 now_s)
{
  g_autoptr(GTimeZone) zone = zone_for_text(tz);
  return wx_format_weekday_z(t_s, zone, now_s);
}

/**
 * local_day_number:
 * @zone: non-NULL zone.
 * @t_s: UTC unix seconds in [WX_TIME_MIN_S, WX_TIME_MAX_S].
 *
 * Preconditions:
 *  - @zone is non-NULL and @t_s is in the range above.
 * Postconditions:
 *  - no state is changed. g_time_zone_find_interval() answers -1 when it
 *    cannot resolve; that is never handed to g_time_zone_get_offset(): the
 *    UTC offset 0 is used instead.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: whole days since 1970-01-01 of the local date at @t_s.
 */
static gint64
local_day_number(GTimeZone *zone, gint64 t_s)
{
  gint interval = g_time_zone_find_interval(zone, G_TIME_TYPE_UNIVERSAL, t_s);
  gint offset = interval >= 0 ? g_time_zone_get_offset(zone, interval) : 0;
  return (t_s + offset) / 86400; /* the local clock reading is positive in the range */
}

/* Documented in wx-format.h. */
gint64
wx_format_local_day_end_z(gint64 t_s, GTimeZone *zone)
{
  g_return_val_if_fail(zone != NULL, 0);
  g_autoptr(GDateTime) dt = local_dt(t_s, zone);
  if (dt == NULL)
    return 0;
  gint64 next_day = local_day_number(zone, t_s) + 1;

  /* GLib's own midnight of the next local date: the first valid instant when
   * midnight does not exist (a gap), but the SECOND midnight when the clock is
   * set back across it. The cannot-fail argument: the date comes from GLib. */
  g_autoptr(GDateTime) tomorrow = g_date_time_add_days(dt, 1);
  g_autoptr(GDateTime) midnight = g_date_time_new(zone, g_date_time_get_year(tomorrow),
                                                  g_date_time_get_month(tomorrow),
                                                  g_date_time_get_day_of_month(tomorrow), 0, 0, 0.0);
  gint64 glib_s = g_date_time_to_unix(midnight);
  gint64 first_s = glib_s > t_s ? glib_s : G_MAXINT64; /* not after t_s: only if t_s is past it */

  /* 00:00 of that date read with every UTC offset in effect within two days of
   * @t_s, accepted when the instant really is on that date and after @t_s: the
   * earliest such instant is the first midnight when the clock is set back
   * across it. */
  gint lo = MAX(g_time_zone_find_interval(zone, G_TIME_TYPE_UNIVERSAL, t_s - 2 * 86400), 0);
  gint hi = MAX(g_time_zone_find_interval(zone, G_TIME_TYPE_UNIVERSAL, t_s + 2 * 86400), 0);
  for (gint i = lo; i <= hi; i++) {
    gint64 c = next_day * 86400 - g_time_zone_get_offset(zone, i);
    if (c > t_s && c < first_s && local_day_number(zone, c) == next_day)
      first_s = c;
  }
  /* A candidate always qualifies (the GLib midnight, or one read with an offset of the window); the
   * bound only keeps the result finite should that ever fail. */
  return MIN(first_s, t_s + 2 * 86400);
}

/* Documented in wx-format.h. */
gint64
wx_format_local_day_end(gint64 t_s, const char *tz)
{
  g_autoptr(GTimeZone) zone = zone_for_text(tz);
  return wx_format_local_day_end_z(t_s, zone);
}

/* Documented in wx-format.h. */
gint64
wx_format_day_covered_from(const WxForecast *forecast, const WxDay *day, gint64 now_s)
{
  g_return_val_if_fail(forecast != NULL, 0);
  g_return_val_if_fail(day != NULL, 0);
  if (forecast->n_hours == 0 || forecast->hours == NULL)
    return 0;
  gint64 first_s = forecast->hours[0].t_s;
  /* the range checks make first_s - 3600 and the comparison free of overflow */
  if (first_s < WX_TIME_MIN_S || first_s >= WX_TIME_MAX_S || first_s > now_s ||
      day->start_s < WX_TIME_MIN_S || day->start_s >= WX_TIME_MAX_S ||
      first_s - 3600 < day->start_s)
    return 0;
  return first_s;
}

/* Documented in wx-format.h. */
char *
wx_format_updated(gint64 age_s)
{
  if (age_s < 60)
    return g_strdup("Updated just now");
  if (age_s < 3600)
    return g_strdup_printf("Updated %d min ago", (int)(age_s / 60));
  if (age_s < 86400)
    return g_strdup_printf("Updated %d h ago", (int)(age_s / 3600));
  gint64 days = age_s / 86400;
  if (days >= 30)
    return g_strdup("Updated over a month ago");
  return g_strdup_printf("Updated %d day%s ago", (int)days, days == 1 ? "" : "s");
}

/**
 * chance_text:
 * @prob: probability, percent.
 * @prefix: text put before the percentage when it is valid.
 * @suffix: text put after it.
 *
 * Builds " (40% chance)" style fragments.
 *
 * Preconditions:
 *  - @prefix and @suffix are non-NULL strings.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): prefix + percentage + suffix, or "" when @prob is
 *   not a percentage.
 */
static char *
chance_text(double prob, const char *prefix, const char *suffix)
{
  if (!wx_value_in_range(prob, WX_PERCENT_MIN, WX_PERCENT_MAX))
    return g_strdup("");
  return g_strdup_printf("%s%ld%%%s", prefix, lround(prob), suffix);
}

/* Documented in wx-format.h. */
char *
wx_rain_headline(const WxRainOutlook *outlook, gint64 now_s, const char *tz)
{
  g_return_val_if_fail(outlook != NULL, NULL);
  g_return_val_if_fail(valid_state(outlook->state), NULL);
  if (outlook->state == WX_RAIN_DRY)
    return g_strdup("No rain expected for the next 48 hours");
  if (!time_ok(now_s))
    return g_strdup("Rain outlook unavailable");

  switch (outlook->state) {
  case WX_RAIN_NOW: {
    if (!outlook->ends_known)
      return g_strdup("Raining now, expected to continue for hours");
    if (!time_ok(outlook->end_s))
      return g_strdup("Raining now");
    if (outlook->end_s <= now_s)
      return g_strdup("Raining now, easing soon");
    g_autofree char *when = when_phrase(outlook->end_s, now_s, tz);
    return g_strdup_printf("Raining now, easing %s", when);
  }
  case WX_RAIN_EXPECTED: {
    if (!time_ok(outlook->start_s))
      return g_strdup("Rain expected in the next 48 hours");
    gint64 delta = outlook->start_s - now_s;
    if (delta <= 0)
      return g_strdup("Rain starting now");
    if (delta < MINUTES_PHRASE_BELOW_S) {
      int minutes = (int)((delta + 59) / 60);
      return g_strdup_printf("Rain starting in %d minute%s", minutes, minutes == 1 ? "" : "s");
    }
    g_autofree char *when = when_phrase(outlook->start_s, now_s, tz);
    return g_strdup_printf("Rain expected %s", when);
  }
  default: { /* WX_RAIN_POSSIBLE */
    g_autofree char *chance = chance_text(outlook->peak_prob, " (", " chance)");
    if (!time_ok(outlook->peak_s))
      return g_strdup_printf("Showers possible in the next 48 hours%s", chance);
    if (outlook->peak_s <= now_s)
      return g_strdup_printf("Showers possible now%s", chance);
    g_autofree char *when = when_phrase(outlook->peak_s, now_s, tz);
    return g_strdup_printf("Showers possible %s%s", when, chance);
  }
  }
}

/**
 * intensity_word:
 * @mm_h: peak rain rate, mm per hour, finite and >= 0.
 *
 * Preconditions:
 *  - @mm_h is finite and non-negative.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: the returned string is static.
 *
 * Returns: (transfer none): "Very light", "Light", "Moderate" or "Heavy".
 */
static const char *
intensity_word(double mm_h)
{
  if (mm_h < VERY_LIGHT_BELOW_MM_H)
    return "Very light";
  if (mm_h < LIGHT_BELOW_MM_H)
    return "Light";
  if (mm_h < MODERATE_BELOW_MM_H)
    return "Moderate";
  return "Heavy";
}

/* Documented in wx-format.h. */
char *
wx_rain_detail(const WxRainOutlook *outlook, gint64 now_s, const char *tz)
{
  g_return_val_if_fail(outlook != NULL, NULL);
  g_return_val_if_fail(valid_state(outlook->state), NULL);
  if (!time_ok(now_s) || outlook->state == WX_RAIN_DRY)
    return g_strdup("");
  if (outlook->state == WX_RAIN_POSSIBLE)
    return g_strdup("No steady rain in the forecast, just a chance.");

  /* The outlook's peak covers the whole run, past samples included, so a
   * peak that is not in the future is reported as past ("peaked") and never
   * as the current rate. */
  g_autofree char *intensity = NULL;
  if (isfinite(outlook->peak_mm_h) && outlook->peak_mm_h >= 0.0) {
    const char *word = intensity_word(outlook->peak_mm_h);
    if (!time_ok(outlook->peak_s)) {
      intensity = g_strdup_printf("%s rain at its heaviest.", word);
    } else {
      g_autofree char *when = when_phrase(outlook->peak_s, now_s, tz);
      if (outlook->peak_s > now_s) {
        intensity = g_strdup_printf("%s rain, heaviest %s.", word, when);
      } else {
        g_autofree char *lower = g_ascii_strdown(word, -1);
        intensity = g_strdup_printf("Rain peaked %s (%s).", when, lower);
      }
    }
  }
  /* "N% chance of rain" is only meaningful while no rain has started. */
  g_autofree char *chance =
      outlook->state == WX_RAIN_EXPECTED ? chance_text(outlook->peak_prob, "", " chance of rain.")
                                         : g_strdup("");
  if (intensity != NULL && chance[0] != '\0')
    return g_strdup_printf("%s %s", intensity, chance);
  return g_strdup(intensity != NULL ? intensity : chance);
}

/**
 * cloud_band:
 * @pct: cloud cover, percent.
 *
 * Bands of design 5.5: [0,12.5) Clear, [12.5,37.5) Mostly clear, [37.5,62.5)
 * Partly cloudy, [62.5,87.5) Mostly cloudy, [87.5,100] Overcast.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the band, or -1 when @pct is not a percentage.
 */
static int
cloud_band(double pct)
{
  if (!wx_value_in_range(pct, WX_PERCENT_MIN, WX_PERCENT_MAX))
    return -1;
  if (pct < 12.5)
    return BAND_CLEAR;
  if (pct < 37.5)
    return BAND_MOSTLY_CLEAR;
  if (pct < 62.5)
    return BAND_PARTLY;
  if (pct < 87.5)
    return BAND_MOSTLY_CLOUDY;
  return BAND_OVERCAST;
}

/* Documented in wx-format.h. */
char *
wx_cloud_sentence(const WxForecast *forecast, gint64 now_s, const char *tz)
{
  g_return_val_if_fail(forecast != NULL, NULL);
  const WxBlendHour *hours = forecast->hours;
  guint n = forecast->n_hours;
  if (!time_ok(now_s))
    return g_strdup("Cloud cover unknown");

  /* The current band is that of the cloud cover wx_forecast_now() reports (the interpolated one),
   * the same value the detail pane shows as cover and condition. */
  guint i = 0;
  while (i < n && !(hours[i].t_s <= now_s && hours[i].t_s > now_s - 3600)) /* no overflow */
    i++;
  WxBlendHour current;
  if (i == n || !wx_forecast_now(forecast, now_s, &current))
    return g_strdup("Cloud cover unknown");
  int cur = cloud_band(current.cloud_pct);
  if (cur < 0)
    return g_strdup("Cloud cover unknown");

  gint64 covered_until = hours[i].t_s + 3600;
  for (i++; i < n && hours[i].t_s < now_s + CLOUD_LOOKAHEAD_S; i++) {
    int band = cloud_band(hours[i].cloud_pct);
    if (band < 0)
      continue;
    if (band != cur) {
      g_autofree char *when = when_phrase(hours[i].t_s, now_s, tz);
      return g_strdup_printf("%s now, %s %s", band_now[cur], band_target[band], when);
    }
    covered_until = hours[i].t_s + 3600;
  }
  if (covered_until >= now_s + CLOUD_LOOKAHEAD_S)
    return g_strdup_printf("%s for the next 24 hours", band_steady[cur]);
  gint64 left = (covered_until - now_s) / 3600;
  if (left < 2)
    return g_strdup_printf("%s for the next hour", band_steady[cur]);
  return g_strdup_printf("%s for the next %d hours", band_steady[cur], (int)left);
}
