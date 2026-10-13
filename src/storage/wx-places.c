/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-places.h"

#include <gio/gio.h>
#include <json-glib/json-glib.h>
#include <string.h>

#include "wx-fileio.h"
#include "wx-geo.h"
#include "wx-store-json.h"

#define PLACES_VERSION 1

/* Bytes examined of a caller's key: the longest key wx_place_key() builds is
 * "-90.0000,-180.0000" (18 bytes), so 24 bytes with the NUL leave room. */
#define KEY_BUF_LEN 24
G_STATIC_ASSERT(KEY_BUF_LEN >= sizeof "-90.0000,-180.0000");

/* One saved place with its cached key; owned by the list (or by a snapshot). */
typedef struct {
  WxPlace *place; /* private copy */
  char *key;      /* wx_place_key(place) */
} Entry;

struct _WxPlaces {
  GObject parent_instance;
  char *path;
  GPtrArray *entries; /* Entry*, freed with entry_free */
  guint64 gen;        /* bumped by every successful add/remove/move */
  guint64 saved_gen;  /* gen at the last load (successful or not) or successful save snapshot */
  gboolean save_in_flight;
};

/* Source tag of wx_places_save_async() tasks; only its address is used. */
static char save_tag;

enum { SIGNAL_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

/*
 * G_DEFINE_TYPE(WxPlaces, wx_places, G_TYPE_OBJECT) generates the following (checked with
 * gcc -E of this file with the project's compile flags):
 *  - GType wx_places_get_type(void): returns the GType of WxPlaces and registers it on the
 *    first call, inside a once-initialisation guard, by calling wx_places_get_type_once().
 *    Thread affinity: any thread. Ownership: none (no pointers).
 *  - static GType wx_places_get_type_once(void): performs the registration for
 *    wx_places_get_type().
 *    Thread affinity: only via wx_places_get_type(). Ownership: none (no pointers).
 *  - static void wx_places_class_intern_init(gpointer klass): @klass is the class structure
 *    being initialised (borrowed, written; nothing is retained). It stores the parent class in
 *    wx_places_parent_class, adjusts the private offset only if WxPlaces_private_offset is
 *    non-zero, then calls wx_places_class_init(). Called by GObject once per type, from the
 *    thread that first uses the type. Ownership: @klass belongs to GObject.
 *  - static gpointer wx_places_parent_class: NULL until class_intern_init() runs; used by
 *    finalize() to chain up.
 *  - static gint WxPlaces_private_offset: stays 0 (no G_ADD_PRIVATE is used).
 *  - static inline gpointer wx_places_get_instance_private(WxPlaces *self): returns self
 *    plus the private offset; unused here (G_GNUC_UNUSED). @self is borrowed. Thread
 *    affinity: any thread.
 */
G_DEFINE_TYPE(WxPlaces, wx_places, G_TYPE_OBJECT)

/**
 * entry_free:
 * @data: (not nullable): an Entry created by entry_new() or entry_dup().
 *
 * GDestroyNotify of the entry arrays: frees the place, the key and the entry.
 *
 * Preconditions:
 *  - @data is a heap-allocated Entry whose place and key are owned by it; the
 *    call sites are the GPtrArray free functions, which pass each element
 *    exactly once. @data is dereferenced and so must not be NULL.
 * Postconditions:
 *  - the entry and its place and key are freed.
 * Thread affinity: any thread (the entry is owned by the freeing array; the
 *   snapshot array may be freed on the worker or the main thread).
 * Ownership: consumes @data.
 */
static void
entry_free(gpointer data)
{
  Entry *e = data;
  wx_place_free(e->place);
  g_free(e->key);
  g_free(e);
}

/**
 * entry_new:
 * @place: (transfer full) (not nullable): a valid place, adopted.
 *
 * Wraps @place in an entry and computes its key.
 *
 * Preconditions:
 *  - @place is a valid place created by wx_place_new()/wx_place_copy().
 * Postconditions:
 *  - the entry owns @place and holds wx_place_key(@place).
 * Thread affinity: any thread.
 * Ownership: consumes @place; the caller owns the entry.
 *
 * Returns: (transfer full): the new entry.
 */
static Entry *
entry_new(WxPlace *place)
{
  Entry *e = g_new(Entry, 1);
  e->place = place;
  e->key = wx_place_key(place);
  return e;
}

/**
 * entry_dup:
 * @src: (not nullable): an entry of a list.
 *
 * Deep-copies an entry field by field (no validation: the source is already
 * valid, so this cannot fail). Used by the save snapshot.
 *
 * Preconditions:
 *  - @src is a valid entry that nobody mutates during the call.
 * Postconditions:
 *  - the copy shares no memory with @src.
 * Thread affinity: the thread that owns the list.
 * Ownership: @src is borrowed; the caller owns the copy.
 *
 * Returns: (transfer full): the copy.
 */
static Entry *
entry_dup(const Entry *src)
{
  WxPlace *p = g_new0(WxPlace, 1);
  p->name = g_strdup(src->place->name);
  p->admin1 = g_strdup(src->place->admin1);
  p->country = g_strdup(src->place->country);
  memcpy(p->country_code, src->place->country_code, sizeof p->country_code);
  p->lat = src->place->lat;
  p->lon = src->place->lon;
  p->timezone = g_strdup(src->place->timezone);
  Entry *e = g_new(Entry, 1);
  e->place = p;
  e->key = g_strdup(src->key);
  return e;
}

/**
 * wx_places_finalize:
 * @object: the WxPlaces being finalized.
 *
 * GObject finalize: frees the path and the entry array, then chains up.
 *
 * Preconditions:
 *  - @object is a WxPlaces whose last reference was dropped; no save is
 *    running (the save tasks hold a reference on the list).
 * Postconditions:
 *  - all memory owned by the list is freed; the parent finalize has run.
 * Thread affinity: the thread that drops the last reference.
 * Ownership: the list owns its path and entries; both are released here.
 */
static void
wx_places_finalize(GObject *object)
{
  WxPlaces *self = WX_PLACES(object);
  g_free(self->path);
  g_ptr_array_unref(self->entries);
  G_OBJECT_CLASS(wx_places_parent_class)->finalize(object);
}

/**
 * wx_places_class_init:
 * @klass: the class structure being initialised.
 *
 * GObject class_init: installs finalize and registers the "changed" signal
 * (no parameters, run last).
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - the finalize vfunc is set and signals[SIGNAL_CHANGED] is registered.
 * Thread affinity: the thread that first uses the type (GType serialises it).
 * Ownership: none (the class is owned by GType).
 */
static void
wx_places_class_init(WxPlacesClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_places_finalize;
  signals[SIGNAL_CHANGED] = g_signal_new("changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST,
                                         0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

/**
 * wx_places_init:
 * @self: the instance being initialised.
 *
 * GObject instance init: creates the empty entry array.
 *
 * Preconditions:
 *  - @self is a zero-initialised new instance.
 * Postconditions:
 *  - entries is an empty array that frees its elements with entry_free();
 *    path is still NULL (set by wx_places_new()).
 * Thread affinity: the creating thread.
 * Ownership: the instance owns the new array.
 */
static void
wx_places_init(WxPlaces *self)
{
  self->entries = g_ptr_array_new_with_free_func(entry_free);
}

/* Documented in wx-places.h. */
WxPlaces *
wx_places_new(const char *path)
{
  g_return_val_if_fail(path == NULL || path[0] != '\0', NULL);
  WxPlaces *self = g_object_new(WX_TYPE_PLACES, NULL);
  self->path = path != NULL
                 ? g_strdup(path)
                 : g_build_filename(g_get_user_config_dir(), "weather", "places.json", NULL);
  return self;
}

/* Documented in wx-places.h. */
const char *
wx_places_get_path(WxPlaces *self)
{
  g_return_val_if_fail(WX_IS_PLACES(self), NULL);
  return self->path;
}

/* Documented in wx-places.h. */
guint
wx_places_get_n_places(WxPlaces *self)
{
  g_return_val_if_fail(WX_IS_PLACES(self), 0);
  return self->entries->len;
}

/* Documented in wx-places.h. */
const WxPlace *
wx_places_get_place(WxPlaces *self, guint index)
{
  g_return_val_if_fail(WX_IS_PLACES(self), NULL);
  if (index >= self->entries->len)
    return NULL;
  return ((const Entry *)g_ptr_array_index(self->entries, index))->place;
}

/* Documented in wx-places.h. */
gint
wx_places_index_of(WxPlaces *self, const char *key)
{
  g_return_val_if_fail(WX_IS_PLACES(self), -1);
  if (key == NULL || memchr(key, '\0', KEY_BUF_LEN) == NULL)
    return -1;
  for (guint i = 0; i < self->entries->len; i++) {
    const Entry *e = g_ptr_array_index(self->entries, i);
    if (g_str_equal(e->key, key))
      return (gint)i;
  }
  return -1;
}

/**
 * is_duplicate:
 * @self: the list.
 * @place: (not nullable): a valid place.
 *
 * Preconditions:
 *  - @self is a valid list; @place is valid (finite, in-range coordinates, so
 *    wx_geo_distance_km() never yields NAN).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the list.
 * Ownership: @place is borrowed for the call only.
 *
 * Returns: TRUE iff a place of the list lies closer than
 *   WX_PLACES_DUPLICATE_KM to @place (so also when it has the same key: equal
 *   keys mean coordinates within 0.00005 degrees).
 */
static gboolean
is_duplicate(WxPlaces *self, const WxPlace *place)
{
  for (guint i = 0; i < self->entries->len; i++) {
    const Entry *e = g_ptr_array_index(self->entries, i);
    if (wx_geo_distance_km(e->place->lat, e->place->lon, place->lat, place->lon) <
        WX_PLACES_DUPLICATE_KM)
      return TRUE;
  }
  return FALSE;
}

/**
 * append_place:
 * @self: the list.
 * @place: (transfer full) (not nullable): a valid place, adopted only on
 *   success.
 *
 * Appends without emitting. Fails when the list is full or @place is a
 * duplicate.
 *
 * Preconditions:
 *  - @self is a valid list; @place is a valid place owned by the caller.
 * Postconditions:
 *  - on TRUE: the list owns @place as its last element and the generation
 *    counter is incremented;
 *  - on FALSE: the list is unchanged and @place is still owned by the caller.
 * Thread affinity: the thread that owns the list.
 * Ownership: consumed on TRUE only.
 *
 * Returns: TRUE if the place was appended.
 */
static gboolean
append_place(WxPlaces *self, WxPlace *place)
{
  if (self->entries->len >= WX_PLACE_MAX || is_duplicate(self, place))
    return FALSE;
  g_ptr_array_add(self->entries, entry_new(place));
  self->gen++;
  return TRUE;
}

/* Documented in wx-places.h. */
gboolean
wx_places_add(WxPlaces *self, const WxPlace *place)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  if (place == NULL)
    return FALSE;
  WxPlace *copy = wx_place_copy(place);
  if (copy == NULL)
    return FALSE;
  if (!append_place(self, copy)) {
    wx_place_free(copy);
    return FALSE;
  }
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* Documented in wx-places.h. */
gboolean
wx_places_remove(WxPlaces *self, const char *key)
{
  gint i = wx_places_index_of(self, key);
  if (i < 0)
    return FALSE;
  g_ptr_array_remove_index(self->entries, (guint)i);
  self->gen++;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* Documented in wx-places.h. */
gboolean
wx_places_move(WxPlaces *self, guint from, guint to)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  guint n = self->entries->len;
  if (from >= n || to >= n || from == to)
    return FALSE;

  /* In bounds: from != to and both < n, so from + 1 <= to < n resp.
   * to + 1 <= from < n, and the byte counts are (|to - from|) pointers. */
  gpointer *pdata = self->entries->pdata;
  gpointer moved = pdata[from];
  if (from < to)
    memmove(&pdata[from], &pdata[from + 1], (to - from) * sizeof(gpointer));
  else
    memmove(&pdata[to + 1], &pdata[to], (from - to) * sizeof(gpointer));
  pdata[to] = moved;
  self->gen++;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* ------------------------------------------------------------------------ */
/* Persistence                                                              */
/* ------------------------------------------------------------------------ */

/**
 * fill_from_json:
 * @self: the list; must be empty.
 * @root: (nullable): root node of the parsed document.
 * @dropped: (not nullable) (inout): counter incremented once per dropped
 *   array element.
 * @error: (nullable): return location for a #GError, may be NULL.
 *
 * Fills @self from parsed JSON: checks the top-level object, the "version"
 * and the "places" array and appends every valid element with
 * append_place().
 *
 * Preconditions:
 *  - @self is empty; @root is NULL or a node owned by a live JsonParser;
 *    @dropped points to a local (call site: wx_places_load()); @error is NULL
 *    or points to a NULL #GError pointer.
 * Postconditions:
 *  - on TRUE: every valid element has been appended in file order and
 *    *@dropped counts the others (no more than the array length, so no
 *    overflow);
 *  - on FALSE: @error (if non-NULL) is set (WX_ERROR / WX_ERROR_PARSE);
 *    nothing was appended; *@dropped is untouched.
 * Thread affinity: the thread that owns the list.
 * Ownership: @root is borrowed; nothing is retained.
 *
 * Returns: TRUE if the document has the expected shape and version.
 */
static gboolean
fill_from_json(WxPlaces *self, JsonNode *root, guint *dropped, GError **error)
{
  JsonObject *obj = wx_store_root_object(root, "places", PLACES_VERSION, error);
  if (obj == NULL)
    return FALSE;
  JsonArray *arr = wx_store_node_array(json_object_get_member(obj, "places"));
  if (arr == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "places: missing places array");
    return FALSE;
  }
  guint n = json_array_get_length(arr);
  for (guint i = 0; i < n; i++) {
    WxPlace *place = wx_store_place_from_json(json_array_get_element(arr, i));
    if (place == NULL)
      (*dropped)++;
    else if (!append_place(self, place)) {
      wx_place_free(place);
      (*dropped)++;
    }
  }
  return TRUE;
}

/* Documented in wx-places.h. */
gboolean
wx_places_load(WxPlaces *self, guint *n_dropped, GError **error)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (n_dropped != NULL)
    *n_dropped = 0;
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("places"));
    return FALSE;
  }

  gboolean had_places = self->entries->len > 0;
  g_ptr_array_set_size(self->entries, 0);

  g_autoptr(JsonParser) parser = NULL;
  guint dropped = 0;
  gboolean ok = wx_store_load_json(self->path, WX_PLACES_MAX_FILE_BYTES, "places", &parser, error) &&
                fill_from_json(self, json_parser_get_root(parser), &dropped, error);
  if (!ok)
    g_ptr_array_set_size(self->entries, 0);
  else if (n_dropped != NULL)
    *n_dropped = dropped;
  self->saved_gen = self->gen;
  if (had_places || self->entries->len > 0)
    g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return ok;
}

/**
 * serialize_entries:
 * @entries: (element-type Entry): the entries to write.
 * @len: (not nullable) (out): receives the document length in bytes.
 *
 * Serialises @entries. Strings go through wx_json_append_string() and numbers
 * through wx_json_append_double(), never JsonGenerator, so that no control
 * byte is ever written raw (the loader rejects those) and every coordinate
 * reads back bit-identical. Size: at most WX_PLACE_MAX places of < 2.5 KiB
 * (three 256-byte names escape to at most 512 bytes each), far below
 * WX_PLACES_MAX_FILE_BYTES.
 *
 * Preconditions:
 *  - @entries holds valid entries and is not modified meanwhile (the worker
 *    uses the private snapshot); it holds at most WX_PLACE_MAX elements
 *    because the list was filled only through append_place() and the
 *    snapshot is an element-wise copy of it.
 * Postconditions:
 *  - no state is changed; *@len is the length of the returned text.
 * Thread affinity: any thread (touches only @entries and the result).
 * Ownership: @entries is borrowed; the caller owns the returned buffer.
 *
 * Returns: (transfer full): the NUL-terminated document; free with g_free().
 */
static char *
serialize_entries(const GPtrArray *entries, gsize *len)
{
  GString *out = g_string_sized_new(64 + (gsize)entries->len * 256);
  g_string_append_printf(out, "{\n  \"version\": %d,\n  \"places\": [", PLACES_VERSION);
  for (guint i = 0; i < entries->len; i++) {
    g_string_append(out, i > 0 ? ",\n    " : "\n    ");
    wx_store_append_place(out, ((const Entry *)g_ptr_array_index(entries, i))->place);
  }
  g_string_append(out, entries->len > 0 ? "\n  ]\n}\n" : "]\n}\n");
  *len = out->len;
  return g_string_free(out, FALSE);
}

/* Documented in wx-places.h. */
gboolean
wx_places_is_dirty(WxPlaces *self)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  return self->gen != self->saved_gen;
}

/* Documented in wx-places.h. */
gboolean
wx_places_save(WxPlaces *self, GError **error)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("places"));
    return FALSE;
  }

  gsize len = 0;
  g_autofree char *text = serialize_entries(self->entries, &len);
  if (!wx_file_write_atomic(self->path, text, len, error))
    return FALSE;
  self->saved_gen = self->gen;
  return TRUE;
}

/* Data of one asynchronous save; owned by the inner GTask as task data. */
typedef struct {
  GPtrArray *entries; /* deep copy, owned */
  guint64 gen;
  GTask *outer; /* the task handed to the caller, completed in save_done() */
} SaveJob;

/**
 * save_job_free:
 * @job: the job to free.
 *
 * GDestroyNotify of the inner task's data: frees the snapshot copy, drops the
 * reference on the outer task and frees the job.
 *
 * Preconditions:
 *  - @job was created by wx_places_save_async() and is freed exactly once
 *    (by the inner GTask, after both save_worker() and save_done() are done
 *    with it).
 * Postconditions:
 *  - the snapshot, the job and the reference on the outer task are released.
 * Thread affinity: any thread (the inner task may be finalised on the worker
 *   or on the thread that ran save_done()).
 * Ownership: consumes @job and its snapshot; releases the outer task.
 */
static void
save_job_free(SaveJob *job)
{
  g_ptr_array_unref(job->entries);
  g_object_unref(job->outer);
  g_free(job);
}

/**
 * save_worker:
 * @task: the inner task.
 * @source: (type WxPlaces): the list the task was created for.
 * @task_data: the SaveJob.
 * @cancellable: (nullable): unused; cancellation is read through @task.
 *
 * GTaskThreadFunc: serialises the private snapshot and writes it atomically
 * to the list's path. Returns the cancellation error instead if the task was
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
  gsize len = 0;
  g_autofree char *text = serialize_entries(job->entries, &len);
  GError *error = NULL;
  if (wx_file_write_atomic(WX_PLACES(source)->path, text, len, &error))
    g_task_return_boolean(task, TRUE);
  else
    g_task_return_error(task, error);
}

/**
 * save_done:
 * @source: (type WxPlaces): the list.
 * @result: the finished inner task.
 * @user_data: unused.
 *
 * GAsyncReadyCallback of the inner task, run in the main context of the
 * thread that called wx_places_save_async(): clears save_in_flight, marks the
 * list saved as of the snapshot generation on success, and completes the
 * caller's outer task with the same outcome.
 *
 * Preconditions:
 *  - @source is the list and @result its inner task, whose task data is the
 *    SaveJob; runs in the thread that owns the list.
 * Postconditions:
 *  - save_in_flight is FALSE; on success saved_gen is the generation of the
 *    snapshot (the list stays dirty if edited since); the outer task has been
 *    completed once.
 * Thread affinity: the thread that owns the list (main thread).
 * Ownership: the error obtained from the inner task is handed to the outer
 *   task; nothing else is retained.
 */
static void
save_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)user_data;
  WxPlaces *self = WX_PLACES(source);
  GTask *inner = G_TASK(result);
  const SaveJob *job = g_task_get_task_data(inner);
  GTask *outer = job->outer;
  guint64 gen = job->gen;

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

/* Documented in wx-places.h. */
void
wx_places_save_async(WxPlaces *self, GCancellable *cancellable, GAsyncReadyCallback callback,
                     gpointer user_data)
{
  g_return_if_fail(WX_IS_PLACES(self));

  GTask *outer = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(outer, &save_tag);
  /* A cancellation that arrives after the write started must not turn a
   * successful write into an error: only save_worker() honours it. */
  g_task_set_check_cancellable(outer, FALSE);
  if (self->save_in_flight) {
    g_task_return_error(outer, wx_store_pending_error("places"));
    g_object_unref(outer);
    return;
  }

  self->save_in_flight = TRUE;
  SaveJob *job = g_new0(SaveJob, 1);
  job->entries = g_ptr_array_new_full(self->entries->len, entry_free);
  for (guint i = 0; i < self->entries->len; i++)
    g_ptr_array_add(job->entries, entry_dup(g_ptr_array_index(self->entries, i)));
  job->gen = self->gen;
  job->outer = outer;
  GTask *inner = g_task_new(self, cancellable, save_done, NULL);
  g_task_set_check_cancellable(inner, FALSE);
  g_task_set_task_data(inner, job, (GDestroyNotify)save_job_free);
  g_task_run_in_thread(inner, save_worker);
  g_object_unref(inner);
}

/* Documented in wx-places.h. */
gboolean
wx_places_save_finish(WxPlaces *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_PLACES(self), FALSE);
  g_return_val_if_fail(g_task_is_valid(result, self), FALSE);
  g_return_val_if_fail(g_async_result_is_tagged(result, &save_tag), FALSE);
  return g_task_propagate_boolean(G_TASK(result), error);
}
