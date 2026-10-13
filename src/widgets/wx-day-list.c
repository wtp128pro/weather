/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-day-list.c - WxDayList: one row per forecast day.
 * See wx-day-list.h for the public contract.
 */
#include "wx-day-list.h"

#include <string.h>

#include "wx-format.h"
#include "wx-icons.h"
#include "wx-widget-util.h"

#define ICON_PIXELS 24
/* Longest weekday label, with the NUL ("Wednesday", "Tomorrow", em dash). */
#define LABEL_MAX 16

/* What one row displays (the compare-before-set key). */
typedef struct {
  gint64 start_s;
  gint64 from_s; /* wx_format_day_covered_from(): 0 when the numbers cover the whole day */
  char day[LABEL_MAX]; /* derived from start_s, the zone and "now": not part of the raw key */
  WxCondition condition;
  double high_c, low_c, precip_mm, prob, cloud;
} RowData;

typedef struct {
  GtkWidget *box;
  GtkWidget *day;
  GtkWidget *icon;
  GtkWidget *rain;
  GtkWidget *low;
  GtkWidget *high;
} Row;

struct _WxDayList {
  GtkWidget parent_instance;
  GtkWidget *box; /* NULL after dispose */
  Row rows[WX_DAY_LIST_MAX_ROWS];
  RowData data[WX_DAY_LIST_MAX_ROWS];
  guint n_shown;
  WxUnits units;
  WxHeldZone zone; /* the place zone, resolved in set_forecast; cleared by dispose */
  gint64 now_day;  /* local day number of "now" at the last labelling, -1 before the first */
};

/* Type boilerplate: defines wx_day_list_get_type() and the parent class
 * pointer; main thread only. */
G_DEFINE_FINAL_TYPE(WxDayList, wx_day_list, GTK_TYPE_WIDGET)

/**
 * add_label:
 * @box: the row box to append to.
 * @css_class: style class of the label.
 * @chars: width in characters.
 * @xalign: horizontal alignment, 0 left .. 1 right.
 *
 * Preconditions:
 *  - @box and @css_class non-NULL.
 * Postconditions:
 *  - an empty label was appended and is returned.
 * Thread affinity: main thread only.
 * Ownership: the label is owned by @box.
 *
 * Returns: (transfer none): the new label.
 */
static GtkWidget *
add_label(GtkWidget *box, const char *css_class, int chars, float xalign)
{
  GtkWidget *label = gtk_label_new("");
  gtk_label_set_width_chars(GTK_LABEL(label), chars);
  gtk_label_set_xalign(GTK_LABEL(label), xalign);
  gtk_widget_add_css_class(label, css_class);
  gtk_box_append(GTK_BOX(box), label);
  return label;
}

/**
 * row_equal:
 * @a: first row data.
 * @b: second row data.
 *
 * Compares the raw forecast values (not the derived day label).
 *
 * Preconditions:
 *  - both non-NULL.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: TRUE iff every raw field is equal (NAN equals NAN).
 */
static gboolean
row_equal(const RowData *a, const RowData *b)
{
  return a->start_s == b->start_s && a->from_s == b->from_s && a->condition == b->condition &&
         wx_same_value(a->high_c, b->high_c) && wx_same_value(a->low_c, b->low_c) &&
         wx_same_value(a->precip_mm, b->precip_mm) && wx_same_value(a->prob, b->prob) &&
         wx_same_value(a->cloud, b->cloud);
}

/**
 * bind_row:
 * @row: the row widgets.
 * @d: what to show.
 * @units: unit system.
 * @zone: the resolved place zone (for the hour label of a partial day).
 *
 * Writes the texts, the icon and the tooltip of one row.
 *
 * Preconditions:
 *  - all non-NULL; the row's widgets are alive.
 * Postconditions:
 *  - the row shows @d.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
bind_row(Row *row, const RowData *d, WxUnits units, GTimeZone *zone)
{
  g_autofree char *prob = wx_format_percent(d->prob);
  g_autofree char *low = wx_format_temp(d->low_c, units, FALSE);
  g_autofree char *high = wx_format_temp(d->high_c, units, FALSE);
  gtk_label_set_text(GTK_LABEL(row->day), d->day);
  gtk_label_set_text(GTK_LABEL(row->rain), prob);
  gtk_label_set_text(GTK_LABEL(row->low), low);
  gtk_label_set_text(GTK_LABEL(row->high), high);
  gtk_image_set_from_icon_name(GTK_IMAGE(row->icon), wx_icon_name(d->condition, TRUE));

  g_autofree char *amount = wx_format_precip(d->precip_mm, units);
  g_autofree char *cloud = wx_format_percent(d->cloud);
  g_autofree char *partial = NULL;
  if (d->from_s != 0) {
    g_autofree char *from = wx_format_hour_label_z(d->from_s, zone);
    partial = g_strdup_printf("\nCovers the rest of the day, from %s.", from);
  }
  g_autofree char *tip = g_strdup_printf("Rain %s, %s chance\nCloud cover %s%s", amount, prob, cloud,
                                         partial != NULL ? partial : "");
  gtk_widget_set_tooltip_text(row->box, tip);
}

/**
 * wx_day_list_dispose:
 * @object: (not nullable): the list being disposed.
 *
 * Unparents the box (which destroys every row). A NULL box marks the
 * disposed state. Safe to run more than once.
 *
 * Preconditions:
 *  - @object is a WxDayList.
 * Postconditions:
 *  - box and zone are NULL, the row widget pointers are cleared, the parent
 *    dispose ran.
 * Thread affinity: main thread only.
 * Ownership: the box is owned by @object and released here.
 */
static void
wx_day_list_dispose(GObject *object)
{
  WxDayList *self = WX_DAY_LIST(object);
  g_clear_pointer(&self->box, gtk_widget_unparent);
  wx_held_zone_clear(&self->zone);
  memset(self->rows, 0, sizeof self->rows);
  self->n_shown = 0;
  G_OBJECT_CLASS(wx_day_list_parent_class)->dispose(object);
}

/**
 * wx_day_list_class_init:
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
wx_day_list_class_init(WxDayListClass *klass)
{
  G_OBJECT_CLASS(klass)->dispose = wx_day_list_dispose;
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
  gtk_widget_class_set_layout_manager_type(widget_class, GTK_TYPE_BIN_LAYOUT);
  gtk_widget_class_set_css_name(widget_class, "wx-day-list");
}

/**
 * wx_day_list_init:
 * @self: (not nullable): the instance being initialised.
 *
 * Builds the box and the WX_DAY_LIST_MAX_ROWS hidden rows once.
 *
 * Preconditions:
 *  - called by GObject on a zero-filled instance (GTK initialised).
 * Postconditions:
 *  - every row exists and is hidden; the box is the only child.
 * Thread affinity: main thread only.
 * Ownership: the box is owned by @self.
 */
static void
wx_day_list_init(WxDayList *self)
{
  self->units = WX_UNITS_METRIC;
  wx_held_zone_init(&self->zone);
  self->now_day = -1;
  self->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  for (guint i = 0; i < WX_DAY_LIST_MAX_ROWS; i++) {
    Row *r = &self->rows[i];
    r->box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(r->box, "day-row");
    r->day = add_label(r->box, "day", 10, 0.0f);
    gtk_widget_set_hexpand(r->day, TRUE);
    r->icon = gtk_image_new();
    gtk_image_set_pixel_size(GTK_IMAGE(r->icon), ICON_PIXELS);
    gtk_box_append(GTK_BOX(r->box), r->icon);
    r->rain = add_label(r->box, "rain", 5, 1.0f);
    gtk_widget_add_css_class(r->rain, "dim-label");
    r->low = add_label(r->box, "low", 4, 1.0f);
    gtk_widget_add_css_class(r->low, "dim-label");
    r->high = add_label(r->box, "high", 4, 1.0f);
    gtk_widget_set_visible(r->box, FALSE);
    gtk_box_append(GTK_BOX(self->box), r->box);
  }
  gtk_widget_set_parent(self->box, GTK_WIDGET(self));
}

/* Documented in wx-day-list.h. */
GtkWidget *
wx_day_list_new(void)
{
  return g_object_new(WX_TYPE_DAY_LIST, NULL);
}

/**
 * local_day_number:
 * @zone: non-NULL zone.
 * @t_s: UTC unix seconds in [WX_TIME_MIN_S, WX_TIME_MAX_S).
 *
 * The identity of the local calendar date at @t_s, without formatting
 * anything: it changes exactly when the local date of @t_s changes (also when
 * the clock is set back across midnight).
 *
 * Preconditions:
 *  - @zone non-NULL, @t_s in the range above.
 * Postconditions:
 *  - no state is changed; g_time_zone_find_interval()'s failure value -1 is
 *    never handed to g_time_zone_get_offset() (offset 0 is used).
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: whole days since 1970-01-01 of the local date.
 */
static gint64
local_day_number(GTimeZone *zone, gint64 t_s)
{
  gint interval = g_time_zone_find_interval(zone, G_TIME_TYPE_UNIVERSAL, t_s);
  gint offset = interval >= 0 ? g_time_zone_get_offset(zone, interval) : 0;
  return (t_s + offset) / 86400;
}

/* Documented in wx-day-list.h. */
void
wx_day_list_set_forecast(WxDayList *self, const WxForecast *forecast, WxUnits units, gint64 now_s)
{
  g_return_if_fail(WX_IS_DAY_LIST(self));
  g_return_if_fail(units == WX_UNITS_IMPERIAL || units == WX_UNITS_METRIC);
  if (self->box == NULL) /* disposed */
    return;

  /* The zone is resolved HERE, never when labelling: once per change of the name, and again on every
   * call while the held zone is only the fallback of a failed lookup. A changed zone rebuilds every
   * row (labels, day ends) even if the data did not change. */
  char tz[WX_PLACE_TIMEZONE_MAX + 1] = "";
  if (forecast != NULL)
    g_strlcpy(tz, forecast->place.timezone, sizeof tz);
  gboolean zone_changed = wx_held_zone_update(&self->zone, tz);
  gboolean force = units != self->units || zone_changed;

  guint n = 0;
  guint first = 0;
  gint64 now_day = -1;
  if (forecast != NULL && now_s >= WX_TIME_MIN_S && now_s < WX_TIME_MAX_S) {
    now_day = local_day_number(self->zone.zone, now_s);
    /* A day is over when ITS OWN local end has passed, whether or not the
     * next day is in the forecast. */
    while (first < forecast->n_days && forecast->days[first].start_s <= now_s) {
      gint64 end_s = wx_format_local_day_end_z(forecast->days[first].start_s, self->zone.zone);
      if (end_s == 0 || end_s > now_s)
        break;
      first++;
    }
    n = MIN(forecast->n_days - first, (guint)WX_DAY_LIST_MAX_ROWS);
  }
  /* The labels ("Today", "Tomorrow", ...) depend on the local date of now only. */
  gboolean relabel = now_day != self->now_day;

  for (guint i = 0; i < n; i++) {
    const WxDay *day = &forecast->days[first + i];
    RowData d = { .start_s = day->start_s,
                  .from_s = wx_format_day_covered_from(forecast, day, now_s),
                  .condition = day->condition,
                  .high_c = day->temp_max_c,
                  .low_c = day->temp_min_c,
                  .precip_mm = day->precip_mm,
                  .prob = day->precip_prob_max,
                  .cloud = day->cloud_pct };
    gboolean same = i < self->n_shown && !force && row_equal(&d, &self->data[i]);
    if (same && !relabel) /* nothing changed: nothing is formatted */
      continue;
    g_autofree char *label = wx_format_weekday_z(day->start_s, self->zone.zone, now_s);
    if (same && strcmp(label, self->data[i].day) == 0)
      continue;
    g_strlcpy(d.day, label, sizeof d.day);
    self->data[i] = d;
    bind_row(&self->rows[i], &d, units, self->zone.zone);
    if (i >= self->n_shown)
      gtk_widget_set_visible(self->rows[i].box, TRUE);
  }
  for (guint i = n; i < self->n_shown; i++)
    gtk_widget_set_visible(self->rows[i].box, FALSE);
  self->n_shown = n;
  self->units = units;
  self->now_day = now_day;
}
