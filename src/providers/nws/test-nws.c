/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of the NWS provider: the two parsers over captured real responses (Miami,
 * fixtures/) and over hostile and randomised bodies (differential against an independent oracle),
 * and the provider against a loopback fake server (request shape, caches, 404 / 429 / 5xx,
 * truncation, timeout, cancellation, dispose in flight). Nothing here touches the Internet or the
 * user's XDG directories.
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

#include "wx-http.h"
#include "wx-nws-testing.h"
#include "wx-nws.h"
#include "wx-registry.h"
#include "wx-time.h"
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

/* 2026-10-12T12:00:00Z, the first hour of the Miami fixture. */
#define T0 G_GINT64_CONSTANT(1791806400)
#define HOUR 3600

#define MSG_NO_GRID "no valid forecast grid in response"
#define MSG_NO_PROPS "response has no properties"
#define MSG_NO_DATA "response has no usable forecast"
#define MSG_OUTSIDE "place is outside the NWS coverage"
#define MSG_BAD_PLACE "invalid place"

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

static GBytes *
fixture(const char *name)
{
  g_autofree char *path = g_build_filename(WX_NWS_FIXTURE_DIR, name, NULL);
  g_autoptr(GError) error = NULL;
  gchar *contents;
  gsize len;
  g_assert_true(g_file_get_contents(path, &contents, &len, &error));
  g_assert_no_error(error);
  return g_bytes_new_take(contents, len);
}

static WxPlace *
place_at(double lat, double lon)
{
  g_autoptr(GError) error = NULL;
  WxPlace *place = wx_place_new("Testville", "Florida", "United States", "US", lat, lon,
                                "America/New_York", &error);
  g_assert_no_error(error);
  g_assert_nonnull(place);
  return place;
}

static WxPlace *
miami(void)
{
  return place_at(25.7617, -80.1918);
}

static const WxHour *
hour_at(const WxMember *m, gint64 t)
{
  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  for (guint i = 0; i < n; i++)
    if (hours[i].t_s == t)
      return &hours[i];
  return NULL;
}

/* TRUE when a and b are the same double, NANs equal (so -0.0 != +0.0 is NOT distinguished). */
static gboolean
same_double(double a, double b)
{
  return (isnan(a) && isnan(b)) || a == b;
}

static void
assert_double_eq(double a, double b)
{
  if (!same_double(a, b)) {
    g_autofree char *message = g_strdup_printf("expected %.17g, got %.17g", b, a);
    g_assertion_message(G_LOG_DOMAIN, __FILE__, __LINE__, G_STRFUNC, message);
  }
}

/* The invariants wx_nws_parse_gridpoints() documents for every member it returns. */
static void
check_member(const WxMember *m)
{
  guint n, nq;
  const WxHour *hours = wx_member_get_hours(m, &n);
  wx_member_get_quarters(m, &nq);
  g_assert_cmpstr(wx_member_get_source_id(m), ==, "nws");
  g_assert_cmpstr(wx_member_get_model_id(m), ==, "nws");
  g_assert_cmpuint(n, >=, 1);
  g_assert_cmpuint(n, <=, WX_MEMBER_MAX_HOURS);
  g_assert_cmpuint(nq, ==, 0);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpint(hours[i].t_s % HOUR, ==, 0);
    if (i > 0)
      g_assert_cmpint(hours[i].t_s, >, hours[i - 1].t_s);
    g_assert_cmpint(hours[i].wmo, ==, -1);
    const WxHour *h = &hours[i];
    gboolean any = FALSE;
    const double v[] = {h->temp_c, h->feels_c, h->precip_mm, h->precip_prob,
                        h->cloud_pct, h->wind_kmh, h->gust_kmh, h->humidity_pct};
    for (guint k = 0; k < G_N_ELEMENTS(v); k++)
      any = any || isfinite(v[k]);
    g_assert_true(any);
    g_assert_true(wx_value_in_range(h->temp_c, WX_TEMP_MIN_C, WX_TEMP_MAX_C) || isnan(h->temp_c));
    g_assert_true(wx_value_in_range(h->feels_c, WX_TEMP_MIN_C, WX_TEMP_MAX_C) || isnan(h->feels_c));
    g_assert_true(wx_value_in_range(h->wind_kmh, 0, WX_WIND_MAX_KMH) || isnan(h->wind_kmh));
    g_assert_true(wx_value_in_range(h->gust_kmh, 0, WX_WIND_MAX_KMH) || isnan(h->gust_kmh));
    g_assert_true(wx_value_in_range(h->precip_mm, 0, WX_PRECIP_MAX_MM_H) || isnan(h->precip_mm));
    g_assert_true(wx_value_in_range(h->precip_prob, 0, 100) || isnan(h->precip_prob));
    g_assert_true(wx_value_in_range(h->cloud_pct, 0, 100) || isnan(h->cloud_pct));
    g_assert_true(wx_value_in_range(h->humidity_pct, 0, 100) || isnan(h->humidity_pct));
  }
}

static WxMember *
parse_grid(const char *body, gint64 fetched_s)
{
  g_autoptr(GError) error = NULL;
  WxMember *m = wx_nws_parse_gridpoints(BODY(body), fetched_s, &error);
  g_assert_no_error(error);
  g_assert_nonnull(m);
  check_member(m);
  return m;
}

static void
assert_grid_error_len(const guint8 *data, gsize len, WxError code, const char *message)
{
  g_autoptr(GError) error = NULL;
  WxMember *m = wx_nws_parse_gridpoints(data, len, T0, &error);
  g_assert_null(m);
  g_assert_error(error, WX_ERROR, (gint)code);
  g_assert_cmpstr(error->message, ==, message);
}

static void
assert_grid_error(const char *body, WxError code, const char *message)
{
  assert_grid_error_len(BODY(body), code, message);
}

static void
assert_points_error_len(const guint8 *data, gsize len, const char *message)
{
  WxNwsGrid grid = {"ZZZ", 7, 8};
  g_autoptr(GError) error = NULL;
  g_assert_false(wx_nws_parse_points(data, len, &grid, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_assert_cmpstr(error->message, ==, message);
  g_assert_cmpstr(grid.grid_id, ==, "ZZZ");
  g_assert_cmpuint(grid.x, ==, 7);
  g_assert_cmpuint(grid.y, ==, 8);
}

static void
assert_points_error(const char *body, const char *message)
{
  assert_points_error_len(BODY(body), message);
}

/* One layer member: "name":{"uom":"<uom>","values":[<elements>]}. */
static char *
layer_json(const char *name, const char *uom, const char *elements)
{
  return g_strdup_printf("\"%s\":{\"uom\":\"%s\",\"values\":[%s]}", name, uom, elements);
}

static char *
grid_body(const char *layers)
{
  return g_strdup_printf("{\"properties\":{%s}}", layers);
}

/* One element for the hour T0 + @hour_offset (UTC "Z" form). */
static char *
element_json(gint64 start_s, const char *duration, const char *value_json)
{
  g_autoptr(GDateTime) dt = g_date_time_new_from_unix_utc(start_s);
  g_autofree char *when = g_date_time_format(dt, "%Y-%m-%dT%H:%M:%S+00:00");
  return g_strdup_printf("{\"validTime\":\"%s/%s\",\"value\":%s}", when, duration, value_json);
}

/* The body of a grid with just `temperature` elements. */
static char *
temp_body(const char *elements)
{
  g_autofree char *layer = layer_json("temperature", "wmoUnit:degC", elements);
  return grid_body(layer);
}

/* ------------------------------------------------------------------------ */
/* Part 1: /points parser                                                   */
/* ------------------------------------------------------------------------ */

static void
test_points_fixture(void)
{
  g_autoptr(GBytes) body = fixture("points_miami.json");
  gsize len;
  const guint8 *data = g_bytes_get_data(body, &len);
  WxNwsGrid grid = {{0}, 0, 0};
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_nws_parse_points(data, len, &grid, &error));
  g_assert_no_error(error);
  g_assert_cmpstr(grid.grid_id, ==, "MFL");
  g_assert_cmpuint(grid.x, ==, 110);
  g_assert_cmpuint(grid.y, ==, 50);
}

static void
test_points_accepts_shapes(void)
{
  WxNwsGrid grid;
  const struct {
    const char *body;
    const char *id;
    guint x, y;
  } cases[] = {
    {"{\"properties\":{\"gridId\":\"AAA\",\"gridX\":0,\"gridY\":0}}", "AAA", 0, 0},
    {"{\"properties\":{\"gridId\":\"ZZZ\",\"gridX\":999,\"gridY\":999}}", "ZZZ", 999, 999},
    {"{\"properties\":{\"gridId\":\"BOX\",\"gridX\":7.0,\"gridY\":1e2}}", "BOX", 7, 100},
    {"{\"x\":1,\"properties\":{\"gridY\":5,\"extra\":[1,2],\"gridX\":4,\"gridId\":\"HFO\"}}",
     "HFO", 4, 5},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(GError) error = NULL;
    g_assert_true(wx_nws_parse_points(BODY(cases[i].body), &grid, &error));
    g_assert_no_error(error);
    g_assert_cmpstr(grid.grid_id, ==, cases[i].id);
    g_assert_cmpuint(grid.x, ==, cases[i].x);
    g_assert_cmpuint(grid.y, ==, cases[i].y);
  }
}

static void
test_points_rejects_bad_grid(void)
{
  const char *const bad[] = {
    "{}",
    "{\"properties\":null}",
    "{\"properties\":[]}",
    "{\"properties\":{}}",
    "{\"properties\":{\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1}}",
    "{\"properties\":{\"gridId\":\"mfl\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MF\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFLL\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"M/L\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"M\\u00c9L\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MF1\",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MF \",\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":5,\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":null,\"gridX\":1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":-1,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":-1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1000,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":1000}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":999.5,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1.5,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":\"1\",\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":true}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":null}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1e999,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":99999999999999999999,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":-0.5,\"gridY\":1}}",
    "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":[1],\"gridY\":1}}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++)
    assert_points_error(bad[i], MSG_NO_GRID);
}

static void
test_points_rejects_bad_json(void)
{
  assert_points_error("", "empty response");
  assert_points_error("[]", "response is not a JSON object");
  assert_points_error("\"x\"", "response is not a JSON object");
  assert_points_error("{", "malformed JSON");
  assert_points_error("{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":1}} x",
                      "malformed JSON");
  assert_points_error("{\"properties\":{\"gridId\":\"MFL\",\"gridId\":\"MFL\",\"gridX\":1,"
                      "\"gridY\":1}}",
                      "malformed JSON");
  assert_points_error("{\"properties\":{\"gridId\":\"MF\xff\",\"gridX\":1,\"gridY\":1}}",
                      "response is not valid UTF-8");
  g_autofree char *brackets = g_strnfill(100000, '[');
  g_autofree char *deep = g_strconcat("{\"a\":", brackets, NULL);
  assert_points_error(deep, "malformed JSON");
  assert_points_error_len(NULL, 0, "empty response");
  /* One byte over the body cap is refused before it is examined. */
  gsize big = (gsize)WX_HTTP_MAX_BODY_BYTES + 1;
  guint8 *blob = g_malloc(big);
  memset(blob, ' ', big);
  assert_points_error_len(blob, big, "response too large");
  g_free(blob);
}

static void
test_points_programmer_errors(void)
{
  WxNwsGrid grid = {"ZZZ", 7, 8};
  g_autoptr(GError) error = NULL;
  ASSERT_CRITICAL("wx_nws_parse_points", g_assert_false(wx_nws_parse_points(NULL, 5, &grid, &error)));
  g_assert_no_error(error);
  ASSERT_CRITICAL("wx_nws_parse_points", g_assert_false(wx_nws_parse_points(BODY("{}"), NULL, &error)));
  g_assert_no_error(error);
  error = g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "preset");
  ASSERT_CRITICAL("wx_nws_parse_points", g_assert_false(wx_nws_parse_points(BODY("{}"), &grid, &error)));
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpstr(grid.grid_id, ==, "ZZZ");
  /* NULL error location is allowed on success and on failure. */
  g_assert_false(wx_nws_parse_points(BODY("{}"), &grid, NULL));
  g_assert_true(wx_nws_parse_points(
    BODY("{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1,\"gridY\":2}}"), &grid, NULL));
  g_assert_cmpuint(grid.y, ==, 2);
}

static void
test_points_guard_page(void)
{
  const char *good = "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}";
  const char *bodies[] = {good, "{\"properties\":{\"gridId\":\"MFL\",\"gridX\":1", "{", "[1,2]",
                          "{\"properties\":{\"gridId\":\"mfl\",\"gridX\":1,\"gridY\":1}}", "x"};
  for (guint i = 0; i < G_N_ELEMENTS(bodies); i++) {
    gsize len = strlen(bodies[i]);
    Guarded g = guard_new(len);
    memcpy(g.data, bodies[i], len);
    WxNwsGrid grid;
    g_autoptr(GError) error = NULL;
    gboolean ok = wx_nws_parse_points((const guint8 *)g.data, len, &grid, &error);
    g_assert_cmpint(ok, ==, i == 0);
    guard_free(g);
  }
}

/* ------------------------------------------------------------------------ */
/* Part 2: /gridpoints parser over the real fixture                         */
/* ------------------------------------------------------------------------ */

/* The eight layers read, with the WxHour field each fills and whether it is a total. */
typedef struct {
  const char *name;
  const char *uom;
  gsize offset;
  gboolean total;
} LayerInfo;

static const LayerInfo kLayers[] = {
  {"temperature", "wmoUnit:degC", offsetof(WxHour, temp_c), FALSE},
  {"apparentTemperature", "wmoUnit:degC", offsetof(WxHour, feels_c), FALSE},
  {"relativeHumidity", "wmoUnit:percent", offsetof(WxHour, humidity_pct), FALSE},
  {"skyCover", "wmoUnit:percent", offsetof(WxHour, cloud_pct), FALSE},
  {"windSpeed", "wmoUnit:km_h-1", offsetof(WxHour, wind_kmh), FALSE},
  {"windGust", "wmoUnit:km_h-1", offsetof(WxHour, gust_kmh), FALSE},
  {"probabilityOfPrecipitation", "wmoUnit:percent", offsetof(WxHour, precip_prob), FALSE},
  {"quantitativePrecipitation", "wmoUnit:mm", offsetof(WxHour, precip_mm), TRUE},
};

static double
field_of(const WxHour *h, const LayerInfo *layer)
{
  return *(const double *)((const char *)h + layer->offset);
}

/*
 * Independent oracle for the real fixture: reads the file with a bare JsonParser, parses the
 * times with GDateTime and the durations with sscanf, and answers "which element covers this
 * hour" by a linear search (no hash tables, no expansion).
 */
static double
oracle_fixture_value(JsonObject *props, const LayerInfo *layer, gint64 t)
{
  JsonObject *l = json_object_get_object_member(props, layer->name);
  JsonArray *values = json_object_get_array_member(l, "values");
  for (guint i = 0; i < json_array_get_length(values); i++) {
    JsonObject *e = json_array_get_object_element(values, i);
    const char *vt = json_object_get_string_member(e, "validTime");
    g_autofree char *start_text = g_strndup(vt, (gsize)(strchr(vt, '/') - vt));
    g_autoptr(GDateTime) start = g_date_time_new_from_iso8601(start_text, NULL);
    g_assert_nonnull(start);
    gint64 s = g_date_time_to_unix(start);
    int hours = 0;
    g_assert_cmpint(sscanf(strchr(vt, '/') + 1, "PT%dH", &hours), ==, 1);
    if (t >= s && t < s + (gint64)hours * HOUR) {
      JsonNode *vn = json_object_get_member(e, "value");
      double v = json_node_get_double(vn);
      return layer->total ? v / hours : v;
    }
  }
  return NAN;
}

static void
test_grid_fixture_vs_oracle(void)
{
  g_autoptr(GBytes) body = fixture("gridpoints_miami.json");
  gsize len;
  const guint8 *data = g_bytes_get_data(body, &len);
  g_assert_cmpuint(len, <=, 200 * 1024);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) m = wx_nws_parse_gridpoints(data, len, 1791676800, &error);
  g_assert_no_error(error);
  g_assert_nonnull(m);
  check_member(m);
  g_assert_cmpint(wx_member_get_fetched_s(m), ==, 1791676800);

  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  /* 186 distinct hours, 2026-10-12T12:00Z .. 2026-10-20T01:00Z (counted with a separate script). */
  g_assert_cmpuint(n, ==, 186);
  g_assert_cmpint(hours[0].t_s, ==, 1791806400);
  g_assert_cmpint(hours[n - 1].t_s, ==, 1792472400);

  g_autoptr(JsonParser) parser = json_parser_new();
  g_assert_true(json_parser_load_from_data(parser, (const char *)data, (gssize)len, NULL));
  JsonObject *props = json_object_get_object_member(
    json_node_get_object(json_parser_get_root(parser)), "properties");
  guint finite_count[G_N_ELEMENTS(kLayers)] = {0};
  for (guint i = 0; i < n; i++) {
    for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++) {
      double expect = oracle_fixture_value(props, &kLayers[k], hours[i].t_s);
      assert_double_eq(field_of(&hours[i], &kLayers[k]), expect);
      finite_count[k] += isfinite(expect) ? 1 : 0;
    }
  }
  /* Every layer contributed (the member is not accidentally empty of one of them). */
  for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++)
    g_assert_cmpuint(finite_count[k], >=, 80);

  /* Hand-checked values of the first hours (read from the captured file). */
  const WxHour *h12 = hour_at(m, T0);
  const WxHour *h13 = hour_at(m, T0 + HOUR);
  const WxHour *h14 = hour_at(m, T0 + 2 * HOUR);
  const WxHour *h15 = hour_at(m, T0 + 3 * HOUR);
  g_assert_nonnull(h12);
  g_assert_nonnull(h13);
  g_assert_nonnull(h14);
  g_assert_nonnull(h15);
  g_assert_cmpfloat(h12->temp_c, ==, 27.77777777777778);   /* PT2H */
  g_assert_cmpfloat(h13->temp_c, ==, 27.77777777777778);
  g_assert_cmpfloat(h14->temp_c, ==, 28.88888888888889);
  g_assert_cmpfloat(h12->feels_c, ==, 32.77777777777778);
  g_assert_cmpfloat(h12->humidity_pct, ==, 88);
  g_assert_cmpfloat(h12->cloud_pct, ==, 16);
  g_assert_cmpfloat(h12->wind_kmh, ==, 9.26);              /* PT3H */
  g_assert_cmpfloat(h14->wind_kmh, ==, 9.26);
  g_assert_cmpfloat(h15->wind_kmh, ==, 11.112);
  g_assert_cmpfloat(h12->gust_kmh, ==, 11.112);
  g_assert_cmpfloat(h13->gust_kmh, ==, 12.964);            /* PT2H */
  g_assert_cmpfloat(h14->gust_kmh, ==, 12.964);
  g_assert_cmpfloat(h12->precip_prob, ==, 6);
  g_assert_cmpfloat(h13->precip_prob, ==, 3);              /* PT3H */
  g_assert_cmpfloat(h15->precip_prob, ==, 3);
  g_assert_cmpfloat(h12->precip_mm, ==, 0.254 / 6);        /* 0.254 mm over PT6H */
  g_assert_cmpfloat(h15->precip_mm, ==, 0.254 / 6);
  g_assert_cmpint(h12->wmo, ==, -1);
  /* The six hours of the first precipitation interval sum back to the interval total. */
  double sum = 0;
  for (guint i = 0; i < 6; i++)
    sum += hour_at(m, T0 + i * HOUR)->precip_mm;
  g_assert_cmpfloat(fabs(sum - 0.254), <, 1e-12);
}

static void
test_grid_fixture_member_is_stable(void)
{
  /* Parsing twice gives identical members; fetched_s is only what the caller passed. */
  g_autoptr(GBytes) body = fixture("gridpoints_miami.json");
  gsize len;
  const guint8 *data = g_bytes_get_data(body, &len);
  g_autoptr(WxMember) a = wx_nws_parse_gridpoints(data, len, 1791676800, NULL);
  g_autoptr(WxMember) b = wx_nws_parse_gridpoints(data, len, 1791676801, NULL);
  guint na, nb;
  const WxHour *ha = wx_member_get_hours(a, &na);
  const WxHour *hb = wx_member_get_hours(b, &nb);
  g_assert_cmpuint(na, ==, nb);
  for (guint i = 0; i < na; i++) {
    g_assert_cmpint(ha[i].t_s, ==, hb[i].t_s);
    assert_double_eq(ha[i].temp_c, hb[i].temp_c);
    assert_double_eq(ha[i].precip_mm, hb[i].precip_mm);
  }
  g_assert_cmpint(wx_member_get_fetched_s(b), ==, 1791676801);
}

/* ------------------------------------------------------------------------ */
/* Part 3: /gridpoints parser over synthetic bodies                         */
/* ------------------------------------------------------------------------ */

static void
test_grid_each_layer_and_unit(void)
{
  for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++) {
    const LayerInfo *layer = &kLayers[k];
    g_autofree char *elem = element_json(T0, "PT1H", "5");
    {
      g_autofree char *l = layer_json(layer->name, layer->uom, elem);
      g_autofree char *body = grid_body(l);
      g_autoptr(WxMember) m = parse_grid(body, 1791676800);
      guint n;
      const WxHour *hours = wx_member_get_hours(m, &n);
      g_assert_cmpuint(n, ==, 1);
      g_assert_cmpint(hours[0].t_s, ==, T0);
      g_assert_cmpfloat(field_of(&hours[0], layer), ==, 5.0);
      /* Every other field of the hour is NAN. */
      for (guint j = 0; j < G_N_ELEMENTS(kLayers); j++)
        if (j != k)
          g_assert_true(isnan(field_of(&hours[0], &kLayers[j])));
    }
    const char *wrong[] = {"wmoUnit:degF", "wmoUnit:m", "", "degC", "wmoUnit:degC ", "WMOUNIT:DEGC",
                           "nwsUnit:s", "wmoUnit:km_h-1x"};
    for (guint w = 0; w < G_N_ELEMENTS(wrong); w++) {
      if (strcmp(wrong[w], layer->uom) == 0)
        continue;
      g_autofree char *l = layer_json(layer->name, wrong[w], elem);
      g_autofree char *body = grid_body(l);
      assert_grid_error(body, WX_ERROR_NOT_FOUND, MSG_NO_DATA);
    }
    /* No uom, uom of another type, values of another type, missing values, layer of another type. */
    for (guint o = 0; o < 10; o++) {
      g_autofree char *l = NULL;
      switch (o) {
      case 0: l = g_strdup_printf("\"%s\":{\"values\":[%s]}", layer->name, elem); break;
      case 1: l = g_strdup_printf("\"%s\":{\"uom\":5,\"values\":[%s]}", layer->name, elem); break;
      case 2: l = g_strdup_printf("\"%s\":{\"uom\":null,\"values\":[%s]}", layer->name, elem); break;
      case 3: l = g_strdup_printf("\"%s\":{\"uom\":\"%s\"}", layer->name, layer->uom); break;
      case 4: l = g_strdup_printf("\"%s\":{\"uom\":\"%s\",\"values\":{}}", layer->name, layer->uom); break;
      case 5: l = g_strdup_printf("\"%s\":{\"uom\":\"%s\",\"values\":null}", layer->name, layer->uom); break;
      case 6: l = g_strdup_printf("\"%s\":{\"uom\":\"%s\",\"values\":\"x\"}", layer->name, layer->uom); break;
      case 7: l = g_strdup_printf("\"%s\":[1]", layer->name); break;
      case 8: l = g_strdup_printf("\"%s\":null", layer->name); break;
      default: l = g_strdup_printf("\"%s\":5", layer->name); break;
      }
      g_autofree char *body = grid_body(l);
      assert_grid_error(body, WX_ERROR_NOT_FOUND, MSG_NO_DATA);
    }
  }
}

static void
test_grid_ignores_other_layers(void)
{
  /* A layer the provider does not read (dewpoint, maxTemperature, weather ...) is not used. */
  g_autofree char *elem = element_json(T0, "PT1H", "5");
  g_autofree char *dew = layer_json("dewpoint", "wmoUnit:degC", elem);
  g_autofree char *mx = layer_json("maxTemperature", "wmoUnit:degC", elem);
  g_autofree char *wc = layer_json("windChill", "wmoUnit:degC", elem);
  g_autofree char *layers = g_strjoin(",", dew, mx, wc, NULL);
  g_autofree char *body = grid_body(layers);
  assert_grid_error(body, WX_ERROR_NOT_FOUND, MSG_NO_DATA);
}

static void
test_grid_expansion(void)
{
  g_autofree char *e1 = element_json(T0, "PT3H", "20");
  g_autofree char *e2 = element_json(T0 + 5 * HOUR, "PT1H", "21.5");
  g_autofree char *elems = g_strjoin(",", e1, e2, NULL);
  g_autofree char *body = temp_body(elems);
  g_autoptr(WxMember) m = parse_grid(body, 1791676800);
  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, 4);
  for (guint i = 0; i < 3; i++) {
    g_assert_cmpint(hours[i].t_s, ==, T0 + i * HOUR);
    g_assert_cmpfloat(hours[i].temp_c, ==, 20.0);
  }
  g_assert_cmpint(hours[3].t_s, ==, T0 + 5 * HOUR);
  g_assert_cmpfloat(hours[3].temp_c, ==, 21.5);
  g_assert_null(hour_at(m, T0 + 3 * HOUR));
  g_assert_null(hour_at(m, T0 + 4 * HOUR));
  g_assert_null(hour_at(m, T0 - HOUR));
}

static void
test_grid_precipitation_is_divided(void)
{
  struct {
    const char *duration;
    const char *value;
    guint hours;
    double each;
  } cases[] = {
    {"PT1H", "2.5", 1, 2.5},
    {"PT3H", "3", 3, 1.0},
    {"PT6H", "0.254", 6, 0.254 / 6},
    {"P1D", "24", 24, 1.0},
    {"P1DT6H", "30", 30, 1.0},
    {"PT2H", "1e-320", 2, 1e-320 / 2}, /* subnormal */
    {"PT12H", "0", 12, 0.0},
    {"PT180M", "3", 3, 1.0},    /* the duration parser also reads minutes and seconds */
    {"PT7200S", "4", 2, 2.0},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autofree char *elem = element_json(T0, cases[i].duration, cases[i].value);
    g_autofree char *l = layer_json("quantitativePrecipitation", "wmoUnit:mm", elem);
    g_autofree char *body = grid_body(l);
    g_autoptr(WxMember) m = parse_grid(body, 1791676800);
    guint n;
    const WxHour *hours = wx_member_get_hours(m, &n);
    g_assert_cmpuint(n, ==, cases[i].hours);
    for (guint h = 0; h < n; h++) {
      g_assert_cmpint(hours[h].t_s, ==, T0 + h * HOUR);
      g_assert_cmpfloat(hours[h].precip_mm, ==, cases[i].each);
    }
  }
}

static void
test_grid_value_ranges(void)
{
  /* Boundary table: layer, value text, expected stored value or NAN when dropped. */
  const struct {
    const char *layer;
    const char *duration;
    const char *value;
    double expect; /* NAN: the element is dropped */
  } cases[] = {
    {"temperature", "PT1H", "-100", -100.0},
    {"temperature", "PT1H", "-100.0000001", NAN},
    {"temperature", "PT1H", "70", 70.0},
    {"temperature", "PT1H", "70.0000001", NAN},
    {"temperature", "PT1H", "1e308", NAN},
    {"temperature", "PT1H", "-1e308", NAN},
    {"temperature", "PT1H", "1e999", NAN},
    {"temperature", "PT1H", "-1e999", NAN},
    {"temperature", "PT1H", "9223372036854775807", NAN},
    {"temperature", "PT1H", "-9223372036854775808", NAN},
    {"temperature", "PT1H", "99999999999999999999", NAN},
    {"temperature", "PT1H", "\"12\"", NAN},
    {"temperature", "PT1H", "true", NAN},
    {"temperature", "PT1H", "null", NAN},
    {"temperature", "PT1H", "[1]", NAN},
    {"temperature", "PT1H", "{}", NAN},
    {"temperature", "PT1H", "-0.0", 0.0},
    {"temperature", "PT1H", "4.9e-324", 4.9e-324},
    {"apparentTemperature", "PT1H", "70", 70.0},
    {"apparentTemperature", "PT1H", "71", NAN},
    {"apparentTemperature", "PT1H", "-101", NAN},
    {"relativeHumidity", "PT1H", "0", 0.0},
    {"relativeHumidity", "PT1H", "100", 100.0},
    {"relativeHumidity", "PT1H", "100.0000001", NAN},
    {"relativeHumidity", "PT1H", "-0.0000001", NAN},
    {"skyCover", "PT1H", "100", 100.0},
    {"skyCover", "PT1H", "101", NAN},
    {"skyCover", "PT1H", "-1", NAN},
    {"probabilityOfPrecipitation", "PT1H", "100", 100.0},
    {"probabilityOfPrecipitation", "PT1H", "100.5", NAN},
    {"probabilityOfPrecipitation", "PT1H", "-5", NAN},
    {"windSpeed", "PT1H", "0", 0.0},
    {"windSpeed", "PT1H", "500", 500.0},
    {"windSpeed", "PT1H", "500.0000001", NAN},
    {"windSpeed", "PT1H", "-0.0000001", NAN},
    {"windGust", "PT1H", "500", 500.0},
    {"windGust", "PT1H", "501", NAN},
    {"windGust", "PT1H", "-1", NAN},
    {"quantitativePrecipitation", "PT1H", "500", 500.0},
    {"quantitativePrecipitation", "PT1H", "500.0000001", NAN},
    {"quantitativePrecipitation", "PT2H", "1000", 500.0},
    {"quantitativePrecipitation", "PT2H", "1000.000001", NAN},
    {"quantitativePrecipitation", "PT3H", "1500", 500.0},
    {"quantitativePrecipitation", "PT1H", "-0.0", 0.0},
    {"quantitativePrecipitation", "PT1H", "-0.1", NAN},
    {"quantitativePrecipitation", "PT2H", "-1e-320", NAN},
    {"quantitativePrecipitation", "PT1H", "1e308", NAN},
    {"quantitativePrecipitation", "P31D", "1e308", NAN},
    {"quantitativePrecipitation", "P31D", "372000", 500.0},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    const LayerInfo *layer = NULL;
    for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++)
      if (strcmp(kLayers[k].name, cases[i].layer) == 0)
        layer = &kLayers[k];
    g_assert_nonnull(layer);
    /* The element under test, then a companion (another layer) that always survives. */
    const LayerInfo *comp = strcmp(layer->name, "skyCover") == 0 ? &kLayers[4] : &kLayers[3];
    g_autofree char *e1 = element_json(T0, cases[i].duration, cases[i].value);
    g_autofree char *e2 = element_json(T0 - 10 * HOUR, "PT1H", "1");
    g_autofree char *l1 = layer_json(layer->name, layer->uom, e1);
    g_autofree char *l2 = layer_json(comp->name, comp->uom, e2);
    g_autofree char *layers = g_strjoin(",", l1, l2, NULL);
    g_autofree char *body = grid_body(layers);
    g_autoptr(WxMember) m = parse_grid(body, 1791676800);
    const WxHour *h = hour_at(m, T0);
    if (isnan(cases[i].expect)) {
      g_assert_null(h);
    } else {
      g_assert_nonnull(h);
      assert_double_eq(field_of(h, layer), cases[i].expect);
      g_assert_false(signbit(field_of(h, layer)) && cases[i].expect == 0.0);
    }
    g_assert_nonnull(hour_at(m, T0 - 10 * HOUR));
  }
}

static void
test_grid_bad_elements_are_skipped(void)
{
  const char *const bad[] = {
    "{\"validTime\":\"\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/\",\"value\":1}",
    "{\"validTime\":\"/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT0S\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT0H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/P1W\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/P1M\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:30:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:01+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT90M\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H30M\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1800S\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/P32D\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT745H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT99999999H\",\"value\":1}",
    "{\"validTime\":\"1999-12-31T23:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2101-01-01T00:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12 12:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-10-12t12:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\"2026-13-12T12:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":\" 2026-10-12T12:00:00+00:00/PT1H\",\"value\":1}",
    "{\"validTime\":5,\"value\":1}",
    "{\"validTime\":null,\"value\":1}",
    "{\"validTime\":[\"2026-10-12T12:00:00+00:00/PT1H\"],\"value\":1}",
    "{\"value\":1}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\"}",
    "{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\",\"value\":null}",
    "{}",
    "[]",
    "5",
    "\"2026-10-12T12:00:00+00:00/PT1H\"",
    "null",
    "true",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autofree char *good = element_json(T0 + 10 * HOUR, "PT1H", "7");
    g_autofree char *elems = g_strjoin(",", bad[i], good, NULL);
    g_autofree char *body = temp_body(elems);
    g_autoptr(WxMember) m = parse_grid(body, 1791676800);
    guint n;
    wx_member_get_hours(m, &n);
    g_assert_cmpuint(n, ==, 1);
    g_assert_nonnull(hour_at(m, T0 + 10 * HOUR));
    /* ... and alone it leaves nothing usable. */
    g_autofree char *alone = temp_body(bad[i]);
    assert_grid_error(alone, WX_ERROR_NOT_FOUND, MSG_NO_DATA);
  }
}

static void
test_grid_time_zones_and_bounds(void)
{
  struct {
    const char *valid_time;
    gint64 first;
    guint hours;
  } cases[] = {
    {"2026-10-12T08:00:00-04:00/PT1H", T0, 1},
    {"2026-10-12T17:30:00+05:30/PT2H", T0, 2},
    {"2026-10-12T12:00:00Z/PT1H", T0, 1},
    {"2026-10-12T12:00:00.750Z/PT1H", T0, 1},
    {"2000-01-01T00:00:00Z/PT1H", WX_TIME_MIN_S, 1},
    /* 2100-12-31: only the 24 hours before WX_TIME_MAX_S (2101-01-01) exist. */
    {"2100-12-31T00:00:00Z/P2D", 4133894400, 24},
    {"2100-12-31T23:00:00Z/PT2H", 4133980800 - HOUR, 1},
    {"2100-12-31T23:00:00Z/PT1H", 4133980800 - HOUR, 1},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autofree char *elem = g_strdup_printf("{\"validTime\":\"%s\",\"value\":3}", cases[i].valid_time);
    g_autofree char *body = temp_body(elem);
    g_autoptr(WxMember) m = parse_grid(body, 1791676800);
    guint n;
    const WxHour *hours = wx_member_get_hours(m, &n);
    g_assert_cmpuint(n, ==, cases[i].hours);
    g_assert_cmpint(hours[0].t_s, ==, cases[i].first);
    g_assert_cmpint(hours[n - 1].t_s, <, WX_TIME_MAX_S);
  }
}

static void
test_grid_overlap_first_wins(void)
{
  g_autofree char *e1 = element_json(T0, "PT3H", "10");
  g_autofree char *e2 = element_json(T0 + HOUR, "PT3H", "20");
  g_autofree char *e3 = element_json(T0, "PT1H", "30");
  g_autofree char *elems = g_strjoin(",", e1, e2, e3, NULL);
  g_autofree char *body = temp_body(elems);
  g_autoptr(WxMember) m = parse_grid(body, 1791676800);
  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, 4);
  g_assert_cmpfloat(hours[0].temp_c, ==, 10);
  g_assert_cmpfloat(hours[1].temp_c, ==, 10);
  g_assert_cmpfloat(hours[2].temp_c, ==, 10);
  g_assert_cmpfloat(hours[3].temp_c, ==, 20);
}

static void
test_grid_union_is_ascending_and_sparse(void)
{
  /* Elements in descending array order and layers with disjoint hours. */
  g_autofree char *t2 = element_json(T0 + 5 * HOUR, "PT1H", "5");
  g_autofree char *t1 = element_json(T0 + 4 * HOUR, "PT1H", "4");
  g_autofree char *telems = g_strjoin(",", t2, t1, NULL);
  g_autofree char *w = element_json(T0 + 1 * HOUR, "PT1H", "11");
  g_autofree char *q = element_json(T0 + 3 * HOUR, "PT2H", "4");
  g_autofree char *tl = layer_json("temperature", "wmoUnit:degC", telems);
  g_autofree char *wl = layer_json("windSpeed", "wmoUnit:km_h-1", w);
  g_autofree char *ql = layer_json("quantitativePrecipitation", "wmoUnit:mm", q);
  g_autofree char *layers = g_strjoin(",", tl, wl, ql, NULL);
  g_autofree char *body = grid_body(layers);
  g_autoptr(WxMember) m = parse_grid(body, 1791676800);
  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, 4); /* hours +1 (wind), +3 and +4 (precipitation, +4 also temperature), +5 */
  g_assert_cmpint(hours[0].t_s, ==, T0 + 1 * HOUR);
  g_assert_cmpint(hours[1].t_s, ==, T0 + 3 * HOUR);
  g_assert_cmpint(hours[2].t_s, ==, T0 + 4 * HOUR);
  g_assert_cmpint(hours[3].t_s, ==, T0 + 5 * HOUR);
}

static void
test_grid_caps(void)
{
  g_autoptr(GString) s = g_string_new(NULL);
  g_autoptr(WxMember) m = NULL;
  guint n;
  const WxHour *hours;

  /* 450 consecutive one-hour elements: the first 400 hours. */
  for (guint i = 0; i < 450; i++) {
    g_autofree char *e = element_json(T0 + i * HOUR, "PT1H", "1");
    g_string_append_printf(s, "%s%s", i ? "," : "", e);
  }
  g_autofree char *body1 = temp_body(s->str);
  m = parse_grid(body1, 1791676800);
  hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpint(hours[n - 1].t_s, ==, T0 + 399 * HOUR);
  g_clear_pointer(&m, wx_member_unref);

  /* Elements 0..399 are read, element 400 and later are not: duplicates of one hour first. */
  for (guint last = 399; last <= 400; last++) {
    g_string_truncate(s, 0);
    for (guint i = 0; i < last; i++) {
      g_autofree char *e = element_json(T0, "PT1H", "1");
      g_string_append_printf(s, "%s%s", i ? "," : "", e);
    }
    g_autofree char *tail = element_json(T0 + 10 * HOUR, "PT1H", "2");
    g_string_append_printf(s, ",%s", tail);
    g_autofree char *body2 = temp_body(s->str);
    m = parse_grid(body2, 1791676800);
    g_assert_cmpint(hour_at(m, T0 + 10 * HOUR) != NULL, ==, last == 399);
    g_clear_pointer(&m, wx_member_unref);
  }

  /* A 31 day interval gives 400 of its 744 hours. */
  g_autofree char *big = element_json(T0, "P31D", "1");
  g_autofree char *body3 = temp_body(big);
  m = parse_grid(body3, 1791676800);
  hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpint(hours[0].t_s, ==, T0);
  g_assert_cmpint(hours[n - 1].t_s, ==, T0 + 399 * HOUR);
  g_clear_pointer(&m, wx_member_unref);

  /* Overlapping 10-day elements: distinct hours stop at 400 (3rd element adds only 40). */
  g_autofree char *a = element_json(T0, "P10D", "1");
  g_autofree char *b = element_json(T0 + 120 * HOUR, "P10D", "2");
  g_autofree char *c = element_json(T0 + 240 * HOUR, "P10D", "3");
  g_autofree char *abc = g_strjoin(",", a, b, c, NULL);
  g_autofree char *body4 = temp_body(abc);
  m = parse_grid(body4, 1791676800);
  hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpfloat(hour_at(m, T0 + 119 * HOUR)->temp_c, ==, 1);
  g_assert_cmpfloat(hour_at(m, T0 + 120 * HOUR)->temp_c, ==, 1); /* first element wins */
  g_assert_cmpfloat(hour_at(m, T0 + 239 * HOUR)->temp_c, ==, 1);
  g_assert_cmpfloat(hour_at(m, T0 + 240 * HOUR)->temp_c, ==, 2);
  g_assert_cmpfloat(hour_at(m, T0 + 359 * HOUR)->temp_c, ==, 2);
  g_assert_cmpfloat(hour_at(m, T0 + 360 * HOUR)->temp_c, ==, 3);
  g_assert_cmpfloat(hour_at(m, T0 + 399 * HOUR)->temp_c, ==, 3);
  g_assert_null(hour_at(m, T0 + 400 * HOUR));
  g_clear_pointer(&m, wx_member_unref);

  /* The union of two layers is cut at 400 hours, earliest first. */
  g_autofree char *t = element_json(T0, "P16D", "1");        /* 384 hours */
  g_autofree char *t2 = element_json(T0 + 384 * HOUR, "P1D", "1"); /* 24 more: 408 for temperature */
  g_autofree char *telems = g_strjoin(",", t, t2, NULL);
  g_autofree char *w = element_json(T0 + 500 * HOUR, "PT3H", "9");
  g_autofree char *tl = layer_json("temperature", "wmoUnit:degC", telems);
  g_autofree char *wl = layer_json("windSpeed", "wmoUnit:km_h-1", w);
  g_autofree char *layers = g_strjoin(",", tl, wl, NULL);
  g_autofree char *body5 = grid_body(layers);
  m = parse_grid(body5, 1791676800);
  hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);
  g_assert_cmpint(hours[n - 1].t_s, ==, T0 + 399 * HOUR);
  for (guint i = 0; i < n; i++)
    g_assert_true(isnan(hours[i].wind_kmh));
}

static void
test_grid_large_hostile_bodies(void)
{
  /* ~3 MB of one-hour elements (only 400 are read) and 400 copies of a 31-day interval. */
  g_autoptr(GString) s = g_string_new(NULL);
  for (guint i = 0; i < 40000; i++)
    g_string_append_printf(s, "%s{\"validTime\":\"2026-10-12T12:00:00+00:00/PT1H\",\"value\":1}",
                           i ? "," : "");
  g_autofree char *body1 = temp_body(s->str);
  g_assert_cmpuint(strlen(body1), <, (gsize)WX_HTTP_MAX_BODY_BYTES);
  g_autoptr(WxMember) m1 = parse_grid(body1, 1791676800);
  guint n;
  wx_member_get_hours(m1, &n);
  g_assert_cmpuint(n, ==, 1);

  g_string_truncate(s, 0);
  for (guint i = 0; i < 2000; i++)
    g_string_append_printf(s, "%s{\"validTime\":\"2026-10-12T12:00:00+00:00/P31D\",\"value\":1}",
                           i ? "," : "");
  g_autofree char *body2 = temp_body(s->str);
  g_autoptr(WxMember) m2 = parse_grid(body2, 1791676800);
  wx_member_get_hours(m2, &n);
  g_assert_cmpuint(n, ==, WX_MEMBER_MAX_HOURS);

  /* Hash-flooding names are refused by wx_json_parse() (1025 members). */
  g_string_truncate(s, 0);
  g_string_append(s, "{\"properties\":{");
  for (guint i = 0; i < 1025; i++)
    g_string_append_printf(s, "%s\"k%u\":1", i ? "," : "", i);
  g_string_append(s, "}}");
  assert_grid_error(s->str, WX_ERROR_PARSE, "malformed JSON");
}

static void
test_grid_parse_errors(void)
{
  assert_grid_error("", WX_ERROR_PARSE, "empty response");
  assert_grid_error("[]", WX_ERROR_PARSE, "response is not a JSON object");
  assert_grid_error("null", WX_ERROR_PARSE, "response is not a JSON object");
  assert_grid_error("{", WX_ERROR_PARSE, "malformed JSON");
  assert_grid_error("{\"properties\":{}} {}", WX_ERROR_PARSE, "malformed JSON");
  assert_grid_error("{\"properties\":{\"a\":\"\xff\"}}", WX_ERROR_PARSE, "response is not valid UTF-8");
  assert_grid_error("{}", WX_ERROR_PARSE, MSG_NO_PROPS);
  assert_grid_error("{\"properties\":null}", WX_ERROR_PARSE, MSG_NO_PROPS);
  assert_grid_error("{\"properties\":[]}", WX_ERROR_PARSE, MSG_NO_PROPS);
  assert_grid_error("{\"properties\":5}", WX_ERROR_PARSE, MSG_NO_PROPS);
  assert_grid_error("{\"properties\":{}}", WX_ERROR_NOT_FOUND, MSG_NO_DATA);
  assert_grid_error_len(NULL, 0, WX_ERROR_PARSE, "empty response");
  g_autofree char *brackets = g_strnfill(5000, '[');
  g_autofree char *deep = g_strconcat("{\"properties\":", brackets, NULL);
  assert_grid_error(deep, WX_ERROR_PARSE, "malformed JSON");
  gsize big = (gsize)WX_HTTP_MAX_BODY_BYTES + 1;
  guint8 *blob = g_malloc(big);
  memset(blob, ' ', big);
  assert_grid_error_len(blob, big, WX_ERROR_PARSE, "response too large");
  g_free(blob);
}

static void
test_grid_fetched_time_is_validated(void)
{
  const char *body = "{\"properties\":{}}";
  const gint64 bad[] = {0, -1, G_MININT64, G_MAXINT64, WX_TIME_MIN_S - 1, WX_TIME_MAX_S};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autoptr(GError) error = NULL;
    g_assert_null(wx_nws_parse_gridpoints(BODY(body), bad[i], &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpstr(error->message, ==, "fetch time out of range");
  }
  /* A body error is reported before the time is looked at. */
  g_autoptr(GError) order = NULL;
  g_assert_null(wx_nws_parse_gridpoints(BODY("{}"), 0, &order));
  g_assert_error(order, WX_ERROR, WX_ERROR_PARSE);
  g_assert_cmpstr(order->message, ==, MSG_NO_PROPS);
  g_autofree char *elem = element_json(T0, "PT1H", "1");
  g_autofree char *good = temp_body(elem);
  const gint64 ok[] = {WX_TIME_MIN_S, WX_TIME_MAX_S - 1};
  for (guint i = 0; i < G_N_ELEMENTS(ok); i++) {
    g_autoptr(WxMember) m = parse_grid(good, ok[i]);
    g_assert_cmpint(wx_member_get_fetched_s(m), ==, ok[i]);
  }
}

static void
test_grid_programmer_errors(void)
{
  g_autoptr(GError) error = NULL;
  ASSERT_CRITICAL("wx_nws_parse_gridpoints",
                  g_assert_null(wx_nws_parse_gridpoints(NULL, 5, T0, &error)));
  g_assert_no_error(error);
  error = g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "preset");
  ASSERT_CRITICAL("wx_nws_parse_gridpoints",
                  g_assert_null(wx_nws_parse_gridpoints(BODY("{}"), T0, &error)));
  g_assert_error(error, WX_ERROR, WX_ERROR_HTTP);
  /* NULL error location is allowed. */
  g_assert_null(wx_nws_parse_gridpoints(BODY("{}"), T0, NULL));
  g_assert_null(wx_nws_parse_gridpoints(BODY("{\"properties\":{}}"), T0, NULL));
}

static void
test_grid_guard_page(void)
{
  g_autofree char *elem = element_json(T0, "PT2H", "3");
  g_autofree char *good = temp_body(elem);
  const char *bodies[] = {good, "{\"properties\":{\"temperature\":{\"uom\":", "{", "[1,2]", "x",
                          "{\"properties\":{}}"};
  for (guint i = 0; i < G_N_ELEMENTS(bodies); i++) {
    gsize len = strlen(bodies[i]);
    Guarded g = guard_new(len);
    memcpy(g.data, bodies[i], len);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) m = wx_nws_parse_gridpoints((const guint8 *)g.data, len, T0, &error);
    g_assert_cmpint(m != NULL, ==, i == 0);
    if (m != NULL)
      check_member(m);
    guard_free(g);
  }
  /* The real fixture, ending at the guard page. */
  g_autoptr(GBytes) body = fixture("gridpoints_miami.json");
  gsize len;
  const void *data = g_bytes_get_data(body, &len);
  Guarded g = guard_new(len);
  memcpy(g.data, data, len);
  g_autoptr(WxMember) m = wx_nws_parse_gridpoints((const guint8 *)g.data, len, T0, NULL);
  g_assert_nonnull(m);
  guard_free(g);
}

/* ------------------------------------------------------------------------ */
/* Part 4: randomised bodies against an independent oracle                  */
/* ------------------------------------------------------------------------ */

/* One generated element: what the text says, and what a correct reader makes of it. */
typedef struct {
  gboolean usable;    /* the element must contribute */
  gint64 start_s;     /* valid when usable */
  guint hours;        /* valid when usable */
  double value;       /* per-hour value, valid when usable */
  char *json;
} GenElement;

/* A generated value: its JSON text and whether it is a finite number the reader accepts. */
typedef struct {
  const char *text;
  gboolean number;
} ValueText;

static const ValueText kValues[] = {
  {"0", TRUE},       {"-0.0", TRUE},     {"1", TRUE},       {"17.25", TRUE},  {"99.9", TRUE},
  {"100", TRUE},     {"250.5", TRUE},    {"499", TRUE},     {"500", TRUE},    {"-5", TRUE},
  {"-100", TRUE},    {"69.5", TRUE},     {"70", TRUE},      {"-20.125", TRUE}, {"0.254", TRUE},
  {"70.5", TRUE},    {"100.5", TRUE},    {"-0.5", TRUE},    {"700", TRUE},    {"-101", TRUE},
  {"1000", TRUE},    {"1e308", TRUE},    {"-1e308", TRUE},  {"500.5", TRUE},  {"2.5e2", TRUE},
  {"null", FALSE},   {"\"3\"", FALSE},   {"true", FALSE},   {"[1]", FALSE},   {"{}", FALSE},
  {"1e999", FALSE},  {"-1e999", FALSE},  {"9223372036854775807", FALSE},
};

/* The valid range of layer @k for a stored (per hour) value. */
static void
layer_range(guint k, double *lo, double *hi)
{
  switch (k) {
  case 0:
  case 1:
    *lo = WX_TEMP_MIN_C;
    *hi = WX_TEMP_MAX_C;
    break;
  case 4:
  case 5:
    *lo = 0;
    *hi = WX_WIND_MAX_KMH;
    break;
  case 7:
    *lo = 0;
    *hi = WX_PRECIP_MAX_MM_H;
    break;
  default:
    *lo = 0;
    *hi = 100;
  }
}

static char *
format_duration(GRand *rng, guint hours)
{
  if (hours % 24 == 0 && g_rand_boolean(rng))
    return g_strdup_printf("P%uD", hours / 24);
  if (hours >= 24 && g_rand_boolean(rng)) {
    return hours % 24 ? g_strdup_printf("P%uDT%uH", hours / 24, hours % 24)
                      : g_strdup_printf("P%uD", hours / 24);
  }
  return g_strdup_printf("PT%uH", hours);
}

static GenElement
gen_element(GRand *rng, guint k)
{
  GenElement e = {FALSE, 0, 0, 0, NULL};
  /* Start: mostly near T0, sometimes at the edges of the supported years. */
  gint64 start;
  switch (g_rand_int_range(rng, 0, 12)) {
  case 0: start = WX_TIME_MIN_S + HOUR * (gint64)g_rand_int_range(rng, 0, 5); break;
  case 1: start = WX_TIME_MAX_S - HOUR * (gint64)g_rand_int_range(rng, 1, 30); break;
  default: start = T0 + HOUR * (gint64)g_rand_int_range(rng, -50, 350);
  }
  guint hours = g_rand_boolean(rng) ? (guint)g_rand_int_range(rng, 1, 7)
                                    : (guint)g_rand_int_range(rng, 1, 745);
  gboolean ok_time = TRUE;
  g_autofree char *when = NULL;
  g_autofree char *dur = format_duration(rng, hours);
  gint64 offset_s = 0;
  gint kind = g_rand_int_range(rng, 0, 20);
  switch (kind) {
  case 1: start += 1800; ok_time = FALSE; break;                       /* misaligned start */
  case 2: g_free(dur); dur = g_strdup_printf("PT%uH30M", hours); ok_time = FALSE; break;
  case 3: g_free(dur); dur = g_strdup_printf("PT%uM", hours * 60); break;   /* same length, minutes */
  case 4: g_free(dur); dur = g_strdup("PT0H"); ok_time = FALSE; break;
  case 5: g_free(dur); dur = g_strdup_printf("P%uD", 32 + (guint)g_rand_int_range(rng, 0, 4)); ok_time = FALSE; break;
  case 6: when = g_strdup("garbage"); ok_time = FALSE; break;
  case 7: offset_s = 3600 * (gint64)g_rand_int_range(rng, -12, 13); break;
  case 8: offset_s = 1800 * (gint64)g_rand_int_range(rng, -23, 24); break;
  case 9: g_free(dur); dur = g_strdup_printf("PT%uS", hours * 3600); break;  /* same length, seconds */
  default: break;
  }
  /* An offset moves the local text; keep it inside the accepted years. */
  if (offset_s != 0 && (start < T0 - 100 * HOUR || start > T0 + 400 * HOUR))
    offset_s = 0;
  if (when == NULL) {
    g_autoptr(GDateTime) dt = g_date_time_new_from_unix_utc(start + offset_s);
    g_autofree char *local = g_date_time_format(dt, "%Y-%m-%dT%H:%M:%S");
    gint64 a = offset_s < 0 ? -offset_s : offset_s;
    when = g_strdup_printf("%s%c%02d:%02d", local, offset_s < 0 ? '-' : '+', (int)(a / 3600),
                           (int)(a % 3600 / 60));
  }
  /* Value. */
  const ValueText *vt = NULL;
  if (g_rand_int_range(rng, 0, 12) != 0)
    vt = &kValues[g_rand_int_range(rng, 0, G_N_ELEMENTS(kValues))];
  const char *value_text = vt != NULL ? vt->text : NULL;
  double v = 0;
  gboolean object = g_rand_int_range(rng, 0, 25) != 0;
  if (!object) {
    const char *junk[] = {"5", "\"x\"", "null", "[]", "true"};
    e.json = g_strdup(junk[g_rand_int_range(rng, 0, G_N_ELEMENTS(junk))]);
    return e;
  }
  if (value_text == NULL)
    e.json = g_strdup_printf("{\"validTime\":\"%s/%s\"}", when, dur);
  else
    e.json = g_strdup_printf("{\"validTime\":\"%s/%s\",\"value\":%s}", when, dur, value_text);
  if (!ok_time || vt == NULL || !vt->number)
    return e;
  /* The reference reading: value, hours, range. */
  v = g_ascii_strtod(value_text, NULL);
  double lo, hi;
  layer_range(k, &lo, &hi);
  if (k == 7)
    v /= hours;
  if (!(v >= lo && v <= hi))
    return e;
  /* Year bounds of the text (local time of the start). */
  gint64 local_s = start + offset_s;
  if (local_s < WX_TIME_MIN_S || local_s >= WX_TIME_MAX_S)
    return e;
  /* 31 days at most. */
  if (hours > 744)
    return e;
  e.usable = TRUE;
  e.start_s = start;
  e.hours = hours;
  e.value = v == 0 ? 0.0 : v;
  return e;
}

typedef struct {
  gint64 t;
  double v[G_N_ELEMENTS(kLayers)];
} OHour;

/* The documented reading of one generated body, with plain arrays and linear searches. */
static GArray *
oracle_read(GArray *per_layer_elems[], const gboolean layer_ok[])
{
  GArray *out = g_array_new(FALSE, FALSE, sizeof(OHour));
  for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++) {
    if (!layer_ok[k])
      continue;
    GArray *seen = g_array_new(FALSE, FALSE, sizeof(gint64));
    guint n = MIN(per_layer_elems[k]->len, (guint)WX_MEMBER_MAX_HOURS);
    for (guint i = 0; i < n && seen->len < WX_MEMBER_MAX_HOURS; i++) {
      const GenElement *e = &g_array_index(per_layer_elems[k], GenElement, i);
      if (!e->usable)
        continue;
      for (guint h = 0; h < e->hours && seen->len < WX_MEMBER_MAX_HOURS; h++) {
        gint64 t = e->start_s + (gint64)h * HOUR;
        if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S)
          continue;
        gboolean dup = FALSE;
        for (guint j = 0; j < seen->len; j++)
          dup = dup || g_array_index(seen, gint64, j) == t;
        if (dup)
          continue;
        g_array_append_val(seen, t);
        OHour *oh = NULL;
        for (guint j = 0; j < out->len; j++)
          if (g_array_index(out, OHour, j).t == t)
            oh = &g_array_index(out, OHour, j);
        if (oh == NULL) {
          OHour fresh;
          fresh.t = t;
          for (guint f = 0; f < G_N_ELEMENTS(fresh.v); f++)
            fresh.v[f] = NAN;
          g_array_append_val(out, fresh);
          oh = &g_array_index(out, OHour, out->len - 1);
        }
        oh->v[k] = e->value;
      }
    }
    g_array_unref(seen);
  }
  /* Ascending order. */
  for (guint i = 1; i < out->len; i++)
    for (guint j = i; j > 0 && g_array_index(out, OHour, j - 1).t > g_array_index(out, OHour, j).t; j--) {
      OHour tmp = g_array_index(out, OHour, j);
      g_array_index(out, OHour, j) = g_array_index(out, OHour, j - 1);
      g_array_index(out, OHour, j - 1) = tmp;
    }
  return out;
}

static void
gen_element_clear(gpointer p)
{
  g_free(((GenElement *)p)->json);
}

static void
differential_once(GRand *rng)
{
  GArray *elems[G_N_ELEMENTS(kLayers)];
  gboolean layer_ok[G_N_ELEMENTS(kLayers)];
  g_autoptr(GString) body = g_string_new("{\"properties\":{");
  gboolean first_layer = TRUE;
  for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++) {
    elems[k] = g_array_new(FALSE, FALSE, sizeof(GenElement));
    g_array_set_clear_func(elems[k], gen_element_clear);
    layer_ok[k] = FALSE;
    gint present = g_rand_int_range(rng, 0, 6);
    if (present == 0)
      continue;
    guint n = g_rand_int_range(rng, 0, 4) == 0 ? (guint)g_rand_int_range(rng, 0, 450)
                                                : (guint)g_rand_int_range(rng, 0, 12);
    for (guint i = 0; i < n; i++) {
      GenElement e = gen_element(rng, k);
      g_array_append_val(elems[k], e);
    }
    const char *uom = kLayers[k].uom;
    if (present == 1)
      uom = "wmoUnit:other";
    layer_ok[k] = present != 1;
    g_string_append_printf(body, "%s\"%s\":{\"uom\":\"%s\",\"values\":[", first_layer ? "" : ",",
                           kLayers[k].name, uom);
    for (guint i = 0; i < n; i++)
      g_string_append_printf(body, "%s%s", i ? "," : "",
                             g_array_index(elems[k], GenElement, i).json);
    g_string_append(body, "]}");
    first_layer = FALSE;
  }
  g_string_append(body, "}}");

  g_autoptr(GArray) expect = oracle_read(elems, layer_ok);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxMember) m = wx_nws_parse_gridpoints((const guint8 *)body->str, body->len, T0, &error);
  /* Hours the oracle lists that carry at least one finite value (all of them do by construction). */
  guint want = MIN(expect->len, (guint)WX_MEMBER_MAX_HOURS);
  if (want == 0) {
    g_assert_null(m);
    g_assert_error(error, WX_ERROR, WX_ERROR_NOT_FOUND);
    g_assert_cmpstr(error->message, ==, MSG_NO_DATA);
  } else {
    g_assert_no_error(error);
    g_assert_nonnull(m);
    check_member(m);
    guint n;
    const WxHour *hours = wx_member_get_hours(m, &n);
    g_assert_cmpuint(n, ==, want);
    for (guint i = 0; i < n; i++) {
      const OHour *oh = &g_array_index(expect, OHour, i);
      g_assert_cmpint(hours[i].t_s, ==, oh->t);
      for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++) {
        double got = field_of(&hours[i], &kLayers[k]);
        assert_double_eq(got, oh->v[k]);
        if (got == 0.0)
          g_assert_false(signbit(got));
      }
    }
  }
  for (guint k = 0; k < G_N_ELEMENTS(kLayers); k++)
    g_array_unref(elems[k]);
}

static guint
fuzz_iterations(guint normal)
{
  const char *env = g_getenv("WX_NWS_FUZZ_ITERATIONS");
  if (env == NULL)
    return normal;
  guint64 v = g_ascii_strtoull(env, NULL, 10);
  return v > 0 && v < G_MAXUINT ? (guint)v : normal;
}

static void
test_grid_differential_fuzz(void)
{
  GRand *rng = g_rand_new_with_seed(20261012);
  guint iterations = fuzz_iterations(4000);
  for (guint i = 0; i < iterations; i++)
    differential_once(rng);
  g_rand_free(rng);
}

/* Random mutation of a text: byte changes, cuts, duplications. */
static GByteArray *
mutate(GRand *rng, const guint8 *data, gsize len)
{
  GByteArray *out = g_byte_array_sized_new((guint)len + 64);
  g_byte_array_append(out, data, (guint)len);
  static const char alphabet[] = "{}[]\",:0123456789.eE+-tnfruaslTZP/H\\ \n\xff\x80";
  guint rounds = (guint)g_rand_int_range(rng, 1, 5);
  for (guint r = 0; r < rounds && out->len > 2; r++) {
    guint pos = (guint)g_rand_int_range(rng, 0, (gint32)out->len);
    switch (g_rand_int_range(rng, 0, 5)) {
    case 0:
      out->data[pos] = (guint8)alphabet[g_rand_int_range(rng, 0, (gint32)sizeof alphabet - 1)];
      break;
    case 1:
      out->data[pos] ^= (guint8)(1u << g_rand_int_range(rng, 0, 8));
      break;
    case 2:
      g_byte_array_set_size(out, pos + 1);
      break;
    case 3: {
      guint want = (guint)g_rand_int_range(rng, 1, 40);
      guint cut = MIN(want, out->len - pos);
      g_byte_array_remove_range(out, pos, cut);
      break;
    }
    default: {
      guint old_len = out->len;
      guint want = (guint)g_rand_int_range(rng, 1, 60);
      guint copy = MIN(want, old_len - pos);
      guint at = (guint)g_rand_int_range(rng, 0, (gint32)old_len);
      g_autofree guint8 *tmp = g_memdup2(out->data + pos, copy);
      g_byte_array_set_size(out, old_len + copy);
      memmove(out->data + at + copy, out->data + at, old_len - at);
      memcpy(out->data + at, tmp, copy);
      break;
    }
    }
  }
  return out;
}

static void
fuzz_grid_text(GRand *rng, const guint8 *seed, gsize len, guint iterations)
{
  for (guint i = 0; i < iterations; i++) {
    g_autoptr(GByteArray) b = mutate(rng, seed, len);
    /* Exact-length heap copy so ASan sees every over-read. */
    g_autofree guint8 *copy = g_memdup2(b->data, b->len > 0 ? b->len : 1);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxMember) m = wx_nws_parse_gridpoints(copy, b->len, T0, &error);
    if (m != NULL) {
      g_assert_no_error(error);
      check_member(m);
    } else {
      g_assert_nonnull(error);
      g_assert_true(error->domain == WX_ERROR);
      g_assert_true(error->code == WX_ERROR_PARSE || error->code == WX_ERROR_NOT_FOUND);
    }
    g_autoptr(GError) error2 = NULL;
    WxNwsGrid grid;
    if (!wx_nws_parse_points(copy, b->len, &grid, &error2)) {
      g_assert_error(error2, WX_ERROR, WX_ERROR_PARSE);
    } else {
      g_assert_cmpuint(grid.x, <=, 999);
      g_assert_cmpuint(grid.y, <=, 999);
      g_assert_cmpuint(strlen(grid.grid_id), ==, 3);
    }
  }
}

static void
test_grid_mutation_fuzz(void)
{
  GRand *rng = g_rand_new_with_seed(424242);
  g_autoptr(GBytes) points = fixture("points_miami.json");
  gsize len;
  const guint8 *data = g_bytes_get_data(points, &len);
  fuzz_grid_text(rng, data, len, fuzz_iterations(1500));
  g_autoptr(GBytes) grid = fixture("gridpoints_miami.json");
  data = g_bytes_get_data(grid, &len);
  fuzz_grid_text(rng, data, len, fuzz_iterations(150));
  g_rand_free(rng);
}

/* ------------------------------------------------------------------------ */
/* Part 5: the provider against a loopback fake server                      */
/* ------------------------------------------------------------------------ */

typedef enum {
  R_REPLY,     /* status + body */
  R_HANG,      /* read the request, never answer */
  R_TRUNCATED, /* 200 whose Content-Length promises more than is sent, then close */
  R_GZIP       /* 200 with a gzip-compressed body */
} RouteKind;

typedef struct {
  char *path;        /* exact path, or a prefix when it ends in '*' */
  RouteKind kind;
  guint status;
  GBytes *body;
  guint delay_ms;
  guint fail_status; /* the first fail_count requests answer this status and "{}" ... */
  guint fail_count;  /* ... before the route's own answer */
  guint hits;
} Route;

typedef struct Fake Fake;
typedef struct {
  Fake *fake;
  GSocketConnection *connection;
  GString *request;
  guint8 buffer[2048];
  GBytes *pending;
} Conn;

struct Fake {
  GSocketService *service;
  guint port;
  GPtrArray *routes;
  GPtrArray *paths; /* request target of every request */
  GPtrArray *heads; /* complete head of every request */
  GPtrArray *held;  /* hanging connections */
  GHashTable *conns;
};

static void conn_read(Conn *conn);

static void
route_free(gpointer p)
{
  Route *r = p;
  g_free(r->path);
  g_clear_pointer(&r->body, g_bytes_unref);
  g_free(r);
}

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
  g_object_set_data_full(G_OBJECT(out), "wx-test-bytes", g_bytes_ref(bytes),
                         (GDestroyNotify)g_bytes_unref);
  g_output_stream_write_all_async(out, data, len, G_PRIORITY_DEFAULT, NULL, write_done, conn);
}

static gboolean
on_delayed_answer(gpointer user_data)
{
  Conn *conn = user_data;
  GBytes *bytes = g_steal_pointer(&conn->pending);
  respond_bytes(conn, bytes);
  g_bytes_unref(bytes);
  return G_SOURCE_REMOVE;
}

static GBytes *
gzip_of(GBytes *plain)
{
  g_autoptr(GConverter) gzip = G_CONVERTER(g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, -1));
  g_autoptr(GOutputStream) mem = g_memory_output_stream_new_resizable();
  g_autoptr(GOutputStream) zout = g_converter_output_stream_new(mem, gzip);
  gsize len;
  const void *data = g_bytes_get_data(plain, &len);
  g_assert_true(g_output_stream_write_all(zout, data, len, NULL, NULL, NULL));
  g_assert_true(g_output_stream_close(zout, NULL, NULL));
  return g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(mem));
}

static Route *
find_route(Fake *fake, const char *path)
{
  for (guint i = 0; i < fake->routes->len; i++) {
    Route *r = g_ptr_array_index(fake->routes, i);
    gsize n = strlen(r->path);
    if (n > 0 && r->path[n - 1] == '*' ? strncmp(path, r->path, n - 1) == 0
                                        : strcmp(path, r->path) == 0)
      return r;
  }
  return NULL;
}

static GBytes *
http_message(guint status, GBytes *body, const char *extra, gsize declared)
{
  gsize len;
  const void *data = g_bytes_get_data(body, &len);
  g_autofree char *head = g_strdup_printf(
    "HTTP/1.1 %u X\r\nContent-Type: application/geo+json\r\n%sContent-Length: %" G_GSIZE_FORMAT
    "\r\nConnection: close\r\n\r\n",
    status, extra, declared);
  GByteArray *all = g_byte_array_new();
  g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
  g_byte_array_append(all, data, (guint)len);
  return g_byte_array_free_to_bytes(all);
}

static void
handle_request(Conn *conn)
{
  Fake *fake = conn->fake;
  g_ptr_array_add(fake->heads, g_strdup(conn->request->str));
  const char *target = conn->request->str + 4; /* after "GET " */
  const char *end = strchr(target, ' ');
  g_autofree char *path = end != NULL ? g_strndup(target, (gsize)(end - target)) : g_strdup(target);
  g_ptr_array_add(fake->paths, g_strdup(path));
  Route *route = find_route(fake, path);
  g_autoptr(GBytes) empty = g_bytes_new_static("{}", 2);
  GBytes *bytes;
  guint delay_ms = 0;
  if (route == NULL) {
    bytes = http_message(404, empty, "", 2);
  } else {
    route->hits++;
    delay_ms = route->delay_ms;
    if (route->fail_count > 0 && route->hits <= route->fail_count) {
      bytes = http_message(route->fail_status, empty, "", 2);
    } else {
      gsize blen = g_bytes_get_size(route->body);
      switch (route->kind) {
      case R_HANG:
        g_hash_table_remove(fake->conns, conn);
        g_ptr_array_add(fake->held, conn);
        return;
      case R_TRUNCATED:
        bytes = http_message(200, route->body, "", blen + 1000);
        break;
      case R_GZIP: {
        g_autoptr(GBytes) packed = gzip_of(route->body);
        bytes = http_message(200, packed, "Content-Encoding: gzip\r\n", g_bytes_get_size(packed));
        break;
      }
      default:
        bytes = http_message(route->status, route->body, "", blen);
      }
    }
  }
  if (delay_ms > 0) {
    conn->pending = bytes;
    g_timeout_add(delay_ms, on_delayed_answer, conn);
  } else {
    respond_bytes(conn, bytes);
    g_bytes_unref(bytes);
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
  g_input_stream_read_async(g_io_stream_get_input_stream(G_IO_STREAM(conn->connection)),
                            conn->buffer, sizeof conn->buffer, G_PRIORITY_DEFAULT, NULL, read_done,
                            conn);
}

static gboolean
on_incoming(GSocketService *service, GSocketConnection *connection, GObject *source,
            gpointer user_data)
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
fake_new(void)
{
  Fake *fake = g_new0(Fake, 1);
  fake->routes = g_ptr_array_new_with_free_func(route_free);
  fake->paths = g_ptr_array_new_with_free_func(g_free);
  fake->heads = g_ptr_array_new_with_free_func(g_free);
  fake->held = g_ptr_array_new();
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
  g_ptr_array_unref(fake->routes);
  g_ptr_array_unref(fake->paths);
  g_ptr_array_unref(fake->heads);
  g_free(fake);
}

static Route *
fake_route(Fake *fake, const char *path, guint status, GBytes *body)
{
  Route *r = g_new0(Route, 1);
  r->path = g_strdup(path);
  r->kind = R_REPLY;
  r->status = status;
  r->body = body != NULL ? g_bytes_ref(body) : g_bytes_new_static("{}", 2);
  g_ptr_array_add(fake->routes, r);
  return r;
}

static Route *
fake_route_text(Fake *fake, const char *path, guint status, const char *text)
{
  g_autoptr(GBytes) body = g_bytes_new(text, strlen(text));
  return fake_route(fake, path, status, body);
}

/* Like fake_route_text(), but matched before the routes added earlier. */
static Route *
fake_route_front(Fake *fake, const char *path, guint status, const char *text)
{
  Route *r = fake_route_text(fake, path, status, text);
  g_ptr_array_insert(fake->routes, 0, g_ptr_array_steal_index(fake->routes, fake->routes->len - 1));
  return r;
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

/* A provider talking to @fake with short timing. */
static WxNws *
nws_for(const Fake *fake, guint timeout_ms, guint backoff_ms)
{
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(GError) error = NULL;
  WxNws *nws = wx_nws_new_custom(base, timeout_ms, backoff_ms, &error);
  g_assert_no_error(error);
  g_assert_nonnull(nws);
  return nws;
}

/* A fake that serves the Miami fixtures for any point. */
static Fake *
miami_fake(void)
{
  Fake *fake = fake_new();
  g_autoptr(GBytes) points = fixture("points_miami.json");
  g_autoptr(GBytes) grid = fixture("gridpoints_miami.json");
  fake_route(fake, "/points/*", 200, points);
  fake_route(fake, "/gridpoints/MFL/110,50", 200, grid);
  return fake;
}

typedef struct {
  gboolean done;
  WxSourceResult *result;
  GError *error;
  GAsyncResult *held; /* set when the callback keeps the result instead of finishing it */
} Outcome;

static void
outcome_clear(Outcome *o)
{
  g_clear_pointer(&o->result, wx_source_result_free);
  g_clear_error(&o->error);
  g_clear_object(&o->held);
  o->done = FALSE;
}

static void
on_fetched(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->result = wx_provider_fetch_finish(WX_PROVIDER(source), result, &o->error);
  o->done = TRUE;
}

static void
on_fetched_held(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)source;
  Outcome *o = user_data;
  o->held = g_object_ref(result);
  o->done = TRUE;
}

static void
wait_for(Outcome *o)
{
  gint64 until = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
  while (!o->done && g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, TRUE);
  g_assert_true(o->done);
}

/* Starts a fetch and checks the callback has not run before the call returned. */
static void
fetch_start(WxNws *nws, const WxPlace *place, GCancellable *cancellable, Outcome *o)
{
  wx_provider_fetch_async(WX_PROVIDER(nws), place, cancellable, on_fetched, o);
  g_assert_false(o->done);
}

static void
fetch(WxNws *nws, const WxPlace *place, Outcome *o)
{
  fetch_start(nws, place, NULL, o);
  wait_for(o);
}

static void
assert_failed(const Outcome *o, WxError code, const char *message)
{
  g_assert_null(o->result);
  g_assert_error(o->error, WX_ERROR, (gint)code);
  g_assert_cmpstr(o->error->message, ==, message);
}

static void
assert_ok(const Outcome *o)
{
  g_assert_no_error(o->error);
  g_assert_nonnull(o->result);
  g_assert_cmpstr(o->result->provider_id, ==, "nws");
  g_assert_cmpuint(o->result->members->len, ==, 1);
  check_member(g_ptr_array_index(o->result->members, 0));
}

static gint64
fake_clock_now;

static gint64
fake_clock(void)
{
  return fake_clock_now;
}

static void
test_net_provider_identity(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(WxNws) nws = wx_nws_new(&error);
  g_assert_no_error(error);
  g_assert_nonnull(nws);
  WxProvider *p = WX_PROVIDER(nws);
  g_assert_cmpstr(wx_provider_get_id(p), ==, "nws");
  g_assert_true(wx_id_is_valid(wx_provider_get_id(p)));
  g_assert_cmpstr(wx_provider_get_name(p), ==, "National Weather Service");
  g_assert_cmpstr(wx_provider_get_attribution(p), ==, "Source: NOAA/National Weather Service");
  g_assert_cmpstr(wx_provider_get_attribution_url(p), ==, "https://www.weather.gov/");
  g_assert_cmpstr(WX_NWS_BASE_URL, ==, "https://api.weather.gov");
  g_assert_nonnull(strstr(WX_NWS_USER_AGENT, "github.com/wtp128pro/weather"));

  g_autoptr(WxPlace) mia = miami();
  g_autoptr(WxPlace) anchorage = place_at(61.2181, -149.9003);
  g_autoptr(WxPlace) honolulu = place_at(21.3069, -157.8583);
  g_autoptr(WxPlace) san_juan = place_at(18.4655, -66.1057);
  g_autoptr(WxPlace) guam = place_at(13.4443, 144.7937);
  g_autoptr(WxPlace) london = place_at(51.5072, -0.1276);
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  g_assert_true(wx_provider_covers(p, mia));
  g_assert_true(wx_provider_covers(p, anchorage));
  g_assert_true(wx_provider_covers(p, honolulu));
  g_assert_true(wx_provider_covers(p, san_juan));
  g_assert_true(wx_provider_covers(p, guam));
  g_assert_false(wx_provider_covers(p, london));
  g_assert_false(wx_provider_covers(p, sydney));

  /* A registry accepts it (id pattern) and finds it by coverage. */
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_assert_true(wx_registry_add_provider(registry, p, &error));
  g_assert_no_error(error);
  g_assert_true(wx_registry_find_provider(registry, "nws") == p);
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, mia);
  g_assert_cmpuint(covering->len, ==, 1);
  g_autoptr(GPtrArray) none = wx_registry_list_covering(registry, london);
  g_assert_cmpuint(none->len, ==, 0);
}

static void
test_net_constructors(void)
{
  g_autoptr(GError) error = NULL;
  g_assert_null(wx_nws_new_custom("ftp://127.0.0.1", 1000, 10, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_assert_cmpstr(error->message, ==, "unacceptable base URL");
  g_clear_error(&error);
  g_assert_null(wx_nws_new_custom("http://example.com", 1000, 10, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&error);
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_nws_new_custom("http://127.0.0.1:1", 0, 10, &error)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_nws_new_custom("http://127.0.0.1:1", 600001, 10, &error)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_nws_new_custom("http://127.0.0.1:1", 1000, 600001, &error)));
  g_assert_no_error(error);
  g_autoptr(WxNws) edge = wx_nws_new_custom("http://127.0.0.1:1", 600000, 0, &error);
  g_assert_no_error(error);
  g_assert_nonnull(edge);
  ASSERT_CRITICAL("wx_nws_new_custom", g_assert_null(wx_nws_new_custom(NULL, 1000, 10, &error)));
  g_assert_no_error(error);
  g_autoptr(WxNws) ok = wx_nws_new_custom("http://127.0.0.1:1", 1000, 10, &error);
  g_assert_no_error(error);
  g_assert_nonnull(ok);
  g_autoptr(WxNws) prod = wx_nws_new(NULL);
  g_assert_nonnull(prod);
}

static void
test_net_success_and_request_shape(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = miami();
  Outcome o = {0};
  gint64 before = g_get_real_time() / G_USEC_PER_SEC;
  fetch(nws, place, &o);
  gint64 after = g_get_real_time() / G_USEC_PER_SEC;
  assert_ok(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);
  g_assert_cmpstr(fake_path(fake, 0), ==, "/points/25.7617,-80.1918");
  g_assert_cmpstr(fake_path(fake, 1), ==, "/gridpoints/MFL/110,50");
  for (guint i = 0; i < 2; i++) {
    const char *head = fake_head(fake, i);
    g_autofree char *line = g_strdup_printf("GET %s HTTP/1.1\r\n", fake_path(fake, i));
    g_assert_true(g_str_has_prefix(head, line));
    g_assert_nonnull(strstr(head, "\r\nUser-Agent: weather-app/0.1 (github.com/wtp128pro/weather)\r\n"));
    g_assert_nonnull(strstr(head, "\r\nAccept: application/geo+json\r\n"));
    g_assert_null(strstr(head, "Cookie"));
    g_assert_null(strstr(head, "Authorization"));
    g_assert_null(strstr(head, "Referer"));
    g_assert_null(strstr(head, "Mozilla"));
    g_assert_null(strstr(head, "If-Modified-Since"));
  }
  const WxMember *m = g_ptr_array_index(o.result->members, 0);
  g_assert_cmpint(wx_member_get_fetched_s(m), >=, before);
  g_assert_cmpint(wx_member_get_fetched_s(m), <=, after);
  guint n;
  const WxHour *hours = wx_member_get_hours(m, &n);
  g_assert_cmpuint(n, ==, 186);
  g_assert_cmpint(hours[0].t_s, ==, T0);
  outcome_clear(&o);

  /* The second fetch of the same point uses the cached cell: gridpoints only. */
  fetch(nws, place, &o);
  assert_ok(&o);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  g_assert_cmpstr(fake_path(fake, 2), ==, "/gridpoints/MFL/110,50");
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_gzip_answers(void)
{
  Fake *fake = fake_new();
  g_autoptr(GBytes) points = fixture("points_miami.json");
  g_autoptr(GBytes) grid = fixture("gridpoints_miami.json");
  fake_route(fake, "/points/*", 200, points)->kind = R_GZIP;
  fake_route(fake, "/gridpoints/MFL/110,50", 200, grid)->kind = R_GZIP;
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = miami();
  Outcome o = {0};
  fetch(nws, place, &o);
  assert_ok(&o);
  g_assert_nonnull(strstr(fake_head(fake, 0), "Accept-Encoding: gzip"));
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_coordinates_are_rounded(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  const struct {
    double lat, lon;
    const char *path;
  } cases[] = {
    {25.123456, -80.987654, "/points/25.1235,-80.9877"},
    {49.99996, -100.00004, "/points/50.0000,-100.0000"},
    {30.5, -90.25, "/points/30.5000,-90.2500"},
    {24.5, -70.25, "/points/24.5000,-70.2500"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(WxPlace) place = place_at(cases[i].lat, cases[i].lon);
    Outcome o = {0};
    fetch(nws, place, &o);
    assert_ok(&o);
    outcome_clear(&o);
    g_assert_cmpstr(fake_path(fake, 2 * i), ==, cases[i].path);
  }
  /* The decimal separator is a dot whatever the locale. */
  const char *locale = setlocale(LC_NUMERIC, "de_DE.UTF-8");
  if (locale == NULL)
    locale = setlocale(LC_NUMERIC, "de_DE");
  g_autoptr(WxPlace) place = place_at(31.25, -91.75);
  Outcome o = {0};
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpstr(fake_path(fake, 8), ==, "/points/31.2500,-91.7500");
  setlocale(LC_NUMERIC, "C");
  fake_free(fake);
}

static void
test_net_unsupported_point_is_remembered(void)
{
  Fake *fake = miami_fake();
  fake_route_front(fake, "/points/45.5000,-73.6000", 404, "{}");
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) montreal = place_at(45.5, -73.6);
  Outcome o = {0};
  fetch(nws, montreal, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 1); /* a 404 is not retried */
  /* Again: no network. The same point written differently (rounds to the same key) too. */
  fetch(nws, montreal, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  g_autoptr(WxPlace) near = place_at(45.500004, -73.599996);
  fetch(nws, near, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 1);
  /* Another point still reaches the network and works. */
  g_autoptr(WxPlace) mia = miami();
  fetch(nws, mia, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  fake_free(fake);
}

static void
test_net_unsupported_memory_is_bounded(void)
{
  Fake *fake = fake_new();
  fake_route_text(fake, "/points/*", 404, "{}");
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_assert_cmpint(WX_NWS_CACHE_MAX, ==, 64);
  Outcome o = {0};
  for (guint i = 0; i < 65; i++) {
    g_autoptr(WxPlace) place = place_at(30.0 + i * 0.01, -90.0);
    fetch(nws, place, &o);
    assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->paths->len, ==, 65);
  /* Points 1..64 are remembered; the first one was evicted by the 65th. */
  for (guint i = 1; i < 65; i++) {
    g_autoptr(WxPlace) place = place_at(30.0 + i * 0.01, -90.0);
    fetch(nws, place, &o);
    assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->paths->len, ==, 65);
  g_autoptr(WxPlace) first = place_at(30.0, -90.0);
  fetch(nws, first, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 66);
  g_assert_cmpstr(fake_path(fake, 65), ==, "/points/30.0000,-90.0000");
  fake_free(fake);
}

static void
test_net_grid_cache_ttl_and_cap(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = miami();
  Outcome o = {0};
  fake_clock_now = 1000 * G_USEC_PER_SEC;
  wx_nws_test_set_clock(fake_clock);
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);
  /* Just before the 7 day lifetime ends the cell is still used ... */
  fake_clock_now = ((gint64)(1000 + WX_NWS_GRID_TTL_S)) * G_USEC_PER_SEC - 1;
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  g_assert_cmpstr(fake_path(fake, 2), ==, "/gridpoints/MFL/110,50");
  /* ... at the end it is resolved again. */
  fake_clock_now = ((gint64)(1000 + WX_NWS_GRID_TTL_S)) * G_USEC_PER_SEC;
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 5);
  g_assert_cmpstr(fake_path(fake, 3), ==, "/points/25.7617,-80.1918");
  /* The refreshed cell lives another full period. */
  fake_clock_now += ((gint64)WX_NWS_GRID_TTL_S * G_USEC_PER_SEC) - 1;
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 6);
  g_assert_cmpstr(fake_path(fake, 5), ==, "/gridpoints/MFL/110,50");

  fake_clock_now = ((gint64)(1000 + WX_NWS_GRID_TTL_S)) * G_USEC_PER_SEC;
  /* Cap: 65 points, the oldest cell (Miami's) is forgotten. */
  for (guint i = 0; i < 64; i++) {
    g_autoptr(WxPlace) other = place_at(30.0 + i * 0.01, -90.0);
    fetch(nws, other, &o);
    assert_ok(&o);
    outcome_clear(&o);
  }
  guint before = fake->paths->len;
  fetch(nws, place, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, before + 2); /* points + gridpoints again */
  g_assert_cmpstr(fake_path(fake, before), ==, "/points/25.7617,-80.1918");
  /* The 64 newest are still cached: the point 30.00 was just evicted by Miami's return, 30.01 is not. */
  before = fake->paths->len;
  g_autoptr(WxPlace) second = place_at(30.01, -90.0);
  fetch(nws, second, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, before + 1);
  wx_nws_test_set_clock(NULL);
  fake_free(fake);
}

static void
test_net_rate_limit_429(void)
{
  Fake *fake = miami_fake();
  fake_route_front(fake, "/points/30.0000,-90.0000", 429, "{}");
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) place = place_at(30.0, -90.0);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  fake_clock_now = 50 * G_USEC_PER_SEC;
  wx_nws_test_set_clock(fake_clock);
  fetch(nws, place, &o);
  g_assert_null(o.result);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 1); /* 429 is never retried */
  /* For 5 s every fetch (any place) is refused without network traffic. */
  const gint64 offsets[] = {0, 1, 2 * G_USEC_PER_SEC, 5 * G_USEC_PER_SEC - 1};
  for (guint i = 0; i < G_N_ELEMENTS(offsets); i++) {
    fake_clock_now = 50 * G_USEC_PER_SEC + offsets[i];
    fetch(nws, mia, &o);
    assert_failed(&o, WX_ERROR_RATE_LIMITED,
                  "NWS asked for fewer requests; waiting 5 seconds");
    outcome_clear(&o);
    fetch(nws, place, &o);
    assert_failed(&o, WX_ERROR_RATE_LIMITED,
                  "NWS asked for fewer requests; waiting 5 seconds");
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->paths->len, ==, 1);
  /* Then requests flow again. */
  fake_clock_now = 50 * G_USEC_PER_SEC + 5 * G_USEC_PER_SEC;
  fetch(nws, mia, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  wx_nws_test_set_clock(NULL);
  fake_free(fake);
}

static void
test_net_rate_limit_on_gridpoints_and_second_step(void)
{
  Fake *fake = fake_new();
  g_autoptr(GBytes) points = fixture("points_miami.json");
  fake_route_text(fake, "/gridpoints/MFL/110,50", 429, "{}");
  fake_route(fake, "/points/*", 200, points);
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  fake_clock_now = 70 * G_USEC_PER_SEC;
  wx_nws_test_set_clock(fake_clock);
  fetch(nws, mia, &o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);
  fetch(nws, mia, &o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);
  wx_nws_test_set_clock(NULL);
  fake_free(fake);

  /* A 429 that arrives while another fetch is between its two steps stops that fetch. */
  fake = fake_new();
  g_autoptr(GBytes) grid = fixture("gridpoints_miami.json");
  Route *slow = fake_route(fake, "/points/25.7617,-80.1918", 200, points);
  slow->delay_ms = 300;
  fake_route_text(fake, "/points/30.0000,-90.0000", 429, "{}");
  fake_route(fake, "/gridpoints/MFL/110,50", 200, grid);
  g_autoptr(WxNws) nws2 = nws_for(fake, 5000, 10);
  g_autoptr(WxPlace) other = place_at(30.0, -90.0);
  Outcome a = {0}, b = {0};
  fetch_start(nws2, mia, NULL, &a);
  fetch_start(nws2, other, NULL, &b);
  wait_for(&b);
  g_assert_error(b.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  wait_for(&a);
  g_assert_error(a.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  g_assert_cmpuint(fake->paths->len, ==, 2); /* no gridpoints request */
  outcome_clear(&a);
  outcome_clear(&b);
  fake_free(fake);
}

static void
test_net_http_errors(void)
{
  struct {
    guint points_status;
    guint grid_status;
    WxError code;
    guint requests;
  } cases[] = {
    {500, 200, WX_ERROR_HTTP, 3},   /* /points 5xx: retried twice, then failed */
    {403, 200, WX_ERROR_HTTP, 1},
    {301, 200, WX_ERROR_HTTP, 1},
    {200, 500, WX_ERROR_HTTP, 4},   /* points (1) + gridpoints (3 attempts) */
    {200, 404, WX_ERROR_NOT_FOUND, 2},
    {200, 403, WX_ERROR_HTTP, 2},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Fake *fake = fake_new();
    g_autoptr(GBytes) points = fixture("points_miami.json");
    fake_route(fake, "/points/*", cases[i].points_status, cases[i].points_status == 200 ? points : NULL);
    fake_route_text(fake, "/gridpoints/MFL/110,50", cases[i].grid_status, "{}");
    g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
    g_autoptr(WxPlace) mia = miami();
    Outcome o = {0};
    fetch(nws, mia, &o);
    g_assert_null(o.result);
    g_assert_error(o.error, WX_ERROR, (gint)cases[i].code);
    g_assert_cmpuint(fake->paths->len, ==, cases[i].requests);
    outcome_clear(&o);
    fake_free(fake);
  }
}

static void
test_net_transient_5xx_then_success(void)
{
  Fake *fake = miami_fake();
  ((Route *)g_ptr_array_index(fake->routes, 0))->fail_status = 503;
  ((Route *)g_ptr_array_index(fake->routes, 0))->fail_count = 1;
  ((Route *)g_ptr_array_index(fake->routes, 1))->fail_status = 500;
  ((Route *)g_ptr_array_index(fake->routes, 1))->fail_count = 2;
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  fetch(nws, mia, &o);
  assert_ok(&o);
  g_assert_cmpuint(fake->paths->len, ==, 5); /* 2 for points, 3 for gridpoints */
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_not_found_grid_forgets_the_cell(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  fetch(nws, mia, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);
  Route *grid = g_ptr_array_index(fake->routes, 1);
  grid->status = 404;
  fetch(nws, mia, &o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_NOT_FOUND);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  /* The cell was dropped: the next fetch resolves the point again, and works once repaired. */
  grid->status = 200;
  fetch(nws, mia, &o);
  assert_ok(&o);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 5);
  g_assert_cmpstr(fake_path(fake, 3), ==, "/points/25.7617,-80.1918");
  fake_free(fake);
}

static void
test_net_bad_bodies(void)
{
  struct {
    const char *points;
    const char *grid;
    WxError code;
    const char *message;
    guint requests;
  } cases[] = {
    {"{}", "{}", WX_ERROR_PARSE, MSG_NO_GRID, 1},
    {"not json", "{}", WX_ERROR_PARSE, "malformed JSON", 1},
    {"[]", "{}", WX_ERROR_PARSE, "response is not a JSON object", 1},
    {"{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}", "{}", WX_ERROR_PARSE,
     MSG_NO_PROPS, 2},
    {"{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}", "{\"properties\":{}}",
     WX_ERROR_NOT_FOUND, MSG_NO_DATA, 2},
    {"{\"properties\":{\"gridId\":\"MFL\",\"gridX\":110,\"gridY\":50}}", "", WX_ERROR_PARSE,
     "empty response", 2},
    /* A grid id that is not what the validator accepts never reaches a request path. */
    {"{\"properties\":{\"gridId\":\"M/L\",\"gridX\":110,\"gridY\":50}}", "{}", WX_ERROR_PARSE,
     MSG_NO_GRID, 1},
    {"{\"properties\":{\"gridId\":\"../\",\"gridX\":1,\"gridY\":50}}", "{}", WX_ERROR_PARSE,
     MSG_NO_GRID, 1},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Fake *fake = fake_new();
    fake_route_text(fake, "/points/*", 200, cases[i].points);
    fake_route_text(fake, "/gridpoints/MFL/110,50", 200, cases[i].grid);
    g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
    g_autoptr(WxPlace) mia = miami();
    Outcome o = {0};
    fetch(nws, mia, &o);
    assert_failed(&o, cases[i].code, cases[i].message);
    g_assert_cmpuint(fake->paths->len, ==, cases[i].requests);
    outcome_clear(&o);
    fake_free(fake);
  }
}

static void
test_net_truncated_and_hanging_answers(void)
{
  /* A body that ends before its Content-Length: network error after 3 attempts. */
  Fake *fake = miami_fake();
  ((Route *)g_ptr_array_index(fake->routes, 0))->kind = R_TRUNCATED;
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  fetch(nws, mia, &o);
  g_assert_null(o.result);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_NETWORK);
  g_assert_cmpuint(fake->paths->len, ==, 3);
  outcome_clear(&o);
  fake_free(fake);

  /* A server that never answers: every attempt times out. */
  fake = miami_fake();
  ((Route *)g_ptr_array_index(fake->routes, 1))->kind = R_HANG;
  g_autoptr(WxNws) nws2 = nws_for(fake, 150, 5);
  fetch(nws2, mia, &o);
  g_assert_null(o.result);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fake->paths->len, ==, 4); /* points + 3 gridpoints attempts */
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_cancellation(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};

  /* Cancelled before the call: no network. */
  g_autoptr(GCancellable) pre = g_cancellable_new();
  g_cancellable_cancel(pre);
  fetch_start(nws, mia, pre, &o);
  wait_for(&o);
  g_assert_null(o.result);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->paths->len, ==, 0);
  outcome_clear(&o);

  /* Cancelled while /points hangs. */
  ((Route *)g_ptr_array_index(fake->routes, 0))->kind = R_HANG;
  g_autoptr(GCancellable) c1 = g_cancellable_new();
  fetch_start(nws, mia, c1, &o);
  while (fake->paths->len < 1)
    g_main_context_iteration(NULL, TRUE);
  g_assert_false(o.done);
  g_cancellable_cancel(c1);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->paths->len, ==, 1);
  outcome_clear(&o);

  /* Cancelled while /gridpoints hangs; the resolved cell is kept for the next fetch. */
  ((Route *)g_ptr_array_index(fake->routes, 0))->kind = R_REPLY;
  ((Route *)g_ptr_array_index(fake->routes, 1))->kind = R_HANG;
  g_autoptr(GCancellable) c2 = g_cancellable_new();
  fetch_start(nws, mia, c2, &o);
  while (fake->paths->len < 3)
    g_main_context_iteration(NULL, TRUE);
  g_cancellable_cancel(c2);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);
  ((Route *)g_ptr_array_index(fake->routes, 1))->kind = R_REPLY;
  guint before = fake->paths->len;
  fetch(nws, mia, &o);
  assert_ok(&o);
  g_assert_cmpuint(fake->paths->len, ==, before + 1);
  outcome_clear(&o);

  /* Cancelled after success but before finish: finish reports the cancellation. */
  g_autoptr(GCancellable) c3 = g_cancellable_new();
  wx_provider_fetch_async(WX_PROVIDER(nws), mia, c3, on_fetched_held, &o);
  wait_for(&o);
  g_cancellable_cancel(c3);
  g_autoptr(GError) error = NULL;
  g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(nws), o.held, &error));
  g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_cancelled_beats_refusals(void)
{
  /* A cancellable that is cancelled before finish wins over every other outcome, refusals
   * included (wx-provider.h): remembered 404, 429 back-off, invalid and uncovered places. */
  Fake *fake = fake_new();
  fake_route_text(fake, "/points/45.5000,-73.6000", 404, "{}");
  fake_route_text(fake, "/points/30.0000,-90.0000", 429, "{}");
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) montreal = place_at(45.5, -73.6);
  g_autoptr(WxPlace) limited = place_at(30.0, -90.0);
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  const WxPlace bad = {(char *)"", (char *)"", (char *)"", "", 25.0, -80.0, (char *)""};
  Outcome o = {0};
  fetch(nws, montreal, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  fetch(nws, limited, &o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 2);

  const WxPlace *places[] = {montreal, limited, sydney, &bad};
  for (guint i = 0; i < G_N_ELEMENTS(places); i++) {
    g_autoptr(GCancellable) cancelled = g_cancellable_new();
    g_cancellable_cancel(cancelled);
    fetch_start(nws, places[i], cancelled, &o);
    wait_for(&o);
    g_assert_null(o.result);
    g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->paths->len, ==, 2);
  fake_free(fake);
}

static void
test_net_dispose_in_flight(void)
{
  Fake *fake = miami_fake();
  ((Route *)g_ptr_array_index(fake->routes, 0))->delay_ms = 150;
  ((Route *)g_ptr_array_index(fake->routes, 1))->delay_ms = 150;
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0}, p = {0};
  WxNws *nws = nws_for(fake, 5000, 5);
  fetch_start(nws, mia, NULL, &o);
  g_object_unref(nws); /* the operation keeps the provider alive */
  wait_for(&o);
  assert_ok(&o);
  outcome_clear(&o);

  /* run_dispose in flight: the provider still serves the operation and new fetches. */
  nws = nws_for(fake, 5000, 5);
  fetch_start(nws, mia, NULL, &o);
  g_object_run_dispose(G_OBJECT(nws));
  wait_for(&o);
  assert_ok(&o);
  outcome_clear(&o);
  fetch(nws, mia, &o);
  assert_ok(&o);
  outcome_clear(&o);

  /* Two concurrent fetches of one place, then the last reference dropped before both finish. */
  fetch_start(nws, mia, NULL, &o);
  fetch_start(nws, mia, NULL, &p);
  g_object_unref(nws);
  wait_for(&o);
  wait_for(&p);
  assert_ok(&o);
  assert_ok(&p);
  outcome_clear(&o);
  outcome_clear(&p);
  fake_free(fake);
}

typedef struct {
  WxNws *nws;
  WxPlace *place;
  Outcome *outcome;
  gboolean returned_not_done;
} IdleCall;

static gboolean
call_fetch_from_source(gpointer user_data)
{
  IdleCall *c = user_data;
  wx_provider_fetch_async(WX_PROVIDER(c->nws), c->place, NULL, on_fetched, c->outcome);
  c->returned_not_done = !c->outcome->done;
  return G_SOURCE_REMOVE;
}

static void
test_net_callback_never_before_return(void)
{
  Fake *fake = miami_fake();
  fake_route_front(fake, "/points/45.5000,-73.6000", 404, "{}");
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) london = place_at(51.5, -0.12);
  g_autoptr(WxPlace) montreal = place_at(45.5, -73.6);
  g_autoptr(WxPlace) mia = miami();
  /* A hand-built place that violates the wx_place_new() rules. */
  WxPlace bad = {g_strdup(""), g_strdup(""), g_strdup(""), "", 25.0, -80.0, g_strdup("")};
  Outcome o = {0};
  IdleCall call = {nws, NULL, &o, FALSE};

  /* Learn that Montreal is unsupported (one request), and trigger the 429 block. */
  fetch(nws, montreal, &o);
  outcome_clear(&o);
  const struct {
    WxPlace *place;
    WxError code;
    const char *message;
  } cases[] = {
    {&bad, WX_ERROR_INVALID_ARG, MSG_BAD_PLACE},
    {london, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE},
    {montreal, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    call.place = cases[i].place;
    g_idle_add(call_fetch_from_source, &call);
    wait_for(&o);
    g_assert_true(call.returned_not_done);
    assert_failed(&o, cases[i].code, cases[i].message);
    outcome_clear(&o);
  }
  /* An already cancelled cancellable and a rate-limit refusal, also from a source. */
  call.place = mia;
  g_autoptr(GCancellable) cancelled = g_cancellable_new();
  g_cancellable_cancel(cancelled);
  wx_provider_fetch_async(WX_PROVIDER(nws), mia, cancelled, on_fetched, &o);
  g_assert_false(o.done);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 1);
  g_free(bad.name);
  g_free(bad.admin1);
  g_free(bad.country);
  g_free(bad.timezone);
  fake_free(fake);

  fake = fake_new();
  fake_route_text(fake, "/points/*", 429, "{}");
  g_autoptr(WxNws) nws2 = nws_for(fake, 5000, 5);
  fetch(nws2, mia, &o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  call.nws = nws2;
  g_idle_add(call_fetch_from_source, &call);
  wait_for(&o);
  g_assert_true(call.returned_not_done);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 1);
  fake_free(fake);
}

static void
test_net_invalid_and_uncovered_places_make_no_request(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  Outcome o = {0};
  const WxPlace nan_lat = {(char *)"X", (char *)"", (char *)"", "", NAN, -80.0, (char *)""};
  const WxPlace big_lat = {(char *)"X", (char *)"", (char *)"", "", 95.0, -80.0, (char *)""};
  const WxPlace null_name = {NULL, (char *)"", (char *)"", "", 30.0, -80.0, (char *)""};
  const WxPlace *bad[] = {&nan_lat, &big_lat, &null_name};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    fetch(nws, bad[i], &o);
    assert_failed(&o, WX_ERROR_INVALID_ARG, MSG_BAD_PLACE);
    outcome_clear(&o);
  }
  g_autoptr(WxPlace) sydney = place_at(-33.8688, 151.2093);
  fetch(nws, sydney, &o);
  assert_failed(&o, WX_ERROR_UNSUPPORTED, MSG_OUTSIDE);
  outcome_clear(&o);
  g_assert_cmpuint(fake->paths->len, ==, 0);
  fake_free(fake);
}

static void
test_net_finish_programmer_errors(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxNws) other = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) mia = miami();
  Outcome o = {0};
  wx_provider_fetch_async(WX_PROVIDER(nws), mia, NULL, on_fetched_held, &o);
  wait_for(&o);
  /* A result of another provider instance. */
  ASSERT_CRITICAL("g_task_is_valid", g_assert_null(wx_provider_fetch_finish(WX_PROVIDER(other), o.held, NULL)));
  g_autoptr(GError) error = NULL;
  g_autoptr(WxSourceResult) r = wx_provider_fetch_finish(WX_PROVIDER(nws), o.held, &error);
  g_assert_no_error(error);
  g_assert_nonnull(r);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_concurrent_fetches(void)
{
  Fake *fake = miami_fake();
  g_autoptr(WxNws) nws = nws_for(fake, 5000, 5);
  g_autoptr(WxPlace) a = miami();
  g_autoptr(WxPlace) b = place_at(30.0, -90.0);
  Outcome oa = {0}, ob = {0}, oc = {0};
  fetch_start(nws, a, NULL, &oa);
  fetch_start(nws, b, NULL, &ob);
  fetch_start(nws, a, NULL, &oc);
  wait_for(&oa);
  wait_for(&ob);
  wait_for(&oc);
  assert_ok(&oa);
  assert_ok(&ob);
  assert_ok(&oc);
  outcome_clear(&oa);
  outcome_clear(&ob);
  outcome_clear(&oc);
  fake_free(fake);
}

/* ------------------------------------------------------------------------ */
/* main                                                                     */
/* ------------------------------------------------------------------------ */

static char *test_root;

static void
rm_rf(const char *path)
{
  if (g_file_test(path, G_FILE_TEST_IS_DIR) && !g_file_test(path, G_FILE_TEST_IS_SYMLINK)) {
    GDir *dir = g_dir_open(path, 0, NULL);
    if (dir != NULL) {
      const char *name;
      while ((name = g_dir_read_name(dir)) != NULL) {
        g_autofree char *child = g_build_filename(path, name, NULL);
        rm_rf(child);
      }
      g_dir_close(dir);
    }
  }
  g_remove(path);
}

static void
cleanup_root(void)
{
  if (test_root != NULL)
    rm_rf(test_root);
  g_free(test_root);
  test_root = NULL;
}

/* Points every XDG directory into a fresh temporary root; aborts when that fails. */
static void
isolate_environment(void)
{
  GError *error = NULL;
  test_root = g_dir_make_tmp("wx-nws-XXXXXX", &error);
  if (test_root == NULL) {
    g_printerr("cannot create the test directory: %s\n", error->message);
    abort();
  }
  const char *vars[] = {"XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                        "XDG_RUNTIME_DIR"};
  for (guint i = 0; i < G_N_ELEMENTS(vars); i++) {
    g_autofree char *dir = g_build_filename(test_root, vars[i], NULL);
    if (g_mkdir_with_parents(dir, 0700) != 0 || !g_setenv(vars[i], dir, TRUE)) {
      g_printerr("cannot set up %s\n", vars[i]);
      abort();
    }
  }
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  atexit(cleanup_root);
}

int
main(int argc, char **argv)
{
  isolate_environment();
  g_test_init(&argc, &argv, NULL);

  g_test_add_func("/nws/points/fixture", test_points_fixture);
  g_test_add_func("/nws/points/accepts-shapes", test_points_accepts_shapes);
  g_test_add_func("/nws/points/rejects-bad-grid", test_points_rejects_bad_grid);
  g_test_add_func("/nws/points/rejects-bad-json", test_points_rejects_bad_json);
  g_test_add_func("/nws/points/programmer-errors", test_points_programmer_errors);
  g_test_add_func("/nws/points/guard-page", test_points_guard_page);

  g_test_add_func("/nws/grid/fixture-vs-oracle", test_grid_fixture_vs_oracle);
  g_test_add_func("/nws/grid/fixture-stable", test_grid_fixture_member_is_stable);
  g_test_add_func("/nws/grid/each-layer-and-unit", test_grid_each_layer_and_unit);
  g_test_add_func("/nws/grid/ignores-other-layers", test_grid_ignores_other_layers);
  g_test_add_func("/nws/grid/expansion", test_grid_expansion);
  g_test_add_func("/nws/grid/precipitation-divided", test_grid_precipitation_is_divided);
  g_test_add_func("/nws/grid/value-ranges", test_grid_value_ranges);
  g_test_add_func("/nws/grid/bad-elements-skipped", test_grid_bad_elements_are_skipped);
  g_test_add_func("/nws/grid/time-zones-and-bounds", test_grid_time_zones_and_bounds);
  g_test_add_func("/nws/grid/overlap-first-wins", test_grid_overlap_first_wins);
  g_test_add_func("/nws/grid/union-ascending", test_grid_union_is_ascending_and_sparse);
  g_test_add_func("/nws/grid/caps", test_grid_caps);
  g_test_add_func("/nws/grid/large-hostile-bodies", test_grid_large_hostile_bodies);
  g_test_add_func("/nws/grid/parse-errors", test_grid_parse_errors);
  g_test_add_func("/nws/grid/fetched-time", test_grid_fetched_time_is_validated);
  g_test_add_func("/nws/grid/programmer-errors", test_grid_programmer_errors);
  g_test_add_func("/nws/grid/guard-page", test_grid_guard_page);
  g_test_add_func("/nws/grid/differential-fuzz", test_grid_differential_fuzz);
  g_test_add_func("/nws/grid/mutation-fuzz", test_grid_mutation_fuzz);

  g_test_add_func("/nws/net/identity", test_net_provider_identity);
  g_test_add_func("/nws/net/constructors", test_net_constructors);
  g_test_add_func("/nws/net/success-and-request-shape", test_net_success_and_request_shape);
  g_test_add_func("/nws/net/gzip", test_net_gzip_answers);
  g_test_add_func("/nws/net/coordinates-rounded", test_net_coordinates_are_rounded);
  g_test_add_func("/nws/net/unsupported-remembered", test_net_unsupported_point_is_remembered);
  g_test_add_func("/nws/net/unsupported-bounded", test_net_unsupported_memory_is_bounded);
  g_test_add_func("/nws/net/grid-cache", test_net_grid_cache_ttl_and_cap);
  g_test_add_func("/nws/net/rate-limit-429", test_net_rate_limit_429);
  g_test_add_func("/nws/net/rate-limit-steps", test_net_rate_limit_on_gridpoints_and_second_step);
  g_test_add_func("/nws/net/http-errors", test_net_http_errors);
  g_test_add_func("/nws/net/transient-5xx", test_net_transient_5xx_then_success);
  g_test_add_func("/nws/net/grid-404", test_net_not_found_grid_forgets_the_cell);
  g_test_add_func("/nws/net/bad-bodies", test_net_bad_bodies);
  g_test_add_func("/nws/net/truncated-and-hanging", test_net_truncated_and_hanging_answers);
  g_test_add_func("/nws/net/cancellation", test_net_cancellation);
  g_test_add_func("/nws/net/cancelled-beats-refusals", test_net_cancelled_beats_refusals);
  g_test_add_func("/nws/net/dispose-in-flight", test_net_dispose_in_flight);
  g_test_add_func("/nws/net/callback-not-before-return", test_net_callback_never_before_return);
  g_test_add_func("/nws/net/invalid-and-uncovered", test_net_invalid_and_uncovered_places_make_no_request);
  g_test_add_func("/nws/net/finish-programmer-errors", test_net_finish_programmer_errors);
  g_test_add_func("/nws/net/concurrent", test_net_concurrent_fetches);
  return g_test_run();
}
