/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-condition.h - plain-language sky / precipitation classes: the cloud-cover
 * words, the condition derived for one blended hour, and their labels.
 *
 * Pure functions: no allocation, no global state, total for every finite and
 * non-finite input. Labels are static English strings (never freed).
 */
#ifndef WX_CONDITION_H
#define WX_CONDITION_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Precipitation (mm per hour) from which an hour counts as wet. */
#define WX_WET_HOUR_MM 0.1
/** A wet hour whose probability is known must reach this many percent. */
#define WX_WET_PROB_PCT 30.0

/**
 * WxConditionInput: what wx_condition_derive() looks at, for one hour.
 */
typedef struct {
  double cloud_pct;       /**< cloud cover 0..100, NAN unknown                       */
  double precip_prob;     /**< probability of precipitation 0..100, NAN unknown      */
  double precip_mm_h;     /**< precipitation over the hour, mm (= mm per hour)       */
  double temp_c;          /**< air temperature, NAN unknown                          */
  const int *wmo_votes;   /**< WMO codes of the members at that hour, may be NULL
                               when n_wmo_votes is 0; entries < 0 mean "no code"     */
  guint n_wmo_votes;      /**< number of entries of wmo_votes                        */
} WxConditionInput;

/**
 * wx_is_wet_hour:
 * @precip_mm: precipitation over the hour, mm.
 * @precip_prob: probability of precipitation, percent, NAN when unknown.
 *
 * The wet-hour test shared by wx_condition_derive() and wx_rain_outlook():
 * precip_mm >= WX_WET_HOUR_MM and (@precip_prob is NAN or >= WX_WET_PROB_PCT).
 *
 * Preconditions: none (any doubles).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the hour is wet (always FALSE when @precip_mm is NAN).
 */
gboolean wx_is_wet_hour(double precip_mm, double precip_prob);

/**
 * wx_cloud_condition:
 * @cloud_pct: cloud cover in percent.
 *
 * Maps cloud cover to the sky classes: [0, 12.5) WX_COND_CLEAR, [12.5, 37.5)
 * WX_COND_MOSTLY_CLEAR, [37.5, 62.5) WX_COND_PARTLY_CLOUDY, [62.5, 87.5)
 * WX_COND_MOSTLY_CLOUDY, from 87.5 WX_COND_OVERCAST. Values below 0 count as
 * clear and above 100 as overcast (the infinities included).
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the class; WX_COND_UNKNOWN when @cloud_pct is NAN.
 */
WxCondition wx_cloud_condition(double cloud_pct);

/**
 * wx_condition_rain_class:
 * @cloud_pct: cloud cover in percent, NAN when unknown.
 * @precip_mm_h: precipitation rate of a wet sample, mm per hour.
 *
 * The class of a wet sample: WX_COND_SHOWERS when @cloud_pct < 87.5 (scattered
 * convective cloud) and @precip_mm_h < 7.6, otherwise by intensity:
 * below 0.5 WX_COND_DRIZZLE, below 2.5 WX_COND_LIGHT_RAIN, below 7.6
 * WX_COND_RAIN, from 7.6 WX_COND_HEAVY_RAIN. An unknown (NAN) cloud cover
 * never gives showers.
 *
 * Preconditions: none (the caller has decided the sample is wet).
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: one of the classes above; WX_COND_UNKNOWN when @precip_mm_h is NAN.
 */
WxCondition wx_condition_rain_class(double cloud_pct, double precip_mm_h);

/**
 * wx_condition_derive:
 * @input: non-NULL input of one hour.
 *
 * Derives the condition of one hour. Rules, first match wins:
 *  1. Of the WMO codes >= 0 in wmo_votes (those "supplying a code", at least
 *     one needed), at least 50 % are in {95, 96, 97, 99}: WX_COND_THUNDERSTORM.
 *  2. At least 50 % in {71, 73, 75, 77, 85, 86} and temp_c <= 2 (an unknown
 *     temperature fails the test): WX_COND_SNOW.
 *  3. At least 50 % in {56, 57, 66, 67}: WX_COND_SLEET.
 *  4. At least 50 % in {45, 48}: WX_COND_FOG.
 *  5. wx_is_wet_hour(precip_mm_h, precip_prob): wx_condition_rain_class(
 *     cloud_pct, precip_mm_h).
 *  6. Otherwise the sky class wx_cloud_condition(cloud_pct) (WX_COND_UNKNOWN
 *     for an unknown cloud cover).
 * Codes outside 0..99 count as supplying a code but are in no set.
 *
 * Preconditions:
 *  - @input is non-NULL, and wmo_votes is non-NULL when n_wmo_votes > 0
 *    (otherwise critical, WX_COND_UNKNOWN returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the condition (never WX_COND_COUNT).
 */
WxCondition wx_condition_derive(const WxConditionInput *input);

/**
 * wx_condition_label:
 * @condition: a condition.
 *
 * English label: "Unknown", "Clear", "Mostly clear", "Partly cloudy", "Mostly
 * cloudy", "Overcast", "Fog", "Drizzle", "Light rain", "Rain", "Heavy rain",
 * "Showers", "Thunderstorm", "Snow", "Sleet".
 *
 * Preconditions:
 *  - @condition < WX_COND_COUNT (otherwise critical, "Unknown" returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: static string owned by the library; do not free.
 *
 * Returns: (transfer none): the label; never NULL.
 */
const char *wx_condition_label(WxCondition condition);

/**
 * wx_cloud_label:
 * @cloud_pct: cloud cover in percent.
 *
 * The cloud-cover words: [0, 12.5) "Clear", [12.5, 37.5) "Mostly clear",
 * [37.5, 62.5) "Partly cloudy", [62.5, 87.5) "Mostly cloudy", from 87.5
 * "Overcast" (below 0 and above 100 as the nearest of those), NAN "Unknown".
 * Equals wx_condition_label(wx_cloud_condition(@cloud_pct)).
 *
 * Preconditions: none.
 * Postconditions: no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: static string; do not free.
 *
 * Returns: (transfer none): the label; never NULL.
 */
const char *wx_cloud_label(double cloud_pct);

G_END_DECLS

#endif /* WX_CONDITION_H */
