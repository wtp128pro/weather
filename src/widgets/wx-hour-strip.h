/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-hour-strip.h - WxHourStrip: horizontally scrolling row of hourly cards.
 *
 * One card per hour, at most WX_HOUR_STRIP_MAX_CARDS (48), starting with the
 * hour that contains "now" (labelled "Now"). Each card shows the local hour
 * ("3 PM"), a weather icon, the temperature ("77°"), "Rain 20%" and "Cloud
 * 40%", and a tooltip with the exact clock time, feels-like temperature, wind
 * and the expected amount. An unknown number is shown as an em dash.
 *
 * The "Now" card shows the conditions AT now, not at the start of the hour:
 * the values of wx_forecast_now() (temperature, feels-like temperature, wind
 * and cloud cover interpolated towards the next hour; a sky condition of the
 * hour follows that cloud cover, a precipitation, fog or storm condition is
 * kept; day or night by the sun at now), so that the card, the header and the sentences of the detail pane agree.
 * Its tooltip names the clock time of now ("2:30 PM") instead of the start of
 * the hour; the rain chance and amount are those of the hour. Every other card
 * shows its own hour unchanged.
 *
 * The 48 cards are created once, in the constructor, and only re-bound (text
 * and icon name set) afterwards; cards past the data are hidden. Standard GTK
 * widgets only (GtkScrolledWindow > GtkBox of GtkBox / GtkLabel / GtkImage);
 * CSS node name "wx-hour-strip", card CSS class "hour-card", the labels carry
 * the classes "hour", "temp", "rain" and "cloud". No timers, no tick
 * callbacks. All strings shown come from the formatting module, so no
 * externally sourced text is displayed.
 *
 * Lifecycle: dispose() unparents the child; afterwards set_forecast() is a
 * no-op. Main thread only.
 */
#ifndef WX_HOUR_STRIP_H
#define WX_HOUR_STRIP_H

#include <gtk/gtk.h>

#include "wx-types.h"

G_BEGIN_DECLS

#define WX_TYPE_HOUR_STRIP (wx_hour_strip_get_type())
G_DECLARE_FINAL_TYPE(WxHourStrip, wx_hour_strip, WX, HOUR_STRIP, GtkWidget)

/** Number of cards created, and so the most hours ever shown. */
#define WX_HOUR_STRIP_MAX_CARDS 48

/**
 * wx_hour_strip_new:
 *
 * Creates an empty strip (all cards hidden).
 *
 * Preconditions:
 *  - GTK is initialised; main thread.
 * Postconditions:
 *  - WX_HOUR_STRIP_MAX_CARDS hidden cards exist; floating reference.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the floating reference.
 *
 * Returns: (transfer floating): a new strip.
 */
GtkWidget *wx_hour_strip_new(void);

/**
 * wx_hour_strip_set_forecast:
 * @self: (not nullable): a WxHourStrip.
 * @forecast: (nullable) (transfer none): the forecast, NULL hides every card.
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 * @now_s: the current time, UTC unix seconds; the first card is the first hour
 *   that has not ended at @now_s.
 *
 * Copies what it displays (nothing of @forecast is kept). Compare-before-set:
 * a card whose displayed data is unchanged is not touched (and the units and
 * zone are unchanged), so setting the same forecast again does no widget
 * work and looks up no zone.
 *
 * The place's zone is resolved here, once per change of the zone name (the
 * first use of a zone reads its zoneinfo file), and held; binding a card only
 * formats with that held zone, so no card text is ever produced by a zone
 * lookup. If the lookup of a zone name FAILED (unknown to GLib, or a transient
 * error), the widget uses UTC for now, does NOT treat the name as resolved,
 * and tries again on every following call (at most one new file access per
 * 30 seconds per name, see wx-format.h) until it succeeds; the call that
 * succeeds re-binds every card with the real zone even though forecast, units
 * and @now_s are unchanged. A widget that gets no further call keeps the
 * fallback until the next one (nothing retries on its own: there are no
 * timers). After dispose it is a no-op.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_HOUR_STRIP() and @units is a WxUnits member
 *    (otherwise critical, nothing happens); @forecast is NULL or valid.
 * Postconditions:
 *  - min(48, hours from "now" on) cards are visible and show the hours in
 *    order; the rest are hidden.
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed for the call.
 */
void wx_hour_strip_set_forecast(WxHourStrip *self, const WxForecast *forecast, WxUnits units,
                                gint64 now_s);

G_END_DECLS

#endif /* WX_HOUR_STRIP_H */
