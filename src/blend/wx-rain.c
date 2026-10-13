/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-rain.h"

#include <math.h>

#include "wx-condition.h"
#include "wx-types.h"

#define HOUR_S 3600
#define QUARTER_S 900

/* One span of the time line: [start, end) with a rate in mm per hour. */
typedef struct {
  gint64 start;
  gint64 end;
  double mm_h;   /* NAN when unknown */
  double prob;   /* NAN for quarters and unknown probabilities */
  gboolean wet;
} Sample;

/* The sample list holds the hours plus the quarters of the first 2 hours. For a usable forecast
 * (forecast_is_usable(): hours strictly ascending on the hour grid) every hour gives at most one
 * sample, except that the one hour that contains the whole quarter span is cut in two (one extra
 * sample); hours inside the span are dropped. So there are at most n_hours + 1 hour samples
 * (n_hours <= WX_FORECAST_MAX_HOURS) plus at most 9 quarter samples (the span is 2 h and the
 * first quarter may start up to 15 minutes before now). The two extra entries are slack. */
#define MAX_SAMPLES (WX_FORECAST_MAX_HOURS + 2 + 9)

/**
 * forecast_is_usable:
 * @forecast: non-NULL forecast, possibly hand-built.
 *
 * The structural requirements of wx_rain_outlook(), the same as those
 * wx_forecast_new() enforces: at most WX_FORECAST_MAX_HOURS hours and
 * WX_FORECAST_MAX_QUARTERS quarters, arrays non-NULL for non-zero counts, hours
 * strictly ascending multiples of 3600 and quarters strictly ascending
 * multiples of 900, all within [WX_TIME_MIN_S, WX_TIME_MAX_S), quarter amounts
 * finite within [0, WX_PRECIP_MAX_MM_H]. Hour values may be NAN. The counts are
 * checked before any array element is read.
 *
 * Preconditions:
 *  - @forecast is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the forecast has the shape above.
 */
static gboolean
forecast_is_usable(const WxForecast *forecast)
{
  if (forecast->n_hours > WX_FORECAST_MAX_HOURS || forecast->n_quarters > WX_FORECAST_MAX_QUARTERS ||
      (forecast->n_hours > 0 && forecast->hours == NULL) ||
      (forecast->n_quarters > 0 && forecast->quarters == NULL))
    return FALSE;
  for (guint i = 0; i < forecast->n_hours; i++) {
    gint64 t = forecast->hours[i].t_s;
    if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || t % HOUR_S != 0 ||
        (i > 0 && t <= forecast->hours[i - 1].t_s))
      return FALSE;
  }
  for (guint i = 0; i < forecast->n_quarters; i++) {
    gint64 t = forecast->quarters[i].t_s;
    if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || t % QUARTER_S != 0 ||
        (i > 0 && t <= forecast->quarters[i - 1].t_s) ||
        !wx_value_in_range(forecast->quarters[i].precip_mm, 0.0, WX_PRECIP_MAX_MM_H))
      return FALSE;
  }
  return TRUE;
}

/**
 * add_hours:
 * @forecast: non-NULL usable forecast.
 * @lo: first instant that may be covered (inclusive).
 * @hi: end of the part that may be covered (exclusive).
 * @horizon_end: instants from here on are ignored.
 * @samples: (array length=MAX_SAMPLES): the sample list.
 * @n: (inout): number of samples in @samples, at most MAX_SAMPLES.
 *
 * Appends one sample per forecast hour, clipped to [@lo, @hi) and dropped when
 * the clipped span is empty or starts at or after @horizon_end. Never writes
 * beyond MAX_SAMPLES: at capacity the remaining hours are not added (cannot
 * happen for a usable forecast, see MAX_SAMPLES; the list is then a truncated
 * but still ascending time line).
 *
 * Preconditions:
 *  - @forecast is usable and *@n <= MAX_SAMPLES.
 * Postconditions:
 *  - samples are appended in ascending time order; *@n <= MAX_SAMPLES.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
add_hours(const WxForecast *forecast, gint64 lo, gint64 hi, gint64 horizon_end, Sample *samples,
          guint *n)
{
  for (guint i = 0; i < forecast->n_hours && *n < MAX_SAMPLES; i++) {
    const WxBlendHour *h = &forecast->hours[i];
    gint64 start = MAX(h->t_s, lo);
    gint64 end = MIN(h->t_s + HOUR_S, hi);
    if (start >= end || start >= horizon_end)
      continue;
    Sample *s = &samples[(*n)++];
    s->start = start;
    s->end = end;
    s->mm_h = h->precip_mm;
    s->prob = h->precip_prob;
    s->wet = wx_is_wet_hour(h->precip_mm, h->precip_prob);
  }
}

/**
 * build_samples:
 * @forecast: non-NULL forecast.
 * @now_s: the current time.
 * @samples: (array length=MAX_SAMPLES): receives the time line.
 *
 * Preconditions:
 *  - @forecast is valid (ascending hours and quarters) and @now_s is in the
 *    time range.
 * Postconditions:
 *  - the samples are ascending and do not overlap.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the number of samples.
 */
static guint
build_samples(const WxForecast *forecast, gint64 now_s, Sample *samples)
{
  gint64 horizon_end = now_s + WX_RAIN_HORIZON_S;
  gint64 q0 = now_s - now_s % QUARTER_S;
  guint n = 0;

  /* the contiguous quarters that start with the one containing now and begin
   * before now + 2 h */
  guint first = 0;
  guint count = 0;
  while (first < forecast->n_quarters && forecast->quarters[first].t_s != q0)
    first++;
  while (first + count < forecast->n_quarters &&
         forecast->quarters[first + count].t_s == q0 + (gint64)count * QUARTER_S &&
         forecast->quarters[first + count].t_s < now_s + WX_RAIN_QUARTER_SPAN_S)
    count++;

  if (count == 0) {
    add_hours(forecast, G_MININT64, G_MAXINT64, horizon_end, samples, &n);
    return n;
  }

  gint64 span_end = q0 + (gint64)count * QUARTER_S;
  add_hours(forecast, G_MININT64, q0, horizon_end, samples, &n);
  for (guint i = 0; i < count && n < MAX_SAMPLES; i++) {
    const WxQuarter *q = &forecast->quarters[first + i];
    Sample *s = &samples[n++];
    s->start = q->t_s;
    s->end = q->t_s + QUARTER_S;
    s->mm_h = q->precip_mm * 4.0;
    s->prob = NAN;
    s->wet = q->precip_mm >= WX_RAIN_WET_QUARTER_MM;
  }
  add_hours(forecast, span_end, G_MAXINT64, horizon_end, samples, &n);
  return n;
}

/**
 * run_end:
 * @samples: the time line.
 * @n: number of samples.
 * @first: index of the first sample of a run.
 *
 * Preconditions:
 *  - @samples[@first] is wet.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 *
 * Returns: the index of the last sample of the run of contiguous wet samples
 *   that starts at @first.
 */
static guint
run_end(const Sample *samples, guint n, guint first)
{
  guint last = first;
  while (last + 1 < n && samples[last + 1].wet && samples[last + 1].start == samples[last].end)
    last++;
  return last;
}

/**
 * describe_run:
 * @samples: the time line.
 * @n: number of samples.
 * @first: index of the first sample of the run.
 * @last: index of the last sample of the run.
 * @out: (inout): the outlook; state is already set, everything else is written.
 *
 * Preconditions:
 *  - @first <= @last < @n and the samples between are the wet run.
 * Postconditions:
 *  - start_s, end_s, ends_known and the peak fields of *@out are written.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
describe_run(const Sample *samples, guint n, guint first, guint last, WxRainOutlook *out)
{
  out->start_s = samples[first].start;
  /* known only if a dry sample directly follows the run */
  out->ends_known = last + 1 < n && samples[last + 1].start == samples[last].end;
  out->end_s = out->ends_known ? samples[last].end : 0;
  out->peak_mm_h = -1.0;
  out->peak_s = samples[first].start;
  out->peak_prob = NAN;
  for (guint i = first; i <= last; i++) {
    if (samples[i].mm_h > out->peak_mm_h) {
      out->peak_mm_h = samples[i].mm_h;
      out->peak_s = samples[i].start;
    }
    out->peak_prob = fmax(out->peak_prob, samples[i].prob);
  }
}

/**
 * possible_rain:
 * @forecast: non-NULL forecast.
 * @now_s: the current time.
 * @out: (inout): the outlook, set to POSSIBLE when an hour qualifies.
 *
 * Preconditions:
 *  - @forecast is valid and @now_s is in the time range.
 * Postconditions:
 *  - *@out is only written when some hour that ends after @now_s and starts
 *    before the horizon has precip_prob >= WX_RAIN_POSSIBLE_PROB_PCT.
 * Thread affinity: any thread.
 * Ownership: nothing is retained.
 */
static void
possible_rain(const WxForecast *forecast, gint64 now_s, WxRainOutlook *out)
{
  const WxBlendHour *best = NULL;
  for (guint i = 0; i < forecast->n_hours; i++) {
    const WxBlendHour *h = &forecast->hours[i];
    if (h->t_s + HOUR_S <= now_s || h->t_s >= now_s + WX_RAIN_HORIZON_S)
      continue;
    if (h->precip_prob >= WX_RAIN_POSSIBLE_PROB_PCT &&
        (best == NULL || h->precip_prob > best->precip_prob))
      best = h;
  }
  if (best == NULL)
    return;
  out->state = WX_RAIN_POSSIBLE;
  out->peak_s = best->t_s;
  out->peak_prob = best->precip_prob;
  out->peak_mm_h = isfinite(best->precip_mm) ? best->precip_mm : 0.0;
}

/* Documented in wx-rain.h. */
void
wx_rain_outlook(const WxForecast *forecast, gint64 now_s, WxRainOutlook *out)
{
  g_return_if_fail(out != NULL);
  *out = (WxRainOutlook){.state = WX_RAIN_DRY};
  g_return_if_fail(forecast != NULL);
  g_return_if_fail(now_s >= WX_TIME_MIN_S && now_s < WX_TIME_MAX_S);
  g_return_if_fail(forecast_is_usable(forecast)); /* the sample list is sized by it */

  Sample samples[MAX_SAMPLES];
  guint n = build_samples(forecast, now_s, samples);

  /* the sample covering now, if any, and the first wet sample from now on */
  guint cover = n;
  guint next_wet = n;
  for (guint i = 0; i < n; i++) {
    if (samples[i].start <= now_s && now_s < samples[i].end)
      cover = i;
    if (next_wet == n && samples[i].wet && samples[i].start >= now_s)
      next_wet = i;
  }

  if (cover < n && samples[cover].wet) {
    guint first = cover;
    while (first > 0 && samples[first - 1].wet && samples[first - 1].end == samples[first].start)
      first--;
    out->state = WX_RAIN_NOW;
    describe_run(samples, n, first, run_end(samples, n, cover), out);
  } else if (next_wet < n) {
    out->state = WX_RAIN_EXPECTED;
    describe_run(samples, n, next_wet, run_end(samples, n, next_wet), out);
  } else {
    possible_rain(forecast, now_s, out);
  }
}
