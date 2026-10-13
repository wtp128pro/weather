/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-service.h - WxService: the forecast service. It fans one refresh out to
 * every enabled registered provider that covers the place, waits for all of
 * them or for a deadline, blends what arrived (wx-blend.h) into one WxForecast
 * with a per-source status, and runs place searches through the registry's
 * geocoder.
 *
 * Refresh, in order
 * -----------------
 *  1. If the caller's cancellable is already cancelled the result is
 *     G_IO_ERROR_CANCELLED and nothing else is done (no provider is called).
 *     Otherwise the place is validated by copying it (wx_place_copy()): a
 *     place that violates the wx_place_new() rules is WX_ERROR_INVALID_ARG,
 *     "invalid place"; no provider is called. (A NULL admin1, country or
 *     timezone of a hand-built place is accepted and becomes "".)
 *  2. wx_registry_list_covering() picks the enabled providers whose covers()
 *     accepts the place (covers() runs once per enabled provider, none for a
 *     disabled one); then wx_registry_list_providers() lists every provider
 *     (so a provider that a covers() added meanwhile is included). A
 *     provider whose id (wx_provider_get_id(), read now) is not a valid
 *     source id (wx_id_is_valid()) cannot be reported and is ignored: it is
 *     neither fetched nor listed. If no provider is left in the covering
 *     list the result is WX_ERROR_UNSUPPORTED, "no enabled data source covers
 *     this place"; no provider is fetched.
 *  3. wx_provider_fetch_async() is started on EVERY covering provider, one
 *     after the other, before the main loop runs again (all are in flight at
 *     once), each with the same private GCancellable: the caller's
 *     cancellable is never handed to a provider and the deadline never
 *     cancels it. The deadline WX_SERVICE_DEADLINE_MS runs from the call of
 *     wx_service_refresh_async().
 *  4. The operation completes as soon as every started fetch has called back,
 *     or when the deadline expires (the providers that have not answered are
 *     cancelled through the private cancellable and are NOT waited for: a
 *     provider that ignores cancellation or never answers cannot delay the
 *     result; whatever it delivers later is released and never used), or
 *     when the caller's cancellable is cancelled (the same, and the result is
 *     G_IO_ERROR_CANCELLED). The results that arrived are reduced to the
 *     members described under "Members handed to the blend" and blended,
 *     the providers in REGISTRATION order whatever the order of arrival. The
 *     source ids of the members decide their weights; they are not compared
 *     with the id of the provider that returned them.
 *
 * Members handed to the blend
 * ---------------------------
 * wx_blend_forecast() takes at most WX_BLEND_MAX_MEMBERS (128) distinct
 * members, the first valid ones in its argument order, and a valid member
 * without any hour counts like any other. A provider's answer handed over as
 * it came would let one provider (hundreds of members, or members without
 * data) push every later provider out of the forecast. So the service
 * chooses what the blend gets from the providers that answered successfully,
 * in registration order:
 *  1. Usable. A member is usable iff the blend would let it take part AND it
 *     has data the blend can use. The first is the blend's own rule
 *     (member_is_valid() in wx-blend.c, private to the blend and mirrored
 *     here): non-NULL; source_id and model_id satisfy wx_id_is_valid();
 *     n_hours <= WX_MEMBER_MAX_HOURS and a non-NULL hours array when n_hours
 *     > 0; every hour stamp in [WX_TIME_MIN_S, WX_TIME_MAX_S), a multiple of
 *     3600 and strictly greater than the stamp before. The second is: n_hours
 *     > 0, or a non-NULL quarters array with 1..WX_MEMBER_MAX_QUARTERS entries
 *     (the guard the blend applies before it reads the quarters of member
 *     open-meteo:hrrr15, the only quarters it reads; the entries themselves
 *     are not examined here). Every other member, a NULL entry included, is
 *     dropped: it is neither forwarded nor counted.
 *  2. Distinct. A usable member whose (source_id, model_id) pair occurred
 *     earlier (earlier in its own provider's answer, or anywhere in the
 *     answer of a provider registered before) is dropped: the first one wins,
 *     like in the blend, and a dropped duplicate stays dropped even when the
 *     member it duplicates does not get past step 3. A member dropped by step
 *     1 is no earlier occurrence: it shadows nothing (the blend alone would
 *     let a valid member without data shadow a later member with the same
 *     ids).
 *  3. Share. When at most WX_BLEND_MAX_MEMBERS members remain, all are
 *     forwarded. Otherwise they are dealt round-robin, one member at a time,
 *     in registration order, each provider's in its own order: the first
 *     member of every provider that has one, then the second of every
 *     provider that still has one, and so on, until WX_BLEND_MAX_MEMBERS have
 *     been dealt. A provider thus has a prefix of its distinct usable members
 *     forwarded, and every provider that has any has at least one (the
 *     registry takes at most WX_REGISTRY_MAX_PROVIDERS <=
 *     WX_BLEND_MAX_MEMBERS providers).
 * The blend gets one result per provider that has a member forwarded, in
 * registration order, holding exactly those members in their own order; it
 * takes them all. It may still not use a forwarded member (for example one
 * with too few hours).
 *
 * Per-source status (WxForecast.sources, one entry per listed provider, in
 * registration order, at most WX_FORECAST_MAX_SOURCES). id, name, attribution
 * and attribution URL are those of the provider read in step 2 and validated
 * by wx_source_status_new() (name and attribution sanitised); an attribution
 * URL that is rejected is replaced by "" (no link) and the other fields are
 * kept.
 *  - disabled, or not in the covering list: WX_SRC_SKIPPED, error_code -1,
 *    n_members 0; the provider is not called.
 *  - fetch failed with WX_ERROR_UNSUPPORTED (the provider learned from its
 *    server that it does not cover the place): WX_SRC_SKIPPED, -1, 0.
 *  - fetch ended with G_IO_ERROR_CANCELLED reported by the provider itself:
 *    WX_SRC_FAILED, -1, 0.
 *  - fetch failed with another WX_ERROR code: WX_SRC_FAILED, that code, 0. An
 *    error of another domain, or of the WX_ERROR domain with a code that is
 *    not a WxError value (the interface forbids both), counts as
 *    WX_ERROR_NETWORK.
 *  - no answer before the deadline: WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0.
 *  - success with at least one usable member: WX_SRC_OK, -1, n_members = the
 *    number of this provider's members forwarded to the blend (step 3 above;
 *    members dropped as duplicates or cut by the share are not counted, so an
 *    OK provider whose usable members all duplicate earlier ones has
 *    n_members 0). It is the number handed to the blend, not the number the
 *    blend used.
 *  - success without a usable member, or a NULL result without an error (the
 *    interface forbids it): WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0.
 *
 * Result. The refresh succeeds iff at least one provider is OK and the blend
 * succeeds (the first OK provider in registration order always has a member
 * forwarded); the forecast is the blend's (wx_blend_forecast() with now = the
 * current time when the operation completes, so generated_s is that time;
 * the blend is not called when no provider is OK). Otherwise there is no
 * forecast and the error is, in this order:
 *  - the caller's cancellable was cancelled before wx_service_refresh_finish()
 *    ran: G_IO_ERROR / G_IO_ERROR_CANCELLED (even if the refresh had
 *    succeeded, like the provider interface);
 *  - no provider is OK and every covering provider ended with
 *    G_IO_ERROR_CANCELLED reported by itself: G_IO_ERROR_CANCELLED;
 *  - else the most informative WX_ERROR among the failures of the covering
 *    providers (those that are neither OK nor cancelled; a provider that
 *    answered UNSUPPORTED counts) and, when some provider was OK, the blend's
 *    own error (wx_blend_forecast(): WX_ERROR_NOT_FOUND "no usable forecast
 *    data" when the members cannot make a forecast). Ranked best first:
 *    WX_ERROR_NETWORK = WX_ERROR_TIMEOUT, then WX_ERROR_RATE_LIMITED,
 *    WX_ERROR_HTTP, WX_ERROR_PARSE, WX_ERROR_NOT_FOUND, WX_ERROR_UNSUPPORTED,
 *    WX_ERROR_INVALID_ARG, and last a provider's LOCAL REFUSAL: a
 *    WX_ERROR_RATE_LIMITED whose message begins "a request for this place was
 *    sent less than 10 minutes ago" (the per-place floor of MET Norway) or
 *    "too many outstanding requests" (the cap on requests in flight), which a
 *    provider gives without any network traffic. It says nothing about a
 *    server, so it never outranks another failure (the blend's own error
 *    included); when it is all that remains the refresh fails with
 *    WX_ERROR_NOT_FOUND (not WX_ERROR_RATE_LIMITED, which the application
 *    answers with a cool-down) and the message "<provider id>: <its
 *    message>". The provider's own status keeps WX_ERROR_RATE_LIMITED. A rate
 *    limit announced by a server (HTTP 429, or a pause a provider keeps after
 *    one) keeps the rank of WX_ERROR_RATE_LIMITED. Among equal ranks the
 *    provider registered first wins (and a provider beats the blend). The
 *    message of a provider's
 *    error is "<provider id>: <its message>" (the message sanitised by
 *    wx_sanitize_text(), at most 200 bytes); the message of the deadline
 *    error is "<provider id>: no answer within <deadline> ms"; the blend's
 *    message is its own.
 * The service itself reports only the WX_ERROR domain and
 * G_IO_ERROR_CANCELLED.
 *
 * Search. If the caller's cancellable is already cancelled the result is
 * G_IO_ERROR_CANCELLED and the geocoder is not called. Otherwise
 * wx_service_search_async() delegates to the registry's geocoder (the text
 * and the caller's cancellable are passed on unchanged; the geocoder's own
 * text rules apply). Its places are copied through wx_place_copy(): anything
 * that is not a valid place (NULL included) is dropped and at most
 * WX_GEOCODER_MAX_HITS are returned. A failure of another domain than
 * WX_ERROR / G_IO_ERROR_CANCELLED, or with a WX_ERROR code that is not a
 * WxError value, counts as WX_ERROR_NETWORK; messages are sanitised as for
 * a refresh but carry no prefix. A NULL answer without an error is
 * WX_ERROR_NOT_FOUND. No geocoder: WX_ERROR_UNSUPPORTED, "no geocoder is
 * registered".
 *
 * Contract shared by both operations: the *_async functions and the *_finish
 * functions must be used from the thread that runs the GLib main context
 * (normally the main thread); only a GCancellable may be cancelled from any
 * thread. The callback is invoked exactly once, in the thread-default main
 * context of the caller, and never before the *_async function has returned
 * (unless a provider or geocoder runs that main context inside its own
 * *_async call, which the provider interface forbids: nothing may block). An
 * operation keeps the service alive until its callback has returned, so
 * dropping the last reference in flight (or running g_object_run_dispose())
 * does not disturb it. The service keeps its own reference to the registry.
 */
#ifndef WX_SERVICE_H
#define WX_SERVICE_H

#include <gio/gio.h>

#include "wx-registry.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** Overall deadline of one refresh, in milliseconds, counted from the call. */
#define WX_SERVICE_DEADLINE_MS 30000

#define WX_TYPE_SERVICE (wx_service_get_type())
G_DECLARE_FINAL_TYPE(WxService, wx_service, WX, SERVICE, GObject)

/**
 * wx_service_new:
 * @registry: the registry of data sources and the geocoder.
 *
 * Creates a service over @registry. The registry is consulted at the start of
 * every operation, so providers added, enabled or disabled later take effect
 * with the next one.
 *
 * Preconditions:
 *  - @registry satisfies WX_IS_REGISTRY() (violation: critical, NULL).
 * Postconditions:
 *  - the service holds its own reference to @registry.
 * Thread affinity: main thread only.
 * Ownership: the service takes a reference to @registry; the caller keeps its
 *   own and owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the service; NULL if @registry is not a
 *   WxRegistry.
 */
WxService *wx_service_new(WxRegistry *registry);

/**
 * wx_service_refresh_async:
 * @self: a WxService.
 * @place: the place to forecast; copied (see the file comment, step 1).
 * @cancellable: (nullable): cancels the refresh.
 * @callback: invoked once, in the thread-default main context of the caller.
 * @user_data: passed to @callback.
 *
 * Starts a refresh as described in the file comment.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_SERVICE(); @place is non-NULL (its content may be
 *    anything: a place that breaks the wx_place_new() rules is reported
 *    through the callback, not as a critical); @cancellable is NULL or a
 *    GCancellable (violation: critical, nothing is started and @callback is
 *    never called).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - @callback is invoked exactly once, later, with the result to pass to
 *    wx_service_refresh_finish(); every failure, including an invalid place,
 *    no covering provider and a cancellable that is already cancelled, is
 *    reported through it.
 *  - a provider that was told to stop (deadline, cancellation) may still
 *    deliver after @callback has run; that delivery is released and never
 *    used.
 * Thread affinity: main thread only.
 * Ownership: @place is copied; the operation holds references to @self and
 *   @cancellable; @user_data is not owned and must stay valid until
 *   @callback has run.
 */
void wx_service_refresh_async(WxService *self, const WxPlace *place, GCancellable *cancellable,
                              GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_service_refresh_finish:
 * @self: the service passed to wx_service_refresh_async().
 * @result: the GAsyncResult given to the callback.
 * @error: (nullable): return location for a GError.
 *
 * Collects the result of wx_service_refresh_async().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_SERVICE(); @result is the result handed to the
 *    callback of a refresh started on @self and is finished at most once
 *    (violation: critical, NULL; a result of wx_service_search_async() is
 *    such a violation).
 *  - @error is NULL or points to a NULL GError* (violation: critical, NULL,
 *    the result is not consumed).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - on success *@error is untouched; on failure NULL is returned and, if
 *    @error is non-NULL, *@error is set (WX_ERROR domain, or
 *    G_IO_ERROR_CANCELLED; see the file comment for which).
 * Thread affinity: main thread only.
 * Ownership: @self and @result stay with the caller; the forecast is returned
 *   to the caller.
 *
 * Returns: (transfer full) (nullable): the blended forecast, release with
 *   wx_forecast_unref(); NULL with @error set on failure.
 */
WxForecast *wx_service_refresh_finish(WxService *self, GAsyncResult *result, GError **error);

/**
 * wx_service_search_async:
 * @self: a WxService.
 * @text: non-NULL search text; passed to the geocoder, which copies it.
 * @cancellable: (nullable): cancels the search.
 * @callback: invoked once, in the thread-default main context of the caller.
 * @user_data: passed to @callback.
 *
 * Starts a place search through the registry's geocoder (the one set when
 * this function is called) as described in the file comment.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_SERVICE(); @text is a non-NULL NUL-terminated
 *    string; @cancellable is NULL or a GCancellable (violation: critical,
 *    nothing is started and @callback is never called).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - @callback is invoked exactly once, later, with the result to pass to
 *    wx_service_search_finish(); a missing geocoder and a geocoder's refusal
 *    of the text are reported through it.
 * Thread affinity: main thread only.
 * Ownership: the operation holds references to @self and @cancellable and
 *   keeps the geocoder alive while it calls it; @user_data is not owned and
 *   must stay valid until @callback has run.
 */
void wx_service_search_async(WxService *self, const char *text, GCancellable *cancellable,
                             GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_service_search_finish:
 * @self: the service passed to wx_service_search_async().
 * @result: the GAsyncResult given to the callback.
 * @error: (nullable): return location for a GError.
 *
 * Collects the result of wx_service_search_async().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_SERVICE(); @result is the result handed to the
 *    callback of a search started on @self and is finished at most once
 *    (violation: critical, NULL; a result of wx_service_refresh_async() is
 *    such a violation).
 *  - @error is NULL or points to a NULL GError* (violation: critical, NULL,
 *    the result is not consumed).
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - on success *@error is untouched; on failure NULL is returned and, if
 *    @error is non-NULL, *@error is set (WX_ERROR domain, or
 *    G_IO_ERROR_CANCELLED). If the caller's cancellable was cancelled before
 *    this call the result is G_IO_ERROR_CANCELLED even if the search had
 *    succeeded.
 * Thread affinity: main thread only.
 * Ownership: @self and @result stay with the caller; the array is returned to
 *   the caller.
 *
 * Returns: (transfer full) (nullable) (element-type WxPlace): at most
 *   WX_GEOCODER_MAX_HITS valid places in the geocoder's order (possibly none),
 *   freed by the array's free function wx_place_free(); release with
 *   g_ptr_array_unref(). NULL with @error set on failure.
 */
GPtrArray *wx_service_search_finish(WxService *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_SERVICE_H */
