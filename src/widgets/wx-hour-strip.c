/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-hour-strip.c - WxHourStrip: scrolled row of hourly cards.
 * See wx-hour-strip.h for the public contract.
 */
#include "wx-hour-strip.h"

#include <string.h>

#include "wx-blend.h"
#include "wx-format.h"
#include "wx-icons.h"
#include "wx-widget-util.h"

#define ICON_PIXELS 32
#define LABEL_CHARS 9

/* What one card displays (the compare-before-set key). */
typedef struct {
  gint64 t_s;
  gboolean is_now;
  gboolean is_day;
  WxCondition condition;
  double temp_c, feels_c, prob, cloud, wind_kmh, precip_mm;
} CardData;

typedef struct {
  GtkWidget *box;
  GtkWidget *hour;
  GtkWidget *icon;
  GtkWidget *temp;
  GtkWidget *rain;
  GtkWidget *cloud;
} Card;

struct _WxHourStrip {
  GtkWidget parent_instance;
  GtkWidget *scroller; /* NULL after dispose */
  Card cards[WX_HOUR_STRIP_MAX_CARDS];
  CardData data[WX_HOUR_STRIP_MAX_CARDS];
  guint n_shown;
  WxUnits units;
  WxHeldZone zone; /* the place zone, resolved in set_forecast; cleared by dispose */
};

/* Type boilerplate: defines wx_hour_strip_get_type() and the parent class
 * pointer; main thread only. */
G_DEFINE_FINAL_TYPE(WxHourStrip, wx_hour_strip, GTK_TYPE_WIDGET)

/**
 * add_label:
 * @box: the card box to append to.
 * @css_class: style class of the label.
 * @dim: whether to add the "dim-label" class.
 *
 * Preconditions:
 *  - both pointers non-NULL.
 * Postconditions:
 *  - an empty centred label was appended and is returned.
 * Thread affinity: main thread only.
 * Ownership: the label is owned by @box.
 *
 * Returns: (transfer none): the new label.
 */
static GtkWidget *
add_label(GtkWidget *box, const char *css_class, gboolean dim)
{
  GtkWidget *label = gtk_label_new("");
  gtk_label_set_width_chars(GTK_LABEL(label), LABEL_CHARS);
  gtk_widget_add_css_class(label, css_class);
  if (dim)
    gtk_widget_add_css_class(label, "dim-label");
  gtk_box_append(GTK_BOX(box), label);
  return label;
}

/**
 * card_equal:
 * @a: first card data.
 * @b: second card data.
 *
 * Preconditions:
 *  - both non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff every displayed field is equal (NAN equals NAN).
 */
static gboolean
card_equal(const CardData *a, const CardData *b)
{
  return a->t_s == b->t_s && a->is_now == b->is_now && a->is_day == b->is_day &&
         a->condition == b->condition && wx_same_value(a->temp_c, b->temp_c) &&
         wx_same_value(a->feels_c, b->feels_c) && wx_same_value(a->prob, b->prob) &&
         wx_same_value(a->cloud, b->cloud) && wx_same_value(a->wind_kmh, b->wind_kmh) &&
         wx_same_value(a->precip_mm, b->precip_mm);
}

/**
 * bind_card:
 * @card: the card widgets.
 * @d: what to show.
 * @units: unit system.
 * @zone: the resolved place zone.
 *
 * Writes the texts, the icon and the tooltip of one card (no zone lookup).
 *
 * Preconditions:
 *  - all non-NULL; the card's widgets are alive.
 * Postconditions:
 *  - the card shows @d.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
bind_card(Card *card, const CardData *d, WxUnits units, GTimeZone *zone)
{
  g_autofree char *hour = d->is_now ? g_strdup("Now") : wx_format_hour_label_z(d->t_s, zone);
  g_autofree char *temp = wx_format_temp(d->temp_c, units, FALSE);
  g_autofree char *prob = wx_format_percent(d->prob);
  g_autofree char *cloud = wx_format_percent(d->cloud);
  g_autofree char *rain = g_strdup_printf("Rain %s", prob);
  g_autofree char *sky = g_strdup_printf("Cloud %s", cloud);
  gtk_label_set_text(GTK_LABEL(card->hour), hour);
  gtk_label_set_text(GTK_LABEL(card->temp), temp);
  gtk_label_set_text(GTK_LABEL(card->rain), rain);
  gtk_label_set_text(GTK_LABEL(card->cloud), sky);
  gtk_image_set_from_icon_name(GTK_IMAGE(card->icon), wx_icon_name(d->condition, d->is_day));

  g_autofree char *clock = wx_format_clock_z(d->t_s, zone);
  g_autofree char *feels = wx_format_temp(d->feels_c, units, TRUE);
  g_autofree char *wind = wx_format_wind(d->wind_kmh, units);
  g_autofree char *amount = wx_format_precip(d->precip_mm, units);
  g_autofree char *tip = g_strdup_printf("%s\nFeels like %s\nWind %s\nRain %s", clock, feels, wind, amount);
  gtk_widget_set_tooltip_text(card->box, tip);
}

/**
 * wx_hour_strip_dispose:
 * @object: (not nullable): the strip being disposed.
 *
 * Unparents the scroller (which destroys every card). A NULL scroller marks
 * the disposed state. Safe to run more than once.
 *
 * Preconditions:
 *  - @object is a WxHourStrip.
 * Postconditions:
 *  - scroller and zone are NULL, the card widget pointers are cleared, the
 *    parent dispose ran.
 * Thread affinity: main thread only.
 * Ownership: the scroller is owned by @object and released here.
 */
static void
wx_hour_strip_dispose(GObject *object)
{
  WxHourStrip *self = WX_HOUR_STRIP(object);
  g_clear_pointer(&self->scroller, gtk_widget_unparent);
  wx_held_zone_clear(&self->zone);
  memset(self->cards, 0, sizeof self->cards);
  self->n_shown = 0;
  G_OBJECT_CLASS(wx_hour_strip_parent_class)->dispose(object);
}

/**
 * wx_hour_strip_class_init:
 * @klass: (not nullable): the class being initialised.
 *
 * Installs dispose, the bin layout and the CSS node name.
 *
 * Preconditions:
 *  - called once by GObject (main thread).
 * Postconditions:
 *  - the class is ready.
 * Thread affinity: main thread only.
 * Ownership: @klass is owned by GObject.
 */
static void
wx_hour_strip_class_init(WxHourStripClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = wx_hour_strip_dispose;
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
  gtk_widget_class_set_layout_manager_type(widget_class, GTK_TYPE_BIN_LAYOUT);
  gtk_widget_class_set_css_name(widget_class, "wx-hour-strip");
}

/**
 * wx_hour_strip_init:
 * @self: (not nullable): the instance being initialised.
 *
 * Builds the scroller and the WX_HOUR_STRIP_MAX_CARDS hidden cards once.
 *
 * Preconditions:
 *  - called by GObject on a zero-filled instance (GTK initialised).
 * Postconditions:
 *  - every card exists and is hidden; the scroller is the only child.
 * Thread affinity: main thread only.
 * Ownership: the scroller is owned by @self.
 */
static void
wx_hour_strip_init(WxHourStrip *self)
{
  self->units = WX_UNITS_METRIC;
  wx_held_zone_init(&self->zone);
  self->scroller = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(self->scroller), GTK_POLICY_AUTOMATIC,
                                 GTK_POLICY_NEVER);
  gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(self->scroller), TRUE);
  gtk_widget_set_hexpand(self->scroller, TRUE);
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(self->scroller), row);
  for (guint i = 0; i < WX_HOUR_STRIP_MAX_CARDS; i++) {
    Card *c = &self->cards[i];
    c->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(c->box, "hour-card");
    c->hour = add_label(c->box, "hour", FALSE);
    c->icon = gtk_image_new();
    gtk_image_set_pixel_size(GTK_IMAGE(c->icon), ICON_PIXELS);
    gtk_box_append(GTK_BOX(c->box), c->icon);
    c->temp = add_label(c->box, "temp", FALSE);
    c->rain = add_label(c->box, "rain", TRUE);
    c->cloud = add_label(c->box, "cloud", TRUE);
    gtk_widget_set_visible(c->box, FALSE);
    gtk_box_append(GTK_BOX(row), c->box);
  }
  gtk_widget_set_parent(self->scroller, GTK_WIDGET(self));
}

/* Documented in wx-hour-strip.h. */
GtkWidget *
wx_hour_strip_new(void)
{
  return g_object_new(WX_TYPE_HOUR_STRIP, NULL);
}

/* Documented in wx-hour-strip.h. */
void
wx_hour_strip_set_forecast(WxHourStrip *self, const WxForecast *forecast, WxUnits units,
                           gint64 now_s)
{
  g_return_if_fail(WX_IS_HOUR_STRIP(self));
  g_return_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC);
  if (self->scroller == NULL) /* disposed */
    return;

  guint n = 0;
  guint first = 0;
  if (forecast != NULL && now_s >= WX_TIME_MIN_S && now_s < WX_TIME_MAX_S) {
    while (first < forecast->n_hours && forecast->hours[first].t_s <= now_s - 3600)
      first++;
    n = MIN(forecast->n_hours - first, (guint)WX_HOUR_STRIP_MAX_CARDS);
  }
  char tz[WX_PLACE_TIMEZONE_MAX + 1] = "";
  if (n > 0)
    g_strlcpy(tz, forecast->place.timezone, sizeof tz);
  /* The zone is resolved HERE, never when binding: once per change of the name, and again on every
   * call while the held zone is only the fallback of a failed lookup. A changed zone re-binds every
   * card even if the data did not change. */
  gboolean zone_changed = wx_held_zone_update(&self->zone, tz);
  gboolean force = units != self->units || zone_changed;

  WxBlendHour current;
  for (guint i = 0; i < n; i++) {
    const WxBlendHour *h = &forecast->hours[first + i];
    gboolean is_now = i == 0 && h->t_s <= now_s;
    /* The "Now" card shows the values AT now (interpolated as in the header of the detail pane),
     * not those at the start of the hour: one number for one moment. */
    if (is_now && wx_forecast_now(forecast, now_s, &current))
      h = &current;
    CardData d = { .t_s = h->t_s,
                   .is_now = is_now,
                   .is_day = h->is_day,
                   .condition = h->condition,
                   .temp_c = h->temp_c,
                   .feels_c = h->feels_c,
                   .prob = h->precip_prob,
                   .cloud = h->cloud_pct,
                   .wind_kmh = h->wind_kmh,
                   .precip_mm = h->precip_mm };
    if (i < self->n_shown && !force && card_equal(&d, &self->data[i]))
      continue;
    self->data[i] = d;
    bind_card(&self->cards[i], &d, units, self->zone.zone);
    if (i >= self->n_shown)
      gtk_widget_set_visible(self->cards[i].box, TRUE);
  }
  for (guint i = n; i < self->n_shown; i++)
    gtk_widget_set_visible(self->cards[i].box, FALSE);
  self->n_shown = n;
  self->units = units;
}
