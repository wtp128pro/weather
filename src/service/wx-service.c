/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-service.c - WxService: refresh fan-out, deadline, per-source status, blend and geocoder
 * search. See wx-service.h for the behaviour contract.
 *
 * One refresh is an Op: a small reference-counted record owned by the GTask of the operation, the
 * outstanding provider calls ("children") and the two GSources (deadline, caller's cancellation).
 * It never references the service: the GTask does, so the service lives until the callback has
 * returned, while a late delivery of a provider that was cancelled or timed out only finds an Op
 * whose task is gone and frees what it received. Everything runs in the main context of the
 * caller; the reference counts are plain integers.
 */
#include "wx-service.h"

#include <string.h>

#include "wx-blend.h"
#include "wx-text.h"

#ifdef WX_SERVICE_TESTING
#include "wx-service-testing.h"
#endif

/* Longest provider message kept in a service error, bytes. */
#define MESSAGE_MAX 200

/* The statuses of one refresh are handed to wx_forecast_new(), which takes at most this many. */
G_STATIC_ASSERT(WX_REGISTRY_MAX_PROVIDERS <= WX_FORECAST_MAX_SOURCES);

/* A provider that has a usable member always gets one forwarded (select_members(), step 3). */
G_STATIC_ASSERT(WX_REGISTRY_MAX_PROVIDERS <= WX_BLEND_MAX_MEMBERS);

struct _WxService {
  GObject parent_instance;
  WxRegistry *registry; /* strong reference */
};

G_DEFINE_TYPE(WxService, wx_service, G_TYPE_OBJECT)

/* Addresses only (never read): the source tags that tell the two finish functions apart. */
static char tag_refresh, tag_search;

#ifdef WX_SERVICE_TESTING
/* Deadline of the refreshes started from now on; set by wx_service_test_set_deadline_ms(). */
static guint test_deadline_ms = WX_SERVICE_DEADLINE_MS;

/* Documented in wx-service-testing.h. */
void
wx_service_test_set_deadline_ms(guint deadline_ms)
{
  test_deadline_ms = deadline_ms != 0 ? deadline_ms : WX_SERVICE_DEADLINE_MS;
}
#endif

/* ------------------------------------------------------------------------ */
/* GObject boilerplate                                                      */
/* ------------------------------------------------------------------------ */

/**
 * wx_service_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: nothing to do; the registry stays NULL until wx_service_new()
 * sets it.
 *
 * Preconditions:
 *  - @self is a zero-initialised WxService being constructed by GObject.
 * Postconditions:
 *  - @self is unchanged.
 * Thread affinity: main thread only.
 * Ownership: @self stays with GObject; nothing is retained.
 */
static void
wx_service_init(WxService *self)
{
  (void)self;
}

/**
 * wx_service_finalize:
 * @object: (not nullable): the WxService being finalized.
 *
 * GObject finalize: drops the registry reference. There is deliberately no dispose override: the
 * service creates no reference cycle (the registry does not know it), and keeping the registry
 * until finalize means that every method stays usable after g_object_run_dispose(). Operations
 * hold a reference to the service, so none is in flight here.
 *
 * Preconditions:
 *  - @object is a WxService whose last reference is gone (runs once).
 * Postconditions:
 *  - the registry reference is released; the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the registry reference owned by the service is released.
 */
static void
wx_service_finalize(GObject *object)
{
  g_clear_object(&WX_SERVICE(object)->registry);
  G_OBJECT_CLASS(wx_service_parent_class)->finalize(object);
}

/**
 * wx_service_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs finalize.
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden; there are no properties or signals.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @klass is owned by the type system and not retained.
 */
static void
wx_service_class_init(WxServiceClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_service_finalize;
}

/* Documented in wx-service.h. */
WxService *
wx_service_new(WxRegistry *registry)
{
  g_return_val_if_fail(WX_IS_REGISTRY(registry), NULL);
  WxService *self = g_object_new(WX_TYPE_SERVICE, NULL);
  self->registry = g_object_ref(registry);
  return self;
}

/* ------------------------------------------------------------------------ */
/* Errors                                                                   */
/* ------------------------------------------------------------------------ */

/**
 * cancelled_error:
 *
 * Builds the error that reports a cancellation.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread.
 * Ownership: the caller owns the error.
 *
 * Returns: (transfer full): G_IO_ERROR / G_IO_ERROR_CANCELLED, "operation was cancelled".
 */
static GError *
cancelled_error(void)
{
  return g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "operation was cancelled");
}

/**
 * normalize_error:
 * @error: (transfer full): an error reported by a provider or a geocoder.
 *
 * Reduces an error from outside to what the service reports: a cancellation stays a
 * cancellation, a WX_ERROR keeps its code, every other error is WX_ERROR_NETWORK. The message is
 * rebuilt through wx_sanitize_text() (at most MESSAGE_MAX bytes of valid UTF-8, no control
 * characters).
 *
 * Preconditions:
 *  - @error is a valid GError (non-NULL message).
 * Postconditions:
 *  - @error is freed.
 * Thread affinity: any thread.
 * Ownership: consumes @error; the caller owns the result.
 *
 * Returns: (transfer full): G_IO_ERROR_CANCELLED, or a WX_ERROR error with a valid code.
 */
static GError *
normalize_error(GError *error)
{
  GError *out;
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    out = cancelled_error();
  } else {
    g_autofree char *message = wx_sanitize_text(error->message, MESSAGE_MAX);
    int code = (error->domain == WX_ERROR && error->code >= WX_ERROR_NETWORK &&
                error->code <= WX_ERROR_UNSUPPORTED)
                   ? error->code
                   : WX_ERROR_NETWORK;
    out = g_error_new_literal(WX_ERROR, code, message);
  }
  g_error_free(error);
  return out;
}

/* The rank of a provider's local refusal (is_local_refusal()): after every code of error_rank(). */
#define LOCAL_REFUSAL_RANK 7

/**
 * error_rank:
 * @code: a WxError value.
 *
 * Ranks an error by how informative it is for the user (smaller is more informative).
 *
 * Preconditions:
 *  - none (any value is accepted).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: 0 for WX_ERROR_NETWORK and WX_ERROR_TIMEOUT, then 1 WX_ERROR_RATE_LIMITED, 2
 *   WX_ERROR_HTTP, 3 WX_ERROR_PARSE, 4 WX_ERROR_NOT_FOUND, 5 WX_ERROR_UNSUPPORTED, 6 for every
 *   other value (WX_ERROR_INVALID_ARG).
 */
static int
error_rank(int code)
{
  switch (code) {
  case WX_ERROR_NETWORK:
  case WX_ERROR_TIMEOUT:
    return 0;
  case WX_ERROR_RATE_LIMITED:
    return 1;
  case WX_ERROR_HTTP:
    return 2;
  case WX_ERROR_PARSE:
    return 3;
  case WX_ERROR_NOT_FOUND:
    return 4;
  case WX_ERROR_UNSUPPORTED:
    return 5;
  default:
    return 6;
  }
}

/**
 * is_local_refusal:
 * @error: (not nullable): a normalised error of a provider's fetch (see normalize_error()).
 *
 * Tells whether @error is a provider's own refusal to send a request, which says nothing about
 * the server: a WX_ERROR_RATE_LIMITED whose message begins with one of the two texts the
 * providers give when they refuse without any network traffic because of their own limits (the
 * per-place floor of MET Norway, "a request for this place was sent less than 10 minutes ago",
 * and the cap on outstanding requests, "too many outstanding requests"). A rate limit that a
 * server announced (HTTP 429), or a pause that a provider keeps after one ("requests are paused
 * after HTTP 429", "NWS asked for fewer requests ...") is not a local refusal.
 *
 * Preconditions:
 *  - @error is non-NULL with a non-NULL message.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @error is a local refusal.
 */
static gboolean
is_local_refusal(const GError *error)
{
  return error->domain == WX_ERROR && error->code == WX_ERROR_RATE_LIMITED &&
         (g_str_has_prefix(error->message, "a request for this place was sent less than 10 "
                                           "minutes ago") ||
          g_str_has_prefix(error->message, "too many outstanding requests"));
}

/* ------------------------------------------------------------------------ */
/* One refresh                                                              */
/* ------------------------------------------------------------------------ */

/* One registered provider of one refresh. */
typedef struct {
  WxSourceStatus *status; /* owned; SKIPPED, -1, 0 until settle_slot() / select_members() */
  WxProvider *provider;   /* strong reference while the fetches are being started, else NULL */
  gboolean fetched;       /* a fetch was (or is being) started on the provider */
  gboolean done;          /* its callback ran before the operation completed */
  WxSourceResult *result; /* owned: the delivered result, only when it has a usable member */
  GPtrArray *forward;     /* owned, NULL exactly when result is: members of result for the blend,
                             borrowed (no free function; valid while result is): the usable ones
                             until select_members(), then the ones it forwards */
  GError *error;          /* owned: the normalised failure of the fetch, or NULL */
} Slot;

/* The state of one refresh. Main context only. */
typedef struct {
  guint ref_count;           /* starter, children, sources */
  GTask *task;               /* owned; NULL once the operation has completed */
  WxPlace *place;            /* owned */
  guint deadline_ms;         /* the deadline this refresh started with */
  Slot *slots;               /* one per listed provider, registration order */
  guint n_slots;
  guint pending;             /* started fetches whose callback has not run yet */
  gboolean starting;         /* the fetches are being started: do not complete from a callback */
  GCancellable *child_cancellable; /* owned: shared by every fetch, cancelled on deadline/cancel */
  GSource *deadline_source;  /* owned reference; NULL once stopped */
  GSource *cancel_source;    /* owned reference; NULL when no cancellable or once stopped */
} Op;

/* The callback data of one fetch: a reference to the Op and the slot the answer belongs to. */
typedef struct {
  Op *op;
  guint index;
} Child;

/** How an operation completes. */
typedef enum {
  DONE_ALL,       /* every started fetch has called back */
  DONE_DEADLINE,  /* the deadline expired */
  DONE_CANCELLED  /* the caller's cancellable was cancelled */
} Done;

/**
 * refresh_deadline_ms:
 *
 * The deadline of a refresh that starts now.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: WX_SERVICE_DEADLINE_MS (the test flavour may have replaced it).
 */
static guint
refresh_deadline_ms(void)
{
#ifdef WX_SERVICE_TESTING
  return test_deadline_ms;
#else
  return WX_SERVICE_DEADLINE_MS;
#endif
}

/**
 * slot_clear:
 * @slot: (not nullable): a slot of a finished or abandoned operation.
 *
 * Releases everything a slot owns.
 *
 * Preconditions:
 *  - @slot was initialised by op_add_slots() (zero-initialised, then filled).
 * Postconditions:
 *  - the status, the provider reference, the forward list, the result and the error are
 *    released.
 * Thread affinity: main thread only.
 * Ownership: the slot's resources are released; @slot itself stays with the caller.
 */
static void
slot_clear(Slot *slot)
{
  wx_source_status_free(slot->status);
  g_clear_object(&slot->provider);
  g_clear_pointer(&slot->forward, g_ptr_array_unref);
  wx_source_result_free(slot->result);
  g_clear_error(&slot->error);
}

/**
 * op_ref:
 * @op: (not nullable): the operation record.
 *
 * Takes a reference.
 *
 * Preconditions:
 *  - the caller owns a reference to @op.
 * Postconditions:
 *  - the count grew by one.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the new reference.
 *
 * Returns: (transfer full): @op.
 */
static Op *
op_ref(Op *op)
{
  op->ref_count++;
  return op;
}

/**
 * op_unref:
 * @op: (not nullable): the operation record.
 *
 * Drops a reference; at zero the record is freed. By then the task has normally been returned
 * (while it is open the deadline source holds a reference); a task that is still open is dropped.
 *
 * Preconditions:
 *  - the caller owns a reference to @op.
 * Postconditions:
 *  - at zero the slots, the place, the private cancellable and the record are freed.
 * Thread affinity: main thread only.
 * Ownership: consumes the caller's reference.
 */
static void
op_unref(Op *op)
{
  if (--op->ref_count > 0)
    return;
  g_clear_object(&op->task);
  for (guint i = 0; i < op->n_slots; i++)
    slot_clear(&op->slots[i]);
  g_free(op->slots);
  wx_place_free(op->place);
  g_clear_object(&op->child_cancellable);
  g_free(op);
}

/**
 * op_unref_notify:
 * @data: (not nullable): an Op, passed as gpointer.
 *
 * GDestroyNotify of the sources' callback data.
 *
 * Preconditions:
 *  - @data is an Op whose reference the source owned.
 * Postconditions:
 *  - the reference is dropped.
 * Thread affinity: main thread only.
 * Ownership: consumes the source's reference.
 */
static void
op_unref_notify(gpointer data)
{
  op_unref(data);
}

/**
 * stop_sources:
 * @op: (not nullable): the operation record.
 *
 * Destroys the deadline source and the cancellation watch, if there is one (which drops the
 * references they hold on @op).
 *
 * Preconditions:
 *  - the caller holds a reference to @op of its own; the deadline source exists (it is created
 *    before the first fetch and lives until the operation completes).
 * Postconditions:
 *  - both sources are NULL and destroyed; neither will be dispatched again.
 * Thread affinity: main thread only.
 * Ownership: the two source references owned by @op are released.
 */
static void
stop_sources(Op *op)
{
  g_source_destroy(op->deadline_source);
  g_clear_pointer(&op->deadline_source, g_source_unref);
  if (op->cancel_source != NULL) {
    g_source_destroy(op->cancel_source);
    g_clear_pointer(&op->cancel_source, g_source_unref);
  }
}

/**
 * drop_null_members:
 * @members: (not nullable): the members array of a provider's result.
 *
 * Removes the NULL entries a misbehaving provider left in a result, so that freeing the result
 * does not unref them (wx_member_unref (NULL) is a critical).
 *
 * Preconditions:
 *  - @members is a valid GPtrArray whose non-NULL elements are members owned by it.
 * Postconditions:
 *  - the non-NULL entries are kept, in order, without their free function having run on any;
 *    no NULL entry is left.
 * Thread affinity: main thread only.
 * Ownership: the entries stay owned by @members.
 */
static void
drop_null_members(GPtrArray *members)
{
  gsize n = 0;
  gpointer *items = g_ptr_array_steal(members, &n); /* the free function is not run */
  for (gsize i = 0; i < n; i++) {
    if (items[i] != NULL)
      g_ptr_array_add(members, items[i]);
  }
  g_free(items);
}

/**
 * member_usable:
 * @member: (nullable): a member of a provider's result, possibly hand-built.
 *
 * Decides whether a member is worth a place among the blend's WX_BLEND_MAX_MEMBERS. It is when the
 * blend would let it take part and it carries something the blend can use. The blend's rule
 * (member_is_valid() in wx-blend.c, private to it, mirrored here) is: non-NULL, valid source and
 * model ids, at most WX_MEMBER_MAX_HOURS hours behind a non-NULL array, every hour stamp inside
 * [WX_TIME_MIN_S, WX_TIME_MAX_S), a multiple of 3600 and strictly greater than the stamp before.
 * Usable data is at least one hour, or quarters under the guard of the blend's nowcast (a non-NULL
 * array of 1..WX_MEMBER_MAX_QUARTERS entries; the entries are not looked at).
 *
 * Preconditions:
 *  - none: any value passes, hand-built garbage included (a pointer must be NULL or a member
 *    whose strings are NUL-terminated and whose hours array holds n_hours entries).
 * Postconditions:
 *  - nothing is modified; at most WX_MEMBER_MAX_HOURS hours are read.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the member is valid for the blend and has an hour or quarters.
 */
static gboolean
member_usable(const WxMember *member)
{
  if (member == NULL || !wx_id_is_valid(member->source_id) || !wx_id_is_valid(member->model_id))
    return FALSE;
  if (member->n_hours > WX_MEMBER_MAX_HOURS || (member->n_hours > 0 && member->hours == NULL))
    return FALSE;
  for (guint i = 0; i < member->n_hours; i++) {
    gint64 t = member->hours[i].t_s;
    if (t < WX_TIME_MIN_S || t >= WX_TIME_MAX_S || t % 3600 != 0 ||
        (i > 0 && t <= member->hours[i - 1].t_s))
      return FALSE;
  }
  return member->n_hours > 0 ||
         (member->quarters != NULL && member->n_quarters > 0 &&
          member->n_quarters <= WX_MEMBER_MAX_QUARTERS);
}

/**
 * member_id_hash:
 * @key: (not nullable): a usable member, passed as gconstpointer.
 *
 * GHashFunc of the (source_id, model_id) pair of a member.
 *
 * Preconditions:
 *  - @key is a WxMember with valid (NUL-terminated) ids.
 * Postconditions:
 *  - nothing is modified; equal pairs give equal hashes.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the hash.
 */
static guint
member_id_hash(gconstpointer key)
{
  const WxMember *member = key;
  return g_str_hash(member->source_id) * 31u + g_str_hash(member->model_id);
}

/**
 * member_id_equal:
 * @a: (not nullable): a usable member, passed as gconstpointer.
 * @b: (not nullable): a usable member, passed as gconstpointer.
 *
 * GEqualFunc: two members are equal when both ids are equal (the blend's notion of "the same
 * member").
 *
 * Preconditions:
 *  - @a and @b are WxMembers with valid (NUL-terminated) ids.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff source_id and model_id are both equal.
 */
static gboolean
member_id_equal(gconstpointer a, gconstpointer b)
{
  const WxMember *x = a, *y = b;
  return strcmp(x->source_id, y->source_id) == 0 && strcmp(x->model_id, y->model_id) == 0;
}

/**
 * collect_usable:
 * @result: (not nullable): a provider's result.
 *
 * Lists the usable members of a result (member_usable()), in the result's order.
 *
 * Preconditions:
 *  - @result is a WxSourceResult whose members array is NULL or a valid GPtrArray (NULL entries
 *    are allowed: they are not usable).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the new array; the members stay owned by @result and must outlive it.
 *
 * Returns: (transfer full): a GPtrArray without free function holding borrowed members; empty
 *   when there is no usable member.
 */
static GPtrArray *
collect_usable(const WxSourceResult *result)
{
  GPtrArray *usable = g_ptr_array_new();
  if (result->members == NULL)
    return usable;
  for (guint i = 0; i < result->members->len; i++) {
    const WxMember *member = g_ptr_array_index(result->members, i);
    if (member_usable(member))
      g_ptr_array_add(usable, (gpointer)member);
  }
  return usable;
}

/**
 * settle_slot:
 * @op: (not nullable): the completing operation.
 * @slot: (not nullable): one of its slots.
 *
 * Turns what a slot received into its final state and error code (see wx-service.h): a fetch
 * whose callback has not run by now is the deadline's timeout. The member count of an OK slot is
 * select_members()'s.
 *
 * Preconditions:
 *  - @op is completing with DONE_ALL or DONE_DEADLINE; @slot belongs to it.
 * Postconditions:
 *  - the status fields state and error_code are final; a timed-out fetch carries a
 *    WX_ERROR_TIMEOUT error; a slot that was not fetched is untouched (SKIPPED, -1, 0).
 * Thread affinity: main thread only.
 * Ownership: nothing is retained beyond the slot.
 */
static void
settle_slot(const Op *op, Slot *slot)
{
  if (!slot->fetched)
    return;
  if (!slot->done)
    slot->error = g_error_new(WX_ERROR, WX_ERROR_TIMEOUT, "no answer within %u ms",
                              op->deadline_ms);
  WxSourceStatus *status = slot->status;
  if (slot->error == NULL) {
    status->state = WX_SRC_OK;
  } else if (g_error_matches(slot->error, WX_ERROR, WX_ERROR_UNSUPPORTED)) {
    status->state = WX_SRC_SKIPPED;
  } else if (slot->error->domain == WX_ERROR) {
    status->state = WX_SRC_FAILED;
    status->error_code = slot->error->code;
  } else {
    status->state = WX_SRC_FAILED; /* cancelled by the provider itself: no WxError code */
  }
}

/**
 * pick_error:
 * @op: (not nullable): the completed operation whose slots are settled.
 * @blend_error: (nullable): the blend's error when it was called and failed.
 *
 * Chooses the error of a refresh without a forecast (see the file comment of wx-service.h). A
 * provider's local refusal (is_local_refusal()) ranks after every other failure, the blend's
 * included, and when it is all that remains it is reported as WX_ERROR_NOT_FOUND (with the
 * provider's message): it is not a rate limit of a server, so it must not make the application
 * hold the place back as one.
 *
 * Preconditions:
 *  - every slot is settled; when @blend_error is NULL no provider result was blended.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result; @op and @blend_error stay with the caller.
 *
 * Returns: (transfer full): the most informative WX_ERROR (a slot's error with the provider id
 *   in front of its message, or a copy of @blend_error when it ranks better), or
 *   G_IO_ERROR_CANCELLED when no failure remains (every covering provider was cancelled).
 */
static GError *
pick_error(const Op *op, const GError *blend_error)
{
  const Slot *best = NULL;
  int best_rank = G_MAXINT;
  for (guint i = 0; i < op->n_slots; i++) {
    const Slot *slot = &op->slots[i];
    if (slot->error == NULL || slot->error->domain != WX_ERROR)
      continue;
    int rank = is_local_refusal(slot->error) ? LOCAL_REFUSAL_RANK : error_rank(slot->error->code);
    if (rank < best_rank) {
      best = slot;
      best_rank = rank;
    }
  }
  if (blend_error != NULL && error_rank(blend_error->code) < best_rank)
    return g_error_copy(blend_error);
  if (best != NULL) {
    int code = best_rank == LOCAL_REFUSAL_RANK ? WX_ERROR_NOT_FOUND : best->error->code;
    return g_error_new(WX_ERROR, code, "%s: %s", best->status->provider_id, best->error->message);
  }
  return cancelled_error();
}

/**
 * select_members:
 * @op: (not nullable): the completing operation whose slots are settled.
 *
 * Chooses the members that go to the blend and sets the member count of every OK slot (the
 * fair-share rule of wx-service.h, so that no provider can take the blend's WX_BLEND_MAX_MEMBERS
 * places away from another). The slots' forward lists hold their usable members (member_usable())
 * on entry. First the distinct members are kept: walking the slots in registration order and each
 * list in its own order, a member whose (source_id, model_id) was seen before is dropped (the
 * first one wins), whether or not the member it duplicates is forwarded in the end. Then, when
 * more than WX_BLEND_MAX_MEMBERS remain, places are dealt round-robin: one member at a time to
 * each provider that still has one, in registration order, until WX_BLEND_MAX_MEMBERS are dealt,
 * so a provider keeps the first members of its own list.
 *
 * Preconditions:
 *  - @op is completing with DONE_ALL or DONE_DEADLINE, every slot is settled, and every slot with
 *    a result has a forward list of its usable members, without a free function.
 * Postconditions:
 *  - the forward lists are the chosen members, pairwise distinct over all slots, at most
 *    WX_BLEND_MAX_MEMBERS in all, each slot's in its own order; the n_members of every slot's
 *    status is the length of its forward list (0 for a slot without one).
 * Thread affinity: main thread only.
 * Ownership: the lists stay owned by the slots; nothing is retained.
 */
static void
select_members(Op *op)
{
  g_autoptr(GHashTable) seen = g_hash_table_new(member_id_hash, member_id_equal);
  for (guint i = 0; i < op->n_slots; i++) {
    Slot *slot = &op->slots[i];
    if (slot->forward == NULL)
      continue;
    GPtrArray *distinct = g_ptr_array_new();
    for (guint k = 0; k < slot->forward->len; k++) {
      gpointer member = g_ptr_array_index(slot->forward, k);
      if (g_hash_table_contains(seen, member))
        continue;
      g_hash_table_add(seen, member);
      g_ptr_array_add(distinct, member);
    }
    g_ptr_array_unref(slot->forward);
    slot->forward = distinct;
  }

  g_autofree guint *dealt = g_new0(guint, op->n_slots);
  guint total = 0;
  gboolean progress = TRUE;
  while (progress && total < WX_BLEND_MAX_MEMBERS) {
    progress = FALSE;
    for (guint i = 0; i < op->n_slots && total < WX_BLEND_MAX_MEMBERS; i++) {
      const Slot *slot = &op->slots[i];
      if (slot->forward != NULL && dealt[i] < slot->forward->len) {
        dealt[i]++;
        total++;
        progress = TRUE;
      }
    }
  }
  for (guint i = 0; i < op->n_slots; i++) {
    Slot *slot = &op->slots[i];
    if (slot->forward != NULL)
      g_ptr_array_set_size(slot->forward, dealt[i]); /* only shrinks; no free function */
    slot->status->n_members = dealt[i];
  }
}

/**
 * build_forecast:
 * @op: (not nullable): the completing operation whose slots are settled.
 * @error: (out): receives the error when there is no forecast.
 *
 * Blends the members that select_members() chose, provider by provider in registration order,
 * with the statuses of every slot.
 *
 * Preconditions:
 *  - @op is completing with DONE_ALL or DONE_DEADLINE and select_members() has run; *@error is
 *    NULL.
 * Postconditions:
 *  - on success a new forecast and *@error untouched; on failure NULL and *@error set (see
 *    pick_error()). wx_blend_forecast() is not called when no member was chosen.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the forecast; @op stays with the caller.
 *
 * Returns: (transfer full) (nullable): the forecast.
 */
static WxForecast *
build_forecast(const Op *op, GError **error)
{
  g_autofree WxSourceStatus *statuses = g_new(WxSourceStatus, op->n_slots);
  g_autofree WxSourceResult *chosen = g_new(WxSourceResult, op->n_slots);
  g_autofree const WxSourceResult **results = g_new(const WxSourceResult *, op->n_slots);
  guint n_results = 0;
  for (guint i = 0; i < op->n_slots; i++) {
    const Slot *slot = &op->slots[i];
    statuses[i] = *slot->status; /* shallow: the strings stay owned by the slot */
    if (slot->forward != NULL && slot->forward->len > 0) {
      /* the blend reads only the members; the array holds borrowed pointers and is not freed */
      chosen[n_results] =
          (WxSourceResult){.provider_id = slot->result->provider_id, .members = slot->forward};
      results[n_results] = &chosen[n_results];
      n_results++;
    }
  }

  g_autoptr(GError) blend_error = NULL;
  WxForecast *forecast = NULL;
  if (n_results > 0) {
    gint64 now_s = g_get_real_time() / G_USEC_PER_SEC;
    forecast = wx_blend_forecast(op->place, (const WxSourceResult *const *)results, n_results,
                                 statuses, op->n_slots, now_s, &blend_error);
  }
  if (forecast == NULL)
    *error = pick_error(op, blend_error);
  return forecast;
}

/**
 * op_complete:
 * @op: (not nullable): the operation record.
 * @how: why the operation completes.
 *
 * Completes the operation exactly once: stops the sources, builds the outcome (a cancellation
 * needs none), releases the delivered results, cancels the fetches that are still outstanding
 * (deadline and cancellation) and returns the outcome through the task. The caller's callback
 * may run before this returns and may do anything, including dropping the last reference to the
 * service; nothing of the operation is used afterwards.
 *
 * Preconditions:
 *  - the task has not been returned yet (violation: critical, nothing happens): the sources are
 *    destroyed with the first completion, so neither can dispatch again, and a late fetch never
 *    reaches this function.
 * Postconditions:
 *  - the task has returned a forecast or an error; its callback runs now or in an idle; a
 *    fetch that calls back later is freed unread (op->task is NULL).
 * Thread affinity: main thread only.
 * Ownership: the caller keeps its reference to @op.
 */
static void
op_complete(Op *op, Done how)
{
  g_return_if_fail(op->task != NULL);
  g_autoptr(GTask) task = g_steal_pointer(&op->task);
  op_ref(op); /* stopping the sources drops the references they held */
  stop_sources(op);

  WxForecast *forecast = NULL;
  GError *error = NULL;
  if (how == DONE_CANCELLED) {
    error = cancelled_error();
  } else {
    for (guint i = 0; i < op->n_slots; i++)
      settle_slot(op, &op->slots[i]);
    select_members(op);
    forecast = build_forecast(op, &error);
  }
  for (guint i = 0; i < op->n_slots; i++) {
    g_clear_pointer(&op->slots[i].forward, g_ptr_array_unref);
    g_clear_pointer(&op->slots[i].result, wx_source_result_free);
  }
  if (how != DONE_ALL)
    g_cancellable_cancel(op->child_cancellable);

  if (forecast != NULL)
    g_task_return_pointer(task, forecast, (GDestroyNotify)wx_forecast_unref);
  else
    g_task_return_error(task, error);
  op_unref(op);
}

/**
 * op_finish_if_done:
 * @op: (not nullable): the operation record.
 *
 * Completes the operation when every started fetch has called back.
 *
 * Preconditions:
 *  - the caller holds a reference to @op.
 * Postconditions:
 *  - if the operation is still open, no fetch is being started and none is outstanding, it has
 *    completed with DONE_ALL; otherwise nothing happened.
 * Thread affinity: main thread only.
 * Ownership: the caller keeps its reference.
 */
static void
op_finish_if_done(Op *op)
{
  if (op->task != NULL && !op->starting && op->pending == 0)
    op_complete(op, DONE_ALL);
}

/**
 * on_deadline:
 * @user_data: (not nullable): the Op, owned by the source.
 *
 * GSourceFunc of the deadline timer: the providers that have not answered are timed out.
 *
 * Preconditions:
 *  - @user_data is the Op the source holds a reference to.
 * Postconditions:
 *  - the operation has completed; the source is removed.
 * Thread affinity: main thread only.
 * Ownership: the source keeps its reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_deadline(gpointer user_data)
{
  op_complete(user_data, DONE_DEADLINE);
  return G_SOURCE_REMOVE;
}

/**
 * on_outer_cancelled:
 * @cancellable: (unused): the caller's cancellable.
 * @user_data: (not nullable): the Op, owned by the source.
 *
 * GCancellableSourceFunc: the caller cancelled. It runs in the main context, never inside
 * g_cancellable_cancel(), whatever thread cancelled.
 *
 * Preconditions:
 *  - @user_data is the Op the source holds a reference to.
 * Postconditions:
 *  - the operation has completed with G_IO_ERROR_CANCELLED; the source is removed.
 * Thread affinity: main thread only.
 * Ownership: the source keeps its reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_outer_cancelled(GCancellable *cancellable, gpointer user_data)
{
  (void)cancellable;
  op_complete(user_data, DONE_CANCELLED);
  return G_SOURCE_REMOVE;
}

/**
 * on_child_done:
 * @source: (not nullable): the provider that was called, passed as GObject.
 * @result: (not nullable): the provider's pending result.
 * @user_data: (transfer full): the Child made by start_fetches().
 *
 * GAsyncReadyCallback of one fetch: finishes it and records the answer in its slot, or, when the
 * operation has already completed (deadline, cancellation), only frees what was delivered.
 *
 * Preconditions:
 *  - @source is a WxProvider and @result the result of a fetch this service started on it; the
 *    provider follows the interface (a NULL result comes with an error).
 * Postconditions:
 *  - the fetch is finished exactly once; the slot holds the normalised error or the result with
 *    the list of its usable members (a result without one becomes a WX_ERROR_NOT_FOUND failure,
 *    a NULL result without an error the same); the operation completes when this was the last
 *    outstanding fetch.
 * Thread affinity: main thread only.
 * Ownership: takes and releases the Child and its Op reference; the answer is moved into the slot
 *   or freed.
 */
static void
on_child_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Child *child = user_data;
  Op *op = child->op;
  guint index = child->index;
  g_free(child);

  GError *error = NULL;
  WxSourceResult *answer = wx_provider_fetch_finish(WX_PROVIDER(source), result, &error);
  if (answer != NULL && answer->members != NULL)
    drop_null_members(answer->members);
  if (op->task == NULL) { /* too late: only free */
    wx_source_result_free(answer);
    g_clear_error(&error);
    op_unref(op);
    return;
  }

  Slot *slot = &op->slots[index];
  slot->done = TRUE;
  op->pending--;
  if (error != NULL) {
    wx_source_result_free(answer);
    slot->error = normalize_error(error);
  } else if (answer == NULL) {
    slot->error = g_error_new_literal(WX_ERROR, WX_ERROR_NOT_FOUND,
                                      "the provider returned no result");
  } else {
    GPtrArray *usable = collect_usable(answer);
    if (usable->len > 0) {
      slot->result = answer;
      slot->forward = usable;
    } else {
      g_ptr_array_unref(usable);
      wx_source_result_free(answer);
      slot->error = g_error_new_literal(WX_ERROR, WX_ERROR_NOT_FOUND,
                                        "the provider returned no forecast data");
    }
  }
  op_finish_if_done(op);
  op_unref(op);
}

/**
 * status_for:
 * @provider: (not nullable): a registered provider.
 *
 * Builds the initial (SKIPPED) status of a provider from its id, name, attribution and URL; an
 * attribution URL that wx_source_status_new() rejects is replaced by "".
 *
 * Preconditions:
 *  - @provider satisfies WX_IS_PROVIDER().
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the status; NULL when the provider's id is not a valid
 *   source id.
 */
static WxSourceStatus *
status_for(WxProvider *provider)
{
  const char *id = wx_provider_get_id(provider);
  const char *name = wx_provider_get_name(provider);
  const char *attribution = wx_provider_get_attribution(provider);
  const char *url = wx_provider_get_attribution_url(provider);
  WxSourceStatus *status =
      wx_source_status_new(id, name, attribution, url, WX_SRC_SKIPPED, -1, 0, NULL);
  if (status == NULL)
    status = wx_source_status_new(id, name, attribution, "", WX_SRC_SKIPPED, -1, 0, NULL);
  return status;
}

/**
 * op_add_slots:
 * @op: (not nullable): a new operation without slots.
 * @providers: (not nullable): every registered provider, registration order.
 * @covering: (not nullable): the providers to fetch from.
 *
 * Creates one slot for every provider that can be reported (see status_for()); the slots of the
 * covering providers are marked fetched and hold a strong reference to their provider.
 *
 * Preconditions:
 *  - @providers lists every provider at most once; @covering is a subset of it.
 * Postconditions:
 *  - op->slots has one entry per provider with a valid id, in registration order; op->n_slots is
 *    their number.
 * Thread affinity: main thread only.
 * Ownership: the slots own their status and (while starting) a reference to the provider.
 *
 * Returns: the number of slots that are fetched.
 */
static guint
op_add_slots(Op *op, GPtrArray *providers, GPtrArray *covering)
{
  guint n_fetched = 0;
  op->slots = g_new0(Slot, providers->len);
  for (guint i = 0; i < providers->len; i++) {
    WxProvider *provider = g_ptr_array_index(providers, i);
    WxSourceStatus *status = status_for(provider);
    if (status == NULL)
      continue;
    Slot *slot = &op->slots[op->n_slots++];
    slot->status = status;
    if (g_ptr_array_find(covering, provider, NULL)) {
      slot->fetched = TRUE;
      slot->provider = g_object_ref(provider);
      n_fetched++;
    }
  }
  return n_fetched;
}

/**
 * op_new:
 * @task: (transfer full): the task of the operation.
 * @place: (transfer full): the validated copy of the place.
 *
 * Creates the operation record with one reference (the starter's).
 *
 * Preconditions:
 *  - none beyond valid arguments.
 * Postconditions:
 *  - the record owns @task, @place and a new private cancellable; the deadline is the current
 *    refresh_deadline_ms(); no slot and no source exists yet.
 * Thread affinity: main thread only.
 * Ownership: takes @task and @place; the caller owns the starter's reference.
 *
 * Returns: (transfer full): the new record.
 */
static Op *
op_new(GTask *task, WxPlace *place)
{
  Op *op = g_new0(Op, 1);
  op->ref_count = 1;
  op->task = task;
  op->place = place;
  op->deadline_ms = refresh_deadline_ms();
  op->child_cancellable = g_cancellable_new();
  return op;
}

/**
 * start_fetches:
 * @op: (not nullable): an operation with its slots and sources.
 *
 * Starts a fetch on every fetched slot, one after the other without returning to the main loop,
 * each with the private cancellable. The pending count is raised before the call, so a provider
 * that (against the interface) calls back at once is handled; if the operation completes while
 * the fetches are being started (a provider ran the main loop and the deadline or a cancellation
 * dispatched) the remaining ones are not started.
 *
 * Preconditions:
 *  - the caller holds a reference to @op; no fetch has been started.
 * Postconditions:
 *  - every started fetch calls back once; the operation completes now if none is outstanding;
 *    the slots no longer hold their provider reference.
 * Thread affinity: main thread only.
 * Ownership: each fetch owns a Child with a reference to @op; the caller keeps its own.
 */
static void
start_fetches(Op *op)
{
  op->starting = TRUE;
  for (guint i = 0; i < op->n_slots && op->task != NULL; i++) {
    Slot *slot = &op->slots[i];
    if (!slot->fetched)
      continue;
    Child *child = g_new(Child, 1);
    child->op = op_ref(op);
    child->index = i;
    op->pending++;
    wx_provider_fetch_async(slot->provider, op->place, op->child_cancellable, on_child_done,
                            child);
  }
  op->starting = FALSE;
  for (guint i = 0; i < op->n_slots; i++)
    g_clear_object(&op->slots[i].provider);
  op_finish_if_done(op);
}

/* Documented in wx-service.h. */
void
wx_service_refresh_async(WxService *self, const WxPlace *place, GCancellable *cancellable,
                         GAsyncReadyCallback callback, gpointer user_data)
{
  g_return_if_fail(WX_IS_SERVICE(self));
  g_return_if_fail(place != NULL);
  g_return_if_fail(cancellable == NULL || G_IS_CANCELLABLE(cancellable));

  g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_refresh);
  if (g_task_return_error_if_cancelled(task))
    return;
  WxPlace *copy = wx_place_copy(place);
  if (copy == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid place");
    return;
  }

  /* covering first: a covers() that adds a provider is then included in the full list too */
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(self->registry, copy);
  g_autoptr(GPtrArray) providers = wx_registry_list_providers(self->registry);
  Op *op = op_new(g_steal_pointer(&task), copy);
  if (op_add_slots(op, providers, covering) == 0) {
    g_task_return_new_error(op->task, WX_ERROR, WX_ERROR_UNSUPPORTED,
                            "no enabled data source covers this place");
    op_unref(op);
    return;
  }

  op->deadline_source = g_timeout_source_new(op->deadline_ms);
  g_source_set_callback(op->deadline_source, on_deadline, op_ref(op), op_unref_notify);
  g_source_attach(op->deadline_source, g_task_get_context(op->task));
  if (cancellable != NULL) {
    op->cancel_source = g_cancellable_source_new(cancellable);
    g_source_set_callback(op->cancel_source, G_SOURCE_FUNC(on_outer_cancelled), op_ref(op),
                          op_unref_notify);
    g_source_attach(op->cancel_source, g_task_get_context(op->task));
  }

  start_fetches(op);
  op_unref(op);
}

/* Documented in wx-service.h. */
WxForecast *
wx_service_refresh_finish(WxService *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_SERVICE(self), NULL);
  g_return_val_if_fail(g_task_is_valid(result, self), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_refresh, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}

/* ------------------------------------------------------------------------ */
/* Search                                                                   */
/* ------------------------------------------------------------------------ */

/**
 * copy_valid_hits:
 * @hits: (not nullable): the array a geocoder returned.
 *
 * Copies the valid places of a geocoder's answer, at most WX_GEOCODER_MAX_HITS.
 *
 * Preconditions:
 *  - @hits is a valid GPtrArray whose elements are NULL or places.
 * Postconditions:
 *  - @hits is not modified.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the new array; @hits stays with the caller.
 *
 * Returns: (transfer full) (element-type WxPlace): the copies of the leading elements that are
 *   non-NULL and pass wx_place_copy(), in order; free function wx_place_free().
 */
static GPtrArray *
copy_valid_hits(const GPtrArray *hits)
{
  GPtrArray *out = g_ptr_array_new_with_free_func((GDestroyNotify)wx_place_free);
  for (guint i = 0; i < hits->len && out->len < WX_GEOCODER_MAX_HITS; i++) {
    const WxPlace *hit = g_ptr_array_index(hits, i);
    WxPlace *copy = hit != NULL ? wx_place_copy(hit) : NULL;
    if (copy != NULL)
      g_ptr_array_add(out, copy);
  }
  return out;
}

/**
 * on_search_done:
 * @source: (not nullable): the geocoder that was called, passed as GObject.
 * @result: (not nullable): the geocoder's pending result.
 * @user_data: (transfer full): the service's GTask of the search.
 *
 * GAsyncReadyCallback of the inner search: moves its outcome into the service's task (places
 * re-validated and capped, errors normalised).
 *
 * Preconditions:
 *  - @source is a WxGeocoder and @result the result of the search started on it.
 * Postconditions:
 *  - the task is completed exactly once.
 * Thread affinity: main thread only.
 * Ownership: takes the task reference in @user_data; the answer is moved into the task or freed.
 */
static void
on_search_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  GError *error = NULL;
  GPtrArray *hits = wx_geocoder_search_finish(WX_GEOCODER(source), result, &error);
  if (error != NULL) {
    g_clear_pointer(&hits, g_ptr_array_unref);
    g_task_return_error(task, normalize_error(error));
  } else if (hits == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_NOT_FOUND,
                            "the geocoder returned no result");
  } else {
    g_task_return_pointer(task, copy_valid_hits(hits), (GDestroyNotify)g_ptr_array_unref);
    g_ptr_array_unref(hits);
  }
}

/* Documented in wx-service.h. */
void
wx_service_search_async(WxService *self, const char *text, GCancellable *cancellable,
                        GAsyncReadyCallback callback, gpointer user_data)
{
  g_return_if_fail(WX_IS_SERVICE(self));
  g_return_if_fail(text != NULL);
  g_return_if_fail(cancellable == NULL || G_IS_CANCELLABLE(cancellable));

  g_autoptr(GTask) task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_search);
  if (g_task_return_error_if_cancelled(task))
    return;
  WxGeocoder *registered = wx_registry_get_geocoder(self->registry);
  if (registered == NULL) {
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_UNSUPPORTED, "no geocoder is registered");
    return;
  }
  /* the registry's pointer is borrowed: the geocoder could replace itself while it runs */
  g_autoptr(WxGeocoder) geocoder = g_object_ref(registered);
  wx_geocoder_search_async(geocoder, text, cancellable, on_search_done, g_steal_pointer(&task));
}

/* Documented in wx-service.h. */
GPtrArray *
wx_service_search_finish(WxService *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_SERVICE(self), NULL);
  g_return_val_if_fail(g_task_is_valid(result, self), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_search, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}
