/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-window.c - WxApp + WxWindow + WxRow/WxRowItem under a display, over the TEST-ONLY fake
 * providers of the net module.
 *
 * Needs a GDK display (run under xvfb-run); exits 77 (meson: skipped) when gtk_init_check() fails.
 * Nothing touches the network or the user's real directories (see test-support.h): the registry
 * holds two fake providers and a fake geocoder, the XDG directories are in a temp root, and the
 * weather files of that root are wiped at the start of every fixture. The application runs for
 * real (g_application_register() / activate, the start-up load on its worker thread, the
 * scheduler, the saves) and is shut down through its "shutdown" vfunc, which drains the saves
 * exactly as at the end of g_application_run().
 *
 * Determinism: the tests pump the main loop until a condition holds (WXT_WAIT_FOR) with a generous
 * deadline. Forecast members are built around the real clock, so texts that depend on the minute
 * of the hour (the "Rain in N min" hint) are asserted through the same pure functions the window
 * uses on the item's own outlook, and exact texts only where they cannot vary (dry, "Raining now",
 * fixed outlooks in the pure tests).
 *
 * Saves: a test that has to know that no save is running (before it edits and starts the next
 * saves, before it abandons saves on purpose, before the storage is wiped) asks the application,
 * not the file system: the three save functions are renamed, in the test's own copy of wx-app.c,
 * to counting functions that count the saves whose completion callback has run (see "Saves in
 * flight"). A file that holds its final text says only
 * that the last write happened, not that the save is over.
 */
#include "test-support.h" /* first: it defines _GNU_SOURCE before any system header */

#include <math.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>

#include "wx-app.h"
#include "wx-blend.h"
#include "wx-cache.h"
#include "wx-fake-provider.h"
#include "wx-format.h"
#include "wx-picker.h"
#include "wx-places.h"
#include "wx-row.h"
#include "wx-scheduler.h"
#include "wx-settings.h"
#include "wx-sources.h"
#include "wx-window.h"

#define NY "America/New_York"

/* Runs @check with the one critical that @fname's g_return_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* ------------------------------------------------------------------ */
/* Saves in flight                                                    */
/* ------------------------------------------------------------------ */

/* The application starts every save with wx_places_save_async(), wx_settings_save_async() or
 * wx_cache_save_async(), and its callback save_done() runs on the main thread when the save is
 * over: that is when the application's own flag "a save of that file is in flight" is cleared and
 * a save of what was edited meanwhile is scheduled. Only that moment tells that a save is over. A
 * file that holds its final text and has no temporary file beside it says less: the worker still
 * synchronises the directory after the rename, and the main loop dispatches the completion later.
 *
 * This executable is therefore linked with a copy of wx-app.c that is compiled with
 * -Dwx_places_save_async=wx_test_counted_places_save_async (and likewise for the other two; see
 * src/ui/meson.build): the renaming is done by the preprocessor, so no linker or optimizer
 * configuration (LTO, IPA clones, --wrap) can route a call around it. The functions below count a
 * save when it starts and again, after the application's callback has returned, when it has
 * finished, and call the real function. The production code has no hook for it. The first test
 * ("/window/app/save-counter-self-check") fails, naming the kind, if a kind of save is not counted.
 * Main thread only, like the application's calls and callbacks. */
static guint n_saves_started;
static guint n_saves_finished;

typedef enum { SAVE_PLACES, SAVE_SETTINGS, SAVE_CACHE, N_SAVE_KINDS } SaveKind;
static const char *const save_kind_names[N_SAVE_KINDS] = {"places", "settings", "cache"};
static guint n_saves_started_of_kind[N_SAVE_KINDS];

/* A one-shot hook that a test arms to act at the first moment after the application starts a
 * save, without polling for it: it runs, and disarms itself, when the next save starts. */
typedef void (*SaveStartHook)(gpointer data);
static SaveStartHook save_start_hook;
static gpointer save_start_hook_data;

/* The saves that have started and whose callback has not returned yet. */
static guint
saves_in_flight(void)
{
  return n_saves_started - n_saves_finished;
}

typedef struct {
  GAsyncReadyCallback callback;
  gpointer user_data;
} CountedSave;

static void
counted_save_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  CountedSave *save = user_data;
  save->callback(source, result, save->user_data);
  n_saves_finished++;
  g_free(save);
}

/* Counts a save that is about to start (and runs the armed hook); returns what the real function
 * gets as its user data. */
static CountedSave *
counted_save_new(SaveKind kind, GAsyncReadyCallback callback, gpointer user_data)
{
  g_assert_nonnull(callback); /* the application always passes its save_done() */
  CountedSave *save = g_new(CountedSave, 1);
  save->callback = callback;
  save->user_data = user_data;
  n_saves_started++;
  n_saves_started_of_kind[kind]++;
  if (save_start_hook != NULL) {
    SaveStartHook hook = save_start_hook;
    save_start_hook = NULL;
    hook(save_start_hook_data);
  }
  return save;
}

#define COUNTED_SAVE(Type, name, Kind)                                                             \
  void wx_test_counted_##name(Type *self, GCancellable *cancellable, GAsyncReadyCallback callback, \
                              gpointer user_data);                                                 \
  void wx_test_counted_##name(Type *self, GCancellable *cancellable, GAsyncReadyCallback callback, \
                              gpointer user_data)                                                  \
  {                                                                                                \
    name(self, cancellable, counted_save_done, counted_save_new(Kind, callback, user_data));       \
  }

COUNTED_SAVE(WxPlaces, wx_places_save_async, SAVE_PLACES)
COUNTED_SAVE(WxSettings, wx_settings_save_async, SAVE_SETTINGS)
COUNTED_SAVE(WxCache, wx_cache_save_async, SAVE_CACHE)

/* Runs the main loop until no save is in flight (60 s at most, monotonic), then asserts it. The
 * condition is produced by this very loop: a worker thread finishes the write, and the completion
 * callback that ends the save is dispatched here, so the loop must run (and sleeps 1 ms when it has
 * nothing to dispatch, instead of spinning, so that the worker gets the CPU). */
static void
wait_saves_done(void)
{
  gint64 end = g_get_monotonic_time() + 60 * G_USEC_PER_SEC;
  while (saves_in_flight() > 0 && g_get_monotonic_time() < end) {
    if (!g_main_context_iteration(NULL, FALSE))
      g_usleep(1000);
  }
  g_assert_cmpuint(saves_in_flight(), ==, 0);
}

/* ------------------------------------------------------------------ */
/* Places, members, storage                                           */
/* ------------------------------------------------------------------ */

static WxPlace *
place_new(const char *name, double lat, double lon)
{
  GError *err = NULL;
  WxPlace *p = wx_place_new(name, "Florida", "United States", "US", lat, lon, NY, &err);
  g_assert_no_error(err);
  return p;
}

static WxPlace *
miami(void)
{
  return place_new("Miami", 25.7743, -80.1937);
}

static WxPlace *
orlando(void)
{
  return place_new("Orlando", 28.5383, -81.3792);
}

static WxPlace *
tampa(void)
{
  return place_new("Tampa", 27.9475, -82.4584);
}

static char *
key_of(WxPlace *p)
{
  return wx_place_key(p);
}

typedef enum { RAIN_DRY, RAIN_NOW, RAIN_SOON, RAIN_LATER } RainKind;

static gint64
real_now(void)
{
  return g_get_real_time() / G_USEC_PER_SEC;
}

/* A member with hourly data from 2 h ago to 72 h ahead of the real clock (so every fixture that
 * runs for a minute is covered): 24 degC, 40 % cloud, and the rain of @kind:
 *  - RAIN_DRY: none;
 *  - RAIN_NOW: 2 mm/h at 80 % from the previous hour to 4 hours ahead (so it rains now whatever
 *    the minute of the hour);
 *  - RAIN_SOON: 2 mm/h at 80 % in the 3 hours that start with the next hour boundary (less than an
 *    hour away);
 *  - RAIN_LATER: 2 mm/h at 80 % in the 3 hours that start 4 hours ahead. */
static WxMember *
make_member(const char *source, RainKind rain)
{
  gint64 now = real_now();
  gint64 base = now - now % 3600;
  GError *err = NULL;
  WxMember *m = wx_member_new(source, "m1", now, &err);
  g_assert_no_error(err);
  for (int i = -2; i < 72; i++) {
    WxHour h;
    wx_hour_init(&h);
    h.t_s = base + (gint64)i * 3600;
    h.temp_c = 24;
    h.feels_c = 26;
    h.humidity_pct = 70;
    h.cloud_pct = 40;
    h.wind_kmh = 12;
    h.gust_kmh = 20;
    h.precip_mm = 0;
    h.precip_prob = 5;
    gboolean wet = FALSE;
    switch (rain) {
    case RAIN_NOW:
      wet = i >= -1 && i < 4;
      break;
    case RAIN_SOON:
      wet = i >= 1 && i < 4;
      break;
    case RAIN_LATER:
      wet = i >= 4 && i < 7;
      break;
    case RAIN_DRY:
    default:
      break;
    }
    if (wet) {
      h.precip_mm = 2.0;
      h.precip_prob = 80;
    }
    g_assert_true(wx_member_add_hour(m, &h));
  }
  return m;
}

/* Whether a temporary file of an atomic write ("<path>.wx-tmp-XXXXXX") exists in the weather
 * directories: a save is between creating it and renaming it into place. */
static gboolean
tmp_files_present(void)
{
  const char *dirs[] = {g_get_user_config_dir(), g_get_user_cache_dir()};
  for (guint i = 0; i < G_N_ELEMENTS(dirs); i++) {
    g_autofree char *dir = g_build_filename(dirs[i], "weather", NULL);
    g_autoptr(GDir) d = g_dir_open(dir, 0, NULL);
    const char *name;
    while (d != NULL && (name = g_dir_read_name(d)) != NULL)
      if (strstr(name, ".wx-tmp-") != NULL)
        return TRUE;
  }
  return FALSE;
}

/* Removes everything the application stores, so the next fixture starts like a first run. A save
 * that is still running would fail (its directory is gone) and its late warning would be fatal in
 * whichever test runs next, so this first waits, bounded, until every save the application started
 * has completed (wait_saves_done()): no write is left then. */
static void
reset_storage(void)
{
  wait_saves_done();
  g_assert_false(tmp_files_present());
  g_autofree char *cfg = g_build_filename(g_get_user_config_dir(), "weather", NULL);
  g_autofree char *cache = g_build_filename(g_get_user_cache_dir(), "weather", NULL);
  wxt_remove_tree(cfg);
  wxt_remove_tree(cache);
}

/* Writes places.json with @places (a NULL-terminated array of owned places, freed here). */
static void
store_places(WxPlace **places)
{
  g_autoptr(WxPlaces) list = wx_places_new(NULL);
  for (guint i = 0; places[i] != NULL; i++) {
    g_assert_true(wx_places_add(list, places[i]));
    wx_place_free(places[i]);
  }
  GError *err = NULL;
  g_assert_true(wx_places_save(list, &err));
  g_assert_no_error(err);
}

static void
store_settings(WxUnits units, const char *disabled_id, const char *selected)
{
  g_autoptr(WxSettings) s = wx_settings_new(NULL);
  g_assert_true(units == WX_UNITS_IMPERIAL || wx_settings_set_units(s, units));
  if (disabled_id != NULL)
    g_assert_true(wx_settings_set_provider_disabled(s, disabled_id, TRUE));
  if (selected != NULL)
    g_assert_true(wx_settings_set_selected(s, selected));
  GError *err = NULL;
  g_assert_true(wx_settings_save(s, &err));
  g_assert_no_error(err);
}

/* ------------------------------------------------------------------ */
/* Widget helpers                                                     */
/* ------------------------------------------------------------------ */

static void
collect_type(GtkWidget *root, GType type, GPtrArray *out)
{
  if (G_TYPE_CHECK_INSTANCE_TYPE(root, type))
    g_ptr_array_add(out, root);
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL;
       c = gtk_widget_get_next_sibling(c))
    collect_type(c, type, out);
}

/* The mapped WxRow whose name label shows @name, or NULL. */
static GtkWidget *
row_named(GtkWidget *window, const char *name)
{
  g_autoptr(GPtrArray) rows = g_ptr_array_new();
  collect_type(window, WX_TYPE_ROW, rows);
  for (guint i = 0; i < rows->len; i++) {
    GtkWidget *row = g_ptr_array_index(rows, i);
    if (gtk_widget_get_mapped(row) && g_strcmp0(wxt_label_text(row, "wx-row-name"), name) == 0)
      return row;
  }
  return NULL;
}

/* The first toplevel of @type, or NULL. */
static GtkWidget *
toplevel_of_type(GType type)
{
  GtkWidget *found = NULL;
  GListModel *tops = gtk_window_get_toplevels();
  for (guint i = 0, n = g_list_model_get_n_items(tops); i < n && found == NULL; i++) {
    g_autoptr(GObject) w = g_list_model_get_item(tops, i);
    if (G_TYPE_CHECK_INSTANCE_TYPE(w, type))
      found = GTK_WIDGET(w);
  }
  return found;
}

static guint
toplevels_of_type(GType type)
{
  guint count = 0;
  GListModel *tops = gtk_window_get_toplevels();
  for (guint i = 0, n = g_list_model_get_n_items(tops); i < n; i++) {
    g_autoptr(GObject) w = g_list_model_get_item(tops, i);
    count += G_TYPE_CHECK_INSTANCE_TYPE(w, type) ? 1 : 0;
  }
  return count;
}

static void
click(GtkWidget *w)
{
  g_assert_nonnull(w);
  g_assert_true(gtk_widget_get_sensitive(w));
  g_signal_emit_by_name(w, "clicked");
}

/* ------------------------------------------------------------------ */
/* A provider that answers when the test says so                      */
/* ------------------------------------------------------------------ */

/* The fakes of the net module answer after a delay on a timer. A test that needs "a request is in
 * flight" for as long as it likes, however slow the machine (valgrind, a loaded CI), uses a Gate
 * instead: a provider whose fetches stay pending until gate_release(). The service stops waiting
 * for it when the caller cancels, like for any provider. */
#define TYPE_GATE (gate_get_type())
G_DECLARE_FINAL_TYPE(Gate, gate, TEST, GATE, GObject)

struct _Gate {
  GObject parent_instance;
  GPtrArray *pending; /* GTask*: the fetches that were not answered yet */
  GCancellable *last; /* the cancellable of the latest fetch (strong) */
  GPtrArray *all;     /* GCancellable*: the cancellable of every fetch (strong) */
  guint fetches;
  WxMember *member; /* what an OK answer carries */
};

static void gate_provider_init(WxProviderInterface *iface);

G_DEFINE_TYPE_WITH_CODE(Gate, gate, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, gate_provider_init))

static const char *
gate_get_id(WxProvider *provider)
{
  (void)provider;
  return "gate";
}

static const char *
gate_get_name(WxProvider *provider)
{
  (void)provider;
  return "Gate";
}

static const char *
gate_get_attribution(WxProvider *provider)
{
  (void)provider;
  return "Gate data";
}

static const char *
gate_get_attribution_url(WxProvider *provider)
{
  (void)provider;
  return "https://example.invalid/";
}

static gboolean
gate_covers(WxProvider *provider, const WxPlace *place)
{
  (void)provider;
  (void)place;
  return TRUE;
}

static void
gate_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
                 GAsyncReadyCallback callback, gpointer user_data)
{
  (void)place;
  Gate *self = TEST_GATE(provider);
  self->fetches++;
  g_set_object(&self->last, cancellable);
  if (cancellable != NULL)
    g_ptr_array_add(self->all, g_object_ref(cancellable));
  GTask *task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_check_cancellable(task, FALSE);
  g_ptr_array_add(self->pending, task);
}

static WxSourceResult *
gate_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  (void)provider;
  return g_task_propagate_pointer(G_TASK(result), error);
}

static void
gate_provider_init(WxProviderInterface *iface)
{
  iface->get_id = gate_get_id;
  iface->get_name = gate_get_name;
  iface->get_attribution = gate_get_attribution;
  iface->get_attribution_url = gate_get_attribution_url;
  iface->covers = gate_covers;
  iface->fetch_async = gate_fetch_async;
  iface->fetch_finish = gate_fetch_finish;
}

/* Answers every pending fetch: with the member for @code -1, else with the WxError @code and
 * @message. (A callback that starts a new fetch finds the pending list empty and fills it
 * again.) */
static void
gate_release_with(Gate *self, int code, const char *message)
{
  g_autoptr(GPtrArray) tasks = g_steal_pointer(&self->pending);
  self->pending = g_ptr_array_new_with_free_func(g_object_unref);
  for (guint i = 0; i < tasks->len; i++) {
    GTask *task = g_ptr_array_index(tasks, i);
    if (code < 0) {
      GError *err = NULL;
      WxSourceResult *res = wx_source_result_new("gate", &err);
      g_assert_no_error(err);
      g_ptr_array_add(res->members, wx_member_ref(self->member));
      g_task_return_pointer(task, res, (GDestroyNotify)wx_source_result_free);
    } else {
      g_task_return_new_error(task, WX_ERROR, code, "%s", message);
    }
  }
}

static void
gate_release(Gate *self, int code)
{
  gate_release_with(self, code, "gate failure");
}

static void
gate_finalize(GObject *object)
{
  Gate *self = TEST_GATE(object);
  /* Whatever is still pending ends cancelled (the service has stopped waiting by then). */
  g_autoptr(GPtrArray) tasks = g_steal_pointer(&self->pending);
  for (guint i = 0; i < tasks->len; i++)
    g_task_return_new_error(g_ptr_array_index(tasks, i), G_IO_ERROR, G_IO_ERROR_CANCELLED,
                            "gate gone");
  g_clear_object(&self->last);
  g_clear_pointer(&self->all, g_ptr_array_unref);
  g_clear_pointer(&self->member, wx_member_unref);
  G_OBJECT_CLASS(gate_parent_class)->finalize(object);
}

static void
gate_class_init(GateClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = gate_finalize;
}

static void
gate_init(Gate *self)
{
  self->pending = g_ptr_array_new_with_free_func(g_object_unref);
  self->all = g_ptr_array_new_with_free_func(g_object_unref);
}

/* ------------------------------------------------------------------ */
/* Fixture                                                            */
/* ------------------------------------------------------------------ */

typedef struct {
  RainKind rain;
  int fail_a; /* -1: succeed; else a WxError */
  int fail_b;
  guint delay_ms;
  gboolean gated; /* the registry also holds a Gate (see fx_add_gate()) */
} FxConfig;

typedef struct {
  WxRegistry *registry;
  WxFakeProvider *a;
  WxFakeProvider *b;
  Gate *gate; /* NULL unless gated */
  WxFakeGeocoder *geocoder;
  WxApp *app;
} Fx;

/* Registers a third provider, "gate", that covers every place and answers only when the test says
 * so; a refresh then stays in flight until gate_release(). Call before the application starts. */
static void
fx_add_gate(Fx *fx, RainKind rain)
{
  g_assert_null(fx->gate);
  fx->gate = g_object_new(TYPE_GATE, NULL);
  fx->gate->member = make_member("gate", rain);
  GError *err = NULL;
  g_assert_true(wx_registry_add_provider(fx->registry, WX_PROVIDER(fx->gate), &err));
  g_assert_no_error(err);
}

static Gate *
gate_of(Fx *fx)
{
  g_assert_nonnull(fx->gate);
  return fx->gate;
}

/* TRUE iff the latest request that reached the gate was cancelled (by the application). */
static gboolean
gate_cancelled(Fx *fx)
{
  return gate_of(fx)->last != NULL && g_cancellable_is_cancelled(gate_of(fx)->last);
}

/* A fixture over two fake providers ("fake-a", "fake-b") that cover every place, and a fake
 * geocoder; the weather files are wiped; no application exists yet. */
static Fx *
fx_new(const FxConfig *cfg)
{
  reset_storage();
  Fx *fx = g_new0(Fx, 1);
  fx->registry = wx_registry_new();
  fx->a = wx_fake_provider_new("fake-a");
  fx->b = wx_fake_provider_new("fake-b");
  fx->geocoder = wx_fake_geocoder_new();
  g_autoptr(WxMember) ma = make_member("fake-a", cfg->rain);
  g_autoptr(WxMember) mb = make_member("fake-b", cfg->rain);
  wx_fake_provider_add_member(fx->a, ma);
  wx_fake_provider_add_member(fx->b, mb);
  wx_fake_provider_fail_with(fx->a, cfg->fail_a);
  wx_fake_provider_fail_with(fx->b, cfg->fail_b);
  wx_fake_provider_set_delay_ms(fx->a, cfg->delay_ms);
  wx_fake_provider_set_delay_ms(fx->b, cfg->delay_ms);
  GError *err = NULL;
  g_assert_true(wx_registry_add_provider(fx->registry, WX_PROVIDER(fx->a), &err));
  g_assert_no_error(err);
  g_assert_true(wx_registry_add_provider(fx->registry, WX_PROVIDER(fx->b), &err));
  g_assert_no_error(err);
  wx_registry_set_geocoder(fx->registry, WX_GEOCODER(fx->geocoder));
  if (cfg->gated)
    fx_add_gate(fx, cfg->rain);
  return fx;
}

#define FX_DEFAULT {RAIN_DRY, -1, -1, 0, FALSE}

static void warp_clocks(gint64 seconds); /* defined below with the clock shim */

static GtkWidget *
fx_window(Fx *fx)
{
  GList *windows = gtk_application_get_windows(GTK_APPLICATION(fx->app));
  return windows != NULL ? GTK_WIDGET(windows->data) : NULL;
}

/* Creates the application over the fixture's registry and registers it (which runs "startup" and
 * starts the load on its worker). Several applications with the same id live in one process, one
 * after the other, so none of them is the unique instance. */
static void
fx_register(Fx *fx)
{
  fx->app = wx_app_new_with_registry(fx->registry);
  g_assert_nonnull(fx->app);
  g_application_set_flags(G_APPLICATION(fx->app), G_APPLICATION_NON_UNIQUE);
  GError *err = NULL;
  g_assert_true(g_application_register(G_APPLICATION(fx->app), NULL, &err));
  g_assert_no_error(err);
}

/* Starts the application like g_application_run() does (register -> startup -> activate) and
 * waits until its window is on screen. */
static GtkWidget *
fx_start(Fx *fx)
{
  fx_register(fx);
  g_application_activate(G_APPLICATION(fx->app));
  WXT_WAIT_FOR(fx_window(fx) != NULL);
  WXT_WAIT_FOR(gtk_widget_get_mapped(fx_window(fx)));
  wxt_pump_idle();
  return fx_window(fx);
}

/* Ends the application like the end of g_application_run(): its "shutdown" vfunc cancels the
 * requests, saves what is dirty and drains. Returns how long that took (ms). */
static gint64
fx_stop(Fx *fx)
{
  gint64 t0 = g_get_monotonic_time();
  G_APPLICATION_GET_CLASS(fx->app)->shutdown(G_APPLICATION(fx->app));
  gint64 ms = (g_get_monotonic_time() - t0) / 1000;
  GList *windows = g_list_copy(gtk_application_get_windows(GTK_APPLICATION(fx->app)));
  for (GList *l = windows; l != NULL; l = l->next)
    gtk_window_destroy(GTK_WINDOW(l->data));
  g_list_free(windows);
  g_clear_object(&fx->app);
  wxt_pump_idle();
  return ms;
}

/* Stops the application and starts a new one over the same registry and files. */
static GtkWidget *
fx_restart(Fx *fx)
{
  fx_stop(fx);
  return fx_start(fx);
}

static void
fx_free(Fx *fx)
{
  if (fx->app != NULL)
    fx_stop(fx);
  g_clear_object(&fx->registry);
  g_clear_object(&fx->a);
  g_clear_object(&fx->gate);
  g_clear_object(&fx->b);
  g_clear_object(&fx->geocoder);
  g_free(fx);
  reset_storage();
}

static WxRowItem *
fx_item(Fx *fx, guint i)
{
  GListModel *items = wx_app_get_items(fx->app);
  g_assert_cmpuint(i, <, g_list_model_get_n_items(items));
  g_autoptr(WxRowItem) item = g_list_model_get_item(items, i);
  return item; /* the model keeps it alive */
}

static guint
fx_n_items(Fx *fx)
{
  return g_list_model_get_n_items(wx_app_get_items(fx->app));
}

#define WAIT_FORECAST(item) WXT_WAIT_FOR(wx_row_item_get_forecast(item) != NULL)

/* Text of the detail pane's label @name. */
static const char *
dtext(GtkWidget *window, const char *name)
{
  return wxt_label_text(window, name);
}

/* The detail footer is ONE label, "Updated ... · Sources: ...": its two parts (the second starts
 * with "Sources: "), as strings that live until the end of the test. */
static const char *
footer_part(GtkWidget *window, gboolean sources)
{
  const char *full = dtext(window, "wx-detail-footer");
  const char *sep = strstr(full, " \xC2\xB7 Sources: ");
  g_assert_nonnull(sep);
  char *part = sources ? g_strdup(sep + strlen(" \xC2\xB7 ")) : g_strndup(full, (gsize)(sep - full));
  g_test_queue_free(part);
  return part;
}

#define FOOTER_UPDATED(win) footer_part((win), FALSE)
#define FOOTER_SOURCES(win) footer_part((win), TRUE)

/* ------------------------------------------------------------------ */
/* Pure: the rain hint                                                */
/* ------------------------------------------------------------------ */

/* Sunday 2026-10-11 18:30Z = 2:30 PM in New York (EDT). */
static gint64
ts(int y, int mo, int d, int h, int mi)
{
  g_autoptr(GDateTime) dt = g_date_time_new_utc(y, mo, d, h, mi, 0);
  g_assert_nonnull(dt);
  return g_date_time_to_unix(dt);
}

#define T_NOW ts(2026, 10, 11, 18, 30)

static void
check_hint(WxRainState state, gint64 start, gint64 end, gboolean ends_known, const char *expected)
{
  WxRainOutlook o = {.state = state, .start_s = start, .end_s = end, .peak_s = start,
                     .peak_mm_h = 1, .peak_prob = 50, .ends_known = ends_known};
  g_autofree char *hint = wx_row_rain_hint(&o, T_NOW, NY);
  g_assert_cmpstr(hint, ==, expected);
}

static void
test_hint_table(void)
{
  check_hint(WX_RAIN_NOW, T_NOW - 1800, T_NOW + 3600, TRUE, "Raining until 3:30 PM");
  check_hint(WX_RAIN_NOW, T_NOW - 1800, 0, FALSE, "Raining now");
  check_hint(WX_RAIN_NOW, T_NOW - 1800, T_NOW - 60, TRUE, "Raining now");
  check_hint(WX_RAIN_NOW, T_NOW - 1800, 5, TRUE, "Raining now"); /* end not a valid time */
  check_hint(WX_RAIN_EXPECTED, T_NOW + 25 * 60, 0, FALSE, "Rain in 25 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 1, 0, FALSE, "Rain in 1 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 60, 0, FALSE, "Rain in 1 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 61, 0, FALSE, "Rain in 2 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 89 * 60, 0, FALSE, "Rain in 89 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 90 * 60 - 1, 0, FALSE, "Rain in 90 min");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 90 * 60, 0, FALSE, "Rain at 4 PM");
  check_hint(WX_RAIN_EXPECTED, T_NOW + 2 * 3600 + 15 * 60, 0, FALSE, "Rain at 4:45 PM");
  check_hint(WX_RAIN_EXPECTED, T_NOW, 0, FALSE, "Rain starting now");
  check_hint(WX_RAIN_EXPECTED, T_NOW - 100, 0, FALSE, "Rain starting now");
  check_hint(WX_RAIN_EXPECTED, ts(2026, 10, 12, 20, 0), 0, FALSE, "Rain tomorrow, 4 PM");
  check_hint(WX_RAIN_EXPECTED, ts(2026, 10, 13, 20, 0), 0, FALSE, "Rain Tuesday, 4 PM");
  check_hint(WX_RAIN_EXPECTED, 7, 0, FALSE, "Rain expected");
  check_hint(WX_RAIN_POSSIBLE, 0, 0, FALSE, "Showers possible");
  check_hint(WX_RAIN_DRY, 0, 0, FALSE, "Dry for 48 h");
}

static void
test_hint_edges(void)
{
  WxRainOutlook o = {.state = WX_RAIN_EXPECTED, .start_s = T_NOW + 600};
  /* A now outside the valid time range gives an empty hint, except for the dry sentence. */
  g_autofree char *a = wx_row_rain_hint(&o, 0, NY);
  g_assert_cmpstr(a, ==, "");
  g_autofree char *b = wx_row_rain_hint(&o, G_MAXINT64, NY);
  g_assert_cmpstr(b, ==, "");
  g_autofree char *c = wx_row_rain_hint(&o, G_MININT64, NY);
  g_assert_cmpstr(c, ==, "");
  o.state = WX_RAIN_DRY;
  g_autofree char *d = wx_row_rain_hint(&o, G_MININT64, NY);
  g_assert_cmpstr(d, ==, "Dry for 48 h");
  /* Extreme stamps never overflow. */
  o = (WxRainOutlook){.state = WX_RAIN_EXPECTED, .start_s = G_MAXINT64};
  g_autofree char *e = wx_row_rain_hint(&o, T_NOW, NY);
  g_assert_cmpstr(e, ==, "Rain expected");
  o = (WxRainOutlook){.state = WX_RAIN_NOW, .end_s = G_MININT64, .ends_known = TRUE};
  g_autofree char *f = wx_row_rain_hint(&o, T_NOW, NY);
  g_assert_cmpstr(f, ==, "Raining now");
  /* The zone decides the clock; a bad zone is UTC. */
  o = (WxRainOutlook){.state = WX_RAIN_EXPECTED, .start_s = T_NOW + 3 * 3600};
  g_autofree char *g = wx_row_rain_hint(&o, T_NOW, "Asia/Tokyo");
  g_assert_cmpstr(g, ==, "Rain at 6:30 AM");
  g_autofree char *h = wx_row_rain_hint(&o, T_NOW, "../etc/passwd");
  g_assert_cmpstr(h, ==, "Rain at 9:30 PM");
  g_autofree char *i = wx_row_rain_hint(&o, T_NOW, NULL);
  g_assert_cmpstr(i, ==, "Rain at 9:30 PM");
}

static void
test_hint_programmer_errors(void)
{
  ASSERT_CRITICAL("wx_row_rain_hint", g_assert_null(wx_row_rain_hint(NULL, T_NOW, NY)));
  WxRainOutlook o = {.state = (WxRainState)99};
  ASSERT_CRITICAL("wx_row_rain_hint", g_assert_null(wx_row_rain_hint(&o, T_NOW, NY)));
}

/* ------------------------------------------------------------------ */
/* Pure: WxRowItem                                                    */
/* ------------------------------------------------------------------ */

static guint item_changes;

static void
on_item_changed(WxRowItem *item, gpointer data)
{
  (void)item;
  (void)data;
  item_changes++;
}

/* A forecast of a dry day around T_NOW, or a wet one when @wet, built by hand. */
static WxForecast *
make_forecast(const WxPlace *place, gboolean wet)
{
  WxBlendHour hours[72]; /* more than 48 h after T_NOW: the dry claim needs the whole horizon */
  gint64 base = T_NOW - T_NOW % 3600;
  for (guint i = 0; i < G_N_ELEMENTS(hours); i++) {
    hours[i] = (WxBlendHour){.t_s = base + (gint64)i * 3600, .temp_c = 25, .feels_c = 27,
                             .precip_mm = wet && i < 3 ? 2.0 : 0.0,
                             .precip_mm_max = wet && i < 3 ? 2.0 : 0.0,
                             .precip_prob = wet && i < 3 ? 80 : 5, .cloud_pct = 50, .wind_kmh = 10,
                             .gust_kmh = 15, .humidity_pct = 60, .temp_spread_c = NAN,
                             .n_members = 2, .condition = wet && i < 3 ? WX_COND_RAIN
                                                                       : WX_COND_PARTLY_CLOUDY,
                             .is_day = TRUE};
  }
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, T_NOW, hours, G_N_ELEMENTS(hours), NULL, 0, NULL, 0, NULL,
                                  0, &err);
  g_assert_no_error(err);
  return f;
}

static void
test_item_defaults_and_args(void)
{
  g_autoptr(WxPlace) p = miami();
  ASSERT_CRITICAL("wx_row_item_new", g_assert_null(wx_row_item_new(NULL)));
  /* A hand-built place that breaks the wx_place_new() rules is refused without a critical. */
  WxPlace bad = {.name = (char *)"", .admin1 = (char *)"", .country = (char *)"",
                 .timezone = (char *)"", .lat = 1, .lon = 1};
  g_assert_null(wx_row_item_new(&bad));

  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  g_assert_nonnull(item);
  g_autofree char *key = wx_place_key(p);
  g_assert_cmpstr(wx_row_item_get_key(item), ==, key);
  g_assert_cmpstr(wx_row_item_get_place(item)->name, ==, "Miami");
  g_assert_true(wx_row_item_get_place(item) != p); /* a private copy */
  g_assert_null(wx_row_item_get_forecast(item));
  g_assert_cmpint(wx_row_item_get_fetched_s(item), ==, 0);
  g_assert_false(wx_row_item_get_loading(item));
  g_assert_false(wx_row_item_get_stale(item));
  g_assert_false(wx_row_item_get_offline(item));
  g_assert_cmpint(wx_row_item_get_units(item), ==, WX_UNITS_IMPERIAL);
  g_assert_null(wx_row_item_get_error(item));
  g_assert_null(wx_row_item_get_outlook(item));
  WxBlendHour cur;
  g_assert_false(wx_row_item_get_current(item, &cur));
  g_assert_cmpint(llabs(wx_row_item_get_now_s(item) - real_now()), <=, 2);

  /* NULL / wrong-type arguments of every accessor and setter. */
  ASSERT_CRITICAL("wx_row_item_get_place", g_assert_null(wx_row_item_get_place(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_key", g_assert_null(wx_row_item_get_key(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_forecast", g_assert_null(wx_row_item_get_forecast(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_fetched_s", g_assert_cmpint(wx_row_item_get_fetched_s(NULL), ==, 0));
  ASSERT_CRITICAL("wx_row_item_get_loading", g_assert_false(wx_row_item_get_loading(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_stale", g_assert_false(wx_row_item_get_stale(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_offline", g_assert_false(wx_row_item_get_offline(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_units",
                  g_assert_cmpint(wx_row_item_get_units(NULL), ==, WX_UNITS_IMPERIAL));
  ASSERT_CRITICAL("wx_row_item_get_now_s", g_assert_cmpint(wx_row_item_get_now_s(NULL), ==, 0));
  ASSERT_CRITICAL("wx_row_item_get_error", g_assert_null(wx_row_item_get_error(NULL)));
  ASSERT_CRITICAL("wx_row_item_get_current", g_assert_false(wx_row_item_get_current(NULL, &cur)));
  ASSERT_CRITICAL("wx_row_item_get_current", g_assert_false(wx_row_item_get_current(item, NULL)));
  ASSERT_CRITICAL("wx_row_item_get_outlook", g_assert_null(wx_row_item_get_outlook(NULL)));
  ASSERT_CRITICAL("wx_row_item_set_forecast", g_assert_false(wx_row_item_set_forecast(NULL, NULL, 0)));
  ASSERT_CRITICAL("wx_row_item_set_loading", g_assert_false(wx_row_item_set_loading(NULL, TRUE)));
  ASSERT_CRITICAL("wx_row_item_set_stale", g_assert_false(wx_row_item_set_stale(NULL, TRUE)));
  ASSERT_CRITICAL("wx_row_item_set_offline", g_assert_false(wx_row_item_set_offline(NULL, TRUE)));
  ASSERT_CRITICAL("wx_row_item_set_units",
                  g_assert_false(wx_row_item_set_units(NULL, WX_UNITS_METRIC)));
  ASSERT_CRITICAL("wx_row_item_set_units", g_assert_false(wx_row_item_set_units(item, (WxUnits)7)));
  ASSERT_CRITICAL("wx_row_item_set_now_s", g_assert_false(wx_row_item_set_now_s(NULL, 1)));
  ASSERT_CRITICAL("wx_row_item_set_error", g_assert_false(wx_row_item_set_error(NULL, "x")));
  g_assert_cmpint(wx_row_item_get_units(item), ==, WX_UNITS_IMPERIAL);
}

static void
test_item_setters(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  item_changes = 0;
  g_signal_connect(item, "changed", G_CALLBACK(on_item_changed), NULL);

  g_assert_true(wx_row_item_set_loading(item, TRUE));
  g_assert_false(wx_row_item_set_loading(item, TRUE));
  g_assert_false(wx_row_item_set_loading(item, 7)); /* any non-zero value is TRUE: equal, no change */
  g_assert_cmpuint(item_changes, ==, 1);
  g_assert_true(wx_row_item_set_loading(item, FALSE));
  g_assert_true(wx_row_item_set_stale(item, TRUE));
  g_assert_false(wx_row_item_set_stale(item, TRUE));
  g_assert_true(wx_row_item_set_offline(item, TRUE));
  g_assert_false(wx_row_item_set_offline(item, TRUE));
  g_assert_true(wx_row_item_set_units(item, WX_UNITS_METRIC));
  g_assert_false(wx_row_item_set_units(item, WX_UNITS_METRIC));
  g_assert_cmpuint(item_changes, ==, 5);
  g_assert_true(wx_row_item_get_stale(item));
  g_assert_true(wx_row_item_get_offline(item));
  g_assert_cmpint(wx_row_item_get_units(item), ==, WX_UNITS_METRIC);

  /* The error text is sanitised and cut. */
  item_changes = 0;
  g_assert_false(wx_row_item_set_error(item, NULL));
  g_assert_false(wx_row_item_set_error(item, ""));
  g_assert_cmpuint(item_changes, ==, 0);
  g_assert_true(wx_row_item_set_error(item, "fake-a: network\nerror\x01 \xE2\x80\xAE" "evil"));
  g_assert_cmpstr(wx_row_item_get_error(item), ==, "fake-a: networkerror evil");
  g_assert_false(wx_row_item_set_error(item, "fake-a: networkerror evil"));
  g_assert_true(wx_row_item_set_error(item, "\x01\x02")); /* nothing left: no error */
  g_assert_null(wx_row_item_get_error(item));
  g_autofree char *huge = g_strnfill(10000, 'x');
  g_assert_true(wx_row_item_set_error(item, huge));
  g_assert_cmpuint(strlen(wx_row_item_get_error(item)), ==, WX_ROW_ERROR_MAX_BYTES);
  g_assert_true(wx_row_item_set_error(item, NULL));
  g_assert_null(wx_row_item_get_error(item));
  g_assert_cmpuint(item_changes, ==, 4);
}

static void
test_item_forecast_and_now(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  g_autoptr(WxForecast) f = make_forecast(p, FALSE);
  g_autoptr(WxForecast) wet = make_forecast(p, TRUE);
  item_changes = 0;
  g_signal_connect(item, "changed", G_CALLBACK(on_item_changed), NULL);
  wx_row_item_set_now_s(item, T_NOW);
  g_assert_cmpuint(item_changes, ==, 1);
  g_assert_false(wx_row_item_set_now_s(item, T_NOW));

  g_assert_true(wx_row_item_set_forecast(item, f, T_NOW - 120));
  g_assert_false(wx_row_item_set_forecast(item, f, T_NOW - 120));
  g_assert_true(wx_row_item_set_forecast(item, f, T_NOW - 60)); /* same forecast, other time */
  g_assert_cmpint(wx_row_item_get_fetched_s(item), ==, T_NOW - 60);
  g_assert_true(wx_row_item_get_forecast(item) == f);
  g_assert_cmpuint(item_changes, ==, 3);
  WxBlendHour cur;
  g_assert_true(wx_row_item_get_current(item, &cur));
  g_assert_cmpfloat(cur.temp_c, ==, 25);
  const WxRainOutlook *o = wx_row_item_get_outlook(item);
  g_assert_nonnull(o);
  g_assert_cmpint(o->state, ==, WX_RAIN_DRY);

  g_assert_true(wx_row_item_set_forecast(item, wet, T_NOW));
  o = wx_row_item_get_outlook(item);
  g_assert_cmpint(o->state, ==, WX_RAIN_NOW);

  /* "now" far past the data (a stale forecast): no current conditions and no outlook, so no
   * "dry" is claimed for a time the forecast does not cover. */
  g_assert_true(wx_row_item_set_now_s(item, T_NOW + 400 * 3600));
  g_assert_false(wx_row_item_get_current(item, &cur));
  g_assert_null(wx_row_item_get_outlook(item));
  /* "now" outside the valid time range: neither. */
  g_assert_true(wx_row_item_set_now_s(item, 5));
  g_assert_null(wx_row_item_get_outlook(item));
  g_assert_false(wx_row_item_get_current(item, &cur));
  g_assert_true(wx_row_item_set_now_s(item, G_MAXINT64));
  g_assert_null(wx_row_item_get_outlook(item));
  g_assert_true(wx_row_item_set_now_s(item, G_MININT64));
  g_assert_null(wx_row_item_get_outlook(item));

  /* Clearing the forecast clears fetched time and derived values; the item holds its own reference. */
  g_assert_true(wx_row_item_set_now_s(item, T_NOW));
  g_assert_true(wx_row_item_set_forecast(item, NULL, 12345));
  g_assert_cmpint(wx_row_item_get_fetched_s(item), ==, 0);
  g_assert_null(wx_row_item_get_outlook(item));
  g_assert_false(wx_row_item_set_forecast(item, NULL, 99)); /* NULL stays NULL: nothing changed */
}

/* A forecast of @n hours starting at the hour of T_NOW, dry, without the hour index @gap (-1: none)
 * and with an unknown amount in the hour index @nan_hour (-1: none); hours below @wet_to are wet. */
static WxForecast *
coverage_forecast(const WxPlace *place, guint n, int gap, int nan_hour, guint wet_to)
{
  WxBlendHour hours[100];
  guint m = 0;
  gint64 base = T_NOW - T_NOW % 3600;
  g_assert_cmpuint(n, <=, G_N_ELEMENTS(hours));
  for (guint i = 0; i < n; i++) {
    if ((int)i == gap)
      continue;
    gboolean wet = i < wet_to;
    hours[m++] = (WxBlendHour){.t_s = base + (gint64)i * 3600, .temp_c = 25, .feels_c = 27,
                               .precip_mm = (int)i == nan_hour ? NAN : (wet ? 2.0 : 0.0),
                               .precip_mm_max = 0, .precip_prob = wet ? 80 : 5, .cloud_pct = 50,
                               .wind_kmh = 10, .gust_kmh = 15, .humidity_pct = 60,
                               .temp_spread_c = NAN, .n_members = 2,
                               .condition = wet ? WX_COND_RAIN : WX_COND_PARTLY_CLOUDY,
                               .is_day = TRUE};
  }
  GError *err = NULL;
  WxForecast *f = wx_forecast_new(place, T_NOW, hours, m, NULL, 0, NULL, 0, NULL, 0, &err);
  g_assert_no_error(err);
  return f;
}

/* Whether the item holds an outlook for @f at @now_s, and what its row says. */
static gboolean
outlook_shown(const WxPlace *p, const WxForecast *f, gint64 now_s, char **hint)
{
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  GtkWidget *row = g_object_ref_sink(wx_row_new());
  wx_row_bind(WX_ROW(row), item);
  wx_row_item_set_now_s(item, now_s);
  wx_row_item_set_forecast(item, (WxForecast *)f, T_NOW);
  gboolean shown = wx_row_item_get_outlook(item) != NULL;
  *hint = g_strdup(wxt_label_text(row, "wx-row-hint"));
  g_object_unref(row);
  return shown;
}

/* "Dry for 48 h" is only claimed for a forecast that knows the precipitation of the 48 hours after
 * "now" (hour after hour, no gap, no unknown amount); a rain that is expected or possible is
 * reported whatever the coverage. */
static void
test_item_dry_claim_needs_coverage(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autofree char *hint = NULL;
  g_autoptr(WxForecast) f49 = coverage_forecast(p, 49, -1, -1, 0);
  g_autoptr(WxForecast) f48 = coverage_forecast(p, 48, -1, -1, 0);

  /* 49 hours from 18:00 cover [18:30, 19:00 + 48 h): the 48 h after now, exactly at the edge */
  g_assert_true(outlook_shown(p, f49, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "Dry for 48 h");
  g_free(hint);
  g_assert_true(outlook_shown(p, f49, T_NOW + 1800 - 1, &hint)); /* 18:59:59 */
  g_free(hint);
  g_assert_false(outlook_shown(p, f49, T_NOW + 1800 + 1, &hint)); /* 19:00:01: 1 s short */
  g_assert_cmpstr(hint, ==, "No rain data");
  g_free(hint);
  /* 48 hours cover 47.5 h after 18:30 */
  g_assert_false(outlook_shown(p, f48, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "No rain data");
  g_free(hint);

  /* a missing hour, or an unknown amount, inside the horizon: not covered; past it: covered */
  g_autoptr(WxForecast) hole = coverage_forecast(p, 72, 10, -1, 0);
  g_assert_false(outlook_shown(p, hole, T_NOW, &hint));
  g_free(hint);
  g_autoptr(WxForecast) hole_far = coverage_forecast(p, 72, 49, -1, 0);
  g_assert_true(outlook_shown(p, hole_far, T_NOW, &hint));
  g_free(hint);
  g_autoptr(WxForecast) unknown = coverage_forecast(p, 72, -1, 30, 0);
  g_assert_false(outlook_shown(p, unknown, T_NOW, &hint));
  g_free(hint);
  g_autoptr(WxForecast) unknown_now = coverage_forecast(p, 72, -1, 0, 0);
  g_assert_false(outlook_shown(p, unknown_now, T_NOW, &hint));
  g_free(hint);
  g_autoptr(WxForecast) unknown_far = coverage_forecast(p, 72, -1, 49, 0);
  g_assert_true(outlook_shown(p, unknown_far, T_NOW, &hint));
  g_free(hint);
  /* the hour of "now" missing (a gap there): there are no current conditions either */
  g_autoptr(WxForecast) no_now = coverage_forecast(p, 72, 0, -1, 0);
  g_assert_false(outlook_shown(p, no_now, T_NOW, &hint));
  g_free(hint);
  /* ... and a rain later in the data is no claim either while the present moment is not covered */
  g_autoptr(WxForecast) no_now_wet = coverage_forecast(p, 72, 0, -1, 3); /* hours 1 and 2 are wet */
  g_assert_false(outlook_shown(p, no_now_wet, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "No rain data");
  g_free(hint);

  /* rain in a short forecast is still reported: raining now, expected, possible */
  g_autoptr(WxForecast) wet_now = coverage_forecast(p, 4, -1, -1, 2);
  g_assert_true(outlook_shown(p, wet_now, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "Raining until 4:00 PM");
  g_free(hint);
  WxBlendHour soon[4];
  gint64 base = T_NOW - T_NOW % 3600;
  for (guint i = 0; i < 4; i++) {
    soon[i] = (WxBlendHour){.t_s = base + (gint64)i * 3600, .temp_c = 25, .feels_c = 27,
                            .precip_mm = i == 2 ? 2.0 : 0.0, .precip_mm_max = 0,
                            .precip_prob = i == 2 ? 80 : 50, .cloud_pct = 50, .wind_kmh = 10,
                            .gust_kmh = 15, .humidity_pct = 60, .temp_spread_c = NAN,
                            .n_members = 2, .condition = WX_COND_PARTLY_CLOUDY, .is_day = TRUE};
  }
  g_autoptr(WxForecast) expected = wx_forecast_new(p, T_NOW, soon, 4, NULL, 0, NULL, 0, NULL, 0, NULL);
  g_assert_nonnull(expected);
  g_assert_true(outlook_shown(p, expected, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "Rain at 4 PM");
  g_free(hint);
  soon[2].precip_mm = 0;
  soon[2].precip_prob = 50;
  g_autoptr(WxForecast) possible = wx_forecast_new(p, T_NOW, soon, 4, NULL, 0, NULL, 0, NULL, 0, NULL);
  g_assert_nonnull(possible);
  g_assert_true(outlook_shown(p, possible, T_NOW, &hint));
  g_assert_cmpstr(hint, ==, "Showers possible");
  g_free(hint);
  hint = NULL;
}

static void
test_item_changed_handler_may_drop_references(void)
{
  g_autoptr(WxPlace) p = miami();
  WxRowItem *item = wx_row_item_new(p);
  g_signal_connect_swapped(item, "changed", G_CALLBACK(g_object_unref), item);
  /* The handler drops the caller's only reference during the emission: the emission itself holds
   * a reference, so the item survives until the signal returned (a use-after-free otherwise). */
  g_assert_true(wx_row_item_set_loading(item, TRUE));
}

/* ------------------------------------------------------------------ */
/* Application: construction and wiring                               */
/* ------------------------------------------------------------------ */

static void
test_app_new_with_registry_null(void)
{
  ASSERT_CRITICAL("wx_app_new_with_registry", g_assert_null(wx_app_new_with_registry(NULL)));
  ASSERT_CRITICAL("wx_app_new_with_registry",
                  g_assert_null(wx_app_new_with_registry((WxRegistry *)g_object_new(G_TYPE_OBJECT, NULL))));
}

static void
test_app_default_wiring(void)
{
  g_autoptr(WxApp) app = wx_app_new();
  g_assert_nonnull(app);
  g_assert_cmpstr(g_application_get_application_id(G_APPLICATION(app)), ==, WX_APP_ID);
  WxRegistry *reg = wx_app_get_registry(app);
  g_assert_nonnull(reg);
  g_autoptr(GPtrArray) providers = wx_registry_list_providers(reg);
  g_assert_cmpuint(providers->len, ==, 3);
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(providers, 0)), ==, "nws");
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(providers, 1)), ==, "open-meteo");
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(providers, 2)), ==, "met-no");
  for (guint i = 0; i < providers->len; i++)
    g_assert_true(wx_registry_is_enabled(reg, wx_provider_get_id(g_ptr_array_index(providers, i))));
  g_assert_nonnull(wx_registry_get_geocoder(reg));
  g_assert_true(WX_IS_SERVICE(wx_app_get_service(app)));
  g_assert_cmpuint(g_list_model_get_n_items(wx_app_get_items(app)), ==, 0);
  g_assert_false(wx_app_get_offline(app));
  g_assert_cmpint(wx_app_get_units(app), ==, WX_UNITS_IMPERIAL);
  g_assert_null(wx_app_get_selected(app));
  g_assert_true(WX_IS_PLACES(wx_app_get_places(app)));
}

static void
test_app_custom_registry_is_used_as_is(void)
{
  g_autoptr(WxRegistry) reg = wx_registry_new();
  g_autoptr(WxApp) app = wx_app_new_with_registry(reg);
  g_assert_true(wx_app_get_registry(app) == reg);
  g_autoptr(GPtrArray) providers = wx_registry_list_providers(reg);
  g_assert_cmpuint(providers->len, ==, 0); /* nothing was added behind the caller's back */
  g_assert_null(wx_registry_get_geocoder(reg));
}

static void
test_app_null_arguments(void)
{
  g_autoptr(WxApp) app = wx_app_new();
  ASSERT_CRITICAL("wx_app_get_items", g_assert_null(wx_app_get_items(NULL)));
  ASSERT_CRITICAL("wx_app_get_places", g_assert_null(wx_app_get_places(NULL)));
  ASSERT_CRITICAL("wx_app_get_registry", g_assert_null(wx_app_get_registry(NULL)));
  ASSERT_CRITICAL("wx_app_get_service", g_assert_null(wx_app_get_service(NULL)));
  ASSERT_CRITICAL("wx_app_get_offline", g_assert_false(wx_app_get_offline(NULL)));
  ASSERT_CRITICAL("wx_app_get_units", g_assert_cmpint(wx_app_get_units(NULL), ==, WX_UNITS_IMPERIAL));
  ASSERT_CRITICAL("wx_app_set_units", wx_app_set_units(NULL, WX_UNITS_METRIC));
  ASSERT_CRITICAL("wx_app_set_units", wx_app_set_units(app, (WxUnits)5));
  ASSERT_CRITICAL("wx_app_set_window_visible", wx_app_set_window_visible(NULL, TRUE));
  ASSERT_CRITICAL("wx_app_window_focused", wx_app_window_focused(NULL));
  ASSERT_CRITICAL("wx_app_get_selected", g_assert_null(wx_app_get_selected(NULL)));
  ASSERT_CRITICAL("wx_app_select", wx_app_select(NULL, "1.0000,1.0000"));
  ASSERT_CRITICAL("wx_app_refresh_selected", wx_app_refresh_selected(NULL));
  ASSERT_CRITICAL("wx_app_set_provider_enabled", wx_app_set_provider_enabled(NULL, "x", TRUE));
  ASSERT_CRITICAL("wx_app_set_provider_enabled", wx_app_set_provider_enabled(app, NULL, TRUE));
  ASSERT_CRITICAL("wx_window_new", g_assert_null(wx_window_new(NULL)));
}

/* ------------------------------------------------------------------ */
/* First run                                                          */
/* ------------------------------------------------------------------ */

static void
test_first_run_empty_state(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  GtkWidget *stack = wxt_find_named(win, "wx-main-stack");
  g_assert_nonnull(stack);
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(stack)), ==, "empty");
  g_assert_cmpstr(dtext(win, "wx-empty-title"), ==, "No places yet");
  g_assert_cmpstr(dtext(win, "wx-empty-hint"), ==, "Pick a city to see its weather and when it will rain.");
  g_autoptr(GPtrArray) chips = g_ptr_array_new();
  wxt_collect_named(win, "wx-suggestion", chips);
  g_assert_cmpuint(chips->len, ==, 5);
  const char *expected[] = {"Miami", "Orlando", "Tampa", "Jacksonville", "Key West"};
  for (guint i = 0; i < 5; i++) {
    g_assert_true(GTK_IS_BUTTON(g_ptr_array_index(chips, i)));
    g_assert_cmpstr(gtk_button_get_label(g_ptr_array_index(chips, i)), ==, expected[i]);
  }
  GtkWidget *empty_add = wxt_find_named(win, "wx-empty-add");
  g_assert_nonnull(empty_add);
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(empty_add)), ==, "Add a city");
  g_assert_true(gtk_widget_has_css_class(empty_add, "suggested-action"));
  g_assert_cmpuint(fx_n_items(fx), ==, 0);
  g_assert_null(wx_app_get_selected(fx->app));
  g_assert_false(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  /* The header controls exist and are usable without a place. */
  g_assert_true(gtk_widget_get_sensitive(wxt_find_named(win, "wx-add-button")));
  g_assert_true(gtk_widget_get_sensitive(wxt_find_named(win, "wx-units-button")));
  /* Nothing is fetched without a place. */
  wxt_pump_ms(300);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 0);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 0);
  /* The detail pane (hidden behind the empty page) invites a selection. */
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-title"), ==, "Select a place");
  fx_free(fx);
}

static void
test_first_run_suggestion_adds_selects_and_fetches(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  g_autoptr(GPtrArray) chips = g_ptr_array_new();
  wxt_collect_named(win, "wx-suggestion", chips);
  click(g_ptr_array_index(chips, 0)); /* Miami */
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 1);
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-main-stack"))),
                  ==, "main");
  g_autoptr(WxPlace) m = place_new("Miami", 25.7743, -80.1937);
  g_autofree char *key = key_of(m);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, key);
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  WxRowItem *item = fx_item(fx, 0);
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-title"), !=, "");
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 1);
  g_assert_cmpstr(dtext(win, "wx-detail-place"), ==, "Miami, Florida, United States");
  g_assert_true(g_str_has_suffix(dtext(win, "wx-detail-temp"), "\xC2\xB0" "F"));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_true(g_str_has_suffix(wxt_label_text(row_named(win, "Miami"), "wx-row-temp"), "\xC2\xB0"));
  fx_free(fx);
}

static void
test_first_run_search_button_opens_one_picker(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  g_assert_cmpuint(toplevels_of_type(WX_TYPE_PICKER), ==, 0);
  click(wxt_find_named(win, "wx-empty-add"));
  WXT_WAIT_FOR(toplevel_of_type(WX_TYPE_PICKER) != NULL);
  GtkWidget *picker = toplevel_of_type(WX_TYPE_PICKER);
  g_assert_true(gtk_window_get_transient_for(GTK_WINDOW(picker)) == GTK_WINDOW(win));
  g_assert_true(gtk_window_get_destroy_with_parent(GTK_WINDOW(picker)));
  g_assert_false(gtk_window_get_modal(GTK_WINDOW(picker)));
  /* A second request presents the same picker instead of opening another. */
  click(wxt_find_named(win, "wx-empty-add"));
  click(wxt_find_named(win, "wx-add-button"));
  g_action_group_activate_action(G_ACTION_GROUP(win), "add", NULL);
  wxt_pump_idle();
  g_assert_cmpuint(toplevels_of_type(WX_TYPE_PICKER), ==, 1);
  g_assert_true(toplevel_of_type(WX_TYPE_PICKER) == picker);
  fx_free(fx);
  g_assert_cmpuint(toplevels_of_type(WX_TYPE_PICKER), ==, 0); /* destroyed with its parent */
}

/* ------------------------------------------------------------------ */
/* Adding through the picker                                          */
/* ------------------------------------------------------------------ */

static GtkWidget *
open_picker(Fx *fx, GtkWidget *win)
{
  (void)fx;
  g_action_group_activate_action(G_ACTION_GROUP(win), "add", NULL);
  WXT_WAIT_FOR(toplevel_of_type(WX_TYPE_PICKER) != NULL);
  return toplevel_of_type(WX_TYPE_PICKER);
}

static void
search(GtkWidget *picker, const char *text)
{
  gtk_editable_set_text(GTK_EDITABLE(wxt_find_named(picker, "wx-picker-search-entry")), text);
}

static void
test_add_via_picker_selects_new_place(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  g_autoptr(WxPlace) o = orlando();
  wx_fake_geocoder_add_hit(fx->geocoder, o);
  GtkWidget *win = fx_start(fx);
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  GtkWidget *picker = open_picker(fx, win);
  search(picker, "Orlando");
  WXT_WAIT_FOR(wx_fake_geocoder_get_search_count(fx->geocoder) == 1);
  GtkWidget *results = wxt_find_named(picker, "wx-picker-results");
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(picker, "wx-picker-label"), "Orlando, Florida, United States") == 0);
  g_signal_emit_by_name(results, "activate", 0u);
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 2);
  WXT_WAIT_FOR(toplevel_of_type(WX_TYPE_PICKER) == NULL); /* the picker closed itself */
  g_autofree char *key = key_of(o);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, key);
  g_assert_cmpuint(fx_n_items(fx), ==, 2);
  WXT_WAIT_FOR(g_strcmp0(dtext(win, "wx-detail-place"), "Orlando, Florida, United States") == 0);
  /* Both places are fetched: the new one at once, the old one after the visible round. */
  WAIT_FORECAST(fx_item(fx, 1));
  fx_free(fx);
}

static void
test_picker_geocoder_failure_is_inline(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  wx_fake_geocoder_fail_with(fx->geocoder, WX_ERROR_NETWORK);
  GtkWidget *win = fx_start(fx);
  GtkWidget *picker = open_picker(fx, win);
  search(picker, "Miami");
  WXT_WAIT_FOR(wx_fake_geocoder_get_search_count(fx->geocoder) == 1);
  WXT_WAIT_FOR(g_str_has_prefix(wxt_label_text(picker, "wx-picker-status"), "Search failed:"));
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 0);
  g_assert_nonnull(toplevel_of_type(WX_TYPE_PICKER)); /* still open */
  fx_free(fx);
}

static void
test_picker_no_results_and_escape_cancel(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  GtkWidget *picker = open_picker(fx, win);
  search(picker, "Nowhereville");
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(picker, "wx-picker-status"), "No results") == 0);
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 0);
  /* Escape cancels: nothing was added, the picker closes. */
  gtk_window_close(GTK_WINDOW(picker));
  WXT_WAIT_FOR(toplevel_of_type(WX_TYPE_PICKER) == NULL);
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 0);
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-main-stack"))),
                  ==, "empty");
  /* It can be opened again. */
  picker = open_picker(fx, win);
  g_assert_nonnull(picker);
  fx_free(fx);
}

static void
test_picker_add_of_saved_place_is_refused_inline(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  g_autoptr(WxPlace) m = miami();
  wx_fake_geocoder_add_hit(fx->geocoder, m);
  GtkWidget *win = fx_start(fx);
  GtkWidget *picker = open_picker(fx, win);
  search(picker, "Miami");
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(picker, "wx-picker-label"), "Miami, Florida, United States") == 0);
  g_signal_emit_by_name(wxt_find_named(picker, "wx-picker-results"), "activate", 0u);
  g_assert_cmpuint(wx_places_get_n_places(wx_app_get_places(fx->app)), ==, 1);
  g_assert_cmpstr(wxt_label_text(picker, "wx-picker-status"), ==, "Already in your places");
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Refresh states                                                     */
/* ------------------------------------------------------------------ */

static void
test_refresh_loading_then_ok(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE}; /* the gate keeps the request in flight */
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  g_assert_null(wx_row_item_get_forecast(item));
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-title"), ==, "Loading forecast\xE2\x80\xA6");
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-hint"), ==, "Loading\xE2\x80\xA6");
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-temp"), ==, "\xE2\x80\x94");
  g_assert_cmpuint(gate_of(fx)->fetches, ==, 1);
  gate_release(gate_of(fx), -1); /* the answer arrives when the test says so */
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_false(wx_row_item_get_stale(item));
  g_assert_null(wx_row_item_get_error(item));
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-detail-stack"))),
                  ==, "forecast");
  g_assert_cmpstr(FOOTER_UPDATED(win), ==, "Updated just now");
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-marker"), ==, "");
  fx_free(fx);
}

static void
test_refresh_partial_one_source_fails(void)
{
  FxConfig cfg = {RAIN_DRY, -1, WX_ERROR_NETWORK, 0, FALSE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_false(wx_row_item_get_stale(item)); /* the refresh as a whole succeeded */
  g_assert_cmpstr(FOOTER_SOURCES(win), ==, "Sources: Fake fake-a");
  g_assert_cmpstr(dtext(win, "wx-detail-partial"), ==, "Not available right now: Fake fake-b");
  fx_free(fx);
}

static void
test_refresh_failed_without_cache_then_recovers(void)
{
  FxConfig cfg = {RAIN_DRY, WX_ERROR_NETWORK, WX_ERROR_TIMEOUT, 0, FALSE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_error(item) != NULL);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_null(wx_row_item_get_forecast(item));
  g_assert_true(wx_row_item_get_stale(item));
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-title"), ==, "Couldn't load the forecast");
  g_assert_true(g_str_has_suffix(dtext(win, "wx-detail-placeholder-text"),
                                 " Check your internet connection; the app tries again automatically."));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-hint"), ==, "Can't load forecast");
  /* The sources recover; the refresh button fetches again once the minimum gap since the last
   * request has passed (a click before it is dropped, see test_refresh_is_rate_limited). */
  wx_fake_provider_fail_with(fx->a, -1);
  wx_fake_provider_fail_with(fx->b, -1);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_assert_true(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  click(wxt_find_named(win, "wx-refresh-button"));
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_false(wx_row_item_get_stale(item));
  g_assert_null(wx_row_item_get_error(item));
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-detail-stack"))),
                  ==, "forecast");
  fx_free(fx);
}

/* Runs the application once so its cache holds a forecast of @place, ages the cache entry by
 * @age_s and stops. The providers answer normally during that run. */
static void
prime_cache(Fx *fx, gint64 age_s)
{
  fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  fx_stop(fx);
  g_autoptr(WxCache) cache = wx_cache_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_cache_load(cache, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_cache_get_n_places(cache), ==, 1);
  g_autoptr(WxPlace) m = miami();
  g_autofree char *key = key_of(m);
  g_autoptr(WxForecast) f = wx_cache_get(cache, key, NULL);
  g_assert_nonnull(f);
  g_assert_true(wx_cache_put(cache, f, (real_now() - age_s) * 1000));
  g_assert_true(wx_cache_save(cache, &err));
  g_assert_no_error(err);
}

static void
test_cached_forecast_is_shown_at_once(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  prime_cache(fx, 3 * 3600);
  /* Now a refresh stays in flight (the gate): whatever is shown comes from the cache. */
  fx_add_gate(fx, RAIN_DRY);
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  g_assert_nonnull(wx_row_item_get_forecast(item));
  WXT_WAIT_FOR(wx_row_item_get_loading(item)); /* refreshing in the background */
  g_assert_cmpstr(FOOTER_UPDATED(win), ==, "Updated 3 h ago");
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-refreshing")));
  g_assert_true(g_str_has_suffix(dtext(win, "wx-detail-temp"), "\xC2\xB0" "F"));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-marker"), ==, "Updating\xE2\x80\xA6");
  fx_free(fx);
}

static void
test_stale_data_stays_and_is_marked(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  prime_cache(fx, 600);
  wx_fake_provider_fail_with(fx->a, WX_ERROR_NETWORK);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_NETWORK);
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_stale(item));
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_nonnull(wx_row_item_get_forecast(item)); /* the cached forecast stays */
  g_assert_nonnull(wx_row_item_get_error(item));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  GtkWidget *row = row_named(win, "Miami");
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(row, "wx-row-marker"), "Stale") == 0);
  g_assert_true(gtk_widget_has_css_class(row, "dim"));
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-badge-stale")));
  g_assert_false(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-badge-offline")));
  g_assert_cmpstr(FOOTER_UPDATED(win), ==, "Updated 10 min ago");
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-detail-stack"))),
                  ==, "forecast");
  /* Recovery clears the mark (the refresh button once the minimum gap has passed). */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  wx_fake_provider_fail_with(fx->a, -1);
  wx_fake_provider_fail_with(fx->b, -1);
  click(wxt_find_named(win, "wx-refresh-button"));
  WXT_WAIT_FOR(!wx_row_item_get_stale(item));
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(row, "wx-row-marker"), "") == 0);
  g_assert_false(gtk_widget_has_css_class(row, "dim"));
  fx_free(fx);
}

static void
emit_network(gboolean available)
{
  g_signal_emit_by_name(g_network_monitor_get_default(), "network-changed", available);
}

static void
test_offline_marker_cancel_and_resume(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE}; /* the gate keeps the requests in flight */
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  emit_network(FALSE);
  g_assert_true(wx_app_get_offline(fx->app));
  WXT_WAIT_FOR(!wx_row_item_get_loading(item)); /* the hanging request was cancelled */
  g_assert_true(wx_row_item_get_offline(item));
  g_assert_false(wx_row_item_get_stale(item)); /* a cancellation is not a failure */
  g_assert_false(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-title"), ==, "You are offline");
  g_assert_cmpstr(dtext(win, "wx-detail-placeholder-text"), ==, "The forecast loads when the network is back.");
  wxt_pump_ms(300);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1); /* nothing is requested offline */
  /* Back online: the place is fetched again. */
  emit_network(TRUE);
  g_assert_false(wx_app_get_offline(fx->app));
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 2);
  gate_release(gate_of(fx), -1);
  WAIT_FORECAST(item);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 2);
  g_assert_false(wx_row_item_get_offline(item));
  g_assert_true(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  /* Offline with data: the forecast stays, marked. */
  emit_network(FALSE);
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  GtkWidget *row = row_named(win, "Miami");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "Offline");
  g_assert_true(gtk_widget_has_css_class(row, "dim"));
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-badge-offline")));
  g_assert_false(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-badge-stale")));
  emit_network(TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "");
  fx_free(fx);
}

static void
test_hidden_window_requests_nothing(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  gtk_widget_set_visible(win, FALSE);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(win));
  WXT_WAIT_FOR(!wx_row_item_get_loading(item)); /* hidden: the request was cancelled */
  wxt_settle_display();
  guint before = wx_fake_provider_get_fetch_count(fx->a);
  wxt_pump_ms(400);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, before);
  g_assert_false(wx_row_item_get_stale(item));
  /* Showing it again starts the round again. */
  gtk_window_present(GTK_WINDOW(win));
  WXT_WAIT_FOR(gtk_widget_get_mapped(win));
  wxt_settle_display();
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, before + 1);
  fx_free(fx);
}

static void
test_refresh_button_forces_a_new_request(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  /* While the place loads the action is off and the API drops the call, even long after the
   * minimum gap: the request in flight is about to make the place fresh. */
  g_assert_false(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  wx_app_refresh_selected(fx->app);
  wxt_pump_idle();
  g_assert_cmpuint(gate_of(fx)->fetches, ==, 1);
  g_assert_false(gate_cancelled(fx)); /* not replaced either */
  gate_release(gate_of(fx), -1);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  WXT_WAIT_FOR(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  /* The place is fresh (less than 120 s old): no round would fetch it, the button does, once the
   * minimum gap since the last success has passed. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  click(wxt_find_named(win, "wx-refresh-button"));
  WXT_WAIT_FOR(gate_of(fx)->fetches == 2);
  g_assert_true(wx_row_item_get_loading(item));
  g_assert_false(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  /* Pressed again while the request is in flight: never doubled, never replaced. */
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  wx_app_refresh_selected(fx->app);
  wxt_pump_idle();
  g_assert_cmpuint(gate_of(fx)->fetches, ==, 2);
  g_assert_false(gate_cancelled(fx));
  gate_release(gate_of(fx), -1);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  WXT_WAIT_FOR(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  g_assert_cmpuint(gate_of(fx)->fetches, ==, 2);
  g_assert_nonnull(wx_row_item_get_forecast(item));
  fx_free(fx);
}

/* A burst of activations (the button, F5 / Ctrl+R, the API) starts at most one request per place
 * and period: N rapid activations are O(1) fetches. */
static void
test_refresh_is_rate_limited(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  /* Right after the request: every activation is dropped. */
  for (int i = 0; i < 300; i++) {
    g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
    wx_app_refresh_selected(fx->app);
    if (i % 10 == 0)
      wxt_pump_idle();
  }
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 1);
  /* Once the gap has passed one activation of a burst is served; the gap restarts at its request
   * (and at its success), so the rest is dropped. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  for (int i = 0; i < 300; i++) {
    g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
    wx_app_refresh_selected(fx->app);
    if (i % 10 == 0)
      wxt_pump_idle();
  }
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 2);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 2);
  fx_free(fx);
}

/* A place whose last refresh was rate limited is not asked again before the cool-down, however
 * often the user presses Refresh; a failure of another kind is only held back for the gap. When
 * the cool-down ends the scheduler asks the place once by itself. */
static void
test_rate_limited_place_waits_for_the_cool_down(void)
{
  G_STATIC_ASSERT(WX_APP_RATE_LIMIT_COOLDOWN_S > WX_APP_REFRESH_MIN_GAP_S);
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300); /* the focus events of the start-up have been handled */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  /* The sources now answer "rate limited": the next refresh fails with that error. */
  wx_fake_provider_fail_with(fx->a, WX_ERROR_RATE_LIMITED);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_RATE_LIMITED);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 2);
  WXT_WAIT_FOR(wx_row_item_get_stale(item));
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  /* The gap has passed, the cool-down has not. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_assert_true(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  for (int i = 0; i < 20; i++)
    g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 2);
  /* The cool-down is over: the place is given back to the scheduler, which asks it once. */
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S - WX_APP_REFRESH_MIN_GAP_S);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 3);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_true(wx_row_item_get_stale(item));
  /* A failure of another kind only waits for the gap (the one above started a new cool-down:
   * the place is asked again when that ends). */
  wx_fake_provider_fail_with(fx->a, WX_ERROR_NETWORK);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_NETWORK);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S + 1);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 4);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 5);
  fx_free(fx);
}

/* A source's LOCAL refusal (MET Norway's 10-minute floor: a RATE_LIMITED that cost no request)
 * next to the real failure of the other sources is not a rate limit of a server: the item shows
 * the real failure and the place is not put into the cool-down, so a Refresh after the gap is
 * served. A rate limit a server announced (HTTP 429) does start the cool-down. */
static void
test_local_refusal_starts_no_cool_down(void)
{
  FxConfig cfg = {RAIN_DRY, WX_ERROR_HTTP, WX_ERROR_HTTP, 0, TRUE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(gate_of(fx)->pending->len == 1);
  gate_release_with(gate_of(fx), WX_ERROR_RATE_LIMITED,
                    "a request for this place was sent less than 10 minutes ago");
  WXT_WAIT_FOR(wx_row_item_get_stale(item) && !wx_row_item_get_loading(item));
  g_assert_cmpstr(wx_row_item_get_error(item), ==, "fake-a: scripted failure");
  wxt_pump_ms(300); /* the focus events of the start-up have been handled */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);

  /* No cool-down: the gap is all that holds Refresh back. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  click(wxt_find_named(win, "wx-refresh-button"));
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 2);
  WXT_WAIT_FOR(gate_of(fx)->pending->len == 1);

  /* The same request answered by a server's rate limit: now the place cools down. */
  gate_release_with(gate_of(fx), WX_ERROR_RATE_LIMITED, "HTTP 429: rate limited");
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_cmpstr(wx_row_item_get_error(item), ==, "gate: HTTP 429: rate limited");
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  for (int i = 0; i < 5; i++)
    g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 2);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S - WX_APP_REFRESH_MIN_GAP_S);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 3);
  fx_free(fx);
}

/* Number of requests that reached the two fake providers together. */
static guint
fetches_of(Fx *fx)
{
  return wx_fake_provider_get_fetch_count(fx->a) + wx_fake_provider_get_fetch_count(fx->b);
}

/* A place inside its RATE_LIMITED cool-down is not asked again by ANYTHING the application does:
 * not by the scheduler's rounds that the window focus, showing the window and the network coming
 * back start, not by Refresh or a provider switch. When the cool-down ends it is asked exactly
 * once. */
static void
test_rate_limited_place_is_out_of_the_scheduler(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300); /* the focus events of the start-up have been handled */
  g_assert_cmpuint(fetches_of(fx), ==, 2);
  wx_fake_provider_fail_with(fx->a, WX_ERROR_RATE_LIMITED);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_RATE_LIMITED);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(fetches_of(fx) == 4);
  WXT_WAIT_FOR(wx_row_item_get_stale(item) && !wx_row_item_get_loading(item));

  /* Inside the cool-down: 20 focus events, 10 hide/show flaps, a network flap, a provider switch
   * and a few more focus events after a clock step that stays inside the cool-down. */
  for (int i = 0; i < 20; i++) {
    wx_app_window_focused(fx->app);
    wxt_pump_idle();
  }
  for (int i = 0; i < 10; i++) {
    wx_app_set_window_visible(fx->app, FALSE);
    wx_app_set_window_visible(fx->app, TRUE);
    wxt_pump_idle();
  }
  emit_network(FALSE);
  emit_network(TRUE);
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  wx_app_set_provider_enabled(fx->app, "fake-b", TRUE);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S / 2);
  for (int i = 0; i < 5; i++) {
    wx_app_window_focused(fx->app);
    wxt_pump_idle();
  }
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, 4);
  g_assert_false(wx_row_item_get_loading(item));
  g_assert_true(wx_row_item_get_stale(item));

  /* The cool-down ends: the place is asked once (by both sources), and no more. */
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S / 2 + 2);
  WXT_WAIT_FOR(fetches_of(fx) == 6);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, 6);
  /* It failed with the rate limit again: a new cool-down, and the same holds. */
  for (int i = 0; i < 5; i++)
    wx_app_window_focused(fx->app);
  wxt_pump_ms(100);
  g_assert_cmpuint(fetches_of(fx), ==, 6);
  fx_free(fx);
}

/* A cool-down that ends while the window is hidden (or the network is gone) arms no timer; the
 * place is asked, once, when the application is active again. */
static void
test_rate_limit_cool_down_ending_while_hidden(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  wx_fake_provider_fail_with(fx->a, WX_ERROR_RATE_LIMITED);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_RATE_LIMITED);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(fetches_of(fx) == 4);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  guint before = fetches_of(fx);

  wx_app_set_window_visible(fx->app, FALSE);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S + 1);
  wxt_pump_ms(300);
  g_assert_null(g_main_context_find_source_by_user_data(NULL, fx->app)); /* no timer while hidden */
  g_assert_cmpuint(fetches_of(fx), ==, before);
  wx_app_set_window_visible(fx->app, TRUE);
  WXT_WAIT_FOR(fetches_of(fx) == before + 2);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, before + 2);

  /* The same with the network: the second cool-down ends while offline. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  emit_network(FALSE);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S + 1);
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, before + 2);
  emit_network(TRUE);
  WXT_WAIT_FOR(fetches_of(fx) == before + 4);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, before + 4);
  fx_free(fx);
}

/* Nothing but time passes: the end of the cool-down alone makes the application ask the place
 * (its timer), once, with the window visible and the network available. */
static void
test_rate_limit_cool_down_end_is_timed(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  wx_fake_provider_fail_with(fx->a, WX_ERROR_RATE_LIMITED);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_RATE_LIMITED);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(fetches_of(fx) == 4);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, 4);
  warp_clocks(WX_APP_RATE_LIMIT_COOLDOWN_S + 1);
  WXT_WAIT_FOR(fetches_of(fx) == 6);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(300);
  g_assert_cmpuint(fetches_of(fx), ==, 6);
  fx_free(fx);
}

/* Every flip of a provider switch asks every place again, but only once per place and period,
 * whatever the number of flips; the place is asked as soon as it is allowed. */
static void
test_provider_switch_flips_are_coalesced(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  fx_start(fx);
  for (guint i = 0; i < 3; i++) {
    WAIT_FORECAST(fx_item(fx, i));
    WXT_WAIT_FOR(!wx_row_item_get_loading(fx_item(fx, i)));
  }
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 3);
  for (int i = 0; i < 40; i++) {
    wx_app_set_provider_enabled(fx->app, "fake-b", i % 2 == 1); /* off, on, off, ... on */
    if (i % 5 == 0)
      wxt_pump_idle();
  }
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-b"));
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 3); /* nothing yet: too soon */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 6); /* each place, once */
  for (guint i = 0; i < 3; i++)
    WXT_WAIT_FOR(!wx_row_item_get_loading(fx_item(fx, i)));
  wxt_pump_ms(200);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 6);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 6); /* enabled again at the end */
  /* The gap restarts at those requests: a later switch waits again. */
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 6);
  fx_free(fx);
}

/* A switch made while the network is down is not forgotten: when it is back, each place is asked
 * once. */
static void
test_provider_switch_while_offline_is_applied_later(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  emit_network(FALSE);
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  wx_app_set_provider_enabled(fx->app, "fake-b", TRUE);
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1); /* offline: nothing */
  emit_network(TRUE);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 2);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 2);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, 1); /* it is off now */
  fx_free(fx);
}

/* The state of the stale place: a cached forecast of 10 minutes ago, a failed refresh and a forced
 * refresh in flight (every provider answers NETWORK; the gate holds the refresh). */
typedef struct {
  Fx *fx;
  GtkWidget *win;
  WxRowItem *item;
  GtkWidget *row;
} StaleFx;

static void
stale_fx_assert_marked(StaleFx *s)
{
  g_assert_true(wx_row_item_get_stale(s->item));
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(s->row, "wx-row-marker"), "Stale") == 0 ||
               g_strcmp0(wxt_label_text(s->row, "wx-row-marker"), "Offline") == 0);
  g_assert_true(gtk_widget_has_css_class(s->row, "dim"));
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(s->win, "wx-detail-badge-stale")) ||
                gtk_widget_get_mapped(wxt_find_named(s->win, "wx-detail-badge-offline")));
}

/* Builds the state above: the first (startup) refresh fails, the Refresh button starts a second
 * one that is still in flight when this returns. */
static void
stale_fx_new(StaleFx *s)
{
  FxConfig cfg = FX_DEFAULT;
  s->fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  prime_cache(s->fx, 600);
  wx_fake_provider_fail_with(s->fx->a, WX_ERROR_NETWORK);
  wx_fake_provider_fail_with(s->fx->b, WX_ERROR_NETWORK);
  fx_add_gate(s->fx, RAIN_DRY);
  s->win = fx_start(s->fx);
  s->item = fx_item(s->fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(s->item));
  gate_release(gate_of(s->fx), WX_ERROR_NETWORK);
  WXT_WAIT_FOR(wx_row_item_get_stale(s->item));
  WXT_WAIT_FOR(!wx_row_item_get_loading(s->item));
  g_assert_nonnull(wx_row_item_get_forecast(s->item)); /* the cached forecast stays */
  WXT_WAIT_FOR(row_named(s->win, "Miami") != NULL);
  s->row = row_named(s->win, "Miami");
  stale_fx_assert_marked(s);
  g_assert_cmpuint(gate_of(s->fx)->fetches, ==, 1);
  /* The user presses Refresh (after the minimum gap): the stale mark stays while it loads. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  click(wxt_find_named(s->win, "wx-refresh-button"));
  WXT_WAIT_FOR(gate_of(s->fx)->fetches == 2);
  g_assert_true(wx_row_item_get_loading(s->item));
  stale_fx_assert_marked(s);
  g_assert_cmpstr(wxt_label_text(s->row, "wx-row-marker"), ==, "Stale");
}

/* A forced refresh never erases the failure of a place: a refresh that is cancelled by hiding the
 * window leaves the place marked, and only an OK completion of that place clears the mark. */
static void
test_forced_refresh_cancelled_by_hide_keeps_the_stale_mark(void)
{
  StaleFx s;
  stale_fx_new(&s);
  gtk_widget_set_visible(s.win, FALSE);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(s.win));
  WXT_WAIT_FOR(!wx_row_item_get_loading(s.item));
  wxt_settle_display(); /* the state change of the hide is all in: no late one meets the next step */
  g_assert_true(gate_cancelled(s.fx));
  g_assert_true(wx_row_item_get_stale(s.item));
  /* Visible again: the place is fetched again (a refresh in flight), still marked. */
  gtk_window_present(GTK_WINDOW(s.win));
  WXT_WAIT_FOR(gtk_widget_get_mapped(s.win));
  wxt_settle_display();
  WXT_WAIT_FOR(gate_of(s.fx)->fetches == 3);
  g_assert_true(wx_row_item_get_loading(s.item));
  WXT_WAIT_FOR(row_named(s.win, "Miami") != NULL);
  s.row = row_named(s.win, "Miami");
  stale_fx_assert_marked(&s);
  g_assert_cmpstr(wxt_label_text(s.row, "wx-row-marker"), ==, "Stale");
  /* A failure keeps it, a success clears it. */
  gate_release(gate_of(s.fx), WX_ERROR_NETWORK);
  WXT_WAIT_FOR(!wx_row_item_get_loading(s.item));
  g_assert_true(wx_row_item_get_stale(s.item));
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  click(wxt_find_named(s.win, "wx-refresh-button"));
  WXT_WAIT_FOR(gate_of(s.fx)->fetches == 4);
  gate_release(gate_of(s.fx), -1);
  WXT_WAIT_FOR(!wx_row_item_get_stale(s.item));
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(s.row, "wx-row-marker"), "") == 0);
  g_assert_false(gtk_widget_has_css_class(s.row, "dim"));
  fx_free(s.fx);
}

static void
test_forced_refresh_cancelled_by_offline_keeps_the_stale_mark(void)
{
  StaleFx s;
  stale_fx_new(&s);
  emit_network(FALSE);
  WXT_WAIT_FOR(!wx_row_item_get_loading(s.item));
  g_assert_true(gate_cancelled(s.fx));
  g_assert_true(wx_row_item_get_stale(s.item));
  stale_fx_assert_marked(&s); /* "Offline" and dim while the network is down */
  g_assert_false(gtk_widget_get_mapped(wxt_find_named(s.win, "wx-detail-badge-stale")));
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(s.win, "wx-detail-badge-offline")));
  /* Back online: the stale mark shows again (and the place is fetched again). */
  emit_network(TRUE);
  WXT_WAIT_FOR(gate_of(s.fx)->fetches == 3);
  g_assert_true(wx_row_item_get_stale(s.item));
  WXT_WAIT_FOR(g_strcmp0(wxt_label_text(s.row, "wx-row-marker"), "Stale") == 0);
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(s.win, "wx-detail-badge-stale")));
  fx_free(s.fx);
}

/* A switch of a provider while a forced refresh is in flight neither cancels it nor erases the
 * mark; the place is asked again afterwards. */
static void
test_provider_switch_during_forced_refresh_keeps_the_stale_mark(void)
{
  StaleFx s;
  stale_fx_new(&s);
  wx_app_set_provider_enabled(s.fx->app, "fake-b", FALSE);
  wxt_pump_idle();
  g_assert_false(gate_cancelled(s.fx));
  g_assert_cmpuint(gate_of(s.fx)->fetches, ==, 2);
  g_assert_true(wx_row_item_get_stale(s.item));
  gate_release(gate_of(s.fx), WX_ERROR_NETWORK); /* the refresh in flight fails */
  WXT_WAIT_FOR(!wx_row_item_get_loading(s.item));
  g_assert_true(wx_row_item_get_stale(s.item));
  /* The pending switch asks the place again as soon as it is allowed; still marked while it loads. */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  WXT_WAIT_FOR(gate_of(s.fx)->fetches == 3);
  g_assert_true(wx_row_item_get_loading(s.item));
  stale_fx_assert_marked(&s);
  gate_release(gate_of(s.fx), -1);
  WXT_WAIT_FOR(!wx_row_item_get_stale(s.item));
  fx_free(s.fx);
}

/* ------------------------------------------------------------------ */
/* Rain texts                                                         */
/* ------------------------------------------------------------------ */

static void
rain_case(RainKind kind, const char *headline_prefix, const char *hint_prefix, gboolean has_detail)
{
  FxConfig cfg = {kind, -1, -1, 0, FALSE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wx_row_item_set_now_s(item, real_now());
  const WxRainOutlook *o = wx_row_item_get_outlook(item);
  g_assert_nonnull(o);
  /* The headline and the hint are exactly the pure texts of the item's outlook. */
  gint64 now = wx_row_item_get_now_s(item);
  g_autofree char *headline = wx_rain_headline(o, now, NY);
  g_autofree char *hint = wx_row_rain_hint(o, now, NY);
  g_assert_cmpstr(dtext(win, "wx-detail-rain-headline"), ==, headline);
  g_assert_true(g_str_has_prefix(headline, headline_prefix));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-hint"), ==, hint);
  g_assert_true(g_str_has_prefix(hint, hint_prefix));
  g_autofree char *detail = wx_rain_detail(o, now, NY);
  g_assert_cmpstr(dtext(win, "wx-detail-rain-detail"), ==, detail);
  g_assert_cmpint(detail[0] != '\0', ==, has_detail);
  g_assert_true(gtk_widget_get_mapped(wxt_find_named(win, "wx-detail-rain-chart")));
  g_assert_true(g_str_has_prefix(dtext(win, "wx-detail-cloud-cover"), "Cloud cover 40%"));
  g_assert_cmpstr(dtext(win, "wx-detail-cloud-title"), ==, "Clouds");
  g_assert_cmpstr(dtext(win, "wx-detail-rain-title"), ==, "Rain");
  g_assert_cmpstr(dtext(win, "wx-detail-hours-title"), ==, "Next 48 hours");
  g_assert_cmpstr(dtext(win, "wx-detail-days-title"), ==, "Next days");
  fx_free(fx);
}

static void
test_rain_dry(void)
{
  rain_case(RAIN_DRY, "No rain expected for the next 48 hours", "Dry for 48 h", FALSE);
}

static void
test_rain_now(void)
{
  rain_case(RAIN_NOW, "Raining now", "Raining", TRUE);
}

static void
test_rain_soon(void)
{
  rain_case(RAIN_SOON, "Rain starting", "Rain in", TRUE);
}

static void
test_rain_later(void)
{
  rain_case(RAIN_LATER, "Rain expected", "Rain ", TRUE);
}

static void
test_rows_follow_the_item_clock(void)
{
  FxConfig cfg = FX_DEFAULT;
  cfg.rain = RAIN_LATER;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  GtkWidget *row = row_named(win, "Miami");
  gint64 now = real_now();
  wx_row_item_set_now_s(item, now);
  g_autofree char *before = g_strdup(wxt_label_text(row, "wx-row-hint"));
  /* The application's clock tick gives every item the time: four hours on, the rain (which began 4
   * to 5 hours after the start of the current hour) is under way. */
  wx_row_item_set_now_s(item, wx_row_item_get_fetched_s(item) + 4 * 3600);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), !=, before);
  g_assert_true(g_str_has_prefix(wxt_label_text(row, "wx-row-hint"), "Raining"));
  g_assert_true(g_str_has_prefix(dtext(win, "wx-detail-rain-headline"), "Raining now"));
  g_assert_cmpstr(FOOTER_UPDATED(win), ==, "Updated 4 h ago");
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Units                                                              */
/* ------------------------------------------------------------------ */

static const char *
tooltip_of(GtkWidget *w)
{
  return gtk_widget_get_tooltip_text(w);
}

static void
test_units_toggle_and_persistence(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  GtkWidget *button = wxt_find_named(win, "wx-units-button");
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(button)), ==, "\xC2\xB0" "F");
  g_assert_cmpstr(tooltip_of(button), ==, "Switch to Celsius");
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  g_assert_true(g_str_has_suffix(dtext(win, "wx-detail-temp"), "\xC2\xB0" "F"));
  g_assert_true(g_str_has_prefix(dtext(win, "wx-detail-wind"), "Wind 7 mph"));

  click(button);
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_METRIC);
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(button)), ==, "\xC2\xB0" "C");
  g_assert_cmpstr(tooltip_of(button), ==, "Switch to Fahrenheit");
  g_assert_cmpstr(dtext(win, "wx-detail-temp"), ==, "24\xC2\xB0" "C");
  g_assert_true(g_str_has_prefix(dtext(win, "wx-detail-wind"), "Wind 12 km/h"));
  g_assert_cmpstr(wxt_label_text(row_named(win, "Miami"), "wx-row-temp"), ==, "24\xC2\xB0");
  g_assert_cmpint(wx_row_item_get_units(item), ==, WX_UNITS_METRIC);

  /* The choice survives a restart (saved at shutdown at the latest). */
  win = fx_restart(fx);
  button = wxt_find_named(win, "wx-units-button");
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_METRIC);
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(button)), ==, "\xC2\xB0" "C");
  WxRowItem *again = fx_item(fx, 0);
  g_assert_cmpint(wx_row_item_get_units(again), ==, WX_UNITS_METRIC);
  /* And back, through the action (Ctrl+U). */
  g_action_group_activate_action(G_ACTION_GROUP(win), "toggle-units", NULL);
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_IMPERIAL);
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(button)), ==, "\xC2\xB0" "F");
  fx_stop(fx);
  g_autoptr(WxSettings) s = wx_settings_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_settings_load(s, &err));
  g_assert_no_error(err);
  g_assert_cmpint(wx_settings_get_units(s), ==, WX_UNITS_IMPERIAL);
  fx_free(fx);
}

static void
test_units_from_settings_at_start(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  store_settings(WX_UNITS_METRIC, NULL, NULL);
  GtkWidget *win = fx_start(fx);
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_METRIC);
  g_assert_cmpstr(gtk_button_get_label(GTK_BUTTON(wxt_find_named(win, "wx-units-button"))), ==,
                  "\xC2\xB0" "C");
  g_assert_cmpint(wx_row_item_get_units(fx_item(fx, 0)), ==, WX_UNITS_METRIC);
  /* Setting the current unit again changes nothing. */
  wx_app_set_units(fx->app, WX_UNITS_METRIC);
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_METRIC);
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Selection, removal, order                                          */
/* ------------------------------------------------------------------ */

static WxPlaces *
places_of(Fx *fx)
{
  return wx_app_get_places(fx->app);
}

static void
test_selection_defaults_and_persists(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  g_autoptr(WxPlace) t = tampa();
  g_autofree char *tkey = key_of(t);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  GtkWidget *win = fx_start(fx);
  g_autoptr(WxPlace) m = miami();
  g_autofree char *mkey = key_of(m);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, mkey); /* the first row */
  WXT_WAIT_FOR(g_strcmp0(dtext(win, "wx-detail-place"), "Miami, Florida, United States") == 0);
  /* Selecting another row is stored and restored. */
  WXT_WAIT_FOR(row_named(win, "Tampa") != NULL);
  GtkWidget *list = wxt_find_named(win, "wx-place-list");
  g_assert_true(gtk_widget_activate_action(list, "list.select-item", "(ubb)", 2u, FALSE, FALSE));
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, tkey);
  WXT_WAIT_FOR(g_strcmp0(dtext(win, "wx-detail-place"), "Tampa, Florida, United States") == 0);
  win = fx_restart(fx);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, tkey);
  WXT_WAIT_FOR(g_strcmp0(dtext(win, "wx-detail-place"), "Tampa, Florida, United States") == 0);
  fx_free(fx);
}

static void
test_selection_of_a_vanished_place_is_ignored(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  store_settings(WX_UNITS_IMPERIAL, NULL, "10.0000,10.0000"); /* a valid key of no saved place */
  fx_start(fx);
  g_autoptr(WxPlace) m = miami();
  g_autofree char *mkey = key_of(m);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, mkey);
  /* wx_app_select() with an unknown or invalid key selects nothing. */
  wx_app_select(fx->app, "99.0000,99.0000");
  g_assert_null(wx_app_get_selected(fx->app));
  wx_app_select(fx->app, "not a key");
  g_assert_null(wx_app_get_selected(fx->app));
  wx_app_select(fx->app, NULL);
  g_assert_null(wx_app_get_selected(fx->app));
  fx_free(fx);
}

static void
test_remove_place_selects_a_neighbour(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  GtkWidget *win = fx_start(fx);
  WXT_WAIT_FOR(row_named(win, "Orlando") != NULL);
  g_autoptr(WxPlace) o = orlando();
  g_autofree char *okey = key_of(o);
  g_assert_true(gtk_widget_activate_action(wxt_find_named(win, "wx-place-list"), "list.select-item",
                                           "(ubb)", 1u, FALSE, FALSE));
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, okey);
  WxRowItem *orlando_item = fx_item(fx, 1);
  WAIT_FORECAST(orlando_item);
  /* Remove it through the row's menu action. */
  g_assert_true(gtk_widget_activate_action(row_named(win, "Orlando"), "row.remove", NULL));
  g_assert_cmpuint(wx_places_get_n_places(places_of(fx)), ==, 2);
  g_assert_cmpint(wx_places_index_of(places_of(fx), okey), ==, -1);
  g_assert_cmpuint(fx_n_items(fx), ==, 2);
  g_assert_nonnull(wx_app_get_selected(fx->app));
  g_assert_cmpstr(wx_app_get_selected(fx->app), !=, okey);
  WXT_WAIT_FOR(g_strcmp0(dtext(win, "wx-detail-place"), "Orlando, Florida, United States") != 0);
  /* Removing the others leaves the empty state. */
  g_assert_true(gtk_widget_activate_action(row_named(win, "Miami"), "row.remove", NULL));
  WXT_WAIT_FOR(row_named(win, "Tampa") != NULL);
  g_assert_true(gtk_widget_activate_action(row_named(win, "Tampa"), "row.remove", NULL));
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-main-stack"))),
                  ==, "empty");
  g_assert_null(wx_app_get_selected(fx->app));
  g_assert_false(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  /* The files follow at shutdown: no place, no selection, no cached forecast left. */
  fx_stop(fx);
  g_autoptr(WxPlaces) list = wx_places_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_places_load(list, NULL, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_places_get_n_places(list), ==, 0);
  g_autoptr(WxCache) cache = wx_cache_new(NULL);
  g_assert_true(wx_cache_load(cache, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_cache_get_n_places(cache), ==, 0);
  g_autoptr(WxSettings) s = wx_settings_new(NULL);
  g_assert_true(wx_settings_load(s, &err));
  g_assert_no_error(err);
  g_assert_null(wx_settings_get_selected(s));
  fx_free(fx);
}

static char *
order_of(Fx *fx)
{
  GString *s = g_string_new("");
  for (guint i = 0, n = wx_places_get_n_places(places_of(fx)); i < n; i++)
    g_string_append_printf(s, "%s%s", i > 0 ? "," : "", wx_places_get_place(places_of(fx), i)->name);
  return g_string_free(s, FALSE);
}

static char *
model_order_of(Fx *fx)
{
  GString *s = g_string_new("");
  for (guint i = 0, n = fx_n_items(fx); i < n; i++)
    g_string_append_printf(s, "%s%s", i > 0 ? "," : "", wx_row_item_get_place(fx_item(fx, i))->name);
  return g_string_free(s, FALSE);
}

static void
test_move_up_and_down(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  GtkWidget *win = fx_start(fx);
  WXT_WAIT_FOR(row_named(win, "Tampa") != NULL);
  g_assert_true(gtk_widget_activate_action(row_named(win, "Tampa"), "row.move-up", NULL));
  g_autofree char *a = order_of(fx);
  g_assert_cmpstr(a, ==, "Miami,Tampa,Orlando");
  g_autofree char *am = model_order_of(fx);
  g_assert_cmpstr(am, ==, "Miami,Tampa,Orlando");
  g_assert_true(gtk_widget_activate_action(row_named(win, "Miami"), "row.move-down", NULL));
  g_autofree char *b = order_of(fx);
  g_assert_cmpstr(b, ==, "Tampa,Miami,Orlando");
  /* Moving past either end does nothing. */
  g_assert_true(gtk_widget_activate_action(row_named(win, "Tampa"), "row.move-up", NULL));
  g_assert_true(gtk_widget_activate_action(row_named(win, "Orlando"), "row.move-down", NULL));
  g_autofree char *c = order_of(fx);
  g_assert_cmpstr(c, ==, "Tampa,Miami,Orlando");
  /* The order is stored (at shutdown at the latest) and restored. */
  win = fx_restart(fx);
  g_autofree char *d = model_order_of(fx);
  g_assert_cmpstr(d, ==, "Tampa,Miami,Orlando");
  fx_free(fx);
}

static void
test_reorder_by_drop_and_hostile_payloads(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  GtkWidget *win = fx_start(fx);
  WXT_WAIT_FOR(row_named(win, "Tampa") != NULL);
  g_autoptr(WxPlace) m = miami();
  g_autoptr(WxPlace) t = tampa();
  g_autofree char *mkey = key_of(m);
  g_autofree char *tkey = key_of(t);
  GtkWidget *tampa_row = row_named(win, "Tampa");
  GtkWidget *miami_row = row_named(win, "Miami");
  /* Hostile payloads (they may come from another application) change nothing and log nothing. */
  g_autofree char *huge = g_strnfill(10000, '9');
  const char *bad[] = {"", "x", "../../etc/passwd", "%s%s%s", "99.0000,99.0000", huge,
                       "25.7743,-80.1937 ", "\xFF\xFE"};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++)
    g_signal_emit_by_name(tampa_row, "reorder-requested", bad[i], tkey);
  g_autofree char *a = order_of(fx);
  g_assert_cmpstr(a, ==, "Miami,Orlando,Tampa");
  /* A drop of a valid key moves that place to the target's position. */
  g_signal_emit_by_name(tampa_row, "reorder-requested", mkey, tkey);
  g_autofree char *b = order_of(fx);
  g_assert_cmpstr(b, ==, "Orlando,Tampa,Miami");
  g_signal_emit_by_name(miami_row, "reorder-requested", tkey, mkey);
  g_autofree char *c = order_of(fx);
  g_assert_cmpstr(c, ==, "Orlando,Miami,Tampa");
  /* A row's own key as source is a no-op. */
  g_signal_emit_by_name(miami_row, "reorder-requested", mkey, mkey);
  g_autofree char *d = order_of(fx);
  g_assert_cmpstr(d, ==, "Orlando,Miami,Tampa");
  /* The drag payload of a row is its key; an unbound row emits nothing. */
  fx_free(fx);
}

static void
test_unbound_row_emits_nothing(void)
{
  GtkWidget *row = g_object_ref_sink(wx_row_new());
  guint emitted = 0;
  g_signal_connect_swapped(row, "remove-requested", G_CALLBACK(g_atomic_int_inc), &emitted);
  g_signal_connect_swapped(row, "move-requested", G_CALLBACK(g_atomic_int_inc), &emitted);
  g_assert_true(gtk_widget_activate_action(row, "row.remove", NULL));
  g_assert_true(gtk_widget_activate_action(row, "row.move-up", NULL));
  g_assert_true(gtk_widget_activate_action(row, "row.move-down", NULL));
  g_signal_emit_by_name(row, "reorder-requested", "x", "y"); /* only the signal itself */
  g_assert_cmpuint(emitted, ==, 0);
  ASSERT_CRITICAL("wx_row_bind", wx_row_bind(NULL, NULL));
  ASSERT_CRITICAL("wx_row_bind", wx_row_bind(WX_ROW(row), (WxRowItem *)row));
  g_object_unref(row);
}

static void
test_row_binding_follows_item(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  GtkWidget *row = g_object_ref_sink(wx_row_new());
  wx_row_bind(WX_ROW(row), item);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-name"), ==, "Miami");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-region"), ==, "Florida, United States");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "No data yet");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-temp"), ==, "\xE2\x80\x94");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "");
  g_assert_true(gtk_widget_has_css_class(row, "empty"));
  g_assert_false(gtk_widget_has_css_class(row, "dim"));
  wx_row_item_set_loading(item, TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "Loading\xE2\x80\xA6");
  wx_row_item_set_loading(item, FALSE);
  wx_row_item_set_error(item, "boom");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "Can't load forecast");
  wx_row_item_set_error(item, NULL);
  wx_row_item_set_offline(item, TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "Offline");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, ""); /* no data: no marker */
  wx_row_item_set_offline(item, FALSE);
  /* With a forecast. */
  g_autoptr(WxForecast) f = make_forecast(p, TRUE);
  wx_row_item_set_now_s(item, T_NOW);
  wx_row_item_set_forecast(item, f, T_NOW);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-temp"), ==, "77\xC2\xB0");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "Raining until 5:00 PM");
  g_assert_false(gtk_widget_has_css_class(row, "empty"));
  wx_row_item_set_units(item, WX_UNITS_METRIC);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-temp"), ==, "25\xC2\xB0");
  wx_row_item_set_stale(item, TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "Stale");
  g_assert_true(gtk_widget_has_css_class(row, "dim"));
  wx_row_item_set_offline(item, TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "Offline"); /* offline wins */
  wx_row_item_set_offline(item, FALSE);
  wx_row_item_set_stale(item, FALSE);
  wx_row_item_set_loading(item, TRUE);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-marker"), ==, "Updating\xE2\x80\xA6");
  g_assert_false(gtk_widget_has_css_class(row, "dim"));
  /* A place without region shows no region line; a long name is ellipsised, not cut. */
  g_autoptr(WxPlace) bare = wx_place_new("Oslo", NULL, NULL, NULL, 59.9, 10.7, "Europe/Oslo", NULL);
  g_autoptr(WxRowItem) bare_item = wx_row_item_new(bare);
  wx_row_bind(WX_ROW(row), bare_item);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-region"), ==, "");
  g_assert_false(gtk_widget_get_visible(wxt_find_named(row, "wx-row-region")));
  /* Unbinding blanks the row and drops its handler on the item. */
  wx_row_bind(WX_ROW(row), NULL);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-name"), ==, "");
  wx_row_item_set_loading(bare_item, TRUE); /* nobody listens: must not touch the row */
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "");
  /* Disposing a bound row is safe, and the item may outlive it. */
  wx_row_bind(WX_ROW(row), item);
  g_object_run_dispose(G_OBJECT(row));
  wx_row_item_set_loading(item, FALSE);
  g_object_unref(row);
}

/* An item made behind the constructor's back (g_object_new() instead of wx_row_item_new()) has no
 * place: a row bound to it logs the critical of refresh() and leaves its widgets as they were,
 * instead of dereferencing the missing place. */
static void
test_row_item_without_a_place(void)
{
  g_autoptr(WxRowItem) item = g_object_new(WX_TYPE_ROW_ITEM, NULL);
  g_assert_null(wx_row_item_get_place(item));
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) named = wx_row_item_new(p);
  GtkWidget *row = g_object_ref_sink(wx_row_new());
  wx_row_bind(WX_ROW(row), named);
  g_assert_cmpstr(wxt_label_text(row, "wx-row-name"), ==, "Miami");
  ASSERT_CRITICAL("refresh", wx_row_bind(WX_ROW(row), item));
  g_assert_cmpstr(wxt_label_text(row, "wx-row-name"), ==, "Miami"); /* kept what it showed */
  ASSERT_CRITICAL("refresh", g_assert_true(wx_row_item_set_loading(item, TRUE)));
  wx_row_bind(WX_ROW(row), NULL); /* unbinding is fine */
  g_assert_cmpstr(wxt_label_text(row, "wx-row-name"), ==, "");
  g_object_unref(row);
}

/* ------------------------------------------------------------------ */
/* Many places                                                        */
/* ------------------------------------------------------------------ */

static void
test_fifty_places(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 20, FALSE};
  Fx *fx = fx_new(&cfg);
  WxPlace *places[WX_PLACE_MAX + 1];
  for (guint i = 0; i < WX_PLACE_MAX; i++) {
    g_autofree char *name = g_strdup_printf("City %02u", i);
    places[i] = place_new(name, 25.0 + i * 0.5, -80.0);
  }
  places[WX_PLACE_MAX] = NULL;
  store_places(places);
  GtkWidget *win = fx_start(fx);
  g_assert_cmpuint(fx_n_items(fx), ==, WX_PLACE_MAX);
  /* Every place is fetched once by the visible round, at most 3 at a time (the scheduler's cap
   * is exercised by its own test); all end up with a forecast. */
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == WX_PLACE_MAX);
  for (guint i = 0; i < WX_PLACE_MAX; i++)
    WAIT_FORECAST(fx_item(fx, i));
  /* The list is a GtkListView over the item model: one row widget per displayed item at most (GTK
   * decides how many it creates; under this toolkit version it may create all 50). */
  g_autoptr(GPtrArray) rows = g_ptr_array_new();
  collect_type(win, WX_TYPE_ROW, rows);
  g_assert_cmpuint(rows->len, >, 0);
  g_assert_cmpuint(rows->len, <=, WX_PLACE_MAX);
  /* The list is full: adding one more is refused by the list itself, the window keeps working. */
  g_autoptr(WxPlace) extra = place_new("One too many", 10.0, 10.0);
  g_assert_false(wx_places_add(places_of(fx), extra));
  g_assert_cmpuint(fx_n_items(fx), ==, WX_PLACE_MAX);
  /* Removing the last one from the end of the list works. */
  g_autoptr(WxPlace) last = place_new("City 49", 25.0 + 49 * 0.5, -80.0);
  g_autofree char *lkey = key_of(last);
  g_assert_true(wx_places_remove(places_of(fx), lkey));
  g_assert_cmpuint(fx_n_items(fx), ==, WX_PLACE_MAX - 1);
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Sources                                                            */
/* ------------------------------------------------------------------ */

static GtkWidget *
switch_for(GtkWidget *win, guint index)
{
  g_autoptr(GPtrArray) switches = g_ptr_array_new();
  wxt_collect_named(win, "wx-sources-switch", switches);
  g_assert_cmpuint(index, <, switches->len);
  return g_ptr_array_index(switches, index);
}

static char *
status_texts(GtkWidget *win)
{
  g_autoptr(GPtrArray) labels = g_ptr_array_new();
  wxt_collect_named(win, "wx-sources-status", labels);
  GString *s = g_string_new("");
  for (guint i = 0; i < labels->len; i++)
    g_string_append_printf(s, "%s%s", i > 0 ? "|" : "", gtk_label_get_text(g_ptr_array_index(labels, i)));
  return g_string_free(s, FALSE);
}

static void
test_sources_page_status_and_toggle(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE}; /* the gate keeps the first refresh in flight */
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  g_autofree char *none = status_texts(win);
  g_assert_cmpstr(none, ==, "No forecast loaded yet|No forecast loaded yet|No forecast loaded yet");
  WxRowItem *item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  gate_release(gate_of(fx), -1);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_autofree char *used = status_texts(win);
  g_assert_cmpstr(used, ==,
                  "Used for this place (1 forecast model)|Used for this place (1 forecast model)|"
                  "Used for this place (1 forecast model)");
  g_assert_cmpstr(dtext(win, "wx-sources-note"), ==,
                  "Forecasts blend several sources with fixed, documented weights. These weights are "
                  "rules of thumb, not statistics measured from past accuracy, so no accuracy figure "
                  "is claimed.");
  g_assert_true(gtk_switch_get_active(GTK_SWITCH(switch_for(win, 0))));
  g_assert_true(gtk_switch_get_active(GTK_SWITCH(switch_for(win, 1))));

  /* Turning fake-b off: registry, settings and the forecast follow (the place is asked again once
   * the minimum gap since its last request has passed). */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  guint a_before = wx_fake_provider_get_fetch_count(fx->a);
  guint b_before = wx_fake_provider_get_fetch_count(fx->b);
  gtk_switch_set_active(GTK_SWITCH(switch_for(win, 1)), FALSE);
  g_assert_false(wx_registry_is_enabled(fx->registry, "fake-b"));
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-a"));
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == a_before + 1);
  gate_release(gate_of(fx), -1);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->b), ==, b_before); /* not asked any more */
  WXT_WAIT_FOR(g_str_has_suffix(dtext(win, "wx-detail-footer"), "Sources: Fake fake-a, Gate"));
  g_autofree char *off = status_texts(win);
  g_assert_cmpstr(off, ==,
                  "Used for this place (1 forecast model)|Turned off|"
                  "Used for this place (1 forecast model)");

  /* The choice is persisted and applied to the registry at the next start. */
  wx_registry_set_enabled(fx->registry, "fake-b", TRUE); /* a fresh process would start enabled */
  win = fx_restart(fx);
  g_assert_false(wx_registry_is_enabled(fx->registry, "fake-b"));
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-a"));
  g_assert_false(gtk_switch_get_active(GTK_SWITCH(switch_for(win, 1))));
  /* The new application's scheduler remembers nothing, so it fetches the place at start-up (the
   * gate holds it); when that is done and the gap has passed, turning fake-b on again fetches
   * with both. */
  item = fx_item(fx, 0);
  WXT_WAIT_FOR(wx_row_item_get_loading(item));
  gate_release(gate_of(fx), -1);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  a_before = wx_fake_provider_get_fetch_count(fx->a);
  gtk_switch_set_active(GTK_SWITCH(switch_for(win, 1)), TRUE);
  WXT_WAIT_FOR(wx_registry_is_enabled(fx->registry, "fake-b"));
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) > a_before);
  fx_stop(fx);
  g_autoptr(WxSettings) s = wx_settings_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_settings_load(s, &err));
  g_assert_no_error(err);
  g_assert_false(wx_settings_is_provider_disabled(s, "fake-b"));
  fx_free(fx);
}

static void
test_sources_attribution_and_failed_status(void)
{
  FxConfig cfg = {RAIN_DRY, -1, WX_ERROR_RATE_LIMITED, 0, FALSE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_autofree char *st = status_texts(win);
  g_assert_cmpstr(st, ==, "Used for this place (1 forecast model)|Could not load: rate limited");
  g_autoptr(GPtrArray) links = g_ptr_array_new();
  wxt_collect_named(win, "wx-sources-attribution", links);
  g_assert_cmpuint(links->len, ==, 2);
  g_assert_true(g_str_has_prefix(gtk_label_get_label(g_ptr_array_index(links, 0)), "<a href=\"https://example.invalid/\">"));
  /* The detail footer credits the source that contributed, with its link. */
  g_assert_true(g_str_has_prefix(gtk_label_get_label(GTK_LABEL(wxt_find_named(win, "wx-detail-attribution"))),
                                 "<a href=\"https://example.invalid/\">"));
  fx_free(fx);
}

static void
test_about_dialog_from_the_sources_page(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  g_assert_null(toplevel_of_type(GTK_TYPE_ABOUT_DIALOG));
  click(wxt_find_named(win, "wx-sources-about"));
  WXT_WAIT_FOR(toplevel_of_type(GTK_TYPE_ABOUT_DIALOG) != NULL);
  GtkAboutDialog *about = GTK_ABOUT_DIALOG(toplevel_of_type(GTK_TYPE_ABOUT_DIALOG));
  g_assert_cmpstr(gtk_about_dialog_get_program_name(about), ==, "Weather");
  g_assert_cmpstr(gtk_about_dialog_get_version(about), ==, "0.1.0");
  g_assert_cmpint(gtk_about_dialog_get_license_type(about), ==, GTK_LICENSE_GPL_3_0);
  g_assert_true(gtk_window_get_transient_for(GTK_WINDOW(about)) == GTK_WINDOW(win));
  /* gtk_show_about_dialog() keeps one dialog per window: closing hides it, the sources page's
   * About button shows the same one again (there is no other route: no "win.about" action). */
  WXT_WAIT_FOR(gtk_widget_get_visible(GTK_WIDGET(about)));
  gtk_window_close(GTK_WINDOW(about));
  WXT_WAIT_FOR(!gtk_widget_get_visible(GTK_WIDGET(about)));
  click(wxt_find_named(win, "wx-sources-about"));
  WXT_WAIT_FOR(gtk_widget_get_visible(GTK_WIDGET(about)));
  g_assert_true(toplevel_of_type(GTK_TYPE_ABOUT_DIALOG) == GTK_WIDGET(about));
  gtk_window_close(GTK_WINDOW(about));
  fx_free(fx);
}

static void
test_menu_button_opens_the_sources_popover(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  GtkWidget *menu = wxt_find_named(win, "wx-menu-button");
  g_assert_true(GTK_IS_MENU_BUTTON(menu));
  GtkPopover *pop = gtk_menu_button_get_popover(GTK_MENU_BUTTON(menu));
  g_assert_true(WX_IS_SOURCES(pop));
  gtk_menu_button_popup(GTK_MENU_BUTTON(menu));
  WXT_WAIT_FOR(gtk_widget_get_mapped(GTK_WIDGET(pop)));
  gtk_menu_button_popdown(GTK_MENU_BUTTON(menu));
  WXT_WAIT_FOR(!gtk_widget_get_mapped(GTK_WIDGET(pop)));
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Shutdown, closing, persistence                                     */
/* ------------------------------------------------------------------ */

static void
test_close_window_with_a_refresh_in_flight(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE}; /* the gate keeps the requests in flight */
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  GtkWidget *win = fx_start(fx);
  WXT_WAIT_FOR(wx_row_item_get_loading(fx_item(fx, 0)));
  /* The user closes the window: the requests are cancelled, nothing is logged as critical or
   * warning (the log writer of this test aborts on any), the shutdown does not wait for them. */
  gtk_window_close(GTK_WINDOW(win));
  WXT_WAIT_FOR(fx_window(fx) == NULL || !gtk_widget_get_mapped(fx_window(fx)));
  gint64 ms = fx_stop(fx);
  g_assert_cmpint(ms, <, 3000);
  fx_free(fx);
}

static void
test_shutdown_saves_everything_within_the_limit(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  /* Edits made less than the 3 s save delay before the end: places, units, selection. */
  g_autoptr(WxPlace) o = orlando();
  g_autofree char *okey = key_of(o);
  g_assert_true(wx_places_add(places_of(fx), o));
  wx_app_select(fx->app, okey);
  click(wxt_find_named(win, "wx-units-button"));
  gint64 ms = fx_stop(fx);
  g_assert_cmpint(ms, <, WX_APP_SHUTDOWN_WAIT_MS);
  g_autoptr(WxPlaces) list = wx_places_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_places_load(list, NULL, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_places_get_n_places(list), ==, 2);
  g_assert_cmpstr(wx_places_get_place(list, 1)->name, ==, "Orlando");
  g_autoptr(WxSettings) s = wx_settings_new(NULL);
  g_assert_true(wx_settings_load(s, &err));
  g_assert_no_error(err);
  g_assert_cmpint(wx_settings_get_units(s), ==, WX_UNITS_METRIC);
  g_assert_cmpstr(wx_settings_get_selected(s), ==, okey);
  g_autoptr(WxCache) cache = wx_cache_new(NULL);
  g_assert_true(wx_cache_load(cache, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_cache_get_n_places(cache), >=, 1);
  g_autoptr(WxPlace) m = miami();
  g_autofree char *mkey = key_of(m);
  g_autoptr(WxForecast) f = wx_cache_get(cache, mkey, NULL);
  g_assert_nonnull(f);
  g_assert_cmpstr(wx_forecast_get_place(f)->name, ==, "Miami");
  /* No temporary file is left behind. */
  g_autofree char *dir = g_path_get_dirname(wx_places_get_path(list));
  g_autoptr(GDir) d = g_dir_open(dir, 0, NULL);
  const char *name;
  while (d != NULL && (name = g_dir_read_name(d)) != NULL)
    g_assert_null(strstr(name, ".wx-tmp-"));
  fx_free(fx);
}

static void
test_places_changed_elsewhere_is_reflected(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  GtkWidget *stack = wxt_find_named(win, "wx-main-stack");
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(stack)), ==, "empty");
  g_autoptr(WxPlace) m = miami();
  g_assert_true(wx_places_add(places_of(fx), m));
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(stack)), ==, "main");
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  /* The new place is fetched at once (the window is visible and online). */
  WAIT_FORECAST(fx_item(fx, 0));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  /* Re-adding the same place, or one within 5 km, is refused by the list; the window is unchanged. */
  g_autoptr(WxPlace) near = place_new("Miami Beach", 25.7743, -80.1900);
  g_assert_false(wx_places_add(places_of(fx), near));
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  g_assert_true(wx_places_remove(places_of(fx), wx_row_item_get_key(fx_item(fx, 0))));
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(stack)), ==, "empty");
  fx_free(fx);
}

static void
test_api_before_the_load_has_finished_is_ignored(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  store_settings(WX_UNITS_METRIC, NULL, NULL);
  fx_register(fx);
  /* The worker thread owns the settings and the places until load_done() runs on this thread. */
  wx_app_set_units(fx->app, WX_UNITS_METRIC);
  wx_app_select(fx->app, "25.7743,-80.1937");
  wx_app_set_provider_enabled(fx->app, "fake-a", FALSE);
  wx_app_refresh_selected(fx->app);
  g_assert_null(wx_app_get_selected(fx->app));
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-a"));
  g_application_activate(G_APPLICATION(fx->app));
  WXT_WAIT_FOR(fx_window(fx) != NULL);
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_METRIC); /* from the file */
  fx_free(fx);
}

static void
test_refresh_without_selection_or_offline_does_nothing(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  fx_start(fx);
  wx_app_refresh_selected(fx->app); /* no place */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 0);
  g_autoptr(WxPlace) m = miami();
  g_assert_true(wx_places_add(places_of(fx), m));
  WAIT_FORECAST(fx_item(fx, 0));
  guint n = wx_fake_provider_get_fetch_count(fx->a);
  emit_network(FALSE);
  wx_app_refresh_selected(fx->app); /* offline */
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE); /* offline: switched, not fetched */
  wxt_pump_ms(200);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, n);
  g_assert_false(wx_registry_is_enabled(fx->registry, "fake-b"));
  /* An unknown provider id is ignored; the same state again changes nothing. */
  wx_app_set_provider_enabled(fx->app, "no-such-provider", FALSE);
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-a"));
  emit_network(TRUE);
  fx_free(fx);
}

static void
test_corrupt_files_start_empty_with_one_warning_each(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  g_autofree char *cfgdir = g_build_filename(g_get_user_config_dir(), "weather", NULL);
  g_autofree char *cachedir = g_build_filename(g_get_user_cache_dir(), "weather", NULL);
  g_assert_cmpint(g_mkdir_with_parents(cfgdir, 0700), ==, 0);
  g_assert_cmpint(g_mkdir_with_parents(cachedir, 0700), ==, 0);
  g_autofree char *pf = g_build_filename(cfgdir, "places.json", NULL);
  g_autofree char *sf = g_build_filename(cfgdir, "settings.json", NULL);
  g_autofree char *cf = g_build_filename(cachedir, "forecasts.json", NULL);
  g_assert_true(g_file_set_contents(pf, "{not json", -1, NULL));
  g_assert_true(g_file_set_contents(sf, "[1,2,3]\n", -1, NULL));
  g_assert_true(g_file_set_contents(cf, "\x01\x02\x03", -1, NULL));
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not read the saved places (starting empty)*");
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not read the settings (using defaults)*");
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not read the forecast cache (starting empty)*");
  GtkWidget *win = fx_start(fx);
  g_test_assert_expected_messages();
  g_assert_cmpuint(fx_n_items(fx), ==, 0);
  g_assert_cmpstr(gtk_stack_get_visible_child_name(GTK_STACK(wxt_find_named(win, "wx-main-stack"))),
                  ==, "empty");
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_IMPERIAL);
  /* The app is usable: a place can be added. */
  g_autoptr(WxPlace) m = miami();
  g_assert_true(wx_places_add(places_of(fx), m));
  WAIT_FORECAST(fx_item(fx, 0));
  fx_free(fx);
}

static void
test_some_invalid_places_are_dropped_with_one_warning(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  g_autofree char *cfgdir = g_build_filename(g_get_user_config_dir(), "weather", NULL);
  g_assert_cmpint(g_mkdir_with_parents(cfgdir, 0700), ==, 0);
  g_autofree char *pf = g_build_filename(cfgdir, "places.json", NULL);
  g_assert_true(g_file_set_contents(
      pf,
      "{\"version\":1,\"places\":[{\"name\":\"Miami\",\"admin1\":\"Florida\",\"country\":\"United States\","
      "\"country_code\":\"US\",\"lat\":25.7743,\"lon\":-80.1937,\"timezone\":\"America/New_York\"},"
      "{\"name\":\"\",\"lat\":1,\"lon\":2},{\"name\":\"Far\",\"lat\":999,\"lon\":0}]}",
      -1, NULL));
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*2 invalid saved places were dropped*");
  fx_start(fx);
  g_test_assert_expected_messages();
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Keyboard and accessibility                                         */
/* ------------------------------------------------------------------ */

static void
check_accel(GtkApplication *app, const char *accel, const char *action)
{
  g_auto(GStrv) actions = gtk_application_get_actions_for_accel(app, accel);
  g_assert_nonnull(actions);
  g_assert_cmpuint(g_strv_length(actions), ==, 1);
  g_assert_cmpstr(actions[0], ==, action);
}

static void
test_keyboard_accelerators_and_actions(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  GtkWidget *win = fx_start(fx);
  GtkApplication *app = GTK_APPLICATION(fx->app);
  check_accel(app, "<Control>n", "win.add");
  check_accel(app, "F5", "win.refresh");
  check_accel(app, "<Control>r", "win.refresh");
  check_accel(app, "<Control>u", "win.toggle-units");
  /* The actions exist with these names and no parameter. */
  const char *names[] = {"add", "refresh", "toggle-units"};
  for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
    g_assert_true(g_action_group_has_action(G_ACTION_GROUP(win), names[i]));
    g_assert_null(g_action_group_get_action_parameter_type(G_ACTION_GROUP(win), names[i]));
  }
  /* Every header control is focusable, and the icon-only ones have a tooltip (their accessible
   * label is set with it). */
  const char *controls[] = {"wx-add-button", "wx-refresh-button", "wx-units-button", "wx-menu-button"};
  for (guint i = 0; i < G_N_ELEMENTS(controls); i++) {
    GtkWidget *w = wxt_find_named(win, controls[i]);
    g_assert_nonnull(w);
    g_assert_true(gtk_widget_get_focusable(w) || gtk_widget_get_can_focus(w) ||
                  gtk_widget_get_focusable(gtk_widget_get_first_child(w)));
    g_assert_nonnull(gtk_widget_get_tooltip_text(w));
  }
  g_assert_cmpstr(tooltip_of(wxt_find_named(win, "wx-add-button")), ==, "Add a city (Ctrl+N)");
  g_assert_cmpstr(tooltip_of(wxt_find_named(win, "wx-refresh-button")), ==, "Refresh this place (F5)");
  g_assert_cmpstr(tooltip_of(wxt_find_named(win, "wx-menu-button")), ==, "Data sources and about");
  /* The list is focusable and navigable by the list's own actions (what the arrow keys call). */
  GtkWidget *list = wxt_find_named(win, "wx-place-list");
  g_assert_true(gtk_widget_grab_focus(list));
  WXT_WAIT_FOR(row_named(win, "Orlando") != NULL);
  g_autoptr(WxPlace) o = orlando();
  g_autofree char *okey = key_of(o);
  g_assert_true(gtk_widget_activate_action(list, "list.select-item", "(ubb)", 1u, FALSE, FALSE));
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, okey);
  /* Tab moves focus through the window without a mouse: from the list it reaches another widget. */
  gboolean moved = gtk_widget_child_focus(win, GTK_DIR_TAB_FORWARD);
  g_assert_true(moved);
  g_assert_nonnull(gtk_window_get_focus(GTK_WINDOW(win)));
  /* The keyboard route to the refresh action works while a place is selected and not loading; the
   * place was requested a moment ago, so the minimum gap has to pass first. */
  WxRowItem *selected = fx_item(fx, 1);
  WAIT_FORECAST(selected);
  WXT_WAIT_FOR(!wx_row_item_get_loading(selected));
  g_assert_false(g_action_group_has_action(G_ACTION_GROUP(win), "about")); /* no unreachable action */
  warp_clocks(WX_APP_REFRESH_MIN_GAP_S + 1);
  guint n = wx_fake_provider_get_fetch_count(fx->a);
  g_assert_true(g_action_group_get_action_enabled(G_ACTION_GROUP(win), "refresh"));
  g_action_group_activate_action(G_ACTION_GROUP(win), "refresh", NULL);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) > n);
  /* Ctrl+N opens the picker, which has the focus chain entry -> list and closes with Escape. */
  g_action_group_activate_action(G_ACTION_GROUP(win), "add", NULL);
  WXT_WAIT_FOR(toplevel_of_type(WX_TYPE_PICKER) != NULL);
  GtkWidget *picker = toplevel_of_type(WX_TYPE_PICKER);
  g_assert_nonnull(wxt_find_named(picker, "wx-picker-search-entry"));
  fx_free(fx);
}

static void
test_window_dispose_is_safe(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  /* The window goes away while the application and the items live on: later changes of the items
   * and the application must not reach it. */
  g_object_ref(win);
  gtk_window_destroy(GTK_WINDOW(win));
  g_object_run_dispose(G_OBJECT(win));
  g_object_unref(win);
  wx_row_item_set_loading(item, TRUE);
  wx_row_item_set_loading(item, FALSE);
  emit_network(FALSE);
  emit_network(TRUE);
  wx_app_set_units(fx->app, WX_UNITS_METRIC);
  wxt_pump_idle();
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* The real binary                                                    */
/* ------------------------------------------------------------------ */

/* Reads what is available on @out_fd (GLib prints g_debug() lines to stdout) and @err_fd (warnings,
 * criticals) into @out, waiting at most @ms; a closed pipe is set to -1. */
static void
drain_pipes(int *out_fd, int *err_fd, GString *out, int ms)
{
  struct pollfd p[2] = {{.fd = *out_fd, .events = POLLIN}, {.fd = *err_fd, .events = POLLIN}};
  if (poll(p, 2, ms) <= 0)
    return;
  int *fds[2] = {out_fd, err_fd};
  for (int i = 0; i < 2; i++) {
    if (p[i].revents == 0)
      continue;
    char buf[1024];
    ssize_t n = read(*fds[i], buf, sizeof buf);
    if (n > 0) {
      g_string_append_len(out, buf, n);
    } else {
      close(*fds[i]);
      *fds[i] = -1; /* poll() ignores a negative descriptor */
    }
  }
}

/* Starts the weather binary on a first run (no place, so no request leaves the machine), waits for
 * its "loaded" and "window visible" debug lines, sends @sig and checks that it exits by itself with
 * status 0 and without a critical or a warning. */
static void
quit_signal_case(int sig)
{
  const char *bin = g_getenv("WX_WEATHER_BIN");
  if (bin == NULL) {
    g_test_skip("WX_WEATHER_BIN is not set");
    return;
  }
  reset_storage();
  char **env = g_get_environ();
  env = g_environ_setenv(env, "G_MESSAGES_DEBUG", "weather", TRUE);
  char *argv[] = {(char *)bin, NULL};
  GPid pid = 0;
  gint out_fd = -1;
  gint err_fd = -1;
  GError *err = NULL;
  g_assert_true(g_spawn_async_with_pipes(NULL, argv, env, G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &pid,
                                         NULL, &out_fd, &err_fd, &err));
  g_assert_no_error(err);
  g_strfreev(env);
  GString *out = g_string_new("");
  gint64 end = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
  while ((strstr(out->str, "loaded 0 places") == NULL || strstr(out->str, "window visible=1") == NULL) &&
         g_get_monotonic_time() < end)
    drain_pipes(&out_fd, &err_fd, out, 200);
  g_assert_nonnull(strstr(out->str, "loaded 0 places"));
  g_assert_nonnull(strstr(out->str, "window visible=1"));
  g_assert_cmpint(kill(pid, sig), ==, 0);
  int status = 0;
  gint64 deadline = g_get_monotonic_time() + 10 * G_USEC_PER_SEC;
  pid_t done = 0;
  while ((done = waitpid(pid, &status, WNOHANG)) == 0 && g_get_monotonic_time() < deadline)
    drain_pipes(&out_fd, &err_fd, out, 100);
  g_assert_cmpint(done, ==, pid); /* it ended by itself within 10 s */
  drain_pipes(&out_fd, &err_fd, out, 0);
  g_assert_true(WIFEXITED(status));
  g_assert_cmpint(WEXITSTATUS(status), ==, 0);
  g_assert_nonnull(strstr(out->str, "shutdown: saving"));
  g_assert_null(strstr(out->str, "CRITICAL"));
  g_assert_null(strstr(out->str, "WARNING"));
  if (out_fd >= 0)
    close(out_fd);
  if (err_fd >= 0)
    close(err_fd);
  g_string_free(out, TRUE);
  g_spawn_close_pid(pid);
  reset_storage();
}

static void
test_binary_quits_cleanly_on_sigterm(void)
{
  quit_signal_case(SIGTERM);
}

static void
test_binary_quits_cleanly_on_sigint(void)
{
  quit_signal_case(SIGINT);
}

/* ------------------------------------------------------------------ */
/* Warped clocks                                                      */
/* ------------------------------------------------------------------ */

/* The tests that need minutes of wall time shift the clocks instead of waiting: this executable
 * defines clock_gettime(), which (being in the executable) the dynamic linker prefers to libc's for
 * every caller in the process, GLib's g_get_monotonic_time() / g_get_real_time() included. It
 * forwards to the kernel and adds an offset that only warp_clocks() changes. Both clocks are
 * shifted by the same amount, so the scheduler sees time pass and no clock jump. */
static _Atomic long long warp_mono_ns;
static _Atomic long long warp_real_ns;

int
clock_gettime(clockid_t clock_id, struct timespec *ts)
{
  if (syscall(SYS_clock_gettime, (long)clock_id, ts) != 0)
    return -1;
  long long add = 0;
  if (clock_id == CLOCK_MONOTONIC || clock_id == CLOCK_MONOTONIC_RAW || clock_id == CLOCK_BOOTTIME)
    add = warp_mono_ns;
  else if (clock_id == CLOCK_REALTIME)
    add = warp_real_ns;
  if (add != 0) {
    long long nsec = ts->tv_nsec + add % 1000000000LL;
    ts->tv_sec += add / 1000000000LL + nsec / 1000000000LL;
    ts->tv_nsec = nsec % 1000000000LL;
  }
  return 0;
}

/* GLib reads the wall clock with gettimeofday(): shifted the same way. */
int
gettimeofday(struct timeval *tv, void *tz)
{
  if (syscall(SYS_gettimeofday, tv, tz) != 0)
    return -1;
  if (tv != NULL && warp_real_ns != 0) {
    long long usec = tv->tv_usec + (warp_real_ns % 1000000000LL) / 1000;
    tv->tv_sec += warp_real_ns / 1000000000LL + usec / 1000000;
    tv->tv_usec = usec % 1000000;
  }
  return 0;
}

static void
warp_clocks(gint64 seconds)
{
  warp_mono_ns += seconds * 1000000000LL;
  warp_real_ns += seconds * 1000000000LL;
}

static void
test_clock_ticks_while_visible_only(void)
{
  gint64 mono = g_get_monotonic_time();
  gint64 real = g_get_real_time();
  warp_clocks(5);
  g_assert_cmpint(g_get_monotonic_time() - mono, >=, 5 * G_USEC_PER_SEC);
  g_assert_cmpint(g_get_real_time() - real, >=, 5 * G_USEC_PER_SEC); /* the shim reaches GLib */

  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  gint64 first = wx_row_item_get_now_s(item);
  warp_clocks(WX_APP_CLOCK_TICK_S + 1);
  WXT_WAIT_FOR(wx_row_item_get_now_s(item) - first >= WX_APP_CLOCK_TICK_S);
  /* Hidden: the clock is removed, nothing advances the item any more. */
  gtk_widget_set_visible(win, FALSE);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(win));
  gint64 stopped = wx_row_item_get_now_s(item);
  warp_clocks(3 * WX_APP_CLOCK_TICK_S);
  wxt_pump_ms(300);
  g_assert_cmpint(wx_row_item_get_now_s(item), ==, stopped);
  /* Visible again: the item gets the time at once and the clock runs again. */
  gtk_window_present(GTK_WINDOW(win));
  WXT_WAIT_FOR(wx_row_item_get_now_s(item) - stopped >= 3 * WX_APP_CLOCK_TICK_S);
  gint64 again = wx_row_item_get_now_s(item);
  warp_clocks(WX_APP_CLOCK_TICK_S + 1);
  WXT_WAIT_FOR(wx_row_item_get_now_s(item) - again >= WX_APP_CLOCK_TICK_S);
  fx_free(fx);
}

/* The display clock runs only while the window is visible AND the network is available (no
 * periodic timer otherwise); every change of either gives the items the time once. */
static void
test_clock_stops_while_offline(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  gint64 first = wx_row_item_get_now_s(item);
  warp_clocks(WX_APP_CLOCK_TICK_S + 1);
  WXT_WAIT_FOR(wx_row_item_get_now_s(item) - first >= WX_APP_CLOCK_TICK_S); /* online: ticks */

  /* Offline: the items get the time once, then no tick however much time passes. */
  warp_clocks(5);
  emit_network(FALSE);
  gint64 at_transition = wx_row_item_get_now_s(item);
  g_assert_cmpint(at_transition - first, >=, WX_APP_CLOCK_TICK_S + 5);
  for (int round = 0; round < 3; round++) {
    warp_clocks(WX_APP_CLOCK_TICK_S + 1);
    wxt_pump_ms(300);
    g_assert_cmpint(wx_row_item_get_now_s(item), ==, at_transition);
  }
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1); /* and no request */

  /* Back online: the items get the time at once and the clock runs again. */
  emit_network(TRUE);
  gint64 back = wx_row_item_get_now_s(item);
  g_assert_cmpint(back - at_transition, >=, 3 * WX_APP_CLOCK_TICK_S);
  warp_clocks(WX_APP_CLOCK_TICK_S + 1);
  WXT_WAIT_FOR(wx_row_item_get_now_s(item) - back >= WX_APP_CLOCK_TICK_S);

  /* Hidden and offline, then visible but still offline: no clock in either state. */
  emit_network(FALSE);
  gtk_widget_set_visible(win, FALSE);
  WXT_WAIT_FOR(!gtk_widget_get_mapped(win));
  gint64 hidden = wx_row_item_get_now_s(item);
  warp_clocks(2 * WX_APP_CLOCK_TICK_S + 1);
  wxt_pump_ms(300);
  g_assert_cmpint(wx_row_item_get_now_s(item), ==, hidden);
  gtk_window_present(GTK_WINDOW(win));
  WXT_WAIT_FOR(gtk_widget_get_mapped(win));
  wxt_pump_idle();
  gint64 shown = wx_row_item_get_now_s(item);
  g_assert_cmpint(shown - hidden, >=, 2 * WX_APP_CLOCK_TICK_S);
  warp_clocks(2 * WX_APP_CLOCK_TICK_S + 1);
  wxt_pump_ms(300);
  g_assert_cmpint(wx_row_item_get_now_s(item), ==, shown);
  fx_free(fx);
}

static void
test_periodic_round_after_ten_minutes(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  /* Nine minutes later nothing happened (the periodic round skips a place that young) ... */
  warp_clocks(9 * 60 - 30);
  wxt_pump_ms(200);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 1);
  /* ... and after the period the round fetches it again. */
  warp_clocks(WX_SCHED_PERIOD_US / G_USEC_PER_SEC);
  WXT_WAIT_FOR(wx_fake_provider_get_fetch_count(fx->a) == 2);
  WXT_WAIT_FOR(!wx_row_item_get_loading(item));
  g_assert_nonnull(wx_row_item_get_forecast(item));
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Application: properties, activation, selection, shutdown           */
/* ------------------------------------------------------------------ */

static void
test_app_properties(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  fx_start(fx);
  gboolean offline = TRUE;
  int units = 99;
  g_object_get(fx->app, "offline", &offline, "units", &units, NULL);
  g_assert_false(offline);
  g_assert_cmpint(units, ==, WX_UNITS_IMPERIAL);
  guint notified = 0;
  g_signal_connect_swapped(fx->app, "notify::offline", G_CALLBACK(g_atomic_int_inc), &notified);
  g_signal_connect_swapped(fx->app, "notify::units", G_CALLBACK(g_atomic_int_inc), &notified);
  emit_network(TRUE); /* no change: no notification */
  g_assert_cmpuint(notified, ==, 0);
  emit_network(FALSE);
  g_assert_cmpuint(notified, ==, 1);
  g_object_get(fx->app, "offline", &offline, NULL);
  g_assert_true(offline);
  emit_network(FALSE);
  g_assert_cmpuint(notified, ==, 1);
  emit_network(TRUE);
  g_assert_cmpuint(notified, ==, 2);
  wx_app_set_units(fx->app, WX_UNITS_METRIC);
  g_assert_cmpuint(notified, ==, 3);
  g_object_get(fx->app, "units", &units, NULL);
  g_assert_cmpint(units, ==, WX_UNITS_METRIC);
  fx_free(fx);
}

static void
test_activate_twice_presents_the_same_window(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  g_application_activate(G_APPLICATION(fx->app));
  wxt_pump_idle();
  g_assert_cmpuint(g_list_length(gtk_application_get_windows(GTK_APPLICATION(fx->app))), ==, 1);
  g_assert_true(fx_window(fx) == win);
  fx_free(fx);
}

static void
test_selection_dropped_when_place_removed(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  GtkWidget *win = fx_start(fx);
  g_autoptr(WxPlace) o = orlando();
  g_autofree char *okey = key_of(o);
  wx_app_select(fx->app, okey);
  g_assert_cmpstr(wx_app_get_selected(fx->app), ==, okey);
  /* Without a window nobody re-selects: the removed place's selection is dropped. */
  gtk_window_destroy(GTK_WINDOW(win));
  wxt_pump_idle();
  g_assert_true(wx_places_remove(places_of(fx), okey));
  g_assert_null(wx_app_get_selected(fx->app));
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  fx_free(fx);
}

static void
test_shutdown_while_loading(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  fx_register(fx);
  /* The start-up load is still running on its worker: shutdown waits for it, creates no window
   * and starts no request. */
  gint64 t0 = g_get_monotonic_time();
  G_APPLICATION_GET_CLASS(fx->app)->shutdown(G_APPLICATION(fx->app));
  g_assert_cmpint((g_get_monotonic_time() - t0) / 1000, <, WX_APP_SHUTDOWN_WAIT_MS);
  g_assert_cmpuint(fx_n_items(fx), ==, 0);
  g_assert_null(gtk_application_get_windows(GTK_APPLICATION(fx->app)));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, 0);
  g_clear_object(&fx->app);
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Saves                                                              */
/* ------------------------------------------------------------------ */

static void
test_save_failures_are_logged(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  /* A directory where a file must be written: the atomic rename cannot succeed. */
  const char *dirs[] = {g_get_user_config_dir(), g_get_user_config_dir(), g_get_user_cache_dir()};
  const char *names[] = {"places.json", "settings.json", "forecasts.json"};
  for (guint i = 0; i < 3; i++) {
    g_autofree char *path = g_build_filename(dirs[i], "weather", names[i], NULL);
    g_assert_cmpint(g_mkdir_with_parents(path, 0700), ==, 0);
  }
  g_autoptr(WxPlace) m = miami();
  g_assert_true(wx_places_add(places_of(fx), m)); /* the places and, once fetched, the cache */
  click(wxt_find_named(win, "wx-units-button"));  /* the settings */
  WAIT_FORECAST(fx_item(fx, 0));
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not save the *");
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not save the *");
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, "*Could not save the *");
  gint64 ms = fx_stop(fx);
  g_test_assert_expected_messages();
  g_assert_cmpint(ms, <, WX_APP_SHUTDOWN_WAIT_MS);
  fx_free(fx);
}

static guint edit_ticks;
static WxApp *edit_app;

/* Edits the places, the settings and (through refreshes) the cache all the time. */
static gboolean
edit_tick(gpointer user_data)
{
  (void)user_data;
  edit_ticks++;
  WxPlaces *places = wx_app_get_places(edit_app);
  wx_places_move(places, edit_ticks % 2 == 0 ? 1 : 0, edit_ticks % 2 == 0 ? 0 : 1);
  wx_app_set_units(edit_app, edit_ticks % 2 == 0 ? WX_UNITS_IMPERIAL : WX_UNITS_METRIC);
  if (edit_ticks % 10 == 0)
    wx_app_refresh_selected(edit_app);
  return G_SOURCE_CONTINUE;
}

static void
test_edits_while_saving(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  fx_start(fx);
  WAIT_FORECAST(fx_item(fx, 0));
  edit_ticks = 0;
  edit_app = fx->app;
  guint id = g_timeout_add(5, edit_tick, NULL);
  /* The first edit arms the 3 s save timer; the saves that follow run while the edits go on, so
   * each save finds its object dirty again when it completes and a new save is scheduled. */
  wxt_pump_ms(WX_APP_SAVE_DELAY_MS + 1500);
  g_source_remove(id);
  g_assert_cmpuint(edit_ticks, >, 100);
  /* At the end everything is stored once more and the files are readable. */
  fx_stop(fx);
  g_autoptr(WxPlaces) list = wx_places_new(NULL);
  GError *err = NULL;
  g_assert_true(wx_places_load(list, NULL, &err));
  g_assert_no_error(err);
  g_assert_cmpuint(wx_places_get_n_places(list), ==, 2);
  fx_free(fx);
}

/* Destroys the windows and drops the application WITHOUT the shutdown drain: what a forced exit
 * leaves behind. Whatever is still pending (saves, requests) completes later and must only free
 * its own memory. */
static void
drop_app(Fx *fx)
{
  GList *windows = g_list_copy(gtk_application_get_windows(GTK_APPLICATION(fx->app)));
  for (GList *l = windows; l != NULL; l = l->next)
    gtk_window_destroy(GTK_WINDOW(l->data));
  g_list_free(windows);
  g_clear_object(&fx->app);
}

/* A file a save has to write and the text its final content holds. */
typedef struct {
  const char *path;
  const char *needle;
} SaveMark;

static gboolean
file_contains(const char *path, const char *needle)
{
  g_autofree char *contents = NULL;
  gsize len = 0;
  return g_file_get_contents(path, &contents, &len, NULL) && strstr(contents, needle) != NULL;
}

/* Asserts that every file holds its text (the saves wrote what the test expects); says which one
 * does not. */
static void
assert_marks(const SaveMark *marks, guint n)
{
  for (guint i = 0; i < n; i++) {
    if (file_contains(marks[i].path, marks[i].needle))
      continue;
    g_autofree char *contents = NULL;
    gboolean read_ok = g_file_get_contents(marks[i].path, &contents, NULL, NULL);
    g_autofree char *shown = g_strescape(read_ok ? contents : "", NULL);
    g_printerr("save missing: %s lacks \"%s\" (%s: %.300s)\n", marks[i].path, marks[i].needle,
               read_ok ? "content" : "unreadable", shown);
    g_assert_true(file_contains(marks[i].path, marks[i].needle));
  }
}

/* Starts the saves that are due (the places were loaded, a place was selected, a forecast arrived)
 * and waits until the application has finished all of them: every save it started has completed
 * and its callback has run, so none is running and none is waiting for the debounce. A round moves
 * the clocks past the debounce, lets the loop start what is dirty and waits for those saves; a save
 * that found its object edited again meanwhile starts one more in the next round, until a round
 * starts nothing. From then on the saves a test starts next are the only ones, and each of them
 * writes the state the test gave it. */
static void
flush_saves(const SaveMark *marks, guint n)
{
  wait_saves_done(); /* saves that were already running (the debounce is real time too) */
  gboolean quiet = FALSE;
  for (guint round = 0; round < 10 && !quiet; round++) {
    guint before = n_saves_started;
    warp_clocks(WX_APP_SAVE_DELAY_MS / 1000 + 1); /* an armed debounce is due now ... */
    wxt_pump_idle();                               /* ... and the loop starts the saves it waits for */
    wait_saves_done();
    quiet = n_saves_started == before;
  }
  g_assert_true(quiet);
  assert_marks(marks, n);
}

/* Runs first: one save of each kind must reach its own counter, or the saves of the other tests
 * would go unobserved (and they would fail late, in confusing ways). The saves are awaited by
 * their files, not by the counters, so that a kind that is not counted is named here at once. */
static void
test_save_counter_self_check(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  fx_start(fx);
  WAIT_FORECAST(fx_item(fx, 0));
  g_autoptr(WxPlace) o = orlando();
  g_assert_true(wx_places_add(places_of(fx), o));
  WAIT_FORECAST(fx_item(fx, 1));
  g_autofree char *places_file = g_build_filename(g_get_user_config_dir(), "weather", "places.json", NULL);
  g_autofree char *settings_file = g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  g_autofree char *cache_file = g_build_filename(g_get_user_cache_dir(), "weather", "forecasts.json", NULL);
  const SaveMark marks[] = {{places_file, "Orlando"}, {settings_file, "imperial"}, {cache_file, "Orlando"}};
  warp_clocks(WX_APP_SAVE_DELAY_MS / 1000 + 1);
  WXT_WAIT_FOR(file_contains(places_file, "Orlando") && file_contains(settings_file, "imperial") &&
               file_contains(cache_file, "Orlando"));
  for (guint k = 0; k < N_SAVE_KINDS; k++) {
    if (n_saves_started_of_kind[k] == 0)
      g_error("save counter self-check: the %s save was written but never counted: the application's "
              "call of wx_%s_save_async() does not reach the counting function "
              "(src/ui/meson.build must build the test's copy of wx-app.c with the renaming defines)",
              save_kind_names[k], save_kind_names[k]);
  }
  flush_saves(marks, G_N_ELEMENTS(marks));
  drop_app(fx);
  fx_free(fx);
}

static void
test_app_disposed_while_saving(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WAIT_FORECAST(fx_item(fx, 0));
  g_autoptr(WxPlace) o = orlando();
  g_assert_true(wx_places_add(places_of(fx), o));
  WAIT_FORECAST(fx_item(fx, 1));
  g_autofree char *places_file = g_build_filename(g_get_user_config_dir(), "weather", "places.json", NULL);
  g_autofree char *settings_file = g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  g_autofree char *cache_file = g_build_filename(g_get_user_cache_dir(), "weather", "forecasts.json", NULL);
  const SaveMark before[] = {{places_file, "Orlando"}, {settings_file, "imperial"}, {cache_file, "Orlando"}};
  flush_saves(before, G_N_ELEMENTS(before)); /* no save is running or waiting from here on */
  /* All three objects are edited in this one turn of the loop (so the debounce cannot start the
   * saves in between, however slow the host): the units (settings), the removal of Orlando (places,
   * and its forecast leaves the cache). Miami stays, so the files keep the same marks. */
  click(wxt_find_named(win, "wx-units-button"));
  g_autofree char *orlando_key = key_of(o);
  g_assert_true(wx_places_remove(places_of(fx), orlando_key));
  const char *const files[] = {places_file, settings_file, cache_file};
  const SaveMark marks[] = {{places_file, "Miami"}, {settings_file, "metric"}, {cache_file, "Miami"}};
  for (guint i = 0; i < G_N_ELEMENTS(files); i++)
    g_assert_cmpint(g_unlink(files[i]), ==, 0); /* they reappear when the saves have written them */
  /* The debounce is due: one turn of the loop starts the three saves (no kind is skipped, because
   * none is in flight), and the application is disposed before the loop dispatches any completion,
   * which therefore finds it gone (the weak references of g_object_run_dispose() are cleared like
   * those of a finalized object). */
  guint started = n_saves_started;
  warp_clocks(WX_APP_SAVE_DELAY_MS / 1000 + 1);
  WXT_WAIT_FOR(n_saves_started == started + 3);
  g_assert_cmpuint(saves_in_flight(), ==, 3);
  g_object_run_dispose(G_OBJECT(fx->app));
  /* The saves the disposed application abandoned finish, write their files and only free their
   * own jobs. */
  wait_saves_done();
  g_assert_cmpuint(n_saves_started, ==, started + 3);
  assert_marks(marks, G_N_ELEMENTS(marks));
  drop_app(fx);
  fx_free(fx);
}

/* TRUE iff every request that reached the gate was cancelled; @n of them reached it. */
static gboolean
gate_all_cancelled(Fx *fx, guint n)
{
  GPtrArray *all = gate_of(fx)->all;
  if (all->len != n)
    return FALSE;
  for (guint i = 0; i < all->len; i++)
    if (!g_cancellable_is_cancelled(g_ptr_array_index(all, i)))
      return FALSE;
  return TRUE;
}

/* Disposed with requests in flight (g_object_run_dispose() clears the weak references of the
 * pending operations like the last unref does, while the object lives on, as it does for a window
 * that outlives it): the disposal cancels every request and unindexes it, a late answer only frees
 * its request, and nothing the window does afterwards reaches a freed request (the unmap of the
 * window used to look up and cancel the freed one: heap-use-after-free). */
static void
test_app_disposed_with_request_in_flight(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), tampa(), NULL});
  fx_start(fx);
  WXT_WAIT_FOR(gate_of(fx)->fetches == 3);
  g_assert_true(wx_row_item_get_loading(fx_item(fx, 0)));
  g_object_run_dispose(G_OBJECT(fx->app));
  WXT_WAIT_FOR(gate_all_cancelled(fx, 3)); /* the service passes the cancellation on */
  /* The answers arrive after the disposal; they only free the requests. */
  gate_release(gate_of(fx), -1);
  wxt_pump_ms(100);
  /* A disposed application ignores every call: nothing is requested, nothing changes. */
  guint a = wx_fake_provider_get_fetch_count(fx->a);
  wx_app_set_window_visible(fx->app, FALSE);
  wx_app_set_window_visible(fx->app, TRUE);
  wx_app_window_focused(fx->app);
  wx_app_refresh_selected(fx->app);
  wx_app_set_provider_enabled(fx->app, "fake-b", FALSE);
  wx_app_set_units(fx->app, WX_UNITS_METRIC);
  wx_app_select(fx->app, NULL);
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, a);
  g_assert_cmpuint(gate_of(fx)->fetches, ==, 3);
  g_assert_true(wx_registry_is_enabled(fx->registry, "fake-b"));
  g_assert_cmpint(wx_app_get_units(fx->app), ==, WX_UNITS_IMPERIAL);
  /* The windows go away (their unmap reports "not visible" to the application). */
  drop_app(fx);
  fx_free(fx);
}

/* The last reference is dropped right after the windows were destroyed, while the cancelled
 * requests have not been answered yet: they only free themselves. */
static void
test_app_unref_with_cancelled_requests_pending(void)
{
  FxConfig cfg = {RAIN_DRY, -1, -1, 0, TRUE};
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  fx_start(fx);
  WXT_WAIT_FOR(gate_of(fx)->fetches == 2);
  drop_app(fx); /* destroys the windows (the requests are cancelled), then drops the application */
  WXT_WAIT_FOR(gate_all_cancelled(fx, 2));
  gate_release(gate_of(fx), -1);
  wxt_pump_ms(100);
  fx_free(fx);
}

typedef struct {
  guint in_flight; /* the saves in flight when the idle ran; G_MAXUINT before */
  guint idle_id;   /* the idle, 0 once it has run */
} LimitJob;

/* A one-shot at G_PRIORITY_HIGH. It records how many saves are in flight, then moves the clocks
 * past the wait limit, so that the next iteration of the loop it runs in finds the limit timer
 * due. It waits for nothing: the main thread is never held here. */
static gboolean
warp_past_the_wait_limit(gpointer user_data)
{
  LimitJob *job = user_data;
  job->idle_id = 0;
  job->in_flight = saves_in_flight();
  warp_clocks(WX_APP_SHUTDOWN_WAIT_MS / 1000 + 1);
  return G_SOURCE_REMOVE;
}

/* The save-start hook of the test below: adds the idle above when the shutdown starts its first
 * save. That is right before the shutdown arms its limit timer and runs its wait loop, so the idle
 * is the first source that loop dispatches. (An idle added earlier is dispatched by a nested main
 * loop that gtk_application_shutdown() runs, as a backtrace of this test shows, before any save
 * is started.) */
static void
add_limit_idle(gpointer data)
{
  LimitJob *job = data;
  job->idle_id = g_idle_add_full(G_PRIORITY_HIGH, warp_past_the_wait_limit, job, NULL);
}

static void
test_shutdown_stops_waiting_at_the_limit(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WAIT_FORECAST(fx_item(fx, 0));
  g_autofree char *flush_settings = g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  g_autofree char *flush_cache = g_build_filename(g_get_user_cache_dir(), "weather", "forecasts.json", NULL);
  const SaveMark flushed[] = {{flush_settings, "imperial"}, {flush_cache, "Miami"}};
  flush_saves(flushed, G_N_ELEMENTS(flushed)); /* no save is running or waiting from here on */
  click(wxt_find_named(win, "wx-units-button")); /* the settings are dirty */
  g_autoptr(WxPlace) o = orlando();
  g_assert_true(wx_places_add(places_of(fx), o)); /* so are the places: the shutdown has saves to wait for */
  g_autofree char *places_file = g_build_filename(g_get_user_config_dir(), "weather", "places.json", NULL);
  g_autofree char *settings_file = g_build_filename(g_get_user_config_dir(), "weather", "settings.json", NULL);
  const SaveMark marks[] = {{places_file, "Orlando"}, {settings_file, "metric"}};
  g_assert_cmpint(g_unlink(places_file), ==, 0); /* they reappear when the saves have written them */
  g_assert_cmpint(g_unlink(settings_file), ==, 0);
  LimitJob job = {G_MAXUINT, 0};
  save_start_hook = add_limit_idle;
  save_start_hook_data = &job;
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_WARNING,
                        "*Gave up waiting for pending saves/requests after 5000 ms*");
  gint64 ms = fx_stop(fx);
  g_test_assert_expected_messages();
  g_assert_null(save_start_hook); /* the shutdown started its saves ... */
  g_assert_cmpuint(job.idle_id, ==, 0); /* ... and the idle ran in its wait loop */
  g_assert_cmpint(ms, >=, WX_APP_SHUTDOWN_WAIT_MS); /* measured on the moved clock: it waited the limit */
  /* The shutdown started the saves of the places and the settings (the cache may be dirty too) and
   * they were still in flight when the limit passed: it stopped waiting for them. */
  g_assert_cmpuint(job.in_flight, >=, 2);
  /* The abandoned saves finish, and write their files, before the storage is wiped. */
  wait_saves_done();
  assert_marks(marks, G_N_ELEMENTS(marks));
  fx_free(fx);
}

static void
test_surface_state_notification_rereads_visibility(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *item = fx_item(fx, 0);
  WAIT_FORECAST(item);
  guint before = wx_fake_provider_get_fetch_count(fx->a);
  /* The surface reports a state change (here: none that matters): the window re-reads the state, finds
   * the visibility unchanged and tells the application nothing. */
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win));
  g_assert_nonnull(surface);
  g_object_notify(G_OBJECT(surface), "state");
  wxt_pump_ms(100);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fx->a), ==, before);
  g_assert_true(gtk_widget_get_mapped(win));
  /* A realize / unrealize cycle re-connects the surface handler: hide and show again. */
  gtk_widget_set_visible(win, FALSE);
  gtk_window_present(GTK_WINDOW(win));
  WXT_WAIT_FOR(gtk_widget_get_mapped(win));
  g_object_notify(G_OBJECT(gtk_native_get_surface(GTK_NATIVE(win))), "state");
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Window: refused and hostile requests                               */
/* ------------------------------------------------------------------ */

static void
test_suggestion_refused_when_saved(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  GtkWidget *win = fx_start(fx);
  g_autoptr(GPtrArray) chips = g_ptr_array_new();
  wxt_collect_named(win, "wx-suggestion", chips);
  g_autoptr(WxPlace) m = miami();
  g_assert_true(wx_places_add(places_of(fx), m)); /* the first-run page is gone now */
  g_assert_cmpuint(wx_places_get_n_places(places_of(fx)), ==, 1);
  /* A late click on the (hidden) Miami suggestion is refused by the list: nothing changes. */
  g_signal_emit_by_name(g_ptr_array_index(chips, 0), "clicked");
  g_assert_cmpuint(wx_places_get_n_places(places_of(fx)), ==, 1);
  g_assert_cmpuint(fx_n_items(fx), ==, 1);
  fx_free(fx);
}

static void
test_hostile_move_request(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), orlando(), NULL});
  GtkWidget *win = fx_start(fx);
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL);
  GtkWidget *row = row_named(win, "Miami");
  g_autoptr(WxPlace) m = miami();
  g_autofree char *mkey = key_of(m);
  g_signal_emit_by_name(row, "move-requested", "junk", -1);
  g_signal_emit_by_name(row, "move-requested", "99.0000,99.0000", 1);
  g_signal_emit_by_name(row, "move-requested", mkey, -1);       /* past the start */
  g_signal_emit_by_name(row, "move-requested", mkey, 2);        /* past the end */
  g_signal_emit_by_name(row, "move-requested", mkey, G_MAXINT); /* far past the end, no overflow */
  g_signal_emit_by_name(row, "move-requested", mkey, G_MININT);
  g_signal_emit_by_name(row, "remove-requested", "junk");
  g_autofree char *order = order_of(fx);
  g_assert_cmpstr(order, ==, "Miami,Orlando");
  g_signal_emit_by_name(row, "move-requested", mkey, 1);
  g_autofree char *moved = order_of(fx);
  g_assert_cmpstr(moved, ==, "Orlando,Miami");
  fx_free(fx);
}

static void
test_dispose_while_mapped(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  g_assert_nonnull(gtk_native_get_surface(GTK_NATIVE(win)));
  /* Disposed while it still has a surface: the surface handler is disconnected. */
  g_object_ref(win);
  g_object_run_dispose(G_OBJECT(win));
  g_object_unref(win);
  wxt_pump_idle();
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* Rows: no outlook, menu, drag and drop                              */
/* ------------------------------------------------------------------ */

static void
test_row_without_outlook(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  g_autoptr(WxForecast) f = make_forecast(p, FALSE);
  GtkWidget *row = g_object_ref_sink(wx_row_new());
  wx_row_bind(WX_ROW(row), item);
  wx_row_item_set_forecast(item, f, T_NOW);
  wx_row_item_set_now_s(item, 5); /* outside the valid time range: no outlook */
  g_assert_null(wx_row_item_get_outlook(item));
  g_assert_cmpstr(wxt_label_text(row, "wx-row-hint"), ==, "No rain data");
  g_assert_cmpstr(wxt_label_text(row, "wx-row-temp"), ==, "\xE2\x80\x94");
  g_object_unref(row);
}

static GtkEventController *
controller_of_type(GtkWidget *w, GType type)
{
  GListModel *controllers = gtk_widget_observe_controllers(w);
  GtkEventController *found = NULL;
  for (guint i = 0, n = g_list_model_get_n_items(controllers); i < n; i++) {
    g_autoptr(GObject) c = g_list_model_get_item(controllers, i);
    if (G_TYPE_CHECK_INSTANCE_TYPE(c, type))
      found = GTK_EVENT_CONTROLLER(c);
  }
  g_object_unref(controllers);
  return found;
}

static char *reorder_source;
static char *reorder_target;

static void
on_reorder(WxRow *row, const char *source, const char *target, gpointer data)
{
  (void)row;
  (void)data;
  g_free(reorder_source);
  g_free(reorder_target);
  reorder_source = g_strdup(source);
  reorder_target = g_strdup(target);
}

static gboolean
drop_value(GtkEventController *target, GValue *value)
{
  gboolean ret = FALSE;
  g_signal_emit_by_name(target, "drop", value, 1.0, 1.0, &ret);
  return ret;
}

static void
test_row_menu_and_dnd(void)
{
  g_autoptr(WxPlace) p = miami();
  g_autoptr(WxRowItem) item = wx_row_item_new(p);
  GtkWidget *row = wx_row_new();
  GtkWidget *window = gtk_window_new();
  gtk_window_set_child(GTK_WINDOW(window), row);
  wx_row_bind(WX_ROW(row), item);
  gtk_window_present(GTK_WINDOW(window));
  WXT_WAIT_FOR(gtk_widget_get_mapped(row));

  /* The menu is built when it is first opened: Move up, Move down, Remove. */
  GtkMenuButton *mb = GTK_MENU_BUTTON(wxt_find_named(row, "wx-row-menu"));
  g_assert_null(gtk_menu_button_get_menu_model(mb));
  gtk_menu_button_popup(mb);
  WXT_WAIT_FOR(gtk_menu_button_get_menu_model(mb) != NULL);
  GMenuModel *menu = gtk_menu_button_get_menu_model(mb);
  g_assert_cmpint(g_menu_model_get_n_items(menu), ==, 3);
  const char *labels[] = {"Move up", "Move down", "Remove"};
  for (int i = 0; i < 3; i++) {
    g_autofree char *label = NULL;
    g_assert_true(g_menu_model_get_item_attribute(menu, i, G_MENU_ATTRIBUTE_LABEL, "s", &label));
    g_assert_cmpstr(label, ==, labels[i]);
  }
  gtk_menu_button_popdown(mb);

  /* Drag source: the payload of a bound row is its key as a string; an unbound row drags nothing. */
  GtkEventController *drag = controller_of_type(row, GTK_TYPE_DRAG_SOURCE);
  g_assert_nonnull(drag);
  GdkContentProvider *provider = NULL;
  g_signal_emit_by_name(drag, "prepare", 1.0, 1.0, &provider);
  g_assert_nonnull(provider);
  GValue value = G_VALUE_INIT;
  g_value_init(&value, G_TYPE_STRING);
  GError *err = NULL;
  g_assert_true(gdk_content_provider_get_value(provider, &value, &err));
  g_assert_no_error(err);
  g_assert_cmpstr(g_value_get_string(&value), ==, wx_row_item_get_key(item));
  g_value_unset(&value);
  g_object_unref(provider);
  g_signal_emit_by_name(drag, "drag-begin", NULL); /* the row becomes the drag icon */

  /* Drop target: a string is handed on as "reorder-requested"; anything else is refused. */
  GtkEventController *drop = controller_of_type(row, GTK_TYPE_DROP_TARGET);
  g_assert_nonnull(drop);
  g_signal_connect(row, "reorder-requested", G_CALLBACK(on_reorder), NULL);
  GValue text = G_VALUE_INIT;
  g_value_init(&text, G_TYPE_STRING);
  g_value_set_string(&text, "some text from elsewhere");
  g_assert_true(drop_value(drop, &text));
  g_assert_cmpstr(reorder_source, ==, "some text from elsewhere");
  g_assert_cmpstr(reorder_target, ==, wx_row_item_get_key(item));
  g_value_set_string(&text, NULL);
  g_assert_false(drop_value(drop, &text));
  g_value_unset(&text);
  GValue number = G_VALUE_INIT;
  g_value_init(&number, G_TYPE_INT);
  g_assert_false(drop_value(drop, &number));
  g_value_unset(&number);

  /* Unbound: nothing to drag, nothing accepts a drop. */
  wx_row_bind(WX_ROW(row), NULL);
  provider = NULL;
  g_signal_emit_by_name(drag, "prepare", 1.0, 1.0, &provider);
  g_assert_null(provider);
  GValue again = G_VALUE_INIT;
  g_value_init(&again, G_TYPE_STRING);
  g_value_set_string(&again, "x");
  g_assert_false(drop_value(drop, &again));
  g_value_unset(&again);
  g_free(reorder_source);
  g_free(reorder_target);
  reorder_source = reorder_target = NULL;
  gtk_window_destroy(GTK_WINDOW(window));
}

/* ------------------------------------------------------------------ */
/* The style sheet reaches the widgets                                */
/* ------------------------------------------------------------------ */

/* Adds the CSS classes of @root and of every descendant (a menu button's popover is one) to @set. */
static void
collect_css_classes(GtkWidget *root, GHashTable *set)
{
  g_auto(GStrv) classes = gtk_widget_get_css_classes(root);
  for (guint i = 0; classes[i] != NULL; i++)
    g_hash_table_add(set, g_strdup(classes[i]));
  for (GtkWidget *c = gtk_widget_get_first_child(root); c != NULL;
       c = gtk_widget_get_next_sibling(c))
    collect_css_classes(c, set);
}

/* The class names that the rules of @css select (".name"; comments are skipped). */
static GPtrArray *
css_selector_classes(const char *css)
{
  GPtrArray *names = g_ptr_array_new_with_free_func(g_free);
  for (const char *p = css; *p != '\0';) {
    if (p[0] == '/' && p[1] == '*') {
      const char *end = strstr(p + 2, "*/");
      g_assert_nonnull(end);
      p = end + 2;
    } else if (p[0] == '.' && (g_ascii_isalpha(p[1]) || p[1] == '_')) {
      const char *q = p + 1;
      while (g_ascii_isalnum(*q) || *q == '-' || *q == '_')
        q++;
      g_ptr_array_add(names, g_strndup(p + 1, (gsize)(q - p - 1)));
      p = q;
    } else {
      p++;
    }
  }
  return names;
}

/* Every class that the compiled-in style sheet selects is carried by some widget of the application
 * in the states that use it, so no rule is dead (the widgets that have only a widget NAME, not a
 * class, are not styled by a ".name" rule). The window has a dimmed place (offline, with data), a
 * place without data, the first-run page, the detail of a forecast, the sources popover and the
 * picker with its results. */
static void
test_every_style_class_reaches_a_widget(void)
{
  FxConfig cfg = FX_DEFAULT;
  Fx *fx = fx_new(&cfg);
  store_places((WxPlace *[]){miami(), NULL});
  GtkWidget *win = fx_start(fx);
  WxRowItem *miami_item = fx_item(fx, 0);
  WAIT_FORECAST(miami_item);
  WXT_WAIT_FOR(!wx_row_item_get_loading(miami_item));
  wx_fake_provider_fail_with(fx->a, WX_ERROR_NETWORK);
  wx_fake_provider_fail_with(fx->b, WX_ERROR_NETWORK);
  g_autoptr(WxPlace) o = orlando(); /* no data: its row is "empty" */
  g_assert_true(wx_places_add(places_of(fx), o));
  wx_app_select(fx->app, wx_row_item_get_key(miami_item));
  emit_network(FALSE); /* Miami: data that is not up to date, so its row is dimmed */
  WXT_WAIT_FOR(row_named(win, "Miami") != NULL && row_named(win, "Orlando") != NULL);
  GtkWidget *miami_row = row_named(win, "Miami");
  WXT_WAIT_FOR(gtk_widget_has_css_class(miami_row, "dim"));
  g_assert_true(gtk_widget_has_css_class(row_named(win, "Orlando"), "empty"));
  /* The row's icon is a descendant of the dimmed row and carries the class that the rule
   * ".wx-row.dim .wx-row-icon" selects. */
  GtkWidget *icon = wxt_find_named(miami_row, "wx-row-icon");
  g_assert_nonnull(icon);
  g_assert_true(gtk_widget_has_css_class(icon, "wx-row-icon"));
  g_assert_true(gtk_widget_is_ancestor(icon, miami_row));
  GtkWidget *picker = open_picker(fx, win);
  WXT_WAIT_FOR(wxt_find_named(picker, "wx-picker-label") != NULL);

  g_autoptr(GHashTable) present = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  collect_css_classes(win, present);
  collect_css_classes(picker, present);

  g_autoptr(GError) error = NULL;
  g_autoptr(GBytes) css = g_resources_lookup_data(
      "/io/github/wtp128pro/Weather/ui/style.css", G_RESOURCE_LOOKUP_FLAGS_NONE, &error);
  g_assert_no_error(error);
  g_autofree char *text = g_strndup(g_bytes_get_data(css, NULL), g_bytes_get_size(css));
  g_autoptr(GPtrArray) wanted = css_selector_classes(text);
  g_assert_cmpuint(wanted->len, >, 20);
  g_autoptr(GString) missing = g_string_new(NULL);
  for (guint i = 0; i < wanted->len; i++) {
    const char *name = g_ptr_array_index(wanted, i);
    if (!g_hash_table_contains(present, name))
      g_string_append_printf(missing, " .%s", name);
  }
  g_assert_cmpstr(missing->str, ==, "");
  fx_free(fx);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  wxt_setup("wx-window-test-XXXXXX");
  g_test_init(&argc, &argv, NULL);
  if (!wxt_init_gtk())
    return 77;

  g_test_add_func("/window/app/save-counter-self-check", test_save_counter_self_check);
  g_test_add_func("/window/hint/table", test_hint_table);
  g_test_add_func("/window/hint/edges", test_hint_edges);
  g_test_add_func("/window/hint/programmer-errors", test_hint_programmer_errors);
  g_test_add_func("/window/item/defaults-and-arguments", test_item_defaults_and_args);
  g_test_add_func("/window/item/setters", test_item_setters);
  g_test_add_func("/window/item/forecast-and-now", test_item_forecast_and_now);
  g_test_add_func("/window/item/dry-claim-needs-coverage", test_item_dry_claim_needs_coverage);
  g_test_add_func("/window/item/changed-handler-drops-references",
                  test_item_changed_handler_may_drop_references);
  g_test_add_func("/window/row/unbound-emits-nothing", test_unbound_row_emits_nothing);
  g_test_add_func("/window/row/binding-follows-item", test_row_binding_follows_item);
  g_test_add_func("/window/row/item-without-a-place", test_row_item_without_a_place);
  g_test_add_func("/window/app/new-with-registry-null", test_app_new_with_registry_null);
  g_test_add_func("/window/app/default-wiring", test_app_default_wiring);
  g_test_add_func("/window/app/custom-registry-as-is", test_app_custom_registry_is_used_as_is);
  g_test_add_func("/window/app/null-arguments", test_app_null_arguments);
  g_test_add_func("/window/app/api-before-load-ignored", test_api_before_the_load_has_finished_is_ignored);
  g_test_add_func("/window/app/refresh-and-switch-edge-cases",
                  test_refresh_without_selection_or_offline_does_nothing);
  g_test_add_func("/window/first-run/empty-state", test_first_run_empty_state);
  g_test_add_func("/window/first-run/suggestion-adds-selects-fetches",
                  test_first_run_suggestion_adds_selects_and_fetches);
  g_test_add_func("/window/first-run/search-button-opens-one-picker",
                  test_first_run_search_button_opens_one_picker);
  g_test_add_func("/window/picker/add-selects-new-place", test_add_via_picker_selects_new_place);
  g_test_add_func("/window/picker/geocoder-failure-inline", test_picker_geocoder_failure_is_inline);
  g_test_add_func("/window/picker/no-results-and-close", test_picker_no_results_and_escape_cancel);
  g_test_add_func("/window/picker/saved-place-refused", test_picker_add_of_saved_place_is_refused_inline);
  g_test_add_func("/window/refresh/loading-then-ok", test_refresh_loading_then_ok);
  g_test_add_func("/window/refresh/partial", test_refresh_partial_one_source_fails);
  g_test_add_func("/window/refresh/failed-then-recovers", test_refresh_failed_without_cache_then_recovers);
  g_test_add_func("/window/refresh/cached-at-once", test_cached_forecast_is_shown_at_once);
  g_test_add_func("/window/refresh/stale-keeps-data", test_stale_data_stays_and_is_marked);
  g_test_add_func("/window/refresh/offline", test_offline_marker_cancel_and_resume);
  g_test_add_func("/window/refresh/hidden-requests-nothing", test_hidden_window_requests_nothing);
  g_test_add_func("/window/refresh/button-forces-request", test_refresh_button_forces_a_new_request);
  g_test_add_func("/window/refresh/rate-limited", test_refresh_is_rate_limited);
  g_test_add_func("/window/refresh/rate-limit-cool-down", test_rate_limited_place_waits_for_the_cool_down);
  g_test_add_func("/window/refresh/local-refusal-no-cool-down", test_local_refusal_starts_no_cool_down);
  g_test_add_func("/window/refresh/rate-limit-out-of-scheduler", test_rate_limited_place_is_out_of_the_scheduler);
  g_test_add_func("/window/refresh/rate-limit-ends-while-hidden", test_rate_limit_cool_down_ending_while_hidden);
  g_test_add_func("/window/refresh/rate-limit-end-is-timed", test_rate_limit_cool_down_end_is_timed);
  g_test_add_func("/window/refresh/switch-flips-coalesced", test_provider_switch_flips_are_coalesced);
  g_test_add_func("/window/refresh/switch-offline-applied-later",
                  test_provider_switch_while_offline_is_applied_later);
  g_test_add_func("/window/refresh/stale-kept-when-cancelled-by-hide",
                  test_forced_refresh_cancelled_by_hide_keeps_the_stale_mark);
  g_test_add_func("/window/refresh/stale-kept-when-cancelled-by-offline",
                  test_forced_refresh_cancelled_by_offline_keeps_the_stale_mark);
  g_test_add_func("/window/refresh/stale-kept-during-provider-switch",
                  test_provider_switch_during_forced_refresh_keeps_the_stale_mark);
  g_test_add_func("/window/rain/dry", test_rain_dry);
  g_test_add_func("/window/rain/now", test_rain_now);
  g_test_add_func("/window/rain/soon", test_rain_soon);
  g_test_add_func("/window/rain/later", test_rain_later);
  g_test_add_func("/window/rain/rows-follow-item-clock", test_rows_follow_the_item_clock);
  g_test_add_func("/window/units/toggle-and-persistence", test_units_toggle_and_persistence);
  g_test_add_func("/window/units/from-settings", test_units_from_settings_at_start);
  g_test_add_func("/window/places/selection-default-and-persist", test_selection_defaults_and_persists);
  g_test_add_func("/window/places/selection-of-vanished-place", test_selection_of_a_vanished_place_is_ignored);
  g_test_add_func("/window/places/remove-selects-neighbour", test_remove_place_selects_a_neighbour);
  g_test_add_func("/window/places/move-up-down", test_move_up_and_down);
  g_test_add_func("/window/places/reorder-by-drop", test_reorder_by_drop_and_hostile_payloads);
  g_test_add_func("/window/places/changed-elsewhere", test_places_changed_elsewhere_is_reflected);
  g_test_add_func("/window/places/fifty", test_fifty_places);
  g_test_add_func("/window/sources/status-and-toggle", test_sources_page_status_and_toggle);
  g_test_add_func("/window/sources/attribution-and-failed-status", test_sources_attribution_and_failed_status);
  g_test_add_func("/window/sources/about-dialog", test_about_dialog_from_the_sources_page);
  g_test_add_func("/window/sources/menu-button-popover", test_menu_button_opens_the_sources_popover);
  g_test_add_func("/window/lifecycle/close-with-refresh-in-flight",
                  test_close_window_with_a_refresh_in_flight);
  g_test_add_func("/window/lifecycle/shutdown-saves", test_shutdown_saves_everything_within_the_limit);
  g_test_add_func("/window/lifecycle/window-dispose", test_window_dispose_is_safe);
  g_test_add_func("/window/files/corrupt-files", test_corrupt_files_start_empty_with_one_warning_each);
  g_test_add_func("/window/files/invalid-places-dropped", test_some_invalid_places_are_dropped_with_one_warning);
  g_test_add_func("/window/keyboard/accelerators-and-actions", test_keyboard_accelerators_and_actions);
  g_test_add_func("/window/binary/sigterm", test_binary_quits_cleanly_on_sigterm);
  g_test_add_func("/window/binary/sigint", test_binary_quits_cleanly_on_sigint);
  g_test_add_func("/window/clock/tick-and-stop", test_clock_ticks_while_visible_only);
  g_test_add_func("/window/clock/stops-while-offline", test_clock_stops_while_offline);
  g_test_add_func("/window/clock/periodic-round", test_periodic_round_after_ten_minutes);
  g_test_add_func("/window/app/properties", test_app_properties);
  g_test_add_func("/window/app/activate-twice", test_activate_twice_presents_the_same_window);
  g_test_add_func("/window/app/selection-dropped-when-place-removed", test_selection_dropped_when_place_removed);
  g_test_add_func("/window/app/shutdown-while-loading", test_shutdown_while_loading);
  g_test_add_func("/window/app/save-failures-are-logged", test_save_failures_are_logged);
  g_test_add_func("/window/app/edits-while-saving", test_edits_while_saving);
  g_test_add_func("/window/app/disposed-while-saving", test_app_disposed_while_saving);
  g_test_add_func("/window/app/disposed-with-request-in-flight", test_app_disposed_with_request_in_flight);
  g_test_add_func("/window/app/unref-with-cancelled-requests-pending",
                  test_app_unref_with_cancelled_requests_pending);
  g_test_add_func("/window/window/suggestion-refused-when-saved", test_suggestion_refused_when_saved);
  g_test_add_func("/window/window/hostile-move-request", test_hostile_move_request);
  g_test_add_func("/window/window/dispose-while-mapped", test_dispose_while_mapped);
  g_test_add_func("/window/app/shutdown-stops-waiting-at-the-limit",
                  test_shutdown_stops_waiting_at_the_limit);
  g_test_add_func("/window/window/surface-state-notification",
                  test_surface_state_notification_rereads_visibility);
  g_test_add_func("/window/row/no-rain-data", test_row_without_outlook);
  g_test_add_func("/window/row/menu-and-drag-and-drop", test_row_menu_and_dnd);
  g_test_add_func("/window/style/every-class-reaches-a-widget", test_every_style_class_reaches_a_widget);
  return g_test_run();
}
