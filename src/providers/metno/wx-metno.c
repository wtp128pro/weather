/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-metno.c - WxMetno: MET Norway locationforecast provider. See wx-metno.h. */
#include "wx-metno.h"

#include <string.h>

#include "wx-geo.h"
#include "wx-http.h"
#include "wx-json.h"
#include "wx-time.h"

#ifdef WX_METNO_TESTING
#include "wx-metno-testing.h"
#endif

/* Accept header of every request. */
#define METNO_ACCEPT "application/json"
/* Request target up to the first coordinate. */
#define METNO_PATH_PREFIX "/weatherapi/locationforecast/2.0/complete?lat="
/* An Expires time is never honoured for longer than this after the answer that carried it. */
#define METNO_EXPIRES_MAX_S 86400
/* m/s -> km/h. */
#define METNO_MS_TO_KMH 3.6

/* Source tag of the tasks created by wx_provider_fetch_async(). */
static char tag_fetch;

/* ------------------------------------------------------------------------ */
/* Clock                                                                    */
/* ------------------------------------------------------------------------ */

#ifdef WX_METNO_TESTING
static WxMetnoClock test_clock;

/* Documented in wx-metno-testing.h. */
void
wx_metno_test_set_clock(WxMetnoClock source)
{
  test_clock = source;
}
#endif

/**
 * clock_now_s:
 *
 * Reads the clock of the cache floor, Expires handling and throttle.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: UTC unix seconds (the system clock, or the test hook), clamped to
 *   [0, G_MAXINT64 / 4] so that the sums and differences made with it cannot
 *   overflow.
 */
static gint64
clock_now_s(void)
{
  gint64 t = g_get_real_time() / G_USEC_PER_SEC;
#ifdef WX_METNO_TESTING
  if (test_clock != NULL)
    t = test_clock();
#endif
  return CLAMP(t, 0, G_MAXINT64 / 4);
}

/* ------------------------------------------------------------------------ */
/* Request target                                                           */
/* ------------------------------------------------------------------------ */

/**
 * format_coord:
 * @v: a coordinate, finite.
 * @out: (out): receives the text, G_ASCII_DTOSTR_BUF_SIZE bytes.
 *
 * Prints @v with four decimals, '.' as decimal point, and no negative zero.
 *
 * Preconditions:
 *  - @v is finite and within +-180; @out has G_ASCII_DTOSTR_BUF_SIZE bytes.
 * Postconditions:
 *  - @out holds the NUL-terminated text, e.g. "-80.1918" or "0.0000".
 * Thread affinity: any thread (locale independent).
 * Ownership: none.
 */
static void
format_coord(double v, char out[G_ASCII_DTOSTR_BUF_SIZE])
{
  (void)g_ascii_formatd(out, G_ASCII_DTOSTR_BUF_SIZE, "%.4f", v);
  if (strcmp(out, "-0.0000") == 0)
    memcpy(out, "0.0000", sizeof "0.0000");
}

/**
 * format_coords:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 * @lat_text: (out): receives the latitude text.
 * @lon_text: (out): receives the longitude text.
 *
 * Formats a coordinate pair as it is sent to the service and used as the
 * cache key.
 *
 * Preconditions:
 *  - both buffers have G_ASCII_DTOSTR_BUF_SIZE bytes.
 * Postconditions:
 *  - on TRUE both buffers hold format_coord() text; on FALSE they are untouched.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: wx_geo_valid(@lat, @lon).
 */
static gboolean
format_coords(double lat, double lon, char lat_text[G_ASCII_DTOSTR_BUF_SIZE],
              char lon_text[G_ASCII_DTOSTR_BUF_SIZE])
{
  if (!wx_geo_valid(lat, lon))
    return FALSE;
  format_coord(lat, lat_text);
  format_coord(lon, lon_text);
  return TRUE;
}

/* Documented in wx-metno.h. */
char *
wx_metno_forecast_path(double lat, double lon)
{
  char lat_text[G_ASCII_DTOSTR_BUF_SIZE];
  char lon_text[G_ASCII_DTOSTR_BUF_SIZE];
  if (!format_coords(lat, lon, lat_text, lon_text))
    return NULL;
  return g_strconcat(METNO_PATH_PREFIX, lat_text, "&lon=", lon_text, NULL);
}

/* ------------------------------------------------------------------------ */
/* Parser                                                                   */
/* ------------------------------------------------------------------------ */

/* Units the parser converts from; a document naming another one is refused. */
static const struct {
  const char *name;
  const char *unit;
} expected_units[] = {
    {"air_temperature", "celsius"},
    {"apparent_air_temperature", "celsius"},
    {"cloud_area_fraction", "%"},
    {"relative_humidity", "%"},
    {"wind_speed", "m/s"},
    {"wind_speed_of_gust", "m/s"},
    {"precipitation_amount", "mm"},
};

/**
 * units_are_expected:
 * @props: (nullable): the "properties" object of a document.
 *
 * Checks properties.meta.units against expected_units[].
 *
 * Preconditions:
 *  - none (a NULL or mistyped tree has no units and is accepted).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (the tree is read only).
 * Ownership: nothing is retained.
 *
 * Returns: FALSE iff the units object names one of the variables with a value
 *   that is not the expected unit string (a non-string included); a missing
 *   units object or a missing name is accepted.
 */
static gboolean
units_are_expected(JsonObject *props)
{
  JsonObject *units = wx_json_member_object(wx_json_member_object(props, "meta"), "units");
  if (units == NULL)
    return TRUE;
  for (guint i = 0; i < G_N_ELEMENTS(expected_units); i++) {
    if (!json_object_has_member(units, expected_units[i].name))
      continue;
    const char *unit = wx_json_member_string(units, expected_units[i].name);
    if (unit == NULL || strcmp(unit, expected_units[i].unit) != 0)
      return FALSE;
  }
  return TRUE;
}

/**
 * details_value:
 * @details: (nullable): a "details" object.
 * @name: member name.
 * @factor: multiplier applied to the number (unit conversion), finite.
 * @lo: inclusive lower bound of the converted value.
 * @hi: inclusive upper bound of the converted value.
 *
 * Reads one numeric detail, converts and range-checks it.
 *
 * Preconditions:
 *  - @name is non-NULL; @details may be NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (the tree is read only).
 * Ownership: nothing is retained.
 *
 * Returns: the value times @factor when the member is a finite number whose
 *   product is finite and within [@lo, @hi] (a negative zero becomes +0.0),
 *   else NAN.
 */
static double
details_value(JsonObject *details, const char *name, double factor, double lo, double hi)
{
  double v;
  if (details == NULL || !wx_json_member_number(details, name, &v))
    return NAN;
  v *= factor;
  if (!wx_value_in_range(v, lo, hi))
    return NAN;
  return v == 0.0 ? 0.0 : v;
}

/**
 * entry_to_hour:
 * @entry: a timeseries element.
 * @hour: (out): receives the hour.
 *
 * Converts one timeseries element (see wx_metno_parse_forecast()).
 *
 * Preconditions:
 *  - @entry and @hour are non-NULL.
 * Postconditions:
 *  - on TRUE *@hour is initialised with t_s and the usable values (the rest
 *    NAN / -1); on FALSE *@hour is unspecified.
 * Thread affinity: any thread (the tree is read only).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the time parses and at least one value is finite.
 */
static gboolean
entry_to_hour(JsonObject *entry, WxHour *hour)
{
  gint64 t_s;
  if (!wx_time_parse_iso8601(wx_json_member_string(entry, "time"), &t_s))
    return FALSE;
  JsonObject *data = wx_json_member_object(entry, "data");
  JsonObject *instant = wx_json_member_object(wx_json_member_object(data, "instant"), "details");
  JsonObject *next = wx_json_member_object(wx_json_member_object(data, "next_1_hours"), "details");
  wx_hour_init(hour);
  hour->t_s = t_s;
  hour->temp_c = details_value(instant, "air_temperature", 1.0, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
  hour->feels_c =
      details_value(instant, "apparent_air_temperature", 1.0, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
  hour->cloud_pct =
      details_value(instant, "cloud_area_fraction", 1.0, WX_PERCENT_MIN, WX_PERCENT_MAX);
  hour->humidity_pct =
      details_value(instant, "relative_humidity", 1.0, WX_PERCENT_MIN, WX_PERCENT_MAX);
  hour->wind_kmh = details_value(instant, "wind_speed", METNO_MS_TO_KMH, 0.0, WX_WIND_MAX_KMH);
  hour->gust_kmh =
      details_value(instant, "wind_speed_of_gust", METNO_MS_TO_KMH, 0.0, WX_WIND_MAX_KMH);
  hour->precip_mm = details_value(next, "precipitation_amount", 1.0, 0.0, WX_PRECIP_MAX_MM_H);
  return !isnan(hour->temp_c) || !isnan(hour->feels_c) || !isnan(hour->cloud_pct) ||
         !isnan(hour->humidity_pct) || !isnan(hour->wind_kmh) || !isnan(hour->gust_kmh) ||
         !isnan(hour->precip_mm);
}

/* Documented in wx-metno.h. */
WxMember *
wx_metno_parse_forecast(const guint8 *data, gsize len, gint64 fetched_s, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  g_autoptr(WxMember) member =
      wx_member_new(WX_METNO_PROVIDER_ID, WX_METNO_MODEL_ID, fetched_s, NULL);
  if (member == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "fetch time out of range");
    return NULL;
  }
  g_autoptr(JsonParser) parser =
      wx_json_parse(data, len, WX_HTTP_MAX_BODY_BYTES, WX_JSON_ROOT_OBJECT, error);
  if (parser == NULL)
    return NULL;
  JsonObject *props =
      wx_json_member_object(json_node_get_object(json_parser_get_root(parser)), "properties");
  JsonArray *series = wx_json_member_array(props, "timeseries");
  if (series == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "not a locationforecast document");
    return NULL;
  }
  if (!units_are_expected(props)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "unexpected units");
    return NULL;
  }
  guint n = json_array_get_length(series);
  for (guint i = 0; i < n && member->n_hours < WX_MEMBER_MAX_HOURS; i++) {
    JsonNode *node = json_array_get_element(series, i);
    WxHour hour;
    if (JSON_NODE_HOLDS_OBJECT(node) && entry_to_hour(json_node_get_object(node), &hour))
      (void)wx_member_add_hour(member, &hour);
  }
  if (member->n_hours == 0) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "no usable forecast data");
    return NULL;
  }
  return g_steal_pointer(&member);
}

/* ------------------------------------------------------------------------ */
/* Cache entries                                                            */
/* ------------------------------------------------------------------------ */

/* What the last successful answer for one place left behind. */
typedef struct {
  WxMember *member;    /* the parsed forecast; owned, never NULL */
  char *last_modified; /* validated Last-Modified text, NULL when none */
  gint64 expires_s;    /* validated Expires time (<= checked_s + 24 h), 0 when none */
  gint64 checked_s;    /* clock reading of the answer */
  guint64 used;        /* LRU stamp: larger is more recent */
} CacheEntry;

/**
 * cache_entry_free:
 * @data: (not nullable): a CacheEntry, as the hash table's value destroy function.
 *
 * Frees an entry.
 *
 * Preconditions:
 *  - @data is a CacheEntry (the table never stores NULL) that is not used afterwards.
 * Postconditions:
 *  - the member reference and the text are released.
 * Thread affinity: main thread only.
 * Ownership: consumes @data.
 */
static void
cache_entry_free(gpointer data)
{
  CacheEntry *entry = data;
  wx_member_unref(entry->member);
  g_free(entry->last_modified);
  g_free(entry);
}

/**
 * entry_is_fresh:
 * @entry: a cache entry.
 * @now_s: the clock reading.
 *
 * Applies the freshness rules of the file comment of wx-metno.h (fewer than
 * WX_METNO_MIN_REFRESH_S seconds since the last successful answer, or before
 * the Expires time). The floor between requests is request_floor_applies().
 *
 * Preconditions:
 *  - @now_s and the entry's times are within [0, G_MAXINT64 / 4].
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the entry may be served without a request.
 */
static gboolean
entry_is_fresh(const CacheEntry *entry, gint64 now_s)
{
  if (now_s < entry->checked_s)
    return FALSE;
  return now_s - entry->checked_s < WX_METNO_MIN_REFRESH_S || now_s < entry->expires_s;
}

/* When the last request for one place was handed to WxHttp. */
typedef struct {
  gint64 sent_s; /* clock reading at that moment */
  guint64 used;  /* LRU stamp: larger is more recent */
} RequestRecord;

/* ------------------------------------------------------------------------ */
/* WxMetno                                                                  */
/* ------------------------------------------------------------------------ */

struct _WxMetno {
  GObject parent_instance;
  WxHttp *http;             /* the only I/O channel */
  GHashTable *cache;        /* char * key -> CacheEntry *, at most WX_METNO_CACHE_MAX */
  GHashTable *requests;     /* char * key -> RequestRecord *, at most WX_METNO_CACHE_MAX */
  GHashTable *flights;      /* Flight::key (borrowed) -> Flight * (borrowed): requests in flight */
  guint outstanding;        /* requests whose WxHttp operation is not yet released */
  guint64 tick;             /* source of CacheEntry::used and RequestRecord::used */
  gint64 throttle_until_s;  /* no new request before this clock reading (after an HTTP 429) */
};

static void wx_metno_provider_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxMetno, wx_metno, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, wx_metno_provider_init))

/**
 * wx_metno_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: creates the empty tables.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxMetno being constructed by GObject.
 * Postconditions:
 *  - cache, requests and flights are empty; http is set by the constructors.
 * Thread affinity: main thread only.
 * Ownership: @self owns the tables.
 */
static void
wx_metno_init(WxMetno *self)
{
  self->cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, cache_entry_free);
  self->requests = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
  self->flights = g_hash_table_new(g_str_hash, g_str_equal);
}

/**
 * wx_metno_finalize:
 * @object: (not nullable): the WxMetno being finalized.
 *
 * GObject finalize: releases the tables and the HTTP engine. Every request in
 * flight holds a reference to the provider, so none is outstanding here.
 *
 * Preconditions:
 *  - @object is a WxMetno whose last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns its tables and its WxHttp.
 */
static void
wx_metno_finalize(GObject *object)
{
  WxMetno *self = WX_METNO(object);
  g_clear_object(&self->http);
  g_hash_table_unref(self->cache);
  g_hash_table_unref(self->requests);
  g_hash_table_unref(self->flights);
  G_OBJECT_CLASS(wx_metno_parent_class)->finalize(object);
}

/**
 * wx_metno_class_init:
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
wx_metno_class_init(WxMetnoClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_metno_finalize;
}

/**
 * cache_store:
 * @self: the provider.
 * @key: cache key of the place.
 * @member: the member answered for it.
 * @last_modified: (nullable): validated Last-Modified text to keep.
 * @expires_s: validated Expires time of the answer, 0 for none.
 * @now_s: the clock reading of the answer.
 *
 * Creates or replaces the entry of @key, dropping the least recently used
 * entry first when a new one would exceed WX_METNO_CACHE_MAX.
 *
 * Preconditions:
 *  - @member is a finished (shared, immutable) member.
 * Postconditions:
 *  - the entry holds its own reference to @member and copies of the text; its
 *    expiry is limited to 24 hours after @now_s; the cache has at most
 *    WX_METNO_CACHE_MAX entries.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained from the arguments but the member reference.
 */
static void
cache_store(WxMetno *self, const char *key, WxMember *member, const char *last_modified,
            gint64 expires_s, gint64 now_s)
{
  CacheEntry *entry = g_hash_table_lookup(self->cache, key);
  g_autoptr(WxMember) old_member = NULL; /* released last: @member may be the entry's own */
  g_autofree char *old_last_modified = NULL;
  if (entry == NULL) {
    if (g_hash_table_size(self->cache) >= WX_METNO_CACHE_MAX) {
      GHashTableIter iter;
      gpointer k, v;
      const char *oldest = NULL;
      guint64 oldest_used = G_MAXUINT64;
      g_hash_table_iter_init(&iter, self->cache);
      while (g_hash_table_iter_next(&iter, &k, &v)) {
        if (((CacheEntry *)v)->used <= oldest_used) {
          oldest_used = ((CacheEntry *)v)->used;
          oldest = k;
        }
      }
      g_hash_table_remove(self->cache, oldest);
    }
    entry = g_new0(CacheEntry, 1);
    g_hash_table_insert(self->cache, g_strdup(key), entry);
  } else {
    old_member = entry->member;
    old_last_modified = entry->last_modified;
  }
  entry->member = wx_member_ref(member);
  entry->last_modified = g_strdup(last_modified);
  entry->expires_s = expires_s > 0 ? MIN(expires_s, now_s + METNO_EXPIRES_MAX_S) : 0;
  entry->checked_s = now_s;
  entry->used = ++self->tick;
}

/**
 * request_floor_applies:
 * @self: the provider.
 * @key: cache key of the place.
 * @now_s: the clock reading.
 *
 * Applies the floor between two requests for one place (file comment of
 * wx-metno.h): a request for the place was handed to WxHttp, answered or not,
 * fewer than WX_METNO_MIN_REFRESH_S seconds ago.
 *
 * Preconditions:
 *  - @now_s and the recorded times are within [0, G_MAXINT64 / 4].
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff a new request for @key must not be sent now. A record that
 *   lies in the future of the clock (the clock moved backwards) does not apply.
 */
static gboolean
request_floor_applies(const WxMetno *self, const char *key, gint64 now_s)
{
  const RequestRecord *record = g_hash_table_lookup(self->requests, key);
  if (record == NULL || now_s < record->sent_s)
    return FALSE;
  return now_s - record->sent_s < WX_METNO_MIN_REFRESH_S;
}

/**
 * request_record:
 * @self: the provider.
 * @key: cache key of the place.
 * @now_s: the clock reading at which a request for @key is handed to WxHttp.
 *
 * Remembers that moment as the last request for @key, dropping the record
 * that was made, or renewed, longest ago first when a new one would exceed
 * WX_METNO_CACHE_MAX.
 *
 * Preconditions:
 *  - @now_s is within [0, G_MAXINT64 / 4].
 * Postconditions:
 *  - @key has a record with time @now_s; there are at most WX_METNO_CACHE_MAX
 *    records.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained from the arguments.
 */
static void
request_record(WxMetno *self, const char *key, gint64 now_s)
{
  RequestRecord *record = g_hash_table_lookup(self->requests, key);
  if (record == NULL) {
    if (g_hash_table_size(self->requests) >= WX_METNO_CACHE_MAX) {
      GHashTableIter iter;
      gpointer k, v;
      const char *oldest = NULL;
      guint64 oldest_used = G_MAXUINT64;
      g_hash_table_iter_init(&iter, self->requests);
      while (g_hash_table_iter_next(&iter, &k, &v)) {
        if (((RequestRecord *)v)->used <= oldest_used) {
          oldest_used = ((RequestRecord *)v)->used;
          oldest = k;
        }
      }
      g_hash_table_remove(self->requests, oldest);
    }
    record = g_new0(RequestRecord, 1);
    g_hash_table_insert(self->requests, g_strdup(key), record);
  }
  record->sent_s = now_s;
  record->used = ++self->tick;
}

/* ------------------------------------------------------------------------ */
/* Requests in flight                                                       */
/* ------------------------------------------------------------------------ */

/*
 * One HTTP request for one place and the fetches waiting for it. Reference
 * counted (main thread only): the WxHttp operation owns one reference until
 * its completion callback has run; the cancellation handler of a waiter takes
 * another while it works. Not shared across threads.
 */
typedef struct {
  gint refs;
  WxMetno *self;        /* strong reference: the provider outlives its requests */
  char *key;            /* cache key; also the key in WxMetno::flights while listed */
  char *ims;            /* If-Modified-Since sent, NULL when none */
  WxMember *base;       /* the member that validator belongs to, NULL when no validator */
  GCancellable *cancel; /* private: cancelled when no waiter is left */
  GPtrArray *waiters;   /* Waiter *, free function waiter_free() */
  gboolean listed;      /* WxMetno::flights points at this flight */
} Flight;

/* One fetch waiting for a flight. */
typedef struct {
  Flight *flight;  /* the flight that holds it in `waiters` */
  GTask *task;     /* the fetch; owned until completed, NULL once taken */
  GSource *watch;  /* completes the task when its cancellable fires, NULL without one */
} Waiter;

/**
 * waiter_free:
 * @data: (not nullable): a Waiter, as the array's element destroy function.
 *
 * Stops the cancellation watch and releases the waiter. A task that is still
 * held is dropped without being completed.
 *
 * Preconditions:
 *  - @data is a Waiter that is no longer in any array, not used afterwards.
 * Postconditions:
 *  - the watch is destroyed (it can no longer run) and everything is released.
 * Thread affinity: main thread only.
 * Ownership: consumes @data.
 */
static void
waiter_free(gpointer data)
{
  Waiter *waiter = data;
  if (waiter->watch != NULL) {
    g_source_destroy(waiter->watch);
    g_source_unref(waiter->watch);
  }
  g_clear_object(&waiter->task);
  g_free(waiter);
}

/**
 * flight_delist:
 * @flight: the flight.
 *
 * Removes the flight from WxMetno::flights, so that no later fetch can join it.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the table does not refer to @flight; calling again does nothing.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
flight_delist(Flight *flight)
{
  if (!flight->listed)
    return;
  flight->listed = FALSE;
  g_hash_table_remove(flight->self->flights, flight->key);
}

/**
 * flight_ref:
 * @flight: the flight.
 *
 * Takes a reference.
 *
 * Preconditions:
 *  - the caller already holds a reference or the flight is being created.
 * Postconditions:
 *  - the count grew by one.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the new reference.
 *
 * Returns: @flight.
 */
static Flight *
flight_ref(Flight *flight)
{
  flight->refs++;
  return flight;
}

/**
 * flight_unref:
 * @flight: the flight.
 *
 * Drops a reference; the last one frees the flight and drops its hold on the
 * provider (which may finalize it).
 *
 * Preconditions:
 *  - the caller owns a reference.
 * Postconditions:
 *  - at zero the flight is delisted and freed; every waiter has been
 *    completed or removed by then.
 * Thread affinity: main thread only.
 * Ownership: consumes the caller's reference.
 */
static void
flight_unref(Flight *flight)
{
  if (--flight->refs > 0)
    return;
  flight_delist(flight);
  g_ptr_array_unref(flight->waiters);
  g_clear_object(&flight->cancel);
  g_clear_pointer(&flight->base, wx_member_unref);
  g_free(flight->key);
  g_free(flight->ims);
  WxMetno *self = flight->self;
  g_free(flight);
  g_object_unref(self);
}

/**
 * on_waiter_cancelled:
 * @cancellable: (unused): the fetch's cancellable.
 * @user_data: (not nullable): the Waiter (passed as gpointer).
 *
 * GCancellableSourceFunc: the caller cancelled a fetch that waits for a
 * flight. The fetch completes with G_IO_ERROR_CANCELLED; when it was the last
 * waiter the flight is delisted and its request is cancelled.
 *
 * Preconditions:
 *  - @user_data is a Waiter still held by its flight (its watch runs only
 *    while it is).
 * Postconditions:
 *  - the waiter is gone, its task is completed with the cancellation error
 *    exactly once, the source is removed.
 * Thread affinity: main thread only.
 * Ownership: the waiter is consumed.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_waiter_cancelled(GCancellable *cancellable, gpointer user_data)
{
  (void)cancellable;
  Waiter *waiter = user_data;
  Flight *flight = flight_ref(waiter->flight);
  g_autoptr(GTask) task = g_steal_pointer(&waiter->task);
  g_ptr_array_remove(flight->waiters, waiter);
  if (flight->waiters->len == 0) {
    flight_delist(flight);
    g_cancellable_cancel(flight->cancel);
  }
  g_task_return_error(task, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED,
                                                "operation was cancelled"));
  flight_unref(flight);
  return G_SOURCE_REMOVE;
}

/**
 * flight_add_waiter:
 * @flight: the flight.
 * @task: the fetch's task (referenced).
 *
 * Makes a fetch wait for the flight and watch its cancellable.
 *
 * Preconditions:
 *  - the fetch's cancellable is not cancelled yet (a cancellation that
 *    happens meanwhile is still delivered through the watch).
 * Postconditions:
 *  - the flight holds a waiter with its own task reference; the task is
 *    completed by on_http_done() or on_waiter_cancelled(), once.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller (a reference is taken).
 */
static void
flight_add_waiter(Flight *flight, GTask *task)
{
  Waiter *waiter = g_new0(Waiter, 1);
  waiter->flight = flight;
  waiter->task = g_object_ref(task);
  GCancellable *cancellable = g_task_get_cancellable(task);
  if (cancellable != NULL) {
    waiter->watch = g_cancellable_source_new(cancellable);
    g_source_set_callback(waiter->watch, G_SOURCE_FUNC(on_waiter_cancelled), waiter, NULL);
    g_source_attach(waiter->watch, g_task_get_context(task));
  }
  g_ptr_array_add(flight->waiters, waiter);
}

/**
 * flight_is_abandoned:
 * @flight: a listed flight.
 *
 * Tells whether every fetch that waits for the flight has already been
 * cancelled, although the cancellation handlers have not run yet (they run
 * from the main loop). Such a flight is about to be cancelled and must not be
 * joined by a new fetch.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff every waiter's cancellable is cancelled.
 */
static gboolean
flight_is_abandoned(const Flight *flight)
{
  for (guint i = 0; i < flight->waiters->len; i++) {
    const Waiter *waiter = g_ptr_array_index(flight->waiters, i);
    GCancellable *cancellable = g_task_get_cancellable(waiter->task);
    if (cancellable == NULL || !g_cancellable_is_cancelled(cancellable))
      return FALSE;
  }
  return TRUE;
}

/**
 * flight_new:
 * @self: the provider.
 * @key: cache key of the place.
 * @entry: (nullable): the stale entry of the place, whose validator is sent.
 *
 * Creates and lists the flight of a new request and counts it as outstanding.
 *
 * Preconditions:
 *  - no flight is listed for @key.
 * Postconditions:
 *  - the flight (one reference, owned by the caller for the HTTP operation)
 *    is listed, holds a reference to @self, and carries @entry's validator
 *    and member when @entry has a Last-Modified text.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the flight.
 */
static Flight *
flight_new(WxMetno *self, const char *key, const CacheEntry *entry)
{
  Flight *flight = g_new0(Flight, 1);
  flight->refs = 1;
  flight->self = g_object_ref(self);
  flight->key = g_strdup(key);
  flight->cancel = g_cancellable_new();
  flight->waiters = g_ptr_array_new_with_free_func(waiter_free);
  if (entry != NULL && entry->last_modified != NULL) {
    flight->ims = g_strdup(entry->last_modified);
    flight->base = wx_member_ref(entry->member);
  }
  flight->listed = TRUE;
  g_hash_table_insert(self->flights, flight->key, flight);
  self->outstanding++;
  return flight;
}

/**
 * on_result_released:
 * @data: (not nullable): the provider (passed as gpointer).
 * @where_the_object_was: (unused): the finalised result object.
 *
 * GWeakNotify of the result object of a finished HTTP operation: WxHttp counts
 * an operation as outstanding until that object is released, so the provider's
 * count can drop now too.
 *
 * Preconditions:
 *  - @data is the provider reference owned by the weak notification.
 * Postconditions:
 *  - the outstanding count dropped by one and the reference is released.
 * Thread affinity: main thread only.
 * Ownership: consumes the provider reference.
 */
static void
on_result_released(gpointer data, GObject *where_the_object_was)
{
  (void)where_the_object_was;
  WxMetno *self = data;
  self->outstanding--;
  g_object_unref(self);
}

/**
 * return_member:
 * @task: a fetch task that has not been returned.
 * @member: the member to answer with.
 *
 * Completes a fetch with a WxSourceResult holding one reference to @member.
 *
 * Preconditions:
 *  - @member is a finished member; @task is not completed yet.
 * Postconditions:
 *  - the task is completed (the callback may run before this returns unless
 *    GTask defers it).
 * Thread affinity: main thread only.
 * Ownership: @task and @member stay with the caller.
 */
static void
return_member(GTask *task, WxMember *member)
{
  WxSourceResult *result = wx_source_result_new(WX_METNO_PROVIDER_ID, NULL);
  g_assert(result != NULL); /* the id is a constant that wx_id_is_valid() accepts */
  g_ptr_array_add(result->members, wx_member_ref(member));
  g_task_return_pointer(task, result, (GDestroyNotify)wx_source_result_free);
}

/**
 * flight_resolve:
 * @self: the provider.
 * @flight: the finished flight.
 * @response: the HTTP response.
 * @now_s: the clock reading.
 * @error: (nullable): return location for a #GError.
 *
 * Turns the response into a member and records it in the cache: a 304 for a
 * flight that sent a validator returns the validated member again (and keeps
 * the old Last-Modified text when the 304 carries none), anything else is
 * parsed (a 304 without validator cannot come from WxHttp; it would be an
 * empty body, hence a parse error).
 *
 * Preconditions:
 *  - @response is a successful WxHttp response.
 * Postconditions:
 *  - on success the cache entry of the flight's key holds the member, with
 *    the response's Expires time and the new validator; on failure NULL is
 *    returned, *@error is set and the cache is unchanged.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the member.
 */
static WxMember *
flight_resolve(WxMetno *self, Flight *flight, const WxHttpResponse *response, gint64 now_s,
               GError **error)
{
  WxMember *member;
  const char *last_modified = response->last_modified;
  if (response->status == 304 && flight->base != NULL) {
    member = wx_member_ref(flight->base);
    if (last_modified == NULL)
      last_modified = flight->ims;
  } else {
    gsize len = 0;
    const guint8 *data = g_bytes_get_data(response->body, &len);
    member = wx_metno_parse_forecast(data, len, now_s, error);
    if (member == NULL)
      return NULL;
  }
  cache_store(self, flight->key, member, last_modified, response->expires_s, now_s);
  return member;
}

/**
 * on_http_done:
 * @source: (not nullable): the WxHttp.
 * @result: (not nullable): the operation's result.
 * @user_data: (not nullable): the Flight (the reference owned by the operation).
 *
 * GAsyncReadyCallback of the request: finishes it, updates cache and
 * throttle, then completes every fetch that still waits for the flight with
 * the same outcome (a member reference each, or a copy of the error).
 *
 * Preconditions:
 *  - @user_data is the flight started with this callback; called once.
 * Postconditions:
 *  - the flight is delisted, all its waiters are completed exactly once, the
 *    provider's slot is released when WxHttp releases the result object (right
 *    after this callback returns), and the operation's flight reference is
 *    dropped. An HTTP 429 started the throttle.
 * Thread affinity: main thread only.
 * Ownership: consumes the operation's flight reference.
 */
static void
on_http_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Flight *flight = user_data;
  WxMetno *self = flight->self;
  g_autoptr(GError) error = NULL;
  g_autoptr(WxHttpResponse) response = wx_http_get_finish(WX_HTTP(source), result, &error);
  gint64 now_s = clock_now_s();
  g_autoptr(WxMember) member = NULL;
  flight_delist(flight);
  if (response != NULL)
    member = flight_resolve(self, flight, response, now_s, &error);
  else if (g_error_matches(error, WX_ERROR, WX_ERROR_RATE_LIMITED))
    self->throttle_until_s = now_s + WX_METNO_THROTTLE_S;
  g_object_weak_ref(G_OBJECT(result), on_result_released, g_object_ref(self));
  while (flight->waiters->len > 0) {
    Waiter *waiter = g_ptr_array_steal_index(flight->waiters, 0);
    g_autoptr(GTask) task = g_steal_pointer(&waiter->task);
    waiter_free(waiter);
    if (member != NULL)
      return_member(task, member);
    else
      g_task_return_error(task, g_error_copy(error));
  }
  flight_unref(flight);
}

/* ------------------------------------------------------------------------ */
/* WxProvider implementation                                                */
/* ------------------------------------------------------------------------ */

/**
 * metno_get_id:
 * @provider: (not nullable): the WxMetno.
 *
 * WxProviderInterface.get_id.
 *
 * Preconditions:
 *  - @provider is a WxMetno (reached only through its vtable).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is a constant.
 *
 * Returns: (transfer none): WX_METNO_PROVIDER_ID.
 */
static const char *
metno_get_id(WxProvider *provider)
{
  (void)provider;
  return WX_METNO_PROVIDER_ID;
}

/**
 * metno_get_name:
 * @provider: (not nullable): the WxMetno.
 *
 * WxProviderInterface.get_name.
 *
 * Preconditions:
 *  - @provider is a WxMetno.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is a constant.
 *
 * Returns: (transfer none): "MET Norway".
 */
static const char *
metno_get_name(WxProvider *provider)
{
  (void)provider;
  return "MET Norway";
}

/**
 * metno_get_attribution:
 * @provider: (not nullable): the WxMetno.
 *
 * WxProviderInterface.get_attribution.
 *
 * Preconditions:
 *  - @provider is a WxMetno.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is a constant.
 *
 * Returns: (transfer none): "Data from MET Norway".
 */
static const char *
metno_get_attribution(WxProvider *provider)
{
  (void)provider;
  return "Data from MET Norway";
}

/**
 * metno_get_attribution_url:
 * @provider: (not nullable): the WxMetno.
 *
 * WxProviderInterface.get_attribution_url.
 *
 * Preconditions:
 *  - @provider is a WxMetno.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is a constant.
 *
 * Returns: (transfer none): "https://api.met.no/".
 */
static const char *
metno_get_attribution_url(WxProvider *provider)
{
  (void)provider;
  return "https://api.met.no/";
}

/**
 * metno_covers:
 * @provider: (not nullable): the WxMetno.
 * @place: (not nullable): the place.
 *
 * WxProviderInterface.covers: the service answers for the whole world.
 *
 * Preconditions:
 *  - @provider is a WxMetno; @place is non-NULL (checked by the dispatcher);
 *    its strings are not read, so a hand-built place is safe.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: wx_geo_valid() of the place's coordinates.
 */
static gboolean
metno_covers(WxProvider *provider, const WxPlace *place)
{
  (void)provider;
  return wx_geo_valid(place->lat, place->lon);
}

/**
 * metno_fetch_async:
 * @provider: (not nullable): the WxMetno.
 * @place: (not nullable): the place; copied and validated.
 * @cancellable: (nullable): cancels the operation.
 * @callback: called once with the result.
 * @user_data: passed to @callback.
 *
 * WxProviderInterface.fetch_async: an invalid place is WX_ERROR_INVALID_ARG,
 * a cancelled @cancellable G_IO_ERROR_CANCELLED, a fresh cache entry is
 * answered at once, a fetch joins the request in flight for the place, a
 * place whose last request was handed to WxHttp less than
 * WX_METNO_MIN_REFRESH_S ago is answered from its (stale) entry or, without
 * one, refused with WX_ERROR_RATE_LIMITED, and otherwise a request is started
 * (refused with WX_ERROR_RATE_LIMITED during a throttle or at the in-flight
 * cap); only a started request makes a record for the floor.
 *
 * Preconditions:
 *  - @provider is a WxMetno; @place is non-NULL (checked by the dispatcher).
 * Postconditions:
 *  - @callback is called exactly once, never before this function returns.
 * Thread affinity: main thread only.
 * Ownership: the task takes references on @provider and @cancellable.
 */
static void
metno_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
                  GAsyncReadyCallback callback, gpointer user_data)
{
  WxMetno *self = WX_METNO(provider);
  g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_fetch);
  g_autoptr(WxPlace) copy = wx_place_copy(place);
  if (copy == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid place");
    return;
  }
  if (g_task_return_error_if_cancelled(task))
    return;
  char lat_text[G_ASCII_DTOSTR_BUF_SIZE];
  char lon_text[G_ASCII_DTOSTR_BUF_SIZE];
  (void)format_coords(copy->lat, copy->lon, lat_text, lon_text); /* wx_place_copy() checked them */
  g_autofree char *key = g_strconcat(lat_text, ",", lon_text, NULL);
  gint64 now_s = clock_now_s();
  CacheEntry *entry = g_hash_table_lookup(self->cache, key);
  if (entry != NULL && entry_is_fresh(entry, now_s)) {
    entry->used = ++self->tick;
    return_member(task, entry->member);
    return;
  }
  Flight *flight = g_hash_table_lookup(self->flights, key);
  if (flight != NULL && flight_is_abandoned(flight))
    flight_delist(flight); /* its waiters' cancellations are on their way: do not join it */
  else if (flight != NULL) {
    flight_add_waiter(flight, task);
    return;
  }
  if (request_floor_applies(self, key, now_s)) {
    if (entry != NULL) {
      entry->used = ++self->tick;
      return_member(task, entry->member);
    } else {
      g_task_return_new_error(task, WX_ERROR, WX_ERROR_RATE_LIMITED,
                              "a request for this place was sent less than 10 minutes ago");
    }
    return;
  }
  if (now_s < self->throttle_until_s && self->throttle_until_s - now_s <= WX_METNO_THROTTLE_S) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_RATE_LIMITED,
                            "requests are paused after HTTP 429");
    return;
  }
  if (self->outstanding >= WX_HTTP_MAX_INFLIGHT) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_RATE_LIMITED,
                            "too many outstanding requests (limit %d)", WX_HTTP_MAX_INFLIGHT);
    return;
  }
  flight = flight_new(self, key, entry);
  request_record(self, key, now_s);
  flight_add_waiter(flight, task);
  g_autofree char *path = g_strconcat(METNO_PATH_PREFIX, lat_text, "&lon=", lon_text, NULL);
  wx_http_get_async(self->http, path, METNO_ACCEPT, flight->ims, flight->cancel, on_http_done,
                    flight);
}

/**
 * metno_fetch_finish:
 * @provider: (not nullable): the WxMetno the fetch was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxProviderInterface.fetch_finish.
 *
 * Preconditions:
 *  - @result is a task created by metno_fetch_async() for @provider and not
 *    yet finished (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed; on failure NULL is returned and *@error is set
 *    (G_IO_ERROR_CANCELLED when the fetch's cancellable was cancelled).
 * Thread affinity: main thread only.
 * Ownership: the result is returned to the caller.
 *
 * Returns: (transfer full) (nullable): the source result, or NULL with @error.
 */
static WxSourceResult *
metno_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, provider), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_fetch, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_metno_provider_init:
 * @iface: (not nullable): the WxProvider interface structure of WxMetno.
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
wx_metno_provider_init(WxProviderInterface *iface)
{
  iface->get_id = metno_get_id;
  iface->get_name = metno_get_name;
  iface->get_attribution = metno_get_attribution;
  iface->get_attribution_url = metno_get_attribution_url;
  iface->covers = metno_covers;
  iface->fetch_async = metno_fetch_async;
  iface->fetch_finish = metno_fetch_finish;
}

/* Documented in wx-metno.h. */
WxMetno *
wx_metno_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms, GError **error)
{
  g_return_val_if_fail(base_url != NULL, NULL);
  WxHttp *http =
      wx_http_new_custom(base_url, WX_METNO_USER_AGENT, timeout_ms, backoff_base_ms, 0, error);
  if (http == NULL)
    return NULL;
  WxMetno *self = g_object_new(WX_TYPE_METNO, NULL);
  self->http = http;
  return self;
}

/* Documented in wx-metno.h. */
WxMetno *
wx_metno_new(void)
{
  g_autoptr(GError) error = NULL;
  WxMetno *self = wx_metno_new_custom(WX_METNO_BASE_URL, WX_HTTP_TIMEOUT_MS,
                                      WX_HTTP_BACKOFF_BASE_MS, &error);
  g_assert_no_error(error); /* constants that wx_http_new_custom() accepts */
  return self;
}
