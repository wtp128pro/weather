/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-json.c - safe JSON access for untrusted response bodies. See wx-json.h. */
#include "wx-json.h"

#include <math.h>
#include <string.h>

#include "wx-text.h"
#include "wx-types.h"

/* The container kinds of the open levels are kept in one 32-bit mask. */
G_STATIC_ASSERT(WX_JSON_PARSE_MAX_DEPTH <= 32);
/* max_chars * 4 bytes (the longest UTF-8 character) must not overflow. */
G_STATIC_ASSERT((gsize)WX_JSON_REASON_CHARS_MAX * 4 < G_MAXSIZE / 2);

/* ------------------------------------------------------------------------ */
/* Strict RFC 8259 gate                                                     */
/* ------------------------------------------------------------------------ */

/* Read position inside the text being checked; both pointers stay within it. */
typedef struct {
  const char *p;
  const char *end;
} Cursor;

/**
 * skip_ws:
 * @c: (inout): cursor.
 *
 * Skips JSON whitespace (space, tab, line feed, carriage return).
 *
 * Preconditions:
 *  - @c->p <= @c->end, both inside one buffer.
 * Postconditions:
 *  - @c->p is at the first non-whitespace byte or at @c->end.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 */
static void
skip_ws(Cursor *c)
{
  while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r'))
    c->p++;
}

/**
 * scan_hex4:
 * @p: four readable bytes after "\u".
 * @out: (out): receives the value on success.
 *
 * Reads four hexadecimal digits.
 *
 * Preconditions:
 *  - @p points to 4 readable bytes.
 * Postconditions:
 *  - @out is written only on TRUE.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the four bytes are hexadecimal digits.
 */
static gboolean
scan_hex4(const char *p, guint32 *out)
{
  guint32 v = 0;
  for (int i = 0; i < 4; i++) {
    if (!g_ascii_isxdigit(p[i]))
      return FALSE;
    v = v * 16 + (guint32)g_ascii_xdigit_value(p[i]);
  }
  *out = v;
  return TRUE;
}

/**
 * scan_string:
 * @c: (inout): cursor at the opening quote of a string.
 * @out: (nullable): receives the decoded text (appended); NULL to only check.
 *
 * Checks one JSON string: no raw control character, only the escapes of
 * RFC 8259 (\u needs four hex digits) and no "\u0000" (a NUL cannot live in a
 * C string, so json-glib would silently truncate the value). An unpaired
 * surrogate escape is NOT checked here: json-glib refuses it, which fails the
 * document after this pass.
 *
 * Preconditions:
 *  - @c->p < @c->end and *@c->p == '"'.
 * Postconditions:
 *  - on TRUE @c->p is just after the closing quote and, when @out is set, the
 *    decoded UTF-8 text of the string was appended to it; on FALSE @c->p is
 *    unspecified (inside the text).
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff a valid string was scanned.
 */
static gboolean
scan_string(Cursor *c, GString *out)
{
  c->p++;
  while (c->p < c->end) {
    guchar ch = (guchar)*c->p++;
    if (ch == '"')
      return TRUE;
    if (ch < 0x20)
      return FALSE;
    if (ch != '\\') {
      if (out != NULL)
        g_string_append_c(out, (char)ch);
      continue;
    }
    if (c->p >= c->end)
      return FALSE;
    char esc = *c->p++;
    char plain = 0;
    switch (esc) {
    case '"':
    case '\\':
    case '/':
      plain = esc;
      break;
    case 'b':
      plain = '\b';
      break;
    case 'f':
      plain = '\f';
      break;
    case 'n':
      plain = '\n';
      break;
    case 'r':
      plain = '\r';
      break;
    case 't':
      plain = '\t';
      break;
    case 'u': {
      guint32 v;
      if (c->end - c->p < 4 || !scan_hex4(c->p, &v) || v == 0)
        return FALSE;
      c->p += 4;
      if (v >= 0xD800 && v <= 0xDFFF) {
        /* A surrogate pair is one character. An unpaired surrogate is refused by json-glib (which
         * makes the whole document fail after this pass); here it only has to decode to
         * something, so that the name comparison below stays total: U+FFFD. */
        guint32 low;
        if (v <= 0xDBFF && c->end - c->p >= 6 && c->p[0] == '\\' && c->p[1] == 'u' &&
            scan_hex4(c->p + 2, &low) && low >= 0xDC00 && low <= 0xDFFF) {
          c->p += 6;
          v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00);
        } else {
          v = 0xFFFD;
        }
      }
      if (out != NULL)
        g_string_append_unichar(out, v);
      continue;
    }
    default:
      return FALSE;
    }
    if (out != NULL)
      g_string_append_c(out, plain);
  }
  return FALSE;
}

/**
 * scan_digits:
 * @c: (inout): cursor.
 *
 * Consumes one or more ASCII digits.
 *
 * Preconditions:
 *  - @c->p <= @c->end, both inside one buffer.
 * Postconditions:
 *  - on TRUE @c->p is after the digits; on FALSE it is unchanged.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff at least one digit was consumed.
 */
static gboolean
scan_digits(Cursor *c)
{
  const char *start = c->p;
  while (c->p < c->end && g_ascii_isdigit(*c->p))
    c->p++;
  return c->p > start;
}

/**
 * scan_number:
 * @c: (inout): cursor at '-' or a digit.
 *
 * Checks one JSON number: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?. What
 * follows is checked by the caller (a stray digit after a leading zero is
 * then a syntax error).
 *
 * Preconditions:
 *  - @c->p < @c->end.
 * Postconditions:
 *  - on TRUE @c->p is after the number; on FALSE it is unspecified.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff a valid number was scanned.
 */
static gboolean
scan_number(Cursor *c)
{
  if (*c->p == '-')
    c->p++;
  if (c->p < c->end && *c->p == '0')
    c->p++;
  else if (!scan_digits(c))
    return FALSE;
  if (c->p < c->end && *c->p == '.') {
    c->p++;
    if (!scan_digits(c))
      return FALSE;
  }
  if (c->p < c->end && (*c->p == 'e' || *c->p == 'E')) {
    c->p++;
    if (c->p < c->end && (*c->p == '+' || *c->p == '-'))
      c->p++;
    if (!scan_digits(c))
      return FALSE;
  }
  return TRUE;
}

/**
 * scan_literal:
 * @c: (inout): cursor.
 * @word: "true", "false" or "null".
 *
 * Consumes @word.
 *
 * Preconditions:
 *  - @c->p <= @c->end; @word is a NUL-terminated literal.
 * Postconditions:
 *  - on TRUE @c->p is after the word; on FALSE it is unchanged.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff the text continues with exactly @word.
 */
static gboolean
scan_literal(Cursor *c, const char *word)
{
  gsize n = strlen(word);
  if ((gsize)(c->end - c->p) < n || memcmp(c->p, word, n) != 0)
    return FALSE;
  c->p += n;
  return TRUE;
}

/**
 * member_name_add:
 * @names: (inout): the set of member names of one open object; created on the
 *   first name.
 * @name: (not nullable): the decoded name just scanned.
 *
 * Records a member name. Rejecting a repeated name (RFC 8259 only says names
 * SHOULD be unique; json-glib answers a repeat with a linear search, which a
 * body of repeats turns into quadratic parse time) and an object with more than
 * WX_JSON_PARSE_MAX_MEMBERS members (a bound on the work of the hash set and
 * of json-glib's own tables) keeps the whole parse linear.
 *
 * Preconditions:
 *  - *@names is NULL or a set created by this function; @name is
 *    NUL-terminated.
 * Postconditions:
 *  - on TRUE the name is in the set; on FALSE (a repeat, or the member limit
 *    reached) the set is unchanged.
 * Thread affinity: any thread (pure).
 * Ownership: the set owns copies of the names; the caller owns the set.
 *
 * Returns: TRUE iff @name is new and the object may take one more member.
 */
static gboolean
member_name_add(GHashTable **names, const char *name)
{
  if (*names == NULL)
    *names = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  if (g_hash_table_size(*names) >= WX_JSON_PARSE_MAX_MEMBERS || g_hash_table_contains(*names, name))
    return FALSE;
  g_hash_table_add(*names, g_strdup(name));
  return TRUE;
}

/**
 * scan_key:
 * @c: (inout): cursor, where an object member name must start.
 * @scratch: (not nullable): buffer for the decoded name; its content is replaced.
 * @names: (inout): the member-name set of the object the name belongs to.
 *
 * Consumes `ws "name" ws :` and records the decoded name (member_name_add()).
 * Names that differ only in how a character is spelled ("a" and "\u0061") are
 * the same name.
 *
 * Preconditions:
 *  - @c->p <= @c->end.
 * Postconditions:
 *  - on TRUE @c->p is just after the colon; on FALSE it is unspecified.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff a new member name and its colon were scanned.
 */
static gboolean
scan_key(Cursor *c, GString *scratch, GHashTable **names)
{
  skip_ws(c);
  if (c->p >= c->end || *c->p != '"')
    return FALSE;
  g_string_truncate(scratch, 0);
  if (!scan_string(c, scratch) || !member_name_add(names, scratch->str))
    return FALSE;
  skip_ws(c);
  if (c->p >= c->end || *c->p != ':')
    return FALSE;
  c->p++;
  return TRUE;
}

/**
 * scan_document:
 * @c: (inout): cursor at the start of the text.
 * @scratch: (not nullable): buffer for decoded names.
 * @names: (inout): one member-name set per nesting level, all NULL on entry;
 *   the slot of an object that is still open may be non-NULL on return.
 *
 * Checks that the text is exactly one JSON value (RFC 8259, whitespace allowed
 * around it) nested at most WX_JSON_PARSE_MAX_DEPTH levels, without a repeated
 * member name and with at most WX_JSON_PARSE_MAX_MEMBERS members per object.
 * Iterative: the stack is a counter, a bit mask and the name sets, so hostile
 * nesting costs no recursion.
 *
 * Preconditions:
 *  - the text between @c->p and @c->end is readable and valid UTF-8.
 * Postconditions:
 *  - at most (end - p) bytes are read; the text is not modified.
 * Thread affinity: any thread (pure).
 * Ownership: the caller frees the sets left in @names.
 *
 * Returns: TRUE iff the text is one acceptable JSON value.
 */
static gboolean
scan_document(Cursor *c, GString *scratch, GHashTable *names[WX_JSON_PARSE_MAX_DEPTH])
{
  guint32 is_object = 0; /* bit (level - 1) set: that open container is an object */
  guint depth = 0;

  for (;;) {
    /* A value starts here. */
    skip_ws(c);
    if (c->p >= c->end)
      return FALSE;
    gboolean complete = TRUE; /* FALSE: a container was opened and has content */
    switch (*c->p) {
    case '{':
    case '[': {
      gboolean object = *c->p == '{';
      if (depth == WX_JSON_PARSE_MAX_DEPTH)
        return FALSE;
      depth++;
      guint32 bit = (guint32)1 << (depth - 1);
      is_object = object ? (is_object | bit) : (is_object & ~bit);
      c->p++;
      skip_ws(c);
      if (c->p < c->end && *c->p == (object ? '}' : ']')) {
        c->p++;
        depth--;
      } else {
        complete = FALSE;
        if (object && !scan_key(c, scratch, &names[depth - 1]))
          return FALSE;
      }
      break;
    }
    case '"':
      if (!scan_string(c, NULL))
        return FALSE;
      break;
    case 't':
      if (!scan_literal(c, "true"))
        return FALSE;
      break;
    case 'f':
      if (!scan_literal(c, "false"))
        return FALSE;
      break;
    case 'n':
      if (!scan_literal(c, "null"))
        return FALSE;
      break;
    default:
      if (!(*c->p == '-' || g_ascii_isdigit(*c->p)) || !scan_number(c))
        return FALSE;
      break;
    }
    if (!complete)
      continue;

    /* A value is complete: close containers and read the next separator. */
    for (;;) {
      skip_ws(c);
      if (depth == 0)
        return c->p == c->end;
      if (c->p >= c->end)
        return FALSE;
      gboolean object = (is_object >> (depth - 1)) & 1;
      if (*c->p == ',') {
        c->p++;
        if (object && !scan_key(c, scratch, &names[depth - 1]))
          return FALSE;
        break; /* the next member value starts */
      }
      if (*c->p != (object ? '}' : ']'))
        return FALSE;
      c->p++;
      g_clear_pointer(&names[depth - 1], g_hash_table_unref); /* the object is closed */
      depth--;
    }
  }
}

/**
 * json_text_is_strict:
 * @text: UTF-8 text (@len bytes, not necessarily NUL-terminated).
 * @len: number of bytes.
 *
 * Runs scan_document() and releases its scratch state.
 *
 * Preconditions:
 *  - @text points to @len readable bytes of valid UTF-8.
 * Postconditions:
 *  - nothing is modified; at most @len bytes are read; nothing leaks.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @text is one valid, shallow-enough JSON value without
 *   repeated member names.
 */
static gboolean
json_text_is_strict(const char *text, gsize len)
{
  Cursor c = {text, text + len};
  GHashTable *names[WX_JSON_PARSE_MAX_DEPTH] = {NULL};
  GString *scratch = g_string_new(NULL);
  gboolean ok = scan_document(&c, scratch, names);
  for (guint i = 0; i < WX_JSON_PARSE_MAX_DEPTH; i++)
    g_clear_pointer(&names[i], g_hash_table_unref);
  g_string_free(scratch, TRUE);
  return ok;
}

/* ------------------------------------------------------------------------ */
/* Parser                                                                   */
/* ------------------------------------------------------------------------ */

/* Documented in wx-json.h. */
JsonParser *
wx_json_parse(const guint8 *data, gsize len, gsize max_len, WxJsonRoot root, GError **error)
{
  g_return_val_if_fail(data != NULL || len == 0, NULL);
  g_return_val_if_fail(max_len >= 1 && max_len <= (gsize)G_MAXSSIZE, NULL);
  g_return_val_if_fail(root == WX_JSON_ROOT_OBJECT || root == WX_JSON_ROOT_ARRAY, NULL);
  g_return_val_if_fail(error == NULL || *error == NULL, NULL);

  if (len == 0) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "empty response");
    return NULL;
  }
  if (len > max_len) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response too large");
    return NULL;
  }
  const char *text = (const char *)data;
  if (!g_utf8_validate(text, (gssize)len, NULL)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "response is not valid UTF-8");
    return NULL;
  }
  if (!json_text_is_strict(text, len)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "malformed JSON");
    return NULL;
  }
  g_autoptr(JsonParser) parser = json_parser_new();
  if (!json_parser_load_from_data(parser, text, (gssize)len, NULL)) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE, "malformed JSON");
    return NULL;
  }
  JsonNode *node = json_parser_get_root(parser);
  gboolean ok = node != NULL && (root == WX_JSON_ROOT_OBJECT ? JSON_NODE_HOLDS_OBJECT(node)
                                                             : JSON_NODE_HOLDS_ARRAY(node));
  if (!ok) {
    g_set_error_literal(error, WX_ERROR, WX_ERROR_PARSE,
                        root == WX_JSON_ROOT_OBJECT ? "response is not a JSON object"
                                                    : "response is not a JSON array");
    return NULL;
  }
  return g_steal_pointer(&parser);
}

/* ------------------------------------------------------------------------ */
/* Accessors                                                                */
/* ------------------------------------------------------------------------ */

/* Documented in wx-json.h. */
JsonObject *
wx_json_member_object(JsonObject *obj, const char *name)
{
  g_return_val_if_fail(name != NULL, NULL);
  JsonNode *node = obj != NULL ? json_object_get_member(obj, name) : NULL;
  return (node != NULL && JSON_NODE_HOLDS_OBJECT(node)) ? json_node_get_object(node) : NULL;
}

/* Documented in wx-json.h. */
JsonArray *
wx_json_member_array(JsonObject *obj, const char *name)
{
  g_return_val_if_fail(name != NULL, NULL);
  JsonNode *node = obj != NULL ? json_object_get_member(obj, name) : NULL;
  return (node != NULL && JSON_NODE_HOLDS_ARRAY(node)) ? json_node_get_array(node) : NULL;
}

/* Documented in wx-json.h. */
const char *
wx_json_member_string(JsonObject *obj, const char *name)
{
  g_return_val_if_fail(name != NULL, NULL);
  JsonNode *node = obj != NULL ? json_object_get_member(obj, name) : NULL;
  if (node == NULL || !JSON_NODE_HOLDS_VALUE(node) ||
      json_node_get_value_type(node) != G_TYPE_STRING)
    return NULL;
  return json_node_get_string(node);
}

/* Documented in wx-json.h. */
gboolean
wx_json_node_number(JsonNode *node, double *out)
{
  g_return_val_if_fail(out != NULL, FALSE);
  if (node == NULL || !JSON_NODE_HOLDS_VALUE(node))
    return FALSE;
  GType type = json_node_get_value_type(node);
  if (type == G_TYPE_INT64) {
    gint64 v = json_node_get_int(node);
    if (v == G_MAXINT64 || v == G_MININT64)
      return FALSE;
    *out = (double)v;
    return TRUE;
  }
  if (type == G_TYPE_DOUBLE) {
    double d = json_node_get_double(node);
    if (!isfinite(d))
      return FALSE;
    *out = d;
    return TRUE;
  }
  return FALSE;
}

/* Documented in wx-json.h. */
gboolean
wx_json_member_number(JsonObject *obj, const char *name, double *out)
{
  g_return_val_if_fail(name != NULL, FALSE);
  g_return_val_if_fail(out != NULL, FALSE);
  return obj != NULL && wx_json_node_number(json_object_get_member(obj, name), out);
}

/* Documented in wx-json.h. */
gboolean
wx_json_number_in_range(JsonNode *node, double lo, double hi, double *out)
{
  g_return_val_if_fail(out != NULL, FALSE);
  double v;
  if (!wx_json_node_number(node, &v) || !wx_value_in_range(v, lo, hi))
    return FALSE;
  *out = v;
  return TRUE;
}

/* Documented in wx-json.h. */
char *
wx_json_error_reason(JsonObject *obj, gsize max_chars)
{
  g_return_val_if_fail(max_chars >= 1 && max_chars <= WX_JSON_REASON_CHARS_MAX, NULL);
  JsonNode *flag = obj != NULL ? json_object_get_member(obj, "error") : NULL;
  if (flag == NULL || !JSON_NODE_HOLDS_VALUE(flag) ||
      json_node_get_value_type(flag) != G_TYPE_BOOLEAN || !json_node_get_boolean(flag))
    return NULL;
  g_autofree char *clean = wx_sanitize_text(wx_json_member_string(obj, "reason"), max_chars * 4);
  return wx_truncated_copy(clean, max_chars);
}
