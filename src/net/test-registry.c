/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of the WxProvider / WxGeocoder interfaces, the WxRegistry and
 * the test-only fakes (wx-fake-provider.h) that later modules reuse.
 */
#include <glib.h>
#include <string.h>

#include "wx-fake-provider.h"
#include "wx-registry.h"
#include "wx-types.h"

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

static WxPlace *
make_place(const char *name, double lat, double lon)
{
  WxPlace *place = wx_place_new(name, "Florida", "United States", "US", lat, lon, "America/New_York", NULL);
  g_assert_nonnull(place);
  return place;
}

static WxMember *
make_member(const char *source, const char *model)
{
  WxMember *member = wx_member_new(source, model, 1791676800, NULL);
  g_assert_nonnull(member);
  WxHour hour;
  wx_hour_init(&hour);
  hour.t_s = 1791676800;
  hour.temp_c = 25.0;
  g_assert_true(wx_member_add_hour(member, &hour));
  return member;
}

typedef struct {
  gboolean done;
  WxSourceResult *result;
  GPtrArray *hits;
  GError *error;
  gint64 finished_us;
} Outcome;

static void
outcome_clear(Outcome *o)
{
  g_clear_pointer(&o->result, wx_source_result_free);
  g_clear_pointer(&o->hits, g_ptr_array_unref);
  g_clear_error(&o->error);
  o->done = FALSE;
}

static void
on_fetch_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->result = wx_provider_fetch_finish(WX_PROVIDER(source), result, &o->error);
  o->finished_us = g_get_monotonic_time();
  o->done = TRUE;
}

static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->hits = wx_geocoder_search_finish(WX_GEOCODER(source), result, &o->error);
  o->finished_us = g_get_monotonic_time();
  o->done = TRUE;
}

static void
wait_for(Outcome *o)
{
  while (!o->done)
    g_main_context_iteration(NULL, TRUE);
}

static gboolean
cancel_later(gpointer user_data)
{
  g_cancellable_cancel(G_CANCELLABLE(user_data));
  return G_SOURCE_REMOVE;
}

/* Counts "changed" emissions. */
static void
on_changed(WxRegistry *registry, gpointer user_data)
{
  (void)registry;
  (*(guint *)user_data)++;
}

/* A provider that implements nothing: every dispatcher must refuse it. */
#define TEST_TYPE_BARE (test_bare_get_type())
G_DECLARE_FINAL_TYPE(TestBare, test_bare, TEST, BARE, GObject)
struct _TestBare {
  GObject parent_instance;
};
static void test_bare_provider_init(WxProviderInterface *iface);
static void test_bare_geocoder_init(WxGeocoderInterface *iface);
G_DEFINE_TYPE_WITH_CODE(TestBare, test_bare, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, test_bare_provider_init)
                            G_IMPLEMENT_INTERFACE(WX_TYPE_GEOCODER, test_bare_geocoder_init))
static void
test_bare_init(TestBare *self)
{
  (void)self;
}
static void
test_bare_class_init(TestBareClass *klass)
{
  (void)klass;
}
static void
test_bare_provider_init(WxProviderInterface *iface)
{
  (void)iface; /* every virtual function stays NULL */
}
static void
test_bare_geocoder_init(WxGeocoderInterface *iface)
{
  (void)iface;
}

/*
 * A hand-written provider with a settable id and a covers() that can register
 * another provider while the registry is walking its list.
 */
#define TEST_TYPE_PROV (test_prov_get_type())
G_DECLARE_FINAL_TYPE(TestProv, test_prov, TEST, PROV, GObject)
struct _TestProv {
  GObject parent_instance;
  char *id;
  WxRegistry *registry; /* borrowed */
  WxProvider *to_add;   /* owned, registered once by covers() */
  guint covers_calls;
};
static void test_prov_provider_init(WxProviderInterface *iface);
G_DEFINE_TYPE_WITH_CODE(TestProv, test_prov, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, test_prov_provider_init))
static const char *
test_prov_get_id(WxProvider *provider)
{
  return TEST_PROV(provider)->id;
}
static const char *
test_prov_get_text(WxProvider *provider)
{
  (void)provider;
  return "text";
}
static gboolean
test_prov_covers(WxProvider *provider, const WxPlace *place)
{
  (void)place;
  TestProv *self = TEST_PROV(provider);
  self->covers_calls++;
  if (self->to_add != NULL) {
    g_autoptr(GError) error = NULL;
    g_assert_true(wx_registry_add_provider(self->registry, self->to_add, &error));
    g_assert_no_error(error);
    g_clear_object(&self->to_add);
  }
  return TRUE;
}
static void
test_prov_finalize(GObject *object)
{
  TestProv *self = TEST_PROV(object);
  g_free(self->id);
  g_clear_object(&self->to_add);
  G_OBJECT_CLASS(test_prov_parent_class)->finalize(object);
}
static void
test_prov_init(TestProv *self)
{
  (void)self;
}
static void
test_prov_class_init(TestProvClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = test_prov_finalize;
}
static void
test_prov_provider_init(WxProviderInterface *iface)
{
  iface->get_id = test_prov_get_id;
  iface->get_name = test_prov_get_text;
  iface->get_attribution = test_prov_get_text;
  iface->get_attribution_url = test_prov_get_text;
  iface->covers = test_prov_covers;
}
static TestProv *
test_prov_new(const char *id)
{
  TestProv *self = g_object_new(TEST_TYPE_PROV, NULL);
  self->id = g_strdup(id);
  return self;
}

/* ------------------------------------------------------------------------ */
/* Interface dispatch                                                       */
/* ------------------------------------------------------------------------ */

static void
test_interfaces_dispatch(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("open-meteo");
  WxProvider *provider = WX_PROVIDER(fake);
  g_assert_true(WX_IS_PROVIDER(provider));
  g_assert_false(WX_IS_GEOCODER(provider));
  g_assert_cmpstr(wx_provider_get_id(provider), ==, "open-meteo");
  g_assert_cmpstr(wx_provider_get_name(provider), ==, "Fake open-meteo");
  g_assert_cmpstr(wx_provider_get_attribution(provider), ==, "Fake data (open-meteo)");
  g_assert_cmpstr(wx_provider_get_attribution_url(provider), ==, "https://example.invalid/");
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_assert_true(wx_provider_covers(provider, place));
  wx_fake_provider_set_covers(fake, FALSE);
  g_assert_false(wx_provider_covers(provider, place));

  /* An implementation without virtual functions is refused by every dispatcher. */
  g_autoptr(TestBare) bare = g_object_new(TEST_TYPE_BARE, NULL);
  WxProvider *bp = WX_PROVIDER(bare);
  WxGeocoder *bg = WX_GEOCODER(bare);
  ASSERT_CRITICAL("wx_provider_get_id", g_assert_null(wx_provider_get_id(bp)));
  ASSERT_CRITICAL("wx_provider_get_name", g_assert_null(wx_provider_get_name(bp)));
  ASSERT_CRITICAL("wx_provider_get_attribution", g_assert_null(wx_provider_get_attribution(bp)));
  ASSERT_CRITICAL("wx_provider_get_attribution_url", g_assert_null(wx_provider_get_attribution_url(bp)));
  ASSERT_CRITICAL("wx_provider_covers", g_assert_false(wx_provider_covers(bp, place)));
  ASSERT_CRITICAL("wx_provider_fetch_async", wx_provider_fetch_async(bp, place, NULL, NULL, NULL));
  ASSERT_CRITICAL("wx_geocoder_search_async", wx_geocoder_search_async(bg, "Miami", NULL, NULL, NULL));
  g_autoptr(GTask) task = g_task_new(bare, NULL, NULL, NULL);
  ASSERT_CRITICAL("wx_provider_fetch_finish", g_assert_null(wx_provider_fetch_finish(bp, G_ASYNC_RESULT(task), NULL)));
  ASSERT_CRITICAL("wx_geocoder_search_finish", g_assert_null(wx_geocoder_search_finish(bg, G_ASYNC_RESULT(task), NULL)));

  /* Invalid receivers and arguments. */
  ASSERT_CRITICAL("wx_provider_get_id", g_assert_null(wx_provider_get_id(NULL)));
  ASSERT_CRITICAL("wx_provider_get_name", g_assert_null(wx_provider_get_name(NULL)));
  ASSERT_CRITICAL("wx_provider_get_attribution", g_assert_null(wx_provider_get_attribution(NULL)));
  ASSERT_CRITICAL("wx_provider_get_attribution_url", g_assert_null(wx_provider_get_attribution_url(NULL)));
  ASSERT_CRITICAL("wx_provider_covers", g_assert_false(wx_provider_covers(NULL, place)));
  ASSERT_CRITICAL("wx_provider_covers", g_assert_false(wx_provider_covers(provider, NULL)));
  ASSERT_CRITICAL("wx_provider_fetch_async", wx_provider_fetch_async(NULL, place, NULL, NULL, NULL));
  ASSERT_CRITICAL("wx_provider_fetch_async", wx_provider_fetch_async(provider, NULL, NULL, NULL, NULL));
  ASSERT_CRITICAL("wx_provider_fetch_async",
                  wx_provider_fetch_async(provider, place, (GCancellable *)fake, NULL, NULL));
  ASSERT_CRITICAL("wx_provider_fetch_finish", g_assert_null(wx_provider_fetch_finish(NULL, G_ASYNC_RESULT(task), NULL)));
  ASSERT_CRITICAL("wx_provider_fetch_finish", g_assert_null(wx_provider_fetch_finish(provider, NULL, NULL)));
  ASSERT_CRITICAL("wx_geocoder_search_async", wx_geocoder_search_async(NULL, "x", NULL, NULL, NULL));
  g_autoptr(WxFakeGeocoder) geocoder = wx_fake_geocoder_new();
  ASSERT_CRITICAL("wx_geocoder_search_async", wx_geocoder_search_async(WX_GEOCODER(geocoder), NULL, NULL, NULL, NULL));
  ASSERT_CRITICAL("wx_geocoder_search_async",
                  wx_geocoder_search_async(WX_GEOCODER(geocoder), "x", (GCancellable *)fake, NULL, NULL));
  ASSERT_CRITICAL("wx_geocoder_search_finish", g_assert_null(wx_geocoder_search_finish(NULL, G_ASYNC_RESULT(task), NULL)));
  ASSERT_CRITICAL("wx_geocoder_search_finish",
                  g_assert_null(wx_geocoder_search_finish(WX_GEOCODER(geocoder), NULL, NULL)));
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fake), ==, 0);
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geocoder), ==, 0);
}

/* ------------------------------------------------------------------------ */
/* Fake provider / geocoder                                                 */
/* ------------------------------------------------------------------------ */

static void
test_fake_provider_fetch(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("nws");
  WxProvider *provider = WX_PROVIDER(fake);
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxMember) m1 = make_member("nws", "gridpoint");
  g_autoptr(WxMember) m2 = make_member("nws", "second");
  wx_fake_provider_add_member(fake, m1);
  wx_fake_provider_add_member(fake, m2);

  Outcome o = {0};
  wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
  g_assert_false(o.done); /* never before the call returns */
  wait_for(&o);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.result);
  g_assert_cmpstr(o.result->provider_id, ==, "nws");
  g_assert_cmpuint(o.result->members->len, ==, 2);
  g_assert_true(g_ptr_array_index(o.result->members, 0) == m1); /* shared, in order */
  g_assert_true(g_ptr_array_index(o.result->members, 1) == m2);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(fake), ==, 1);
  outcome_clear(&o);

  /* The result does not alias provider state: members were ref'ed. */
  wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_cmpuint(o.result->members->len, ==, 2);
  outcome_clear(&o);

  /* Not covered. */
  wx_fake_provider_set_covers(fake, FALSE);
  wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
  g_assert_false(o.done);
  wait_for(&o);
  g_assert_null(o.result);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_UNSUPPORTED);
  outcome_clear(&o);
  wx_fake_provider_set_covers(fake, TRUE);

  /* Invalid place (hand-built, hostile). */
  WxPlace bad = *place;
  bad.name = (char *)"";
  wx_provider_fetch_async(provider, &bad, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&o);

  /* Scripted failures: every code, then back to success. */
  for (int code = 0; code <= WX_ERROR_UNSUPPORTED; code++) {
    wx_fake_provider_fail_with(fake, code);
    wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
    wait_for(&o);
    g_assert_null(o.result);
    g_assert_error(o.error, WX_ERROR, code);
    outcome_clear(&o);
  }
  wx_fake_provider_fail_with(fake, -1);
  wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  ASSERT_CRITICAL("wx_fake_provider_fail_with", wx_fake_provider_fail_with(fake, -2));
  ASSERT_CRITICAL("wx_fake_provider_fail_with", wx_fake_provider_fail_with(fake, WX_ERROR_UNSUPPORTED + 1));

  /* An invalid provider id cannot build a result. */
  g_autoptr(WxFakeProvider) odd = wx_fake_provider_new("Not Valid!");
  wx_provider_fetch_async(WX_PROVIDER(odd), place, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&o);
}

static void
test_fake_provider_delay_and_cancel(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("slow");
  WxProvider *provider = WX_PROVIDER(fake);
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxMember) member = make_member("slow", "m");
  wx_fake_provider_add_member(fake, member);

  /* A delay. */
  wx_fake_provider_set_delay_ms(fake, 120);
  Outcome o = {0};
  gint64 start = g_get_monotonic_time();
  wx_provider_fetch_async(provider, place, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  g_assert_cmpint((o.finished_us - start) / 1000, >=, 110);
  outcome_clear(&o);

  /* A delay with a cancellable that stays quiet. */
  g_autoptr(GCancellable) quiet = g_cancellable_new();
  wx_provider_fetch_async(provider, place, quiet, on_fetch_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);

  /* Cancelled while waiting (the delivery is a success that is dropped). */
  wx_fake_provider_set_delay_ms(fake, 60000);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  start = g_get_monotonic_time();
  wx_provider_fetch_async(provider, place, cancellable, on_fetch_done, &o);
  g_timeout_add(80, cancel_later, cancellable);
  wait_for(&o);
  g_assert_null(o.result);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpint((o.finished_us - start) / 1000, <, 5000);
  outcome_clear(&o);

  /* Cancelled while waiting for a scripted failure. */
  wx_fake_provider_fail_with(fake, WX_ERROR_NETWORK);
  g_autoptr(GCancellable) c2 = g_cancellable_new();
  wx_provider_fetch_async(provider, place, c2, on_fetch_done, &o);
  g_timeout_add(50, cancel_later, c2);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);

  /* Pre-cancelled. */
  g_autoptr(GCancellable) pre = g_cancellable_new();
  g_cancellable_cancel(pre);
  wx_provider_fetch_async(provider, place, pre, on_fetch_done, &o);
  g_assert_false(o.done);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);

  /* Cancel after completion but before finish wins (GTask semantics the contract promises). */
  wx_fake_provider_set_delay_ms(fake, 0);
  wx_fake_provider_fail_with(fake, -1);
  g_autoptr(GCancellable) late = g_cancellable_new();
  wx_provider_fetch_async(provider, place, late, on_fetch_done, &o);
  g_cancellable_cancel(late);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);
}

static void
on_weak_notify(gpointer data, GObject *where_the_object_was)
{
  (void)where_the_object_was;
  *(gboolean *)data = TRUE;
}

static void
test_fake_provider_dropped_in_flight(void)
{
  WxFakeProvider *fake = wx_fake_provider_new("drop");
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  wx_fake_provider_set_delay_ms(fake, 60);
  Outcome o = {0};
  wx_provider_fetch_async(WX_PROVIDER(fake), place, NULL, on_fetch_done, &o);
  gboolean finalized = FALSE;
  g_object_weak_ref(G_OBJECT(fake), on_weak_notify, &finalized);
  g_object_unref(fake);
  g_assert_false(finalized); /* the operation holds it */
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  while (!finalized)
    g_main_context_iteration(NULL, TRUE);

  /* The same for the geocoder. */
  WxFakeGeocoder *geocoder = wx_fake_geocoder_new();
  wx_fake_geocoder_set_delay_ms(geocoder, 60);
  wx_geocoder_search_async(WX_GEOCODER(geocoder), "Miami", NULL, on_search_done, &o);
  finalized = FALSE;
  g_object_weak_ref(G_OBJECT(geocoder), on_weak_notify, &finalized);
  g_object_unref(geocoder);
  g_assert_false(finalized);
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  while (!finalized)
    g_main_context_iteration(NULL, TRUE);
}

static void
test_fake_provider_programmer_errors(void)
{
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("x");
  g_autoptr(WxFakeGeocoder) geocoder = wx_fake_geocoder_new();
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  ASSERT_CRITICAL("wx_fake_provider_new", g_assert_null(wx_fake_provider_new(NULL)));
  ASSERT_CRITICAL("wx_fake_provider_set_covers", wx_fake_provider_set_covers(NULL, TRUE));
  ASSERT_CRITICAL("wx_fake_provider_add_member", wx_fake_provider_add_member(NULL, NULL));
  ASSERT_CRITICAL("wx_fake_provider_add_member", wx_fake_provider_add_member(fake, NULL));
  ASSERT_CRITICAL("wx_fake_provider_fail_with", wx_fake_provider_fail_with(NULL, -1));
  ASSERT_CRITICAL("wx_fake_provider_set_delay_ms", wx_fake_provider_set_delay_ms(NULL, 1));
  ASSERT_CRITICAL("wx_fake_provider_get_fetch_count", g_assert_cmpuint(wx_fake_provider_get_fetch_count(NULL), ==, 0));
  ASSERT_CRITICAL("wx_fake_geocoder_add_hit", wx_fake_geocoder_add_hit(NULL, place));
  ASSERT_CRITICAL("wx_fake_geocoder_add_hit", wx_fake_geocoder_add_hit(geocoder, NULL));
  WxPlace bad = *place;
  bad.name = (char *)"";
  ASSERT_CRITICAL("wx_fake_geocoder_add_hit", wx_fake_geocoder_add_hit(geocoder, &bad));
  ASSERT_CRITICAL("wx_fake_geocoder_fail_with", wx_fake_geocoder_fail_with(NULL, -1));
  ASSERT_CRITICAL("wx_fake_geocoder_fail_with", wx_fake_geocoder_fail_with(geocoder, 99));
  ASSERT_CRITICAL("wx_fake_geocoder_set_delay_ms", wx_fake_geocoder_set_delay_ms(NULL, 1));
  ASSERT_CRITICAL("wx_fake_geocoder_get_search_count",
                  g_assert_cmpuint(wx_fake_geocoder_get_search_count(NULL), ==, 0));
}

static void
test_fake_geocoder_search(void)
{
  g_autoptr(WxFakeGeocoder) fake = wx_fake_geocoder_new();
  WxGeocoder *geocoder = WX_GEOCODER(fake);
  g_assert_true(WX_IS_GEOCODER(geocoder));
  g_assert_false(WX_IS_PROVIDER(geocoder));
  g_autoptr(WxPlace) miami = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(WxPlace) oslo = make_place("Oslo", 59.9139, 10.7522);
  wx_fake_geocoder_add_hit(fake, miami);
  wx_fake_geocoder_add_hit(fake, oslo);

  Outcome o = {0};
  wx_geocoder_search_async(geocoder, "Mia", NULL, on_search_done, &o);
  g_assert_false(o.done);
  wait_for(&o);
  g_assert_no_error(o.error);
  g_assert_cmpuint(o.hits->len, ==, 2);
  WxPlace *first = g_ptr_array_index(o.hits, 0);
  g_assert_true(first != miami); /* copies */
  g_assert_cmpstr(first->name, ==, "Miami");
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(o.hits, 1))->name, ==, "Oslo");
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(fake), ==, 1);
  outcome_clear(&o);

  /* Invalid text: reported through the callback. */
  const char *bad_text[] = {"", "   ", "a\x01", "\xff\xfe"};
  for (guint i = 0; i < G_N_ELEMENTS(bad_text); i++) {
    wx_geocoder_search_async(geocoder, bad_text[i], NULL, on_search_done, &o);
    g_assert_false(o.done);
    wait_for(&o);
    g_assert_null(o.hits);
    g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    outcome_clear(&o);
  }
  g_autofree char *long_text = g_strnfill(65, 'a');
  wx_geocoder_search_async(geocoder, long_text, NULL, on_search_done, &o);
  wait_for(&o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&o);

  /* Failure, delay, cancellation. */
  wx_fake_geocoder_fail_with(fake, WX_ERROR_RATE_LIMITED);
  wx_geocoder_search_async(geocoder, "Mia", NULL, on_search_done, &o);
  wait_for(&o);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);
  wx_fake_geocoder_fail_with(fake, -1);
  wx_fake_geocoder_set_delay_ms(fake, 60000);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  wx_geocoder_search_async(geocoder, "Mia", cancellable, on_search_done, &o);
  g_timeout_add(50, cancel_later, cancellable);
  wait_for(&o);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);

  /* The result is capped at WX_GEOCODER_MAX_HITS. */
  wx_fake_geocoder_set_delay_ms(fake, 0);
  for (guint i = 0; i < WX_GEOCODER_MAX_HITS + 5; i++) {
    g_autoptr(WxPlace) extra = make_place("Extra", 10.0 + i, 20.0);
    wx_fake_geocoder_add_hit(fake, extra);
  }
  wx_geocoder_search_async(geocoder, "Mia", NULL, on_search_done, &o);
  wait_for(&o);
  g_assert_cmpuint(o.hits->len, ==, WX_GEOCODER_MAX_HITS);
  outcome_clear(&o);
  g_assert_cmpuint(WX_GEOCODER_MAX_HITS, ==, 20);
}

/* ------------------------------------------------------------------------ */
/* Registry                                                                 */
/* ------------------------------------------------------------------------ */

static void
test_registry_empty(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_assert_true(WX_IS_REGISTRY(registry));
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, 0);
  g_assert_null(wx_registry_find_provider(registry, "nws"));
  g_assert_false(wx_registry_is_enabled(registry, "nws"));
  g_assert_false(wx_registry_set_enabled(registry, "nws", FALSE));
  g_assert_null(wx_registry_get_geocoder(registry));
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(covering->len, ==, 0);
}

static void
test_registry_add_find_order(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  guint changed = 0;
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  g_autoptr(WxFakeProvider) a = wx_fake_provider_new("nws");
  g_autoptr(WxFakeProvider) b = wx_fake_provider_new("open-meteo");
  g_autoptr(WxFakeProvider) c = wx_fake_provider_new("met-no");
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(a), &error));
  g_assert_no_error(error);
  g_assert_cmpuint(changed, ==, 1);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(b), &error));
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(c), &error));
  g_assert_cmpuint(changed, ==, 3);

  /* The registry holds its own reference. */
  g_assert_cmpuint(G_OBJECT(a)->ref_count, ==, 2);

  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, 3);
  g_assert_true(g_ptr_array_index(list, 0) == WX_PROVIDER(a)); /* registration order */
  g_assert_true(g_ptr_array_index(list, 1) == WX_PROVIDER(b));
  g_assert_true(g_ptr_array_index(list, 2) == WX_PROVIDER(c));
  g_assert_true(wx_registry_find_provider(registry, "nws") == WX_PROVIDER(a));
  g_assert_true(wx_registry_find_provider(registry, "open-meteo") == WX_PROVIDER(b));
  g_assert_true(wx_registry_find_provider(registry, "met-no") == WX_PROVIDER(c));
  g_assert_null(wx_registry_find_provider(registry, "NWS"));
  g_assert_null(wx_registry_find_provider(registry, "nws "));
  g_assert_null(wx_registry_find_provider(registry, ""));
  g_assert_true(wx_registry_is_enabled(registry, "nws")); /* new providers are enabled */

  /* The snapshot does not change when more providers are added; elements are borrowed. */
  g_autoptr(WxFakeProvider) d = wx_fake_provider_new("later");
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(d), NULL));
  g_assert_cmpuint(list->len, ==, 3);
  g_autoptr(GPtrArray) list2 = wx_registry_list_providers(registry);
  g_assert_cmpuint(list2->len, ==, 4);
  g_assert_true(g_ptr_array_index(list2, 3) == WX_PROVIDER(d));
  g_assert_cmpuint(changed, ==, 4);
}

static void
test_registry_rejects_bad_and_duplicate_ids(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  guint changed = 0;
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  g_autofree char *id32 = g_strnfill(32, 'a');
  g_autofree char *id33 = g_strnfill(33, 'a');
  const char *bad[] = {"", ".", "..", "a.b", ".a", "-a", "_a", "A", "nWs", "a b", "a/b", "a\\b", "a:b", "../x",
                       "a\n", "caf\xc3\xa9", "a\xff", "a%2e", "a\x01", id33};
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    g_autoptr(WxFakeProvider) p = wx_fake_provider_new(bad[i]);
    g_autoptr(GError) error = NULL;
    g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(p), &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(p), NULL));
    g_assert_cmpuint(G_OBJECT(p)->ref_count, ==, 1); /* nothing was retained */
  }
  g_assert_cmpuint(changed, ==, 0);

  /* Valid boundary ids. */
  const char *good[] = {"a", "0", "9z", "a-b", "a_b", "a-", "a_", "a--b", id32};
  for (guint i = 0; i < G_N_ELEMENTS(good); i++) {
    g_autoptr(WxFakeProvider) p = wx_fake_provider_new(good[i]);
    g_autoptr(GError) error = NULL;
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(p), &error));
    g_assert_no_error(error);
  }
  g_assert_cmpuint(changed, ==, G_N_ELEMENTS(good));

  /* A provider without get_id is a bad provider (data), not a crash. */
  g_autoptr(TestBare) bare = g_object_new(TEST_TYPE_BARE, NULL);
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*wx_provider_get_id*");
  g_autoptr(GError) bare_error = NULL;
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(bare), &bare_error));
  g_test_assert_expected_messages();
  g_assert_error(bare_error, WX_ERROR, WX_ERROR_INVALID_ARG);

  /* Duplicates: another instance with the same id, and the same instance twice. */
  g_autoptr(WxFakeProvider) first = wx_fake_provider_new("dup");
  g_autoptr(WxFakeProvider) second = wx_fake_provider_new("dup");
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(first), NULL));
  guint before = changed;
  g_autoptr(GError) error = NULL;
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(second), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_clear_error(&error);
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(first), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_assert_cmpuint(changed, ==, before);
  g_assert_true(wx_registry_find_provider(registry, "dup") == WX_PROVIDER(first));
  g_assert_cmpuint(G_OBJECT(second)->ref_count, ==, 1);

  /* The id is read once: a later change of the implementation's string is not followed. */
  g_autoptr(TestProv) morph = test_prov_new("one");
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(morph), NULL));
  g_free(morph->id);
  morph->id = g_strdup("two");
  g_assert_true(wx_registry_find_provider(registry, "one") == WX_PROVIDER(morph));
  g_assert_null(wx_registry_find_provider(registry, "two"));
  g_assert_true(wx_registry_is_enabled(registry, "one"));
  g_assert_false(wx_registry_is_enabled(registry, "two"));
  g_assert_true(wx_registry_set_enabled(registry, "one", FALSE));
}

static void
test_registry_cap(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  guint changed = 0;
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  g_assert_cmpuint(WX_REGISTRY_MAX_PROVIDERS, ==, 16);
  for (guint i = 0; i < WX_REGISTRY_MAX_PROVIDERS; i++) {
    g_autofree char *id = g_strdup_printf("p%u", i);
    g_autoptr(WxFakeProvider) p = wx_fake_provider_new(id);
    g_autoptr(GError) error = NULL;
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(p), &error));
    g_assert_no_error(error);
  }
  g_assert_cmpuint(changed, ==, WX_REGISTRY_MAX_PROVIDERS);
  g_autoptr(WxFakeProvider) extra = wx_fake_provider_new("one-too-many");
  g_autoptr(GError) error = NULL;
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(extra), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_assert_cmpuint(changed, ==, WX_REGISTRY_MAX_PROVIDERS);
  g_assert_cmpuint(G_OBJECT(extra)->ref_count, ==, 1);
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, WX_REGISTRY_MAX_PROVIDERS);
  /* A duplicate id is reported as such even when full, and nothing changes. */
  g_autoptr(WxFakeProvider) dup = wx_fake_provider_new("p3");
  g_clear_error(&error);
  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(dup), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
}

static void
test_registry_enable_covering_and_signals(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxFakeProvider) a = wx_fake_provider_new("a");
  g_autoptr(WxFakeProvider) b = wx_fake_provider_new("b");
  g_autoptr(WxFakeProvider) c = wx_fake_provider_new("c");
  wx_fake_provider_set_covers(b, FALSE);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(a), NULL));
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(b), NULL));
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(c), NULL));
  guint changed = 0;
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);

  /* enabled AND covers. */
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(covering->len, ==, 2);
  g_assert_true(g_ptr_array_index(covering, 0) == WX_PROVIDER(a));
  g_assert_true(g_ptr_array_index(covering, 1) == WX_PROVIDER(c));

  /* Disabling changes the flag and emits once; repeating it is silent. */
  g_assert_true(wx_registry_set_enabled(registry, "a", FALSE));
  g_assert_cmpuint(changed, ==, 1);
  g_assert_false(wx_registry_is_enabled(registry, "a"));
  g_assert_true(wx_registry_set_enabled(registry, "a", FALSE)); /* known id: TRUE, but no change */
  g_assert_cmpuint(changed, ==, 1);
  g_autoptr(GPtrArray) covering2 = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(covering2->len, ==, 1);
  g_assert_true(g_ptr_array_index(covering2, 0) == WX_PROVIDER(c));
  /* A disabled provider stays registered and listed. */
  g_autoptr(GPtrArray) all = wx_registry_list_providers(registry);
  g_assert_cmpuint(all->len, ==, 3);
  g_assert_true(wx_registry_find_provider(registry, "a") == WX_PROVIDER(a));

  /* Re-enabling, and any non-zero value means enabled. */
  g_assert_true(wx_registry_set_enabled(registry, "a", 7));
  g_assert_cmpuint(changed, ==, 2);
  g_assert_true(wx_registry_is_enabled(registry, "a"));
  g_assert_true(wx_registry_set_enabled(registry, "a", TRUE));
  g_assert_cmpuint(changed, ==, 2);

  /* Disabled-and-not-covering: both filters apply. */
  g_assert_true(wx_registry_set_enabled(registry, "b", FALSE));
  g_assert_true(wx_registry_set_enabled(registry, "c", FALSE));
  g_assert_cmpuint(changed, ==, 4);
  g_autoptr(GPtrArray) covering3 = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(covering3->len, ==, 1);
  g_assert_true(g_ptr_array_index(covering3, 0) == WX_PROVIDER(a));

  /* Unknown ids: FALSE, no change, no signal; hostile text is only compared. */
  const char *unknown[] = {"zzz", "A", "a ", "", "a\x01", "../a", "\xff"};
  for (guint i = 0; i < G_N_ELEMENTS(unknown); i++) {
    g_assert_false(wx_registry_set_enabled(registry, unknown[i], TRUE));
    g_assert_false(wx_registry_set_enabled(registry, unknown[i], FALSE));
    g_assert_false(wx_registry_is_enabled(registry, unknown[i]));
    g_assert_null(wx_registry_find_provider(registry, unknown[i]));
  }
  g_assert_cmpuint(changed, ==, 4);

  /* The geocoder does not emit "changed". */
  g_autoptr(WxFakeGeocoder) geocoder = wx_fake_geocoder_new();
  wx_registry_set_geocoder(registry, WX_GEOCODER(geocoder));
  g_assert_cmpuint(changed, ==, 4);
}

static void
test_registry_geocoder(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxFakeGeocoder) g1 = wx_fake_geocoder_new();
  g_autoptr(WxFakeGeocoder) g2 = wx_fake_geocoder_new();
  g_assert_null(wx_registry_get_geocoder(registry));
  wx_registry_set_geocoder(registry, WX_GEOCODER(g1));
  g_assert_true(wx_registry_get_geocoder(registry) == WX_GEOCODER(g1));
  g_assert_cmpuint(G_OBJECT(g1)->ref_count, ==, 2); /* the registry holds a reference */
  wx_registry_set_geocoder(registry, WX_GEOCODER(g1));  /* same object again */
  g_assert_cmpuint(G_OBJECT(g1)->ref_count, ==, 2);
  wx_registry_set_geocoder(registry, WX_GEOCODER(g2));
  g_assert_true(wx_registry_get_geocoder(registry) == WX_GEOCODER(g2));
  g_assert_cmpuint(G_OBJECT(g1)->ref_count, ==, 1); /* the old one was released */
  g_assert_cmpuint(G_OBJECT(g2)->ref_count, ==, 2);
  wx_registry_set_geocoder(registry, NULL);
  g_assert_null(wx_registry_get_geocoder(registry));
  g_assert_cmpuint(G_OBJECT(g2)->ref_count, ==, 1);
  wx_registry_set_geocoder(registry, WX_GEOCODER(g1));

  /* The geocoder usable through the registry. */
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  wx_fake_geocoder_add_hit(g1, place);
  Outcome o = {0};
  wx_geocoder_search_async(wx_registry_get_geocoder(registry), "Mia", NULL, on_search_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  g_assert_cmpuint(o.hits->len, ==, 1);
  outcome_clear(&o);

  /* Something that is not a geocoder is refused. */
  g_autoptr(WxFakeProvider) not_a_geocoder = wx_fake_provider_new("x");
  ASSERT_CRITICAL("wx_registry_set_geocoder", wx_registry_set_geocoder(registry, (WxGeocoder *)not_a_geocoder));
  g_assert_true(wx_registry_get_geocoder(registry) == WX_GEOCODER(g1));
}

static void
test_registry_programmer_errors(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(WxFakeProvider) p = wx_fake_provider_new("p");
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_autoptr(GError) preset = g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "x");
  ASSERT_CRITICAL("wx_registry_add_provider", g_assert_false(wx_registry_add_provider(NULL, WX_PROVIDER(p), NULL)));
  ASSERT_CRITICAL("wx_registry_add_provider", g_assert_false(wx_registry_add_provider(registry, NULL, NULL)));
  ASSERT_CRITICAL("wx_registry_add_provider",
                  g_assert_false(wx_registry_add_provider(registry, WX_PROVIDER(p), &preset)));
  ASSERT_CRITICAL("wx_registry_find_provider", g_assert_null(wx_registry_find_provider(NULL, "p")));
  ASSERT_CRITICAL("wx_registry_find_provider", g_assert_null(wx_registry_find_provider(registry, NULL)));
  ASSERT_CRITICAL("wx_registry_list_providers", g_assert_null(wx_registry_list_providers(NULL)));
  ASSERT_CRITICAL("wx_registry_set_enabled", g_assert_false(wx_registry_set_enabled(NULL, "p", TRUE)));
  ASSERT_CRITICAL("wx_registry_set_enabled", g_assert_false(wx_registry_set_enabled(registry, NULL, TRUE)));
  ASSERT_CRITICAL("wx_registry_is_enabled", g_assert_false(wx_registry_is_enabled(NULL, "p")));
  ASSERT_CRITICAL("wx_registry_is_enabled", g_assert_false(wx_registry_is_enabled(registry, NULL)));
  ASSERT_CRITICAL("wx_registry_list_covering", g_assert_null(wx_registry_list_covering(NULL, place)));
  ASSERT_CRITICAL("wx_registry_list_covering", g_assert_null(wx_registry_list_covering(registry, NULL)));
  ASSERT_CRITICAL("wx_registry_set_geocoder", wx_registry_set_geocoder(NULL, NULL));
  ASSERT_CRITICAL("wx_registry_get_geocoder", g_assert_null(wx_registry_get_geocoder(NULL)));
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, 0); /* nothing leaked in */
}

static void
test_registry_covers_may_reenter(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_autoptr(TestProv) adder = test_prov_new("adder");
  adder->registry = registry;
  adder->to_add = WX_PROVIDER(wx_fake_provider_new("added"));
  g_autoptr(WxFakeProvider) other = wx_fake_provider_new("other");
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(adder), NULL));
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(other), NULL));
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  /* covers() of the first provider registers a third one: the walk stays valid and visits it. */
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(adder->covers_calls, ==, 1);
  g_assert_null(adder->to_add);
  g_assert_cmpuint(covering->len, ==, 3);
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(covering, 0)), ==, "adder");
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(covering, 1)), ==, "other");
  g_assert_cmpstr(wx_provider_get_id(g_ptr_array_index(covering, 2)), ==, "added");
  g_assert_nonnull(wx_registry_find_provider(registry, "added"));
}

static void
test_registry_dispose_releases_everything(void)
{
  WxRegistry *registry = wx_registry_new();
  WxFakeProvider *p = wx_fake_provider_new("p");
  WxFakeGeocoder *g = wx_fake_geocoder_new();
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(p), NULL));
  wx_registry_set_geocoder(registry, WX_GEOCODER(g));
  g_assert_cmpuint(G_OBJECT(p)->ref_count, ==, 2);
  g_assert_cmpuint(G_OBJECT(g)->ref_count, ==, 2);
  g_object_unref(registry);
  g_assert_cmpuint(G_OBJECT(p)->ref_count, ==, 1);
  g_assert_cmpuint(G_OBJECT(g)->ref_count, ==, 1);
  g_object_unref(p);
  g_object_unref(g);
}

/* GObject allows method calls until finalize, and the registry documents that the provider and
 * geocoder pointers it hands out stay valid until it is finalized: after g_object_run_dispose()
 * the registry is unchanged (it keeps its references, even the only ones), every function still
 * works and a pointer borrowed earlier is still good. Run under ASan to catch a use after free. */
static void
test_registry_usable_after_dispose(void)
{
  WxRegistry *registry = wx_registry_new();
  guint changed = 0;
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  WxFakeProvider *p = wx_fake_provider_new("p");
  WxFakeGeocoder *g = wx_fake_geocoder_new();
  gboolean p_finalized = FALSE, g_finalized = FALSE;
  g_object_weak_ref(G_OBJECT(p), on_weak_notify, &p_finalized);
  g_object_weak_ref(G_OBJECT(g), on_weak_notify, &g_finalized);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(p), NULL));
  wx_registry_set_geocoder(registry, WX_GEOCODER(g));
  g_object_unref(p); /* the registry now holds the only references */
  g_object_unref(g);
  g_autoptr(WxPlace) place = make_place("Miami", 25.7617, -80.1918);
  g_assert_cmpuint(changed, ==, 1);

  /* Pointers borrowed before the dispose. */
  WxProvider *borrowed = wx_registry_find_provider(registry, "p");
  WxGeocoder *borrowed_geocoder = wx_registry_get_geocoder(registry);
  g_autoptr(GPtrArray) snapshot = wx_registry_list_providers(registry);
  g_assert_nonnull(borrowed);
  g_assert_nonnull(borrowed_geocoder);

  g_object_run_dispose(G_OBJECT(registry));
  g_object_run_dispose(G_OBJECT(registry)); /* a second dispose is harmless too */
  g_assert_false(p_finalized);
  g_assert_false(g_finalized);

  /* The registry is unchanged and the borrowed pointers are valid. */
  g_assert_cmpstr(wx_provider_get_id(borrowed), ==, "p");
  g_assert_cmpuint(snapshot->len, ==, 1);
  g_assert_true(g_ptr_array_index(snapshot, 0) == borrowed);
  g_assert_cmpstr(wx_provider_get_name(g_ptr_array_index(snapshot, 0)), ==, "Fake p");
  g_assert_true(wx_registry_find_provider(registry, "p") == borrowed);
  g_assert_true(wx_registry_get_geocoder(registry) == borrowed_geocoder);
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, 1);
  g_assert_true(wx_registry_is_enabled(registry, "p"));
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, place);
  g_assert_cmpuint(covering->len, ==, 1);
  Outcome o = {0};
  wx_provider_fetch_async(borrowed, place, NULL, on_fetch_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  wx_geocoder_search_async(borrowed_geocoder, "Mia", NULL, on_search_done, &o);
  wait_for(&o);
  g_assert_no_error(o.error);
  outcome_clear(&o);

  /* It keeps working: disable and re-enable, add a provider, replace the geocoder. The dispose
   * disconnected the "changed" handler (GObject does that), so connect a new one. */
  g_signal_connect(registry, "changed", G_CALLBACK(on_changed), &changed);
  g_assert_true(wx_registry_set_enabled(registry, "p", FALSE));
  g_assert_cmpuint(changed, ==, 2);
  g_assert_true(wx_registry_set_enabled(registry, "p", TRUE));
  g_autoptr(WxFakeProvider) q = wx_fake_provider_new("q");
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(q), NULL));
  g_assert_cmpuint(changed, ==, 4);
  wx_registry_set_geocoder(registry, NULL);
  g_assert_null(wx_registry_get_geocoder(registry));
  g_assert_true(g_finalized); /* the registry held the only reference to the old geocoder */

  /* Everything is released at finalize. */
  g_ptr_array_set_size(snapshot, 0);
  g_object_unref(registry);
  g_assert_true(p_finalized);
  g_assert_true(g_finalized);
}

/* A "changed" handler may call back into the registry. */
static void
reenter_handler(WxRegistry *registry, gpointer user_data)
{
  guint *calls = user_data;
  (*calls)++;
  g_assert_true(wx_registry_is_enabled(registry, "x"));
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, >=, 1);
  if (*calls == 1) {
    g_autoptr(WxFakeProvider) y = wx_fake_provider_new("y");
    g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(y), NULL));
  }
}

static void
test_registry_handler_reentrancy(void)
{
  g_autoptr(WxRegistry) registry = wx_registry_new();
  guint calls = 0;
  g_autoptr(WxFakeProvider) x = wx_fake_provider_new("x");
  g_signal_connect(registry, "changed", G_CALLBACK(reenter_handler), &calls);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(x), NULL));
  g_assert_cmpuint(calls, ==, 2); /* x's own emission, then y added from inside the handler */
  g_autoptr(GPtrArray) list = wx_registry_list_providers(registry);
  g_assert_cmpuint(list->len, ==, 2);
}

/* ------------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);

  g_test_add_func("/registry/interfaces/dispatch", test_interfaces_dispatch);
  g_test_add_func("/registry/fake/provider-fetch", test_fake_provider_fetch);
  g_test_add_func("/registry/fake/provider-delay-cancel", test_fake_provider_delay_and_cancel);
  g_test_add_func("/registry/fake/dropped-in-flight", test_fake_provider_dropped_in_flight);
  g_test_add_func("/registry/fake/programmer-errors", test_fake_provider_programmer_errors);
  g_test_add_func("/registry/fake/geocoder-search", test_fake_geocoder_search);
  g_test_add_func("/registry/empty", test_registry_empty);
  g_test_add_func("/registry/add-find-order", test_registry_add_find_order);
  g_test_add_func("/registry/rejects-bad-and-duplicate-ids", test_registry_rejects_bad_and_duplicate_ids);
  g_test_add_func("/registry/cap", test_registry_cap);
  g_test_add_func("/registry/enable-covering-signals", test_registry_enable_covering_and_signals);
  g_test_add_func("/registry/geocoder", test_registry_geocoder);
  g_test_add_func("/registry/programmer-errors", test_registry_programmer_errors);
  g_test_add_func("/registry/covers-reenter", test_registry_covers_may_reenter);
  g_test_add_func("/registry/dispose", test_registry_dispose_releases_everything);
  g_test_add_func("/registry/after-dispose", test_registry_usable_after_dispose);
  g_test_add_func("/registry/handler-reentrancy", test_registry_handler_reentrancy);
  return g_test_run();
}
