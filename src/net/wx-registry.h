/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-registry.h - WxRegistry: the extension point for weather data sources.
 *
 * The registry owns the list of WxProvider instances (in registration order),
 * a per-provider "enabled" flag and at most one WxGeocoder. Adding a data
 * source to the app is exactly: implement WxProvider, call
 * wx_registry_add_provider() once where the application builds its registry,
 * add fixtures and tests. There is no removal: providers live as long as the
 * registry, so the pointers handed out by the query functions stay valid until
 * the registry is finalized (there is no dispose override: after
 * g_object_run_dispose() the registry keeps its providers and works as before).
 *
 * The "changed" signal is emitted after the registry state has been updated,
 * only when the set of providers or an enabled flag really changed (a
 * geocoder change does not count). A handler may call any registry function.
 *
 * A registry is a main-thread object: every function, the signal emission and
 * the handlers run in the thread that runs the GLib main context; it is not
 * thread-safe.
 */
#ifndef WX_REGISTRY_H
#define WX_REGISTRY_H

#include <glib-object.h>

#include "wx-provider.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** Most providers one registry accepts. */
#define WX_REGISTRY_MAX_PROVIDERS 16

#define WX_TYPE_REGISTRY (wx_registry_get_type())
G_DECLARE_FINAL_TYPE(WxRegistry, wx_registry, WX, REGISTRY, GObject)

/**
 * wx_registry_new:
 *
 * Creates an empty registry (no providers, no geocoder).
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the registry has no provider and no geocoder.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the new registry.
 */
WxRegistry *wx_registry_new(void);

/**
 * wx_registry_add_provider:
 * @self: a WxRegistry.
 * @provider: the provider to register.
 * @error: (nullable): return location for a #GError.
 *
 * Registers @provider, enabled, after the providers already present. The
 * provider's id (wx_provider_get_id(), read once here) must match
 * [a-z0-9][a-z0-9_-]{0,31}: 1..WX_ID_MAX bytes, starting with a lower-case
 * letter or digit, no dot, so it can serve as a source id (WxMember), a
 * settings key and a file-name component.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(), @provider satisfies WX_IS_PROVIDER()
 *    and implements get_id (violation: critical, FALSE).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on TRUE the registry holds its own reference to @provider, which is last
 *    in wx_registry_list_providers() order and enabled, and "changed" has
 *    been emitted once.
 *  - on FALSE nothing changed, no signal was emitted and *@error (when
 *    non-NULL) is WX_ERROR/WX_ERROR_INVALID_ARG: invalid id, id already
 *    registered (this instance or another), or WX_REGISTRY_MAX_PROVIDERS
 *    already registered. These are reported, not asserted.
 * Thread affinity: main thread only.
 * Ownership: the registry takes its own reference; the caller keeps its own.
 *
 * Returns: TRUE if @provider was registered.
 */
gboolean wx_registry_add_provider(WxRegistry *self, WxProvider *provider, GError **error);

/**
 * wx_registry_find_provider:
 * @self: a WxRegistry.
 * @id: provider id to look for (any text; it is only compared).
 *
 * Looks up a registered provider by its id.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(); @id is non-NULL (violation: critical,
 *    NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the result is borrowed from the registry (valid for its life).
 *
 * Returns: (transfer none) (nullable): the provider registered under @id, or
 *   NULL when none is.
 */
WxProvider *wx_registry_find_provider(WxRegistry *self, const char *id);

/**
 * wx_registry_list_providers:
 * @self: a WxRegistry.
 *
 * Lists every registered provider, enabled or not.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY() (violation: critical, NULL).
 * Postconditions:
 *  - nothing is modified; the array is a snapshot (later additions do not
 *    change it).
 * Thread affinity: main thread only.
 * Ownership: the caller owns the container (g_ptr_array_unref()); the
 *   elements are borrowed from the registry and not referenced.
 *
 * Returns: (transfer container) (element-type WxProvider): every provider,
 *   enabled or not, in registration order (empty when there is none).
 */
GPtrArray *wx_registry_list_providers(WxRegistry *self);

/**
 * wx_registry_set_enabled:
 * @self: a WxRegistry.
 * @id: provider id (any text).
 * @enabled: the new state.
 *
 * Enables or disables the provider registered under @id. A disabled provider
 * stays registered but is skipped by wx_registry_list_covering().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(); @id is non-NULL (violation: critical,
 *    FALSE).
 * Postconditions:
 *  - for a known id the provider's flag equals @enabled, and "changed" has
 *    been emitted once if and only if the flag differed before.
 *  - for an unknown id nothing changed and no signal was emitted.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff a provider is registered under @id (whether or not its
 *   flag changed); FALSE for an unknown id.
 */
gboolean wx_registry_set_enabled(WxRegistry *self, const char *id, gboolean enabled);

/**
 * wx_registry_is_enabled:
 * @self: a WxRegistry.
 * @id: provider id (any text).
 *
 * Tells whether a provider is registered and enabled.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(); @id is non-NULL (violation: critical,
 *    FALSE).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff a provider is registered under @id and enabled (new
 *   providers are enabled); FALSE for a disabled or an unknown id.
 */
gboolean wx_registry_is_enabled(WxRegistry *self, const char *id);

/**
 * wx_registry_list_covering:
 * @self: a WxRegistry.
 * @place: the place to cover.
 *
 * Lists the providers that are enabled and whose wx_provider_covers() accepts
 * @place (no I/O).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(); @place is non-NULL (violation:
 *    critical, NULL). A covers() implementation may call back into the
 *    registry; a provider it adds meanwhile is visited as well (it is last).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the container (g_ptr_array_unref()); the
 *   elements are borrowed from the registry and not referenced.
 *
 * Returns: (transfer container) (element-type WxProvider): the matching
 *   providers in registration order (empty when none matches).
 */
GPtrArray *wx_registry_list_covering(WxRegistry *self, const WxPlace *place);

/**
 * wx_registry_set_geocoder:
 * @self: a WxRegistry.
 * @geocoder: (nullable): the geocoder to use, or NULL for none.
 *
 * Sets, replaces or clears the geocoder.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY(); @geocoder is NULL or satisfies
 *    WX_IS_GEOCODER() (violation: critical, nothing changes).
 * Postconditions:
 *  - wx_registry_get_geocoder() returns @geocoder; the registry holds its own
 *    reference (the previous geocoder's reference is dropped). No "changed"
 *    signal is emitted.
 * Thread affinity: main thread only.
 * Ownership: the registry takes its own reference; the caller keeps its own.
 */
void wx_registry_set_geocoder(WxRegistry *self, WxGeocoder *geocoder);

/**
 * wx_registry_get_geocoder:
 * @self: a WxRegistry.
 *
 * Returns the geocoder.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_REGISTRY() (violation: critical, NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the result is borrowed; it stays valid until the next
 *   wx_registry_set_geocoder() or the registry's last unref.
 *
 * Returns: (transfer none) (nullable): the geocoder, or NULL when none is set.
 */
WxGeocoder *wx_registry_get_geocoder(WxRegistry *self);

G_END_DECLS

#endif /* WX_REGISTRY_H */
