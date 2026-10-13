/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-openmeteo.h - the Open-Meteo forecast provider (WxOpenMeteo, a WxProvider
 * with id "open-meteo") and the Open-Meteo place search (WxOpenMeteoGeocoder,
 * a WxGeocoder), plus the pure parsers of their JSON bodies.
 *
 * Open-Meteo (https://open-meteo.com/) is keyless and serves one forecast
 * series per weather model. The data is licensed CC BY 4.0: the credit line
 * "Weather data by Open-Meteo.com" and its link https://open-meteo.com/ are
 * exposed through wx_provider_get_attribution() and
 * wx_provider_get_attribution_url() and must be shown wherever the data is.
 * No API key, account, cookie or telemetry is involved; the only network
 * access is through WxHttp (wx-http.h), with the fixed hosts
 * WX_OPEN_METEO_BASE_URL (forecast) and WX_OPEN_METEO_GEOCODING_BASE_URL
 * (place search), one WxHttp per object.
 *
 * Model allow-list
 * ----------------
 * An unknown model name makes Open-Meteo refuse the whole request (HTTP 400),
 * so the models are a compile-time allow-list; the request is built only from
 * these names (API name -> member model id):
 *   ncep_hrrr_conus -> hrrr, ncep_nbm_conus -> nbm, gfs_seamless -> gfs,
 *   ecmwf_ifs025 -> ecmwf, icon_seamless -> icon, gem_seamless -> gem,
 *   ukmo_seamless -> ukmo, meteofrance_seamless -> meteofrance.
 * The models of a request depend on the place (wx-geo.h):
 *   - wx_geo_in_us_nws() and wx_geo_in_conus(): ncep_hrrr_conus,
 *     ncep_nbm_conus, gfs_seamless, ecmwf_ifs025, icon_seamless,
 *     gem_seamless (in this order);
 *   - wx_geo_in_us_nws() but not wx_geo_in_conus() (Alaska, Hawaii, ...):
 *     gfs_seamless, ecmwf_ifs025, icon_seamless, gem_seamless;
 *   - elsewhere: ecmwf_ifs025, icon_seamless, gem_seamless, gfs_seamless, and
 *     ukmo_seamless, meteofrance_seamless after them when wx_geo_in_europe().
 * Every request is a GET of
 *   /v1/forecast?latitude=<%.4f>&longitude=<%.4f>&hourly=temperature_2m,
 *   apparent_temperature,relative_humidity_2m,precipitation,
 *   precipitation_probability,cloud_cover,wind_speed_10m,wind_gusts_10m,
 *   weather_code&models=<list>&timeformat=unixtime&timezone=GMT&
 *   forecast_days=10&wind_speed_unit=kmh&temperature_unit=celsius&
 *   precipitation_unit=mm
 * (one line, "." decimal point whatever the locale), with Accept
 * "application/json".
 *
 * Request A and request B
 * -----------------------
 * A fetch sends request A (the hourly multi-model forecast above). For a place
 * in the CONUS branch of the list above it ALSO sends, concurrently, request B,
 * the 15-minute HRRR precipitation nowcast:
 *   /v1/forecast?latitude=<%.4f>&longitude=<%.4f>&minutely_15=precipitation&
 *   models=ncep_hrrr_conus&forecast_minutely_15=12&timeformat=unixtime&
 *   timezone=GMT&precipitation_unit=mm
 * If A fails, the fetch fails with A's error (B alone is not enough) and B is
 * cancelled. If A succeeds, a failure of B (any error, an unusable body) is
 * tolerated: the result is A's members without the nowcast. The wait for B is
 * bounded relative to the START of the fetch (the moment request A is sent,
 * measured with g_get_monotonic_time()): B gets at most
 * WX_OPEN_METEO_NOWCAST_GRACE_MS from then. When A completes earlier than that,
 * the fetch waits only for the rest of the window; when A completes at or after
 * the end of the window and B is not done, the fetch returns A's members at
 * once, without waiting. At the end of the window B is cancelled and A's
 * members are returned. The fetch therefore returns no later than
 * max(A's completion, start + WX_OPEN_METEO_NOWCAST_GRACE_MS) (plus main-loop
 * dispatch latency): B never delays the result of a fetch whose A completed at
 * or after the end of the window. Time that request A or B spends queued
 * inside WxHttp / the network stack counts against the window like any other.
 *
 * Errors of a fetch (all in the WX_ERROR domain except cancellation): a place
 * that fails wx_place_copy() (invalid coordinates, strings or timezone) is
 * WX_ERROR_INVALID_ARG ("invalid place") without network traffic; the
 * errors of WxHttp for request A are returned unchanged (the tests exercise
 * NETWORK, TIMEOUT, HTTP, RATE_LIMITED, NOT_FOUND and PARSE); a body that
 * wx_open_meteo_parse_forecast() refuses gives its error (PARSE, HTTP,
 * NOT_FOUND). A cancellable that is cancelled before the call, during the
 * fetch, or before the finish call gives G_IO_ERROR_CANCELLED.
 *
 * Place search
 * ------------
 * wx_geocoder_search_async() on a WxOpenMeteoGeocoder checks the text in this
 * order, every failure without network traffic:
 *  1. Trim: the bytes space (0x20), \t (0x09), \n (0x0A), \f (0x0C) and \r
 *     (0x0D) are removed from both ends (g_strstrip(); the set is what
 *     g_ascii_isspace() accepts and the tests assert it for all 256 byte
 *     values). \v (0x0B) is NOT trimmed: like every other byte below 0x20 or
 *     equal to 0x7F it is a control character (step 3).
 *  2. Length: fewer than WX_OPEN_METEO_SEARCH_MIN_BYTES bytes left is an
 *     EMPTY result (0 hits, no error). This covers "", text of trim bytes
 *     only, and any single byte (even a control or an invalid one).
 *  3. Usability: the trimmed text must be accepted by
 *     wx_text_is_usable_name(text, WX_OPEN_METEO_SEARCH_MAX_BYTES); that
 *     function and the definition of "forbidden characters" in the file
 *     comment of wx-text.h are the one authoritative rule, and the list below
 *     only spells it out. A text that is not accepted is
 *     WX_ERROR_INVALID_ARG ("unacceptable search text"). The text is refused
 *     if and only if at least one of these holds:
 *      (a) it is longer than WX_OPEN_METEO_SEARCH_MAX_BYTES bytes (bytes, not
 *          characters);
 *      (b) it is not valid UTF-8: a stray continuation byte, a truncated or
 *          overlong sequence, an encoded surrogate (U+D800..U+DFFF) or a
 *          value above U+10FFFF;
 *      (c) it contains a forbidden character, which is exactly one of
 *            U+0001..U+001F, U+007F and U+0080..U+009F  (the control
 *              characters, category Cc: C0, DEL and C1; \t \n \v \f \r too,
 *              also inside the text),
 *            U+2028 and U+2029  (LINE SEPARATOR, PARAGRAPH SEPARATOR),
 *            U+061C, U+200E, U+200F, U+202A..U+202E and U+2066..U+2069
 *              (the bidirectional formatting characters);
 *      (d) it contains no non-whitespace character, i.e. every character is
 *          white space as g_unichar_isspace() decides. Since (c) already
 *          refuses \t \n \f \r, U+2028 and U+2029, the texts that reach (d)
 *          are those made only of Unicode space separators (category Zs):
 *          U+0020, U+00A0, U+1680, U+2000..U+200A, U+202F, U+205F and
 *          U+3000 (step 1 trims only U+0020 among them, and only at the ends).
 *     Every other character is accepted: letters, digits, punctuation,
 *     combining marks, emoji, unassigned code points, private-use code
 *     points, noncharacters and U+FFFD included. In particular the check does
 *     NOT detect text made only of invisible format characters (category Cf,
 *     for example U+00AD, U+180E, U+200B, U+200C, U+200D, U+2060, U+FEFF and
 *     the tag characters U+E0001, U+E0020): such a text counts as visible and
 *     is sent in step 4 (one harmless request that finds nothing).
 *  4. Otherwise the trimmed text is percent-encoded (g_uri_escape_string(),
 *     everything but ALPHA DIGIT - . _ ~ is escaped) into the request. The
 *     hits are parsed by wx_open_meteo_parse_geocode(); the errors of WxHttp
 *     are returned unchanged.
 *
 * Concurrency: every fetch of one WxOpenMeteo goes through its single WxHttp,
 * which admits at most WX_HTTP_MAX_INFLIGHT outstanding operations (an
 * operation holds its slot from wx_http_get_async() until WxHttp releases the
 * result object after the operation's callback returned); a fetch in the CONUS
 * branch uses two of them while it runs, any other fetch one. A fetch started
 * when no slot is free fails with WX_ERROR_RATE_LIMITED (request A) without
 * network traffic; a CONUS fetch that finds exactly one free slot sends
 * request A and does without request B (its result has no nowcast). Slot
 * lifetime: a fetch holds request A's slot until the completion callback of A
 * has returned (WxHttp releases a slot only after the callback of its
 * operation returned). A fetch that completes synchronously inside A's
 * callback therefore still counts A's slot while ITS own completion callback
 * runs: a fetch started from inside that callback may be refused with
 * RATE_LIMITED (a fetch outside the CONUS branch: 16 fetches started from its
 * callback give 15 results and 1 RATE_LIMITED; started from an idle source
 * after the callback returned they give 16 results). A CONUS fetch that is
 * completed by the end of B's window cancels B, and B's slot stays held until
 * WxHttp delivers B's cancellation, which takes several main-loop dispatches:
 * 16 fetches started from the completion callback, from a G_PRIORITY_HIGH idle
 * source or from a default-priority idle source queued in the callback give 15
 * results and 1 RATE_LIMITED, started 100 ms later they give 16 results (all
 * of these are pinned by the tests). Callers that refresh many places should
 * limit how many fetches they keep in flight.
 *
 * Normalisation (design contract 4)
 * ---------------------------------
 * The result holds one WxMember per model that has data (source id
 * "open-meteo", model id from the table above, in the order of the request),
 * plus the nowcast member (model id "hrrr15", quarters only) when request B
 * succeeded, last. Open-Meteo stamps an hour with the END of the interval for
 * precipitation and precipitation_probability, and with the instant itself
 * for the other variables: for a stamp T the instant variables (temperature,
 * apparent temperature, humidity, cloud cover, wind, gusts, weather code) are
 * stored in the bucket T and precipitation / probability in the bucket
 * T - 3600. A 15-minute stamp T (end of the quarter) is stored at T - 900.
 * Units are requested as degC, km/h and mm. Values outside the ranges of
 * wx-types.h (and anything that is not a finite JSON number) are stored as
 * NAN, never clamped; negative zero is stored as +0. A member keeps at most
 * WX_MEMBER_MAX_HOURS buckets: the first ones in time order, later ones are
 * dropped without error (see wx_open_meteo_parse_forecast()).
 *
 * Pure functions and objects: the parsers are pure (any thread). The objects
 * are main-thread objects like every WxProvider / WxGeocoder (wx-provider.h).
 */
#ifndef WX_OPENMETEO_H
#define WX_OPENMETEO_H

#include <gio/gio.h>

#include "wx-provider.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** Provider id (also the source id of every member). */
#define WX_OPEN_METEO_ID "open-meteo"
/** Fixed origin of the forecast API. */
#define WX_OPEN_METEO_BASE_URL "https://api.open-meteo.com"
/** Fixed origin of the place-search API. */
#define WX_OPEN_METEO_GEOCODING_BASE_URL "https://geocoding-api.open-meteo.com"
/** Most entries of "time" a forecast body may have (16 days of hourly steps; a request asks for 10 days). */
#define WX_OPEN_METEO_MAX_TIME_STEPS 384
/** The window, counted from the START of a fetch, in which request B may still add the nowcast, milliseconds. */
#define WX_OPEN_METEO_NOWCAST_GRACE_MS 2000
/** Shortest / longest accepted place-search text (after trimming), bytes. */
#define WX_OPEN_METEO_SEARCH_MIN_BYTES 2
#define WX_OPEN_METEO_SEARCH_MAX_BYTES 64

#define WX_TYPE_OPEN_METEO (wx_open_meteo_get_type())
G_DECLARE_FINAL_TYPE(WxOpenMeteo, wx_open_meteo, WX, OPEN_METEO, GObject)

#define WX_TYPE_OPEN_METEO_GEOCODER (wx_open_meteo_geocoder_get_type())
G_DECLARE_FINAL_TYPE(WxOpenMeteoGeocoder, wx_open_meteo_geocoder, WX, OPEN_METEO_GEOCODER,
                     GObject)

/**
 * wx_open_meteo_new:
 *
 * Creates the Open-Meteo forecast provider: id "open-meteo", name
 * "Open-Meteo", attribution "Weather data by Open-Meteo.com", attribution URL
 * "https://open-meteo.com/", covering every valid place. It owns one WxHttp
 * for WX_OPEN_METEO_BASE_URL with the default timing and the User-Agent
 * "weather-app/0.1 (github.com/wtp128pro/weather)".
 *
 * Preconditions:
 *  - called from the thread that will run the GLib main context.
 * Postconditions:
 *  - the instance has no outstanding operation.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the provider (also a WxProvider).
 */
WxOpenMeteo *wx_open_meteo_new(void);

/**
 * wx_open_meteo_new_custom:
 * @base_url: origin of the forecast API, as accepted by wx_http_new_custom()
 *   (https, or http towards a loopback host: the hook of the tests).
 * @timeout_ms: per-attempt deadline, 1..600000.
 * @backoff_base_ms: first back-off delay, 0..600000.
 * @error: (nullable): return location for a #GError.
 *
 * Like wx_open_meteo_new() but with another origin and timing.
 *
 * Preconditions:
 *  - @base_url is non-NULL and NUL-terminated; @timeout_ms and
 *    @backoff_base_ms are in range (violation: critical, NULL).
 *  - called from the thread that will run the GLib main context.
 * Postconditions:
 *  - on failure NULL is returned and *@error (when non-NULL) is
 *    WX_ERROR/WX_ERROR_INVALID_ARG ("unacceptable base URL").
 * Thread affinity: main thread only.
 * Ownership: @base_url is copied; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the provider, or NULL if @base_url is
 *   not acceptable.
 */
WxOpenMeteo *wx_open_meteo_new_custom(const char *base_url, guint timeout_ms,
                                      guint backoff_base_ms, GError **error);

/**
 * wx_open_meteo_geocoder_new:
 *
 * Creates the Open-Meteo place search (a WxGeocoder). It owns one WxHttp for
 * WX_OPEN_METEO_GEOCODING_BASE_URL with the default timing and the same
 * User-Agent as the provider. A search sends
 *   /v1/search?name=<escaped text>&count=10&language=en&format=json
 * with Accept "application/json".
 *
 * Preconditions:
 *  - called from the thread that will run the GLib main context.
 * Postconditions:
 *  - the instance has no outstanding operation.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the geocoder (also a WxGeocoder).
 */
WxOpenMeteoGeocoder *wx_open_meteo_geocoder_new(void);

/**
 * wx_open_meteo_geocoder_new_custom:
 * @base_url: origin of the search API, see wx_open_meteo_new_custom().
 * @timeout_ms: per-attempt deadline, 1..600000.
 * @backoff_base_ms: first back-off delay, 0..600000.
 * @error: (nullable): return location for a #GError.
 *
 * Like wx_open_meteo_geocoder_new() but with another origin and timing.
 *
 * Preconditions:
 *  - as wx_open_meteo_new_custom().
 * Postconditions:
 *  - on failure NULL is returned and *@error (when non-NULL) is
 *    WX_ERROR/WX_ERROR_INVALID_ARG ("unacceptable base URL").
 * Thread affinity: main thread only.
 * Ownership: @base_url is copied; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the geocoder, or NULL if @base_url is
 *   not acceptable.
 */
WxOpenMeteoGeocoder *wx_open_meteo_geocoder_new_custom(const char *base_url, guint timeout_ms,
                                                       guint backoff_base_ms, GError **error);

/**
 * wx_open_meteo_parse_forecast:
 * @data: (nullable): body bytes (@len of them; need not be NUL-terminated).
 * @len: number of bytes at @data; at most @len bytes are read.
 * @models: the API names of the models that were requested, in request
 *   order; the keys of the body are looked up from them (see the allow-list in
 *   the file comment). With exactly one model the body keys are the plain
 *   variable names ("temperature_2m"), with several they carry the suffix
 *   "_<api name>" ("temperature_2m_gfs_seamless"); "time" never has a suffix.
 * @n_models: number of entries of @models, 1..8.
 * @fetched_s: fetch time stored in every member, within [WX_TIME_MIN_S,
 *   WX_TIME_MAX_S).
 * @error: (nullable): return location for a #GError.
 *
 * Parses the body of request A (hourly forecast). The body must be one JSON
 * object (wx_json_parse() limits: at most WX_HTTP_MAX_BODY_BYTES bytes, depth
 * 32, 1024 members per object) holding "hourly" with a "time" array of at most
 * WX_OPEN_METEO_MAX_TIME_STEPS entries. A "time" entry is used only if it is
 * a JSON integer-valued number in [WX_TIME_MIN_S, WX_TIME_MAX_S), a multiple
 * of 3600 and greater than the previous used entry; any other entry (and the
 * values at its index) is skipped. Per model the nine variables are read from
 * the arrays of the same index; an array that is missing, not an array,
 * shorter than "time", or an element that is null / not a number / outside its
 * range, gives NAN for that field; a weather code is stored only when it is an
 * integer-valued number in 0..99, else -1. Hours are built as described in
 * the file comment (precipitation and probability in the bucket T - 3600,
 * merged with the bucket of the previous stamp when it is the same hour); an
 * hour without any finite value and without a weather code is omitted. A model
 * that has no finite value in any of the eight numeric variables (a weather
 * code alone does not count) is dropped, not an error. A member holds at most
 * WX_MEMBER_MAX_HOURS (400) buckets and every used stamp can make two buckets
 * (the instant bucket T and the precipitation bucket T - 3600, which merge only
 * when the previous used stamp is T - 3600): the first 400 buckets in time
 * order are kept and later ones are dropped without error (384 stamps spaced
 * 7200 s give 400 buckets: stamps 0..199 are kept and 200..383 dropped; a
 * contiguous hourly series of 384 stamps gives 385 buckets and loses nothing).
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0; @models is non-NULL with @n_models
 *    names in 1..8, each on the allow-list and no name repeated (violation:
 *    critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success the result's provider_id is "open-meteo" and its members are
 *    the models that have data, in the order of @models, each with source id
 *    "open-meteo", fetched_s == @fetched_s and at least one finite value.
 *  - on failure NULL is returned and *@error (when non-NULL) is a WX_ERROR:
 *    WX_ERROR_INVALID_ARG when @fetched_s is out of range (checked first);
 *    WX_ERROR_PARSE for a body that is not one JSON object, has no "hourly"
 *    object or "time" array, or more than WX_OPEN_METEO_MAX_TIME_STEPS
 *    entries; WX_ERROR_HTTP for an error body {"error":true,"reason":...}
 *    (the reason is cleaned of the forbidden characters listed at
 *    wx_open_meteo_parse_geocode() and cut to at most 120 CHARACTERS, not
 *    bytes; it is in the message);
 *    WX_ERROR_NOT_FOUND ("no usable forecast data") when no model has data.
 *    Body problems never log a critical.
 * Thread affinity: any thread (pure).
 * Ownership: @data and @models stay with the caller.
 *
 * Returns: (transfer full) (nullable): the members; wx_source_result_free() it.
 */
WxSourceResult *wx_open_meteo_parse_forecast(const guint8 *data, gsize len,
                                             const char *const *models, guint n_models,
                                             gint64 fetched_s, GError **error);

/**
 * wx_open_meteo_parse_nowcast:
 * @data: (nullable): body bytes (@len of them; need not be NUL-terminated).
 * @len: number of bytes at @data; at most @len bytes are read.
 * @fetched_s: fetch time stored in the member, within [WX_TIME_MIN_S,
 *   WX_TIME_MAX_S).
 * @error: (nullable): return location for a #GError.
 *
 * Parses the body of request B: the object "minutely_15" with the arrays
 * "time" and "precipitation" (keys without suffix: one model). A "time" entry
 * is used only if it is an integer-valued number in [WX_TIME_MIN_S,
 * WX_TIME_MAX_S), a multiple of 900 and greater than the previous used entry;
 * the quarter is stored at T - 900 (Open-Meteo stamps the end of the 15
 * minutes) provided the amount at the same index is a number in
 * [0, WX_PRECIP_MAX_MM_H]; every other entry is skipped.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0 (violation: critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success the member has source id "open-meteo", model id "hrrr15",
 *    fetched_s == @fetched_s, n_hours == 0 and at least one quarter.
 *  - on failure NULL is returned and *@error (when non-NULL) is a WX_ERROR:
 *    INVALID_ARG for @fetched_s out of range (checked first); PARSE for a body
 *    that is not one JSON object, lacks "minutely_15", its "time" or its
 *    "precipitation" array, or has more than WX_MEMBER_MAX_QUARTERS time
 *    entries; HTTP for an error body {"error":true,...}; NOT_FOUND ("no usable
 *    nowcast data") when no quarter could be used. No critical for bad bodies.
 * Thread affinity: any thread (pure).
 * Ownership: @data stays with the caller.
 *
 * Returns: (transfer full) (nullable): the member; wx_member_unref() it.
 */
WxMember *wx_open_meteo_parse_nowcast(const guint8 *data, gsize len, gint64 fetched_s,
                                      GError **error);

/**
 * wx_open_meteo_parse_geocode:
 * @data: (nullable): body bytes (@len of them; need not be NUL-terminated).
 * @len: number of bytes at @data; at most @len bytes are read.
 * @error: (nullable): return location for a #GError.
 *
 * Parses a place-search body: an object whose "results" array holds hits
 * {name, latitude, longitude, country_code, timezone, country, admin1, ...}.
 * "results" missing or null means no hit (an empty array); any other type is a
 * parse error. A hit that is not an object, lacks a string "name" or numeric
 * "latitude" / "longitude", or fails wx_place_new() is dropped. name, admin1
 * and country are cleaned with wx_sanitize_text(text, WX_PLACE_NAME_MAX)
 * before they are validated. That function (wx-text.h) removes every
 * forbidden character, the same set as in step 3 (c) of the place search:
 * U+0001..U+001F, U+007F, U+0080..U+009F, U+2028, U+2029, U+061C, U+200E,
 * U+200F, U+202A..U+202E and U+2066..U+2069 (U+0000 and invalid UTF-8 never
 * get that far: the JSON layer refuses the whole body), and it ends the text,
 * on a character boundary, before the result would exceed WX_PLACE_NAME_MAX
 * bytes; forbidden characters are removed before the bytes are counted, and
 * other white space is neither trimmed nor collapsed. A name that is empty or
 * only white space (g_unichar_isspace()) after cleaning drops the hit; an
 * admin1 or country in that state, or a member that is missing or not a
 * string, becomes "" and the hit is kept. A country_code that is not exactly
 * two ASCII capitals A-Z and a timezone that wx_place_new() does not accept
 * are replaced by "" (the hit is kept). At most WX_GEOCODER_MAX_HITS hits are
 * returned, in body order.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0 (violation: critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 * Postconditions:
 *  - on success the array holds 0..WX_GEOCODER_MAX_HITS places that satisfy
 *    the wx_place_new() rules.
 *  - on failure NULL is returned and *@error (when non-NULL) is WX_ERROR_PARSE
 *    (not one JSON object, or "results" of another type) or WX_ERROR_HTTP (an
 *    error body {"error":true,...}); no critical for bad bodies.
 * Thread affinity: any thread (pure).
 * Ownership: @data stays with the caller.
 *
 * Returns: (transfer full) (nullable) (element-type WxPlace): the places,
 *   freed by the array's free function wx_place_free(); g_ptr_array_unref() it.
 */
GPtrArray *wx_open_meteo_parse_geocode(const guint8 *data, gsize len, GError **error);

G_END_DECLS

#endif /* WX_OPENMETEO_H */
