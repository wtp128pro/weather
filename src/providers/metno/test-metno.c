/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of WxMetno.
 *
 * Part 1 feeds captured MET Norway answers (fixtures/) and synthetic hostile
 * bodies to wx_metno_parse_forecast(), checks the request target builder, and
 * fuzzes the parser against an independent model. Part 2 runs the provider
 * (cache, the per-place floor between requests, Expires, If-Modified-Since / 304, 429 throttle, request
 * sharing, cancellation, in-flight cap, dispose in flight) against a loopback
 * fake server. Nothing touches the Internet or the user's XDG directories.
 *
 * Usage: test-metno FIXTURE_DIR [GLib test options]   (-m slow: more fuzzing)
 */
#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <locale.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-http.h"
#include "wx-json.h"
#include "wx-metno-testing.h"
#include "wx-metno.h"
#include "wx-registry.h"
#include "wx-types.h"

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

#define BODY(str) ((const guint8 *)(str)), strlen(str)

static const char *fixture_dir;
static char *miami_text;
static gsize miami_len;
static char *london_text;
static gsize london_len;

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

static char *
load_fixture(const char *name, gsize *len)
{
  g_autofree char *path = g_build_filename(fixture_dir, name, NULL);
  g_autoptr(GError) error = NULL;
  char *contents = NULL;
  if (!g_file_get_contents(path, &contents, len, &error))
    g_error("cannot read fixture %s: %s", path, error->message);
  return contents;
}

/*
 * A buffer of @len bytes that ends exactly at a PROT_NONE guard page: reading
 * even one byte beyond it faults. Released with guard_free().
 */
typedef struct {
  void *map;
  gsize map_len;
  char *data;
} Guarded;

static Guarded
guard_new(gsize len)
{
  gsize page = (gsize)sysconf(_SC_PAGESIZE);
  gsize pages = (len + page - 1) / page;
  if (pages == 0)
    pages = 1;
  gsize total = (pages + 1) * page;
  char *map = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect(map + pages * page, page, PROT_NONE), ==, 0);
  Guarded g = {map, total, map + pages * page - len};
  return g;
}

static void
guard_free(Guarded g)
{
  g_assert_cmpint(munmap(g.map, g.map_len), ==, 0);
}

static gint64
real_now_s(void)
{
  return g_get_real_time() / G_USEC_PER_SEC;
}

/* UTC unix seconds of y-m-d h:00:00. */
static gint64
at(int y, int m, int d, int h)
{
  GDateTime *dt = g_date_time_new_utc(y, m, d, h, 0, 0);
  g_assert_nonnull(dt);
  gint64 t = g_date_time_to_unix(dt);
  g_date_time_unref(dt);
  return t;
}

/* "2026-10-12T19:00:00Z" of @t. */
static char *
iso_of(gint64 t)
{
  GDateTime *dt = g_date_time_new_from_unix_utc(t);
  char *s = g_date_time_format_iso8601(dt);
  g_date_time_unref(dt);
  return s;
}

/* HTTP date ("Mon, 12 Oct 2026 19:19:33 GMT") without locale-dependent formatting. */
static char *
http_date(gint64 t)
{
  static const char *const days[] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
  static const char *const months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  GDateTime *dt = g_date_time_new_from_unix_utc(t);
  char *s = g_strdup_printf("%s, %02d %s %04d %02d:%02d:%02d GMT",
                            days[g_date_time_get_day_of_week(dt) - 1],
                            g_date_time_get_day_of_month(dt), months[g_date_time_get_month(dt) - 1],
                            g_date_time_get_year(dt), g_date_time_get_hour(dt),
                            g_date_time_get_minute(dt), g_date_time_get_second(dt));
  g_date_time_unref(dt);
  return s;
}

static void
assert_same_double(double got, double want)
{
  if (isnan(want)) {
    g_assert_true(isnan(got));
  } else {
    g_assert_false(isnan(got));
    g_assert_cmpfloat(got, ==, want);
    g_assert_cmpint(signbit(got) != 0, ==, signbit(want) != 0);
  }
}

static void
assert_error(const GError *error, GQuark domain, int code, const char *message)
{
  g_assert_nonnull(error);
  g_assert_cmpstr(g_quark_to_string(error->domain), ==, g_quark_to_string(domain));
  g_assert_cmpint(error->code, ==, code);
  g_assert_cmpstr(error->message, ==, message);
}

static WxMember *
parse_text(const char *text, GError **error)
{
  return wx_metno_parse_forecast(BODY(text), real_now_s(), error);
}

static WxMember *
parse_ok(const char *text)
{
  g_autoptr(GError) error = NULL;
  WxMember *member = parse_text(text, &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  return member;
}

static void
assert_parse_fails(const char *text, int code, const char *message)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) member = parse_text(text, &error);
  g_assert_null(member);
  assert_error(error, WX_ERROR, code, message);
}

/* Every promise of wx_metno_parse_forecast() about a successful result. */
static void
assert_member_invariants(WxMember *member)
{
  g_assert_cmpstr(wx_member_get_source_id(member), ==, "met-no");
  g_assert_cmpstr(wx_member_get_model_id(member), ==, "ecmwf");
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, >=, 1);
  g_assert_cmpuint(n, <=, WX_MEMBER_MAX_HOURS);
  g_assert_nonnull(hours);
  guint nq;
  g_assert_null(wx_member_get_quarters(member, &nq));
  g_assert_cmpuint(nq, ==, 0);
  for (guint i = 0; i < n; i++) {
    const WxHour *h = &hours[i];
    g_assert_cmpint(h->t_s % 3600, ==, 0);
    g_assert_cmpint(h->t_s, >=, WX_TIME_MIN_S);
    g_assert_cmpint(h->t_s, <, WX_TIME_MAX_S);
    if (i > 0)
      g_assert_cmpint(h->t_s, >, hours[i - 1].t_s);
    const double finite[] = {h->temp_c, h->feels_c, h->cloud_pct, h->humidity_pct,
                             h->wind_kmh, h->gust_kmh, h->precip_mm};
    guint n_finite = 0;
    for (guint k = 0; k < G_N_ELEMENTS(finite); k++)
      n_finite += !isnan(finite[k]);
    g_assert_cmpuint(n_finite, >=, 1);
    g_assert_true(isnan(h->temp_c) || (h->temp_c >= WX_TEMP_MIN_C && h->temp_c <= WX_TEMP_MAX_C));
    g_assert_true(isnan(h->feels_c) || (h->feels_c >= WX_TEMP_MIN_C && h->feels_c <= WX_TEMP_MAX_C));
    g_assert_true(isnan(h->cloud_pct) || (h->cloud_pct >= 0 && h->cloud_pct <= 100));
    g_assert_true(isnan(h->humidity_pct) || (h->humidity_pct >= 0 && h->humidity_pct <= 100));
    g_assert_true(isnan(h->wind_kmh) || (h->wind_kmh >= 0 && h->wind_kmh <= WX_WIND_MAX_KMH));
    g_assert_true(isnan(h->gust_kmh) || (h->gust_kmh >= 0 && h->gust_kmh <= WX_WIND_MAX_KMH));
    g_assert_true(isnan(h->precip_mm) || (h->precip_mm >= 0 && h->precip_mm <= WX_PRECIP_MAX_MM_H));
    g_assert_true(isnan(h->precip_prob));
    g_assert_cmpint(h->wmo, ==, -1);
  }
}

/* A timeseries element: time and the two details bodies are raw JSON (NULL: member omitted). */
static char *
mk_entry(const char *time_json, const char *instant, const char *next)
{
  GString *s = g_string_new("{");
  if (time_json != NULL)
    g_string_append_printf(s, "\"time\":%s,", time_json);
  g_string_append(s, "\"data\":{");
  g_string_append_printf(s, "\"instant\":{\"details\":{%s}}", instant != NULL ? instant : "");
  if (next != NULL)
    g_string_append_printf(s, ",\"next_1_hours\":{\"details\":{%s}}", next);
  g_string_append(s, "}}");
  return g_string_free(s, FALSE);
}

static char *
quoted_iso(gint64 t)
{
  g_autofree char *iso = iso_of(t);
  return g_strdup_printf("\"%s\"", iso);
}

/* {"properties":{<meta>"timeseries":[<entries>]}}; every argument is raw JSON (NULL meta: none). */
static char *
mk_doc(const char *meta, GPtrArray *entries)
{
  GString *s = g_string_new("{\"type\":\"Feature\",\"properties\":{");
  if (meta != NULL)
    g_string_append_printf(s, "%s,", meta);
  g_string_append(s, "\"timeseries\":[");
  for (guint i = 0; i < entries->len; i++)
    g_string_append_printf(s, "%s%s", i > 0 ? "," : "", (const char *)g_ptr_array_index(entries, i));
  g_string_append(s, "]}}");
  return g_string_free(s, FALSE);
}

static GPtrArray *
entries_new(void)
{
  return g_ptr_array_new_with_free_func(g_free);
}

/* Document with the given raw elements. */
static char *
doc_of(const char *first, ...) G_GNUC_NULL_TERMINATED;
static char *
doc_of(const char *first, ...)
{
  g_autoptr(GPtrArray) entries = entries_new();
  va_list ap;
  va_start(ap, first);
  for (const char *e = first; e != NULL; e = va_arg(ap, const char *))
    g_ptr_array_add(entries, g_strdup(e));
  va_end(ap);
  return mk_doc(NULL, entries);
}

/* ------------------------------------------------------------------------ */
/* Part 1: pure functions                                                   */
/* ------------------------------------------------------------------------ */

static void
test_constants(void)
{
  g_assert_cmpstr(WX_METNO_BASE_URL, ==, "https://api.met.no");
  g_assert_cmpstr(WX_METNO_USER_AGENT, ==, "weather-app/0.1 (github.com/wtp128pro/weather)");
  g_assert_cmpstr(WX_METNO_PROVIDER_ID, ==, "met-no");
  g_assert_cmpstr(WX_METNO_MODEL_ID, ==, "ecmwf");
  g_assert_cmpint(WX_METNO_CACHE_MAX, ==, 32);
  g_assert_cmpint(WX_METNO_MIN_REFRESH_S, ==, 600);
  g_assert_cmpint(WX_METNO_THROTTLE_S, ==, 60);
  g_assert_true(wx_id_is_valid(WX_METNO_PROVIDER_ID));
  g_assert_null(strchr(WX_METNO_PROVIDER_ID, '.'));
  g_assert_true(wx_id_is_valid(WX_METNO_MODEL_ID));
}

static void
test_forecast_path_table(void)
{
  static const struct {
    double lat, lon;
    const char *path;
  } cases[] = {
      {25.7617, -80.1918, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918"},
      {51.5072, -0.1276, "/weatherapi/locationforecast/2.0/complete?lat=51.5072&lon=-0.1276"},
      {-33.8688, 151.2093, "/weatherapi/locationforecast/2.0/complete?lat=-33.8688&lon=151.2093"},
      {0.0, 0.0, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
      {-0.0, -0.0, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
      {-0.00001, -0.00004, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
      {-0.00006, 0.00006, "/weatherapi/locationforecast/2.0/complete?lat=-0.0001&lon=0.0001"},
      {25.76174999, -80.19184999, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918"},
      {25.76176, -80.19186, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919"},
      {25.5, 100.0, "/weatherapi/locationforecast/2.0/complete?lat=25.5000&lon=100.0000"},
      {90.0, 180.0, "/weatherapi/locationforecast/2.0/complete?lat=90.0000&lon=180.0000"},
      {-90.0, -180.0, "/weatherapi/locationforecast/2.0/complete?lat=-90.0000&lon=-180.0000"},
      {89.99996, 179.99996, "/weatherapi/locationforecast/2.0/complete?lat=90.0000&lon=180.0000"},
      {1e-300, -1e-300, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
      {4.9e-324, -4.9e-324, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autofree char *path = wx_metno_forecast_path(cases[i].lat, cases[i].lon);
    g_assert_cmpstr(path, ==, cases[i].path);
    g_assert_true(wx_http_path_is_valid(path));
  }
  /* The longest possible target is the one of the south-west corner. */
  g_autofree char *longest = wx_metno_forecast_path(-90.0, -180.0);
  g_assert_cmpuint(strlen(longest), ==, 68);
}

static void
test_forecast_path_rejects_invalid(void)
{
  /* Bad for both coordinates, and bad for the latitude only (valid longitudes). */
  static const double bad[] = {NAN, INFINITY, -INFINITY, 180.0000001, -180.0000001, 1e300, -1e300,
                               G_MAXDOUBLE, -G_MAXDOUBLE};
  static const double bad_lat_only[] = {90.0000001, -90.0000001, 100.0, -100.0, 179.9, -179.9};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_assert_null(wx_metno_forecast_path(bad[i], 0.0));
    g_assert_null(wx_metno_forecast_path(0.0, bad[i]));
    g_assert_null(wx_metno_forecast_path(bad[i], bad[i]));
  }
  for (guint i = 0; i < G_N_ELEMENTS(bad_lat_only); i++) {
    g_assert_null(wx_metno_forecast_path(bad_lat_only[i], 0.0));
    g_assert_null(wx_metno_forecast_path(bad_lat_only[i], bad_lat_only[i] / 2));
  }
  g_assert_null(wx_metno_forecast_path(0.0, 200.0));
}

/* The path of random coordinates has exactly four decimals, is within half a unit of the last
 * decimal of the input and never contains a negative zero. */
static void
test_forecast_path_property(void)
{
  g_autoptr(GRand) rand = g_rand_new_with_seed(0x4d45544e);
  for (guint i = 0; i < 20000; i++) {
    double lat = g_rand_double_range(rand, -90.0, 90.0);
    double lon = g_rand_double_range(rand, -180.0, 180.0);
    if (i % 4 == 0) {
      lat = floor(lat * 1e5) / 1e5;
      lon = floor(lon * 1e5) / 1e5;
    }
    g_autofree char *path = wx_metno_forecast_path(lat, lon);
    g_assert_nonnull(path);
    g_assert_true(g_str_has_prefix(path, "/weatherapi/locationforecast/2.0/complete?lat="));
    g_auto(GStrv) parts = g_strsplit(path + strlen("/weatherapi/locationforecast/2.0/complete?"), "&", -1);
    g_assert_cmpuint(g_strv_length(parts), ==, 2);
    g_assert_true(g_str_has_prefix(parts[0], "lat="));
    g_assert_true(g_str_has_prefix(parts[1], "lon="));
    const char *texts[] = {parts[0] + 4, parts[1] + 4};
    const double values[] = {lat, lon};
    for (guint k = 0; k < 2; k++) {
      const char *dot = strchr(texts[k], '.');
      g_assert_nonnull(dot);
      g_assert_cmpuint(strlen(dot + 1), ==, 4);
      for (const char *p = texts[k]; *p != '\0'; p++)
        g_assert_true(g_ascii_isdigit(*p) || *p == '.' || (*p == '-' && p == texts[k]));
      g_assert_cmpstr(texts[k], !=, "-0.0000");
      char *end;
      double back = g_ascii_strtod(texts[k], &end);
      g_assert_cmpint(*end, ==, '\0');
      g_assert_cmpfloat(fabs(back - values[k]), <=, 0.00005 + 1e-9);
    }
  }
}

/* The text uses '.' as decimal separator whatever LC_NUMERIC says. */
static void
test_locale_independence(void)
{
  static const char *const locales[] = {"de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8",
                                        "ru_RU.UTF-8", "ru_RU.utf8", "pt_BR.UTF-8", "pt_BR.utf8"};
  gboolean changed = FALSE;
  for (guint i = 0; i < G_N_ELEMENTS(locales) && !changed; i++) {
    if (setlocale(LC_ALL, locales[i]) == NULL)
      continue;
    if (strcmp(localeconv()->decimal_point, ".") != 0)
      changed = TRUE;
  }
  if (!changed) {
    (void)setlocale(LC_ALL, "");
    g_test_skip("no locale with a decimal comma is installed");
    return;
  }
  g_autofree char *path = wx_metno_forecast_path(25.7617, -80.1918);
  g_assert_cmpstr(path, ==, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918");
  g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)miami_text, miami_len,
                                                       real_now_s(), NULL);
  g_assert_nonnull(member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, 92);
  g_assert_cmpfloat(hours[0].temp_c, ==, 30.5);
  g_assert_cmpfloat(hours[0].humidity_pct, ==, 66.0);
  (void)setlocale(LC_ALL, ""); /* back to the locale of the environment */
}

/* ------------------------------------------------------------------------ */
/* Part 1: parser over the captured fixtures                                */
/* ------------------------------------------------------------------------ */

static double
oracle_number(JsonObject *obj, const char *name, double factor)
{
  if (obj == NULL || !json_object_has_member(obj, name))
    return NAN;
  return json_object_get_double_member(obj, name) * factor;
}

/* Compares a parsed member with what a plain json-glib walk of the same document gives (the
 * fixtures hold only valid values, so every present number must come through unchanged). */
static void
assert_matches_oracle(const char *text, gsize len, WxMember *member)
{
  g_autoptr(JsonParser) parser = json_parser_new();
  g_assert_true(json_parser_load_from_data(parser, text, (gssize)len, NULL));
  JsonObject *root = json_node_get_object(json_parser_get_root(parser));
  JsonArray *series =
      json_object_get_array_member(json_object_get_object_member(root, "properties"), "timeseries");
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, json_array_get_length(series));
  for (guint i = 0; i < n; i++) {
    JsonObject *entry = json_array_get_object_element(series, i);
    g_autoptr(GDateTime) when =
        g_date_time_new_from_iso8601(json_object_get_string_member(entry, "time"), NULL);
    g_assert_nonnull(when);
    JsonObject *data = json_object_get_object_member(entry, "data");
    JsonObject *instant =
        json_object_get_object_member(json_object_get_object_member(data, "instant"), "details");
    JsonObject *next = json_object_has_member(data, "next_1_hours")
                           ? json_object_get_object_member(
                                 json_object_get_object_member(data, "next_1_hours"), "details")
                           : NULL;
    g_assert_cmpint(hours[i].t_s, ==, g_date_time_to_unix(when));
    assert_same_double(hours[i].temp_c, oracle_number(instant, "air_temperature", 1.0));
    assert_same_double(hours[i].feels_c, oracle_number(instant, "apparent_air_temperature", 1.0));
    assert_same_double(hours[i].cloud_pct, oracle_number(instant, "cloud_area_fraction", 1.0));
    assert_same_double(hours[i].humidity_pct, oracle_number(instant, "relative_humidity", 1.0));
    assert_same_double(hours[i].wind_kmh, oracle_number(instant, "wind_speed", 3.6));
    assert_same_double(hours[i].gust_kmh, oracle_number(instant, "wind_speed_of_gust", 3.6));
    assert_same_double(hours[i].precip_mm, oracle_number(next, "precipitation_amount", 1.0));
    g_assert_true(isnan(hours[i].precip_prob));
    g_assert_cmpint(hours[i].wmo, ==, -1);
  }
}

static void
test_fixture_miami(void)
{
  gint64 fetched = real_now_s();
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)miami_text, miami_len, fetched,
                                                       &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  assert_member_invariants(member);
  g_assert_cmpint(wx_member_get_fetched_s(member), ==, fetched);
  assert_matches_oracle(miami_text, miami_len, member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, 92);
  /* Spot values read off the captured document (m/s * 3.6 for the wind). */
  g_assert_cmpint(hours[0].t_s, ==, 1791831600); /* 2026-10-12T19:00:00Z */
  g_assert_cmpfloat(hours[0].temp_c, ==, 30.5);
  g_assert_cmpfloat(hours[0].feels_c, ==, 35.3);
  g_assert_cmpfloat(hours[0].cloud_pct, ==, 49.2);
  g_assert_cmpfloat(hours[0].humidity_pct, ==, 66.0);
  g_assert_cmpfloat(hours[0].wind_kmh, ==, 5.8 * 3.6);
  g_assert_cmpfloat(fabs(hours[0].wind_kmh - 20.88), <, 1e-12);
  g_assert_true(isnan(hours[0].gust_kmh));
  g_assert_cmpfloat(hours[0].precip_mm, ==, 0.5);
  g_assert_cmpint(hours[1].t_s, ==, hours[0].t_s + 3600);
  g_assert_cmpfloat(hours[1].precip_mm, ==, 0.3);
  g_assert_cmpfloat(hours[2].precip_mm, ==, 0.1);
  /* The 6-hourly tail: instants only, no precipitation, gaps between the hours. */
  g_assert_cmpint(hours[91].t_s, ==, 1792627200); /* 2026-10-22T00:00:00Z */
  g_assert_cmpfloat(hours[91].temp_c, ==, 25.8);
  g_assert_cmpfloat(hours[91].wind_kmh, ==, 3.5 * 3.6);
  g_assert_true(isnan(hours[91].precip_mm));
  g_assert_cmpint(hours[91].t_s - hours[90].t_s, ==, 6 * 3600);
  guint with_precip = 0;
  for (guint i = 0; i < n; i++)
    with_precip += !isnan(hours[i].precip_mm);
  g_assert_cmpuint(with_precip, ==, 65); /* the elements that carry next_1_hours */
}

static void
test_fixture_london(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)london_text, london_len,
                                                       real_now_s(), &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  assert_member_invariants(member);
  assert_matches_oracle(london_text, london_len, member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, 92);
  g_assert_cmpint(hours[0].t_s, ==, 1791831600);
  g_assert_cmpfloat(hours[0].temp_c, ==, 17.6);
  g_assert_cmpfloat(hours[0].feels_c, ==, 17.6);
  g_assert_cmpfloat(hours[0].cloud_pct, ==, 94.5);
  g_assert_cmpfloat(hours[0].humidity_pct, ==, 90.8);
  g_assert_cmpfloat(hours[0].wind_kmh, ==, 4.3 * 3.6);
  g_assert_cmpfloat(fabs(hours[0].wind_kmh - 15.48), <, 1e-12);
  g_assert_cmpfloat(hours[0].precip_mm, ==, 0.0);
  g_assert_false(signbit(hours[0].precip_mm));
  guint wet = 0;
  for (guint i = 0; i < n; i++)
    wet += !isnan(hours[i].precip_mm) && hours[i].precip_mm > 0;
  g_assert_cmpuint(wet, ==, 1); /* 2026-10-13T09:00Z: 0.1 mm */
}

/* The captured documents stay within the limits wx_json_parse() enforces, with room to spare. */
static void
test_fixture_limits(void)
{
  const char *texts[] = {miami_text, london_text};
  const gsize lens[] = {miami_len, london_len};
  for (guint i = 0; i < 2; i++) {
    g_assert_cmpuint(lens[i], <=, 200 * 1024);
    g_autoptr(GError) error = NULL;
    g_autoptr(JsonParser) parser =
        wx_json_parse((const guint8 *)texts[i], lens[i], WX_HTTP_MAX_BODY_BYTES, WX_JSON_ROOT_OBJECT,
                      &error);
    g_assert_no_error(error);
    g_assert_nonnull(parser);
  }
}

static void
test_fixture_survives_dropped_elements(void)
{
  /* Corrupt the time of every fifth element: those hours vanish, the others are untouched. */
  g_autoptr(JsonParser) parser = json_parser_new();
  g_assert_true(json_parser_load_from_data(parser, miami_text, (gssize)miami_len, NULL));
  JsonArray *series = json_object_get_array_member(
      json_object_get_object_member(json_node_get_object(json_parser_get_root(parser)), "properties"),
      "timeseries");
  guint kept = 0;
  for (guint i = 0; i < json_array_get_length(series); i++) {
    if (i % 5 == 0)
      json_object_set_string_member(json_array_get_object_element(series, i), "time", "soon");
    else
      kept++;
  }
  g_autoptr(JsonGenerator) gen = json_generator_new();
  json_generator_set_root(gen, json_parser_get_root(parser));
  g_autofree char *text = json_generator_to_data(gen, NULL);
  g_autoptr(WxMember) member = parse_ok(text);
  assert_member_invariants(member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, kept);
  g_assert_cmpuint(kept, ==, 92 - 19);
  g_assert_cmpint(hours[0].t_s, ==, 1791831600 + 3600); /* element 0 is gone */
}

/* ------------------------------------------------------------------------ */
/* Part 1: parser, document shape and units                                 */
/* ------------------------------------------------------------------------ */

static void
test_parse_rejects_document_shapes(void)
{
  g_autofree char *e = mk_entry("\"2026-10-12T19:00:00Z\"", "\"air_temperature\":20", NULL);
  static const char *const not_forecast[] = {
      "{}",
      "{\"properties\":null}",
      "{\"properties\":[]}",
      "{\"properties\":\"x\"}",
      "{\"properties\":{}}",
      "{\"properties\":{\"timeseries\":null}}",
      "{\"properties\":{\"timeseries\":{}}}",
      "{\"properties\":{\"timeseries\":\"x\"}}",
      "{\"properties\":{\"timeseries\":5}}",
      "{\"timeseries\":[]}",
      "{\"Properties\":{\"timeseries\":[]}}",
      "{\"properties\":{\"Timeseries\":[]}}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(not_forecast); i++)
    assert_parse_fails(not_forecast[i], WX_ERROR_PARSE, "not a locationforecast document");
  /* The right shape, but nothing usable in it. */
  assert_parse_fails("{\"properties\":{\"timeseries\":[]}}", WX_ERROR_PARSE, "no usable forecast data");
  assert_parse_fails("{\"properties\":{\"timeseries\":[null,1,\"a\",[],{}]}}", WX_ERROR_PARSE,
                     "no usable forecast data");
  /* Document level problems are the ones wx_json_parse() reports. */
  assert_parse_fails("", WX_ERROR_PARSE, "empty response");
  assert_parse_fails("[]", WX_ERROR_PARSE, "response is not a JSON object");
  assert_parse_fails("null", WX_ERROR_PARSE, "response is not a JSON object");
  assert_parse_fails("{\"properties\"", WX_ERROR_PARSE, "malformed JSON");
  assert_parse_fails("<html>502 Bad Gateway</html>", WX_ERROR_PARSE, "malformed JSON");
  assert_parse_fails("{\"properties\":{},\"properties\":{}}", WX_ERROR_PARSE, "malformed JSON");
  g_autoptr(GError) error = NULL;
  g_assert_null(wx_metno_parse_forecast(BODY("{\"a\":\"\xff\"}"), real_now_s(), &error));
  assert_error(error, WX_ERROR, WX_ERROR_PARSE, "response is not valid UTF-8");
  /* The valid one for contrast. */
  g_autofree char *good = doc_of(e, NULL);
  g_autoptr(WxMember) member = parse_ok(good);
  assert_member_invariants(member);
}

static void
test_parse_error_messages_do_not_echo_body(void)
{
  assert_parse_fails("{\"properties\":{\"timeseries\":\"SENTINEL-BODY-TEXT\"}}", WX_ERROR_PARSE,
                     "not a locationforecast document");
  assert_parse_fails("{\"properties\":{\"meta\":{\"units\":{\"air_temperature\":\"SENTINEL-BODY-TEXT\"}},"
                     "\"timeseries\":[]}}",
                     WX_ERROR_PARSE, "unexpected units");
}

static void
test_parse_units(void)
{
  static const struct {
    const char *name, *good, *bad;
  } units[] = {
      {"air_temperature", "celsius", "fahrenheit"},
      {"apparent_air_temperature", "celsius", "kelvin"},
      {"cloud_area_fraction", "%", "1"},
      {"relative_humidity", "%", "fraction"},
      {"wind_speed", "m/s", "km/h"},
      {"wind_speed_of_gust", "m/s", "knots"},
      {"precipitation_amount", "mm", "in"},
  };
  g_autofree char *e = mk_entry("\"2026-10-12T19:00:00Z\"", "\"air_temperature\":20", NULL);
  for (guint i = 0; i < G_N_ELEMENTS(units); i++) {
    g_autoptr(GPtrArray) entries = entries_new();
    g_ptr_array_add(entries, g_strdup(e));
    /* Every other variable carries its right unit; only the tested one varies. */
    for (int pass = 0; pass < 6; pass++) {
      g_autofree char *meta = NULL;
      const char *value;
      switch (pass) {
      case 0:
        value = units[i].good;
        break;
      case 1:
        value = units[i].bad;
        break;
      case 2:
        value = "";
        break;
      case 3:
        value = "CELSIUS"; /* case matters */
        break;
      case 4:
        value = "m/s ";
        break;
      default:
        value = NULL;
        break;
      }
      if (value != NULL)
        meta = g_strdup_printf("\"meta\":{\"units\":{\"%s\":\"%s\"}}", units[i].name, value);
      else
        meta = g_strdup_printf("\"meta\":{\"units\":{\"%s\":5}}", units[i].name);
      g_autofree char *text = mk_doc(meta, entries);
      if (pass == 0) {
        g_autoptr(WxMember) member = parse_ok(text);
        assert_member_invariants(member);
      } else {
        assert_parse_fails(text, WX_ERROR_PARSE, "unexpected units");
      }
    }
  }
  /* A mistyped (null) unit is a mismatch as well. */
  g_autoptr(GPtrArray) entries = entries_new();
  g_ptr_array_add(entries, g_strdup(e));
  g_autofree char *null_unit = mk_doc("\"meta\":{\"units\":{\"wind_speed\":null}}", entries);
  assert_parse_fails(null_unit, WX_ERROR_PARSE, "unexpected units");
  /* Missing meta, missing units, other variables and an empty units object are accepted. */
  const char *accepted[] = {"\"meta\":{}", "\"meta\":null", "\"meta\":{\"units\":{}}",
                            "\"meta\":{\"units\":null}", "\"meta\":[]",
                            "\"meta\":{\"units\":{\"air_pressure_at_sea_level\":\"hPa\"}}"};
  for (guint i = 0; i < G_N_ELEMENTS(accepted); i++) {
    g_autofree char *text = mk_doc(accepted[i], entries);
    g_autoptr(WxMember) member = parse_ok(text);
    assert_member_invariants(member);
  }
}

/* ------------------------------------------------------------------------ */
/* Part 1: parser, elements and values                                      */
/* ------------------------------------------------------------------------ */

/* The hours of @text as (t_s) list, for tests that only care which elements survive. */
static void
assert_times(const char *text, const gint64 *want, guint n_want)
{
  g_autoptr(WxMember) member = parse_ok(text);
  assert_member_invariants(member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, n_want);
  for (guint i = 0; i < n; i++)
    g_assert_cmpint(hours[i].t_s, ==, want[i]);
}

static void
test_parse_element_skipping(void)
{
  const gint64 t0 = at(2026, 10, 12, 19);
  g_autofree char *q0 = quoted_iso(t0);
  g_autofree char *q1 = quoted_iso(t0 + 3600);
  g_autofree char *q2 = quoted_iso(t0 + 7200);
  g_autofree char *q3 = quoted_iso(t0 + 10800);
  const char *v = "\"air_temperature\":20";
  g_autofree char *e0 = mk_entry(q0, v, NULL);
  g_autofree char *e1 = mk_entry(q1, v, NULL);
  g_autofree char *e2 = mk_entry(q2, v, NULL);
  g_autofree char *e3 = mk_entry(q3, v, NULL);

  /* Order: duplicates and descending stamps are dropped, a later ascending one is kept. */
  {
    g_autofree char *text = doc_of(e0, e0, e1, e1, e0, e2, NULL);
    const gint64 want[] = {t0, t0 + 3600, t0 + 7200};
    assert_times(text, want, 3);
  }
  {
    g_autofree char *text = doc_of(e2, e1, e3, e0, NULL);
    const gint64 want[] = {t0 + 7200, t0 + 10800};
    assert_times(text, want, 2);
  }
  /* Gaps are fine (the 6-hourly tail). */
  {
    g_autofree char *far = quoted_iso(t0 + 6 * 3600);
    g_autofree char *ef = mk_entry(far, v, NULL);
    g_autofree char *text = doc_of(e0, ef, NULL);
    const gint64 want[] = {t0, t0 + 6 * 3600};
    assert_times(text, want, 2);
  }
  /* Elements that are not objects, or lack / mangle their time, are skipped. */
  {
    g_autofree char *no_time = mk_entry(NULL, v, NULL);
    g_autofree char *num_time = mk_entry("1791831600", v, NULL);
    g_autofree char *null_time = mk_entry("null", v, NULL);
    g_autofree char *arr_time = mk_entry("[\"2026-10-12T20:00:00Z\"]", v, NULL);
    g_autofree char *text = doc_of("1", "\"x\"", "null", "true", "[]", "[1]", no_time, num_time,
                                   null_time, arr_time, e0, "{}", e1, NULL);
    const gint64 want[] = {t0, t0 + 3600};
    assert_times(text, want, 2);
  }
  /* Timestamps off the hour, malformed or outside 2000..2100 are skipped. */
  {
    const char *bad_times[] = {"\"2026-10-12T19:30:00Z\"", "\"2026-10-12T19:00:01Z\"",
                               "\"2026-10-12T19:59:59Z\"", "\"2026-10-12t19:00:00z\"",
                               "\"2026-10-12 19:00:00Z\"", "\"2026-10-12T19:00:00\"",
                               "\"2026-13-12T19:00:00Z\"", "\"2026-02-30T19:00:00Z\"",
                               "\"1999-12-31T23:00:00Z\"", "\"2101-01-01T00:00:00Z\"", "\"\"",
                               "\"2026-10-12T19:00:00Z \"", "\" 2026-10-12T19:00:00Z\""};
    for (guint i = 0; i < G_N_ELEMENTS(bad_times); i++) {
      g_autofree char *bad = mk_entry(bad_times[i], v, NULL);
      g_autofree char *text = doc_of(bad, e1, NULL);
      const gint64 want[] = {t0 + 3600};
      assert_times(text, want, 1);
    }
  }
  /* The ends of the accepted range, offsets and fractions. */
  {
    g_autofree char *first = mk_entry("\"2000-01-01T00:00:00Z\"", v, NULL);
    g_autofree char *last = mk_entry("\"2100-12-31T23:00:00Z\"", v, NULL);
    g_autofree char *text = doc_of(first, last, NULL);
    const gint64 want[] = {946684800, 4133980800 - 3600};
    assert_times(text, want, 2);
    g_autofree char *zoned = mk_entry("\"2026-10-12T21:00:00+02:00\"", v, NULL);
    g_autofree char *frac = mk_entry("\"2026-10-12T20:00:00.75Z\"", v, NULL);
    g_autofree char *minus = mk_entry("\"2026-10-12T14:00:00-05:00\"", v, NULL);
    g_autofree char *text2 = doc_of(zoned, frac, e2, minus, NULL);
    const gint64 want2[] = {t0, t0 + 3600, t0 + 7200};
    /* "14:00-05:00" is 19:00Z again: not later than 21:00Z, so it is dropped. */
    assert_times(text2, want2, 3);
  }
  /* Elements without a usable value are skipped; a precipitation-only one is kept. */
  {
    g_autofree char *no_data = g_strdup_printf("{\"time\":%s}", q0);
    g_autofree char *data_null = g_strdup_printf("{\"time\":%s,\"data\":null}", q0);
    g_autofree char *data_arr = g_strdup_printf("{\"time\":%s,\"data\":[]}", q0);
    g_autofree char *no_instant = g_strdup_printf("{\"time\":%s,\"data\":{}}", q0);
    g_autofree char *no_details = g_strdup_printf("{\"time\":%s,\"data\":{\"instant\":{}}}", q0);
    g_autofree char *details_arr =
        g_strdup_printf("{\"time\":%s,\"data\":{\"instant\":{\"details\":[1]}}}", q0);
    g_autofree char *empty = mk_entry(q0, "", NULL);
    g_autofree char *only_junk = mk_entry(q0, "\"air_pressure_at_sea_level\":1013,\"wind_from_direction\":55", NULL);
    g_autofree char *all_bad =
        mk_entry(q0,
                 "\"air_temperature\":999,\"cloud_area_fraction\":-1,\"relative_humidity\":101,"
                 "\"wind_speed\":-3,\"wind_speed_of_gust\":\"fast\",\"apparent_air_temperature\":null",
                 "\"precipitation_amount\":-1");
    g_autofree char *junk = doc_of(no_data, data_null, data_arr, no_instant, no_details, details_arr,
                                   empty, only_junk, all_bad, e1, NULL);
    const gint64 want[] = {t0 + 3600};
    assert_times(junk, want, 1);
    g_autofree char *precip_only = mk_entry(q0, "", "\"precipitation_amount\":0.3");
    g_autofree char *text = doc_of(precip_only, e1, NULL);
    g_autoptr(WxMember) member = parse_ok(text);
    guint n;
    const WxHour *hours = wx_member_get_hours(member, &n);
    g_assert_cmpuint(n, ==, 2);
    g_assert_cmpfloat(hours[0].precip_mm, ==, 0.3);
    g_assert_true(isnan(hours[0].temp_c));
    g_assert_true(isnan(hours[0].wind_kmh));
    g_assert_cmpfloat(hours[1].temp_c, ==, 20);
    g_assert_true(isnan(hours[1].precip_mm));
  }
  /* A next_1_hours that is no object (or lacks details) leaves the instants alone. */
  {
    g_autofree char *odd1 = g_strdup_printf(
        "{\"time\":%s,\"data\":{\"instant\":{\"details\":{\"air_temperature\":21}},\"next_1_hours\":5}}", q0);
    g_autofree char *odd2 = g_strdup_printf(
        "{\"time\":%s,\"data\":{\"instant\":{\"details\":{\"air_temperature\":22}},\"next_1_hours\":{}}}", q1);
    g_autofree char *odd3 = g_strdup_printf(
        "{\"time\":%s,\"data\":{\"instant\":{\"details\":{\"air_temperature\":23}},\"next_1_hours\":"
        "{\"details\":{\"precipitation_amount\":\"1\"}}}}",
        q2);
    g_autofree char *text = doc_of(odd1, odd2, odd3, NULL);
    g_autoptr(WxMember) member = parse_ok(text);
    guint n;
    const WxHour *hours = wx_member_get_hours(member, &n);
    g_assert_cmpuint(n, ==, 3);
    for (guint i = 0; i < 3; i++) {
      g_assert_cmpfloat(hours[i].temp_c, ==, 21 + i);
      g_assert_true(isnan(hours[i].precip_mm));
    }
  }
}

typedef struct {
  const char *field;      /* member name in the details object */
  gboolean in_next;       /* inside next_1_hours.details instead of instant.details */
  double factor;          /* unit conversion applied by the parser */
  gsize offset;           /* offsetof(WxHour, <field>) */
  const char *carrier;    /* a valid value of another variable, so the hour exists */
} Variable;

static double
hour_field(const WxHour *h, gsize offset)
{
  return *(const double *)((const char *)h + offset);
}

static void
assert_value_case(const Variable *var, const char *literal, double want)
{
  g_autofree char *member_text = g_strdup_printf("\"%s\":%s", var->field, literal);
  g_autofree char *instant = var->in_next ? g_strdup(var->carrier)
                                          : g_strdup_printf("%s,%s", var->carrier, member_text);
  g_autofree char *q = quoted_iso(at(2026, 10, 12, 19));
  g_autofree char *entry = mk_entry(q, instant, var->in_next ? member_text : NULL);
  g_autofree char *text = doc_of(entry, NULL);
  g_autoptr(WxMember) member = parse_ok(text);
  assert_member_invariants(member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, 1);
  assert_same_double(hour_field(&hours[0], var->offset), want);
}

static void
test_parse_value_ranges(void)
{
  const Variable temp = {"air_temperature", FALSE, 1.0, G_STRUCT_OFFSET(WxHour, temp_c), "\"relative_humidity\":50"};
  const Variable feels = {"apparent_air_temperature", FALSE, 1.0, G_STRUCT_OFFSET(WxHour, feels_c),
                          "\"relative_humidity\":50"};
  const Variable cloud = {"cloud_area_fraction", FALSE, 1.0, G_STRUCT_OFFSET(WxHour, cloud_pct),
                          "\"air_temperature\":20"};
  const Variable humidity = {"relative_humidity", FALSE, 1.0, G_STRUCT_OFFSET(WxHour, humidity_pct),
                             "\"air_temperature\":20"};
  const Variable wind = {"wind_speed", FALSE, 3.6, G_STRUCT_OFFSET(WxHour, wind_kmh), "\"air_temperature\":20"};
  const Variable gust = {"wind_speed_of_gust", FALSE, 3.6, G_STRUCT_OFFSET(WxHour, gust_kmh),
                         "\"air_temperature\":20"};
  const Variable precip = {"precipitation_amount", TRUE, 1.0, G_STRUCT_OFFSET(WxHour, precip_mm),
                           "\"air_temperature\":20"};
  static const char *const garbage[] = {"\"20\"", "true", "false", "null", "[20]", "{}", "[]", "\"\"",
                                        "1e999", "-1e999", "9223372036854775807",
                                        "-9223372036854775808", "18446744073709551615",
                                        "1e308", "-1e308", "1.7976931348623157e308",
                                        "-1.7976931348623157e308"};
  const Variable *all[] = {&temp, &feels, &cloud, &humidity, &wind, &gust, &precip};
  for (guint i = 0; i < G_N_ELEMENTS(all); i++) {
    for (guint k = 0; k < G_N_ELEMENTS(garbage); k++)
      assert_value_case(all[i], garbage[k], NAN);
    assert_value_case(all[i], "-0.0", 0.0);
    assert_value_case(all[i], "-0", 0.0);
    assert_value_case(all[i], "0", 0.0);
    assert_value_case(all[i], "0.0e5", 0.0);
    assert_value_case(all[i], "-0.0E-3", 0.0);
  }
  /* Temperatures: -100..70 inclusive. */
  const Variable *temps[] = {&temp, &feels};
  for (guint i = 0; i < 2; i++) {
    assert_value_case(temps[i], "-100", -100.0);
    assert_value_case(temps[i], "-100.0", -100.0);
    assert_value_case(temps[i], "70", 70.0);
    assert_value_case(temps[i], "70.0", 70.0);
    assert_value_case(temps[i], "20.5", 20.5);
    assert_value_case(temps[i], "-40.25", -40.25);
    assert_value_case(temps[i], "-100.0000001", NAN);
    assert_value_case(temps[i], "70.0000001", NAN);
    assert_value_case(temps[i], "-101", NAN);
    assert_value_case(temps[i], "71", NAN);
    assert_value_case(temps[i], "4.9e-324", 4.9e-324);
    assert_value_case(temps[i], "-4.9e-324", -4.9e-324);
    assert_value_case(temps[i], "2.2250738585072014e-308", 2.2250738585072014e-308);
  }
  /* Percentages: 0..100 inclusive. */
  const Variable *percents[] = {&cloud, &humidity};
  for (guint i = 0; i < 2; i++) {
    assert_value_case(percents[i], "100", 100.0);
    assert_value_case(percents[i], "100.0", 100.0);
    assert_value_case(percents[i], "49.2", 49.2);
    assert_value_case(percents[i], "100.0000001", NAN);
    assert_value_case(percents[i], "101", NAN);
    assert_value_case(percents[i], "-0.0000001", NAN);
    assert_value_case(percents[i], "-1", NAN);
    assert_value_case(percents[i], "4.9e-324", 4.9e-324);
  }
  /* Speeds: m/s times 3.6, result 0..500 km/h. */
  const Variable *speeds[] = {&wind, &gust};
  for (guint i = 0; i < 2; i++) {
    assert_value_case(speeds[i], "1", 1 * 3.6);
    assert_value_case(speeds[i], "5.8", 5.8 * 3.6);
    assert_value_case(speeds[i], "100", 100 * 3.6);
    assert_value_case(speeds[i], "138.8", 138.8 * 3.6); /* 499.68 km/h */
    assert_value_case(speeds[i], "138.9", NAN);         /* 500.04 km/h */
    assert_value_case(speeds[i], "500", NAN);
    assert_value_case(speeds[i], "-0.1", NAN);
    assert_value_case(speeds[i], "-4.9e-324", NAN);
    assert_value_case(speeds[i], "4.9e-324", 4.9e-324 * 3.6);
    assert_value_case(speeds[i], "1e-300", 1e-300 * 3.6);
    assert_value_case(speeds[i], "5e307", NAN); /* the product overflows to infinity */
  }
  /* Precipitation: 0..500 mm. */
  assert_value_case(&precip, "500", 500.0);
  assert_value_case(&precip, "500.0", 500.0);
  assert_value_case(&precip, "0.1", 0.1);
  assert_value_case(&precip, "12", 12.0);
  assert_value_case(&precip, "500.0000001", NAN);
  assert_value_case(&precip, "501", NAN);
  assert_value_case(&precip, "-0.0000001", NAN);
  assert_value_case(&precip, "-1", NAN);
  assert_value_case(&precip, "4.9e-324", 4.9e-324);
}

static void
test_parse_gust(void)
{
  g_autofree char *q = quoted_iso(at(2026, 10, 12, 19));
  g_autofree char *entry = mk_entry(q, "\"wind_speed\":5,\"wind_speed_of_gust\":9.5", NULL);
  g_autofree char *text = doc_of(entry, NULL);
  g_autoptr(WxMember) member = parse_ok(text);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, 1);
  g_assert_cmpfloat(hours[0].wind_kmh, ==, 5 * 3.6);
  g_assert_cmpfloat(hours[0].gust_kmh, ==, 9.5 * 3.6);
  /* No relation between the two is enforced: a gust below the wind is kept as given. */
  g_autofree char *entry2 = mk_entry(q, "\"wind_speed\":9,\"wind_speed_of_gust\":2", NULL);
  g_autofree char *text2 = doc_of(entry2, NULL);
  g_autoptr(WxMember) member2 = parse_ok(text2);
  hours = wx_member_get_hours(member2, &n);
  g_assert_cmpfloat(hours[0].wind_kmh, ==, 9 * 3.6);
  g_assert_cmpfloat(hours[0].gust_kmh, ==, 2 * 3.6);
}

static void
test_parse_hour_cap(void)
{
  const gint64 t0 = at(2026, 10, 12, 0);
  g_autoptr(GPtrArray) entries = entries_new();
  for (guint i = 0; i < 1000; i++) {
    g_autofree char *q = quoted_iso(t0 + (gint64)i * 3600);
    g_ptr_array_add(entries, mk_entry(q, "\"air_temperature\":20", NULL));
  }
  g_autofree char *text = mk_doc(NULL, entries);
  g_autoptr(WxMember) member = parse_ok(text);
  assert_member_invariants(member);
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpint(hours[0].t_s, ==, t0);
  g_assert_cmpint(hours[n - 1].t_s, ==, t0 + (gint64)(WX_MEMBER_MAX_HOURS - 1) * 3600);
  /* Exactly 400 and 399 elements. */
  g_ptr_array_set_size(entries, WX_MEMBER_MAX_HOURS);
  g_autofree char *text400 = mk_doc(NULL, entries);
  g_autoptr(WxMember) m400 = parse_ok(text400);
  (void)wx_member_get_hours(m400, &n);
  g_assert_cmpuint(n, ==, 400);
  g_ptr_array_set_size(entries, WX_MEMBER_MAX_HOURS - 1);
  g_autofree char *text399 = mk_doc(NULL, entries);
  g_autoptr(WxMember) m399 = parse_ok(text399);
  (void)wx_member_get_hours(m399, &n);
  g_assert_cmpuint(n, ==, 399);
  /* Dropped elements do not count towards the cap: 500 bad ones in front of 400 good ones. */
  g_autoptr(GPtrArray) mixed = entries_new();
  for (guint i = 0; i < 500; i++)
    g_ptr_array_add(mixed, g_strdup("{\"time\":\"bad\"}"));
  for (guint i = 0; i < 450; i++) {
    g_autofree char *q = quoted_iso(t0 + (gint64)i * 3600);
    g_ptr_array_add(mixed, mk_entry(q, "\"air_temperature\":20", NULL));
  }
  g_autofree char *text_mixed = mk_doc(NULL, mixed);
  g_autoptr(WxMember) mm = parse_ok(text_mixed);
  hours = wx_member_get_hours(mm, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpint(hours[0].t_s, ==, t0);
}

static void
test_parse_fetched_time(void)
{
  g_autofree char *e = mk_entry("\"2026-10-12T19:00:00Z\"", "\"air_temperature\":20", NULL);
  g_autofree char *good = doc_of(e, NULL);
  const gint64 bad[] = {0, -1, WX_TIME_MIN_S - 1, WX_TIME_MAX_S, WX_TIME_MAX_S + 1, G_MININT64, G_MAXINT64};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autoptr(GError) error = NULL;
    /* Checked before the body is looked at: a garbage body gives the same error. */
    g_assert_null(wx_metno_parse_forecast(BODY(good), bad[i], &error));
    assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG, "fetch time out of range");
    g_clear_error(&error);
    g_assert_null(wx_metno_parse_forecast(BODY("garbage"), bad[i], &error));
    assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG, "fetch time out of range");
  }
  const gint64 fine[] = {WX_TIME_MIN_S, WX_TIME_MAX_S - 1, 1791831600};
  for (guint i = 0; i < G_N_ELEMENTS(fine); i++) {
    g_autoptr(WxMember) member = wx_metno_parse_forecast(BODY(good), fine[i], NULL);
    g_assert_nonnull(member);
    g_assert_cmpint(wx_member_get_fetched_s(member), ==, fine[i]);
  }
  /* No error location is fine too. */
  g_assert_null(wx_metno_parse_forecast(BODY(good), 0, NULL));
  g_assert_null(wx_metno_parse_forecast(BODY("{}"), 1791831600, NULL));
}

static void
test_parse_null_and_programmer_errors(void)
{
  g_autoptr(GError) error = NULL;
  /* NULL with a zero length is an empty body: data, not a programmer error. */
  g_assert_null(wx_metno_parse_forecast(NULL, 0, real_now_s(), &error));
  assert_error(error, WX_ERROR, WX_ERROR_PARSE, "empty response");
  g_clear_error(&error);
  /* NULL with a length is a programmer error: one critical, NULL, no error set. */
  ASSERT_CRITICAL("data != NULL || len == 0",
                  g_assert_null(wx_metno_parse_forecast(NULL, 5, real_now_s(), &error)));
  g_assert_no_error(error);
}

/* Only @len bytes are read: the body ends at a PROT_NONE page, and so does every prefix. */
static void
test_parse_guard_page(void)
{
  Guarded g = guard_new(miami_len);
  memcpy(g.data, miami_text, miami_len);
  g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)g.data, miami_len, real_now_s(), NULL);
  g_assert_nonnull(member);
  guard_free(g);

  const gsize cuts[] = {0, 1, 2, 5, 17, 100, 1000, 4095, 4096, 4097, 30000, 64000};
  for (guint i = 0; i < G_N_ELEMENTS(cuts); i++) {
    gsize cut = MIN(cuts[i], miami_len - 1);
    Guarded gp = guard_new(cut);
    memcpy(gp.data, miami_text, cut);
    g_autoptr(GError) error = NULL;
    g_assert_null(wx_metno_parse_forecast((const guint8 *)gp.data, cut, real_now_s(), &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
    guard_free(gp);
  }
  /* A complete tiny document at the guard. */
  const char *tiny = "{\"properties\":{\"timeseries\":[{\"time\":\"2026-10-12T19:00:00Z\","
                     "\"data\":{\"instant\":{\"details\":{\"air_temperature\":1}}}}]}}";
  Guarded gt = guard_new(strlen(tiny));
  memcpy(gt.data, tiny, strlen(tiny));
  g_autoptr(WxMember) tiny_member =
      wx_metno_parse_forecast((const guint8 *)gt.data, strlen(tiny), real_now_s(), NULL);
  g_assert_nonnull(tiny_member);
  guard_free(gt);
}

static void
test_parse_size_limits(void)
{
  /* A body above the cap is refused before any byte is examined. */
  gsize big = (gsize)WX_HTTP_MAX_BODY_BYTES + 1;
  char *blank = g_malloc(big);
  memset(blank, ' ', big);
  g_autoptr(GError) error = NULL;
  g_assert_null(wx_metno_parse_forecast((const guint8 *)blank, big, real_now_s(), &error));
  assert_error(error, WX_ERROR, WX_ERROR_PARSE, "response too large");
  g_free(blank);
  /* Nesting beyond the depth the JSON layer allows: the structure is refused. */
  GString *deep = g_string_new("{\"properties\":");
  for (guint i = 0; i < 40; i++)
    g_string_append(deep, "{\"a\":");
  g_string_append(deep, "1");
  for (guint i = 0; i < 40; i++)
    g_string_append_c(deep, '}');
  g_string_append_c(deep, '}');
  g_autoptr(GError) error2 = NULL;
  g_assert_null(wx_metno_parse_forecast((const guint8 *)deep->str, deep->len, real_now_s(), &error2));
  assert_error(error2, WX_ERROR, WX_ERROR_PARSE, "malformed JSON");
  g_string_free(deep, TRUE);
}

/* Documents at the limits wx_json_parse() enforces: 1024 members per object, depth 32. */
static void
test_parse_json_limits(void)
{
  g_autofree char *q = quoted_iso(at(2026, 10, 12, 19));
  for (guint n = 1023; n <= 1026; n++) {
    GString *instant = g_string_new("\"air_temperature\":20");
    for (guint i = 1; i < n; i++)
      g_string_append_printf(instant, ",\"k%u\":%u", i, i);
    g_autofree char *entry = mk_entry(q, instant->str, NULL);
    g_autofree char *text = doc_of(entry, NULL);
    g_string_free(instant, TRUE);
    if (n <= WX_JSON_PARSE_MAX_MEMBERS) {
      g_autoptr(WxMember) member = parse_ok(text);
      g_assert_cmpfloat(wx_member_get_hours(member, &(guint){0})[0].temp_c, ==, 20);
    } else {
      assert_parse_fails(text, WX_ERROR_PARSE, "malformed JSON");
    }
  }
  /* The deepest accepted nesting: an extra value inside an element, root = level 1,
   * properties 2, timeseries 3, element 4, so "extra" holds 28 arrays at level 32. */
  for (guint arrays = 27; arrays <= 30; arrays++) {
    GString *extra = g_string_new(NULL);
    for (guint i = 0; i < arrays; i++)
      g_string_append_c(extra, '[');
    g_string_append_c(extra, '1');
    for (guint i = 0; i < arrays; i++)
      g_string_append_c(extra, ']');
    g_autofree char *text = g_strdup_printf(
        "{\"properties\":{\"timeseries\":[{\"time\":%s,\"extra\":%s,\"data\":{\"instant\":{\"details\":"
        "{\"air_temperature\":20}}}}]}}",
        q, extra->str);
    g_string_free(extra, TRUE);
    if (4 + arrays <= WX_JSON_PARSE_MAX_DEPTH) {
      g_autoptr(WxMember) member = parse_ok(text);
      assert_member_invariants(member);
    } else {
      assert_parse_fails(text, WX_ERROR_PARSE, "malformed JSON");
    }
  }
}

/* ------------------------------------------------------------------------ */
/* Part 1: fuzzing the parser                                               */
/* ------------------------------------------------------------------------ */

static guint
fuzz_iterations(guint normal, guint slow)
{
  const char *env = g_getenv("WX_TEST_FUZZ_ITERATIONS");
  if (env != NULL && *env != '\0')
    return (guint)g_ascii_strtoull(env, NULL, 10);
  return g_test_slow() ? slow : normal;
}

typedef struct {
  gboolean time_ok;  /* the element has a time the parser must accept (on the hour, in range) */
  gint64 t_s;
  double v[7];       /* expected temp, feels, cloud, humidity, wind, gust, precip (NAN: unusable) */
} ModelEntry;

/* One random JSON number for a variable with the converted range [lo, hi] and factor; sets the
 * expected value. Returns the JSON text. */
static char *
random_value(GRand *rand, double factor, double lo, double hi, double *expected)
{
  *expected = NAN;
  switch (g_rand_int_range(rand, 0, 14)) {
  case 0:
    return g_strdup("null");
  case 1:
    return g_strdup("\"12\"");
  case 2:
    return g_strdup("true");
  case 3:
    return g_strdup("[1]");
  case 4:
    return g_strdup("1e999");
  case 5: {
    /* Far out of range, either side. */
    double v = (g_rand_boolean(rand) ? 1 : -1) * (hi - lo + 1.0) * (1.0 + g_rand_double(rand) * 1000.0);
    if (lo >= 0 && v > 0)
      v += hi / factor;
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    return g_strdup(g_ascii_dtostr(buf, sizeof buf, v)); /* "%.17g", whatever the locale */
  }
  default: {
    /* In range of the converted value (the raw value is converted back by the factor). */
    double conv = lo + (hi - lo) * g_rand_double(rand);
    if (g_rand_int_range(rand, 0, 8) == 0)
      conv = g_rand_boolean(rand) ? lo : hi;
    double raw = conv / factor;
    double product = raw * factor;
    if (!(product >= lo && product <= hi)) {
      raw = nextafter(raw, 0.0);
      product = raw * factor;
    }
    if (!(product >= lo && product <= hi))
      return g_strdup("null");
    *expected = product == 0.0 ? 0.0 : product;
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    return g_strdup(g_ascii_dtostr(buf, sizeof buf, raw));
  }
  }
}

/* Builds a random document and the entries the parser must accept, from the rules of the header
 * comment of wx_metno_parse_forecast() only. */
static char *
random_document(GRand *rand, GArray *want)
{
  const double lows[] = {WX_TEMP_MIN_C, WX_TEMP_MIN_C, 0, 0, 0, 0, 0};
  const double highs[] = {WX_TEMP_MAX_C, WX_TEMP_MAX_C, 100, 100, WX_WIND_MAX_KMH, WX_WIND_MAX_KMH,
                          WX_PRECIP_MAX_MM_H};
  const double factors[] = {1, 1, 1, 1, 3.6, 3.6, 1};
  const char *names[] = {"air_temperature", "apparent_air_temperature", "cloud_area_fraction",
                         "relative_humidity", "wind_speed", "wind_speed_of_gust",
                         "precipitation_amount"};
  guint n = (guint)g_rand_int_range(rand, 0, 60) + (g_rand_int_range(rand, 0, 20) == 0 ? 450 : 0);
  g_autoptr(GPtrArray) entries = entries_new();
  gint64 t = at(2026, 10, 12, 0) + g_rand_int_range(rand, -50, 50) * 3600;
  gint64 last_accepted = G_MININT64;
  guint accepted = 0;
  for (guint i = 0; i < n; i++) {
    ModelEntry m = {FALSE, 0, {NAN, NAN, NAN, NAN, NAN, NAN, NAN}};
    g_autofree char *time_json = NULL;
    switch (g_rand_int_range(rand, 0, 12)) {
    case 0: /* the same stamp again */
      break;
    case 1: /* a step back */
      t -= (gint64)g_rand_int_range(rand, 1, 4) * 3600;
      break;
    case 2: /* a long gap */
      t += (gint64)g_rand_int_range(rand, 5, 50) * 3600;
      break;
    default:
      t += (gint64)g_rand_int_range(rand, 1, 4) * 3600;
      break;
    }
    gint64 stamp = t;
    switch (g_rand_int_range(rand, 0, 14)) {
    case 0:
      time_json = g_strdup("null");
      break;
    case 1:
      time_json = g_strdup_printf("%" G_GINT64_FORMAT, stamp);
      break;
    case 2: {
      g_autofree char *iso = iso_of(stamp + 1800);
      time_json = g_strdup_printf("\"%s\"", iso);
      break;
    }
    case 3:
      time_json = g_strdup("\"not a time\"");
      break;
    case 4: { /* a zone offset: the same instant */
      GDateTime *dt = g_date_time_new_from_unix_utc(stamp + 7200);
      g_autofree char *base = g_date_time_format(dt, "%Y-%m-%dT%H:%M:%S");
      g_date_time_unref(dt);
      time_json = g_strdup_printf("\"%s+02:00\"", base);
      m.time_ok = TRUE;
      break;
    }
    default: {
      g_autofree char *iso = iso_of(stamp);
      time_json = g_strdup_printf("\"%s\"", iso);
      m.time_ok = TRUE;
      break;
    }
    }
    m.t_s = stamp;
    GString *instant = g_string_new(NULL);
    GString *next = g_string_new(NULL);
    for (guint k = 0; k < 7; k++) {
      if (g_rand_int_range(rand, 0, 3) == 0)
        continue; /* member absent */
      double expected;
      g_autofree char *literal = random_value(rand, factors[k], lows[k], highs[k], &expected);
      m.v[k] = expected;
      GString *target = k == 6 ? next : instant;
      g_string_append_printf(target, "%s\"%s\":%s", target->len > 0 ? "," : "", names[k], literal);
    }
    g_autofree char *entry = NULL;
    gboolean structural = TRUE; /* the element is an object with a data.instant.details object */
    switch (g_rand_int_range(rand, 0, 25)) {
    case 0:
      entry = g_strdup("7");
      structural = FALSE;
      break;
    case 1:
      entry = g_strdup("null");
      structural = FALSE;
      break;
    case 2:
      entry = g_strdup_printf("{\"time\":%s,\"data\":null}", time_json);
      structural = FALSE;
      break;
    case 3:
      entry = g_strdup_printf("{\"time\":%s,\"data\":{\"instant\":[]}}", time_json);
      structural = FALSE;
      break;
    default: /* a next_1_hours object is sometimes left out, sometimes empty */
      entry = mk_entry(time_json, instant->str,
                       g_rand_int_range(rand, 0, 5) == 0 && next->len == 0 ? NULL : next->str);
      break;
    }
    g_string_free(instant, TRUE);
    g_string_free(next, TRUE);
    if (structural && m.time_ok && stamp % 3600 == 0 && stamp > last_accepted) {
      gboolean any = FALSE;
      for (guint k = 0; k < 7; k++)
        any = any || !isnan(m.v[k]);
      if (any && accepted < WX_MEMBER_MAX_HOURS) {
        g_array_append_val(want, m);
        last_accepted = stamp;
        accepted++;
      }
    }
    g_ptr_array_add(entries, g_steal_pointer(&entry));
  }
  return mk_doc(NULL, entries);
}

static void
test_parse_fuzz_against_model(void)
{
  g_autoptr(GRand) rand = g_rand_new_with_seed(0x57584d4e);
  guint iterations = fuzz_iterations(1500, 60000);
  guint successes = 0;
  for (guint it = 0; it < iterations; it++) {
    g_autoptr(GArray) want = g_array_new(FALSE, FALSE, sizeof(ModelEntry));
    g_autofree char *text = random_document(rand, want);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) member = wx_metno_parse_forecast(BODY(text), real_now_s(), &error);
    if (want->len == 0) {
      g_assert_null(member);
      assert_error(error, WX_ERROR, WX_ERROR_PARSE, "no usable forecast data");
      continue;
    }
    g_assert_no_error(error);
    g_assert_nonnull(member);
    successes++;
    assert_member_invariants(member);
    guint n;
    const WxHour *hours = wx_member_get_hours(member, &n);
    g_assert_cmpuint(n, ==, want->len);
    for (guint i = 0; i < n; i++) {
      const ModelEntry *m = &g_array_index(want, ModelEntry, i);
      g_assert_cmpint(hours[i].t_s, ==, m->t_s);
      assert_same_double(hours[i].temp_c, m->v[0]);
      assert_same_double(hours[i].feels_c, m->v[1]);
      assert_same_double(hours[i].cloud_pct, m->v[2]);
      assert_same_double(hours[i].humidity_pct, m->v[3]);
      assert_same_double(hours[i].wind_kmh, m->v[4]);
      assert_same_double(hours[i].gust_kmh, m->v[5]);
      assert_same_double(hours[i].precip_mm, m->v[6]);
    }
  }
  g_assert_cmpuint(successes, >, iterations / 4); /* the generator exercises the success path */
}

/* Inserts @len bytes at @pos (the bytes must not live inside @buf). */
static void
ba_insert(GByteArray *buf, guint pos, const guint8 *data, guint len)
{
  guint old = buf->len;
  g_byte_array_set_size(buf, old + len);
  memmove(buf->data + pos + len, buf->data + pos, old - pos);
  memcpy(buf->data + pos, data, len);
}

/* Random edits of a real document: whatever happens, no crash, and a success keeps every promise. */
static void
test_parse_fuzz_mutations(void)
{
  g_autoptr(GRand) rand = g_rand_new_with_seed(0x4d555441);
  guint iterations = fuzz_iterations(300, 20000);
  static const char *const tokens[] = {"null", "1e999", "-1", "\"", "{", "}", "[", "]", ",", ":", "\\u0000",
                                       "99999999999999999999", "\"time\"", "\"data\"", "0.5e-400",
                                       "\xff", "\xed\xa0\x80", "{\"a\":1}", "[[[[[[[[[[", " "};
  guint ok = 0;
  for (guint it = 0; it < iterations; it++) {
    const char *src = it % 2 == 0 ? miami_text : london_text;
    gsize src_len = it % 2 == 0 ? miami_len : london_len;
    GByteArray *buf = g_byte_array_new();
    g_byte_array_append(buf, (const guint8 *)src, (guint)src_len);
    guint edits = (guint)g_rand_int_range(rand, 1, 6);
    for (guint e = 0; e < edits && buf->len > 0; e++) {
      guint pos = (guint)g_rand_int_range(rand, 0, (gint32)buf->len);
      switch (g_rand_int_range(rand, 0, 6)) {
      case 0:
        buf->data[pos] = (guint8)g_rand_int_range(rand, 0, 256);
        break;
      case 1:
        buf->data[pos] ^= (guint8)(1u << g_rand_int_range(rand, 0, 8));
        break;
      case 2: {
        guint want = (guint)g_rand_int_range(rand, 1, 400);
        guint len = MIN(want, buf->len - pos);
        g_byte_array_remove_range(buf, pos, len);
        break;
      }
      case 3: {
        const char *tok = tokens[g_rand_int_range(rand, 0, G_N_ELEMENTS(tokens))];
        ba_insert(buf, pos, (const guint8 *)tok, (guint)strlen(tok));
        break;
      }
      case 4:
        g_byte_array_set_size(buf, pos);
        break;
      default: {
        guint want = (guint)g_rand_int_range(rand, 1, 300);
        guint len = MIN(want, buf->len - pos);
        g_autofree guint8 *chunk = g_memdup2(buf->data + pos, len);
        ba_insert(buf, (guint)g_rand_int_range(rand, 0, (gint32)buf->len), chunk, len);
        break;
      }
      }
    }
    Guarded g = guard_new(buf->len);
    if (buf->len > 0)
      memcpy(g.data, buf->data, buf->len);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)g.data, buf->len, real_now_s(), &error);
    if (member != NULL) {
      g_assert_no_error(error);
      assert_member_invariants(member);
      ok++;
    } else {
      g_assert_nonnull(error);
      g_assert_cmpstr(g_quark_to_string(error->domain), ==, g_quark_to_string(WX_ERROR));
      g_assert_cmpint(error->code, ==, WX_ERROR_PARSE);
    }
    guard_free(g);
    g_byte_array_unref(buf);
  }
  g_assert_cmpuint(ok, >, 0);
}

/* ------------------------------------------------------------------------ */
/* Part 2: loopback fake server                                             */
/* ------------------------------------------------------------------------ */

#define WAIT_UNTIL(expr)                                                  \
  G_STMT_START {                                                          \
    gint64 deadline_ = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;      \
    while (!(expr)) {                                                     \
      if (!g_main_context_iteration(NULL, FALSE))                         \
        g_usleep(300);                                                    \
      g_assert_cmpint(g_get_monotonic_time(), <, deadline_);              \
    }                                                                     \
  }                                                                       \
  G_STMT_END

static void
spin_ms(guint ms)
{
  gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
  while (g_get_monotonic_time() < until) {
    if (!g_main_context_iteration(NULL, FALSE))
      g_usleep(300);
  }
}

typedef enum {
  R_RESPOND, /* status, headers, body, then close */
  R_GZIP,    /* 200 with the body gzip-compressed */
  R_HOLD,    /* like R_RESPOND, but the answer is sent only when the test calls fake_release() */
  R_HANG,    /* read the request, never answer; notes when the client closes */
  R_CLOSE,   /* close without answering */
} ReplyKind;

typedef struct {
  ReplyKind kind;
  guint status;
  const char *headers;  /* extra header lines, each ending in CRLF, or NULL */
  const char *body;     /* NUL-terminated, or NULL for "" */
  gsize declared;       /* Content-Length to announce when not 0 (it may exceed the body) */
  guint delay_ms;       /* R_RESPOND / R_GZIP: wait this long before answering */
} Reply;

typedef struct Fake Fake;
typedef Reply (*ReplyFn)(guint index, const char *path, gpointer data);

typedef struct {
  const Reply *steps;
  guint n;
} Script;

typedef struct {
  Fake *fake;
  GSocketConnection *connection;
  GString *request;
  guint8 buffer[2048];
  gboolean hanging;
  guint timer;
  GBytes *pending;
} Conn;

struct Fake {
  GSocketService *service;
  guint port;
  ReplyFn fn;
  gpointer fn_data;
  Script script;
  guint requests;     /* requests that reached the server */
  guint closed_early; /* hanging requests whose client closed the connection */
  guint connections;  /* connections accepted */
  GPtrArray *paths;   /* request target of every request (char *) */
  GPtrArray *heads;   /* complete head of every request (char *) */
  GHashTable *conns;  /* live connections */
};

static void conn_read(Conn *conn);

static void
conn_free(Conn *conn)
{
  g_hash_table_remove(conn->fake->conns, conn);
  if (conn->timer != 0)
    g_source_remove(conn->timer);
  if (conn->connection != NULL) {
    (void)g_io_stream_close(G_IO_STREAM(conn->connection), NULL, NULL);
    g_object_unref(conn->connection);
  }
  g_clear_pointer(&conn->pending, g_bytes_unref);
  g_string_free(conn->request, TRUE);
  g_free(conn);
}

static void
write_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gsize written;
  (void)g_output_stream_write_all_finish(G_OUTPUT_STREAM(source), result, &written, &error);
  conn_free(conn);
}

static void
respond_bytes(Conn *conn, GBytes *bytes)
{
  GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn->connection));
  gsize len;
  const void *data = g_bytes_get_data(bytes, &len);
  /* The bytes stay alive with the stream until the write completes. */
  g_object_set_data_full(G_OBJECT(out), "wx-test-bytes", g_bytes_ref(bytes),
                         (GDestroyNotify)g_bytes_unref);
  g_output_stream_write_all_async(out, data, len, G_PRIORITY_DEFAULT, NULL, write_done, conn);
}

static gboolean
on_delayed_answer(gpointer user_data)
{
  Conn *conn = user_data;
  conn->timer = 0;
  GBytes *bytes = g_steal_pointer(&conn->pending);
  respond_bytes(conn, bytes);
  g_bytes_unref(bytes);
  return G_SOURCE_REMOVE;
}

static GBytes *
gzip_of(const char *body)
{
  g_autoptr(GConverter) gzip = G_CONVERTER(g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, -1));
  g_autoptr(GOutputStream) mem = g_memory_output_stream_new_resizable();
  g_autoptr(GOutputStream) zout = g_converter_output_stream_new(mem, gzip);
  g_autoptr(GError) zerror = NULL;
  g_assert_true(g_output_stream_write_all(zout, body, strlen(body), NULL, NULL, &zerror));
  g_assert_true(g_output_stream_close(zout, NULL, &zerror));
  return g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(mem));
}

static void
handle_request(Conn *conn)
{
  Fake *fake = conn->fake;
  g_ptr_array_add(fake->heads, g_strdup(conn->request->str));
  const char *target = conn->request->str + 4; /* after "GET " */
  const char *end = strchr(target, ' ');
  char *path = end != NULL ? g_strndup(target, (gsize)(end - target)) : g_strdup(target);
  g_ptr_array_add(fake->paths, path);
  guint index = fake->requests++;
  Reply reply = fake->fn(index, path, fake->fn_data);
  switch (reply.kind) {
  case R_RESPOND:
  case R_HOLD:
  case R_GZIP: {
    const char *text = reply.body != NULL ? reply.body : "";
    g_autoptr(GBytes) payload = reply.kind == R_GZIP ? gzip_of(text) : g_bytes_new(text, strlen(text));
    gsize payload_len = g_bytes_get_size(payload);
    g_autofree char *head = g_strdup_printf(
        "HTTP/1.1 %u X\r\nContent-Type: application/json\r\n%s%sContent-Length: %" G_GSIZE_FORMAT
        "\r\nConnection: close\r\n\r\n",
        reply.status, reply.kind == R_GZIP ? "Content-Encoding: gzip\r\n" : "",
        reply.headers != NULL ? reply.headers : "", reply.declared != 0 ? reply.declared : payload_len);
    GByteArray *all = g_byte_array_new();
    g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
    g_byte_array_append(all, g_bytes_get_data(payload, NULL), (guint)payload_len);
    GBytes *bytes = g_byte_array_free_to_bytes(all);
    if (reply.kind == R_HOLD) {
      conn->pending = bytes; /* answered by fake_release() */
    } else if (reply.delay_ms > 0) {
      conn->pending = bytes;
      conn->timer = g_timeout_add(reply.delay_ms, on_delayed_answer, conn);
    } else {
      respond_bytes(conn, bytes);
      g_bytes_unref(bytes);
    }
    break;
  }
  case R_HANG:
    conn->hanging = TRUE;
    conn_read(conn); /* keep reading: end of stream means the client gave up */
    break;
  case R_CLOSE:
    conn_free(conn);
    break;
  }
}

static void
read_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gssize n = g_input_stream_read_finish(G_INPUT_STREAM(source), result, &error);
  if (n <= 0) {
    if (conn->hanging)
      conn->fake->closed_early++;
    conn_free(conn);
    return;
  }
  if (conn->hanging) {
    conn_read(conn);
    return;
  }
  g_string_append_len(conn->request, (const char *)conn->buffer, n);
  if (strstr(conn->request->str, "\r\n\r\n") != NULL)
    handle_request(conn);
  else
    conn_read(conn);
}

static void
conn_read(Conn *conn)
{
  g_input_stream_read_async(g_io_stream_get_input_stream(G_IO_STREAM(conn->connection)), conn->buffer,
                            sizeof conn->buffer, G_PRIORITY_DEFAULT, NULL, read_done, conn);
}

static gboolean
on_incoming(GSocketService *service, GSocketConnection *connection, GObject *source,
            gpointer user_data)
{
  (void)service;
  (void)source;
  Conn *conn = g_new0(Conn, 1);
  conn->fake = user_data;
  conn->fake->connections++;
  conn->connection = g_object_ref(connection);
  conn->request = g_string_new(NULL);
  g_hash_table_add(conn->fake->conns, conn);
  conn_read(conn);
  return TRUE;
}

static Reply
script_reply(guint index, const char *path, gpointer data)
{
  (void)path;
  const Script *script = data;
  return script->steps[MIN(index, script->n - 1)];
}

static Fake *
fake_new_fn(ReplyFn fn, gpointer data)
{
  Fake *fake = g_new0(Fake, 1);
  fake->fn = fn;
  fake->fn_data = data;
  fake->paths = g_ptr_array_new_with_free_func(g_free);
  fake->heads = g_ptr_array_new_with_free_func(g_free);
  fake->conns = g_hash_table_new(NULL, NULL);
  fake->service = g_socket_service_new();
  g_autoptr(GError) error = NULL;
  guint16 port = g_socket_listener_add_any_inet_port(G_SOCKET_LISTENER(fake->service), NULL, &error);
  g_assert_no_error(error);
  fake->port = port;
  g_signal_connect(fake->service, "incoming", G_CALLBACK(on_incoming), fake);
  g_socket_service_start(fake->service);
  return fake;
}

/* A fake whose replies are @steps in request order; the last one repeats. */
static Fake *
fake_new_script(const Reply *steps, guint n)
{
  Fake *fake = fake_new_fn(script_reply, NULL);
  fake->script.steps = steps;
  fake->script.n = n;
  fake->fn_data = &fake->script;
  return fake;
}

static void
fake_free(Fake *fake)
{
  g_socket_service_stop(fake->service);
  g_socket_listener_close(G_SOCKET_LISTENER(fake->service));
  /* Connections with an answer still scheduled have no I/O pending: drop them now. The others
   * have a read or a write pending whose callback points at the fake: close them and let every
   * callback run before the fake goes away. */
  GList *conns = g_hash_table_get_keys(fake->conns);
  for (GList *l = conns; l != NULL; l = l->next) {
    Conn *conn = l->data;
    if (conn->timer != 0 || conn->pending != NULL) /* an answer is scheduled or held back */
      conn_free(conn);
    else
      (void)g_io_stream_close(G_IO_STREAM(conn->connection), NULL, NULL);
  }
  g_list_free(conns);
  gint64 until = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
  while (g_hash_table_size(fake->conns) > 0 && g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, FALSE);
  g_assert_cmpuint(g_hash_table_size(fake->conns), ==, 0);
  g_object_unref(fake->service);
  g_hash_table_unref(fake->conns);
  g_ptr_array_unref(fake->paths);
  g_ptr_array_unref(fake->heads);
  g_free(fake);
}

/* Sends the answers that R_HOLD replies held back. */
static void
fake_release(Fake *fake)
{
  GList *conns = g_hash_table_get_keys(fake->conns);
  for (GList *l = conns; l != NULL; l = l->next) {
    Conn *conn = l->data;
    if (conn->pending != NULL && conn->timer == 0) {
      GBytes *bytes = g_steal_pointer(&conn->pending);
      respond_bytes(conn, bytes);
      g_bytes_unref(bytes);
    }
  }
  g_list_free(conns);
}

static const char *
fake_path(const Fake *fake, guint index)
{
  g_assert_cmpuint(index, <, fake->paths->len);
  return g_ptr_array_index(fake->paths, index);
}

static const char *
fake_head(const Fake *fake, guint index)
{
  g_assert_cmpuint(index, <, fake->heads->len);
  return g_ptr_array_index(fake->heads, index);
}

/* The number of requests the server has seen, after the pending ones had time to arrive. */
static void
assert_requests(const Fake *fake, guint n)
{
  spin_ms(25);
  g_assert_cmpuint(fake->requests, ==, n);
}

/* Request @index: one GET request line for @path, only the expected headers, the identifying
 * User-Agent and the JSON Accept value, If-Modified-Since exactly when @ims is given. */
static void
assert_request(const Fake *fake, guint index, const char *path, const char *ims)
{
  const char *head = fake_head(fake, index);
  g_autofree char *line = g_strdup_printf("GET %s HTTP/1.1\r\n", path);
  g_assert_true(g_str_has_prefix(head, line));
  g_assert_cmpstr(fake_path(fake, index), ==, path);
  g_assert_true(g_str_has_suffix(head, "\r\n\r\n"));
  g_auto(GStrv) lines = g_strsplit(head, "\r\n", -1);
  guint request_lines = 0;
  gboolean saw_ua = FALSE, saw_accept = FALSE, saw_host = FALSE, saw_ims = FALSE;
  for (guint i = 0; lines[i] != NULL && lines[i][0] != '\0'; i++) {
    if (strstr(lines[i], " HTTP/1.") != NULL)
      request_lines++;
    if (i == 0)
      continue;
    const char *colon = strchr(lines[i], ':');
    g_assert_nonnull(colon);
    g_autofree char *name = g_ascii_strdown(lines[i], colon - lines[i]);
    g_assert_true(g_strv_contains((const char *const[]){"host", "user-agent", "accept", "accept-encoding",
                                                         "connection", "if-modified-since", NULL},
                                  name));
    if (g_str_equal(name, "user-agent")) {
      saw_ua = TRUE;
      g_assert_cmpstr(colon + 2, ==, WX_METNO_USER_AGENT);
    } else if (g_str_equal(name, "accept")) {
      saw_accept = TRUE;
      g_assert_cmpstr(colon + 2, ==, "application/json");
    } else if (g_str_equal(name, "host")) {
      saw_host = TRUE;
      g_autofree char *expected = g_strdup_printf("127.0.0.1:%u", fake->port);
      g_assert_cmpstr(colon + 2, ==, expected);
    } else if (g_str_equal(name, "if-modified-since")) {
      saw_ims = TRUE;
      g_assert_cmpstr(ims, !=, NULL);
      g_assert_cmpstr(colon + 2, ==, ims);
    }
  }
  g_assert_cmpuint(request_lines, ==, 1);
  g_assert_true(saw_ua && saw_accept && saw_host);
  g_assert_cmpint(saw_ims, ==, ims != NULL);
  for (const char *const *f = (const char *const[]){"Cookie", "Authorization", "Referer", "Origin",
                                                     "Mozilla", "Proxy-Authorization", "X-", NULL};
       *f != NULL; f++)
    g_assert_null(g_strstr_len(head, -1, *f));
}

/* ------------------------------------------------------------------------ */
/* Part 2: harness                                                          */
/* ------------------------------------------------------------------------ */

/* The test clock: fixed at clock_value, or the real time plus clock_offset. */
static gboolean clock_fixed;
static gint64 clock_value;

static gint64
test_clock(void)
{
  return clock_fixed ? clock_value : real_now_s();
}

static void
clock_set(gint64 t)
{
  clock_fixed = TRUE;
  clock_value = t;
  wx_metno_test_set_clock(test_clock);
}

static void
clock_system(void)
{
  clock_fixed = FALSE;
  wx_metno_test_set_clock(test_clock);
}

static WxMetno *
metno_for(const Fake *fake)
{
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(GError) error = NULL;
  WxMetno *metno = wx_metno_new_custom(base, 3000, 1, &error);
  g_assert_no_error(error);
  g_assert_nonnull(metno);
  return metno;
}

static WxPlace *
place_at(double lat, double lon)
{
  g_autoptr(GError) error = NULL;
  WxPlace *place = wx_place_new("Test place", "", "", "", lat, lon, "", &error);
  g_assert_no_error(error);
  g_assert_nonnull(place);
  return place;
}

#define MIAMI_LAT 25.7617
#define MIAMI_LON (-80.1918)
#define LONDON_LAT 51.5072
#define LONDON_LON (-0.1276)
#define MIAMI_PATH "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918"
#define LONDON_PATH "/weatherapi/locationforecast/2.0/complete?lat=51.5072&lon=-0.1276"

typedef struct _Outcome Outcome;
struct _Outcome {
  gboolean done;
  guint calls;
  WxSourceResult *result;
  GError *error;
  GCancellable *cancel_first; /* cancelled in the callback before it finishes the fetch */
  void (*then)(Outcome *);    /* run at the end of the callback */
  gpointer data;
};

static void
outcome_clear(Outcome *o)
{
  if (o->result != NULL)
    wx_source_result_free(o->result);
  g_clear_error(&o->error);
  memset(o, 0, sizeof *o);
}

static void
on_fetch(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->calls++;
  if (o->cancel_first != NULL)
    g_cancellable_cancel(o->cancel_first);
  o->result = wx_provider_fetch_finish(WX_PROVIDER(source), result, &o->error);
  o->done = TRUE;
  if (o->then != NULL)
    o->then(o);
}

/* Starts a fetch and checks that its callback has not run yet. */
static void
fetch_start(WxMetno *metno, const WxPlace *place, GCancellable *cancellable, Outcome *o)
{
  wx_provider_fetch_async(WX_PROVIDER(metno), place, cancellable, on_fetch, o);
  g_assert_false(o->done);
  g_assert_cmpuint(o->calls, ==, 0);
}

static void
fetch_wait(Outcome *o)
{
  WAIT_UNTIL(o->done);
}

static void
fetch(WxMetno *metno, const WxPlace *place, Outcome *o)
{
  fetch_start(metno, place, NULL, o);
  fetch_wait(o);
}

/* The one member of a successful outcome. */
static WxMember *
outcome_member(const Outcome *o)
{
  g_assert_no_error(o->error);
  g_assert_nonnull(o->result);
  g_assert_cmpstr(o->result->provider_id, ==, "met-no");
  g_assert_cmpuint(o->result->members->len, ==, 1);
  WxMember *member = g_ptr_array_index(o->result->members, 0);
  g_assert_cmpstr(wx_member_get_source_id(member), ==, "met-no");
  g_assert_cmpstr(wx_member_get_model_id(member), ==, "ecmwf");
  return member;
}

static void
outcome_assert_failed(const Outcome *o, int code, const char *message)
{
  g_assert_null(o->result);
  assert_error(o->error, WX_ERROR, code, message);
}

static void
outcome_assert_cancelled(const Outcome *o)
{
  g_assert_null(o->result);
  g_assert_nonnull(o->error);
  g_assert_cmpstr(g_quark_to_string(o->error->domain), ==, g_quark_to_string(G_IO_ERROR));
  g_assert_cmpint(o->error->code, ==, G_IO_ERROR_CANCELLED);
}

/* Fetches @place, expects success and returns the member (borrowed from @o). */
static WxMember *
fetch_ok(WxMetno *metno, const WxPlace *place, Outcome *o)
{
  outcome_clear(o);
  fetch(metno, place, o);
  return outcome_member(o);
}

static Reply
ok_reply(const char *headers)
{
  return (Reply){R_RESPOND, 200, headers, miami_text, 0, 0};
}

/* ------------------------------------------------------------------------ */
/* Part 2: identity and construction                                        */
/* ------------------------------------------------------------------------ */

static void
test_provider_identity(void)
{
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  WxProvider *provider = WX_PROVIDER(metno);
  g_assert_true(WX_IS_PROVIDER(metno));
  g_assert_false(WX_IS_GEOCODER(metno));
  g_assert_cmpstr(wx_provider_get_id(provider), ==, "met-no");
  g_assert_cmpstr(wx_provider_get_name(provider), ==, "MET Norway");
  g_assert_cmpstr(wx_provider_get_attribution(provider), ==, "Data from MET Norway");
  g_assert_cmpstr(wx_provider_get_attribution_url(provider), ==, "https://api.met.no/");
  g_assert_true(g_str_has_prefix(wx_provider_get_attribution_url(provider), "https://"));
  g_assert_true(wx_id_is_valid(wx_provider_get_id(provider)));
  /* Constant for the whole life of the instance. */
  g_assert_true(wx_provider_get_id(provider) == wx_provider_get_id(provider));
  g_assert_true(g_utf8_validate(wx_provider_get_name(provider), -1, NULL));
  g_assert_true(g_utf8_validate(wx_provider_get_attribution(provider), -1, NULL));

  /* Covers every place with valid coordinates, whatever the other fields are. */
  const double lats[] = {25.7617, 51.5072, -33.8688, 90.0, -90.0, 0.0, 69.6492};
  const double lons[] = {-80.1918, -0.1276, 151.2093, 180.0, -180.0, 0.0, 18.9553};
  for (guint i = 0; i < G_N_ELEMENTS(lats); i++) {
    g_autoptr(WxPlace) place = place_at(lats[i], lons[i]);
    g_assert_true(wx_provider_covers(provider, place));
  }
  WxPlace hand = {(char *)"x", (char *)"", (char *)"", {0}, NAN, 0.0, (char *)""};
  g_assert_false(wx_provider_covers(provider, &hand));
  hand.lat = 0.0;
  hand.lon = 181.0;
  g_assert_false(wx_provider_covers(provider, &hand));
  hand.lon = 0.0;
  hand.name = NULL; /* strings are not looked at */
  g_assert_true(wx_provider_covers(provider, &hand));
  assert_requests(fake, 0);
  fake_free(fake);
}

/* wx_metno_new(): the production origin and timing; nothing is sent until a fetch. */
static void
test_new_production(void)
{
  g_autoptr(WxMetno) metno = wx_metno_new();
  g_assert_nonnull(metno);
  g_assert_true(WX_IS_PROVIDER(metno));
  g_assert_cmpstr(wx_provider_get_id(WX_PROVIDER(metno)), ==, "met-no");
  g_autoptr(WxPlace) place = place_at(MIAMI_LAT, MIAMI_LON);
  g_assert_true(wx_provider_covers(WX_PROVIDER(metno), place));
  /* An invalid place is refused before any request: safe to run against the real origin. */
  WxPlace hand = {(char *)"x", (char *)"", (char *)"", {0}, NAN, 0.0, (char *)""};
  Outcome o = {0};
  fetch(metno, &hand, &o);
  outcome_assert_failed(&o, WX_ERROR_INVALID_ARG, "invalid place");
  outcome_clear(&o);
}

static void
test_new_custom_validation(void)
{
  g_autoptr(GError) error = NULL;
  const char *bad[] = {"ftp://127.0.0.1:1", "http://example.com", "http://api.met.no",
                       "https://user:pw@api.met.no", "https://api.met.no/x", "https://api.met.no?q=1",
                       "https://api.met.no#f", "", "not a url", "https://"};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_assert_null(wx_metno_new_custom(bad[i], 1000, 1, &error));
    assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG, "unacceptable base URL");
    g_clear_error(&error);
  }
  const char *good[] = {"https://api.met.no", "https://api.met.no/", "http://127.0.0.1:8080",
                        "http://localhost:9", "http://[::1]:9"};
  for (guint i = 0; i < G_N_ELEMENTS(good); i++) {
    g_autoptr(WxMetno) metno = wx_metno_new_custom(good[i], 1000, 0, &error);
    g_assert_no_error(error);
    g_assert_nonnull(metno);
  }
  /* A NULL error location is fine. */
  g_assert_null(wx_metno_new_custom("http://example.com", 1000, 1, NULL));
  /* Programmer errors: a critical and NULL, no error set. */
  ASSERT_CRITICAL("base_url != NULL", g_assert_null(wx_metno_new_custom(NULL, 1000, 1, &error)));
  g_assert_no_error(error);
  ASSERT_CRITICAL("timeout_ms", g_assert_null(wx_metno_new_custom("https://api.met.no", 0, 1, &error)));
  g_assert_no_error(error);
}

static void
test_registry_integration(void)
{
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(metno), &error));
  g_assert_no_error(error);
  g_assert_true(wx_registry_find_provider(registry, "met-no") == WX_PROVIDER(metno));
  g_assert_true(wx_registry_is_enabled(registry, "met-no"));
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, miami);
  g_assert_cmpuint(covering->len, ==, 1);
  g_assert_true(g_ptr_array_index(covering, 0) == WX_PROVIDER(metno));
  g_autoptr(GPtrArray) covering2 = wx_registry_list_covering(registry, sydney);
  g_assert_cmpuint(covering2->len, ==, 1);
  g_assert_true(wx_registry_set_enabled(registry, "met-no", FALSE));
  g_autoptr(GPtrArray) none = wx_registry_list_covering(registry, miami);
  g_assert_cmpuint(none->len, ==, 0);
  /* The same id twice is refused by the registry. */
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(metno), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  assert_requests(fake, 0);
  fake_free(fake);
}

/* ------------------------------------------------------------------------ */
/* Part 2: requests and the cache                                           */
/* ------------------------------------------------------------------------ */

static void
test_net_success_and_request_shape(void)
{
  clock_system();
  gint64 before = real_now_s();
  g_autofree char *lm = http_date(before - 100);
  g_autofree char *ex = http_date(before + 1800);
  g_autofree char *headers = g_strdup_printf("Last-Modified: %s\r\nExpires: %s\r\n", lm, ex);
  Reply steps[] = {{R_GZIP, 200, headers, miami_text, 0, 0}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  WxMember *member = fetch_ok(metno, miami, &o);
  assert_requests(fake, 1);
  assert_request(fake, 0, MIAMI_PATH, NULL);
  gint64 after = real_now_s();
  g_assert_cmpint(wx_member_get_fetched_s(member), >=, before);
  g_assert_cmpint(wx_member_get_fetched_s(member), <=, after);
  assert_member_invariants(member);
  assert_matches_oracle(miami_text, miami_len, member);
  g_assert_cmpuint(member->n_hours, ==, 92);
  g_assert_cmpuint(o.calls, ==, 1);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_london_fixture(void)
{
  clock_system();
  Reply steps[] = {{R_RESPOND, 200, NULL, london_text, 0, 0}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o = {0};
  WxMember *member = fetch_ok(metno, london, &o);
  assert_request(fake, 0, LONDON_PATH, NULL);
  assert_matches_oracle(london_text, london_len, member);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* The coordinates are ROUNDED to four decimals (printf "%.4f"), not truncated. */
static void
test_net_coordinates_are_rounded(void)
{
  clock_system();
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  struct {
    double lat, lon;
    const char *path;
  } cases[] = {
      {25.76174999, -80.19184999, MIAMI_PATH},
      {25.76176, -80.19186, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919"},
      {-0.00001, 0.00001, "/weatherapi/locationforecast/2.0/complete?lat=0.0000&lon=0.0000"},
      {-33.868812345, 151.209312345, "/weatherapi/locationforecast/2.0/complete?lat=-33.8688&lon=151.2093"},
      {90.0, -180.0, "/weatherapi/locationforecast/2.0/complete?lat=90.0000&lon=-180.0000"},
  };
  Outcome o = {0};
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(WxPlace) place = place_at(cases[i].lat, cases[i].lon);
    (void)fetch_ok(metno, place, &o);
    assert_requests(fake, i + 1);
    assert_request(fake, i, cases[i].path, NULL);
  }
  outcome_clear(&o);
  /* Random places: every target has exactly four decimals on both coordinates. */
  g_autoptr(GRegex) shape = g_regex_new(
      "^/weatherapi/locationforecast/2\\.0/complete\\?lat=-?[0-9]{1,2}\\.[0-9]{4}&lon=-?[0-9]{1,3}\\.[0-9]{4}$",
      0, 0, NULL);
  g_assert_nonnull(shape);
  g_autoptr(GRand) rand = g_rand_new_with_seed(77);
  guint base = fake->requests;
  for (guint i = 0; i < 40; i++) {
    g_autoptr(WxPlace) place =
        place_at(g_rand_double_range(rand, -90, 90), g_rand_double_range(rand, -180, 180));
    (void)fetch_ok(metno, place, &o);
  }
  outcome_clear(&o);
  g_assert_cmpuint(fake->requests, ==, base + 40);
  for (guint i = base; i < fake->requests; i++)
    g_assert_true(g_regex_match(shape, fake_path(fake, i), 0, NULL));
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* The cache key is the "%.4f" text of the two coordinates: places whose texts are identical share
 * one entry (the places 25.76170 and 25.76174 both print 25.7617), places whose texts differ do not
 * (25.76176 prints 25.7618) - rounding, not truncation, decides. */
static void
test_net_cache_key_is_the_rounded_coordinates(void)
{
  clock_set(real_now_s());
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  Outcome o = {0};
  g_autoptr(WxPlace) a = place_at(25.76170, -80.19180);
  g_autoptr(WxPlace) b = place_at(25.761700004, -80.191799996);
  g_autoptr(WxPlace) c = place_at(25.76174, -80.19184);
  g_autoptr(WxPlace) d = place_at(25.76176, -80.19180);
  WxMember *ma = fetch_ok(metno, a, &o);
  g_autoptr(WxMember) keep = wx_member_ref(ma);
  WxMember *mb = fetch_ok(metno, b, &o);
  g_assert_true(mb == keep);
  WxMember *mc = fetch_ok(metno, c, &o);
  g_assert_true(mc == keep);
  assert_requests(fake, 1);
  (void)fetch_ok(metno, d, &o); /* 25.7618: another place */
  assert_requests(fake, 2);
  assert_request(fake, 1, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1918", NULL);
  /* Each coordinate and its sign are part of the identity of a place. */
  const struct {
    double lat, lon;
    const char *path;
  } others[] = {
      {25.7617, -80.1919, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1919"},
      {25.7617, 80.1918, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=80.1918"},
      {-25.7617, -80.1918, "/weatherapi/locationforecast/2.0/complete?lat=-25.7617&lon=-80.1918"},
      {-25.7617, 80.1918, "/weatherapi/locationforecast/2.0/complete?lat=-25.7617&lon=80.1918"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(others); i++) {
    g_autoptr(WxPlace) place = place_at(others[i].lat, others[i].lon);
    (void)fetch_ok(metno, place, &o);
    assert_requests(fake, 3 + i);
    assert_request(fake, 2 + i, others[i].path, NULL);
  }
  /* Rounding, not truncation: (25.76176, -80.19186) prints 25.7618 / -80.1919 although truncating
   * it would give 25.7617 / -80.1918, the place of a, b and c above, which is fresh in the cache.
   * It is a request of its own, and a place that rounds to the same text shares its entry. */
  g_autofree char *down = wx_metno_forecast_path(25.76174, -80.19184);
  g_autofree char *same = wx_metno_forecast_path(25.76170, -80.19180);
  g_autofree char *up = wx_metno_forecast_path(25.76176, -80.19186);
  g_assert_cmpstr(down, ==, same);
  g_assert_cmpstr(down, !=, up);
  g_assert_cmpstr(up, ==, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919");
  const guint before = fake->requests;
  g_autoptr(WxPlace) e = place_at(25.76176, -80.19186);
  g_autoptr(WxPlace) g = place_at(25.76184, -80.19194);
  WxMember *me = fetch_ok(metno, e, &o);
  g_assert_true(me != keep);
  assert_requests(fake, before + 1);
  assert_request(fake, before, "/weatherapi/locationforecast/2.0/complete?lat=25.7618&lon=-80.1919", NULL);
  g_autoptr(WxMember) keep_e = wx_member_ref(me);
  g_assert_true(fetch_ok(metno, g, &o) == keep_e);
  assert_requests(fake, before + 1);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_floor_and_revalidation(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm1 = http_date(t0 - 500);
  g_autofree char *lm2 = http_date(t0 + 700);
  g_autofree char *h1 = g_strdup_printf("Last-Modified: %s\r\n", lm1);
  g_autofree char *h2 = g_strdup_printf("Last-Modified: %s\r\n", lm2);
  Reply steps[] = {ok_reply(h1), ok_reply(h2), ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 3);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  WxMember *a = fetch_ok(metno, miami, &o);
  g_autoptr(WxMember) member_a = wx_member_ref(a);
  assert_request(fake, 0, MIAMI_PATH, NULL);
  g_assert_cmpint(wx_member_get_fetched_s(a), ==, t0);

  /* Inside the floor: no request, the very same member. */
  const gint64 inside[] = {t0, t0 + 1, t0 + 300, t0 + 599};
  for (guint i = 0; i < G_N_ELEMENTS(inside); i++) {
    clock_set(inside[i]);
    g_assert_true(fetch_ok(metno, miami, &o) == member_a);
    assert_requests(fake, 1);
  }
  /* 600 s after the answer: revalidate with the stored Last-Modified. */
  clock_set(t0 + 600);
  WxMember *b = fetch_ok(metno, miami, &o);
  g_assert_true(b != member_a);
  assert_requests(fake, 2);
  assert_request(fake, 1, MIAMI_PATH, lm1);
  g_assert_cmpint(wx_member_get_fetched_s(b), ==, t0 + 600);
  g_autoptr(WxMember) member_b = wx_member_ref(b);
  /* The floor restarts from the new answer. */
  clock_set(t0 + 1199);
  g_assert_true(fetch_ok(metno, miami, &o) == member_b);
  assert_requests(fake, 2);
  clock_set(t0 + 1200);
  WxMember *c = fetch_ok(metno, miami, &o);
  g_assert_true(c != member_b);
  assert_requests(fake, 3);
  assert_request(fake, 2, MIAMI_PATH, lm2);
  /* The third answer carried no Last-Modified: the next request has no validator. */
  clock_set(t0 + 1800);
  (void)fetch_ok(metno, miami, &o);
  assert_requests(fake, 4);
  assert_request(fake, 3, MIAMI_PATH, NULL);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_not_modified(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm1 = http_date(t0 - 500);
  g_autofree char *lm2 = http_date(t0 + 900);
  g_autofree char *expires = http_date(t0 + 1800);
  g_autofree char *h1 = g_strdup_printf("Last-Modified: %s\r\n", lm1);
  g_autofree char *h304_expires = g_strdup_printf("Expires: %s\r\n", expires);
  g_autofree char *h304_lm = g_strdup_printf("Last-Modified: %s\r\n", lm2);
  Reply steps[] = {
      ok_reply(h1),
      {R_RESPOND, 304, h304_expires, "", 0, 0}, /* no Last-Modified: the validator stays */
      {R_RESPOND, 304, h304_lm, "", 0, 0},      /* a new Last-Modified replaces it */
      ok_reply(NULL),
  };
  Fake *fake = fake_new_script(steps, 4);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  WxMember *a = fetch_ok(metno, miami, &o);
  g_autoptr(WxMember) member_a = wx_member_ref(a);

  clock_set(t0 + 601);
  WxMember *again = fetch_ok(metno, miami, &o);
  g_assert_true(again == member_a);                       /* the cached member, not a copy */
  g_assert_cmpint(wx_member_get_fetched_s(again), ==, t0); /* its data is still the old download */
  assert_requests(fake, 2);
  assert_request(fake, 1, MIAMI_PATH, lm1);
  g_assert_cmpuint(o.result->members->len, ==, 1);
  /* The 304 renewed the entry: floor from t0 + 601, and the new Expires time. */
  clock_set(t0 + 1200);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 2);
  clock_set(t0 + 1799); /* before the Expires of the 304, though past its floor */
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 2);
  clock_set(t0 + 1800);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 3);
  assert_request(fake, 2, MIAMI_PATH, lm1); /* the 304 had no Last-Modified: the old one is kept */
  /* The next 304 brought lm2. */
  clock_set(t0 + 1800 + 599);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 3);
  clock_set(t0 + 1800 + 600);
  WxMember *fresh = fetch_ok(metno, miami, &o);
  g_assert_true(fresh != member_a);
  assert_requests(fake, 4);
  assert_request(fake, 3, MIAMI_PATH, lm2);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_expires(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *expires = http_date(t0 + 1800);
  g_autofree char *headers = g_strdup_printf("Last-Modified: %s\r\nExpires: %s\r\n", lm, expires);
  Reply steps[] = {ok_reply(headers), ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 2);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  WxMember *a = fetch_ok(metno, miami, &o);
  g_autoptr(WxMember) member_a = wx_member_ref(a);
  /* Past the 600 s floor but before Expires: still fresh. */
  const gint64 fresh_times[] = {t0 + 601, t0 + 1000, t0 + 1799};
  for (guint i = 0; i < G_N_ELEMENTS(fresh_times); i++) {
    clock_set(fresh_times[i]);
    g_assert_true(fetch_ok(metno, miami, &o) == member_a);
    assert_requests(fake, 1);
  }
  clock_set(t0 + 1800); /* Expires is not "before" any more */
  g_assert_true(fetch_ok(metno, miami, &o) != member_a);
  assert_requests(fake, 2);
  assert_request(fake, 1, MIAMI_PATH, lm);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* An Expires time that WxHttp refuses (past, more than 24 h away, garbage) does not extend the
 * floor: the entry is stale after 600 s. */
static void
test_net_implausible_expires_is_ignored(void)
{
  const gint64 t0 = real_now_s();
  g_autofree char *past = http_date(t0 - 3600);
  g_autofree char *far = http_date(t0 + 2 * 86400);
  g_autofree char *h_past = g_strdup_printf("Expires: %s\r\n", past);
  g_autofree char *h_far = g_strdup_printf("Expires: %s\r\n", far);
  const char *headers[] = {h_past, h_far, "Expires: soon\r\n", "Expires: 0\r\n", "Expires: -1\r\n", ""};
  for (guint i = 0; i < G_N_ELEMENTS(headers); i++) {
    clock_set(t0);
    Reply steps[] = {ok_reply(headers[i])};
    Fake *fake = fake_new_script(steps, 1);
    g_autoptr(WxMetno) metno = metno_for(fake);
    g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
    Outcome o = {0};
    (void)fetch_ok(metno, miami, &o);
    clock_set(t0 + 599);
    (void)fetch_ok(metno, miami, &o);
    assert_requests(fake, 1);
    clock_set(t0 + 600);
    (void)fetch_ok(metno, miami, &o);
    assert_requests(fake, 2);
    outcome_clear(&o);
    fake_free(fake);
  }
  wx_metno_test_set_clock(NULL);
}

/* An Expires time is honoured for at most 24 hours after the answer that carried it, measured on
 * the provider's own clock (here two days behind the real time, so WxHttp, which compares with the
 * real time, accepts an Expires 30 minutes ahead of the real time). */
static void
test_net_expires_is_capped_at_24_hours(void)
{
  const gint64 real = real_now_s();
  const gint64 t0 = real - 2 * 86400;
  clock_set(t0);
  g_autofree char *expires = http_date(real + 1800);
  g_autofree char *headers = g_strdup_printf("Expires: %s\r\n", expires);
  Reply steps[] = {ok_reply(headers), ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 2);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  WxMember *a = fetch_ok(metno, miami, &o);
  g_autoptr(WxMember) member_a = wx_member_ref(a);
  clock_set(t0 + 86399);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 1);
  clock_set(t0 + 86400);
  g_assert_true(fetch_ok(metno, miami, &o) != member_a);
  assert_requests(fake, 2);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_clock_going_backwards(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Reply steps[] = {ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  (void)fetch_ok(metno, miami, &o);
  /* An answer from the future of the clock is not trusted: ask again. */
  clock_set(t0 - 1);
  (void)fetch_ok(metno, miami, &o);
  assert_requests(fake, 2);
  clock_set(t0 - 100000);
  (void)fetch_ok(metno, miami, &o);
  assert_requests(fake, 3);
  /* The entry now dates from t0 - 100000: fresh again for 600 s there. */
  clock_set(t0 - 100000 + 599);
  (void)fetch_ok(metno, miami, &o);
  assert_requests(fake, 3);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_clock_extremes(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Reply steps[] = {ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o = {0};
  /* A clock outside the accepted time range cannot stamp a member: reported, never a crash. Every
   * extreme gets a provider of its own: the request that failed is recorded for the floor of its
   * place, and several of the clocks below read the same value after clamping. */
  const gint64 extremes[] = {G_MININT64, G_MININT64 + 1, -1, 0, G_MAXINT64, G_MAXINT64 - 1,
                             G_MAXINT64 / 4, G_MAXINT64 / 4 + 1, WX_TIME_MAX_S, WX_TIME_MIN_S - 1};
  guint expected = 0;
  for (guint i = 0; i < G_N_ELEMENTS(extremes); i++) {
    g_autoptr(WxMetno) metno = metno_for(fake);
    clock_set(t0);
    outcome_clear(&o);
    (void)fetch_ok(metno, miami, &o);
    expected++;
    clock_set(extremes[i]);
    outcome_clear(&o);
    fetch(metno, london, &o);
    expected++;
    outcome_assert_failed(&o, WX_ERROR_INVALID_ARG, "fetch time out of range");
    outcome_clear(&o);
    fetch(metno, miami, &o); /* the cached place is stale for such a clock: also a request */
    expected++;
    outcome_assert_failed(&o, WX_ERROR_INVALID_ARG, "fetch time out of range");
    assert_requests(fake, expected);
  }
  g_autoptr(WxMetno) metno = metno_for(fake);
  clock_set(t0);
  outcome_clear(&o);
  (void)fetch_ok(metno, miami, &o);
  expected++;
  /* The entry from t0 is still there: served at t0 + 5, no request. */
  clock_set(t0 + 5);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  (void)outcome_member(&o);
  assert_requests(fake, expected);
  /* The smallest and the largest valid readings work. */
  clock_set(WX_TIME_MIN_S);
  outcome_clear(&o);
  fetch(metno, london, &o);
  g_assert_cmpint(wx_member_get_fetched_s(outcome_member(&o)), ==, WX_TIME_MIN_S);
  clock_set(WX_TIME_MAX_S - 1);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  g_assert_cmpint(wx_member_get_fetched_s(outcome_member(&o)), ==, WX_TIME_MAX_S - 1);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* The message of a fetch refused by the per-place floor (no entry to serve). */
#define FLOOR_MESSAGE "a request for this place was sent less than 10 minutes ago"

/* A fetch of @place that the floor refuses: RATE_LIMITED with the floor's message, and the server
 * has seen @requests requests in total. */
static void
assert_floor_refusal(WxMetno *metno, const WxPlace *place, const Fake *fake, guint requests)
{
  Outcome o = {0};
  fetch(metno, place, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, FLOOR_MESSAGE);
  assert_requests(fake, requests);
  outcome_clear(&o);
}

/* A request that failed counts for the floor like an answered one: while it is less than 600 s
 * old, the stale entry (also one whose Expires time has passed) is served and nothing is sent. */
static void
test_net_floor_after_failure_serves_the_cache(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *expires = http_date(t0 + 650);
  g_autofree char *h = g_strdup_printf("Last-Modified: %s\r\nExpires: %s\r\n", lm, expires);
  const Reply down = {R_RESPOND, 500, NULL, "{}", 0, 0};
  Reply steps[] = {ok_reply(h), down, down, down, {R_RESPOND, 304, NULL, "", 0, 0}};
  Fake *fake = fake_new_script(steps, G_N_ELEMENTS(steps));
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  g_autoptr(WxMember) member_a = wx_member_ref(fetch_ok(metno, miami, &o));
  /* t0 + 700: the floor of the answer and the Expires time (t0 + 650) are over: a request. */
  clock_set(t0 + 700);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 500 Internal Server Error");
  assert_requests(fake, 4); /* the first attempt and two retries, all with the validator */
  for (guint i = 1; i < 4; i++)
    assert_request(fake, i, MIAMI_PATH, lm);
  /* For 600 s after that request nothing is sent; the cached member is served, although stale. */
  const gint64 held[] = {700, 701, 702, 1000, 1299};
  for (guint i = 0; i < G_N_ELEMENTS(held); i++) {
    clock_set(t0 + held[i]);
    outcome_clear(&o);
    g_assert_true(fetch_ok(metno, miami, &o) == member_a);
    g_assert_cmpint(wx_member_get_fetched_s(outcome_member(&o)), ==, t0);
    assert_requests(fake, 4);
  }
  /* t0 + 1300 = 700 + 600: a request again; its 304 renews the entry. */
  clock_set(t0 + 1300);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 5);
  assert_request(fake, 4, MIAMI_PATH, lm);
  clock_set(t0 + 1899);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == member_a);
  assert_requests(fake, 5);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A fetch that was refused before anything was sent leaves the floor of its place alone, and a
 * request that was started counts although it was cancelled at once. */
static void
test_net_floor_counts_started_requests_only(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Reply steps[] = {{R_HANG, 0, NULL, NULL, 0, 0}, ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 2);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  /* Cancelled before the call: nothing is sent, no floor. */
  g_autoptr(GCancellable) pre = g_cancellable_new();
  g_cancellable_cancel(pre);
  fetch_start(metno, miami, pre, &o);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  g_assert_cmpuint(fake->connections, ==, 0);
  outcome_clear(&o);
  /* The next fetch of the place is a request at once (the first, hanging one) ... */
  g_autoptr(GCancellable) c = g_cancellable_new();
  fetch_start(metno, miami, c, &o);
  WAIT_UNTIL(fake->requests == 1);
  g_cancellable_cancel(c);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  WAIT_UNTIL(fake->closed_early == 1);
  outcome_clear(&o);
  /* ... and being cancelled afterwards does not undo it: for 600 s nothing more is sent. */
  const gint64 held[] = {0, 1, 599};
  for (guint i = 0; i < G_N_ELEMENTS(held); i++) {
    clock_set(t0 + held[i]);
    assert_floor_refusal(metno, miami, fake, 1);
  }
  clock_set(t0 + 600);
  outcome_clear(&o);
  (void)fetch_ok(metno, miami, &o);
  assert_requests(fake, 2);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A time-out of every attempt is a failed request like any other. How many of its attempts reach
 * the server before their time-out depends on the speed of the machine (valgrind), so the
 * requests are counted relative to each other: at least one, at most the three attempts. */
static void
test_net_floor_after_timeout(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Fake *fake = fake_new_script((Reply[]){{R_HANG, 0, NULL, NULL, 0, 0}}, 1);
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(WxMetno) metno = wx_metno_new_custom(base, 700, 1, NULL);
  g_assert_nonnull(metno);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  fetch(metno, miami, &o);
  g_assert_null(o.result);
  g_assert_nonnull(o.error);
  g_assert_cmpint(o.error->code, ==, WX_ERROR_TIMEOUT);
  outcome_clear(&o);
  spin_ms(25);
  const guint first = fake->requests;
  g_assert_cmpuint(first, >=, 1);
  g_assert_cmpuint(first, <=, 3);
  clock_set(t0 + 599);
  assert_floor_refusal(metno, miami, fake, first);
  clock_set(t0 + 600);
  fetch(metno, miami, &o);
  g_assert_cmpint(o.error->code, ==, WX_ERROR_TIMEOUT);
  outcome_clear(&o);
  spin_ms(25);
  const guint second = fake->requests;
  g_assert_cmpuint(second, >, first); /* the floor was over: another series of attempts */
  g_assert_cmpuint(second, <=, first + 3);
  clock_set(t0 + 1199);
  assert_floor_refusal(metno, miami, fake, second);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static Reply
miami_down_reply(guint index, const char *path, gpointer data)
{
  (void)index;
  (void)data;
  if (strstr(path, "lat=25.7617") != NULL)
    return (Reply){R_RESPOND, 503, NULL, "{}", 0, 0};
  return (Reply){R_RESPOND, 200, NULL, london_text, 0, 0};
}

/* The floor belongs to one place: a failing place does not block the others, and answers for the
 * others do not lift its floor. */
static void
test_net_floor_is_per_place(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Fake *fake = fake_new_fn(miami_down_reply, NULL);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  Outcome o = {0};
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 503 Service Unavailable");
  assert_requests(fake, 3);
  outcome_clear(&o);
  clock_set(t0 + 1);
  g_autoptr(WxMember) london_member = wx_member_ref(fetch_ok(metno, london, &o));
  assert_requests(fake, 4);
  assert_request(fake, 3, LONDON_PATH, NULL);
  outcome_clear(&o);
  (void)fetch_ok(metno, sydney, &o);
  assert_requests(fake, 5);
  outcome_clear(&o);
  clock_set(t0 + 2);
  assert_floor_refusal(metno, miami, fake, 5);
  g_assert_true(fetch_ok(metno, london, &o) == london_member); /* a fresh entry: no request */
  assert_requests(fake, 5);
  outcome_clear(&o);
  clock_set(t0 + 599);
  assert_floor_refusal(metno, miami, fake, 5);
  clock_set(t0 + 600); /* the floor of miami is over: its request is sent (and fails again) */
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 503 Service Unavailable");
  assert_requests(fake, 8);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* The records are bounded by WX_METNO_CACHE_MAX places: the one made, or renewed, longest ago is
 * dropped when a new place needs a record, and its place may then be requested early. */
static void
test_net_floor_records_are_bounded(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  const Reply forbidden = {R_RESPOND, 403, NULL, "{}", 0, 0};
  Fake *fake = fake_new_script(&forbidden, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  enum { N = WX_METNO_CACHE_MAX + 1, MANY = 200 };
  WxPlace *places[MANY];
  for (guint i = 0; i < MANY; i++)
    places[i] = place_at(-60.0 + 0.5 * i, 50.0);
  Outcome o = {0};
  for (guint i = 0; i < N; i++) {
    clock_set(t0 + i);
    outcome_clear(&o);
    fetch(metno, places[i], &o);
    outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  }
  assert_requests(fake, N); /* place 0 lost its record when place 32 got one */
  clock_set(t0 + 40);
  assert_floor_refusal(metno, places[1], fake, N);
  assert_floor_refusal(metno, places[N - 1], fake, N);
  outcome_clear(&o);
  fetch(metno, places[0], &o); /* its record is gone: requested again, evicting place 1's */
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, N + 1);
  outcome_clear(&o);
  fetch(metno, places[1], &o); /* evicting place 2's */
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, N + 2);
  outcome_clear(&o);
  assert_floor_refusal(metno, places[3], fake, N + 2);
  assert_floor_refusal(metno, places[N - 1], fake, N + 2);
  assert_floor_refusal(metno, places[0], fake, N + 2);
  fetch(metno, places[2], &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, N + 3);
  outcome_clear(&o);

  /* A place that already has a record gets it renewed without dropping another one. */
  g_autoptr(WxMetno) second = metno_for(fake);
  const guint base = fake->requests;
  for (guint i = 0; i < WX_METNO_CACHE_MAX; i++) {
    clock_set(t0 + 1000 + i);
    fetch(second, places[i], &o);
    outcome_clear(&o);
  }
  assert_requests(fake, base + WX_METNO_CACHE_MAX);
  clock_set(t0 + 1000 + WX_METNO_MIN_REFRESH_S); /* place 0: exactly 600 s; place 1: 599 s */
  fetch(second, places[0], &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  outcome_clear(&o);
  assert_requests(fake, base + WX_METNO_CACHE_MAX + 1);
  assert_floor_refusal(second, places[1], fake, base + WX_METNO_CACHE_MAX + 1);
  assert_floor_refusal(second, places[WX_METNO_CACHE_MAX - 1], fake, base + WX_METNO_CACHE_MAX + 1);
  /* A new place needs a record: the one made longest ago (place 1, as place 0 was just renewed) is
   * dropped, so place 1 may be requested early while places 0 and 2 are still held back. */
  const guint after_renewal = base + WX_METNO_CACHE_MAX + 1;
  fetch(second, places[WX_METNO_CACHE_MAX + 5], &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  outcome_clear(&o);
  assert_requests(fake, after_renewal + 1);
  assert_floor_refusal(second, places[0], fake, after_renewal + 1);
  assert_floor_refusal(second, places[2], fake, after_renewal + 1);
  fetch(second, places[1], &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  outcome_clear(&o);
  assert_requests(fake, after_renewal + 2);

  /* Far more places than records: only the last WX_METNO_CACHE_MAX are remembered. */
  g_autoptr(WxMetno) many = metno_for(fake);
  const guint start = fake->requests;
  for (guint i = 0; i < MANY; i++) {
    clock_set(t0 + 5000 + i);
    fetch(many, places[i], &o);
    outcome_clear(&o);
  }
  assert_requests(fake, start + MANY);
  assert_floor_refusal(many, places[MANY - 1], fake, start + MANY);
  assert_floor_refusal(many, places[MANY - WX_METNO_CACHE_MAX], fake, start + MANY);
  fetch(many, places[MANY - WX_METNO_CACHE_MAX - 1], &o); /* the one before them: forgotten */
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, start + MANY + 1);
  outcome_clear(&o);
  for (guint i = 0; i < MANY; i++)
    wx_place_free(places[i]);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A fetch that joins the request in flight sends nothing and leaves the record of that request as
 * it is: the floor ends 600 s after the request was started, not after the joiner came. */
static void
test_net_floor_join_does_not_renew(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Reply steps[] = {{R_HOLD, 403, NULL, "{}", 0, 0}, {R_RESPOND, 403, NULL, "{}", 0, 0}};
  Fake *fake = fake_new_script(steps, 2);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome first = {0}, joiner = {0}, later = {0};
  fetch_start(metno, miami, NULL, &first);
  WAIT_UNTIL(fake->requests == 1);
  clock_set(t0 + 500);
  fetch_start(metno, miami, NULL, &joiner);
  g_assert_false(joiner.done);
  fake_release(fake);
  fetch_wait(&first);
  fetch_wait(&joiner);
  outcome_assert_failed(&first, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  outcome_assert_failed(&joiner, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, 1);
  clock_set(t0 + 600);
  fetch(metno, miami, &later); /* 600 s after the request, 100 s after the joiner */
  outcome_assert_failed(&later, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, 2);
  outcome_clear(&first);
  outcome_clear(&joiner);
  outcome_clear(&later);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A record that lies in the future of the clock does not hold anything back, and the request that
 * is sent replaces it. */
static void
test_net_floor_clock_backwards(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Fake *fake = fake_new_script((Reply[]){{R_RESPOND, 403, NULL, "{}", 0, 0}}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  outcome_clear(&o);
  const gint64 starts[] = {t0 - 1, t0 - 100000};
  guint requests = 1;
  for (guint i = 0; i < G_N_ELEMENTS(starts); i++) {
    clock_set(starts[i]);
    fetch(metno, miami, &o); /* the record of the last request is in the future: sent */
    outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
    outcome_clear(&o);
    requests++;
    assert_requests(fake, requests);
    /* The record of this request counts, not the older (later) one: 599 s on, still held back,
     * and at 600 s the request is sent. */
    clock_set(starts[i] + 599);
    assert_floor_refusal(metno, miami, fake, requests);
    clock_set(starts[i] + 600);
    fetch(metno, miami, &o);
    outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
    outcome_clear(&o);
    requests++;
    assert_requests(fake, requests);
  }
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

typedef struct {
  guint first_requests; /* requests for the first place so far */
} FirstDownState;

/* The first place (lat 10.0000) is answered once and then refused with 403; every other place is
 * answered 200. */
static Reply
first_down_reply(guint index, const char *path, gpointer data)
{
  (void)index;
  FirstDownState *state = data;
  if (strstr(path, "lat=10.0000&") != NULL && state->first_requests++ > 0)
    return (Reply){R_RESPOND, 403, NULL, "{}", 0, 0};
  return ok_reply(NULL);
}

/* An entry that the floor serves counts as used: when the full cache must drop an entry, it is not
 * that one. */
static void
test_net_floor_serve_counts_as_use(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  FirstDownState state = {0};
  Fake *fake = fake_new_fn(first_down_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  WxPlace *places[WX_METNO_CACHE_MAX + 1];
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    places[i] = place_at(10.0 + 0.5 * i, 20.0);
  Outcome o = {0};
  g_autoptr(WxMember) first = NULL;
  for (guint i = 0; i < WX_METNO_CACHE_MAX; i++) {
    outcome_clear(&o);
    WxMember *member = fetch_ok(metno, places[i], &o);
    if (i == 0)
      first = wx_member_ref(member);
  }
  assert_requests(fake, WX_METNO_CACHE_MAX);
  /* t0 + 700: the first place is stale and its request fails; at t0 + 701 the floor serves it. */
  clock_set(t0 + 700);
  outcome_clear(&o);
  fetch(metno, places[0], &o);
  outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 403 Forbidden");
  assert_requests(fake, WX_METNO_CACHE_MAX + 1);
  clock_set(t0 + 701);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, places[0], &o) == first);
  assert_requests(fake, WX_METNO_CACHE_MAX + 1);
  /* A 33rd place fills the cache beyond its bound: the entry used least recently goes. Place 0 was
   * stored first, but it was served last, so it is place 1 that is dropped. */
  outcome_clear(&o);
  (void)fetch_ok(metno, places[WX_METNO_CACHE_MAX], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX + 2);
  clock_set(t0 + 702);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, places[0], &o) == first); /* still cached, served by the floor */
  assert_requests(fake, WX_METNO_CACHE_MAX + 2);
  outcome_clear(&o);
  (void)fetch_ok(metno, places[1], &o); /* dropped: a request without validator */
  assert_requests(fake, WX_METNO_CACHE_MAX + 3);
  outcome_clear(&o);
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    wx_place_free(places[i]);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_lru_eviction(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *expires = http_date(t0 + 1500);
  g_autofree char *lm_header = g_strdup_printf("Last-Modified: %s\r\nExpires: %s\r\n", lm, expires);
  Fake *fake = fake_new_script((Reply[]){ok_reply(lm_header)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  WxPlace *places[WX_METNO_CACHE_MAX + 1];
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    places[i] = place_at(10.0 + 0.5 * i, 20.0);
  Outcome o = {0};
  for (guint i = 0; i < WX_METNO_CACHE_MAX; i++)
    (void)fetch_ok(metno, places[i], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX);
  /* Serving place 0 makes it the most recently used; place 1 is now the oldest. */
  (void)fetch_ok(metno, places[0], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX);
  (void)fetch_ok(metno, places[WX_METNO_CACHE_MAX], &o); /* the 33rd place evicts place 1 */
  assert_requests(fake, WX_METNO_CACHE_MAX + 1);
  (void)fetch_ok(metno, places[0], &o);
  (void)fetch_ok(metno, places[2], &o);
  (void)fetch_ok(metno, places[WX_METNO_CACHE_MAX], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX + 1);
  /* Place 1 was evicted. Its request of t0 is still recorded, so it is refused until t0 + 600; the
   * other entries stay fresh until their Expires time (t0 + 1500) and need no request. */
  assert_floor_refusal(metno, places[1], fake, WX_METNO_CACHE_MAX + 1);
  clock_set(t0 + 601);
  (void)fetch_ok(metno, places[1], &o); /* evicted: a request again */
  assert_requests(fake, WX_METNO_CACHE_MAX + 2);
  /* Replacing a stale entry of a full cache evicts nothing: the entries that are still there
   * revalidate (they send their Last-Modified), the one that was evicted starts afresh. */
  clock_set(t0 + 1600);
  for (guint i = 0; i < 5; i++)
    (void)fetch_ok(metno, places[WX_METNO_CACHE_MAX], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX + 3); /* request 34: place 32, with its validator */
  assert_request(fake, WX_METNO_CACHE_MAX + 2,
                 "/weatherapi/locationforecast/2.0/complete?lat=26.0000&lon=20.0000", lm);
  (void)fetch_ok(metno, places[1], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX + 4); /* request 35: place 1, stored by request 33 */
  assert_request(fake, WX_METNO_CACHE_MAX + 3,
                 "/weatherapi/locationforecast/2.0/complete?lat=10.5000&lon=20.0000", lm);
  (void)fetch_ok(metno, places[3], &o); /* evicted when place 1 was stored again */
  assert_requests(fake, WX_METNO_CACHE_MAX + 5);
  assert_request(fake, WX_METNO_CACHE_MAX + 4,
                 "/weatherapi/locationforecast/2.0/complete?lat=11.5000&lon=20.0000", NULL);
  (void)fetch_ok(metno, places[2], &o);
  assert_requests(fake, WX_METNO_CACHE_MAX + 6);
  assert_request(fake, WX_METNO_CACHE_MAX + 5,
                 "/weatherapi/locationforecast/2.0/complete?lat=11.0000&lon=20.0000", lm);
  outcome_clear(&o);
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    wx_place_free(places[i]);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

typedef struct {
  guint miami_requests;
  const char *miami_headers;
} EvictState;

static Reply
evict_reply(guint index, const char *path, gpointer data)
{
  (void)index;
  EvictState *state = data;
  if (strstr(path, "lat=25.7617") == NULL)
    return ok_reply(NULL);
  if (state->miami_requests++ == 0)
    return ok_reply(state->miami_headers);
  return (Reply){R_HOLD, 304, NULL, "", 0, 0}; /* answers after the cache has been churned */
}

/* A 304 for a request whose entry was evicted while it was in flight still returns the validated
 * member (the request holds it) and puts the entry back. */
static void
test_net_not_modified_after_eviction(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *h = g_strdup_printf("Last-Modified: %s\r\n", lm);
  EvictState state = {0, h};
  Fake *fake = fake_new_fn(evict_reply, &state);
  /* The held 304 must not time out (and be retried) while the 32 fetches below run, however slowly
   * (valgrind): a per-attempt time-out of a minute. */
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(WxMetno) metno = wx_metno_new_custom(base, 60000, 1, NULL);
  g_assert_nonnull(metno);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  g_autoptr(WxMember) a = wx_member_ref(fetch_ok(metno, miami, &o));
  outcome_clear(&o);
  clock_set(t0 + 700);
  Outcome pending = {0};
  fetch_start(metno, miami, NULL, &pending); /* revalidation: its 304 comes late */
  WAIT_UNTIL(fake->requests == 2);
  /* Meanwhile the cache is filled with other places: the stale entry is the least recently used. */
  for (guint i = 0; i < WX_METNO_CACHE_MAX; i++) {
    g_autoptr(WxPlace) other = place_at(10.0 + 0.5 * i, 20.0);
    (void)fetch_ok(metno, other, &o);
  }
  g_assert_false(pending.done);
  fake_release(fake); /* now the 304 is sent */
  fetch_wait(&pending);
  g_assert_true(outcome_member(&pending) == a);
  assert_requests(fake, 2 + WX_METNO_CACHE_MAX);
  /* The entry is back, renewed at t0 + 700: served without a request. */
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 2 + WX_METNO_CACHE_MAX);
  outcome_clear(&o);
  outcome_clear(&pending);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* ------------------------------------------------------------------------ */
/* Part 2: failures                                                         */
/* ------------------------------------------------------------------------ */

typedef struct {
  const char *what;
  Reply reply;
  int code;
  const char *message; /* NULL: not asserted (libsoup's own text) */
  guint requests;      /* requests one failed fetch sends: 1, or 3 for the retried failures */
} FailureCase;

static void
test_net_failure_table(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *bad_units = g_strdup(
      "{\"properties\":{\"meta\":{\"units\":{\"wind_speed\":\"knots\"}},\"timeseries\":["
      "{\"time\":\"2026-10-12T19:00:00Z\",\"data\":{\"instant\":{\"details\":{\"air_temperature\":20}}}}]}}");
  const FailureCase cases[] = {
      {"404", {R_RESPOND, 404, NULL, "{}", 0, 0}, WX_ERROR_NOT_FOUND, "HTTP 404: not found", 1},
      {"429", {R_RESPOND, 429, NULL, "{}", 0, 0}, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited", 1},
      {"403", {R_RESPOND, 403, NULL, "{}", 0, 0}, WX_ERROR_HTTP, "HTTP 403 Forbidden", 1},
      {"400", {R_RESPOND, 400, NULL, "{}", 0, 0}, WX_ERROR_HTTP, "HTTP 400 Bad Request", 1},
      {"422", {R_RESPOND, 422, NULL, "{}", 0, 0}, WX_ERROR_HTTP, "HTTP 422 Unprocessable Entity", 1},
      {"301", {R_RESPOND, 301, "Location: http://127.0.0.1:1/x\r\n", "", 0, 0}, WX_ERROR_HTTP,
       "HTTP 301 Moved Permanently", 1},
      {"304 without validator", {R_RESPOND, 304, NULL, "", 0, 0}, WX_ERROR_HTTP, "HTTP 304 Not Modified", 1},
      {"500", {R_RESPOND, 500, NULL, "{}", 0, 0}, WX_ERROR_HTTP, "HTTP 500 Internal Server Error", 3},
      {"503", {R_RESPOND, 503, NULL, "{}", 0, 0}, WX_ERROR_HTTP, "HTTP 503 Service Unavailable", 3},
      {"closed", {R_CLOSE, 0, NULL, NULL, 0, 0}, WX_ERROR_NETWORK, NULL, 3},
      {"truncated body", {R_RESPOND, 200, NULL, "{\"properties\":{", 5000, 0}, WX_ERROR_NETWORK, NULL, 3},
      {"declared 50 MiB", {R_RESPOND, 200, NULL, "{}", (gsize)50 * 1024 * 1024, 0}, WX_ERROR_PARSE, NULL, 1},
      {"200 empty", {R_RESPOND, 200, NULL, "", 0, 0}, WX_ERROR_PARSE, "empty response", 1},
      {"204", {R_RESPOND, 204, NULL, "", 0, 0}, WX_ERROR_PARSE, "empty response", 1},
      {"200 html", {R_RESPOND, 200, NULL, "<html>Bad Gateway</html>", 0, 0}, WX_ERROR_PARSE, "malformed JSON", 1},
      {"200 array", {R_RESPOND, 200, NULL, "[]", 0, 0}, WX_ERROR_PARSE, "response is not a JSON object", 1},
      {"200 object", {R_RESPOND, 200, NULL, "{}", 0, 0}, WX_ERROR_PARSE, "not a locationforecast document", 1},
      {"no series", {R_RESPOND, 200, NULL, "{\"properties\":{\"timeseries\":[]}}", 0, 0}, WX_ERROR_PARSE,
       "no usable forecast data", 1},
      {"other units", {R_RESPOND, 200, NULL, bad_units, 0, 0}, WX_ERROR_PARSE, "unexpected units", 1},
      {"gzip garbage", {R_GZIP, 200, NULL, "not json at all", 0, 0}, WX_ERROR_PARSE, "malformed JSON", 1},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_test_message("case %s", cases[i].what);
    clock_set(t0); /* every case starts at t0 */
    Fake *fake = fake_new_script(&cases[i].reply, 1);
    g_autoptr(WxMetno) metno = metno_for(fake);
    g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
    Outcome o = {0};
    fetch(metno, miami, &o);
    g_assert_null(o.result);
    g_assert_nonnull(o.error);
    g_assert_cmpstr(g_quark_to_string(o.error->domain), ==, g_quark_to_string(WX_ERROR));
    g_assert_cmpint(o.error->code, ==, cases[i].code);
    if (cases[i].message != NULL)
      g_assert_cmpstr(o.error->message, ==, cases[i].message);
    g_assert_null(strstr(o.error->message, "Bad Gateway</html>"));
    assert_requests(fake, cases[i].requests);
    /* The request counts for the floor although it failed: for 600 s nothing is sent for the place
     * and, as there is no entry to serve, the fetch fails with RATE_LIMITED and the floor's message
     * (also after a 429, the floor comes before the throttle). */
    const gint64 held[] = {0, 1, 300, 599};
    outcome_clear(&o);
    for (guint w = 0; w < G_N_ELEMENTS(held); w++) {
      clock_set(t0 + held[w]);
      assert_floor_refusal(metno, miami, fake, cases[i].requests);
    }
    /* 600 s after the request the next one is sent, again without validator, and it counts again. */
    clock_set(t0 + 600);
    fetch(metno, miami, &o);
    g_assert_nonnull(o.error);
    g_assert_cmpint(o.error->code, ==, cases[i].code);
    assert_requests(fake, 2 * cases[i].requests);
    assert_request(fake, cases[i].requests, MIAMI_PATH, NULL);
    outcome_clear(&o);
    clock_set(t0 + 1199);
    assert_floor_refusal(metno, miami, fake, 2 * cases[i].requests);
    fake_free(fake);
  }
  wx_metno_test_set_clock(NULL);
}

/* A good body followed by a bad one: the bad answer leaves the good entry alone. */
static void
test_net_bad_body_keeps_cache(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *h = g_strdup_printf("Last-Modified: %s\r\n", lm);
  Reply steps[] = {ok_reply(h), {R_RESPOND, 200, NULL, "{\"properties\":{\"timeseries\":[]}}", 0, 0},
                   {R_RESPOND, 304, NULL, "", 0, 0}};
  Fake *fake = fake_new_script(steps, 3);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  g_autoptr(WxMember) a = wx_member_ref(fetch_ok(metno, miami, &o));
  clock_set(t0 + 700);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_PARSE, "no usable forecast data");
  assert_requests(fake, 2);
  /* The bad answer left the entry alone and counts for the floor: the good member is served. */
  clock_set(t0 + 701);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 2);
  clock_set(t0 + 1300);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 3);
  assert_request(fake, 2, MIAMI_PATH, lm); /* the validator of the good answer is still the one sent */
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

typedef struct {
  const char *fail_429; /* a request whose path contains this text is answered 429; NULL: none */
  gboolean hold_london; /* the London answer waits for fake_release() */
} ThrottleState;

static Reply
throttle_reply(guint index, const char *path, gpointer data)
{
  (void)index;
  ThrottleState *state = data;
  if (strstr(path, "lat=51.5072") != NULL)
    return (Reply){state->hold_london ? R_HOLD : R_RESPOND, 200, NULL, london_text, 0, 0};
  if (state->fail_429 != NULL && strstr(path, state->fail_429) != NULL)
    return (Reply){R_RESPOND, 429, NULL, "{}", 0, 0};
  return (Reply){R_RESPOND, 200, NULL, miami_text, 0, 0};
}

static void
test_net_throttle_after_429(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  ThrottleState state = {"lat=25.7617", 0};
  Fake *fake = fake_new_fn(throttle_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  g_autoptr(WxPlace) tokyo = place_at(35.68, 139.69);
  Outcome o = {0};
  g_autoptr(WxMember) london_member = wx_member_ref(fetch_ok(metno, london, &o));
  assert_requests(fake, 1);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  assert_requests(fake, 2); /* 429 is final: no retry */

  /* For 60 s no request that needs the network is sent, for any place but the one that was
   * answered 429: that one is held by its own floor, which is checked first. */
  const struct {
    const WxPlace *place;
    const char *message;
  } refused[] = {{miami, FLOOR_MESSAGE},
                 {sydney, "requests are paused after HTTP 429"},
                 {miami, FLOOR_MESSAGE},
                 {sydney, "requests are paused after HTTP 429"}};
  for (guint i = 0; i < G_N_ELEMENTS(refused); i++) {
    outcome_clear(&o);
    fetch(metno, refused[i].place, &o);
    outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, refused[i].message);
    assert_requests(fake, 2);
  }
  /* A fresh entry is still served: that needs no request. */
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, london, &o) == london_member);
  assert_requests(fake, 2);
  clock_set(t0 + 59);
  outcome_clear(&o);
  fetch(metno, sydney, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  assert_requests(fake, 2);
  /* The refusals sent nothing, so they left no floor: after 60 s the request of sydney goes out
   * (and gets a 429, which starts a new pause). The floor of miami lasts until t0 + 600. */
  state.fail_429 = "lat=-33.8688";
  clock_set(t0 + 60);
  outcome_clear(&o);
  fetch(metno, sydney, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  assert_requests(fake, 3);
  clock_set(t0 + 60 + 59);
  outcome_clear(&o);
  fetch(metno, tokyo, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  assert_requests(fake, 3);
  assert_floor_refusal(metno, sydney, fake, 3);
  assert_floor_refusal(metno, miami, fake, 3);
  /* Once the service answers again, so does the provider. */
  state.fail_429 = NULL;
  clock_set(t0 + 120);
  outcome_clear(&o);
  fetch(metno, tokyo, &o);
  (void)outcome_member(&o);
  assert_requests(fake, 4);
  /* A stale entry is not served during a pause either, unless its floor holds the request back:
   * tokyo (answered at t0 + 120) and london (t0, a request that is long over) are stale now. */
  clock_set(t0 + 2000);
  state.fail_429 = "lat=35.6800";
  outcome_clear(&o);
  fetch(metno, tokyo, &o); /* a request, which gets 429 */
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  outcome_clear(&o);
  fetch(metno, london, &o); /* paused */
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  assert_requests(fake, 5);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A place that was answered 429 and has an entry is served from it (its floor), while other places
 * without an entry are paused by the throttle; the throttle ends after 60 s, the floor after 600 s. */
static void
test_net_floor_and_throttle_with_entry(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  ThrottleState state = {NULL, 0};
  Fake *fake = fake_new_fn(throttle_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o = {0};
  g_autoptr(WxMember) a = wx_member_ref(fetch_ok(metno, miami, &o));
  assert_requests(fake, 1);
  state.fail_429 = "lat=25.7617";
  clock_set(t0 + 700);
  outcome_clear(&o);
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  assert_requests(fake, 2);
  clock_set(t0 + 701);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a); /* the floor serves the stale member */
  assert_requests(fake, 2);
  /* A place without entry is paused by the throttle (it has no floor of its own) ... */
  outcome_clear(&o);
  fetch(metno, london, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  assert_requests(fake, 2);
  clock_set(t0 + 759);
  outcome_clear(&o);
  fetch(metno, london, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  /* ... until the 60 s are over; miami is still served from its entry. */
  clock_set(t0 + 760);
  outcome_clear(&o);
  (void)fetch_ok(metno, london, &o);
  assert_requests(fake, 3);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 3);
  clock_set(t0 + 1299);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 3);
  /* 700 + 600: the floor of miami is over. */
  state.fail_429 = NULL;
  clock_set(t0 + 1300);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) != a);
  assert_requests(fake, 4);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A clock earlier than the 429 answer lifts the pause (it cannot be measured any more). */
static void
test_net_throttle_clock_backwards(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  ThrottleState state = {"lat=25.7617", 0};
  Fake *fake = fake_new_fn(throttle_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o = {0};
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  outcome_clear(&o);
  clock_set(t0 + 30);
  fetch(metno, london, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  assert_requests(fake, 1);
  assert_floor_refusal(metno, miami, fake, 1);
  outcome_clear(&o);
  clock_set(t0 - 1); /* neither the pause nor the floor of miami can be measured any more */
  fetch(metno, miami, &o);
  outcome_assert_failed(&o, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  assert_requests(fake, 2);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* Requests already in flight when a 429 arrives are not affected by it. */
static void
test_net_throttle_spares_requests_in_flight(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  ThrottleState state = {"lat=25.7617", TRUE};
  Fake *fake = fake_new_fn(throttle_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome slow = {0}, quick = {0}, late = {0};
  fetch_start(metno, london, NULL, &slow);
  WAIT_UNTIL(fake->requests == 1);
  fetch(metno, miami, &quick);
  outcome_assert_failed(&quick, WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  g_assert_false(slow.done);
  /* A new request for another place is refused meanwhile ... */
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  fetch(metno, sydney, &late);
  outcome_assert_failed(&late, WX_ERROR_RATE_LIMITED, "requests are paused after HTTP 429");
  /* ... but the one in flight completes normally and joiners of it are still allowed. */
  Outcome joiner = {0};
  fetch_start(metno, london, NULL, &joiner);
  g_assert_false(slow.done || joiner.done);
  fake_release(fake);
  fetch_wait(&slow);
  fetch_wait(&joiner);
  (void)outcome_member(&slow);
  g_assert_true(outcome_member(&slow) == outcome_member(&joiner));
  assert_requests(fake, 2);
  outcome_clear(&slow);
  outcome_clear(&quick);
  outcome_clear(&late);
  outcome_clear(&joiner);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* ------------------------------------------------------------------------ */
/* Part 2: shared requests, cancellation, cap, lifecycle                    */
/* ------------------------------------------------------------------------ */

static void
test_net_concurrent_fetches_share_one_request(void)
{
  clock_set(real_now_s());
  Reply steps[] = {{R_RESPOND, 200, NULL, miami_text, 0, 120}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o[4] = {{0}};
  GCancellable *c[3];
  for (guint i = 0; i < 3; i++) {
    c[i] = g_cancellable_new();
    fetch_start(metno, miami, c[i], &o[i]);
  }
  fetch_start(metno, london, NULL, &o[3]); /* another place: its own request */
  for (guint i = 0; i < 4; i++)
    fetch_wait(&o[i]);
  assert_requests(fake, 2);
  WxMember *m0 = outcome_member(&o[0]);
  g_assert_true(m0 == outcome_member(&o[1]));
  g_assert_true(m0 == outcome_member(&o[2]));
  g_assert_true(m0 != outcome_member(&o[3]));
  g_assert_true(o[0].result != o[1].result); /* every caller owns its own result */
  for (guint i = 0; i < 4; i++) {
    g_assert_cmpuint(o[i].calls, ==, 1);
    outcome_clear(&o[i]);
  }
  for (guint i = 0; i < 3; i++)
    g_object_unref(c[i]);
  spin_ms(30);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* Cancelling one of several fetches that share a request cancels that fetch only, whichever it is. */
static void
test_net_cancel_one_of_shared_fetches(void)
{
  clock_set(real_now_s());
  for (guint victim = 0; victim < 3; victim++) {
    Reply steps[] = {{R_HOLD, 200, NULL, miami_text, 0, 0}};
    Fake *fake = fake_new_script(steps, 1);
    g_autoptr(WxMetno) metno = metno_for(fake);
    g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
    Outcome o[3] = {{0}};
    GCancellable *c[3];
    for (guint i = 0; i < 3; i++) {
      c[i] = g_cancellable_new();
      fetch_start(metno, miami, c[i], &o[i]);
    }
    WAIT_UNTIL(fake->requests == 1);
    g_cancellable_cancel(c[victim]);
    fetch_wait(&o[victim]);
    outcome_assert_cancelled(&o[victim]);
    for (guint i = 0; i < 3; i++)
      g_assert_false(i != victim && o[i].done);
    fake_release(fake); /* now the shared request is answered */
    for (guint i = 0; i < 3; i++) {
      if (i == victim)
        continue;
      fetch_wait(&o[i]);
      (void)outcome_member(&o[i]);
    }
    assert_requests(fake, 1);
    for (guint i = 0; i < 3; i++) {
      g_assert_cmpuint(o[i].calls, ==, 1);
      outcome_clear(&o[i]);
      g_object_unref(c[i]);
    }
    fake_free(fake);
  }
  wx_metno_test_set_clock(NULL);
}

/* When every fetch of a place is cancelled, the request is cancelled too. It was started, so it
 * counts for the floor of the place: a later fetch is refused until 600 s have passed and then
 * starts a new request. */
static void
test_net_cancel_all_cancels_the_request(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  Reply steps[] = {{R_HANG, 0, NULL, NULL, 0, 0}, ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 2);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o[3] = {{0}};
  GCancellable *c[3];
  for (guint i = 0; i < 3; i++) {
    c[i] = g_cancellable_new();
    fetch_start(metno, miami, c[i], &o[i]);
  }
  WAIT_UNTIL(fake->requests == 1);
  g_cancellable_cancel(c[1]);
  fetch_wait(&o[1]);
  g_assert_false(o[0].done);
  g_assert_cmpuint(fake->closed_early, ==, 0); /* two fetches still wait: the request goes on */
  g_cancellable_cancel(c[0]);
  g_cancellable_cancel(c[2]);
  fetch_wait(&o[0]);
  fetch_wait(&o[2]);
  for (guint i = 0; i < 3; i++) {
    outcome_assert_cancelled(&o[i]);
    g_assert_cmpuint(o[i].calls, ==, 1);
  }
  WAIT_UNTIL(fake->closed_early == 1); /* the HTTP request was aborted */
  /* The cancelled request counts: no new one within 600 s of it, and no entry to serve. */
  assert_floor_refusal(metno, miami, fake, 1);
  clock_set(t0 + 599);
  assert_floor_refusal(metno, miami, fake, 1);
  clock_set(t0 + 600); /* a new request (the second reply), not the cancelled one */
  Outcome again = {0};
  fetch(metno, miami, &again);
  (void)outcome_member(&again);
  assert_requests(fake, 2);
  for (guint i = 0; i < 3; i++) {
    g_assert_cmpuint(o[i].calls, ==, 1);
    outcome_clear(&o[i]);
    g_object_unref(c[i]);
  }
  outcome_clear(&again);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* A new fetch that comes while the request of an all-cancelled place is still winding down: it
 * does not join the cancelled request. Within 600 s of that request it is refused at once (it
 * counts for the floor); after that it starts a request of its own. */
static void
test_net_fetch_right_after_cancel_all(void)
{
  const gint64 t0 = real_now_s();
  for (guint later = 0; later < 2; later++) {
    clock_set(t0);
    Reply steps[] = {{R_HANG, 0, NULL, NULL, 0, 0}, ok_reply(NULL)};
    Fake *fake = fake_new_script(steps, 2);
    g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
    g_autoptr(WxMetno) metno = wx_metno_new_custom(base, 60000, 1, NULL);
    g_assert_nonnull(metno);
    g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
    Outcome first = {0}, second = {0};
    g_autoptr(GCancellable) c = g_cancellable_new();
    fetch_start(metno, miami, c, &first);
    WAIT_UNTIL(fake->requests == 1);
    g_cancellable_cancel(c);
    clock_set(t0 + 600 * later);
    fetch_start(metno, miami, NULL, &second); /* before any main loop iteration */
    fetch_wait(&first);
    outcome_assert_cancelled(&first);
    fetch_wait(&second);
    /* Joining the cancelled request instead would have waited for it: a hung request, whose
     * per-attempt time-out is one minute here (WAIT_UNTIL gives up after 20 s). */
    if (later == 0) {
      outcome_assert_failed(&second, WX_ERROR_RATE_LIMITED, FLOOR_MESSAGE);
      assert_requests(fake, 1);
    } else {
      (void)outcome_member(&second);
      assert_requests(fake, 2);
    }
    outcome_clear(&first);
    outcome_clear(&second);
    fake_free(fake);
  }
  wx_metno_test_set_clock(NULL);
}

static void
test_net_cancel_before_and_after(void)
{
  clock_set(real_now_s());
  Reply steps[] = {ok_reply(NULL)};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};

  /* Already cancelled: no request, one callback, never before the call returned. */
  g_autoptr(GCancellable) pre = g_cancellable_new();
  g_cancellable_cancel(pre);
  fetch_start(metno, miami, pre, &o);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  spin_ms(30);
  g_assert_cmpuint(o.calls, ==, 1);
  assert_requests(fake, 0);
  g_assert_cmpuint(fake->connections, ==, 0); /* not even a connection was opened */
  outcome_clear(&o);

  /* Cancelled between completion and finish (inside the callback): reported as cancelled even
   * though the fetch succeeded. The request that was already made left its answer in the cache. */
  g_autoptr(GCancellable) late = g_cancellable_new();
  o.cancel_first = late;
  fetch_start(metno, miami, late, &o);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  assert_requests(fake, 1);
  outcome_clear(&o);

  /* The same for an answer served from the cache. */
  g_autoptr(GCancellable) late2 = g_cancellable_new();
  o.cancel_first = late2;
  fetch_start(metno, miami, late2, &o);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  assert_requests(fake, 1);
  outcome_clear(&o);

  /* Cancelled after the callback: no effect on what was delivered. */
  g_autoptr(GCancellable) after = g_cancellable_new();
  fetch_start(metno, miami, after, &o);
  fetch_wait(&o);
  (void)outcome_member(&o);
  g_cancellable_cancel(after);
  spin_ms(30);
  g_assert_cmpuint(o.calls, ==, 1);
  (void)outcome_member(&o);
  outcome_clear(&o);

  /* An invalid place with a cancelled cancellable: still one callback, no request; a cancelled
   * cancellable always wins at finish (the interface contract). */
  WxPlace hand = {(char *)"x", (char *)"", (char *)"", {0}, 100.0, 0.0, (char *)""};
  fetch_start(metno, &hand, pre, &o);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  spin_ms(10);
  g_assert_cmpuint(o.calls, ==, 1);
  assert_requests(fake, 1);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_cancel_in_flight(void)
{
  clock_set(real_now_s());
  Reply steps[] = {{R_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(GCancellable) c = g_cancellable_new();
  Outcome o = {0};
  fetch_start(metno, miami, c, &o);
  WAIT_UNTIL(fake->requests == 1);
  g_assert_false(o.done);
  g_cancellable_cancel(c);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  WAIT_UNTIL(fake->closed_early == 1);
  spin_ms(30);
  g_assert_cmpuint(o.calls, ==, 1);
  assert_requests(fake, 1); /* a cancelled request is not retried */
  outcome_clear(&o);
  /* Nothing was cached; the cancelled request counts for the floor, after which the provider works
   * again. */
  assert_floor_refusal(metno, miami, fake, 1);
  fake->fn = script_reply;
  fake->script.steps = (Reply[]){ok_reply(NULL)};
  fake->script.n = 1;
  fake->fn_data = &fake->script;
  clock_set(real_now_s() + 600);
  fetch(metno, miami, &o);
  (void)outcome_member(&o);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_inflight_cap(void)
{
  clock_set(real_now_s());
  Reply steps[] = {{R_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  WxPlace *places[WX_HTTP_MAX_INFLIGHT + 1];
  GCancellable *cancels[WX_HTTP_MAX_INFLIGHT];
  Outcome outs[WX_HTTP_MAX_INFLIGHT + 1] = {{0}};
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    places[i] = place_at(40.0 + 0.1 * i, 10.0);
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    cancels[i] = g_cancellable_new();
    fetch_start(metno, places[i], cancels[i], &outs[i]);
  }
  /* libsoup limits the connections per host: only some of the 16 requests reach the server at
   * once, the others wait inside libsoup (and count as outstanding all the same). */
  WAIT_UNTIL(fake->requests >= 1);
  spin_ms(100);
  const guint on_wire = fake->requests;
  g_assert_cmpuint(on_wire, <=, WX_HTTP_MAX_INFLIGHT);
  /* One more place: refused at once, without traffic, and not by a throttle. */
  fetch(metno, places[WX_HTTP_MAX_INFLIGHT], &outs[WX_HTTP_MAX_INFLIGHT]);
  outcome_assert_failed(&outs[WX_HTTP_MAX_INFLIGHT], WX_ERROR_RATE_LIMITED,
                        "too many outstanding requests (limit 16)");
  assert_requests(fake, on_wire);
  /* A fetch of a place that is in flight joins its request: it is not a new one. */
  Outcome joiner = {0};
  GCancellable *cj = g_cancellable_new();
  fetch_start(metno, places[0], cj, &joiner);
  spin_ms(30);
  g_assert_false(joiner.done);
  assert_requests(fake, on_wire);
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++)
    g_cancellable_cancel(cancels[i]);
  g_cancellable_cancel(cj);
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    fetch_wait(&outs[i]);
    outcome_assert_cancelled(&outs[i]);
  }
  fetch_wait(&joiner);
  outcome_assert_cancelled(&joiner);
  WAIT_UNTIL(fake->closed_early == fake->requests); /* every request that reached the server ended */
  /* The slots come back (a slot is free once the completion has been handled, a loop iteration
   * after the request ended): the refusal ends and the next fetch is a request. */
  Outcome probe = {0};
  g_autoptr(GCancellable) cp = g_cancellable_new();
  guint before = fake->requests;
  for (;;) {
    outcome_clear(&probe);
    fetch_start(metno, places[WX_HTTP_MAX_INFLIGHT], cp, &probe);
    WAIT_UNTIL(probe.done || fake->requests > before);
    if (!probe.done)
      break;
    outcome_assert_failed(&probe, WX_ERROR_RATE_LIMITED, "too many outstanding requests (limit 16)");
    spin_ms(2);
  }
  g_cancellable_cancel(cp);
  fetch_wait(&probe);
  outcome_assert_cancelled(&probe);
  WAIT_UNTIL(fake->closed_early == fake->requests);
  /* And all 16 slots are usable again. */
  spin_ms(50);
  GCancellable *again[WX_HTTP_MAX_INFLIGHT];
  Outcome again_outs[WX_HTTP_MAX_INFLIGHT] = {{0}};
  WxPlace *other[WX_HTTP_MAX_INFLIGHT] = {NULL};
  before = fake->requests;
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    other[i] = place_at(-20.0 - 0.1 * i, 30.0);
    again[i] = g_cancellable_new();
    fetch_start(metno, other[i], again[i], &again_outs[i]);
  }
  WAIT_UNTIL(fake->requests > before);
  spin_ms(100);
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    g_assert_false(again_outs[i].done);
    g_cancellable_cancel(again[i]);
  }
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    fetch_wait(&again_outs[i]);
    outcome_assert_cancelled(&again_outs[i]);
    outcome_clear(&again_outs[i]);
    g_object_unref(again[i]);
  }
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    outcome_clear(&outs[i]);
    g_object_unref(cancels[i]);
    wx_place_free(other[i]);
  }
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    wx_place_free(places[i]);
  outcome_clear(&outs[WX_HTTP_MAX_INFLIGHT]);
  outcome_clear(&joiner);
  outcome_clear(&probe);
  g_object_unref(cj);
  WAIT_UNTIL(fake->closed_early == fake->requests);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_drop_provider_in_flight(void)
{
  clock_set(real_now_s());
  Reply steps[] = {{R_RESPOND, 200, NULL, miami_text, 0, 80}};
  Fake *fake = fake_new_script(steps, 1);
  WxMetno *metno = metno_for(fake);
  WxMetno *weak = metno;
  g_object_add_weak_pointer(G_OBJECT(metno), (gpointer *)&weak);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o = {0}, joiner = {0};
  fetch_start(metno, miami, NULL, &o);
  fetch_start(metno, miami, NULL, &joiner);
  g_object_unref(metno); /* the last reference of the caller */
  g_assert_nonnull(weak);
  fetch_wait(&o);
  fetch_wait(&joiner);
  (void)outcome_member(&o);
  g_assert_true(outcome_member(&o) == outcome_member(&joiner));
  assert_member_invariants(outcome_member(&o));
  WAIT_UNTIL(weak == NULL); /* finalized once the work and the slot release are done */
  g_assert_cmpuint(o.calls, ==, 1);
  g_assert_cmpuint(joiner.calls, ==, 1);
  outcome_clear(&o);
  outcome_clear(&joiner);

  /* Dropped while the only fetch is cancelled and the request winds down. */
  Reply hang[] = {{R_HANG, 0, NULL, NULL, 0, 0}};
  fake->script.steps = hang;
  fake->script.n = 1;
  metno = metno_for(fake);
  weak = metno;
  g_object_add_weak_pointer(G_OBJECT(metno), (gpointer *)&weak);
  g_autoptr(GCancellable) c = g_cancellable_new();
  fetch_start(metno, london, c, &o);
  WAIT_UNTIL(fake->requests == 2);
  g_object_unref(metno);
  g_cancellable_cancel(c);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  WAIT_UNTIL(weak == NULL);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* GObject allows calls until finalize: after dispose the instance still works. */
static void
test_net_works_after_dispose(void)
{
  clock_set(real_now_s());
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  (void)fetch_ok(metno, miami, &o);
  g_object_run_dispose(G_OBJECT(metno));
  g_assert_cmpstr(wx_provider_get_id(WX_PROVIDER(metno)), ==, "met-no");
  g_assert_true(wx_provider_covers(WX_PROVIDER(metno), miami));
  (void)fetch_ok(metno, miami, &o); /* cache survives */
  assert_requests(fake, 1);
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  Outcome o2 = {0};
  fetch_start(metno, london, NULL, &o2);
  g_object_run_dispose(G_OBJECT(metno)); /* in flight */
  fetch_wait(&o2);
  (void)outcome_member(&o2);
  assert_requests(fake, 2);
  outcome_clear(&o);
  outcome_clear(&o2);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_invalid_places(void)
{
  clock_set(real_now_s());
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  WxPlace base = {(char *)"x", (char *)"", (char *)"", {0}, 10.0, 20.0, (char *)""};
  WxPlace nulls = {NULL, NULL, NULL, {0}, 10.0, 20.0, NULL};
  WxPlace nan_lat = base, inf_lon = base, lat_high = base, lon_low = base, empty_name = base,
          control = base, tz_bad = base, cc_bad = base;
  nan_lat.lat = NAN;
  inf_lon.lon = INFINITY;
  lat_high.lat = 90.0000001;
  lon_low.lon = -180.0000001;
  empty_name.name = (char *)"";
  control.name = (char *)"a\nb";
  tz_bad.timezone = (char *)"../etc/passwd";
  cc_bad.country_code[0] = 'x';
  cc_bad.country_code[1] = 'y';
  const WxPlace *bad[] = {&nulls, &nan_lat, &inf_lon, &lat_high, &lon_low, &empty_name, &control, &tz_bad, &cc_bad};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    Outcome o = {0};
    fetch(metno, bad[i], &o);
    outcome_assert_failed(&o, WX_ERROR_INVALID_ARG, "invalid place");
    spin_ms(5);
    g_assert_cmpuint(o.calls, ==, 1);
    outcome_clear(&o);
  }
  assert_requests(fake, 0);
  /* The valid base place works. */
  Outcome o = {0};
  fetch(metno, &base, &o);
  (void)outcome_member(&o);
  assert_requests(fake, 1);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

static void
test_net_programmer_errors(void)
{
  clock_set(real_now_s());
  Fake *fake = fake_new_script((Reply[]){ok_reply(NULL)}, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  /* The interface dispatcher refuses a NULL place before the provider sees it. */
  ASSERT_CRITICAL("place != NULL", wx_provider_fetch_async(WX_PROVIDER(metno), NULL, NULL, on_fetch, &o));
  spin_ms(10);
  g_assert_false(o.done);
  g_assert_cmpuint(o.calls, ==, 0);
  /* A result that is not one of this provider's fetch tasks: a critical, NULL, no error. */
  g_autoptr(GObject) other = g_object_new(G_TYPE_OBJECT, NULL);
  g_autoptr(GTask) foreign = g_task_new(other, NULL, NULL, NULL);
  g_autoptr(GError) error = NULL;
  ASSERT_CRITICAL("g_task_is_valid",
                  g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(metno), G_ASYNC_RESULT(foreign), &error)));
  g_assert_no_error(error);
  g_autoptr(GTask) untagged = g_task_new(metno, NULL, NULL, NULL);
  ASSERT_CRITICAL("g_task_get_source_tag",
                  g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(metno), G_ASYNC_RESULT(untagged), &error)));
  g_assert_no_error(error);
  /* The provider is unharmed. */
  fetch(metno, miami, &o);
  (void)outcome_member(&o);
  outcome_clear(&o);
  assert_requests(fake, 1);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

typedef struct {
  WxMetno *metno;
  const WxPlace *place;
  Outcome inner;
} Nested;

static void
nested_then(Outcome *o)
{
  Nested *n = o->data;
  /* A cache hit started from inside a completion callback: still deferred, never nested. */
  fetch_start(n->metno, n->place, NULL, &n->inner);
}

static void
test_net_callbacks_once_and_never_nested(void)
{
  clock_set(real_now_s());
  Reply steps[] = {{R_RESPOND, 200, NULL, miami_text, 0, 20}};
  Fake *fake = fake_new_script(steps, 1);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Nested nested = {metno, miami, {0}};
  Outcome o = {0};
  o.then = nested_then;
  o.data = &nested;
  fetch(metno, miami, &o); /* a network answer; its callback starts a second fetch */
  g_assert_false(nested.inner.done);
  fetch_wait(&nested.inner);
  (void)outcome_member(&nested.inner);
  spin_ms(30);
  g_assert_cmpuint(o.calls, ==, 1);
  g_assert_cmpuint(nested.inner.calls, ==, 1);
  assert_requests(fake, 1);
  outcome_clear(&nested.inner);
  outcome_clear(&o);

  /* A fetch without callback (fire and forget) is fine: the request is made, nothing is delivered. */
  g_autoptr(WxPlace) london = place_at(LONDON_LAT, LONDON_LON);
  wx_provider_fetch_async(WX_PROVIDER(metno), london, NULL, NULL, NULL);
  WAIT_UNTIL(fake->requests == 2);
  spin_ms(60);
  Outcome again = {0};
  fetch(metno, london, &again); /* served from what the fire-and-forget fetch stored */
  (void)outcome_member(&again);
  assert_requests(fake, 2);
  outcome_clear(&again);

  /* A cache hit from outside any callback, a refusal and an invalid place: deferred as well. */
  Outcome hit = {0};
  fetch(metno, miami, &hit);
  spin_ms(10);
  g_assert_cmpuint(hit.calls, ==, 1);
  outcome_clear(&hit);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* The Last-Modified text is sent back as it came (it is opaque to the provider) as long as WxHttp
 * accepts it as a validator: printable ASCII of at most WX_HTTP_VALIDATOR_MAX bytes. */
static void
test_net_validator_round_trip(void)
{
  const gint64 t0 = real_now_s();
  g_autofree char *max_len = g_strnfill(WX_HTTP_VALIDATOR_MAX, 'x');
  g_autofree char *too_long = g_strnfill(WX_HTTP_VALIDATOR_MAX + 1, 'x');
  const struct {
    const char *header_value;
    const char *sent_back; /* NULL: no If-Modified-Since */
  } cases[] = {
      {"not a date at all", "not a date at all"},
      {"W/\"abc\"; q=0.5, \\ ~!#$%&'()*+,-./", "W/\"abc\"; q=0.5, \\ ~!#$%&'()*+,-./"},
      {max_len, max_len},
      {too_long, NULL},
      {"", NULL},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    clock_set(t0);
    g_autofree char *h = g_strdup_printf("Last-Modified: %s\r\n", cases[i].header_value);
    Reply steps[] = {ok_reply(h), {R_RESPOND, 304, NULL, "", 0, 0}};
    Fake *fake = fake_new_script(steps, 2);
    g_autoptr(WxMetno) metno = metno_for(fake);
    g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
    Outcome o = {0};
    g_autoptr(WxMember) a = wx_member_ref(fetch_ok(metno, miami, &o));
    outcome_clear(&o);
    clock_set(t0 + 600);
    fetch_start(metno, miami, NULL, &o);
    fetch_wait(&o);
    assert_requests(fake, 2);
    assert_request(fake, 1, MIAMI_PATH, cases[i].sent_back);
    if (cases[i].sent_back != NULL)
      g_assert_true(outcome_member(&o) == a); /* the 304 for the validator */
    else /* no validator was sent, so the server's 304 is an error */
      outcome_assert_failed(&o, WX_ERROR_HTTP, "HTTP 304 Not Modified");
    outcome_clear(&o);
    fake_free(fake);
  }
  wx_metno_test_set_clock(NULL);
}

/* A cancelled request leaves the entry as it was and counts for the floor: the stale entry is
 * served for 600 s, then the next fetch revalidates it. */
static void
test_net_cancelled_request_leaves_the_entry(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  g_autofree char *lm = http_date(t0 - 100);
  g_autofree char *h = g_strdup_printf("Last-Modified: %s\r\n", lm);
  Reply steps[] = {ok_reply(h), {R_HANG, 0, NULL, NULL, 0, 0}, {R_RESPOND, 304, NULL, "", 0, 0}};
  Fake *fake = fake_new_script(steps, 3);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(WxPlace) miami = place_at(MIAMI_LAT, MIAMI_LON);
  Outcome o = {0};
  g_autoptr(WxMember) a = wx_member_ref(fetch_ok(metno, miami, &o));
  clock_set(t0 + 700);
  g_autoptr(GCancellable) c = g_cancellable_new();
  outcome_clear(&o);
  fetch_start(metno, miami, c, &o);
  WAIT_UNTIL(fake->requests == 2);
  assert_request(fake, 1, MIAMI_PATH, lm);
  g_cancellable_cancel(c);
  fetch_wait(&o);
  outcome_assert_cancelled(&o);
  WAIT_UNTIL(fake->closed_early == 1);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a); /* served by the floor: no request */
  assert_requests(fake, 2);
  clock_set(t0 + 1299);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a);
  assert_requests(fake, 2);
  clock_set(t0 + 1300);
  outcome_clear(&o);
  g_assert_true(fetch_ok(metno, miami, &o) == a); /* the 304 of the third request */
  assert_requests(fake, 3);
  assert_request(fake, 2, MIAMI_PATH, lm);
  outcome_clear(&o);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* ------------------------------------------------------------------------ */
/* Part 2: stress                                                           */
/* ------------------------------------------------------------------------ */

typedef struct {
  gboolean calm; /* every answer is a 200 after 40 ms */
} StressState;

static Reply
stress_reply(guint index, const char *path, gpointer data)
{
  (void)path;
  const StressState *state = data;
  if (state->calm)
    return (Reply){R_RESPOND, 200, NULL, miami_text, 0, 40};
  guint delay = (index * 37) % 70;
  if (index % 11 == 5)
    return (Reply){R_CLOSE, 0, NULL, NULL, 0, 0};
  if (index % 13 == 7)
    return (Reply){R_RESPOND, 304, NULL, "", 0, delay};
  return (Reply){R_RESPOND, 200, NULL, miami_text, 0, delay};
}

/* Random fetches, cancellations at random moments and failures: every callback runs once with a
 * valid outcome, nothing is left behind (all 16 slots usable afterwards), no crash. */
static void
test_net_stress(void)
{
  const gint64 t0 = real_now_s();
  clock_set(t0);
  StressState state = {FALSE};
  Fake *fake = fake_new_fn(stress_reply, &state);
  g_autoptr(WxMetno) metno = metno_for(fake);
  g_autoptr(GRand) rand = g_rand_new_with_seed(4242);
  WxPlace *places[12];
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    places[i] = place_at(30.0 + i, -80.0);
  guint rounds = g_test_slow() ? 120 : 25;
  for (guint round = 0; round < rounds; round++) {
    clock_set(t0 + (gint64)round * 400); /* some entries stale, some fresh */
    enum { N = 10 };
    Outcome outs[N] = {{0}};
    GCancellable *cancels[N];
    guint cancel_after[N];
    for (guint i = 0; i < N; i++) {
      cancels[i] = g_rand_int_range(rand, 0, 3) == 0 ? NULL : g_cancellable_new();
      cancel_after[i] = cancels[i] != NULL && g_rand_boolean(rand) ? (guint)g_rand_int_range(rand, 0, 40) : G_MAXUINT;
      fetch_start(metno, places[g_rand_int_range(rand, 0, G_N_ELEMENTS(places))], cancels[i], &outs[i]);
    }
    for (guint step = 0; step < 4000; step++) {
      gboolean all = TRUE;
      for (guint i = 0; i < N; i++) {
        all = all && outs[i].done;
        if (cancels[i] != NULL && cancel_after[i] == step)
          g_cancellable_cancel(cancels[i]);
      }
      if (all)
        break;
      if (!g_main_context_iteration(NULL, FALSE))
        g_usleep(500);
    }
    for (guint i = 0; i < N; i++) {
      g_assert_true(outs[i].done);
      g_assert_cmpuint(outs[i].calls, ==, 1);
      if (outs[i].result != NULL) {
        g_assert_no_error(outs[i].error);
        assert_member_invariants(outcome_member(&outs[i]));
      } else {
        g_assert_nonnull(outs[i].error);
        gboolean cancelled = g_error_matches(outs[i].error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        gboolean network = g_error_matches(outs[i].error, WX_ERROR, WX_ERROR_NETWORK);
        gboolean http = g_error_matches(outs[i].error, WX_ERROR, WX_ERROR_HTTP); /* a 304 sent unasked */
        /* a refusal by the floor (no entry to serve) carries its fixed message and nothing else */
        gboolean by_floor = g_error_matches(outs[i].error, WX_ERROR, WX_ERROR_RATE_LIMITED) &&
                            g_str_equal(outs[i].error->message, FLOOR_MESSAGE);
        g_assert_true(cancelled || network || http || by_floor);
      }
      outcome_clear(&outs[i]);
      if (cancels[i] != NULL)
        g_object_unref(cancels[i]);
    }
  }
  /* Let everything wind down, then use every slot at once. */
  state.calm = TRUE;
  clock_set(t0 + 1000000);
  spin_ms(200);
  Outcome outs[WX_HTTP_MAX_INFLIGHT] = {{0}};
  WxPlace *fresh[WX_HTTP_MAX_INFLIGHT] = {NULL};
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    fresh[i] = place_at(-50.0 - i, 100.0);
    fetch_start(metno, fresh[i], NULL, &outs[i]);
  }
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    fetch_wait(&outs[i]);
    (void)outcome_member(&outs[i]);
    outcome_clear(&outs[i]);
    wx_place_free(fresh[i]);
  }
  for (guint i = 0; i < G_N_ELEMENTS(places); i++)
    wx_place_free(places[i]);
  fake_free(fake);
  wx_metno_test_set_clock(NULL);
}

/* ------------------------------------------------------------------------ */
/* main                                                                     */
/* ------------------------------------------------------------------------ */

static void
remove_tree(const char *path)
{
  GDir *dir = g_dir_open(path, 0, NULL);
  if (dir != NULL) {
    const char *name;
    while ((name = g_dir_read_name(dir)) != NULL) {
      g_autofree char *child = g_build_filename(path, name, NULL);
      if (g_file_test(child, G_FILE_TEST_IS_DIR) && !g_file_test(child, G_FILE_TEST_IS_SYMLINK))
        remove_tree(child);
      else
        (void)g_remove(child);
    }
    g_dir_close(dir);
  }
  (void)g_rmdir(path);
}

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  if (argc < 2) {
    g_printerr("usage: %s FIXTURE_DIR [GLib test options]\n", argv[0]);
    return 1;
  }
  fixture_dir = argv[1];
  /* Loopback traffic must never go through a user's proxy settings; library messages stay
   * untranslated whatever the environment says; the user's real XDG directories are never used.
   * The tests run in the locale of the environment (LC_ALL / LANG): nothing here may depend on it. */
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  g_setenv("LANGUAGE", "C", TRUE);
  (void)setlocale(LC_ALL, "");
  g_autofree char *sandbox = g_dir_make_tmp("wx-metno-test-XXXXXX", NULL);
  if (sandbox == NULL)
    g_error("cannot create a temporary directory");
  const char *const xdg[] = {"XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                             "XDG_RUNTIME_DIR"};
  for (guint i = 0; i < G_N_ELEMENTS(xdg); i++) {
    g_autofree char *dir = g_build_filename(sandbox, xdg[i], NULL);
    if (g_mkdir(dir, 0700) != 0)
      g_error("cannot create %s", dir);
    g_setenv(xdg[i], dir, TRUE);
  }
  miami_text = load_fixture("complete_miami.json", &miami_len);
  london_text = load_fixture("complete_london.json", &london_len);

  g_test_add_func("/metno/pure/constants", test_constants);
  g_test_add_func("/metno/pure/path-table", test_forecast_path_table);
  g_test_add_func("/metno/pure/path-rejects-invalid", test_forecast_path_rejects_invalid);
  g_test_add_func("/metno/pure/path-property", test_forecast_path_property);
  g_test_add_func("/metno/pure/locale-independence", test_locale_independence);
  g_test_add_func("/metno/parse/fixture-miami", test_fixture_miami);
  g_test_add_func("/metno/parse/fixture-london", test_fixture_london);
  g_test_add_func("/metno/parse/fixture-limits", test_fixture_limits);
  g_test_add_func("/metno/parse/fixture-dropped-elements", test_fixture_survives_dropped_elements);
  g_test_add_func("/metno/parse/document-shapes", test_parse_rejects_document_shapes);
  g_test_add_func("/metno/parse/errors-do-not-echo-body", test_parse_error_messages_do_not_echo_body);
  g_test_add_func("/metno/parse/units", test_parse_units);
  g_test_add_func("/metno/parse/element-skipping", test_parse_element_skipping);
  g_test_add_func("/metno/parse/value-ranges", test_parse_value_ranges);
  g_test_add_func("/metno/parse/gust", test_parse_gust);
  g_test_add_func("/metno/parse/hour-cap", test_parse_hour_cap);
  g_test_add_func("/metno/parse/fetched-time", test_parse_fetched_time);
  g_test_add_func("/metno/parse/null-and-programmer-errors", test_parse_null_and_programmer_errors);
  g_test_add_func("/metno/parse/guard-page", test_parse_guard_page);
  g_test_add_func("/metno/parse/size-limits", test_parse_size_limits);
  g_test_add_func("/metno/parse/json-limits", test_parse_json_limits);
  g_test_add_func("/metno/parse/fuzz-model", test_parse_fuzz_against_model);
  g_test_add_func("/metno/parse/fuzz-mutations", test_parse_fuzz_mutations);
  g_test_add_func("/metno/provider/identity", test_provider_identity);
  g_test_add_func("/metno/provider/new-production", test_new_production);
  g_test_add_func("/metno/provider/new-custom-validation", test_new_custom_validation);
  g_test_add_func("/metno/provider/registry", test_registry_integration);
  g_test_add_func("/metno/net/success-request-shape", test_net_success_and_request_shape);
  g_test_add_func("/metno/net/london-fixture", test_net_london_fixture);
  g_test_add_func("/metno/net/coordinates-rounded", test_net_coordinates_are_rounded);
  g_test_add_func("/metno/net/cache-key", test_net_cache_key_is_the_rounded_coordinates);
  g_test_add_func("/metno/net/floor-and-revalidation", test_net_floor_and_revalidation);
  g_test_add_func("/metno/net/not-modified", test_net_not_modified);
  g_test_add_func("/metno/net/validator-round-trip", test_net_validator_round_trip);
  g_test_add_func("/metno/net/expires", test_net_expires);
  g_test_add_func("/metno/net/implausible-expires", test_net_implausible_expires_is_ignored);
  g_test_add_func("/metno/net/expires-cap-24h", test_net_expires_is_capped_at_24_hours);
  g_test_add_func("/metno/net/clock-backwards", test_net_clock_going_backwards);
  g_test_add_func("/metno/net/clock-extremes", test_net_clock_extremes);
  g_test_add_func("/metno/net/floor-after-failure", test_net_floor_after_failure_serves_the_cache);
  g_test_add_func("/metno/net/floor-counts-started-requests", test_net_floor_counts_started_requests_only);
  g_test_add_func("/metno/net/floor-after-timeout", test_net_floor_after_timeout);
  g_test_add_func("/metno/net/floor-per-place", test_net_floor_is_per_place);
  g_test_add_func("/metno/net/floor-records-bounded", test_net_floor_records_are_bounded);
  g_test_add_func("/metno/net/floor-and-throttle-with-entry", test_net_floor_and_throttle_with_entry);
  g_test_add_func("/metno/net/floor-join-does-not-renew", test_net_floor_join_does_not_renew);
  g_test_add_func("/metno/net/floor-clock-backwards", test_net_floor_clock_backwards);
  g_test_add_func("/metno/net/floor-serve-counts-as-use", test_net_floor_serve_counts_as_use);
  g_test_add_func("/metno/net/lru-eviction", test_net_lru_eviction);
  g_test_add_func("/metno/net/not-modified-after-eviction", test_net_not_modified_after_eviction);
  g_test_add_func("/metno/net/failure-table", test_net_failure_table);
  g_test_add_func("/metno/net/bad-body-keeps-cache", test_net_bad_body_keeps_cache);
  g_test_add_func("/metno/net/throttle-429", test_net_throttle_after_429);
  g_test_add_func("/metno/net/throttle-clock-backwards", test_net_throttle_clock_backwards);
  g_test_add_func("/metno/net/throttle-spares-in-flight", test_net_throttle_spares_requests_in_flight);
  g_test_add_func("/metno/net/shared-request", test_net_concurrent_fetches_share_one_request);
  g_test_add_func("/metno/net/cancel-one-of-shared", test_net_cancel_one_of_shared_fetches);
  g_test_add_func("/metno/net/cancel-all-cancels-request", test_net_cancel_all_cancels_the_request);
  g_test_add_func("/metno/net/fetch-right-after-cancel-all", test_net_fetch_right_after_cancel_all);
  g_test_add_func("/metno/net/cancel-before-and-after", test_net_cancel_before_and_after);
  g_test_add_func("/metno/net/cancel-in-flight", test_net_cancel_in_flight);
  g_test_add_func("/metno/net/cancelled-request-keeps-entry", test_net_cancelled_request_leaves_the_entry);
  g_test_add_func("/metno/net/inflight-cap", test_net_inflight_cap);
  g_test_add_func("/metno/net/drop-provider-in-flight", test_net_drop_provider_in_flight);
  g_test_add_func("/metno/net/works-after-dispose", test_net_works_after_dispose);
  g_test_add_func("/metno/net/invalid-places", test_net_invalid_places);
  g_test_add_func("/metno/net/programmer-errors", test_net_programmer_errors);
  g_test_add_func("/metno/net/callbacks-once-never-nested", test_net_callbacks_once_and_never_nested);
  g_test_add_func("/metno/net/stress", test_net_stress);

  int result = g_test_run();
  g_free(miami_text);
  g_free(london_text);
  remove_tree(sandbox);
  return result;
}
