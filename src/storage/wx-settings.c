/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-settings.h"

#include <gio/gio.h>
#include <json-glib/json-glib.h>
#include <string.h>

#include "wx-fileio.h"
#include "wx-geo.h"
#include "wx-store-json.h"

#define SETTINGS_VERSION 1

/* Bytes examined of a caller's key: the longest valid key is
 * "-90.0000,-180.0000" (18 bytes), so 24 bytes with the NUL leave room. */
#define KEY_BUF_LEN 24
G_STATIC_ASSERT(KEY_BUF_LEN >= sizeof "-90.0000,-180.0000");

/* The persisted values; embedded in the object and used for save snapshots. */
typedef struct {
  WxUnits units;
  GPtrArray *disabled; /* char*, valid provider ids, no repeats, freed with g_free */
  char *selected;      /* valid place key, or NULL */
} Values;

struct _WxSettings {
  GObject parent_instance;
  char *path;
  Values v;
  guint64 gen;       /* bumped by every successful setter */
  guint64 saved_gen; /* gen at the last load (successful or not) or successful save snapshot */
  gboolean save_in_flight;
};

/* Source tag of wx_settings_save_async() tasks; only its address is used. */
static char save_tag;

enum { SIGNAL_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

/*
 * G_DEFINE_TYPE(WxSettings, wx_settings, G_TYPE_OBJECT) generates the following (checked with
 * gcc -E of this file with the project's compile flags):
 *  - GType wx_settings_get_type(void): returns the GType of WxSettings and registers it on the
 *    first call, inside a once-initialisation guard, by calling wx_settings_get_type_once().
 *    Thread affinity: any thread. Ownership: none (no pointers).
 *  - static GType wx_settings_get_type_once(void): performs the registration for
 *    wx_settings_get_type().
 *    Thread affinity: only via wx_settings_get_type(). Ownership: none (no pointers).
 *  - static void wx_settings_class_intern_init(gpointer klass): @klass is the class structure
 *    being initialised (borrowed, written; nothing is retained). It stores the parent class in
 *    wx_settings_parent_class, adjusts the private offset only if WxSettings_private_offset is
 *    non-zero, then calls wx_settings_class_init(). Called by GObject once per type, from the
 *    thread that first uses the type. Ownership: @klass belongs to GObject.
 *  - static gpointer wx_settings_parent_class: NULL until class_intern_init() runs; used by
 *    finalize() to chain up.
 *  - static gint WxSettings_private_offset: stays 0 (no G_ADD_PRIVATE is used).
 *  - static inline gpointer wx_settings_get_instance_private(WxSettings *self): returns self
 *    plus the private offset; unused here (G_GNUC_UNUSED). @self is borrowed. Thread
 *    affinity: any thread.
 */
G_DEFINE_TYPE(WxSettings, wx_settings, G_TYPE_OBJECT)

/**
 * values_init:
 * @v: (out): the values to initialise.
 *
 * Sets the defaults: imperial units, no disabled provider, no selection.
 *
 * Preconditions:
 *  - @v is non-NULL and holds no resources (fresh or cleared).
 * Postconditions:
 *  - @v owns an empty array; units is WX_UNITS_IMPERIAL; selected is NULL.
 * Thread affinity: any thread.
 * Ownership: @v owns its members afterwards (release with values_clear()).
 */
static void
values_init(Values *v)
{
  v->units = WX_UNITS_IMPERIAL;
  v->disabled = g_ptr_array_new_with_free_func(g_free);
  v->selected = NULL;
}

/**
 * values_clear:
 * @v: values initialised by values_init().
 *
 * Preconditions:
 *  - @v was initialised and is not used afterwards.
 * Postconditions:
 *  - everything @v owns is freed.
 * Thread affinity: any thread (the snapshot may be freed on the worker).
 * Ownership: consumes the members of @v, not @v itself.
 */
static void
values_clear(Values *v)
{
  g_ptr_array_unref(v->disabled);
  g_free(v->selected);
}

/**
 * values_disabled_index:
 * @v: the values.
 * @id: (not nullable): a valid provider id.
 *
 * Preconditions:
 *  - @v is initialised; @id is NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns @v.
 * Ownership: @id is borrowed.
 *
 * Returns: the position of @id in the disabled list, or -1.
 */
static gint
values_disabled_index(const Values *v, const char *id)
{
  for (guint i = 0; i < v->disabled->len; i++)
    if (g_str_equal(g_ptr_array_index(v->disabled, i), id))
      return (gint)i;
  return -1;
}

/**
 * key_is_valid:
 * @key: (nullable): candidate place key.
 *
 * Checks the grammar of wx_place_key(): '-'? 1-3 digits '.' 4 digits, a comma,
 * the same again, and then a valid latitude and longitude. At most
 * KEY_BUF_LEN bytes are examined.
 *
 * Preconditions:
 *  - @key is NULL, NUL-terminated, or has KEY_BUF_LEN readable bytes.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: @key is borrowed.
 *
 * Returns: TRUE iff @key has the grammar above and wx_geo_valid() accepts its
 *   coordinates.
 */
static gboolean
key_is_valid(const char *key)
{
  if (key == NULL || memchr(key, '\0', KEY_BUF_LEN) == NULL)
    return FALSE;
  const char *p = key;
  double coord[2];
  for (guint part = 0; part < 2; part++) {
    const char *start = p;
    if (*p == '-')
      p++;
    guint digits = 0;
    for (; g_ascii_isdigit(*p); p++)
      digits++;
    if (digits < 1 || digits > 3 || *p != '.')
      return FALSE;
    p++;
    for (guint i = 0; i < 4; i++, p++)
      if (!g_ascii_isdigit(*p))
        return FALSE;
    coord[part] = g_ascii_strtod(start, NULL);
    if (part == 0) {
      if (*p != ',')
        return FALSE;
      p++;
    }
  }
  return *p == '\0' && wx_geo_valid(coord[0], coord[1]);
}

/**
 * wx_settings_finalize:
 * @object: the WxSettings being finalized.
 *
 * GObject finalize: frees the path and the values, then chains up.
 *
 * Preconditions:
 *  - @object is a WxSettings whose last reference was dropped; no save is
 *    running (the save tasks hold a reference on the object).
 * Postconditions:
 *  - all memory owned by the object is freed; the parent finalize has run.
 * Thread affinity: the thread that drops the last reference.
 * Ownership: the object owns its path and values; both are released here.
 */
static void
wx_settings_finalize(GObject *object)
{
  WxSettings *self = WX_SETTINGS(object);
  g_free(self->path);
  values_clear(&self->v);
  G_OBJECT_CLASS(wx_settings_parent_class)->finalize(object);
}

/**
 * wx_settings_class_init:
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
wx_settings_class_init(WxSettingsClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_settings_finalize;
  signals[SIGNAL_CHANGED] = g_signal_new("changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST,
                                         0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

/**
 * wx_settings_init:
 * @self: the instance being initialised.
 *
 * GObject instance init: sets the default values.
 *
 * Preconditions:
 *  - @self is a zero-initialised new instance.
 * Postconditions:
 *  - the values are the defaults; path is still NULL (set by
 *    wx_settings_new()).
 * Thread affinity: the creating thread.
 * Ownership: the instance owns the values.
 */
static void
wx_settings_init(WxSettings *self)
{
  values_init(&self->v);
}

/* Documented in wx-settings.h. */
WxSettings *
wx_settings_new(const char *path)
{
  g_return_val_if_fail(path == NULL || path[0] != '\0', NULL);
  WxSettings *self = g_object_new(WX_TYPE_SETTINGS, NULL);
  self->path = path != NULL
                 ? g_strdup(path)
                 : g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  return self;
}

/* Documented in wx-settings.h. */
const char *
wx_settings_get_path(WxSettings *self)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), NULL);
  return self->path;
}

/* Documented in wx-settings.h. */
WxUnits
wx_settings_get_units(WxSettings *self)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), WX_UNITS_IMPERIAL);
  return self->v.units;
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_set_units(WxSettings *self, WxUnits units)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  g_return_val_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC, FALSE);
  if (units == self->v.units)
    return FALSE;
  self->v.units = units;
  self->gen++;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_is_provider_disabled(WxSettings *self, const char *id)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  return wx_id_is_valid(id) && values_disabled_index(&self->v, id) >= 0;
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_set_provider_disabled(WxSettings *self, const char *id, gboolean disabled)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  if (!wx_id_is_valid(id))
    return FALSE;
  gint i = values_disabled_index(&self->v, id);
  if (disabled) {
    if (i >= 0 || self->v.disabled->len >= WX_SETTINGS_MAX_DISABLED)
      return FALSE;
    g_ptr_array_add(self->v.disabled, g_strdup(id));
  } else {
    if (i < 0)
      return FALSE;
    g_ptr_array_remove_index(self->v.disabled, (guint)i);
  }
  self->gen++;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* Documented in wx-settings.h. */
const char *
wx_settings_get_selected(WxSettings *self)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), NULL);
  return self->v.selected;
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_set_selected(WxSettings *self, const char *key)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  if (key != NULL && !key_is_valid(key))
    return FALSE;
  if (g_strcmp0(key, self->v.selected) == 0)
    return FALSE;
  g_free(self->v.selected);
  self->v.selected = g_strdup(key);
  self->gen++;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* ------------------------------------------------------------------------ */
/* Persistence                                                              */
/* ------------------------------------------------------------------------ */

/**
 * values_from_json:
 * @v: (out): receives the values; must be initialised (defaults).
 * @obj: (not nullable): the root object of the document.
 *
 * Reads every member that is present and valid; everything else keeps the
 * default already in @v. Unknown members are ignored.
 *
 * Preconditions:
 *  - @v holds the defaults; @obj belongs to a live parser.
 * Postconditions:
 *  - @v holds the defaults overridden by the valid members; nothing is logged.
 * Thread affinity: any thread.
 * Ownership: @obj is borrowed; @v owns what it was given.
 */
static void
values_from_json(Values *v, JsonObject *obj)
{
  const char *units = wx_store_node_string(json_object_get_member(obj, "units"));
  if (g_strcmp0(units, "metric") == 0)
    v->units = WX_UNITS_METRIC;

  JsonArray *arr = wx_store_node_array(json_object_get_member(obj, "disabled_providers"));
  guint n = arr != NULL ? json_array_get_length(arr) : 0;
  for (guint i = 0; i < n; i++) {
    const char *id = wx_store_node_string(json_array_get_element(arr, i));
    if (wx_id_is_valid(id) && values_disabled_index(v, id) < 0 &&
        v->disabled->len < WX_SETTINGS_MAX_DISABLED)
      g_ptr_array_add(v->disabled, g_strdup(id));
  }

  const char *selected = wx_store_node_string(json_object_get_member(obj, "selected"));
  if (key_is_valid(selected))
    v->selected = g_strdup(selected);
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_load(WxSettings *self, GError **error)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("settings"));
    return FALSE;
  }

  Values loaded;
  values_init(&loaded);
  g_autoptr(JsonParser) parser = NULL;
  JsonObject *obj = NULL;
  gboolean ok = wx_store_load_json(self->path, WX_SETTINGS_MAX_FILE_BYTES, "settings", &parser,
                                   error);
  if (ok) {
    obj = wx_store_root_object(json_parser_get_root(parser), "settings", SETTINGS_VERSION, error);
    ok = obj != NULL;
  }
  if (ok)
    values_from_json(&loaded, obj);

  values_clear(&self->v);
  self->v = loaded; /* the defaults after a failure: nothing was read into it */
  self->saved_gen = self->gen;
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return ok;
}

/**
 * serialize_values:
 * @v: the values to write.
 * @len: (not nullable) (out): receives the document length in bytes.
 *
 * Serialises @v. Strings go through wx_json_append_string(), never
 * JsonGenerator, so that no control byte is ever written raw. Size: at most
 * WX_SETTINGS_MAX_DISABLED ids of 32 bytes plus a key, far below
 * WX_SETTINGS_MAX_FILE_BYTES.
 *
 * Preconditions:
 *  - @v holds valid values (the object's own or a private snapshot) that are
 *    not modified meanwhile.
 * Postconditions:
 *  - no state is changed; *@len is the length of the returned text.
 * Thread affinity: any thread (touches only @v and the result).
 * Ownership: @v is borrowed; the caller owns the returned buffer.
 *
 * Returns: (transfer full): the NUL-terminated document; free with g_free().
 */
static char *
serialize_values(const Values *v, gsize *len)
{
  GString *out = g_string_sized_new(256);
  g_string_append_printf(out, "{\n  \"version\": %d,\n  \"units\": ", SETTINGS_VERSION);
  wx_json_append_string(out, v->units == WX_UNITS_METRIC ? "metric" : "imperial");
  g_string_append(out, ",\n  \"disabled_providers\": [");
  for (guint i = 0; i < v->disabled->len; i++) {
    g_string_append(out, i > 0 ? ", " : "");
    wx_json_append_string(out, g_ptr_array_index(v->disabled, i));
  }
  g_string_append_c(out, ']');
  if (v->selected != NULL) {
    g_string_append(out, ",\n  \"selected\": ");
    wx_json_append_string(out, v->selected);
  }
  g_string_append(out, "\n}\n");
  *len = out->len;
  return g_string_free(out, FALSE);
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_is_dirty(WxSettings *self)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  return self->gen != self->saved_gen;
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_save(WxSettings *self, GError **error)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  if (self->save_in_flight) {
    g_propagate_error(error, wx_store_pending_error("settings"));
    return FALSE;
  }

  gsize len = 0;
  g_autofree char *text = serialize_values(&self->v, &len);
  if (!wx_file_write_atomic(self->path, text, len, error))
    return FALSE;
  self->saved_gen = self->gen;
  return TRUE;
}

/* Data of one asynchronous save; owned by the inner GTask as task data. */
typedef struct {
  Values v; /* deep copy, owned */
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
 *  - @job was created by wx_settings_save_async() and is freed exactly once
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
  values_clear(&job->v);
  g_object_unref(job->outer);
  g_free(job);
}

/**
 * save_worker:
 * @task: the inner task.
 * @source: (type WxSettings): the object the task was created for.
 * @task_data: the SaveJob.
 * @cancellable: (nullable): unused; cancellation is read through @task.
 *
 * GTaskThreadFunc: serialises the private snapshot and writes it atomically
 * to the object's path. Returns the cancellation error instead if the task
 * was cancelled before it started.
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
  g_autofree char *text = serialize_values(&job->v, &len);
  GError *error = NULL;
  if (wx_file_write_atomic(WX_SETTINGS(source)->path, text, len, &error))
    g_task_return_boolean(task, TRUE);
  else
    g_task_return_error(task, error);
}

/**
 * save_done:
 * @source: (type WxSettings): the object.
 * @result: the finished inner task.
 * @user_data: unused.
 *
 * GAsyncReadyCallback of the inner task, run in the main context of the
 * thread that called wx_settings_save_async(): clears save_in_flight, marks
 * the settings saved as of the snapshot generation on success, and completes
 * the caller's outer task with the same outcome.
 *
 * Preconditions:
 *  - @source is the object and @result its inner task, whose task data is the
 *    SaveJob; runs in the thread that owns the object.
 * Postconditions:
 *  - save_in_flight is FALSE; on success saved_gen is the generation of the
 *    snapshot (the settings stay dirty if changed since); the outer task has
 *    been completed once.
 * Thread affinity: the thread that owns the object (main thread).
 * Ownership: the error obtained from the inner task is handed to the outer
 *   task; nothing else is retained.
 */
static void
save_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)user_data;
  WxSettings *self = WX_SETTINGS(source);
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

/* Documented in wx-settings.h. */
void
wx_settings_save_async(WxSettings *self, GCancellable *cancellable, GAsyncReadyCallback callback,
                       gpointer user_data)
{
  g_return_if_fail(WX_IS_SETTINGS(self));

  GTask *outer = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(outer, &save_tag);
  /* A cancellation that arrives after the write started must not turn a
   * successful write into an error: only save_worker() honours it. */
  g_task_set_check_cancellable(outer, FALSE);
  if (self->save_in_flight) {
    g_task_return_error(outer, wx_store_pending_error("settings"));
    g_object_unref(outer);
    return;
  }

  self->save_in_flight = TRUE;
  SaveJob *job = g_new0(SaveJob, 1);
  values_init(&job->v);
  job->v.units = self->v.units;
  for (guint i = 0; i < self->v.disabled->len; i++)
    g_ptr_array_add(job->v.disabled, g_strdup(g_ptr_array_index(self->v.disabled, i)));
  job->v.selected = g_strdup(self->v.selected);
  job->gen = self->gen;
  job->outer = outer;
  GTask *inner = g_task_new(self, cancellable, save_done, NULL);
  g_task_set_check_cancellable(inner, FALSE);
  g_task_set_task_data(inner, job, (GDestroyNotify)save_job_free);
  g_task_run_in_thread(inner, save_worker);
  g_object_unref(inner);
}

/* Documented in wx-settings.h. */
gboolean
wx_settings_save_finish(WxSettings *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_SETTINGS(self), FALSE);
  g_return_val_if_fail(g_task_is_valid(result, self), FALSE);
  g_return_val_if_fail(g_async_result_is_tagged(result, &save_tag), FALSE);
  return g_task_propagate_boolean(G_TASK(result), error);
}
