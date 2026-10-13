/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-condition.h"

#include <math.h>

#include "wx-types.h"

/* Upper bound of "clear", "mostly clear", ... in percent (design 5.5). */
#define CLOUD_CLEAR_MAX 12.5
#define CLOUD_MOSTLY_CLEAR_MAX 37.5
#define CLOUD_PARTLY_MAX 62.5
#define CLOUD_MOSTLY_CLOUDY_MAX 87.5

/* Rain intensity bounds, mm per hour. */
#define RATE_DRIZZLE_MAX 0.5
#define RATE_LIGHT_MAX 2.5
#define RATE_RAIN_MAX 7.6

/* Documented in wx-condition.h. */
gboolean
wx_is_wet_hour(double precip_mm, double precip_prob)
{
  return precip_mm >= WX_WET_HOUR_MM && (isnan(precip_prob) || precip_prob >= WX_WET_PROB_PCT);
}

/* Documented in wx-condition.h. */
WxCondition
wx_cloud_condition(double cloud_pct)
{
  if (isnan(cloud_pct))
    return WX_COND_UNKNOWN;
  if (cloud_pct < CLOUD_CLEAR_MAX)
    return WX_COND_CLEAR;
  if (cloud_pct < CLOUD_MOSTLY_CLEAR_MAX)
    return WX_COND_MOSTLY_CLEAR;
  if (cloud_pct < CLOUD_PARTLY_MAX)
    return WX_COND_PARTLY_CLOUDY;
  if (cloud_pct < CLOUD_MOSTLY_CLOUDY_MAX)
    return WX_COND_MOSTLY_CLOUDY;
  return WX_COND_OVERCAST;
}

/* Documented in wx-condition.h. */
WxCondition
wx_condition_rain_class(double cloud_pct, double precip_mm_h)
{
  if (isnan(precip_mm_h))
    return WX_COND_UNKNOWN;
  if (cloud_pct < CLOUD_MOSTLY_CLOUDY_MAX && precip_mm_h < RATE_RAIN_MAX)
    return WX_COND_SHOWERS;
  if (precip_mm_h < RATE_DRIZZLE_MAX)
    return WX_COND_DRIZZLE;
  if (precip_mm_h < RATE_LIGHT_MAX)
    return WX_COND_LIGHT_RAIN;
  if (precip_mm_h < RATE_RAIN_MAX)
    return WX_COND_RAIN;
  return WX_COND_HEAVY_RAIN;
}

/**
 * code_in:
 * @code: a WMO code.
 * @set: (array length=n_set): the codes of one class.
 * @n_set: number of codes of the class.
 *
 * Preconditions:
 *  - @set has @n_set readable entries.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @code is one of @set.
 */
static gboolean
code_in(int code, const int *set, gsize n_set)
{
  for (gsize i = 0; i < n_set; i++) {
    if (set[i] == code)
      return TRUE;
  }
  return FALSE;
}

/**
 * majority_in:
 * @votes: (array length=n_votes): the WMO codes of the members.
 * @n_votes: number of entries.
 * @set: (array length=n_set): the codes of one class.
 * @n_set: number of codes of the class.
 *
 * Preconditions:
 *  - the arrays have their stated number of readable entries.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff at least one code is >= 0 and at least half of the codes
 *   >= 0 are in @set.
 */
static gboolean
majority_in(const int *votes, guint n_votes, const int *set, gsize n_set)
{
  guint supplied = 0;
  guint hits = 0;
  for (guint i = 0; i < n_votes; i++) {
    if (votes[i] < 0)
      continue;
    supplied++;
    if (code_in(votes[i], set, n_set))
      hits++;
  }
  /* hits * 2 cannot overflow: both counts are below 2^32 and are summed in 64 bits */
  return supplied > 0 && (guint64)hits * 2 >= supplied;
}

static const int thunder_codes[] = {95, 96, 97, 99};
static const int snow_codes[] = {71, 73, 75, 77, 85, 86};
static const int sleet_codes[] = {56, 57, 66, 67};
static const int fog_codes[] = {45, 48};

/* Highest air temperature at which snow codes are believed, degC. */
#define SNOW_MAX_TEMP_C 2.0

/* Documented in wx-condition.h. */
WxCondition
wx_condition_derive(const WxConditionInput *input)
{
  g_return_val_if_fail(input != NULL, WX_COND_UNKNOWN);
  g_return_val_if_fail(input->wmo_votes != NULL || input->n_wmo_votes == 0, WX_COND_UNKNOWN);

  const int *v = input->wmo_votes;
  guint n = input->n_wmo_votes;
  if (majority_in(v, n, thunder_codes, G_N_ELEMENTS(thunder_codes)))
    return WX_COND_THUNDERSTORM;
  if (input->temp_c <= SNOW_MAX_TEMP_C && majority_in(v, n, snow_codes, G_N_ELEMENTS(snow_codes)))
    return WX_COND_SNOW;
  if (majority_in(v, n, sleet_codes, G_N_ELEMENTS(sleet_codes)))
    return WX_COND_SLEET;
  if (majority_in(v, n, fog_codes, G_N_ELEMENTS(fog_codes)))
    return WX_COND_FOG;
  if (wx_is_wet_hour(input->precip_mm_h, input->precip_prob))
    return wx_condition_rain_class(input->cloud_pct, input->precip_mm_h);
  return wx_cloud_condition(input->cloud_pct);
}

static const char *const condition_labels[WX_COND_COUNT] = {
  [WX_COND_UNKNOWN] = "Unknown",
  [WX_COND_CLEAR] = "Clear",
  [WX_COND_MOSTLY_CLEAR] = "Mostly clear",
  [WX_COND_PARTLY_CLOUDY] = "Partly cloudy",
  [WX_COND_MOSTLY_CLOUDY] = "Mostly cloudy",
  [WX_COND_OVERCAST] = "Overcast",
  [WX_COND_FOG] = "Fog",
  [WX_COND_DRIZZLE] = "Drizzle",
  [WX_COND_LIGHT_RAIN] = "Light rain",
  [WX_COND_RAIN] = "Rain",
  [WX_COND_HEAVY_RAIN] = "Heavy rain",
  [WX_COND_SHOWERS] = "Showers",
  [WX_COND_THUNDERSTORM] = "Thunderstorm",
  [WX_COND_SNOW] = "Snow",
  [WX_COND_SLEET] = "Sleet",
};

/* Documented in wx-condition.h. */
const char *
wx_condition_label(WxCondition condition)
{
  g_return_val_if_fail((guint)condition < WX_COND_COUNT, "Unknown");
  return condition_labels[condition];
}

/* Documented in wx-condition.h. */
const char *
wx_cloud_label(double cloud_pct)
{
  return wx_condition_label(wx_cloud_condition(cloud_pct));
}
