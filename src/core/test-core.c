/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* Offline unit tests for the core module (types, text, time, geo). */
#include <glib.h>
#include <locale.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-geo.h"
#include "wx-text.h"
#include "wx-time.h"
#include "wx-types.h"

/* A fixed instant used all over the tests: 2026-10-11T00:00:00Z. */
#define T0 G_GINT64_CONSTANT(1791676800)

/* A valid attribution URL for tests that are not about URLs. */
#define GOOD_URL "https://example.org/"

/* Runs @check with the one critical that @fname's g_return_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END


/* ------------------------------------------------------------------------ */
/* helpers                                                                  */
/* ------------------------------------------------------------------------ */

/* A valid place that tests then break one field at a time. */
static WxPlace *
make_miami(void)
{
  GError *err = NULL;
  WxPlace *p = wx_place_new("Miami", "Florida", "United States", "US", 25.7617, -80.1918,
                            "America/New_York", &err);
  g_assert_no_error(err);
  g_assert_nonnull(p);
  return p;
}

static void
assert_place_rejected(const char *name, const char *admin1, const char *country, const char *cc,
                      double lat, double lon, const char *tz)
{
  GError *err = NULL;
  WxPlace *p = wx_place_new(name, admin1, country, cc, lat, lon, tz, &err);
  g_assert_null(p);
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  /* the error location is optional */
  g_assert_null(wx_place_new(name, admin1, country, cc, lat, lon, tz, NULL));
}

static WxHour
good_hour(gint64 t_s)
{
  WxHour h;
  wx_hour_init(&h);
  h.t_s = t_s;
  h.temp_c = 25.0;
  h.feels_c = 27.0;
  h.precip_mm = 0.5;
  h.precip_prob = 40.0;
  h.cloud_pct = 60.0;
  h.wind_kmh = 12.0;
  h.gust_kmh = 25.0;
  h.humidity_pct = 80.0;
  h.wmo = 61;
  return h;
}

static WxMember *
make_member(void)
{
  GError *err = NULL;
  WxMember *m = wx_member_new("open-meteo", "ecmwf_ifs025", T0, &err);
  g_assert_no_error(err);
  g_assert_nonnull(m);
  return m;
}

static WxBlendHour
good_blend_hour(gint64 t_s)
{
  WxBlendHour b = {
    .t_s = t_s,
    .temp_c = 28.0,
    .feels_c = 31.0,
    .precip_mm = 0.2,
    .precip_mm_max = 1.0,
    .precip_prob = 30.0,
    .cloud_pct = 55.0,
    .wind_kmh = 14.0,
    .gust_kmh = 30.0,
    .humidity_pct = 75.0,
    .temp_spread_c = 1.5,
    .n_members = 4,
    .condition = WX_COND_PARTLY_CLOUDY,
    .is_day = TRUE,
  };
  return b;
}

static WxDay
good_day(gint64 start_s)
{
  WxDay d = {
    .start_s = start_s,
    .temp_max_c = 31.0,
    .temp_min_c = 23.0,
    .precip_mm = 3.0,
    .precip_prob_max = 70.0,
    .cloud_pct = 50.0,
    .condition = WX_COND_SHOWERS,
  };
  return d;
}

static void
assert_utf8_clean(const char *s)
{
  g_assert_true(g_utf8_validate(s, -1, NULL));
  for (const char *p = s; *p != '\0'; p = g_utf8_next_char(p)) {
    gunichar c = g_utf8_get_char(p);
    g_assert_false(g_unichar_iscntrl(c));
    g_assert_false(c == 0x2028 || c == 0x2029 || c == 0x061C || c == 0x200E || c == 0x200F);
    g_assert_false(c >= 0x202A && c <= 0x202E);
    g_assert_false(c >= 0x2066 && c <= 0x2069);
  }
}

/* ------------------------------------------------------------------------ */
/* types: errors, ranges, ids                                               */
/* ------------------------------------------------------------------------ */

static void
test_error_domain(void)
{
  g_autoptr(GError) err = g_error_new(WX_ERROR, WX_ERROR_RATE_LIMITED, "slow down");
  g_assert_true(g_error_matches(err, WX_ERROR, WX_ERROR_RATE_LIMITED));
  g_assert_cmpstr(g_quark_to_string(WX_ERROR), ==, "wx-error-quark");
  g_assert_cmpint(WX_ERROR_NETWORK, ==, 0);
  g_assert_cmpint(WX_ERROR_UNSUPPORTED, ==, 7);
  g_assert_cmpint(WX_ERROR_TIMEOUT, !=, WX_ERROR_HTTP);
  g_assert_cmpint(WX_COND_COUNT, ==, 15);
  g_assert_cmpint(WX_SRC_SKIPPED, ==, 2);
  g_assert_cmpint(WX_UNITS_METRIC, !=, WX_UNITS_IMPERIAL);
  g_assert_cmpint(WX_RAIN_POSSIBLE, ==, 3);
  g_assert_cmpint(WX_MEMBER_MAX_HOURS, ==, 400);
  g_assert_cmpint(WX_MEMBER_MAX_QUARTERS, ==, 1536);
  g_assert_cmpint(WX_PLACE_NAME_MAX, ==, 256);
  g_assert_cmpint(WX_PLACE_MAX, ==, 50);
  g_assert_cmpint(WX_TIME_MIN_S, ==, 946684800);
  g_assert_cmpint(WX_TIME_MAX_S, ==, 4133980800);
}

static void
test_value_in_range(void)
{
  g_assert_true(wx_value_in_range(0.0, 0.0, 100.0));
  g_assert_true(wx_value_in_range(100.0, 0.0, 100.0));
  g_assert_true(wx_value_in_range(-100.0, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
  g_assert_true(wx_value_in_range(70.0, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
  g_assert_false(wx_value_in_range(-100.0001, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
  g_assert_false(wx_value_in_range(70.0001, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
  g_assert_false(wx_value_in_range(100.0001, 0.0, 100.0));
  g_assert_false(wx_value_in_range(NAN, 0.0, 100.0));
  g_assert_false(wx_value_in_range(INFINITY, 0.0, INFINITY));
  g_assert_false(wx_value_in_range(-INFINITY, -INFINITY, 0.0));
  g_assert_false(wx_value_in_range(1.0, NAN, 2.0));
  g_assert_false(wx_value_in_range(1.0, 0.0, NAN));
  g_assert_true(wx_value_in_range(WX_WIND_MAX_KMH, 0.0, WX_WIND_MAX_KMH));
  g_assert_true(wx_value_in_range(WX_PRECIP_MAX_MM_H, 0.0, WX_PRECIP_MAX_MM_H));
}

static void
test_id_validation(void)
{
  g_assert_true(wx_id_is_valid("open-meteo"));
  g_assert_true(wx_id_is_valid("ecmwf_ifs025"));
  g_assert_true(wx_id_is_valid("met-no"));
  g_assert_true(wx_id_is_valid("a"));
  g_assert_true(wx_id_is_valid("a.b_c-9"));
  g_assert_true(wx_id_is_valid("abcdefghijklmnopqrstuvwxyz012345")); /* 32 */
  g_assert_false(wx_id_is_valid("abcdefghijklmnopqrstuvwxyz0123456")); /* 33 */
  g_assert_false(wx_id_is_valid(NULL));
  g_assert_false(wx_id_is_valid(""));
  g_assert_false(wx_id_is_valid("Open"));
  g_assert_false(wx_id_is_valid("a b"));
  g_assert_false(wx_id_is_valid("a/b"));
  g_assert_false(wx_id_is_valid("../x"));
  g_assert_false(wx_id_is_valid("a\n"));
  g_assert_false(wx_id_is_valid("\xc3\xa9"));
  g_assert_false(wx_id_is_valid("a%00"));
  /* unterminated long buffer: only WX_ID_MAX + 1 bytes are examined */
  char big[200];
  memset(big, 'a', sizeof big);
  g_assert_false(wx_id_is_valid(big));

  /* path-traversal and option-like names: the first character must be [a-z0-9] */
  g_assert_false(wx_id_is_valid("."));
  g_assert_false(wx_id_is_valid(".."));
  g_assert_false(wx_id_is_valid("..."));
  g_assert_false(wx_id_is_valid(".x"));
  g_assert_false(wx_id_is_valid(".hidden"));
  g_assert_false(wx_id_is_valid("-x"));
  g_assert_false(wx_id_is_valid("-"));
  g_assert_false(wx_id_is_valid("--help"));
  g_assert_false(wx_id_is_valid("_x"));
  g_assert_false(wx_id_is_valid("_"));
  g_assert_false(wx_id_is_valid("../etc"));
  g_assert_false(wx_id_is_valid("..x"));
  /* interior and trailing '.' / '-' / '_' are allowed (documented): not path components */
  g_assert_true(wx_id_is_valid("a.b"));
  g_assert_true(wx_id_is_valid("a..b"));
  g_assert_true(wx_id_is_valid("a-"));
  g_assert_true(wx_id_is_valid("a."));
  g_assert_true(wx_id_is_valid("0.25"));
  g_assert_true(wx_id_is_valid("9"));
  g_assert_true(wx_id_is_valid("ecmwf_ifs0.25"));
  /* the rule is applied everywhere an id is accepted */
  g_assert_null(wx_member_new("..", "m", T0, NULL));
  g_assert_null(wx_member_new("s", ".", T0, NULL));
  g_assert_null(wx_member_new("s", "-m", T0, NULL));
  g_assert_null(wx_source_result_new("..", NULL));
  g_assert_null(wx_source_status_new("..", "n", "a", GOOD_URL, WX_SRC_OK, -1, 0, NULL));
}

/* ------------------------------------------------------------------------ */
/* types: places                                                            */
/* ------------------------------------------------------------------------ */

static void
test_place_valid(void)
{
  g_autoptr(WxPlace) p = make_miami();
  g_assert_cmpstr(p->name, ==, "Miami");
  g_assert_cmpstr(p->admin1, ==, "Florida");
  g_assert_cmpstr(p->country, ==, "United States");
  g_assert_cmpstr(p->country_code, ==, "US");
  g_assert_cmpfloat(p->lat, ==, 25.7617);
  g_assert_cmpfloat(p->lon, ==, -80.1918);
  g_assert_cmpstr(p->timezone, ==, "America/New_York");

  /* NULL and "" optional fields become "" */
  g_autoptr(WxPlace) q = wx_place_new("Oslo", NULL, NULL, NULL, 59.91, 10.75, NULL, NULL);
  g_assert_nonnull(q);
  g_assert_cmpstr(q->admin1, ==, "");
  g_assert_cmpstr(q->country, ==, "");
  g_assert_cmpstr(q->country_code, ==, "");
  g_assert_cmpstr(q->timezone, ==, "");
  g_autoptr(WxPlace) r = wx_place_new("Oslo", "", "", "", 59.91, 10.75, "", NULL);
  g_assert_nonnull(r);
  g_assert_cmpstr(r->admin1, ==, "");
  g_assert_cmpstr(r->country_code, ==, "");

  /* non-ASCII names are fine */
  g_autoptr(WxPlace) u = wx_place_new("S\xc3\xa3o Paulo", "S\xc3\xa3o Paulo", "Brasil", "BR",
                                      -23.55, -46.63, "America/Sao_Paulo", NULL);
  g_assert_nonnull(u);
  g_autoptr(WxPlace) cjk = wx_place_new("\xe6\x9d\xb1\xe4\xba\xac", NULL, NULL, "JP", 35.68, 139.69,
                                        "Asia/Tokyo", NULL);
  g_assert_nonnull(cjk);
  g_autoptr(WxPlace) tz = wx_place_new("X", NULL, NULL, NULL, 0, 0, "Etc/GMT+5", NULL);
  g_assert_nonnull(tz);
}

static void
test_place_boundaries(void)
{
  g_autoptr(WxPlace) a = wx_place_new("N", NULL, NULL, NULL, 90.0, 180.0, NULL, NULL);
  g_assert_nonnull(a);
  g_autoptr(WxPlace) b = wx_place_new("S", NULL, NULL, NULL, -90.0, -180.0, NULL, NULL);
  g_assert_nonnull(b);

  g_autofree char *n256 = g_strnfill(256, 'x');
  g_autofree char *n257 = g_strnfill(257, 'x');
  g_autoptr(WxPlace) c = wx_place_new(n256, n256, n256, NULL, 0, 0, NULL, NULL);
  g_assert_nonnull(c);
  assert_place_rejected(n257, NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("x", n257, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("x", NULL, n257, NULL, 0, 0, NULL);

  /* a 2-byte character straddling the limit is still a plain length failure */
  g_autofree char *wide = g_strnfill(255, 'x');
  g_autofree char *wide2 = g_strconcat(wide, "\xc3\xa9", NULL); /* 257 bytes */
  assert_place_rejected(wide2, NULL, NULL, NULL, 0, 0, NULL);

  g_autofree char *tz64 = g_strnfill(64, 'a');
  g_autofree char *tz65 = g_strnfill(65, 'a');
  g_autoptr(WxPlace) d = wx_place_new("x", NULL, NULL, NULL, 0, 0, tz64, NULL);
  g_assert_nonnull(d);
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, tz65);

  assert_place_rejected("x", NULL, NULL, NULL, 90.0001, 0, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, -90.0001, 0, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, 0, 180.0001, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, 0, -180.0001, NULL);
}

static void
test_place_hostile(void)
{
  assert_place_rejected(NULL, NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("   ", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("\t\n", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("Mia\nmi", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("Mia\tmi", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("Mia\x7f", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("Mia\x1b[31m", NULL, NULL, NULL, 0, 0, NULL);
  assert_place_rejected("Mia\xc2\x85mi", NULL, NULL, NULL, 0, 0, NULL);       /* C1 NEL */
  assert_place_rejected("a\xe2\x80\xaa" "b", NULL, NULL, NULL, 0, 0, NULL);   /* U+202A */
  assert_place_rejected("a\xe2\x80\xae" "b", NULL, NULL, NULL, 0, 0, NULL);   /* U+202E RLO */
  assert_place_rejected("a\xe2\x81\xa6" "b", NULL, NULL, NULL, 0, 0, NULL);   /* U+2066 LRI */
  assert_place_rejected("a\xe2\x80\x8f" "b", NULL, NULL, NULL, 0, 0, NULL);   /* U+200F RLM */
  assert_place_rejected("a\xe2\x80\xa8" "b", NULL, NULL, NULL, 0, 0, NULL);   /* U+2028 */
  assert_place_rejected("a\xff" "b", NULL, NULL, NULL, 0, 0, NULL);           /* invalid UTF-8 */
  assert_place_rejected("a\xc3", NULL, NULL, NULL, 0, 0, NULL);               /* truncated */
  assert_place_rejected("a\xc0\x80" "b", NULL, NULL, NULL, 0, 0, NULL);       /* overlong NUL */
  assert_place_rejected("a\xed\xa0\x80" "b", NULL, NULL, NULL, 0, 0, NULL);   /* surrogate */
  assert_place_rejected("x", "bad\nadmin", NULL, NULL, 0, 0, NULL);
  assert_place_rejected("x", NULL, "bad\xff", NULL, 0, 0, NULL);
  assert_place_rejected("x", "  ", NULL, NULL, 0, 0, NULL); /* whitespace-only optional text */

  /* country codes */
  assert_place_rejected("x", NULL, NULL, "us", 0, 0, NULL);
  assert_place_rejected("x", NULL, NULL, "U", 0, 0, NULL);
  assert_place_rejected("x", NULL, NULL, "USA", 0, 0, NULL);
  assert_place_rejected("x", NULL, NULL, "U1", 0, 0, NULL);
  assert_place_rejected("x", NULL, NULL, "U ", 0, 0, NULL);
  assert_place_rejected("x", NULL, NULL, "\xc3\x9c" "S", 0, 0, NULL);

  /* coordinates */
  assert_place_rejected("x", NULL, NULL, NULL, NAN, 0, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, 0, NAN, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, INFINITY, 0, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, 0, -INFINITY, NULL);
  assert_place_rejected("x", NULL, NULL, NULL, 1e308, 0, NULL);

  /* time zones */
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "America/New York");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "../etc/passwd\n");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "UTC;rm");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "/etc/passwd");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "/dev/stdin");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "/");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "//");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "-");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "America/");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "America//New_York");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "/usr/share/zoneinfo/Asia/Tokyo");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "./x");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "a/../b");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "Z\xc3\xbcrich");
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, "A%20B");
}

static void
test_place_error_text(void)
{
  GError *err = NULL;
  g_assert_null(wx_place_new("secret\nname", NULL, NULL, NULL, 0, 0, NULL, &err));
  g_assert_nonnull(err);
  g_assert_null(strstr(err->message, "secret"));
  g_clear_error(&err);
}

static void
test_place_key_label(void)
{
  g_autoptr(WxPlace) p = make_miami();
  g_autofree char *key = wx_place_key(p);
  g_assert_cmpstr(key, ==, "25.7617,-80.1918");
  g_autofree char *label = wx_place_label(p);
  g_assert_cmpstr(label, ==, "Miami, Florida, United States");

  g_autoptr(WxPlace) a = wx_place_new("Oslo", NULL, "Norway", "NO", 59.9139, 10.7522, NULL, NULL);
  g_autofree char *la = wx_place_label(a);
  g_assert_cmpstr(la, ==, "Oslo, Norway");
  g_autoptr(WxPlace) b = wx_place_new("Oslo", "", "", NULL, 59.9139, 10.7522, NULL, NULL);
  g_autofree char *lb = wx_place_label(b);
  g_assert_cmpstr(lb, ==, "Oslo");
  g_autoptr(WxPlace) c = wx_place_new("Texas", "Texas", "", NULL, 31.0, -100.0, NULL, NULL);
  g_autofree char *lc = wx_place_label(c);
  g_assert_cmpstr(lc, ==, "Texas, Texas");

  /* rounding to 4 decimals, zero padding, negative zero */
  g_autoptr(WxPlace) d = wx_place_new("x", NULL, NULL, NULL, 1.0, -0.00001, NULL, NULL);
  g_autofree char *kd = wx_place_key(d);
  g_assert_cmpstr(kd, ==, "1.0000,0.0000");
  g_autoptr(WxPlace) e = wx_place_new("x", NULL, NULL, NULL, -33.86882, 151.20929, NULL, NULL);
  g_autofree char *ke = wx_place_key(e);
  g_assert_cmpstr(ke, ==, "-33.8688,151.2093");
  g_autoptr(WxPlace) f = wx_place_new("x", NULL, NULL, NULL, -90.0, 180.0, NULL, NULL);
  g_autofree char *kf = wx_place_key(f);
  g_assert_cmpstr(kf, ==, "-90.0000,180.0000");
  /* places 0.00004 degrees apart share a key; 0.0001 apart do not */
  g_autoptr(WxPlace) g1 = wx_place_new("x", NULL, NULL, NULL, 10.12341, 20.0, NULL, NULL);
  g_autoptr(WxPlace) g2 = wx_place_new("x", NULL, NULL, NULL, 10.12344, 20.0, NULL, NULL);
  g_autoptr(WxPlace) g3 = wx_place_new("x", NULL, NULL, NULL, 10.12351, 20.0, NULL, NULL);
  g_autofree char *k1 = wx_place_key(g1);
  g_autofree char *k2 = wx_place_key(g2);
  g_autofree char *k3 = wx_place_key(g3);
  g_assert_cmpstr(k1, ==, k2);
  g_assert_cmpstr(k1, !=, k3);
}

static void
test_place_key_locale_independent(void)
{
  const char *candidates[] = {"de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8"};
  char *saved = g_strdup(setlocale(LC_ALL, NULL));
  gboolean switched = FALSE;
  for (guint i = 0; i < G_N_ELEMENTS(candidates) && !switched; i++) {
    if (setlocale(LC_ALL, candidates[i]) != NULL && localeconv()->decimal_point[0] == ',')
      switched = TRUE;
  }
  if (!switched)
    g_test_message("no comma-decimal locale installed; locale check only runs the C path");
  g_autoptr(WxPlace) p = make_miami();
  g_autofree char *key = wx_place_key(p);
  gint64 t = 0;
  gboolean parsed = wx_time_parse_iso8601("2026-10-11T00:00:00.5Z", &t);
  setlocale(LC_ALL, saved);
  g_free(saved);
  g_assert_cmpstr(key, ==, "25.7617,-80.1918");
  g_assert_true(parsed);
  g_assert_cmpint(t, ==, T0);
}

static void
test_place_copy_free(void)
{
  g_autoptr(WxPlace) p = make_miami();
  g_autoptr(WxPlace) c = wx_place_copy(p);
  g_assert_nonnull(c);
  g_assert_true(c != p);
  g_assert_true(c->name != p->name);
  g_assert_true(c->admin1 != p->admin1);
  g_assert_true(c->country != p->country);
  g_assert_true(c->timezone != p->timezone);
  g_assert_cmpstr(c->name, ==, p->name);
  g_assert_cmpstr(c->country_code, ==, "US");
  g_assert_cmpfloat(c->lat, ==, p->lat);
  g_assert_cmpfloat(c->lon, ==, p->lon);
  g_assert_cmpstr(c->timezone, ==, p->timezone);

  /* mutate the original: the copy is independent */
  g_free(p->name);
  p->name = g_strdup("Changed");
  g_assert_cmpstr(c->name, ==, "Miami");

  wx_place_free(NULL); /* no-op */

  /* a hand-built place with NULL strings / hostile content is refused */
  WxPlace bad = {0};
  g_assert_null(wx_place_copy(&bad));
  g_autoptr(WxPlace) q = make_miami();
  g_free(q->name);
  q->name = g_strdup("evil\nname");
  g_assert_null(wx_place_copy(q));

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_place_copy*");
  g_assert_null(wx_place_copy(NULL));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_place_key*");
  g_assert_null(wx_place_key(NULL));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_place_label*");
  g_assert_null(wx_place_label(NULL));
  g_test_assert_expected_messages();
}

static void
test_hour_init(void)
{
  WxHour h;
  memset(&h, 0xAB, sizeof h);
  wx_hour_init(&h);
  g_assert_cmpint(h.t_s, ==, 0);
  g_assert_true(isnan(h.temp_c));
  g_assert_true(isnan(h.feels_c));
  g_assert_true(isnan(h.precip_mm));
  g_assert_true(isnan(h.precip_prob));
  g_assert_true(isnan(h.cloud_pct));
  g_assert_true(isnan(h.wind_kmh));
  g_assert_true(isnan(h.gust_kmh));
  g_assert_true(isnan(h.humidity_pct));
  g_assert_cmpint(h.wmo, ==, -1);
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_hour_init*");
  wx_hour_init(NULL);
  g_test_assert_expected_messages();
}

/* ------------------------------------------------------------------------ */
/* types: members                                                           */
/* ------------------------------------------------------------------------ */

static void
test_member_new(void)
{
  g_autoptr(WxMember) m = make_member();
  g_assert_cmpstr(wx_member_get_source_id(m), ==, "open-meteo");
  g_assert_cmpstr(wx_member_get_model_id(m), ==, "ecmwf_ifs025");
  g_assert_cmpint(wx_member_get_fetched_s(m), ==, T0);
  guint n = 99;
  g_assert_null(wx_member_get_hours(m, &n));
  g_assert_cmpuint(n, ==, 0);
  n = 99;
  g_assert_null(wx_member_get_quarters(m, &n));
  g_assert_cmpuint(n, ==, 0);

  const char *bad_ids[] = {NULL, "", "Upper", "has space", "a/b", "x\n",
                           "abcdefghijklmnopqrstuvwxyz0123456"};
  for (guint i = 0; i < G_N_ELEMENTS(bad_ids); i++) {
    GError *err = NULL;
    g_assert_null(wx_member_new(bad_ids[i], "model", T0, &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_clear_error(&err);
    g_assert_null(wx_member_new("src", bad_ids[i], T0, &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_clear_error(&err);
    g_assert_null(wx_member_new("src", bad_ids[i], T0, NULL));
  }
  g_assert_null(wx_member_new("s", "m", 0, NULL));
  g_assert_null(wx_member_new("s", "m", -1, NULL));
  g_assert_null(wx_member_new("s", "m", WX_TIME_MIN_S - 1, NULL));
  g_assert_null(wx_member_new("s", "m", WX_TIME_MAX_S, NULL));
  g_assert_null(wx_member_new("s", "m", G_MAXINT64, NULL));
  g_autoptr(WxMember) lo = wx_member_new("s", "m", WX_TIME_MIN_S, NULL);
  g_assert_nonnull(lo);
  g_autoptr(WxMember) hi = wx_member_new("s", "m", WX_TIME_MAX_S - 1, NULL);
  g_assert_nonnull(hi);

  /* the ids are private copies */
  char src[] = "abc";
  g_autoptr(WxMember) c = wx_member_new(src, "m", T0, NULL);
  src[0] = 'z';
  g_assert_cmpstr(wx_member_get_source_id(c), ==, "abc");
}

static void
test_member_add_hour_rules(void)
{
  g_autoptr(WxMember) m = make_member();
  WxHour h = good_hour(T0);
  g_assert_true(wx_member_add_hour(m, &h));
  g_assert_cmpuint(m->n_hours, ==, 1);

  /* duplicate and descending */
  g_assert_false(wx_member_add_hour(m, &h));
  WxHour earlier = good_hour(T0 - 3600);
  g_assert_false(wx_member_add_hour(m, &earlier));
  g_assert_cmpuint(m->n_hours, ==, 1);

  /* not a multiple of 3600 */
  WxHour odd = good_hour(T0 + 3601);
  g_assert_false(wx_member_add_hour(m, &odd));
  odd.t_s = T0 + 1800;
  g_assert_false(wx_member_add_hour(m, &odd));
  odd.t_s = T0 + 3599;
  g_assert_false(wx_member_add_hour(m, &odd));
  g_assert_cmpuint(m->n_hours, ==, 1);

  /* gaps are allowed */
  WxHour gap = good_hour(T0 + 5 * 3600);
  g_assert_true(wx_member_add_hour(m, &gap));
  WxHour next = good_hour(T0 + 6 * 3600);
  g_assert_true(wx_member_add_hour(m, &next));
  g_assert_cmpuint(m->n_hours, ==, 3);

  /* out of the plausible time range */
  WxHour neg = good_hour(-3600);
  g_autoptr(WxMember) m2 = make_member();
  g_assert_false(wx_member_add_hour(m2, &neg));
  WxHour zero = good_hour(0);
  g_assert_false(wx_member_add_hour(m2, &zero));
  WxHour max = good_hour(WX_TIME_MAX_S);
  g_assert_false(wx_member_add_hour(m2, &max));
  WxHour huge = good_hour(G_MAXINT64 - (G_MAXINT64 % 3600));
  g_assert_false(wx_member_add_hour(m2, &huge));
  WxHour min = good_hour(WX_TIME_MIN_S);
  g_assert_true(wx_member_add_hour(m2, &min));
  g_assert_cmpuint(m2->n_hours, ==, 1);

  guint n = 0;
  const WxHour *hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, 3);
  g_assert_cmpint(hours[0].t_s, ==, T0);
  g_assert_cmpint(hours[1].t_s, ==, T0 + 5 * 3600);
  g_assert_cmpint(hours[2].t_s, ==, T0 + 6 * 3600);
  g_assert_true(hours == m->hours);
}

static void
test_member_add_hour_normalises(void)
{
  g_autoptr(WxMember) m = make_member();
  WxHour h = good_hour(T0);
  g_assert_true(wx_member_add_hour(m, &h));
  g_assert_cmpfloat(m->hours[0].temp_c, ==, 25.0);
  g_assert_cmpfloat(m->hours[0].feels_c, ==, 27.0);
  g_assert_cmpfloat(m->hours[0].precip_mm, ==, 0.5);
  g_assert_cmpfloat(m->hours[0].precip_prob, ==, 40.0);
  g_assert_cmpfloat(m->hours[0].cloud_pct, ==, 60.0);
  g_assert_cmpfloat(m->hours[0].wind_kmh, ==, 12.0);
  g_assert_cmpfloat(m->hours[0].gust_kmh, ==, 25.0);
  g_assert_cmpfloat(m->hours[0].humidity_pct, ==, 80.0);
  g_assert_cmpint(m->hours[0].wmo, ==, 61);

  /* every field out of range -> NAN / -1; the element itself is still added */
  WxHour bad = good_hour(T0 + 3600);
  bad.temp_c = 70.5;
  bad.feels_c = -100.5;
  bad.precip_mm = -0.1;
  bad.precip_prob = 100.1;
  bad.cloud_pct = -1.0;
  bad.wind_kmh = 500.1;
  bad.gust_kmh = -5.0;
  bad.humidity_pct = 1e9;
  bad.wmo = 100;
  g_assert_true(wx_member_add_hour(m, &bad));
  const WxHour *o = &m->hours[1];
  g_assert_true(isnan(o->temp_c));
  g_assert_true(isnan(o->feels_c));
  g_assert_true(isnan(o->precip_mm));
  g_assert_true(isnan(o->precip_prob));
  g_assert_true(isnan(o->cloud_pct));
  g_assert_true(isnan(o->wind_kmh));
  g_assert_true(isnan(o->gust_kmh));
  g_assert_true(isnan(o->humidity_pct));
  g_assert_cmpint(o->wmo, ==, -1);

  WxHour inf = good_hour(T0 + 2 * 3600);
  inf.temp_c = INFINITY;
  inf.feels_c = -INFINITY;
  inf.precip_mm = NAN;
  inf.wmo = -7;
  g_assert_true(wx_member_add_hour(m, &inf));
  g_assert_true(isnan(m->hours[2].temp_c));
  g_assert_true(isnan(m->hours[2].feels_c));
  g_assert_true(isnan(m->hours[2].precip_mm));
  g_assert_cmpint(m->hours[2].wmo, ==, -1);

  /* limits are inclusive; wmo 0 and 99 survive */
  WxHour edge = good_hour(T0 + 3 * 3600);
  edge.temp_c = -100.0;
  edge.feels_c = 70.0;
  edge.precip_mm = 500.0;
  edge.precip_prob = 0.0;
  edge.cloud_pct = 100.0;
  edge.wind_kmh = 500.0;
  edge.gust_kmh = 0.0;
  edge.humidity_pct = 100.0;
  edge.wmo = 99;
  g_assert_true(wx_member_add_hour(m, &edge));
  g_assert_cmpfloat(m->hours[3].temp_c, ==, -100.0);
  g_assert_cmpfloat(m->hours[3].feels_c, ==, 70.0);
  g_assert_cmpfloat(m->hours[3].precip_mm, ==, 500.0);
  g_assert_cmpfloat(m->hours[3].wind_kmh, ==, 500.0);
  g_assert_cmpint(m->hours[3].wmo, ==, 99);
  WxHour zero_wmo = good_hour(T0 + 4 * 3600);
  zero_wmo.wmo = 0;
  g_assert_true(wx_member_add_hour(m, &zero_wmo));
  g_assert_cmpint(m->hours[4].wmo, ==, 0);

  /* the caller's struct is untouched */
  g_assert_cmpfloat(bad.temp_c, ==, 70.5);
  g_assert_cmpint(bad.wmo, ==, 100);
}

static void
test_member_hour_cap_and_growth(void)
{
  g_autoptr(WxMember) m = make_member();
  for (int i = 0; i < WX_MEMBER_MAX_HOURS; i++) {
    WxHour h = good_hour(T0 + (gint64)i * 3600);
    h.temp_c = i * 0.01;
    g_assert_true(wx_member_add_hour(m, &h));
  }
  g_assert_cmpuint(m->n_hours, ==, WX_MEMBER_MAX_HOURS);
  WxHour extra = good_hour(T0 + (gint64)WX_MEMBER_MAX_HOURS * 3600);
  g_assert_false(wx_member_add_hour(m, &extra));
  g_assert_cmpuint(m->n_hours, ==, WX_MEMBER_MAX_HOURS);
  /* data survived every reallocation */
  for (int i = 0; i < WX_MEMBER_MAX_HOURS; i++) {
    g_assert_cmpint(m->hours[i].t_s, ==, T0 + (gint64)i * 3600);
    g_assert_cmpfloat_with_epsilon(m->hours[i].temp_c, i * 0.01, 1e-12);
  }
}

typedef struct {
  WxMember *member;
  WxForecast *forecast;
} RefArg;

static gpointer
ref_worker(gpointer data)
{
  RefArg *arg = data;
  for (int i = 0; i < 20000; i++) {
    if (arg->member != NULL) {
      wx_member_ref(arg->member);
      wx_member_unref(arg->member);
    }
    if (arg->forecast != NULL) {
      wx_forecast_ref(arg->forecast);
      wx_forecast_unref(arg->forecast);
    }
  }
  return NULL;
}

/* Reader thread for the shared-member test: walks the arrays like any consumer would. */
static gpointer
member_read_worker(gpointer data)
{
  WxMember *m = data;
  double sum = 0.0;
  for (int round = 0; round < 2000; round++) {
    guint n_hours = 0, n_quarters = 0;
    const WxHour *hours = wx_member_get_hours(m, &n_hours);
    const WxQuarter *quarters = wx_member_get_quarters(m, &n_quarters);
    for (guint i = 0; i < n_hours; i++)
      sum += hours[i].temp_c;
    for (guint i = 0; i < n_quarters; i++)
      sum += quarters[i].precip_mm;
  }
  return GUINT_TO_POINTER(sum > 0.0 ? 1 : 0);
}

/*
 * Build-then-share contract: adding to a member with more than one reference is a programmer
 * error: a critical is logged, FALSE is returned and nothing changes. Rejected DATA on an
 * unshared member returns FALSE without a critical (the other tests would fail on one).
 */
static void
test_member_shared_immutable(void)
{
  g_autoptr(WxMember) m = make_member();
  WxHour h0 = good_hour(T0);
  WxQuarter q0 = {T0, 0.1};
  g_assert_true(wx_member_add_hour(m, &h0));
  g_assert_true(wx_member_add_quarter(m, &q0));
  const WxHour *hours_before = m->hours;
  const WxQuarter *quarters_before = m->quarters;

  /* a second owner appears: both adders refuse (with a critical) and change nothing */
  WxMember *second = wx_member_ref(m);
  WxHour h1 = good_hour(T0 + 3600);
  WxQuarter q1 = {T0 + 900, 0.2};
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(m, &h1)));
  ASSERT_CRITICAL("wx_member_add_quarter", g_assert_false(wx_member_add_quarter(m, &q1)));
  g_assert_cmpuint(m->n_hours, ==, 1);
  g_assert_cmpuint(m->n_quarters, ==, 1);
  g_assert_true(m->hours == hours_before);
  g_assert_true(m->quarters == quarters_before);
  g_assert_cmpint(m->hours[0].t_s, ==, T0);
  g_assert_cmpfloat(m->hours[0].temp_c, ==, 25.0);
  g_assert_cmpfloat(m->quarters[0].precip_mm, ==, 0.1);
  /* shared is shared from either owner's point of view, and even for data that would be
   * rejected anyway (the sharing check comes first) */
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(second, &h1)));
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(second, &h0)));
  ASSERT_CRITICAL("wx_member_add_quarter", g_assert_false(wx_member_add_quarter(second, &q0)));

  /* two extra owners, then drop one: still shared */
  WxMember *third = wx_member_ref(m);
  wx_member_unref(second);
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(m, &h1)));
  g_assert_cmpuint(m->n_hours, ==, 1);

  /* back to a single owner: writable again, and the data accepted before is intact; data
   * that is merely invalid is rejected silently again */
  wx_member_unref(third);
  g_assert_false(wx_member_add_hour(m, &h0)); /* duplicate: FALSE, no critical */
  g_assert_true(wx_member_add_hour(m, &h1));
  g_assert_true(wx_member_add_quarter(m, &q1));
  g_assert_cmpuint(m->n_hours, ==, 2);
  g_assert_cmpuint(m->n_quarters, ==, 2);
  g_assert_cmpint(m->hours[0].t_s, ==, T0);
  g_assert_cmpint(m->hours[1].t_s, ==, T0 + 3600);
  g_assert_cmpfloat(m->quarters[1].precip_mm, ==, 0.2);

  /* readers walk a shared member while the owner keeps (wrongly) trying to grow it: nothing
   * is reallocated or appended, so the readers are race-free (ASan would flag a stale array) */
  for (int i = 2; i < 24; i++) { /* fills the initial allocation: the next add would realloc */
    WxHour h = good_hour(T0 + (gint64)i * 3600);
    g_assert_true(wx_member_add_hour(m, &h));
  }
  WxMember *shared = wx_member_ref(m);
  const WxHour *array_while_shared = m->hours;
  GThread *threads[3];
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    threads[i] = g_thread_new("reader", member_read_worker, m);
  for (int i = 24; i < 64; i++) {
    WxHour h = good_hour(T0 + (gint64)i * 3600);
    ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(m, &h)));
  }
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    g_assert_cmpuint(GPOINTER_TO_UINT(g_thread_join(threads[i])), ==, 1);
  g_assert_cmpuint(m->n_hours, ==, 24);
  g_assert_true(m->hours == array_while_shared); /* never reallocated while shared */
  wx_member_unref(shared);
  WxHour last = good_hour(T0 + 24 * 3600);
  g_assert_true(wx_member_add_hour(m, &last)); /* writable again; grows past the first block */
  g_assert_cmpuint(m->n_hours, ==, 25);
}

static void
test_member_quarters(void)
{
  g_autoptr(WxMember) m = make_member();
  WxQuarter q = {T0, 0.0};
  g_assert_true(wx_member_add_quarter(m, &q));
  g_assert_false(wx_member_add_quarter(m, &q)); /* duplicate */
  WxQuarter back = {T0 - 900, 0.1};
  g_assert_false(wx_member_add_quarter(m, &back));
  WxQuarter odd = {T0 + 901, 0.1};
  g_assert_false(wx_member_add_quarter(m, &odd));
  odd.t_s = T0 + 450;
  g_assert_false(wx_member_add_quarter(m, &odd));
  WxQuarter nan_q = {T0 + 900, NAN};
  g_assert_false(wx_member_add_quarter(m, &nan_q));
  WxQuarter neg = {T0 + 900, -0.1};
  g_assert_false(wx_member_add_quarter(m, &neg));
  WxQuarter huge = {T0 + 900, 500.1};
  g_assert_false(wx_member_add_quarter(m, &huge));
  WxQuarter inf = {T0 + 900, INFINITY};
  g_assert_false(wx_member_add_quarter(m, &inf));
  WxQuarter early = {0, 0.1};
  g_assert_false(wx_member_add_quarter(m, &early));
  WxQuarter late = {WX_TIME_MAX_S, 0.1};
  g_assert_false(wx_member_add_quarter(m, &late));
  g_assert_cmpuint(m->n_quarters, ==, 1);

  WxQuarter ok = {T0 + 1800, 500.0}; /* gap allowed, max inclusive */
  g_assert_true(wx_member_add_quarter(m, &ok));
  guint n = 0;
  const WxQuarter *qs = wx_member_get_quarters(m, &n);
  g_assert_cmpuint(n, ==, 2);
  g_assert_cmpint(qs[1].t_s, ==, T0 + 1800);
  g_assert_cmpfloat(qs[1].precip_mm, ==, 500.0);

  g_autoptr(WxMember) big = make_member();
  for (int i = 0; i < WX_MEMBER_MAX_QUARTERS; i++) {
    WxQuarter x = {T0 + (gint64)i * 900, i * 0.001};
    g_assert_true(wx_member_add_quarter(big, &x));
  }
  WxQuarter over = {T0 + (gint64)WX_MEMBER_MAX_QUARTERS * 900, 0.0};
  g_assert_false(wx_member_add_quarter(big, &over));
  g_assert_cmpuint(big->n_quarters, ==, WX_MEMBER_MAX_QUARTERS);
  g_assert_cmpint(big->quarters[WX_MEMBER_MAX_QUARTERS - 1].t_s, ==,
                  T0 + (gint64)(WX_MEMBER_MAX_QUARTERS - 1) * 900);
}

static void
test_member_refcount(void)
{
  WxMember *m = make_member();
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 1);
  WxMember *m2 = wx_member_ref(m);
  g_assert_true(m2 == m);
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 2);
  wx_member_unref(m2);
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 1);

  RefArg arg = {m, NULL};
  GThread *threads[4];
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    threads[i] = g_thread_new("ref", ref_worker, &arg);
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    g_thread_join(threads[i]);
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 1);
  wx_member_unref(m);

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_member_ref*");
  g_assert_null(wx_member_ref(NULL));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_member_unref*");
  wx_member_unref(NULL);
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_member_add_hour*");
  g_assert_false(wx_member_add_hour(NULL, NULL));
  g_test_assert_expected_messages();
  g_autoptr(WxMember) mm = make_member();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_member_add_quarter*");
  g_assert_false(wx_member_add_quarter(mm, NULL));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_member_get_hours*");
  g_assert_null(wx_member_get_hours(mm, NULL));
  g_test_assert_expected_messages();
}

static void
test_source_result(void)
{
  GError *err = NULL;
  WxSourceResult *r = wx_source_result_new("open-meteo", &err);
  g_assert_no_error(err);
  g_assert_nonnull(r);
  g_assert_cmpstr(r->provider_id, ==, "open-meteo");
  g_assert_nonnull(r->members);
  g_assert_cmpuint(r->members->len, ==, 0);

  WxMember *m = make_member();
  g_ptr_array_add(r->members, wx_member_ref(m)); /* the array owns one reference */
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 2);
  wx_source_result_free(r);
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 1); /* free dropped it */
  wx_member_unref(m);

  wx_source_result_free(NULL);
  g_autoptr(WxSourceResult) a = wx_source_result_new("met-no", NULL);
  g_assert_nonnull(a);

  const char *bad[] = {NULL, "", "Open", "a b", "abcdefghijklmnopqrstuvwxyz0123456"};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_assert_null(wx_source_result_new(bad[i], &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_clear_error(&err);
  }
}

static void
test_source_status(void)
{
  GError *err = NULL;
  WxSourceStatus *s = wx_source_status_new("nws", "National Weather Service",
                                           "Source: NOAA/National Weather Service",
                                           "https://www.weather.gov/", WX_SRC_OK, -1, 3, &err);
  g_assert_no_error(err);
  g_assert_nonnull(s);
  g_assert_cmpstr(s->provider_id, ==, "nws");
  g_assert_cmpstr(s->name, ==, "National Weather Service");
  g_assert_cmpstr(s->attribution_url, ==, "https://www.weather.gov/");
  g_assert_cmpint(s->state, ==, WX_SRC_OK);
  g_assert_cmpint(s->error_code, ==, -1);
  g_assert_cmpuint(s->n_members, ==, 3);

  WxSourceStatus *c = wx_source_status_copy(s);
  g_assert_nonnull(c);
  g_assert_true(c->name != s->name);
  g_assert_cmpstr(c->attribution, ==, s->attribution);
  g_assert_cmpuint(c->n_members, ==, 3);
  wx_source_status_free(s);
  g_assert_cmpstr(c->name, ==, "National Weather Service"); /* copy independent */
  wx_source_status_free(c);
  wx_source_status_free(NULL);

  /* NULL texts become "", hostile text is sanitised, long text truncated */
  g_autofree char *long_name = g_strnfill(1000, 'n');
  g_autoptr(WxSourceStatus) t =
    wx_source_status_new("x", NULL, "A\nB\xe2\x80\xae" "C\xff", NULL, WX_SRC_FAILED,
                         WX_ERROR_TIMEOUT, 0, NULL);
  g_assert_nonnull(t);
  g_assert_cmpstr(t->name, ==, "");
  g_assert_cmpstr(t->attribution, ==, "ABC\xef\xbf\xbd");
  g_assert_cmpstr(t->attribution_url, ==, "");
  g_assert_cmpint(t->error_code, ==, WX_ERROR_TIMEOUT);
  g_autoptr(WxSourceStatus) lng = wx_source_status_new("x", long_name, long_name, "", WX_SRC_OK,
                                                       -1, 0, NULL);
  g_assert_nonnull(lng);
  g_assert_cmpuint(strlen(lng->name), ==, WX_SOURCE_TEXT_MAX);
  g_assert_cmpuint(strlen(lng->attribution), ==, WX_SOURCE_TEXT_MAX);
  g_assert_cmpstr(lng->attribution_url, ==, "");

  g_autoptr(WxSourceStatus) skipped = wx_source_status_new(
    "x", "n", "a", GOOD_URL, WX_SRC_SKIPPED, WX_ERROR_UNSUPPORTED, 0, NULL);
  g_assert_nonnull(skipped);

  /* rejects */
  g_assert_null(wx_source_status_new("Bad Id", "n", "a", GOOD_URL, WX_SRC_OK, -1, 0, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  g_assert_null(wx_source_status_new(NULL, "n", "a", GOOD_URL, WX_SRC_OK, -1, 0, NULL));
  g_assert_null(wx_source_status_new("x", "n", "a", GOOD_URL, (WxSourceState)3, -1, 0, NULL));
  g_assert_null(wx_source_status_new("x", "n", "a", GOOD_URL, (WxSourceState)-1, -1, 0, NULL));
  g_assert_null(wx_source_status_new("x", "n", "a", GOOD_URL, WX_SRC_OK, -2, 0, NULL));
  g_assert_null(wx_source_status_new("x", "n", "a", GOOD_URL, WX_SRC_OK,
                                     WX_ERROR_UNSUPPORTED + 1, 0, NULL));
  /* a hand-built invalid status is not copied */
  WxSourceStatus bad = {0};
  g_assert_null(wx_source_status_copy(&bad));
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_source_status_copy*");
  g_assert_null(wx_source_status_copy(NULL));
  g_test_assert_expected_messages();
}

/* ------------------------------------------------------------------------ */
/* types: forecast                                                          */
/* ------------------------------------------------------------------------ */

static WxForecast *
make_forecast_sized(guint n_hours, guint n_quarters, guint n_days, guint n_sources)
{
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour *hours = g_new(WxBlendHour, n_hours + 1);
  WxQuarter *quarters = g_new(WxQuarter, n_quarters + 1);
  WxDay *days = g_new(WxDay, n_days + 1);
  WxSourceStatus *sources = g_new0(WxSourceStatus, n_sources + 1);
  for (guint i = 0; i < n_hours; i++)
    hours[i] = good_blend_hour(T0 + (gint64)i * 3600);
  for (guint i = 0; i < n_quarters; i++) {
    quarters[i].t_s = T0 + (gint64)i * 900;
    quarters[i].precip_mm = 0.1;
  }
  for (guint i = 0; i < n_days; i++)
    days[i] = good_day(T0 + (gint64)i * 86400);
  for (guint i = 0; i < n_sources; i++) {
    sources[i].provider_id = g_strdup_printf("src-%u", i);
    sources[i].name = g_strdup("Name");
    sources[i].attribution = g_strdup("Attribution");
    sources[i].attribution_url = g_strdup("https://example.org/");
    sources[i].state = WX_SRC_OK;
    sources[i].error_code = -1;
    sources[i].n_members = i;
  }
  GError *err = NULL;
  WxForecast *fc = wx_forecast_new(place, T0 + 100, n_hours ? hours : NULL, n_hours,
                                   n_quarters ? quarters : NULL, n_quarters,
                                   n_days ? days : NULL, n_days, n_sources ? sources : NULL,
                                   n_sources, &err);
  g_assert_no_error(err);
  g_assert_nonnull(fc);
  for (guint i = 0; i < n_sources; i++) {
    g_free(sources[i].provider_id);
    g_free(sources[i].name);
    g_free(sources[i].attribution);
    g_free(sources[i].attribution_url);
  }
  g_free(hours);
  g_free(quarters);
  g_free(days);
  g_free(sources);
  return fc;
}

static void
test_forecast_new(void)
{
  g_autoptr(WxForecast) fc = make_forecast_sized(48, 8, 7, 3);
  g_assert_cmpint(wx_forecast_get_generated_s(fc), ==, T0 + 100);
  const WxPlace *p = wx_forecast_get_place(fc);
  g_assert_cmpstr(p->name, ==, "Miami");
  g_assert_cmpstr(p->country_code, ==, "US");
  guint n = 0;
  const WxBlendHour *h = wx_forecast_get_hours(fc, &n);
  g_assert_cmpuint(n, ==, 48);
  g_assert_cmpint(h[47].t_s, ==, T0 + 47 * 3600);
  g_assert_cmpfloat(h[0].temp_c, ==, 28.0);
  g_assert_cmpfloat(h[0].precip_mm_max, ==, 1.0);
  g_assert_cmpfloat(h[0].temp_spread_c, ==, 1.5);
  g_assert_cmpuint(h[0].n_members, ==, 4);
  g_assert_cmpint(h[0].condition, ==, WX_COND_PARTLY_CLOUDY);
  g_assert_true(h[0].is_day);
  const WxQuarter *q = wx_forecast_get_quarters(fc, &n);
  g_assert_cmpuint(n, ==, 8);
  g_assert_cmpint(q[7].t_s, ==, T0 + 7 * 900);
  const WxDay *d = wx_forecast_get_days(fc, &n);
  g_assert_cmpuint(n, ==, 7);
  g_assert_cmpint(d[6].start_s, ==, T0 + 6 * 86400);
  g_assert_cmpint(d[0].condition, ==, WX_COND_SHOWERS);
  const WxSourceStatus *s = wx_forecast_get_sources(fc, &n);
  g_assert_cmpuint(n, ==, 3);
  g_assert_cmpstr(s[2].provider_id, ==, "src-2");
  g_assert_cmpuint(s[2].n_members, ==, 2);
  /* public fields mirror the getters */
  g_assert_true(fc->hours == h);
  g_assert_cmpuint(fc->n_days, ==, 7);
  g_assert_cmpuint(fc->ref_count, ==, 1);
}

static void
test_forecast_copies_everything(void)
{
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour hours[2] = {good_blend_hour(T0), good_blend_hour(T0 + 3600)};
  WxQuarter quarters[1] = {{T0, 0.3}};
  WxDay days[1] = {good_day(T0)};
  WxSourceStatus src = {g_strdup("nws"), g_strdup("N"), g_strdup("A"), g_strdup(GOOD_URL),
                        WX_SRC_OK, -1, 5};
  g_autoptr(WxForecast) fc = wx_forecast_new(place, T0, hours, 2, quarters, 1, days, 1, &src, 1,
                                             NULL);
  g_assert_nonnull(fc);
  /* change / free every input: the forecast must not notice */
  hours[0].temp_c = -1.0;
  quarters[0].precip_mm = 99.0;
  days[0].temp_max_c = -1.0;
  g_free(src.provider_id);
  g_free(src.name);
  g_free(src.attribution);
  g_free(src.attribution_url);
  g_free(place->name);
  place->name = g_strdup("Changed");
  g_assert_cmpfloat(fc->hours[0].temp_c, ==, 28.0);
  g_assert_cmpfloat(fc->quarters[0].precip_mm, ==, 0.3);
  g_assert_cmpfloat(fc->days[0].temp_max_c, ==, 31.0);
  g_assert_cmpstr(fc->sources[0].provider_id, ==, "nws");
  g_assert_cmpstr(fc->sources[0].name, ==, "N");
  g_assert_cmpstr(fc->place.name, ==, "Miami");
  g_assert_true(fc->place.name != place->name);
}

static void
test_forecast_empty_and_max(void)
{
  g_autoptr(WxForecast) empty = make_forecast_sized(0, 0, 0, 0);
  guint n = 99;
  g_assert_null(wx_forecast_get_hours(empty, &n));
  g_assert_cmpuint(n, ==, 0);
  g_assert_null(wx_forecast_get_quarters(empty, &n));
  g_assert_null(wx_forecast_get_days(empty, &n));
  g_assert_null(wx_forecast_get_sources(empty, &n));
  g_assert_cmpuint(n, ==, 0);

  g_autoptr(WxForecast) full =
    make_forecast_sized(WX_FORECAST_MAX_HOURS, WX_FORECAST_MAX_QUARTERS, WX_FORECAST_MAX_DAYS,
                        WX_FORECAST_MAX_SOURCES);
  g_assert_cmpuint(full->n_hours, ==, 400);
  g_assert_cmpuint(full->n_quarters, ==, 1536);
  g_assert_cmpuint(full->n_days, ==, 16);
  g_assert_cmpuint(full->n_sources, ==, 16);
}

static void
test_forecast_normalises_numbers(void)
{
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour h = good_blend_hour(T0);
  h.temp_c = 1000;
  h.feels_c = -1000;
  h.precip_mm = -1;
  h.precip_mm_max = INFINITY;
  h.precip_prob = 101;
  h.cloud_pct = NAN;
  h.wind_kmh = 501;
  h.gust_kmh = -1;
  h.humidity_pct = 200;
  h.temp_spread_c = 171;
  h.is_day = 7;
  WxDay d = good_day(T0);
  d.temp_max_c = 80;
  d.temp_min_c = -101;
  d.precip_mm = -1;
  d.precip_prob_max = 101;
  d.cloud_pct = -1;
  g_autoptr(WxForecast) fc = wx_forecast_new(place, T0, &h, 1, NULL, 0, &d, 1, NULL, 0, NULL);
  g_assert_nonnull(fc);
  const WxBlendHour *o = &fc->hours[0];
  g_assert_true(isnan(o->temp_c));
  g_assert_true(isnan(o->feels_c));
  g_assert_true(isnan(o->precip_mm));
  g_assert_true(isnan(o->precip_mm_max));
  g_assert_true(isnan(o->precip_prob));
  g_assert_true(isnan(o->cloud_pct));
  g_assert_true(isnan(o->wind_kmh));
  g_assert_true(isnan(o->gust_kmh));
  g_assert_true(isnan(o->humidity_pct));
  g_assert_true(isnan(o->temp_spread_c));
  g_assert_cmpint(o->is_day, ==, TRUE);
  g_assert_true(isnan(fc->days[0].temp_max_c));
  g_assert_true(isnan(fc->days[0].temp_min_c));
  g_assert_true(isnan(fc->days[0].precip_mm));
  g_assert_true(isnan(fc->days[0].precip_prob_max));
  g_assert_true(isnan(fc->days[0].cloud_pct));

  /* NAN spread (fewer than two members) stays NAN; legitimate values survive */
  WxBlendHour one = good_blend_hour(T0);
  one.temp_spread_c = NAN;
  one.n_members = 1;
  g_autoptr(WxForecast) f2 = wx_forecast_new(place, T0, &one, 1, NULL, 0, NULL, 0, NULL, 0, NULL);
  g_assert_nonnull(f2);
  g_assert_true(isnan(f2->hours[0].temp_spread_c));
  g_assert_cmpuint(f2->hours[0].n_members, ==, 1);
}

static void
assert_forecast_rejected(const WxPlace *place, gint64 gen, const WxBlendHour *h, guint nh,
                         const WxQuarter *q, guint nq, const WxDay *d, guint nd,
                         const WxSourceStatus *s, guint ns)
{
  GError *err = NULL;
  g_assert_null(wx_forecast_new(place, gen, h, nh, q, nq, d, nd, s, ns, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  g_assert_null(wx_forecast_new(place, gen, h, nh, q, nq, d, nd, s, ns, NULL));
}

static void
test_forecast_rejects(void)
{
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour hs[3] = {good_blend_hour(T0), good_blend_hour(T0 + 3600),
                       good_blend_hour(T0 + 7200)};
  WxQuarter qs[3] = {{T0, 0.1}, {T0 + 900, 0.1}, {T0 + 1800, 0.1}};
  WxDay ds[2] = {good_day(T0), good_day(T0 + 86400)};

  /* generation time */
  assert_forecast_rejected(place, 0, hs, 3, NULL, 0, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, WX_TIME_MAX_S, hs, 3, NULL, 0, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, -5, hs, 3, NULL, 0, NULL, 0, NULL, 0);

  /* NULL array with a count; counts above the maxima */
  assert_forecast_rejected(place, T0, NULL, 3, NULL, 0, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, NULL, 2, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 1, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, NULL, 1);
  assert_forecast_rejected(place, T0, hs, WX_FORECAST_MAX_HOURS + 1, NULL, 0, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, qs, WX_FORECAST_MAX_QUARTERS + 1, NULL, 0, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, ds, WX_FORECAST_MAX_DAYS + 1, NULL, 0);
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, NULL, WX_FORECAST_MAX_SOURCES + 1);
  assert_forecast_rejected(place, T0, hs, G_MAXUINT, NULL, 0, NULL, 0, NULL, 0);

  /* hours */
  WxBlendHour bad[3];
  memcpy(bad, hs, sizeof bad);
  bad[1].t_s = T0; /* duplicate */
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);
  memcpy(bad, hs, sizeof bad);
  bad[2].t_s = T0 + 1800; /* descending */
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);
  memcpy(bad, hs, sizeof bad);
  bad[1].t_s = T0 + 3601; /* unaligned */
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);
  memcpy(bad, hs, sizeof bad);
  bad[0].t_s = 0;
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);
  memcpy(bad, hs, sizeof bad);
  bad[2].condition = WX_COND_COUNT;
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);
  memcpy(bad, hs, sizeof bad);
  bad[2].condition = (WxCondition)-1;
  assert_forecast_rejected(place, T0, bad, 3, NULL, 0, NULL, 0, NULL, 0);

  /* quarters */
  WxQuarter bq[3];
  memcpy(bq, qs, sizeof bq);
  bq[1].t_s = T0;
  assert_forecast_rejected(place, T0, hs, 3, bq, 3, NULL, 0, NULL, 0);
  memcpy(bq, qs, sizeof bq);
  bq[1].t_s = T0 + 901;
  assert_forecast_rejected(place, T0, hs, 3, bq, 3, NULL, 0, NULL, 0);
  memcpy(bq, qs, sizeof bq);
  bq[2].precip_mm = NAN;
  assert_forecast_rejected(place, T0, hs, 3, bq, 3, NULL, 0, NULL, 0);
  memcpy(bq, qs, sizeof bq);
  bq[0].precip_mm = -0.5;
  assert_forecast_rejected(place, T0, hs, 3, bq, 3, NULL, 0, NULL, 0);

  /* days */
  WxDay bd[2];
  memcpy(bd, ds, sizeof bd);
  bd[1].start_s = T0;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, bd, 2, NULL, 0);
  memcpy(bd, ds, sizeof bd);
  bd[0].start_s = 5;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, bd, 2, NULL, 0);
  memcpy(bd, ds, sizeof bd);
  bd[1].condition = WX_COND_COUNT;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, bd, 2, NULL, 0);

  /* sources: bad id / state / error code */
  WxSourceStatus s = {(char *)"nws", (char *)"N", (char *)"A", (char *)GOOD_URL, WX_SRC_OK, -1, 0};
  s.provider_id = (char *)"Bad Id";
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, &s, 1);
  s.provider_id = NULL;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, &s, 1);
  s.provider_id = (char *)"nws";
  s.state = (WxSourceState)9;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, &s, 1);
  s.state = WX_SRC_OK;
  s.error_code = 99;
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, &s, 1);
  /* a bad source after a good one: nothing leaks (checked by the leak-free run) */
  WxSourceStatus two[2] = {{(char *)"a", (char *)"N", (char *)"A", (char *)GOOD_URL, WX_SRC_OK, -1, 0},
                           {(char *)"B", (char *)"N", (char *)"A", (char *)GOOD_URL, WX_SRC_OK, -1, 0}};
  assert_forecast_rejected(place, T0, hs, 3, NULL, 0, NULL, 0, two, 2);

  /* hand-built hostile place */
  WxPlace evil = {0};
  assert_forecast_rejected(&evil, T0, hs, 3, NULL, 0, NULL, 0, NULL, 0);
  evil.name = (char *)"x\nx";
  evil.admin1 = (char *)"";
  evil.country = (char *)"";
  evil.timezone = (char *)"";
  assert_forecast_rejected(&evil, T0, hs, 3, NULL, 0, NULL, 0, NULL, 0);
  evil.name = (char *)"ok";
  evil.lat = 100.0;
  assert_forecast_rejected(&evil, T0, hs, 3, NULL, 0, NULL, 0, NULL, 0);

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_forecast_new*");
  g_assert_null(wx_forecast_new(NULL, T0, NULL, 0, NULL, 0, NULL, 0, NULL, 0, NULL));
  g_test_assert_expected_messages();
}

static void
test_forecast_refcount(void)
{
  WxForecast *fc = make_forecast_sized(24, 4, 3, 2);
  g_assert_cmpuint(g_atomic_int_get(&fc->ref_count), ==, 1);
  WxForecast *again = wx_forecast_ref(fc);
  g_assert_true(again == fc);
  g_assert_cmpuint(g_atomic_int_get(&fc->ref_count), ==, 2);
  wx_forecast_unref(again);
  RefArg arg = {NULL, fc};
  GThread *threads[4];
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    threads[i] = g_thread_new("ref", ref_worker, &arg);
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    g_thread_join(threads[i]);
  g_assert_cmpuint(g_atomic_int_get(&fc->ref_count), ==, 1);
  wx_forecast_unref(fc);

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_forecast_ref*");
  g_assert_null(wx_forecast_ref(NULL));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_forecast_unref*");
  wx_forecast_unref(NULL);
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_forecast_get_hours*");
  g_assert_null(wx_forecast_get_hours(NULL, NULL));
  g_test_assert_expected_messages();
}

/* ------------------------------------------------------------------------ */
/* text                                                                     */
/* ------------------------------------------------------------------------ */

static void
assert_sanitized(const char *in, gsize max, const char *expect)
{
  g_autofree char *out = wx_sanitize_text(in, max);
  g_assert_nonnull(out);
  g_assert_cmpstr(out, ==, expect);
  assert_utf8_clean(out);
  g_assert_cmpuint(strlen(out), <=, max);
}

static void
test_sanitize_basic(void)
{
  assert_sanitized(NULL, 100, "");
  assert_sanitized("", 100, "");
  assert_sanitized("Miami", 100, "Miami");
  assert_sanitized("Miami", 0, "");
  assert_sanitized("S\xc3\xa3o Paulo", 100, "S\xc3\xa3o Paulo");
  assert_sanitized("\xe6\x9d\xb1\xe4\xba\xac", 100, "\xe6\x9d\xb1\xe4\xba\xac");
  assert_sanitized("\xf0\x9f\x8c\xa7 rain", 100, "\xf0\x9f\x8c\xa7 rain"); /* astral plane */
  /* controls are stripped */
  assert_sanitized("a\nb\tc\rd", 100, "abcd");
  assert_sanitized("a\x01\x02\x1f" "b", 100, "ab");
  assert_sanitized("a\x7f" "b", 100, "ab");
  assert_sanitized("a\xc2\x80\xc2\x9f" "b", 100, "ab"); /* C1 */
  assert_sanitized("\x1b[31mred\x1b[0m", 100, "[31mred[0m");
  assert_sanitized("\n\n\n", 100, "");
  /* bidi and format overrides */
  assert_sanitized("a\xe2\x80\xaa" "b", 100, "ab");
  assert_sanitized("a\xe2\x80\xab" "b", 100, "ab");
  assert_sanitized("a\xe2\x80\xac" "b", 100, "ab");
  assert_sanitized("a\xe2\x80\xad" "b", 100, "ab");
  assert_sanitized("a\xe2\x80\xae" "b", 100, "ab");
  assert_sanitized("a\xe2\x81\xa6" "b\xe2\x81\xa7" "c\xe2\x81\xa8" "d\xe2\x81\xa9" "e", 100, "abcde");
  assert_sanitized("a\xe2\x80\x8e" "b\xe2\x80\x8f" "c", 100, "abc");
  assert_sanitized("a\xd8\x9c" "b", 100, "ab");        /* U+061C */
  assert_sanitized("a\xe2\x80\xa8" "b\xe2\x80\xa9" "c", 100, "abc"); /* U+2028/9 */
  /* characters next to the forbidden ranges survive */
  assert_sanitized("a\xe2\x80\xa7" "b", 100, "a\xe2\x80\xa7" "b");  /* U+2027 */
  assert_sanitized("a\xe2\x80\xaf" "b", 100, "a\xe2\x80\xaf" "b");  /* U+202F */
  assert_sanitized("a\xe2\x81\xa5" "b", 100, "a\xe2\x81\xa5" "b");  /* U+2065 */
  assert_sanitized("a\xe2\x81\xaa" "b", 100, "a\xe2\x81\xaa" "b");  /* U+206A */
  assert_sanitized("a\xe2\x80\x8d" "b", 100, "a\xe2\x80\x8d" "b");  /* ZWJ is kept */
}

static void
test_sanitize_invalid_utf8(void)
{
  const char *r = "\xef\xbf\xbd"; /* U+FFFD */
  g_autofree char *e1 = g_strconcat("a", r, "b", NULL);
  assert_sanitized("a\xff" "b", 100, e1);
  assert_sanitized("a\xfe" "b", 100, e1);
  assert_sanitized("a\x80" "b", 100, e1);                  /* lone continuation */
  g_autofree char *e2 = g_strconcat("a", r, NULL);
  assert_sanitized("a\xc3", 100, e2);                       /* truncated 2-byte */
  g_autofree char *e3 = g_strconcat("a", r, r, NULL);
  assert_sanitized("a\xe2\x82", 100, e3);                   /* truncated 3-byte */
  g_autofree char *e4 = g_strconcat("a", r, r, r, NULL);
  assert_sanitized("a\xf0\x9f\x8c", 100, e4);               /* truncated 4-byte */
  g_autofree char *e5 = g_strconcat(r, r, NULL);
  assert_sanitized("\xc0\x80", 100, e5);                    /* overlong NUL */
  assert_sanitized("\xc1\xbf", 100, e5);                    /* overlong 0x7f */
  g_autofree char *e6 = g_strconcat(r, r, r, NULL);
  assert_sanitized("\xed\xa0\x80", 100, e6);                /* surrogate D800 */
  g_autofree char *e7 = g_strconcat(r, r, r, r, NULL);
  assert_sanitized("\xf4\x90\x80\x80", 100, e7);            /* > U+10FFFF */
  assert_sanitized("\xf8\x88\x80\x80\x80", 100, "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd"); /* 5-byte */
  /* invalid followed by forbidden */
  g_autofree char *e8 = g_strconcat(r, "x", NULL);
  assert_sanitized("\xff\n" "x", 100, e8);
}

static void
test_sanitize_truncation(void)
{
  assert_sanitized("abcdef", 3, "abc");
  assert_sanitized("abcdef", 6, "abcdef");
  assert_sanitized("abcdef", 7, "abcdef");
  assert_sanitized("abcdef", 1, "a");
  /* never splits a multi-byte character */
  assert_sanitized("\xc3\xa9\xc3\xa9\xc3\xa9", 5, "\xc3\xa9\xc3\xa9");
  assert_sanitized("\xc3\xa9\xc3\xa9\xc3\xa9", 6, "\xc3\xa9\xc3\xa9\xc3\xa9");
  assert_sanitized("\xc3\xa9", 1, "");
  assert_sanitized("\xe6\x9d\xb1\xe4\xba\xac", 5, "\xe6\x9d\xb1");
  assert_sanitized("\xe6\x9d\xb1\xe4\xba\xac", 2, "");
  assert_sanitized("\xf0\x9f\x8c\xa7x", 3, "");
  assert_sanitized("\xf0\x9f\x8c\xa7x", 4, "\xf0\x9f\x8c\xa7");
  /* the documented empty results: nothing fits in fewer bytes than the first kept character */
  assert_sanitized("\xc3\xa9", 1, "");                    /* 2-byte character */
  assert_sanitized("\xe6\x9d\xb1", 2, "");                /* 3-byte character */
  assert_sanitized("\xf0\x9f\x8c\xa7", 3, "");            /* 4-byte character */
  assert_sanitized("\xf0\x9f\x8c\xa7", 4, "\xf0\x9f\x8c\xa7");
  assert_sanitized("\xff", 1, "");                        /* U+FFFD needs 3 bytes */
  assert_sanitized("\xff", 2, "");
  assert_sanitized("\xff", 3, "\xef\xbf\xbd");
  assert_sanitized("\x01\x02\x7f", 100, "");              /* only forbidden characters */
  assert_sanitized("\xe2\x80\xae\xe2\x80\xac", 100, "");
  assert_sanitized("\x01\xc3\xa9", 1, "");                /* forbidden first, kept one too big */
  assert_sanitized("a\xc3\xa9", 2, "a");
  /* non-characters (U+FFFE) are not asserted: GLib versions disagree on their validity */
  /* stripping happens before counting: forbidden characters use no budget */
  assert_sanitized("a\nb\nc\nd", 3, "abc");
  /* the replacement character counts as three bytes */
  assert_sanitized("\xff\xff\xff", 7, "\xef\xbf\xbd\xef\xbf\xbd");

  /* a huge input is cut quickly and exactly */
  g_autofree char *huge = g_strnfill(5 * 1024 * 1024, 'x');
  g_autofree char *out = wx_sanitize_text(huge, 256);
  g_assert_cmpuint(strlen(out), ==, 256);
  g_autofree char *out2 = wx_sanitize_text(huge, 0);
  g_assert_cmpstr(out2, ==, "");
}

/*
 * Deterministic (not timing based) proof that wx_sanitize_text() stops reading once the output
 * is full: the input lives at the start of a page followed by a PROT_NONE guard page, is NOT
 * NUL-terminated, and is "abc" + a run of forbidden characters up to the page end. A scanner
 * that kept consuming the run would walk into the guard page and die with SIGSEGV.
 */
static void
test_sanitize_stops_when_full(void)
{
  long page = sysconf(_SC_PAGESIZE);
  g_assert_cmpint(page, >, 0);
  char *map = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect(map + page, (size_t)page, PROT_NONE), ==, 0);

  /* output exactly full, then only forbidden characters (C0 controls) until the guard */
  memset(map, 0x01, (size_t)page);
  memcpy(map, "abc", 3);
  g_autofree char *full = wx_sanitize_text(map, 3);
  g_assert_cmpstr(full, ==, "abc");

  /* the next kept character does not fit: stop there, even with forbidden text behind it */
  memset(map, 0x01, (size_t)page);
  memcpy(map, "ab\xc3\xa9", 4);
  g_autofree char *nofit = wx_sanitize_text(map, 3);
  g_assert_cmpstr(nofit, ==, "ab");

  /* invalid UTF-8 run behind a full output (each byte would become U+FFFD) */
  memset(map, 0xff, (size_t)page);
  memcpy(map, "abc", 3);
  g_autofree char *inv = wx_sanitize_text(map, 3);
  g_assert_cmpstr(inv, ==, "abc");

  /* a huge forbidden-only tail still yields the right bytes (linear scan is documented) */
  g_autofree char *huge = g_malloc(8 * 1024 * 1024 + 1);
  memset(huge, 0x01, 8 * 1024 * 1024);
  memcpy(huge, "abc", 3);
  huge[8 * 1024 * 1024] = '\0';
  g_autofree char *out = wx_sanitize_text(huge, 3);
  g_assert_cmpstr(out, ==, "abc");

  g_assert_cmpint(munmap(map, (size_t)page * 2), ==, 0);
}

static void
test_sanitize_fuzz(void)
{
  g_autoptr(GRand) rnd = g_rand_new_with_seed(20261011);
  static const guint8 interesting[] = {0x00, 0x0a, 0x1b, 0x7f, 0x80, 0xc2, 0xc3, 0xe2, 0xe0, 0xed,
                                       0xf0, 0xf4, 0xf8, 0xfe, 0xff, 0x9c, 0x8e, 0xae, 0xa8, 'a'};
  for (int iter = 0; iter < 20000; iter++) {
    guint len = g_rand_int_range(rnd, 0, 48);
    guint8 buf[64];
    for (guint i = 0; i < len; i++) {
      buf[i] = (g_rand_int_range(rnd, 0, 3) == 0) ? (guint8)g_rand_int_range(rnd, 0, 256)
                                                  : interesting[g_rand_int_range(rnd, 0, G_N_ELEMENTS(interesting))];
    }
    buf[len] = 0;
    gsize max = (gsize)g_rand_int_range(rnd, 0, 70);
    g_autofree char *out = wx_sanitize_text((const char *)buf, max);
    g_assert_nonnull(out);
    g_assert_cmpuint(strlen(out), <=, max);
    assert_utf8_clean(out);
    /* idempotent: sanitising clean text changes nothing */
    g_autofree char *again = wx_sanitize_text(out, max);
    g_assert_cmpstr(again, ==, out);
    /* the same text as a name is either usable or empty/whitespace */
    g_autofree char *tc = wx_truncated_copy((const char *)buf, (gsize)g_rand_int_range(rnd, 0, 20));
    g_assert_true(g_utf8_validate(tc, -1, NULL));
  }
}

static void
test_usable_name(void)
{
  g_assert_true(wx_text_is_usable_name("Miami", 256));
  g_assert_true(wx_text_is_usable_name("a", 1));
  g_assert_true(wx_text_is_usable_name("S\xc3\xa3o Paulo", 256));
  g_assert_true(wx_text_is_usable_name(" x ", 256));
  g_assert_true(wx_text_is_usable_name("a\xe2\x80\x8d" "b", 256)); /* ZWJ */
  g_assert_false(wx_text_is_usable_name(NULL, 256));
  g_assert_false(wx_text_is_usable_name("", 256));
  g_assert_false(wx_text_is_usable_name("abc", 0));
  g_assert_false(wx_text_is_usable_name("abc", 2));
  g_assert_true(wx_text_is_usable_name("abc", 3));
  g_assert_false(wx_text_is_usable_name("\xc3\xa9", 1));
  g_assert_true(wx_text_is_usable_name("\xc3\xa9", 2));
  g_assert_false(wx_text_is_usable_name("   ", 256));
  g_assert_false(wx_text_is_usable_name("\xe3\x80\x80", 256));  /* ideographic space only */
  g_assert_false(wx_text_is_usable_name("a\nb", 256));
  g_assert_false(wx_text_is_usable_name("a\x01" "b", 256));
  g_assert_false(wx_text_is_usable_name("a\x7f", 256));
  g_assert_false(wx_text_is_usable_name("a\xc2\x9b", 256));
  g_assert_false(wx_text_is_usable_name("a\xe2\x80\xae", 256));
  g_assert_false(wx_text_is_usable_name("a\xe2\x80\x8e", 256));
  g_assert_false(wx_text_is_usable_name("a\xe2\x81\xa9", 256));
  g_assert_false(wx_text_is_usable_name("a\xd8\x9c", 256));
  g_assert_false(wx_text_is_usable_name("a\xe2\x80\xa9", 256));
  g_assert_false(wx_text_is_usable_name("a\xff", 256));
  g_assert_false(wx_text_is_usable_name("a\xed\xa0\x80", 256));
  g_assert_false(wx_text_is_usable_name("a\xc3", 256));
  /* unterminated: nothing past max + 1 is read */
  char big[512];
  memset(big, 'x', sizeof big);
  g_assert_false(wx_text_is_usable_name(big, 256));
  g_assert_true(wx_text_is_usable_name("abc", G_MAXSIZE)); /* max + 1 must not overflow */
  g_autofree char *exact = g_strnfill(256, 'x');
  g_assert_true(wx_text_is_usable_name(exact, 256));
  g_autofree char *over = g_strnfill(257, 'x');
  g_assert_false(wx_text_is_usable_name(over, 256));
}

static void
test_truncated_copy(void)
{
  g_autofree char *a = wx_truncated_copy("hello world", 5);
  g_assert_cmpstr(a, ==, "hello");
  g_autofree char *b = wx_truncated_copy("hello", 5);
  g_assert_cmpstr(b, ==, "hello");
  g_autofree char *c = wx_truncated_copy("hello", 50);
  g_assert_cmpstr(c, ==, "hello");
  g_autofree char *d = wx_truncated_copy("hello", 0);
  g_assert_cmpstr(d, ==, "");
  g_autofree char *e = wx_truncated_copy(NULL, 5);
  g_assert_cmpstr(e, ==, "");
  g_autofree char *f = wx_truncated_copy("", 5);
  g_assert_cmpstr(f, ==, "");
  /* characters, not bytes */
  g_autofree char *g = wx_truncated_copy("\xc3\xa9\xc3\xa9\xc3\xa9", 2);
  g_assert_cmpstr(g, ==, "\xc3\xa9\xc3\xa9");
  g_autofree char *h = wx_truncated_copy("\xe6\x9d\xb1\xe4\xba\xac\xe9\x83\xbd", 1);
  g_assert_cmpstr(h, ==, "\xe6\x9d\xb1");
  g_autofree char *i = wx_truncated_copy("\xf0\x9f\x8c\xa7x", 1);
  g_assert_cmpstr(i, ==, "\xf0\x9f\x8c\xa7");
  /* stops before invalid UTF-8 */
  g_autofree char *j = wx_truncated_copy("ab\xffzz", 10);
  g_assert_cmpstr(j, ==, "ab");
  g_autofree char *k = wx_truncated_copy("ab\xc3", 10);
  g_assert_cmpstr(k, ==, "ab");
  g_autofree char *l = wx_truncated_copy("\xff", 10);
  g_assert_cmpstr(l, ==, "");
  /* (whether U+FFFF-style non-characters count as valid depends on the GLib version: unasserted) */
  g_autofree char *l3 = wx_truncated_copy("ab\xed\xa0\x80" "cd", 10); /* surrogate */
  g_assert_cmpstr(l3, ==, "ab");
  g_autofree char *l4 = wx_truncated_copy("ab\xf4\x90\x80\x80", 10);   /* above U+10FFFF */
  g_assert_cmpstr(l4, ==, "ab");
  g_autofree char *l5 = wx_truncated_copy("ab\xc0\xaf" "cd", 10);      /* overlong '/' */
  g_assert_cmpstr(l5, ==, "ab");
  /* does not read the whole of a huge string */
  g_autofree char *huge = g_strnfill(4 * 1024 * 1024, 'x');
  g_autofree char *m = wx_truncated_copy(huge, 8);
  g_assert_cmpstr(m, ==, "xxxxxxxx");
}

/* ------------------------------------------------------------------------ */
/* time                                                                     */
/* ------------------------------------------------------------------------ */

static void
assert_iso(const char *s, gint64 expect)
{
  gint64 t = -12345;
  g_assert_true(wx_time_parse_iso8601(s, &t));
  g_assert_cmpint(t, ==, expect);
}

static void
assert_iso_rejected(const char *s)
{
  gint64 t = -12345;
  g_assert_false(wx_time_parse_iso8601(s, &t));
  g_assert_cmpint(t, ==, -12345); /* untouched on failure */
}

static void
test_iso8601_valid(void)
{
  assert_iso("2026-10-11T00:00:00Z", T0);
  assert_iso("2026-10-11T00:00:00+00:00", T0);
  assert_iso("2026-10-11T00:00:00-00:00", T0);
  assert_iso("2026-10-11T00:00:00.000Z", T0);
  assert_iso("2026-10-11T00:00:00.999Z", T0);              /* fraction truncated */
  assert_iso("2026-10-11T00:00:00.123456789012Z", T0);
  assert_iso("2026-10-11T00:00:00.5+00:00", T0);
  assert_iso("2026-10-11T01:00:00+01:00", T0);
  assert_iso("2026-10-10T20:00:00-04:00", T0);
  assert_iso("2026-10-11T05:30:00+05:30", T0);
  assert_iso("2026-10-11T05:45:00+05:45", T0);             /* Nepal */
  assert_iso("2026-10-10T12:15:00-11:45", T0);
  assert_iso("2026-10-11T23:59:00+23:59", T0);
  assert_iso("2026-10-10T00:01:00-23:59", T0);
  assert_iso("2000-01-01T00:00:00Z", 946684800);
  assert_iso("2000-02-29T12:00:00Z", 951825600);           /* 2000 is leap (div by 400) */
  assert_iso("2100-12-31T23:59:59Z", 4133980799);
  assert_iso("2024-02-29T23:59:59Z", 1709251199);
  assert_iso("2038-01-19T03:14:08Z", 2147483648);          /* past the 32-bit limit */
  assert_iso("2026-10-11T00:00:00.5-04:00", T0 + 4 * 3600);
  /* the converted instant may leave 2000..2100 by the offset */
  assert_iso("2000-01-01T00:00:00+01:00", 946684800 - 3600);
  assert_iso("2100-12-31T23:59:59-01:00", 4133980799 + 3600);
}

static void
test_iso8601_rejects(void)
{
  const char *bad[] = {
    "", "2026", "2026-10-11", "2026-10-11T00:00:00", "2026-10-11T00:00Z",
    "2026-10-11T00:00:00z", "2026-10-11t00:00:00Z", "2026-10-11 00:00:00Z",
    "2026-10-11T00:00:00 Z", " 2026-10-11T00:00:00Z", "2026-10-11T00:00:00Z ",
    "2026-10-11T00:00:00Z\n", "2026-10-11T00:00:00ZZ", "2026-10-11T00:00:00+0000",
    "2026-10-11T00:00:00+00", "2026-10-11T00:00:00+00:0", "2026-10-11T00:00:00+0:00",
    "2026-10-11T00:00:00+00:000", "2026-10-11T00:00:00+00.00", "2026-10-11T00:00:00+24:00",
    "2026-10-11T00:00:00+00:60", "2026-10-11T00:00:00-24:00", "2026-10-11T00:00:00+ab:cd",
    "2026-10-11T00:00:00.Z", "2026-10-11T00:00:00.", "2026-10-11T00:00:00,5Z",
    "2026-10-11T00:00:00.5", "2026-10-11T00:00:00.5.5Z", "2026-10-11T00:00:00.5xZ",
    "2026-10-11T00:00:60Z", "2026-10-11T00:60:00Z", "2026-10-11T24:00:00Z",
    "2026-10-11T24:00:01Z", "2026-13-11T00:00:00Z", "2026-00-11T00:00:00Z",
    "2026-10-00T00:00:00Z", "2026-10-32T00:00:00Z", "2026-04-31T00:00:00Z",
    "2026-02-29T00:00:00Z", "2100-02-29T00:00:00Z", "1900-02-28T00:00:00Z",
    "1999-12-31T23:59:59Z", "2101-01-01T00:00:00Z", "9999-12-31T23:59:59Z",
    "0000-01-01T00:00:00Z", "2026/10/11T00:00:00Z", "2026-10-11T00-00-00Z",
    "26-10-11T00:00:00Z", "+2026-10-11T00:00:00Z", "2026-1-11T00:00:00Z",
    "2026-10-1T00:00:00Z", "2026-10-11T0:00:00Z", "2026-10-11T00:00:00\xc2\xa0Z",
    "20261011T000000Z", "2026-W41-7T00:00:00Z", "2026-10-11T00:00:00Z+01:00",
    "2026-10-11T00:00:0\x00" "0Z", "-026-10-11T00:00:00Z", "2026-10-11T00:00:+1Z",
    "2026-10-11T00:-1:00Z", "2026-10-11T 0:00:00Z", "2026-10-11T00:00:00\xff",
    "2026-10-11T00:00:00+00:00\n", "2026-10-11T00:00:00.123456789012345678901234567890Z",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_test_message("case %u: %s", i, bad[i]);
    assert_iso_rejected(bad[i]);
  }
  assert_iso_rejected(NULL);

  /* length bound: 40 bytes accepted, 41 rejected */
  g_autofree char *ok40 = g_strdup("2026-10-11T00:00:00.1234567890123456789Z"); /* 40 bytes */
  g_assert_cmpuint(strlen(ok40), ==, 40);
  assert_iso(ok40, T0);
  g_autofree char *bad41 = g_strdup("2026-10-11T00:00:00.12345678901234567890Z");
  g_assert_cmpuint(strlen(bad41), ==, 41);
  assert_iso_rejected(bad41);

  /* unterminated buffer: only 41 bytes are inspected */
  char big[256];
  memset(big, '1', sizeof big);
  assert_iso_rejected(big);

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_time_parse_iso8601*");
  g_assert_false(wx_time_parse_iso8601("2026-10-11T00:00:00Z", NULL));
  g_test_assert_expected_messages();
}

static void
test_iso8601_calendar(void)
{
  /* every day of two years, leap and non-leap, against GDateTime */
  for (int year = 2023; year <= 2024; year++) {
    for (int month = 1; month <= 12; month++) {
      for (int day = 1; day <= 31; day++) {
        g_autofree char *s = g_strdup_printf("%04d-%02d-%02dT13:14:15Z", year, month, day);
        g_autoptr(GDateTime) dt = g_date_time_new_utc(year, month, day, 13, 14, 15.0);
        gint64 t = 0;
        if (dt == NULL) {
          g_assert_false(wx_time_parse_iso8601(s, &t)); /* e.g. 2023-02-29, 04-31 */
        } else {
          g_assert_true(wx_time_parse_iso8601(s, &t));
          g_assert_cmpint(t, ==, g_date_time_to_unix(dt));
        }
      }
    }
  }
  /* century rules */
  gint64 t;
  g_assert_true(wx_time_parse_iso8601("2000-02-29T00:00:00Z", &t));
  g_assert_true(wx_time_parse_iso8601("2096-02-29T00:00:00Z", &t));
  g_assert_false(wx_time_parse_iso8601("2100-02-29T00:00:00Z", &t));
  g_assert_false(wx_time_parse_iso8601("2001-02-29T00:00:00Z", &t));
  g_assert_false(wx_time_parse_iso8601("2025-02-29T00:00:00Z", &t));
  g_assert_true(wx_time_parse_iso8601("2028-02-29T00:00:00Z", &t));
}

static void
test_iso8601_roundtrip_fuzz(void)
{
  g_autoptr(GRand) rnd = g_rand_new_with_seed(424242);
  for (int i = 0; i < 20000; i++) {
    gint64 want = WX_TIME_MIN_S + (gint64)g_rand_double_range(rnd, 0, (double)(4133980799 - WX_TIME_MIN_S));
    g_autoptr(GDateTime) dt = g_date_time_new_from_unix_utc(want);
    g_assert_nonnull(dt);
    int offset_min = g_rand_int_range(rnd, -23 * 60 - 59, 23 * 60 + 60);
    gint64 local = want + (gint64)offset_min * 60;
    g_autoptr(GDateTime) lt = g_date_time_new_from_unix_utc(local);
    int y = g_date_time_get_year(lt);
    if (y < 2000 || y > 2100)
      continue;
    g_autofree char *s = g_strdup_printf("%04d-%02d-%02dT%02d:%02d:%02d%s%c%02d:%02d", y,
                                         g_date_time_get_month(lt), g_date_time_get_day_of_month(lt),
                                         g_date_time_get_hour(lt), g_date_time_get_minute(lt),
                                         g_date_time_get_second(lt), (i % 3 == 0) ? ".25" : "",
                                         offset_min < 0 ? '-' : '+', abs(offset_min) / 60,
                                         abs(offset_min) % 60);
    gint64 t = 0;
    g_assert_true(wx_time_parse_iso8601(s, &t));
    g_assert_cmpint(t, ==, want);
    g_assert_true(g_date_time_to_unix(dt) == want);
  }
}

static void
test_iso8601_mutation_fuzz(void)
{
  g_autoptr(GRand) rnd = g_rand_new_with_seed(77);
  const char *base = "2026-10-11T18:30:45.123+05:30";
  static const char junk[] = "0129-:T.+Zz /\n\xff\x80" "a";
  for (int i = 0; i < 40000; i++) {
    char buf[64];
    g_strlcpy(buf, base, sizeof buf);
    guint flips = g_rand_int_range(rnd, 1, 4);
    for (guint f = 0; f < flips; f++) {
      guint pos = g_rand_int_range(rnd, 0, (gint)strlen(buf) + 1);
      switch (g_rand_int_range(rnd, 0, 3)) {
      case 0:
        if (pos < strlen(buf))
          buf[pos] = junk[g_rand_int_range(rnd, 0, (gint)sizeof junk - 1)];
        break;
      case 1:
        if (pos < strlen(buf))
          memmove(buf + pos, buf + pos + 1, strlen(buf + pos));
        break;
      default:
        if (strlen(buf) < 50) {
          memmove(buf + pos + 1, buf + pos, strlen(buf + pos) + 1);
          buf[pos] = junk[g_rand_int_range(rnd, 0, (gint)sizeof junk - 1)];
        }
        break;
      }
    }
    gint64 t = 777;
    if (wx_time_parse_iso8601(buf, &t)) {
      /* anything accepted must re-parse identically and fit the profile */
      g_assert_cmpuint(strlen(buf), <=, WX_TIME_ISO8601_MAX_LEN);
      g_assert_true(buf[10] == 'T');
      g_assert_true(t > WX_TIME_MIN_S - 2 * 86400 && t < WX_TIME_MAX_S + 2 * 86400);
    } else {
      g_assert_cmpint(t, ==, 777);
    }
  }
}

static void
assert_dur(const char *s, gint64 expect)
{
  gint64 v = -1;
  g_test_message("duration %s", s);
  g_assert_true(wx_time_parse_iso8601_duration(s, &v));
  g_assert_cmpint(v, ==, expect);
}

static void
assert_dur_rejected(const char *s)
{
  gint64 v = -777;
  g_test_message("duration (reject) %s", s ? s : "(null)");
  g_assert_false(wx_time_parse_iso8601_duration(s, &v));
  g_assert_cmpint(v, ==, -777);
}

static void
test_duration(void)
{
  assert_dur("PT1H", 3600);
  assert_dur("PT3H", 3 * 3600);
  assert_dur("PT30M", 1800);
  assert_dur("PT45S", 45);
  assert_dur("PT1H30M", 5400);
  assert_dur("PT1H30M15S", 5415);
  assert_dur("PT0S", 0);
  assert_dur("PT0H", 0);
  assert_dur("P1D", 86400);
  assert_dur("P2D", 172800);
  assert_dur("P1DT12H", 86400 + 43200);
  assert_dur("P1DT1H1M1S", 86400 + 3661);
  assert_dur("P0D", 0);
  assert_dur("PT24H", 86400);
  assert_dur("PT36H", 129600);
  assert_dur("PT01H", 3600);                       /* leading zeros ok */
  assert_dur("P31D", 31 * 86400);
  assert_dur("PT744H", 31 * 86400);
  assert_dur("P30DT24H", 31 * 86400);
  assert_dur("PT44640M", 31 * 86400);
  assert_dur("PT2678400S", 31 * 86400);

  assert_dur_rejected(NULL);
  assert_dur_rejected("");
  assert_dur_rejected("P");
  assert_dur_rejected("PT");
  assert_dur_rejected("P1DT");
  assert_dur_rejected("T1H");
  assert_dur_rejected("1H");
  assert_dur_rejected("pt1h");
  assert_dur_rejected("PT1h");
  assert_dur_rejected("P1d");
  assert_dur_rejected("PT1");
  assert_dur_rejected("P1");
  assert_dur_rejected("PTH");
  assert_dur_rejected("PT1H1H");
  assert_dur_rejected("PT30M1H");                  /* order matters */
  assert_dur_rejected("PT1S1M");
  assert_dur_rejected("P1D1D");
  assert_dur_rejected("PT1HT1M");
  assert_dur_rejected("P1H");                      /* H outside T */
  assert_dur_rejected("P1M");                      /* months not supported */
  assert_dur_rejected("P1Y");
  assert_dur_rejected("P1W");
  assert_dur_rejected("P1Y2M3DT4H");
  assert_dur_rejected("PT1D");                     /* D inside T */
  assert_dur_rejected("-PT1H");
  assert_dur_rejected("PT-1H");
  assert_dur_rejected("+PT1H");
  assert_dur_rejected("PT1.5H");
  assert_dur_rejected("PT1,5H");
  assert_dur_rejected("PT0.5S");
  assert_dur_rejected("PT 1H");
  assert_dur_rejected("PT1H ");
  assert_dur_rejected(" PT1H");
  assert_dur_rejected("PT1H\n");
  assert_dur_rejected("PT1H/");
  assert_dur_rejected("PT\xd9\xa1H");              /* Arabic-indic digit */
  assert_dur_rejected("P32D");                     /* > 31 days */
  assert_dur_rejected("P31DT1S");
  assert_dur_rejected("PT745H");
  assert_dur_rejected("PT44641M");
  assert_dur_rejected("PT2678401S");
  assert_dur_rejected("P99999999D");               /* 8 digits: no overflow */
  assert_dur_rejected("P999999999D");              /* 9 digits */
  assert_dur_rejected("PT99999999999999999999S");
  assert_dur_rejected("PT99999999H99999999M99999999S");
  assert_dur_rejected("P1DT1H1M1SX");
  /* length bound */
  assert_dur_rejected("PT0000000000000000000000000000000000000001S");
  /* Unterminated buffer: the parser may read at most WX_TIME_DURATION_MAX_LEN + 1 bytes. It is
   * deliberately NOT passed to assert_dur_rejected(), whose %s logging would read past the end. */
  char big[256];
  memset(big, 'P', sizeof big);
  gint64 untouched = -777;
  g_assert_false(wx_time_parse_iso8601_duration(big, &untouched));
  g_assert_cmpint(untouched, ==, -777);
  memset(big, '1', sizeof big);
  big[0] = 'P';
  big[1] = 'T';
  g_assert_false(wx_time_parse_iso8601_duration(big, &untouched));
  g_assert_cmpint(untouched, ==, -777);

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_time_parse_iso8601_duration*");
  g_assert_false(wx_time_parse_iso8601_duration("PT1H", NULL));
  g_test_assert_expected_messages();
}

static void
test_interval(void)
{
  gint64 s = 0, d = 0;
  g_assert_true(wx_time_parse_interval("2026-10-11T00:00:00+00:00/PT1H", &s, &d));
  g_assert_cmpint(s, ==, T0);
  g_assert_cmpint(d, ==, 3600);
  g_assert_true(wx_time_parse_interval("2026-10-10T20:00:00-04:00/PT3H30M", &s, &d));
  g_assert_cmpint(s, ==, T0);
  g_assert_cmpint(d, ==, 3 * 3600 + 1800);
  g_assert_true(wx_time_parse_interval("2026-10-11T00:00:00Z/P1DT6H", &s, &d));
  g_assert_cmpint(d, ==, 86400 + 6 * 3600);
  g_assert_true(wx_time_parse_interval("2026-10-11T00:00:00Z/P7D", &s, &d));
  g_assert_cmpint(d, ==, 7 * 86400);

  /* failures leave both outputs untouched */
  s = 111;
  d = 222;
  const char *bad[] = {
    NULL, "", "/", "/PT1H", "2026-10-11T00:00:00Z/", "2026-10-11T00:00:00Z",
    "PT1H", "2026-10-11T00:00:00Z/PT0S", "2026-10-11T00:00:00Z/P0D",
    "2026-10-11T00:00:00Z/PT1H/", "2026-10-11T00:00:00Z//PT1H",
    "2026-10-11T00:00:00Z/PT1H/PT1H", "2026-10-11/PT1H", "2026-10-11T00:00:00/PT1H",
    "2026-10-11T00:00:00Z/1H", "2026-10-11T00:00:00Z/P32D", "2026-10-11T00:00:00Z/pt1h",
    "2026-10-11T00:00:00Z / PT1H", " 2026-10-11T00:00:00Z/PT1H", "2026-10-11T00:00:00Z/PT1H ",
    "2026-13-11T00:00:00Z/PT1H", "2026-10-11T00:00:00Z/PT1H\n",
    "PT1H/2026-10-11T00:00:00Z", "2026-10-11T00:00:00Z/2026-10-12T00:00:00Z",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_test_message("interval (reject) %s", bad[i] ? bad[i] : "(null)");
    g_assert_false(wx_time_parse_interval(bad[i], &s, &d));
    g_assert_cmpint(s, ==, 111);
    g_assert_cmpint(d, ==, 222);
  }
  /* a failing duration must not leave a half-written start */
  g_assert_false(wx_time_parse_interval("2026-10-11T00:00:00Z/P32D", &s, &d));
  g_assert_cmpint(s, ==, 111);

  /* length bound: whole interval <= 80 bytes, start part <= 40 */
  g_autofree char *long_start = g_strdup_printf("2026-10-11T00:00:00.%sZ/PT1H",
                                                "12345678901234567890123456789012345");
  g_assert_false(wx_time_parse_interval(long_start, &s, &d));
  char big[300];
  memset(big, '/', sizeof big);
  g_assert_false(wx_time_parse_interval(big, &s, &d));
  memset(big, 'x', sizeof big);
  g_assert_false(wx_time_parse_interval(big, &s, &d));

  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_time_parse_interval*");
  g_assert_false(wx_time_parse_interval("2026-10-11T00:00:00Z/PT1H", NULL, &d));
  g_test_assert_expected_messages();
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_time_parse_interval*");
  g_assert_false(wx_time_parse_interval("2026-10-11T00:00:00Z/PT1H", &s, NULL));
  g_test_assert_expected_messages();
}

static void
test_duration_interval_fuzz(void)
{
  g_autoptr(GRand) rnd = g_rand_new_with_seed(99);
  static const char alphabet[] = "PT0123456789DHMSYW.-+/:Z \n";
  for (int i = 0; i < 60000; i++) {
    char buf[96];
    guint len = g_rand_int_range(rnd, 0, 60);
    for (guint k = 0; k < len; k++)
      buf[k] = alphabet[g_rand_int_range(rnd, 0, (gint)sizeof alphabet - 1)];
    buf[len] = 0;
    gint64 v = -5, s = -5, d = -5;
    if (wx_time_parse_iso8601_duration(buf, &v))
      g_assert_true(v >= 0 && v <= WX_TIME_DURATION_MAX_S);
    else
      g_assert_cmpint(v, ==, -5);
    if (wx_time_parse_interval(buf, &s, &d))
      g_assert_true(d >= 1 && d <= WX_TIME_DURATION_MAX_S);
    else
      g_assert_true(s == -5 && d == -5);
  }
  /* structured mutation: valid durations with random single-character damage */
  const char *base = "P1DT2H3M4S";
  for (int i = 0; i < 20000; i++) {
    char buf[32];
    g_strlcpy(buf, base, sizeof buf);
    buf[g_rand_int_range(rnd, 0, (gint)strlen(base))] = alphabet[g_rand_int_range(rnd, 0, (gint)sizeof alphabet - 1)];
    gint64 v = -5;
    if (wx_time_parse_iso8601_duration(buf, &v))
      g_assert_true(v >= 0 && v <= WX_TIME_DURATION_MAX_S);
  }
}

/* ------------------------------------------------------------------------ */
/* geo                                                                      */
/* ------------------------------------------------------------------------ */

static void
test_geo_round_valid(void)
{
  /* the scaled value must not overflow into an infinity: NAN, never +-INFINITY */
  g_assert_true(isnan(wx_geo_round4(1e305)));
  g_assert_true(isnan(wx_geo_round4(-1e305)));
  g_assert_true(isnan(wx_geo_round4(G_MAXDOUBLE)));
  g_assert_true(isnan(wx_geo_round4(-G_MAXDOUBLE)));
  g_assert_cmpfloat(fabs(wx_geo_round4(1e300) - 1e300), <=, 1e286); /* finite, relative 1e-14 */
  g_assert_cmpfloat(wx_geo_round4(1e-300), ==, 0.0); /* underflows to +0 */
  g_assert_false(signbit(wx_geo_round4(-1e-300)));
  /* rounding keeps valid coordinates valid: the bounds are multiples of 0.0001 */
  g_assert_cmpfloat(wx_geo_round4(90.00004), ==, 90.0);
  g_assert_cmpfloat(wx_geo_round4(-180.00004), ==, -180.0);
  g_assert_true(wx_geo_valid(wx_geo_round4(89.99996), wx_geo_round4(179.99996)));
  g_assert_cmpfloat(wx_geo_round4(25.76174), ==, 25.7617);
  g_assert_cmpfloat(wx_geo_round4(25.76176), ==, 25.7618);
  g_assert_cmpfloat(wx_geo_round4(-80.19184), ==, -80.1918);
  g_assert_cmpfloat(wx_geo_round4(-80.19186), ==, -80.1919);
  g_assert_cmpfloat(wx_geo_round4(0.0), ==, 0.0);
  g_assert_false(signbit(wx_geo_round4(-0.00001)));         /* -0 normalised */
  g_assert_false(signbit(wx_geo_round4(-0.0)));
  g_assert_cmpfloat(wx_geo_round4(180.0), ==, 180.0);
  g_assert_cmpfloat(wx_geo_round4(-90.0), ==, -90.0);
  g_assert_true(isnan(wx_geo_round4(NAN)));
  g_assert_true(isnan(wx_geo_round4(INFINITY)));
  g_assert_true(isnan(wx_geo_round4(-INFINITY)));

  g_assert_true(wx_geo_valid(0, 0));
  g_assert_true(wx_geo_valid(90, 180));
  g_assert_true(wx_geo_valid(-90, -180));
  g_assert_false(wx_geo_valid(90.0001, 0));
  g_assert_false(wx_geo_valid(0, 180.0001));
  g_assert_false(wx_geo_valid(-91, 0));
  g_assert_false(wx_geo_valid(0, -181));
  g_assert_false(wx_geo_valid(NAN, 0));
  g_assert_false(wx_geo_valid(0, NAN));
  g_assert_false(wx_geo_valid(INFINITY, 0));
  g_assert_false(wx_geo_valid(0, -INFINITY));
}

static void
test_geo_boxes(void)
{
  /* NWS coverage */
  g_assert_true(wx_geo_in_us_nws(25.7617, -80.1918));   /* Miami */
  g_assert_true(wx_geo_in_us_nws(24.55, -81.78));       /* Key West */
  g_assert_true(wx_geo_in_us_nws(40.71, -74.0));        /* New York */
  g_assert_true(wx_geo_in_us_nws(47.61, -122.33));      /* Seattle */
  g_assert_true(wx_geo_in_us_nws(32.72, -117.16));      /* San Diego */
  g_assert_true(wx_geo_in_us_nws(44.8, -68.8));         /* Maine */
  g_assert_true(wx_geo_in_us_nws(61.22, -149.9));       /* Anchorage */
  g_assert_true(wx_geo_in_us_nws(64.84, -147.72));      /* Fairbanks */
  g_assert_true(wx_geo_in_us_nws(71.29, -156.79));      /* Utqiagvik */
  g_assert_true(wx_geo_in_us_nws(53.89, -166.54));      /* Dutch Harbor */
  g_assert_true(wx_geo_in_us_nws(52.2, 174.2));         /* Attu, west of 180 */
  g_assert_true(wx_geo_in_us_nws(21.31, -157.86));      /* Honolulu */
  g_assert_true(wx_geo_in_us_nws(19.7, -155.09));       /* Hilo */
  g_assert_true(wx_geo_in_us_nws(18.47, -66.1));        /* San Juan */
  g_assert_true(wx_geo_in_us_nws(18.34, -64.93));       /* Charlotte Amalie */
  g_assert_true(wx_geo_in_us_nws(13.47, 144.75));       /* Guam */
  g_assert_false(wx_geo_in_us_nws(51.5074, -0.1278));   /* London */
  g_assert_false(wx_geo_in_us_nws(-33.87, 151.21));     /* Sydney */
  g_assert_false(wx_geo_in_us_nws(35.68, 139.69));      /* Tokyo */
  g_assert_false(wx_geo_in_us_nws(19.43, -99.13));      /* Mexico City */
  g_assert_false(wx_geo_in_us_nws(23.1, -82.4));        /* Havana, south of the box */
  g_assert_false(wx_geo_in_us_nws(0, 0));
  g_assert_false(wx_geo_in_us_nws(-89, 0));
  g_assert_false(wx_geo_in_us_nws(NAN, -80));
  g_assert_false(wx_geo_in_us_nws(25, NAN));
  g_assert_false(wx_geo_in_us_nws(INFINITY, -80));
  g_assert_false(wx_geo_in_us_nws(95, -80));            /* invalid latitude */
  g_assert_false(wx_geo_in_us_nws(40, 260));            /* invalid longitude */

  /* CONUS box */
  g_assert_true(wx_geo_in_conus(25.7617, -80.1918));
  g_assert_true(wx_geo_in_conus(21.0, -135.0));
  g_assert_true(wx_geo_in_conus(53.0, -60.0));
  g_assert_false(wx_geo_in_conus(20.99, -100.0));
  g_assert_false(wx_geo_in_conus(53.01, -100.0));
  g_assert_false(wx_geo_in_conus(40.0, -135.01));
  g_assert_false(wx_geo_in_conus(40.0, -59.99));
  g_assert_false(wx_geo_in_conus(51.5, -0.12));
  g_assert_false(wx_geo_in_conus(21.31, -157.86));      /* Hawaii is outside HRRR conus */
  g_assert_false(wx_geo_in_conus(NAN, -100));

  /* Europe box */
  g_assert_true(wx_geo_in_europe(51.5074, -0.1278));
  g_assert_true(wx_geo_in_europe(34.0, -25.0));
  g_assert_true(wx_geo_in_europe(72.0, 45.0));
  g_assert_true(wx_geo_in_europe(59.91, 10.75));        /* Oslo */
  g_assert_false(wx_geo_in_europe(33.99, 10));
  g_assert_false(wx_geo_in_europe(72.01, 10));
  g_assert_false(wx_geo_in_europe(50, -25.01));
  g_assert_false(wx_geo_in_europe(50, 45.01));
  g_assert_false(wx_geo_in_europe(25.76, -80.19));
  g_assert_false(wx_geo_in_europe(NAN, 0));
  g_assert_false(wx_geo_in_europe(0, INFINITY));
}

static void
test_geo_distance(void)
{
  g_assert_cmpfloat(wx_geo_distance_km(10, 20, 10, 20), ==, 0.0);
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(25.7617, -80.1918, 51.5074, -0.1278), 7126.9, 1.0);
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(0, 0, 0, 1), 111.195, 0.01);
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(0, 0, 1, 0), 111.195, 0.01);
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(0, 0, 0, 180), 20015.1, 0.1);   /* antipodes */
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(90, 0, -90, 0), 20015.1, 0.1);  /* poles */
  g_assert_cmpfloat_with_epsilon(wx_geo_distance_km(0, 179.9, 0, -179.9), 22.239, 0.01); /* date line */
  /* symmetric and never negative */
  g_assert_cmpfloat(wx_geo_distance_km(-33.87, 151.21, 51.5, -0.12), ==,
                    wx_geo_distance_km(51.5, -0.12, -33.87, 151.21));
  g_autoptr(GRand) rnd = g_rand_new_with_seed(5);
  for (int i = 0; i < 5000; i++) {
    double a = g_rand_double_range(rnd, -90, 90), b = g_rand_double_range(rnd, -180, 180);
    double c = g_rand_double_range(rnd, -90, 90), d = g_rand_double_range(rnd, -180, 180);
    double km = wx_geo_distance_km(a, b, c, d);
    g_assert_true(km >= 0.0 && km <= 20015.12);
  }
  /* invalid points are NAN, not a crash */
  g_assert_true(isnan(wx_geo_distance_km(NAN, 0, 0, 0)));
  g_assert_true(isnan(wx_geo_distance_km(0, 0, 91, 0)));
  g_assert_true(isnan(wx_geo_distance_km(0, 0, 0, 181)));
  g_assert_true(isnan(wx_geo_distance_km(0, INFINITY, 0, 0)));
}

/* Sunrise/sunset instants from the U.S. Naval Observatory (aa.usno.navy.mil/api/rstt/oneday, fetched
 * 2026-10-11; minute resolution, so each is good to +-30 s) for 2026-10-11 and the 2026 solstices
 * (Miami, London, Sydney) and for polar-summer days where the sun dips below the horizon only
 * briefly (Reykjavik, Fairbanks, Murmansk, Tromso), in local civil time. The test bisects
 * wx_sun_is_up() around each instant and requires its transition within 90 s of the table value
 * (30 s table rounding + 60 s algorithm) at |lat| <= 60, and within 150 s at the high-latitude
 * rows, where the sun merely skims the horizon (see the comment at the assertion). */
#define SUN_TOLERANCE_S 90
#define SUN_POLAR_TOLERANCE_S 150
typedef struct {
  const char *city;
  double lat, lon;
  const char *when; /* RFC 3339, local time */
  gboolean rising;  /* TRUE: the sun comes up at that instant, FALSE: it goes down */
} SunEvent;

static const SunEvent sun_events[] = {
  {"Miami 2026-10-11", 25.7617, -80.1918, "2026-10-11T07:18:00-04:00", TRUE},
  {"Miami 2026-10-11", 25.7617, -80.1918, "2026-10-11T18:57:00-04:00", FALSE},
  {"London 2026-10-11", 51.5074, -0.1278, "2026-10-11T07:18:00+01:00", TRUE},
  {"London 2026-10-11", 51.5074, -0.1278, "2026-10-11T18:16:00+01:00", FALSE},
  {"Sydney 2026-10-11", -33.8688, 151.2093, "2026-10-11T06:19:00+11:00", TRUE},
  {"Sydney 2026-10-11", -33.8688, 151.2093, "2026-10-11T19:05:00+11:00", FALSE},
  {"London 2026-06-21", 51.5074, -0.1278, "2026-06-21T04:43:00+01:00", TRUE},
  {"London 2026-06-21", 51.5074, -0.1278, "2026-06-21T21:22:00+01:00", FALSE},
  {"Miami 2026-12-21", 25.7617, -80.1918, "2026-12-21T07:03:00-05:00", TRUE},
  {"Miami 2026-12-21", 25.7617, -80.1918, "2026-12-21T17:35:00-05:00", FALSE},
  {"Sydney 2026-12-21", -33.8688, 151.2093, "2026-12-21T05:41:00+11:00", TRUE},
  {"Sydney 2026-12-21", -33.8688, 151.2093, "2026-12-21T20:05:00+11:00", FALSE},
  {"Reykjavik 2026-06-21", 64.1466, -21.9426, "2026-06-21T00:04:00+00:00", FALSE},
  {"Reykjavik 2026-06-21", 64.1466, -21.9426, "2026-06-21T02:55:00+00:00", TRUE},
  {"Fairbanks 2026-06-21", 64.8378, -147.7164, "2026-06-21T00:47:00-08:00", FALSE},
  {"Fairbanks 2026-06-21", 64.8378, -147.7164, "2026-06-21T02:58:00-08:00", TRUE},
  {"Murmansk 2026-07-25", 68.9585, 33.0827, "2026-07-25T00:02:00+03:00", FALSE},
  {"Murmansk 2026-07-25", 68.9585, 33.0827, "2026-07-25T01:47:00+03:00", TRUE},
  {"Murmansk 2026-07-25", 68.9585, 33.0827, "2026-07-25T23:52:00+03:00", FALSE},
  {"Tromso 2026-07-26", 69.6492, 18.9553, "2026-07-26T00:36:00+02:00", FALSE},
  {"Tromso 2026-07-26", 69.6492, 18.9553, "2026-07-26T01:06:00+02:00", TRUE},
};

static void
test_sun_is_up_usno_transitions(void)
{
  for (guint i = 0; i < G_N_ELEMENTS(sun_events); i++) {
    const SunEvent *e = &sun_events[i];
    gint64 want = 0;
    g_assert_true(wx_time_parse_iso8601(e->when, &want));
    /* the instants are 10 minutes either side of the event: the sun must be on the expected
     * side there, otherwise the bisection below would not bracket a transition */
    gint64 lo = want - 600, hi = want + 600;
    g_assert_cmpint(wx_sun_is_up(e->lat, e->lon, lo), ==, !e->rising);
    g_assert_cmpint(wx_sun_is_up(e->lat, e->lon, hi), ==, e->rising);
    while (hi - lo > 1) {
      gint64 mid = lo + (hi - lo) / 2;
      if (wx_sun_is_up(e->lat, e->lon, mid) == wx_sun_is_up(e->lat, e->lon, lo))
        lo = mid;
      else
        hi = mid;
    }
    /* hi is the first second of the new state */
    g_assert_cmpint(wx_sun_is_up(e->lat, e->lon, hi), ==, e->rising);
    g_assert_cmpint(wx_sun_is_up(e->lat, e->lon, hi - 1), ==, !e->rising);
    g_test_message("%s %s: transition off by %" G_GINT64_FORMAT " s", e->city,
                   e->rising ? "rise" : "set", hi - want);
    /* Near the horizon-grazing polar-summer dips the altitude changes by only ~0.005 degree per
     * minute (computed for Tromso 2026-07-26 00:36), so a model difference of 0.01 degree moves
     * the transition by two minutes: those rows get the wider bound. */
    gint64 tolerance = fabs(e->lat) > 60.0 ? SUN_POLAR_TOLERANCE_S : SUN_TOLERANCE_S;
    g_assert_cmpint(llabs(hi - want), <=, tolerance);
  }
}

static void
test_sun_is_up_sanity(void)
{
  gint64 noon_utc = T0 + 12 * 3600;
  /* local solar noon at lon 0 is ~12:00 UTC: up in London and Accra, down at lon 180 */
  g_assert_true(wx_sun_is_up(51.5, 0.0, noon_utc));
  g_assert_false(wx_sun_is_up(51.5, 0.0, T0));       /* local midnight */
  g_assert_true(wx_sun_is_up(0.0, 0.0, noon_utc));
  g_assert_false(wx_sun_is_up(0.0, 180.0, noon_utc));
  g_assert_true(wx_sun_is_up(0.0, 180.0, T0));
  /* equator: roughly 12 hours of daylight on the equinox */
  gint64 equinox = 0;
  g_assert_true(wx_time_parse_iso8601("2026-03-20T00:00:00Z", &equinox));
  gint64 up = 0;
  for (gint64 t = equinox; t < equinox + 86400; t += 60)
    up += wx_sun_is_up(0.0, 0.0, t) ? 60 : 0;
  g_assert_cmpint(up, >=, 12 * 3600 - 15 * 60);
  g_assert_cmpint(up, <=, 12 * 3600 + 15 * 60);

  /* hostile arguments are "night" (never a critical) */
  g_assert_false(wx_sun_is_up(NAN, 0, noon_utc));
  g_assert_false(wx_sun_is_up(0, NAN, noon_utc));
  g_assert_false(wx_sun_is_up(INFINITY, 0, noon_utc));
  g_assert_false(wx_sun_is_up(0, -INFINITY, noon_utc));
  g_assert_false(wx_sun_is_up(89.5, 0, noon_utc));
  g_assert_false(wx_sun_is_up(-89.5, 0, noon_utc));
  g_assert_false(wx_sun_is_up(0, 181, noon_utc));
  g_assert_false(wx_sun_is_up(0, -181, noon_utc));
  g_assert_false(wx_sun_is_up(0, 0, 0));
  g_assert_false(wx_sun_is_up(0, 0, -1));
  g_assert_false(wx_sun_is_up(0, 0, WX_TIME_MIN_S - 1));
  g_assert_false(wx_sun_is_up(0, 0, G_MAXINT64));
  g_assert_false(wx_sun_is_up(0, 0, G_MININT64));
  g_assert_false(wx_sun_is_up(0, 0, WX_TIME_MAX_S));
  /* the time range is half open [WX_TIME_MIN_S, WX_TIME_MAX_S): the first and last accepted
   * seconds work (local noon at lon 180 is ~00:00 UTC), the seconds outside are refused even
   * though the sun is up there */
  g_assert_true(wx_sun_is_up(0.0, 180.0, WX_TIME_MIN_S));
  g_assert_false(wx_sun_is_up(0.0, 180.0, WX_TIME_MIN_S - 1));
  g_assert_true(wx_sun_is_up(0.0, 180.0, WX_TIME_MAX_S - 1));
  g_assert_false(wx_sun_is_up(0.0, 180.0, WX_TIME_MAX_S));
}

/* Every minute of the UTC day starting at @day_start_s: is the sun up? Returns the number of
 * minutes with the sun up. */
static gint
sun_up_minutes(double lat, double lon, gint64 day_start_s)
{
  gint up = 0;
  for (gint64 t = day_start_s; t < day_start_s + 86400; t += 60)
    up += wx_sun_is_up(lat, lon, t) ? 1 : 0;
  return up;
}

static void
test_sun_is_up_polar(void)
{
  gint64 june, dec;
  g_assert_true(wx_time_parse_iso8601("2026-06-21T00:00:00Z", &june));
  g_assert_true(wx_time_parse_iso8601("2026-12-21T00:00:00Z", &dec));

  /* Tromso (69.65 N): midnight sun on 21 June (up in every minute of the day), polar night on
   * 21 December (down in every minute). */
  g_assert_cmpint(sun_up_minutes(69.6492, 18.9553, june), ==, 1440);
  g_assert_cmpint(sun_up_minutes(69.6492, 18.9553, dec), ==, 0);
  /* ... the same at 80 N and 89 N (the accepted edge) and in the southern hemisphere */
  g_assert_cmpint(sun_up_minutes(80.0, 20.0, june), ==, 1440);
  g_assert_cmpint(sun_up_minutes(80.0, 20.0, dec), ==, 0);
  g_assert_cmpint(sun_up_minutes(89.0, 0.0, june), ==, 1440);
  g_assert_cmpint(sun_up_minutes(89.0, 0.0, dec), ==, 0);
  g_assert_cmpint(sun_up_minutes(-89.0, 0.0, june), ==, 0);
  g_assert_cmpint(sun_up_minutes(-89.0, 0.0, dec), ==, 1440);
  g_assert_cmpint(sun_up_minutes(-77.85, 166.67, dec), ==, 1440); /* McMurdo */
  g_assert_cmpint(sun_up_minutes(-77.85, 166.67, june), ==, 0);
  /* Tromso on a mid-autumn day has both day and night */
  gint64 autumn;
  g_assert_true(wx_time_parse_iso8601("2026-10-10T22:00:00Z", &autumn));
  gint up = sun_up_minutes(69.6492, 18.9553, autumn);
  g_assert_cmpint(up, >, 5 * 60);
  g_assert_cmpint(up, <, 10 * 60);

  /* beyond 89 degrees the function refuses: "not up", although the sun is up at the pole in June */
  g_assert_cmpint(sun_up_minutes(89.0001, 0.0, june), ==, 0);
  g_assert_cmpint(sun_up_minutes(90.0, 0.0, june), ==, 0);
  g_assert_cmpint(sun_up_minutes(-89.0001, 0.0, dec), ==, 0);
  g_assert_cmpint(sun_up_minutes(-90.0, 0.0, dec), ==, 0);
}

/* Exact edges of every range wx_forecast_new() normalises: the limit itself is kept, a hair
 * beyond it becomes NAN. */
static void
test_forecast_normalise_limits(void)
{
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour hs[4] = {good_blend_hour(T0), good_blend_hour(T0 + 3600),
                       good_blend_hour(T0 + 7200), good_blend_hour(T0 + 10800)};
  /* 0: every field exactly at its limit */
  hs[0].temp_c = -100.0;
  hs[0].feels_c = 70.0;
  hs[0].precip_mm = 500.0;
  hs[0].precip_mm_max = 500.0;
  hs[0].precip_prob = 100.0;
  hs[0].cloud_pct = 0.0;
  hs[0].wind_kmh = 500.0;
  hs[0].gust_kmh = 0.0;
  hs[0].humidity_pct = 100.0;
  hs[0].temp_spread_c = WX_TEMP_SPREAD_MAX_C;
  hs[0].n_members = 255;
  hs[0].is_day = FALSE;
  /* 1: a hair beyond every limit */
  hs[1].temp_c = -100.001;
  hs[1].feels_c = 70.001;
  hs[1].precip_mm = 500.001;
  hs[1].precip_mm_max = 500.001;
  hs[1].precip_prob = 100.001;
  hs[1].cloud_pct = -0.001;
  hs[1].wind_kmh = 500.001;
  hs[1].gust_kmh = -0.001;
  hs[1].humidity_pct = 100.001;
  hs[1].temp_spread_c = WX_TEMP_SPREAD_MAX_C + 0.001;
  /* 2: spread just below zero; 3: spread exactly zero and infinities elsewhere */
  hs[2].temp_spread_c = -0.001;
  hs[3].temp_spread_c = 0.0;
  hs[3].temp_c = INFINITY;
  hs[3].wind_kmh = -INFINITY;
  hs[3].is_day = 7;
  WxDay ds[2] = {good_day(T0), good_day(T0 + 86400)};
  ds[0].temp_max_c = 70.0;
  ds[0].temp_min_c = -100.0;
  ds[0].precip_mm = WX_PRECIP_MAX_MM_DAY;
  ds[0].precip_prob_max = 100.0;
  ds[0].cloud_pct = 0.0;
  ds[1].temp_max_c = 70.001;
  ds[1].temp_min_c = -100.001;
  ds[1].precip_mm = WX_PRECIP_MAX_MM_DAY + 0.001;
  ds[1].precip_prob_max = 100.001;
  ds[1].cloud_pct = -0.001;
  g_assert_cmpfloat(WX_PRECIP_MAX_MM_DAY, ==, 12000.0);
  g_assert_cmpfloat(WX_TEMP_SPREAD_MAX_C, ==, 170.0);

  g_autoptr(WxForecast) fc = wx_forecast_new(place, T0, hs, 4, NULL, 0, ds, 2, NULL, 0, NULL);
  g_assert_nonnull(fc);
  const WxBlendHour *o = fc->hours;
  g_assert_cmpfloat(o[0].temp_c, ==, -100.0);
  g_assert_cmpfloat(o[0].feels_c, ==, 70.0);
  g_assert_cmpfloat(o[0].precip_mm, ==, 500.0);
  g_assert_cmpfloat(o[0].precip_mm_max, ==, 500.0);
  g_assert_cmpfloat(o[0].precip_prob, ==, 100.0);
  g_assert_cmpfloat(o[0].cloud_pct, ==, 0.0);
  g_assert_cmpfloat(o[0].wind_kmh, ==, 500.0);
  g_assert_cmpfloat(o[0].gust_kmh, ==, 0.0);
  g_assert_cmpfloat(o[0].humidity_pct, ==, 100.0);
  g_assert_cmpfloat(o[0].temp_spread_c, ==, 170.0);
  g_assert_cmpuint(o[0].n_members, ==, 255);
  g_assert_cmpint(o[0].is_day, ==, FALSE);
  g_assert_true(isnan(o[1].temp_c));
  g_assert_true(isnan(o[1].feels_c));
  g_assert_true(isnan(o[1].precip_mm));
  g_assert_true(isnan(o[1].precip_mm_max));
  g_assert_true(isnan(o[1].precip_prob));
  g_assert_true(isnan(o[1].cloud_pct));
  g_assert_true(isnan(o[1].wind_kmh));
  g_assert_true(isnan(o[1].gust_kmh));
  g_assert_true(isnan(o[1].humidity_pct));
  g_assert_true(isnan(o[1].temp_spread_c));
  g_assert_true(isnan(o[2].temp_spread_c));
  g_assert_cmpfloat(o[3].temp_spread_c, ==, 0.0);
  g_assert_true(isnan(o[3].temp_c));
  g_assert_true(isnan(o[3].wind_kmh));
  g_assert_cmpint(o[3].is_day, ==, TRUE); /* normalised to exactly TRUE */
  g_assert_cmpfloat(fc->days[0].temp_max_c, ==, 70.0);
  g_assert_cmpfloat(fc->days[0].temp_min_c, ==, -100.0);
  g_assert_cmpfloat(fc->days[0].precip_mm, ==, 12000.0);
  g_assert_cmpfloat(fc->days[0].precip_prob_max, ==, 100.0);
  g_assert_cmpfloat(fc->days[0].cloud_pct, ==, 0.0);
  g_assert_true(isnan(fc->days[1].temp_max_c));
  g_assert_true(isnan(fc->days[1].temp_min_c));
  g_assert_true(isnan(fc->days[1].precip_mm));
  g_assert_true(isnan(fc->days[1].precip_prob_max));
  g_assert_true(isnan(fc->days[1].cloud_pct));

  /* every condition below WX_COND_COUNT is accepted and copied as given */
  for (int c = 0; c < WX_COND_COUNT; c++) {
    WxBlendHour one = good_blend_hour(T0);
    one.condition = (WxCondition)c;
    WxDay day = good_day(T0);
    day.condition = (WxCondition)c;
    g_autoptr(WxForecast) f = wx_forecast_new(place, T0, &one, 1, NULL, 0, &day, 1, NULL, 0, NULL);
    g_assert_nonnull(f);
    g_assert_cmpint(f->hours[0].condition, ==, c);
    g_assert_cmpint(f->days[0].condition, ==, c);
  }
}

/* Error messages are constants: they never repeat the rejected (possibly hostile) text. */
static void
test_error_messages_do_not_echo(void)
{
  const char *secret = "SECRETZZ";
  g_autofree char *evil = g_strconcat(secret, "\n\xff", NULL);
  g_autofree char *evil_tz = g_strconcat("/", secret, NULL);
  g_autofree char *evil_url = g_strconcat("javascript:", secret, NULL);
  GError *err = NULL;

  g_assert_null(wx_place_new(evil, NULL, NULL, NULL, 0, 0, NULL, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_place_new("x", evil, NULL, NULL, 0, 0, NULL, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_place_new("x", NULL, evil, NULL, 0, 0, NULL, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_place_new("x", NULL, NULL, secret, 0, 0, NULL, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_place_new("x", NULL, NULL, NULL, 0, 0, evil_tz, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_member_new(secret, "m", T0, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_member_new("s", secret, T0, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_source_result_new(secret, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_source_status_new(secret, "n", "a", "", WX_SRC_OK, -1, 0, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_null(wx_source_status_new("x", "n", "a", evil_url, WX_SRC_OK, -1, 0, &err));
  g_assert_null(strstr(err->message, secret));
  g_clear_error(&err);
  g_assert_cmpuint(wx_error_quark(), !=, 0);
}

/* ------------------------------------------------------------------------ */
/* audit-driven tests: every documented claim has an assertion              */
/* ------------------------------------------------------------------------ */

/* wx_place_key() promises [0-9.,-] only (never '/', '%', space): checked over random places. */
static void
test_place_key_charset(void)
{
  g_autoptr(GRand) rnd = g_rand_new_with_seed(31415);
  gboolean saw_leading_minus = FALSE;
  for (int i = 0; i < 5000; i++) {
    double lat = g_rand_double_range(rnd, -90.0, 90.0);
    double lon = g_rand_double_range(rnd, -180.0, 180.0);
    if (i == 0) {
      lat = -90.0;
      lon = -180.0;
    } else if (i == 1) {
      lat = 90.0;
      lon = 180.0;
    } else if (i == 2) {
      lat = -0.0;
      lon = -0.00004;
    }
    g_autoptr(WxPlace) p = wx_place_new("x", NULL, NULL, NULL, lat, lon, NULL, NULL);
    g_assert_nonnull(p);
    g_autofree char *key = wx_place_key(p);
    g_assert_nonnull(strchr(key, ','));
    for (const char *c = key; *c != '\0'; c++)
      g_assert_nonnull(strchr("0123456789.,-", *c));
    g_assert_null(strstr(key, "-0.0000"));          /* no negative zero */
    if (key[0] == '-')
      saw_leading_minus = TRUE;
    g_assert_true(key[0] == '-' || (key[0] >= '0' && key[0] <= '9'));
  }
  g_assert_true(saw_leading_minus); /* the documented "may start with '-'" really happens */
}

/* Copies and forecasts re-sanitise hand-built statuses exactly like wx_source_status_new(). */
static void
test_status_copy_and_forecast_resanitise(void)
{
  WxSourceStatus hand = {(char *)"nws", (char *)"Na\nme\xe2\x80\xae" "X", (char *)"At\x01tr\xff",
                         (char *)GOOD_URL, WX_SRC_FAILED, WX_ERROR_HTTP, 7};
  g_autoptr(WxSourceStatus) copy = wx_source_status_copy(&hand);
  g_assert_nonnull(copy);
  g_assert_cmpstr(copy->name, ==, "NameX");
  g_assert_cmpstr(copy->attribution, ==, "Attr\xef\xbf\xbd");
  g_assert_cmpint(copy->state, ==, WX_SRC_FAILED);
  g_assert_cmpint(copy->error_code, ==, WX_ERROR_HTTP);
  g_assert_cmpuint(copy->n_members, ==, 7);

  g_autoptr(WxPlace) place = make_miami();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, T0, NULL, 0, NULL, 0, NULL, 0, &hand, 1, NULL);
  g_assert_nonnull(fc);
  g_assert_cmpstr(fc->sources[0].name, ==, "NameX");
  g_assert_cmpstr(fc->sources[0].attribution, ==, "Attr\xef\xbf\xbd");
  g_assert_cmpstr(hand.name, ==, "Na\nme\xe2\x80\xae" "X"); /* the input is untouched */
}

/* The time range is [WX_TIME_MIN_S, WX_TIME_MAX_S) everywhere it is documented. */
static void
test_time_range_edges(void)
{
  g_assert_cmpint(WX_TIME_MIN_S % 3600, ==, 0);
  g_assert_cmpint(WX_TIME_MAX_S % 3600, ==, 0);
  g_assert_cmpint(WX_TIME_MAX_S % 900, ==, 0);

  /* members */
  g_autoptr(WxMember) lo = wx_member_new("s", "m", WX_TIME_MIN_S, NULL);
  g_assert_nonnull(lo);
  g_autoptr(WxMember) hi = wx_member_new("s", "m", WX_TIME_MAX_S - 1, NULL);
  g_assert_nonnull(hi);
  g_assert_null(wx_member_new("s", "m", WX_TIME_MIN_S - 1, NULL));
  g_assert_null(wx_member_new("s", "m", WX_TIME_MAX_S, NULL));
  WxHour h = good_hour(WX_TIME_MIN_S);
  g_assert_true(wx_member_add_hour(lo, &h));
  h.t_s = WX_TIME_MIN_S - 3600;
  g_autoptr(WxMember) lo2 = make_member();
  g_assert_false(wx_member_add_hour(lo2, &h));
  h.t_s = WX_TIME_MAX_S - 3600;
  g_assert_true(wx_member_add_hour(hi, &h));
  h.t_s = WX_TIME_MAX_S;
  g_autoptr(WxMember) hi2 = make_member();
  g_assert_false(wx_member_add_hour(hi2, &h));
  WxQuarter q = {WX_TIME_MIN_S, 0.0};
  g_assert_true(wx_member_add_quarter(lo, &q));
  q.t_s = WX_TIME_MIN_S - 900;
  g_assert_false(wx_member_add_quarter(lo2, &q));
  q.t_s = WX_TIME_MAX_S - 900;
  g_assert_true(wx_member_add_quarter(hi, &q));
  q.t_s = WX_TIME_MAX_S;
  g_assert_false(wx_member_add_quarter(hi2, &q));

  /* forecasts: generation time, hours, quarters and days */
  g_autoptr(WxPlace) place = make_miami();
  WxBlendHour bh = good_blend_hour(WX_TIME_MIN_S);
  WxQuarter bq = {WX_TIME_MIN_S, 0.1};
  WxDay bd = good_day(WX_TIME_MIN_S);
  g_autoptr(WxForecast) f1 =
    wx_forecast_new(place, WX_TIME_MIN_S, &bh, 1, &bq, 1, &bd, 1, NULL, 0, NULL);
  g_assert_nonnull(f1);
  bh.t_s = WX_TIME_MAX_S - 3600;
  bq.t_s = WX_TIME_MAX_S - 900;
  bd.start_s = WX_TIME_MAX_S - 1;
  g_autoptr(WxForecast) f2 =
    wx_forecast_new(place, WX_TIME_MAX_S - 1, &bh, 1, &bq, 1, &bd, 1, NULL, 0, NULL);
  g_assert_nonnull(f2);
  assert_forecast_rejected(place, WX_TIME_MIN_S - 1, &bh, 1, &bq, 1, &bd, 1, NULL, 0);
  assert_forecast_rejected(place, WX_TIME_MAX_S, &bh, 1, &bq, 1, &bd, 1, NULL, 0);
  bh.t_s = WX_TIME_MAX_S;
  assert_forecast_rejected(place, T0, &bh, 1, NULL, 0, NULL, 0, NULL, 0);
  bh.t_s = WX_TIME_MIN_S - 3600;
  assert_forecast_rejected(place, T0, &bh, 1, NULL, 0, NULL, 0, NULL, 0);
  bq.t_s = WX_TIME_MAX_S;
  assert_forecast_rejected(place, T0, NULL, 0, &bq, 1, NULL, 0, NULL, 0);
  bq.t_s = WX_TIME_MIN_S - 900;
  assert_forecast_rejected(place, T0, NULL, 0, &bq, 1, NULL, 0, NULL, 0);
  bd.start_s = WX_TIME_MAX_S;
  assert_forecast_rejected(place, T0, NULL, 0, NULL, 0, &bd, 1, NULL, 0);
  bd.start_s = WX_TIME_MIN_S - 1;
  assert_forecast_rejected(place, T0, NULL, 0, NULL, 0, &bd, 1, NULL, 0);
}

/* ------------------------------------------------------------------------ */
/* read bounds: guard page + independent oracle                             */
/* ------------------------------------------------------------------------ */

/*
 * One mapping: a writable page followed by an unreadable one. A buffer placed with
 * guard_place() ends exactly at the guard, so any read past its last byte is a SIGSEGV.
 */
typedef struct {
  char *map;
  size_t page;
} Guard;

static void
guard_init(Guard *g)
{
  g->page = (size_t)sysconf(_SC_PAGESIZE);
  g->map = mmap(NULL, g->page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(g->map != MAP_FAILED);
  g_assert_cmpint(mprotect(g->map + g->page, g->page, PROT_NONE), ==, 0);
}

static void
guard_clear(Guard *g)
{
  g_assert_cmpint(munmap(g->map, g->page * 2), ==, 0);
}

/* Copies @len bytes so that the last one is the last readable byte of the mapping. */
static char *
guard_place(Guard *g, const guchar *bytes, gsize len)
{
  g_assert_cmpuint(len, <=, g->page);
  char *dst = g->map + g->page - len;
  if (len > 0)
    memcpy(dst, bytes, len);
  return dst;
}

/*
 * An independent model of the reading rules documented in wx-text.h. It reads through
 * oracle_byte(), which records any access past the end of the content ("over"): when a call
 * finishes with over == FALSE the model never needed a byte beyond the content, so the real
 * function must not read one either (a guard-page placement then proves it).
 */
typedef struct {
  const guchar *s;
  gsize len;
  gboolean over;
} OracleReader;

static guchar
oracle_byte(OracleReader *r, gsize i)
{
  if (i >= r->len) {
    r->over = TRUE;
    return 0;
  }
  return r->s[i];
}

static gboolean
oracle_forbidden(gunichar c)
{
  return c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || c == 0x061C ||
         c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) ||
         (c >= 0x2066 && c <= 0x2069);
}

/* Decodes the character at @i: lead-byte classes, then at most want - 1 continuation bytes. */
static gboolean
oracle_decode(OracleReader *r, gsize i, gunichar *c, gsize *n)
{
  guchar lead = oracle_byte(r, i);
  *c = 0xFFFD;
  *n = 1;
  if (lead < 0x80) {
    *c = lead;
    return TRUE;
  }
  if (lead < 0xC2 || lead > 0xF4)
    return FALSE;
  gsize want = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4);
  char seq[4] = {(char)lead, 0, 0, 0};
  for (gsize j = 1; j < want; j++) {
    guchar x = oracle_byte(r, i + j);
    if ((x & 0xC0) != 0x80)
      return FALSE;
    seq[j] = (char)x;
  }
  gunichar v = g_utf8_get_char_validated(seq, (gssize)want); /* seq holds exactly @want bytes */
  if (v == (gunichar)-1 || v == (gunichar)-2)
    return FALSE;
  *c = v;
  *n = want;
  return TRUE;
}

static char *
oracle_sanitize(const guchar *s, gsize len, gsize max_bytes, gboolean *over)
{
  OracleReader r = {s, len, FALSE};
  GString *out = g_string_new(NULL);
  gsize i = 0;
  while (out->len < max_bytes && oracle_byte(&r, i) != 0) {
    gunichar c;
    gsize n;
    oracle_decode(&r, i, &c, &n);
    i += n;
    if (oracle_forbidden(c))
      continue;
    char buf[6];
    gint k = g_unichar_to_utf8(c, buf);
    if (out->len + (gsize)k > max_bytes)
      break;
    g_string_append_len(out, buf, k);
  }
  *over = r.over;
  return g_string_free(out, FALSE);
}

static char *
oracle_truncated(const guchar *s, gsize len, gsize max_chars, gboolean *over)
{
  OracleReader r = {s, len, FALSE};
  gsize i = 0, n_chars = 0;
  while (n_chars < max_chars && oracle_byte(&r, i) != 0) {
    gunichar c;
    gsize n;
    if (!oracle_decode(&r, i, &c, &n))
      break;
    i += n;
    n_chars++;
  }
  *over = r.over;
  return g_strndup((const char *)s, i);
}

/* [fill][lead][k continuation bytes]; returns the length. */
static gsize
make_content(guchar *out, const char *fill, guint lead, guint k, guchar cont)
{
  gsize fill_len = strlen(fill);
  memcpy(out, fill, fill_len);
  out[fill_len] = (guchar)lead;
  memset(out + fill_len + 1, cont, k);
  return fill_len + 1 + k;
}

/* Number of bytes of the longest sequence a lead byte can start, as documented: 0 = none. */
static gsize
sequence_length(guint lead)
{
  if (lead < 0xC2 || lead > 0xF4)
    return 0;
  return lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4);
}

/* The reviewers' three repros: legacy 5/6-byte leads must not make the decoder read ahead. */
static void
test_sanitize_legacy_leads(void)
{
  Guard g;
  guard_init(&g);
  const struct {
    const guchar bytes[8];
    gsize len;
    gsize max;
    const char *want;
  } cases[] = {
    {{'a', 'b', 'c', 0xFC, 0x80, 0x80, 0x80}, 7, 6, "abc\xef\xbf\xbd"},
    {{'a', 'b', 'c', 0xF8, 0x80, 0x80, 0x80}, 7, 6, "abc\xef\xbf\xbd"},
    {{'a', 'b', 'c', 0xF8, 0x80, 0x80, 0x80}, 7, 4, "abc"},
    {{'a', 'b', 'c', 0xFC, 0x80, 0x80, 0x80, 0x80}, 8, 4, "abc"},
    {{'a', 'b', 'c', 0xFD, 0x80, 0x80, 0x80}, 7, 5, "abc"},
    {{'a', 'b', 'c', 0xFE, 0x80, 0x80, 0x80}, 7, 6, "abc\xef\xbf\xbd"},
    {{'a', 'b', 'c', 0xFF, 0x80, 0x80, 0x80}, 7, 3, "abc"},
    {{'a', 'b', 'c', 0xF5, 0x80, 0x80, 0x80}, 7, 6, "abc\xef\xbf\xbd"},
    {{'a', 'b', 'c', 0xC0, 0x80}, 5, 6, "abc\xef\xbf\xbd"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autofree char *out = wx_sanitize_text(guard_place(&g, cases[i].bytes, cases[i].len),
                                            cases[i].max);
    g_assert_cmpstr(out, ==, cases[i].want);
    g_autofree char *copy = wx_truncated_copy(guard_place(&g, cases[i].bytes, cases[i].len), 3);
    g_assert_cmpstr(copy, ==, "abc"); /* three characters copied: the lead byte is never read */
  }
  /* the replacement of a legacy lead is exactly U+FFFD and the continuation bytes are re-read */
  g_autofree char *two = wx_sanitize_text("\xfc\x80\x80\x80\x80\x80", 100);
  g_assert_cmpstr(two, ==, "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd");
  guard_clear(&g);
}

/*
 * For every first byte 0x00..0xFF, every number of continuation bytes 0..5 (two continuation
 * values), several fills and every output budget 0..9: content = [fill][lead][conts] is placed
 * so that it ends exactly at an unreadable page, and wx_sanitize_text() / wx_truncated_copy()
 * must give the oracle's result without touching the page whenever the oracle itself did not
 * need a byte beyond the content. That covers "output exactly full" (the lead byte is never
 * read) and "the next character does not fit" (it is decided from at most 3 bytes after its
 * lead). The only skipped cases are the documented ones: the oracle ran off the end of the
 * buffer, either because a valid lead byte's sequence is cut off by the end or because the
 * output never filled.
 */
static void
test_text_guard_all_lead_bytes(void)
{
  Guard g;
  guard_init(&g);
  static const char *const fills[] = {"", "abc", "ab\xc3\xa9", "\xe2\x80\xae" "a", "\x01\x02"};
  static const guchar conts[] = {0x80, 0xBF};
  guint checked = 0, skipped = 0, full_cases = 0, nofit_cases = 0, copy_checked = 0;

  for (guint f = 0; f < G_N_ELEMENTS(fills); f++) {
    for (guint lead = 0; lead < 256; lead++) {
      for (guint k = 0; k <= 5; k++) {
        for (guint ci = 0; ci < G_N_ELEMENTS(conts); ci++) {
          guchar content[32];
          gsize len = make_content(content, fills[f], lead, k, conts[ci]);

          for (gsize max = 0; max <= 9; max++) {
            gboolean over = FALSE;
            g_autofree char *want = oracle_sanitize(content, len, max, &over);
            if (over) {
              skipped++;
              /* only a cut-off valid sequence or an output that never filled may run off */
              gsize want_len = sequence_length(lead);
              g_assert_true((want_len > 0 && k < want_len - 1) || strlen(want) < max);
              continue;
            }
            g_autofree char *got = wx_sanitize_text(guard_place(&g, content, len), max);
            g_assert_cmpstr(got, ==, want);
            checked++;
            if (strlen(want) == max)
              full_cases++;
            else
              nofit_cases++;
          }

          for (gsize max_chars = 0; max_chars <= 6; max_chars++) {
            gboolean over = FALSE;
            g_autofree char *want = oracle_truncated(content, len, max_chars, &over);
            if (over)
              continue; /* run off the end: the buffer is not self-delimiting */
            g_autofree char *got = wx_truncated_copy(guard_place(&g, content, len), max_chars);
            g_assert_cmpstr(got, ==, want);
            copy_checked++;
          }
        }
      }
    }
  }
  g_test_message("sanitize: %u guard runs (%u full, %u no-fit), %u skipped; truncated_copy: %u",
                 checked, full_cases, nofit_cases, skipped, copy_checked);
  g_assert_cmpuint(checked, >, 20000);
  g_assert_cmpuint(full_cases, >, 5000);
  g_assert_cmpuint(nofit_cases, >, 1000);
  g_assert_cmpuint(copy_checked, >, 10000);

  /* "exactly full": nothing after the filler is read at all (the guard follows the filler) */
  for (guint f = 0; f < G_N_ELEMENTS(fills); f++) {
    gsize fill_len = strlen(fills[f]);
    gboolean over = FALSE;
    g_autofree char *want = oracle_sanitize((const guchar *)fills[f], fill_len, G_MAXSIZE, &over);
    gsize max = strlen(want);
    if (max == 0)
      continue;
    g_autofree char *got =
      wx_sanitize_text(guard_place(&g, (const guchar *)fills[f], fill_len), max);
    g_assert_cmpstr(got, ==, want);
  }

  /* wx_truncated_copy(): once max_chars characters are copied nothing more is read, not even
   * the next byte (the guard follows the last copied character; max_chars 0 reads nothing) */
  static const char *const copy_fills[] = {"", "a", "abc", "ab\xc3\xa9", "\xe2\x82\xac" "x",
                                           "\xf0\x9f\x8c\xa7"};
  for (guint f = 0; f < G_N_ELEMENTS(copy_fills); f++) {
    gsize fill_len = strlen(copy_fills[f]);
    gboolean over = FALSE;
    g_autofree char *whole =
      oracle_truncated((const guchar *)copy_fills[f], fill_len, G_MAXSIZE, &over);
    gsize n_chars = (gsize)g_utf8_strlen(whole, -1);
    g_autofree char *got =
      wx_truncated_copy(guard_place(&g, (const guchar *)copy_fills[f], fill_len), n_chars);
    g_assert_cmpstr(got, ==, copy_fills[f]);
    if (n_chars > 0) { /* one character fewer: also stops inside the buffer */
      g_autofree char *less =
        wx_truncated_copy(guard_place(&g, (const guchar *)copy_fills[f], fill_len), n_chars - 1);
      g_assert_cmpuint(strlen(less), <, fill_len);
    }
  }

  /* differential fuzz on NUL-terminated heap strings: valid and invalid input alike */
  g_autoptr(GRand) rnd = g_rand_new_with_seed(271828);
  static const guchar pool[] = {0x01, 0x0a, 0x1f, 0x41, 0x7f, 0x80, 0xBF, 0xC0, 0xC2, 0xC3, 0xDF,
                                0xE0, 0xE2, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xF8, 0xFC, 0xFE, 0xFF,
                                0x9c, 0xae, 0xa9, 0x8e};
  for (int iter = 0; iter < 30000; iter++) {
    guchar buf[40];
    guint n = (guint)g_rand_int_range(rnd, 0, 30);
    for (guint i = 0; i < n; i++) {
      buf[i] = g_rand_boolean(rnd) ? pool[g_rand_int_range(rnd, 0, G_N_ELEMENTS(pool))]
                                   : (guchar)g_rand_int_range(rnd, 0, 256);
      if (buf[i] == 0)
        buf[i] = 0x20; /* no early NUL: the whole string is the content */
    }
    buf[n] = 0;
    gsize max = (gsize)g_rand_int_range(rnd, 0, 40);
    gboolean over;
    g_autofree char *want = oracle_sanitize(buf, n, max, &over);
    g_autofree char *got = wx_sanitize_text((const char *)buf, max);
    g_assert_cmpstr(got, ==, want);
    gsize chars = (gsize)g_rand_int_range(rnd, 0, 20);
    g_autofree char *want_copy = oracle_truncated(buf, n, chars, &over);
    g_autofree char *got_copy = wx_truncated_copy((const char *)buf, chars);
    g_assert_cmpstr(got_copy, ==, want_copy);
  }
  guard_clear(&g);
}

/* Verdict of a bounded-read function on a string: TRUE = accepted. */
typedef gboolean (*Verdict)(const char *s);

static gboolean
v_id(const char *s)
{
  return wx_id_is_valid(s);
}
static gboolean
v_name10(const char *s)
{
  return wx_text_is_usable_name(s, 10);
}
static gboolean
v_name256(const char *s)
{
  return wx_text_is_usable_name(s, WX_PLACE_NAME_MAX);
}
static gboolean
v_place_name(const char *s)
{
  g_autoptr(WxPlace) p = wx_place_new(s, NULL, NULL, NULL, 0, 0, NULL, NULL);
  return p != NULL;
}
static gboolean
v_place_admin(const char *s)
{
  g_autoptr(WxPlace) p = wx_place_new("x", s, NULL, NULL, 0, 0, NULL, NULL);
  return p != NULL;
}
static gboolean
v_place_country(const char *s)
{
  g_autoptr(WxPlace) p = wx_place_new("x", NULL, s, NULL, 0, 0, NULL, NULL);
  return p != NULL;
}
static gboolean
v_place_cc(const char *s)
{
  g_autoptr(WxPlace) p = wx_place_new("x", NULL, NULL, s, 0, 0, NULL, NULL);
  return p != NULL;
}
static gboolean
v_place_tz(const char *s)
{
  g_autoptr(WxPlace) p = wx_place_new("x", NULL, NULL, NULL, 0, 0, s, NULL);
  return p != NULL;
}
static gboolean
v_member_source(const char *s)
{
  g_autoptr(WxMember) m = wx_member_new(s, "m", T0, NULL);
  return m != NULL;
}
static gboolean
v_member_model(const char *s)
{
  g_autoptr(WxMember) m = wx_member_new("s", s, T0, NULL);
  return m != NULL;
}
static gboolean
v_result_id(const char *s)
{
  g_autoptr(WxSourceResult) r = wx_source_result_new(s, NULL);
  return r != NULL;
}
static gboolean
v_status_id(const char *s)
{
  g_autoptr(WxSourceStatus) st = wx_source_status_new(s, "n", "a", "", WX_SRC_OK, -1, 0, NULL);
  return st != NULL;
}
static gboolean
v_status_url(const char *s)
{
  g_autoptr(WxSourceStatus) st = wx_source_status_new("x", "n", "a", s, WX_SRC_OK, -1, 0, NULL);
  return st != NULL;
}
static gboolean
v_iso(const char *s)
{
  gint64 t;
  return wx_time_parse_iso8601(s, &t);
}
static gboolean
v_duration(const char *s)
{
  gint64 d;
  return wx_time_parse_iso8601_duration(s, &d);
}
static gboolean
v_interval(const char *s)
{
  gint64 a, d;
  return wx_time_parse_interval(s, &a, &d);
}

typedef struct {
  const char *name;
  Verdict fn;
  gsize bound;        /* the documented bound: at most bound + 1 bytes are read */
  const char *prefix; /* valid-looking start of the pattern */
  char fill;
} BoundedCase;

static const BoundedCase bounded_cases[] = {
  {"wx_id_is_valid", v_id, WX_ID_MAX, "", 'a'},
  {"wx_text_is_usable_name(10)", v_name10, 10, "", 'a'},
  {"wx_text_is_usable_name(256)", v_name256, WX_PLACE_NAME_MAX, "", 'a'},
  {"place name", v_place_name, WX_PLACE_NAME_MAX, "", 'a'},
  {"place admin1", v_place_admin, WX_PLACE_NAME_MAX, "", 'a'},
  {"place country", v_place_country, WX_PLACE_NAME_MAX, "", 'a'},
  {"place country code", v_place_cc, 2, "", 'U'},
  {"place timezone", v_place_tz, WX_PLACE_TIMEZONE_MAX, "", 'a'},
  {"member source id", v_member_source, WX_ID_MAX, "", 'a'},
  {"member model id", v_member_model, WX_ID_MAX, "", 'a'},
  {"source result id", v_result_id, WX_ID_MAX, "", 'a'},
  {"status provider id", v_status_id, WX_ID_MAX, "", 'a'},
  {"status attribution url", v_status_url, WX_SOURCE_URL_MAX, "https://example.org/", 'a'},
  {"wx_time_parse_iso8601", v_iso, WX_TIME_ISO8601_MAX_LEN, "2026-10-11T00:00:00", '1'},
  {"wx_time_parse_iso8601_duration", v_duration, WX_TIME_DURATION_MAX_LEN, "PT", '1'},
  {"wx_time_parse_interval", v_interval, WX_TIME_INTERVAL_MAX_LEN, "2026-10-11T00:00:00Z/PT", '1'},
};

/* @len bytes: fill, the prefix at the start and [lead][k continuation bytes] at the end. */
static void
bounded_pattern(guchar *out, gsize len, const BoundedCase *c, guint lead, guint k, guchar cont)
{
  memset(out, c->fill, len);
  memcpy(out, c->prefix, MIN(strlen(c->prefix), len));
  guchar tail[6] = {(guchar)lead, cont, cont, cont, cont, cont};
  gsize tail_len = 1 + k;
  if (tail_len > len)
    memcpy(out, tail, len);
  else
    memcpy(out + len - tail_len, tail, tail_len);
}

/*
 * Every validator and parser that documents "at most bound + 1 bytes are read": for every first
 * byte 0x00..0xFF followed by 0..5 continuation bytes at the end of the candidate,
 *  - a candidate of exactly bound + 1 bytes without NUL (the longest window the function may
 *    look at) ends at an unreadable page and must be rejected without reading further;
 *  - NUL-terminated candidates of several lengths up to the bound end at the page right after
 *    their terminator and must give the same verdict as on a heap copy.
 */
static void
test_bounded_reads_guard_page(void)
{
  Guard g;
  guard_init(&g);
  guint runs = 0;
  static const guchar conts[] = {0x80, 0xBF};
  for (guint ci = 0; ci < G_N_ELEMENTS(bounded_cases); ci++) {
    const BoundedCase *c = &bounded_cases[ci];
    g_test_message("bounded read: %s (bound %" G_GSIZE_FORMAT ")", c->name, c->bound);
    for (guint lead = 0; lead < 256; lead++) {
      for (guint k = 0; k <= 5; k++) {
        for (guint ki = 0; ki < G_N_ELEMENTS(conts); ki++) {
          guchar buf[WX_SOURCE_URL_MAX + 2];
          /* exactly bound + 1 bytes, no NUL: rejected (a NUL lead byte would end the string) */
          if (lead != 0) {
            bounded_pattern(buf, c->bound + 1, c, lead, k, conts[ki]);
            g_assert_false(c->fn(guard_place(&g, buf, c->bound + 1)));
            runs++;
          }
          /* NUL-terminated, the NUL being the last readable byte */
          const gsize lens[] = {0, 1, c->bound > 1 ? c->bound - 1 : 1, c->bound};
          for (guint li = 0; li < G_N_ELEMENTS(lens); li++) {
            gsize len = lens[li];
            bounded_pattern(buf, len, c, lead, k, conts[ki]);
            buf[len] = 0;
            gboolean got = c->fn(guard_place(&g, buf, len + 1));
            g_autofree char *heap = g_memdup2(buf, len + 1);
            g_assert_cmpint(got, ==, c->fn(heap));
            runs++;
          }
        }
      }
    }
  }
  g_assert_cmpuint(runs, >, 100000);
  guard_clear(&g);
}

/*
 * Inputs found by a brute-force search (scratch program mirroring the formulas) for which
 * rounding pushes a cosine a hair beyond +-1 (1.0000000000000002 with glibc's libm), so the
 * clamps are exercised: without them acos()/asin() would return NAN.
 */
static void
test_rounding_clamps(void)
{
  /* the sun exactly overhead: cos(zenith) rounds to 1.0000000000000002; the answer must be "up" */
  g_assert_true(wx_sun_is_up(-22.977484256883766, 6.4150193887007436, 1767267474));
  g_assert_true(wx_sun_is_up(-22.95178723335215, -101.55816157199749, 1767293396));
  /* the sun exactly at the nadir: cos(zenith) rounds to -1.0000000000000002; "not up" */
  g_assert_false(wx_sun_is_up(23.015200120310002, -9.5844338919206038, 1767228101));
  g_assert_false(wx_sun_is_up(23.013826171322677, -15.682435367175831, 1767229565));

  /* antipodal points: the haversine term rounds to 1.0000000000000002. sqrt() rounds that back
   * to exactly 1.0, so the result is finite even without the cap on h (which is not exercised
   * for larger overshoots: none was found in 60 million random antipodal pairs); the distance
   * must equal half the circumference */
  const double lats[] = {-43.449997000000003, -42.999996099999997, -39.299988700000007,
                         -34.999980100000002, -29.299968700000004};
  const double lons[] = {-175.0, -174.09999999999999, -166.69999999999999, -158.09999999999999,
                         -146.69999999999999};
  for (guint i = 0; i < G_N_ELEMENTS(lats); i++) {
    double km = wx_geo_distance_km(lats[i], lons[i], -lats[i], lons[i] + 180.0);
    g_assert_true(isfinite(km));
    g_assert_cmpfloat_with_epsilon(km, 20015.114, 0.01);
  }
}

/* Hand-built structs (the fields are public): the functions that take them stay safe. */
static void
test_hand_built_structs(void)
{
  /* a place with NULL optional strings still has a label (and a key) */
  WxPlace bare = {(char *)"Nowhere", NULL, NULL, "", 1.5, -2.5, NULL};
  g_autofree char *label = wx_place_label(&bare);
  g_assert_cmpstr(label, ==, "Nowhere");
  g_autofree char *key = wx_place_key(&bare);
  g_assert_cmpstr(key, ==, "1.5000,-2.5000");
  WxPlace partial = {(char *)"N", (char *)"A", NULL, "", 0, 0, NULL};
  g_autofree char *label2 = wx_place_label(&partial);
  g_assert_cmpstr(label2, ==, "N, A");
  WxPlace partial2 = {(char *)"N", NULL, (char *)"C", "", 0, 0, NULL};
  g_autofree char *label3 = wx_place_label(&partial2);
  g_assert_cmpstr(label3, ==, "N, C");

  /* a source result whose members array was never created, or was already taken away */
  WxSourceResult *hand = g_new0(WxSourceResult, 1);
  hand->provider_id = g_strdup("x");
  wx_source_result_free(hand);
  WxSourceResult *empty = g_new0(WxSourceResult, 1);
  wx_source_result_free(empty);
}

/* The one documented way to make wx_sanitize_text() slow: a long forbidden run BEFORE the text. */
static void
test_sanitize_long_forbidden_run(void)
{
  gsize run = 4 * 1024 * 1024;
  g_autofree char *s = g_malloc(run + 4);
  memset(s, 0x01, run);
  memcpy(s + run, "abc", 4);
  g_autofree char *out = wx_sanitize_text(s, 3);
  g_assert_cmpstr(out, ==, "abc");
  /* a run of overlong-looking invalid bytes is replaced one by one until the output is full */
  memset(s, 0xff, run);
  g_autofree char *out2 = wx_sanitize_text(s, 9);
  g_assert_cmpstr(out2, ==, "\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd");
}

typedef struct {
  const char *name;
  double lat_min, lat_max, lon_min, lon_max;
} Box;

/* Corners of the box are inside; 0.001 degree beyond each side (at mid-box) is outside. */
static void
assert_box_edges(gboolean (*in_box)(double, double), const Box *b)
{
  double mid_lat = 0.5 * (b->lat_min + b->lat_max);
  double mid_lon = 0.5 * (b->lon_min + b->lon_max);
  g_test_message("box %s", b->name);
  g_assert_true(in_box(b->lat_min, b->lon_min));
  g_assert_true(in_box(b->lat_min, b->lon_max));
  g_assert_true(in_box(b->lat_max, b->lon_min));
  g_assert_true(in_box(b->lat_max, b->lon_max));
  g_assert_true(in_box(mid_lat, mid_lon));
  g_assert_false(in_box(b->lat_min - 0.001, mid_lon));
  g_assert_false(in_box(b->lat_max + 0.001, mid_lon));
  if (b->lon_min - 0.001 >= -180.0)
    g_assert_false(in_box(mid_lat, b->lon_min - 0.001));
  if (b->lon_max + 0.001 <= 180.0)
    g_assert_false(in_box(mid_lat, b->lon_max + 0.001));
}

static void
test_geo_box_edges(void)
{
  /* the numbers documented in wx-geo.h */
  static const Box nws[] = {
    {"contiguous US", 24.0, 50.0, -125.0, -66.5},
    {"Alaska", 51.0, 72.0, -180.0, -129.0},
    {"western Aleutians", 51.0, 56.0, 172.0, 180.0},
    {"Hawaii", 18.5, 22.5, -161.0, -154.0},
    {"Puerto Rico / USVI", 17.5, 18.8, -68.0, -64.5},
    {"Guam", 13.0, 14.0, 144.0, 145.2},
  };
  for (guint i = 0; i < G_N_ELEMENTS(nws); i++)
    assert_box_edges(wx_geo_in_us_nws, &nws[i]);
  static const Box conus = {"HRRR box", 21.0, 53.0, -135.0, -60.0};
  assert_box_edges(wx_geo_in_conus, &conus);
  static const Box europe = {"Europe box", 34.0, 72.0, -25.0, 45.0};
  assert_box_edges(wx_geo_in_europe, &europe);
}

/* ------------------------------------------------------------------------ */
/* validators vs. consumers: time zone names and attribution URLs           */
/* ------------------------------------------------------------------------ */

static void
test_place_timezone_shapes(void)
{
  /* IANA names, including the awkward real ones, are accepted */
  const char *good[] = {
    "UTC", "GMT", "EST5EDT", "America/New_York", "Etc/GMT+5", "Etc/GMT-14",
    "America/Port-au-Prince", "America/Argentina/ComodRivadavia",
    "America/North_Dakota/New_Salem", "Asia/Ho_Chi_Minh", "Africa/Dar_es_Salaam", "",
  };
  for (guint i = 0; i < G_N_ELEMENTS(good); i++) {
    g_test_message("accept %s", good[i]);
    g_autoptr(WxPlace) p = wx_place_new("x", NULL, NULL, NULL, 0, 0, good[i], NULL);
    g_assert_nonnull(p);
    g_assert_cmpstr(p->timezone, ==, good[i]);
  }
  /* paths, traversals, options and every other malformed shape are refused */
  const char *bad[] = {
    "/etc/passwd", "/dev/stdin", "/", "//", "///", "-", "--help", "-x", "+05", "_x", "1abc",
    "America/", "America//New_York", "/America/New_York", "America/New_York/",
    "/usr/share/zoneinfo/Asia/Tokyo", "./x", "../x", "a/../b", "a/./b", "..", ".", "a/..",
    "a/.", "a/-b", "a/+b", "a/_b", "a/1b", "Etc/+5", "a b", " UTC", "UTC ", "a\\b", "a:b",
    "a%2Fb", "a\tb", "a\nb", "Z\xc3\xbcrich", "a;b", "a$b", "a~b", "a.b", "America/New.York",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_test_message("reject %s", bad[i]);
    assert_place_rejected("x", NULL, NULL, NULL, 0, 0, bad[i]);
  }
  /* exactly 64 bytes pass, 65 fail, also when built from components */
  g_autofree char *c31 = g_strnfill(31, 'a');
  g_autofree char *c32 = g_strnfill(32, 'a');
  g_autofree char *tz63 = g_strdup_printf("%s/%s", c31, c31);
  g_autofree char *tz64 = g_strdup_printf("%s/%s", c32, c31);
  g_autofree char *tz65 = g_strdup_printf("%s/%s", c32, c32);
  g_assert_cmpuint(strlen(tz63), ==, 63);
  g_assert_cmpuint(strlen(tz64), ==, 64);
  g_assert_cmpuint(strlen(tz65), ==, 65);
  g_autoptr(WxPlace) ok63 = wx_place_new("x", NULL, NULL, NULL, 0, 0, tz63, NULL);
  g_assert_nonnull(ok63);
  g_autoptr(WxPlace) ok64 = wx_place_new("x", NULL, NULL, NULL, 0, 0, tz64, NULL);
  g_assert_nonnull(ok64);
  assert_place_rejected("x", NULL, NULL, NULL, 0, 0, tz65);

  /* the same rule guards the place copy inside a forecast and wx_place_copy */
  g_autoptr(WxPlace) src = make_miami();
  g_free(src->timezone);
  src->timezone = g_strdup("/etc/passwd");
  g_assert_null(wx_place_copy(src));
  assert_forecast_rejected(src, T0, NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static void
assert_url_rejected(const char *url)
{
  GError *err = NULL;
  g_test_message("reject URL %s", url);
  g_assert_null(wx_source_status_new("x", "n", "a", url, WX_SRC_OK, -1, 0, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_assert_null(strstr(err->message, "javascript"));
  g_assert_null(strstr(err->message, "evil"));
  g_clear_error(&err);
  g_assert_null(wx_source_status_new("x", "n", "a", url, WX_SRC_OK, -1, 0, NULL));
}

static void
test_source_status_url(void)
{
  const char *good[] = {
    "https://open-meteo.com/", "https://www.weather.gov/", "https://api.met.no/",
    "https://example.org/a?b=c&d=e#f", "https://example.org:8443/x", "https://[::1]/",
    "https://a", "https://example.org/%20x", "https://example.org/a_b-c.d~e",
    "https://example.org/a@b", "https://example.org?q=a@b", "https://example.org#a@b",
    "https://xn--bcher-kva.example/", "https://example.org/(x)*!$'+,;=",
    "https://api.met.no/weatherapi/", "https://example.org:8443/x?y=1#z", "https://1.2.3.4/",
    "https://255.255.255.255:65535/", "https://0.0.0.0/", "https://[2001:db8::1]:8443/x",
    "https://[::ffff:1.2.3.4]/", "https://[::1]:1/", "https://[::]/",
    "https://[1:2:3:4:5:6:7:8]/", "https://a:1/", "https://a:65535/", "https://A.B-c.D9/",
    "https://a-b.c-d.example/", "https://example.org/%C3%A9", "https://a/?q=%20&r=%7e",
    "https://example.org/a/b/c?d#e/f?g", "https://example.org/a:b@c", "https://a.b.c.d.e/",
    "https://a1.example/", "https://1a.example/", "https://example.org?", "https://example.org#",
    "https://example.org/?#", "https://1.2.3.4a/",
  };
  for (guint i = 0; i < G_N_ELEMENTS(good); i++) {
    g_test_message("accept URL %s", good[i]);
    g_autoptr(WxSourceStatus) s = wx_source_status_new("x", "n", "a", good[i], WX_SRC_OK, -1, 0, NULL);
    g_assert_nonnull(s);
    g_assert_cmpstr(s->attribution_url, ==, good[i]);
  }
  g_autoptr(WxSourceStatus) none = wx_source_status_new("x", "n", "a", NULL, WX_SRC_OK, -1, 0, NULL);
  g_assert_cmpstr(none->attribution_url, ==, "");
  g_autoptr(WxSourceStatus) empty = wx_source_status_new("x", "n", "a", "", WX_SRC_OK, -1, 0, NULL);
  g_assert_cmpstr(empty->attribution_url, ==, "");

  const char *bad[] = {
    "http://example.org/", "HTTPS://example.org/", "Https://example.org/", "https:/example.org/",
    "https:example.org", "https://", "https:///x", "https://?x", "https://#x",
    "file:///etc/passwd", "javascript:alert(1)", "ftp://example.org/", "data:text/html,x",
    "//example.org/", "example.org", "mailto:a@b", " https://example.org/",
    "https://example.org/ x", "https://example.org/\n", "https://example.org/\t",
    "https://example.org/\r\nSet-Cookie:x", "https://exa\"mple.org/", "https://example.org/<x>",
    "https://example.org/\\x", "https://example.org/`x`", "https://example.org/{x}",
    "https://example.org/|x", "https://example.org/^x", "https://example.org/\xc3\xa9",
    "https://\xc3\xa9.example/", "https://example.org/\x7f", "https://example.org/\x01",
    "https://good.example@evil.example/", "https://user:pw@example.org/", "https://@example.org/",
    "https://good.example@evil.example", "https://good.example@", "https://a@b?x",
    "https://example.org/\xe2\x80\xae",
    /* authority must be host [":" port] with a non-empty host and a numeric port */
    "https://:443/", "https://:/", "https://a:b/", "https://a.b:99999999/", "https://a:/",
    "https://a:65536/", "https://a:0/", "https://a:08/", "https://a:80:80/", "https://a:-1/",
    "https://a:+1/", "https://a:1 /", "https://a:/x", "https://:", "https://:0",
    /* host: registered name subset */
    "https://-a/", "https://a-/", "https://a..b/", "https://.a/", "https://a./", "https://a_b/",
    "https://a%20b/", "https://%zz/", "https://%00/", "https://%41/", "https://a b/",
    "https://a!b/", "https://a$b/", "https://a'b/", "https://a(b)/", "https://a,b/",
    "https://a;b/", "https://a=b/", "https://a*b/", "https://a+b/", "https://a~b/",
    /* numeric hosts must be strict dotted-decimal IPv4 */
    "https://1.2.3/", "https://1.2.3.4.5/", "https://256.1.1.1/", "https://01.2.3.4/",
    "https://1.2.3.4./", "https://123/", "https://a.123/", "https://1..2.3/",
    "https://0x7f.0.0.1/", "https://1.2.3.1000/",
    /* IP literals */
    "https://[]/", "https://[/", "https://[::1/", "https://[::1]x/", "https://[::1]:/",
    "https://[::1]:0/", "https://[::1]:65536/", "https://[::1]]/", "https://[::1%25eth0]/",
    "https://[::1%eth0]/", "https://[::1%25a]/", "https://[::1%a]/", "https://[::1%25ab]/",
    "https://[1.2.3.4]/", "https://[v1.a]/", "https://[:::]/",
    "https://[12345::]/", "https://[::g]/", "https://[1::2::3]/", "https://[::1:]/",
    "https://[ ::1]/", "https://[::1] /", "https://[a]/", "https://[:]/", "https://[.]/",
    "https://[::1]:80:80/", "https://[::1]@a/",
    /* percent escapes must be well formed and decode to valid UTF-8 without NUL */
    "https://a/%", "https://a/%0", "https://a/%zz", "https://a/%0g", "https://a/%g0",
    "https://a/%00", "https://a/%FF", "https://a/%C3", "https://a/%80", "https://a/x%2",
    "https://a/?q=%", "https://a/#%z",
    /* raw gen-delims and a second '#' are not allowed after the authority */
    "https://a/[x]", "https://a/?q=[x]", "https://a/#[x]", "https://a/#a#b", "https://a/b#c#d",
    "https://a/b\"c", "https://a/b c", "https://a/b%", "https://a/b\x7f",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++)
    assert_url_rejected(bad[i]);

  /* host length: 253 bytes (the DNS maximum) are accepted, 254 are not; labels up to 63 bytes */
  g_autofree char *l63 = g_strnfill(63, 'a');
  g_autofree char *l61 = g_strnfill(61, 'b');
  g_autofree char *l64 = g_strnfill(64, 'a');
  g_autofree char *host253 = g_strjoin(".", l63, l63, l63, l61, NULL);
  g_assert_cmpuint(strlen(host253), ==, 253);
  g_autofree char *url253 = g_strconcat("https://", host253, "/", NULL);
  g_autoptr(WxSourceStatus) ok253 =
    wx_source_status_new("x", "n", "a", url253, WX_SRC_OK, -1, 0, NULL);
  g_assert_nonnull(ok253);
  g_autofree char *url254 = g_strconcat("https://", host253, "c/", NULL);
  assert_url_rejected(url254);
  g_autofree char *url_label64 = g_strconcat("https://", l64, ".example/", NULL);
  assert_url_rejected(url_label64);
  g_autofree char *url_label63 = g_strconcat("https://", l63, ".example/", NULL);
  g_autoptr(WxSourceStatus) ok63 =
    wx_source_status_new("x", "n", "a", url_label63, WX_SRC_OK, -1, 0, NULL);
  g_assert_nonnull(ok63);
  /* IPv6 literals longer than 45 bytes are rejected */
  g_autofree char *long_v6 = g_strnfill(46, '1');
  g_autofree char *url_v6 = g_strconcat("https://[", long_v6, "::]/", NULL);
  assert_url_rejected(url_v6);

  /* length: WX_SOURCE_URL_MAX bytes are accepted, one more is not (rejected, not truncated) */
  g_autofree char *pad = g_strnfill(WX_SOURCE_URL_MAX - strlen("https://example.org/"), 'a');
  g_autofree char *max_url = g_strconcat("https://example.org/", pad, NULL);
  g_assert_cmpuint(strlen(max_url), ==, WX_SOURCE_URL_MAX);
  g_autoptr(WxSourceStatus) at_max =
    wx_source_status_new("x", "n", "a", max_url, WX_SRC_OK, -1, 0, NULL);
  g_assert_nonnull(at_max);
  g_assert_cmpstr(at_max->attribution_url, ==, max_url);
  g_autofree char *over_url = g_strconcat(max_url, "a", NULL);
  assert_url_rejected(over_url);
  /* an unterminated buffer is rejected after at most WX_SOURCE_URL_MAX + 1 bytes */
  char raw[WX_SOURCE_URL_MAX * 2];
  memset(raw, 'a', sizeof raw);
  memcpy(raw, "https://", 8);
  g_assert_null(wx_source_status_new("x", "n", "a", raw, WX_SRC_OK, -1, 0, NULL));

  /* hand-built statuses go through the same check in copy and in wx_forecast_new */
  WxSourceStatus hand = {(char *)"x", (char *)"n", (char *)"a", (char *)"file:///etc/passwd",
                         WX_SRC_OK, -1, 0};
  g_assert_null(wx_source_status_copy(&hand));
  g_autoptr(WxPlace) place = make_miami();
  assert_forecast_rejected(place, T0, NULL, 0, NULL, 0, NULL, 0, &hand, 1);
  hand.attribution_url = (char *)"https://example.org/ok";
  g_autoptr(WxSourceStatus) copy = wx_source_status_copy(&hand);
  g_assert_nonnull(copy);
  g_assert_cmpstr(copy->attribution_url, ==, "https://example.org/ok");
  g_autoptr(WxForecast) fc = wx_forecast_new(place, T0, NULL, 0, NULL, 0, NULL, 0, &hand, 1, NULL);
  g_assert_nonnull(fc);
  g_assert_cmpstr(fc->sources[0].attribution_url, ==, "https://example.org/ok");
}

/* ------------------------------------------------------------------------ */
/* programmer errors: NULL arguments                                        */
/* ------------------------------------------------------------------------ */

/*
 * Every public function whose header documents "NULL: critical" is called with each NULL it
 * documents: the documented return value comes back, out parameters stay untouched and the
 * objects are unchanged. (Functions that take NULL as data, e.g. wx_sanitize_text(NULL), the
 * parsers' NULL text and the NULL-tolerant free functions, are covered by their own tests.)
 */
static void
test_null_arguments(void)
{
  g_autoptr(WxMember) m = make_member();
  g_autoptr(WxForecast) fc = make_forecast_sized(2, 1, 1, 1);
  g_autoptr(WxPlace) place = make_miami();
  WxHour h = good_hour(T0);
  WxQuarter q = {T0, 0.1};
  guint n = 1234;

  /* wx_hour_init */
  ASSERT_CRITICAL("wx_hour_init", wx_hour_init(NULL));

  /* wx_place_* */
  ASSERT_CRITICAL("wx_place_copy", g_assert_null(wx_place_copy(NULL)));
  ASSERT_CRITICAL("wx_place_key", g_assert_null(wx_place_key(NULL)));
  ASSERT_CRITICAL("wx_place_label", g_assert_null(wx_place_label(NULL)));

  /* wx_member_* */
  ASSERT_CRITICAL("wx_member_ref", g_assert_null(wx_member_ref(NULL)));
  ASSERT_CRITICAL("wx_member_unref", wx_member_unref(NULL));
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(NULL, &h)));
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(m, NULL)));
  ASSERT_CRITICAL("wx_member_add_hour", g_assert_false(wx_member_add_hour(NULL, NULL)));
  ASSERT_CRITICAL("wx_member_add_quarter", g_assert_false(wx_member_add_quarter(NULL, &q)));
  ASSERT_CRITICAL("wx_member_add_quarter", g_assert_false(wx_member_add_quarter(m, NULL)));
  ASSERT_CRITICAL("wx_member_add_quarter", g_assert_false(wx_member_add_quarter(NULL, NULL)));
  g_assert_cmpuint(m->n_hours, ==, 0);
  g_assert_cmpuint(m->n_quarters, ==, 0);
  ASSERT_CRITICAL("wx_member_get_source_id", g_assert_null(wx_member_get_source_id(NULL)));
  ASSERT_CRITICAL("wx_member_get_model_id", g_assert_null(wx_member_get_model_id(NULL)));
  ASSERT_CRITICAL("wx_member_get_fetched_s", g_assert_cmpint(wx_member_get_fetched_s(NULL), ==, 0));
  ASSERT_CRITICAL("wx_member_get_hours", g_assert_null(wx_member_get_hours(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_member_get_hours", g_assert_null(wx_member_get_hours(m, NULL)));
  ASSERT_CRITICAL("wx_member_get_hours", g_assert_null(wx_member_get_hours(NULL, NULL)));
  ASSERT_CRITICAL("wx_member_get_quarters", g_assert_null(wx_member_get_quarters(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_member_get_quarters", g_assert_null(wx_member_get_quarters(m, NULL)));
  ASSERT_CRITICAL("wx_member_get_quarters", g_assert_null(wx_member_get_quarters(NULL, NULL)));

  /* wx_source_status_copy */
  ASSERT_CRITICAL("wx_source_status_copy", g_assert_null(wx_source_status_copy(NULL)));

  /* wx_forecast_* */
  ASSERT_CRITICAL("wx_forecast_new",
                  g_assert_null(wx_forecast_new(NULL, T0, NULL, 0, NULL, 0, NULL, 0, NULL, 0, NULL)));
  ASSERT_CRITICAL("wx_forecast_ref", g_assert_null(wx_forecast_ref(NULL)));
  ASSERT_CRITICAL("wx_forecast_unref", wx_forecast_unref(NULL));
  ASSERT_CRITICAL("wx_forecast_get_place", g_assert_null(wx_forecast_get_place(NULL)));
  ASSERT_CRITICAL("wx_forecast_get_generated_s",
                  g_assert_cmpint(wx_forecast_get_generated_s(NULL), ==, 0));
  ASSERT_CRITICAL("wx_forecast_get_hours", g_assert_null(wx_forecast_get_hours(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_forecast_get_hours", g_assert_null(wx_forecast_get_hours(fc, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_hours", g_assert_null(wx_forecast_get_hours(NULL, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_quarters", g_assert_null(wx_forecast_get_quarters(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_forecast_get_quarters", g_assert_null(wx_forecast_get_quarters(fc, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_quarters", g_assert_null(wx_forecast_get_quarters(NULL, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_days", g_assert_null(wx_forecast_get_days(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_forecast_get_days", g_assert_null(wx_forecast_get_days(fc, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_days", g_assert_null(wx_forecast_get_days(NULL, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_sources", g_assert_null(wx_forecast_get_sources(NULL, &n)));
  g_assert_cmpuint(n, ==, 1234);
  ASSERT_CRITICAL("wx_forecast_get_sources", g_assert_null(wx_forecast_get_sources(fc, NULL)));
  ASSERT_CRITICAL("wx_forecast_get_sources", g_assert_null(wx_forecast_get_sources(NULL, NULL)));
  g_assert_cmpuint(fc->n_hours, ==, 2); /* the forecast is unchanged */
  g_assert_cmpuint(g_atomic_int_get(&fc->ref_count), ==, 1);
  g_assert_cmpuint(g_atomic_int_get(&m->ref_count), ==, 1);

  /* wx_time_parse_*: a NULL out parameter is a programmer error; NULL text is plain data */
  gint64 a = 111, b = 222;
  ASSERT_CRITICAL("wx_time_parse_iso8601",
                  g_assert_false(wx_time_parse_iso8601("2026-10-11T00:00:00Z", NULL)));
  ASSERT_CRITICAL("wx_time_parse_iso8601_duration",
                  g_assert_false(wx_time_parse_iso8601_duration("PT1H", NULL)));
  ASSERT_CRITICAL("wx_time_parse_interval", g_assert_false(wx_time_parse_interval(
                                              "2026-10-11T00:00:00Z/PT1H", NULL, &b)));
  ASSERT_CRITICAL("wx_time_parse_interval", g_assert_false(wx_time_parse_interval(
                                              "2026-10-11T00:00:00Z/PT1H", &a, NULL)));
  ASSERT_CRITICAL("wx_time_parse_interval",
                  g_assert_false(wx_time_parse_interval(NULL, NULL, NULL)));
  g_assert_cmpint(a, ==, 111);
  g_assert_cmpint(b, ==, 222);
  g_assert_false(wx_time_parse_iso8601(NULL, &a));      /* NULL text: FALSE, no critical */
  g_assert_false(wx_time_parse_iso8601_duration(NULL, &a));
  g_assert_false(wx_time_parse_interval(NULL, &a, &b));
  g_assert_cmpint(a, ==, 111);
  g_assert_cmpint(b, ==, 222);

  /* NULL as data: documented, silent results */
  g_autofree char *s1 = wx_sanitize_text(NULL, 10);
  g_assert_cmpstr(s1, ==, "");
  g_autofree char *s2 = wx_truncated_copy(NULL, 10);
  g_assert_cmpstr(s2, ==, "");
  g_assert_false(wx_text_is_usable_name(NULL, 10));
  g_assert_false(wx_id_is_valid(NULL));
  g_assert_true(isnan(wx_geo_round4(NAN)));
  g_assert_false(wx_geo_valid(NAN, NAN));
  wx_place_free(NULL);
  wx_source_result_free(NULL);
  wx_source_status_free(NULL);
}

/* ------------------------------------------------------------------------ */
/* main                                                                     */
/* ------------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);

  g_test_add_func("/core/types/error-domain", test_error_domain);
  g_test_add_func("/core/types/value-in-range", test_value_in_range);
  g_test_add_func("/core/types/id-validation", test_id_validation);
  g_test_add_func("/core/types/place-valid", test_place_valid);
  g_test_add_func("/core/types/place-boundaries", test_place_boundaries);
  g_test_add_func("/core/types/place-hostile", test_place_hostile);
  g_test_add_func("/core/types/place-error-text", test_place_error_text);
  g_test_add_func("/core/types/place-key-label", test_place_key_label);
  g_test_add_func("/core/types/place-key-locale", test_place_key_locale_independent);
  g_test_add_func("/core/types/place-copy-free", test_place_copy_free);
  g_test_add_func("/core/types/hour-init", test_hour_init);
  g_test_add_func("/core/types/member-new", test_member_new);
  g_test_add_func("/core/types/member-add-hour-rules", test_member_add_hour_rules);
  g_test_add_func("/core/types/member-add-hour-normalises", test_member_add_hour_normalises);
  g_test_add_func("/core/types/member-hour-cap-growth", test_member_hour_cap_and_growth);
  g_test_add_func("/core/types/member-quarters", test_member_quarters);
  g_test_add_func("/core/types/member-refcount", test_member_refcount);
  g_test_add_func("/core/types/member-shared-immutable", test_member_shared_immutable);
  g_test_add_func("/core/types/source-result", test_source_result);
  g_test_add_func("/core/types/source-status", test_source_status);
  g_test_add_func("/core/types/forecast-new", test_forecast_new);
  g_test_add_func("/core/types/forecast-copies", test_forecast_copies_everything);
  g_test_add_func("/core/types/forecast-empty-max", test_forecast_empty_and_max);
  g_test_add_func("/core/types/forecast-normalises", test_forecast_normalises_numbers);
  g_test_add_func("/core/types/forecast-rejects", test_forecast_rejects);
  g_test_add_func("/core/types/forecast-refcount", test_forecast_refcount);
  g_test_add_func("/core/types/place-timezone-shapes", test_place_timezone_shapes);
  g_test_add_func("/core/types/source-status-url", test_source_status_url);
  g_test_add_func("/core/types/forecast-normalise-limits", test_forecast_normalise_limits);
  g_test_add_func("/core/types/error-messages-no-echo", test_error_messages_do_not_echo);
  g_test_add_func("/core/types/place-key-charset", test_place_key_charset);
  g_test_add_func("/core/types/status-resanitised", test_status_copy_and_forecast_resanitise);
  g_test_add_func("/core/types/time-range-edges", test_time_range_edges);
  g_test_add_func("/core/bounded-reads-guard-page", test_bounded_reads_guard_page);
  g_test_add_func("/core/text/guard-all-lead-bytes", test_text_guard_all_lead_bytes);
  g_test_add_func("/core/text/legacy-lead-bytes", test_sanitize_legacy_leads);
  g_test_add_func("/core/text/sanitize-long-forbidden-run", test_sanitize_long_forbidden_run);
  g_test_add_func("/core/geo/box-edges", test_geo_box_edges);
  g_test_add_func("/core/geo/rounding-clamps", test_rounding_clamps);
  g_test_add_func("/core/types/hand-built-structs", test_hand_built_structs);

  g_test_add_func("/core/text/sanitize-basic", test_sanitize_basic);
  g_test_add_func("/core/text/sanitize-invalid-utf8", test_sanitize_invalid_utf8);
  g_test_add_func("/core/text/sanitize-truncation", test_sanitize_truncation);
  g_test_add_func("/core/text/sanitize-stops-when-full", test_sanitize_stops_when_full);
  g_test_add_func("/core/text/sanitize-fuzz", test_sanitize_fuzz);
  g_test_add_func("/core/text/usable-name", test_usable_name);
  g_test_add_func("/core/text/truncated-copy", test_truncated_copy);

  g_test_add_func("/core/time/iso8601-valid", test_iso8601_valid);
  g_test_add_func("/core/time/iso8601-rejects", test_iso8601_rejects);
  g_test_add_func("/core/time/iso8601-calendar", test_iso8601_calendar);
  g_test_add_func("/core/time/iso8601-roundtrip-fuzz", test_iso8601_roundtrip_fuzz);
  g_test_add_func("/core/time/iso8601-mutation-fuzz", test_iso8601_mutation_fuzz);
  g_test_add_func("/core/time/duration", test_duration);
  g_test_add_func("/core/time/interval", test_interval);
  g_test_add_func("/core/time/duration-interval-fuzz", test_duration_interval_fuzz);

  g_test_add_func("/core/geo/round-valid", test_geo_round_valid);
  g_test_add_func("/core/geo/boxes", test_geo_boxes);
  g_test_add_func("/core/geo/distance", test_geo_distance);
  g_test_add_func("/core/geo/sun-usno-transitions", test_sun_is_up_usno_transitions);
  g_test_add_func("/core/geo/sun-is-up", test_sun_is_up_sanity);
  g_test_add_func("/core/geo/sun-polar", test_sun_is_up_polar);
  g_test_add_func("/core/null-arguments", test_null_arguments);

  return g_test_run();
}
