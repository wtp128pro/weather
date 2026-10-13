/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-cache.h - bounded on-disk cache of the latest blended WxForecast per
 * place, used to show stale data instantly and when offline.
 *
 * File: <cache>/weather/forecasts.json, schema
 *   {"version":1,"entries":[{"fetched_at_ms":N,"forecast":{
 *      "place":{..},"generated_s":N,"hours":[..],"quarters":[[t,mm],..],
 *      "days":[..],"sources":[..]}}]}
 * stored least recently used first. A number that is NAN is stored as null.
 *
 * Threading: a WxCache has no locking: at any moment it must be used by ONE
 * thread only, normally the main thread. Two exceptions exist:
 *  - the start-up load: the application calls wx_cache_load() on a GTask
 *    worker thread. That is correct only because nobody else touches the
 *    cache until the task has completed back on the main thread (the
 *    hand-off); the cache emits no signals;
 *  - the internals of wx_cache_save_async()'s worker, which touch only a
 *    private snapshot (the forecasts are shared with the cache through their
 *    atomic reference count and are immutable) and the immutable file path.
 * Every other function must be called from the thread that owns the cache.
 * wx_cache_load() and wx_cache_save() are SYNCHRONOUS file operations (load:
 * one bounded read plus JSON parsing; save: serialisation plus write + fsync)
 * and are meant for start-up, shutdown and tests. For saving while the UI
 * runs use wx_cache_save_async(), which serialises and writes on a worker
 * thread.
 * The cache never saves by itself. Debouncing is the caller's job: after
 * put()/remove() calls, schedule one save when wx_cache_is_dirty() is TRUE.
 * Before the process exits, keep the main loop running until the save_async
 * callback has fired: exiting in the middle of a write leaves a
 * "<path>.wx-tmp-XXXXXX" temporary file (megabytes), which the next
 * wx_cache_load() removes once it is older than a minute.
 */
#ifndef WX_CACHE_H
#define WX_CACHE_H

#include <gio/gio.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Maximum number of forecasts held; storing a new one evicts the least recently used. */
#define WX_CACHE_MAX_PLACES 50
/** Largest number of hourly entries of a forecast that put() accepts and load() keeps. */
#define WX_CACHE_MAX_HOURS 240
/** Largest number of 15-minute entries of a forecast that put() accepts and load() keeps. */
#define WX_CACHE_MAX_QUARTERS 96
/**
 * Largest cache file that load() accepts. A file written by this module is
 * always smaller: WX_CACHE_MAX_PLACES forecasts of the largest size that
 * put() accepts (WX_CACHE_MAX_HOURS hours, WX_CACHE_MAX_QUARTERS quarters,
 * WX_FORECAST_MAX_DAYS days, WX_FORECAST_MAX_SOURCES sources, every text at
 * its maximum length and fully escaped, every number at its longest form)
 * serialise to less than this (checked by the unit tests).
 */
#define WX_CACHE_MAX_FILE_BYTES (8 * 1024 * 1024)

#define WX_TYPE_CACHE (wx_cache_get_type())
/* Declared by G_DECLARE_FINAL_TYPE below (GLib gtype.h): the WxCache typedef, the WxCacheClass
 * struct, GType wx_cache_get_type(void) (defined by G_DEFINE_TYPE() in wx-cache.c, see
 * there), the static inline casts WX_CACHE() and WX_IS_CACHE(), and g_autoptr() support for
 * WxCache and WxCacheClass. WX_TYPE_CACHE above is hand-written. */
G_DECLARE_FINAL_TYPE(WxCache, wx_cache, WX, CACHE, GObject)

/**
 * wx_cache_new:
 * @path: (nullable): file used by load/save; NULL selects
 *   g_get_user_cache_dir()/weather/forecasts.json. Copied.
 *
 * Preconditions:
 *  - @path is NULL, or a non-empty NUL-terminated string (an empty string is
 *    a programmer error: critical, NULL returned).
 * Postconditions:
 *  - the cache is empty and clean; no file is read or created; the stored
 *    path is non-empty.
 * Thread affinity: any thread; the creating thread owns the cache until it is
 *   handed over.
 * Ownership: @path is borrowed and copied; the caller owns the returned cache.
 *
 * Returns: (transfer full) (nullable): a new empty, clean (not dirty) cache,
 *   or NULL if @path is the empty string. Nothing is read from disk until
 *   wx_cache_load() is called.
 */
WxCache *wx_cache_new(const char *path);

/**
 * wx_cache_get_path:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: the returned string is owned by @self and lives as long as it.
 *
 * Returns: (transfer none): the file path used by load/save.
 */
const char *wx_cache_get_path(WxCache *self);

/**
 * wx_cache_get_n_places:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, 0 returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: none (no pointers returned).
 *
 * Returns: the number of forecasts currently held (at most
 *   WX_CACHE_MAX_PLACES).
 */
guint wx_cache_get_n_places(WxCache *self);

/**
 * wx_cache_put:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @forecast: (nullable): the forecast to store, keyed by
 *   wx_place_key() of its place. It has at most WX_CACHE_MAX_HOURS hours and
 *   WX_CACHE_MAX_QUARTERS quarters. The cache takes a reference; forecasts
 *   are immutable, so nothing is copied.
 * @fetched_at_ms: when the data was fetched, milliseconds since the Unix
 *   epoch (UTC), within [WX_TIME_MIN_S * 1000, WX_TIME_MAX_S * 1000).
 *
 * Replaces the forecast stored for the same place key, makes the place the
 * most recently used one and marks the cache dirty. Storing a new key into a
 * full cache evicts the least recently used place.
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, FALSE returned); @forecast is
 *    NULL or a live forecast.
 * Postconditions:
 *  - on TRUE: the cache holds one reference on @forecast for its place key (a
 *    new one, unless that same forecast was already stored there: the count
 *    is then unchanged), the place is the most recently used one, the cache
 *    is dirty and at most WX_CACHE_MAX_PLACES places are held;
 *  - on FALSE: the cache and the reference count are unchanged.
 * Thread affinity: the thread that owns the cache (the forecast itself is
 *   reference-counted atomically and may be shared).
 * Ownership: the caller keeps its own reference on @forecast.
 *
 * Returns: TRUE if stored; FALSE, with the cache unchanged, if @forecast is
 *   NULL, exceeds the limits above or @fetched_at_ms is out of range.
 */
gboolean wx_cache_put(WxCache *self, WxForecast *forecast, gint64 fetched_at_ms);

/**
 * wx_cache_get:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @key: (nullable): a place key as built by wx_place_key(), compared byte for
 *   byte.
 * @age_ms: (out) (optional): receives the milliseconds elapsed since the
 *   stored fetch time according to the system clock, clamped to >= 0.
 *
 * Makes the place the most recently used one when a forecast is returned
 * (this does not mark the cache dirty).
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, NULL returned); @key is NULL,
 *    NUL-terminated, or has at least 24 readable bytes (at most 24 are read).
 * Postconditions:
 *  - on a non-NULL result: *@age_ms (if given) is set and the place is the
 *    most recently used one;
 *  - on NULL: *@age_ms and the cache are unchanged.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @key is borrowed; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): a new reference to the cached
 *   forecast (release with wx_forecast_unref()), or NULL if @key is NULL or
 *   has no forecast.
 */
WxForecast *wx_cache_get(WxCache *self, const char *key, gint64 *age_ms);

/**
 * wx_cache_remove:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @key: (nullable): a place key as built by wx_place_key().
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, FALSE returned); @key is NULL,
 *    NUL-terminated, or has at least 24 readable bytes.
 * Postconditions:
 *  - on TRUE: the forecast of @key is released, the cache is dirty;
 *  - on FALSE: the cache is unchanged.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: TRUE iff a forecast was removed.
 */
gboolean wx_cache_remove(WxCache *self, const char *key);

/**
 * wx_cache_is_dirty:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, FALSE returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the cache.
 * Ownership: none (no pointers).
 *
 * Returns: TRUE iff put() or remove() changed the cache since the last
 *   wx_cache_load() (successful or not) or successful save. A save started
 *   before the latest change does not clear the flag.
 */
gboolean wx_cache_is_dirty(WxCache *self);

/**
 * wx_cache_load:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @error: (nullable): return location for a #GError.
 *
 * Synchronously replaces the cache content with the file at
 * wx_cache_get_path(). Invalid parts are skipped individually: an entry whose
 * forecast is malformed in any element (a bad place, hour, quarter, day or
 * source, a non-ascending series, more hours or quarters than
 * WX_CACHE_MAX_HOURS / WX_CACHE_MAX_QUARTERS, a missing or out-of-range fetch
 * time) is dropped as a whole, the rest is kept in the stored recency order.
 * Numbers outside their valid range are normalised to NAN by
 * wx_forecast_new(), not rejected. A place key (wx_place_key()) that repeats
 * an EARLIER accepted entry is skipped as a duplicate even if that earlier
 * entry has been evicted meanwhile: the first accepted occurrence is the only
 * one that can load. If the file holds more than WX_CACHE_MAX_PLACES valid
 * entries the least recently used ones are ignored. Also removes stale
 * "<path>.wx-tmp-XXXXXX" temporary files (see wx_file_remove_stale_temps()).
 *
 * On any failure the cache is left EMPTY and @error is set:
 *  - G_FILE_ERROR / G_FILE_ERROR_NOENT: no file yet (normal on first run);
 *  - G_IO_ERROR / G_IO_ERROR_MESSAGE_TOO_LARGE: file larger than
 *    WX_CACHE_MAX_FILE_BYTES; other G_FILE_ERROR codes: I/O failure;
 *  - WX_ERROR / WX_ERROR_PARSE: not valid JSON, wrong shape, unsupported
 *    "version", or rejected by wx_json_check_strict() (comments,
 *    single-quoted strings or other non-RFC 8259 bytes, a "\u0000" escape, or
 *    nesting deeper than WX_JSON_MAX_DEPTH; checked before the JSON parser
 *    sees the data).
 * No GLib warning or critical is logged for any file content. Either way the
 * cache is clean (not dirty) afterwards.
 * Fails with G_IO_ERROR / G_IO_ERROR_PENDING (cache untouched) while an
 * asynchronous save is running.
 *
 * Known limit (not enforced): the file is bounded only by
 * WX_CACHE_MAX_FILE_BYTES (8 MiB), and json-glib builds a node tree for the
 * whole text before any entry is validated, so a hostile 8 MiB file of tiny
 * elements costs memory proportional to its element count for the duration of
 * the load, even though the cache itself stays within its limits. No further
 * cap is applied.
 *
 * Preconditions:
 *  - @self is a valid cache (else: critical, FALSE); @error is NULL or points
 *    to a NULL #GError pointer (else: critical, FALSE); the caller owns the
 *    cache (see the file header).
 * Postconditions:
 *  - on TRUE: the cache holds the valid entries within the limits and is
 *    clean;
 *  - on FALSE: @error (if non-NULL) is set; the cache is empty and clean,
 *    except in the PENDING case where it is untouched.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @error is filled for the caller; nothing is retained.
 *
 * Returns: TRUE if the file was loaded.
 */
gboolean wx_cache_load(WxCache *self, GError **error);

/**
 * wx_cache_save:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @error: (nullable): return location for a #GError.
 *
 * Synchronously writes the whole cache (in recency order, least recently used
 * first) with wx_file_write_atomic(): the old file stays intact on failure.
 * On success the cache becomes clean. Saves unconditionally, even when the
 * cache is already clean. Fails with G_IO_ERROR / G_IO_ERROR_PENDING if an
 * asynchronous save is running. Other errors are in the G_FILE_ERROR domain.
 *
 * Preconditions:
 *  - @self is a valid cache owned by the calling thread; @error is NULL or
 *    points to a NULL #GError pointer (else: critical, FALSE).
 * Postconditions:
 *  - on TRUE: the file holds the content of the cache as of the start of the
 *    call and the cache is clean;
 *  - on FALSE: @error (if non-NULL) is set; the dirty flag and the previous
 *    file are unchanged.
 * Thread affinity: the thread that owns the cache.
 * Ownership: @error is filled for the caller; nothing is retained.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_cache_save(WxCache *self, GError **error);

/**
 * wx_cache_save_async:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @cancellable: (nullable): cancelling before the worker starts writing makes
 *   the save fail with G_IO_ERROR_CANCELLED (nothing is written); once writing
 *   has started it runs to completion and is reported as a success even if
 *   cancellation arrives meanwhile.
 * @callback: (nullable) (scope async): invoked in the thread-default main
 *   context of the calling thread.
 * @user_data: passed to @callback.
 *
 * Takes a snapshot of the cache on the calling thread (cheap: forecasts are
 * reference-counted, not copied) and serialises + writes it on a worker
 * thread. Only one save may run at a time: if one is already running,
 * @callback receives G_IO_ERROR_PENDING (from the main loop, never
 * synchronously) and the dirty flag is untouched, so the caller should retry
 * later. Saves unconditionally, even when the cache is clean. On success the
 * dirty flag is cleared before @callback runs, unless put()/remove() changed
 * something after the snapshot was taken. The cache is kept alive until the
 * save finishes.
 *
 * Preconditions:
 *  - @self is a valid cache owned by the calling thread (else: critical,
 *    nothing happens and @callback is never called); the calling thread
 *    iterates a main context that will run @callback.
 * Postconditions:
 *  - exactly one call of @callback (if given) follows, from the main loop,
 *    with a result for wx_cache_save_finish().
 * Thread affinity: the thread that owns the cache.
 * Ownership: the snapshot holds one reference on each forecast; the task holds
 *   a reference on @self until the callback has run and the worker has let go
 *   of the task, so when the caller drops its own reference meanwhile the
 *   last reference may be released by the worker thread, which then finalises
 *   the cache (it owns no thread-affine resource; no signal is emitted);
 *   @cancellable is referenced by the task; @user_data is passed through
 *   untouched and stays owned by the caller.
 */
void wx_cache_save_async(WxCache *self, GCancellable *cancellable, GAsyncReadyCallback callback,
                         gpointer user_data);

/**
 * wx_cache_save_finish:
 * @self: (not nullable): the cache; must satisfy WX_IS_CACHE().
 * @result: (not nullable): the result passed to the callback of
 *   wx_cache_save_async().
 * @error: (nullable): return location for a #GError.
 *
 * Collects the outcome of wx_cache_save_async().
 *
 * Preconditions:
 *  - @self is a valid cache; @result was produced by wx_cache_save_async() on
 *    @self (else: critical, FALSE); call it once, in the callback.
 * Postconditions:
 *  - on FALSE after a runtime failure: @error (if non-NULL) is set
 *    (G_IO_ERROR / G_IO_ERROR_PENDING or _CANCELLED, or G_FILE_ERROR_*).
 * Thread affinity: the thread that runs the callback (the thread that called
 *   wx_cache_save_async()).
 * Ownership: @result stays owned by the caller (the async machinery); @error
 *   is filled for the caller.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_cache_save_finish(WxCache *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_CACHE_H */
