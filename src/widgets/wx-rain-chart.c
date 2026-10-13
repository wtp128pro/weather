/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-rain-chart.c - WxRainChart: rain bars drawn with GtkSnapshot.
 * See wx-rain-chart.h for the public contract.
 *
 * set_forecast() copies the (at most WX_RAIN_CHART_HOURS) values of the
 * window into a small Window struct and compares it with the displayed one;
 * snapshot() only draws from that struct, so it never touches the forecast.
 */
#include "wx-rain-chart.h"

#include <math.h>
#include <string.h>

#include "wx-format.h"
#include "wx-widget-util.h"

#define MIN_WIDTH 160
#define MIN_HEIGHT 96
#define NAT_WIDTH 360
#define NAT_HEIGHT 140

#define MAX_SLOTS WX_RAIN_CHART_HOURS
#define MAX_X_LABELS 5
#define PAD 3.0f
#define LABEL_GAP 4.0f

/* Vertical scale starts here (a rate the blend calls "light rain" at most)
 * and doubles until the largest bar fits. */
#define BASE_SCALE_MM_H 2.5
#define BASE_SCALE_IN_H 0.1
#define MAX_SCALE_DOUBLINGS 24

enum {
  L_NODATA,
  L_AMOUNT,
  L_PCT_TOP,
  L_PCT_BOT,
  L_X0,
  N_LAYOUTS = L_X0 + MAX_X_LABELS
};

/* The copied window: mmh[i] is the rain rate of slot i in mm/h, prob[i] the
 * chance in percent; NAN = no value. */
typedef struct {
  gboolean quarters; /* 15-minute slots (the nowcast) instead of hours */
  gint64 start_s;
  guint n; /* 0 (nothing to show) or the slot count of the view */
  double mmh[MAX_SLOTS];
  double prob[MAX_SLOTS];
} Window;

struct _WxRainChart {
  GtkWidget parent_instance;
  Window win;
  WxRainChartView view;
  WxUnits units;
  WxHeldZone zone;               /* the place zone, resolved in set_forecast; cleared by dispose */
  gboolean has_data;
  double scale;                  /* top of the bar scale, mm/h */
  PangoLayout *layout[N_LAYOUTS]; /* NULL after dispose */
  GskStroke *stroke;              /* NULL after dispose */
};

/* Type boilerplate: defines wx_rain_chart_get_type() and the parent class
 * pointer; main thread only. */
G_DEFINE_FINAL_TYPE(WxRainChart, wx_rain_chart, GTK_TYPE_WIDGET)

/**
 * window_equal:
 * @a: first window.
 * @b: second window.
 *
 * Preconditions:
 *  - both non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff both windows hold the same slots (NAN equals NAN). The slot
 *   count tells the views apart (8 quarter slots, 24 hourly slots).
 */
static gboolean
window_equal(const Window *a, const Window *b)
{
  if (a->n != b->n || a->start_s != b->start_s)
    return FALSE;
  for (guint i = 0; i < a->n; i++)
    if (!wx_same_value(a->mmh[i], b->mmh[i]) || !wx_same_value(a->prob[i], b->prob[i]))
      return FALSE;
  return TRUE;
}

/**
 * nowcast_covers:
 * @forecast: non-NULL forecast.
 * @quarter_s: start of the 15-minute slot that contains "now".
 *
 * Preconditions:
 *  - @forecast is non-NULL with valid arrays (quarters ascending).
 * Postconditions:
 *  - no state is changed; the quarters are scanned at most once.
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed.
 *
 * Returns: TRUE iff the forecast has a quarter that starts exactly at
 *   @quarter_s and carries a valid amount (the blended nowcast covers now).
 */
static gboolean
nowcast_covers(const WxForecast *forecast, gint64 quarter_s)
{
  for (guint k = 0; k < forecast->n_quarters && forecast->quarters[k].t_s <= quarter_s; k++)
    if (forecast->quarters[k].t_s == quarter_s)
      return wx_value_in_range(forecast->quarters[k].precip_mm, 0.0, WX_PRECIP_MAX_MM_H);
  return FALSE;
}

/**
 * build_window:
 * @forecast: (nullable): forecast to read.
 * @now_s: the current time.
 * @view: which view the chart shows.
 * @out: (out): receives the window.
 *
 * Builds the window of @view. WX_RAIN_CHART_HOURLY: the next 24 hours in
 * hourly slots from the hour that contains @now_s. WX_RAIN_CHART_NOWCAST: when
 * the forecast's 15-minute nowcast covers "now" (a valid quarter starting at
 * the quarter that contains @now_s) the next 2 hours in 15-minute slots from
 * that quarter, otherwise an empty window (n is 0). WX_RAIN_CHART_AUTO: the
 * nowcast window when it covers "now", otherwise the hourly one. The forecast
 * arrays are ascending, so the scan stops at the first entry past the window;
 * values outside their valid range become NAN.
 *
 * Preconditions:
 *  - @out is non-NULL; @forecast, when non-NULL, has valid arrays; @view is a
 *    WxRainChartView member.
 * Postconditions:
 *  - *@out is fully initialised; n is 0 when @forecast is NULL or @now_s is
 *    outside the valid time range, or when @view is the nowcast view and the
 *    nowcast does not cover "now". At most the forecast's own array length is
 *    read, once per scan.
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed.
 */
static void
build_window(const WxForecast *forecast, gint64 now_s, WxRainChartView view, Window *out)
{
  memset(out, 0, sizeof *out);
  if (forecast == NULL || now_s < WX_TIME_MIN_S || now_s >= WX_TIME_MAX_S)
    return;
  out->quarters = view != WX_RAIN_CHART_HOURLY &&
                  nowcast_covers(forecast, now_s - now_s % 900); /* now_s > 0 */
  if (view == WX_RAIN_CHART_NOWCAST && !out->quarters)
    return;
  gboolean hourly = !out->quarters;
  gint64 step = hourly ? 3600 : 900;
  guint slots = hourly ? WX_RAIN_CHART_HOURS : WX_RAIN_CHART_QUARTER_SLOTS;
  out->start_s = now_s - now_s % step;
  out->n = slots;
  for (guint i = 0; i < MAX_SLOTS; i++)
    out->mmh[i] = out->prob[i] = NAN;
  gint64 end_s = out->start_s + (gint64)slots * step;
  if (hourly) {
    for (guint k = 0; k < forecast->n_hours && forecast->hours[k].t_s < end_s; k++) {
      const WxBlendHour *h = &forecast->hours[k];
      if (h->t_s < out->start_s)
        continue;
      guint i = (guint)((h->t_s - out->start_s) / step);
      out->mmh[i] = wx_value_in_range(h->precip_mm, 0.0, WX_PRECIP_MAX_MM_H) ? h->precip_mm : NAN;
      out->prob[i] =
          wx_value_in_range(h->precip_prob, WX_PERCENT_MIN, WX_PERCENT_MAX) ? h->precip_prob : NAN;
    }
  } else {
    for (guint k = 0; k < forecast->n_quarters && forecast->quarters[k].t_s < end_s; k++) {
      const WxQuarter *q = &forecast->quarters[k];
      if (q->t_s < out->start_s)
        continue;
      guint i = (guint)((q->t_s - out->start_s) / step);
      out->mmh[i] = wx_value_in_range(q->precip_mm, 0.0, WX_PRECIP_MAX_MM_H) ? q->precip_mm * 4.0 : NAN;
    }
  }
}

/**
 * window_scale:
 * @win: non-NULL window.
 * @units: unit system, which decides the 1-2-4 ladder of the scale.
 *
 * Preconditions:
 *  - @win is non-NULL, @units a WxUnits member.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: the top of the bar scale in mm/h: 2.5 mm/h (0.1 in/h) doubled until
 *   the largest finite bar fits; at most 2.5 * 2^24 (the loop is bounded).
 */
static double
window_scale(const Window *win, WxUnits units)
{
  double top = units == WX_UNITS_METRIC ? BASE_SCALE_MM_H : BASE_SCALE_IN_H * 25.4;
  double max = 0.0;
  for (guint i = 0; i < win->n; i++)
    if (win->mmh[i] > max)
      max = win->mmh[i];
  for (int k = 0; k < MAX_SCALE_DOUBLINGS && top < max; k++)
    top *= 2.0;
  return top;
}

/**
 * window_has_data:
 * @win: non-NULL window.
 *
 * Preconditions:
 *  - @win is non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff some slot has a value that the chart would draw.
 */
static gboolean
window_has_data(const Window *win)
{
  for (guint i = 0; i < win->n; i++)
    if (!isnan(win->mmh[i]) || !isnan(win->prob[i]))
      return TRUE;
  return FALSE;
}

/**
 * slot_label:
 * @self: the chart.
 * @i: slot index.
 *
 * Time axis text of a slot: "Now" for the first, else the local hour ("3 PM")
 * or clock ("3:45 PM") of the slot start, in the zone the chart holds (no zone
 * lookup, so no file access, at draw time).
 *
 * Preconditions:
 *  - @self has data and @i < self->win.n.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): the label.
 */
static char *
slot_label(const WxRainChart *self, guint i)
{
  if (i == 0)
    return g_strdup("Now");
  if (!self->win.quarters)
    return wx_format_hour_label_z(self->win.start_s + (gint64)i * 3600, self->zone.zone);
  return wx_format_clock_z(self->win.start_s + (gint64)i * 900, self->zone.zone);
}

/**
 * describe:
 * @self: the chart, with its window, units and zone set.
 *
 * Builds the accessible description of the current window.
 *
 * Preconditions:
 *  - @self is a live chart.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full): the sentence(s).
 */
static char *
describe(const WxRainChart *self)
{
  if (!self->has_data)
    return g_strdup("No rain data.");
  const Window *w = &self->win;
  gboolean hourly = !self->win.quarters;
  const char *span = hourly ? "Rain chance by hour for the next 24 hours."
                            : "Rain intensity every 15 minutes for the next 2 hours.";
  guint best = 0;
  gboolean use_prob = FALSE;
  double best_v = -1.0;
  if (hourly) {
    for (guint i = 0; i < w->n; i++)
      if (!isnan(w->prob[i]) && w->prob[i] > best_v) {
        best_v = w->prob[i];
        best = i;
        use_prob = TRUE;
      }
  }
  if (!use_prob) {
    if (hourly)
      span = "Rain amount by hour for the next 24 hours.";
    for (guint i = 0; i < w->n; i++)
      if (!isnan(w->mmh[i]) && w->mmh[i] > best_v) {
        best_v = w->mmh[i];
        best = i;
      }
    if (best_v <= 0.0)
      return g_strdup_printf("%s No rain expected.", span);
  }
  g_autofree char *when = slot_label(self, best);
  g_autofree char *value = use_prob ? wx_format_percent(best_v) : wx_format_precip(best_v, self->units);
  if (use_prob)
    return g_strdup_printf("%s Highest chance: %s at %s.", span, value, best == 0 ? "the current hour" : when);
  return g_strdup_printf("%s Heaviest: %s per hour at %s.", span, value,
                         best == 0 ? "the current time" : when);
}

/**
 * wx_rain_chart_measure:
 * @widget: unused.
 * @orientation: which dimension is measured.
 * @for_size: unused.
 * @minimum: (out): minimum size.
 * @natural: (out): natural size.
 * @minimum_baseline: (out): receives -1.
 * @natural_baseline: (out): receives -1.
 *
 * Preconditions:
 *  - the four pointers are non-NULL (GTK always passes them).
 * Postconditions:
 *  - 160x96 minimum, 360x140 natural; no baselines.
 * Thread affinity: main thread only.
 * Ownership: outputs are caller-owned.
 */
static void
wx_rain_chart_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum,
                      int *natural, int *minimum_baseline, int *natural_baseline)
{
  (void)widget;
  (void)for_size;
  gboolean horizontal = orientation == GTK_ORIENTATION_HORIZONTAL;
  *minimum = horizontal ? MIN_WIDTH : MIN_HEIGHT;
  *natural = horizontal ? NAT_WIDTH : NAT_HEIGHT;
  *minimum_baseline = -1;
  *natural_baseline = -1;
}

/**
 * draw_text:
 * @snapshot: snapshot to append to.
 * @layout: layout whose text is already set.
 * @x: left edge.
 * @y: top edge.
 * @color: text colour.
 *
 * Preconditions:
 *  - all non-NULL.
 * Postconditions:
 *  - the saved snapshot state is restored.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
draw_text(GtkSnapshot *snapshot, PangoLayout *layout, float x, float y, const GdkRGBA *color)
{
  gtk_snapshot_save(snapshot);
  gtk_snapshot_translate(snapshot, &(graphene_point_t){ x, y });
  gtk_snapshot_append_layout(snapshot, layout, color);
  gtk_snapshot_restore(snapshot);
}

/**
 * fill_rect:
 * @snapshot: snapshot to append to.
 * @color: fill colour.
 * @x: left edge.
 * @y: top edge.
 * @w: width.
 * @h: height.
 *
 * Preconditions:
 *  - all non-NULL pointers.
 * Postconditions:
 *  - one colour node was appended.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
fill_rect(GtkSnapshot *snapshot, const GdkRGBA *color, float x, float y, float w, float h)
{
  gtk_snapshot_append_color(snapshot, color, &GRAPHENE_RECT_INIT(x, y, w, h));
}

/**
 * set_text:
 * @layout: layout to fill.
 * @text: new text.
 * @w: (out) (nullable): receives the pixel width.
 * @h: (out) (nullable): receives the pixel height.
 *
 * Preconditions:
 *  - @layout and @text non-NULL.
 * Postconditions:
 *  - the layout shows @text and *@w / *@h hold its pixel size.
 * Thread affinity: main thread only.
 * Ownership: @text is copied.
 */
static void
set_text(PangoLayout *layout, const char *text, int *w, int *h)
{
  pango_layout_set_text(layout, text, -1);
  int lw, lh;
  pango_layout_get_pixel_size(layout, &lw, &lh);
  if (w != NULL)
    *w = lw;
  if (h != NULL)
    *h = lh;
}

/**
 * draw_probability_line:
 * @snapshot: snapshot to append to.
 * @self: chart with data in the hourly view.
 * @color: line colour.
 * @px: left edge of the plot.
 * @pw: plot width.
 * @y1: bottom of the plot.
 * @ph: plot height.
 *
 * Strokes the chance-of-rain polyline over the slot centres; a gap in the data
 * breaks the line and a lone value is drawn as a small square.
 *
 * Preconditions:
 *  - all non-NULL; self->win.n > 0; self->stroke non-NULL.
 * Postconditions:
 *  - the path builder is consumed.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
draw_probability_line(GtkSnapshot *snapshot, const WxRainChart *self, const GdkRGBA *color,
                      float px, float pw, float y1, float ph)
{
  const Window *w = &self->win;
  float sw = pw / (float)w->n;
  GskPathBuilder *builder = gsk_path_builder_new();
  gboolean any = FALSE;
  for (guint i = 0; i < w->n; i++) {
    if (isnan(w->prob[i]))
      continue;
    float x = px + (float)i * sw + sw / 2.0f;
    float y = y1 - (float)(w->prob[i] / 100.0) * ph;
    gboolean prev = i > 0 && !isnan(w->prob[i - 1]);
    gboolean next = i + 1 < w->n && !isnan(w->prob[i + 1]);
    if (!prev && !next) {
      fill_rect(snapshot, color, x - 1.5f, y - 1.5f, 3.0f, 3.0f);
      continue;
    }
    if (prev)
      gsk_path_builder_line_to(builder, x, y);
    else
      gsk_path_builder_move_to(builder, x, y);
    any = TRUE;
  }
  GskPath *path = gsk_path_builder_free_to_path(builder);
  if (any)
    gtk_snapshot_append_stroke(snapshot, path, self->stroke, color);
  gsk_path_unref(path);
}

/**
 * wx_rain_chart_snapshot:
 * @widget: (not nullable): the WxRainChart.
 * @snapshot: (not nullable): snapshot to append to.
 *
 * Draws the chart from the copied window: grid lines at 0 / 50 / 100 % of the
 * plot height, one bar per slot, the chance line (hourly view), the top-of-scale
 * label, the percentage labels and at most 5 time labels, or "No data".
 *
 * Preconditions:
 *  - called by GTK with a valid @snapshot.
 * Postconditions:
 *  - nothing is drawn after dispose or when the widget has no size; the saved
 *    snapshot state is restored; the widget state is not changed (only the
 *    cached layouts get new text).
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
wx_rain_chart_snapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
  WxRainChart *self = WX_RAIN_CHART(widget);
  if (self->stroke == NULL)
    return;
  float w = (float)gtk_widget_get_width(widget);
  float h = (float)gtk_widget_get_height(widget);
  if (w <= 0.0f || h <= 0.0f)
    return;

  GdkRGBA bar, fg;
  gtk_widget_get_color(widget, &bar);
  GtkWidget *parent = gtk_widget_get_parent(widget);
  if (parent != NULL)
    gtk_widget_get_color(parent, &fg);
  else
    fg = bar;
  GdkRGBA dim = fg;
  dim.alpha *= 0.6f;
  GdkRGBA grid = fg;
  grid.alpha *= 0.2f;

  int tw, th;
  if (!self->has_data) {
    set_text(self->layout[L_NODATA], "No data", &tw, &th);
    draw_text(snapshot, self->layout[L_NODATA], floorf((w - (float)tw) / 2.0f),
              floorf((h - (float)th) / 2.0f), &dim);
    return;
  }

  gboolean hourly = !self->win.quarters;
  const Window *win = &self->win;

  set_text(self->layout[L_PCT_TOP], "100%", &tw, &th);
  set_text(self->layout[L_PCT_BOT], "0%", NULL, NULL);
  float right = hourly ? (float)tw + LABEL_GAP : 0.0f;
  float axis_h = (float)th + LABEL_GAP;
  float px = 0.0f, pw = w - right;
  float py = PAD, y1 = h - axis_h;
  float ph = y1 - py;
  if (pw <= 1.0f || ph <= 1.0f)
    return;

  /* Grid: bottom, middle, top. */
  fill_rect(snapshot, &grid, px, y1 - 1.0f, pw, 1.0f);
  fill_rect(snapshot, &grid, px, py + ph / 2.0f, pw, 1.0f);
  fill_rect(snapshot, &grid, px, py, pw, 1.0f);

  /* Bars. */
  float sw = pw / (float)win->n;
  float bw = fmaxf(1.0f, sw * 0.7f);
  for (guint i = 0; i < win->n; i++) {
    if (isnan(win->mmh[i]) || win->mmh[i] <= 0.0)
      continue;
    float bh = fminf(ph, fmaxf(1.0f, (float)(win->mmh[i] / self->scale) * ph));
    fill_rect(snapshot, &bar, px + (float)i * sw + (sw - bw) / 2.0f, y1 - bh, bw, bh);
  }

  if (hourly)
    draw_probability_line(snapshot, self, &fg, px, pw, y1, ph);

  /* Top-of-scale label inside the plot, percent labels on the right. */
  g_autofree char *top = wx_format_precip(self->scale, self->units);
  g_autofree char *amount = g_strdup_printf("%s/h", top);
  set_text(self->layout[L_AMOUNT], amount, NULL, NULL);
  draw_text(snapshot, self->layout[L_AMOUNT], px + 2.0f, py + 1.0f, &dim);
  if (hourly) {
    draw_text(snapshot, self->layout[L_PCT_TOP], pw + LABEL_GAP, py - 1.0f, &dim);
    draw_text(snapshot, self->layout[L_PCT_BOT], pw + LABEL_GAP, y1 - (float)th, &dim);
  }

  /* Time axis: up to MAX_X_LABELS evenly spread slots, skipping overlaps. */
  float last_right = -LABEL_GAP;
  for (guint k = 0; k < MAX_X_LABELS; k++) {
    /* distinct for both window sizes (24 and 8 slots): 0 6 12 17 23 / 0 2 4 5 7 */
    guint slot = (guint)lround((double)k * (win->n - 1) / (MAX_X_LABELS - 1));
    g_autofree char *text = slot_label(self, slot);
    int lw;
    set_text(self->layout[L_X0 + k], text, &lw, NULL);
    float cx = px + (float)slot * sw + sw / 2.0f;
    float x = fminf(fmaxf(0.0f, cx - (float)lw / 2.0f), w - (float)lw);
    if (x < last_right + LABEL_GAP)
      continue;
    draw_text(snapshot, self->layout[L_X0 + k], floorf(x), y1 + 2.0f, &dim);
    last_right = x + (float)lw;
  }
}

/**
 * reset_layouts:
 * @self: the chart.
 *
 * Tells every layout that its Pango context changed (font, scale, theme).
 *
 * Preconditions:
 *  - @self is a WxRainChart (layouts may be NULL after dispose).
 * Postconditions:
 *  - every live layout will re-measure at its next use.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
reset_layouts(WxRainChart *self)
{
  for (guint i = 0; i < N_LAYOUTS; i++)
    if (self->layout[i] != NULL)
      pango_layout_context_changed(self->layout[i]);
}

/**
 * wx_rain_chart_css_changed:
 * @widget: (not nullable): the WxRainChart.
 * @change: the CSS change.
 *
 * Chains up, then invalidates the cached layouts (font or scale may differ).
 *
 * Preconditions:
 *  - called by GTK on a live (possibly disposed) widget.
 * Postconditions:
 *  - layouts are re-validated; GTK queues the redraw itself.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
wx_rain_chart_css_changed(GtkWidget *widget, GtkCssStyleChange *change)
{
  GTK_WIDGET_CLASS(wx_rain_chart_parent_class)->css_changed(widget, change);
  reset_layouts(WX_RAIN_CHART(widget));
}

/**
 * wx_rain_chart_dispose:
 * @object: (not nullable): the chart being disposed.
 *
 * Drops every Pango / GSK reference. A NULL stroke marks the disposed state,
 * so snapshot() and set_forecast() are no-ops afterwards. Runs more than once
 * safely.
 *
 * Preconditions:
 *  - @object is a WxRainChart.
 * Postconditions:
 *  - layouts, stroke and zone are NULL, has_data is FALSE, the parent dispose ran.
 * Thread affinity: main thread only.
 * Ownership: the references are owned by @object and released here.
 */
static void
wx_rain_chart_dispose(GObject *object)
{
  WxRainChart *self = WX_RAIN_CHART(object);
  for (guint i = 0; i < N_LAYOUTS; i++)
    g_clear_object(&self->layout[i]);
  g_clear_pointer(&self->stroke, gsk_stroke_free);
  wx_held_zone_clear(&self->zone);
  self->has_data = FALSE;
  G_OBJECT_CLASS(wx_rain_chart_parent_class)->dispose(object);
}

/**
 * wx_rain_chart_class_init:
 * @klass: (not nullable): the class being initialised.
 *
 * Installs dispose / measure / snapshot / css_changed, the CSS node name and
 * the image accessible role and, when a default display exists, the fallback
 * colour style (see wx-rain-chart.h).
 *
 * Preconditions:
 *  - called once by GObject (main thread).
 * Postconditions:
 *  - the style provider belongs to the display, the local reference is
 *    dropped.
 * Thread affinity: main thread only.
 * Ownership: the provider is owned by the display afterwards.
 */
static void
wx_rain_chart_class_init(WxRainChartClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS(klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);

  object_class->dispose = wx_rain_chart_dispose;
  widget_class->measure = wx_rain_chart_measure;
  widget_class->snapshot = wx_rain_chart_snapshot;
  widget_class->css_changed = wx_rain_chart_css_changed;
  gtk_widget_class_set_css_name(widget_class, "wx-rain-chart");
  gtk_widget_class_set_accessible_role(widget_class, GTK_ACCESSIBLE_ROLE_IMG);

  GdkDisplay *display = gdk_display_get_default();
  if (display != NULL) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider,
                                      "@define-color accent_color #3584e4;\n"
                                      "wx-rain-chart { color: @accent_color; }\n");
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_FALLBACK);
    g_object_unref(provider);
  }
}

/**
 * wx_rain_chart_init:
 * @self: (not nullable): the instance being initialised.
 *
 * Creates the small-font layouts and the 1.5 px round stroke, expands the
 * widget and sets the accessible label.
 *
 * Preconditions:
 *  - called by GObject on a zero-filled instance (GTK initialised).
 * Postconditions:
 *  - layouts and stroke are non-NULL (until dispose); the window is empty.
 * Thread affinity: main thread only.
 * Ownership: layouts and stroke are owned by @self.
 */
static void
wx_rain_chart_init(WxRainChart *self)
{
  GtkWidget *widget = GTK_WIDGET(self);
  gtk_widget_set_hexpand(widget, TRUE);
  gtk_widget_set_vexpand(widget, TRUE);
  for (guint i = 0; i < N_LAYOUTS; i++) {
    self->layout[i] = gtk_widget_create_pango_layout(widget, NULL);
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_scale_new(PANGO_SCALE_SMALL));
    pango_layout_set_attributes(self->layout[i], attrs);
    pango_attr_list_unref(attrs);
  }
  self->stroke = gsk_stroke_new(1.5f);
  gsk_stroke_set_line_join(self->stroke, GSK_LINE_JOIN_ROUND);
  gsk_stroke_set_line_cap(self->stroke, GSK_LINE_CAP_ROUND);
  self->units = WX_UNITS_METRIC;
  self->scale = BASE_SCALE_MM_H;
  wx_held_zone_init(&self->zone);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self), GTK_ACCESSIBLE_PROPERTY_LABEL, "Rain chart",
                                 GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "No rain data.", -1);
}

/* Documented in wx-rain-chart.h. */
GtkWidget *
wx_rain_chart_new(void)
{
  return g_object_new(WX_TYPE_RAIN_CHART, NULL);
}

/* Documented in wx-rain-chart.h. */
void
wx_rain_chart_set_forecast(WxRainChart *self, const WxForecast *forecast, WxUnits units,
                           gint64 now_s)
{
  g_return_if_fail(WX_IS_RAIN_CHART(self));
  g_return_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC);
  if (self->stroke == NULL) /* disposed */
    return;

  Window win;
  build_window(forecast, now_s, self->view, &win);
  char tz[WX_PLACE_TIMEZONE_MAX + 1] = "";
  if (forecast != NULL && win.n > 0)
    g_strlcpy(tz, forecast->place.timezone, sizeof tz);
  /* The zone is resolved HERE, never at draw time: once per change of the name, and again on every
   * call while the held zone is only the fallback of a failed lookup. A zone that changed (a retry
   * that succeeded included) must rebuild the labels even if the data did not change. */
  gboolean zone_changed = wx_held_zone_update(&self->zone, tz);
  if (!zone_changed && units == self->units && window_equal(&win, &self->win))
    return;

  self->win = win;
  self->units = units;
  self->has_data = window_has_data(&win);
  self->scale = window_scale(&win, units);
  g_autofree char *desc = describe(self);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, desc, -1);
  gtk_widget_queue_draw(GTK_WIDGET(self));
}

/* Documented in wx-rain-chart.h. */
void
wx_rain_chart_set_view(WxRainChart *self, WxRainChartView view)
{
  g_return_if_fail(WX_IS_RAIN_CHART(self));
  g_return_if_fail(view == WX_RAIN_CHART_AUTO || view == WX_RAIN_CHART_HOURLY ||
                   view == WX_RAIN_CHART_NOWCAST);
  if (self->stroke == NULL || view == self->view) /* disposed, or nothing changes */
    return;

  self->view = view;
  memset(&self->win, 0, sizeof self->win); /* "No data" until the next set_forecast() */
  self->has_data = FALSE;
  self->scale = window_scale(&self->win, self->units);
  g_autofree char *desc = describe(self);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, desc, -1);
  gtk_widget_queue_draw(GTK_WIDGET(self));
}

/* Documented in wx-rain-chart.h. */
gboolean
wx_rain_chart_has_data(WxRainChart *self)
{
  g_return_val_if_fail(WX_IS_RAIN_CHART(self), FALSE);
  return self->has_data;
}
