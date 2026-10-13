/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-blend.h - the blend engine: turns the members of several providers into
 * one WxForecast (hourly blend, 15-minute nowcast, daily summary).
 *
 * Pure: no I/O, no GTK, no network, no global state, no locale or local time
 * zone use (all time handling is in UTC unix seconds; the only zone database
 * access is the place's own IANA zone for the daily summary). Deterministic:
 * the same arguments always give the same forecast.
 *
 * Time semantics are those of wx-types.h: an instant variable of an hour
 * bucket is its value AT t_s; precip_mm and precip_prob describe
 * [t_s, t_s + 3600).
 */
#ifndef WX_BLEND_H
#define WX_BLEND_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Most members used by one blend; later ones (in argument order) are ignored. */
#define WX_BLEND_MAX_MEMBERS 128
/** Most hourly buckets kept by one blend, counted from the first bucket. */
#define WX_BLEND_MAX_HOURS 240
/** A forecast needs at least one member that contributed to this many hours. */
#define WX_BLEND_MIN_HOURS 6
/** Most nowcast quarters kept (3 hours, the HRRR 15-minute product's reach). */
#define WX_BLEND_MAX_QUARTERS 12

/**
 * wx_weighted_median:
 * @values: (array length=n) (nullable): the samples.
 * @weights: (array length=n) (nullable): the weight of each sample.
 * @n: number of entries of both arrays, at most WX_BLEND_MAX_MEMBERS.
 *
 * Lower weighted median. An entry takes part only when its value is finite
 * and its weight is finite and above 0; the others are ignored. Let W be the
 * total weight of the taking-part entries and v_1 <= ... <= v_k their values
 * in ascending order with cumulative weights c_1 .. c_k. Let j be the smallest
 * index with 2 * c_j >= W. The result is v_j when 2 * c_j > W; when
 * 2 * c_j == W exactly (the lower values carry exactly 50 % of the weight) it
 * is the mean of v_j and v_(j+1), the two adjacent values, computed as
 * v_j + (v_(j+1) - v_j) / 2 (or (v_j + v_(j+1)) / 2 when they have opposite
 * signs) so that it never overflows and always lies within [v_j, v_(j+1)], even
 * for subnormal values and for +-DBL_MAX. Ties between equal
 * values do not matter. So with equal weights: an odd count gives the middle
 * value, an even count the mean of the two middle values; one dominant weight
 * (above half of W) gives that sample's value. Weights are first scaled by a
 * power of two (exact) so the largest becomes < 1: the sums never overflow and
 * are exact for weights that are multiples of 0.5 (all table weights). In
 * general sums are rounded to double precision, so a weight smaller than
 * about 2^-53 of the total can be absorbed (it then cannot break an exact
 * 50 % tie), and one that scales below the smallest double is ignored.
 *
 * Preconditions:
 *  - @n <= WX_BLEND_MAX_MEMBERS (otherwise critical, NAN returned).
 *  - @values and @weights are non-NULL when @n > 0 (otherwise critical, NAN).
 * Postconditions:
 *  - the arrays are not modified; no allocation.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the weighted median, always one of the input values or the mean of
 *   two adjacent ones (so within [min, max] of the taking-part values, never
 *   infinite); NAN when no entry takes part (including @n == 0).
 */
double wx_weighted_median(const double *values, const double *weights, guint n);

/**
 * wx_blend_forecast:
 * @place: non-NULL place (re-validated and deep-copied by wx_forecast_new()).
 * @results: (array length=n_results) (nullable): the provider results; NULL
 *   only when @n_results is 0. NULL entries, entries without members and
 *   NULL members are skipped.
 * @n_results: number of entries of @results.
 * @statuses: (array length=n_statuses) (nullable): per-source statuses copied
 *   into the forecast unchanged (see wx_forecast_new() for their validation);
 *   NULL only when @n_statuses is 0.
 * @n_statuses: number of statuses, at most WX_FORECAST_MAX_SOURCES.
 * @now_s: the current time, UTC unix seconds, in [WX_TIME_MIN_S,
 *   WX_TIME_MAX_S); it is also the forecast's generated_s.
 * @error: (nullable): return location for a #GError.
 *
 * Blends the members into one forecast.
 *
 * Members: a member takes part only if its ids are valid (wx_id_is_valid()),
 * its counts are within WX_MEMBER_MAX_HOURS / WX_MEMBER_MAX_QUARTERS, its
 * arrays are non-NULL for non-zero counts, and its hours are strictly
 * ascending multiples of 3600 within the time range (hand-built garbage is
 * dropped as a whole, not an error); a hand-built member's out-of-range
 * numbers count as missing. When two members have the same (source_id,
 * model_id) the first one in argument order is used and the others dropped; at
 * most WX_BLEND_MAX_MEMBERS members are used.
 *
 * Region: us_region is TRUE iff a taking-part member of source "nws" exists
 * or the place lies in the NWS box (wx_geo_in_us_nws()) or the CONUS box
 * (wx_geo_in_conus()). It selects the weights table of wx_weight_for().
 *
 * Hours: the buckets start at the hour containing @now_s minus one hour
 * (never before WX_TIME_MIN_S) and run contiguously, one per 3600 s, up to
 * the latest hour at which any taking-part member has a value, at most
 * WX_BLEND_MAX_HOURS buckets. A bucket nobody has data for stays in the list
 * with all values NAN, n_members 0, condition WX_COND_UNKNOWN. For every
 * bucket and every variable the finite in-range member values are gathered
 * with weight wx_weight_for(source, model, group, horizon_h, us_region),
 * horizon_h = max(0, (t_s - @now_s) / 3600); weight <= 0 excludes the value;
 * the result is wx_weighted_median(). Variables: temp_c, feels_c (group TEMP),
 * humidity_pct, wind_kmh and gust_kmh (WIND), cloud_pct, precip_mm
 * (PRECIP_MM), precip_prob (PRECIP_PROB). precip_mm_max is the largest
 * precipitation value among the gathered members. precip_prob is the weighted
 * median over members that supply a probability; when none does it is derived
 * from the gathered precipitation values: 100 * (weight of the members with
 * precip_mm >= 0.1) / (weight of all of them) (NAN when there is no
 * precipitation value). n_members is the number of distinct members that
 * contributed at least one gathered value to the bucket; temp_spread_c is
 * max - min of the gathered temperatures (NAN with fewer than two). A
 * variable without any value is NAN. condition comes from
 * wx_condition_derive() with the WMO codes (0..99) of the contributing
 * members of that bucket; is_day is wx_sun_is_up() of the place at t_s.
 *
 * Nowcast: if a member open-meteo:hrrr15 has an unbroken run of 15-minute
 * quarters starting with the quarter containing @now_s and ending at or after
 * @now_s + 1800 (amounts finite in [0, WX_PRECIP_MAX_MM_H]), then (a) for every
 * bucket fully covered by four such consecutive quarters whose sum is at most
 * WX_PRECIP_MAX_MM_H, the precipitation of the open-meteo:hrrr member in that
 * bucket is replaced by the sum of the quarters (only if that member has an
 * hour there; hrrr15 never votes by itself) before blending; and (b) forecast
 * quarters are the run's quarters from the one containing @now_s onward, at
 * most WX_BLEND_MAX_QUARTERS. Every hour that starts on the hour, is covered
 * by four of them and has a finite blended precip_mm is rescaled to sum to
 * that bucket's BLENDED precip_mm (up to floating point rounding): when the
 * blended amount or the four raw amounts' sum is below 1e-9 mm (zero and every
 * subnormal included) the blended amount is spread evenly, a quarter of it
 * each, rounded to nearest (exact unless blended is subnormal, where the
 * four quarters sum to within 2 subnormal ulps of blended, ABOVE or below;
 * zero gives four zeros); otherwise the three smaller quarters become
 * MIN(quarter * blended / raw sum, blended), the largest MAX(0, blended - the
 * other three), and every quarter is finally clamped into
 * [0, MIN(blended, WX_PRECIP_MAX_MM_H)]. So EVERY quarter of such an hour is
 * finite and within [0, blended] (tested down to 1 ulp of the smallest
 * subnormal), whatever the raw amounts. Quarters of an hour not fully in the list, and
 * of an hour whose blended precip_mm is NAN, keep their raw amounts, which are within
 * [0, WX_PRECIP_MAX_MM_H]. Without a
 * usable nowcast the forecast has no quarters.
 *
 * Daily summary: wx_daily_build() on the blended hours with the place's zone
 * and @now_s: today is listed while the list holds one covered hour of it, and
 * its summary covers the hours of today from the first bucket of this list on
 * (the hour before the one that contains now), see wx-daily.h.
 *
 * Preconditions:
 *  - @place is non-NULL; @results is non-NULL when @n_results > 0; @statuses is
 *    non-NULL when @n_statuses > 0; *@error is NULL when @error is non-NULL
 *    (programmer errors: critical, NULL returned).
 *  - the arguments are not modified by another thread during the call; the
 *    members are immutable (shared members always are).
 * Postconditions:
 *  - on success: a new forecast with generated_s == @now_s, hours ascending
 *    (multiples of 3600, at most WX_BLEND_MAX_HOURS), whose every value is NAN
 *    or within its valid range; no argument is modified.
 *  - on failure: NULL and @error set (nothing leaks):
 *    WX_ERROR_NOT_FOUND "no usable forecast data" when no taking-part member
 *    contributed to at least WX_BLEND_MIN_HOURS hours; WX_ERROR_INVALID_ARG
 *    when @now_s is outside the time range or wx_forecast_new() rejects the
 *    place or the statuses.
 * Thread affinity: any thread (pure; the result is private to the caller).
 * Ownership: arguments stay with the caller; the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the forecast; wx_forecast_unref() it.
 */
WxForecast *wx_blend_forecast(const WxPlace *place, const WxSourceResult *const *results,
                              guint n_results, const WxSourceStatus *statuses,
                              guint n_statuses, gint64 now_s, GError **error);

/**
 * wx_forecast_now:
 * @forecast: non-NULL forecast.
 * @now_s: the instant to evaluate, UTC unix seconds.
 * @out: (out): receives the values at @now_s.
 *
 * The "current conditions" of a forecast. Finds the bucket k with
 * t_s <= @now_s < t_s + 3600. The instant variables temp_c, feels_c,
 * humidity_pct, wind_kmh, cloud_pct and gust_kmh are interpolated linearly
 * between bucket k and bucket k + 1 when the latter exists and starts exactly
 * 3600 s later (the design names the first five; gusts are interpolated too
 * because a gust frozen at the bucket's value could end up below the
 * interpolated wind). If only one of the two values is finite that one is
 * used; if neither is, the result is NAN. All
 * other fields (precip_mm, precip_mm_max, precip_prob, temp_spread_c,
 * n_members) are those of bucket k; t_s is @now_s; is_day is
 * wx_sun_is_up() of the forecast's place at @now_s. condition is that of
 * bucket k, except that a sky class of the bucket (WX_COND_CLEAR ..
 * WX_COND_OVERCAST) or WX_COND_UNKNOWN becomes wx_cloud_condition() of the
 * interpolated cloud_pct when that is finite, so for a dry bucket the
 * condition word and the cloud cover of the result are those of one cloud
 * value; a precipitation, fog, snow, sleet or thunderstorm class of the
 * bucket is kept as it is.
 *
 * Preconditions:
 *  - @forecast and @out are non-NULL and @forecast->hours is non-NULL when
 *    n_hours > 0, with n_hours readable entries (NULL: critical, FALSE
 *    returned, @out untouched).
 *  - nothing else is required: the function is total and memory safe for any
 *    hand-built forecast (unsorted, duplicated, unaligned or out-of-range time
 *    stamps, any @now_s, any values). The hours are scanned in array order and
 *    the first bucket containing @now_s is used; time differences are computed
 *    without signed overflow. (It reads no other array and has no stack
 *    buffer.)
 * Postconditions:
 *  - on TRUE *@out is filled; on FALSE (no bucket contains @now_s) it is
 *    untouched.
 * Thread affinity: any thread (the forecast is immutable).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff a bucket contains @now_s.
 */
gboolean wx_forecast_now(const WxForecast *forecast, gint64 now_s, WxBlendHour *out);

G_END_DECLS

#endif /* WX_BLEND_H */
