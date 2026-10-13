/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-weights.c - the member weights table.
 *
 * HEURISTIC: these weights are hand-chosen from the general experience that
 * (a) a human-edited NWS grid beats raw models for US temperature, (b) HRRR is
 * the best raw model for the first day over CONUS but ends at 48 h, (c) ECMWF
 * is the strongest global model, and (d) MET Norway's worldwide product is an
 * ECMWF derivative, so it is down-weighted outside the US to avoid counting
 * the same physics twice. They are NOT fitted to forecast-verification data
 * and make no claim of optimality; change them here, in one place, and the
 * tests (test-blend.c) show which documented values move.
 */
#include "wx-weights.h"

#include <math.h>
#include <string.h>

#include "wx-types.h"

/* Number of horizon bands: H0 [0,3) h, H1 [3,18), H2 [18,72), H3 from 72 h. */
#define N_BANDS 4

/* A weight per horizon band. */
typedef struct {
  double band[N_BANDS];
} Bands;

/* One member of the table. */
typedef struct {
  const char *source_id;
  const char *model_id;      /* NULL: any model of the source */
  gboolean us_only;          /* weight 0 outside the US region */
  gboolean limited_to_48h;   /* weight 0 beyond WX_WEIGHT_HRRR_MAX_HORIZON_H */
  Bands us[WX_VAR_COUNT];    /* weights in the US region, per variable group */
  double world[WX_VAR_COUNT]; /* flat weights elsewhere (unused when us_only) */
} Row;

/* The same weight in every band. */
#define FLAT(w) {{(w), (w), (w), (w)}}
/* Band weights H0/H1/H2/H3. */
#define BANDS(a, b, c, d) {{(a), (b), (c), (d)}}

/* Variable group order: TEMP, WIND, CLOUD, HUMIDITY, PRECIP_MM, PRECIP_PROB. */
#define WORLD(temp, wind, cloud, hum, pmm, pprob) {(temp), (wind), (cloud), (hum), (pmm), (pprob)}
/* The same weight for temp, wind, cloud and precipitation amount; humidity and probability 1. */
#define WORLD_MAIN(w) WORLD(w, w, w, 1.0, w, 1.0)

static const Row rows[] = {
  /* NWS forecaster grid: US only (any model id). */
  {"nws", NULL, TRUE, FALSE,
   {BANDS(4, 4, 4.5, 5), FLAT(3), FLAT(3), FLAT(1), BANDS(2, 3, 4, 4), FLAT(5)},
   WORLD(0, 0, 0, 0, 0, 0)},
  /* HRRR (hourly) and, by alias in find_row(), the 15-minute product. */
  {"open-meteo", "hrrr", TRUE, TRUE,
   {BANDS(3, 3, 0.5, 0), BANDS(3, 3, 0.5, 0), BANDS(2, 2, 0.5, 0), FLAT(1), BANDS(4, 4, 1, 0),
    FLAT(1)},
   WORLD(0, 0, 0, 0, 0, 0)},
  /* NOAA National Blend of Models: CONUS only. */
  {"open-meteo", "nbm", TRUE, FALSE,
   {BANDS(2.5, 3, 3, 2), FLAT(2), FLAT(2), FLAT(1), FLAT(2), FLAT(2)},
   WORLD(0, 0, 0, 0, 0, 0)},
  {"open-meteo", "ecmwf", FALSE, FALSE,
   {BANDS(1, 1.5, 2, 2), FLAT(1.5), FLAT(1.5), FLAT(1), BANDS(1, 2, 2.5, 2.5), FLAT(1)},
   WORLD_MAIN(3.0)},
  {"open-meteo", "gfs", FALSE, FALSE,
   {BANDS(0.5, 1, 1, 1), FLAT(1), FLAT(1), FLAT(1), FLAT(1), FLAT(1)},
   WORLD_MAIN(1.5)},
  {"open-meteo", "icon", FALSE, FALSE,
   {BANDS(0.5, 1, 1, 1), FLAT(1), FLAT(1), FLAT(1), BANDS(1, 1, 1.5, 1.5), FLAT(1)},
   WORLD_MAIN(2.5)},
  {"open-meteo", "gem", FALSE, FALSE,
   {FLAT(0.5), FLAT(1), FLAT(1), FLAT(1), FLAT(1), FLAT(1)},
   WORLD_MAIN(1.5)},
  /* Not in the design's US table: same as in the rest of the world. */
  {"open-meteo", "ukmo", FALSE, FALSE,
   {FLAT(2), FLAT(2), FLAT(2), FLAT(1), FLAT(2), FLAT(1)},
   WORLD_MAIN(2.0)},
  {"open-meteo", "meteofrance", FALSE, FALSE,
   {FLAT(2), FLAT(2), FLAT(2), FLAT(1), FLAT(2), FLAT(1)},
   WORLD_MAIN(2.0)},
  /* MET Norway worldwide product (ECMWF-derived): no probability of its own. */
  {"met-no", "ecmwf", FALSE, FALSE,
   {FLAT(0.5), FLAT(1), FLAT(1), FLAT(1), FLAT(1), FLAT(1)},
   WORLD_MAIN(1.5)},
};

/**
 * find_row:
 * @source_id: non-NULL source id.
 * @model_id: non-NULL model id.
 *
 * Finds the table row of a member. "hrrr15" (the 15-minute HRRR product) is
 * an alias of "hrrr" of the same source.
 *
 * Preconditions:
 *  - both arguments are non-NULL NUL-terminated strings.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the result points into the static table; do not free.
 *
 * Returns: (nullable): the row, or NULL for an unknown pair.
 */
static const Row *
find_row(const char *source_id, const char *model_id)
{
  if (strcmp(source_id, "open-meteo") == 0 && strcmp(model_id, "hrrr15") == 0)
    model_id = "hrrr";
  for (gsize i = 0; i < G_N_ELEMENTS(rows); i++) {
    if (strcmp(rows[i].source_id, source_id) != 0)
      continue;
    if (rows[i].model_id == NULL || strcmp(rows[i].model_id, model_id) == 0)
      return &rows[i];
  }
  return NULL;
}

/**
 * band_of:
 * @horizon_h: horizon in hours, not NAN.
 *
 * Preconditions:
 *  - @horizon_h is not NAN.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the band index 0..3 (H0 [0,3), H1 [3,18), H2 [18,72), H3 from 72);
 *   negative horizons are band 0.
 */
static guint
band_of(double horizon_h)
{
  if (horizon_h < 3.0)
    return 0;
  if (horizon_h < 18.0)
    return 1;
  if (horizon_h < 72.0)
    return 2;
  return 3;
}

/* Documented in wx-weights.h. */
double
wx_weight_for(const char *source_id, const char *model_id, WxVar var, double horizon_h,
              gboolean us_region)
{
  g_return_val_if_fail(source_id != NULL, 0.0);
  g_return_val_if_fail(model_id != NULL, 0.0);
  g_return_val_if_fail((guint)var < WX_VAR_COUNT, 0.0);

  if (isnan(horizon_h))
    return 0.0;

  const Row *row = find_row(source_id, model_id);
  if (row == NULL)
    return WX_WEIGHT_UNKNOWN;
  if (row->us_only && !us_region)
    return 0.0;
  if (row->limited_to_48h && horizon_h > WX_WEIGHT_HRRR_MAX_HORIZON_H)
    return 0.0;
  return us_region ? row->us[var].band[band_of(horizon_h)] : row->world[var];
}
