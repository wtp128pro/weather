/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-fake-provider.c - TEST-ONLY scripted WxProvider / WxGeocoder. See wx-fake-provider.h. */
#include "wx-fake-provider.h"

#include "wx-text.h"

/* Longest search text the fake geocoder accepts, bytes. */
#define FAKE_SEARCH_TEXT_MAX 64

/* Source tags of the tasks created by the fakes' async functions. */
static char tag_fetch, tag_search;

/* ------------------------------------------------------------------------ */
/* Delayed completion shared by both fakes                                  */
/* ------------------------------------------------------------------------ */

/*
 * Task data of one fake operation: the outcome prepared at call time and the
 * sources that deliver it. Owned by the GTask; main thread only. Each source's
 * callback data is a task reference, released when the source is destroyed,
 * so the task (and the fake it references) outlives every pending source.
 */
typedef struct {
  GError *error;               /* fail with this ... */
  gpointer result;             /* ... else return this (owned until returned) */
  GDestroyNotify result_destroy;
  GSource *timer;              /* delivers the outcome after the delay */
  GSource *cancel_watch;       /* completes with G_IO_ERROR_CANCELLED */
} Pending;

/**
 * pending_stop:
 * @pending: (not nullable): the task data.
 *
 * Destroys the delivery sources (and so drops their task references).
 *
 * Preconditions:
 *  - @pending is live; may be called more than once.
 * Postconditions:
 *  - timer and cancel_watch are NULL and destroyed.
 * Thread affinity: main thread only.
 * Ownership: the two source references owned by @pending are released.
 */
static void
pending_stop(Pending *pending)
{
  if (pending->timer != NULL) {
    g_source_destroy(pending->timer);
    g_clear_pointer(&pending->timer, g_source_unref);
  }
  if (pending->cancel_watch != NULL) {
    g_source_destroy(pending->cancel_watch);
    g_clear_pointer(&pending->cancel_watch, g_source_unref);
  }
}

/**
 * pending_free:
 * @data: (not nullable): the Pending created by fake_complete().
 *
 * GDestroyNotify of the task data: releases an outcome that was never
 * delivered (for instance because the operation was cancelled).
 *
 * Preconditions:
 *  - @data is the Pending installed with g_task_set_task_data(); called once
 *    when the GTask is finalised (no source references the task any more).
 * Postconditions:
 *  - everything is released.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @data.
 */
static void
pending_free(gpointer data)
{
  Pending *pending = data;
  pending_stop(pending);
  g_clear_error(&pending->error);
  if (pending->result != NULL)
    pending->result_destroy(pending->result);
  g_free(pending);
}

/**
 * pending_deliver:
 * @task: (not nullable): the task; the caller holds a reference.
 *
 * Completes the task with the prepared outcome.
 *
 * Preconditions:
 *  - @task has a Pending as task data and has not been returned yet.
 * Postconditions:
 *  - the sources are destroyed and the task is completed (the callback may
 *    run before this returns unless GTask defers it); the outcome is moved
 *    into the task.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller.
 */
static void
pending_deliver(GTask *task)
{
  Pending *pending = g_task_get_task_data(task);
  pending_stop(pending);
  if (pending->error != NULL)
    g_task_return_error(task, g_steal_pointer(&pending->error));
  else
    g_task_return_pointer(task, g_steal_pointer(&pending->result), pending->result_destroy);
}

/**
 * on_delay_elapsed:
 * @user_data: (not nullable): the task (passed as gpointer).
 *
 * GSource callback of the delay timer: delivers the prepared outcome.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by the timer source.
 * Postconditions:
 *  - the task is completed; the source is removed.
 * Thread affinity: main thread only.
 * Ownership: the callback takes and releases its own task reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_delay_elapsed(gpointer user_data)
{
  g_autoptr(GTask) task = g_object_ref(user_data);
  pending_deliver(task);
  return G_SOURCE_REMOVE;
}

/**
 * on_cancel_watch:
 * @cancellable: (unused): the caller's cancellable.
 * @user_data: (not nullable): the task (passed as gpointer).
 *
 * GCancellableSourceFunc: the caller cancelled during the delay.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by the watch source; the task has
 *    not been returned.
 * Postconditions:
 *  - the task is completed with G_IO_ERROR_CANCELLED; the source is removed.
 * Thread affinity: main thread only.
 * Ownership: the callback takes and releases its own task reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_cancel_watch(GCancellable *cancellable, gpointer user_data)
{
  (void)cancellable;
  g_autoptr(GTask) task = g_object_ref(user_data);
  pending_stop(g_task_get_task_data(task));
  g_task_return_error(task, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED,
                                                "operation was cancelled"));
  return G_SOURCE_REMOVE;
}

/**
 * fake_complete:
 * @task: (not nullable): the new task of a fake operation.
 * @error: (transfer full) (nullable): the failure to deliver, or NULL.
 * @result: (transfer full) (nullable): the success value when @error is NULL.
 * @result_destroy: frees @result.
 * @delay_ms: delay before delivery; 0 delivers immediately.
 *
 * Schedules the delivery of a prepared outcome: at once, after @delay_ms, or
 * as G_IO_ERROR_CANCELLED if the task's cancellable is (or becomes) cancelled
 * first.
 *
 * Preconditions:
 *  - @task has no task data yet; @result_destroy is non-NULL when @result is
 *    non-NULL.
 * Postconditions:
 *  - the task owns the outcome and will be completed exactly once; the
 *    caller drops its own task reference afterwards.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @error and @result; @task stays with the
 *   caller.
 */
static void
fake_complete(GTask *task, GError *error, gpointer result, GDestroyNotify result_destroy,
              guint delay_ms)
{
  Pending *pending = g_new0(Pending, 1);
  pending->error = error;
  pending->result = result;
  pending->result_destroy = result_destroy;
  g_task_set_task_data(task, pending, pending_free);
  if (g_task_return_error_if_cancelled(task))
    return;
  if (delay_ms == 0) {
    pending_deliver(task);
    return;
  }
  pending->timer = g_timeout_source_new(delay_ms);
  g_source_set_callback(pending->timer, on_delay_elapsed, g_object_ref(task), g_object_unref);
  g_source_attach(pending->timer, g_task_get_context(task));
  GCancellable *cancellable = g_task_get_cancellable(task);
  if (cancellable != NULL) {
    pending->cancel_watch = g_cancellable_source_new(cancellable);
    g_source_set_callback(pending->cancel_watch, G_SOURCE_FUNC(on_cancel_watch),
                          g_object_ref(task), g_object_unref);
    g_source_attach(pending->cancel_watch, g_task_get_context(task));
  }
}

/**
 * code_is_valid:
 * @code: a scripted failure code.
 *
 * Tells whether a scripted failure code is acceptable.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @code is -1 (no failure) or a WxError value.
 */
static gboolean
code_is_valid(int code)
{
  return code >= -1 && code <= WX_ERROR_UNSUPPORTED;
}

/* ------------------------------------------------------------------------ */
/* WxFakeProvider                                                           */
/* ------------------------------------------------------------------------ */

struct _WxFakeProvider {
  GObject parent_instance;
  char *id;
  char *name;
  char *attribution;
  gboolean covers_all;
  int failure; /* -1: succeed, else the WxError to fail with */
  guint delay_ms;
  guint fetch_count;
  GPtrArray *members; /* WxMember*, element free function wx_member_unref() */
};

static void wx_fake_provider_provider_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxFakeProvider, wx_fake_provider, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, wx_fake_provider_provider_init))

/**
 * wx_fake_provider_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: covers everything, succeeds at once, no member.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxFakeProvider being constructed by GObject.
 * Postconditions:
 *  - covers_all is TRUE, failure is -1, the member list is empty.
 * Thread affinity: main thread only.
 * Ownership: @self owns the list.
 */
static void
wx_fake_provider_init(WxFakeProvider *self)
{
  self->covers_all = TRUE;
  self->failure = -1;
  self->members = g_ptr_array_new_with_free_func((GDestroyNotify)wx_member_unref);
}

/**
 * wx_fake_provider_finalize:
 * @object: (not nullable): the WxFakeProvider being finalized.
 *
 * GObject finalize: frees the strings and drops the member references.
 *
 * Preconditions:
 *  - @object is a WxFakeProvider whose last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns its strings and members.
 */
static void
wx_fake_provider_finalize(GObject *object)
{
  WxFakeProvider *self = WX_FAKE_PROVIDER(object);
  g_free(self->id);
  g_free(self->name);
  g_free(self->attribution);
  g_ptr_array_unref(self->members);
  G_OBJECT_CLASS(wx_fake_provider_parent_class)->finalize(object);
}

/**
 * wx_fake_provider_class_init:
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
wx_fake_provider_class_init(WxFakeProviderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_fake_provider_finalize;
}

/**
 * fake_get_id:
 * @provider: (not nullable): the WxFakeProvider.
 *
 * WxProviderInterface.get_id.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider (reached only through its vtable).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is owned by @provider.
 *
 * Returns: (transfer none): the id given to wx_fake_provider_new().
 */
static const char *
fake_get_id(WxProvider *provider)
{
  return WX_FAKE_PROVIDER(provider)->id;
}

/**
 * fake_get_name:
 * @provider: (not nullable): the WxFakeProvider.
 *
 * WxProviderInterface.get_name.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is owned by @provider.
 *
 * Returns: (transfer none): "Fake <id>".
 */
static const char *
fake_get_name(WxProvider *provider)
{
  return WX_FAKE_PROVIDER(provider)->name;
}

/**
 * fake_get_attribution:
 * @provider: (not nullable): the WxFakeProvider.
 *
 * WxProviderInterface.get_attribution.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is owned by @provider.
 *
 * Returns: (transfer none): "Fake data (<id>)".
 */
static const char *
fake_get_attribution(WxProvider *provider)
{
  return WX_FAKE_PROVIDER(provider)->attribution;
}

/**
 * fake_get_attribution_url:
 * @provider: (not nullable): the WxFakeProvider.
 *
 * WxProviderInterface.get_attribution_url.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the string is a constant.
 *
 * Returns: (transfer none): "https://example.invalid/".
 */
static const char *
fake_get_attribution_url(WxProvider *provider)
{
  (void)provider;
  return "https://example.invalid/";
}

/**
 * fake_covers:
 * @provider: (not nullable): the WxFakeProvider.
 * @place: (not nullable): the place.
 *
 * WxProviderInterface.covers.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider; @place is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: the flag set by wx_fake_provider_set_covers().
 */
static gboolean
fake_covers(WxProvider *provider, const WxPlace *place)
{
  (void)place;
  return WX_FAKE_PROVIDER(provider)->covers_all;
}

/**
 * fake_fetch_async:
 * @provider: (not nullable): the WxFakeProvider.
 * @place: (not nullable): the place; validated by copying.
 * @cancellable: (nullable): cancels the operation.
 * @callback: called once with the result.
 * @user_data: passed to @callback.
 *
 * WxProviderInterface.fetch_async: an invalid place is WX_ERROR_INVALID_ARG,
 * an uncovered one WX_ERROR_UNSUPPORTED, then the scripted failure (if any) or
 * a WxSourceResult holding the added members is delivered after the delay.
 *
 * Preconditions:
 *  - @provider is a WxFakeProvider; @place is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - @callback is called exactly once, never before this function returns;
 *    the fetch count is incremented.
 * Thread affinity: main thread only.
 * Ownership: the task takes references on @provider and @cancellable.
 */
static void
fake_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
                 GAsyncReadyCallback callback, gpointer user_data)
{
  WxFakeProvider *self = WX_FAKE_PROVIDER(provider);
  self->fetch_count++;
  GTask *task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_fetch);
  GError *error = NULL;
  WxSourceResult *result = NULL;
  g_autoptr(WxPlace) copy = wx_place_copy(place);
  if (copy == NULL) {
    g_set_error_literal(&error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid place");
  } else if (!self->covers_all) {
    g_set_error_literal(&error, WX_ERROR, WX_ERROR_UNSUPPORTED, "place not covered");
  } else if (self->failure >= 0) {
    g_set_error_literal(&error, WX_ERROR, self->failure, "scripted failure");
  } else {
    result = wx_source_result_new(self->id, &error);
    for (guint i = 0; result != NULL && i < self->members->len; i++)
      g_ptr_array_add(result->members, wx_member_ref(g_ptr_array_index(self->members, i)));
  }
  fake_complete(task, error, result, (GDestroyNotify)wx_source_result_free, self->delay_ms);
  g_object_unref(task);
}

/**
 * fake_fetch_finish:
 * @provider: (not nullable): the WxFakeProvider the fetch was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxProviderInterface.fetch_finish.
 *
 * Preconditions:
 *  - @result is a task created by fake_fetch_async() for @provider and not
 *    yet finished (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed; on failure NULL is returned and *@error is set.
 * Thread affinity: main thread only.
 * Ownership: the result is returned to the caller.
 *
 * Returns: (transfer full) (nullable): the source result, or NULL with @error.
 */
static WxSourceResult *
fake_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, provider), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_fetch, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_fake_provider_provider_init:
 * @iface: (not nullable): the WxProvider interface structure of WxFakeProvider.
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
wx_fake_provider_provider_init(WxProviderInterface *iface)
{
  iface->get_id = fake_get_id;
  iface->get_name = fake_get_name;
  iface->get_attribution = fake_get_attribution;
  iface->get_attribution_url = fake_get_attribution_url;
  iface->covers = fake_covers;
  iface->fetch_async = fake_fetch_async;
  iface->fetch_finish = fake_fetch_finish;
}

/* Documented in wx-fake-provider.h. */
WxFakeProvider *
wx_fake_provider_new(const char *id)
{
  g_return_val_if_fail(id != NULL, NULL);
  WxFakeProvider *self = g_object_new(WX_TYPE_FAKE_PROVIDER, NULL);
  self->id = g_strdup(id);
  self->name = g_strconcat("Fake ", id, NULL);
  self->attribution = g_strconcat("Fake data (", id, ")", NULL);
  return self;
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_provider_set_covers(WxFakeProvider *self, gboolean covers_all)
{
  g_return_if_fail(WX_IS_FAKE_PROVIDER(self));
  self->covers_all = covers_all != FALSE;
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_provider_add_member(WxFakeProvider *self, WxMember *member)
{
  g_return_if_fail(WX_IS_FAKE_PROVIDER(self));
  g_return_if_fail(member != NULL);
  g_ptr_array_add(self->members, wx_member_ref(member));
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_provider_fail_with(WxFakeProvider *self, int code)
{
  g_return_if_fail(WX_IS_FAKE_PROVIDER(self));
  g_return_if_fail(code_is_valid(code));
  self->failure = code;
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_provider_set_delay_ms(WxFakeProvider *self, guint delay_ms)
{
  g_return_if_fail(WX_IS_FAKE_PROVIDER(self));
  self->delay_ms = delay_ms;
}

/* Documented in wx-fake-provider.h. */
guint
wx_fake_provider_get_fetch_count(WxFakeProvider *self)
{
  g_return_val_if_fail(WX_IS_FAKE_PROVIDER(self), 0);
  return self->fetch_count;
}

/* ------------------------------------------------------------------------ */
/* WxFakeGeocoder                                                           */
/* ------------------------------------------------------------------------ */

struct _WxFakeGeocoder {
  GObject parent_instance;
  GPtrArray *hits; /* WxPlace*, element free function wx_place_free() */
  int failure;     /* -1: succeed, else the WxError to fail with */
  guint delay_ms;
  guint search_count;
};

static void wx_fake_geocoder_geocoder_init(WxGeocoderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(WxFakeGeocoder, wx_fake_geocoder, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_GEOCODER, wx_fake_geocoder_geocoder_init))

/**
 * wx_fake_geocoder_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: no hit, succeeds at once.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxFakeGeocoder being constructed by GObject.
 * Postconditions:
 *  - failure is -1 and the hit list is empty.
 * Thread affinity: main thread only.
 * Ownership: @self owns the list.
 */
static void
wx_fake_geocoder_init(WxFakeGeocoder *self)
{
  self->failure = -1;
  self->hits = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
}

/**
 * wx_fake_geocoder_finalize:
 * @object: (not nullable): the WxFakeGeocoder being finalized.
 *
 * GObject finalize: frees the hits.
 *
 * Preconditions:
 *  - @object is a WxFakeGeocoder whose last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns its hits.
 */
static void
wx_fake_geocoder_finalize(GObject *object)
{
  g_ptr_array_unref(WX_FAKE_GEOCODER(object)->hits);
  G_OBJECT_CLASS(wx_fake_geocoder_parent_class)->finalize(object);
}

/**
 * wx_fake_geocoder_class_init:
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
wx_fake_geocoder_class_init(WxFakeGeocoderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_fake_geocoder_finalize;
}

/**
 * fake_search_async:
 * @geocoder: (not nullable): the WxFakeGeocoder.
 * @text: (not nullable): the search text.
 * @cancellable: (nullable): cancels the operation.
 * @callback: called once with the result.
 * @user_data: passed to @callback.
 *
 * WxGeocoderInterface.search_async: text that is not usable (1..64 bytes,
 * valid UTF-8, no control characters, not only blanks) is
 * WX_ERROR_INVALID_ARG; otherwise the scripted failure or a copy of the hits
 * (at most WX_GEOCODER_MAX_HITS) is delivered after the delay.
 *
 * Preconditions:
 *  - @geocoder is a WxFakeGeocoder; @text is non-NULL (checked by the
 *    dispatcher).
 * Postconditions:
 *  - @callback is called exactly once, never before this function returns;
 *    the search count is incremented.
 * Thread affinity: main thread only.
 * Ownership: the task takes references on @geocoder and @cancellable.
 */
static void
fake_search_async(WxGeocoder *geocoder, const char *text, GCancellable *cancellable,
                  GAsyncReadyCallback callback, gpointer user_data)
{
  WxFakeGeocoder *self = WX_FAKE_GEOCODER(geocoder);
  self->search_count++;
  GTask *task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_search);
  GError *error = NULL;
  GPtrArray *hits = NULL;
  if (!wx_text_is_usable_name(text, FAKE_SEARCH_TEXT_MAX)) {
    g_set_error_literal(&error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid search text");
  } else if (self->failure >= 0) {
    g_set_error_literal(&error, WX_ERROR, self->failure, "scripted failure");
  } else {
    hits = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
    for (guint i = 0; i < self->hits->len && i < WX_GEOCODER_MAX_HITS; i++)
      g_ptr_array_add(hits, wx_place_copy(g_ptr_array_index(self->hits, i)));
  }
  fake_complete(task, error, hits, (GDestroyNotify)g_ptr_array_unref, self->delay_ms);
  g_object_unref(task);
}

/**
 * fake_search_finish:
 * @geocoder: (not nullable): the WxFakeGeocoder the search was started on.
 * @result: (not nullable): the result passed to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * WxGeocoderInterface.search_finish.
 *
 * Preconditions:
 *  - @result is a task created by fake_search_async() for @geocoder and not
 *    yet finished (checked: critical, NULL).
 * Postconditions:
 *  - the outcome is consumed; on failure NULL is returned and *@error is set.
 * Thread affinity: main thread only.
 * Ownership: the array is returned to the caller.
 *
 * Returns: (transfer full) (nullable) (element-type WxPlace): the hits, or
 *   NULL with @error.
 */
static GPtrArray *
fake_search_finish(WxGeocoder *geocoder, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(g_task_is_valid(result, geocoder), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_search, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/**
 * wx_fake_geocoder_geocoder_init:
 * @iface: (not nullable): the WxGeocoder interface structure of WxFakeGeocoder.
 *
 * Interface initialiser named in G_IMPLEMENT_INTERFACE(): fills the vtable.
 *
 * Preconditions:
 *  - called by GObject when the interface is set up for the type.
 * Postconditions:
 *  - both virtual functions are set.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @iface is owned by GObject and not retained.
 */
static void
wx_fake_geocoder_geocoder_init(WxGeocoderInterface *iface)
{
  iface->search_async = fake_search_async;
  iface->search_finish = fake_search_finish;
}

/* Documented in wx-fake-provider.h. */
WxFakeGeocoder *
wx_fake_geocoder_new(void)
{
  return g_object_new(WX_TYPE_FAKE_GEOCODER, NULL);
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_geocoder_add_hit(WxFakeGeocoder *self, const WxPlace *place)
{
  g_return_if_fail(WX_IS_FAKE_GEOCODER(self));
  g_return_if_fail(place != NULL);
  WxPlace *copy = wx_place_copy(place);
  g_return_if_fail(copy != NULL);
  g_ptr_array_add(self->hits, copy);
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_geocoder_fail_with(WxFakeGeocoder *self, int code)
{
  g_return_if_fail(WX_IS_FAKE_GEOCODER(self));
  g_return_if_fail(code_is_valid(code));
  self->failure = code;
}

/* Documented in wx-fake-provider.h. */
void
wx_fake_geocoder_set_delay_ms(WxFakeGeocoder *self, guint delay_ms)
{
  g_return_if_fail(WX_IS_FAKE_GEOCODER(self));
  self->delay_ms = delay_ms;
}

/* Documented in wx-fake-provider.h. */
guint
wx_fake_geocoder_get_search_count(WxFakeGeocoder *self)
{
  g_return_val_if_fail(WX_IS_FAKE_GEOCODER(self), 0);
  return self->search_count;
}
