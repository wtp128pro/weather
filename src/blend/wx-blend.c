/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-blend.h"

#include <math.h>
#include <string.h>

#include "wx-condition.h"
#include "wx-daily.h"
#include "wx-geo.h"
#include "wx-types.h"
#include "wx-weights.h"

#define HOUR_S 3600
#define QUARTER_S 900

/* A precipitation value from this many mm counts the member as "wet" when the
 * probability is derived. */
#define DERIVED_PROB_WET_MM 0.1

/* A nowcast hour whose quarters sum to less than this many mm counts as dry when the
 * quarters are rescaled (the ratio blended / sum of such a sum could overflow). */
#define NOWCAST_MIN_RAW_MM 1e-9

/* ------------------------------------------------------------------------ */
/* Weighted median                                                          */
/* ------------------------------------------------------------------------ */

/* A sample and its (scaled) weight. */
typedef struct {
  double value;
  double weight;
} Entry;

/**
 * mean_of_pair:
 * @a: the smaller value.
 * @b: the larger value (a <= b), both finite.
 *
 * The mean of two ordered finite doubles that is always within [@a, @b]: for
 * values of one sign (or zero) @a + (@b - @a) / 2 (the difference cannot
 * overflow; rounding is monotone, so the result stays in the interval), for
 * values of opposite signs (@a + @b) / 2 (the sum cannot overflow). The naive
 * a / 2 + b / 2 loses the last bit of subnormals and can end below @a.
 *
 * Preconditions:
 *  - @a and @b are finite and @a <= @b.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the mean, within [@a, @b].
 */
static double
mean_of_pair(double a, double b)
{
  if (a < 0.0 && b > 0.0)
    return (a + b) / 2.0;
  return a + (b - a) / 2.0;
}

/* Documented in wx-blend.h. */
double
wx_weighted_median(const double *values, const double *weights, guint n)
{
  g_return_val_if_fail(n <= WX_BLEND_MAX_MEMBERS, NAN);
  g_return_val_if_fail(n == 0 || (values != NULL && weights != NULL), NAN);

  double max_weight = 0.0;
  for (guint i = 0; i < n; i++) {
    if (isfinite(values[i]) && isfinite(weights[i]) && weights[i] > 0.0)
      max_weight = fmax(max_weight, weights[i]);
  }
  if (max_weight == 0.0)
    return NAN;

  /* Scaling by a power of two is exact, and keeps the sums below 128 whatever
   * the magnitude of the weights. */
  int exponent;
  frexp(max_weight, &exponent);

  Entry sorted[WX_BLEND_MAX_MEMBERS];
  guint k = 0;
  for (guint i = 0; i < n; i++) {
    if (!isfinite(values[i]) || !isfinite(weights[i]) || weights[i] <= 0.0)
      continue;
    double w = ldexp(weights[i], -exponent);
    if (w <= 0.0) /* underflow: negligible next to the largest weight */
      continue;
    guint j = k++;
    while (j > 0 && sorted[j - 1].value > values[i]) {
      sorted[j] = sorted[j - 1];
      j--;
    }
    sorted[j].value = values[i];
    sorted[j].weight = w;
  }

  double total = 0.0;
  for (guint i = 0; i < k; i++)
    total += sorted[i].weight;

  /* The last cumulative weight is exactly total (same summation order), so the loop ends
   * at the latest on the last entry, where 2 * cumulative > total. */
  guint i = 0;
  double cumulative = sorted[0].weight;
  while (cumulative * 2.0 < total)
    cumulative += sorted[++i].weight;
  if (cumulative * 2.0 == total) /* the lower values carry exactly half, so i + 1 < k */
    return mean_of_pair(sorted[i].value, sorted[i + 1].value);
  return sorted[i].value;
}

/* ------------------------------------------------------------------------ */
/* Members                                                                  */
/* ------------------------------------------------------------------------ */

/* The variables that are blended one by one. */
typedef enum {
  F_TEMP,
  F_FEELS,
  F_HUMIDITY,
  F_WIND,
  F_GUST,
  F_CLOUD,
  F_PRECIP,
  F_PROB,
  F_COUNT
} Field;

/* Weight group, valid range and storage offset of each field. */
static const struct {
  WxVar var;
  double lo;
  double hi;
  gsize offset;
} field_info[F_COUNT] = {
  [F_TEMP] = {WX_VAR_TEMP, WX_TEMP_MIN_C, WX_TEMP_MAX_C, G_STRUCT_OFFSET(WxHour, temp_c)},
  [F_FEELS] = {WX_VAR_TEMP, WX_TEMP_MIN_C, WX_TEMP_MAX_C, G_STRUCT_OFFSET(WxHour, feels_c)},
  [F_HUMIDITY] = {WX_VAR_HUMIDITY, WX_PERCENT_MIN, WX_PERCENT_MAX,
                  G_STRUCT_OFFSET(WxHour, humidity_pct)},
  [F_WIND] = {WX_VAR_WIND, 0.0, WX_WIND_MAX_KMH, G_STRUCT_OFFSET(WxHour, wind_kmh)},
  [F_GUST] = {WX_VAR_WIND, 0.0, WX_WIND_MAX_KMH, G_STRUCT_OFFSET(WxHour, gust_kmh)},
  [F_CLOUD] = {WX_VAR_CLOUD, WX_PERCENT_MIN, WX_PERCENT_MAX, G_STRUCT_OFFSET(WxHour, cloud_pct)},
  [F_PRECIP] = {WX_VAR_PRECIP_MM, 0.0, WX_PRECIP_MAX_MM_H, G_STRUCT_OFFSET(WxHour, precip_mm)},
  [F_PROB] = {WX_VAR_PRECIP_PROB, WX_PERCENT_MIN, WX_PERCENT_MAX,
              G_STRUCT_OFFSET(WxHour, precip_prob)},
};

/**
 * field_value:
 * @hour: non-NULL hour.
 * @field: the field to read.
 *
 * Preconditions:
 *  - @hour is non-NULL and @field < F_COUNT.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the raw (not range-checked) value of the field.
 */
static double
field_value(const WxHour *hour, Field field)
{
  return G_STRUCT_MEMBER(double, hour, field_info[field].offset);
}

/**
 * hour_has_value:
 * @hour: non-NULL hour.
 *
 * Preconditions:
 *  - @hour is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff at least one field of the hour is finite and in range.
 */
static gboolean
hour_has_value(const WxHour *hour)
{
  for (int f = 0; f < F_COUNT; f++) {
    if (wx_value_in_range(field_value(hour, f), field_info[f].lo, field_info[f].hi))
      return TRUE;
  }
  return FALSE;
}

/* A member taking part in the blend, with the per-bucket scratch state. */
typedef struct {
  const WxMember *member;
  gboolean is_hrrr;      /* open-meteo:hrrr: its precipitation may be overridden */
  guint cursor;          /* index of the next hour not before the current bucket */
  const WxHour *current; /* the member's hour in the current bucket, or NULL */
  gboolean contributed;  /* it gave a value to the current bucket */
  guint hours_contributed;
} BlendMember;

/**
 * member_is_valid:
 * @member: (nullable): a member, possibly hand-built.
 *
 * Preconditions:
 *  - none (a NULL member is simply invalid).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the ids are valid, the hour count and pointer are
 *   consistent and the hours are strictly ascending multiples of 3600 within
 *   the time range.
 */
static gboolean
member_is_valid(const WxMember *member)
{
  if (member == NULL || !wx_id_is_valid(member->source_id) || !wx_id_is_valid(member->model_id))
    return FALSE;
  if (member->n_hours > WX_MEMBER_MAX_HOURS || (member->n_hours > 0 && member->hours == NULL))
    return FALSE;
  for (guint i = 0; i < member->n_hours; i++) {
    gint64 t = member->hours[i].t_s;
    if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || t % HOUR_S != 0 ||
        (i > 0 && t <= member->hours[i - 1].t_s))
      return FALSE;
  }
  return TRUE;
}

/**
 * is_member:
 * @member: non-NULL member.
 * @source_id: source id to compare with.
 * @model_id: model id to compare with.
 *
 * Preconditions:
 *  - @member has valid ids; the other arguments are NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the member has exactly these ids.
 */
static gboolean
is_member(const WxMember *member, const char *source_id, const char *model_id)
{
  return strcmp(member->source_id, source_id) == 0 && strcmp(member->model_id, model_id) == 0;
}

/**
 * collect_members:
 * @results: (array length=n_results) (nullable): provider results.
 * @n_results: number of results.
 * @out: (array length=WX_BLEND_MAX_MEMBERS): receives the members.
 *
 * Preconditions:
 *  - @results is non-NULL when @n_results > 0.
 * Postconditions:
 *  - the first returned entries of @out are initialised; they hold valid,
 *    pairwise distinct (source, model) members in argument order.
 * Thread affinity: any thread.
 * Ownership: the members stay owned by the results.
 *
 * Returns: the number of members collected, at most WX_BLEND_MAX_MEMBERS.
 */
static guint
collect_members(const WxSourceResult *const *results, guint n_results, BlendMember *out)
{
  guint n = 0;
  for (guint r = 0; r < n_results; r++) {
    if (results[r] == NULL || results[r]->members == NULL)
      continue;
    for (guint k = 0; k < results[r]->members->len; k++) {
      const WxMember *m = g_ptr_array_index(results[r]->members, k);
      if (!member_is_valid(m))
        continue;
      gboolean duplicate = FALSE;
      for (guint i = 0; i < n && !duplicate; i++)
        duplicate = is_member(out[i].member, m->source_id, m->model_id);
      if (duplicate)
        continue;
      if (n == WX_BLEND_MAX_MEMBERS)
        return n;
      out[n] = (BlendMember){.member = m, .is_hrrr = is_member(m, "open-meteo", "hrrr")};
      n++;
    }
  }
  return n;
}

/**
 * region_is_us:
 * @place: non-NULL place.
 * @members: the members taking part.
 * @n: number of members.
 *
 * Preconditions:
 *  - @place is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff a member of source "nws" exists or the place is in the NWS
 *   or CONUS boxes.
 */
static gboolean
region_is_us(const WxPlace *place, const BlendMember *members, guint n)
{
  for (guint i = 0; i < n; i++) {
    if (strcmp(members[i].member->source_id, "nws") == 0)
      return TRUE;
  }
  return wx_geo_in_us_nws(place->lat, place->lon) || wx_geo_in_conus(place->lat, place->lon);
}

/* ------------------------------------------------------------------------ */
/* Nowcast                                                                  */
/* ------------------------------------------------------------------------ */

/* The usable run of 15-minute quarters of open-meteo:hrrr15. */
typedef struct {
  const WxQuarter *quarters; /* all quarters of the member */
  guint n_quarters;
  guint first;               /* index of the quarter containing now */
  guint count;               /* quarters kept for the forecast, at most WX_BLEND_MAX_QUARTERS */
} Nowcast;

/**
 * quarter_is_ok:
 * @quarter: non-NULL quarter.
 *
 * Preconditions:
 *  - @quarter is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the amount is finite within [0, WX_PRECIP_MAX_MM_H].
 */
static gboolean
quarter_is_ok(const WxQuarter *quarter)
{
  return wx_value_in_range(quarter->precip_mm, 0.0, WX_PRECIP_MAX_MM_H);
}

/**
 * find_nowcast:
 * @members: the members taking part.
 * @n: number of members.
 * @now_s: the current time.
 * @nc: (out): receives the run on success.
 *
 * Preconditions:
 *  - none beyond valid arguments.
 * Postconditions:
 *  - *@nc is written only when TRUE is returned.
 * Thread affinity: any thread.
 * Ownership: *@nc points into the member, which the caller keeps alive.
 *
 * Returns: TRUE iff open-meteo:hrrr15 exists with consistent, strictly
 *   ascending quarters (multiples of 900 within the time range) and an
 *   unbroken run of valid quarters that starts with the one containing @now_s
 *   and ends at or after @now_s + 1800.
 */
static gboolean
find_nowcast(const BlendMember *members, guint n, gint64 now_s, Nowcast *nc)
{
  const WxMember *m = NULL;
  for (guint i = 0; i < n && m == NULL; i++) {
    if (is_member(members[i].member, "open-meteo", "hrrr15"))
      m = members[i].member;
  }
  if (m == NULL || m->n_quarters == 0 || m->n_quarters > WX_MEMBER_MAX_QUARTERS ||
      m->quarters == NULL)
    return FALSE;
  for (guint i = 0; i < m->n_quarters; i++) {
    gint64 t = m->quarters[i].t_s;
    if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || t % QUARTER_S != 0 ||
        (i > 0 && t <= m->quarters[i - 1].t_s))
      return FALSE;
  }

  gint64 q0 = now_s - now_s % QUARTER_S;
  guint first = 0;
  while (first < m->n_quarters && m->quarters[first].t_s != q0)
    first++;
  guint run = 0;
  while (first + run < m->n_quarters &&
         m->quarters[first + run].t_s == q0 + (gint64)run * QUARTER_S &&
         quarter_is_ok(&m->quarters[first + run]))
    run++;
  if (run == 0 || q0 + (gint64)run * QUARTER_S < now_s + 1800)
    return FALSE;

  nc->quarters = m->quarters;
  nc->n_quarters = m->n_quarters;
  nc->first = first;
  nc->count = MIN(run, WX_BLEND_MAX_QUARTERS);
  return TRUE;
}

/**
 * nowcast_hour_sums:
 * @nc: the usable nowcast.
 * @start_s: start of bucket 0.
 * @n_buckets: number of buckets.
 * @sums: (array length=n_buckets) (out): receives the sums.
 *
 * Preconditions:
 *  - @nc comes from find_nowcast().
 * Postconditions:
 *  - sums[i] is the sum of the four quarters of bucket i when all four exist
 *    and are valid and the sum is within [0, WX_PRECIP_MAX_MM_H]; NAN
 *    otherwise.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
nowcast_hour_sums(const Nowcast *nc, gint64 start_s, guint n_buckets, double *sums)
{
  for (guint i = 0; i < n_buckets; i++)
    sums[i] = NAN;
  const WxQuarter *q = nc->quarters;
  for (guint j = 0; j + 3 < nc->n_quarters; j++) {
    gint64 t = q[j].t_s;
    /* strictly ascending multiples of 900: the last one 2700 s later means all four */
    if (t % HOUR_S != 0 || t < start_s || q[j + 3].t_s != t + 3 * QUARTER_S)
      continue;
    if (!quarter_is_ok(&q[j]) || !quarter_is_ok(&q[j + 1]) || !quarter_is_ok(&q[j + 2]) ||
        !quarter_is_ok(&q[j + 3]))
      continue;
    gint64 bucket = (t - start_s) / HOUR_S;
    double sum = ((q[j].precip_mm + q[j + 1].precip_mm) + q[j + 2].precip_mm) + q[j + 3].precip_mm;
    if ((guint64)bucket < n_buckets && wx_value_in_range(sum, 0.0, WX_PRECIP_MAX_MM_H))
      sums[bucket] = sum;
  }
}

/**
 * build_quarters:
 * @nc: the usable nowcast.
 * @hours: the blended hours.
 * @n_hours: number of blended hours, at least 6.
 * @start_s: start of bucket 0 (= hours[0].t_s).
 * @out: (array length=WX_BLEND_MAX_QUARTERS) (out): receives the quarters.
 *
 * Fills @out with the raw nowcast quarters and then rescales every hour that
 * starts on the hour and is covered by four of them (and whose blended
 * precip_mm is finite) so that the hour sums to the blended amount. The blended
 * amount is a weighted median of values in [0, WX_PRECIP_MAX_MM_H], so it is
 * itself in that range.
 *
 * The rescaling is ROBUST BY CONSTRUCTION, it does not rely on rounding
 * arguments: when the blended amount or the raw sum is below
 * NOWCAST_MIN_RAW_MM (0 and every subnormal included; the ratio of such a
 * number could overflow or round badly) the amount is spread evenly,
 * blended / 4 each. Otherwise the ratio blended / raw is at most 5e11 (finite),
 * each of the three smaller quarters becomes MIN(quarter * ratio, blended),
 * the largest one MAX(0, blended - (the other three)), and finally EVERY
 * written quarter is clamped into [0, MIN(blended, WX_PRECIP_MAX_MM_H)].
 *
 * Preconditions:
 *  - @nc comes from find_nowcast(); @hours are the blended buckets, every
 *    finite precip_mm within [0, WX_PRECIP_MAX_MM_H].
 * Postconditions:
 *  - out[0 .. nc->count) are the quarters. A quarter that belongs to an hour
 *    covered by four quarters with a finite blended precip_mm is finite and
 *    within [0, blended]; its hour sums to blended within a few ulps of
 *    rounding. In the even spread blended / 4 is exact unless blended is
 *    subnormal; then each quarter is rounded to nearest, off by at most half a
 *    subnormal ulp (4.94e-324) in EITHER direction (3 ulps give quarters of
 *    1 ulp each: the sum, 4 ulps, is ABOVE blended; 5 ulps give 1 ulp each:
 *    below), so the sum is within 2 subnormal ulps of blended (the tests
 *    assert 4) while every quarter stays within [0, blended]; 0 gives four
 *    zeros. Other
 *    quarters keep their raw amounts, which are finite and within
 *    [0, WX_PRECIP_MAX_MM_H] (find_nowcast() checked them).
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
build_quarters(const Nowcast *nc, const WxBlendHour *hours, guint n_hours, gint64 start_s,
               WxQuarter *out)
{
  for (guint i = 0; i < nc->count; i++)
    out[i] = nc->quarters[nc->first + i];

  for (guint j = 0; j + 3 < nc->count; j++) {
    gint64 t = out[j].t_s;
    if (t % HOUR_S != 0)
      continue;
    /* t >= now's quarter >= start_s, and the list has at least WX_BLEND_MIN_HOURS (6) buckets
     * while the quarters reach at most 3 hours past now: the bucket exists */
    gint64 bucket = (t - start_s) / HOUR_S;
    /* both conditions hold for a usable nowcast (bucket in [0, 4], at least 6 buckets); the
     * index is nevertheless checked, never asserted */
    if ((guint64)bucket >= n_hours || !isfinite(hours[bucket].precip_mm))
      continue;
    double blended = hours[bucket].precip_mm;
    double cap = fmin(blended, WX_PRECIP_MAX_MM_H);
    double raw = ((out[j].precip_mm + out[j + 1].precip_mm) + out[j + 2].precip_mm) +
                 out[j + 3].precip_mm;
    gboolean even = blended < NOWCAST_MIN_RAW_MM || raw < NOWCAST_MIN_RAW_MM;
    guint big = 0;
    for (guint k = 1; k < 4; k++) {
      if (out[j + k].precip_mm > out[j + big].precip_mm)
        big = k;
    }
    double ratio = even ? 0.0 : blended / raw;
    double rest = 0.0;
    for (guint k = 0; k < 4; k++) {
      if (k == big)
        continue;
      out[j + k].precip_mm = even ? blended / 4.0 : fmin(out[j + k].precip_mm * ratio, blended);
      rest += out[j + k].precip_mm;
    }
    out[j + big].precip_mm = even ? blended / 4.0 : fmax(0.0, blended - rest);
    for (guint k = 0; k < 4; k++)
      out[j + k].precip_mm = CLAMP(out[j + k].precip_mm, 0.0, cap);
    j += 3;
  }
}

/* ------------------------------------------------------------------------ */
/* The blend                                                                */
/* ------------------------------------------------------------------------ */

/**
 * gather:
 * @members: the members taking part.
 * @n: number of members.
 * @field: the field to gather.
 * @sums: the nowcast sums per bucket (NAN where there is none).
 * @bucket: index of the current bucket.
 * @horizon_h: horizon of the bucket, hours, >= 0.
 * @us_region: the region.
 * @values: (array length=WX_BLEND_MAX_MEMBERS) (out): the member values.
 * @weights: (array length=WX_BLEND_MAX_MEMBERS) (out): their weights.
 *
 * Collects the finite, in-range values of one field of the current bucket
 * whose weight is above 0 (the hrrr member's precipitation is replaced by the
 * nowcast sum when there is one) and marks the members as contributing.
 *
 * Preconditions:
 *  - every member's `current` is set for this bucket.
 * Postconditions:
 *  - values[i]/weights[i] describe the i-th taking-part member, in member order.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the number of values gathered.
 */
static guint
gather(BlendMember *members, guint n, Field field, const double *sums, guint bucket,
       double horizon_h, gboolean us_region, double *values, double *weights)
{
  guint k = 0;
  for (guint i = 0; i < n; i++) {
    const WxHour *h = members[i].current;
    if (h == NULL)
      continue;
    double v = field_value(h, field);
    if (field == F_PRECIP && members[i].is_hrrr && isfinite(sums[bucket]))
      v = sums[bucket];
    if (!wx_value_in_range(v, field_info[field].lo, field_info[field].hi))
      continue;
    double w = wx_weight_for(members[i].member->source_id, members[i].member->model_id,
                             field_info[field].var, horizon_h, us_region);
    if (!(w > 0.0))
      continue;
    values[k] = v;
    weights[k] = w;
    k++;
    members[i].contributed = TRUE;
  }
  return k;
}

/**
 * blend_bucket:
 * @members: the members taking part (scratch state is updated).
 * @n: number of members.
 * @sums: nowcast sums per bucket.
 * @bucket: index of the bucket.
 * @t_s: start of the bucket.
 * @now_s: the current time.
 * @us_region: the region.
 * @place: non-NULL place (for the day/night flag).
 * @out: (out): receives the blended hour; every field is written.
 *
 * Preconditions:
 *  - every member's cursor is at the first hour not before the previous bucket.
 * Postconditions:
 *  - *@out is complete; the members' cursors are at the first hour not before
 *    @t_s and their hours_contributed counters are updated.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
blend_bucket(BlendMember *members, guint n, const double *sums, guint bucket, gint64 t_s,
             gint64 now_s, gboolean us_region, const WxPlace *place, WxBlendHour *out)
{
  double horizon_h = MAX((double)(t_s - now_s), 0.0) / HOUR_S;
  double values[WX_BLEND_MAX_MEMBERS], weights[WX_BLEND_MAX_MEMBERS];
  double mm_values[WX_BLEND_MAX_MEMBERS], mm_weights[WX_BLEND_MAX_MEMBERS];

  for (guint i = 0; i < n; i++) {
    BlendMember *m = &members[i];
    while (m->cursor < m->member->n_hours && m->member->hours[m->cursor].t_s < t_s)
      m->cursor++;
    m->current = (m->cursor < m->member->n_hours && m->member->hours[m->cursor].t_s == t_s)
                     ? &m->member->hours[m->cursor]
                     : NULL;
    m->contributed = FALSE;
  }

  out->t_s = t_s;

  guint k = gather(members, n, F_TEMP, sums, bucket, horizon_h, us_region, values, weights);
  out->temp_c = wx_weighted_median(values, weights, k);
  out->temp_spread_c = NAN;
  if (k >= 2) {
    double lo = values[0], hi = values[0];
    for (guint i = 1; i < k; i++) {
      lo = fmin(lo, values[i]);
      hi = fmax(hi, values[i]);
    }
    out->temp_spread_c = hi - lo;
  }

  k = gather(members, n, F_FEELS, sums, bucket, horizon_h, us_region, values, weights);
  out->feels_c = wx_weighted_median(values, weights, k);
  k = gather(members, n, F_HUMIDITY, sums, bucket, horizon_h, us_region, values, weights);
  out->humidity_pct = wx_weighted_median(values, weights, k);
  k = gather(members, n, F_WIND, sums, bucket, horizon_h, us_region, values, weights);
  out->wind_kmh = wx_weighted_median(values, weights, k);
  k = gather(members, n, F_GUST, sums, bucket, horizon_h, us_region, values, weights);
  out->gust_kmh = wx_weighted_median(values, weights, k);
  k = gather(members, n, F_CLOUD, sums, bucket, horizon_h, us_region, values, weights);
  out->cloud_pct = wx_weighted_median(values, weights, k);

  guint n_mm = gather(members, n, F_PRECIP, sums, bucket, horizon_h, us_region, mm_values,
                      mm_weights);
  out->precip_mm = wx_weighted_median(mm_values, mm_weights, n_mm);
  out->precip_mm_max = NAN;
  for (guint i = 0; i < n_mm; i++)
    out->precip_mm_max = fmax(out->precip_mm_max, mm_values[i]);

  k = gather(members, n, F_PROB, sums, bucket, horizon_h, us_region, values, weights);
  if (k > 0) {
    out->precip_prob = wx_weighted_median(values, weights, k);
  } else if (n_mm > 0) {
    double wet = 0.0, all = 0.0;
    for (guint i = 0; i < n_mm; i++) {
      all += mm_weights[i];
      if (mm_values[i] >= DERIVED_PROB_WET_MM)
        wet += mm_weights[i];
    }
    /* wet <= all and both are sums of multiples of 0.5 (exact), so 100 * wet is exact and
     * 100 * wet / all <= 100 (the quotient of exact values rounds monotonically) */
    out->precip_prob = 100.0 * wet / all;
  } else {
    out->precip_prob = NAN;
  }

  int votes[WX_BLEND_MAX_MEMBERS];
  guint n_votes = 0;
  guint n_contributing = 0;
  for (guint i = 0; i < n; i++) {
    if (!members[i].contributed)
      continue;
    n_contributing++;
    members[i].hours_contributed++;
    if (members[i].current->wmo >= 0 && members[i].current->wmo <= 99)
      votes[n_votes++] = members[i].current->wmo;
  }
  out->n_members = (guint8)n_contributing; /* at most WX_BLEND_MAX_MEMBERS */

  WxConditionInput input = {
    .cloud_pct = out->cloud_pct,
    .precip_prob = out->precip_prob,
    .precip_mm_h = out->precip_mm,
    .temp_c = out->temp_c,
    .wmo_votes = votes,
    .n_wmo_votes = n_votes,
  };
  out->condition = wx_condition_derive(&input);
  out->is_day = wx_sun_is_up(place->lat, place->lon, t_s);
}

/**
 * last_hour_with_value:
 * @members: the members taking part.
 * @n: number of members.
 * @start_s: first instant that counts.
 * @t_s: (out): receives the latest hour start.
 *
 * Preconditions:
 *  - none beyond valid arguments.
 * Postconditions:
 *  - *@t_s is written only when TRUE is returned.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff some member has an hour at or after @start_s with a
 *   finite in-range value.
 */
static gboolean
last_hour_with_value(const BlendMember *members, guint n, gint64 start_s, gint64 *t_s)
{
  gboolean found = FALSE;
  for (guint i = 0; i < n; i++) {
    const WxMember *m = members[i].member;
    for (guint k = m->n_hours; k > 0; k--) {
      const WxHour *h = &m->hours[k - 1];
      if (h->t_s < start_s)
        break;
      if (hour_has_value(h)) {
        if (!found || h->t_s > *t_s)
          *t_s = h->t_s;
        found = TRUE;
        break;
      }
    }
  }
  return found;
}

/* Documented in wx-blend.h. */
WxForecast *
wx_blend_forecast(const WxPlace *place, const WxSourceResult *const *results, guint n_results,
                  const WxSourceStatus *statuses, guint n_statuses, gint64 now_s, GError **error)
{
  g_return_val_if_fail(place != NULL, NULL);
  g_return_val_if_fail(results != NULL || n_results == 0, NULL);
  g_return_val_if_fail(statuses != NULL || n_statuses == 0, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);

  if (now_s < WX_TIME_MIN_S || now_s >= WX_TIME_MAX_S) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "time is outside the supported range");
    return NULL;
  }

  BlendMember members[WX_BLEND_MAX_MEMBERS];
  guint n = collect_members(results, n_results, members);

  gint64 start_s = MAX(now_s - now_s % HOUR_S - HOUR_S, (gint64)WX_TIME_MIN_S);
  gint64 last_s = 0;
  if (!last_hour_with_value(members, n, start_s, &last_s)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_NOT_FOUND, "no usable forecast data");
    return NULL;
  }
  guint n_hours = (guint)MIN((last_s - start_s) / HOUR_S + 1, (gint64)WX_BLEND_MAX_HOURS);

  gboolean us_region = region_is_us(place, members, n);

  g_autofree double *sums = g_new(double, n_hours);
  Nowcast nc;
  gboolean have_nowcast = find_nowcast(members, n, now_s, &nc);
  if (have_nowcast) {
    nowcast_hour_sums(&nc, start_s, n_hours, sums);
  } else {
    for (guint i = 0; i < n_hours; i++)
      sums[i] = NAN;
  }

  g_autofree WxBlendHour *hours = g_new0(WxBlendHour, n_hours);
  for (guint i = 0; i < n_hours; i++)
    blend_bucket(members, n, sums, i, start_s + (gint64)i * HOUR_S, now_s, us_region, place,
                 &hours[i]);

  guint best = 0;
  for (guint i = 0; i < n; i++)
    best = MAX(best, members[i].hours_contributed);
  if (best < WX_BLEND_MIN_HOURS) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_NOT_FOUND, "no usable forecast data");
    return NULL;
  }

  WxQuarter quarters[WX_BLEND_MAX_QUARTERS] = {{0, 0.0}};
  guint n_quarters = 0;
  if (have_nowcast) {
    build_quarters(&nc, hours, n_hours, start_s, quarters);
    n_quarters = nc.count;
  }

  WxDay days[WX_DAILY_MAX_DAYS];
  memset(days, 0, sizeof days);
  guint n_days = wx_daily_build(place->timezone, hours, n_hours, now_s, days);

  return wx_forecast_new(place, now_s, hours, n_hours, quarters, n_quarters, days, n_days,
                         statuses, n_statuses, error);
}

/* ------------------------------------------------------------------------ */
/* Current conditions                                                       */
/* ------------------------------------------------------------------------ */

/**
 * lerp_known:
 * @a: value at the start of the interval, NAN if unknown.
 * @b: value at its end, NAN if unknown.
 * @frac: position in [0, 1).
 *
 * Preconditions:
 *  - @frac is in [0, 1).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: none.
 *
 * Returns: the linear interpolation (kept within [a, b] against rounding) when
 *   both are finite, the finite one when only one is, NAN otherwise.
 */
static double
lerp_known(double a, double b, double frac)
{
  if (isfinite(a) && isfinite(b))
    return CLAMP(a + (b - a) * frac, MIN(a, b), MAX(a, b));
  if (isfinite(a))
    return a;
  return isfinite(b) ? b : NAN;
}

/* Documented in wx-blend.h. */
gboolean
wx_forecast_now(const WxForecast *forecast, gint64 now_s, WxBlendHour *out)
{
  g_return_val_if_fail(forecast != NULL, FALSE);
  g_return_val_if_fail(out != NULL, FALSE);
  g_return_val_if_fail(forecast->hours != NULL || forecast->n_hours == 0, FALSE);

  for (guint k = 0; k < forecast->n_hours; k++) {
    const WxBlendHour *a = &forecast->hours[k];
    /* unsigned differences: no signed overflow whatever the (hand-built) time stamps are */
    guint64 age = (guint64)now_s - (guint64)a->t_s;
    if (now_s < a->t_s || age >= HOUR_S)
      continue;
    const WxBlendHour *b = NULL;
    if (k + 1 < forecast->n_hours &&
        (guint64)forecast->hours[k + 1].t_s - (guint64)a->t_s == HOUR_S)
      b = &forecast->hours[k + 1];
    double frac = (double)age / HOUR_S;

    *out = *a;
    out->t_s = now_s;
    out->temp_c = lerp_known(a->temp_c, b ? b->temp_c : NAN, frac);
    out->feels_c = lerp_known(a->feels_c, b ? b->feels_c : NAN, frac);
    out->humidity_pct = lerp_known(a->humidity_pct, b ? b->humidity_pct : NAN, frac);
    out->wind_kmh = lerp_known(a->wind_kmh, b ? b->wind_kmh : NAN, frac);
    out->gust_kmh = lerp_known(a->gust_kmh, b ? b->gust_kmh : NAN, frac);
    out->cloud_pct = lerp_known(a->cloud_pct, b ? b->cloud_pct : NAN, frac);
    /* One cloud value: a sky class (or unknown) of the bucket is the class of the cloud cover
     * shown for now, not of the bucket's own; a precipitation, fog or severe class is kept. */
    if ((a->condition == WX_COND_UNKNOWN ||
         (a->condition >= WX_COND_CLEAR && a->condition <= WX_COND_OVERCAST)) &&
        isfinite(out->cloud_pct))
      out->condition = wx_cloud_condition(out->cloud_pct);
    out->is_day = wx_sun_is_up(forecast->place.lat, forecast->place.lon, now_s);
    return TRUE;
  }
  return FALSE;
}
