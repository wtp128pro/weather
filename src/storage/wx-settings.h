/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-settings.h - the user's preferences, persisted as JSON.
 *
 * File: <config>/weather/settings.json, schema
 *   {"version":1,"units":"imperial"|"metric",
 *    "disabled_providers":[<provider id>,...],"selected":"<place key>"}
 * ("selected" is omitted when no place is selected). Defaults: imperial
 * units, no provider disabled, no selection. Unknown members, unknown or
 * invalid values and surplus entries are ignored on load and keep the
 * defaults.
 *
 * Threading: a WxSettings has no locking: at any moment it must be used by ONE
 * thread only, normally the main thread. Two exceptions exist:
 *  - the start-up load: the application calls wx_settings_load() on a GTask
 *    worker thread. That is correct only because nobody else touches the
 *    object until the task has completed back on the main thread (the
 *    hand-off). The "changed" signal that load() emits is therefore emitted
 *    on that worker thread; the application connects its own handler only
 *    after the load has completed;
 *  - the internals of wx_settings_save_async()'s worker, which touch only a
 *    private snapshot and the (immutable) file path.
 * Every other function must be called from the thread that owns the object.
 * wx_settings_load() and wx_settings_save() are SYNCHRONOUS file operations
 * meant for start-up, shutdown and tests only; the UI persists edits with
 * wx_settings_save_async(). The object never saves by itself: after edits the
 * caller schedules one save when wx_settings_is_dirty() is TRUE, and before
 * the process exits it keeps the main loop running until the save callback
 * has fired (an exit in the middle of a write leaves a
 * "<path>.wx-tmp-XXXXXX" temporary file, which the next wx_settings_load()
 * removes once it is older than a minute).
 */
#ifndef WX_SETTINGS_H
#define WX_SETTINGS_H

#include <gio/gio.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Largest settings file that load() accepts. */
#define WX_SETTINGS_MAX_FILE_BYTES (64 * 1024)
/** Maximum number of disabled providers remembered (the registry holds at most 16). */
#define WX_SETTINGS_MAX_DISABLED 16

#define WX_TYPE_SETTINGS (wx_settings_get_type())
/* Declared by G_DECLARE_FINAL_TYPE below (GLib gtype.h): the WxSettings typedef, the
 * WxSettingsClass struct, GType wx_settings_get_type(void) (defined by G_DEFINE_TYPE() in
 * wx-settings.c, see there), the static inline casts WX_SETTINGS() and WX_IS_SETTINGS(), and
 * g_autoptr() support for WxSettings and WxSettingsClass. WX_TYPE_SETTINGS above is
 * hand-written. */
G_DECLARE_FINAL_TYPE(WxSettings, wx_settings, WX, SETTINGS, GObject)

/**
 * WxSettings::changed:
 * @self: the settings.
 *
 * Emitted (synchronously, once per call) after a setter changed a value, and
 * once after every wx_settings_load() that did not fail with
 * G_IO_ERROR_PENDING (also when the values did not change). It is NOT emitted
 * by setters that change nothing or fail, nor by saving. Handlers may read the
 * settings; they MUST NOT mutate them re-entrantly.
 *
 * Thread affinity: emitted in the thread that runs the emitting call; for
 * load() that is the start-up worker thread (see the file header).
 */

/**
 * wx_settings_new:
 * @path: (nullable): file used by load()/save(); NULL selects
 *   g_get_user_config_dir()/weather/settings.json. The string is copied.
 *
 * Preconditions:
 *  - @path is NULL, or a non-empty NUL-terminated string (an empty string is
 *    a programmer error: critical, NULL returned).
 * Postconditions:
 *  - the settings hold the defaults and are clean; no file is read or created;
 *    the stored path is non-empty.
 * Thread affinity: any thread; the creating thread owns the object until it is
 *   handed over.
 * Ownership: @path is borrowed and copied; the caller owns the result.
 *
 * Returns: (transfer full) (nullable): new default settings, or NULL if @path
 *   is the empty string.
 */
WxSettings *wx_settings_new(const char *path);

/**
 * wx_settings_get_path:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 *
 * Preconditions:
 *  - @self is valid (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the settings.
 * Ownership: the returned string is owned by @self and lives as long as it.
 *
 * Returns: (transfer none): the file path used by load()/save().
 */
const char *wx_settings_get_path(WxSettings *self);

/**
 * wx_settings_get_units:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 *
 * Preconditions:
 *  - @self is valid (else: critical, WX_UNITS_IMPERIAL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the settings.
 * Ownership: none.
 *
 * Returns: the unit system; WX_UNITS_IMPERIAL by default.
 */
WxUnits wx_settings_get_units(WxSettings *self);

/**
 * wx_settings_set_units:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 *
 * Preconditions:
 *  - @self is valid and @units is one of the two values (else: critical, FALSE
 *    returned, nothing changes).
 * Postconditions:
 *  - on TRUE: the unit system is @units, the settings are dirty and "changed"
 *    has been emitted once;
 *  - on FALSE: nothing is changed or emitted.
 * Thread affinity: the thread that owns the settings.
 * Ownership: none.
 *
 * Returns: TRUE iff the value differed from the current one.
 */
gboolean wx_settings_set_units(WxSettings *self, WxUnits units);

/**
 * wx_settings_is_provider_disabled:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @id: (nullable): provider id.
 *
 * Preconditions:
 *  - @self is valid (else: critical, FALSE returned); @id is NULL,
 *    NUL-terminated, or has at least WX_ID_MAX + 1 readable bytes.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the settings.
 * Ownership: @id is borrowed for the call only.
 *
 * Returns: TRUE iff @id satisfies wx_id_is_valid() and is in the disabled
 *   list. FALSE otherwise (so every provider is enabled by default).
 */
gboolean wx_settings_is_provider_disabled(WxSettings *self, const char *id);

/**
 * wx_settings_set_provider_disabled:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @id: (nullable): provider id; must satisfy wx_id_is_valid().
 * @disabled: TRUE to disable the provider, FALSE to enable it.
 *
 * Preconditions:
 *  - @self is valid (else: critical, FALSE returned); @id is NULL,
 *    NUL-terminated, or has at least WX_ID_MAX + 1 readable bytes.
 * Postconditions:
 *  - on TRUE: the provider is in (@disabled) or out of (!@disabled) the
 *    disabled list, the settings are dirty and "changed" has been emitted
 *    once;
 *  - on FALSE: nothing is changed or emitted.
 * Thread affinity: the thread that owns the settings.
 * Ownership: @id is borrowed and copied.
 *
 * Returns: TRUE iff the list changed. FALSE if @id is NULL or invalid, the
 *   state already was as requested, or the provider would have to be added to
 *   a list that holds WX_SETTINGS_MAX_DISABLED ids.
 */
gboolean wx_settings_set_provider_disabled(WxSettings *self, const char *id, gboolean disabled);

/**
 * wx_settings_get_selected:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 *
 * Preconditions:
 *  - @self is valid (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the settings.
 * Ownership: the string is owned by @self and valid until the next
 *   set_selected() or load().
 *
 * Returns: (transfer none) (nullable): the key of the selected place (the
 *   form built by wx_place_key(), e.g. "25.7617,-80.1918"), or NULL when no
 *   place is selected.
 */
const char *wx_settings_get_selected(WxSettings *self);

/**
 * wx_settings_set_selected:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @key: (nullable): a place key of the form "<lat>,<lon>", each coordinate
 *   with an optional '-', one to three integer digits, '.', exactly four
 *   decimals and a valid latitude/longitude; or NULL to clear the selection.
 *
 * Preconditions:
 *  - @self is valid (else: critical, FALSE returned); @key is NULL,
 *    NUL-terminated, or has at least 24 readable bytes (at most 24 are read).
 * Postconditions:
 *  - on TRUE: the selection is @key (copied) or cleared, the settings are
 *    dirty and "changed" has been emitted once;
 *  - on FALSE: nothing is changed or emitted.
 * Thread affinity: the thread that owns the settings.
 * Ownership: @key is borrowed and copied.
 *
 * Returns: TRUE iff the selection changed. FALSE if @key is not a valid key
 *   or equals the current selection.
 */
gboolean wx_settings_set_selected(WxSettings *self, const char *key);

/**
 * wx_settings_load:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @error: (nullable): return location for a #GError.
 *
 * Replaces the settings with the content of the file at
 * wx_settings_get_path(). Values that are missing, of the wrong type or
 * invalid keep their default; "disabled_providers" entries that are invalid,
 * repeated or beyond WX_SETTINGS_MAX_DISABLED are skipped. Also removes stale
 * "<path>.wx-tmp-XXXXXX" temporary files. Synchronous blocking file I/O:
 * start-up and tests only.
 *
 * Fails with G_IO_ERROR / G_IO_ERROR_PENDING and changes nothing while an
 * asynchronous save is running. Every other failure resets the settings to the
 * defaults, sets @error and emits "changed" once:
 *  - G_FILE_ERROR / G_FILE_ERROR_NOENT: no file yet (normal on first run);
 *  - G_IO_ERROR / G_IO_ERROR_MESSAGE_TOO_LARGE: file larger than
 *    WX_SETTINGS_MAX_FILE_BYTES; other G_FILE_ERROR codes: I/O failure;
 *  - WX_ERROR / WX_ERROR_PARSE: not valid JSON, not an object, an unsupported
 *    "version", or rejected by wx_json_check_strict() (a "\u0000" escape,
 *    comments, non-RFC 8259 bytes or nesting deeper than WX_JSON_MAX_DEPTH;
 *    checked before the JSON parser sees the data).
 * No GLib warning or critical is logged for any file content. Either way the
 * settings are clean (not dirty) afterwards.
 *
 * Preconditions:
 *  - @self is valid (else: critical, FALSE); @error is NULL or points to a
 *    NULL #GError pointer (else: critical, FALSE);
 *  - the caller owns the object (see the file header).
 * Postconditions:
 *  - on TRUE: the settings hold the file's valid values (defaults for the
 *    rest), are clean, and "changed" has been emitted once;
 *  - on FALSE: @error (if non-NULL) is set; the settings are the defaults and
 *    clean, "changed" has been emitted once; except in the PENDING case where
 *    everything is untouched.
 * Thread affinity: the thread that owns the settings.
 * Ownership: @error is filled for the caller; nothing is retained.
 *
 * Returns: TRUE if the file was loaded.
 */
gboolean wx_settings_load(WxSettings *self, GError **error);

/**
 * wx_settings_is_dirty:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 *
 * Preconditions:
 *  - @self is valid (else: critical, FALSE returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the settings.
 * Ownership: none.
 *
 * Returns: TRUE iff a setter changed a value since the last
 *   wx_settings_load() (successful or not) or successful save. A save that
 *   was started before the latest change does not clear the flag.
 */
gboolean wx_settings_is_dirty(WxSettings *self);

/**
 * wx_settings_save:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @error: (nullable): return location for a #GError (G_FILE_ERROR domain, or
 *   G_IO_ERROR / G_IO_ERROR_PENDING).
 *
 * Writes the settings with wx_file_write_atomic(): on failure the previous
 * file is untouched. SYNCHRONOUS, includes fsync: for start-up, shutdown and
 * tests; the UI must use wx_settings_save_async(). Clears the dirty flag on
 * success. Fails with G_IO_ERROR_PENDING (nothing written) while an
 * asynchronous save is running. Saves unconditionally, even when clean.
 *
 * Preconditions:
 *  - @self is valid and owned by the calling thread; @error is NULL or points
 *    to a NULL #GError pointer (else: critical, FALSE).
 * Postconditions:
 *  - on TRUE: the file holds the settings and they are clean;
 *  - on FALSE: @error (if non-NULL) is set; the dirty flag and the previous
 *    file are unchanged.
 * Thread affinity: the thread that owns the settings.
 * Ownership: @error is filled for the caller; nothing is retained.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_settings_save(WxSettings *self, GError **error);

/**
 * wx_settings_save_async:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @cancellable: (nullable): honoured only until the write starts; a cancelled
 *   save writes nothing and reports G_IO_ERROR_CANCELLED.
 * @callback: (nullable) (scope async): invoked in the thread-default main
 *   context of the calling thread.
 * @user_data: passed to @callback.
 *
 * Takes a snapshot of the settings on the calling thread and serialises +
 * writes it on a worker thread; the calling thread never touches the disk.
 * Only one save may run at a time: if one is already running, @callback
 * receives G_IO_ERROR_PENDING (from the main loop, never synchronously) and
 * nothing else changes, so the caller should retry later. Saves
 * unconditionally. On success the dirty flag is cleared before @callback
 * runs, unless a setter changed something after the snapshot was taken. The
 * object is kept alive until the save finishes.
 *
 * Preconditions:
 *  - @self is valid and owned by the calling thread (else: critical, nothing
 *    happens and @callback is never called); the calling thread iterates a
 *    main context that will run @callback.
 * Postconditions:
 *  - exactly one call of @callback (if given) follows, from the main loop,
 *    with a result for wx_settings_save_finish(); the worker touches only the
 *    private snapshot and the immutable path of @self.
 * Thread affinity: the thread that owns the settings.
 * Ownership: the task holds a reference on @self until the callback has run
 *   and the worker has let go of the task, so when the caller drops its own
 *   reference meanwhile the last reference may be released by the worker
 *   thread, which then finalises the object (it owns no thread-affine
 *   resource; no signal is emitted); @cancellable is referenced by the task;
 *   @user_data is passed through untouched and stays owned by the caller.
 */
void wx_settings_save_async(WxSettings *self, GCancellable *cancellable,
                            GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_settings_save_finish:
 * @self: (not nullable): the settings; must satisfy WX_IS_SETTINGS().
 * @result: (not nullable): the result passed to the callback of
 *   wx_settings_save_async().
 * @error: (nullable): return location for a #GError.
 *
 * Collects the outcome of wx_settings_save_async().
 *
 * Preconditions:
 *  - @self is valid; @result was produced by wx_settings_save_async() on @self
 *    (else: critical, FALSE); call it once, in the callback.
 * Postconditions:
 *  - on FALSE after a runtime failure: @error (if non-NULL) is set
 *    (G_IO_ERROR / G_IO_ERROR_PENDING or _CANCELLED, or G_FILE_ERROR_*).
 * Thread affinity: the thread that runs the callback.
 * Ownership: @result stays owned by the caller; @error is filled for the
 *   caller.
 *
 * Returns: TRUE if the file was replaced.
 */
gboolean wx_settings_save_finish(WxSettings *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_SETTINGS_H */
