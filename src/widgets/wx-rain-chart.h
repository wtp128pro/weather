/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-rain-chart.h - WxRainChart: bar chart of the coming rain, drawn with
 * GtkSnapshot (no cairo).
 *
 * Two views (see WxRainChartView and wx_rain_chart_set_view(); a new chart is
 * in WX_RAIN_CHART_AUTO; the detail pane shows one HOURLY and one NOWCAST
 * chart side by side):
 *  - 15-minute view when the forecast's blended nowcast (WxForecast quarters)
 *    covers "now", i.e. it holds a valid quarter that starts at the 15-minute
 *    slot containing "now": the next WX_RAIN_CHART_QUARTER_SLOTS (8, i.e. 2
 *    hours) slots starting with that quarter; the bar is the rate (amount x
 *    4) in mm/h or in/h. There is no probability line.
 *  - hourly view otherwise: the next WX_RAIN_CHART_HOURS (24) hours, one slot
 *    per UTC hour starting with the hour that contains "now". The bar of a
 *    slot is the expected rain rate of that hour (mm/h or in/h, WxBlendHour
 *    precip_mm), drawn against a vertical scale that starts at 2.5 mm/h
 *    (0.1 in/h) and doubles when needed; a line over the bars is the chance
 *    of rain (precip_prob, 0..100 %, labelled "100%" / "0%" on the right).
 * In WX_RAIN_CHART_AUTO the view switches by itself whenever the data changes
 * (a forecast with a nowcast, then one without, and back);
 * WX_RAIN_CHART_HOURLY always shows the hourly view, whatever quarters the
 * forecast has; WX_RAIN_CHART_NOWCAST shows the 15-minute view when the
 * nowcast covers "now" and "No data" otherwise.
 * A slot without a value is left empty (no bar, a gap in the line). The time
 * axis shows at most 5 labels in the place's time zone ("Now", "3 PM" /
 * "3:45 PM"); labels that would overlap are skipped. The chart is always laid
 * out left to right.
 *
 * With no forecast, no value in the window or a "now" outside the valid time
 * range the chart shows "No data".
 *
 * Colour: the bars use the CSS `color` of the widget (CSS node name
 * "wx-rain-chart"; a fallback style at GTK_STYLE_PROVIDER_PRIORITY_FALLBACK,
 * installed when the class is first used with a default display, sets it to
 * a blue), the grid, labels and probability line use the CSS `color` of the
 * parent.
 *
 * Accessibility: the widget has the image role (tested). Its accessible label
 * ("Rain chart") and description (a sentence that summarises the window, e.g.
 * "Rain chance by hour for the next 24 hours. Highest chance: 60% at 4 PM.")
 * are set with gtk_accessible_update_property() whenever the data changes;
 * GTK has no public getter for them, so their text is not asserted by the
 * tests.
 *
 * Bounded work: at most 24 slots are kept and drawn; scanning the forecast
 * visits at most its (validated) hour / quarter arrays once; no timers,
 * animations or tick callbacks; a redraw is queued only when the displayed
 * data, the units or the zone really change.
 *
 * Lifecycle: all Pango/GSK references are dropped in dispose(); after
 * g_object_run_dispose() every method is a harmless no-op and nothing is
 * drawn. Main thread only, like every GtkWidget.
 */
#ifndef WX_RAIN_CHART_H
#define WX_RAIN_CHART_H

#include <gtk/gtk.h>

#include "wx-types.h"

G_BEGIN_DECLS

#define WX_TYPE_RAIN_CHART (wx_rain_chart_get_type())
G_DECLARE_FINAL_TYPE(WxRainChart, wx_rain_chart, WX, RAIN_CHART, GtkWidget)

/** Number of slots of the hourly view (the next 24 hours). */
#define WX_RAIN_CHART_HOURS 24
/** Number of slots of the 15-minute view (the next 2 hours). */
#define WX_RAIN_CHART_QUARTER_SLOTS 8

/** Which view a chart shows. */
typedef enum {
  WX_RAIN_CHART_AUTO,    /**< 15-minute view while the nowcast covers "now", else hourly */
  WX_RAIN_CHART_HOURLY,  /**< always the next 24 hours, hour by hour */
  WX_RAIN_CHART_NOWCAST  /**< the next 2 hours in 15 minutes, only while the nowcast covers "now" */
} WxRainChartView;

/**
 * wx_rain_chart_new:
 *
 * Creates an empty chart.
 *
 * Preconditions:
 *  - GTK is initialised; main thread.
 * Postconditions:
 *  - the chart shows "No data"; it expands in both directions and requests
 *    at least 160x96 px (natural 360x140). Floating reference.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the floating reference.
 *
 * Returns: (transfer floating): a new chart.
 */
GtkWidget *wx_rain_chart_new(void);

/**
 * wx_rain_chart_set_forecast:
 * @self: (not nullable): a WxRainChart.
 * @forecast: (nullable) (transfer none): the forecast to show, NULL for "No
 *   data".
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC (axis label).
 * @now_s: the current time, UTC unix seconds; selects the window and, with the
 *   data, the view (see the file comment).
 *
 * Copies the (at most 24) values of the window and the place's time zone name;
 * no reference to @forecast is kept, so it may be unreffed or replaced at once.
 * Compare-before-set: the raw copied window (view included), the units and the
 * zone are compared first; when they equal the displayed ones nothing else
 * happens (nothing is formatted, no redraw).
 *
 * The place's zone is resolved here, once per change of the zone name (the
 * first use of a zone reads its zoneinfo file), and held; snapshot() only
 * formats the axis labels with that held zone, so drawing never resolves a
 * zone and never reads a file, whatever other zones are used elsewhere in the
 * process. If the lookup of a zone name FAILED (unknown to GLib, or a
 * transient error), the chart uses UTC labels for now, does NOT treat the
 * name as resolved, and tries again on every following call (at most one new
 * file access per 30 seconds per name, see wx-format.h) until it succeeds;
 * the call that succeeds rebuilds the axis and the description with the real
 * zone and queues a redraw even though forecast, units and @now_s are
 * unchanged. A chart that gets no further call keeps the fallback until the
 * next one (nothing retries on its own: there are no timers or draw-time
 * lookups). After dispose it is a no-op.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_RAIN_CHART() and @units is a WxUnits member
 *    (otherwise critical, nothing happens); @forecast is NULL or valid and
 *    not modified during the call.
 * Postconditions:
 *  - at most 24 slots are stored whatever the forecast size; a redraw is
 *    queued only when something changed.
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed for the call.
 */
void wx_rain_chart_set_forecast(WxRainChart *self, const WxForecast *forecast, WxUnits units,
                                gint64 now_s);

/**
 * wx_rain_chart_set_view:
 * @self: (not nullable): a WxRainChart.
 * @view: the view the chart shows from now on.
 *
 * Chooses the view (see the file comment). A call that changes the view
 * discards the displayed window: the chart shows "No data" (and
 * wx_rain_chart_has_data() is FALSE) until the next wx_rain_chart_set_forecast(),
 * whatever the data; a call with the view the chart already has does nothing.
 * After dispose it is a no-op.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_RAIN_CHART() and @view is a WxRainChartView member
 *    (otherwise critical, nothing happens).
 * Postconditions:
 *  - the view is @view; a redraw is queued only when it changed.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_rain_chart_set_view(WxRainChart *self, WxRainChartView view);

/**
 * wx_rain_chart_has_data:
 * @self: (not nullable): a WxRainChart.
 *
 * Tells whether the chart draws something other than "No data": some slot of
 * the displayed window has a value. A NOWCAST chart whose forecast has no
 * nowcast covering "now" has none.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_RAIN_CHART() (otherwise critical, FALSE returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the displayed window has a value; FALSE after dispose.
 */
gboolean wx_rain_chart_has_data(WxRainChart *self);

G_END_DECLS

#endif /* WX_RAIN_CHART_H */
