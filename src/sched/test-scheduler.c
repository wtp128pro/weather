/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * test-scheduler.c - offline unit tests of WxScheduler (src/sched/wx-scheduler.h).
 *
 * Pure logic: no display, no network, no main loop, no real clock. Every test
 * drives the scheduler with a fake WxSchedTime. The fixture checks, after
 * every call, the invariants that must hold at all times: at most one
 * outstanding request per place (cancelled ones included), at most
 * WX_SCHED_MAX_INFLIGHT in total, unique non-zero ids, CANCEL only for
 * outstanding requests and at most once per request, no FETCH while the window
 * is hidden or the network is down, wx_scheduler_n_inflight() equal to the
 * fixture's own count, and a wakeup deadline that exists exactly while the
 * scheduler is active with at least one place and is never more than one
 * period ahead. The random-walk tests then apply long seeded input sequences
 * and additionally check that every place an event round must refresh is
 * refreshed (liveness) and that the stale mark of a place changes only where
 * wx-scheduler.h says it can.
 *
 * Nothing here depends on the local time zone, the locale or the real clock.
 */
#define _XOPEN_SOURCE 700 /* sysconf() under -std=c11 */
#define _DEFAULT_SOURCE   /* MAP_ANONYMOUS */

#include <glib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-scheduler.h"

/* Microseconds per second as a gint64: products like 2200 * SEC must not overflow an int. */
#define SEC ((gint64)G_USEC_PER_SEC)

#define MIA "25.7617,-80.1918"
#define TPA "27.9506,-82.4572"
#define ORL "28.5383,-81.3792"
#define LON "51.5072,-0.1276"
#define TYO "35.6762,139.6503"

#define EXPECT_CRITICAL(pattern) \
  g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, pattern)

/* ------------------------------------------------------------------------ */
/* Fixture                                                                  */
/* ------------------------------------------------------------------------ */

typedef struct {
  guint64 id;
  char key[WX_SCHED_KEY_BYTES];
  gboolean cancelled;
} Outstanding;

typedef struct {
  WxScheduler *s;
  gint64 mono_us;
  gint64 wall_ms;
  gboolean visible, online;
  guint n_places; /* distinct valid tracked places, as the tests know them */
  GArray *all;  /* WxSchedAction: everything emitted so far     */
  GArray *last; /* WxSchedAction: emitted by the latest call    */
  GArray *out;  /* Outstanding                                  */
} Fx;

static WxSchedTime
now_of(const Fx *fx)
{
  WxSchedTime t = {fx->mono_us, fx->wall_ms};
  return t;
}

/* Collects the actions of the latest call and checks every invariant. */
static void
collect(Fx *fx)
{
  g_clear_pointer(&fx->last, g_array_unref);
  fx->last = wx_scheduler_take_actions(fx->s);
  if (fx->last != NULL) {
    g_assert_cmpuint(fx->last->len, >, 0);
    for (guint i = 0; i < fx->last->len; i++) {
      WxSchedAction a = g_array_index(fx->last, WxSchedAction, i);
      g_array_append_val(fx->all, a);
      if (a.type == WX_SCHED_CANCEL) {
        gboolean found = FALSE;
        for (guint j = 0; j < fx->out->len; j++) {
          Outstanding *o = &g_array_index(fx->out, Outstanding, j);
          if (o->id == a.id) {
            found = TRUE;
            g_assert_false(o->cancelled); /* never cancelled twice */
            o->cancelled = TRUE;
          }
        }
        g_assert_true(found); /* CANCEL only for an outstanding request */
        g_assert_cmpstr(a.key, ==, "");
        continue;
      }
      g_assert_cmpint(a.type, ==, WX_SCHED_FETCH);
      g_assert_true(fx->visible && fx->online); /* never a request while inactive */
      g_assert_cmpuint(a.id, !=, 0);
      g_assert_cmpuint(strlen(a.key), >, 0);
      Outstanding o;
      memset(&o, 0, sizeof o);
      o.id = a.id;
      memcpy(o.key, a.key, sizeof o.key);
      for (guint j = 0; j < fx->out->len; j++) {
        const Outstanding *p = &g_array_index(fx->out, Outstanding, j);
        g_assert_cmpuint(p->id, !=, a.id);
        g_assert_cmpstr(p->key, !=, a.key); /* one request per place */
      }
      for (guint j = 0; j + 1 < fx->all->len; j++)
        g_assert_cmpuint(g_array_index(fx->all, WxSchedAction, j).id, !=, a.id); /* ids never reused */
      g_array_append_val(fx->out, o);
      g_assert_cmpuint(fx->out->len, <=, WX_SCHED_MAX_INFLIGHT);
    }
  }
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, fx->out->len);
  /* The deadline exists exactly while active with at least one place, at most a period ahead. */
  gint64 wake = wx_scheduler_next_wakeup_us(fx->s);
  gboolean armed = fx->visible && fx->online && fx->n_places > 0;
  g_assert_cmpint(wake >= 0, ==, armed);
  if (armed && fx->mono_us <= G_MAXINT64 - WX_SCHED_PERIOD_US)
    g_assert_cmpint(wake, <=, fx->mono_us + WX_SCHED_PERIOD_US);
}

static Fx *
fx_new(void)
{
  Fx *fx = g_new0(Fx, 1);
  fx->s = wx_scheduler_new();
  fx->mono_us = 1000 * SEC;
  fx->wall_ms = G_GINT64_CONSTANT(1790000000000); /* some UTC instant; only differences matter */
  fx->all = g_array_new(FALSE, FALSE, sizeof(WxSchedAction));
  fx->out = g_array_new(FALSE, FALSE, sizeof(Outstanding));
  return fx;
}

static void
fx_free(Fx *fx)
{
  g_clear_pointer(&fx->last, g_array_unref);
  g_array_unref(fx->all);
  g_array_unref(fx->out);
  wx_scheduler_free(fx->s);
  g_free(fx);
}

/* Moves both clocks forward by @seconds (the wall clock saturates). */
static void
fx_advance(Fx *fx, gint64 seconds)
{
  /* Both clocks saturate: the extreme-clock tests start close to the ends of the range. */
  if (fx->mono_us > G_MAXINT64 - seconds * SEC)
    fx->mono_us = G_MAXINT64;
  else
    fx->mono_us += seconds * SEC;
  if (fx->wall_ms > G_MAXINT64 - seconds * 1000)
    fx->wall_ms = G_MAXINT64;
  else
    fx->wall_ms += seconds * 1000;
}

static void
fx_places(Fx *fx, const char *const *keys, gsize n)
{
  wx_scheduler_set_places(fx->s, now_of(fx), keys, n);
  /* The tests only pass valid, distinct keys through here, except where they set n_places. */
  collect(fx);
}

static void
fx_select(Fx *fx, const char *key)
{
  wx_scheduler_set_selection(fx->s, now_of(fx), key);
  collect(fx);
}

static void
fx_visible(Fx *fx, gboolean v)
{
  fx->visible = v;
  wx_scheduler_set_visible(fx->s, now_of(fx), v);
  collect(fx);
}

static void
fx_online(Fx *fx, gboolean v)
{
  fx->online = v;
  wx_scheduler_set_online(fx->s, now_of(fx), v);
  collect(fx);
}

static void
fx_focus(Fx *fx)
{
  wx_scheduler_focus_regained(fx->s, now_of(fx));
  collect(fx);
}

static void
fx_tick(Fx *fx)
{
  wx_scheduler_tick(fx->s, now_of(fx));
  collect(fx);
}

static void
fx_done(Fx *fx, guint64 id, WxSchedResult r)
{
  wx_scheduler_request_done(fx->s, now_of(fx), id, r);
  for (guint j = 0; j < fx->out->len; j++) {
    if (g_array_index(fx->out, Outstanding, j).id == id) {
      g_array_remove_index(fx->out, j);
      break;
    }
  }
  collect(fx);
}

/* Completes everything outstanding (and whatever that starts) with @r. */
static void
fx_finish_all(Fx *fx, WxSchedResult r)
{
  for (guint guard = 0; fx->out->len > 0; guard++) {
    g_assert_cmpuint(guard, <, 100000);
    fx_done(fx, g_array_index(fx->out, Outstanding, 0).id, r);
  }
}

static guint64
out_id(const Fx *fx, const char *key)
{
  for (guint j = 0; j < fx->out->len; j++) {
    const Outstanding *o = &g_array_index(fx->out, Outstanding, j);
    if (strcmp(o->key, key) == 0)
      return o->id;
  }
  return 0;
}

static gboolean
out_cancelled(const Fx *fx, const char *key)
{
  for (guint j = 0; j < fx->out->len; j++) {
    const Outstanding *o = &g_array_index(fx->out, Outstanding, j);
    if (strcmp(o->key, key) == 0)
      return o->cancelled;
  }
  g_assert_not_reached();
}

/* Counts actions of @type in @arr from index @from on; @key NULL = any. */
static guint
count_from(const GArray *arr, guint from, WxSchedActionType type, const char *key)
{
  guint n = 0;
  if (arr == NULL)
    return 0;
  for (guint i = from; i < arr->len; i++) {
    const WxSchedAction *a = &g_array_index(arr, WxSchedAction, i);
    if (a->type == type && (key == NULL || strcmp(a->key, key) == 0))
      n++;
  }
  return n;
}

#define COUNT_ALL(fx, type, key) count_from((fx)->all, 0, type, key)
#define COUNT_LAST(fx, type, key) count_from((fx)->last, 0, type, key)
#define COUNT_SINCE(fx, mark, type, key) count_from((fx)->all, mark, type, key)
#define NO_ACTIONS(fx) g_assert_null((fx)->last)
/* The latest call produced exactly @n actions (a NULL batch is a failure, not a crash). */
#define ASSERT_LAST_LEN(fx, n)                   \
  G_STMT_START {                                 \
    g_assert_nonnull((fx)->last);                \
    g_assert_cmpuint((fx)->last->len, ==, (n));  \
  }                                              \
  G_STMT_END

/* The key of the i-th action of the latest call. */
static const char *
last_key(const Fx *fx, guint i)
{
  g_assert_nonnull(fx->last);
  g_assert_cmpuint(i, <, fx->last->len);
  return g_array_index(fx->last, WxSchedAction, i).key;
}

static const char *const k_three[] = {MIA, TPA, ORL};
static const char *const k_five[] = {MIA, TPA, ORL, LON, TYO};

static void
fx_set_known(Fx *fx, const char *const *keys, gsize n)
{
  fx->n_places = (guint)n;
  fx_places(fx, keys, n);
}

/* Visible + online + @keys, nothing completed. */
static Fx *
fx_started(const char *const *keys, gsize n)
{
  Fx *fx = fx_new();
  fx_set_known(fx, keys, n);
  fx_online(fx, TRUE);
  fx_visible(fx, TRUE);
  return fx;
}

/* ------------------------------------------------------------------------ */
/* Helpers of the cases below                                               */
/* ------------------------------------------------------------------------ */

#define SYD "-33.8688,151.2093"

/* Moves the monotonic clock to the absolute @mono_us and the wall clock by the same amount. */
static void
fx_set_mono(Fx *fx, gint64 mono_us)
{
  g_assert_cmpint(mono_us, >=, fx->mono_us);
  fx->wall_ms += (mono_us - fx->mono_us) / 1000;
  fx->mono_us = mono_us;
}

/* Jumps only the wall clock (suspend/resume, clock set). */
static void
fx_jump_wall(Fx *fx, gint64 seconds)
{
  fx->wall_ms += seconds * 1000;
}

/*
 * The scenario of the freshness cases: MIA, TPA and ORL are fetched at t = 1000 s and report OK
 * at t = 1100 s (so the periodic deadline of 1600 s finds those successes 500 s old, inside the
 * 540 s periodic window); a focus event at t = 1230 s (130 s old: outside the 120 s event
 * window) starts a second request for each of them, all three outstanding at t = 1230 s.
 */
static Fx *
fx_second_requests(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_set_mono(fx, 1100 * SEC);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, 1600 * SEC);
  fx_set_mono(fx, 1230 * SEC);
  fx_focus(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  return fx;
}

/* ------------------------------------------------------------------------ */
/* Idle, rounds, in-flight cap, start order                                 */
/* ------------------------------------------------------------------------ */

static void
test_idle_has_no_actions_no_timer(void)
{
  Fx *fx = fx_new();
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  g_assert_null(wx_scheduler_take_actions(fx->s));
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  fx_set_known(fx, k_three, G_N_ELEMENTS(k_three));
  NO_ACTIONS(fx);
  fx_visible(fx, TRUE); /* visible but offline */
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_advance(fx, 600);
  fx_tick(fx);
  NO_ACTIONS(fx);
  fx_online(fx, TRUE); /* now active: exactly one round */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_free(fx);

  wx_scheduler_free(NULL); /* allowed */
}

static void
test_start_round_once_per_place(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  ASSERT_LAST_LEN(fx, 3);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);

  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  for (guint i = 0; i < 3; i++) {
    g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, k_three[i]), ==, 1);
    g_assert_false(wx_scheduler_is_stale(fx->s, k_three[i]));
  }
  g_assert_cmpuint(fx->all->len, ==, 3);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);

  /* Showing again while already visible, or going online again: nothing. */
  fx_visible(fx, TRUE);
  fx_online(fx, TRUE);
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_inflight_cap(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five));
  ASSERT_LAST_LEN(fx, WX_SCHED_MAX_INFLIGHT);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, WX_SCHED_MAX_INFLIGHT);
  /* Asking again while requests are in flight or waiting does not duplicate anything. */
  guint mark = fx->all->len;
  fx_focus(fx);
  fx_focus(fx);
  fx_visible(fx, TRUE);
  fx_online(fx, TRUE);
  NO_ACTIONS(fx);
  g_assert_cmpuint(fx->all->len, ==, mark);
  /* One completes: exactly one more starts, in list order. */
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_FAILED);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO);
  /* The failed request is not retried within the same round. */
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpuint(fx->all->len, ==, 5);
  fx_free(fx);
}

static void
test_start_order_selected_first(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_five, G_N_ELEMENTS(k_five));
  fx_select(fx, LON); /* the fourth place */
  fx_online(fx, TRUE);
  fx_visible(fx, TRUE);
  /* Three slots: the selected place first, then list order. */
  ASSERT_LAST_LEN(fx, WX_SCHED_MAX_INFLIGHT);
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  g_assert_cmpstr(last_key(fx, 1), ==, MIA);
  g_assert_cmpstr(last_key(fx, 2), ==, TPA);
  fx_done(fx, out_id(fx, LON), WX_SCHED_RESULT_OK);
  g_assert_cmpstr(last_key(fx, 0), ==, ORL);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Selection                                                                */
/* ------------------------------------------------------------------------ */

static void
test_selection_fetches_nothing(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx_advance(fx, 500); /* every success is old, yet changing the selection fetches nothing */
  fx_select(fx, TPA);
  NO_ACTIONS(fx);
  fx_select(fx, ORL);
  NO_ACTIONS(fx);
  fx_select(fx, NULL);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  for (guint i = 0; i < 3; i++)
    g_assert_false(wx_scheduler_is_stale(fx->s, k_three[i])); /* no stale mark changes */
  fx_free(fx);
}

/* Every slot busy: selecting a waiting place cancels nothing and fetches nothing; the place
 * simply goes first when a slot frees, ahead of the places before it in the list. */
static void
test_selection_all_slots_busy(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five)); /* MIA, TPA, ORL in flight; LON, TYO wait */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, WX_SCHED_MAX_INFLIGHT);
  fx_select(fx, TYO);
  NO_ACTIONS(fx);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, WX_SCHED_MAX_INFLIGHT);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO); /* ahead of LON */
  /* Selecting a place that is already in flight changes nothing either. */
  fx_select(fx, TPA);
  NO_ACTIONS(fx);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_selection_invalid_or_untracked(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* An invalid selection is "none"; the selection need not be tracked (yet). */
  fx_select(fx, "bad key");
  fx_select(fx, NULL);
  fx_select(fx, "");
  fx_select(fx, "1.0000,2.0000");
  NO_ACTIONS(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, "1.0000,2.0000"));
  /* The untracked selection takes effect once the place appears: it goes first. */
  fx_advance(fx, 10);
  const char *five[] = {MIA, TPA, ORL, LON, "1.0000,2.0000"};
  fx_set_known(fx, five, G_N_ELEMENTS(five));
  ASSERT_LAST_LEN(fx, 2); /* the two new places (LON and the former selection), both fit */
  g_assert_cmpstr(last_key(fx, 0), ==, "1.0000,2.0000");
  g_assert_cmpstr(last_key(fx, 1), ==, LON);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Periodic rounds                                                          */
/* ------------------------------------------------------------------------ */

static void
test_periodic_deadline_and_early_tick(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  g_assert_cmpint(deadline, ==, 1000 * SEC + WX_SCHED_PERIOD_US);

  fx_advance(fx, 300); /* an early tick changes nothing */
  fx_tick(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  /* An event round in between (the successes are 300 s old, so it refreshes) does not move it. */
  fx_focus(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  fx_free(fx);
}

static void
test_periodic_skips_young_successes(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 100);
  fx_finish_all(fx, WX_SCHED_RESULT_OK); /* successes at 1100 s */
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  g_assert_cmpint(deadline, ==, 1600 * SEC);
  /* The deadline finds the successes 500 s old, younger than 540 s: skipped. */
  fx_set_mono(fx, deadline);
  fx_tick(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline + WX_SCHED_PERIOD_US);
  /* One period later they are 1100 s old: a round for every place. */
  fx_advance(fx, 600);
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline + 2 * WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* The boundary: a success exactly WX_SCHED_PERIODIC_FRESH_US old is not fresh any more. */
static void
test_periodic_freshness_540s_is_stale(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 60);
  fx_finish_all(fx, WX_SCHED_RESULT_OK); /* successes at 1060 s; the deadline is at 1600 s */
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s) - fx->mono_us, ==, WX_SCHED_PERIODIC_FRESH_US);
  fx_set_mono(fx, wx_scheduler_next_wakeup_us(fx->s));
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_periodic_freshness_539s_is_fresh(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 61);
  fx_finish_all(fx, WX_SCHED_RESULT_OK); /* successes at 1061 s: 539 s before the deadline */
  fx_set_mono(fx, wx_scheduler_next_wakeup_us(fx->s));
  fx_tick(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_periodic_late_and_no_catch_up(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx_set_mono(fx, deadline);
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);

  /* Woken very late (a long stall of the process): one round, the next a full period later. */
  fx_advance(fx, 3600);
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_tick(fx); /* the same instant again: no catch-up round */
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_periodic_merges_with_inflight(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five));
  /* Slow responses: a periodic tick arrives while the first wave is still in flight. */
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx_set_mono(fx, deadline);
  guint mark = fx->all->len;
  fx_tick(fx);
  NO_ACTIONS(fx);
  g_assert_cmpuint(COUNT_SINCE(fx, mark, WX_SCHED_FETCH, NULL), ==, 0);
  /* The places that were waiting are still waiting (merged), not duplicated. */
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  for (guint i = 0; i < 5; i++)
    g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, k_five[i]), ==, 1);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Event rounds: freshness window, show/hide, network, focus                */
/* ------------------------------------------------------------------------ */

static void
test_event_freshness_119s_is_fresh(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_advance(fx, 119);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_event_freshness_120s_is_stale(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_advance(fx, 120);
  fx_focus(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* The two windows differ: a success 300 s old is stale for an event round, fresh for the periodic
 * round whose deadline then arrives. */
static void
test_event_and_periodic_windows_differ(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 300);
  fx_finish_all(fx, WX_SCHED_RESULT_OK); /* successes at 1300 s; the deadline stays at 1600 s */
  fx_set_mono(fx, 1430 * SEC);
  fx_tick(fx); /* early */
  NO_ACTIONS(fx);
  fx_set_mono(fx, 1600 * SEC); /* the successes are 300 s old */
  fx_tick(fx);
  NO_ACTIONS(fx); /* the periodic round skips them ... */
  fx_focus(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3); /* ... an event round does not */
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_event_show_hide_cycle(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* A hide/show cycle inside the window does not refetch; one outside does. */
  fx_advance(fx, 5);
  fx_visible(fx, FALSE);
  NO_ACTIONS(fx); /* nothing was in flight */
  fx_advance(fx, 5);
  fx_visible(fx, TRUE);
  NO_ACTIONS(fx);
  fx_advance(fx, 200);
  fx_visible(fx, FALSE);
  fx_visible(fx, TRUE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_event_network_cycle(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_advance(fx, 10);
  fx_online(fx, FALSE);
  fx_online(fx, TRUE);
  NO_ACTIONS(fx); /* inside the window */
  fx_advance(fx, 130);
  fx_online(fx, FALSE);
  fx_online(fx, TRUE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_focus_regained_runs_one_round(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_advance(fx, 130);
  fx_focus(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_focus(fx); /* a second focus event while the first round is in flight: merged */
  NO_ACTIONS(fx);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_focus(fx); /* just refreshed */
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_focus_while_offline(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_three, G_N_ELEMENTS(k_three));
  fx_visible(fx, TRUE); /* visible, offline */
  fx_focus(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_advance(fx, 500);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_online(fx, TRUE); /* the reconnect is the event round */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_focus_while_hidden(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_three, G_N_ELEMENTS(k_three));
  fx_online(fx, TRUE); /* online, hidden */
  fx_focus(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_visible(fx, TRUE); /* showing is the event round, exactly one */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* A focus event while the window is hidden is not an event round: it must leave no waiting state
 * behind. The requests that were cancelled by the hide finish OK anyway; when the window is shown
 * again those places are fresh and must not be fetched again. */
static void
test_focus_while_hidden_leaves_no_waiting_state(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_visible(fx, FALSE);
  ASSERT_LAST_LEN(fx, 3); /* three CANCELs */
  fx_advance(fx, 1);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  NO_ACTIONS(fx);
  fx_advance(fx, 1);
  fx_visible(fx, TRUE);
  NO_ACTIONS(fx); /* every place succeeded 1 s ago */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  fx_free(fx);
}

/* The same with the network down: focus while offline wants nothing. */
static void
test_focus_while_offline_leaves_no_waiting_state(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_online(fx, FALSE);
  ASSERT_LAST_LEN(fx, 3);
  fx_advance(fx, 1);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  NO_ACTIONS(fx);
  fx_advance(fx, 1);
  fx_online(fx, TRUE);
  NO_ACTIONS(fx);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Failure, cancellation and the memory of the latest success               */
/* ------------------------------------------------------------------------ */

static void
test_failure_marks_stale(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_CANCELLED);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_false(wx_scheduler_is_stale(fx->s, TPA));
  g_assert_false(wx_scheduler_is_stale(fx->s, ORL)); /* cancellation never marks stale */
  /* Nothing retries by itself. */
  fx_advance(fx, 10);
  fx_tick(fx); /* no deadline has been reached */
  NO_ACTIONS(fx);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_free(fx);
}

static void
test_stale_query_edge_keys(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_false(wx_scheduler_is_stale(fx->s, LON)); /* unknown */
  g_assert_false(wx_scheduler_is_stale(fx->s, NULL));
  g_assert_false(wx_scheduler_is_stale(fx->s, "not a key"));
  g_assert_false(wx_scheduler_is_stale(fx->s, ""));
  g_assert_false(wx_scheduler_is_stale(fx->s, "25.7617,-80.1918 "));
  g_assert_false(wx_scheduler_is_stale(fx->s, "123456789012345678901234"));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_failure_retried_by_event_round(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_CANCELLED);
  fx_advance(fx, 10);
  /* The failed place and the cancelled one (it never succeeded) are wanted, the fresh one is not,
   * even though the round is inside the freshness window of TPA only. */
  fx_focus(fx);
  ASSERT_LAST_LEN(fx, 2);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, ORL), ==, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, TPA), ==, 0);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA)); /* the mark stays until a success */
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* "No other call changes a mark": a failed place stays stale through hide, show, offline, online,
 * focus, ticks, selection changes and place-list changes that keep it, until a request succeeds. */
static void
test_stale_mark_survives_every_other_input(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_visible(fx, FALSE);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_online(fx, FALSE);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_online(fx, TRUE); /* hidden: no round */
  fx_visible(fx, TRUE); /* the round retries MIA; the request is outstanding, the mark stays */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_select(fx, MIA);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_select(fx, TPA);
  fx_focus(fx);
  fx_advance(fx, 700);
  fx_tick(fx);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  const char *reordered[] = {ORL, TPA, MIA};
  fx_set_known(fx, reordered, 3);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  /* Only a success clears it (a cancelled completion does not). */
  fx_visible(fx, FALSE);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_visible(fx, TRUE);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_failure_retried_by_periodic_round(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_advance(fx, 100);
  fx_finish_all(fx, WX_SCHED_RESULT_OK); /* TPA, ORL succeed at 1100 s; MIA failed at 1000 s */
  fx_set_mono(fx, wx_scheduler_next_wakeup_us(fx->s));
  fx_tick(fx); /* the others are 500 s old (fresh for periodic rounds); the failed one is wanted */
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* A failure forgets the earlier success: the periodic round wants the place although that success
 * (t = 1100 s) is only 500 s old at the deadline, whereas a place whose second request was merely
 * cancelled keeps it (see the next case). */
static void
test_failure_forgets_earlier_success(void)
{
  Fx *fx = fx_second_requests();
  fx_advance(fx, 1);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_set_mono(fx, 1600 * SEC);
  fx_tick(fx);
  ASSERT_LAST_LEN(fx, 1); /* TPA, ORL: successes 369 s old, skipped */
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* A cancelled newest request leaves the earlier success in place: the success of t = 1100 s is
 * 500 s old at the periodic deadline (inside the 540 s window), so that round skips the place; a
 * round after the window wants it. */
static void
test_cancelled_newest_request_keeps_earlier_success(void)
{
  Fx *fx = fx_second_requests();
  fx_advance(fx, 1);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_CANCELLED); /* the owner cancelled it itself */
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_set_mono(fx, 1600 * SEC);
  fx_tick(fx);
  NO_ACTIONS(fx); /* MIA: success 500 s old; TPA, ORL: 369 s old */
  fx_set_mono(fx, 2200 * SEC);
  fx_tick(fx); /* after the window: everything is old */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* The same cancelled request does not count as a success for the event round either: the earlier
 * success is 140 s old, outside the 120 s window, so the place is wanted again at once. */
static void
test_cancelled_newest_request_event_round_wants_again(void)
{
  Fx *fx = fx_second_requests();
  fx_advance(fx, 1);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_CANCELLED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  fx_advance(fx, 9);
  fx_focus(fx);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* A request that completes OK after its CANCEL was issued is a success like any other: the place
 * is fresh, no stale mark appears, and the event round after showing again skips it. */
static void
test_ok_after_cancel_counts_as_success(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 1);
  fx_visible(fx, FALSE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 3);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK); /* finished before it noticed the cancel */
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_CANCELLED);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_FAILED); /* failed on the way down */
  NO_ACTIONS(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_false(wx_scheduler_is_stale(fx->s, TPA));
  g_assert_true(wx_scheduler_is_stale(fx->s, ORL));
  fx_advance(fx, 1);
  fx_visible(fx, TRUE);
  ASSERT_LAST_LEN(fx, 2); /* MIA is fresh: skipped */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 0);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* MIA's success is dated at the time it was reported (t = 1001 s), TPA's and ORL's at t = 1002 s.
   * At t = 1120 s MIA is 119 s old: still fresh. */
  fx_advance(fx, 118);
  fx_focus(fx);
  NO_ACTIONS(fx);
  /* At t = 1121 s MIA is exactly 120 s old and wanted; TPA and ORL are 119 s old and not. */
  fx_advance(fx, 1);
  fx_focus(fx);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_cancelled_never_fresh(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_advance(fx, 1);
  fx_visible(fx, FALSE);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  /* Nothing arrived: showing a second later wants every place. */
  fx_advance(fx, 1);
  fx_visible(fx, TRUE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  /* A success then makes only that place fresh. */
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_CANCELLED);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_FAILED);
  fx_advance(fx, 1);
  fx_focus(fx);
  ASSERT_LAST_LEN(fx, 2);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 0);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_hide_cancels_and_drops_waiting(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five));
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);
  guint64 id_mia = out_id(fx, MIA);
  fx_visible(fx, FALSE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  /* Cancelled requests keep their slots until reported; nothing waiting starts. */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);
  fx_done(fx, id_mia, WX_SCHED_RESULT_CANCELLED);
  NO_ACTIONS(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  NO_ACTIONS(fx); /* the dropped waiting places (LON, TYO) did not start */
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, LON), ==, 0);
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, TYO), ==, 0);
  fx_free(fx);
}

/* Showing again before the cancelled requests are reported: a place whose request is still
 * winding down cannot restart yet (no overlap); the others can. */
static void
test_show_before_cancelled_requests_reported(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five));
  fx_visible(fx, FALSE);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_CANCELLED);
  fx_visible(fx, TRUE);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1); /* its slot was freed */
  g_assert_true(out_cancelled(fx, TPA));
  g_assert_true(out_cancelled(fx, ORL));
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, TPA), ==, 1);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_CANCELLED);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, TPA), ==, 1); /* the freed slot restarts it */
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* Everything was fetched, and (fixture) never two requests of one place at once. */
  for (guint i = 0; i < 5; i++)
    g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, k_five[i]), >=, 1);
  fx_free(fx);
}

/* Hide, show (the cancelled requests are still winding down, so the places wait for them), hide
 * again, and only then do the cancelled requests finish OK: the second hide dropped the waiting,
 * so showing once more fetches nothing for these now fresh places. */
static void
test_hide_show_hide_before_cancels_reported(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_visible(fx, FALSE);
  ASSERT_LAST_LEN(fx, 3);
  fx_advance(fx, 1);
  fx_visible(fx, TRUE);
  NO_ACTIONS(fx); /* the places wait for their cancelled requests */
  fx_visible(fx, FALSE);
  NO_ACTIONS(fx); /* already being cancelled: no second CANCEL */
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  NO_ACTIONS(fx);
  fx_advance(fx, 1);
  fx_visible(fx, TRUE);
  NO_ACTIONS(fx);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  fx_free(fx);
}

static void
test_offline_cancels_and_back_online(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_online(fx, FALSE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  NO_ACTIONS(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_advance(fx, 5);
  fx_focus(fx); /* offline: nothing */
  NO_ACTIONS(fx);
  fx_online(fx, TRUE); /* the cancelled requests delivered nothing: all wanted again */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* Hiding and losing the network with nothing in flight emits nothing at all. */
  fx_visible(fx, FALSE);
  fx_online(fx, FALSE);
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_dropped_waiting_wanted_again(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five)); /* LON and TYO wait for a slot */
  fx_visible(fx, FALSE);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, LON), ==, 0);
  fx_visible(fx, TRUE);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, LON), ==, 1);
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, TYO), ==, 1);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Timer                                                                    */
/* ------------------------------------------------------------------------ */

static void
test_no_timer_when_hidden_or_offline(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), >=, 0);
  fx_visible(fx, FALSE);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  fx_advance(fx, 50);
  fx_visible(fx, TRUE);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US); /* fresh */
  fx_online(fx, FALSE);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  fx_advance(fx, 50);
  fx_online(fx, TRUE);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_no_timer_without_places(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_set_known(fx, NULL, 0);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_advance(fx, 1000);
  fx_tick(fx);
  NO_ACTIONS(fx);
  const char *one[] = {MIA};
  fx_set_known(fx, one, 1); /* the first place arms a fresh deadline and is fetched at once */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_tick_while_hidden_does_nothing(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_visible(fx, FALSE);
  fx_advance(fx, 2000); /* a deadline that fires while hidden (the tick arrives late) */
  fx_tick(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* The tracked set                                                          */
/* ------------------------------------------------------------------------ */

static void
test_place_added_fetched_at_once(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx_advance(fx, 10);
  /* A new place is fetched at once; the kept ones are fresh and not refetched. */
  const char *four[] = {MIA, TPA, ORL, LON};
  fx_set_known(fx, four, 4);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline); /* the deadline is kept */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 1);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_place_reorder_keeps_state(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  const char *reordered[] = {ORL, MIA, TPA};
  fx_set_known(fx, reordered, 3);
  NO_ACTIONS(fx); /* reordering fetches nothing and keeps every state */
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_false(wx_scheduler_is_stale(fx->s, TPA));
  fx_advance(fx, 130);
  fx_focus(fx); /* list order now: ORL, MIA, TPA */
  ASSERT_LAST_LEN(fx, 3);
  g_assert_cmpstr(last_key(fx, 0), ==, ORL);
  g_assert_cmpstr(last_key(fx, 1), ==, MIA);
  g_assert_cmpstr(last_key(fx, 2), ==, TPA);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* Removing a place cancels its request and clears its mark; a removed place's result changes no
 * mark, and the cancelled request keeps its slot until it is reported. */
static void
test_place_removed_cancels_request(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five)); /* MIA, TPA, ORL in flight; LON, TYO wait */
  const char *rest[] = {LON, TYO};
  fx_set_known(fx, rest, 2);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 3);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 0); /* the cap counts cancelled requests */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_CANCELLED);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, LON), ==, 1);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_FAILED); /* a removed place's result marks nothing */
  g_assert_false(wx_scheduler_is_stale(fx->s, TPA));
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, TYO), ==, 1);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  g_assert_false(wx_scheduler_is_stale(fx->s, ORL));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  fx_free(fx);
}

/* A place that failed, is retried, and is removed while the retry is in flight: it has no stale
 * mark although its entry lingers to hold the slot, and a new place of that key starts clean. */
static void
test_place_removed_has_no_stale_mark(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  fx_advance(fx, 10);
  fx_focus(fx); /* the failed place is retried */
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA)); /* the mark stays while the retry runs */
  const char *two[] = {TPA, ORL};
  fx_set_known(fx, two, 2);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 1);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA)); /* removed: no mark, though the entry lingers */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 1);
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_CANCELLED);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  fx_advance(fx, 1);
  fx_set_known(fx, k_three, G_N_ELEMENTS(k_three)); /* added back: a new place without a mark */
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, MIA), ==, 1);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_place_removed_while_waiting(void)
{
  Fx *fx = fx_started(k_five, G_N_ELEMENTS(k_five)); /* LON waits */
  const char *without_lon[] = {MIA, TPA, ORL, TYO};
  fx_set_known(fx, without_lon, 4);
  NO_ACTIONS(fx); /* nothing in flight for LON: nothing to cancel */
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  g_assert_cmpuint(COUNT_ALL(fx, WX_SCHED_FETCH, LON), ==, 0);
  fx_free(fx);
}

static void
test_place_readded_after_cancel_reported(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_advance(fx, 1);
  const char *four[] = {MIA, TPA, ORL, LON};
  fx_set_known(fx, four, 4);
  fx_done(fx, out_id(fx, LON), WX_SCHED_RESULT_FAILED);
  g_assert_true(wx_scheduler_is_stale(fx->s, LON));
  fx_set_known(fx, k_three, 3); /* LON removed: its mark is gone, nothing in flight */
  g_assert_false(wx_scheduler_is_stale(fx->s, LON));
  NO_ACTIONS(fx);
  fx_set_known(fx, four, 4); /* a new place again: no mark, fetched at once */
  g_assert_false(wx_scheduler_is_stale(fx->s, LON));
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, LON), ==, 1);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* Revival: a place removed while its request is in flight and added back before that request is
 * reported keeps the slot (no overlap), has no stale mark, and starts when the slot frees. */
static void
test_place_revived_while_request_winds_down(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_FAILED);
  g_assert_true(wx_scheduler_is_stale(fx->s, MIA));
  const char *two[] = {TPA, ORL};
  fx_set_known(fx, two, 2); /* MIA is out of the set; TPA, ORL stay in flight */
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  /* Remove TPA while it is in flight, then add it back: it is revived. */
  fx_set_known(fx, (const char *const[]){ORL}, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 1);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 2);
  fx_set_known(fx, two, 2);
  NO_ACTIONS(fx); /* no second request while the first winds down */
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 2);
  g_assert_true(out_cancelled(fx, TPA));
  g_assert_false(wx_scheduler_is_stale(fx->s, TPA));
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_CANCELLED);
  ASSERT_LAST_LEN(fx, 1); /* now the revived place starts */
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, TPA), ==, 1);
  g_assert_false(out_cancelled(fx, TPA));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_place_clear_all(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_set_known(fx, NULL, 0);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3); /* still outstanding until reported */
  fx_finish_all(fx, WX_SCHED_RESULT_CANCELLED);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
  for (guint i = 0; i < 3; i++)
    g_assert_false(wx_scheduler_is_stale(fx->s, k_three[i]));
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

static void
test_places_added_while_inactive_wait(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_three, 3);
  NO_ACTIONS(fx);
  fx_online(fx, TRUE);
  NO_ACTIONS(fx);
  fx_visible(fx, TRUE);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* Hidden again: a new place does not fetch until the next event round. */
  fx_visible(fx, FALSE);
  fx_advance(fx, 1);
  const char *four[] = {MIA, TPA, ORL, LON};
  fx_set_known(fx, four, 4);
  NO_ACTIONS(fx);
  fx_visible(fx, TRUE);
  ASSERT_LAST_LEN(fx, 1); /* only the new place: the others are fresh */
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* The selected place is removed while its request is in flight: the request is cancelled, the
 * selection stays set but gives the removed place no priority, and when the place is added back it
 * goes first again, ahead of places that are earlier in the list. */
static void
test_remove_selected_place(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_five, G_N_ELEMENTS(k_five));
  fx_select(fx, TYO);
  fx_online(fx, TRUE);
  fx_visible(fx, TRUE);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO); /* TYO, MIA, TPA in flight; ORL, LON wait */
  const char *without_tyo[] = {MIA, TPA, ORL, LON};
  fx_set_known(fx, without_tyo, 4);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 1);
  g_assert_true(out_cancelled(fx, TYO));
  fx_done(fx, out_id(fx, TYO), WX_SCHED_RESULT_CANCELLED);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, ORL); /* list order: the removed selection has no say */
  fx_done(fx, out_id(fx, MIA), WX_SCHED_RESULT_OK);
  g_assert_cmpstr(last_key(fx, 0), ==, LON);
  /* Add the selected place back together with a new place that precedes it in the list. */
  const char *back[] = {SYD, MIA, TPA, ORL, LON, TYO};
  fx_set_known(fx, back, G_N_ELEMENTS(back));
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3); /* TPA, ORL, LON: SYD and TYO wait */
  NO_ACTIONS(fx);
  fx_done(fx, out_id(fx, TPA), WX_SCHED_RESULT_OK);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, TYO); /* the selection first, though SYD is earlier */
  fx_done(fx, out_id(fx, ORL), WX_SCHED_RESULT_OK);
  g_assert_cmpstr(last_key(fx, 0), ==, SYD);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Keys                                                                     */
/* ------------------------------------------------------------------------ */

static void
test_key_validation(void)
{
  Fx *fx = fx_new();
  fx_online(fx, TRUE);
  fx_visible(fx, TRUE);
  const char *k23 = "12345678901234567890.-,"; /* 23 characters of the alphabet */
  const char *keys[] = {NULL,
                        "",
                        "abc",
                        "25.7617, -80.1918",
                        "25.7617;-80.1918",
                        " 25.7617,-80.1918",
                        "25.7617,-80.1918\n",
                        "../../etc",
                        "%s",
                        "\xc3\xa9",
                        "123456789012345678901234", /* 24 characters: too long */
                        "1234567890123456789012345678901234567890",
                        MIA,
                        MIA, /* repeat */
                        k23,
                        "-1.5000,2.5000"};
  wx_scheduler_set_places(fx->s, now_of(fx), keys, G_N_ELEMENTS(keys));
  fx->n_places = 3; /* MIA, the 23-character key, -1.5/2.5 */
  collect(fx);
  ASSERT_LAST_LEN(fx, 3);
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  g_assert_cmpstr(last_key(fx, 1), ==, k23);
  g_assert_cmpstr(last_key(fx, 2), ==, "-1.5000,2.5000");
  g_assert_false(wx_scheduler_is_stale(fx->s, "123456789012345678901234"));
  fx_done(fx, out_id(fx, k23), WX_SCHED_RESULT_FAILED);
  g_assert_true(wx_scheduler_is_stale(fx->s, k23));
  g_assert_false(wx_scheduler_is_stale(fx->s, "123456789012345678901234"));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* An empty list with a NULL array is allowed. */
  fx->n_places = 0;
  wx_scheduler_set_places(fx->s, now_of(fx), NULL, 0);
  collect(fx);
  fx_free(fx);
}

/* Keys are read at most WX_SCHED_KEY_BYTES bytes deep: unterminated buffers at a guard page. */
static void
test_key_guard_pages(void)
{
  long page = sysconf(_SC_PAGESIZE);
  g_assert_cmpint(page, >, 0);
  Fx *fx = fx_new();
  fx_online(fx, TRUE);
  fx_visible(fx, TRUE);
  for (guint first = 0; first < 256; first++) {
    char *map = mmap(NULL, 2 * (gsize)page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
                     -1, 0);
    g_assert_true(map != MAP_FAILED);
    g_assert_cmpint(mprotect(map + page, (gsize)page, PROT_NONE), ==, 0);
    char *buf = map + page - WX_SCHED_KEY_BYTES;
    memset(buf, '1', WX_SCHED_KEY_BYTES);
    buf[0] = (char)first;
    const char *keys[] = {buf};
    wx_scheduler_set_places(fx->s, now_of(fx), keys, 1); /* never a NUL: rejected, never an overread */
    collect(fx);
    wx_scheduler_set_selection(fx->s, now_of(fx), buf);
    collect(fx);
    g_assert_false(wx_scheduler_is_stale(fx->s, buf));
    g_assert_cmpint(munmap(map, 2 * (gsize)page), ==, 0);
  }
  /* A valid key whose NUL is the very last byte of the page. */
  char *map = mmap(NULL, 2 * (gsize)page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect(map + page, (gsize)page, PROT_NONE), ==, 0);
  char *buf = map + page - sizeof MIA;
  memcpy(buf, MIA, sizeof MIA);
  const char *keys[] = {buf};
  fx->n_places = 1;
  wx_scheduler_set_places(fx->s, now_of(fx), keys, 1);
  collect(fx);
  ASSERT_LAST_LEN(fx, 1);
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  /* A 23-character key ends at the guard with its NUL as the 24th byte. */
  char *b23 = map + page - 24;
  memset(b23, '7', 23);
  b23[23] = '\0';
  const char *keys2[] = {b23};
  wx_scheduler_set_places(fx->s, now_of(fx), keys2, 1);
  collect(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 1); /* the 23-character key */
  g_assert_cmpstr(last_key(fx, 1), ==, "77777777777777777777777");
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_CANCEL, NULL), ==, 1); /* MIA left the set */
  g_assert_cmpint(munmap(map, 2 * (gsize)page), ==, 0);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* request_done() edge cases                                                */
/* ------------------------------------------------------------------------ */

static void
test_request_done_unknown_ids(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  /* Unknown, zero and huge ids are ignored, whatever the result. */
  const guint64 ids[] = {0, G_MAXUINT64, 9999, 4};
  for (guint i = 0; i < G_N_ELEMENTS(ids); i++) {
    wx_scheduler_request_done(fx->s, now_of(fx), ids[i], WX_SCHED_RESULT_FAILED);
    collect(fx);
    wx_scheduler_request_done(fx->s, now_of(fx), ids[i], WX_SCHED_RESULT_OK);
    collect(fx);
  }
  NO_ACTIONS(fx);
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 3);
  for (guint i = 0; i < 3; i++)
    g_assert_false(wx_scheduler_is_stale(fx->s, k_three[i]));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

/* A value other than OK/FAILED is handled like CANCELLED: no mark changes, the slot is freed and
 * the place counts as having delivered nothing. */
static void
test_request_done_unknown_result(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  guint64 id = out_id(fx, MIA);
  wx_scheduler_request_done(fx->s, now_of(fx), id, (WxSchedResult)42);
  for (guint j = 0; j < fx->out->len; j++)
    if (g_array_index(fx->out, Outstanding, j).id == id) {
      g_array_remove_index(fx->out, j);
      break;
    }
  collect(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 2);
  fx_advance(fx, 1);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_focus(fx);
  ASSERT_LAST_LEN(fx, 1); /* MIA never succeeded: wanted; the others are fresh */
  g_assert_cmpstr(last_key(fx, 0), ==, MIA);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_free(fx);
}

static void
test_request_done_twice(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  guint64 id = out_id(fx, MIA);
  fx_done(fx, id, WX_SCHED_RESULT_OK);
  /* Reporting the same request twice is ignored: no second effect, no mark. */
  wx_scheduler_request_done(fx->s, now_of(fx), id, WX_SCHED_RESULT_FAILED);
  collect(fx);
  g_assert_false(wx_scheduler_is_stale(fx->s, MIA));
  g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 2);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  /* The place with the doubled report is fresh from the first one. */
  fx_advance(fx, 100);
  fx_focus(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

/* ------------------------------------------------------------------------ */
/* Clocks                                                                   */
/* ------------------------------------------------------------------------ */

static void
test_clock_forward_jump_makes_deadline_due(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  /* Suspend/resume: the wall clock jumps by an hour, the monotonic clock by one second. */
  fx->mono_us += 1 * SEC;
  fx_jump_wall(fx, 1);
  fx_jump_wall(fx, 3600);
  fx_focus(fx); /* any input with a time notices the jump; the successes are 1 s old */
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us); /* due now */
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), <, deadline);
  fx_tick(fx);
  /* The successes are 1 s old: the periodic round skips them; there is no burst of rounds. */
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_tick(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

/* After a long sleep the round that became due finds old data and refetches it, once. */
static void
test_clock_forward_jump_refetches_old_data(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx->mono_us += 1000 * SEC;
  fx->wall_ms += 1000 * 1000 + 3600 * 1000;
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us + WX_SCHED_PERIOD_US);
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_tick(fx);
  NO_ACTIONS(fx);
  fx_free(fx);
}

/* A drift of exactly the tolerance does not count, one millisecond more does. */
static void
test_clock_jump_tolerance_boundary(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx->mono_us += 1 * SEC;
  fx->wall_ms += 1000 + WX_SCHED_JUMP_TOLERANCE_US / 1000;
  fx_focus(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  fx->wall_ms += 1 + WX_SCHED_JUMP_TOLERANCE_US / 1000;
  fx_focus(fx); /* the wall clock advanced 10.001 s more than the monotonic one */
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, fx->mono_us);
  fx_free(fx);
}

/* Every input that carries a time notices a forward jump; the tick also runs the due round. */
static void
test_clock_jump_noticed_by_every_input(void)
{
  enum { SET_PLACES, SET_SELECTION, SET_VISIBLE, SET_ONLINE, FOCUS, REQUEST_DONE, TICK, N_INPUTS };
  for (guint input = 0; input < N_INPUTS; input++) {
    g_test_message("input %u", input);
    Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
    fx_finish_all(fx, WX_SCHED_RESULT_OK);
    fx->mono_us += 1 * SEC;
    fx_jump_wall(fx, 1 + 3600);
    switch (input) {
    case SET_PLACES:
      fx_places(fx, k_three, G_N_ELEMENTS(k_three));
      break;
    case SET_SELECTION:
      fx_select(fx, TPA);
      break;
    case SET_VISIBLE:
      fx_visible(fx, TRUE); /* unchanged: still notices */
      break;
    case SET_ONLINE:
      fx_online(fx, TRUE);
      break;
    case FOCUS:
      fx_focus(fx);
      break;
    case REQUEST_DONE:
      wx_scheduler_request_done(fx->s, now_of(fx), 12345, WX_SCHED_RESULT_OK);
      collect(fx);
      break;
    default:
      fx_tick(fx);
      break;
    }
    NO_ACTIONS(fx); /* the successes are 1 s old */
    gint64 want = input == TICK ? fx->mono_us + WX_SCHED_PERIOD_US : fx->mono_us;
    g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, want);
    fx_free(fx);
  }
}

/* With no deadline there is nothing to bring forward: a jump changes nothing. */
static void
test_clock_jump_without_deadline(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  fx_visible(fx, FALSE);
  fx->mono_us += 1 * SEC;
  fx_jump_wall(fx, 1 + 7200);
  fx_focus(fx); /* hidden */
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_tick(fx);
  NO_ACTIONS(fx);
  fx_set_known(fx, NULL, 0);
  fx_visible(fx, TRUE); /* active but no places */
  fx_jump_wall(fx, 7200);
  fx_tick(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, -1);
  fx_free(fx);
}

static void
test_clock_backward_jump_changes_nothing(void)
{
  Fx *fx = fx_started(k_three, G_N_ELEMENTS(k_three));
  fx_finish_all(fx, WX_SCHED_RESULT_OK);
  gint64 deadline = wx_scheduler_next_wakeup_us(fx->s);
  fx->wall_ms -= 7 * 24 * 3600 * 1000;
  fx_focus(fx);
  NO_ACTIONS(fx);
  g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, deadline);
  fx_advance(fx, 600);
  fx_tick(fx);
  g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
  fx_free(fx);
}

static void
test_extreme_clock_values(void)
{
  const gint64 monos[] = {G_MAXINT64, G_MAXINT64 - 5 * SEC, 0, 1, G_MAXINT64 - WX_SCHED_PERIOD_US,
                          G_MAXINT64 - WX_SCHED_PERIOD_US + 1, G_MAXINT64 / 2};
  const gint64 walls[] = {G_MAXINT64, G_MININT64, 0, -1, G_MAXINT64 - 5, G_MININT64 + 5};
  for (guint i = 0; i < G_N_ELEMENTS(monos); i++) {
    for (guint j = 0; j < G_N_ELEMENTS(walls); j++) {
      Fx *fx = fx_new();
      fx->mono_us = monos[i];
      fx->wall_ms = walls[j];
      fx_set_known(fx, k_three, G_N_ELEMENTS(k_three));
      fx_online(fx, TRUE);
      fx_visible(fx, TRUE);
      g_assert_cmpuint(COUNT_LAST(fx, WX_SCHED_FETCH, NULL), ==, 3);
      /* The deadline saturates instead of overflowing. */
      if (monos[i] > G_MAXINT64 - WX_SCHED_PERIOD_US)
        g_assert_cmpint(wx_scheduler_next_wakeup_us(fx->s), ==, G_MAXINT64);
      fx_finish_all(fx, WX_SCHED_RESULT_OK);
      /* Time moves by saturating steps; nothing may overflow or trap (UBSan). */
      fx_advance(fx, 1);
      fx_focus(fx);
      fx_advance(fx, 700);
      fx_tick(fx);
      fx_finish_all(fx, WX_SCHED_RESULT_FAILED);
      fx_advance(fx, 100000);
      fx_tick(fx);
      fx_focus(fx);
      fx_finish_all(fx, WX_SCHED_RESULT_OK);
      fx->wall_ms = j % 2 ? G_MININT64 : G_MAXINT64; /* the wall clock jumps across its whole range */
      fx_tick(fx);
      fx_focus(fx);
      fx->wall_ms = j % 2 ? G_MAXINT64 : G_MININT64;
      fx_tick(fx);
      fx_visible(fx, FALSE);
      fx_visible(fx, TRUE);
      fx_finish_all(fx, WX_SCHED_RESULT_OK);
      fx_free(fx);
    }
  }
}

/* ------------------------------------------------------------------------ */
/* Preconditions and ownership of the action array                          */
/* ------------------------------------------------------------------------ */

static void
test_preconditions_null_self(void)
{
  WxSchedTime now = {0, 0};
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_set_places(NULL, now, NULL, 0);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_set_selection(NULL, now, MIA);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_set_visible(NULL, now, TRUE);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_set_online(NULL, now, TRUE);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_focus_regained(NULL, now);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_tick(NULL, now);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  wx_scheduler_request_done(NULL, now, 1, WX_SCHED_RESULT_OK);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  g_assert_null(wx_scheduler_take_actions(NULL));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  g_assert_cmpint(wx_scheduler_next_wakeup_us(NULL), ==, -1);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  g_assert_false(wx_scheduler_is_stale(NULL, MIA));
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*self != NULL*");
  g_assert_cmpuint(wx_scheduler_n_inflight(NULL), ==, 0);
  g_test_assert_expected_messages();
}

static void
test_preconditions_keys_array(void)
{
  WxSchedTime now = {0, 0};
  WxScheduler *s = wx_scheduler_new();
  EXPECT_CRITICAL("*keys != NULL || n == 0*");
  wx_scheduler_set_places(s, now, NULL, 3);
  g_test_assert_expected_messages();
  g_assert_cmpint(wx_scheduler_next_wakeup_us(s), ==, -1);
  g_assert_null(wx_scheduler_take_actions(s));
  wx_scheduler_free(s);
}

/* A negative monotonic time is a programmer error: critical, nothing changes. */
static void
test_preconditions_negative_mono(void)
{
  WxSchedTime neg = {-1, 0};
  WxScheduler *s = wx_scheduler_new();
  const char *one[] = {MIA};
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_set_places(s, neg, one, 1);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_set_selection(s, neg, MIA);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_set_visible(s, neg, TRUE);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_set_online(s, neg, TRUE);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_focus_regained(s, neg);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_tick(s, neg);
  g_test_assert_expected_messages();
  EXPECT_CRITICAL("*now.mono_us >= 0*");
  wx_scheduler_request_done(s, neg, 1, WX_SCHED_RESULT_OK);
  g_test_assert_expected_messages();
  /* The failed calls changed nothing. */
  g_assert_cmpint(wx_scheduler_next_wakeup_us(s), ==, -1);
  g_assert_null(wx_scheduler_take_actions(s));
  g_assert_cmpuint(wx_scheduler_n_inflight(s), ==, 0);
  /* The scheduler is still fully usable afterwards. */
  WxSchedTime ok = {5 * SEC, 0};
  wx_scheduler_set_places(s, ok, one, 1);
  wx_scheduler_set_online(s, ok, TRUE);
  wx_scheduler_set_visible(s, ok, TRUE);
  g_assert_cmpuint(wx_scheduler_n_inflight(s), ==, 1);
  wx_scheduler_free(s);
}

static void
test_take_actions_drains(void)
{
  Fx *fx = fx_new();
  fx_set_known(fx, k_three, 3);
  fx_online(fx, TRUE);
  wx_scheduler_set_visible(fx->s, now_of(fx), TRUE);
  fx->visible = TRUE;
  GArray *a = wx_scheduler_take_actions(fx->s);
  g_assert_nonnull(a);
  g_assert_cmpuint(a->len, ==, 3);
  g_assert_null(wx_scheduler_take_actions(fx->s)); /* drained */
  /* The array is the caller's: it survives further calls. */
  fx_advance(fx, 1);
  wx_scheduler_set_visible(fx->s, now_of(fx), FALSE);
  fx->visible = FALSE;
  GArray *b = wx_scheduler_take_actions(fx->s);
  g_assert_cmpuint(b->len, ==, 3);
  g_assert_cmpuint(g_array_index(a, WxSchedAction, 0).type, ==, WX_SCHED_FETCH);
  g_assert_cmpuint(g_array_index(b, WxSchedAction, 0).type, ==, WX_SCHED_CANCEL);
  g_assert_cmpuint(g_array_index(b, WxSchedAction, 0).id, ==, g_array_index(a, WxSchedAction, 0).id);
  g_array_unref(a);
  g_array_unref(b);
  fx->out->len = 0; /* the fixture's bookkeeping was bypassed above */
  fx->online = FALSE;
  fx->n_places = 0;
  fx_free(fx);
}

/* Actions that were never taken are freed with the scheduler (leak-checked under valgrind/ASan). */
static void
test_untaken_actions_freed_with_scheduler(void)
{
  WxScheduler *s = wx_scheduler_new();
  WxSchedTime t = {5 * SEC, 0};
  const char *keys[] = {MIA, TPA};
  wx_scheduler_set_places(s, t, keys, 2);
  wx_scheduler_set_online(s, t, TRUE);
  wx_scheduler_set_visible(s, t, TRUE);
  g_assert_cmpuint(wx_scheduler_n_inflight(s), ==, 2);
  wx_scheduler_free(s);
}

/* ------------------------------------------------------------------------ */
/* Random walks                                                             */
/* ------------------------------------------------------------------------ */

#define POOL 7

static const char *const k_pool[POOL] = {MIA, TPA, ORL, LON, TYO, "-33.8688,151.2093", "0.0000,0.0000"};

/* Applies a long random sequence of inputs and checks after every step, besides the fixture
 * invariants: (a) the stale mark of a place changes only through request_done() of that place,
 * set_places() (added/removed places) and nothing else; (b) after an event round the places it must
 * refresh (no success within WX_SCHED_FRESH_US, or failed) are all fetched once every request has
 * been completed. */
static void
test_random_walk_invariants(void)
{
  for (guint seed = 1; seed <= 40; seed++) {
    GRand *rnd = g_rand_new_with_seed(seed);
    Fx *fx = fx_new();
    gint64 last_ok_us[POOL]; /* mono time of the latest success, -1 none */
    gboolean failed[POOL];   /* the latest result was FAILED */
    gboolean tracked[POOL];
    for (guint i = 0; i < POOL; i++) {
      last_ok_us[i] = -1;
      failed[i] = FALSE;
      tracked[i] = FALSE;
    }
    gboolean expect_stale[POOL] = {FALSE};
    for (guint step = 0; step < 4000; step++) {
      fx_advance(fx, g_rand_int_range(rnd, 0, 4));
      gboolean event_round = FALSE;
      guint mark = fx->all->len;
      switch (g_rand_int_range(rnd, 0, 11)) {
      case 0: { /* new place set: a random subset in random order */
        const char *keys[POOL];
        guint n = 0;
        gboolean in_set[POOL] = {FALSE};
        for (guint k = 0; k < POOL; k++) {
          guint pick = (guint)g_rand_int_range(rnd, 0, POOL);
          if (!in_set[pick] && g_rand_int_range(rnd, 0, 100) < 70) {
            in_set[pick] = TRUE;
            keys[n++] = k_pool[pick];
          }
        }
        fx->n_places = n;
        wx_scheduler_set_places(fx->s, now_of(fx), keys, n);
        collect(fx);
        for (guint k = 0; k < POOL; k++) {
          if (!in_set[k]) {
            tracked[k] = FALSE;
            failed[k] = FALSE;
            expect_stale[k] = FALSE;
            last_ok_us[k] = -1;
          } else if (!tracked[k]) {
            tracked[k] = TRUE;
            failed[k] = FALSE;
            expect_stale[k] = FALSE;
            last_ok_us[k] = -1;
          }
        }
        break;
      }
      case 1:
        wx_scheduler_set_selection(fx->s, now_of(fx),
                                   g_rand_boolean(rnd) ? k_pool[g_rand_int_range(rnd, 0, POOL)] : NULL);
        collect(fx);
        break;
      case 2: {
        gboolean v = g_rand_boolean(rnd);
        event_round = v && !fx->visible && fx->online;
        fx_visible(fx, v);
        break;
      }
      case 3: {
        gboolean v = g_rand_boolean(rnd);
        event_round = v && fx->visible && !fx->online;
        fx_online(fx, v);
        break;
      }
      case 4:
        event_round = fx->visible && fx->online;
        fx_focus(fx);
        break;
      case 5:
        fx_advance(fx, g_rand_int_range(rnd, 0, 700));
        fx_tick(fx);
        break;
      default: { /* complete a random outstanding request */
        if (fx->out->len == 0)
          break;
        Outstanding o = g_array_index(fx->out, Outstanding, g_rand_int_range(rnd, 0, fx->out->len));
        WxSchedResult r = o.cancelled ? WX_SCHED_RESULT_CANCELLED
                          : g_rand_int_range(rnd, 0, 10) < 7 ? WX_SCHED_RESULT_OK
                                                              : WX_SCHED_RESULT_FAILED;
        if (o.cancelled && g_rand_int_range(rnd, 0, 4) == 0)
          r = WX_SCHED_RESULT_OK; /* a cancelled request that finished anyway is reported as it ended */
        guint idx = POOL;
        for (guint k = 0; k < POOL; k++)
          if (strcmp(k_pool[k], o.key) == 0)
            idx = k;
        g_assert_cmpuint(idx, <, POOL);
        fx_done(fx, o.id, r);
        if (tracked[idx]) {
          if (r == WX_SCHED_RESULT_OK) {
            failed[idx] = FALSE;
            expect_stale[idx] = FALSE;
            last_ok_us[idx] = fx->mono_us;
          } else if (r == WX_SCHED_RESULT_FAILED) {
            failed[idx] = TRUE;
            expect_stale[idx] = TRUE;
            last_ok_us[idx] = -1;
          }
        }
        break;
      }
      }
      /* (a) stale marks follow the model exactly. */
      for (guint k = 0; k < POOL; k++)
        g_assert_cmpint(wx_scheduler_is_stale(fx->s, k_pool[k]), ==, tracked[k] && expect_stale[k]);

      /* (b) liveness of an event round: complete everything with OK at this very instant and
       * check that every place that had to be refreshed was fetched (or was already in flight
       * without being cancelled, which counts as merged). */
      if (event_round && g_rand_int_range(rnd, 0, 3) == 0) {
        gboolean wanted[POOL];
        for (guint k = 0; k < POOL; k++) {
          wanted[k] = tracked[k] &&
                      (failed[k] || last_ok_us[k] < 0 ||
                       fx->mono_us - last_ok_us[k] >= WX_SCHED_FRESH_US);
        }
        /* Requests outstanding before this round whose completion would deliver data. */
        gboolean merged[POOL] = {FALSE};
        /* (in-flight requests that were not started by this call are the ones with ids below the
         * first action of the call) */
        guint64 first_new = G_MAXUINT64;
        for (guint i = mark; i < fx->all->len; i++) {
          const WxSchedAction *a = &g_array_index(fx->all, WxSchedAction, i);
          if (a->type == WX_SCHED_FETCH && a->id < first_new)
            first_new = a->id;
        }
        for (guint j = 0; j < fx->out->len; j++) {
          const Outstanding *o = &g_array_index(fx->out, Outstanding, j);
          if (!o->cancelled && o->id < first_new)
            for (guint k = 0; k < POOL; k++)
              if (strcmp(k_pool[k], o->key) == 0)
                merged[k] = TRUE;
        }
        /* Everything is reported OK without time passing; the waiting places start as slots free. */
        for (guint guard = 0; fx->out->len > 0; guard++) {
          g_assert_cmpuint(guard, <, 1000);
          Outstanding o = g_array_index(fx->out, Outstanding, 0);
          WxSchedResult r = o.cancelled ? WX_SCHED_RESULT_CANCELLED : WX_SCHED_RESULT_OK;
          guint idx = POOL;
          for (guint k = 0; k < POOL; k++)
            if (strcmp(k_pool[k], o.key) == 0)
              idx = k;
          fx_done(fx, o.id, r);
          if (r == WX_SCHED_RESULT_OK && tracked[idx]) {
            failed[idx] = FALSE;
            expect_stale[idx] = FALSE;
            last_ok_us[idx] = fx->mono_us;
          }
        }
        for (guint k = 0; k < POOL; k++) {
          if (!wanted[k])
            continue;
          gboolean fetched_in_round = FALSE;
          for (guint i = mark; i < fx->all->len; i++) {
            const WxSchedAction *a = &g_array_index(fx->all, WxSchedAction, i);
            if (a->type == WX_SCHED_FETCH && strcmp(a->key, k_pool[k]) == 0)
              fetched_in_round = TRUE;
          }
          g_assert_true(fetched_in_round || merged[k]);
        }
        /* After completing OK everything tracked and wanted is fresh and not stale. */
        for (guint k = 0; k < POOL; k++)
          if (wanted[k] && fx->visible && fx->online)
            g_assert_false(wx_scheduler_is_stale(fx->s, k_pool[k]));
      }
    }
    fx_finish_all(fx, WX_SCHED_RESULT_OK);
    fx_free(fx);
    g_rand_free(rnd);
  }
}

/* The scheduler against a trivial model of "who is outstanding": whatever the owner reports,
 * the in-flight count the scheduler gives equals the owner's own and no request is ever lost:
 * with every request completed OK, a quiescent active scheduler wants nothing more. */
static void
test_random_walk_quiescence(void)
{
  for (guint seed = 100; seed < 140; seed++) {
    GRand *rnd = g_rand_new_with_seed(seed);
    Fx *fx = fx_new();
    fx->n_places = 0;
    for (guint step = 0; step < 3000; step++) {
      fx_advance(fx, g_rand_int_range(rnd, 0, 250));
      switch (g_rand_int_range(rnd, 0, 8)) {
      case 0: fx_visible(fx, g_rand_boolean(rnd)); break;
      case 1: fx_online(fx, g_rand_boolean(rnd)); break;
      case 2: fx_focus(fx); break;
      case 3: fx_tick(fx); break;
      case 4: {
        const char *keys[POOL];
        guint n = 0;
        gboolean in_set[POOL] = {FALSE};
        for (guint k = 0; k < POOL; k++) {
          guint pick = (guint)g_rand_int_range(rnd, 0, POOL);
          if (!in_set[pick]) {
            in_set[pick] = TRUE;
            keys[n++] = k_pool[pick];
          }
        }
        fx->n_places = n;
        fx_places(fx, keys, n);
        break;
      }
      default:
        if (fx->out->len > 0) {
          Outstanding o = g_array_index(fx->out, Outstanding, g_rand_int_range(rnd, 0, fx->out->len));
          fx_done(fx, o.id, o.cancelled ? WX_SCHED_RESULT_CANCELLED : WX_SCHED_RESULT_OK);
        }
      }
    }
    /* Quiesce: complete everything, then an active scheduler must have nothing waiting. */
    fx_finish_all(fx, WX_SCHED_RESULT_OK);
    guint mark = fx->all->len;
    fx_finish_all(fx, WX_SCHED_RESULT_OK);
    g_assert_cmpuint(fx->all->len, ==, mark);
    g_assert_cmpuint(wx_scheduler_n_inflight(fx->s), ==, 0);
    fx_free(fx);
    g_rand_free(rnd);
  }
}

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);

  g_test_add_func("/sched/idle-has-no-actions-no-timer", test_idle_has_no_actions_no_timer);
  g_test_add_func("/sched/start-round-once-per-place", test_start_round_once_per_place);
  g_test_add_func("/sched/inflight-cap", test_inflight_cap);
  g_test_add_func("/sched/start-order-selected-first", test_start_order_selected_first);
  g_test_add_func("/sched/selection/fetches-nothing", test_selection_fetches_nothing);
  g_test_add_func("/sched/selection/all-slots-busy", test_selection_all_slots_busy);
  g_test_add_func("/sched/selection/invalid-or-untracked", test_selection_invalid_or_untracked);
  g_test_add_func("/sched/periodic/deadline-and-early-tick", test_periodic_deadline_and_early_tick);
  g_test_add_func("/sched/periodic/skips-young-successes", test_periodic_skips_young_successes);
  g_test_add_func("/sched/periodic/freshness-540s-is-stale", test_periodic_freshness_540s_is_stale);
  g_test_add_func("/sched/periodic/freshness-539s-is-fresh", test_periodic_freshness_539s_is_fresh);
  g_test_add_func("/sched/periodic/late-and-no-catch-up", test_periodic_late_and_no_catch_up);
  g_test_add_func("/sched/periodic/merges-with-inflight", test_periodic_merges_with_inflight);
  g_test_add_func("/sched/event/freshness-119s-is-fresh", test_event_freshness_119s_is_fresh);
  g_test_add_func("/sched/event/freshness-120s-is-stale", test_event_freshness_120s_is_stale);
  g_test_add_func("/sched/event/and-periodic-windows-differ", test_event_and_periodic_windows_differ);
  g_test_add_func("/sched/event/show-hide-cycle", test_event_show_hide_cycle);
  g_test_add_func("/sched/event/network-cycle", test_event_network_cycle);
  g_test_add_func("/sched/focus/regained-runs-one-round", test_focus_regained_runs_one_round);
  g_test_add_func("/sched/focus/while-offline", test_focus_while_offline);
  g_test_add_func("/sched/focus/while-hidden", test_focus_while_hidden);
  g_test_add_func("/sched/focus/while-hidden-leaves-no-waiting-state",
                  test_focus_while_hidden_leaves_no_waiting_state);
  g_test_add_func("/sched/focus/while-offline-leaves-no-waiting-state",
                  test_focus_while_offline_leaves_no_waiting_state);
  g_test_add_func("/sched/failure/marks-stale", test_failure_marks_stale);
  g_test_add_func("/sched/stale-query-edge-keys", test_stale_query_edge_keys);
  g_test_add_func("/sched/failure/retried-by-event-round", test_failure_retried_by_event_round);
  g_test_add_func("/sched/failure/stale-mark-survives-every-other-input",
                  test_stale_mark_survives_every_other_input);
  g_test_add_func("/sched/failure/retried-by-periodic-round", test_failure_retried_by_periodic_round);
  g_test_add_func("/sched/failure/forgets-earlier-success", test_failure_forgets_earlier_success);
  g_test_add_func("/sched/cancelled-newest-request-keeps-earlier-success", test_cancelled_newest_request_keeps_earlier_success);
  g_test_add_func("/sched/cancelled-newest-request-event-round-wants-again", test_cancelled_newest_request_event_round_wants_again);
  g_test_add_func("/sched/ok-after-cancel-counts-as-success", test_ok_after_cancel_counts_as_success);
  g_test_add_func("/sched/cancelled-never-fresh", test_cancelled_never_fresh);
  g_test_add_func("/sched/hide-cancels-and-drops-waiting", test_hide_cancels_and_drops_waiting);
  g_test_add_func("/sched/show-before-cancelled-requests-reported", test_show_before_cancelled_requests_reported);
  g_test_add_func("/sched/offline-cancels-and-back-online", test_offline_cancels_and_back_online);
  g_test_add_func("/sched/hide-show-hide-before-cancels-reported",
                  test_hide_show_hide_before_cancels_reported);
  g_test_add_func("/sched/dropped-waiting-wanted-again", test_dropped_waiting_wanted_again);
  g_test_add_func("/sched/timer/when-hidden-or-offline", test_no_timer_when_hidden_or_offline);
  g_test_add_func("/sched/timer/without-places", test_no_timer_without_places);
  g_test_add_func("/sched/tick-while-hidden-does-nothing", test_tick_while_hidden_does_nothing);
  g_test_add_func("/sched/place/added-fetched-at-once", test_place_added_fetched_at_once);
  g_test_add_func("/sched/place/reorder-keeps-state", test_place_reorder_keeps_state);
  g_test_add_func("/sched/place/removed-cancels-request", test_place_removed_cancels_request);
  g_test_add_func("/sched/place/removed-while-waiting", test_place_removed_while_waiting);
  g_test_add_func("/sched/place/removed-has-no-stale-mark", test_place_removed_has_no_stale_mark);
  g_test_add_func("/sched/place/readded-after-cancel-reported", test_place_readded_after_cancel_reported);
  g_test_add_func("/sched/place/revived-while-request-winds-down", test_place_revived_while_request_winds_down);
  g_test_add_func("/sched/place/clear-all", test_place_clear_all);
  g_test_add_func("/sched/places-added-while-inactive-wait", test_places_added_while_inactive_wait);
  g_test_add_func("/sched/remove-selected-place", test_remove_selected_place);
  g_test_add_func("/sched/key/validation", test_key_validation);
  g_test_add_func("/sched/key/guard-pages", test_key_guard_pages);
  g_test_add_func("/sched/request-done/unknown-ids", test_request_done_unknown_ids);
  g_test_add_func("/sched/request-done/unknown-result", test_request_done_unknown_result);
  g_test_add_func("/sched/request-done/twice", test_request_done_twice);
  g_test_add_func("/sched/clock/forward-jump-makes-deadline-due", test_clock_forward_jump_makes_deadline_due);
  g_test_add_func("/sched/clock/forward-jump-refetches-old-data", test_clock_forward_jump_refetches_old_data);
  g_test_add_func("/sched/clock/jump-tolerance-boundary", test_clock_jump_tolerance_boundary);
  g_test_add_func("/sched/clock/jump-noticed-by-every-input", test_clock_jump_noticed_by_every_input);
  g_test_add_func("/sched/clock/jump-without-deadline", test_clock_jump_without_deadline);
  g_test_add_func("/sched/clock/backward-jump-changes-nothing", test_clock_backward_jump_changes_nothing);
  g_test_add_func("/sched/extreme-clock-values", test_extreme_clock_values);
  g_test_add_func("/sched/preconditions/null-self", test_preconditions_null_self);
  g_test_add_func("/sched/preconditions/keys-array", test_preconditions_keys_array);
  g_test_add_func("/sched/preconditions/negative-mono", test_preconditions_negative_mono);
  g_test_add_func("/sched/take-actions-drains", test_take_actions_drains);
  g_test_add_func("/sched/untaken-actions-freed-with-scheduler", test_untaken_actions_freed_with_scheduler);
  g_test_add_func("/sched/random-walk", test_random_walk_invariants);
  g_test_add_func("/sched/random-quiescence", test_random_walk_quiescence);

  return g_test_run();
}
