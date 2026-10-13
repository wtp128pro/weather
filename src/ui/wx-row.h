/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-row.h - the per-place model of the place list (WxRowItem), the list row
 * widget that shows it (WxRow) and the one-line rain hint of a row.
 *
 * Threading: WxRowItem and WxRow are main thread only (GObject / GtkWidget).
 * wx_row_rain_hint() keeps no state: any thread.
 *
 * WxRowItem
 * ---------
 * One saved place and everything shown for it: the place, the latest blended
 * forecast (immutable, shared by reference) with the time it was fetched, the
 * state of the refresh (loading / stale / error text), the application's
 * offline state, the unit system and "now". WxApp creates and updates the
 * items; widgets only read them. Every setter compares the new value with
 * the stored one first and returns FALSE, emitting nothing, when nothing
 * changed, so widgets that listen to the item are touched only when data
 * really changed. "now" is the application's clock tick (once a minute while the window is
 * visible and the network is available, and once at every change of either): the current
 * conditions, the rain outlook and every time-dependent text are derived from the forecast and
 * this value, never from the system clock, so a row and the detail pane that show the same
 * item always agree.
 *
 * The derived values (current conditions at "now", rain outlook at "now") are
 * recomputed whenever the forecast or "now" changes; they are plain data
 * (no allocation per query).
 *
 * WxRow
 * -----
 * The widget bound to an item by the list view's factory: weather icon,
 * place name, region, big temperature, one-line rain hint and a marker
 * ("Offline" / "Stale") with the CSS class "wx-row"; a "..." menu button
 * (Move up, Move down, Remove). The row is also a drag source and drop
 * target: dropping another row on it asks to move that row to this row's
 * position. The row never touches the places: it only emits requests that
 * carry place keys; the owner validates them (a drop may originate outside the
 * application) and acts.
 *
 * Widget names (the same as the CSS classes of the labels): "wx-row-icon",
 * "wx-row-name", "wx-row-region", "wx-row-temp", "wx-row-hint",
 * "wx-row-marker" and "wx-row-menu". The row has the CSS class "dim" while
 * its marker is shown (offline or stale data), and the class "empty" while
 * it has no forecast.
 */
#ifndef WX_ROW_H
#define WX_ROW_H

#include <gtk/gtk.h>

#include "wx-blend.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** Longest error text kept by a WxRowItem, in bytes. */
#define WX_ROW_ERROR_MAX_BYTES 200

/**
 * wx_row_rain_hint:
 * @outlook: non-NULL rain outlook (see wx_rain_outlook()).
 * @now_s: the current time, UTC unix seconds.
 * @tz: (nullable): IANA time zone name of the place (the weather time zone rule applies).
 *
 * The one-line hint of a row, shorter than the headline of the detail pane:
 *  - WX_RAIN_NOW: "Raining until 3:30 PM" when the end is known and after
 *    @now_s, otherwise "Raining now";
 *  - WX_RAIN_EXPECTED: "Rain in 25 min" ("Rain in 1 min", rounded up to whole
 *    minutes) when start_s is more than 0 and less than 90 minutes ahead,
 *    "Rain starting now" when start_s is not after @now_s, otherwise "Rain at
 *    4 PM" for a start on the same local day, "Rain tomorrow, 4 PM" or "Rain
 *    Friday, 4 PM" for a later day; "Rain expected" when start_s is not a
 *    valid time;
 *  - WX_RAIN_POSSIBLE: "Showers possible";
 *  - WX_RAIN_DRY: "Dry for 48 h".
 * Except for WX_RAIN_DRY a @now_s outside [WX_TIME_MIN_S, WX_TIME_MAX_S) gives
 * "".
 *
 * Preconditions:
 *  - @outlook is non-NULL and its state is a WxRainState member (otherwise
 *    critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full) (nullable): newly allocated text, possibly empty.
 */
char *wx_row_rain_hint(const WxRainOutlook *outlook, gint64 now_s, const char *tz);

#define WX_TYPE_ROW_ITEM (wx_row_item_get_type())
G_DECLARE_FINAL_TYPE(WxRowItem, wx_row_item, WX, ROW_ITEM, GObject)

/**
 * WxRowItem::changed:
 * @self: the item.
 *
 * Emitted (synchronously) after a setter changed what the item holds.
 */

/**
 * wx_row_item_new:
 * @place: non-NULL place; copied (wx_place_copy()).
 *
 * Creates an item without forecast: not loading, not stale, online, imperial
 * units, "now" = the current time, no error text.
 *
 * Preconditions:
 *  - @place is non-NULL (NULL: critical, NULL returned). A place that
 *    violates the wx_place_new() rules is refused (NULL, no critical).
 * Postconditions:
 *  - the item owns a copy of the place; nothing is emitted.
 * Thread affinity: main thread only.
 * Ownership: @place is borrowed; the caller owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the new item.
 */
WxRowItem *wx_row_item_new(const WxPlace *place);

/**
 * wx_row_item_get_place:
 * @self: an item.
 *
 * The place the item shows.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the place is owned by the item and lives as long as it.
 *
 * Returns: (transfer none): the place.
 */
const WxPlace *wx_row_item_get_place(WxRowItem *self);

/**
 * wx_row_item_get_key:
 * @self: an item.
 *
 * The key (wx_place_key()) of the item's place.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the string is owned by the item (wx_place_key() of its place).
 *
 * Returns: (transfer none): the place key.
 */
const char *wx_row_item_get_key(WxRowItem *self);

/**
 * wx_row_item_get_forecast:
 * @self: an item.
 *
 * The forecast the item holds.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the forecast is owned by the item (no reference added).
 *
 * Returns: (transfer none) (nullable): the forecast, NULL while there is none.
 */
WxForecast *wx_row_item_get_forecast(WxRowItem *self);

/**
 * wx_row_item_get_fetched_s:
 * @self: an item.
 *
 * When the item's forecast was fetched.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, 0).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: when the forecast of the item was fetched (UTC unix seconds; for a
 *   forecast loaded from the cache: now minus its age), 0 without forecast.
 */
gint64 wx_row_item_get_fetched_s(WxRowItem *self);

/**
 * wx_row_item_get_loading:
 * @self: an item.
 *
 * Whether a refresh of the place is in flight.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, FALSE).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE while a refresh request of the place is in flight.
 */
gboolean wx_row_item_get_loading(WxRowItem *self);

/**
 * wx_row_item_get_stale:
 * @self: an item.
 *
 * Whether the latest refresh of the place failed (the data is shown, but not up to date).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, FALSE).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE while the latest refresh of the place failed (the data
 *   shown, if any, is older than it should be).
 */
gboolean wx_row_item_get_stale(WxRowItem *self);

/**
 * wx_row_item_get_offline:
 * @self: an item.
 *
 * Whether the network is unavailable.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, FALSE).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE while the application reports that the network is unavailable.
 */
gboolean wx_row_item_get_offline(WxRowItem *self);

/**
 * wx_row_item_get_units:
 * @self: an item.
 *
 * The unit system the item's texts use.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, WX_UNITS_IMPERIAL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: the unit system the item is shown in (imperial by default).
 */
WxUnits wx_row_item_get_units(WxRowItem *self);

/**
 * wx_row_item_get_now_s:
 * @self: an item.
 *
 * The "now" that the item's time-dependent values are derived from.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, 0).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: the item's "now", UTC unix seconds.
 */
gint64 wx_row_item_get_now_s(WxRowItem *self);

/**
 * wx_row_item_get_error:
 * @self: an item.
 *
 * The sanitised reason of the latest failed refresh.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the string is owned by the item, valid until the next
 *   wx_row_item_set_error().
 *
 * Returns: (transfer none) (nullable): the sanitised reason of the latest failed
 *   refresh, NULL when the latest refresh did not fail (or none ran).
 */
const char *wx_row_item_get_error(WxRowItem *self);

/**
 * wx_row_item_get_current:
 * @self: an item.
 * @out: (out): receives the current conditions.
 *
 * The conditions at the item's "now" (wx_forecast_now(): interpolated
 * instant values, the precipitation and condition of the hour that
 * contains "now").
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() and @out is non-NULL (violation:
 *    critical, FALSE, @out untouched).
 * Postconditions:
 *  - on TRUE *@out is filled; on FALSE (no forecast, or no hour contains
 *    "now") it is untouched. Nothing is allocated and no clock is read.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff current conditions exist.
 */
gboolean wx_row_item_get_current(WxRowItem *self, WxBlendHour *out);

/**
 * wx_row_item_get_outlook:
 * @self: an item.
 *
 * The rain outlook of the forecast at the item's "now" (wx_rain_outlook()).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (NULL: critical, NULL).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the outlook is owned by the item, valid until the next change of
 *   its forecast or "now".
 *
 * Returns: (transfer none) (nullable): the outlook, NULL without forecast,
 *   when "now" is outside [WX_TIME_MIN_S, WX_TIME_MAX_S), when no hour of the
 *   forecast contains "now" (wx_row_item_get_current() is FALSE: a stale
 *   forecast makes no claim about the rain now) and when the outlook is DRY
 *   but the forecast does not know the precipitation of the next 48 hours
 *   (WX_RAIN_HORIZON_S) hour after hour without a gap, an unknown amount
 *   (NAN) counting as unknown: no "dry" is claimed for a time the forecast
 *   does not cover. The row then says "No rain data" and the detail pane
 *   "Rain outlook unavailable". A rain that is raining, expected or possible
 *   is reported whatever the coverage.
 */
const WxRainOutlook *wx_row_item_get_outlook(WxRowItem *self);

/**
 * wx_row_item_set_forecast:
 * @self: an item.
 * @forecast: (nullable): the forecast to show, NULL for none. The item takes
 *   its own reference.
 * @fetched_s: when it was fetched, UTC unix seconds (ignored, 0 stored,
 *   when @forecast is NULL).
 *
 * Gives the item a forecast and the time it was fetched, and recomputes what is derived from them.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE).
 * Postconditions:
 *  - the derived values were recomputed; "changed" was emitted iff the
 *    forecast pointer or @fetched_s differed from the stored ones.
 * Thread affinity: main thread only.
 * Ownership: @forecast stays with the caller; the item holds its own reference.
 *
 * Returns: TRUE iff something changed.
 */
gboolean wx_row_item_set_forecast(WxRowItem *self, WxForecast *forecast, gint64 fetched_s);

/**
 * wx_row_item_set_loading:
 * @self: an item.
 * @loading: whether a refresh of the place is in flight.
 *
 * Sets whether a refresh of the place is in flight.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE).
 * Postconditions:
 *  - "changed" was emitted iff the flag differed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the flag changed.
 */
gboolean wx_row_item_set_loading(WxRowItem *self, gboolean loading);

/**
 * wx_row_item_set_stale:
 * @self: an item.
 * @stale: whether the latest refresh failed.
 *
 * Sets whether the latest refresh of the place failed.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE).
 * Postconditions:
 *  - "changed" was emitted iff the flag differed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the flag changed.
 */
gboolean wx_row_item_set_stale(WxRowItem *self, gboolean stale);

/**
 * wx_row_item_set_offline:
 * @self: an item.
 * @offline: whether the network is unavailable.
 *
 * Sets whether the network is unavailable.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE).
 * Postconditions:
 *  - "changed" was emitted iff the flag differed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the flag changed.
 */
gboolean wx_row_item_set_offline(WxRowItem *self, gboolean offline);

/**
 * wx_row_item_set_units:
 * @self: an item.
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 *
 * Sets the unit system of the item's texts.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() and @units is a WxUnits member
 *    (otherwise critical, FALSE, nothing changes).
 * Postconditions:
 *  - "changed" was emitted iff the unit system differed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the unit system changed.
 */
gboolean wx_row_item_set_units(WxRowItem *self, WxUnits units);

/**
 * wx_row_item_set_now_s:
 * @self: an item.
 * @now_s: the new "now", UTC unix seconds (any value; one outside
 *   [WX_TIME_MIN_S, WX_TIME_MAX_S) leaves the derived values empty).
 *
 * Sets the "now" that the item's time-dependent values are derived from.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE).
 * Postconditions:
 *  - the derived values were recomputed; "changed" was emitted iff @now_s
 *    differed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff "now" changed.
 */
gboolean wx_row_item_set_now_s(WxRowItem *self, gint64 now_s);

/**
 * wx_row_item_set_error:
 * @self: an item.
 * @message: (nullable): reason of a failed refresh, NULL (or text that is empty
 *   after sanitising) for none. Passed through wx_sanitize_text() and cut to
 *   WX_ROW_ERROR_MAX_BYTES; the original is not retained.
 *
 * Sets the reason of the latest failed refresh (sanitised and cut by the item).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW_ITEM() (otherwise critical, FALSE);
 *    @message is NULL or NUL-terminated.
 * Postconditions:
 *  - "changed" was emitted iff the stored text differed.
 * Thread affinity: main thread only.
 * Ownership: @message is borrowed for the call.
 *
 * Returns: TRUE iff the stored text changed.
 */
gboolean wx_row_item_set_error(WxRowItem *self, const char *message);

#define WX_TYPE_ROW (wx_row_get_type())
G_DECLARE_FINAL_TYPE(WxRow, wx_row, WX, ROW, GtkBox)

/**
 * WxRow::remove-requested:
 * @self: the row.
 * @key: the place key of the bound item (a private copy).
 *
 * Emitted when the user chose "Remove" in the row's menu. Not emitted by an
 * unbound row.
 */

/**
 * WxRow::move-requested:
 * @self: the row.
 * @key: the place key of the bound item (a private copy).
 * @delta: -1 ("Move up") or +1 ("Move down").
 *
 * Emitted when the user chose "Move up" / "Move down". Not emitted by an
 * unbound row.
 */

/**
 * WxRow::reorder-requested:
 * @self: the row.
 * @source: UNTRUSTED text carried by a drop (it may come from another
 *   application); a private copy, never interpreted by the row.
 * @target: the place key of the bound item that received the drop.
 *
 * Emitted when something that is a string was dropped on a bound row. The
 * receiver validates @source.
 */

/**
 * wx_row_new:
 *
 * Creates an unbound row.
 *
 * Preconditions:
 *  - GTK is initialised; main thread.
 * Postconditions:
 *  - the row shows nothing; floating reference.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the floating reference.
 *
 * Returns: (transfer floating): a new row.
 */
GtkWidget *wx_row_new(void);

/**
 * wx_row_bind:
 * @self: a row.
 * @item: (nullable): the item to show, NULL to unbind and blank the row.
 *
 * Shows @item and follows its "changed" signal until it is unbound.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_ROW() and @item is NULL or satisfies
 *    WX_IS_ROW_ITEM() (otherwise critical, nothing happens).
 * Postconditions:
 *  - the row holds a reference on @item (the previous one is released) and
 *    shows its current data.
 * Thread affinity: main thread only.
 * Ownership: @item stays with the caller; the row takes its own reference.
 */
void wx_row_bind(WxRow *self, WxRowItem *item);

G_END_DECLS

#endif /* WX_ROW_H */
