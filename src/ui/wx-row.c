/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-row.c - WxRowItem (the per-place model), WxRow (its list row) and the rain hint. */
#include "wx-row.h"

#include <math.h>
#include <string.h>

#include "wx-condition.h"
#include "wx-format.h"
#include "wx-icons.h"
#include "wx-rain.h"
#include "wx-text.h"

/* A rain that starts less than this many minutes ahead is announced as "Rain in N min". */
#define HINT_SOON_MINUTES 90

/* ------------------------------------------------------------------------ */
/* Rain hint                                                                */
/* ------------------------------------------------------------------------ */

/**
 * time_valid:
 * @t_s: a time, UTC unix seconds.
 *
 * Checks that a stamp is a plausible time.
 *
 * Preconditions:
 *  - none (any gint64).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @t_s is in [WX_TIME_MIN_S, WX_TIME_MAX_S).
 */
static gboolean
time_valid(gint64 t_s)
{
  return t_s >= WX_TIME_MIN_S && t_s < WX_TIME_MAX_S;
}

/**
 * hint_at:
 * @start_s: a valid start time of the rain.
 * @now_s: the current time, valid.
 * @tz: (nullable): the place's zone name.
 *
 * "Rain at 4 PM", "Rain tomorrow, 4 PM" or "Rain Friday, 4 PM": the clock time of @start_s, with
 * the day word of wx_format_weekday() when it is not today.
 *
 * Preconditions:
 *  - @start_s and @now_s are in [WX_TIME_MIN_S, WX_TIME_MAX_S).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the hint.
 */
static char *
hint_at(gint64 start_s, gint64 now_s, const char *tz)
{
  g_autofree char *clock = wx_format_hour_label(start_s, tz);
  g_autofree char *day = wx_format_weekday(start_s, tz, now_s);
  if (g_strcmp0(day, "Today") == 0)
    return g_strdup_printf("Rain at %s", clock);
  if (g_strcmp0(day, "Tomorrow") == 0)
    return g_strdup_printf("Rain tomorrow, %s", clock);
  return g_strdup_printf("Rain %s, %s", day, clock);
}

/* Documented in wx-row.h. */
char *
wx_row_rain_hint(const WxRainOutlook *outlook, gint64 now_s, const char *tz)
{
  g_return_val_if_fail(outlook != NULL, NULL);
  g_return_val_if_fail(outlook->state == WX_RAIN_DRY || outlook->state == WX_RAIN_NOW ||
                           outlook->state == WX_RAIN_EXPECTED || outlook->state == WX_RAIN_POSSIBLE,
                       NULL);
  if (outlook->state == WX_RAIN_DRY)
    return g_strdup("Dry for 48 h");
  if (!time_valid(now_s))
    return g_strdup("");

  switch (outlook->state) {
  case WX_RAIN_NOW:
    if (outlook->ends_known && time_valid(outlook->end_s) && outlook->end_s > now_s) {
      g_autofree char *clock = wx_format_clock(outlook->end_s, tz);
      return g_strdup_printf("Raining until %s", clock);
    }
    return g_strdup("Raining now");
  case WX_RAIN_EXPECTED: {
    if (!time_valid(outlook->start_s))
      return g_strdup("Rain expected");
    if (outlook->start_s <= now_s)
      return g_strdup("Rain starting now");
    gint64 ahead_s = outlook->start_s - now_s; /* both valid: no overflow */
    if (ahead_s < (gint64)HINT_SOON_MINUTES * 60) {
      gint64 minutes = (ahead_s + 59) / 60;
      return g_strdup_printf("Rain in %" G_GINT64_FORMAT " min", minutes);
    }
    return hint_at(outlook->start_s, now_s, tz);
  }
  case WX_RAIN_POSSIBLE:
  case WX_RAIN_DRY:
  default:
    return g_strdup("Showers possible");
  }
}

/* ------------------------------------------------------------------------ */
/* WxRowItem                                                                */
/* ------------------------------------------------------------------------ */

struct _WxRowItem {
  GObject parent_instance;

  WxPlace *place;      /* owned copy */
  char *key;           /* wx_place_key(place) */
  WxForecast *forecast; /* strong, NULL for none */
  gint64 fetched_s;
  gboolean loading;
  gboolean stale;
  gboolean offline;
  WxUnits units;
  gint64 now_s;
  char *error;         /* sanitised, NULL for none */

  WxBlendHour current; /* valid iff has_current */
  gboolean has_current;
  WxRainOutlook outlook; /* valid iff has_outlook */
  gboolean has_outlook;
};

/*
 * G_DEFINE_FINAL_TYPE() defines wx_row_item_get_type(), the static wx_row_item_parent_class
 * pointer and the static class initialiser that runs wx_row_item_class_init() once;
 * wx_row_item_init() is registered as the instance initialiser.
 */
G_DEFINE_FINAL_TYPE(WxRowItem, wx_row_item, G_TYPE_OBJECT)

static guint item_changed_signal;

/**
 * wx_row_item_finalize:
 * @object: (not nullable): the item being finalized.
 *
 * GObject finalize: frees the place, key, forecast reference and error text, then chains up.
 *
 * Preconditions:
 *  - called once by GObject after the last reference is dropped.
 * Postconditions:
 *  - everything the item owns is released.
 * Thread affinity: main thread only.
 * Ownership: the item's own members are released.
 */
static void
wx_row_item_finalize(GObject *object)
{
  WxRowItem *self = WX_ROW_ITEM(object);
  wx_place_free(self->place);
  g_free(self->key);
  g_clear_pointer(&self->forecast, wx_forecast_unref);
  g_free(self->error);
  G_OBJECT_CLASS(wx_row_item_parent_class)->finalize(object);
}

/**
 * wx_row_item_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * Installs finalize() and registers the "changed" signal (no arguments, G_SIGNAL_RUN_LAST).
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - item_changed_signal holds the signal id.
 * Thread affinity: the thread that first uses the type.
 * Ownership: the class is owned by GType.
 */
static void
wx_row_item_class_init(WxRowItemClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_row_item_finalize;
  item_changed_signal = g_signal_new("changed", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0,
                                     NULL, NULL, NULL, G_TYPE_NONE, 0);
}

/**
 * wx_row_item_init:
 * @self: (not nullable): the new instance (zero-filled by GObject).
 *
 * Sets the defaults: imperial units, online, "now" = the current time.
 *
 * Preconditions:
 *  - called once by GObject for a new instance.
 * Postconditions:
 *  - units are imperial and now_s is the current time; everything else is empty.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
wx_row_item_init(WxRowItem *self)
{
  self->units = WX_UNITS_IMPERIAL;
  self->now_s = g_get_real_time() / G_USEC_PER_SEC;
}

/**
 * covers_dry_claim:
 * @forecast: (not nullable): a forecast built by wx_forecast_new().
 * @now_s: a valid time.
 *
 * Tells whether the forecast knows the precipitation of the whole outlook horizon: starting with
 * the hour that contains @now_s, hour after hour without a gap, every hour has a finite amount,
 * up to @now_s + WX_RAIN_HORIZON_S. Only then may "dry" be claimed for that long, because
 * wx_rain_outlook() treats a missing hour or amount as dry.
 *
 * Preconditions:
 *  - the hours are ascending multiples of 3600 (wx_forecast_new()).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff the amounts of [@now_s, @now_s + WX_RAIN_HORIZON_S) are all known (FALSE
 *   when no hour contains @now_s).
 */
static gboolean
covers_dry_claim(const WxForecast *forecast, gint64 now_s)
{
  gint64 until_s = 0; /* the end of what is known so far; 0 until the hour of now_s is found */
  for (guint i = 0; i < forecast->n_hours; i++) {
    const WxBlendHour *h = &forecast->hours[i];
    if (until_s == 0) {
      if (!(h->t_s <= now_s && now_s - h->t_s < 3600))
        continue;
      until_s = h->t_s;
    }
    if (h->t_s != until_s || !isfinite(h->precip_mm))
      break;
    until_s += 3600;
  }
  return until_s != 0 && until_s - now_s >= WX_RAIN_HORIZON_S;
}

/**
 * item_recompute:
 * @self: (not nullable): the item.
 *
 * Recomputes the current conditions and the rain outlook from the forecast at the item's "now".
 * The rain outlook is only claimed as far as the forecast covers: not at all when no hour
 * contains "now" (a stale forecast), and "dry" only when the amounts of the next
 * WX_RAIN_HORIZON_S seconds are all known (covers_dry_claim()); a rain that is expected or
 * possible is a claim about data that exists and stays.
 *
 * Preconditions:
 *  - @self is a valid item; its forecast, when set, was built by wx_forecast_new() (so it is a
 *    usable forecast in the sense of wx_rain_outlook()).
 * Postconditions:
 *  - has_current / current describe the forecast at now_s (both empty without a forecast or when
 *    no hour contains now_s); has_outlook / outlook hold the outlook iff has_current, now_s is in
 *    the valid time range and the outlook is not a DRY one that the forecast does not cover.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
item_recompute(WxRowItem *self)
{
  self->has_current = FALSE;
  self->has_outlook = FALSE;
  if (self->forecast == NULL)
    return;
  self->has_current = wx_forecast_now(self->forecast, self->now_s, &self->current);
  if (!self->has_current || !time_valid(self->now_s))
    return;
  wx_rain_outlook(self->forecast, self->now_s, &self->outlook);
  self->has_outlook = self->outlook.state != WX_RAIN_DRY ||
                      covers_dry_claim(self->forecast, self->now_s);
}

/**
 * item_emit_changed:
 * @self: (not nullable): the item.
 *
 * Emits "changed" while holding a temporary reference, so a handler that drops the last other
 * reference cannot free the item under the emission.
 *
 * Preconditions:
 *  - @self is a valid item.
 * Postconditions:
 *  - "changed" was emitted once.
 * Thread affinity: main thread only.
 * Ownership: the temporary reference is released before returning.
 */
static void
item_emit_changed(WxRowItem *self)
{
  g_autoptr(WxRowItem) keep = g_object_ref(self);
  g_signal_emit(keep, item_changed_signal, 0);
}

/* Documented in wx-row.h. */
WxRowItem *
wx_row_item_new(const WxPlace *place)
{
  g_return_val_if_fail(place != NULL, NULL);
  WxPlace *copy = wx_place_copy(place);
  if (copy == NULL)
    return NULL;
  WxRowItem *self = g_object_new(WX_TYPE_ROW_ITEM, NULL);
  self->place = copy;
  self->key = wx_place_key(copy);
  return self;
}

/* Documented in wx-row.h. */
const WxPlace *
wx_row_item_get_place(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), NULL);
  return self->place;
}

/* Documented in wx-row.h. */
const char *
wx_row_item_get_key(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), NULL);
  return self->key;
}

/* Documented in wx-row.h. */
WxForecast *
wx_row_item_get_forecast(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), NULL);
  return self->forecast;
}

/* Documented in wx-row.h. */
gint64
wx_row_item_get_fetched_s(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), 0);
  return self->fetched_s;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_get_loading(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  return self->loading;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_get_stale(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  return self->stale;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_get_offline(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  return self->offline;
}

/* Documented in wx-row.h. */
WxUnits
wx_row_item_get_units(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), WX_UNITS_IMPERIAL);
  return self->units;
}

/* Documented in wx-row.h. */
gint64
wx_row_item_get_now_s(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), 0);
  return self->now_s;
}

/* Documented in wx-row.h. */
const char *
wx_row_item_get_error(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), NULL);
  return self->error;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_get_current(WxRowItem *self, WxBlendHour *out)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  g_return_val_if_fail(out != NULL, FALSE);
  if (!self->has_current)
    return FALSE;
  *out = self->current;
  return TRUE;
}

/* Documented in wx-row.h. */
const WxRainOutlook *
wx_row_item_get_outlook(WxRowItem *self)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), NULL);
  return self->has_outlook ? &self->outlook : NULL;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_forecast(WxRowItem *self, WxForecast *forecast, gint64 fetched_s)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  gint64 stored = forecast != NULL ? fetched_s : 0;
  if (self->forecast == forecast && self->fetched_s == stored)
    return FALSE;
  WxForecast *ref = forecast != NULL ? wx_forecast_ref(forecast) : NULL;
  WxForecast *old = self->forecast;
  self->forecast = ref;
  self->fetched_s = stored;
  item_recompute(self);
  if (old != NULL)
    wx_forecast_unref(old);
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_loading(WxRowItem *self, gboolean loading)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  loading = !!loading;
  if (self->loading == loading)
    return FALSE;
  self->loading = loading;
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_stale(WxRowItem *self, gboolean stale)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  stale = !!stale;
  if (self->stale == stale)
    return FALSE;
  self->stale = stale;
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_offline(WxRowItem *self, gboolean offline)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  offline = !!offline;
  if (self->offline == offline)
    return FALSE;
  self->offline = offline;
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_units(WxRowItem *self, WxUnits units)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  g_return_val_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC, FALSE);
  if (self->units == units)
    return FALSE;
  self->units = units;
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_now_s(WxRowItem *self, gint64 now_s)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  if (self->now_s == now_s)
    return FALSE;
  self->now_s = now_s;
  item_recompute(self);
  item_emit_changed(self);
  return TRUE;
}

/* Documented in wx-row.h. */
gboolean
wx_row_item_set_error(WxRowItem *self, const char *message)
{
  g_return_val_if_fail(WX_IS_ROW_ITEM(self), FALSE);
  g_autofree char *clean = message != NULL ? wx_sanitize_text(message, WX_ROW_ERROR_MAX_BYTES) : NULL;
  if (clean != NULL && clean[0] == '\0')
    g_clear_pointer(&clean, g_free);
  if (g_strcmp0(clean, self->error) == 0)
    return FALSE;
  g_free(self->error);
  self->error = g_steal_pointer(&clean);
  item_emit_changed(self);
  return TRUE;
}

/* ------------------------------------------------------------------------ */
/* WxRow                                                                    */
/* ------------------------------------------------------------------------ */

struct _WxRow {
  GtkBox parent_instance;

  GtkWidget *icon;
  GtkWidget *name_label;
  GtkWidget *region_label;
  GtkWidget *hint_label;
  GtkWidget *temp_label;
  GtkWidget *marker_label;
  GtkWidget *menu_button;

  WxRowItem *item; /* strong while bound */
  gulong changed_id;
};

/*
 * G_DEFINE_FINAL_TYPE() defines wx_row_get_type(), the static wx_row_parent_class pointer and
 * the static class initialiser that runs wx_row_class_init() once; wx_row_init() is registered
 * as the instance initialiser.
 */
G_DEFINE_FINAL_TYPE(WxRow, wx_row, GTK_TYPE_BOX)

enum { ROW_REMOVE_REQUESTED, ROW_MOVE_REQUESTED, ROW_REORDER_REQUESTED, N_ROW_SIGNALS };
static guint row_signals[N_ROW_SIGNALS];

/**
 * set_class:
 * @widget: (not nullable): a widget.
 * @css_class: (not nullable): a style class.
 * @on: whether the widget has the class afterwards.
 *
 * Adds or removes a style class (GTK ignores an add of a class the widget already has and a
 * removal of one it does not have, so no state is compared here).
 *
 * Preconditions:
 *  - @widget is a GtkWidget; @css_class is NUL-terminated.
 * Postconditions:
 *  - the widget has the class iff @on.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
set_class(GtkWidget *widget, const char *css_class, gboolean on)
{
  if (on)
    gtk_widget_add_css_class(widget, css_class);
  else
    gtk_widget_remove_css_class(widget, css_class);
}

/**
 * region_text:
 * @place: (not nullable): a place.
 *
 * Builds the small second line of a row: "Florida, United States", the parts that are not empty.
 *
 * Preconditions:
 *  - @place has non-NULL strings (every WxPlace made by wx_place_new() has).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the text, possibly "".
 */
static char *
region_text(const WxPlace *place)
{
  if (place->admin1[0] != '\0' && place->country[0] != '\0')
    return g_strconcat(place->admin1, ", ", place->country, NULL);
  return g_strdup(place->admin1[0] != '\0' ? place->admin1 : place->country);
}

/**
 * hint_text:
 * @item: (not nullable): the bound item.
 *
 * The one-line hint of the item: the rain hint when there is an outlook, otherwise what the item
 * is doing ("Loading\u2026", "Can't load forecast", "Offline", "No data yet").
 *
 * Preconditions:
 *  - @item is a valid item.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the text.
 */
static char *
hint_text(WxRowItem *item)
{
  const WxRainOutlook *outlook = wx_row_item_get_outlook(item);
  if (outlook != NULL)
    return wx_row_rain_hint(outlook, wx_row_item_get_now_s(item), wx_row_item_get_place(item)->timezone);
  if (wx_row_item_get_forecast(item) != NULL)
    return g_strdup("No rain data");
  if (wx_row_item_get_loading(item))
    return g_strdup("Loading\xE2\x80\xA6");
  if (wx_row_item_get_error(item) != NULL)
    return g_strdup("Can't load forecast");
  if (wx_row_item_get_offline(item))
    return g_strdup("Offline");
  return g_strdup("No data yet");
}

/**
 * marker_text:
 * @item: (not nullable): the bound item.
 *
 * The marker of the item: "Offline" while the network is unavailable and there is data, "Stale"
 * while the latest refresh failed and there is data, "Updating\u2026" while a refresh is in flight and
 * there is data, otherwise "".
 *
 * Preconditions:
 *  - @item is a valid item.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none; the returned string is static.
 *
 * Returns: (transfer none): the marker text, never NULL.
 */
static const char *
marker_text(WxRowItem *item)
{
  if (wx_row_item_get_forecast(item) == NULL)
    return "";
  if (wx_row_item_get_offline(item))
    return "Offline";
  if (wx_row_item_get_stale(item))
    return "Stale";
  if (wx_row_item_get_loading(item))
    return "Updating\xE2\x80\xA6";
  return "";
}

/**
 * refresh:
 * @self: (not nullable): the row.
 *
 * Redraws the whole row from the bound item (blank when none): icon, name, region, temperature,
 * rain hint, marker and the "dim" / "empty" classes. Also the callback of the item's "changed"
 * signal (connected with g_signal_connect_swapped(), so the row is its first argument).
 *
 * Preconditions:
 *  - @self is a constructed WxRow; @self->item is NULL or a live WxRowItem (strongly held) that
 *    has a place (every item made by wx_row_item_new() has; an item without one logs a critical
 *    and the row keeps what it shows).
 * Postconditions:
 *  - the widgets reflect the item's current data; a missing temperature shows an em dash. The
 *    item is not modified.
 * Thread affinity: main thread only.
 * Ownership: none transferred; all strings are freed locally.
 */
static void
refresh(WxRow *self)
{
  GtkWidget *box = GTK_WIDGET(self);
  if (self->item == NULL) {
    gtk_label_set_text(GTK_LABEL(self->name_label), "");
    gtk_label_set_text(GTK_LABEL(self->region_label), "");
    gtk_label_set_text(GTK_LABEL(self->hint_label), "");
    gtk_label_set_text(GTK_LABEL(self->temp_label), "");
    gtk_label_set_text(GTK_LABEL(self->marker_label), "");
    gtk_widget_set_visible(self->marker_label, FALSE);
    gtk_image_set_from_icon_name(GTK_IMAGE(self->icon), NULL);
    set_class(box, "dim", FALSE);
    set_class(box, "empty", FALSE);
    gtk_widget_set_tooltip_text(box, NULL);
    return;
  }

  WxRowItem *item = self->item;
  const WxPlace *place = wx_row_item_get_place(item);
  g_return_if_fail(place != NULL);
  WxBlendHour current;
  gboolean has_current = wx_row_item_get_current(item, &current);

  g_autofree char *region = region_text(place);
  g_autofree char *temp = wx_format_temp(has_current ? current.temp_c : NAN, wx_row_item_get_units(item), FALSE);
  g_autofree char *hint = hint_text(item);
  const char *marker = marker_text(item);
  const char *icon = wx_icon_name(has_current ? current.condition : WX_COND_UNKNOWN,
                                  has_current ? current.is_day : TRUE);

  gtk_label_set_text(GTK_LABEL(self->name_label), place->name);
  gtk_label_set_text(GTK_LABEL(self->region_label), region);
  gtk_widget_set_visible(self->region_label, region[0] != '\0');
  gtk_label_set_text(GTK_LABEL(self->temp_label), temp);
  gtk_label_set_text(GTK_LABEL(self->hint_label), hint);
  gtk_label_set_text(GTK_LABEL(self->marker_label), marker);
  gtk_widget_set_visible(self->marker_label, marker[0] != '\0');
  if (g_strcmp0(gtk_image_get_icon_name(GTK_IMAGE(self->icon)), icon) != 0)
    gtk_image_set_from_icon_name(GTK_IMAGE(self->icon), icon);

  gboolean dim = wx_row_item_get_forecast(item) != NULL &&
                 (wx_row_item_get_offline(item) || wx_row_item_get_stale(item));
  set_class(box, "dim", dim);
  set_class(box, "empty", wx_row_item_get_forecast(item) == NULL);

  g_autofree char *label = wx_place_label(place);
  g_autofree char *summary = g_strdup_printf("%s: %s, %s%s%s", label, temp, hint,
                                             marker[0] != '\0' ? ", " : "", marker);
  gtk_widget_set_tooltip_text(box, label);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self), GTK_ACCESSIBLE_PROPERTY_LABEL, summary, -1);
}

/* Documented in wx-row.h. */
void
wx_row_bind(WxRow *self, WxRowItem *item)
{
  g_return_if_fail(WX_IS_ROW(self));
  g_return_if_fail(item == NULL || WX_IS_ROW_ITEM(item));
  if (self->item != NULL) {
    g_signal_handler_disconnect(self->item, self->changed_id);
    self->changed_id = 0;
    g_clear_object(&self->item);
  }
  if (item != NULL) {
    self->item = g_object_ref(item);
    self->changed_id = g_signal_connect_swapped(item, "changed", G_CALLBACK(refresh), self);
  }
  refresh(self);
}

/**
 * emit_with_key:
 * @self: (not nullable): the row.
 * @signal_id: the id of "remove-requested" or "move-requested" (row_signals[]).
 * @delta: the second signal argument; only used when @has_delta is TRUE.
 * @has_delta: TRUE for "move-requested" (arguments key, delta), FALSE for "remove-requested"
 *   (argument key).
 *
 * Emits the signal with the bound item's place key.
 *
 * Preconditions:
 *  - @self is a constructed WxRow; @signal_id and @has_delta agree on the signal's arity.
 * Postconditions:
 *  - nothing happens when the row is unbound. Otherwise the signal was emitted with a private
 *    copy of the key, while the row was kept alive by a temporary reference, so a handler that
 *    unbinds, disposes or destroys the row cannot invalidate the arguments.
 * Thread affinity: main thread only.
 * Ownership: the key copy and the temporary reference are released before returning.
 */
static void
emit_with_key(WxRow *self, guint signal_id, int delta, gboolean has_delta)
{
  if (self->item == NULL)
    return;
  g_autoptr(WxRow) keep = g_object_ref(self);
  g_autofree char *key = g_strdup(wx_row_item_get_key(self->item));
  if (has_delta)
    g_signal_emit(keep, signal_id, 0, key, delta);
  else
    g_signal_emit(keep, signal_id, 0, key);
}

/**
 * on_remove:
 * @action: the activated "row.remove" action (unused).
 * @parameter: (nullable): the activation parameter (unused; the action has none).
 * @user_data: (not nullable): the WxRow, passed by g_signal_connect_object() in wx_row_init().
 *
 * "activate" handler of the "remove" action: emits "remove-requested".
 *
 * Preconditions:
 *  - @user_data is a WxRow (it was connected with the row as the object).
 * Postconditions:
 *  - "remove-requested" was emitted with the bound item's key; nothing when unbound.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_remove(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  emit_with_key(WX_ROW(user_data), row_signals[ROW_REMOVE_REQUESTED], 0, FALSE);
}

/**
 * on_move_up:
 * @action: the activated "row.move-up" action (unused).
 * @parameter: (nullable): the activation parameter (unused).
 * @user_data: (not nullable): the WxRow, see on_remove().
 *
 * "activate" handler of the "move-up" action: emits "move-requested" with delta -1.
 *
 * Preconditions:
 *  - @user_data is a WxRow.
 * Postconditions:
 *  - "move-requested" was emitted with the bound item's key and -1; nothing when unbound.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_move_up(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  emit_with_key(WX_ROW(user_data), row_signals[ROW_MOVE_REQUESTED], -1, TRUE);
}

/**
 * on_move_down:
 * @action: the activated "row.move-down" action (unused).
 * @parameter: (nullable): the activation parameter (unused).
 * @user_data: (not nullable): the WxRow, see on_remove().
 *
 * "activate" handler of the "move-down" action: emits "move-requested" with delta +1.
 *
 * Preconditions:
 *  - @user_data is a WxRow.
 * Postconditions:
 *  - "move-requested" was emitted with the bound item's key and +1; nothing when unbound.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_move_down(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  emit_with_key(WX_ROW(user_data), row_signals[ROW_MOVE_REQUESTED], 1, TRUE);
}

/**
 * row_menu:
 *
 * Returns the menu model shared by all rows ("Move up", "Move down", "Remove"), created on first
 * use. The GMenu is created once per process and intentionally never freed (every menu button
 * takes its own reference). g_once_init_enter() makes the creation safe even from two threads.
 *
 * Preconditions:
 *  - GLib only; the caller is the main thread (create_popup()).
 * Postconditions:
 *  - the menu exists and is unchanged afterwards.
 * Thread affinity: main thread only.
 * Ownership: the model is owned by this function's static; the caller must not free it.
 *
 * Returns: (transfer none): the shared menu model, never NULL.
 */
static GMenuModel *
row_menu(void)
{
  static gsize once = 0;
  static GMenu *menu;
  if (g_once_init_enter(&once)) {
    menu = g_menu_new();
    g_menu_append(menu, "Move up", "row.move-up");
    g_menu_append(menu, "Move down", "row.move-down");
    g_menu_append(menu, "Remove", "row.remove");
    g_once_init_leave(&once, 1);
  }
  return G_MENU_MODEL(menu);
}

/**
 * create_popup:
 * @button: the row's menu button.
 * @user_data: unused (NULL: no data was registered).
 *
 * GtkMenuButtonCreatePopupFunc: the popover (and its widgets) is only built when the menu is
 * first opened, by giving the button its menu model.
 *
 * Preconditions:
 *  - @button is a GtkMenuButton.
 * Postconditions:
 *  - @button has a menu model (row_menu()) afterwards; an existing one is kept.
 * Thread affinity: main thread only.
 * Ownership: @button is borrowed; the button takes its own reference on the shared menu.
 */
static void
create_popup(GtkMenuButton *button, gpointer user_data)
{
  (void)user_data;
  if (gtk_menu_button_get_menu_model(button) == NULL)
    gtk_menu_button_set_menu_model(button, row_menu());
}

/**
 * on_drag_prepare:
 * @source: the drag source (unused).
 * @x: pointer x (unused).
 * @y: pointer y (unused).
 * @user_data: (not nullable): the WxRow, passed by g_signal_connect_object().
 *
 * GtkDragSource "prepare" handler: the dragged payload is the bound item's place key as text.
 *
 * Preconditions:
 *  - @user_data is a WxRow.
 * Postconditions:
 *  - no state is changed; the provider holds its own copy of the key.
 * Thread affinity: main thread only.
 * Ownership: the returned provider is owned by the caller (GTK); the key is copied.
 *
 * Returns: (transfer full) (nullable): a G_TYPE_STRING content provider, or NULL (no drag) when
 *   the row is unbound.
 */
static GdkContentProvider *
on_drag_prepare(GtkDragSource *source, double x, double y, gpointer user_data)
{
  (void)source;
  (void)x;
  (void)y;
  WxRow *self = WX_ROW(user_data);
  if (self->item == NULL)
    return NULL;
  return gdk_content_provider_new_typed(G_TYPE_STRING, wx_row_item_get_key(self->item));
}

/**
 * on_drag_begin:
 * @source: the drag source.
 * @drag: the new drag (unused).
 * @user_data: (not nullable): the WxRow, passed by g_signal_connect_object().
 *
 * GtkDragSource "drag-begin" handler: uses a snapshot of the row as the drag icon.
 *
 * Preconditions:
 *  - @user_data is a WxRow (a GtkWidget).
 * Postconditions:
 *  - @source has the row's paintable as its icon (hotspot 0, 0); the local reference on the
 *    paintable is released.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_drag_begin(GtkDragSource *source, GdkDrag *drag, gpointer user_data)
{
  (void)drag;
  g_autoptr(GdkPaintable) icon = gtk_widget_paintable_new(GTK_WIDGET(user_data));
  gtk_drag_source_set_icon(source, icon, 0, 0);
}

/**
 * on_drop:
 * @target: the drop target (unused).
 * @value: the dropped value; the target only accepts G_TYPE_STRING.
 * @x: drop x (unused).
 * @y: drop y (unused).
 * @user_data: (not nullable): the WxRow, passed by g_signal_connect_object().
 *
 * GtkDropTarget "drop" handler: asks the owner to move the dropped place to this row's position
 * by emitting "reorder-requested". The payload may come from another application, so it is
 * UNTRUSTED text: it is only copied here and handed on; the receiver validates it.
 *
 * Preconditions:
 *  - @user_data is a WxRow; @value is a valid, initialised GValue.
 * Postconditions:
 *  - when the row is bound and @value holds a non-NULL string, "reorder-requested" was emitted
 *    with a copy of that string and the bound key, and TRUE is returned; otherwise nothing
 *    happens and FALSE is returned. Row and copies stay alive while the handlers run.
 * Thread affinity: main thread only.
 * Ownership: @value is borrowed for the call; the copies are freed before returning.
 *
 * Returns: TRUE if the drop was accepted (signal emitted), FALSE otherwise.
 */
static gboolean
on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer user_data)
{
  (void)target;
  (void)x;
  (void)y;
  WxRow *self = WX_ROW(user_data);
  if (self->item == NULL || !G_VALUE_HOLDS_STRING(value))
    return FALSE;
  const char *source = g_value_get_string(value);
  if (source == NULL)
    return FALSE;
  g_autoptr(WxRow) keep = g_object_ref(self);
  g_autofree char *src = g_strdup(source);
  g_autofree char *dst = g_strdup(wx_row_item_get_key(self->item));
  g_signal_emit(keep, row_signals[ROW_REORDER_REQUESTED], 0, src, dst);
  return TRUE;
}

/**
 * wx_row_dispose:
 * @object: the row being disposed.
 *
 * GObject dispose vfunc: disconnects from the bound item and drops the reference on it, then
 * chains up. May run more than once.
 *
 * Preconditions:
 *  - @object is a WxRow; called by GObject (possibly repeatedly).
 * Postconditions:
 *  - the row is unbound (no handler of the item points at it any more); the parent dispose ran.
 * Thread affinity: main thread only.
 * Ownership: the item reference held by the row is released.
 */
static void
wx_row_dispose(GObject *object)
{
  WxRow *self = WX_ROW(object);
  if (self->item != NULL) {
    g_signal_handler_disconnect(self->item, self->changed_id);
    self->changed_id = 0;
    g_clear_object(&self->item);
  }
  G_OBJECT_CLASS(wx_row_parent_class)->dispose(object);
}

/**
 * wx_row_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * Installs dispose() and registers the signals "remove-requested" (string), "move-requested"
 * (string, int) and "reorder-requested" (string, string), all G_SIGNAL_RUN_LAST.
 *
 * Preconditions:
 *  - called once by GObject while the type is registered.
 * Postconditions:
 *  - row_signals[] holds the three signal ids.
 * Thread affinity: the thread that first uses the type.
 * Ownership: the class is owned by GObject.
 */
static void
wx_row_class_init(WxRowClass *klass)
{
  GObjectClass *oc = G_OBJECT_CLASS(klass);
  oc->dispose = wx_row_dispose;
  row_signals[ROW_REMOVE_REQUESTED] =
      g_signal_new("remove-requested", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                   NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
  row_signals[ROW_MOVE_REQUESTED] =
      g_signal_new("move-requested", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                   NULL, G_TYPE_NONE, 2, G_TYPE_STRING, G_TYPE_INT);
  row_signals[ROW_REORDER_REQUESTED] =
      g_signal_new("reorder-requested", G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL,
                   NULL, NULL, G_TYPE_NONE, 2, G_TYPE_STRING, G_TYPE_STRING);
}

/**
 * make_label:
 * @name: (not nullable): widget name and style class of the label.
 * @xalign: horizontal alignment, 0.0 (left) .. 1.0 (right).
 *
 * Creates a single-line label that ellipsizes at the end.
 *
 * Preconditions:
 *  - GTK is initialised; @name is NUL-terminated; @xalign is in 0.0 .. 1.0.
 * Postconditions:
 *  - a new floating label is returned.
 * Thread affinity: main thread only.
 * Ownership: @name is borrowed (GTK copies it).
 *
 * Returns: (transfer floating): the new label.
 */
static GtkWidget *
make_label(const char *name, float xalign)
{
  GtkWidget *label = gtk_label_new(NULL);
  gtk_label_set_xalign(GTK_LABEL(label), xalign);
  gtk_label_set_single_line_mode(GTK_LABEL(label), TRUE);
  gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
  gtk_widget_set_name(label, name);
  gtk_widget_add_css_class(label, name);
  return label;
}

/**
 * wx_row_init:
 * @self: (not nullable): the new row (zero-filled by GObject).
 *
 * GObject instance initialiser: builds the child widgets (icon, name / region / hint, temperature
 * / marker, menu button), the "row" action group (remove, move-up, move-down) and the drag source
 * and drop target. The action and controller handlers are connected with
 * g_signal_connect_object() and the row as the object, so they never outlive it. The row starts
 * unbound.
 *
 * Preconditions:
 *  - called once by GObject for a new instance; GTK is initialised.
 * Postconditions:
 *  - all child pointers of @self are set, item is NULL; the widget owns the children, the action
 *    group and the controllers.
 * Thread affinity: main thread only.
 * Ownership: @self is owned by GObject; local references on the action group and actions are
 *   released after they were handed to the widget / the group.
 */
static void
wx_row_init(WxRow *self)
{
  GtkWidget *box = GTK_WIDGET(self);
  gtk_orientable_set_orientation(GTK_ORIENTABLE(self), GTK_ORIENTATION_HORIZONTAL);
  gtk_box_set_spacing(GTK_BOX(self), 12);
  gtk_widget_add_css_class(box, "wx-row");

  self->icon = gtk_image_new();
  gtk_image_set_pixel_size(GTK_IMAGE(self->icon), 32);
  gtk_widget_set_name(self->icon, "wx-row-icon");
  gtk_widget_add_css_class(self->icon, "wx-row-icon");
  gtk_widget_set_valign(self->icon, GTK_ALIGN_CENTER);
  gtk_box_append(GTK_BOX(self), self->icon);

  GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_widget_set_hexpand(names, TRUE);
  gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
  self->name_label = make_label("wx-row-name", 0.0f);
  self->region_label = make_label("wx-row-region", 0.0f);
  self->hint_label = make_label("wx-row-hint", 0.0f);
  gtk_label_set_width_chars(GTK_LABEL(self->name_label), 10);
  gtk_label_set_max_width_chars(GTK_LABEL(self->name_label), 24);
  gtk_label_set_max_width_chars(GTK_LABEL(self->region_label), 28);
  gtk_label_set_max_width_chars(GTK_LABEL(self->hint_label), 28);
  gtk_box_append(GTK_BOX(names), self->name_label);
  gtk_box_append(GTK_BOX(names), self->region_label);
  gtk_box_append(GTK_BOX(names), self->hint_label);
  gtk_box_append(GTK_BOX(self), names);

  GtkWidget *right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_widget_set_valign(right, GTK_ALIGN_CENTER);
  self->temp_label = make_label("wx-row-temp", 1.0f);
  gtk_label_set_width_chars(GTK_LABEL(self->temp_label), 4);
  self->marker_label = make_label("wx-row-marker", 1.0f);
  gtk_widget_set_visible(self->marker_label, FALSE);
  gtk_box_append(GTK_BOX(right), self->temp_label);
  gtk_box_append(GTK_BOX(right), self->marker_label);
  gtk_box_append(GTK_BOX(self), right);

  self->menu_button = gtk_menu_button_new();
  gtk_menu_button_set_child(GTK_MENU_BUTTON(self->menu_button), gtk_label_new("\xe2\x80\xa6"));
  gtk_menu_button_set_create_popup_func(GTK_MENU_BUTTON(self->menu_button), create_popup, NULL,
                                        NULL);
  gtk_widget_set_name(self->menu_button, "wx-row-menu");
  gtk_widget_add_css_class(self->menu_button, "flat");
  gtk_widget_set_valign(self->menu_button, GTK_ALIGN_CENTER);
  gtk_widget_set_tooltip_text(self->menu_button, "Place actions");
  gtk_accessible_update_property(GTK_ACCESSIBLE(self->menu_button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "Place actions", -1);
  gtk_box_append(GTK_BOX(self), self->menu_button);

  GSimpleActionGroup *group = g_simple_action_group_new();
  static const struct {
    const char *name;
    GCallback cb;
  } actions[] = {{"remove", G_CALLBACK(on_remove)},
                 {"move-up", G_CALLBACK(on_move_up)},
                 {"move-down", G_CALLBACK(on_move_down)}};
  for (guint i = 0; i < G_N_ELEMENTS(actions); i++) {
    GSimpleAction *action = g_simple_action_new(actions[i].name, NULL);
    g_signal_connect_object(action, "activate", actions[i].cb, self, 0);
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
    g_object_unref(action);
  }
  gtk_widget_insert_action_group(box, "row", G_ACTION_GROUP(group));
  g_object_unref(group);

  GtkDragSource *drag = gtk_drag_source_new();
  gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE);
  g_signal_connect_object(drag, "prepare", G_CALLBACK(on_drag_prepare), self, 0);
  g_signal_connect_object(drag, "drag-begin", G_CALLBACK(on_drag_begin), self, 0);
  gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(drag));

  GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_STRING, GDK_ACTION_MOVE);
  g_signal_connect_object(drop, "drop", G_CALLBACK(on_drop), self, 0);
  gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(drop));
}

/* Documented in wx-row.h. */
GtkWidget *
wx_row_new(void)
{
  return g_object_new(WX_TYPE_ROW, NULL);
}
