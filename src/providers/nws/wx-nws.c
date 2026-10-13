/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-nws.c - the National Weather Service provider. See wx-nws.h for the contract. */
#include "wx-nws.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "wx-geo.h"
#include "wx-http.h"
#include "wx-json.h"
#include "wx-time.h"

#ifdef WX_NWS_TESTING
#include "wx-nws-testing.h"
#endif

#define NWS_NAME "National Weather Service"
#define NWS_ATTRIBUTION "Source: NOAA/National Weather Service"
#define NWS_ATTRIBUTION_URL "https://www.weather.gov/"
#define NWS_ACCEPT "application/geo+json"
/* Largest valid gridX / gridY. */
#define NWS_GRID_COORD_MAX 999
#define NWS_HOUR_S 3600

/* Source tag of the fetch tasks. */
static char tag_fetch;

/* ------------------------------------------------------------------------ */
/* Clock                                                                    */
/* ------------------------------------------------------------------------ */

#ifdef WX_NWS_TESTING
static WxNwsClock clock_hook;

/* Documented in wx-nws-testing.h. */
void
wx_nws_test_set_clock(WxNwsClock clock)
{
  clock_hook = clock;
}
#endif

/**
 * now_us:
 *
 * The monotonic clock of the caches and the rate limit.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: monotonic microseconds (g_get_monotonic_time(); a test hook in the test flavour).
 */
static gint64
now_us(void)
{
#ifdef WX_NWS_TESTING
  if (clock_hook != NULL)
    return clock_hook();
#endif
  return g_get_monotonic_time();
}

/**
 * deadline_after:
 * @now: a time, microseconds.
 * @seconds: non-negative span.
 *
 * Adds a span to a time without overflow.
 *
 * Preconditions:
 *  - @seconds is in [0, G_MAXINT32].
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: @now + @seconds seconds, saturated at G_MAXINT64.
 */
static gint64
deadline_after(gint64 now, gint seconds)
{
  gint64 span = (gint64)seconds * G_USEC_PER_SEC;
  return now > G_MAXINT64 - span ? G_MAXINT64 : now + span;
}

/* ------------------------------------------------------------------------ */
/* /points parser                                                           */
/* ------------------------------------------------------------------------ */

/**
 * grid_coord:
 * @props: (nullable): the properties object.
 * @name: member to read.
 * @out: (out): receives the coordinate.
 *
 * Reads an integral number in 0..NWS_GRID_COORD_MAX.
 *
 * Preconditions:
 *  - @name and @out are non-NULL.
 * Postconditions:
 *  - *@out is written only on TRUE.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: TRUE iff the member is a finite integral number in range.
 */
static gboolean
grid_coord(JsonObject *props, const char *name, guint *out)
{
  double v;
  if (!wx_json_member_number(props, name, &v) || v < 0.0 || v > NWS_GRID_COORD_MAX ||
      v != floor(v))
    return FALSE;
  *out = (guint)v;
  return TRUE;
}

/* Documented in wx-nws.h. */
gboolean
wx_nws_parse_points(const guint8 *data, gsize len, WxNwsGrid *grid, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, FALSE);
  g_return_val_if_fail(grid != NULL, FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  g_autoptr(JsonParser) parser =
    wx_json_parse(data, len, WX_HTTP_MAX_BODY_BYTES, WX_JSON_ROOT_OBJECT, error);
  if (parser == NULL)
    return FALSE;
  JsonObject *props =
    wx_json_member_object(json_node_get_object(json_parser_get_root(parser)), "properties");
  const char *id = wx_json_member_string(props, "gridId");
  WxNwsGrid found = {{0}, 0, 0};
  gboolean id_ok = id != NULL && strlen(id) == 3;
  for (guint i = 0; id_ok && i < 3; i++)
    id_ok = id[i] >= 'A' && id[i] <= 'Z';
  if (!id_ok || !grid_coord(props, "gridX", &found.x) || !grid_coord(props, "gridY", &found.y)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "no valid forecast grid in response");
    return FALSE;
  }
  memcpy(found.grid_id, id, 3);
  *grid = found;
  return TRUE;
}

/* ------------------------------------------------------------------------ */
/* /gridpoints parser                                                       */
/* ------------------------------------------------------------------------ */

/* One layer of the grid that becomes a field of WxHour. */
typedef struct {
  const char *name;   /* member of "properties" */
  const char *uom;    /* the only accepted unit */
  double lo, hi;      /* valid range of the stored (per hour) value */
  gsize offset;       /* offsetof(WxHour, <double field>) */
  gboolean total;     /* the value is a total over the interval: divide it among the hours */
} Layer;

static const Layer layers[] = {
  {"temperature", "wmoUnit:degC", WX_TEMP_MIN_C, WX_TEMP_MAX_C, offsetof(WxHour, temp_c), FALSE},
  {"apparentTemperature", "wmoUnit:degC", WX_TEMP_MIN_C, WX_TEMP_MAX_C,
   offsetof(WxHour, feels_c), FALSE},
  {"relativeHumidity", "wmoUnit:percent", WX_PERCENT_MIN, WX_PERCENT_MAX,
   offsetof(WxHour, humidity_pct), FALSE},
  {"skyCover", "wmoUnit:percent", WX_PERCENT_MIN, WX_PERCENT_MAX, offsetof(WxHour, cloud_pct),
   FALSE},
  {"windSpeed", "wmoUnit:km_h-1", 0.0, WX_WIND_MAX_KMH, offsetof(WxHour, wind_kmh), FALSE},
  {"windGust", "wmoUnit:km_h-1", 0.0, WX_WIND_MAX_KMH, offsetof(WxHour, gust_kmh), FALSE},
  {"probabilityOfPrecipitation", "wmoUnit:percent", WX_PERCENT_MIN, WX_PERCENT_MAX,
   offsetof(WxHour, precip_prob), FALSE},
  {"quantitativePrecipitation", "wmoUnit:mm", 0.0, WX_PRECIP_MAX_MM_H,
   offsetof(WxHour, precip_mm), TRUE},
};

/**
 * element_value:
 * @layer: (not nullable): the layer.
 * @element: (nullable): one entry of the layer's "values".
 * @start_s: (out): receives the interval start.
 * @hours: (out): receives the interval length in hours (>= 1).
 * @value: (out): receives the value stored in every hour.
 *
 * Validates one element as described in wx-nws.h and computes the per-hour value.
 *
 * Preconditions:
 *  - the outputs are non-NULL.
 * Postconditions:
 *  - the outputs are written only on TRUE; *@value is in [layer->lo, layer->hi], never -0.0.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the element is usable.
 */
static gboolean
element_value(const Layer *layer, JsonNode *element, gint64 *start_s, guint *hours, double *value)
{
  if (element == NULL || !JSON_NODE_HOLDS_OBJECT(element))
    return FALSE;
  JsonObject *obj = json_node_get_object(element);
  gint64 start, duration;
  double v;
  if (!wx_time_parse_interval(wx_json_member_string(obj, "validTime"), &start, &duration) ||
      start % NWS_HOUR_S != 0 || duration % NWS_HOUR_S != 0 ||
      !wx_json_node_number(json_object_get_member(obj, "value"), &v))
    return FALSE;
  *hours = (guint)(duration / NWS_HOUR_S);
  if (layer->total)
    v /= *hours;
  if (!wx_value_in_range(v, layer->lo, layer->hi))
    return FALSE;
  *start_s = start;
  *value = v == 0.0 ? 0.0 : v;
  return TRUE;
}

/**
 * layer_collect:
 * @layer: (not nullable): the layer.
 * @values: (not nullable): the layer's "values" array.
 * @hours: (not nullable): table gint64* -> WxHour*, receives the layer's field.
 *
 * Expands the elements of one layer into the hour table (see wx-nws.h for the rules and bounds).
 *
 * Preconditions:
 *  - @hours keys are g_malloc'ed gint64 and the values g_malloc'ed initialised WxHour; the table
 *    owns both.
 * Postconditions:
 *  - at most WX_MEMBER_MAX_HOURS distinct hours were given a value of this layer; hours that were
 *    new to the table were added.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
layer_collect(const Layer *layer, JsonArray *values, GHashTable *hours)
{
  g_autoptr(GHashTable) seen = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, NULL);
  guint length = json_array_get_length(values);
  guint n = MIN(length, (guint)WX_MEMBER_MAX_HOURS);
  for (guint i = 0; i < n; i++) {
    gint64 start;
    guint count;
    double v;
    if (!element_value(layer, json_array_get_element(values, i), &start, &count, &v))
      continue;
    for (guint h = 0; h < count && g_hash_table_size(seen) < WX_MEMBER_MAX_HOURS; h++) {
      gint64 t = start + (gint64)h * NWS_HOUR_S;
      if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || g_hash_table_contains(seen, &t))
        continue;
      g_hash_table_add(seen, g_memdup2(&t, sizeof t));
      WxHour *hour = g_hash_table_lookup(hours, &t);
      if (hour == NULL) {
        hour = g_new(WxHour, 1);
        wx_hour_init(hour);
        hour->t_s = t;
        g_hash_table_insert(hours, g_memdup2(&t, sizeof t), hour);
      }
      *(double *)((char *)hour + layer->offset) = v;
    }
  }
}

/**
 * compare_time:
 * @a: (not nullable): pointer to a gint64.
 * @b: (not nullable): pointer to a gint64.
 *
 * qsort comparison of two times, overflow free.
 *
 * Preconditions:
 *  - both point to a gint64.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: negative, zero or positive as *@a is before, equal to or after *@b.
 */
static int
compare_time(const void *a, const void *b)
{
  gint64 x = *(const gint64 *)a, y = *(const gint64 *)b;
  return (x > y) - (x < y);
}

/* Documented in wx-nws.h. */
WxMember *
wx_nws_parse_gridpoints(const guint8 *data, gsize len, gint64 fetched_s, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);
  g_autoptr(JsonParser) parser =
    wx_json_parse(data, len, WX_HTTP_MAX_BODY_BYTES, WX_JSON_ROOT_OBJECT, error);
  if (parser == NULL)
    return NULL;
  JsonObject *props =
    wx_json_member_object(json_node_get_object(json_parser_get_root(parser)), "properties");
  if (props == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response has no properties");
    return NULL;
  }
  g_autoptr(WxMember) member = wx_member_new(WX_NWS_ID, WX_NWS_ID, fetched_s, error);
  if (member == NULL)
    return NULL;

  g_autoptr(GHashTable) hours = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, g_free);
  for (guint i = 0; i < G_N_ELEMENTS(layers); i++) {
    JsonObject *layer = wx_json_member_object(props, layers[i].name);
    JsonArray *values = wx_json_member_array(layer, "values");
    const char *uom = wx_json_member_string(layer, "uom");
    if (values != NULL && uom != NULL && strcmp(uom, layers[i].uom) == 0)
      layer_collect(&layers[i], values, hours);
  }

  g_autofree gint64 *keys = g_new(gint64, MAX(1, g_hash_table_size(hours)));
  guint n_keys = 0;
  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init(&iter, hours);
  while (g_hash_table_iter_next(&iter, &key, NULL))
    keys[n_keys++] = *(gint64 *)key;
  qsort(keys, n_keys, sizeof *keys, compare_time);
  for (guint i = 0; i < n_keys; i++) {
    const WxHour *hour = g_hash_table_lookup(hours, &keys[i]);
    if (!wx_member_add_hour(member, hour))
      break;
  }
  guint n_added;
  wx_member_get_hours(member, &n_added);
  if (n_added == 0) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_NOT_FOUND, "response has no usable forecast");
    return NULL;
  }
  return g_steal_pointer(&member);
}

/* ------------------------------------------------------------------------ */
/* WxNws                                                                    */
/* ------------------------------------------------------------------------ */

/* One remembered point: a grid cell or an "unsupported" mark. */
typedef struct {
  char *key;          /* "<lat4>,<lon4>" */
  WxNwsGrid grid;
  gint64 expires_us;  /* monotonic; G_MAXINT64 never */
} CacheEntry;

struct _WxNws {
  GObject parent_instance;
  WxHttp *http;
  GPtrArray *grids;        /* CacheEntry*, oldest first, at most WX_NWS_CACHE_MAX */
  GPtrArray *unsupported;  /* CacheEntry*, oldest first, at most WX_NWS_CACHE_MAX */
  gint64 blocked_until_us; /* no request before this monotonic time */
};

static void wx_nws_provider_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxNws, wx_nws, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, wx_nws_provider_init))

/**
 * cache_entry_free:
 * @data: (not nullable): a CacheEntry.
 *
 * GDestroyNotify of the cache arrays.
 *
 * Preconditions:
 *  - @data is an entry owned by the caller (a GPtrArray never passes NULL).
 * Postconditions:
 *  - the entry is freed.
 * Thread affinity: main thread only.
 * Ownership: consumes @data.
 */
static void
cache_entry_free(gpointer data)
{
  CacheEntry *entry = data;
  g_free(entry->key);
  g_free(entry);
}

/**
 * cache_lookup:
 * @cache: (not nullable): a cache array.
 * @key: (not nullable): the point key.
 *
 * Finds a live entry; an expired entry that matches is removed.
 *
 * Preconditions:
 *  - none beyond non-NULL arguments.
 * Postconditions:
 *  - the cache only lost an expired entry of @key.
 * Thread affinity: main thread only.
 * Ownership: the result is owned by @cache.
 *
 * Returns: (transfer none) (nullable): the entry, or NULL.
 */
static const CacheEntry *
cache_lookup(GPtrArray *cache, const char *key)
{
  for (guint i = 0; i < cache->len; i++) {
    const CacheEntry *entry = g_ptr_array_index(cache, i);
    if (strcmp(entry->key, key) != 0)
      continue;
    if (now_us() < entry->expires_us)
      return entry;
    g_ptr_array_remove_index(cache, i);
    return NULL;
  }
  return NULL;
}

/**
 * cache_store:
 * @cache: (not nullable): a cache array.
 * @key: (not nullable): the point key.
 * @grid: (nullable): the cell, or NULL for an unsupported mark.
 * @expires_us: monotonic expiry time.
 *
 * Stores or replaces the entry of @key as the newest one; when the cache is full the oldest
 * entry is evicted.
 *
 * Preconditions:
 *  - none beyond non-NULL @cache and @key.
 * Postconditions:
 *  - the cache has at most WX_NWS_CACHE_MAX entries and @key is its last.
 * Thread affinity: main thread only.
 * Ownership: @key and @grid are copied.
 */
static void
cache_store(GPtrArray *cache, const char *key, const WxNwsGrid *grid, gint64 expires_us)
{
  for (guint i = 0; i < cache->len; i++) {
    if (strcmp(((const CacheEntry *)g_ptr_array_index(cache, i))->key, key) == 0) {
      g_ptr_array_remove_index(cache, i);
      break;
    }
  }
  if (cache->len >= WX_NWS_CACHE_MAX)
    g_ptr_array_remove_index(cache, 0);
  CacheEntry *entry = g_new0(CacheEntry, 1);
  entry->key = g_strdup(key);
  if (grid != NULL)
    entry->grid = *grid;
  entry->expires_us = expires_us;
  g_ptr_array_add(cache, entry);
}

/**
 * wx_nws_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: empty caches, no block. The WxHttp is set by the constructors.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxNws being constructed.
 * Postconditions:
 *  - both caches exist and are empty; no rate-limit block.
 * Thread affinity: main thread only.
 * Ownership: @self owns the arrays.
 */
static void
wx_nws_init(WxNws *self)
{
  self->grids = g_ptr_array_new_with_free_func(cache_entry_free);
  self->unsupported = g_ptr_array_new_with_free_func(cache_entry_free);
  self->blocked_until_us = G_MININT64;
}

/**
 * wx_nws_finalize:
 * @object: (not nullable): the WxNws being finalized.
 *
 * GObject finalize: releases the HTTP engine and the caches (no operation can be running: each
 * one holds a reference).
 *
 * Preconditions:
 *  - the last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns everything it releases.
 */
static void
wx_nws_finalize(GObject *object)
{
  WxNws *self = WX_NWS(object);
  g_clear_object(&self->http);
  g_clear_pointer(&self->grids, g_ptr_array_unref);
  g_clear_pointer(&self->unsupported, g_ptr_array_unref);
  G_OBJECT_CLASS(wx_nws_parent_class)->finalize(object);
}

/**
 * wx_nws_class_init:
 * @klass: (not nullable): the class structure.
 *
 * GObject class initialiser: installs finalize.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden.
 * Thread affinity: any thread (under the type lock).
 * Ownership: @klass belongs to the type system.
 */
static void
wx_nws_class_init(WxNwsClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_nws_finalize;
}

/* Documented in wx-nws.h. */
WxNws *
wx_nws_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms, GError **error)
{
  g_return_val_if_fail(base_url != NULL, NULL);
  g_autoptr(WxHttp) http =
    wx_http_new_custom(base_url, WX_NWS_USER_AGENT, timeout_ms, backoff_base_ms, 0, error);
  if (http == NULL)
    return NULL;
  WxNws *self = g_object_new(WX_TYPE_NWS, NULL);
  self->http = g_steal_pointer(&http);
  return self;
}

/* Documented in wx-nws.h. */
WxNws *
wx_nws_new(GError **error)
{
  return wx_nws_new_custom(WX_NWS_BASE_URL, WX_HTTP_TIMEOUT_MS, WX_HTTP_BACKOFF_BASE_MS, error);
}

/* ------------------------------------------------------------------------ */
/* WxProvider implementation                                                */
/* ------------------------------------------------------------------------ */

/**
 * nws_get_id:
 * @provider: (not nullable): the WxNws.
 *
 * WxProviderInterface.get_id.
 *
 * Preconditions:
 *  - reached only through the vtable.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): WX_NWS_ID.
 */
static const char *
nws_get_id(WxProvider *provider)
{
  (void)provider;
  return WX_NWS_ID;
}

/**
 * nws_get_name:
 * @provider: (not nullable): the WxNws.
 *
 * WxProviderInterface.get_name.
 *
 * Preconditions:
 *  - reached only through the vtable.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): "National Weather Service".
 */
static const char *
nws_get_name(WxProvider *provider)
{
  (void)provider;
  return NWS_NAME;
}

/**
 * nws_get_attribution:
 * @provider: (not nullable): the WxNws.
 *
 * WxProviderInterface.get_attribution.
 *
 * Preconditions:
 *  - reached only through the vtable.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): the credit line.
 */
static const char *
nws_get_attribution(WxProvider *provider)
{
  (void)provider;
  return NWS_ATTRIBUTION;
}

/**
 * nws_get_attribution_url:
 * @provider: (not nullable): the WxNws.
 *
 * WxProviderInterface.get_attribution_url.
 *
 * Preconditions:
 *  - reached only through the vtable.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is static.
 *
 * Returns: (transfer none): the https URL of the credit link.
 */
static const char *
nws_get_attribution_url(WxProvider *provider)
{
  (void)provider;
  return NWS_ATTRIBUTION_URL;
}

/**
 * nws_covers:
 * @provider: (not nullable): the WxNws.
 * @place: (not nullable): the place.
 *
 * WxProviderInterface.covers: the coarse US pre-filter, no I/O.
 *
 * Preconditions:
 *  - reached only through the vtable, @place non-NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: wx_geo_in_us_nws() of the place's coordinates.
 */
static gboolean
nws_covers(WxProvider *provider, const WxPlace *place)
{
  (void)provider;
  return wx_geo_in_us_nws(place->lat, place->lon);
}

/**
 * is_rate_limited:
 * @self: (not nullable): the provider.
 *
 * Tells whether the 429 back-off is running.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff now is before the end of the last 429 block.
 */
static gboolean
is_rate_limited(const WxNws *self)
{
  return now_us() < self->blocked_until_us;
}

/**
 * note_failure:
 * @self: (not nullable): the provider.
 * @error: (not nullable): a WxHttp failure.
 *
 * Starts the WX_NWS_RATE_LIMIT_S back-off when @error is WX_ERROR_RATE_LIMITED.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - on a rate-limit error the block ends WX_NWS_RATE_LIMIT_S seconds from now (never earlier
 *    than before).
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
note_failure(WxNws *self, const GError *error)
{
  if (!g_error_matches(error, WX_ERROR, WX_ERROR_RATE_LIMITED))
    return;
  gint64 until = deadline_after(now_us(), WX_NWS_RATE_LIMIT_S);
  if (until > self->blocked_until_us)
    self->blocked_until_us = until;
}

/**
 * return_rate_limited:
 * @task: (not nullable): the fetch task.
 *
 * Completes @task with WX_ERROR_RATE_LIMITED for the running back-off.
 *
 * Preconditions:
 *  - @task is not completed yet.
 * Postconditions:
 *  - @task is completed.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller.
 */
static void
return_rate_limited(GTask *task)
{
  g_task_return_new_error(task, WX_ERROR, WX_ERROR_RATE_LIMITED,
                          "NWS asked for fewer requests; waiting %d seconds", WX_NWS_RATE_LIMIT_S);
}

static void on_points_done(GObject *source, GAsyncResult *result, gpointer user_data);
static void on_grid_done(GObject *source, GAsyncResult *result, gpointer user_data);

/**
 * start_gridpoints:
 * @task: (not nullable): the fetch task.
 * @grid: (not nullable): the cell to fetch.
 *
 * Starts step 2 (/gridpoints) unless the 429 back-off is running.
 *
 * Preconditions:
 *  - @task is not completed; @grid is valid.
 * Postconditions:
 *  - on_grid_done() will complete @task, or @task is completed now (back-off).
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller; the request holds its own reference.
 */
static void
start_gridpoints(GTask *task, const WxNwsGrid *grid)
{
  WxNws *self = g_task_get_source_object(task);
  if (is_rate_limited(self)) {
    return_rate_limited(task);
    return;
  }
  g_autofree char *path = g_strdup_printf("/gridpoints/%s/%u,%u", grid->grid_id, grid->x, grid->y);
  wx_http_get_async(self->http, path, NWS_ACCEPT, NULL, g_task_get_cancellable(task),
                    on_grid_done, g_object_ref(task));
}

/**
 * on_points_done:
 * @source: the WxHttp.
 * @result: the request result.
 * @user_data: (transfer full): the fetch task.
 *
 * Step 1 finished: 404 marks the point unsupported, a cell is cached and step 2 starts.
 *
 * Preconditions:
 *  - called once by WxHttp with the task reference given at the call.
 * Postconditions:
 *  - the task is completed or step 2 is running; the reference is released.
 * Thread affinity: main thread only.
 * Ownership: consumes the task reference.
 */
static void
on_points_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  WxNws *self = g_task_get_source_object(task);
  const char *key = g_task_get_task_data(task);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  if (response == NULL) {
    note_failure(self, error);
    if (g_error_matches(error, WX_ERROR, WX_ERROR_NOT_FOUND)) {
      cache_store(self->unsupported, key, NULL, G_MAXINT64);
      g_task_return_new_error(task, WX_ERROR, WX_ERROR_UNSUPPORTED,
                              "place is outside the NWS coverage");
    } else {
      g_task_return_error(task, g_steal_pointer(&error));
    }
    return;
  }
  gsize len;
  const guint8 *body = g_bytes_get_data(response->body, &len);
  WxNwsGrid grid;
  if (!wx_nws_parse_points(body, len, &grid, &error)) {
    g_task_return_error(task, g_steal_pointer(&error));
    return;
  }
  cache_store(self->grids, key, &grid, deadline_after(now_us(), WX_NWS_GRID_TTL_S));
  start_gridpoints(task, &grid);
}

/**
 * on_grid_done:
 * @source: the WxHttp.
 * @result: the request result.
 * @user_data: (transfer full): the fetch task.
 *
 * Step 2 finished: parses the grid into the member and completes the task.
 *
 * Preconditions:
 *  - called once by WxHttp with the task reference given at the call.
 * Postconditions:
 *  - the task is completed; a 404 also forgets the cached cell of the point; the reference is
 *    released.
 * Thread affinity: main thread only.
 * Ownership: consumes the task reference.
 */
static void
on_grid_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  WxNws *self = g_task_get_source_object(task);
  const char *key = g_task_get_task_data(task);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  if (response == NULL) {
    note_failure(self, error);
    if (g_error_matches(error, WX_ERROR, WX_ERROR_NOT_FOUND)) {
      for (guint i = 0; i < self->grids->len; i++) {
        if (strcmp(((const CacheEntry *)g_ptr_array_index(self->grids, i))->key, key) == 0) {
          g_ptr_array_remove_index(self->grids, i);
          break;
        }
      }
    }
    g_task_return_error(task, g_steal_pointer(&error));
    return;
  }
  gsize len;
  const guint8 *body = g_bytes_get_data(response->body, &len);
  g_autoptr(WxMember) member =
    wx_nws_parse_gridpoints(body, len, g_get_real_time() / G_USEC_PER_SEC, &error);
  g_autoptr(WxSourceResult) out = member != NULL ? wx_source_result_new(WX_NWS_ID, &error) : NULL;
  if (out == NULL) {
    g_task_return_error(task, g_steal_pointer(&error));
    return;
  }
  g_ptr_array_add(out->members, g_steal_pointer(&member));
  g_task_return_pointer(task, g_steal_pointer(&out), (GDestroyNotify)wx_source_result_free);
}

/**
 * point_key:
 * @place: (not nullable): a valid place.
 *
 * Builds the "<lat>,<lon>" text of a place: both coordinates rounded to four decimals and
 * printed with a dot whatever the locale.
 *
 * Preconditions:
 *  - the coordinates are valid (wx_geo_valid()).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: the caller owns the string.
 *
 * Returns: (transfer full): e.g. "25.7617,-80.1918".
 */
static char *
point_key(const WxPlace *place)
{
  char lat[G_ASCII_DTOSTR_BUF_SIZE], lon[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_formatd(lat, sizeof lat, "%.4f", wx_geo_round4(place->lat));
  g_ascii_formatd(lon, sizeof lon, "%.4f", wx_geo_round4(place->lon));
  return g_strconcat(lat, ",", lon, NULL);
}

/**
 * nws_fetch_async:
 * @provider: (not nullable): the WxNws.
 * @place: (not nullable): the place.
 * @cancellable: (nullable): cancels the operation.
 * @callback: invoked once.
 * @user_data: passed to @callback.
 *
 * WxProviderInterface.fetch_async: validates, consults the caches and the 429 back-off, then
 * runs the two requests.
 *
 * Preconditions:
 *  - reached through wx_provider_fetch_async().
 * Postconditions:
 *  - @callback runs exactly once, never before this function returns.
 * Thread affinity: main thread only.
 * Ownership: the task holds references on @provider and @cancellable; @place is copied (only
 *   the point key is kept).
 */
static void
nws_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
                GAsyncReadyCallback callback, gpointer user_data)
{
  WxNws *self = WX_NWS(provider);
  GTask *task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_fetch);
  g_autoptr(WxPlace) copy = wx_place_copy(place);
  if (copy == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid place");
  } else if (!wx_geo_in_us_nws(copy->lat, copy->lon)) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_UNSUPPORTED,
                            "place is outside the NWS coverage");
  } else {
    char *key = point_key(copy);
    g_task_set_task_data(task, key, g_free);
    if (cache_lookup(self->unsupported, key) != NULL) {
      g_task_return_new_error(task, WX_ERROR, WX_ERROR_UNSUPPORTED,
                              "place is outside the NWS coverage");
    } else if (is_rate_limited(self)) {
      return_rate_limited(task);
    } else {
      const CacheEntry *cached = cache_lookup(self->grids, key);
      if (cached != NULL) {
        WxNwsGrid grid = cached->grid;
        start_gridpoints(task, &grid);
      } else {
        g_autofree char *path = g_strconcat("/points/", key, NULL);
        wx_http_get_async(self->http, path, NWS_ACCEPT, NULL, cancellable, on_points_done,
                          g_object_ref(task));
      }
    }
  }
  g_object_unref(task);
}

/**
 * nws_fetch_finish:
 * @provider: (not nullable): the WxNws the fetch was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxProviderInterface.fetch_finish.
 *
 * Preconditions:
 *  - @result is a fetch task of @provider, not finished before (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed.
 * Thread affinity: main thread only.
 * Ownership: the result is returned to the caller.
 *
 * Returns: (transfer full) (nullable): the source result, or NULL with @error.
 */
static WxSourceResult *
nws_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, provider), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_fetch, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_nws_provider_init:
 * @iface: (not nullable): the WxProvider interface structure of WxNws.
 *
 * Interface initialiser named in G_IMPLEMENT_INTERFACE(): fills the vtable.
 *
 * Preconditions:
 *  - called by GObject when the interface is set up.
 * Postconditions:
 *  - every virtual function is set.
 * Thread affinity: any thread (under the type lock).
 * Ownership: @iface belongs to GObject.
 */
static void
wx_nws_provider_init(WxProviderInterface *iface)
{
  iface->get_id = nws_get_id;
  iface->get_name = nws_get_name;
  iface->get_attribution = nws_get_attribution;
  iface->get_attribution_url = nws_get_attribution_url;
  iface->covers = nws_covers;
  iface->fetch_async = nws_fetch_async;
  iface->fetch_finish = nws_fetch_finish;
}
