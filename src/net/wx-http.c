/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-http.c - WxHttp: the hardened, host-pinned HTTP GET engine. See wx-http.h
 * for the contract.
 *
 * Layout: header/URL validation, the WxHttp object, then the request layer:
 * one GTask per operation, one shared FIFO queue that paces the attempts
 * (WxHttp.min_gap_ms), one libsoup message per attempt, a per-attempt
 * deadline, a whole-operation deadline and a back-off wait between attempts.
 * This is the only file of the program that uses libsoup.
 */
#include "wx-http.h"

#include <libsoup/soup.h>
#include <string.h>

/* Upper bound of the numeric arguments of wx_http_new_custom(), milliseconds. */
#define WX_HTTP_TIME_ARG_MAX_MS 600000
/* Longest accepted host name (RFC 1035), bytes. */
#define HOST_MAX_BYTES 253
/* An Expires value more than this far in the future is implausible, seconds. */
#define EXPIRES_MAX_AHEAD_S 86400
/* libsoup has no constant for 429. */
#define HTTP_TOO_MANY_REQUESTS 429

/* Size arithmetic of the request layer: the body buffer is sized with guint
 * (GByteArray), so cap + 1 must fit; schedule_retry() shifts the back-off base
 * left by at most WX_HTTP_MAX_RETRIES - 1 and casts the result to guint. */
G_STATIC_ASSERT((guint64)WX_HTTP_MAX_BODY_BYTES + 1 <= G_MAXUINT);
G_STATIC_ASSERT(((guint64)WX_HTTP_TIME_ARG_MAX_MS << WX_HTTP_MAX_RETRIES) <= G_MAXUINT);
G_STATIC_ASSERT(WX_HTTP_READ_CHUNK > 0 && WX_HTTP_MAX_RETRIES >= 1);

/* ------------------------------------------------------------------------ */
/* Response                                                                 */
/* ------------------------------------------------------------------------ */

/* Documented in wx-http.h. */
void
wx_http_response_free(WxHttpResponse *response)
{
  if (response == NULL)
    return;
  g_bytes_unref(response->body);
  g_free(response->last_modified);
  g_free(response);
}

/* ------------------------------------------------------------------------ */
/* Validation                                                               */
/* ------------------------------------------------------------------------ */

/**
 * text_is_printable_ascii:
 * @text: (nullable): candidate header value.
 * @max: longest accepted length in bytes (without the NUL).
 *
 * Checks a header value for its length and for printable ASCII.
 *
 * Preconditions:
 *  - @text is NULL or NUL-terminated (or has @max + 1 readable bytes).
 * Postconditions:
 *  - nothing is modified; at most @max + 1 bytes are read (a bounded search
 *    for the terminator comes first).
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @text is 1..@max bytes, every one in 0x20..0x7E.
 */
static gboolean
text_is_printable_ascii(const char *text, gsize max)
{
  if (text == NULL)
    return FALSE;
  const char *nul = memchr(text, '\0', max + 1);
  if (nul == NULL || nul == text)
    return FALSE;
  for (const char *p = text; p < nul; p++)
    if ((guchar)*p < 0x20 || (guchar)*p > 0x7E)
      return FALSE;
  return TRUE;
}

/* Documented in wx-http.h. */
gboolean
wx_http_path_is_valid(const char *path_and_query)
{
  if (path_and_query == NULL)
    return FALSE;
  const char *nul = memchr(path_and_query, '\0', WX_HTTP_PATH_MAX + 1);
  if (nul == NULL || nul == path_and_query || path_and_query[0] != '/' ||
      (nul - path_and_query > 1 && path_and_query[1] == '/'))
    return FALSE;
  for (const char *p = path_and_query; p < nul; p++)
    if ((guchar)*p <= 0x20 || (guchar)*p >= 0x7F || *p == '#' || *p == '\\')
      return FALSE;
  return TRUE;
}

/* Documented in wx-http.h. */
gint64
wx_http_parse_expires(const char *value, gint64 now_s)
{
  if (value == NULL || memchr(value, '\0', WX_HTTP_VALIDATOR_MAX + 1) == NULL)
    return 0;
  g_autoptr(GDateTime) when = soup_date_time_new_from_http_string(value);
  if (when == NULL)
    return 0;
  gint64 t = g_date_time_to_unix(when);
  /* t > now_s, so the unsigned difference is exact whatever now_s is. */
  if (t <= now_s || (guint64)t - (guint64)now_s > EXPIRES_MAX_AHEAD_S)
    return 0;
  return t;
}

/**
 * host_is_acceptable:
 * @host: non-NULL host as GUri reports it (decoded, IDN already in punycode).
 *
 * Checks the host part of a base URL.
 *
 * Preconditions:
 *  - @host is NUL-terminated.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @host is 1..HOST_MAX_BYTES bytes and either a DNS name /
 *   IPv4 address (dot-separated labels of 1..63 ASCII letters, digits and '-',
 *   none starting or ending with '-', no trailing dot) or an IPv6 literal
 *   (contains ':') made of hex digits, ':' and '.'. Anything else (spaces, '/',
 *   '%', '@', ...) could change the meaning of the URL it is rebuilt into.
 */
static gboolean
host_is_acceptable(const char *host)
{
  gsize len = strlen(host);
  if (len == 0 || len > HOST_MAX_BYTES)
    return FALSE;
  if (strchr(host, ':') != NULL) {
    for (const char *p = host; *p != '\0'; p++)
      if (!(g_ascii_isxdigit(*p) || *p == '.' || *p == ':'))
        return FALSE;
    return TRUE;
  }
  gsize label_len = 0;
  for (const char *p = host; *p != '\0'; p++) {
    if (*p == '.') {
      if (label_len == 0 || p[-1] == '-')
        return FALSE;
      label_len = 0;
      continue;
    }
    if (!(g_ascii_isalnum(*p) || *p == '-') || (*p == '-' && label_len == 0) || ++label_len > 63)
      return FALSE;
  }
  return label_len > 0 && host[len - 1] != '-';
}

/**
 * normalise_base_url:
 * @base_url: non-NULL, NUL-terminated URL text.
 *
 * Checks an origin as described for wx_http_new_custom() and rebuilds it from
 * the parsed, validated components, so the stored string is exactly what was
 * checked.
 *
 * Preconditions:
 *  - @base_url is non-NULL and NUL-terminated.
 * Postconditions:
 *  - @base_url is unchanged.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full) (nullable): "scheme://host[:port]" (lower-case, an
 *   IPv6 host in brackets), or NULL if the origin is not acceptable.
 */
static char *
normalise_base_url(const char *base_url)
{
  g_autoptr(GUri) uri = g_uri_parse(base_url, G_URI_FLAGS_NONE, NULL);
  if (uri == NULL)
    return NULL;
  const char *host = g_uri_get_host(uri);
  const char *path = g_uri_get_path(uri);
  gint port = g_uri_get_port(uri);
  if (host == NULL || !host_is_acceptable(host) || g_uri_get_userinfo(uri) != NULL ||
      g_uri_get_query(uri) != NULL || g_uri_get_fragment(uri) != NULL ||
      !(path[0] == '\0' || g_str_equal(path, "/")) || port == 0)
    return NULL;
  g_autofree char *lower_host = g_ascii_strdown(host, -1);
  gboolean loopback = g_str_equal(lower_host, "127.0.0.1") || g_str_equal(lower_host, "::1") ||
                      g_str_equal(lower_host, "localhost");
  const char *scheme = g_uri_get_scheme(uri);
  if (!(g_ascii_strcasecmp(scheme, "https") == 0 ||
        (g_ascii_strcasecmp(scheme, "http") == 0 && loopback)))
    return NULL;
  g_autofree char *lower_scheme = g_ascii_strdown(scheme, -1);
  gboolean ipv6 = strchr(lower_host, ':') != NULL;
  g_autofree char *port_text = port > 0 ? g_strdup_printf(":%d", port) : g_strdup("");
  return g_strdup_printf("%s://%s%s%s%s", lower_scheme, ipv6 ? "[" : "", lower_host,
                         ipv6 ? "]" : "", port_text);
}

/* ------------------------------------------------------------------------ */
/* WxHttp object                                                            */
/* ------------------------------------------------------------------------ */

/*
 * Instance data; main thread only. session and base_url are owned by the
 * instance (released in finalize); inflight counts the live Ops,
 * each of which holds a strong reference to the instance, so the instance is
 * never finalised while inflight > 0.
 */
struct _WxHttp {
  GObject parent_instance;
  SoupSession *session; /* created once by the constructor, shared by every request */
  char *base_url;       /* validated origin "scheme://host[:port]" */
  guint timeout_ms;
  guint backoff_base_ms;
  guint min_gap_ms;
  guint inflight; /* live Ops, see WX_HTTP_MAX_INFLIGHT */

  /* Pacing. queue holds the GTasks (one reference each) waiting for their
   * next attempt; on_wire counts the attempts between start and end;
   * next_start_us is the earliest g_get_monotonic_time() at which the next
   * attempt may start; pump_timer wakes pump() when that time is reached
   * (NULL unless the queue head is waiting for it). */
  GQueue queue;
  guint on_wire;
  gint64 next_start_us;
  GSource *pump_timer;
};

G_DEFINE_TYPE(WxHttp, wx_http, G_TYPE_OBJECT)

/**
 * wx_http_init:
 * @self: (not nullable): the new instance.
 *
 * GObject instance initialiser: empty queue, nothing on the wire. The
 * session and the base URL are set by wx_http_new_custom(); an instance made
 * with a plain g_object_new() has none and is refused by wx_http_get_async().
 *
 * Preconditions:
 *  - @self is a zero-initialised WxHttp being constructed by GObject.
 * Postconditions:
 *  - the queue is initialised and empty, inflight is 0, no timer is armed.
 * Thread affinity: main thread only.
 * Ownership: @self owns everything it will later hold.
 */
static void
wx_http_init(WxHttp *self)
{
  g_queue_init(&self->queue);
}

/**
 * source_clear:
 * @source: (inout) (nullable): location of an owned GSource reference.
 *
 * Destroys the source (removing it from its context) and drops the owned
 * reference, which also drops the task reference held by its callback data.
 *
 * Preconditions:
 *  - @source points to a NULL pointer or to a source reference owned by the
 *    caller (possibly already destroyed, possibly the source being
 *    dispatched).
 * Postconditions:
 *  - *@source is NULL.
 * Thread affinity: main thread only.
 * Ownership: the reference in *@source is released.
 */
static void
source_clear(GSource **source)
{
  if (*source != NULL) {
    g_source_destroy(*source);
    g_clear_pointer(source, g_source_unref);
  }
}

/**
 * wx_http_finalize:
 * @object: (not nullable): the WxHttp being finalized.
 *
 * GObject finalize: drops the HTTP session and frees the base URL copy.
 * Operations hold a reference to the instance (Op.owner), so none is
 * outstanding here and the queue is empty.
 *
 * Preconditions:
 *  - @object is a WxHttp whose last reference is gone (runs once).
 * Postconditions:
 *  - the pacing timer, whose callback data is the instance without a
 *    reference, is destroyed (it can never fire on a finalised instance), the
 *    session is released, base_url is freed and the parent finalize has run.
 * Thread affinity: main thread only.
 * Ownership: the instance owns the timer, the session and base_url; they are
 *   released here.
 */
static void
wx_http_finalize(GObject *object)
{
  WxHttp *self = WX_HTTP(object);
  source_clear(&self->pump_timer);
  g_clear_object(&self->session);
  g_free(self->base_url);
  G_OBJECT_CLASS(wx_http_parent_class)->finalize(object);
}

/**
 * wx_http_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs finalize. There is deliberately no
 * dispose override: the instance holds no reference cycle, so everything it
 * owns (the session included) lives until finalize and the public functions
 * stay usable after g_object_run_dispose().
 *
 * Preconditions:
 *  - called once by the GType system.
 * Postconditions:
 *  - finalize is overridden; no properties or signals exist.
 * Thread affinity: any thread (called by GObject under its type lock).
 * Ownership: @klass is owned by the type system and not retained.
 */
static void
wx_http_class_init(WxHttpClass *klass)
{
  G_OBJECT_CLASS(klass)->finalize = wx_http_finalize;
}

/* Documented in wx-http.h. */
WxHttp *
wx_http_new(const char *base_url, const char *user_agent, GError **error)
{
  return wx_http_new_custom(base_url, user_agent, WX_HTTP_TIMEOUT_MS, WX_HTTP_BACKOFF_BASE_MS, 0,
                            error);
}

/* Documented in wx-http.h. */
WxHttp *
wx_http_new_custom(const char *base_url, const char *user_agent, guint timeout_ms,
                   guint backoff_base_ms, guint min_gap_ms, GError **error)
{
  g_return_val_if_fail(base_url != NULL, NULL);
  g_return_val_if_fail(user_agent != NULL, NULL);
  g_return_val_if_fail(timeout_ms >= 1 && timeout_ms <= WX_HTTP_TIME_ARG_MAX_MS, NULL);
  g_return_val_if_fail(backoff_base_ms <= WX_HTTP_TIME_ARG_MAX_MS, NULL);
  g_return_val_if_fail(min_gap_ms <= WX_HTTP_TIME_ARG_MAX_MS, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);

  if (!text_is_printable_ascii(user_agent, WX_HTTP_HEADER_VALUE_MAX)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid User-Agent");
    return NULL;
  }
  char *origin = normalise_base_url(base_url);
  if (origin == NULL) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "unacceptable base URL");
    return NULL;
  }
  WxHttp *self = g_object_new(WX_TYPE_HTTP, NULL);
  /* No cookie jar and no HTTP cache feature are added: nothing is persisted;
   * no "authenticate" handler is connected, so credentials are never sent. */
  self->session = g_object_new(SOUP_TYPE_SESSION, "user-agent", user_agent, NULL);
  self->base_url = origin;
  self->timeout_ms = timeout_ms;
  self->backoff_base_ms = backoff_base_ms;
  self->min_gap_ms = min_gap_ms;
  return self;
}

/* ------------------------------------------------------------------------ */
/* Request layer                                                            */
/* ------------------------------------------------------------------------ */

/* Where an operation is: waiting in the queue, on the wire, or in back-off. */
typedef enum { OP_QUEUED, OP_ATTEMPT, OP_BACKOFF } OpState;

/*
 * Task data of one operation: the request and the state of its current
 * attempt. Created by op_new(), owned by the GTask (task data, freed by
 * op_free() when the task is finalised) and used from the main thread only.
 *
 * Ownership of the members: uri, accept, if_modified_since, user_cancellable
 * (a strong reference) and owner (a strong reference; the Op counts in
 * owner->inflight from op_new() to op_free()) are owned by the Op. total_deadline
 * is owned from op_start() until the operation completes; queue_watch while
 * the task is queued; the per-attempt members between attempt_start() and
 * attempt_cleanup(); the back-off sources between schedule_retry() and
 * backoff_cleanup().
 *
 * Lifetime: every GSource and GAsyncReadyCallback of an operation holds its
 * own reference to the GTask as callback data (released when the callback has
 * run or the source is finalised; the user-cancel handler holds the attempt
 * cancellable instead) and the queue holds one reference per queued task, so
 * the task, and with it the Op, outlives every pending callback. That cycle
 * (task -> Op -> source -> task) is broken by op_release(), which every path
 * that completes the task runs first, and by attempt_cleanup() /
 * backoff_cleanup() on the paths that end an attempt or a wait without
 * completing it.
 */
typedef struct {
  GUri *uri;                      /* validated request URI, parsed once */
  char *accept;
  char *if_modified_since;        /* nullable */
  GCancellable *user_cancellable; /* the caller's (nullable), strong ref */
  WxHttp *owner;                  /* strong ref; this Op counts in owner->inflight */

  OpState state;
  guint attempt;           /* number of retries started so far; 0 for the first attempt */
  gboolean total_expired;  /* the whole-operation deadline has passed */
  GSource *total_deadline; /* owned reference; its callback data is a task reference */
  GSource *queue_watch;    /* while queued: wakes the task when the caller cancels */

  /* Per-attempt state, released by attempt_cleanup(). */
  guint http_status; /* HTTP status of the current attempt, 0 until known */
  SoupMessage *msg;
  GCancellable *attempt_cancel; /* cancelled by the deadlines or by the user; the user_cancellable
                                 * handler holds a second reference as its data */
  gulong user_cancel_id;        /* handler on user_cancellable, 0 if none */
  GSource *deadline;            /* per-attempt deadline; callback data is a task reference */
  gboolean timed_out;           /* the per-attempt deadline fired */
  gboolean on_wire;             /* counted in owner->on_wire */
  GInputStream *stream; /* the raw response stream (closed by attempt_cleanup()) */
  GConverter *decoder;     /* gzip decoder of the current attempt, NULL for the identity coding */
  guint8 *raw;             /* encoded bytes of the last read (gzip only), WX_HTTP_READ_CHUNK long */
  gsize raw_received;      /* encoded body bytes received so far */
  gboolean decoder_finished; /* the gzip stream has been read up to its end marker */
  GByteArray *body;  /* owned until moved into the response */
  gsize body_filled; /* bytes of body->data already read; <= WX_HTTP_MAX_BODY_BYTES + 1 */
  gboolean has_declared;     /* the response is length-delimited (SOUP_ENCODING_CONTENT_LENGTH) */
  gboolean length_unknown;   /* content-carrying response without a Content-Length (close-delimited or chunked) */
  gsize declared;            /* its Content-Length (ENCODED bytes, <= the cap); meaningful only with has_declared */
  const char *framing_error; /* static text: the response headers' framing was rejected (PARSE), else NULL */
  gint64 expires_s;  /* parsed Expires of the current response, 0 if none */
  char *last_modified; /* validated Last-Modified of the current response, or NULL */

  /* Back-off wait state, released by backoff_cleanup(). */
  GSource *backoff_timer;  /* owned reference; its callback data is a task reference */
  GSource *backoff_cancel; /* owned reference (nullable); callback data is a task reference */
} Op;

/* Source tag of the tasks created by wx_http_get_async(). */
static char tag_get;

/* Forward declaration; documented at the definition below. */
static void pump(WxHttp *self);

/**
 * attempt_cleanup:
 * @op: (not nullable): the operation.
 *
 * Releases the per-attempt state of @op: the deadline source, the
 * user-cancellation handler, the attempt cancellable, the stream (closed
 * asynchronously, which hands the connection back to the pool), the message
 * (after disconnecting the status-code handler that points at @op), the
 * partial body and the parsed headers, and gives the wire slot back.
 *
 * Preconditions:
 *  - @op is live (owned by its GTask). It may be called with no attempt
 *    running (everything NULL/0) and more than once.
 *  - It is not called from inside on_user_cancelled() (g_cancellable_disconnect()
 *    would wait for that handler): its callers are fail_attempt(), on_read(),
 *    on_sent() and op_free(), reached from I/O callbacks and from task
 *    finalisation. This relies on a cancelled read/send being completed from
 *    the main loop and not from inside g_cancellable_cancel().
 * Postconditions:
 *  - deadline, user_cancel_id, attempt_cancel, stream, msg, body and
 *    last_modified are NULL/0, body_filled and expires_s are 0 and, if the
 *    attempt was on the wire, owner->on_wire was decremented. Dropping the
 *    deadline source also drops the task reference held by its callback data,
 *    and disconnecting the handler drops the attempt_cancel reference held
 *    by it. The caller is responsible for calling pump().
 * Thread affinity: main thread only (the thread running the GLib main context).
 * Ownership: @op stays with its task; every per-attempt resource is released.
 */
static void
attempt_cleanup(Op *op)
{
  source_clear(&op->deadline);
  if (op->user_cancel_id != 0) {
    g_cancellable_disconnect(op->user_cancellable, op->user_cancel_id);
    op->user_cancel_id = 0;
  }
  g_clear_object(&op->attempt_cancel);
  g_clear_object(&op->decoder);
  g_clear_pointer(&op->raw, g_free);
  op->raw_received = 0;
  op->decoder_finished = FALSE;
  if (op->stream != NULL) {
    /* Closing hands the connection back to the pool; nothing waits for it. */
    g_input_stream_close_async(op->stream, G_PRIORITY_DEFAULT, NULL, NULL, NULL);
    g_clear_object(&op->stream);
  }
  if (op->msg != NULL)
    g_signal_handlers_disconnect_by_data(op->msg, op);
  g_clear_object(&op->msg);
  g_clear_pointer(&op->body, g_byte_array_unref);
  g_clear_pointer(&op->last_modified, g_free);
  op->body_filled = 0;
  op->expires_s = 0;
  op->has_declared = FALSE;
  op->declared = 0;
  op->length_unknown = FALSE;
  op->framing_error = NULL;
  if (op->on_wire) {
    op->on_wire = FALSE;
    op->owner->on_wire--;
  }
}

/**
 * backoff_cleanup:
 * @op: (not nullable): the operation.
 *
 * Cancels and releases the back-off wait of @op (the timer and the
 * cancellation watch). Dropping each source also drops the task reference
 * held by its callback data.
 *
 * Preconditions:
 *  - @op is live (owned by its GTask); may be called with no wait pending and
 *    more than once.
 * Postconditions:
 *  - backoff_timer and backoff_cancel are NULL and their sources destroyed.
 * Thread affinity: main thread only.
 * Ownership: @op stays with its task; the two source references are released.
 */
static void
backoff_cleanup(Op *op)
{
  source_clear(&op->backoff_timer);
  source_clear(&op->backoff_cancel);
}

/**
 * op_release:
 * @op: (not nullable): the operation.
 *
 * Ends everything that keeps the task alive: the whole-operation deadline,
 * the queue watch, the back-off wait and the attempt. Run before the task is
 * completed.
 *
 * Preconditions:
 *  - @op is live; the task is not in owner->queue (callers remove it first;
 *    op_release() does not touch the queue). The caller is responsible for
 *    calling pump() afterwards.
 * Postconditions:
 *  - total_deadline, queue_watch and every back-off/attempt member are
 *    released.
 * Thread affinity: main thread only.
 * Ownership: @op stays with its task.
 */
static void
op_release(Op *op)
{
  source_clear(&op->total_deadline);
  source_clear(&op->queue_watch);
  backoff_cleanup(op);
  attempt_cleanup(op);
}

/**
 * op_free:
 * @data: (not nullable): the Op created by op_new().
 *
 * GDestroyNotify of the task data: releases an Op and everything it owns,
 * then drops the in-flight count and the owner reference.
 *
 * Preconditions:
 *  - @data is the Op installed with g_task_set_task_data(); called exactly
 *    once, when the GTask is finalised (so no source or callback can still
 *    reference the task: each holds a task reference that op_release() or
 *    the callback released first). owner->inflight is > 0.
 * Postconditions:
 *  - all members are released; owner->inflight is decremented once and the
 *    owner reference taken in op_new() is dropped (which may finalise the
 *    WxHttp). @data is invalid afterwards.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @data and of every member of the Op.
 */
static void
op_free(gpointer data)
{
  Op *op = data;
  op_release(op);
  g_clear_object(&op->user_cancellable);
  op->owner->inflight--;
  g_object_unref(op->owner);
  g_uri_unref(op->uri);
  g_free(op->accept);
  g_free(op->if_modified_since);
  g_free(op);
}

/**
 * op_return_error:
 * @task: (not nullable): the operation's task; the caller holds a reference.
 * @error: (transfer full): the failure.
 *
 * Completes @task with @error after releasing every timer and watch.
 *
 * Preconditions:
 *  - @task has an Op as task data, has not been returned yet and is not in
 *    the queue; @error is non-NULL.
 * Postconditions:
 *  - the Op's sources and attempt are released and @task is completed
 *    (its callback may run before this returns). The caller runs pump().
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @error; @task stays with the caller.
 */
static void
op_return_error(GTask *task, GError *error)
{
  op_release(g_task_get_task_data(task));
  g_task_return_error(task, error);
}

/**
 * op_return_cancelled:
 * @task: (not nullable): the operation's task; the caller holds a reference.
 *
 * Completes @task with G_IO_ERROR_CANCELLED (see op_return_error()).
 *
 * Preconditions:
 *  - as for op_return_error().
 * Postconditions:
 *  - as for op_return_error().
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller.
 */
static void
op_return_cancelled(GTask *task)
{
  op_return_error(task, g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED,
                                            "operation was cancelled"));
}

/**
 * http_status_error:
 * @status: HTTP status code of a response that is not a success.
 *
 * Maps an HTTP status to the error reported to the caller: 429 is
 * WX_ERROR_RATE_LIMITED, 404 is WX_ERROR_NOT_FOUND, everything else
 * WX_ERROR_HTTP. The message formats are fixed; only the numeric status and
 * libsoup's own phrase (never server text) are embedded.
 *
 * Preconditions:
 *  - none (any value is accepted).
 * Postconditions:
 *  - a new GError is returned; nothing else changes.
 * Thread affinity: any thread (pure).
 * Ownership: the returned error is owned by the caller.
 *
 * Returns: (transfer full): the error.
 */
static GError *
http_status_error(guint status)
{
  if (status == HTTP_TOO_MANY_REQUESTS)
    return g_error_new(WX_ERROR, WX_ERROR_RATE_LIMITED, "HTTP %u: rate limited", status);
  if (status == SOUP_STATUS_NOT_FOUND)
    return g_error_new(WX_ERROR, WX_ERROR_NOT_FOUND, "HTTP %u: not found", status);
  return g_error_new(WX_ERROR, WX_ERROR_HTTP, "HTTP %u %s", status, soup_status_get_phrase(status));
}

/**
 * normalize_error:
 * @op: (not nullable): the operation.
 * @err: (transfer full): the failure of the current attempt.
 *
 * Turns a libsoup/GIO failure into the error the caller sees: cancellation of
 * the user's cancellable wins; WX_ERROR errors pass through; then an expired
 * whole-operation deadline and an expired per-attempt deadline become
 * WX_ERROR_TIMEOUT; anything else, a transport failure whatever its cause, is
 * WX_ERROR_NETWORK ("network error: %s" with the library's own message).
 *
 * Preconditions:
 *  - @op is live; @err is non-NULL and owned by the caller, who must not use
 *    it afterwards.
 * Postconditions:
 *  - @err is either returned (WX_ERROR domain) or freed; the result is never
 *    NULL.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @err; the returned error is owned by the
 *   caller.
 *
 * Returns: (transfer full): the normalised error.
 */
static GError *
normalize_error(Op *op, GError *err)
{
  if (op->user_cancellable != NULL && g_cancellable_is_cancelled(op->user_cancellable)) {
    g_error_free(err);
    return g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "operation was cancelled");
  }
  if (err->domain == WX_ERROR)
    return err;
  GError *out;
  if (op->total_expired)
    out = g_error_new_literal(WX_ERROR, WX_ERROR_TIMEOUT, "operation deadline exceeded");
  else if (op->timed_out)
    out = g_error_new_literal(WX_ERROR, WX_ERROR_TIMEOUT, "request timed out");
  else
    out = g_error_new(WX_ERROR, WX_ERROR_NETWORK, "network error: %s", err->message);
  g_error_free(err);
  return out;
}

/* Forward declaration; documented at the definition below. */
static void schedule_retry(GTask *task);

/**
 * on_user_cancelled:
 * @user: (unused): the caller's cancellable.
 * @attempt_cancel: (not nullable): the attempt's GCancellable (passed as gpointer).
 *
 * "cancelled" handler of the caller's GCancellable: cancels the current
 * attempt. It may run in whatever thread cancels the caller's cancellable
 * (g_cancellable_cancel() is thread-safe).
 *
 * Preconditions:
 *  - @attempt_cancel is the reference taken in attempt_start() and owned by
 *    the connection; the handler is disconnected by attempt_cleanup() before
 *    the attempt's own reference is dropped, and the connection's reference
 *    keeps the object alive until the notify runs.
 * Postconditions:
 *  - the attempt cancellable is cancelled; the pending I/O callback then
 *    reports the cancellation.
 * Thread affinity: any thread (the one that cancels the caller's
 *   cancellable); it only calls g_cancellable_cancel(), which is thread-safe.
 * Ownership: @attempt_cancel stays owned by the connection; @user is not
 *   retained.
 */
static void
on_user_cancelled(GCancellable *user, gpointer attempt_cancel)
{
  (void)user;
  g_cancellable_cancel(G_CANCELLABLE(attempt_cancel));
}

/**
 * fail_attempt:
 * @task: (not nullable): the operation's task.
 * @err: (transfer full): the failure of the attempt.
 *
 * Ends the current attempt with @err: schedules a retry when the failure
 * class allows it (network, per-attempt timeout, HTTP 5xx, fewer than
 * WX_HTTP_MAX_RETRIES retries so far, whole-operation deadline not passed),
 * otherwise completes @task with the normalised error. Finally lets the
 * queue move on.
 *
 * Preconditions:
 *  - @task has an Op as task data in state OP_ATTEMPT and the caller holds a
 *    reference to @task for the duration of the call (so the Op stays valid
 *    even if the task completes synchronously); @err is non-NULL.
 * Postconditions:
 *  - the attempt state is released; either schedule_retry() has queued the
 *    next attempt or @task has been completed with the normalised error;
 *    pump() has run.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @err; @task stays with the caller.
 */
static void
fail_attempt(GTask *task, GError *err)
{
  Op *op = g_task_get_task_data(task);
  WxHttp *self = op->owner;
  GError *final = normalize_error(op, err);
  gboolean retryable = !op->total_expired &&
                       (g_error_matches(final, WX_ERROR, WX_ERROR_NETWORK) ||
                        g_error_matches(final, WX_ERROR, WX_ERROR_TIMEOUT) ||
                        (g_error_matches(final, WX_ERROR, WX_ERROR_HTTP) &&
                         op->http_status >= 500 && op->http_status <= 599));
  attempt_cleanup(op);
  if (retryable && op->attempt < WX_HTTP_MAX_RETRIES) {
    g_error_free(final);
    schedule_retry(task);
  } else {
    op_return_error(task, final);
  }
  pump(self);
}

/**
 * on_deadline:
 * @user_data: (not nullable): the operation's GTask (passed as gpointer).
 *
 * GSource callback of the per-attempt deadline: marks the attempt as timed out
 * and cancels its I/O (the pending I/O callback reports the failure).
 *
 * Preconditions:
 *  - @user_data is the task reference held by the source's callback data, so
 *    the task and its Op are alive. attempt_cancel is non-NULL while the
 *    source is attached, because attempt_cleanup() destroys the source before
 *    it clears attempt_cancel.
 * Postconditions:
 *  - op->timed_out is TRUE and the attempt cancellable is cancelled; the
 *    source is removed (and releases its task reference).
 * Thread affinity: main thread only.
 * Ownership: @user_data stays owned by the source.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_deadline(gpointer user_data)
{
  Op *op = g_task_get_task_data(G_TASK(user_data));
  op->timed_out = TRUE;
  g_cancellable_cancel(op->attempt_cancel); /* the pending I/O callback reports it */
  return G_SOURCE_REMOVE;
}

/* Forward declaration; documented at the definition below. */
static void read_next(GTask *task);

/**
 * response_new:
 * @op: (not nullable): the operation, with the headers of the response parsed.
 * @status: HTTP status of the response.
 * @body: (transfer full): the body.
 *
 * Builds the response of the current attempt.
 *
 * Preconditions:
 *  - @op's expires_s and last_modified describe the response being returned.
 * Postconditions:
 *  - last_modified was moved out of @op (the Op no longer owns it).
 * Thread affinity: main thread only.
 * Ownership: takes @body; the caller owns the result.
 *
 * Returns: (transfer full): the new response.
 */
static WxHttpResponse *
response_new(Op *op, guint status, GBytes *body)
{
  WxHttpResponse *response = g_new0(WxHttpResponse, 1);
  response->status = status;
  response->body = body;
  response->expires_s = op->expires_s;
  response->last_modified = g_steal_pointer(&op->last_modified);
  return response;
}

/**
 * op_return_response:
 * @task: (not nullable): the operation's task; the caller holds a reference.
 * @response: (transfer full): the response.
 *
 * Completes @task successfully after releasing the attempt and every timer,
 * then lets the queue move on.
 *
 * Preconditions:
 *  - @task has an Op as task data, not yet returned and not queued.
 * Postconditions:
 *  - @task is completed (its callback may run before this returns); pump()
 *    has run.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @response; @task stays with the caller.
 */
static void
op_return_response(GTask *task, WxHttpResponse *response)
{
  Op *op = g_task_get_task_data(task);
  WxHttp *self = op->owner;
  op_release(op);
  g_task_return_pointer(task, response, (GDestroyNotify)wx_http_response_free);
  pump(self);
}

/**
 * inflate_chunk:
 * @op: (not nullable): the operation, with decoder and body set up.
 * @in: the encoded bytes to feed (@in_len of them).
 * @in_len: number of encoded bytes, at least 1.
 * @error: (nullable): return location for a #GError.
 *
 * Feeds encoded bytes to the gzip decoder and appends the decoded bytes to
 * the body, at most WX_HTTP_READ_CHUNK of them per decoder call and never more
 * than WX_HTTP_MAX_BODY_BYTES + 1 in total, so a decompression bomb is
 * detected after cap + 1 decoded bytes without being buffered. The decoder may
 * hold decoded bytes back until there is output room, so once all input is
 * consumed it is called again with G_CONVERTER_FLUSH until it reports that
 * nothing is pending. Every call makes progress (zlib never returns without
 * consuming input or producing output while input and output room are
 * available, and a FLUSH call without pending output reports
 * G_CONVERTER_FLUSHED), so the loop ends.
 *
 * Preconditions:
 *  - op->decoder is the gzip decompressor of the current attempt and
 *    op->body_filled <= WX_HTTP_MAX_BODY_BYTES on entry; @in is non-NULL and
 *    readable for @in_len bytes.
 * Postconditions:
 *  - on TRUE every byte was accepted, the decoded bytes so far are in the body
 *    (body_filled <= cap) and op->decoder_finished says whether the gzip
 *    stream has reached its end marker. On FALSE *@error is WX_ERROR_PARSE
 *    (decoded size above the cap, or data after the end of the gzip stream: a
 *    second member or garbage) or a GIO error (the data is corrupt or fails
 *    its CRC); the caller fails the attempt with it.
 * Thread affinity: main thread only.
 * Ownership: @in stays with the caller.
 *
 * Returns: TRUE if every byte was accepted.
 */
static gboolean
inflate_chunk(Op *op, const guint8 *in, gsize in_len, GError **error)
{
  /* Bytes that arrive after the gzip stream ended (in a LATER read, after any idle gap) are not
   * part of the content: refuse them here, before the finished decoder is asked to convert them.
   * How a finished converter answers is up to GLib (the version this was written against reports
   * "finished, nothing consumed"; another may report G_IO_ERROR_CLOSED, which would be mistaken
   * for a retryable transport failure), so the outcome must not depend on it. */
  if (op->decoder_finished) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "compressed body continues after its end marker");
    return FALSE;
  }
  gsize off = 0;
  for (;;) {
    gsize room = MIN((gsize)WX_HTTP_READ_CHUNK, (gsize)WX_HTTP_MAX_BODY_BYTES + 1 - op->body_filled);
    g_byte_array_set_size(op->body, (guint)(op->body_filled + room));
    gsize consumed = 0, produced = 0;
    GConverterResult res = g_converter_convert(
        op->decoder, in + off, in_len - off, op->body->data + op->body_filled, room,
        off == in_len ? G_CONVERTER_FLUSH : G_CONVERTER_NO_FLAGS, &consumed, &produced, error);
    if (res == G_CONVERTER_ERROR)
      return FALSE;
    off += consumed;
    op->body_filled += produced;
    if (op->body_filled > WX_HTTP_MAX_BODY_BYTES) {
      g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response too large");
      return FALSE;
    }
    if (res == G_CONVERTER_FINISHED) {
      op->decoder_finished = TRUE;
      if (off < in_len) {
        g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "data after the end of the compressed body");
        return FALSE;
      }
      return TRUE;
    }
    if (res == G_CONVERTER_FLUSHED)
      return TRUE;
  }
}

/**
 * on_read:
 * @source: (not nullable): the raw response GInputStream (passed as GObject*).
 * @result: (not nullable): the read result.
 * @user_data: (transfer full): the operation's GTask reference taken in
 *   read_next(), released here.
 *
 * GAsyncReadyCallback of one body read: accumulates the bytes (decoding them
 * first for a gzip response), enforces the body cap, the declared length and
 * the completeness of the gzip stream, and either reads on, fails the attempt
 * or completes the operation.
 *
 * Preconditions:
 *  - @source is op->stream and @result belongs to the read started by
 *    read_next(), whose buffer is inside op->body (identity coding, not
 *    reallocated while a read is pending) or op->raw (gzip).
 *    op->body_filled <= WX_HTTP_MAX_BODY_BYTES on entry (read_next() is only
 *    called then).
 * Postconditions:
 *  - body_filled is incremented by the (decoded) bytes read; if it exceeds
 *    WX_HTTP_MAX_BODY_BYTES the attempt fails with WX_ERROR_PARSE "response
 *    too large" (so body_filled <= cap + 1 and the guint casts of it cannot
 *    truncate); a failed read is WX_ERROR_NETWORK, as is a body whose encoded
 *    length (raw_received) differs from a declared Content-Length, an empty
 *    body of unknown length (length_unknown) and a gzip stream that is
 *    truncated, lacks its trailer or is corrupt; data after the end of a gzip
 *    stream is WX_ERROR_PARSE; at end of stream the body
 *    (trimmed to body_filled, <= the cap) is returned. Exactly one of: another
 *    read, a failed attempt, or completion.
 * Thread affinity: main thread only.
 * Ownership: the task reference in @user_data is released on every path
 *   through the g_autoptr; the body is stolen into a GBytes owned by the
 *   response.
 */
static void
on_read(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  Op *op = g_task_get_task_data(task);
  GError *err = NULL;
  gssize n = g_input_stream_read_finish(G_INPUT_STREAM(source), result, &err);
  if (n < 0) {
    fail_attempt(task, err);
    return;
  }
  op->raw_received += (gsize)n;
  if (op->decoder == NULL) {
    op->body_filled += (gsize)n;
    if (op->body_filled > WX_HTTP_MAX_BODY_BYTES) {
      fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "response too large"));
      return;
    }
  } else if (n > 0 && !inflate_chunk(op, op->raw, (gsize)n, &err)) {
    fail_attempt(task, err);
    return;
  }
  if (n > 0) {
    read_next(task);
    return;
  }
  /* End of the encoded body. A body of unknown length that is EMPTY (nothing at all, with no
   * explicit "Content-Length: 0") is not accepted as a complete response: a close-delimited one
   * cannot be told from a response cut inside its header block (libsoup takes the end of the
   * stream there as the end of the head), and libsoup reads a chunked body whose first chunk-size
   * line is not hexadecimal as an empty body. Nothing complete arrived: a failed transfer. */
  if (op->length_unknown && op->raw_received == 0) {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK,
                                           "connection closed before any content arrived"));
    return;
  }
  /* A body shorter than its declared length is a dropped connection, not a complete response
   * (libsoup reports it as a plain end of stream); the length counts encoded bytes, so it is
   * compared with what came off the wire, not with the decoded body. */
  if (op->has_declared && op->raw_received != op->declared) {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK,
                                           "connection closed before the whole body arrived"));
    return;
  }
  /* A gzip stream that has not reached its end marker (data cut, trailer missing, nothing at
   * all) is incomplete even when the HTTP framing is intact; every input byte was already fed to
   * the decoder and drained, so nothing more can come out of it. */
  if (op->decoder != NULL && !op->decoder_finished) {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_NETWORK,
                                           "compressed body ended before its end marker"));
    return;
  }
  g_byte_array_set_size(op->body, (guint)op->body_filled);
  GBytes *body = g_byte_array_free_to_bytes(g_steal_pointer(&op->body));
  op_return_response(task, response_new(op, op->http_status, body));
}

/**
 * read_next:
 * @task: (not nullable): the operation's task.
 *
 * Issues the next asynchronous read: into the body buffer (identity coding),
 * asking for at most one byte beyond the cap so an oversized body is detected
 * without buffering it, or into the raw buffer (gzip).
 *
 * Preconditions:
 *  - @task has an Op with a live stream and body, and op->body_filled <=
 *    WX_HTTP_MAX_BODY_BYTES (on_sent() starts with 0; on_read() checks the
 *    cap before calling), so the identity chunk is >= 1 byte and body_filled
 *    + chunk <= cap + 1, which fits a guint (G_STATIC_ASSERT above).
 * Postconditions:
 *  - a read is pending with a new reference to @task, passed to on_read();
 *    for the identity coding op->body was grown to body_filled + chunk bytes.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller; the pending read owns the new task
 *   reference until on_read() releases it.
 */
static void
read_next(GTask *task)
{
  Op *op = g_task_get_task_data(task);
  if (op->decoder != NULL) {
    g_input_stream_read_async(op->stream, op->raw, WX_HTTP_READ_CHUNK, G_PRIORITY_DEFAULT,
                              op->attempt_cancel, on_read, g_object_ref(task));
    return;
  }
  gsize chunk = MIN((gsize)WX_HTTP_READ_CHUNK, (gsize)WX_HTTP_MAX_BODY_BYTES + 1 - op->body_filled);
  g_byte_array_set_size(op->body, (guint)(op->body_filled + chunk));
  g_input_stream_read_async(op->stream, op->body->data + op->body_filled, chunk, G_PRIORITY_DEFAULT,
                            op->attempt_cancel, on_read, g_object_ref(task));
}

/**
 * parse_content_coding:
 * @list: (nullable): the Content-Encoding header value as libsoup joins several
 *   header lines (", "), or NULL if there is none.
 * @is_gzip: (out): receives whether the body is gzip coded.
 *
 * Interprets a Content-Encoding value as an RFC 9110 content-coding list: elements are
 * separated by commas, surrounding blanks and empty elements are dropped, and "identity" elements
 * are dropped; names compare case-insensitively. What is left must be nothing (no coding) or
 * exactly one "gzip" (or its alias "x-gzip").
 *
 * Preconditions:
 *  - @list is NULL or NUL-terminated; @is_gzip is non-NULL.
 * Postconditions:
 *  - on TRUE *@is_gzip says whether the body is gzip coded; on FALSE (any other coding, a
 *    parameter such as "gzip;q=1", gzip twice, gzip with another coding) *@is_gzip is unchanged.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the coding is none or gzip.
 */
static gboolean
parse_content_coding(const char *list, gboolean *is_gzip)
{
  if (list == NULL) {
    *is_gzip = FALSE;
    return TRUE;
  }
  guint gzips = 0;
  g_auto(GStrv) parts = g_strsplit(list, ",", -1);
  for (guint i = 0; parts[i] != NULL; i++) {
    const char *name = g_strstrip(parts[i]);
    if (name[0] == '\0' || g_ascii_strcasecmp(name, "identity") == 0)
      continue;
    if (g_ascii_strcasecmp(name, "gzip") != 0 && g_ascii_strcasecmp(name, "x-gzip") != 0)
      return FALSE;
    gzips++;
  }
  if (gzips > 1)
    return FALSE;
  *is_gzip = gzips == 1;
  return TRUE;
}

/* Result of parse_content_length(). */
typedef enum {
  CL_OK,        /* one value (possibly repeated, identically) within the cap */
  CL_INVALID,   /* an element is not 1*DIGIT (empty, sign, hex, garbage) */
  CL_CONFLICT,  /* two elements with different values */
  CL_TOO_LARGE, /* the (single) value exceeds WX_HTTP_MAX_BODY_BYTES */
} ContentLengthResult;

/**
 * parse_content_length:
 * @list: (not nullable): the Content-Length value as libsoup joins several header lines
 *   (", "): a comma separated list.
 * @value: (out): receives the length on CL_OK.
 *
 * Validates a Content-Length field value by RFC 9110 8.6 / RFC 9112 6.3 and not by libsoup's
 * parser (which stores an unsigned 64 bit value in a signed one, so that 2^63 and more come out
 * negative or as -1): every comma separated element, after trimming blanks and tabs, must be 1*DIGIT
 * (no sign, no hex, no empty element); elements that differ numerically (leading zeros do not
 * count) are a conflict, equal ones are one value; the value must not exceed
 * WX_HTTP_MAX_BODY_BYTES. Arbitrarily long digit strings are handled without conversion.
 *
 * Preconditions:
 *  - @list is NUL-terminated; @value is non-NULL.
 * Postconditions:
 *  - *@value is written only on CL_OK. CL_INVALID takes precedence over CL_CONFLICT, which takes
 *    precedence over CL_TOO_LARGE.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the verdict.
 */
static ContentLengthResult
parse_content_length(const char *list, gsize *value)
{
  g_auto(GStrv) parts = g_strsplit(list, ",", -1);
  const char *first = NULL;
  gsize first_len = 0;
  gboolean conflict = FALSE;
  for (guint i = 0; parts[i] != NULL; i++) {
    const char *s = parts[i];
    while (*s == ' ' || *s == '\t')
      s++;
    gsize len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\t'))
      len--;
    if (len == 0)
      return CL_INVALID;
    for (gsize k = 0; k < len; k++)
      if (!g_ascii_isdigit(s[k]))
        return CL_INVALID;
    while (len > 1 && *s == '0') {
      s++;
      len--;
    }
    if (first == NULL) {
      first = s;
      first_len = len;
    } else if (len != first_len || memcmp(s, first, len) != 0) {
      conflict = TRUE;
    }
  }
  if (first == NULL) /* an empty value has no elements at all */
    return CL_INVALID;
  if (conflict)
    return CL_CONFLICT;
  if (first_len > 9) /* more than 999999999 > the cap, and cannot overflow below */
    return CL_TOO_LARGE;
  gsize n = 0;
  for (gsize k = 0; k < first_len; k++)
    n = n * 10 + (gsize)(first[k] - '0');
  if (n > WX_HTTP_MAX_BODY_BYTES)
    return CL_TOO_LARGE;
  *value = n;
  return CL_OK;
}

/**
 * status_is_bodiless:
 * @op: (not nullable): the operation (for its If-Modified-Since).
 * @status: the HTTP status of the response.
 *
 * Tells whether the response is accepted as complete without a body: a 204, a 205, or a 304 to
 * a request that carried If-Modified-Since.
 *
 * Preconditions:
 *  - @op is live.
 * Postconditions:
 *  - nothing changes.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 *
 * Returns: TRUE if the status completes the operation with an empty body.
 */
static gboolean
status_is_bodiless(const Op *op, guint status)
{
  return status == SOUP_STATUS_NO_CONTENT || status == SOUP_STATUS_RESET_CONTENT ||
         (status == SOUP_STATUS_NOT_MODIFIED && op->if_modified_since != NULL);
}

/**
 * transfer_coding_is_chunked:
 * @list: (not nullable): the Transfer-Encoding value as libsoup joins several header lines (", ").
 *
 * Tells whether a Transfer-Encoding list is exactly "chunked": one element, compared
 * case-insensitively. libsoup has already stripped the blanks and tabs around each header value
 * (the tests send "Transfer-Encoding:  chunked \t" and a tab-wrapped value), and joins several
 * lines with ", ", so a list of two lines is never equal to "chunked", and neither is anything
 * else: no second element (a repeated or earlier "chunked", "gzip, chunked", "chunked,
 * identity"), no "identity" (unlike Content-Encoding, whose "identity" and empty elements are
 * dropped: libsoup frames by the LAST header line only, so a list is not read the way it is
 * written) and no empty value. Should a value ever keep a blank, it fails closed (not accepted).
 *
 * Preconditions:
 *  - @list is NUL-terminated.
 * Postconditions:
 *  - nothing changes.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the list is the single coding "chunked".
 */
static gboolean
transfer_coding_is_chunked(const char *list)
{
  return g_ascii_strcasecmp(list, "chunked") == 0;
}

/**
 * inspect_framing:
 * @op: (not nullable): the operation; op->msg is live and has a status (any value).
 * @msg: (not nullable): the message of the attempt (op->msg).
 *
 * Validates the framing headers of a response head from their raw text, records the verdict for
 * on_sent() and rewrites Content-Length so that libsoup only ever converts a number it can
 * convert safely. The verdict is recorded whatever the status; on_sent() reads it only for a
 * 2xx response that carries content (not a 204, 205 or accepted 304), so the status-first rules
 * hold: a bodiless success or another status keeps its own result whatever the lines say.
 *  - with a Transfer-Encoding header Content-Length is ignored (RFC 9112 6.3; in libsoup 3.6.6
 *    soup_message_headers_get_encoding() looks at Transfer-Encoding first and converts
 *    Content-Length only when there is none, so it is left alone); the joined Transfer-Encoding
 *    list must be exactly "chunked" (transfer_coding_is_chunked()), else op->framing_error is
 *    "unsupported response framing" (libsoup decides by the last Transfer-Encoding line only);
 *  - otherwise the Content-Length list is checked by parse_content_length(): a valid length is
 *    rewritten as that single canonical decimal ("7, 7" and "007" become "7") and stored in
 *    op->has_declared / op->declared; an invalid, conflicting or oversized one is REMOVED and
 *    recorded in op->framing_error (on_sent() fails the attempt, the body is never read).
 * op->length_unknown is set when the framing is not Content-Length (close-delimited or chunked).
 *
 * The function is idempotent over the headers it has already rewritten and never clears a
 * verdict: it runs once from on_status_code() and once more from on_sent(), because the headers
 * the first run saw are complete only over HTTP/1 (see on_status_code()).
 *
 * Preconditions:
 *  - @msg is op->msg; @op's framing_error is either NULL or a verdict recorded for this very
 *    response head.
 * Postconditions:
 *  - without a Transfer-Encoding header the Content-Length header of @msg is absent or one
 *    canonical number; op->framing_error is set when the framing is rejected (and is otherwise
 *    left as it was); op->has_declared / op->declared are set for a valid Content-Length;
 *    op->length_unknown describes the headers as they are now.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
inspect_framing(Op *op, SoupMessage *msg)
{
  SoupMessageHeaders *headers = soup_message_get_response_headers(msg);
  const char *error = NULL;
  const char *transfer = soup_message_headers_get_list(headers, "Transfer-Encoding");
  const char *list = soup_message_headers_get_list(headers, "Content-Length");
  if (transfer != NULL) {
    if (!transfer_coding_is_chunked(transfer))
      error = "unsupported response framing";
  } else if (list != NULL) {
    gsize value = 0;
    switch (parse_content_length(list, &value)) {
    case CL_OK: {
      g_autofree char *canonical = g_strdup_printf("%" G_GSIZE_FORMAT, value);
      if (strcmp(list, canonical) != 0)
        soup_message_headers_replace(headers, "Content-Length", canonical);
      op->has_declared = TRUE;
      op->declared = value;
      break;
    }
    case CL_INVALID:
      soup_message_headers_remove(headers, "Content-Length");
      error = "invalid Content-Length";
      break;
    case CL_CONFLICT:
      soup_message_headers_remove(headers, "Content-Length");
      error = "conflicting Content-Length values";
      break;
    case CL_TOO_LARGE:
      soup_message_headers_remove(headers, "Content-Length");
      error = "response too large";
      break;
    }
  }
  if (error != NULL)
    op->framing_error = error;
  op->length_unknown = soup_message_headers_get_encoding(headers) != SOUP_ENCODING_CONTENT_LENGTH;
}

/**
 * on_status_code:
 * @object: (not nullable): the SoupMessage of the attempt (passed as GObject*).
 * @pspec: (unused): the property that changed ("status-code").
 * @user_data: (not nullable): the operation (passed as gpointer).
 *
 * "notify::status-code" handler: forgets the verdict of an earlier head of the same attempt and
 * runs inspect_framing(), which validates the raw framing headers and neutralises Content-Length
 * before libsoup converts it.
 *
 * Why here (libsoup 3.6.6, libsoup/http1/soup-client-message-io-http1.c, read from its source):
 * in parse_headers() soup_headers_parse_response() fills the response headers, then
 * soup_message_set_status() emits this notification, and only afterwards
 * soup_message_headers_get_encoding() parses Content-Length with g_ascii_strtoull() into a signed
 * goffset (2^63 and more come out negative or as -1) and caches the result. io_read() copies that
 * value into read_length (before it emits "got-headers") and, in its BODY_START state, builds the
 * body stream from it with soup_body_input_stream_new(), whose g_object_new() logs a GObject
 * CRITICAL for a negative length. This notification is therefore the last point where the raw
 * header can still be changed, and inspect_framing() changes it there whatever the status:
 * parse_headers() calls soup_message_headers_get_encoding() for every final status but 204 and
 * 304 (a 205, 404 or 500 included). soup_message_headers_remove() and _replace() reset the cached
 * framing (soup_message_headers_set()).
 *
 * An informational (1xx) head is inspected like any other and harmlessly: parse_headers() does
 * not compute its framing, and io_read() then calls soup_message_cleanup_response(), which
 * clears the headers and sets the status back to 0 (a notification of its own, which wipes the
 * verdict again) before the next head is parsed, so the verdict that survives is always the one
 * of the final head. This is covered by test_net_informational_heads(). A request that libsoup
 * repeats by itself (once after a 421, observed with 3.6.6) is covered by
 * test_net_content_length_after_421().
 *
 * HTTP/2 (https servers that negotiate it): libsoup's http2 on_header_callback() sets the status
 * from ":status", the first header of the block, BEFORE it appends the regular headers (observed
 * live: an empty "200" with "content-length: 0" from an HTTP/2 server was a failed transfer when
 * only this handler ran), so the response headers are still empty here. A hostile Content-Length
 * cannot cause the libsoup critical there: its http2 code only compares the length with 0
 * (message_has_content_length_zero()) and builds no length-limited body stream from it, and
 * nghttp2 1.64 (lib/nghttp2_http.c; the installed library was not read) refuses a content-length
 * that is not 1*DIGIT within INT64_MAX. on_sent() runs inspect_framing() again, when the headers
 * are complete, and applies the same rules as over HTTP/1.
 *
 * Preconditions:
 *  - @user_data is the Op whose op->msg is @object; the notification is emitted from the main
 *    loop while the response head is parsed.
 * Postconditions:
 *  - op->framing_error, op->has_declared / op->declared and op->length_unknown describe the head
 *    that was just parsed, and (over HTTP/1) its Content-Length header is absent or one canonical
 *    number.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
static void
on_status_code(GObject *object, GParamSpec *pspec, gpointer user_data)
{
  (void)pspec;
  SoupMessage *msg = SOUP_MESSAGE(object);
  Op *op = user_data;
  op->has_declared = FALSE;
  op->declared = 0;
  op->framing_error = NULL;
  inspect_framing(op, msg);
}

/**
 * record_validators:
 * @op: (not nullable): the operation, with a live message that has response headers.
 *
 * Records the cache validators of the current response in @op: the parsed Expires (expires_s,
 * 0 if absent or unusable) and Last-Modified (last_modified, only printable ASCII within
 * WX_HTTP_VALIDATOR_MAX bytes, else NULL).
 *
 * Preconditions:
 *  - op->msg is live; op->last_modified is NULL (attempt_cleanup() clears it).
 * Postconditions:
 *  - expires_s and last_modified describe the response.
 * Thread affinity: main thread only.
 * Ownership: last_modified is a new string owned by @op.
 */
static void
record_validators(Op *op)
{
  SoupMessageHeaders *headers = soup_message_get_response_headers(op->msg);
  op->expires_s = wx_http_parse_expires(soup_message_headers_get_one(headers, "Expires"),
                                        g_get_real_time() / G_USEC_PER_SEC);
  const char *last_modified = soup_message_headers_get_one(headers, "Last-Modified");
  if (text_is_printable_ascii(last_modified, WX_HTTP_VALIDATOR_MAX))
    op->last_modified = g_strdup(last_modified);
}

/**
 * on_unrecognized_framing:
 * @task: (not nullable): the operation's task.
 *
 * Ends an attempt that libsoup itself refused with SOUP_SESSION_ERROR_ENCODING: the response
 * head was complete but its framing cannot be followed (the last Transfer-Encoding line is
 * neither "chunked" nor "identity", e.g. "gzip, chunked" or "bogus"; a Content-Length can no
 * longer cause it, inspect_framing() has rewritten it before libsoup parses it). The status line was
 * parsed first, so the status decides, as for any other response: a 204, a 205 or an accepted
 * 304 is a bodiless success; another status outside 2xx fails as http_status_error() says; a 2xx
 * carrying content fails with WX_ERROR_PARSE "unsupported response framing" (final, not a
 * network fault).
 *
 * Preconditions:
 *  - op->msg is live and has parsed status and headers; no stream exists; the caller holds the
 *    task reference.
 * Postconditions:
 *  - the task is completed with the response or the error (or a retry was scheduled for a 5xx);
 *    op->http_status is the response status.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller.
 */
static void
on_unrecognized_framing(GTask *task)
{
  Op *op = g_task_get_task_data(task);
  op->http_status = (guint)soup_message_get_status(op->msg);
  if (status_is_bodiless(op, op->http_status)) {
    record_validators(op);
    op_return_response(task, response_new(op, op->http_status, g_bytes_new(NULL, 0)));
  } else if (op->http_status < 200 || op->http_status >= 300) {
    fail_attempt(task, http_status_error(op->http_status));
  } else {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "unsupported response framing"));
  }
}

/**
 * on_sent:
 * @source: (not nullable): the SoupSession (passed as GObject*).
 * @result: (not nullable): the send result.
 * @user_data: (transfer full): the operation's GTask reference taken in
 *   attempt_start(), released here.
 *
 * GAsyncReadyCallback of soup_session_send_async(): decides the status, the
 * framing (on_status_code() validated Content-Length when the status arrived;
 * inspect_framing() runs again here on the complete headers) and the content
 * coding, records the response headers, then starts reading the body (or
 * completes at once for a bodiless response).
 *
 * Preconditions:
 *  - @user_data is a task whose Op has a live message (op->msg) of the attempt
 *    that was sent.
 * Postconditions:
 *  - a libsoup failure to follow the framing (SOUP_SESSION_ERROR_ENCODING) is
 *    decided by on_unrecognized_framing(); any other transport error fails the
 *    attempt (fail_attempt()). A 204, a 205 or a 304 to a request that carried
 *    If-Modified-Since completes the operation with an empty body whatever
 *    Content-Encoding and Content-Length say; any other status outside 2xx
 *    fails with its own error. For a 2xx that carries content a framing
 *    verdict recorded by on_status_code() (invalid, conflicting or oversized
 *    Content-Length, all WX_ERROR_PARSE, one request) fails the attempt before
 *    any body byte is read, and a Content-Encoding that is not (a list of
 *    identity and at most one) gzip fails with WX_ERROR_PARSE "unsupported
 *    content coding" (see parse_content_coding()).
 *    Otherwise op->has_declared / op->declared describe the Content-Length of
 *    a length-delimited response, op->decoder and op->raw exist exactly for a
 *    gzip response, op->body is allocated with the declared length (<= the
 *    cap, so the guint cast is safe) or WX_HTTP_READ_CHUNK, and the first
 *    read is issued.
 * Thread affinity: main thread only.
 * Ownership: the stream returned by libsoup becomes owned by the Op; the task
 *   reference in @user_data is released on every path.
 */
static void
on_sent(GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr(GTask) task = user_data;
  Op *op = g_task_get_task_data(task);
  GError *err = NULL;
  GInputStream *stream = soup_session_send_finish(SOUP_SESSION(source), result, &err);
  if (stream == NULL) {
    if (g_error_matches(err, SOUP_SESSION_ERROR, SOUP_SESSION_ERROR_ENCODING)) {
      g_error_free(err);
      on_unrecognized_framing(task);
    } else {
      fail_attempt(task, err);
    }
    return;
  }
  op->stream = stream;
  op->http_status = (guint)soup_message_get_status(op->msg);
  /* 204, 205 and an accepted 304 can carry no content: the body is empty and Content-Encoding
   * (which describes content that does not exist) is not looked at. */
  gboolean no_content = status_is_bodiless(op, op->http_status);
  if (!no_content && (op->http_status < 200 || op->http_status >= 300)) {
    fail_attempt(task, http_status_error(op->http_status));
    return;
  }
  record_validators(op);
  SoupMessageHeaders *headers = soup_message_get_response_headers(op->msg);
  if (no_content) {
    op_return_response(task, response_new(op, op->http_status, g_bytes_new(NULL, 0)));
    return;
  }
  /* The headers are complete now over HTTP/1 and HTTP/2 alike; over HTTP/2 the notification of the
   * status came before them (see on_status_code()). The rerun leaves a recorded verdict alone and
   * changes nothing that on_status_code() already rewrote. */
  inspect_framing(op, op->msg);
  if (op->framing_error != NULL) {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, op->framing_error));
    return;
  }
  /* Only a coding we asked for (gzip), or none, is accepted: anything else is a server that
   * ignores Accept-Encoding, and its body cannot be decoded. */
  gboolean gzip = FALSE;
  if (!parse_content_coding(soup_message_headers_get_list(headers, "Content-Encoding"), &gzip)) {
    fail_attempt(task, g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "unsupported content coding"));
    return;
  }
  /* Content-Length counts the ENCODED bytes (raw_received is compared with it at the end of the
   * body whatever the coding); a chunked or close-delimited body has none. inspect_framing() set
   * has_declared/declared from the validated header, only for SOUP_ENCODING_CONTENT_LENGTH. */
  if (gzip) {
    op->decoder = G_CONVERTER(g_zlib_decompressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP));
    op->raw = g_malloc(WX_HTTP_READ_CHUNK);
  }
  op->body = g_byte_array_sized_new(op->has_declared && op->declared > 0 ? (guint)op->declared : WX_HTTP_READ_CHUNK);
  op->body_filled = 0;
  read_next(task);
}

/**
 * attempt_start:
 * @task: (not nullable): the operation's task, just taken out of the queue.
 *
 * Starts one attempt of the operation: builds the GET message (no redirects,
 * Accept, optional If-Modified-Since), takes the wire slot, arms the
 * per-attempt deadline and the cancellation link and sends it.
 *
 * Preconditions:
 *  - @task has an Op with uri set and no attempt state; the caller (pump())
 *    holds a reference to @task for the duration of the call; the source
 *    object of @task is the WxHttp; the pacing gap has elapsed and, when
 *    pacing is on, nothing is on the wire.
 * Postconditions:
 *  - op->state is OP_ATTEMPT, owner->on_wire is incremented, next_start_us is
 *    now + min_gap_ms, and msg, attempt_cancel, deadline (attached to the
 *    task's context) and, when the caller supplied a cancellable, the
 *    user_cancel_id handler exist and a send is pending; the references taken
 *    for the callbacks are listed in Op.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller; the new GSource and callbacks take
 *   their own task references; @op owns the new per-attempt objects.
 */
static void
attempt_start(GTask *task)
{
  Op *op = g_task_get_task_data(task);
  WxHttp *self = op->owner;

  op->state = OP_ATTEMPT;
  op->msg = soup_message_new_from_uri(SOUP_METHOD_GET, op->uri);
  /* No redirects. libsoup's own content decoder is switched off for this message: it reports a
   * truncated compressed body as a clean end of stream, so the one supported coding (gzip) is
   * inflated by inflate_chunk() instead, strictly. */
  soup_message_add_flags(op->msg, SOUP_MESSAGE_NO_REDIRECT);
  g_signal_connect(op->msg, "notify::status-code", G_CALLBACK(on_status_code), op);
  soup_message_disable_feature(op->msg, SOUP_TYPE_CONTENT_DECODER);
  SoupMessageHeaders *request_headers = soup_message_get_request_headers(op->msg);
  soup_message_headers_replace(request_headers, "Accept", op->accept);
  soup_message_headers_replace(request_headers, "Accept-Encoding", "gzip");
  if (op->if_modified_since != NULL)
    soup_message_headers_replace(request_headers, "If-Modified-Since", op->if_modified_since);
  op->timed_out = FALSE;
  op->http_status = 0;
  op->has_declared = FALSE;
  op->declared = 0;
  op->length_unknown = FALSE;
  op->framing_error = NULL;
  op->on_wire = TRUE;
  self->on_wire++;
  self->next_start_us = g_get_monotonic_time() + (gint64)self->min_gap_ms * 1000;
  op->attempt_cancel = g_cancellable_new();
  if (op->user_cancellable != NULL)
    op->user_cancel_id = g_cancellable_connect(op->user_cancellable, G_CALLBACK(on_user_cancelled),
                                               g_object_ref(op->attempt_cancel), g_object_unref);

  op->deadline = g_timeout_source_new(self->timeout_ms);
  g_source_set_callback(op->deadline, on_deadline, g_object_ref(task), g_object_unref);
  g_source_attach(op->deadline, g_task_get_context(task));

  soup_session_send_async(self->session, op->msg, G_PRIORITY_DEFAULT, op->attempt_cancel, on_sent,
                          g_object_ref(task));
}

/**
 * on_queue_cancelled:
 * @user: (unused): the caller's cancellable that was cancelled.
 * @user_data: (not nullable): the operation's GTask (passed as gpointer).
 *
 * GCancellableSourceFunc of Op.queue_watch: completes a queued task with
 * G_IO_ERROR_CANCELLED without sending anything.
 *
 * Preconditions:
 *  - @user_data is the task reference held by the queue_watch source's
 *    callback data; the task is queued (queue_watch is cleared by every path
 *    that removes the task from the queue, so the source cannot fire for a
 *    task that has left it).
 * Postconditions:
 *  - the task is removed from the queue (the queue's reference is dropped),
 *    completed with G_IO_ERROR_CANCELLED, and pump() has run. A local
 *    reference keeps the task, its Op and the owner alive until the function
 *    returns.
 * Thread affinity: main thread only.
 * Ownership: @user and @user_data stay owned by the source; the function
 *   takes and releases its own task reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_queue_cancelled(GCancellable *user, gpointer user_data)
{
  (void)user;
  g_autoptr(GTask) task = g_object_ref(user_data);
  Op *op = g_task_get_task_data(task);
  WxHttp *self = op->owner;
  g_queue_remove(&self->queue, task);
  g_object_unref(task); /* the queue's reference */
  op_return_cancelled(task);
  pump(self);
  return G_SOURCE_REMOVE;
}

/**
 * on_pump_timer:
 * @user_data: (not nullable): the WxHttp, passed as gpointer, WITHOUT a
 *   reference.
 *
 * GSource callback of the pacing timer: runs pump().
 *
 * Preconditions:
 *  - the instance is alive: the source is the one stored in self->pump_timer
 *    (pump() destroys the previous timer before arming a new one, so at most
 *    one exists), and wx_http_finalize() destroys it before the instance is
 *    freed, which in turn needs every Op (each holds an owner reference)
 *    to be gone.
 * Postconditions:
 *  - pump() has run; the source is removed.
 * Thread affinity: main thread only.
 * Ownership: @user_data is not owned by the source (no destroy notify, no
 *   reference).
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_pump_timer(gpointer user_data)
{
  pump(WX_HTTP(user_data));
  return G_SOURCE_REMOVE;
}

/**
 * pump:
 * @self: (not nullable): the WxHttp whose queue is advanced.
 *
 * Starts the queue head while the pacing rules allow it: nothing is on the
 * wire (only when min_gap_ms > 0) and the gap since the last attempt start has
 * elapsed; otherwise arms pump_timer for the remaining time (or does nothing
 * when an attempt is on the wire: its end calls pump()). A head whose
 * cancellable is already cancelled is completed with G_IO_ERROR_CANCELLED
 * without traffic. Idempotent: every state change that could allow a start
 * calls it.
 *
 * Preconditions:
 *  - @self is a live WxHttp. pump() takes its own reference for the duration
 *    of the call: a completion callback invoked synchronously by
 *    g_task_return_*() may drop the last external reference, and the final
 *    unref of the head task (which releases the Op's owner reference) must
 *    not finalise @self while the loop still reads it. Callbacks may re-enter
 *    pump() and wx_http_get_async(); the loop re-reads the state after each.
 * Postconditions:
 *  - at most one pacing timer is armed (a timer armed by a re-entrant call is
 *    destroyed before a new one is armed). The loop ends when the queue is
 *    empty, an attempt blocks the wire or the timer was armed. The timer
 *    delay is (next_start_us - now + 999) / 1000 milliseconds with now <
 *    next_start_us <= last start + 600000 ms, so it is positive and fits a
 *    guint.
 * Thread affinity: main thread only.
 * Ownership: the queue's reference to each popped task is dropped here; the
 *   new timer's callback data is @self without a reference (see
 *   on_pump_timer()).
 */
static void
pump(WxHttp *self)
{
  g_autoptr(WxHttp) keep_alive = g_object_ref(self);
  source_clear(&self->pump_timer);
  while (!g_queue_is_empty(&self->queue) && (self->min_gap_ms == 0 || self->on_wire == 0)) {
    GTask *head = g_queue_peek_head(&self->queue);
    Op *op = g_task_get_task_data(head);
    gboolean cancelled = op->user_cancellable != NULL && g_cancellable_is_cancelled(op->user_cancellable);
    gint64 now = g_get_monotonic_time();
    if (!cancelled && now < self->next_start_us) {
      source_clear(&self->pump_timer); /* a re-entrant pump() may have armed one meanwhile */
      self->pump_timer = g_timeout_source_new((guint)((self->next_start_us - now + 999) / 1000));
      g_source_set_callback(self->pump_timer, on_pump_timer, self, NULL);
      g_source_attach(self->pump_timer, g_task_get_context(head));
      return;
    }
    g_queue_pop_head(&self->queue); /* the queue's reference is now ours */
    source_clear(&op->queue_watch);
    if (cancelled)
      op_return_cancelled(head);
    else
      attempt_start(head);
    g_object_unref(head);
  }
}

/**
 * enqueue:
 * @task: (not nullable): the operation's task, which must not be queued.
 * @at_head: TRUE to put the task at the head of the queue (a retry), FALSE at
 *   the tail.
 *
 * Puts @task into the queue and lets the pacing logic start it when its turn
 * has come. While queued, a cancellation of the caller's cancellable
 * completes the task at once.
 *
 * Preconditions:
 *  - @task has an Op, is not in the queue and has no queue_watch; the caller
 *    holds a reference to @task for the duration of the call.
 * Postconditions:
 *  - op->state is OP_QUEUED; the queue holds one new reference to @task; if
 *    the caller supplied a cancellable, queue_watch is attached to the task's
 *    context with its own task reference; pump() has run.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller; the queue and the watch take their
 *   own references.
 */
static void
enqueue(GTask *task, gboolean at_head)
{
  Op *op = g_task_get_task_data(task);
  op->state = OP_QUEUED;
  if (at_head)
    g_queue_push_head(&op->owner->queue, g_object_ref(task));
  else
    g_queue_push_tail(&op->owner->queue, g_object_ref(task));
  if (op->user_cancellable != NULL) {
    op->queue_watch = g_cancellable_source_new(op->user_cancellable);
    g_source_set_callback(op->queue_watch, G_SOURCE_FUNC(on_queue_cancelled), g_object_ref(task),
                          g_object_unref);
    g_source_attach(op->queue_watch, g_task_get_context(task));
  }
  pump(op->owner);
}

/**
 * on_backoff_elapsed:
 * @user_data: (not nullable): the operation's GTask (passed as gpointer).
 *
 * GSource callback of the back-off timer: queues the next attempt at the head.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by the timer source's callback
 *    data; the task is in state OP_BACKOFF.
 * Postconditions:
 *  - the back-off sources are released and enqueue() has run; the source is
 *    removed. A local reference keeps the task alive across backoff_cleanup()
 *    (which drops the source's own reference).
 * Thread affinity: main thread only.
 * Ownership: @user_data stays owned by the source; the callback takes and
 *   releases its own reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_backoff_elapsed(gpointer user_data)
{
  g_autoptr(GTask) task = g_object_ref(user_data);
  backoff_cleanup(g_task_get_task_data(task));
  enqueue(task, TRUE);
  return G_SOURCE_REMOVE;
}

/**
 * on_backoff_cancelled:
 * @user: (unused): the caller's cancellable.
 * @user_data: (not nullable): the operation's GTask (passed as gpointer).
 *
 * GCancellableSourceFunc: the caller cancelled during the back-off wait, so
 * the task completes immediately with G_IO_ERROR_CANCELLED.
 *
 * Preconditions:
 *  - @user_data is the task reference owned by the cancellation source's
 *    callback data; a back-off is pending.
 * Postconditions:
 *  - the back-off sources are released and @task is completed with a G_IO_ERROR
 *    / G_IO_ERROR_CANCELLED error; the source is removed. A local reference
 *    keeps the task alive across the release.
 * Thread affinity: main thread only.
 * Ownership: @user_data stays owned by the source; the callback takes and
 *   releases its own reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_backoff_cancelled(GCancellable *user, gpointer user_data)
{
  (void)user;
  g_autoptr(GTask) task = g_object_ref(user_data);
  op_return_cancelled(task);
  return G_SOURCE_REMOVE;
}

/**
 * schedule_retry:
 * @task: (not nullable): the operation's task.
 *
 * Waits backoff_base_ms * 2^(retries so far), then queues the next attempt at
 * the head of the queue; a cancellation during the wait completes the task
 * immediately.
 *
 * Preconditions:
 *  - @task has an Op whose attempt state was released and op->attempt <
 *    WX_HTTP_MAX_RETRIES (fail_attempt() checks it), so the shift is at most
 *    WX_HTTP_MAX_RETRIES - 1 and backoff_base_ms <= 600000 (the constructor
 *    enforces it), hence the delay fits a guint (G_STATIC_ASSERT above).
 * Postconditions:
 *  - op->state is OP_BACKOFF and op->attempt is incremented; a timer source
 *    (and, if the caller supplied a cancellable, a cancellation source) is
 *    attached to the task's context, each holding a new task reference
 *    released when the source is finalised.
 * Thread affinity: main thread only.
 * Ownership: @task stays with the caller; @op owns the new sources.
 */
static void
schedule_retry(GTask *task)
{
  Op *op = g_task_get_task_data(task);
  guint64 delay_ms = (guint64)op->owner->backoff_base_ms << op->attempt;
  op->attempt++;
  op->state = OP_BACKOFF;

  op->backoff_timer = g_timeout_source_new((guint)delay_ms);
  g_source_set_callback(op->backoff_timer, on_backoff_elapsed, g_object_ref(task), g_object_unref);
  g_source_attach(op->backoff_timer, g_task_get_context(task));
  if (op->user_cancellable != NULL) {
    op->backoff_cancel = g_cancellable_source_new(op->user_cancellable);
    g_source_set_callback(op->backoff_cancel, G_SOURCE_FUNC(on_backoff_cancelled),
                          g_object_ref(task), g_object_unref);
    g_source_attach(op->backoff_cancel, g_task_get_context(task));
  }
}

/**
 * on_total_deadline:
 * @user_data: (not nullable): the operation's GTask (passed as gpointer).
 *
 * GSource callback of the whole-operation deadline. In an attempt it cancels
 * the I/O and lets the pending callback report WX_ERROR_TIMEOUT (no retry
 * follows, see fail_attempt()); in a back-off wait or in the queue it
 * completes the task with WX_ERROR_TIMEOUT at once.
 *
 * Preconditions:
 *  - @user_data is the task reference held by the source's callback data; the
 *    task has not completed (op_release() destroys this source before every
 *    completion).
 * Postconditions:
 *  - op->total_expired is TRUE, the source is removed and, unless an attempt
 *    is running, @task has been completed with WX_ERROR_TIMEOUT and pump()
 *    has run. A local reference keeps the task alive across the release.
 * Thread affinity: main thread only.
 * Ownership: @user_data stays owned by the source; the callback takes and
 *   releases its own reference.
 *
 * Returns: G_SOURCE_REMOVE.
 */
static gboolean
on_total_deadline(gpointer user_data)
{
  g_autoptr(GTask) task = g_object_ref(user_data);
  Op *op = g_task_get_task_data(task);
  WxHttp *self = op->owner;
  source_clear(&op->total_deadline);
  op->total_expired = TRUE;
  switch (op->state) {
  case OP_ATTEMPT:
    g_cancellable_cancel(op->attempt_cancel); /* the pending I/O callback reports it */
    break;
  case OP_BACKOFF:
    op_return_error(task, g_error_new_literal(WX_ERROR, WX_ERROR_TIMEOUT,
                                              "operation deadline exceeded"));
    pump(self);
    break;
  case OP_QUEUED:
    g_queue_remove(&self->queue, task);
    g_object_unref(task); /* the queue's reference */
    op_return_error(task, g_error_new_literal(WX_ERROR, WX_ERROR_TIMEOUT,
                                              "operation deadline exceeded"));
    pump(self);
    break;
  }
  return G_SOURCE_REMOVE;
}

/**
 * op_new:
 * @owner: (not nullable): the WxHttp.
 * @uri: (transfer full): the validated request URI.
 * @accept: Accept value; copied.
 * @if_modified_since: (nullable): validator value; copied.
 * @user_cancellable: (nullable): the caller's cancellable; referenced.
 *
 * Creates the Op of one request and counts it in the owner's in-flight total.
 *
 * Preconditions:
 *  - @owner satisfies WX_IS_HTTP() and has fewer than WX_HTTP_MAX_INFLIGHT
 *    live Ops (the caller checked); the strings are NUL-terminated and
 *    already validated.
 * Postconditions:
 *  - owner->inflight is incremented; the Op holds a reference to @owner and
 *    to @user_cancellable and owns @uri and the string copies.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @uri; copies the strings; takes references on
 *   @owner and @user_cancellable; the returned Op is owned by the caller
 *   (op_start() hands it to the task).
 *
 * Returns: (transfer full): the new Op.
 */
static Op *
op_new(WxHttp *owner, GUri *uri, const char *accept, const char *if_modified_since,
       GCancellable *user_cancellable)
{
  Op *op = g_new0(Op, 1);
  op->uri = uri;
  op->accept = g_strdup(accept);
  op->if_modified_since = g_strdup(if_modified_since);
  op->user_cancellable = user_cancellable != NULL ? g_object_ref(user_cancellable) : NULL;
  op->owner = g_object_ref(owner);
  owner->inflight++;
  return op;
}

/**
 * op_start:
 * @task: (transfer full): the operation's task.
 * @uri: (transfer full): the validated request URI.
 * @accept: Accept value; copied.
 * @if_modified_since: (nullable): validator value; copied.
 *
 * Starts one admitted request as @task: attaches the Op as task data, arms
 * the whole-operation deadline and queues the first attempt (a task whose
 * caller's cancellable is already cancelled is completed with
 * G_IO_ERROR_CANCELLED instead).
 *
 * Preconditions:
 *  - @task has a WxHttp source object and no task data; the in-flight cap has
 *    been checked.
 * Postconditions:
 *  - the task owns a new Op (freed by op_free()) and is queued, or completed
 *    with the cancellation error. The caller's task reference is dropped
 *    before returning, the task living on through the references of its
 *    callbacks, sources and the queue.
 * Thread affinity: main thread only.
 * Ownership: takes ownership of @uri and of the caller's reference to @task;
 *   the strings stay with the caller.
 */
static void
op_start(GTask *task, GUri *uri, const char *accept, const char *if_modified_since)
{
  WxHttp *self = WX_HTTP(g_task_get_source_object(task));
  Op *op = op_new(self, uri, accept, if_modified_since, g_task_get_cancellable(task));
  g_task_set_task_data(task, op, op_free);
  if (!g_task_return_error_if_cancelled(task)) {
    op->total_deadline = g_timeout_source_new(WX_HTTP_TOTAL_DEADLINE_MS);
    g_source_set_callback(op->total_deadline, on_total_deadline, g_object_ref(task),
                          g_object_unref);
    g_source_attach(op->total_deadline, g_task_get_context(task));
    enqueue(task, FALSE);
  }
  g_object_unref(task);
}

/**
 * request_uri:
 * @self: (not nullable): the WxHttp.
 * @path_and_query: (nullable): candidate request target.
 * @accept: (nullable): candidate Accept value.
 * @if_modified_since: (nullable): candidate validator value.
 * @error: (nullable): return location for a #GError.
 *
 * Validates the three request strings and builds the request URI from the
 * pinned base URL and the target.
 *
 * Preconditions:
 *  - @self has a base URL (it was made by wx_http_new_custom()).
 * Postconditions:
 *  - on success the URI has the base URL's scheme, host and port (the target
 *    starts with a single '/' and cannot alter the authority); on failure
 *    NULL is returned and *@error is WX_ERROR_INVALID_ARG with a fixed
 *    message.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the URI.
 */
static GUri *
request_uri(WxHttp *self, const char *path_and_query, const char *accept,
            const char *if_modified_since, GError **error)
{
  if (!wx_http_path_is_valid(path_and_query)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid request path");
    return NULL;
  }
  if (!text_is_printable_ascii(accept, WX_HTTP_HEADER_VALUE_MAX)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid Accept value");
    return NULL;
  }
  if (if_modified_since != NULL &&
      !text_is_printable_ascii(if_modified_since, WX_HTTP_VALIDATOR_MAX)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "invalid If-Modified-Since value");
    return NULL;
  }
  g_autofree char *url = g_strconcat(self->base_url, path_and_query, NULL);
  GUri *uri = g_uri_parse(url, SOUP_HTTP_URI_FLAGS, NULL);
  if (uri == NULL)
    g_set_error_literal(error, WX_ERROR, WX_ERROR_INVALID_ARG, "malformed request path");
  return uri;
}

/* Documented in wx-http.h. */
void
wx_http_get_async(WxHttp *self, const char *path_and_query, const char *accept,
                  const char *if_modified_since, GCancellable *cancellable,
                  GAsyncReadyCallback callback, gpointer user_data)
{
  g_return_if_fail(WX_IS_HTTP(self) && self->base_url != NULL);
  g_return_if_fail(path_and_query != NULL);
  g_return_if_fail(accept != NULL);
  g_return_if_fail(cancellable == NULL || G_IS_CANCELLABLE(cancellable));

  GTask *task = g_task_new(self, cancellable, callback, user_data);
  g_task_set_source_tag(task, &tag_get);
  GError *error = NULL;
  GUri *uri = request_uri(self, path_and_query, accept, if_modified_since, &error);
  if (uri == NULL) {
    g_task_return_error(task, error);
    g_object_unref(task);
    return;
  }
  if (self->inflight >= WX_HTTP_MAX_INFLIGHT) {
    g_uri_unref(uri);
    g_task_return_new_error(task, WX_ERROR, WX_ERROR_RATE_LIMITED,
                            "too many outstanding requests (limit %d)", WX_HTTP_MAX_INFLIGHT);
    g_object_unref(task);
    return;
  }
  op_start(task, uri, accept, if_modified_since);
}

/* Documented in wx-http.h. */
WxHttpResponse *
wx_http_get_finish(WxHttp *self, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail(WX_IS_HTTP(self), NULL);
  g_return_val_if_fail(g_task_is_valid(result, self), NULL);
  g_return_val_if_fail(g_task_get_source_tag(G_TASK(result)) == &tag_get, NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}
