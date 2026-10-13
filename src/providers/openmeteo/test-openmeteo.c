/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of the Open-Meteo provider and geocoder (wx-openmeteo.c).
 *
 * Part 1: the pure parsers over captured real responses (fixtures/, one
 * argument: the fixture directory) and hostile synthetic bodies, checked
 * against an independent oracle and a differential fuzzer.
 * Part 2: the provider and geocoder objects against a loopback fake server
 * (GSocketService). Nothing here touches the Internet or the user's XDG dirs.
 *
 * Place-search text rules: the oracle (oracle_search()) is the list of the
 * header, typed in again; the default run checks every Unicode scalar value
 * against the header's lists without network (header-lists-match-runtime,
 * parse/geocode-forbidden-sweep) and the class boundaries plus a spread of
 * code points through the public API; ONE extra test, skipped unless run with
 * "-m slow" or WX_TEST_EXHAUSTIVE=1, sends every scalar value (4 templates)
 * and a defined set of raw byte sequences through the public API, enumerated in the test: all 2-byte
 * pairs (first byte 0x80..0xFF, second 0x01..0xFF; valid ones included), the 3-byte sequences that the oracle
 * decoder refuses with lead E0..EF and both other bytes 0x80..0xFF, the refused 4-byte sequences with lead
 * F0..F7 and bytes 2-3 in 0x80..0xBF (byte 4 in 0x80..0xBF for the leads F0 and F4, only 0x80 and 0xBF for
 * the others), a sample of edge values (9 per byte) for the leads F0..FF, and one 5- and one 6-byte form;
 * millions of
 * loopback requests: 14.5 minutes measured, with other jobs running):
 *   test-openmeteo FIXTURE_DIR -m slow -p /openmeteo/geocoder/scalar-sweep-exhaustive
 * (also registered as the meson benchmark "openmeteo-exhaustive").
 */
#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <locale.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-geo.h"
#include "wx-http.h"
#include "wx-openmeteo.h"
#include "wx-registry.h"
#include "wx-text.h"
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
#define T0 G_GINT64_CONSTANT(1791763200) /* 2026-10-12T00:00:00Z, the first stamp of the fixtures */
#define FETCHED G_GINT64_CONSTANT(1791800000)

static const char *fixture_dir;

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

/* A buffer of @len bytes that ends exactly at a PROT_NONE guard page. */
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

/* The fixture @name, NUL-terminated (g_file_get_contents() terminates it), cached for the process. */
static const char *
fixture_text(const char *name, gsize *len)
{
  static GHashTable *cache;
  if (cache == NULL)
    cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
  GBytes *bytes = g_hash_table_lookup(cache, name);
  if (bytes == NULL) {
    g_autofree char *path = g_build_filename(fixture_dir, name, NULL);
    g_autoptr(GError) error = NULL;
    char *contents;
    gsize n;
    g_assert_true(g_file_get_contents(path, &contents, &n, &error));
    g_assert_no_error(error);
    bytes = g_bytes_new_take(contents, n);
    g_hash_table_insert(cache, g_strdup(name), bytes);
  }
  if (len != NULL)
    *len = g_bytes_get_size(bytes);
  return g_bytes_get_data(bytes, NULL);
}

static gboolean
same_double(double a, double b)
{
  if (isnan(a) || isnan(b))
    return isnan(a) && isnan(b);
  return a == b && signbit(a) == signbit(b);
}

static const WxMember *
result_member(const WxSourceResult *result, guint i)
{
  g_assert_cmpuint(i, <, result->members->len);
  return g_ptr_array_index(result->members, i);
}

static void
assert_result_model_ids(const WxSourceResult *result, const char *const *ids, guint n)
{
  g_assert_cmpuint(result->members->len, ==, n);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpstr(wx_member_get_source_id(result_member(result, i)), ==, "open-meteo");
    g_assert_cmpstr(wx_member_get_model_id(result_member(result, i)), ==, ids[i]);
  }
}

static const WxHour *
hour_at(const WxMember *member, gint64 t_s)
{
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  for (guint i = 0; i < n; i++)
    if (hours[i].t_s == t_s)
      return &hours[i];
  return NULL;
}

/* Parses with the default model list of @models (a NULL-terminated array). */
static WxSourceResult *
forecast(const char *text, const char *const *models, GError **error)
{
  guint n = 0;
  while (models[n] != NULL)
    n++;
  return wx_open_meteo_parse_forecast(BODY(text), models, n, FETCHED, error);
}

static void assert_hour(const WxHour *h, gint64 t, double temp, double feels, double hum, double precip,
                        double prob, double cloud, double wind, double gust, int wmo);

static const char *const miami_models[] = {"ncep_hrrr_conus", "ncep_nbm_conus", "gfs_seamless",
                                           "ecmwf_ifs025",    "icon_seamless",  "gem_seamless", NULL};
static const char *const miami_ids[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem"};
static const char *const london_models[] = {"ecmwf_ifs025", "icon_seamless", "gem_seamless",
                                            "gfs_seamless",  "ukmo_seamless", "meteofrance_seamless", NULL};
static const char *const london_ids[] = {"ecmwf", "icon", "gem", "gfs", "ukmo", "meteofrance"};
static const char *const gfs_only[] = {"gfs_seamless", NULL};

/* ------------------------------------------------------------------------ */
/* Independent oracle: the stamp semantics restated with plain json-glib     */
/* ------------------------------------------------------------------------ */

typedef struct {
  gint64 t;
  double v[8]; /* temp, feels, precip, prob, cloud, wind, gust, humidity */
  int wmo;
} ExpHour;

enum { E_TEMP, E_FEELS, E_PRECIP, E_PROB, E_CLOUD, E_WIND, E_GUST, E_HUM };

/* A JSON value node as a finite double, or FALSE (strings, booleans, null, containers). */
static gboolean
onode_number(JsonNode *node, double *out)
{
  if (node == NULL || !JSON_NODE_HOLDS_VALUE(node))
    return FALSE;
  GType type = json_node_get_value_type(node);
  double v;
  if (type == G_TYPE_INT64) {
    gint64 i = json_node_get_int(node);
    if (i == G_MAXINT64 || i == G_MININT64)
      return FALSE;
    v = (double)i;
  } else if (type == G_TYPE_DOUBLE) {
    v = json_node_get_double(node);
  } else {
    return FALSE;
  }
  if (!isfinite(v))
    return FALSE;
  *out = v;
  return TRUE;
}

static double
oval(JsonObject *hourly, const char *key, guint i, double lo, double hi)
{
  JsonNode *arr = json_object_get_member(hourly, key);
  double v;
  if (arr == NULL || !JSON_NODE_HOLDS_ARRAY(arr))
    return NAN;
  JsonArray *a = json_node_get_array(arr);
  if (i >= json_array_get_length(a) || !onode_number(json_array_get_element(a, i), &v))
    return NAN;
  if (v < lo || v > hi)
    return NAN;
  return v == 0 ? 0.0 : v;
}

static int
cmp_i64(gconstpointer a, gconstpointer b)
{
  gint64 x = *(const gint64 *)a, y = *(const gint64 *)b;
  return x < y ? -1 : x > y;
}

/* Expected hours of one model, or NULL when the model must be dropped. */
static GArray *
oracle_hours(JsonObject *hourly, const char *api_id, gboolean suffixed)
{
  JsonNode *tn = json_object_get_member(hourly, "time");
  g_assert_nonnull(tn);
  g_assert_true(JSON_NODE_HOLDS_ARRAY(tn));
  JsonArray *times = json_node_get_array(tn);
  GArray *st = g_array_new(FALSE, FALSE, sizeof(gint64));
  GArray *ix = g_array_new(FALSE, FALSE, sizeof(guint));
  for (guint i = 0; i < json_array_get_length(times); i++) {
    double v;
    if (!onode_number(json_array_get_element(times, i), &v))
      continue;
    if (v < (double)WX_TIME_MIN_S || v > (double)(WX_TIME_MAX_S - 1) || v != floor(v))
      continue;
    gint64 t = (gint64)v;
    if (t % 3600 != 0)
      continue;
    if (st->len > 0 && t <= g_array_index(st, gint64, st->len - 1))
      continue;
    g_array_append_val(st, t);
    g_array_append_val(ix, i);
  }
  /* The buckets: every stamp and every stamp minus one hour, ascending, unique. */
  GArray *buckets = g_array_new(FALSE, FALSE, sizeof(gint64));
  for (guint k = 0; k < st->len; k++) {
    gint64 t = g_array_index(st, gint64, k);
    g_array_append_val(buckets, t);
    gint64 p = t - 3600;
    g_array_append_val(buckets, p);
  }
  g_array_sort(buckets, cmp_i64);

  static const struct {
    const char *key;
    double lo, hi;
    int slot;
  } vars[] = {{"temperature_2m", -100, 70, E_TEMP},         {"apparent_temperature", -100, 70, E_FEELS},
              {"precipitation", 0, 500, E_PRECIP},          {"precipitation_probability", 0, 100, E_PROB},
              {"cloud_cover", 0, 100, E_CLOUD},             {"wind_speed_10m", 0, 500, E_WIND},
              {"wind_gusts_10m", 0, 500, E_GUST},           {"relative_humidity_2m", 0, 100, E_HUM}};
  GArray *out = g_array_new(FALSE, FALSE, sizeof(ExpHour));
  guint finite_total = 0;
  gint64 prev = -1;
  for (guint b = 0; b < buckets->len; b++) {
    gint64 t = g_array_index(buckets, gint64, b);
    if (t == prev || t < WX_TIME_MIN_S)
      continue;
    prev = t;
    ExpHour h = {.t = t, .wmo = -1};
    for (guint s = 0; s < 8; s++)
      h.v[s] = NAN;
    for (guint k = 0; k < st->len; k++) {
      gint64 s = g_array_index(st, gint64, k);
      guint i = g_array_index(ix, guint, k);
      for (guint v = 0; v < G_N_ELEMENTS(vars); v++) {
        g_autofree char *key = suffixed ? g_strdup_printf("%s_%s", vars[v].key, api_id)
                                        : g_strdup(vars[v].key);
        gboolean precip_like = vars[v].slot == E_PRECIP || vars[v].slot == E_PROB;
        if ((precip_like && s == t + 3600) || (!precip_like && s == t))
          h.v[vars[v].slot] = oval(hourly, key, i, vars[v].lo, vars[v].hi);
      }
      if (s == t) {
        g_autofree char *key = suffixed ? g_strdup_printf("weather_code_%s", api_id) : g_strdup("weather_code");
        double w = oval(hourly, key, i, 0, 99);
        h.wmo = (isnan(w) || w != floor(w)) ? -1 : (int)w;
      }
    }
    guint finite = 0;
    for (guint s = 0; s < 8; s++)
      finite += isfinite(h.v[s]) ? 1 : 0;
    if (finite == 0 && h.wmo < 0)
      continue;
    finite_total += finite;
    g_array_append_val(out, h);
  }
  g_array_unref(st);
  g_array_unref(ix);
  g_array_unref(buckets);
  if (finite_total == 0) {
    g_array_unref(out);
    return NULL;
  }
  return out;
}

static void
assert_member_matches(const WxMember *member, const GArray *exp)
{
  guint n;
  const WxHour *hours = wx_member_get_hours(member, &n);
  g_assert_cmpuint(n, ==, exp->len);
  for (guint i = 0; i < n; i++) {
    const ExpHour *e = &g_array_index(exp, ExpHour, i);
    g_assert_cmpint(hours[i].t_s, ==, e->t);
    g_assert_true(same_double(hours[i].temp_c, e->v[E_TEMP]));
    g_assert_true(same_double(hours[i].feels_c, e->v[E_FEELS]));
    g_assert_true(same_double(hours[i].precip_mm, e->v[E_PRECIP]));
    g_assert_true(same_double(hours[i].precip_prob, e->v[E_PROB]));
    g_assert_true(same_double(hours[i].cloud_pct, e->v[E_CLOUD]));
    g_assert_true(same_double(hours[i].wind_kmh, e->v[E_WIND]));
    g_assert_true(same_double(hours[i].gust_kmh, e->v[E_GUST]));
    g_assert_true(same_double(hours[i].humidity_pct, e->v[E_HUM]));
    g_assert_cmpint(hours[i].wmo, ==, e->wmo);
  }
}

/* Checks a parse result against the oracle for every requested model. */
static void
assert_forecast_matches_oracle(const char *text, const char *const *models, guint n_models,
                               WxSourceResult *result)
{
  g_autoptr(JsonParser) parser = json_parser_new();
  g_assert_true(json_parser_load_from_data(parser, text, -1, NULL));
  JsonObject *hourly = json_object_get_object_member(json_node_get_object(json_parser_get_root(parser)),
                                                     "hourly");
  static const struct {
    const char *api, *id;
  } ids[] = {{"ncep_hrrr_conus", "hrrr"}, {"ncep_nbm_conus", "nbm"},   {"gfs_seamless", "gfs"},
             {"ecmwf_ifs025", "ecmwf"},   {"icon_seamless", "icon"},   {"gem_seamless", "gem"},
             {"ukmo_seamless", "ukmo"},   {"meteofrance_seamless", "meteofrance"}};
  guint next = 0;
  for (guint m = 0; m < n_models; m++) {
    const char *id = NULL;
    for (guint k = 0; k < G_N_ELEMENTS(ids); k++)
      if (strcmp(ids[k].api, models[m]) == 0)
        id = ids[k].id;
    g_assert_nonnull(id);
    GArray *exp = oracle_hours(hourly, models[m], n_models > 1);
    if (exp == NULL)
      continue;
    const WxMember *member = result_member(result, next++);
    g_assert_cmpstr(wx_member_get_model_id(member), ==, id);
    g_assert_cmpstr(wx_member_get_source_id(member), ==, "open-meteo");
    g_assert_cmpint(wx_member_get_fetched_s(member), ==, FETCHED);
    assert_member_matches(member, exp);
    guint nq;
    (void)wx_member_get_quarters(member, &nq);
    g_assert_cmpuint(nq, ==, 0);
    g_array_unref(exp);
  }
  g_assert_cmpuint(result->members->len, ==, next);
}

/* ------------------------------------------------------------------------ */
/* Parser tests over the captured fixtures                                  */
/* ------------------------------------------------------------------------ */

static void
test_parse_miami_fixture(void)
{
  gsize len;
  const char *text = fixture_text("forecast_miami_multi.json", &len);
  g_assert_cmpuint(len, <=, 200 * 1024);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, miami_models, &error);
  g_assert_no_error(error);
  g_assert_nonnull(result);
  g_assert_cmpstr(result->provider_id, ==, "open-meteo");
  assert_result_model_ids(result, miami_ids, 6);

  /* GFS: complete arrays of 240 stamps -> 240 instants + the bucket of the first precipitation. */
  const WxMember *gfs = result_member(result, 2);
  guint n;
  const WxHour *hours = wx_member_get_hours(gfs, &n);
  g_assert_cmpuint(n, ==, 241);
  g_assert_cmpint(hours[0].t_s, ==, T0 - 3600);
  g_assert_cmpint(hours[240].t_s, ==, T0 + 239 * 3600);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpint(hours[i].t_s % 3600, ==, 0);
    if (i > 0)
      g_assert_cmpint(hours[i].t_s, ==, hours[i - 1].t_s + 3600);
  }
  /* Bucket T0 - 3600 holds ONLY the precipitation values stamped T0 (0.0 mm, 1 %). */
  g_assert_true(same_double(hours[0].precip_mm, 0.0));
  g_assert_true(same_double(hours[0].precip_prob, 1.0));
  g_assert_true(isnan(hours[0].temp_c));
  g_assert_true(isnan(hours[0].feels_c));
  g_assert_true(isnan(hours[0].cloud_pct));
  g_assert_true(isnan(hours[0].wind_kmh));
  g_assert_true(isnan(hours[0].gust_kmh));
  g_assert_true(isnan(hours[0].humidity_pct));
  g_assert_cmpint(hours[0].wmo, ==, -1);
  /* Bucket T0: instants stamped T0 (27.7 degC, 86 %, 2 %, 4.4 km/h, 9.7 km/h, WMO 0). */
  g_assert_true(same_double(hours[1].temp_c, 27.7));
  g_assert_true(same_double(hours[1].feels_c, 33.9));
  g_assert_true(same_double(hours[1].humidity_pct, 86.0));
  g_assert_true(same_double(hours[1].cloud_pct, 2.0));
  g_assert_true(same_double(hours[1].wind_kmh, 4.4));
  g_assert_true(same_double(hours[1].gust_kmh, 9.7));
  g_assert_cmpint(hours[1].wmo, ==, 0);
  /* ... and the precipitation stamped T0 + 3600 (the next stamp). */
  g_assert_true(same_double(hours[1].precip_mm, 0.0));
  g_assert_true(same_double(hours[1].precip_prob, 1.0));
  /* The last bucket has no later stamp: instants only. */
  g_assert_false(isnan(hours[240].temp_c));
  g_assert_true(isnan(hours[240].precip_mm));
  g_assert_true(isnan(hours[240].precip_prob));

  /* HRRR has instants and precipitation for the first 61 stamps only, but a probability for all 240:
   * its 240 buckets (T0 - 1 h .. T0 + 238 h) hold the probability, the later ones only that. */
  hours = wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, 240);
  g_assert_cmpint(hours[0].t_s, ==, T0 - 3600);
  g_assert_false(isnan(hours[61].temp_c)); /* stamp T0 + 60 h */
  g_assert_cmpint(hours[61].t_s, ==, T0 + 60 * 3600);
  g_assert_true(isnan(hours[62].temp_c));
  g_assert_true(isnan(hours[62].precip_mm));
  g_assert_false(isnan(hours[62].precip_prob));
  g_assert_cmpint(hours[62].wmo, ==, -1);
  /* ICON has 47 trailing nulls (193 stamps); its probability stops earlier. */
  hours = wx_member_get_hours(result_member(result, 4), &n);
  g_assert_cmpuint(n, ==, 194);
  /* Every member: no quarters, the fetch time given, ranges respected. */
  for (guint m = 0; m < 6; m++) {
    const WxMember *member = result_member(result, m);
    g_assert_cmpint(wx_member_get_fetched_s(member), ==, FETCHED);
    guint nq, nh;
    (void)wx_member_get_quarters(member, &nq);
    g_assert_cmpuint(nq, ==, 0);
    hours = wx_member_get_hours(member, &nh);
    for (guint i = 0; i < nh; i++) {
      g_assert_true(isnan(hours[i].temp_c) || (hours[i].temp_c >= -100 && hours[i].temp_c <= 70));
      g_assert_true(isnan(hours[i].wind_kmh) || (hours[i].wind_kmh >= 0 && hours[i].wind_kmh <= 500));
      g_assert_true(isnan(hours[i].precip_prob) || (hours[i].precip_prob >= 0 && hours[i].precip_prob <= 100));
    }
  }
  assert_forecast_matches_oracle(text, miami_models, 6, result);
}

static void
test_parse_london_fixture(void)
{
  const char *text = fixture_text("forecast_london_multi.json", NULL);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, london_models, &error);
  g_assert_no_error(error);
  g_assert_nonnull(result);
  assert_result_model_ids(result, london_ids, 6);
  guint n;
  /* ECMWF: the whole 240 hours; Meteo-France has 115 non-null stamps and NO probability. */
  (void)wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, 241);
  const WxHour *mf = wx_member_get_hours(result_member(result, 5), &n);
  g_assert_cmpuint(n, ==, 116);
  for (guint i = 0; i < n; i++)
    g_assert_true(isnan(mf[i].precip_prob));
  g_assert_true(same_double(mf[1].temp_c, 13.8));
  g_assert_true(same_double(mf[1].humidity_pct, 74.0));
  g_assert_cmpint(mf[1].wmo, ==, 3);
  /* UKMO: 169 stamps with data (T0 .. T0 + 168 h), but a probability for all 240 stamps. */
  const WxHour *ukmo = wx_member_get_hours(result_member(result, 4), &n);
  g_assert_cmpuint(n, ==, 240);
  g_assert_cmpint(ukmo[169].t_s, ==, T0 + 168 * 3600);
  g_assert_false(isnan(ukmo[169].temp_c));
  g_assert_true(isnan(ukmo[170].temp_c));
  g_assert_false(isnan(ukmo[170].precip_prob));
  assert_forecast_matches_oracle(text, london_models, 6, result);
}

static void
test_parse_single_model_keys_are_not_suffixed(void)
{
  /* Rename the ECMWF keys of the Miami fixture to the unsuffixed form. */
  const char *text = fixture_text("forecast_miami_multi.json", NULL);
  g_autoptr(JsonParser) parser = json_parser_new();
  g_assert_true(json_parser_load_from_data(parser, text, -1, NULL));
  JsonObject *hourly = json_object_get_object_member(json_node_get_object(json_parser_get_root(parser)),
                                                     "hourly");
  static const char *const vars[] = {"temperature_2m", "apparent_temperature", "relative_humidity_2m",
                                     "precipitation",  "precipitation_probability", "cloud_cover",
                                     "wind_speed_10m", "wind_gusts_10m", "weather_code"};
  JsonObject *plain = json_object_new();
  json_object_set_member(plain, "time", json_node_copy(json_object_get_member(hourly, "time")));
  for (guint v = 0; v < G_N_ELEMENTS(vars); v++) {
    g_autofree char *key = g_strdup_printf("%s_ecmwf_ifs025", vars[v]);
    json_object_set_member(plain, vars[v], json_node_copy(json_object_get_member(hourly, key)));
  }
  g_autoptr(JsonNode) root = json_node_new(JSON_NODE_OBJECT);
  JsonObject *top = json_object_new();
  json_object_set_object_member(top, "hourly", plain);
  json_node_take_object(root, top);
  g_autoptr(JsonGenerator) gen = json_generator_new();
  json_generator_set_root(gen, root);
  g_autofree char *single = json_generator_to_data(gen, NULL);

  static const char *const one[] = {"ecmwf_ifs025", NULL};
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(single, one, &error);
  g_assert_no_error(error);
  g_assert_nonnull(result);
  static const char *const ids[] = {"ecmwf"};
  assert_result_model_ids(result, ids, 1);
  g_autoptr(WxSourceResult) multi = forecast(text, miami_models, NULL);
  guint n1, n2;
  const WxHour *a = wx_member_get_hours(result_member(result, 0), &n1);
  const WxHour *b = wx_member_get_hours(result_member(multi, 3), &n2);
  g_assert_cmpuint(n1, ==, n2);
  for (guint i = 0; i < n1; i++)
    assert_hour(&a[i], b[i].t_s, b[i].temp_c, b[i].feels_c, b[i].humidity_pct, b[i].precip_mm,
                b[i].precip_prob, b[i].cloud_pct, b[i].wind_kmh, b[i].gust_kmh, b[i].wmo);

  /* Keys of the other form are not found: no member at all. */
  g_clear_pointer(&result, wx_source_result_free);
  result = forecast(single, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_clear_error(&error);
  static const char *const two[] = {"ecmwf_ifs025", "gfs_seamless", NULL};
  result = forecast(single, two, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_clear_error(&error);
  result = forecast(text, one, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
}

static void
test_parse_nowcast_fixture(void)
{
  const char *text = fixture_text("nowcast_miami.json", NULL);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) member = wx_open_meteo_parse_nowcast(BODY(text), FETCHED, &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  g_assert_cmpstr(wx_member_get_source_id(member), ==, "open-meteo");
  g_assert_cmpstr(wx_member_get_model_id(member), ==, "hrrr15");
  g_assert_cmpint(wx_member_get_fetched_s(member), ==, FETCHED);
  guint nh, nq;
  (void)wx_member_get_hours(member, &nh);
  g_assert_cmpuint(nh, ==, 0);
  const WxQuarter *q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 12);
  /* The first stamp of the capture is 1791832500 (the END of the quarter): stored 900 s earlier. */
  g_assert_cmpint(q[0].t_s, ==, 1791832500 - 900);
  g_assert_cmpint(q[11].t_s, ==, 1791842400 - 900);
  for (guint i = 0; i < nq; i++) {
    g_assert_cmpint(q[i].t_s % 900, ==, 0);
    g_assert_true(same_double(q[i].precip_mm, 0.0));
    if (i > 0)
      g_assert_cmpint(q[i].t_s, ==, q[i - 1].t_s + 900);
  }
}

static void
test_parse_geocode_fixture(void)
{
  const char *text = fixture_text("geocode_miami.json", NULL);
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) places = wx_open_meteo_parse_geocode(BODY(text), &error);
  g_assert_no_error(error);
  g_assert_nonnull(places);
  g_assert_cmpuint(places->len, ==, 10);
  const WxPlace *first = g_ptr_array_index(places, 0);
  g_assert_cmpstr(first->name, ==, "Miami");
  g_assert_cmpstr(first->admin1, ==, "Florida");
  g_assert_cmpstr(first->country, ==, "United States");
  g_assert_cmpstr(first->country_code, ==, "US");
  g_assert_cmpstr(first->timezone, ==, "America/New_York");
  g_assert_true(same_double(first->lat, 25.77427));
  g_assert_true(same_double(first->lon, -80.19366));
  g_autofree char *label = wx_place_label(first);
  g_assert_cmpstr(label, ==, "Miami, Florida, United States");
  g_autofree char *key = wx_place_key(first);
  g_assert_cmpstr(key, ==, "25.7743,-80.1937");
  const WxPlace *last = g_ptr_array_index(places, 9);
  g_assert_cmpstr(last->admin1, ==, "Manitoba");
  g_assert_cmpstr(last->country_code, ==, "CA");
  g_assert_cmpstr(last->timezone, ==, "America/Winnipeg");
  const WxPlace *indiana = g_ptr_array_index(places, 7);
  g_assert_cmpstr(indiana->timezone, ==, "America/Indiana/Indianapolis");
}

static void
test_parse_error_fixture(void)
{
  const char *text = fixture_text("error_400.json", NULL);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpstr(error->message, ==,
                  "Open-Meteo reported an error: Invalid value: Cannot initialize MultiDomains from "
                  "invalid String value bogus_model");
  g_clear_error(&error);
  g_autoptr(WxMember) member = wx_open_meteo_parse_nowcast(BODY(text), FETCHED, &error);
  g_assert_null(member);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_clear_error(&error);
  g_autoptr(GPtrArray) places = wx_open_meteo_parse_geocode(BODY(text), &error);
  g_assert_null(places);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_clear_error(&error);

  /* Variants: no reason, a reason with controls and bidi marks, a very long reason, error=false. */
  result = forecast("{\"error\":true}", miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpstr(error->message, ==, "Open-Meteo reported an error: ");
  g_clear_error(&error);
  result = forecast("{\"error\":true,\"reason\":\"a\\u0001b\\u202ec\\n%s%n\"}", miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpstr(error->message, ==, "Open-Meteo reported an error: abc%s%n");
  g_clear_error(&error);
  g_autofree char *longer = g_strdup_printf("{\"error\":true,\"reason\":\"%0200d\"}", 7);
  result = forecast(longer, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpuint(strlen(error->message), ==, strlen("Open-Meteo reported an error: ") + 120);
  g_clear_error(&error);
  result = forecast("{\"error\":false,\"reason\":\"x\"}", miami_models, &error);
  g_assert_null(result); /* not an error body: just no data */
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
}

/* ------------------------------------------------------------------------ */
/* Stamp and bucket semantics on hand-made bodies                           */
/* ------------------------------------------------------------------------ */

/* One-model body with the given "time" array text and 3 values per variable. */
static char *
body3(const char *times)
{
  return g_strdup_printf(
      "{\"hourly\":{\"time\":%s,\"temperature_2m\":[10,11,12],\"apparent_temperature\":[9,10,11],"
      "\"relative_humidity_2m\":[50,51,52],\"precipitation\":[0.1,0.2,0.3],"
      "\"precipitation_probability\":[10,20,30],\"cloud_cover\":[1,2,3],\"wind_speed_10m\":[5,6,7],"
      "\"wind_gusts_10m\":[8,9,10],\"weather_code\":[0,3,61]}}",
      times);
}

static void
assert_hour(const WxHour *h, gint64 t, double temp, double feels, double hum, double precip, double prob,
            double cloud, double wind, double gust, int wmo)
{
  g_assert_nonnull(h);
  g_assert_cmpint(h->t_s, ==, t);
  g_assert_true(same_double(h->temp_c, temp));
  g_assert_true(same_double(h->feels_c, feels));
  g_assert_true(same_double(h->humidity_pct, hum));
  g_assert_true(same_double(h->precip_mm, precip));
  g_assert_true(same_double(h->precip_prob, prob));
  g_assert_true(same_double(h->cloud_pct, cloud));
  g_assert_true(same_double(h->wind_kmh, wind));
  g_assert_true(same_double(h->gust_kmh, gust));
  g_assert_cmpint(h->wmo, ==, wmo);
}

static void
test_parse_bucket_times(void)
{
  g_autofree char *times = g_strdup_printf("[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]",
                                           T0, T0 + 3600, T0 + 7200);
  g_autofree char *text = body3(times);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  g_assert_nonnull(result);
  guint n;
  const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, 4);
  /* instants at T, precipitation and probability of stamp T in the bucket T - 3600 */
  assert_hour(&h[0], T0 - 3600, NAN, NAN, NAN, 0.1, 10, NAN, NAN, NAN, -1);
  assert_hour(&h[1], T0, 10, 9, 50, 0.2, 20, 1, 5, 8, 0);
  assert_hour(&h[2], T0 + 3600, 11, 10, 51, 0.3, 30, 2, 6, 9, 3);
  assert_hour(&h[3], T0 + 7200, 12, 11, 52, NAN, NAN, 3, 7, 10, 61);

  /* A gap: the precipitation of the later stamp gets a bucket of its own. */
  g_autofree char *gap = g_strdup_printf("[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]",
                                         T0, T0 + 3 * 3600, T0 + 4 * 3600);
  g_autofree char *gap_text = body3(gap);
  g_autoptr(WxSourceResult) gapped = forecast(gap_text, gfs_only, &error);
  g_assert_no_error(error);
  h = wx_member_get_hours(result_member(gapped, 0), &n);
  g_assert_cmpuint(n, ==, 5);
  assert_hour(&h[0], T0 - 3600, NAN, NAN, NAN, 0.1, 10, NAN, NAN, NAN, -1);
  assert_hour(&h[1], T0, 10, 9, 50, NAN, NAN, 1, 5, 8, 0);
  assert_hour(&h[2], T0 + 2 * 3600, NAN, NAN, NAN, 0.2, 20, NAN, NAN, NAN, -1);
  assert_hour(&h[3], T0 + 3 * 3600, 11, 10, 51, 0.3, 30, 2, 6, 9, 3);
  assert_hour(&h[4], T0 + 4 * 3600, 12, 11, 52, NAN, NAN, 3, 7, 10, 61);
}

static void
assert_used_stamps(const char *times, guint expect_hours)
{
  g_autofree char *text = body3(times);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  g_assert_nonnull(result);
  guint n;
  (void)wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, expect_hours);
}

static void
test_parse_time_entries_skipped(void)
{
  /* Only the stamp at index 0 survives each of these: its values give 1 instant + 1 precipitation bucket. */
  g_autofree char *t = g_strdup_printf("%" G_GINT64_FORMAT, T0);
  g_autofree char *dup = g_strdup_printf("[%s,%s,%s]", t, t, t);
  assert_used_stamps(dup, 2);                                              /* duplicates */
  g_autofree char *desc = g_strdup_printf("[%s,%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]", t, T0 - 3600, T0 - 7200);
  assert_used_stamps(desc, 2);                                             /* descending */
  g_autofree char *mis = g_strdup_printf("[%s,%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]", t, T0 + 1800, T0 + 3601);
  assert_used_stamps(mis, 2);                                              /* not a multiple of 3600 */
  g_autofree char *frac = g_strdup_printf("[%s,%" G_GINT64_FORMAT ".5,%" G_GINT64_FORMAT ".25]", t, T0 + 3600, T0 + 7200);
  assert_used_stamps(frac, 2);                                             /* not integer-valued */
  g_autofree char *junk = g_strdup_printf("[%s,\"%" G_GINT64_FORMAT "\",null]", t, T0 + 3600);
  assert_used_stamps(junk, 2);                                             /* string and null */
  g_autofree char *kinds = g_strdup_printf("[%s,true,{},[],-1,1e30,1e999,9223372036854775807]", t);
  assert_used_stamps(kinds, 2);                                            /* bool, containers, range */
  /* Which entries are used shows in the values: the skipped index contributes nothing. */
  g_autofree char *dup2 = g_strdup_printf("[%s,%s,%" G_GINT64_FORMAT "]", t, t, T0 + 3600);
  g_autofree char *desc2 = g_strdup_printf("[%s,%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]", t, T0 - 3600, T0 + 3600);
  g_autofree char *mis2 = g_strdup_printf("[%s,%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]", t, T0 + 1800, T0 + 3600);
  const char *const second_group[] = {dup2, desc2, mis2};
  for (guint i = 0; i < G_N_ELEMENTS(second_group); i++) {
    g_autofree char *second_text = body3(second_group[i]);
    g_autoptr(GError) second_error = NULL;
    g_autoptr(WxSourceResult) second = forecast(second_text, gfs_only, &second_error);
    g_assert_no_error(second_error);
    guint count;
    const WxHour *sh = wx_member_get_hours(result_member(second, 0), &count);
    g_assert_cmpuint(count, ==, 3);
    assert_hour(&sh[0], T0 - 3600, NAN, NAN, NAN, 0.1, 10, NAN, NAN, NAN, -1);
    /* stamp index 2 is the next used one: its precipitation lands in the bucket of index 0 */
    assert_hour(&sh[1], T0, 10, 9, 50, 0.3, 30, 1, 5, 8, 0);
    assert_hour(&sh[2], T0 + 3600, 12, 11, 52, NAN, NAN, 3, 7, 10, 61);
  }
  /* the epoch bounds: MIN is the first accepted stamp, MAX the first refused one */
  g_autofree char *edge = g_strdup_printf("[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]",
                                          (gint64)WX_TIME_MIN_S - 3600, (gint64)WX_TIME_MIN_S, (gint64)WX_TIME_MIN_S + 3600);
  g_autofree char *edge_text = body3(edge);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(edge_text, gfs_only, &error);
  g_assert_no_error(error);
  guint n;
  const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
  /* index 1 -> MIN (instants 11,..; its precipitation bucket MIN-3600 is refused by the member),
   * index 2 -> MIN + 3600 (instants 12 and precipitation 0.3 in bucket MIN). */
  g_assert_cmpuint(n, ==, 2);
  g_assert_cmpint(h[0].t_s, ==, (gint64)WX_TIME_MIN_S);
  g_assert_true(same_double(h[0].temp_c, 11));
  g_assert_true(same_double(h[0].precip_mm, 0.3));
  g_assert_cmpint(h[1].t_s, ==, (gint64)WX_TIME_MIN_S + 3600);
  g_autofree char *top = g_strdup_printf("[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "]",
                                         (gint64)WX_TIME_MAX_S - 3600, (gint64)WX_TIME_MAX_S);
  g_autofree char *top_text = body3(top);
  g_autoptr(WxSourceResult) top_result = forecast(top_text, gfs_only, &error);
  g_assert_no_error(error);
  h = wx_member_get_hours(result_member(top_result, 0), &n);
  g_assert_cmpuint(n, ==, 2); /* MAX - 3600 stamp: precipitation bucket of it, then the instants */
  g_assert_cmpint(h[1].t_s, ==, (gint64)WX_TIME_MAX_S - 3600);
}

static char *
times_text(guint n)
{
  GString *s = g_string_new("[");
  for (guint i = 0; i < n; i++)
    g_string_append_printf(s, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 3600);
  g_string_append_c(s, ']');
  return g_string_free(s, FALSE);
}

static void
test_parse_time_step_limit(void)
{
  g_assert_cmpuint(WX_OPEN_METEO_MAX_TIME_STEPS, ==, 384);
  g_autofree char *at = times_text(WX_OPEN_METEO_MAX_TIME_STEPS);
  g_autofree char *at_text = body3(at);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(at_text, gfs_only, &error);
  g_assert_no_error(error);
  guint n;
  (void)wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, 3 + 1); /* values only for the first 3 stamps: 3 instants + 1 */
  g_autofree char *over = times_text(WX_OPEN_METEO_MAX_TIME_STEPS + 1);
  g_autofree char *over_text = body3(over);
  g_clear_pointer(&result, wx_source_result_free);
  result = forecast(over_text, gfs_only, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_assert_cmpstr(error->message, ==, "response has too many time steps");
  g_clear_error(&error);

  /* A full 384-stamp series fills 385 buckets, within WX_MEMBER_MAX_HOURS. */
  GString *s = g_string_new("{\"hourly\":{\"time\":");
  g_string_append(s, at);
  g_string_append(s, ",\"temperature_2m\":[");
  for (guint i = 0; i < WX_OPEN_METEO_MAX_TIME_STEPS; i++)
    g_string_append_printf(s, "%s%u", i ? "," : "", i % 40);
  g_string_append(s, "],\"precipitation\":[");
  for (guint i = 0; i < WX_OPEN_METEO_MAX_TIME_STEPS; i++)
    g_string_append_printf(s, "%s0.5", i ? "," : "");
  g_string_append(s, "]}}");
  result = forecast(s->str, gfs_only, &error);
  g_assert_no_error(error);
  const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, WX_OPEN_METEO_MAX_TIME_STEPS + 1);
  g_assert_cmpuint(n, <=, WX_MEMBER_MAX_HOURS);
  g_assert_true(same_double(h[n - 1].temp_c, (double)((WX_OPEN_METEO_MAX_TIME_STEPS - 1) % 40)));
  g_string_free(s, TRUE);
}

/* 384 stamps spaced 7200 s make 768 buckets (an instant bucket and a precipitation bucket per stamp, none merge):
 * a member keeps the first WX_MEMBER_MAX_HOURS = 400 in time order, i.e. stamps 0..199, and drops the rest silently. */
static void
test_parse_gapped_series_is_cut_at_member_limit(void)
{
  G_STATIC_ASSERT(WX_MEMBER_MAX_HOURS == 400);
  GString *s = g_string_new("{\"hourly\":{\"time\":[");
  for (guint i = 0; i < WX_OPEN_METEO_MAX_TIME_STEPS; i++)
    g_string_append_printf(s, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 7200);
  g_string_append(s, "],\"temperature_2m\":[");
  for (guint i = 0; i < WX_OPEN_METEO_MAX_TIME_STEPS; i++)
    g_string_append_printf(s, "%s%u", i ? "," : "", i % 40);
  g_string_append(s, "],\"precipitation\":[");
  for (guint i = 0; i < WX_OPEN_METEO_MAX_TIME_STEPS; i++)
    g_string_append_printf(s, "%s0.5", i ? "," : "");
  g_string_append(s, "]}}");
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(s->str, gfs_only, &error);
  g_assert_no_error(error);
  guint n;
  const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  for (guint b = 0; b < n; b++) {
    guint k = b / 2; /* stamp index; even buckets are the precipitation buckets */
    if (b % 2 == 0) {
      g_assert_cmpint(h[b].t_s, ==, T0 + (gint64)k * 7200 - 3600);
      g_assert_true(same_double(h[b].precip_mm, 0.5));
      g_assert_true(isnan(h[b].temp_c));
    } else {
      g_assert_cmpint(h[b].t_s, ==, T0 + (gint64)k * 7200);
      g_assert_true(same_double(h[b].temp_c, (double)(k % 40)));
      g_assert_true(isnan(h[b].precip_mm));
    }
  }
  /* last bucket: the instant bucket of stamp 199; stamps 200..383 are gone */
  g_assert_cmpint(h[n - 1].t_s, ==, T0 + 199 * 7200);
  g_assert_true(same_double(h[n - 1].temp_c, 39.0));
  g_string_free(s, TRUE);
}

static void
test_parse_value_ranges(void)
{
  /* Each row: variable key, then the values at the edges; the expected stored values. */
  static const struct {
    const char *key;
    const char *values; /* 8 JSON values, one per stamp */
    double expect[8];
  } rows[] = {
      {"temperature_2m", "[-100,70,-100.0001,70.0001,-101,71,1e308,-1e308]", {-100, 70, NAN, NAN, NAN, NAN, NAN, NAN}},
      {"apparent_temperature", "[-100,70,-100.1,70.1,0,-0.0,5e-324,\"3\"]", {-100, 70, NAN, NAN, 0, 0, 5e-324, NAN}},
      {"relative_humidity_2m", "[0,100,-0.1,100.1,-1,101,true,null]", {0, 100, NAN, NAN, NAN, NAN, NAN, NAN}},
      {"cloud_cover", "[0,100,-1,101,1e999,-1e999,[1],{\"a\":1}]", {0, 100, NAN, NAN, NAN, NAN, NAN, NAN}},
      {"wind_speed_10m", "[0,500,-0.01,500.01,-5,501,1e30,9223372036854775807]", {0, 500, NAN, NAN, NAN, NAN, NAN, NAN}},
      {"wind_gusts_10m", "[0,500,-0.01,500.01,-9223372036854775808,2,2.5,\"x\"]", {0, 500, NAN, NAN, NAN, 2, 2.5, NAN}},
  };
  for (guint r = 0; r < G_N_ELEMENTS(rows); r++) {
    GString *times = g_string_new("[");
    for (guint i = 0; i < 8; i++)
      g_string_append_printf(times, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 3600);
    g_string_append_c(times, ']');
    g_autofree char *text = g_strdup_printf("{\"hourly\":{\"time\":%s,\"%s\":%s}}", times->str, rows[r].key,
                                            rows[r].values);
    g_string_free(times, TRUE);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
    g_assert_no_error(error);
    g_assert_nonnull(result);
    guint n;
    const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
    for (guint i = 0; i < 8; i++) {
      const WxHour *hour = hour_at(result_member(result, 0), T0 + (gint64)i * 3600);
      double got = NAN;
      if (hour != NULL) {
        if (r == 0)
          got = hour->temp_c;
        else if (r == 1)
          got = hour->feels_c;
        else if (r == 2)
          got = hour->humidity_pct;
        else if (r == 3)
          got = hour->cloud_pct;
        else if (r == 4)
          got = hour->wind_kmh;
        else
          got = hour->gust_kmh;
      }
      if (!same_double(got, rows[r].expect[i]))
        g_error("row %u (%s) index %u: got %g expected %g", r, rows[r].key, i, got, rows[r].expect[i]);
    }
    (void)h;
  }

  /* Precipitation and probability: they land in bucket T - 3600. */
  static const char *const pvals = "[0,500,-0.1,500.5,2,1e999,null,\"1\"]";
  static const char *const qvals = "[0,100,-1,100.5,50,1e999,null,\"1\"]";
  GString *times = g_string_new("[");
  for (guint i = 0; i < 8; i++)
    g_string_append_printf(times, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 3600);
  g_string_append_c(times, ']');
  g_autofree char *text = g_strdup_printf("{\"hourly\":{\"time\":%s,\"precipitation\":%s,"
                                          "\"precipitation_probability\":%s,\"weather_code\":[0,99,100,-1,3.5,\"3\",null,7]}}",
                                          times->str, pvals, qvals);
  g_string_free(times, TRUE);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  static const double pe[8] = {0, 500, NAN, NAN, 2, NAN, NAN, NAN};
  static const double qe[8] = {0, 100, NAN, NAN, 50, NAN, NAN, NAN};
  static const int we[8] = {0, 99, -1, -1, -1, -1, -1, 7};
  for (guint i = 0; i < 8; i++) {
    const WxHour *p = hour_at(result_member(result, 0), T0 + (gint64)i * 3600 - 3600);
    if (!isnan(pe[i]) || !isnan(qe[i]))
      g_assert_nonnull(p);
    if (p != NULL) {
      g_assert_true(same_double(p->precip_mm, pe[i]));
      g_assert_true(same_double(p->precip_prob, qe[i]));
    }
    const WxHour *w = hour_at(result_member(result, 0), T0 + (gint64)i * 3600);
    if (we[i] >= 0) {
      g_assert_nonnull(w);
      g_assert_cmpint(w->wmo, ==, we[i]);
    } else if (w != NULL) {
      g_assert_cmpint(w->wmo, ==, -1);
    }
  }
}

static void
test_parse_negative_zero_and_subnormal(void)
{
  g_autofree char *times = g_strdup_printf("[%" G_GINT64_FORMAT "]", T0);
  g_autofree char *text = g_strdup_printf(
      "{\"hourly\":{\"time\":%s,\"temperature_2m\":[-0.0],\"precipitation\":[-0.0],"
      "\"wind_speed_10m\":[-0],\"cloud_cover\":[4.9e-324]}}",
      times);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  const WxHour *h = hour_at(result_member(result, 0), T0);
  g_assert_nonnull(h);
  g_assert_true(same_double(h->temp_c, 0.0)); /* +0, not -0 */
  g_assert_true(same_double(h->wind_kmh, 0.0));
  g_assert_true(same_double(h->cloud_pct, 4.9e-324));
  h = hour_at(result_member(result, 0), T0 - 3600);
  g_assert_nonnull(h);
  g_assert_true(same_double(h->precip_mm, 0.0));
}

static void
test_parse_ragged_arrays(void)
{
  /* Shorter arrays, null elements, longer arrays and mistyped arrays: skipped per element. */
  g_autofree char *times = times_text(4);
  g_autofree char *text = g_strdup_printf(
      "{\"hourly\":{\"time\":%s,\"temperature_2m\":[1,null,3],\"apparent_temperature\":\"x\","
      "\"relative_humidity_2m\":{\"a\":1},\"precipitation\":[0.5,0.5,0.5,0.5,0.5,0.5,0.5],"
      "\"precipitation_probability\":null,\"cloud_cover\":[],\"wind_speed_10m\":[7,8,9,10],"
      "\"wind_gusts_10m\":[1],\"weather_code\":[1,2]}}",
      times);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  guint n;
  const WxHour *h = wx_member_get_hours(result_member(result, 0), &n);
  g_assert_cmpuint(n, ==, 5);
  assert_hour(&h[0], T0 - 3600, NAN, NAN, NAN, 0.5, NAN, NAN, NAN, NAN, -1);
  assert_hour(&h[1], T0, 1, NAN, NAN, 0.5, NAN, NAN, 7, 1, 1);
  assert_hour(&h[2], T0 + 3600, NAN, NAN, NAN, 0.5, NAN, NAN, 8, NAN, 2);
  assert_hour(&h[3], T0 + 7200, 3, NAN, NAN, 0.5, NAN, NAN, 9, NAN, -1);
  assert_hour(&h[4], T0 + 10800, NAN, NAN, NAN, NAN, NAN, NAN, 10, NAN, -1);
  assert_forecast_matches_oracle(text, gfs_only, 1, result);
}

static void
test_parse_dropped_models(void)
{
  /* GFS has data; ECMWF has only nulls / missing arrays; ICON only a weather code. */
  g_autofree char *times = times_text(3);
  g_autofree char *text = g_strdup_printf(
      "{\"hourly\":{\"time\":%s,"
      "\"temperature_2m_gfs_seamless\":[1,2,3],"
      "\"temperature_2m_ecmwf_ifs025\":[null,null,null],\"precipitation_ecmwf_ifs025\":[],"
      "\"weather_code_icon_seamless\":[1,2,3]}}",
      times);
  static const char *const three[] = {"gfs_seamless", "ecmwf_ifs025", "icon_seamless", NULL};
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, three, &error);
  g_assert_no_error(error);
  static const char *const ids[] = {"gfs"};
  assert_result_model_ids(result, ids, 1);
  assert_forecast_matches_oracle(text, three, 3, result);

  /* Everything dropped: not an error of the model, but "no usable forecast data". */
  static const char *const two[] = {"ecmwf_ifs025", "icon_seamless", NULL};
  g_clear_pointer(&result, wx_source_result_free);
  result = forecast(text, two, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_assert_cmpstr(error->message, ==, "no usable forecast data");
  g_clear_error(&error);
  /* An empty hourly object: the time array is the only thing present. */
  g_autofree char *only_time = g_strdup_printf("{\"hourly\":{\"time\":%s}}", times);
  result = forecast(only_time, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_clear_error(&error);
  /* Every stamp unusable: no hours, so no member. */
  result = forecast("{\"hourly\":{\"time\":[1,2,3],\"temperature_2m\":[1,2,3]}}", gfs_only, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
}

static void
test_parse_hostile_bodies(void)
{
  /* Not one JSON object, or not JSON at all: PARSE from the JSON layer. */
  static const char *const syntax_bad[] = {
      "",
      "{",
      "[]",
      "[{}]",
      "null",
      "\"{}\"",
      "{}{}",
      "{\"hourly\":",
      "\xEF\xBB\xBF{\"hourly\":{\"time\":[]}}",
      "{\"hourly\":{\"time\":[]},\"hourly\":{}}",
      "{\"hourly\":{\"time\":[1],\"temperature_2m\":[\xff]}}",
      "{\"hourly\":{\"time\":[1],\"temperature_2m\":[01]}}",
      "{\"hourly\":{\"time\":[1],\"temperature_2m\":[1e]}}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(syntax_bad); i++) {
    g_autoptr(GError) error = NULL;
    g_autoptr(WxSourceResult) result = forecast(syntax_bad[i], miami_models, &error);
    g_assert_null(result);
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  }
  /* An object without a usable hourly "time" array. */
  static const char *const shape_bad[] = {
      "{\"hourly\":\"x\"}",
      "{\"hourly\":[]}",
      "{\"hourly\":null}",
      "{\"hourly\":{}}",
      "{\"hourly\":{\"time\":null}}",
      "{\"hourly\":{\"time\":{}}}",
      "{\"hourly\":{\"time\":\"2026\"}}",
      "{\"hourly\":{\"time\":5}}",
      "{\"other\":{\"time\":[1]}}",
      "{}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(shape_bad); i++) {
    g_autoptr(GError) error = NULL;
    g_autoptr(WxSourceResult) result = forecast(shape_bad[i], miami_models, &error);
    g_assert_null(result);
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
    g_assert_cmpstr(error->message, ==, "response has no hourly time array");
  }
  /* An empty time array is valid and has no data. */
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast("{\"hourly\":{\"time\":[]}}", miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_clear_error(&error);

  /* Deep nesting (> 32 levels), >1024 members, huge numbers of elements: PARSE, no critical. */
  GString *deep = g_string_new("{\"hourly\":{\"time\":[],\"x\":");
  for (guint i = 0; i < 40; i++)
    g_string_append_c(deep, '[');
  for (guint i = 0; i < 40; i++)
    g_string_append_c(deep, ']');
  g_string_append(deep, "}}");
  result = forecast(deep->str, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_string_free(deep, TRUE);
  GString *many = g_string_new("{\"hourly\":{\"time\":[]");
  for (guint i = 0; i < 1100; i++)
    g_string_append_printf(many, ",\"k%u\":1", i);
  g_string_append(many, "}}");
  result = forecast(many->str, miami_models, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_string_free(many, TRUE);
  /* A body above the HTTP cap is refused before it is looked at. */
  guint8 *big = g_malloc0(WX_HTTP_MAX_BODY_BYTES + 1);
  memset(big, ' ', WX_HTTP_MAX_BODY_BYTES + 1);
  result = wx_open_meteo_parse_forecast(big, WX_HTTP_MAX_BODY_BYTES + 1, miami_models, 6, FETCHED, &error);
  g_assert_null(result);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_free(big);
}

static void
test_parse_programmer_errors_and_fetch_time(void)
{
  const char *text = "{\"hourly\":{\"time\":[]}}";
  g_autoptr(GError) error = NULL;
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast",
                  g_assert_null(wx_open_meteo_parse_forecast(NULL, 5, miami_models, 6, FETCHED, &error)));
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast",
                  g_assert_null(wx_open_meteo_parse_forecast(BODY(text), NULL, 1, FETCHED, &error)));
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast",
                  g_assert_null(wx_open_meteo_parse_forecast(BODY(text), miami_models, 0, FETCHED, &error)));
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast",
                  g_assert_null(wx_open_meteo_parse_forecast(BODY(text), miami_models, 9, FETCHED, &error)));
  static const char *const unknown[] = {"gfs_seamless", "bogus_model", NULL};
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast", g_assert_null(forecast(text, unknown, &error)));
  static const char *const uppercase[] = {"GFS_SEAMLESS", NULL};
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast", g_assert_null(forecast(text, uppercase, &error)));
  static const char *const prefix[] = {"gfs", NULL};
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast", g_assert_null(forecast(text, prefix, &error)));
  static const char *const repeated[] = {"gfs_seamless", "ecmwf_ifs025", "gfs_seamless", NULL};
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast", g_assert_null(forecast(text, repeated, &error)));
  const char *with_null[] = {"gfs_seamless", NULL, "icon_seamless"};
  ASSERT_CRITICAL("wx_open_meteo_parse_forecast",
                  g_assert_null(wx_open_meteo_parse_forecast(BODY(text), with_null, 3, FETCHED, &error)));
  g_assert_no_error(error);
  ASSERT_CRITICAL("wx_open_meteo_parse_nowcast", g_assert_null(wx_open_meteo_parse_nowcast(NULL, 3, FETCHED, &error)));
  ASSERT_CRITICAL("wx_open_meteo_parse_geocode", g_assert_null(wx_open_meteo_parse_geocode(NULL, 3, &error)));
  g_assert_no_error(error);

  /* NULL @data with len 0 is allowed: an empty body is a parse error, not a critical. */
  g_assert_null(wx_open_meteo_parse_forecast(NULL, 0, miami_models, 6, FETCHED, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_assert_null(wx_open_meteo_parse_nowcast(NULL, 0, FETCHED, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_assert_null(wx_open_meteo_parse_geocode(NULL, 0, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  /* A NULL @error is fine. */
  g_assert_null(wx_open_meteo_parse_forecast(BODY("x"), miami_models, 6, FETCHED, NULL));
  g_assert_null(wx_open_meteo_parse_nowcast(BODY("x"), FETCHED, NULL));
  g_assert_null(wx_open_meteo_parse_geocode(BODY("x"), NULL));

  /* @fetched_s outside [MIN, MAX) is INVALID_ARG and is checked before the body. */
  static const gint64 bad_times[] = {G_MININT64, -1, 0, WX_TIME_MIN_S - 1, WX_TIME_MAX_S, G_MAXINT64};
  for (guint i = 0; i < G_N_ELEMENTS(bad_times); i++) {
    g_assert_null(wx_open_meteo_parse_forecast(BODY("not json"), miami_models, 6, bad_times[i], &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpstr(error->message, ==, "invalid fetch time");
    g_clear_error(&error);
    g_assert_null(wx_open_meteo_parse_nowcast(BODY("not json"), bad_times[i], &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_clear_error(&error);
  }
  g_autoptr(WxSourceResult) lo = wx_open_meteo_parse_forecast(
      BODY("{\"hourly\":{\"time\":[1791763200],\"temperature_2m\":[1]}}"), gfs_only, 1, WX_TIME_MIN_S, &error);
  g_assert_no_error(error);
  g_assert_nonnull(lo);
  g_autoptr(WxSourceResult) hi = wx_open_meteo_parse_forecast(
      BODY("{\"hourly\":{\"time\":[1791763200],\"temperature_2m\":[1]}}"), gfs_only, 1, WX_TIME_MAX_S - 1,
      &error);
  g_assert_no_error(error);
  g_assert_nonnull(hi);
  g_assert_cmpint(wx_member_get_fetched_s(result_member(hi, 0)), ==, WX_TIME_MAX_S - 1);
}

static void
test_parse_guard_pages(void)
{
  /* Every parser reads exactly @len bytes: put the body right before a PROT_NONE page. */
  const char *forecast_text = fixture_text("forecast_miami_multi.json", NULL);
  const char *nowcast_text = fixture_text("nowcast_miami.json", NULL);
  const char *geocode_text = fixture_text("geocode_miami.json", NULL);
  const char *texts[] = {forecast_text, nowcast_text, geocode_text, "{\"hourly\":{\"time\":[]}}", "{}", "x"};
  for (guint k = 0; k < G_N_ELEMENTS(texts); k++) {
    gsize len = strlen(texts[k]);
    Guarded g = guard_new(len);
    memcpy(g.data, texts[k], len);
    g_autoptr(GError) error = NULL;
    WxSourceResult *r = wx_open_meteo_parse_forecast((guint8 *)g.data, len, miami_models, 6, FETCHED, &error);
    wx_source_result_free(r);
    g_clear_error(&error);
    WxMember *m = wx_open_meteo_parse_nowcast((guint8 *)g.data, len, FETCHED, &error);
    if (m != NULL)
      wx_member_unref(m);
    g_clear_error(&error);
    GPtrArray *p = wx_open_meteo_parse_geocode((guint8 *)g.data, len, &error);
    if (p != NULL)
      g_ptr_array_unref(p);
    g_clear_error(&error);
    /* and truncated at every length class: a cut body is a parse error, never a read overrun */
    for (gsize cut = 0; cut < len && cut < 64; cut++) {
      Guarded c = guard_new(cut);
      memcpy(c.data, texts[k], cut);
      r = wx_open_meteo_parse_forecast((guint8 *)c.data, cut, miami_models, 6, FETCHED, &error);
      g_assert_null(r);
      g_clear_error(&error);
      guard_free(c);
    }
    guard_free(g);
  }
}

/* ------------------------------------------------------------------------ */
/* Nowcast parser                                                           */
/* ------------------------------------------------------------------------ */

static WxMember *
nowcast(const char *text, GError **error)
{
  return wx_open_meteo_parse_nowcast(BODY(text), FETCHED, error);
}

static void
test_parse_nowcast_semantics(void)
{
  g_autoptr(GError) error = NULL;
  const gint64 b = 1791832500; /* a multiple of 900 */
  g_autofree char *text = g_strdup_printf(
      "{\"minutely_15\":{\"time\":[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT
      ",%" G_GINT64_FORMAT "],\"precipitation\":[0.25,1.5,null,\"2\",500]}}",
      b, b + 900, b + 1800, b + 2700, b + 3600);
  g_autoptr(WxMember) member = nowcast(text, &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  guint nq;
  const WxQuarter *q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 3);
  g_assert_cmpint(q[0].t_s, ==, b - 900);
  g_assert_true(same_double(q[0].precip_mm, 0.25));
  g_assert_cmpint(q[1].t_s, ==, b);
  g_assert_true(same_double(q[1].precip_mm, 1.5));
  g_assert_cmpint(q[2].t_s, ==, b + 2700);
  g_assert_true(same_double(q[2].precip_mm, 500.0));

  /* Skipped entries: misaligned, duplicate, descending, out of range, mistyped, bad amounts. */
  g_autofree char *odd = g_strdup_printf(
      "{\"minutely_15\":{\"time\":[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT
      ",%" G_GINT64_FORMAT ",\"x\",null,1e30,%" G_GINT64_FORMAT ".5,%" G_GINT64_FORMAT "],"
      "\"precipitation\":[1,1,1,1,1,1,1,1,1,0.5,7]}}",
      b, b + 450, b, b - 900, b + 900, b + 1800, b + 2700);
  g_clear_pointer(&member, wx_member_unref);
  member = nowcast(odd, &error);
  g_assert_no_error(error);
  q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 3);
  g_assert_cmpint(q[0].t_s, ==, b - 900);
  g_assert_cmpint(q[1].t_s, ==, b);
  g_assert_cmpint(q[2].t_s, ==, b + 1800); /* the stamp b + 2700 at index 9: amount 0.5 */
  g_assert_true(same_double(q[2].precip_mm, 0.5));
  /* negative, too large, infinite amounts: skipped (a quarter has no NAN) */
  g_autofree char *amounts = g_strdup_printf(
      "{\"minutely_15\":{\"time\":[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT
      "],\"precipitation\":[-0.01,500.01,1e999,-0.0]}}",
      b, b + 900, b + 1800, b + 2700);
  g_clear_pointer(&member, wx_member_unref);
  member = nowcast(amounts, &error);
  g_assert_no_error(error);
  q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 1);
  g_assert_true(same_double(q[0].precip_mm, 0.0)); /* -0.0 is stored as +0 */

  /* Shorter amounts array than time. */
  g_autofree char *shorter = g_strdup_printf(
      "{\"minutely_15\":{\"time\":[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "],\"precipitation\":[3]}}", b, b + 900);
  g_clear_pointer(&member, wx_member_unref);
  member = nowcast(shorter, &error);
  g_assert_no_error(error);
  q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 1);
  g_assert_cmpint(q[0].t_s, ==, b - 900);
  g_clear_pointer(&member, wx_member_unref);

  /* Epoch edges: MIN itself would be stored at MIN - 900 (refused by the member), MIN + 900 is fine. */
  g_autofree char *edge = g_strdup_printf(
      "{\"minutely_15\":{\"time\":[%" G_GINT64_FORMAT ",%" G_GINT64_FORMAT "],\"precipitation\":[1,2]}}",
      (gint64)WX_TIME_MIN_S, (gint64)WX_TIME_MIN_S + 900);
  member = nowcast(edge, &error);
  g_assert_no_error(error);
  q = wx_member_get_quarters(member, &nq);
  g_assert_cmpuint(nq, ==, 1);
  g_assert_cmpint(q[0].t_s, ==, (gint64)WX_TIME_MIN_S);
  g_clear_pointer(&member, wx_member_unref);
}

static void
test_parse_nowcast_errors(void)
{
  struct {
    const char *text;
    int code;
    const char *message;
  } cases[] = {
      {"", WX_ERROR_PARSE, NULL},
      {"[]", WX_ERROR_PARSE, NULL},
      {"{", WX_ERROR_PARSE, NULL},
      {"{}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":null}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":[]}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":{\"time\":[1]}}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":{\"precipitation\":[1]}}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":{\"time\":\"x\",\"precipitation\":[1]}}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":{\"time\":[1],\"precipitation\":{}}}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"minutely_15\":{\"time\":[],\"precipitation\":[]}}", WX_ERROR_NOT_FOUND, "no usable nowcast data"},
      {"{\"minutely_15\":{\"time\":[1791832500],\"precipitation\":[null]}}", WX_ERROR_NOT_FOUND, "no usable nowcast data"},
      {"{\"minutely_15\":{\"time\":[1791832501],\"precipitation\":[1]}}", WX_ERROR_NOT_FOUND, "no usable nowcast data"},
      {"{\"minutely_15_x\":{\"time\":[1791832500],\"precipitation_hourly\":[1]}}", WX_ERROR_PARSE, "response has no 15-minute data"},
      {"{\"error\":true,\"reason\":\"nope\"}", WX_ERROR_HTTP, "Open-Meteo reported an error: nope"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) member = nowcast(cases[i].text, &error);
    g_assert_null(member);
    g_assert_error(error, WX_ERROR, cases[i].code);
    if (cases[i].message != NULL)
      g_assert_cmpstr(error->message, ==, cases[i].message);
  }
  /* The count limit: WX_MEMBER_MAX_QUARTERS time entries are accepted, one more is refused. */
  for (guint k = 0; k < 2; k++) {
    guint n = WX_MEMBER_MAX_QUARTERS + k;
    GString *s = g_string_new("{\"minutely_15\":{\"time\":[");
    for (guint i = 0; i < n; i++)
      g_string_append_printf(s, "%s%" G_GINT64_FORMAT, i ? "," : "", (gint64)1791832500 + (gint64)i * 900);
    g_string_append(s, "],\"precipitation\":[");
    for (guint i = 0; i < n; i++)
      g_string_append_printf(s, "%s0.1", i ? "," : "");
    g_string_append(s, "]}}");
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) member = nowcast(s->str, &error);
    if (k == 0) {
      g_assert_no_error(error);
      guint nq;
      (void)wx_member_get_quarters(member, &nq);
      g_assert_cmpuint(nq, ==, WX_MEMBER_MAX_QUARTERS);
    } else {
      g_assert_null(member);
      g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
      g_assert_cmpstr(error->message, ==, "response has too many time steps");
    }
    g_string_free(s, TRUE);
  }
}

/* ------------------------------------------------------------------------ */
/* Geocode parser                                                           */
/* ------------------------------------------------------------------------ */

static GPtrArray *
geocode(const char *text, GError **error)
{
  return wx_open_meteo_parse_geocode(BODY(text), error);
}

static void
test_parse_geocode_shapes(void)
{
  g_autoptr(GError) error = NULL;
  /* results absent, null, empty: an empty array. */
  static const char *const empty[] = {"{}", "{\"generationtime_ms\":0.5}", "{\"results\":null}", "{\"results\":[]}"};
  for (guint i = 0; i < G_N_ELEMENTS(empty); i++) {
    g_autoptr(GPtrArray) places = geocode(empty[i], &error);
    g_assert_no_error(error);
    g_assert_nonnull(places);
    g_assert_cmpuint(places->len, ==, 0);
  }
  /* Another type: parse error. */
  static const char *const wrong[] = {"{\"results\":{}}", "{\"results\":\"x\"}", "{\"results\":5}",
                                      "{\"results\":true}", "[]", "", "{\"results\":["};
  for (guint i = 0; i < G_N_ELEMENTS(wrong); i++) {
    g_autoptr(GPtrArray) places = geocode(wrong[i], &error);
    g_assert_null(places);
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
    g_clear_error(&error);
  }
  /* Hits that are not objects or lack required members are dropped; valid ones keep their order. */
  g_autoptr(GPtrArray) places = geocode(
      "{\"results\":[1,null,\"x\",[],{},{\"name\":\"A\"},{\"name\":\"A\",\"latitude\":1},"
      "{\"name\":\"A\",\"latitude\":\"1\",\"longitude\":2},{\"latitude\":1,\"longitude\":2},"
      "{\"name\":5,\"latitude\":1,\"longitude\":2},{\"name\":\"Ok1\",\"latitude\":1,\"longitude\":2},"
      "{\"name\":\"Ok2\",\"latitude\":-90,\"longitude\":180},"
      "{\"name\":\"BadLat\",\"latitude\":90.0001,\"longitude\":0},{\"name\":\"BadLon\",\"latitude\":0,\"longitude\":-180.1},"
      "{\"name\":\"Inf\",\"latitude\":1e999,\"longitude\":0},{\"name\":\"Ok3\",\"latitude\":90,\"longitude\":-180}]}",
      &error);
  g_assert_no_error(error);
  g_assert_cmpuint(places->len, ==, 3);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->name, ==, "Ok1");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 1))->name, ==, "Ok2");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 2))->name, ==, "Ok3");
  const WxPlace *ok1 = g_ptr_array_index(places, 0);
  g_assert_cmpstr(ok1->admin1, ==, "");
  g_assert_cmpstr(ok1->country, ==, "");
  g_assert_cmpstr(ok1->country_code, ==, "");
  g_assert_cmpstr(ok1->timezone, ==, "");
}

static void
test_parse_geocode_sanitising(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) places = geocode(
      "{\"results\":["
      "{\"name\":\"Mi\\u0001a\\u202emi\\n\",\"latitude\":1,\"longitude\":2,\"admin1\":\"Fl\\u0007or\\u2066ida\","
      "\"country\":\"United\\u0000\\u202aS\"},"          /* \u0000 is refused by the JSON parser: whole body */
      "{\"name\":\"x\"}]}",
      &error);
  g_assert_null(places);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);

  places = geocode(
      "{\"results\":["
      "{\"name\":\"Mi\\u0001a\\u202emi\\n\",\"latitude\":1,\"longitude\":2,\"admin1\":\"Fl\\u0007or\\u2066ida\","
      "\"country\":\"Un\\u200eited\\u2029 States\",\"country_code\":\"US\",\"timezone\":\"America/New_York\"},"
      "{\"name\":\"\\u0001\\u202e\",\"latitude\":1,\"longitude\":2},"          /* empty after cleaning */
      "{\"name\":\"   \",\"latitude\":1,\"longitude\":2},"                   /* blank */
      "{\"name\":\"\",\"latitude\":1,\"longitude\":2},"
      "{\"name\":\"CC lower\",\"latitude\":1,\"longitude\":2,\"country_code\":\"us\"},"
      "{\"name\":\"CC three\",\"latitude\":1,\"longitude\":2,\"country_code\":\"USA\"},"
      "{\"name\":\"CC digits\",\"latitude\":1,\"longitude\":2,\"country_code\":\"1A\"},"
      "{\"name\":\"CC type\",\"latitude\":1,\"longitude\":2,\"country_code\":5},"
      "{\"name\":\"CC ok\",\"latitude\":1,\"longitude\":2,\"country_code\":\"ZZ\"},"
      "{\"name\":\"TZ abs\",\"latitude\":1,\"longitude\":2,\"timezone\":\"/etc/passwd\"},"
      "{\"name\":\"TZ dots\",\"latitude\":1,\"longitude\":2,\"timezone\":\"a/../b\"},"
      "{\"name\":\"TZ space\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Europe/New York\"},"
      "{\"name\":\"TZ long\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Europe/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"},"
      "{\"name\":\"TZ type\",\"latitude\":1,\"longitude\":2,\"timezone\":7},"
      "{\"name\":\"TZ utc\",\"latitude\":1,\"longitude\":2,\"timezone\":\"UTC\"},"
      "{\"name\":\"TZ plus\",\"latitude\":1,\"longitude\":2,\"timezone\":\"Etc/GMT+5\"}"
      "]}",
      &error);
  g_assert_no_error(error);
  g_assert_nonnull(places);
  static const struct {
    const char *name, *admin1, *country, *code, *tz;
  } expect[] = {
      {"Miami", "Florida", "United States", "US", "America/New_York"},
      {"CC lower", "", "", "", ""},
      {"CC three", "", "", "", ""},
      {"CC digits", "", "", "", ""},
      {"CC type", "", "", "", ""},
      {"CC ok", "", "", "ZZ", ""},
      {"TZ abs", "", "", "", ""},
      {"TZ dots", "", "", "", ""},
      {"TZ space", "", "", "", ""},
      {"TZ long", "", "", "", ""},
      {"TZ type", "", "", "", ""},
      {"TZ utc", "", "", "", "UTC"},
      {"TZ plus", "", "", "", "Etc/GMT+5"},
  };
  g_assert_cmpuint(places->len, ==, G_N_ELEMENTS(expect));
  for (guint i = 0; i < G_N_ELEMENTS(expect); i++) {
    const WxPlace *p = g_ptr_array_index(places, i);
    if (i == 0) {
      g_assert_cmpstr(p->name, ==, "Miami");
      g_assert_cmpstr(p->admin1, ==, "Florida");
      g_assert_cmpstr(p->country, ==, "United States");
    } else {
      g_assert_cmpstr(p->name, ==, expect[i].name);
      g_assert_cmpstr(p->admin1, ==, expect[i].admin1);
      g_assert_cmpstr(p->country, ==, expect[i].country);
    }
    g_assert_cmpstr(p->country_code, ==, expect[i].code);
    g_assert_cmpstr(p->timezone, ==, expect[i].tz);
  }
}

static void
test_parse_geocode_optional_text_cleared(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) places = geocode(
      "{\"results\":["
      "{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"admin1\":\" \"},"
      "{\"name\":\"B\",\"latitude\":1,\"longitude\":2,\"country\":\"\\u3000\"},"
      "{\"name\":\"C\",\"latitude\":1,\"longitude\":2,\"admin1\":\"\\u00a0\",\"country\":\"\\u3000\"},"
      "{\"name\":\"D\",\"latitude\":1,\"longitude\":2,\"admin1\":\"\\u0001\",\"country\":\" X \"}"
      "]}",
      &error);
  g_assert_no_error(error);
  g_assert_nonnull(places);
  g_assert_cmpuint(places->len, ==, 4);
  static const char *const names[] = {"A", "B", "C", "D"};
  static const char *const countries[] = {"", "", "", " X "};
  for (guint i = 0; i < 4; i++) {
    const WxPlace *p = g_ptr_array_index(places, i);
    g_assert_cmpstr(p->name, ==, names[i]);
    g_assert_cmpstr(p->admin1, ==, "");
    g_assert_cmpstr(p->country, ==, countries[i]);
  }
}

static void
test_parse_geocode_limits(void)
{
  g_autoptr(GError) error = NULL;
  /* More than WX_GEOCODER_MAX_HITS valid hits: the first 20, in body order. */
  GString *s = g_string_new("{\"results\":[");
  for (guint i = 0; i < 45; i++)
    g_string_append_printf(s, "%s{\"name\":\"P%u\",\"latitude\":%u,\"longitude\":%u}", i ? "," : "", i, i % 80, i);
  g_string_append(s, "]}");
  g_autoptr(GPtrArray) places = geocode(s->str, &error);
  g_string_free(s, TRUE);
  g_assert_no_error(error);
  g_assert_cmpuint(places->len, ==, WX_GEOCODER_MAX_HITS);
  g_assert_cmpuint(WX_GEOCODER_MAX_HITS, ==, 20);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->name, ==, "P0");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 19))->name, ==, "P19");
  /* Invalid hits do not count against the limit. */
  s = g_string_new("{\"results\":[");
  for (guint i = 0; i < 30; i++)
    g_string_append_printf(s, "%s{\"name\":\"B%u\",\"latitude\":999,\"longitude\":0}", i ? "," : "", i);
  for (guint i = 0; i < 25; i++)
    g_string_append_printf(s, ",{\"name\":\"G%u\",\"latitude\":1,\"longitude\":1}", i);
  g_string_append(s, "]}");
  g_autoptr(GPtrArray) mixed = geocode(s->str, &error);
  g_string_free(s, TRUE);
  g_assert_no_error(error);
  g_assert_cmpuint(mixed->len, ==, 20);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(mixed, 0))->name, ==, "G0");

  /* Over-long names are cut to WX_PLACE_NAME_MAX bytes on a character boundary and kept. */
  g_autofree char *longname = g_strnfill(300, 'a');
  GString *w = g_string_new(NULL);
  for (guint i = 0; i < 200; i++)
    g_string_append(w, "\xc3\xa9"); /* 400 bytes of e-acute */
  g_autofree char *text = g_strdup_printf(
      "{\"results\":[{\"name\":\"%s\",\"latitude\":1,\"longitude\":2,\"admin1\":\"%s\"}]}", longname, w->str);
  g_string_free(w, TRUE);
  g_autoptr(GPtrArray) cut = geocode(text, &error);
  g_assert_no_error(error);
  g_assert_cmpuint(cut->len, ==, 1);
  const WxPlace *p = g_ptr_array_index(cut, 0);
  g_assert_cmpuint(strlen(p->name), ==, WX_PLACE_NAME_MAX);
  g_assert_cmpuint(strlen(p->admin1), ==, WX_PLACE_NAME_MAX);
  g_assert_true(g_utf8_validate(p->admin1, -1, NULL));
  /* Exactly the byte limit passes unchanged. */
  g_autofree char *at = g_strnfill(WX_PLACE_NAME_MAX, 'b');
  g_autofree char *text_at = g_strdup_printf("{\"results\":[{\"name\":\"%s\",\"latitude\":1,\"longitude\":2}]}", at);
  g_autoptr(GPtrArray) exact = geocode(text_at, &error);
  g_assert_no_error(error);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(exact, 0))->name, ==, at);
}

static void
test_parse_geocode_hostile(void)
{
  static const char *const bad[] = {
      "{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"name\":\"B\"}]}",  /* duplicate member */
      "{\"results\":[{\"name\":\"\xff\",\"latitude\":1,\"longitude\":2}]}",                /* invalid UTF-8 */
      "{\"results\":[{\"name\":\"\\ud800\",\"latitude\":1,\"longitude\":2}]}",             /* lone surrogate */
      "{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2},]}",
      "\xEF\xBB\xBF{}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autoptr(GError) error = NULL;
    g_autoptr(GPtrArray) places = geocode(bad[i], &error);
    g_assert_null(places);
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  }
  /* Deep nesting inside a hit is refused by the JSON layer. */
  GString *deep = g_string_new("{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"x\":");
  for (guint i = 0; i < 40; i++)
    g_string_append_c(deep, '[');
  for (guint i = 0; i < 40; i++)
    g_string_append_c(deep, ']');
  g_string_append(deep, "}]}");
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) places = geocode(deep->str, &error);
  g_string_free(deep, TRUE);
  g_assert_null(places);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  /* Format-string and markup text is data: kept verbatim in the name. */
  g_autoptr(GPtrArray) fmt = geocode(
      "{\"results\":[{\"name\":\"%s%n<b>&amp;\",\"latitude\":1,\"longitude\":2,\"country\":\"%d\"}]}", &error);
  g_assert_no_error(error);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(fmt, 0))->name, ==, "%s%n<b>&amp;");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(fmt, 0))->country, ==, "%d");
}

/* ------------------------------------------------------------------------ */
/* Differential fuzz of the forecast parser against the oracle              */
/* ------------------------------------------------------------------------ */

static void
rand_number_text(GRand *rng, GString *s, double lo, double hi)
{
  gint32 k = g_rand_int_range(rng, 0, 100);
  char buf[G_ASCII_DTOSTR_BUF_SIZE];
  if (k < 62) { /* in range */
    double v = lo + (hi - lo) * g_rand_double(rng);
    if (g_rand_boolean(rng))
      g_string_append_printf(s, "%d", (int)v);
    else
      g_string_append(s, g_ascii_formatd(buf, sizeof buf, "%.17g", v));
  } else if (k < 68) {
    g_string_append(s, "null");
  } else if (k < 72) {
    g_string_append(s, g_ascii_formatd(buf, sizeof buf, "%.17g", hi + 1.0 + g_rand_double(rng) * 1000));
  } else if (k < 76) {
    g_string_append(s, g_ascii_formatd(buf, sizeof buf, "%.17g", lo - 1.0 - g_rand_double(rng) * 1000));
  } else if (k < 79) {
    g_string_append(s, "\"12\"");
  } else if (k < 81) {
    g_string_append(s, g_rand_boolean(rng) ? "true" : "false");
  } else if (k < 83) {
    g_string_append(s, "-0.0");
  } else if (k < 85) {
    g_string_append(s, g_rand_boolean(rng) ? "1e999" : "-1e999");
  } else if (k < 87) {
    g_string_append(s, g_rand_boolean(rng) ? "{\"a\":1}" : "[1,2]");
  } else if (k < 90) {
    g_string_append(s, g_ascii_formatd(buf, sizeof buf, "%.17g", g_rand_boolean(rng) ? lo : hi));
  } else if (k < 92) {
    g_string_append(s, "5e-324");
  } else if (k < 94) {
    g_string_append(s, g_rand_boolean(rng) ? "9223372036854775807" : "-9223372036854775808");
  } else {
    g_string_append_printf(s, "%d", g_rand_int_range(rng, (gint32)lo, (gint32)hi + 1));
  }
}

static void
rand_time_text(GRand *rng, GString *s, gint64 *t)
{
  gint32 k = g_rand_int_range(rng, 0, 100);
  if (k < 72) {
    *t += 3600 * (g_rand_int_range(rng, 0, 12) == 0 ? g_rand_int_range(rng, 2, 6) : 1);
    g_string_append_printf(s, "%" G_GINT64_FORMAT, *t);
  } else if (k < 77) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, *t); /* duplicate */
  } else if (k < 81) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, *t - 3600 * g_rand_int_range(rng, 1, 5)); /* descending */
  } else if (k < 85) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, *t + 1800); /* misaligned */
  } else if (k < 87) {
    g_string_append(s, "\"x\"");
  } else if (k < 89) {
    g_string_append(s, "null");
  } else if (k < 91) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT ".5", *t + 3600);
  } else if (k < 93) {
    g_string_append(s, g_rand_boolean(rng) ? "1e30" : "-5");
  } else if (k < 95) {
    g_string_append(s, g_rand_boolean(rng) ? "true" : "[]");
  } else if (k < 97) {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, (gint64)WX_TIME_MIN_S + 3600 * g_rand_int_range(rng, -1, 2));
  } else {
    g_string_append_printf(s, "%" G_GINT64_FORMAT, (gint64)WX_TIME_MAX_S - 3600 * g_rand_int_range(rng, 0, 3));
  }
}

static char *
random_body(GRand *rng, const char **models, guint *n_models)
{
  static const char *const all[] = {"ncep_hrrr_conus", "ncep_nbm_conus", "gfs_seamless", "ecmwf_ifs025",
                                    "icon_seamless",   "gem_seamless",   "ukmo_seamless", "meteofrance_seamless"};
  guint n = (guint)g_rand_int_range(rng, 1, 9);
  guint order[8] = {0, 1, 2, 3, 4, 5, 6, 7};
  for (guint i = 7; i > 0; i--) {
    guint j = (guint)g_rand_int_range(rng, 0, (gint32)i + 1);
    guint tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  for (guint i = 0; i < n; i++)
    models[i] = all[order[i]];
  *n_models = n;
  guint n_t = (guint)g_rand_int_range(rng, 0, 40);
  gint64 t = T0 + 3600 * g_rand_int_range(rng, -3, 400);
  if (g_rand_int_range(rng, 0, 30) == 0)
    t = (gint64)WX_TIME_MIN_S - 3600;
  GString *s = g_string_new("{\"hourly\":{\"time\":[");
  for (guint i = 0; i < n_t; i++) {
    if (i)
      g_string_append_c(s, ',');
    rand_time_text(rng, s, &t);
  }
  g_string_append_c(s, ']');
  static const struct {
    const char *key;
    double lo, hi;
  } vars[] = {{"temperature_2m", -100, 70},   {"apparent_temperature", -100, 70}, {"relative_humidity_2m", 0, 100},
              {"precipitation", 0, 500},      {"precipitation_probability", 0, 100}, {"cloud_cover", 0, 100},
              {"wind_speed_10m", 0, 500},     {"wind_gusts_10m", 0, 500},         {"weather_code", 0, 99}};
  for (guint m = 0; m < n; m++) {
    for (guint v = 0; v < G_N_ELEMENTS(vars); v++) {
      gint32 shape = g_rand_int_range(rng, 0, 100);
      if (shape < 12)
        continue; /* missing array */
      if (g_rand_int_range(rng, 0, 6) == 0 && m % 2 == 1)
        continue; /* whole models tend to drop */
      g_string_append_printf(s, ",\"%s%s%s\":", vars[v].key, n > 1 ? "_" : "", n > 1 ? models[m] : "");
      if (shape < 15) {
        g_string_append(s, shape < 13 ? "\"x\"" : (shape < 14 ? "null" : "{}"));
        continue;
      }
      guint len = n_t;
      if (shape < 35) {
        gint32 delta = (gint32)n_t + g_rand_int_range(rng, -3, 3);
        len = delta < 0 ? 0 : (guint)delta;
      }
      g_string_append_c(s, '[');
      for (guint i = 0; i < len; i++) {
        if (i)
          g_string_append_c(s, ',');
        rand_number_text(rng, s, vars[v].lo, vars[v].hi);
      }
      g_string_append_c(s, ']');
    }
  }
  g_string_append(s, "}}");
  return g_string_free(s, FALSE);
}

static guint
fuzz_iterations(guint fallback)
{
  const char *env = g_getenv("WX_OM_FUZZ_N");
  return env != NULL ? (guint)g_ascii_strtoull(env, NULL, 10) : fallback;
}

static void
test_parse_differential_fuzz(void)
{
  GRand *rng = g_rand_new_with_seed(0x0e17e0);
  guint n_iter = fuzz_iterations(4000);
  guint ok = 0, empty = 0;
  for (guint iter = 0; iter < n_iter; iter++) {
    const char *models[8];
    guint n_models;
    g_autofree char *text = random_body(rng, models, &n_models);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxSourceResult) result = wx_open_meteo_parse_forecast(BODY(text), models, n_models, FETCHED, &error);

    /* The oracle needs a parseable document; the generator always makes one. */
    g_autoptr(JsonParser) parser = json_parser_new();
    if (!json_parser_load_from_data(parser, text, -1, NULL)) {
      g_assert_null(result);
      g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
      continue;
    }
    JsonObject *hourly = json_object_get_object_member(json_node_get_object(json_parser_get_root(parser)), "hourly");
    guint expected_members = 0;
    for (guint m = 0; m < n_models; m++) {
      GArray *exp = oracle_hours(hourly, models[m], n_models > 1);
      if (exp != NULL) {
        expected_members++;
        g_array_unref(exp);
      }
    }
    if (expected_members == 0) {
      g_assert_null(result);
      g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
      empty++;
      continue;
    }
    g_assert_no_error(error);
    g_assert_nonnull(result);
    assert_forecast_matches_oracle(text, models, n_models, result);
    ok++;
  }
  if (n_iter >= 1000) {
    g_assert_cmpuint(ok, >, n_iter / 4);
    g_assert_cmpuint(empty, >, 0);
  }
  g_rand_free(rng);
}

/* Random byte mutations of the real fixtures: always a WX_ERROR or a well-formed result. */
static void
test_parse_mutation_fuzz(void)
{
  GRand *rng = g_rand_new_with_seed(0xfeed);
  const char *names[] = {"forecast_miami_multi.json", "nowcast_miami.json", "geocode_miami.json"};
  guint n_iter = fuzz_iterations(4000) / 2;
  for (guint iter = 0; iter < n_iter; iter++) {
    guint which = (guint)g_rand_int_range(rng, 0, 3);
    gsize len;
    const char *text = fixture_text(names[which], &len);
    g_autofree guint8 *copy = g_memdup2(text, len);
    gsize out_len = len;
    guint edits = (guint)g_rand_int_range(rng, 1, 6);
    for (guint e = 0; e < edits; e++) {
      gsize pos = (gsize)g_rand_int_range(rng, 0, (gint32)out_len);
      switch (g_rand_int_range(rng, 0, 4)) {
      case 0:
        copy[pos] = (guint8)g_rand_int_range(rng, 0, 256);
        break;
      case 1:
        copy[pos] = (guint8)"{}[],:\"-0.e9"[g_rand_int_range(rng, 0, 12)];
        break;
      case 2:
        out_len = pos; /* truncation */
        if (out_len == 0)
          out_len = 1;
        break;
      default:
        copy[pos] = ' ';
        break;
      }
    }
    g_autoptr(GError) error = NULL;
    if (which == 0) {
      g_autoptr(WxSourceResult) r = wx_open_meteo_parse_forecast(copy, out_len, miami_models, 6, FETCHED, &error);
      if (r == NULL) {
        g_assert_true(error->domain == WX_ERROR);
      } else {
        for (guint m = 0; m < r->members->len; m++) {
          guint n;
          const WxHour *h = wx_member_get_hours(result_member(r, m), &n);
          for (guint i = 0; i < n; i++) {
            g_assert_cmpint(h[i].t_s % 3600, ==, 0);
            g_assert_true(isnan(h[i].temp_c) || (h[i].temp_c >= -100 && h[i].temp_c <= 70));
            g_assert_true(isnan(h[i].precip_mm) || (h[i].precip_mm >= 0 && h[i].precip_mm <= 500));
            g_assert_true(h[i].wmo >= -1 && h[i].wmo <= 99);
          }
        }
      }
    } else if (which == 1) {
      g_autoptr(WxMember) m = wx_open_meteo_parse_nowcast(copy, out_len, FETCHED, &error);
      g_assert_true((m != NULL) != (error != NULL));
    } else {
      g_autoptr(GPtrArray) p = wx_open_meteo_parse_geocode(copy, out_len, &error);
      g_assert_true((p != NULL) != (error != NULL));
      if (p != NULL)
        g_assert_cmpuint(p->len, <=, WX_GEOCODER_MAX_HITS);
    }
  }
  g_rand_free(rng);
}

/* ------------------------------------------------------------------------ */
/* Part 2: provider and geocoder against a loopback fake server             */
/* ------------------------------------------------------------------------ */

#define UA "weather-app/0.1 (github.com/wtp128pro/weather)"

typedef enum {
  R_REPLY, /* status + headers + body (optionally gzip), then close */
  R_HANG,  /* read the request, never answer */
  R_CLOSE, /* close without answering */
  R_CUT    /* declare more body than is sent, then close */
} ReplyKind;

typedef struct {
  ReplyKind kind;
  guint status;
  const char *body; /* borrowed; NULL: a forecast body synthesised from the models of the request */
  gboolean gzip;
  guint delay_ms;
} Reply;

/* What the fake answers: request A (forecast), request B (minutely_15), the search. */
typedef struct {
  Reply a, b, geo;
  guint a_first_fail; /* the first @a_first_fail attempts of request A answer 503 at once */
} Script;

typedef struct Fake Fake;

typedef struct {
  Fake *fake;
  GSocketConnection *connection;
  GString *request;
  guint8 buffer[2048];
  GBytes *pending;
  gboolean is_a_ok; /* this connection carries the answer that A succeeds with (not a refused attempt) */
} Conn;

struct Fake {
  GSocketService *service;
  guint port;
  Script script;
  guint requests;
  GPtrArray *paths;
  GPtrArray *heads;
  GPtrArray *held;
  GHashTable *conns;
  guint a_seen;      /* attempts of request A so far */
  gint64 a_answer_us; /* monotonic time at which the successful answer of A was written */
};

static void conn_read(Conn *conn);

static void
conn_free(Conn *conn)
{
  g_hash_table_remove(conn->fake->conns, conn);
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
  g_autoptr(GError) error = NULL;
  gsize written;
  (void)g_output_stream_write_all_finish(G_OUTPUT_STREAM(source), result, &written, &error);
  conn_free(user_data);
}

static void
respond_bytes(Conn *conn, GBytes *bytes)
{
  GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn->connection));
  gsize len;
  const void *data = g_bytes_get_data(bytes, &len);
  g_object_set_data_full(G_OBJECT(out), "wx-test-bytes", g_bytes_ref(bytes), (GDestroyNotify)g_bytes_unref);
  g_output_stream_write_all_async(out, data, len, G_PRIORITY_DEFAULT, NULL, write_done, conn);
}

static gboolean
on_delayed_answer(gpointer user_data)
{
  Conn *conn = user_data;
  GBytes *bytes = g_steal_pointer(&conn->pending);
  if (conn->is_a_ok)
    conn->fake->a_answer_us = g_get_monotonic_time();
  respond_bytes(conn, bytes);
  g_bytes_unref(bytes);
  return G_SOURCE_REMOVE;
}

static GBytes *
gzip_of(const char *body)
{
  if (body == NULL)
    g_error("gzip_of: no body");
  g_autoptr(GConverter) gz = G_CONVERTER(g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, -1));
  g_autoptr(GOutputStream) mem = g_memory_output_stream_new_resizable();
  g_autoptr(GOutputStream) zout = g_converter_output_stream_new(mem, gz);
  g_assert_true(g_output_stream_write_all(zout, body, strlen(body), NULL, NULL, NULL));
  g_assert_true(g_output_stream_close(zout, NULL, NULL));
  return g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(mem));
}

/* A forecast body with 4 stamps for every model named in the "models=" parameter of @path. */
static char *
synth_body(const char *path)
{
  const char *m = strstr(path, "models=");
  g_assert_nonnull(m);
  m += strlen("models=");
  const char *end = strchr(m, '&');
  g_assert_nonnull(end);
  g_autofree char *list = g_strndup(m, (gsize)(end - m));
  g_auto(GStrv) names = g_strsplit(list, ",", -1);
  guint n = g_strv_length(names);
  static const struct {
    const char *key;
    double base;
  } vars[] = {{"temperature_2m", 20}, {"apparent_temperature", 21}, {"relative_humidity_2m", 60},
              {"precipitation", 0.5}, {"precipitation_probability", 30}, {"cloud_cover", 40},
              {"wind_speed_10m", 10}, {"wind_gusts_10m", 15}, {"weather_code", 3}};
  GString *s = g_string_new("{\"hourly\":{\"time\":[");
  for (guint i = 0; i < 4; i++)
    g_string_append_printf(s, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 3600);
  g_string_append_c(s, ']');
  for (guint mi = 0; mi < n; mi++)
    for (guint v = 0; v < G_N_ELEMENTS(vars); v++) {
      g_string_append_printf(s, ",\"%s%s%s\":[", vars[v].key, n > 1 ? "_" : "", n > 1 ? names[mi] : "");
      for (guint i = 0; i < 4; i++)
      {
        char num[G_ASCII_DTOSTR_BUF_SIZE];
        g_string_append_printf(s, "%s%s", i ? "," : "", g_ascii_dtostr(num, sizeof num, vars[v].base + mi + i));
      }
      g_string_append_c(s, ']');
    }
  g_string_append(s, "}}");
  return g_string_free(s, FALSE);
}

static void
handle_request(Conn *conn)
{
  Fake *fake = conn->fake;
  const char *target = conn->request->str + 4; /* after "GET " */
  const char *end = strchr(target, ' ');
  g_assert_nonnull(end);
  g_autofree char *path = g_strndup(target, (gsize)(end - target));
  g_ptr_array_add(fake->heads, g_strdup(conn->request->str));
  g_ptr_array_add(fake->paths, g_strdup(path));
  fake->requests++;
  const Reply *reply = &fake->script.a;
  static const Reply failing = {R_REPLY, 503, "{}", FALSE, 0};
  gboolean is_a_ok = FALSE;
  if (g_str_has_prefix(path, "/v1/search"))
    reply = &fake->script.geo;
  else if (strstr(path, "minutely_15") != NULL)
    reply = &fake->script.b;
  else if (fake->a_seen++ < fake->script.a_first_fail)
    reply = &failing; /* the first attempts of request A are refused with 503 (WxHttp retries them) */
  else
    is_a_ok = TRUE;
  conn->is_a_ok = is_a_ok;

  switch (reply->kind) {
  case R_HANG:
    g_hash_table_remove(fake->conns, conn);
    g_ptr_array_add(fake->held, conn);
    return;
  case R_CLOSE:
    conn_free(conn);
    return;
  case R_REPLY:
  case R_CUT: {
    g_autofree char *synth = reply->body == NULL ? synth_body(path) : NULL;
    const char *body = reply->body != NULL ? reply->body : synth;
    if (body == NULL)
      g_error("no body to send");
    g_autoptr(GBytes) payload = reply->gzip ? gzip_of(body) : g_bytes_new(body, strlen(body));
    gsize n = g_bytes_get_size(payload);
    g_autofree char *head = g_strdup_printf(
        "HTTP/1.1 %u X\r\nContent-Type: application/json\r\n%sContent-Length: %" G_GSIZE_FORMAT
        "\r\nConnection: close\r\n\r\n",
        reply->status, reply->gzip ? "Content-Encoding: gzip\r\n" : "", reply->kind == R_CUT ? n + 500 : n);
    GByteArray *all = g_byte_array_new();
    g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
    g_byte_array_append(all, g_bytes_get_data(payload, NULL), (guint)n);
    GBytes *bytes = g_byte_array_free_to_bytes(all);
    if (reply->delay_ms > 0) {
      conn->pending = bytes;
      g_timeout_add(reply->delay_ms, on_delayed_answer, conn);
    } else {
      if (is_a_ok)
        fake->a_answer_us = g_get_monotonic_time();
      respond_bytes(conn, bytes);
      g_bytes_unref(bytes);
    }
    return;
  }
  }
}

static void
read_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gssize n = g_input_stream_read_finish(G_INPUT_STREAM(source), result, &error);
  if (n <= 0) {
    conn_free(conn);
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
on_incoming(GSocketService *service, GSocketConnection *connection, GObject *source, gpointer user_data)
{
  (void)service;
  (void)source;
  Conn *conn = g_new0(Conn, 1);
  conn->fake = user_data;
  conn->connection = g_object_ref(connection);
  conn->request = g_string_new(NULL);
  g_hash_table_add(conn->fake->conns, conn);
  conn_read(conn);
  return TRUE;
}

static Fake *
fake_new(const Script *script)
{
  Fake *fake = g_new0(Fake, 1);
  fake->script = *script;
  fake->paths = g_ptr_array_new_with_free_func(g_free);
  fake->heads = g_ptr_array_new_with_free_func(g_free);
  fake->held = g_ptr_array_new();
  fake->conns = g_hash_table_new(NULL, NULL);
  fake->service = g_socket_service_new();
  g_autoptr(GError) error = NULL;
  fake->port = g_socket_listener_add_any_inet_port(G_SOCKET_LISTENER(fake->service), NULL, &error);
  g_assert_no_error(error);
  g_signal_connect(fake->service, "incoming", G_CALLBACK(on_incoming), fake);
  g_socket_service_start(fake->service);
  return fake;
}

static void
fake_free(Fake *fake)
{
  g_socket_service_stop(fake->service);
  g_socket_listener_close(G_SOCKET_LISTENER(fake->service));
  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init(&iter, fake->conns);
  while (g_hash_table_iter_next(&iter, &key, NULL))
    (void)g_io_stream_close(G_IO_STREAM(((Conn *)key)->connection), NULL, NULL);
  gint64 until = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
  while (g_hash_table_size(fake->conns) > 0 && g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, FALSE);
  g_assert_cmpuint(g_hash_table_size(fake->conns), ==, 0);
  g_object_unref(fake->service);
  for (guint i = 0; i < fake->held->len; i++)
    conn_free(g_ptr_array_index(fake->held, i));
  g_ptr_array_unref(fake->held);
  g_hash_table_unref(fake->conns);
  g_ptr_array_unref(fake->paths);
  g_ptr_array_unref(fake->heads);
  g_free(fake);
}

static void
spin_ms(guint ms)
{
  gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
  while (g_get_monotonic_time() < until) {
    g_main_context_iteration(NULL, FALSE);
    g_usleep(500);
  }
}

static void
spin_until(const gboolean *flag, guint timeout_s)
{
  gint64 until = g_get_monotonic_time() + (gint64)timeout_s * G_USEC_PER_SEC;
  while (!*flag && g_get_monotonic_time() < until) {
    g_main_context_iteration(NULL, FALSE);
    g_usleep(500);
  }
}

/* The path of the request whose target contains @needle (NULL: any request not containing minutely_15). */
static const char *
fake_path_with(const Fake *fake, const char *needle)
{
  const char *found = NULL;
  for (guint i = 0; i < fake->paths->len; i++) {
    const char *p = g_ptr_array_index(fake->paths, i);
    gboolean match = needle != NULL ? strstr(p, needle) != NULL : strstr(p, "minutely_15") == NULL;
    if (match) {
      g_assert_null(found); /* exactly one */
      found = p;
    }
  }
  return found;
}

static const Script ok_script = {
    .a = {.kind = R_REPLY, .status = 200},
    .b = {.kind = R_REPLY, .status = 200, .body = NULL /* patched in script_ok() */},
    .geo = {.kind = R_REPLY, .status = 200},
};

static Script
script_ok(void)
{
  Script s = ok_script;
  s.b.body = fixture_text("nowcast_miami.json", NULL);
  s.geo.body = fixture_text("geocode_miami.json", NULL);
  return s;
}

/* A provider talking to @fake; short timings so failures do not slow the suite down. */
static WxOpenMeteo *
provider_for(const Fake *fake, guint timeout_ms, guint backoff_ms)
{
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(GError) error = NULL;
  WxOpenMeteo *om = wx_open_meteo_new_custom(base, timeout_ms, backoff_ms, &error);
  g_assert_no_error(error);
  g_assert_nonnull(om);
  return om;
}

static WxOpenMeteoGeocoder *
geocoder_for(const Fake *fake, guint timeout_ms, guint backoff_ms)
{
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(GError) error = NULL;
  WxOpenMeteoGeocoder *geo = wx_open_meteo_geocoder_new_custom(base, timeout_ms, backoff_ms, &error);
  g_assert_no_error(error);
  g_assert_nonnull(geo);
  return geo;
}

static WxPlace *
mk_place(const char *name, double lat, double lon)
{
  g_autoptr(GError) error = NULL;
  WxPlace *place = wx_place_new(name, "", "", "", lat, lon, "", &error);
  g_assert_no_error(error);
  g_assert_nonnull(place);
  return place;
}

/* ------------------------------------------------------------------------ */
/* Fetch / search drivers                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
  gboolean in_call;
  gboolean done;
  guint calls;
  WxSourceResult *result;
  GPtrArray *places;
  GError *error;
  gint64 start_us, end_us;
  GCancellable *cancel_first; /* cancelled by the callback before it finishes the operation */
} Op;

static void
op_clear(Op *op)
{
  g_clear_pointer(&op->result, wx_source_result_free);
  g_clear_pointer(&op->places, g_ptr_array_unref);
  g_clear_error(&op->error);
  memset(op, 0, sizeof *op);
}

static void
on_fetch(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Op *op = user_data;
  g_assert_false(op->in_call); /* never before the async call has returned */
  op->calls++;
  op->end_us = g_get_monotonic_time();
  if (op->cancel_first != NULL)
    g_cancellable_cancel(op->cancel_first);
  op->result = wx_provider_fetch_finish(WX_PROVIDER(source), result, &op->error);
  op->done = TRUE;
}

static void
fetch_start(WxOpenMeteo *om, const WxPlace *place, GCancellable *cancellable, Op *op)
{
  op->in_call = TRUE;
  op->start_us = g_get_monotonic_time();
  wx_provider_fetch_async(WX_PROVIDER(om), place, cancellable, on_fetch, op);
  op->in_call = FALSE;
}

/* Waits for the callback, then checks it was called exactly once. */
static void
op_wait(Op *op)
{
  spin_until(&op->done, 60);
  g_assert_true(op->done);
  spin_ms(60);
  g_assert_cmpuint(op->calls, ==, 1);
}

static void
on_search(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Op *op = user_data;
  g_assert_false(op->in_call);
  op->calls++;
  op->end_us = g_get_monotonic_time();
  if (op->cancel_first != NULL)
    g_cancellable_cancel(op->cancel_first);
  op->places = wx_geocoder_search_finish(WX_GEOCODER(source), result, &op->error);
  op->done = TRUE;
}

static void
search_start(WxOpenMeteoGeocoder *geo, const char *text, GCancellable *cancellable, Op *op)
{
  op->in_call = TRUE;
  op->start_us = g_get_monotonic_time();
  wx_geocoder_search_async(WX_GEOCODER(geo), text, cancellable, on_search, op);
  op->in_call = FALSE;
}

static gint64
elapsed_ms(const Op *op)
{
  return (op->end_us - op->start_us) / 1000;
}

static void
assert_member_ids(const WxSourceResult *result, const char *const *ids)
{
  guint n = 0;
  while (ids[n] != NULL)
    n++;
  assert_result_model_ids(result, ids, n);
}

/* ------------------------------------------------------------------------ */
/* Provider metadata and constructors                                       */
/* ------------------------------------------------------------------------ */

static void
test_provider_metadata(void)
{
  g_autoptr(WxOpenMeteo) om = wx_open_meteo_new();
  g_assert_nonnull(om);
  WxProvider *p = WX_PROVIDER(om);
  g_assert_cmpstr(wx_provider_get_id(p), ==, "open-meteo");
  g_assert_cmpstr(wx_provider_get_id(p), ==, WX_OPEN_METEO_ID);
  g_assert_cmpstr(wx_provider_get_name(p), ==, "Open-Meteo");
  g_assert_cmpstr(wx_provider_get_attribution(p), ==, "Weather data by Open-Meteo.com");
  g_assert_cmpstr(wx_provider_get_attribution_url(p), ==, "https://open-meteo.com/");
  g_assert_true(wx_id_is_valid(wx_provider_get_id(p)));
  g_assert_null(strchr(wx_provider_get_id(p), '.'));
  g_assert_cmpstr(WX_OPEN_METEO_BASE_URL, ==, "https://api.open-meteo.com");
  g_assert_cmpstr(WX_OPEN_METEO_GEOCODING_BASE_URL, ==, "https://geocoding-api.open-meteo.com");
  g_assert_cmpint(WX_OPEN_METEO_NOWCAST_GRACE_MS, ==, 2000);
  g_assert_cmpint(WX_OPEN_METEO_SEARCH_MIN_BYTES, ==, 2);
  g_assert_cmpint(WX_OPEN_METEO_SEARCH_MAX_BYTES, ==, 64);
  /* the constants are accepted by the engine (https hosts) */
  g_autoptr(GError) error = NULL;
  g_autoptr(WxOpenMeteo) again = wx_open_meteo_new_custom(WX_OPEN_METEO_BASE_URL, 1000, 0, &error);
  g_assert_no_error(error);
  g_assert_nonnull(again);
  g_autoptr(WxOpenMeteoGeocoder) geo = wx_open_meteo_geocoder_new();
  g_assert_nonnull(geo);
  g_assert_true(WX_IS_GEOCODER(geo));
  g_autoptr(WxOpenMeteoGeocoder) geo2 = wx_open_meteo_geocoder_new_custom(WX_OPEN_METEO_GEOCODING_BASE_URL, 1000, 0, &error);
  g_assert_no_error(error);
  g_assert_nonnull(geo2);
}

static void
test_provider_covers(void)
{
  g_autoptr(WxOpenMeteo) om = wx_open_meteo_new();
  struct {
    double lat, lon;
  } places[] = {{25.7617, -80.1918}, {51.5, -0.12}, {-33.87, 151.2}, {90, 180}, {-90, -180}, {0, 0}, {64.1, -21.9}};
  for (guint i = 0; i < G_N_ELEMENTS(places); i++) {
    g_autoptr(WxPlace) place = mk_place("P", places[i].lat, places[i].lon);
    g_assert_true(wx_provider_covers(WX_PROVIDER(om), place));
  }
  /* A hand-built place with an invalid coordinate is not covered. */
  WxPlace bad = {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"",
                 .lat = 91, .lon = 0};
  g_assert_false(wx_provider_covers(WX_PROVIDER(om), &bad));
  bad.lat = NAN;
  g_assert_false(wx_provider_covers(WX_PROVIDER(om), &bad));
  bad.lat = 0;
  bad.lon = INFINITY;
  g_assert_false(wx_provider_covers(WX_PROVIDER(om), &bad));
  ASSERT_CRITICAL("wx_provider_covers", g_assert_false(wx_provider_covers(WX_PROVIDER(om), NULL)));
}

static void
test_provider_registry(void)
{
  g_autoptr(WxRegistry) reg = wx_registry_new();
  g_autoptr(WxOpenMeteo) om = wx_open_meteo_new();
  g_autoptr(WxOpenMeteoGeocoder) geo = wx_open_meteo_geocoder_new();
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_registry_add_provider(reg, WX_PROVIDER(om), &error));
  g_assert_no_error(error);
  wx_registry_set_geocoder(reg, WX_GEOCODER(geo));
  g_assert_true(wx_registry_find_provider(reg, "open-meteo") == WX_PROVIDER(om));
  g_assert_true(wx_registry_get_geocoder(reg) == WX_GEOCODER(geo));
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(reg, place);
  g_assert_cmpuint(covering->len, ==, 1);
  /* A second Open-Meteo provider is a duplicate id. */
  g_autoptr(WxOpenMeteo) other = wx_open_meteo_new();
  g_assert_false(wx_registry_add_provider(reg, WX_PROVIDER(other), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
}

static void
test_constructors_validate(void)
{
  static const char *const bad_urls[] = {
      "http://example.com",           /* plain http to a public host */
      "ftp://127.0.0.1",
      "https://user:pw@example.com",
      "https://example.com?x=1",
      "https://example.com/v1",
      "",
      "not a url",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad_urls); i++) {
    g_autoptr(GError) error = NULL;
    g_assert_null(wx_open_meteo_new_custom(bad_urls[i], 1000, 10, &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpstr(error->message, ==, "unacceptable base URL");
    g_clear_error(&error);
    g_assert_null(wx_open_meteo_geocoder_new_custom(bad_urls[i], 1000, 10, &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpstr(error->message, ==, "unacceptable base URL");
  }
  g_assert_null(wx_open_meteo_new_custom("http://example.com", 1000, 10, NULL)); /* NULL error is fine */
  g_assert_null(wx_open_meteo_geocoder_new_custom("http://example.com", 1000, 10, NULL));
  ASSERT_CRITICAL("wx_open_meteo_new_custom", g_assert_null(wx_open_meteo_new_custom(NULL, 1000, 10, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_new_custom",
                  g_assert_null(wx_open_meteo_new_custom("https://a.example", 0, 10, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_new_custom",
                  g_assert_null(wx_open_meteo_new_custom("https://a.example", 600001, 10, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_new_custom",
                  g_assert_null(wx_open_meteo_new_custom("https://a.example", 1000, 600001, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_geocoder_new_custom",
                  g_assert_null(wx_open_meteo_geocoder_new_custom(NULL, 1000, 10, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_geocoder_new_custom",
                  g_assert_null(wx_open_meteo_geocoder_new_custom("https://a.example", 0, 10, NULL)));
  ASSERT_CRITICAL("wx_open_meteo_geocoder_new_custom",
                  g_assert_null(wx_open_meteo_geocoder_new_custom("https://a.example", 1000, 600001, NULL)));
  /* the limits themselves are fine */
  g_autoptr(WxOpenMeteo) a = wx_open_meteo_new_custom("https://a.example", 1, 0, NULL);
  g_autoptr(WxOpenMeteo) b = wx_open_meteo_new_custom("https://a.example", 600000, 600000, NULL);
  g_assert_nonnull(a);
  g_assert_nonnull(b);
  g_autoptr(WxOpenMeteoGeocoder) c = wx_open_meteo_geocoder_new_custom("https://a.example", 1, 0, NULL);
  g_autoptr(WxOpenMeteoGeocoder) d = wx_open_meteo_geocoder_new_custom("https://a.example", 600000, 600000, NULL);
  g_assert_nonnull(c);
  g_assert_nonnull(d);
}

static void
test_provider_finish_programmer_errors(void)
{
  g_autoptr(WxOpenMeteo) om = wx_open_meteo_new();
  g_autoptr(WxOpenMeteo) other = wx_open_meteo_new();
  ASSERT_CRITICAL("wx_provider_fetch_async", wx_provider_fetch_async(WX_PROVIDER(om), NULL, NULL, NULL, NULL));
  /* A task of another source object / with another tag is not a fetch result of this provider. */
  static char other_tag;
  g_autoptr(GTask) wrong_source = g_task_new(other, NULL, NULL, NULL);
  g_task_return_boolean(wrong_source, TRUE);
  ASSERT_CRITICAL("om_fetch_finish", g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(om), G_ASYNC_RESULT(wrong_source), NULL)));
  g_autoptr(GTask) wrong_tag = g_task_new(om, NULL, NULL, NULL);
  g_task_set_source_tag(wrong_tag, &other_tag);
  g_task_return_boolean(wrong_tag, TRUE);
  ASSERT_CRITICAL("om_fetch_finish", g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(om), G_ASYNC_RESULT(wrong_tag), NULL)));
  g_autoptr(WxOpenMeteoGeocoder) geo = wx_open_meteo_geocoder_new();
  ASSERT_CRITICAL("wx_geocoder_search_async", wx_geocoder_search_async(WX_GEOCODER(geo), NULL, NULL, NULL, NULL));
  g_autoptr(GTask) geo_wrong = g_task_new(geo, NULL, NULL, NULL);
  g_task_return_boolean(geo_wrong, TRUE);
  ASSERT_CRITICAL("geocoder_search_finish", g_assert_null(wx_geocoder_search_finish(WX_GEOCODER(geo), G_ASYNC_RESULT(geo_wrong), NULL)));
}

/* ------------------------------------------------------------------------ */
/* Provider: requests                                                       */
/* ------------------------------------------------------------------------ */

static char *
expect_path_a(const char *lat, const char *lon, const char *models)
{
  return g_strdup_printf(
      "/v1/forecast?latitude=%s&longitude=%s&hourly=temperature_2m,apparent_temperature,"
      "relative_humidity_2m,precipitation,precipitation_probability,cloud_cover,wind_speed_10m,"
      "wind_gusts_10m,weather_code&models=%s&timeformat=unixtime&timezone=GMT&forecast_days=10"
      "&wind_speed_unit=kmh&temperature_unit=celsius&precipitation_unit=mm",
      lat, lon, models);
}

static char *
expect_path_b(const char *lat, const char *lon)
{
  return g_strdup_printf(
      "/v1/forecast?latitude=%s&longitude=%s&minutely_15=precipitation&models=ncep_hrrr_conus"
      "&forecast_minutely_15=12&timeformat=unixtime&timezone=GMT&precipitation_unit=mm",
      lat, lon);
}

static void
test_net_miami_success(void)
{
  Script script = script_ok();
  script.a.body = fixture_text("forecast_miami_multi.json", NULL);
  script.a.gzip = TRUE; /* the real API serves gzip */
  script.b.gzip = TRUE;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  gint64 before = g_get_real_time() / G_USEC_PER_SEC;
  fetch_start(om, place, NULL, &op);
  g_assert_false(op.done);
  op_wait(&op);
  gint64 after = g_get_real_time() / G_USEC_PER_SEC;
  g_assert_no_error(op.error);
  g_assert_nonnull(op.result);
  g_assert_cmpstr(op.result->provider_id, ==, "open-meteo");
  static const char *const ids[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", "hrrr15", NULL};
  assert_member_ids(op.result, ids);
  for (guint i = 0; i < 7; i++) {
    gint64 f = wx_member_get_fetched_s(result_member(op.result, i));
    g_assert_cmpint(f, >=, before);
    g_assert_cmpint(f, <=, after);
  }
  guint n;
  (void)wx_member_get_hours(result_member(op.result, 2), &n);
  g_assert_cmpuint(n, ==, 241);
  (void)wx_member_get_hours(result_member(op.result, 6), &n);
  g_assert_cmpuint(n, ==, 0);
  const WxQuarter *q = wx_member_get_quarters(result_member(op.result, 6), &n);
  g_assert_cmpuint(n, ==, 12);
  g_assert_cmpint(q[0].t_s, ==, 1791832500 - 900);
  g_assert_cmpuint(fake->requests, ==, 2);
  g_autofree char *a = expect_path_a("25.7617", "-80.1918",
                                     "ncep_hrrr_conus,ncep_nbm_conus,gfs_seamless,ecmwf_ifs025,icon_seamless,gem_seamless");
  g_autofree char *b = expect_path_b("25.7617", "-80.1918");
  g_assert_cmpstr(fake_path_with(fake, NULL), ==, a);
  g_assert_cmpstr(fake_path_with(fake, "minutely_15"), ==, b);
  g_assert_true(wx_http_path_is_valid(a));
  g_assert_true(wx_http_path_is_valid(b));
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_london_success(void)
{
  Script script = script_ok();
  script.a.body = fixture_text("forecast_london_multi.json", NULL);
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("London", 51.5072, -0.1276);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  assert_result_model_ids(op.result, london_ids, 6);
  g_assert_cmpuint(fake->requests, ==, 1); /* no request B outside the CONUS branch */
  g_autofree char *a = expect_path_a("51.5072", "-0.1276",
                                     "ecmwf_ifs025,icon_seamless,gem_seamless,gfs_seamless,ukmo_seamless,meteofrance_seamless");
  g_assert_cmpstr(g_ptr_array_index(fake->paths, 0), ==, a);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_model_selection(void)
{
  static const char *const conus = "ncep_hrrr_conus,ncep_nbm_conus,gfs_seamless,ecmwf_ifs025,icon_seamless,gem_seamless";
  static const char *const us_other = "gfs_seamless,ecmwf_ifs025,icon_seamless,gem_seamless";
  static const char *const world = "ecmwf_ifs025,icon_seamless,gem_seamless,gfs_seamless";
  static const char *const europe = "ecmwf_ifs025,icon_seamless,gem_seamless,gfs_seamless,ukmo_seamless,meteofrance_seamless";
  static const struct {
    const char *name;
    double lat, lon;
    const char *lat_text, *lon_text, *models;
    gboolean nowcast;
  } cases[] = {
      {"Miami", 25.7617, -80.1918, "25.7617", "-80.1918", conus, TRUE},
      {"New York", 40.7128, -74.006, "40.7128", "-74.0060", conus, TRUE},
      {"Seattle", 47.6062, -122.3321, "47.6062", "-122.3321", conus, TRUE},
      {"Toronto", 43.6532, -79.3832, "43.6532", "-79.3832", conus, TRUE},
      {"Honolulu", 21.3069, -157.8583, "21.3069", "-157.8583", us_other, FALSE},
      {"Anchorage", 61.2181, -149.9003, "61.2181", "-149.9003", us_other, FALSE},
      {"San Juan", 18.4655, -66.1057, "18.4655", "-66.1057", us_other, FALSE},
      {"Guam", 13.4443, 144.7937, "13.4443", "144.7937", us_other, FALSE},
      {"Calgary", 51.0447, -114.0719, "51.0447", "-114.0719", world, FALSE},
      {"Mexico City", 19.4326, -99.1332, "19.4326", "-99.1332", world, FALSE},
      {"Sydney", -33.8688, 151.2093, "-33.8688", "151.2093", world, FALSE},
      {"Tokyo", 35.6762, 139.6503, "35.6762", "139.6503", world, FALSE},
      {"Moscow", 55.7558, 37.6173, "55.7558", "37.6173", europe, FALSE},
      {"London", 51.5072, -0.1276, "51.5072", "-0.1276", europe, FALSE},
      {"Reykjavik", 64.1466, -21.9426, "64.1466", "-21.9426", europe, FALSE},
      {"Origin", 0, 0, "0.0000", "0.0000", world, FALSE},
      {"Neg zero", -0.00001, -0.00001, "0.0000", "0.0000", world, FALSE},
      {"Rounding up", 25.76176, -80.19184, "25.7618", "-80.1918", conus, TRUE},
      {"Rounding down", 25.76174, -80.19186, "25.7617", "-80.1919", conus, TRUE},
      {"Pole", 90, 180, "90.0000", "180.0000", world, FALSE},
      {"Antarctica", -90, -180, "-90.0000", "-180.0000", world, FALSE},
  };
  static const char *const allow[] = {"ncep_hrrr_conus", "ncep_nbm_conus", "gfs_seamless", "ecmwf_ifs025",
                                      "icon_seamless",   "gem_seamless",   "ukmo_seamless", "meteofrance_seamless"};
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Script script = script_ok();
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
    g_autoptr(WxPlace) place = mk_place(cases[i].name, cases[i].lat, cases[i].lon);
    Op op = {0};
    fetch_start(om, place, NULL, &op);
    op_wait(&op);
    g_assert_no_error(op.error);
    g_assert_nonnull(op.result);
    g_autofree char *a = expect_path_a(cases[i].lat_text, cases[i].lon_text, cases[i].models);
    const char *got_a = fake_path_with(fake, NULL);
    if (got_a == NULL)
      g_error("%s: no request A", cases[i].name);
    if (strcmp(a, got_a) != 0)
      g_error("%s: got %s expected %s", cases[i].name, got_a, a);
    g_assert_cmpuint(fake->requests, ==, cases[i].nowcast ? 2 : 1);
    if (cases[i].nowcast) {
      g_autofree char *b = expect_path_b(cases[i].lat_text, cases[i].lon_text);
      g_assert_cmpstr(fake_path_with(fake, "minutely_15"), ==, b);
    }
    /* every requested model is on the allow-list, once; the synthetic body has data for each */
    const char *m = strstr(a, "models=") + 7;
    g_autofree char *list = g_strndup(m, (gsize)(strchr(m, '&') - m));
    g_auto(GStrv) names = g_strsplit(list, ",", -1);
    g_assert_cmpuint(g_strv_length(names), ==, op.result->members->len - (cases[i].nowcast ? 1 : 0));
    for (guint k = 0; names[k] != NULL; k++) {
      gboolean found = FALSE;
      for (guint j = 0; j < G_N_ELEMENTS(allow); j++)
        found |= strcmp(allow[j], names[k]) == 0;
      g_assert_true(found);
      const WxMember *member = result_member(op.result, k);
      guint nh;
      (void)wx_member_get_hours(member, &nh);
      g_assert_cmpuint(nh, ==, 5);
    }
    op_clear(&op);
    fake_free(fake);
  }
}

static void
test_net_locale_independent_coordinates(void)
{
  const char *saved = setlocale(LC_ALL, NULL);
  g_autofree char *restore = g_strdup(saved);
  const char *locales[] = {"de_DE.UTF-8", "fr_FR.UTF-8", "de_DE.utf8", "ru_RU.UTF-8", "pt_BR.UTF-8"};
  const char *got = NULL;
  for (guint i = 0; i < G_N_ELEMENTS(locales) && got == NULL; i++)
    got = setlocale(LC_ALL, locales[i]);
  if (got == NULL) {
    g_test_skip("no locale with a decimal comma is installed");
    return;
  }
  char probe[32];
  g_snprintf(probe, sizeof probe, "%f", 1.5);
  g_assert_nonnull(strchr(probe, ',')); /* the premise: printf would write a decimal comma */
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_autofree char *expect_b = expect_path_b("25.7617", "-80.1918");
  g_assert_cmpstr(fake_path_with(fake, "minutely_15"), ==, expect_b);
  const char *path_a = fake_path_with(fake, NULL);
  if (path_a == NULL)
    g_error("no request A");
  g_assert_nonnull(strstr(path_a, "latitude=25.7617&longitude=-80.1918&"));
  op_clear(&op);
  fake_free(fake);
  (void)setlocale(LC_ALL, restore);
}

static void
test_net_request_shape(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_cmpuint(fake->heads->len, ==, 2);
  for (guint i = 0; i < fake->heads->len; i++) {
    const char *head = g_ptr_array_index(fake->heads, i);
    g_autofree char *lower = g_ascii_strdown(head, -1);
    const char *path = g_ptr_array_index(fake->paths, i);
    g_autofree char *line = g_strdup_printf("GET %s HTTP/1.1\r\n", path);
    g_assert_true(g_str_has_prefix(head, line));
    g_assert_nonnull(strstr(head, "\r\nUser-Agent: " UA "\r\n"));
    g_assert_nonnull(strstr(lower, "\r\naccept: application/json\r\n"));
    g_assert_null(strstr(lower, "cookie"));
    g_assert_null(strstr(lower, "authorization"));
    g_assert_null(strstr(lower, "referer"));
    g_assert_null(strstr(lower, "mozilla"));
    g_assert_null(strstr(lower, "if-modified-since"));
    g_assert_null(strstr(lower, "api-key"));
    g_assert_null(strstr(lower, "apikey"));
    g_autofree char *host = g_strdup_printf("\r\nhost: 127.0.0.1:%u\r\n", fake->port);
    g_assert_nonnull(strstr(lower, host));
  }
  op_clear(&op);
  fake_free(fake);
}

/* ------------------------------------------------------------------------ */
/* Provider: partial failure (request B) and failure (request A)            */
/* ------------------------------------------------------------------------ */

static void
test_net_b_failure_is_tolerated(void)
{
  static const char *const garbage = "this is not json";
  static const char *const api_error = "{\"error\":true,\"reason\":\"Too many requests\"}";
  static const char *const no_quarters = "{\"minutely_15\":{\"time\":[],\"precipitation\":[]}}";
  static const char *const all_null = "{\"minutely_15\":{\"time\":[1791832500],\"precipitation\":[null]}}";
  static const struct {
    Reply reply;
    guint expect_requests;
  } cases[] = {
      {{R_REPLY, 404, "{}", FALSE, 0}, 2},
      {{R_REPLY, 400, "{\"error\":true,\"reason\":\"x\"}", FALSE, 0}, 2},
      {{R_REPLY, 429, "{}", FALSE, 0}, 2},
      {{R_REPLY, 500, "{}", FALSE, 0}, 4}, /* WxHttp retries 5xx twice */
      {{R_REPLY, 200, garbage, FALSE, 0}, 2},
      {{R_REPLY, 200, "{}", FALSE, 0}, 2},
      {{R_REPLY, 200, api_error, FALSE, 0}, 2},
      {{R_REPLY, 200, no_quarters, FALSE, 0}, 2},
      {{R_REPLY, 200, all_null, FALSE, 0}, 2},
      {{R_REPLY, 204, "", FALSE, 0}, 2},
      {{R_CLOSE, 0, NULL, FALSE, 0}, 4},
      {{R_CUT, 200, "{\"minutely_15\":{}}", FALSE, 0}, 4},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Script script = script_ok();
    script.b = cases[i].reply;
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 5);
    g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
    Op op = {0};
    fetch_start(om, place, NULL, &op);
    op_wait(&op);
    if (op.error != NULL)
      g_error("case %u: unexpected error %s", i, op.error->message);
    g_assert_nonnull(op.result);
    static const char *const ids[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", NULL};
    assert_member_ids(op.result, ids); /* request A's members, no nowcast member */
    spin_ms(150);                      /* let B's retries finish: the count is only final then */
    if (fake->requests != cases[i].expect_requests)
      g_error("case %u: %u requests, expected %u", i, fake->requests, cases[i].expect_requests);
    op_clear(&op);
    fake_free(fake);
  }
}

static void
test_net_b_hang_does_not_hold_the_result(void)
{
  Script script = script_ok();
  script.b.kind = R_HANG;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 10000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  static const char *const ids[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", NULL};
  assert_member_ids(op.result, ids);
  /* A answered at once: the result came when the grace period for B ran out, not at the 10 s timeout. */
  g_assert_cmpint(elapsed_ms(&op), >=, WX_OPEN_METEO_NOWCAST_GRACE_MS - 200);
  g_assert_cmpint(elapsed_ms(&op), <, WX_OPEN_METEO_NOWCAST_GRACE_MS + 4000);
  g_assert_cmpuint(fake->requests, ==, 2);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_b_slower_than_a_but_within_grace(void)
{
  for (guint k = 0; k < 2; k++) {
    Script script = script_ok();
    if (k == 0)
      script.b.delay_ms = 400; /* B after A */
    else
      script.a.delay_ms = 400; /* A after B */
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
    g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
    Op op = {0};
    fetch_start(om, place, NULL, &op);
    op_wait(&op);
    g_assert_no_error(op.error);
    static const char *const ids[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", "hrrr15", NULL};
    assert_member_ids(op.result, ids);
    g_assert_cmpint(elapsed_ms(&op), <, WX_OPEN_METEO_NOWCAST_GRACE_MS);
    op_clear(&op);
    fake_free(fake);
  }
}

/* The wait for request B is bounded from the START of the fetch (header, "Request A and request B"): the result
 * arrives at max(A's answer, start + WX_OPEN_METEO_NOWCAST_GRACE_MS) when B has not answered, with no wait added
 * after a late A. Every case checks that delivery time (upper bound with a 700 ms dispatch margin; for a hanging B
 * also the lower bound: the window is really waited out, and no further). */
static void
test_net_b_window_counts_from_fetch_start(void)
{
  static const struct {
    const char *name;
    guint a_delay_ms, a_first_fail, backoff_ms;
    ReplyKind b_kind;
    guint b_delay_ms;
    gboolean expect_nowcast;
    guint expect_a_attempts;
    gint64 min_total_ms; /* A really was this late / this early */
  } cases[] = {
      {"a-late-delayed-b-hang", 2500, 0, 10, R_HANG, 0, FALSE, 1, 2400},
      {"a-late-503-retries-b-hang", 0, 2, 700, R_HANG, 0, FALSE, 3, 2000},
      {"a-late-b-answers-after-window", 2300, 0, 10, R_REPLY, 2600, FALSE, 1, 2300},
      {"a-late-b-answered-early", 2300, 0, 10, R_REPLY, 0, TRUE, 1, 2300},
      {"a-1500-b-1800", 1500, 0, 10, R_REPLY, 1800, TRUE, 1, 1700},
      {"a-1000-b-hang", 1000, 0, 10, R_HANG, 0, FALSE, 1, 1900},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Script script = script_ok();
    script.a.delay_ms = cases[i].a_delay_ms;
    script.a_first_fail = cases[i].a_first_fail;
    script.b.kind = cases[i].b_kind;
    script.b.delay_ms = cases[i].b_delay_ms;
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteo) om = provider_for(fake, 10000, cases[i].backoff_ms);
    g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
    Op op = {0};
    fetch_start(om, place, NULL, &op);
    op_wait(&op);
    if (op.error != NULL)
      g_error("%s: unexpected error %s", cases[i].name, op.error->message);
    g_assert_nonnull(op.result);
    static const char *const with_b[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", "hrrr15", NULL};
    static const char *const without_b[] = {"hrrr", "nbm", "gfs", "ecmwf", "icon", "gem", NULL};
    assert_member_ids(op.result, cases[i].expect_nowcast ? with_b : without_b);
    if (fake->a_seen != cases[i].expect_a_attempts)
      g_error("%s: %u attempts of A, expected %u", cases[i].name, fake->a_seen, cases[i].expect_a_attempts);
    g_assert_cmpint(fake->a_answer_us, >, op.start_us);
    gint64 window_end_us = op.start_us + (gint64)WX_OPEN_METEO_NOWCAST_GRACE_MS * 1000;
    gint64 due_us = MAX(fake->a_answer_us, window_end_us);
    if (elapsed_ms(&op) < cases[i].min_total_ms)
      g_error("%s: result after %" G_GINT64_FORMAT " ms, A was expected to take >= %" G_GINT64_FORMAT " ms",
              cases[i].name, elapsed_ms(&op), cases[i].min_total_ms);
    if (op.end_us > due_us + 700 * 1000)
      g_error("%s: result %" G_GINT64_FORMAT " ms after max(A, start + window)", cases[i].name,
              (op.end_us - due_us) / 1000);
    if (cases[i].b_kind == R_HANG && op.end_us < due_us - 50 * 1000)
      g_error("%s: result %" G_GINT64_FORMAT " ms before max(A, start + window) with B pending", cases[i].name,
              (due_us - op.end_us) / 1000);
    op_clear(&op);
    fake_free(fake);
  }
}

/* Refill: 16 fetches (outside the CONUS branch: one slot each) started from a place that is defined relative to the
 * end of the first fetch. WxHttp admits 16 operations; the header ("Concurrency") says which of them are still
 * counted at each place. */
typedef enum { REFILL_IN_CALLBACK, REFILL_HIGH_IDLE, REFILL_DEFAULT_IDLE, REFILL_AFTER_100_MS } RefillWhere;

typedef struct {
  WxOpenMeteo *om;
  const WxPlace *london;
  RefillWhere where;
  gboolean first_done;
  guint started, ok, limited, other;
} Refill;

static void
on_refill_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Refill *r = user_data;
  g_autoptr(GError) error = NULL;
  WxSourceResult *res = wx_provider_fetch_finish(WX_PROVIDER(source), result, &error);
  if (res != NULL) {
    r->ok++;
    wx_source_result_free(res);
  } else if (g_error_matches(error, WX_ERROR, WX_ERROR_RATE_LIMITED)) {
    r->limited++;
  } else {
    r->other++;
  }
}

static void
refill_start(Refill *r)
{
  for (guint i = 0; i < 16; i++) {
    r->started++;
    wx_provider_fetch_async(WX_PROVIDER(r->om), r->london, NULL, on_refill_done, r);
  }
}

static gboolean
refill_idle(gpointer user_data)
{
  refill_start(user_data);
  return G_SOURCE_REMOVE;
}

static void
on_first_fetch_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Refill *r = user_data;
  g_autoptr(GError) error = NULL;
  WxSourceResult *res = wx_provider_fetch_finish(WX_PROVIDER(source), result, &error);
  g_assert_no_error(error);
  g_assert_nonnull(res);
  wx_source_result_free(res);
  r->first_done = TRUE;
  if (r->where == REFILL_IN_CALLBACK)
    refill_start(r);
  else if (r->where == REFILL_AFTER_100_MS)
    g_timeout_add(100, refill_idle, r);
  else
    g_idle_add_full(r->where == REFILL_HIGH_IDLE ? G_PRIORITY_HIGH : G_PRIORITY_DEFAULT, refill_idle, r, NULL);
}

static void
run_refill(const char *name, double lat, double lon, gboolean b_hangs, RefillWhere where, guint expect_ok,
           guint expect_limited)
{
  Script script = script_ok();
  if (b_hangs)
    script.b.kind = R_HANG;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 10000, 10);
  g_autoptr(WxPlace) first = mk_place("First", lat, lon);
  g_autoptr(WxPlace) london = mk_place("London", 51.5072, -0.1276);
  Refill r = {.om = om, .london = london, .where = where};
  wx_provider_fetch_async(WX_PROVIDER(om), first, NULL, on_first_fetch_done, &r);
  gint64 until = g_get_monotonic_time() + 30 * G_USEC_PER_SEC;
  while ((r.started < 16 || r.ok + r.limited + r.other < 16) && g_get_monotonic_time() < until) {
    g_main_context_iteration(NULL, FALSE);
    g_usleep(500);
  }
  spin_ms(100);
  if (r.started != 16 || r.ok != expect_ok || r.limited != expect_limited || r.other != 0)
    g_error("%s: started %u, ok %u, rate limited %u, other %u; expected 16 started, ok %u, rate limited %u", name,
            r.started, r.ok, r.limited, r.other, expect_ok, expect_limited);
  g_assert_true(r.first_done);
  fake_free(fake);
}

/* Slot lifetime of header "Concurrency", pinned. A fetch outside the CONUS branch still counts request A's slot
 * while its completion callback runs (15 of 16 refills start, 1 is RATE_LIMITED); once the callback has returned
 * the slot is free (idle sources: 16). A CONUS fetch completed by the end of B's window keeps B's slot until
 * WxHttp delivers B's cancellation, which takes several main-loop dispatches: refills from the callback, from a
 * G_PRIORITY_HIGH idle and from a default-priority idle queued in the callback all see it (15 + 1); 100 ms later it
 * is free (16). */
static void
test_net_slot_lifetime_refill(void)
{
  run_refill("london callback", 51.5072, -0.1276, FALSE, REFILL_IN_CALLBACK, 15, 1);
  run_refill("london high idle", 51.5072, -0.1276, FALSE, REFILL_HIGH_IDLE, 16, 0);
  run_refill("london default idle", 51.5072, -0.1276, FALSE, REFILL_DEFAULT_IDLE, 16, 0);
  run_refill("miami grace callback", 25.7617, -80.1918, TRUE, REFILL_IN_CALLBACK, 15, 1);
  run_refill("miami grace high idle", 25.7617, -80.1918, TRUE, REFILL_HIGH_IDLE, 15, 1);
  run_refill("miami grace default idle", 25.7617, -80.1918, TRUE, REFILL_DEFAULT_IDLE, 15, 1);
  run_refill("miami grace after 100 ms", 25.7617, -80.1918, TRUE, REFILL_AFTER_100_MS, 16, 0);
}

typedef struct {
  const char *name;
  Reply reply;
  int code;
  guint expect_requests; /* for the place in the CONUS branch: A attempts + 1 request B */
} FailCase;

static void
test_net_a_failure_fails_the_fetch(void)
{
  static const char *const no_models = "{\"hourly\":{\"time\":[1791763200],\"temperature_2m_gfs_seamless\":[null]}}";
  static const char *const wrong_keys = "{\"hourly\":{\"time\":[1791763200],\"temperature_2m\":[5]}}";
  static const FailCase cases[] = {
      {"404", {R_REPLY, 404, "{}", FALSE, 0}, WX_ERROR_NOT_FOUND, 2},
      {"429", {R_REPLY, 429, "{}", FALSE, 0}, WX_ERROR_RATE_LIMITED, 2},
      {"400", {R_REPLY, 400, "{\"error\":true,\"reason\":\"bad\"}", FALSE, 0}, WX_ERROR_HTTP, 2},
      {"403", {R_REPLY, 403, "{}", FALSE, 0}, WX_ERROR_HTTP, 2},
      {"301", {R_REPLY, 301, "{}", FALSE, 0}, WX_ERROR_HTTP, 2},
      {"500", {R_REPLY, 500, "{}", FALSE, 0}, WX_ERROR_HTTP, 4},
      {"503", {R_REPLY, 503, "{}", FALSE, 0}, WX_ERROR_HTTP, 4},
      {"garbage", {R_REPLY, 200, "<html>nope</html>", FALSE, 0}, WX_ERROR_PARSE, 2},
      {"empty object", {R_REPLY, 200, "{}", FALSE, 0}, WX_ERROR_PARSE, 2},
      {"empty body", {R_REPLY, 200, "", FALSE, 0}, WX_ERROR_PARSE, 2},
      {"no content", {R_REPLY, 204, "", FALSE, 0}, WX_ERROR_PARSE, 2},
      {"array root", {R_REPLY, 200, "[]", FALSE, 0}, WX_ERROR_PARSE, 2},
      {"error body 200", {R_REPLY, 200, "{\"error\":true,\"reason\":\"Cannot initialize\"}", FALSE, 0}, WX_ERROR_HTTP, 2},
      {"no model data", {R_REPLY, 200, no_models, FALSE, 0}, WX_ERROR_NOT_FOUND, 2},
      {"unsuffixed keys", {R_REPLY, 200, wrong_keys, FALSE, 0}, WX_ERROR_NOT_FOUND, 2},
      {"closed", {R_CLOSE, 0, NULL, FALSE, 0}, WX_ERROR_NETWORK, 4},
      {"truncated", {R_CUT, 200, "{\"hourly\":", FALSE, 0}, WX_ERROR_NETWORK, 4},
      {"hang", {R_HANG, 0, NULL, FALSE, 0}, WX_ERROR_TIMEOUT, 0},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    for (guint region = 0; region < 2; region++) {
      Script script = script_ok(); /* request B is healthy: it cannot rescue a failed A */
      script.a = cases[i].reply;
      Fake *fake = fake_new(&script);
      g_autoptr(WxOpenMeteo) om = provider_for(fake, 250, 5);
      g_autoptr(WxPlace) place = region == 0 ? mk_place("Miami", 25.7617, -80.1918)
                                             : mk_place("London", 51.5072, -0.1276);
      Op op = {0};
      fetch_start(om, place, NULL, &op);
      op_wait(&op);
      if (op.result != NULL || op.error == NULL || op.error->domain != WX_ERROR ||
          op.error->code != cases[i].code)
        g_error("case %s region %u: result=%p error=%s", cases[i].name, region, (void *)op.result,
                op.error != NULL ? op.error->message : "(none)");
      if (cases[i].code == WX_ERROR_HTTP && strcmp(cases[i].name, "error body 200") == 0)
        g_assert_cmpstr(op.error->message, ==, "Open-Meteo reported an error: Cannot initialize");
      if (cases[i].code == WX_ERROR_NOT_FOUND && strcmp(cases[i].name, "no model data") == 0)
        g_assert_cmpstr(op.error->message, ==, "no usable forecast data");
      if (cases[i].expect_requests > 0 && region == 1) {
        spin_ms(100);
        g_assert_cmpuint(fake->requests, ==, cases[i].expect_requests - 1); /* no request B in Europe */
      }
      op_clear(&op);
      fake_free(fake);
    }
  }
}

static void
test_net_a_failure_does_not_wait_for_b(void)
{
  Script script = script_ok();
  script.a = (Reply){R_REPLY, 404, "{}", FALSE, 0};
  script.b.kind = R_HANG;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 10000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_error(op.error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_assert_null(op.result);
  g_assert_cmpint(elapsed_ms(&op), <, 1500);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_b_alone_is_not_enough(void)
{
  /* A has no usable model, B is perfect: the fetch fails. */
  Script script = script_ok();
  script.a = (Reply){R_REPLY, 200, "{\"hourly\":{\"time\":[]}}", FALSE, 0};
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_error(op.error, WX_ERROR, WX_ERROR_NOT_FOUND);
  op_clear(&op);
  fake_free(fake);
}

/* ------------------------------------------------------------------------ */
/* Provider: invalid places, cancellation, lifecycle                        */
/* ------------------------------------------------------------------------ */

static void
test_net_invalid_places_make_no_request(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  WxPlace cases[] = {
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 91, .lon = 0},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = -91, .lon = 0},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 0, .lon = 181},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = NAN, .lon = 0},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 0, .lon = INFINITY},
      {.name = NULL, .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 1, .lon = 1},
      {.name = (char *)"", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 1, .lon = 1},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .country_code = "us", .timezone = (char *)"", .lat = 1, .lon = 1},
      {.name = (char *)"P", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"/etc/passwd", .lat = 1, .lon = 1},
      {.name = (char *)"P\n", .admin1 = (char *)"", .country = (char *)"", .timezone = (char *)"", .lat = 1, .lon = 1},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Op op = {0};
    fetch_start(om, &cases[i], NULL, &op);
    g_assert_false(op.done); /* the callback never runs before the async call returned */
    op_wait(&op);
    if (op.error == NULL || !g_error_matches(op.error, WX_ERROR, WX_ERROR_INVALID_ARG))
      g_error("case %u: %s", i, op.error != NULL ? op.error->message : "no error");
    g_assert_cmpstr(op.error->message, ==, "invalid place");
    op_clear(&op);
  }
  g_assert_cmpuint(fake->requests, ==, 0);
  fake_free(fake);
}

static void
test_net_cancel_before_start(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  g_cancellable_cancel(cancel);
  Op op = {0};
  fetch_start(om, place, cancel, &op);
  g_assert_false(op.done);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_null(op.result);
  spin_ms(50);
  g_assert_cmpuint(fake->requests, ==, 0);
  op_clear(&op);
  fake_free(fake);
}

static gboolean
cancel_later(gpointer user_data)
{
  g_cancellable_cancel(user_data);
  return G_SOURCE_REMOVE;
}

static void
test_net_cancel_during_a(void)
{
  Script script = script_ok();
  script.a.kind = R_HANG;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 10000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  Op op = {0};
  fetch_start(om, place, cancel, &op);
  g_timeout_add(150, cancel_later, cancel);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_null(op.result);
  g_assert_cmpint(elapsed_ms(&op), <, 3000);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_cancel_during_grace(void)
{
  Script script = script_ok();
  script.b.kind = R_HANG; /* A done, B pending: inside the grace period */
  Fake *fake = fake_new(&script);
  WxOpenMeteo *om = provider_for(fake, 10000, 10);
  gpointer weak = om;
  g_object_add_weak_pointer(G_OBJECT(om), &weak);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  Op op = {0};
  fetch_start(om, place, cancel, &op);
  g_timeout_add(500, cancel_later, cancel);
  op_wait(&op);
  /* A had succeeded, but the caller cancelled before finishing: the cancellation is reported. */
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_null(op.result);
  g_assert_cmpint(elapsed_ms(&op), <, WX_OPEN_METEO_NOWCAST_GRACE_MS);
  op_clear(&op);
  /* The grace timer died with the fetch: nothing keeps the provider alive after the last unref. */
  g_object_unref(om);
  spin_ms(100);
  g_assert_null(weak);
  fake_free(fake);
}

static void
test_net_cancel_before_finish(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("London", 51.5072, -0.1276);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  Op op = {0};
  op.cancel_first = cancel; /* cancelled in the callback, before wx_provider_fetch_finish() */
  fetch_start(om, place, cancel, &op);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_null(op.result);
  op_clear(&op);
  fake_free(fake);
}

typedef struct {
  GCancellable *cancellable;
  guint delay_us;
} ThreadCancel;

static gpointer
cancel_thread(gpointer data)
{
  ThreadCancel *tc = data;
  g_usleep(tc->delay_us);
  g_cancellable_cancel(tc->cancellable);
  return NULL;
}

/* The caller's cancellable is cancelled from another thread while the fetch runs, at every
 * stage from "just started" to "already finished": always exactly one callback, either the
 * result or G_IO_ERROR_CANCELLED, and no deadlock with the handler that forwards the cancel. */
static void
test_net_cancel_from_another_thread(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  guint cancelled = 0, succeeded = 0;
  guint rounds = fuzz_iterations(4000) / 40;
  for (guint i = 0; i < rounds; i++) {
    g_autoptr(GCancellable) cancel = g_cancellable_new();
    ThreadCancel tc = {cancel, (guint)(i % 20) * 300};
    Op op = {0};
    GThread *thread = g_thread_new("cancel", cancel_thread, &tc);
    fetch_start(om, place, cancel, &op);
    spin_until(&op.done, 30);
    g_assert_true(op.done);
    g_thread_join(thread);
    g_assert_cmpuint(op.calls, ==, 1);
    if (op.error != NULL) {
      g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
      cancelled++;
    } else {
      g_assert_cmpuint(op.result->members->len, ==, 7);
      succeeded++;
    }
    op_clear(&op);
  }
  g_assert_cmpuint(cancelled + succeeded, ==, rounds);
  g_assert_cmpuint(cancelled, >, 0);
  spin_ms(100);
  fake_free(fake);
}

static void
test_net_cancellable_outlives_the_fetch(void)
{
  /* One cancellable serves two fetches; cancelling it after both completed is harmless. */
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  for (guint i = 0; i < 2; i++) {
    Op op = {0};
    fetch_start(om, place, cancel, &op);
    op_wait(&op);
    g_assert_no_error(op.error);
    g_assert_cmpuint(op.result->members->len, ==, 7);
    op_clear(&op);
  }
  g_cancellable_cancel(cancel);
  spin_ms(100);
  Op op = {0};
  fetch_start(om, place, cancel, &op); /* already cancelled now */
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_dispose_in_flight(void)
{
  Script script = script_ok();
  script.a.delay_ms = 250;
  Fake *fake = fake_new(&script);
  WxOpenMeteo *om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  g_object_unref(om); /* the last caller reference goes while the fetch is in flight */
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_cmpuint(op.result->members->len, ==, 7);
  op_clear(&op);
  /* ... and dropped in flight with the cancellable cancelled afterwards */
  om = provider_for(fake, 5000, 10);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  fetch_start(om, place, cancel, &op);
  g_object_unref(om);
  g_cancellable_cancel(cancel);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  op_clear(&op);
  /* run_dispose in flight: the object keeps working */
  om = provider_for(fake, 5000, 10);
  fetch_start(om, place, NULL, &op);
  g_object_run_dispose(G_OBJECT(om));
  op_wait(&op);
  g_assert_no_error(op.error);
  op_clear(&op);
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  op_clear(&op);
  g_object_unref(om);
  fake_free(fake);
}

static void
test_net_concurrent_fetches(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) miami = mk_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxPlace) london = mk_place("London", 51.5072, -0.1276);
  g_autoptr(WxPlace) honolulu = mk_place("Honolulu", 21.3069, -157.8583);
  Op ops[6] = {{0}};
  const WxPlace *places[6] = {miami, london, honolulu, miami, london, honolulu};
  for (guint i = 0; i < 6; i++)
    fetch_start(om, places[i], NULL, &ops[i]);
  for (guint i = 0; i < 6; i++) {
    op_wait(&ops[i]);
    g_assert_no_error(ops[i].error);
  }
  g_assert_cmpuint(ops[0].result->members->len, ==, 7);
  g_assert_cmpuint(ops[1].result->members->len, ==, 6);
  g_assert_cmpuint(ops[2].result->members->len, ==, 4);
  g_assert_cmpuint(fake->requests, ==, 2 + 1 + 1 + 2 + 1 + 1);
  for (guint i = 0; i < 6; i++)
    op_clear(&ops[i]);
  fake_free(fake);
}

static void
test_net_inflight_cap(void)
{
  /* A CONUS fetch holds two WxHttp slots (A and B) while it runs: 8 fit into the 16 of WxHttp. */
  g_assert_cmpint(WX_HTTP_MAX_INFLIGHT, ==, 16);
  Script script = script_ok();
  /* Measured: the 16 requests are answered about two at a time (one fetch per delay period), and the window of
   * request B counts from the start of the fetch, queue time included: the delays stay short enough for the
   * 8th fetch to get its request B inside the window. */
  script.a.delay_ms = 100;
  script.b.delay_ms = 100;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op ops[10] = {{0}};
  for (guint i = 0; i < 10; i++)
    fetch_start(om, place, NULL, &ops[i]);
  for (guint i = 0; i < 10; i++) {
    op_wait(&ops[i]);
    if (i < 8) {
      g_assert_no_error(ops[i].error);
      g_assert_cmpuint(ops[i].result->members->len, ==, 7);
    } else {
      g_assert_error(ops[i].error, WX_ERROR, WX_ERROR_RATE_LIMITED);
      g_assert_null(ops[i].result);
    }
  }
  g_assert_cmpuint(fake->requests, ==, 16);
  for (guint i = 0; i < 10; i++)
    op_clear(&ops[i]);
  /* the slots come back: the next fetch works */
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  op_clear(&op);
  fake_free(fake);
}

/* A fetch outside the CONUS branch holds ONE WxHttp slot (header, "Concurrency"): 16 of them fit, the 17th is
 * refused; a CONUS fetch (two slots) among them takes the room of two. */
static void
test_net_inflight_cap_single_slot_fetches(void)
{
  Script script = script_ok();
  script.a.delay_ms = 300;
  script.b.delay_ms = 300;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 10);
  g_autoptr(WxPlace) sydney = mk_place("Sydney", -33.8688, 151.2093);
  g_autoptr(WxPlace) miami = mk_place("Miami", 25.7617, -80.1918);
  Op ops[18] = {{0}};
  for (guint i = 0; i < 18; i++)
    fetch_start(om, sydney, NULL, &ops[i]);
  for (guint i = 0; i < 18; i++) {
    op_wait(&ops[i]);
    if (i < 16) {
      g_assert_no_error(ops[i].error);
      g_assert_cmpuint(ops[i].result->members->len, ==, 4);
    } else {
      g_assert_error(ops[i].error, WX_ERROR, WX_ERROR_RATE_LIMITED);
      g_assert_null(ops[i].result);
    }
  }
  g_assert_cmpuint(fake->requests, ==, 16);
  for (guint i = 0; i < 18; i++)
    op_clear(&ops[i]);
  /* one CONUS fetch (2 slots) + 14 single-slot fetches fill the 16 slots; the 15th single-slot fetch is refused */
  guint before = fake->requests;
  fetch_start(om, miami, NULL, &ops[0]);
  for (guint i = 1; i < 16; i++)
    fetch_start(om, sydney, NULL, &ops[i]);
  for (guint i = 0; i < 16; i++) {
    op_wait(&ops[i]);
    if (i < 15) {
      g_assert_no_error(ops[i].error);
      g_assert_cmpuint(ops[i].result->members->len, ==, i == 0 ? 7 : 4);
    } else {
      g_assert_error(ops[i].error, WX_ERROR, WX_ERROR_RATE_LIMITED);
    }
  }
  g_assert_cmpuint(fake->requests - before, ==, 2 + 14);
  for (guint i = 0; i < 16; i++)
    op_clear(&ops[i]);
  /* A CONUS fetch that finds exactly one free slot sends request A and loses request B (tolerated): 6 members. */
  before = fake->requests;
  for (guint i = 0; i < 15; i++)
    fetch_start(om, sydney, NULL, &ops[i]);
  fetch_start(om, miami, NULL, &ops[15]);
  for (guint i = 0; i < 16; i++) {
    op_wait(&ops[i]);
    g_assert_no_error(ops[i].error);
    g_assert_cmpuint(ops[i].result->members->len, ==, i == 15 ? 6 : 4);
  }
  g_assert_cmpuint(fake->requests - before, ==, 15 + 1);
  for (guint i = 0; i < 16; i++)
    op_clear(&ops[i]);
  fake_free(fake);
}

static void
test_net_refused_connection(void)
{
  /* Nothing listens: a NETWORK error in the WX domain, B cannot help. */
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteo) om = provider_for(fake, 5000, 5);
  g_socket_service_stop(fake->service);
  g_socket_listener_close(G_SOCKET_LISTENER(fake->service));
  g_autoptr(WxPlace) place = mk_place("Miami", 25.7617, -80.1918);
  Op op = {0};
  fetch_start(om, place, NULL, &op);
  op_wait(&op);
  g_assert_error(op.error, WX_ERROR, WX_ERROR_NETWORK);
  op_clear(&op);
  fake_free(fake);
}

/* ------------------------------------------------------------------------ */
/* Geocoder over the network                                                */
/* ------------------------------------------------------------------------ */

static void
test_net_geocoder_success(void)
{
  Script script = script_ok();
  script.geo.gzip = TRUE;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Op op = {0};
  search_start(geo, "Miami", NULL, &op);
  g_assert_false(op.done);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_nonnull(op.places);
  g_assert_cmpuint(op.places->len, ==, 10);
  g_autofree char *label = wx_place_label(g_ptr_array_index(op.places, 0));
  g_assert_cmpstr(label, ==, "Miami, Florida, United States");
  g_assert_cmpuint(fake->requests, ==, 1);
  g_assert_cmpstr(g_ptr_array_index(fake->paths, 0), ==, "/v1/search?name=Miami&count=10&language=en&format=json");
  const char *head = g_ptr_array_index(fake->heads, 0);
  g_autofree char *lower = g_ascii_strdown(head, -1);
  g_assert_true(g_str_has_prefix(head, "GET /v1/search?name=Miami&count=10&language=en&format=json HTTP/1.1\r\n"));
  g_assert_nonnull(strstr(head, "\r\nUser-Agent: " UA "\r\n"));
  g_assert_nonnull(strstr(lower, "\r\naccept: application/json\r\n"));
  g_assert_null(strstr(lower, "cookie"));
  g_assert_null(strstr(lower, "authorization"));
  g_assert_null(strstr(lower, "referer"));
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_geocoder_escaping(void)
{
  static const struct {
    const char *text;
    const char *escaped;
  } cases[] = {
      {"Miami", "Miami"},
      {"  Miami \n", "Miami"},
      {"\t San Jose\r\n", "San%20Jose"},
      {"S\xc3\xa3o Paulo", "S%C3%A3o%20Paulo"},
      {"\xe6\x9d\xb1\xe4\xba\xac", "%E6%9D%B1%E4%BA%AC"},
      {"a&b=c#d?e/f%g+h", "a%26b%3Dc%23d%3Fe%2Ff%25g%2Bh"},
      {"x\\y\"z'<>|{}^`", "x%5Cy%22z%27%3C%3E%7C%7B%7D%5E%60"},
      {"a-b_c.d~e", "a-b_c.d~e"},
      {"ab", "ab"},
      {"\xc3\xa9", "%C3%A9"}, /* two bytes: long enough */
      {"New York, NY", "New%20York%2C%20NY"},
      {"x%00y", "x%2500y"},
      {"..", ".."},
      {"a b  c", "a%20b%20%20c"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Script script = script_ok();
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
    Op op = {0};
    search_start(geo, cases[i].text, NULL, &op);
    op_wait(&op);
    g_assert_no_error(op.error);
    g_assert_cmpuint(fake->requests, ==, 1);
    g_autofree char *expect = g_strdup_printf("/v1/search?name=%s&count=10&language=en&format=json", cases[i].escaped);
    if (strcmp(g_ptr_array_index(fake->paths, 0), expect) != 0)
      g_error("%s: got %s expected %s", cases[i].text, (char *)g_ptr_array_index(fake->paths, 0), expect);
    g_assert_true(wx_http_path_is_valid(expect));
    op_clear(&op);
    fake_free(fake);
  }
}

/* ------------------------------------------------------------------------ */
/* Search-text oracle                                                       */
/* ------------------------------------------------------------------------ */

/*
 * The oracle is the rule of wx-openmeteo.h ("Place search", steps 1-4), typed in again from the header's own
 * enumerations: the five trim bytes, the minimum and maximum length, the forbidden characters of step 3 (c), the
 * space separators of step 3 (d) and a strict RFC 3629 decoder of its own. It calls neither
 * wx_text_is_usable_name() nor GLib's character tables, so a list that drifts (in the header, in wx-text.c or in
 * GLib's Unicode data) makes the sweeps fail. test_geocoder_header_lists_match_runtime() ties the same lists to
 * wx-text.c and to the one GLib function the header names, for every Unicode scalar value, in the default run.
 */
G_STATIC_ASSERT(WX_OPEN_METEO_SEARCH_MIN_BYTES == 2);
G_STATIC_ASSERT(WX_OPEN_METEO_SEARCH_MAX_BYTES == 64);

enum { SEARCH_EMPTY = 0, SEARCH_INVALID = 1, SEARCH_REQUEST = 2 };

/* Step 1: the bytes that are trimmed from both ends. */
static gboolean
oracle_is_trim_byte(guchar c)
{
  return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r';
}

/* Step 3 (c): the forbidden characters, exactly as the header lists them (U+0000 cannot occur in a C string). */
static gboolean
oracle_forbidden(guint32 c)
{
  return (c >= 0x01 && c <= 0x1F) || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || c == 0x061C ||
         c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069);
}

/* Step 3 (d): the white space that is not forbidden, exactly as the header lists it (category Zs). */
static gboolean
oracle_space(guint32 c)
{
  return c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F || c == 0x205F ||
         c == 0x3000;
}

/* Step 3 (b): decodes one character per RFC 3629 (no overlong form, no surrogate, nothing above U+10FFFF).
 * Returns its length in bytes, 0 when the bytes are not valid UTF-8 (or are cut off after @left bytes). */
static gsize
oracle_utf8_decode(const guchar *p, gsize left, guint32 *c)
{
  guchar b = p[0];
  if (b < 0x80) {
    *c = b;
    return 1;
  }
  gsize n;
  guint32 v, min;
  if (b >= 0xC2 && b <= 0xDF) {
    n = 2;
    v = b & 0x1Fu;
    min = 0x80;
  } else if (b >= 0xE0 && b <= 0xEF) {
    n = 3;
    v = b & 0x0Fu;
    min = 0x800;
  } else if (b >= 0xF0 && b <= 0xF4) {
    n = 4;
    v = b & 0x07u;
    min = 0x10000;
  } else {
    return 0;
  }
  if (left < n)
    return 0;
  for (gsize i = 1; i < n; i++) {
    if ((p[i] & 0xC0) != 0x80)
      return 0;
    v = (v << 6) | (p[i] & 0x3Fu);
  }
  if (v < min || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF))
    return 0;
  *c = v;
  return n;
}

/* Steps 1-4: returns SEARCH_EMPTY, SEARCH_INVALID or SEARCH_REQUEST (*path_out = the exact request path). */
static int
oracle_search(const guchar *text, gsize len, char **path_out)
{
  gsize a = 0, b = len;
  while (a < b && oracle_is_trim_byte(text[a]))
    a++;
  while (b > a && oracle_is_trim_byte(text[b - 1]))
    b--;
  if (b - a < 2)
    return SEARCH_EMPTY;
  if (b - a > 64)
    return SEARCH_INVALID;
  gboolean visible = FALSE;
  for (gsize i = a; i < b;) {
    guint32 c = 0;
    gsize n = oracle_utf8_decode(text + i, b - i, &c);
    if (n == 0 || oracle_forbidden(c))
      return SEARCH_INVALID;
    if (!oracle_space(c))
      visible = TRUE;
    i += n;
  }
  if (!visible)
    return SEARCH_INVALID;
  GString *esc = g_string_new(NULL);
  for (gsize i = a; i < b; i++) {
    guchar c = text[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' ||
        c == '_' || c == '~')
      g_string_append_c(esc, (char)c);
    else
      g_string_append_printf(esc, "%%%02X", c);
  }
  *path_out = g_strdup_printf("/v1/search?name=%s&count=10&language=en&format=json", esc->str);
  g_string_free(esc, TRUE);
  return SEARCH_REQUEST;
}

/* The bytes of @text as hex, for failure messages. */
static char *
describe_bytes(const char *text)
{
  GString *s = g_string_new(NULL);
  for (const guchar *p = (const guchar *)text; *p != '\0'; p++)
    g_string_append_printf(s, "%02X ", *p);
  return g_string_free(s, FALSE);
}

/* The lists of the header against the runtime, for EVERY Unicode scalar value (default run; no network). */
static void
test_geocoder_header_lists_match_runtime(void)
{
  guint forbidden = 0, spaces = 0;
  for (guint32 c = 1; c <= 0x10FFFF; c++) {
    if (c >= 0xD800 && c <= 0xDFFF)
      continue;
    char u[8];
    gint n = g_unichar_to_utf8(c, u);
    g_assert_cmpint(n, >=, 1);
    char mid[16], twice[16];
    memcpy(mid, "ab", 2);
    memcpy(mid + 2, u, (gsize)n);
    memcpy(mid + 2 + n, "cd", 3); /* with the NUL */
    memcpy(twice, u, (gsize)n);
    memcpy(twice + n, u, (gsize)n);
    twice[2 * n] = '\0';
    gboolean forb = oracle_forbidden(c), sp = oracle_space(c);
    forbidden += forb;
    spaces += sp;
    if (wx_text_is_usable_name(mid, WX_OPEN_METEO_SEARCH_MAX_BYTES) == forb)
      g_error("U+%04X: wx_text_is_usable_name(ab c cd) disagrees with the header's forbidden list", c);
    if (wx_text_is_usable_name(twice, WX_OPEN_METEO_SEARCH_MAX_BYTES) != (!forb && !sp))
      g_error("U+%04X: wx_text_is_usable_name(c c) disagrees with the header's lists", c);
    /* Step 3 (d) names g_unichar_isspace(): outside the forbidden set it is exactly the listed space separators. */
    if ((g_unichar_isspace(c) && !forb) != sp)
      g_error("U+%04X: g_unichar_isspace() disagrees with the header's space list", c);
    /* The parse_geocode text names wx_sanitize_text(): it removes exactly the forbidden characters. */
    g_autofree char *clean = wx_sanitize_text(mid, WX_PLACE_NAME_MAX);
    if (strcmp(clean, forb ? "abcd" : mid) != 0)
      g_error("U+%04X: wx_sanitize_text disagrees with the header's forbidden list", c);
  }
  g_assert_cmpuint(forbidden, ==, 78); /* 64 control + 2 separators + 12 bidirectional formatting */
  g_assert_cmpuint(spaces, ==, 17);
  /* Not detected, and documented so: format characters (Cf) alone count as visible. */
  static const guint32 format_only[] = {0x00AD, 0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xE0001, 0xE0020};
  for (guint i = 0; i < G_N_ELEMENTS(format_only); i++) {
    char u[8];
    gint n = g_unichar_to_utf8(format_only[i], u);
    char twice[16];
    memcpy(twice, u, (gsize)n);
    memcpy(twice + n, u, (gsize)n);
    twice[2 * n] = '\0';
    g_assert_false(oracle_forbidden(format_only[i]));
    g_assert_false(oracle_space(format_only[i]));
    g_assert_true(wx_text_is_usable_name(twice, WX_OPEN_METEO_SEARCH_MAX_BYTES));
  }
}

/* ------------------------------------------------------------------------ */
/* Geocode parser: what is cleaned, cut, cleared and kept                   */
/* ------------------------------------------------------------------------ */

/* Appends @text as the inside of a JSON string: quote, backslash and bytes below 0x20 escaped, the rest raw. */
static void
json_escape(GString *out, const char *text)
{
  for (const guchar *p = (const guchar *)text; *p != '\0'; p++) {
    if (*p == '"' || *p == '\\') {
      g_string_append_c(out, '\\');
      g_string_append_c(out, (char)*p);
    } else if (*p < 0x20) {
      g_string_append_printf(out, "\\u%04x", *p);
    } else {
      g_string_append_c(out, (char)*p);
    }
  }
}

/* One hit with the given texts (NULL: member absent); every text is JSON-escaped. */
static void
append_hit(GString *body, const char *name, const char *admin1, const char *country, const char *code,
           const char *tz)
{
  static const char *const keys[] = {"name", "admin1", "country", "country_code", "timezone"};
  const char *vals[] = {name, admin1, country, code, tz};
  if (body->str[body->len - 1] != '[')
    g_string_append_c(body, ',');
  g_string_append(body, "{\"latitude\":1,\"longitude\":2");
  for (guint i = 0; i < G_N_ELEMENTS(keys); i++) {
    if (vals[i] == NULL)
      continue;
    g_string_append_printf(body, ",\"%s\":\"", keys[i]);
    json_escape(body, vals[i]);
    g_string_append_c(body, '"');
  }
  g_string_append_c(body, '}');
}

static GPtrArray *
parse_hits(GString *body)
{
  g_string_append(body, "]}");
  g_autoptr(GError) error = NULL;
  GPtrArray *places = wx_open_meteo_parse_geocode(BODY(body->str), &error);
  g_assert_no_error(error);
  g_assert_nonnull(places);
  return places;
}

/* parse_geocode: name, admin1 and country lose exactly the forbidden characters of the header (every Unicode
 * scalar value, in batches of 40 inside one text), whatever else they hold stays. */
static void
test_parse_geocode_forbidden_sweep(void)
{
  guint32 c = 1;
  while (c <= 0x10FFFF) {
    guint32 first = c;
    GString *chars = g_string_new("N"), *kept = g_string_new("N");
    for (guint i = 0; i < 40 && c <= 0x10FFFF; c++) {
      if (c >= 0xD800 && c <= 0xDFFF)
        continue;
      g_string_append_unichar(chars, c);
      if (!oracle_forbidden(c))
        g_string_append_unichar(kept, c);
      i++;
    }
    GString *body = g_string_new("{\"results\":[");
    append_hit(body, chars->str, chars->str, chars->str, NULL, NULL);
    g_autoptr(GPtrArray) places = parse_hits(body);
    if (places->len != 1)
      g_error("batch from U+%04X: %u hits", first, places->len);
    const WxPlace *p = g_ptr_array_index(places, 0);
    if (strcmp(p->name, kept->str) != 0 || strcmp(p->admin1, kept->str) != 0 || strcmp(p->country, kept->str) != 0)
      g_error("batch from U+%04X: texts differ from the header's forbidden list", first);
    g_string_free(body, TRUE);
    g_string_free(chars, TRUE);
    g_string_free(kept, TRUE);
  }
}

/* parse_geocode: white space only, format characters only, surrounding white space. */
static void
test_parse_geocode_whitespace_rules(void)
{
  GString *body = g_string_new(NULL);
  guint spaces = 0;
  for (guint32 c = 1; c <= 0x10FFFF; c++) {
    if (!oracle_space(c))
      continue;
    spaces++;
    char u[8] = {0};
    (void)g_unichar_to_utf8(c, u);
    g_autofree char *two = g_strconcat(u, u, NULL);
    g_autofree char *mixed = g_strconcat(u, "\x01", u, "\xe2\x80\xa8", NULL); /* white space and forbidden only */
    /* name: white space only (after cleaning) drops the hit; admin1 / country in that state become "" */
    g_string_assign(body, "{\"results\":[");
    append_hit(body, u, NULL, NULL, NULL, NULL);
    append_hit(body, mixed, NULL, NULL, NULL, NULL);
    append_hit(body, "A", two, u, NULL, NULL);
    g_autoptr(GPtrArray) places = parse_hits(body);
    if (places->len != 1)
      g_error("space U+%04X: %u hits, expected only the one with a visible name", c, places->len);
    const WxPlace *p = g_ptr_array_index(places, 0);
    g_assert_cmpstr(p->name, ==, "A");
    g_assert_cmpstr(p->admin1, ==, "");
    g_assert_cmpstr(p->country, ==, "");
  }
  g_assert_cmpuint(spaces, ==, 17);
  /* Not detected (documented): format characters only are visible and kept, in the name and in the optional texts. */
  static const char *const cf[] = {"\xe2\x80\x8b\xe2\x80\x8b", "\xef\xbb\xbf", "\xe2\x81\xa0", "\xc2\xad",
                                   "\xe1\xa0\x8e", "\xf3\xa0\x80\x81"};
  for (guint i = 0; i < G_N_ELEMENTS(cf); i++) {
    g_string_assign(body, "{\"results\":[");
    append_hit(body, cf[i], cf[i], cf[i], NULL, NULL);
    g_autoptr(GPtrArray) places = parse_hits(body);
    g_assert_cmpuint(places->len, ==, 1);
    const WxPlace *p = g_ptr_array_index(places, 0);
    g_assert_cmpstr(p->name, ==, cf[i]);
    g_assert_cmpstr(p->admin1, ==, cf[i]);
    g_assert_cmpstr(p->country, ==, cf[i]);
  }
  /* White space around visible text is neither trimmed nor collapsed. */
  g_string_assign(body, "{\"results\":[");
  append_hit(body, " Miami ", "\xe3\x80\x80" "FL\xc2\xa0", "  United   States ", NULL, NULL);
  g_autoptr(GPtrArray) kept = parse_hits(body);
  g_assert_cmpuint(kept->len, ==, 1);
  const WxPlace *p = g_ptr_array_index(kept, 0);
  g_assert_cmpstr(p->name, ==, " Miami ");
  g_assert_cmpstr(p->admin1, ==, "\xe3\x80\x80" "FL\xc2\xa0");
  g_assert_cmpstr(p->country, ==, "  United   States ");
  /* A member that is not a string is "" (admin1 and country), and a non-string name drops the hit. */
  g_autoptr(GError) error = NULL;
  g_autoptr(GPtrArray) typed = geocode(
      "{\"results\":[{\"name\":\"A\",\"latitude\":1,\"longitude\":2,\"admin1\":5,\"country\":true},"
      "{\"name\":\"B\",\"latitude\":1,\"longitude\":2,\"admin1\":null,\"country\":[\"X\"]},"
      "{\"name\":7,\"latitude\":1,\"longitude\":2,\"admin1\":\"X\"}]}",
      &error);
  g_assert_no_error(error);
  g_assert_cmpuint(typed->len, ==, 2);
  for (guint i = 0; i < 2; i++) {
    const WxPlace *t = g_ptr_array_index(typed, i);
    g_assert_cmpstr(t->admin1, ==, "");
    g_assert_cmpstr(t->country, ==, "");
  }
  g_string_free(body, TRUE);
}

/* parse_geocode: cut at WX_PLACE_NAME_MAX bytes on a character boundary, forbidden characters not counted, the
 * scan ends at the first character that does not fit. */
static void
test_parse_geocode_truncation(void)
{
  G_STATIC_ASSERT(WX_PLACE_NAME_MAX == 256);
  static const guint32 samples[4] = {'b', 0xE9, 0x4E2D, 0x1F600}; /* 1, 2, 3 and 4 bytes */
  for (guint w = 1; w <= 4; w++) {
    GString *body = g_string_new("{\"results\":[");
    GPtrArray *expect = g_ptr_array_new_with_free_func(g_free);
    for (guint n = 250; n <= 256; n++)
      for (guint noise = 0; noise < 2; noise++) {
        GString *text = g_string_new(NULL);
        for (guint i = 0; i < n; i++)
          g_string_append_c(text, 'a');
        if (noise) /* forbidden characters do not use up the budget */
          g_string_append(text, "\x01\xe2\x80\xa8\xe2\x80\x8e\xc2\x85\x7f");
        g_string_append_unichar(text, samples[w - 1]);
        g_string_append(text, "zzzzzzzzzz");
        /* expected: whole characters up to 256 bytes; the scan ends at the first that does not fit */
        GString *want = g_string_new(NULL);
        for (guint i = 0; i < n; i++)
          g_string_append_c(want, 'a');
        if (n + w <= 256) {
          g_string_append_unichar(want, samples[w - 1]);
          for (guint i = 0; i < 10 && want->len < 256; i++)
            g_string_append_c(want, 'z');
        }
        append_hit(body, text->str, text->str, text->str, NULL, NULL);
        g_ptr_array_add(expect, g_string_free(want, FALSE));
        g_string_free(text, TRUE);
      }
    g_autoptr(GPtrArray) places = parse_hits(body);
    g_assert_cmpuint(places->len, ==, expect->len);
    for (guint i = 0; i < places->len; i++) {
      const WxPlace *p = g_ptr_array_index(places, i);
      const char *want = g_ptr_array_index(expect, i);
      g_assert_cmpuint(strlen(want), <=, WX_PLACE_NAME_MAX);
      g_assert_true(g_utf8_validate(want, -1, NULL));
      g_assert_cmpstr(p->name, ==, want);
      g_assert_cmpstr(p->admin1, ==, want);
      g_assert_cmpstr(p->country, ==, want);
    }
    g_ptr_array_unref(expect);
    g_string_free(body, TRUE);
  }
  /* Cut to white space only: the name drops the hit, admin1 / country become "" (no hit is lost for them). */
  g_autofree char *blank = g_strnfill(300, ' ');
  g_autofree char *blank_then_text = g_strdup_printf("%.256s" "X", blank);
  g_autofree char *wide_blank = g_strnfill(257, ' ');
  GString *body = g_string_new("{\"results\":[");
  append_hit(body, blank, NULL, NULL, NULL, NULL);            /* dropped */
  append_hit(body, wide_blank, NULL, NULL, NULL, NULL);       /* dropped */
  append_hit(body, "A", blank_then_text, blank, NULL, NULL);  /* kept, admin1 and country "" */
  g_autoptr(GPtrArray) places = parse_hits(body);
  g_string_free(body, TRUE);
  g_assert_cmpuint(places->len, ==, 1);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->name, ==, "A");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->admin1, ==, "");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->country, ==, "");
}

/* parse_geocode: country_code is kept iff it is exactly two ASCII capitals. */
static void
test_parse_geocode_country_code_rule(void)
{
  GPtrArray *codes = g_ptr_array_new_with_free_func(g_free);
  /* every ASCII pair (U+0001..U+007F twice) */
  for (guint a = 1; a < 0x80; a++)
    for (guint b = 1; b < 0x80; b++)
      g_ptr_array_add(codes, g_strdup_printf("%c%c", (int)a, (int)b));
  /* every single ASCII character, and every three-character code that starts with two capitals */
  for (guint a = 1; a < 0x80; a++) {
    g_ptr_array_add(codes, g_strdup_printf("%c", (int)a));
    g_ptr_array_add(codes, g_strdup_printf("US%c", (int)a));
    g_ptr_array_add(codes, g_strdup_printf("%cUS", (int)a));
  }
  /* every one-character code that is two bytes long: U+0080..U+07FF (strlen 2 but not two capitals) */
  for (guint32 c = 0x80; c <= 0x7FF; c++) {
    char u[8] = {0};
    (void)g_unichar_to_utf8(c, u);
    g_ptr_array_add(codes, g_strdup(u));
  }
  static const char *const other[] = {"", "\xef\xbc\xb5\xef\xbc\xb3", "U\xcc\x81", "US\xe2\x80\x8b", " US", "US ",
                                      "uS", "Us", "\xc3\x80" "B", "ABC", "A", "\xc3\x89\xc3\x89", "U\xc3\x9c"};
  for (guint i = 0; i < G_N_ELEMENTS(other); i++)
    g_ptr_array_add(codes, g_strdup(other[i]));
  guint kept = 0;
  for (guint start = 0; start < codes->len; start += 20) {
    GString *body = g_string_new("{\"results\":[");
    guint end = MIN(start + 20, codes->len);
    for (guint i = start; i < end; i++)
      append_hit(body, "N", NULL, NULL, g_ptr_array_index(codes, i), NULL);
    g_autoptr(GPtrArray) places = parse_hits(body);
    g_string_free(body, TRUE);
    g_assert_cmpuint(places->len, ==, end - start);
    for (guint i = start; i < end; i++) {
      const char *code = g_ptr_array_index(codes, i);
      gboolean ok = strlen(code) == 2 && code[0] >= 'A' && code[0] <= 'Z' && code[1] >= 'A' && code[1] <= 'Z';
      const WxPlace *p = g_ptr_array_index(places, i - start);
      if (strcmp(p->country_code, ok ? code : "") != 0) {
        g_autofree char *what = describe_bytes(code);
        g_error("country_code bytes %s: got '%s'", what, p->country_code);
      }
      kept += ok;
    }
  }
  g_assert_cmpuint(kept, ==, 26 * 26);
  g_ptr_array_unref(codes);
  /* A country_code that is not a string is "" too. */
  static const char *const typed[] = {"5", "null", "true", "[]", "{}", "[\"US\"]", "1.5"};
  for (guint i = 0; i < G_N_ELEMENTS(typed); i++) {
    g_autofree char *text = g_strdup_printf(
        "{\"results\":[{\"name\":\"N\",\"latitude\":1,\"longitude\":2,\"country_code\":%s}]}", typed[i]);
    g_autoptr(GError) error = NULL;
    g_autoptr(GPtrArray) places = geocode(text, &error);
    g_assert_no_error(error);
    g_assert_cmpuint(places->len, ==, 1);
    g_assert_cmpstr(((WxPlace *)g_ptr_array_index(places, 0))->country_code, ==, "");
  }
}

/* parse_geocode: a timezone is kept iff wx_place_new() accepts it; the hit is kept either way. */
static void
test_parse_geocode_timezone_rule(void)
{
  static const struct {
    const char *tz;
    const char *kept; /* the literal expectation (NULL: whatever wx_place_new() decides, checked below) */
  } pinned[] = {
      {"", ""}, {"UTC", "UTC"}, {"America/New_York", "America/New_York"}, {"Etc/GMT+5", "Etc/GMT+5"},
      {"America/Argentina/Buenos_Aires", "America/Argentina/Buenos_Aires"}, {"/etc/passwd", ""},
      {"a/../b", ""}, {"../x", ""}, {"./x", ""}, {"-", ""}, {"Europe/New York", ""}, {"a//b", ""}, {"a/", ""},
      {"/a", ""}, {"1/a", ""}, {"a/1", ""}, {"a/-b", ""}, {"a/_b", ""}, {"a/.b", ""}, {"Europe/Z\xc3\xbc" "rich", ""},
      {"a/b\\c", ""}, {"a/b%2fc", ""}, {"a/b\nc", ""}, {"a/b\x7f", ""},
  };
  GPtrArray *tzs = g_ptr_array_new_with_free_func(g_free);
  GPtrArray *want = g_ptr_array_new_with_free_func(g_free);
  for (guint i = 0; i < G_N_ELEMENTS(pinned); i++) {
    g_ptr_array_add(tzs, g_strdup(pinned[i].tz));
    g_ptr_array_add(want, g_strdup(pinned[i].kept));
  }
  /* the length limit: WX_PLACE_TIMEZONE_MAX characters pass, one more does not */
  for (guint len = 60; len <= 70; len++) {
    g_autofree char *tail = g_strnfill(len - 2, 'x');
    g_ptr_array_add(tzs, g_strdup_printf("A/%s", tail));
    g_ptr_array_add(want, len <= WX_PLACE_TIMEZONE_MAX ? g_strdup_printf("A/%s", tail) : g_strdup(""));
  }
  /* every ASCII character next to a valid zone, in front of it and behind it: wx_place_new() decides; the literal
   * expectation is "kept only if it is the plain name" */
  for (guint c = 1; c < 0x80; c++) {
    gboolean name_char = g_ascii_isalnum((int)c) || c == '_' || c == '+' || c == '-';
    g_ptr_array_add(tzs, g_strdup_printf("Area/Loc%c", (int)c));
    g_ptr_array_add(want, name_char ? g_strdup_printf("Area/Loc%c", (int)c) : g_strdup(""));
    g_ptr_array_add(tzs, g_strdup_printf("%cArea/Loc", (int)c));
    g_ptr_array_add(want, g_ascii_isalpha((int)c) ? g_strdup_printf("%cArea/Loc", (int)c) : g_strdup(""));
  }
  for (guint start = 0; start < tzs->len; start += 20) {
    GString *body = g_string_new("{\"results\":[");
    guint end = MIN(start + 20, tzs->len);
    for (guint i = start; i < end; i++)
      append_hit(body, "N", NULL, NULL, NULL, g_ptr_array_index(tzs, i));
    g_autoptr(GPtrArray) places = parse_hits(body);
    g_string_free(body, TRUE);
    g_assert_cmpuint(places->len, ==, end - start);
    for (guint i = start; i < end; i++) {
      const char *tz = g_ptr_array_index(tzs, i);
      const WxPlace *p = g_ptr_array_index(places, i - start);
      /* the header's sentence: kept iff wx_place_new() accepts it */
      g_autoptr(WxPlace) probe = wx_place_new("N", "", "", "", 1, 2, tz, NULL);
      const char *by_place_new = probe != NULL ? tz : "";
      if (strcmp(p->timezone, by_place_new) != 0)
        g_error("timezone '%s': parse_geocode kept '%s', wx_place_new decides '%s'", tz, p->timezone, by_place_new);
      /* and the shape the tests pin independently of wx_place_new() */
      if (strcmp(p->timezone, g_ptr_array_index(want, i)) != 0)
        g_error("timezone '%s': kept '%s', expected '%s'", tz, p->timezone, (char *)g_ptr_array_index(want, i));
      g_assert_cmpfloat(p->lat, ==, 1.0);
    }
  }
  g_ptr_array_unref(tzs);
  g_ptr_array_unref(want);
}

/* The error reason of {"error":true,"reason":...}: forbidden characters removed, then cut to 120 CHARACTERS (not
 * bytes), by all three parsers. */
static void
test_parse_error_reason_length(void)
{
  static const guint32 samples[4] = {'x', 0xE9, 0x4E2D, 0x1F600}; /* 1, 2, 3 and 4 bytes */
  static const char prefix[] = "Open-Meteo reported an error: ";
  for (guint w = 1; w <= 4; w++)
    for (guint count = 118; count <= 122; count++)
      for (guint noise = 0; noise < 2; noise++) {
        GString *reason = g_string_new(NULL), *want = g_string_new(prefix);
        for (guint i = 0; i < count; i++) {
          if (noise) /* forbidden characters between the characters do not count towards the 120 */
            g_string_append(reason, "\x01\xe2\x80\xa8\xe2\x80\x8e\xc2\x85");
          g_string_append_unichar(reason, samples[w - 1]);
          if (i < 120)
            g_string_append_unichar(want, samples[w - 1]);
        }
        GString *body = g_string_new("{\"error\":true,\"reason\":\"");
        json_escape(body, reason->str);
        g_string_append(body, "\"}");
        g_autoptr(GError) e1 = NULL, e2 = NULL, e3 = NULL;
        g_autoptr(WxSourceResult) result = forecast(body->str, miami_models, &e1);
        g_autoptr(WxMember) member = nowcast(body->str, &e2);
        g_autoptr(GPtrArray) places = geocode(body->str, &e3);
        g_assert_null(result);
        g_assert_null(member);
        g_assert_null(places);
        g_assert_error(e1, WX_ERROR, WX_ERROR_HTTP);
        g_assert_error(e2, WX_ERROR, WX_ERROR_HTTP);
        g_assert_error(e3, WX_ERROR, WX_ERROR_HTTP);
        g_assert_cmpstr(e1->message, ==, want->str);
        g_assert_cmpstr(e2->message, ==, want->str);
        g_assert_cmpstr(e3->message, ==, want->str);
        g_string_free(reason, TRUE);
        g_string_free(want, TRUE);
        g_string_free(body, TRUE);
      }
}

/* The weather code: stored only for an integer-valued number in 0..99, else -1. */
static void
test_parse_weather_code_rule(void)
{
  GString *times = g_string_new("["), *temps = g_string_new("["), *codes = g_string_new("[");
  int want[160];
  guint n = 0;
  for (int v = -5; v <= 104; v++) {
    g_string_append_printf(codes, "%s%d", n ? "," : "", v);
    want[n++] = (v >= 0 && v <= 99) ? v : -1;
  }
  static const struct {
    const char *text;
    int code;
  } special[] = {{"7.0", 7},        {"7e0", 7},      {"0.0", 0},    {"-0.0", 0},     {"99.0", 99},
                 {"99.0000001", -1}, {"1e2", -1},   {"3.5", -1},   {"-0.5", -1},    {"\"3\"", -1},
                 {"true", -1},      {"null", -1},    {"[]", -1},    {"{}", -1},      {"1e999", -1},
                 {"9223372036854775807", -1}, {"-9223372036854775808", -1}, {"4.9e-324", -1}};
  for (guint i = 0; i < G_N_ELEMENTS(special); i++) {
    g_string_append_printf(codes, ",%s", special[i].text);
    want[n++] = special[i].code;
  }
  for (guint i = 0; i < n; i++) {
    g_string_append_printf(times, "%s%" G_GINT64_FORMAT, i ? "," : "", T0 + (gint64)i * 3600);
    g_string_append(temps, i ? ",10" : "10");
  }
  g_autofree char *text = g_strdup_printf("{\"hourly\":{\"time\":%s],\"temperature_2m\":%s],\"weather_code\":%s]}}",
                                          times->str, temps->str, codes->str);
  g_string_free(times, TRUE);
  g_string_free(temps, TRUE);
  g_string_free(codes, TRUE);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) result = forecast(text, gfs_only, &error);
  g_assert_no_error(error);
  for (guint i = 0; i < n; i++) {
    const WxHour *h = hour_at(result_member(result, 0), T0 + (gint64)i * 3600);
    g_assert_nonnull(h);
    if (h->wmo != want[i])
      g_error("weather code index %u: stored %d, expected %d", i, h->wmo, want[i]);
  }
}

/* ------------------------------------------------------------------------ */
/* Sweep driver: many searches at once, every outcome checked               */
/* ------------------------------------------------------------------------ */

#define SWEEP_WINDOW 8 /* WxHttp admits 16 outstanding operations; a search uses one */

typedef struct {
  WxOpenMeteoGeocoder *geo;
  Fake *fake;
  guint n;             /* queued cases of the current window */
  guint64 outcomes[3]; /* cases per SEARCH_* outcome so far */
  char *text[SWEEP_WINDOW];
  int kind[SWEEP_WINDOW];
  char *path[SWEEP_WINDOW];
  Op op[SWEEP_WINDOW];
} Sweep;

static void
sweep_init(Sweep *s, Fake *fake, WxOpenMeteoGeocoder *geo)
{
  memset(s, 0, sizeof *s);
  s->fake = fake;
  s->geo = geo;
}

static gboolean
on_sweep_timeout(gpointer data)
{
  *(gboolean *)data = TRUE;
  return G_SOURCE_REMOVE;
}

/* Runs the queued searches concurrently and checks, for each: the callback ran exactly once, the outcome is the
 * oracle's (EMPTY: 0 hits and no error; INVALID: WX_ERROR_INVALID_ARG "unacceptable search text" and no hits;
 * REQUEST: no error), and the server saw exactly one request per REQUEST case with exactly the oracle's path and
 * none for the others. */
static void
sweep_flush(Sweep *s)
{
  if (s->n == 0)
    return;
  g_ptr_array_set_size(s->fake->paths, 0);
  g_ptr_array_set_size(s->fake->heads, 0);
  guint before = s->fake->requests, want = 0;
  for (guint i = 0; i < s->n; i++) {
    if (s->kind[i] == SEARCH_REQUEST)
      want++;
    search_start(s->geo, s->text[i], NULL, &s->op[i]);
  }
  gboolean timed_out = FALSE;
  GSource *timer = g_timeout_source_new_seconds(60);
  g_source_set_callback(timer, on_sweep_timeout, &timed_out, NULL);
  g_source_attach(timer, NULL);
  for (;;) {
    gboolean all = TRUE;
    for (guint i = 0; i < s->n; i++)
      all = all && s->op[i].done;
    if (all || timed_out)
      break;
    g_main_context_iteration(NULL, TRUE);
  }
  g_source_destroy(timer);
  g_source_unref(timer);
  for (guint i = 0; i < s->n; i++) {
    Op *op = &s->op[i];
    g_autofree char *what = describe_bytes(s->text[i]);
    const char *got = op->error != NULL ? op->error->message : (op->places != NULL ? "hits" : "nothing");
    if (!op->done || op->calls != 1)
      g_error("bytes %s: callback done=%d calls=%u", what, op->done, op->calls);
    switch (s->kind[i]) {
    case SEARCH_EMPTY:
      if (op->error != NULL || op->places == NULL || op->places->len != 0)
        g_error("bytes %s: expected an empty result, got %s", what, got);
      break;
    case SEARCH_INVALID:
      if (op->error == NULL || !g_error_matches(op->error, WX_ERROR, WX_ERROR_INVALID_ARG) ||
          strcmp(op->error->message, "unacceptable search text") != 0 || op->places != NULL)
        g_error("bytes %s: expected INVALID_ARG 'unacceptable search text', got %s", what, got);
      break;
    default:
      if (op->error != NULL || op->places == NULL)
        g_error("bytes %s: expected a request and a result, got %s", what, got);
      break;
    }
  }
  if (s->fake->requests - before != want || s->fake->paths->len != want)
    g_error("window of %u: %u requests seen, %u expected", s->n, s->fake->requests - before, want);
  for (guint i = 0; i < s->n; i++) {
    if (s->kind[i] != SEARCH_REQUEST)
      continue;
    guint expect = 0, seen = 0;
    for (guint j = 0; j < s->n; j++)
      expect += s->kind[j] == SEARCH_REQUEST && strcmp(s->path[j], s->path[i]) == 0;
    for (guint j = 0; j < s->fake->paths->len; j++)
      seen += strcmp(g_ptr_array_index(s->fake->paths, j), s->path[i]) == 0;
    if (seen != expect) {
      g_autofree char *what = describe_bytes(s->text[i]);
      g_error("bytes %s: path %s seen %u times, expected %u", what, s->path[i], seen, expect);
    }
  }
  for (guint i = 0; i < s->n; i++) {
    g_clear_pointer(&s->text[i], g_free);
    g_clear_pointer(&s->path[i], g_free);
    op_clear(&s->op[i]);
  }
  s->n = 0;
}

/* Queues one search; its expected outcome comes from the oracle. */
static void
sweep_add(Sweep *s, const char *text)
{
  char *path = NULL;
  int kind = oracle_search((const guchar *)text, strlen(text), &path);
  s->text[s->n] = g_strdup(text);
  s->kind[s->n] = kind;
  s->path[s->n] = path;
  s->n++;
  s->outcomes[kind]++;
  if (s->n == SWEEP_WINDOW)
    sweep_flush(s);
}

/* The Unicode scalar value @c in the templates 'ab' c 'cd' (is a forbidden character fatal anywhere in the
 * text), c c (is it white space), c alone (the length rule counts bytes) and c with trim padding on both sides. */
static void
sweep_scalar(Sweep *s, guint32 c)
{
  char u[8];
  gint n = g_unichar_to_utf8(c, u);
  u[n] = '\0';
  g_autofree char *inner = g_strconcat("ab", u, "cd", NULL);
  g_autofree char *twice = g_strconcat(u, u, NULL);
  g_autofree char *padded = g_strconcat("  \t", u, "\n  ", NULL);
  sweep_add(s, inner);
  sweep_add(s, twice);
  sweep_add(s, u);
  sweep_add(s, padded);
}

/* Queues every Unicode scalar value of [first, last] (surrogates and U+0000 skipped). */
static void
sweep_scalar_range(Sweep *s, guint32 first, guint32 last)
{
  for (guint32 c = first; c <= last; c++)
    if (c != 0 && !(c >= 0xD800 && c <= 0xDFFF))
      sweep_scalar(s, c);
}

/* Queues the raw bytes @seq of length @n between 'ab' and 'cd' (no byte of @seq may be 0). */
static void
sweep_raw(Sweep *s, const guint8 *seq, gsize n)
{
  GString *t = g_string_new("ab");
  g_string_append_len(t, (const char *)seq, (gssize)n);
  g_string_append(t, "cd");
  sweep_add(s, t->str);
  g_string_free(t, TRUE);
}

static gboolean
exhaustive_enabled(void)
{
  return g_test_slow() || g_getenv("WX_TEST_EXHAUSTIVE") != NULL;
}

/* ------------------------------------------------------------------------ */
/* Search-text tests                                                        */
/* ------------------------------------------------------------------------ */

static void
test_net_geocoder_text_validation(void)
{
  g_autofree char *at_max = g_strnfill(WX_OPEN_METEO_SEARCH_MAX_BYTES, 'a');
  g_autofree char *over_max = g_strnfill(WX_OPEN_METEO_SEARCH_MAX_BYTES + 1, 'a');
  g_autofree char *padded = g_strdup_printf("   %s   ", at_max); /* trimming happens first */
  g_autofree char *padded_over = g_strdup_printf("  %s  ", over_max);
  GString *wide = g_string_new(NULL);
  for (guint i = 0; i < 32; i++)
    g_string_append(wide, "\xc3\xa9"); /* 64 bytes, 32 characters */
  GString *wide_over = g_string_new(wide->str);
  g_string_append(wide_over, "\xc3\xa9");
  static const struct {
    const char *text;
    int kind;
  } cases[] = {
      /* trimmed away or a single byte: EMPTY, whatever the byte is */
      {"", SEARCH_EMPTY}, {" ", SEARCH_EMPTY}, {"a", SEARCH_EMPTY}, {"  a  ", SEARCH_EMPTY},
      {"\n\t", SEARCH_EMPTY}, {"\t\n", SEARCH_EMPTY}, {" \t\n\v\f\r ", SEARCH_EMPTY}, {"\v", SEARCH_EMPTY},
      {"\x01", SEARCH_EMPTY}, {"\xff", SEARCH_EMPTY}, {" \x7f ", SEARCH_EMPTY},
      /* ordinary text: a request */
      {"ab", SEARCH_REQUEST}, {"  ab  ", SEARCH_REQUEST}, {"a b", SEARCH_REQUEST},
      {"Paris", SEARCH_REQUEST}, {"S\xc3\xa3o Paulo", SEARCH_REQUEST},
      /* white space that is not trimmed: space separators only (step 3 d) */
      {"\xc2\xa0", SEARCH_INVALID}, {"\xe3\x80\x80", SEARCH_INVALID}, {"  \xe3\x80\x80  ", SEARCH_INVALID},
      {"\xc2\xa0\xc2\xa0", SEARCH_INVALID}, {"\xe2\x80\x83\xe2\x80\x83", SEARCH_INVALID},
      {"\xe3\x80\x80 \xc2\xa0", SEARCH_INVALID}, {"\xc2\xa0" "a", SEARCH_REQUEST},
      /* invalid UTF-8 (step 3 b) */
      {"\xff\xfe", SEARCH_INVALID}, {"a\xffz", SEARCH_INVALID}, {"ab\xed\xa0\x80", SEARCH_INVALID},
      {"ab\xf4\x90\x80\x80", SEARCH_INVALID}, {"ab\xc0\xaf", SEARCH_INVALID},
      /* ASCII controls anywhere, also in the middle (step 3 c) */
      {"ab\x01", SEARCH_INVALID}, {"a\x01" "b", SEARCH_INVALID}, {"ab\x7f", SEARCH_INVALID},
      {"a\tb", SEARCH_INVALID}, {"a\nb", SEARCH_INVALID}, {"a\vb", SEARCH_INVALID}, {"\vParis", SEARCH_INVALID},
      /* C1 controls */
      {"ab\xc2\x80", SEARCH_INVALID}, {"ab\xc2\x85" "cd", SEARCH_INVALID}, {"ab\xc2\x9f", SEARCH_INVALID},
      /* line and paragraph separators U+2028 / U+2029 (step 3 c), at the end, inside and alone */
      {"ab\xe2\x80\xa8", SEARCH_INVALID}, {"ab\xe2\x80\xa9", SEARCH_INVALID},
      {"New\xe2\x80\xa8" "York", SEARCH_INVALID}, {"Paris\xe2\x80\xa8" "Texas", SEARCH_INVALID},
      {"Paris\xe2\x80\xa9" "Texas", SEARCH_INVALID}, {"ab\xe2\x80\xa8" "cd", SEARCH_INVALID},
      {"ab\xe2\x80\xa9" "cd", SEARCH_INVALID}, {"\xe2\x80\xa8\xe2\x80\xa8", SEARCH_INVALID},
      {"\xe2\x80\xa9\xe2\x80\xa9", SEARCH_INVALID},
      /* bidirectional formatting characters (step 3 c) */
      {"ab\xd8\x9c", SEARCH_INVALID}, {"ab\xe2\x80\x8e", SEARCH_INVALID}, {"ab\xe2\x80\x8f", SEARCH_INVALID},
      {"ab\xe2\x80\xae" "cd", SEARCH_INVALID}, {"ab\xe2\x81\xa6" "cd", SEARCH_INVALID},
      {"ab\xe2\x81\xa9" "cd", SEARCH_INVALID},
      /* neighbours of the forbidden characters are fine */
      {"ab\xd8\x9b", SEARCH_REQUEST}, {"ab\xd8\x9d", SEARCH_REQUEST}, {"ab\xe2\x80\x8d", SEARCH_REQUEST},
      {"ab\xe2\x80\xaf", SEARCH_REQUEST}, {"ab\xe2\x81\xa5", SEARCH_REQUEST}, {"ab\xe2\x81\xaa", SEARCH_REQUEST},
      {"ab\xe2\x80\xa7", SEARCH_REQUEST}, {"ab\xc2\xa0", SEARCH_REQUEST},
      /* text made only of format characters (Cf) is NOT detected: it is sent */
      {"\xe2\x80\x8b\xe2\x80\x8b", SEARCH_REQUEST}, {"\xef\xbb\xbf\xef\xbb\xbf", SEARCH_REQUEST},
      {"\xe2\x81\xa0\xe2\x81\xa0", SEARCH_REQUEST}, {"\xc2\xad\xc2\xad", SEARCH_REQUEST},
      {"\xe1\xa0\x8e\xe1\xa0\x8e", SEARCH_REQUEST}, {"\xe2\x80\x8c\xe2\x80\x8d", SEARCH_REQUEST},
      {"\xf3\xa0\x80\x81\xf3\xa0\x80\x81", SEARCH_REQUEST}, {"\xe2\x80\x8b", SEARCH_REQUEST},
      {"\xe2\x80\x8b \xe2\x80\x8b", SEARCH_REQUEST},
  };
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  guint expected_requests = 0;
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    /* The table and the oracle (the header's lists) must agree before the runtime is asked. */
    g_autofree char *oracle_path = NULL;
    if (oracle_search((const guchar *)cases[i].text, strlen(cases[i].text), &oracle_path) != cases[i].kind)
      g_error("case %u (%s): the table disagrees with the oracle", i, cases[i].text);
    Op op = {0};
    search_start(geo, cases[i].text, NULL, &op);
    g_assert_false(op.done);
    op_wait(&op);
    if (cases[i].kind == SEARCH_EMPTY) {
      g_assert_no_error(op.error);
      g_assert_nonnull(op.places);
      g_assert_cmpuint(op.places->len, ==, 0);
    } else if (cases[i].kind == SEARCH_INVALID) {
      if (op.error == NULL || !g_error_matches(op.error, WX_ERROR, WX_ERROR_INVALID_ARG))
        g_error("case %u (%s): %s", i, cases[i].text, op.error != NULL ? op.error->message : "no error");
      g_assert_cmpstr(op.error->message, ==, "unacceptable search text");
      g_assert_null(op.places);
    } else {
      g_assert_no_error(op.error);
      expected_requests++;
      g_assert_cmpstr(g_ptr_array_index(fake->paths, expected_requests - 1), ==, oracle_path);
    }
    g_assert_cmpuint(fake->requests, ==, expected_requests);
    op_clear(&op);
  }
  /* The byte limits (after trimming): 64 passes, 65 does not; characters do not matter, bytes do. */
  const char *limit_texts[] = {at_max, padded, wide->str, over_max, padded_over, wide_over->str};
  for (guint i = 0; i < G_N_ELEMENTS(limit_texts); i++) {
    Op op = {0};
    search_start(geo, limit_texts[i], NULL, &op);
    op_wait(&op);
    if (i < 3) {
      g_assert_no_error(op.error);
      expected_requests++;
    } else {
      g_assert_error(op.error, WX_ERROR, WX_ERROR_INVALID_ARG);
      g_assert_cmpstr(op.error->message, ==, "unacceptable search text");
    }
    g_assert_cmpuint(fake->requests, ==, expected_requests);
    op_clear(&op);
  }
  g_string_free(wide, TRUE);
  g_string_free(wide_over, TRUE);
  fake_free(fake);
}

static void
test_net_geocoder_every_byte(void)
{
  /* The trimmed set is asserted at runtime, not assumed from the GLib documentation. */
  for (int c = 0; c < 256; c++)
    g_assert_cmpint(g_ascii_isspace((guchar)c) ? 1 : 0, ==, oracle_is_trim_byte((guchar)c) ? 1 : 0);
  g_assert_false(g_ascii_isspace('\v'));

  /* Every byte 1..255 (0 cannot be in a C string) as pre + copies * byte + post: raw, doubled, "ab"-padded,
   * space-padded and padded with every trim byte. */
  static const struct {
    const char *pre;
    guint copies;
    const char *post;
  } templates[] = {
      {"", 1, ""},           {"", 2, ""},           {"ab", 1, ""},         {"", 1, "ab"},
      {" ", 1, " "},         {" ", 2, " "},         {"ab", 1, "ab"},       {"\t\n\f\r ", 1, " \r\f\n\t"},
      {" \t", 2, "\n "},     {"a", 1, ""},          {"", 1, "a"},          {" ", 1, "b"},
  };
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  for (int byte = 1; byte < 256; byte++) {
    for (guint t = 0; t < G_N_ELEMENTS(templates); t++) {
      GString *text = g_string_new(templates[t].pre);
      for (guint k = 0; k < templates[t].copies; k++)
        g_string_append_c(text, (char)byte);
      g_string_append(text, templates[t].post);
      sweep_add(&sweep, text->str);
      g_string_free(text, TRUE);
    }
  }
  sweep_flush(&sweep);
  /* The sweep exercised all three outcomes (including \v cases that are not trimmed). */
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 0);
  /* Pinned examples of the reported class. */
  static const struct {
    const char *text;
    int kind;
  } pinned[] = {{"\v\v", SEARCH_INVALID},     {" \v\v ", SEARCH_INVALID}, {"\vParis", SEARCH_INVALID},
                {"Paris\v", SEARCH_INVALID},  {"\v", SEARCH_EMPTY},       {" \v ", SEARCH_EMPTY},
                {"Pa\vris", SEARCH_INVALID}};
  for (guint i = 0; i < G_N_ELEMENTS(pinned); i++) {
    g_autofree char *p = NULL;
    g_assert_cmpint(oracle_search((const guchar *)pinned[i].text, strlen(pinned[i].text), &p), ==, pinned[i].kind);
    guint before = fake->requests;
    Op op = {0};
    search_start(geo, pinned[i].text, NULL, &op);
    op_wait(&op);
    if (pinned[i].kind == SEARCH_EMPTY)
      g_assert_no_error(op.error);
    else
      g_assert_error(op.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpuint(fake->requests, ==, before);
    op_clear(&op);
  }
  fake_free(fake);
}

/*
 * The default run: every code point of every class the header names (forbidden, space separators, the format
 * characters of the "not detected" sentence), the first / last code point of each class and its two neighbours on
 * each side, and a representative spread of everything else (printable ASCII, letters, combining marks,
 * unassigned, private-use and non-characters, the ends of every UTF-8 length, the astral planes), each in the
 * four templates of sweep_scalar() through the public API. EVERY code point of Unicode goes through the same
 * templates in test_net_geocoder_scalar_sweep_exhaustive() (-m slow or WX_TEST_EXHAUSTIVE=1), and every code
 * point is checked against the header's lists in test_geocoder_header_lists_match_runtime() in every run.
 */
static void
test_net_geocoder_scalar_classes(void)
{
  static const struct {
    guint32 first, last;
  } classes[] = {
      /* forbidden (step 3 c) */
      {0x01, 0x1F}, {0x7F, 0x9F}, {0x2028, 0x2029}, {0x061C, 0x061C}, {0x200E, 0x200F}, {0x202A, 0x202E},
      {0x2066, 0x2069},
      /* space separators (step 3 d) */
      {0x20, 0x20}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A}, {0x202F, 0x202F}, {0x205F, 0x205F},
      {0x3000, 0x3000},
      /* format characters: not detected */
      {0xAD, 0xAD}, {0x600, 0x605}, {0x180E, 0x180E}, {0x200B, 0x200D}, {0x2060, 0x2064}, {0xFEFF, 0xFEFF},
      {0xFFF9, 0xFFFB}, {0xE0001, 0xE0001}, {0xE0020, 0xE007F},
      /* printable ASCII, the ends of each UTF-8 length, the astral planes, the ends of the surrogate gap */
      {0x21, 0x7E}, {0x80, 0x80}, {0x7FF, 0x800}, {0xD7FE, 0xD7FF}, {0xE000, 0xE001}, {0xFFFC, 0xFFFF},
      {0x10000, 0x10001}, {0x1F600, 0x1F602}, {0x1FFFE, 0x1FFFF}, {0xE0000, 0xE0000}, {0xF0000, 0xF0001},
      {0x10FFFC, 0x10FFFF},
      /* letters and marks, non-characters, unassigned and private use */
      {0xC0, 0xC2}, {0xE9, 0xE9}, {0x300, 0x302}, {0x378, 0x379}, {0x5D0, 0x5D2}, {0x4E00, 0x4E01},
      {0xAC00, 0xAC01}, {0xF8FF, 0xF8FF}, {0xFDD0, 0xFDD1}, {0xFFFD, 0xFFFD},
  };
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  for (guint i = 0; i < G_N_ELEMENTS(classes); i++) {
    guint32 first = classes[i].first, last = classes[i].last;
    sweep_scalar_range(&sweep, first >= 3 ? first - 2 : 1, first - 1); /* two neighbours below ... */
    sweep_scalar_range(&sweep, first, last);                           /* ... every member ... */
    sweep_scalar_range(&sweep, last + 1, last + 2 > 0x10FFFF ? 0x10FFFF : last + 2); /* ... two above */
  }
  sweep_flush(&sweep);
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 0);
  fake_free(fake);
}

/* Every Unicode scalar value in the four templates, then every raw byte sequence that cannot be a character. */
static void
test_net_geocoder_scalar_sweep_exhaustive(void)
{
  if (!exhaustive_enabled()) {
    g_test_skip("exhaustive sweep: run with -m slow or WX_TEST_EXHAUSTIVE=1");
    return;
  }
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  sweep_scalar_range(&sweep, 1, 0x10FFFF);
  sweep_flush(&sweep);
  /* 1,112,063 scalar values (U+0000 excluded) x 4 templates, and the oracle expected all three outcomes. */
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY] + sweep.outcomes[SEARCH_INVALID] + sweep.outcomes[SEARCH_REQUEST],
                   ==, 4u * 1112063u);
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 0);
  g_test_message("scalar sweep: %" G_GUINT64_FORMAT " empty, %" G_GUINT64_FORMAT " invalid, %" G_GUINT64_FORMAT
                 " requests",
                 sweep.outcomes[SEARCH_EMPTY], sweep.outcomes[SEARCH_INVALID], sweep.outcomes[SEARCH_REQUEST]);

  /* Raw byte sequences (step 3 b), between 'ab' and 'cd': every 2-byte pair with a high first byte, every 3-byte
   * sequence and every 4-byte one over the continuation range that the oracle's own decoder refuses (overlong,
   * surrogate, above U+10FFFF, bad continuation), the edge values of the 4-byte families, and the 5- and 6-byte
   * forms of the old UTF-8. The valid ones are in the scalar sweep above. */
  guint64 invalid_before = sweep.outcomes[SEARCH_INVALID];
  for (guint b1 = 0x80; b1 <= 0xFF; b1++)
    for (guint b2 = 0x01; b2 <= 0xFF; b2++) {
      const guint8 seq[2] = {(guint8)b1, (guint8)b2};
      sweep_raw(&sweep, seq, 2);
    }
  for (guint b1 = 0xE0; b1 <= 0xEF; b1++)
    for (guint b2 = 0x80; b2 <= 0xFF; b2++)
      for (guint b3 = 0x80; b3 <= 0xFF; b3++) {
        const guint8 seq[3] = {(guint8)b1, (guint8)b2, (guint8)b3};
        guint32 c = 0;
        if (oracle_utf8_decode(seq, 3, &c) == 0)
          sweep_raw(&sweep, seq, 3);
      }
  for (guint b1 = 0xF0; b1 <= 0xF7; b1++)
    for (guint b2 = 0x80; b2 <= 0xBF; b2++)
      for (guint b3 = 0x80; b3 <= 0xBF; b3++)
        for (guint b4 = 0x80; b4 <= 0xBF; b4 += (b1 == 0xF0 || b1 == 0xF4) ? 1 : 0x3F) {
          const guint8 seq[4] = {(guint8)b1, (guint8)b2, (guint8)b3, (guint8)b4};
          guint32 c = 0;
          if (oracle_utf8_decode(seq, 4, &c) == 0)
            sweep_raw(&sweep, seq, 4);
        }
  static const guint edge[] = {0x01, 0x7F, 0x80, 0x8F, 0x90, 0xBF, 0xC0, 0xC2, 0xFF};
  for (guint b1 = 0xF0; b1 <= 0xFF; b1++)
    for (guint i = 0; i < G_N_ELEMENTS(edge); i++)
      for (guint j = 0; j < G_N_ELEMENTS(edge); j++)
        for (guint k = 0; k < G_N_ELEMENTS(edge); k++) {
          const guint8 seq[4] = {(guint8)b1, (guint8)edge[i], (guint8)edge[j], (guint8)edge[k]};
          guint32 c = 0;
          if (oracle_utf8_decode(seq, 4, &c) == 0)
            sweep_raw(&sweep, seq, 4);
        }
  static const guint8 legacy5[] = {0xF8, 0x88, 0x80, 0x80, 0x80};
  static const guint8 legacy6[] = {0xFC, 0x84, 0x80, 0x80, 0x80, 0x80};
  sweep_raw(&sweep, legacy5, sizeof legacy5);
  sweep_raw(&sweep, legacy6, sizeof legacy6);
  sweep_flush(&sweep);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID] - invalid_before, >, 400000);
  fake_free(fake);
}

/* The edges of every UTF-8 length class, valid and invalid (default run). */
static void
test_net_geocoder_utf8_edges(void)
{
  static const struct {
    guint8 len;
    guint8 b[6];
  } pats[] = {
      /* overlong, surrogate, out of range, legacy lengths, stray and truncated: invalid */
      {2, {0xC0, 0x80}}, {2, {0xC0, 0xAF}}, {2, {0xC1, 0xBF}}, {3, {0xE0, 0x80, 0x80}}, {3, {0xE0, 0x9F, 0xBF}},
      {3, {0xED, 0xA0, 0x80}}, {3, {0xED, 0xAD, 0xBF}}, {3, {0xED, 0xBF, 0xBF}}, {4, {0xF0, 0x80, 0x80, 0x80}},
      {4, {0xF0, 0x8F, 0xBF, 0xBF}}, {4, {0xF4, 0x90, 0x80, 0x80}}, {4, {0xF4, 0xBF, 0xBF, 0xBF}},
      {4, {0xF5, 0x80, 0x80, 0x80}}, {4, {0xF7, 0xBF, 0xBF, 0xBF}}, {5, {0xF8, 0x88, 0x80, 0x80, 0x80}},
      {6, {0xFC, 0x84, 0x80, 0x80, 0x80, 0x80}}, {1, {0x80}}, {1, {0xBF}}, {1, {0xC2}}, {2, {0xE2, 0x80}},
      {3, {0xF0, 0x9F, 0x98}}, {1, {0xFE}}, {1, {0xFF}}, {2, {0xC2, 0x41}}, {3, {0xE2, 0x80, 0x41}},
      {4, {0xF0, 0x9F, 0x98, 0x41}},
      /* the valid neighbours of those forms */
      {2, {0xC2, 0xA1}}, {2, {0xDF, 0xBF}}, {3, {0xE0, 0xA0, 0x80}}, {3, {0xED, 0x9F, 0xBF}},
      {3, {0xEE, 0x80, 0x80}}, {3, {0xEF, 0xBF, 0xBD}}, {3, {0xEF, 0xBF, 0xBE}}, {4, {0xF0, 0x90, 0x80, 0x80}},
      {4, {0xF4, 0x8F, 0xBF, 0xBF}},
  };
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  for (guint i = 0; i < G_N_ELEMENTS(pats); i++) {
    GString *t = g_string_new(NULL);
    g_string_append_len(t, (const char *)pats[i].b, pats[i].len);
    g_autofree char *pad = g_strconcat("  ", t->str, "  ", NULL);
    g_autofree char *both = g_strconcat("ab", t->str, "cd", NULL);
    g_autofree char *left = g_strconcat("ab", t->str, NULL);
    g_autofree char *right = g_strconcat(t->str, "cd", NULL);
    sweep_add(&sweep, t->str);
    sweep_add(&sweep, pad);
    sweep_add(&sweep, both);
    sweep_add(&sweep, left);
    sweep_add(&sweep, right);
    g_string_free(t, TRUE);
  }
  sweep_flush(&sweep);
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 0);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 0);
  fake_free(fake);
}

/* The 64-byte limit counts bytes, at every character width, with and without trim padding. */
static void
test_net_geocoder_byte_limit_by_width(void)
{
  static const guint32 samples[4] = {'a', 0xE9, 0x4E2D, 0x1F600}; /* 1, 2, 3 and 4 bytes */
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  for (guint w = 1; w <= 4; w++)
    for (guint fill = 0; fill < w; fill++) /* 'a' bytes before the run, so every total is reached */
      for (guint k = 1; fill + k * w <= 72; k++) {
        GString *t = g_string_new(NULL);
        for (guint i = 0; i < fill; i++)
          g_string_append_c(t, 'a');
        for (guint i = 0; i < k; i++)
          g_string_append_unichar(t, samples[w - 1]);
        guint bytes = (guint)t->len;
        if (bytes >= 56) {
          g_autofree char *padded = g_strconcat(" \t ", t->str, " \r\n", NULL);
          /* explicit expectation, independent of the oracle: up to 64 bytes is searched, more is refused */
          char *p1 = NULL, *p2 = NULL;
          int want = bytes <= 64 ? SEARCH_REQUEST : SEARCH_INVALID;
          g_assert_cmpint(oracle_search((const guchar *)t->str, t->len, &p1), ==, want);
          g_assert_cmpint(oracle_search((const guchar *)padded, strlen(padded), &p2), ==, want);
          g_free(p1);
          g_free(p2);
          sweep_add(&sweep, t->str);
          sweep_add(&sweep, padded);
        }
        g_string_free(t, TRUE);
      }
  sweep_flush(&sweep);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 20);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 20);
  fake_free(fake);
}

/* Random texts from fragments of every kind, against the oracle. */
static void
test_net_geocoder_differential_fuzz(void)
{
  static const guint32 interesting[] = {0x01, 0x09, 0x0B, 0x1F, 0x7F, 0x80, 0x85, 0x9F, 0xA0, 0xAD, 0x61C, 0x1680,
                                        0x2000, 0x200A, 0x200B, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A,
                                        0x202E, 0x202F, 0x205F, 0x2060, 0x2066, 0x2069, 0x3000, 0xFEFF, 0xFFFD,
                                        0xE0001, 0x10FFFF, 0x1F600, 0x4E2D, 0xE9};
  static const char trim[] = " \t\n\f\r";
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  Sweep sweep;
  sweep_init(&sweep, fake, geo);
  GRand *rng = g_rand_new_with_seed(0x5ea5c);
  for (guint round = 0; round < 6000; round++) {
    GString *t = g_string_new(NULL);
    guint parts = (guint)g_rand_int_range(rng, 0, 14);
    for (guint i = 0; i < parts; i++) {
      switch (g_rand_int_range(rng, 0, 10)) {
      case 0:
      case 1:
      case 2:
        g_string_append_c(t, (char)g_rand_int_range(rng, 'a', 'z' + 1));
        break;
      case 3:
        g_string_append_c(t, trim[g_rand_int_range(rng, 0, 5)]);
        break;
      case 4:
        g_string_append_c(t, (char)g_rand_int_range(rng, 0x80, 0x100)); /* a raw high byte */
        break;
      case 5:
        g_string_append_c(t, (char)g_rand_int_range(rng, 0x01, 0x20)); /* a raw control byte */
        break;
      case 6:
      case 7:
        g_string_append_unichar(t, interesting[g_rand_int_range(rng, 0, G_N_ELEMENTS(interesting))]);
        break;
      case 8: {
        guint32 c = (guint32)g_rand_int_range(rng, 0x21, 0x110000);
        g_string_append_unichar(t, (c >= 0xD800 && c <= 0xDFFF) ? 'x' : c);
        break;
      }
      default:
        g_string_append(t, "ab");
        break;
      }
    }
    sweep_add(&sweep, t->str);
    g_string_free(t, TRUE);
  }
  sweep_flush(&sweep);
  g_rand_free(rng);
  g_assert_cmpuint(sweep.outcomes[SEARCH_EMPTY], >, 100);
  g_assert_cmpuint(sweep.outcomes[SEARCH_INVALID], >, 100);
  g_assert_cmpuint(sweep.outcomes[SEARCH_REQUEST], >, 100);
  fake_free(fake);
}

static void
test_net_geocoder_failures(void)
{
  static const struct {
    Reply reply;
    int code;
    const char *message;
  } cases[] = {
      {{R_REPLY, 404, "{}", FALSE, 0}, WX_ERROR_NOT_FOUND, NULL},
      {{R_REPLY, 429, "{}", FALSE, 0}, WX_ERROR_RATE_LIMITED, NULL},
      {{R_REPLY, 400, "{\"error\":true,\"reason\":\"x\"}", FALSE, 0}, WX_ERROR_HTTP, NULL},
      {{R_REPLY, 500, "{}", FALSE, 0}, WX_ERROR_HTTP, NULL},
      {{R_REPLY, 302, "{}", FALSE, 0}, WX_ERROR_HTTP, NULL},
      {{R_REPLY, 200, "not json", FALSE, 0}, WX_ERROR_PARSE, NULL},
      {{R_REPLY, 200, "", FALSE, 0}, WX_ERROR_PARSE, NULL},
      {{R_REPLY, 200, "[]", FALSE, 0}, WX_ERROR_PARSE, NULL},
      {{R_REPLY, 200, "{\"results\":\"x\"}", FALSE, 0}, WX_ERROR_PARSE, "unexpected search response shape"},
      {{R_REPLY, 200, "{\"error\":true,\"reason\":\"Rate\"}", FALSE, 0}, WX_ERROR_HTTP, "Open-Meteo reported an error: Rate"},
      {{R_CLOSE, 0, NULL, FALSE, 0}, WX_ERROR_NETWORK, NULL},
      {{R_CUT, 200, "{\"results\":", FALSE, 0}, WX_ERROR_NETWORK, NULL},
      {{R_HANG, 0, NULL, FALSE, 0}, WX_ERROR_TIMEOUT, NULL},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Script script = script_ok();
    script.geo = cases[i].reply;
    Fake *fake = fake_new(&script);
    g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 250, 5);
    Op op = {0};
    search_start(geo, "Miami", NULL, &op);
    op_wait(&op);
    if (op.places != NULL || op.error == NULL || op.error->domain != WX_ERROR || op.error->code != cases[i].code)
      g_error("case %u: error=%s", i, op.error != NULL ? op.error->message : "(none)");
    if (cases[i].message != NULL)
      g_assert_cmpstr(op.error->message, ==, cases[i].message);
    op_clear(&op);
    fake_free(fake);
  }
  /* A body without results is a success with no place. */
  Script script = script_ok();
  script.geo.body = "{\"generationtime_ms\":0.7}";
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 5);
  Op op = {0};
  search_start(geo, "Nowhereville", NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_cmpuint(op.places->len, ==, 0);
  op_clear(&op);
  fake_free(fake);
}

static void
test_net_geocoder_cancel_and_lifecycle(void)
{
  Script script = script_ok();
  script.geo.kind = R_HANG;
  Fake *fake = fake_new(&script);
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 10000, 10);
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  Op op = {0};
  search_start(geo, "Miami", cancel, &op);
  g_timeout_add(150, cancel_later, cancel);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpint(elapsed_ms(&op), <, 3000);
  op_clear(&op);
  /* already cancelled: no request */
  guint before = fake->requests;
  search_start(geo, "Miami", cancel, &op);
  g_assert_false(op.done);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  spin_ms(50);
  g_assert_cmpuint(fake->requests, ==, before);
  op_clear(&op);
  fake_free(fake);

  /* cancelled in the callback, before finish: the cancellation wins over the result */
  Script ok = script_ok();
  Fake *fake2 = fake_new(&ok);
  WxOpenMeteoGeocoder *geo2 = geocoder_for(fake2, 5000, 10);
  g_autoptr(GCancellable) cancel2 = g_cancellable_new();
  op.cancel_first = cancel2;
  search_start(geo2, "Miami", cancel2, &op);
  op_wait(&op);
  g_assert_error(op.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  op_clear(&op);
  /* the object dropped in flight */
  ok.geo.delay_ms = 200;
  fake2->script = ok;
  search_start(geo2, "Miami", NULL, &op);
  g_object_unref(geo2);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_cmpuint(op.places->len, ==, 10);
  op_clear(&op);
  fake_free(fake2);
}

static void
test_net_geocoder_registry(void)
{
  Script script = script_ok();
  Fake *fake = fake_new(&script);
  g_autoptr(WxRegistry) reg = wx_registry_new();
  g_autoptr(WxOpenMeteoGeocoder) geo = geocoder_for(fake, 5000, 10);
  wx_registry_set_geocoder(reg, WX_GEOCODER(geo));
  Op op = {0};
  search_start(WX_OPEN_METEO_GEOCODER(wx_registry_get_geocoder(reg)), "Miami", NULL, &op);
  op_wait(&op);
  g_assert_no_error(op.error);
  g_assert_cmpuint(op.places->len, ==, 10);
  op_clear(&op);
  fake_free(fake);
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
      remove_tree(child);
    }
    g_dir_close(dir);
  }
  (void)g_remove(path);
}

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  if (argc != 2) {
    g_printerr("usage: test-openmeteo FIXTURE_DIR\n");
    return 1;
  }
  fixture_dir = argv[1];
  /* Loopback traffic must never go through a user's proxy; library messages stay untranslated. */
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  g_setenv("LANGUAGE", "C", TRUE);
  (void)setlocale(LC_ALL, "C");
  /* Never touch the user's real XDG directories. */
  g_autoptr(GError) error = NULL;
  g_autofree char *root = g_dir_make_tmp("wx-openmeteo-test-XXXXXX", &error);
  if (root == NULL) {
    g_printerr("cannot create the temporary root: %s\n", error->message);
    abort();
  }
  static const char *const xdg[] = {"XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                                    "XDG_RUNTIME_DIR"};
  for (guint i = 0; i < G_N_ELEMENTS(xdg); i++) {
    g_autofree char *dir = g_build_filename(root, xdg[i], NULL);
    if (g_mkdir_with_parents(dir, 0700) != 0 || !g_setenv(xdg[i], dir, TRUE))
      abort();
  }

  g_test_add_func("/openmeteo/parse/miami-fixture", test_parse_miami_fixture);
  g_test_add_func("/openmeteo/parse/london-fixture", test_parse_london_fixture);
  g_test_add_func("/openmeteo/parse/single-model-keys", test_parse_single_model_keys_are_not_suffixed);
  g_test_add_func("/openmeteo/parse/nowcast-fixture", test_parse_nowcast_fixture);
  g_test_add_func("/openmeteo/parse/geocode-fixture", test_parse_geocode_fixture);
  g_test_add_func("/openmeteo/parse/error-fixture", test_parse_error_fixture);
  g_test_add_func("/openmeteo/parse/bucket-times", test_parse_bucket_times);
  g_test_add_func("/openmeteo/parse/time-entries-skipped", test_parse_time_entries_skipped);
  g_test_add_func("/openmeteo/parse/time-step-limit", test_parse_time_step_limit);
  g_test_add_func("/openmeteo/parse/gapped-series-member-limit", test_parse_gapped_series_is_cut_at_member_limit);
  g_test_add_func("/openmeteo/parse/value-ranges", test_parse_value_ranges);
  g_test_add_func("/openmeteo/parse/negative-zero-subnormal", test_parse_negative_zero_and_subnormal);
  g_test_add_func("/openmeteo/parse/ragged-arrays", test_parse_ragged_arrays);
  g_test_add_func("/openmeteo/parse/dropped-models", test_parse_dropped_models);
  g_test_add_func("/openmeteo/parse/hostile-bodies", test_parse_hostile_bodies);
  g_test_add_func("/openmeteo/parse/programmer-errors", test_parse_programmer_errors_and_fetch_time);
  g_test_add_func("/openmeteo/parse/guard-pages", test_parse_guard_pages);
  g_test_add_func("/openmeteo/parse/nowcast-semantics", test_parse_nowcast_semantics);
  g_test_add_func("/openmeteo/parse/nowcast-errors", test_parse_nowcast_errors);
  g_test_add_func("/openmeteo/parse/geocode-shapes", test_parse_geocode_shapes);
  g_test_add_func("/openmeteo/parse/geocode-sanitising", test_parse_geocode_sanitising);
  g_test_add_func("/openmeteo/parse/geocode-optional-text-cleared", test_parse_geocode_optional_text_cleared);
  g_test_add_func("/openmeteo/parse/geocode-limits", test_parse_geocode_limits);
  g_test_add_func("/openmeteo/parse/geocode-hostile", test_parse_geocode_hostile);
  g_test_add_func("/openmeteo/parse/geocode-forbidden-sweep", test_parse_geocode_forbidden_sweep);
  g_test_add_func("/openmeteo/parse/geocode-whitespace-rules", test_parse_geocode_whitespace_rules);
  g_test_add_func("/openmeteo/parse/geocode-truncation", test_parse_geocode_truncation);
  g_test_add_func("/openmeteo/parse/geocode-country-code-rule", test_parse_geocode_country_code_rule);
  g_test_add_func("/openmeteo/parse/geocode-timezone-rule", test_parse_geocode_timezone_rule);
  g_test_add_func("/openmeteo/parse/error-reason-length", test_parse_error_reason_length);
  g_test_add_func("/openmeteo/parse/weather-code-rule", test_parse_weather_code_rule);
  g_test_add_func("/openmeteo/parse/differential-fuzz", test_parse_differential_fuzz);
  g_test_add_func("/openmeteo/parse/mutation-fuzz", test_parse_mutation_fuzz);

  g_test_add_func("/openmeteo/provider/metadata", test_provider_metadata);
  g_test_add_func("/openmeteo/provider/covers", test_provider_covers);
  g_test_add_func("/openmeteo/provider/registry", test_provider_registry);
  g_test_add_func("/openmeteo/provider/constructors", test_constructors_validate);
  g_test_add_func("/openmeteo/provider/programmer-errors", test_provider_finish_programmer_errors);

  g_test_add_func("/openmeteo/net/miami-success", test_net_miami_success);
  g_test_add_func("/openmeteo/net/london-success", test_net_london_success);
  g_test_add_func("/openmeteo/net/model-selection", test_net_model_selection);
  g_test_add_func("/openmeteo/net/locale-independent", test_net_locale_independent_coordinates);
  g_test_add_func("/openmeteo/net/request-shape", test_net_request_shape);
  g_test_add_func("/openmeteo/net/b-failure-tolerated", test_net_b_failure_is_tolerated);
  g_test_add_func("/openmeteo/net/b-hang-grace", test_net_b_hang_does_not_hold_the_result);
  g_test_add_func("/openmeteo/net/b-within-grace", test_net_b_slower_than_a_but_within_grace);
  g_test_add_func("/openmeteo/net/b-window-from-start", test_net_b_window_counts_from_fetch_start);
  g_test_add_func("/openmeteo/net/slot-lifetime-refill", test_net_slot_lifetime_refill);
  g_test_add_func("/openmeteo/net/a-failure", test_net_a_failure_fails_the_fetch);
  g_test_add_func("/openmeteo/net/a-failure-no-wait-for-b", test_net_a_failure_does_not_wait_for_b);
  g_test_add_func("/openmeteo/net/b-alone-not-enough", test_net_b_alone_is_not_enough);
  g_test_add_func("/openmeteo/net/invalid-places", test_net_invalid_places_make_no_request);
  g_test_add_func("/openmeteo/net/cancel-before-start", test_net_cancel_before_start);
  g_test_add_func("/openmeteo/net/cancel-during-a", test_net_cancel_during_a);
  g_test_add_func("/openmeteo/net/cancel-during-grace", test_net_cancel_during_grace);
  g_test_add_func("/openmeteo/net/cancel-before-finish", test_net_cancel_before_finish);
  g_test_add_func("/openmeteo/net/cancel-other-thread", test_net_cancel_from_another_thread);
  g_test_add_func("/openmeteo/net/cancellable-outlives", test_net_cancellable_outlives_the_fetch);
  g_test_add_func("/openmeteo/net/dispose-in-flight", test_net_dispose_in_flight);
  g_test_add_func("/openmeteo/net/concurrent-fetches", test_net_concurrent_fetches);
  g_test_add_func("/openmeteo/net/inflight-cap", test_net_inflight_cap);
  g_test_add_func("/openmeteo/net/inflight-cap-single-slot", test_net_inflight_cap_single_slot_fetches);
  g_test_add_func("/openmeteo/net/refused", test_net_refused_connection);

  g_test_add_func("/openmeteo/geocoder/success", test_net_geocoder_success);
  g_test_add_func("/openmeteo/geocoder/escaping", test_net_geocoder_escaping);
  g_test_add_func("/openmeteo/geocoder/text-validation", test_net_geocoder_text_validation);
  g_test_add_func("/openmeteo/geocoder/every-byte", test_net_geocoder_every_byte);
  g_test_add_func("/openmeteo/geocoder/header-lists-match-runtime", test_geocoder_header_lists_match_runtime);
  g_test_add_func("/openmeteo/geocoder/scalar-classes", test_net_geocoder_scalar_classes);
  g_test_add_func("/openmeteo/geocoder/utf8-edges", test_net_geocoder_utf8_edges);
  g_test_add_func("/openmeteo/geocoder/byte-limit-by-width", test_net_geocoder_byte_limit_by_width);
  g_test_add_func("/openmeteo/geocoder/differential-fuzz", test_net_geocoder_differential_fuzz);
  g_test_add_func("/openmeteo/geocoder/scalar-sweep-exhaustive", test_net_geocoder_scalar_sweep_exhaustive);
  g_test_add_func("/openmeteo/geocoder/failures", test_net_geocoder_failures);
  g_test_add_func("/openmeteo/geocoder/cancel-lifecycle", test_net_geocoder_cancel_and_lifecycle);
  g_test_add_func("/openmeteo/geocoder/registry", test_net_geocoder_registry);

  int status = g_test_run();
  remove_tree(root);
  return status;
}
