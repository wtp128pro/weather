/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of WxService (wx-service.h): refresh fan-out, deadline, per-source status, the
 * blend call, error selection, cancellation, dispose in flight, re-entrancy and search. Providers
 * are the test-only fakes of the net module (wx-fake-provider.h) and the hand-written scripted
 * TestProv / TestGeo below, which can also misbehave (ignore cancellation, answer garbage,
 * call back at once, run hooks). The service under test is the test flavour of the library (the
 * deadline can be shortened, wx-service-testing.h); the real 30-second deadline is tested
 * against the production flavour in test-service-production.c.
 */
#include <glib.h>
#include <glib/gstdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "wx-blend.h"
#include "wx-fake-provider.h"
#include "wx-registry.h"
#include "wx-service-testing.h"
#include "wx-service.h"
#include "wx-types.h"

#define HOUR_S 3600

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

/* Iterates the default main context until @cond holds; fails after 30 s. (g_assertion_message()
 * rather than g_error(): the latter ends in an endless loop that -fanalyzer reports.) */
#define SPIN_UNTIL(cond)                                                                   \
  G_STMT_START {                                                                           \
    gint64 limit_us_ = g_get_monotonic_time() + 30 * G_USEC_PER_SEC;                       \
    while (!(cond)) {                                                                      \
      if (g_get_monotonic_time() > limit_us_)                                              \
        g_assertion_message(G_LOG_DOMAIN, __FILE__, __LINE__, G_STRFUNC,                   \
                            "timed out waiting for: " #cond);                              \
      g_main_context_iteration(NULL, TRUE);                                                \
    }                                                                                      \
  }                                                                                        \
  G_STMT_END

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

/* Runs the default main context for @ms milliseconds (late deliveries, double callbacks). */
static void
drain_ms(guint ms)
{
  gint64 end_us = g_get_monotonic_time() + (gint64)ms * 1000;
  while (g_get_monotonic_time() < end_us) {
    while (g_main_context_iteration(NULL, FALSE))
      ;
    g_usleep(500);
  }
}

static gint64
now_s(void)
{
  return g_get_real_time() / G_USEC_PER_SEC;
}

static WxPlace *
make_place(const char *name, double lat, double lon, const char *tz)
{
  WxPlace *place = wx_place_new(name, "Florida", "United States", "US", lat, lon, tz, NULL);
  g_assert_nonnull(place);
  return place;
}

static WxPlace *
miami(void)
{
  return make_place("Miami", 25.7617, -80.1918, "America/New_York");
}

/*
 * A member with @n_hours hourly buckets starting an hour before now, every variable set, the
 * temperature @temp_c. The ids need not match any provider.
 */
static WxMember *
make_member_n(const char *source, const char *model, double temp_c, guint n_hours)
{
  WxMember *member = wx_member_new(source, model, now_s(), NULL);
  g_assert_nonnull(member);
  for (guint i = 0; i < n_hours; i++) {
    WxHour hour;
    wx_hour_init(&hour);
    hour.t_s = now_s() / HOUR_S * HOUR_S - HOUR_S + (gint64)i * HOUR_S;
    hour.temp_c = temp_c;
    hour.feels_c = temp_c;
    hour.humidity_pct = 50.0;
    hour.wind_kmh = 10.0;
    hour.gust_kmh = 15.0;
    hour.cloud_pct = 40.0;
    hour.precip_mm = 0.0;
    hour.precip_prob = 10.0;
    hour.wmo = 1;
    g_assert_true(wx_member_add_hour(member, &hour));
  }
  return member;
}

static WxMember *
make_member(const char *source, double temp_c)
{
  return make_member_n(source, "m", temp_c, 48);
}

/* A result of provider @id holding a new reference to each of the NULL-terminated members. */
static WxSourceResult *
make_result(const char *id, ...)
{
  WxSourceResult *result = wx_source_result_new(id, NULL);
  g_assert_nonnull(result);
  va_list args;
  va_start(args, id);
  WxMember *member;
  while ((member = va_arg(args, WxMember *)) != NULL)
    g_ptr_array_add(result->members, wx_member_ref(member));
  va_end(args);
  return result;
}

/* ------------------------------------------------------------------------ */
/* TestProv: a scripted provider that can misbehave                         */
/* ------------------------------------------------------------------------ */

typedef enum {
  TP_ANSWER, /* answers after delay_ms, ignoring the cancellable */
  TP_HOLD,   /* keeps the operation until test_prov_release(), ignoring the cancellable */
  TP_SYNC    /* calls the callback inside fetch_async (the interface forbids it) */
} TpMode;

typedef enum {
  TPR_MEMBERS,           /* a result with the members */
  TPR_NULL_NO_ERROR,     /* NULL without an error */
  TPR_NULL_MEMBERS,      /* a result whose members array is NULL */
  TPR_NULL_ENTRIES       /* members: NULL, the first member, NULL */
} TpResult;

typedef void (*TestHook)(gpointer instance, gpointer data);

#define TEST_TYPE_PROV (test_prov_get_type())
G_DECLARE_FINAL_TYPE(TestProv, test_prov, TEST, PROV, GObject)

struct _TestProv {
  GObject parent_instance;
  char *id, *name, *attribution, *url;
  gboolean covers;
  guint covers_calls, fetches;
  TpMode mode;
  guint delay_ms;
  TpResult result_kind;
  GPtrArray *members;          /* WxMember*, element free function wx_member_unref() */
  GError *failure;             /* owned: fail with a copy of it */
  gboolean both;               /* a failure comes with a result as well (the interface forbids it) */
  GCancellable *seen;          /* the cancellable of the last fetch (a reference) */
  const WxPlace *seen_place;   /* the place of the last fetch (only compared, never read later) */
  char *seen_key;              /* wx_place_key() of that place, taken during the fetch */
  GPtrArray *held;             /* GTask*, TP_HOLD */
  TestHook on_covers, on_fetch;
  gpointer hook_data;
};

static void test_prov_provider_init(WxProviderInterface *iface);
G_DEFINE_TYPE_WITH_CODE(TestProv, test_prov, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_PROVIDER, test_prov_provider_init))

static void
test_prov_finalize(GObject *object)
{
  TestProv *self = TEST_PROV(object);
  g_free(self->id);
  g_free(self->name);
  g_free(self->attribution);
  g_free(self->url);
  g_free(self->seen_key);
  g_ptr_array_unref(self->members);
  g_clear_error(&self->failure);
  g_clear_object(&self->seen);
  g_ptr_array_unref(self->held);
  G_OBJECT_CLASS(test_prov_parent_class)->finalize(object);
}

static void
test_prov_init(TestProv *self)
{
  self->covers = TRUE;
  self->members = g_ptr_array_new_with_free_func((GDestroyNotify)wx_member_unref);
  self->held = g_ptr_array_new_with_free_func(g_object_unref);
}

static void
test_prov_class_init(TestProvClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = test_prov_finalize;
}

static const char *
tp_get_id(WxProvider *provider)
{
  return TEST_PROV(provider)->id;
}

static const char *
tp_get_name(WxProvider *provider)
{
  return TEST_PROV(provider)->name;
}

static const char *
tp_get_attribution(WxProvider *provider)
{
  return TEST_PROV(provider)->attribution;
}

static const char *
tp_get_url(WxProvider *provider)
{
  return TEST_PROV(provider)->url;
}

static gboolean
tp_covers(WxProvider *provider, const WxPlace *place)
{
  (void)place;
  TestProv *self = TEST_PROV(provider);
  self->covers_calls++;
  if (self->on_covers != NULL)
    self->on_covers(self, self->hook_data);
  return self->covers;
}

/* Completes @task (whose source object is the provider) with the scripted outcome. */
static void
tp_deliver(TestProv *self, GTask *task)
{
  if (self->failure != NULL) {
    g_task_return_error(task, g_error_copy(self->failure));
    return;
  }
  WxSourceResult *result = NULL;
  switch (self->result_kind) {
  case TPR_MEMBERS:
    result = wx_source_result_new(self->id, NULL);
    if (result == NULL) { /* a hostile id: any valid one will do */
      result = wx_source_result_new("test-hostile", NULL);
    }
    for (guint i = 0; i < self->members->len; i++)
      g_ptr_array_add(result->members, wx_member_ref(g_ptr_array_index(self->members, i)));
    break;
  case TPR_NULL_NO_ERROR:
    break;
  case TPR_NULL_MEMBERS:
    result = wx_source_result_new("test-hostile", NULL);
    g_clear_pointer(&result->members, g_ptr_array_unref);
    break;
  case TPR_NULL_ENTRIES:
    result = wx_source_result_new("test-hostile", NULL);
    g_ptr_array_add(result->members, NULL);
    if (self->members->len > 0)
      g_ptr_array_add(result->members, wx_member_ref(g_ptr_array_index(self->members, 0)));
    g_ptr_array_add(result->members, NULL);
    break;
  }
  g_task_return_pointer(task, result, (GDestroyNotify)wx_source_result_free);
}

static gboolean
tp_on_delay(gpointer user_data)
{
  GTask *task = user_data;
  tp_deliver(g_task_get_source_object(task), task);
  g_object_unref(task);
  return G_SOURCE_REMOVE;
}

/* Addresses only (never read): the source tags of the scripted fakes' tasks. */
static char tp_tag, tg_tag;

static void
tp_fetch_async(WxProvider *provider, const WxPlace *place, GCancellable *cancellable,
               GAsyncReadyCallback callback, gpointer user_data)
{
  TestProv *self = TEST_PROV(provider);
  self->fetches++;
  g_set_object(&self->seen, cancellable);
  self->seen_place = place;
  g_free(self->seen_key);
  self->seen_key = wx_place_key(place);
  g_assert_nonnull(place);
  g_assert_nonnull(place->name); /* the service hands out its own validated copy */
  if (self->on_fetch != NULL)
    self->on_fetch(self, self->hook_data);
  GTask *task = g_task_new(self, NULL, self->mode == TP_SYNC ? NULL : callback, user_data);
  g_task_set_source_tag(task, &tp_tag);
  switch (self->mode) {
  case TP_ANSWER:
    if (self->delay_ms == 0) {
      tp_deliver(self, task);
      g_object_unref(task);
    } else {
      g_timeout_add(self->delay_ms, tp_on_delay, task);
    }
    break;
  case TP_HOLD:
    g_ptr_array_add(self->held, task);
    break;
  case TP_SYNC:
    tp_deliver(self, task);
    callback(G_OBJECT(self), G_ASYNC_RESULT(task), user_data);
    g_object_unref(task);
    break;
  }
}

static WxSourceResult *
tp_fetch_finish(WxProvider *provider, GAsyncResult *result, GError **error)
{
  g_assert_true(g_task_is_valid(result, provider));
  g_assert_true(g_task_get_source_tag(G_TASK(result)) == &tp_tag);
  TestProv *self = TEST_PROV(provider);
  WxSourceResult *answer = g_task_propagate_pointer(G_TASK(result), error);
  if (answer == NULL && self->both && error != NULL && *error != NULL) {
    answer = wx_source_result_new("test-both", NULL);
    for (guint i = 0; i < self->members->len; i++)
      g_ptr_array_add(answer->members, wx_member_ref(g_ptr_array_index(self->members, i)));
  }
  return answer;
}

static void
test_prov_provider_init(WxProviderInterface *iface)
{
  iface->get_id = tp_get_id;
  iface->get_name = tp_get_name;
  iface->get_attribution = tp_get_attribution;
  iface->get_attribution_url = tp_get_url;
  iface->covers = tp_covers;
  iface->fetch_async = tp_fetch_async;
  iface->fetch_finish = tp_fetch_finish;
}

static TestProv *
test_prov_new(const char *id)
{
  TestProv *self = g_object_new(TEST_TYPE_PROV, NULL);
  self->id = g_strdup(id);
  self->name = g_strconcat("Test ", id, NULL);
  self->attribution = g_strdup("Test data");
  self->url = g_strdup("https://example.invalid/");
  return self;
}

static void
test_prov_add_member(TestProv *self, WxMember *member)
{
  g_ptr_array_add(self->members, wx_member_ref(member));
}

/* Makes later fetches fail with @error (taken). */
static void
test_prov_fail(TestProv *self, GError *error)
{
  g_clear_error(&self->failure);
  self->failure = error;
}

/* Delivers every held operation, in the order they were started. */
static void
test_prov_release(TestProv *self)
{
  GPtrArray *held = self->held;
  self->held = g_ptr_array_new_with_free_func(g_object_unref);
  for (guint i = 0; i < held->len; i++)
    tp_deliver(self, g_ptr_array_index(held, i));
  g_ptr_array_unref(held);
}

/* ------------------------------------------------------------------------ */
/* TestGeo: a scripted geocoder that can misbehave                          */
/* ------------------------------------------------------------------------ */

#define TEST_TYPE_GEO (test_geo_get_type())
G_DECLARE_FINAL_TYPE(TestGeo, test_geo, TEST, GEO, GObject)

struct _TestGeo {
  GObject parent_instance;
  GPtrArray *(*make)(gpointer data); /* builds the answer; NULL: answer NULL without an error */
  gpointer make_data;
  GError *failure;                   /* owned: fail with a copy of it */
  gboolean both;                     /* a failure comes with hits as well (the interface forbids it) */
  guint searches;
  guint delay_ms;
  char *last_text;
  GCancellable *seen;
  TestHook on_search;
  gpointer hook_data;
};

static void test_geo_geocoder_init(WxGeocoderInterface *iface);
G_DEFINE_TYPE_WITH_CODE(TestGeo, test_geo, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(WX_TYPE_GEOCODER, test_geo_geocoder_init))

static void
test_geo_finalize(GObject *object)
{
  TestGeo *self = TEST_GEO(object);
  g_clear_error(&self->failure);
  g_free(self->last_text);
  g_clear_object(&self->seen);
  G_OBJECT_CLASS(test_geo_parent_class)->finalize(object);
}

static void
test_geo_init(TestGeo *self)
{
  (void)self;
}

static void
test_geo_class_init(TestGeoClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = test_geo_finalize;
}

static void
tg_deliver(TestGeo *self, GTask *task)
{
  if (self->failure != NULL) {
    g_task_return_error(task, g_error_copy(self->failure));
    return;
  }
  GPtrArray *hits = self->make != NULL ? self->make(self->make_data) : NULL;
  g_task_return_pointer(task, hits, hits != NULL ? (GDestroyNotify)g_ptr_array_unref : NULL);
}

static gboolean
tg_on_delay(gpointer user_data)
{
  GTask *task = user_data;
  tg_deliver(g_task_get_source_object(task), task);
  g_object_unref(task);
  return G_SOURCE_REMOVE;
}

static void
tg_search_async(WxGeocoder *geocoder, const char *text, GCancellable *cancellable,
                GAsyncReadyCallback callback, gpointer user_data)
{
  TestGeo *self = TEST_GEO(geocoder);
  self->searches++;
  g_free(self->last_text);
  self->last_text = g_strdup(text);
  g_set_object(&self->seen, cancellable);
  if (self->on_search != NULL)
    self->on_search(self, self->hook_data);
  GTask *task = g_task_new(self, NULL, callback, user_data);
  g_task_set_source_tag(task, &tg_tag);
  if (self->delay_ms == 0) {
    tg_deliver(self, task);
    g_object_unref(task);
  } else {
    g_timeout_add(self->delay_ms, tg_on_delay, task);
  }
}

static GPtrArray *
tg_search_finish(WxGeocoder *geocoder, GAsyncResult *result, GError **error)
{
  g_assert_true(g_task_is_valid(result, geocoder));
  TestGeo *self = TEST_GEO(geocoder);
  GPtrArray *hits = g_task_propagate_pointer(G_TASK(result), error);
  if (hits == NULL && self->both && self->make != NULL && error != NULL && *error != NULL)
    hits = self->make(self->make_data);
  return hits;
}

static void
test_geo_geocoder_init(WxGeocoderInterface *iface)
{
  iface->search_async = tg_search_async;
  iface->search_finish = tg_search_finish;
}

static TestGeo *
test_geo_new(void)
{
  return g_object_new(TEST_TYPE_GEO, NULL);
}

/* ------------------------------------------------------------------------ */
/* Rig: a registry, a service and the fakes registered in it                */
/* ------------------------------------------------------------------------ */

typedef struct {
  WxRegistry *registry;
  WxService *service;
  GPtrArray *fakes;   /* WxFakeProvider*, owned references, registration order */
  GPtrArray *members; /* WxMember*, owned references: the member of each fake, same order */
} Rig;

static Rig *
rig_new(void)
{
  Rig *rig = g_new0(Rig, 1);
  rig->registry = wx_registry_new();
  rig->service = wx_service_new(rig->registry);
  g_assert_nonnull(rig->service);
  rig->fakes = g_ptr_array_new_with_free_func(g_object_unref);
  rig->members = g_ptr_array_new_with_free_func((GDestroyNotify)wx_member_unref);
  return rig;
}

static void
rig_free(Rig *rig)
{
  g_ptr_array_unref(rig->fakes);
  g_ptr_array_unref(rig->members);
  g_clear_object(&rig->service);
  g_clear_object(&rig->registry);
  g_free(rig);
}

G_DEFINE_AUTOPTR_CLEANUP_FUNC(Rig, rig_free)

/* Registers a fake provider @id that answers with @member (a reference is kept by the rig). */
static WxFakeProvider *
rig_add_member(Rig *rig, const char *id, WxMember *member)
{
  WxFakeProvider *fake = wx_fake_provider_new(id);
  wx_fake_provider_add_member(fake, member);
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(fake), &error));
  g_assert_no_error(error);
  g_ptr_array_add(rig->fakes, fake);
  g_ptr_array_add(rig->members, wx_member_ref(member));
  return fake;
}

/* Registers a fake provider @id with one 48-hour member of source @id and temperature @temp_c. */
static WxFakeProvider *
rig_add(Rig *rig, const char *id, double temp_c)
{
  g_autoptr(WxMember) member = make_member(id, temp_c);
  return rig_add_member(rig, id, member);
}

/* Registers a scripted provider (the rig does not keep a reference to it). */
static void
rig_add_prov(Rig *rig, TestProv *prov)
{
  g_autoptr(GError) error = NULL;
  g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(prov), &error));
  g_assert_no_error(error);
}

/* The oracle's input: one result per rig fake, in registration order (the first @n only). */
static GPtrArray *
rig_results(const Rig *rig, guint n)
{
  GPtrArray *results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  for (guint i = 0; i < n; i++)
    g_ptr_array_add(results, make_result(wx_provider_get_id(g_ptr_array_index(rig->fakes, i)),
                                         g_ptr_array_index(rig->members, i), NULL));
  return results;
}

/* ------------------------------------------------------------------------ */
/* Outcomes of one refresh                                                  */
/* ------------------------------------------------------------------------ */

typedef struct _Out Out;
struct _Out {
  guint calls;
  gboolean in_call; /* wx_service_refresh_async() / search_async() has not returned yet */
  WxForecast *forecast;
  GPtrArray *hits;
  GError *error;
  gint64 start_us, done_us;
  GThread *callback_thread;
  void (*after)(Out *out, WxService *service); /* runs inside the callback, after finish */
  gpointer after_data;
};

/* Releases the outcome and makes the Out ready for the next operation. */
static void
out_clear(Out *out)
{
  g_clear_pointer(&out->forecast, wx_forecast_unref);
  g_clear_pointer(&out->hits, g_ptr_array_unref);
  g_clear_error(&out->error);
  out->calls = 0;
}

static void
on_refresh_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Out *out = user_data;
  g_assert_false(out->in_call); /* never before the *_async function has returned */
  out->calls++;
  out->done_us = g_get_monotonic_time();
  out->callback_thread = g_thread_self();
  g_assert_true(WX_IS_SERVICE(source));
  g_assert_null(out->forecast);
  out->forecast = wx_service_refresh_finish(WX_SERVICE(source), result, &out->error);
  if (out->after != NULL)
    out->after(out, WX_SERVICE(source));
}

static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Out *out = user_data;
  g_assert_false(out->in_call);
  out->calls++;
  out->done_us = g_get_monotonic_time();
  out->callback_thread = g_thread_self();
  g_assert_true(WX_IS_SERVICE(source));
  out->hits = wx_service_search_finish(WX_SERVICE(source), result, &out->error);
  if (out->after != NULL)
    out->after(out, WX_SERVICE(source));
}

static void
out_refresh(Out *out, WxService *service, const WxPlace *place, GCancellable *cancellable)
{
  out->start_us = g_get_monotonic_time();
  out->in_call = TRUE;
  wx_service_refresh_async(service, place, cancellable, on_refresh_done, out);
  out->in_call = FALSE;
}

static void
out_search(Out *out, WxService *service, const char *text, GCancellable *cancellable)
{
  out->start_us = g_get_monotonic_time();
  out->in_call = TRUE;
  wx_service_search_async(service, text, cancellable, on_search_done, out);
  out->in_call = FALSE;
}

/* Waits for the callback and then for a while, to catch a second one. */
static void
out_wait(Out *out)
{
  SPIN_UNTIL(out->calls > 0);
  /* no test waits for the production deadline by accident: that would hide a missed completion */
  g_assert_cmpint((out->done_us - out->start_us) / 1000, <, 10000);
  drain_ms(15);
  g_assert_cmpuint(out->calls, ==, 1);
}

/* Refreshes @place with @cancellable (may be NULL), waits and checks the callback ran once. */
static void
run_refresh(Out *out, WxService *service, const WxPlace *place, GCancellable *cancellable)
{
  out_refresh(out, service, place, cancellable);
  out_wait(out);
}

static void
assert_failed(const Out *out, int code, const char *message)
{
  g_assert_null(out->forecast);
  g_assert_error(out->error, WX_ERROR, code);
  g_assert_cmpstr(out->error->message, ==, message);
}

static void
assert_cancelled(const Out *out)
{
  g_assert_null(out->forecast);
  g_assert_null(out->hits);
  g_assert_error(out->error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
}

static void
assert_succeeded(const Out *out)
{
  g_assert_no_error(out->error);
  g_assert_nonnull(out->forecast);
}

static void
assert_status(const WxForecast *forecast, guint i, const char *id, WxSourceState state, int code,
              guint n_members)
{
  g_assert_cmpuint(i, <, forecast->n_sources);
  const WxSourceStatus *status = &forecast->sources[i];
  g_assert_cmpstr(status->provider_id, ==, id);
  g_assert_cmpint(status->state, ==, state);
  g_assert_cmpint(status->error_code, ==, code);
  g_assert_cmpuint(status->n_members, ==, n_members);
}

/* ------------------------------------------------------------------------ */
/* Oracle: the blend of the same members, called directly                   */
/* ------------------------------------------------------------------------ */

static gboolean
same_double(double a, double b)
{
  return (isnan(a) && isnan(b)) || a == b;
}

/* The hours, quarters and days of two forecasts are identical (NAN equals NAN). */
static void
assert_same_blend(const WxForecast *a, const WxForecast *b)
{
  g_assert_cmpint(a->generated_s, ==, b->generated_s);
  g_assert_cmpuint(a->n_hours, ==, b->n_hours);
  for (guint i = 0; i < a->n_hours; i++) {
    const WxBlendHour *x = &a->hours[i], *y = &b->hours[i];
    g_assert_cmpint(x->t_s, ==, y->t_s);
    g_assert_true(same_double(x->temp_c, y->temp_c));
    g_assert_true(same_double(x->feels_c, y->feels_c));
    g_assert_true(same_double(x->precip_mm, y->precip_mm));
    g_assert_true(same_double(x->precip_mm_max, y->precip_mm_max));
    g_assert_true(same_double(x->precip_prob, y->precip_prob));
    g_assert_true(same_double(x->cloud_pct, y->cloud_pct));
    g_assert_true(same_double(x->wind_kmh, y->wind_kmh));
    g_assert_true(same_double(x->gust_kmh, y->gust_kmh));
    g_assert_true(same_double(x->humidity_pct, y->humidity_pct));
    g_assert_true(same_double(x->temp_spread_c, y->temp_spread_c));
    g_assert_cmpuint(x->n_members, ==, y->n_members);
    g_assert_cmpint(x->condition, ==, y->condition);
    g_assert_cmpint(x->is_day, ==, y->is_day);
  }
  g_assert_cmpuint(a->n_quarters, ==, b->n_quarters);
  for (guint i = 0; i < a->n_quarters; i++) {
    g_assert_cmpint(a->quarters[i].t_s, ==, b->quarters[i].t_s);
    g_assert_true(same_double(a->quarters[i].precip_mm, b->quarters[i].precip_mm));
  }
  g_assert_cmpuint(a->n_days, ==, b->n_days);
  for (guint i = 0; i < a->n_days; i++) {
    const WxDay *x = &a->days[i], *y = &b->days[i];
    g_assert_cmpint(x->start_s, ==, y->start_s);
    g_assert_true(same_double(x->temp_max_c, y->temp_max_c));
    g_assert_true(same_double(x->temp_min_c, y->temp_min_c));
    g_assert_true(same_double(x->precip_mm, y->precip_mm));
    g_assert_true(same_double(x->precip_prob_max, y->precip_prob_max));
    g_assert_true(same_double(x->cloud_pct, y->cloud_pct));
    g_assert_cmpint(x->condition, ==, y->condition);
  }
}

/*
 * Blends @results (GPtrArray of WxSourceResult*, in the order the service must have used) for
 * @place at the time and with the statuses of @got, and requires the same hours, quarters and
 * days as @got.
 */
static void
assert_matches_oracle(const WxForecast *got, const WxPlace *place, GPtrArray *results)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(WxForecast) expected = wx_blend_forecast(
      place, (const WxSourceResult *const *)results->pdata, results->len, got->sources,
      got->n_sources, got->generated_s, &error);
  g_assert_no_error(error);
  g_assert_nonnull(expected);
  assert_same_blend(got, expected);
}


/* ------------------------------------------------------------------------ */
/* Construction                                                             */
/* ------------------------------------------------------------------------ */

static void
test_constants(void)
{
  g_assert_cmpuint(WX_SERVICE_DEADLINE_MS, ==, 30000);
  g_assert_cmpuint(WX_REGISTRY_MAX_PROVIDERS, <=, WX_FORECAST_MAX_SOURCES);
}

static void
test_new(void)
{
  ASSERT_CRITICAL("wx_service_new", g_assert_null(wx_service_new(NULL)));
  g_autoptr(GObject) other = g_object_new(G_TYPE_OBJECT, NULL);
  ASSERT_CRITICAL("wx_service_new", g_assert_null(wx_service_new((WxRegistry *)other)));

  WxRegistry *registry = wx_registry_new();
  gpointer weak = registry;
  g_object_add_weak_pointer(G_OBJECT(registry), &weak);
  WxService *service = wx_service_new(registry);
  g_assert_true(WX_IS_SERVICE(service));
  g_object_unref(registry);
  g_assert_nonnull(weak); /* the service holds its own reference ... */
  g_object_unref(service);
  g_assert_null(weak); /* ... and drops it when it is finalized */
}

/* ------------------------------------------------------------------------ */
/* Refresh: success paths                                                   */
/* ------------------------------------------------------------------------ */

static void
test_refresh_all_ok(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
  WxFakeProvider *c = rig_add(rig, "fake-c", 30.0);
  g_autoptr(WxPlace) place = miami();

  gint64 before_s = now_s();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  gint64 after_s = now_s();

  assert_succeeded(&out);
  const WxForecast *fc = out.forecast;
  g_assert_cmpint(fc->generated_s, >=, before_s);
  g_assert_cmpint(fc->generated_s, <=, after_s);
  g_autofree char *got_key = wx_place_key(&fc->place);
  g_autofree char *want_key = wx_place_key(place);
  g_assert_cmpstr(got_key, ==, want_key);
  g_assert_cmpstr(fc->place.name, ==, "Miami");
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(b), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(c), ==, 1);

  g_assert_cmpuint(fc->n_sources, ==, 3);
  assert_status(fc, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(fc, 1, "fake-b", WX_SRC_OK, -1, 1);
  assert_status(fc, 2, "fake-c", WX_SRC_OK, -1, 1);
  g_assert_cmpstr(fc->sources[1].name, ==, "Fake fake-b");
  g_assert_cmpstr(fc->sources[1].attribution, ==, "Fake data (fake-b)");
  g_assert_cmpstr(fc->sources[1].attribution_url, ==, "https://example.invalid/");

  g_assert_cmpuint(fc->n_hours, >=, WX_BLEND_MIN_HOURS);
  for (guint i = 0; i < fc->n_hours; i++) {
    g_assert_cmpuint(fc->hours[i].n_members, ==, 3);
    g_assert_cmpfloat(fc->hours[i].temp_c, ==, 20.0); /* the median of 10, 20, 30 */
  }
  g_autoptr(GPtrArray) results = rig_results(rig, 3);
  assert_matches_oracle(fc, place, results);
  out_clear(&out);
}

/* Every covering provider is called before the main loop runs again, with a private cancellable. */
static void
test_refresh_starts_all_at_once(void)
{
  g_autoptr(Rig) rig = rig_new();
  const char *ids[] = {"hold-a", "hold-b", "hold-c"};
  TestProv *prov[3];
  for (guint i = 0; i < 3; i++) {
    prov[i] = test_prov_new(ids[i]);
    prov[i]->mode = TP_HOLD;
    g_autoptr(WxMember) member = make_member(ids[i], 10.0 * (i + 1));
    test_prov_add_member(prov[i], member);
    rig_add_prov(rig, prov[i]);
  }
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();

  Out out = {0};
  out_refresh(&out, rig->service, place, outer);
  for (guint i = 0; i < 3; i++) {
    g_assert_cmpuint(prov[i]->fetches, ==, 1);
    g_assert_cmpuint(prov[i]->held->len, ==, 1);
  }
  g_assert_cmpuint(out.calls, ==, 0);
  g_assert_true(prov[0]->seen == prov[1]->seen);
  g_assert_true(prov[1]->seen == prov[2]->seen);
  g_assert_true(prov[0]->seen != outer); /* the caller's cancellable is never handed out */
  g_assert_false(g_cancellable_is_cancelled(prov[0]->seen));
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 0); /* waits for all of them */

  test_prov_release(prov[2]);
  test_prov_release(prov[0]);
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 0); /* two of three are not enough */
  test_prov_release(prov[1]);
  out_wait(&out);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 3);
  assert_status(out.forecast, 0, "hold-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "hold-b", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 2, "hold-c", WX_SRC_OK, -1, 1);
  g_assert_false(g_cancellable_is_cancelled(outer));
  out_clear(&out);
  for (guint i = 0; i < 3; i++)
    g_object_unref(prov[i]);
}

/* The forecast does not depend on the order in which the providers answer. */
static void
test_refresh_order_independent(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
  WxFakeProvider *c = rig_add(rig, "fake-c", 45.0);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GPtrArray) results = rig_results(rig, 3);
  const guint delays[2][3] = {{0, 40, 80}, {80, 40, 0}};
  for (guint round = 0; round < 2; round++) {
    wx_fake_provider_set_delay_ms(a, delays[round][0]);
    wx_fake_provider_set_delay_ms(b, delays[round][1]);
    wx_fake_provider_set_delay_ms(c, delays[round][2]);
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    g_assert_cmpuint(out.forecast->n_sources, ==, 3);
    assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
    assert_matches_oracle(out.forecast, place, results);
    out_clear(&out);
  }
}

/* Members with the same (source, model): the provider registered first wins, whoever is faster. */
static void
test_refresh_duplicate_members(void)
{
  for (guint swap = 0; swap < 2; swap++) {
    g_autoptr(Rig) rig = rig_new();
    g_autoptr(WxMember) low = make_member_n("shared", "m", 10.0, 48);
    g_autoptr(WxMember) high = make_member_n("shared", "m", 60.0, 48);
    /* the first registered one answers last */
    WxFakeProvider *first = rig_add_member(rig, "fake-a", swap ? high : low);
    WxFakeProvider *second = rig_add_member(rig, "fake-b", swap ? low : high);
    wx_fake_provider_set_delay_ms(first, 60);
    wx_fake_provider_set_delay_ms(second, 0);
    g_autoptr(WxPlace) place = miami();

    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
    /* OK, but its only member is superseded by fake-a's: nothing of it is forwarded */
    assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 0);
    for (guint i = 0; i < out.forecast->n_hours; i++) {
      g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 1);
      g_assert_cmpfloat(out.forecast->hours[i].temp_c, ==, swap ? 60.0 : 10.0);
    }
    g_autoptr(GPtrArray) results = rig_results(rig, 2);
    assert_matches_oracle(out.forecast, place, results);
    out_clear(&out);
  }

  /* one provider returning the same pair twice: the first counts, the second is not forwarded */
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxMember) low = make_member_n("shared", "m", 10.0, 48);
  g_autoptr(WxMember) high = make_member_n("shared", "m", 60.0, 48);
  WxFakeProvider *twice = rig_add_member(rig, "fake-a", low);
  wx_fake_provider_add_member(twice, high);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  for (guint i = 0; i < out.forecast->n_hours; i++)
    g_assert_cmpfloat(out.forecast->hours[i].temp_c, ==, 10.0);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Refresh: failures, partial success, error selection                      */
/* ------------------------------------------------------------------------ */

static const int all_codes[] = {WX_ERROR_NETWORK,   WX_ERROR_TIMEOUT,     WX_ERROR_HTTP,
                                WX_ERROR_RATE_LIMITED, WX_ERROR_PARSE,    WX_ERROR_NOT_FOUND,
                                WX_ERROR_INVALID_ARG, WX_ERROR_UNSUPPORTED};

/* How informative an error is for the user, smaller is better: the documented ranking. */
static const int code_rank[] = {
    [WX_ERROR_NETWORK] = 0,      [WX_ERROR_TIMEOUT] = 0,       [WX_ERROR_RATE_LIMITED] = 1,
    [WX_ERROR_HTTP] = 2,         [WX_ERROR_PARSE] = 3,         [WX_ERROR_NOT_FOUND] = 4,
    [WX_ERROR_UNSUPPORTED] = 5,  [WX_ERROR_INVALID_ARG] = 6,
};

static void
test_refresh_one_fails(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
  WxFakeProvider *c = rig_add(rig, "fake-c", 30.0);
  wx_fake_provider_fail_with(b, WX_ERROR_NETWORK);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 3);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_FAILED, WX_ERROR_NETWORK, 0);
  assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(b), ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(c), ==, 1);
  for (guint i = 0; i < out.forecast->n_hours; i++) {
    g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 2);
    g_assert_cmpfloat(out.forecast->hours[i].temp_c, ==, 20.0); /* the mean of 10 and 30 */
  }
  g_autoptr(GPtrArray) results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  g_ptr_array_add(results, make_result("fake-a", g_ptr_array_index(rig->members, 0), NULL));
  g_ptr_array_add(results, make_result("fake-c", g_ptr_array_index(rig->members, 2), NULL));
  assert_matches_oracle(out.forecast, place, results);
  out_clear(&out);
}

/* A failing provider next to a good one: its status carries its code; UNSUPPORTED is "skipped". */
static void
test_refresh_each_error_code(void)
{
  for (guint k = 0; k < G_N_ELEMENTS(all_codes); k++) {
    int code = all_codes[k];
    g_autoptr(Rig) rig = rig_new();
    rig_add(rig, "fake-a", 10.0);
    WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
    wx_fake_provider_fail_with(b, code);
    g_autoptr(WxPlace) place = miami();

    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    g_assert_cmpuint(out.forecast->n_sources, ==, 2);
    assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
    if (code == WX_ERROR_UNSUPPORTED)
      assert_status(out.forecast, 1, "fake-b", WX_SRC_SKIPPED, -1, 0);
    else
      assert_status(out.forecast, 1, "fake-b", WX_SRC_FAILED, code, 0);
    g_assert_cmpuint(wx_fake_provider_get_fetch_count(b), ==, 1);
    g_autoptr(GPtrArray) results = rig_results(rig, 1);
    assert_matches_oracle(out.forecast, place, results);
    out_clear(&out);
  }
}

/* Every provider fails: the error of a lone provider is its own code, prefixed by its id. */
static void
test_refresh_all_fail_single(void)
{
  for (guint k = 0; k < G_N_ELEMENTS(all_codes); k++) {
    int code = all_codes[k];
    g_autoptr(Rig) rig = rig_new();
    WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
    wx_fake_provider_fail_with(a, code);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_failed(&out, code, "fake-a: scripted failure");
    g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 1);
    out_clear(&out);
  }
}

/* Two failing providers: the more informative error wins, the first registered on a tie. */
static void
test_refresh_error_ranking(void)
{
  for (guint i = 0; i < G_N_ELEMENTS(all_codes); i++) {
    for (guint j = 0; j < G_N_ELEMENTS(all_codes); j++) {
      int first = all_codes[i], second = all_codes[j];
      g_autoptr(Rig) rig = rig_new();
      wx_fake_provider_fail_with(rig_add(rig, "fake-a", 10.0), first);
      wx_fake_provider_fail_with(rig_add(rig, "fake-b", 20.0), second);
      g_autoptr(WxPlace) place = miami();
      Out out = {0};
      run_refresh(&out, rig->service, place, NULL);
      if (code_rank[first] <= code_rank[second])
        assert_failed(&out, first, "fake-a: scripted failure");
      else
        assert_failed(&out, second, "fake-b: scripted failure");
      out_clear(&out);
    }
  }
}

/*
 * A provider that answered but whose members the blend cannot use (too few hours) competes with
 * the failures of the others through the blend's own error (NOT_FOUND, "no usable forecast
 * data"): a provider's error wins when it ranks at least as well.
 */
static void
test_refresh_error_ranking_blend(void)
{
  for (guint k = 0; k < G_N_ELEMENTS(all_codes); k++) {
    int code = all_codes[k];
    g_autoptr(Rig) rig = rig_new();
    g_autoptr(WxMember) short_member = make_member_n("fake-a", "m", 10.0, 5);
    rig_add_member(rig, "fake-a", short_member);
    wx_fake_provider_fail_with(rig_add(rig, "fake-b", 20.0), code);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    if (code_rank[code] <= code_rank[WX_ERROR_NOT_FOUND])
      assert_failed(&out, code, "fake-b: scripted failure");
    else
      assert_failed(&out, WX_ERROR_NOT_FOUND, "no usable forecast data");
    out_clear(&out);
  }
}

/* A TestProv "met-no" refusing like the real provider does, next to the rest of the rig. */
static void
add_refusing(Rig *rig, const char *id, int code, const char *message)
{
  g_autoptr(TestProv) prov = test_prov_new(id);
  test_prov_fail(prov, g_error_new_literal(WX_ERROR, code, message));
  rig_add_prov(rig, prov);
}

#define FLOOR_TEXT "a request for this place was sent less than 10 minutes ago"
#define CAP_TEXT "too many outstanding requests (limit 16)"

/*
 * A provider's LOCAL refusal (MET Norway's per-place floor, the cap on requests in flight: a
 * WX_ERROR_RATE_LIMITED that cost no network request) ranks after every other failure and the
 * blend's error, whatever the registration order, and when it is all that remains the refresh
 * fails with NOT_FOUND, not RATE_LIMITED (which the application answers with a cool-down).
 */
static void
test_refresh_local_refusal_ranks_last(void)
{
  const char *texts[] = { FLOOR_TEXT, CAP_TEXT };
  for (guint t = 0; t < G_N_ELEMENTS(texts); t++) {
    for (guint k = 0; k < G_N_ELEMENTS(all_codes); k++) {
      int code = all_codes[k];
      g_autoptr(Rig) rig = rig_new();
      add_refusing(rig, "met-no", WX_ERROR_RATE_LIMITED, texts[t]); /* registered FIRST */
      wx_fake_provider_fail_with(rig_add(rig, "fake-b", 20.0), code);
      g_autoptr(WxPlace) place = miami();
      Out out = {0};
      run_refresh(&out, rig->service, place, NULL);
      assert_failed(&out, code, "fake-b: scripted failure");
      out_clear(&out);
    }
  }

  /* all that remains: NOT_FOUND with the provider's message, per source it stays RATE_LIMITED */
  for (guint t = 0; t < G_N_ELEMENTS(texts); t++) {
    g_autoptr(Rig) rig = rig_new();
    add_refusing(rig, "met-no", WX_ERROR_RATE_LIMITED, texts[t]);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    g_autofree char *want = g_strconcat("met-no: ", texts[t], NULL);
    assert_failed(&out, WX_ERROR_NOT_FOUND, want);
    out_clear(&out);
  }

  /* next to a provider that answered (its members unusable for the blend): the blend's error,
   * not the refusal, and the refusal's own status keeps its code */
  {
    g_autoptr(Rig) rig = rig_new();
    add_refusing(rig, "met-no", WX_ERROR_RATE_LIMITED, FLOOR_TEXT);
    g_autoptr(WxMember) short_member = make_member_n("fake-b", "m", 10.0, 5);
    rig_add_member(rig, "fake-b", short_member);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_failed(&out, WX_ERROR_NOT_FOUND, "no usable forecast data");
    out_clear(&out);
  }
  {
    g_autoptr(Rig) rig = rig_new();
    add_refusing(rig, "met-no", WX_ERROR_RATE_LIMITED, FLOOR_TEXT);
    rig_add(rig, "fake-b", 20.0);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "met-no", WX_SRC_FAILED, WX_ERROR_RATE_LIMITED, 0);
    assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
    out_clear(&out);
  }
}

/*
 * A rate limit a SERVER announced, or a pause a provider keeps after one, is not a local refusal:
 * it keeps the rank (and the code) of WX_ERROR_RATE_LIMITED. So do texts that merely contain a
 * refusal text, and a refusal text under another code is just that code.
 */
static void
test_refresh_genuine_rate_limit_keeps_rank(void)
{
  const char *genuine[] = { "HTTP 429: rate limited", "requests are paused after HTTP 429",
                            "NWS asked for fewer requests; waiting 5 seconds",
                            "x " FLOOR_TEXT, "the " CAP_TEXT, "" };
  for (guint t = 0; t < G_N_ELEMENTS(genuine); t++) {
    g_autoptr(Rig) rig = rig_new();
    add_refusing(rig, "met-no", WX_ERROR_RATE_LIMITED, genuine[t]);
    wx_fake_provider_fail_with(rig_add(rig, "fake-b", 20.0), WX_ERROR_HTTP);
    g_autoptr(WxPlace) place = miami();
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    g_autofree char *want = g_strconcat("met-no: ", genuine[t], NULL);
    assert_failed(&out, WX_ERROR_RATE_LIMITED, want);
    out_clear(&out);
  }
  /* the refusal text under another code is an ordinary error of that code (HTTP ranks 2, before
   * fake-b's PARSE, 3) */
  g_autoptr(Rig) rig = rig_new();
  add_refusing(rig, "met-no", WX_ERROR_HTTP, FLOOR_TEXT);
  wx_fake_provider_fail_with(rig_add(rig, "fake-b", 20.0), WX_ERROR_PARSE);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_failed(&out, WX_ERROR_HTTP, "met-no: " FLOOR_TEXT);
  out_clear(&out);
}

/* Nothing usable and nothing failed: the blend's NOT_FOUND, with or without short members. */
static void
test_refresh_blend_not_found(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxMember) m1 = make_member_n("fake-a", "m", 10.0, 5);
  g_autoptr(WxMember) m2 = make_member_n("fake-b", "m", 20.0, 1);
  rig_add_member(rig, "fake-a", m1);
  rig_add_member(rig, "fake-b", m2);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_failed(&out, WX_ERROR_NOT_FOUND, "no usable forecast data");
  out_clear(&out);

  /* a usable provider next to it makes the refresh succeed, the short one is still reported */
  rig_add(rig, "fake-c", 30.0);
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 3);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
  out_clear(&out);
}

/* A provider that answers without any member is a failure of that provider (NOT_FOUND). */
static void
test_refresh_no_members(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeProvider) bare = wx_fake_provider_new("fake-b");
  g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(bare), NULL));
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_failed(&out, WX_ERROR_NOT_FOUND, "fake-b: the provider returned no forecast data");
  out_clear(&out);

  WxFakeProvider *good = rig_add(rig, "fake-c", 20.0);
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 2);
  assert_status(out.forecast, 0, "fake-b", WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0);
  assert_status(out.forecast, 1, "fake-c", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(good), ==, 1);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Refresh: providers that misbehave                                        */
/* ------------------------------------------------------------------------ */

#define ALONE_OK (-100)
#define ALONE_CANCELLED (-101)

/*
 * Runs @bad (id "bad-x") next to a good provider, expecting the forecast and the status
 * (@state, @code, @n_members) for it, then alone, expecting a forecast (@alone == ALONE_OK), a
 * cancellation (ALONE_CANCELLED) or the WX_ERROR code @alone with @alone_message.
 */
static void
check_bad_provider(TestProv *bad, WxSourceState state, int code, guint n_members, int alone,
                   const char *alone_message)
{
  g_autoptr(WxPlace) place = miami();
  {
    g_autoptr(Rig) rig = rig_new();
    rig_add(rig, "fake-a", 20.0);
    rig_add_prov(rig, bad);
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    g_assert_cmpuint(out.forecast->n_sources, ==, 2);
    assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "bad-x", state, code, n_members);
    g_autoptr(GPtrArray) results = rig_results(rig, 1);
    if (state == WX_SRC_OK && bad->members->len > 0)
      g_ptr_array_add(results, make_result("bad-x", g_ptr_array_index(bad->members, 0), NULL));
    assert_matches_oracle(out.forecast, place, results);
    out_clear(&out);
  }
  {
    g_autoptr(Rig) rig = rig_new();
    rig_add_prov(rig, bad);
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    if (alone == ALONE_OK)
      assert_succeeded(&out);
    else if (alone == ALONE_CANCELLED)
      assert_cancelled(&out);
    else
      assert_failed(&out, alone, alone_message);
    out_clear(&out);
  }
}

static TestProv *
bad_provider(void)
{
  return test_prov_new("bad-x");
}

static void
test_refresh_garbage_results(void)
{
  /* NULL without an error */
  g_autoptr(TestProv) p1 = bad_provider();
  p1->result_kind = TPR_NULL_NO_ERROR;
  check_bad_provider(p1, WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0, WX_ERROR_NOT_FOUND,
                     "bad-x: the provider returned no result");

  /* a result without a members array */
  g_autoptr(TestProv) p2 = bad_provider();
  p2->result_kind = TPR_NULL_MEMBERS;
  check_bad_provider(p2, WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0, WX_ERROR_NOT_FOUND,
                     "bad-x: the provider returned no forecast data");

  /* NULL entries only */
  g_autoptr(TestProv) p3 = bad_provider();
  p3->result_kind = TPR_NULL_ENTRIES;
  check_bad_provider(p3, WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0, WX_ERROR_NOT_FOUND,
                     "bad-x: the provider returned no forecast data");

  /* NULL entries around a real member: the member counts */
  g_autoptr(TestProv) p4 = bad_provider();
  p4->result_kind = TPR_NULL_ENTRIES;
  g_autoptr(WxMember) real = make_member("bad-x", 30.0);
  test_prov_add_member(p4, real);
  check_bad_provider(p4, WX_SRC_OK, -1, 1, ALONE_OK, NULL);

  /* a member without any hour or quarter does not count */
  g_autoptr(TestProv) p5 = bad_provider();
  g_autoptr(WxMember) empty = wx_member_new("bad-x", "m", now_s(), NULL);
  test_prov_add_member(p5, empty);
  check_bad_provider(p5, WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0, WX_ERROR_NOT_FOUND,
                     "bad-x: the provider returned no forecast data");

  /* a member with quarters only counts (the nowcast member has no hours), but the blend has no
   * hour from it: a lone one cannot make a forecast */
  g_autoptr(TestProv) p6 = bad_provider();
  g_autoptr(WxMember) quarters = wx_member_new("bad-x", "m", now_s(), NULL);
  WxQuarter quarter = {now_s() / 900 * 900, 0.5};
  g_assert_true(wx_member_add_quarter(quarters, &quarter));
  test_prov_add_member(p6, quarters);
  check_bad_provider(p6, WX_SRC_OK, -1, 1, WX_ERROR_NOT_FOUND, "no usable forecast data");
}

/* Errors outside the interface's contract are reduced to the WX_ERROR domain. */
static void
test_refresh_foreign_errors(void)
{
  /* another domain */
  g_autoptr(TestProv) p1 = bad_provider();
  test_prov_fail(p1, g_error_new_literal(G_FILE_ERROR, G_FILE_ERROR_NOENT, "no such thing"));
  check_bad_provider(p1, WX_SRC_FAILED, WX_ERROR_NETWORK, 0, WX_ERROR_NETWORK,
                     "bad-x: no such thing");

  /* a GIO error that is not a cancellation */
  g_autoptr(TestProv) p2 = bad_provider();
  test_prov_fail(p2, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "gio timeout"));
  check_bad_provider(p2, WX_SRC_FAILED, WX_ERROR_NETWORK, 0, WX_ERROR_NETWORK,
                     "bad-x: gio timeout");

  /* a WX_ERROR code that does not exist, above and below */
  g_autoptr(TestProv) p3 = bad_provider();
  test_prov_fail(p3, g_error_new_literal(WX_ERROR, 99, "too big"));
  check_bad_provider(p3, WX_SRC_FAILED, WX_ERROR_NETWORK, 0, WX_ERROR_NETWORK,
                     "bad-x: too big");
  g_autoptr(TestProv) p4 = bad_provider();
  test_prov_fail(p4, g_error_new_literal(WX_ERROR, -3, "negative"));
  check_bad_provider(p4, WX_SRC_FAILED, WX_ERROR_NETWORK, 0, WX_ERROR_NETWORK,
                     "bad-x: negative");

  /* a cancellation that the provider reports by itself: a failure without a WxError code; when
   * every covering provider did so, the refresh is cancelled */
  g_autoptr(TestProv) p5 = bad_provider();
  test_prov_fail(p5, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "I gave up"));
  check_bad_provider(p5, WX_SRC_FAILED, -1, 0, ALONE_CANCELLED, NULL);

  /* control characters, a bidi override and invalid UTF-8 are removed or replaced, and the
   * message is cut at 200 bytes: "bad" + U+FFFD (3 bytes) + 194 x */
  g_autoptr(GString) hostile = g_string_new("ba\xE2\x80\xAE" "d\x07\xff");
  for (guint i = 0; i < 300; i++)
    g_string_append_c(hostile, 'x');
  g_autoptr(TestProv) p6 = bad_provider();
  test_prov_fail(p6, g_error_new_literal(G_FILE_ERROR, G_FILE_ERROR_FAILED, hostile->str));
  g_autoptr(GString) want = g_string_new("bad-x: bad\xEF\xBF\xBD");
  for (guint i = 0; i < 194; i++)
    g_string_append_c(want, 'x');
  check_bad_provider(p6, WX_SRC_FAILED, WX_ERROR_NETWORK, 0, WX_ERROR_NETWORK, want->str);
}

/* A provider answering with a result and an error is a failure; the result is released. */
static void
test_refresh_result_with_error(void)
{
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  g_autoptr(TestProv) both = test_prov_new("both-b");
  g_autoptr(WxMember) member = make_member("both-b", 20.0);
  test_prov_add_member(both, member);
  both->both = TRUE;
  test_prov_fail(both, g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "bad status"));
  rig_add_prov(rig, both);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "both-b", WX_SRC_FAILED, WX_ERROR_HTTP, 0);
  for (guint i = 0; i < out.forecast->n_hours; i++)
    g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 1); /* its member was not blended */
  g_assert_true(g_atomic_ref_count_compare(&member->ref_count, 2)); /* test + provider */
  out_clear(&out);
}

/* A mix of cancelled and failed providers: the failure is reported, a cancellation is not. */
static void
test_refresh_cancelled_providers(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) c1 = test_prov_new("cancel-a");
  g_autoptr(TestProv) c2 = test_prov_new("cancel-b");
  test_prov_fail(c1, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "x"));
  test_prov_fail(c2, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "y"));
  rig_add_prov(rig, c1);
  rig_add_prov(rig, c2);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_cancelled(&out); /* every covering provider was cancelled */
  out_clear(&out);

  WxFakeProvider *failing = rig_add(rig, "fake-c", 10.0);
  wx_fake_provider_fail_with(failing, WX_ERROR_RATE_LIMITED);
  run_refresh(&out, rig->service, place, NULL);
  assert_failed(&out, WX_ERROR_RATE_LIMITED, "fake-c: scripted failure");
  out_clear(&out);

  wx_fake_provider_fail_with(failing, -1);
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "cancel-a", WX_SRC_FAILED, -1, 0);
  assert_status(out.forecast, 1, "cancel-b", WX_SRC_FAILED, -1, 0);
  assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
  out_clear(&out);
}

/* What a provider says about itself is validated and sanitised; an unusable id drops it. */
static void
test_refresh_source_fields(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) nice = test_prov_new("prov-nice");
  g_free(nice->name);
  nice->name = g_strdup("Nice Name");
  g_free(nice->attribution);
  nice->attribution = g_strdup("Nice credit");
  g_free(nice->url);
  nice->url = g_strdup("https://example.invalid/path?x=1");
  g_autoptr(TestProv) odd = test_prov_new("prov-odd");
  g_free(odd->name);
  odd->name = g_strdup("A\x01" "B\xE2\x80\xAE" "C");
  g_clear_pointer(&odd->attribution, g_free);
  g_free(odd->url);
  odd->url = g_strdup("http://insecure.invalid/");
  g_autoptr(TestProv) renamed = test_prov_new("prov-renamed");
  g_autoptr(TestProv) bare = test_prov_new("prov-bare");
  g_clear_pointer(&bare->name, g_free);
  g_clear_pointer(&bare->url, g_free);
  TestProv *providers[] = {nice, odd, renamed, bare};
  for (guint i = 0; i < G_N_ELEMENTS(providers); i++) {
    TestProv *p = providers[i];
    g_autoptr(WxMember) member = make_member(p->id, 10.0 + i);
    test_prov_add_member(p, member);
    rig_add_prov(rig, p);
  }
  /* the id must be constant: this provider changes it after the registry accepted it */
  g_free(renamed->id);
  renamed->id = g_strdup("BAD ID");
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(renamed->fetches, ==, 0);
  g_assert_cmpuint(renamed->covers_calls, ==, 1);
  const WxForecast *fc = out.forecast;
  g_assert_cmpuint(fc->n_sources, ==, 3);
  assert_status(fc, 0, "prov-nice", WX_SRC_OK, -1, 1);
  g_assert_cmpstr(fc->sources[0].name, ==, "Nice Name");
  g_assert_cmpstr(fc->sources[0].attribution, ==, "Nice credit");
  g_assert_cmpstr(fc->sources[0].attribution_url, ==, "https://example.invalid/path?x=1");
  assert_status(fc, 1, "prov-odd", WX_SRC_OK, -1, 1);
  g_assert_cmpstr(fc->sources[1].name, ==, "ABC");
  g_assert_cmpstr(fc->sources[1].attribution, ==, "");
  g_assert_cmpstr(fc->sources[1].attribution_url, ==, ""); /* rejected: replaced, not the source */
  assert_status(fc, 2, "prov-bare", WX_SRC_OK, -1, 1);
  g_assert_cmpstr(fc->sources[2].name, ==, "");
  g_assert_cmpstr(fc->sources[2].attribution_url, ==, "");
  out_clear(&out);
}

/* Disabled and non-covering providers are skipped without being called. */
static void
test_refresh_skipped(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) a = test_prov_new("prov-a");
  g_autoptr(TestProv) b = test_prov_new("prov-b");
  g_autoptr(TestProv) c = test_prov_new("prov-c");
  TestProv *provs[] = {a, b, c};
  for (guint i = 0; i < 3; i++) {
    g_autoptr(WxMember) member = make_member(provs[i]->id, 10.0 * (i + 1));
    test_prov_add_member(provs[i], member);
    rig_add_prov(rig, provs[i]);
  }
  c->covers = FALSE;
  WxFakeProvider *d = rig_add(rig, "fake-d", 40.0);
  wx_fake_provider_fail_with(d, WX_ERROR_UNSUPPORTED); /* learned from the server */
  g_assert_true(wx_registry_set_enabled(rig->registry, "prov-b", FALSE));
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 4);
  assert_status(out.forecast, 0, "prov-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "prov-b", WX_SRC_SKIPPED, -1, 0);
  assert_status(out.forecast, 2, "prov-c", WX_SRC_SKIPPED, -1, 0);
  assert_status(out.forecast, 3, "fake-d", WX_SRC_SKIPPED, -1, 0);
  g_assert_cmpuint(a->fetches, ==, 1);
  g_assert_cmpuint(b->fetches, ==, 0);
  g_assert_cmpuint(c->fetches, ==, 0);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(d), ==, 1);
  g_assert_cmpuint(a->covers_calls, ==, 1); /* once per enabled provider per refresh */
  g_assert_cmpuint(b->covers_calls, ==, 0); /* disabled: not even asked */
  g_assert_cmpuint(c->covers_calls, ==, 1);
  for (guint i = 0; i < out.forecast->n_hours; i++)
    g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 1);
  out_clear(&out);

  /* the registry is read again by every refresh */
  g_assert_true(wx_registry_set_enabled(rig->registry, "prov-b", TRUE));
  c->covers = TRUE;
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "prov-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "prov-b", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 2, "prov-c", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 3, "fake-d", WX_SRC_SKIPPED, -1, 0);
  g_assert_cmpuint(a->covers_calls, ==, 2);
  g_assert_cmpuint(b->covers_calls, ==, 1);
  g_assert_cmpuint(c->covers_calls, ==, 2);
  out_clear(&out);
}

/* Nobody to ask: UNSUPPORTED without any fetch. */
static void
test_refresh_no_covering(void)
{
  const char *message = "no enabled data source covers this place";
  g_autoptr(WxPlace) place = miami();
  Out out = {0};

  g_autoptr(Rig) empty = rig_new(); /* no provider at all */
  run_refresh(&out, empty->service, place, NULL);
  assert_failed(&out, WX_ERROR_UNSUPPORTED, message);
  out_clear(&out);

  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
  g_assert_true(wx_registry_set_enabled(rig->registry, "fake-a", FALSE));
  g_assert_true(wx_registry_set_enabled(rig->registry, "fake-b", FALSE));
  run_refresh(&out, rig->service, place, NULL); /* all disabled */
  assert_failed(&out, WX_ERROR_UNSUPPORTED, message);
  out_clear(&out);

  g_assert_true(wx_registry_set_enabled(rig->registry, "fake-a", TRUE));
  g_assert_true(wx_registry_set_enabled(rig->registry, "fake-b", TRUE));
  wx_fake_provider_set_covers(a, FALSE);
  wx_fake_provider_set_covers(b, FALSE);
  run_refresh(&out, rig->service, place, NULL); /* all non-covering */
  assert_failed(&out, WX_ERROR_UNSUPPORTED, message);
  out_clear(&out);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 0);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(b), ==, 0);

  /* the only covering provider has an unusable id: it is not asked either */
  g_autoptr(Rig) odd = rig_new();
  g_autoptr(TestProv) renamed = test_prov_new("prov-renamed");
  rig_add_prov(odd, renamed);
  g_free(renamed->id);
  renamed->id = g_strdup("Not Valid");
  run_refresh(&out, odd->service, place, NULL);
  assert_failed(&out, WX_ERROR_UNSUPPORTED, message);
  g_assert_cmpuint(renamed->fetches, ==, 0);
  out_clear(&out);
}

/* The place is validated by copying: hand-built garbage is INVALID_ARG, nothing is fetched. */
static void
test_refresh_invalid_place(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *b = rig_add(rig, "fake-b", 20.0);
  char long_name[301];
  memset(long_name, 'a', 300);
  long_name[300] = '\0';

  enum { OK, NAME_NULL, NAME_EMPTY, NAME_LONG, NAME_CONTROL, NAME_BAD_UTF8, ADMIN_NULL, COUNTRY_NULL,
         TZ_NULL, TZ_ABSOLUTE, TZ_DOTDOT, CODE_LOWER, LAT_NAN, LAT_HIGH, LAT_LOW, LON_HIGH,
         LON_INF, N_CASES };
  guint n_accepted = 0;
  for (int which = 0; which < N_CASES; which++) {
    WxPlace place = {.name = (char *)"Miami",
                     .admin1 = (char *)"Florida",
                     .country = (char *)"United States",
                     .country_code = {'U', 'S', '\0'},
                     .lat = 25.7617,
                     .lon = -80.1918,
                     .timezone = (char *)"America/New_York"};
    switch (which) {
    case NAME_NULL: place.name = NULL; break;
    case NAME_EMPTY: place.name = (char *)""; break;
    case NAME_LONG: place.name = long_name; break;
    case NAME_CONTROL: place.name = (char *)"Mia\x01mi"; break;
    case NAME_BAD_UTF8: place.name = (char *)"Mia\xffmi"; break;
    case ADMIN_NULL: place.admin1 = NULL; break;
    case COUNTRY_NULL: place.country = NULL; break;
    case TZ_NULL: place.timezone = NULL; break;
    case TZ_ABSOLUTE: place.timezone = (char *)"/etc/passwd"; break;
    case TZ_DOTDOT: place.timezone = (char *)"a/../b"; break;
    case CODE_LOWER: place.country_code[0] = 'u'; break;
    case LAT_NAN: place.lat = NAN; break;
    case LAT_HIGH: place.lat = 90.0001; break;
    case LAT_LOW: place.lat = -90.0001; break;
    case LON_HIGH: place.lon = 180.0001; break;
    case LON_INF: place.lon = INFINITY; break;
    default: break;
    }
    Out out = {0};
    run_refresh(&out, rig->service, &place, NULL);
    gboolean optional_text = which == ADMIN_NULL || which == COUNTRY_NULL || which == TZ_NULL;
    if (which == OK || optional_text) {
      /* the baseline is valid; a NULL optional string is accepted and becomes "" (wx_place_copy()) */
      assert_succeeded(&out);
      n_accepted++;
      if (which == ADMIN_NULL)
        g_assert_cmpstr(out.forecast->place.admin1, ==, "");
      if (which == COUNTRY_NULL)
        g_assert_cmpstr(out.forecast->place.country, ==, "");
      if (which == TZ_NULL)
        g_assert_cmpstr(out.forecast->place.timezone, ==, "");
    } else {
      if (out.forecast != NULL)
        g_error("the hostile place of case %d was accepted", which);
      assert_failed(&out, WX_ERROR_INVALID_ARG, "invalid place");
    }
    out_clear(&out);
  }
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, n_accepted); /* nothing else */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(b), ==, n_accepted);
  g_assert_cmpuint(n_accepted, ==, 4);
}

static void
test_refresh_programmer_errors(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GObject) not_a_cancellable = g_object_new(G_TYPE_OBJECT, NULL);
  Out out = {0};
  ASSERT_CRITICAL("wx_service_refresh_async",
                  wx_service_refresh_async(NULL, place, NULL, on_refresh_done, &out));
  ASSERT_CRITICAL("wx_service_refresh_async",
                  wx_service_refresh_async((WxService *)not_a_cancellable, place, NULL,
                                           on_refresh_done, &out));
  ASSERT_CRITICAL("wx_service_refresh_async",
                  wx_service_refresh_async(rig->service, NULL, NULL, on_refresh_done, &out));
  ASSERT_CRITICAL("wx_service_refresh_async",
                  wx_service_refresh_async(rig->service, place, (GCancellable *)not_a_cancellable,
                                           on_refresh_done, &out));
  drain_ms(50);
  g_assert_cmpuint(out.calls, ==, 0); /* nothing was started */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 0);
}

/* The place is copied: the caller may free its own at once, the providers get a private one. */
static void
test_refresh_place_is_copied(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) prov = test_prov_new("prov-a");
  g_autoptr(WxMember) member = make_member("prov-a", 10.0);
  test_prov_add_member(prov, member);
  prov->delay_ms = 40;
  rig_add_prov(rig, prov);
  WxPlace *place = make_place("Miami", 25.7617, -80.1918, "America/New_York");
  g_autofree char *want_key = wx_place_key(place);
  const WxPlace *caller_place = place;

  Out out = {0};
  out_refresh(&out, rig->service, place, NULL);
  wx_place_free(place); /* before any provider has answered */
  g_assert_cmpuint(prov->fetches, ==, 1);
  g_assert_true(prov->seen_place != caller_place); /* the provider got the service's copy */
  g_assert_cmpstr(prov->seen_key, ==, want_key);
  out_wait(&out);
  assert_succeeded(&out);
  g_assert_cmpstr(out.forecast->place.name, ==, "Miami");
  g_assert_cmpstr(out.forecast->place.timezone, ==, "America/New_York");
  g_autofree char *got_key = wx_place_key(&out.forecast->place);
  g_assert_cmpstr(got_key, ==, want_key);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Deadline                                                                 */
/* ------------------------------------------------------------------------ */

static gint64
elapsed_ms(const Out *out)
{
  return (out->done_us - out->start_us) / 1000;
}

/* A fake that never answers by itself; it honours cancellation (it ends as cancelled). */
static WxFakeProvider *
rig_add_hang(Rig *rig, const char *id)
{
  WxFakeProvider *fake = rig_add(rig, id, 20.0);
  wx_fake_provider_set_delay_ms(fake, G_MAXUINT);
  return fake;
}

/* One provider hangs past the deadline: the others' forecast arrives at the deadline. */
static void
test_deadline_partial(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *hang = rig_add_hang(rig, "fake-hang");
  rig_add(rig, "fake-c", 30.0);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpint(elapsed_ms(&out), >=, 300);
  g_assert_cmpint(elapsed_ms(&out), <, 300 + 2000);
  g_assert_cmpuint(out.forecast->n_sources, ==, 3);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "fake-hang", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(hang), ==, 1);
  for (guint i = 0; i < out.forecast->n_hours; i++)
    g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 2);
  g_autoptr(GPtrArray) results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  g_ptr_array_add(results, make_result("fake-a", g_ptr_array_index(rig->members, 0), NULL));
  g_ptr_array_add(results, make_result("fake-c", g_ptr_array_index(rig->members, 2), NULL));
  assert_matches_oracle(out.forecast, place, results);
  out_clear(&out);
}

/* The stragglers are told to stop: a provider that honours cancellation finishes and goes away. */
static void
test_deadline_cancels_stragglers(void)
{
  wx_service_test_set_deadline_ms(300);
  Rig *rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  WxFakeProvider *hang = rig_add_hang(rig, "fake-hang");
  gpointer weak_hang = hang;
  g_object_add_weak_pointer(G_OBJECT(hang), &weak_hang);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  out_clear(&out);
  rig_free(rig);
  /* the pending fetch keeps the fake alive until it ends; it only ends if it was cancelled */
  SPIN_UNTIL(weak_hang == NULL);
}

/* Everybody hangs: TIMEOUT, whatever else failed. */
static void
test_deadline_all_hang(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(WxPlace) place = miami();
  {
    g_autoptr(Rig) rig = rig_new();
    rig_add_hang(rig, "fake-a");
    rig_add_hang(rig, "fake-b");
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_failed(&out, WX_ERROR_TIMEOUT, "fake-a: no answer within 300 ms");
    g_assert_cmpint(elapsed_ms(&out), >=, 300);
    g_assert_cmpint(elapsed_ms(&out), <, 300 + 2000);
    out_clear(&out);
  }
  {
    g_autoptr(Rig) rig = rig_new();
    wx_fake_provider_fail_with(rig_add(rig, "fake-a", 10.0), WX_ERROR_PARSE);
    rig_add_hang(rig, "fake-b");
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_failed(&out, WX_ERROR_TIMEOUT, "fake-b: no answer within 300 ms"); /* beats PARSE */
    out_clear(&out);
  }
}

/*
 * [INV-SVC] A provider that ignores cancellation and never answers costs the refresh the deadline,
 * not more; what it delivers afterwards is freed.
 */
static void
test_deadline_ignoring_provider(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxMember) late_member = make_member("hold-a", 25.0);
  g_autoptr(TestProv) hold = test_prov_new("hold-a");
  hold->mode = TP_HOLD;
  test_prov_add_member(hold, late_member);
  rig_add_prov(rig, hold);
  rig_add(rig, "fake-b", 10.0);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpint(elapsed_ms(&out), >=, 300);
  g_assert_cmpint(elapsed_ms(&out), <, 300 + 2000);
  g_assert_cmpuint(out.forecast->n_sources, ==, 2);
  assert_status(out.forecast, 0, "hold-a", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(hold->held->len, ==, 1); /* still outstanding: the service did not wait for it */
  g_assert_nonnull(hold->seen);
  g_assert_true(g_cancellable_is_cancelled(hold->seen)); /* but it was told to stop */
  g_assert_true(g_atomic_ref_count_compare(&late_member->ref_count, 2)); /* test + provider */

  test_prov_release(hold); /* the late delivery: a good result, after the refresh is over */
  drain_ms(50);
  g_assert_cmpuint(out.calls, ==, 1);
  g_assert_true(g_atomic_ref_count_compare(&late_member->ref_count, 2)); /* the service let go */
  assert_status(out.forecast, 0, "hold-a", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0); /* not reopened */
  for (guint i = 0; i < out.forecast->n_hours; i++)
    g_assert_cmpuint(out.forecast->hours[i].n_members, ==, 1);
  out_clear(&out);

  /* a late failure and a late garbage result are freed as well */
  g_autoptr(TestProv) late_fail = test_prov_new("hold-b");
  late_fail->mode = TP_HOLD;
  test_prov_fail(late_fail, g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "late"));
  g_autoptr(TestProv) late_null = test_prov_new("hold-c");
  late_null->mode = TP_HOLD;
  late_null->result_kind = TPR_NULL_ENTRIES;
  test_prov_add_member(late_null, late_member);
  rig_add_prov(rig, late_fail);
  rig_add_prov(rig, late_null);
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, 4);
  assert_status(out.forecast, 2, "hold-b", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  assert_status(out.forecast, 3, "hold-c", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  test_prov_release(late_fail);
  test_prov_release(late_null); /* NULL entries around a member, delivered late */
  test_prov_release(hold);
  drain_ms(50);
  g_assert_cmpuint(out.calls, ==, 1);
  g_assert_true(g_atomic_ref_count_compare(&late_member->ref_count, 3)); /* test, hold, late_null */
  out_clear(&out);
}

/* A refresh that is answered in time finishes at once and the timer never fires afterwards. */
static void
test_deadline_not_before_all_done(void)
{
  wx_service_test_set_deadline_ms(800);
  g_autoptr(Rig) rig = rig_new();
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-a", 10.0), 20);
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-b", 20.0), 40);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  out_refresh(&out, rig->service, place, NULL);
  SPIN_UNTIL(out.calls > 0);
  g_assert_cmpint(elapsed_ms(&out), >=, 40);
  g_assert_cmpint(elapsed_ms(&out), <, 800);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
  drain_ms(1000); /* well past the deadline */
  g_assert_cmpuint(out.calls, ==, 1);
  out_clear(&out);
}

/* Every refresh has its own deadline, counted from its own start. */
static void
test_deadline_per_refresh(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  rig_add_hang(rig, "fake-b");
  g_autoptr(WxPlace) place = miami();
  for (guint round = 0; round < 3; round++) {
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    g_assert_cmpint(elapsed_ms(&out), >=, 300);
    g_assert_cmpint(elapsed_ms(&out), <, 300 + 2000);
    assert_status(out.forecast, 1, "fake-b", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
    out_clear(&out);
  }
  /* the deadline is read when a refresh starts: a later change does not touch one in flight */
  wx_service_test_set_deadline_ms(10000);
  g_autoptr(GCancellable) outer = g_cancellable_new();
  Out out = {0};
  out_refresh(&out, rig->service, place, outer);
  wx_service_test_set_deadline_ms(100);
  drain_ms(400);
  g_assert_cmpuint(out.calls, ==, 0); /* still waiting: it keeps the 10 s it started with */
  g_cancellable_cancel(outer);
  out_wait(&out);
  assert_cancelled(&out);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Cancellation                                                             */
/* ------------------------------------------------------------------------ */

static void
test_cancel_pre_cancelled(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *a = rig_add(rig, "fake-a", 10.0);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();
  g_cancellable_cancel(outer);

  Out out = {0};
  run_refresh(&out, rig->service, place, outer);
  assert_cancelled(&out);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(a), ==, 0); /* no provider was called */
  out_clear(&out);

  /* cancellation is checked before anything else: an invalid place or no provider is not seen */
  WxPlace bad = {.name = NULL, .lat = NAN};
  run_refresh(&out, rig->service, &bad, outer);
  assert_cancelled(&out);
  out_clear(&out);
  g_autoptr(Rig) empty = rig_new();
  run_refresh(&out, empty->service, place, outer);
  assert_cancelled(&out);
  out_clear(&out);
}

static void
test_cancel_in_flight(void)
{
  g_autoptr(Rig) rig = rig_new();
  WxFakeProvider *hang = rig_add_hang(rig, "fake-a");
  g_autoptr(TestProv) hold = test_prov_new("hold-b");
  hold->mode = TP_HOLD;
  rig_add_prov(rig, hold);
  rig_add(rig, "fake-c", 30.0);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();

  Out out = {0};
  out_refresh(&out, rig->service, place, outer);
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 0);
  g_assert_false(g_cancellable_is_cancelled(hold->seen));
  out.in_call = TRUE; /* the callback must not run inside g_cancellable_cancel() */
  g_cancellable_cancel(outer);
  out.in_call = FALSE;
  g_assert_cmpuint(out.calls, ==, 0);
  out_wait(&out);
  assert_cancelled(&out);
  g_assert_cmpint(elapsed_ms(&out), <, 5000); /* nowhere near the deadline */
  g_assert_true(g_cancellable_is_cancelled(hold->seen)); /* the children were told to stop */
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(hang), ==, 1);
  g_assert_cmpuint(hold->held->len, ==, 1); /* ... though this one never answers */
  test_prov_release(hold);
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 1);
  g_cancellable_cancel(outer); /* cancelling again changes nothing */
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 1);
  out_clear(&out);
}

/* The caller's cancellable is cancelled before finish: cancelled, even if the refresh worked. */
static void
on_keep(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)source;
  GAsyncResult **kept = user_data;
  g_assert_null(*kept);
  *kept = g_object_ref(result);
}

static void
test_cancel_after_completion(void)
{
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();

  GAsyncResult *kept = NULL;
  wx_service_refresh_async(rig->service, place, outer, on_keep, &kept);
  SPIN_UNTIL(kept != NULL);
  g_cancellable_cancel(outer);
  g_autoptr(GError) error = NULL;
  WxForecast *forecast = wx_service_refresh_finish(rig->service, kept, &error);
  g_assert_null(forecast);
  g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_object_unref(kept);

  /* without the cancellation the same refresh delivers its forecast */
  g_autoptr(GCancellable) calm = g_cancellable_new();
  kept = NULL;
  wx_service_refresh_async(rig->service, place, calm, on_keep, &kept);
  SPIN_UNTIL(kept != NULL);
  g_clear_error(&error);
  forecast = wx_service_refresh_finish(rig->service, kept, &error);
  g_assert_no_error(error);
  g_assert_nonnull(forecast);
  wx_forecast_unref(forecast);
  g_object_unref(kept);
}

/* A provider that ignores cancellation does not hold a cancelled refresh up. */
static void
test_cancel_ignoring_provider(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) hold = test_prov_new("hold-a");
  hold->mode = TP_HOLD;
  g_autoptr(WxMember) member = make_member("hold-a", 20.0);
  test_prov_add_member(hold, member);
  rig_add_prov(rig, hold);
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();
  Out out = {0};
  out_refresh(&out, rig->service, place, outer);
  g_cancellable_cancel(outer);
  out_wait(&out);
  assert_cancelled(&out);
  g_assert_cmpint(elapsed_ms(&out), <, 5000);
  test_prov_release(hold);
  drain_ms(30);
  g_assert_true(g_atomic_ref_count_compare(&member->ref_count, 2)); /* delivered late, freed */
  g_assert_cmpuint(out.calls, ==, 1);
  out_clear(&out);
}

static gpointer
cancel_after_delay(gpointer user_data)
{
  g_usleep(40 * 1000);
  g_cancellable_cancel(user_data);
  return NULL;
}

/* Cancelling from another thread is safe: the refresh ends in the main thread. */
static void
test_cancel_from_thread(void)
{
  g_autoptr(Rig) rig = rig_new();
  rig_add_hang(rig, "fake-a");
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();
  Out out = {0};
  out_refresh(&out, rig->service, place, outer);
  GThread *thread = g_thread_new("canceller", cancel_after_delay, outer);
  out_wait(&out);
  g_thread_join(thread);
  assert_cancelled(&out);
  g_assert_true(out.callback_thread == g_thread_self());
  out_clear(&out);
}

/* The deadline cancels the stragglers, not the caller's cancellable. */
static void
test_cancel_deadline_leaves_caller_alone(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  rig_add_hang(rig, "fake-b");
  g_autoptr(WxPlace) place = miami();
  g_autoptr(GCancellable) outer = g_cancellable_new();
  Out out = {0};
  run_refresh(&out, rig->service, place, outer);
  assert_succeeded(&out);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0);
  g_assert_false(g_cancellable_is_cancelled(outer));
  out_clear(&out);
  /* the same cancellable serves another refresh */
  run_refresh(&out, rig->service, place, outer);
  assert_succeeded(&out);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Dispose in flight                                                        */
/* ------------------------------------------------------------------------ */

/* The callback runs with the service still alive although the caller let go of every reference. */
static void
check_service_alive(Out *out, WxService *service)
{
  g_assert_true(WX_IS_SERVICE(service));
  g_assert_nonnull(*(gpointer *)out->after_data);
}

static void
test_dispose_last_reference(void)
{
  Rig *rig = rig_new();
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-a", 10.0), 40);
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-b", 30.0), 60);
  gpointer weak_service = rig->service;
  g_object_add_weak_pointer(G_OBJECT(rig->service), &weak_service);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  out.after = check_service_alive;
  out.after_data = &weak_service;
  out_refresh(&out, rig->service, place, NULL);
  rig_free(rig); /* the service, the registry and the fakes lose the caller's references */
  g_assert_nonnull(weak_service); /* the operation keeps the service alive ... */
  out_wait(&out);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_OK, -1, 1);
  SPIN_UNTIL(weak_service == NULL); /* ... and lets go when the callback has returned */
  out_clear(&out);
}

/* g_object_run_dispose() in flight changes nothing: the operation completes, the service works. */
static void
test_dispose_run_dispose(void)
{
  g_autoptr(Rig) rig = rig_new();
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-a", 10.0), 40);
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  g_autoptr(WxPlace) place = miami();
  wx_fake_geocoder_add_hit(geo, place);
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));

  Out out = {0};
  out_refresh(&out, rig->service, place, NULL);
  g_object_run_dispose(G_OBJECT(rig->service));
  out_wait(&out);
  assert_succeeded(&out);
  out_clear(&out);
  run_refresh(&out, rig->service, place, NULL); /* still usable afterwards */
  assert_succeeded(&out);
  out_clear(&out);
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(out.hits->len, ==, 1);
  out_clear(&out);
}

/* A fetch that delivers after the refresh is over and the service is gone only frees memory. */
static void
test_dispose_late_completion(void)
{
  wx_service_test_set_deadline_ms(300);
  Rig *rig = rig_new();
  g_autoptr(WxMember) late_member = make_member("hold-a", 25.0);
  g_autoptr(TestProv) hold = test_prov_new("hold-a");
  hold->mode = TP_HOLD;
  test_prov_add_member(hold, late_member);
  rig_add_prov(rig, hold);
  rig_add(rig, "fake-b", 10.0);
  gpointer weak_service = rig->service;
  g_object_add_weak_pointer(G_OBJECT(rig->service), &weak_service);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  out_clear(&out);
  rig_free(rig);
  SPIN_UNTIL(weak_service == NULL); /* the service is gone, the provider still owes its answer */
  g_assert_cmpuint(hold->held->len, ==, 1);
  test_prov_release(hold);
  drain_ms(50);
  g_assert_true(g_atomic_ref_count_compare(&late_member->ref_count, 2)); /* freed, unread */
}

/* Dropping the caller's registry reference in flight is harmless: the service has its own. */
static void
test_dispose_registry_dropped(void)
{
  WxRegistry *registry = wx_registry_new();
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("fake-a");
  g_autoptr(WxMember) member = make_member("fake-a", 10.0);
  wx_fake_provider_add_member(fake, member);
  wx_fake_provider_set_delay_ms(fake, 40);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(fake), NULL));
  g_autoptr(WxService) service = wx_service_new(registry);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  out_refresh(&out, service, place, NULL);
  g_object_unref(registry);
  out_wait(&out);
  assert_succeeded(&out);
  out_clear(&out);
  run_refresh(&out, service, place, NULL); /* the registry lives on inside the service */
  assert_succeeded(&out);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Re-entrancy                                                              */
/* ------------------------------------------------------------------------ */

typedef struct {
  WxPlace *place;
  Out outs[5];
  guint next;
} Chain;

static void
chain_after(Out *out, WxService *service)
{
  Chain *chain = out->after_data;
  chain->next++;
  if (chain->next < G_N_ELEMENTS(chain->outs))
    out_refresh(&chain->outs[chain->next], service, chain->place, NULL);
}

/* A callback may start the next refresh: five in a row, one after the other. */
static void
test_reentrancy_refresh_from_callback(void)
{
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  rig_add(rig, "fake-b", 20.0);
  g_autoptr(WxPlace) place = miami();
  Chain chain = {.place = place};
  for (guint i = 0; i < G_N_ELEMENTS(chain.outs); i++) {
    chain.outs[i].after = chain_after;
    chain.outs[i].after_data = &chain;
  }
  out_refresh(&chain.outs[0], rig->service, place, NULL);
  SPIN_UNTIL(chain.next == G_N_ELEMENTS(chain.outs));
  drain_ms(30);
  for (guint i = 0; i < G_N_ELEMENTS(chain.outs); i++) {
    g_assert_cmpuint(chain.outs[i].calls, ==, 1);
    assert_succeeded(&chain.outs[i]);
    out_clear(&chain.outs[i]);
  }
}

typedef struct {
  WxService *owned;
  gpointer weak;
} Drop;

/* Drops the caller's last reference to the service inside the callback. */
static void
drop_service(Out *out, WxService *service)
{
  Drop *drop = out->after_data;
  g_assert_true(service == drop->owned);
  g_object_unref(drop->owned);
  drop->owned = NULL;
  g_assert_nonnull(drop->weak); /* the task still holds the service while the callback runs */
  g_assert_true(WX_IS_SERVICE(service));
}

static void
test_reentrancy_drop_service_in_callback(void)
{
  WxRegistry *registry = wx_registry_new();
  g_autoptr(WxFakeProvider) fake = wx_fake_provider_new("fake-a");
  g_autoptr(WxMember) member = make_member("fake-a", 10.0);
  wx_fake_provider_add_member(fake, member);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(fake), NULL));
  Drop drop = {.owned = wx_service_new(registry)};
  g_object_unref(registry);
  drop.weak = drop.owned;
  g_object_add_weak_pointer(G_OBJECT(drop.owned), &drop.weak);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  out.after = drop_service;
  out.after_data = &drop;
  out_refresh(&out, drop.owned, place, NULL);
  out_wait(&out);
  assert_succeeded(&out);
  SPIN_UNTIL(drop.weak == NULL);
  out_clear(&out);

  /* the same with a refresh that ends by the deadline, so the callback runs in the timer */
  wx_service_test_set_deadline_ms(100);
  registry = wx_registry_new();
  g_autoptr(WxFakeProvider) hang = wx_fake_provider_new("fake-h");
  wx_fake_provider_set_delay_ms(hang, G_MAXUINT);
  g_assert_true(wx_registry_add_provider(registry, WX_PROVIDER(hang), NULL));
  drop.owned = wx_service_new(registry);
  g_object_unref(registry);
  drop.weak = drop.owned;
  g_object_add_weak_pointer(G_OBJECT(drop.owned), &drop.weak);
  out_refresh(&out, drop.owned, place, NULL);
  out_wait(&out);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_TIMEOUT);
  SPIN_UNTIL(drop.weak == NULL);
  out_clear(&out);
}

/* A covers() that changes the registry while it is being walked. */
static void
covers_changes_registry(gpointer instance, gpointer data)
{
  TestProv *prov = instance;
  Rig *rig = data;
  if (prov->covers_calls != 1)
    return;
  g_assert_true(wx_registry_set_enabled(rig->registry, "prov-b", FALSE));
  rig_add(rig, "fake-c", 30.0);
}

static void
test_reentrancy_registry_changes_in_covers(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) a = test_prov_new("prov-a");
  g_autoptr(TestProv) b = test_prov_new("prov-b");
  g_autoptr(WxMember) ma = make_member("prov-a", 10.0);
  g_autoptr(WxMember) mb = make_member("prov-b", 20.0);
  test_prov_add_member(a, ma);
  test_prov_add_member(b, mb);
  a->on_covers = covers_changes_registry;
  a->hook_data = rig;
  rig_add_prov(rig, a);
  rig_add_prov(rig, b);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  /* b was disabled before it was visited, c was added meanwhile and is visited and listed */
  g_assert_cmpuint(out.forecast->n_sources, ==, 3);
  assert_status(out.forecast, 0, "prov-a", WX_SRC_OK, -1, 1);
  assert_status(out.forecast, 1, "prov-b", WX_SRC_SKIPPED, -1, 0);
  assert_status(out.forecast, 2, "fake-c", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(a->fetches, ==, 1);
  g_assert_cmpuint(b->fetches, ==, 0);
  g_assert_cmpuint(b->covers_calls, ==, 0);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(g_ptr_array_index(rig->fakes, 0)), ==, 1);
  out_clear(&out);
}

/* Providers that call back inside fetch_async (the interface forbids it) are tolerated. */
static void
test_reentrancy_synchronous_provider(void)
{
  g_autoptr(WxPlace) place = miami();
  {
    /* one synchronous provider and one that has not answered yet: the refresh waits for it */
    g_autoptr(Rig) rig = rig_new();
    g_autoptr(TestProv) sync = test_prov_new("sync-a");
    sync->mode = TP_SYNC;
    g_autoptr(WxMember) member = make_member("sync-a", 10.0);
    test_prov_add_member(sync, member);
    rig_add_prov(rig, sync);
    g_autoptr(TestProv) slow = test_prov_new("hold-b");
    slow->mode = TP_HOLD;
    g_autoptr(WxMember) slow_member = make_member("hold-b", 30.0);
    test_prov_add_member(slow, slow_member);
    rig_add_prov(rig, slow);
    Out out = {0};
    out_refresh(&out, rig->service, place, NULL);
    g_assert_cmpuint(sync->fetches, ==, 1);
    g_assert_cmpuint(slow->held->len, ==, 1);
    drain_ms(20);
    g_assert_cmpuint(out.calls, ==, 0);
    test_prov_release(slow);
    out_wait(&out);
    assert_succeeded(&out);
    g_assert_cmpint(elapsed_ms(&out), <, 5000); /* not at the 30 s deadline */
    assert_status(out.forecast, 0, "sync-a", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "hold-b", WX_SRC_OK, -1, 1);
    out_clear(&out);
  }
  {
    /* only synchronous providers, one of them failing: still no callback before the call returns */
    g_autoptr(Rig) rig = rig_new();
    g_autoptr(TestProv) s1 = test_prov_new("sync-a");
    g_autoptr(TestProv) s2 = test_prov_new("sync-b");
    g_autoptr(TestProv) s3 = test_prov_new("sync-c");
    s1->mode = s2->mode = s3->mode = TP_SYNC;
    g_autoptr(WxMember) m1 = make_member("sync-a", 10.0);
    g_autoptr(WxMember) m3 = make_member("sync-c", 30.0);
    test_prov_add_member(s1, m1);
    test_prov_add_member(s3, m3);
    test_prov_fail(s2, g_error_new_literal(WX_ERROR, WX_ERROR_HTTP, "sync failure"));
    rig_add_prov(rig, s1);
    rig_add_prov(rig, s2);
    rig_add_prov(rig, s3);
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_succeeded(&out);
    g_assert_cmpint(elapsed_ms(&out), <, 5000);
    assert_status(out.forecast, 0, "sync-a", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "sync-b", WX_SRC_FAILED, WX_ERROR_HTTP, 0);
    assert_status(out.forecast, 2, "sync-c", WX_SRC_OK, -1, 1);
    out_clear(&out);
  }
  {
    /* all synchronous and all failing */
    g_autoptr(Rig) rig = rig_new();
    g_autoptr(TestProv) s1 = test_prov_new("sync-a");
    s1->mode = TP_SYNC;
    test_prov_fail(s1, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "bad"));
    rig_add_prov(rig, s1);
    Out out = {0};
    run_refresh(&out, rig->service, place, NULL);
    assert_failed(&out, WX_ERROR_PARSE, "sync-a: bad");
    g_assert_cmpint(elapsed_ms(&out), <, 5000);
    out_clear(&out);
  }
}

static void
cancel_and_spin(gpointer instance, gpointer data)
{
  (void)instance;
  g_cancellable_cancel(data);
  while (g_main_context_iteration(NULL, FALSE))
    ;
}

/*
 * A provider that runs the main loop inside fetch_async (it should not) while the caller cancels:
 * the refresh completes in the middle of starting, the providers not started yet are not started.
 */
static void
test_reentrancy_cancel_during_start(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(GCancellable) outer = g_cancellable_new();
  g_autoptr(TestProv) first = test_prov_new("prov-a");
  g_autoptr(WxMember) member = make_member("prov-a", 10.0);
  test_prov_add_member(first, member);
  first->on_fetch = cancel_and_spin;
  first->hook_data = outer;
  rig_add_prov(rig, first);
  WxFakeProvider *second = rig_add(rig, "fake-b", 20.0);
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  /* no in_call guard: the nested loop runs the callback before wx_service_refresh_async returns */
  wx_service_refresh_async(rig->service, place, outer, on_refresh_done, &out);
  g_assert_cmpuint(out.calls, ==, 1);
  assert_cancelled(&out);
  g_assert_cmpuint(first->fetches, ==, 1);
  g_assert_cmpuint(wx_fake_provider_get_fetch_count(second), ==, 0); /* never started */
  drain_ms(30); /* the first provider's late answer is freed */
  g_assert_cmpuint(out.calls, ==, 1);
  g_assert_true(g_atomic_ref_count_compare(&member->ref_count, 2));
  out_clear(&out);
}

typedef struct {
  WxService *service;
  WxPlace *place;
  Out *inner;
} Nested;

/* Starts a second refresh from inside the first provider's fetch_async (once). */
static void
start_nested_refresh(gpointer instance, gpointer data)
{
  TestProv *prov = instance;
  Nested *nested = data;
  if (prov->fetches != 1)
    return;
  out_refresh(nested->inner, nested->service, nested->place, NULL);
}

static void
test_reentrancy_refresh_from_provider(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestProv) first = test_prov_new("prov-a");
  g_autoptr(WxMember) member = make_member("prov-a", 10.0);
  test_prov_add_member(first, member);
  g_autoptr(WxPlace) place = miami();
  Out inner = {0};
  Nested nested = {rig->service, place, &inner};
  first->on_fetch = start_nested_refresh;
  first->hook_data = &nested;
  rig_add_prov(rig, first);
  rig_add(rig, "fake-b", 20.0);

  Out outer = {0};
  out_refresh(&outer, rig->service, place, NULL);
  out_wait(&outer);
  SPIN_UNTIL(inner.calls > 0);
  assert_succeeded(&outer);
  assert_succeeded(&inner);
  g_assert_cmpuint(first->fetches, ==, 2);
  g_assert_cmpuint(outer.forecast->n_sources, ==, 2);
  g_assert_cmpuint(inner.forecast->n_sources, ==, 2);
  out_clear(&outer);
  out_clear(&inner);
}

/* ------------------------------------------------------------------------ */
/* Main context, limits                                                     */
/* ------------------------------------------------------------------------ */

/* The operation lives in the thread-default context of the caller, not in the default one. */
static void
test_private_context(void)
{
  wx_service_test_set_deadline_ms(300);
  g_autoptr(GMainContext) context = g_main_context_new();
  g_main_context_push_thread_default(context);
  Rig *rig = rig_new();
  wx_fake_provider_set_delay_ms(rig_add(rig, "fake-a", 10.0), 20);
  rig_add_hang(rig, "fake-b");
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  out_refresh(&out, rig->service, place, NULL);
  drain_ms(60); /* the default context sees nothing of it */
  g_assert_cmpuint(out.calls, ==, 0);
  gint64 limit_us = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
  while (out.calls == 0 && g_get_monotonic_time() < limit_us)
    g_main_context_iteration(context, TRUE);
  g_assert_cmpuint(out.calls, ==, 1);
  assert_succeeded(&out);
  assert_status(out.forecast, 1, "fake-b", WX_SRC_FAILED, WX_ERROR_TIMEOUT, 0); /* its deadline */
  out_clear(&out);

  /* cancellation is watched in the same context */
  g_autoptr(GCancellable) outer = g_cancellable_new();
  wx_service_test_set_deadline_ms(0);
  out_refresh(&out, rig->service, place, outer);
  g_cancellable_cancel(outer);
  limit_us = g_get_monotonic_time() + 20 * G_USEC_PER_SEC;
  while (out.calls == 0 && g_get_monotonic_time() < limit_us)
    g_main_context_iteration(context, TRUE);
  g_assert_cmpuint(out.calls, ==, 1);
  assert_cancelled(&out);
  out_clear(&out);
  while (g_main_context_iteration(context, FALSE))
    ;
  rig_free(rig);
  while (g_main_context_iteration(context, FALSE))
    ;
  g_main_context_pop_thread_default(context);
}

/* As many providers as the registry takes, and a provider with more members than the blend uses. */
static void
test_refresh_limits(void)
{
  g_autoptr(Rig) rig = rig_new();
  for (guint i = 0; i < WX_REGISTRY_MAX_PROVIDERS; i++) {
    g_autofree char *id = g_strdup_printf("fake-%02u", i);
    rig_add(rig, id, 10.0 + i);
  }
  g_autoptr(WxFakeProvider) extra = wx_fake_provider_new("fake-extra");
  g_autoptr(GError) error = NULL;
  g_assert_false(wx_registry_add_provider(rig->registry, WX_PROVIDER(extra), &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
  g_autoptr(WxPlace) place = miami();
  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  g_assert_cmpuint(out.forecast->n_sources, ==, WX_REGISTRY_MAX_PROVIDERS);
  for (guint i = 0; i < WX_REGISTRY_MAX_PROVIDERS; i++) {
    g_autofree char *id = g_strdup_printf("fake-%02u", i);
    assert_status(out.forecast, i, id, WX_SRC_OK, -1, 1);
  }
  g_autoptr(GPtrArray) results = rig_results(rig, WX_REGISTRY_MAX_PROVIDERS);
  assert_matches_oracle(out.forecast, place, results);
  out_clear(&out);

  /* one provider returning 200 members: the blend takes 128, so 128 are forwarded and counted */
  g_autoptr(Rig) many = rig_new();
  g_autoptr(WxFakeProvider) big = wx_fake_provider_new("fake-big");
  for (guint i = 0; i < 200; i++) {
    g_autofree char *model = g_strdup_printf("m%u", i);
    g_autoptr(WxMember) member = make_member_n("fake-big", model, 10.0 + (i % 20), 48);
    wx_fake_provider_add_member(big, member);
  }
  g_assert_true(wx_registry_add_provider(many->registry, WX_PROVIDER(big), NULL));
  run_refresh(&out, many->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-big", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS);
  g_assert_cmpuint(out.forecast->hours[0].n_members, ==, WX_BLEND_MAX_MEMBERS);
  out_clear(&out);
}

/* ------------------------------------------------------------------------ */
/* Refresh: the members that reach the blend (usable, distinct, fair share) */
/* ------------------------------------------------------------------------ */

/*
 * Members the service must not hand to the blend. GB_BAD_SOURCE_ID .. GB_HOURS_NO_ARRAY are
 * hand-built garbage that the blend rejects as a whole (wx-blend.h); GB_NO_DATA ..
 * GB_QUARTERS_TOO_MANY are valid for the blend but carry nothing it can use.
 */
typedef enum {
  GB_BAD_SOURCE_ID,    /* source id "Bad Id" */
  GB_BAD_MODEL_ID,     /* model id "" */
  GB_HOURS_UNALIGNED,  /* an hour stamp that is not a multiple of 3600 */
  GB_HOURS_DESCENDING, /* an hour that is not after the one before */
  GB_HOURS_DUPLICATE,  /* two hours with the same stamp */
  GB_HOURS_TOO_EARLY,  /* first stamp WX_TIME_MIN_S - 3600 */
  GB_HOURS_TOO_LATE,   /* last stamp WX_TIME_MAX_S (a multiple of 3600) */
  GB_HOURS_INT64_MAX,  /* last stamp G_MAXINT64 */
  GB_HOURS_INT64_MIN,  /* first stamp G_MININT64 */
  GB_HOURS_TOO_MANY,   /* n_hours = WX_MEMBER_MAX_HOURS + 1 over a shorter array */
  GB_HOURS_NO_ARRAY,   /* n_hours 5, hours NULL */
  GB_NO_DATA,          /* no hour, no quarter */
  GB_QUARTERS_NO_ARRAY,/* n_quarters 5, quarters NULL */
  GB_QUARTERS_TOO_MANY,/* n_quarters = WX_MEMBER_MAX_QUARTERS + 1 over a shorter array */
  GB_COUNT
} Garbage;

/* The first kind that is valid for the blend (but has nothing to use). */
#define GB_FIRST_VALID GB_NO_DATA

/* A hand-built member of @kind with the ids @source and @model (before the kind alters them). */
static WxMember *
make_garbage(Garbage kind, const char *source, const char *model)
{
  WxMember *m = (kind >= GB_NO_DATA || kind == GB_HOURS_NO_ARRAY)
                    ? wx_member_new(source, model, now_s(), NULL)
                    : make_member_n(source, model, 20.0, 12);
  g_assert_nonnull(m);
  WxHour *hours = (WxHour *)m->hours;
  switch (kind) {
  case GB_BAD_SOURCE_ID:
    g_free((char *)m->source_id);
    m->source_id = g_strdup("Bad Id");
    break;
  case GB_BAD_MODEL_ID:
    g_free((char *)m->model_id);
    m->model_id = g_strdup("");
    break;
  case GB_HOURS_UNALIGNED:
    hours[3].t_s += 1;
    break;
  case GB_HOURS_DESCENDING:
    hours[5].t_s = hours[3].t_s;
    break;
  case GB_HOURS_DUPLICATE:
    hours[4].t_s = hours[3].t_s;
    break;
  case GB_HOURS_TOO_EARLY:
    hours[0].t_s = WX_TIME_MIN_S - 3600;
    break;
  case GB_HOURS_TOO_LATE:
    hours[11].t_s = WX_TIME_MAX_S;
    break;
  case GB_HOURS_INT64_MAX:
    hours[11].t_s = G_MAXINT64;
    break;
  case GB_HOURS_INT64_MIN:
    hours[0].t_s = G_MININT64;
    break;
  case GB_HOURS_TOO_MANY: {
    /* an array of exactly 12 valid hours: reading a 13th would run over the allocation */
    WxHour *exact = g_memdup2(m->hours, 12 * sizeof(WxHour));
    g_free(hours);
    m->hours = exact;
    m->n_hours = WX_MEMBER_MAX_HOURS + 1;
    break;
  }
  case GB_HOURS_NO_ARRAY:
    m->n_hours = 5;
    break;
  case GB_NO_DATA:
    break;
  case GB_QUARTERS_NO_ARRAY:
    m->n_quarters = 5;
    break;
  case GB_QUARTERS_TOO_MANY: {
    WxQuarter quarter = {now_s() / 900 * 900, 0.5};
    g_assert_true(wx_member_add_quarter(m, &quarter));
    m->n_quarters = WX_MEMBER_MAX_QUARTERS + 1;
    break;
  }
  case GB_COUNT:
    g_assert_not_reached();
  }
  return m;
}

/* One member of a provider's scripted answer, with what the model of the rule knows about it. */
typedef struct {
  WxMember *member;     /* owned reference */
  gboolean usable;      /* the blend takes part in it and it has hours or quarters */
  gboolean long_enough; /* it has at least WX_BLEND_MIN_HOURS hours the blend takes */
  gboolean blend_valid; /* the blend takes part in it (it may have no data) */
  gint64 mark_t;        /* the one hour of a member made by spec_add_mark(), else 0 */
} SpecMember;

static void
spec_member_clear(gpointer data)
{
  wx_member_unref(((SpecMember *)data)->member);
}

/* A provider's scripted answer: a GArray of SpecMember in answer order. */
static GArray *
spec_new(void)
{
  GArray *spec = g_array_new(FALSE, TRUE, sizeof(SpecMember));
  g_array_set_clear_func(spec, spec_member_clear);
  return spec;
}

/* Appends @member (taken). */
static void
spec_add(GArray *spec, WxMember *member, gboolean usable, gboolean long_enough,
         gboolean blend_valid)
{
  SpecMember entry = {member, usable, long_enough, blend_valid, 0};
  g_array_append_val(spec, entry);
}

/* A valid member of @source and model "m<model>" with @n_hours hours at @temp_c. */
static void
spec_add_hours(GArray *spec, const char *source, guint model, double temp_c, guint n_hours)
{
  g_autofree char *name = g_strdup_printf("m%03u", model);
  spec_add(spec, make_member_n(source, name, temp_c, n_hours), TRUE, n_hours >= WX_BLEND_MIN_HOURS,
           TRUE);
}

/* A valid member of one quarter and no hour (like the nowcast member). */
static void
spec_add_quarters(GArray *spec, const char *source, guint model)
{
  g_autofree char *name = g_strdup_printf("m%03u", model);
  WxMember *member = wx_member_new(source, name, now_s(), NULL);
  g_assert_nonnull(member);
  WxQuarter quarter = {now_s() / 900 * 900, 0.5};
  g_assert_true(wx_member_add_quarter(member, &quarter));
  spec_add(spec, member, TRUE, FALSE, TRUE);
}

/*
 * A valid member with a single hour, at @t_s, that no other member has: whether the member reached
 * the blend can be read off the blended hour starting at @t_s (n_members 1 or 0).
 */
static void
spec_add_mark(GArray *spec, const char *source, guint model, gint64 t_s)
{
  g_autofree char *name = g_strdup_printf("m%03u", model);
  WxMember *member = wx_member_new(source, name, now_s(), NULL);
  g_assert_nonnull(member);
  WxHour hour;
  wx_hour_init(&hour);
  hour.t_s = t_s;
  hour.temp_c = 20.0;
  hour.humidity_pct = 50.0;
  g_assert_true(wx_member_add_hour(member, &hour));
  SpecMember entry = {member, TRUE, FALSE, TRUE, t_s};
  g_array_append_val(spec, entry);
}

/* A member that must not reach the blend. */
static void
spec_add_garbage(GArray *spec, Garbage kind, const char *source, guint model)
{
  g_autofree char *name = g_strdup_printf("m%03u", model);
  spec_add(spec, make_garbage(kind, source, name), FALSE, FALSE, kind >= GB_FIRST_VALID);
}

static void
specs_free(GArray **specs, guint n)
{
  for (guint i = 0; i < n; i++)
    g_array_unref(specs[i]);
}

/* What the rule forwards for one provider. */
typedef struct {
  guint n_usable;    /* usable members the provider returned */
  GPtrArray *chosen; /* const SpecMember*, borrowed from the spec: the forwarded ones */
} Plan;

static gboolean
same_ids(const WxMember *a, const WxMember *b)
{
  return strcmp(a->source_id, b->source_id) == 0 && strcmp(a->model_id, b->model_id) == 0;
}

/* Sum over the providers of min(length of the distinct list, @cap). */
static guint
capped_sum(GPtrArray **distinct, guint n, guint cap)
{
  guint sum = 0;
  for (guint i = 0; i < n; i++)
    sum += MIN(distinct[i]->len, cap);
  return sum;
}

/* TRUE iff the lists distinct[0 .. last] hold a member with the ids of @member. */
static gboolean
listed(GPtrArray **distinct, guint last, const WxMember *member)
{
  for (guint j = 0; j <= last; j++) {
    for (guint x = 0; x < distinct[j]->len; x++) {
      const SpecMember *other = g_ptr_array_index(distinct[j], x);
      if (same_ids(member, other->member))
        return TRUE;
    }
  }
  return FALSE;
}

/*
 * The documented rule (wx-service.h, "Members handed to the blend"), written without sharing
 * anything with the service: the usable members are decided by the construction of the members
 * (SpecMember.usable), duplicates are found by nested loops, and the share is computed in closed
 * form (the largest r such that every provider's first r members fit, then the remaining places
 * go to the first providers that have more) instead of dealing one member at a time.
 */
static Plan *
plan_forwarding(GArray **specs, guint n)
{
  Plan *plans = g_new0(Plan, n);
  GPtrArray **distinct = g_new0(GPtrArray *, n);
  for (guint i = 0; i < n; i++) {
    distinct[i] = g_ptr_array_new();
    for (guint k = 0; k < specs[i]->len; k++) {
      const SpecMember *entry = &g_array_index(specs[i], SpecMember, k);
      if (!entry->usable)
        continue;
      plans[i].n_usable++;
      if (!listed(distinct, i, entry->member))
        g_ptr_array_add(distinct[i], (gpointer)entry);
    }
  }

  guint longest = 0;
  for (guint i = 0; i < n; i++)
    longest = MAX(longest, distinct[i]->len);
  guint r = 0;
  while (r < longest && capped_sum(distinct, n, r + 1) <= WX_BLEND_MAX_MEMBERS)
    r++;
  guint used = capped_sum(distinct, n, r);
  for (guint i = 0; i < n; i++) {
    guint share = MIN(distinct[i]->len, r);
    if (used < WX_BLEND_MAX_MEMBERS && distinct[i]->len > r) {
      share++;
      used++;
    }
    plans[i].chosen = g_ptr_array_new();
    for (guint k = 0; k < share; k++)
      g_ptr_array_add(plans[i].chosen, g_ptr_array_index(distinct[i], k));
    g_ptr_array_unref(distinct[i]);
  }
  g_free(distinct);
  return plans;
}

static void
plans_free(Plan *plans, guint n)
{
  for (guint i = 0; i < n; i++)
    g_ptr_array_unref(plans[i].chosen);
  g_free(plans);
}

/* The blend's oracle input for the forwarded members: one result per provider that has some. */
static GPtrArray *
chosen_results(const Plan *plans, guint n)
{
  GPtrArray *results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  for (guint i = 0; i < n; i++) {
    if (plans[i].chosen->len == 0)
      continue;
    g_autofree char *id = g_strdup_printf("fake-%02u", i);
    WxSourceResult *result = wx_source_result_new(id, NULL);
    g_assert_nonnull(result);
    for (guint k = 0; k < plans[i].chosen->len; k++) {
      const SpecMember *entry = g_ptr_array_index(plans[i].chosen, k);
      g_ptr_array_add(result->members, wx_member_ref(entry->member));
    }
    g_ptr_array_add(results, result);
  }
  return results;
}

/* The blend's oracle input for everything the providers answered, as it came. */
static GPtrArray *
raw_results(GArray **specs, guint n)
{
  GPtrArray *results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  for (guint i = 0; i < n; i++) {
    g_autofree char *id = g_strdup_printf("fake-%02u", i);
    WxSourceResult *result = wx_source_result_new(id, NULL);
    g_assert_nonnull(result);
    for (guint k = 0; k < specs[i]->len; k++)
      g_ptr_array_add(result->members,
                      wx_member_ref(g_array_index(specs[i], SpecMember, k).member));
    g_ptr_array_add(results, result);
  }
  return results;
}

/* The blended hour starting at @t_s, or NULL. */
static const WxBlendHour *
hour_at_t(const WxForecast *forecast, gint64 t_s)
{
  for (guint i = 0; i < forecast->n_hours; i++) {
    if (forecast->hours[i].t_s == t_s)
      return &forecast->hours[i];
  }
  return NULL;
}

/* The first hour of the member at @index of @spec. */
static gint64
first_hour_of(GArray *spec, guint index)
{
  const WxMember *member = g_array_index(spec, SpecMember, index).member;
  g_assert_cmpuint(member->n_hours, >, 0);
  return member->hours[0].t_s;
}

/* The largest number of members that contribute to one blended hour. */
static guint
max_members(const WxForecast *forecast)
{
  guint most = 0;
  for (guint i = 0; i < forecast->n_hours; i++)
    most = MAX(most, forecast->hours[i].n_members);
  return most;
}

/*
 * TRUE iff a member that the blend would take part in although it has no data comes, in the order
 * the blend sees (provider by provider), before a member with the same ids: the blend alone then
 * keeps the empty one and drops the other, which the service (that drops the empty one first)
 * deliberately does not.
 */
static gboolean
empty_shadows_later(GArray **specs, guint n)
{
  for (guint i = 0; i < n; i++) {
    for (guint k = 0; k < specs[i]->len; k++) {
      const SpecMember *empty = &g_array_index(specs[i], SpecMember, k);
      if (!empty->blend_valid || empty->usable)
        continue;
      for (guint j = i; j < n; j++) {
        for (guint x = (j == i ? k + 1 : 0); x < specs[j]->len; x++) {
          const SpecMember *later = &g_array_index(specs[j], SpecMember, x);
          if (later->usable && same_ids(empty->member, later->member))
            return TRUE;
        }
      }
    }
  }
  return FALSE;
}

/*
 * Checks a finished refresh of the providers scripted by @specs (ids fake-00, fake-01, ...)
 * against the model of the rule: the statuses, the forecast (the blend of the forwarded members
 * must give the same hours, quarters and days), and, when the providers answered no more members
 * than the blend takes, the blend of everything as it came.
 */
static void
check_share(const Out *out, GArray **specs, guint n)
{
  Plan *plans = plan_forwarding(specs, n);
  gboolean any_long = FALSE, any_failed = FALSE;
  guint first_failed = 0, raw_total = 0;
  for (guint i = 0; i < n; i++) {
    raw_total += specs[i]->len;
    if (plans[i].n_usable == 0 && !any_failed) {
      any_failed = TRUE;
      first_failed = i;
    }
    for (guint k = 0; k < plans[i].chosen->len; k++) {
      const SpecMember *entry = g_ptr_array_index(plans[i].chosen, k);
      any_long = any_long || entry->long_enough;
    }
  }
  g_autoptr(WxPlace) place = miami();
  if (!any_long) {
    /* a provider that returned nothing usable fails with NOT_FOUND and beats the blend's own */
    g_autofree char *message = any_failed ? g_strdup_printf("fake-%02u: the provider returned no "
                                                            "forecast data", first_failed)
                                          : g_strdup("no usable forecast data");
    assert_failed(out, WX_ERROR_NOT_FOUND, message);
  } else {
    assert_succeeded(out);
    g_assert_cmpuint(out->forecast->n_sources, ==, n);
    for (guint i = 0; i < n; i++) {
      g_autofree char *id = g_strdup_printf("fake-%02u", i);
      if (plans[i].n_usable > 0)
        assert_status(out->forecast, i, id, WX_SRC_OK, -1, plans[i].chosen->len);
      else
        assert_status(out->forecast, i, id, WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0);
    }
    g_autoptr(GPtrArray) chosen = chosen_results(plans, n);
    assert_matches_oracle(out->forecast, place, chosen);
    if (raw_total <= WX_BLEND_MAX_MEMBERS && !empty_shadows_later(specs, n)) {
      /* the blend alone could take everything: the filtering must change nothing it would use */
      g_autoptr(GPtrArray) raw = raw_results(specs, n);
      assert_matches_oracle(out->forecast, place, raw);
    }
  }
  plans_free(plans, n);
}

/*
 * Registers one fake provider per spec (fake-00, fake-01, ... in this order, answering after a
 * random few milliseconds so that the order of arrival varies), refreshes Miami and checks the
 * outcome with check_share(). The caller makes further checks on @out and clears it.
 */
static void
run_share(Out *out, GArray **specs, guint n)
{
  static const guint delays_ms[] = {0, 0, 3, 8};
  g_autoptr(Rig) rig = rig_new();
  for (guint i = 0; i < n; i++) {
    g_autofree char *id = g_strdup_printf("fake-%02u", i);
    WxFakeProvider *fake = wx_fake_provider_new(id);
    for (guint k = 0; k < specs[i]->len; k++)
      wx_fake_provider_add_member(fake, g_array_index(specs[i], SpecMember, k).member);
    guint delay_ms = delays_ms[g_test_rand_int_range(0, G_N_ELEMENTS(delays_ms))];
    wx_fake_provider_set_delay_ms(fake, delay_ms);
    g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(fake), NULL));
    g_ptr_array_add(rig->fakes, fake);
  }
  g_autoptr(WxPlace) place = miami();
  run_refresh(out, rig->service, place, NULL);
  check_share(out, specs, n);
}

/*
 * One provider answers WX_BLEND_MAX_MEMBERS members (each with a single hour) and a later one a
 * 48-hour member: the later provider is not pushed out of the forecast.
 */
static void
test_share_big_provider_first(void)
{
  GArray *a = spec_new(), *b = spec_new();
  for (guint m = 0; m < WX_BLEND_MAX_MEMBERS; m++)
    spec_add_hours(a, "fake-a", m, 10.0, 1);
  spec_add_hours(b, "fake-b", 0, 30.0, 48);
  GArray *specs[] = {a, b};
  Out out = {0};
  run_share(&out, specs, 2);
  assert_succeeded(&out);
  const WxForecast *fc = out.forecast;
  assert_status(fc, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS - 1);
  assert_status(fc, 1, "fake-01", WX_SRC_OK, -1, 1);
  gint64 t0 = first_hour_of(b, 0);
  g_assert_nonnull(hour_at_t(fc, t0));
  g_assert_cmpuint(hour_at_t(fc, t0)->n_members, ==, WX_BLEND_MAX_MEMBERS);
  g_assert_nonnull(hour_at_t(fc, t0 + HOUR_S));
  g_assert_cmpuint(hour_at_t(fc, t0 + HOUR_S)->n_members, ==, 1);
  g_assert_cmpfloat(hour_at_t(fc, t0 + HOUR_S)->temp_c, ==, 30.0);
  out_clear(&out);
  specs_free(specs, 2);
}

/*
 * Members that must not reach the blend, whatever their number, use up no place: a provider that
 * answers 127, 128, 129 or 400 of them before its one real member, and a later provider with a
 * real member, are both blended; a provider that answers nothing else fails.
 */
static void
test_share_unusable_members(void)
{
  static const guint counts[] = {WX_BLEND_MAX_MEMBERS - 1, WX_BLEND_MAX_MEMBERS,
                                 WX_BLEND_MAX_MEMBERS + 1, 400};
  for (Garbage kind = 0; kind < GB_COUNT; kind++) {
    for (guint c = 0; c < G_N_ELEMENTS(counts); c++) {
      GArray *a = spec_new(), *b = spec_new(), *d = spec_new();
      for (guint m = 0; m < counts[c]; m++)
        spec_add_garbage(a, kind, "fake-a", m);
      spec_add_hours(a, "fake-a", 900, 10.0, 48); /* the real one, last */
      spec_add_hours(b, "fake-b", 0, 30.0, 48);
      for (guint m = 0; m < 3; m++)
        spec_add_garbage(d, kind, "fake-d", m);
      GArray *specs[] = {a, b, d};
      Out out = {0};
      run_share(&out, specs, 3);
      assert_succeeded(&out);
      assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, 1);
      assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 1);
      assert_status(out.forecast, 2, "fake-02", WX_SRC_FAILED, WX_ERROR_NOT_FOUND, 0);
      const WxBlendHour *both = hour_at_t(out.forecast, first_hour_of(a, a->len - 1));
      g_assert_nonnull(both);
      g_assert_cmpuint(both->n_members, ==, 2);
      out_clear(&out);
      specs_free(specs, 3);
    }
  }
}

/* Members of quarters only count as data (the nowcast member has no hours): they take places. */
static void
test_share_quarters_only(void)
{
  GArray *a = spec_new(), *b = spec_new();
  for (guint m = 0; m < 200; m++)
    spec_add_quarters(a, "fake-a", m);
  spec_add_hours(b, "fake-b", 0, 30.0, 48);
  GArray *specs[] = {a, b};
  Out out = {0};
  run_share(&out, specs, 2);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS - 1);
  assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 1);
  out_clear(&out);
  specs_free(specs, 2);
}

typedef struct {
  guint n;
  guint lens[WX_REGISTRY_MAX_PROVIDERS]; /* distinct usable members each provider answers */
  guint want[WX_REGISTRY_MAX_PROVIDERS]; /* members forwarded for each, worked out by hand */
} ShareRow;

/* Each row: round-robin dealing of WX_BLEND_MAX_MEMBERS places between the providers. */
static void
test_share_many_providers(void)
{
  static const ShareRow rows[] = {
      {2, {200, 1}, {127, 1}},
      {2, {1, 200}, {1, 127}},
      {2, {128, 128}, {64, 64}},
      {2, {129, 1}, {127, 1}},
      {2, {128, 1}, {127, 1}},
      {2, {127, 1}, {127, 1}},
      {3, {5, 300, 5}, {5, 118, 5}},
      {4, {0, 50, 0, 200}, {0, 50, 0, 78}},
      {8, {10, 20, 30, 40, 50, 60, 70, 80}, {10, 17, 17, 17, 17, 17, 17, 16}},
      {16, {8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8},
       {8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8}},
      {16, {9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9},
       {8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8}},
      {16, {200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200},
       {8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8}},
      {16, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
       {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 12, 12}},
  };
  for (guint r = 0; r < G_N_ELEMENTS(rows); r++) {
    const ShareRow *row = &rows[r];
    GArray *specs[WX_REGISTRY_MAX_PROVIDERS];
    guint total_want = 0;
    for (guint i = 0; i < row->n; i++) {
      specs[i] = spec_new();
      g_autofree char *source = g_strdup_printf("fake-%02u", i);
      for (guint m = 0; m < row->lens[i]; m++)
        spec_add_hours(specs[i], source, m, 5.0 + 0.05 * m + 0.5 * i, 48);
      total_want += row->want[i];
    }
    Out out = {0};
    run_share(&out, specs, row->n);
    assert_succeeded(&out);
    for (guint i = 0; i < row->n; i++) {
      g_assert_cmpuint(out.forecast->sources[i].n_members, ==, row->want[i]);
      g_assert_cmpint(out.forecast->sources[i].state, ==,
                      row->lens[i] > 0 ? WX_SRC_OK : WX_SRC_FAILED);
    }
    g_assert_cmpuint(max_members(out.forecast), ==, total_want);
    out_clear(&out);
    specs_free(specs, row->n);
  }
}

/* A duplicate never takes a place that another provider's distinct member needs. */
static void
test_share_duplicates(void)
{
  /* fake-b repeats all of fake-a's 128 pairs, then answers one of its own: that one is forwarded */
  {
    GArray *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < WX_BLEND_MAX_MEMBERS; m++)
      spec_add_hours(a, "shared", m, 10.0 + 0.05 * m, 48);
    for (guint m = 0; m < WX_BLEND_MAX_MEMBERS; m++)
      spec_add_hours(b, "shared", m, 50.0, 48);
    spec_add_hours(b, "own", 0, 30.0, 48);
    GArray *specs[] = {a, b};
    Out out = {0};
    run_share(&out, specs, 2);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS - 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 1);
    g_assert_cmpuint(max_members(out.forecast), ==, WX_BLEND_MAX_MEMBERS);
    out_clear(&out);
    specs_free(specs, 2);
  }

  /* a duplicate stays dropped when the member it duplicates is cut by the share */
  {
    GArray *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < 200; m++)
      spec_add_hours(a, "shared", m, 10.0 + 0.05 * m, 48);
    spec_add_hours(b, "shared", 199, 50.0, 48);
    GArray *specs[] = {a, b};
    Out out = {0};
    run_share(&out, specs, 2);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 0);
    out_clear(&out);
    specs_free(specs, 2);
  }

  /* copies inside one provider: 127 distinct members and 5 copies of the first, then one more */
  {
    GArray *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < WX_BLEND_MAX_MEMBERS - 1; m++)
      spec_add_hours(a, "shared", m, 10.0 + 0.05 * m, 48);
    for (guint k = 0; k < 5; k++)
      spec_add_hours(a, "shared", 0, 60.0, 48);
    spec_add_hours(b, "own", 0, 30.0, 48);
    GArray *specs[] = {a, b};
    Out out = {0};
    run_share(&out, specs, 2);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS - 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 1);
    g_assert_cmpuint(max_members(out.forecast), ==, WX_BLEND_MAX_MEMBERS);
    out_clear(&out);
    specs_free(specs, 2);
  }

  /* a member that is dropped as unusable shadows nothing: fake-b's one with the same ids is used,
   * whether the first one is garbage or valid without data (the blend alone would keep the
   * latter and drop fake-b's) */
  for (Garbage kind = 0; kind < GB_COUNT; kind++) {
    GArray *a = spec_new(), *b = spec_new();
    spec_add_garbage(a, kind, "shared", 0);
    spec_add_hours(a, "fake-a", 0, 10.0, 48);
    spec_add_hours(b, "shared", 0, 30.0, 48);
    GArray *specs[] = {a, b};
    Out out = {0};
    run_share(&out, specs, 2);
    assert_succeeded(&out);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 1);
    g_assert_cmpuint(max_members(out.forecast), ==, 2);
    if (kind >= GB_FIRST_VALID) {
      /* what the blend alone does with the same answers: the empty member shadows fake-b's */
      g_autoptr(GPtrArray) raw = raw_results(specs, 2);
      g_autoptr(GError) error = NULL;
      g_autoptr(WxPlace) place = miami();
      g_autoptr(WxForecast) alone = wx_blend_forecast(
          place, (const WxSourceResult *const *)raw->pdata, raw->len, out.forecast->sources,
          out.forecast->n_sources, out.forecast->generated_s, &error);
      g_assert_no_error(error);
      g_assert_nonnull(alone);
      g_assert_cmpuint(max_members(alone), ==, 1);
    }
    out_clear(&out);
    specs_free(specs, 2);
  }
}

/*
 * One provider answers 200000 references to the same member and then 126 others, a later one a
 * member of its own: the copies are found without comparing every pair (the answer must come well
 * inside the time limit of out_wait()) and cost no place.
 */
static void
test_share_many_copies(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeProvider) a = wx_fake_provider_new("fake-00");
  g_autoptr(WxMember) same = make_member_n("shared", "m000", 10.0, 48);
  for (guint i = 0; i < 200000; i++)
    wx_fake_provider_add_member(a, same);
  for (guint m = 1; m < WX_BLEND_MAX_MEMBERS - 1; m++) {
    g_autofree char *model = g_strdup_printf("m%03u", m);
    g_autoptr(WxMember) member = make_member_n("shared", model, 10.0 + 0.05 * m, 48);
    wx_fake_provider_add_member(a, member);
  }
  g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(a), NULL));
  rig_add_member(rig, "fake-01", same); /* the same ids as the copies: superseded */
  g_autoptr(WxMember) own = make_member_n("own", "m000", 30.0, 48);
  g_autoptr(WxFakeProvider) c = wx_fake_provider_new("fake-02");
  wx_fake_provider_add_member(c, own);
  g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(c), NULL));
  g_autoptr(WxPlace) place = miami();

  Out out = {0};
  run_refresh(&out, rig->service, place, NULL);
  assert_succeeded(&out);
  assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, WX_BLEND_MAX_MEMBERS - 1);
  assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 0);
  assert_status(out.forecast, 2, "fake-02", WX_SRC_OK, -1, 1);
  g_assert_cmpuint(max_members(out.forecast), ==, WX_BLEND_MAX_MEMBERS);
  out_clear(&out);
}

/* The stamp of the first mark: past the 48 hours of the base member that every scenario has. */
static gint64
mark_origin(void)
{
  return now_s() / HOUR_S * HOUR_S - HOUR_S + 48 * (gint64)HOUR_S;
}

/*
 * Exact set: every member made by spec_add_mark() has a blended hour of its own, in which exactly
 * one member contributes iff the member reached the blend (and none otherwise). Checks that this
 * is what the model says for every mark and returns the number of marks that reached the blend.
 */
static guint
check_marks(const Out *out, GArray **specs, guint n)
{
  assert_succeeded(out);
  Plan *plans = plan_forwarding(specs, n);
  guint n_forwarded = 0;
  for (guint i = 0; i < n; i++) {
    for (guint k = 0; k < specs[i]->len; k++) {
      const SpecMember *entry = &g_array_index(specs[i], SpecMember, k);
      if (entry->mark_t == 0)
        continue;
      gboolean forwarded = g_ptr_array_find(plans[i].chosen, entry, NULL);
      const WxBlendHour *hour = hour_at_t(out->forecast, entry->mark_t);
      g_assert_cmpuint(hour != NULL ? hour->n_members : 0, ==, forwarded ? 1 : 0);
      n_forwarded += forwarded ? 1 : 0;
    }
  }
  plans_free(plans, n);
  return n_forwarded;
}

/* The base member (fake-00): 48 hours, so that the blend has a forecast whatever else is cut. */
static GArray *
base_spec(void)
{
  GArray *base = spec_new();
  spec_add_hours(base, "fake-base", 0, 20.0, 48);
  return base;
}

/*
 * Which members reach the blend, read off the blended hours one by one: marks in the forecast are
 * exactly the ones the rule forwards (first members of each provider, distinct, in registration
 * order of precedence), nothing else.
 */
static void
test_share_exact_sets(void)
{
  gint64 t0 = mark_origin();

  /* 128 + 64 distinct marks and the base member: 1 + 64 + 63 are dealt */
  {
    GArray *base = base_spec(), *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < 128; m++)
      spec_add_mark(a, "src-a", m, t0 + (gint64)m * HOUR_S);
    for (guint m = 0; m < 64; m++)
      spec_add_mark(b, "src-b", m, t0 + (gint64)(128 + m) * HOUR_S);
    GArray *specs[] = {base, a, b};
    Out out = {0};
    run_share(&out, specs, 3);
    g_assert_cmpuint(check_marks(&out, specs, 3), ==, 127);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 64);
    assert_status(out.forecast, 2, "fake-02", WX_SRC_OK, -1, 63);
    out_clear(&out);
    specs_free(specs, 3);
  }

  /* fake-b repeats the ids m050 .. m099 of fake-a: those marks are not forwarded, its m100 ..
   * m139 are, and the share cuts fake-a at 87 */
  {
    GArray *base = base_spec(), *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < 100; m++)
      spec_add_mark(a, "shared", m, t0 + (gint64)m * HOUR_S);
    for (guint j = 0; j < 90; j++)
      spec_add_mark(b, "shared", 50 + j, t0 + (gint64)(100 + j) * HOUR_S);
    GArray *specs[] = {base, a, b};
    Out out = {0};
    run_share(&out, specs, 3);
    g_assert_cmpuint(check_marks(&out, specs, 3), ==, 127);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 87);
    assert_status(out.forecast, 2, "fake-02", WX_SRC_OK, -1, 40);
    out_clear(&out);
    specs_free(specs, 3);
  }

  /* every other member of fake-a is garbage of some kind: it takes no place */
  {
    GArray *base = base_spec(), *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < 100; m++) {
      spec_add_mark(a, "src-a", m, t0 + (gint64)m * HOUR_S);
      spec_add_garbage(a, m % GB_COUNT, "junk", m);
    }
    for (guint m = 0; m < 90; m++)
      spec_add_mark(b, "src-b", m, t0 + (gint64)(100 + m) * HOUR_S);
    GArray *specs[] = {base, a, b};
    Out out = {0};
    run_share(&out, specs, 3);
    g_assert_cmpuint(check_marks(&out, specs, 3), ==, 127);
    assert_status(out.forecast, 0, "fake-00", WX_SRC_OK, -1, 1);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 64);
    assert_status(out.forecast, 2, "fake-02", WX_SRC_OK, -1, 63);
    out_clear(&out);
    specs_free(specs, 3);
  }

  /* 130 members without data, then 5 marks, next to a provider with 5 marks: all ten are used */
  {
    GArray *base = base_spec(), *a = spec_new(), *b = spec_new();
    for (guint m = 0; m < 130; m++)
      spec_add_garbage(a, GB_NO_DATA, "junk", m);
    for (guint m = 0; m < 5; m++)
      spec_add_mark(a, "src-a", m, t0 + (gint64)m * HOUR_S);
    for (guint m = 0; m < 5; m++)
      spec_add_mark(b, "src-b", m, t0 + (gint64)(5 + m) * HOUR_S);
    GArray *specs[] = {base, a, b};
    Out out = {0};
    run_share(&out, specs, 3);
    g_assert_cmpuint(check_marks(&out, specs, 3), ==, 10);
    assert_status(out.forecast, 1, "fake-01", WX_SRC_OK, -1, 5);
    assert_status(out.forecast, 2, "fake-02", WX_SRC_OK, -1, 5);
    out_clear(&out);
    specs_free(specs, 3);
  }
}

/* Random answers made of marks, copies, garbage and long members, read off hour by hour. */
static void
test_share_exact_random(void)
{
  guint n_scenarios = g_test_slow() ? 300 : 40;
  gint64 t0 = mark_origin();
  for (guint s = 0; s < n_scenarios; s++) {
    guint n = g_test_rand_int_range(2, 9);
    guint n_models = g_test_rand_bit() ? 20 : 200;
    GArray *specs[8];
    specs[0] = base_spec();
    guint n_marks = 0; /* the blend keeps 240 hours, 48 of them are the base member's */
    for (guint i = 1; i < n; i++) {
      specs[i] = spec_new();
      guint len = g_test_rand_int_range(0, 3) == 0 ? g_test_rand_int_range(0, 8)
                                                    : g_test_rand_int_range(20, 130);
      for (guint k = 0; k < len; k++) {
        static const char *const sources[] = {"src-a", "src-b", "src-c"};
        const char *source = sources[g_test_rand_int_range(0, G_N_ELEMENTS(sources))];
        guint model = g_test_rand_int_range(0, n_models);
        gint32 roll = g_test_rand_int_range(0, 100);
        if (roll < 70 && n_marks < 190) {
          spec_add_mark(specs[i], source, model, t0 + (gint64)n_marks * HOUR_S);
          n_marks++;
        } else if (roll < 85) {
          spec_add_garbage(specs[i], g_test_rand_int_range(0, GB_COUNT), source, model);
        } else if (roll < 95) {
          spec_add_hours(specs[i], source, model, 25.0, 48);
        } else {
          spec_add_quarters(specs[i], source, model);
        }
      }
    }
    Out out = {0};
    run_share(&out, specs, n);
    check_marks(&out, specs, n);
    out_clear(&out);
    specs_free(specs, n);
  }
}

/* A random member for the model: mostly good ones, with ids from a small pool so copies occur. */
static void
random_member(GArray *spec, guint n_models)
{
  static const char *const sources[] = {"src-a", "src-b", "src-c"};
  const char *source = sources[g_test_rand_int_range(0, G_N_ELEMENTS(sources))];
  guint model = g_test_rand_int_range(0, n_models);
  double temp_c = 10.0 + g_test_rand_int_range(0, 25);
  gint32 roll = g_test_rand_int_range(0, 100);
  if (roll < 55)
    spec_add_hours(spec, source, model, temp_c, 48);
  else if (roll < 65)
    spec_add_hours(spec, source, model, temp_c, 3);
  else if (roll < 72)
    spec_add_hours(spec, source, model, temp_c, 1);
  else if (roll < 80)
    spec_add_quarters(spec, source, model);
  else
    spec_add_garbage(spec, g_test_rand_int_range(0, GB_COUNT), source, model);
}

/*
 * Random answers (good, short, quarters only, garbage, copies, from empty to 260 members) of one
 * to eight providers, against the model of the rule.
 */
static void
test_share_random(void)
{
  guint n_scenarios = g_test_slow() ? 600 : 60;
  for (guint s = 0; s < n_scenarios; s++) {
    guint n = g_test_rand_int_range(1, 9);
    guint n_models = g_test_rand_bit() ? 12 : 400;
    GArray *specs[8];
    for (guint i = 0; i < n; i++) {
      specs[i] = spec_new();
      gint32 roll = g_test_rand_int_range(0, 10);
      guint len = roll == 0   ? 0
                  : roll < 5  ? g_test_rand_int_range(1, 20)
                  : roll < 8  ? g_test_rand_int_range(20, 130)
                              : g_test_rand_int_range(120, 261);
      for (guint k = 0; k < len; k++)
        random_member(specs[i], n_models);
    }
    Out out = {0};
    run_share(&out, specs, n);
    out_clear(&out);
    specs_free(specs, n);
  }
}

/* ------------------------------------------------------------------------ */
/* Search                                                                   */
/* ------------------------------------------------------------------------ */

/* A hand-built place: every string is a heap copy (@name may be NULL), nothing is validated. */
static WxPlace *
raw_place(const char *name, double lat, double lon)
{
  WxPlace *place = g_new0(WxPlace, 1);
  place->name = g_strdup(name);
  place->admin1 = g_strdup("Florida");
  place->country = g_strdup("United States");
  place->country_code[0] = 'U';
  place->country_code[1] = 'S';
  place->lat = lat;
  place->lon = lon;
  place->timezone = g_strdup("America/New_York");
  return place;
}

static void
raw_place_free(gpointer data)
{
  WxPlace *place = data;
  if (place == NULL)
    return;
  g_free(place->name);
  g_free(place->admin1);
  g_free(place->country);
  g_free(place->timezone);
  g_free(place);
}

/* Hits: a valid place, NULL, a place without a name, one with a NaN latitude, then GPOINTER_TO_UINT
 * (@data) valid places "City1" ... */
static GPtrArray *
make_hostile_hits(gpointer data)
{
  guint n_valid = GPOINTER_TO_UINT(data);
  GPtrArray *hits = g_ptr_array_new_with_free_func(raw_place_free);
  g_ptr_array_add(hits, raw_place("City0", 25.0, -80.0));
  g_ptr_array_add(hits, NULL);
  g_ptr_array_add(hits, raw_place(NULL, 25.0, -80.0));
  g_ptr_array_add(hits, raw_place("Not a number", NAN, -80.0));
  for (guint i = 1; i <= n_valid; i++) {
    g_autofree char *name = g_strdup_printf("City%u", i);
    g_ptr_array_add(hits, raw_place(name, 25.0 + i * 0.01, -80.0));
  }
  return hits;
}

/* 200000 NULL entries and one valid place at the end. */
static GPtrArray *
make_many_nulls(gpointer data)
{
  (void)data;
  GPtrArray *hits = g_ptr_array_new_with_free_func(raw_place_free);
  for (guint i = 0; i < 200000; i++)
    g_ptr_array_add(hits, NULL);
  g_ptr_array_add(hits, raw_place("Last", 25.0, -80.0));
  return hits;
}

static GPtrArray *
make_two_hits(gpointer data)
{
  (void)data;
  GPtrArray *hits = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
  g_ptr_array_add(hits, make_place("Miami", 25.7617, -80.1918, "America/New_York"));
  g_ptr_array_add(hits, make_place("Orlando", 28.5383, -81.3792, "America/New_York"));
  return hits;
}

static void
test_search_ok(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  const char *names[] = {"Miami", "Orlando", "Tampa"};
  for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
    g_autoptr(WxPlace) place = make_place(names[i], 25.0 + i, -80.0 - i, "America/New_York");
    wx_fake_geocoder_add_hit(geo, place);
  }
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));

  Out out = {0};
  out_search(&out, rig->service, "Mia", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_nonnull(out.hits);
  g_assert_cmpuint(out.hits->len, ==, G_N_ELEMENTS(names));
  for (guint i = 0; i < G_N_ELEMENTS(names); i++) {
    const WxPlace *hit = g_ptr_array_index(out.hits, i);
    g_assert_cmpstr(hit->name, ==, names[i]);
    g_assert_cmpfloat(hit->lat, ==, 25.0 + i);
  }
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geo), ==, 1);
  out_clear(&out);

  /* no hit is an empty array, not an error */
  g_autoptr(WxFakeGeocoder) none = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(none));
  out_search(&out, rig->service, "Nowhere", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_nonnull(out.hits);
  g_assert_cmpuint(out.hits->len, ==, 0);
  out_clear(&out);
}

/* The text and the caller's cancellable go to the geocoder unchanged; the registry is read when
 * the search starts. */
static void
test_search_pass_through(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestGeo) geo = test_geo_new();
  geo->make = make_two_hits;
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  g_autoptr(GCancellable) outer = g_cancellable_new();
  g_autofree char *text = g_strdup("  Mi\xc3\xa1mi, FL \t");

  Out out = {0};
  out_search(&out, rig->service, text, outer);
  g_free(g_steal_pointer(&text)); /* the geocoder copied it during the call */
  text = g_strdup("  Mi\xc3\xa1mi, FL \t");
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(out.hits->len, ==, 2);
  g_assert_cmpstr(geo->last_text, ==, text); /* not trimmed, not validated */
  g_assert_true(geo->seen == outer);
  g_assert_cmpuint(geo->searches, ==, 1);
  out_clear(&out);

  /* the geocoder replaced after the call is not the one that was asked */
  g_autoptr(TestGeo) later = test_geo_new();
  later->make = make_two_hits;
  later->delay_ms = 40;
  geo->delay_ms = 40;
  out_search(&out, rig->service, "again", NULL);
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(later));
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(geo->searches, ==, 2);
  g_assert_cmpuint(later->searches, ==, 0);
  out_clear(&out);
}

static void
test_search_no_geocoder(void)
{
  g_autoptr(Rig) rig = rig_new();
  Out out = {0};
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_null(out.hits);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_UNSUPPORTED);
  g_assert_cmpstr(out.error->message, ==, "no geocoder is registered");
  out_clear(&out);

  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  out_clear(&out);

  wx_registry_set_geocoder(rig->registry, NULL);
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_UNSUPPORTED);
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geo), ==, 1);
  out_clear(&out);
}

static void
test_search_errors(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  Out out = {0};
  for (guint k = 0; k < G_N_ELEMENTS(all_codes); k++) {
    wx_fake_geocoder_fail_with(geo, all_codes[k]);
    out_search(&out, rig->service, "Miami", NULL);
    out_wait(&out);
    g_assert_null(out.hits);
    g_assert_error(out.error, WX_ERROR, all_codes[k]);
    g_assert_cmpstr(out.error->message, ==, "scripted failure");
    out_clear(&out);
  }

  /* outside the interface: reduced to WX_ERROR / cancellation, messages sanitised */
  g_autoptr(TestGeo) odd = test_geo_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(odd));
  odd->failure = g_error_new_literal(G_FILE_ERROR, G_FILE_ERROR_NOENT, "no such thing");
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_NETWORK);
  g_assert_cmpstr(out.error->message, ==, "no such thing");
  out_clear(&out);

  g_clear_error(&odd->failure);
  odd->failure = g_error_new_literal(WX_ERROR, 99, "too big");
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_NETWORK);
  g_assert_cmpstr(out.error->message, ==, "too big");
  out_clear(&out);

  g_clear_error(&odd->failure);
  odd->failure = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "gave up");
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  assert_cancelled(&out);
  out_clear(&out);

  g_clear_error(&odd->failure);
  odd->failure = g_error_new_literal(G_FILE_ERROR, G_FILE_ERROR_FAILED, "ba\x07\xff" "d\xE2\x80\xAE!");
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_NETWORK);
  g_assert_cmpstr(out.error->message, ==, "ba\xEF\xBF\xBD" "d!");
  out_clear(&out);

  g_clear_error(&odd->failure); /* NULL without an error */
  odd->make = NULL;
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_null(out.hits);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_NOT_FOUND);
  g_assert_cmpstr(out.error->message, ==, "the geocoder returned no result");
  out_clear(&out);
}

/* Text the geocoder refuses is its business: the service passes it on and reports its answer. */
static void
test_search_invalid_text(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  g_autofree char *long_text = g_strnfill(65, 'a');
  const char *texts[] = {"", " ", long_text, "a\x01" "b", "\xff"};
  Out out = {0};
  for (guint i = 0; i < G_N_ELEMENTS(texts); i++) {
    out_search(&out, rig->service, texts[i], NULL);
    out_wait(&out);
    g_assert_null(out.hits);
    g_assert_error(out.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_cmpstr(out.error->message, ==, "invalid search text");
    out_clear(&out);
  }
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geo), ==, G_N_ELEMENTS(texts));
}

static void
test_search_cancel(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  g_autoptr(WxPlace) place = miami();
  wx_fake_geocoder_add_hit(geo, place);
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  Out out = {0};

  g_autoptr(GCancellable) done = g_cancellable_new();
  g_cancellable_cancel(done);
  out_search(&out, rig->service, "Miami", done);
  out_wait(&out);
  assert_cancelled(&out);
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geo), ==, 0); /* the geocoder was not asked */
  out_clear(&out);

  wx_fake_geocoder_set_delay_ms(geo, 10000);
  g_autoptr(GCancellable) outer = g_cancellable_new();
  out_search(&out, rig->service, "Miami", outer);
  drain_ms(20);
  g_assert_cmpuint(out.calls, ==, 0);
  g_cancellable_cancel(outer);
  out_wait(&out);
  assert_cancelled(&out);
  g_assert_cmpint(elapsed_ms(&out), <, 5000);
  out_clear(&out);

  /* cancelled after the search completed but before finish: cancelled */
  wx_fake_geocoder_set_delay_ms(geo, 0);
  g_autoptr(GCancellable) late = g_cancellable_new();
  GAsyncResult *kept = NULL;
  wx_service_search_async(rig->service, "Miami", late, on_keep, &kept);
  SPIN_UNTIL(kept != NULL);
  g_cancellable_cancel(late);
  g_autoptr(GError) error = NULL;
  g_assert_null(wx_service_search_finish(rig->service, kept, &error));
  g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_object_unref(kept);
}

/* An answer that carries both hits and an error: the error is reported, the hits are released. */
static void
test_search_hits_with_error(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestGeo) geo = test_geo_new();
  geo->make = make_two_hits;
  geo->both = TRUE;
  geo->failure = g_error_new_literal(WX_ERROR, WX_ERROR_RATE_LIMITED, "slow down");
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  Out out = {0};
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_null(out.hits);
  g_assert_error(out.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  g_assert_cmpstr(out.error->message, ==, "slow down");
  out_clear(&out);
}

/* A geocoder's answer is re-validated and capped. */
static void
test_search_hostile_hits(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(TestGeo) geo = test_geo_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  Out out = {0};

  /* valid, NULL, nameless, NaN, then 24 valid: the three bad ones go, 20 are kept */
  geo->make = make_hostile_hits;
  geo->make_data = GUINT_TO_POINTER(24);
  out_search(&out, rig->service, "City", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(out.hits->len, ==, WX_GEOCODER_MAX_HITS);
  for (guint i = 0; i < WX_GEOCODER_MAX_HITS; i++) {
    g_autofree char *name = g_strdup_printf("City%u", i);
    g_assert_cmpstr(((WxPlace *)g_ptr_array_index(out.hits, i))->name, ==, name);
  }
  out_clear(&out);

  /* fewer valid ones than the cap: all of them, in order */
  geo->make_data = GUINT_TO_POINTER(2);
  out_search(&out, rig->service, "City", NULL);
  out_wait(&out);
  g_assert_cmpuint(out.hits->len, ==, 3);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(out.hits, 2))->name, ==, "City2");
  out_clear(&out);

  /* a lot of NULL entries ahead of the only valid place */
  geo->make = make_many_nulls;
  out_search(&out, rig->service, "City", NULL);
  out_wait(&out);
  g_assert_cmpuint(out.hits->len, ==, 1);
  g_assert_cmpstr(((WxPlace *)g_ptr_array_index(out.hits, 0))->name, ==, "Last");
  out_clear(&out);
}

static void
replace_geocoder(gpointer instance, gpointer data)
{
  (void)instance;
  wx_registry_set_geocoder(data, NULL); /* drops the registry's reference to the geocoder */
}

/* A geocoder that is replaced while it is being called (even by itself) is kept alive. */
static void
test_search_geocoder_replaced(void)
{
  g_autoptr(Rig) rig = rig_new();
  TestGeo *geo = test_geo_new();
  geo->make = make_two_hits;
  geo->on_search = replace_geocoder;
  geo->hook_data = rig->registry;
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  gpointer weak = geo;
  g_object_add_weak_pointer(G_OBJECT(geo), &weak);
  g_object_unref(geo); /* the registry holds the only reference now */

  Out out = {0};
  out_search(&out, rig->service, "Miami", NULL);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(out.hits->len, ==, 2);
  g_assert_null(wx_registry_get_geocoder(rig->registry));
  SPIN_UNTIL(weak == NULL);
  out_clear(&out);
}

/* The caller lets go of everything in flight: the search still completes. */
static void
test_search_dispose_in_flight(void)
{
  Rig *rig = rig_new();
  g_autoptr(TestGeo) geo = test_geo_new();
  geo->make = make_two_hits;
  geo->delay_ms = 40;
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  gpointer weak_service = rig->service;
  g_object_add_weak_pointer(G_OBJECT(rig->service), &weak_service);
  Out out = {0};
  out.after = check_service_alive;
  out.after_data = &weak_service;
  out_search(&out, rig->service, "Miami", NULL);
  rig_free(rig);
  g_assert_nonnull(weak_service);
  out_wait(&out);
  g_assert_no_error(out.error);
  g_assert_cmpuint(out.hits->len, ==, 2);
  SPIN_UNTIL(weak_service == NULL);
  out_clear(&out);
}

static void
test_search_programmer_errors(void)
{
  g_autoptr(Rig) rig = rig_new();
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  g_autoptr(GObject) not_a_cancellable = g_object_new(G_TYPE_OBJECT, NULL);
  Out out = {0};
  ASSERT_CRITICAL("wx_service_search_async",
                  wx_service_search_async(NULL, "Miami", NULL, on_search_done, &out));
  ASSERT_CRITICAL("wx_service_search_async",
                  wx_service_search_async(rig->service, NULL, NULL, on_search_done, &out));
  ASSERT_CRITICAL("wx_service_search_async",
                  wx_service_search_async(rig->service, "Miami", (GCancellable *)not_a_cancellable,
                                          on_search_done, &out));
  drain_ms(30);
  g_assert_cmpuint(out.calls, ==, 0);
  g_assert_cmpuint(wx_fake_geocoder_get_search_count(geo), ==, 0);
}

/* ------------------------------------------------------------------------ */
/* Finish functions                                                         */
/* ------------------------------------------------------------------------ */

static void
test_finish_errors(void)
{
  g_autoptr(Rig) rig = rig_new();
  rig_add(rig, "fake-a", 10.0);
  g_autoptr(WxFakeGeocoder) geo = wx_fake_geocoder_new();
  wx_registry_set_geocoder(rig->registry, WX_GEOCODER(geo));
  g_autoptr(Rig) other = rig_new();
  g_autoptr(WxPlace) place = miami();
  GAsyncResult *refresh_result = NULL, *search_result = NULL;
  wx_service_refresh_async(rig->service, place, NULL, on_keep, &refresh_result);
  wx_service_search_async(rig->service, "Miami", NULL, on_keep, &search_result);
  SPIN_UNTIL(refresh_result != NULL && search_result != NULL);

  GError *preset = g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "preset");
  ASSERT_CRITICAL("wx_service_refresh_finish",
                  g_assert_null(wx_service_refresh_finish(NULL, refresh_result, NULL)));
  ASSERT_CRITICAL("wx_service_refresh_finish",
                  g_assert_null(wx_service_refresh_finish(rig->service, NULL, NULL)));
  ASSERT_CRITICAL("wx_service_refresh_finish", /* the result of another service */
                  g_assert_null(wx_service_refresh_finish(other->service, refresh_result, NULL)));
  ASSERT_CRITICAL("wx_service_refresh_finish", /* the result of a search */
                  g_assert_null(wx_service_refresh_finish(rig->service, search_result, NULL)));
  ASSERT_CRITICAL("wx_service_refresh_finish", /* an error already set */
                  g_assert_null(wx_service_refresh_finish(rig->service, refresh_result, &preset)));
  ASSERT_CRITICAL("wx_service_search_finish",
                  g_assert_null(wx_service_search_finish(NULL, search_result, NULL)));
  ASSERT_CRITICAL("wx_service_search_finish",
                  g_assert_null(wx_service_search_finish(rig->service, NULL, NULL)));
  ASSERT_CRITICAL("wx_service_search_finish",
                  g_assert_null(wx_service_search_finish(other->service, search_result, NULL)));
  ASSERT_CRITICAL("wx_service_search_finish", /* the result of a refresh */
                  g_assert_null(wx_service_search_finish(rig->service, refresh_result, NULL)));
  ASSERT_CRITICAL("wx_service_search_finish",
                  g_assert_null(wx_service_search_finish(rig->service, search_result, &preset)));
  g_assert_error(preset, WX_ERROR, WX_ERROR_PARSE); /* untouched */
  g_assert_cmpstr(preset->message, ==, "preset");
  g_clear_error(&preset);

  /* none of the refusals consumed the results */
  g_autoptr(GError) error = NULL;
  WxForecast *forecast = wx_service_refresh_finish(rig->service, refresh_result, &error);
  g_assert_no_error(error);
  g_assert_nonnull(forecast);
  wx_forecast_unref(forecast);
  GPtrArray *hits = wx_service_search_finish(rig->service, search_result, &error);
  g_assert_no_error(error);
  g_assert_nonnull(hits);
  g_ptr_array_unref(hits);

  /* finishing twice is refused by GTask */
  g_test_expect_message("GLib-GIO", G_LOG_LEVEL_CRITICAL, "*g_task_propagate_pointer*");
  g_assert_null(wx_service_refresh_finish(rig->service, refresh_result, NULL));
  g_test_assert_expected_messages();
  g_test_expect_message("GLib-GIO", G_LOG_LEVEL_CRITICAL, "*g_task_propagate_pointer*");
  g_assert_null(wx_service_search_finish(rig->service, search_result, NULL));
  g_test_assert_expected_messages();
  g_object_unref(refresh_result);
  g_object_unref(search_result);
}

/* ------------------------------------------------------------------------ */
/* Randomised scenarios against an independent model                        */
/* ------------------------------------------------------------------------ */

typedef enum {
  K_OK,          /* a fake with a 48-hour member */
  K_SHORT,       /* a fake with a 3-hour member: counted, but of no use to the blend */
  K_FAIL,        /* a fake failing with a code */
  K_EMPTY,       /* a fake answering without members */
  K_CANCELLED,   /* a scripted provider failing with G_IO_ERROR_CANCELLED */
  K_HANG_FAKE,   /* a fake that never answers and honours cancellation */
  K_HANG_IGNORE, /* a scripted provider that never answers and ignores cancellation */
  K_NULL_RESULT, /* a scripted provider answering NULL without an error */
  K_COUNT
} Kind;

typedef struct {
  Kind kind;
  gboolean enabled, covers;
  int code;
  guint delay_ms;
  char id[8];
  TestProv *prov;     /* an owned reference, or NULL */
  WxMember *member;   /* an owned reference, or NULL */
} FuzzProv;

/* Picks a kind with fixed odds (percent): OK 34, SHORT 8, FAIL 22, EMPTY 8, CANCELLED 7,
 * HANG_FAKE 7, HANG_IGNORE 6, NULL_RESULT 8; hanging kinds are drawn again when @allow_hang is
 * FALSE. */
static Kind
pick_kind(gboolean allow_hang)
{
  for (;;) {
    gint32 roll = g_test_rand_int_range(0, 100);
    if (roll < 34) return K_OK;
    if (roll < 42) return K_SHORT;
    if (roll < 64) return K_FAIL;
    if (roll < 72) return K_EMPTY;
    if (roll < 79) return K_CANCELLED;
    if (roll < 86 && allow_hang) return K_HANG_FAKE;
    if (roll < 92 && roll >= 86 && allow_hang) return K_HANG_IGNORE;
    if (roll >= 92) return K_NULL_RESULT;
  }
}

/* Long enough that a provider answering within a few milliseconds is never overtaken by it. */
#define FUZZ_DEADLINE_MS 250

/* Builds the providers of one scenario, registers them in @rig, returns TRUE if any can hang
 * (none is drawn when @allow_hang is FALSE). */
static gboolean
fuzz_build(Rig *rig, FuzzProv *provs, guint n, gboolean allow_hang)
{
  gboolean hangs = FALSE;
  for (guint i = 0; i < n; i++) {
    FuzzProv *p = &provs[i];
    p->kind = pick_kind(allow_hang);
    p->enabled = g_test_rand_int_range(0, 100) < 85;
    p->covers = g_test_rand_int_range(0, 100) < 85;
    p->code = all_codes[g_test_rand_int_range(0, G_N_ELEMENTS(all_codes))];
    p->delay_ms = (guint[]){0, 0, 0, 5, 15}[g_test_rand_int_range(0, 5)];
    g_snprintf(p->id, sizeof p->id, "p%u", i);
    switch (p->kind) {
    case K_OK:
    case K_SHORT:
    case K_FAIL:
    case K_HANG_FAKE: {
      p->member = make_member_n(p->id, "m", 10.0 + i, p->kind == K_SHORT ? 3 : 48);
      WxFakeProvider *fake = rig_add_member(rig, p->id, p->member);
      wx_fake_provider_set_covers(fake, p->covers);
      wx_fake_provider_set_delay_ms(fake, p->kind == K_HANG_FAKE ? G_MAXUINT : p->delay_ms);
      if (p->kind == K_FAIL)
        wx_fake_provider_fail_with(fake, p->code);
      break;
    }
    case K_EMPTY: {
      WxFakeProvider *fake = wx_fake_provider_new(p->id);
      wx_fake_provider_set_covers(fake, p->covers);
      wx_fake_provider_set_delay_ms(fake, p->delay_ms);
      g_assert_true(wx_registry_add_provider(rig->registry, WX_PROVIDER(fake), NULL));
      g_ptr_array_add(rig->fakes, fake);
      break;
    }
    case K_CANCELLED:
    case K_HANG_IGNORE:
    case K_NULL_RESULT:
      p->prov = test_prov_new(p->id);
      p->prov->covers = p->covers;
      p->prov->delay_ms = p->delay_ms;
      if (p->kind == K_CANCELLED)
        test_prov_fail(p->prov, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "stop"));
      if (p->kind == K_HANG_IGNORE)
        p->prov->mode = TP_HOLD;
      if (p->kind == K_NULL_RESULT)
        p->prov->result_kind = TPR_NULL_NO_ERROR;
      rig_add_prov(rig, p->prov);
      break;
    case K_COUNT:
      g_assert_not_reached();
    }
    if (!p->enabled)
      g_assert_true(wx_registry_set_enabled(rig->registry, p->id, FALSE));
    if (p->enabled && p->covers && (p->kind == K_HANG_FAKE || p->kind == K_HANG_IGNORE))
      hangs = TRUE;
  }
  return hangs;
}

/* What the model expects of one scenario, and the check against what the service did. */
static void
fuzz_check(const FuzzProv *provs, guint n, const Out *out, const WxPlace *place, guint deadline_ms)
{
  struct {
    WxSourceState state;
    int code;
    guint n_members;
  } want[6];
  GPtrArray *results = g_ptr_array_new_with_free_func((GDestroyNotify)wx_source_result_free);
  gboolean any_fetched = FALSE, any_counted = FALSE, any_full = FALSE;
  /* the best failure so far: its rank, then its text */
  int best_rank = G_MAXINT;
  int best_code = -1;
  g_autofree char *best_message = NULL;
  for (guint i = 0; i < n; i++) {
    const FuzzProv *p = &provs[i];
    want[i].state = WX_SRC_SKIPPED;
    want[i].code = -1;
    want[i].n_members = 0;
    if (!p->enabled || !p->covers)
      continue;
    any_fetched = TRUE;
    int fail_code = -2; /* no failure */
    const char *fail_text = NULL;
    switch (p->kind) {
    case K_OK:
    case K_SHORT:
      want[i].state = WX_SRC_OK;
      want[i].n_members = 1;
      any_counted = TRUE;
      any_full = any_full || p->kind == K_OK;
      g_ptr_array_add(results, make_result(p->id, p->member, NULL));
      break;
    case K_FAIL:
      fail_code = p->code;
      fail_text = "scripted failure";
      if (p->code == WX_ERROR_UNSUPPORTED) {
        want[i].state = WX_SRC_SKIPPED;
      } else {
        want[i].state = WX_SRC_FAILED;
        want[i].code = p->code;
      }
      break;
    case K_EMPTY:
      want[i].state = WX_SRC_FAILED;
      want[i].code = fail_code = WX_ERROR_NOT_FOUND;
      fail_text = "the provider returned no forecast data";
      break;
    case K_CANCELLED:
      want[i].state = WX_SRC_FAILED; /* no code, and no candidate for the error */
      break;
    case K_HANG_FAKE:
    case K_HANG_IGNORE:
      want[i].state = WX_SRC_FAILED;
      want[i].code = fail_code = WX_ERROR_TIMEOUT;
      fail_text = NULL; /* built below: it names the deadline */
      break;
    case K_NULL_RESULT:
      want[i].state = WX_SRC_FAILED;
      want[i].code = fail_code = WX_ERROR_NOT_FOUND;
      fail_text = "the provider returned no result";
      break;
    case K_COUNT:
      g_assert_not_reached();
    }
    if (fail_code != -2 && code_rank[fail_code] < best_rank) {
      best_rank = code_rank[fail_code];
      best_code = fail_code;
      g_free(best_message);
      best_message = fail_text != NULL
                         ? g_strdup_printf("%s: %s", p->id, fail_text)
                         : g_strdup_printf("%s: no answer within %u ms", p->id, deadline_ms);
    }
  }

  if (!any_fetched) {
    assert_failed(out, WX_ERROR_UNSUPPORTED, "no enabled data source covers this place");
  } else if (any_full) {
    assert_succeeded(out);
    g_assert_cmpuint(out->forecast->n_sources, ==, n);
    for (guint i = 0; i < n; i++)
      assert_status(out->forecast, i, provs[i].id, want[i].state, want[i].code, want[i].n_members);
    assert_matches_oracle(out->forecast, place, results);
  } else {
    /* no forecast: the blend's own failure competes when someone answered (it ranks as NOT_FOUND
     * and loses ties against a provider) */
    if (any_counted && code_rank[WX_ERROR_NOT_FOUND] < best_rank) {
      assert_failed(out, WX_ERROR_NOT_FOUND, "no usable forecast data");
    } else if (best_code != -1) {
      assert_failed(out, best_code, best_message);
    } else {
      assert_cancelled(out); /* nobody failed except by cancelling */
    }
  }
  g_ptr_array_unref(results);
}

static void
test_refresh_random_scenarios(void)
{
  guint n_scenarios = g_test_slow() ? 3000 : 300;
  guint hang_budget = g_test_slow() ? 100 : 20; /* each hanging scenario lasts the whole deadline */
  GPtrArray *outs = g_ptr_array_new_with_free_func(g_free);
  g_autoptr(WxPlace) place = miami();
  for (guint s = 0; s < n_scenarios; s++) {
    Rig *rig = rig_new();
    FuzzProv provs[6] = {{0}};
    guint n = g_test_rand_int_range(0, 7);
    gboolean hangs = fuzz_build(rig, provs, n, hang_budget > 0);
    if (hangs)
      hang_budget--;
    guint deadline_ms = hangs ? FUZZ_DEADLINE_MS : WX_SERVICE_DEADLINE_MS;
    wx_service_test_set_deadline_ms(hangs ? FUZZ_DEADLINE_MS : 0);

    Out *out = g_new0(Out, 1);
    g_ptr_array_add(outs, out);
    out_refresh(out, rig->service, place, NULL);
    SPIN_UNTIL(out->calls > 0);
    fuzz_check(provs, n, out, place, deadline_ms);
    if (hangs) /* only a hanging provider can make the refresh last until the deadline */
      g_assert_cmpint(elapsed_ms(out), >=, FUZZ_DEADLINE_MS);

    for (guint i = 0; i < n; i++) {
      if (provs[i].prov != NULL) {
        test_prov_release(provs[i].prov); /* late deliveries */
        g_object_unref(provs[i].prov);
      }
      g_clear_pointer(&provs[i].member, wx_member_unref);
    }
    /* free the outcome but keep the call count: a second callback would be seen below */
    g_clear_pointer(&out->forecast, wx_forecast_unref);
    g_clear_error(&out->error);
    rig_free(rig);
  }
  drain_ms(150);
  for (guint i = 0; i < outs->len; i++)
    g_assert_cmpuint(((Out *)g_ptr_array_index(outs, i))->calls, ==, 1);
  g_ptr_array_unref(outs);
}

/* ------------------------------------------------------------------------ */
/* Test harness                                                             */
/* ------------------------------------------------------------------------ */

typedef struct {
  void (*fn)(void);
} Case;

static gboolean
heartbeat(gpointer user_data)
{
  (void)user_data;
  return G_SOURCE_CONTINUE;
}

/* Wraps every test: the deadline hook starts each one at the production value. */
static void
run_test(gconstpointer data)
{
  const Case *test_case = data;
  wx_service_test_set_deadline_ms(0);
  test_case->fn();
  wx_service_test_set_deadline_ms(0);
}

#define ADD(path, function)                         \
  G_STMT_START {                                    \
    static const Case case_ = {function};           \
    g_test_add_data_func(path, &case_, run_test);   \
  }                                                 \
  G_STMT_END

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
  test_root = g_dir_make_tmp("wx-service-XXXXXX", &error);
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

int
main(int argc, char **argv)
{
  isolate_environment();
  g_test_init(&argc, &argv, NULL);
  g_timeout_add(50, heartbeat, NULL); /* wakes a blocking main-context iteration */

  ADD("/service/constants", test_constants);
  ADD("/service/new", test_new);
  ADD("/service/refresh/all-ok", test_refresh_all_ok);
  ADD("/service/refresh/starts-all-at-once", test_refresh_starts_all_at_once);
  ADD("/service/refresh/order-independent", test_refresh_order_independent);
  ADD("/service/refresh/duplicate-members", test_refresh_duplicate_members);
  ADD("/service/refresh/one-fails", test_refresh_one_fails);
  ADD("/service/refresh/each-error-code", test_refresh_each_error_code);
  ADD("/service/refresh/all-fail-single", test_refresh_all_fail_single);
  ADD("/service/refresh/error-ranking", test_refresh_error_ranking);
  ADD("/service/refresh/error-ranking-blend", test_refresh_error_ranking_blend);
  ADD("/service/refresh/local-refusal-ranks-last", test_refresh_local_refusal_ranks_last);
  ADD("/service/refresh/genuine-rate-limit-keeps-rank", test_refresh_genuine_rate_limit_keeps_rank);
  ADD("/service/refresh/blend-not-found", test_refresh_blend_not_found);
  ADD("/service/refresh/no-members", test_refresh_no_members);
  ADD("/service/refresh/garbage-results", test_refresh_garbage_results);
  ADD("/service/refresh/foreign-errors", test_refresh_foreign_errors);
  ADD("/service/refresh/result-with-error", test_refresh_result_with_error);
  ADD("/service/refresh/cancelled-providers", test_refresh_cancelled_providers);
  ADD("/service/refresh/source-fields", test_refresh_source_fields);
  ADD("/service/refresh/skipped", test_refresh_skipped);
  ADD("/service/refresh/no-covering", test_refresh_no_covering);
  ADD("/service/refresh/invalid-place", test_refresh_invalid_place);
  ADD("/service/refresh/programmer-errors", test_refresh_programmer_errors);
  ADD("/service/refresh/place-is-copied", test_refresh_place_is_copied);

  ADD("/service/deadline/partial", test_deadline_partial);
  ADD("/service/deadline/cancels-stragglers", test_deadline_cancels_stragglers);
  ADD("/service/deadline/all-hang", test_deadline_all_hang);
  ADD("/service/deadline/ignoring-provider", test_deadline_ignoring_provider);
  ADD("/service/deadline/not-before-all-done", test_deadline_not_before_all_done);
  ADD("/service/deadline/per-refresh", test_deadline_per_refresh);

  ADD("/service/cancel/pre-cancelled", test_cancel_pre_cancelled);
  ADD("/service/cancel/in-flight", test_cancel_in_flight);
  ADD("/service/cancel/after-completion", test_cancel_after_completion);
  ADD("/service/cancel/ignoring-provider", test_cancel_ignoring_provider);
  ADD("/service/cancel/from-thread", test_cancel_from_thread);
  ADD("/service/cancel/deadline-leaves-caller-alone", test_cancel_deadline_leaves_caller_alone);

  ADD("/service/dispose/last-reference", test_dispose_last_reference);
  ADD("/service/dispose/run-dispose", test_dispose_run_dispose);
  ADD("/service/dispose/late-completion", test_dispose_late_completion);
  ADD("/service/dispose/registry-dropped", test_dispose_registry_dropped);

  ADD("/service/reentrancy/refresh-from-callback", test_reentrancy_refresh_from_callback);
  ADD("/service/reentrancy/drop-service-in-callback", test_reentrancy_drop_service_in_callback);
  ADD("/service/reentrancy/registry-changes-in-covers", test_reentrancy_registry_changes_in_covers);
  ADD("/service/reentrancy/synchronous-provider", test_reentrancy_synchronous_provider);
  ADD("/service/reentrancy/cancel-during-start", test_reentrancy_cancel_during_start);
  ADD("/service/reentrancy/refresh-from-provider", test_reentrancy_refresh_from_provider);

  ADD("/service/context/private", test_private_context);
  ADD("/service/refresh/limits", test_refresh_limits);
  ADD("/service/refresh/random-scenarios", test_refresh_random_scenarios);

  ADD("/service/share/big-provider-first", test_share_big_provider_first);
  ADD("/service/share/unusable-members", test_share_unusable_members);
  ADD("/service/share/quarters-only", test_share_quarters_only);
  ADD("/service/share/many-providers", test_share_many_providers);
  ADD("/service/share/duplicates", test_share_duplicates);
  ADD("/service/share/many-copies", test_share_many_copies);
  ADD("/service/share/exact-sets", test_share_exact_sets);
  ADD("/service/share/exact-random", test_share_exact_random);
  ADD("/service/share/random", test_share_random);

  ADD("/service/search/ok", test_search_ok);
  ADD("/service/search/pass-through", test_search_pass_through);
  ADD("/service/search/no-geocoder", test_search_no_geocoder);
  ADD("/service/search/errors", test_search_errors);
  ADD("/service/search/invalid-text", test_search_invalid_text);
  ADD("/service/search/cancel", test_search_cancel);
  ADD("/service/search/hostile-hits", test_search_hostile_hits);
  ADD("/service/search/hits-with-error", test_search_hits_with_error);
  ADD("/service/search/geocoder-replaced", test_search_geocoder_replaced);
  ADD("/service/search/dispose-in-flight", test_search_dispose_in_flight);
  ADD("/service/search/programmer-errors", test_search_programmer_errors);

  ADD("/service/finish/errors", test_finish_errors);
  return g_test_run();
}
