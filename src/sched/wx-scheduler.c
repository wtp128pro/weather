/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-scheduler.c - see wx-scheduler.h for the rules. Pure logic. */
#include "wx-scheduler.h"

#include <string.h>

/* One tracked place (one forecast job). */
typedef struct {
  char key[WX_SCHED_KEY_BYTES]; /* NUL-padded, so memcmp() over the array compares keys */
  /* Removed from the tracked set but its cancelled request has not been
   * reported finished yet: kept only to hold the slot. */
  gboolean removed;
  gboolean wanted; /* waiting for a slot                              */
  gboolean failed; /* the latest request failed                       */
  gboolean fresh;  /* the latest request succeeded (ok_us is valid)   */
  gint64 ok_us;    /* monotonic time of that success                  */

  guint64 req_id; /* 0: nothing in flight */
  gboolean req_cancelling;
} Entry;

struct _WxScheduler {
  GPtrArray *entries; /* Entry*, display order, removed ones last */
  gboolean has_sel;
  char sel_key[WX_SCHED_KEY_BYTES];
  gboolean visible;
  gboolean online;
  guint n_inflight;
  guint64 next_id;
  gint64 deadline_us; /* -1: none */
  gboolean has_last;
  WxSchedTime last;
  GArray *actions; /* WxSchedAction, NULL when empty */
};

/* ------------------------------------------------------------------------ */
/* Small helpers                                                            */
/* ------------------------------------------------------------------------ */

/**
 * sat_add:
 * @a: first operand.
 * @b: second operand.
 *
 * Preconditions:
 *  - @b >= 0 (every call site adds the period).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none (no pointers).
 *
 * Returns: a + b, clamped to G_MAXINT64 instead of overflowing.
 */
static gint64
sat_add(gint64 a, gint64 b)
{
  return a > G_MAXINT64 - b ? G_MAXINT64 : a + b;
}

/**
 * sat_sub:
 * @a: minuend.
 * @b: subtrahend.
 *
 * Preconditions:
 *  - none (any values).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none (no pointers).
 *
 * Returns: a - b, clamped to the gint64 range instead of overflowing.
 */
static gint64
sat_sub(gint64 a, gint64 b)
{
  if (b < 0 && a > G_MAXINT64 + b)
    return G_MAXINT64;
  if (b > 0 && a < G_MININT64 + b)
    return G_MININT64;
  return a - b;
}

/**
 * normalise:
 * @key: (nullable): a caller's place key.
 * @out: (out): receives the NUL-padded copy.
 *
 * Preconditions:
 *  - @key is NULL, NUL-terminated, or has WX_SCHED_KEY_BYTES readable bytes
 *    (at most that many are read); @out has room for WX_SCHED_KEY_BYTES.
 * Postconditions:
 *  - on TRUE @out holds the key padded with NULs; on FALSE @out is untouched.
 * Thread affinity: any thread (pure).
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: TRUE iff @key consists of 1 to WX_SCHED_KEY_BYTES - 1 characters of
 *   [0-9.,-].
 */
static gboolean
normalise(const char *key, char out[WX_SCHED_KEY_BYTES])
{
  if (key == NULL)
    return FALSE;
  const char *end = memchr(key, '\0', WX_SCHED_KEY_BYTES);
  if (end == NULL || end == key)
    return FALSE;
  for (const char *p = key; p < end; p++)
    if (!g_ascii_isdigit(*p) && *p != '.' && *p != ',' && *p != '-')
      return FALSE;
  memset(out, 0, WX_SCHED_KEY_BYTES);
  memcpy(out, key, (gsize)(end - key));
  return TRUE;
}

/**
 * is_active:
 * @self: the scheduler.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 *
 * Returns: TRUE iff the window is visible and the network is available.
 */
static gboolean
is_active(const WxScheduler *self)
{
  return self->visible && self->online;
}

/**
 * find_entry:
 * @self: the scheduler.
 * @key: (not nullable): a normalised key.
 * @include_removed: whether removed entries (waiting for their cancelled
 *   request) count.
 *
 * Preconditions:
 *  - @self is a scheduler; @key has WX_SCHED_KEY_BYTES readable bytes (from
 *    normalise() or an entry).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: @key is borrowed; the entry is owned by the scheduler.
 *
 * Returns: (transfer none) (nullable): the entry, or NULL.
 */
static Entry *
find_entry(const WxScheduler *self, const char *key, gboolean include_removed)
{
  for (guint i = 0; i < self->entries->len; i++) {
    Entry *e = g_ptr_array_index(self->entries, i);
    if ((include_removed || !e->removed) && memcmp(e->key, key, WX_SCHED_KEY_BYTES) == 0)
      return e;
  }
  return NULL;
}

/**
 * is_selected:
 * @self: the scheduler.
 * @e: an entry.
 *
 * Preconditions:
 *  - @self is a scheduler; @e one of its entries.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 *
 * Returns: TRUE iff @e is tracked and is the selected place.
 */
static gboolean
is_selected(const WxScheduler *self, const Entry *e)
{
  return self->has_sel && !e->removed && memcmp(e->key, self->sel_key, WX_SCHED_KEY_BYTES) == 0;
}

/**
 * want:
 * @e: an entry.
 *
 * Marks the place as waiting for a slot unless its request is already in
 * flight (merged).
 *
 * Preconditions:
 *  - @e is a tracked entry of a scheduler.
 * Postconditions:
 *  - e->wanted is set unless a request that is not being cancelled is
 *    outstanding for @e.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
want(Entry *e)
{
  if (e->req_id == 0 || e->req_cancelling)
    e->wanted = TRUE;
}

/**
 * emit:
 * @self: the scheduler.
 * @action: (not nullable): the action to queue (copied).
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - the action is the last pending one.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: @action is borrowed and copied.
 */
static void
emit(WxScheduler *self, const WxSchedAction *action)
{
  if (self->actions == NULL)
    self->actions = g_array_new(FALSE, FALSE, sizeof(WxSchedAction));
  g_array_append_val(self->actions, *action);
}

/**
 * cancel_request:
 * @self: the scheduler.
 * @e: an entry.
 *
 * Queues a CANCEL for the entry's request, once. The request keeps its slot
 * until request_done() reports it.
 *
 * Preconditions:
 *  - @self is a scheduler; @e one of its entries.
 * Postconditions:
 *  - if a request is outstanding and not yet being cancelled: it is marked
 *    cancelling and a CANCEL is queued; otherwise nothing happens.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
cancel_request(WxScheduler *self, Entry *e)
{
  if (e->req_id == 0 || e->req_cancelling)
    return;
  e->req_cancelling = TRUE;
  WxSchedAction a;
  memset(&a, 0, sizeof a);
  a.type = WX_SCHED_CANCEL;
  a.id = e->req_id;
  emit(self, &a);
}

/* ------------------------------------------------------------------------ */
/* Starting requests                                                        */
/* ------------------------------------------------------------------------ */

/**
 * start_request:
 * @self: the scheduler.
 * @e: a tracked entry that is waiting and has no request outstanding.
 *
 * Issues the FETCH of the entry with a new id.
 *
 * Preconditions:
 *  - @self is a scheduler with a free slot; @e.wanted is set and e->req_id is
 *    0.
 * Postconditions:
 *  - a FETCH is queued; the entry holds the new request; the in-flight count
 *    grew by one; e->wanted is cleared.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
start_request(WxScheduler *self, Entry *e)
{
  WxSchedAction a;
  memset(&a, 0, sizeof a);
  a.type = WX_SCHED_FETCH;
  a.id = self->next_id++;
  memcpy(a.key, e->key, sizeof a.key);

  e->req_id = a.id;
  e->req_cancelling = FALSE;
  e->wanted = FALSE;
  self->n_inflight++;
  emit(self, &a);
}

/**
 * start_next:
 * @self: the scheduler.
 *
 * Starts the next waiting place: the selected one first, then list order.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - at most one request was started.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 *
 * Returns: TRUE iff a request was started.
 */
static gboolean
start_next(WxScheduler *self)
{
  for (guint pass = 0; pass < 2; pass++) {
    for (guint i = 0; i < self->entries->len; i++) {
      Entry *e = g_ptr_array_index(self->entries, i);
      if (e->removed || e->req_id != 0 || !e->wanted || is_selected(self, e) != (pass == 0))
        continue;
      start_request(self, e);
      return TRUE;
    }
  }
  return FALSE;
}

/**
 * pump:
 * @self: the scheduler.
 *
 * While active, starts waiting places until the in-flight cap is reached or
 * nothing waits.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - not active: nothing changes; otherwise n_inflight <=
 *    WX_SCHED_MAX_INFLIGHT or no entry is waiting for a free slot.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
pump(WxScheduler *self)
{
  if (!is_active(self))
    return;
  while (self->n_inflight < WX_SCHED_MAX_INFLIGHT && start_next(self))
    ;
}

/* ------------------------------------------------------------------------ */
/* Rounds, time, deadline                                                   */
/* ------------------------------------------------------------------------ */

/**
 * add_round:
 * @self: the scheduler.
 * @now: the current time.
 * @window_us: places whose latest success is younger than this are skipped.
 *
 * Marks every tracked place that is not fresh as waiting. A failed place is
 * never fresh (a failure forgets the freshness).
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - the waiting set grew by the places the round includes; nothing started.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
add_round(WxScheduler *self, WxSchedTime now, gint64 window_us)
{
  for (guint i = 0; i < self->entries->len; i++) {
    Entry *e = g_ptr_array_index(self->entries, i);
    if (e->removed)
      continue;
    if (!e->fresh || sat_sub(now.mono_us, e->ok_us) >= window_us)
      want(e);
  }
}

/**
 * drop_all:
 * @self: the scheduler.
 *
 * Forgets every waiting place and cancels every request in flight (hiding the
 * window or losing the network).
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - nothing waits; every outstanding request is being cancelled (a CANCEL was
 *    queued for each not yet cancelling one).
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
drop_all(WxScheduler *self)
{
  for (guint i = 0; i < self->entries->len; i++) {
    Entry *e = g_ptr_array_index(self->entries, i);
    e->wanted = FALSE;
    cancel_request(self, e);
  }
}

/**
 * has_places:
 * @self: the scheduler.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 *
 * Returns: TRUE iff at least one tracked (not removed) place exists. Removed
 *   entries are kept after the tracked ones, so checking the first suffices.
 */
static gboolean
has_places(const WxScheduler *self)
{
  return self->entries->len > 0 && !((const Entry *)g_ptr_array_index(self->entries, 0))->removed;
}

/**
 * rearm:
 * @self: the scheduler.
 * @now: the current time.
 *
 * Re-evaluates the deadline: none unless active with at least one place; an
 * armed deadline is kept, a missing one starts a full period ahead.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - deadline_us is -1, or a monotonic time.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
rearm(WxScheduler *self, WxSchedTime now)
{
  if (!is_active(self) || !has_places(self))
    self->deadline_us = -1;
  else if (self->deadline_us < 0)
    self->deadline_us = sat_add(now.mono_us, WX_SCHED_PERIOD_US);
}

/**
 * advance:
 * @self: the scheduler.
 * @now: the current time.
 *
 * Clock-jump detection, run first by every call that takes a time: if the
 * wall clock advanced more than WX_SCHED_JUMP_TOLERANCE_US more than the
 * monotonic clock since the previous call, a pending deadline becomes due.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - the time of this call is remembered; deadline_us may have become @now's
 *    monotonic time.
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
advance(WxScheduler *self, WxSchedTime now)
{
  if (self->has_last && self->deadline_us >= 0) {
    gint64 drift_ms = sat_sub(sat_sub(now.wall_ms, self->last.wall_ms),
                              sat_sub(now.mono_us, self->last.mono_us) / 1000);
    if (drift_ms > WX_SCHED_JUMP_TOLERANCE_US / 1000)
      self->deadline_us = now.mono_us;
  }
  self->last = now;
  self->has_last = TRUE;
}

/**
 * finish:
 * @self: the scheduler.
 * @now: the current time.
 *
 * The common end of every input: starts what can start and re-evaluates the
 * deadline.
 *
 * Preconditions:
 *  - @self is a scheduler.
 * Postconditions:
 *  - see pump() and rearm().
 * Thread affinity: the thread that owns the scheduler.
 * Ownership: none.
 */
static void
finish(WxScheduler *self, WxSchedTime now)
{
  pump(self);
  rearm(self, now);
}

/* ------------------------------------------------------------------------ */
/* Public API                                                               */
/* ------------------------------------------------------------------------ */

/* Documented in wx-scheduler.h. */
WxScheduler *
wx_scheduler_new(void)
{
  WxScheduler *self = g_new0(WxScheduler, 1);
  self->entries = g_ptr_array_new_with_free_func(g_free);
  self->next_id = 1;
  self->deadline_us = -1;
  return self;
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_free(WxScheduler *self)
{
  if (self == NULL)
    return;
  g_ptr_array_unref(self->entries);
  if (self->actions != NULL)
    g_array_unref(self->actions);
  g_free(self);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_set_places(WxScheduler *self, WxSchedTime now, const char *const *keys, gsize n)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(keys != NULL || n == 0);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);

  /* Entries move from the old array to @next (steal), so each is owned by
   * exactly one array at any time. */
  GPtrArray *next = g_ptr_array_new_with_free_func(g_free);
  for (gsize i = 0; i < n; i++) {
    char key[WX_SCHED_KEY_BYTES];
    if (!normalise(keys[i], key))
      continue;
    gboolean dup = FALSE;
    for (guint j = 0; j < next->len && !dup; j++)
      dup = memcmp(((const Entry *)g_ptr_array_index(next, j))->key, key, WX_SCHED_KEY_BYTES) == 0;
    if (dup)
      continue;

    Entry *e = NULL;
    for (guint j = 0; j < self->entries->len && e == NULL; j++) {
      Entry *c = g_ptr_array_index(self->entries, j);
      if (memcmp(c->key, key, WX_SCHED_KEY_BYTES) == 0)
        e = g_ptr_array_steal_index(self->entries, j);
    }
    gboolean fresh = e == NULL || e->removed; /* new, or revived while its request winds down */
    if (e == NULL) {
      e = g_new0(Entry, 1);
      memcpy(e->key, key, sizeof e->key);
    }
    e->removed = FALSE;
    if (fresh) {
      e->wanted = is_active(self);
      e->failed = FALSE;
      e->fresh = FALSE;
    }
    g_ptr_array_add(next, e);
  }

  /* What is left in the old array left the tracked set. */
  while (self->entries->len > 0) {
    Entry *e = g_ptr_array_steal_index(self->entries, self->entries->len - 1);
    e->wanted = FALSE;
    cancel_request(self, e);
    if (e->req_id != 0) {
      e->removed = TRUE; /* keeps its slot until the request is reported done */
      g_ptr_array_add(next, e);
    } else {
      g_free(e);
    }
  }
  g_ptr_array_unref(self->entries);
  self->entries = next;

  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_set_selection(WxScheduler *self, WxSchedTime now, const char *key)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);

  char norm[WX_SCHED_KEY_BYTES];
  self->has_sel = normalise(key, norm);
  if (self->has_sel)
    memcpy(self->sel_key, norm, sizeof self->sel_key);
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_set_visible(WxScheduler *self, WxSchedTime now, gboolean visible)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);
  visible = !!visible;
  if (visible != self->visible) {
    self->visible = visible;
    if (!visible)
      drop_all(self);
    else if (is_active(self))
      add_round(self, now, WX_SCHED_FRESH_US);
  }
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_set_online(WxScheduler *self, WxSchedTime now, gboolean online)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);
  online = !!online;
  if (online != self->online) {
    self->online = online;
    if (!online)
      drop_all(self);
    else if (is_active(self))
      add_round(self, now, WX_SCHED_FRESH_US);
  }
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_focus_regained(WxScheduler *self, WxSchedTime now)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);
  if (is_active(self))
    add_round(self, now, WX_SCHED_FRESH_US);
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_tick(WxScheduler *self, WxSchedTime now)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);
  if (self->deadline_us >= 0 && now.mono_us >= self->deadline_us) {
    gint64 next = sat_add(self->deadline_us, WX_SCHED_PERIOD_US);
    if (next <= now.mono_us)
      next = sat_add(now.mono_us, WX_SCHED_PERIOD_US); /* late: no catch-up rounds */
    /* An armed deadline implies "active with a place" (rearm() clears it as
     * soon as either is lost), so the round is always wanted here. */
    add_round(self, now, WX_SCHED_PERIODIC_FRESH_US);
    self->deadline_us = next;
  }
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
void
wx_scheduler_request_done(WxScheduler *self, WxSchedTime now, guint64 id, WxSchedResult result)
{
  g_return_if_fail(self != NULL);
  g_return_if_fail(now.mono_us >= 0);
  advance(self, now);

  Entry *e = NULL;
  if (id != 0) {
    for (guint i = 0; i < self->entries->len && e == NULL; i++) {
      Entry *c = g_ptr_array_index(self->entries, i);
      if (c->req_id == id)
        e = c;
    }
  }
  if (e == NULL) {
    finish(self, now);
    return;
  }

  if (result == WX_SCHED_RESULT_OK) {
    e->failed = FALSE;
    e->fresh = TRUE;
    e->ok_us = now.mono_us;
  } else if (result == WX_SCHED_RESULT_FAILED) {
    e->failed = TRUE;
    e->fresh = FALSE;
  }

  e->req_id = 0;
  e->req_cancelling = FALSE;
  self->n_inflight--;
  if (e->removed)
    g_ptr_array_remove(self->entries, e);
  finish(self, now);
}

/* Documented in wx-scheduler.h. */
GArray *
wx_scheduler_take_actions(WxScheduler *self)
{
  g_return_val_if_fail(self != NULL, NULL);
  GArray *out = self->actions;
  self->actions = NULL;
  return out;
}

/* Documented in wx-scheduler.h. */
gint64
wx_scheduler_next_wakeup_us(WxScheduler *self)
{
  g_return_val_if_fail(self != NULL, -1);
  return self->deadline_us;
}

/* Documented in wx-scheduler.h. */
gboolean
wx_scheduler_is_stale(WxScheduler *self, const char *key)
{
  g_return_val_if_fail(self != NULL, FALSE);
  char norm[WX_SCHED_KEY_BYTES];
  if (!normalise(key, norm))
    return FALSE;
  const Entry *e = find_entry(self, norm, FALSE);
  return e != NULL && e->failed;
}

/* Documented in wx-scheduler.h. */
guint
wx_scheduler_n_inflight(WxScheduler *self)
{
  g_return_val_if_fail(self != NULL, 0);
  return self->n_inflight;
}
