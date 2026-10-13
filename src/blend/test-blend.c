/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* Offline unit tests for the blend module (weights, median, blend, nowcast,
 * conditions, rain outlook, daily summary). No network, no GTK, no real clock:
 * every time is a fixed UTC instant, so the results do not depend on the
 * local time zone or locale of the machine. */
#include <glib.h>
#include <float.h>
#include <locale.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "wx-blend.h"
#include "wx-condition.h"
#include "wx-daily.h"
#include "wx-geo.h"
#include "wx-rain.h"
#include "wx-types.h"
#include "wx-weights.h"

/* 2026-10-11T00:00:00Z */
#define T0 G_GINT64_CONSTANT(1791676800)
#define H 3600
/* 2026-10-11T12:37:00Z: the hour containing it is 12:00, the quarter 12:30. */
#define NOW_S (T0 + 12 * H + 37 * 60)

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

#define ASSERT_NAN(x) g_assert_true(isnan(x))
/* Fails the test with a formatted message and never returns (g_error() would do, but gcc
 * -fanalyzer reports its "for (;;)" fallback as an infinite loop; g_assertion_message() itself is
 * not declared noreturn, hence the g_abort(), which is not reached). */
#define FAIL(...)                                                                \
  G_STMT_START {                                                                 \
    g_autofree char *fail_msg_ = g_strdup_printf(__VA_ARGS__);                   \
    g_assertion_message(G_LOG_DOMAIN, __FILE__, __LINE__, G_STRFUNC, fail_msg_); \
    g_abort();                                                                   \
  }                                                                              \
  G_STMT_END
#define ASSERT_NEAR(a, b) g_assert_cmpfloat_with_epsilon((a), (b), 1e-9)

/* ------------------------------------------------------------------------ */
/* helpers                                                                  */
/* ------------------------------------------------------------------------ */

static WxPlace *
mk_place(double lat, double lon, const char *tz)
{
  GError *err = NULL;
  WxPlace *p = wx_place_new("Testville", "Region", "Country", "US", lat, lon, tz, &err);
  g_assert_no_error(err);
  g_assert_nonnull(p);
  return p;
}

static WxPlace *
miami(void)
{
  return mk_place(25.7617, -80.1918, "America/New_York");
}

static WxPlace *
london(void)
{
  return mk_place(51.5074, -0.1278, "Europe/London");
}

/* The values of a constant member; every field defaults to "unknown". */
typedef struct {
  double temp, feels, precip, prob, cloud, wind, gust, hum;
  int wmo;
} Vals;

static Vals
vnone(void)
{
  Vals v = {NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN, -1};
  return v;
}

/* Fills the hour @i of a member; the time stamp is already set. */
typedef void (*HourFn)(WxHour *h, guint i, gpointer data);

static void
fill_const(WxHour *h, guint i, gpointer data)
{
  const Vals *v = data;
  (void)i;
  h->temp_c = v->temp;
  h->feels_c = v->feels;
  h->precip_mm = v->precip;
  h->precip_prob = v->prob;
  h->cloud_pct = v->cloud;
  h->wind_kmh = v->wind;
  h->gust_kmh = v->gust;
  h->humidity_pct = v->hum;
  h->wmo = v->wmo;
}

static WxMember *
mk_member_fn(const char *src, const char *model, gint64 first_t, guint n, HourFn fn, gpointer data)
{
  GError *err = NULL;
  WxMember *m = wx_member_new(src, model, NOW_S, &err);
  g_assert_no_error(err);
  g_assert_nonnull(m);
  for (guint i = 0; i < n; i++) {
    WxHour h;
    wx_hour_init(&h);
    h.t_s = first_t + (gint64)i * H;
    fn(&h, i, data);
    g_assert_true(wx_member_add_hour(m, &h));
  }
  return m;
}

static WxMember *
mk_member(const char *src, const char *model, gint64 first_t, guint n, const Vals *v)
{
  return mk_member_fn(src, model, first_t, n, fill_const, (gpointer)v);
}

static void
add_quarters(WxMember *m, gint64 first_t, const double *amounts, guint n)
{
  for (guint i = 0; i < n; i++) {
    WxQuarter q = {first_t + (gint64)i * 900, amounts[i]};
    g_assert_true(wx_member_add_quarter(m, &q));
  }
}

/* A set of provider results built from members. */
typedef struct {
  GPtrArray *results;
} Fx;

static Fx *
fx_new(void)
{
  Fx *fx = g_new0(Fx, 1);
  fx->results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  return fx;
}

static void
fx_free(Fx *fx)
{
  g_ptr_array_free(fx->results, TRUE);
  g_free(fx);
}

/* Adds @m (consumed) to the result of @provider, creating it on first use. */
static void
fx_add(Fx *fx, const char *provider, WxMember *m)
{
  WxSourceResult *r = NULL;
  for (guint i = 0; i < fx->results->len; i++) {
    WxSourceResult *c = g_ptr_array_index(fx->results, i);
    if (strcmp(c->provider_id, provider) == 0)
      r = c;
  }
  if (r == NULL) {
    r = wx_source_result_new(provider, NULL);
    g_assert_nonnull(r);
    g_ptr_array_add(fx->results, r);
  }
  g_ptr_array_add(r->members, m);
}

static WxForecast *
fx_blend_at(Fx *fx, const WxPlace *place, gint64 now_s, GError **err)
{
  return wx_blend_forecast(place, (const WxSourceResult *const *)fx->results->pdata,
                           fx->results->len, NULL, 0, now_s, err);
}

/* Blends and asserts success. */
static WxForecast *
fx_blend(Fx *fx, const WxPlace *place, gint64 now_s)
{
  GError *err = NULL;
  WxForecast *fc = fx_blend_at(fx, place, now_s, &err);
  g_assert_no_error(err);
  g_assert_nonnull(fc);
  return fc;
}

static const WxBlendHour *
hours_of(const WxForecast *fc, guint *n)
{
  const WxBlendHour *h = wx_forecast_get_hours(fc, n);
  g_assert_nonnull(h);
  return h;
}

/* The hour starting at @t_s; asserts that it exists. */
static const WxBlendHour *
hour_at(const WxForecast *fc, gint64 t_s)
{
  guint n;
  const WxBlendHour *h = hours_of(fc, &n);
  for (guint i = 0; i < n; i++) {
    if (h[i].t_s == t_s)
      return &h[i];
  }
  FAIL("no hour at %" G_GINT64_FORMAT, t_s);
}

static void
assert_blend_fails(Fx *fx, const WxPlace *place, gint64 now_s, WxError code)
{
  GError *err = NULL;
  WxForecast *fc = fx_blend_at(fx, place, now_s, &err);
  g_assert_null(fc);
  g_assert_error(err, WX_ERROR, (gint)code);
  g_clear_error(&err);
}

/* A deterministic random source. */
static GRand *
rng(guint32 seed)
{
  return g_rand_new_with_seed(seed);
}

/* A uniform double in [lo, hi). */
static double
rnd(GRand *r, double lo, double hi)
{
  return lo + g_rand_double(r) * (hi - lo);
}

/* A (source, model) pair: the members the fuzz tests generate. */
typedef struct {
  const char *src, *model;
} Id;

static const Id fuzz_ids[] = {
  {"nws", "nws"},           {"open-meteo", "hrrr"}, {"open-meteo", "nbm"},
  {"open-meteo", "ecmwf"},  {"open-meteo", "gfs"},  {"open-meteo", "icon"},
  {"open-meteo", "gem"},    {"open-meteo", "ukmo"}, {"open-meteo", "meteofrance"},
  {"met-no", "ecmwf"},      {"other", "x1"},        {"other", "x2"},
};

/* ------------------------------------------------------------------------ */
/* weighted median                                                          */
/* ------------------------------------------------------------------------ */

static double
wm(const double *v, const double *w, guint n)
{
  return wx_weighted_median(v, w, n);
}

static void
test_median_basic(void)
{
  /* odd, equal weights: the middle value, whatever the input order */
  double v1[] = {3, 1, 2}, w1[] = {1, 1, 1};
  ASSERT_NEAR(wm(v1, w1, 3), 2.0);
  /* even, equal weights: mean of the two middle values */
  double v2[] = {4, 1, 3, 2}, w2[] = {1, 1, 1, 1};
  ASSERT_NEAR(wm(v2, w2, 4), 2.5);
  /* one sample */
  double v3[] = {7.5}, w3[] = {0.25};
  ASSERT_NEAR(wm(v3, w3, 1), 7.5);
  /* two samples, equal weights: exactly 50 % -> mean */
  double v4[] = {1, 2}, w4[] = {1, 1};
  ASSERT_NEAR(wm(v4, w4, 2), 1.5);
  /* a weight above half wins */
  double v5[] = {1, 2}, w5[] = {1, 2};
  ASSERT_NEAR(wm(v5, w5, 2), 2.0);
  double v6[] = {1, 2}, w6[] = {2, 1};
  ASSERT_NEAR(wm(v6, w6, 2), 1.0);
  /* exactly 50 % in the middle of three: lower half {1,2} weighs 2 of 4 */
  double v7[] = {1, 2, 3}, w7[] = {1, 1, 2};
  ASSERT_NEAR(wm(v7, w7, 3), 2.5);
  /* just below 50 %: not a tie, the next value (c = 2 of 5) */
  double v8[] = {1, 2, 3, 4}, w8[] = {2, 1, 1, 1};
  ASSERT_NEAR(wm(v8, w8, 4), 2.0);
  /* exactly 50 % at the first value: 3 of 6 */
  double v9[] = {1, 2, 3, 4}, w9[] = {3, 1, 1, 1};
  ASSERT_NEAR(wm(v9, w9, 4), 1.5);
  /* fractional weights that are multiples of 0.5 (table values) */
  double v10[] = {10, 20, 30}, w10[] = {1.5, 1.0, 0.5};
  ASSERT_NEAR(wm(v10, w10, 3), 15.0); /* 1.5 of 3 is exactly half */
  /* negative values and a mean of negatives */
  double v11[] = {-3, -1}, w11[] = {1, 1};
  ASSERT_NEAR(wm(v11, w11, 2), -2.0);
}

static void
test_median_ties_zeros_nan(void)
{
  /* equal values are interchangeable */
  double v1[] = {5, 5, 5}, w1[] = {1, 2, 3};
  ASSERT_NEAR(wm(v1, w1, 3), 5.0);
  double v2[] = {5, 7, 5, 7}, w2[] = {1, 1, 1, 1};
  ASSERT_NEAR(wm(v2, w2, 4), 6.0);
  /* weight 0, negative weight, NAN or infinite weight, NAN or infinite value: ignored */
  double v3[] = {100, 1, NAN, 200, INFINITY, -INFINITY, 2, 3};
  double w3[] = {0, 1, 1, -5, 1, 1, 1, 1};
  ASSERT_NEAR(wm(v3, w3, 8), 2.0);
  double v4[] = {1, 2, 3}, w4[] = {NAN, INFINITY, -INFINITY};
  ASSERT_NAN(wm(v4, w4, 3));
  /* nothing usable */
  double v5[] = {NAN, NAN}, w5[] = {1, 1};
  ASSERT_NAN(wm(v5, w5, 2));
  double v6[] = {1, 2}, w6[] = {0, 0};
  ASSERT_NAN(wm(v6, w6, 2));
  /* empty input is valid with NULL arrays */
  ASSERT_NAN(wm(NULL, NULL, 0));
  /* the arrays are not modified */
  double v7[] = {3, 1, 2}, w7[] = {1, 1, 1};
  wm(v7, w7, 3);
  g_assert_cmpfloat(v7[0], ==, 3);
  g_assert_cmpfloat(v7[1], ==, 1);
  g_assert_cmpfloat(v7[2], ==, 2);
  g_assert_cmpfloat(w7[2], ==, 1);
  /* the full range of a member count */
  double v8[WX_BLEND_MAX_MEMBERS], w8[WX_BLEND_MAX_MEMBERS];
  for (guint i = 0; i < WX_BLEND_MAX_MEMBERS; i++) {
    v8[i] = WX_BLEND_MAX_MEMBERS - i;
    w8[i] = 1;
  }
  ASSERT_NEAR(wm(v8, w8, WX_BLEND_MAX_MEMBERS), 64.5);
}

static void
test_median_extreme_weights(void)
{
  /* sums of huge weights would overflow without the power-of-two scaling */
  double v[] = {1, 2, 3};
  double huge[] = {1e308, 1e308, 1e308};
  ASSERT_NEAR(wm(v, huge, 3), 2.0);
  double tiny[] = {5e-324, 5e-324, 5e-324}; /* denormals */
  ASSERT_NEAR(wm(v, tiny, 3), 2.0);
  double v2[] = {1, 2}, w2[] = {1e308, 1e308};
  ASSERT_NEAR(wm(v2, w2, 2), 1.5);
  /* a weight far below the largest is absorbed by rounding or ignored, never an error: the
   * answer is the exact one (2: it breaks the tie) or the tie (2.5) */
  double w3[] = {1e-320, 1, 1};
  double v3[] = {1, 2, 3};
  g_assert_true(wm(v3, w3, 3) == 2.0 || wm(v3, w3, 3) == 2.5);
  double w6[] = {1e-300, 1e308, 1e308};
  g_assert_true(wm(v3, w6, 3) == 2.0 || wm(v3, w6, 3) == 2.5);
  /* huge values: the mean of the two middle values must not overflow */
  double v4[] = {1.7e308, 1.7e308}, w4[] = {1, 1};
  ASSERT_NEAR(wm(v4, w4, 2) / 1e308, 1.7);
  double v5[] = {1.7e308, -1.7e308}, w5[] = {1, 1};
  g_assert_cmpfloat(wm(v5, w5, 2), ==, 0.0);
}

/* Independent reference: every sample is repeated "weight" times (weights are
 * small integers) and the median of the expanded list is taken. */
static double
reference_median(const double *v, const int *w, guint n)
{
  GArray *list = g_array_new(FALSE, FALSE, sizeof(double));
  for (guint i = 0; i < n; i++) {
    for (int c = 0; c < w[i]; c++)
      g_array_append_val(list, v[i]);
  }
  if (list->len == 0) {
    g_array_free(list, TRUE);
    return NAN;
  }
  /* insertion sort */
  double *a = (double *)list->data;
  for (guint i = 1; i < list->len; i++) {
    double x = a[i];
    guint j = i;
    while (j > 0 && a[j - 1] > x) {
      a[j] = a[j - 1];
      j--;
    }
    a[j] = x;
  }
  double r = (list->len % 2 == 1) ? a[list->len / 2] : (a[list->len / 2 - 1] + a[list->len / 2]) / 2;
  g_array_free(list, TRUE);
  return r;
}

static void
test_median_fuzz_reference(void)
{
  GRand *r = rng(12345);
  for (int iter = 0; iter < 60000; iter++) {
    guint n = (guint)g_rand_int_range(r, 0, 12);
    double v[12], w[12];
    int wi[12];
    for (guint i = 0; i < n; i++) {
      /* few distinct values to produce many ties and exact 50 % splits */
      v[i] = g_rand_int_range(r, -5, 6) * 0.5;
      wi[i] = g_rand_int_range(r, 0, 9);
      w[i] = wi[i] * 0.5; /* multiples of 0.5, like the table */
    }
    double got = wm(v, w, n);
    double want = reference_median(v, wi, n);
    if (isnan(want))
      ASSERT_NAN(got);
    else
      g_assert_cmpfloat(got, ==, want);
  }
  g_rand_free(r);
}

static void
test_median_criticals(void)
{
  double v[] = {1}, w[] = {1};
  ASSERT_CRITICAL("wx_weighted_median", g_assert_true(isnan(wx_weighted_median(NULL, w, 1))));
  ASSERT_CRITICAL("wx_weighted_median", g_assert_true(isnan(wx_weighted_median(v, NULL, 1))));
  ASSERT_CRITICAL("wx_weighted_median", g_assert_true(isnan(wx_weighted_median(NULL, NULL, 1))));
  double big[WX_BLEND_MAX_MEMBERS + 1] = {0};
  ASSERT_CRITICAL("wx_weighted_median",
                  g_assert_true(isnan(wx_weighted_median(big, big, WX_BLEND_MAX_MEMBERS + 1))));
}

/* Guard-page buffer: @n doubles that end exactly at an inaccessible page. */
static double *
guarded_doubles(guint n, void **map, gsize *map_len)
{
  long page = sysconf(_SC_PAGESIZE);
  *map_len = (gsize)page * 2;
  *map = mmap(NULL, *map_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(*map != MAP_FAILED);
  g_assert_cmpint(mprotect((char *)*map + page, (gsize)page, PROT_NONE), ==, 0);
  return (double *)((char *)*map + page - (gsize)n * sizeof(double));
}

static void
test_median_guard_page(void)
{
  for (guint n = 1; n <= 5; n++) {
    void *m1, *m2;
    gsize l1, l2;
    double *v = guarded_doubles(n, &m1, &l1);
    double *w = guarded_doubles(n, &m2, &l2);
    for (guint i = 0; i < n; i++) {
      v[i] = i;
      w[i] = 1;
    }
    ASSERT_NEAR(wm(v, w, n), (n % 2 == 1) ? (n - 1) / 2.0 : (n - 1) / 2.0);
    munmap(m1, l1);
    munmap(m2, l2);
  }
}

/* ------------------------------------------------------------------------ */
/* weights                                                                  */
/* ------------------------------------------------------------------------ */

/* The design's table, typed again independently of wx-weights.c:
 * source, model, group, H0, H1, H2, H3 (US region). */
typedef struct {
  const char *src, *model;
  WxVar var;
  double b[4];
} Cell;

#define ALL4(x) {(x), (x), (x), (x)}

static const Cell us_cells[] = {
  /* TEMP */
  {"nws", "nws", WX_VAR_TEMP, {4, 4, 4.5, 5}},
  {"open-meteo", "hrrr", WX_VAR_TEMP, {3, 3, 0.5, 0}},
  {"open-meteo", "nbm", WX_VAR_TEMP, {2.5, 3, 3, 2}},
  {"open-meteo", "ecmwf", WX_VAR_TEMP, {1, 1.5, 2, 2}},
  {"open-meteo", "gfs", WX_VAR_TEMP, {0.5, 1, 1, 1}},
  {"open-meteo", "icon", WX_VAR_TEMP, {0.5, 1, 1, 1}},
  {"open-meteo", "gem", WX_VAR_TEMP, ALL4(0.5)},
  {"met-no", "ecmwf", WX_VAR_TEMP, ALL4(0.5)},
  /* WIND */
  {"nws", "nws", WX_VAR_WIND, ALL4(3)},
  {"open-meteo", "hrrr", WX_VAR_WIND, {3, 3, 0.5, 0}},
  {"open-meteo", "nbm", WX_VAR_WIND, ALL4(2)},
  {"open-meteo", "ecmwf", WX_VAR_WIND, ALL4(1.5)},
  {"open-meteo", "gfs", WX_VAR_WIND, ALL4(1)},
  {"open-meteo", "icon", WX_VAR_WIND, ALL4(1)},
  {"open-meteo", "gem", WX_VAR_WIND, ALL4(1)},
  {"met-no", "ecmwf", WX_VAR_WIND, ALL4(1)},
  /* CLOUD */
  {"nws", "nws", WX_VAR_CLOUD, ALL4(3)},
  {"open-meteo", "hrrr", WX_VAR_CLOUD, {2, 2, 0.5, 0}},
  {"open-meteo", "nbm", WX_VAR_CLOUD, ALL4(2)},
  {"open-meteo", "ecmwf", WX_VAR_CLOUD, ALL4(1.5)},
  {"open-meteo", "icon", WX_VAR_CLOUD, ALL4(1)},
  {"open-meteo", "gem", WX_VAR_CLOUD, ALL4(1)},
  {"open-meteo", "gfs", WX_VAR_CLOUD, ALL4(1)},
  {"met-no", "ecmwf", WX_VAR_CLOUD, ALL4(1)},
  /* HUMIDITY: 1 for every member (hrrr only up to 48 h) */
  {"nws", "nws", WX_VAR_HUMIDITY, ALL4(1)},
  {"open-meteo", "hrrr", WX_VAR_HUMIDITY, {1, 1, 1, 0}},
  {"open-meteo", "nbm", WX_VAR_HUMIDITY, ALL4(1)},
  {"open-meteo", "ecmwf", WX_VAR_HUMIDITY, ALL4(1)},
  {"open-meteo", "gfs", WX_VAR_HUMIDITY, ALL4(1)},
  {"open-meteo", "icon", WX_VAR_HUMIDITY, ALL4(1)},
  {"open-meteo", "gem", WX_VAR_HUMIDITY, ALL4(1)},
  {"met-no", "ecmwf", WX_VAR_HUMIDITY, ALL4(1)},
  /* PRECIP_MM */
  {"open-meteo", "hrrr", WX_VAR_PRECIP_MM, {4, 4, 1, 0}},
  {"nws", "nws", WX_VAR_PRECIP_MM, {2, 3, 4, 4}},
  {"open-meteo", "nbm", WX_VAR_PRECIP_MM, ALL4(2)},
  {"open-meteo", "ecmwf", WX_VAR_PRECIP_MM, {1, 2, 2.5, 2.5}},
  {"open-meteo", "icon", WX_VAR_PRECIP_MM, {1, 1, 1.5, 1.5}},
  {"open-meteo", "gem", WX_VAR_PRECIP_MM, ALL4(1)},
  {"open-meteo", "gfs", WX_VAR_PRECIP_MM, ALL4(1)},
  {"met-no", "ecmwf", WX_VAR_PRECIP_MM, ALL4(1)},
  /* PRECIP_PROB: nws 5, nbm 2, every other member 1 */
  {"nws", "nws", WX_VAR_PRECIP_PROB, ALL4(5)},
  {"open-meteo", "nbm", WX_VAR_PRECIP_PROB, ALL4(2)},
  {"open-meteo", "hrrr", WX_VAR_PRECIP_PROB, {1, 1, 1, 0}},
  {"open-meteo", "ecmwf", WX_VAR_PRECIP_PROB, ALL4(1)},
  {"open-meteo", "gfs", WX_VAR_PRECIP_PROB, ALL4(1)},
  {"open-meteo", "icon", WX_VAR_PRECIP_PROB, ALL4(1)},
  {"open-meteo", "gem", WX_VAR_PRECIP_PROB, ALL4(1)},
  {"met-no", "ecmwf", WX_VAR_PRECIP_PROB, ALL4(1)},
};

/* A horizon inside each band. */
static const double band_horizon[4] = {1.5, 10.0, 40.0, 100.0};

static void
test_weights_us_table(void)
{
  for (guint c = 0; c < G_N_ELEMENTS(us_cells); c++) {
    for (guint b = 0; b < 4; b++) {
      double got = wx_weight_for(us_cells[c].src, us_cells[c].model, us_cells[c].var,
                                 band_horizon[b], TRUE);
      if (got != us_cells[c].b[b])
        FAIL("US %s:%s var %d band %u: got %g want %g", us_cells[c].src, us_cells[c].model,
                us_cells[c].var, b, got, us_cells[c].b[b]);
    }
  }
}

static void
test_weights_world_table(void)
{
  /* ecmwf 3, icon 2.5, ukmo 2, meteofrance 2, gem 1.5, gfs 1.5, met-no:ecmwf 1.5 for
   * TEMP/WIND/CLOUD/PRECIP_MM; HUMIDITY 1; PRECIP_PROB 1 */
  static const struct {
    const char *src, *model;
    double main;
  } rows[] = {
    {"open-meteo", "ecmwf", 3.0}, {"open-meteo", "icon", 2.5}, {"open-meteo", "ukmo", 2.0},
    {"open-meteo", "meteofrance", 2.0}, {"open-meteo", "gem", 1.5}, {"open-meteo", "gfs", 1.5},
    {"met-no", "ecmwf", 1.5},
  };
  for (guint r = 0; r < G_N_ELEMENTS(rows); r++) {
    for (guint b = 0; b < 4; b++) {
      double h = band_horizon[b];
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_TEMP, h, FALSE), ==, rows[r].main);
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_WIND, h, FALSE), ==, rows[r].main);
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_CLOUD, h, FALSE), ==, rows[r].main);
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_PRECIP_MM, h, FALSE), ==, rows[r].main);
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_HUMIDITY, h, FALSE), ==, 1.0);
      g_assert_cmpfloat(wx_weight_for(rows[r].src, rows[r].model, WX_VAR_PRECIP_PROB, h, FALSE), ==, 1.0);
    }
  }
  /* ukmo and meteofrance keep their weights in the US region (the design leaves them out) */
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ukmo", WX_VAR_TEMP, 5, TRUE), ==, 2.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "meteofrance", WX_VAR_PRECIP_MM, 5, TRUE), ==, 2.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ukmo", WX_VAR_HUMIDITY, 5, TRUE), ==, 1.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ukmo", WX_VAR_PRECIP_PROB, 5, TRUE), ==, 1.0);
}

static void
test_weights_invariants(void)
{
  static const char *const srcs[] = {"nws", "open-meteo", "met-no", "other"};
  static const char *const models[] = {"nws", "hrrr", "hrrr15", "nbm", "ecmwf", "gfs", "icon",
                                       "gem", "ukmo", "meteofrance", "newmodel", ""};
  static const double horizons[] = {-1e9, -1, 0, 1, 2.999, 3, 17.999, 18, 47.9, 48, 48.001, 71.999,
                                    72, 100, 240, 1e9, INFINITY, -INFINITY};
  for (guint s = 0; s < G_N_ELEMENTS(srcs); s++) {
    for (guint m = 0; m < G_N_ELEMENTS(models); m++) {
      for (int var = 0; var < WX_VAR_COUNT; var++) {
        for (guint h = 0; h < G_N_ELEMENTS(horizons); h++) {
          for (int us = 0; us < 2; us++) {
            double w = wx_weight_for(srcs[s], models[m], (WxVar)var, horizons[h], us);
            g_assert_true(isfinite(w));
            g_assert_cmpfloat(w, >=, 0.0);
            g_assert_cmpfloat(w, <=, 5.0);
            /* purity: the same arguments, the same weight */
            g_assert_cmpfloat(w, ==, wx_weight_for(srcs[s], models[m], (WxVar)var, horizons[h], us));
            gboolean hrrr = strcmp(srcs[s], "open-meteo") == 0 &&
                            (strcmp(models[m], "hrrr") == 0 || strcmp(models[m], "hrrr15") == 0);
            if (hrrr && (horizons[h] > 48.0 || !us))
              g_assert_cmpfloat(w, ==, 0.0);
            if (hrrr && us && horizons[h] <= 48.0 && horizons[h] >= 0.0)
              g_assert_cmpfloat(w, >, 0.0);
            if (strcmp(srcs[s], "nws") == 0 && !us)
              g_assert_cmpfloat(w, ==, 0.0);
            if (strcmp(srcs[s], "nws") == 0 && us)
              g_assert_cmpfloat(w, >, 0.0);
            if (strcmp(srcs[s], "open-meteo") == 0 && strcmp(models[m], "nbm") == 0 && !us)
              g_assert_cmpfloat(w, ==, 0.0);
            gboolean known = strcmp(srcs[s], "nws") == 0 ||
                             (strcmp(srcs[s], "open-meteo") == 0 && strcmp(models[m], "newmodel") != 0 &&
                              strcmp(models[m], "nws") != 0 && strcmp(models[m], "") != 0) ||
                             (strcmp(srcs[s], "met-no") == 0 && strcmp(models[m], "ecmwf") == 0);
            if (!known)
              g_assert_cmpfloat(w, ==, WX_WEIGHT_UNKNOWN);
          }
        }
      }
    }
  }
}

static void
test_weights_edges(void)
{
  /* band edges: [0,3) [3,18) [18,72) [72,...) */
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ecmwf", WX_VAR_TEMP, 2.999, TRUE), ==, 1.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ecmwf", WX_VAR_TEMP, 3.0, TRUE), ==, 1.5);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ecmwf", WX_VAR_TEMP, 17.999, TRUE), ==, 1.5);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ecmwf", WX_VAR_TEMP, 18.0, TRUE), ==, 2.0);
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, 71.999, TRUE), ==, 4.5);
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, 72.0, TRUE), ==, 5.0);
  /* negative horizon is band 0, infinity the last band */
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, -5.0, TRUE), ==, 4.0);
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, -INFINITY, TRUE), ==, 4.0);
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, INFINITY, TRUE), ==, 5.0);
  /* HRRR: exactly 48 h is still weighted, beyond it is not */
  g_assert_cmpfloat(wx_weight_for("open-meteo", "hrrr", WX_VAR_TEMP, 48.0, TRUE), ==, 0.5);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "hrrr", WX_VAR_TEMP, 48.0001, TRUE), ==, 0.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "hrrr15", WX_VAR_PRECIP_MM, 20.0, TRUE), ==, 1.0);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "hrrr15", WX_VAR_PRECIP_MM, 49.0, TRUE), ==, 0.0);
  /* unknown horizon: excluded */
  g_assert_cmpfloat(wx_weight_for("nws", "nws", WX_VAR_TEMP, NAN, TRUE), ==, 0.0);
  g_assert_cmpfloat(wx_weight_for("other", "x", WX_VAR_TEMP, NAN, FALSE), ==, 0.0);
  /* NWS: any model id of the source "nws" is the NWS row; the id match is exact and case sensitive */
  g_assert_cmpfloat(wx_weight_for("nws", "gridpoint", WX_VAR_TEMP, 1.0, TRUE), ==, 4.0);
  g_assert_cmpfloat(wx_weight_for("NWS", "nws", WX_VAR_TEMP, 1.0, TRUE), ==, WX_WEIGHT_UNKNOWN);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ECMWF", WX_VAR_TEMP, 1.0, TRUE), ==, WX_WEIGHT_UNKNOWN);
  g_assert_cmpfloat(wx_weight_for("other-source", "ecmwf", WX_VAR_TEMP, 1.0, TRUE), ==, WX_WEIGHT_UNKNOWN);
  g_assert_cmpfloat(wx_weight_for("open-meteo", "ecmwf_ifs025", WX_VAR_TEMP, 1.0, TRUE), ==, WX_WEIGHT_UNKNOWN);
  g_assert_cmpfloat(wx_weight_for("met-no", "gfs", WX_VAR_TEMP, 1.0, FALSE), ==, WX_WEIGHT_UNKNOWN);
  /* unknown ids weigh the same everywhere */
  g_assert_cmpfloat(wx_weight_for("brand-new", "model", WX_VAR_PRECIP_PROB, 500, FALSE), ==, 1.0);
}

static void
test_weights_criticals(void)
{
  ASSERT_CRITICAL("wx_weight_for", g_assert_cmpfloat(wx_weight_for(NULL, "x", WX_VAR_TEMP, 1, TRUE), ==, 0.0));
  ASSERT_CRITICAL("wx_weight_for", g_assert_cmpfloat(wx_weight_for("x", NULL, WX_VAR_TEMP, 1, TRUE), ==, 0.0));
  ASSERT_CRITICAL("wx_weight_for", g_assert_cmpfloat(wx_weight_for("x", "y", WX_VAR_COUNT, 1, TRUE), ==, 0.0));
  ASSERT_CRITICAL("wx_weight_for", g_assert_cmpfloat(wx_weight_for("x", "y", (WxVar)-1, 1, TRUE), ==, 0.0));
}

/* ------------------------------------------------------------------------ */
/* conditions                                                               */
/* ------------------------------------------------------------------------ */

static void
test_cloud_label(void)
{
  static const struct {
    double pct;
    const char *label;
    WxCondition cond;
  } cases[] = {
    {0.0, "Clear", WX_COND_CLEAR},
    {12.499, "Clear", WX_COND_CLEAR},
    {12.5, "Mostly clear", WX_COND_MOSTLY_CLEAR},
    {37.499, "Mostly clear", WX_COND_MOSTLY_CLEAR},
    {37.5, "Partly cloudy", WX_COND_PARTLY_CLOUDY},
    {62.499, "Partly cloudy", WX_COND_PARTLY_CLOUDY},
    {62.5, "Mostly cloudy", WX_COND_MOSTLY_CLOUDY},
    {87.499, "Mostly cloudy", WX_COND_MOSTLY_CLOUDY},
    {87.5, "Overcast", WX_COND_OVERCAST},
    {100.0, "Overcast", WX_COND_OVERCAST},
    {-5.0, "Clear", WX_COND_CLEAR},
    {-INFINITY, "Clear", WX_COND_CLEAR},
    {1000.0, "Overcast", WX_COND_OVERCAST},
    {INFINITY, "Overcast", WX_COND_OVERCAST},
    {NAN, "Unknown", WX_COND_UNKNOWN},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_assert_cmpstr(wx_cloud_label(cases[i].pct), ==, cases[i].label);
    g_assert_cmpint(wx_cloud_condition(cases[i].pct), ==, cases[i].cond);
  }
}

static void
test_condition_labels(void)
{
  static const char *const labels[WX_COND_COUNT] = {
    "Unknown", "Clear", "Mostly clear", "Partly cloudy", "Mostly cloudy", "Overcast", "Fog",
    "Drizzle", "Light rain", "Rain", "Heavy rain", "Showers", "Thunderstorm", "Snow", "Sleet",
  };
  for (int c = 0; c < WX_COND_COUNT; c++)
    g_assert_cmpstr(wx_condition_label((WxCondition)c), ==, labels[c]);
  ASSERT_CRITICAL("wx_condition_label", g_assert_cmpstr(wx_condition_label(WX_COND_COUNT), ==, "Unknown"));
  ASSERT_CRITICAL("wx_condition_label", g_assert_cmpstr(wx_condition_label((WxCondition)-1), ==, "Unknown"));
}

static WxCondition
derive(double cloud, double prob, double mm, double temp, const int *votes, guint n)
{
  WxConditionInput in = {cloud, prob, mm, temp, votes, n};
  return wx_condition_derive(&in);
}

static void
test_condition_wmo_rules(void)
{
  const int thunder[] = {95, 96, 97, 99}, snow[] = {71, 73, 75, 77, 85, 86};
  const int sleet[] = {56, 57, 66, 67}, fog[] = {45, 48};
  for (guint i = 0; i < 4; i++) {
    int one[] = {thunder[i]};
    g_assert_cmpint(derive(50, NAN, 0, 20, one, 1), ==, WX_COND_THUNDERSTORM);
  }
  for (guint i = 0; i < 6; i++) {
    int one[] = {snow[i]};
    g_assert_cmpint(derive(50, NAN, 0, 2.0, one, 1), ==, WX_COND_SNOW);
    g_assert_cmpint(derive(50, NAN, 0, -10.0, one, 1), ==, WX_COND_SNOW);
    /* too warm for snow: falls through to the sky class */
    g_assert_cmpint(derive(50, NAN, 0, 2.01, one, 1), ==, WX_COND_PARTLY_CLOUDY);
    /* unknown temperature fails the temperature test */
    g_assert_cmpint(derive(50, NAN, 0, NAN, one, 1), ==, WX_COND_PARTLY_CLOUDY);
  }
  for (guint i = 0; i < 4; i++) {
    int one[] = {sleet[i]};
    g_assert_cmpint(derive(50, NAN, 0, 20, one, 1), ==, WX_COND_SLEET);
  }
  for (guint i = 0; i < 2; i++) {
    int one[] = {fog[i]};
    g_assert_cmpint(derive(50, NAN, 0, 20, one, 1), ==, WX_COND_FOG);
  }
  /* neighbouring codes are not in the sets */
  int others[] = {0, 1, 3, 44, 46, 49, 55, 58, 65, 68, 70, 72, 76, 78, 84, 87, 94, 98};
  for (guint i = 0; i < G_N_ELEMENTS(others); i++) {
    int one[] = {others[i]};
    g_assert_cmpint(derive(50, NAN, 0, 0, one, 1), ==, WX_COND_PARTLY_CLOUDY);
  }
}

static void
test_condition_majority(void)
{
  /* exactly 50 % of the codes counts; below does not */
  int half[] = {95, 0};
  g_assert_cmpint(derive(0, NAN, 0, 20, half, 2), ==, WX_COND_THUNDERSTORM);
  int minority[] = {95, 0, 0};
  g_assert_cmpint(derive(0, NAN, 0, 20, minority, 3), ==, WX_COND_CLEAR);
  int two_of_four[] = {45, 45, 3, 3};
  g_assert_cmpint(derive(0, NAN, 0, 20, two_of_four, 4), ==, WX_COND_FOG);
  /* negative codes do not take part in the count at all */
  int with_missing[] = {-1, -1, -1, 95};
  g_assert_cmpint(derive(0, NAN, 0, 20, with_missing, 4), ==, WX_COND_THUNDERSTORM);
  int all_missing[] = {-1, -1};
  g_assert_cmpint(derive(0, NAN, 0, 20, all_missing, 2), ==, WX_COND_CLEAR);
  g_assert_cmpint(derive(0, NAN, 0, 20, NULL, 0), ==, WX_COND_CLEAR);
  /* a code beyond 99 supplies a code but belongs to no class */
  int big[] = {95, 150, 150};
  g_assert_cmpint(derive(0, NAN, 0, 20, big, 3), ==, WX_COND_CLEAR);
  int big2[] = {95, 150};
  g_assert_cmpint(derive(0, NAN, 0, 20, big2, 2), ==, WX_COND_THUNDERSTORM);
  /* priority: thunder > snow > sleet > fog > rain > sky; a class needs its own majority */
  int mix_ts[] = {95, 95, 71, 71};
  g_assert_cmpint(derive(0, NAN, 0, 0, mix_ts, 4), ==, WX_COND_THUNDERSTORM);
  int mix_snow_sleet[] = {71, 71, 56, 56};
  g_assert_cmpint(derive(0, NAN, 0, 0, mix_snow_sleet, 4), ==, WX_COND_SNOW);
  g_assert_cmpint(derive(0, NAN, 0, 5, mix_snow_sleet, 4), ==, WX_COND_SLEET);
  int mix_sleet_fog[] = {56, 56, 45, 45};
  g_assert_cmpint(derive(0, NAN, 0, 0, mix_sleet_fog, 4), ==, WX_COND_SLEET);
  /* a thunder code beats rain intensity */
  int one_thunder[] = {96};
  g_assert_cmpint(derive(100, 100, 20, 20, one_thunder, 1), ==, WX_COND_THUNDERSTORM);
  /* fog beats rain */
  int one_fog[] = {45};
  g_assert_cmpint(derive(100, 100, 5, 20, one_fog, 1), ==, WX_COND_FOG);
  /* many votes: the count arithmetic is exact (3 of 6 is half, 2 of 5 is not) */
  int six[] = {95, 95, 95, 0, 0, 0};
  g_assert_cmpint(derive(0, NAN, 0, 20, six, 6), ==, WX_COND_THUNDERSTORM);
  int five[] = {95, 95, 0, 0, 0};
  g_assert_cmpint(derive(0, NAN, 0, 20, five, 5), ==, WX_COND_CLEAR);
}

static void
test_condition_wet_and_intensity(void)
{
  /* wet = >= 0.1 mm and (probability unknown or >= 30 %) */
  g_assert_true(wx_is_wet_hour(0.1, NAN));
  g_assert_true(wx_is_wet_hour(0.1, 30.0));
  g_assert_false(wx_is_wet_hour(0.1, 29.999));
  g_assert_false(wx_is_wet_hour(0.0999, NAN));
  g_assert_false(wx_is_wet_hour(0.0999, 100.0));
  g_assert_false(wx_is_wet_hour(NAN, 100.0));
  g_assert_false(wx_is_wet_hour(NAN, NAN));
  g_assert_true(wx_is_wet_hour(50.0, 0.0 + 30.0));
  g_assert_false(wx_is_wet_hour(-1.0, NAN));

  /* intensity, overcast (no showers): 0.5 / 2.5 / 7.6 */
  g_assert_cmpint(derive(100, NAN, 0.1, 20, NULL, 0), ==, WX_COND_DRIZZLE);
  g_assert_cmpint(derive(100, NAN, 0.4999, 20, NULL, 0), ==, WX_COND_DRIZZLE);
  g_assert_cmpint(derive(100, NAN, 0.5, 20, NULL, 0), ==, WX_COND_LIGHT_RAIN);
  g_assert_cmpint(derive(100, NAN, 2.4999, 20, NULL, 0), ==, WX_COND_LIGHT_RAIN);
  g_assert_cmpint(derive(100, NAN, 2.5, 20, NULL, 0), ==, WX_COND_RAIN);
  g_assert_cmpint(derive(100, NAN, 7.5999, 20, NULL, 0), ==, WX_COND_RAIN);
  g_assert_cmpint(derive(100, NAN, 7.6, 20, NULL, 0), ==, WX_COND_HEAVY_RAIN);
  g_assert_cmpint(derive(100, NAN, 400, 20, NULL, 0), ==, WX_COND_HEAVY_RAIN);
  /* showers: cloud < 87.5 and rate < 7.6 */
  g_assert_cmpint(derive(87.499, NAN, 0.3, 20, NULL, 0), ==, WX_COND_SHOWERS);
  g_assert_cmpint(derive(0, 50, 3.0, 20, NULL, 0), ==, WX_COND_SHOWERS);
  g_assert_cmpint(derive(50, 50, 7.5999, 20, NULL, 0), ==, WX_COND_SHOWERS);
  g_assert_cmpint(derive(50, 50, 7.6, 20, NULL, 0), ==, WX_COND_HEAVY_RAIN);
  g_assert_cmpint(derive(87.5, 50, 3.0, 20, NULL, 0), ==, WX_COND_RAIN);
  /* unknown cloud never gives showers */
  g_assert_cmpint(derive(NAN, 50, 3.0, 20, NULL, 0), ==, WX_COND_RAIN);
  g_assert_cmpint(derive(NAN, NAN, 0.2, 20, NULL, 0), ==, WX_COND_DRIZZLE);
  /* not wet: sky class (rain below 0.1 mm or a probability below 30 %) */
  g_assert_cmpint(derive(100, 29.9, 5.0, 20, NULL, 0), ==, WX_COND_OVERCAST);
  g_assert_cmpint(derive(10, NAN, 0.09, 20, NULL, 0), ==, WX_COND_CLEAR);
  g_assert_cmpint(derive(NAN, NAN, 0, 20, NULL, 0), ==, WX_COND_UNKNOWN);
  g_assert_cmpint(derive(NAN, NAN, NAN, NAN, NULL, 0), ==, WX_COND_UNKNOWN);
  g_assert_cmpint(derive(30, NAN, NAN, 20, NULL, 0), ==, WX_COND_MOSTLY_CLEAR);
  g_assert_cmpint(derive(50, 0, 0, 20, NULL, 0), ==, WX_COND_PARTLY_CLOUDY);
  g_assert_cmpint(derive(70, 0, 0, 20, NULL, 0), ==, WX_COND_MOSTLY_CLOUDY);

  /* the rain class helper */
  g_assert_cmpint(wx_condition_rain_class(NAN, NAN), ==, WX_COND_UNKNOWN);
  g_assert_cmpint(wx_condition_rain_class(50, NAN), ==, WX_COND_UNKNOWN);
  g_assert_cmpint(wx_condition_rain_class(NAN, 0.2), ==, WX_COND_DRIZZLE);
  g_assert_cmpint(wx_condition_rain_class(50, 0.0), ==, WX_COND_SHOWERS);
}

static void
test_condition_criticals(void)
{
  ASSERT_CRITICAL("wx_condition_derive", g_assert_cmpint(wx_condition_derive(NULL), ==, WX_COND_UNKNOWN));
  WxConditionInput in = {50, NAN, 0, 20, NULL, 3};
  ASSERT_CRITICAL("wx_condition_derive", g_assert_cmpint(wx_condition_derive(&in), ==, WX_COND_UNKNOWN));
}

/* The vote array is read only up to n_wmo_votes entries (guard page). */
static void
test_condition_guard_page(void)
{
  long page = sysconf(_SC_PAGESIZE);
  for (guint n = 1; n <= 6; n++) {
    void *map = mmap(NULL, (gsize)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    g_assert_true(map != MAP_FAILED);
    g_assert_cmpint(mprotect((char *)map + page, (gsize)page, PROT_NONE), ==, 0);
    int *votes = (int *)((char *)map + page - (gsize)n * sizeof(int));
    for (guint i = 0; i < n; i++)
      votes[i] = 45;
    g_assert_cmpint(derive(0, NAN, 0, 20, votes, n), ==, WX_COND_FOG);
    munmap(map, (gsize)page * 2);
  }
}

/* ------------------------------------------------------------------------ */
/* blend: helpers                                                           */
/* ------------------------------------------------------------------------ */

/* Bitwise equality of two doubles (NAN equals NAN with the same payload). */
static gboolean
same_bits(double a, double b)
{
  return memcmp(&a, &b, sizeof a) == 0;
}

static void
assert_hours_identical(const WxForecast *a, const WxForecast *b)
{
  guint na, nb;
  const WxBlendHour *ha = wx_forecast_get_hours(a, &na);
  const WxBlendHour *hb = wx_forecast_get_hours(b, &nb);
  g_assert_cmpuint(na, ==, nb);
  for (guint i = 0; i < na; i++) {
    g_assert_cmpint(ha[i].t_s, ==, hb[i].t_s);
    g_assert_true(same_bits(ha[i].temp_c, hb[i].temp_c));
    g_assert_true(same_bits(ha[i].feels_c, hb[i].feels_c));
    g_assert_true(same_bits(ha[i].precip_mm, hb[i].precip_mm));
    g_assert_true(same_bits(ha[i].precip_mm_max, hb[i].precip_mm_max));
    g_assert_true(same_bits(ha[i].precip_prob, hb[i].precip_prob));
    g_assert_true(same_bits(ha[i].cloud_pct, hb[i].cloud_pct));
    g_assert_true(same_bits(ha[i].wind_kmh, hb[i].wind_kmh));
    g_assert_true(same_bits(ha[i].gust_kmh, hb[i].gust_kmh));
    g_assert_true(same_bits(ha[i].humidity_pct, hb[i].humidity_pct));
    g_assert_true(same_bits(ha[i].temp_spread_c, hb[i].temp_spread_c));
    g_assert_cmpuint(ha[i].n_members, ==, hb[i].n_members);
    g_assert_cmpint(ha[i].condition, ==, hb[i].condition);
    g_assert_cmpint(ha[i].is_day, ==, hb[i].is_day);
  }
}

static void
assert_forecasts_identical(const WxForecast *a, const WxForecast *b)
{
  assert_hours_identical(a, b);
  guint na, nb;
  const WxQuarter *qa = wx_forecast_get_quarters(a, &na);
  const WxQuarter *qb = wx_forecast_get_quarters(b, &nb);
  g_assert_cmpuint(na, ==, nb);
  for (guint i = 0; i < na; i++) {
    g_assert_cmpint(qa[i].t_s, ==, qb[i].t_s);
    g_assert_true(same_bits(qa[i].precip_mm, qb[i].precip_mm));
  }
  const WxDay *da = wx_forecast_get_days(a, &na);
  const WxDay *db = wx_forecast_get_days(b, &nb);
  g_assert_cmpuint(na, ==, nb);
  for (guint i = 0; i < na; i++) {
    g_assert_cmpint(da[i].start_s, ==, db[i].start_s);
    g_assert_true(same_bits(da[i].temp_max_c, db[i].temp_max_c));
    g_assert_true(same_bits(da[i].temp_min_c, db[i].temp_min_c));
    g_assert_true(same_bits(da[i].precip_mm, db[i].precip_mm));
    g_assert_true(same_bits(da[i].precip_prob_max, db[i].precip_prob_max));
    g_assert_true(same_bits(da[i].cloud_pct, db[i].cloud_pct));
    g_assert_cmpint(da[i].condition, ==, db[i].condition);
  }
  g_assert_cmpint(wx_forecast_get_generated_s(a), ==, wx_forecast_get_generated_s(b));
}

/* A member built by hand, bypassing wx_member_*() so the tests can feed the blend data
 * that the builder would refuse. */
static WxMember
raw_member(const char *src, const char *model, const WxHour *hours, guint n, const WxQuarter *q,
           guint nq)
{
  WxMember m;
  memset(&m, 0, sizeof m);
  m.source_id = src;
  m.model_id = model;
  m.fetched_s = NOW_S;
  m.hours = hours;
  m.n_hours = n;
  m.quarters = q;
  m.n_quarters = nq;
  return m;
}

/* Blends a hand-built list of members at @now (a NULL entry stays a NULL member). */
static WxForecast *
blend_raw_at(const WxPlace *place, WxMember **members, guint n, gint64 now, GError **err)
{
  WxSourceResult r = {(char *)"raw", g_ptr_array_new()};
  for (guint i = 0; i < n; i++)
    g_ptr_array_add(r.members, members[i]);
  const WxSourceResult *list[] = {&r};
  WxForecast *fc = wx_blend_forecast(place, list, 1, NULL, 0, now, err);
  g_ptr_array_free(r.members, TRUE);
  return fc;
}

static WxForecast *
blend_raw(const WxPlace *place, WxMember **members, guint n, GError **err)
{
  return blend_raw_at(place, members, n, NOW_S, err);
}

static void
add_hour_vals(WxMember *m, gint64 t_s, const Vals *v)
{
  WxHour h;
  wx_hour_init(&h);
  h.t_s = t_s;
  fill_const(&h, 0, (gpointer)v);
  g_assert_true(wx_member_add_hour(m, &h));
}

static WxMember *
new_member(const char *src, const char *model)
{
  GError *err = NULL;
  WxMember *m = wx_member_new(src, model, NOW_S, &err);
  g_assert_no_error(err);
  return m;
}

/* ------------------------------------------------------------------------ */
/* blend: alignment and values                                              */
/* ------------------------------------------------------------------------ */

static void
test_blend_alignment(void)
{
  g_autoptr(WxPlace) p = london();
  Vals v = vnone();
  v.temp = 15;

  /* hours 09:00 .. 38:00 (30 hours): the blend starts one hour before the hour containing now */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 30, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  const WxBlendHour *h = hours_of(fc, &n);
  g_assert_cmpuint(n, ==, 28);
  g_assert_cmpint(h[0].t_s, ==, T0 + 11 * H);
  g_assert_cmpint(h[n - 1].t_s, ==, T0 + 38 * H);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpint(h[i].t_s % H, ==, 0);
    if (i > 0)
      g_assert_cmpint(h[i].t_s - h[i - 1].t_s, ==, H);
    ASSERT_NEAR(h[i].temp_c, 15.0);
  }
  g_assert_cmpint(wx_forecast_get_generated_s(fc), ==, NOW_S);
  g_assert_true(wx_forecast_get_place(fc) != p); /* deep copy */
  g_assert_cmpstr(wx_forecast_get_place(fc)->timezone, ==, "Europe/London");
  fx_free(fx);

  /* the start depends only on the hour containing now */
  gint64 nows[] = {T0 + 12 * H, T0 + 12 * H + 1, T0 + 13 * H - 1};
  for (guint i = 0; i < G_N_ELEMENTS(nows); i++) {
    Fx *f2 = fx_new();
    fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 30, &v));
    g_autoptr(WxForecast) c2 = fx_blend(f2, p, nows[i]);
    g_assert_cmpint(hours_of(c2, &n)[0].t_s, ==, T0 + 11 * H);
    g_assert_cmpint(wx_forecast_get_generated_s(c2), ==, nows[i]);
    fx_free(f2);
  }
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 30, &v));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, T0 + 13 * H);
  g_assert_cmpint(hours_of(c3, &n)[0].t_s, ==, T0 + 12 * H);
  g_assert_cmpuint(n, ==, 27);
  fx_free(f3);
}

static void
test_blend_leading_gap_and_cap(void)
{
  g_autoptr(WxPlace) p = london();
  Vals v = vnone();
  v.temp = 15;

  /* data starts at 12:00: the 11:00 bucket exists but is empty */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 12 * H, 10, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  const WxBlendHour *h = hours_of(fc, &n);
  g_assert_cmpuint(n, ==, 11);
  g_assert_cmpint(h[0].t_s, ==, T0 + 11 * H);
  ASSERT_NAN(h[0].temp_c);
  ASSERT_NAN(h[0].feels_c);
  ASSERT_NAN(h[0].precip_mm);
  ASSERT_NAN(h[0].precip_mm_max);
  ASSERT_NAN(h[0].precip_prob);
  ASSERT_NAN(h[0].cloud_pct);
  ASSERT_NAN(h[0].wind_kmh);
  ASSERT_NAN(h[0].gust_kmh);
  ASSERT_NAN(h[0].humidity_pct);
  ASSERT_NAN(h[0].temp_spread_c);
  g_assert_cmpuint(h[0].n_members, ==, 0);
  g_assert_cmpint(h[0].condition, ==, WX_COND_UNKNOWN);
  ASSERT_NEAR(h[1].temp_c, 15.0);
  fx_free(fx);

  /* a gap inside a member leaves empty buckets in the contiguous list */
  Fx *f2 = fx_new();
  WxMember *m = new_member("open-meteo", "ecmwf");
  for (int i = 12; i <= 14; i++)
    add_hour_vals(m, T0 + i * H, &v);
  for (int i = 17; i <= 22; i++)
    add_hour_vals(m, T0 + i * H, &v);
  fx_add(f2, "open-meteo", m);
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  h = hours_of(c2, &n);
  g_assert_cmpuint(n, ==, 12); /* 11:00 .. 22:00 */
  for (int i = 11; i <= 22; i++) {
    gboolean has = (i >= 12 && i <= 14) || (i >= 17);
    g_assert_cmpint(h[i - 11].t_s, ==, T0 + i * H);
    g_assert_cmpuint(h[i - 11].n_members, ==, has ? 1 : 0);
    g_assert_true(has ? isfinite(h[i - 11].temp_c) : isnan(h[i - 11].temp_c));
  }
  fx_free(f2);

  /* at most WX_BLEND_MAX_HOURS buckets, counted from the first */
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0, WX_MEMBER_MAX_HOURS, &v));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, NOW_S);
  h = hours_of(c3, &n);
  g_assert_cmpuint(n, ==, WX_BLEND_MAX_HOURS);
  g_assert_cmpint(h[0].t_s, ==, T0 + 11 * H);
  g_assert_cmpint(h[n - 1].t_s, ==, T0 + (11 + WX_BLEND_MAX_HOURS - 1) * H);
  fx_free(f3);

  /* exactly the cap, and one hour less */
  Fx *f4 = fx_new();
  fx_add(f4, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 11 * H, WX_BLEND_MAX_HOURS, &v));
  g_autoptr(WxForecast) c4 = fx_blend(f4, p, NOW_S);
  g_assert_cmpuint(wx_forecast_get_hours(c4, &n) != NULL ? n : 0, ==, WX_BLEND_MAX_HOURS);
  fx_free(f4);
  Fx *f5 = fx_new();
  fx_add(f5, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 11 * H, WX_BLEND_MAX_HOURS - 1, &v));
  g_autoptr(WxForecast) c5 = fx_blend(f5, p, NOW_S);
  g_assert_cmpuint(wx_forecast_get_hours(c5, &n) != NULL ? n : 0, ==, WX_BLEND_MAX_HOURS - 1);
  fx_free(f5);
}

static void
test_blend_time_edges(void)
{
  g_autoptr(WxPlace) p = london();
  Vals v = vnone();
  v.temp = 15;
  /* now at the very start of the supported range: no bucket before WX_TIME_MIN_S */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", WX_TIME_MIN_S, 40, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, WX_TIME_MIN_S);
  guint n;
  g_assert_cmpint(hours_of(fc, &n)[0].t_s, ==, WX_TIME_MIN_S);
  g_assert_cmpuint(n, ==, 40);
  fx_free(fx);
  /* the same one hour later: starts one hour before now */
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", WX_TIME_MIN_S, 40, &v));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, WX_TIME_MIN_S + H);
  g_assert_cmpint(hours_of(c2, &n)[0].t_s, ==, WX_TIME_MIN_S);
  fx_free(f2);
  /* the end of the range: the last accepted bucket is WX_TIME_MAX_S - 3600 */
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", WX_TIME_MAX_S - 20 * H, 20, &v));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, WX_TIME_MAX_S - 10 * H);
  const WxBlendHour *last = hours_of(c3, &n);
  g_assert_cmpint(last[n - 1].t_s, ==, WX_TIME_MAX_S - H);
  fx_free(f3);

  /* out-of-range now is an error, not a critical */
  Fx *f4 = fx_new();
  fx_add(f4, "open-meteo", mk_member("open-meteo", "ecmwf", T0, 40, &v));
  assert_blend_fails(f4, p, WX_TIME_MIN_S - 1, WX_ERROR_INVALID_ARG);
  assert_blend_fails(f4, p, WX_TIME_MAX_S, WX_ERROR_INVALID_ARG);
  assert_blend_fails(f4, p, G_MININT64, WX_ERROR_INVALID_ARG);
  assert_blend_fails(f4, p, G_MAXINT64, WX_ERROR_INVALID_ARG);
  assert_blend_fails(f4, p, 0, WX_ERROR_INVALID_ARG);
  fx_free(f4);
}

static void
test_blend_single_member(void)
{
  g_autoptr(WxPlace) p = london();
  Vals v = {.temp = 14.5, .feels = 13.0, .precip = 0.0, .prob = 20.0, .cloud = 50.0,
            .wind = 12.0, .gust = 25.0, .hum = 77.0, .wmo = 3};
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 30, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  const WxBlendHour *h = hours_of(fc, &n);
  for (guint i = 0; i < n; i++) {
    ASSERT_NEAR(h[i].temp_c, 14.5);
    ASSERT_NEAR(h[i].feels_c, 13.0);
    ASSERT_NEAR(h[i].precip_mm, 0.0);
    ASSERT_NEAR(h[i].precip_mm_max, 0.0);
    ASSERT_NEAR(h[i].precip_prob, 20.0);
    ASSERT_NEAR(h[i].cloud_pct, 50.0);
    ASSERT_NEAR(h[i].wind_kmh, 12.0);
    ASSERT_NEAR(h[i].gust_kmh, 25.0);
    ASSERT_NEAR(h[i].humidity_pct, 77.0);
    ASSERT_NAN(h[i].temp_spread_c); /* one member: no spread */
    g_assert_cmpuint(h[i].n_members, ==, 1);
    g_assert_cmpint(h[i].condition, ==, WX_COND_PARTLY_CLOUDY);
    g_assert_cmpint(h[i].is_day, ==, wx_sun_is_up(51.5074, -0.1278, h[i].t_s));
  }
  /* both day and night occur in a 28 hour list */
  gboolean day = FALSE, night = FALSE;
  for (guint i = 0; i < n; i++) {
    day |= h[i].is_day;
    night |= !h[i].is_day;
  }
  g_assert_true(day && night);
  guint nq, nd, ns;
  g_assert_null(wx_forecast_get_quarters(fc, &nq));
  g_assert_cmpuint(nq, ==, 0);
  g_assert_nonnull(wx_forecast_get_days(fc, &nd));
  g_assert_null(wx_forecast_get_sources(fc, &ns));
  g_assert_cmpuint(ns, ==, 0);
  fx_free(fx);
}

static void
test_blend_median_and_horizon(void)
{
  /* Miami: US weights. gem 10 (0.5 everywhere), icon 20 (0.5 / 1 / 1 / 1), ecmwf 30
   * (1 / 1.5 / 2 / 2): in band H0 the weights are 0.5 / 0.5 / 1 (exactly half below 20 and
   * 20 itself: the mean 25), in band H2 0.5 / 1 / 2 (30 carries more than half). */
  g_autoptr(WxPlace) p = miami();
  Vals gem = vnone(), icon = vnone(), ecmwf = vnone();
  gem.temp = 10;
  icon.temp = 20;
  ecmwf.temp = 30;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "gem", T0 + 10 * H, 80, &gem));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 80, &icon));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 80, &ecmwf));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  /* horizon of the 13:00 bucket: 23 minutes -> H0 */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->temp_c, 25.0);
  /* 31:00 is 18.38 h ahead -> H2; 30:00 is 17.38 h ahead -> H1 (also 25: total 3, tie) */
  ASSERT_NEAR(hour_at(fc, T0 + 30 * H)->temp_c, 25.0);
  ASSERT_NEAR(hour_at(fc, T0 + 31 * H)->temp_c, 30.0);
  /* the spread is max - min of the member values, n_members the three of them */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->temp_spread_c, 20.0);
  g_assert_cmpuint(hour_at(fc, T0 + 13 * H)->n_members, ==, 3);
  /* hours before now are not in the future: horizon 0 -> H0 */
  ASSERT_NEAR(hour_at(fc, T0 + 11 * H)->temp_c, 25.0);
  fx_free(fx);

  /* HRRR (3 / 3 / 0.5) against ECMWF (1 / 1.5 / 2): 20 wins early, 10 later; and the HRRR
   * member drops out after 48 h (n_members shows it) */
  Vals hrrr = vnone(), ec = vnone();
  hrrr.temp = 20;
  ec.temp = 10;
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 80, &hrrr));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 80, &ec));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  ASSERT_NEAR(hour_at(c2, T0 + 13 * H)->temp_c, 20.0);
  g_assert_cmpuint(hour_at(c2, T0 + 13 * H)->n_members, ==, 2);
  ASSERT_NEAR(hour_at(c2, T0 + 31 * H)->temp_c, 10.0);
  /* now + 48 h = 60:37; the 60:00 bucket is 47.38 h ahead, the 61:00 bucket 48.38 h */
  g_assert_cmpuint(hour_at(c2, T0 + 60 * H)->n_members, ==, 2);
  g_assert_cmpuint(hour_at(c2, T0 + 61 * H)->n_members, ==, 1);
  ASSERT_NEAR(hour_at(c2, T0 + 61 * H)->temp_c, 10.0);
  ASSERT_NAN(hour_at(c2, T0 + 61 * H)->temp_spread_c);
  fx_free(f2);
}

static void
test_blend_region(void)
{
  Vals hrrr = vnone(), ec = vnone(), nws = vnone();
  hrrr.temp = 30;
  ec.temp = 10;
  nws.temp = 40;

  struct {
    double lat, lon;
    const char *name;
    gboolean us;
  } places[] = {
    {25.7617, -80.1918, "Miami", TRUE},      /* CONUS and NWS box */
    {43.65, -79.38, "Toronto", TRUE},        /* inside the coarse CONUS box */
    {61.2, -149.9, "Anchorage", TRUE},       /* NWS box only */
    {19.9, -155.6, "Hawaii", TRUE},          /* NWS box only */
    {51.5074, -0.1278, "London", FALSE},
    {35.68, 139.69, "Tokyo", FALSE},
    {-33.87, 151.21, "Sydney", FALSE},
    {51.05, -114.07, "Calgary", TRUE},       /* CONUS box only (north of the NWS box) */
    {23.11, -82.37, "Havana", TRUE},         /* CONUS box only (south of the NWS box) */
  };
  for (guint i = 0; i < G_N_ELEMENTS(places); i++) {
    g_autoptr(WxPlace) p = mk_place(places[i].lat, places[i].lon, "UTC");
    Fx *fx = fx_new();
    fx_add(fx, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &hrrr));
    fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &ec));
    g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
    const WxBlendHour *h = hour_at(fc, T0 + 13 * H);
    if (places[i].us) {
      /* US weights: hrrr 3 against ecmwf 1 */
      ASSERT_NEAR(h->temp_c, 30.0);
      g_assert_cmpuint(h->n_members, ==, 2);
    } else {
      /* HRRR is CONUS-only: weight 0 */
      ASSERT_NEAR(h->temp_c, 10.0);
      g_assert_cmpuint(h->n_members, ==, 1);
    }
    fx_free(fx);
  }

  /* an NWS member makes any place a US-region place (London here), and NWS takes part */
  g_autoptr(WxPlace) lon = london();
  Fx *f2 = fx_new();
  fx_add(f2, "nws", mk_member("nws", "nws", T0 + 10 * H, 30, &nws));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &ec));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &hrrr));
  g_autoptr(WxForecast) c2 = fx_blend(f2, lon, NOW_S);
  /* nws 4 (40), hrrr 3 (30), ecmwf 1 (10): total 8; 10 -> 1, 30 -> 4 (8 == 8 exactly): mean 35 */
  ASSERT_NEAR(hour_at(c2, T0 + 13 * H)->temp_c, 35.0);
  g_assert_cmpuint(hour_at(c2, T0 + 13 * H)->n_members, ==, 3);
  fx_free(f2);

  /* without NWS in London there is no region switch: ecmwf 10 only (hrrr weighs 0) */
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &ec));
  fx_add(f3, "open-meteo", mk_member("open-meteo", "nbm", T0 + 10 * H, 30, &nws));
  g_autoptr(WxForecast) c3 = fx_blend(f3, lon, NOW_S);
  ASSERT_NEAR(hour_at(c3, T0 + 13 * H)->temp_c, 10.0); /* NBM is CONUS-only */
  fx_free(f3);

  /* an NWS member that does not take part (descending hours) does not make London a US place:
   * HRRR still weighs 0 */
  WxHour bad[8];
  for (guint i = 0; i < 8; i++) {
    wx_hour_init(&bad[i]);
    bad[i].t_s = T0 + (20 - i) * H;
    bad[i].temp_c = 99;
  }
  WxMember rnws = raw_member("nws", "nws", bad, 8, NULL, 0);
  g_autoptr(WxMember) lec = mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &ec);
  g_autoptr(WxMember) lhr = mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &hrrr);
  WxMember *list[] = {&rnws, lec, lhr};
  g_autoptr(WxForecast) c4 = blend_raw(lon, list, 3, NULL);
  g_assert_nonnull(c4);
  ASSERT_NEAR(hour_at(c4, T0 + 13 * H)->temp_c, 10.0);
  g_assert_cmpuint(hour_at(c4, T0 + 13 * H)->n_members, ==, 1);
}

static void
test_blend_precip_and_probability(void)
{
  g_autoptr(WxPlace) p = london();
  Vals a = vnone(), b = vnone(), c = vnone();
  a.precip = 0.5; /* ecmwf, weight 3 */
  b.precip = 0.0; /* icon, weight 2.5 */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &a));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &b));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  const WxBlendHour *h = hour_at(fc, T0 + 13 * H);
  ASSERT_NEAR(h->precip_mm, 0.5);     /* 3 of 5.5 is above half from the top */
  ASSERT_NEAR(h->precip_mm_max, 0.5);
  /* no probability from anyone: 100 * weight(precip >= 0.1) / weight(all) = 100 * 3 / 5.5 */
  ASSERT_NEAR(h->precip_prob, 100.0 * 3.0 / 5.5);
  fx_free(fx);

  /* one member supplies a probability: it is used, not derived */
  c.precip = 0.2;
  c.prob = 20.0;
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &a));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &b));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "gem", T0 + 10 * H, 30, &c));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  h = hour_at(c2, T0 + 13 * H);
  ASSERT_NEAR(h->precip_prob, 20.0);
  /* values 0 (2.5), 0.2 (1.5), 0.5 (3): total 7, 0 -> 2.5, 0.2 -> 4 (8 > 7) */
  ASSERT_NEAR(h->precip_mm, 0.2);
  ASSERT_NEAR(h->precip_mm_max, 0.5);
  fx_free(f2);

  /* probabilities are a weighted median among those who supply one */
  Vals p1 = vnone(), p2 = vnone(), p3 = vnone();
  p1.prob = 10; /* ecmwf 1 */
  p2.prob = 50; /* icon 1 */
  p3.prob = 90; /* gem 1 */
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &p1));
  fx_add(f3, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &p2));
  fx_add(f3, "open-meteo", mk_member("open-meteo", "gem", T0 + 10 * H, 30, &p3));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, NOW_S);
  ASSERT_NEAR(hour_at(c3, T0 + 13 * H)->precip_prob, 50.0);
  ASSERT_NAN(hour_at(c3, T0 + 13 * H)->precip_mm);
  ASSERT_NAN(hour_at(c3, T0 + 13 * H)->precip_mm_max);
  fx_free(f3);

  /* neither precipitation nor probability anywhere: both unknown */
  Vals t = vnone();
  t.temp = 12;
  Fx *f4 = fx_new();
  fx_add(f4, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &t));
  g_autoptr(WxForecast) c4 = fx_blend(f4, p, NOW_S);
  ASSERT_NAN(hour_at(c4, T0 + 13 * H)->precip_prob);
  ASSERT_NAN(hour_at(c4, T0 + 13 * H)->precip_mm);
  fx_free(f4);

  /* the NWS probability (weight 5) outweighs three others (1 each) */
  g_autoptr(WxPlace) mi = miami();
  Vals np = vnone(), o1 = vnone(), o2 = vnone(), o3 = vnone();
  np.prob = 80;
  o1.prob = 10;
  o2.prob = 10;
  o3.prob = 10;
  Fx *f5 = fx_new();
  fx_add(f5, "nws", mk_member("nws", "nws", T0 + 10 * H, 30, &np));
  fx_add(f5, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &o1));
  fx_add(f5, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &o2));
  fx_add(f5, "open-meteo", mk_member("open-meteo", "gfs", T0 + 10 * H, 30, &o3));
  g_autoptr(WxForecast) c5 = fx_blend(f5, mi, NOW_S);
  ASSERT_NEAR(hour_at(c5, T0 + 13 * H)->precip_prob, 80.0);
  fx_free(f5);
}

static void
test_blend_member_counts_and_missing(void)
{
  g_autoptr(WxPlace) p = london();
  Vals only_cloud = vnone(), full = vnone(), only_temp = vnone();
  only_cloud.cloud = 100;
  full.temp = 10;
  full.cloud = 0;
  only_temp.temp = 12;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &full));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &only_cloud));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "gem", T0 + 10 * H, 30, &only_temp));
  /* an all-unknown member and a weight-0 member (HRRR outside the US) never count */
  fx_add(fx, "open-meteo", mk_member("open-meteo", "gfs", T0 + 10 * H, 30, &(Vals){NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN, 61}));
  Vals hv = vnone();
  hv.temp = 99;
  fx_add(fx, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &hv));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  const WxBlendHour *h = hour_at(fc, T0 + 13 * H);
  g_assert_cmpuint(h->n_members, ==, 3);
  /* temp: ecmwf 10 (3), gem 12 (1.5) -> 10 ; spread over those two */
  ASSERT_NEAR(h->temp_c, 10.0);
  ASSERT_NEAR(h->temp_spread_c, 2.0);
  /* cloud: ecmwf 0 (3), icon 100 (2.5): 3 of 5.5 -> 100? no: 0 carries 3, 6 > 5.5 -> 0 */
  ASSERT_NEAR(h->cloud_pct, 0.0);
  /* variables nobody supplies */
  ASSERT_NAN(h->wind_kmh);
  ASSERT_NAN(h->gust_kmh);
  ASSERT_NAN(h->humidity_pct);
  ASSERT_NAN(h->feels_c);
  fx_free(fx);

  /* only a temperature: the condition is unknown, everything else NAN */
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &only_temp));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  h = hour_at(c2, T0 + 13 * H);
  g_assert_cmpint(h->condition, ==, WX_COND_UNKNOWN);
  ASSERT_NAN(h->cloud_pct);
  g_assert_cmpuint(h->n_members, ==, 1);
  fx_free(f2);
}

static void
test_blend_conditions_from_wmo(void)
{
  g_autoptr(WxPlace) p = london();
  Vals a = vnone(), b = vnone(), c = vnone();
  a.temp = b.temp = c.temp = 10;
  a.cloud = b.cloud = c.cloud = 100;
  a.wmo = 95;
  b.wmo = 95;
  c.wmo = 0;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &a));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &b));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "gem", T0 + 10 * H, 30, &c));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  g_assert_cmpint(hour_at(fc, T0 + 13 * H)->condition, ==, WX_COND_THUNDERSTORM);
  fx_free(fx);

  /* snow needs a cold hour; the blended temperature decides */
  Vals s = vnone();
  s.temp = 1;
  s.wmo = 71;
  Vals warm = vnone();
  warm.temp = 8;
  warm.wmo = 71;
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &s));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 30, &warm));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  g_assert_cmpint(hour_at(c2, T0 + 13 * H)->condition, ==, WX_COND_SNOW); /* ecmwf 3 > icon 2.5 */
  fx_free(f2);

  /* no codes at all: derived from the blended cloud and rain */
  Vals r = vnone();
  r.temp = 12;
  r.cloud = 100;
  r.precip = 1.0;
  r.prob = 80;
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &r));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, NOW_S);
  g_assert_cmpint(hour_at(c3, T0 + 13 * H)->condition, ==, WX_COND_LIGHT_RAIN);
  fx_free(f3);

  /* only members that contribute vote: a HRRR member (weight 0 in London) saying 95 is ignored */
  Vals t = vnone();
  t.temp = 10;
  t.cloud = 10;
  t.wmo = 0;
  Vals hv = vnone();
  hv.temp = 10;
  hv.wmo = 95;
  Fx *f4 = fx_new();
  fx_add(f4, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 30, &t));
  fx_add(f4, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &hv));
  g_autoptr(WxForecast) c4 = fx_blend(f4, p, NOW_S);
  g_assert_cmpint(hour_at(c4, T0 + 13 * H)->condition, ==, WX_COND_CLEAR);
  fx_free(f4);
}

/* ------------------------------------------------------------------------ */
/* blend: dropout, hostile input, statuses                                  */
/* ------------------------------------------------------------------------ */

static void
test_blend_no_data(void)
{
  g_autoptr(WxPlace) p = london();
  GError *err = NULL;

  /* no results at all (NULL array with a zero count is allowed) */
  g_assert_null(wx_blend_forecast(p, NULL, 0, NULL, 0, NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_assert_cmpstr(err->message, ==, "no usable forecast data");
  g_clear_error(&err);
  /* the error location is optional */
  g_assert_null(wx_blend_forecast(p, NULL, 0, NULL, 0, NOW_S, NULL));

  /* results without members */
  Fx *fx = fx_new();
  g_ptr_array_add(fx->results, wx_source_result_new("open-meteo", NULL));
  assert_blend_fails(fx, p, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(fx);

  Vals v = vnone();
  v.temp = 10;

  /* fewer than WX_BLEND_MIN_HOURS contributing hours: an error; exactly that many: fine */
  for (guint n = 1; n <= WX_BLEND_MIN_HOURS + 1; n++) {
    Fx *f = fx_new();
    fx_add(f, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 12 * H, n, &v));
    if (n < WX_BLEND_MIN_HOURS) {
      assert_blend_fails(f, p, NOW_S, WX_ERROR_NOT_FOUND);
    } else {
      g_autoptr(WxForecast) fc = fx_blend(f, p, NOW_S);
      guint nh;
      g_assert_cmpuint(hours_of(fc, &nh) != NULL ? nh : 0, ==, n + 1);
    }
    fx_free(f);
  }

  /* the hours must be spread over one member: six hours split over two members is not enough */
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 12 * H, 3, &v));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "icon", T0 + 15 * H, 3, &v));
  assert_blend_fails(f2, p, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(f2);

  /* six hours but one of them without any value: five */
  Fx *f3 = fx_new();
  WxMember *m = new_member("open-meteo", "ecmwf");
  for (int i = 12; i < 18; i++) {
    Vals e = (i == 14) ? vnone() : v;
    add_hour_vals(m, T0 + i * H, &e);
  }
  fx_add(f3, "open-meteo", m);
  assert_blend_fails(f3, p, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(f3);

  /* only data from the past (before the first bucket) */
  Fx *f4 = fx_new();
  fx_add(f4, "open-meteo", mk_member("open-meteo", "ecmwf", T0, 11, &v)); /* 00:00 .. 10:00 */
  assert_blend_fails(f4, p, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(f4);

  /* the first bucket (11:00) counts; 11:00 .. 16:00 is six hours */
  Fx *f5 = fx_new();
  fx_add(f5, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 5 * H, 12, &v));
  g_autoptr(WxForecast) c5 = fx_blend(f5, p, NOW_S);
  g_assert_nonnull(c5);
  fx_free(f5);

  /* only members whose weight is 0 (HRRR outside the US) contribute nothing */
  Fx *f6 = fx_new();
  fx_add(f6, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 10 * H, 30, &v));
  assert_blend_fails(f6, p, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(f6);

  /* HRRR beyond 48 h only: its hours beyond the horizon have weight 0 */
  Fx *f7 = fx_new();
  g_autoptr(WxPlace) mi = miami();
  fx_add(f7, "open-meteo", mk_member("open-meteo", "hrrr", T0 + 61 * H, 10, &v));
  assert_blend_fails(f7, mi, NOW_S, WX_ERROR_NOT_FOUND);
  fx_free(f7);

  /* a member with out-of-range hand-built numbers only */
  WxHour bad[8];
  for (guint i = 0; i < 8; i++) {
    wx_hour_init(&bad[i]);
    bad[i].t_s = T0 + (12 + i) * H;
    bad[i].temp_c = 1000.0;
    bad[i].humidity_pct = -5.0;
    bad[i].wind_kmh = INFINITY;
    bad[i].precip_mm = -1.0;
    bad[i].cloud_pct = 101.0;
  }
  WxMember rm = raw_member("open-meteo", "ecmwf", bad, 8, NULL, 0);
  WxMember *list[] = {&rm};
  GError *e2 = NULL;
  g_assert_null(blend_raw(p, list, 1, &e2));
  g_assert_error(e2, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_clear_error(&e2);
}

static void
test_blend_garbage_members(void)
{
  g_autoptr(WxPlace) p = london();
  Vals good = vnone();
  good.temp = 10;
  /* the good member is icon (weight 2.5); each garbage member is ecmwf (weight 3) and says 60,
   * so if any of them took part the blended value would be 60 */
  WxHour hs[8], desc[8], odd[8], range[8];
  for (guint i = 0; i < 8; i++) {
    wx_hour_init(&hs[i]);
    hs[i].t_s = T0 + (10 + i) * H;
    hs[i].temp_c = 60;
    desc[i] = hs[i];
    desc[i].t_s = T0 + (20 - i) * H; /* descending */
    odd[i] = hs[i];
    odd[i].t_s = T0 + (10 + i) * H + 1800; /* not on the hour */
    range[i] = hs[i];
    range[i].t_s = i * H; /* 1970: before the supported range */
  }
  WxHour dup[3];
  for (guint i = 0; i < 3; i++) {
    dup[i] = hs[0];
  }

  WxMember garbage[] = {
    raw_member("open-meteo", "ecmwf", desc, 8, NULL, 0),
    raw_member("open-meteo", "ecmwf", odd, 8, NULL, 0),
    raw_member("open-meteo", "ecmwf", range, 8, NULL, 0),
    raw_member("open-meteo", "ecmwf", dup, 3, NULL, 0),          /* duplicate time stamps */
    raw_member("open-meteo", "ecmwf", NULL, 8, NULL, 0),         /* count without array */
    raw_member("open-meteo", "ecmwf", hs, WX_MEMBER_MAX_HOURS + 1, NULL, 0), /* too many */
    raw_member("open-meteo", "ecmwf", hs, G_MAXUINT, NULL, 0),
    raw_member("Open-Meteo", "ecmwf", hs, 8, NULL, 0),           /* invalid ids */
    raw_member("open-meteo", "", hs, 8, NULL, 0),
    raw_member("open-meteo", "../ecmwf", hs, 8, NULL, 0),
    raw_member(NULL, "ecmwf", hs, 8, NULL, 0),
    raw_member("open-meteo", NULL, hs, 8, NULL, 0),
  };
  g_autoptr(WxMember) real = mk_member("open-meteo", "icon", T0 + 10 * H, 8, &good);

  for (guint g = 0; g < G_N_ELEMENTS(garbage); g++) {
    WxMember *list[] = {&garbage[g], real};
    g_autoptr(WxForecast) fc = blend_raw(p, list, 2, NULL);
    g_assert_nonnull(fc);
    const WxBlendHour *h = hour_at(fc, T0 + 13 * H);
    ASSERT_NEAR(h->temp_c, 10.0);
    g_assert_cmpuint(h->n_members, ==, 1);
    /* the same with the garbage after the good member */
    WxMember *list2[] = {real, &garbage[g]};
    g_autoptr(WxForecast) fc2 = blend_raw(p, list2, 2, NULL);
    g_assert_nonnull(fc2);
    ASSERT_NEAR(hour_at(fc2, T0 + 13 * H)->temp_c, 10.0);
  }

  /* only garbage: not found */
  for (guint g = 0; g < G_N_ELEMENTS(garbage); g++) {
    WxMember *list[] = {&garbage[g]};
    GError *err = NULL;
    g_assert_null(blend_raw(p, list, 1, &err));
    g_assert_error(err, WX_ERROR, WX_ERROR_NOT_FOUND);
    g_clear_error(&err);
  }

  /* a member is garbage as a whole: one bad hour (out of order) drops the member */
  WxHour mixed[8];
  memcpy(mixed, hs, sizeof mixed);
  mixed[5].t_s = mixed[3].t_s;
  WxMember mm = raw_member("open-meteo", "ecmwf", mixed, 8, NULL, 0);
  WxMember *list3[] = {&mm, real};
  g_autoptr(WxForecast) c3 = blend_raw(p, list3, 2, NULL);
  ASSERT_NEAR(hour_at(c3, T0 + 13 * H)->temp_c, 10.0);

  /* hand-built out-of-range numbers in an otherwise valid member count as missing */
  WxHour partly[8];
  for (guint i = 0; i < 8; i++) {
    wx_hour_init(&partly[i]);
    partly[i].t_s = T0 + (10 + i) * H;
    partly[i].temp_c = (i == 3) ? 500.0 : 60.0; /* hour 13:00 is out of range */
    partly[i].cloud_pct = 55.0;
  }
  WxMember pm = raw_member("open-meteo", "ecmwf", partly, 8, NULL, 0);
  WxMember *list4[] = {&pm, real};
  g_autoptr(WxForecast) c4 = blend_raw(p, list4, 2, NULL);
  ASSERT_NEAR(hour_at(c4, T0 + 13 * H)->temp_c, 10.0); /* only icon's temperature counts at 13:00 */
  ASSERT_NEAR(hour_at(c4, T0 + 13 * H)->cloud_pct, 55.0);
  g_assert_cmpuint(hour_at(c4, T0 + 13 * H)->n_members, ==, 2); /* ecmwf still gave its cloud */
  ASSERT_NEAR(hour_at(c4, T0 + 14 * H)->temp_c, 60.0); /* ecmwf (3) beats icon (2.5) */

  /* NULL entries: result, members array, member */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "icon", T0 + 10 * H, 8, &good));
  WxSourceResult no_members = {(char *)"x", NULL};
  WxSourceResult with_null = {(char *)"y", g_ptr_array_new()};
  g_ptr_array_add(with_null.members, NULL);
  const WxSourceResult *list5[] = {NULL, &no_members, &with_null, g_ptr_array_index(fx->results, 0)};
  g_autoptr(WxForecast) c5 = wx_blend_forecast(p, list5, 4, NULL, 0, NOW_S, NULL);
  g_assert_nonnull(c5);
  ASSERT_NEAR(hour_at(c5, T0 + 13 * H)->temp_c, 10.0);
  g_ptr_array_free(with_null.members, TRUE);
  fx_free(fx);
}

static void
test_blend_duplicates_and_cap(void)
{
  g_autoptr(WxPlace) p = london();
  Vals a = vnone(), b = vnone();
  a.temp = 10;
  b.temp = 50;

  /* the same (source, model) twice, in one result or in two: the first one wins */
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &a));
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &b));
  fx_add(fx, "other", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &b));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->temp_c, 10.0);
  g_assert_cmpuint(hour_at(fc, T0 + 13 * H)->n_members, ==, 1);
  fx_free(fx);
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &b));
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &a));
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, NOW_S);
  ASSERT_NEAR(hour_at(c2, T0 + 13 * H)->temp_c, 50.0);
  fx_free(f2);

  /* same model of another source is a different member (met-no:ecmwf and open-meteo:ecmwf) */
  Fx *f3 = fx_new();
  fx_add(f3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &a));
  fx_add(f3, "met-no", mk_member("met-no", "ecmwf", T0 + 10 * H, 20, &b));
  g_autoptr(WxForecast) c3 = fx_blend(f3, p, NOW_S);
  g_assert_cmpuint(hour_at(c3, T0 + 13 * H)->n_members, ==, 2);
  /* ecmwf 3 vs met-no 1.5: 10 has more than half */
  ASSERT_NEAR(hour_at(c3, T0 + 13 * H)->temp_c, 10.0);
  fx_free(f3);

  /* more distinct members than WX_BLEND_MAX_MEMBERS: the first ones are used */
  Fx *f4 = fx_new();
  for (guint i = 0; i < WX_BLEND_MAX_MEMBERS + 5; i++) {
    g_autofree char *model = g_strdup_printf("m%03u", i);
    fx_add(f4, "other", mk_member("other", model, T0 + 10 * H, 10, i < WX_BLEND_MAX_MEMBERS ? &a : &b));
  }
  g_autoptr(WxForecast) c4 = fx_blend(f4, p, NOW_S);
  g_assert_cmpuint(hour_at(c4, T0 + 13 * H)->n_members, ==, WX_BLEND_MAX_MEMBERS);
  ASSERT_NEAR(hour_at(c4, T0 + 13 * H)->temp_c, 10.0);
  fx_free(f4);

  /* 128 members with distinct values: the weighted median stays defined */
  Fx *f5 = fx_new();
  for (guint i = 0; i < WX_BLEND_MAX_MEMBERS; i++) {
    g_autofree char *model = g_strdup_printf("m%03u", i);
    Vals v = vnone();
    v.temp = i * 0.5; /* 0 .. 63.5, all within the valid temperature range */
    fx_add(f5, "other", mk_member("other", model, T0 + 10 * H, 10, &v));
  }
  g_autoptr(WxForecast) c5 = fx_blend(f5, p, NOW_S);
  ASSERT_NEAR(hour_at(c5, T0 + 13 * H)->temp_c, 31.75); /* the mean of 31.5 and 32 */
  ASSERT_NEAR(hour_at(c5, T0 + 13 * H)->temp_spread_c, 63.5);
  fx_free(f5);
}

static void
test_blend_statuses_and_place(void)
{
  g_autoptr(WxPlace) p = miami();
  Vals v = vnone();
  v.temp = 10;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &v));
  const WxSourceResult *const *res = (const WxSourceResult *const *)fx->results->pdata;

  /* statuses are copied into the forecast */
  GError *err = NULL;
  WxSourceStatus *s1 = wx_source_status_new("open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                                            "https://open-meteo.com/", WX_SRC_OK, -1, 1, &err);
  g_assert_no_error(err);
  WxSourceStatus *s2 = wx_source_status_new("nws", "National Weather Service", "NOAA", "",
                                            WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0, &err);
  g_assert_no_error(err);
  WxSourceStatus both[2];
  both[0] = *s1;
  both[1] = *s2;
  g_autoptr(WxForecast) fc = wx_blend_forecast(p, res, 1, both, 2, NOW_S, &err);
  g_assert_no_error(err);
  g_assert_nonnull(fc);
  guint ns;
  const WxSourceStatus *out = wx_forecast_get_sources(fc, &ns);
  g_assert_cmpuint(ns, ==, 2);
  g_assert_cmpstr(out[0].provider_id, ==, "open-meteo");
  g_assert_cmpstr(out[1].name, ==, "National Weather Service");
  g_assert_cmpint(out[1].error_code, ==, WX_ERROR_TIMEOUT);
  g_assert_true(out[0].name != s1->name); /* deep copy */

  /* statuses that the forecast refuses give an error, not a critical */
  WxSourceStatus bad = *s1;
  bad.provider_id = (char *)"BAD ID";
  g_assert_null(wx_blend_forecast(p, res, 1, &bad, 1, NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  WxSourceStatus many[WX_FORECAST_MAX_SOURCES + 1];
  for (guint i = 0; i < G_N_ELEMENTS(many); i++)
    many[i] = *s1;
  g_assert_null(wx_blend_forecast(p, res, 1, many, G_N_ELEMENTS(many), NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  g_autoptr(WxForecast) c16 = wx_blend_forecast(p, res, 1, many, WX_FORECAST_MAX_SOURCES, NOW_S, &err);
  g_assert_no_error(err);
  g_assert_nonnull(c16);

  /* hand-built hostile places are refused by the forecast; none reads a file */
  WxPlace hostile = *p;
  hostile.timezone = (char *)"/etc/passwd";
  g_assert_null(wx_blend_forecast(&hostile, res, 1, NULL, 0, NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  hostile.timezone = NULL; /* NULL means "" for a place: accepted, the days are then UTC days */
  g_autoptr(WxForecast) no_tz = wx_blend_forecast(&hostile, res, 1, NULL, 0, NOW_S, &err);
  g_assert_no_error(err);
  g_assert_nonnull(no_tz);
  hostile = *p;
  hostile.name = (char *)"";
  g_assert_null(wx_blend_forecast(&hostile, res, 1, NULL, 0, NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);
  hostile = *p;
  hostile.lat = NAN;
  g_assert_null(wx_blend_forecast(&hostile, res, 1, NULL, 0, NOW_S, &err));
  g_assert_error(err, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&err);

  wx_source_status_free(s1);
  wx_source_status_free(s2);
  fx_free(fx);
}

static void
test_blend_criticals(void)
{
  g_autoptr(WxPlace) p = miami();
  Vals v = vnone();
  v.temp = 10;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 10 * H, 20, &v));
  const WxSourceResult *const *res = (const WxSourceResult *const *)fx->results->pdata;
  GError *err = NULL;

  ASSERT_CRITICAL("wx_blend_forecast", g_assert_null(wx_blend_forecast(NULL, res, 1, NULL, 0, NOW_S, &err)));
  ASSERT_CRITICAL("wx_blend_forecast", g_assert_null(wx_blend_forecast(p, NULL, 1, NULL, 0, NOW_S, &err)));
  ASSERT_CRITICAL("wx_blend_forecast", g_assert_null(wx_blend_forecast(p, res, 1, NULL, 1, NOW_S, &err)));
  g_assert_no_error(err);
  /* an error location that is already set is a programmer error */
  g_set_error_literal(&err, WX_ERROR, WX_ERROR_PARSE, "earlier");
  ASSERT_CRITICAL("wx_blend_forecast", g_assert_null(wx_blend_forecast(p, res, 1, NULL, 0, NOW_S, &err)));
  g_assert_error(err, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&err);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* blend: nowcast                                                           */
/* ------------------------------------------------------------------------ */

/* Per-hour precipitation of the nowcast scenarios, for the hours 12:00, 13:00 and 14:00. */
typedef struct {
  double others[3]; /* nws, nbm, ecmwf */
  double hrrr[3];   /* the HRRR member's own hourly value */
  double dflt;
} NcVals;

static void
nc_fill(WxHour *h, const double *by_hour, double dflt)
{
  gint64 hour = (h->t_s - T0) / H;
  h->temp_c = 20;
  h->cloud_pct = 50;
  h->precip_mm = (hour >= 12 && hour <= 14) ? by_hour[hour - 12] : dflt;
}

static void
nc_fill_others(WxHour *h, guint i, gpointer data)
{
  const NcVals *v = data;
  (void)i;
  nc_fill(h, v->others, v->dflt);
}

static void
nc_fill_hrrr(WxHour *h, guint i, gpointer data)
{
  const NcVals *v = data;
  (void)i;
  nc_fill(h, v->hrrr, v->dflt);
}

/* Miami with NWS, NBM, ECMWF, HRRR and the HRRR 15-minute member (quarters from @q_first). */
static Fx *
nc_fixture(const NcVals *v, gint64 q_first, const double *quarters, guint nq)
{
  Fx *fx = fx_new();
  fx_add(fx, "nws", mk_member_fn("nws", "nws", T0 + 9 * H, 40, nc_fill_others, (gpointer)v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "nbm", T0 + 9 * H, 40, nc_fill_others, (gpointer)v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "ecmwf", T0 + 9 * H, 40, nc_fill_others, (gpointer)v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "hrrr", T0 + 9 * H, 40, nc_fill_hrrr, (gpointer)v));
  WxMember *q = new_member("open-meteo", "hrrr15");
  add_quarters(q, q_first, quarters, nq);
  fx_add(fx, "open-meteo", q);
  return fx;
}

static void
assert_quarters(const WxForecast *fc, gint64 first_t, const double *want, guint n)
{
  guint nq;
  const WxQuarter *q = wx_forecast_get_quarters(fc, &nq);
  g_assert_cmpuint(nq, ==, n);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpint(q[i].t_s, ==, first_t + (gint64)i * 900);
    if (fabs(q[i].precip_mm - want[i]) > 1e-12)
      FAIL("quarter %u: got %g want %g", i, q[i].precip_mm, want[i]);
  }
}

static void
test_nowcast_override_and_rescale(void)
{
  g_autoptr(WxPlace) p = miami();
  /* now 12:07: the quarter containing now is 12:00 and the 12 quarters cover 12:00 .. 15:00, so
   * the hours 12:00, 13:00 and 14:00 are each fully covered.
   * Weights (H0, precipitation): hrrr 4, nws 2, nbm 2, ecmwf 1.
   *  12:00: others 0.2, hrrr's own 5 is replaced by the quarter sum 0.8 -> median 0.2
   *  13:00: others 0.4, quarter sum 0   -> median 0.4 (quarters all 0: spread evenly)
   *  14:00: others 0,   quarter sum 0.8 -> median 0   (quarters become 0) */
  NcVals v = {{0.2, 0.4, 0.0}, {5.0, 5.0, 0.0}, 0.1};
  double qs[12] = {0.4, 0.2, 0.2, 0.0, 0, 0, 0, 0, 0.4, 0.2, 0.2, 0.0};
  Fx *fx = nc_fixture(&v, T0 + 12 * H, qs, 12);
  gint64 now = T0 + 12 * H + 7 * 60;
  g_autoptr(WxForecast) fc = fx_blend(fx, p, now);
  ASSERT_NEAR(hour_at(fc, T0 + 12 * H)->precip_mm, 0.2);
  ASSERT_NEAR(hour_at(fc, T0 + 12 * H)->precip_mm_max, 0.8); /* max includes the override */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm, 0.4);
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm_max, 0.4);
  ASSERT_NEAR(hour_at(fc, T0 + 14 * H)->precip_mm, 0.0);
  ASSERT_NEAR(hour_at(fc, T0 + 14 * H)->precip_mm_max, 0.8);
  /* an hour that is not covered keeps the plain blend: 0.1 everywhere */
  ASSERT_NEAR(hour_at(fc, T0 + 15 * H)->precip_mm, 0.1);
  double want[12] = {0.1, 0.05, 0.05, 0.0, 0.1, 0.1, 0.1, 0.1, 0, 0, 0, 0};
  assert_quarters(fc, T0 + 12 * H, want, 12);
  /* each fully covered hour sums to its blended precipitation */
  guint nq;
  const WxQuarter *q = wx_forecast_get_quarters(fc, &nq);
  for (guint hh = 0; hh < 3; hh++) {
    double sum = q[4 * hh].precip_mm + q[4 * hh + 1].precip_mm + q[4 * hh + 2].precip_mm +
                 q[4 * hh + 3].precip_mm;
    ASSERT_NEAR(sum, hour_at(fc, T0 + (12 + (gint64)hh) * H)->precip_mm);
  }
  fx_free(fx);
}

static void
test_nowcast_partial_hours(void)
{
  g_autoptr(WxPlace) p = miami();
  /* now 12:37: the list starts at 12:30. The 12:00 hour is not covered by the member (its
   * 12:00 and 12:15 quarters do not exist) and keeps HRRR's own 5 mm; the 15:00 hour is only
   * half in the 12 quarters; the 13:00 and 14:00 hours are fully covered. */
  NcVals v = {{0.1, 0.2, 0.4}, {5.0, 5.0, 0.0}, 0.1};
  double qs[12] = {0.1, 0.1, 0.2, 0.2, 0.2, 0.2, 0, 0, 0, 0, 0.3, 0.3};
  Fx *fx = nc_fixture(&v, T0 + 12 * H + 1800, qs, 12);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  ASSERT_NEAR(hour_at(fc, T0 + 12 * H)->precip_mm_max, 5.0);
  /* 13:00: quarters sum 0.8 against others 0.2 -> 0.2 (see the previous test); 14:00 -> 0.4 */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm, 0.2);
  ASSERT_NEAR(hour_at(fc, T0 + 14 * H)->precip_mm, 0.4);
  double want[12] = {0.1, 0.1, 0.05, 0.05, 0.05, 0.05, 0.1, 0.1, 0.1, 0.1, 0.3, 0.3};
  assert_quarters(fc, T0 + 12 * H + 1800, want, 12);
  fx_free(fx);
}

/* Number of nowcast quarters of Miami with ECMWF 0.8 mm/h plus a quarter-only HRRR 15 member. */
static guint
nc_count(gint64 now, gint64 q_first, const double *quarters, guint nq, const char *src, const char *model,
         gint64 *first_out)
{
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 0.8;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  WxMember *q = new_member(src, model);
  add_quarters(q, q_first, quarters, nq);
  fx_add(fx, src, q);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, now);
  guint n;
  const WxQuarter *out = wx_forecast_get_quarters(fc, &n);
  if (first_out != NULL && n > 0)
    *first_out = out[0].t_s;
  fx_free(fx);
  return n;
}

static void
test_nowcast_coverage_rules(void)
{
  double z[24];
  for (guint i = 0; i < 24; i++)
    z[i] = 0.1;
  gint64 first = 0;
  gint64 q1230 = T0 + 12 * H + 1800;

  /* quarter 12:30 contains now (12:37); the run must end at or after now + 30 min = 13:07 */
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 3, "open-meteo", "hrrr15", &first), ==, 3);
  g_assert_cmpint(first, ==, q1230);
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 2, "open-meteo", "hrrr15", NULL), ==, 0); /* ends 13:00 */
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 1, "open-meteo", "hrrr15", NULL), ==, 0);
  /* boundary: now 12:30:00, run ends exactly at now + 30 min */
  g_assert_cmpuint(nc_count(q1230, q1230, z, 2, "open-meteo", "hrrr15", NULL), ==, 2);
  g_assert_cmpuint(nc_count(q1230, q1230, z, 1, "open-meteo", "hrrr15", NULL), ==, 0);
  /* now 12:44:59 is still the 12:30 quarter */
  g_assert_cmpuint(nc_count(q1230 + 899, q1230, z, 3, "open-meteo", "hrrr15", NULL), ==, 3);
  /* the quarter containing now is missing: first quarter starts after now */
  g_assert_cmpuint(nc_count(NOW_S, q1230 + 900, z, 4, "open-meteo", "hrrr15", NULL), ==, 0);
  /* quarters before the one containing now are not part of the list */
  g_assert_cmpuint(nc_count(NOW_S, q1230 - 900, z, 4, "open-meteo", "hrrr15", &first), ==, 3);
  g_assert_cmpint(first, ==, q1230);
  /* the run is cut at the 12 quarter limit */
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 20, "open-meteo", "hrrr15", NULL), ==, WX_BLEND_MAX_QUARTERS);
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 13, "open-meteo", "hrrr15", NULL), ==, WX_BLEND_MAX_QUARTERS);
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 12, "open-meteo", "hrrr15", NULL), ==, 12);
  /* only the HRRR 15-minute member of open-meteo is a nowcast */
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 6, "met-no", "hrrr15", NULL), ==, 0);
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 6, "open-meteo", "hrrr", NULL), ==, 0);
  g_assert_cmpuint(nc_count(NOW_S, q1230, z, 6, "open-meteo", "gfs", NULL), ==, 0);

  /* an interior gap cuts the run; it must still reach now + 30 min */
  WxMember *gap = new_member("open-meteo", "hrrr15");
  WxQuarter a = {q1230, 0.1}, b = {q1230 + 900, 0.1}, c = {q1230 + 1800, 0.1}, d = {q1230 + 2700 + 900, 0.1};
  g_assert_true(wx_member_add_quarter(gap, &a));
  g_assert_true(wx_member_add_quarter(gap, &b));
  g_assert_true(wx_member_add_quarter(gap, &c));
  g_assert_true(wx_member_add_quarter(gap, &d));
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 0.8;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  fx_add(fx, "open-meteo", gap);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  wx_forecast_get_quarters(fc, &n);
  g_assert_cmpuint(n, ==, 3);
  fx_free(fx);
  WxMember *gap2 = new_member("open-meteo", "hrrr15");
  WxQuarter e = {q1230, 0.1}, f = {q1230 + 1800, 0.1};
  g_assert_true(wx_member_add_quarter(gap2, &e));
  g_assert_true(wx_member_add_quarter(gap2, &f));
  Fx *fx2 = fx_new();
  fx_add(fx2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  fx_add(fx2, "open-meteo", gap2);
  g_autoptr(WxForecast) fc2 = fx_blend(fx2, p, NOW_S);
  wx_forecast_get_quarters(fc2, &n);
  g_assert_cmpuint(n, ==, 0); /* run of one quarter ends 12:45 < 13:07 */
  fx_free(fx2);

  /* a member without quarters, and without any data, is no nowcast */
  Fx *fx3 = fx_new();
  fx_add(fx3, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  fx_add(fx3, "open-meteo", new_member("open-meteo", "hrrr15"));
  g_autoptr(WxForecast) fc3 = fx_blend(fx3, p, NOW_S);
  wx_forecast_get_quarters(fc3, &n);
  g_assert_cmpuint(n, ==, 0);
  fx_free(fx3);
}

static void
test_nowcast_without_hrrr_hours(void)
{
  /* ECMWF alone has 0.8 mm per hour; the quarters of every covered hour are scaled to it */
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 0.8;
  double qs[12];
  for (guint i = 0; i < 12; i++)
    qs[i] = 0.1;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  WxMember *q = new_member("open-meteo", "hrrr15");
  add_quarters(q, T0 + 12 * H, qs, 12);
  fx_add(fx, "open-meteo", q);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, T0 + 12 * H + 7 * 60);
  double want[12];
  for (guint i = 0; i < 12; i++)
    want[i] = 0.2;
  assert_quarters(fc, T0 + 12 * H, want, 12);
  /* HRRR 15 never votes by itself: the hour values are ECMWF's */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm, 0.8);
  g_assert_cmpuint(hour_at(fc, T0 + 13 * H)->n_members, ==, 1);
  fx_free(fx);

  /* no data of other members for those hours: the blended precipitation is unknown, the
   * quarters keep their raw amounts */
  Vals t = vnone();
  t.temp = 20; /* temperature only */
  Fx *f2 = fx_new();
  fx_add(f2, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &t));
  WxMember *q2 = new_member("open-meteo", "hrrr15");
  add_quarters(q2, T0 + 12 * H, qs, 12);
  fx_add(f2, "open-meteo", q2);
  g_autoptr(WxForecast) c2 = fx_blend(f2, p, T0 + 12 * H + 7 * 60);
  ASSERT_NAN(hour_at(c2, T0 + 13 * H)->precip_mm);
  assert_quarters(c2, T0 + 12 * H, qs, 12);
  fx_free(f2);
}

static void
test_nowcast_garbage_quarters(void)
{
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 0.8;
  g_autoptr(WxMember) real = mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec);
  gint64 q0 = T0 + 12 * H;
  WxQuarter ok[4] = {{q0, 0.1}, {q0 + 900, 0.1}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}};
  WxQuarter desc[4] = {{q0 + 2700, 0.1}, {q0 + 1800, 0.1}, {q0 + 900, 0.1}, {q0, 0.1}};
  WxQuarter misaligned[4] = {{q0 + 1, 0.1}, {q0 + 901, 0.1}, {q0 + 1801, 0.1}, {q0 + 2701, 0.1}};
  WxQuarter nan_amount[4] = {{q0, 0.1}, {q0 + 900, NAN}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}};
  WxQuarter negative[4] = {{q0, 0.1}, {q0 + 900, -0.1}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}};
  WxQuarter huge[4] = {{q0, 0.1}, {q0 + 900, 501.0}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}};
  WxQuarter out_of_range[4] = {{0, 0.1}, {900, 0.1}, {1800, 0.1}, {2700, 0.1}};
  gint64 now = q0 + 7 * 60;

  struct {
    WxMember m;
    guint expect;
  } cases[] = {
    {raw_member("open-meteo", "hrrr15", NULL, 0, ok, 4), 4},          /* control: valid */
    {raw_member("open-meteo", "hrrr15", NULL, 0, desc, 4), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, misaligned, 4), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, nan_amount, 4), 0},  /* run of one quarter: too short */
    {raw_member("open-meteo", "hrrr15", NULL, 0, negative, 4), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, huge, 4), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, out_of_range, 4), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, NULL, 4), 0},        /* count without array */
    {raw_member("open-meteo", "hrrr15", NULL, 0, ok, WX_MEMBER_MAX_QUARTERS + 1), 0},
    {raw_member("open-meteo", "hrrr15", NULL, 0, ok, 0), 0},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    WxMember *list[] = {real, &cases[i].m};
    g_autoptr(WxForecast) fc = NULL;
    GError *err = NULL;
    WxSourceResult r = {(char *)"raw", g_ptr_array_new()};
    g_ptr_array_add(r.members, list[0]);
    g_ptr_array_add(r.members, list[1]);
    const WxSourceResult *res[] = {&r};
    fc = wx_blend_forecast(p, res, 1, NULL, 0, now, &err);
    g_assert_no_error(err);
    g_assert_nonnull(fc);
    guint n;
    wx_forecast_get_quarters(fc, &n);
    if (n != cases[i].expect)
      FAIL("case %u: %u quarters, wanted %u", i, n, cases[i].expect);
    g_ptr_array_free(r.members, TRUE);
  }
}

static void
test_nowcast_hour_sums_validity(void)
{
  g_autoptr(WxPlace) p = miami();
  /* quarters 12:00 .. 14:45, all 0.2 mm, except: the 13:00 hour sums to 1600 mm (each quarter is
   * valid, the sum is not an hourly amount) and the 14:30 quarter is unknown (NAN). */
  NcVals v = {{0.2, 0.2, 0.2}, {5.0, 5.0, 5.0}, 0.1};
  g_autoptr(WxMember) nws = mk_member_fn("nws", "nws", T0 + 9 * H, 40, nc_fill_others, &v);
  g_autoptr(WxMember) nbm = mk_member_fn("open-meteo", "nbm", T0 + 9 * H, 40, nc_fill_others, &v);
  g_autoptr(WxMember) ec = mk_member_fn("open-meteo", "ecmwf", T0 + 9 * H, 40, nc_fill_others, &v);
  g_autoptr(WxMember) hrrr = mk_member_fn("open-meteo", "hrrr", T0 + 9 * H, 40, nc_fill_hrrr, &v);
  /* four quarters of 10:00 (before the first blended hour, 11:00) come first, then the others */
  WxQuarter qs[16];
  for (guint i = 0; i < 16; i++) {
    gint64 first = (i < 4) ? T0 + 10 * H : T0 + 12 * H - 4 * 900;
    qs[i].t_s = first + (gint64)i * 900;
    qs[i].precip_mm = (i >= 8 && i < 12) ? 400.0 : 0.2;
  }
  qs[14].precip_mm = NAN;
  WxMember q15 = raw_member("open-meteo", "hrrr15", NULL, 0, qs, 16);
  WxMember *list[] = {nws, nbm, ec, hrrr, &q15};
  GError *err = NULL;
  g_autoptr(WxForecast) fc = blend_raw_at(p, list, 5, T0 + 12 * H + 7 * 60, &err);
  g_assert_no_error(err);
  g_assert_nonnull(fc);
  /* 12:00 is overridden by 0.8; 13:00 and 14:00 keep HRRR's own 5 */
  ASSERT_NEAR(hour_at(fc, T0 + 12 * H)->precip_mm_max, 0.8);
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm_max, 5.0);
  ASSERT_NEAR(hour_at(fc, T0 + 14 * H)->precip_mm_max, 5.0);
  /* the run stops before the unknown quarter: ten quarters; the hours 12:00 and 13:00 are
   * rescaled to their blended 0.2 mm, the last two quarters (half of 14:00) stay as they are */
  double want[10] = {0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.2, 0.2};
  assert_quarters(fc, T0 + 12 * H, want, 10);
}

static void
test_nowcast_hrrr_without_hour(void)
{
  /* the override only replaces an hour the HRRR member has: its hours start at 14:00 */
  g_autoptr(WxPlace) p = miami();
  NcVals v = {{0.2, 0.2, 0.2}, {5.0, 5.0, 5.0}, 0.1};
  Fx *fx = fx_new();
  fx_add(fx, "nws", mk_member_fn("nws", "nws", T0 + 9 * H, 40, nc_fill_others, &v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "nbm", T0 + 9 * H, 40, nc_fill_others, &v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "ecmwf", T0 + 9 * H, 40, nc_fill_others, &v));
  fx_add(fx, "open-meteo", mk_member_fn("open-meteo", "hrrr", T0 + 14 * H, 20, nc_fill_hrrr, &v));
  double qs[12];
  for (guint i = 0; i < 12; i++)
    qs[i] = 0.2;
  WxMember *q = new_member("open-meteo", "hrrr15");
  add_quarters(q, T0 + 12 * H, qs, 12);
  fx_add(fx, "open-meteo", q);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, T0 + 12 * H + 7 * 60);
  ASSERT_NEAR(hour_at(fc, T0 + 12 * H)->precip_mm_max, 0.2); /* no HRRR hour, no override */
  ASSERT_NEAR(hour_at(fc, T0 + 13 * H)->precip_mm_max, 0.2);
  ASSERT_NEAR(hour_at(fc, T0 + 14 * H)->precip_mm_max, 0.8); /* HRRR's 5 mm replaced by 0.8 */
  double want[12];
  for (guint i = 0; i < 12; i++)
    want[i] = 0.05; /* every hour blends to 0.2 mm */
  assert_quarters(fc, T0 + 12 * H, want, 12);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* wx_forecast_now                                                          */
/* ------------------------------------------------------------------------ */

static WxBlendHour
bh(gint64 t_s, double temp, double precip, double prob, double cloud, WxCondition cond, gboolean is_day,
   guint8 n_members)
{
  WxBlendHour b;
  memset(&b, 0, sizeof b);
  b.t_s = t_s;
  b.temp_c = temp;
  b.feels_c = temp;
  b.precip_mm = precip;
  b.precip_mm_max = precip;
  b.precip_prob = prob;
  b.cloud_pct = cloud;
  b.wind_kmh = NAN;
  b.gust_kmh = NAN;
  b.humidity_pct = NAN;
  b.temp_spread_c = NAN;
  b.n_members = n_members;
  b.condition = cond;
  b.is_day = is_day;
  return b;
}

static WxForecast *
make_forecast(const WxPlace *p, const WxBlendHour *hours, guint n, const WxQuarter *q, guint nq)
{
  GError *err = NULL;
  WxForecast *fc = wx_forecast_new(p, NOW_S, hours, n, q, nq, NULL, 0, NULL, 0, &err);
  g_assert_no_error(err);
  g_assert_nonnull(fc);
  return fc;
}

static void
test_forecast_now(void)
{
  g_autoptr(WxPlace) p = london();
  WxBlendHour hs[4];
  hs[0] = bh(T0 + 10 * H, 10, 0.5, 30, 20, WX_COND_CLEAR, FALSE, 3);
  hs[1] = bh(T0 + 11 * H, 20, 1.5, 60, 80, WX_COND_RAIN, TRUE, 4);
  hs[2] = bh(T0 + 12 * H, NAN, 2.5, 70, NAN, WX_COND_OVERCAST, TRUE, 5);
  hs[3] = bh(T0 + 14 * H, 40, 3.5, 80, 40, WX_COND_SNOW, TRUE, 6); /* 13:00 is missing */
  hs[0].wind_kmh = 10;
  hs[1].wind_kmh = 20;
  hs[0].gust_kmh = 30;
  hs[1].gust_kmh = 40;
  hs[0].humidity_pct = 50;
  hs[1].humidity_pct = 90;
  hs[0].feels_c = 5;
  hs[1].feels_c = 15;
  g_autoptr(WxForecast) fc = make_forecast(p, hs, 4, NULL, 0);

  WxBlendHour out;
  /* at the start of a bucket: its own values */
  g_assert_true(wx_forecast_now(fc, T0 + 10 * H, &out));
  ASSERT_NEAR(out.temp_c, 10.0);
  g_assert_cmpint(out.t_s, ==, T0 + 10 * H);
  /* a quarter of the way: linear between 10:00 and 11:00 */
  gint64 now = T0 + 10 * H + 900;
  g_assert_true(wx_forecast_now(fc, now, &out));
  g_assert_cmpint(out.t_s, ==, now);
  ASSERT_NEAR(out.temp_c, 12.5);
  ASSERT_NEAR(out.feels_c, 7.5);
  ASSERT_NEAR(out.wind_kmh, 12.5);
  ASSERT_NEAR(out.gust_kmh, 32.5);
  ASSERT_NEAR(out.humidity_pct, 60.0);
  ASSERT_NEAR(out.cloud_pct, 35.0);
  /* the other fields are those of the bucket containing now */
  ASSERT_NEAR(out.precip_mm, 0.5);
  ASSERT_NEAR(out.precip_mm_max, 0.5);
  ASSERT_NEAR(out.precip_prob, 30.0);
  g_assert_cmpuint(out.n_members, ==, 3);
  /* a sky class follows the cloud cover of the result (35 % is "mostly clear", the bucket's own
   * 20 % was "clear"): one cloud value for the word and the number */
  g_assert_cmpint(out.condition, ==, WX_COND_MOSTLY_CLEAR);
  g_assert_cmpint(out.condition, ==, wx_cloud_condition(out.cloud_pct));
  g_assert_cmpint(out.is_day, ==, wx_sun_is_up(51.5074, -0.1278, now));
  /* one second before the end of the bucket: nearly the next value */
  g_assert_true(wx_forecast_now(fc, T0 + 11 * H - 1, &out));
  g_assert_cmpfloat_with_epsilon(out.temp_c, 20.0, 0.01);
  g_assert_cmpfloat(out.temp_c, <=, 20.0);
  /* a missing value on one side: the other side is used */
  g_assert_true(wx_forecast_now(fc, T0 + 11 * H + 1800, &out));
  ASSERT_NEAR(out.temp_c, 20.0); /* 11:00 has 20, 12:00 has NAN */
  ASSERT_NEAR(out.wind_kmh, 20.0); /* 11:00 has 20, 12:00 has none */
  g_assert_true(wx_forecast_now(fc, T0 + 12 * H + 1800, &out));
  /* 12:00 has no temperature and there is no contiguous next bucket (13:00 is missing) */
  ASSERT_NAN(out.temp_c);
  ASSERT_NAN(out.wind_kmh); /* both sides unknown */
  /* no bucket contains now */
  WxBlendHour sentinel;
  memset(&sentinel, 0x5a, sizeof sentinel);
  out = sentinel;
  g_assert_false(wx_forecast_now(fc, T0 + 13 * H + 10, &out)); /* in the gap */
  g_assert_false(wx_forecast_now(fc, T0 + 9 * H + 3599, &out));
  g_assert_false(wx_forecast_now(fc, T0 + 15 * H, &out));
  g_assert_false(wx_forecast_now(fc, G_MAXINT64, &out));
  g_assert_false(wx_forecast_now(fc, G_MININT64, &out));
  g_assert_cmpint(memcmp(&out, &sentinel, sizeof out), ==, 0);
  /* the last bucket has no successor: its own values */
  g_assert_true(wx_forecast_now(fc, T0 + 14 * H + 1800, &out));
  ASSERT_NEAR(out.temp_c, 40.0);
  g_assert_cmpuint(out.n_members, ==, 6);
  g_assert_cmpint(out.condition, ==, WX_COND_SNOW);
  /* the very end of the last bucket */
  g_assert_true(wx_forecast_now(fc, T0 + 15 * H - 1, &out));
  g_assert_false(wx_forecast_now(fc, T0 + 15 * H, &out));

  ASSERT_CRITICAL("wx_forecast_now", g_assert_false(wx_forecast_now(NULL, now, &out)));
  ASSERT_CRITICAL("wx_forecast_now", g_assert_false(wx_forecast_now(fc, now, NULL)));

  /* an empty forecast has no current bucket */
  g_autoptr(WxForecast) empty = make_forecast(p, NULL, 0, NULL, 0);
  g_assert_false(wx_forecast_now(empty, now, &out));

  /* only the following bucket has a value: it is used (nothing to interpolate with) */
  WxBlendHour pair[2];
  pair[0] = bh(T0 + 10 * H, NAN, 0.5, 30, 20, WX_COND_CLEAR, FALSE, 1);
  pair[1] = bh(T0 + 11 * H, 20, 1.5, 60, 80, WX_COND_RAIN, TRUE, 1);
  g_autoptr(WxForecast) f2 = make_forecast(p, pair, 2, NULL, 0);
  g_assert_true(wx_forecast_now(f2, T0 + 10 * H + 1800, &out));
  ASSERT_NEAR(out.temp_c, 20.0);
  ASSERT_NEAR(out.cloud_pct, 50.0);
}

/* The condition word of the current conditions comes from the same cloud value as the cover that
 * is shown: 10:00 is 55 % (partly cloudy) and 11:00 70 % (mostly cloudy); at 10:36 the cover is
 * 64 % and the word must be "mostly cloudy", not the bucket's "partly cloudy". */
static void
test_forecast_now_condition_follows_cloud(void)
{
  g_autoptr(WxPlace) p = miami();
  WxBlendHour hs[2];
  hs[0] = bh(T0 + 10 * H, 28.9, 0.0, 10, 55, WX_COND_PARTLY_CLOUDY, TRUE, 2);
  hs[1] = bh(T0 + 11 * H, 29.4, 0.0, 10, 70, WX_COND_MOSTLY_CLOUDY, TRUE, 2);
  g_autoptr(WxForecast) fc = make_forecast(p, hs, 2, NULL, 0);
  WxBlendHour out;
  g_assert_true(wx_forecast_now(fc, T0 + 10 * H + 36 * 60, &out));
  ASSERT_NEAR(out.cloud_pct, 55.0 + 15.0 * 0.6);
  g_assert_cmpint(out.condition, ==, WX_COND_MOSTLY_CLOUDY);
  g_assert_cmpstr(wx_condition_label(out.condition), ==, wx_cloud_label(out.cloud_pct));
  ASSERT_NEAR(out.temp_c, 28.9 + 0.5 * 0.6);
  g_assert_true(wx_forecast_now(fc, T0 + 10 * H + 24 * 60, &out)); /* 61 %: still partly cloudy */
  g_assert_cmpint(out.condition, ==, WX_COND_PARTLY_CLOUDY);

  /* every second of the hour, for sky classes of the bucket and an unknown one: the condition is
   * the class of the cloud cover, whatever the bucket's own class says */
  static const WxCondition sky[] = {WX_COND_UNKNOWN, WX_COND_CLEAR, WX_COND_MOSTLY_CLEAR,
                                    WX_COND_PARTLY_CLOUDY, WX_COND_MOSTLY_CLOUDY, WX_COND_OVERCAST};
  static const double clouds[][2] = {{0, 100}, {100, 0}, {12, 13}, {37, 38}, {62, 63}, {87, 88},
                                     {10, NAN}, {NAN, 90}, {50, 50}, {0, 0}, {100, 100}};
  for (guint c = 0; c < G_N_ELEMENTS(sky); c++) {
    for (guint k = 0; k < G_N_ELEMENTS(clouds); k++) {
      hs[0] = bh(T0 + 10 * H, 20, 0.0, 10, clouds[k][0], sky[c], TRUE, 1);
      hs[1] = bh(T0 + 11 * H, 20, 0.0, 10, clouds[k][1], WX_COND_OVERCAST, TRUE, 1);
      g_autoptr(WxForecast) f = make_forecast(p, hs, 2, NULL, 0);
      for (gint s = 0; s < H; s += 37) {
        g_assert_true(wx_forecast_now(f, T0 + 10 * H + s, &out));
        g_assert_cmpint(out.condition, ==, wx_cloud_condition(out.cloud_pct));
      }
      g_assert_true(wx_forecast_now(f, T0 + 10 * H + H - 1, &out));
      g_assert_cmpint(out.condition, ==, wx_cloud_condition(out.cloud_pct));
    }
  }

  /* a precipitation, fog or severe class of the bucket is kept, whatever the cloud cover */
  static const WxCondition kept[] = {WX_COND_FOG, WX_COND_DRIZZLE, WX_COND_LIGHT_RAIN, WX_COND_RAIN,
                                     WX_COND_HEAVY_RAIN, WX_COND_SHOWERS, WX_COND_THUNDERSTORM,
                                     WX_COND_SNOW, WX_COND_SLEET};
  for (guint c = 0; c < G_N_ELEMENTS(kept); c++) {
    hs[0] = bh(T0 + 10 * H, 20, 1.0, 80, 20, kept[c], TRUE, 1);
    hs[1] = bh(T0 + 11 * H, 20, 0.0, 10, 90, WX_COND_OVERCAST, TRUE, 1);
    g_autoptr(WxForecast) f = make_forecast(p, hs, 2, NULL, 0);
    g_assert_true(wx_forecast_now(f, T0 + 10 * H + 1800, &out));
    g_assert_cmpint(out.condition, ==, kept[c]);
  }

  /* no cloud value at all: nothing to derive a class from, the bucket's class stays */
  hs[0] = bh(T0 + 10 * H, 20, 0.0, 10, NAN, WX_COND_OVERCAST, TRUE, 1);
  hs[1] = bh(T0 + 11 * H, 20, 0.0, 10, NAN, WX_COND_CLEAR, TRUE, 1);
  g_autoptr(WxForecast) nan_f = make_forecast(p, hs, 2, NULL, 0);
  g_assert_true(wx_forecast_now(nan_f, T0 + 10 * H + 1800, &out));
  ASSERT_NAN(out.cloud_pct);
  g_assert_cmpint(out.condition, ==, WX_COND_OVERCAST);
}

/* ------------------------------------------------------------------------ */
/* rain outlook                                                             */
/* ------------------------------------------------------------------------ */

/* Rain forecasts have the hours 11:00 .. 70:00 (60 hours), initially dry with a 10 % chance. */
#define RFIRST 11
#define RN 60
#define RH(a, h) ((a)[(h) - RFIRST])

static WxBlendHour *
rain_hours(void)
{
  WxBlendHour *a = g_new(WxBlendHour, RN);
  for (int i = 0; i < RN; i++)
    a[i] = bh(T0 + (RFIRST + i) * H, 20, 0.0, 10, 50, WX_COND_PARTLY_CLOUDY, TRUE, 1);
  return a;
}

/* Makes the hours [from, to) wet. */
static void
set_wet(WxBlendHour *a, int from, int to, double mm, double prob)
{
  for (int h = from; h < to; h++) {
    RH(a, h).precip_mm = mm;
    RH(a, h).precip_prob = prob;
  }
}

static WxRainOutlook
outlook_of(const WxBlendHour *hrs, guint n, const WxQuarter *q, guint nq, gint64 now)
{
  g_autoptr(WxPlace) p = london();
  g_autoptr(WxForecast) fc = make_forecast(p, hrs, n, q, nq);
  WxRainOutlook o;
  memset(&o, 0xAB, sizeof o);
  wx_rain_outlook(fc, now, &o);
  return o;
}

static void
assert_outlook(const WxRainOutlook *o, WxRainState state, gint64 start, gint64 end, gboolean known,
               gint64 peak_s, double peak_mm, double peak_prob)
{
  g_assert_cmpint(o->state, ==, state);
  g_assert_cmpint(o->start_s, ==, start);
  g_assert_cmpint(o->end_s, ==, end);
  g_assert_cmpint(o->ends_known, ==, known);
  g_assert_cmpint(o->peak_s, ==, peak_s);
  ASSERT_NEAR(o->peak_mm_h, peak_mm);
  if (isnan(peak_prob))
    ASSERT_NAN(o->peak_prob);
  else
    ASSERT_NEAR(o->peak_prob, peak_prob);
}

static void
assert_dry(const WxRainOutlook *o)
{
  assert_outlook(o, WX_RAIN_DRY, 0, 0, FALSE, 0, 0.0, 0.0);
}

static void
test_rain_dry_and_possible(void)
{
  g_autofree WxBlendHour *a = rain_hours();
  WxRainOutlook o = outlook_of(a, RN, NULL, 0, NOW_S);
  assert_dry(&o);

  /* 39.99 % is not enough, 40 % is */
  RH(a, 20).precip_prob = 39.99;
  o = outlook_of(a, RN, NULL, 0, NOW_S);
  assert_dry(&o);
  RH(a, 20).precip_prob = 40.0;
  o = outlook_of(a, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 20 * H, 0.0, 40.0);

  /* the highest probability, the first of equal ones; its own precipitation is reported */
  RH(a, 20).precip_prob = 45.0;
  RH(a, 22).precip_prob = 60.0;
  RH(a, 22).precip_mm = 0.05; /* below 0.1 mm: not wet */
  RH(a, 23).precip_prob = 60.0;
  o = outlook_of(a, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 22 * H, 0.05, 60.0);
  /* an unknown amount is reported as 0 */
  RH(a, 22).precip_mm = NAN;
  o = outlook_of(a, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 22 * H, 0.0, 60.0);
  /* unknown probabilities never qualify */
  g_autofree WxBlendHour *b = rain_hours();
  for (int h = RFIRST; h < RFIRST + RN; h++)
    RH(b, h).precip_prob = NAN;
  o = outlook_of(b, RN, NULL, 0, NOW_S);
  assert_dry(&o);

  /* only hours that end after now and start before now + 48 h count */
  g_autofree WxBlendHour *c = rain_hours();
  RH(c, 11).precip_prob = 90; /* 11:00 .. 12:00 ends before now */
  o = outlook_of(c, RN, NULL, 0, NOW_S);
  assert_dry(&o);
  RH(c, 12).precip_prob = 90; /* the hour containing now */
  o = outlook_of(c, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 12 * H, 0.0, 90.0);
  g_autofree WxBlendHour *d = rain_hours();
  RH(d, 61).precip_prob = 90; /* starts at 61:00, after now + 48 h = 60:37 */
  o = outlook_of(d, RN, NULL, 0, NOW_S);
  assert_dry(&o);
  RH(d, 60).precip_prob = 90; /* starts 60:00 < 60:37 */
  o = outlook_of(d, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 60 * H, 0.0, 90.0);
  /* with now on the hour the horizon is exactly 60:00: that hour no longer counts */
  o = outlook_of(d, RN, NULL, 0, T0 + 12 * H);
  assert_dry(&o); /* the hours 60 and 61 start at or after the horizon */
}

static void
test_rain_now(void)
{
  g_autofree WxBlendHour *a = rain_hours();
  set_wet(a, 11, 14, 0.5, 60);
  RH(a, 12).precip_prob = 70;
  RH(a, 13).precip_mm = 1.2;
  WxRainOutlook o = outlook_of(a, RN, NULL, 0, NOW_S);
  /* the run began in the past (11:00), ends at 14:00; the peak is over the whole run */
  assert_outlook(&o, WX_RAIN_NOW, T0 + 11 * H, T0 + 14 * H, TRUE, T0 + 13 * H, 1.2, 70.0);

  /* a run that starts exactly at the beginning of the hour containing now */
  g_autofree WxBlendHour *b = rain_hours();
  set_wet(b, 12, 13, 0.8, 50);
  o = outlook_of(b, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, T0 + 13 * H, TRUE, T0 + 12 * H, 0.8, 50.0);
  /* the instant the hour starts, and its last second */
  o = outlook_of(b, RN, NULL, 0, T0 + 12 * H);
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);
  o = outlook_of(b, RN, NULL, 0, T0 + 13 * H - 1);
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);
  o = outlook_of(b, RN, NULL, 0, T0 + 13 * H); /* now the hour is over: dry (hour 13 is dry) */
  assert_dry(&o);

  /* the data ends while it rains: the end is unknown */
  g_autofree WxBlendHour *c = rain_hours();
  set_wet(c, 11, 21, 0.5, 60); /* the forecast has the hours 11 .. 20 only (below) */
  o = outlook_of(c, 10, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 11 * H, 0, FALSE, T0 + 11 * H, 0.5, 60.0);

  /* wet all the way past the 48 h horizon */
  g_autofree WxBlendHour *d = rain_hours();
  set_wet(d, 11, 71, 0.5, 60);
  o = outlook_of(d, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 11 * H, 0, FALSE, T0 + 11 * H, 0.5, 60.0);

  /* wet through 60:00 and dry from 61:00: the hour 60:00 starts inside the horizon (60:37 is
   * its end) but the first dry sample would start after it: unknown. Dry from 60:00: the dry
   * sample starts inside the horizon, so the end is known. */
  g_autofree WxBlendHour *e = rain_hours();
  set_wet(e, 12, 61, 0.5, 60);
  o = outlook_of(e, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, 0, FALSE, T0 + 12 * H, 0.5, 60.0);
  g_autofree WxBlendHour *f = rain_hours();
  set_wet(f, 12, 60, 0.5, 60);
  o = outlook_of(f, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, T0 + 60 * H, TRUE, T0 + 12 * H, 0.5, 60.0);
}

static void
test_rain_expected(void)
{
  g_autofree WxBlendHour *a = rain_hours();
  set_wet(a, 16, 18, 0.3, 40);
  RH(a, 17).precip_mm = 0.9;
  set_wet(a, 22, 23, 0.5, 50);
  WxRainOutlook o = outlook_of(a, RN, NULL, 0, NOW_S);
  /* the first run only */
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 16 * H, T0 + 18 * H, TRUE, T0 + 17 * H, 0.9, 40.0);

  /* the next hour */
  g_autofree WxBlendHour *b = rain_hours();
  set_wet(b, 13, 14, 0.4, 35);
  o = outlook_of(b, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 13 * H, T0 + 14 * H, TRUE, T0 + 13 * H, 0.4, 35.0);

  /* starting inside the horizon, running past it */
  g_autofree WxBlendHour *c = rain_hours();
  set_wet(c, 59, 71, 0.4, 60);
  o = outlook_of(c, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 59 * H, 0, FALSE, T0 + 59 * H, 0.4, 60.0);
  /* starting at 60:00 (inside 60:37) counts; at 61:00 it does not */
  g_autofree WxBlendHour *d = rain_hours();
  set_wet(d, 60, 61, 0.4, 60);
  o = outlook_of(d, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 60 * H, 0, FALSE, T0 + 60 * H, 0.4, 60.0);
  g_autofree WxBlendHour *e = rain_hours();
  set_wet(e, 61, 62, 0.4, 60);
  o = outlook_of(e, RN, NULL, 0, NOW_S);
  assert_dry(&o); /* 60 % at 61:00 is beyond the horizon, so not even "possible" */
  /* with now on the hour the horizon is exactly 60:00 */
  g_autofree WxBlendHour *f = rain_hours();
  set_wet(f, 60, 61, 0.4, 60);
  o = outlook_of(f, RN, NULL, 0, T0 + 12 * H);
  assert_dry(&o);
  set_wet(f, 59, 60, 0.4, 60);
  o = outlook_of(f, RN, NULL, 0, T0 + 12 * H);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 59 * H, 0, FALSE, T0 + 59 * H, 0.4, 60.0);

  /* a wet run in the past does not make "expected" */
  g_autofree WxBlendHour *g = rain_hours();
  set_wet(g, 11, 12, 0.5, 60);
  o = outlook_of(g, RN, NULL, 0, NOW_S);
  g_assert_cmpint(o.state, !=, WX_RAIN_EXPECTED);
  g_assert_cmpint(o.state, !=, WX_RAIN_NOW);
}

static void
test_rain_wet_thresholds(void)
{
  /* wet hour: >= 0.1 mm and (probability unknown or >= 30 %) */
  struct {
    double mm, prob;
    WxRainState state;
  } cases[] = {
    {0.1, 30.0, WX_RAIN_EXPECTED}, {0.1, 29.99, WX_RAIN_DRY},  {1.0, 29.9, WX_RAIN_DRY},
    {0.1, NAN, WX_RAIN_EXPECTED},  {0.0999, 90.0, WX_RAIN_POSSIBLE}, {5.0, 100.0, WX_RAIN_EXPECTED},
    {0.0999, NAN, WX_RAIN_DRY},    {NAN, 90.0, WX_RAIN_POSSIBLE}, {NAN, NAN, WX_RAIN_DRY},
    {0.0, 40.0, WX_RAIN_POSSIBLE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autofree WxBlendHour *a = rain_hours();
    RH(a, 16).precip_mm = cases[i].mm;
    RH(a, 16).precip_prob = cases[i].prob;
    WxRainOutlook o = outlook_of(a, RN, NULL, 0, NOW_S);
    if (o.state != cases[i].state)
      FAIL("case %u: state %d, wanted %d", i, o.state, cases[i].state);
  }
  /* an unknown probability on a wet hour leaves peak_prob unknown */
  g_autofree WxBlendHour *b = rain_hours();
  RH(b, 16).precip_mm = 0.3;
  RH(b, 16).precip_prob = NAN;
  WxRainOutlook o = outlook_of(b, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 16 * H, T0 + 17 * H, TRUE, T0 + 16 * H, 0.3, NAN);
  /* a peak with the same rate: the first one */
  g_autofree WxBlendHour *c = rain_hours();
  set_wet(c, 16, 19, 0.7, 50);
  o = outlook_of(c, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 16 * H, T0 + 19 * H, TRUE, T0 + 16 * H, 0.7, 50.0);
}

static void
test_rain_gaps_and_empty(void)
{
  /* hours 11, 12 wet; 13 missing; 14 wet: the run ends at the gap, its end unknown */
  WxBlendHour a[5];
  a[0] = bh(T0 + 11 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  a[1] = bh(T0 + 12 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  a[2] = bh(T0 + 14 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  a[3] = bh(T0 + 15 * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  WxRainOutlook o = outlook_of(a, 4, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 11 * H, 0, FALSE, T0 + 11 * H, 0.5, 60.0);

  /* a wet hour before a gap does not join the wet hour containing now: 10 wet, 11 missing, 12 wet */
  WxBlendHour pre[3];
  pre[0] = bh(T0 + 10 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  pre[1] = bh(T0 + 12 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  pre[2] = bh(T0 + 13 * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  o = outlook_of(pre, 3, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, T0 + 13 * H, TRUE, T0 + 12 * H, 0.5, 60.0);

  /* dry now, a gap, then rain: expected; the run before a gap is not joined to the one after */
  WxBlendHour b[5];
  b[0] = bh(T0 + 12 * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  b[1] = bh(T0 + 14 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  b[2] = bh(T0 + 15 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  b[3] = bh(T0 + 17 * H, 20, 0.5, 60, 50, WX_COND_RAIN, TRUE, 1);
  o = outlook_of(b, 4, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 14 * H, 0, FALSE, T0 + 14 * H, 0.5, 60.0);

  /* contiguous runs are joined only without a gap: 14, 15 wet then 16 dry then 17 wet */
  b[3] = bh(T0 + 16 * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  o = outlook_of(b, 4, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 14 * H, T0 + 16 * H, TRUE, T0 + 14 * H, 0.5, 60.0);

  /* no hours at all, and no hour covering now */
  o = outlook_of(NULL, 0, NULL, 0, NOW_S);
  assert_dry(&o);
  WxBlendHour past = bh(T0 + 2 * H, 20, 5.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  o = outlook_of(&past, 1, NULL, 0, NOW_S);
  assert_dry(&o);
  /* the forecast starts in the future and rains: expected, although nothing covers now */
  WxBlendHour fut = bh(T0 + 15 * H, 20, 5.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  o = outlook_of(&fut, 1, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 15 * H, 0, FALSE, T0 + 15 * H, 5.0, 90.0);
}

static void
quarters_from(WxQuarter *q, gint64 first, const double *amounts, guint n)
{
  for (guint i = 0; i < n; i++) {
    q[i].t_s = first + (gint64)i * 900;
    q[i].precip_mm = amounts[i];
  }
}

static void
test_rain_quarters(void)
{
  gint64 q1230 = T0 + 12 * H + 1800;
  WxQuarter q[16];
  double amounts[16] = {0};

  /* (a) the hours are dry; the quarter containing now (12:30) and the next are wet */
  g_autofree WxBlendHour *a = rain_hours();
  amounts[0] = 0.06;
  amounts[1] = 0.06;
  quarters_from(q, q1230, amounts, 12);
  WxRainOutlook o = outlook_of(a, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, q1230, T0 + 13 * H, TRUE, q1230, 0.24, NAN);

  /* (e) the 0.05 mm threshold: >= wet */
  memset(amounts, 0, sizeof amounts);
  amounts[0] = 0.05;
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(a, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, q1230, q1230 + 900, TRUE, q1230, 0.2, NAN);
  amounts[0] = 0.0499;
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(a, RN, q, 12, NOW_S);
  assert_dry(&o);

  /* wet quarters later in the first two hours: expected, with the quarter's start */
  memset(amounts, 0, sizeof amounts);
  amounts[3] = 0.1;
  amounts[4] = 0.2;
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(a, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, q1230 + 3 * 900, q1230 + 5 * 900, TRUE, q1230 + 4 * 900, 0.8, NAN);
  /* a quarter beyond 2 hours from now (12:37 + 2 h = 14:37) is not used: quarter 14:45 */
  memset(amounts, 0, sizeof amounts);
  amounts[9] = 0.3; /* 14:45: the 10th quarter starts after 14:37 */
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(a, RN, q, 12, NOW_S);
  assert_dry(&o);
  amounts[9] = 0;
  amounts[8] = 0.3; /* 14:30 starts before 14:37 */
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(a, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, q1230 + 8 * 900, q1230 + 9 * 900, TRUE, q1230 + 8 * 900, 1.2, NAN);

  /* (b) quarters dry; hour 12 is wet but replaced for 12:30 .. 14:45 and past before that;
   * hour 14 is wet: its remainder after the quarters (14:45 .. 15:00) is the first rain */
  g_autofree WxBlendHour *b = rain_hours();
  set_wet(b, 12, 13, 2.0, 60);
  set_wet(b, 14, 15, 0.5, 50);
  memset(amounts, 0, sizeof amounts);
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(b, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 14 * H + 2700, T0 + 15 * H, TRUE, T0 + 14 * H + 2700, 0.5, 50.0);

  /* (d) the quarters win over a wet hour 13 that they cover: no rain run; the hour's own
   * probability still makes rain "possible" */
  g_autofree WxBlendHour *d = rain_hours();
  set_wet(d, 13, 14, 9.0, 100);
  o = outlook_of(d, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_POSSIBLE, 0, 0, FALSE, T0 + 13 * H, 9.0, 100.0);
  /* without quarters the same forecast is wet at 13:00 */
  o = outlook_of(d, RN, NULL, 0, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 13 * H, T0 + 14 * H, TRUE, T0 + 13 * H, 9.0, 100.0);

  /* (c) quarter run handing over to the hours: 9 wet quarters (12:30 .. 14:45), hour 14's remainder,
   * hour 15, then dry. The start is 12:30 (the 12:00 .. 12:30 part of hour 12 is dry). */
  g_autofree WxBlendHour *c = rain_hours();
  set_wet(c, 14, 15, 0.3, 50);
  set_wet(c, 15, 16, 0.9, 70);
  for (guint i = 0; i < 16; i++)
    amounts[i] = 0.1;
  quarters_from(q, q1230, amounts, 12);
  o = outlook_of(c, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, q1230, T0 + 16 * H, TRUE, T0 + 15 * H, 0.9, 70.0);
  /* the wet part of hour 12 before the quarters joins the run (12:00 .. 12:30) */
  set_wet(c, 12, 13, 0.2, 40);
  o = outlook_of(c, RN, q, 12, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, T0 + 16 * H, TRUE, T0 + 15 * H, 0.9, 70.0);

  /* (f) the quarter containing now is not the first one: the quarters are ignored */
  g_autofree WxBlendHour *f = rain_hours();
  set_wet(f, 12, 13, 0.8, 50);
  amounts[0] = 5.0;
  quarters_from(q, q1230 + 900, amounts, 4); /* 12:45 .. 13:30 */
  o = outlook_of(f, RN, q, 4, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, T0 + 12 * H, T0 + 13 * H, TRUE, T0 + 12 * H, 0.8, 50.0);

  /* (g) a gap in the quarters: only the run from 12:30 is used (12:30, 12:45) */
  g_autofree WxBlendHour *g = rain_hours();
  WxQuarter gq[3] = {{q1230, 0.1}, {q1230 + 900, 0.1}, {q1230 + 2700, 5.0}}; /* 13:15 after a gap */
  o = outlook_of(g, RN, gq, 3, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, q1230, T0 + 13 * H, TRUE, q1230, 0.4, NAN);

  /* quarters without any hours: the quarter run still gives an outlook */
  o = outlook_of(NULL, 0, gq, 2, NOW_S);
  assert_outlook(&o, WX_RAIN_NOW, q1230, 0, FALSE, q1230, 0.4, NAN); /* nothing after the run */

  /* quarters that do not contain now at all (stale) are ignored */
  g_autofree WxBlendHour *s = rain_hours();
  set_wet(s, 16, 17, 0.5, 60);
  quarters_from(q, T0 + 10 * H, amounts, 8);
  o = outlook_of(s, RN, q, 8, NOW_S);
  assert_outlook(&o, WX_RAIN_EXPECTED, T0 + 16 * H, T0 + 17 * H, TRUE, T0 + 16 * H, 0.5, 60.0);
}

static void
test_rain_criticals(void)
{
  g_autoptr(WxPlace) p = london();
  g_autoptr(WxForecast) fc = make_forecast(p, NULL, 0, NULL, 0);
  WxRainOutlook o;
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(fc, NOW_S, NULL));
  /* on a precondition failure the outlook is still set to the dry one */
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(NULL, NOW_S, &o));
  assert_dry(&o);
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(fc, WX_TIME_MIN_S - 1, &o));
  assert_dry(&o);
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(fc, WX_TIME_MAX_S, &o));
  assert_dry(&o);
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(fc, G_MAXINT64, &o));
  assert_dry(&o);
  /* the ends of the range are fine */
  wx_rain_outlook(fc, WX_TIME_MIN_S, &o);
  assert_dry(&o);
  wx_rain_outlook(fc, WX_TIME_MAX_S - 1, &o);
  assert_dry(&o);
}

/* A reference outlook for a forecast made of hours only, written straight from the rules in
 * wx-rain.h with time arithmetic on the hour grid instead of the sample list of the code. */
typedef struct {
  gint64 t;
  double mm, prob;
} RefHour;

static const RefHour *
ref_at(const RefHour *h, guint n, gint64 t)
{
  for (guint i = 0; i < n; i++) {
    if (h[i].t == t)
      return &h[i];
  }
  return NULL;
}

static gboolean
ref_wet(const RefHour *h)
{
  return h != NULL && h->mm >= 0.1 && (isnan(h->prob) || h->prob >= 30.0);
}

static WxRainOutlook
ref_outlook(const RefHour *h, guint n, gint64 now)
{
  gint64 horizon = now + 172800;
  WxRainOutlook o = {.state = WX_RAIN_DRY};
  gint64 first = 0;
  gboolean have = FALSE;
  const RefHour *cover = NULL;
  for (guint i = 0; i < n; i++) {
    if (h[i].t <= now && now < h[i].t + 3600)
      cover = &h[i];
  }
  if (cover != NULL && ref_wet(cover)) {
    first = cover->t;
    while (ref_wet(ref_at(h, n, first - 3600)))
      first -= 3600;
    o.state = WX_RAIN_NOW;
    have = TRUE;
  } else {
    /* the earliest wet hour that starts at or after now and before the horizon */
    const RefHour *c = NULL;
    for (guint k = 0; k < n; k++) {
      if (ref_wet(&h[k]) && h[k].t >= now && h[k].t < horizon && (c == NULL || h[k].t < c->t))
        c = &h[k];
    }
    if (c != NULL) {
      first = c->t;
      o.state = WX_RAIN_EXPECTED;
      have = TRUE;
    }
  }
  if (have) {
    gint64 last = first;
    while (ref_wet(ref_at(h, n, last + 3600)) && last + 3600 < horizon)
      last += 3600;
    const RefHour *next = ref_at(h, n, last + 3600);
    o.start_s = first;
    o.ends_known = next != NULL && last + 3600 < horizon && !ref_wet(next);
    o.end_s = o.ends_known ? last + 3600 : 0;
    o.peak_mm_h = -1;
    o.peak_prob = NAN;
    for (gint64 t = first; t <= last; t += 3600) {
      const RefHour *c = ref_at(h, n, t);
      if (c->mm > o.peak_mm_h) {
        o.peak_mm_h = c->mm;
        o.peak_s = t;
      }
      if (!isnan(c->prob) && (isnan(o.peak_prob) || c->prob > o.peak_prob))
        o.peak_prob = c->prob;
    }
    return o;
  }
  const RefHour *best = NULL;
  for (guint i = 0; i < n; i++) {
    if (h[i].t + 3600 > now && h[i].t < horizon && h[i].prob >= 40.0 &&
        (best == NULL || h[i].prob > best->prob))
      best = &h[i];
  }
  if (best != NULL) {
    o.state = WX_RAIN_POSSIBLE;
    o.peak_s = best->t;
    o.peak_prob = best->prob;
    o.peak_mm_h = isfinite(best->mm) ? best->mm : 0.0;
  }
  return o;
}

/* Equal up to rounding (the oracle averages ties as (a + b) / 2, the code as a + (b - a) / 2),
 * or both NAN. */
static void
assert_close_or_nan(double got, double want)
{
  if (isnan(want))
    ASSERT_NAN(got);
  else
    g_assert_cmpfloat(fabs(got - want), <=, 1e-12 * fmax(1.0, fabs(want)));
}

static void
test_rain_fuzz_against_reference(void)
{
  g_autoptr(WxPlace) p = london();
  GRand *r = rng(424242);
  static const double mms[] = {0.0, 0.0, 0.05, 0.0999, 0.1, 0.5, 2.0, NAN};
  static const double probs[] = {NAN, 0.0, 20.0, 29.99, 30.0, 39.99, 40.0, 45.0, 80.0};
  guint seen[4] = {0};
  for (int iter = 0; iter < 20000; iter++) {
    guint n = (guint)g_rand_int_range(r, 0, 90);
    gint64 base = T0 + (gint64)g_rand_int_range(r, 0, 100) * H;
    RefHour ref[90];
    WxBlendHour hrs[90];
    guint m = 0;
    gboolean sticky = g_rand_double(r) < 0.5; /* rain tends to continue */
    gboolean raining = FALSE;
    for (guint i = 0; i < n; i++) {
      if (g_rand_double(r) < 0.05)
        continue; /* a missing hour */
      if (!sticky || g_rand_double(r) < 0.3)
        raining = g_rand_boolean(r);
      double mm = raining ? mms[g_rand_int_range(r, 4, G_N_ELEMENTS(mms))] : mms[g_rand_int_range(r, 0, 4)];
      double prob = probs[g_rand_int_range(r, 0, G_N_ELEMENTS(probs))];
      ref[m].t = base + (gint64)i * H;
      ref[m].mm = mm;
      ref[m].prob = prob;
      hrs[m] = bh(ref[m].t, 20, mm, prob, 50, WX_COND_CLEAR, TRUE, 1);
      m++;
    }
    gint64 now = base + (gint64)g_rand_int_range(r, -4, 60 + (int)n) * H + g_rand_int_range(r, 0, H);
    if (g_rand_double(r) < 0.1)
      now = base + (gint64)g_rand_int_range(r, 0, 60) * H; /* on the hour */
    g_autoptr(WxForecast) fc = make_forecast(p, hrs, m, NULL, 0);
    WxRainOutlook got;
    wx_rain_outlook(fc, now, &got);
    WxRainOutlook want = ref_outlook(ref, m, now);
    g_assert_cmpint(got.state, ==, want.state);
    g_assert_cmpint(got.start_s, ==, want.start_s);
    g_assert_cmpint(got.end_s, ==, want.end_s);
    g_assert_cmpint(got.ends_known, ==, want.ends_known);
    g_assert_cmpint(got.peak_s, ==, want.peak_s);
    assert_close_or_nan(got.peak_mm_h, want.peak_mm_h);
    assert_close_or_nan(got.peak_prob, want.peak_prob);
    seen[got.state]++;
    /* invariants of the result */
    g_assert_cmpint(got.ends_known, ==, got.end_s != 0);
    if (got.state == WX_RAIN_NOW)
      g_assert_cmpint(got.start_s, <=, now);
    if (got.state == WX_RAIN_EXPECTED)
      g_assert_cmpint(got.start_s, >=, now);
    if (got.end_s != 0) {
      g_assert_cmpint(got.start_s, <=, got.peak_s);
      g_assert_cmpint(got.peak_s, <, got.end_s);
    }
  }
  for (guint s = 0; s < 4; s++)
    g_assert_cmpuint(seen[s], >, 500);
  g_rand_free(r);
}

/* With quarters the outlook keeps its invariants whatever the data. */
static void
test_rain_fuzz_quarters_invariants(void)
{
  g_autoptr(WxPlace) p = london();
  GRand *r = rng(99);
  for (int iter = 0; iter < 5000; iter++) {
    WxBlendHour hrs[40];
    guint n = (guint)g_rand_int_range(r, 0, 40);
    gint64 base = T0 + (gint64)g_rand_int_range(r, 0, 100) * H;
    for (guint i = 0; i < n; i++) {
      double mm = g_rand_double(r) < 0.6 ? 0.0 : rnd(r, 0, 3);
      double prob = g_rand_double(r) < 0.2 ? NAN : rnd(r, 0, 100);
      hrs[i] = bh(base + (gint64)i * H, 20, mm, prob, 50, WX_COND_CLEAR, TRUE, 1);
    }
    gint64 now = base + (gint64)g_rand_int_range(r, 0, 40) * H + g_rand_int_range(r, 0, H);
    gint64 q0 = now - now % 900 - 900 * g_rand_int_range(r, 0, 2);
    guint nq = (guint)g_rand_int_range(r, 0, 14);
    WxQuarter q[14];
    for (guint i = 0; i < nq; i++) {
      q[i].t_s = q0 + (gint64)i * 900;
      q[i].precip_mm = g_rand_double(r) < 0.5 ? 0.0 : rnd(r, 0, 1);
    }
    g_autoptr(WxForecast) fc = make_forecast(p, hrs, n, q, nq);
    WxRainOutlook o;
    wx_rain_outlook(fc, now, &o);
    g_assert_cmpint(o.ends_known, ==, o.end_s != 0);
    g_assert_true(o.state == WX_RAIN_DRY || o.state == WX_RAIN_NOW || o.state == WX_RAIN_EXPECTED ||
                  o.state == WX_RAIN_POSSIBLE);
    if (o.state == WX_RAIN_DRY) {
      g_assert_cmpint(o.start_s, ==, 0);
      g_assert_cmpint(o.end_s, ==, 0);
    }
    if (o.state == WX_RAIN_NOW || o.state == WX_RAIN_EXPECTED) {
      g_assert_cmpint(o.start_s, <=, o.peak_s);
      g_assert_true(isfinite(o.peak_mm_h) && o.peak_mm_h >= 0);
      if (o.end_s != 0)
        g_assert_cmpint(o.peak_s, <, o.end_s);
      g_assert_cmpint(o.start_s, <, now + 172800);
    }
    if (o.state == WX_RAIN_POSSIBLE)
      g_assert_cmpfloat(o.peak_prob, >=, 40.0);
  }
  g_rand_free(r);
}

/* ------------------------------------------------------------------------ */
/* daily summary                                                            */
/* ------------------------------------------------------------------------ */

typedef void (*BhFn)(WxBlendHour *h, guint i, gpointer data);

/* @n hours from @first_t: 15 degC, dry, 10 %, 50 % cloud, night, one member; @fn adjusts them. */
static WxBlendHour *
daily_hours(gint64 first_t, guint n, BhFn fn, gpointer data)
{
  WxBlendHour *a = g_new(WxBlendHour, n > 0 ? n : 1);
  for (guint i = 0; i < n; i++) {
    a[i] = bh(first_t + (gint64)i * H, 15, 0.0, 10, 50, WX_COND_PARTLY_CLOUDY, FALSE, 1);
    if (fn != NULL)
      fn(&a[i], i, data);
  }
  return a;
}

/* Builds the days of @hours in @tz at @now; returns their number. */
static guint
days_of_at(const char *tz, const WxBlendHour *hours, guint n, gint64 now, WxDay *days)
{
  memset(days, 0, sizeof(WxDay) * WX_DAILY_MAX_DAYS);
  guint nd = wx_daily_build(tz, hours, n, now, days);
  g_assert_cmpuint(nd, <=, WX_DAILY_MAX_DAYS);
  for (guint i = 0; i < nd; i++) {
    g_assert_cmpint(days[i].condition, >=, 0);
    g_assert_cmpint(days[i].condition, <, WX_COND_COUNT);
    if (i > 0)
      g_assert_cmpint(days[i].start_s, >, days[i - 1].start_s);
  }
  return nd;
}

/* The days of @hours when "now" is long before every hour: no day is over and none is today, so
 * every day needs WX_DAILY_MIN_HOURS covered hours. */
static guint
days_of(const char *tz, const WxBlendHour *hours, guint n, WxDay *days)
{
  memset(days, 0, sizeof(WxDay) * WX_DAILY_MAX_DAYS);
  guint nd = wx_daily_build(tz, hours, n, WX_TIME_MIN_S, days);
  g_assert_cmpuint(nd, <=, WX_DAILY_MAX_DAYS);
  for (guint i = 0; i < nd; i++) {
    g_assert_cmpint(days[i].condition, >=, 0);
    g_assert_cmpint(days[i].condition, <, WX_COND_COUNT);
    if (i > 0)
      g_assert_cmpint(days[i].start_s, >, days[i - 1].start_s);
  }
  return nd;
}

/* True when the zone database knows @tz; the zone tests are skipped without tzdata. */
static gboolean
zone_available(const char *tz)
{
  GTimeZone *z = g_time_zone_new_identifier(tz);
  if (z == NULL)
    return FALSE;
  g_time_zone_unref(z);
  return TRUE;
}

/* Skips the test (the rest of the calling function) when the zone database lacks @tz. */
#define SKIP_WITHOUT_ZONE(tz)                                  \
  G_STMT_START {                                               \
    if (!zone_available(tz)) {                                 \
      g_test_skip("the time zone database lacks a needed zone"); \
      return;                                                  \
    }                                                          \
  }                                                            \
  G_STMT_END

/* Local-hour pattern for Miami without a DST change: the hour i is the local hour i % 24. */
static void
fill_pattern(WxBlendHour *h, guint i, gpointer data)
{
  guint lh = i % 24, di = i / 24;
  (void)data;
  h->temp_c = 10 + lh + 2 * di;
  h->precip_mm = 0.02;
  h->precip_prob = lh * 4;
  h->cloud_pct = lh * 4;
  h->is_day = lh >= 7 && lh <= 18;
}

static void
test_daily_basic(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  /* three local days of Miami (EDT, no DST change): 2026-10-12 00:00 EDT = 04:00Z */
  gint64 first = 1791777600;
  g_autofree WxBlendHour *a = daily_hours(first, 72, fill_pattern, NULL);
  WxDay d[WX_DAILY_MAX_DAYS];
  guint n = days_of("America/New_York", a, 72, d);
  g_assert_cmpuint(n, ==, 3);
  for (guint i = 0; i < 3; i++) {
    g_assert_cmpint(d[i].start_s, ==, first + (gint64)i * 86400);
    ASSERT_NEAR(d[i].temp_max_c, 33.0 + 2 * i);
    ASSERT_NEAR(d[i].temp_min_c, 10.0 + 2 * i);
    ASSERT_NEAR(d[i].precip_mm, 0.48);
    ASSERT_NEAR(d[i].precip_prob_max, 92.0);
    ASSERT_NEAR(d[i].cloud_pct, 50.0); /* mean of 4 * (7 .. 18) */
    g_assert_cmpint(d[i].condition, ==, WX_COND_PARTLY_CLOUDY);
  }
  /* the day boundaries follow the zone, not UTC: the same hours in UTC give other days */
  n = days_of("UTC", a, 72, d);
  g_assert_cmpuint(n, ==, 3); /* 20 + 24 + 24 + 4 hours from 04:00Z: the last day has only 4 */
  g_assert_cmpint(d[0].start_s, ==, 1791763200); /* 2026-10-12T00:00:00Z */
}

static void
test_daily_covered_hours(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  gint64 midnight = 1791777600;
  WxDay d[WX_DAILY_MAX_DAYS];
  /* the second day needs 12 covered hours */
  for (guint extra = 10; extra <= 13; extra++) {
    g_autofree WxBlendHour *a = daily_hours(midnight, 24 + extra, NULL, NULL);
    guint n = days_of("America/New_York", a, 24 + extra, d);
    g_assert_cmpuint(n, ==, extra >= WX_DAILY_MIN_HOURS ? 2 : 1);
  }
  /* the first day may be partial: it starts at its local midnight, before the first hour */
  g_autofree WxBlendHour *p12 = daily_hours(midnight + 12 * H, 12, NULL, NULL); /* 12:00 .. 23:00 */
  g_assert_cmpuint(days_of("America/New_York", p12, 12, d), ==, 1);
  g_assert_cmpint(d[0].start_s, ==, midnight);
  g_autofree WxBlendHour *p11 = daily_hours(midnight + 13 * H, 11, NULL, NULL);
  g_assert_cmpuint(days_of("America/New_York", p11, 11, d), ==, 0);
  /* only hours with a member count as covered */
  for (guint uncovered = 11; uncovered <= 13; uncovered++) {
    g_autofree WxBlendHour *a = daily_hours(midnight, 48, NULL, NULL);
    for (guint i = 24; i < 24 + uncovered; i++)
      a[i].n_members = 0;
    guint n = days_of("America/New_York", a, 48, d);
    g_assert_cmpuint(n, ==, (24 - uncovered >= WX_DAILY_MIN_HOURS) ? 2 : 1);
  }
  /* a skipped day does not stop the next one */
  g_autofree WxBlendHour *s = daily_hours(midnight + 13 * H, 11 + 24 + 12, NULL, NULL);
  g_assert_cmpuint(days_of("America/New_York", s, 11 + 24 + 12, d), ==, 2);
  g_assert_cmpint(d[0].start_s, ==, midnight + 86400);
  g_assert_cmpint(d[1].start_s, ==, midnight + 2 * 86400);

  /* at most WX_DAILY_MAX_DAYS days, the earliest */
  g_autofree WxBlendHour *big = daily_hours(midnight, 14 * 24, NULL, NULL);
  g_assert_cmpuint(days_of("America/New_York", big, 14 * 24, d), ==, WX_DAILY_MAX_DAYS);
  g_assert_cmpint(d[0].start_s, ==, midnight);
  g_assert_cmpint(d[9].start_s, ==, midnight + 9 * 86400);
  /* the largest accepted hour count */
  g_autofree WxBlendHour *max = daily_hours(midnight, WX_FORECAST_MAX_HOURS, NULL, NULL);
  g_assert_cmpuint(days_of("America/New_York", max, WX_FORECAST_MAX_HOURS, d), ==, WX_DAILY_MAX_DAYS);
  /* no hours */
  g_assert_cmpuint(days_of("America/New_York", NULL, 0, d), ==, 0);
}

static void
fill_one_mm(WxBlendHour *h, guint i, gpointer data)
{
  (void)i;
  (void)data;
  h->precip_mm = 1.0;
  h->precip_prob = 10;
  h->cloud_pct = NAN;
  h->temp_c = 10;
}

/* A zone with a DST change: the day of the change has 23 or 25 hours, each hour is in exactly one day */
static void
assert_dst_days(const char *tz, gint64 first, guint n, const gint64 *starts, const double *sums, guint n_days)
{
  SKIP_WITHOUT_ZONE(tz);
  g_autofree WxBlendHour *a = daily_hours(first, n, fill_one_mm, NULL);
  WxDay d[WX_DAILY_MAX_DAYS];
  guint nd = days_of(tz, a, n, d);
  g_assert_cmpuint(nd, ==, n_days);
  for (guint i = 0; i < nd; i++) {
    if (d[i].start_s != starts[i])
      FAIL("%s day %u starts %" G_GINT64_FORMAT " wanted %" G_GINT64_FORMAT, tz, i, d[i].start_s, starts[i]);
    ASSERT_NEAR(d[i].precip_mm, sums[i]);
  }
}

static void
test_daily_dst(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  SKIP_WITHOUT_ZONE("Europe/London");
  SKIP_WITHOUT_ZONE("Australia/Sydney");
  SKIP_WITHOUT_ZONE("America/Havana");
  /* Miami: fall back 2026-11-01 (25 hour day), spring forward 2026-03-08 (23 hour day) */
  const gint64 ny_fall[] = {1793419200, 1793505600, 1793595600, 1793682000};
  const double s25[] = {24, 25, 24, 12};
  assert_dst_days("America/New_York", 1793419200, 85, ny_fall, s25, 4);
  const gint64 ny_spring[] = {1772859600, 1772946000, 1773028800, 1773115200};
  const double s23[] = {24, 23, 24, 12};
  assert_dst_days("America/New_York", 1772859600, 83, ny_spring, s23, 4);
  /* London: 2026-10-25 (BST ends, 25 hours) */
  const gint64 lon[] = {1792796400, 1792882800, 1792972800, 1793059200};
  assert_dst_days("Europe/London", 1792796400, 85, lon, s25, 4);
  /* Sydney: 2026-10-04 (DST starts, 23 hours) */
  const gint64 syd[] = {1790949600, 1791036000, 1791118800, 1791205200};
  assert_dst_days("Australia/Sydney", 1790949600, 83, syd, s23, 4);
  /* Havana: DST starts at midnight, so local midnight of 2026-03-08 does not exist: the day
   * starts at its first valid instant (01:00 CDT = 05:00Z) */
  const gint64 hav_spring[] = {1772859600, 1772946000, 1773028800, 1773115200};
  assert_dst_days("America/Havana", 1772859600, 83, hav_spring, s23, 4);
  /* Havana: DST ends at 01:00, so midnight of 2026-11-01 happens twice: the first one starts the day */
  const gint64 hav_fall[] = {1793419200, 1793505600, 1793595600, 1793682000};
  assert_dst_days("America/Havana", 1793419200, 85, hav_fall, s25, 4);

  /* an hour belongs to the day of its instant: a spike in the last hour of a 25 hour day stays in
   * that day, the next hour starts the next day */
  g_autofree WxBlendHour *a = daily_hours(1793419200, 85, fill_one_mm, NULL);
  a[24 + 24].temp_c = 40; /* 2026-11-02T04:00Z = 23:00 EST of Nov 1 */
  a[24 + 25].temp_c = 41; /* 2026-11-02T05:00Z = 00:00 EST of Nov 2 */
  g_assert_cmpint(a[48].t_s, ==, 1793595600 - H);
  WxDay d[WX_DAILY_MAX_DAYS];
  g_assert_cmpuint(days_of("America/New_York", a, 85, d), ==, 4);
  ASSERT_NEAR(d[1].temp_max_c, 40.0);
  ASSERT_NEAR(d[2].temp_max_c, 41.0);
  ASSERT_NEAR(d[0].temp_max_c, 10.0);
}

static void
test_daily_zones_and_invalid_names(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  g_autofree WxBlendHour *a = daily_hours(T0, 72, fill_pattern, NULL);
  WxDay ref[WX_DAILY_MAX_DAYS], d[WX_DAILY_MAX_DAYS];
  g_assert_cmpuint(days_of("UTC", a, 72, ref), ==, 3);
  g_assert_cmpint(ref[0].start_s, ==, T0);
  g_assert_cmpint(ref[2].start_s, ==, T0 + 2 * 86400);
  g_assert_cmpuint(days_of("Etc/UTC", a, 72, d), ==, 3);
  g_assert_cmpint(d[1].start_s, ==, T0 + 86400);

  /* empty, NULL, unknown, and every shape that must never reach the zone database: UTC days */
  char long_name[WX_PLACE_TIMEZONE_MAX + 2];
  memset(long_name, 'a', sizeof long_name);
  long_name[sizeof long_name - 1] = '\0';
  const char *bad[] = {NULL, "", "Nope/Zone", "Foo", "/etc/passwd", "/usr/share/zoneinfo/UTC",
                       "../../etc/passwd", "..", ".", "/", "America/New_York/", "America//New_York",
                       "America/New York", "-", "+05:00", "UTC+0:00", "America/./New_York",
                       "a\nb", "\xff\xfe", "Z", "/dev/zero", "America/New_York\n", long_name};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    guint n = days_of(bad[i], a, 72, d);
    g_assert_cmpuint(n, ==, 3);
    for (guint k = 0; k < n; k++)
      g_assert_cmpint(d[k].start_s, ==, ref[k].start_s);
  }

  /* the process time zone is never used */
  g_setenv("TZ", "Pacific/Auckland", TRUE);
  tzset();
  g_assert_cmpuint(days_of(NULL, a, 72, d), ==, 3);
  g_assert_cmpint(d[0].start_s, ==, T0);
  g_assert_cmpuint(days_of("America/New_York", a, 72, d), ==, 3);
  g_assert_cmpint(d[0].start_s, ==, T0 + 4 * H);
  g_unsetenv("TZ");
  tzset();

  /* a name without a terminator 64 + 1 bytes long ends at a guard page: no byte beyond it is read */
  long page = sysconf(_SC_PAGESIZE);
  void *map = mmap(NULL, (gsize)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect((char *)map + page, (gsize)page, PROT_NONE), ==, 0);
  gsize len = WX_PLACE_TIMEZONE_MAX + 1;
  char *name = (char *)map + page - len;
  memset(name, 'a', len);
  g_assert_cmpuint(days_of(name, a, 72, d), ==, 3);
  g_assert_cmpint(d[0].start_s, ==, T0);
  munmap(map, (gsize)page * 2);

  /* the hour array is read only up to n_hours (guard page) */
  void *map2 = mmap(NULL, (gsize)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map2 != MAP_FAILED);
  g_assert_cmpint(mprotect((char *)map2 + page, (gsize)page, PROT_NONE), ==, 0);
  guint nh = 12;
  WxBlendHour *edge = (WxBlendHour *)((char *)map2 + page - nh * sizeof(WxBlendHour));
  g_autofree WxBlendHour *src = daily_hours(T0, nh, NULL, NULL);
  memcpy(edge, src, nh * sizeof(WxBlendHour));
  g_assert_cmpuint(days_of("UTC", edge, nh, d), ==, 1);
  munmap(map2, (gsize)page * 2);
}

static void
fill_unknowns(WxBlendHour *h, guint i, gpointer data)
{
  (void)i;
  (void)data;
  h->temp_c = NAN;
  h->precip_mm = NAN;
  h->precip_prob = NAN;
  h->cloud_pct = NAN;
  h->condition = WX_COND_UNKNOWN;
}

static void
fill_aggregates(WxBlendHour *h, guint i, gpointer data)
{
  (void)data;
  /* hours 0..11: unknown temperature on every third hour, unknown precipitation on every
   * fourth; night clouds (100) differ from day clouds */
  h->temp_c = (i % 3 == 0) ? NAN : (double)i - 5.0;
  h->precip_mm = (i % 4 == 0) ? NAN : 0.1 * i;
  h->precip_prob = (i % 5 == 0) ? NAN : 3.0 * i;
  h->is_day = i >= 6 && i < 18;
  h->cloud_pct = (i == 7) ? NAN : (h->is_day ? 10.0 : 100.0);
}

static void
test_daily_aggregates(void)
{
  WxDay d[WX_DAILY_MAX_DAYS];
  /* all unknown: every number NAN, the condition unknown, the day still emitted */
  g_autofree WxBlendHour *u = daily_hours(T0, 24, fill_unknowns, NULL);
  g_assert_cmpuint(days_of("UTC", u, 24, d), ==, 1);
  ASSERT_NAN(d[0].temp_max_c);
  ASSERT_NAN(d[0].temp_min_c);
  ASSERT_NAN(d[0].precip_mm);
  ASSERT_NAN(d[0].precip_prob_max);
  ASSERT_NAN(d[0].cloud_pct);
  g_assert_cmpint(d[0].condition, ==, WX_COND_UNKNOWN);

  g_autofree WxBlendHour *a = daily_hours(T0, 24, fill_aggregates, NULL);
  g_assert_cmpuint(days_of("UTC", a, 24, d), ==, 1);
  /* temperatures: i - 5 for i not divisible by 3, i = 1..23: max 23 - 5 = 18, min 1 - 5 = -4 */
  ASSERT_NEAR(d[0].temp_max_c, 18.0);
  ASSERT_NEAR(d[0].temp_min_c, -4.0);
  /* precipitation: sum over i not divisible by 4 (0.1 * i), i in 0..23 */
  double sum = 0;
  for (guint i = 0; i < 24; i++) {
    if (i % 4 != 0)
      sum += 0.1 * i;
  }
  ASSERT_NEAR(d[0].precip_mm, sum);
  /* probability: max of 3 * i for i not divisible by 5: 23 -> 69 */
  ASSERT_NEAR(d[0].precip_prob_max, 69.0);
  /* cloud: daylight hours 6..17 except the unknown 7: ten... eleven hours of 10 -> 10 */
  ASSERT_NEAR(d[0].cloud_pct, 10.0);
  /* rain day: 24 hours with 2.3 mm at most, probability maximum 69 %: the rain class of the
   * largest rate (2.3 mm/h) and a 10 % cloud mean (below 87.5): showers */
  g_assert_cmpint(d[0].condition, ==, WX_COND_SHOWERS);

  /* polar night: no daylight hour, so the mean over all hours with a cloud value */
  g_autofree WxBlendHour *n = daily_hours(T0, 24, NULL, NULL);
  for (guint i = 0; i < 24; i++) {
    n[i].is_day = FALSE;
    n[i].cloud_pct = (i % 2) ? 20.0 : 40.0;
  }
  g_assert_cmpuint(days_of("UTC", n, 24, d), ==, 1);
  ASSERT_NEAR(d[0].cloud_pct, 30.0);
  g_assert_cmpint(d[0].condition, ==, WX_COND_MOSTLY_CLEAR);
  /* daylight hours without a cloud value but night hours with one: the fallback again */
  for (guint i = 0; i < 24; i++) {
    n[i].is_day = (i < 12);
    n[i].cloud_pct = (i < 12) ? NAN : 80.0;
  }
  g_assert_cmpuint(days_of("UTC", n, 24, d), ==, 1);
  ASSERT_NEAR(d[0].cloud_pct, 80.0);
  /* daylight clouds only count by day, not night: day 0, night 100 -> 0 */
  for (guint i = 0; i < 24; i++) {
    n[i].is_day = (i >= 6 && i < 18);
    n[i].cloud_pct = n[i].is_day ? 0.0 : 100.0;
  }
  g_assert_cmpuint(days_of("UTC", n, 24, d), ==, 1);
  ASSERT_NEAR(d[0].cloud_pct, 0.0);
  g_assert_cmpint(d[0].condition, ==, WX_COND_CLEAR);
}

typedef struct {
  WxCondition cond;
  int from, to;      /* hours [from, to) of the day carry cond */
  double prob;       /* their probability */
} Mark;

typedef struct {
  const Mark *marks;
  guint n_marks;
  double cloud;      /* every hour is daylight with this cloud cover */
  double precip;     /* precipitation of every hour */
  double prob;       /* probability of every hour (before the marks) */
  int rate_hour;     /* an hour with a different precipitation, or -1 */
  double rate;
} CondDay;

static void
fill_cond_day(WxBlendHour *h, guint i, gpointer data)
{
  const CondDay *c = data;
  h->is_day = TRUE;
  h->cloud_pct = c->cloud;
  h->precip_mm = c->precip;
  h->precip_prob = c->prob;
  if ((int)i == c->rate_hour)
    h->precip_mm = c->rate;
  for (guint m = 0; m < c->n_marks; m++) {
    if ((int)i >= c->marks[m].from && (int)i < c->marks[m].to) {
      h->condition = c->marks[m].cond;
      h->precip_prob = c->marks[m].prob;
    }
  }
}

static WxCondition
day_condition(const CondDay *c)
{
  g_autofree WxBlendHour *a = daily_hours(T0, 24, fill_cond_day, (gpointer)c);
  WxDay d[WX_DAILY_MAX_DAYS];
  g_assert_cmpuint(days_of("UTC", a, 24, d), ==, 1);
  return d[0].condition;
}

static void
test_daily_conditions_severe(void)
{
  /* two consecutive hours of a severe class; their probability does not matter */
  Mark t2[] = {{WX_COND_THUNDERSTORM, 10, 12, 10}};
  CondDay c = {t2, 1, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_THUNDERSTORM);
  Mark sn2[] = {{WX_COND_SNOW, 3, 5, 10}};
  c = (CondDay){sn2, 1, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SNOW);
  Mark sl2[] = {{WX_COND_SLEET, 23 - 1, 24, 10}};
  c = (CondDay){sl2, 1, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SLEET);

  /* a single hour needs a probability of 40 % */
  for (int cls = WX_COND_THUNDERSTORM; cls <= WX_COND_SLEET; cls++) {
    Mark one[] = {{(WxCondition)cls, 10, 11, 39.99}};
    c = (CondDay){one, 1, 20.0, 0.0, 10.0, -1, 0};
    g_assert_cmpint(day_condition(&c), ==, WX_COND_MOSTLY_CLEAR);
    one[0].prob = 40.0;
    g_assert_cmpint(day_condition(&c), ==, cls);
    one[0].prob = 100.0;
    g_assert_cmpint(day_condition(&c), ==, cls);
    one[0].prob = NAN;
    g_assert_cmpint(day_condition(&c), ==, WX_COND_MOSTLY_CLEAR);
  }

  /* two hours of the class that are not consecutive do not count */
  Mark apart[] = {{WX_COND_THUNDERSTORM, 10, 11, 10}, {WX_COND_THUNDERSTORM, 12, 13, 10}};
  c = (CondDay){apart, 2, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_MOSTLY_CLEAR);
  /* nor do two that are adjacent in the array but an hour apart in time (an hour is missing) */
  g_autofree WxBlendHour *gap = daily_hours(T0, 24, fill_cond_day, &c);
  memmove(&gap[11], &gap[12], 12 * sizeof(WxBlendHour)); /* drop hour 11: 10 and 12 are neighbours now */
  WxDay d[WX_DAILY_MAX_DAYS];
  g_assert_cmpuint(days_of("UTC", gap, 23, d), ==, 1);
  g_assert_cmpint(d[0].condition, ==, WX_COND_MOSTLY_CLEAR);
  /* consecutive hours but split by midnight are two days of one hour each: nothing */
  Mark midnight[] = {{WX_COND_THUNDERSTORM, 23, 25, 10}};
  CondDay cm = {midnight, 1, 20.0, 0.0, 10.0, -1, 0};
  g_autofree WxBlendHour *two = daily_hours(T0, 48, fill_cond_day, &cm);
  g_assert_cmpuint(days_of("UTC", two, 48, d), ==, 2);
  g_assert_cmpint(d[0].condition, ==, WX_COND_MOSTLY_CLEAR);
  g_assert_cmpint(d[1].condition, ==, WX_COND_MOSTLY_CLEAR);

  /* priority: thunderstorm, snow, sleet; a class that does not qualify does not count */
  Mark ts[] = {{WX_COND_THUNDERSTORM, 2, 4, 10}, {WX_COND_SNOW, 6, 8, 10}, {WX_COND_SLEET, 10, 12, 10}};
  c = (CondDay){ts, 3, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_THUNDERSTORM);
  c = (CondDay){ts + 1, 2, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SNOW);
  c = (CondDay){ts + 2, 1, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SLEET);
  Mark weak[] = {{WX_COND_THUNDERSTORM, 2, 3, 10}, {WX_COND_SNOW, 6, 8, 10}};
  c = (CondDay){weak, 2, 20.0, 0.0, 10.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SNOW);
  /* a severe class beats a rainy day */
  Mark ts2[] = {{WX_COND_SLEET, 2, 4, 10}};
  c = (CondDay){ts2, 1, 100.0, 1.0, 90.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SLEET);
}

static void
test_daily_conditions_rain_and_cloud(void)
{
  /* a rain day: sum >= 1 mm and probability maximum >= 50 %; the class follows the largest hourly
   * rate and the mean daylight cloud like an hour does */
  CondDay c = {NULL, 0, 50.0, 0.05, 50.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SHOWERS); /* 24 * 0.05 = 1.2 mm, rate 0.05, cloud 50 */
  c.cloud = 100.0;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_DRIZZLE);
  c.rate_hour = 5;
  c.rate = 0.5;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_LIGHT_RAIN);
  c.rate = 2.5;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_RAIN);
  c.rate = 7.6;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_HEAVY_RAIN);
  c.cloud = 50.0;
  c.rate = 7.5;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SHOWERS);
  c.rate = 7.6;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_HEAVY_RAIN);
  c.cloud = 87.5;
  c.rate = 3.0;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_RAIN);

  /* the thresholds: 1 mm and 50 % */
  c = (CondDay){NULL, 0, 100.0, 0.0, 50.0, 3, 0.99};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_OVERCAST); /* 0.99 mm */
  c.rate = 1.0;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_LIGHT_RAIN); /* exactly 1 mm, rate 1.0 */
  c.prob = 49.99;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_OVERCAST);
  c.prob = NAN;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_OVERCAST);
  c.prob = 50.0;
  c.cloud = 0.0;
  g_assert_cmpint(day_condition(&c), ==, WX_COND_SHOWERS);

  /* a dry day: the cloud words */
  struct {
    double cloud;
    WxCondition cond;
  } words[] = {{0, WX_COND_CLEAR},         {12.49, WX_COND_CLEAR},       {12.5, WX_COND_MOSTLY_CLEAR},
               {37.49, WX_COND_MOSTLY_CLEAR}, {37.5, WX_COND_PARTLY_CLOUDY}, {62.49, WX_COND_PARTLY_CLOUDY},
               {62.5, WX_COND_MOSTLY_CLOUDY}, {87.49, WX_COND_MOSTLY_CLOUDY}, {87.5, WX_COND_OVERCAST},
               {100, WX_COND_OVERCAST},       {NAN, WX_COND_UNKNOWN}};
  for (guint i = 0; i < G_N_ELEMENTS(words); i++) {
    c = (CondDay){NULL, 0, words[i].cloud, 0.0, 10.0, -1, 0};
    g_assert_cmpint(day_condition(&c), ==, words[i].cond);
  }
  /* lots of rain but a low probability: still the cloud word */
  c = (CondDay){NULL, 0, 100.0, 1.0, 20.0, -1, 0};
  g_assert_cmpint(day_condition(&c), ==, WX_COND_OVERCAST);
}

static void
test_daily_time_range_and_criticals(void)
{
  SKIP_WITHOUT_ZONE("Etc/GMT+12");
  WxDay d[WX_DAILY_MAX_DAYS];
  /* UTC-12 at the start of the range: the first local day began before WX_TIME_MIN_S and is
   * skipped although it has 12 hours; the next ones are fine */
  g_autofree WxBlendHour *a = daily_hours(WX_TIME_MIN_S, 48, NULL, NULL);
  g_assert_cmpuint(days_of("Etc/GMT+12", a, 48, d), ==, 2);
  g_assert_cmpint(d[0].start_s, ==, WX_TIME_MIN_S + 12 * H);
  g_assert_cmpint(d[1].start_s, ==, WX_TIME_MIN_S + 36 * H);
  /* the same hours in UTC start exactly at the beginning of the range */
  g_assert_cmpuint(days_of("UTC", a, 48, d), ==, 2);
  g_assert_cmpint(d[0].start_s, ==, WX_TIME_MIN_S);
  /* the last hour of the range */
  g_autofree WxBlendHour *e = daily_hours(WX_TIME_MAX_S - 12 * H, 12, NULL, NULL);
  g_assert_cmpuint(days_of("UTC", e, 12, d), ==, 1);

  /* programmer errors: critical, nothing returned, nothing written */
  WxDay sentinel[WX_DAILY_MAX_DAYS];
  memset(sentinel, 0x5a, sizeof sentinel);
  g_autofree WxBlendHour *ok = daily_hours(T0, 24, NULL, NULL);
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", ok, 24, T0, NULL), ==, 0));
  ASSERT_CRITICAL("wx_daily_build",
                  g_assert_cmpuint(wx_daily_build("UTC", NULL, 24, T0, sentinel), ==, 0));
  ASSERT_CRITICAL("wx_daily_build",
                  g_assert_cmpuint(wx_daily_build("UTC", ok, WX_FORECAST_MAX_HOURS + 1, T0, sentinel), ==, 0));
  g_autofree WxBlendHour *bad = daily_hours(T0, 24, NULL, NULL);
  bad[5].t_s = bad[4].t_s; /* duplicate */
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", bad, 24, T0, sentinel), ==, 0));
  bad[5].t_s = bad[4].t_s - H; /* descending */
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", bad, 24, T0, sentinel), ==, 0));
  bad[5].t_s = bad[4].t_s + 1800; /* off the hour */
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", bad, 24, T0, sentinel), ==, 0));
  bad[5].t_s = bad[4].t_s + H;
  bad[0].t_s = WX_TIME_MIN_S - H; /* before the range */
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", bad, 24, T0, sentinel), ==, 0));
  bad[0].t_s = WX_TIME_MAX_S; /* at the end of the range (exclusive) */
  ASSERT_CRITICAL("wx_daily_build", g_assert_cmpuint(wx_daily_build("UTC", bad, 1, T0, sentinel), ==, 0));
  /* now_s outside the time range, at both ends and at the extremes */
  static const gint64 bad_now[] = {WX_TIME_MIN_S - 1, WX_TIME_MAX_S, G_MININT64, G_MAXINT64, 0, -1};
  for (guint i = 0; i < G_N_ELEMENTS(bad_now); i++)
    ASSERT_CRITICAL("wx_daily_build",
                    g_assert_cmpuint(wx_daily_build("UTC", ok, 24, bad_now[i], sentinel), ==, 0));
  WxDay untouched[WX_DAILY_MAX_DAYS];
  memset(untouched, 0x5a, sizeof untouched);
  g_assert_cmpint(memcmp(sentinel, untouched, sizeof sentinel), ==, 0);

  /* entries beyond the returned count are not written */
  memset(d, 0x5a, sizeof d);
  g_assert_cmpuint(wx_daily_build("UTC", ok, 24, T0, d), ==, 1);
  g_assert_cmpint(memcmp(&d[1], &untouched[1], sizeof(WxDay) * (WX_DAILY_MAX_DAYS - 1)), ==, 0);
}

static void
assert_blend_days(const char *tz, double lat, double lon, guint want_days, gint64 first_start)
{
  SKIP_WITHOUT_ZONE(tz);
  g_autoptr(WxPlace) p = mk_place(lat, lon, tz);
  Vals v = vnone();
  v.temp = 20;
  v.cloud = 30;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0, WX_MEMBER_MAX_HOURS, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  const WxDay *d = wx_forecast_get_days(fc, &n);
  g_assert_cmpuint(n, ==, want_days);
  g_assert_cmpint(d[0].start_s, ==, first_start);
  for (guint i = 0; i < n; i++) {
    g_assert_cmpint(d[i].start_s, ==, first_start + (gint64)i * 86400);
    ASSERT_NEAR(d[i].temp_max_c, 20.0);
    g_assert_cmpint(d[i].condition, ==, WX_COND_MOSTLY_CLEAR);
  }
  fx_free(fx);
}

static void
test_blend_daily_places(void)
{
  /* the blend starts at 11:00Z on 2026-10-11 and keeps 240 hours (until 2026-10-21T10:00Z).
   * Miami (EDT): the 11th has 17 hours (07:00 ..), ... 20th, the 21st only 6: ten days.
   * London (BST): the 11th has 12 hours (12:00 ..): counted, the 21st has 12 hours as well: 11
   * days, ten kept.
   * Sydney (AEDT): it is 23:37 on the 11th and the 11th has 2 hours: today is listed however few
   * hours are left; the 12th .. 20th follow (the 21st is cut by the ten day limit). */
  assert_blend_days("America/New_York", 25.7617, -80.1918, 10, 1791691200);
  assert_blend_days("Europe/London", 51.5074, -0.1278, 10, 1791673200);
  assert_blend_days("Australia/Sydney", -33.8688, 151.2093, 10, 1791637200);
  /* a place without a zone: UTC days; the 11th has 13 hours (11:00 ..) */
  g_autoptr(WxPlace) p = mk_place(10.0, 10.0, "");
  Vals v = vnone();
  v.temp = 20;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0, WX_MEMBER_MAX_HOURS, &v));
  g_autoptr(WxForecast) fc = fx_blend(fx, p, NOW_S);
  guint n;
  const WxDay *d = wx_forecast_get_days(fc, &n);
  g_assert_cmpuint(n, ==, 10);
  g_assert_cmpint(d[0].start_s, ==, T0);
  fx_free(fx);
}

/* 2026-10-12 00:00 EDT (America/New_York). */
#define MIAMI_M G_GINT64_CONSTANT(1791777600)

/* The extremes of the forecast's own hours that lie in [@from, @to): the oracle for a day. */
static void
hour_extremes(const WxForecast *fc, gint64 from, gint64 to, double *tmin, double *tmax, guint *count)
{
  guint n;
  const WxBlendHour *h = hours_of(fc, &n);
  *tmin = INFINITY;
  *tmax = -INFINITY;
  *count = 0;
  for (guint i = 0; i < n; i++) {
    if (h[i].t_s < from || h[i].t_s >= to)
      continue;
    *tmin = MIN(*tmin, h[i].temp_c);
    *tmax = MAX(*tmax, h[i].temp_c);
    (*count)++;
  }
}

/* A member hour of Miami without a DST change: local hour lh of day di is 10 + lh + 2 * di degrees. */
static void
fill_miami_temp(WxHour *h, guint i, gpointer data)
{
  (void)data;
  h->temp_c = 10 + (double)(i % 24) + 2.0 * (double)(i / 24);
}

/* Today's day stays listed from the morning to its local midnight (it used to vanish from 14:00,
 * when fewer than 12 of its hours were left), with the extremes of the hours the forecast holds. */
static void
test_blend_today_until_midnight(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  g_autoptr(WxPlace) p = miami();
  Fx *fx = fx_new();
  /* local hour lh of day di (counted from 2026-10-10) is 10 + lh + 2 * di degrees: 14 + lh today */
  fx_add(fx, "open-meteo",
         mk_member_fn("open-meteo", "ecmwf", MIAMI_M - 2 * 86400, 14 * 24, fill_miami_temp, NULL));
  static const struct {
    const char *what;
    gint64 off_s;  /* now, after local midnight */
    int first_lh;  /* local hour of the first hour of today in the forecast */
  } cases[] = {
    {"00:30", 30 * 60, 0},          /* the list starts at 23:00 yesterday: not a day */
    {"01:30", 90 * 60, 0},          {"09:00", 9 * H, 8},
    {"10:00", 10 * H, 9},           {"13:59", 13 * H + 59 * 60, 12},
    {"14:00", 14 * H, 13},          {"14:01", 14 * H + 60, 13},
    {"18:00", 18 * H, 17},          {"23:00", 23 * H, 22},
    {"23:30", 23 * H + 30 * 60, 22}, {"23:59:59", 24 * H - 1, 22},
  };
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++) {
    g_test_message("now %s local", cases[c].what);
    g_autoptr(WxForecast) fc = fx_blend(fx, p, MIAMI_M + cases[c].off_s);
    guint nh, nd;
    const WxBlendHour *h = hours_of(fc, &nh);
    g_assert_cmpint(h[0].t_s, ==, MIAMI_M + cases[c].off_s - cases[c].off_s % H - H);
    const WxDay *d = wx_forecast_get_days(fc, &nd);
    g_assert_cmpuint(nd, >=, 2);
    g_assert_cmpint(d[0].start_s, ==, MIAMI_M);
    g_assert_cmpint(d[1].start_s, ==, MIAMI_M + 86400);
    ASSERT_NEAR(d[0].temp_min_c, 14.0 + cases[c].first_lh);
    ASSERT_NEAR(d[0].temp_max_c, 37.0);
    /* the same numbers from the forecast's own hours */
    double tmin, tmax;
    guint count;
    hour_extremes(fc, MIAMI_M, MIAMI_M + 86400, &tmin, &tmax, &count);
    g_assert_cmpuint(count, ==, (guint)(24 - cases[c].first_lh));
    ASSERT_NEAR(d[0].temp_min_c, tmin);
    ASSERT_NEAR(d[0].temp_max_c, tmax);
    /* tomorrow is a whole day */
    ASSERT_NEAR(d[1].temp_min_c, 16.0);
    ASSERT_NEAR(d[1].temp_max_c, 39.0);
  }
  fx_free(fx);
}

/* The same where the local midnight is not on a UTC hour (India, UTC+5:30): the hour bucket that
 * straddles midnight belongs to the previous day and must not be listed as "today". */
static void
test_blend_today_half_hour_zone(void)
{
  SKIP_WITHOUT_ZONE("Asia/Kolkata");
  g_autoptr(WxPlace) p = mk_place(22.5726, 88.3639, "Asia/Kolkata");
  Vals v = vnone();
  v.temp = 20;
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 - 2 * 86400, 14 * 24, &v));
  gint64 m = T0 + 18 * H + 30 * 60; /* 2026-10-12 00:00 IST = 2026-10-11T18:30Z */
  static const gint64 offs[] = {1, 15 * 60, 29 * 60, 31 * 60, 45 * 60, 75 * 60, 13 * H + 59 * 60,
                                23 * H + 45 * 60, 24 * H - 1};
  for (guint c = 0; c < G_N_ELEMENTS(offs); c++) {
    g_autoptr(WxForecast) fc = fx_blend(fx, p, m + offs[c]);
    guint nd;
    const WxDay *d = wx_forecast_get_days(fc, &nd);
    g_assert_cmpuint(nd, >=, 2);
    g_assert_cmpint(d[0].start_s, ==, m);
    g_assert_cmpint(d[1].start_s, ==, m + 86400);
  }
  fx_free(fx);
}

/* wx_daily_build(): the day that contains "now" needs one covered hour, every other day twelve. */
static void
test_daily_today(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  gint64 m = MIAMI_M;
  WxDay d[WX_DAILY_MAX_DAYS];
  /* @left hours of today: listed as today, dropped as a later day */
  for (guint left = 1; left <= 11; left++) {
    gint64 first = m + (gint64)(24 - left) * H;
    g_autofree WxBlendHour *a = daily_hours(first, left, NULL, NULL);
    g_assert_cmpuint(days_of_at("America/New_York", a, left, first + 60, d), ==, 1);
    g_assert_cmpint(d[0].start_s, ==, m);
    g_assert_cmpuint(days_of("America/New_York", a, left, d), ==, 0);
    /* "now" on another day of the zone does not make it today */
    g_assert_cmpuint(days_of_at("America/New_York", a, left, m - 3600, d), ==, 0);
    g_assert_cmpuint(days_of_at("America/New_York", a, left, m + 86400, d), ==, 0);
  }
  /* an uncovered today is not listed; the later days follow the 12 hour rule */
  g_autofree WxBlendHour *u = daily_hours(m + 20 * H, 4 + 24 + 12, NULL, NULL);
  for (guint i = 0; i < 4; i++)
    u[i].n_members = 0;
  g_assert_cmpuint(days_of_at("America/New_York", u, 4 + 24 + 12, m + 20 * H + 60, d), ==, 2);
  g_assert_cmpint(d[0].start_s, ==, m + 86400);
  g_assert_cmpint(d[1].start_s, ==, m + 2 * 86400);
  /* the one hour of yesterday that a list cut one hour before now holds just after midnight is
   * no day (a day that is not today needs 12 hours): the list starts with today */
  g_autofree WxBlendHour *o = daily_hours(m - H, 1 + 24 + 12, NULL, NULL);
  g_assert_cmpuint(days_of_at("America/New_York", o, 1 + 24 + 12, m + 30 * 60, d), ==, 2);
  g_assert_cmpint(d[0].start_s, ==, m);
  g_assert_cmpint(d[1].start_s, ==, m + 86400);
  /* until the last second of yesterday it is yesterday that is today */
  g_assert_cmpuint(days_of_at("America/New_York", o, 1 + 24 + 12, m - 1, d), ==, 3);
  g_assert_cmpint(d[0].start_s, ==, m - 86400);
  g_assert_cmpint(d[1].start_s, ==, m);
  /* the ends of the time range are accepted as "now" */
  g_autofree WxBlendHour *e = daily_hours(T0, 24, NULL, NULL);
  g_assert_cmpuint(days_of_at("UTC", e, 24, WX_TIME_MIN_S, d), ==, 1);
  g_assert_cmpuint(days_of_at("UTC", e, 24, WX_TIME_MAX_S - 1, d), ==, 1);
  /* at most ten days */
  g_autofree WxBlendHour *big = daily_hours(m, 12 * 24, NULL, NULL);
  g_assert_cmpuint(days_of_at("America/New_York", big, 12 * 24, m + 30 * 60, d), ==, WX_DAILY_MAX_DAYS);
  g_assert_cmpint(d[0].start_s, ==, m);
  g_assert_cmpint(d[WX_DAILY_MAX_DAYS - 1].start_s, ==, m + 9 * 86400);
}

/* ------------------------------------------------------------------------ */
/* second review round: quarter rescale, median ties, midnights, day sum,   */
/* rain bound, the timezone rule                                            */
/* ------------------------------------------------------------------------ */

/* wx-blend.c's rescale threshold: below it the blended amount is spread evenly. */
#define NOWCAST_MIN_MM 1e-9
/* The smallest positive double. */
#define DMIN 4.9406564584124654e-324

/* Blends ECMWF (one hourly precipitation value, so that every hour blends to exactly it) with
 * a HRRR 15-minute member whose quarters repeat @pattern, at 12:07, and checks the nowcast
 * quarters: the blend must succeed (wx_forecast_new refuses a quarter outside [0, 500]), every
 * quarter is finite and within [0, blended], and each of the three covered hours sums to the
 * blended amount. Returns the sum of the first hour's quarters. */
static double
check_rescaled_quarters(double blended, const double pattern[4])
{
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = blended;
  double qs[12];
  for (guint i = 0; i < 12; i++)
    qs[i] = pattern[i % 4];
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 11 * H, 8, &ec));
  WxMember *q = new_member("open-meteo", "hrrr15");
  add_quarters(q, T0 + 12 * H, qs, 12);
  fx_add(fx, "open-meteo", q);
  GError *err = NULL;
  g_autoptr(WxForecast) fc = fx_blend_at(fx, p, T0 + 12 * H + 7 * 60, &err);
  if (fc == NULL)
    FAIL("blend of %g mm with pattern %g %g %g %g failed: %s", blended, pattern[0], pattern[1],
         pattern[2], pattern[3], err->message);
  guint nq;
  const WxQuarter *out = wx_forecast_get_quarters(fc, &nq);
  g_assert_cmpuint(nq, ==, 12);
  double first_sum = 0;
  for (guint hh = 0; hh < 3; hh++) {
    double want = hour_at(fc, T0 + (12 + (gint64)hh) * H)->precip_mm;
    g_assert_cmpfloat(want, ==, blended);
    double sum = 0;
    for (guint k = 0; k < 4; k++) {
      double v = out[4 * hh + k].precip_mm;
      g_assert_true(isfinite(v));
      g_assert_cmpfloat(v, >=, 0.0);
      g_assert_cmpfloat(v, <=, blended);
      sum += v;
    }
    g_assert_cmpfloat(fabs(sum - want), <=, 1e-9);
    /* the even spread (blended below 1e-9) rounds blended / 4 to nearest: the sum is within 4
     * subnormal ulps of blended, above or below (2 is the real bound) */
    if (blended < NOWCAST_MIN_MM)
      g_assert_cmpfloat(fabs(sum - want), <=, 4 * DMIN);
    if (hh == 0)
      first_sum = sum;
  }
  fx_free(fx);
  return first_sum;
}

static void
test_nowcast_rescale_in_range(void)
{
  /* a single non-zero quarter at each position, at the cap (0.073 * (500 / 0.073) is 500 + 1 ulp
   * with the plain ratio), and subnormal raw sums whose ratio overflows */
  static const double singles[] = {0.073, 0.21, 0.37, 1.0, 499.99999999999994, 500.0,
                                   1e-9, 1e-310, 4.9e-324};
  static const double blendeds[] = {500.0, 499.99999999999994, 7.6, 0.3, 1e-9, 1e-300, 4.9e-324};
  for (guint b = 0; b < G_N_ELEMENTS(blendeds); b++) {
    for (guint s = 0; s < G_N_ELEMENTS(singles); s++) {
      for (guint pos = 0; pos < 4; pos++) {
        double pattern[4] = {0, 0, 0, 0};
        pattern[pos] = singles[s];
        check_rescaled_quarters(blendeds[b], pattern);
      }
    }
    static const double others[][4] = {
      {0.073, 0.073, 0.073, 0.073}, {500, 500, 500, 500},   {0, 0, 0, 0},
      {1e-310, 1e-310, 1e-310, 1e-310}, {4.9e-324, 0, 4.9e-324, 0},
      {0.25e-9, 0.25e-9, 0.25e-9, 0.25e-9}, /* the raw sum is exactly 1e-9 */
      {0.249e-9, 0.25e-9, 0.25e-9, 0.25e-9}, /* just below it */
      {0.1, 0.2, 0.3, 0.4},         {500, 0, 0, 1e-300},  {0.5, 0.5, 0.5, 0.5},
    };
    for (guint o = 0; o < G_N_ELEMENTS(others); o++)
      check_rescaled_quarters(blendeds[b], others[o]);
  }
  check_rescaled_quarters(0.0, (double[4]){0.073, 0.2, 0, 0});

  /* the exact values: the largest quarter keeps the remainder */
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 500.0;
  double qs[12] = {0.073, 0, 0, 0, 0, 0, 0, 0.21, 1e-310, 0, 0, 0};
  Fx *fx = fx_new();
  fx_add(fx, "open-meteo", mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec));
  WxMember *q = new_member("open-meteo", "hrrr15");
  add_quarters(q, T0 + 12 * H, qs, 12);
  fx_add(fx, "open-meteo", q);
  g_autoptr(WxForecast) fc = fx_blend(fx, p, T0 + 12 * H + 7 * 60);
  double want[12] = {500, 0, 0, 0, 0, 0, 0, 500, 125, 125, 125, 125};
  assert_quarters(fc, T0 + 12 * H, want, 12);
  fx_free(fx);
}

/* The even spread of a subnormal blended amount rounds blended / 4 to nearest, so the four
 * quarters can sum to MORE or LESS than blended (a few subnormal ulps), never beyond 2 ulps. */
static void
test_nowcast_rescale_spread_both_directions(void)
{
  static const double pat[4] = {0.6, 0.6, 0.6, 0.6};
  /* 3 ulps -> 0.75 rounds to 1 ulp each: sum 4 ulps, ABOVE blended */
  g_assert_cmpfloat(check_rescaled_quarters(3 * DMIN, pat), ==, 4 * DMIN);
  /* 5 ulps -> 1.25 rounds to 1 ulp each: sum 4 ulps, BELOW blended */
  g_assert_cmpfloat(check_rescaled_quarters(5 * DMIN, pat), ==, 4 * DMIN);
  /* 4 ulps: exact; 1 ulp -> 0.25 rounds to 0: sum 0; 2 ulps -> 0.5 ties to even 0: sum 0 */
  g_assert_cmpfloat(check_rescaled_quarters(4 * DMIN, pat), ==, 4 * DMIN);
  g_assert_cmpfloat(check_rescaled_quarters(DMIN, pat), ==, 0.0);
  g_assert_cmpfloat(check_rescaled_quarters(2 * DMIN, pat), ==, 0.0);
  /* a normal blended below the threshold divides exactly */
  g_assert_cmpfloat(check_rescaled_quarters(7e-10, pat), ==, 7e-10);
  /* the bound over many subnormal multiples, both signs of the error seen */
  gboolean above = FALSE, below = FALSE;
  for (int k = 1; k <= 2000; k++) {
    double s = check_rescaled_quarters(k * DMIN, pat);
    above |= s > k * DMIN;
    below |= s < k * DMIN;
    g_assert_cmpfloat(fabs(s - k * DMIN), <=, 2 * DMIN);
  }
  g_assert_true(above && below);
}

static void assert_forecast_days_in_range(const WxForecast *fc);

/* The quarter patterns that stress a rescale: near-equal quarters, big against small, tiny. */
static const double stress_patterns[][4] = {
  {0.175, 0.175, 0.175, 0.175}, {300, 300, 300, 301}, {1e-12, 2e-12, 3e-12, 4e-12},
  {500, 500, 500, 500},         {0.6, 0.6, 0.6, 0.6}, {377.97, 500, 0.76, 500},
  {0.073, 0, 0, 0},             {1e-310, 1e-310, 1e-310, 1e-310}, {0.1, 0.2, 0.3, 0.4},
};

/* Subnormal blended hours: the quarters must stay in [0, blended] (regression: 1e-323 with
 * {0.6 x4} once produced -4.94e-324 and the whole blend failed with INVALID_ARG). */
static void
test_nowcast_rescale_subnormal(void)
{
  const double dmin = 4.9406564584124654e-324;
  check_rescaled_quarters(1e-323, (double[4]){0.6, 0.6, 0.6, 0.6});
  check_rescaled_quarters(3.78e-321, (double[4]){377.97, 500, 0.76, 500});
  for (guint pat = 0; pat < G_N_ELEMENTS(stress_patterns); pat++) {
    for (int k = 1; k <= 5000; k++)
      check_rescaled_quarters(k * dmin, stress_patterns[pat]);
  }
  const double blendeds[] = {0.9999999e-9, 1e-9, 1.0000001e-9, nextafter(1e-9, 0),
                                    nextafter(1e-9, 1), DBL_MIN, nextafter(DBL_MIN, 0),
                                    nextafter(DBL_MIN, 1), 1e-300, 1e-12, 1e-6, 500.0,
                                    nextafter(500.0, 0)};
  for (guint b = 0; b < G_N_ELEMENTS(blendeds); b++) {
    for (guint pat = 0; pat < G_N_ELEMENTS(stress_patterns); pat++)
      check_rescaled_quarters(blendeds[b], stress_patterns[pat]);
  }
  /* negative zero is in range: blended -0.0 and quarters of -0.0 must not break anything */
  check_rescaled_quarters(-0.0, stress_patterns[0]);
  check_rescaled_quarters(0.3, (double[4]){-0.0, -0.0, -0.0, 0.2});
  check_rescaled_quarters(0.3, (double[4]){-0.0, -0.0, -0.0, -0.0});
  check_rescaled_quarters(-0.0, (double[4]){-0.0, -0.0, -0.0, -0.0});
}

/* Random blended amounts (mostly extreme) against random quarters: direct property test of the
 * rescale through the public API. */
static void
test_nowcast_rescale_fuzz(void)
{
  GRand *r = rng(8675309);
  const double dmin = 4.9406564584124654e-324;
  for (int iter = 0; iter < 20000; iter++) {
    double blended;
    switch (g_rand_int_range(r, 0, 5)) {
    case 0:
      blended = dmin * g_rand_int_range(r, 1, 100000);
      break;
    case 1:
      blended = ldexp(1.0, g_rand_int_range(r, -1074, 9)) * (1.0 + g_rand_double(r));
      break;
    case 2:
      blended = nextafter(1e-9, g_rand_boolean(r) ? 0.0 : 1.0);
      break;
    default:
      blended = g_rand_double(r) * 500.0;
    }
    if (blended > 500.0)
      blended = 500.0;
    double pat[4];
    for (guint k = 0; k < 4; k++) {
      switch (g_rand_int_range(r, 0, 4)) {
      case 0:
        pat[k] = dmin * g_rand_int_range(r, 0, 1000);
        break;
      case 1:
        pat[k] = ldexp(1.0, g_rand_int_range(r, -1074, 9));
        break;
      case 2:
        pat[k] = pat[k > 0 ? k - 1 : 0]; /* near-equal quarters (k = 0 copies an unset value) */
        if (k == 0)
          pat[0] = 0.175;
        break;
      default:
        pat[k] = g_rand_double(r) * 500.0;
      }
      pat[k] = CLAMP(pat[k], 0.0, 500.0);
    }
    check_rescaled_quarters(blended, pat);
  }
  g_rand_free(r);
}

/* Property: for valid in-range inputs and a valid now the only failure of the blend is
 * WX_ERROR_NOT_FOUND. The generator uses the extreme values of every range. */
static double
nasty_precip(GRand *r)
{
  static const double pool[] = {0.0, 4.9e-324, 1e-310, 1e-9, 0.05, 0.073, 0.1, 0.21, 0.37, 1.0,
                                7.6, 100.0, 499.99999999999994, 500.0,
                                /* multi-ulp subnormals: the old remainder scheme went negative */
                                2 * DMIN, 3 * DMIN, 4 * DMIN, 5 * DMIN, 8 * DMIN, 11 * DMIN,
                                47 * DMIN, 113 * DMIN, 1465 * DMIN, 1e-323, 3.78e-321,
                                DBL_MIN, 1e-300, 1e-12, 0.9999999e-9, 1.0000001e-9};
  return pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))];
}

static double
nasty_pick(GRand *r, double lo, double hi)
{
  switch (g_rand_int_range(r, 0, 6)) {
  case 0:
    return lo;
  case 1:
    return hi;
  case 2:
    return NAN;
  case 3:
    return nextafter(lo, hi);
  case 4:
    return nextafter(hi, lo);
  default:
    return rnd(r, lo, hi);
  }
}

static WxMember *
nasty_member(GRand *r, const Id *id, gint64 base)
{
  WxMember *m = new_member(id->src, id->model);
  int first = g_rand_int_range(r, -3, 6);
  int len = g_rand_int_range(r, 0, 80);
  for (int i = 0; i < len; i++) {
    WxHour h;
    wx_hour_init(&h);
    h.t_s = base + (gint64)(first + i) * H;
    h.temp_c = nasty_pick(r, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
    h.feels_c = nasty_pick(r, WX_TEMP_MIN_C, WX_TEMP_MAX_C);
    h.precip_mm = g_rand_double(r) < 0.3 ? NAN : nasty_precip(r);
    h.precip_prob = nasty_pick(r, 0, 100);
    h.cloud_pct = nasty_pick(r, 0, 100);
    h.wind_kmh = nasty_pick(r, 0, WX_WIND_MAX_KMH);
    h.gust_kmh = nasty_pick(r, 0, WX_WIND_MAX_KMH);
    h.humidity_pct = nasty_pick(r, 0, 100);
    h.wmo = g_rand_double(r) < 0.5 ? -1 : g_rand_int_range(r, 0, 100);
    /* near the ends of the supported range the builder refuses the hour: skip it */
    if (h.t_s >= WX_TIME_MIN_S && h.t_s < WX_TIME_MAX_S)
      g_assert_true(wx_member_add_hour(m, &h));
  }
  return m;
}

static void
test_fuzz_only_not_found_fails(void)
{
  GRand *r = rng(31337);
  /* places, with zones whose midnights or day counts are odd, and instants around them */
  static const struct {
    double lat, lon;
    const char *tz;
    gint64 now;
  } cases[] = {
    {47.56, -52.71, "America/St_Johns", 1194004800 + 36 * 3600},   /* 2007-11-04 */
    {-23.55, -46.63, "America/Sao_Paulo", 1455796800 + 48 * 3600}, /* 2016-02-20 */
    {23.11, -82.37, "America/Havana", 1793419200 + 24 * 3600},     /* 2026-11-01 */
    {-13.83, -171.76, "Pacific/Apia", 1325203200},                 /* 2011-12-29: the skipped day */
    {-31.55, 159.08, "Australia/Lord_Howe", 1791676800},
    {27.7, 85.3, "Asia/Kathmandu", 1791676800},
    {1.87, -157.4, "Pacific/Kiritimati", 1791676800},
    {25.7617, -80.1918, "America/New_York", 1793419200},           /* the 25 hour day */
    {51.5074, -0.1278, "Europe/London", 1792796400},
    {0.0, 0.0, "", 1791676800},
  };
  guint ok = 0, not_found = 0, with_quarters = 0;
  for (int iter = 0; iter < 2500; iter++) {
    guint c = (guint)g_rand_int_range(r, 0, G_N_ELEMENTS(cases));
    const char *tz = cases[c].tz;
    if (tz[0] != '\0' && !zone_available(tz))
      tz = "";
    g_autoptr(WxPlace) place = mk_place(cases[c].lat, cases[c].lon, tz);
    gint64 now = cases[c].now + g_rand_int_range(r, -5 * 86400, 5 * 86400);
    if (g_rand_double(r) < 0.1)
      now = g_rand_boolean(r) ? WX_TIME_MIN_S + g_rand_int_range(r, 0, 100) * 600
                              : WX_TIME_MAX_S - 1 - g_rand_int_range(r, 0, 100) * 600;
    gint64 base = now - now % H;
    WxMember *members[16];
    guint n = 0;
    for (guint k = 0; k < G_N_ELEMENTS(fuzz_ids); k++) {
      if (g_rand_double(r) < 0.5)
        members[n++] = nasty_member(r, &fuzz_ids[k], base);
    }
    /* HRRR 15-minute member: random runs of nasty amounts, some valid for now, some not */
    WxMember *q = new_member("open-meteo", "hrrr15");
    gint64 qfirst = (now - now % 900) - 900 * g_rand_int_range(r, -1, 3);
    guint nq = (guint)g_rand_int_range(r, 0, 20);
    gboolean uniform = g_rand_boolean(r);
    double u = nasty_precip(r);
    for (guint i = 0; i < nq; i++) {
      if (g_rand_double(r) < 0.03)
        continue;
      WxQuarter qq = {qfirst + (gint64)i * 900, uniform ? u : nasty_precip(r)};
      if (qq.t_s >= WX_TIME_MIN_S && qq.t_s < WX_TIME_MAX_S)
        wx_member_add_quarter(q, &qq);
    }
    members[n++] = q;
    GError *err = NULL;
    g_autoptr(WxForecast) fc = blend_raw_at(place, members, n, now, &err);
    if (fc != NULL) {
      ok++;
      assert_forecast_days_in_range(fc);
      guint nqf;
      wx_forecast_get_quarters(fc, &nqf);
      if (nqf > 0)
        with_quarters++;
    } else {
      if (err == NULL || !g_error_matches(err, WX_ERROR, WX_ERROR_NOT_FOUND))
        FAIL("iteration %d: blend failed with %s", iter, err ? err->message : "no error");
      not_found++;
      g_clear_error(&err);
    }
    for (guint i = 0; i < n; i++)
      wx_member_unref(members[i]);
  }
  g_assert_cmpuint(ok, >, 1000);
  g_assert_cmpuint(not_found, >, 10);
  g_assert_cmpuint(with_quarters, >, 100);
  g_rand_free(r);
}

/* ------------------------------------------------------------------------ */

/* TRUE when long double really is wider than double (not under valgrind, which computes it as a
 * double: then the 1 ulp check below has no reference and is skipped). */
static gboolean
have_extended_precision(void)
{
  volatile long double x = 1.0L;
  x += 1e-17L;
  return x != 1.0L;
}

/* Median ties: the mean of two adjacent values is within [a, b], also for subnormals and DBL_MAX */
static void
test_median_tie_mean_in_range(void)
{
  static const double ds[] = {0.0, 4.9e-324, 9.8e-324, 1.5e-323, 1e-310, 2.2250738585072014e-308,
                              1e-300, 0.5, 1.0, 3.0, 1e300, 8.9e307, DBL_MAX / 2, DBL_MAX};
  double w[2] = {1, 1};
  for (guint i = 0; i < G_N_ELEMENTS(ds); i++) {
    for (guint j = 0; j < G_N_ELEMENTS(ds); j++) {
      for (int sa = -1; sa <= 1; sa += 2) {
        for (int sb = -1; sb <= 1; sb += 2) {
          double v[2] = {sa * ds[i], sb * ds[j]};
          double lo = fmin(v[0], v[1]), hi = fmax(v[0], v[1]);
          double got = wm(v, w, 2);
          g_assert_true(isfinite(got));
          g_assert_cmpfloat(got, >=, lo);
          g_assert_cmpfloat(got, <=, hi);
          /* the order of the inputs does not matter */
          double vr[2] = {v[1], v[0]};
          g_assert_cmpfloat(wm(vr, w, 2), ==, got);
          /* correct to one unit in the last place against a wider type */
          if (have_extended_precision()) {
            long double ref = ((long double)v[0] + (long double)v[1]) / 2.0L;
            double ulp = fabs(nextafter(got, INFINITY) - got);
            if (isfinite(ulp))
              g_assert_true(fabsl((long double)got - ref) <= (long double)ulp);
          }
        }
      }
    }
  }
  /* the named cases */
  double a[2] = {4.9e-324, 4.9e-324};
  g_assert_cmpfloat(wm(a, w, 2), ==, 4.9e-324);
  double b[2] = {-DBL_MAX, DBL_MAX};
  g_assert_cmpfloat(wm(b, w, 2), ==, 0.0);
  double c[2] = {DBL_MAX, DBL_MAX};
  g_assert_cmpfloat(wm(c, w, 2), ==, DBL_MAX);
  double d[2] = {0.0, DBL_MAX};
  g_assert_cmpfloat(wm(d, w, 2), ==, DBL_MAX / 2);
  double e[2] = {-4.9e-324, -9.8e-324};
  g_assert_cmpfloat(wm(e, w, 2), >=, -9.8e-324);
  g_assert_cmpfloat(wm(e, w, 2), <=, -4.9e-324);
  /* three values where the tie is between the lower two, with unequal weights */
  double v3[3] = {4.9e-324, 4.9e-324, 1.0};
  double w3[3] = {1, 1, 2};
  g_assert_cmpfloat(wm(v3, w3, 3), >=, 4.9e-324);
  g_assert_cmpfloat(wm(v3, w3, 3), <=, 1.0);
  /* random bit patterns */
  GRand *r = rng(5);
  for (int iter = 0; iter < 200000; iter++) {
    guint64 bits[2] = {((guint64)g_rand_int(r) << 32) | g_rand_int(r),
                       ((guint64)g_rand_int(r) << 32) | g_rand_int(r)};
    if (iter % 2 == 0) { /* bias to subnormals */
      bits[0] &= 0x800FFFFFFFFFFFFFULL;
      bits[1] &= 0x800FFFFFFFFFFFFFULL;
    }
    double v[2];
    memcpy(v, bits, sizeof v);
    if (!isfinite(v[0]) || !isfinite(v[1]))
      continue;
    double got = wm(v, w, 2);
    g_assert_cmpfloat(got, >=, fmin(v[0], v[1]));
    g_assert_cmpfloat(got, <=, fmax(v[0], v[1]));
  }
  g_rand_free(r);
}

/* ------------------------------------------------------------------------ */

/* First instants of local days, from an independent reference (a brute-force scan at one-minute
 * resolution with Python's zoneinfo of the same zone database): the first midnight when the clock
 * is set back across midnight, also shortly after it. */
static void
assert_day_starts(const char *tz, gint64 first_t, guint n_hours, const gint64 *starts, guint n)
{
  SKIP_WITHOUT_ZONE(tz);
  g_autofree WxBlendHour *a = daily_hours(first_t, n_hours, NULL, NULL);
  WxDay d[WX_DAILY_MAX_DAYS];
  guint nd = days_of(tz, a, n_hours, d);
  if (nd != n)
    FAIL("%s: %u days, wanted %u", tz, nd, n);
  for (guint i = 0; i < nd; i++) {
    if (d[i].start_s != starts[i])
      FAIL("%s day %u starts %" G_GINT64_FORMAT ", wanted %" G_GINT64_FORMAT, tz, i, d[i].start_s,
           starts[i]);
  }
}

static void
test_daily_first_midnight(void)
{
  SKIP_WITHOUT_ZONE("America/St_Johns");
  SKIP_WITHOUT_ZONE("America/Goose_Bay");
  SKIP_WITHOUT_ZONE("America/Moncton");
  SKIP_WITHOUT_ZONE("America/Sao_Paulo");
  /* St. John's 2007-11-04: 00:00 NDT (02:30Z), at 00:01 the clock went back to 23:01 NST */
  const gint64 sj[] = {1193970600, 1194057000, 1194143400, 1194233400, 1194319800};
  assert_day_starts("America/St_Johns", 1194004800, 120, sj, 5);
  const gint64 gb[] = {1193972400, 1194058800, 1194145200, 1194235200, 1194321600};
  assert_day_starts("America/Goose_Bay", 1194004800, 120, gb, 5);
  const gint64 mo[] = {1161831600, 1161918000, 1162004400, 1162090800, 1162180800};
  assert_day_starts("America/Moncton", 1161864000, 120, mo, 5);
  /* Sao Paulo 2016-02-21: 00:00 BRST (02:00Z) was set back to 23:00 BRT at once: the day starts
   * an hour later, at 00:00 BRT */
  const gint64 sp[] = {1455760800, 1455847200, 1455933600, 1456023600, 1456110000};
  assert_day_starts("America/Sao_Paulo", 1455796800, 120, sp, 5);
}

/* Sweeps a list of zones over several instants: every emitted day starts at the first instant
 * of its local date (scanned back minute by minute), the days ascend, and wx_forecast_new
 * accepts them. */
static gint64
first_instant_back_scan(GTimeZone *tz, gint64 start)
{
  gint64 date = 0;
  {
    gint i = g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, start);
    date = (start + g_time_zone_get_offset(tz, i)) / 86400;
  }
  gint64 first = start;
  for (gint64 t = start - 60; t > start - 2 * 86400; t -= 60) {
    gint i = g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, t);
    if ((t + g_time_zone_get_offset(tz, i)) / 86400 == date)
      first = t;
  }
  return first;
}

static void
sweep_zone(const char *name, const gint64 *firsts, guint n_firsts)
{
  GTimeZone *tz = g_time_zone_new_identifier(name);
  if (tz == NULL)
    return; /* the database of this machine lacks it */
  g_autoptr(WxPlace) place = mk_place(0.0, 0.0, name);
  for (guint f = 0; f < n_firsts; f++) {
    g_autofree WxBlendHour *a = daily_hours(firsts[f], 120, NULL, NULL);
    WxDay d[WX_DAILY_MAX_DAYS];
    guint nd = days_of(name, a, 120, d);
    g_assert_cmpuint(nd, >=, 3); /* Apia skips a day */
    for (guint i = 0; i < nd; i++) {
      gint64 got = d[i].start_s;
      gint64 want = first_instant_back_scan(tz, got);
      if (got != want)
        FAIL("%s from %" G_GINT64_FORMAT ": day %u starts %" G_GINT64_FORMAT ", the first instant of its date is %" G_GINT64_FORMAT,
             name, firsts[f], i, got, want);
    }
    GError *err = NULL;
    g_autoptr(WxForecast) fc = wx_forecast_new(place, firsts[f], a, 120, NULL, 0, d, nd, NULL, 0, &err);
    g_assert_no_error(err);
    g_assert_nonnull(fc);
  }
  g_time_zone_unref(tz);
}

static const char *const sweep_zones[] = {
  "America/St_Johns", "America/Goose_Bay", "America/Moncton", "America/Halifax", "America/Havana",
  "America/Sao_Paulo", "America/Asuncion", "America/Santiago", "America/Miami", "America/New_York",
  "America/Los_Angeles", "America/Anchorage", "America/Caracas", "America/Godthab", "America/Scoresbysund",
  "Pacific/Honolulu", "Pacific/Apia", "Pacific/Kiritimati", "Pacific/Chatham", "Pacific/Auckland",
  "Pacific/Norfolk", "Pacific/Tongatapu", "Pacific/Fiji", "Pacific/Pago_Pago", "Australia/Lord_Howe",
  "Australia/Adelaide", "Australia/Eucla", "Australia/Sydney", "Asia/Kolkata", "Asia/Kathmandu",
  "Asia/Tehran", "Asia/Beirut", "Asia/Gaza", "Asia/Pyongyang", "Asia/Tokyo", "Africa/Cairo",
  "Africa/Casablanca", "Africa/Windhoek", "Europe/London", "Europe/Dublin", "Europe/Moscow",
  "Europe/Istanbul", "Antarctica/Troll", "Etc/GMT+12", "Etc/GMT-14", "Atlantic/Azores",
};

static void
test_daily_zone_sweep(void)
{
  static const gint64 firsts[] = {
    1194004800, /* 2007-11-02T12:00Z: St. John's back-step */
    1161864000, /* 2006-10-26T12:00Z: Moncton */
    1455796800, /* 2016-02-18T12:00Z: Sao Paulo */
    1445000000 - 1445000000 % 3600, /* 2015-10-16: Sao Paulo midnight gap */
    1793419200, /* 2026-10-31T12:00Z: Northern autumn */
    1772859600, /* 2026-03-07: Northern spring */
    1791676800, /* 2026-10-11 */
    1790000000 - 1790000000 % 3600, /* 2026-09-21 */
    1325203200, /* 2011-12-29: Apia skips a day */
    1230768000, /* 2009-01-01 */
  };
  for (guint z = 0; z < G_N_ELEMENTS(sweep_zones); z++)
    sweep_zone(sweep_zones[z], firsts, G_N_ELEMENTS(firsts));
}

/* All zones of the zone database (those with a '/') when it can be listed. */
static void
test_daily_zone_sweep_all(void)
{
  gchar *zi = NULL;
  if (!g_file_get_contents("/usr/share/zoneinfo/tzdata.zi", &zi, NULL, NULL)) {
    g_test_skip("no /usr/share/zoneinfo/tzdata.zi");
    return;
  }
  static const gint64 firsts[] = {1194004800, 1161864000, 1455796800, 1793419200, 1772859600};
  guint count = 0;
  gchar **lines = g_strsplit(zi, "\n", -1);
  for (guint i = 0; lines[i] != NULL; i++) {
    gchar **f = g_strsplit(lines[i], " ", 3);
    const char *name = NULL;
    if (f[0] != NULL && f[1] != NULL && strcmp(f[0], "Z") == 0)
      name = f[1];
    else if (f[0] != NULL && f[1] != NULL && f[2] != NULL && strcmp(f[0], "L") == 0)
      name = f[2];
    if (name != NULL && strchr(name, '/') != NULL) {
      sweep_zone(name, firsts, G_N_ELEMENTS(firsts));
      count++;
    }
    g_strfreev(f);
  }
  g_assert_cmpuint(count, >, 300);
  g_strfreev(lines);
  g_free(zi);
}

/* ------------------------------------------------------------------------ */

/* THE INTERVAL GUARD: g_time_zone_find_interval() documents -1 as a failure value, which must
 * never reach g_time_zone_get_offset(). GLib does not return it for G_TIME_TYPE_UNIVERSAL (probed
 * here over many zones and instants), so the guard is exercised through its own function. A
 * negative interval gives offset 0 and no critical (the fatal-critical test harness would abort
 * on one); valid intervals give GLib's offsets. */
static void
test_daily_interval_guard(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  SKIP_WITHOUT_ZONE("America/St_Johns");
  SKIP_WITHOUT_ZONE("Asia/Kolkata");
  static const char *const zones[] = {"UTC", "America/New_York", "America/St_Johns", "Asia/Kolkata",
                                      "Pacific/Apia", "Africa/Casablanca", "Antarctica/Troll",
                                      "Europe/London", "Australia/Lord_Howe"};
  static const gint64 instants[] = {WX_TIME_MIN_S, WX_TIME_MIN_S + 86400, 2000000000, T0,
                                    WX_TIME_MAX_S - 1};
  for (guint z = 0; z < G_N_ELEMENTS(zones); z++) {
    GTimeZone *tz = g_time_zone_new_identifier(zones[z]);
    if (tz == NULL)
      continue;
    for (guint i = 0; i < G_N_ELEMENTS(instants); i++) {
      gint interval = g_time_zone_find_interval(tz, G_TIME_TYPE_UNIVERSAL, instants[i]);
      g_assert_cmpint(interval, >=, 0); /* the failure value does not occur for UNIVERSAL */
      g_assert_cmpint(wx_daily_interval_offset(tz, interval), ==,
                      g_time_zone_get_offset(tz, interval));
    }
    g_assert_cmpint(wx_daily_interval_offset(tz, -1), ==, 0);
    g_assert_cmpint(wx_daily_interval_offset(tz, -2), ==, 0);
    g_assert_cmpint(wx_daily_interval_offset(tz, G_MININT), ==, 0);
    g_time_zone_unref(tz);
  }
  GTimeZone *ny = g_time_zone_new_identifier("America/New_York");
  g_assert_cmpint(wx_daily_interval_offset(ny, g_time_zone_find_interval(ny, G_TIME_TYPE_UNIVERSAL, T0)),
                  ==, -4 * 3600);
  g_time_zone_unref(ny);
  ASSERT_CRITICAL("wx_daily_interval_offset", g_assert_cmpint(wx_daily_interval_offset(NULL, 0), ==, 0));
  ASSERT_CRITICAL("wx_daily_interval_offset", g_assert_cmpint(wx_daily_interval_offset(NULL, -1), ==, 0));
}

static void
test_daily_day_sum_clamp(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  g_autoptr(WxPlace) p = miami();
  /* 2026-11-01 is 25 hours long in New York (1793419200 = 2026-10-31T04:00:00Z .. day starts at
   * 1793505600); every hour at the hourly maximum: 12500 mm */
  gint64 first = 1793505600 - 24 * H;
  g_autofree WxBlendHour *a = daily_hours(first, 24 + 25 + 24, NULL, NULL);
  for (guint i = 0; i < 24 + 25 + 24; i++) {
    a[i].precip_mm = 500.0;
    a[i].precip_mm_max = 500.0;
    a[i].precip_prob = 100.0;
  }
  WxDay d[WX_DAILY_MAX_DAYS];
  g_assert_cmpuint(days_of("America/New_York", a, 24 + 25 + 24, d), ==, 3);
  g_assert_cmpint(d[1].start_s, ==, 1793505600);
  g_assert_cmpint(d[2].start_s, ==, 1793505600 + 25 * H);
  ASSERT_NEAR(d[0].precip_mm, 12000.0); /* 24 hours: exactly the maximum, not clamped */
  ASSERT_NEAR(d[1].precip_mm, WX_PRECIP_MAX_MM_DAY); /* 25 hours: 12500, clamped */
  g_assert_cmpint(d[1].condition, ==, WX_COND_HEAVY_RAIN);
  /* the forecast keeps the number and the condition */
  GError *err = NULL;
  g_autoptr(WxForecast) fc = wx_forecast_new(p, NOW_S, a, 73, NULL, 0, d, 3, NULL, 0, &err);
  g_assert_no_error(err);
  guint n;
  const WxDay *kept = wx_forecast_get_days(fc, &n);
  g_assert_cmpuint(n, ==, 3);
  g_assert_true(isfinite(kept[1].precip_mm));
  ASSERT_NEAR(kept[1].precip_mm, WX_PRECIP_MAX_MM_DAY);
  g_assert_cmpint(kept[1].condition, ==, WX_COND_HEAVY_RAIN);
  /* a 23 hour day below the cap is not touched */
  g_autofree WxBlendHour *b = daily_hours(1772946000 - 24 * H, 24 + 23 + 24, NULL, NULL); /* 2026-03-08 */
  for (guint i = 0; i < 24 + 23 + 24; i++)
    b[i].precip_mm = 500.0;
  g_assert_cmpuint(days_of("America/New_York", b, 24 + 23 + 24, d), ==, 3);
  ASSERT_NEAR(d[1].precip_mm, 11500.0);
}

/* ------------------------------------------------------------------------ */

static void
test_rain_hours_bound(void)
{
  /* (a place is not needed) */
  WxRainOutlook o;
  /* a hand-built forecast with more hours than the sample list holds: critical, DRY, and no
   * write beyond the list (ASan) */
  static WxBlendHour big[WX_FORECAST_MAX_HOURS + 200];
  for (guint i = 0; i < G_N_ELEMENTS(big); i++)
    big[i] = bh(T0 + (gint64)i * H, 20, 5.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  WxForecast hand;
  memset(&hand, 0, sizeof hand);
  hand.hours = big;
  hand.n_hours = G_N_ELEMENTS(big);
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(&hand, T0 + 12 * H, &o));
  assert_dry(&o);
  hand.n_hours = WX_FORECAST_MAX_HOURS + 1;
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(&hand, T0 + 12 * H, &o));
  assert_dry(&o);
  hand.n_hours = G_MAXUINT;
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(&hand, T0 + 12 * H, &o));
  assert_dry(&o);
  /* exactly the maximum works, with and without nowcast quarters */
  hand.n_hours = WX_FORECAST_MAX_HOURS;
  wx_rain_outlook(&hand, T0 + 12 * H + 7 * 60, &o);
  assert_outlook(&o, WX_RAIN_NOW, T0, 0, FALSE, T0, 5.0, 90.0);
  WxQuarter q[12];
  for (guint i = 0; i < 12; i++) {
    q[i].t_s = T0 + 12 * H + (gint64)i * 900;
    q[i].precip_mm = 1.0;
  }
  hand.quarters = q;
  hand.n_quarters = 12;
  wx_rain_outlook(&hand, T0 + 12 * H + 7 * 60, &o);
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);
  g_assert_cmpint(o.start_s, ==, T0);
  g_assert_cmpint(o.ends_known, ==, FALSE);
}

/* ------------------------------------------------------------------------ */
/* hand-built hostile structs: totality and memory safety of every function  */
/* that takes a caller-built forecast / hour array (run under ASan/UBSan)    */
/* ------------------------------------------------------------------------ */

/* wx_rain_outlook() on an unusable forecast: one critical, the DRY outlook, no memory error. */
static void
expect_rain_critical(const WxForecast *f, gint64 now)
{
  WxRainOutlook o;
  memset(&o, 0xAB, sizeof o);
  ASSERT_CRITICAL("wx_rain_outlook", wx_rain_outlook(f, now, &o));
  assert_dry(&o);
}

static WxForecast
hand_forecast(const WxBlendHour *hours, guint n_hours, const WxQuarter *quarters, guint n_quarters)
{
  WxForecast f;
  memset(&f, 0, sizeof f);
  f.hours = hours;
  f.n_hours = n_hours;
  f.quarters = quarters;
  f.n_quarters = n_quarters;
  return f;
}

static void
test_rain_hostile_hours(void)
{
  static WxBlendHour hrs[WX_FORECAST_MAX_HOURS];
  static WxQuarter qs[WX_FORECAST_MAX_QUARTERS + 1];
  const gint64 now = 1791720900; /* 12:15Z */
  qs[0] = (WxQuarter){now, 0.2};

  /* the reported overflow: the same hour 205, 206 and 400 times against a one quarter span */
  guint counts[] = {2, 205, 206, 399, 400};
  for (guint c = 0; c < G_N_ELEMENTS(counts); c++) {
    for (guint i = 0; i < counts[c]; i++)
      hrs[i] = bh(1791720000, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
    WxForecast f = hand_forecast(hrs, counts[c], qs, 1);
    expect_rain_critical(&f, now);
  }
  /* strictly ascending but unaligned (11:30:00 + i seconds), now 12:00 */
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++)
    hrs[i] = bh(1791719400 + (gint64)i, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  WxForecast f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, qs, 1);
  expect_rain_critical(&f, 1791720000);
  f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, NULL, 0);
  expect_rain_critical(&f, 1791720000);

  /* descending, and a duplicate in the middle of an otherwise good list */
  for (guint i = 0; i < 10; i++)
    hrs[i] = bh(T0 + (30 - (gint64)i) * H, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  f = hand_forecast(hrs, 10, NULL, 0);
  expect_rain_critical(&f, NOW_S);
  for (guint i = 0; i < 10; i++)
    hrs[i] = bh(T0 + (10 + (gint64)i) * H, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  hrs[6].t_s = hrs[5].t_s;
  f = hand_forecast(hrs, 10, NULL, 0);
  expect_rain_critical(&f, NOW_S);

  /* out of the time range, one bad hour in a good list */
  static const gint64 bad_t[] = {0, -3600, G_MININT64, G_MAXINT64, WX_TIME_MIN_S - 3600,
                                 WX_TIME_MAX_S, WX_TIME_MAX_S + 3600, G_MAXINT64 - 3599};
  for (guint b = 0; b < G_N_ELEMENTS(bad_t); b++) {
    for (guint pos = 0; pos < 2; pos++) {
      for (guint i = 0; i < 4; i++)
        hrs[i] = bh(T0 + (10 + (gint64)i) * H, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
      hrs[pos == 0 ? 0 : 3].t_s = bad_t[b];
      f = hand_forecast(hrs, 4, NULL, 0);
      expect_rain_critical(&f, NOW_S);
    }
  }
  /* NULL arrays with counts */
  f = hand_forecast(NULL, 1, NULL, 0);
  expect_rain_critical(&f, NOW_S);
  for (guint i = 0; i < 3; i++)
    hrs[i] = bh(T0 + (10 + (gint64)i) * H, 20, 1.0, 90, 50, WX_COND_RAIN, TRUE, 1);
  f = hand_forecast(hrs, 3, NULL, 1);
  expect_rain_critical(&f, NOW_S);
  /* no hours at all, NULL array: fine */
  WxRainOutlook o;
  f = hand_forecast(NULL, 0, NULL, 0);
  wx_rain_outlook(&f, NOW_S, &o);
  assert_dry(&o);

  /* the worst valid case for the sample list: 400 hours and a ONE quarter span in the middle of
   * an hour (that hour is cut in two): 401 hour samples + 1 quarter sample, below the capacity */
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++)
    hrs[i] = bh(T0 + (12 + (gint64)i) * H, 20, 0.5, 90, 50, WX_COND_RAIN, TRUE, 1);
  qs[0] = (WxQuarter){T0 + 12 * H + 900, 0.2};
  f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, qs, 1);
  wx_rain_outlook(&f, T0 + 12 * H + 1200, &o);
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);
  g_assert_cmpint(o.start_s, ==, T0 + 12 * H); /* the wet part of the hour before the quarter */
  g_assert_false(o.ends_known);                /* wet to the end of the 48 h horizon */

  /* the maximum number of quarters, all valid */
  for (guint i = 0; i < WX_FORECAST_MAX_QUARTERS; i++)
    qs[i] = (WxQuarter){T0 + (gint64)i * 900, 1.0};
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++)
    hrs[i] = bh(T0 + (gint64)i * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, qs, WX_FORECAST_MAX_QUARTERS);
  wx_rain_outlook(&f, T0 + 12 * H + 7 * 60, &o);
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);
  g_assert_cmpint(o.start_s, ==, T0 + 12 * H);
  g_assert_cmpint(o.end_s, ==, T0 + 14 * H + 900); /* 9 quarters: 12:00 .. 14:00 start */
  g_assert_true(o.ends_known);
  /* one more than the limit */
  for (guint i = 0; i < WX_FORECAST_MAX_QUARTERS + 1; i++)
    qs[i] = (WxQuarter){T0 + (gint64)i * 900, 1.0};
  f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, qs, WX_FORECAST_MAX_QUARTERS + 1);
  expect_rain_critical(&f, T0 + 12 * H + 7 * 60);
  f = hand_forecast(hrs, WX_FORECAST_MAX_HOURS, qs, G_MAXUINT);
  expect_rain_critical(&f, T0 + 12 * H + 7 * 60);
}

static void
test_rain_hostile_quarters(void)
{
  static WxBlendHour hrs[8];
  for (guint i = 0; i < G_N_ELEMENTS(hrs); i++)
    hrs[i] = bh(T0 + (10 + (gint64)i) * H, 20, 0.0, 10, 50, WX_COND_CLEAR, TRUE, 1);
  const gint64 q0 = T0 + 12 * H;
  WxQuarter good[4] = {{q0, 0.1}, {q0 + 900, 0.1}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}};
  WxRainOutlook o;
  WxForecast f = hand_forecast(hrs, G_N_ELEMENTS(hrs), good, 4);
  wx_rain_outlook(&f, q0 + 420, &o); /* the control is accepted */
  g_assert_cmpint(o.state, ==, WX_RAIN_NOW);

  struct {
    const char *what;
    WxQuarter q[4];
  } cases[] = {
    {"unaligned", {{q0 + 1, 0.1}, {q0 + 901, 0.1}, {q0 + 1801, 0.1}, {q0 + 2701, 0.1}}},
    {"duplicate", {{q0, 0.1}, {q0 + 900, 0.1}, {q0 + 900, 0.1}, {q0 + 2700, 0.1}}},
    {"descending", {{q0 + 2700, 0.1}, {q0 + 1800, 0.1}, {q0 + 900, 0.1}, {q0, 0.1}}},
    {"NaN", {{q0, 0.1}, {q0 + 900, NAN}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}}},
    {"inf", {{q0, 0.1}, {q0 + 900, INFINITY}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}}},
    {"negative", {{q0, 0.1}, {q0 + 900, -0.001}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}}},
    {"above max", {{q0, 0.1}, {q0 + 900, 500.5}, {q0 + 1800, 0.1}, {q0 + 2700, 0.1}}},
    {"time zero", {{0, 0.1}, {900, 0.1}, {1800, 0.1}, {2700, 0.1}}},
    {"time max", {{WX_TIME_MAX_S, 0.1}, {WX_TIME_MAX_S + 900, 0.1}, {WX_TIME_MAX_S + 1800, 0.1}, {WX_TIME_MAX_S + 2700, 0.1}}},
    {"time int64 max", {{G_MAXINT64, 0.1}, {G_MAXINT64, 0.1}, {G_MAXINT64, 0.1}, {G_MAXINT64, 0.1}}},
    {"time int64 min", {{G_MININT64, 0.1}, {G_MININT64 + 900, 0.1}, {q0, 0.1}, {q0 + 900, 0.1}}},
  };
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++) {
    f = hand_forecast(hrs, G_N_ELEMENTS(hrs), cases[c].q, 4);
    expect_rain_critical(&f, q0 + 420);
  }
  /* -0.0 and the exact maximum are valid amounts */
  WxQuarter edge[4] = {{q0, -0.0}, {q0 + 900, 500.0}, {q0 + 1800, 0.0}, {q0 + 2700, 4.9e-324}};
  f = hand_forecast(hrs, G_N_ELEMENTS(hrs), edge, 4);
  wx_rain_outlook(&f, q0 + 420, &o);
  g_assert_cmpint(o.state, ==, WX_RAIN_EXPECTED);
  ASSERT_NEAR(o.peak_mm_h, 2000.0);
}

/* A 128 bit integer for overflow-free reference arithmetic (a GCC extension). */
__extension__ typedef __int128 wide_t;

/* wx_forecast_now(): total for any hand-built hours (unsorted, duplicated, unaligned, out of
 * range, extreme now); in particular no signed overflow in the time arithmetic. */
static void
test_forecast_now_hostile(void)
{
  WxBlendHour hs[4];
  WxBlendHour out;
  WxForecast f;
  static const gint64 nows[] = {0, -1, G_MININT64, G_MAXINT64, G_MAXINT64 - 1, G_MININT64 + 1,
                                WX_TIME_MIN_S, WX_TIME_MAX_S, T0};
  static const gint64 ts[] = {0, 1, -1, G_MININT64, G_MAXINT64, G_MAXINT64 - 10, G_MININT64 + 3589,
                              T0, T0 + 1, T0 - 1, T0 + 3599, T0 + 3600};
  guint hits = 0;
  for (guint a = 0; a < G_N_ELEMENTS(ts); a++) {
    for (guint b = 0; b < G_N_ELEMENTS(ts); b++) {
      hs[0] = bh(ts[a], 10, 1.0, 50, 20, WX_COND_CLEAR, TRUE, 1);
      hs[1] = bh(ts[b], 30, 2.0, 60, 40, WX_COND_RAIN, TRUE, 2);
      hs[2] = bh(ts[a], NAN, INFINITY, -1, 1e300, WX_COND_COUNT, TRUE, 255);
      hs[3] = bh(ts[b], DBL_MAX, NAN, NAN, -0.0, (WxCondition)G_MAXINT, FALSE, 0);
      f = hand_forecast(NULL, 0, NULL, 0);
      f.hours = hs;
      f.n_hours = 4;
      for (guint n = 0; n < G_N_ELEMENTS(nows); n++) {
        WxBlendHour sentinel;
        memset(&sentinel, 0x5a, sizeof sentinel);
        out = sentinel;
        gboolean got = wx_forecast_now(&f, nows[n], &out);
        /* a bucket contains now iff 0 <= now - t < 3600, computed without overflow */
        gboolean want = FALSE;
        for (guint k = 0; k < 4 && !want; k++) {
          wide_t d = (wide_t)nows[n] - (wide_t)hs[k].t_s;
          want = d >= 0 && d < 3600;
        }
        g_assert_cmpint(got, ==, want);
        if (got) {
          hits++;
          g_assert_cmpint(out.t_s, ==, nows[n]);
        } else {
          g_assert_cmpint(memcmp(&out, &sentinel, sizeof out), ==, 0);
        }
      }
    }
  }
  g_assert_cmpuint(hits, >, 20);
  /* the regression of the signed difference: now = INT64_MAX against a bucket at INT64_MIN
   * (now - t wraps to -1, which a signed comparison would take for "inside the hour") */
  hs[0] = bh(G_MININT64, 10, 1.0, 50, 20, WX_COND_CLEAR, TRUE, 1);
  f = hand_forecast(hs, 1, NULL, 0);
  g_assert_false(wx_forecast_now(&f, G_MAXINT64, &out));
  /* a following bucket whose time stamp wraps around is not "3600 s later" in the sense of the
   * arithmetic, and one that really is later is used */
  hs[0] = bh(G_MAXINT64 - 10, 10, 1.0, 50, 20, WX_COND_CLEAR, TRUE, 1);
  hs[1] = bh(G_MININT64 + 3589, 30, 2.0, 60, 40, WX_COND_RAIN, TRUE, 2);
  f = hand_forecast(hs, 2, NULL, 0);
  g_assert_true(wx_forecast_now(&f, G_MAXINT64, &out));
  g_assert_true(isfinite(out.temp_c));
  /* NULL hours with a count */
  f = hand_forecast(NULL, 1, NULL, 0);
  ASSERT_CRITICAL("wx_forecast_now", g_assert_false(wx_forecast_now(&f, NOW_S, &out)));
}

/* wx_daily_build() with hostile values (not times: those are guarded with criticals): NaN, inf,
 * huge, negative, garbage conditions and member counts must never crash, overrun or raise a
 * critical, and every produced condition is valid. */
static void
test_daily_hostile_values(void)
{
  static const double pool[] = {NAN, INFINITY, -INFINITY, DBL_MAX, -DBL_MAX, -0.0, 0.0, 4.9e-324,
                                1e300, -1e300, 100.0, -1.0, 500.0, 12.5, 87.5, 40.0, 50.0, 1.0};
  GRand *r = rng(1234);
  static WxBlendHour hs[WX_FORECAST_MAX_HOURS];
  for (int iter = 0; iter < 300; iter++) {
    guint n = (guint)g_rand_int_range(r, 0, WX_FORECAST_MAX_HOURS + 1);
    gint64 first = T0 + (gint64)g_rand_int_range(r, -100, 100) * H;
    for (guint i = 0; i < n; i++) {
      hs[i] = bh(first + (gint64)i * H, pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))],
                 pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))],
                 pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))],
                 pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))],
                 (WxCondition)g_rand_int_range(r, -5, WX_COND_COUNT + 5), g_rand_boolean(r),
                 (guint8)g_rand_int_range(r, 0, 256));
    }
    WxDay d[WX_DAILY_MAX_DAYS];
    memset(d, 0, sizeof d);
    guint nd = wx_daily_build(iter % 3 == 0 ? "America/New_York" : NULL, n > 0 ? hs : NULL, n,
                              first + (gint64)g_rand_int_range(r, -10, 300) * H, d);
    g_assert_cmpuint(nd, <=, WX_DAILY_MAX_DAYS);
    for (guint i = 0; i < nd; i++) {
      g_assert_cmpint(d[i].condition, >=, 0);
      g_assert_cmpint(d[i].condition, <, WX_COND_COUNT);
      if (i > 0)
        g_assert_cmpint(d[i].start_s, >, d[i - 1].start_s);
    }
  }
  g_rand_free(r);
}

/* wx_condition_derive() with a hostile vote list (any int, many) and wx_is_wet_hour() with any
 * double. */
static void
test_condition_hostile(void)
{
  int votes[WX_BLEND_MAX_MEMBERS];
  static const int pool[] = {G_MININT, G_MAXINT, -1, 0, 95, 100, 1000, -1000, 45, 71};
  GRand *r = rng(77);
  for (int iter = 0; iter < 5000; iter++) {
    guint n = (guint)g_rand_int_range(r, 0, WX_BLEND_MAX_MEMBERS + 1);
    for (guint i = 0; i < n; i++)
      votes[i] = pool[g_rand_int_range(r, 0, G_N_ELEMENTS(pool))];
    WxConditionInput in = {iter % 2 ? NAN : -INFINITY, INFINITY, DBL_MAX, iter % 3 ? NAN : -DBL_MAX,
                           n > 0 ? votes : NULL, n};
    WxCondition c = wx_condition_derive(&in);
    g_assert_cmpint(c, >=, 0);
    g_assert_cmpint(c, <, WX_COND_COUNT);
  }
  g_assert_false(wx_is_wet_hour(-INFINITY, NAN));
  g_assert_true(wx_is_wet_hour(INFINITY, NAN));
  g_assert_true(wx_is_wet_hour(DBL_MAX, INFINITY));
  g_assert_false(wx_is_wet_hour(DBL_MAX, -INFINITY));
  g_rand_free(r);
}

/* A hand-built hrrr15 member with the maximum number of quarters, starting far before now and
 * ending far after: the blend takes the nowcast from the quarter containing now. */
static void
test_blend_hostile_nowcast_member(void)
{
  g_autoptr(WxPlace) p = miami();
  Vals ec = vnone();
  ec.temp = 20;
  ec.precip = 0.4;
  g_autoptr(WxMember) real = mk_member("open-meteo", "ecmwf", T0 + 9 * H, 40, &ec);
  static WxQuarter qs[WX_MEMBER_MAX_QUARTERS + 1]; /* the extra one keeps the long list valid */
  for (guint i = 0; i < WX_MEMBER_MAX_QUARTERS + 1; i++)
    qs[i] = (WxQuarter){T0 - 100 * 900 + (gint64)i * 900, 0.1};
  WxMember q15 = raw_member("open-meteo", "hrrr15", NULL, 0, qs, WX_MEMBER_MAX_QUARTERS);
  WxMember *list[] = {real, &q15};
  GError *err = NULL;
  g_autoptr(WxForecast) fc = blend_raw_at(p, list, 2, T0 + 12 * H + 7 * 60, &err);
  g_assert_no_error(err);
  guint nq;
  wx_forecast_get_quarters(fc, &nq);
  g_assert_cmpuint(nq, ==, WX_BLEND_MAX_QUARTERS);
  /* the same member one quarter too long is garbage as a whole: no nowcast */
  WxMember big = raw_member("open-meteo", "hrrr15", NULL, 0, qs, WX_MEMBER_MAX_QUARTERS + 1);
  WxMember *list2[] = {real, &big};
  g_autoptr(WxForecast) fc2 = blend_raw_at(p, list2, 2, T0 + 12 * H + 7 * 60, &err);
  g_assert_no_error(err);
  wx_forecast_get_quarters(fc2, &nq);
  g_assert_cmpuint(nq, ==, 0);
}

/* THE TIMEZONE RULE: looked up only if the name has a '/' (and a safe shape), else UTC; no
 * critical for any string. Each row: the zone string and the start of the local day that
 * contains 2026-10-13T00:00:00Z in the zone the rule resolves to (hard-coded; computed with
 * Python's zoneinfo / `date`). */
#define UTC_DAY_START G_GINT64_CONSTANT(1791849600)
static void
test_daily_timezone_rule(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  SKIP_WITHOUT_ZONE("Asia/Kolkata");
  SKIP_WITHOUT_ZONE("Australia/Lord_Howe");
  SKIP_WITHOUT_ZONE("Asia/Tokyo");
  SKIP_WITHOUT_ZONE("Etc/GMT-14");
  static const struct {
    const char *tz;
    gint64 day_start;
  } table[] = {
    {"UTC", UTC_DAY_START},
    {"Etc/UTC", UTC_DAY_START},
    {"America/New_York", 1791777600},     /* UTC-4: 2026-10-12T04:00Z */
    {"Asia/Kolkata", 1791829800},         /* UTC+5:30 */
    {"Australia/Lord_Howe", 1791810000},  /* UTC+11 */
    {"Asia/Tokyo", 1791817200},           /* UTC+9 */
    {"Etc/GMT-14", 1791799200},           /* UTC+14 */
    /* legacy bare aliases and non-zone files of the database have no '/': UTC */
    {"Japan", UTC_DAY_START},
    {"Singapore", UTC_DAY_START},
    {"EST5EDT", UTC_DAY_START},
    {"Cuba", UTC_DAY_START},
    {"leapseconds", UTC_DAY_START},
    {"tzdata.zi", UTC_DAY_START},
    {"zone.tab", UTC_DAY_START},
    {"posixrules", UTC_DAY_START},
    {"localtime", UTC_DAY_START},
    {"GMT+5", UTC_DAY_START},
    {"Z", UTC_DAY_START},
    {"+05:00", UTC_DAY_START},
    {"", UTC_DAY_START},
    {NULL, UTC_DAY_START},
    /* a '/' but not a zone, or a bad shape: UTC */
    {"America/Nowhere", UTC_DAY_START},
    {"America/Argentina", UTC_DAY_START}, /* a directory */
    {"asia/tokyo", UTC_DAY_START},        /* names are case sensitive */
    {"Asia/Tokyo/", UTC_DAY_START},
    {"/Asia/Tokyo", UTC_DAY_START},
    {"/etc/passwd", UTC_DAY_START},
    {"../x", UTC_DAY_START},
    {"Asia/../Asia/Tokyo", UTC_DAY_START},
    {"Asia//Tokyo", UTC_DAY_START},
    {"Asia/Tokyo\n", UTC_DAY_START},
    {"Asia/Tok yo", UTC_DAY_START},
    {"Asia/\xe2\x82\xac", UTC_DAY_START},
    {"-", UTC_DAY_START},
    {"1/2", UTC_DAY_START},
    {"a/.b", UTC_DAY_START},
  };
  const gint64 t_mid = 1791849600; /* 2026-10-13T00:00:00Z */
  g_autofree WxBlendHour *a = daily_hours(T0, 120, NULL, NULL);
  for (guint i = 0; i < G_N_ELEMENTS(table); i++) {
    WxDay d[WX_DAILY_MAX_DAYS];
    guint nd = days_of(table[i].tz, a, 120, d);
    g_assert_cmpuint(nd, >=, 3);
    gint64 got = 0;
    for (guint k = 0; k < nd; k++) {
      if (d[k].start_s <= t_mid)
        got = d[k].start_s;
    }
    if (got != table[i].day_start)
      FAIL("zone '%s': the day of 2026-10-13T00:00Z starts %" G_GINT64_FORMAT ", wanted %" G_GINT64_FORMAT,
           table[i].tz != NULL ? table[i].tz : "(null)", got, table[i].day_start);
  }
}

/* ------------------------------------------------------------------------ */
/* determinism, threads, fuzz                                               */
/* ------------------------------------------------------------------------ */

/* SHA-256 over every value of every member of @fx (field by field: the structs have padding). */
static char *
fx_digest(const Fx *fx)
{
  GChecksum *sum = g_checksum_new(G_CHECKSUM_SHA256);
  for (guint i = 0; i < fx->results->len; i++) {
    const WxSourceResult *r = g_ptr_array_index(fx->results, i);
    for (guint k = 0; k < r->members->len; k++) {
      const WxMember *m = g_ptr_array_index(r->members, k);
      g_checksum_update(sum, (const guchar *)m->source_id, (gssize)strlen(m->source_id));
      g_checksum_update(sum, (const guchar *)m->model_id, (gssize)strlen(m->model_id));
      for (guint h = 0; h < m->n_hours; h++) {
        const double vals[] = {(double)m->hours[h].t_s, m->hours[h].temp_c, m->hours[h].feels_c,
                               m->hours[h].precip_mm, m->hours[h].precip_prob, m->hours[h].cloud_pct,
                               m->hours[h].wind_kmh, m->hours[h].gust_kmh, m->hours[h].humidity_pct,
                               (double)m->hours[h].wmo};
        g_checksum_update(sum, (const guchar *)vals, sizeof vals);
      }
      for (guint q = 0; q < m->n_quarters; q++) {
        const double vals[] = {(double)m->quarters[q].t_s, m->quarters[q].precip_mm};
        g_checksum_update(sum, (const guchar *)vals, sizeof vals);
      }
    }
  }
  char *hex = g_strdup(g_checksum_get_string(sum));
  g_checksum_free(sum);
  return hex;
}

static void
test_determinism_and_environment(void)
{
  SKIP_WITHOUT_ZONE("America/New_York");
  g_autoptr(WxPlace) p = miami();
  NcVals v = {{0.2, 0.4, 0.0}, {5.0, 5.0, 0.0}, 0.1};
  double qs[12] = {0.4, 0.2, 0.2, 0.0, 0, 0, 0, 0, 0.4, 0.2, 0.2, 0.0};
  Fx *fx = nc_fixture(&v, T0 + 12 * H, qs, 12);
  gint64 now = T0 + 12 * H + 7 * 60;
  char *digest_before = fx_digest(fx);
  g_autoptr(WxForecast) a = fx_blend(fx, p, now);
  g_autoptr(WxForecast) b = fx_blend(fx, p, now);
  assert_forecasts_identical(a, b);

  /* the same members in the opposite order: the same forecast */
  Fx *rev = fx_new();
  for (guint i = fx->results->len; i > 0; i--) {
    WxSourceResult *r = g_ptr_array_index(fx->results, i - 1);
    WxSourceResult *copy = wx_source_result_new(r->provider_id, NULL);
    for (guint k = r->members->len; k > 0; k--)
      g_ptr_array_add(copy->members, wx_member_ref(g_ptr_array_index(r->members, k - 1)));
    g_ptr_array_add(rev->results, copy);
  }
  g_autoptr(WxForecast) c = fx_blend(rev, p, now);
  assert_forecasts_identical(a, c);
  fx_free(rev);

  /* neither the process time zone nor the locale changes anything */
  g_setenv("TZ", "Pacific/Auckland", TRUE);
  tzset();
  g_autoptr(WxForecast) d = fx_blend(fx, p, now);
  assert_forecasts_identical(a, d);
  g_setenv("TZ", "America/Los_Angeles", TRUE);
  tzset();
  g_autoptr(WxForecast) e = fx_blend(fx, p, now);
  assert_forecasts_identical(a, e);
  g_unsetenv("TZ");
  tzset();
  const char *locales[] = {"de_DE.UTF-8", "fr_FR.UTF-8", "tr_TR.UTF-8", "C.UTF-8"};
  char *saved = g_strdup(setlocale(LC_ALL, NULL));
  for (guint i = 0; i < G_N_ELEMENTS(locales); i++) {
    if (setlocale(LC_ALL, locales[i]) == NULL)
      continue;
    g_autoptr(WxForecast) f = fx_blend(fx, p, now);
    assert_forecasts_identical(a, f);
  }
  setlocale(LC_ALL, saved);
  g_free(saved);

  /* the inputs are not modified: every member is bit for bit what it was */
  char *digest_after = fx_digest(fx);
  g_assert_cmpstr(digest_before, ==, digest_after);
  g_free(digest_before);
  g_free(digest_after);
  fx_free(fx);
}

typedef struct {
  Fx *fx;
  const WxPlace *place;
  WxForecast *reference;
  gint64 now;
} ThreadJob;

static gpointer
blend_thread(gpointer data)
{
  ThreadJob *job = data;
  for (int i = 0; i < 40; i++) {
    g_autoptr(WxForecast) fc = fx_blend(job->fx, job->place, job->now);
    assert_forecasts_identical(fc, job->reference);
    /* the shared forecast is read concurrently too */
    WxBlendHour out;
    g_assert_true(wx_forecast_now(job->reference, job->now, &out));
    WxRainOutlook o;
    wx_rain_outlook(job->reference, job->now, &o);
  }
  return NULL;
}

static void
test_concurrent_blend_of_shared_members(void)
{
  /* the members are shared (immutable) between threads; every blend is independent */
  g_autoptr(WxPlace) p = miami();
  NcVals v = {{0.2, 0.4, 0.0}, {5.0, 5.0, 0.0}, 0.1};
  double qs[12] = {0.4, 0.2, 0.2, 0.0, 0, 0, 0, 0, 0.4, 0.2, 0.2, 0.0};
  Fx *fx = nc_fixture(&v, T0 + 12 * H, qs, 12);
  gint64 now = T0 + 12 * H + 7 * 60;
  g_autoptr(WxForecast) ref = fx_blend(fx, p, now);
  ThreadJob job = {fx, p, ref, now};
  GThread *threads[8];
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    threads[i] = g_thread_new("blend", blend_thread, &job);
  for (guint i = 0; i < G_N_ELEMENTS(threads); i++)
    g_thread_join(threads[i]);
  fx_free(fx);
}

static double
maybe(GRand *r, double lo, double hi)
{
  return g_rand_double(r) < 0.3 ? NAN : rnd(r, lo, hi);
}

static WxMember *
fuzz_member(GRand *r, const Id *id, gint64 base)
{
  WxMember *m = new_member(id->src, id->model);
  int first = g_rand_int_range(r, -6, 8);
  int len = g_rand_double(r) < 0.3 ? g_rand_int_range(r, 0, 9) : g_rand_int_range(r, 0, 260);
  gboolean sparse = g_rand_double(r) < 0.2;
  for (int i = 0; i < len; i++) {
    if (g_rand_double(r) < (sparse ? 0.6 : 0.03))
      continue;
    WxHour h;
    wx_hour_init(&h);
    h.t_s = base + (gint64)(first + i) * H;
    h.temp_c = maybe(r, -30, 45);
    h.feels_c = maybe(r, -35, 50);
    h.precip_mm = g_rand_double(r) < 0.4 ? 0.0 : maybe(r, 0, 20);
    h.precip_prob = maybe(r, 0, 100);
    h.cloud_pct = maybe(r, 0, 100);
    h.wind_kmh = maybe(r, 0, 80);
    h.gust_kmh = maybe(r, 0, 120);
    h.humidity_pct = maybe(r, 0, 100);
    h.wmo = g_rand_double(r) < 0.5 ? -1 : g_rand_int_range(r, 0, 100);
    g_assert_true(wx_member_add_hour(m, &h));
  }
  return m;
}

/* The valid range and group of each variable, as a second statement of the rules. */
typedef struct {
  WxVar var;
  double lo, hi;
  double (*get)(const WxHour *);
} OField;

static double g_temp(const WxHour *h) { return h->temp_c; }
static double g_feels(const WxHour *h) { return h->feels_c; }
static double g_hum(const WxHour *h) { return h->humidity_pct; }
static double g_wind(const WxHour *h) { return h->wind_kmh; }
static double g_gust(const WxHour *h) { return h->gust_kmh; }
static double g_cloud(const WxHour *h) { return h->cloud_pct; }
static double g_precip(const WxHour *h) { return h->precip_mm; }
static double g_prob(const WxHour *h) { return h->precip_prob; }

static const OField ofields[] = {
  {WX_VAR_TEMP, -100, 70, g_temp},       {WX_VAR_TEMP, -100, 70, g_feels},
  {WX_VAR_HUMIDITY, 0, 100, g_hum},      {WX_VAR_WIND, 0, 500, g_wind},
  {WX_VAR_WIND, 0, 500, g_gust},         {WX_VAR_CLOUD, 0, 100, g_cloud},
  {WX_VAR_PRECIP_MM, 0, 500, g_precip},  {WX_VAR_PRECIP_PROB, 0, 100, g_prob},
};

/* The hour of @m at @t_s, or NULL. */
static const WxHour *
member_hour(const WxMember *m, gint64 t_s)
{
  for (guint i = 0; i < m->n_hours; i++) {
    if (m->hours[i].t_s == t_s)
      return &m->hours[i];
  }
  return NULL;
}

static gboolean
in_range(double v, double lo, double hi)
{
  return isfinite(v) && v >= lo && v <= hi;
}

/* Weighted-median of the oracle's gathered list through the independent reference (weights x2). */
static double
oracle_median(const double *v, const double *w, guint n)
{
  int wi[WX_BLEND_MAX_MEMBERS];
  for (guint i = 0; i < n; i++) {
    wi[i] = (int)lround(w[i] * 2.0);
    g_assert_cmpfloat(wi[i] / 2.0, ==, w[i]); /* every weight is a multiple of 0.5 */
  }
  return reference_median(v, wi, n);
}

/* Equal, or both NAN (the payload of a NAN does not matter). */
static gboolean
same_or_both_nan(double a, double b)
{
  return (isnan(a) && isnan(b)) || a == b;
}

/* wx_forecast_new() turns an out-of-range number into NAN instead of refusing it, so a day
 * that the blend built out of range would silently lose a value. Rebuilds the days from the
 * forecast's hours and requires them equal to the forecast's days (nothing was normalised
 * away), with every field within the range wx_forecast_new() enforces. */
static void
assert_forecast_days_in_range(const WxForecast *fc)
{
  guint nh, nd;
  const WxBlendHour *h = hours_of(fc, &nh);
  const WxDay *d = wx_forecast_get_days(fc, &nd);
  WxDay built[WX_DAILY_MAX_DAYS];
  const WxPlace *place = wx_forecast_get_place(fc);
  guint nb = wx_daily_build(place->timezone, h, nh, wx_forecast_get_generated_s(fc), built);
  g_assert_cmpuint(nb, ==, nd);
  for (guint i = 0; i < nd; i++) {
    g_assert_cmpint(built[i].start_s, ==, d[i].start_s);
    g_assert_true(same_or_both_nan(built[i].temp_max_c, d[i].temp_max_c));
    g_assert_true(same_or_both_nan(built[i].temp_min_c, d[i].temp_min_c));
    g_assert_true(same_or_both_nan(built[i].precip_mm, d[i].precip_mm));
    g_assert_true(same_or_both_nan(built[i].precip_prob_max, d[i].precip_prob_max));
    g_assert_true(same_or_both_nan(built[i].cloud_pct, d[i].cloud_pct));
    g_assert_cmpint(built[i].condition, ==, d[i].condition);
    g_assert_true(isnan(d[i].temp_max_c) || in_range(d[i].temp_max_c, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
    g_assert_true(isnan(d[i].temp_min_c) || in_range(d[i].temp_min_c, WX_TEMP_MIN_C, WX_TEMP_MAX_C));
    g_assert_true(isnan(d[i].precip_mm) || in_range(d[i].precip_mm, 0, WX_PRECIP_MAX_MM_DAY));
    g_assert_true(isnan(d[i].precip_prob_max) || in_range(d[i].precip_prob_max, 0, 100));
    g_assert_true(isnan(d[i].cloud_pct) || in_range(d[i].cloud_pct, 0, 100));
  }
}

/* Checks a blend of @members (no HRRR 15) against the oracle: values, counts, errors. */
static void
check_fuzz_case(const WxPlace *place, WxMember **members, guint n, gint64 now)
{
  /* oracle setup */
  gint64 start = now - now % H - H;
  gboolean us = wx_geo_in_us_nws(place->lat, place->lon) || wx_geo_in_conus(place->lat, place->lon);
  for (guint i = 0; i < n; i++) {
    if (strcmp(members[i]->source_id, "nws") == 0)
      us = TRUE;
  }
  gint64 last = 0;
  gboolean any = FALSE;
  for (guint i = 0; i < n; i++) {
    for (guint k = 0; k < members[i]->n_hours; k++) {
      const WxHour *h = &members[i]->hours[k];
      if (h->t_s < start)
        continue;
      for (guint f = 0; f < G_N_ELEMENTS(ofields); f++) {
        if (in_range(ofields[f].get(h), ofields[f].lo, ofields[f].hi)) {
          if (!any || h->t_s > last)
            last = h->t_s;
          any = TRUE;
        }
      }
    }
  }

  GError *err = NULL;
  g_autoptr(WxForecast) fc = blend_raw_at(place, members, n, now, &err);

  guint nb = any ? (guint)MIN((last - start) / H + 1, WX_BLEND_MAX_HOURS) : 0;
  /* per member contribution counts */
  guint contrib[16] = {0};
  struct Exp {
    double v[8];
    double max_precip, spread, prob;
    guint nmem;
  };
  struct Exp *want = g_new0(struct Exp, nb > 0 ? nb : 1);
  for (guint b = 0; b < nb; b++) {
    gint64 t = start + (gint64)b * H;
    double horizon = MAX((double)(t - now), 0.0) / H;
    double vals[8][WX_BLEND_MAX_MEMBERS], wts[8][WX_BLEND_MAX_MEMBERS];
    guint cnt[8] = {0};
    guint nmem = 0;
    for (guint i = 0; i < n; i++) {
      const WxHour *h = member_hour(members[i], t);
      if (h == NULL)
        continue;
      gboolean gave = FALSE;
      for (guint f = 0; f < G_N_ELEMENTS(ofields); f++) {
        double v = ofields[f].get(h);
        if (!in_range(v, ofields[f].lo, ofields[f].hi))
          continue;
        double w = wx_weight_for(members[i]->source_id, members[i]->model_id, ofields[f].var, horizon, us);
        if (!(w > 0))
          continue;
        vals[f][cnt[f]] = v;
        wts[f][cnt[f]] = w;
        cnt[f]++;
        gave = TRUE;
      }
      if (gave) {
        nmem++;
        contrib[i]++;
      }
    }
    for (guint f = 0; f < 8; f++)
      want[b].v[f] = oracle_median(vals[f], wts[f], cnt[f]);
    want[b].max_precip = NAN;
    for (guint k = 0; k < cnt[6]; k++)
      want[b].max_precip = fmax(want[b].max_precip, vals[6][k]);
    want[b].spread = NAN;
    if (cnt[0] >= 2) {
      double lo = vals[0][0], hi = vals[0][0];
      for (guint k = 1; k < cnt[0]; k++) {
        lo = fmin(lo, vals[0][k]);
        hi = fmax(hi, vals[0][k]);
      }
      want[b].spread = hi - lo;
    }
    if (cnt[7] == 0 && cnt[6] > 0) {
      double wet = 0, all = 0;
      for (guint k = 0; k < cnt[6]; k++) {
        all += wts[6][k];
        if (vals[6][k] >= 0.1)
          wet += wts[6][k];
      }
      want[b].v[7] = 100.0 * wet / all;
    }
    want[b].nmem = nmem;
  }
  guint best = 0;
  for (guint i = 0; i < n; i++)
    best = MAX(best, contrib[i]);

  if (best < WX_BLEND_MIN_HOURS) {
    g_assert_null(fc);
    g_assert_error(err, WX_ERROR, WX_ERROR_NOT_FOUND);
    g_clear_error(&err);
    g_free(want);
    return;
  }
  g_assert_no_error(err);
  g_assert_nonnull(fc);

  guint nh;
  const WxBlendHour *h = hours_of(fc, &nh);
  g_assert_cmpuint(nh, ==, nb);
  for (guint b = 0; b < nb; b++) {
    g_assert_cmpint(h[b].t_s, ==, start + (gint64)b * H);
    assert_close_or_nan(h[b].temp_c, want[b].v[0]);
    assert_close_or_nan(h[b].feels_c, want[b].v[1]);
    assert_close_or_nan(h[b].humidity_pct, want[b].v[2]);
    assert_close_or_nan(h[b].wind_kmh, want[b].v[3]);
    assert_close_or_nan(h[b].gust_kmh, want[b].v[4]);
    assert_close_or_nan(h[b].cloud_pct, want[b].v[5]);
    assert_close_or_nan(h[b].precip_mm, want[b].v[6]);
    assert_close_or_nan(h[b].precip_mm_max, want[b].max_precip);
    assert_close_or_nan(h[b].precip_prob, want[b].v[7]);
    assert_close_or_nan(h[b].temp_spread_c, want[b].spread);
    g_assert_cmpuint(h[b].n_members, ==, want[b].nmem);
    /* ranges, and a member count of 0 means nothing at all */
    g_assert_true(isnan(h[b].temp_c) || in_range(h[b].temp_c, -100, 70));
    g_assert_true(isnan(h[b].precip_prob) || in_range(h[b].precip_prob, 0, 100));
    g_assert_true(isnan(h[b].feels_c) || in_range(h[b].feels_c, -100, 70));
    g_assert_true(isnan(h[b].humidity_pct) || in_range(h[b].humidity_pct, 0, 100));
    g_assert_true(isnan(h[b].cloud_pct) || in_range(h[b].cloud_pct, 0, 100));
    g_assert_true(isnan(h[b].wind_kmh) || in_range(h[b].wind_kmh, 0, 500));
    g_assert_true(isnan(h[b].gust_kmh) || in_range(h[b].gust_kmh, 0, 500));
    g_assert_true(isnan(h[b].precip_mm_max) || in_range(h[b].precip_mm_max, 0, 500));
    g_assert_true(isnan(h[b].temp_spread_c) || in_range(h[b].temp_spread_c, 0, 170));
    g_assert_true(isnan(h[b].precip_mm) || (h[b].precip_mm >= 0 && h[b].precip_mm <= h[b].precip_mm_max));
    g_assert_true(isnan(h[b].temp_spread_c) || h[b].temp_spread_c >= 0);
    g_assert_cmpint(h[b].condition, >=, 0);
    g_assert_cmpint(h[b].condition, <, WX_COND_COUNT);
    g_assert_cmpint(h[b].is_day, ==, wx_sun_is_up(place->lat, place->lon, h[b].t_s));
    if (want[b].nmem == 0) {
      ASSERT_NAN(h[b].temp_c);
      ASSERT_NAN(h[b].precip_prob);
      g_assert_cmpint(h[b].condition, ==, WX_COND_UNKNOWN);
    }
  }
  guint nq;
  wx_forecast_get_quarters(fc, &nq);
  g_assert_cmpuint(nq, ==, 0);
  guint nd;
  const WxDay *d = wx_forecast_get_days(fc, &nd);
  g_assert_cmpuint(nd, <=, WX_DAILY_MAX_DAYS);
  for (guint i = 0; i < nd; i++) {
    if (i > 0)
      g_assert_cmpint(d[i].start_s, >, d[i - 1].start_s);
    g_assert_true(isnan(d[i].temp_max_c) || d[i].temp_max_c >= d[i].temp_min_c);
    g_assert_true(isnan(d[i].precip_mm) || d[i].precip_mm >= 0);
  }
  assert_forecast_days_in_range(fc);

  /* the member order does not matter */
  WxMember *rev[16];
  for (guint i = 0; i < n; i++)
    rev[i] = members[n - 1 - i];
  g_autoptr(WxForecast) fc2 = blend_raw_at(place, rev, n, now, NULL);
  g_assert_nonnull(fc2);
  assert_forecasts_identical(fc, fc2);
  g_free(want);
}

static void
test_fuzz_against_oracle(void)
{
  GRand *r = rng(20261011);
  static const struct {
    double lat, lon;
    const char *tz;
  } places[] = {
    {25.7617, -80.1918, "America/New_York"}, {51.5074, -0.1278, "Europe/London"},
    {-33.8688, 151.2093, "Australia/Sydney"}, {61.2, -149.9, ""}, {35.68, 139.69, "Asia/Tokyo"},
    {69.65, 18.96, "Europe/Oslo"},
  };
  guint successes = 0, failures = 0;
  for (int iter = 0; iter < 1500; iter++) {
    guint pi = (guint)g_rand_int_range(r, 0, G_N_ELEMENTS(places));
    const char *tz = places[pi].tz;
    if (tz[0] != '\0' && !zone_available(tz))
      tz = "";
    g_autoptr(WxPlace) place = mk_place(places[pi].lat, places[pi].lon, tz);
    gint64 now = T0 + g_rand_int_range(r, 0, 20 * 86400) + g_rand_int_range(r, 0, 86400);
    gint64 base = now - now % H;
    WxMember *members[16];
    guint n = 0;
    for (guint k = 0; k < G_N_ELEMENTS(fuzz_ids); k++) {
      if (g_rand_double(r) < 0.45)
        members[n++] = fuzz_member(r, &fuzz_ids[k], base);
    }
    WxMember *keep[16];
    memcpy(keep, members, sizeof members);
    /* shuffle the order a little */
    for (guint i = n; i > 1; i--) {
      guint j = (guint)g_rand_int_range(r, 0, i);
      WxMember *t = members[i - 1];
      members[i - 1] = members[j];
      members[j] = t;
    }
    check_fuzz_case(place, members, n, now);
    GError *err = NULL;
    g_autoptr(WxForecast) fc = blend_raw_at(place, members, n, now, &err);
    if (fc != NULL)
      successes++;
    else
      failures++;
    g_clear_error(&err);
    for (guint i = 0; i < n; i++)
      wx_member_unref(keep[i]);
  }
  /* the generator reaches both outcomes */
  g_assert_cmpuint(successes, >, 500);
  g_assert_cmpuint(failures, >, 20);
  g_rand_free(r);
}

/* A forecast must keep its invariants with a nowcast, whatever the quarters */
static void
test_fuzz_nowcast_invariants(void)
{
  GRand *r = rng(777);
  g_autoptr(WxPlace) place = miami();
  guint with_quarters = 0;
  for (int iter = 0; iter < 600; iter++) {
    gint64 now = T0 + g_rand_int_range(r, 0, 10 * 86400);
    gint64 base = now - now % H;
    WxMember *members[8];
    guint n = 0;
    for (guint k = 1; k < 7; k++) {
      if (g_rand_double(r) < 0.7)
        members[n++] = fuzz_member(r, &fuzz_ids[k], base);
    }
    WxMember *q = new_member("open-meteo", "hrrr15");
    gint64 qfirst = (now - now % 900) - 900 * g_rand_int_range(r, -2, 5);
    guint nq = (guint)g_rand_int_range(r, 0, 20);
    for (guint i = 0; i < nq; i++) {
      if (g_rand_double(r) < 0.05)
        continue;
      WxQuarter qq = {qfirst + (gint64)i * 900, g_rand_double(r) < 0.4 ? 0.0 : rnd(r, 0, 3)};
      g_assert_true(wx_member_add_quarter(q, &qq));
    }
    members[n++] = q;
    GError *err = NULL;
    g_autoptr(WxForecast) fc = blend_raw_at(place, members, n, now, &err);
    if (fc == NULL) {
      g_assert_error(err, WX_ERROR, WX_ERROR_NOT_FOUND);
      g_clear_error(&err);
    } else {
      guint nh, nqf;
      const WxBlendHour *h = hours_of(fc, &nh);
      const WxQuarter *fq = wx_forecast_get_quarters(fc, &nqf);
      g_assert_cmpuint(nqf, <=, WX_BLEND_MAX_QUARTERS);
      if (nqf > 0) {
        with_quarters++;
        g_assert_cmpint(fq[0].t_s, ==, now - now % 900);
        g_assert_cmpint(fq[nqf - 1].t_s + 900, >=, now + 1800);
        for (guint i = 0; i < nqf; i++) {
          if (i > 0)
            g_assert_cmpint(fq[i].t_s - fq[i - 1].t_s, ==, 900);
          g_assert_true(isfinite(fq[i].precip_mm) && fq[i].precip_mm >= 0);
          /* a fully covered hour sums to its blended precipitation (when that is known) */
          if (fq[i].t_s % H == 0 && i + 3 < nqf) {
            guint b = (guint)((fq[i].t_s - h[0].t_s) / H);
            if (b < nh && isfinite(h[b].precip_mm)) {
              double s = fq[i].precip_mm + fq[i + 1].precip_mm + fq[i + 2].precip_mm + fq[i + 3].precip_mm;
              g_assert_cmpfloat_with_epsilon(s, h[b].precip_mm, 1e-9 * (1 + h[b].precip_mm));
            }
          }
        }
      }
      for (guint i = 0; i < nh; i++) {
        g_assert_true(isnan(h[i].precip_mm) || (h[i].precip_mm >= 0 && h[i].precip_mm <= 500));
        g_assert_true(isnan(h[i].precip_mm_max) || h[i].precip_mm_max >= h[i].precip_mm);
      }
    }
    for (guint i = 0; i < n; i++)
      wx_member_unref(members[i]);
  }
  g_assert_cmpuint(with_quarters, >, 30);
  g_rand_free(r);
}

/* ------------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);

  g_test_add_func("/blend/median/basic", test_median_basic);
  g_test_add_func("/blend/median/ties-zeros-nan", test_median_ties_zeros_nan);
  g_test_add_func("/blend/median/extreme-weights", test_median_extreme_weights);
  g_test_add_func("/blend/median/fuzz-reference", test_median_fuzz_reference);
  g_test_add_func("/blend/median/criticals", test_median_criticals);
  g_test_add_func("/blend/median/guard-page", test_median_guard_page);
  g_test_add_func("/blend/median/tie-mean-in-range", test_median_tie_mean_in_range);

  g_test_add_func("/blend/weights/us-table", test_weights_us_table);
  g_test_add_func("/blend/weights/world-table", test_weights_world_table);
  g_test_add_func("/blend/weights/invariants", test_weights_invariants);
  g_test_add_func("/blend/weights/edges", test_weights_edges);
  g_test_add_func("/blend/weights/criticals", test_weights_criticals);

  g_test_add_func("/blend/condition/cloud-label", test_cloud_label);
  g_test_add_func("/blend/condition/labels", test_condition_labels);
  g_test_add_func("/blend/condition/wmo-rules", test_condition_wmo_rules);
  g_test_add_func("/blend/condition/majority", test_condition_majority);
  g_test_add_func("/blend/condition/wet-intensity", test_condition_wet_and_intensity);
  g_test_add_func("/blend/condition/criticals", test_condition_criticals);
  g_test_add_func("/blend/condition/guard-page", test_condition_guard_page);

  g_test_add_func("/blend/blend/alignment", test_blend_alignment);
  g_test_add_func("/blend/blend/leading-gap-and-cap", test_blend_leading_gap_and_cap);
  g_test_add_func("/blend/blend/time-edges", test_blend_time_edges);
  g_test_add_func("/blend/blend/single-member", test_blend_single_member);
  g_test_add_func("/blend/blend/median-and-horizon", test_blend_median_and_horizon);
  g_test_add_func("/blend/blend/region", test_blend_region);
  g_test_add_func("/blend/blend/precip-and-probability", test_blend_precip_and_probability);
  g_test_add_func("/blend/blend/member-counts", test_blend_member_counts_and_missing);
  g_test_add_func("/blend/blend/conditions-from-wmo", test_blend_conditions_from_wmo);
  g_test_add_func("/blend/blend/no-data", test_blend_no_data);
  g_test_add_func("/blend/blend/garbage-members", test_blend_garbage_members);
  g_test_add_func("/blend/blend/duplicates-and-cap", test_blend_duplicates_and_cap);
  g_test_add_func("/blend/blend/statuses-and-place", test_blend_statuses_and_place);
  g_test_add_func("/blend/blend/criticals", test_blend_criticals);
  g_test_add_func("/blend/blend/daily-places", test_blend_daily_places);
  g_test_add_func("/blend/blend/today-until-midnight", test_blend_today_until_midnight);
  g_test_add_func("/blend/blend/today-half-hour-zone", test_blend_today_half_hour_zone);

  g_test_add_func("/blend/nowcast/override-rescale", test_nowcast_override_and_rescale);
  g_test_add_func("/blend/nowcast/partial-hours", test_nowcast_partial_hours);
  g_test_add_func("/blend/nowcast/coverage-rules", test_nowcast_coverage_rules);
  g_test_add_func("/blend/nowcast/without-hrrr-hours", test_nowcast_without_hrrr_hours);
  g_test_add_func("/blend/nowcast/garbage-quarters", test_nowcast_garbage_quarters);
  g_test_add_func("/blend/nowcast/hour-sums-validity", test_nowcast_hour_sums_validity);
  g_test_add_func("/blend/nowcast/hrrr-without-hour", test_nowcast_hrrr_without_hour);

  g_test_add_func("/blend/now/interpolation", test_forecast_now);
  g_test_add_func("/blend/now/condition-follows-cloud", test_forecast_now_condition_follows_cloud);

  g_test_add_func("/blend/rain/dry-possible", test_rain_dry_and_possible);
  g_test_add_func("/blend/rain/now", test_rain_now);
  g_test_add_func("/blend/rain/expected", test_rain_expected);
  g_test_add_func("/blend/rain/wet-thresholds", test_rain_wet_thresholds);
  g_test_add_func("/blend/rain/gaps-empty", test_rain_gaps_and_empty);
  g_test_add_func("/blend/rain/quarters", test_rain_quarters);
  g_test_add_func("/blend/rain/criticals", test_rain_criticals);
  g_test_add_func("/blend/rain/fuzz-reference", test_rain_fuzz_against_reference);
  g_test_add_func("/blend/rain/fuzz-quarters", test_rain_fuzz_quarters_invariants);
  g_test_add_func("/blend/rain/hours-bound", test_rain_hours_bound);
  g_test_add_func("/blend/rain/hostile-hours", test_rain_hostile_hours);
  g_test_add_func("/blend/rain/hostile-quarters", test_rain_hostile_quarters);
  g_test_add_func("/blend/now/hostile", test_forecast_now_hostile);
  g_test_add_func("/blend/daily/hostile-values", test_daily_hostile_values);
  g_test_add_func("/blend/condition/hostile", test_condition_hostile);
  g_test_add_func("/blend/blend/hostile-nowcast-member", test_blend_hostile_nowcast_member);

  g_test_add_func("/blend/daily/basic", test_daily_basic);
  g_test_add_func("/blend/daily/covered-hours", test_daily_covered_hours);
  g_test_add_func("/blend/daily/today", test_daily_today);
  g_test_add_func("/blend/daily/dst", test_daily_dst);
  g_test_add_func("/blend/daily/zones-invalid-names", test_daily_zones_and_invalid_names);
  g_test_add_func("/blend/daily/aggregates", test_daily_aggregates);
  g_test_add_func("/blend/daily/conditions-severe", test_daily_conditions_severe);
  g_test_add_func("/blend/daily/conditions-rain-cloud", test_daily_conditions_rain_and_cloud);
  g_test_add_func("/blend/daily/range-and-criticals", test_daily_time_range_and_criticals);
  g_test_add_func("/blend/daily/first-midnight", test_daily_first_midnight);
  g_test_add_func("/blend/daily/zone-sweep", test_daily_zone_sweep);
  g_test_add_func("/blend/daily/zone-sweep-all", test_daily_zone_sweep_all);
  g_test_add_func("/blend/daily/day-sum-clamp", test_daily_day_sum_clamp);
  g_test_add_func("/blend/daily/interval-guard", test_daily_interval_guard);
  g_test_add_func("/blend/daily/timezone-rule", test_daily_timezone_rule);

  g_test_add_func("/blend/determinism/environment", test_determinism_and_environment);
  g_test_add_func("/blend/determinism/threads", test_concurrent_blend_of_shared_members);
  g_test_add_func("/blend/fuzz/oracle", test_fuzz_against_oracle);
  g_test_add_func("/blend/fuzz/nowcast", test_fuzz_nowcast_invariants);
  g_test_add_func("/blend/nowcast/rescale-in-range", test_nowcast_rescale_in_range);
  g_test_add_func("/blend/nowcast/rescale-subnormal", test_nowcast_rescale_subnormal);
  g_test_add_func("/blend/nowcast/rescale-fuzz", test_nowcast_rescale_fuzz);
  g_test_add_func("/blend/nowcast/rescale-spread-both-directions", test_nowcast_rescale_spread_both_directions);
  g_test_add_func("/blend/fuzz/only-not-found-fails", test_fuzz_only_not_found_fails);

  return g_test_run();
}
