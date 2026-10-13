/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-http.h - WxHttp: the hardened, host-pinned HTTP GET engine. Every weather
 * provider reaches the network through one WxHttp instance and nothing else in
 * the process does; it is the only module that uses libsoup.
 *
 * Read-only GETs over HTTPS (plain HTTP is accepted only towards the loopback
 * hosts 127.0.0.1, ::1 and localhost, so tests can use a fake server). No API
 * key, cookie, credential, referrer or browser identity is ever sent: the
 * request carries the caller's User-Agent, its Accept value, "Accept-Encoding:
 * gzip", an optional If-Modified-Since, and the Host header libsoup adds.
 * TLS certificates are always verified. Redirects are never followed.
 *
 * Host pinning
 * ------------
 * The scheme, host and port are fixed by the base URL given to the
 * constructor. A request is described by a path-and-query that must begin
 * with a single '/' and may contain neither whitespace, control or non-ASCII
 * bytes, '#' nor '\' (wx_http_path_is_valid()), so it can never change the
 * authority: an instance can only ever contact its base URL's host.
 *
 * Request policy (per operation; every attempt is one GET)
 * --------------------------------------------------------
 *  - An attempt that has not completed (headers and body) within the
 *    per-attempt timeout (WX_HTTP_TIMEOUT_MS by default) fails with
 *    WX_ERROR_TIMEOUT. The whole operation, queue wait and back-off included,
 *    must finish within WX_HTTP_TOTAL_DEADLINE_MS; when that expires the
 *    operation is cancelled and fails with WX_ERROR_TIMEOUT without a further
 *    retry.
 *  - After a failed attempt the request is retried at most WX_HTTP_MAX_RETRIES
 *    times, waiting backoff, 2 * backoff, ... (WX_HTTP_BACKOFF_BASE_MS by
 *    default) before the next attempt, and ONLY after WX_ERROR_NETWORK, a
 *    per-attempt WX_ERROR_TIMEOUT and an HTTP status 500..599.
 *    Everything else (4xx, 429, 3xx, too large a body, ...) is final.
 *  - HTTP status mapping: 2xx -> success (204 and 205 always with an empty
 *    body); 304 -> success ONLY when an If-Modified-Since value was sent
 *    (empty body), otherwise WX_ERROR_HTTP; 429 -> WX_ERROR_RATE_LIMITED;
 *    404 -> WX_ERROR_NOT_FOUND; every other status (3xx are not followed) ->
 *    WX_ERROR_HTTP.
 *  - Body: at most WX_HTTP_MAX_BODY_BYTES bytes after content decoding. A
 *    larger body is rejected with WX_ERROR_PARSE: a declared Content-Length
 *    above the cap is refused before any body byte is read; otherwise at
 *    most cap + 1 decoded bytes are ever buffered (a compressed body that
 *    inflates beyond the cap is refused the same way). A body that ends
 *    before its declared Content-Length is WX_ERROR_NETWORK: the number of
 *    ENCODED bytes that arrived is compared with the Content-Length whatever
 *    the Content-Encoding. A chunked body has no declared length; libsoup
 *    reports a cut chunk or a missing final chunk as an error
 *    (WX_ERROR_NETWORK). The body is NOT interpreted here: UTF-8 and JSON
 *    validation is the parser's job (wx_json_parse()).
 *  - Transfer-Encoding and Content-Length (RFC 9110 8.6, RFC 9112 6.1 and
 *    6.3) are validated here from their raw header text, not trusted from
 *    libsoup. What libsoup 3.6.6 does (read from libsoup/http1/
 *    soup-client-message-io-http1.c, parse_headers(), and
 *    soup_message_headers_get_encoding()): it fills the response headers,
 *    then soup_message_set_status() emits notify::status-code, and only
 *    afterwards the framing is computed, from the LAST Transfer-Encoding
 *    line, else by converting the LAST Content-Length line with
 *    g_ascii_strtoull() into a signed goffset: 2^63 and more come out
 *    negative or as -1, which would mean "no declared length" (the size cap
 *    and the truncation check off), and for a negative length
 *    soup_body_input_stream_new() logs a GObject CRITICAL (abort under
 *    G_DEBUG=fatal-criticals). WxHttp therefore runs its checks in that
 *    notification (on_status_code(), before the framing exists) and rewrites
 *    the Content-Length header there, so that what libsoup converts is
 *    one canonical number or nothing, whatever the status (205, 404, 500
 *    included; libsoup converts no Content-Length when there is a
 *    Transfer-Encoding header): the Content-Length of a response can no
 *    longer make libsoup log that critical. Over HTTP/2 (https servers that
 *    negotiate it) libsoup sets the status before it appends the other
 *    headers, so the same checks run again, on the complete headers, when
 *    the send completes (on_sent()).
 *    For a response that can carry content (2xx except 204/205 and an
 *    accepted 304): if there is any Transfer-Encoding line, the JOINED list
 *    (several lines are one comma separated list) must be exactly one
 *    "chunked" element (case-insensitive, blanks around it ignored) else
 *    WX_ERROR_PARSE "unsupported response framing": a second element or line
 *    ("gzip" + "chunked", "chunked" + "chunked", "gzip, chunked"), an
 *    "identity" element, an empty element or line and every other value are
 *    all rejected (nothing is dropped, unlike in Content-Encoding, below).
 *    Content-Length is ignored whenever Transfer-Encoding is present (RFC
 *    9112 6.3). Without Transfer-Encoding the Content-Length lines form a comma
 *    separated list in which every element must be 1*DIGIT (blanks and
 *    leading zeros do not matter; no sign, hex, exponent, fraction or empty
 *    element): else WX_ERROR_PARSE "invalid Content-Length"; elements that
 *    differ in value ("7" and "3") are WX_ERROR_PARSE "conflicting
 *    Content-Length values"; equal ones ("7" + "7", "7, 7") are one value,
 *    handed to libsoup as that canonical number; a value above
 *    WX_HTTP_MAX_BODY_BYTES, however many digits it has, is WX_ERROR_PARSE
 *    "response too large". All of them are decided before any body byte is
 *    read, are final (not retried), take exactly one request and leave no
 *    unread body to be mistaken for the next response (the connection is
 *    closed, not reused). A Transfer-Encoding that libsoup itself refuses
 *    (SOUP_SESSION_ERROR_ENCODING, e.g. a single "gzip" line) is the same
 *    PARSE. The status decides first: 204, 205 and an accepted 304 stay
 *    bodiless successes, and any other non-2xx status keeps its own error,
 *    whatever these lines say.
 *  - Content coding: every request offers "Accept-Encoding: gzip" and
 *    nothing else. Content-Encoding is read as a content-coding LIST (RFC 9110
 *    5.6.1.2; several header lines are one list): blanks, empty elements and
 *    "identity" are dropped, names are case-insensitive, and what is left must
 *    be nothing (no coding) or exactly one "gzip" ("x-gzip" is accepted as an
 *    alias). Anything else ("gzip, gzip", "gzip;q=1", deflate, br, gzip with
 *    another coding, ...) is a server ignoring Accept-Encoding and fails with
 *    WX_ERROR_PARSE, not retried. It is interpreted ONLY for a response that
 *    can carry content: 204, 205 and an accepted 304 are bodiless successes
 *    whatever it says (and 3xx/4xx/5xx fail on their status first). A gzip
 *    body is inflated here (not by libsoup, whose decoder ends a truncated
 *    stream cleanly) and only one gzip member is accepted: a stream that ends
 *    early, lacks its trailer, fails its CRC, is corrupt or is EMPTY (a 200
 *    with Content-Encoding gzip needs at least the 20-byte empty member) is
 *    WX_ERROR_NETWORK, retried like any transport failure; bytes after the
 *    end of the gzip stream (garbage, zero padding, a second member), in the
 *    same read or in a later one, in any framing, are WX_ERROR_PARSE, not
 *    retried. A Content-Length that promises more bytes than ever arrive is a
 *    cut connection (WX_ERROR_NETWORK) even when the gzip stream is complete;
 *    if the extra bytes do arrive, they are the trailing data above. An EMPTY
 *    body of unknown length (a 2xx with content, no Content-Length, either
 *    close-delimited or chunked, zero bytes) is WX_ERROR_NETWORK: libsoup takes
 *    the end of the stream inside a header block for the end of the head, so a
 *    response cut there looks exactly like an empty close-delimited one, and it
 *    reads a chunked body whose first chunk-size line is not hexadecimal as an
 *    empty one (a "200 OK" with Content-Length: 0 stays an empty success).
 *    What stays undetectable: truncation of a NON-EMPTY UNCOMPRESSED body that
 *    has neither a Content-Length nor chunked framing (HTTP/1.1 lets the
 *    server delimit it by closing the connection, so a cut cannot be told from
 *    the end), and a malformed chunk-size line AFTER the first chunk (libsoup
 *    parses sizes with strtoul and reads garbage as the last chunk, so the
 *    body ends there); the parser (wx_json_parse()) then sees a cut document.
 *    A close-delimited gzip body whose server keeps the connection open after
 *    a complete stream ends by the per-attempt deadline (WX_ERROR_TIMEOUT).
 *  - Result table (GET, no redirect following; every row is tested by
 *    test_net_status_framing_table(), test_net_content_length_*(),
 *    test_net_transfer_encoding_lines(), test_net_transfer_encoding_random()
 *    and test_net_no_content_statuses() in test-http.c). "N" =
 *    WX_ERROR_NETWORK and retried, "P" =
 *    WX_ERROR_PARSE and final, "OK" = success; framing is Content-Length (CL),
 *    chunked (CH) or close-delimited (CD). The rules apply in this order:
 *    status, Transfer-Encoding / Content-Length, Content-Encoding, payload.
 *
 *      status                          result
 *      ------------------------------  -----------------------------------
 *      204, 205, 304 with If-Mod-Since  OK, EMPTY body, any Content-Encoding,
 *                                       Content-Length and Transfer-Encoding
 *      304 without If-Modified-Since,   WX_ERROR_HTTP (3xx are not followed,
 *        other 3xx, 4xx except below     final), any Content-Length and
 *                                        Transfer-Encoding lines
 *      404 / 429                        WX_ERROR_NOT_FOUND / _RATE_LIMITED
 *      5xx                              WX_ERROR_HTTP, retried (3 requests)
 *      200, 206, other 2xx              see the next tables
 *
 *      Transfer-Encoding lines (2xx with content), joined into one list
 *      ------------------------------------------------------------------------
 *      absent                                   see the Content-Length table
 *      exactly "chunked" (any case, blanks      chunked body; Content-Length ignored
 *        around, also with a Content-Length)    (whatever it says), see the payload table
 *      "gzip" + "chunked", "bogus" + "chunked", P "unsupported response framing"
 *        "chunked" + "identity", "chunked" +
 *        "chunked", "identity" + "chunked",
 *        "chunked" + "", "" + "chunked"
 *      "gzip, chunked", "chunked, chunked",     P (the same, in one line)
 *        "chunked, identity", "identity, chunked"
 *      "identity", "gzip", "bogus", empty       P (identity is NOT dropped, unlike in
 *                                               Content-Encoding)
 *
 *      Content-Length lines (2xx with content, no Transfer-Encoding)
 *      ------------------------------------------------------------------------
 *      absent (CH, CD)                          see the payload table
 *      one value or identical repeats, <= cap   OK with exactly that many bytes
 *        ("7", " 7 ", "007", "7" + "7", "7, 7")  (gzip: the stream must end
 *                                                 there, else N); N if fewer arrive
 *      above the cap, 2^63, 2^64 - 1, 99...9    P "response too large"
 *      "-1", "+5", "", "5x", "0x10", "5 5",     P "invalid Content-Length"
 *        "7" + "" (two lines)
 *      distinct values ("7" + "3", "7, 3")      P "conflicting Content-Length values"
 *
 *      Content-Encoding  payload       CL        CH        CD
 *      ----------------  ------------  --------  --------  --------------
 *      none / identity   complete      OK        OK        OK
 *                        empty         OK (0)    N         N   (cut head, bad chunk size)
 *                        cut           N         N         OK (cut body)
 *                        extra bytes   OK (they are part of the body)
 *      gzip              complete      OK (decoded)        OK
 *                        empty         N         N         N
 *                        cut / corrupt N         N         N
 *                        extra bytes   P         P         P
 *      br, "gzip, gzip", any other     P         P         P
 *        non-gzip list                 (before the body is read)
 *  - Server input audit (every header and number read from the response):
 *      status line      only the 3 digit status and libsoup's fixed phrase are
 *                       used (server text is never copied); 1xx heads are skipped
 *                       by libsoup and ignored here; every 2xx but 204/205
 *                       carries content, 206 included (WxHttp never sends Range,
 *                       the contract is "2xx -> success"); a malformed status
 *                       line is a libsoup error (N); libsoup itself repeats a
 *                       request once after a 421 (observed with 3.6.6: two
 *                       requests may reach the server for that one final error)
 *      head             above 100 KiB, or a line libsoup cannot parse: N; the
 *                       end of the stream inside the head: see "EMPTY body of
 *                       unknown length" above
 *      Content-Length   validated here and rewritten before libsoup converts it
 *                       (above); Transfer-Encoding: exactly "chunked" (above)
 *      Content-Encoding content-coding list (above)
 *      Expires          the last line only, parsed strictly (wx_http_parse_expires()),
 *                       0 when absent or unusable; never used for framing
 *      Last-Modified    the last line only; kept only when printable ASCII of at
 *                       most WX_HTTP_VALIDATOR_MAX bytes (so it can be sent back
 *                       as If-Modified-Since without any injection)
 *      Location, Retry-After, Content-Type, Content-Range, Connection, Upgrade,
 *      Set-Cookie, WWW-Authenticate, Alt-Svc, Trailer ...: not read (redirects
 *                       are off, there is no cookie jar and no credentials; a
 *                       401/407 is WX_ERROR_HTTP)
 *      header syntax    names with blanks, obs-fold, bare LF, odd bytes, repeated
 *                       lines and lenient chunk framing (bytes between a chunk
 *                       and the next line end are skipped) are decided by libsoup's
 *                       parser; only the framing headers above can change what is
 *                       returned and each is validated from its raw text.
 *                       libsoup 3.6.6 reads a chunk-size line with strtoul() in
 *                       soup_body_input_stream_read_chunked(), also when the line is
 *                       blank or only blanks, where valgrind reports a use of an
 *                       uninitialised value (the line buffer is not terminated):
 *                       a hostile server can cause it and nothing here can
 *                       intercept it, the chunked reader being libsoup's
 *      request side     User-Agent, Accept, If-Modified-Since: printable ASCII
 *                       within WX_HTTP_HEADER_VALUE_MAX / WX_HTTP_VALIDATOR_MAX
 *                       (INVALID_ARG otherwise); the path is validated and
 *                       the origin is pinned (wx_http_path_is_valid())
 *    A raw-socket fuzzer (over a million mutated responses, ASan+UBSan, every
 *    critical and warning fatal in every domain) accepted only outcomes in these
 *    tables.
 *  - Transport failures (DNS, connect, TLS, I/O) -> WX_ERROR_NETWORK.
 *  - Pacing: with min_gap_ms > 0 all operations of an instance share one FIFO
 *    queue; at most one attempt is on the wire and the next attempt starts
 *    only when at least min_gap_ms have passed since the previous attempt
 *    STARTED; a retry waits for its slot as well and re-enters the queue at
 *    its head. With min_gap_ms == 0 attempts start at once (libsoup limits
 *    the connections per host; further requests wait inside libsoup).
 *  - Admission: at most WX_HTTP_MAX_INFLIGHT operations are outstanding per
 *    instance. An operation is outstanding from wx_http_get_async() until its
 *    GAsyncResult is released: normally right after the callback returns, but
 *    a caller that keeps the result object (for instance to call
 *    wx_http_get_finish() later) keeps the slot, and the WxHttp alive, until
 *    it drops it. An operation that would exceed the cap fails at once with
 *    WX_ERROR_RATE_LIMITED and no network traffic. Argument validation comes
 *    first, so invalid arguments are still WX_ERROR_INVALID_ARG.
 *  - Cancellation: cancelling during the queue wait, an attempt or a back-off
 *    ends the operation promptly with G_IO_ERROR_CANCELLED. A cancellable
 *    that is already cancelled at the call is reported the same way, without
 *    network traffic. If the cancellable is cancelled after the operation
 *    completed but before wx_http_get_finish(), the finish call reports
 *    G_IO_ERROR_CANCELLED.
 *  - The callback is never invoked before wx_http_get_async() has returned,
 *    and every operation completes exactly once. An operation keeps its WxHttp
 *    alive, so dropping the last caller reference in flight is safe. The
 *    instance has no dispose override: after g_object_run_dispose() it still
 *    serves requests exactly as before (GObject allows calls until finalize).
 *
 * A WxHttp instance, and wx_http_get_async() / wx_http_get_finish() on it,
 * belong to the thread that runs the GLib main context (normally the main
 * thread); WxHttp is not thread-safe. wx_http_path_is_valid() and
 * wx_http_parse_expires() are pure and may be called from any thread.
 */
#ifndef WX_HTTP_H
#define WX_HTTP_H

#include <gio/gio.h>

#include "wx-types.h"

G_BEGIN_DECLS

/** Default per-attempt deadline, milliseconds. */
#define WX_HTTP_TIMEOUT_MS 10000
/** Deadline of a whole operation (queue wait, attempts, back-off), milliseconds. */
#define WX_HTTP_TOTAL_DEADLINE_MS 45000
/** Default first back-off delay, milliseconds (doubles per retry). */
#define WX_HTTP_BACKOFF_BASE_MS 1000
/** Maximum number of retries after the first attempt. */
#define WX_HTTP_MAX_RETRIES 2
/** Maximum accepted response body, bytes (after content decoding). */
#define WX_HTTP_MAX_BODY_BYTES (4 * 1024 * 1024)
/** Maximum number of outstanding operations per instance. */
#define WX_HTTP_MAX_INFLIGHT 16
/** Size of one body read, bytes. */
#define WX_HTTP_READ_CHUNK 16384
/** Longest accepted path-and-query, bytes (without the NUL). */
#define WX_HTTP_PATH_MAX 2048
/** Longest accepted User-Agent / Accept value, bytes (without the NUL). */
#define WX_HTTP_HEADER_VALUE_MAX 200
/** Longest accepted If-Modified-Since / Last-Modified value, bytes (without the NUL). */
#define WX_HTTP_VALIDATOR_MAX 64

/**
 * WxHttpResponse: a successful response. status is the HTTP status (200..299,
 * or 304 when If-Modified-Since was sent). Owns its members.
 */
typedef struct {
  guint status;        /**< HTTP status of the final attempt                          */
  GBytes *body;        /**< never NULL; <= WX_HTTP_MAX_BODY_BYTES bytes, empty for 304 */
  gint64 expires_s;    /**< UTC unix seconds from Expires, 0 if absent or implausible */
  char *last_modified; /**< Last-Modified text, NULL if absent or unusable            */
} WxHttpResponse;

/**
 * wx_http_response_free:
 * @response: (nullable) (transfer full): the response to free, or NULL.
 *
 * Frees a response and what it owns.
 *
 * Preconditions:
 *  - @response is NULL or a response returned by wx_http_get_finish(), not
 *    used afterwards.
 * Postconditions:
 *  - the body reference and the strings are released; NULL is a no-op.
 * Thread affinity: any thread (touches only @response).
 * Ownership: consumes @response.
 */
void wx_http_response_free(WxHttpResponse *response);

G_DEFINE_AUTOPTR_CLEANUP_FUNC(WxHttpResponse, wx_http_response_free)

#define WX_TYPE_HTTP (wx_http_get_type())
G_DECLARE_FINAL_TYPE(WxHttp, wx_http, WX, HTTP, GObject)

/**
 * wx_http_new:
 * @base_url: origin without path, e.g. "https://api.met.no" (see
 *   wx_http_new_custom() for the accepted forms).
 * @user_agent: User-Agent sent with every request: 1..WX_HTTP_HEADER_VALUE_MAX
 *   bytes of printable ASCII (0x20..0x7E).
 * @error: (nullable): return location for a #GError.
 *
 * Creates an instance with the default timing: WX_HTTP_TIMEOUT_MS,
 * WX_HTTP_BACKOFF_BASE_MS and no pacing.
 *
 * Preconditions:
 *  - @base_url and @user_agent are non-NULL and NUL-terminated (violation:
 *    critical, NULL). Their content is data: a rejected value is reported
 *    through @error, never as a critical.
 *  - Called from the thread that will run the GLib main context.
 * Postconditions:
 *  - on success the instance owns one HTTP session, created here and reused
 *    by every request, and has no outstanding operation.
 *  - on failure NULL is returned, @error (when non-NULL) is
 *    WX_ERROR/WX_ERROR_INVALID_ARG and nothing is allocated that outlives
 *    the call.
 * Thread affinity: main thread only.
 * Ownership: the arguments stay with the caller (copied); the caller owns the
 *   returned reference.
 *
 * Returns: (transfer full) (nullable): the instance; create one per provider
 *   and share it.
 */
WxHttp *wx_http_new(const char *base_url, const char *user_agent, GError **error);

/**
 * wx_http_new_custom:
 * @base_url: origin without path. "https://" origins, and "http://" origins
 *   whose host is exactly 127.0.0.1, ::1 or localhost (the latter exist so
 *   tests can use a loopback fake server), are accepted; scheme and host are
 *   compared case-insensitively and stored lower-case. The host (percent
 *   escapes decoded, an international name converted to punycode) must be a
 *   DNS name or IPv4 address of well-formed labels (1..63 ASCII letters,
 *   digits and '-', none starting or ending with '-', no trailing dot) or an
 *   IPv6 literal in brackets; a port must be 1..65535. Userinfo, query,
 *   fragment and any path other than "" or "/" are rejected; the path is the
 *   one the URI parser reports, so "/." (which it normalises to "/") is
 *   accepted as "/".
 * @user_agent: see wx_http_new().
 * @timeout_ms: per-attempt deadline, 1..600000.
 * @backoff_base_ms: first back-off delay, 0..600000 (0 retries at once).
 * @min_gap_ms: minimum time between two attempt starts, 0..600000 (0: no
 *   pacing; see the file comment).
 * @error: (nullable): return location for a #GError.
 *
 * Creates an instance with custom timing; the small values exist so tests
 * need not sleep, @min_gap_ms is for providers whose service asks for pacing.
 *
 * Preconditions:
 *  - @base_url and @user_agent are non-NULL and NUL-terminated and the three
 *    numbers are in the ranges above (violation: critical, NULL).
 *  - Called from the thread that will run the GLib main context.
 * Postconditions:
 *  - on success the instance holds a normalised copy of @base_url
 *    (scheme://host[:port], no trailing "/") and the timings.
 *  - on failure NULL is returned, @error (when non-NULL) is
 *    WX_ERROR/WX_ERROR_INVALID_ARG ("unacceptable base URL" / "invalid
 *    User-Agent", never echoing the rejected text) and nothing is allocated
 *    that outlives the call.
 * Thread affinity: main thread only.
 * Ownership: the arguments stay with the caller (copied); the caller owns the
 *   returned reference.
 *
 * Returns: (transfer full) (nullable): the instance, or NULL if @base_url or
 *   @user_agent is not acceptable.
 */
WxHttp *wx_http_new_custom(const char *base_url, const char *user_agent, guint timeout_ms,
                           guint backoff_base_ms, guint min_gap_ms, GError **error);

/**
 * wx_http_path_is_valid:
 * @path_and_query: (nullable): candidate request target.
 *
 * Validates a path-and-query: 1..WX_HTTP_PATH_MAX bytes of ASCII 0x21..0x7E,
 * beginning with exactly one '/' (so not "//"), without '#' and '\'.
 * Callers percent-encode every component (g_uri_escape_string()). At most
 * WX_HTTP_PATH_MAX + 1 bytes are read. Percent-encoding syntax is not
 * checked here; wx_http_get_async() rejects what the URI parser refuses.
 *
 * Preconditions:
 *  - @path_and_query is NULL or NUL-terminated (or has WX_HTTP_PATH_MAX + 1
 *    readable bytes).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @path_and_query satisfies the rules above.
 */
gboolean wx_http_path_is_valid(const char *path_and_query);

/**
 * wx_http_parse_expires:
 * @value: (nullable): Expires header value.
 * @now_s: current time, UTC unix seconds.
 *
 * Interprets an HTTP Expires header defensively. Only the first
 * WX_HTTP_VALIDATOR_MAX + 1 bytes are read and a longer value is refused.
 * The text must be an HTTP date that libsoup parses; the instant is accepted
 * only when it lies in the future of @now_s and at most 24 hours (86400 s)
 * after it.
 *
 * Preconditions:
 *  - @value is NULL or NUL-terminated (or has WX_HTTP_VALIDATOR_MAX + 1
 *    readable bytes); @now_s is any value.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: the expiry as UTC unix seconds t with @now_s < t <= @now_s + 86400,
 *   or 0 when @value is NULL, too long, unparsable, not after @now_s or more
 *   than 24 hours after it ("absent or implausible").
 */
gint64 wx_http_parse_expires(const char *value, gint64 now_s);

/**
 * wx_http_get_async:
 * @self: a WxHttp.
 * @path_and_query: request target, see wx_http_path_is_valid(); a target that
 *   libsoup's URI parser refuses (for instance an invalid %-escape) is
 *   refused too. Copied.
 * @accept: Accept header value: 1..WX_HTTP_HEADER_VALUE_MAX bytes of printable
 *   ASCII (0x20..0x7E), e.g. "application/json". Copied.
 * @if_modified_since: (nullable): NULL to send no validator, otherwise the
 *   If-Modified-Since value: 1..WX_HTTP_VALIDATOR_MAX bytes of printable
 *   ASCII (normally the last_modified of an earlier response). Copied.
 * @cancellable: (nullable): cancels the operation.
 * @callback: invoked once, in the thread-default main context of the caller.
 * @user_data: passed to @callback.
 *
 * Starts a GET of the base URL's host (see the file comment for the policy).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_HTTP(); @path_and_query and @accept are non-NULL;
 *    @cancellable is NULL or a GCancellable (violation: critical, nothing is
 *    started). The content of the strings is data: an unacceptable value is
 *    reported through the callback as WX_ERROR_INVALID_ARG without traffic.
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - @callback is invoked exactly once, later, in the thread-default main
 *    context of the caller, with the result to pass to wx_http_get_finish().
 *    The operation holds references to @self and @cancellable until then.
 * Thread affinity: main thread only (the thread running the GLib main
 *   context).
 * Ownership: the strings are copied; @user_data is not owned or freed here
 *   and must stay valid until @callback has run.
 */
void wx_http_get_async(WxHttp *self, const char *path_and_query, const char *accept,
                       const char *if_modified_since, GCancellable *cancellable,
                       GAsyncReadyCallback callback, gpointer user_data);

/**
 * wx_http_get_finish:
 * @self: the instance passed to wx_http_get_async().
 * @result: the GAsyncResult given to the callback.
 * @error: (nullable): return location for a #GError.
 *
 * Collects the result of wx_http_get_async().
 *
 * Preconditions:
 *  - @self satisfies WX_IS_HTTP(); @result is the result of a
 *    wx_http_get_async() call on @self and is finished at most once
 *    (violation: critical, NULL).
 *  - @error is NULL or points to a NULL GError*.
 *  - Called from the thread that runs the GLib main context.
 * Postconditions:
 *  - on success *@error is untouched and a response is returned; on failure
 *    NULL is returned and, if @error is non-NULL, *@error is set: WX_ERROR
 *    (NETWORK, TIMEOUT, HTTP, RATE_LIMITED, PARSE for an oversized body, an
 *    invalid, conflicting or oversized Content-Length, framing libsoup cannot
 *    follow, an unsupported Content-Encoding or data after a gzip stream, NOT_FOUND,
 *    INVALID_ARG) or G_IO_ERROR_CANCELLED. The messages contain no
 *    response body text (only the numeric status, libsoup's fixed status
 *    phrase and, for transport failures, the HTTP library's own message).
 * Thread affinity: main thread only.
 * Ownership: @self and @result stay with the caller; the response is
 *   returned to the caller.
 *
 * Returns: (transfer full) (nullable): the response; wx_http_response_free()
 *   it. NULL with @error set on failure.
 */
WxHttpResponse *wx_http_get_finish(WxHttp *self, GAsyncResult *result, GError **error);

G_END_DECLS

#endif /* WX_HTTP_H */
