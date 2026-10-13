/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-openmeteo.c - Open-Meteo provider and geocoder. See wx-openmeteo.h. */
#include "wx-openmeteo.h"

#include <math.h>
#include <string.h>

#include "wx-geo.h"
#include "wx-http.h"
#include "wx-json.h"
#include "wx-text.h"

#define OPEN_METEO_NAME "Open-Meteo"
#define OPEN_METEO_ATTRIBUTION "Weather data by Open-Meteo.com"
#define OPEN_METEO_ATTRIBUTION_URL "https://open-meteo.com/"
#define OPEN_METEO_USER_AGENT "weather-app/0.1 (github.com/wtp128pro/weather)"
#define OPEN_METEO_ACCEPT "application/json"

/* Longest server-supplied error reason put into an error message, characters. */
#define REASON_MAX_CHARS 120
/* Most models of one request: the whole allow-list. */
#define MAX_MODELS 8
/* Most hits requested from the geocoder (count=10 in the request). */
#define SEARCH_COUNT 10

/* Source tags of the tasks created by the async functions. */
static char tag_fetch, tag_search;

/* ------------------------------------------------------------------------ */
/* Model allow-list and variables                                           */
/* ------------------------------------------------------------------------ */

typedef struct {
  const char *api_id;    /* name in the "models=" parameter and in the body keys */
  const char *member_id; /* WxMember model id */
} ModelEntry;

/* The compile-time allow-list: the request is built only from these names. */
static const ModelEntry model_table[] = {
  {"ncep_hrrr_conus", "hrrr"},
  {"ncep_nbm_conus", "nbm"},
  {"gfs_seamless", "gfs"},
  {"ecmwf_ifs025", "ecmwf"},
  {"icon_seamless", "icon"},
  {"gem_seamless", "gem"},
  {"ukmo_seamless", "ukmo"},
  {"meteofrance_seamless", "meteofrance"},
};
G_STATIC_ASSERT(G_N_ELEMENTS(model_table) == MAX_MODELS);

typedef enum {
  VAR_TEMP,
  VAR_FEELS,
  VAR_HUMIDITY,
  VAR_PRECIP,
  VAR_PROB,
  VAR_CLOUD,
  VAR_WIND,
  VAR_GUST,
  VAR_WMO,
  VAR_COUNT
} Var;

typedef struct {
  const char *key; /* body key without the model suffix */
  double lo, hi;   /* accepted range, inclusive */
} VarSpec;

static const VarSpec var_table[VAR_COUNT] = {
  [VAR_TEMP] = {"temperature_2m", WX_TEMP_MIN_C, WX_TEMP_MAX_C},
  [VAR_FEELS] = {"apparent_temperature", WX_TEMP_MIN_C, WX_TEMP_MAX_C},
  [VAR_HUMIDITY] = {"relative_humidity_2m", WX_PERCENT_MIN, WX_PERCENT_MAX},
  [VAR_PRECIP] = {"precipitation", 0.0, WX_PRECIP_MAX_MM_H},
  [VAR_PROB] = {"precipitation_probability", WX_PERCENT_MIN, WX_PERCENT_MAX},
  [VAR_CLOUD] = {"cloud_cover", WX_PERCENT_MIN, WX_PERCENT_MAX},
  [VAR_WIND] = {"wind_speed_10m", 0.0, WX_WIND_MAX_KMH},
  [VAR_GUST] = {"wind_gusts_10m", 0.0, WX_WIND_MAX_KMH},
  [VAR_WMO] = {"weather_code", 0.0, 99.0},
};

/**
 * model_find:
 * @api_id: (nullable): candidate API model name.
 *
 * Looks a model up in the allow-list.
 *
 * Preconditions:
 *  - @api_id is NULL or NUL-terminated.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the entry is static.
 *
 * Returns: (transfer none) (nullable): the entry, or NULL when @api_id is NULL
 *   or not on the allow-list.
 */
static const ModelEntry *
model_find(const char *api_id)
{
  if (api_id == NULL)
    return NULL;
  for (guint i = 0; i < G_N_ELEMENTS(model_table); i++)
    if (strcmp(model_table[i].api_id, api_id) == 0)
      return &model_table[i];
  return NULL;
}

/**
 * models_for_place:
 * @lat: latitude of a valid place.
 * @lon: longitude of a valid place.
 * @out: (out) (array fixed-size=8): receives the API names, in request order.
 * @conus: (out): TRUE when the place is in the CONUS branch (request B too).
 *
 * Chooses the model list of request A (see the file comment of the header).
 *
 * Preconditions:
 *  - @out has room for MAX_MODELS entries; @conus is non-NULL.
 * Postconditions:
 *  - the first returned entries of @out are static allow-list names, without
 *    repetition.
 * Thread affinity: any thread (pure).
 * Ownership: the names are static strings.
 *
 * Returns: the number of models, 4..6.
 */
static guint
models_for_place(double lat, double lon, const char **out, gboolean *conus)
{
  guint n = 0;
  *conus = FALSE;
  if (wx_geo_in_us_nws(lat, lon)) {
    if (wx_geo_in_conus(lat, lon)) {
      *conus = TRUE;
      out[n++] = "ncep_hrrr_conus";
      out[n++] = "ncep_nbm_conus";
    }
    out[n++] = "gfs_seamless";
    out[n++] = "ecmwf_ifs025";
    out[n++] = "icon_seamless";
    out[n++] = "gem_seamless";
    return n;
  }
  out[n++] = "ecmwf_ifs025";
  out[n++] = "icon_seamless";
  out[n++] = "gem_seamless";
  out[n++] = "gfs_seamless";
  if (wx_geo_in_europe(lat, lon)) {
    out[n++] = "ukmo_seamless";
    out[n++] = "meteofrance_seamless";
  }
  return n;
}

/**
 * coord_text:
 * @v: a valid coordinate in degrees.
 *
 * Formats a coordinate for a request: rounded to four decimals, "." decimal
 * point whatever the locale, negative zero printed as 0.0000.
 *
 * Preconditions:
 *  - @v is finite and within [-180, 180].
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the text, e.g. "-80.1918".
 */
static char *
coord_text(double v)
{
  char buf[G_ASCII_DTOSTR_BUF_SIZE];
  return g_strdup(g_ascii_formatd(buf, sizeof buf, "%.4f", wx_geo_round4(v)));
}

/**
 * forecast_path:
 * @lat: latitude of a valid place.
 * @lon: longitude of a valid place.
 * @models: the model API names (allow-list names).
 * @n_models: number of entries of @models, 1..MAX_MODELS.
 *
 * Builds the path-and-query of request A.
 *
 * Preconditions:
 *  - the place is valid; @models holds @n_models allow-list names.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the request target.
 */
static char *
forecast_path(double lat, double lon, const char *const *models, guint n_models)
{
  g_autofree char *lat_text = coord_text(lat);
  g_autofree char *lon_text = coord_text(lon);
  g_autoptr(GString) list = g_string_new(NULL);
  for (guint i = 0; i < n_models; i++) {
    if (i > 0)
      g_string_append_c(list, ',');
    g_string_append(list, models[i]);
  }
  return g_strconcat("/v1/forecast?latitude=", lat_text, "&longitude=", lon_text,
                     "&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,"
                     "precipitation,precipitation_probability,cloud_cover,wind_speed_10m,"
                     "wind_gusts_10m,weather_code&models=",
                     list->str,
                     "&timeformat=unixtime&timezone=GMT&forecast_days=10&wind_speed_unit=kmh"
                     "&temperature_unit=celsius&precipitation_unit=mm",
                     NULL);
}

/**
 * nowcast_path:
 * @lat: latitude of a valid place.
 * @lon: longitude of a valid place.
 *
 * Builds the path-and-query of request B.
 *
 * Preconditions:
 *  - the place is valid.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the request target.
 */
static char *
nowcast_path(double lat, double lon)
{
  g_autofree char *lat_text = coord_text(lat);
  g_autofree char *lon_text = coord_text(lon);
  return g_strconcat("/v1/forecast?latitude=", lat_text, "&longitude=", lon_text,
                     "&minutely_15=precipitation&models=ncep_hrrr_conus&forecast_minutely_15=12"
                     "&timeformat=unixtime&timezone=GMT&precipitation_unit=mm",
                     NULL);
}

/* ------------------------------------------------------------------------ */
/* JSON helpers                                                             */
/* ------------------------------------------------------------------------ */

/**
 * api_error:
 * @root: (nullable): the root object of a parsed body.
 * @error: (nullable): return location for a #GError.
 *
 * Recognises the Open-Meteo error body {"error":true,"reason":"..."}.
 *
 * Preconditions:
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - when the body is an error body, *@error is set to WX_ERROR_HTTP with the
 *    sanitised reason (at most REASON_MAX_CHARS characters) in the message.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @root is an error body (and @error was set).
 */
static gboolean
api_error(JsonObject *root, GError **error)
{
  g_autofree char *reason = wx_json_error_reason(root, REASON_MAX_CHARS);
  if (reason == NULL)
    return FALSE;
  g_set_error(error, WX_ERROR, WX_ERROR_HTTP, "Open-Meteo reported an error: %s", reason);
  return TRUE;
}

/**
 * parse_root:
 * @data: (nullable): body bytes.
 * @len: number of bytes at @data.
 * @error: (nullable): return location for a #GError.
 *
 * Parses a body as one JSON object and screens it for the API error shape.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0.
 * Postconditions:
 *  - on success the parser is returned; on failure NULL and *@error is
 *    WX_ERROR_PARSE or WX_ERROR_HTTP (error body).
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the parser.
 *
 * Returns: (transfer full) (nullable): the parser; the root is an object.
 */
static JsonParser *
parse_root(const guint8 *data, gsize len, GError **error)
{
  JsonParser *parser = wx_json_parse(data, len, WX_HTTP_MAX_BODY_BYTES, WX_JSON_ROOT_OBJECT, error);
  if (parser == NULL)
    return NULL;
  if (api_error(json_node_get_object(json_parser_get_root(parser)), error)) {
    g_object_unref(parser);
    return NULL;
  }
  return parser;
}

/**
 * array_number:
 * @array: (nullable): value array.
 * @i: element index.
 * @lo: inclusive lower bound.
 * @hi: inclusive upper bound.
 *
 * Reads one value of a body array defensively: negative zero becomes +0.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the value when @array has an element @i that is a finite number in
 *   [@lo, @hi]; else NAN.
 */
static double
array_number(JsonArray *array, guint i, double lo, double hi)
{
  double v;
  if (array == NULL || i >= json_array_get_length(array))
    return NAN;
  if (!wx_json_number_in_range(json_array_get_element(array, i), lo, hi, &v))
    return NAN;
  return v == 0.0 ? 0.0 : v;
}

/**
 * array_wmo:
 * @array: (nullable): the weather_code array.
 * @i: element index.
 *
 * Reads one WMO weather code.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the code when the element is an integer-valued number in 0..99;
 *   else -1.
 */
static int
array_wmo(JsonArray *array, guint i)
{
  double v = array_number(array, i, 0.0, 99.0);
  return (isnan(v) || v != floor(v)) ? -1 : (int)v;
}

/**
 * stamp_from_node:
 * @node: (nullable): a "time" element.
 * @step: required divisor of the stamp, seconds (3600 or 900).
 * @t_s: (out): receives the stamp.
 *
 * Reads one unix-time stamp defensively.
 *
 * Preconditions:
 *  - @t_s is non-NULL.
 * Postconditions:
 *  - on TRUE *@t_s is a multiple of @step within [WX_TIME_MIN_S, WX_TIME_MAX_S);
 *    on FALSE it is untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: whether the node is an integer-valued number of that kind.
 */
static gboolean
stamp_from_node(JsonNode *node, gint64 step, gint64 *t_s)
{
  double v;
  if (!wx_json_number_in_range(node, (double)WX_TIME_MIN_S, (double)(WX_TIME_MAX_S - 1), &v))
    return FALSE;
  if (v != floor(v))
    return FALSE;
  gint64 s = (gint64)v;
  if (s % step != 0)
    return FALSE;
  *t_s = s;
  return TRUE;
}

/**
 * read_stamps:
 * @times: (nullable): the "time" array.
 * @step: required divisor of a stamp, seconds.
 * @max_steps: longest accepted array.
 * @stamps: (out) (array length=max_steps): receives the used stamps.
 * @index: (out) (array length=max_steps): receives their array indices.
 * @n_used: (out): receives how many stamps are used.
 *
 * Selects the usable "time" entries: stamp_from_node() succeeds and the stamp is
 * greater than the previous used one.
 *
 * Preconditions:
 *  - @stamps and @index have room for @max_steps entries.
 * Postconditions:
 *  - the used stamps are strictly ascending; *@n_used <= @max_steps.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: FALSE when @times has more than @max_steps entries (nothing is
 *   used), else TRUE.
 */
static gboolean
read_stamps(JsonArray *times, gint64 step, guint max_steps, gint64 *stamps, guint *index,
            guint *n_used)
{
  guint n = json_array_get_length(times);
  *n_used = 0;
  if (n > max_steps)
    return FALSE;
  for (guint i = 0; i < n; i++) {
    gint64 t;
    if (!stamp_from_node(json_array_get_element(times, i), step, &t))
      continue;
    if (*n_used > 0 && t <= stamps[*n_used - 1])
      continue;
    stamps[*n_used] = t;
    index[*n_used] = i;
    (*n_used)++;
  }
  return TRUE;
}

/* ------------------------------------------------------------------------ */
/* Forecast parser                                                          */
/* ------------------------------------------------------------------------ */

/**
 * hour_finite_count:
 * @hour: an hour.
 *
 * Counts the finite numeric fields of an hour.
 *
 * Preconditions:
 *  - @hour is non-NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: 0..8.
 */
static guint
hour_finite_count(const WxHour *hour)
{
  const double v[] = {hour->temp_c,   hour->feels_c,  hour->precip_mm, hour->precip_prob,
                      hour->cloud_pct, hour->wind_kmh, hour->gust_kmh,  hour->humidity_pct};
  guint n = 0;
  for (guint i = 0; i < G_N_ELEMENTS(v); i++)
    if (isfinite(v[i]))
      n++;
  return n;
}

/**
 * flush_hour:
 * @member: the member under construction (single owner).
 * @hour: the finished bucket.
 * @n_values: (inout): running count of finite numeric values stored.
 *
 * Appends a bucket unless it carries no value at all (no finite number and no
 * weather code).
 *
 * Preconditions:
 *  - @hour->t_s is greater than the t_s of every bucket added before.
 * Postconditions:
 *  - when the member accepted the bucket, *@n_values grew by its finite
 *    numeric fields.
 * Thread affinity: builder only.
 * Ownership: nothing is retained.
 */
static void
flush_hour(WxMember *member, const WxHour *hour, guint *n_values)
{
  guint finite = hour_finite_count(hour);
  if (finite == 0 && hour->wmo < 0)
    return;
  if (wx_member_add_hour(member, hour))
    *n_values += finite;
}

/**
 * build_member:
 * @hourly: the "hourly" object.
 * @model: the model.
 * @suffixed: whether the body keys carry the "_<api name>" suffix.
 * @stamps: the used time stamps (ascending, multiples of 3600).
 * @index: the array index of each used stamp.
 * @n_used: number of used stamps.
 * @fetched_s: fetch time of the member.
 *
 * Builds the member of one model from the value arrays of the body.
 *
 * Preconditions:
 *  - @fetched_s is within [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * Postconditions:
 *  - the member's buckets follow the stamp semantics of the header: the
 *    instant variables of stamp T in bucket T, precipitation and probability
 *    in bucket T - 3600 (merged when that is the previous used stamp).
 *  - the member keeps at most WX_MEMBER_MAX_HOURS buckets: flush_hour() drops
 *    the later ones silently (gapped stamps make two buckets per stamp).
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the member, or NULL when the model has
 *   no finite value.
 */
static WxMember *
build_member(JsonObject *hourly, const ModelEntry *model, gboolean suffixed, const gint64 *stamps,
             const guint *index, guint n_used, gint64 fetched_s)
{
  JsonArray *arrays[VAR_COUNT];
  for (guint v = 0; v < VAR_COUNT; v++) {
    g_autofree char *key = suffixed ? g_strconcat(var_table[v].key, "_", model->api_id, NULL)
                                    : g_strdup(var_table[v].key);
    arrays[v] = wx_json_member_array(hourly, key);
  }
  g_autoptr(WxMember) member = wx_member_new(WX_OPEN_METEO_ID, model->member_id, fetched_s, NULL);
  g_return_val_if_fail(member != NULL, NULL); /* constant ids and a checked @fetched_s: cannot fail */

  guint n_values = 0;
  WxHour open;
  gboolean have_open = FALSE;
  for (guint k = 0; k < n_used; k++) {
    guint i = index[k];
    WxHour precip;
    wx_hour_init(&precip);
    precip.t_s = stamps[k] - 3600;
    precip.precip_mm = array_number(arrays[VAR_PRECIP], i, var_table[VAR_PRECIP].lo,
                                    var_table[VAR_PRECIP].hi);
    precip.precip_prob = array_number(arrays[VAR_PROB], i, var_table[VAR_PROB].lo,
                                      var_table[VAR_PROB].hi);
    if (have_open && open.t_s == precip.t_s) {
      open.precip_mm = precip.precip_mm;
      open.precip_prob = precip.precip_prob;
    } else {
      if (have_open)
        flush_hour(member, &open, &n_values);
      open = precip;
    }
    flush_hour(member, &open, &n_values);

    wx_hour_init(&open);
    open.t_s = stamps[k];
    have_open = TRUE;
    open.temp_c = array_number(arrays[VAR_TEMP], i, var_table[VAR_TEMP].lo, var_table[VAR_TEMP].hi);
    open.feels_c = array_number(arrays[VAR_FEELS], i, var_table[VAR_FEELS].lo,
                                var_table[VAR_FEELS].hi);
    open.humidity_pct = array_number(arrays[VAR_HUMIDITY], i, var_table[VAR_HUMIDITY].lo,
                                     var_table[VAR_HUMIDITY].hi);
    open.cloud_pct = array_number(arrays[VAR_CLOUD], i, var_table[VAR_CLOUD].lo,
                                  var_table[VAR_CLOUD].hi);
    open.wind_kmh = array_number(arrays[VAR_WIND], i, var_table[VAR_WIND].lo,
                                 var_table[VAR_WIND].hi);
    open.gust_kmh = array_number(arrays[VAR_GUST], i, var_table[VAR_GUST].lo,
                                 var_table[VAR_GUST].hi);
    open.wmo = array_wmo(arrays[VAR_WMO], i);
  }
  if (have_open)
    flush_hour(member, &open, &n_values);
  if (n_values == 0)
    return NULL;
  return g_steal_pointer(&member);
}

/* Documented in wx-openmeteo.h. */
WxSourceResult *
wx_open_meteo_parse_forecast(const guint8 *data, gsize len, const char *const *models,
                             guint n_models, gint64 fetched_s, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  g_return_val_if_fail(models != NULL && n_models >= 1 && n_models <= MAX_MODELS, NULL);
  const ModelEntry *entries[MAX_MODELS];
  for (guint i = 0; i < n_models; i++) {
    entries[i] = model_find(models[i]);
    g_return_val_if_fail(entries[i] != NULL, NULL);
    for (guint j = 0; j < i; j++)
      g_return_val_if_fail(entries[j] != entries[i], NULL);
  }
  if (fetched_s < WX_TIME_MIN_S || fetched_s >= WX_TIME_MAX_S) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid fetch time");
    return NULL;
  }

  g_autoptr(JsonParser) parser = parse_root(data, len, error);
  if (parser == NULL)
    return NULL;
  JsonObject *hourly = wx_json_member_object(json_node_get_object(json_parser_get_root(parser)),
                                             "hourly");
  JsonArray *times = wx_json_member_array(hourly, "time");
  if (times == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response has no hourly time array");
    return NULL;
  }
  gint64 stamps[WX_OPEN_METEO_MAX_TIME_STEPS];
  guint index[WX_OPEN_METEO_MAX_TIME_STEPS];
  guint n_used;
  if (!read_stamps(times, 3600, WX_OPEN_METEO_MAX_TIME_STEPS, stamps, index, &n_used)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response has too many time steps");
    return NULL;
  }

  g_autoptr(WxSourceResult) result = wx_source_result_new(WX_OPEN_METEO_ID, NULL);
  g_return_val_if_fail(result != NULL, NULL); /* constant id: cannot fail */
  for (guint m = 0; m < n_models; m++) {
    WxMember *member = build_member(hourly, entries[m], n_models > 1, stamps, index, n_used,
                                    fetched_s);
    if (member != NULL)
      g_ptr_array_add(result->members, member);
  }
  if (result->members->len == 0) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_NOT_FOUND, "no usable forecast data");
    return NULL;
  }
  return g_steal_pointer(&result);
}

/* ------------------------------------------------------------------------ */
/* Nowcast parser                                                           */
/* ------------------------------------------------------------------------ */

/* Documented in wx-openmeteo.h. */
WxMember *
wx_open_meteo_parse_nowcast(const guint8 *data, gsize len, gint64 fetched_s, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  if (fetched_s < WX_TIME_MIN_S || fetched_s >= WX_TIME_MAX_S) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid fetch time");
    return NULL;
  }
  g_autoptr(JsonParser) parser = parse_root(data, len, error);
  if (parser == NULL)
    return NULL;
  JsonObject *quarters = wx_json_member_object(json_node_get_object(json_parser_get_root(parser)),
                                               "minutely_15");
  JsonArray *times = wx_json_member_array(quarters, "time");
  JsonArray *amounts = wx_json_member_array(quarters, "precipitation");
  if (times == NULL || amounts == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response has no 15-minute data");
    return NULL;
  }
  if (json_array_get_length(times) > WX_MEMBER_MAX_QUARTERS) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response has too many time steps");
    return NULL;
  }
  g_autoptr(WxMember) member = wx_member_new(WX_OPEN_METEO_ID, "hrrr15", fetched_s, NULL);
  g_return_val_if_fail(member != NULL, NULL); /* constant ids and a checked @fetched_s: cannot fail */
  gint64 last = 0;
  gboolean have_last = FALSE;
  guint n_times = json_array_get_length(times);
  for (guint i = 0; i < n_times; i++) {
    gint64 t;
    if (!stamp_from_node(json_array_get_element(times, i), 900, &t))
      continue;
    if (have_last && t <= last)
      continue;
    last = t;
    have_last = TRUE;
    WxQuarter q = {.t_s = t - 900,
                   .precip_mm = array_number(amounts, i, 0.0, WX_PRECIP_MAX_MM_H)};
    if (isnan(q.precip_mm))
      continue;
    (void)wx_member_add_quarter(member, &q);
  }
  if (member->n_quarters == 0) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_NOT_FOUND, "no usable nowcast data");
    return NULL;
  }
  return g_steal_pointer(&member);
}

/* ------------------------------------------------------------------------ */
/* Geocode parser                                                           */
/* ------------------------------------------------------------------------ */

/**
 * hit_string:
 * @hit: a result object.
 * @name: member name.
 * @max_bytes: longest kept text, bytes.
 *
 * Reads a text member of a hit and sanitises it.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the cleaned text; "" when the member is missing
 *   or not a string.
 */
static char *
hit_string(JsonObject *hit, const char *name, gsize max_bytes)
{
  return wx_sanitize_text(wx_json_member_string(hit, name), max_bytes);
}

/**
 * hit_optional_string:
 * @hit: a result object.
 * @name: member name.
 *
 * Like hit_string() for the optional texts (admin1, country): a cleaned text
 * that wx_place_new() would refuse (whitespace only) is replaced by "" so the
 * hit is kept.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): "" or a text accepted by wx_text_is_usable_name().
 */
static char *
hit_optional_string(JsonObject *hit, const char *name)
{
  char *text = hit_string(hit, name, WX_PLACE_NAME_MAX);
  if (text[0] != '\0' && !wx_text_is_usable_name(text, WX_PLACE_NAME_MAX)) {
    g_free(text);
    return g_strdup("");
  }
  return text;
}

/**
 * country_code_or_empty:
 * @hit: a result object.
 *
 * Reads the country code of a hit.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the code when it is exactly two ASCII capitals,
 *   else "".
 */
static char *
country_code_or_empty(JsonObject *hit)
{
  const char *code = wx_json_member_string(hit, "country_code");
  gboolean ok = code != NULL && strlen(code) == 2 && g_ascii_isupper(code[0]) && g_ascii_isupper(code[1]);
  return g_strndup(ok ? code : "", 2);
}

/**
 * place_from_hit:
 * @hit: a result object.
 *
 * Builds a place from one geocoder hit.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified; no critical for any content.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned place.
 *
 * Returns: (transfer full) (nullable): the place, or NULL when the hit is
 *   unusable.
 */
static WxPlace *
place_from_hit(JsonObject *hit)
{
  double lat, lon;
  if (wx_json_member_string(hit, "name") == NULL || !wx_json_member_number(hit, "latitude", &lat) ||
      !wx_json_member_number(hit, "longitude", &lon))
    return NULL;
  g_autofree char *name = hit_string(hit, "name", WX_PLACE_NAME_MAX);
  g_autofree char *admin1 = hit_optional_string(hit, "admin1");
  g_autofree char *country = hit_optional_string(hit, "country");
  g_autofree char *code = country_code_or_empty(hit);
  const char *timezone = wx_json_member_string(hit, "timezone");
  WxPlace *place = wx_place_new(name, admin1, country, code, lat, lon, timezone, NULL);
  if (place == NULL && timezone != NULL && timezone[0] != '\0')
    place = wx_place_new(name, admin1, country, code, lat, lon, "", NULL);
  return place;
}

/* Documented in wx-openmeteo.h. */
GPtrArray *
wx_open_meteo_parse_geocode(const guint8 *data, gsize len, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  g_autoptr(JsonParser) parser = parse_root(data, len, error);
  if (parser == NULL)
    return NULL;
  JsonObject *root = json_node_get_object(json_parser_get_root(parser));
  JsonNode *results = json_object_get_member(root, "results");
  if (results != NULL && !JSON_NODE_HOLDS_NULL(results) && !JSON_NODE_HOLDS_ARRAY(results)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "unexpected search response shape");
    return NULL;
  }
  g_autoptr(GPtrArray) places = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
  JsonArray *hits = (results != NULL && JSON_NODE_HOLDS_ARRAY(results)) ? json_node_get_array(results)
                                                                         : NULL;
  guint n_hits = hits != NULL ? json_array_get_length(hits) : 0;
  for (guint i = 0; i < n_hits && places->len < WX_GEOCODER_MAX_HITS; i++) {
    JsonNode *node = json_array_get_element(hits, i);
    if (!JSON_NODE_HOLDS_OBJECT(node))
      continue;
    WxPlace *place = place_from_hit(json_node_get_object(node));
    if (place != NULL)
      g_ptr_array_add(places, place);
  }
  return g_steal_pointer(&places);
}

/* ------------------------------------------------------------------------ */
/* Fetch operation (request A + optional request B)                         */
/* ------------------------------------------------------------------------ */

/*
 * State of one fetch, owned by its GTask (main thread only). Every request
 * callback owns a task reference, so the task, this state and the provider
 * outlive all of them.
 */
typedef struct {
  GCancellable *cancel; /* cancels request A and B: user cancel, A failure, completion */
  GCancellable *user;   /* the caller's cancellable (ref) or NULL */
  gulong user_handler;  /* g_cancellable_connect() id on @user, 0 when not connected */
  GSource *grace;       /* the nowcast grace timer, NULL when not armed */
  gint64 start_us;      /* g_get_monotonic_time() when request A was sent */
  gboolean completed;   /* the task has been returned */
  gboolean want_b;      /* request B was sent */
  gboolean b_done;      /* request B finished (whatever its outcome) */
  WxSourceResult *a_result; /* request A's members once A succeeded */
  WxMember *b_member;       /* the nowcast member once B succeeded */
  WxHttp *http;             /* ref: the provider's HTTP engine */
  const char *models[MAX_MODELS];
  guint n_models;
} FetchOp;

/**
 * fetch_op_stop:
 * @op: (not nullable): the fetch state.
 *
 * Disconnects the user cancellation handler, destroys the grace timer and
 * cancels whatever request is still in flight.
 *
 * Preconditions:
 *  - main thread, and not from inside on_user_cancelled() (g_cancellable_disconnect()
 *    would wait for that handler). Its callers are the request callbacks, the grace
 *    timer and the task finalisation, all run by the main loop: WxHttp completes a
 *    cancelled operation from the main loop, never from inside g_cancellable_cancel()
 *    (see attempt_cleanup() in wx-http.c).
 * Postconditions:
 *  - no handler or timer references the task; both requests are cancelled
 *    (their callbacks, still to come, only release their resources).
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
fetch_op_stop(FetchOp *op)
{
  if (op->user_handler != 0) {
    g_cancellable_disconnect(op->user, op->user_handler);
    op->user_handler = 0;
  }
  if (op->grace != NULL) {
    g_source_destroy(op->grace);
    g_clear_pointer(&op->grace, g_source_unref);
  }
  g_cancellable_cancel(op->cancel);
}

/**
 * fetch_op_free:
 * @data: (not nullable): the FetchOp installed as task data.
 *
 * GDestroyNotify of the task data.
 *
 * Preconditions:
 *  - called once when the GTask is finalised (no callback references it).
 * Postconditions:
 *  - everything is released.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @data.
 */
static void
fetch_op_free(gpointer data)
{
  FetchOp *op = data;
  fetch_op_stop(op);
  g_clear_object(&op->cancel);
  g_clear_object(&op->user);
  g_clear_object(&op->http);
  g_clear_pointer(&op->a_result, wx_source_result_free);
  g_clear_pointer(&op->b_member, wx_member_unref);
  g_free(op);
}

/**
 * fetch_complete_ok:
 * @task: (not nullable): the fetch task; the caller holds a reference.
 *
 * Returns the task with request A's members plus the nowcast member, if any.
 *
 * Preconditions:
 *  - request A succeeded; the task has not been returned.
 * Postconditions:
 *  - the task is completed with the WxSourceResult.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller.
 */
static void
fetch_complete_ok(GTask *task)
{
  FetchOp *op = g_task_get_task_data(task);
  op->completed = TRUE;
  fetch_op_stop(op);
  WxSourceResult *result = g_steal_pointer(&op->a_result);
  if (op->b_member != NULL)
    g_ptr_array_add(result->members, g_steal_pointer(&op->b_member));
  g_task_return_pointer(task, result, (GDestroyNotify)wx_source_result_free);
}

/**
 * fetch_complete_error:
 * @task: (not nullable): the fetch task; the caller holds a reference.
 * @error: (transfer full): the failure.
 *
 * Returns the task with an error and cancels the other request.
 *
 * Preconditions:
 *  - the task has not been returned.
 * Postconditions:
 *  - the task is completed with @error.
 * Thread affinity: main thread only.
 * Ownership: takes @error; @task stays with the caller.
 */
static void
fetch_complete_error(GTask *task, GError *error)
{
  FetchOp *op = g_task_get_task_data(task);
  op->completed = TRUE;
  fetch_op_stop(op);
  g_task_return_error(task, error);
}

/**
 * on_grace_elapsed:
 * @user_data: (not nullable): the task.
 *
 * GSource callback: request B did not answer within WX_OPEN_METEO_NOWCAST_GRACE_MS
 * of the start of the fetch; the fetch returns A's members.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by the timer source.
 * Postconditions:
 *  - the task is completed without the nowcast (when it was not completed).
 * Thread affinity: main thread only.
 * Ownership: the callback takes and releases its own task reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_grace_elapsed(gpointer user_data)
{
  g_autoptr(GTask) task = g_object_ref(user_data);
  FetchOp *op = g_task_get_task_data(task);
  if (!op->completed)
    fetch_complete_ok(task);
  return G_SOURCE_REMOVE;
}

/**
 * on_forecast_done:
 * @source: the WxHttp.
 * @result: the finished request.
 * @user_data: (transfer full): the task.
 *
 * Request A finished: parse it. A failure fails the fetch; a success completes
 * it at once, or after request B / the grace timer when B is still pending.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by this callback.
 * Postconditions:
 *  - the task is completed unless request B is pending and grace is running.
 * Thread affinity: main thread only.
 * Ownership: releases the task reference.
 */
static void
on_forecast_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  FetchOp *op = g_task_get_task_data(task);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  /* The task cannot be completed yet: only this callback completes it on a failure of A, and the
   * grace timer and request B's callback act only after A succeeded. */
  g_assert(!op->completed);
  if (response != NULL) {
    gsize len;
    const guint8 *body = g_bytes_get_data(response->body, &len);
    op->a_result = wx_open_meteo_parse_forecast(body, len, op->models, op->n_models,
                                                g_get_real_time() / G_USEC_PER_SEC, &error);
  }
  if (op->a_result == NULL) {
    fetch_complete_error(task, g_steal_pointer(&error));
    return;
  }
  if (!op->want_b || op->b_done) {
    fetch_complete_ok(task);
    return;
  }
  /* B's window is measured from the start of the fetch, not from A's completion: a late A must
   * not be held past the window (the service deadline counts from the start too). */
  gint64 elapsed_us = g_get_monotonic_time() - op->start_us;
  gint64 window_us = (gint64)WX_OPEN_METEO_NOWCAST_GRACE_MS * 1000;
  if (elapsed_us >= window_us) {
    fetch_complete_ok(task);
    return;
  }
  guint remaining_ms = (guint)((window_us - elapsed_us + 999) / 1000);
  op->grace = g_timeout_source_new(remaining_ms);
  g_source_set_callback(op->grace, on_grace_elapsed, g_object_ref(task), g_object_unref);
  g_source_attach(op->grace, g_task_get_context(task));
}

/**
 * on_nowcast_done:
 * @source: the WxHttp.
 * @result: the finished request.
 * @user_data: (transfer full): the task.
 *
 * Request B finished: keep its member when it parsed (every failure is
 * tolerated); complete the fetch when request A has already succeeded.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by this callback.
 * Postconditions:
 *  - the task is completed when A succeeded earlier.
 * Thread affinity: main thread only.
 * Ownership: releases the task reference.
 */
static void
on_nowcast_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  FetchOp *op = g_task_get_task_data(task);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  if (op->completed)
    return;
  op->b_done = TRUE;
  if (response != NULL) {
    gsize len;
    const guint8 *body = g_bytes_get_data(response->body, &len);
    op->b_member = wx_open_meteo_parse_nowcast(body, len, g_get_real_time() / G_USEC_PER_SEC, NULL);
  }
  if (op->a_result != NULL)
    fetch_complete_ok(task);
}

/**
 * on_user_cancelled:
 * @user: (unused): the caller's cancellable.
 * @data: (not nullable): the fetch's internal cancellable.
 *
 * GCancellable "cancelled" handler (may run in any thread): forwards the
 * caller's cancellation to the internal cancellable.
 *
 * Preconditions:
 *  - @data is the reference owned by the handler connection.
 * Postconditions:
 *  - the internal cancellable is cancelled.
 * Thread affinity: any thread (g_cancellable_cancel() is thread-safe).
 * Ownership: nothing is retained.
 */
static void
on_user_cancelled(GCancellable *user, gpointer data)
{
  (void)user;
  g_cancellable_cancel(G_CANCELLABLE(data));
}

/* ------------------------------------------------------------------------ */
/* WxOpenMeteo                                                              */
/* ------------------------------------------------------------------------ */

struct _WxOpenMeteo {
  GObject parent_instance;
  WxHttp *http;
};

static void wx_open_meteo_provider_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxOpenMeteo, wx_open_meteo, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, wx_open_meteo_provider_init))

/**
 * wx_open_meteo_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: nothing to do (the HTTP engine is set by the
 * constructors).
 *
 * Preconditions:
 *  - @self is a zero-initialised WxOpenMeteo being constructed by GObject.
 * Postconditions:
 *  - none.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
wx_open_meteo_init(WxOpenMeteo *self)
{
  (void)self;
}

/**
 * wx_open_meteo_finalize:
 * @object: (not nullable): the WxOpenMeteo being finalized.
 *
 * GObject finalize: releases the HTTP engine.
 *
 * Preconditions:
 *  - @object's last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns its WxHttp.
 */
static void
wx_open_meteo_finalize(GObject *object)
{
  g_clear_object(&WX_OPEN_METEO(object)->http);
  G_OBJECT_CLASS(wx_open_meteo_parent_class)->finalize(object);
}

/**
 * wx_open_meteo_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs finalize.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @klass is owned by the type system and not retained.
 */
static void
wx_open_meteo_class_init(WxOpenMeteoClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_open_meteo_finalize;
}

/**
 * om_get_id:
 * @provider: (not nullable): the WxOpenMeteo.
 *
 * WxProviderInterface.get_id.
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo (reached only through its vtable).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): WX_OPEN_METEO_ID.
 */
static const char *
om_get_id(WxProvider *provider)
{
  (void)provider;
  return WX_OPEN_METEO_ID;
}

/**
 * om_get_name:
 * @provider: (not nullable): the WxOpenMeteo.
 *
 * WxProviderInterface.get_name.
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): "Open-Meteo".
 */
static const char *
om_get_name(WxProvider *provider)
{
  (void)provider;
  return OPEN_METEO_NAME;
}

/**
 * om_get_attribution:
 * @provider: (not nullable): the WxOpenMeteo.
 *
 * WxProviderInterface.get_attribution (the CC BY 4.0 credit line).
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): "Weather data by Open-Meteo.com".
 */
static const char *
om_get_attribution(WxProvider *provider)
{
  (void)provider;
  return OPEN_METEO_ATTRIBUTION;
}

/**
 * om_get_attribution_url:
 * @provider: (not nullable): the WxOpenMeteo.
 *
 * WxProviderInterface.get_attribution_url.
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): "https://open-meteo.com/".
 */
static const char *
om_get_attribution_url(WxProvider *provider)
{
  (void)provider;
  return OPEN_METEO_ATTRIBUTION_URL;
}

/**
 * om_covers:
 * @provider: (not nullable): the WxOpenMeteo.
 * @place: (not nullable): the place to test.
 *
 * WxProviderInterface.covers: Open-Meteo answers for every valid coordinate.
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo; @place is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: wx_geo_valid() of the place's coordinates.
 */
static gboolean
om_covers(WxProvider *provider, const WxPlace *place)
{
  (void)provider;
  return wx_geo_valid(place->lat, place->lon);
}

/**
 * om_fetch_async:
 * @provider: (not nullable): the WxOpenMeteo.
 * @place: (not nullable): the place.
 * @cancellable: (nullable): cancels the operation.
 * @callback: called once with the result.
 * @user_data: passed to @callback.
 *
 * WxProviderInterface.fetch_async: validates the place (WX_ERROR_INVALID_ARG,
 * no network), then sends request A and, in the CONUS branch, request B.
 *
 * Preconditions:
 *  - @provider is a WxOpenMeteo; @place is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - @callback is called exactly once, never before this function returns.
 * Thread affinity: main thread only.
 * Ownership: the task takes references on @provider and @cancellable; the
 *   place is read, not retained.
 */
static void
om_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
               GAsyncReadyCallback callback, gpointer user_data)
{
  WxOpenMeteo *self = WX_OPEN_METEO(provider);
  g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_fetch);
  g_autoptr(WxPlace) copy = wx_place_copy(place);
  if (copy == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid place");
    return;
  }
  if (g_task_return_error_if_cancelled(task))
    return;

  FetchOp *op = g_new0(FetchOp, 1);
  g_task_set_task_data(task, op, fetch_op_free);
  op->http = g_object_ref(self->http);
  op->cancel = g_cancellable_new();
  op->n_models = models_for_place(copy->lat, copy->lon, op->models, &op->want_b);
  if (cancellable != NULL) {
    op->user = g_object_ref(cancellable);
    op->user_handler = g_cancellable_connect(cancellable, G_CALLBACK(on_user_cancelled),
                                             g_object_ref(op->cancel), g_object_unref);
  }

  op->start_us = g_get_monotonic_time();
  g_autofree char *path_a = forecast_path(copy->lat, copy->lon, op->models, op->n_models);
  wx_http_get_async(op->http, path_a, OPEN_METEO_ACCEPT, NULL, op->cancel, on_forecast_done,
                    g_object_ref(task));
  if (op->want_b) {
    g_autofree char *path_b = nowcast_path(copy->lat, copy->lon);
    wx_http_get_async(op->http, path_b, OPEN_METEO_ACCEPT, NULL, op->cancel, on_nowcast_done,
                      g_object_ref(task));
  }
}

/**
 * om_fetch_finish:
 * @provider: (not nullable): the WxOpenMeteo the fetch was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxProviderInterface.fetch_finish.
 *
 * Preconditions:
 *  - @result is a task created by om_fetch_async() for @provider and not yet
 *    finished (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed; on failure NULL is returned and *@error is set.
 * Thread affinity: main thread only.
 * Ownership: the result is returned to the caller.
 *
 * Returns: (transfer full) (nullable): the source result, or NULL with @error.
 */
static WxSourceResult *
om_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, provider), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_fetch, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_open_meteo_provider_init:
 * @iface: (not nullable): the WxProvider interface structure of WxOpenMeteo.
 *
 * Interface initialiser named in G_IMPLEMENT_INTERFACE(): fills the vtable.
 *
 * Preconditions:
 *  - called by GObject when the interface is set up for the type.
 * Postconditions:
 *  - every virtual function is set.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @iface is owned by GObject and not retained.
 */
static void
wx_open_meteo_provider_init(WxProviderInterface *iface)
{
  iface->get_id = om_get_id;
  iface->get_name = om_get_name;
  iface->get_attribution = om_get_attribution;
  iface->get_attribution_url = om_get_attribution_url;
  iface->covers = om_covers;
  iface->fetch_async = om_fetch_async;
  iface->fetch_finish = om_fetch_finish;
}

/* Documented in wx-openmeteo.h. */
WxOpenMeteo *
wx_open_meteo_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms,
                         GError **error)
{
  g_return_val_if_fail(base_url != NULL, NULL);
  g_return_val_if_fail(timeout_ms >= 1 && timeout_ms <= 600000, NULL);
  g_return_val_if_fail(backoff_base_ms <= 600000, NULL);
  WxHttp *http = wx_http_new_custom(base_url, OPEN_METEO_USER_AGENT, timeout_ms, backoff_base_ms, 0,
                                    error);
  if (http == NULL)
    return NULL;
  WxOpenMeteo *self = g_object_new(WX_TYPE_OPEN_METEO, NULL);
  self->http = http;
  return self;
}

/* Documented in wx-openmeteo.h. */
WxOpenMeteo *
wx_open_meteo_new(void)
{
  return wx_open_meteo_new_custom(WX_OPEN_METEO_BASE_URL, WX_HTTP_TIMEOUT_MS,
                                  WX_HTTP_BACKOFF_BASE_MS, NULL);
}

/* ------------------------------------------------------------------------ */
/* WxOpenMeteoGeocoder                                                      */
/* ------------------------------------------------------------------------ */

struct _WxOpenMeteoGeocoder {
  GObject parent_instance;
  WxHttp *http;
};

static void wx_open_meteo_geocoder_geocoder_init(WxGeocoderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxOpenMeteoGeocoder, wx_open_meteo_geocoder, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_GEOCODER,
                                              wx_open_meteo_geocoder_geocoder_init))

/**
 * wx_open_meteo_geocoder_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: nothing to do (the HTTP engine is set by the
 * constructors).
 *
 * Preconditions:
 *  - @self is a zero-initialised WxOpenMeteoGeocoder being constructed by
 *    GObject.
 * Postconditions:
 *  - none.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
wx_open_meteo_geocoder_init(WxOpenMeteoGeocoder *self)
{
  (void)self;
}

/**
 * wx_open_meteo_geocoder_finalize:
 * @object: (not nullable): the WxOpenMeteoGeocoder being finalized.
 *
 * GObject finalize: releases the HTTP engine.
 *
 * Preconditions:
 *  - @object's last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns its WxHttp.
 */
static void
wx_open_meteo_geocoder_finalize(GObject *object)
{
  g_clear_object(&WX_OPEN_METEO_GEOCODER(object)->http);
  G_OBJECT_CLASS(wx_open_meteo_geocoder_parent_class)->finalize(object);
}

/**
 * wx_open_meteo_geocoder_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs finalize.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @klass is owned by the type system and not retained.
 */
static void
wx_open_meteo_geocoder_class_init(WxOpenMeteoGeocoderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_open_meteo_geocoder_finalize;
}

/**
 * on_search_done:
 * @source: the WxHttp.
 * @result: the finished request.
 * @user_data: (transfer full): the task.
 *
 * The search request finished: parse the body and return the task.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by this callback.
 * Postconditions:
 *  - the task is completed with the places or the error.
 * Thread affinity: main thread only.
 * Ownership: releases the task reference.
 */
static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  GPtrArray *places = NULL;
  if (response != NULL) {
    gsize len;
    const guint8 *body = g_bytes_get_data(response->body, &len);
    places = wx_open_meteo_parse_geocode(body, len, &error);
  }
  if (places == NULL)
    g_task_return_error(task, g_steal_pointer(&error));
  else
    g_task_return_pointer(task, places, (GDestroyNotify)g_ptr_array_unref);
}

/**
 * geocoder_search_async:
 * @geocoder: (not nullable): the WxOpenMeteoGeocoder.
 * @text: (not nullable): the text typed by the user.
 * @cancellable: (nullable): cancels the operation.
 * @callback: called once with the result.
 * @user_data: passed to @callback.
 *
 * WxGeocoderInterface.search_async. The four steps of "Place search" in
 * wx-openmeteo.h, in this order, every failure without network traffic:
 *  1. @text is trimmed of the bytes space, \t, \n, \f and \r (g_strstrip();
 *     NOT \v) at both ends;
 *  2. fewer than WX_OPEN_METEO_SEARCH_MIN_BYTES bytes left: an EMPTY result
 *     (0 hits, no error);
 *  3. the trimmed text must be accepted by wx_text_is_usable_name(text,
 *     WX_OPEN_METEO_SEARCH_MAX_BYTES) (the authoritative rule: wx-text.h),
 *     else WX_ERROR_INVALID_ARG ("unacceptable search text"). It is refused
 *     iff (a) it is longer than WX_OPEN_METEO_SEARCH_MAX_BYTES bytes, (b) it
 *     is not valid UTF-8, (c) it contains a forbidden character: exactly
 *     U+0001..U+001F, U+007F, U+0080..U+009F (control characters, \v and the
 *     other ASCII controls included), U+2028, U+2029 (line / paragraph
 *     separator), U+061C, U+200E, U+200F, U+202A..U+202E, U+2066..U+2069
 *     (bidirectional formatting), or (d) it has no non-whitespace character,
 *     i.e. it is made only of Unicode space separators (U+0020, U+00A0,
 *     U+1680, U+2000..U+200A, U+202F, U+205F, U+3000). Everything else is
 *     accepted, including text made only of invisible format characters
 *     (category Cf, such as U+200B or U+FEFF): that is NOT detected and is
 *     sent;
 *  4. otherwise the text is percent-encoded into the request.
 *
 * Preconditions:
 *  - @geocoder is a WxOpenMeteoGeocoder; @text is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - @callback is called exactly once, never before this function returns.
 * Thread affinity: main thread only.
 * Ownership: @text is copied; the task takes references on @geocoder and
 *   @cancellable.
 */
static void
geocoder_search_async(WxGeocoder *geocoder, const char *text, GCancellable *cancellable,
                      GAsyncReadyCallback callback, gpointer user_data)
{
  WxOpenMeteoGeocoder *self = WX_OPEN_METEO_GEOCODER(geocoder);
  g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_search);
  if (g_task_return_error_if_cancelled(task))
    return;
  g_autofree char *trimmed = g_strstrip(g_strdup(text));
  if (strlen(trimmed) < WX_OPEN_METEO_SEARCH_MIN_BYTES) {
    g_task_return_pointer(task, g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free),
                          (GDestroyNotify)g_ptr_array_unref);
    return;
  }
  if (!wx_text_is_usable_name(trimmed, WX_OPEN_METEO_SEARCH_MAX_BYTES)) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_INVALID_ARG, "unacceptable search text");
    return;
  }
  g_autofree char *escaped = g_uri_escape_string(trimmed, NULL, FALSE);
  g_autofree char *path = g_strdup_printf("/v1/search?name=%s&count=%d&language=en&format=json",
                                          escaped, SEARCH_COUNT);
  wx_http_get_async(self->http, path, OPEN_METEO_ACCEPT, NULL, cancellable, on_search_done,
                    g_object_ref(task));
}

/**
 * geocoder_search_finish:
 * @geocoder: (not nullable): the WxOpenMeteoGeocoder the search was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxGeocoderInterface.search_finish.
 *
 * Preconditions:
 *  - @result is a task created by geocoder_search_async() for @geocoder and
 *    not yet finished (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed; on failure NULL is returned and *@error is set.
 * Thread affinity: main thread only.
 * Ownership: the array is returned to the caller.
 *
 * Returns: (transfer full) (nullable): the places, or NULL with @error.
 */
static GPtrArray *
geocoder_search_finish(WxGeocoder *geocoder, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, geocoder), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_search, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_open_meteo_geocoder_geocoder_init:
 * @iface: (not nullable): the WxGeocoder interface structure of
 *   WxOpenMeteoGeocoder.
 *
 * Interface initialiser named in G_IMPLEMENT_INTERFACE(): fills the vtable.
 *
 * Preconditions:
 *  - called by GObject when the interface is set up for the type.
 * Postconditions:
 *  - every virtual function is set.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @iface is owned by GObject and not retained.
 */
static void
wx_open_meteo_geocoder_geocoder_init(WxGeocoderInterface *iface)
{
  iface->search_async = geocoder_search_async;
  iface->search_finish = geocoder_search_finish;
}

/* Documented in wx-openmeteo.h. */
WxOpenMeteoGeocoder *
wx_open_meteo_geocoder_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms,
                                  GError **error)
{
  g_return_val_if_fail(base_url != NULL, NULL);
  g_return_val_if_fail(timeout_ms >= 1 && timeout_ms <= 600000, NULL);
  g_return_val_if_fail(backoff_base_ms <= 600000, NULL);
  WxHttp *http = wx_http_new_custom(base_url, OPEN_METEO_USER_AGENT, timeout_ms, backoff_base_ms, 0,
                                    error);
  if (http == NULL)
    return NULL;
  WxOpenMeteoGeocoder *self = g_object_new(WX_TYPE_OPEN_METEO_GEOCODER, NULL);
  self->http = http;
  return self;
}

/* Documented in wx-openmeteo.h. */
WxOpenMeteoGeocoder *
wx_open_meteo_geocoder_new(void)
{
  return wx_open_meteo_geocoder_new_custom(WX_OPEN_METEO_GEOCODING_BASE_URL, WX_HTTP_TIMEOUT_MS,
                                           WX_HTTP_BACKOFF_BASE_MS, NULL);
}
