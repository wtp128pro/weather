/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-registry.c - WxRegistry: provider list, enabled flags, geocoder. See wx-registry.h. */
#include "wx-registry.h"

#include <string.h>

/* One registered provider. The id is copied at registration because the
 * implementation's get_id() is only required to be constant, not trusted. */
typedef struct {
  WxProvider *provider; /* strong reference */
  char *id;
  gboolean enabled;
} Entry;

struct _WxRegistry {
  GObject parent_instance;
  GPtrArray *entries; /* Entry*, registration order, element free function entry_free() */
  WxGeocoder *geocoder;
};

enum { SIGNAL_CHANGED, N_SIGNALS };
static guint signals[N_SIGNALS];

G_DEFINE_TYPE(WxRegistry, wx_registry, G_TYPE_OBJECT)

/**
 * entry_free:
 * @data: (not nullable): an Entry created by wx_registry_add_provider().
 *
 * Releases an entry and the provider reference it holds.
 *
 * Preconditions:
 *  - @data is an Entry owned by the caller and not used afterwards.
 * Postconditions:
 *  - the id is freed and the provider reference dropped (which may finalise
 *    the provider).
 * Thread affinity: main thread only.
 * Ownership: consumes @data.
 */
static void
entry_free(gpointer data)
{
  Entry *entry = data;
  g_object_unref(entry->provider);
  g_free(entry->id);
  g_free(entry);
}

/**
 * wx_registry_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: creates the empty provider list.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxRegistry being constructed by GObject.
 * Postconditions:
 *  - the list is empty and there is no geocoder.
 * Thread affinity: main thread only.
 * Ownership: @self owns the list.
 */
static void
wx_registry_init(WxRegistry *self)
{
  self->entries = g_ptr_array_new_with_free_func(entry_free);
}

/**
 * wx_registry_finalize:
 * @object: (not nullable): the WxRegistry being finalized.
 *
 * GObject finalize: releases the providers, the geocoder and the list. There
 * is deliberately no dispose override: a registry is a plain container that
 * creates no reference cycle (providers do not reference it), so nothing has
 * to be broken at dispose time, and keeping everything until finalize means
 * that after g_object_run_dispose() the registry still works and the provider
 * and geocoder pointers handed out earlier are still valid.
 *
 * Preconditions:
 *  - @object is a WxRegistry whose last reference is gone (runs once).
 * Postconditions:
 *  - all memory is released and the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the references owned by the registry are released.
 */
static void
wx_registry_finalize(GObject *object)
{
  WxRegistry *self = WX_REGISTRY(object);
  g_ptr_array_unref(self->entries);
  g_clear_object(&self->geocoder);
  G_OBJECT_CLASS(wx_registry_parent_class)->finalize(object);
}

/**
 * wx_registry_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs finalize and the "changed" signal (run
 * last, no arguments, no return value).
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden; the signal exists.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @klass is owned by the type system and not retained.
 */
static void
wx_registry_class_init(WxRegistryClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS(klass);
  object_class->finalize = wx_registry_finalize;
  signals[SIGNAL_CHANGED] = g_signal_new("changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST,
                                         0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

/* Documented in wx-registry.h. */
WxRegistry *
wx_registry_new(void)
{
  return g_object_new(WX_TYPE_REGISTRY, NULL);
}

/**
 * provider_id_is_valid:
 * @id: (nullable): candidate provider id.
 *
 * The registry's id rule: wx_id_is_valid() and no '.'.
 *
 * Preconditions:
 *  - @id is NULL or NUL-terminated (at most WX_ID_MAX + 1 bytes are read).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @id matches [a-z0-9][a-z0-9_-]{0,31}.
 */
static gboolean
provider_id_is_valid(const char *id)
{
  return wx_id_is_valid(id) && strchr(id, '.') == NULL;
}

/**
 * find_entry:
 * @self: (not nullable): the registry.
 * @id: (not nullable): id to look for.
 *
 * Finds the entry registered under an id.
 *
 * Preconditions:
 *  - @self is a live WxRegistry; @id is NUL-terminated.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the entry is owned by the registry.
 *
 * Returns: (transfer none) (nullable): the entry registered under @id.
 */
static Entry *
find_entry(WxRegistry *self, const char *id)
{
  for (guint i = 0; i < self->entries->len; i++) {
    Entry *entry = g_ptr_array_index(self->entries, i);
    if (strcmp(entry->id, id) == 0)
      return entry;
  }
  return NULL;
}

/* Documented in wx-registry.h. */
gboolean
wx_registry_add_provider(WxRegistry *self, WxProvider *provider, GError **error)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), FALSE);
  g_return_val_if_fail(WX_IS_PROVIDER(provider), FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);

  const char *id = wx_provider_get_id(provider);
  if (!provider_id_is_valid(id)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid provider id");
    return FALSE;
  }
  if (find_entry(self, id) != NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG,
                        "a provider with this id is already registered");
    return FALSE;
  }
  if (self->entries->len >= WX_REGISTRY_MAX_PROVIDERS) {
    g_set_error(error, WX_ERROR, WX_ERROR_INVALID_ARG, "too many providers (limit %d)",
                WX_REGISTRY_MAX_PROVIDERS);
    return FALSE;
  }
  Entry *entry = g_new0(Entry, 1);
  entry->provider = g_object_ref(provider);
  entry->id = g_strdup(id);
  entry->enabled = TRUE;
  g_ptr_array_add(self->entries, entry);
  g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

/* Documented in wx-registry.h. */
WxProvider *
wx_registry_find_provider(WxRegistry *self, const char *id)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), NULL);
  g_return_val_if_fail(id != NULL, NULL);
  Entry *entry = find_entry(self, id);
  return entry != NULL ? entry->provider : NULL;
}

/* Documented in wx-registry.h. */
GPtrArray *
wx_registry_list_providers(WxRegistry *self)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), NULL);
  GPtrArray *list = g_ptr_array_sized_new(self->entries->len);
  for (guint i = 0; i < self->entries->len; i++)
    g_ptr_array_add(list, ((Entry *)g_ptr_array_index(self->entries, i))->provider);
  return list;
}

/* Documented in wx-registry.h. */
gboolean
wx_registry_set_enabled(WxRegistry *self, const char *id, gboolean enabled)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), FALSE);
  g_return_val_if_fail(id != NULL, FALSE);
  Entry *entry = find_entry(self, id);
  if (entry == NULL)
    return FALSE;
  enabled = enabled != FALSE;
  if (entry->enabled != enabled) {
    entry->enabled = enabled;
    g_signal_emit(self, signals[SIGNAL_CHANGED], 0);
  }
  return TRUE;
}

/* Documented in wx-registry.h. */
gboolean
wx_registry_is_enabled(WxRegistry *self, const char *id)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), FALSE);
  g_return_val_if_fail(id != NULL, FALSE);
  Entry *entry = find_entry(self, id);
  return entry != NULL && entry->enabled;
}

/* Documented in wx-registry.h. */
GPtrArray *
wx_registry_list_covering(WxRegistry *self, const WxPlace *place)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), NULL);
  g_return_val_if_fail(place != NULL, NULL);
  GPtrArray *list = g_ptr_array_new();
  /* Index based, re-reading the length: a covers() that adds a provider
   * cannot invalidate the walk (entries are heap blocks, the array may move). */
  for (guint i = 0; i < self->entries->len; i++) {
    Entry *entry = g_ptr_array_index(self->entries, i);
    if (entry->enabled && wx_provider_covers(entry->provider, place))
      g_ptr_array_add(list, entry->provider);
  }
  return list;
}

/* Documented in wx-registry.h. */
void
wx_registry_set_geocoder(WxRegistry *self, WxGeocoder *geocoder)
{
  g_return_if_fail(WX_IS_REGISTRY(self));
  g_return_if_fail(geocoder == NULL || WX_IS_GEOCODER(geocoder));
  g_set_object(&self->geocoder, geocoder);
}

/* Documented in wx-registry.h. */
WxGeocoder *
wx_registry_get_geocoder(WxRegistry *self)
{
  g_return_val_if_fail(WX_IS_REGISTRY(self), NULL);
  return self->geocoder;
}
