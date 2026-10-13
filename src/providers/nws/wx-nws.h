/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-nws.h - WxNws: the National Weather Service (api.weather.gov) provider.
 *
 * The service needs no key. It identifies clients by their User-Agent (WX_NWS_USER_AGENT carries
 * a contact string) and answers in two steps, which this provider performs through one WxHttp
 * instance (no other I/O):
 *
 *  1. GET /points/<lat>,<lon>, both rounded to four decimals with wx_geo_round4() and printed
 *     locale independently ("%.4f"), resolves a point to its forecast grid cell (gridId, gridX,
 *     gridY). HTTP 404 means the point is outside NWS coverage: the fetch fails with
 *     WX_ERROR_UNSUPPORTED, is never retried, and the point is remembered as unsupported (at most
 *     WX_NWS_CACHE_MAX points, the oldest is forgotten first, for the life of the instance), so
 *     later fetches of it fail with WX_ERROR_UNSUPPORTED without network traffic. A resolved cell
 *     is cached per point (at most WX_NWS_CACHE_MAX points, the oldest is evicted first, for
 *     WX_NWS_GRID_TTL_S seconds of monotonic time).
 *  2. GET /gridpoints/<GRID>/<x>,<y> returns the raw forecast grid. The layers `temperature`,
 *     `apparentTemperature`, `relativeHumidity`, `skyCover`, `windSpeed`, `windGust`,
 *     `probabilityOfPrecipitation` and `quantitativePrecipitation` become ONE member (source
 *     "nws", model "nws"); every other layer is ignored. The member has no weather code (wmo -1)
 *     and no quarters.
 *
 * HTTP 429 (WX_ERROR_RATE_LIMITED, which WxHttp also reports for its own in-flight cap): the
 * instance refuses every new request, including the second request of a fetch in progress, for
 * WX_NWS_RATE_LIMIT_S seconds of monotonic time, answering WX_ERROR_RATE_LIMITED without network
 * traffic.
 *
 * Grid layer format (design 3.2 and 4)
 * -------------------------------------
 * A layer is {"uom": "wmoUnit:...", "values": [{"validTime": "<start>/<duration>", "value": n}]}.
 * Only the units wmoUnit:degC (temperatures), wmoUnit:percent (humidity, sky cover, probability),
 * wmoUnit:km_h-1 (wind, gust) and wmoUnit:mm (precipitation) are accepted: a layer with another
 * unit, no unit or no value array is ignored. Each valid element covers the whole hours
 * [start, start + duration) and is expanded into one hourly bucket per hour, keyed by the
 * bucket's start (UTC). Instant layers and the probability repeat the element's value in every
 * hour; the precipitation, a total over the element's interval, is divided evenly: value /
 * hours in every hour. An element is skipped (the rest of the layer is still read) when it is not
 * an object, its validTime is not a valid "start/duration" (wx_time_parse_interval(): at most 31
 * days, never zero), the start is not a multiple of 3600 s, the duration is not a whole number of
 * hours, its value is null, missing, not a finite number or outside the range of the layer
 * (temperature WX_TEMP_MIN_C..WX_TEMP_MAX_C, percentages 0..100, wind 0..WX_WIND_MAX_KMH,
 * precipitation per hour 0..WX_PRECIP_MAX_MM_H; nothing is clamped). A bucket outside
 * [WX_TIME_MIN_S, WX_TIME_MAX_S) is dropped. When elements of one layer overlap, the first one
 * in the array wins for the shared hours. At most WX_MEMBER_MAX_HOURS elements and at most
 * WX_MEMBER_MAX_HOURS distinct hours of one layer are read, in array order. The member lists the
 * union of the layers' hours in ascending order, the first WX_MEMBER_MAX_HOURS of them; a field
 * no layer provides for an hour is NAN.
 *
 * The member's fetched_s is the wall clock (g_get_real_time(), whole seconds) when the second
 * response was received.
 *
 * Real service, as captured in fixtures/ (Miami, 2026-10-12): 186 distinct hourly buckets over
 * the eight layers, objects with at most 68 members, nesting depth 9; wx_json_parse() accepts
 * 1024 members and depth 32.
 *
 * Thread affinity: a WxNws and its operations belong to the thread that runs the GLib main
 * context; the parsers are pure and thread-safe.
 */
#ifndef WX_NWS_H
#define WX_NWS_H

#include "wx-provider.h"

G_BEGIN_DECLS

/** Base URL of the service; the host of the production instance is fixed to it. */
#define WX_NWS_BASE_URL "https://api.weather.gov"
/** User-Agent of every request: product, version and contact. */
#define WX_NWS_USER_AGENT "weather-app/0.1 (github.com/wtp128pro/weather)"
/** Provider and member source id, and member model id. */
#define WX_NWS_ID "nws"
/** Most points remembered per cache (resolved cells; unsupported points). */
#define WX_NWS_CACHE_MAX 64
/** Lifetime of a cached grid cell, seconds (7 days). */
#define WX_NWS_GRID_TTL_S (7 * 86400)
/** Time after a 429 during which no request is made, seconds. */
#define WX_NWS_RATE_LIMIT_S 5

#define WX_TYPE_NWS (wx_nws_get_type())
G_DECLARE_FINAL_TYPE(WxNws, wx_nws, WX, NWS, GObject)

/**
 * WxNwsGrid: the forecast grid cell of a point.
 */
typedef struct {
  char grid_id[4]; /**< forecast office, three ASCII capital letters */
  guint x;         /**< 0..999 */
  guint y;         /**< 0..999 */
} WxNwsGrid;

/**
 * wx_nws_new:
 * @error: (nullable): return location for a #GError.
 *
 * Creates the provider for WX_NWS_BASE_URL with WX_NWS_USER_AGENT and the default WxHttp timing
 * (WX_HTTP_TIMEOUT_MS, WX_HTTP_BACKOFF_BASE_MS, no pacing): wx_nws_new_custom() with those values.
 *
 * Preconditions:
 *  - Called from the thread that will run the GLib main context.
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success the instance owns one WxHttp, empty caches and no rate-limit block. Failure
 *    (NULL, @error set by wx_nws_new_custom()) is not expected: every argument is a constant.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the provider, or NULL on failure.
 */
WxNws *wx_nws_new(GError **error);

/**
 * wx_nws_new_custom:
 * @base_url: origin of the service (https, or http towards a loopback host; see
 *   wx_http_new_custom()).
 * @timeout_ms: per-attempt deadline, 1..600000.
 * @backoff_base_ms: first back-off delay, 0..600000.
 * @error: (nullable): return location for a #GError.
 *
 * Creates a provider for another origin and timing: the hook of the tests (loopback server,
 * short timeouts). Everything else is as for wx_nws_new().
 *
 * Preconditions:
 *  - @base_url is non-NULL and NUL-terminated, @timeout_ms is in 1..600000, @backoff_base_ms in
 *    0..600000 and @error is NULL or points to a NULL GError* (violation: critical, NULL).
 *  - Called from the thread that will run the GLib main context.
 *  - @base_url is acceptable to wx_http_new_custom() (https, or http towards a loopback host, no
 *    userinfo/query/fragment); otherwise NULL is returned with @error set to WX_ERROR_INVALID_ARG.
 * Postconditions:
 *  - as for wx_nws_new(), with the given origin and timing.
 * Thread affinity: main thread only.
 * Ownership: @base_url is copied; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the provider, or NULL on failure.
 */
WxNws *wx_nws_new_custom(const char *base_url, guint timeout_ms, guint backoff_base_ms,
                         GError **error);

/**
 * wx_nws_parse_points:
 * @data: (nullable): body of a /points response (@len bytes; need not be NUL-terminated).
 * @len: number of bytes at @data.
 * @grid: (out): receives the grid cell on success.
 * @error: (nullable): return location for a #GError.
 *
 * Extracts properties.gridId (exactly three ASCII capitals), properties.gridX and
 * properties.gridY (integral numbers 0..999) from a /points body. Everything else is ignored.
 * At most WX_HTTP_MAX_BODY_BYTES bytes are accepted and exactly @len bytes are read.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0, otherwise it points to @len readable bytes (violation:
 *    critical, FALSE); @grid is non-NULL (violation: critical, FALSE).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on TRUE *@grid is a valid cell; on FALSE *@grid is untouched and *@error (when non-NULL) is
 *    WX_ERROR/WX_ERROR_PARSE with a fixed message that never echoes body content. Hostile body
 *    content never logs a critical.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the body is a valid /points response.
 */
gboolean wx_nws_parse_points(const guint8 *data, gsize len, WxNwsGrid *grid, GError **error);

/**
 * wx_nws_parse_gridpoints:
 * @data: (nullable): body of a /gridpoints response (@len bytes; need not be NUL-terminated).
 * @len: number of bytes at @data.
 * @fetched_s: fetch time stored in the member, UTC unix seconds.
 * @error: (nullable): return location for a #GError.
 *
 * Builds the member of a /gridpoints body as described in the file comment. At most
 * WX_HTTP_MAX_BODY_BYTES bytes are accepted and exactly @len bytes are read.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0, otherwise it points to @len readable bytes (violation:
 *    critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success the member (source "nws", model "nws", @fetched_s) has at least one hour with a
 *    finite value; its hours are strictly ascending multiples of 3600, at most
 *    WX_MEMBER_MAX_HOURS; no hour has all values NAN; wmo is -1, no quarters.
 *  - on failure NULL is returned and *@error (when non-NULL) is WX_ERROR with a fixed message
 *    that never echoes body content: WX_ERROR_PARSE when the body is not JSON, not an object or
 *    has no `properties` object; then WX_ERROR_INVALID_ARG when @fetched_s is outside
 *    [WX_TIME_MIN_S, WX_TIME_MAX_S) (no critical: wx_member_new()); then WX_ERROR_NOT_FOUND when
 *    the shape is right but no layer yields a usable value. Hostile body content never logs a
 *    critical.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the member.
 *
 * Returns: (transfer full) (nullable): the member, or NULL with @error set.
 */
WxMember *wx_nws_parse_gridpoints(const guint8 *data, gsize len, gint64 fetched_s,
                                  GError **error);

G_END_DECLS

#endif /* WX_NWS_H */
