/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-provider.c - WxProvider and WxGeocoder interface dispatch. See wx-provider.h. */
#include "wx-provider.h"

G_DEFINE_INTERFACE(WxProvider, wx_provider, G_TYPE_OBJECT)
G_DEFINE_INTERFACE(WxGeocoder, wx_geocoder, G_TYPE_OBJECT)

/**
 * wx_provider_default_init:
 * @iface: (not nullable): the interface vtable being initialised by GObject.
 *
 * GObject interface default initialiser (installed by G_DEFINE_INTERFACE()).
 * The interface has no properties, signals or default implementations, so
 * nothing is done.
 *
 * Preconditions:
 *  - Called once by the GType system when the interface type is first used.
 * Postconditions:
 *  - @iface is untouched; every virtual function stays NULL until an
 *    implementation fills it in.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: none (@iface is owned by the type system and not retained).
 */
static void
wx_provider_default_init(WxProviderInterface *iface)
{
  (void)iface;
}

/**
 * wx_geocoder_default_init:
 * @iface: (not nullable): the interface vtable being initialised by GObject.
 *
 * GObject interface default initialiser (installed by G_DEFINE_INTERFACE()).
 * The interface has no properties, signals or default implementations, so
 * nothing is done.
 *
 * Preconditions:
 *  - Called once by the GType system when the interface type is first used.
 * Postconditions:
 *  - @iface is untouched; every virtual function stays NULL until an
 *    implementation fills it in.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: none (@iface is owned by the type system and not retained).
 */
static void
wx_geocoder_default_init(WxGeocoderInterface *iface)
{
  (void)iface;
}

/* Documented in wx-provider.h. */
const char *
wx_provider_get_id(WxProvider *self)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), NULL);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->get_id != NULL, NULL);
  return WX_PROVIDER_GET_IFACE(self)->get_id(self);
}

/* Documented in wx-provider.h. */
const char *
wx_provider_get_name(WxProvider *self)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), NULL);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->get_name != NULL, NULL);
  return WX_PROVIDER_GET_IFACE(self)->get_name(self);
}

/* Documented in wx-provider.h. */
const char *
wx_provider_get_attribution(WxProvider *self)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), NULL);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->get_attribution != NULL, NULL);
  return WX_PROVIDER_GET_IFACE(self)->get_attribution(self);
}

/* Documented in wx-provider.h. */
const char *
wx_provider_get_attribution_url(WxProvider *self)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), NULL);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->get_attribution_url != NULL, NULL);
  return WX_PROVIDER_GET_IFACE(self)->get_attribution_url(self);
}

/* Documented in wx-provider.h. */
gboolean
wx_provider_covers(WxProvider *self, const WxPlace *place)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), FALSE);
  g_return_val_if_fail(place != NULL, FALSE);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->covers != NULL, FALSE);
  return WX_PROVIDER_GET_IFACE(self)->covers(self, place);
}

/* Documented in wx-provider.h. */
void
wx_provider_fetch_async(WxProvider *self, const WxPlace *place, GCancellable *cancellable,
                        GAsyncReadyCallback callback, gpointer user_data)
{
  g_return_if_fail(WX_IS_PROVIDER(self));
  g_return_if_fail(place != NULL);
  g_return_if_fail(cancellable == NULL || G_IS_CANCELLABLE(cancellable));
  g_return_if_fail(WX_PROVIDER_GET_IFACE(self)->fetch_async != NULL);
  WX_PROVIDER_GET_IFACE(self)->fetch_async(self, place, cancellable, callback, user_data);
}

/* Documented in wx-provider.h. */
WxSourceResult *
wx_provider_fetch_finish(WxProvider *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_PROVIDER(self), NULL);
  g_return_val_if_fail(G_IS_ASYNC_RESULT(result), NULL);
  g_return_val_if_fail(WX_PROVIDER_GET_IFACE(self)->fetch_finish != NULL, NULL);
  return WX_PROVIDER_GET_IFACE(self)->fetch_finish(self, result, error);
}

/* Documented in wx-provider.h. */
void
wx_geocoder_search_async(WxGeocoder *self, const char *text, GCancellable *cancellable,
                         GAsyncReadyCallback callback, gpointer user_data)
{
  g_return_if_fail(WX_IS_GEOCODER(self));
  g_return_if_fail(text != NULL);
  g_return_if_fail(cancellable == NULL || G_IS_CANCELLABLE(cancellable));
  g_return_if_fail(WX_GEOCODER_GET_IFACE(self)->search_async != NULL);
  WX_GEOCODER_GET_IFACE(self)->search_async(self, text, cancellable, callback, user_data);
}

/* Documented in wx-provider.h. */
GPtrArray *
wx_geocoder_search_finish(WxGeocoder *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_GEOCODER(self), NULL);
  g_return_val_if_fail(G_IS_ASYNC_RESULT(result), NULL);
  g_return_val_if_fail(WX_GEOCODER_GET_IFACE(self)->search_finish != NULL, NULL);
  return WX_GEOCODER_GET_IFACE(self)->search_finish(self, result, error);
}
