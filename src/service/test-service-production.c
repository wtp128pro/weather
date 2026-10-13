/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline test of the PRODUCTION flavour of the forecast service (the library the application
 * links: no deadline hook): providers that never answer cost the refresh exactly
 * WX_SERVICE_DEADLINE_MS (30 s of wall time, which is why this is a test of its own) whatever they
 * do with the cancellation the service sends them at the deadline (one honours it, one ignores it
 * and only answers when the test releases it), a provider that answers is blended, and a search
 * runs. All the other behaviour is tested with a short deadline in test-service.c.
 */
#include <glib.h>
#include <glib/gstdio.h>
#include <stdlib.h>

#include "wx-fake-provider.h"
#include "wx-registry.h"
#include "wx-service.h"
#include "wx-types.h"

#define HOUR_S 3600

static char *test_root;

static void
rm_rf(const char *path)
{
  if (g_file_test(path, G_FILE_TEST_IS_DIR) && !g_file_test(path, G_FILE_TEST_IS_SYMLINK)) {
    GDir *dir = g_dir_open(path, 0, NULL);
    if (dir != NULL) {
      const char *name;
      while ((name = g_dir_read_name(dir)) != NULL) {
        g_autofree char *child = g_build_filename(path, name, NULL);
        rm_rf(child);
      }
      g_dir_close(dir);
    }
  }
  g_remove(path);
}

static void
cleanup_root(void)
{
  if (test_root != NULL)
    rm_rf(test_root);
  g_free(test_root);
  test_root = NULL;
}

/* Points every XDG directory into a fresh temporary root; aborts when that fails. */
static void
isolate_environment(void)
{
  GError *error = NULL;
  test_root = g_dir_make_tmp("wx-service-prod-XXXXXX", &error);
  if (test_root == NULL) {
    g_printerr("cannot create the test directory: %s\n", error->message);
    abort();
  }
  const char *vars[] = {"XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                        "XDG_RUNTIME_DIR"};
  for (guint i = 0; i < G_N_ELEMENTS(vars); i++) {
    g_autofree char *dir = g_build_filename(test_root, vars[i], NULL);
    if (g_mkdir_with_parents(dir, 0700) != 0 || !g_setenv(vars[i], dir, TRUE)) {
      g_printerr("cannot set up %s\n", vars[i]);
      abort();
    }
  }
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  atexit(cleanup_root);
}

static WxPlace *
make_place(void)
{
  WxPlace *place = wx_place_new("Miami", "Florida", "United States", "US", 25.7617, -80.1918,
                                "America/New_York", NULL);
  g_assert_nonnull(place);
  return place;
}

/* ------------------------------------------------------------------------ */
/* MuteProvider: never answers and ignores its cancellable                  */
/* ------------------------------------------------------------------------ */

#define MUTE_TYPE_PROVIDER (mute_provider_get_type())
G_DECLARE_FINAL_TYPE(MuteProvider, mute_provider, MUTE, PROVIDER, GObject)

struct _MuteProvider {
  GObject parent_instance;
  GPtrArray *held;    /* GTask*, owned: the fetches that have not been answered */
  GCancellable *seen; /* a reference to the cancellable of the last fetch, never looked at by it */
};

static void mute_provider_provider_init(WxProviderInterface *iface);
G_DEFINE_TYPE_WITH_CODE(MuteProvider, mute_provider, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, mute_provider_provider_init))

/* Addresses only (never read): the source tag of the held tasks. */
static char mute_tag;

static void
mute_provider_finalize(GObject *object)
{
  MuteProvider *self = MUTE_PROVIDER(object);
  g_ptr_array_unref(self->held);
  g_clear_object(&self->seen);
  G_OBJECT_CLASS(mute_provider_parent_class)->finalize(object);
}

static void
mute_provider_init(MuteProvider *self)
{
  self->held = g_ptr_array_new_with_free_func(g_object_unref);
}

static void
mute_provider_class_init(MuteProviderClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = mute_provider_finalize;
}

static const char *
mute_get_id(WxProvider *provider)
{
  (void)provider;
  return "mute-silent";
}

static const char *
mute_get_name(WxProvider *provider)
{
  (void)provider;
  return "Mute";
}

static const char *
mute_get_attribution(WxProvider *provider)
{
  (void)provider;
  return "Mute data";
}

static const char *
mute_get_url(WxProvider *provider)
{
  (void)provider;
  return "https://example.invalid/";
}

static gboolean
mute_covers(WxProvider *provider, const WxPlace *place)
{
  (void)provider;
  (void)place;
  return TRUE;
}

/* Keeps the operation: the cancellable is remembered but never connected to the task. */
static void
mute_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
                 GAsyncReadyCallback callback, gpointer user_data)
{
  (void)place;
  MuteProvider *self = MUTE_PROVIDER(provider);
  g_set_object(&self->seen, cancellable);
  GTask *task = g_task_new(self, NULL, callback, user_data);
  g_task_set_source_tag(task, &mute_tag);
  g_ptr_array_add(self->held, task);
}

static WxSourceResult *
mute_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_assert_true(g_task_is_valid(result, provider));
  g_assert_true(g_task_get_source_tag(G_TASK(result)) == &mute_tag);
  return g_task_propagate_pointer(G_TASK(result), error);
}

static void
mute_provider_provider_init(WxProviderInterface *iface)
{
  iface->get_id = mute_get_id;
  iface->get_name = mute_get_name;
  iface->get_attribution = mute_get_attribution;
  iface->get_attribution_url = mute_get_url;
  iface->covers = mute_covers;
  iface->fetch_async = mute_fetch_async;
  iface->fetch_finish = mute_fetch_finish;
}

/* Answers every held fetch (late, with an error) and forgets it. */
static void
mute_provider_release(MuteProvider *self)
{
  GPtrArray *held = self->held;
  self->held = g_ptr_array_new_with_free_func(g_object_unref);
  for (guint i = 0; i < held->len; i++)
    g_task_return_new_error(g_ptr_array_index(held, i), WX_ERROR, WX_ERROR_NETWORK,
                            "late answer");
  g_ptr_array_unref(held);
}

static WxMember *
make_member(const char *source, double temp_c)
{
  gint64 now_s = g_get_real_time() / G_USEC_PER_SEC;
  WxMember *member = wx_member_new(source, "m", now_s, NULL);
  g_assert_nonnull(member);
  for (gint i = 0; i < 48; i++) {
    WxHour hour;
    wx_hour_init(&hour);
    hour.t_s = now_s / HOUR_S * HOUR_S - HOUR_S + (gint64)i * HOUR_S;
    hour.temp_c = temp_c;
    hour.feels_c = temp_c;
    hour.humidity_pct = 50.0;
    hour.wind_kmh = 10.0;
    hour.cloud_pct = 40.0;
    hour.precip_mm = 0.0;
    hour.precip_prob = 10.0;
    g_assert_true(wx_member_add_hour(member, &hour));
  }
  return member;
}

typedef struct {
  guint calls;
  WxForecast *forecast;
  GError *error;
  gint64 done_us;
} Outcome;

static void
on_refresh_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->calls++;
  o->forecast = wx_service_refresh_finish(WX_SERVICE(source), result, &o->error);
  o->done_us = g_get_monotonic_time();
}

static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  GPtrArray **hits = user_data;
  g_autoptr(GError) error = NULL;
  *hits = wx_service_search_finish(WX_SERVICE(source), result, &error);
  g_assert_no_error(error);
}

static void
test_constant(void)
{
  g_assert_cmpuint(WX_SERVICE_DEADLINE_MS, ==, 30000);
}

/*
 * One provider answers at once and two never do: a fake whose answer is a very long delay (it
 * honours the cancellation the service sends at the deadline) and a MuteProvider (it ignores it
 * and only answers when the test releases it). The refresh completes at the real 30 s deadline
 * with the answering provider's forecast; both silent providers are reported as timeouts, the
 * service has cancelled both fetches through its private cancellable, and the mute provider's
 * late answer is harmless and leaves no reference behind.
 */
static void
test_real_deadline_partial(void)
{
  MuteProvider *mute = g_object_new(MUTE_TYPE_PROVIDER, NULL);
  gpointer mute_weak = mute;
  g_object_add_weak_pointer(G_OBJECT(mute), &mute_weak);
  {
    g_autoptr(WxRegistry) registry = wx_registry_new();
    g_autoptr(WxFakeProvider) good = wx_fake_provider_new("fake-good");
    g_autoptr(WxFakeProvider) silent = wx_fake_provider_new("fake-silent");
    g_autoptr(WxMember) member = make_member("fake-good", 20.0);
    wx_fake_provider_add_member(good, member);
    wx_fake_provider_set_delay_ms(silent, G_MAXUINT); /* about 49 days: never, within the test */
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(good), NULL));
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(silent), NULL));
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(mute), NULL));
    g_autoptr(WxService) service = wx_service_new(registry);
    g_autoptr(WxPlace) place = make_place();

    Outcome o = {0};
    gint64 start_us = g_get_monotonic_time();
    wx_service_refresh_async(service, place, NULL, on_refresh_done, &o);
    while (o.calls == 0)
      g_main_context_iteration(NULL, TRUE);
    gint64 elapsed_ms = (o.done_us - start_us) / 1000;

    g_assert_no_error(o.error);
    g_assert_nonnull(o.forecast);
    g_assert_cmpint(elapsed_ms, >=, WX_SERVICE_DEADLINE_MS);
    g_assert_cmpint(elapsed_ms, <, WX_SERVICE_DEADLINE_MS + 3000);
    guint n = 0;
    const WxSourceStatus *sources = wx_forecast_get_sources(o.forecast, &n);
    g_assert_cmpuint(n, ==, 3);
    g_assert_cmpstr(sources[0].provider_id, ==, "fake-good");
    g_assert_cmpint(sources[0].state, ==, WX_SRC_OK);
    g_assert_cmpuint(sources[0].n_members, ==, 1);
    g_assert_cmpstr(sources[1].provider_id, ==, "fake-silent");
    g_assert_cmpint(sources[1].state, ==, WX_SRC_FAILED);
    g_assert_cmpint(sources[1].error_code, ==, WX_ERROR_TIMEOUT);
    g_assert_cmpuint(wx_fake_provider_get_fetch_count(silent), ==, 1);
    g_assert_cmpstr(sources[2].provider_id, ==, "mute-silent");
    g_assert_cmpint(sources[2].state, ==, WX_SRC_FAILED);
    g_assert_cmpint(sources[2].error_code, ==, WX_ERROR_TIMEOUT);
    g_assert_cmpuint(sources[2].n_members, ==, 0);
    g_assert_cmpuint(mute->held->len, ==, 1); /* it never answered ... */
    g_assert_nonnull(mute->seen);
    g_assert_true(g_cancellable_is_cancelled(mute->seen)); /* ... though it was told to stop */
    wx_forecast_unref(o.forecast);

    /* the ignoring provider answers late: released, never used, nothing is left behind */
    mute_provider_release(mute);
    while (g_main_context_iteration(NULL, FALSE))
      ;
    g_assert_cmpuint(o.calls, ==, 1);
  }
  g_assert_nonnull(mute_weak); /* the test's own reference */
  g_object_unref(mute);
  g_assert_null(mute_weak); /* no task, operation or service still holds the provider */
}

/* The production flavour answers quickly when every provider does, and finds places. */
static void
test_production_smoke(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxFakeProvider) a = wx_fake_provider_new("fake-a");
  g_autoptr(WxFakeProvider) b = wx_fake_provider_new("fake-b");
  g_autoptr(WxMember) ma = make_member("fake-a", 10.0);
  g_autoptr(WxMember) mb = make_member("fake-b", 30.0);
  wx_fake_provider_add_member(a, ma);
  wx_fake_provider_add_member(b, mb);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(a), NULL));
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(b), NULL));
  g_autoptr(WxFakeGeocoder) geocoder = wx_fake_geocoder_new();
  g_autoptr(WxPlace) place = make_place();
  wx_fake_geocoder_add_hit(geocoder, place);
  wx_registry_set_geocoder(registry, WX_GEOCODER(geocoder));
  g_autoptr(WxService) service = wx_service_new(registry);

  Outcome o = {0};
  gint64 start_us = g_get_monotonic_time();
  wx_service_refresh_async(service, place, NULL, on_refresh_done, &o);
  while (o.calls == 0)
    g_main_context_iteration(NULL, TRUE);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.forecast);
  g_assert_cmpint((o.done_us - start_us) / 1000, <, 5000);
  guint n = 0;
  const WxSourceStatus *sources = wx_forecast_get_sources(o.forecast, &n);
  g_assert_cmpuint(n, ==, 2);
  g_assert_cmpint(sources[0].state, ==, WX_SRC_OK);
  g_assert_cmpint(sources[1].state, ==, WX_SRC_OK);
  wx_forecast_unref(o.forecast);

  GPtrArray *hits = NULL;
  wx_service_search_async(service, "Miami", NULL, on_search_done, &hits);
  while (hits == NULL)
    g_main_context_iteration(NULL, TRUE);
  g_assert_cmpuint(hits->len, ==, 1);
  g_ptr_array_unref(hits);
}

int
main(int argc, char **argv)
{
  isolate_environment();
  g_test_init(&argc, &argv, NULL);
  g_test_add_func("/service-production/constant", test_constant);
  g_test_add_func("/service-production/smoke", test_production_smoke);
  g_test_add_func("/service-production/real-deadline", test_real_deadline_partial);
  return g_test_run();
}
