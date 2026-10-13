/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-weights.h - how much each forecast member is trusted, per variable group
 * and forecast horizon.
 *
 * The numbers are a documented HEURISTIC (see wx-weights.c): they are NOT
 * fitted to forecast-verification data. Pure and deterministic: the weight
 * depends only on the arguments; there is no state and no allocation.
 */
#ifndef WX_WEIGHTS_H
#define WX_WEIGHTS_H

#include <glib.h>

G_BEGIN_DECLS

/**
 * WxVar: the variable groups that share one set of weights.
 *
 * WX_VAR_TEMP covers temperature and apparent temperature, WX_VAR_WIND wind
 * speed and gusts; the other groups are single variables.
 */
typedef enum {
  WX_VAR_TEMP,
  WX_VAR_WIND,
  WX_VAR_CLOUD,
  WX_VAR_HUMIDITY,
  WX_VAR_PRECIP_MM,
  WX_VAR_PRECIP_PROB,
  WX_VAR_COUNT /**< number of groups; not a valid group itself */
} WxVar;

/** Weight of a member whose source:model pair is not in the table. */
#define WX_WEIGHT_UNKNOWN 1.0

/** HRRR only forecasts 48 h ahead: its weight is 0 for a horizon above this, in hours. */
#define WX_WEIGHT_HRRR_MAX_HORIZON_H 48.0

/**
 * wx_weight_for:
 * @source_id: provider id of the member, e.g. "open-meteo", "nws", "met-no".
 * @model_id: model id of the member, e.g. "ecmwf", "hrrr", "nws".
 * @var: the variable group.
 * @horizon_h: forecast horizon in hours, (valid time - now) / 3600. Negative
 *   values count as 0, +infinity as the longest band; NAN is "unknown" and is
 *   weighted 0 (the value is excluded from the blend).
 * @us_region: TRUE when the place is in the US region (an NWS member exists or
 *   the place is in the NWS / CONUS boxes, see wx_blend_forecast()).
 *
 * Looks the (source_id, model_id) pair up in the static weights table
 * (wx-weights.c). Horizon bands: H0 [0, 3) h, H1 [3, 18), H2 [18, 72), H3 from
 * 72 h. The pair is compared byte for byte (no case folding, no validation of
 * the ids); at most the two strings are read up to their NUL.
 *
 * Table rules:
 *  - US region: the US tables of the design (NWS, HRRR, NBM, ECMWF, GFS, ICON,
 *    GEM, MET Norway); UKMO and Meteo-France use the same weights as in the
 *    rest of the world (the design leaves them out of the US table).
 *  - elsewhere: ecmwf 3, icon 2.5, ukmo 2, meteofrance 2, gem 1.5, gfs 1.5,
 *    met-no:ecmwf 1.5 for temperature, wind, cloud and precipitation amount;
 *    humidity and precipitation probability 1.
 *  - "nws" (any model id) weighs 0 when @us_region is FALSE. The CONUS-only
 *    models "hrrr", "hrrr15" (HRRR, the 15-minute product weighs like it) and
 *    "nbm" of source "open-meteo" weigh 0 when @us_region is FALSE.
 *  - "open-meteo:hrrr" and "open-meteo:hrrr15" weigh 0 for @horizon_h above
 *    WX_WEIGHT_HRRR_MAX_HORIZON_H (exactly 48 h is still weighted).
 *  - any other pair is unknown and weighs exactly WX_WEIGHT_UNKNOWN (1.0)
 *    whatever the variable, horizon and region: a newly added provider takes
 *    part at once, and 1.0 is also its cap (it never outweighs a calibrated
 *    top-weight member of the same region).
 *
 * Preconditions:
 *  - @source_id and @model_id are non-NULL NUL-terminated strings (NULL:
 *    critical, 0.0 returned); @var is a valid WxVar (otherwise critical, 0.0).
 * Postconditions:
 *  - no state is changed; the result depends only on the arguments.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: a finite weight in [0, 5]; 0 means "exclude".
 */
double wx_weight_for(const char *source_id, const char *model_id, WxVar var, double horizon_h,
                     gboolean us_region);

G_END_DECLS

#endif /* WX_WEIGHTS_H */
