/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-app.c - WxApp: data ownership, refresh execution, persistence, the single wiring site. */
#include "wx-app.h"

#include <string.h>

#include "wx-cache.h"
#include "wx-metno.h"
#include "wx-nws.h"
#include "wx-openmeteo.h"
#include "wx-row.h"
#include "wx-scheduler.h"
#include "wx-settings.h"
#include "wx-text.h"
#include "wx-ui-resources.h"
#include "wx-window.h"

#define CSS_RESOURCE_PATH "/io/github/wtp128pro/Weather/ui/style.css"

/* One in-flight forecast request. Ownership: it is allocated by run_action() and belongs to the
 * completion callback of its operation (refresh_done()), which frees it exactly once with
 * request_free() (directly, or through finish_request()). WxApp.requests only indexes it by id
 * while it is in flight and never frees it: wx_app_dispose() empties the table (after cancelling
 * every request) before any completion can see the application as gone, so a Request that is
 * freed is never indexed. Its GWeakRef keeps it from holding the application alive. */
typedef struct {
  GWeakRef app; /* weak: a pending request must never keep the application alive */
  guint64 id;
  GCancellable *cancellable;
  char key[WX_SCHED_KEY_BYTES];
} Request;

/* run_action() copies the scheduler's key with g_strlcpy() into Request.key; the copy is whole
 * because the scheduler's key is NUL-terminated within WX_SCHED_KEY_BYTES bytes and the
 * destination is at least that large. */
G_STATIC_ASSERT(sizeof(((Request *)NULL)->key) >= WX_SCHED_KEY_BYTES);

/* The three files the application writes. */
typedef enum { SAVE_PLACES, SAVE_SETTINGS, SAVE_CACHE, N_SAVE_KINDS } SaveKind;

/* One in-flight save. Ownership: it is allocated by start_saves() and belongs to the completion
 * callback save_done(), which frees it. Its GWeakRef keeps it from holding the application alive. */
typedef struct {
  GWeakRef app;
  SaveKind kind;
} SaveJob;

/* What the application remembers about one place besides its item. */
typedef struct {
  WxRowItem *item;       /* strong */
  gint64 next_forced_us; /* monotonic: no forced refresh of the place starts before this time */
  gboolean refetch;      /* a forced refresh was asked for and has not started yet */
  gint64 cool_until_us;  /* monotonic; 0, or the place is out of the scheduler until then and
                          * until release_cooled() puts it back (RATE_LIMITED cool-down) */
} Entry;

struct _WxApp {
  GtkApplication parent_instance;

  WxRegistry *registry;
  WxService *service;
  WxPlaces *places;
  WxSettings *settings;
  WxCache *cache;

  GListStore *items;     /* WxRowItem, places order */
  GHashTable *by_key;    /* char* (owned) -> Entry* (owned), one per place */
  WxScheduler *sched;
  GHashTable *requests;  /* guint64* (== &Request.id) -> Request*, in flight; does not own: a
                          * Request belongs to the callback of its operation */
  guint wake_id;         /* the single timer, 0 = none: the scheduler's next wakeup, the time a pending
                          * forced refresh may start or the end of a RATE_LIMITED cool-down, the
                          * earliest of them */
  gint64 wake_us;        /* the deadline wake_id was armed for */
  guint clock_id;        /* the display clock, 0 = none (window hidden or network unavailable) */

  GNetworkMonitor *netmon;
  gulong netmon_id;
  gboolean offline;
  gboolean visible;      /* what the window last reported */
  WxUnits units;

  gboolean loading;          /* the start-up load task is running */
  gboolean loaded;
  gboolean activate_pending; /* activate arrived before the load finished */
  gboolean shutting_down;
  gulong places_changed_id;

  char *sel_key;

  guint save_id;
  gboolean saving[N_SAVE_KINDS]; /* a save of that file is in flight */

  GMainLoop *drain_loop;
  guint drain_id;
};

/*
 * G_DEFINE_FINAL_TYPE() defines: wx_app_get_type(), the static wx_app_parent_class pointer and
 * the static class initialiser that runs wx_app_class_init() once; wx_app_init() is registered
 * as the instance initialiser; the instance struct is _WxApp above.
 */
G_DEFINE_FINAL_TYPE(WxApp, wx_app, GTK_TYPE_APPLICATION)

enum { PROP_0, PROP_REGISTRY, PROP_OFFLINE, PROP_UNITS, N_PROPS };

/**
 * sched_now:
 *
 * Reads both clocks for a scheduler call.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (reads the clocks only); called on the main thread.
 * Ownership: none (no pointers).
 *
 * Returns: the monotonic time in microseconds and the wall time in milliseconds since the Unix
 *   epoch.
 */
static WxSchedTime
sched_now(void)
{
  WxSchedTime t = {g_get_monotonic_time(), g_get_real_time() / 1000};
  return t;
}

/**
 * now_s:
 *
 * Reads the wall clock.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: the current wall time, UTC unix seconds.
 */
static gint64
now_s(void)
{
  return g_get_real_time() / G_USEC_PER_SEC;
}

/**
 * entry_new:
 * @item: (transfer full): the item of a place.
 *
 * Creates the entry of a place: nothing pending, a forced refresh may start at once.
 *
 * Preconditions:
 *  - @item is a WxRowItem the caller owns a reference of.
 * Postconditions:
 *  - the entry holds that reference; next_forced_us and cool_until_us are 0 and refetch is FALSE.
 * Thread affinity: main thread.
 * Ownership: consumes @item; the caller owns the returned entry (entry_free()).
 *
 * Returns: (transfer full): the entry.
 */
static Entry *
entry_new(WxRowItem *item)
{
  Entry *e = g_new0(Entry, 1);
  e->item = item;
  return e;
}

/**
 * entry_free:
 * @data: (transfer full): an Entry made by entry_new().
 *
 * GDestroyNotify of the key table: releases the item and frees the entry.
 *
 * Preconditions:
 *  - @data is an Entry from entry_new() that nothing refers to any more.
 * Postconditions:
 *  - the item reference is released and the entry freed.
 * Thread affinity: main thread.
 * Ownership: consumes @data.
 */
static void
entry_free(gpointer data)
{
  Entry *e = data;
  g_object_unref(e->item);
  g_free(e);
}

/**
 * lookup_entry:
 * @self: (not nullable): the application.
 * @key: (nullable): a place key, or NULL.
 *
 * Finds the entry of a place by its key.
 *
 * Preconditions:
 *  - @self is a valid application; @key is NULL or NUL-terminated (every caller passes a
 *    GLib-owned string, a Request.key that run_action() terminated, or the key given to
 *    wx_app_select()).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: @key is borrowed; the entry stays owned by @self.
 *
 * Returns: (transfer none) (nullable): the entry of that key, or NULL when @key is NULL or has
 *   no entry.
 */
static Entry *
lookup_entry(WxApp *self, const char *key)
{
  return key != NULL ? g_hash_table_lookup(self->by_key, key) : NULL;
}

/**
 * lookup_item:
 * @self: (not nullable): the application.
 * @key: (nullable): a place key, or NULL.
 *
 * Finds the item of a place by its key.
 *
 * Preconditions:
 *  - as lookup_entry().
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: @key is borrowed; the item stays owned by @self.
 *
 * Returns: (transfer none) (nullable): the item of that key, or NULL when @key is NULL or has
 *   no item.
 */
static WxRowItem *
lookup_item(WxApp *self, const char *key)
{
  Entry *e = lookup_entry(self, key);
  return e != NULL ? e->item : NULL;
}

/* ------------------------------------------------------------------------ */
/* The wiring site                                                          */
/* ------------------------------------------------------------------------ */

/**
 * add_provider:
 * @registry: (not nullable): the registry being built.
 * @provider: (transfer full): a provider to register (a failed constructor gives NULL, which is a
 *   programmer error here: every constructor below only fails for a constant that is wrong).
 *
 * Registers @provider and drops the local reference (the registry holds its own). A refusal
 * (invalid or duplicate id, registry full) is a programmer error too: every id below is constant,
 * distinct and valid, and there are fewer than WX_REGISTRY_MAX_PROVIDERS of them.
 *
 * Preconditions:
 *  - @registry satisfies WX_IS_REGISTRY(); @provider is NULL (critical, nothing is registered) or
 *    a WxProvider owned by the caller.
 * Postconditions:
 *  - the provider is registered last, enabled; @provider is released.
 * Thread affinity: main thread.
 * Ownership: consumes @provider.
 */
static void
add_provider(WxRegistry *registry, gpointer provider)
{
  g_return_if_fail(provider != NULL);
  g_autoptr(GObject) owned = provider;
  gboolean added = wx_registry_add_provider(registry, WX_PROVIDER(owned), NULL);
  g_warn_if_fail(added);
}

/**
 * build_default_registry:
 *
 * THE wiring site of the data sources: creates the registry of the production set. Adding a data
 * source to the application is one more add_provider() line here (plus its own directory); the
 * place search is the geocoder of the registry.
 *
 * Preconditions:
 *  - main thread.
 * Postconditions:
 *  - the registry holds, in this order, the National Weather Service, Open-Meteo and MET Norway
 *    (all enabled) and the Open-Meteo geocoder.
 * Thread affinity: main thread.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the registry.
 */
static WxRegistry *
build_default_registry(void)
{
  WxRegistry *registry = wx_registry_new();
  add_provider(registry, wx_nws_new(NULL));
  add_provider(registry, wx_open_meteo_new());
  add_provider(registry, wx_metno_new());
  g_autoptr(WxOpenMeteoGeocoder) geocoder = wx_open_meteo_geocoder_new();
  wx_registry_set_geocoder(registry, WX_GEOCODER(geocoder));
  return registry;
}

/* ------------------------------------------------------------------------ */
/* Persistence                                                              */
/* ------------------------------------------------------------------------ */

/**
 * pending_io:
 * @self: (not nullable): the application.
 *
 * Tells whether anything that the shutdown waits for is still pending.
 *
 * Preconditions:
 *  - @self is a valid application whose request table exists (between init and finalize).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none; @self is only read.
 *
 * Returns: TRUE while the start-up load, a save or a request is still pending.
 */
static gboolean
pending_io(WxApp *self)
{
  return self->loading || self->saving[SAVE_PLACES] || self->saving[SAVE_SETTINGS] ||
         self->saving[SAVE_CACHE] || g_hash_table_size(self->requests) > 0;
}

/**
 * drain_progress:
 * @self: (not nullable): the application.
 *
 * During the shutdown wait: leave the nested loop once nothing is pending.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - if the shutdown wait loop is running and pending_io() is FALSE, that loop has been asked to
 *    quit; otherwise nothing changes.
 * Thread affinity: main thread.
 * Ownership: none; the loop stays owned by wx_app_shutdown().
 */
static void
drain_progress(WxApp *self)
{
  if (self->drain_loop != NULL && !pending_io(self))
    g_main_loop_quit(self->drain_loop);
}

static void start_saves(WxApp *self);
static void schedule_save(WxApp *self);

/**
 * save_job_new:
 * @self: (not nullable): the application.
 * @kind: which file the save writes.
 *
 * An operation (forecast request, file save) can still be pending when the application goes away
 * after a forced shutdown (hung network or disk). Its user_data therefore holds no strong
 * reference to the application; the completion callback takes one only while it runs and, when
 * the application is gone, just releases what the operation itself owns.
 *
 * Preconditions:
 *  - @self is a valid application; @kind is a SaveKind.
 * Postconditions:
 *  - a weak reference to @self was created; @self's reference count is unchanged.
 * Thread affinity: main thread.
 * Ownership: @self is borrowed; the caller owns the returned job and passes it to save_done()
 *   (as the user_data of the save), which frees it.
 *
 * Returns: (transfer full): a heap-allocated job.
 */
static SaveJob *
save_job_new(WxApp *self, SaveKind kind)
{
  SaveJob *job = g_new(SaveJob, 1);
  g_weak_ref_init(&job->app, self);
  job->kind = kind;
  return job;
}

/**
 * save_name:
 * @kind: which file.
 *
 * Names a file for the log line of a failed save.
 *
 * Preconditions:
 *  - @kind is a SaveKind.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the string is static.
 *
 * Returns: (transfer none): "places", "settings" or "cache", for the log line of a failed save.
 */
static const char *
save_name(SaveKind kind)
{
  static const char *const names[N_SAVE_KINDS] = {"places", "settings", "cache"};
  return names[kind];
}

/**
 * is_dirty:
 * @self: (not nullable): the application.
 * @kind: which file.
 *
 * Tells whether the object behind a file has unsaved changes.
 *
 * Preconditions:
 *  - @self is a valid application whose places, settings and cache are not being loaded on the
 *    worker thread; @kind is a SaveKind.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none.
 *
 * Returns: whether that object has unsaved changes.
 */
static gboolean
is_dirty(WxApp *self, SaveKind kind)
{
  switch (kind) {
  case SAVE_PLACES:
    return wx_places_is_dirty(self->places);
  case SAVE_SETTINGS:
    return wx_settings_is_dirty(self->settings);
  case N_SAVE_KINDS:
  case SAVE_CACHE:
  default:
    return wx_cache_is_dirty(self->cache);
  }
}

/**
 * save_done:
 * @source: (not nullable): the WxPlaces, WxSettings or WxCache the save ran on (kept alive by the
 *   save task until this callback returns).
 * @result: (not nullable): the result of the save.
 * @user_data: (transfer full): the SaveJob made by save_job_new() in start_saves().
 *
 * GAsyncReadyCallback of every save: logs a failure, and when the application still exists,
 * clears the saving flag, re-arms a save if the object was edited while writing, and lets the
 * shutdown wait finish.
 *
 * Preconditions:
 *  - called once, on the main thread, by wx_places_save_async(), wx_settings_save_async() or
 *    wx_cache_save_async(); @user_data is the job that start_saves() passed (consumed here) and
 *    @source is the object of the job's kind.
 * Postconditions:
 *  - the job is freed. On a failed save the reason is logged with g_warning() ("unknown error"
 *    without a GError). If the application is gone nothing else happens; otherwise its saving flag
 *    of that kind is FALSE and, after a successful save of an object that was edited meanwhile, a
 *    new save is started (while shutting down) or scheduled (otherwise).
 * Thread affinity: main thread (the callback runs in the main context of the thread that
 *   started the save).
 * Ownership: the job in @user_data is consumed; @source and @result stay with the caller.
 */
static void
save_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  SaveJob *job = user_data;
  SaveKind kind = job->kind;
  g_autoptr(WxApp) self = g_weak_ref_get(&job->app);
  g_weak_ref_clear(&job->app);
  g_free(job);

  g_autoptr(GError) error = NULL;
  gboolean saved;
  switch (kind) {
  case SAVE_PLACES:
    saved = wx_places_save_finish(WX_PLACES(source), result, &error);
    break;
  case SAVE_SETTINGS:
    saved = wx_settings_save_finish(WX_SETTINGS(source), result, &error);
    break;
  case N_SAVE_KINDS:
  case SAVE_CACHE:
  default:
    saved = wx_cache_save_finish(WX_CACHE(source), result, &error);
  }
  if (!saved)
    g_warning("Could not save the %s: %s", save_name(kind),
              error != NULL ? error->message : "unknown error");
  if (self == NULL)
    return; /* the application is gone */
  self->saving[kind] = FALSE;
  if (saved && is_dirty(self, kind)) /* edited while writing */
    self->shutting_down ? start_saves(self) : schedule_save(self);
  drain_progress(self);
}

/**
 * start_saves:
 * @self: (not nullable): the application.
 *
 * Starts an asynchronous save of whatever is dirty and not already being saved.
 *
 * Preconditions:
 *  - @self is a valid application; its places, settings and cache are not being loaded on the
 *    worker thread (callers: save_timeout(), save_done() and wx_app_shutdown() only run after the
 *    load, which wx_app_shutdown() guarantees by testing "loaded").
 * Postconditions:
 *  - for each of the places, the settings and the cache that is dirty and has no save running:
 *    its saving flag is TRUE and one save was started whose callback owns a new job; nothing is
 *    started otherwise.
 * Thread affinity: main thread.
 * Ownership: each job passed as user_data is owned by save_done().
 */
static void
start_saves(WxApp *self)
{
  for (SaveKind kind = SAVE_PLACES; kind < N_SAVE_KINDS; kind++) {
    if (!is_dirty(self, kind) || self->saving[kind])
      continue;
    self->saving[kind] = TRUE;
    SaveJob *job = save_job_new(self, kind);
    switch (kind) {
    case SAVE_PLACES:
      wx_places_save_async(self->places, NULL, save_done, job);
      break;
    case SAVE_SETTINGS:
      wx_settings_save_async(self->settings, NULL, save_done, job);
      break;
    case N_SAVE_KINDS:
    case SAVE_CACHE:
    default:
      wx_cache_save_async(self->cache, NULL, save_done, job);
    }
  }
}

/**
 * save_timeout:
 * @user_data: (not nullable): the WxApp that armed the timer (borrowed raw pointer).
 *
 * GSourceFunc of the one-shot save debounce timer.
 *
 * Preconditions:
 *  - the source is alive only while @user_data is: wx_app_dispose() removes save_id before the
 *    application can be finalized, so the pointer cannot dangle.
 * Postconditions:
 *  - save_id is 0 and start_saves() ran; the source is removed.
 * Thread affinity: main thread (default main context).
 * Ownership: @user_data is borrowed.
 *
 * Returns: G_SOURCE_REMOVE always (one-shot).
 */
static gboolean
save_timeout(gpointer user_data)
{
  WxApp *self = WX_APP(user_data);
  self->save_id = 0;
  start_saves(self);
  return G_SOURCE_REMOVE;
}

/**
 * schedule_save:
 * @self: (not nullable): the application.
 *
 * Arms the one-shot save debounce timer unless it is armed or the application is shutting down.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - if save_id was 0 and the application is not shutting down: save_id is a live timer of
 *    WX_APP_SAVE_DELAY_MS that calls save_timeout() with @self; otherwise nothing changes.
 * Thread affinity: main thread.
 * Ownership: @self is passed to the timer as a borrowed pointer (see save_timeout()).
 */
static void
schedule_save(WxApp *self)
{
  if (self->save_id == 0 && !self->shutting_down)
    self->save_id = g_timeout_add(WX_APP_SAVE_DELAY_MS, save_timeout, self);
}

/* ------------------------------------------------------------------------ */
/* Items                                                                    */
/* ------------------------------------------------------------------------ */

/**
 * apply_cache:
 * @self: (not nullable): the application.
 * @item: (not nullable): an item of this application.
 *
 * Paints a new item from the cache: the cached forecast with the time it was fetched, when the
 * cache holds one.
 *
 * Preconditions:
 *  - @self and @item are valid; the cache is not being loaded on the worker.
 * Postconditions:
 *  - the item holds the cached forecast if any, with fetched time now minus the cache entry's
 *    age; the cache's recency order changed for a hit (it is not marked dirty).
 * Thread affinity: main thread.
 * Ownership: @item is borrowed; the reference taken from the cache is released.
 */
static void
apply_cache(WxApp *self, WxRowItem *item)
{
  gint64 age_ms = 0;
  g_autoptr(WxForecast) forecast = wx_cache_get(self->cache, wx_row_item_get_key(item), &age_ms);
  if (forecast != NULL)
    wx_row_item_set_forecast(item, forecast, now_s() - age_ms / 1000);
}

/**
 * store_key_at:
 * @store: (not nullable): the item store.
 * @position: index of an item of @store.
 *
 * Reads the key of an item of the store.
 *
 * Preconditions:
 *  - @position < the number of items of @store (the only caller, sync_items(), keeps every index
 *    below old_n).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the item stays owned by @store; the returned string is owned by that item.
 *
 * Returns: (transfer none): the key of the item at @position, valid while the item stays in the
 *   store.
 */
static const char *
store_key_at(GListStore *store, guint position)
{
  /* The store keeps the item alive, so the borrowed string outlives the unref. */
  g_autoptr(WxRowItem) item = g_list_model_get_item(G_LIST_MODEL(store), position);
  return wx_row_item_get_key(item);
}

/**
 * place_key_at:
 * @self: (not nullable): the application.
 * @index: index of a place of the list.
 *
 * Builds the key of a place of the list.
 *
 * Preconditions:
 *  - @index < wx_places_get_n_places() (the callers loop below the count).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): wx_place_key() of the place at @index.
 */
static char *
place_key_at(WxApp *self, guint index)
{
  return wx_place_key(wx_places_get_place(self->places, index));
}

/**
 * sync_items:
 * @self: (not nullable): the application.
 *
 * Brings the item model in line with the places: new places get an item (painted from the
 * cache), and the changed middle part of the list is replaced with one splice, so that unchanged
 * items (and a selection on them) survive moves, additions and removals elsewhere. The items and
 * cache entries of removed places are released.
 *
 * Preconditions:
 *  - @self is a valid application and the places are owned by the calling thread (the start-up
 *    load has finished); every place passes wx_place_new()'s rules (the list guarantees it), so
 *    wx_row_item_new() succeeds.
 *  - every index below is in range: places are read only for indices below the count n, store
 *    items only below the store size old_n; the unsigned differences n - prefix and old_n -
 *    prefix cannot wrap because prefix <= min(n, old_n) after the first loop, and n - 1 - suffix
 *    and old_n - 1 - suffix cannot wrap because suffix < min(n, old_n) - prefix at each use.
 * Postconditions:
 *  - the store holds one item per place in list order; the table by_key holds exactly the keys of
 *    the places (items of removed places are released from it and their forecasts leave the
 *    cache, which schedules a save); the store changed with at most one items-changed emission.
 * Thread affinity: main thread.
 * Ownership: items are owned by the entries of by_key (one reference each) and the store (one
 *   reference each).
 */
static void
sync_items(WxApp *self)
{
  guint n = wx_places_get_n_places(self->places);
  guint old_n = g_list_model_get_n_items(G_LIST_MODEL(self->items));
  g_autoptr(GPtrArray) keys = g_ptr_array_new_with_free_func(g_free);

  for (guint i = 0; i < n; i++) {
    char *key = place_key_at(self, i);
    g_ptr_array_add(keys, key);
    if (g_hash_table_contains(self->by_key, key))
      continue;
    WxRowItem *item = wx_row_item_new(wx_places_get_place(self->places, i));
    /* The list only holds places that passed wx_place_new()'s rules, the very rules that
     * wx_row_item_new() applies: it cannot fail. */
    g_return_if_fail(item != NULL);
    wx_row_item_set_units(item, self->units);
    wx_row_item_set_offline(item, self->offline);
    apply_cache(self, item);
    g_hash_table_insert(self->by_key, g_strdup(key), entry_new(item));
  }

  guint prefix = 0;
  while (prefix < n && prefix < old_n &&
         g_str_equal(g_ptr_array_index(keys, prefix), store_key_at(self->items, prefix)))
    prefix++;
  guint suffix = 0;
  while (suffix < n - prefix && suffix < old_n - prefix &&
         g_str_equal(g_ptr_array_index(keys, n - 1 - suffix),
                     store_key_at(self->items, old_n - 1 - suffix)))
    suffix++;

  guint n_removed = old_n - prefix - suffix;
  guint n_added = n - prefix - suffix;
  if (n_removed > 0 || n_added > 0) {
    gpointer *added = g_new(gpointer, n_added > 0 ? n_added : 1);
    for (guint i = 0; i < n_added; i++)
      added[i] = lookup_item(self, g_ptr_array_index(keys, prefix + i));
    g_list_store_splice(self->items, prefix, n_removed, added, n_added);
    g_free(added);
  }

  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init(&iter, self->by_key);
  while (g_hash_table_iter_next(&iter, &key, NULL)) {
    if (wx_places_index_of(self->places, key) < 0) {
      if (wx_cache_remove(self->cache, key))
        schedule_save(self);
      g_hash_table_iter_remove(&iter);
    }
  }
}

/* ------------------------------------------------------------------------ */
/* Scheduler glue                                                           */
/* ------------------------------------------------------------------------ */

static void pump_actions(WxApp *self);
static void serve_refetches(WxApp *self);
static void set_scheduler_places(WxApp *self, const char *const *skip, guint n_skip);
static void tick_items(WxApp *self);
static void sync_clock(WxApp *self);

/**
 * is_active:
 * @self: (not nullable): the application.
 *
 * Whether the application may do periodic or network work: the window is visible, the network
 * is available and the application is not shutting down. The scheduler's wake timer, the display
 * clock and forced refreshes all require it.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none.
 *
 * Returns: TRUE iff visible AND online AND not shutting down.
 */
static gboolean
is_active(WxApp *self)
{
  return self->visible && !self->offline && !self->shutting_down;
}

/**
 * hold:
 * @e: (not nullable): the entry of a place.
 * @until_us: a monotonic time, microseconds.
 *
 * Postpones the next forced refresh of the place to @until_us (never earlier than it already is).
 *
 * Preconditions:
 *  - @e is an entry of the application; @until_us is a monotonic time plus at most
 *    WX_APP_RATE_LIMIT_COOLDOWN_S seconds, so it cannot overflow.
 * Postconditions:
 *  - e->next_forced_us is the larger of its old value and @until_us.
 * Thread affinity: main thread.
 * Ownership: none.
 */
static void
hold(Entry *e, gint64 until_us)
{
  e->next_forced_us = MAX(e->next_forced_us, until_us);
}

/**
 * refetch_wake_us:
 * @self: (not nullable): the application.
 *
 * When the earliest pending forced refresh may start.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none.
 *
 * Returns: the monotonic time (microseconds) of the earliest of the next_forced_us of the places
 *   that have a pending refresh and are not loading (a loading place is served when its request
 *   completes) and the cool_until_us of the places that are cooling down; -1 when there is none
 *   or the application is not active. A value in the past means "due now".
 */
static gint64
refetch_wake_us(WxApp *self)
{
  if (!is_active(self))
    return -1;
  gint64 wake = -1;
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, self->by_key);
  while (g_hash_table_iter_next(&iter, NULL, &value)) {
    const Entry *e = value;
    if (e->refetch && !wx_row_item_get_loading(e->item) && (wake < 0 || e->next_forced_us < wake))
      wake = e->next_forced_us;
    if (e->cool_until_us != 0 && (wake < 0 || e->cool_until_us < wake))
      wake = e->cool_until_us;
  }
  return wake;
}

/**
 * request_free:
 * @r: (transfer full): a request that no longer is in the request table or whose table has been
 *   discarded.
 *
 * Frees a request that is no longer indexed.
 *
 * Preconditions:
 *  - @r was allocated by run_action() and is freed exactly once; nothing refers to it afterwards
 *    (finish_request() removes it from the table first).
 * Postconditions:
 *  - the weak reference is cleared, the cancellable released and @r freed.
 * Thread affinity: main thread.
 * Ownership: consumes @r.
 */
static void
request_free(Request *r)
{
  g_weak_ref_clear(&r->app);
  g_object_unref(r->cancellable);
  g_free(r);
}

/**
 * outcome:
 * @forecast: (nullable): the delivered forecast, NULL on failure.
 * @error: (nullable): the error of a failed operation, may be NULL.
 * @r: (not nullable): the request, only used for the log line.
 *
 * Maps an operation result to the scheduler's result. A failure is logged with g_debug().
 *
 * Preconditions:
 *  - @r is a live request whose key is NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: all pointers are borrowed.
 *
 * Returns: WX_SCHED_RESULT_OK if @forecast is set; WX_SCHED_RESULT_CANCELLED if @error is
 *   G_IO_ERROR_CANCELLED; otherwise WX_SCHED_RESULT_FAILED (also when @error is NULL; the log
 *   then says "unknown error").
 */
static WxSchedResult
outcome(const WxForecast *forecast, const GError *error, const Request *r)
{
  if (forecast != NULL)
    return WX_SCHED_RESULT_OK;
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    return WX_SCHED_RESULT_CANCELLED;
  g_debug("refresh %s failed: %s", r->key, error != NULL ? error->message : "unknown error");
  return WX_SCHED_RESULT_FAILED;
}

/**
 * finish_request:
 * @self: (not nullable): the application.
 * @r: (transfer full): the request that ended.
 * @result: how it ended.
 * @rate_limited: whether the failure was WX_ERROR_RATE_LIMITED (only read for a FAILED result).
 *
 * Ends request @r (taken): hands its result to the scheduler, clears the item's loading flag,
 * records the outcome on the item and frees @r. An OK result clears the item's stale flag, a
 * FAILED one sets it, a CANCELLED one leaves it as it is: the flag changes only here and only by
 * the outcome of a request of that place, never by a refresh being started or dropped. A
 * success holds back the next forced refresh for WX_APP_REFRESH_MIN_GAP_S seconds; a rate-limited
 * failure holds it back for WX_APP_RATE_LIMIT_COOLDOWN_S and also takes the place out of the
 * scheduler's set until then (see release_cooled()). The order is load-bearing: @r leaves the table
 * before the scheduler may start a new request, and the loading flag is cleared before that
 * request sets it again.
 *
 * Preconditions:
 *  - @self is a valid application; @r is a request that no one else frees (it is in the table,
 *    keyed by its id, unless wx_app_dispose() emptied the table meanwhile).
 * Postconditions:
 *  - @r is not in the table and is freed; the scheduler knows the request is done; its actions
 *    were executed, the pending forced refreshes served and the shutdown wait re-checked.
 * Thread affinity: main thread.
 * Ownership: consumes @r; @self is borrowed.
 */
static void
finish_request(WxApp *self, Request *r, WxSchedResult result, gboolean rate_limited)
{
  g_hash_table_remove(self->requests, &r->id);
  wx_scheduler_request_done(self->sched, sched_now(), r->id, result);
  Entry *e = lookup_entry(self, r->key);
  if (e != NULL) {
    wx_row_item_set_loading(e->item, FALSE);
    gint64 now_us = g_get_monotonic_time();
    if (result == WX_SCHED_RESULT_OK) {
      wx_row_item_set_stale(e->item, FALSE);
      hold(e, now_us + WX_APP_REFRESH_MIN_GAP_S * G_USEC_PER_SEC);
    } else if (result == WX_SCHED_RESULT_FAILED) {
      wx_row_item_set_stale(e->item, TRUE);
      if (rate_limited) {
        gint64 until_us = now_us + WX_APP_RATE_LIMIT_COOLDOWN_S * G_USEC_PER_SEC;
        hold(e, until_us);
        /* Out of the scheduler until the cool-down ends: none of its rounds may ask again. */
        e->cool_until_us = until_us;
        if (!self->shutting_down)
          set_scheduler_places(self, NULL, 0);
      }
    }
  }
  pump_actions(self);
  serve_refetches(self);
  drain_progress(self);
  request_free(r);
}

/**
 * apply_forecast:
 * @self: (not nullable): the application.
 * @r: (not nullable): the finished request.
 * @forecast: (not nullable): the forecast it delivered.
 *
 * Shows the forecast on its item (clearing the item's error text) and stores it in the cache.
 *
 * Preconditions:
 *  - @self, @r and @forecast are valid; the cache stores the forecast under the key of its own
 *    place, the item is looked up by @r->key.
 * Postconditions:
 *  - the item holds the forecast, fetched now, and no error text; if the cache accepts the forecast
 *    a save is scheduled. The item exists (see below); otherwise (programmer error: critical)
 *    nothing changes.
 * Thread affinity: main thread.
 * Ownership: all pointers are borrowed; the item and the cache take their own references.
 */
static void
apply_forecast(WxApp *self, const Request *r, WxForecast *forecast)
{
  WxRowItem *item = lookup_item(self, r->key);
  /* A removed place's request is cancelled, and a cancelled request never delivers a forecast
   * (wx_service_refresh_finish() reports G_IO_ERROR_CANCELLED then). */
  g_return_if_fail(item != NULL);
  /* A forecast that the cache refuses (a clock outside 2000..2100) is still shown. */
  if (wx_cache_put(self->cache, forecast, g_get_real_time() / 1000))
    schedule_save(self);
  wx_row_item_set_error(item, NULL);
  wx_row_item_set_forecast(item, forecast, now_s());
}

/**
 * refresh_done:
 * @source: (not nullable): the WxService that ran the request.
 * @result: (not nullable): the result of wx_service_refresh_async().
 * @user_data: (transfer full): the Request made by run_action().
 *
 * GAsyncReadyCallback of a forecast request. When the application still exists the result is
 * applied (unless shutting down: a failure's reason is still recorded) and the request is
 * finished; when it is gone (or disposed: wx_app_dispose() has already cancelled and unindexed
 * the request) only the request is released.
 *
 * Preconditions:
 *  - called once, on the main thread, by the service; @user_data is a Request that run_action()
 *    created for this operation and nothing else frees.
 * Postconditions:
 *  - the request is freed exactly once (through finish_request() or request_free()); the
 *    forecast, if any, is released. A failure other than cancellation leaves the sanitised
 *    reason on the item (the item keeps the forecast it had). When the application is gone
 *    nothing but the request is touched.
 * Thread affinity: main thread.
 * Ownership: @user_data is consumed; @source and @result stay with the caller; a strong
 *   reference on the application is held only while the callback runs.
 */
static void
refresh_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Request *r = user_data;
  g_autoptr(WxApp) self = g_weak_ref_get(&r->app);
  g_autoptr(GError) error = NULL;
  g_autoptr(WxForecast) forecast = wx_service_refresh_finish(WX_SERVICE(source), result, &error);
  WxSchedResult res = outcome(forecast, error, r);
  if (self == NULL) { /* the application is gone (forced shutdown): only release the request */
    request_free(r);
    return;
  }
  if (!self->shutting_down) {
    if (forecast != NULL) {
      apply_forecast(self, r, forecast);
    } else if (res == WX_SCHED_RESULT_FAILED) {
      WxRowItem *item = lookup_item(self, r->key);
      if (item != NULL)
        wx_row_item_set_error(item, error != NULL ? error->message : "unknown error");
    }
  }
  finish_request(self, r, res, res == WX_SCHED_RESULT_FAILED &&
                                   g_error_matches(error, WX_ERROR, WX_ERROR_RATE_LIMITED));
}

/**
 * run_action:
 * @self: (not nullable): the application.
 * @a: (not nullable): one action of the scheduler, valid for the call.
 *
 * Executes a scheduler action: a CANCEL cancels the request with that id, a FETCH starts the
 * request with the service (nothing while shutting down).
 *
 * Preconditions:
 *  - @self and @a are valid; for a FETCH, @a->key is NUL-terminated within WX_SCHED_KEY_BYTES
 *    bytes and @a->id is a fresh id (the scheduler starts at 1, only increments and never reuses
 *    an id), so the id is not in the request table yet and the table key &r->id stays unique and
 *    valid for as long as r is in the table.
 * Postconditions:
 *  - CANCEL: the cancellable of the request (if it is still in flight) was cancelled; a strong
 *    reference on it is held meanwhile because the cancellation may complete the operation
 *    synchronously and free the Request, which is not touched afterwards.
 *    FETCH: the key has an item (the scheduler tracks exactly the keys of the items) and the
 *    application is not shutting down (the scheduler is hidden then): a Request exists in the
 *    table, the item is loading and one service call is running; the key copy g_strlcpy()'d into
 *    the Request is not truncated (see the static assertion above). The completion callback owns
 *    the Request. Otherwise (programmer error: critical) nothing is started.
 * Thread affinity: main thread.
 * Ownership: @a is borrowed; the new Request is owned by the operation's completion callback,
 *   the table does not own it.
 */
static void
run_action(WxApp *self, const WxSchedAction *a)
{
  if (a->type == WX_SCHED_CANCEL) {
    g_debug("cancel #%" G_GUINT64_FORMAT, a->id);
    Request *r = g_hash_table_lookup(self->requests, &a->id);
    if (r != NULL) {
      /* Cancelling may complete the request synchronously and free it. */
      g_autoptr(GCancellable) cancellable = g_object_ref(r->cancellable);
      g_cancellable_cancel(cancellable);
    }
    return;
  }
  /* Neither can happen: a hidden scheduler (and the scheduler is hidden before the first step of
   * shutdown) starts nothing, and it tracks exactly the keys of the items. */
  g_return_if_fail(!self->shutting_down);
  Entry *e = lookup_entry(self, a->key);
  g_return_if_fail(e != NULL);

  Request *r = g_new0(Request, 1);
  g_weak_ref_init(&r->app, self);
  r->id = a->id;
  r->cancellable = g_cancellable_new();
  g_strlcpy(r->key, a->key, sizeof r->key);
  g_debug("request #%" G_GUINT64_FORMAT " %s", a->id, a->key);
  g_hash_table_insert(self->requests, &r->id, r);
  /* A request that starts now fetches with the current set of sources: nothing is pending. */
  e->refetch = FALSE;
  hold(e, g_get_monotonic_time() + WX_APP_REFRESH_MIN_GAP_S * G_USEC_PER_SEC);
  wx_row_item_set_loading(e->item, TRUE);
  wx_service_refresh_async(self->service, wx_row_item_get_place(e->item), r->cancellable,
                           refresh_done, r);
}

/**
 * wake_timeout:
 * @user_data: (not nullable): the WxApp that armed the timer (borrowed raw pointer).
 *
 * GSourceFunc of the single timer: the scheduler's wakeup, a forced refresh that was held back or
 * the end of a place's RATE_LIMITED cool-down became due.
 *
 * Preconditions:
 *  - the source is alive only while @user_data is: wx_app_dispose() (and wx_app_shutdown())
 *    remove wake_id before the application can be finalized.
 * Postconditions:
 *  - the source is removed: wake_id was set to 0 and wake_us to -1 first, so a deadline that
 *    remains (or arises) is armed again by a new timer (rearm_timer()). The scheduler was ticked (an
 *    early tick only re-evaluates its conditions) and its actions executed; while the application
 *    is active (see serve_refetches()) the places whose cool-down had ended were given back to the
 *    scheduler and the forced refreshes that are due were started.
 * Thread affinity: main thread (default main context).
 * Ownership: @user_data is borrowed.
 *
 * Returns: G_SOURCE_REMOVE always (a new timer is made by rearm_timer()).
 */
static gboolean
wake_timeout(gpointer user_data)
{
  WxApp *self = WX_APP(user_data);
  self->wake_id = 0;
  self->wake_us = -1;
  wx_scheduler_tick(self->sched, sched_now());
  pump_actions(self);
  serve_refetches(self);
  return G_SOURCE_REMOVE;
}

/**
 * rearm_timer:
 * @self: (not nullable): the application.
 *
 * Keeps exactly the timer that is needed: none, or one at the earliest of the scheduler's
 * deadline, the time a pending forced refresh may start and the end of a place's cool-down. All
 * of them are absent while the application is hidden or offline.
 *
 * Preconditions:
 *  - @self is a valid application. The scheduler derives every deadline from a
 *    g_get_monotonic_time() reading plus at most WX_SCHED_PERIOD_US, and a forced refresh is held
 *    back by at most WX_APP_RATE_LIMIT_COOLDOWN_S from such a reading, so the difference to the
 *    current monotonic time is small and "delay_us + 999" cannot overflow; the delay is clamped
 *    to G_MAXINT32 ms and is never negative before the unsigned cast.
 * Postconditions:
 *  - without a deadline no timer exists (wake_id 0, wake_us -1); with one there is exactly one
 *    timer armed for it (kept if it already was).
 * Thread affinity: main thread.
 * Ownership: the timer holds @self as a borrowed raw pointer (see wake_timeout()).
 */
static void
rearm_timer(WxApp *self)
{
  gint64 wake = wx_scheduler_next_wakeup_us(self->sched);
  gint64 refetch = refetch_wake_us(self);
  if (refetch >= 0 && (wake < 0 || refetch < wake))
    wake = refetch;
  if (wake < 0) {
    g_clear_handle_id(&self->wake_id, g_source_remove);
    self->wake_us = -1;
    return;
  }
  if (self->wake_id != 0 && self->wake_us == wake)
    return;
  g_clear_handle_id(&self->wake_id, g_source_remove);
  gint64 delay_us = wake - g_get_monotonic_time();
  gint64 delay_ms = delay_us <= 0 ? 0 : (delay_us + 999) / 1000;
  self->wake_us = wake;
  self->wake_id = g_timeout_add((guint)MIN(delay_ms, (gint64)G_MAXINT32), wake_timeout, self);
}

/**
 * pump_actions:
 * @self: (not nullable): the application.
 *
 * Executes the actions the scheduler has queued (repeatedly, until it has none: an action may
 * itself make the scheduler queue another) and re-arms the timer.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - every pending scheduler action was passed (as a copy) to run_action() in order, and the
 *    timer follows the earliest deadline (see rearm_timer(): the scheduler's wakeup, a held-back
 *    forced refresh, the end of a cool-down).
 * Thread affinity: main thread.
 * Ownership: the action arrays taken from the scheduler are released here.
 */
static void
pump_actions(WxApp *self)
{
  for (;;) {
    g_autoptr(GArray) actions = wx_scheduler_take_actions(self->sched);
    if (actions == NULL)
      break;
    for (guint i = 0; i < actions->len; i++) {
      WxSchedAction a = g_array_index(actions, WxSchedAction, i);
      run_action(self, &a);
    }
  }
  rearm_timer(self);
}

/**
 * set_scheduler_places:
 * @self: (not nullable): the application.
 * @skip: (nullable) (array length=n_skip): keys to leave out of the tracked set, or NULL.
 * @n_skip: number of elements of @skip.
 *
 * Feeds the keys of the items (in list order) to the scheduler, except @skip and the places that
 * are cooling down after a RATE_LIMITED failure (cool_until_us is not 0), and executes the
 * resulting actions.
 *
 * Preconditions:
 *  - @self is a valid application (the start-up load has finished); @skip is NULL or points to
 *    @n_skip NUL-terminated strings.
 * Postconditions:
 *  - the scheduler tracks the keys of the items in list order except @skip; the temporary array
 *    of borrowed key pointers is freed before the scheduler's actions are executed.
 * Thread affinity: main thread.
 * Ownership: the key pointers are borrowed from the items (and from @skip) for the call.
 */
static void
set_scheduler_places(WxApp *self, const char *const *skip, guint n_skip)
{
  guint n = g_list_model_get_n_items(G_LIST_MODEL(self->items));
  const char **keys = g_new(const char *, n > 0 ? n : 1);
  guint m = 0;
  for (guint i = 0; i < n; i++) {
    const char *key = store_key_at(self->items, i);
    const Entry *entry = lookup_entry(self, key);
    gboolean skipped = entry != NULL && entry->cool_until_us != 0; /* cooling down */
    for (guint j = 0; j < n_skip && !skipped; j++)
      skipped = strcmp(key, skip[j]) == 0;
    if (!skipped)
      keys[m++] = key;
  }
  wx_scheduler_set_places(self->sched, sched_now(), keys, m);
  g_free(keys);
  pump_actions(self);
}

/**
 * release_cooled:
 * @self: (not nullable): the application.
 *
 * Puts the places whose RATE_LIMITED cool-down has ended back into the scheduler's set. The
 * scheduler sees them as new places, so each is fetched once, at once (when the window is visible
 * and the network available: callers check is_active()).
 *
 * Preconditions:
 *  - @self is a valid application (the start-up load has finished) and is_active().
 * Postconditions:
 *  - cool_until_us is 0 for every place whose cool-down had ended; when there was one, the
 *    scheduler tracks every item that is not still cooling down and its actions were executed;
 *    otherwise nothing changed.
 * Thread affinity: main thread.
 * Ownership: none.
 */
static void
release_cooled(WxApp *self)
{
  gint64 now_us = g_get_monotonic_time();
  gboolean released = FALSE;
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, self->by_key);
  while (g_hash_table_iter_next(&iter, NULL, &value)) {
    Entry *e = value;
    if (e->cool_until_us != 0 && now_us >= e->cool_until_us) {
      e->cool_until_us = 0;
      released = TRUE;
    }
  }
  if (released)
    set_scheduler_places(self, NULL, 0);
}

/**
 * serve_refetches:
 * @self: (not nullable): the application.
 *
 * Starts the forced refreshes that are pending and allowed, then re-arms the timer. A pending
 * refresh (an entry's "refetch" flag: the Refresh button, or a change of the sources) is started
 * when the application is active, the place is not loading and its next_forced_us has passed;
 * otherwise it stays pending (one flag per place, however often it was asked for) and the timer
 * serves it when it becomes allowed. A started refresh makes the scheduler forget the place
 * (wx_scheduler_set_places() without it, then with it again), which makes it a new place that
 * is fetched at once whatever its age; the scheduler's memory of the place is not used by the
 * application (the stale mark lives on the item, see finish_request()).
 *
 * Preconditions:
 *  - @self is a valid application (the start-up load has finished).
 * Postconditions:
 *  - every cooled place whose cool-down had ended is tracked by the scheduler again; every place
 *    that had a pending refresh, was not loading and whose next_forced_us had passed has had its
 *    flag cleared and a request started (the scheduler tracks every item again, except the places
 *    that are cooling down); the other flags are unchanged; the timer follows the earliest
 *    deadline.
 * Thread affinity: main thread.
 * Ownership: none.
 */
static void
serve_refetches(WxApp *self)
{
  if (is_active(self)) {
    release_cooled(self);
    gint64 now_us = g_get_monotonic_time();
    g_autoptr(GPtrArray) ready = g_ptr_array_new_with_free_func(g_free);
    GHashTableIter iter;
    gpointer value;
    g_hash_table_iter_init(&iter, self->by_key);
    while (g_hash_table_iter_next(&iter, NULL, &value)) {
      Entry *e = value;
      if (e->refetch && !wx_row_item_get_loading(e->item) && now_us >= e->next_forced_us) {
        e->refetch = FALSE;
        g_ptr_array_add(ready, g_strdup(wx_row_item_get_key(e->item)));
      }
    }
    if (ready->len > 0) {
      set_scheduler_places(self, (const char *const *)ready->pdata, ready->len);
      set_scheduler_places(self, NULL, 0);
    }
  }
  rearm_timer(self);
}

/**
 * on_places_changed:
 * @self: (not nullable): the application (the swapped-signal instance).
 *
 * Handler of the places' "changed" signal (connected with g_signal_connect_swapped() after the
 * start-up load).
 *
 * Preconditions:
 *  - emitted on the main thread (the handler is connected only after the load has finished, so it
 *    never runs on the load worker); @self is alive: wx_app_dispose() disconnects the handler.
 * Postconditions:
 *  - the items and the scheduler follow the places, a selection on a place that is gone is
 *    dropped, and a save is scheduled.
 * Thread affinity: main thread.
 * Ownership: @self is borrowed.
 */
static void
on_places_changed(WxApp *self)
{
  sync_items(self);
  set_scheduler_places(self, NULL, 0);
  if (self->sel_key != NULL && lookup_item(self, self->sel_key) == NULL) {
    g_clear_pointer(&self->sel_key, g_free);
    wx_settings_set_selected(self->settings, NULL);
    wx_scheduler_set_selection(self->sched, sched_now(), NULL);
    pump_actions(self);
  }
  schedule_save(self);
}

/**
 * set_offline:
 * @self: (not nullable): the application.
 * @offline: the new network state.
 *
 * Records a change of the network state and applies it.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - when the state changes: every item knows it and was given the current time, the display
 *    clock exists iff the application is then active (visible and online), the "offline" property
 *    is notified, the scheduler told and its actions executed, and, when the network is back, the
 *    forced refreshes that were waiting are served; otherwise nothing happens.
 * Thread affinity: main thread.
 * Ownership: none (no pointers besides @self).
 */
static void
set_offline(WxApp *self, gboolean offline)
{
  if (self->offline == offline)
    return;
  self->offline = offline;
  for (guint i = 0, n = g_list_model_get_n_items(G_LIST_MODEL(self->items)); i < n; i++) {
    g_autoptr(WxRowItem) item = g_list_model_get_item(G_LIST_MODEL(self->items), i);
    wx_row_item_set_offline(item, offline);
  }
  tick_items(self);
  sync_clock(self);
  g_object_notify(G_OBJECT(self), "offline");
  wx_scheduler_set_online(self->sched, sched_now(), !offline);
  pump_actions(self);
  serve_refetches(self);
}

/**
 * on_network_changed:
 * @monitor: the network monitor (unused).
 * @available: the monitor's reported availability (the current value of its
 *   "network-available" property, as the signal documents).
 * @user_data: (not nullable): the WxApp the handler was connected for.
 *
 * Handler of the monitor's "network-changed" signal.
 *
 * Preconditions:
 *  - emitted on the main thread; @user_data is alive: wx_app_dispose() disconnects the handler.
 * Postconditions:
 *  - set_offline() was called with !@available.
 * Thread affinity: main thread.
 * Ownership: all pointers are borrowed.
 */
static void
on_network_changed(GNetworkMonitor *monitor, gboolean available, gpointer user_data)
{
  (void)monitor;
  set_offline(WX_APP(user_data), !available);
}

/**
 * tick_items:
 * @self: (not nullable): the application.
 *
 * Gives every item the current time, so the texts that depend on it (rain hint, current
 * conditions, "Updated N min ago") follow the clock.
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - every item's "now" is the current time (items whose "now" did not change emit nothing).
 * Thread affinity: main thread.
 * Ownership: none.
 */
static void
tick_items(WxApp *self)
{
  gint64 now = now_s();
  for (guint i = 0, n = g_list_model_get_n_items(G_LIST_MODEL(self->items)); i < n; i++) {
    g_autoptr(WxRowItem) item = g_list_model_get_item(G_LIST_MODEL(self->items), i);
    wx_row_item_set_now_s(item, now);
  }
}

/**
 * clock_timeout:
 * @user_data: (not nullable): the WxApp that armed the timer (borrowed raw pointer).
 *
 * GSourceFunc of the display clock.
 *
 * Preconditions:
 *  - the source is alive only while @user_data is: sync_clock() (called by
 *    wx_app_set_window_visible() and by set_offline(), when the application stops being active),
 *    wx_app_shutdown() and wx_app_dispose() remove clock_id before the application can be
 *    finalized.
 * Postconditions:
 *  - the items were given the current time; the source stays.
 * Thread affinity: main thread (default main context).
 * Ownership: @user_data is borrowed.
 *
 * Returns: G_SOURCE_CONTINUE always (it is removed by its owner).
 */
static gboolean
clock_timeout(gpointer user_data)
{
  tick_items(WX_APP(user_data));
  return G_SOURCE_CONTINUE;
}

/**
 * sync_clock:
 * @self: (not nullable): the application.
 *
 * Arms or removes the display clock so that it exists exactly while the application is active:
 * the window is visible AND the network is available (invariant "no periodic timer unless the
 * window is visible and the network available"). The clock only gives the items the time, so
 * what the window shows while it is not ticking is the state at the last tick (every change of
 * visibility or network state ticks the items once, see tick_items()).
 *
 * Preconditions:
 *  - @self is a valid application.
 * Postconditions:
 *  - clock_id is 0 iff !is_active(); otherwise it is the (single) live display clock source.
 * Thread affinity: main thread.
 * Ownership: the timer holds @self as a borrowed raw pointer (see clock_timeout()).
 */
static void
sync_clock(WxApp *self)
{
  if (!is_active(self))
    g_clear_handle_id(&self->clock_id, g_source_remove);
  else if (self->clock_id == 0)
    self->clock_id = g_timeout_add_seconds(WX_APP_CLOCK_TICK_S, clock_timeout, self);
}

/* ------------------------------------------------------------------------ */
/* Public API                                                               */
/* ------------------------------------------------------------------------ */

/* Documented in wx-app.h. */
WxApp *
wx_app_new(void)
{
  return g_object_new(WX_TYPE_APP, "application-id", WX_APP_ID, "flags", G_APPLICATION_FLAGS_NONE,
                      NULL);
}

/* Documented in wx-app.h. */
WxApp *
wx_app_new_with_registry(WxRegistry *registry)
{
  g_return_val_if_fail(WX_IS_REGISTRY(registry), NULL);
  return g_object_new(WX_TYPE_APP, "application-id", WX_APP_ID, "flags", G_APPLICATION_FLAGS_NONE,
                      "registry", registry, NULL);
}

/* Documented in wx-app.h. */
GListModel *
wx_app_get_items(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), NULL);
  return G_LIST_MODEL(self->items);
}

/* Documented in wx-app.h. */
WxPlaces *
wx_app_get_places(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), NULL);
  return self->places;
}

/* Documented in wx-app.h. */
WxRegistry *
wx_app_get_registry(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), NULL);
  return self->registry;
}

/* Documented in wx-app.h. */
WxService *
wx_app_get_service(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), NULL);
  return self->service;
}

/* Documented in wx-app.h. */
gboolean
wx_app_get_offline(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), FALSE);
  return self->offline;
}

/* Documented in wx-app.h. */
WxUnits
wx_app_get_units(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), WX_UNITS_IMPERIAL);
  return self->units;
}

/* Documented in wx-app.h. */
void
wx_app_set_units(WxApp *self, WxUnits units)
{
  g_return_if_fail(WX_IS_APP(self));
  g_return_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC);
  if (self->shutting_down || !self->loaded || self->units == units)
    return;
  self->units = units;
  wx_settings_set_units(self->settings, units);
  for (guint i = 0, n = g_list_model_get_n_items(G_LIST_MODEL(self->items)); i < n; i++) {
    g_autoptr(WxRowItem) item = g_list_model_get_item(G_LIST_MODEL(self->items), i);
    wx_row_item_set_units(item, units);
  }
  g_object_notify(G_OBJECT(self), "units");
  schedule_save(self);
}

/* Documented in wx-app.h. */
void
wx_app_set_window_visible(WxApp *self, gboolean visible)
{
  g_return_if_fail(WX_IS_APP(self));
  if (self->shutting_down)
    return;
  g_debug("window visible=%d", visible);
  gboolean changed = self->visible != !!visible;
  self->visible = !!visible;
  if (changed)
    tick_items(self);
  sync_clock(self);
  wx_scheduler_set_visible(self->sched, sched_now(), visible);
  pump_actions(self);
  serve_refetches(self);
}

/* Documented in wx-app.h. */
void
wx_app_window_focused(WxApp *self)
{
  g_return_if_fail(WX_IS_APP(self));
  if (self->shutting_down)
    return;
  g_debug("window focused");
  wx_scheduler_focus_regained(self->sched, sched_now());
  pump_actions(self);
}

/* Documented in wx-app.h. */
const char *
wx_app_get_selected(WxApp *self)
{
  g_return_val_if_fail(WX_IS_APP(self), NULL);
  return self->sel_key;
}

/* Documented in wx-app.h. */
void
wx_app_select(WxApp *self, const char *key)
{
  g_return_if_fail(WX_IS_APP(self));
  if (self->shutting_down || !self->loaded)
    return; /* the windows are being torn down: their signals no longer mean anything */

  WxRowItem *item = lookup_item(self, key);
  const char *new_key = item != NULL ? wx_row_item_get_key(item) : NULL;
  if (g_strcmp0(new_key, self->sel_key) == 0)
    return;
  g_free(self->sel_key);
  self->sel_key = g_strdup(new_key);
  g_debug("select %s", new_key != NULL ? new_key : "(none)");
  if (wx_settings_set_selected(self->settings, new_key))
    schedule_save(self);
  wx_scheduler_set_selection(self->sched, sched_now(), new_key);
  pump_actions(self);
}

/* Documented in wx-app.h. */
void
wx_app_refresh_selected(WxApp *self)
{
  g_return_if_fail(WX_IS_APP(self));
  if (self->sel_key == NULL || !self->loaded || !is_active(self))
    return;
  Entry *e = lookup_entry(self, self->sel_key);
  /* A place that is loading is about to be fresh, one that was started or succeeded a moment ago
   * or hit a rate limit is not asked again yet: the request is dropped, not queued. */
  if (e == NULL || wx_row_item_get_loading(e->item) ||
      g_get_monotonic_time() < e->next_forced_us)
    return;
  e->refetch = TRUE;
  serve_refetches(self);
}

/* Documented in wx-app.h. */
void
wx_app_set_provider_enabled(WxApp *self, const char *id, gboolean enabled)
{
  g_return_if_fail(WX_IS_APP(self));
  g_return_if_fail(id != NULL);
  if (self->shutting_down || !self->loaded)
    return;
  if (wx_registry_find_provider(self->registry, id) == NULL ||
      wx_registry_is_enabled(self->registry, id) == !!enabled)
    return;
  wx_registry_set_enabled(self->registry, id, enabled);
  wx_settings_set_provider_disabled(self->settings, id, !enabled);
  schedule_save(self);
  /* Every forecast was made with the old set of sources: each place is asked again, once however
   * many switches were flipped, as soon as it is allowed (see serve_refetches()). */
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, self->by_key);
  while (g_hash_table_iter_next(&iter, NULL, &value))
    ((Entry *)value)->refetch = TRUE;
  serve_refetches(self);
}

/* ------------------------------------------------------------------------ */
/* Start-up load (worker thread)                                            */
/* ------------------------------------------------------------------------ */

typedef struct {
  guint n_dropped;
  char *places_error;
  char *settings_error;
  char *cache_error;
} LoadResult;

/**
 * load_result_free:
 * @r: (transfer full): a LoadResult.
 *
 * GDestroyNotify of the load task's result.
 *
 * Preconditions:
 *  - @r is non-NULL and heap-allocated (g_new0()) with NULL or g_strdup()'d strings.
 * Postconditions:
 *  - the strings and @r are freed.
 * Thread affinity: the thread that releases the result (main thread, from load_done(); the task
 *   would release it on whichever thread drops the last reference).
 * Ownership: consumes @r.
 */
static void
load_result_free(LoadResult *r)
{
  g_free(r->places_error);
  g_free(r->settings_error);
  g_free(r->cache_error);
  g_free(r);
}

/**
 * load_thread:
 * @task: (not nullable): the load task.
 * @source: (not nullable): the WxApp the task was created for.
 * @task_data: unused (NULL).
 * @cancellable: unused (the task has none).
 *
 * Runs on a worker thread. The places, the settings and the cache are touched by nobody else
 * until the task has completed on the main thread, which is the hand-off that makes it correct
 * for these main-thread-owned objects. A missing file is not an error. The "changed" signals
 * emitted by the loads run on this thread; the application has no handler connected yet.
 *
 * Preconditions:
 *  - @source is the application, kept alive by the task; the places, settings and cache of
 *    @source exist and no other thread uses them (wx_app_startup() creates the task before any
 *    window exists and the shutdown path does not touch them while "loaded" is FALSE).
 * Postconditions:
 *  - the task returns a LoadResult with the number of dropped places and the message of any load
 *    error other than "file does not exist"; a failing load without a GError is reported as
 *    "unknown error".
 * Thread affinity: worker thread only (GTask thread pool).
 * Ownership: the LoadResult is handed to the task (destroy notify load_result_free()); @source,
 *   @task_data and @cancellable are borrowed.
 */
static void
load_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable)
{
  (void)task_data;
  (void)cancellable;
  WxApp *self = WX_APP(source);
  LoadResult *r = g_new0(LoadResult, 1);

  g_autoptr(GError) places_error = NULL;
  if (!wx_places_load(self->places, &r->n_dropped, &places_error) &&
      !g_error_matches(places_error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
    r->places_error = g_strdup(places_error != NULL ? places_error->message : "unknown error");

  g_autoptr(GError) settings_error = NULL;
  if (!wx_settings_load(self->settings, &settings_error) &&
      !g_error_matches(settings_error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
    r->settings_error =
        g_strdup(settings_error != NULL ? settings_error->message : "unknown error");

  g_autoptr(GError) cache_error = NULL;
  if (!wx_cache_load(self->cache, &cache_error) &&
      !g_error_matches(cache_error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
    r->cache_error = g_strdup(cache_error != NULL ? cache_error->message : "unknown error");

  g_task_return_pointer(task, r, (GDestroyNotify)load_result_free);
}

static void present_window(WxApp *self);

/**
 * apply_settings:
 * @self: (not nullable): the application.
 *
 * Applies the loaded settings: the unit system, and the enabled flag of every registered provider
 * (a provider listed as disabled is turned off in the registry).
 *
 * Preconditions:
 *  - @self is a valid application and the settings are no longer being loaded.
 * Postconditions:
 *  - self->units is the persisted unit system ("units" notified when it differs); every
 *    registered provider is enabled iff the settings do not list it as disabled.
 * Thread affinity: main thread.
 * Ownership: none.
 */
static void
apply_settings(WxApp *self)
{
  WxUnits units = wx_settings_get_units(self->settings);
  if (units != self->units) {
    self->units = units;
    g_object_notify(G_OBJECT(self), "units");
  }
  g_autoptr(GPtrArray) providers = wx_registry_list_providers(self->registry);
  for (guint i = 0; i < providers->len; i++) {
    const char *id = wx_provider_get_id(g_ptr_array_index(providers, i));
    wx_registry_set_enabled(self->registry, id, !wx_settings_is_provider_disabled(self->settings, id));
  }
}

/**
 * load_done:
 * @source: (not nullable): the WxApp that started the load.
 * @result: (not nullable): the finished GTask of load_thread().
 * @user_data: unused (NULL).
 *
 * GAsyncReadyCallback of the start-up load: logs what the load reported, hooks the application up
 * to the places, applies the settings, fills the items and the scheduler, restores the selection
 * and presents the window if activate already came; always drops the start-up hold.
 *
 * Preconditions:
 *  - called once, on the main thread, after load_thread() returned; the hold taken by
 *    wx_app_startup() is still in place.
 * Postconditions:
 *  - loading is FALSE; a missing result (NULL from the task) is treated like a load without
 *    messages. If the application is shutting down the shutdown wait is re-checked; otherwise
 *    loaded is TRUE, the "changed" handler is connected, the settings are applied, items and
 *    scheduler hold the places, the persisted selection is restored when its place still exists
 *    and the window is presented if activation was pending. The hold is released.
 * Thread affinity: main thread.
 * Ownership: the LoadResult obtained from the task is freed here; @source and @result stay with
 *   the caller.
 */
static void
load_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)user_data;
  WxApp *self = WX_APP(source);
  LoadResult *r = g_task_propagate_pointer(G_TASK(result), NULL);
  self->loading = FALSE;

  if (r != NULL) {
    if (r->places_error != NULL)
      g_warning("Could not read the saved places (starting empty): %s", r->places_error);
    if (r->n_dropped > 0)
      g_warning("%u invalid saved places were dropped", r->n_dropped);
    if (r->settings_error != NULL)
      g_warning("Could not read the settings (using defaults): %s", r->settings_error);
    if (r->cache_error != NULL)
      g_warning("Could not read the forecast cache (starting empty): %s", r->cache_error);
    load_result_free(r);
  }

  if (self->shutting_down) {
    drain_progress(self);
  } else {
    g_debug("loaded %u places", wx_places_get_n_places(self->places));
    self->loaded = TRUE;
    apply_settings(self);
    self->places_changed_id =
        g_signal_connect_swapped(self->places, "changed", G_CALLBACK(on_places_changed), self);
    sync_items(self);
    const char *selected = wx_settings_get_selected(self->settings);
    if (lookup_item(self, selected) != NULL) {
      self->sel_key = g_strdup(selected);
      wx_scheduler_set_selection(self->sched, sched_now(), self->sel_key);
    }
    set_scheduler_places(self, NULL, 0);
    if (self->activate_pending)
      present_window(self);
  }
  g_application_release(G_APPLICATION(self));
}

/* ------------------------------------------------------------------------ */
/* GApplication                                                             */
/* ------------------------------------------------------------------------ */

/**
 * install_css:
 *
 * Installs the compiled-in style sheet for the default display.
 *
 * Preconditions:
 *  - GTK is initialised and has a default display (called from wx_app_startup() after the parent
 *    startup, which opens it); the style sheet is compiled into the binary, so the lookup cannot
 *    fail. Either failing is a programmer error (critical: nothing is installed).
 * Postconditions:
 *  - the CSS provider is installed at application priority.
 * Thread affinity: main thread.
 * Ownership: the bytes and the provider are released here (the display holds its own reference
 *   on the provider).
 */
static void
install_css(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(GBytes) bytes = g_resource_lookup_data(wx_ui_get_resource(), CSS_RESOURCE_PATH,
                                                   G_RESOURCE_LOOKUP_FLAGS_NONE, &error);
  GdkDisplay *display = gdk_display_get_default();
  g_return_if_fail(bytes != NULL && display != NULL);
  g_autoptr(GtkCssProvider) provider = gtk_css_provider_new();
  gtk_css_provider_load_from_bytes(provider, bytes);
  gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                             GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/**
 * install_accels:
 * @self: (not nullable): the application.
 *
 * Registers the keyboard accelerators of the window's actions: Ctrl+N "win.add", F5 and Ctrl+R
 * "win.refresh", Ctrl+U "win.toggle-units".
 *
 * Preconditions:
 *  - @self is a valid application, past the parent startup.
 * Postconditions:
 *  - the accelerators are registered with GTK.
 * Thread affinity: main thread.
 * Ownership: none; GTK copies the strings.
 */
static void
install_accels(WxApp *self)
{
  GtkApplication *app = GTK_APPLICATION(self);
  gtk_application_set_accels_for_action(app, "win.add", (const char *[]){"<Control>n", NULL});
  gtk_application_set_accels_for_action(app, "win.refresh",
                                        (const char *[]){"F5", "<Control>r", NULL});
  gtk_application_set_accels_for_action(app, "win.toggle-units",
                                        (const char *[]){"<Control>u", NULL});
}

/**
 * wx_app_startup:
 * @application: (not nullable): the WxApp (GApplication::startup vfunc).
 *
 * Chains up, installs the CSS and the accelerators, hooks up the network monitor and starts the
 * load of the places, the settings and the cache on a worker thread, holding the application
 * until it finished.
 *
 * Preconditions:
 *  - called once by GApplication on the main thread, before activate.
 * Postconditions:
 *  - the network monitor is referenced and its handler connected; the scheduler knows the
 *    network state; loading is TRUE; the application is held (released by load_done()); one
 *    worker task owns the right to touch the places, the settings and the cache until
 *    load_done().
 * Thread affinity: main thread.
 * Ownership: the task holds its own reference on the application; the monitor reference is
 *   released in wx_app_dispose().
 */
static void
wx_app_startup(GApplication *application)
{
  WxApp *self = WX_APP(application);
  G_APPLICATION_CLASS(wx_app_parent_class)->startup(application);
  install_css();
  install_accels(self);

  self->netmon = g_object_ref(g_network_monitor_get_default());
  self->offline = !g_network_monitor_get_network_available(self->netmon);
  self->netmon_id =
      g_signal_connect(self->netmon, "network-changed", G_CALLBACK(on_network_changed), self);
  wx_scheduler_set_online(self->sched, sched_now(), !self->offline);

  /* Alive until the window exists (released in load_done). */
  g_application_hold(application);
  self->loading = TRUE;
  g_autoptr(GTask) task = g_task_new(self, NULL, load_done, NULL);
  g_task_run_in_thread(task, load_thread);
}

/**
 * present_window:
 * @self: (not nullable): the application.
 *
 * Shows the main window, creating it on first use.
 *
 * Preconditions:
 *  - @self is a valid application, loaded and not shutting down (callers: wx_app_activate() and
 *    load_done()).
 * Postconditions:
 *  - the active window (existing or new) was presented.
 * Thread affinity: main thread.
 * Ownership: a new window is owned by the application (GtkApplication tracks it); nothing is
 *   returned.
 */
static void
present_window(WxApp *self)
{
  GtkWindow *window = gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window == NULL)
    window = GTK_WINDOW(wx_window_new(self));
  gtk_window_present(window);
}

/**
 * wx_app_activate:
 * @application: (not nullable): the WxApp (GApplication::activate vfunc).
 *
 * Presents the window now if the load finished, otherwise as soon as it does.
 *
 * Preconditions:
 *  - called by GApplication on the main thread after startup.
 * Postconditions:
 *  - the window is presented when loaded; otherwise activate_pending is TRUE.
 * Thread affinity: main thread.
 * Ownership: none (no pointers besides @application).
 */
static void
wx_app_activate(GApplication *application)
{
  WxApp *self = WX_APP(application);
  if (self->loaded)
    present_window(self);
  else
    self->activate_pending = TRUE;
}

/**
 * drain_timeout:
 * @user_data: (not nullable): the WxApp that armed the timer (borrowed raw pointer).
 *
 * GSourceFunc of the shutdown wait limit.
 *
 * Preconditions:
 *  - the source is alive only while @user_data is and while the wait loop exists:
 *    wx_app_shutdown() removes drain_id right after the loop ran and wx_app_dispose() removes it
 *    too.
 * Postconditions:
 *  - drain_id is 0, a warning was logged and the wait loop was asked to quit; the source is
 *    removed.
 * Thread affinity: main thread (default main context).
 * Ownership: @user_data is borrowed.
 *
 * Returns: G_SOURCE_REMOVE always (one-shot).
 */
static gboolean
drain_timeout(gpointer user_data)
{
  WxApp *self = WX_APP(user_data);
  self->drain_id = 0;
  g_warning("Gave up waiting for pending saves/requests after %d ms", WX_APP_SHUTDOWN_WAIT_MS);
  g_main_loop_quit(self->drain_loop);
  return G_SOURCE_REMOVE;
}

/**
 * wx_app_shutdown:
 * @application: (not nullable): the WxApp (GApplication::shutdown vfunc).
 *
 * Cancels every request, lets the windows go, saves what is dirty and waits, in a nested main
 * loop of at most WX_APP_SHUTDOWN_WAIT_MS, for the start-up load, the saves and the cancelled
 * requests. Pending operations that have not finished by then are abandoned (they hold only weak
 * references).
 *
 * Preconditions:
 *  - called once by GApplication on the main thread after the main loop ended.
 * Postconditions:
 *  - shutting_down is TRUE, the save, refresh and clock timers are removed, the scheduler was
 *    told to hide; if loaded, saves of dirty data were started. On return nothing is pending or
 *    the wait limit elapsed (a warning was logged); the wait loop and its timer no longer exist.
 * Thread affinity: main thread.
 * Ownership: the wait loop is created and released here; the Requests and save jobs still
 *   pending belong to their callbacks.
 */
static void
wx_app_shutdown(GApplication *application)
{
  WxApp *self = WX_APP(application);
  self->shutting_down = TRUE;
  g_debug("shutdown: saving and waiting for %u request(s)", g_hash_table_size(self->requests));
  g_clear_handle_id(&self->save_id, g_source_remove);
  g_clear_handle_id(&self->clock_id, g_source_remove);

  /* Cancel everything in flight, then let the windows go. */
  wx_scheduler_set_visible(self->sched, sched_now(), FALSE);
  pump_actions(self);
  g_clear_handle_id(&self->wake_id, g_source_remove);
  G_APPLICATION_CLASS(wx_app_parent_class)->shutdown(application);

  if (self->loaded)
    start_saves(self);
  if (pending_io(self)) {
    self->drain_loop = g_main_loop_new(NULL, FALSE);
    self->drain_id = g_timeout_add(WX_APP_SHUTDOWN_WAIT_MS, drain_timeout, self);
    g_main_loop_run(self->drain_loop);
    g_clear_handle_id(&self->drain_id, g_source_remove);
    g_clear_pointer(&self->drain_loop, g_main_loop_unref);
  }
}

/**
 * wx_app_get_property:
 * @object: (not nullable): the WxApp.
 * @prop_id: the property id (PROP_OFFLINE or PROP_UNITS).
 * @value: (not nullable): the GValue to fill.
 * @pspec: (not nullable): the property's GParamSpec.
 *
 * GObject get_property vfunc.
 *
 * Preconditions:
 *  - called by GObject with @value initialised to the property's type.
 * Postconditions:
 *  - PROP_OFFLINE: @value holds the offline flag; PROP_UNITS: the unit system as an int; any
 *    other id logs the standard invalid-property warning and leaves @value untouched.
 * Thread affinity: main thread.
 * Ownership: all pointers are borrowed; @value is filled for the caller.
 */
static void
wx_app_get_property(GObject *object, guint prop_id, GValue *value, GParamSpec *pspec)
{
  WxApp *self = WX_APP(object);
  switch (prop_id) {
  case PROP_OFFLINE:
    g_value_set_boolean(value, self->offline);
    break;
  case PROP_UNITS:
    g_value_set_int(value, (int)self->units);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
  }
}

/**
 * wx_app_set_property:
 * @object: (not nullable): the WxApp.
 * @prop_id: the property id (PROP_REGISTRY is the only writable one).
 * @value: (not nullable): the GValue holding the new value.
 * @pspec: (not nullable): the property's GParamSpec.
 *
 * GObject set_property vfunc. The registry is a construct-only property.
 *
 * Preconditions:
 *  - called by GObject while the object is being constructed.
 * Postconditions:
 *  - PROP_REGISTRY: the application holds its own reference on the registry in @value (NULL
 *    keeps none, and wx_app_constructed() then builds the production registry); any other id
 *    logs the standard invalid-property warning.
 * Thread affinity: main thread.
 * Ownership: the registry reference is taken here and released in wx_app_finalize().
 */
static void
wx_app_set_property(GObject *object, guint prop_id, const GValue *value, GParamSpec *pspec)
{
  WxApp *self = WX_APP(object);
  switch (prop_id) {
  case PROP_REGISTRY:
    g_clear_object(&self->registry);
    self->registry = g_value_dup_object(value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID(object, prop_id, pspec);
  }
}

/**
 * wx_app_constructed:
 * @object: (not nullable): the WxApp (GObject constructed vfunc).
 *
 * Chains up, builds the production registry when none was given, and creates the service over
 * it.
 *
 * Preconditions:
 *  - called once by GObject after the construct properties were set.
 * Postconditions:
 *  - registry and service exist.
 * Thread affinity: main thread.
 * Ownership: the service reference is released in wx_app_finalize().
 */
static void
wx_app_constructed(GObject *object)
{
  WxApp *self = WX_APP(object);
  G_OBJECT_CLASS(wx_app_parent_class)->constructed(object);
  if (self->registry == NULL)
    self->registry = build_default_registry();
  self->service = wx_service_new(self->registry);
}

/**
 * abandon_requests:
 * @self: (not nullable): the application.
 *
 * Cancels every request in flight and removes all of them from the request table, so that no
 * later action can look one up and a request that completes afterwards (it belongs to its
 * completion callback, which only frees it once the application is gone) is never indexed.
 *
 * Preconditions:
 *  - @self is a valid application whose request table exists.
 * Postconditions:
 *  - the request table is empty and the cancellable of every request that was in it has been
 *    cancelled. A cancellation may complete a request synchronously, which frees it; the
 *    cancellables are therefore referenced and the table emptied before the first one is
 *    cancelled, and no Request is touched afterwards.
 * Thread affinity: main thread.
 * Ownership: the cancellables are referenced here and released before the function returns; the
 *   Requests stay with their callbacks.
 */
static void
abandon_requests(WxApp *self)
{
  g_autoptr(GPtrArray) cancellables = g_ptr_array_new_with_free_func(g_object_unref);
  GHashTableIter iter;
  gpointer value;
  g_hash_table_iter_init(&iter, self->requests);
  while (g_hash_table_iter_next(&iter, NULL, &value))
    g_ptr_array_add(cancellables, g_object_ref(((Request *)value)->cancellable));
  g_hash_table_remove_all(self->requests);
  for (guint i = 0; i < cancellables->len; i++)
    g_cancellable_cancel(g_ptr_array_index(cancellables, i));
}

/**
 * wx_app_dispose:
 * @object: (not nullable): the WxApp (GObject dispose vfunc).
 *
 * Neutralises the application: it is marked as shutting down (every later call of the public API
 * is a no-op, and a completion that still sees the application only records its outcome), every
 * source and signal handler that holds a raw pointer to it (save, refresh, clock and
 * shutdown-wait timers, the network and places handlers) is removed, the network monitor is
 * released, the scheduler is told the window is hidden and its actions are dropped, and every
 * request in flight is cancelled and removed from the request table (abandon_requests()), then it
 * chains up. The object itself, with its items and tables, stays usable by the code that still
 * holds a reference (a window being torn down) until it is finalized. It may run more than once,
 * and also runs through g_object_run_dispose(), which clears the GWeakRefs of the pending
 * operations while the object lives on.
 *
 * Preconditions:
 *  - called by GObject on the main thread. No completion callback of a pending operation can run
 *    during it except one that a cancellation completes synchronously (see abandon_requests()).
 * Postconditions:
 *  - shutting_down is TRUE; save_id, wake_id, clock_id and drain_id are 0, the handler ids are 0,
 *    netmon is NULL, the request table is empty and the scheduler tracks no request in the table.
 * Thread affinity: the thread that drops the last reference (main thread).
 * Ownership: the monitor reference is released; the handlers and sources are removed; the
 *   Requests stay with their callbacks.
 */
static void
wx_app_dispose(GObject *object)
{
  WxApp *self = WX_APP(object);
  self->shutting_down = TRUE;
  g_clear_handle_id(&self->save_id, g_source_remove);
  g_clear_handle_id(&self->wake_id, g_source_remove);
  g_clear_handle_id(&self->clock_id, g_source_remove);
  g_clear_handle_id(&self->drain_id, g_source_remove);
  if (self->netmon != NULL && self->netmon_id != 0)
    g_signal_handler_disconnect(self->netmon, self->netmon_id);
  self->netmon_id = 0;
  g_clear_object(&self->netmon);
  if (self->places != NULL && self->places_changed_id != 0)
    g_signal_handler_disconnect(self->places, self->places_changed_id);
  self->places_changed_id = 0;
  if (self->sched != NULL) {
    wx_scheduler_set_visible(self->sched, sched_now(), FALSE);
    GArray *dropped = wx_scheduler_take_actions(self->sched);
    g_clear_pointer(&dropped, g_array_unref);
  }
  if (self->requests != NULL)
    abandon_requests(self);
  G_OBJECT_CLASS(wx_app_parent_class)->dispose(object);
}

/**
 * wx_app_finalize:
 * @object: (not nullable): the WxApp (GObject finalize vfunc).
 *
 * Frees what the application owns and chains up.
 *
 * Preconditions:
 *  - called once by GObject after dispose; no timer or handler refers to the application any
 *    more (see wx_app_dispose()).
 * Postconditions:
 *  - the scheduler, the request table (without the Requests, which belong to their callbacks),
 *    the key table, the item store, the service, the registry, the places, the settings, the
 *    cache and the selected key are released.
 * Thread affinity: the thread that drops the last reference (main thread).
 * Ownership: everything the application owns is released.
 */
static void
wx_app_finalize(GObject *object)
{
  WxApp *self = WX_APP(object);
  g_clear_pointer(&self->sched, wx_scheduler_free);
  g_clear_pointer(&self->requests, g_hash_table_unref);
  g_clear_pointer(&self->by_key, g_hash_table_unref);
  g_clear_object(&self->items);
  g_clear_object(&self->service);
  g_clear_object(&self->registry);
  g_clear_object(&self->places);
  g_clear_object(&self->settings);
  g_clear_object(&self->cache);
  g_free(self->sel_key);
  G_OBJECT_CLASS(wx_app_parent_class)->finalize(object);
}

/**
 * wx_app_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * Installs the GApplication startup / activate / shutdown vfuncs, the GObject constructed /
 * get_property / set_property / dispose / finalize vfuncs, the construct-only "registry"
 * property and the read-only "offline" and "units" properties.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - the vfuncs and the properties are installed.
 * Thread affinity: the thread that first uses the type (GType serialises it).
 * Ownership: none (the class is owned by GType).
 */
static void
wx_app_class_init(WxAppClass *klass)
{
  GObjectClass *oc = G_OBJECT_CLASS(klass);
  GApplicationClass *ac = G_APPLICATION_CLASS(klass);
  oc->constructed = wx_app_constructed;
  oc->get_property = wx_app_get_property;
  oc->set_property = wx_app_set_property;
  oc->dispose = wx_app_dispose;
  oc->finalize = wx_app_finalize;
  ac->startup = wx_app_startup;
  ac->activate = wx_app_activate;
  ac->shutdown = wx_app_shutdown;
  g_object_class_install_property(
      oc, PROP_REGISTRY,
      g_param_spec_object("registry", NULL, NULL, WX_TYPE_REGISTRY,
                          G_PARAM_WRITABLE | G_PARAM_CONSTRUCT_ONLY | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property(
      oc, PROP_OFFLINE,
      g_param_spec_boolean("offline", NULL, NULL, FALSE,
                           G_PARAM_READABLE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY));
  g_object_class_install_property(
      oc, PROP_UNITS,
      g_param_spec_int("units", NULL, NULL, WX_UNITS_IMPERIAL, WX_UNITS_METRIC, WX_UNITS_IMPERIAL,
                       G_PARAM_READABLE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY));
}

/**
 * wx_app_init:
 * @self: (not nullable): the instance being initialised.
 *
 * Creates the places, the settings and the cache (default paths, nothing read), the item store,
 * the key table, the scheduler and the request table. The registry and the service are made by
 * wx_app_constructed(), after the construct properties are known.
 *
 * Preconditions:
 *  - @self is a zero-initialised new instance.
 * Postconditions:
 *  - all members above exist; no timer, handler or request exists; units are imperial, the
 *    selection is none and wake_us is -1.
 * Thread affinity: the thread that creates the instance (main thread).
 * Ownership: the instance owns everything created.
 */
static void
wx_app_init(WxApp *self)
{
  self->places = wx_places_new(NULL);
  self->settings = wx_settings_new(NULL);
  self->cache = wx_cache_new(NULL);
  self->items = g_list_store_new(WX_TYPE_ROW_ITEM);
  self->by_key = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, entry_free);
  self->sched = wx_scheduler_new();
  self->requests = g_hash_table_new(g_int64_hash, g_int64_equal);
  self->units = WX_UNITS_IMPERIAL;
  self->wake_us = -1;
}
