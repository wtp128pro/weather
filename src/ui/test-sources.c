/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-sources.c - WxSources (the data-source status popover) with the TEST-ONLY fake providers
 * of the net module, a hand-written hostile provider and a real WxRegistry.
 *
 * Needs a GDK display (run under xvfb-run); exits 77 (meson: skipped) when gtk_init_check()
 * fails. Nothing touches the network or the disk (the harness redirects the XDG directories).
 *
 * Accessibility: the harness selects GTK_A11Y=none, which gives widgets no accessibility
 * context, so the accessible labels could not be read back. main() therefore switches to
 * GTK_A11Y=test (GTK's in-process test backend, no bus, no I/O) before GTK starts.
 *
 * Determinism: nothing sleeps for a fixed time except one wait that proves something does NOT
 * happen (a toggle is reported once); everything else pumps the main loop until a condition
 * holds. No test depends on X keyboard focus or on the window being active.
 */
/* test-support.h comes first: it defines _GNU_SOURCE before any system header. */
#include "test-support.h"

#include <string.h>

#include "wx-fake-provider.h"
#include "wx-sources.h"

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* ------------------------------------------------------------------ */
/* Hostile provider: every text is chosen by the test                 */
/* ------------------------------------------------------------------ */

#define TEST_TYPE_PROVIDER (test_provider_get_type())
G_DECLARE_FINAL_TYPE(TestProvider, test_provider, TEST, PROVIDER, GObject)

struct _TestProvider {
  GObject parent_instance;
  char *id;
  char *name;
  char *attribution;
  char *url;
};

static void test_provider_iface_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(TestProvider, test_provider, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, test_provider_iface_init))

static void
test_provider_finalize(GObject *object)
{
  TestProvider *self = TEST_PROVIDER(object);
  g_free(self->id);
  g_free(self->name);
  g_free(self->attribution);
  g_free(self->url);
  G_OBJECT_CLASS(test_provider_parent_class)->finalize(object);
}

static void
test_provider_class_init(TestProviderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = test_provider_finalize;
}

static void
test_provider_init(TestProvider *self)
{
  (void)self;
}

static const char *
test_provider_get_id(WxProvider *p)
{
  return TEST_PROVIDER(p)->id;
}

static const char *
test_provider_get_name(WxProvider *p)
{
  return TEST_PROVIDER(p)->name;
}

static const char *
test_provider_get_attribution(WxProvider *p)
{
  return TEST_PROVIDER(p)->attribution;
}

static const char *
test_provider_get_attribution_url(WxProvider *p)
{
  return TEST_PROVIDER(p)->url;
}

static gboolean
test_provider_covers(WxProvider *p, const WxPlace *place)
{
  (void)p;
  (void)place;
  return TRUE;
}

static void
test_provider_fetch_async(WxProvider *p, const WxPlace *place, GCancellable *cancellable,
                          GAsyncReadyCallback callback, gpointer user_data)
{
  (void)place;
  g_task_report_new_error(p, callback, user_data, NULL, WX_ERROR, WX_ERROR_UNSUPPORTED,
                          "the hostile test provider never fetches");
  (void)cancellable;
}

static WxSourceResult *
test_provider_fetch_finish(WxProvider *p, GAsyncResult *result, GError **error)
{
  (void)p;
  g_task_propagate_pointer(G_TASK(result), error);
  return NULL;
}

static void
test_provider_iface_init(WxProviderInterface *iface)
{
  iface->get_id = test_provider_get_id;
  iface->get_name = test_provider_get_name;
  iface->get_attribution = test_provider_get_attribution;
  iface->get_attribution_url = test_provider_get_attribution_url;
  iface->covers = test_provider_covers;
  iface->fetch_async = test_provider_fetch_async;
  iface->fetch_finish = test_provider_fetch_finish;
}

/* Registers in @registry a provider with the given texts; the registry holds the only reference. */
static void
add_test_provider(WxRegistry *registry, const char *id, const char *name, const char *attribution,
                  const char *url)
{
  g_autoptr(TestProvider) p = g_object_new(TEST_TYPE_PROVIDER, NULL);
  p->id = g_strdup(id);
  p->name = g_strdup(name);
  p->attribution = g_strdup(attribution);
  p->url = g_strdup(url);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(p), NULL));
}

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

/* A registry holding a fake provider for each id of the NULL-terminated list. */
static WxRegistry *
make_registry(const char *const *ids)
{
  WxRegistry *registry = wx_registry_new();
  for (; *ids != NULL; ids++) {
    g_autoptr(WxFakeProvider) fake = wx_fake_provider_new(*ids);
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(fake), NULL));
  }
  return registry;
}

static void
add_fake(WxRegistry *registry, const char *id)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new(id);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(fake), NULL));
}

/* The popover of a registry, owned by the caller (sunk reference). */
static WxSources *
make_sources(WxRegistry *registry)
{
  GtkWidget *w = wx_sources_new(registry);
  g_assert_nonnull(w);
  g_assert_true(WX_IS_SOURCES(w));
  return WX_SOURCES(g_object_ref_sink(w));
}

static GPtrArray *
rows_of(WxSources *s)
{
  GPtrArray *rows = g_ptr_array_new();
  wxt_collect_named(GTK_WIDGET(s), "wx-sources-row", rows);
  return rows;
}

static guint
n_rows(WxSources *s)
{
  g_autoptr(GPtrArray) rows = rows_of(s);
  return rows->len;
}

static GtkWidget *
row_at(WxSources *s, guint i)
{
  g_autoptr(GPtrArray) rows = rows_of(s);
  g_assert_cmpuint(i, <, rows->len);
  return g_ptr_array_index(rows, i);
}

static const char *
row_text(WxSources *s, guint i, const char *name)
{
  GtkWidget *w = wxt_find_named(row_at(s, i), name);
  g_assert_nonnull(w);
  return gtk_label_get_text(GTK_LABEL(w));
}

static GtkWidget *
row_widget(WxSources *s, guint i, const char *name)
{
  GtkWidget *w = wxt_find_named(row_at(s, i), name);
  g_assert_nonnull(w);
  return w;
}

static GtkSwitch *
row_switch(WxSources *s, guint i)
{
  return GTK_SWITCH(row_widget(s, i, "wx-sources-switch"));
}

static const char *
status_of(WxSources *s, guint i)
{
  return row_text(s, i, "wx-sources-status");
}

static WxPlace *
make_place(void)
{
  WxPlace *place = wx_place_new("Miami", "Florida", "United States", "US", 25.77, -80.19,
                                "America/New_York", NULL);
  g_assert_nonnull(place);
  return place;
}

static WxSourceStatus *
make_status(const char *id, WxSourceState state, int error_code, guint n_members)
{
  g_autoptr(GError) error = NULL;
  WxSourceStatus *st = wx_source_status_new(id, "Name", "Attribution", "https://example.invalid/",
                                            state, error_code, n_members, &error);
  g_assert_no_error(error);
  g_assert_nonnull(st);
  return st;
}

/* A forecast whose sources are copies of the @n statuses in @list. */
static WxForecast *
make_forecast(WxSourceStatus *const *list, guint n)
{
  g_autoptr(WxPlace) place = make_place();
  WxSourceStatus sources[WX_FORECAST_MAX_SOURCES];
  g_assert_cmpuint(n, <=, G_N_ELEMENTS(sources));
  for (guint i = 0; i < n; i++)
    sources[i] = *list[i];
  g_autoptr(GError) error = NULL;
  WxForecast *f = wx_forecast_new(place, 1791676800, NULL, 0, NULL, 0, NULL, 0,
                                  n > 0 ? sources : NULL, n, &error);
  g_assert_no_error(error);
  g_assert_nonnull(f);
  return f;
}

/* A forecast with the single source (@id, @state, @code, @n_members). */
static WxForecast *
make_forecast1(const char *id, WxSourceState state, int code, guint n_members)
{
  g_autoptr(WxSourceStatus) st = make_status(id, state, code, n_members);
  return make_forecast(&st, 1);
}

/* Records "provider-toggled" emissions; optionally applies the request to a registry. */
typedef struct {
  guint count;
  char *id;
  const char *id_ptr;
  gboolean enabled;
  WxRegistry *apply_to; /* NULL: the owner ignores the toggle */
} Toggles;

static void
on_toggled(WxSources *s, const char *id, gboolean enabled, gpointer user_data)
{
  Toggles *t = user_data;
  g_assert_true(WX_IS_SOURCES(s));
  t->count++;
  g_free(t->id);
  t->id = g_strdup(id);
  t->id_ptr = id;
  t->enabled = enabled;
  if (t->apply_to != NULL)
    wx_registry_set_enabled(t->apply_to, id, enabled);
}

static void
toggles_connect(Toggles *t, WxSources *s)
{
  memset(t, 0, sizeof *t);
  g_signal_connect(s, "provider-toggled", G_CALLBACK(on_toggled), t);
}

static void
toggles_clear(Toggles *t)
{
  g_free(t->id);
  t->id = NULL;
}

static void
count_signal(guint *counter)
{
  (*counter)++;
}

/* Asserts that the accessible label of @w is exactly @expected.
 * gtk_test_accessible_check_property() takes the value to compare with and returns NULL when the
 * property equals it, otherwise a description of the difference. */
static void
assert_accessible_label(GtkWidget *w, const char *expected)
{
  g_assert_true(gtk_test_accessible_has_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL));
  g_autofree char *difference = gtk_test_accessible_check_property(
      GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, expected);
  g_assert_null(difference);
}

/* ------------------------------------------------------------------ */
/* Construction and arguments                                         */
/* ------------------------------------------------------------------ */

static void
test_new_null(void)
{
  GtkWidget *w = NULL;
  ASSERT_CRITICAL("wx_sources_new", w = wx_sources_new(NULL));
  g_assert_null(w);
}

static void
test_new_wrong_type(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("x");
  GtkWidget *w = NULL;
  ASSERT_CRITICAL("wx_sources_new", w = wx_sources_new((WxRegistry *)fake));
  g_assert_null(w);
}

static void
test_set_forecast_bad_self(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("x");
  ASSERT_CRITICAL("wx_sources_set_forecast", wx_sources_set_forecast(NULL, NULL));
  ASSERT_CRITICAL("wx_sources_set_forecast", wx_sources_set_forecast((WxSources *)fake, NULL));
}

static void
test_new_is_floating_popover(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  GtkWidget *w = wx_sources_new(registry);
  g_assert_true(GTK_IS_POPOVER(w));
  g_assert_true(g_object_is_floating(w));
  g_assert_true(gtk_widget_has_css_class(w, "wx-sources"));
  g_object_ref_sink(w);
  g_object_unref(w);
}

static void
test_empty_registry_layout(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpuint(n_rows(s), ==, 0);
  GtkWidget *title = wxt_find_named(GTK_WIDGET(s), "wx-sources-title");
  g_assert_nonnull(title);
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(title)), ==, "Data sources");
  g_assert_true(gtk_widget_has_css_class(title, "wx-sources-title"));
  g_assert_nonnull(wxt_find_named(GTK_WIDGET(s), "wx-sources-note"));
  GtkWidget *about = wxt_find_named(GTK_WIDGET(s), "wx-sources-about");
  g_assert_true(GTK_IS_BUTTON(about));
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(about)), ==, "About Weather");
  g_assert_true(gtk_widget_has_css_class(about, "flat"));
}

static void
test_rows_follow_registry_order(void)
{
  const char *const ids[] = { "open-meteo", "zeta", "alpha", "met-no", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpuint(n_rows(s), ==, 4);
  for (guint i = 0; ids[i] != NULL; i++) {
    g_autofree char *expected = g_strdup_printf("Fake %s", ids[i]);
    g_assert_cmpstr(row_text(s, i, "wx-sources-name"), ==, expected);
    GtkWidget *row = row_at(s, i);
    g_assert_true(GTK_IS_BOX(row));
    g_assert_true(gtk_widget_has_css_class(row, "wx-sources-row"));
    g_assert_true(GTK_IS_SWITCH(wxt_find_named(row, "wx-sources-switch")));
    g_assert_true(GTK_IS_LABEL(wxt_find_named(row, "wx-sources-status")));
    g_assert_true(gtk_widget_has_css_class(wxt_find_named(row, "wx-sources-name"),
                                           "wx-sources-name"));
    g_assert_true(GTK_IS_LABEL(wxt_find_named(row, "wx-sources-attribution")));
    g_assert_true(GTK_IS_LABEL(wxt_find_named(row, "wx-sources-licence")));
  }
}

static void
test_sixteen_providers(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  for (int i = 0; i < WX_REGISTRY_MAX_PROVIDERS; i++) {
    g_autofree char *id = g_strdup_printf("p%d", i);
    add_fake(registry, id);
  }
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpuint(n_rows(s), ==, WX_REGISTRY_MAX_PROVIDERS);
  g_assert_cmpstr(row_text(s, 15, "wx-sources-name"), ==, "Fake p15");
  /* The registry refuses a 17th provider; the popover stays at 16 rows. */
  g_autoptr(WxFakeProvider) extra = wx_fake_provider_new("extra");
  g_autoptr(GError) error = NULL;
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(extra), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_assert_cmpuint(n_rows(s), ==, WX_REGISTRY_MAX_PROVIDERS);
}

static void
test_switch_matches_enabled_flag(void)
{
  const char *const ids[] = { "a", "b", "c", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  wx_registry_set_enabled(registry, "b", FALSE);
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_false(gtk_switch_get_active(row_switch(s, 1)));
  g_assert_true(gtk_switch_get_active(row_switch(s, 2)));
  g_assert_true(gtk_switch_get_state(row_switch(s, 0)));
  g_assert_false(gtk_switch_get_state(row_switch(s, 1)));
}

/* ------------------------------------------------------------------ */
/* The switch and "provider-toggled"                                  */
/* ------------------------------------------------------------------ */

static void
test_toggle_emits_once_and_does_not_touch_registry(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  guint changed = 0;
  g_signal_connect_swapped(registry, "changed", G_CALLBACK(count_signal), &changed);
  gtk_switch_set_active(row_switch(s, 1), FALSE);
  g_assert_cmpuint(t.count, ==, 1);
  g_assert_cmpstr(t.id, ==, "b");
  g_assert_false(t.enabled);
  g_assert_true(wx_registry_is_enabled(registry, "b"));
  g_assert_true(wx_registry_is_enabled(registry, "a"));
  g_assert_cmpuint(changed, ==, 0);
  toggles_clear(&t);
}

static void
test_refused_toggle_snaps_back(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  g_assert_cmpuint(t.count, ==, 1);
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_true(gtk_switch_get_state(row_switch(s, 0)));
  /* Same for a disabled provider that the owner refuses to enable. */
  wx_registry_set_enabled(registry, "a", FALSE);
  g_assert_false(gtk_switch_get_active(row_switch(s, 0)));
  gtk_switch_set_active(row_switch(s, 0), TRUE);
  g_assert_cmpuint(t.count, ==, 2);
  g_assert_true(t.enabled);
  g_assert_false(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_false(gtk_switch_get_state(row_switch(s, 0)));
  toggles_clear(&t);
}

/* Whether the accessible "checked" state of the switch equals @checked. */
static gboolean
checked_state_is(GtkSwitch *sw, gboolean checked)
{
  g_autofree char *difference = gtk_test_accessible_check_state(
      GTK_ACCESSIBLE(sw), GTK_ACCESSIBLE_STATE_CHECKED,
      checked ? GTK_ACCESSIBLE_TRISTATE_TRUE : GTK_ACCESSIBLE_TRISTATE_FALSE);
  return difference == NULL;
}

static void
test_refused_toggle_republishes_accessible_state(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  g_assert_true(checked_state_is(row_switch(s, 0), TRUE));
  g_assert_null(g_main_context_find_source_by_user_data(NULL, s));
  gtk_switch_set_active(row_switch(s, 0), FALSE); /* ignored by the owner: snaps back */
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_nonnull(g_main_context_find_source_by_user_data(NULL, s));
  /* GtkSwitch publishes the state it was asked for after the handler returned; the popover
   * corrects that from an idle callback. */
  WXT_WAIT_FOR(checked_state_is(row_switch(s, 0), TRUE));
  g_assert_null(g_main_context_find_source_by_user_data(NULL, s));
  g_assert_true(checked_state_is(row_switch(s, 1), TRUE));
  /* A toggle that sticks needs no correction. */
  t.apply_to = registry;
  gtk_switch_set_active(row_switch(s, 1), FALSE);
  g_assert_null(g_main_context_find_source_by_user_data(NULL, s));
  g_assert_true(checked_state_is(row_switch(s, 1), FALSE));
  /* Two refused toggles in a row share one pending callback. */
  t.apply_to = NULL;
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  g_assert_cmpuint(t.count, ==, 4);
  g_assert_nonnull(g_main_context_find_source_by_user_data(NULL, s));
  WXT_WAIT_FOR(g_main_context_find_source_by_user_data(NULL, s) == NULL);
  g_assert_true(checked_state_is(row_switch(s, 0), TRUE));
  toggles_clear(&t);
}

static void
test_pending_idle_is_removed_at_dispose(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  WxSources *s = make_sources(registry);
  gtk_switch_set_active(row_switch(s, 0), FALSE); /* refused: the idle callback is pending */
  g_assert_nonnull(g_main_context_find_source_by_user_data(NULL, s));
  g_object_run_dispose(G_OBJECT(s));
  g_assert_null(g_main_context_find_source_by_user_data(NULL, s));
  g_object_unref(s);
  wxt_pump_idle();
}

static void
test_applied_toggle_sticks(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  t.apply_to = registry;
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  g_assert_cmpuint(t.count, ==, 1);
  g_assert_false(wx_registry_is_enabled(registry, "a"));
  g_assert_false(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_false(gtk_switch_get_state(row_switch(s, 0)));
  g_assert_cmpstr(status_of(s, 0), ==, "Turned off");
  g_assert_true(gtk_switch_get_active(row_switch(s, 1)));
  gtk_switch_set_active(row_switch(s, 0), TRUE);
  g_assert_cmpuint(t.count, ==, 2);
  g_assert_true(t.enabled);
  g_assert_true(wx_registry_is_enabled(registry, "a"));
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_cmpstr(status_of(s, 0), ==, "No forecast loaded yet");
  toggles_clear(&t);
}

static void
flip_flop(WxSources *s, const char *id, gboolean enabled, gpointer user_data)
{
  (void)s;
  (void)enabled;
  WxRegistry *registry = user_data;
  wx_registry_set_enabled(registry, id, FALSE);
  wx_registry_set_enabled(registry, id, TRUE);
}

static void
test_owner_reverting_the_request(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_signal_connect(s, "provider-toggled", G_CALLBACK(flip_flop), registry);
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  g_assert_true(wx_registry_is_enabled(registry, "a"));
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  g_assert_true(gtk_switch_get_state(row_switch(s, 0)));
}

static void
test_toggle_id_is_a_copy(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  WxProvider *p = wx_registry_find_provider(registry, "a");
  g_assert_cmpstr(t.id, ==, wx_provider_get_id(p));
  g_assert_true(t.id_ptr != wx_provider_get_id(p));
  toggles_clear(&t);
}

static void
test_each_user_toggle_emits_once(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  t.apply_to = registry;
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  gtk_switch_set_active(row_switch(s, 0), TRUE);
  gtk_switch_set_active(row_switch(s, 0), TRUE); /* no change: not a toggle */
  gtk_switch_set_active(row_switch(s, 0), FALSE);
  g_assert_cmpuint(t.count, ==, 3);
  g_assert_false(t.enabled);
  toggles_clear(&t);
}

static void
test_registry_changes_resync_without_signal(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  wx_registry_set_enabled(registry, "b", FALSE);
  g_assert_false(gtk_switch_get_active(row_switch(s, 1)));
  g_assert_false(gtk_switch_get_state(row_switch(s, 1)));
  g_assert_cmpstr(status_of(s, 1), ==, "Turned off");
  g_assert_true(gtk_switch_get_active(row_switch(s, 0)));
  wx_registry_set_enabled(registry, "b", TRUE);
  g_assert_true(gtk_switch_get_active(row_switch(s, 1)));
  g_assert_cmpstr(status_of(s, 1), ==, "No forecast loaded yet");
  g_assert_cmpuint(t.count, ==, 0);
  toggles_clear(&t);
}

static void
test_added_provider_gets_a_row(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  GtkWidget *first_switch = GTK_WIDGET(row_switch(s, 0));
  GtkWidget *first_row = row_at(s, 0);
  add_fake(registry, "b");
  g_assert_cmpuint(n_rows(s), ==, 2);
  g_assert_cmpstr(row_text(s, 1, "wx-sources-name"), ==, "Fake b");
  g_assert_true(gtk_switch_get_active(row_switch(s, 1)));
  /* The existing row is kept (keyboard focus on its switch survives a change). */
  g_assert_true(row_at(s, 0) == first_row);
  g_assert_true(GTK_WIDGET(row_switch(s, 0)) == first_switch);
  g_assert_cmpuint(t.count, ==, 0);
  /* The new switch is wired like the others. */
  gtk_switch_set_active(row_switch(s, 1), FALSE);
  g_assert_cmpuint(t.count, ==, 1);
  g_assert_cmpstr(t.id, ==, "b");
  toggles_clear(&t);
}

/* ------------------------------------------------------------------ */
/* Status lines                                                       */
/* ------------------------------------------------------------------ */

static void
test_status_no_forecast(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpstr(status_of(s, 0), ==, "No forecast loaded yet");
  g_assert_cmpstr(status_of(s, 1), ==, "No forecast loaded yet");
  GtkWidget *status = row_widget(s, 0, "wx-sources-status");
  g_assert_true(gtk_widget_has_css_class(status, "dim-label"));
  g_assert_true(gtk_widget_has_css_class(status, "wx-sources-status"));
}

static void
test_status_ok_counts(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  const struct {
    guint n;
    const char *text;
  } cases[] = {
    { 1, "Used for this place (1 forecast model)" },
    { 2, "Used for this place (2 forecast models)" },
    { 0, "Used for this place (0 forecast models)" },
    { 17, "Used for this place (17 forecast models)" },
  };
  for (gsize i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(WxForecast) f = make_forecast1("a", WX_SRC_OK, -1, cases[i].n);
    wx_sources_set_forecast(s, f);
    g_assert_cmpstr(status_of(s, 0), ==, cases[i].text);
  }
}

static void
test_status_failed_reasons(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  const struct {
    int code;
    const char *text;
  } cases[] = {
    { WX_ERROR_NETWORK, "Could not load: network error" },
    { WX_ERROR_TIMEOUT, "Could not load: timed out" },
    { WX_ERROR_HTTP, "Could not load: server error" },
    { WX_ERROR_RATE_LIMITED, "Could not load: rate limited" },
    { WX_ERROR_PARSE, "Could not load: unreadable answer" },
    { WX_ERROR_NOT_FOUND, "Could not load: no data" },
    { WX_ERROR_INVALID_ARG, "Could not load: invalid request" },
    { WX_ERROR_UNSUPPORTED, "Could not load: not available" },
    { -1, "Could not load: unknown error" },
  };
  for (gsize i = 0; i < G_N_ELEMENTS(cases); i++) {
    g_autoptr(WxForecast) f = make_forecast1("a", WX_SRC_FAILED, cases[i].code, 0);
    wx_sources_set_forecast(s, f);
    g_assert_cmpstr(status_of(s, 0), ==, cases[i].text);
  }
}

static void
test_status_failed_unknown_code(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  /* wx_forecast_new() refuses codes it does not know, so the forecast is built by hand (the
   * fields of WxForecast are public and read through wx_forecast_get_sources()). */
  const int codes[] = { 99, -5, 8, G_MAXINT };
  for (gsize i = 0; i < G_N_ELEMENTS(codes); i++) {
    WxSourceStatus st = { (char *)"a", (char *)"Name", (char *)"", (char *)"", WX_SRC_FAILED,
                          codes[i], 0 };
    WxForecast f;
    memset(&f, 0, sizeof f);
    f.sources = &st;
    f.n_sources = 1;
    wx_sources_set_forecast(s, &f);
    g_assert_cmpstr(status_of(s, 0), ==, "Could not load: unknown error");
  }
}

static void
test_status_skipped_and_missing(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_autoptr(WxForecast) f = make_forecast1("a", WX_SRC_SKIPPED, -1, 0);
  wx_sources_set_forecast(s, f);
  g_assert_cmpstr(status_of(s, 0), ==, "Not used for this place");
  g_assert_cmpstr(status_of(s, 1), ==, "Not used for this place"); /* no entry at all */
  g_autoptr(WxForecast) empty = make_forecast(NULL, 0);
  wx_sources_set_forecast(s, empty);
  g_assert_cmpstr(status_of(s, 0), ==, "Not used for this place");
  g_assert_cmpstr(status_of(s, 1), ==, "Not used for this place");
}

static void
test_status_picks_entry_by_id(void)
{
  const char *const ids[] = { "a", "b", "c", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_autoptr(WxSourceStatus) sc = make_status("c", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  g_autoptr(WxSourceStatus) sa = make_status("a", WX_SRC_OK, -1, 3);
  g_autoptr(WxSourceStatus) sx = make_status("other", WX_SRC_OK, -1, 9);
  WxSourceStatus *list[] = { sc, sx, sa };
  g_autoptr(WxForecast) f = make_forecast(list, 3);
  wx_sources_set_forecast(s, f);
  g_assert_cmpstr(status_of(s, 0), ==, "Used for this place (3 forecast models)");
  g_assert_cmpstr(status_of(s, 1), ==, "Not used for this place");
  g_assert_cmpstr(status_of(s, 2), ==, "Could not load: timed out");
}

static void
test_status_turned_off_takes_precedence(void)
{
  const char *const ids[] = { "a", "b", "c", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  wx_registry_set_enabled(registry, "a", FALSE);
  wx_registry_set_enabled(registry, "b", FALSE);
  wx_registry_set_enabled(registry, "c", FALSE);
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpstr(status_of(s, 0), ==, "Turned off"); /* no forecast */
  g_autoptr(WxSourceStatus) sa = make_status("a", WX_SRC_OK, -1, 2);
  g_autoptr(WxSourceStatus) sb = make_status("b", WX_SRC_FAILED, WX_ERROR_HTTP, 0);
  g_autoptr(WxSourceStatus) sc = make_status("c", WX_SRC_SKIPPED, -1, 0);
  WxSourceStatus *list[] = { sa, sb, sc };
  g_autoptr(WxForecast) f = make_forecast(list, 3);
  wx_sources_set_forecast(s, f);
  for (guint i = 0; i < 3; i++)
    g_assert_cmpstr(status_of(s, i), ==, "Turned off");
}

static void
test_status_forecast_replaced_and_cleared(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_autoptr(WxForecast) ok = make_forecast1("a", WX_SRC_OK, -1, 2);
  g_autoptr(WxForecast) bad = make_forecast1("a", WX_SRC_FAILED, WX_ERROR_NETWORK, 0);
  wx_sources_set_forecast(s, ok);
  g_assert_cmpstr(status_of(s, 0), ==, "Used for this place (2 forecast models)");
  wx_sources_set_forecast(s, bad);
  g_assert_cmpstr(status_of(s, 0), ==, "Could not load: network error");
  wx_sources_set_forecast(s, NULL);
  g_assert_cmpstr(status_of(s, 0), ==, "No forecast loaded yet");
  /* A forecast without an entry for "a" must not keep the entry of the earlier forecast. */
  wx_sources_set_forecast(s, ok);
  g_autoptr(WxForecast) other = make_forecast1("other", WX_SRC_OK, -1, 1);
  wx_sources_set_forecast(s, other);
  g_assert_cmpstr(status_of(s, 0), ==, "Not used for this place");
}

static void
test_status_duplicate_entries_first_wins(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_autoptr(WxSourceStatus) first = make_status("a", WX_SRC_FAILED, WX_ERROR_PARSE, 0);
  g_autoptr(WxSourceStatus) second = make_status("a", WX_SRC_OK, -1, 4);
  WxSourceStatus *list[] = { first, second };
  g_autoptr(WxForecast) f = make_forecast(list, 2);
  wx_sources_set_forecast(s, f);
  g_assert_cmpstr(status_of(s, 0), ==, "Could not load: unreadable answer");
  WxSourceStatus *swapped[] = { second, first };
  g_autoptr(WxForecast) g = make_forecast(swapped, 2);
  wx_sources_set_forecast(s, g);
  g_assert_cmpstr(status_of(s, 0), ==, "Used for this place (4 forecast models)");
  /* A skipped first entry counts: a later entry of the same source is ignored. */
  g_autoptr(WxSourceStatus) skipped = make_status("a", WX_SRC_SKIPPED, -1, 0);
  WxSourceStatus *skipped_first[] = { skipped, second };
  g_autoptr(WxForecast) h = make_forecast(skipped_first, 2);
  wx_sources_set_forecast(s, h);
  g_assert_cmpstr(status_of(s, 0), ==, "Not used for this place");
}

static void
test_status_follows_registry_after_forecast_is_gone(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  WxForecast *f = make_forecast1("a", WX_SRC_OK, -1, 2);
  wx_sources_set_forecast(s, f);
  /* The popover keeps no reference: the only reference is ours. */
  g_assert_true(g_atomic_ref_count_compare(&f->ref_count, 1));
  wx_forecast_unref(f);
  wx_registry_set_enabled(registry, "a", FALSE);
  g_assert_cmpstr(status_of(s, 0), ==, "Turned off");
  wx_registry_set_enabled(registry, "a", TRUE);
  g_assert_cmpstr(status_of(s, 0), ==, "Used for this place (2 forecast models)");
  g_assert_cmpstr(status_of(s, 1), ==, "Not used for this place");
  add_fake(registry, "c");
  g_assert_cmpstr(status_of(s, 2), ==, "Not used for this place");
}

static void
test_status_new_row_uses_stored_forecast(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_autoptr(WxSourceStatus) sb = make_status("b", WX_SRC_FAILED, WX_ERROR_RATE_LIMITED, 0);
  g_autoptr(WxForecast) f = make_forecast(&sb, 1);
  wx_sources_set_forecast(s, f);
  add_fake(registry, "b");
  g_assert_cmpstr(status_of(s, 0), ==, "Not used for this place");
  g_assert_cmpstr(status_of(s, 1), ==, "Could not load: rate limited");
}

/* ------------------------------------------------------------------ */
/* Licence lines                                                      */
/* ------------------------------------------------------------------ */

static void
test_licence_known_ids(void)
{
  const char *const ids[] = { "open-meteo", "met-no", "nws", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  GtkWidget *om = row_widget(s, 0, "wx-sources-licence");
  g_assert_true(gtk_widget_get_visible(om));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(om)), ==, "Open-Meteo data is licensed CC BY 4.0");
  g_assert_true(gtk_label_get_use_markup(GTK_LABEL(om)));
  g_assert_cmpstr(gtk_label_get_label(GTK_LABEL(om)), ==,
                  "Open-Meteo data is licensed "
                  "<a href=\"https://creativecommons.org/licenses/by/4.0/\">CC BY 4.0</a>");
  GtkWidget *mn = row_widget(s, 1, "wx-sources-licence");
  g_assert_true(gtk_widget_get_visible(mn));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(mn)), ==, "MET Norway data: CC BY 4.0 / NLOD");
  g_assert_cmpstr(gtk_label_get_label(GTK_LABEL(mn)), ==,
                  "MET Norway data: "
                  "<a href=\"https://api.met.no/doc/License\">CC BY 4.0 / NLOD</a>");
  GtkWidget *nws = row_widget(s, 2, "wx-sources-licence");
  g_assert_true(gtk_widget_get_visible(nws));
  g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(nws)), ==,
                  "NOAA/National Weather Service data is US government work, "
                  "credited as a courtesy");
  g_assert_null(strstr(gtk_label_get_label(GTK_LABEL(nws)), "<a"));
  for (guint i = 0; i < 3; i++) {
    GtkWidget *l = row_widget(s, i, "wx-sources-licence");
    g_assert_true(gtk_widget_has_css_class(l, "dim-label"));
    g_assert_true(gtk_widget_has_css_class(l, "wx-sources-licence"));
  }
}

static void
test_licence_absent_for_other_ids(void)
{
  const char *const ids[] = { "fake", "open-meteo2", "nws-x", "x", "met", "open", "xopen-meteo",
                              "a_b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpuint(n_rows(s), ==, 8);
  for (guint i = 0; i < 8; i++) {
    GtkWidget *l = row_widget(s, i, "wx-sources-licence");
    g_assert_false(gtk_widget_get_visible(l));
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(l)), ==, "");
    /* Everything else behaves as for any provider. */
    g_assert_true(gtk_widget_get_visible(row_widget(s, i, "wx-sources-attribution")));
    g_assert_cmpstr(status_of(s, i), ==, "No forecast loaded yet");
  }
}

/* ------------------------------------------------------------------ */
/* Attribution text and link                                          */
/* ------------------------------------------------------------------ */

static void
test_attribution_https_link(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  GtkLabel *l = GTK_LABEL(row_widget(s, 0, "wx-sources-attribution"));
  g_assert_true(gtk_label_get_use_markup(l));
  g_assert_cmpstr(gtk_label_get_text(l), ==, "Fake data (a)");
  g_assert_cmpstr(gtk_label_get_label(l), ==,
                  "<a href=\"https://example.invalid/\">Fake data (a)</a>");
  g_assert_true(gtk_widget_has_css_class(GTK_WIDGET(l), "wx-sources-attribution"));
}

static void
test_attribution_url_accepted_edge_cases(void)
{
  g_autofree char *fill = g_strnfill(WX_SOURCE_URL_MAX - 8, 'a');
  g_autofree char *max_url = g_strdup_printf("https://%s", fill);
  g_assert_cmpuint(strlen(max_url), ==, WX_SOURCE_URL_MAX);
  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "max", "Max", "T", max_url);
  add_test_provider(registry, "one", "One", "T", "https://x");
  add_test_provider(registry, "uni", "Uni", "T", "https://exämple.invalid/ü?a=1&b=2");
  g_autoptr(WxSources) s = make_sources(registry);
  for (guint i = 0; i < 3; i++)
    g_assert_true(gtk_label_get_use_markup(GTK_LABEL(row_widget(s, i, "wx-sources-attribution"))));
  g_autofree char *expected = g_strdup_printf("<a href=\"%s\">T</a>", max_url);
  GtkWidget *max_label = row_widget(s, 0, "wx-sources-attribution");
  g_assert_cmpstr(gtk_label_get_label(GTK_LABEL(max_label)), ==, expected);
  g_assert_cmpstr(gtk_label_get_label(GTK_LABEL(row_widget(s, 2, "wx-sources-attribution"))), ==,
                  "<a href=\"https://exämple.invalid/ü?a=1&amp;b=2\">T</a>");
}

static void
test_attribution_unacceptable_urls_give_plain_text(void)
{
  g_autofree char *fill = g_strnfill(WX_SOURCE_URL_MAX - 7, 'a');
  g_autofree char *too_long = g_strdup_printf("https://%s", fill);
  g_assert_cmpuint(strlen(too_long), ==, WX_SOURCE_URL_MAX + 1);
  g_autofree char *huge_fill = g_strnfill(100000, 'a');
  g_autofree char *very_long = g_strdup_printf("https://%s", huge_fill);
  const char *urls[] = {
    "http://example.invalid/",
    "javascript:alert(1)",
    "ftp://example.invalid/",
    "HTTPS://example.invalid/",
    " https://example.invalid/",
    "//example.invalid/",
    "https://",
    "https:/",
    "https:example.invalid/",
    "https//example.invalid/",
    "httpss://example.invalid/",
    "https:\\\\example.invalid/",
    "https://example.invalid/a<b",
    "",
    "https://example.invalid/a b",
    "https://example.invalid/a\tb",
    "https://example.invalid/a\nb",
    "https://example.invalid/a\x01" "b",
    "https://example.invalid/a\x7f" "b",
    "https://example.invalid/<b>",
    "https://example.invalid/a>b",
    "https://example.invalid/\"x\"",
    "https://example.invalid/\"onmouseover=\"x",
    "https://example.invalid/\xff",
    "https://example.invalid/\xc3",
    "https://example.invalid/\xe2\x80\xae" "x", /* U+202E, a bidi override */
    "https://example.invalid/\xc2\xa0x",        /* U+00A0 no-break space */
    "https://example.invalid/\xe2\x80\xa8x",    /* U+2028 line separator */
    "https://example.invalid/\xc2\x85x",        /* U+0085, a C1 control */
    too_long,
    very_long,
  };
  for (gsize i = 0; i < G_N_ELEMENTS(urls); i++) {
    g_test_message("url #%" G_GSIZE_FORMAT, i);
    g_autoptr(WxRegistry) registry = wx_registry_new();
    add_test_provider(registry, "p", "Name", "Credit line", urls[i]);
    g_autoptr(WxSources) s = make_sources(registry);
    GtkLabel *l = GTK_LABEL(row_widget(s, 0, "wx-sources-attribution"));
    g_assert_false(gtk_label_get_use_markup(l));
    g_assert_cmpstr(gtk_label_get_text(l), ==, "Credit line");
    g_assert_cmpstr(gtk_label_get_label(l), ==, "Credit line");
    g_assert_true(gtk_widget_has_css_class(GTK_WIDGET(l), "wx-sources-attribution"));
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(l)));
  }
}

static void
test_attribution_text_and_url_are_escaped(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "evil", "<b>&amp;\"", "<b>&amp;\" </a><a href='x'>",
                    "https://example.invalid/?a=1&b='2'&c=%3Cb%3E");
  g_autoptr(WxSources) s = make_sources(registry);
  GtkLabel *name = GTK_LABEL(row_widget(s, 0, "wx-sources-name"));
  g_assert_false(gtk_label_get_use_markup(name));
  g_assert_cmpstr(gtk_label_get_text(name), ==, "<b>&amp;\"");
  GtkLabel *l = GTK_LABEL(row_widget(s, 0, "wx-sources-attribution"));
  g_assert_true(gtk_label_get_use_markup(l));
  g_assert_cmpstr(gtk_label_get_text(l), ==, "<b>&amp;\" </a><a href='x'>");
  g_assert_cmpstr(gtk_label_get_label(l), ==,
                  "<a href=\"https://example.invalid/?a=1&amp;b=&apos;2&apos;&amp;c=%3Cb%3E\">"
                  "&lt;b&gt;&amp;amp;&quot; &lt;/a&gt;&lt;a href=&apos;x&apos;&gt;</a>");
  /* The markup parsed into exactly one link; nothing from the text became markup. */
  g_assert_cmpuint(g_utf8_strlen(gtk_label_get_text(l), -1), ==, 26);
  g_assert_true(gtk_widget_get_visible(GTK_WIDGET(l)));
}

static void
test_hostile_texts_are_sanitised(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "ctl", "A\x01" "B\nC\tD\xff" "E\xe2\x80\xae" "F",
                    "X\x1b[31mY\r\nZ\xc3", "https://example.invalid/");
  g_autoptr(WxSources) s = make_sources(registry);
  const char *name = row_text(s, 0, "wx-sources-name");
  g_assert_cmpstr(name, ==, "AB" "C" "D\xef\xbf\xbd" "E" "F");
  g_assert_true(g_utf8_validate(name, -1, NULL));
  const char *attribution = row_text(s, 0, "wx-sources-attribution");
  g_assert_cmpstr(attribution, ==, "X[31mYZ\xef\xbf\xbd");
  assert_accessible_label(row_widget(s, 0, "wx-sources-switch"),
                          "Use AB" "C" "D\xef\xbf\xbd" "E" "F");
}

static void
test_empty_name_shows_id_and_empty_attribution_hides(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "blank", "\x01\x02\n", "\x03\t", "https://example.invalid/");
  add_test_provider(registry, "none", "", "", "");
  add_test_provider(registry, "null", NULL, NULL, NULL);
  g_autoptr(WxSources) s = make_sources(registry);
  const char *ids[] = { "blank", "none", "null" };
  for (guint i = 0; i < G_N_ELEMENTS(ids); i++) {
    g_assert_cmpstr(row_text(s, i, "wx-sources-name"), ==, ids[i]);
    GtkWidget *l = row_widget(s, i, "wx-sources-attribution");
    g_assert_false(gtk_widget_get_visible(l));
    g_assert_cmpstr(gtk_label_get_text(GTK_LABEL(l)), ==, "");
    g_autofree char *expected = g_strdup_printf("Use %s", ids[i]);
    assert_accessible_label(row_widget(s, i, "wx-sources-switch"), expected);
  }
}

static void
test_missing_url_gives_plain_text(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "nourl", "No URL", "Credit", NULL);
  g_autoptr(WxSources) s = make_sources(registry);
  GtkLabel *l = GTK_LABEL(row_widget(s, 0, "wx-sources-attribution"));
  g_assert_true(gtk_widget_get_visible(GTK_WIDGET(l)));
  g_assert_false(gtk_label_get_use_markup(l));
  g_assert_cmpstr(gtk_label_get_text(l), ==, "Credit");
}

/* ------------------------------------------------------------------ */
/* Bounded size                                                       */
/* ------------------------------------------------------------------ */

static const char *const label_names[] = {
  "wx-sources-title", "wx-sources-note",        "wx-sources-name",
  "wx-sources-status", "wx-sources-attribution", "wx-sources-licence",
};

static void
test_labels_wrap_and_are_bounded(void)
{
  const char *const ids[] = { "open-meteo", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  for (gsize i = 0; i < G_N_ELEMENTS(label_names); i++) {
    GtkWidget *w = wxt_find_named(GTK_WIDGET(s), label_names[i]);
    g_assert_nonnull(w);
    GtkLabel *l = GTK_LABEL(w);
    g_assert_cmpint(WX_SOURCES_MAX_WIDTH_CHARS, ==, 40);
    g_assert_cmpint(gtk_label_get_max_width_chars(l), ==, 40);
    g_assert_true(gtk_label_get_wrap(l));
    g_assert_cmpint(gtk_label_get_wrap_mode(l), ==, PANGO_WRAP_WORD_CHAR);
  }
}

static int
natural_width(GtkWidget *w)
{
  int nat = 0;
  gtk_widget_measure(w, GTK_ORIENTATION_HORIZONTAL, -1, NULL, &nat, NULL, NULL);
  return nat;
}

static void
test_huge_texts_do_not_grow_the_popover(void)
{
  g_autofree char *huge_word = g_strnfill(5000, 'W');
  g_autofree char *huge_text = g_strjoinv(" ", (char *[]){ huge_word, huge_word, NULL });
  g_autoptr(WxRegistry) small_registry = wx_registry_new();
  add_test_provider(small_registry, "a", "Short", "Credit", "https://example.invalid/");
  g_autoptr(WxSources) small = make_sources(small_registry);

  g_autoptr(WxRegistry) registry = wx_registry_new();
  add_test_provider(registry, "a", huge_text, huge_text, "https://example.invalid/");
  for (int i = 1; i < WX_REGISTRY_MAX_PROVIDERS; i++) {
    g_autofree char *id = g_strdup_printf("p%d", i);
    add_test_provider(registry, id, huge_word, huge_word, "https://example.invalid/");
  }
  g_autoptr(WxSources) big = make_sources(registry);
  g_assert_cmpuint(n_rows(big), ==, WX_REGISTRY_MAX_PROVIDERS);
  for (guint i = 0; i < n_rows(big); i++) {
    g_assert_cmpuint(strlen(row_text(big, i, "wx-sources-name")), <=, WX_SOURCE_TEXT_MAX);
    g_assert_cmpuint(strlen(row_text(big, i, "wx-sources-attribution")), <=, WX_SOURCE_TEXT_MAX);
  }
  int w_small = natural_width(gtk_popover_get_child(GTK_POPOVER(small)));
  int w_big = natural_width(gtk_popover_get_child(GTK_POPOVER(big)));
  g_test_message("natural width: short names %d, hostile names %d", w_small, w_big);
  g_assert_cmpint(w_small, >, 0);
  /* 256 bytes of 'W' unwrapped are several times wider than 40 characters of text. */
  g_assert_cmpint(w_big, <=, w_small * 2);
}

/* ------------------------------------------------------------------ */
/* The honesty note and the About button                              */
/* ------------------------------------------------------------------ */

static void
test_note_text_exact(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxSources) s = make_sources(registry);
  g_assert_cmpstr(wxt_label_text(GTK_WIDGET(s), "wx-sources-note"), ==,
                  "Forecasts blend several sources with fixed, documented weights. These "
                  "weights are rules of thumb, not statistics measured from past accuracy, so "
                  "no accuracy figure is claimed.");
  g_assert_true(gtk_widget_has_css_class(wxt_find_named(GTK_WIDGET(s), "wx-sources-note"),
                                         "wx-sources-note"));
}

static void
test_about_emits_signal(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxSources) s = make_sources(registry);
  guint about = 0, toggled = 0;
  g_signal_connect_swapped(s, "about-requested", G_CALLBACK(count_signal), &about);
  g_signal_connect_swapped(s, "provider-toggled", G_CALLBACK(count_signal), &toggled);
  GtkWidget *button = wxt_find_named(GTK_WIDGET(s), "wx-sources-about");
  g_signal_emit_by_name(button, "clicked");
  g_assert_cmpuint(about, ==, 1);
  g_signal_emit_by_name(button, "clicked");
  g_assert_cmpuint(about, ==, 2);
  g_assert_cmpuint(toggled, ==, 0);
}

/* ------------------------------------------------------------------ */
/* In a window                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
  GtkWidget *window;
  GtkWidget *button;
  WxSources *sources; /* owned by the menu button */
} Shell;

static void
shell_open(Shell *sh, WxRegistry *registry)
{
  sh->window = gtk_window_new();
  sh->button = gtk_menu_button_new();
  sh->sources = WX_SOURCES(wx_sources_new(registry));
  g_assert_nonnull(sh->sources);
  gtk_menu_button_set_popover(GTK_MENU_BUTTON(sh->button), GTK_WIDGET(sh->sources));
  gtk_window_set_child(GTK_WINDOW(sh->window), sh->button);
  gtk_window_present(GTK_WINDOW(sh->window));
  WXT_WAIT_FOR(gtk_widget_get_mapped(sh->button));
}

static void
test_popup_and_popdown_in_menu_button(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  Shell sh;
  shell_open(&sh, registry);
  g_assert_false(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  gtk_menu_button_popup(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(sh.sources), "wx-sources-title"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(sh.sources), "wx-sources-note"));
  g_assert_true(wxt_is_mapped(GTK_WIDGET(sh.sources), "wx-sources-about"));
  g_assert_true(gtk_widget_get_mapped(GTK_WIDGET(row_switch(sh.sources, 1))));
  /* Hidden labels are not mapped, the shown ones are. */
  g_assert_false(gtk_widget_get_mapped(row_widget(sh.sources, 0, "wx-sources-licence")));
  g_assert_true(gtk_widget_get_mapped(row_widget(sh.sources, 0, "wx-sources-attribution")));
  gtk_menu_button_popdown(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(!gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  gtk_window_destroy(GTK_WINDOW(sh.window));
}

static void
test_about_pops_the_popover_down(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  Shell sh;
  shell_open(&sh, registry);
  guint about = 0;
  g_signal_connect_swapped(sh.sources, "about-requested", G_CALLBACK(count_signal), &about);
  gtk_menu_button_popup(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  g_signal_emit_by_name(wxt_find_named(GTK_WIDGET(sh.sources), "wx-sources-about"), "clicked");
  g_assert_cmpuint(about, ==, 1);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  gtk_window_destroy(GTK_WINDOW(sh.window));
}

static void
test_about_activation_in_shown_popover(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  Shell sh;
  shell_open(&sh, registry);
  guint about = 0;
  g_signal_connect_swapped(sh.sources, "about-requested", G_CALLBACK(count_signal), &about);
  gtk_menu_button_popup(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  g_assert_true(gtk_widget_activate(wxt_find_named(GTK_WIDGET(sh.sources), "wx-sources-about")));
  WXT_WAIT_FOR(about == 1);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  gtk_window_destroy(GTK_WINDOW(sh.window));
}

static void
test_switch_activation_in_shown_popover(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  Shell sh;
  shell_open(&sh, registry);
  Toggles t;
  toggles_connect(&t, sh.sources);
  t.apply_to = registry;
  gtk_menu_button_popup(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  /* The keyboard/mouse path of GtkSwitch: "activate" animates the switch, then toggles it. */
  g_assert_true(gtk_widget_activate(GTK_WIDGET(row_switch(sh.sources, 1))));
  WXT_WAIT_FOR(t.count == 1);
  g_assert_cmpstr(t.id, ==, "b");
  g_assert_false(t.enabled);
  g_assert_false(wx_registry_is_enabled(registry, "b"));
  g_assert_false(gtk_switch_get_active(row_switch(sh.sources, 1)));
  wxt_pump_ms(100);
  g_assert_cmpuint(t.count, ==, 1);
  g_assert_cmpstr(status_of(sh.sources, 1), ==, "Turned off");
  toggles_clear(&t);
  gtk_window_destroy(GTK_WINDOW(sh.window));
}

static void
test_menu_button_destroy_releases_registry(void)
{
  const char *const ids[] = { "a", NULL };
  WxRegistry *registry = make_registry(ids);
  WxRegistry *weak = registry;
  g_object_add_weak_pointer(G_OBJECT(registry), (gpointer *)&weak);
  Shell sh;
  shell_open(&sh, registry);
  g_object_unref(registry); /* ours; the popover holds the last reference */
  g_assert_nonnull(weak);
  wx_registry_set_enabled(weak, "a", FALSE);
  g_assert_false(gtk_switch_get_active(row_switch(sh.sources, 0)));
  gtk_window_destroy(GTK_WINDOW(sh.window));
  WXT_WAIT_FOR(weak == NULL);
}

/* ------------------------------------------------------------------ */
/* Keyboard and accessibility                                         */
/* ------------------------------------------------------------------ */

static void
test_keyboard_and_accessible_labels(void)
{
  const char *const ids[] = { "open-meteo", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s = make_sources(registry);
  for (guint i = 0; i < 2; i++) {
    GtkWidget *sw = GTK_WIDGET(row_switch(s, i));
    g_assert_true(gtk_widget_get_focusable(sw));
    g_assert_true(gtk_widget_get_can_focus(sw));
    g_autofree char *expected = g_strdup_printf("Use %s", row_text(s, i, "wx-sources-name"));
    assert_accessible_label(sw, expected);
    /* The checker does discriminate: a different label is reported. */
    g_autofree char *difference = gtk_test_accessible_check_property(
        GTK_ACCESSIBLE(sw), GTK_ACCESSIBLE_PROPERTY_LABEL, "Use something else");
    g_assert_nonnull(difference);
  }
  GtkWidget *about = wxt_find_named(GTK_WIDGET(s), "wx-sources-about");
  g_assert_true(gtk_widget_get_focusable(about));
  g_assert_true(gtk_widget_get_can_focus(about));
  /* The labels that hold a link can be focused to follow it with the keyboard. */
  g_assert_true(gtk_widget_get_focusable(row_widget(s, 0, "wx-sources-attribution")));
  g_assert_true(gtk_widget_get_focusable(row_widget(s, 0, "wx-sources-licence")));
}

static void
test_switch_focus_survives_registry_change(void)
{
  const char *const ids[] = { "a", "b", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  Shell sh;
  shell_open(&sh, registry);
  gtk_menu_button_popup(GTK_MENU_BUTTON(sh.button));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(sh.sources)));
  GtkWidget *sw = GTK_WIDGET(row_switch(sh.sources, 0));
  gtk_widget_grab_focus(sw);
  g_assert_true(gtk_widget_get_focus_child(gtk_widget_get_parent(sw)) == sw);
  wx_registry_set_enabled(registry, "a", FALSE);
  add_fake(registry, "c");
  g_assert_true(GTK_WIDGET(row_switch(sh.sources, 0)) == sw);
  g_assert_true(gtk_widget_get_focus_child(gtk_widget_get_parent(sw)) == sw);
  g_assert_true(gtk_widget_get_mapped(sw));
  g_assert_true(gtk_widget_get_parent(sw) != NULL);
  gtk_window_destroy(GTK_WINDOW(sh.window));
}

/* ------------------------------------------------------------------ */
/* Dispose                                                            */
/* ------------------------------------------------------------------ */

static void
test_dispose_releases_registry_and_handler(void)
{
  const char *const ids[] = { "a", NULL };
  WxRegistry *registry = make_registry(ids);
  WxRegistry *weak = registry;
  g_object_add_weak_pointer(G_OBJECT(registry), (gpointer *)&weak);
  WxSources *s = make_sources(registry);
  g_assert_cmpuint(g_signal_handler_find(registry, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, s), !=,
                   0);
  g_object_unref(registry); /* the popover holds the last reference */
  g_assert_nonnull(weak);
  g_object_unref(s);
  g_assert_null(weak);
}

static void
test_methods_after_dispose_are_noops(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  WxSources *s = make_sources(registry);
  Toggles t;
  toggles_connect(&t, s);
  guint about = 0;
  g_signal_connect_swapped(s, "about-requested", G_CALLBACK(count_signal), &about);
  GtkWidget *sw = GTK_WIDGET(row_switch(s, 0));
  g_object_ref(sw);
  g_object_run_dispose(G_OBJECT(s));
  g_assert_cmpuint(g_signal_handler_find(registry, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, s), ==,
                   0);
  g_autoptr(WxForecast) f = make_forecast1("a", WX_SRC_OK, -1, 2);
  wx_sources_set_forecast(s, f);
  wx_sources_set_forecast(s, NULL);
  g_assert_true(g_atomic_ref_count_compare(&f->ref_count, 1));
  /* The registry changes after dispose: nothing reaches the popover. */
  wx_registry_set_enabled(registry, "a", FALSE);
  add_fake(registry, "b");
  g_assert_true(gtk_switch_get_active(GTK_SWITCH(sw))); /* untouched */
  g_assert_cmpuint(t.count, ==, 0);
  /* A late toggle of a surviving switch emits nothing. */
  gtk_switch_set_active(GTK_SWITCH(sw), FALSE);
  g_assert_cmpuint(t.count, ==, 0);
  g_object_unref(sw);
  g_object_run_dispose(G_OBJECT(s)); /* disposing twice is harmless */
  g_assert_cmpuint(about, ==, 0);
  g_object_unref(s);
  toggles_clear(&t);
}

static void
test_registry_freed_before_late_calls(void)
{
  const char *const ids[] = { "a", NULL };
  WxRegistry *registry = make_registry(ids);
  WxSources *s = make_sources(registry);
  g_object_run_dispose(G_OBJECT(s));
  g_object_unref(registry); /* now the last reference: the registry is gone */
  g_autoptr(WxForecast) f = make_forecast1("a", WX_SRC_OK, -1, 2);
  wx_sources_set_forecast(s, f);
  g_object_unref(s);
}

static void
dispose_in_handler(WxSources *s, const char *id, gboolean enabled, gpointer user_data)
{
  (void)id;
  (void)enabled;
  (*(guint *)user_data)++;
  g_object_run_dispose(G_OBJECT(s));
}

static void
test_dispose_inside_toggle_handler(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  WxSources *s = make_sources(registry);
  guint calls = 0;
  g_signal_connect(s, "provider-toggled", G_CALLBACK(dispose_in_handler), &calls);
  /* GTK's own gtk_switch_set_active() keeps using the switch after the signal returns; the
   * switch is held here, as an owner that disposes a popover mid-toggle must do. */
  GtkWidget *sw = g_object_ref(GTK_WIDGET(row_switch(s, 0)));
  gtk_switch_set_active(GTK_SWITCH(sw), FALSE);
  g_object_unref(sw);
  g_assert_cmpuint(calls, ==, 1);
  g_assert_cmpuint(g_signal_handler_find(registry, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, s), ==,
                   0);
  g_object_unref(s);
}

static void
test_two_popovers_one_registry(void)
{
  const char *const ids[] = { "a", NULL };
  g_autoptr(WxRegistry) registry = make_registry(ids);
  g_autoptr(WxSources) s1 = make_sources(registry);
  WxSources *s2 = make_sources(registry);
  wx_registry_set_enabled(registry, "a", FALSE);
  g_assert_false(gtk_switch_get_active(row_switch(s1, 0)));
  g_assert_false(gtk_switch_get_active(row_switch(s2, 0)));
  g_object_unref(s2);
  wx_registry_set_enabled(registry, "a", TRUE);
  g_assert_true(gtk_switch_get_active(row_switch(s1, 0)));
}

/* ------------------------------------------------------------------ */
/* The harness itself (test-support.h): its fatal-message policy      */
/* ------------------------------------------------------------------ */

/* A warning of the application's own log domain aborts the process. */
static void
test_harness_own_warning_aborts(void)
{
  if (g_test_subprocess()) {
    g_warning("harness probe: an unexpected warning");
    return;
  }
  g_test_trap_subprocess(NULL, 0, 0);
  g_test_trap_assert_failed();
  g_test_trap_assert_stderr("*harness probe: an unexpected warning*");
}

static void
test_harness_own_critical_aborts(void)
{
  if (g_test_subprocess()) {
    g_critical("harness probe: an own critical");
    return;
  }
  g_test_trap_subprocess(NULL, 0, 0);
  g_test_trap_assert_failed();
  g_test_trap_assert_stderr("*harness probe: an own critical*");
}

/* A critical of any other domain aborts too. */
static void
test_harness_foreign_critical_aborts(void)
{
  if (g_test_subprocess()) {
    g_log("GLib-GIO", G_LOG_LEVEL_CRITICAL, "harness probe: a critical of a library");
    return;
  }
  g_test_trap_subprocess(NULL, 0, 0);
  g_test_trap_assert_failed();
  g_test_trap_assert_stderr("*harness probe: a critical of a library*");
}

/* A warning of another domain is printed and does not abort (see the file comment of
 * test-support.h for why). */
static void
test_harness_foreign_warning_does_not_abort(void)
{
  if (g_test_subprocess()) {
    g_log("GLib-GIO", G_LOG_LEVEL_WARNING, "harness probe: a warning of a library");
    return;
  }
  g_test_trap_subprocess(NULL, 0, 0);
  g_test_trap_assert_passed();
  g_test_trap_assert_stderr("*harness probe: a warning of a library*");
}

/* A message that a test expects is checked and does not abort. */
static void
test_harness_expected_warning_passes(void)
{
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "harness probe: expected *");
  g_warning("harness probe: expected warning");
  g_test_assert_expected_messages();
}

/* A test subprocess borrows the root of the process that started it and never removes it (GLib
 * ends a subprocess that hit a fatal message with _exit(), so a root of its own would stay in
 * $TMPDIR for good); the owner still has it afterwards and removes it at its exit. */
static void
test_harness_subprocess_borrows_the_root(void)
{
  if (g_test_subprocess()) {
    const char *owner_root = g_getenv(WXT_OWNER_ROOT_VAR);
    g_assert_nonnull(owner_root);
    g_assert_false(wxt_owns_root);
    g_assert_cmpstr(wxt_root, ==, owner_root);
    g_assert_true(g_str_has_prefix(g_get_user_config_dir(), owner_root));
    wxt_cleanup(); /* a borrower removes nothing */
    return;
  }
  g_assert_true(wxt_owns_root);
  g_test_trap_subprocess(NULL, 0, 0);
  g_test_trap_assert_passed();
  g_assert_true(g_file_test(wxt_root, G_FILE_TEST_IS_DIR));
  g_assert_true(g_str_has_prefix(g_get_user_config_dir(), wxt_root));
  g_assert_true(g_file_test(g_get_user_config_dir(), G_FILE_TEST_IS_DIR));
}

static gboolean
busy_source_cb(gpointer user_data)
{
  (*(guint *)user_data)++;
  g_usleep(3000); /* longer than the 1 ms period: the source is due again at every iteration */
  return G_SOURCE_CONTINUE;
}

/* wxt_pump_ms() returns on time even when a source is always ready. */
static void
test_harness_pump_returns_with_a_busy_source(void)
{
  guint calls = 0;
  guint id = g_timeout_add(1, busy_source_cb, &calls);
  gint64 t0 = g_get_monotonic_time();
  alarm(30); /* a pump that never returns must fail the test, not hang it */
  wxt_pump_ms(100);
  alarm(0);
  gint64 took_ms = (g_get_monotonic_time() - t0) / 1000;
  g_source_remove(id);
  g_assert_cmpint(took_ms, >=, 100);
  g_assert_cmpint(took_ms, <, 1000);
  g_assert_cmpuint(calls, >, 5);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  wxt_setup("weather-test-sources-XXXXXX");
  g_test_init(&argc, &argv, NULL);
  /* See the file comment: the harness' GTK_A11Y=none leaves no accessible properties to read. */
  g_setenv("GTK_A11Y", "test", TRUE);
  if (!wxt_init_gtk())
    return 77;

  g_test_add_func("/sources/new/null", test_new_null);
  g_test_add_func("/harness/own-warning-aborts", test_harness_own_warning_aborts);
  g_test_add_func("/harness/own-critical-aborts", test_harness_own_critical_aborts);
  g_test_add_func("/harness/foreign-critical-aborts", test_harness_foreign_critical_aborts);
  g_test_add_func("/harness/foreign-warning-does-not-abort",
                  test_harness_foreign_warning_does_not_abort);
  g_test_add_func("/harness/expected-warning-passes", test_harness_expected_warning_passes);
  g_test_add_func("/sources/new/wrong-type", test_new_wrong_type);
  g_test_add_func("/sources/set-forecast/bad-self", test_set_forecast_bad_self);
  g_test_add_func("/sources/new/floating-popover", test_new_is_floating_popover);
  g_test_add_func("/sources/layout/empty-registry", test_empty_registry_layout);
  g_test_add_func("/sources/rows/registry-order", test_rows_follow_registry_order);
  g_test_add_func("/sources/rows/sixteen", test_sixteen_providers);
  g_test_add_func("/sources/switch/matches-enabled", test_switch_matches_enabled_flag);
  g_test_add_func("/sources/toggle/emits-once-registry-untouched",
                  test_toggle_emits_once_and_does_not_touch_registry);
  g_test_add_func("/sources/toggle/refused-snaps-back", test_refused_toggle_snaps_back);
  g_test_add_func("/sources/toggle/refused-republishes-accessible-state",
                  test_refused_toggle_republishes_accessible_state);
  g_test_add_func("/sources/toggle/idle-removed-at-dispose",
                  test_pending_idle_is_removed_at_dispose);
  g_test_add_func("/sources/toggle/applied-sticks", test_applied_toggle_sticks);
  g_test_add_func("/sources/toggle/owner-reverts", test_owner_reverting_the_request);
  g_test_add_func("/sources/toggle/id-is-a-copy", test_toggle_id_is_a_copy);
  g_test_add_func("/sources/toggle/each-user-toggle-once", test_each_user_toggle_emits_once);
  g_test_add_func("/sources/registry/resync-without-signal",
                  test_registry_changes_resync_without_signal);
  g_test_add_func("/sources/registry/added-provider-row", test_added_provider_gets_a_row);
  g_test_add_func("/sources/status/no-forecast", test_status_no_forecast);
  g_test_add_func("/sources/status/ok-counts", test_status_ok_counts);
  g_test_add_func("/sources/status/failed-reasons", test_status_failed_reasons);
  g_test_add_func("/sources/status/failed-unknown-code", test_status_failed_unknown_code);
  g_test_add_func("/sources/status/skipped-and-missing", test_status_skipped_and_missing);
  g_test_add_func("/sources/status/entry-by-id", test_status_picks_entry_by_id);
  g_test_add_func("/sources/status/turned-off-precedence", test_status_turned_off_takes_precedence);
  g_test_add_func("/sources/status/replaced-and-cleared",
                  test_status_forecast_replaced_and_cleared);
  g_test_add_func("/sources/status/duplicates-first-wins",
                  test_status_duplicate_entries_first_wins);
  g_test_add_func("/sources/status/follows-registry-no-forecast-ref",
                  test_status_follows_registry_after_forecast_is_gone);
  g_test_add_func("/sources/status/new-row-uses-forecast",
                  test_status_new_row_uses_stored_forecast);
  g_test_add_func("/sources/licence/known-ids", test_licence_known_ids);
  g_test_add_func("/sources/licence/absent-for-other-ids", test_licence_absent_for_other_ids);
  g_test_add_func("/sources/attribution/https-link", test_attribution_https_link);
  g_test_add_func("/sources/attribution/url-accepted-edges",
                  test_attribution_url_accepted_edge_cases);
  g_test_add_func("/sources/attribution/unacceptable-urls-plain",
                  test_attribution_unacceptable_urls_give_plain_text);
  g_test_add_func("/sources/attribution/escaped", test_attribution_text_and_url_are_escaped);
  g_test_add_func("/sources/attribution/hostile-sanitised", test_hostile_texts_are_sanitised);
  g_test_add_func("/sources/attribution/empty-name-and-text",
                  test_empty_name_shows_id_and_empty_attribution_hides);
  g_test_add_func("/sources/attribution/missing-url-plain", test_missing_url_gives_plain_text);
  g_test_add_func("/sources/bounds/labels-wrap", test_labels_wrap_and_are_bounded);
  g_test_add_func("/sources/bounds/huge-texts", test_huge_texts_do_not_grow_the_popover);
  g_test_add_func("/sources/note/text-exact", test_note_text_exact);
  g_test_add_func("/sources/about/emits-signal", test_about_emits_signal);
  g_test_add_func("/sources/window/popup-popdown", test_popup_and_popdown_in_menu_button);
  g_test_add_func("/sources/window/about-pops-down", test_about_pops_the_popover_down);
  g_test_add_func("/sources/window/about-activation", test_about_activation_in_shown_popover);
  g_test_add_func("/sources/window/switch-activation", test_switch_activation_in_shown_popover);
  g_test_add_func("/sources/window/destroy-releases-registry",
                  test_menu_button_destroy_releases_registry);
  g_test_add_func("/sources/window/focus-survives-changes",
                  test_switch_focus_survives_registry_change);
  g_test_add_func("/sources/keyboard/focusable-and-labelled", test_keyboard_and_accessible_labels);
  g_test_add_func("/sources/dispose/releases-registry", test_dispose_releases_registry_and_handler);
  g_test_add_func("/sources/dispose/methods-are-noops", test_methods_after_dispose_are_noops);
  g_test_add_func("/sources/dispose/registry-freed-first", test_registry_freed_before_late_calls);
  g_test_add_func("/sources/dispose/inside-toggle-handler", test_dispose_inside_toggle_handler);
  g_test_add_func("/sources/registry/two-popovers", test_two_popovers_one_registry);
  g_test_add_func("/harness/child-borrows-the-root", test_harness_subprocess_borrows_the_root);
  g_test_add_func("/harness/pump-returns-with-a-busy-source",
                  test_harness_pump_returns_with_a_busy_source);
  return g_test_run();
}
