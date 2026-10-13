/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-scheduler.h - WxScheduler: pure refresh-policy logic of the weather app.
 *
 * The scheduler decides WHEN a forecast is fetched; it never fetches, never
 * touches GLib's main loop, never reads a clock and has no timers. The owner
 * feeds it inputs (every call carries the current time as a WxSchedTime),
 * then drains the resulting actions with wx_scheduler_take_actions() and arms
 * at most one timer for wx_scheduler_next_wakeup_us(). Because time is an
 * argument, every rule is deterministic and unit-tested (test-scheduler.c).
 * Threading: not thread-safe; use it from one thread (the main thread).
 * Everything is main-loop-free pure logic over memory: no I/O of any kind,
 * and no dependency on GTK.
 *
 * What is wanted: one "job" per tracked place, the forecast of that place.
 * Places are identified by their key (wx_place_key(), "<lat>,<lon>").
 *
 * Rules
 * -----
 *  - A request is issued only while the window is visible AND the network is
 *    available ("active"). While not active the scheduler emits no FETCH
 *    action and has no wakeup.
 *  - Refresh rounds. An "event round" (every place) happens exactly once for
 *    each of: the window becoming visible (also the app start), the window
 *    regaining focus while visible and online, and the network coming back
 *    while visible. A place that is added to the tracked set while active is
 *    fetched at once (without a round for the others). A "periodic round"
 *    (every place) happens every WX_SCHED_PERIOD_US while the window is
 *    visible, the network is available and at least one place is tracked.
 *  - Freshness. The scheduler remembers, per place, the time of the latest
 *    SUCCESS: the time of the wx_scheduler_request_done() call that reported
 *    WX_SCHED_RESULT_OK. A place whose latest success is less than
 *    WX_SCHED_FRESH_US old is skipped by an event round, one whose latest
 *    success is less than WX_SCHED_PERIODIC_FRESH_US old is skipped by a
 *    periodic round; every other place that a round includes is wanted
 *    (unless its request is already in flight, see "In flight"). Only the
 *    outcome of a request changes this memory: a FAILED completion forgets
 *    the success (a place that failed is wanted by the next round, however
 *    young its earlier success was), whereas a CANCELLED completion (window
 *    hidden, network lost, place removed) leaves it untouched, so an earlier
 *    success that lies inside the window still counts and the cancelled
 *    request itself counts for nothing. A place that never succeeded, and a
 *    place newly added (or re-added), has no success and is wanted by every
 *    round. Waiting for a slot is not remembered across a hide or a loss of
 *    the network: the places that were waiting are wanted again by the next
 *    event round if their latest success is outside the window, and a place
 *    whose cancelled request finished OK in the meantime is fresh and skipped.
 *  - Timer: wx_scheduler_next_wakeup_us() is the monotonic deadline of the
 *    next periodic round while "active AND at least one place is tracked";
 *    otherwise -1 (no timer must exist). Hiding the window, losing the network
 *    or removing the last place clears the deadline; becoming active again
 *    arms a new one a full period ahead. Event rounds do not move an armed
 *    deadline.
 *  - In flight: at most one request per place, at most WX_SCHED_MAX_INFLIGHT
 *    in total. A place that is already in flight (or already waiting) is
 *    merged: asking again does not start a second request. A cancelled
 *    request keeps its slot until its completion is reported with
 *    wx_scheduler_request_done(), so a replacement request of the same place
 *    never overlaps it. Waiting places start in this order: the selected
 *    place first, then the others in list order.
 *  - Failure: a FAILED completion marks the place stale
 *    (wx_scheduler_is_stale()) until a request for it succeeds; the owner
 *    keeps showing its cached data. Nothing retries a failure by itself: the
 *    next round does (every event round and, while its conditions hold, every
 *    periodic round). CANCELLED completions never mark stale.
 *  - Stale marks. The mark of a place can change only in
 *    wx_scheduler_request_done() (the place of that request) and
 *    wx_scheduler_set_places() (an added place starts without a mark, a
 *    removed one has none); no other call changes a mark.
 *  - Cancellation: hiding the window or losing the network cancels every
 *    request in flight and drops everything waiting; removing a place cancels
 *    its request.
 *  - Clock jumps: deadlines use the monotonic clock only. If the wall clock
 *    advanced more than WX_SCHED_JUMP_TOLERANCE_US more than the monotonic
 *    clock since the previous call (suspend/resume, clock set forward), a
 *    pending deadline becomes due at once (one round, never a burst). A wall
 *    clock that moves backwards changes nothing. A periodic round that fires
 *    late is followed by the next one a full period later, never by catch-up
 *    rounds. All time arithmetic saturates, so extreme clock values are safe.
 */
#ifndef WX_SCHEDULER_H
#define WX_SCHEDULER_H

#include <glib.h>

G_BEGIN_DECLS

/** Period of the periodic round, microseconds. */
#define WX_SCHED_PERIOD_US (600 * G_USEC_PER_SEC)
/**
 * An event round skips a place whose latest SUCCESS (the time given to
 * wx_scheduler_request_done() with WX_SCHED_RESULT_OK) is less than this ago.
 */
#define WX_SCHED_FRESH_US (120 * G_USEC_PER_SEC)
/**
 * A periodic round skips a place whose latest SUCCESS is less than this ago.
 * Shorter than WX_SCHED_PERIOD_US, so a success one round ago is refreshed.
 */
#define WX_SCHED_PERIODIC_FRESH_US (540 * G_USEC_PER_SEC)
/** Maximum number of requests outstanding at once (all places). */
#define WX_SCHED_MAX_INFLIGHT 3
/** Wall-minus-monotonic drift above which a forward clock jump is assumed. */
#define WX_SCHED_JUMP_TOLERANCE_US (10 * G_USEC_PER_SEC)
/** Size of WxSchedAction.key: the longest key wx_place_key() builds (18 bytes) plus room. */
#define WX_SCHED_KEY_BYTES 24

typedef struct _WxScheduler WxScheduler;

/**
 * The instant an input happens at; both clocks are read by the caller.
 * mono_us is never negative (g_get_monotonic_time() counts from an arbitrary
 * start that is not before boot); every call taking a WxSchedTime treats a
 * negative value as a programmer error. A deadline of -1 means "none", which
 * is why the scale starts at 0.
 */
typedef struct {
  gint64 mono_us; /**< g_get_monotonic_time(), >= 0                     */
  gint64 wall_ms; /**< real time, milliseconds since the Unix epoch UTC */
} WxSchedTime;

/** The kinds of instruction the scheduler gives its owner. */
typedef enum {
  WX_SCHED_FETCH, /**< start a forecast refresh for the place        */
  WX_SCHED_CANCEL /**< cancel the request with this id               */
} WxSchedActionType;

/** An instruction for the owner; plain data, no pointers. */
typedef struct {
  WxSchedActionType type;
  /** FETCH: id of the new request (never 0, never reused); CANCEL: id of the
   *  request to cancel. */
  guint64 id;
  /** FETCH: the place key, NUL-terminated; CANCEL: "". */
  char key[WX_SCHED_KEY_BYTES];
} WxSchedAction;

/** Outcome of a request (input of wx_scheduler_request_done()). */
typedef enum {
  WX_SCHED_RESULT_OK,
  WX_SCHED_RESULT_FAILED,   /**< any error except cancellation */
  WX_SCHED_RESULT_CANCELLED /**< ended by cancellation          */
} WxSchedResult;

/**
 * wx_scheduler_new:
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the scheduler is hidden, offline, has no places, no selection, no pending
 *    action and no deadline; the first request id it will issue is 1.
 * Thread affinity: the thread that will use it (main thread); the scheduler is
 *   not thread-safe.
 * Ownership: the caller owns the result; release it with wx_scheduler_free().
 *
 * Returns: (transfer full): a scheduler that is hidden, offline and empty (so
 *   it emits nothing until told otherwise).
 */
WxScheduler *wx_scheduler_new(void);

/**
 * wx_scheduler_free:
 * @self: (nullable) (transfer full): the scheduler to free, or NULL.
 *
 * Frees @self; NULL is allowed. Requests still in flight are forgotten.
 *
 * Preconditions:
 *  - @self is NULL or a scheduler from wx_scheduler_new() that is not used
 *    again; no other thread uses it.
 * Postconditions:
 *  - everything the scheduler owns is freed, including actions that were never
 *    taken; an array already returned by wx_scheduler_take_actions() is not
 *    affected. Nothing is cancelled: the owner cancels its own requests.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: consumes @self.
 */
void wx_scheduler_free(WxScheduler *self);

/**
 * wx_scheduler_set_places:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 * @keys: (nullable) (array length=n): the keys of the tracked places in
 *   display order; elements that are NULL, not a key (see below) or a repeat
 *   are ignored. May be NULL when @n is 0.
 * @n: number of elements.
 *
 * Replaces the tracked set. Kept places keep their state; a removed place's
 * request in flight is cancelled; while active, a new place is wanted at once.
 * The list order is the order in which waiting places of equal priority are
 * started.
 *
 * A key is accepted when it is NUL-terminated within WX_SCHED_KEY_BYTES - 1
 * characters and consists of 1 to 23 characters of [0-9.,-] (the alphabet of
 * wx_place_key()); nothing more is checked, so any such string is a place.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes); @keys is non-NULL
 *    or @n is 0 (else: critical, nothing changes).
 *  - @keys points to @n readable pointers; each is NULL, NUL-terminated or
 *    has at least WX_SCHED_KEY_BYTES readable bytes (at most that many are
 *    read).
 * Postconditions:
 *  - the tracked set is the valid, de-duplicated elements (the scheduler keeps
 *    its own copies); @keys and the strings it points to are not retained.
 *    Pending actions may have been queued (CANCEL for removed places, FETCH
 *    for new ones while active); the deadline is re-evaluated.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: all pointers are borrowed for the call only.
 */
void wx_scheduler_set_places(WxScheduler *self, WxSchedTime now, const char *const *keys,
                             gsize n);

/**
 * wx_scheduler_set_selection:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 * @key: (nullable): the key of the selected place, or NULL / an invalid key
 *   for none. It need not be tracked (yet).
 *
 * The selected place is started before the other waiting places. Changing the
 * selection fetches nothing by itself and changes no stale mark.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes); @key is NULL,
 *    NUL-terminated or has at least WX_SCHED_KEY_BYTES readable bytes.
 * Postconditions:
 *  - the selection is @key when it is a valid key (see
 *    wx_scheduler_set_places()), none otherwise; @key is not retained.
 *    No action is queued (a place waits only while every slot is taken); the
 *    new order applies when a slot frees.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: @key is borrowed for the call only.
 */
void wx_scheduler_set_selection(WxScheduler *self, WxSchedTime now, const char *key);

/**
 * wx_scheduler_set_visible:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 * @visible: whether the window is mapped and not minimised/suspended.
 *
 * No-op when unchanged. TRUE starts an event round (when online); FALSE
 * cancels everything in flight and drops everything waiting.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes).
 * Postconditions:
 *  - the visible flag is !!@visible; actions may have been queued and the
 *    deadline re-evaluated.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers besides @self, which is only used for the call).
 */
void wx_scheduler_set_visible(WxScheduler *self, WxSchedTime now, gboolean visible);

/**
 * wx_scheduler_set_online:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 * @online: whether the network is available.
 *
 * No-op when unchanged. TRUE starts an event round (when visible); FALSE
 * cancels everything in flight and drops everything waiting.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes).
 * Postconditions:
 *  - the online flag is !!@online; actions may have been queued and the
 *    deadline re-evaluated.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers besides @self, which is only used for the call).
 */
void wx_scheduler_set_online(WxScheduler *self, WxSchedTime now, gboolean online);

/**
 * wx_scheduler_focus_regained:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 *
 * The window became the active window. Starts an event round, but only while
 * visible and online (otherwise nothing: showing or reconnecting does it).
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes).
 * Postconditions:
 *  - actions may have been queued and the deadline re-evaluated.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers besides @self, which is only used for the call).
 */
void wx_scheduler_focus_regained(WxScheduler *self, WxSchedTime now);

/**
 * wx_scheduler_tick:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 *
 * To be called when the timer armed for wx_scheduler_next_wakeup_us() fires.
 * If the deadline has been reached and the window is visible and the network
 * available: starts a periodic round and schedules the next deadline one
 * period after the old one (one period after @now when it fired late).
 * Calling it early, or with no deadline, only re-evaluates the conditions.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing changes).
 * Postconditions:
 *  - actions may have been queued; the deadline is re-evaluated (see
 *    wx_scheduler_next_wakeup_us()).
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers besides @self, which is only used for the call).
 */
void wx_scheduler_tick(WxScheduler *self, WxSchedTime now);

/**
 * wx_scheduler_request_done:
 * @self: (not nullable): the scheduler.
 * @now: the current time.
 * @id: the id of a request that FETCH returned (also one that was cancelled;
 *   the owner reports every request exactly once).
 * @result: how it ended.
 *
 * Frees the request's slot, updates the stale mark and the freshness of the
 * place and starts waiting places. An unknown or already finished @id is
 * ignored.
 *
 * Preconditions:
 *  - @self is a scheduler and @now.mono_us >= 0 (else: critical, nothing
 *    changes); @result is a
 *    WxSchedResult (a value other than OK or FAILED is handled like
 *    CANCELLED: no mark changes).
 * Postconditions:
 *  - if @id is the id of an outstanding request: that request no longer holds
 *    a slot (the in-flight count drops by one, the entry of a removed place is
 *    freed); otherwise only the conditions are re-evaluated. Actions may have
 *    been queued.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers besides @self, which is only used for the call).
 */
void wx_scheduler_request_done(WxScheduler *self, WxSchedTime now, guint64 id,
                               WxSchedResult result);

/**
 * wx_scheduler_take_actions:
 * @self: (not nullable): the scheduler.
 *
 * Preconditions:
 *  - @self is a scheduler (else: critical, NULL returned).
 * Postconditions:
 *  - the scheduler holds no pending action afterwards.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: the caller owns the returned array.
 *
 * Returns: (transfer full) (nullable) (element-type WxSchedAction): the
 *   actions produced since the last call, in the order to execute them, or
 *   NULL if there are none. Free with g_array_unref().
 */
GArray *wx_scheduler_take_actions(WxScheduler *self);

/**
 * wx_scheduler_next_wakeup_us:
 * @self: (not nullable): the scheduler.
 *
 * Preconditions:
 *  - @self is a scheduler (else: critical, -1 returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers returned).
 *
 * Returns: the monotonic time (microseconds, g_get_monotonic_time() scale) at
 *   which to call wx_scheduler_tick(), or -1: no timer must exist. It can
 *   change after every call that takes a WxSchedTime; re-read it after each.
 */
gint64 wx_scheduler_next_wakeup_us(WxScheduler *self);

/**
 * wx_scheduler_is_stale:
 * @self: (not nullable): the scheduler.
 * @key: (nullable): the key of a tracked place.
 *
 * Preconditions:
 *  - @self is a scheduler (else: critical, FALSE returned); @key is NULL,
 *    NUL-terminated or has at least WX_SCHED_KEY_BYTES readable bytes.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: @key is borrowed for the call only.
 *
 * Returns: TRUE iff the latest request of the place failed and no success has
 *   cleared it since (see "Failure" and "Stale marks" above). FALSE for
 *   unknown (and NULL or invalid) keys.
 */
gboolean wx_scheduler_is_stale(WxScheduler *self, const char *key);

/**
 * wx_scheduler_n_inflight:
 * @self: (not nullable): the scheduler.
 *
 * Preconditions:
 *  - @self is a scheduler (else: critical, 0 returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: the thread that owns the scheduler (main thread).
 * Ownership: none (no pointers returned).
 *
 * Returns: the number of requests outstanding, cancelled ones included.
 */
guint wx_scheduler_n_inflight(WxScheduler *self);

G_END_DECLS

#endif /* WX_SCHEDULER_H */
