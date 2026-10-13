/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-day-list.h - WxDayList: the daily forecast, one row per day.
 *
 * At most WX_DAY_LIST_MAX_ROWS (10) rows, starting with the day that contains
 * "now". Each row shows the weekday ("Today", "Tomorrow", "Saturday"), an
 * icon, the chance of rain, the low and the high temperature, and carries a
 * tooltip with the expected amount, the chance and the cloud cover. An unknown
 * number is shown as an em dash. The day of "now" summarises only the hours
 * the forecast still holds (see wx_format_day_covered_from()): when the
 * forecast's first hour is later than the start of that day its tooltip has a
 * third line "Covers the rest of the day, from 2 PM." (the hour label of the
 * first hour in the place's zone).
 *
 * The rows are created once in the constructor and only re-bound afterwards;
 * unused rows are hidden. Standard GTK widgets only (GtkBox of rows of
 * GtkLabel / GtkImage); CSS node name "wx-day-list", row class "day-row",
 * the labels carry the classes "day", "rain", "low" and "high". No timers.
 * No externally sourced text is displayed.
 *
 * Lifecycle: dispose() unparents the child; afterwards set_forecast() is a
 * no-op. Main thread only.
 */
#ifndef WX_DAY_LIST_H
#define WX_DAY_LIST_H

#include <gtk/gtk.h>

#include "wx-types.h"

G_BEGIN_DECLS

#define WX_TYPE_DAY_LIST (wx_day_list_get_type())
G_DECLARE_FINAL_TYPE(WxDayList, wx_day_list, WX, DAY_LIST, GtkWidget)

/** Number of rows created, and so the most days ever shown. */
#define WX_DAY_LIST_MAX_ROWS 10

/**
 * wx_day_list_new:
 *
 * Creates an empty list (all rows hidden).
 *
 * Preconditions:
 *  - GTK is initialised; main thread.
 * Postconditions:
 *  - WX_DAY_LIST_MAX_ROWS hidden rows exist; floating reference.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the floating reference.
 *
 * Returns: (transfer floating): a new list.
 */
GtkWidget *wx_day_list_new(void);

/**
 * wx_day_list_set_forecast:
 * @self: (not nullable): a WxDayList.
 * @forecast: (nullable) (transfer none): the forecast, NULL hides every row.
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 * @now_s: the current time, UTC unix seconds. A day is listed until its own
 *   local end (the first instant of a later local date in the place's zone, see
 *   wx_format_local_day_end()) has passed, so a day missing from the forecast
 *   between two listed days never shows as a stale row.
 *
 * Copies what it displays (nothing of @forecast is kept). Compare-before-set:
 * the raw day values, the units and the zone are compared first, and a row
 * that is unchanged is not touched and nothing is formatted for it. Only when
 * the LOCAL DATE of @now_s changes (in the place's zone) are the day labels
 * ("Today", "Tomorrow", ...) recomputed, and a row is rebound only if its label
 * changed.
 *
 * The place's zone is resolved here, once per change of the zone name (the
 * first use of a zone reads its zoneinfo file), and held: the day-end test and
 * the labels use that held zone, so a call never looks a zone up again,
 * whatever other zones are used meanwhile. If the lookup of a zone name FAILED
 * (unknown to GLib, or a transient error), the widget uses UTC for now, does
 * NOT treat the name as resolved, and tries again on every following call
 * (at most one new file access per 30 seconds per name, see wx-format.h) until
 * it succeeds; the call that succeeds rebuilds every row with the real zone
 * even though forecast, units and @now_s are unchanged. A widget that gets no
 * further call keeps the fallback until the next one (nothing retries on its
 * own: there are no timers). After dispose it is a no-op.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_DAY_LIST() and @units is a WxUnits member
 *    (otherwise critical, nothing happens); @forecast is NULL or valid.
 * Postconditions:
 *  - min(10, remaining days) rows are visible, the rest hidden.
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed for the call.
 */
void wx_day_list_set_forecast(WxDayList *self, const WxForecast *forecast, WxUnits units,
                              gint64 now_s);

G_END_DECLS

#endif /* WX_DAY_LIST_H */
