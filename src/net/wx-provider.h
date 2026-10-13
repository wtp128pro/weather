/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-provider.h - WxProvider and WxGeocoder: the only network surface of the
 * weather app.
 *
 * Two GObject interfaces with GIO-style asynchronous operations. A WxProvider
 * turns one place into forecast members (one data source: NWS, Open-Meteo,
 * MET Norway ...); a WxGeocoder turns user text into places. Every other
 * module obtains weather data exclusively through these interfaces, and a new
 * data source is added by writing another implementation and registering it
 * (wx-registry.h). Implementations reach the network only through WxHttp
 * (wx-http.h) and parse bodies only through wx-json.
 *
 * Contract shared by all operations
 * ---------------------------------
 *  - Call the *_async functions from the thread that runs the GLib main
 *    context (normally the main thread). They never block: all I/O is
 *    asynchronous and the callback runs in the thread-default main context
 *    that was current at the call.
 *  - The callback is never invoked before the *_async function has returned,
 *    even when the arguments are rejected immediately.
 *  - Invalid arguments (a place that violates the wx_place_new() rules, text
 *    that is not acceptable) are reported through the callback, not as a
 *    programming-error critical, with WX_ERROR_INVALID_ARG and without any
 *    network traffic.
 *  - A place the provider does not cover is reported as WX_ERROR_UNSUPPORTED,
 *    again without network traffic (a provider that can only learn this from
 *    the server, e.g. an HTTP 404, reports it after its request).
 *  - Failures are reported in the WX_ERROR domain (WX_ERROR_NETWORK,
 *    _TIMEOUT, _HTTP, _RATE_LIMITED, _PARSE, _NOT_FOUND, _INVALID_ARG,
 *    _UNSUPPORTED). Cancellation is the only exception: it is reported as
 *    G_IO_ERROR / G_IO_ERROR_CANCELLED. If the cancellable is cancelled
 *    before the *_finish function is called, *_finish reports
 *    G_IO_ERROR_CANCELLED even if the operation had already succeeded.
 *  - The caller owns the results (transfer full); the implementation keeps no
 *    reference to them. An implementation keeps itself alive until every
 *    operation it started has completed, so dropping the last caller
 *    reference while an operation is in flight is safe.
 *  - The members of a WxSourceResult follow the normalisation contract of the
 *    design (hour buckets keyed by interval start in UTC, values range
 *    checked, units degC / km/h / mm / percent); wx_member_add_hour() and
 *    wx_member_add_quarter() enforce the invariants.
 */
#ifndef WX_PROVIDER_H
#define WX_PROVIDER_H

#include <gio/gio.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Most places a WxGeocoder returns from one search. */
#define WX_GEOCODER_MAX_HITS 20

#define WX_TYPE_PROVIDER (wx_provider_get_type())
G_DECLARE_INTERFACE(WxProvider, wx_provider, WX, PROVIDER, GObject)

/**
 * WxProviderInterface:
 * @get_id: constant provider id, wx_id_is_valid() and without '.' (the registry
 *   refuses anything else); the same string for the whole life of the instance.
 * @get_name: human readable source name, e.g. "National Weather Service".
 * @get_attribution: credit line, e.g. "Weather data by Open-Meteo.com".
 * @get_attribution_url: https URL of the credit link.
 * @covers: cheap predicate, no I/O: may this provider answer for the place?
 * @fetch_async: see wx_provider_fetch_async().
 * @fetch_finish: see wx_provider_fetch_finish().
 *
 * Every virtual function is mandatory. The dispatch functions check that the
 * implementation filled in the one they need and, if not, report a
 * g_return_*_if_fail() critical and do nothing. The four text functions return
 * NUL-terminated strings owned by the instance, valid UTF-8, never NULL, and
 * constant for the life of the instance.
 */
struct _WxProviderInterface {
  GTypeInterface parent_iface;

  const char *(*get_id)(WxProvider *self);
  const char *(*get_name)(WxProvider *self);
  const char *(*get_attribution)(WxProvider *self);
  const char *(*get_attribution_url)(WxProvider *self);
  gboolean (*covers)(WxProvider *self, const WxPlace *place);
  void (*fetch_async)(WxProvider *self, const WxPlace *place, GCancellable *cancellable,
                      GAsyncReadyCallback callback, gpointer user_data);
  WxSourceResult *(*fetch_finish)(WxProvider *self, GAsyncResult *result, GError **error);
};

/**
 * wx_provider_get_id:
 * @self: a WxProvider.
 *
 * Returns the constant id of the provider.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements get_id (violation:
 *    critical, NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: the string is owned by @self; do not free.
 *
 * Returns: (transfer none): the provider id.
 */
const char *wx_provider_get_id(WxProvider *self);

/**
 * wx_provider_get_name:
 * @self: a WxProvider.
 *
 * Returns the human readable name of the provider.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements get_name (violation:
 *    critical, NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: the string is owned by @self; do not free.
 *
 * Returns: (transfer none): the human readable name.
 */
const char *wx_provider_get_name(WxProvider *self);

/**
 * wx_provider_get_attribution:
 * @self: a WxProvider.
 *
 * Returns the credit line of the provider.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements get_attribution
 *    (violation: critical, NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: the string is owned by @self; do not free.
 *
 * Returns: (transfer none): the credit line.
 */
const char *wx_provider_get_attribution(WxProvider *self);

/**
 * wx_provider_get_attribution_url:
 * @self: a WxProvider.
 *
 * Returns the URL of the provider's credit link.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements get_attribution_url
 *    (violation: critical, NULL).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: the string is owned by @self; do not free.
 *
 * Returns: (transfer none): the https URL of the credit link.
 */
const char *wx_provider_get_attribution_url(WxProvider *self);

/**
 * wx_provider_covers:
 * @self: a WxProvider.
 * @place: place to test.
 *
 * Cheap coverage test, no I/O. A TRUE answer is a pre-filter (the server may
 * still say the place is not covered); FALSE means a fetch would be refused.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements covers; @place is
 *    non-NULL (violation: critical, FALSE).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: nothing is retained; @place stays with the caller.
 *
 * Returns: whether the provider answers for @place.
 */
gboolean wx_provider_covers(WxProvider *self, const WxPlace *place);

/**
 * wx_provider_fetch_async:
 * @self: a WxProvider.
 * @place: non-NULL place; copied. A place that violates the wx_place_new()
 *   rules is reported as WX_ERROR_INVALID_ARG through the callback.
 * @cancellable: (nullable): cancels the operation.
 * @callback: invoked once, in the thread-default main context of the caller.
 * @user_data: passed to @callback.
 *
 * Starts fetching the forecast members of @place.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements fetch_async; @place is
 *    non-NULL; @cancellable is NULL or a GCancellable (violation: critical,
 *    nothing is started).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - @callback is invoked exactly once, later, in the thread-default main
 *    context of the caller, with the result to pass to
 *    wx_provider_fetch_finish(); bad arguments and uncovered places are
 *    reported through it (see the file comment).
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: @place is copied by the implementation; the implementation takes
 *   its own references to @self and @cancellable as it needs them; @user_data
 *   is not owned or freed here and must stay valid until @callback has run.
 */
void wx_provider_fetch_async(WxProvider *self, const WxPlace *place, GCancellable *cancellable,
                             GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_provider_fetch_finish:
 * @self: the provider passed to the async call.
 * @result: the GAsyncResult given to the callback.
 * @error: (nullable): return location for a GError.
 *
 * Collects the result of wx_provider_fetch_async().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_PROVIDER() and implements fetch_finish; @result
 *    satisfies G_IS_ASYNC_RESULT() and is the result handed to the callback
 *    of a fetch started on @self; it is finished at most once (violation:
 *    critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - on success *@error is untouched and the result is returned; on failure
 *    NULL is returned and, if @error is non-NULL, *@error is set (WX_ERROR
 *    domain, or G_IO_ERROR_CANCELLED).
 * Thread affinity: main thread only.
 * Ownership: @self and @result stay with the caller; the result is returned
 *   to the caller.
 *
 * Returns: (transfer full) (nullable): the members of one provider, possibly
 *   none; release with wx_source_result_free(). NULL with @error set on
 *   failure.
 */
WxSourceResult *wx_provider_fetch_finish(WxProvider *self, GAsyncResult *result, GError **error);

#define WX_TYPE_GEOCODER (wx_geocoder_get_type())
G_DECLARE_INTERFACE(WxGeocoder, wx_geocoder, WX, GEOCODER, GObject)

/**
 * WxGeocoderInterface:
 * @search_async: see wx_geocoder_search_async().
 * @search_finish: see wx_geocoder_search_finish().
 *
 * Every virtual function is mandatory (see WxProviderInterface).
 */
struct _WxGeocoderInterface {
  GTypeInterface parent_iface;

  void (*search_async)(WxGeocoder *self, const char *text, GCancellable *cancellable,
                       GAsyncReadyCallback callback, gpointer user_data);
  GPtrArray *(*search_finish)(WxGeocoder *self, GAsyncResult *result, GError **error);
};

/**
 * wx_geocoder_search_async:
 * @self: a WxGeocoder.
 * @text: non-NULL free text typed by the user; copied. An implementation
 *   reports text it cannot use (too short, too long, invalid UTF-8, control
 *   characters) as WX_ERROR_INVALID_ARG or, where documented by it, as an
 *   empty result, without network traffic.
 * @cancellable: (nullable): cancels the operation.
 * @callback: invoked once, in the thread-default main context of the caller.
 * @user_data: passed to @callback.
 *
 * Starts a place search.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_GEOCODER() and implements search_async; @text is
 *    a non-NULL NUL-terminated string; @cancellable is NULL or a
 *    GCancellable (violation: critical, nothing is started).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - @callback is invoked exactly once, later, in the thread-default main
 *    context of the caller, with the result to pass to
 *    wx_geocoder_search_finish().
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: @text is copied by the implementation; the implementation takes
 *   its own references to @self and @cancellable as it needs them; @user_data
 *   is not owned or freed here and must stay valid until @callback has run.
 */
void wx_geocoder_search_async(WxGeocoder *self, const char *text, GCancellable *cancellable,
                              GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_geocoder_search_finish:
 * @self: the geocoder passed to the async call.
 * @result: the GAsyncResult given to the callback.
 * @error: (nullable): return location for a GError.
 *
 * Collects the result of wx_geocoder_search_async().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_GEOCODER() and implements search_finish; @result
 *    satisfies G_IS_ASYNC_RESULT() and is the result handed to the callback
 *    of a search started on @self; it is finished at most once (violation:
 *    critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - on success *@error is untouched; on failure NULL is returned and, if
 *    @error is non-NULL, *@error is set (WX_ERROR domain, or
 *    G_IO_ERROR_CANCELLED).
 * Thread affinity: main thread only.
 * Ownership: @self and @result stay with the caller; the array is returned
 *   to the caller.
 *
 * Returns: (transfer full) (nullable) (element-type WxPlace): at most
 *   WX_GEOCODER_MAX_HITS places in the geocoder's order (possibly none), each
 *   freed by the array's free function wx_place_free(); release with
 *   g_ptr_array_unref(). NULL with @error set on failure.
 */
GPtrArray *wx_geocoder_search_finish(WxGeocoder *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_PROVIDER_H */
