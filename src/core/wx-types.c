/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-types.h"

#include <string.h>

#include "wx-geo.h"
#include "wx-text.h"

/* wx_error_quark(): defined by G_DEFINE_QUARK below. Documented in wx-types.h
 * (no parameters; returns the quark of the WX_ERROR domain; any thread). */
G_DEFINE_QUARK(wx-error-quark, wx_error)

/* The member/forecast arrays are tiny; this guards the guint capacity
 * arithmetic of the growth code and the byte-size products below. */
G_STATIC_ASSERT((gsize)WX_MEMBER_MAX_QUARTERS * sizeof(WxQuarter) < G_MAXUINT32);
G_STATIC_ASSERT((gsize)WX_MEMBER_MAX_HOURS * sizeof(WxHour) < G_MAXUINT32);
G_STATIC_ASSERT((gsize)WX_FORECAST_MAX_HOURS * sizeof(WxBlendHour) < G_MAXUINT32);
G_STATIC_ASSERT(WX_FORECAST_MAX_HOURS <= WX_MEMBER_MAX_HOURS);

/* First capacity of a member's arrays; they double up to the hard maximum. */
#define WX_MEMBER_INITIAL_ALLOC 24

/* ------------------------------------------------------------------------ */
/* Validation helpers                                                       */
/* ------------------------------------------------------------------------ */

/* Documented in wx-types.h. */
gboolean
wx_value_in_range(double v, double lo, double hi)
{
  return isfinite(v) && v >= lo && v <= hi;
}

/* Documented in wx-types.h. */
gboolean
wx_id_is_valid(const char *id)
{
  if (id == NULL)
    return FALSE;
  const char *nul = memchr(id, '\0', WX_ID_MAX + 1);
  if (nul == NULL || nul == id)
    return FALSE;
  /* The first character must be [a-z0-9]: this rejects ".", ".." and every
   * id starting with '.', '-' or '_' (path-traversal / option-like names). */
  if (!((*id >= 'a' && *id <= 'z') || (*id >= '0' && *id <= '9')))
    return FALSE;
  for (const char *p = id; p < nul; p++) {
    char c = *p;
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-'))
      return FALSE;
  }
  return TRUE;
}

/**
 * norm:
 * @v: value to check.
 * @lo: inclusive lower bound.
 * @hi: inclusive upper bound.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: @v when wx_value_in_range(), else NAN (the "drop, never clamp" rule).
 */
static double
norm(double v, double lo, double hi)
{
  return wx_value_in_range(v, lo, hi) ? v : NAN;
}

/**
 * norm_temp:
 * @v: temperature in degC.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: @v if within [WX_TEMP_MIN_C, WX_TEMP_MAX_C], else NAN.
 */
static double
norm_temp(double v)
{
  return norm(v, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
}

/**
 * norm_percent:
 * @v: percentage.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: @v if within [0, 100], else NAN.
 */
static double
norm_percent(double v)
{
  return norm(v, WX_PERCENT_MIN, WX_PERCENT_MAX);
}

/**
 * norm_wind:
 * @v: speed in km/h.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: @v if within [0, WX_WIND_MAX_KMH], else NAN.
 */
static double
norm_wind(double v)
{
  return norm(v, 0.0, WX_WIND_MAX_KMH);
}

/**
 * norm_precip:
 * @v: precipitation in mm over an hour.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: @v if within [0, WX_PRECIP_MAX_MM_H], else NAN.
 */
static double
norm_precip(double v)
{
  return norm(v, 0.0, WX_PRECIP_MAX_MM_H);
}

/**
 * time_in_range:
 * @t_s: UTC unix seconds.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff WX_TIME_MIN_S <= @t_s < WX_TIME_MAX_S.
 */
static gboolean
time_in_range(gint64 t_s)
{
  return t_s >= WX_TIME_MIN_S && t_s < WX_TIME_MAX_S;
}

/**
 * set_invalid:
 * @error: (nullable): return location.
 * @msg: constant message (never contains rejected input).
 *
 * Preconditions: @msg is a NUL-terminated constant.
 * Postconditions: *@error is set to WX_ERROR_INVALID_ARG when @error is
 *   non-NULL and *@error is NULL.
 * Thread affinity: any thread.
 * Ownership: none.
 */
static void
set_invalid(GError **error, const char *msg)
{
  g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, msg);
}

/* ------------------------------------------------------------------------ */
/* WxPlace                                                                  */
/* ------------------------------------------------------------------------ */

/**
 * optional_text_ok:
 * @s: (nullable): optional name text.
 *
 * Preconditions: @s is NULL or NUL-terminated.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE for NULL, "" and wx_text_is_usable_name(@s, WX_PLACE_NAME_MAX).
 */
static gboolean
optional_text_ok(const char *s)
{
  return s == NULL || *s == '\0' || wx_text_is_usable_name(s, WX_PLACE_NAME_MAX);
}

/**
 * country_code_ok:
 * @cc: (nullable): candidate ISO 3166 alpha-2 code.
 *
 * Preconditions: @cc is NULL or NUL-terminated.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE for NULL, "" and exactly two ASCII upper-case letters.
 */
static gboolean
country_code_ok(const char *cc)
{
  if (cc == NULL || cc[0] == '\0')
    return TRUE;
  return cc[0] >= 'A' && cc[0] <= 'Z' && cc[1] >= 'A' && cc[1] <= 'Z' && cc[2] == '\0';
}

/**
 * timezone_ok:
 * @tz: (nullable): candidate IANA time zone name.
 *
 * Accepts only IANA-shaped names so that a validated value can never be used
 * as an absolute path, a ".." / "." traversal, an option or a format string
 * when it is later handed to g_time_zone_new_identifier() or concatenated
 * with a zoneinfo directory: "/"-separated components, each starting with an
 * ASCII letter and continuing with [A-Za-z0-9_+-]; no leading, trailing or
 * doubled '/'; at most WX_PLACE_TIMEZONE_MAX bytes. Examples: "UTC",
 * "America/New_York", "Etc/GMT+5", "America/Argentina/ComodRivadavia".
 *
 * Preconditions: @tz is NULL or NUL-terminated (or has 65 readable bytes).
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE for NULL, "" and every name of the shape above.
 */
static gboolean
timezone_ok(const char *tz)
{
  if (tz == NULL)
    return TRUE;
  const char *nul = memchr(tz, '\0', WX_PLACE_TIMEZONE_MAX + 1);
  if (nul == NULL)
    return FALSE;
  gboolean at_component_start = TRUE;
  for (const char *p = tz; p < nul; p++) {
    char c = *p;
    if (c == '/') {
      if (at_component_start) /* leading '/' or an empty component ("//") */
        return FALSE;
      at_component_start = TRUE;
      continue;
    }
    gboolean letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (at_component_start && !letter) /* also rejects ".", ".." and "-x" */
      return FALSE;
    if (!(letter || (c >= '0' && c <= '9') || c == '_' || c == '+' || c == '-'))
      return FALSE;
    at_component_start = FALSE;
  }
  return nul == tz || !at_component_start; /* "" is fine, a trailing '/' is not */
}

/**
 * place_init:
 * @dst: (out): place to fill (its previous content is overwritten, not freed).
 * @name: place name.
 * @admin1: (nullable): region.
 * @country: (nullable): country.
 * @country_code: (nullable): alpha-2 code.
 * @lat: latitude.
 * @lon: longitude.
 * @timezone: (nullable): IANA name.
 * @error: (nullable): return location.
 *
 * Validates the fields (see wx_place_new()) and fills @dst with private
 * copies.
 *
 * Preconditions:
 *  - @dst is writable; strings are NULL or NUL-terminated.
 * Postconditions:
 *  - on TRUE @dst owns its strings; on FALSE @dst is untouched and @error is
 *    set.
 * Thread affinity: any thread.
 * Ownership: arguments are copied.
 *
 * Returns: TRUE on success.
 */
static gboolean
place_init(WxPlace *dst, const char *name, const char *admin1, const char *country,
           const char *country_code, double lat, double lon, const char *timezone,
           GError **error)
{
  if (!wx_text_is_usable_name(name, WX_PLACE_NAME_MAX)) {
    set_invalid(error, "invalid place name");
    return FALSE;
  }
  if (!optional_text_ok(admin1)) {
    set_invalid(error, "invalid region name");
    return FALSE;
  }
  if (!optional_text_ok(country)) {
    set_invalid(error, "invalid country name");
    return FALSE;
  }
  if (!country_code_ok(country_code)) {
    set_invalid(error, "invalid country code");
    return FALSE;
  }
  if (!wx_geo_valid(lat, lon)) {
    set_invalid(error, "coordinates out of range");
    return FALSE;
  }
  if (!timezone_ok(timezone)) {
    set_invalid(error, "invalid time zone name");
    return FALSE;
  }

  dst->name = g_strdup(name);
  dst->admin1 = g_strdup(admin1 != NULL ? admin1 : "");
  dst->country = g_strdup(country != NULL ? country : "");
  memset(dst->country_code, 0, sizeof dst->country_code);
  if (country_code != NULL && country_code[0] != '\0') {
    dst->country_code[0] = country_code[0];
    dst->country_code[1] = country_code[1];
  }
  dst->lat = lat;
  dst->lon = lon;
  dst->timezone = g_strdup(timezone != NULL ? timezone : "");
  return TRUE;
}

/**
 * place_clear:
 * @place: non-NULL place whose strings are freed (the struct is not).
 *
 * Preconditions: @place is non-NULL (both callers guarantee it); the strings
 *   are NULL or owned by @place.
 * Postconditions: the string fields are NULL.
 * Thread affinity: any thread.
 * Ownership: releases the strings.
 */
static void
place_clear(WxPlace *place)
{
  g_clear_pointer(&place->name, g_free);
  g_clear_pointer(&place->admin1, g_free);
  g_clear_pointer(&place->country, g_free);
  g_clear_pointer(&place->timezone, g_free);
}

/* Documented in wx-types.h. */
WxPlace *
wx_place_new(const char *name, const char *admin1, const char *country, const char *country_code,
             double lat, double lon, const char *timezone, GError **error)
{
  g_autofree WxPlace *place = g_new0(WxPlace, 1);
  if (!place_init(place, name, admin1, country, country_code, lat, lon, timezone, error))
    return NULL;
  return g_steal_pointer(&place);
}

/* Documented in wx-types.h. */
WxPlace *
wx_place_copy(const WxPlace *place)
{
  g_return_val_if_fail(place != NULL, NULL);
  /* Re-validating copies of a hand-built place with NULL or hostile strings
   * must not crash later consumers, so they yield NULL instead. */
  return wx_place_new(place->name, place->admin1, place->country, place->country_code,
                      place->lat, place->lon, place->timezone, NULL);
}

/* Documented in wx-types.h. */
void
wx_place_free(WxPlace *place)
{
  if (place == NULL)
    return;
  place_clear(place);
  g_free(place);
}

/* Documented in wx-types.h. */
char *
wx_place_key(const WxPlace *place)
{
  g_return_val_if_fail(place != NULL, NULL);
  char lat_buf[G_ASCII_DTOSTR_BUF_SIZE];
  char lon_buf[G_ASCII_DTOSTR_BUF_SIZE];
  g_ascii_formatd(lat_buf, sizeof lat_buf, "%.4f", wx_geo_round4(place->lat));
  g_ascii_formatd(lon_buf, sizeof lon_buf, "%.4f", wx_geo_round4(place->lon));
  return g_strconcat(lat_buf, ",", lon_buf, NULL);
}

/* Documented in wx-types.h. */
char *
wx_place_label(const WxPlace *place)
{
  g_return_val_if_fail(place != NULL, NULL);
  GString *label = g_string_new(place->name);
  if (place->admin1 != NULL && place->admin1[0] != '\0')
    g_string_append_printf(label, ", %s", place->admin1);
  if (place->country != NULL && place->country[0] != '\0')
    g_string_append_printf(label, ", %s", place->country);
  return g_string_free(label, FALSE);
}

/* ------------------------------------------------------------------------ */
/* WxHour / WxMember                                                        */
/* ------------------------------------------------------------------------ */

/* Documented in wx-types.h. */
void
wx_hour_init(WxHour *hour)
{
  g_return_if_fail(hour != NULL);
  hour->t_s = 0;
  hour->temp_c = NAN;
  hour->feels_c = NAN;
  hour->precip_mm = NAN;
  hour->precip_prob = NAN;
  hour->cloud_pct = NAN;
  hour->wind_kmh = NAN;
  hour->gust_kmh = NAN;
  hour->humidity_pct = NAN;
  hour->wmo = -1;
}

/**
 * quarter_ok:
 * @q: a quarter entry.
 *
 * Preconditions: @q is non-NULL.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff t_s is a multiple of 900 within the time range and
 *   precip_mm is finite within [0, WX_PRECIP_MAX_MM_H].
 */
static gboolean
quarter_ok(const WxQuarter *q)
{
  return time_in_range(q->t_s) && q->t_s % 900 == 0 &&
         wx_value_in_range(q->precip_mm, 0.0, WX_PRECIP_MAX_MM_H);
}

/* Documented in wx-types.h. */
WxMember *
wx_member_new(const char *source_id, const char *model_id, gint64 fetched_s, GError **error)
{
  if (!wx_id_is_valid(source_id)) {
    set_invalid(error, "invalid source id");
    return NULL;
  }
  if (!wx_id_is_valid(model_id)) {
    set_invalid(error, "invalid model id");
    return NULL;
  }
  if (!time_in_range(fetched_s)) {
    set_invalid(error, "fetch time out of range");
    return NULL;
  }
  WxMember *m = g_new0(WxMember, 1);
  m->source_id = g_strdup(source_id);
  m->model_id = g_strdup(model_id);
  m->fetched_s = fetched_s;
  g_atomic_ref_count_init(&m->ref_count);
  return m;
}

/* Documented in wx-types.h. */
WxMember *
wx_member_ref(WxMember *member)
{
  g_return_val_if_fail(member != NULL, NULL);
  g_atomic_ref_count_inc(&member->ref_count);
  return member;
}

/* Documented in wx-types.h. */
void
wx_member_unref(WxMember *member)
{
  g_return_if_fail(member != NULL);
  if (g_atomic_ref_count_dec(&member->ref_count)) {
    /* The arrays are exposed read-only but are allocated writable by
     * wx_member_add_*() and owned solely by the member. */
    g_free((gpointer)member->hours);
    g_free((gpointer)member->quarters);
    g_free((gpointer)member->source_id);
    g_free((gpointer)member->model_id);
    g_free(member);
  }
}

/* Documented in wx-types.h. */
gboolean
wx_member_add_hour(WxMember *member, const WxHour *hour)
{
  g_return_val_if_fail(member != NULL && hour != NULL, FALSE);
  /* Build-then-share: once a second owner holds a reference, readers may walk
   * the arrays without a lock, so reallocating or appending would race. Adding
   * to a shared member is a programmer error, hence a critical (unlike
   * rejected data, which returns FALSE silently). */
  g_return_val_if_fail(g_atomic_ref_count_compare(&member->ref_count, 1), FALSE);
  if (!time_in_range(hour->t_s) || hour->t_s % 3600 != 0)
    return FALSE;
  if (member->n_hours >= WX_MEMBER_MAX_HOURS)
    return FALSE;
  if (member->n_hours > 0 && hour->t_s <= member->hours[member->n_hours - 1].t_s)
    return FALSE;

  if (member->n_hours == member->hours_alloc) {
    guint grown = member->hours_alloc == 0 ? WX_MEMBER_INITIAL_ALLOC
                                           : MIN(member->hours_alloc * 2, WX_MEMBER_MAX_HOURS);
    member->hours = g_renew(WxHour, (WxHour *)member->hours, grown);
    member->hours_alloc = grown;
  }
  WxHour *dst = (WxHour *)member->hours + member->n_hours;
  dst->t_s = hour->t_s;
  dst->temp_c = norm_temp(hour->temp_c);
  dst->feels_c = norm_temp(hour->feels_c);
  dst->precip_mm = norm_precip(hour->precip_mm);
  dst->precip_prob = norm_percent(hour->precip_prob);
  dst->cloud_pct = norm_percent(hour->cloud_pct);
  dst->wind_kmh = norm_wind(hour->wind_kmh);
  dst->gust_kmh = norm_wind(hour->gust_kmh);
  dst->humidity_pct = norm_percent(hour->humidity_pct);
  dst->wmo = (hour->wmo >= 0 && hour->wmo <= 99) ? hour->wmo : -1;
  member->n_hours++;
  return TRUE;
}

/* Documented in wx-types.h. */
gboolean
wx_member_add_quarter(WxMember *member, const WxQuarter *quarter)
{
  g_return_val_if_fail(member != NULL && quarter != NULL, FALSE);
  /* Build-then-share: a shared member is immutable (see wx_member_add_hour()).
   * Adding to it is a programmer error, hence a critical, unlike rejected data. */
  g_return_val_if_fail(g_atomic_ref_count_compare(&member->ref_count, 1), FALSE);
  if (!quarter_ok(quarter) || member->n_quarters >= WX_MEMBER_MAX_QUARTERS)
    return FALSE;
  if (member->n_quarters > 0 && quarter->t_s <= member->quarters[member->n_quarters - 1].t_s)
    return FALSE;

  if (member->n_quarters == member->quarters_alloc) {
    guint grown = member->quarters_alloc == 0
                    ? WX_MEMBER_INITIAL_ALLOC
                    : MIN(member->quarters_alloc * 2, WX_MEMBER_MAX_QUARTERS);
    member->quarters = g_renew(WxQuarter, (WxQuarter *)member->quarters, grown);
    member->quarters_alloc = grown;
  }
  ((WxQuarter *)member->quarters)[member->n_quarters++] = *quarter;
  return TRUE;
}

/* Documented in wx-types.h. */
const char *
wx_member_get_source_id(const WxMember *member)
{
  g_return_val_if_fail(member != NULL, NULL);
  return member->source_id;
}

/* Documented in wx-types.h. */
const char *
wx_member_get_model_id(const WxMember *member)
{
  g_return_val_if_fail(member != NULL, NULL);
  return member->model_id;
}

/* Documented in wx-types.h. */
gint64
wx_member_get_fetched_s(const WxMember *member)
{
  g_return_val_if_fail(member != NULL, 0);
  return member->fetched_s;
}

/* Documented in wx-types.h. */
const WxHour *
wx_member_get_hours(const WxMember *member, guint *n_hours)
{
  g_return_val_if_fail(member != NULL && n_hours != NULL, NULL);
  *n_hours = member->n_hours;
  return member->n_hours > 0 ? member->hours : NULL;
}

/* Documented in wx-types.h. */
const WxQuarter *
wx_member_get_quarters(const WxMember *member, guint *n_quarters)
{
  g_return_val_if_fail(member != NULL && n_quarters != NULL, NULL);
  *n_quarters = member->n_quarters;
  return member->n_quarters > 0 ? member->quarters : NULL;
}

/* ------------------------------------------------------------------------ */
/* WxSourceResult                                                           */
/* ------------------------------------------------------------------------ */

/**
 * member_unref_notify:
 * @data: a WxMember* owned by the array.
 *
 * GDestroyNotify adapter (keeps the call type-correct).
 *
 * Preconditions: @data is a valid WxMember with a reference owned by the array.
 * Postconditions: that reference is dropped.
 * Thread affinity: any thread.
 * Ownership: consumes the array's reference.
 */
static void
member_unref_notify(gpointer data)
{
  wx_member_unref(data);
}

/* Documented in wx-types.h. */
WxSourceResult *
wx_source_result_new(const char *provider_id, GError **error)
{
  if (!wx_id_is_valid(provider_id)) {
    set_invalid(error, "invalid provider id");
    return NULL;
  }
  WxSourceResult *r = g_new0(WxSourceResult, 1);
  r->provider_id = g_strdup(provider_id);
  r->members = g_ptr_array_new_with_free_func(member_unref_notify);
  return r;
}

/* Documented in wx-types.h. */
void
wx_source_result_free(WxSourceResult *result)
{
  if (result == NULL)
    return;
  if (result->members != NULL)
    g_ptr_array_unref(result->members);
  g_free(result->provider_id);
  g_free(result);
}

/* ------------------------------------------------------------------------ */
/* WxSourceStatus                                                           */
/* ------------------------------------------------------------------------ */

/** Longest host name (RFC 1035) and longest label accepted in an attribution URL. */
#define WX_URL_HOST_MAX 253
#define WX_URL_LABEL_MAX 63

/**
 * ipv4_ok:
 * @s: candidate dotted-decimal address (not NUL-terminated).
 * @len: its length in bytes.
 *
 * Strict dotted decimal: exactly four octets of 1..3 digits, value 0..255,
 * no leading zero ("01"), no empty octet, no leading or trailing dot.
 *
 * Preconditions: @s has @len readable bytes.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @s is a strict IPv4 address.
 */
static gboolean
ipv4_ok(const char *s, gsize len)
{
  const char *end = s + len;
  const char *p = s;
  guint octets = 0;
  for (;;) {
    const char *start = p;
    guint v = 0;
    while (p < end && g_ascii_isdigit(*p) && p - start < 3)
      v = v * 10 + (guint)(*p++ - '0');
    gsize digits = (gsize)(p - start);
    if (digits == 0 || v > 255 || (digits > 1 && *start == '0'))
      return FALSE;
    octets++;
    if (p == end)
      return octets == 4;
    if (*p != '.' || octets == 4) /* garbage, a 4th digit, or a 5th octet */
      return FALSE;
    p++;
  }
}

/**
 * dns_host_ok:
 * @host: candidate host name (not NUL-terminated).
 * @len: its length in bytes.
 *
 * The registered-name subset accepted in an attribution URL: 1..253 bytes,
 * dot-separated labels of 1..63 bytes made of [A-Za-z0-9-] that neither start
 * nor end with '-' (so no '%', no sub-delimiters, no '_', no empty label, no
 * trailing dot; internationalised names must be in their "xn--" form). A host
 * whose last label is all digits must be a strict dotted-decimal IPv4 address
 * (browsers read such names as numbers), see ipv4_ok().
 *
 * Preconditions: @host has @len readable bytes.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @host is acceptable.
 */
static gboolean
dns_host_ok(const char *host, gsize len)
{
  if (len == 0 || len > WX_URL_HOST_MAX)
    return FALSE;
  gsize label_start = 0;
  for (gsize i = 0; i <= len; i++) {
    if (i < len && host[i] != '.') {
      if (!g_ascii_isalnum(host[i]) && host[i] != '-')
        return FALSE;
      continue;
    }
    gsize label_len = i - label_start;
    if (label_len == 0 || label_len > WX_URL_LABEL_MAX || host[label_start] == '-' ||
        host[i - 1] == '-')
      return FALSE;
    label_start = i + 1;
  }
  gsize last = len;
  while (last > 0 && host[last - 1] != '.')
    last--;
  for (gsize i = last; i < len; i++) {
    if (!g_ascii_isdigit(host[i]))
      return TRUE; /* the last label has a non-digit: an ordinary name */
  }
  return ipv4_ok(host, len);
}

/**
 * ipv6_literal_ok:
 * @s: text between the brackets of an IP literal (not NUL-terminated).
 * @len: its length in bytes.
 *
 * An IPv6 address in the usual forms ("::1", "2001:db8::1", "::ffff:1.2.3.4"):
 * only hex digits, ':' and '.', at least one ':', at most 45 bytes, and
 * accepted by g_hostname_is_ip_address(). Zone identifiers ("%25eth0") and
 * IPvFuture ("v1.x") are rejected.
 *
 * Preconditions: @s has @len readable bytes.
 * Postconditions: none.
 * Thread affinity: any thread.
 * Ownership: a temporary copy is made and freed.
 *
 * Returns: TRUE iff @s is an acceptable IPv6 address.
 */
static gboolean
ipv6_literal_ok(const char *s, gsize len)
{
  if (len < 2 || len > 45)
    return FALSE;
  gboolean colon = FALSE;
  for (gsize i = 0; i < len; i++) {
    if (s[i] == ':')
      colon = TRUE;
    else if (!g_ascii_isxdigit(s[i]) && s[i] != '.')
      return FALSE;
  }
  if (!colon)
    return FALSE;
  g_autofree char *copy = g_strndup(s, len);
  return g_hostname_is_ip_address(copy);
}

/**
 * port_ok:
 * @s: candidate port digits (not NUL-terminated).
 * @len: their number.
 * @port: (out): receives the value on success.
 *
 * A decimal port: 1..5 digits, no leading zero, value 1..65535.
 *
 * Preconditions: @s has @len readable bytes; @port is writable.
 * Postconditions: *@port is written only on TRUE.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @s is an acceptable port.
 */
static gboolean
port_ok(const char *s, gsize len, gint *port)
{
  if (len == 0 || len > 5 || s[0] == '0')
    return FALSE;
  guint v = 0;
  for (gsize i = 0; i < len; i++) {
    if (!g_ascii_isdigit(s[i]))
      return FALSE;
    v = v * 10 + (guint)(s[i] - '0');
  }
  if (v > 65535)
    return FALSE;
  *port = (gint)v;
  return TRUE;
}

/**
 * url_tail_ok:
 * @p: start of the path / query / fragment part (a '/', '?' or '#', or @end).
 * @end: the terminating NUL of the URL.
 *
 * Checks the part after the authority: only unreserved characters
 * [A-Za-z0-9-._~], sub-delimiters (!$&'()*+,;=), ':', '@', '/', '?' and
 * well-formed percent escapes ('%' + two hex digits); '#' only once, as the
 * start of the fragment. Raw '[' and ']' (and every other character, space,
 * control and non-ASCII byte included) are rejected.
 *
 * Preconditions: [@p, @end) holds no NUL.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the part is well formed.
 */
static gboolean
url_tail_ok(const char *p, const char *end)
{
  static const char allowed[] = "-._~!$&'()*+,;=:@/?";
  gboolean in_fragment = FALSE;
  for (; p < end; p++) {
    char c = *p;
    if (c == '%') {
      if (end - p < 3 || !g_ascii_isxdigit(p[1]) || !g_ascii_isxdigit(p[2]))
        return FALSE;
      p += 2;
    } else if (c == '#') {
      if (in_fragment)
        return FALSE;
      in_fragment = TRUE;
    } else if (!g_ascii_isalnum(c) && strchr(allowed, c) == NULL) {
      return FALSE;
    }
  }
  return TRUE;
}

/**
 * attribution_url_ok:
 * @url: (nullable): candidate attribution link.
 *
 * Strict check of a link that the UI may hand to a link widget or a URI
 * launcher (see wx_source_status_new() for the accepted form):
 * "https://" authority [path] [?query] [#fragment], where
 * authority = host [":" port], host = dns_host_ok() name or a bracketed
 * ipv6_literal_ok() address, port = port_ok(); no user-info; the rest
 * satisfies url_tail_ok(); at most WX_SOURCE_URL_MAX bytes. As defence in
 * depth the URL must also parse with g_uri_parse() (which rejects, among
 * other things, percent escapes that decode to invalid UTF-8 or NUL) into
 * scheme "https", a non-empty host, no user-info and the same port.
 *
 * Preconditions: @url is NULL or NUL-terminated (or has WX_SOURCE_URL_MAX + 1
 *   readable bytes); at most that many bytes are read.
 * Postconditions: none.
 * Thread affinity: any thread.
 * Ownership: temporary objects are freed.
 *
 * Returns: TRUE for NULL, "" and every acceptable https URL.
 */
static gboolean
attribution_url_ok(const char *url)
{
  static const char prefix[] = "https://";
  const gsize prefix_len = sizeof prefix - 1;
  if (url == NULL)
    return TRUE;
  const char *nul = memchr(url, '\0', WX_SOURCE_URL_MAX + 1);
  if (nul == NULL)
    return FALSE;
  if (nul == url)
    return TRUE;
  if ((gsize)(nul - url) <= prefix_len || memcmp(url, prefix, prefix_len) != 0)
    return FALSE;

  const char *auth = url + prefix_len;
  const char *auth_end = auth + strcspn(auth, "/?#"); /* stops at the NUL at the latest */
  const char *port_text = NULL;
  if (*auth == '[') {
    const char *bracket_end = memchr(auth, ']', (gsize)(auth_end - auth));
    if (bracket_end == NULL || !ipv6_literal_ok(auth + 1, (gsize)(bracket_end - auth - 1)))
      return FALSE;
    if (bracket_end + 1 < auth_end) {
      if (bracket_end[1] != ':')
        return FALSE;
      port_text = bracket_end + 2;
    }
  } else {
    const char *colon = memchr(auth, ':', (gsize)(auth_end - auth));
    if (!dns_host_ok(auth, (gsize)((colon != NULL ? colon : auth_end) - auth)))
      return FALSE;
    if (colon != NULL)
      port_text = colon + 1;
  }
  gint port = -1;
  if (port_text != NULL && !port_ok(port_text, (gsize)(auth_end - port_text), &port))
    return FALSE;
  if (!url_tail_ok(auth_end, nul))
    return FALSE;

  g_autoptr(GUri) uri = g_uri_parse(url, G_URI_FLAGS_NONE, NULL);
  if (uri == NULL)
    return FALSE;
  const char *host = g_uri_get_host(uri);
  return g_strcmp0(g_uri_get_scheme(uri), "https") == 0 && host != NULL && host[0] != '\0' &&
         g_uri_get_userinfo(uri) == NULL && g_uri_get_port(uri) == port;
}

/**
 * status_init:
 * @dst: (out): status to fill (its previous content is overwritten).
 * @provider_id: provider id.
 * @name: (nullable): display name.
 * @attribution: (nullable): attribution text.
 * @attribution_url: (nullable): attribution link.
 * @state: source state.
 * @error_code: -1 or a WxError.
 * @n_members: member count.
 * @error: (nullable): return location.
 *
 * Validates the fields and fills @dst with sanitised private copies.
 *
 * Preconditions:
 *  - @dst is writable; strings are NULL or NUL-terminated.
 * Postconditions:
 *  - on TRUE @dst owns its strings; on FALSE @dst is untouched, @error set.
 * Thread affinity: any thread.
 * Ownership: arguments are copied.
 *
 * Returns: TRUE on success.
 */
static gboolean
status_init(WxSourceStatus *dst, const char *provider_id, const char *name,
            const char *attribution, const char *attribution_url, WxSourceState state,
            int error_code, guint n_members, GError **error)
{
  if (!wx_id_is_valid(provider_id)) {
    set_invalid(error, "invalid provider id");
    return FALSE;
  }
  if ((guint)state > (guint)WX_SRC_SKIPPED) {
    set_invalid(error, "invalid source state");
    return FALSE;
  }
  if (error_code != -1 && (error_code < 0 || error_code > WX_ERROR_UNSUPPORTED)) {
    set_invalid(error, "invalid source error code");
    return FALSE;
  }
  if (!attribution_url_ok(attribution_url)) {
    set_invalid(error, "invalid attribution URL");
    return FALSE;
  }
  dst->provider_id = g_strdup(provider_id);
  dst->name = wx_sanitize_text(name, WX_SOURCE_TEXT_MAX);
  dst->attribution = wx_sanitize_text(attribution, WX_SOURCE_TEXT_MAX);
  dst->attribution_url = g_strdup(attribution_url != NULL ? attribution_url : "");
  dst->state = state;
  dst->error_code = error_code;
  dst->n_members = n_members;
  return TRUE;
}

/**
 * status_clear:
 * @status: non-NULL status whose strings are freed (the struct is not).
 *
 * Preconditions: @status is non-NULL (both callers guarantee it); the strings
 *   are NULL or owned by @status.
 * Postconditions: the string fields are NULL.
 * Thread affinity: any thread.
 * Ownership: releases the strings.
 */
static void
status_clear(WxSourceStatus *status)
{
  g_clear_pointer(&status->provider_id, g_free);
  g_clear_pointer(&status->name, g_free);
  g_clear_pointer(&status->attribution, g_free);
  g_clear_pointer(&status->attribution_url, g_free);
}

/* Documented in wx-types.h. */
WxSourceStatus *
wx_source_status_new(const char *provider_id, const char *name, const char *attribution,
                     const char *attribution_url, WxSourceState state, int error_code,
                     guint n_members, GError **error)
{
  g_autofree WxSourceStatus *status = g_new0(WxSourceStatus, 1);
  if (!status_init(status, provider_id, name, attribution, attribution_url, state, error_code,
                   n_members, error))
    return NULL;
  return g_steal_pointer(&status);
}

/* Documented in wx-types.h. */
WxSourceStatus *
wx_source_status_copy(const WxSourceStatus *status)
{
  g_return_val_if_fail(status != NULL, NULL);
  return wx_source_status_new(status->provider_id, status->name, status->attribution,
                              status->attribution_url, status->state, status->error_code,
                              status->n_members, NULL);
}

/* Documented in wx-types.h. */
void
wx_source_status_free(WxSourceStatus *status)
{
  if (status == NULL)
    return;
  status_clear(status);
  g_free(status);
}

/* ------------------------------------------------------------------------ */
/* WxForecast                                                               */
/* ------------------------------------------------------------------------ */

/**
 * forecast_release:
 * @fc: forecast under construction or at end of life, non-NULL.
 *
 * Frees everything @fc owns, tolerating a partially built object
 * (n_sources counts only the fully initialised statuses).
 *
 * Preconditions: @fc is non-NULL (both callers guarantee it); all owned
 *   pointers are NULL or heap blocks owned by @fc.
 * Postconditions: @fc and its storage are freed.
 * Thread affinity: any thread.
 * Ownership: consumes @fc.
 */
static void
forecast_release(WxForecast *fc)
{
  place_clear(&fc->place);
  /* Arrays are exposed read-only but allocated writable and solely owned. */
  g_free((gpointer)fc->hours);
  g_free((gpointer)fc->quarters);
  g_free((gpointer)fc->days);
  for (guint i = 0; i < fc->n_sources; i++)
    status_clear((WxSourceStatus *)&fc->sources[i]);
  g_free((gpointer)fc->sources);
  g_free(fc);
}

/**
 * forecast_validate_inputs:
 * @generated_s: generation time.
 * @hours: (nullable): blended hours.
 * @n_hours: count.
 * @quarters: (nullable): quarters.
 * @n_quarters: count.
 * @days: (nullable): days.
 * @n_days: count.
 * @sources: (nullable): statuses.
 * @n_sources: count.
 * @error: (nullable): return location.
 *
 * Checks every structural rule of wx_forecast_new() except the per-source
 * field checks (done while copying): counts, NULL arrays, time range,
 * alignment, strict ordering and condition enums.
 *
 * Preconditions: none beyond the argument types.
 * Postconditions: @error is set on FALSE; nothing else changes.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: TRUE if the structure is acceptable.
 */
static gboolean
forecast_validate_inputs(gint64 generated_s, const WxBlendHour *hours, guint n_hours,
                         const WxQuarter *quarters, guint n_quarters, const WxDay *days,
                         guint n_days, const WxSourceStatus *sources, guint n_sources,
                         GError **error)
{
  if (!time_in_range(generated_s)) {
    set_invalid(error, "generation time out of range");
    return FALSE;
  }
  if (n_hours > WX_FORECAST_MAX_HOURS || n_quarters > WX_FORECAST_MAX_QUARTERS ||
      n_days > WX_FORECAST_MAX_DAYS || n_sources > WX_FORECAST_MAX_SOURCES) {
    set_invalid(error, "too many forecast entries");
    return FALSE;
  }
  if ((n_hours > 0 && hours == NULL) || (n_quarters > 0 && quarters == NULL) ||
      (n_days > 0 && days == NULL) || (n_sources > 0 && sources == NULL)) {
    set_invalid(error, "missing forecast array");
    return FALSE;
  }
  for (guint i = 0; i < n_hours; i++) {
    if (!time_in_range(hours[i].t_s) || hours[i].t_s % 3600 != 0 ||
        (i > 0 && hours[i].t_s <= hours[i - 1].t_s) || (guint)hours[i].condition >= WX_COND_COUNT) {
      set_invalid(error, "invalid forecast hour");
      return FALSE;
    }
  }
  for (guint i = 0; i < n_quarters; i++) {
    if (!quarter_ok(&quarters[i]) || (i > 0 && quarters[i].t_s <= quarters[i - 1].t_s)) {
      set_invalid(error, "invalid forecast quarter");
      return FALSE;
    }
  }
  for (guint i = 0; i < n_days; i++) {
    if (!time_in_range(days[i].start_s) || (i > 0 && days[i].start_s <= days[i - 1].start_s) ||
        (guint)days[i].condition >= WX_COND_COUNT) {
      set_invalid(error, "invalid forecast day");
      return FALSE;
    }
  }
  return TRUE;
}

/* Documented in wx-types.h. */
WxForecast *
wx_forecast_new(const WxPlace *place, gint64 generated_s, const WxBlendHour *hours, guint n_hours,
                const WxQuarter *quarters, guint n_quarters, const WxDay *days, guint n_days,
                const WxSourceStatus *sources, guint n_sources, GError **error)
{
  g_return_val_if_fail(place != NULL, NULL);
  if (!forecast_validate_inputs(generated_s, hours, n_hours, quarters, n_quarters, days, n_days,
                                sources, n_sources, error))
    return NULL;

  WxForecast *fc = g_new0(WxForecast, 1);
  g_atomic_ref_count_init(&fc->ref_count);
  fc->generated_s = generated_s;
  if (!place_init(&fc->place, place->name, place->admin1, place->country, place->country_code,
                  place->lat, place->lon, place->timezone, error)) {
    forecast_release(fc);
    return NULL;
  }

  if (n_hours > 0) {
    WxBlendHour *dst = g_new(WxBlendHour, n_hours);
    fc->hours = dst;
    fc->n_hours = n_hours;
    for (guint i = 0; i < n_hours; i++) {
      const WxBlendHour *src = &hours[i];
      dst[i].t_s = src->t_s;
      dst[i].temp_c = norm_temp(src->temp_c);
      dst[i].feels_c = norm_temp(src->feels_c);
      dst[i].precip_mm = norm_precip(src->precip_mm);
      dst[i].precip_mm_max = norm_precip(src->precip_mm_max);
      dst[i].precip_prob = norm_percent(src->precip_prob);
      dst[i].cloud_pct = norm_percent(src->cloud_pct);
      dst[i].wind_kmh = norm_wind(src->wind_kmh);
      dst[i].gust_kmh = norm_wind(src->gust_kmh);
      dst[i].humidity_pct = norm_percent(src->humidity_pct);
      dst[i].temp_spread_c = norm(src->temp_spread_c, 0.0, WX_TEMP_SPREAD_MAX_C);
      dst[i].n_members = src->n_members;
      dst[i].condition = src->condition;
      dst[i].is_day = src->is_day ? TRUE : FALSE;
    }
  }
  if (n_quarters > 0) {
    fc->quarters = g_memdup2(quarters, (gsize)n_quarters * sizeof(WxQuarter));
    fc->n_quarters = n_quarters;
  }
  if (n_days > 0) {
    WxDay *dst = g_new(WxDay, n_days);
    fc->days = dst;
    fc->n_days = n_days;
    for (guint i = 0; i < n_days; i++) {
      const WxDay *src = &days[i];
      dst[i].start_s = src->start_s;
      dst[i].temp_max_c = norm_temp(src->temp_max_c);
      dst[i].temp_min_c = norm_temp(src->temp_min_c);
      dst[i].precip_mm = norm(src->precip_mm, 0.0, WX_PRECIP_MAX_MM_DAY);
      dst[i].precip_prob_max = norm_percent(src->precip_prob_max);
      dst[i].cloud_pct = norm_percent(src->cloud_pct);
      dst[i].condition = src->condition;
    }
  }
  if (n_sources > 0) {
    WxSourceStatus *dst = g_new0(WxSourceStatus, n_sources);
    fc->sources = dst;
    for (guint i = 0; i < n_sources; i++) {
      const WxSourceStatus *src = &sources[i];
      if (!status_init(&dst[i], src->provider_id, src->name, src->attribution,
                       src->attribution_url, src->state, src->error_code, src->n_members,
                       error)) {
        forecast_release(fc);
        return NULL;
      }
      fc->n_sources = i + 1;
    }
  }
  return fc;
}

/* Documented in wx-types.h. */
WxForecast *
wx_forecast_ref(WxForecast *forecast)
{
  g_return_val_if_fail(forecast != NULL, NULL);
  g_atomic_ref_count_inc(&forecast->ref_count);
  return forecast;
}

/* Documented in wx-types.h. */
void
wx_forecast_unref(WxForecast *forecast)
{
  g_return_if_fail(forecast != NULL);
  if (g_atomic_ref_count_dec(&forecast->ref_count))
    forecast_release(forecast);
}

/* Documented in wx-types.h. */
const WxPlace *
wx_forecast_get_place(const WxForecast *forecast)
{
  g_return_val_if_fail(forecast != NULL, NULL);
  return &forecast->place;
}

/* Documented in wx-types.h. */
gint64
wx_forecast_get_generated_s(const WxForecast *forecast)
{
  g_return_val_if_fail(forecast != NULL, 0);
  return forecast->generated_s;
}

/* Documented in wx-types.h. */
const WxBlendHour *
wx_forecast_get_hours(const WxForecast *forecast, guint *n_hours)
{
  g_return_val_if_fail(forecast != NULL && n_hours != NULL, NULL);
  *n_hours = forecast->n_hours;
  return forecast->hours;
}

/* Documented in wx-types.h. */
const WxQuarter *
wx_forecast_get_quarters(const WxForecast *forecast, guint *n_quarters)
{
  g_return_val_if_fail(forecast != NULL && n_quarters != NULL, NULL);
  *n_quarters = forecast->n_quarters;
  return forecast->quarters;
}

/* Documented in wx-types.h. */
const WxDay *
wx_forecast_get_days(const WxForecast *forecast, guint *n_days)
{
  g_return_val_if_fail(forecast != NULL && n_days != NULL, NULL);
  *n_days = forecast->n_days;
  return forecast->days;
}

/* Documented in wx-types.h. */
const WxSourceStatus *
wx_forecast_get_sources(const WxForecast *forecast, guint *n_sources)
{
  g_return_val_if_fail(forecast != NULL && n_sources != NULL, NULL);
  *n_sources = forecast->n_sources;
  return forecast->sources;
}
