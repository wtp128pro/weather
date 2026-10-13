/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-cache.h"

#include <json-glib/json-glib.h>
#include <math.h>
#include <string.h>

#include "wx-fileio.h"
#include "wx-store-json.h"

#define CACHE_VERSION 1

/* Bytes examined of a caller's key: the longest key wx_place_key() builds is
 * "-90.0000,-180.0000" (18 bytes), so 24 bytes with the NUL leave room. */
#define KEY_BUF_LEN 24
G_STATIC_ASSERT(KEY_BUF_LEN >= sizeof "-90.0000,-180.0000");

/* Fetch times are accepted in [FETCHED_MIN_MS, FETCHED_MAX_MS): the time range
 * of the core types, so a hostile file cannot pin a forecast as "fresh" with a
 * fetch time in the far future. */
#define FETCHED_MIN_MS (WX_TIME_MIN_S * 1000)
#define FETCHED_MAX_MS (WX_TIME_MAX_S * 1000)

/* Source tag of wx_cache_save_async() tasks; only its address is used. */
static char save_tag;

/* One cached forecast. Also used (without lru_link) for save snapshots. */
typedef struct {
  char *key;           /* wx_place_key() of the forecast's place */
  WxForecast *forecast; /* one reference */
  gint64 fetched_ms;
  GList *lru_link; /* link in WxCache.lru; NULL in snapshots */
} Entry;

struct _WxCache {
  GObject parent_instance;
  char *path;
  GHashTable *by_key; /* key (owned by Entry) -> Entry*, owns the Entry */
  GQueue lru;         /* Entry*; head = least recently used */
  guint64 gen;        /* bumped by every successful put/remove */
  guint64 saved_gen;  /* gen captured by the last successful load/save snapshot */
  gboolean save_in_flight;
};

/*
 * G_DEFINE_TYPE(WxCache, wx_cache, G_TYPE_OBJECT) generates the following (checked with gcc -E
 * of this file with the project's compile flags):
 *  - GType wx_cache_get_type(void): returns the GType of WxCache and registers it on the first
 *    call, inside a once-initialisation guard, by calling wx_cache_get_type_once().
 *    Thread affinity: any thread. Ownership: none (no pointers).
 *  - static GType wx_cache_get_type_once(void): performs the registration for
 *    wx_cache_get_type().
 *    Thread affinity: only via wx_cache_get_type(). Ownership: none (no pointers).
 *  - static void wx_cache_class_intern_init(gpointer klass): @klass is the class structure being
 *    initialised (borrowed, written; nothing is retained). It stores the parent class in
 *    wx_cache_parent_class, adjusts the private offset only if WxCache_private_offset is
 *    non-zero, then calls wx_cache_class_init(). Called by GObject once per type, from the
 *    thread that first uses the type. Ownership: @klass belongs to GObject.
 *  - static gpointer wx_cache_parent_class: NULL until class_intern_init() runs; used by
 *    finalize() to chain up.
 *  - static gint WxCache_private_offset: stays 0 (no G_ADD_PRIVATE is used).
 *  - static inline gpointer wx_cache_get_instance_private(WxCache *self): returns self plus the
 *    private offset; unused here (G_GNUC_UNUSED). @self is borrowed. Thread affinity: any
 *    thread.
 */
G_DEFINE_TYPE(WxCache, wx_cache, G_TYPE_OBJECT)

/* ------------------------------------------------------------------------ */
/* Entries and LRU                                                          */
/* ------------------------------------------------------------------------ */

/**
 * entry_free:
 * @data: an Entry created by put_entry() or snapshot_take().
 *
 * GDestroyNotify of the key table and of the snapshot array: drops the
 * forecast reference, frees the key and the entry.
 *
 * Preconditions:
 *  - @data is a non-NULL, heap-allocated Entry owned by the caller (the
 *    container that frees it passes each element exactly once).
 * Postconditions:
 *  - the entry and everything it owns is released.
 * Thread affinity: any thread (the snapshot may be freed on the worker or on
 *   the main thread; the forecast reference count is atomic).
 * Ownership: consumes @data.
 */
static void
entry_free(gpointer data)
{
  Entry *e = data;
  wx_forecast_unref(e->forecast);
  g_free(e->key);
  g_free(e);
}

/**
 * wx_cache_finalize:
 * @object: the WxCache being finalized.
 *
 * GObject finalize: clears the LRU queue, releases the key table (which frees
 * the entries) and the path, then chains up.
 *
 * Preconditions:
 *  - @object is a WxCache whose last reference was dropped; no save is
 *    running (the save tasks hold a reference on the cache).
 * Postconditions:
 *  - all memory owned by the cache is freed; the parent finalize has run.
 * Thread affinity: the thread that drops the last reference.
 * Ownership: the cache owns its path, table and entries; all are released.
 */
static void
wx_cache_finalize(GObject *object)
{
  WxCache *self = WX_CACHE(object);
  g_queue_clear(&self->lru);
  g_hash_table_unref(self->by_key);
  g_free(self->path);
  G_OBJECT_CLASS(wx_cache_parent_class)->finalize(object);
}

/**
 * wx_cache_class_init:
 * @klass: the class structure being initialised.
 *
 * GObject class_init: installs finalize.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - the finalize vfunc is set.
 * Thread affinity: the thread that first uses the type (GType serialises it).
 * Ownership: none (the class is owned by GType).
 */
static void
wx_cache_class_init(WxCacheClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_cache_finalize;
}

/**
 * wx_cache_init:
 * @self: the instance being initialised.
 *
 * GObject instance init: creates the key table (owning its entries) and
 * initialises the LRU queue.
 *
 * Preconditions:
 *  - @self is a zero-initialised new instance.
 * Postconditions:
 *  - by_key is an empty table that frees entries with entry_free(); lru is an
 *    empty queue; path is still NULL (set by wx_cache_new()).
 * Thread affinity: the creating thread.
 * Ownership: the instance owns the new table.
 */
static void
wx_cache_init(WxCache *self)
{
  self->by_key = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, entry_free);
  g_queue_init(&self->lru);
}

/* Documented in wx-cache.h. */
WxCache *
wx_cache_new(const char *path)
{
  g_return_val_if_fail(path == NULL || path[0] != '\0', NULL);
  WxCache *self = g_object_new(WX_TYPE_CACHE, NULL);
  self->path = path != NULL
                 ? g_strdup(path)
                 : g_build_filename(g_get_user_cache_dir(), "weather", "forecasts.json", NULL);
  return self;
}

/* Documented in wx-cache.h. */
const char *
wx_cache_get_path(WxCache *self)
{
  g_return_val_if_fail(WX_IS_CACHE(self), NULL);
  return self->path;
}

/* Documented in wx-cache.h. */
guint
wx_cache_get_n_places(WxCache *self)
{
  g_return_val_if_fail(WX_IS_CACHE(self), 0);
  return g_hash_table_size(self->by_key);
}

/**
 * touch:
 * @self: the cache.
 * @e: an entry of @self.
 *
 * Makes @e the most recently used entry (moves its link to the queue tail).
 *
 * Preconditions:
 *  - @e is an entry of @self with a non-NULL lru_link that is currently in
 *    self->lru (true for every entry created by put_entry(); snapshot entries
 *    are never passed here).
 * Postconditions:
 *  - @e is the tail of the LRU queue; no entry is added or removed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: none transferred; the link stays owned by the queue.
 */
static void
touch(WxCache *self, Entry *e)
{
  if (e->lru_link != g_queue_peek_tail_link(&self->lru)) {
    g_queue_unlink(&self->lru, e->lru_link);
    g_queue_push_tail_link(&self->lru, e->lru_link);
  }
}

/**
 * find_entry:
 * @self: the cache.
 * @key: (nullable): a caller's place key.
 *
 * Looks a key up without changing the recency.
 *
 * Preconditions:
 *  - @self is a valid cache; @key is NULL, NUL-terminated, or has KEY_BUF_LEN
 *    readable bytes.
 * Postconditions:
 *  - no state is changed; at most KEY_BUF_LEN bytes of @key are read.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: (transfer none) (nullable): the entry, or NULL if @key is NULL,
 *   not NUL-terminated within KEY_BUF_LEN bytes or unknown.
 */
static Entry *
find_entry(WxCache *self, const char *key)
{
  if (key == NULL || memchr(key, '\0', KEY_BUF_LEN) == NULL)
    return NULL;
  return g_hash_table_lookup(self->by_key, key);
}

/**
 * evict_oldest:
 * @self: the cache.
 *
 * Removes the least recently used entry with its forecast.
 *
 * Preconditions:
 *  - @self is a valid cache whose queue is non-empty (call sites only call it
 *    while the table holds more than WX_CACHE_MAX_PLACES entries); every entry
 *    of by_key is in self->lru.
 * Postconditions:
 *  - the head entry is removed from the queue and the table (and freed).
 * Thread affinity: the thread that owns the cache.
 * Ownership: the evicted entry is freed by the table.
 */
static void
evict_oldest(WxCache *self)
{
  Entry *e = g_queue_pop_head(&self->lru);
  g_hash_table_remove(self->by_key, e->key); /* frees e */
}

/**
 * insert_entry:
 * @self: the cache.
 * @key: (not nullable) (transfer full): the place key of @forecast, adopted.
 * @forecast: (not nullable) (transfer full): the forecast, adopted.
 * @fetched_ms: its fetch time.
 *
 * Stores a forecast for a key not yet in the cache as the most recently used
 * one and evicts the surplus least recently used entries.
 *
 * Preconditions:
 *  - @self is a valid cache without an entry for @key; @key is
 *    wx_place_key() of the place of @forecast.
 * Postconditions:
 *  - the entry exists and is the tail of the queue; at most
 *    WX_CACHE_MAX_PLACES entries are held. The generation counter is NOT
 *    changed (load() does not make the cache dirty).
 * Thread affinity: the thread that owns the cache.
 * Ownership: @key and @forecast are adopted by the new entry.
 */
static void
insert_entry(WxCache *self, char *key, WxForecast *forecast, gint64 fetched_ms)
{
  Entry *e = g_new0(Entry, 1);
  e->key = key;
  e->forecast = forecast;
  e->fetched_ms = fetched_ms;
  g_hash_table_insert(self->by_key, e->key, e);
  g_queue_push_tail(&self->lru, e);
  e->lru_link = g_queue_peek_tail_link(&self->lru);
  while (g_hash_table_size(self->by_key) > WX_CACHE_MAX_PLACES)
    evict_oldest(self);
}

/**
 * clear_all:
 * @self: the cache.
 *
 * Removes every entry.
 *
 * Preconditions:
 *  - @self is a valid cache.
 * Postconditions:
 *  - the queue and table are empty; the generation counters are not changed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: all entries are freed (the queue is cleared first, so no entry's
 *   lru_link is used afterwards).
 */
static void
clear_all(WxCache *self)
{
  g_queue_clear(&self->lru);
  g_hash_table_remove_all(self->by_key);
}

/**
 * age_since:
 * @fetched_ms: fetch time, ms since the Unix epoch.
 *
 * Milliseconds elapsed according to the system clock, clamped to >= 0.
 *
 * Preconditions:
 *  - @fetched_ms is within [FETCHED_MIN_MS, FETCHED_MAX_MS) (put() and the
 *    loader reject other values), so the subtraction cannot overflow.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (reads the clock only).
 * Ownership: none (no pointers).
 *
 * Returns: now - @fetched_ms in ms, or 0 if that is negative.
 */
static gint64
age_since(gint64 fetched_ms)
{
  gint64 age = g_get_real_time() / 1000 - fetched_ms;
  return age > 0 ? age : 0;
}

/* Documented in wx-cache.h. */
gboolean
wx_cache_put(WxCache *self, WxForecast *forecast, gint64 fetched_at_ms)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  if (forecast == NULL || forecast->n_hours > WX_CACHE_MAX_HOURS ||
      forecast->n_quarters > WX_CACHE_MAX_QUARTERS || fetched_at_ms < FETCHED_MIN_MS ||
      fetched_at_ms >= FETCHED_MAX_MS)
    return FALSE;

  g_autofree char *key = wx_place_key(wx_forecast_get_place(forecast));
  Entry *e = g_hash_table_lookup(self->by_key, key);
  if (e != NULL) {
    WxForecast *old = e->forecast;
    e->forecast = wx_forecast_ref(forecast);
    e->fetched_ms = fetched_at_ms;
    wx_forecast_unref(old);
    touch(self, e);
  } else {
    insert_entry(self, g_steal_pointer(&key), wx_forecast_ref(forecast), fetched_at_ms);
  }
  self->gen++;
  return TRUE;
}

/* Documented in wx-cache.h. */
WxForecast *
wx_cache_get(WxCache *self, const char *key, gint64 *age_ms)
{
  g_return_val_if_fail(WX_IS_CACHE(self), NULL);
  Entry *e = find_entry(self, key);
  if (e == NULL)
    return NULL;
  touch(self, e);
  if (age_ms != NULL)
    *age_ms = age_since(e->fetched_ms);
  return wx_forecast_ref(e->forecast);
}

/* Documented in wx-cache.h. */
gboolean
wx_cache_remove(WxCache *self, const char *key)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  Entry *e = find_entry(self, key);
  if (e == NULL)
    return FALSE;
  g_queue_delete_link(&self->lru, e->lru_link);
  g_hash_table_remove(self->by_key, e->key); /* frees e */
  self->gen++;
  return TRUE;
}

/* Documented in wx-cache.h. */
gboolean
wx_cache_is_dirty(WxCache *self)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  return self->gen != self->saved_gen;
}

/* ------------------------------------------------------------------------ */
/* Snapshot and serialisation                                               */
/* ------------------------------------------------------------------------ */

/* A private, immutable view of the cache for one save; shared with the worker. */
typedef struct {
  guint64 gen;
  GPtrArray *entries; /* Entry* (key NULL, lru_link NULL), least recently used first */
} Snapshot;

/**
 * snapshot_free:
 * @snap: (not nullable): a snapshot from snapshot_take().
 *
 * Preconditions:
 *  - @snap was returned by snapshot_take() and is freed once (g_autoptr()
 *    never passes NULL).
 * Postconditions:
 *  - the entries (one forecast reference each) and the snapshot are released.
 * Thread affinity: any thread.
 * Ownership: consumes @snap.
 */
static void
snapshot_free(Snapshot *snap)
{
  g_ptr_array_unref(snap->entries);
  g_free(snap);
}

G_DEFINE_AUTOPTR_CLEANUP_FUNC(Snapshot, snapshot_free)

/**
 * snapshot_take:
 * @self: the cache.
 *
 * Captures the entries in recency order (least recently used first), one new
 * reference per forecast; the forecasts are immutable, so nothing is copied.
 *
 * Preconditions:
 *  - @self is a valid cache owned by the calling thread.
 * Postconditions:
 *  - the cache is unchanged; the snapshot holds the current generation.
 * Thread affinity: the thread that owns the cache.
 * Ownership: the caller owns the snapshot.
 *
 * Returns: (transfer full): the snapshot.
 */
static Snapshot *
snapshot_take(WxCache *self)
{
  Snapshot *snap = g_new0(Snapshot, 1);
  snap->gen = self->gen;
  snap->entries = g_ptr_array_new_full(g_queue_get_length(&self->lru), entry_free);
  for (GList *l = self->lru.head; l != NULL; l = l->next) {
    const Entry *src = l->data;
    Entry *e = g_new0(Entry, 1);
    e->forecast = wx_forecast_ref(src->forecast);
    e->fetched_ms = src->fetched_ms;
    g_ptr_array_add(snap->entries, e);
  }
  return snap;
}

/* A double member of a struct and its JSON key (hours and days share the code). */
typedef struct {
  const char *key;
  gsize offset;
} DoubleField;

static const DoubleField hour_fields[] = {
    {"temp", offsetof(WxBlendHour, temp_c)},
    {"feels", offsetof(WxBlendHour, feels_c)},
    {"precip", offsetof(WxBlendHour, precip_mm)},
    {"precip_max", offsetof(WxBlendHour, precip_mm_max)},
    {"prob", offsetof(WxBlendHour, precip_prob)},
    {"cloud", offsetof(WxBlendHour, cloud_pct)},
    {"wind", offsetof(WxBlendHour, wind_kmh)},
    {"gust", offsetof(WxBlendHour, gust_kmh)},
    {"humidity", offsetof(WxBlendHour, humidity_pct)},
    {"spread", offsetof(WxBlendHour, temp_spread_c)},
};

static const DoubleField day_fields[] = {
    {"tmax", offsetof(WxDay, temp_max_c)},
    {"tmin", offsetof(WxDay, temp_min_c)},
    {"precip", offsetof(WxDay, precip_mm)},
    {"prob", offsetof(WxDay, precip_prob_max)},
    {"cloud", offsetof(WxDay, cloud_pct)},
};

/**
 * append_fields:
 * @out: the document being built.
 * @base: (not nullable): the struct holding the doubles.
 * @fields: (array length=n): the members to write.
 * @n: number of @fields.
 *
 * Appends ,"key":number for every field (null for a non-finite value).
 *
 * Preconditions:
 *  - @out is a valid #GString not used by another thread meanwhile; every
 *    offset of @fields is that of a double inside the struct @base points to.
 * Postconditions:
 *  - the members have been appended; @base is not modified.
 * Thread affinity: any thread (touches only @out).
 * Ownership: all pointers are borrowed for the call only.
 */
static void
append_fields(GString *out, const void *base, const DoubleField *fields, gsize n)
{
  for (gsize i = 0; i < n; i++) {
    g_string_append_printf(out, ",\"%s\":", fields[i].key);
    wx_json_append_double(out, G_STRUCT_MEMBER(double, base, fields[i].offset));
  }
}

/**
 * append_forecast:
 * @out: the document being built.
 * @f: (not nullable): the forecast.
 *
 * Appends the JSON object of one forecast (place, generation time and the
 * four arrays). Strings go through wx_json_append_string(), numbers through
 * wx_json_append_double(), so no control byte is ever written raw.
 *
 * Preconditions:
 *  - @out is a valid #GString not used by another thread meanwhile; @f is a
 *    live forecast.
 * Postconditions:
 *  - the object has been appended; @f is not modified.
 * Thread affinity: any thread (touches only @out and reads the immutable
 *   forecast).
 * Ownership: both pointers are borrowed for the call only.
 */
static void
append_forecast(GString *out, const WxForecast *f)
{
  g_string_append(out, "{\"place\":");
  wx_store_append_place(out, &f->place);
  g_string_append_printf(out, ",\"generated_s\":%" G_GINT64_FORMAT ",\"hours\":[", f->generated_s);
  for (guint i = 0; i < f->n_hours; i++) {
    const WxBlendHour *h = &f->hours[i];
    g_string_append_printf(out, "%s{\"t\":%" G_GINT64_FORMAT, i > 0 ? "," : "", h->t_s);
    append_fields(out, h, hour_fields, G_N_ELEMENTS(hour_fields));
    g_string_append_printf(out, ",\"members\":%u,\"cond\":%d,\"day\":%s}", (guint)h->n_members,
                           (int)h->condition, h->is_day ? "true" : "false");
  }
  g_string_append(out, "],\"quarters\":[");
  for (guint i = 0; i < f->n_quarters; i++) {
    g_string_append_printf(out, "%s[%" G_GINT64_FORMAT ",", i > 0 ? "," : "", f->quarters[i].t_s);
    wx_json_append_double(out, f->quarters[i].precip_mm);
    g_string_append_c(out, ']');
  }
  g_string_append(out, "],\"days\":[");
  for (guint i = 0; i < f->n_days; i++) {
    const WxDay *d = &f->days[i];
    g_string_append_printf(out, "%s{\"start\":%" G_GINT64_FORMAT, i > 0 ? "," : "", d->start_s);
    append_fields(out, d, day_fields, G_N_ELEMENTS(day_fields));
    g_string_append_printf(out, ",\"cond\":%d}", (int)d->condition);
  }
  g_string_append(out, "],\"sources\":[");
  for (guint i = 0; i < f->n_sources; i++) {
    const WxSourceStatus *s = &f->sources[i];
    g_string_append(out, i > 0 ? ",{\"id\":" : "{\"id\":");
    wx_json_append_string(out, s->provider_id);
    g_string_append(out, ",\"name\":");
    wx_json_append_string(out, s->name);
    g_string_append(out, ",\"attribution\":");
    wx_json_append_string(out, s->attribution);
    g_string_append(out, ",\"url\":");
    wx_json_append_string(out, s->attribution_url);
    g_string_append_printf(out, ",\"state\":%d,\"error\":%d,\"members\":%u}", (int)s->state,
                           s->error_code, s->n_members);
  }
  g_string_append(out, "]}");
}

/**
 * snapshot_serialize:
 * @snap: the snapshot to write.
 * @len: (not nullable) (out): receives the document length in bytes.
 *
 * Serialises @snap in stored order. The size is below WX_CACHE_MAX_FILE_BYTES
 * for every snapshot the cache can produce: put() bounds the hours and
 * quarters of each forecast, the other arrays are bounded by the forecast
 * type, and there are at most WX_CACHE_MAX_PLACES entries (verified by the
 * unit tests with forecasts of maximal size and text).
 *
 * Preconditions:
 *  - @snap comes from snapshot_take() and is not modified meanwhile.
 * Postconditions:
 *  - no state is changed; *@len is the length of the returned text.
 * Thread affinity: any thread (touches only @snap and the result).
 * Ownership: @snap is borrowed; the caller owns the returned buffer.
 *
 * Returns: (transfer full): the NUL-terminated document; free with g_free().
 */
static char *
snapshot_serialize(const Snapshot *snap, gsize *len)
{
  GString *out = g_string_sized_new(512 + (gsize)snap->entries->len * 32768);
  g_string_append_printf(out, "{\"version\":%d,\"entries\":[", CACHE_VERSION);
  for (guint i = 0; i < snap->entries->len; i++) {
    const Entry *e = g_ptr_array_index(snap->entries, i);
    g_string_append_printf(out, "%s{\"fetched_at_ms\":%" G_GINT64_FORMAT ",\"forecast\":",
                           i > 0 ? "," : "", e->fetched_ms);
    append_forecast(out, e->forecast);
    g_string_append_c(out, '}');
  }
  g_string_append(out, "]}\n");
  *len = out->len;
  return g_string_free(out, FALSE);
}

/**
 * snapshot_write:
 * @snap: the snapshot to write.
 * @path: (not nullable): destination file.
 * @error: (nullable): return location for a #GError, may be NULL.
 *
 * Serialises @snap and stores it with wx_file_write_atomic().
 *
 * Preconditions:
 *  - @snap comes from snapshot_take() and is not modified meanwhile; @path is
 *    non-empty and NUL-terminated; @error is NULL or points to a NULL
 *    #GError pointer.
 * Postconditions:
 *  - on TRUE: the file at @path holds the document; on FALSE: @error (if
 *    non-NULL) is set and the previous file is intact; the temporary text
 *    buffer is freed either way.
 * Thread affinity: any thread (the save worker or the owner of the cache).
 * Ownership: @snap and @path are borrowed for the call only.
 *
 * Returns: TRUE if the file was replaced.
 */
static gboolean
snapshot_write(const Snapshot *snap, const char *path, GError **error)
{
  gsize len = 0;
  g_autofree char *text = snapshot_serialize(snap, &len);
  return wx_file_write_atomic(path, text, len, error);
}

/* ------------------------------------------------------------------------ */
/* Load                                                                     */
/* ------------------------------------------------------------------------ */

/**
 * read_fields:
 * @o: (not nullable): a JSON object.
 * @base: (not nullable) (out): the struct receiving the doubles.
 * @fields: (array length=n): the members to read.
 * @n: number of @fields.
 *
 * Reads every field as a finite number or null (NAN). A missing member or any
 * other type fails.
 *
 * Preconditions:
 *  - @o belongs to a live parser; every offset of @fields is that of a double
 *    inside the struct @base points to.
 * Postconditions:
 *  - on TRUE every field is written; on FALSE some may have been written.
 * Thread affinity: any thread.
 * Ownership: @o is borrowed.
 *
 * Returns: TRUE iff every field was read.
 */
static gboolean
read_fields(JsonObject *o, void *base, const DoubleField *fields, gsize n)
{
  for (gsize i = 0; i < n; i++) {
    double v;
    if (!wx_store_node_double(json_object_get_member(o, fields[i].key), TRUE, &v))
      return FALSE;
    G_STRUCT_MEMBER(double, base, fields[i].offset) = v;
  }
  return TRUE;
}

/**
 * read_int_member:
 * @o: (not nullable): a JSON object.
 * @key: (not nullable): member name.
 * @min: smallest accepted value.
 * @max: largest accepted value.
 * @out: (out): receives the value.
 *
 * Preconditions:
 *  - @o belongs to a live parser; @key is NUL-terminated; @min <= @max.
 * Postconditions:
 *  - on TRUE *@out is within [@min, @max]; on FALSE *@out is untouched.
 * Thread affinity: any thread.
 * Ownership: @o is borrowed.
 *
 * Returns: TRUE iff the member is an integer within the range.
 */
static gboolean
read_int_member(JsonObject *o, const char *key, gint64 min, gint64 max, gint64 *out)
{
  gint64 v;
  if (!wx_store_node_i64(json_object_get_member(o, key), &v) || v < min || v > max)
    return FALSE;
  *out = v;
  return TRUE;
}

/**
 * parse_hour:
 * @node: (nullable): one element of the "hours" array.
 * @h: (out): receives the hour.
 *
 * Preconditions:
 *  - @node is NULL or a node of a live parser; @h is non-NULL.
 * Postconditions:
 *  - on TRUE *@h is complete (range validation of the numbers is left to
 *    wx_forecast_new()); on FALSE its content is unspecified.
 * Thread affinity: any thread.
 * Ownership: @node is borrowed.
 *
 * Returns: TRUE iff every member is present with the right type and the
 *   member count and condition are in range.
 */
static gboolean
parse_hour(JsonNode *node, WxBlendHour *h)
{
  JsonObject *o = wx_store_node_object(node);
  gint64 t, members, cond;
  gboolean day;
  if (o == NULL || !read_int_member(o, "t", G_MININT64, G_MAXINT64, &t) ||
      !read_fields(o, h, hour_fields, G_N_ELEMENTS(hour_fields)) ||
      !read_int_member(o, "members", 0, G_MAXUINT8, &members) ||
      !read_int_member(o, "cond", 0, WX_COND_COUNT - 1, &cond) ||
      !wx_store_node_bool(json_object_get_member(o, "day"), &day))
    return FALSE;
  h->t_s = t;
  h->n_members = (guint8)members;
  h->condition = (WxCondition)cond;
  h->is_day = day;
  return TRUE;
}

/**
 * parse_quarter:
 * @node: (nullable): one element of the "quarters" array.
 * @q: (out): receives the quarter.
 *
 * Preconditions:
 *  - @node is NULL or a node of a live parser; @q is non-NULL.
 * Postconditions:
 *  - on TRUE *@q is complete; on FALSE its content is unspecified.
 * Thread affinity: any thread.
 * Ownership: @node is borrowed.
 *
 * Returns: TRUE iff @node is an array [t, mm] of an integer and a finite
 *   number.
 */
static gboolean
parse_quarter(JsonNode *node, WxQuarter *q)
{
  JsonArray *a = wx_store_node_array(node);
  double mm;
  gint64 t;
  if (a == NULL || json_array_get_length(a) != 2 ||
      !wx_store_node_i64(json_array_get_element(a, 0), &t) ||
      !wx_store_node_double(json_array_get_element(a, 1), FALSE, &mm))
    return FALSE;
  q->t_s = t;
  q->precip_mm = mm;
  return TRUE;
}

/**
 * parse_day:
 * @node: (nullable): one element of the "days" array.
 * @d: (out): receives the day.
 *
 * Preconditions:
 *  - @node is NULL or a node of a live parser; @d is non-NULL.
 * Postconditions:
 *  - on TRUE *@d is complete; on FALSE its content is unspecified.
 * Thread affinity: any thread.
 * Ownership: @node is borrowed.
 *
 * Returns: TRUE iff every member is present with the right type and the
 *   condition is in range.
 */
static gboolean
parse_day(JsonNode *node, WxDay *d)
{
  JsonObject *o = wx_store_node_object(node);
  gint64 start, cond;
  if (o == NULL || !read_int_member(o, "start", G_MININT64, G_MAXINT64, &start) ||
      !read_fields(o, d, day_fields, G_N_ELEMENTS(day_fields)) ||
      !read_int_member(o, "cond", 0, WX_COND_COUNT - 1, &cond))
    return FALSE;
  d->start_s = start;
  d->condition = (WxCondition)cond;
  return TRUE;
}

/**
 * source_clear:
 * @s: (not nullable): a status whose strings are g_malloc()ed or NULL.
 *
 * Preconditions:
 *  - @s was filled by parse_source() (or is zeroed).
 * Postconditions:
 *  - the four strings are freed and set to NULL.
 * Thread affinity: any thread.
 * Ownership: the strings are owned by @s; @s itself is not freed.
 */
static void
source_clear(WxSourceStatus *s)
{
  g_clear_pointer(&s->provider_id, g_free);
  g_clear_pointer(&s->name, g_free);
  g_clear_pointer(&s->attribution, g_free);
  g_clear_pointer(&s->attribution_url, g_free);
}

/**
 * parse_source:
 * @node: (nullable): one element of the "sources" array.
 * @s: (out): receives a status owning private copies of its strings.
 *
 * Reads the members only; the id, the https URL and the error code are
 * validated by wx_forecast_new().
 *
 * Preconditions:
 *  - @node is NULL or a node of a live parser; @s is zeroed.
 * Postconditions:
 *  - on TRUE the strings of *@s are owned by the caller (source_clear());
 *    on FALSE *@s owns nothing.
 * Thread affinity: any thread.
 * Ownership: @node is borrowed.
 *
 * Returns: TRUE iff every member is present with the right type and the state
 *   and the counters are in range.
 */
static gboolean
parse_source(JsonNode *node, WxSourceStatus *s)
{
  JsonObject *o = wx_store_node_object(node);
  if (o == NULL)
    return FALSE;
  const char *id = wx_store_node_string(json_object_get_member(o, "id"));
  const char *name = wx_store_node_string(json_object_get_member(o, "name"));
  const char *attr = wx_store_node_string(json_object_get_member(o, "attribution"));
  const char *url = wx_store_node_string(json_object_get_member(o, "url"));
  gint64 state, error, members;
  if (id == NULL || name == NULL || attr == NULL || url == NULL ||
      !read_int_member(o, "state", WX_SRC_OK, WX_SRC_SKIPPED, &state) ||
      !read_int_member(o, "error", -1, WX_ERROR_UNSUPPORTED, &error) ||
      !read_int_member(o, "members", 0, G_MAXUINT, &members))
    return FALSE;
  s->provider_id = g_strdup(id);
  s->name = g_strdup(name);
  s->attribution = g_strdup(attr);
  s->attribution_url = g_strdup(url);
  s->state = (WxSourceState)state;
  s->error_code = (int)error;
  s->n_members = (guint)members;
  return TRUE;
}

/**
 * forecast_from_json:
 * @fo: (not nullable): the "forecast" object of one entry.
 *
 * Builds a forecast from the stored object. Every element must be well-formed
 * and within the array limits; the series and the strings are then validated
 * by wx_forecast_new(), so an invalid forecast never reaches the cache.
 *
 * Preconditions:
 *  - @fo belongs to a live parser.
 * Postconditions:
 *  - nothing is modified; no GLib message is logged; temporary arrays are
 *    freed.
 * Thread affinity: any thread.
 * Ownership: @fo is borrowed; the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the forecast, or NULL if the object is
 *   malformed or invalid.
 */
static WxForecast *
forecast_from_json(JsonObject *fo)
{
  g_autoptr(WxPlace) place = wx_store_place_from_json(json_object_get_member(fo, "place"));
  JsonArray *ha = wx_store_node_array(json_object_get_member(fo, "hours"));
  JsonArray *qa = wx_store_node_array(json_object_get_member(fo, "quarters"));
  JsonArray *da = wx_store_node_array(json_object_get_member(fo, "days"));
  JsonArray *sa = wx_store_node_array(json_object_get_member(fo, "sources"));
  gint64 generated;
  if (place == NULL || ha == NULL || qa == NULL || da == NULL || sa == NULL ||
      !read_int_member(fo, "generated_s", G_MININT64, G_MAXINT64, &generated))
    return NULL;
  guint nh = json_array_get_length(ha), nq = json_array_get_length(qa);
  guint nd = json_array_get_length(da), ns = json_array_get_length(sa);
  if (nh > WX_CACHE_MAX_HOURS || nq > WX_CACHE_MAX_QUARTERS || nd > WX_FORECAST_MAX_DAYS ||
      ns > WX_FORECAST_MAX_SOURCES)
    return NULL;

  g_autofree WxBlendHour *hours = g_new0(WxBlendHour, nh);
  g_autofree WxQuarter *quarters = g_new0(WxQuarter, nq);
  g_autofree WxDay *days = g_new0(WxDay, nd);
  WxSourceStatus sources[WX_FORECAST_MAX_SOURCES];
  memset(sources, 0, sizeof sources);
  WxForecast *forecast = NULL;
  guint parsed_sources = 0;
  gboolean ok = TRUE;
  for (guint i = 0; ok && i < nh; i++)
    ok = parse_hour(json_array_get_element(ha, i), &hours[i]);
  for (guint i = 0; ok && i < nq; i++)
    ok = parse_quarter(json_array_get_element(qa, i), &quarters[i]);
  for (guint i = 0; ok && i < nd; i++)
    ok = parse_day(json_array_get_element(da, i), &days[i]);
  for (; ok && parsed_sources < ns; parsed_sources++)
    ok = parse_source(json_array_get_element(sa, parsed_sources), &sources[parsed_sources]);
  if (ok)
    forecast = wx_forecast_new(place, generated, hours, nh, quarters, nq, days, nd, sources, ns,
                               NULL);
  for (guint i = 0; i < parsed_sources; i++)
    source_clear(&sources[i]);
  return forecast;
}

/**
 * load_entry:
 * @self: the cache.
 * @seen: (inout): place keys accepted earlier in this load.
 * @node: (nullable): one element of the "entries" array.
 *
 * Adds the entry when it is well-formed and its place was not seen before;
 * otherwise skips it silently.
 *
 * Preconditions:
 *  - @self is a valid cache; @node is NULL or a node of a live parser.
 * Postconditions:
 *  - on success the entry is the most recently used one and its key is in
 *    @seen; otherwise nothing changed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @node is borrowed.
 */
static void
load_entry(WxCache *self, GHashTable *seen, JsonNode *node)
{
  JsonObject *o = wx_store_node_object(node);
  gint64 fetched;
  if (o == NULL || !read_int_member(o, "fetched_at_ms", FETCHED_MIN_MS, FETCHED_MAX_MS - 1, &fetched))
    return;
  JsonObject *fo = wx_store_node_object(json_object_get_member(o, "forecast"));
  if (fo == NULL)
    return;
  g_autoptr(WxForecast) forecast = forecast_from_json(fo);
  if (forecast == NULL)
    return;
  g_autofree char *key = wx_place_key(wx_forecast_get_place(forecast));
  if (g_hash_table_contains(seen, key))
    return;
  g_hash_table_add(seen, g_strdup(key));
  insert_entry(self, g_steal_pointer(&key), g_steal_pointer(&forecast), fetched);
}

/**
 * load_document:
 * @self: the cache; must be empty.
 * @root: (nullable): root node of the parsed document.
 * @error: (nullable): return location for a #GError, may be NULL.
 *
 * Fills @self from parsed JSON: checks the top-level object, the version and
 * the "entries" array and offers every element to load_entry().
 *
 * Preconditions:
 *  - @self is empty; @root is NULL or a node owned by a live parser; @error is
 *    NULL or points to a NULL #GError pointer.
 * Postconditions:
 *  - on TRUE: the valid entries are in the cache in file order (the file is
 *    least recently used first), at most WX_CACHE_MAX_PLACES of them (the
 *    surplus oldest ones were evicted as the load went on);
 *  - on FALSE: @error (if non-NULL) is set (WX_ERROR / WX_ERROR_PARSE) and
 *    nothing was added.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @root is borrowed; nothing is retained.
 *
 * Returns: TRUE if the document has the expected shape and version.
 */
static gboolean
load_document(WxCache *self, JsonNode *root, GError **error)
{
  JsonObject *obj = wx_store_root_object(root, "cache", CACHE_VERSION, error);
  if (obj == NULL)
    return FALSE;
  JsonArray *arr = wx_store_node_array(json_object_get_member(obj, "entries"));
  if (arr == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "cache: missing entries array");
    return FALSE;
  }

  /* Stored least recently used first. Every element is offered and
   * insert_entry() evicts the surplus least recently used entries, so that
   * invalid or duplicate elements never use up one of the slots. Duplicates
   * are recognised against @seen, which keeps every key accepted earlier in
   * this load even after its entry was evicted (one short string per array
   * element, so bounded by the file size cap): the first accepted occurrence
   * always wins. */
  g_autoptr(GHashTable) seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  guint n = json_array_get_length(arr);
  for (guint i = 0; i < n; i++)
    load_entry(self, seen, json_array_get_element(arr, i));
  return TRUE;
}

/* Documented in wx-cache.h. */
gboolean
wx_cache_load(WxCache *self, GError **error)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("cache"));
    return FALSE;
  }

  clear_all(self);
  g_autoptr(JsonParser) parser = NULL;
  gboolean ok = wx_store_load_json(self->path, WX_CACHE_MAX_FILE_BYTES, "cache", &parser, error) &&
                load_document(self, json_parser_get_root(parser), error);
  if (!ok)
    clear_all(self);
  self->saved_gen = self->gen;
  return ok;
}

/* ------------------------------------------------------------------------ */
/* Save                                                                     */
/* ------------------------------------------------------------------------ */

/* Documented in wx-cache.h. */
gboolean
wx_cache_save(WxCache *self, GError **error)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("cache"));
    return FALSE;
  }

  g_autoptr(Snapshot) snap = snapshot_take(self);
  if (!snapshot_write(snap, self->path, error))
    return FALSE;
  self->saved_gen = snap->gen;
  return TRUE;
}

/* Data of one asynchronous save; owned by the inner GTask as task data. */
typedef struct {
  Snapshot *snap;
  GTask *outer; /* the task handed to the caller, completed in save_done() */
} SaveJob;

/**
 * save_job_free:
 * @job: the job to free.
 *
 * GDestroyNotify of the inner task's data: frees the snapshot, drops the
 * reference on the outer task and frees the job.
 *
 * Preconditions:
 *  - @job was created by wx_cache_save_async() and is freed exactly once (by
 *    the inner GTask, after both save_worker() and save_done() are done with
 *    it).
 * Postconditions:
 *  - the snapshot, the job and the reference on the outer task are released.
 * Thread affinity: any thread (the inner task may be finalised on the worker
 *   or on the thread that ran save_done()).
 * Ownership: consumes @job and its snapshot; releases the outer task.
 */
static void
save_job_free(SaveJob *job)
{
  snapshot_free(job->snap);
  g_object_unref(job->outer);
  g_free(job);
}

/**
 * save_worker:
 * @task: the inner task.
 * @source: (type WxCache): the cache the task was created for.
 * @task_data: the SaveJob.
 * @cancellable: (nullable): unused; cancellation is read through @task.
 *
 * GTaskThreadFunc: serialises the private snapshot and writes it atomically
 * to the cache's path. Returns the cancellation error instead if the task was
 * cancelled before it started.
 *
 * Preconditions:
 *  - runs on a GTask worker thread; @source is kept alive by @task; its path
 *    is never modified after construction (so reading it here is race free);
 *    @task_data is the SaveJob that nothing else mutates meanwhile.
 * Postconditions:
 *  - @task is completed exactly once: TRUE, the cancellation error or the
 *    error of wx_file_write_atomic().
 * Thread affinity: worker thread only.
 * Ownership: @task_data stays owned by the task; the error from the write is
 *   handed to the task.
 */
static void
save_worker(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable)
{
  (void)cancellable;
  if (g_task_return_error_if_cancelled(task))
    return;
  const SaveJob *job = task_data;
  GError *error = NULL;
  if (snapshot_write(job->snap, WX_CACHE(source)->path, &error))
    g_task_return_boolean(task, TRUE);
  else
    g_task_return_error(task, error);
}

/**
 * save_done:
 * @source: (type WxCache): the cache.
 * @result: the finished inner task.
 * @user_data: unused.
 *
 * GAsyncReadyCallback of the inner task, run in the main context of the
 * thread that called wx_cache_save_async(): clears save_in_flight, marks the
 * cache saved as of the snapshot generation on success, and completes the
 * caller's outer task with the same outcome.
 *
 * Preconditions:
 *  - @source is the cache and @result its inner task, whose task data is the
 *    SaveJob; runs in the thread that owns the cache.
 * Postconditions:
 *  - save_in_flight is FALSE; on success saved_gen is the generation of the
 *    snapshot (the cache stays dirty if changed since); the outer task has
 *    been completed once.
 * Thread affinity: the thread that owns the cache (main thread).
 * Ownership: the error obtained from the inner task is handed to the outer
 *   task; nothing else is retained.
 */
static void
save_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)user_data;
  WxCache *self = WX_CACHE(source);
  GTask *inner = G_TASK(result);
  const SaveJob *job = g_task_get_task_data(inner);
  GTask *outer = job->outer;
  guint64 gen = job->snap->gen;

  GError *error = NULL;
  gboolean ok = g_task_propagate_boolean(inner, &error);
  self->save_in_flight = FALSE;
  if (ok) {
    self->saved_gen = gen;
    g_task_return_boolean(outer, TRUE);
  } else {
    g_task_return_error(outer, error);
  }
}

/* Documented in wx-cache.h. */
void
wx_cache_save_async(WxCache *self, GCancellable *cancellable, GAsyncReadyCallback callback,
                    gpointer user_data)
{
  g_return_if_fail(WX_IS_CACHE(self));

  GTask *outer = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(outer, &save_tag);
  /* A cancellation that arrives after the write started must not turn a
   * successful write into an error: only save_worker() honours it. */
  g_task_set_check_cancellable(outer, FALSE);
  if (self->save_in_flight) {
    g_task_return_error(outer, wx_store_pending_error("cache"));
    g_object_unref(outer);
    return;
  }

  self->save_in_flight = TRUE;
  SaveJob *job = g_new0(SaveJob, 1);
  job->snap = snapshot_take(self);
  job->outer = outer;
  GTask *inner = g_task_new(self, cancellable, save_done, NULL);
  g_task_set_check_cancellable(inner, FALSE);
  g_task_set_task_data(inner, job, (GDestroyNotify)save_job_free);
  g_task_run_in_thread(inner, save_worker);
  g_object_unref(inner);
}

/* Documented in wx-cache.h. */
gboolean
wx_cache_save_finish(WxCache *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_CACHE(self), FALSE);
  g_return_val_if_fail(g_task_is_valid(result, self), FALSE);
  g_return_val_if_fail(g_async_result_is_tagged(result, &save_tag), FALSE);
  return g_task_propagate_boolean(G_TASK(result), error);
}
