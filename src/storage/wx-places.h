/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-places.h - the user's ordered list of saved places, persisted as JSON.
 *
 * File: <config>/weather/places.json, schema
 *   {"version":1,"places":[{"name":..,"admin1":..,"country":..,
 *     "country_code":..,"lat":..,"lon":..,"timezone":..}]}
 * (admin1, country, country_code and timezone are optional when loading).
 *
 * Threading: a WxPlaces has no locking: at any moment it must be used by ONE
 * thread only, normally the main thread. Two exceptions exist:
 *  - the start-up load: the application calls wx_places_load() on a GTask
 *    worker thread. That is correct only because nobody else touches the list
 *    until the task has completed back on the main thread (the hand-off).
 *    Consequently the "changed" signal that load() emits is emitted on that
 *    worker thread; the application connects its own handler only after the
 *    load has completed, so none of its handlers runs on the worker, but any
 *    handler connected earlier would;
 *  - the internals of wx_places_save_async()'s worker, which touch only a
 *    private snapshot of the places and the (immutable) file path.
 * Every other function must be called from the thread that owns the list.
 * wx_places_load() and wx_places_save() are SYNCHRONOUS file operations (save
 * includes fsync and rename) meant for start-up, shutdown and tests only. The
 * UI MUST persist edits with wx_places_save_async(), which snapshots the list
 * on the calling thread and serialises + writes on a worker thread; running
 * the synchronous save from an idle or debounce handler would still block the
 * main loop. Never hold pointers returned by get_place() across a mutation
 * other than add() and move().
 * The list never saves by itself. Debouncing is the caller's job: after
 * edits, schedule one save when wx_places_is_dirty() is TRUE. Before the
 * process exits, keep the main loop running until the save callback has
 * fired (an exit in the middle of a write leaves a "<path>.wx-tmp-XXXXXX"
 * temporary file, which the next wx_places_load() removes once it is older
 * than a minute).
 */
#ifndef WX_PLACES_H
#define WX_PLACES_H

#include <gio/gio.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Largest places file that load() accepts. */
#define WX_PLACES_MAX_FILE_BYTES (1024 * 1024)
/**
 * A new place is rejected as a duplicate when it lies closer than this to a
 * place already in the list (great-circle distance, wx_geo_distance_km()).
 */
#define WX_PLACES_DUPLICATE_KM 5.0

#define WX_TYPE_PLACES (wx_places_get_type())
/* Declared by G_DECLARE_FINAL_TYPE below (GLib gtype.h): the WxPlaces typedef, the
 * WxPlacesClass struct, GType wx_places_get_type(void) (defined by G_DEFINE_TYPE() in
 * wx-places.c, see there), the static inline casts WX_PLACES() and WX_IS_PLACES(), and
 * g_autoptr() support for WxPlaces and WxPlacesClass. WX_TYPE_PLACES above is
 * hand-written. */
G_DECLARE_FINAL_TYPE(WxPlaces, wx_places, WX, PLACES, GObject)

/**
 * WxPlaces::changed:
 * @self: the list.
 *
 * Emitted (synchronously, once per call) after add(), remove() or move()
 * changed the list, and after load() when the list was or became non-empty.
 * It is NOT emitted by calls that fail or change nothing, nor by saving.
 * Handlers may read the list; they MUST NOT mutate it re-entrantly.
 *
 * Thread affinity: emitted in the thread that runs the emitting call; for
 * load() that is the start-up worker thread (see the file header).
 */

/**
 * wx_places_new:
 * @path: (nullable): file used by load()/save(); NULL selects
 *   g_get_user_config_dir()/weather/places.json. The string is copied.
 *
 * Preconditions:
 *  - @path is NULL, or a non-empty NUL-terminated string (an empty string is
 *    a programmer error: critical, NULL returned).
 * Postconditions:
 *  - the list is empty and clean; no file is read or created; the stored path
 *    is non-empty.
 * Thread affinity: any thread; the creating thread owns the list until it is
 *   handed over.
 * Ownership: @path is borrowed and copied; the caller owns the returned list.
 *
 * Returns: (transfer full) (nullable): a new empty list, or NULL if @path is
 *   the empty string. Nothing is read from disk until wx_places_load() is
 *   called.
 */
WxPlaces *wx_places_new(const char *path);

/**
 * wx_places_get_path:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: the returned string is owned by @self and lives as long as it.
 *
 * Returns: (transfer none): the file path used by load()/save().
 */
const char *wx_places_get_path(WxPlaces *self);

/**
 * wx_places_get_n_places:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, 0 returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: none (no pointers returned).
 *
 * Returns: the number of places (at most WX_PLACE_MAX).
 */
guint wx_places_get_n_places(WxPlaces *self);

/**
 * wx_places_get_place:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @index: zero-based position.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: the place is owned by the list; the caller must not free or
 *   modify it.
 *
 * Returns: (transfer none) (nullable): the place, or NULL if @index is out of
 *   range. Valid until the place is removed or the list is reloaded (move()
 *   and add() keep it).
 */
const WxPlace *wx_places_get_place(WxPlaces *self, guint index);

/**
 * wx_places_index_of:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @key: (nullable): a place key as built by wx_place_key(), compared byte for
 *   byte.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, -1 returned); @key is NULL,
 *    NUL-terminated, or has at least 24 readable bytes (at most 24 bytes are
 *    read; no key built by wx_place_key() is longer than 18).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: the position of the place whose wx_place_key() equals @key, or -1
 *   if there is none or @key is NULL or longer than 23 bytes.
 */
gint wx_places_index_of(WxPlaces *self, const char *key);

/**
 * wx_places_add:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @place: (nullable): the place to append; deep-copied and re-validated with
 *   the rules of wx_place_new() (see wx_place_copy()).
 *
 * Appends a place at the end. Emits "changed" on success.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, FALSE returned); @place is NULL
 *    or a place whose strings are NULL or NUL-terminated (a NULL place or one
 *    that violates the wx_place_new() rules is rejected, not a critical).
 * Postconditions:
 *  - on TRUE: a private copy of @place is the last element, the list is dirty
 *    and "changed" has been emitted once;
 *  - on FALSE: the list is unchanged, nothing is emitted.
 * Thread affinity: the thread that owns the list.
 * Ownership: @place is borrowed for the call only.
 *
 * Returns: TRUE if added. FALSE, with the list unchanged, if @place is NULL
 *   or invalid, the list already holds WX_PLACE_MAX places, or a place of
 *   the list lies closer than WX_PLACES_DUPLICATE_KM to it (this includes a
 *   place with the same wx_place_key()).
 */
gboolean wx_places_add(WxPlaces *self, const WxPlace *place);

/**
 * wx_places_remove:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @key: (nullable): a place key as built by wx_place_key().
 *
 * Removes the place with that key. Emits "changed" on success.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, FALSE returned); @key is NULL,
 *    NUL-terminated, or has at least 24 readable bytes.
 * Postconditions:
 *  - on TRUE: the place is freed (pointers from get_place() are invalid), the
 *    places after it shift down by one, the list is dirty and "changed" has
 *    been emitted once;
 *  - on FALSE: the list is unchanged, nothing is emitted.
 * Thread affinity: the thread that owns the list.
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: TRUE if a place was removed; FALSE if no place has that key.
 */
gboolean wx_places_remove(WxPlaces *self, const char *key);

/**
 * wx_places_move:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @from: current zero-based position of the place.
 * @to: zero-based position the place has afterwards; the places in between
 *   shift by one.
 *
 * Moves one place. Emits "changed" on success.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, FALSE returned).
 * Postconditions:
 *  - on TRUE: the place is at index @to, the places in between shifted by
 *    one, the list is dirty and "changed" has been emitted once; pointers
 *    from get_place() still point to the same places but at other indices;
 *  - on FALSE: the list is unchanged, nothing is emitted.
 * Thread affinity: the thread that owns the list.
 * Ownership: none (no pointers).
 *
 * Returns: TRUE if the order changed; FALSE (list unchanged) if either index
 *   is out of range or @from == @to.
 */
gboolean wx_places_move(WxPlaces *self, guint from, guint to);

/**
 * wx_places_load:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @n_dropped: (out) (optional): receives how many stored elements were
 *   discarded (not an object, a missing or mistyped field, a place rejected by
 *   wx_place_new(), a duplicate in the sense of wx_places_add(), elements
 *   beyond WX_PLACE_MAX). Set to 0 first, right after the checks of @self and
 *   @error, so it is 0 after every failure except those two argument checks,
 *   which leave it untouched.
 * @error: (nullable): return location for a #GError.
 *
 * Replaces the list with the content of the file at wx_places_get_path().
 * Valid places are kept in file order; invalid ones are dropped and counted.
 * Also removes stale "<path>.wx-tmp-XXXXXX" temporary files (see
 * wx_file_remove_stale_temps()). Synchronous blocking file I/O: start-up and
 * tests only.
 *
 * If an asynchronous save is running the call fails at once with
 * G_IO_ERROR / G_IO_ERROR_PENDING and changes nothing: the places, the dirty
 * flag and the file are untouched, no signal is emitted (only @n_dropped is
 * set to 0). Every other failure leaves the list EMPTY, sets @error and emits
 * "changed" once if the list was non-empty; the list is then clean (not
 * dirty). Failures:
 *  - G_FILE_ERROR / G_FILE_ERROR_NOENT: no file yet (normal on first run);
 *  - G_IO_ERROR / G_IO_ERROR_MESSAGE_TOO_LARGE: file larger than
 *    WX_PLACES_MAX_FILE_BYTES; other G_FILE_ERROR codes: I/O failure;
 *  - WX_ERROR / WX_ERROR_PARSE: not valid JSON, not the expected shape, an
 *    unsupported "version", or rejected by wx_json_check_strict() (comments,
 *    single-quoted strings or other non-RFC 8259 bytes, a "\u0000" escape, or
 *    nesting deeper than WX_JSON_MAX_DEPTH; checked before the JSON parser
 *    sees the data).
 * No GLib warning or critical is logged for any file content.
 * On success "changed" is emitted once if the list was or became non-empty,
 * and the list is clean (not dirty).
 *
 * Known limit (not enforced): the file is bounded only by
 * WX_PLACES_MAX_FILE_BYTES (1 MiB), and json-glib builds a node tree for the
 * whole text before any place is validated, so a hostile 1 MiB file of tiny
 * elements costs memory proportional to its element count for the duration of
 * the load. No further cap is applied.
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, FALSE returned and @n_dropped is
 *    left untouched); @error is NULL or points to a NULL #GError pointer
 *    (else: critical, FALSE, @n_dropped untouched);
 *  - the caller owns the list (see the file header).
 * Postconditions:
 *  - on TRUE: the list holds the valid places, *@n_dropped is the number of
 *    dropped elements, the list is clean; "changed" has been emitted once if
 *    the list was or became non-empty (in the calling thread, which may be the
 *    start-up worker thread);
 *  - on FALSE: see above; the list is empty (except the PENDING case).
 * Thread affinity: the thread that owns the list.
 * Ownership: @n_dropped and @error are filled for the caller; nothing is
 *   retained.
 *
 * Returns: TRUE if the file was loaded (possibly with dropped elements).
 */
gboolean wx_places_load(WxPlaces *self, guint *n_dropped, GError **error);

/**
 * wx_places_is_dirty:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 *
 * Preconditions:
 *  - @self is a valid list (else: critical, FALSE returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: none (no pointers).
 *
 * Returns: TRUE iff add()/remove()/move() changed the list since the last
 *   wx_places_load() (successful or not) or successful save. A save that was
 *   started before the latest edit does not clear the flag.
 */
gboolean wx_places_is_dirty(WxPlaces *self);

/**
 * wx_places_save:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @error: (nullable): return location for a #GError (G_FILE_ERROR domain, or
 *   G_IO_ERROR / G_IO_ERROR_PENDING).
 *
 * Writes the list with wx_file_write_atomic(): on failure the previous file
 * is untouched. SYNCHRONOUS, includes fsync: for start-up, shutdown and
 * tests; the UI must use wx_places_save_async(). Clears the dirty flag on
 * success. Fails with G_IO_ERROR_PENDING (nothing written) while an
 * asynchronous save is running. Saves unconditionally, even when the list is
 * clean.
 *
 * Preconditions:
 *  - @self is a valid list and is owned by the calling thread; @error is NULL
 *    or points to a NULL #GError pointer (else: critical, FALSE).
 * Postconditions:
 *  - on TRUE: the file holds the list and the list is clean;
 *  - on FALSE: @error (if non-NULL) is set; the dirty flag and the previous
 *    file are unchanged.
 * Thread affinity: the thread that owns the list.
 * Ownership: @error is filled for the caller; nothing is retained.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_places_save(WxPlaces *self, GError **error);

/**
 * wx_places_save_async:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @cancellable: (nullable): honoured only until the write starts; a cancelled
 *   save writes nothing and reports G_IO_ERROR_CANCELLED.
 * @callback: (nullable) (scope async): invoked in the thread-default main
 *   context of the calling thread.
 * @user_data: passed to @callback.
 *
 * Takes a snapshot of the list on the calling thread (at most WX_PLACE_MAX
 * small places) and serialises + writes it on a worker thread; the calling
 * thread never touches the disk. Only one save may run at a time: if one is
 * already running, @callback receives G_IO_ERROR_PENDING (from the main loop,
 * never synchronously) and nothing else changes, so the caller should retry
 * later. Saves unconditionally, even when the list is clean. On success the
 * dirty flag is cleared before @callback runs, unless an edit happened after
 * the snapshot was taken (the list then stays dirty and needs another save).
 * The list is kept alive until the save finishes.
 *
 * Preconditions:
 *  - @self is a valid list owned by the calling thread (else: critical,
 *    nothing happens and @callback is never called); the calling thread
 *    iterates a main context that will run @callback.
 * Postconditions:
 *  - exactly one call of @callback (if given) follows, from the main loop,
 *    with a result for wx_places_save_finish(); the worker touches only the
 *    private snapshot and the immutable path of @self.
 * Thread affinity: the thread that owns the list.
 * Ownership: the task holds a reference on @self until the callback has run
 *   and the worker has let go of the task, so when the caller drops its own
 *   reference meanwhile the last reference may be released by the worker
 *   thread, which then finalises the list (it owns no thread-affine resource;
 *   no signal is emitted); @cancellable is referenced by the task; @user_data
 *   is passed through untouched and stays owned by the caller.
 */
void wx_places_save_async(WxPlaces *self, GCancellable *cancellable,
                          GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_places_save_finish:
 * @self: (not nullable): the list; must satisfy WX_IS_PLACES().
 * @result: (not nullable): the result passed to the callback of
 *   wx_places_save_async().
 * @error: (nullable): return location for a #GError.
 *
 * Collects the outcome of wx_places_save_async().
 *
 * Preconditions:
 *  - @self is a valid list; @result was produced by wx_places_save_async() on
 *    @self (else: critical, FALSE); call it once, in the callback.
 * Postconditions:
 *  - on FALSE after a runtime failure: @error (if non-NULL) is set
 *    (G_IO_ERROR / G_IO_ERROR_PENDING or _CANCELLED, or G_FILE_ERROR_*).
 * Thread affinity: the thread that runs the callback (the thread that called
 *   wx_places_save_async()).
 * Ownership: @result stays owned by the caller (the async machinery); @error
 *   is filled for the caller.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_places_save_finish(WxPlaces *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_PLACES_H */
