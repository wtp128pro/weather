/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-metno.h - WxMetno: WxProvider backed by the MET Norway locationforecast
 * 2.0 "complete" API (https://api.met.no). Read-only GETs over HTTPS (plain
 * HTTP only towards loopback hosts, for tests), no API key, account or
 * cookie. All I/O goes through one WxHttp instance (wx-http.h), so every
 * transport rule of that module (host pinning, redirects refused, body cap,
 * time-outs, retries of network errors / time-outs / 5xx, status mapping
 * 404 -> WX_ERROR_NOT_FOUND, 429 -> WX_ERROR_RATE_LIMITED, other failures ->
 * WX_ERROR_HTTP, cancellation) applies unchanged.
 *
 * Identity: id "met-no", name "MET Norway", attribution "Data from MET
 * Norway", attribution URL "https://api.met.no/". The service covers every
 * place with valid coordinates (wx_geo_valid()).
 *
 * Request
 * -------
 * One GET per refresh: wx_metno_forecast_path(), i.e.
 *   /weatherapi/locationforecast/2.0/complete?lat=<%.4f>&lon=<%.4f>
 * The coordinates are printed with exactly four decimals (MET Norway answers
 * 403 for more), with a '.' decimal point whatever the locale, and "-0.0000"
 * is printed "0.0000". The User-Agent is WX_METNO_USER_AGENT (the service
 * requires an identifying one), Accept is "application/json", and an
 * If-Modified-Since header carries the Last-Modified value of the cached
 * answer when there is one.
 *
 * Polite caching (per place, in memory)
 * -------------------------------------
 * A place is identified by its two coordinate strings above (the "%.4f"
 * text, which ROUNDS the coordinates to four decimals): places whose strings
 * are identical share one entry, one request record and one request, places
 * whose strings differ are different places - with the same longitude,
 * the latitudes 25.76170 and 25.76174 are the same place (both print 25.7617),
 * 25.76176 is another one (it prints 25.7618). At most
 * WX_METNO_CACHE_MAX places are kept in the cache, and at most as many request
 * records (below).
 *
 * An entry is made by every successful answer (HTTP 200 with a usable body,
 * or 304) and records the parsed member, the validated Last-Modified text,
 * the validated Expires time (see wx_http_parse_expires(); absent or
 * implausible means none) and the time of that answer. A fetch is answered
 * from the entry WITHOUT any network traffic - with the very same WxMember
 * object, whose fetched_s is the time its data was downloaded - while the
 * entry is fresh, that is while
 *  - fewer than WX_METNO_MIN_REFRESH_S seconds (600) have passed since the
 *    entry's last successful answer, or
 *  - the current time is before the entry's Expires time; an Expires time is
 *    never honoured for longer than 24 hours after the answer that carried
 *    it.
 * Time is the system clock in UTC seconds (g_get_real_time()); an entry
 * whose answer lies in the future of the clock (the clock moved backwards)
 * is not fresh. A stale entry is revalidated: the request carries its
 * If-Modified-Since when the entry has a Last-Modified text, a 304 answer
 * returns the cached member again (fetched_s unchanged) and renews the entry
 * (also when the entry was evicted meanwhile), a 200 answer replaces it. A
 * failed request (any error, a cancelled one included) changes no entry and
 * is never answered from the cache by itself: the error is reported. When
 * the cache is full, the entry used least recently (stored or served) is
 * dropped.
 *
 * Floor between requests: the provider records, per place, the clock reading
 * at which it last handed a request to WxHttp - whatever became of that
 * request: answered, failed (HTTP error, time-out, network error, unusable
 * body, after WxHttp's retries) or cancelled afterwards (WxHttp may already
 * have contacted the service, so a started request always counts). A fetch
 * that is refused before a request was started (invalid place, cancelled
 * cancellable, a fresh entry, joining a request, the floor itself, the
 * throttle or the cap below) records nothing. No new request for a place is
 * sent while fewer than WX_METNO_MIN_REFRESH_S seconds (600) have passed
 * since its record: a fetch of that place that finds no fresh entry and does
 * not join a request in flight is answered from the entry - the stale
 * member, even when its Expires time has passed - or, when the place has no
 * entry, fails at once, without network traffic, with WX_ERROR_RATE_LIMITED
 * and the message "a request for this place was sent less than 10 minutes
 * ago". The floor is checked before the throttle below. The floor ends exactly
 * 600 s after the record
 * (a fetch at record time + 599 is held back, one at + 600 may send a
 * request); a record that lies in the future of the clock (the clock moved
 * backwards) does not apply, and the next request replaces it. Provided the
 * bound below holds, a request that fails costs one attempt series (WxHttp's
 * retries) per place per 10 minutes, not one per caller's round.
 * The records are bounded like the cache: at most WX_METNO_CACHE_MAX
 * places have one, kept apart from the entries (a place that never got an
 * answer has a record but no entry). When a request for a place without
 * record would exceed that bound, the record made, or renewed, longest ago is
 * dropped first; the place it belonged to may then be requested again before
 * its 10 minutes are over. With a clock that does not go backwards that can
 * only happen when more than WX_METNO_CACHE_MAX distinct places are
 * requested within 10 minutes.
 *
 * Concurrent fetches of one place share one request: while a request for a
 * place is in flight, further fetches of that place that find no fresh entry
 * wait for it and all receive its outcome; the request is cancelled only
 * when every one of them has been cancelled. A fetch that comes after all of
 * them were cancelled does not join the cancelled request; it is subject to
 * the floor above like any other fetch (the cancelled request counts for it).
 * Fetches of different places run in parallel; at most
 * WX_HTTP_MAX_INFLIGHT requests are outstanding per
 * provider, a fetch that would exceed the cap fails at once with
 * WX_ERROR_RATE_LIMITED and no network traffic (it does not start the
 * throttle below). A slot is free again as soon as WxHttp has released the
 * finished request, which is right after the completion callback of that
 * request has returned.
 *
 * Throttle: after an answer of HTTP 429 ("too many requests") no new request
 * is sent for WX_METNO_THROTTLE_S seconds (60): a fetch that would start a
 * request fails with WX_ERROR_RATE_LIMITED and the message "requests are
 * paused after HTTP 429", without traffic, while fetches served from a fresh
 * entry or, by the floor, from a stale one, fetches that join a request
 * already in flight and the requests already in flight are not affected. The
 * request that was answered 429 is itself recorded for the floor of its
 * place. A clock that reads earlier than the time of the 429 answer (it moved
 * backwards) lifts the throttle.
 *
 * Response -> member
 * ------------------
 * wx_metno_parse_forecast() turns the body into ONE WxMember with source id
 * "met-no" and model id "ecmwf" (the model label fixed by the design). Hour
 * buckets follow the provider contract of the design:
 * the entry with time T gives the values AT T (temperature, humidity, cloud
 * cover, wind) and, when it has next_1_hours, the precipitation over
 * [T, T + 1 h). Entries without next_1_hours (the 6-hourly tail of the
 * series) still give their instant values, their precipitation is
 * NAN. There is no precipitation probability (NAN) and no WMO code (-1; the
 * symbol codes are ignored). Wind and gust speeds are converted from m/s to
 * km/h (x 3.6).
 *
 * Thread affinity: a WxMetno and the WxProvider operations on it belong to the
 * thread that runs the GLib main context (normally the main thread); it is not
 * thread-safe. wx_metno_forecast_path() and wx_metno_parse_forecast() are pure
 * and may be called from any thread.
 */
#ifndef WX_METNO_H
#define WX_METNO_H

#include <gio/gio.h>

#include "wx-provider.h"

G_BEGIN_DECLS

/** Production origin. */
#define WX_METNO_BASE_URL "https://api.met.no"
/** User-Agent sent with every request (the service requires an identifying one). */
#define WX_METNO_USER_AGENT "weather-app/0.1 (github.com/wtp128pro/weather)"
/** Provider id and WxMember source id. */
#define WX_METNO_PROVIDER_ID "met-no"
/** WxMember model id. */
#define WX_METNO_MODEL_ID "ecmwf"
/** Most places kept in the in-memory cache, and most places with a request record. */
#define WX_METNO_CACHE_MAX 32
/** Floor between two requests for one place, seconds. */
#define WX_METNO_MIN_REFRESH_S 600
/** Time without new requests after an HTTP 429, seconds. */
#define WX_METNO_THROTTLE_S 60

#define WX_TYPE_METNO (wx_metno_get_type())
G_DECLARE_FINAL_TYPE(WxMetno, wx_metno, WX, METNO, GObject)

/**
 * wx_metno_new:
 *
 * Creates the production provider.
 *
 * Preconditions:
 *  - Called from the thread that will run the GLib main context.
 * Postconditions:
 *  - the instance talks to WX_METNO_BASE_URL with the default WxHttp timing,
 *    owns one WxHttp (one HTTP session, reused by every request), has an
 *    empty cache, no request record and no outstanding request.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): a WxProvider; create one and share it.
 */
WxMetno *wx_metno_new(void);

/**
 * wx_metno_new_custom:
 * @base_url: origin without path, see wx_http_new_custom() ("https://" origins
 *   and "http://" origins towards 127.0.0.1, ::1 or localhost).
 * @timeout_ms: per-attempt deadline, 1..600000.
 * @backoff_base_ms: first back-off delay, 0..600000.
 * @error: (nullable): return location for a #GError.
 *
 * Creates a provider for another origin or other timing; exists so tests can
 * use a loopback fake server and short delays.
 *
 * Preconditions:
 *  - @base_url is non-NULL and NUL-terminated and the two numbers are in the
 *    ranges above (violation: critical, NULL). A @base_url that is not
 *    acceptable is data: it is reported through @error.
 *  - Called from the thread that will run the GLib main context.
 * Postconditions:
 *  - on success as wx_metno_new(), for @base_url, @timeout_ms and
 *    @backoff_base_ms.
 *  - on failure NULL is returned, @error (when non-NULL) is WX_ERROR /
 *    WX_ERROR_INVALID_ARG and nothing is allocated that outlives the call.
 * Thread affinity: main thread only.
 * Ownership: @base_url is copied; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the provider, or NULL.
 */
WxMetno *wx_metno_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms,
                             GError **error);

/**
 * wx_metno_forecast_path:
 * @lat: latitude in degrees.
 * @lon: longitude in degrees.
 *
 * Builds the request target of the forecast of a place:
 * "/weatherapi/locationforecast/2.0/complete?lat=<lat>&lon=<lon>" with both
 * coordinates printed "%.4f" with a '.' decimal point (rounded as printf
 * rounds the binary value; "-0.0000" becomes "0.0000"), so the longest result
 * is 68 bytes and it satisfies wx_http_path_is_valid().
 *
 * Preconditions:
 *  - none (any doubles are accepted).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure; locale independent).
 * Ownership: the caller owns the returned string (g_free()).
 *
 * Returns: (transfer full) (nullable): the path, or NULL unless
 *   wx_geo_valid(@lat, @lon).
 */
char *wx_metno_forecast_path(double lat, double lon);

/**
 * wx_metno_parse_forecast:
 * @data: (nullable): response body, @len bytes (need not be NUL-terminated).
 * @len: number of bytes at @data.
 * @fetched_s: fetch time stored in the member, UTC unix seconds within
 *   [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * @error: (nullable): return location for a #GError.
 *
 * Parses a locationforecast "complete" document: the body must be one JSON
 * object (wx_json_parse(): UTF-8, at most WX_HTTP_MAX_BODY_BYTES bytes,
 * nesting <= WX_JSON_PARSE_MAX_DEPTH, <= WX_JSON_PARSE_MAX_MEMBERS members per
 * object) with an array properties.timeseries. If properties.meta.units
 * names a unit for air_temperature, apparent_air_temperature, wind_speed,
 * wind_speed_of_gust, cloud_area_fraction, relative_humidity or
 * precipitation_amount it must be the one this parser converts from
 * ("celsius", "celsius", "m/s", "m/s", "%", "%", "mm"); a document that names
 * another unit is refused (a missing unit is accepted).
 *
 * The timeseries is walked in order. An element becomes one WxHour when its
 * "time" is a timestamp accepted by wx_time_parse_iso8601() (any zone, taken
 * to UTC) that lies exactly on a full hour and is later than the previous
 * accepted element and when at least one of the values below is usable;
 * every other element is skipped (not an object, bad or missing time, off the
 * hour, not later than its predecessor, outside 2000..2100, no usable value).
 * Values: data.instant.details.air_temperature -> temp_c (-100..70 degC),
 * apparent_air_temperature -> feels_c (same range), cloud_area_fraction ->
 * cloud_pct and relative_humidity -> humidity_pct (0..100),
 * wind_speed -> wind_kmh and wind_speed_of_gust -> gust_kmh (m/s x 3.6, result
 * 0..WX_WIND_MAX_KMH), data.next_1_hours.details.precipitation_amount ->
 * precip_mm (0..WX_PRECIP_MAX_MM_H). A value that is missing, not a finite
 * number or outside its range is NAN (never clamped); a negative zero is
 * stored as +0.0. precip_prob is always NAN and wmo -1. At most
 * WX_MEMBER_MAX_HOURS elements are used; the rest of the series is ignored.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0, otherwise it points to @len readable
 *    bytes; no more than @len bytes are read (violation: critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success a new member with source "met-no", model "ecmwf", @fetched_s
 *    and between 1 and WX_MEMBER_MAX_HOURS hours, ascending, every t_s a
 *    multiple of 3600, every hour with at least one finite value; no
 *    quarters.
 *  - on failure NULL is returned and @error (when non-NULL) is WX_ERROR with
 *    WX_ERROR_INVALID_ARG ("fetch time out of range", checked first) or
 *    WX_ERROR_PARSE (not a document of this shape, unexpected units, no
 *    usable hour); the messages never echo body text and no critical is
 *    logged for a hostile body.
 * Thread affinity: any thread (pure).
 * Ownership: @data stays with the caller; the caller owns the member.
 *
 * Returns: (transfer full) (nullable): the member; wx_member_unref() it.
 */
WxMember *wx_metno_parse_forecast(const guint8 *data, gsize len, gint64 fetched_s, GError **error);

G_END_DECLS

#endif /* WX_METNO_H */
