/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-json.h - safe JSON access for untrusted response bodies.
 *
 * wx_json_parse() accepts exactly one JSON text (RFC 8259 grammar, UTF-8)
 * whose root is the object or the array the caller asked for, nested at most
 * WX_JSON_PARSE_MAX_DEPTH levels and without repeated member names; everything
 * json-glib would additionally tolerate (several top-level values, single
 * quotes, a byte-order mark, NUL escapes) is
 * rejected before json-glib sees the text. The accessors never assert on
 * hostile content: a missing, null or mistyped node yields NULL / FALSE.
 *
 * Pure functions, no global state. A JsonParser and the nodes borrowed from it
 * belong to the thread that uses them; they are not thread-safe.
 */
#ifndef WX_JSON_H
#define WX_JSON_H

#include <glib.h>
#include <json-glib/json-glib.h>

G_BEGIN_DECLS

/** Deepest accepted nesting: the root container is level 1. */
#define WX_JSON_PARSE_MAX_DEPTH 32
/**
 * Most members one JSON object may have in a body accepted by wx_json_parse().
 * It bounds the damage of hash-flooding (many names with one g_str_hash value
 * make every table insert linear, here and inside json-glib): at most this
 * many names per object, whatever the body size. Real provider objects have
 * a few dozen members.
 */
#define WX_JSON_PARSE_MAX_MEMBERS 1024
/** Largest max_chars accepted by wx_json_error_reason(). */
#define WX_JSON_REASON_CHARS_MAX 1024

/** The kind of root container wx_json_parse() requires. */
typedef enum {
  WX_JSON_ROOT_OBJECT, /**< the JSON text must be one object */
  WX_JSON_ROOT_ARRAY   /**< the JSON text must be one array  */
} WxJsonRoot;

/**
 * wx_json_parse:
 * @data: (nullable): body bytes (@len of them; need not be NUL-terminated).
 * @len: number of bytes at @data.
 * @max_len: largest accepted @len, 1..G_MAXSSIZE.
 * @root: kind of root container the text must have.
 * @error: (nullable): return location for a #GError.
 *
 * Validates and parses an untrusted response body. In this order: empty ->
 * error; @len above @max_len -> error (before any byte is examined); invalid
 * UTF-8 (an embedded NUL byte included) -> error; text that is not exactly
 * one JSON value in RFC 8259 grammar -> error; nesting deeper than
 * WX_JSON_PARSE_MAX_DEPTH -> error; an object that repeats a member name
 * (compared after decoding escapes, so "a" and "\u0061" are the same name) or
 * has more than WX_JSON_PARSE_MAX_MEMBERS members -> error; a "\u0000" escape
 * -> error; json-glib failure (for example an unpaired surrogate escape) ->
 * error; root kind different from @root -> error. Everything up to the
 * json-glib call is
 * one linear pass over the body, so the parse time is bounded by the body size
 * (json-glib itself is quadratic on repeated names, which is why they are
 * refused). Only @len bytes of @data are ever read.
 *
 * Preconditions:
 *  - @data is NULL only when @len is 0, otherwise it points to @len readable
 *    bytes (violation: critical, NULL).
 *  - @max_len is in [1, G_MAXSSIZE] (violation: critical, NULL).
 *  - @error is NULL or points to a NULL GError* .
 * Postconditions:
 *  - on success the parser holds a tree whose root is an object (@root ==
 *    WX_JSON_ROOT_OBJECT) or an array (WX_JSON_ROOT_ARRAY); every string in
 *    the tree is valid UTF-8 without NUL (it may contain control characters,
 *    which only an escape can produce: sanitise before display).
 *  - on failure NULL is returned and *@error (when non-NULL) is set to
 *    WX_ERROR/WX_ERROR_PARSE with a fixed message that never echoes body
 *    content; nothing is allocated that outlives the call. Body problems
 *    never trigger a critical.
 * Thread affinity: any thread (pure); the returned parser is single-thread.
 * Ownership: @data stays with the caller and is not retained; the caller
 *   owns the parser, and nodes borrowed from it die with it.
 *
 * Returns: (transfer full) (nullable): the parser; g_object_unref() it.
 */
JsonParser *wx_json_parse(const guint8 *data, gsize len, gsize max_len, WxJsonRoot root,
                          GError **error);

/**
 * wx_json_member_object:
 * @obj: (nullable): object to read.
 * @name: member name.
 *
 * Returns the member @name of @obj when it is a JSON object.
 *
 * Preconditions:
 *  - @name is non-NULL (NULL: critical, NULL returned); @obj may be NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure; the tree is not modified).
 * Ownership: the result is borrowed from @obj's tree.
 *
 * Returns: (transfer none) (nullable): the member when @obj is non-NULL and
 *   the member exists and is an object; NULL if @obj is NULL, the member is
 *   missing, null or of another type.
 */
JsonObject *wx_json_member_object(JsonObject *obj, const char *name);

/**
 * wx_json_member_array:
 * @obj: (nullable): object to read.
 * @name: member name.
 *
 * Returns the member @name of @obj when it is a JSON array.
 *
 * Preconditions:
 *  - @name is non-NULL (NULL: critical, NULL returned); @obj may be NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure; the tree is not modified).
 * Ownership: the result is borrowed from @obj's tree.
 *
 * Returns: (transfer none) (nullable): the member when it exists and is an
 *   array; NULL if @obj is NULL, the member is missing, null or mistyped.
 */
JsonArray *wx_json_member_array(JsonObject *obj, const char *name);

/**
 * wx_json_member_string:
 * @obj: (nullable): object to read.
 * @name: member name.
 *
 * Returns the member @name of @obj when it is a JSON string.
 *
 * Preconditions:
 *  - @name is non-NULL (NULL: critical, NULL returned); @obj may be NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure; the tree is not modified).
 * Ownership: the result is borrowed from @obj's tree.
 *
 * Returns: (transfer none) (nullable): the NUL-terminated string when the
 *   member exists and is a JSON string (possibly ""); NULL if @obj is NULL,
 *   the member is missing, null or mistyped (a number or boolean is NOT
 *   converted). Its length is not bounded and it may contain control
 *   characters: use wx_sanitize_text() / wx_text_is_usable_name() before use.
 */
const char *wx_json_member_string(JsonObject *obj, const char *name);

/**
 * wx_json_node_number:
 * @node: (nullable): node to read.
 * @out: (out): receives the value on success.
 *
 * Reads a JSON number. Only integer and floating point nodes qualify (not
 * strings such as "12", not booleans); the value must be finite (a literal
 * like 1e999 overflows to infinity and is refused). json-glib saturates an
 * integer literal that does not fit 64 bits to G_MAXINT64 / G_MININT64, so
 * those two integer values are refused as well.
 *
 * Preconditions:
 *  - @out is non-NULL (NULL: critical, FALSE); @node may be NULL.
 * Postconditions:
 *  - on TRUE *@out holds the finite value; on FALSE *@out is untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @node is a finite number as described above.
 */
gboolean wx_json_node_number(JsonNode *node, double *out);

/**
 * wx_json_member_number:
 * @obj: (nullable): object to read.
 * @name: member name.
 * @out: (out): receives the value on success.
 *
 * wx_json_node_number() applied to the member @name of @obj.
 *
 * Preconditions:
 *  - @name and @out are non-NULL (NULL: critical, FALSE); @obj may be NULL.
 * Postconditions:
 *  - on TRUE *@out holds the finite value; on FALSE *@out is untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff the member exists and is a finite number (see
 *   wx_json_node_number()); FALSE for NULL @obj, missing, null or mistyped.
 */
gboolean wx_json_member_number(JsonObject *obj, const char *name, double *out);

/**
 * wx_json_number_in_range:
 * @node: (nullable): node to read.
 * @lo: inclusive lower bound.
 * @hi: inclusive upper bound.
 * @out: (out): receives the value on success.
 *
 * wx_json_node_number() followed by a range check, for values that are
 * stored only when plausible (the caller stores NAN on FALSE; out-of-range
 * data is dropped, never clamped).
 *
 * Preconditions:
 *  - @out is non-NULL (NULL: critical, FALSE); @node may be NULL; @lo and
 *    @hi are any doubles (a NAN bound makes every value fail).
 * Postconditions:
 *  - on TRUE *@out holds a finite value with lo <= value <= hi; on FALSE
 *    *@out is untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @node is a finite number within [@lo, @hi].
 */
gboolean wx_json_number_in_range(JsonNode *node, double lo, double hi, double *out);

/**
 * wx_json_error_reason:
 * @obj: (nullable): object to inspect (a parsed response root).
 * @max_chars: longest result in Unicode characters, 1..WX_JSON_REASON_CHARS_MAX.
 *
 * Recognises the keyless-API error shape {"error": true, "reason": "..."}
 * and returns a display-safe excerpt of the reason: control and bidirectional
 * formatting characters removed (wx_sanitize_text()), then cut to @max_chars
 * characters on a character boundary. The text is server-supplied: print it
 * only through "%s".
 *
 * Preconditions:
 *  - @max_chars is in [1, WX_JSON_REASON_CHARS_MAX] (violation: critical,
 *    NULL); @obj may be NULL.
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full) (nullable): NULL when @obj is NULL or has no
 *   member "error" that is the boolean true (not an error response);
 *   otherwise a newly allocated string (g_free()), "" when "reason" is
 *   missing, mistyped or empty after sanitising.
 */
char *wx_json_error_reason(JsonObject *obj, gsize max_chars);

G_END_DECLS

#endif /* WX_JSON_H */
