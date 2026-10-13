/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-rain.h - the rain outlook: "raining now / rain expected / rain possible /
 * dry" with start, end and peak, from a blended forecast.
 *
 * Pure: no allocation on the heap, no global state, no locale or time-zone use.
 */
#ifndef WX_RAIN_H
#define WX_RAIN_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** The outlook looks at the next 48 hours, in seconds. */
#define WX_RAIN_HORIZON_S G_GINT64_CONSTANT(172800)
/** Nowcast quarters are used for the first 2 hours, in seconds. */
#define WX_RAIN_QUARTER_SPAN_S G_GINT64_CONSTANT(7200)
/** Precipitation (mm per 15 minutes) from which a quarter counts as wet. */
#define WX_RAIN_WET_QUARTER_MM 0.05
/** Hourly precip_prob (percent) from which "rain possible" is reported. */
#define WX_RAIN_POSSIBLE_PROB_PCT 40.0

/**
 * wx_rain_outlook:
 * @forecast: non-NULL forecast.
 * @now_s: the current time, UTC unix seconds, in [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * @out: (out): receives the outlook.
 *
 * Summarises the next WX_RAIN_HORIZON_S seconds of precipitation.
 *
 * Samples. A wet hour is wx_is_wet_hour(precip_mm, precip_prob) (>= 0.1 mm and
 * a probability that is unknown or >= 30 %); a wet quarter has precip_mm >=
 * 0.05. A sample is a time span with a rate in mm per hour (an hour's
 * precip_mm, or four times a quarter's) and, for hours, a probability. The
 * time line is made of hour samples [t_s, t_s + 3600), except that when the
 * forecast has quarters starting with the one that contains @now_s the
 * contiguous quarters that start before @now_s + 7200 replace the hours for
 * the span they cover (an hour that overlaps that span contributes only the
 * part outside it, at the hour's rate). Samples that start at or after
 * @now_s + 48 h are ignored. Missing data (an hour absent from the forecast,
 * a NAN amount) is treated as dry; a run of wet samples never continues over
 * a gap in the time line.
 *
 * State:
 *  - WX_RAIN_NOW when the sample covering @now_s is wet. start_s is the start
 *    of the wet run containing it (possibly before @now_s), peak_* are taken
 *    over the whole run.
 *  - otherwise WX_RAIN_EXPECTED when a wet sample starts at or after @now_s;
 *    start_s, end_s and the peak describe the FIRST such run.
 *  - otherwise WX_RAIN_POSSIBLE when some hour that ends after @now_s and
 *    starts before the horizon has precip_prob >= 40: peak_s is the start of
 *    the first hour with the highest probability, peak_prob that probability,
 *    peak_mm_h that hour's precip_mm (0 when NAN); start_s, end_s are 0.
 *  - otherwise WX_RAIN_DRY.
 * For NOW and EXPECTED: end_s is the end of the run and ends_known TRUE iff
 * the run is followed, inside the horizon, by a dry sample that is present in
 * the time line (the run did not reach the horizon or the end of the data);
 * otherwise end_s is 0 and ends_known FALSE. peak_mm_h is the largest rate in
 * the run, peak_s the start of the first sample with that rate, peak_prob the
 * largest finite probability among the run's hour samples (NAN when none).
 * For DRY every other field is 0 / FALSE.
 *
 * Preconditions:
 *  - @forecast and @out are non-NULL and @now_s is in the time range.
 *  - @forecast is USABLE, i.e. has the shape wx_forecast_new() guarantees (a
 *    hand-built struct must keep it): n_hours <= WX_FORECAST_MAX_HOURS and
 *    n_quarters <= WX_FORECAST_MAX_QUARTERS; hours/quarters non-NULL when their
 *    count is non-zero; hour t_s strictly ascending multiples of 3600 and
 *    quarter t_s strictly ascending multiples of 900, all within
 *    [WX_TIME_MIN_S, WX_TIME_MAX_S); every quarter precip_mm finite within
 *    [0, WX_PRECIP_MAX_MM_H] (hour values may be NAN). The counts are checked
 *    before any element is read.
 *  - a violation is a programmer error: critical, and @out, if non-NULL, is
 *    set to the DRY outlook. Memory safety does not depend on the data: the
 *    working list on the stack is bounded and never written beyond its
 *    capacity (it is never reached for a usable forecast).
 * Postconditions:
 *  - *@out is fully written; start_s <= peak_s < end_s whenever end_s != 0.
 * Thread affinity: any thread (the forecast is immutable).
 * Ownership: nothing is retained.
 */
void wx_rain_outlook(const WxForecast *forecast, gint64 now_s, WxRainOutlook *out);

G_END_DECLS

#endif /* WX_RAIN_H */
