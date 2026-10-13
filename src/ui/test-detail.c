/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-detail.c - GUI tests of WxDetail (the detail pane). Needs a display (run under xvfb-run);
 * exits 77 ("skipped") without one. Offline: the forecasts are built by hand relative to a fixed
 * time and the items are driven with wx_row_item_set_now_s(), so no test depends on the clock.
 */
#include "test-support.h" /* first: it defines _GNU_SOURCE before any system header */

#include <math.h>
#include <string.h>

#include "wx-condition.h"
#include "wx-day-list.h"
#include "wx-detail.h"
#include "wx-format.h"
#include "wx-hour-strip.h"
#include "wx-icons.h"
#include "wx-rain-chart.h"
#include "wx-row.h"
#include "wx-types.h"

#define NY "America/New_York"
#define AKL "Pacific/Auckland"

/* 2026-10-12 18:00:00Z (2:00 PM in New York, 7:00 AM on 2026-10-13 in Auckland). */
#define T_H0 G_GINT64_CONSTANT(1791828000)
/* The fixed "now" of almost every test: 18:30:00Z. */
#define NOW_S (T_H0 + 1800)
/* 2026-10-12 00:00 in New York (04:00Z). */
#define NY_DAY0 G_GINT64_CONSTANT(1791777600)

#define SECOND_SENTENCE "Check your internet connection; the app tries again automatically."
#define DASH "\xe2\x80\x94"
#define DOT " \xc2\xb7 "

/* Runs @check with the one critical that @fname's g_return_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* ------------------------------------------------------------------ */
/* Fixtures                                                           */
/* ------------------------------------------------------------------ */

static WxPlace *
place_new(const char *tz)
{
  g_autoptr(GError) err = NULL;
  WxPlace *p;
  if (g_strcmp0(tz, AKL) == 0)
    p = wx_place_new("Auckland", "Auckland", "New Zealand", "NZ", -36.85, 174.76, tz, &err);
  else if (g_strcmp0(tz, "UTC") == 0)
    p = wx_place_new("Reykjavik", "", "Iceland", "IS", 64.14, -21.9, tz, &err);
  else
    p = wx_place_new("New York", "New York", "United States", "US", 40.71, -74.0, tz, &err);
  g_assert_no_error(err);
  g_assert_nonnull(p);
  return p;
}

/* A forecast under construction: hours from T_H0 on, quarters, days and sources. */
typedef struct {
  WxBlendHour hours[WX_FORECAST_MAX_HOURS];
  guint n_hours;
  WxQuarter quarters[WX_FORECAST_MAX_QUARTERS];
  guint n_quarters;
  WxDay days[WX_FORECAST_MAX_DAYS];
  guint n_days;
  WxSourceStatus *sources[WX_FORECAST_MAX_SOURCES];
  guint n_sources;
} Spec;

/* 25 C (77 F), feels 24 C (75 F), wind 20 km/h (12 mph), gusts 32 km/h (20 mph), humidity 40 %,
 * cloud cover 50 % (partly cloudy), dry. */
static void
hour_init(WxBlendHour *h, gint64 t_s)
{
  *h = (WxBlendHour){ .t_s = t_s,
                      .temp_c = 25,
                      .feels_c = 24,
                      .precip_mm = 0,
                      .precip_mm_max = 0,
                      .precip_prob = 0,
                      .cloud_pct = 50,
                      .wind_kmh = 20,
                      .gust_kmh = 32,
                      .humidity_pct = 40,
                      .temp_spread_c = NAN,
                      .n_members = 2,
                      .condition = WX_COND_PARTLY_CLOUDY,
                      .is_day = TRUE };
}

/* The hours of a plain forecast: 72, so that the forecast knows the precipitation of the 48 hours
 * after "now" (NOW_S is half an hour into the first hour): only then the pane says it is dry for
 * 48 hours. */
#define SPEC_HOURS 72

/* One day (NY_DAY0, high 27 C = 81 F, low 16 C = 61 F) and nothing else. */
static void
spec_init(Spec *s, guint n_hours)
{
  memset(s, 0, sizeof *s);
  s->n_hours = n_hours;
  for (guint i = 0; i < n_hours; i++)
    hour_init(&s->hours[i], T_H0 + (gint64)i * 3600);
  s->days[0] = (WxDay){ .start_s = NY_DAY0,
                        .temp_max_c = 27,
                        .temp_min_c = 16,
                        .precip_mm = 0,
                        .precip_prob_max = 10,
                        .cloud_pct = 50,
                        .condition = WX_COND_PARTLY_CLOUDY };
  s->n_days = 1;
}

static void
spec_free(Spec *s)
{
  for (guint i = 0; i < s->n_sources; i++)
    wx_source_status_free(s->sources[i]);
  s->n_sources = 0;
}

static void
spec_add_source(Spec *s, const char *id, const char *name, const char *attribution,
                const char *url, WxSourceState state)
{
  g_autoptr(GError) err = NULL;
  g_assert_cmpuint(s->n_sources, <, WX_FORECAST_MAX_SOURCES);
  WxSourceStatus *st = wx_source_status_new(id, name, attribution, url, state,
                                            state == WX_SRC_FAILED ? WX_ERROR_NETWORK : -1,
                                            state == WX_SRC_OK ? 1 : 0, &err);
  g_assert_no_error(err);
  g_assert_nonnull(st);
  s->sources[s->n_sources++] = st;
}

static void
spec_add_day(Spec *s, gint64 start_s, double hi, double lo)
{
  g_assert_cmpuint(s->n_days, <, WX_FORECAST_MAX_DAYS);
  s->days[s->n_days++] = (WxDay){ .start_s = start_s,
                                  .temp_max_c = hi,
                                  .temp_min_c = lo,
                                  .precip_mm = 0,
                                  .precip_prob_max = 0,
                                  .cloud_pct = 50,
                                  .condition = WX_COND_CLEAR };
}

static void
spec_wet(Spec *s, guint hour, double mm, double prob)
{
  s->hours[hour].precip_mm = mm;
  s->hours[hour].precip_mm_max = mm;
  s->hours[hour].precip_prob = prob;
  s->hours[hour].condition = WX_COND_RAIN;
}

static WxForecast *
spec_forecast(const Spec *s, const WxPlace *place)
{
  g_autoptr(GError) err = NULL;
  WxSourceStatus statuses[WX_FORECAST_MAX_SOURCES];
  for (guint i = 0; i < s->n_sources; i++)
    statuses[i] = *s->sources[i];
  WxForecast *f = wx_forecast_new(place, NOW_S, s->n_hours ? s->hours : NULL, s->n_hours,
                                  s->n_quarters ? s->quarters : NULL, s->n_quarters,
                                  s->n_days ? s->days : NULL, s->n_days,
                                  s->n_sources ? statuses : NULL, s->n_sources, &err);
  g_assert_no_error(err);
  g_assert_nonnull(f);
  return f;
}

static WxRowItem *
item_new(const WxPlace *place)
{
  WxRowItem *item = wx_row_item_new(place);
  g_assert_nonnull(item);
  wx_row_item_set_now_s(item, NOW_S);
  return item;
}

/* An item of zone @tz showing the forecast of @s, fetched 2 minutes before "now". */
static WxRowItem *
item_with(const Spec *s, const char *tz)
{
  g_autoptr(WxPlace) place = place_new(tz);
  g_autoptr(WxForecast) f = spec_forecast(s, place);
  WxRowItem *item = item_new(place);
  wx_row_item_set_forecast(item, f, NOW_S - 120);
  return item;
}

/* An item of zone @tz showing the plain dry forecast of SPEC_HOURS hours. */
static WxRowItem *
item_plain(const char *tz)
{
  Spec s;
  spec_init(&s, SPEC_HOURS);
  WxRowItem *item = item_with(&s, tz);
  spec_free(&s);
  return item;
}

static WxDetail *
pane_new(void)
{
  return WX_DETAIL(g_object_ref_sink(wx_detail_new()));
}

#define T(name) wxt_label_text(GTK_WIDGET(pane), (name))

/* The footer is ONE label reading "Updated ... · Sources: ..."; these return its two parts (the
 * second one starts with "Sources: "), as strings that live until the end of the test. */
#define FOOTER_SEP " \xC2\xB7 "
static const char *
footer_part(WxDetail *pane, gboolean sources)
{
  const char *full = wxt_label_text(GTK_WIDGET(pane), "wx-detail-footer");
  const char *sep = strstr(full, FOOTER_SEP "Sources: ");
  g_assert_nonnull(sep);
  char *part = sources ? g_strdup(sep + strlen(FOOTER_SEP)) : g_strndup(full, (gsize)(sep - full));
  g_test_queue_free(part);
  return part;
}
#define FOOTER_UPDATED(pane) footer_part((pane), FALSE)
#define FOOTER_SOURCES(pane) footer_part((pane), TRUE)

static GtkWidget *
find(WxDetail *pane, const char *name)
{
  GtkWidget *w = wxt_find_named(GTK_WIDGET(pane), name);
  g_assert_nonnull(w);
  return w;
}

static gboolean
shown(WxDetail *pane, const char *name)
{
  return gtk_widget_get_visible(find(pane, name));
}

static gboolean
spinning(WxDetail *pane, const char *name)
{
  GtkWidget *w = find(pane, name);
  g_assert_true(GTK_IS_SPINNER(w));
  return gtk_spinner_get_spinning(GTK_SPINNER(w));
}

static const char *
page_name(WxDetail *pane)
{
  return gtk_stack_get_visible_child_name(GTK_STACK(find(pane, "wx-detail-stack")));
}

static const char *
markup_of(WxDetail *pane, const char *name)
{
  GtkWidget *w = find(pane, name);
  g_assert_true(GTK_IS_LABEL(w));
  return gtk_label_get_label(GTK_LABEL(w));
}

static const char *
icon_of(WxDetail *pane)
{
  return gtk_image_get_icon_name(GTK_IMAGE(find(pane, "wx-detail-icon")));
}

static void
walk(GtkWidget *root, void (*fn)(GtkWidget *, gpointer), gpointer data)
{
  fn(root, data);
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL;
       c = gtk_widget_get_next_sibling(c))
    walk(c, fn, data);
}

static void
count_visible_with_class(GtkWidget *w, gpointer data)
{
  gpointer *args = data;
  if (gtk_widget_has_css_class(w, args[0]) && gtk_widget_get_visible(w))
    (*(guint *)args[1])++;
}

static guint
visible_with_class(GtkWidget *root, const char *css_class)
{
  guint n = 0;
  gpointer args[2] = { (gpointer)css_class, &n };
  walk(root, count_visible_with_class, args);
  return n;
}

/* Texts of the first visible label with CSS class @css_class below @root, "" when none. */
static const char *
first_label_with_class(GtkWidget *w, const char *css_class)
{
  if (GTK_IS_LABEL(w) && gtk_widget_has_css_class(w, css_class) && gtk_widget_get_visible(w))
    return gtk_label_get_text(GTK_LABEL(w));
  for (GtkWidget *c = gtk_widget_get_first_child(w); c != NULL;
       c = gtk_widget_get_next_sibling(c)) {
    const char *t = first_label_with_class(c, css_class);
    if (t[0] != '\0')
      return t;
  }
  return "";
}

static void
settle(void)
{
  wxt_pump_ms(60);
  wxt_pump_idle();
}

/* Puts @pane in a window with a size that fits the whole forecast page and shows it. */
static GtkWidget *
show_in_window(WxDetail *pane)
{
  GtkWidget *window = gtk_window_new();
  gtk_window_set_default_size(GTK_WINDOW(window), 560, 1400);
  gtk_window_set_child(GTK_WINDOW(window), GTK_WIDGET(pane));
  gtk_window_present(GTK_WINDOW(window));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(pane)));
  settle();
  return window;
}

static void
hide_window(GtkWidget *window)
{
  gtk_window_destroy(GTK_WINDOW(window));
  wxt_pump_idle();
}

/* Counts of the node types of one snapshot of @widget: colour (grid, bars), text and stroke
 * (the chance line of the hourly view). */
typedef struct {
  guint color, text, stroke;
} Counts;

static void
count_nodes(GskRenderNode *node, Counts *c)
{
  if (node == NULL)
    return;
  switch (gsk_render_node_get_node_type(node)) {
  case GSK_CONTAINER_NODE:
    for (guint i = 0; i < gsk_container_node_get_n_children(node); i++)
      count_nodes(gsk_container_node_get_child(node, i), c);
    break;
  case GSK_TRANSFORM_NODE:
    count_nodes(gsk_transform_node_get_child(node), c);
    break;
  case GSK_COLOR_NODE:
    c->color++;
    break;
  case GSK_TEXT_NODE:
    c->text++;
    break;
  case GSK_STROKE_NODE:
    c->stroke++;
    break;
  default:
    break;
  }
}

static Counts
chart_counts_of(WxDetail *pane, const char *name)
{
  GtkWidget *chart = find(pane, name);
  g_assert_cmpint(gtk_widget_get_width(chart), >, 0);
  GtkSnapshot *snapshot = gtk_snapshot_new();
  GTK_WIDGET_GET_CLASS(chart)->snapshot(chart, snapshot);
  GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
  Counts c = { 0, 0, 0 };
  count_nodes(node, &c);
  if (node != NULL)
    gsk_render_node_unref(node);
  return c;
}

/* The 24 hour chart. */
static Counts
chart_counts(WxDetail *pane)
{
  return chart_counts_of(pane, "wx-detail-rain-chart");
}

/* The 2 hour nowcast chart. */
static Counts
nowcast_counts(WxDetail *pane)
{
  return chart_counts_of(pane, "wx-detail-rain-nowcast");
}

/* ------------------------------------------------------------------ */
/* Structure                                                          */
/* ------------------------------------------------------------------ */

static void
test_construct(void)
{
  GtkWidget *w = wx_detail_new();
  g_assert_true(g_object_is_floating(w));
  g_assert_true(WX_IS_DETAIL(w));
  g_assert_true(GTK_IS_BOX(w));
  g_assert_cmpint(gtk_orientable_get_orientation(GTK_ORIENTABLE(w)), ==, GTK_ORIENTATION_VERTICAL);
  g_assert_true(gtk_widget_has_css_class(w, "wx-detail"));
  g_object_unref(g_object_ref_sink(w));
}

static void
test_scrolled_child(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  GtkWidget *first = gtk_widget_get_first_child(GTK_WIDGET(pane));
  g_assert_true(GTK_IS_SCROLLED_WINDOW(first));
  g_assert_true(first == gtk_widget_get_last_child(GTK_WIDGET(pane)));
  GtkPolicyType h, v;
  gtk_scrolled_window_get_policy(GTK_SCROLLED_WINDOW(first), &h, &v);
  g_assert_cmpint(h, ==, GTK_POLICY_NEVER);
  g_assert_cmpint(v, ==, GTK_POLICY_AUTOMATIC);
  g_assert_cmpstr(gtk_widget_get_name(first), ==, "wx-detail-scroller");
  GtkWidget *stack = find(pane, "wx-detail-stack");
  g_assert_true(GTK_IS_STACK(stack));
  g_assert_true(gtk_widget_get_ancestor(stack, GTK_TYPE_SCROLLED_WINDOW) == first);
  g_assert_nonnull(gtk_stack_get_child_by_name(GTK_STACK(stack), "placeholder"));
  g_assert_nonnull(gtk_stack_get_child_by_name(GTK_STACK(stack), "forecast"));
}

static const char *const unique_names[] = {
  "wx-detail-stack",        "wx-detail-placeholder-title", "wx-detail-placeholder-text",
  "wx-detail-spinner",      "wx-detail-place",             "wx-detail-badge-offline",
  "wx-detail-badge-stale",  "wx-detail-icon",              "wx-detail-temp",
  "wx-detail-condition",    "wx-detail-feels",             "wx-detail-highlow",
  "wx-detail-wind",         "wx-detail-rain-title",        "wx-detail-rain-headline",
  "wx-detail-rain-detail",  "wx-detail-rain-chart",        "wx-detail-cloud-title",
  "wx-detail-rain-nowcast", "wx-detail-rain-nowcast-caption", "wx-detail-rain-chart-caption",
  "wx-detail-cloud-cover",  "wx-detail-cloud-sentence",    "wx-detail-hours-title",
  "wx-detail-hours",        "wx-detail-days-title",        "wx-detail-days",
  "wx-detail-footer",       "wx-detail-refreshing",
  "wx-detail-attribution",  "wx-detail-partial",
};

static void
test_widget_names_unique(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  for (guint i = 0; i < G_N_ELEMENTS(unique_names); i++) {
    g_autoptr(GPtrArray) found = g_ptr_array_new();
    wxt_collect_named(GTK_WIDGET(pane), unique_names[i], found);
    if (found->len != 1)
      g_error("widget name %s found %u times", unique_names[i], found->len);
    GtkWidget *w = g_ptr_array_index(found, 0);
    if (GTK_IS_LABEL(w) || GTK_IS_SPINNER(w) || GTK_IS_IMAGE(w))
      g_assert_true(gtk_widget_has_css_class(w, unique_names[i]));
  }
}

static void
test_widget_types(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_assert_true(WX_IS_RAIN_CHART(find(pane, "wx-detail-rain-chart")));
  g_assert_true(WX_IS_RAIN_CHART(find(pane, "wx-detail-rain-nowcast")));
  g_assert_true(WX_IS_HOUR_STRIP(find(pane, "wx-detail-hours")));
  g_assert_true(WX_IS_DAY_LIST(find(pane, "wx-detail-days")));
  g_assert_true(GTK_IS_IMAGE(find(pane, "wx-detail-icon")));
  g_assert_cmpint(gtk_image_get_pixel_size(GTK_IMAGE(find(pane, "wx-detail-icon"))), ==, 64);
  g_assert_true(GTK_IS_SPINNER(find(pane, "wx-detail-spinner")));
  g_assert_true(GTK_IS_SPINNER(find(pane, "wx-detail-refreshing")));
}

static void
test_cards_have_class(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  GtkWidget *rain = gtk_widget_get_parent(find(pane, "wx-detail-rain-title"));
  GtkWidget *clouds = gtk_widget_get_parent(find(pane, "wx-detail-cloud-title"));
  g_assert_true(GTK_IS_BOX(rain));
  g_assert_true(gtk_widget_has_css_class(rain, "wx-card"));
  g_assert_true(GTK_IS_BOX(clouds));
  g_assert_true(gtk_widget_has_css_class(clouds, "wx-card"));
  g_assert_true(rain != clouds);
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-rain-title"), "wx-card-title"));
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-cloud-title"), "wx-card-title"));
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-hours-title"), "wx-section-title"));
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-days-title"), "wx-section-title"));
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-badge-offline"), "wx-badge"));
  g_assert_true(gtk_widget_has_css_class(find(pane, "wx-detail-badge-stale"), "wx-badge"));
}

static void
check_not_selectable(GtkWidget *w, gpointer data)
{
  (void)data;
  if (GTK_IS_LABEL(w))
    g_assert_false(gtk_label_get_selectable(GTK_LABEL(w)));
}

static void
test_accessibility(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  static const char *const titles[] = { "wx-detail-rain-title", "wx-detail-cloud-title",
                                        "wx-detail-hours-title", "wx-detail-days-title" };
  for (guint i = 0; i < G_N_ELEMENTS(titles); i++)
    g_assert_cmpint(gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(find(pane, titles[i]))), ==,
                    GTK_ACCESSIBLE_ROLE_HEADING);
  walk(GTK_WIDGET(pane), check_not_selectable, NULL);
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  walk(GTK_WIDGET(pane), check_not_selectable, NULL);
  g_assert_cmpstr(T("wx-detail-rain-title"), ==, "Rain");
  g_assert_cmpstr(T("wx-detail-cloud-title"), ==, "Clouds");
  g_assert_cmpstr(T("wx-detail-hours-title"), ==, "Next 48 hours");
  g_assert_cmpstr(T("wx-detail-days-title"), ==, "Next days");
}

/* Asserts that the accessible label of @w equals @expected (GTK_A11Y=test backend). */
static void
assert_a11y_label(GtkWidget *w, const char *expected)
{
  g_autofree char *problem = gtk_test_accessible_check_property(
      GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, expected);
  g_assert_null(problem);
}

static void
test_accessible_labels(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  assert_a11y_label(find(pane, "wx-detail-spinner"), "Loading");
  assert_a11y_label(find(pane, "wx-detail-refreshing"), "Refreshing");
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  assert_a11y_label(find(pane, "wx-detail-icon"), "Partly cloudy");
  assert_a11y_label(find(pane, "wx-detail-spinner"), "Loading");
  assert_a11y_label(find(pane, "wx-detail-refreshing"), "Refreshing");
  wx_row_item_set_now_s(item, T_H0 + 100 * 3600); /* no current conditions */
  assert_a11y_label(find(pane, "wx-detail-icon"), "Unknown");
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].condition = WX_COND_THUNDERSTORM;
  g_autoptr(WxRowItem) storm = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, storm);
  assert_a11y_label(find(pane, "wx-detail-icon"), "Thunderstorm");
}

static void
test_null_arguments(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  ASSERT_CRITICAL("wx_detail_set_item", wx_detail_set_item(NULL, item));
  GtkWidget *not_an_item = g_object_ref_sink(gtk_label_new("x"));
  ASSERT_CRITICAL("wx_detail_set_item", wx_detail_set_item(pane, (WxRowItem *)not_an_item));
  g_object_unref(not_an_item);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
}

/* ------------------------------------------------------------------ */
/* Placeholder                                                        */
/* ------------------------------------------------------------------ */

static void
test_placeholder_no_item(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==,
                  "Pick a place on the left, or add one with the + button.");
  g_assert_false(shown(pane, "wx-detail-spinner"));
  g_assert_false(spinning(pane, "wx-detail-spinner"));
  GtkLabel *text = GTK_LABEL(find(pane, "wx-detail-placeholder-text"));
  g_assert_true(gtk_label_get_wrap(text));
  g_assert_cmpint(gtk_label_get_justify(text), ==, GTK_JUSTIFY_CENTER);
  g_assert_cmpfloat(gtk_label_get_xalign(text), ==, 0.5f);
  g_assert_true(gtk_label_get_wrap(GTK_LABEL(find(pane, "wx-detail-rain-headline"))));
  wx_detail_set_item(pane, NULL);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");
}

static void
test_placeholder_loading(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_row_item_set_loading(item, TRUE);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Loading forecast\xe2\x80\xa6");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "This takes a few seconds.");
  g_assert_true(shown(pane, "wx-detail-spinner"));
  g_assert_true(spinning(pane, "wx-detail-spinner"));
}

static void
test_placeholder_error(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  wx_row_item_set_error(item, "Network error");
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Couldn't load the forecast");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "Network error. " SECOND_SENTENCE);
  g_assert_false(shown(pane, "wx-detail-spinner"));
  g_assert_false(spinning(pane, "wx-detail-spinner"));
}

static void
test_placeholder_error_punctuation(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  static const struct {
    const char *error;
    const char *text;
  } cases[] = {
    { "Timed out.", "Timed out. " SECOND_SENTENCE },
    { "Server said no!", "Server said no! " SECOND_SENTENCE },
    { "Why?", "Why? " SECOND_SENTENCE },
    { "Code 503", "Code 503. " SECOND_SENTENCE },
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    wx_row_item_set_error(item, cases[i].error);
    g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, cases[i].text);
  }
}

static void
test_placeholder_error_hostile(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  wx_row_item_set_error(item, "<b>boom</b> & \"%s\" %n <a href='x'>\x01\x1b[31m\xff");
  /* control characters are removed and the invalid byte replaced by the item; the rest is shown
   * literally (the label is plain text) */
  const char *text = T("wx-detail-placeholder-text");
  g_assert_true(g_str_has_prefix(text, "<b>boom</b> & \"%s\" %n <a href='x'>"));
  g_assert_true(g_str_has_suffix(text, ". " SECOND_SENTENCE));
  g_assert_true(g_utf8_validate(text, -1, NULL));
  g_assert_false(gtk_label_get_use_markup(GTK_LABEL(find(pane, "wx-detail-placeholder-text"))));

  g_autofree char *big = g_strnfill(5000, 'x');
  wx_row_item_set_error(item, big);
  g_assert_true(g_str_has_suffix(T("wx-detail-placeholder-text"), ". " SECOND_SENTENCE));
  g_assert_cmpuint(strlen(T("wx-detail-placeholder-text")), ==,
                   WX_ROW_ERROR_MAX_BYTES + strlen(". " SECOND_SENTENCE));
}

static void
test_placeholder_error_empty_text(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  /* an error text that is empty after sanitising is no error at all */
  wx_row_item_set_error(item, "\x01\x02");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "No forecast yet");
  wx_row_item_set_error(item, "");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "No forecast yet");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "");
  wx_row_item_set_error(item, "x");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Couldn't load the forecast");
  wx_row_item_set_error(item, NULL);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "No forecast yet");
}

static void
test_placeholder_offline_and_none(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "No forecast yet");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "");
  wx_row_item_set_offline(item, TRUE);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "You are offline");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==,
                  "The forecast loads when the network is back.");
  wx_row_item_set_offline(item, FALSE);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "No forecast yet");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "");
  g_assert_false(spinning(pane, "wx-detail-spinner"));
}

static void
test_placeholder_precedence(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  wx_row_item_set_offline(item, TRUE);
  wx_row_item_set_error(item, "Oops");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Couldn't load the forecast");
  wx_row_item_set_loading(item, TRUE);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Loading forecast\xe2\x80\xa6");
  g_assert_cmpstr(T("wx-detail-placeholder-text"), ==, "This takes a few seconds.");
  g_assert_true(spinning(pane, "wx-detail-spinner"));
  wx_row_item_set_loading(item, FALSE);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Couldn't load the forecast");
  g_assert_false(spinning(pane, "wx-detail-spinner"));
  g_assert_false(shown(pane, "wx-detail-spinner"));
  wx_row_item_set_error(item, NULL);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "You are offline");
}

static void
test_spinners_follow_loading_and_forecast(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  wx_row_item_set_loading(item, TRUE);
  g_assert_true(spinning(pane, "wx-detail-spinner"));
  g_assert_false(spinning(pane, "wx-detail-refreshing"));
  g_assert_false(shown(pane, "wx-detail-refreshing"));

  Spec s;
  spec_init(&s, SPEC_HOURS);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  wx_row_item_set_forecast(item, f, NOW_S);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  g_assert_false(spinning(pane, "wx-detail-spinner"));
  g_assert_false(shown(pane, "wx-detail-spinner"));
  g_assert_true(spinning(pane, "wx-detail-refreshing"));
  g_assert_true(shown(pane, "wx-detail-refreshing"));

  wx_row_item_set_loading(item, FALSE);
  g_assert_false(spinning(pane, "wx-detail-refreshing"));
  g_assert_false(shown(pane, "wx-detail-refreshing"));
  g_assert_false(spinning(pane, "wx-detail-spinner"));

  wx_row_item_set_forecast(item, NULL, 0);
  wx_row_item_set_loading(item, TRUE);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_true(spinning(pane, "wx-detail-spinner"));
  g_assert_false(spinning(pane, "wx-detail-refreshing"));
}

static void
test_page_follows_forecast(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  Spec s;
  spec_init(&s, SPEC_HOURS);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  wx_row_item_set_forecast(item, f, NOW_S);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  wx_row_item_set_forecast(item, NULL, 0);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  wx_row_item_set_forecast(item, f, NOW_S);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  wx_detail_set_item(pane, NULL);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");
}

/* ------------------------------------------------------------------ */
/* Item lifecycle                                                     */
/* ------------------------------------------------------------------ */

/* Number of handlers of the "changed" signal of @item whose user data is @pane (the pane connects
 * with g_signal_connect_swapped(item, "changed", ..., pane)). Only compares the pointer. */
static guint
handlers_for(gpointer item, gpointer pane)
{
  guint signal_id = g_signal_lookup("changed", WX_TYPE_ROW_ITEM);
  g_assert_cmpuint(signal_id, !=, 0);
  /* g_signal_handler_find() returns one handler: block each found one, look again, unblock */
  gulong found[8];
  guint n = 0;
  gulong id;
  while (n < G_N_ELEMENTS(found) &&
         (id = g_signal_handler_find(item, G_SIGNAL_MATCH_DATA | G_SIGNAL_MATCH_UNBLOCKED,
                                     signal_id, 0, NULL, NULL, pane)) != 0) {
    found[n++] = id;
    g_signal_handler_block(item, id);
  }
  for (guint i = 0; i < n; i++)
    g_signal_handler_unblock(item, found[i]);
  return n;
}

static void
test_switch_items(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  g_autoptr(WxRowItem) a = item_with(&s, NY);
  s.hours[0].temp_c = 10;
  s.hours[1].temp_c = 10;
  g_autoptr(WxRowItem) b = item_with(&s, AKL);
  spec_free(&s);

  wx_detail_set_item(pane, a);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  g_assert_cmpstr(T("wx-detail-place"), ==, "New York, New York, United States");
  g_assert_cmpuint(handlers_for(a, pane), ==, 1);

  wx_detail_set_item(pane, b);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "50\xc2\xb0" "F");
  g_assert_cmpstr(T("wx-detail-place"), ==, "Auckland, Auckland, New Zealand");
  g_assert_cmpuint(handlers_for(a, pane), ==, 0);
  g_assert_cmpuint(handlers_for(b, pane), ==, 1);

  /* the old item no longer reaches the pane, the new one does */
  wx_row_item_set_units(a, WX_UNITS_METRIC);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "50\xc2\xb0" "F");
  wx_row_item_set_units(b, WX_UNITS_METRIC);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "10\xc2\xb0" "C");

  wx_detail_set_item(pane, NULL);
  g_assert_cmpuint(handlers_for(b, pane), ==, 0);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  wx_row_item_set_units(b, WX_UNITS_IMPERIAL);
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");

  wx_detail_set_item(pane, a);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
  g_assert_cmpuint(handlers_for(a, pane), ==, 1);
}

static void
test_same_item_only_refreshes(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  wx_detail_set_item(pane, item);
  wx_detail_set_item(pane, item);
  g_assert_cmpuint(handlers_for(item, pane), ==, 1);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
  wx_detail_set_item(pane, NULL);
  g_assert_cmpuint(handlers_for(item, pane), ==, 0);
}

static void
test_item_reference_is_held(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  WxRowItem *item = item_plain(NY);
  WxRowItem *weak = item;
  g_object_add_weak_pointer(G_OBJECT(item), (gpointer *)&weak);
  wx_detail_set_item(pane, item);
  g_object_unref(item); /* the caller's reference: the pane keeps the item alive */
  g_assert_nonnull(weak);
  wx_row_item_set_units(weak, WX_UNITS_METRIC);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
  wx_detail_set_item(pane, NULL);
  g_assert_null(weak); /* the pane held the last reference */
}

static void
test_item_finalised_with_pane(void)
{
  GtkWidget *pane = g_object_ref_sink(wx_detail_new());
  WxRowItem *item = item_plain(NY);
  WxRowItem *weak = item;
  g_object_add_weak_pointer(G_OBJECT(item), (gpointer *)&weak);
  wx_detail_set_item(WX_DETAIL(pane), item);
  g_object_unref(item);
  g_assert_nonnull(weak);
  g_object_unref(pane);
  g_assert_null(weak);
}

static void
test_replaced_item_is_released(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  WxRowItem *a = item_plain(NY);
  WxRowItem *weak = a;
  g_object_add_weak_pointer(G_OBJECT(a), (gpointer *)&weak);
  g_autoptr(WxRowItem) b = item_plain(AKL);
  wx_detail_set_item(pane, a);
  g_object_unref(a);
  g_assert_nonnull(weak);
  wx_detail_set_item(pane, b);
  g_assert_null(weak);
}

static void
unset_item_cb(WxRowItem *item, gpointer data)
{
  (void)item;
  wx_detail_set_item(*(WxDetail **)data, NULL);
}

static void
test_handler_unsets_item_during_emission(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  WxDetail *target = pane;
  /* connected first, so it runs before the pane's own handler */
  g_signal_connect(item, "changed", G_CALLBACK(unset_item_cb), &target);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_cmpstr(page_name(pane), ==, "placeholder");
  g_assert_cmpstr(T("wx-detail-placeholder-title"), ==, "Select a place");
  g_assert_cmpuint(handlers_for(item, pane), ==, 0);
}

static void
unref_pane_cb(WxRowItem *item, gpointer data)
{
  (void)item;
  WxDetail **target = data;
  if (*target != NULL)
    g_object_unref(*target);
  *target = NULL;
}

static void
test_handler_destroys_pane_during_emission(void)
{
  WxDetail *pane = WX_DETAIL(g_object_ref_sink(wx_detail_new()));
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  /* runs after the pane's handler and drops the pane's last reference */
  g_signal_connect(item, "changed", G_CALLBACK(unref_pane_cb), &pane);
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_null(pane);
  wx_row_item_set_units(item, WX_UNITS_IMPERIAL); /* nothing is left that could be called */
}

static void
test_dispose(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  WxRowItem *item = item_plain(NY);
  WxRowItem *weak = item;
  g_object_add_weak_pointer(G_OBJECT(item), (gpointer *)&weak);
  wx_detail_set_item(pane, item);
  g_object_run_dispose(G_OBJECT(pane));
  g_assert_cmpuint(handlers_for(item, pane), ==, 0);

  /* every call after dispose is a no-op: no critical, no reference taken, no handler */
  wx_detail_set_item(pane, item);
  wx_detail_set_item(pane, NULL);
  wx_detail_set_item(pane, item);
  g_assert_cmpuint(handlers_for(item, pane), ==, 0);
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  wx_row_item_set_loading(item, TRUE);
  g_object_run_dispose(G_OBJECT(pane)); /* twice */
  g_object_unref(item);
  g_assert_null(weak);
}

static void
test_dispose_without_item(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_object_run_dispose(G_OBJECT(pane));
  wx_detail_set_item(pane, NULL);
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  g_assert_cmpuint(handlers_for(item, pane), ==, 0);
}

static void
test_window_destroy_with_item(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-temp"));
  hide_window(window);
  wx_row_item_set_units(item, WX_UNITS_METRIC); /* the pane lives on, unparented */
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
}

/* ------------------------------------------------------------------ */
/* Forecast page: the now block                                       */
/* ------------------------------------------------------------------ */

static void
test_now_block_imperial(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  g_assert_cmpstr(T("wx-detail-place"), ==, "New York, New York, United States");
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  g_assert_cmpstr(T("wx-detail-condition"), ==, "Partly cloudy");
  g_assert_cmpstr(T("wx-detail-feels"), ==, "Feels like 75\xc2\xb0");
  /* the fixture's forecast starts at 2 PM: the numbers of today cover only the rest of the day */
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 2 PM)");
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 12 mph, gusts 20 mph" DOT "Humidity 40%");
  g_assert_cmpstr(icon_of(pane), ==, "weather-few-clouds-symbolic");
  g_assert_true(shown(pane, "wx-detail-highlow"));
}

static void
test_now_block_metric_and_toggle(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
  g_assert_cmpstr(T("wx-detail-feels"), ==, "Feels like 24\xc2\xb0");
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 27\xc2\xb0" DOT "Low 16\xc2\xb0 (from 2 PM)");
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 20 km/h, gusts 32 km/h" DOT "Humidity 40%");
  wx_row_item_set_units(item, WX_UNITS_IMPERIAL);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  g_assert_cmpstr(T("wx-detail-feels"), ==, "Feels like 75\xc2\xb0");
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 2 PM)");
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 12 mph, gusts 20 mph" DOT "Humidity 40%");
}

static void
test_units_reach_the_widgets(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-hours"), "temp"), ==,
                  "77\xc2\xb0");
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-days"), "high"), ==,
                  "81\xc2\xb0");
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-hours"), "temp"), ==,
                  "25\xc2\xb0");
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-days"), "high"), ==,
                  "27\xc2\xb0");
  wx_row_item_set_units(item, WX_UNITS_IMPERIAL);
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-hours"), "temp"), ==,
                  "77\xc2\xb0");
}

static void
test_icon_follows_condition_and_daylight(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].condition = WX_COND_THUNDERSTORM;
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-condition"), ==, "Thunderstorm");
  g_assert_cmpstr(icon_of(pane), ==, "weather-storm-symbolic");

  /* 3 AM in New York: night */
  g_autoptr(WxRowItem) night = item_plain(NY);
  wx_row_item_set_now_s(night, T_H0 + 13 * 3600 + 1800);
  wx_detail_set_item(pane, night);
  g_assert_cmpstr(icon_of(pane), ==, "weather-few-clouds-night-symbolic");
  wx_row_item_set_now_s(night, NOW_S);
  g_assert_cmpstr(icon_of(pane), ==, "weather-few-clouds-symbolic");
}

static void
test_gusts_rules(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  s.hours[0].gust_kmh = s.hours[1].gust_kmh = 20; /* equal to the wind: shown */
  g_autoptr(WxRowItem) equal = item_with(&s, NY);
  wx_detail_set_item(pane, equal);
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 12 mph, gusts 12 mph" DOT "Humidity 40%");

  s.hours[0].gust_kmh = s.hours[1].gust_kmh = 10; /* below the wind: left out */
  g_autoptr(WxRowItem) below = item_with(&s, NY);
  wx_detail_set_item(pane, below);
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 12 mph" DOT "Humidity 40%");

  s.hours[0].gust_kmh = s.hours[1].gust_kmh = NAN; /* unknown: left out */
  g_autoptr(WxRowItem) unknown = item_with(&s, NY);
  wx_detail_set_item(pane, unknown);
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind 12 mph" DOT "Humidity 40%");

  s.hours[0].wind_kmh = s.hours[1].wind_kmh = NAN; /* unknown wind: no gusts either */
  s.hours[0].gust_kmh = s.hours[1].gust_kmh = 30;
  s.hours[0].humidity_pct = s.hours[1].humidity_pct = NAN;
  g_autoptr(WxRowItem) nowind = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, nowind);
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind " DASH DOT "Humidity " DASH);
}

static void
test_no_current_conditions(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_row_item_set_now_s(item, T_H0 + 100 * 3600); /* after the hours of the forecast */
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  g_assert_cmpstr(T("wx-detail-temp"), ==, DASH);
  g_assert_cmpstr(T("wx-detail-condition"), ==, "Unknown");
  g_assert_cmpstr(T("wx-detail-feels"), ==, "Feels like " DASH);
  g_assert_cmpstr(T("wx-detail-wind"), ==, "Wind " DASH DOT "Humidity " DASH);
  g_assert_cmpstr(T("wx-detail-cloud-cover"), ==, "Cloud cover " DASH DOT "Unknown");
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Cloud cover unknown");
  g_assert_cmpstr(icon_of(pane), ==, "dialog-question-symbolic");
  g_assert_false(shown(pane, "wx-detail-highlow")); /* no day contains "now" either */
  /* the hours are over: no rain claim at all ("dry" included), and no card of the strip is shown */
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain outlook unavailable");
  g_assert_false(shown(pane, "wx-detail-rain-detail"));
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-hours"), "hour-card"), ==, 0);

  wx_row_item_set_now_s(item, NOW_S);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  g_assert_cmpstr(T("wx-detail-condition"), ==, "Partly cloudy");
  g_assert_true(shown(pane, "wx-detail-highlow"));
}

static void
test_hours_in_the_past(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_row_item_set_now_s(item, T_H0 - 3 * 3600); /* before the forecast starts */
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-temp"), ==, DASH);
  g_assert_cmpstr(T("wx-detail-condition"), ==, "Unknown");
  /* no hour contains "now": nothing is claimed about the rain */
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain outlook unavailable");
}

static void
test_now_outside_valid_range(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  static const gint64 nows[] = { 0, -1, G_MININT64, G_MAXINT64, WX_TIME_MAX_S, WX_TIME_MIN_S - 1 };
  for (guint i = 0; i < G_N_ELEMENTS(nows); i++) {
    wx_row_item_set_now_s(item, nows[i]);
    g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain outlook unavailable");
    g_assert_false(shown(pane, "wx-detail-rain-detail"));
    g_assert_cmpstr(T("wx-detail-temp"), ==, DASH);
    g_assert_cmpstr(page_name(pane), ==, "forecast");
  }
  wx_row_item_set_now_s(item, NOW_S);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "No rain expected for the next 48 hours");
}

/* ------------------------------------------------------------------ */
/* High / low of today                                                */
/* ------------------------------------------------------------------ */

static void
test_highlow_missing_day(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  s.n_days = 0;
  g_autoptr(WxRowItem) none = item_with(&s, NY);
  wx_detail_set_item(pane, none);
  g_assert_false(shown(pane, "wx-detail-highlow"));

  /* only days that are over or still to come */
  s.days[0].start_s = NY_DAY0 - 86400;
  s.n_days = 1;
  spec_add_day(&s, NY_DAY0 + 86400, 20, 10);
  g_autoptr(WxRowItem) other = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, other);
  g_assert_false(shown(pane, "wx-detail-highlow"));
}

static void
test_highlow_unknown_numbers(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  s.days[0].temp_max_c = NAN;
  s.days[0].temp_min_c = NAN;
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_true(shown(pane, "wx-detail-highlow"));
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High " DASH DOT "Low " DASH " (from 2 PM)");
}

static void
test_highlow_day_boundaries(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  /* the day lasts until the next local midnight (04:00Z), whatever the next entry says */
  wx_row_item_set_now_s(item, NY_DAY0 - 1);
  g_assert_false(shown(pane, "wx-detail-highlow"));
  wx_row_item_set_now_s(item, NY_DAY0);
  g_assert_true(shown(pane, "wx-detail-highlow"));
  wx_row_item_set_now_s(item, NY_DAY0 + 86400 - 1);
  g_assert_true(shown(pane, "wx-detail-highlow"));
  wx_row_item_set_now_s(item, NY_DAY0 + 86400);
  g_assert_false(shown(pane, "wx-detail-highlow"));
}

static void
test_highlow_picks_the_day_of_now(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_day(&s, NY_DAY0 + 86400, 20, 10); /* 68 F / 50 F */
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 2 PM)");
  wx_row_item_set_now_s(item, NY_DAY0 + 86400 + 3600);
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 68\xc2\xb0" DOT "Low 50\xc2\xb0");
}

static void
test_highlow_time_zones(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  /* days that begin at New York midnight (04:00Z): 2026-10-12 18:30Z is inside the first one in
   * New York and in UTC, but in Auckland (07:30 on the 13th) that "day" ended at 11:00Z */
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_day(&s, NY_DAY0 + 86400, 20, 10);
  g_autoptr(WxRowItem) ny = item_with(&s, NY);
  g_autoptr(WxRowItem) utc = item_with(&s, "UTC");
  g_autoptr(WxRowItem) akl = item_with(&s, AKL);
  spec_free(&s);
  wx_detail_set_item(pane, ny);
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 2 PM)");
  wx_detail_set_item(pane, utc);
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 6 PM)");
  wx_detail_set_item(pane, akl);
  g_assert_false(shown(pane, "wx-detail-highlow"));

  /* Auckland midnight of the 13th is 11:00Z on the 12th */
  Spec t;
  spec_init(&t, SPEC_HOURS);
  t.days[0].start_s = G_GINT64_CONSTANT(1791802800);
  t.days[0].temp_max_c = 22;
  t.days[0].temp_min_c = 12;
  g_autoptr(WxRowItem) akl2 = item_with(&t, AKL);
  spec_free(&t);
  wx_detail_set_item(pane, akl2);
  g_assert_cmpstr(T("wx-detail-highlow"), ==, "High 72\xc2\xb0" DOT "Low 54\xc2\xb0 (from 7 AM)");
}

/* The label names the hour the numbers start at only when the forecast starts after the day began:
 * the hour before the forecast's first hour must not belong to the day. */
static void
test_highlow_covered_from(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  static const struct {
    gint64 first_off_s; /* the forecast's first hour, after New York midnight of the 12th */
    gint64 now_off_s;
    const char *text;
  } cases[] = {
    {-3600, 1800, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0"},  /* the list began yesterday evening */
    {0, 1800, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0"},      /* the whole day */
    {0, 7200, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0"},
    {3600, 7200, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 1 AM)"}, /* 00:00 is missing */
    {9 * 3600, 10 * 3600 + 1800, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 9 AM)"},
    {13 * 3600, 14 * 3600, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 1 PM)"},
    {22 * 3600, 23 * 3600 + 1800, "High 81\xc2\xb0" DOT "Low 61\xc2\xb0 (from 10 PM)"},
  };
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++) {
    g_test_message("case %u", c);
    Spec s;
    spec_init(&s, SPEC_HOURS);
    for (guint i = 0; i < s.n_hours; i++)
      s.hours[i].t_s = NY_DAY0 + cases[c].first_off_s + (gint64)i * 3600;
    g_autoptr(WxRowItem) item = item_with(&s, NY);
    spec_free(&s);
    wx_row_item_set_now_s(item, NY_DAY0 + cases[c].now_off_s);
    wx_detail_set_item(pane, item);
    g_assert_true(shown(pane, "wx-detail-highlow"));
    g_assert_cmpstr(T("wx-detail-highlow"), ==, cases[c].text);
  }
}

/* ------------------------------------------------------------------ */
/* Rain and clouds                                                    */
/* ------------------------------------------------------------------ */

static void
check_rain(void (*setup)(Spec *), const char *tz, const char *headline, const char *detail)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  setup(&s);
  g_autoptr(WxRowItem) item = item_with(&s, tz);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, headline);
  g_assert_cmpstr(T("wx-detail-rain-detail"), ==, detail);
  g_assert_true(shown(pane, "wx-detail-rain-detail") == (detail[0] != '\0'));
}

static void
setup_dry(Spec *s)
{
  (void)s;
}

static void
setup_now(Spec *s)
{
  spec_wet(s, 0, 1.0, 80);
  spec_wet(s, 1, 1.0, 80);
  spec_wet(s, 2, 1.5, 80);
}

static void
setup_now_peak_past(Spec *s)
{
  spec_wet(s, 0, 1.5, 80);
  spec_wet(s, 1, 1.0, 80);
}

static void
setup_now_unknown_end(Spec *s)
{
  for (guint i = 0; i < s->n_hours; i++)
    spec_wet(s, i, 3.0, 90);
}

static void
setup_soon(Spec *s)
{
  spec_wet(s, 1, 2.0, 70);
  spec_wet(s, 2, 1.0, 70);
}

static void
setup_later_today(Spec *s)
{
  spec_wet(s, 6, 4.0, 60);
}

static void
setup_tomorrow(Spec *s)
{
  spec_wet(s, 20, 8.0, 90);
}

static void
setup_possible(Spec *s)
{
  s->hours[5].precip_prob = 60;
  s->hours[5].precip_mm = 0.05;
}

static void
test_rain_dry(void)
{
  check_rain(setup_dry, NY, "No rain expected for the next 48 hours", "");
}

/* "No rain expected for the next 48 hours" needs a forecast that knows the amounts of those 48
 * hours: with 48 hours from the start of the hour of "now" (half an hour past it) it does not, with
 * 49 it does; an unknown amount inside the horizon does not either. A short forecast that has rain
 * is still reported. */
static void
test_rain_dry_needs_coverage(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  guint sizes[] = { 24, 48, 49 };
  for (guint k = 0; k < G_N_ELEMENTS(sizes); k++) {
    Spec s;
    spec_init(&s, sizes[k]);
    g_autoptr(WxRowItem) item = item_with(&s, NY);
    spec_free(&s);
    wx_detail_set_item(pane, item);
    g_assert_cmpstr(T("wx-detail-rain-headline"), ==,
                    sizes[k] == 49 ? "No rain expected for the next 48 hours"
                                   : "Rain outlook unavailable");
    g_assert_false(shown(pane, "wx-detail-rain-detail"));
  }
  Spec u;
  spec_init(&u, SPEC_HOURS);
  u.hours[40].precip_mm = NAN;
  g_autoptr(WxRowItem) unknown = item_with(&u, NY);
  spec_free(&u);
  wx_detail_set_item(pane, unknown);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain outlook unavailable");

  Spec w;
  spec_init(&w, 6);
  spec_wet(&w, 3, 2.0, 80);
  g_autoptr(WxRowItem) wet = item_with(&w, NY);
  spec_free(&w);
  wx_detail_set_item(pane, wet);
  g_assert_true(g_str_has_prefix(T("wx-detail-rain-headline"), "Rain "));
}

static void
test_rain_now(void)
{
  check_rain(setup_now, NY, "Raining now, easing around 5 PM", "Light rain, heaviest around 4 PM.");
}

static void
test_rain_now_peak_past(void)
{
  check_rain(setup_now_peak_past, NY, "Raining now, easing around 4 PM",
             "Rain peaked around 2 PM (light).");
}

static void
test_rain_now_unknown_end(void)
{
  check_rain(setup_now_unknown_end, NY, "Raining now, expected to continue for hours",
             "Rain peaked around 2 PM (moderate).");
}

static void
test_rain_expected_soon(void)
{
  check_rain(setup_soon, NY, "Rain starting in 30 minutes",
             "Light rain, heaviest around 3 PM. 70% chance of rain.");
}

static void
test_rain_expected_later_today(void)
{
  check_rain(setup_later_today, NY, "Rain expected around 8 PM",
             "Moderate rain, heaviest around 8 PM. 60% chance of rain.");
}

static void
test_rain_expected_tomorrow(void)
{
  check_rain(setup_tomorrow, NY, "Rain expected tomorrow around 10 AM",
             "Heavy rain, heaviest tomorrow around 10 AM. 90% chance of rain.");
}

static void
test_rain_possible(void)
{
  check_rain(setup_possible, NY, "Showers possible around 7 PM (60% chance)",
             "No steady rain in the forecast, just a chance.");
}

static void
test_rain_texts_follow_the_zone(void)
{
  check_rain(setup_now, "UTC", "Raining now, easing around 9 PM",
             "Light rain, heaviest around 8 PM.");
  check_rain(setup_now, AKL, "Raining now, easing around 10 AM",
             "Light rain, heaviest around 9 AM.");
  check_rain(setup_later_today, AKL, "Rain expected around 1 PM",
             "Moderate rain, heaviest around 1 PM. 60% chance of rain.");
  check_rain(setup_tomorrow, AKL, "Rain expected tomorrow around 3 AM",
             "Heavy rain, heaviest tomorrow around 3 AM. 90% chance of rain.");
}

static void
test_rain_updates_with_now(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  setup_soon(&s);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain starting in 30 minutes");
  wx_row_item_set_now_s(item, NOW_S + 600);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Rain starting in 20 minutes");
  wx_row_item_set_now_s(item, NOW_S + 1800);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Raining now, easing around 5 PM");
}

/* the first four quarters from the slot of "now" are wet: 2 mm/h until 19:30Z */
static void
add_quarters(Spec *s, gboolean wet)
{
  for (guint i = 0; i < 8; i++) {
    s->quarters[i].t_s = NOW_S + (gint64)i * 900;
    s->quarters[i].precip_mm = wet && i < 4 ? 0.5 : 0.0;
  }
  s->n_quarters = 8;
}

static void
test_rain_with_nowcast_quarters(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS); /* the hours are dry: only the nowcast knows about the rain */
  add_quarters(&s, TRUE);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  g_autoptr(WxRowItem) utc = item_with(&s, "UTC");
  g_autoptr(WxRowItem) akl = item_with(&s, AKL);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Raining now, easing around 3:30 PM");
  g_assert_cmpstr(T("wx-detail-rain-detail"), ==, "Rain peaked around 2:30 PM (light).");
  wx_detail_set_item(pane, utc);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Raining now, easing around 7:30 PM");
  g_assert_cmpstr(T("wx-detail-rain-detail"), ==, "Rain peaked around 6:30 PM (light).");
  wx_detail_set_item(pane, akl);
  g_assert_cmpstr(T("wx-detail-rain-headline"), ==, "Raining now, easing around 8:30 AM");
  g_assert_cmpstr(T("wx-detail-rain-detail"), ==, "Rain peaked around 7:30 AM (light).");
}

static void
test_chart_views(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].precip_prob = 20;
  setup_soon(&s);
  g_autoptr(WxRowItem) hourly = item_with(&s, NY);
  add_quarters(&s, TRUE);
  g_autoptr(WxRowItem) quarters = item_with(&s, NY);
  spec_free(&s);

  /* no nowcast: the 24 hour chart with its chance line, nothing else */
  wx_detail_set_item(pane, hourly);
  GtkWidget *window = show_in_window(pane);
  Counts c = chart_counts(pane);
  g_assert_cmpuint(c.text, >, 0);   /* the time axis */
  g_assert_cmpuint(c.color, >, 0);  /* grid and bars */
  g_assert_cmpuint(c.stroke, >, 0); /* the chance line of the hourly view */
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-chart"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-chart-caption"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast-caption"));
  g_assert_cmpstr(T("wx-detail-rain-chart-caption"), ==, "Next 24 hours");
  int alone = gtk_widget_get_width(find(pane, "wx-detail-rain-chart"));

  /* with a nowcast: BOTH charts; the 24 hour chance chart does not go away (it used to be
   * replaced by the 15-minute bars), and the two share the width */
  wx_detail_set_item(pane, quarters);
  settle();
  c = chart_counts(pane);
  g_assert_cmpuint(c.color, >, 0);
  g_assert_cmpuint(c.stroke, >, 0);
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast-caption"));
  g_assert_cmpstr(T("wx-detail-rain-nowcast-caption"), ==, "Next 2 hours");
  c = nowcast_counts(pane);
  g_assert_cmpuint(c.color, >, 0);
  g_assert_cmpuint(c.stroke, ==, 0); /* the 15-minute view has no chance line */
  int both = gtk_widget_get_width(find(pane, "wx-detail-rain-chart"));
  int nowcast_w = gtk_widget_get_width(find(pane, "wx-detail-rain-nowcast"));
  g_assert_cmpint(abs(both - nowcast_w), <=, 1);
  g_assert_cmpint(both, <, alone);
  g_assert_cmpint(abs(2 * both + 16 - alone), <=, 1); /* two columns and the 16 px gap */

  /* and back */
  wx_detail_set_item(pane, hourly);
  settle();
  g_assert_cmpuint(chart_counts(pane).stroke, >, 0);
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast"));
  g_assert_cmpint(gtk_widget_get_width(find(pane, "wx-detail-rain-chart")), ==, alone);

  /* a nowcast that is over: "now" after its last quarter hides the nowcast chart again, the
   * hours still give the 24 hour chart */
  wx_detail_set_item(pane, quarters);
  settle();
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast"));
  wx_row_item_set_now_s(quarters, NOW_S + 3 * 3600);
  settle();
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-nowcast"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-chart"));
  g_assert_cmpuint(chart_counts(pane).stroke, >, 0);
  hide_window(window);
}

static void
test_chart_follows_item_changes(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].precip_prob = 20;
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_assert_cmpuint(chart_counts(pane).stroke, >, 0);

  /* "now" far after the data: the chart has nothing to show */
  wx_row_item_set_now_s(item, T_H0 + 200 * 3600);
  settle();
  Counts c = chart_counts(pane);
  g_assert_cmpuint(c.color, ==, 0);
  g_assert_cmpuint(c.stroke, ==, 0);
  g_assert_cmpuint(c.text, ==, 1); /* "No data" */

  wx_row_item_set_now_s(item, NOW_S);
  settle();
  g_assert_cmpuint(chart_counts(pane).stroke, >, 0);
  hide_window(window);
}

static void
test_chart_cleared_without_forecast(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_assert_cmpuint(chart_counts(pane).color, >, 0);
  wx_row_item_set_forecast(item, NULL, 0);
  wx_detail_set_item(pane, NULL);
  settle();
  /* the forecast page is hidden now, but the widgets dropped their data: show it again with an
   * item without forecast to look at the chart */
  gtk_stack_set_visible_child_name(GTK_STACK(find(pane, "wx-detail-stack")), "forecast");
  settle();
  Counts c = chart_counts(pane);
  g_assert_cmpuint(c.color, ==, 0);
  g_assert_cmpuint(c.text, ==, 1);
  hide_window(window);
}

static void
test_cloud_texts(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(T("wx-detail-cloud-cover"), ==, "Cloud cover 50%" DOT "Partly cloudy");
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Partly cloudy for the next 24 hours");

  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].cloud_pct = i < 3 ? 95 : 5;
  g_autoptr(WxRowItem) clearing = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, clearing);
  g_assert_cmpstr(T("wx-detail-cloud-cover"), ==, "Cloud cover 95%" DOT "Overcast");
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Overcast now, clearing around 5 PM");

  /* unknown cloud cover in the hour of "now" */
  Spec t;
  spec_init(&t, SPEC_HOURS);
  t.hours[0].cloud_pct = t.hours[1].cloud_pct = NAN;
  g_autoptr(WxRowItem) unknown = item_with(&t, NY);
  spec_free(&t);
  wx_detail_set_item(pane, unknown);
  g_assert_cmpstr(T("wx-detail-cloud-cover"), ==, "Cloud cover " DASH DOT "Unknown");
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Cloud cover unknown");
}

static void
test_cloud_sentence_follows_the_zone(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < s.n_hours; i++)
    s.hours[i].cloud_pct = i < 3 ? 95 : 5;
  g_autoptr(WxRowItem) ny = item_with(&s, NY);
  g_autoptr(WxRowItem) akl = item_with(&s, AKL);
  spec_free(&s);
  wx_detail_set_item(pane, ny);
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Overcast now, clearing around 5 PM");
  wx_detail_set_item(pane, akl);
  g_assert_cmpstr(T("wx-detail-cloud-sentence"), ==, "Overcast now, clearing around 10 AM");
}

/* ------------------------------------------------------------------ */
/* Hours and days                                                     */
/* ------------------------------------------------------------------ */

static void
test_hours_and_days_are_fed(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, 100);
  for (guint i = 1; i < 4; i++)
    spec_add_day(&s, NY_DAY0 + (gint64)i * 86400, 20, 10);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-hours"), "hour-card"), ==,
                   WX_HOUR_STRIP_MAX_CARDS);
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-days"), "day-row"), ==, 4);
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-hours"), "hour"), ==, "Now");
  g_assert_cmpstr(first_label_with_class(find(pane, "wx-detail-days"), "day"), ==, "Today");

  wx_row_item_set_now_s(item, T_H0 + 90 * 3600); /* ten hours left */
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-hours"), "hour-card"), ==, 10);
  wx_detail_set_item(pane, NULL);
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-hours"), "hour-card"), ==, 0);
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-days"), "day-row"), ==, 0);
}

/* ------------------------------------------------------------------ */
/* Badges                                                             */
/* ------------------------------------------------------------------ */

static void
test_badges_and_tooltips(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  GtkWidget *offline = find(pane, "wx-detail-badge-offline");
  GtkWidget *stale = find(pane, "wx-detail-badge-stale");
  g_assert_cmpstr(T("wx-detail-badge-offline"), ==, "Offline");
  g_assert_cmpstr(T("wx-detail-badge-stale"), ==, "Stale");
  g_assert_false(gtk_widget_get_visible(offline));
  g_assert_false(gtk_widget_get_visible(stale));

  wx_row_item_set_offline(item, TRUE);
  g_assert_true(gtk_widget_get_visible(offline));
  g_assert_false(gtk_widget_get_visible(stale));
  g_assert_cmpstr(gtk_widget_get_tooltip_text(offline), ==,
                  "No network connection: showing the last forecast");

  wx_row_item_set_stale(item, TRUE); /* both flags: offline wins */
  g_assert_true(gtk_widget_get_visible(offline));
  g_assert_false(gtk_widget_get_visible(stale));

  wx_row_item_set_offline(item, FALSE);
  g_assert_false(gtk_widget_get_visible(offline));
  g_assert_true(gtk_widget_get_visible(stale));
  g_assert_cmpstr(gtk_widget_get_tooltip_text(stale), ==, "The last refresh failed");

  wx_row_item_set_error(item, "HTTP 503");
  g_assert_cmpstr(gtk_widget_get_tooltip_text(stale), ==, "The last refresh failed: HTTP 503");
  wx_row_item_set_error(item, "<b>x</b> & y");
  g_assert_cmpstr(gtk_widget_get_tooltip_text(stale), ==,
                  "The last refresh failed: <b>x</b> & y");
  wx_row_item_set_error(item, NULL);
  g_assert_cmpstr(gtk_widget_get_tooltip_text(stale), ==, "The last refresh failed");

  wx_row_item_set_stale(item, FALSE);
  g_assert_false(gtk_widget_get_visible(offline));
  g_assert_false(gtk_widget_get_visible(stale));
}

/* ------------------------------------------------------------------ */
/* Footer                                                             */
/* ------------------------------------------------------------------ */

static void
check_updated(WxDetail *pane, WxRowItem *item, WxForecast *f, gint64 fetched_s, const char *text)
{
  wx_row_item_set_forecast(item, f, fetched_s);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, text);
}

static void
test_updated_texts(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  Spec s;
  spec_init(&s, SPEC_HOURS);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  check_updated(pane, item, f, NOW_S, "Updated just now");
  check_updated(pane, item, f, NOW_S - 59, "Updated just now");
  check_updated(pane, item, f, NOW_S - 60, "Updated 1 min ago");
  check_updated(pane, item, f, NOW_S - 600, "Updated 10 min ago");
  check_updated(pane, item, f, NOW_S - 3600, "Updated 1 h ago");
  check_updated(pane, item, f, NOW_S - 7200 - 59, "Updated 2 h ago");
  check_updated(pane, item, f, NOW_S - 86400, "Updated 1 day ago");
  check_updated(pane, item, f, NOW_S - 40 * 86400, "Updated over a month ago");
  check_updated(pane, item, f, NOW_S + 100, "Updated just now");
  check_updated(pane, item, f, NOW_S + 100 * 86400, "Updated just now");
  check_updated(pane, item, f, -5, "Updated over a month ago");
  check_updated(pane, item, f, 0, "Updated over a month ago");
  check_updated(pane, item, f, G_MININT64, "Updated over a month ago");
  check_updated(pane, item, f, G_MAXINT64, "Updated just now");
  check_updated(pane, item, f, NOW_S - 120, "Updated 2 min ago");
}

static void
test_updated_extreme_now(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  Spec s;
  spec_init(&s, SPEC_HOURS);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  g_autoptr(WxRowItem) item = item_new(place);
  wx_detail_set_item(pane, item);
  wx_row_item_set_forecast(item, f, -1);
  wx_row_item_set_now_s(item, G_MAXINT64); /* the difference does not fit a gint64 */
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated over a month ago");
  wx_row_item_set_forecast(item, f, G_MININT64);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated over a month ago");
  wx_row_item_set_now_s(item, G_MININT64);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated just now");
  wx_row_item_set_forecast(item, f, G_MAXINT64);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated just now");
  wx_row_item_set_now_s(item, G_MAXINT64);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated just now");
  g_assert_cmpstr(page_name(pane), ==, "forecast");
}

static void
test_updated_follows_now_only(void)
{
  /* the age comes from the item's "now" and fetch time, never from the clock: a "now" years
   * away from the real time gives the same texts */
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  const gint64 far = G_GINT64_CONSTANT(2000000000); /* 2033-05-18 */
  wx_row_item_set_forecast(item, wx_row_item_get_forecast(item), far - 300);
  wx_row_item_set_now_s(item, far);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated 5 min ago");
  wx_row_item_set_now_s(item, far + 3600);
  g_assert_cmpstr(FOOTER_UPDATED(pane), ==, "Updated 1 h ago");
}

static void
test_sources_list(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) none = item_plain(NY);
  wx_detail_set_item(pane, none);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: none");
  g_assert_true(shown(pane, "wx-detail-footer"));
  g_assert_false(shown(pane, "wx-detail-attribution"));
  g_assert_false(shown(pane, "wx-detail-partial"));

  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                  "https://open-meteo.com/", WX_SRC_OK);
  spec_add_source(&s, "nws", "National Weather Service", "Source: NOAA/National Weather Service",
                  "https://www.weather.gov/", WX_SRC_FAILED);
  spec_add_source(&s, "met-no", "MET Norway", "Data from MET Norway", "https://api.met.no/",
                  WX_SRC_OK);
  spec_add_source(&s, "other", "Skipped One", "never shown", "https://example.org/",
                  WX_SRC_SKIPPED);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: Open-Meteo, MET Norway");
  g_assert_cmpstr(T("wx-detail-partial"), ==, "Not available right now: National Weather Service");
  g_assert_true(shown(pane, "wx-detail-partial"));
  wx_detail_set_item(pane, none);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: none");
  g_assert_false(shown(pane, "wx-detail-partial"));
}

static void
test_sources_only_failed_or_skipped(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "a", "Alpha", "Alpha data", "https://a.example/", WX_SRC_FAILED);
  spec_add_source(&s, "b", "Beta", "Beta data", "https://b.example/", WX_SRC_FAILED);
  spec_add_source(&s, "c", "Gamma", "Gamma data", "https://c.example/", WX_SRC_SKIPPED);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: none");
  g_assert_cmpstr(T("wx-detail-partial"), ==, "Not available right now: Alpha, Beta");
  g_assert_false(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==, "");
}

/* Design 9: the footer is "Updated ... · Sources: A, B" in ONE label, with the refresh spinner
 * and the Stale / Offline badges in the same row and the attribution links below it. */
static void
test_footer_is_one_row_with_the_badges(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                  "https://open-meteo.com/", WX_SRC_OK);
  spec_add_source(&s, "met-no", "MET Norway", "Data from MET Norway", "https://api.met.no/",
                  WX_SRC_OK);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  const gint64 far = G_GINT64_CONSTANT(2000000000);
  wx_row_item_set_forecast(item, wx_row_item_get_forecast(item), far - 300);
  wx_row_item_set_now_s(item, far);
  g_assert_cmpstr(T("wx-detail-footer"), ==,
                  "Updated 5 min ago \xC2\xB7 Sources: Open-Meteo, MET Norway");
  GtkWidget *row = gtk_widget_get_parent(find(pane, "wx-detail-footer"));
  g_assert_true(gtk_widget_get_parent(find(pane, "wx-detail-refreshing")) == row);
  g_assert_true(gtk_widget_get_parent(find(pane, "wx-detail-badge-offline")) == row);
  g_assert_true(gtk_widget_get_parent(find(pane, "wx-detail-badge-stale")) == row);
  g_assert_true(gtk_widget_get_parent(find(pane, "wx-detail-place")) != row);
  g_assert_true(gtk_widget_get_parent(find(pane, "wx-detail-attribution")) ==
                gtk_widget_get_parent(row));
  g_assert_null(wxt_find_named(GTK_WIDGET(pane), "wx-detail-updated"));
  g_assert_null(wxt_find_named(GTK_WIDGET(pane), "wx-detail-sources"));
  /* the badges of the row follow the item */
  g_assert_false(shown(pane, "wx-detail-badge-stale"));
  wx_row_item_set_stale(item, TRUE);
  g_assert_true(shown(pane, "wx-detail-badge-stale"));
  wx_row_item_set_offline(item, TRUE);
  g_assert_true(shown(pane, "wx-detail-badge-offline"));
  g_assert_false(shown(pane, "wx-detail-badge-stale"));
}

static void
test_source_without_name_uses_its_id(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "", "Weather data", "", WX_SRC_OK);
  spec_add_source(&s, "nws", "\x01\x02", "", "", WX_SRC_FAILED);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: open-meteo");
  g_assert_cmpstr(T("wx-detail-partial"), ==, "Not available right now: nws");
}

static void
test_attribution_link(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                  "https://open-meteo.com/", WX_SRC_OK);
  spec_add_source(&s, "nws", "NWS", "Source: NOAA/National Weather Service",
                  "https://www.weather.gov/", WX_SRC_FAILED);
  spec_add_source(&s, "met-no", "MET Norway", "Data from MET Norway", "", WX_SRC_OK);
  spec_add_source(&s, "q", "Query", "Has a query", "https://example.org/a?x=1&y=2&z='3'",
                  WX_SRC_OK);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  GtkWidget *label = find(pane, "wx-detail-attribution");
  g_assert_true(gtk_label_get_use_markup(GTK_LABEL(label)));
  g_assert_true(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "<a href=\"https://open-meteo.com/\">Weather data by Open-Meteo.com</a>" DOT
                  "Data from MET Norway" DOT
                  "<a href=\"https://example.org/a?x=1&amp;y=2&amp;z=&apos;3&apos;\">Has a "
                  "query</a>");
  g_assert_cmpstr(T("wx-detail-attribution"), ==,
                  "Weather data by Open-Meteo.com" DOT "Data from MET Norway" DOT "Has a query");
}

/* Replaces the attribution URL of source @i of @f in place (a hand-built forecast: the
 * constructor itself refuses such URLs). */
static void
set_source_url(WxForecast *f, guint i, const char *url)
{
  g_assert_cmpuint(i, <, f->n_sources);
  WxSourceStatus *s = (WxSourceStatus *)&f->sources[i];
  g_free(s->attribution_url);
  s->attribution_url = g_strdup(url);
}

static void
set_source_text(WxForecast *f, guint i, const char *name, const char *attribution)
{
  g_assert_cmpuint(i, <, f->n_sources);
  WxSourceStatus *s = (WxSourceStatus *)&f->sources[i];
  g_free(s->name);
  s->name = g_strdup(name);
  g_free(s->attribution);
  s->attribution = g_strdup(attribution);
}

static WxRowItem *
item_with_hand_built_source(const char *url, const char *name, const char *attribution)
{
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data", "https://open-meteo.com/",
                  WX_SRC_OK);
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  if (url != NULL)
    set_source_url(f, 0, url);
  if (name != NULL)
    set_source_text(f, 0, name, attribution);
  WxRowItem *item = item_new(place);
  wx_row_item_set_forecast(item, f, NOW_S - 120);
  return item;
}

static void
test_attribution_rejects_hostile_urls(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autofree char *pad = g_strnfill(WX_SOURCE_URL_MAX + 1 - strlen("https://e.example/"), 'a');
  g_autofree char *too_long = g_strconcat("https://e.example/", pad, NULL);
  g_assert_cmpuint(strlen(too_long), ==, WX_SOURCE_URL_MAX + 1);
  static const char *const bad[] = {
    "javascript:alert(1)",
    "http://open-meteo.com/",
    "HTTPS://open-meteo.com/",
    "ftp://open-meteo.com/",
    "file:///etc/passwd",
    "//open-meteo.com/",
    "open-meteo.com",
    "https://",
    "https://open meteo.com/",
    "https://open-meteo.com/a b",
    "https://open-meteo.com/\tx",
    "https://open-meteo.com/\nx",
    "https://open-meteo.com/\x7f",
    "https://open-meteo.com/<b>",
    "https://open-meteo.com/>x",
    "https://open-meteo.com/\"onclick=\"x",
    "https://open-meteo.com/\xff",
    " https://open-meteo.com/",
  };
  for (guint i = 0; i <= G_N_ELEMENTS(bad); i++) {
    const char *url = i < G_N_ELEMENTS(bad) ? bad[i] : too_long;
    g_autoptr(WxRowItem) item = item_with_hand_built_source(url, NULL, NULL);
    wx_detail_set_item(pane, item);
    if (g_strcmp0(markup_of(pane, "wx-detail-attribution"), "Weather data") != 0)
      g_error("URL %u was linked: %s", i, markup_of(pane, "wx-detail-attribution"));
    g_assert_cmpstr(T("wx-detail-attribution"), ==, "Weather data");
    g_assert_true(shown(pane, "wx-detail-attribution"));
  }
}

static void
test_attribution_url_length_limit(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autofree char *pad = g_strnfill(WX_SOURCE_URL_MAX - strlen("https://e.example/"), 'a');
  g_autofree char *url = g_strconcat("https://e.example/", pad, NULL);
  g_assert_cmpuint(strlen(url), ==, WX_SOURCE_URL_MAX);
  g_autoptr(WxRowItem) item = item_with_hand_built_source(url, NULL, NULL);
  wx_detail_set_item(pane, item);
  g_autofree char *expected = g_strconcat("<a href=\"", url, "\">Weather data</a>", NULL);
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==, expected);
  g_assert_cmpstr(T("wx-detail-attribution"), ==, "Weather data");
}

static void
test_attribution_hand_built_link_is_escaped(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_with_hand_built_source("https://e.example/?a=1&b=2", NULL, NULL);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "<a href=\"https://e.example/?a=1&amp;b=2\">Weather data</a>");
}

static void
test_attribution_without_text_is_skipped(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "a", "Alpha", "", "https://a.example/", WX_SRC_OK);
  g_autoptr(WxRowItem) only_empty = item_with(&s, NY);
  spec_add_source(&s, "b", "Beta", "Beta data", "https://b.example/", WX_SRC_OK);
  spec_add_source(&s, "c", "Gamma", "\x01", "https://c.example/", WX_SRC_OK);
  g_autoptr(WxRowItem) mixed = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, only_empty);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: Alpha");
  g_assert_false(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==, "");
  wx_detail_set_item(pane, mixed);
  g_assert_true(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: Alpha, Beta, Gamma");
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "<a href=\"https://b.example/\">Beta data</a>");
}

static void
count_changed(WxRowItem *item, gpointer data)
{
  (void)item;
  (*(guint *)data)++;
}

static void
test_item_is_not_mutated(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_row_item_set_stale(item, TRUE);
  wx_row_item_set_offline(item, TRUE);
  wx_row_item_set_loading(item, TRUE);
  wx_row_item_set_error(item, "Oops");
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  guint changed = 0;
  g_signal_connect(item, "changed", G_CALLBACK(count_changed), &changed);
  WxForecast *forecast = wx_row_item_get_forecast(item);
  wx_detail_set_item(pane, item);
  wx_detail_set_item(pane, item);
  wx_row_item_set_units(item, WX_UNITS_IMPERIAL);
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  guint after_user_changes = changed;
  wx_detail_set_item(pane, NULL);
  g_assert_cmpuint(after_user_changes, ==, 2); /* only the two calls above emitted */
  g_assert_cmpuint(changed, ==, 2);
  g_assert_true(wx_row_item_get_forecast(item) == forecast);
  g_assert_cmpint(wx_row_item_get_fetched_s(item), ==, NOW_S - 120);
  g_assert_cmpint(wx_row_item_get_now_s(item), ==, NOW_S);
  g_assert_true(wx_row_item_get_loading(item));
  g_assert_true(wx_row_item_get_stale(item));
  g_assert_true(wx_row_item_get_offline(item));
  g_assert_cmpstr(wx_row_item_get_error(item), ==, "Oops");
  g_assert_cmpint(wx_row_item_get_units(item), ==, WX_UNITS_METRIC);
}

static void
test_hostile_names_and_attributions_are_literal(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "a", "<b>&amp;\"", "<i>x</i> & \"<a href='y'>", "https://a.example/",
                  WX_SRC_OK);
  spec_add_source(&s, "b", "%s%n</span>", "&#x41; &lt;", "", WX_SRC_FAILED);
  spec_add_source(&s, "c", "<big>", "&lt;/a>", "", WX_SRC_OK);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  /* the plain labels show the text literally, the markup label shows it literally too (its text
   * is the unescaped attribution) and no markup error was reported (the harness aborts on any
   * warning) */
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, "Sources: <b>&amp;\", <big>");
  g_assert_cmpstr(T("wx-detail-partial"), ==, "Not available right now: %s%n</span>");
  g_assert_cmpstr(T("wx-detail-attribution"), ==,
                  "<i>x</i> & \"<a href='y'>" DOT "&lt;/a>");
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "<a href=\"https://a.example/\">&lt;i&gt;x&lt;/i&gt; &amp; &quot;&lt;a "
                  "href=&apos;y&apos;&gt;</a>" DOT "&amp;lt;/a&gt;");
}

static void
test_invalid_utf8_in_hand_built_names(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item =
      item_with_hand_built_source(NULL, "bad\xff\xfe" "name\x01", "attr\xc3(\x1b[1m");
  wx_detail_set_item(pane, item);
  const char *sources = FOOTER_SOURCES(pane);
  g_assert_true(g_str_has_prefix(sources, "Sources: bad"));
  g_assert_true(g_utf8_validate(sources, -1, NULL));
  g_assert_true(strchr(sources, '\x01') == NULL);
  const char *attribution = T("wx-detail-attribution");
  g_assert_true(g_utf8_validate(attribution, -1, NULL));
  g_assert_true(g_str_has_prefix(attribution, "attr"));
  g_assert_true(shown(pane, "wx-detail-attribution"));
}

static void
test_sixteen_sources(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  GString *names = g_string_new("Sources: ");
  GString *partial = g_string_new("Not available right now: ");
  GString *attribution = g_string_new(NULL);
  guint ok = 0, failed = 0;
  for (guint i = 0; i < WX_FORECAST_MAX_SOURCES; i++) {
    g_autofree char *id = g_strdup_printf("src%u", i);
    g_autofree char *name = g_strdup_printf("Source %u", i);
    g_autofree char *attr = g_strdup_printf("Data %u", i);
    g_autofree char *url = g_strdup_printf("https://s%u.example/", i);
    WxSourceState st = i % 3 == 0 ? WX_SRC_FAILED : (i % 3 == 1 ? WX_SRC_OK : WX_SRC_SKIPPED);
    spec_add_source(&s, id, name, attr, url, st);
    if (st == WX_SRC_OK) {
      g_string_append_printf(names, "%s%s", ok++ ? ", " : "", name);
      g_string_append_printf(attribution, "%s<a href=\"%s\">%s</a>", ok > 1 ? DOT : "", url, attr);
    } else if (st == WX_SRC_FAILED) {
      g_string_append_printf(partial, "%s%s", failed++ ? ", " : "", name);
    }
  }
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  g_assert_cmpstr(FOOTER_SOURCES(pane), ==, names->str);
  g_assert_cmpstr(T("wx-detail-partial"), ==, partial->str);
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==, attribution->str);
  g_string_free(names, TRUE);
  g_string_free(partial, TRUE);
  g_string_free(attribution, TRUE);
}

static void
test_long_names_are_bounded(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autofree char *big = g_strnfill(WX_SOURCE_TEXT_MAX, 'N');
  Spec s;
  spec_init(&s, SPEC_HOURS);
  for (guint i = 0; i < WX_FORECAST_MAX_SOURCES; i++) {
    g_autofree char *id = g_strdup_printf("src%u", i);
    spec_add_source(&s, id, big, big, "https://s.example/", i % 2 ? WX_SRC_OK : WX_SRC_FAILED);
  }
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_assert_cmpuint(strlen(FOOTER_SOURCES(pane)), ==,
                   strlen("Sources: ") + 8 * WX_SOURCE_TEXT_MAX + 7 * strlen(", "));
  hide_window(window);
}

/* ------------------------------------------------------------------ */
/* Compare before set                                                 */
/* ------------------------------------------------------------------ */

/* The properties the pane itself sets: texts, icon, visibility, tooltips, spinners, the stack page.
 * Notifications of anything else are GTK's own doing (the opacity of an overlay scrollbar that
 * fades after the layout, adjustment values, ...: they depend on the locale and the layout
 * direction) and say nothing about whether the pane compares before it sets. */
static const char *const pane_properties[] = {
  "label", "icon-name", "visible", "tooltip-text", "tooltip-markup", "spinning", "use-markup",
  "visible-child-name", "visible-child",
};

static void
count_notify(GObject *object, GParamSpec *pspec, gpointer data)
{
  (void)object;
  for (guint i = 0; i < G_N_ELEMENTS(pane_properties); i++) {
    if (strcmp(pspec->name, pane_properties[i]) == 0) {
      (*(guint *)data)++;
      return;
    }
  }
}

static void
connect_counter(GtkWidget *w, gpointer data)
{
  g_signal_connect(w, "notify", G_CALLBACK(count_notify), data);
}

static void
disconnect_counter(GtkWidget *w, gpointer data)
{
  g_signal_handlers_disconnect_by_data(w, data);
}

static void
test_unchanged_refresh_changes_nothing(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  setup_soon(&s);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                  "https://open-meteo.com/", WX_SRC_OK);
  spec_add_source(&s, "nws", "NWS", "NWS data", "", WX_SRC_FAILED);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_row_item_set_stale(item, TRUE);
  wx_row_item_set_error(item, "HTTP 503");
  wx_row_item_set_loading(item, TRUE);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);

  guint notifications = 0;
  walk(GTK_WIDGET(pane), connect_counter, &notifications);
  const char *markup_before = markup_of(pane, "wx-detail-attribution");
  g_assert_cmpstr(markup_before, !=, "");
  wx_detail_set_item(pane, item);
  /* a "changed" signal without any change of what is shown */
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  wx_row_item_set_units(item, WX_UNITS_IMPERIAL);
  guint after_toggle = notifications;
  notifications = 0;
  wx_detail_set_item(pane, item);
  wx_detail_set_item(pane, item);
  settle();
  g_assert_cmpuint(notifications, ==, 0);
  g_assert_true(markup_of(pane, "wx-detail-attribution") == markup_before);
  g_assert_cmpuint(after_toggle, >, 0); /* the unit toggle did change things */
  walk(GTK_WIDGET(pane), disconnect_counter, &notifications);
  hide_window(window);
}

static void
test_irrelevant_change_changes_nothing(void)
{
  /* a new "now" one second later: no text of the pane changes (the hour and the rain countdown
   * stay) */
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_autofree char *temp = g_strdup(T("wx-detail-temp"));
  guint notifications = 0;
  GtkWidget *icon = find(pane, "wx-detail-icon");
  GtkWidget *place = find(pane, "wx-detail-place");
  GtkWidget *wind = find(pane, "wx-detail-wind");
  connect_counter(icon, &notifications);
  connect_counter(place, &notifications);
  connect_counter(wind, &notifications);
  wx_row_item_set_now_s(item, NOW_S + 1);
  g_assert_cmpuint(notifications, ==, 0);
  g_assert_cmpstr(T("wx-detail-temp"), ==, temp);
  disconnect_counter(icon, &notifications);
  disconnect_counter(place, &notifications);
  disconnect_counter(wind, &notifications);
  hide_window(window);
}

static void
test_attribution_markup_cache(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "open-meteo", "Open-Meteo", "Weather data by Open-Meteo.com",
                  "https://open-meteo.com/", WX_SRC_OK);
  g_autoptr(WxRowItem) item = item_with(&s, NY);
  spec_free(&s);
  wx_detail_set_item(pane, item);
  GtkWidget *label = find(pane, "wx-detail-attribution");
  guint notifications = 0;
  connect_counter(label, &notifications);
  const char *before = markup_of(pane, "wx-detail-attribution");
  wx_row_item_set_loading(item, TRUE);
  wx_row_item_set_loading(item, FALSE);
  wx_row_item_set_now_s(item, NOW_S + 60);
  wx_detail_set_item(pane, item);
  g_assert_true(markup_of(pane, "wx-detail-attribution") == before);
  g_assert_cmpuint(notifications, ==, 0);

  /* a different forecast with other attribution does rewrite it */
  g_autoptr(WxRowItem) other = item_plain(NY);
  wx_detail_set_item(pane, other);
  g_assert_false(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==, "");
  wx_detail_set_item(pane, item);
  g_assert_true(shown(pane, "wx-detail-attribution"));
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "<a href=\"https://open-meteo.com/\">Weather data by Open-Meteo.com</a>");
  disconnect_counter(label, &notifications);
}

/* ------------------------------------------------------------------ */
/* Big data, zones, window                                            */
/* ------------------------------------------------------------------ */

static void
test_huge_forecast(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec *s = g_new0(Spec, 1);
  spec_init(s, WX_FORECAST_MAX_HOURS);
  for (guint i = 0; i < WX_FORECAST_MAX_HOURS; i++)
    spec_wet(s, i, i % 5 == 0 ? 0 : 1.5, 70);
  for (guint i = 0; i < WX_FORECAST_MAX_QUARTERS; i++) {
    s->quarters[i].t_s = NOW_S - 900 * 100 + (gint64)i * 900;
    s->quarters[i].precip_mm = i % 3 ? 0.2 : 0;
  }
  s->n_quarters = WX_FORECAST_MAX_QUARTERS;
  for (guint i = 1; i < WX_FORECAST_MAX_DAYS; i++)
    spec_add_day(s, NY_DAY0 + (gint64)i * 86400, 20, 10);
  for (guint i = 0; i < WX_FORECAST_MAX_SOURCES; i++) {
    g_autofree char *id = g_strdup_printf("src%u", i);
    spec_add_source(s, id, id, id, "https://s.example/", i % 2 ? WX_SRC_OK : WX_SRC_FAILED);
  }
  g_autoptr(WxRowItem) item = item_with(s, NY);
  spec_free(s);
  g_free(s);
  wx_detail_set_item(pane, item);
  GtkWidget *window = show_in_window(pane);
  g_assert_cmpstr(page_name(pane), ==, "forecast");
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-hours"), "hour-card"), ==, 48);
  g_assert_cmpuint(visible_with_class(find(pane, "wx-detail-days"), "day-row"), ==,
                   WX_DAY_LIST_MAX_ROWS);
  g_assert_cmpstr(T("wx-detail-temp"), ==, "77\xc2\xb0" "F");
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  wx_row_item_set_now_s(item, NOW_S + 7 * 3600);
  settle();
  g_assert_cmpstr(T("wx-detail-temp"), ==, "25\xc2\xb0" "C");
  hide_window(window);
}

static void
test_window_layout_all_states(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxRowItem) loading = item_new(place);
  wx_row_item_set_loading(loading, TRUE);
  g_autoptr(WxRowItem) error = item_new(place);
  wx_row_item_set_error(error, "Network error");
  g_autoptr(WxRowItem) offline = item_new(place);
  wx_row_item_set_offline(offline, TRUE);
  g_autoptr(WxRowItem) full = item_plain(NY);
  wx_row_item_set_offline(full, TRUE);
  wx_row_item_set_stale(full, TRUE);
  wx_row_item_set_loading(full, TRUE);

  GtkWidget *window = show_in_window(pane);
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-placeholder-title"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-temp"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-spinner"));

  WxRowItem *items[] = { loading, error, offline, full, NULL };
  for (guint i = 0; i < G_N_ELEMENTS(items); i++) {
    wx_detail_set_item(pane, items[i]);
    settle();
  }
  wx_detail_set_item(pane, loading);
  settle();
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-spinner"));
  wx_detail_set_item(pane, full);
  settle();
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-temp"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-badge-offline"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-badge-stale"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-refreshing"));
  g_assert_false(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-placeholder-title"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-rain-chart"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-days"));
  hide_window(window);
}

static void
test_window_hostile_data(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  Spec s;
  spec_init(&s, SPEC_HOURS);
  spec_add_source(&s, "a", "<b>&amp;\"", "<i>x</i> & \"", "https://a.example/", WX_SRC_OK);
  g_autoptr(WxPlace) place = place_new(NY);
  g_autoptr(WxForecast) f = spec_forecast(&s, place);
  spec_free(&s);
  set_source_url(f, 0, "https://a.example/?q=\"><script>");
  g_autoptr(WxRowItem) item = item_new(place);
  wx_row_item_set_forecast(item, f, NOW_S - 90);
  wx_row_item_set_error(item, "<span foreground='red'>&</span>");
  wx_row_item_set_stale(item, TRUE);
  GtkWidget *window = show_in_window(pane);
  wx_detail_set_item(pane, item);
  settle();
  g_assert_true(wxt_is_mapped(GTK_WIDGET(pane), "wx-detail-badge-stale"));
  g_assert_cmpstr(gtk_widget_get_tooltip_text(find(pane, "wx-detail-badge-stale")), ==,
                  "The last refresh failed: <span foreground='red'>&</span>");
  g_assert_cmpstr(T("wx-detail-attribution"), ==, "<i>x</i> & \"");
  g_assert_cmpstr(markup_of(pane, "wx-detail-attribution"), ==,
                  "&lt;i&gt;x&lt;/i&gt; &amp; &quot;");
  hide_window(window);
}

static void
test_scroll_policy_in_narrow_window(void)
{
  g_autoptr(WxDetail) pane = pane_new();
  g_autoptr(WxRowItem) item = item_plain(NY);
  wx_detail_set_item(pane, item);
  GtkWidget *window = gtk_window_new();
  gtk_window_set_default_size(GTK_WINDOW(window), 300, 300);
  gtk_window_set_child(GTK_WINDOW(window), GTK_WIDGET(pane));
  gtk_window_present(GTK_WINDOW(window));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(pane)));
  settle();
  GtkWidget *scroller = gtk_widget_get_first_child(GTK_WIDGET(pane));
  GtkAdjustment *v = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller));
  /* the content is taller than the window, so it scrolls vertically */
  g_assert_cmpfloat(gtk_adjustment_get_upper(v), >, gtk_adjustment_get_page_size(v));
  hide_window(window);
}

int
main(int argc, char **argv)
{
  wxt_setup("wx-test-detail-XXXXXX");
  /* the harness chose GTK_A11Y=none, under which accessible properties are write-only; this test
   * reads the accessible labels back, which needs GTK's test backend. GTK is not initialised
   * yet. */
  g_setenv("GTK_A11Y", "test", TRUE);
  g_test_init(&argc, &argv, NULL);
  if (!wxt_init_gtk())
    return 77;

  g_test_add_func("/detail/construct", test_construct);
  g_test_add_func("/detail/scrolled-child", test_scrolled_child);
  g_test_add_func("/detail/widget-names-unique", test_widget_names_unique);
  g_test_add_func("/detail/widget-types", test_widget_types);
  g_test_add_func("/detail/cards-have-class", test_cards_have_class);
  g_test_add_func("/detail/accessibility", test_accessibility);
  g_test_add_func("/detail/accessible-labels", test_accessible_labels);
  g_test_add_func("/detail/null-arguments", test_null_arguments);

  g_test_add_func("/detail/placeholder/no-item", test_placeholder_no_item);
  g_test_add_func("/detail/placeholder/loading", test_placeholder_loading);
  g_test_add_func("/detail/placeholder/error", test_placeholder_error);
  g_test_add_func("/detail/placeholder/error-punctuation", test_placeholder_error_punctuation);
  g_test_add_func("/detail/placeholder/error-hostile", test_placeholder_error_hostile);
  g_test_add_func("/detail/placeholder/error-empty-text", test_placeholder_error_empty_text);
  g_test_add_func("/detail/placeholder/offline-and-none", test_placeholder_offline_and_none);
  g_test_add_func("/detail/placeholder/precedence", test_placeholder_precedence);
  g_test_add_func("/detail/spinners", test_spinners_follow_loading_and_forecast);
  g_test_add_func("/detail/page-follows-forecast", test_page_follows_forecast);

  g_test_add_func("/detail/item/switch", test_switch_items);
  g_test_add_func("/detail/item/same-item-refreshes", test_same_item_only_refreshes);
  g_test_add_func("/detail/item/reference-held", test_item_reference_is_held);
  g_test_add_func("/detail/item/finalised-with-pane", test_item_finalised_with_pane);
  g_test_add_func("/detail/item/replaced-released", test_replaced_item_is_released);
  g_test_add_func("/detail/item/handler-unsets-item", test_handler_unsets_item_during_emission);
  g_test_add_func("/detail/item/handler-destroys-pane", test_handler_destroys_pane_during_emission);
  g_test_add_func("/detail/dispose", test_dispose);
  g_test_add_func("/detail/dispose-without-item", test_dispose_without_item);
  g_test_add_func("/detail/window-destroy-with-item", test_window_destroy_with_item);

  g_test_add_func("/detail/now/imperial", test_now_block_imperial);
  g_test_add_func("/detail/now/metric-and-toggle", test_now_block_metric_and_toggle);
  g_test_add_func("/detail/now/units-reach-widgets", test_units_reach_the_widgets);
  g_test_add_func("/detail/now/icon", test_icon_follows_condition_and_daylight);
  g_test_add_func("/detail/now/gusts", test_gusts_rules);
  g_test_add_func("/detail/now/no-current-conditions", test_no_current_conditions);
  g_test_add_func("/detail/now/hours-in-the-past", test_hours_in_the_past);
  g_test_add_func("/detail/now/outside-valid-range", test_now_outside_valid_range);

  g_test_add_func("/detail/highlow/missing-day", test_highlow_missing_day);
  g_test_add_func("/detail/highlow/unknown-numbers", test_highlow_unknown_numbers);
  g_test_add_func("/detail/highlow/day-boundaries", test_highlow_day_boundaries);
  g_test_add_func("/detail/highlow/picks-day-of-now", test_highlow_picks_the_day_of_now);
  g_test_add_func("/detail/highlow/time-zones", test_highlow_time_zones);
  g_test_add_func("/detail/highlow/covered-from", test_highlow_covered_from);

  g_test_add_func("/detail/rain/dry", test_rain_dry);
  g_test_add_func("/detail/rain/dry-needs-coverage", test_rain_dry_needs_coverage);
  g_test_add_func("/detail/rain/now", test_rain_now);
  g_test_add_func("/detail/rain/now-peak-past", test_rain_now_peak_past);
  g_test_add_func("/detail/rain/now-unknown-end", test_rain_now_unknown_end);
  g_test_add_func("/detail/rain/expected-soon", test_rain_expected_soon);
  g_test_add_func("/detail/rain/expected-later-today", test_rain_expected_later_today);
  g_test_add_func("/detail/rain/expected-tomorrow", test_rain_expected_tomorrow);
  g_test_add_func("/detail/rain/possible", test_rain_possible);
  g_test_add_func("/detail/rain/time-zones", test_rain_texts_follow_the_zone);
  g_test_add_func("/detail/rain/follows-now", test_rain_updates_with_now);
  g_test_add_func("/detail/rain/nowcast-quarters", test_rain_with_nowcast_quarters);
  g_test_add_func("/detail/chart/views", test_chart_views);
  g_test_add_func("/detail/chart/follows-item", test_chart_follows_item_changes);
  g_test_add_func("/detail/chart/cleared-without-forecast", test_chart_cleared_without_forecast);
  g_test_add_func("/detail/clouds/texts", test_cloud_texts);
  g_test_add_func("/detail/clouds/time-zones", test_cloud_sentence_follows_the_zone);
  g_test_add_func("/detail/lists/hours-and-days", test_hours_and_days_are_fed);

  g_test_add_func("/detail/badges", test_badges_and_tooltips);
  g_test_add_func("/detail/footer/updated", test_updated_texts);
  g_test_add_func("/detail/footer/updated-extreme-now", test_updated_extreme_now);
  g_test_add_func("/detail/footer/updated-no-clock", test_updated_follows_now_only);
  g_test_add_func("/detail/footer/sources", test_sources_list);
  g_test_add_func("/detail/footer/sources-failed-or-skipped", test_sources_only_failed_or_skipped);
  g_test_add_func("/detail/footer/source-without-name", test_source_without_name_uses_its_id);
  g_test_add_func("/detail/footer/one-row-with-badges", test_footer_is_one_row_with_the_badges);
  g_test_add_func("/detail/footer/attribution-link", test_attribution_link);
  g_test_add_func("/detail/footer/attribution-hostile-urls", test_attribution_rejects_hostile_urls);
  g_test_add_func("/detail/footer/attribution-url-length", test_attribution_url_length_limit);
  g_test_add_func("/detail/footer/attribution-escapes-link",
                  test_attribution_hand_built_link_is_escaped);
  g_test_add_func("/detail/footer/attribution-without-text",
                  test_attribution_without_text_is_skipped);
  g_test_add_func("/detail/item/not-mutated", test_item_is_not_mutated);
  g_test_add_func("/detail/footer/hostile-text", test_hostile_names_and_attributions_are_literal);
  g_test_add_func("/detail/footer/invalid-utf8", test_invalid_utf8_in_hand_built_names);
  g_test_add_func("/detail/footer/sixteen-sources", test_sixteen_sources);
  g_test_add_func("/detail/footer/long-names", test_long_names_are_bounded);

  g_test_add_func("/detail/compare/unchanged-refresh", test_unchanged_refresh_changes_nothing);
  g_test_add_func("/detail/compare/irrelevant-change", test_irrelevant_change_changes_nothing);
  g_test_add_func("/detail/compare/attribution-cache", test_attribution_markup_cache);

  g_test_add_func("/detail/huge-forecast", test_huge_forecast);
  g_test_add_func("/detail/window/all-states", test_window_layout_all_states);
  g_test_add_func("/detail/window/hostile-data", test_window_hostile_data);
  g_test_add_func("/detail/window/scrolls-vertically", test_scroll_policy_in_narrow_window);

  return g_test_run();
}
