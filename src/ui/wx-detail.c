/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-detail.c - WxDetail: the detail pane (everything about the selected place). */
#include "wx-detail.h"

#include <math.h>
#include <string.h>

#include "wx-condition.h"
#include "wx-day-list.h"
#include "wx-format.h"
#include "wx-hour-strip.h"
#include "wx-icons.h"
#include "wx-rain-chart.h"
#include "wx-text.h"

/* Widest label in characters before a wrapping label wraps. */
#define WRAP_CHARS 50
/* Size of the big weather icon, in pixels. */
#define ICON_PIXELS 64
/* U+00B7 MIDDLE DOT, as UTF-8, with the spaces around it. */
#define SEPARATOR " \xc2\xb7 "
/* The second sentence of the error text of the placeholder. */
#define RETRY_HINT "Check your internet connection; the app tries again automatically."

struct _WxDetail {
  GtkBox parent_instance;

  GtkWidget *stack;

  /* placeholder page */
  GtkWidget *ph_spinner;
  GtkWidget *ph_title;
  GtkWidget *ph_text;

  /* forecast page: header and now block */
  GtkWidget *place_label;
  GtkWidget *badge_offline;
  GtkWidget *badge_stale;
  GtkWidget *icon;
  GtkWidget *temp_label;
  GtkWidget *condition_label;
  GtkWidget *feels_label;
  GtkWidget *highlow_label;
  GtkWidget *wind_label;

  /* forecast page: cards and sections */
  GtkWidget *rain_headline;
  GtkWidget *rain_detail;
  GtkWidget *rain_chart;       /* the 24 hour chance chart: always shown */
  GtkWidget *nowcast_box;      /* caption and chart of the 2 hour nowcast: shown while it has data */
  GtkWidget *rain_nowcast;
  GtkWidget *cloud_cover;
  GtkWidget *cloud_sentence;
  GtkWidget *hours;
  GtkWidget *days;

  /* forecast page: footer */
  GtkWidget *footer_label;
  GtkWidget *refreshing;
  GtkWidget *attribution_label;
  GtkWidget *partial_label;

  WxRowItem *item; /* strong, NULL for none */
  gulong changed_id;
  char *attribution_markup; /* what the attribution label shows, never NULL */
  gboolean disposed;        /* the child widgets may be gone: touch nothing */
};

/*
 * G_DEFINE_FINAL_TYPE() below defines wx_detail_get_type(), the static wx_detail_parent_class
 * pointer and the static class initialiser that runs wx_detail_class_init() once;
 * wx_detail_init() is registered as the instance initialiser. The instance struct is _WxDetail
 * (WxDetail).
 */
G_DEFINE_FINAL_TYPE(WxDetail, wx_detail, GTK_TYPE_BOX)

/* ------------------------------------------------------------------------ */
/* Text                                                                     */
/* ------------------------------------------------------------------------ */

/**
 * age_s:
 * @now_s: the item's "now", UTC unix seconds (any value).
 * @fetched_s: when the forecast was fetched, UTC unix seconds (any value).
 *
 * The age of the data for wx_format_updated(), computed without signed overflow.
 *
 * Preconditions:
 *  - none (any two gint64).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: 0 when @fetched_s is not before @now_s, G_MAXINT64 when the difference does not fit,
 *   otherwise @now_s - @fetched_s.
 */
static gint64
age_s(gint64 now_s, gint64 fetched_s)
{
  if (fetched_s >= now_s)
    return 0;
  if (fetched_s < 0 && now_s > G_MAXINT64 + fetched_s)
    return G_MAXINT64;
  return now_s - fetched_s;
}

/**
 * url_is_linkable:
 * @url: (nullable): an attribution URL of a source.
 *
 * Decides whether @url may become the target of a link in the attribution label. The status of a
 * source is validated by wx_source_status_new() already; this is the second line of defence for
 * a forecast that was built by hand.
 *
 * Preconditions:
 *  - @url is NULL or NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @url starts with "https://", has at least one byte after it, is at most
 *   WX_SOURCE_URL_MAX bytes long, is valid UTF-8 and contains no byte <= 0x20, no 0x7f and none
 *   of '<', '>' and '"'.
 */
static gboolean
url_is_linkable(const char *url)
{
  static const char prefix[] = "https://";
  if (url == NULL || !g_str_has_prefix(url, prefix))
    return FALSE;
  const char *nul = memchr(url, '\0', WX_SOURCE_URL_MAX + 1);
  if (nul == NULL || nul == url + sizeof prefix - 1)
    return FALSE;
  gsize len = (gsize)(nul - url);
  for (gsize i = 0; i < len; i++) {
    guchar c = (guchar)url[i];
    if (c <= 0x20 || c == 0x7f || c == '<' || c == '>' || c == '"')
      return FALSE;
  }
  return g_utf8_validate(url, (gssize)len, NULL);
}

/**
 * display_text:
 * @text: (nullable): untrusted display text of a source.
 *
 * Sanitises untrusted display text of a source (a name or an attribution) for showing it.
 *
 * Preconditions:
 *  - @text is NULL or NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): wx_sanitize_text() of @text, at most WX_SOURCE_TEXT_MAX bytes; never
 *   NULL, valid UTF-8.
 */
static char *
display_text(const char *text)
{
  return wx_sanitize_text(text, WX_SOURCE_TEXT_MAX);
}

/**
 * join_sources:
 * @forecast: (not nullable): the forecast.
 * @state: the state of the sources to list.
 *
 * Lists the names of the sources that are in @state, in forecast order, separated by ", ". A
 * source whose name is empty after sanitising is listed by its provider id.
 *
 * Preconditions:
 *  - @forecast is a valid forecast.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the list, "" when no source is in @state. Never NULL.
 */
static char *
join_sources(const WxForecast *forecast, WxSourceState state)
{
  guint n = 0;
  const WxSourceStatus *sources = wx_forecast_get_sources(forecast, &n);
  GString *out = g_string_new(NULL);
  for (guint i = 0; i < n; i++) {
    if (sources[i].state != state)
      continue;
    g_autofree char *name = display_text(sources[i].name);
    if (name[0] == '\0') {
      g_free(name);
      name = display_text(sources[i].provider_id);
    }
    if (out->len > 0)
      g_string_append(out, ", ");
    g_string_append(out, name);
  }
  return g_string_free(out, FALSE);
}

/**
 * build_attribution:
 * @forecast: (not nullable): the forecast.
 *
 * Builds the Pango markup of the attribution label: one entry per source that is WX_SRC_OK and
 * has a non-empty attribution text, separated by " · ". An entry is the escaped text inside
 * <a href="URL">, with the escaped URL, when url_is_linkable(), otherwise the escaped text.
 *
 * Preconditions:
 *  - @forecast is a valid forecast.
 * Postconditions:
 *  - no state is changed; the markup is well-formed whatever the data (every piece of external
 *    text is escaped).
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the markup, "" when there is no entry. Never NULL.
 */
static char *
build_attribution(const WxForecast *forecast)
{
  guint n = 0;
  const WxSourceStatus *sources = wx_forecast_get_sources(forecast, &n);
  GString *out = g_string_new(NULL);
  for (guint i = 0; i < n; i++) {
    if (sources[i].state != WX_SRC_OK)
      continue;
    g_autofree char *text = display_text(sources[i].attribution);
    if (text[0] == '\0')
      continue;
    g_autofree char *escaped = g_markup_escape_text(text, -1);
    if (out->len > 0)
      g_string_append(out, SEPARATOR);
    if (url_is_linkable(sources[i].attribution_url)) {
      g_autofree char *href = g_markup_escape_text(sources[i].attribution_url, -1);
      g_string_append_printf(out, "<a href=\"%s\">%s</a>", href, escaped);
    } else {
      g_string_append(out, escaped);
    }
  }
  return g_string_free(out, FALSE);
}

/**
 * find_today:
 * @forecast: (not nullable): the forecast.
 * @now_s: the item's "now", UTC unix seconds.
 * @tz: the place's zone name.
 *
 * Finds the day that contains @now_s: start_s <= @now_s < wx_format_local_day_end(start_s).
 *
 * Preconditions:
 *  - @forecast is a valid forecast; @tz is NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: the day is owned by @forecast.
 *
 * Returns: (transfer none) (nullable): the first such day in forecast order, NULL when none.
 */
static const WxDay *
find_today(const WxForecast *forecast, gint64 now_s, const char *tz)
{
  guint n = 0;
  const WxDay *days = wx_forecast_get_days(forecast, &n);
  for (guint i = 0; i < n; i++) {
    if (days[i].start_s <= now_s && now_s < wx_format_local_day_end(days[i].start_s, tz))
      return &days[i];
  }
  return NULL;
}

/**
 * error_sentence:
 * @error: (nullable): the item's error text.
 *
 * Joins the error text and the retry hint into the text of the placeholder: the error text, a
 * full stop unless the text already ends in '.', '!' or '?', one space and the hint; only the
 * hint when the error text is NULL or empty.
 *
 * Preconditions:
 *  - @error is NULL or NUL-terminated.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): the text, never NULL.
 */
static char *
error_sentence(const char *error)
{
  const char *text = error != NULL ? error : "";
  gsize len = strlen(text);
  const char *glue = len == 0 ? "" : (strchr(".!?", text[len - 1]) != NULL ? " " : ". ");
  return g_strconcat(text, glue, RETRY_HINT, NULL);
}

/* ------------------------------------------------------------------------ */
/* Rendering                                                                */
/* ------------------------------------------------------------------------ */

/**
 * set_visible_spinning:
 * @spinner: (not nullable): a GtkSpinner.
 * @on: whether it is visible and spinning.
 *
 * Makes a spinner visible and spinning, or neither.
 *
 * Preconditions:
 *  - @spinner is a GtkSpinner.
 * Postconditions:
 *  - the spinner is visible and spinning iff @on (GTK ignores a call that changes nothing).
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
set_visible_spinning(GtkWidget *spinner, gboolean on)
{
  gtk_widget_set_visible(spinner, on);
  gtk_spinner_set_spinning(GTK_SPINNER(spinner), on);
}

/**
 * refresh_placeholder:
 * @self: (not nullable): the pane, not disposed.
 *
 * Updates the placeholder page from the item (see the file comment of wx-detail.h for the
 * texts) and its spinner. The texts are only touched while the item has no forecast.
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; self->item is NULL or a live item.
 * Postconditions:
 *  - the spinner is visible and spinning iff the item is loading and has no forecast; the title
 *    and the text describe the state when there is no forecast.
 * Thread affinity: main thread only.
 * Ownership: none; the strings are freed locally.
 */
static void
refresh_placeholder(WxDetail *self)
{
  WxRowItem *item = self->item;
  gboolean has_forecast = item != NULL && wx_row_item_get_forecast(item) != NULL;
  gboolean loading = item != NULL && wx_row_item_get_loading(item);
  set_visible_spinning(self->ph_spinner, loading && !has_forecast);
  if (has_forecast)
    return;

  const char *error = item != NULL ? wx_row_item_get_error(item) : NULL;
  g_autofree char *text = NULL;
  const char *title;
  if (item == NULL) {
    title = "Select a place";
    text = g_strdup("Pick a place on the left, or add one with the + button.");
  } else if (loading) {
    title = "Loading forecast\xe2\x80\xa6";
    text = g_strdup("This takes a few seconds.");
  } else if (error != NULL) {
    title = "Couldn't load the forecast";
    text = error_sentence(error);
  } else if (wx_row_item_get_offline(item)) {
    title = "You are offline";
    text = g_strdup("The forecast loads when the network is back.");
  } else {
    title = "No forecast yet";
    text = g_strdup("");
  }
  gtk_label_set_text(GTK_LABEL(self->ph_title), title);
  gtk_label_set_text(GTK_LABEL(self->ph_text), text);
}

/**
 * refresh_header:
 * @self: (not nullable): the pane, not disposed.
 *
 * Updates the place label and the "Offline" / "Stale" badges with their tooltips.
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; self->item is a live item with a forecast.
 * Postconditions:
 *  - the offline badge is visible iff the item is offline, the stale badge iff it is stale and
 *    not offline; the tooltips carry the texts of wx-detail.h.
 * Thread affinity: main thread only.
 * Ownership: none; the strings are freed locally.
 */
static void
refresh_header(WxDetail *self)
{
  WxRowItem *item = self->item;
  g_autofree char *label = wx_place_label(wx_row_item_get_place(item));
  gtk_label_set_text(GTK_LABEL(self->place_label), label);

  gboolean offline = wx_row_item_get_offline(item);
  gboolean stale = !offline && wx_row_item_get_stale(item);
  gtk_widget_set_visible(self->badge_offline, offline);
  gtk_widget_set_visible(self->badge_stale, stale);

  const char *error = wx_row_item_get_error(item);
  g_autofree char *tip = error != NULL ? g_strconcat("The last refresh failed: ", error, NULL)
                                       : g_strdup("The last refresh failed");
  gtk_widget_set_tooltip_text(self->badge_stale, tip);
}

/**
 * set_icon:
 * @self: (not nullable): the pane, not disposed.
 * @icon_name: (not nullable): the icon name.
 * @label: (not nullable): the accessible label of the image.
 *
 * Shows an icon on the big image of the pane and gives the image its accessible label.
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; the strings are NUL-terminated.
 * Postconditions:
 *  - the image shows @icon_name and has the accessible label @label; nothing is touched when
 *    the icon name is already shown (the image is the one widget GTK would notify again for an
 *    equal name).
 * Thread affinity: main thread only.
 * Ownership: the strings are borrowed for the call (copied by GTK).
 */
static void
set_icon(WxDetail *self, const char *icon_name, const char *label)
{
  GtkImage *image = GTK_IMAGE(self->icon);
  if (g_strcmp0(gtk_image_get_icon_name(image), icon_name) != 0)
    gtk_image_set_from_icon_name(image, icon_name);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self->icon), GTK_ACCESSIBLE_PROPERTY_LABEL, label,
                                 -1);
}

/**
 * refresh_now:
 * @self: (not nullable): the pane, not disposed.
 *
 * Updates the "now" block: icon, temperature, condition, feels like, today's high and low and
 * the wind line, from the item's current conditions (em dashes and "Unknown" without them).
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; self->item is a live item with a forecast.
 * Postconditions:
 *  - the labels carry the texts of wx-detail.h; the high / low label is hidden when no day
 *    contains "now".
 * Thread affinity: main thread only.
 * Ownership: none; the strings are freed locally.
 */
static void
refresh_now(WxDetail *self)
{
  WxRowItem *item = self->item;
  WxUnits units = wx_row_item_get_units(item);
  gint64 now_s = wx_row_item_get_now_s(item);
  const char *tz = wx_row_item_get_place(item)->timezone;
  WxBlendHour cur;
  gboolean has = wx_row_item_get_current(item, &cur);

  WxCondition condition = has ? cur.condition : WX_COND_UNKNOWN;
  const char *condition_text = wx_condition_label(condition);
  set_icon(self, wx_icon_name(condition, has ? cur.is_day : TRUE), condition_text);

  g_autofree char *temp = wx_format_temp(has ? cur.temp_c : NAN, units, TRUE);
  gtk_label_set_text(GTK_LABEL(self->temp_label), temp);
  gtk_label_set_text(GTK_LABEL(self->condition_label), condition_text);

  g_autofree char *feels = wx_format_temp(has ? cur.feels_c : NAN, units, FALSE);
  g_autofree char *feels_text = g_strconcat("Feels like ", feels, NULL);
  gtk_label_set_text(GTK_LABEL(self->feels_label), feels_text);

  WxForecast *forecast = wx_row_item_get_forecast(item);
  const WxDay *today = find_today(forecast, now_s, tz);
  if (today != NULL) {
    g_autofree char *high = wx_format_temp(today->temp_max_c, units, FALSE);
    g_autofree char *low = wx_format_temp(today->temp_min_c, units, FALSE);
    /* The forecast holds no hour before the one preceding its "now": the numbers of today cover
     * only the hours from its first hour on, and the label says so. */
    gint64 from_s = wx_format_day_covered_from(forecast, today, now_s);
    g_autofree char *from = from_s != 0 ? wx_format_hour_label(from_s, tz) : NULL;
    g_autofree char *text = g_strconcat("High ", high, SEPARATOR "Low ", low,
                                        from != NULL ? " (from " : "", from != NULL ? from : "",
                                        from != NULL ? ")" : "", NULL);
    gtk_label_set_text(GTK_LABEL(self->highlow_label), text);
  }
  gtk_widget_set_visible(self->highlow_label, today != NULL);

  double wind_kmh = has ? cur.wind_kmh : NAN;
  double gust_kmh = has ? cur.gust_kmh : NAN;
  g_autofree char *wind = wx_format_wind(wind_kmh, units);
  g_autofree char *humidity = wx_format_percent(has ? cur.humidity_pct : NAN);
  g_autofree char *gust = isfinite(gust_kmh) && gust_kmh >= wind_kmh
                              ? wx_format_wind(gust_kmh, units)
                              : NULL;
  g_autofree char *wind_text = g_strconcat("Wind ", wind, gust != NULL ? ", gusts " : "",
                                           gust != NULL ? gust : "", SEPARATOR "Humidity ",
                                           humidity, NULL);
  gtk_label_set_text(GTK_LABEL(self->wind_label), wind_text);
}

/**
 * refresh_cards:
 * @self: (not nullable): the pane, not disposed.
 *
 * Updates the "Rain" and "Clouds" cards.
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; self->item is a live item with a forecast.
 * Postconditions:
 *  - the headline, detail, charts and cloud labels carry the texts and data of wx-detail.h; the
 *    rain detail is hidden when empty, the nowcast chart (with its caption) is shown iff it has
 *    data.
 * Thread affinity: main thread only.
 * Ownership: none; the strings are freed locally.
 */
static void
refresh_cards(WxDetail *self)
{
  WxRowItem *item = self->item;
  WxForecast *forecast = wx_row_item_get_forecast(item);
  WxUnits units = wx_row_item_get_units(item);
  gint64 now_s = wx_row_item_get_now_s(item);
  const char *tz = wx_row_item_get_place(item)->timezone;
  const WxRainOutlook *outlook = wx_row_item_get_outlook(item);

  g_autofree char *headline = outlook != NULL ? wx_rain_headline(outlook, now_s, tz)
                                              : g_strdup("Rain outlook unavailable");
  g_autofree char *detail = outlook != NULL ? wx_rain_detail(outlook, now_s, tz) : NULL;
  gtk_label_set_text(GTK_LABEL(self->rain_headline), headline);
  gtk_label_set_text(GTK_LABEL(self->rain_detail), detail != NULL ? detail : "");
  gtk_widget_set_visible(self->rain_detail, detail != NULL && detail[0] != '\0');
  wx_rain_chart_set_forecast(WX_RAIN_CHART(self->rain_chart), forecast, units, now_s);
  wx_rain_chart_set_forecast(WX_RAIN_CHART(self->rain_nowcast), forecast, units, now_s);
  gtk_widget_set_visible(self->nowcast_box,
                         wx_rain_chart_has_data(WX_RAIN_CHART(self->rain_nowcast)));

  WxBlendHour cur;
  gboolean has = wx_row_item_get_current(item, &cur);
  double cloud = has ? cur.cloud_pct : NAN;
  g_autofree char *percent = wx_format_percent(cloud);
  g_autofree char *cover = g_strconcat("Cloud cover ", percent, SEPARATOR, wx_cloud_label(cloud),
                                       NULL);
  g_autofree char *sentence = wx_cloud_sentence(forecast, now_s, tz);
  gtk_label_set_text(GTK_LABEL(self->cloud_cover), cover);
  gtk_label_set_text(GTK_LABEL(self->cloud_sentence), sentence);
}

/**
 * refresh_footer:
 * @self: (not nullable): the pane, not disposed.
 *
 * Updates the footer: "Updated ...", the refresh spinner, the source list, the attribution links
 * and the list of the sources that failed.
 *
 * Preconditions:
 *  - @self is a constructed, not disposed WxDetail; self->item is a live item with a forecast.
 * Postconditions:
 *  - the footer widgets carry the texts of wx-detail.h; the attribution markup is only rebuilt
 *    into the label when it changed (self->attribution_markup is what the label shows); the
 *    attribution and partial labels are hidden when empty.
 * Thread affinity: main thread only.
 * Ownership: none; the strings are freed locally.
 */
static void
refresh_footer(WxDetail *self)
{
  WxRowItem *item = self->item;
  const WxForecast *forecast = wx_row_item_get_forecast(item);

  g_autofree char *updated =
      wx_format_updated(age_s(wx_row_item_get_now_s(item), wx_row_item_get_fetched_s(item)));
  set_visible_spinning(self->refreshing, wx_row_item_get_loading(item));

  g_autofree char *ok = join_sources(forecast, WX_SRC_OK);
  g_autofree char *footer = g_strconcat(updated, SEPARATOR "Sources: ", ok[0] != '\0' ? ok : "none",
                                        NULL);
  gtk_label_set_text(GTK_LABEL(self->footer_label), footer);

  g_autofree char *markup = build_attribution(forecast);
  if (g_strcmp0(markup, self->attribution_markup) != 0) {
    gtk_label_set_markup(GTK_LABEL(self->attribution_label), markup);
    g_free(self->attribution_markup);
    self->attribution_markup = g_steal_pointer(&markup);
  }
  gtk_widget_set_visible(self->attribution_label, self->attribution_markup[0] != '\0');

  g_autofree char *failed = join_sources(forecast, WX_SRC_FAILED);
  if (failed[0] != '\0') {
    g_autofree char *partial = g_strconcat("Not available right now: ", failed, NULL);
    gtk_label_set_text(GTK_LABEL(self->partial_label), partial);
  }
  gtk_widget_set_visible(self->partial_label, failed[0] != '\0');
}

/**
 * refresh:
 * @self: (not nullable): the pane.
 *
 * Re-reads the item and updates every widget (compare before set): the placeholder page, and
 * when the item has a forecast the forecast page; the chart widgets are given NULL when there
 * is no forecast so that they drop their data. Also the callback of the item's "changed" signal
 * (connected with g_signal_connect_swapped(), so the pane is its first argument).
 *
 * Preconditions:
 *  - @self is a constructed WxDetail that is not disposed; self->item is NULL or a live item
 *    (strongly held).
 * Postconditions:
 *  - the stack shows "forecast" iff the item has a forecast, "placeholder" otherwise; the item is
 *    not modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
refresh(WxDetail *self)
{
  WxRowItem *item = self->item;
  WxForecast *forecast = item != NULL ? wx_row_item_get_forecast(item) : NULL;
  refresh_placeholder(self);
  if (forecast == NULL) {
    WxUnits units = item != NULL ? wx_row_item_get_units(item) : WX_UNITS_IMPERIAL;
    gint64 now_s = item != NULL ? wx_row_item_get_now_s(item) : 0;
    wx_rain_chart_set_forecast(WX_RAIN_CHART(self->rain_chart), NULL, units, now_s);
    wx_rain_chart_set_forecast(WX_RAIN_CHART(self->rain_nowcast), NULL, units, now_s);
    gtk_widget_set_visible(self->nowcast_box, FALSE);
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(self->hours), NULL, units, now_s);
    wx_day_list_set_forecast(WX_DAY_LIST(self->days), NULL, units, now_s);
  } else {
    refresh_header(self);
    refresh_now(self);
    refresh_cards(self);
    wx_hour_strip_set_forecast(WX_HOUR_STRIP(self->hours), forecast, wx_row_item_get_units(item),
                               wx_row_item_get_now_s(item));
    wx_day_list_set_forecast(WX_DAY_LIST(self->days), forecast, wx_row_item_get_units(item),
                             wx_row_item_get_now_s(item));
    refresh_footer(self);
  }
  const char *page = forecast != NULL ? "forecast" : "placeholder";
  if (g_strcmp0(gtk_stack_get_visible_child_name(GTK_STACK(self->stack)), page) != 0)
    gtk_stack_set_visible_child_name(GTK_STACK(self->stack), page);
}

/**
 * disconnect_item:
 * @self: (not nullable): the pane.
 *
 * Disconnects the pane from its item and drops its reference on it.
 *
 * Preconditions:
 *  - @self is a WxDetail; self->item is NULL or a live item with the handler self->changed_id.
 * Postconditions:
 *  - self->item is NULL and self->changed_id is 0; the item no longer calls the pane.
 * Thread affinity: main thread only.
 * Ownership: the pane's reference on the item is released (the item may be finalised).
 */
static void
disconnect_item(WxDetail *self)
{
  if (self->item == NULL)
    return;
  g_signal_handler_disconnect(self->item, self->changed_id);
  self->changed_id = 0;
  g_clear_object(&self->item);
}

/* Documented in wx-detail.h. */
void
wx_detail_set_item(WxDetail *self, WxRowItem *item)
{
  g_return_if_fail(WX_IS_DETAIL(self));
  if (self->disposed)
    return;
  g_return_if_fail(item == NULL || WX_IS_ROW_ITEM(item));
  if (item != self->item) {
    WxRowItem *ref = item != NULL ? g_object_ref(item) : NULL;
    disconnect_item(self);
    self->item = ref;
    if (ref != NULL)
      self->changed_id = g_signal_connect_swapped(ref, "changed", G_CALLBACK(refresh), self);
  }
  refresh(self);
}

/* ------------------------------------------------------------------------ */
/* Widget                                                                   */
/* ------------------------------------------------------------------------ */

/**
 * wx_detail_dispose:
 * @object: the pane being disposed.
 *
 * GObject dispose vfunc: disconnects from the item and drops the reference on it, marks the pane
 * disposed (the toolkit may destroy the children now, so no widget pointer is used any more),
 * then chains up. May run more than once.
 *
 * Preconditions:
 *  - @object is a WxDetail; called by GObject (possibly repeatedly).
 * Postconditions:
 *  - the pane follows no item and holds no reference on one; wx_detail_set_item() is a no-op; the
 *    parent dispose ran.
 * Thread affinity: main thread only.
 * Ownership: the item reference held by the pane is released.
 */
static void
wx_detail_dispose(GObject *object)
{
  WxDetail *self = WX_DETAIL(object);
  disconnect_item(self);
  self->disposed = TRUE;
  G_OBJECT_CLASS(wx_detail_parent_class)->dispose(object);
}

/**
 * wx_detail_finalize:
 * @object: the pane being finalized.
 *
 * GObject finalize vfunc: frees the cached attribution markup, then chains up.
 *
 * Preconditions:
 *  - called once by GObject after the last reference is dropped (dispose ran).
 * Postconditions:
 *  - the markup cache is freed.
 * Thread affinity: main thread only.
 * Ownership: the pane's own strings are released.
 */
static void
wx_detail_finalize(GObject *object)
{
  WxDetail *self = WX_DETAIL(object);
  g_clear_pointer(&self->attribution_markup, g_free);
  G_OBJECT_CLASS(wx_detail_parent_class)->finalize(object);
}

/**
 * wx_detail_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs dispose() and finalize().
 *
 * Preconditions:
 *  - called once by GObject while the type is registered.
 * Postconditions:
 *  - the vfuncs are installed.
 * Thread affinity: the thread that first uses the type.
 * Ownership: @klass is owned by GObject.
 */
static void
wx_detail_class_init(WxDetailClass *klass)
{
  GObjectClass *oc = G_OBJECT_CLASS(klass);
  oc->dispose = wx_detail_dispose;
  oc->finalize = wx_detail_finalize;
}

/**
 * make_label:
 * @name: (not nullable): widget name and style class of the label.
 * @xalign: horizontal alignment, 0.0 (left) .. 1.0 (right).
 * @wrap: TRUE for a label that wraps over several lines, FALSE for a single line that is
 *   ellipsized at the end.
 *
 * Creates a plain (not selectable) label.
 *
 * Preconditions:
 *  - GTK is initialised; @name is NUL-terminated; @xalign is in 0.0 .. 1.0.
 * Postconditions:
 *  - a new floating label with the widget name and the style class @name is returned.
 * Thread affinity: main thread only.
 * Ownership: @name is borrowed (GTK copies it).
 *
 * Returns: (transfer floating): the new label.
 */
static GtkWidget *
make_label(const char *name, float xalign, gboolean wrap)
{
  GtkWidget *label = gtk_label_new(NULL);
  gtk_label_set_xalign(GTK_LABEL(label), xalign);
  if (wrap) {
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(label), WRAP_CHARS);
  } else {
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
  }
  gtk_widget_set_name(label, name);
  gtk_widget_add_css_class(label, name);
  return label;
}

/**
 * make_title:
 * @name: (not nullable): widget name and style class of the title.
 * @css_class: (not nullable): second style class ("wx-card-title" or "wx-section-title").
 * @text: (not nullable): the fixed title text.
 *
 * Creates a title label with the accessible role "heading".
 *
 * Preconditions:
 *  - GTK is initialised; the strings are NUL-terminated.
 * Postconditions:
 *  - a new floating, left aligned, single line label carrying @text.
 * Thread affinity: main thread only.
 * Ownership: the strings are borrowed (GTK copies them).
 *
 * Returns: (transfer floating): the new label.
 */
static GtkWidget *
make_title(const char *name, const char *css_class, const char *text)
{
  GtkWidget *label = g_object_new(GTK_TYPE_LABEL, "accessible-role", GTK_ACCESSIBLE_ROLE_HEADING,
                                  "label", text, "xalign", 0.0f, NULL);
  gtk_widget_set_name(label, name);
  gtk_widget_add_css_class(label, name);
  gtk_widget_add_css_class(label, css_class);
  return label;
}

/**
 * make_spinner:
 * @name: (not nullable): widget name and style class.
 * @accessible_label: (not nullable): the accessible label of the spinner.
 *
 * Creates a spinner that the pane shows only while something is loading.
 *
 * Preconditions:
 *  - GTK is initialised; the strings are NUL-terminated.
 * Postconditions:
 *  - a new floating spinner that is neither visible nor spinning.
 * Thread affinity: main thread only.
 * Ownership: the strings are borrowed (GTK copies them).
 *
 * Returns: (transfer floating): the spinner.
 */
static GtkWidget *
make_spinner(const char *name, const char *accessible_label)
{
  GtkWidget *spinner = gtk_spinner_new();
  gtk_widget_set_name(spinner, name);
  gtk_widget_add_css_class(spinner, name);
  gtk_widget_set_visible(spinner, FALSE);
  gtk_accessible_update_property(GTK_ACCESSIBLE(spinner), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 accessible_label, -1);
  return spinner;
}

/**
 * make_badge:
 * @name: (not nullable): widget name and style class.
 * @text: (not nullable): the badge text.
 * @tooltip: (nullable): fixed tooltip, NULL for none (set later).
 *
 * Creates a small hidden label that marks the state of the data ("Offline", "Stale").
 *
 * Preconditions:
 *  - GTK is initialised; the strings are NUL-terminated.
 * Postconditions:
 *  - a new floating, hidden badge label with the extra style class "wx-badge".
 * Thread affinity: main thread only.
 * Ownership: the strings are borrowed (GTK copies them).
 *
 * Returns: (transfer floating): the badge.
 */
static GtkWidget *
make_badge(const char *name, const char *text, const char *tooltip)
{
  GtkWidget *badge = make_label(name, 0.5f, FALSE);
  gtk_label_set_text(GTK_LABEL(badge), text);
  gtk_widget_add_css_class(badge, "wx-badge");
  gtk_widget_set_valign(badge, GTK_ALIGN_CENTER);
  gtk_widget_set_visible(badge, FALSE);
  gtk_widget_set_tooltip_text(badge, tooltip);
  return badge;
}

/**
 * build_placeholder:
 * @self: (not nullable): the pane being initialised.
 *
 * Builds the placeholder page (spinner, title, text) and adds it to the stack as "placeholder".
 *
 * Preconditions:
 *  - self->stack exists; GTK is initialised.
 * Postconditions:
 *  - self->ph_spinner, ph_title and ph_text are set; the title reads "Select a place".
 * Thread affinity: main thread only.
 * Ownership: the stack owns the page.
 */
static void
build_placeholder(WxDetail *self)
{
  GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_halign(page, GTK_ALIGN_CENTER);
  gtk_widget_set_valign(page, GTK_ALIGN_CENTER);
  gtk_widget_set_vexpand(page, TRUE);
  gtk_widget_set_margin_start(page, 24);
  gtk_widget_set_margin_end(page, 24);
  gtk_widget_add_css_class(page, "wx-detail-placeholder");

  self->ph_spinner = make_spinner("wx-detail-spinner", "Loading");
  gtk_widget_set_size_request(self->ph_spinner, 32, 32);
  self->ph_title = make_label("wx-detail-placeholder-title", 0.5f, TRUE);
  self->ph_text = make_label("wx-detail-placeholder-text", 0.5f, TRUE);
  gtk_label_set_justify(GTK_LABEL(self->ph_title), GTK_JUSTIFY_CENTER);
  gtk_label_set_justify(GTK_LABEL(self->ph_text), GTK_JUSTIFY_CENTER);
  gtk_widget_add_css_class(self->ph_text, "dim-label");
  gtk_box_append(GTK_BOX(page), self->ph_spinner);
  gtk_box_append(GTK_BOX(page), self->ph_title);
  gtk_box_append(GTK_BOX(page), self->ph_text);

  gtk_label_set_text(GTK_LABEL(self->ph_title), "Select a place");
  gtk_label_set_text(GTK_LABEL(self->ph_text),
                     "Pick a place on the left, or add one with the + button.");
  gtk_stack_add_named(GTK_STACK(self->stack), page, "placeholder");
}

/**
 * build_now_block:
 * @self: (not nullable): the pane being initialised.
 * @content: (not nullable): the vertical box of the forecast page.
 *
 * Builds the place label and the "now" block (icon, temperature, condition, feels
 * like, high / low, wind) and appends them to @content.
 *
 * Preconditions:
 *  - GTK is initialised; @content is a GtkBox.
 * Postconditions:
 *  - the header and now widgets of @self are set; the badges and the high / low label are hidden.
 * Thread affinity: main thread only.
 * Ownership: @content owns the new widgets.
 */
static void
build_now_block(WxDetail *self, GtkWidget *content)
{
  self->place_label = make_label("wx-detail-place", 0.0f, FALSE);
  gtk_box_append(GTK_BOX(content), self->place_label);

  GtkWidget *now = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
  self->icon = gtk_image_new();
  gtk_image_set_pixel_size(GTK_IMAGE(self->icon), ICON_PIXELS);
  gtk_widget_set_name(self->icon, "wx-detail-icon");
  gtk_widget_add_css_class(self->icon, "wx-detail-icon");
  gtk_widget_set_valign(self->icon, GTK_ALIGN_CENTER);
  gtk_box_append(GTK_BOX(now), self->icon);

  GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_widget_set_hexpand(texts, TRUE);
  self->temp_label = make_label("wx-detail-temp", 0.0f, FALSE);
  self->condition_label = make_label("wx-detail-condition", 0.0f, FALSE);
  self->feels_label = make_label("wx-detail-feels", 0.0f, FALSE);
  self->highlow_label = make_label("wx-detail-highlow", 0.0f, FALSE);
  self->wind_label = make_label("wx-detail-wind", 0.0f, TRUE);
  gtk_widget_set_visible(self->highlow_label, FALSE);
  gtk_box_append(GTK_BOX(texts), self->temp_label);
  gtk_box_append(GTK_BOX(texts), self->condition_label);
  gtk_box_append(GTK_BOX(texts), self->feels_label);
  gtk_box_append(GTK_BOX(texts), self->highlow_label);
  gtk_box_append(GTK_BOX(texts), self->wind_label);
  gtk_box_append(GTK_BOX(now), texts);
  gtk_box_append(GTK_BOX(content), now);
}

/**
 * build_cards:
 * @self: (not nullable): the pane being initialised.
 * @content: (not nullable): the vertical box of the forecast page.
 *
 * Builds the "Rain" and "Clouds" cards and the "Next 48 hours" and "Next days" sections and
 * appends them to @content. The Rain card has two charts in a homogeneous row: the nowcast chart
 * of the next 2 hours (hidden until it has data) and the 24 hour chart, which is always there.
 *
 * Preconditions:
 *  - GTK is initialised; @content is a GtkBox.
 * Postconditions:
 *  - the card and section widgets of @self are set; the rain detail label and the nowcast chart
 *    are hidden.
 * Thread affinity: main thread only.
 * Ownership: @content owns the new widgets.
 */
static void
build_cards(WxDetail *self, GtkWidget *content)
{
  GtkWidget *rain = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_add_css_class(rain, "wx-card");
  gtk_box_append(GTK_BOX(rain), make_title("wx-detail-rain-title", "wx-card-title", "Rain"));
  self->rain_headline = make_label("wx-detail-rain-headline", 0.0f, TRUE);
  self->rain_detail = make_label("wx-detail-rain-detail", 0.0f, TRUE);
  gtk_widget_set_visible(self->rain_detail, FALSE);
  GtkWidget *charts = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
  gtk_box_set_homogeneous(GTK_BOX(charts), TRUE);
  self->nowcast_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *nowcast_caption = make_label("wx-detail-rain-nowcast-caption", 0.0f, FALSE);
  gtk_label_set_text(GTK_LABEL(nowcast_caption), "Next 2 hours");
  gtk_widget_add_css_class(nowcast_caption, "dim-label");
  self->rain_nowcast = wx_rain_chart_new();
  wx_rain_chart_set_view(WX_RAIN_CHART(self->rain_nowcast), WX_RAIN_CHART_NOWCAST);
  gtk_widget_set_name(self->rain_nowcast, "wx-detail-rain-nowcast");
  gtk_box_append(GTK_BOX(self->nowcast_box), nowcast_caption);
  gtk_box_append(GTK_BOX(self->nowcast_box), self->rain_nowcast);
  gtk_widget_set_visible(self->nowcast_box, FALSE);
  GtkWidget *hourly_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *hourly_caption = make_label("wx-detail-rain-chart-caption", 0.0f, FALSE);
  gtk_label_set_text(GTK_LABEL(hourly_caption), "Next 24 hours");
  gtk_widget_add_css_class(hourly_caption, "dim-label");
  self->rain_chart = wx_rain_chart_new();
  wx_rain_chart_set_view(WX_RAIN_CHART(self->rain_chart), WX_RAIN_CHART_HOURLY);
  gtk_widget_set_name(self->rain_chart, "wx-detail-rain-chart");
  gtk_box_append(GTK_BOX(hourly_box), hourly_caption);
  gtk_box_append(GTK_BOX(hourly_box), self->rain_chart);
  gtk_box_append(GTK_BOX(charts), self->nowcast_box);
  gtk_box_append(GTK_BOX(charts), hourly_box);
  gtk_box_append(GTK_BOX(rain), self->rain_headline);
  gtk_box_append(GTK_BOX(rain), self->rain_detail);
  gtk_box_append(GTK_BOX(rain), charts);
  gtk_box_append(GTK_BOX(content), rain);

  GtkWidget *clouds = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_add_css_class(clouds, "wx-card");
  gtk_box_append(GTK_BOX(clouds),
                 make_title("wx-detail-cloud-title", "wx-card-title", "Clouds"));
  self->cloud_cover = make_label("wx-detail-cloud-cover", 0.0f, TRUE);
  self->cloud_sentence = make_label("wx-detail-cloud-sentence", 0.0f, TRUE);
  gtk_box_append(GTK_BOX(clouds), self->cloud_cover);
  gtk_box_append(GTK_BOX(clouds), self->cloud_sentence);
  gtk_box_append(GTK_BOX(content), clouds);

  GtkWidget *hours = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_box_append(GTK_BOX(hours),
                 make_title("wx-detail-hours-title", "wx-section-title", "Next 48 hours"));
  self->hours = wx_hour_strip_new();
  gtk_widget_set_name(self->hours, "wx-detail-hours");
  gtk_box_append(GTK_BOX(hours), self->hours);
  gtk_box_append(GTK_BOX(content), hours);

  GtkWidget *days = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  gtk_box_append(GTK_BOX(days),
                 make_title("wx-detail-days-title", "wx-section-title", "Next days"));
  self->days = wx_day_list_new();
  gtk_widget_set_name(self->days, "wx-detail-days");
  gtk_box_append(GTK_BOX(days), self->days);
  gtk_box_append(GTK_BOX(content), days);
}

/**
 * build_footer:
 * @self: (not nullable): the pane being initialised.
 * @content: (not nullable): the vertical box of the forecast page.
 *
 * Builds the footer ("Updated ... · Sources: ..." with the refresh spinner and the "Offline" and
 * "Stale" badges, the attribution links, the partial notice) and appends it to @content.
 *
 * Preconditions:
 *  - GTK is initialised; @content is a GtkBox; self->attribution_markup is "".
 * Postconditions:
 *  - the footer widgets and the badges of @self are set; the spinner, the badges, the attribution
 *    label and the partial label are hidden.
 * Thread affinity: main thread only.
 * Ownership: @content owns the new widgets.
 */
static void
build_footer(WxDetail *self, GtkWidget *content)
{
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  self->footer_label = make_label("wx-detail-footer", 0.0f, TRUE);
  gtk_widget_add_css_class(self->footer_label, "dim-label");
  gtk_widget_set_hexpand(self->footer_label, TRUE);
  self->refreshing = make_spinner("wx-detail-refreshing", "Refreshing");
  self->badge_offline = make_badge("wx-detail-badge-offline", "Offline",
                                   "No network connection: showing the last forecast");
  self->badge_stale = make_badge("wx-detail-badge-stale", "Stale", NULL);
  gtk_box_append(GTK_BOX(row), self->footer_label);
  gtk_box_append(GTK_BOX(row), self->refreshing);
  gtk_box_append(GTK_BOX(row), self->badge_offline);
  gtk_box_append(GTK_BOX(row), self->badge_stale);
  gtk_box_append(GTK_BOX(content), row);

  self->attribution_label = make_label("wx-detail-attribution", 0.0f, TRUE);
  gtk_label_set_use_markup(GTK_LABEL(self->attribution_label), TRUE);
  gtk_widget_add_css_class(self->attribution_label, "dim-label");
  gtk_widget_set_visible(self->attribution_label, FALSE);
  self->partial_label = make_label("wx-detail-partial", 0.0f, TRUE);
  gtk_widget_add_css_class(self->partial_label, "dim-label");
  gtk_widget_set_visible(self->partial_label, FALSE);
  gtk_box_append(GTK_BOX(content), self->attribution_label);
  gtk_box_append(GTK_BOX(content), self->partial_label);
}

/**
 * wx_detail_init:
 * @self: (not nullable): the new pane (zero-filled by GObject).
 *
 * GObject instance initialiser: builds the scrolled window, the stack, the placeholder page and
 * the forecast page, and shows the placeholder "Select a place". The pane follows no item.
 *
 * Preconditions:
 *  - called once by GObject for a new instance; GTK is initialised.
 * Postconditions:
 *  - every widget pointer of @self is set, item is NULL, the markup cache is "".
 * Thread affinity: main thread only.
 * Ownership: @self is owned by GObject; the widget owns the children.
 */
static void
wx_detail_init(WxDetail *self)
{
  gtk_orientable_set_orientation(GTK_ORIENTABLE(self), GTK_ORIENTATION_VERTICAL);
  gtk_widget_add_css_class(GTK_WIDGET(self), "wx-detail");
  self->attribution_markup = g_strdup("");

  GtkWidget *scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER,
                                 GTK_POLICY_AUTOMATIC);
  gtk_widget_set_name(scroller, "wx-detail-scroller");
  gtk_widget_set_hexpand(scroller, TRUE);
  gtk_widget_set_vexpand(scroller, TRUE);
  gtk_box_append(GTK_BOX(self), scroller);

  self->stack = gtk_stack_new();
  gtk_widget_set_name(self->stack, "wx-detail-stack");
  gtk_stack_set_transition_type(GTK_STACK(self->stack), GTK_STACK_TRANSITION_TYPE_NONE);
  gtk_stack_set_hhomogeneous(GTK_STACK(self->stack), FALSE);
  gtk_stack_set_vhomogeneous(GTK_STACK(self->stack), FALSE);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), self->stack);

  build_placeholder(self);

  GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_name(content, "wx-detail-content");
  gtk_widget_add_css_class(content, "wx-detail-content");
  gtk_widget_set_margin_top(content, 16);
  gtk_widget_set_margin_bottom(content, 16);
  gtk_widget_set_margin_start(content, 16);
  gtk_widget_set_margin_end(content, 16);
  build_now_block(self, content);
  build_cards(self, content);
  build_footer(self, content);
  gtk_stack_add_named(GTK_STACK(self->stack), content, "forecast");

  gtk_stack_set_visible_child_name(GTK_STACK(self->stack), "placeholder");
}

/* Documented in wx-detail.h. */
GtkWidget *
wx_detail_new(void)
{
  return g_object_new(WX_TYPE_DETAIL, NULL);
}
