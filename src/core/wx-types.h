/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-types.h - core value types shared by every weather module.
 *
 * Pure data + GLib only: no GTK, no network, no disk I/O, no global state.
 *
 * Units everywhere internally: temperature degC, speed km/h, precipitation mm,
 * percentages 0..100, time = UTC unix seconds (gint64 t_s). An unknown numeric
 * value is NAN (test with isnan()); an unknown WMO weather code is -1.
 */
#ifndef WX_TYPES_H
#define WX_TYPES_H

#include <glib.h>
#include <math.h>

G_BEGIN_DECLS

/* ------------------------------------------------------------------------ */
/* Errors                                                                   */
/* ------------------------------------------------------------------------ */

/** GError domain used by every weather module. */
#define WX_ERROR (wx_error_quark())

/** Error codes of the WX_ERROR domain. */
typedef enum {
  WX_ERROR_NETWORK,      /**< connection failed / DNS / TLS / I/O error      */
  WX_ERROR_TIMEOUT,      /**< request exceeded its deadline                  */
  WX_ERROR_HTTP,         /**< unexpected HTTP status (not 404 / 429)         */
  WX_ERROR_RATE_LIMITED, /**< HTTP 429 or provider-signalled throttling      */
  WX_ERROR_PARSE,        /**< response/text did not match the expected shape */
  WX_ERROR_NOT_FOUND,    /**< unknown place / HTTP 404 / no usable data      */
  WX_ERROR_INVALID_ARG,  /**< caller passed a value the API rejects          */
  WX_ERROR_UNSUPPORTED   /**< the provider does not cover the request        */
} WxError;

/**
 * wx_error_quark:
 *
 * Returns the quark of the WX_ERROR domain ("wx-error-quark"). Defined with
 * G_DEFINE_QUARK() in wx-types.c.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the same non-zero quark is returned on every call; no state is changed
 *    other than the one-time quark registration.
 * Thread affinity: any thread.
 * Ownership: none (no pointers; returns a quark).
 *
 * Returns: the #GQuark of the WX_ERROR domain.
 */
GQuark wx_error_quark(void);

/* ------------------------------------------------------------------------ */
/* Limits and validation constants                                          */
/* ------------------------------------------------------------------------ */

/** Longest place / admin / country name, in bytes (without the NUL). */
#define WX_PLACE_NAME_MAX 256
/** Longest IANA time zone name, in characters (without the NUL). */
#define WX_PLACE_TIMEZONE_MAX 64
/** Maximum number of saved places per user. */
#define WX_PLACE_MAX 50

/** Maximum number of hourly entries in one WxMember. */
#define WX_MEMBER_MAX_HOURS 400
/** Maximum number of 15-minute entries in one WxMember. */
#define WX_MEMBER_MAX_QUARTERS 1536
/** Longest source_id / model_id, in bytes (without the NUL). */
#define WX_ID_MAX 32

/** Maximum number of hourly entries in a WxForecast. */
#define WX_FORECAST_MAX_HOURS 400
/** Maximum number of 15-minute entries in a WxForecast. */
#define WX_FORECAST_MAX_QUARTERS WX_MEMBER_MAX_QUARTERS
/** Maximum number of daily entries in a WxForecast. */
#define WX_FORECAST_MAX_DAYS 16
/** Maximum number of source-status entries in a WxForecast. */
#define WX_FORECAST_MAX_SOURCES 16

/** Longest source name / attribution text kept by WxSourceStatus, in bytes. */
#define WX_SOURCE_TEXT_MAX 256
/** Longest attribution URL accepted by WxSourceStatus, in bytes. */
#define WX_SOURCE_URL_MAX 512

/** Earliest accepted timestamp: 2000-01-01T00:00:00Z (inclusive). */
#define WX_TIME_MIN_S G_GINT64_CONSTANT(946684800)
/** Upper bound of accepted timestamps: 2101-01-01T00:00:00Z (EXCLUSIVE). */
#define WX_TIME_MAX_S G_GINT64_CONSTANT(4133980800)

/** Valid air temperature range, degC; values outside are stored as NAN. */
#define WX_TEMP_MIN_C (-100.0)
#define WX_TEMP_MAX_C 70.0
/** Valid wind / gust speed upper bound, km/h (lower bound 0). */
#define WX_WIND_MAX_KMH 500.0
/** Valid precipitation rate upper bound, mm per hour (lower bound 0). */
#define WX_PRECIP_MAX_MM_H 500.0
/** Valid daily precipitation total upper bound, mm (lower bound 0): 24 h at the hourly maximum. */
#define WX_PRECIP_MAX_MM_DAY (WX_PRECIP_MAX_MM_H * 24.0)
/** Valid spread between members, degC: the whole temperature range (lower bound 0). */
#define WX_TEMP_SPREAD_MAX_C (WX_TEMP_MAX_C - WX_TEMP_MIN_C)
/** Valid percentage range (probability, cloud cover, humidity). */
#define WX_PERCENT_MIN 0.0
#define WX_PERCENT_MAX 100.0

/**
 * wx_value_in_range:
 * @v: value to test.
 * @lo: inclusive lower bound.
 * @hi: inclusive upper bound.
 *
 * Range check used on every external number before it is stored: the caller
 * stores NAN instead of @v when this returns FALSE (out-of-range data is
 * dropped, never clamped into a plausible value).
 *
 * Preconditions:
 *  - none (any doubles, including NAN and infinities, are accepted).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @v is finite and lo <= v <= hi (so FALSE when any of the
 *   three arguments is NAN).
 */
gboolean wx_value_in_range(double v, double lo, double hi);

/**
 * wx_id_is_valid:
 * @id: (nullable): candidate source / model / provider identifier.
 *
 * Validates an identifier: 1..WX_ID_MAX bytes of [a-z0-9_.-] starting with
 * [a-z0-9]. Only the first
 * WX_ID_MAX + 1 bytes are ever examined.
 *
 * Preconditions:
 *  - @id is NULL or a NUL-terminated string (or has WX_ID_MAX + 1 readable
 *    bytes).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @id is non-NULL and matches [a-z0-9][a-z0-9_.-]{0,31}
 *   (1..32 bytes, the first one a lower-case letter or digit). So "." and ".."
 *   and every id starting with '.', '-' or '_' are rejected (an id may end up
 *   in a file name); interior and trailing dots, dashes and underscores are
 *   allowed ("ecmwf_ifs0.25"; "a..b" is accepted: it is not a path component
 *   on its own).
 */
gboolean wx_id_is_valid(const char *id);

/* ------------------------------------------------------------------------ */
/* WxPlace                                                                  */
/* ------------------------------------------------------------------------ */

/**
 * WxPlace: a geocoded location. Every string is owned by the struct, never
 * NULL and valid UTF-8; admin1, country and timezone may be "". Create with
 * wx_place_new() / wx_place_copy() so the invariants hold.
 *
 * What the validated fields may be used for: name, admin1 and country are
 * DISPLAY text (any printable text, so they may contain '/', '%', '-', quotes
 * and so on) and must never be used as a path component, a command-line
 * option or a format string; pass them only through "%s" and similar. The
 * country code is two ASCII capitals, the timezone is an IANA-shaped name
 * (see wx_place_new()), and the key from wx_place_key() is numeric.
 */
typedef struct {
  char *name;            /**< 1..WX_PLACE_NAME_MAX bytes, no control chars   */
  char *admin1;          /**< state / region, "" when unknown                */
  char *country;         /**< country name, "" when unknown                  */
  char country_code[3];  /**< "" or two ASCII upper-case letters             */
  double lat;            /**< degrees north, [-90, 90]                       */
  double lon;            /**< degrees east, [-180, 180]                      */
  char *timezone;        /**< IANA-shaped name (see wx_place_new()) or ""    */
} WxPlace;

/**
 * wx_place_new:
 * @name: place name: 1..WX_PLACE_NAME_MAX bytes, valid UTF-8, no control or
 *   bidi-override characters, not only whitespace (see wx_text_is_usable_name()).
 * @admin1: (nullable): region name, same rules as @name but may be NULL or "".
 * @country: (nullable): country name, same rules as @admin1.
 * @country_code: (nullable): "" / NULL or exactly two ASCII upper-case letters.
 * @lat: latitude in degrees, finite, within [-90, 90].
 * @lon: longitude in degrees, finite, within [-180, 180].
 * @timezone: (nullable): "" / NULL or an IANA-shaped zone name of at most
 *   WX_PLACE_TIMEZONE_MAX bytes: "/"-separated components, each starting with
 *   an ASCII letter and continuing with [A-Za-z0-9_+-] ("UTC",
 *   "America/New_York", "Etc/GMT+5"). A leading or trailing '/', an empty
 *   component ("//") and a component starting with a digit, '-', '+', '_' or
 *   '.' ("/etc/passwd", "a/../b", "./x", "-") are rejected, so the value is
 *   never usable as an absolute path, a traversal or an option.
 * @error: (nullable): return location for a #GError.
 *
 * Validates and creates a place. @name, @admin1, @country, @country_code and
 * @timezone are examined only up to their bound plus one byte, so an
 * over-long or unterminated candidate is rejected cheaply.
 *
 * Preconditions:
 *  - every string argument is NULL or NUL-terminated (hostile content is
 *    expected and rejected; it never triggers a critical).
 * Postconditions:
 *  - on success: a new place owning private copies; NULL optional strings
 *    became "".
 *  - on failure: NULL is returned, @error (if non-NULL) is set to
 *    WX_ERROR/WX_ERROR_INVALID_ARG with a message that never echoes the
 *    rejected text; nothing is allocated.
 * Thread affinity: any thread.
 * Ownership: arguments stay with the caller (copied).
 *
 * Returns: (transfer full) (nullable): the new place; release with
 *   wx_place_free() (or g_autoptr(WxPlace)).
 */
WxPlace *wx_place_new(const char *name, const char *admin1, const char *country,
                      const char *country_code, double lat, double lon,
                      const char *timezone, GError **error);

/**
 * wx_place_copy:
 * @place: non-NULL place.
 *
 * Deep-copies a place, re-validating it with the rules of wx_place_new() (the
 * copy of a place that was hand-built with NULL or hostile strings is refused
 * instead of propagating them).
 *
 * Preconditions:
 *  - @place is non-NULL (NULL: critical, NULL returned).
 * Postconditions:
 *  - on success the copy owns its strings and equals @place field by field;
 *    @place is unchanged. If @place violates the wx_place_new() rules, NULL
 *    is returned (no critical).
 * Thread affinity: any thread (the caller must not mutate @place concurrently).
 * Ownership: the caller owns the copy.
 *
 * Returns: (transfer full) (nullable): deep copy; release with wx_place_free().
 */
WxPlace *wx_place_copy(const WxPlace *place);

/**
 * wx_place_free:
 * @place: (nullable) (transfer full): place to free, or NULL.
 *
 * Frees a place and its strings.
 *
 * Preconditions:
 *  - @place is NULL or was returned by wx_place_new()/wx_place_copy() and is
 *    not used afterwards.
 * Postconditions:
 *  - all memory is released; NULL is a no-op.
 * Thread affinity: any thread.
 * Ownership: consumes @place.
 */
void wx_place_free(WxPlace *place);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxPlace, wx_place_free)

/**
 * wx_place_key:
 * @place: non-NULL place.
 *
 * Builds the stable identity key of a place: latitude and longitude rounded
 * to four decimals, "%.4f,%.4f" with a '.' decimal point whatever the locale
 * (e.g. "25.7617,-80.1918"). Negative zero is printed as 0.0000. The key
 * consists only of [0-9.,-]: it never contains '/', '%' or a space, but it
 * may START with '-', so a caller that builds a file name or a command line
 * from it must put a prefix in front.
 *
 * Preconditions:
 *  - @place is non-NULL (NULL: critical, NULL returned) with finite lat/lon.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated key; g_free() it.
 */
char *wx_place_key(const WxPlace *place);

/**
 * wx_place_label:
 * @place: non-NULL place.
 *
 * Builds the display label "Name, Admin1, Country" omitting empty parts
 * (e.g. "Miami, Florida, United States", "Reykjavik, Iceland", "Oslo").
 *
 * Preconditions:
 *  - @place is non-NULL (NULL: critical, NULL returned) with non-NULL strings.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated label; g_free() it.
 */
char *wx_place_label(const WxPlace *place);

/* ------------------------------------------------------------------------ */
/* Hours, quarters, members                                                 */
/* ------------------------------------------------------------------------ */

/**
 * WxHour: one provider-normalised hourly bucket. Instant variables are values
 * AT t_s; precip_mm and precip_prob describe [t_s, t_s + 3600).
 */
typedef struct {
  gint64 t_s;          /**< bucket start, UTC unix seconds, multiple of 3600 */
  double temp_c;       /**< air temperature, degC                            */
  double feels_c;      /**< apparent temperature, degC                       */
  double precip_mm;    /**< precipitation over the hour, mm                  */
  double precip_prob;  /**< probability of precipitation, 0..100             */
  double cloud_pct;    /**< cloud cover, 0..100                              */
  double wind_kmh;     /**< 10 m wind speed, km/h                            */
  double gust_kmh;     /**< wind gust, km/h                                  */
  double humidity_pct; /**< relative humidity, 0..100                        */
  int wmo;             /**< WMO weather code 0..99, -1 unknown               */
} WxHour;

/** WxQuarter: precipitation amount over [t_s, t_s + 900). */
typedef struct {
  gint64 t_s;       /**< start, UTC unix seconds, multiple of 900 */
  double precip_mm; /**< amount over the 15 minutes, mm           */
} WxQuarter;

/**
 * wx_hour_init:
 * @hour: (out): hour to initialise.
 *
 * Sets every numeric field to NAN, t_s to 0 and wmo to -1.
 *
 * Preconditions:
 *  - @hour is non-NULL and writable (NULL: critical, nothing happens).
 * Postconditions:
 *  - *@hour is the "all unknown" hour.
 * Thread affinity: any thread.
 * Ownership: none.
 */
void wx_hour_init(WxHour *hour);

/**
 * WxMember: one forecast series from one model of one source (e.g. source
 * "open-meteo", model "ecmwf_ifs025"). Atomically reference-counted; build it
 * with wx_member_new() + wx_member_add_hour()/wx_member_add_quarter(), then
 * share it (it may be handed across threads once building is finished).
 * Adding to a shared member (reference count above 1) is a programmer error
 * that is refused with a critical, so a shared member is immutable and may be
 * read from any thread without locks.
 *
 * Invariants: hours are strictly ascending in t_s, every t_s a multiple of
 * 3600 within [WX_TIME_MIN_S, WX_TIME_MAX_S) (gaps allowed); quarters are
 * strictly ascending, multiples of 900, amounts finite in
 * [0, WX_PRECIP_MAX_MM_H]; every hour field is finite and in range or NAN.
 * The fields below are read-only; the pointers may be non-NULL while the
 * counts are 0.
 */
typedef struct _WxMember WxMember;
struct _WxMember {
  const char *source_id;      /**< wx_id_is_valid(): [a-z0-9][a-z0-9_.-]{0,31} */
  const char *model_id;       /**< wx_id_is_valid(): [a-z0-9][a-z0-9_.-]{0,31} */
  gint64 fetched_s;           /**< UTC unix seconds the data was fetched */
  const WxHour *hours;        /**< valid for [0, n_hours) */
  guint n_hours;
  const WxQuarter *quarters;  /**< valid for [0, n_quarters) */
  guint n_quarters;

  /*< private >*/
  gatomicrefcount ref_count;
  guint hours_alloc;
  guint quarters_alloc;
};

/**
 * wx_member_new:
 * @source_id: provider id, see wx_id_is_valid().
 * @model_id: model id, see wx_id_is_valid().
 * @fetched_s: fetch time, within [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * @error: (nullable): return location for a #GError.
 *
 * Creates an empty member (n_hours == n_quarters == 0, one reference).
 *
 * Preconditions:
 *  - the string arguments are NULL or NUL-terminated (invalid ones are
 *    rejected with an error, never a critical).
 * Postconditions:
 *  - on success: a member owning copies of the ids, ref count 1.
 *  - on failure: NULL, @error set to WX_ERROR_INVALID_ARG; nothing allocated.
 * Thread affinity: any thread (the new member is private to the caller).
 * Ownership: the caller owns the returned reference; arguments are copied.
 *
 * Returns: (transfer full) (nullable): new member; wx_member_unref() it.
 */
WxMember *wx_member_new(const char *source_id, const char *model_id, gint64 fetched_s,
                        GError **error);

/**
 * wx_member_ref:
 * @member: non-NULL member.
 *
 * Takes an additional (atomic) reference.
 *
 * Preconditions:
 *  - @member is non-NULL (NULL: critical, NULL returned) and the caller owns
 *    a reference.
 * Postconditions:
 *  - the reference count grew by one.
 * Thread affinity: any thread (atomic count).
 * Ownership: the caller owns the new reference.
 *
 * Returns: (transfer full): @member.
 */
WxMember *wx_member_ref(WxMember *member);

/**
 * wx_member_unref:
 * @member: non-NULL member.
 *
 * Drops one reference; frees the member when the last one goes away.
 *
 * Preconditions:
 *  - @member is non-NULL (NULL: critical, nothing happens) and the caller owns
 *    a reference.
 * Postconditions:
 *  - at zero references all storage is freed and no pointer into the member
 *    may be used any more.
 * Thread affinity: any thread (atomic count).
 * Ownership: consumes the caller's reference.
 */
void wx_member_unref(WxMember *member);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxMember, wx_member_unref)

/**
 * wx_member_add_hour:
 * @member: non-NULL member with a single reference (not shared).
 * @hour: non-NULL hour to append (copied).
 *
 * Appends an hourly bucket. Hostile data is rejected, not asserted: the
 * element is simply not added (providers skip a bad element and go on).
 *
 * Numeric fields outside their valid range (WX_TEMP_*, 0..WX_WIND_MAX_KMH
 * for wind/gust, 0..WX_PRECIP_MAX_MM_H for precip_mm, 0..100 for the
 * percentages) or non-finite are stored as NAN; wmo outside 0..99 is stored
 * as -1.
 *
 * Preconditions:
 *  - @member and @hour are non-NULL (checked: critical, FALSE).
 *  - the caller holds the only reference to @member (the builder). This is
 *    checked: adding to a shared member (reference count above 1) is a
 *    programmer error, so it logs a critical and returns FALSE without
 *    touching the member. It enforces the build-then-share contract: once a
 *    second owner holds a reference, readers may walk `hours` without any
 *    lock, so reallocating it would be a data race; the member is immutable
 *    from the moment it is ref'ed (writable again once the other references
 *    are dropped).
 * Postconditions:
 *  - on TRUE: n_hours grew by one and the last hour is the normalised copy;
 *    earlier `hours` pointers may be invalidated (reallocation).
 *  - on FALSE the member is unchanged. Rejected DATA (silently, no critical):
 *    t_s not a multiple of 3600, outside [WX_TIME_MIN_S, WX_TIME_MAX_S), not
 *    strictly greater than the last hour's t_s (duplicate or descending), or
 *    n_hours already WX_MEMBER_MAX_HOURS.
 * Thread affinity: builder only: the thread that created the member and holds
 *   its single reference; the member becomes immutable once a second owner
 *   has referenced it.
 * Ownership: nothing is retained; @hour stays with the caller.
 *
 * Returns: TRUE if added; FALSE if the data was rejected or (with a critical)
 *   the member is shared.
 */
gboolean wx_member_add_hour(WxMember *member, const WxHour *hour);

/**
 * wx_member_add_quarter:
 * @member: non-NULL member with a single reference (not shared).
 * @quarter: non-NULL 15-minute entry to append (copied).
 *
 * Appends a 15-minute precipitation amount. Rejected data (silently, no
 * critical): t_s not a multiple of 900, outside [WX_TIME_MIN_S, WX_TIME_MAX_S),
 * not strictly after the last quarter, precip_mm not finite or outside
 * [0, WX_PRECIP_MAX_MM_H], or WX_MEMBER_MAX_QUARTERS already stored.
 *
 * Preconditions:
 *  - @member and @quarter are non-NULL (checked: critical, FALSE).
 *  - the caller holds the only reference to @member (checked: a shared
 *    member, i.e. reference count above 1, is a programmer error: critical,
 *    FALSE, member unchanged; see wx_member_add_hour()).
 * Postconditions:
 *  - on TRUE: n_quarters grew by one; earlier `quarters` pointers may be
 *    invalidated. On FALSE the member is unchanged.
 * Thread affinity: builder only: the thread that created the member and holds
 *   its single reference; the member becomes immutable once a second owner
 *   has referenced it.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE if added; FALSE if the data was rejected or (with a critical)
 *   the member is shared.
 */
gboolean wx_member_add_quarter(WxMember *member, const WxQuarter *quarter);

/**
 * wx_member_get_source_id:
 * @member: non-NULL member.
 *
 * Preconditions: @member non-NULL (NULL: critical, NULL returned).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (immutable once shared).
 * Ownership: the string is owned by @member; do not free.
 *
 * Returns: (transfer none): the source id.
 */
const char *wx_member_get_source_id(const WxMember *member);

/**
 * wx_member_get_model_id:
 * @member: non-NULL member.
 *
 * Preconditions: @member non-NULL (NULL: critical, NULL returned).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (immutable once shared).
 * Ownership: the string is owned by @member; do not free.
 *
 * Returns: (transfer none): the model id.
 */
const char *wx_member_get_model_id(const WxMember *member);

/**
 * wx_member_get_fetched_s:
 * @member: non-NULL member.
 *
 * Preconditions: @member non-NULL (NULL: critical, 0 returned).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (immutable once shared).
 * Ownership: none.
 *
 * Returns: the fetch time, UTC unix seconds.
 */
gint64 wx_member_get_fetched_s(const WxMember *member);

/**
 * wx_member_get_hours:
 * @member: non-NULL member.
 * @n_hours: (out): receives the number of hours.
 *
 * Preconditions: @member and @n_hours non-NULL (checked: critical, NULL).
 * Postconditions: *@n_hours == member->n_hours; no other state is changed.
 * Thread affinity: any thread (immutable once shared).
 * Ownership: the array is owned by @member and valid until the last
 *   reference is dropped (or, while building, until the next add).
 *
 * Returns: (transfer none) (nullable): the hours (NULL when none are stored).
 */
const WxHour *wx_member_get_hours(const WxMember *member, guint *n_hours);

/**
 * wx_member_get_quarters:
 * @member: non-NULL member.
 * @n_quarters: (out): receives the number of quarters.
 *
 * Preconditions: @member and @n_quarters non-NULL (checked: critical, NULL).
 * Postconditions: *@n_quarters == member->n_quarters; nothing else changes.
 * Thread affinity: any thread (immutable once shared).
 * Ownership: as wx_member_get_hours().
 *
 * Returns: (transfer none) (nullable): the quarters (NULL when none stored).
 */
const WxQuarter *wx_member_get_quarters(const WxMember *member, guint *n_quarters);

/**
 * WxSourceResult: the members one provider produced for one place. Owns its
 * strings and the references held by @members. It is a plain, single-owner
 * builder/hand-over object: only the thread that owns it may append to
 * @members; once handed to another thread (e.g. as a task result) the
 * receiver is the only owner and the producer must not touch it again. It is
 * never shared: WxMember (immutable once shared) and WxForecast (immutable
 * from construction) are the types that cross threads concurrently.
 */
typedef struct {
  char *provider_id;  /**< wx_id_is_valid(): [a-z0-9][a-z0-9_.-]{0,31} */
  GPtrArray *members; /**< WxMember*, element free function is wx_member_unref() */
} WxSourceResult;

/**
 * wx_source_result_new:
 * @provider_id: provider id, see wx_id_is_valid().
 * @error: (nullable): return location for a #GError.
 *
 * Creates an empty result. Callers append members with g_ptr_array_add()
 * (transferring one reference each).
 *
 * Preconditions:
 *  - @provider_id is NULL or NUL-terminated (invalid ones are rejected with
 *    an error).
 * Postconditions:
 *  - on success: a result with an empty members array; on failure NULL and
 *    @error set to WX_ERROR_INVALID_ARG.
 * Thread affinity: any thread.
 * Ownership: the caller owns the result; @provider_id is copied.
 *
 * Returns: (transfer full) (nullable): the result; wx_source_result_free() it.
 */
WxSourceResult *wx_source_result_new(const char *provider_id, GError **error);

/**
 * wx_source_result_free:
 * @result: (nullable) (transfer full): result to free, or NULL.
 *
 * Frees the result, its id and drops the reference of every member.
 *
 * Preconditions:
 *  - @result is NULL or was returned by wx_source_result_new().
 * Postconditions:
 *  - all memory released; NULL is a no-op.
 * Thread affinity: any thread.
 * Ownership: consumes @result.
 */
void wx_source_result_free(WxSourceResult *result);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxSourceResult, wx_source_result_free)

/* ------------------------------------------------------------------------ */
/* Conditions, blended output, outlook                                      */
/* ------------------------------------------------------------------------ */

/** Plain-language sky/precipitation class derived by the blend. */
typedef enum {
  WX_COND_UNKNOWN,
  WX_COND_CLEAR,
  WX_COND_MOSTLY_CLEAR,
  WX_COND_PARTLY_CLOUDY,
  WX_COND_MOSTLY_CLOUDY,
  WX_COND_OVERCAST,
  WX_COND_FOG,
  WX_COND_DRIZZLE,
  WX_COND_LIGHT_RAIN,
  WX_COND_RAIN,
  WX_COND_HEAVY_RAIN,
  WX_COND_SHOWERS,
  WX_COND_THUNDERSTORM,
  WX_COND_SNOW,
  WX_COND_SLEET,
  WX_COND_COUNT /**< number of conditions; not a valid condition itself */
} WxCondition;

/** One blended hour of the final forecast. */
typedef struct {
  gint64 t_s;
  double temp_c, feels_c;
  double precip_mm;      /**< weighted median over members            */
  double precip_mm_max;  /**< maximum over members                    */
  double precip_prob, cloud_pct, wind_kmh, gust_kmh, humidity_pct;
  double temp_spread_c;  /**< max-min across members, NAN if < 2      */
  guint8 n_members;
  WxCondition condition;
  gboolean is_day;
} WxBlendHour;

/** One day of the daily summary. */
typedef struct {
  gint64 start_s; /**< local midnight as UTC unix seconds */
  double temp_max_c, temp_min_c, precip_mm, precip_prob_max, cloud_pct;
  WxCondition condition;
} WxDay;

/** Outcome of one source for one refresh. */
typedef enum {
  WX_SRC_OK,
  WX_SRC_FAILED,
  WX_SRC_SKIPPED /**< not covering the place, or disabled */
} WxSourceState;

/**
 * WxSourceStatus: per-source status shown in the "Sources" UI; owns its strings.
 * name and attribution are DISPLAY text (sanitised, may contain any printable
 * character: never use them as a path, option or format string). The
 * attribution_url is either "" or a strictly checked https URL (see
 * wx_source_status_new()) so it can be handed to a link widget or URI launcher.
 */
typedef struct {
  char *provider_id;
  char *name;
  char *attribution;
  char *attribution_url;
  WxSourceState state;
  int error_code;  /**< a WxError value, or -1 */
  guint n_members;
} WxSourceStatus;

/**
 * wx_source_status_new:
 * @provider_id: provider id, see wx_id_is_valid().
 * @name: (nullable): human-readable name (NULL becomes "").
 * @attribution: (nullable): attribution text (NULL becomes "").
 * @attribution_url: (nullable): attribution link: NULL or "" (stored as ""), or
 *   an absolute "https://" URL of at most WX_SOURCE_URL_MAX bytes of the form
 *   authority [path] [?query] [#fragment]. authority = host [":" port] with no
 *   user-info. host is either a registered name (1..253 bytes; dot-separated
 *   labels of 1..63 bytes of [A-Za-z0-9-] not starting or ending with '-'; no
 *   '%', '_', trailing dot or empty label; "xn--" form for non-ASCII names; a
 *   name whose last label is all digits must be a strict dotted-decimal IPv4
 *   address) or an IPv6 address in brackets ("[::1]", no zone id). port is
 *   1..5 digits, no leading zero, 1..65535 ("https://a:/" is rejected). The
 *   rest consists of unreserved characters, !$&'()*+,;=:@/? and well-formed
 *   percent escapes ('%' + 2 hex digits, decoding to valid UTF-8 without NUL);
 *   a raw '[' or ']', a second '#', spaces, controls and non-ASCII bytes are
 *   rejected. The URL must also parse with g_uri_parse() into the same host
 *   and port. Any other scheme ("http:", "file:", "javascript:") is rejected;
 *   a URL is rejected, never repaired. Callers that embed it in markup must
 *   still escape it. At most WX_SOURCE_URL_MAX + 1 bytes are read.
 * @state: a valid WxSourceState.
 * @error_code: -1 or a WxError value (WX_ERROR_NETWORK..WX_ERROR_UNSUPPORTED).
 * @n_members: number of members the source contributed.
 * @error: (nullable): return location for a #GError.
 *
 * Creates a status. @name and @attribution are passed through
 * wx_sanitize_text() (controls and bidi overrides stripped, invalid UTF-8
 * replaced, truncated to WX_SOURCE_TEXT_MAX bytes) before being copied.
 *
 * Preconditions:
 *  - string arguments are NULL or NUL-terminated (invalid values are rejected
 *    with an error, not a critical).
 * Postconditions:
 *  - on success: a status owning private strings.
 *  - on failure (bad id, URL, state or error_code): NULL, @error set to
 *    WX_ERROR_INVALID_ARG.
 * Thread affinity: any thread.
 * Ownership: arguments stay with the caller; the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the status; wx_source_status_free() it.
 */
WxSourceStatus *wx_source_status_new(const char *provider_id, const char *name,
                                     const char *attribution, const char *attribution_url,
                                     WxSourceState state, int error_code, guint n_members,
                                     GError **error);

/**
 * wx_source_status_copy:
 * @status: non-NULL status.
 *
 * Deep-copies a status, re-validating and re-sanitising it like
 * wx_source_status_new().
 *
 * Preconditions:
 *  - @status is non-NULL (NULL: critical, NULL returned).
 * Postconditions:
 *  - @status is unchanged; NULL is returned when its fields are invalid
 *    (not a programming error: no critical).
 * Thread affinity: any thread (the caller must not mutate @status concurrently).
 * Ownership: the caller owns the copy.
 *
 * Returns: (transfer full) (nullable): the copy; wx_source_status_free() it.
 */
WxSourceStatus *wx_source_status_copy(const WxSourceStatus *status);

/**
 * wx_source_status_free:
 * @status: (nullable) (transfer full): status to free, or NULL.
 *
 * Preconditions:
 *  - @status is NULL or was returned by wx_source_status_new()/_copy().
 * Postconditions:
 *  - the struct and its strings are freed; NULL is a no-op.
 * Thread affinity: any thread.
 * Ownership: consumes @status.
 */
void wx_source_status_free(WxSourceStatus *status);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxSourceStatus, wx_source_status_free)

/** State of the rain headline. */
typedef enum {
  WX_RAIN_DRY,
  WX_RAIN_NOW,
  WX_RAIN_EXPECTED,
  WX_RAIN_POSSIBLE
} WxRainState;

/** Summary of the next rain period. */
typedef struct {
  WxRainState state;
  gint64 start_s;
  gint64 end_s;      /**< 0 if unknown / beyond the horizon */
  gint64 peak_s;
  double peak_mm_h;
  double peak_prob;
  gboolean ends_known;
} WxRainOutlook;

/** Unit system for display. */
typedef enum {
  WX_UNITS_IMPERIAL,
  WX_UNITS_METRIC
} WxUnits;

/* ------------------------------------------------------------------------ */
/* WxForecast                                                               */
/* ------------------------------------------------------------------------ */

/**
 * WxForecast: the final blended forecast for one place. Atomically
 * reference-counted and immutable after wx_forecast_new(); safe to share
 * across threads. The fields are read-only; arrays are NULL when the count is
 * 0.
 */
typedef struct _WxForecast WxForecast;
struct _WxForecast {
  WxPlace place;                 /**< private deep copy */
  gint64 generated_s;            /**< UTC unix seconds the blend was produced */
  const WxBlendHour *hours;      /**< ascending, multiples of 3600, <= WX_FORECAST_MAX_HOURS */
  guint n_hours;
  const WxQuarter *quarters;     /**< blended 15-min nowcast, ascending, may be empty */
  guint n_quarters;
  const WxDay *days;             /**< ascending start_s, <= WX_FORECAST_MAX_DAYS */
  guint n_days;
  const WxSourceStatus *sources; /**< <= WX_FORECAST_MAX_SOURCES */
  guint n_sources;

  /*< private >*/
  gatomicrefcount ref_count;
};

/**
 * wx_forecast_new:
 * @place: non-NULL place; re-validated and deep-copied.
 * @generated_s: production time, within [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * @hours: (nullable) (array length=n_hours): blended hours (copied); may be
 *   NULL only when @n_hours is 0.
 * @n_hours: number of hours, <= WX_FORECAST_MAX_HOURS.
 * @quarters: (nullable) (array length=n_quarters): 15-minute nowcast (copied).
 * @n_quarters: number of quarters, <= WX_FORECAST_MAX_QUARTERS.
 * @days: (nullable) (array length=n_days): daily summary (copied).
 * @n_days: number of days, <= WX_FORECAST_MAX_DAYS.
 * @sources: (nullable) (array length=n_sources): source statuses (deep-copied,
 *   re-validated and re-sanitised like wx_source_status_new()).
 * @n_sources: number of statuses, <= WX_FORECAST_MAX_SOURCES.
 * @error: (nullable): return location for a #GError.
 *
 * Creates an immutable forecast. EVERYTHING passed in is copied; the caller
 * keeps ownership of all arguments (nothing is adopted), so arrays may live on
 * the stack. Because the cache loader feeds disk data through this function,
 * all arguments are validated and hostile data returns a #GError instead of
 * asserting.
 *
 * Validation (violations return WX_ERROR_INVALID_ARG): hours t_s strictly
 * ascending, multiples of 3600, in [WX_TIME_MIN_S, WX_TIME_MAX_S), condition <
 * WX_COND_COUNT; quarters strictly ascending, multiples of 900, in the time
 * range, amounts finite in [0, WX_PRECIP_MAX_MM_H]; days start_s strictly
 * ascending and in the time range, condition < WX_COND_COUNT; sources valid
 * per wx_source_status_new() (id, https attribution URL, state, error code);
 * the place valid per wx_place_new().
 *
 * Normalised, not rejected: numeric fields outside their valid range or not
 * finite are stored as NAN: hour temp_c/feels_c in [WX_TEMP_MIN_C,
 * WX_TEMP_MAX_C]; precip_mm and precip_mm_max in [0, WX_PRECIP_MAX_MM_H];
 * precip_prob, cloud_pct, humidity_pct in [0, 100]; wind_kmh and gust_kmh in
 * [0, WX_WIND_MAX_KMH]; temp_spread_c in [0, WX_TEMP_SPREAD_MAX_C]; day
 * temp_max_c/temp_min_c in the temperature range, precip_mm in [0,
 * WX_PRECIP_MAX_MM_DAY], precip_prob_max and cloud_pct in [0, 100]. is_day is
 * normalised to TRUE/FALSE; n_members and condition are copied as given
 * (condition is validated above).
 *
 * Preconditions:
 *  - @place is non-NULL (NULL: critical, NULL returned).
 *  - each array pointer is non-NULL when its count is > 0 (otherwise a
 *    WX_ERROR_INVALID_ARG error is returned).
 * Postconditions:
 *  - on success: a forecast with ref count 1 owning private copies of
 *    everything.
 *  - on failure: NULL, @error set to WX_ERROR_INVALID_ARG; nothing leaks.
 * Thread affinity: any thread (the result is private to the caller).
 * Ownership: arguments stay with the caller; the caller owns the returned
 *   reference.
 *
 * Returns: (transfer full) (nullable): the forecast; wx_forecast_unref() it.
 */
WxForecast *wx_forecast_new(const WxPlace *place, gint64 generated_s,
                            const WxBlendHour *hours, guint n_hours,
                            const WxQuarter *quarters, guint n_quarters,
                            const WxDay *days, guint n_days,
                            const WxSourceStatus *sources, guint n_sources,
                            GError **error);

/**
 * wx_forecast_ref:
 * @forecast: non-NULL forecast.
 *
 * Takes an additional (atomic) reference.
 *
 * Preconditions: @forecast non-NULL (NULL: critical, NULL returned), caller
 *   owns a reference.
 * Postconditions: the count grew by one.
 * Thread affinity: any thread (atomic count).
 * Ownership: the caller owns the new reference.
 *
 * Returns: (transfer full): @forecast.
 */
WxForecast *wx_forecast_ref(WxForecast *forecast);

/**
 * wx_forecast_unref:
 * @forecast: non-NULL forecast.
 *
 * Drops one reference; frees the forecast at zero.
 *
 * Preconditions: @forecast non-NULL (NULL: critical, nothing happens), caller
 *   owns a reference.
 * Postconditions: at zero all storage is freed and no pointer into the
 *   forecast may be used any more.
 * Thread affinity: any thread (atomic count).
 * Ownership: consumes the caller's reference.
 */
void wx_forecast_unref(WxForecast *forecast);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxForecast, wx_forecast_unref)

/**
 * wx_forecast_get_place:
 * @forecast: non-NULL forecast.
 *
 * Preconditions: @forecast non-NULL (NULL: critical, NULL returned).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (immutable).
 * Ownership: owned by @forecast; do not free.
 *
 * Returns: (transfer none): the forecast's place.
 */
const WxPlace *wx_forecast_get_place(const WxForecast *forecast);

/**
 * wx_forecast_get_generated_s:
 * @forecast: non-NULL forecast.
 *
 * Preconditions: @forecast non-NULL (NULL: critical, 0 returned).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (immutable).
 * Ownership: none.
 *
 * Returns: the generation time, UTC unix seconds.
 */
gint64 wx_forecast_get_generated_s(const WxForecast *forecast);

/**
 * wx_forecast_get_hours:
 * @forecast: non-NULL forecast.
 * @n_hours: (out): receives the count.
 *
 * Preconditions: both arguments non-NULL (checked: critical, NULL).
 * Postconditions: *@n_hours == forecast->n_hours; no other state is changed.
 * Thread affinity: any thread (immutable).
 * Ownership: owned by @forecast, valid until the last reference is dropped.
 *
 * Returns: (transfer none) (nullable): the hours (NULL when none).
 */
const WxBlendHour *wx_forecast_get_hours(const WxForecast *forecast, guint *n_hours);

/**
 * wx_forecast_get_quarters:
 * @forecast: non-NULL forecast.
 * @n_quarters: (out): receives the count.
 *
 * Preconditions: both arguments non-NULL (checked: critical, NULL).
 * Postconditions: *@n_quarters == forecast->n_quarters; nothing else changes.
 * Thread affinity: any thread (immutable).
 * Ownership: owned by @forecast.
 *
 * Returns: (transfer none) (nullable): the quarters (NULL when none).
 */
const WxQuarter *wx_forecast_get_quarters(const WxForecast *forecast, guint *n_quarters);

/**
 * wx_forecast_get_days:
 * @forecast: non-NULL forecast.
 * @n_days: (out): receives the count.
 *
 * Preconditions: both arguments non-NULL (checked: critical, NULL).
 * Postconditions: *@n_days == forecast->n_days; nothing else changes.
 * Thread affinity: any thread (immutable).
 * Ownership: owned by @forecast.
 *
 * Returns: (transfer none) (nullable): the days (NULL when none).
 */
const WxDay *wx_forecast_get_days(const WxForecast *forecast, guint *n_days);

/**
 * wx_forecast_get_sources:
 * @forecast: non-NULL forecast.
 * @n_sources: (out): receives the count.
 *
 * Preconditions: both arguments non-NULL (checked: critical, NULL).
 * Postconditions: *@n_sources == forecast->n_sources; nothing else changes.
 * Thread affinity: any thread (immutable).
 * Ownership: owned by @forecast.
 *
 * Returns: (transfer none) (nullable): the statuses (NULL when none).
 */
const WxSourceStatus *wx_forecast_get_sources(const WxForecast *forecast, guint *n_sources);

G_END_DECLS

#endif /* WX_TYPES_H */
