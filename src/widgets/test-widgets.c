/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-widgets.c - WxRainChart / WxHourStrip / WxDayList under a display.
 *
 * Needs a GDK display (run under xvfb-run); exits 77 (meson: skipped) when
 * gtk_init_check() fails. The tests run under a bare theme created in a temp
 * directory, so they do not depend on the installed GTK theme.
 */
#define _GNU_SOURCE /* syscall(): the cleanup must be async-signal-safe */
#include <fcntl.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "wx-day-list.h"
#include "wx-format.h"
#include "wx-format-testing.h"
#include "wx-hour-strip.h"
#include "wx-icons.h"
#include "wx-rain-chart.h"

#define NY "America/New_York"
#define WIN_W 440
#define WIN_H 280

/* Runs @check with the one critical that @fname's g_return_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* ------------------------------------------------------------------ */
/* Fixtures                                                           */
/* ------------------------------------------------------------------ */

static gint64
ts(int y, int mo, int d, int h, int mi)
{
  g_autoptr(GDateTime) dt = g_date_time_new_utc(y, mo, d, h, mi, 0);
  g_assert_nonnull(dt);
  return g_date_time_to_unix(dt);
}

/* Sunday 2026-10-11 18:30Z = 2:30 PM in New York. */
#define T_HOUR0 ts(2026, 10, 11, 18, 0)
#define NOW (T_HOUR0 + 1800)

static WxPlace *
make_place_in(const char *tz)
{
  GError *err = NULL;
  WxPlace *p = wx_place_new("Miami", "Florida", "United States", "US", 25.76, -80.19, tz, &err);
  g_assert_no_error(err);
  return p;
}

static WxPlace *
make_place(void)
{
  return make_place_in(NY);
}

static WxBlendHour
hour(gint64 t_s)
{
  return (WxBlendHour){ .t_s = t_s, .temp_c = 25, .feels_c = 27, .precip_mm = 0,
                        .precip_mm_max = 0, .precip_prob = 10, .cloud_pct = 40, .wind_kmh = 19,
                        .gust_kmh = 30, .humidity_pct = 60, .temp_spread_c = NAN, .n_members = 2,
                        .condition = WX_COND_PARTLY_CLOUDY, .is_day = TRUE };
}

/* @n hours from @t0; hour i rains 1.5 mm when i % 3 == 0 (chance 10 * (i % 10) + 5). */
static WxForecast *
make_forecast_in(const char *tz, gint64 t0, guint n, guint n_quarters, guint n_days)
{
  WxBlendHour hours[WX_FORECAST_MAX_HOURS];
  WxQuarter quarters[WX_FORECAST_MAX_QUARTERS];
  WxDay days[WX_FORECAST_MAX_DAYS];
  g_assert_cmpuint(n, <=, G_N_ELEMENTS(hours));
  g_assert_cmpuint(n_quarters, <=, G_N_ELEMENTS(quarters));
  g_assert_cmpuint(n_days, <=, G_N_ELEMENTS(days));
  for (guint i = 0; i < n; i++) {
    hours[i] = hour(t0 + (gint64)i * 3600);
    hours[i].precip_mm = i % 3 == 0 ? 1.5 : 0.0;
    hours[i].precip_prob = 10.0 * (i % 10) + 5.0;
    hours[i].temp_c = 20.0 + (double)(i % 10);
  }
  gint64 q0 = t0; /* quarter i rains 0.5 mm when i is even */
  for (guint i = 0; i < n_quarters; i++)
    quarters[i] = (WxQuarter){ q0 + (gint64)i * 900, i % 2 == 0 ? 0.5 : 0.0 };
  /* day 0 starts at local midnight Oct 11 in New York = 04:00Z */
  for (guint i = 0; i < n_days; i++)
    days[i] = (WxDay){ .start_s = ts(2026, 10, 11, 4, 0) + (gint64)i * 86400, .temp_max_c = 30 + (double)i,
                       .temp_min_c = 20 - (double)i, .precip_mm = 2.0 * i, .precip_prob_max = 10.0 * i,
                       .cloud_pct = 50, .condition = WX_COND_RAIN };
  g_autoptr(WxPlace) place = make_place_in(tz);
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, NOW, hours, n, n_quarters ? quarters : NULL, n_quarters,
                                  n_days ? days : NULL, n_days, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

static WxForecast *
make_forecast(gint64 t0, guint n, guint n_quarters, guint n_days)
{
  return make_forecast_in(NY, t0, n, n_quarters, n_days);
}

static void
pump(guint ms)
{
  gint64 end = g_get_monotonic_time() + (gint64)ms * 1000;
  GMainContext *ctx = g_main_context_default();
  while (g_get_monotonic_time() < end) {
    while (g_main_context_iteration(ctx, FALSE))
      ;
    g_usleep(5000);
  }
}

typedef struct {
  GtkWidget *window;
  GtkWidget *widget;
} Fixture;

static Fixture
fixture_new_sized(GtkWidget *widget, int width, int height)
{
  Fixture f = { gtk_window_new(), widget };
  gtk_window_set_default_size(GTK_WINDOW(f.window), width, height);
  gtk_window_set_child(GTK_WINDOW(f.window), widget);
  gtk_window_present(GTK_WINDOW(f.window));
  for (int i = 0; i < 200 && gtk_widget_get_width(widget) <= 0; i++)
    pump(10);
  g_assert_cmpint(gtk_widget_get_width(widget), >, 0);
  g_assert_cmpint(gtk_widget_get_height(widget), >, 0);
  return f;
}

static Fixture
fixture_new(GtkWidget *widget)
{
  return fixture_new_sized(widget, WIN_W, WIN_H);
}

static void
fixture_free(Fixture *f)
{
  gtk_window_destroy(GTK_WINDOW(f->window));
  pump(20);
}

/* Render node of one snapshot() call (NULL for no nodes); unref it. */
static GskRenderNode *
snap_node(GtkWidget *w)
{
  GtkSnapshot *s = gtk_snapshot_new();
  GTK_WIDGET_GET_CLASS(w)->snapshot(w, s);
  return gtk_snapshot_free_to_node(s);
}

static GBytes *
snap(GtkWidget *w)
{
  GskRenderNode *node = snap_node(w);
  if (node == NULL)
    return g_bytes_new_static("", 0);
  GBytes *bytes = gsk_render_node_serialize(node);
  gsk_render_node_unref(node);
  return bytes;
}

/* Number of nodes of @type below @node (containers and transforms are walked). */
static guint
count_nodes(GskRenderNode *node, GskRenderNodeType type)
{
  if (node == NULL)
    return 0;
  GskRenderNodeType t = gsk_render_node_get_node_type(node);
  if (t == GSK_CONTAINER_NODE) {
    guint n = 0;
    for (guint i = 0; i < gsk_container_node_get_n_children(node); i++)
      n += count_nodes(gsk_container_node_get_child(node, i), type);
    return n;
  }
  if (t == GSK_TRANSFORM_NODE)
    return count_nodes(gsk_transform_node_get_child(node), type);
  g_assert_true(t == GSK_COLOR_NODE || t == GSK_TEXT_NODE || t == GSK_STROKE_NODE);
  return t == type ? 1 : 0;
}

/* Counts of one snapshot of @w: colour nodes, text nodes, stroke nodes. */
typedef struct {
  guint color, text, stroke;
} Counts;

static Counts
counts(GtkWidget *w)
{
  GskRenderNode *node = snap_node(w);
  Counts c = { count_nodes(node, GSK_COLOR_NODE), count_nodes(node, GSK_TEXT_NODE),
               count_nodes(node, GSK_STROKE_NODE) };
  if (node != NULL)
    gsk_render_node_unref(node);
  return c;
}

/* ------------------------------------------------------------------ */
/* WxRainChart                                                        */
/* ------------------------------------------------------------------ */

/* TRUE iff the chart draws a plot (the grid lines) rather than "No data" or nothing. */
static gboolean
shows_data(GtkWidget *w)
{
  return counts(w).color > 0;
}

/* The 15-minute view has no chance line, the hourly view has one when chances are known. */
#define HAS_DATA(chart) shows_data(GTK_WIDGET(chart))

/* The bars (and lone-value squares) of one snapshot: every colour node that is not a grid line. */
static GArray *
bar_rects(GtkWidget *w)
{
  GArray *out = g_array_new(FALSE, FALSE, sizeof(graphene_rect_t));
  GskRenderNode *node = snap_node(w);
  if (node != NULL) {
    float grid_w = (float)gtk_widget_get_width(w) / 2.0f;
    for (guint i = 0; i < gsk_container_node_get_n_children(node); i++) {
      GskRenderNode *c = gsk_container_node_get_child(node, i);
      graphene_rect_t b;
      if (gsk_render_node_get_node_type(c) != GSK_COLOR_NODE)
        continue;
      gsk_render_node_get_bounds(c, &b);
      if (b.size.width < grid_w)
        g_array_append_val(out, b);
    }
    gsk_render_node_unref(node);
  }
  return out;
}

static void
test_chart_measure(void)
{
  GtkWidget *chart = g_object_ref_sink(wx_rain_chart_new());
  int min, nat;
  gtk_widget_measure(chart, GTK_ORIENTATION_HORIZONTAL, -1, &min, &nat, NULL, NULL);
  g_assert_cmpint(min, ==, 160);
  g_assert_cmpint(nat, ==, 360);
  gtk_widget_measure(chart, GTK_ORIENTATION_VERTICAL, -1, &min, &nat, NULL, NULL);
  g_assert_cmpint(min, ==, 96);
  g_assert_cmpint(nat, ==, 140);
  g_assert_true(gtk_widget_get_hexpand(chart));
  g_assert_true(gtk_widget_get_vexpand(chart));
  g_assert_cmpstr(gtk_widget_get_css_name(chart), ==, "wx-rain-chart");
  g_assert_cmpint(gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(chart)), ==, GTK_ACCESSIBLE_ROLE_IMG);
  g_object_unref(chart);
}

static void
test_chart_null_arguments(void)
{
  GtkWidget *chart = g_object_ref_sink(wx_rain_chart_new());
  ASSERT_CRITICAL("wx_rain_chart_set_forecast",
                  wx_rain_chart_set_forecast(NULL, NULL, WX_UNITS_METRIC, NOW));
  ASSERT_CRITICAL("wx_rain_chart_set_forecast",
                  wx_rain_chart_set_forecast(WX_RAIN_CHART(chart), NULL, (WxUnits)5, NOW));
  g_object_unref(chart);
}

static void
test_chart_no_data(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  g_assert_false(HAS_DATA(chart));
  Counts c = counts(f.widget);
  g_assert_cmpuint(c.text, ==, 1); /* "No data" */
  g_assert_cmpuint(c.color, ==, 0);
  g_assert_cmpuint(c.stroke, ==, 0);
  GBytes *empty = snap(f.widget);

  wx_rain_chart_set_forecast(chart, NULL, WX_UNITS_METRIC, NOW);
  GBytes *again = snap(f.widget);
  g_assert_true(g_bytes_equal(empty, again));

  /* a forecast without any hour, a now outside the valid range */
  g_autoptr(WxForecast) none = make_forecast(T_HOUR0, 0, 0, 0);
  wx_rain_chart_set_forecast(chart, none, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart));
  g_autoptr(WxForecast) some = make_forecast(T_HOUR0, 30, 0, 0);
  gint64 bad_now[] = { 0, G_MAXINT64, G_MININT64, WX_TIME_MIN_S - 1, WX_TIME_MAX_S };
  for (guint i = 0; i < G_N_ELEMENTS(bad_now); i++) {
    wx_rain_chart_set_forecast(chart, some, WX_UNITS_METRIC, bad_now[i]);
    g_assert_false(HAS_DATA(chart));
    g_assert_cmpuint(counts(f.widget).text, ==, 1);
  }
  /* a forecast entirely in the past has no value in the window */
  wx_rain_chart_set_forecast(chart, some, WX_UNITS_METRIC, T_HOUR0 + 100 * 3600);
  g_assert_false(HAS_DATA(chart));
  g_bytes_unref(empty);
  g_bytes_unref(again);
  fixture_free(&f);
}

static void
test_chart_hourly(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  GBytes *empty = snap(f.widget);
  /* data starts one hour before the current hour: that hour must not be drawn */
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0 - 3600, 40, 0, 0);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_true(HAS_DATA(chart));
  Counts c = counts(f.widget);
  /* window = hours index 1..24; rain when index % 3 == 0 -> 3,6,..,24 = 8 bars; 3 grid lines */
  g_assert_cmpuint(c.color, ==, 3 + 8);
  g_assert_cmpuint(c.stroke, ==, 1); /* one chance line, all 24 chances known */
  g_assert_cmpuint(c.text, >=, 4);   /* top-of-scale, 100%, 0%, at least the "Now" label */
  g_assert_cmpuint(c.text, <=, 3 + 5);

  GBytes *shown = snap(f.widget);
  g_assert_false(g_bytes_equal(empty, shown));
  GBytes *shown2 = snap(f.widget); /* drawing is deterministic */
  g_assert_true(g_bytes_equal(shown, shown2));

  /* the units change the labels */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  GBytes *metric = snap(f.widget);
  g_assert_false(g_bytes_equal(shown, metric));
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW);
  GBytes *back = snap(f.widget);
  g_assert_true(g_bytes_equal(shown, back));

  /* a hole in the data breaks the line and drops the lone values to squares */
  WxBlendHour hs[5];
  for (guint i = 0; i < 5; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = NAN;
  }
  hs[0].precip_prob = 50;
  hs[1].precip_prob = NAN;
  hs[2].precip_prob = 60;
  hs[3].precip_prob = 70;
  hs[4].precip_prob = NAN;
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) holes = wx_forecast_new(place, NOW, hs, 5, NULL, 0, NULL, 0, NULL, 0, NULL);
  g_assert_nonnull(holes);
  wx_rain_chart_set_forecast(chart, holes, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart));
  c = counts(f.widget);
  g_assert_cmpuint(c.stroke, ==, 1);    /* slots 2-3 */
  g_assert_cmpuint(c.color, ==, 3 + 1); /* grid + the lone value of slot 0 as a square */

  /* only a lone value: no stroke at all */
  hs[3].precip_prob = NAN;
  g_autoptr(WxForecast) lone = wx_forecast_new(place, NOW, hs, 5, NULL, 0, NULL, 0, NULL, 0, NULL);
  wx_rain_chart_set_forecast(chart, lone, WX_UNITS_METRIC, NOW);
  c = counts(f.widget);
  g_assert_cmpuint(c.stroke, ==, 0);
  g_assert_cmpuint(c.color, ==, 3 + 2);

  /* amounts only, no chance at all: bars, no line */
  for (guint i = 0; i < 5; i++) {
    hs[i].precip_prob = NAN;
    hs[i].precip_mm = i == 1 ? 3.0 : 0.0;
  }
  g_autoptr(WxForecast) amounts = wx_forecast_new(place, NOW, hs, 5, NULL, 0, NULL, 0, NULL, 0, NULL);
  wx_rain_chart_set_forecast(chart, amounts, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart));
  c = counts(f.widget);
  g_assert_cmpuint(c.stroke, ==, 0);
  g_assert_cmpuint(c.color, ==, 3 + 1);

  /* back to nothing */
  wx_rain_chart_set_forecast(chart, NULL, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart));
  GBytes *cleared = snap(f.widget);
  g_assert_true(g_bytes_equal(cleared, empty));

  g_bytes_unref(empty);
  g_bytes_unref(shown);
  g_bytes_unref(shown2);
  g_bytes_unref(metric);
  g_bytes_unref(back);
  g_bytes_unref(cleared);
  fixture_free(&f);
}

static void
test_chart_quarters(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  g_assert_false(HAS_DATA(chart));

  /* hourly data alone: the hourly view (chance line, hourly bars) */
  g_autoptr(WxForecast) hourly_only = make_forecast(T_HOUR0, 30, 0, 0);
  wx_rain_chart_set_forecast(chart, hourly_only, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart));
  g_assert_cmpuint(counts(f.widget).stroke, ==, 1);

  /* quarters from 18:00Z; now 18:30Z -> window = quarters 2..9, even indices rain: 2,4,6,8 */
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 30, 12, 0);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart));
  Counts c = counts(f.widget);
  g_assert_cmpuint(c.color, ==, 3 + 4);
  g_assert_cmpuint(c.stroke, ==, 0);          /* no chance line for the nowcast */
  g_assert_cmpuint(c.text, >=, 2);            /* top-of-scale + "Now" */
  g_assert_cmpuint(c.text, <=, 1 + 5);        /* no percent labels */

  /* the window moves with now: at 18:45 quarters 3..10 -> rain at 4,6,8,10 */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, T_HOUR0 + 45 * 60);
  c = counts(f.widget);
  g_assert_cmpuint(c.color, ==, 3 + 4);
  g_assert_cmpuint(c.stroke, ==, 0);
  /* at 19:30 only quarters 6..11 exist: 6,8,10 */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, T_HOUR0 + 90 * 60);
  c = counts(f.widget);
  g_assert_cmpuint(c.color, ==, 3 + 3);
  g_assert_cmpuint(c.stroke, ==, 0);
  /* after the last quarter (20:45 ends) the nowcast no longer covers now: hourly view again */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, T_HOUR0 + 4 * 3600);
  g_assert_true(HAS_DATA(chart));
  g_assert_cmpuint(counts(f.widget).stroke, ==, 1);
  /* with no hours either there is nothing to show */
  g_autoptr(WxForecast) q_only = make_forecast(T_HOUR0, 0, 12, 0);
  wx_rain_chart_set_forecast(chart, q_only, WX_UNITS_METRIC, T_HOUR0 + 4 * 3600);
  g_assert_false(HAS_DATA(chart));
  fixture_free(&f);
}

/* Which view the data selects: the same chart, a forecast with a nowcast, then without, and back. */
static void
test_chart_view_follows_data(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  g_autoptr(WxForecast) with_nc = make_forecast(T_HOUR0, 30, 12, 0);   /* hours + quarters 18:00.. */
  g_autoptr(WxForecast) without = make_forecast(T_HOUR0, 30, 0, 0);

  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, NOW);
  GBytes *quarter_view = snap(f.widget);
  GArray *qb = bar_rects(f.widget);
  g_assert_cmpuint(qb->len, ==, 4); /* quarters 2,4,6,8 -> slots 0,2,4,6 of 8 */
  g_assert_cmpuint(counts(f.widget).stroke, ==, 0);

  wx_rain_chart_set_forecast(chart, without, WX_UNITS_METRIC, NOW);
  GBytes *hourly_view = snap(f.widget);
  GArray *hb = bar_rects(f.widget);
  g_assert_cmpuint(hb->len, ==, 8); /* hours 0,3,..21 of the window from 18:00Z... */
  g_assert_cmpuint(counts(f.widget).stroke, ==, 1);
  g_assert_false(g_bytes_equal(quarter_view, hourly_view));

  /* geometry: 8 wide slots across the whole width, rate 2.0 of a 2.5 scale; 24 narrow slots with
   * room for the percent labels on the right, rate 1.5 of 2.5 */
  float w = (float)gtk_widget_get_width(f.widget);
  graphene_rect_t q0 = g_array_index(qb, graphene_rect_t, 0), q1 = g_array_index(qb, graphene_rect_t, 1);
  graphene_rect_t h0 = g_array_index(hb, graphene_rect_t, 0), h1 = g_array_index(hb, graphene_rect_t, 1);
  float q_slot = w / 8.0f;
  g_assert_cmpfloat_with_epsilon(q1.origin.x - q0.origin.x, 2.0f * q_slot, 0.01f);
  g_assert_cmpfloat_with_epsilon(q0.size.width, fmaxf(1.0f, q_slot * 0.7f), 0.01f);
  g_assert_cmpfloat_with_epsilon(q0.origin.x, (q_slot - q0.size.width) / 2.0f, 0.01f);
  float h_slot = (h1.origin.x - h0.origin.x) / 3.0f;
  g_assert_cmpfloat(h_slot, <, q_slot / 2.0f);
  g_assert_cmpfloat(h_slot * 24.0f, <, w); /* the 100% / 0% labels take room on the right */
  g_assert_cmpfloat_with_epsilon(h0.size.width, fmaxf(1.0f, h_slot * 0.7f), 0.01f);
  g_assert_cmpfloat_with_epsilon(h0.size.height / q0.size.height, 0.75f, 0.01f); /* 1.5 / 2.0 */

  /* back: byte-identical to the first quarter view (the switch loses nothing) */
  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, NOW);
  GBytes *again = snap(f.widget);
  g_assert_true(g_bytes_equal(quarter_view, again));
  wx_rain_chart_set_forecast(chart, without, WX_UNITS_METRIC, NOW);
  GBytes *again_h = snap(f.widget);
  g_assert_true(g_bytes_equal(hourly_view, again_h));

  /* a nowcast that does not cover now: only later quarters, or only past ones, or NaN */
  g_autoptr(WxPlace) place = make_place();
  WxQuarter later[2] = { { T_HOUR0 + 2700, 1.0 }, { T_HOUR0 + 3600, 1.0 } }; /* 18:45 and 19:00: not now (18:30) */
  g_autoptr(WxForecast) fl = wx_forecast_new(place, NOW, NULL, 0, later, 2, NULL, 0, NULL, 0, NULL);
  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, NOW);
  wx_rain_chart_set_forecast(chart, fl, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart)); /* no hours, and no covering quarter: hourly view without data */
  WxQuarter past[2] = { { T_HOUR0, 1.0 }, { T_HOUR0 + 900, 1.0 } };
  g_autoptr(WxForecast) fp = wx_forecast_new(place, NOW, NULL, 0, past, 2, NULL, 0, NULL, 0, NULL);
  wx_rain_chart_set_forecast(chart, fp, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart));
  WxQuarter nan_q[1] = { { T_HOUR0 + 1800, NAN } }; /* hand-built: wx_forecast_new() would refuse a NaN */
  WxForecast raw = { .quarters = nan_q, .n_quarters = 1 };
  raw.place.timezone = (char *)"";
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart));
  WxQuarter ok_q[1] = { { T_HOUR0 + 1800, 1.0 } };
  raw.quarters = ok_q;
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart)); /* a single covering quarter is enough for the 15-minute view */
  /* the covering quarter is judged at the 15-minute boundary */
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, T_HOUR0 + 1800 + 899);
  g_assert_true(HAS_DATA(chart));
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, T_HOUR0 + 1800 + 900);
  g_assert_false(HAS_DATA(chart));
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, T_HOUR0 + 1799);
  g_assert_false(HAS_DATA(chart));

  g_array_free(qb, TRUE);
  g_array_free(hb, TRUE);
  g_bytes_unref(quarter_view);
  g_bytes_unref(hourly_view);
  g_bytes_unref(again);
  g_bytes_unref(again_h);
  fixture_free(&f);
}

/* The fixed views: HOURLY ignores the nowcast, NOWCAST shows only the nowcast, and each draws
 * exactly what an AUTO chart draws for the data that selects that view. */
static void
test_chart_fixed_views(void)
{
  g_autoptr(WxForecast) with_nc = make_forecast(T_HOUR0, 30, 12, 0);
  g_autoptr(WxForecast) without = make_forecast(T_HOUR0, 30, 0, 0);
  Fixture fa = fixture_new(wx_rain_chart_new());
  Fixture fh = fixture_new(wx_rain_chart_new());
  Fixture fn = fixture_new(wx_rain_chart_new());
  WxRainChart *autoc = WX_RAIN_CHART(fa.widget);
  WxRainChart *hourly = WX_RAIN_CHART(fh.widget);
  WxRainChart *nowcast = WX_RAIN_CHART(fn.widget);
  wx_rain_chart_set_view(hourly, WX_RAIN_CHART_HOURLY);
  wx_rain_chart_set_view(nowcast, WX_RAIN_CHART_NOWCAST);
  g_assert_false(wx_rain_chart_has_data(autoc));
  g_assert_false(wx_rain_chart_has_data(hourly));
  g_assert_false(wx_rain_chart_has_data(nowcast));

  /* with a nowcast: HOURLY draws the hourly view of the forecast without one, NOWCAST the
   * 15-minute view that AUTO chooses */
  wx_rain_chart_set_forecast(autoc, without, WX_UNITS_METRIC, NOW);
  GBytes *auto_hourly = snap(fa.widget);
  wx_rain_chart_set_forecast(hourly, with_nc, WX_UNITS_METRIC, NOW);
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, NOW);
  GBytes *hourly_bytes = snap(fh.widget);
  g_assert_true(g_bytes_equal(auto_hourly, hourly_bytes));
  g_assert_cmpuint(counts(fh.widget).stroke, ==, 1); /* the chance line: the hourly view */
  g_assert_true(wx_rain_chart_has_data(hourly));
  wx_rain_chart_set_forecast(autoc, with_nc, WX_UNITS_METRIC, NOW);
  GBytes *auto_quarters = snap(fa.widget);
  GBytes *nowcast_bytes = snap(fn.widget);
  g_assert_true(g_bytes_equal(auto_quarters, nowcast_bytes));
  g_assert_cmpuint(counts(fn.widget).stroke, ==, 0);
  g_assert_true(wx_rain_chart_has_data(nowcast));
  g_assert_false(g_bytes_equal(hourly_bytes, nowcast_bytes));

  /* without a nowcast: HOURLY is unchanged, NOWCAST has nothing to show */
  wx_rain_chart_set_forecast(hourly, without, WX_UNITS_METRIC, NOW);
  g_assert_true(g_bytes_equal(hourly_bytes, auto_hourly));
  wx_rain_chart_set_forecast(nowcast, without, WX_UNITS_METRIC, NOW);
  g_assert_false(wx_rain_chart_has_data(nowcast));
  Counts c = counts(fn.widget);
  g_assert_cmpuint(c.color, ==, 0);
  g_assert_cmpuint(c.stroke, ==, 0);
  g_assert_cmpuint(c.text, ==, 1); /* "No data" */
  /* nothing at all */
  wx_rain_chart_set_forecast(nowcast, NULL, WX_UNITS_METRIC, NOW);
  g_assert_false(wx_rain_chart_has_data(nowcast));
  wx_rain_chart_set_forecast(hourly, NULL, WX_UNITS_METRIC, NOW);
  g_assert_false(wx_rain_chart_has_data(hourly));

  /* the nowcast ends: the covering quarter is judged as for AUTO */
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, NOW);
  g_assert_true(wx_rain_chart_has_data(nowcast));
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, T_HOUR0 + 4 * 3600);
  g_assert_false(wx_rain_chart_has_data(nowcast));

  /* changing the view discards the window until the next set_forecast(); the same view keeps it */
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, NOW);
  wx_rain_chart_set_view(nowcast, WX_RAIN_CHART_NOWCAST);
  g_assert_true(wx_rain_chart_has_data(nowcast));
  wx_rain_chart_set_view(nowcast, WX_RAIN_CHART_HOURLY);
  g_assert_false(wx_rain_chart_has_data(nowcast));
  g_assert_cmpuint(counts(fn.widget).text, ==, 1);
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, NOW);
  g_autoptr(GBytes) again_h = snap(fn.widget);
  g_assert_true(g_bytes_equal(again_h, hourly_bytes));
  wx_rain_chart_set_view(nowcast, WX_RAIN_CHART_AUTO);
  g_assert_false(wx_rain_chart_has_data(nowcast));
  wx_rain_chart_set_forecast(nowcast, with_nc, WX_UNITS_METRIC, NOW);
  g_autoptr(GBytes) again_q = snap(fn.widget);
  g_assert_true(g_bytes_equal(again_q, auto_quarters));

  /* programmer errors */
  ASSERT_CRITICAL("wx_rain_chart_set_view", wx_rain_chart_set_view(NULL, WX_RAIN_CHART_AUTO));
  ASSERT_CRITICAL("wx_rain_chart_set_view", wx_rain_chart_set_view(hourly, (WxRainChartView)3));
  ASSERT_CRITICAL("wx_rain_chart_set_view", wx_rain_chart_set_view(hourly, (WxRainChartView)-1));
  g_assert_true(wx_rain_chart_has_data(autoc));
  ASSERT_CRITICAL("wx_rain_chart_has_data", g_assert_false(wx_rain_chart_has_data(NULL)));

  /* after dispose: harmless, no data (a parented widget must not be disposed) */
  g_object_ref(autoc);
  gtk_window_set_child(GTK_WINDOW(fa.window), NULL);
  g_object_run_dispose(G_OBJECT(autoc));
  wx_rain_chart_set_view(autoc, WX_RAIN_CHART_HOURLY);
  g_assert_false(wx_rain_chart_has_data(autoc));
  g_object_unref(autoc);

  g_bytes_unref(auto_hourly);
  g_bytes_unref(hourly_bytes);
  g_bytes_unref(auto_quarters);
  g_bytes_unref(nowcast_bytes);
  fixture_free(&fa);
  fixture_free(&fh);
  fixture_free(&fn);
}

static guint chart_snapshots;
static void (*orig_chart_snapshot)(GtkWidget *, GtkSnapshot *);

static void
counting_snapshot(GtkWidget *w, GtkSnapshot *s)
{
  chart_snapshots++;
  orig_chart_snapshot(w, s);
}

static void
wait_snapshots(guint from, guint min)
{
  gint64 end = g_get_monotonic_time() + 10 * G_USEC_PER_SEC;
  while (chart_snapshots - from < min && g_get_monotonic_time() < end)
    pump(10);
  g_assert_cmpuint(chart_snapshots - from, >=, min);
}

static void
settle(void)
{
  gint64 deadline = g_get_monotonic_time() + 15 * G_USEC_PER_SEC;
  guint seen = chart_snapshots;
  gint64 quiet_since = g_get_monotonic_time();
  while (g_get_monotonic_time() < deadline) {
    pump(10);
    if (chart_snapshots != seen) {
      seen = chart_snapshots;
      quiet_since = g_get_monotonic_time();
    } else if (g_get_monotonic_time() - quiet_since >= 500 * 1000) {
      return;
    }
  }
  g_assert_not_reached();
}

/* Idle: no repaint; compare-before-set: an unchanged forecast queues no redraw. */
static void
test_chart_idle_and_redraw(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 40, 0, 0);
  g_autoptr(WxForecast) same = make_forecast(T_HOUR0, 40, 0, 0); /* equal content, other object */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW);

  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;
  settle();
  guint base = chart_snapshots;
  pump(400);
  g_assert_cmpuint(chart_snapshots, ==, base); /* idle: no repaint, no animation */

  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW); /* identical */
  wx_rain_chart_set_forecast(chart, same, WX_UNITS_IMPERIAL, NOW);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW + 60); /* same hour: same window */
  pump(400);
  g_assert_cmpuint(chart_snapshots, ==, base);

  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW); /* units changed */
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;

  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW + 3600); /* next hour: window moved */
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;

  g_autoptr(WxForecast) utc = make_forecast_in("UTC", T_HOUR0, 40, 0, 0); /* same data, other zone */
  wx_rain_chart_set_forecast(chart, utc, WX_UNITS_METRIC, NOW + 3600);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW + 3600); /* and back */
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;

  g_autoptr(WxForecast) other = make_forecast(T_HOUR0, 39, 0, 0); /* one hour fewer: last slot differs */
  wx_rain_chart_set_forecast(chart, other, WX_UNITS_METRIC, NOW + 3600);
  pump(400);
  g_assert_cmpuint(chart_snapshots, ==, base); /* hour 40 is outside the window: window unchanged */

  g_autoptr(WxForecast) other2 = make_forecast(T_HOUR0, 20, 0, 0); /* fewer hours: slots became empty */
  wx_rain_chart_set_forecast(chart, other2, WX_UNITS_METRIC, NOW + 3600);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;

  wx_rain_chart_set_forecast(chart, NULL, WX_UNITS_METRIC, NOW + 3600);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  wx_rain_chart_set_forecast(chart, NULL, WX_UNITS_METRIC, NOW + 3600); /* nothing to clear */
  pump(400);
  g_assert_cmpuint(chart_snapshots, ==, base);

  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
}

/* Compare-before-set across a view change, and no zone lookup in snapshot() or an unchanged set. */
static void
test_chart_view_switch_redraw_and_no_zone_io(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  /* a zone no other test loaded, so that its first use is visible in the counter */
  g_autoptr(WxPlace) place = make_place_in("Pacific/Chatham");
  WxBlendHour hs[30];
  WxQuarter qs[12];
  for (guint i = 0; i < 30; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = i % 3 == 0 ? 1.5 : 0.0;
  }
  for (guint i = 0; i < 12; i++)
    qs[i] = (WxQuarter){ T_HOUR0 + (gint64)i * 900, 0.5 };
  g_autoptr(WxForecast) with_nc = wx_forecast_new(place, NOW, hs, 30, qs, 12, NULL, 0, NULL, 0, NULL);
  g_autoptr(WxForecast) without = wx_forecast_new(place, NOW, hs, 30, NULL, 0, NULL, 0, NULL, 0, NULL);

  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;
  wx_format_test_set_hooks(NULL, NULL); /* an empty zone cache: Pacific/Chatham is not loaded */
  guint loads0 = wx_format_zone_loads();
  /* now = 18:00Z sharp: the quarter view and the hourly view then start at the same instant, so
   * only the view itself tells them apart */
  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, T_HOUR0);
  guint loads1 = wx_format_zone_loads();
  g_assert_cmpuint(loads1, ==, loads0 + 1); /* the SETTER loaded Pacific/Chatham, once ... */
  wait_snapshots(0, 1);
  settle();
  g_assert_cmpuint(wx_format_zone_loads(), ==, loads1); /* ... and drawing the first frame did not */
  guint base = chart_snapshots;
  pump(300);
  g_assert_cmpuint(chart_snapshots, ==, base);

  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, T_HOUR0); /* unchanged */
  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, T_HOUR0 + 60);
  pump(300);
  g_assert_cmpuint(chart_snapshots, ==, base);

  wx_rain_chart_set_forecast(chart, without, WX_UNITS_METRIC, T_HOUR0); /* view changes, window start does not */
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  wx_rain_chart_set_forecast(chart, with_nc, WX_UNITS_METRIC, T_HOUR0);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  wx_rain_chart_set_forecast(chart, without, WX_UNITS_METRIC, T_HOUR0 + 1800 + 900); /* 18:45: no quarter 18:45... */
  wait_snapshots(base, 1);
  settle();

  /* snapshots and unchanged sets never load a zone again */
  guint loads2 = wx_format_zone_loads();
  for (int i = 0; i < 20; i++) {
    g_bytes_unref(snap(f.widget));
    wx_rain_chart_set_forecast(chart, without, WX_UNITS_METRIC, T_HOUR0 + 1800 + 900);
  }
  g_assert_cmpuint(wx_format_zone_loads(), ==, loads2);
  g_assert_cmpuint(loads2, ==, loads1); /* and the view changes above reused the one load */

  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
}

/* Two views whose first eight slots hold the same values still count as different data. */
static void
test_chart_view_change_with_equal_first_slots(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  g_autoptr(WxPlace) place = make_place();
  WxQuarter qs[8];
  WxBlendHour hs[8];
  for (guint i = 0; i < 8; i++) {
    qs[i] = (WxQuarter){ T_HOUR0 + (gint64)i * 900, 0.0 };
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = 0.0;
    hs[i].precip_prob = NAN;
  }
  g_autoptr(WxForecast) quarter_data = wx_forecast_new(place, NOW, NULL, 0, qs, 8, NULL, 0, NULL, 0, NULL);
  g_autoptr(WxForecast) hourly_data = wx_forecast_new(place, NOW, hs, 8, NULL, 0, NULL, 0, NULL, 0, NULL);

  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;
  wx_rain_chart_set_forecast(chart, quarter_data, WX_UNITS_METRIC, T_HOUR0);
  wait_snapshots(0, 1);
  settle();
  GBytes *quarter_view = snap(f.widget);
  guint base = chart_snapshots;
  wx_rain_chart_set_forecast(chart, hourly_data, WX_UNITS_METRIC, T_HOUR0);
  wait_snapshots(base, 1); /* the view changed although slots 0..7 hold the same zeros */
  settle();
  GBytes *hourly_view = snap(f.widget);
  g_assert_false(g_bytes_equal(quarter_view, hourly_view));
  g_bytes_unref(quarter_view);
  g_bytes_unref(hourly_view);
  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
}

/* Drawing and unchanged setter calls never resolve a zone: the widgets hold the GTimeZone they
 * resolved when the zone changed, so evicting it from the shared cache cannot make them read a file.
 * Zones that no earlier test used (the cache is emptied first), a dry window and a window with rain
 * now (so the labels, the description and the peak text are all produced), all three widgets. */
static GPtrArray *find_all(GtkWidget *root, const char *css_class);

static void
evict_cache_with_other_zones(void)
{
  for (int i = 1; i <= 9; i++) { /* more than the 8 slots */
    char name[24];
    g_snprintf(name, sizeof name, "Etc/GMT-%d", i);
    g_free(wx_format_hour_label(T_HOUR0, name));
  }
}

static WxForecast *
make_wet_or_dry_forecast(const char *tz, gboolean wet)
{
  WxBlendHour hs[30];
  WxQuarter qs[12];
  WxDay days[3];
  for (guint i = 0; i < 30; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = wet ? 2.0 : 0.0;
    hs[i].precip_prob = wet ? 80.0 : 0.0;
  }
  for (guint i = 0; i < 12; i++)
    qs[i] = (WxQuarter){ T_HOUR0 + (gint64)i * 900, wet ? 0.5 : 0.0 };
  for (guint i = 0; i < 3; i++)
    days[i] = (WxDay){ .start_s = ts(2026, 10, 10, 0, 0) + (gint64)i * 86400, .temp_max_c = 30, .temp_min_c = 20,
                       .precip_mm = wet ? 5.0 : 0.0, .precip_prob_max = wet ? 80.0 : 0.0, .cloud_pct = 50,
                       .condition = wet ? WX_COND_RAIN : WX_COND_CLEAR };
  g_autoptr(WxPlace) place = make_place_in(tz);
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, NOW, hs, 30, qs, 12, days, 3, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

static void
test_no_zone_resolution_at_draw_time(void)
{
  for (int wet = 0; wet < 2; wet++) {
    wx_format_test_set_hooks(NULL, NULL);
    /* --- WxRainChart, hourly view and 15-minute view --- */
    for (int view = 0; view < 2; view++) {
      Fixture f = fixture_new(wx_rain_chart_new());
      g_autoptr(WxForecast) fc = make_wet_or_dry_forecast("Asia/Kathmandu", wet);
      g_autoptr(WxForecast) hourly_only = NULL;
      WxBlendHour one = hour(T_HOUR0);
      one.precip_mm = wet ? 2.0 : 0.0;
      g_autoptr(WxPlace) place = make_place_in("Asia/Kathmandu");
      hourly_only = wx_forecast_new(place, NOW, &one, 1, NULL, 0, NULL, 0, NULL, 0, NULL);
      wx_format_test_set_hooks(NULL, NULL);
      guint loads = wx_format_zone_loads();
      wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), view ? fc : hourly_only, WX_UNITS_METRIC, NOW);
      g_assert_cmpuint(wx_format_zone_loads(), ==, loads + 1); /* the setter resolved the zone, once */
      loads++;
      GBytes *first = snap(f.widget); /* the first frame */
      g_assert_cmpuint(wx_format_zone_loads(), ==, loads);
      g_assert_cmpuint(counts(f.widget).text, >, 1); /* the labels were drawn */
      evict_cache_with_other_zones();
      loads += 9;
      g_assert_cmpuint(wx_format_zone_loads(), ==, loads);
      GBytes *again = snap(f.widget); /* a redraw after the shared cache lost the zone */
      gtk_widget_queue_draw(f.widget);
      pump(50);
      wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), view ? fc : hourly_only, WX_UNITS_METRIC, NOW); /* unchanged */
      g_assert_cmpuint(wx_format_zone_loads(), ==, loads);
      g_assert_true(g_bytes_equal(first, again));
      g_bytes_unref(first);
      g_bytes_unref(again);
      fixture_free(&f);
    }

    /* --- WxHourStrip: binding, an unchanged set, a units change (rebinds every card) --- */
    GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
    g_autoptr(WxForecast) fs = make_wet_or_dry_forecast("Pacific/Chatham", wet);
    wx_format_test_set_hooks(NULL, NULL);
    guint loads = wx_format_zone_loads();
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fs, WX_UNITS_METRIC, NOW);
    g_assert_cmpuint(wx_format_zone_loads(), ==, loads + 1);
    loads++;
    evict_cache_with_other_zones();
    loads += 9;
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fs, WX_UNITS_METRIC, NOW);          /* unchanged */
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fs, WX_UNITS_IMPERIAL, NOW);        /* every card re-bound */
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fs, WX_UNITS_IMPERIAL, NOW + 3600); /* cards shift */
    g_assert_cmpuint(wx_format_zone_loads(), ==, loads);
    g_autoptr(GPtrArray) hour_labels = find_all(strip, "hour");
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "9:45 AM"); /* 20:00Z in Chatham, +13:45 */
    g_object_unref(strip);

    /* --- WxDayList: the day-end test and the labels --- */
    GtkWidget *list = g_object_ref_sink(wx_day_list_new());
    g_autoptr(WxForecast) fd = make_wet_or_dry_forecast("Asia/Kolkata", wet);
    wx_format_test_set_hooks(NULL, NULL);
    loads = wx_format_zone_loads();
    wx_day_list_set_forecast(WX_DAY_LIST(list), fd, WX_UNITS_METRIC, NOW);
    g_assert_cmpuint(wx_format_zone_loads(), ==, loads + 1);
    loads++;
    evict_cache_with_other_zones();
    loads += 9;
    wx_day_list_set_forecast(WX_DAY_LIST(list), fd, WX_UNITS_METRIC, NOW);                /* unchanged */
    wx_day_list_set_forecast(WX_DAY_LIST(list), fd, WX_UNITS_IMPERIAL, NOW);              /* rebinds */
    wx_day_list_set_forecast(WX_DAY_LIST(list), fd, WX_UNITS_IMPERIAL, NOW + 86400);      /* labels + day end */
    wx_day_list_set_forecast(WX_DAY_LIST(list), fd, WX_UNITS_IMPERIAL, NOW + 2 * 86400);  /* a day is over */
    g_assert_cmpuint(wx_format_zone_loads(), ==, loads);
    g_object_unref(list);
  }
  wx_format_test_set_hooks(NULL, NULL);
}

/* Huge and hostile data: bounded drawing, no crash. */
static void
test_chart_huge_inputs(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  Fixture g = fixture_new(wx_rain_chart_new());
  WxRainChart *qchart = WX_RAIN_CHART(g.widget);

  WxBlendHour *hs = g_new(WxBlendHour, WX_FORECAST_MAX_HOURS);
  WxQuarter *qs = g_new(WxQuarter, WX_FORECAST_MAX_QUARTERS);
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = 500.0; /* the maximum rate */
    hs[i].precip_prob = 100.0;
  }
  for (guint i = 0; i < WX_FORECAST_MAX_QUARTERS; i++)
    qs[i] = (WxQuarter){ T_HOUR0 + (gint64)i * 900, 500.0 };
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, hs, WX_FORECAST_MAX_HOURS, NULL, 0, NULL, 0,
                                             NULL, 0, NULL);
  g_autoptr(WxForecast) fq = wx_forecast_new(place, NOW, hs, WX_FORECAST_MAX_HOURS, qs,
                                             WX_FORECAST_MAX_QUARTERS, NULL, 0, NULL, 0, NULL);
  g_assert_nonnull(fc);
  g_assert_nonnull(fq);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  wx_rain_chart_set_forecast(qchart, fq, WX_UNITS_IMPERIAL, NOW);
  Counts c = counts(f.widget);
  g_assert_cmpuint(c.color, ==, 3 + WX_RAIN_CHART_HOURS); /* bars are capped at the window */
  g_assert_cmpuint(c.stroke, ==, 1);
  g_assert_cmpuint(c.text, <=, 8);
  c = counts(g.widget);
  g_assert_cmpuint(c.color, ==, 3 + WX_RAIN_CHART_QUARTER_SLOTS);
  g_assert_cmpuint(c.text, <=, 6);
  GBytes *b = snap(f.widget);
  g_assert_cmpuint(g_bytes_get_size(b), <, 64 * 1024);
  g_bytes_unref(b);

  /* every value unknown or out of range: nothing to draw */
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++) {
    hs[i].precip_mm = i % 2 ? NAN : -5.0;
    hs[i].precip_prob = i % 2 ? 1e300 : INFINITY;
  }
  g_autoptr(WxForecast) bad = wx_forecast_new(place, NOW, hs, WX_FORECAST_MAX_HOURS, NULL, 0, NULL, 0,
                                              NULL, 0, NULL);
  g_assert_nonnull(bad);
  wx_rain_chart_set_forecast(chart, bad, WX_UNITS_METRIC, NOW);
  g_assert_false(HAS_DATA(chart));

  /* hand-built forecast with values wx_forecast_new() would have normalised: still safe */
  for (guint i = 0; i < 30; i++) {
    hs[i].precip_mm = i % 2 ? 1e300 : 500.0;
    hs[i].precip_prob = i % 2 ? -3 : 250;
  }
  WxForecast raw = { .hours = hs, .n_hours = 30 };
  raw.place.timezone = (char *)"";
  wx_rain_chart_set_forecast(chart, &raw, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart)); /* the even slots: 500 mm/h, no valid chance */
  Counts rc = counts(f.widget);
  g_assert_cmpuint(rc.color, ==, 3 + 12);
  g_assert_cmpuint(rc.stroke, ==, 0);

  /* extreme now values never crash and never show data */
  gint64 nows[] = { G_MININT64, G_MAXINT64, 0, -1, WX_TIME_MAX_S, WX_TIME_MIN_S };
  for (guint i = 0; i < G_N_ELEMENTS(nows); i++) {
    wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, nows[i]);
    wx_rain_chart_set_forecast(qchart, fq, WX_UNITS_METRIC, nows[i]);
    g_bytes_unref(snap(f.widget));
  }
  g_free(hs);
  g_free(qs);
  fixture_free(&f);
  fixture_free(&g);
}

/* Time labels that would overlap are skipped, so a narrow chart shows fewer of them. */
static void
test_chart_narrow_skips_overlapping_labels(void)
{
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 30, 12, 0);
  Fixture wide = fixture_new_sized(wx_rain_chart_new(), 600, 200);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(wide.widget), fc, WX_UNITS_METRIC, NOW);
  Fixture narrow = fixture_new_sized(wx_rain_chart_new(), 100, 100);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(narrow.widget), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpint(gtk_widget_get_width(narrow.widget), ==, 160); /* the minimum width */
  guint wide_texts = counts(wide.widget).text;
  guint narrow_texts = counts(narrow.widget).text;
  g_assert_cmpuint(wide_texts, ==, 1 + 5);  /* top-of-scale + five time labels */
  g_assert_cmpuint(narrow_texts, >=, 1 + 1); /* "Now" is always shown */
  g_assert_cmpuint(narrow_texts, <, wide_texts);
  fixture_free(&wide);
  fixture_free(&narrow);
}

/* Only zero amounts: the chart has data (an empty plot with its scale), no bars. */
static void
test_chart_all_dry(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxQuarter qs[8];
  for (guint i = 0; i < 8; i++)
    qs[i] = (WxQuarter){ T_HOUR0 + 1800 + (gint64)i * 900, 0.0 };
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, qs, 8, NULL, 0, NULL, 0, NULL);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), fc, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(WX_RAIN_CHART(f.widget)));
  Counts c = counts(f.widget);
  g_assert_cmpuint(c.color, ==, 3);
  g_assert_cmpuint(c.stroke, ==, 0);
  fixture_free(&f);
}

/* No allocation, or less than the plot needs: nothing is drawn and nothing breaks. */
static void
test_chart_tiny_allocation(void)
{
  GtkWidget *chart = g_object_ref_sink(wx_rain_chart_new());
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0 - 3600, 40, 0, 0);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(chart), fc, WX_UNITS_METRIC, NOW);
  g_assert_null(snap_node(chart)); /* never allocated */
  gtk_widget_allocate(chart, 12, 30, -1, NULL);
  g_assert_cmpint(gtk_widget_get_width(chart), ==, 12);
  g_assert_null(snap_node(chart)); /* plot narrower than a pixel after the labels */
  gtk_widget_allocate(chart, 200, 12, -1, NULL);
  g_assert_null(snap_node(chart)); /* plot lower than a pixel after the axis */
  gtk_widget_allocate(chart, 200, 100, -1, NULL);
  GskRenderNode *node = snap_node(chart);
  g_assert_nonnull(node);
  gsk_render_node_unref(node);
  g_object_unref(chart);
}

static void
test_chart_dispose(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = g_object_ref(WX_RAIN_CHART(f.widget));
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 40, 0, 0);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  g_assert_true(HAS_DATA(chart));
  gtk_window_set_child(GTK_WINDOW(f.window), NULL); /* disposing a parented widget is a GTK error */
  g_object_run_dispose(G_OBJECT(chart));
  g_assert_false(HAS_DATA(chart));
  /* every method is a no-op and nothing is drawn */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_false(HAS_DATA(chart));
  g_assert_null(snap_node(GTK_WIDGET(chart)));
  g_object_run_dispose(G_OBJECT(chart)); /* twice */
  fixture_free(&f);
  g_object_unref(chart); /* the last reference: finalize after dispose */
}

/* Replacing the child while the chart is in a window and dropping the window with data. */
static void
test_chart_dispose_in_window(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 40, 12, 0);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), fc, WX_UNITS_METRIC, NOW);
  pump(100);
  fixture_free(&f);
}

static GdkRGBA
widget_color(GtkWidget *w)
{
  GdkRGBA c;
  gtk_widget_get_color(w, &c);
  return c;
}

/* The fallback style gives the chart a colour of its own (the bare theme has none). */
static void
test_chart_fallback_colour(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  pump(50);
  GdkRGBA c = widget_color(f.widget);
  GdkRGBA want;
  g_assert_true(gdk_rgba_parse(&want, "#3584e4"));
  g_assert_true(gdk_rgba_equal(&c, &want));
  /* application CSS (higher priority) wins over the fallback */
  GtkCssProvider *p = gtk_css_provider_new();
  gtk_css_provider_load_from_string(p, "wx-rain-chart { color: #112233; }");
  gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p),
                                             GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  pump(50);
  c = widget_color(f.widget);
  g_assert_true(gdk_rgba_parse(&want, "#112233"));
  g_assert_true(gdk_rgba_equal(&c, &want));
  gtk_style_context_remove_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p));
  g_object_unref(p);
  fixture_free(&f);
}

/* ------------------------------------------------------------------ */
/* tree helpers for the standard-widget lists                         */
/* ------------------------------------------------------------------ */

static void
collect(GtkWidget *root, const char *css_class, GPtrArray *out)
{
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL; c = gtk_widget_get_next_sibling(c)) {
    if (gtk_widget_has_css_class(c, css_class))
      g_ptr_array_add(out, c);
    collect(c, css_class, out);
  }
}

static GPtrArray *
find_all(GtkWidget *root, const char *css_class)
{
  GPtrArray *a = g_ptr_array_new();
  collect(root, css_class, a);
  return a;
}

static const char *
label_in(GtkWidget *card, const char *css_class)
{
  g_autoptr(GPtrArray) a = find_all(card, css_class);
  g_assert_cmpuint(a->len, ==, 1);
  g_assert_true(GTK_IS_LABEL(a->pdata[0]));
  return gtk_label_get_text(GTK_LABEL(a->pdata[0]));
}

static GtkWidget *
image_in(GtkWidget *card)
{
  for (GtkWidget *c = gtk_widget_get_first_child(card); c != NULL; c = gtk_widget_get_next_sibling(c))
    if (GTK_IS_IMAGE(c))
      return c;
  g_assert_not_reached();
}

static guint
visible_count(GPtrArray *a)
{
  guint n = 0;
  for (guint i = 0; i < a->len; i++)
    if (gtk_widget_get_visible(a->pdata[i]))
      n++;
  return n;
}

/* ------------------------------------------------------------------ */
/* WxHourStrip                                                        */
/* ------------------------------------------------------------------ */

static void
test_strip_basic(void)
{
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_assert_cmpstr(gtk_widget_get_css_name(strip), ==, "wx-hour-strip");
  g_autoptr(GPtrArray) cards = find_all(strip, "hour-card");
  g_assert_cmpuint(cards->len, ==, WX_HOUR_STRIP_MAX_CARDS);
  g_assert_cmpuint(visible_count(cards), ==, 0);

  /* 60 hours starting one hour before the current one: the first card is the current hour */
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0 - 3600, 60, 0, 0);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_cmpuint(visible_count(cards), ==, 48);
  GtkWidget *c0 = cards->pdata[0];
  GtkWidget *c1 = cards->pdata[1];
  GtkWidget *c47 = cards->pdata[47];
  g_assert_cmpstr(label_in(c0, "hour"), ==, "Now");
  g_assert_cmpstr(label_in(c1, "hour"), ==, "3 PM"); /* 19:00Z */
  g_assert_cmpstr(label_in(c47, "hour"), ==, "1 PM"); /* 47 h after 2 PM */
  /* The Now card shows the values AT now (18:30), interpolated between hour index 1 (21 C) and
   * index 2 (22 C) as the header of the detail pane does: 21.5 C -> 70.7 F -> 71. Chance 15 %,
   * cloud 40 % and the dry hour are those of the bucket. */
  g_assert_cmpstr(label_in(c0, "temp"), ==, "71" "\xc2\xb0");
  g_assert_cmpstr(label_in(c0, "rain"), ==, "Rain 15%");
  g_assert_cmpstr(label_in(c0, "cloud"), ==, "Cloud 40%");
  g_assert_cmpstr(gtk_image_get_icon_name(GTK_IMAGE(image_in(c0))), ==, "weather-few-clouds-symbolic");
  const char *tip = gtk_widget_get_tooltip_text(c0);
  g_assert_nonnull(tip);
  /* the tooltip of the Now card names the moment its values are for: 2:30 PM */
  g_assert_cmpstr(tip, ==, "2:30 PM\nFeels like 81\xc2\xb0" "F\nWind 12 mph\nRain 0 in");

  /* units change re-binds every card */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(c0, "temp"), ==, "22" "\xc2\xb0"); /* 21.5 C */
  g_assert_cmpstr(gtk_widget_get_tooltip_text(c0), ==, "2:30 PM\nFeels like 27\xc2\xb0" "C\nWind 19 km/h\nRain 0 mm");

  /* fewer hours: the rest are hidden; later hours are shown again */
  g_autoptr(WxForecast) few = make_forecast(T_HOUR0, 3, 0, 0);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), few, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(cards), ==, 3);
  g_assert_cmpstr(label_in(cards->pdata[2], "hour"), ==, "4 PM");
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(cards), ==, 48);
  g_assert_cmpstr(label_in(c47, "hour"), ==, "1 PM");

  /* "Now" moves on with the clock */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW + 3600);
  g_assert_cmpuint(visible_count(cards), ==, 48); /* 60 hours, first is index 2 -> 58 left */
  g_assert_cmpstr(label_in(c0, "hour"), ==, "Now");
  g_assert_cmpstr(label_in(c1, "hour"), ==, "4 PM");
  /* exactly at the end of an hour the next one is the current hour */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, T_HOUR0 + 3600);
  g_assert_cmpstr(label_in(c0, "hour"), ==, "Now");
  g_assert_cmpstr(label_in(c1, "hour"), ==, "4 PM");
  /* before the first hour starts: the first hour is not "now" */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, T_HOUR0 - 3 * 3600);
  g_assert_cmpstr(label_in(c0, "hour"), ==, "1 PM");

  /* the tail of the forecast: fewer than 48 left */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, T_HOUR0 + 55 * 3600);
  g_assert_cmpuint(visible_count(cards), ==, 4); /* indices 56..59 */

  /* NULL, bad now: nothing */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), NULL, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(cards), ==, 0);
  gint64 nows[] = { 0, G_MAXINT64, G_MININT64, WX_TIME_MAX_S };
  for (guint i = 0; i < G_N_ELEMENTS(nows); i++) {
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, nows[i]);
    g_assert_cmpuint(visible_count(cards), ==, 0);
  }
  g_object_unref(strip);
}

static void
test_strip_missing_values(void)
{
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_autoptr(GPtrArray) cards = find_all(strip, "hour-card");
  /* 00:00 local at night: the Now card takes is_day from the sun at now (as the detail header
   * does), so the night icon needs a real night */
  gint64 night = ts(2026, 10, 12, 4, 0);
  WxBlendHour h = hour(night);
  h.temp_c = NAN;
  h.precip_prob = NAN;
  h.cloud_pct = NAN;
  h.is_day = FALSE;
  h.condition = WX_COND_CLEAR;
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, &h, 1, NULL, 0, NULL, 0, NULL, 0, NULL);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, night + 1800);
  GtkWidget *c0 = cards->pdata[0];
  g_assert_cmpstr(label_in(c0, "temp"), ==, "\xe2\x80\x94");
  g_assert_cmpstr(label_in(c0, "rain"), ==, "Rain \xe2\x80\x94");
  g_assert_cmpstr(label_in(c0, "cloud"), ==, "Cloud \xe2\x80\x94");
  g_assert_cmpstr(gtk_image_get_icon_name(GTK_IMAGE(image_in(c0))), ==, "weather-clear-night-symbolic");
  g_object_unref(strip);
}

/* Compare-before-set: a card whose data did not change is not touched. */
static void
test_strip_compare_before_set(void)
{
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_autoptr(GPtrArray) cards = find_all(strip, "hour-card");
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 10, 0, 0);
  g_autoptr(WxForecast) same = make_forecast(T_HOUR0, 10, 0, 0);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  /* scribble on a card; an unchanged set must leave it alone */
  g_autoptr(GPtrArray) temps = find_all(strip, "temp");
  gtk_label_set_text(GTK_LABEL(temps->pdata[2]), "scribble");
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), same, WX_UNITS_METRIC, NOW);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), same, WX_UNITS_METRIC, NOW + 100); /* same hour */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[2])), ==, "scribble");
  /* a changed zone restores it too (the hour labels change) */
  g_autoptr(WxForecast) utc = make_forecast_in("UTC", T_HOUR0, 10, 0, 0);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), utc, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[2])), !=, "scribble");
  g_autoptr(GPtrArray) hour_labels = find_all(strip, "hour");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "7 PM");
  gtk_label_set_text(GTK_LABEL(temps->pdata[2]), "scribble");
  /* a changed unit, or changed data in that card, restores it */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[2])), !=, "scribble");
  gtk_label_set_text(GTK_LABEL(temps->pdata[2]), "scribble");
  gtk_label_set_text(GTK_LABEL(temps->pdata[1]), "scribble");
  WxBlendHour hs[10];
  for (guint i = 0; i < 10; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = i % 3 == 0 ? 1.5 : 0.0;
    hs[i].precip_prob = 10.0 * (i % 10) + 5.0;
    hs[i].temp_c = 20.0 + (double)(i % 10);
  }
  hs[1].temp_c = 99 - 40; /* card 1 only */
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) changed = wx_forecast_new(place, NOW, hs, 10, NULL, 0, NULL, 0, NULL, 0, NULL);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), changed, WX_UNITS_IMPERIAL, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), ==, "138\xc2\xb0");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[2])), ==, "scribble"); /* unchanged card */
  g_object_unref(strip);
}

static void
test_strip_dispose(void)
{
  Fixture f = fixture_new(wx_hour_strip_new());
  WxHourStrip *strip = g_object_ref(WX_HOUR_STRIP(f.widget));
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 60, 0, 0);
  wx_hour_strip_set_forecast(strip, fc, WX_UNITS_METRIC, NOW);
  gtk_window_set_child(GTK_WINDOW(f.window), NULL);
  g_object_run_dispose(G_OBJECT(strip));
  g_assert_null(gtk_widget_get_first_child(GTK_WIDGET(strip)));
  wx_hour_strip_set_forecast(strip, fc, WX_UNITS_IMPERIAL, NOW); /* no-op */
  wx_hour_strip_set_forecast(strip, NULL, WX_UNITS_IMPERIAL, NOW);
  g_object_run_dispose(G_OBJECT(strip));
  fixture_free(&f);
  g_object_unref(strip);
}

static void
test_strip_null_arguments(void)
{
  ASSERT_CRITICAL("wx_hour_strip_set_forecast",
                  wx_hour_strip_set_forecast(NULL, NULL, WX_UNITS_METRIC, NOW));
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  ASSERT_CRITICAL("wx_hour_strip_set_forecast",
                  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), NULL, (WxUnits)9, NOW));
  g_object_unref(strip);
}

/* The strip lays out and scrolls horizontally inside a window. */
static void
test_strip_in_window(void)
{
  Fixture f = fixture_new(wx_hour_strip_new());
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 60, 0, 0);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(f.widget), fc, WX_UNITS_METRIC, NOW);
  pump(100);
  g_autoptr(GPtrArray) cards = find_all(f.widget, "hour-card");
  GtkWidget *last = cards->pdata[47];
  /* 48 cards cannot fit in 440 px: the last one is laid out beyond the window */
  graphene_rect_t b;
  g_assert_true(gtk_widget_compute_bounds(last, f.widget, &b));
  g_assert_cmpfloat(b.origin.x, >, (float)WIN_W);
  fixture_free(&f);
}

/* ------------------------------------------------------------------ */
/* WxDayList                                                          */
/* ------------------------------------------------------------------ */

static void
test_days_basic(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_assert_cmpstr(gtk_widget_get_css_name(list), ==, "wx-day-list");
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  g_assert_cmpuint(rows->len, ==, WX_DAY_LIST_MAX_ROWS);
  g_assert_cmpuint(visible_count(rows), ==, 0);

  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 10, 0, 16);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_cmpuint(visible_count(rows), ==, 10); /* 16 days, at most 10 rows */
  GtkWidget *r0 = rows->pdata[0];
  GtkWidget *r1 = rows->pdata[1];
  GtkWidget *r2 = rows->pdata[2];
  g_assert_cmpstr(label_in(r0, "day"), ==, "Today");
  g_assert_cmpstr(label_in(r1, "day"), ==, "Tomorrow");
  g_assert_cmpstr(label_in(r2, "day"), ==, "Tuesday");
  g_assert_cmpstr(label_in(rows->pdata[9], "day"), ==, "Tuesday"); /* Oct 20 */
  /* day 0: 30 C high = 86 F, 20 C low = 68 F, chance 0 % */
  g_assert_cmpstr(label_in(r0, "high"), ==, "86\xc2\xb0");
  g_assert_cmpstr(label_in(r0, "low"), ==, "68\xc2\xb0");
  g_assert_cmpstr(label_in(r0, "rain"), ==, "0%");
  g_assert_cmpstr(label_in(r1, "rain"), ==, "10%");
  g_assert_cmpstr(label_in(r1, "high"), ==, "88\xc2\xb0");
  g_assert_cmpstr(gtk_image_get_icon_name(GTK_IMAGE(image_in(r1))), ==, "weather-showers-symbolic");
  g_assert_cmpstr(gtk_widget_get_tooltip_text(r1), ==, "Rain 0.08 in, 10% chance\nCloud cover 50%");

  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(r0, "high"), ==, "30\xc2\xb0");
  g_assert_cmpstr(gtk_widget_get_tooltip_text(r1), ==, "Rain 2.0 mm, 10% chance\nCloud cover 50%");

  /* a past day is skipped once the next one has started */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 12, 4, 0));
  g_assert_cmpstr(label_in(r0, "day"), ==, "Today");
  g_assert_cmpstr(label_in(r0, "high"), ==, "31\xc2\xb0"); /* day 1 */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 12, 3, 59));
  g_assert_cmpstr(label_in(r0, "high"), ==, "30\xc2\xb0"); /* day 0 is still the current day */

  /* the last day ends at its own local midnight */
  g_autoptr(WxForecast) three = make_forecast(T_HOUR0, 10, 0, 3);
  gint64 last_start = ts(2026, 10, 11, 4, 0) + 2 * 86400;
  wx_day_list_set_forecast(WX_DAY_LIST(list), three, WX_UNITS_METRIC, last_start + 24 * 3600 - 1);
  g_assert_cmpuint(visible_count(rows), ==, 1);
  wx_day_list_set_forecast(WX_DAY_LIST(list), three, WX_UNITS_METRIC, last_start + 24 * 3600);
  g_assert_cmpuint(visible_count(rows), ==, 0);
  wx_day_list_set_forecast(WX_DAY_LIST(list), three, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(rows), ==, 3);

  wx_day_list_set_forecast(WX_DAY_LIST(list), NULL, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(rows), ==, 0);
  gint64 nows[] = { 0, G_MAXINT64, G_MININT64, WX_TIME_MAX_S };
  for (guint i = 0; i < G_N_ELEMENTS(nows); i++) {
    wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, nows[i]);
    g_assert_cmpuint(visible_count(rows), ==, 0);
  }
  g_object_unref(list);
}

/* A day missing between two listed days must not keep an ended day on screen. */
static void
test_days_gap_day(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  gint64 sun = ts(2026, 10, 11, 4, 0); /* local midnights in New York (EDT) */
  WxDay d[3];
  for (guint i = 0; i < 3; i++)
    d[i] = (WxDay){ .start_s = sun, .temp_max_c = 20, .temp_min_c = 10, .precip_mm = 0, .precip_prob_max = 0,
                    .cloud_pct = 0, .condition = WX_COND_CLEAR };
  d[1].start_s = sun + 2 * 86400; /* Tuesday: Monday is missing */
  d[2].start_s = sun + 3 * 86400; /* Wednesday */
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, d, 3, NULL, 0, NULL);
  g_assert_nonnull(fc);
  gint64 mon_noon = ts(2026, 10, 12, 16, 0);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, mon_noon);
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Tomorrow");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Wednesday");
  /* only the labels change at local midnight: Tuesday is row 0 both times */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, sun + 2 * 86400);
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, mon_noon);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Tomorrow");
  /* Sunday itself, up to its last second, is Today */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, sun + 86400 - 1);
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tuesday");
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, sun + 86400);
  g_assert_cmpuint(visible_count(rows), ==, 2);
  /* all days over */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, sun + 4 * 86400);
  g_assert_cmpuint(visible_count(rows), ==, 0);
  g_object_unref(list);
}

/* The local day, not 24 hours, decides: a 25-hour DST day is listed until its true end. */
static void
test_days_dst_day(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  WxDay d = { .start_s = ts(2026, 11, 1, 4, 0), .temp_max_c = 20, .temp_min_c = 10, .precip_mm = 0,
              .precip_prob_max = 0, .cloud_pct = 0, .condition = WX_COND_CLEAR }; /* Nov 1: 25 h long */
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, &d, 1, NULL, 0, NULL);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 11, 2, 4, 59));
  g_assert_cmpuint(visible_count(rows), ==, 1); /* 24 h after the start, still the same local day */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 11, 2, 5, 0));
  g_assert_cmpuint(visible_count(rows), ==, 0);
  /* a day whose start is not a valid time is never skipped by the end test (it shows dashes) */
  WxForecast raw = { .days = &(WxDay){ .start_s = 5, .temp_max_c = NAN, .temp_min_c = NAN, .precip_mm = NAN,
                                       .precip_prob_max = NAN, .cloud_pct = NAN, .condition = WX_COND_UNKNOWN },
                     .n_days = 1 };
  raw.place.timezone = (char *)"";
  wx_day_list_set_forecast(WX_DAY_LIST(list), &raw, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(visible_count(rows), ==, 1);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "\xe2\x80\x94");
  g_object_unref(list);
}

/* Changing only the zone re-labels: "Today" depends on the local date. */
static void
test_days_zone_change(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  /* 2026-10-11 03:00Z is Oct 10 at 11 PM in New York but Oct 11 in UTC */
  WxDay d[2];
  for (guint i = 0; i < 2; i++)
    d[i] = (WxDay){ .start_s = ts(2026, 10, 11, 0, 0) + (gint64)i * 86400, .temp_max_c = 20, .temp_min_c = 10,
                    .precip_mm = 0, .precip_prob_max = 0, .cloud_pct = 0, .condition = WX_COND_CLEAR };
  g_autoptr(WxPlace) ny = make_place_in(NY);
  g_autoptr(WxPlace) utc = make_place_in("UTC");
  g_autoptr(WxForecast) f_utc = wx_forecast_new(utc, NOW, NULL, 0, NULL, 0, d, 2, NULL, 0, NULL);
  d[0].start_s = ts(2026, 10, 11, 4, 0);
  d[1].start_s = ts(2026, 10, 12, 4, 0);
  g_autoptr(WxForecast) f_ny = wx_forecast_new(ny, NOW, NULL, 0, NULL, 0, d, 2, NULL, 0, NULL);
  gint64 now = ts(2026, 10, 12, 3, 0); /* Oct 11, 11 PM in New York; Oct 12 in UTC */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_ny, WX_UNITS_METRIC, now);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_utc, WX_UNITS_METRIC, now);
  g_assert_cmpuint(visible_count(rows), ==, 1); /* Oct 11 is over in UTC */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today"); /* Oct 12 */

  /* the very same day values in another zone, at the same instant: only the labels differ */
  WxDay one = { .start_s = ts(2026, 10, 11, 4, 0), .temp_max_c = 20, .temp_min_c = 10, .precip_mm = 0,
                .precip_prob_max = 0, .cloud_pct = 0, .condition = WX_COND_CLEAR };
  g_autoptr(WxForecast) one_ny = wx_forecast_new(ny, NOW, NULL, 0, NULL, 0, &one, 1, NULL, 0, NULL);
  g_autoptr(WxForecast) one_utc = wx_forecast_new(utc, NOW, NULL, 0, NULL, 0, &one, 1, NULL, 0, NULL);
  gint64 at = ts(2026, 10, 11, 3, 0); /* Oct 10, 11 PM in New York; Oct 11 in UTC */
  wx_day_list_set_forecast(WX_DAY_LIST(list), one_ny, WX_UNITS_METRIC, at);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Tomorrow");
  wx_day_list_set_forecast(WX_DAY_LIST(list), one_utc, WX_UNITS_METRIC, at);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  wx_day_list_set_forecast(WX_DAY_LIST(list), one_ny, WX_UNITS_METRIC, at);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Tomorrow");
  g_object_unref(list);
}

/* Atlantic/Azores sets its clock back across midnight on 2026-10-25 (00:00 happens at 00:00Z and again at
 * 01:00Z): Saturday ends at the FIRST midnight, as the blend starts Sunday there. */
static void
test_days_repeated_midnight(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  WxDay d[3];
  gint64 starts[3] = { ts(2026, 10, 24, 0, 0), ts(2026, 10, 25, 0, 0), ts(2026, 10, 26, 1, 0) };
  for (guint i = 0; i < 3; i++)
    d[i] = (WxDay){ .start_s = starts[i], .temp_max_c = 20, .temp_min_c = 10, .precip_mm = 0,
                    .precip_prob_max = 0, .cloud_pct = 0, .condition = WX_COND_CLEAR };
  g_autoptr(WxPlace) place = make_place_in("Atlantic/Azores");
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, d, 3, NULL, 0, NULL);
  g_assert_nonnull(fc);

  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 24, 23, 59));
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today"); /* Saturday */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 25, 0, 15));
  g_assert_cmpuint(visible_count(rows), ==, 2); /* the ended Saturday row is gone */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");    /* Sunday */
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow"); /* Monday */
  g_assert_cmpstr(label_in(rows->pdata[0], "high"), ==, "20\xc2\xb0");
  /* the repeated hour (local 00:30 again): Sunday still */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 25, 1, 30));
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  /* and at exactly 00:00Z */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 10, 25, 0, 0));
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_object_unref(list);
}

/* America/Havana sets its clock back across midnight too (2026-11-01: 00:00 happens at 04:00Z and again at
 * 05:00Z): the day that starts 2026-10-31T04:00Z ends at the first of them. */
static void
test_days_repeated_midnight_havana(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  gint64 starts[3] = { ts(2026, 10, 31, 4, 0), ts(2026, 11, 1, 4, 0), ts(2026, 11, 2, 5, 0) };
  WxDay d[3];
  for (guint i = 0; i < 3; i++)
    d[i] = (WxDay){ .start_s = starts[i], .temp_max_c = 25, .temp_min_c = 18, .precip_mm = 0,
                    .precip_prob_max = 0, .cloud_pct = 0, .condition = WX_COND_CLEAR };
  g_autoptr(WxPlace) place = make_place_in("America/Havana");
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, d, 3, NULL, 0, NULL);
  g_assert_nonnull(fc);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 11, 1, 3, 59));
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today"); /* Saturday */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 11, 1, 4, 30));
  g_assert_cmpuint(visible_count(rows), ==, 2); /* Saturday is over: its first midnight has passed */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");    /* Sunday */
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow"); /* Monday */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, ts(2026, 11, 1, 5, 30)); /* the repeated hour */
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_object_unref(list);
}

static void
test_days_missing_values(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  WxDay d = { .start_s = ts(2026, 10, 11, 4, 0), .temp_max_c = NAN, .temp_min_c = NAN,
              .precip_mm = NAN, .precip_prob_max = NAN, .cloud_pct = NAN, .condition = WX_COND_UNKNOWN };
  g_autoptr(WxPlace) place = make_place();
  g_autoptr(WxForecast) fc = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, &d, 1, NULL, 0, NULL);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, NOW);
  GtkWidget *r0 = rows->pdata[0];
  g_assert_cmpstr(label_in(r0, "high"), ==, "\xe2\x80\x94");
  g_assert_cmpstr(label_in(r0, "low"), ==, "\xe2\x80\x94");
  g_assert_cmpstr(label_in(r0, "rain"), ==, "\xe2\x80\x94");
  g_assert_cmpstr(gtk_image_get_icon_name(GTK_IMAGE(image_in(r0))), ==, "dialog-question-symbolic");
  g_assert_cmpstr(gtk_widget_get_tooltip_text(r0), ==, "Rain \xe2\x80\x94, \xe2\x80\x94 chance\nCloud cover \xe2\x80\x94");
  g_object_unref(list);
}

static void
test_days_compare_before_set(void)
{
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 10, 0, 5);
  g_autoptr(WxForecast) same = make_forecast(T_HOUR0, 10, 0, 5);
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, NOW);
  g_autoptr(GPtrArray) highs = find_all(list, "high");
  gtk_label_set_text(GTK_LABEL(highs->pdata[3]), "scribble");
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, NOW);
  wx_day_list_set_forecast(WX_DAY_LIST(list), same, WX_UNITS_METRIC, NOW + 600);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[3])), ==, "scribble");
  /* "now" moves within the same local date: nothing is recomputed, the rows are kept */
  wx_day_list_set_forecast(WX_DAY_LIST(list), same, WX_UNITS_METRIC, NOW + 3 * 900);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[3])), ==, "scribble");
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_IMPERIAL, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[3])), ==, "91\xc2\xb0"); /* 33 C */
  /* "Today" / "Tomorrow" depend on now: the labels follow the local midnight */
  g_autoptr(GPtrArray) days = find_all(list, "day");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(days->pdata[0])), ==, "Today");
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_IMPERIAL, ts(2026, 10, 12, 4, 0));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(days->pdata[0])), ==, "Today"); /* now first row is day 1 */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(days->pdata[1])), ==, "Tomorrow");
  g_object_unref(list);
}

static void
test_days_dispose_and_null(void)
{
  ASSERT_CRITICAL("wx_day_list_set_forecast", wx_day_list_set_forecast(NULL, NULL, WX_UNITS_METRIC, NOW));
  Fixture f = fixture_new(wx_day_list_new());
  WxDayList *list = g_object_ref(WX_DAY_LIST(f.widget));
  ASSERT_CRITICAL("wx_day_list_set_forecast", wx_day_list_set_forecast(list, NULL, (WxUnits)4, NOW));
  g_autoptr(WxForecast) fc = make_forecast(T_HOUR0, 10, 0, 5);
  wx_day_list_set_forecast(list, fc, WX_UNITS_METRIC, NOW);
  pump(50);
  gtk_window_set_child(GTK_WINDOW(f.window), NULL);
  g_object_run_dispose(G_OBJECT(list));
  g_assert_null(gtk_widget_get_first_child(GTK_WIDGET(list)));
  wx_day_list_set_forecast(list, fc, WX_UNITS_IMPERIAL, NOW);
  wx_day_list_set_forecast(list, NULL, WX_UNITS_IMPERIAL, NOW);
  g_object_run_dispose(G_OBJECT(list));
  fixture_free(&f);
  g_object_unref(list);
}

/* ------------------------------------------------------------------ */
/* Zone lookup that fails, then heals; and the state audit            */
/* ------------------------------------------------------------------ */

static gint64 w_now_us;
static gboolean w_fail;
static guint w_calls;

static gint64
w_clock(void)
{
  return w_now_us;
}

/* The loader of the zone hooks: fails while w_fail, else loads the real zone. */
static GTimeZone *
w_loader(const char *name)
{
  w_calls++;
  return w_fail ? NULL : g_time_zone_new_identifier(name);
}

static void
w_hooks(gboolean fail)
{
  w_now_us = 1000 * G_USEC_PER_SEC;
  w_fail = fail;
  w_calls = 0;
  wx_format_test_set_hooks(w_loader, w_clock);
}

#define KATH "Asia/Kathmandu" /* +05:45: 19:00Z is 00:45 the next day */

/* hours from T_HOUR0 (18:00Z), card 1 = 19:00Z */
static WxForecast *
hours_forecast_in(const char *tz, const WxBlendHour *hs, guint n)
{
  g_autoptr(WxPlace) place = make_place_in(tz);
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, NOW, hs, n, NULL, 0, NULL, 0, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

static WxForecast *
three_hours_in(const char *tz)
{
  WxBlendHour hs[3];
  for (guint i = 0; i < 3; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = i == 1 ? 2.0 : 0.0;
    hs[i].precip_prob = 30.0 + (double)i;
  }
  return hours_forecast_in(tz, hs, 3);
}

static WxForecast *
days_forecast_in(const char *tz, const WxDay *d, guint n)
{
  g_autoptr(WxPlace) place = make_place_in(tz);
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, d, n, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

/* Days whose local midnights are those of Kathmandu: with UTC the list shows 2 rows, with Kathmandu 3. */
static WxForecast *
kathmandu_days(const char *tz)
{
  WxDay d[3];
  for (guint i = 0; i < 3; i++)
    d[i] = (WxDay){ .start_s = ts(2026, 10, 11, 18, 15) + (gint64)i * 86400, .temp_max_c = 30, .temp_min_c = 20,
                    .precip_mm = 0, .precip_prob_max = 0, .cloud_pct = 10, .condition = WX_COND_CLEAR };
  g_autoptr(WxPlace) place = make_place_in(tz);
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, NOW, NULL, 0, NULL, 0, d, 3, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

#define DAYS_NOW ts(2026, 10, 12, 12, 0) /* 17:45 on Oct 12 in Kathmandu, 12:00 in UTC */

/* WxHourStrip: a failed lookup is retried on later calls (an unchanged forecast included) and, when it
 * succeeds, every card is re-bound with the real zone; within 30 s a retry costs no lookup. */
static void
test_strip_zone_failure_heals(void)
{
  w_hooks(TRUE);
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_autoptr(GPtrArray) cards = find_all(strip, "hour-card");
  g_autoptr(GPtrArray) hour_labels = find_all(strip, "hour");
  g_autoptr(GPtrArray) temps = find_all(strip, "temp");
  g_autoptr(WxForecast) fc = three_hours_in(KATH);
  g_autoptr(WxForecast) same = three_hours_in(KATH); /* an equal forecast, another object */

  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW); /* #1: the lookup fails */
  g_assert_cmpuint(w_calls, ==, 1);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "7 PM"); /* UTC fallback */
  gtk_label_set_text(GTK_LABEL(temps->pdata[1]), "scribble");

  for (int i = 0; i < 50; i++) { /* #2: within 30 s: no lookup, nothing rebound */
    w_now_us += G_USEC_PER_SEC / 2;
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), i % 2 ? fc : same, WX_UNITS_METRIC, NOW);
  }
  g_assert_cmpuint(w_calls, ==, 1);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), ==, "scribble"); /* no churn */

  w_now_us += 31 * G_USEC_PER_SEC; /* #3: after 30 s, still failing: ONE more lookup, still no churn */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(w_calls, ==, 2);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), ==, "scribble");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "7 PM");

  w_fail = FALSE; /* the descriptor pressure is over */
  w_now_us += 31 * G_USEC_PER_SEC;
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW); /* forecast, units, now unchanged */
  g_assert_cmpuint(w_calls, ==, 3);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "12:45 AM"); /* the real zone */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), !=, "scribble");     /* re-bound */
  g_assert_true(g_str_has_prefix(gtk_widget_get_tooltip_text(cards->pdata[1]), "12:45 AM\n"));
  gtk_label_set_text(GTK_LABEL(temps->pdata[1]), "scribble");
  for (int i = 0; i < 10; i++) /* resolved: never looked up again, nothing rebound */
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(w_calls, ==, 3);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), ==, "scribble");
  g_object_unref(strip);
  wx_format_test_set_hooks(NULL, NULL);
}

/* WxDayList: same story; the day-end test and the labels follow the real zone once it loads. */
static void
test_days_zone_failure_heals(void)
{
  w_hooks(TRUE);
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  g_autoptr(GPtrArray) highs = find_all(list, "high");
  g_autoptr(WxForecast) fc = kathmandu_days(KATH);

  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, DAYS_NOW); /* #1: fails: UTC */
  g_assert_cmpuint(w_calls, ==, 1);
  g_assert_cmpuint(visible_count(rows), ==, 2); /* UTC: Oct 12 and 13 */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  gtk_label_set_text(GTK_LABEL(highs->pdata[0]), "scribble");
  for (int i = 0; i < 50; i++) { /* #2 */
    w_now_us += G_USEC_PER_SEC / 2;
    wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, DAYS_NOW);
  }
  g_assert_cmpuint(w_calls, ==, 1);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[0])), ==, "scribble");
  w_now_us += 31 * G_USEC_PER_SEC; /* #3: one more failing lookup, still nothing rebuilt */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, DAYS_NOW);
  g_assert_cmpuint(w_calls, ==, 2);
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[0])), ==, "scribble");

  w_fail = FALSE;
  w_now_us += 31 * G_USEC_PER_SEC;
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, DAYS_NOW); /* everything unchanged */
  g_assert_cmpuint(w_calls, ==, 3);
  g_assert_cmpuint(visible_count(rows), ==, 3); /* Kathmandu: Oct 12 (Today), 13, 14 */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  g_assert_cmpstr(label_in(rows->pdata[2], "day"), ==, "Wednesday");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[0])), !=, "scribble"); /* rebuilt */
  gtk_label_set_text(GTK_LABEL(highs->pdata[0]), "scribble");
  for (int i = 0; i < 10; i++)
    wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, DAYS_NOW);
  g_assert_cmpuint(w_calls, ==, 3);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[0])), ==, "scribble");
  g_object_unref(list);
  wx_format_test_set_hooks(NULL, NULL);
}

/* Rows whose data and "now" date are the same in both zones, but whose weekday names differ: a zone that
 * heals must rebuild the labels although no data, no units and no date of now changed. */
static void
test_days_zone_heal_changes_only_labels(void)
{
  w_hooks(TRUE);
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  WxDay d[3];
  gint64 starts[3] = { ts(2026, 10, 12, 0, 0), ts(2026, 10, 13, 0, 0), ts(2026, 10, 14, 20, 0) };
  for (guint i = 0; i < 3; i++)
    d[i] = (WxDay){ .start_s = starts[i], .temp_max_c = 30, .temp_min_c = 20, .precip_mm = 0,
                    .precip_prob_max = 0, .cloud_pct = 10, .condition = WX_COND_CLEAR };
  g_autoptr(WxForecast) fc = days_forecast_in(KATH, d, 3);
  gint64 now = ts(2026, 10, 12, 6, 0); /* 12 Oct in UTC and in Kathmandu (11:45) */
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, now); /* the lookup fails: UTC */
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[2], "day"), ==, "Wednesday"); /* Oct 14 in UTC */
  w_fail = FALSE;
  w_now_us += 31 * G_USEC_PER_SEC;
  wx_day_list_set_forecast(WX_DAY_LIST(list), fc, WX_UNITS_METRIC, now); /* same data, units, now */
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[2], "day"), ==, "Thursday"); /* Oct 15 in Kathmandu */
  g_object_unref(list);
  wx_format_test_set_hooks(NULL, NULL);
}

/* WxRainChart: the axis and the description are rebuilt, and a redraw queued, when a failed lookup heals;
 * a failing retry causes neither a rebuild nor a redraw. The healed frame equals one of a chart that never
 * had trouble. */
static void
test_chart_zone_failure_heals(void)
{
  g_autoptr(WxForecast) fc = make_wet_or_dry_forecast(KATH, TRUE);

  /* the reference frame: a chart whose zone loaded at once */
  w_hooks(FALSE);
  Fixture ref = fixture_new(wx_rain_chart_new());
  wx_rain_chart_set_forecast(WX_RAIN_CHART(ref.widget), fc, WX_UNITS_METRIC, NOW);
  GBytes *good = snap(ref.widget);
  fixture_free(&ref);

  w_hooks(TRUE);
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW); /* #1: fails */
  g_assert_cmpuint(w_calls, ==, 1);
  wait_snapshots(0, 1);
  settle();
  GBytes *fallback = snap(f.widget);
  g_assert_false(g_bytes_equal(fallback, good)); /* UTC labels */
  guint base = chart_snapshots;

  for (int i = 0; i < 50; i++) { /* #2 within 30 s: no lookup, no redraw */
    w_now_us += G_USEC_PER_SEC / 2;
    wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  }
  w_now_us += 31 * G_USEC_PER_SEC; /* #3 still failing: one more lookup, still no redraw */
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(w_calls, ==, 2);
  pump(300);
  g_assert_cmpuint(chart_snapshots, ==, base);

  w_fail = FALSE;
  w_now_us += 31 * G_USEC_PER_SEC;
  wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW); /* nothing changed but the zone */
  g_assert_cmpuint(w_calls, ==, 3);
  wait_snapshots(base, 1); /* a redraw was queued */
  settle();
  GBytes *healed = snap(f.widget);
  g_assert_true(g_bytes_equal(healed, good));
  g_assert_false(g_bytes_equal(healed, fallback));
  base = chart_snapshots;
  for (int i = 0; i < 5; i++)
    wx_rain_chart_set_forecast(chart, fc, WX_UNITS_METRIC, NOW);
  pump(300);
  g_assert_cmpuint(w_calls, ==, 3);
  g_assert_cmpuint(chart_snapshots, ==, base);

  g_bytes_unref(good);
  g_bytes_unref(fallback);
  g_bytes_unref(healed);
  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
  wx_format_test_set_hooks(NULL, NULL);
}

/* A zone name GLib never loads: at most one lookup per 30 s per name, UTC labels, no churn, no redraws. */
static void
test_unknown_zone_costs_one_lookup_per_30s(void)
{
  w_hooks(TRUE); /* every load fails, like an unknown name */
  g_autoptr(WxForecast) h = three_hours_in("Nowhere/Land");
  g_autoptr(WxForecast) d = kathmandu_days("Nowhere/Land");
  g_autoptr(WxForecast) c = make_wet_or_dry_forecast("Nowhere/Land", TRUE);
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  Fixture f = fixture_new(wx_rain_chart_new());
  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;
  g_autoptr(GPtrArray) temps = find_all(strip, "temp");
  g_autoptr(GPtrArray) highs = find_all(list, "high");

  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), h, WX_UNITS_METRIC, NOW);
  wx_day_list_set_forecast(WX_DAY_LIST(list), d, WX_UNITS_METRIC, DAYS_NOW);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), c, WX_UNITS_METRIC, NOW);
  g_assert_cmpuint(w_calls, ==, 1); /* all three widgets, one name: one lookup */
  wait_snapshots(0, 1);
  settle();
  guint base = chart_snapshots;
  gtk_label_set_text(GTK_LABEL(temps->pdata[1]), "scribble");
  gtk_label_set_text(GTK_LABEL(highs->pdata[0]), "scribble");
  for (int i = 0; i < 200; i++) { /* 29.5 s of calls */
    w_now_us += G_USEC_PER_SEC * 29 / 200 + 1;
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), h, WX_UNITS_METRIC, NOW);
    wx_day_list_set_forecast(WX_DAY_LIST(list), d, WX_UNITS_METRIC, DAYS_NOW);
    wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), c, WX_UNITS_METRIC, NOW);
  }
  g_assert_cmpuint(w_calls, ==, 1);
  w_now_us += 2 * G_USEC_PER_SEC; /* past the 30 s: the next call looks once more, for all three */
  for (int i = 0; i < 20; i++) {
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), h, WX_UNITS_METRIC, NOW);
    wx_day_list_set_forecast(WX_DAY_LIST(list), d, WX_UNITS_METRIC, DAYS_NOW);
    wx_rain_chart_set_forecast(WX_RAIN_CHART(f.widget), c, WX_UNITS_METRIC, NOW);
  }
  g_assert_cmpuint(w_calls, ==, 2);
  pump(300);
  g_assert_cmpuint(chart_snapshots, ==, base); /* no redraw churn */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(temps->pdata[1])), ==, "scribble"); /* no rebinding */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(highs->pdata[0])), ==, "scribble");
  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
  g_object_unref(strip);
  g_object_unref(list);
  wx_format_test_set_hooks(NULL, NULL);
}

/* The failed fallback is held while the zone name changes: the new name is resolved at once (a different
 * zone), and coming back to the failing name starts from a fallback again. */
static void
test_zone_name_change_while_fallback_held(void)
{
  w_hooks(TRUE);
  g_autoptr(WxForecast) bad = three_hours_in(KATH);
  g_autoptr(WxForecast) good = three_hours_in(NY);
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_autoptr(GPtrArray) hour_labels = find_all(strip, "hour");
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), bad, WX_UNITS_METRIC, NOW); /* fails: UTC */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "7 PM");
  w_fail = FALSE; /* the next lookup of ANOTHER name works; Kathmandu stays in the failure memory */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), good, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "3 PM"); /* New York */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), bad, WX_UNITS_METRIC, NOW);        /* back: within 30 s */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "7 PM");  /* fallback again */
  w_now_us += 31 * G_USEC_PER_SEC;
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), bad, WX_UNITS_METRIC, NOW);        /* heals */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "12:45 AM");
  /* a NULL forecast (name ""): resolved, no lookup; the same forecast again keeps the real zone */
  guint calls = w_calls;
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), NULL, WX_UNITS_METRIC, NOW);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), bad, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(hour_labels->pdata[1])), ==, "12:45 AM");
  g_assert_cmpuint(w_calls, ==, calls); /* Kathmandu came from the cache */
  g_object_unref(strip);
  wx_format_test_set_hooks(NULL, NULL);
}

/* ------------------------------------------------------------------ */
/* State audit: every cached field, the inputs that change it            */
/* ------------------------------------------------------------------ */

/* WxHourStrip caches, per card, the raw key {t_s, is_now, is_day, condition, temp, feels, prob, cloud,
 * wind, precip} and, for all cards: n_shown, units, the held zone. Every input is changed once; the card
 * must show it, and show the original again when the input goes back. */
typedef struct {
  const char *field;
  void (*mutate)(WxBlendHour *h);
} StripMutation;

static void m_temp(WxBlendHour *h) { h->temp_c += 5; }
static void m_feels(WxBlendHour *h) { h->feels_c += 5; }
static void m_prob(WxBlendHour *h) { h->precip_prob += 7; }
static void m_cloud(WxBlendHour *h) { h->cloud_pct += 9; }
static void m_wind(WxBlendHour *h) { h->wind_kmh += 20; }
static void m_precip(WxBlendHour *h) { h->precip_mm += 3; }
static void m_cond(WxBlendHour *h) { h->condition = WX_COND_THUNDERSTORM; }
static void m_day(WxBlendHour *h) { h->is_day = !h->is_day; }
static void m_nan(WxBlendHour *h) { h->temp_c = NAN; h->precip_prob = NAN; h->cloud_pct = NAN; }

typedef struct {
  char text[7][64];
  char tip[160];
  char icon[64];
} CardSeen;

static CardSeen
seen_card(GtkWidget *card)
{
  CardSeen c = { { "" }, "", "" };
  const char *classes[] = { "hour", "temp", "rain", "cloud" };
  for (guint i = 0; i < G_N_ELEMENTS(classes); i++)
    g_strlcpy(c.text[i], label_in(card, classes[i]), sizeof c.text[i]);
  g_strlcpy(c.tip, gtk_widget_get_tooltip_text(card), sizeof c.tip);
  g_strlcpy(c.icon, gtk_image_get_icon_name(GTK_IMAGE(image_in(card))), sizeof c.icon);
  return c;
}

static gboolean
same_card(const CardSeen *a, const CardSeen *b)
{
  for (guint i = 0; i < 4; i++)
    if (strcmp(a->text[i], b->text[i]) != 0)
      return FALSE;
  return strcmp(a->tip, b->tip) == 0 && strcmp(a->icon, b->icon) == 0;
}

static gboolean
card_is(GtkWidget *card, const CardSeen *want)
{
  CardSeen c = seen_card(card);
  return same_card(&c, want);
}

static void
test_strip_state_audit(void)
{
  static const StripMutation muts[] = { { "temp", m_temp }, { "feels", m_feels }, { "prob", m_prob },
                                        { "cloud", m_cloud }, { "wind", m_wind }, { "precip", m_precip },
                                        { "condition", m_cond }, { "is_day", m_day }, { "nan", m_nan } };
  GtkWidget *strip = g_object_ref_sink(wx_hour_strip_new());
  g_autoptr(GPtrArray) cards = find_all(strip, "hour-card");
  WxBlendHour base[3];
  for (guint i = 0; i < 3; i++) {
    base[i] = hour(T_HOUR0 + (gint64)i * 3600);
    base[i].condition = WX_COND_CLEAR;
    base[i].precip_mm = 1.0;
    base[i].precip_prob = 20;
  }
  g_autoptr(WxForecast) f0 = hours_forecast_in(NY, base, 3);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  CardSeen orig[3] = { seen_card(cards->pdata[0]), seen_card(cards->pdata[1]), seen_card(cards->pdata[2]) };
  for (guint m = 0; m < G_N_ELEMENTS(muts); m++) {
    WxBlendHour mut[3];
    memcpy(mut, base, sizeof base);
    /* hour 2: the Now card (card 0, 14:30) interpolates between hours 0 and 1 only */
    muts[m].mutate(&mut[2]);
    g_autoptr(WxForecast) f1 = hours_forecast_in(NY, mut, 3);
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f1, WX_UNITS_METRIC, NOW);
    if (card_is(cards->pdata[2], &orig[2]))
      g_error("hour field '%s' did not reach the card", muts[m].field);
    g_assert_true(card_is(cards->pdata[0], &orig[0])); /* the neighbours are untouched */
    g_assert_true(card_is(cards->pdata[1], &orig[1]));
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW); /* and back */
    g_assert_true(card_is(cards->pdata[2], &orig[2]));
  }
  /* The Now card follows the NEXT hour too (it shows the values at now, interpolated): hour 1 at
   * 10 C more is 5 C more at 14:30, and the card comes back with the data. */
  {
    WxBlendHour mut[3];
    memcpy(mut, base, sizeof base);
    mut[1].temp_c += 10;
    mut[1].feels_c += 10;
    mut[1].wind_kmh += 20;
    mut[1].cloud_pct += 20; /* 40 -> 60 %: 50 % at 14:30, the base condition CLEAR becomes partly cloudy */
    g_autoptr(WxForecast) f1 = hours_forecast_in(NY, mut, 3);
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f1, WX_UNITS_METRIC, NOW);
    g_assert_cmpstr(label_in(cards->pdata[0], "temp"), ==, "30" "\xc2\xb0"); /* 25 C, half way to 35 C */
    g_assert_cmpstr(label_in(cards->pdata[0], "cloud"), ==, "Cloud 50%");
    g_assert_cmpstr(gtk_image_get_icon_name(GTK_IMAGE(image_in(cards->pdata[0]))), ==,
                    "weather-few-clouds-symbolic");
    g_assert_cmpstr(gtk_widget_get_tooltip_text(cards->pdata[0]), ==,
                    "2:30 PM\nFeels like 32\xc2\xb0" "C\nWind 29 km/h\nRain 1.0 mm");
    g_assert_cmpstr(label_in(cards->pdata[1], "cloud"), ==, "Cloud 60%"); /* the others are raw */
    g_assert_cmpstr(label_in(cards->pdata[2], "cloud"), ==, "Cloud 40%");
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
    g_assert_true(card_is(cards->pdata[0], &orig[0]));
  }
  /* t_s: the same values one hour later */
  WxBlendHour later[3];
  for (guint i = 0; i < 3; i++) {
    later[i] = base[i];
    later[i].t_s += 3600;
  }
  g_autoptr(WxForecast) f_later = hours_forecast_in(NY, later, 3);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f_later, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(cards->pdata[1], "hour"), ==, "4 PM"); /* was 3 PM */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(cards->pdata[1], "hour"), ==, "3 PM");
  /* now: the "Now" marker, and the first hour that has not ended */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, T_HOUR0 - 600);
  g_assert_cmpstr(label_in(cards->pdata[0], "hour"), ==, "2 PM"); /* the first hour has not started */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(cards->pdata[0], "hour"), ==, "Now");
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, T_HOUR0 + 3600 + 5);
  g_assert_cmpstr(label_in(cards->pdata[0], "hour"), ==, "Now");
  g_assert_cmpstr(label_in(cards->pdata[0], "temp"), ==, orig[1].text[1]); /* card 0 now holds hour 1 */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  /* units, and the zone name: each rebinds all cards */
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_IMPERIAL, NOW);
  g_assert_false(card_is(cards->pdata[1], &orig[1]));
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  g_assert_true(card_is(cards->pdata[1], &orig[1]));
  g_autoptr(WxForecast) f_utc = hours_forecast_in("UTC", base, 3);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f_utc, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(cards->pdata[1], "hour"), ==, "7 PM");
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  g_assert_cmpstr(label_in(cards->pdata[1], "hour"), ==, "3 PM");
  /* n_shown: fewer hours hide the cards, a NULL forecast hides all, and the same data shows again */
  g_autoptr(WxForecast) f_one = hours_forecast_in(NY, base, 1);
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f_one, WX_UNITS_METRIC, NOW);
  g_assert_false(gtk_widget_get_visible(cards->pdata[1]));
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), NULL, WX_UNITS_METRIC, NOW);
  g_assert_false(gtk_widget_get_visible(cards->pdata[0]));
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f0, WX_UNITS_METRIC, NOW);
  g_assert_true(gtk_widget_get_visible(cards->pdata[2]));
  g_assert_true(card_is(cards->pdata[1], &orig[1]));
  /* dispose: nothing changes any more */
  g_object_run_dispose(G_OBJECT(strip));
  wx_hour_strip_set_forecast(WX_HOUR_STRIP(strip), f_later, WX_UNITS_IMPERIAL, NOW);
  g_object_unref(strip);
}

/* WxDayList caches, per row, the raw key {start_s, condition, high, low, precip, prob, cloud} and the label,
 * and for all rows: n_shown, units, the held zone and the local date of now. */
typedef struct {
  const char *field;
  void (*mutate)(WxDay *d);
} DayMutation;

static void dm_high(WxDay *d) { d->temp_max_c += 4; }
static void dm_low(WxDay *d) { d->temp_min_c -= 4; }
static void dm_precip(WxDay *d) { d->precip_mm += 6; }
static void dm_prob(WxDay *d) { d->precip_prob_max += 15; }
static void dm_cloud(WxDay *d) { d->cloud_pct += 20; }
static void dm_cond(WxDay *d) { d->condition = WX_COND_SNOW; }
static void dm_nan(WxDay *d) { d->temp_max_c = NAN; d->temp_min_c = NAN; d->precip_prob_max = NAN; }

typedef struct {
  char day[32], rain[32], low[32], high[32], tip[160], icon[64];
} RowSeen;

static RowSeen
seen_row(GtkWidget *row)
{
  RowSeen r;
  g_strlcpy(r.day, label_in(row, "day"), sizeof r.day);
  g_strlcpy(r.rain, label_in(row, "rain"), sizeof r.rain);
  g_strlcpy(r.low, label_in(row, "low"), sizeof r.low);
  g_strlcpy(r.high, label_in(row, "high"), sizeof r.high);
  g_strlcpy(r.tip, gtk_widget_get_tooltip_text(row), sizeof r.tip);
  g_strlcpy(r.icon, gtk_image_get_icon_name(GTK_IMAGE(image_in(row))), sizeof r.icon);
  return r;
}

static gboolean
same_row(const RowSeen *a, const RowSeen *b)
{
  return strcmp(a->day, b->day) == 0 && strcmp(a->rain, b->rain) == 0 && strcmp(a->low, b->low) == 0 &&
         strcmp(a->high, b->high) == 0 && strcmp(a->tip, b->tip) == 0 && strcmp(a->icon, b->icon) == 0;
}

static gboolean
row_is(GtkWidget *row, const RowSeen *want)
{
  RowSeen r = seen_row(row);
  return same_row(&r, want);
}

static void
test_days_state_audit(void)
{
  static const DayMutation muts[] = { { "temp_max", dm_high }, { "temp_min", dm_low }, { "precip", dm_precip },
                                      { "prob", dm_prob }, { "cloud", dm_cloud }, { "condition", dm_cond },
                                      { "nan", dm_nan } };
  GtkWidget *list = g_object_ref_sink(wx_day_list_new());
  g_autoptr(GPtrArray) rows = find_all(list, "day-row");
  WxDay base[3];
  for (guint i = 0; i < 3; i++)
    base[i] = (WxDay){ .start_s = ts(2026, 10, 11, 4, 0) + (gint64)i * 86400, .temp_max_c = 30, .temp_min_c = 20,
                       .precip_mm = 1, .precip_prob_max = 20, .cloud_pct = 30, .condition = WX_COND_CLEAR };
  gint64 now = ts(2026, 10, 11, 12, 0); /* Sunday in New York */
  g_autoptr(WxForecast) f0 = days_forecast_in(NY, base, 3);
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  RowSeen orig[3] = { seen_row(rows->pdata[0]), seen_row(rows->pdata[1]), seen_row(rows->pdata[2]) };
  for (guint m = 0; m < G_N_ELEMENTS(muts); m++) {
    WxDay mut[3];
    memcpy(mut, base, sizeof base);
    muts[m].mutate(&mut[1]);
    g_autoptr(WxForecast) f1 = days_forecast_in(NY, mut, 3);
    wx_day_list_set_forecast(WX_DAY_LIST(list), f1, WX_UNITS_METRIC, now);
    if (row_is(rows->pdata[1], &orig[1]))
      g_error("day field '%s' did not reach the row", muts[m].field);
    g_assert_true(row_is(rows->pdata[0], &orig[0]));
    g_assert_true(row_is(rows->pdata[2], &orig[2]));
    wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now); /* and back */
    g_assert_true(row_is(rows->pdata[1], &orig[1]));
  }
  /* start_s: the same values three days later change the weekday label */
  WxDay later[3];
  memcpy(later, base, sizeof base);
  for (guint i = 0; i < 3; i++)
    later[i].start_s += 3 * 86400;
  g_autoptr(WxForecast) f_later = days_forecast_in(NY, later, 3);
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_later, WX_UNITS_METRIC, now);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Wednesday"); /* was "Today" */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  /* now: the labels follow the LOCAL DATE (also across midnight in the zone, not in UTC) */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, ts(2026, 10, 12, 3, 59)); /* 23:59 Oct 11 */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, ts(2026, 10, 12, 4, 0)); /* 00:00 Oct 12 */
  g_assert_cmpuint(visible_count(rows), ==, 2);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today"); /* the old Today is over */
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now); /* now goes back */
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  g_assert_cmpstr(label_in(rows->pdata[1], "day"), ==, "Tomorrow");
  g_assert_cmpstr(label_in(rows->pdata[2], "day"), ==, "Tuesday");
  /* a forecast that starts in the future: moving "now" to the next local date changes no label yet
   * (a weekday name stays), so the rows are not rebound; at the day before they turn into "Tomorrow" */
  WxDay fut[3];
  memcpy(fut, base, sizeof base);
  for (guint i = 0; i < 3; i++)
    fut[i].start_s += 3 * 86400; /* Wed, Thu, Fri (4:00Z = local midnight in New York) */
  g_autoptr(WxForecast) f_fut = days_forecast_in(NY, fut, 3);
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_fut, WX_UNITS_METRIC, now);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Wednesday");
  g_autoptr(GPtrArray) day_highs = find_all(list, "high");
  gtk_label_set_text(GTK_LABEL(day_highs->pdata[0]), "scribble");
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_fut, WX_UNITS_METRIC, now + 86400); /* Monday: a new date */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Wednesday");
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(day_highs->pdata[0])), ==, "scribble"); /* nothing rebound */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_fut, WX_UNITS_METRIC, now + 2 * 86400); /* Tuesday */
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Tomorrow"); /* Wednesday is tomorrow now */
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(day_highs->pdata[0])), !=, "scribble");
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  /* units and zone name rebuild everything */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_IMPERIAL, now);
  g_assert_false(row_is(rows->pdata[1], &orig[1]));
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  g_assert_true(row_is(rows->pdata[1], &orig[1]));
  g_autoptr(WxForecast) f_syd = days_forecast_in("Australia/Sydney", base, 3);
  gint64 syd_midnight = ts(2026, 10, 11, 13, 30); /* 00:30 on Oct 12 in Sydney, 09:30 on Oct 11 in New York */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_syd, WX_UNITS_METRIC, syd_midnight);
  g_assert_cmpuint(visible_count(rows), ==, 2); /* in Sydney the first day (Oct 11) is over */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, syd_midnight);
  g_assert_cmpuint(visible_count(rows), ==, 3); /* in New York it is not */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  g_assert_cmpuint(visible_count(rows), ==, 3);
  /* NULL forecast hides the rows; the same data shows again and rebinds */
  wx_day_list_set_forecast(WX_DAY_LIST(list), NULL, WX_UNITS_METRIC, now);
  g_assert_cmpuint(visible_count(rows), ==, 0);
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  g_assert_cmpuint(visible_count(rows), ==, 3);
  g_assert_true(row_is(rows->pdata[0], &orig[0]));
  /* an invalid now hides everything and the valid one brings the labels back */
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, 0);
  g_assert_cmpuint(visible_count(rows), ==, 0);
  wx_day_list_set_forecast(WX_DAY_LIST(list), f0, WX_UNITS_METRIC, now);
  g_assert_cmpstr(label_in(rows->pdata[0], "day"), ==, "Today");
  /* dispose */
  g_object_run_dispose(G_OBJECT(list));
  wx_day_list_set_forecast(WX_DAY_LIST(list), f_later, WX_UNITS_IMPERIAL, now);
  g_object_unref(list);
}

/* WxRainChart caches the window (view, start, n, 24 rates and chances), the units, the held zone, the scale,
 * has_data and the accessible description. */
static void
test_chart_state_audit(void)
{
  Fixture f = fixture_new(wx_rain_chart_new());
  WxRainChart *chart = WX_RAIN_CHART(f.widget);
  GtkWidgetClass *klass = GTK_WIDGET_GET_CLASS(f.widget);
  orig_chart_snapshot = klass->snapshot;
  klass->snapshot = counting_snapshot;
  chart_snapshots = 0;

  WxBlendHour hs[40];
  for (guint i = 0; i < 40; i++) {
    hs[i] = hour(T_HOUR0 + (gint64)i * 3600);
    hs[i].precip_mm = i % 3 == 0 ? 1.5 : 0.0;
    hs[i].precip_prob = 20;
  }
  g_autoptr(WxForecast) f0 = hours_forecast_in(NY, hs, 40);
  wx_rain_chart_set_forecast(chart, f0, WX_UNITS_METRIC, NOW);
  wait_snapshots(0, 1);
  settle();
  GBytes *orig = snap(f.widget);
  guint base = chart_snapshots;

  /* a rate and a chance INSIDE the window rebuild; each returns to the original */
  for (int what = 0; what < 2; what++) {
    WxBlendHour mut[40];
    memcpy(mut, hs, sizeof hs);
    if (what == 0)
      mut[5].precip_mm += 1.0;
    else
      mut[5].precip_prob += 30.0;
    g_autoptr(WxForecast) f1 = hours_forecast_in(NY, mut, 40);
    wx_rain_chart_set_forecast(chart, f1, WX_UNITS_METRIC, NOW);
    wait_snapshots(base, 1);
    settle();
    GBytes *changed = snap(f.widget);
    g_assert_false(g_bytes_equal(changed, orig));
    g_bytes_unref(changed);
    base = chart_snapshots;
    wx_rain_chart_set_forecast(chart, f0, WX_UNITS_METRIC, NOW);
    wait_snapshots(base, 1);
    settle();
    GBytes *back = snap(f.widget);
    g_assert_true(g_bytes_equal(back, orig));
    g_bytes_unref(back);
    base = chart_snapshots;
  }
  /* a value OUTSIDE the window (hour 30) is not part of the key: no rebuild, no redraw */
  WxBlendHour far[40];
  memcpy(far, hs, sizeof hs);
  far[30].precip_mm += 4.0;
  g_autoptr(WxForecast) f_far = hours_forecast_in(NY, far, 40);
  wx_rain_chart_set_forecast(chart, f_far, WX_UNITS_METRIC, NOW);
  pump(300);
  g_assert_cmpuint(chart_snapshots, ==, base);
  /* the place's zone name (the axis labels) */
  g_autoptr(WxForecast) f_utc = hours_forecast_in("UTC", hs, 40);
  wx_rain_chart_set_forecast(chart, f_utc, WX_UNITS_METRIC, NOW);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  GBytes *utc_view = snap(f.widget);
  g_assert_false(g_bytes_equal(utc_view, orig));
  wx_rain_chart_set_forecast(chart, f0, WX_UNITS_METRIC, NOW);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  GBytes *ny_again = snap(f.widget);
  g_assert_true(g_bytes_equal(ny_again, orig));
  /* a NULL forecast shows "No data" and then the same forecast the data again */
  wx_rain_chart_set_forecast(chart, NULL, WX_UNITS_METRIC, NOW);
  wait_snapshots(base, 1);
  settle();
  base = chart_snapshots;
  g_assert_cmpuint(counts(f.widget).color, ==, 0);
  wx_rain_chart_set_forecast(chart, f0, WX_UNITS_METRIC, NOW);
  wait_snapshots(base, 1);
  settle();
  GBytes *shown_again = snap(f.widget);
  g_assert_true(g_bytes_equal(shown_again, orig));
  g_bytes_unref(utc_view);
  g_bytes_unref(ny_again);
  g_bytes_unref(shown_again);
  g_bytes_unref(orig);
  klass->snapshot = orig_chart_snapshot;
  fixture_free(&f);
}

/* ------------------------------------------------------------------ */
/* icons resolve in the installed theme                               */
/* ------------------------------------------------------------------ */

static void
test_icons_exist_in_theme(void)
{
  GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
  if (!gtk_icon_theme_has_icon(theme, "weather-clear-symbolic")) {
    g_test_skip("the icon theme has no weather icons");
    return;
  }
  for (int c = 0; c <= (int)WX_COND_COUNT; c++) {
    for (int day = 0; day < 2; day++) {
      const char *name = wx_icon_name((WxCondition)c, day);
      if (!gtk_icon_theme_has_icon(theme, name))
        g_error("icon '%s' (condition %d, day %d) is missing from the theme", name, c, day);
    }
  }
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* The temp tree of the bare theme, and its removal                   */
/* ------------------------------------------------------------------ */

/* GTK, GIO and dconf may create files and directories of their own below the mocked XDG dirs, so the
 * tree is removed recursively. The same code runs from the signal handlers of a failed test (a failed
 * assertion aborts), so it only uses async-signal-safe calls: openat, getdents64, fstatat, unlinkat,
 * close, rmdir. It works relative to directory descriptors, never follows a symlink (a link is
 * unlinked itself) and never goes up ("." and ".." are skipped), so it cannot leave the root. */
#define RM_MAX_DEPTH 32
#define RM_PASSES 4

struct dirent64_raw { /* the kernel's linux_dirent64 */
  guint64 d_ino;
  gint64 d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[];
};

/* The buffer the kernel fills with records of that layout. Records start at 8-byte aligned offsets
 * (the kernel pads d_reclen), so the buffer itself is aligned for the struct. */
typedef union {
  struct dirent64_raw align_as;
  char bytes[2048];
} DirentBuf;

static void
remove_children(int dfd, int depth)
{
  DirentBuf buf;
  /* unlinking while reading may skip entries: read again until a pass removes nothing */
  for (int pass = 0; pass < RM_PASSES; pass++) {
    gboolean removed = FALSE;
    lseek(dfd, 0, SEEK_SET);
    long n;
    while ((n = syscall(SYS_getdents64, dfd, buf.bytes, sizeof buf.bytes)) > 0) {
      for (long off = 0; off < n;) {
        /* the header is read with memcpy, the name stays in the buffer */
        unsigned short reclen;
        memcpy(&reclen, buf.bytes + off + offsetof(struct dirent64_raw, d_reclen), sizeof reclen);
        const char *name = buf.bytes + off + offsetof(struct dirent64_raw, d_name);
        off += reclen;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))
          continue;
        struct stat st;
        if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0)
          continue;
        if (S_ISDIR(st.st_mode)) {
          int child = depth < RM_MAX_DEPTH ? openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
          if (child >= 0) {
            remove_children(child, depth + 1);
            close(child);
          }
          removed |= unlinkat(dfd, name, AT_REMOVEDIR) == 0;
        } else {
          removed |= unlinkat(dfd, name, 0) == 0;
        }
      }
    }
    if (!removed)
      break;
  }
}

/* Removes @root and everything below it; a symlink inside is removed, not followed. */
static void
remove_tree_path(const char *root)
{
  int fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return;
  remove_children(fd, 0);
  close(fd);
  rmdir(root);
}

static char tmp_root[4096]; /* the temp root, "" when none; written once before any signal can matter */
static const char *self_path;

static void
remove_tmp_tree(void)
{
  if (tmp_root[0] != '\0')
    remove_tree_path(tmp_root);
}

static void
on_fatal_signal(int sig)
{
  remove_tmp_tree();
  signal(sig, SIG_DFL);
  raise(sig);
}

/* A theme that defines no colours of its own, so the tests are independent of the installed
 * one. Must run before GTK reads its environment. With WX_TEST_SELFTEST set (only by the test of the
 * cleanup below) it also leaves files like GTK's own below the temp dirs. */
static void
install_bare_theme(void)
{
  g_autofree char *root = g_dir_make_tmp("wx-widgets-test-XXXXXX", NULL);
  if (root == NULL || strlen(root) >= sizeof tmp_root)
    return;
  g_strlcpy(tmp_root, root, sizeof tmp_root);
  signal(SIGABRT, on_fatal_signal);
  signal(SIGSEGV, on_fatal_signal);
  signal(SIGTERM, on_fatal_signal);
  signal(SIGINT, on_fatal_signal);
  g_autofree char *theme_dir = g_build_filename(root, "themes", "Bare", "gtk-4.0", NULL);
  g_autofree char *css = g_build_filename(theme_dir, "gtk.css", NULL);
  g_autofree char *cfg = g_build_filename(root, "config", NULL);
  g_autofree char *cache = g_build_filename(root, "cache", NULL);
  g_autofree char *state = g_build_filename(root, "state", NULL);
  g_autofree char *run = g_build_filename(root, "run", NULL);
  if (g_mkdir_with_parents(theme_dir, 0700) == 0 && g_mkdir_with_parents(cfg, 0700) == 0 &&
      g_mkdir_with_parents(cache, 0700) == 0 && g_mkdir_with_parents(state, 0700) == 0 &&
      g_mkdir_with_parents(run, 0700) == 0 &&
      g_file_set_contents(css, "window { color: #101010; background-color: #ffffff; }\n", -1, NULL)) {
    g_setenv("XDG_DATA_HOME", root, TRUE);
    g_setenv("XDG_CONFIG_HOME", cfg, TRUE);
    /* every cache GTK, Mesa, fontconfig and the GL drivers may write goes below the temp root too */
    g_setenv("XDG_CACHE_HOME", cache, TRUE);
    g_setenv("XDG_STATE_HOME", state, TRUE);
    g_setenv("XDG_RUNTIME_DIR", run, TRUE);
    g_setenv("MESA_SHADER_CACHE_DIR", cache, TRUE);
    g_setenv("__GL_SHADER_DISK_CACHE_PATH", cache, TRUE);
    g_setenv("GSETTINGS_BACKEND", "memory", TRUE);
    g_setenv("GTK_THEME", "Bare", TRUE);
  }
  if (g_getenv("WX_TEST_SELFTEST") != NULL) {
    g_autofree char *deep = g_build_filename(cfg, "dconf", "x", "y", NULL);
    g_autofree char *user = g_build_filename(cfg, "dconf", "user", NULL);
    g_autofree char *deep_file = g_build_filename(deep, "cache", NULL);
    g_autofree char *dangling = g_build_filename(cfg, "link-to-nowhere", NULL);
    g_mkdir_with_parents(deep, 0700);
    g_file_set_contents(user, "x", -1, NULL);
    g_file_set_contents(deep_file, "y", -1, NULL);
    if (symlink("/nonexistent/wx-test", dangling) != 0)
      g_printerr("symlink failed\n");
  }
}

/* A fresh empty directory below the temp root of the run (so that even a failed test, which aborts,
 * leaves nothing behind: the signal handler removes the whole root). */
static char *
scratch_dir(const char *name)
{
  g_assert_cmpstr(tmp_root, !=, "");
  char *dir = g_build_filename(tmp_root, name, NULL);
  remove_tree_path(dir);
  g_assert_cmpint(g_mkdir_with_parents(dir, 0700), ==, 0);
  return dir;
}

/* The mocked XDG tree is gone after a normal exit, the skip exit and an abort, even when GTK-like files
 * were created below it. The test binary runs itself with WX_TEST_SELFTEST set and a private TMPDIR. */
static void
run_selftest(const char *mode, int *exit_status, int *term_signal, char **leftovers)
{
  g_autofree char *private_tmp = scratch_dir("selftest");
  char **env = g_get_environ();
  env = g_environ_unsetenv(env, "DISPLAY");
  env = g_environ_unsetenv(env, "WAYLAND_DISPLAY");
  env = g_environ_setenv(env, "TMPDIR", private_tmp, TRUE);
  env = g_environ_setenv(env, "WX_TEST_SELFTEST", mode, TRUE);
  char *argv[] = { (char *)self_path, NULL };
  int status = 0;
  GError *err = NULL;
  g_assert_true(g_spawn_sync(NULL, argv, env, G_SPAWN_DEFAULT, NULL, NULL, NULL, NULL, &status, &err));
  g_assert_no_error(err);
  g_strfreev(env);
  *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  *term_signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
  GString *left = g_string_new("");
  g_autoptr(GDir) d = g_dir_open(private_tmp, 0, NULL);
  const char *name;
  while (d != NULL && (name = g_dir_read_name(d)) != NULL)
    g_string_append_printf(left, "%s ", name);
  *leftovers = g_string_free(left, FALSE);
  remove_tree_path(private_tmp);
}

static void
test_tmp_cleanup_on_skip_and_abort(void)
{
  int code, sig;
  g_autofree char *left = NULL;
  run_selftest("skip", &code, &sig, &left);
  g_assert_cmpint(code, ==, 77); /* no display: the skip exit */
  g_assert_cmpstr(left, ==, "");
  g_free(left);
  run_selftest("abort", &code, &sig, &left);
  g_assert_cmpint(sig, ==, SIGABRT);
  g_assert_cmpstr(left, ==, "");
}

/* The recursive removal itself: nested dirs, many files, a link that points outside (it is removed, the
 * target is not), a link to a directory, an unreadable-looking dot name, and a path that is not a dir. */
static void
test_remove_tree_recursive(void)
{
  g_autofree char *base = scratch_dir("rmtree");
  g_autofree char *outside = g_build_filename(base, "outside", NULL);
  g_autofree char *sentinel = g_build_filename(outside, "keep.txt", NULL);
  g_autofree char *root = g_build_filename(base, "root", NULL);
  g_assert_cmpint(g_mkdir_with_parents(outside, 0700), ==, 0);
  g_assert_true(g_file_set_contents(sentinel, "keep", -1, NULL));
  g_assert_cmpint(g_mkdir_with_parents(root, 0700), ==, 0);
  for (int i = 0; i < 300; i++) { /* more entries than one getdents buffer holds */
    g_autofree char *name = g_strdup_printf("%s/f%03d.with-a-longer-name-to-fill-the-buffer", root, i);
    g_assert_true(g_file_set_contents(name, "x", -1, NULL));
  }
  g_autofree char *deep = g_build_filename(root, "a", "b", "c", "d", "e", NULL);
  g_assert_cmpint(g_mkdir_with_parents(deep, 0700), ==, 0);
  g_autofree char *deep_file = g_build_filename(deep, "file", NULL);
  g_assert_true(g_file_set_contents(deep_file, "x", -1, NULL));
  g_autofree char *link_dir = g_build_filename(root, "a", "link-to-outside", NULL);
  g_autofree char *link_file = g_build_filename(root, "link-to-file", NULL);
  g_assert_cmpint(symlink(outside, link_dir), ==, 0);
  g_assert_cmpint(symlink(sentinel, link_file), ==, 0);
  g_autofree char *odd = g_build_filename(root, "..hidden", NULL);
  g_assert_true(g_file_set_contents(odd, "x", -1, NULL));

  remove_tree_path(root);
  g_assert_false(g_file_test(root, G_FILE_TEST_EXISTS));
  g_assert_true(g_file_test(sentinel, G_FILE_TEST_IS_REGULAR)); /* the link was removed, not followed */

  /* a path that does not exist, a regular file, and a symlink to a directory are left alone */
  remove_tree_path(root);
  g_assert_true(g_file_set_contents(root, "x", -1, NULL));
  remove_tree_path(root);
  g_assert_true(g_file_test(root, G_FILE_TEST_IS_REGULAR));
  g_assert_cmpint(g_unlink(root), ==, 0);
  g_assert_cmpint(symlink(outside, root), ==, 0);
  remove_tree_path(root);
  g_assert_true(g_file_test(sentinel, G_FILE_TEST_IS_REGULAR));
  g_assert_cmpint(g_unlink(root), ==, 0);

  /* deeper than the depth limit: the stack use is bounded, so the part below the limit stays */
  GString *path = g_string_new(root);
  for (int i = 0; i < RM_MAX_DEPTH + 3; i++)
    g_string_append(path, "/d");
  g_assert_cmpint(g_mkdir_with_parents(path->str, 0700), ==, 0);
  remove_tree_path(root);
  g_assert_true(g_file_test(root, G_FILE_TEST_IS_DIR));
  while (path->len > strlen(root)) { /* remove it from the bottom up, by hand */
    g_assert_cmpint(g_rmdir(path->str), ==, 0);
    g_string_truncate(path, (gsize)(strrchr(path->str, '/') - path->str));
  }
  g_string_free(path, TRUE);
  remove_tree_path(root);
  g_assert_false(g_file_test(root, G_FILE_TEST_EXISTS));

  remove_tree_path(base);
  g_assert_false(g_file_test(base, G_FILE_TEST_EXISTS));
}

/* Any GLib/GTK warning aborts the test, except the theme parser notes about the bare theme. */
static GLogWriterOutput
log_writer(GLogLevelFlags level, const GLogField *fields, gsize n_fields, gpointer user_data)
{
  if (level & G_LOG_LEVEL_WARNING) {
    for (gsize i = 0; i < n_fields; i++) {
      if (strcmp(fields[i].key, "MESSAGE") == 0 && fields[i].value != NULL &&
          g_str_has_prefix(fields[i].value, "Theme parser error: gtk.css")) {
        g_printerr("# ignored (GTK theme): %s\n", (const char *)fields[i].value);
        return G_LOG_WRITER_HANDLED;
      }
    }
    g_log_writer_default(level, fields, n_fields, user_data);
    abort();
  }
  return g_log_writer_default(level, fields, n_fields, user_data);
}

int
main(int argc, char **argv)
{
  self_path = argv[0];
  install_bare_theme();
  if (g_strcmp0(g_getenv("WX_TEST_SELFTEST"), "abort") == 0)
    abort(); /* the cleanup test: a failing test aborts the process */
  g_log_set_writer_func(log_writer, NULL, NULL);
  g_setenv("GTK_A11Y", "none", TRUE);
  g_test_init(&argc, &argv, NULL);
  g_log_set_always_fatal(G_LOG_FATAL_MASK | G_LOG_LEVEL_CRITICAL);
  /* Pin the X11 backend (Xvfb) so the test never touches a live compositor. */
  g_setenv("GDK_BACKEND", "x11", TRUE);
  gdk_set_allowed_backends("x11");
  if (!gtk_init_check()) {
    g_print("1..0 # SKIP no display\n");
    remove_tmp_tree();
    return 77;
  }
  g_assert_true(g_str_has_prefix(G_OBJECT_TYPE_NAME(gdk_display_get_default()), "GdkX11"));

  g_test_add_func("/widgets/chart/measure", test_chart_measure);
  g_test_add_func("/widgets/chart/null-arguments", test_chart_null_arguments);
  g_test_add_func("/widgets/chart/no-data", test_chart_no_data);
  g_test_add_func("/widgets/chart/hourly", test_chart_hourly);
  g_test_add_func("/widgets/chart/quarters", test_chart_quarters);
  g_test_add_func("/widgets/chart/view-follows-data", test_chart_view_follows_data);
  g_test_add_func("/widgets/chart/fixed-views", test_chart_fixed_views);
  g_test_add_func("/widgets/chart/idle-and-redraw", test_chart_idle_and_redraw);
  g_test_add_func("/widgets/chart/view-switch-redraw-and-no-zone-io", test_chart_view_switch_redraw_and_no_zone_io);
  g_test_add_func("/widgets/chart/view-change-equal-first-slots", test_chart_view_change_with_equal_first_slots);
  g_test_add_func("/widgets/no-zone-resolution-at-draw-time", test_no_zone_resolution_at_draw_time);
  g_test_add_func("/widgets/chart/huge-inputs", test_chart_huge_inputs);
  g_test_add_func("/widgets/chart/narrow-skips-overlapping-labels", test_chart_narrow_skips_overlapping_labels);
  g_test_add_func("/widgets/chart/all-dry", test_chart_all_dry);
  g_test_add_func("/widgets/chart/tiny-allocation", test_chart_tiny_allocation);
  g_test_add_func("/widgets/chart/dispose", test_chart_dispose);
  g_test_add_func("/widgets/chart/dispose-in-window", test_chart_dispose_in_window);
  g_test_add_func("/widgets/chart/fallback-colour", test_chart_fallback_colour);
  g_test_add_func("/widgets/strip/basic", test_strip_basic);
  g_test_add_func("/widgets/strip/missing-values", test_strip_missing_values);
  g_test_add_func("/widgets/strip/compare-before-set", test_strip_compare_before_set);
  g_test_add_func("/widgets/strip/dispose", test_strip_dispose);
  g_test_add_func("/widgets/strip/null-arguments", test_strip_null_arguments);
  g_test_add_func("/widgets/strip/in-window", test_strip_in_window);
  g_test_add_func("/widgets/days/basic", test_days_basic);
  g_test_add_func("/widgets/days/gap-day", test_days_gap_day);
  g_test_add_func("/widgets/days/repeated-midnight", test_days_repeated_midnight);
  g_test_add_func("/widgets/days/repeated-midnight-havana", test_days_repeated_midnight_havana);
  g_test_add_func("/widgets/days/dst-day", test_days_dst_day);
  g_test_add_func("/widgets/days/zone-change", test_days_zone_change);
  g_test_add_func("/widgets/days/missing-values", test_days_missing_values);
  g_test_add_func("/widgets/days/compare-before-set", test_days_compare_before_set);
  g_test_add_func("/widgets/days/dispose-and-null", test_days_dispose_and_null);
  g_test_add_func("/widgets/state-audit/strip", test_strip_state_audit);
  g_test_add_func("/widgets/state-audit/days", test_days_state_audit);
  g_test_add_func("/widgets/state-audit/chart", test_chart_state_audit);
  g_test_add_func("/widgets/zone-failure/strip-heals", test_strip_zone_failure_heals);
  g_test_add_func("/widgets/zone-failure/days-heal", test_days_zone_failure_heals);
  g_test_add_func("/widgets/zone-failure/days-heal-labels-only", test_days_zone_heal_changes_only_labels);
  g_test_add_func("/widgets/zone-failure/chart-heals", test_chart_zone_failure_heals);
  g_test_add_func("/widgets/zone-failure/unknown-zone-one-lookup-per-30s", test_unknown_zone_costs_one_lookup_per_30s);
  g_test_add_func("/widgets/zone-failure/name-change-while-fallback-held", test_zone_name_change_while_fallback_held);
  g_test_add_func("/widgets/icons-exist-in-theme", test_icons_exist_in_theme);
  g_test_add_func("/widgets/tmp-cleanup/recursive", test_remove_tree_recursive);
  g_test_add_func("/widgets/tmp-cleanup/skip-and-abort", test_tmp_cleanup_on_skip_and_abort);
  int rc = g_test_run();
  remove_tmp_tree();
  return rc;
}
