/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* Offline unit tests of the GTK-free formatting and icon modules (no display). */
#include <glib.h>
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-format.h"
#include "wx-format-testing.h"
#include "wx-icons.h"
#include "wx-types.h"

#define DASH "\xe2\x80\x94"
#define DEG "\xc2\xb0"

/* Runs @check with the one critical that @fname's g_return_val_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

#define ASSERT_INT64(expr, expected) g_assert_cmpint((expr), ==, (expected))

/* Frees the string returned by @expr and compares it with @expected. */
#define ASSERT_STR(expr, expected)       \
  G_STMT_START {                         \
    char *s_ = (expr);                   \
    g_assert_nonnull(s_);                \
    g_assert_cmpstr(s_, ==, (expected)); \
    g_free(s_);                          \
  }                                      \
  G_STMT_END

static WxRainOutlook outlook(WxRainState state, gint64 start, gint64 end, gboolean known, gint64 peak,
                             double mm, double prob);

static gint64
ts(int y, int mo, int d, int h, int mi, int s)
{
  g_autoptr(GDateTime) dt = g_date_time_new_utc(y, mo, d, h, mi, s);
  g_assert_nonnull(dt);
  return g_date_time_to_unix(dt);
}

#define NY "America/New_York"

/* ------------------------------------------------------------------------ */
/* numbers                                                                  */
/* ------------------------------------------------------------------------ */

static void
test_temp(void)
{
  struct {
    double c;
    const char *imp, *imp_u, *met, *met_u;
  } t[] = {
    { 0, "32" DEG, "32" DEG "F", "0" DEG, "0" DEG "C" },
    { 25, "77" DEG, "77" DEG "F", "25" DEG, "25" DEG "C" },
    { -40, "-40" DEG, "-40" DEG "F", "-40" DEG, "-40" DEG "C" },
    { 24.5, "76" DEG, "76" DEG "F", "25" DEG, "25" DEG "C" },   /* 76.1 F; halves away */
    { 24.4, "76" DEG, "76" DEG "F", "24" DEG, "24" DEG "C" },
    { -0.4, "31" DEG, "31" DEG "F", "0" DEG, "0" DEG "C" },     /* never "-0" */
    { -0.5, "31" DEG, "31" DEG "F", "-1" DEG, "-1" DEG "C" },   /* 31.1 F */
    { -0.0, "32" DEG, "32" DEG "F", "0" DEG, "0" DEG "C" },
    { -17.7778, "0" DEG, "0" DEG "F", "-18" DEG, "-18" DEG "C" }, /* imperial zero, never "-0" */
    { -18.0, "0" DEG, "0" DEG "F", "-18" DEG, "-18" DEG "C" },
    { 70.0, "158" DEG, "158" DEG "F", "70" DEG, "70" DEG "C" },
    { -100.0, "-148" DEG, "-148" DEG "F", "-100" DEG, "-100" DEG "C" },
    { 70.0001, DASH, DASH, DASH, DASH },
    { -100.0001, DASH, DASH, DASH, DASH },
    { NAN, DASH, DASH, DASH, DASH },
    { INFINITY, DASH, DASH, DASH, DASH },
    { -INFINITY, DASH, DASH, DASH, DASH },
    { 1e300, DASH, DASH, DASH, DASH },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    ASSERT_STR(wx_format_temp(t[i].c, WX_UNITS_IMPERIAL, FALSE), t[i].imp);
    ASSERT_STR(wx_format_temp(t[i].c, WX_UNITS_IMPERIAL, TRUE), t[i].imp_u);
    ASSERT_STR(wx_format_temp(t[i].c, WX_UNITS_METRIC, FALSE), t[i].met);
    ASSERT_STR(wx_format_temp(t[i].c, WX_UNITS_METRIC, TRUE), t[i].met_u);
  }
  ASSERT_CRITICAL("wx_format_temp", g_assert_null(wx_format_temp(1, (WxUnits)7, TRUE)));
  ASSERT_CRITICAL("wx_format_temp", g_assert_null(wx_format_temp(1, (WxUnits)-1, FALSE)));
}

static void
test_wind(void)
{
  struct {
    double kmh;
    const char *imp, *met;
  } t[] = {
    { 0, "0 mph", "0 km/h" },
    { 0.4, "0 mph", "0 km/h" },
    { 0.5, "0 mph", "1 km/h" }, /* 0.31 mph */
    { 1.0, "1 mph", "1 km/h" },     /* 0.62 mph rounds up */
    { 19.3, "12 mph", "19 km/h" },
    { 100, "62 mph", "100 km/h" },
    { 500, "311 mph", "500 km/h" },
    { 500.0001, DASH, DASH },
    { -0.0001, DASH, DASH },
    { NAN, DASH, DASH },
    { INFINITY, DASH, DASH },
    { -INFINITY, DASH, DASH },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    ASSERT_STR(wx_format_wind(t[i].kmh, WX_UNITS_IMPERIAL), t[i].imp);
    ASSERT_STR(wx_format_wind(t[i].kmh, WX_UNITS_METRIC), t[i].met);
  }
  ASSERT_CRITICAL("wx_format_wind", g_assert_null(wx_format_wind(1, (WxUnits)3)));
}

static void
test_precip(void)
{
  struct {
    double mm;
    const char *imp, *met;
  } t[] = {
    { 0, "0 in", "0 mm" },
    { -0.0, "0 in", "0 mm" },
    { 0.04, "<0.01 in", "<0.1 mm" },
    { 0.1, "<0.01 in", "0.1 mm" },        /* 0.0039 in */
    { 0.2, "0.01 in", "0.2 mm" },         /* 0.0079 in */
    { 2.5, "0.10 in", "2.5 mm" },
    { 6.35, "0.25 in", "6.3 mm" },        /* 6.35 is 6.3499.. in binary */
    { 25.3, "1.0 in", "25.3 mm" },        /* 0.996 in prints as 1.0, not 1.00 */
    { 25.4, "1.0 in", "25.4 mm" },
    { 24.9, "0.98 in", "24.9 mm" },
    { 38.1, "1.5 in", "38.1 mm" },
    { 100, "3.9 in", "100.0 mm" },
    { 12000, "472.4 in", "12000.0 mm" },
    { 12000.0001, DASH, DASH },
    { -0.0001, DASH, DASH },
    { NAN, DASH, DASH },
    { INFINITY, DASH, DASH },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    ASSERT_STR(wx_format_precip(t[i].mm, WX_UNITS_IMPERIAL), t[i].imp);
    ASSERT_STR(wx_format_precip(t[i].mm, WX_UNITS_METRIC), t[i].met);
  }
  ASSERT_CRITICAL("wx_format_precip", g_assert_null(wx_format_precip(1, (WxUnits)9)));
  /* a positive amount is never printed as zero */
  for (double mm = 0.0001; mm < 0.3; mm += 0.0001) {
    g_autofree char *i = wx_format_precip(mm, WX_UNITS_IMPERIAL);
    g_autofree char *m = wx_format_precip(mm, WX_UNITS_METRIC);
    g_assert_false(g_str_has_prefix(i, "0.00"));
    g_assert_false(g_str_has_prefix(m, "0.0 "));
  }
}

static void
test_percent(void)
{
  ASSERT_STR(wx_format_percent(0), "0%");
  ASSERT_STR(wx_format_percent(-0.0), "0%");
  ASSERT_STR(wx_format_percent(40.4), "40%");
  ASSERT_STR(wx_format_percent(40.5), "41%");
  ASSERT_STR(wx_format_percent(99.5), "100%");
  ASSERT_STR(wx_format_percent(100), "100%");
  ASSERT_STR(wx_format_percent(100.0001), DASH);
  ASSERT_STR(wx_format_percent(-0.0001), DASH);
  ASSERT_STR(wx_format_percent(NAN), DASH);
  ASSERT_STR(wx_format_percent(INFINITY), DASH);
  ASSERT_STR(wx_format_percent(-INFINITY), DASH);
}

/* The output never depends on the process locale. */
static void
test_locale_independent(void)
{
  const char *names[] = { "de_DE.UTF-8", "fr_FR.UTF-8", "ar_SA.UTF-8", "C.UTF-8" };
  for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
    if (setlocale(LC_ALL, names[i]) == NULL)
      continue;
    ASSERT_STR(wx_format_precip(6.35, WX_UNITS_IMPERIAL), "0.25 in");
    ASSERT_STR(wx_format_precip(2.5, WX_UNITS_METRIC), "2.5 mm");
    ASSERT_STR(wx_format_temp(1234.0 / 100.0, WX_UNITS_METRIC, TRUE), "12" DEG "C");
    ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), NY), "3 PM");
    ASSERT_STR(wx_format_clock(ts(2026, 10, 11, 19, 45, 0), NY), "3:45 PM");
    ASSERT_STR(wx_format_weekday(ts(2026, 10, 11, 19, 0, 0), "UTC", 0), "Sunday");
  }
  setlocale(LC_ALL, "C");
}

/* ------------------------------------------------------------------------ */
/* times                                                                    */
/* ------------------------------------------------------------------------ */

static void
test_hour_label_and_clock(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0); /* 3 PM EDT */
  ASSERT_STR(wx_format_hour_label(t, NY), "3 PM");
  ASSERT_STR(wx_format_clock(t, NY), "3:00 PM");
  ASSERT_STR(wx_format_clock(t + 45 * 60, NY), "3:45 PM");
  ASSERT_STR(wx_format_hour_label(t + 45 * 60, NY), "3:45 PM"); /* never claims a wrong hour */
  ASSERT_STR(wx_format_hour_label(t + 59, NY), "3 PM");          /* seconds are dropped */
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 4, 0, 0), NY), "12 AM");
  ASSERT_STR(wx_format_clock(ts(2026, 10, 11, 4, 5, 0), NY), "12:05 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 16, 0, 0), NY), "12 PM");
  ASSERT_STR(wx_format_clock(ts(2026, 10, 11, 16, 0, 0), NY), "12:00 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 15, 59, 59), NY), "11:59 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 15, 0, 59), NY), "11 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 17, 0, 0), NY), "1 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 12, 3, 59, 0), NY), "11:59 PM");

  /* DST: spring forward 2026-03-08 at 02:00 EST (07:00Z), fall back 2026-11-01 at 02:00 EDT. */
  ASSERT_STR(wx_format_clock(ts(2026, 3, 8, 6, 59, 59), NY), "1:59 AM");
  ASSERT_STR(wx_format_clock(ts(2026, 3, 8, 7, 0, 0), NY), "3:00 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 11, 1, 5, 0, 0), NY), "1 AM"); /* EDT */
  ASSERT_STR(wx_format_hour_label(ts(2026, 11, 1, 6, 0, 0), NY), "1 AM"); /* the repeated hour, EST */
  ASSERT_STR(wx_format_hour_label(ts(2026, 11, 1, 7, 0, 0), NY), "2 AM");

  /* other zones, half-hour and 45-minute offsets, southern hemisphere */
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 0, 0, 0), "Australia/Sydney"), "11 AM"); /* +11 */
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 12, 0, 0), "Europe/London"), "1 PM");    /* BST */
  ASSERT_STR(wx_format_hour_label(ts(2026, 1, 11, 12, 0, 0), "Europe/London"), "12 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 18, 0, 0), "Asia/Kolkata"), "11:30 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 0, 0, 0), "Asia/Kathmandu"), "5:45 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 12, 0, 0), "Etc/GMT+5"), "7 AM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 12, 0, 0), "Pacific/Kiritimati"), "2 AM"); /* +14 */

  /* UTC for NULL, "", unknown, wrongly shaped and directory / non-TZif names */
  const char *utc_names[] = { NULL, "", "UTC", "Nowhere/Land", "/etc/passwd", "../x", "a//b",
                              "America/", "/America/New_York", ".", "..", "-x", "9x", "A b",
                              "America/New_York\n", "America", "leapseconds", "posix",
                              "America/New_York/x", "\xff\xfe", "SECURITY", "Japan", "EST5EDT", "Etc" };
  for (guint i = 0; i < G_N_ELEMENTS(utc_names); i++) {
    ASSERT_STR(wx_format_hour_label(t, utc_names[i]), "7 PM");
    ASSERT_STR(wx_format_clock(t, utc_names[i]), "7:00 PM");
  }
  g_autofree char *long_name = g_strnfill(65, 'A'); /* 65 bytes: one too many */
  ASSERT_STR(wx_format_hour_label(t, long_name), "7 PM");
  g_autofree char *max_name = g_strnfill(64, 'A'); /* shaped ok, unknown to GLib */
  ASSERT_STR(wx_format_hour_label(t, max_name), "7 PM");

  /* the valid range is [WX_TIME_MIN_S, WX_TIME_MAX_S) */
  ASSERT_STR(wx_format_hour_label(WX_TIME_MIN_S - 1, NY), DASH);
  ASSERT_STR(wx_format_hour_label(WX_TIME_MAX_S, NY), DASH);
  ASSERT_STR(wx_format_hour_label(G_MININT64, NY), DASH);
  ASSERT_STR(wx_format_hour_label(G_MAXINT64, NY), DASH);
  ASSERT_STR(wx_format_hour_label(0, NY), DASH);
  ASSERT_STR(wx_format_clock(G_MININT64, NY), DASH);
  ASSERT_STR(wx_format_clock(WX_TIME_MAX_S, NULL), DASH);
  ASSERT_STR(wx_format_clock(WX_TIME_MIN_S, "UTC"), "12:00 AM");
  ASSERT_STR(wx_format_clock(WX_TIME_MAX_S - 1, "UTC"), "11:59 PM");
}

static WxBlendHour cloud_hour(gint64 t_s, double cloud);

/* tz is read through memchr bounded by WX_PLACE_TIMEZONE_MAX + 1: never past 65 bytes. */
static void
test_tz_read_bound(void)
{
  long page = sysconf(_SC_PAGESIZE);
  char *map = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect(map + page, (size_t)page, PROT_NONE), ==, 0);
  gsize n = WX_PLACE_TIMEZONE_MAX + 1;
  char *buf = map + page - n; /* the 65 bytes end exactly at the guard page */
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  for (int first = 1; first < 256; first++) {
    memset(buf, 'A', n);
    buf[0] = (char)first;
    g_autofree char *a = wx_format_hour_label(t, buf);
    g_autofree char *b = wx_format_clock(t, buf);
    g_assert_cmpstr(a, ==, "7 PM");
    g_assert_cmpstr(b, ==, "7:00 PM");
    g_autofree char *w = wx_format_weekday(t, buf, t);
    g_assert_cmpstr(w, ==, "Today");
    WxRainOutlook o = { .state = WX_RAIN_NOW, .ends_known = TRUE, .end_s = t + 7200 };
    g_autofree char *h = wx_rain_headline(&o, t, buf);
    g_assert_cmpstr(h, ==, "Raining now, easing around 9 PM");
    o.peak_s = t + 3600;
    o.peak_mm_h = 1.0;
    o.peak_prob = NAN;
    g_autofree char *d = wx_rain_detail(&o, t, buf);
    g_assert_cmpstr(d, ==, "Light rain, heaviest around 8 PM.");
    WxBlendHour hs[2] = { cloud_hour(t - 1800 - (t - 1800) % 3600, 70), cloud_hour(t - 1800 - (t - 1800) % 3600 + 3600, 10) };
    WxForecast raw = { .hours = hs, .n_hours = 2 };
    g_autofree char *c = wx_cloud_sentence(&raw, t - 600, buf);
    /* 10 minutes before the next hour: the cloud cover of "now" is 70 + (10 - 70) * 50/60 = 20 %
     * (mostly clear), the value wx_forecast_now() reports, not the 70 % at the start of the hour */
    g_assert_cmpstr(c, ==, "Mostly clear now, clearing around 7 PM");
  }
  /* a name that ends with a NUL inside the window is read up to the NUL only */
  memset(buf, 'x', n);
  memcpy(buf + n - 1 - 16, NY, 17); /* NUL terminator is the last byte of the window */
  memmove(buf, buf + n - 1 - 16, 17);
  memset(buf + 17, 'x', n - 17);
  ASSERT_STR(wx_format_hour_label(t, buf), "3 PM");
  munmap(map, (size_t)page * 2);
}

/* THE TIME ZONE RULE shared with the other weather modules: a zone string is an IANA zone only
 * when it is Area/Location-shaped (contains a '/') or exactly "UTC"; every other string is UTC. */
static void
test_zone_rule_table(void)
{
  gint64 winter = ts(2026, 7, 11, 12, 0, 0);  /* northern summer / southern winter */
  gint64 summer = ts(2026, 10, 11, 12, 0, 0); /* 12:00 UTC */
  struct {
    const char *tz;
    int off_oct_s; /* UTC offset on 2026-10-11 */
    int off_jul_s; /* UTC offset on 2026-07-11 */
  } t[] = {
    { "America/New_York", -4 * 3600, -4 * 3600 },
    { "Asia/Kolkata", 19800, 19800 },
    { "Australia/Lord_Howe", 11 * 3600, 10 * 3600 + 1800 },
    { "Australia/Sydney", 11 * 3600, 10 * 3600 },
    { "Asia/Kathmandu", 20700, 20700 },
    { "Etc/GMT+5", -5 * 3600, -5 * 3600 },
    { "UTC", 0, 0 },
    { NULL, 0, 0 },
    { "", 0, 0 },
    /* one-word aliases and non-zone files are NOT looked up, although their files exist */
    { "Japan", 0, 0 },
    { "Singapore", 0, 0 },
    { "EST5EDT", 0, 0 },
    { "Zulu", 0, 0 },
    { "leapseconds", 0, 0 },
    { "tzdata.zi", 0, 0 },
    { "utc", 0, 0 },
    { "Etc", 0, 0 },
    /* hostile or ill-shaped */
    { "../x", 0, 0 },
    { "/etc/passwd", 0, 0 },
    { "America/New_York/", 0, 0 },
    { "America//New_York", 0, 0 },
    { "America/../New_York", 0, 0 },
    { "America/.New_York", 0, 0 },
    { "America/9x", 0, 0 },
    { " America/New_York", 0, 0 },
    { "America/New York", 0, 0 },
    /* well-shaped but unknown to GLib */
    { "Nowhere/Land", 0, 0 },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    for (int k = 0; k < 2; k++) {
      gint64 instant = k ? winter : summer;
      int off = k ? t[i].off_jul_s : t[i].off_oct_s;
      gint64 local = instant + off; /* what the clock shows, as UTC seconds */
      g_autoptr(GDateTime) want = g_date_time_new_from_unix_utc(local);
      g_autofree char *expect = g_strdup_printf("%d:%02d %s", g_date_time_get_hour(want) % 12 == 0 ? 12 : g_date_time_get_hour(want) % 12,
                                                 g_date_time_get_minute(want),
                                                 g_date_time_get_hour(want) < 12 ? "AM" : "PM");
      g_autofree char *got = wx_format_clock(instant, t[i].tz);
      if (g_strcmp0(got, expect) != 0)
        g_test_message("zone '%s' at %" G_GINT64_FORMAT, t[i].tz ? t[i].tz : "(null)", instant);
      g_assert_cmpstr(got, ==, expect);
    }
  }
  /* spot values written out by hand */
  ASSERT_STR(wx_format_clock(summer, "Australia/Lord_Howe"), "11:00 PM");
  ASSERT_STR(wx_format_clock(winter, "Australia/Lord_Howe"), "10:30 PM");
  ASSERT_STR(wx_format_clock(summer, "Asia/Kolkata"), "5:30 PM");
  ASSERT_STR(wx_format_clock(summer, "Japan"), "12:00 PM");
  ASSERT_STR(wx_format_clock(summer, "Singapore"), "12:00 PM");
  ASSERT_STR(wx_format_clock(summer, "EST5EDT"), "12:00 PM");
  ASSERT_STR(wx_format_clock(summer, "leapseconds"), "12:00 PM");
}

/* No zoneinfo file is read again once a zone is loaded; unknown names are looked up once. */
static void
test_zone_cache(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  wx_format_test_set_hooks(NULL, NULL); /* an empty cache, whatever the earlier tests loaded */
  guint base = wx_format_zone_loads();
  /* names that need no lookup never count */
  const char *free_names[] = { NULL, "", "UTC", "Japan", "../x", "leapseconds", "a//b", "/etc/passwd" };
  for (guint i = 0; i < G_N_ELEMENTS(free_names); i++) {
    g_free(wx_format_hour_label(t, free_names[i]));
    g_free(wx_format_clock(t, free_names[i]));
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base);

  /* the first use loads, every later use of any formatter hits the cache */
  ASSERT_STR(wx_format_hour_label(t, "Africa/Nairobi"), "10 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 1);
  for (int i = 0; i < 200; i++) {
    g_free(wx_format_hour_label(t, "Africa/Nairobi"));
    g_free(wx_format_clock(t, "Africa/Nairobi"));
    g_free(wx_format_weekday(t, "Africa/Nairobi", t));
    WxRainOutlook o = outlook(WX_RAIN_EXPECTED, t + 7200, 0, FALSE, t + 7200, 1, 50);
    g_free(wx_rain_headline(&o, t, "Africa/Nairobi"));
    g_free(wx_rain_detail(&o, t, "Africa/Nairobi"));
    g_assert_cmpint((int)wx_format_local_day_end(t, "Africa/Nairobi"), !=, 0);
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 1);

  /* an unknown name is looked up once, shown as UTC, and not looked up again */
  for (int i = 0; i < 5; i++)
    ASSERT_STR(wx_format_hour_label(t, "Mars/Olympus"), "7 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 2);

  /* eight more names evict the oldest ones: Nairobi is loaded again, a recent one is not */
  char name[16];
  for (int i = 1; i <= 8; i++) {
    g_snprintf(name, sizeof name, "Etc/GMT+%d", i);
    g_free(wx_format_hour_label(t, name));
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 10);
  g_free(wx_format_hour_label(t, "Etc/GMT+8")); /* newest: still cached */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 10);
  ASSERT_STR(wx_format_hour_label(t, "Africa/Nairobi"), "10 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 11);
  /* the cache never changes a result */
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+8"), "11 AM");
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+1"), "6 PM");
}

static void
test_local_day_end(void)
{
  /* a normal day: New York midnight is 04:00Z during daylight time */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 11, 18, 0, 0), NY), ts(2026, 10, 12, 4, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 12, 3, 59, 59), NY), ts(2026, 10, 12, 4, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 12, 4, 0, 0), NY), ts(2026, 10, 13, 4, 0, 0));
  /* DST days are 25 and 23 hours long */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 11, 1, 12, 0, 0), NY), ts(2026, 11, 2, 5, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 3, 8, 12, 0, 0), NY), ts(2026, 3, 9, 4, 0, 0));
  /* UTC for NULL, "" and non-zones */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 11, 18, 0, 0), NULL), ts(2026, 10, 12, 0, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 11, 18, 0, 0), "Japan"), ts(2026, 10, 12, 0, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 11, 18, 0, 0), "Asia/Kolkata"), ts(2026, 10, 11, 18, 30, 0));
  /* a midnight that does not exist (Cuba springs forward at 00:00 on 2026-03-08) is the first valid instant */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 3, 7, 12, 0, 0), "America/Havana"), ts(2026, 3, 8, 5, 0, 0));
  /* the range ends */
  ASSERT_INT64(wx_format_local_day_end(WX_TIME_MIN_S, "UTC"), WX_TIME_MIN_S + 86400);
  ASSERT_INT64(wx_format_local_day_end(WX_TIME_MAX_S - 1, "UTC"), WX_TIME_MAX_S);
  ASSERT_INT64(wx_format_local_day_end(WX_TIME_MIN_S - 1, NY), 0);
  ASSERT_INT64(wx_format_local_day_end(WX_TIME_MAX_S, NY), 0);
  ASSERT_INT64(wx_format_local_day_end(0, NY), 0);
  ASSERT_INT64(wx_format_local_day_end(G_MININT64, NY), 0);
  ASSERT_INT64(wx_format_local_day_end(G_MAXINT64, NULL), 0);
}

/* Length of the local day that starts at the first midnight after @inside_prev_day. */
static gint64
next_day_length(const char *tz, gint64 inside_prev_day)
{
  gint64 start = wx_format_local_day_end(inside_prev_day, tz);
  return wx_format_local_day_end(start, tz) - start;
}

/* The documented day lengths (wx-format.h): a day lasts as long as the clock makes it. */
static void
test_local_day_lengths(void)
{
  ASSERT_INT64(next_day_length(NY, ts(2026, 3, 7, 12, 0, 0)), 23 * 3600);    /* spring forward */
  ASSERT_INT64(next_day_length(NY, ts(2026, 10, 31, 12, 0, 0)), 25 * 3600);  /* fall back */
  ASSERT_INT64(next_day_length(NY, ts(2026, 5, 1, 12, 0, 0)), 24 * 3600);
  ASSERT_INT64(next_day_length("Antarctica/Troll", ts(2026, 3, 28, 12, 0, 0)), 22 * 3600);
  ASSERT_INT64(next_day_length("Antarctica/Troll", ts(2026, 10, 24, 12, 0, 0)), 26 * 3600);
  ASSERT_INT64(next_day_length("Australia/Lord_Howe", ts(2026, 4, 4, 12, 0, 0)), 24 * 3600 + 1800);
  ASSERT_INT64(next_day_length("Australia/Lord_Howe", ts(2026, 10, 3, 12, 0, 0)), 23 * 3600 + 1800);
  /* a skipped date does not lengthen the day before it (Pacific/Apia, 2011-12-29 24 h; 12-30 never was) */
  ASSERT_INT64(next_day_length("Pacific/Apia", ts(2011, 12, 28, 20, 0, 0)), 24 * 3600);
  ASSERT_INT64(wx_format_local_day_end(ts(2011, 12, 29, 20, 0, 0), "Pacific/Apia"), ts(2011, 12, 30, 10, 0, 0));
  ASSERT_INT64(next_day_length("Pacific/Apia", ts(2011, 12, 29, 20, 0, 0)), 24 * 3600); /* 12-31 */
}

/* A clock set back across midnight: the FIRST midnight ends the day (the rule of the blend). */
static void
test_local_day_end_repeated_midnight(void)
{
  /* Atlantic/Azores: Sat 2026-10-24; the clock goes 01:00 -> 00:00 at 01:00Z on Oct 25, so 00:00 local
   * happens at 00:00Z and again at 01:00Z. */
  const char *az = "Atlantic/Azores";
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 24, 12, 0, 0), az), ts(2026, 10, 25, 0, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 24, 0, 0, 0), az), ts(2026, 10, 25, 0, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 24, 23, 59, 59), az), ts(2026, 10, 25, 0, 0, 0));
  /* Oct 25 itself starts at 00:00Z and ends at the next midnight, 00:00 at UTC-1 = 01:00Z on Oct 26 */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 25, 0, 0, 0), az), ts(2026, 10, 26, 1, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 25, 0, 30, 0), az), ts(2026, 10, 26, 1, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 25, 1, 30, 0), az), ts(2026, 10, 26, 1, 0, 0));
  /* America/Havana: Sat 2026-10-31; 00:00 local on Nov 1 happens at 04:00Z and again at 05:00Z */
  const char *hv = "America/Havana";
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 31, 12, 0, 0), hv), ts(2026, 11, 1, 4, 0, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 10, 31, 16, 0, 0), hv), ts(2026, 11, 1, 4, 0, 0));
  /* America/St_Johns 2007-11-04: 00:01 NDT went back to 23:01 NST on Nov 3 (02:31Z) */
  const char *sj = "America/St_Johns";
  ASSERT_INT64(wx_format_local_day_end(ts(2007, 11, 3, 12, 0, 0), sj), ts(2007, 11, 4, 2, 30, 0));
  ASSERT_INT64(wx_format_local_day_end(ts(2007, 11, 4, 2, 30, 0), sj), ts(2007, 11, 5, 3, 30, 0)); /* Nov 4 */
  ASSERT_INT64(wx_format_local_day_end(ts(2007, 11, 4, 2, 30, 59), sj), ts(2007, 11, 5, 3, 30, 0));
  /* t inside the repeated hour (23:10 NST on Nov 3, 02:40Z): the first midnight is past, the second counts */
  ASSERT_INT64(wx_format_local_day_end(ts(2007, 11, 4, 2, 40, 0), sj), ts(2007, 11, 4, 3, 30, 0));
  /* a midnight that does not exist (Havana springs forward at 00:00 on 2026-03-08): the first valid instant */
  ASSERT_INT64(wx_format_local_day_end(ts(2026, 3, 7, 12, 0, 0), hv), ts(2026, 3, 8, 5, 0, 0));
  /* a whole date skipped (Pacific/Apia, 2011-12-30 did not exist): the next date's first instant */
  ASSERT_INT64(wx_format_local_day_end(ts(2011, 12, 30, 9, 0, 0), "Pacific/Apia"), ts(2011, 12, 30, 10, 0, 0));
}

/* ----- cross-check against a brute-force scan, over every zone of the database ----- */

/* The first instant after @t whose local date is later than that of @t, found by a scan in one-minute
 * steps (every offset change is on a minute boundary, so no window of a later date is missed) and a
 * bisection of the last minute. Independent of the production code: it only asks GLib for offsets. */
static gint64
brute_day_end(GTimeZone *z, gint64 t)
{
  gint iv = g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, t);
  gint64 date = (t + g_time_zone_get_offset(z, iv)) / 86400;
  for (gint64 c = t + 60;; c += 60) {
    iv = g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, c);
    if ((c + g_time_zone_get_offset(z, iv)) / 86400 > date) {
      gint64 lo = c - 60, hi = c; /* lo is not later, hi is */
      while (hi - lo > 1) {
        gint64 mid = lo + (hi - lo) / 2;
        iv = g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, mid);
        if ((mid + g_time_zone_get_offset(z, iv)) / 86400 > date)
          hi = mid;
        else
          lo = mid;
      }
      return hi;
    }
    g_assert_cmpint(c - t, <, 4 * 86400);
  }
}

static void
collect_zones(const char *root, const char *rel, GPtrArray *out)
{
  g_autofree char *dir = rel[0] ? g_build_filename(root, rel, NULL) : g_strdup(root);
  g_autoptr(GDir) d = g_dir_open(dir, 0, NULL);
  if (d == NULL)
    return;
  const char *name;
  while ((name = g_dir_read_name(d)) != NULL) {
    if (name[0] == '.' || strcmp(name, "posix") == 0 || strcmp(name, "right") == 0)
      continue;
    g_autofree char *relname = rel[0] ? g_strconcat(rel, "/", name, NULL) : g_strdup(name);
    g_autofree char *path = g_build_filename(root, relname, NULL);
    if (g_file_test(path, G_FILE_TEST_IS_SYMLINK))
      continue;
    if (g_file_test(path, G_FILE_TEST_IS_DIR)) {
      collect_zones(root, relname, out);
    } else if (strchr(relname, '/') != NULL &&
               strspn(relname, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-/") ==
                   strlen(relname)) {
      char magic[4] = { 0 };
      FILE *f = fopen(path, "rb");
      if (f != NULL) {
        if (fread(magic, 1, 4, f) == 4 && memcmp(magic, "TZif", 4) == 0)
          g_ptr_array_add(out, g_strdup(relname));
        fclose(f);
      }
    }
  }
}

static gint
cmp_str(gconstpointer a, gconstpointer b)
{
  return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Every Area/Location zone: day_end(t) equals the brute-force answer around every transition of
 * 2026-2027 (and of 2007 for the zones that changed then). WX_TEST_QUICK=1 samples one zone in 16
 * (for valgrind and the sanitizers, which are ~30x slower). */
static void
test_local_day_end_all_zones(void)
{
  g_autoptr(GPtrArray) zones = g_ptr_array_new_with_free_func(g_free);
  collect_zones("/usr/share/zoneinfo", "", zones);
  if (zones->len < 100) {
    g_test_skip("no zoneinfo database");
    return;
  }
  g_ptr_array_sort(zones, cmp_str);
  guint stride = g_getenv("WX_TEST_QUICK") != NULL ? 16 : 1;
  gint64 offs[24];
  guint n_offs = 0;
  for (int h = -30; h <= 30; h += 6) /* the day before .. the day after, in 6-hour steps */
    offs[n_offs++] = h * 3600;
  offs[n_offs++] = -1;
  offs[n_offs++] = 1;
  offs[n_offs++] = -3600;
  offs[n_offs++] = 3600;
  offs[n_offs++] = -13 * 3600;
  offs[n_offs++] = 13 * 3600;
  guint checked = 0, transitions = 0;
  for (guint zi = 0; zi < zones->len; zi += stride) {
    const char *name = zones->pdata[zi];
    g_autoptr(GTimeZone) z = g_time_zone_new_identifier(name);
    if (z == NULL)
      continue;
    /* 2026-27, 2007, and the skipped date of Pacific/Apia and Tokelau (2011-12-30) */
    static const gint64 spans[][2] = { { 1767225600, 1830297600 }, { 1167609600, 1199145600 },
                                       { 1322697600, 1328054400 } };
    for (guint sp = 0; sp < G_N_ELEMENTS(spans); sp++) {
      gint prev = g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, spans[sp][0]);
      for (gint64 c = spans[sp][0] + 3600; c < spans[sp][1]; c += 3600) {
        gint iv = g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, c);
        if (iv == prev)
          continue;
        prev = iv;
        gint64 lo = c - 3600, hi = c; /* bisect the transition to the second */
        while (hi - lo > 1) {
          gint64 mid = lo + (hi - lo) / 2;
          if (g_time_zone_find_interval(z, G_TIME_TYPE_UNIVERSAL, mid) == iv)
            hi = mid;
          else
            lo = mid;
        }
        transitions++;
        for (guint k = 0; k < n_offs; k++) {
          gint64 t = hi + offs[k];
          gint64 want = brute_day_end(z, t);
          gint64 got = wx_format_local_day_end(t, name);
          if (got != want)
            g_test_message("zone %s t=%" G_GINT64_FORMAT " (transition %" G_GINT64_FORMAT "): got %" G_GINT64_FORMAT
                           " want %" G_GINT64_FORMAT, name, t, hi, got, want);
          g_assert_cmpint(got, ==, want);
          checked++;
        }
      }
    }
  }
  g_test_message("checked %u instants around %u transitions in %u zones", checked, transitions, zones->len);
  g_assert_cmpuint(checked, >, 0);
}

static void
test_weekday(void)
{
  gint64 now = ts(2026, 10, 11, 12, 0, 0); /* Sunday 8 AM in New York */
  ASSERT_STR(wx_format_weekday(now, NY, now), "Today");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 12, 3, 59, 59), NY, now), "Today");     /* 23:59:59 local */
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 12, 4, 0, 0), NY, now), "Tomorrow");    /* local midnight */
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 13, 3, 59, 59), NY, now), "Tomorrow");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 13, 4, 0, 0), NY, now), "Tuesday");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 17, 12, 0, 0), NY, now), "Saturday");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 18, 12, 0, 0), NY, now), "Sunday");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 10, 12, 0, 0), NY, now), "Saturday"); /* yesterday */
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 9, 12, 0, 0), NY, now), "Friday");
  /* the zone, not UTC, decides */
  gint64 late = ts(2026, 10, 12, 2, 0, 0); /* Oct 11 22:00 in New York */
  gint64 next = ts(2026, 10, 12, 5, 0, 0); /* Oct 12 01:00 in New York */
  ASSERT_STR(wx_format_weekday(next, NY, late), "Tomorrow");
  ASSERT_STR(wx_format_weekday(next, "UTC", late), "Today");
  ASSERT_STR(wx_format_weekday(next, NULL, late), "Today");
  /* month, year and leap-day boundaries */
  ASSERT_STR(wx_format_weekday(ts(2027, 1, 1, 12, 0, 0), "UTC", ts(2026, 12, 31, 12, 0, 0)), "Tomorrow");
  ASSERT_STR(wx_format_weekday(ts(2026, 11, 1, 12, 0, 0), "UTC", ts(2026, 10, 31, 23, 0, 0)), "Tomorrow");
  ASSERT_STR(wx_format_weekday(ts(2028, 2, 29, 12, 0, 0), "UTC", ts(2028, 2, 28, 12, 0, 0)), "Tomorrow");
  ASSERT_STR(wx_format_weekday(ts(2028, 3, 1, 12, 0, 0), "UTC", ts(2028, 2, 28, 12, 0, 0)), "Wednesday");
  ASSERT_STR(wx_format_weekday(ts(2027, 3, 1, 12, 0, 0), "UTC", ts(2027, 2, 28, 12, 0, 0)), "Tomorrow");
  /* every weekday name */
  const char *days[] = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
  for (int i = 0; i < 7; i++)
    ASSERT_STR(wx_format_weekday(ts(2026, 10, 12 + i, 12, 0, 0), "UTC", 0), days[i]);
  /* bad now: weekday names only; bad t: dash */
  ASSERT_STR(wx_format_weekday(now, NY, 0), "Sunday");
  ASSERT_STR(wx_format_weekday(now, NY, WX_TIME_MAX_S), "Sunday");
  ASSERT_STR(wx_format_weekday(now, NY, G_MININT64), "Sunday");
  ASSERT_STR(wx_format_weekday(0, NY, now), DASH);
  ASSERT_STR(wx_format_weekday(WX_TIME_MAX_S, NY, now), DASH);
  ASSERT_STR(wx_format_weekday(G_MAXINT64, NY, now), DASH);
}

static void
test_updated(void)
{
  struct {
    gint64 age;
    const char *text;
  } t[] = {
    { G_MININT64, "Updated just now" },
    { -1, "Updated just now" },
    { 0, "Updated just now" },
    { 59, "Updated just now" },
    { 60, "Updated 1 min ago" },
    { 119, "Updated 1 min ago" },
    { 5 * 60, "Updated 5 min ago" },
    { 3599, "Updated 59 min ago" },
    { 3600, "Updated 1 h ago" },
    { 2 * 3600 + 59, "Updated 2 h ago" },
    { 86399, "Updated 23 h ago" },
    { 86400, "Updated 1 day ago" },
    { 2 * 86400, "Updated 2 days ago" },
    { 29 * 86400 + 86399, "Updated 29 days ago" },
    { 30 * 86400, "Updated over a month ago" },
    { G_MAXINT64, "Updated over a month ago" },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++)
    ASSERT_STR(wx_format_updated(t[i].age), t[i].text);
}

/* ------------------------------------------------------------------------ */
/* rain headline / detail                                                   */
/* ------------------------------------------------------------------------ */

#define NOW_S ts(2026, 10, 11, 18, 0, 0) /* 2 PM EDT, a Sunday */

static WxRainOutlook
outlook(WxRainState state, gint64 start, gint64 end, gboolean known, gint64 peak, double mm,
        double prob)
{
  return (WxRainOutlook){ .state = state, .start_s = start, .end_s = end, .ends_known = known,
                          .peak_s = peak, .peak_mm_h = mm, .peak_prob = prob };
}

static void
test_headline_dry(void)
{
  WxRainOutlook o = outlook(WX_RAIN_DRY, 0, 0, FALSE, 0, NAN, NAN);
  ASSERT_STR(wx_rain_headline(&o, NOW_S, NY), "No rain expected for the next 48 hours");
  ASSERT_STR(wx_rain_headline(&o, 0, NY), "No rain expected for the next 48 hours");
  ASSERT_STR(wx_rain_headline(&o, G_MAXINT64, NULL), "No rain expected for the next 48 hours");
}

static void
test_headline_now(void)
{
  gint64 now = NOW_S;
  WxRainOutlook o = outlook(WX_RAIN_NOW, now - 600, now + 90 * 60, TRUE, now, 1, 80);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing around 3:30 PM");
  ASSERT_STR(wx_rain_headline(&o, now, "UTC"), "Raining now, easing around 7:30 PM");
  ASSERT_STR(wx_rain_headline(&o, now, NULL), "Raining now, easing around 7:30 PM");
  o.end_s = now + 2 * 3600;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing around 4 PM");
  o.end_s = now + 1;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing around 2 PM");
  o.end_s = ts(2026, 10, 12, 7, 0, 0); /* 3 AM next local day */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing tomorrow around 3 AM");
  o.end_s = ts(2026, 10, 13, 20, 0, 0);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing Tuesday around 4 PM");
  o.end_s = ts(2026, 10, 12, 3, 59, 0); /* 11:59 PM today in New York */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing around 11:59 PM");
  ASSERT_STR(wx_rain_headline(&o, now, "UTC"), "Raining now, easing tomorrow around 3:59 AM");

  o.ends_known = FALSE;
  o.end_s = 0;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, expected to continue for hours");
  o.end_s = now + 3600; /* ignored while the end is not known */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, expected to continue for hours");

  o.ends_known = TRUE;
  o.end_s = now; /* not after now */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing soon");
  o.end_s = now - 5000;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now, easing soon");
  o.end_s = 0; /* known but not a time */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now");
  o.end_s = G_MAXINT64;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now");
  o.end_s = WX_TIME_MAX_S;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Raining now");

  o.end_s = now + 3600;
  ASSERT_STR(wx_rain_headline(&o, 0, NY), "Rain outlook unavailable");
  ASSERT_STR(wx_rain_headline(&o, WX_TIME_MAX_S, NY), "Rain outlook unavailable");
  ASSERT_STR(wx_rain_headline(&o, WX_TIME_MIN_S - 1, NY), "Rain outlook unavailable");
}

static void
test_headline_expected(void)
{
  gint64 now = NOW_S;
  WxRainOutlook o = outlook(WX_RAIN_EXPECTED, now + 25 * 60, now + 3 * 3600, TRUE, now + 3600, 2, 70);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting in 25 minutes");
  gint64 secs[] = { 1, 59, 60 };
  const char *want[] = { "Rain starting in 1 minute", "Rain starting in 1 minute",
                         "Rain starting in 1 minute" };
  for (guint i = 0; i < G_N_ELEMENTS(secs); i++) {
    o.start_s = now + secs[i];
    ASSERT_STR(wx_rain_headline(&o, now, NY), want[i]);
  }
  o.start_s = now + 61;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting in 2 minutes");
  o.start_s = now + 89 * 60;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting in 89 minutes");
  o.start_s = now + 90 * 60 - 1;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting in 90 minutes");
  o.start_s = now + 90 * 60; /* the boundary: the clock-time form begins */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected around 3:30 PM");
  o.start_s = now + 2 * 3600;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected around 4 PM");
  ASSERT_STR(wx_rain_headline(&o, now, "UTC"), "Rain expected around 8 PM");
  o.start_s = ts(2026, 10, 12, 20, 0, 0);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected tomorrow around 4 PM");
  o.start_s = ts(2026, 10, 13, 20, 0, 0);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected Tuesday around 4 PM");

  o.start_s = now; /* not in the future */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting now");
  o.start_s = now - 3600;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain starting now");
  o.start_s = 0;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected in the next 48 hours");
  o.start_s = G_MAXINT64;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected in the next 48 hours");
  o.start_s = WX_TIME_MAX_S;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Rain expected in the next 48 hours");
  o.start_s = now + 3600;
  ASSERT_STR(wx_rain_headline(&o, 0, NY), "Rain outlook unavailable");
  ASSERT_STR(wx_rain_headline(&o, G_MININT64, NY), "Rain outlook unavailable");
}

static void
test_headline_possible(void)
{
  gint64 now = NOW_S;
  WxRainOutlook o = outlook(WX_RAIN_POSSIBLE, 0, 0, FALSE, now + 2 * 3600, NAN, 40);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM (40% chance)");
  o.peak_prob = 39.6;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM (40% chance)");
  o.peak_prob = 100;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM (100% chance)");
  o.peak_prob = NAN;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM");
  o.peak_prob = 100.5;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM");
  o.peak_prob = -1;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM");
  o.peak_prob = INFINITY;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible around 4 PM");
  o.peak_prob = 55;
  o.peak_s = ts(2026, 10, 12, 20, 30, 0);
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible tomorrow around 4:30 PM (55% chance)");
  o.peak_s = now; /* the current hour */
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible now (55% chance)");
  o.peak_s = now - 1800;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible now (55% chance)");
  o.peak_s = 0;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible in the next 48 hours (55% chance)");
  o.peak_s = G_MININT64;
  o.peak_prob = NAN;
  ASSERT_STR(wx_rain_headline(&o, now, NY), "Showers possible in the next 48 hours");
  o.peak_s = now + 3600;
  ASSERT_STR(wx_rain_headline(&o, WX_TIME_MAX_S, NY), "Rain outlook unavailable");
}

static void
test_headline_programmer_errors(void)
{
  WxRainOutlook o = outlook(WX_RAIN_DRY, 0, 0, FALSE, 0, NAN, NAN);
  ASSERT_CRITICAL("wx_rain_headline", g_assert_null(wx_rain_headline(NULL, NOW_S, NY)));
  ASSERT_CRITICAL("wx_rain_detail", g_assert_null(wx_rain_detail(NULL, NOW_S, NY)));
  o.state = (WxRainState)4;
  ASSERT_CRITICAL("wx_rain_headline", g_assert_null(wx_rain_headline(&o, NOW_S, NY)));
  ASSERT_CRITICAL("wx_rain_detail", g_assert_null(wx_rain_detail(&o, NOW_S, NY)));
  o.state = (WxRainState)-1;
  ASSERT_CRITICAL("wx_rain_headline", g_assert_null(wx_rain_headline(&o, NOW_S, NY)));
  ASSERT_CRITICAL("wx_rain_detail", g_assert_null(wx_rain_detail(&o, NOW_S, NY)));
  ASSERT_CRITICAL("wx_cloud_sentence", g_assert_null(wx_cloud_sentence(NULL, NOW_S, NY)));
}

static void
test_detail(void)
{
  gint64 now = NOW_S; /* 2:00 PM in New York */
  WxRainOutlook o = outlook(WX_RAIN_EXPECTED, now + 600, now + 3 * 3600, TRUE, now + 3600, 1.0, 60);
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Light rain, heaviest around 3 PM. 60% chance of rain.");
  ASSERT_STR(wx_rain_detail(&o, now, "UTC"), "Light rain, heaviest around 7 PM. 60% chance of rain.");
  /* a rain that is already falling carries no chance sentence */
  o.state = WX_RAIN_NOW;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Light rain, heaviest around 3 PM.");
  o.state = WX_RAIN_EXPECTED;
  double mm[] = { 0.0, 0.49, 0.5, 2.49, 2.5, 7.59, 7.6, 500 };
  const char *word[] = { "Very light", "Very light", "Light", "Light", "Moderate", "Moderate", "Heavy", "Heavy" };
  const char *lower[] = { "very light", "very light", "light", "light", "moderate", "moderate", "heavy", "heavy" };
  for (guint i = 0; i < G_N_ELEMENTS(mm); i++) {
    o.peak_mm_h = mm[i];
    g_autofree char *want = g_strdup_printf("%s rain, heaviest around 3 PM. 60%% chance of rain.", word[i]);
    ASSERT_STR(wx_rain_detail(&o, now, NY), want);
    o.peak_s = now - 3600; /* the same peak, one hour ago */
    g_autofree char *past = g_strdup_printf("Rain peaked around 1 PM (%s). 60%% chance of rain.", lower[i]);
    ASSERT_STR(wx_rain_detail(&o, now, NY), past);
    o.peak_s = now + 3600;
  }
  o.peak_mm_h = 3;
  /* the boundary: a peak sample that is not after now is never "right now" nor a current rate */
  o.peak_s = now + 1;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Moderate rain, heaviest around 2 PM. 60% chance of rain.");
  o.peak_s = now;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Rain peaked around 2 PM (moderate). 60% chance of rain.");
  o.peak_s = now - 1;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Rain peaked around 1:59 PM (moderate). 60% chance of rain.");
  o.peak_s = ts(2026, 10, 12, 20, 0, 0);
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Moderate rain, heaviest tomorrow around 4 PM. 60% chance of rain.");
  o.peak_s = ts(2026, 10, 10, 20, 30, 0); /* yesterday, 4:30 PM local */
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Rain peaked yesterday around 4:30 PM (moderate). 60% chance of rain.");
  o.peak_s = ts(2026, 10, 9, 20, 0, 0);
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Rain peaked Friday around 4 PM (moderate). 60% chance of rain.");
  o.peak_s = 0; /* no valid peak time: no time, no claim about now */
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Moderate rain at its heaviest. 60% chance of rain.");
  o.peak_s = now + 3600;
  o.peak_prob = NAN;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Moderate rain, heaviest around 3 PM.");
  o.peak_prob = 101;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "Moderate rain, heaviest around 3 PM.");
  o.peak_prob = 60;
  o.peak_mm_h = NAN;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "60% chance of rain.");
  o.peak_mm_h = -1;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "60% chance of rain.");
  o.peak_mm_h = INFINITY;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "60% chance of rain.");
  o.peak_prob = NAN;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "");
  o.state = WX_RAIN_NOW; /* NOW without a usable intensity: nothing to say */
  o.peak_prob = 60;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "");
  o.state = WX_RAIN_EXPECTED;
  o.peak_mm_h = 3;
  o.peak_prob = 60;
  ASSERT_STR(wx_rain_detail(&o, 0, NY), "");
  ASSERT_STR(wx_rain_detail(&o, WX_TIME_MAX_S, NY), "");

  o.state = WX_RAIN_POSSIBLE;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "No steady rain in the forecast, just a chance.");
  o.state = WX_RAIN_DRY;
  ASSERT_STR(wx_rain_detail(&o, now, NY), "");
}

/* Regression: the run's peak (8 mm/h at 17:00Z) is over at 18:10Z, when the hour is almost dry. The
 * outlook only knows the peak, so the text must describe it as past and never as current. */
static void
test_detail_past_peak(void)
{
  gint64 peak = ts(2026, 10, 11, 17, 0, 0);
  gint64 now = ts(2026, 10, 11, 18, 10, 0);
  WxRainOutlook o = outlook(WX_RAIN_NOW, peak - 3600, now + 3600, TRUE, peak, 8.0, 90);
  g_autofree char *d = wx_rain_detail(&o, now, NY);
  g_assert_cmpstr(d, ==, "Rain peaked around 1 PM (heavy).");
  g_assert_null(strstr(d, "right now"));
  g_assert_null(strstr(d, "heaviest"));
  g_assert_null(strstr(d, "chance"));
}

/* ------------------------------------------------------------------------ */
/* cloud sentence                                                           */
/* ------------------------------------------------------------------------ */

static WxBlendHour
cloud_hour(gint64 t_s, double cloud)
{
  return (WxBlendHour){ .t_s = t_s, .temp_c = NAN, .feels_c = NAN, .precip_mm = NAN,
                        .precip_mm_max = NAN, .precip_prob = NAN, .cloud_pct = cloud,
                        .wind_kmh = NAN, .gust_kmh = NAN, .humidity_pct = NAN,
                        .temp_spread_c = NAN, .n_members = 1, .condition = WX_COND_UNKNOWN,
                        .is_day = TRUE };
}

/* A forecast with @n hours from @t0, hour i having cloud cover cloud[i]. */
static WxForecast *
make_forecast(gint64 t0, const double *cloud, guint n)
{
  WxBlendHour hours[WX_FORECAST_MAX_HOURS];
  g_assert_cmpuint(n, <=, G_N_ELEMENTS(hours));
  for (guint i = 0; i < n; i++)
    hours[i] = cloud_hour(t0 + (gint64)i * 3600, cloud[i]);
  GError *err = NULL;
  g_autoptr(WxPlace) place =
      wx_place_new("Miami", "Florida", "United States", "US", 25.76, -80.19, NY, &err);
  g_assert_no_error(err);
  WxForecast *f = wx_forecast_new(place, NOW_S, hours, n, NULL, 0, NULL, 0, NULL, 0, &err);
  g_assert_no_error(err);
  g_assert_nonnull(f);
  return f;
}

static void
test_cloud_bands(void)
{
  gint64 t0 = ts(2026, 10, 11, 18, 0, 0);
  struct {
    double pct;
    const char *text;
  } t[] = {
    { 0, "Clear skies for the next hour" },
    { 12.49, "Clear skies for the next hour" },
    { 12.5, "Mostly clear skies for the next hour" },
    { 37.49, "Mostly clear skies for the next hour" },
    { 37.5, "Partly cloudy for the next hour" },
    { 62.49, "Partly cloudy for the next hour" },
    { 62.5, "Mostly cloudy for the next hour" },
    { 87.49, "Mostly cloudy for the next hour" },
    { 87.5, "Overcast for the next hour" },
    { 100, "Overcast for the next hour" },
    { NAN, "Cloud cover unknown" },
    { -1, "Cloud cover unknown" },
    { 100.01, "Cloud cover unknown" },
    { INFINITY, "Cloud cover unknown" },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    g_autoptr(WxForecast) f = make_forecast(t0, &t[i].pct, 1);
    ASSERT_STR(wx_cloud_sentence(f, t0 + 600, NY), t[i].text);
  }
}

static void
test_cloud_transitions(void)
{
  gint64 t0 = ts(2026, 10, 11, 18, 0, 0); /* 2 PM EDT */
  gint64 now = t0 + 1800;
  /* mostly cloudy until 9 PM local (01:00Z), then clear */
  double a[30];
  for (guint i = 0; i < 30; i++)
    a[i] = i < 7 ? 70 : 5;
  g_autoptr(WxForecast) f = make_forecast(t0, a, 30);
  ASSERT_STR(wx_cloud_sentence(f, now, NY), "Mostly cloudy now, clearing around 9 PM");
  /* the same instant is "tomorrow around 1 AM" in UTC */
  ASSERT_STR(wx_cloud_sentence(f, now, "UTC"), "Mostly cloudy now, clearing tomorrow around 1 AM");
}

static void
test_cloud_targets(void)
{
  gint64 t0 = ts(2026, 10, 11, 18, 0, 0);
  struct {
    double from, to;
    const char *text;
  } t[] = {
    { 50, 0, "Partly cloudy now, clearing around 4 PM" },
    { 50, 20, "Partly cloudy now, mostly clear around 4 PM" },
    { 20, 50, "Mostly clear now, partly cloudy around 4 PM" },
    { 50, 70, "Partly cloudy now, mostly cloudy around 4 PM" },
    { 50, 100, "Partly cloudy now, clouding over around 4 PM" },
    { 0, 100, "Clear now, clouding over around 4 PM" },
    { 100, 0, "Overcast now, clearing around 4 PM" },
  };
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    double c[6] = { t[i].from, t[i].from, t[i].to, t[i].to, t[i].to, t[i].to }; /* change at 20:00Z */
    g_autoptr(WxForecast) f = make_forecast(t0, c, 6);
    ASSERT_STR(wx_cloud_sentence(f, t0 + 60, NY), t[i].text);
  }
}

static void
test_cloud_days_and_lookahead(void)
{
  gint64 t0 = ts(2026, 10, 11, 18, 0, 0);
  double c[40];
  /* change 22 hours ahead = 12 PM next local day */
  for (guint i = 0; i < 40; i++)
    c[i] = i < 22 ? 90 : 10;
  g_autoptr(WxForecast) f = make_forecast(t0, c, 40);
  ASSERT_STR(wx_cloud_sentence(f, t0, NY), "Overcast now, clearing tomorrow around 12 PM");
  ASSERT_STR(wx_cloud_sentence(f, t0, "UTC"), "Overcast now, clearing tomorrow around 4 PM");

  /* a change exactly 24 h ahead is outside the look-ahead; one second earlier it is inside */
  for (guint i = 0; i < 40; i++)
    c[i] = i < 24 ? 90 : 10;
  g_autoptr(WxForecast) g = make_forecast(t0, c, 40);
  ASSERT_STR(wx_cloud_sentence(g, t0, NY), "Overcast for the next 24 hours");
  ASSERT_STR(wx_cloud_sentence(g, t0 + 1, NY), "Overcast now, clearing tomorrow around 2 PM");

  /* a change after local midnight is "tomorrow" (the look-ahead of 24 h never reaches a weekday word) */
  double d[3] = { 90, 90, 10 };
  g_autoptr(WxForecast) h = make_forecast(ts(2026, 10, 13, 2, 0, 0), d, 3); /* Sun 10 PM EDT */
  ASSERT_STR(wx_cloud_sentence(h, ts(2026, 10, 13, 2, 30, 0), NY), "Overcast now, clearing tomorrow around 12 AM");

  /* hours without a cloud value are skipped and do not end the steady stretch */
  double e[6] = { 20, NAN, 20, NAN, 20, 20 };
  g_autoptr(WxForecast) k = make_forecast(t0, e, 6);
  ASSERT_STR(wx_cloud_sentence(k, t0, NY), "Mostly clear skies for the next 6 hours");
  double e2[6] = { 20, 20, 20, NAN, NAN, NAN };
  g_autoptr(WxForecast) k2 = make_forecast(t0, e2, 6);
  ASSERT_STR(wx_cloud_sentence(k2, t0, NY), "Mostly clear skies for the next 3 hours");
  double e3[3] = { 20, 20, 90 };
  g_autoptr(WxForecast) k3 = make_forecast(t0, e3, 3);
  ASSERT_STR(wx_cloud_sentence(k3, t0, NY), "Mostly clear now, clouding over around 4 PM");

  /* steady for 24 h */
  double s24[24] = { 0 };
  g_autoptr(WxForecast) m = make_forecast(t0, s24, 24);
  ASSERT_STR(wx_cloud_sentence(m, t0, NY), "Clear skies for the next 24 hours");
  ASSERT_STR(wx_cloud_sentence(m, t0 + 3599, NY), "Clear skies for the next 23 hours"); /* data ends 24 h after t0 */
}

static void
test_cloud_unknown(void)
{
  gint64 t0 = ts(2026, 10, 11, 18, 0, 0);
  double c[4] = { 10, 10, NAN, 10 };
  g_autoptr(WxForecast) f = make_forecast(t0, c, 4);
  ASSERT_STR(wx_cloud_sentence(f, t0 - 1, NY), "Cloud cover unknown");        /* before the first hour */
  ASSERT_STR(wx_cloud_sentence(f, t0 + 4 * 3600, NY), "Cloud cover unknown"); /* after the last hour */
  /* a NaN hour whose next hour has a value: that value is the cloud cover of now
   * (wx_forecast_now() uses the one finite value), so the sky is known */
  ASSERT_STR(wx_cloud_sentence(f, t0 + 2 * 3600 + 5, NY), "Clear skies for the next hour");
  /* a NaN hour followed by a NaN hour (or by the end of the forecast): unknown */
  double c2[4] = { 10, 10, NAN, NAN };
  g_autoptr(WxForecast) f2 = make_forecast(t0, c2, 4);
  ASSERT_STR(wx_cloud_sentence(f2, t0 + 2 * 3600 + 5, NY), "Cloud cover unknown");
  ASSERT_STR(wx_cloud_sentence(f2, t0 + 3 * 3600 + 5, NY), "Cloud cover unknown");
  ASSERT_STR(wx_cloud_sentence(f, 0, NY), "Cloud cover unknown");
  ASSERT_STR(wx_cloud_sentence(f, WX_TIME_MAX_S, NY), "Cloud cover unknown");
  ASSERT_STR(wx_cloud_sentence(f, G_MININT64, NY), "Cloud cover unknown");
  g_autoptr(WxForecast) none = make_forecast(t0, c, 0);
  ASSERT_STR(wx_cloud_sentence(none, t0, NY), "Cloud cover unknown");

  /* a hand-built forecast whose later hour is not a valid time falls back to "later" */
  WxBlendHour hs[2] = { cloud_hour(WX_TIME_MAX_S - 3600, 70), cloud_hour(WX_TIME_MAX_S, 10) };
  WxForecast raw = { .hours = hs, .n_hours = 2 };
  ASSERT_STR(wx_cloud_sentence(&raw, WX_TIME_MAX_S - 3599, NY), "Mostly cloudy now, clearing later");
}

/* ------------------------------------------------------------------------ */
/* icons                                                                    */
/* ------------------------------------------------------------------------ */

static void
test_icons(void)
{
  struct {
    WxCondition c;
    const char *day, *night;
  } t[] = {
    { WX_COND_UNKNOWN, "dialog-question-symbolic", "dialog-question-symbolic" },
    { WX_COND_CLEAR, "weather-clear-symbolic", "weather-clear-night-symbolic" },
    { WX_COND_MOSTLY_CLEAR, "weather-few-clouds-symbolic", "weather-few-clouds-night-symbolic" },
    { WX_COND_PARTLY_CLOUDY, "weather-few-clouds-symbolic", "weather-few-clouds-night-symbolic" },
    { WX_COND_MOSTLY_CLOUDY, "weather-overcast-symbolic", "weather-overcast-symbolic" },
    { WX_COND_OVERCAST, "weather-overcast-symbolic", "weather-overcast-symbolic" },
    { WX_COND_FOG, "weather-fog-symbolic", "weather-fog-symbolic" },
    { WX_COND_DRIZZLE, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic" },
    { WX_COND_LIGHT_RAIN, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic" },
    { WX_COND_RAIN, "weather-showers-symbolic", "weather-showers-symbolic" },
    { WX_COND_HEAVY_RAIN, "weather-showers-symbolic", "weather-showers-symbolic" },
    { WX_COND_SHOWERS, "weather-showers-scattered-symbolic", "weather-showers-scattered-symbolic" },
    { WX_COND_THUNDERSTORM, "weather-storm-symbolic", "weather-storm-symbolic" },
    { WX_COND_SNOW, "weather-snow-symbolic", "weather-snow-symbolic" },
    { WX_COND_SLEET, "weather-snow-symbolic", "weather-snow-symbolic" },
    { WX_COND_COUNT, "dialog-question-symbolic", "dialog-question-symbolic" },
    { (WxCondition)-1, "dialog-question-symbolic", "dialog-question-symbolic" },
    { (WxCondition)9999, "dialog-question-symbolic", "dialog-question-symbolic" },
  };
  g_assert_cmpuint(G_N_ELEMENTS(t) - 3, ==, (guint)WX_COND_COUNT); /* every condition + 3 invalid values */
  for (guint i = 0; i < G_N_ELEMENTS(t); i++) {
    const char *d = wx_icon_name(t[i].c, TRUE);
    const char *n = wx_icon_name(t[i].c, FALSE);
    g_assert_nonnull(d);
    g_assert_nonnull(n);
    g_assert_cmpstr(d, ==, t[i].day);
    g_assert_cmpstr(n, ==, t[i].night);
    g_assert_true(g_str_has_suffix(d, "-symbolic"));
    g_assert_true(g_str_has_suffix(n, "-symbolic"));
  }
}

/* ------------------------------------------------------------------------ */
/* fuzz: totality, valid UTF-8, never NULL                                  */
/* ------------------------------------------------------------------------ */

static double
rand_double(GRand *r)
{
  switch (g_rand_int_range(r, 0, 8)) {
  case 0:
    return NAN;
  case 1:
    return g_rand_boolean(r) ? INFINITY : -INFINITY;
  case 2:
    return g_rand_double_range(r, -150, 150);
  case 3:
    return g_rand_double_range(r, -1e300, 1e300);
  case 4:
    return g_rand_int_range(r, -2, 1002) / 10.0;
  case 5:
    return g_rand_double_range(r, 0, 13000);
  case 6:
    return (double)g_rand_int_range(r, -3, 3) * 0.5;
  default:
    return g_rand_double_range(r, -1, 101);
  }
}

static gint64
rand_time(GRand *r)
{
  switch (g_rand_int_range(r, 0, 6)) {
  case 0:
    return (gint64)(((guint64)g_rand_int(r) << 32) | g_rand_int(r));
  case 1:
    return g_rand_boolean(r) ? G_MAXINT64 : G_MININT64;
  case 2:
    return WX_TIME_MIN_S + g_rand_int_range(r, -3, 3);
  case 3:
    return WX_TIME_MAX_S + g_rand_int_range(r, -3, 3);
  default:
    return WX_TIME_MIN_S + (gint64)g_rand_int(r) % (WX_TIME_MAX_S - WX_TIME_MIN_S);
  }
}

/* a + b with wrap-around (the fuzzer deliberately goes beyond the int64 range). */
static gint64
add_wrap(gint64 a, gint64 b)
{
  return (gint64)((guint64)a + (guint64)b);
}

static const char *
rand_tz(GRand *r, char *buf, gsize cap)
{
  static const char *const pool[] = { NULL, "", "UTC", NY, "Australia/Sydney", "Asia/Kolkata",
                                      "/etc/passwd", "../..", "a//b", "Nowhere/Land" };
  int k = g_rand_int_range(r, 0, 12);
  if (k < 10)
    return pool[k];
  gsize len = (gsize)g_rand_int_range(r, 0, (int)cap - 1);
  for (gsize i = 0; i < len; i++)
    buf[i] = (char)g_rand_int_range(r, 1, 256);
  buf[len] = '\0';
  return buf;
}

static void
assert_text(char *s)
{
  g_assert_nonnull(s);
  g_assert_true(g_utf8_validate(s, -1, NULL));
  g_free(s);
}

static void
test_fuzz(void)
{
  GRand *r = g_rand_new_with_seed(20261011);
  char tzbuf[100];
  WxBlendHour hours[3];
  for (int it = 0; it < 60000; it++) {
    WxUnits u = g_rand_boolean(r) ? WX_UNITS_IMPERIAL : WX_UNITS_METRIC;
    double v = rand_double(r);
    gint64 t = rand_time(r), now = rand_time(r);
    const char *tz = rand_tz(r, tzbuf, sizeof tzbuf);
    assert_text(wx_format_temp(v, u, g_rand_boolean(r)));
    assert_text(wx_format_wind(v, u));
    assert_text(wx_format_precip(v, u));
    assert_text(wx_format_percent(v));
    assert_text(wx_format_hour_label(t, tz));
    assert_text(wx_format_clock(t, tz));
    assert_text(wx_format_weekday(t, tz, now));
    assert_text(wx_format_updated(t));
    gint64 end = wx_format_local_day_end(t, tz);
    g_assert_true(end == 0 ? !(t >= WX_TIME_MIN_S && t < WX_TIME_MAX_S) : end > t);
    WxRainOutlook o = outlook((WxRainState)g_rand_int_range(r, 0, 4), rand_time(r), rand_time(r),
                              g_rand_boolean(r), rand_time(r), rand_double(r), rand_double(r));
    if (g_rand_boolean(r)) /* mostly plausible times so the time branches are reached */
      o.start_s = add_wrap(now, g_rand_int_range(r, -4000, 200000));
    if (g_rand_boolean(r))
      o.end_s = add_wrap(now, g_rand_int_range(r, -4000, 200000));
    if (g_rand_boolean(r))
      o.peak_s = add_wrap(now, g_rand_int_range(r, -4000, 200000));
    if (g_rand_boolean(r))
      now = WX_TIME_MIN_S + g_rand_int_range(r, 0, 100000000);
    assert_text(wx_rain_headline(&o, now, tz));
    assert_text(wx_rain_detail(&o, now, tz));
    for (guint i = 0; i < 3; i++)
      hours[i] = cloud_hour((gint64)((guint64)(now - now % 3600) + (guint64)i * 3600 - 3600), rand_double(r));
    WxForecast fc = { .hours = hours, .n_hours = (guint)g_rand_int_range(r, 0, 4) };
    assert_text(wx_cloud_sentence(&fc, now, tz));
    assert_text(wx_cloud_sentence(&fc, hours[1].t_s + 1, tz));
  }
  g_rand_free(r);
}

/* ------------------------------------------------------------------------ */
/* time-zone / environment independence                                     */
/* ------------------------------------------------------------------------ */

static void
test_process_tz_independent(void)
{
  g_setenv("TZ", "Asia/Tokyo", TRUE);
  tzset();
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), NY), "3 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), NULL), "7 PM");
  ASSERT_STR(wx_format_weekday(ts(2026, 10, 11, 23, 0, 0), NULL, ts(2026, 10, 11, 1, 0, 0)), "Today");
  g_setenv("TZ", "Pacific/Auckland", TRUE);
  tzset();
  ASSERT_STR(wx_format_clock(ts(2026, 10, 11, 19, 45, 0), "UTC"), "7:45 PM");
  g_unsetenv("TZ");
  tzset();
}

/* The formatters are documented as callable from any thread. 12 zones (more than the 8 the cache holds,
 * so the ring keeps evicting), unknown and ill-shaped names, and the day-end function. */
static gpointer
thread_main(gpointer data)
{
  (void)data;
  static const struct {
    const char *tz;
    const char *label;
  } z[] = { { NY, "3 PM" }, { "Australia/Sydney", "6 AM" }, { "Asia/Kolkata", "12:30 AM" },
            { "Europe/London", "8 PM" }, { "Asia/Tokyo", "4 AM" }, { "America/Chicago", "2 PM" },
            { "Africa/Cairo", "10 PM" }, { "Pacific/Auckland", "8 AM" }, { "America/Sao_Paulo", "4 PM" },
            { "Asia/Dubai", "11 PM" }, { "Europe/Moscow", "10 PM" }, { "Pacific/Honolulu", "9 AM" },
            { "Mars/Olympus", "7 PM" }, { "Japan", "7 PM" }, { NULL, "7 PM" } }; /* 19:00Z on 2026-10-11 */
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  for (int i = 0; i < 2000; i++) {
    guint k = (guint)i % G_N_ELEMENTS(z);
    char *s = wx_format_hour_label(t, z[k].tz);
    g_assert_cmpstr(s, ==, z[k].label);
    g_free(s);
    s = wx_format_clock(t, z[k].tz);
    g_assert_nonnull(s);
    g_free(s);
    g_assert_cmpint(wx_format_local_day_end(t, z[k].tz), >, t);
    s = wx_format_temp(i % 100, WX_UNITS_IMPERIAL, TRUE);
    g_assert_nonnull(s);
    g_free(s);
  }
  return NULL;
}

static void
test_threads(void)
{
  GThread *threads[24];
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    threads[i] = g_thread_new("fmt", thread_main, NULL);
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    g_thread_join(threads[i]);
}

/* ------------------------------------------------------------------------ */
/* zone loading with a simulated loader                                     */
/* ------------------------------------------------------------------------ */

static gint64 fake_now_us;
static gboolean fake_fail;
static guint fake_calls;

static gint64
fake_clock(void)
{
  return fake_now_us;
}

static GTimeZone *
fake_loader(const char *name)
{
  fake_calls++;
  return fake_fail ? NULL : g_time_zone_new_identifier(name);
}

/* A transient failure to load a valid zone (EMFILE) must not stick: UTC for at most 30 s, then retried. */
static void
test_zone_failure_heals(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  fake_now_us = 1000 * G_USEC_PER_SEC;
  fake_fail = TRUE;
  fake_calls = 0;
  wx_format_test_set_hooks(fake_loader, fake_clock);
  guint base = wx_format_zone_loads();

  ASSERT_STR(wx_format_hour_label(t, NY), "7 PM"); /* the failed load shows UTC ... */
  g_assert_cmpuint(fake_calls, ==, 1);
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 1);
  for (int i = 0; i < 20; i++)
    ASSERT_STR(wx_format_clock(t, NY), "7:00 PM"); /* ... and is not retried at once */
  g_assert_cmpuint(fake_calls, ==, 1);

  fake_now_us += 29 * G_USEC_PER_SEC;
  ASSERT_STR(wx_format_hour_label(t, NY), "7 PM");
  g_assert_cmpuint(fake_calls, ==, 1);
  fake_now_us += 1 * G_USEC_PER_SEC + 1; /* just past 30 s: retried, still failing, remembered again */
  ASSERT_STR(wx_format_hour_label(t, NY), "7 PM");
  g_assert_cmpuint(fake_calls, ==, 2);
  ASSERT_STR(wx_format_hour_label(t, NY), "7 PM");
  g_assert_cmpuint(fake_calls, ==, 2);

  fake_fail = FALSE; /* the descriptor pressure is over */
  fake_now_us += 31 * G_USEC_PER_SEC;
  ASSERT_STR(wx_format_hour_label(t, NY), "3 PM"); /* healed: the real zone */
  g_assert_cmpuint(fake_calls, ==, 3);
  fake_fail = TRUE; /* a known zone is never loaded again, a failure cannot take it away */
  fake_now_us += 100 * G_USEC_PER_SEC;
  for (int i = 0; i < 20; i++)
    ASSERT_STR(wx_format_hour_label(t, NY), "3 PM");
  g_assert_cmpuint(fake_calls, ==, 3);

  /* the failure memory holds 4 names: the fifth evicts the oldest */
  const char *names[] = { "Fail/A", "Fail/B", "Fail/C", "Fail/D", "Fail/E" };
  fake_calls = 0;
  for (guint i = 0; i < G_N_ELEMENTS(names); i++)
    ASSERT_STR(wx_format_hour_label(t, names[i]), "7 PM");
  g_assert_cmpuint(fake_calls, ==, 5);
  for (guint i = 1; i < G_N_ELEMENTS(names); i++) /* B..E are remembered */
    ASSERT_STR(wx_format_hour_label(t, names[i]), "7 PM");
  g_assert_cmpuint(fake_calls, ==, 5);
  ASSERT_STR(wx_format_hour_label(t, names[0]), "7 PM"); /* A was forgotten */
  g_assert_cmpuint(fake_calls, ==, 6);

  wx_format_test_set_hooks(NULL, NULL); /* restores the real loader and drops the fake zones */
  ASSERT_STR(wx_format_hour_label(t, NY), "3 PM");
}

typedef struct {
  GMutex lock;
  GCond cond;
  guint entered;   /* loads of "Slow/Zone" that have started */
  gboolean release;
  gboolean done;   /* the cached-zone thread finished */
} Latch;

static Latch latch;

static GTimeZone *
slow_loader(const char *name)
{
  if (strcmp(name, "Slow/Zone") != 0)
    return g_time_zone_new_identifier(name);
  g_mutex_lock(&latch.lock);
  latch.entered++;
  g_cond_broadcast(&latch.cond);
  gint64 deadline = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
  while (!latch.release && g_cond_wait_until(&latch.cond, &latch.lock, deadline))
    ;
  g_mutex_unlock(&latch.lock);
  return g_time_zone_new_identifier(NY);
}

static gpointer
slow_user(gpointer data)
{
  (void)data;
  char *s = wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Slow/Zone");
  g_assert_cmpstr(s, ==, "3 PM");
  g_free(s);
  return NULL;
}

static gpointer
cached_user(gpointer data)
{
  (void)data;
  for (int i = 0; i < 2000; i++) {
    char *s = wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Africa/Nairobi");
    g_assert_cmpstr(s, ==, "10 PM");
    g_free(s);
  }
  g_mutex_lock(&latch.lock);
  latch.done = TRUE;
  g_cond_broadcast(&latch.cond);
  g_mutex_unlock(&latch.lock);
  return NULL;
}

/* A zone file that loads slowly must not stall threads that use cached zones: the lock is not held
 * during the load. Two threads load the same slow zone at once; one result is kept. */
/* A valid zone must not turn into UTC for up to 30 s because a failure was recorded for it while its own
 * load was running (another thread, a transient error) and it is looked up again after being evicted.
 * Deterministic: the loader of the outer call, which will succeed, first makes a nested call for the
 * same name; that one fails and records the failure. */
static int nest_state; /* 0 = outer load not started, 1 = nested load running, 2 = done */

static GTimeZone *
nesting_loader(const char *name)
{
  if (strcmp(name, NY) == 0 && nest_state == 0) {
    nest_state = 1;
    g_free(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), NY)); /* re-enters: fails below */
    nest_state = 2;
  } else if (strcmp(name, NY) == 0 && nest_state == 1) {
    return NULL;
  }
  return g_time_zone_new_identifier(name);
}

static void
test_zone_failure_forgotten_on_success(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  fake_now_us = 1000 * G_USEC_PER_SEC;
  nest_state = 0;
  wx_format_test_set_hooks(nesting_loader, fake_clock);
  guint base = wx_format_zone_loads();
  ASSERT_STR(wx_format_hour_label(t, NY), "3 PM"); /* the outer load succeeded */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 2); /* the outer and the failing nested one */
  g_assert_cmpint(nest_state, ==, 2);
  for (int i = 1; i <= 8; i++) { /* New York leaves the 8 slots; no time passes on the fake clock */
    char name[16];
    g_snprintf(name, sizeof name, "Etc/GMT+%d", i);
    g_free(wx_format_hour_label(t, name));
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 10);
  /* a real load of the real zone, not UTC from the stale failure */
  ASSERT_STR(wx_format_hour_label(t, NY), "3 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 11);
  wx_format_test_set_hooks(NULL, NULL);
}

/* wx_format_zone_new() tells a FAILED lookup of a looked-up name from a real zone and from the
 * legitimate "not looked up" UTC cases. */
static void
test_zone_new_resolved_flag(void)
{
  fake_now_us = 1000 * G_USEC_PER_SEC;
  fake_fail = FALSE;
  fake_calls = 0;
  wx_format_test_set_hooks(fake_loader, fake_clock);
  gboolean ok = FALSE;
  /* a real zone */
  g_autoptr(GTimeZone) z = wx_format_zone_new(NY, &ok);
  g_assert_true(ok);
  ASSERT_STR(wx_format_hour_label_z(ts(2026, 10, 11, 19, 0, 0), z), "3 PM");
  /* UTC without a lookup: always resolved */
  const char *no_lookup[] = { NULL, "", "UTC", "Japan", "../x", "a//b", "/etc/passwd", "leapseconds", "utc" };
  for (guint i = 0; i < G_N_ELEMENTS(no_lookup); i++) {
    ok = FALSE;
    g_autoptr(GTimeZone) u = wx_format_zone_new(no_lookup[i], &ok);
    g_assert_true(ok);
    ASSERT_STR(wx_format_hour_label_z(ts(2026, 10, 11, 19, 0, 0), u), "7 PM");
  }
  g_assert_cmpuint(fake_calls, ==, 1); /* only New York was looked up */
  /* a failing lookup: not resolved, UTC fallback; remembered failure: still not resolved, no loader call */
  fake_fail = TRUE;
  for (int i = 0; i < 3; i++) {
    ok = TRUE;
    g_autoptr(GTimeZone) f = wx_format_zone_new("Asia/Kathmandu", &ok);
    g_assert_false(ok);
    ASSERT_STR(wx_format_hour_label_z(ts(2026, 10, 11, 19, 0, 0), f), "7 PM");
  }
  g_assert_cmpuint(fake_calls, ==, 2);
  /* after 30 s the lookup is tried again; it succeeds now */
  fake_fail = FALSE;
  fake_now_us += 31 * G_USEC_PER_SEC;
  g_autoptr(GTimeZone) healed = wx_format_zone_new("Asia/Kathmandu", &ok);
  g_assert_true(ok);
  ASSERT_STR(wx_format_hour_label_z(ts(2026, 10, 11, 19, 0, 0), healed), "12:45 AM");
  g_assert_cmpuint(fake_calls, ==, 3);
  /* the out parameter is optional */
  g_autoptr(GTimeZone) none = wx_format_zone_new("Asia/Kolkata", NULL);
  g_assert_nonnull(none);
  wx_format_test_set_hooks(NULL, NULL);
}

/* The failure memory has 4 slots. A new failure takes a free slot, then an expired one, then the oldest
 * live entry: a live entry is never lost while a free or expired slot exists. The repro of the review:
 * A..D fail, A re-fails, B loads (its slot is free), C and D re-fail, E fails: E must take B's free slot. */
static void
test_neg_ring_prefers_free_and_expired_slots(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  fake_fail = TRUE;
  fake_calls = 0;
  fake_now_us = 1000 * G_USEC_PER_SEC;
  wx_format_test_set_hooks(fake_loader, fake_clock);
  const char *a = "Aa/a", *b = "Africa/Nairobi", *c = "Cc/c", *d = "Dd/d", *e = "Ee/e";
  const gint64 S = G_USEC_PER_SEC;
  gint64 t0 = fake_now_us;
  const char *names[] = { a, b, c, d };
  for (int i = 0; i < 4; i++) { /* t0 + 0..3 s: four failures fill the ring */
    fake_now_us = t0 + i * S;
    g_free(wx_format_hour_label(t, names[i]));
  }
  g_assert_cmpuint(fake_calls, ==, 4);
  fake_now_us = t0 + 30 * S + S / 2; /* A (expired at 30 s) fails again; B..D expire at 31..33 s */
  g_free(wx_format_hour_label(t, a));
  g_assert_cmpuint(fake_calls, ==, 5);
  fake_fail = FALSE; /* B loads at 31.5 s: it was expired, now it is a real zone... */
  fake_now_us = t0 + 31 * S + S / 2;
  g_free(wx_format_hour_label(t, b)); /* a real zone: it loads */
  g_assert_cmpuint(fake_calls, ==, 6);
  fake_fail = TRUE;
  fake_now_us = t0 + 32 * S + S / 2; /* C expired at 32 s: it re-fails; D expires at 33 s: live now */
  g_free(wx_format_hour_label(t, c));
  g_assert_cmpuint(fake_calls, ==, 7);
  fake_now_us = t0 + 33 * S + S / 2; /* D expired at 33 s: it re-fails */
  g_free(wx_format_hour_label(t, d));
  g_assert_cmpuint(fake_calls, ==, 8);
  fake_now_us = t0 + 34 * S; /* E fails: live entries are A (until 60.5), C (62.5), D (63.5); slot 1 is free/expired */
  g_free(wx_format_hour_label(t, e));
  g_assert_cmpuint(fake_calls, ==, 9);
  fake_now_us = t0 + 35 * S; /* A's entry is live: no loader call */
  g_free(wx_format_hour_label(t, a));
  g_free(wx_format_hour_label(t, c));
  g_free(wx_format_hour_label(t, d));
  g_free(wx_format_hour_label(t, e));
  g_assert_cmpuint(fake_calls, ==, 9);
  wx_format_test_set_hooks(NULL, NULL);
}

/* Property test against a model: random lookups of 6 names that may fail or succeed, random clock steps.
 * The model keeps at most 4 live failures (the oldest is dropped for a fifth); the loader is called
 * exactly when the model says a name is neither cached (it loaded) nor a live failure. */
static GHashTable *model_succeeds; /* name -> TRUE when the loader succeeds for it now */

static GTimeZone *
model_loader(const char *name)
{
  fake_calls++;
  return GPOINTER_TO_INT(g_hash_table_lookup(model_succeeds, name)) ? g_time_zone_new_identifier(NY) : NULL;
}

typedef struct {
  const char *name;
  gint64 expires;
} ModelFail;

static void
test_neg_ring_model(void)
{
  const char *names[] = { "Mm/a", "Mm/b", "Mm/c", "Mm/d", "Mm/e", "Mm/f" };
  GRand *r = g_rand_new_with_seed(77);
  ModelFail live[4];
  guint n_live = 0;
  gboolean cached[6] = { FALSE };
  model_succeeds = g_hash_table_new(g_str_hash, g_str_equal);
  fake_now_us = 1000 * G_USEC_PER_SEC;
  wx_format_test_set_hooks(model_loader, fake_clock);
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  guint lookups = 0;
  for (int step = 0; step < 20000; step++) {
    switch (g_rand_int_range(r, 0, 4)) {
    case 0: /* the clock moves */
      fake_now_us += g_rand_int_range(r, 1, 40) * G_USEC_PER_SEC / 2;
      break;
    case 1: /* the loader's behaviour for a name changes */
      g_hash_table_insert(model_succeeds, (gpointer)names[g_rand_int_range(r, 0, 6)],
                          GINT_TO_POINTER(g_rand_int_range(r, 0, 3) == 0));
      break;
    default: {
      guint k = (guint)g_rand_int_range(r, 0, 6);
      fake_now_us += 1; /* every failure gets its own expiry time: "the oldest" is unambiguous */
      for (guint i = 0; i < n_live;) /* expired failures leave the model */
        if (live[i].expires <= fake_now_us)
          live[i] = live[--n_live];
        else
          i++;
      gboolean is_live = FALSE;
      for (guint i = 0; i < n_live; i++)
        is_live |= strcmp(live[i].name, names[k]) == 0;
      guint want_calls = cached[k] || is_live ? 0 : 1;
      guint before = fake_calls;
      char *label = wx_format_hour_label(t, names[k]);
      gboolean succeeded = GPOINTER_TO_INT(g_hash_table_lookup(model_succeeds, names[k]));
      if (want_calls == 1) {
        if (succeeded) {
          cached[k] = TRUE; /* 6 names fit the 8 positive slots: never evicted */
        } else if (n_live < 4) {
          live[n_live++] = (ModelFail){ names[k], fake_now_us + 30 * G_USEC_PER_SEC };
        } else { /* all four live: the oldest goes */
          guint oldest = 0;
          for (guint i = 1; i < 4; i++)
            if (live[i].expires < live[oldest].expires)
              oldest = i;
          live[oldest] = (ModelFail){ names[k], fake_now_us + 30 * G_USEC_PER_SEC };
        }
      }
      g_assert_cmpuint(fake_calls - before, ==, want_calls);
      /* a real zone gives New York time, everything else UTC */
      g_assert_cmpstr(label, ==, cached[k] ? "3 PM" : "7 PM");
      g_free(label);
      lookups++;
      break;
    }
    }
  }
  g_assert_cmpuint(lookups, >, 5000);
  g_hash_table_destroy(model_succeeds);
  g_rand_free(r);
  wx_format_test_set_hooks(NULL, NULL);
}

/* The cache is least-recently-USED: a zone that keeps being used survives one-off lookups. */
static void
test_zone_cache_is_lru(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  wx_format_test_set_hooks(NULL, NULL);
  guint base = wx_format_zone_loads();
  char name[16];
  for (int i = 1; i <= 8; i++) { /* fill the 8 slots: GMT+1 is the oldest, GMT+8 the newest */
    g_snprintf(name, sizeof name, "Etc/GMT+%d", i);
    g_free(wx_format_hour_label(t, name));
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 8);
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+1"), "6 PM"); /* a hit: GMT+1 is now the newest */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 8);
  g_free(wx_format_hour_label(t, "Etc/GMT+9")); /* a ninth zone: GMT+2, now the oldest, goes */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 9);
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+1"), "6 PM"); /* the used one stayed */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 9);
  g_free(wx_format_hour_label(t, "Etc/GMT+2")); /* the evicted one loads again */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 10);
  /* every kind of use refreshes, wx_format_zone_new() included: GMT+4 is the oldest now */
  g_autoptr(GTimeZone) z4 = wx_format_zone_new("Etc/GMT+4", NULL); /* a hit, GMT+4 is the newest */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 10);
  g_free(wx_format_hour_label(t, "Etc/GMT+10")); /* evicts the oldest, which is GMT+5 now */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 11);
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+4"), "3 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 11);
  ASSERT_STR(wx_format_hour_label(t, "Etc/GMT+5"), "2 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 12);
  wx_format_test_set_hooks(NULL, NULL);
}

/* The functions with a held zone: same answers as the string ones, no lookup, and independent of the
 * shared cache (a held zone survives its eviction). */
static void
test_zone_taking_functions(void)
{
  gint64 t = ts(2026, 10, 11, 19, 0, 0);
  wx_format_test_set_hooks(NULL, NULL);
  guint base = wx_format_zone_loads();
  g_autoptr(GTimeZone) kath = wx_format_zone_new("Asia/Kathmandu", NULL);
  g_autoptr(GTimeZone) utc_null = wx_format_zone_new(NULL, NULL);
  g_autoptr(GTimeZone) utc_bad = wx_format_zone_new("Japan", NULL);
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 1);
  for (int i = 1; i <= 9; i++) { /* push Kathmandu out of the cache */
    char name[16];
    g_snprintf(name, sizeof name, "Etc/GMT+%d", i);
    g_free(wx_format_hour_label(t, name));
  }
  guint loads = wx_format_zone_loads();
  ASSERT_STR(wx_format_hour_label_z(t, kath), "12:45 AM");
  ASSERT_STR(wx_format_clock_z(t, kath), "12:45 AM");
  ASSERT_STR(wx_format_weekday_z(t, kath, t), "Today");
  ASSERT_STR(wx_format_weekday_z(t + 86400, kath, t), "Tomorrow");
  ASSERT_STR(wx_format_hour_label_z(t, utc_null), "7 PM");
  ASSERT_STR(wx_format_clock_z(t, utc_bad), "7:00 PM");
  ASSERT_INT64(wx_format_local_day_end_z(t, kath), ts(2026, 10, 12, 18, 15, 0)); /* Oct 13 00:00 at +05:45 */
  ASSERT_INT64(wx_format_local_day_end_z(t, utc_null), ts(2026, 10, 12, 0, 0, 0));
  ASSERT_STR(wx_format_hour_label_z(WX_TIME_MAX_S, kath), DASH);
  ASSERT_STR(wx_format_clock_z(0, kath), DASH);
  ASSERT_STR(wx_format_weekday_z(0, kath, t), DASH);
  ASSERT_INT64(wx_format_local_day_end_z(0, kath), 0);
  /* the string functions agree (they only differ in where the zone comes from) */
  g_assert_cmpuint(wx_format_zone_loads(), ==, loads + 0); /* the _z calls above looked nothing up */
  ASSERT_STR(wx_format_hour_label(t, "Asia/Kathmandu"), "12:45 AM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, loads + 1);
  ASSERT_INT64(wx_format_local_day_end(t, "Asia/Kathmandu"), wx_format_local_day_end_z(t, kath));
  /* NULL zone: programmer error */
  ASSERT_CRITICAL("wx_format_hour_label_z", g_assert_null(wx_format_hour_label_z(t, NULL)));
  ASSERT_CRITICAL("wx_format_clock_z", g_assert_null(wx_format_clock_z(t, NULL)));
  ASSERT_CRITICAL("wx_format_weekday_z", g_assert_null(wx_format_weekday_z(t, NULL, t)));
  ASSERT_CRITICAL("wx_format_local_day_end_z", ASSERT_INT64(wx_format_local_day_end_z(t, NULL), 0));
  wx_format_test_set_hooks(NULL, NULL);
}

static void
test_zone_load_does_not_block_others(void)
{
  wx_format_test_set_hooks(slow_loader, NULL);
  guint base = wx_format_zone_loads();
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Africa/Nairobi"), "10 PM"); /* cached */
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 1);

  GThread *slow1 = g_thread_new("slow1", slow_user, NULL);
  GThread *slow2 = g_thread_new("slow2", slow_user, NULL);
  g_mutex_lock(&latch.lock);
  gint64 deadline = g_get_monotonic_time() + 10 * G_USEC_PER_SEC;
  while (latch.entered < 2 && g_cond_wait_until(&latch.cond, &latch.lock, deadline))
    ;
  g_assert_cmpuint(latch.entered, ==, 2); /* both are inside the loader, blocked */
  g_mutex_unlock(&latch.lock);

  GThread *fast = g_thread_new("cached", cached_user, NULL);
  g_mutex_lock(&latch.lock);
  deadline = g_get_monotonic_time() + 10 * G_USEC_PER_SEC;
  while (!latch.done && g_cond_wait_until(&latch.cond, &latch.lock, deadline))
    ;
  gboolean fast_finished = latch.done; /* while the two loads are still blocked */
  latch.release = TRUE;
  g_cond_broadcast(&latch.cond);
  g_mutex_unlock(&latch.lock);
  g_thread_join(slow1);
  g_thread_join(slow2);
  g_thread_join(fast);
  g_assert_true(fast_finished);

  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 3); /* Nairobi once, the slow zone twice */
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Slow/Zone"), "3 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 3); /* kept: one result */
  /* the duplicate was dropped, not stored: Nairobi + the slow zone + 6 more names fill the 8 slots
   * exactly, so nothing has been evicted (a stored duplicate would have pushed Nairobi out) */
  char name[16];
  for (int i = 1; i <= 6; i++) {
    g_snprintf(name, sizeof name, "Etc/GMT+%d", i);
    g_free(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), name));
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 9);
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Africa/Nairobi"), "10 PM");
  ASSERT_STR(wx_format_hour_label(ts(2026, 10, 11, 19, 0, 0), "Slow/Zone"), "3 PM");
  g_assert_cmpuint(wx_format_zone_loads(), ==, base + 9);
  wx_format_test_set_hooks(NULL, NULL);
}

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  g_test_add_func("/format/temp", test_temp);
  g_test_add_func("/format/wind", test_wind);
  g_test_add_func("/format/precip", test_precip);
  g_test_add_func("/format/percent", test_percent);
  g_test_add_func("/format/locale-independent", test_locale_independent);
  g_test_add_func("/format/hour-label-and-clock", test_hour_label_and_clock);
  g_test_add_func("/format/tz-read-bound", test_tz_read_bound);
  g_test_add_func("/format/zone-rule-table", test_zone_rule_table);
  g_test_add_func("/format/zone-cache", test_zone_cache);
  g_test_add_func("/format/local-day-end", test_local_day_end);
  g_test_add_func("/format/local-day-end/repeated-midnight", test_local_day_end_repeated_midnight);
  g_test_add_func("/format/local-day-end/day-lengths", test_local_day_lengths);
  g_test_add_func("/format/local-day-end/all-zones", test_local_day_end_all_zones);
  g_test_add_func("/format/weekday", test_weekday);
  g_test_add_func("/format/updated", test_updated);
  g_test_add_func("/format/headline/dry", test_headline_dry);
  g_test_add_func("/format/headline/now", test_headline_now);
  g_test_add_func("/format/headline/expected", test_headline_expected);
  g_test_add_func("/format/headline/possible", test_headline_possible);
  g_test_add_func("/format/headline/programmer-errors", test_headline_programmer_errors);
  g_test_add_func("/format/detail", test_detail);
  g_test_add_func("/format/detail/past-peak", test_detail_past_peak);
  g_test_add_func("/format/cloud/bands", test_cloud_bands);
  g_test_add_func("/format/cloud/transitions", test_cloud_transitions);
  g_test_add_func("/format/cloud/targets", test_cloud_targets);
  g_test_add_func("/format/cloud/days-and-lookahead", test_cloud_days_and_lookahead);
  g_test_add_func("/format/cloud/unknown", test_cloud_unknown);
  g_test_add_func("/format/icons", test_icons);
  g_test_add_func("/format/fuzz", test_fuzz);
  g_test_add_func("/format/process-tz-independent", test_process_tz_independent);
  g_test_add_func("/format/threads", test_threads);
  g_test_add_func("/format/zone-failure-heals", test_zone_failure_heals);
  g_test_add_func("/format/zone-failure-forgotten-on-success", test_zone_failure_forgotten_on_success);
  g_test_add_func("/format/zone-new-resolved-flag", test_zone_new_resolved_flag);
  g_test_add_func("/format/neg-ring/free-and-expired-slots", test_neg_ring_prefers_free_and_expired_slots);
  g_test_add_func("/format/neg-ring/model", test_neg_ring_model);
  g_test_add_func("/format/zone-cache-is-lru", test_zone_cache_is_lru);
  g_test_add_func("/format/zone-taking-functions", test_zone_taking_functions);
  g_test_add_func("/format/zone-load-does-not-block-others", test_zone_load_does_not_block_others);
  return g_test_run();
}
