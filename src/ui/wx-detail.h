/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-detail.h - WxDetail: the detail pane of the main window (everything about the selected
 * place).
 *
 * WxDetail is a vertical GtkBox with the CSS class "wx-detail" whose only child is a
 * GtkScrolledWindow (name "wx-detail-scroller", horizontal policy NEVER, vertical policy
 * AUTOMATIC) around a GtkStack (name "wx-detail-stack"). The stack has two pages: "placeholder"
 * and "forecast"; "forecast" is visible iff the shown item has a forecast, "placeholder"
 * otherwise (no item, or an item that has no forecast).
 *
 * Everything shown is derived from one WxRowItem (wx_row_item_*): its forecast, place, units,
 * "now" (wx_row_item_get_now_s()), loading / stale / offline flags, error text, fetch time, the
 * current conditions and the rain outlook. The pane never mutates the item (reading it emits
 * nothing) and never reads a clock (every time-dependent text uses the item's "now"); it
 * starts no timer of its own (a GtkSpinner animates itself) and does no network or file access.
 * It follows the item's "changed" signal and re-reads everything on each
 * emission. Every number goes through wx-format.h in the item's units; a missing or implausible
 * number is the em dash U+2014 those functions return.
 *
 * Placeholder page (widget names; every named label, spinner and image also carries its name as
 * CSS class):
 *  - "wx-detail-placeholder-title" / "wx-detail-placeholder-text" (wrapping, centred):
 *      no item:          "Select a place" /
 *                        "Pick a place on the left, or add one with the + button."
 *      loading:          "Loading forecast" + U+2026 / "This takes a few seconds."
 *      error (not loading): "Couldn't load the forecast" / the item's error text, a full stop
 *                        unless the text already ends in '.', '!' or '?', and "Check your internet
 *                        connection; the app tries again automatically." (separated by one space)
 *      offline (neither loading nor an error): "You are offline" /
 *                        "The forecast loads when the network is back."
 *      otherwise:        "No forecast yet" / "".
 *    The checks run in the order loading, error, offline.
 *  - "wx-detail-spinner" (GtkSpinner, accessible label "Loading"): visible and spinning iff the
 *    item is loading and has no forecast.
 *
 * Forecast page:
 *  - Header: "wx-detail-place" (wx_place_label() of the item's place).
 *  - Badges (in the footer row, see below): "wx-detail-badge-offline" ("Offline") and
 *    "wx-detail-badge-stale" ("Stale") (CSS class "wx-badge" besides their name). The offline
 *    badge is visible iff the item is offline, the stale badge iff the item is stale and NOT
 *    offline. Tooltips: offline "No network connection: showing the last forecast"; stale
 *    "The last refresh failed: <error text>" ("The last refresh failed" without error text).
 *  - Now: "wx-detail-icon" (GtkImage, 64 px, wx_icon_name() of the current condition, accessible
 *    label = the condition label), "wx-detail-temp" (wx_format_temp() with unit),
 *    "wx-detail-condition" (wx_condition_label()), "wx-detail-feels" ("Feels like 75°"),
 *    "wx-detail-highlow" ("High 80° · Low 65°" of today, the WxDay whose start_s <= now < the
 *    end of its local day (wx_format_local_day_end()) in the place's zone; hidden when there is
 *    none. The forecast holds no hour before the one preceding its "now", so the numbers of
 *    today cover the hours from the forecast's first hour on; when that is later in the day
 *    than its start (wx_format_day_covered_from() != 0) the label says so: "High 80° · Low
 *    65° (from 2 PM)", the hour label of that first hour in the place's zone) and
 *    "wx-detail-wind" ("Wind 12 mph, gusts 20 mph · Humidity 40%"; the gusts part
 *    only when the gust is finite and not below the wind). Without current conditions (no hour
 *    contains "now") the temperature is the em dash, the condition "Unknown", the icon
 *    wx_icon_name(WX_COND_UNKNOWN, TRUE) and the other numbers em dashes.
 *  - Card "Rain" (a GtkBox with the CSS class "wx-card"): "wx-detail-rain-title" ("Rain",
 *    class "wx-card-title"), "wx-detail-rain-headline" (wx_rain_headline(); "Rain outlook
 *    unavailable" without an outlook: see wx_row_item_get_outlook(), which has none when the
 *    forecast does not cover "now", and none for a dry outlook the forecast does not cover for
 *    48 hours), "wx-detail-rain-detail" (wx_rain_detail(), hidden when
 *    empty) and a row of two WxRainCharts, each under a dim caption: "wx-detail-rain-nowcast"
 *    (view WX_RAIN_CHART_NOWCAST, caption "wx-detail-rain-nowcast-caption" "Next 2 hours"; it
 *    and its caption are visible iff the chart has data, i.e. iff the forecast's nowcast covers
 *    "now") and "wx-detail-rain-chart" (view WX_RAIN_CHART_HOURLY, caption
 *    "wx-detail-rain-chart-caption" "Next 24 hours"; ALWAYS visible, whether or not the forecast
 *    has a nowcast: the hourly chance bars of the next 24 hours). The two share the row's width
 *    equally while both are visible, the hourly chart has all of it otherwise. Both are fed with
 *    wx_rain_chart_set_forecast().
 *  - Card "Clouds" (class "wx-card"): "wx-detail-cloud-title" ("Clouds", class
 *    "wx-card-title"), "wx-detail-cloud-cover" ("Cloud cover 40% · Partly cloudy",
 *    wx_format_percent() and wx_cloud_label() of the current cloud cover) and
 *    "wx-detail-cloud-sentence" (wx_cloud_sentence()).
 *  - Sections "Next 48 hours" ("wx-detail-hours-title", class "wx-section-title") with the
 *    WxHourStrip "wx-detail-hours" and "Next days" ("wx-detail-days-title", same class) with the
 *    WxDayList "wx-detail-days", both fed from the item's forecast, units and "now".
 *  - Footer: one row with "wx-detail-footer" (a wrapping label reading "Updated 5 min ago ·
 *    Sources: A, B, C": wx_format_updated() of "now" minus the fetch time, an age that does
 *    not fit a gint64 is clamped, a negative one reads "Updated just now", then " · Sources: "
 *    and the list described below), "wx-detail-refreshing" (GtkSpinner, accessible label
 *    "Refreshing": visible and spinning iff the item is loading) and the two badges; below it
 *    "wx-detail-attribution" and "wx-detail-partial".
 *    The source list is "A, B, C": the names of the forecast's sources whose state is WX_SRC_OK,
 *    in forecast order (a source without a name is listed by its provider id), "none" when
 *    there is no such source. "wx-detail-attribution" is a markup
 *    label: one entry per WX_SRC_OK source whose attribution text is not empty, separated by
 *    " · "; the entry is a link (a href) when the source's attribution URL starts with
 *    "https://", has something after it, is at most WX_SOURCE_URL_MAX bytes, is valid UTF-8 and
 *    contains no byte <= 0x20, no 0x7f and none of '<', '>', '"'; otherwise the plain text. The
 *    label is hidden when it has no entry. "wx-detail-partial" reads "Not available right now:
 *    X, Y" with the names of the WX_SRC_FAILED sources in forecast order and is hidden when
 *    none failed (the forecast is fine, only some providers failed). Source names and
 *    attribution texts are untrusted: they are passed through wx_sanitize_text() and, in the
 *    markup, g_markup_escape_text(); hostile data never produces a markup error, a warning or
 *    a critical.
 *
 * Compare before set: a refresh whose result equals what is shown changes no widget property
 * (labels, icon, tooltips, visibility, spinners, the three chart widgets and the cached
 * attribution markup are compared first).
 *
 * Accessibility: the card and section titles have the accessible role heading, all text
 * widgets are plain labels (not selectable). The image has the accessible label of its condition
 * ("Partly cloudy", "Unknown" without current conditions, ...), the placeholder spinner "Loading"
 * and the refresh spinner "Refreshing" (all tested with GTK's test accessibility backend).
 *
 * Lifecycle: the pane holds its own reference on the item, disconnects from the previous item
 * when another one is set and in dispose(); after g_object_run_dispose() every function of this
 * header is a harmless no-op. Main thread only, like every GtkWidget.
 */
#ifndef WX_DETAIL_H
#define WX_DETAIL_H

#include <gtk/gtk.h>

#include "wx-row.h"

G_BEGIN_DECLS

/*
 * G_DECLARE_FINAL_TYPE() below declares the types WxDetail and WxDetailClass,
 * wx_detail_get_type(), the inline cast function WX_DETAIL(), the inline type check
 * WX_IS_DETAIL() and the g_autoptr() cleanup for WxDetail. WX_TYPE_DETAIL is defined here; the
 * type itself is defined by G_DEFINE_FINAL_TYPE() in wx-detail.c.
 */
#define WX_TYPE_DETAIL (wx_detail_get_type())
G_DECLARE_FINAL_TYPE(WxDetail, wx_detail, WX, DETAIL, GtkBox)

/**
 * wx_detail_new:
 *
 * Creates a pane without an item: the placeholder page shows "Select a place".
 *
 * Preconditions:
 *  - GTK is initialised (a display is available); main thread.
 * Postconditions:
 *  - a floating pane showing the placeholder, following no item.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the floating reference.
 *
 * Returns: (transfer floating): a new pane.
 */
GtkWidget *wx_detail_new(void);

/**
 * wx_detail_set_item:
 * @self: (not nullable): the pane.
 * @item: (nullable): the item to show, NULL for none (placeholder "Select a place").
 *
 * Shows @item and follows its "changed" signal (every emission re-reads the item). The previous
 * item, if any, is disconnected and released. Setting the item that is already shown only
 * refreshes the pane.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_DETAIL() and @item is NULL or satisfies WX_IS_ROW_ITEM() (otherwise
 *    critical, nothing happens).
 * Postconditions:
 *  - the pane holds one reference on @item (none for NULL) and shows its current data. After
 *    g_object_run_dispose() of the pane nothing happens (no critical either).
 * Thread affinity: main thread only.
 * Ownership: @item stays with the caller; the pane takes its own reference.
 */
void wx_detail_set_item(WxDetail *self, WxRowItem *item);

G_END_DECLS

#endif /* WX_DETAIL_H */
