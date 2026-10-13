/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * Offline tests of WxHttp (request layer against a loopback fake server) and
 * wx-json (strict parsing of hostile bodies, safe accessors).
 *
 * The whole-operation deadline tests take 45 s of wall time by design; they
 * live under /http/deadline so meson runs them as a test of their own
 * (`test-http -p /http/deadline`) in parallel with everything else
 * (`test-http -x /http/deadline`).
 */
#include <gio/gio.h>
#include <glib.h>
#include <locale.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "wx-http.h"
#include "wx-json.h"
#include "wx-types.h"

/* Runs @check with the one critical that @fname's g_return_*_if_fail() logs expected. */
#define ASSERT_CRITICAL(fname, check)                                         \
  G_STMT_START {                                                              \
    g_test_expect_message(G_LOG_DOMAIN, G_LOG_LEVEL_CRITICAL, "*" fname "*"); \
    check;                                                                    \
    g_test_assert_expected_messages();                                        \
  }                                                                           \
  G_STMT_END

#define UA "weather-app/0.1 (github.com/wtp128pro/weather)"
#define JSON_ACCEPT "application/json"

/* ------------------------------------------------------------------------ */
/* Helpers                                                                  */
/* ------------------------------------------------------------------------ */

/*
 * A buffer of @len bytes that ends exactly at a PROT_NONE guard page: reading
 * even one byte beyond it faults. The mapping is released with guard_free().
 */
typedef struct {
  void *map;
  gsize map_len;
  char *data;
} Guarded;

static Guarded
guard_new(gsize len)
{
  gsize page = (gsize)sysconf(_SC_PAGESIZE);
  gsize pages = (len + page - 1) / page;
  if (pages == 0)
    pages = 1;
  gsize total = (pages + 1) * page;
  char *map = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  g_assert_true(map != MAP_FAILED);
  g_assert_cmpint(mprotect(map + pages * page, page, PROT_NONE), ==, 0);
  Guarded g = {map, total, map + pages * page - len};
  return g;
}

static void
guard_free(Guarded g)
{
  g_assert_cmpint(munmap(g.map, g.map_len), ==, 0);
}

static gint64
now_s(void)
{
  return g_get_real_time() / G_USEC_PER_SEC;
}

/* ------------------------------------------------------------------------ */
/* Part 1: wx-json                                                          */
/* ------------------------------------------------------------------------ */

#define BODY(str) ((const guint8 *)(str)), strlen(str)

static JsonParser *
parse_ok(const char *text, WxJsonRoot root)
{
  g_autoptr(GError) error = NULL;
  JsonParser *parser = wx_json_parse(BODY(text), 1024 * 1024, root, &error);
  g_assert_no_error(error);
  g_assert_nonnull(parser);
  return parser;
}

static void
assert_parse_error_len(const guint8 *data, gsize len, gsize max_len, WxJsonRoot root)
{
  g_autoptr(GError) error = NULL;
  JsonParser *parser = wx_json_parse(data, len, max_len, root, &error);
  g_assert_null(parser);
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
}

static void
assert_parse_error(const char *text, WxJsonRoot root)
{
  assert_parse_error_len(BODY(text), 1024 * 1024, root);
}

static JsonObject *
root_object(JsonParser *parser)
{
  return json_node_get_object(json_parser_get_root(parser));
}

static void
test_json_parse_accepts(void)
{
  static const char *const objects[] = {
      "{}",
      " \t\r\n{ }\n\r\t ",
      "{\"a\":1}",
      "{\"a\":-0}",
      "{\"a\":1E+5}",
      "{\"a\":1.5e-3}",
      "{\"a\":0.5,\"b\":10,\"c\":-12.25e2}",
      "{\"a\":[]}",
      "{\"a\":{}}",
      "{\"a\":[[],{},[{}]]}",
      "{\"a\":\"\\u0041\\u00e9\\ud83d\\ude00\\n\\/\\\\\\\"\\b\\f\\r\\t\"}",
      "{\"a\":\"\\u0001\\u001f\\u007f\"}",
      "{\"a\":null,\"b\":true,\"c\":false}",
      "{\"a\":1,\"A\":2}",
      "{\"\xc3\xa9\":\"\xc3\xbc\"}",
      "{\"a\":\"\xf0\x9f\x98\x80\"}",
      "{\"a\" : 1 , \"b\" : [ 1 , 2 ] }",
  };
  for (guint i = 0; i < G_N_ELEMENTS(objects); i++) {
    g_autoptr(JsonParser) parser = parse_ok(objects[i], WX_JSON_ROOT_OBJECT);
    g_assert_true(JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser)));
    assert_parse_error(objects[i], WX_JSON_ROOT_ARRAY); /* the root kind is enforced */
  }
  static const char *const arrays[] = {"[]", "[1,2,3]", "[{}]", " [ ] ", "[[[]]]", "[\"a\",null]"};
  for (guint i = 0; i < G_N_ELEMENTS(arrays); i++) {
    g_autoptr(JsonParser) parser = parse_ok(arrays[i], WX_JSON_ROOT_ARRAY);
    g_assert_true(JSON_NODE_HOLDS_ARRAY(json_parser_get_root(parser)));
    assert_parse_error(arrays[i], WX_JSON_ROOT_OBJECT);
  }

  /* Decoded values. */
  g_autoptr(JsonParser) parser =
      parse_ok("{\"s\":\"\\u0041\\u00e9\\ud83d\\ude00\\n\",\"n\":-12.25e2,\"i\":7}", WX_JSON_ROOT_OBJECT);
  JsonObject *obj = root_object(parser);
  g_assert_cmpstr(wx_json_member_string(obj, "s"), ==, "A\xc3\xa9\xf0\x9f\x98\x80\n");
  double d;
  g_assert_true(wx_json_member_number(obj, "n", &d));
  g_assert_cmpfloat(d, ==, -1225.0);
  g_assert_true(wx_json_member_number(obj, "i", &d));
  g_assert_cmpfloat(d, ==, 7.0);
}

static void
test_json_parse_rejects_grammar(void)
{
  static const char *const bad[] = {
      "",
      " ",
      "{",
      "}",
      "[",
      "]",
      "{}{}",
      "{} {}",
      "{}x",
      "{} x",
      "{}}",
      "[]]",
      "[1][2]",
      "{\"a\":1}{\"b\":2}",
      "{'a':1}",
      "{\"a\":'x'}",
      "{\"a\":1,}",
      "[1,]",
      "{,}",
      "[,1]",
      "[1,,2]",
      "{\"a\"}",
      "{\"a\":}",
      "{a:1}",
      "{1:1}",
      "{\"a\" 1}",
      "{\"a\":1 \"b\":2}",
      "[1 2]",
      "{\"a\":01}",
      "{\"a\":-01}",
      "{\"a\":+1}",
      "{\"a\":.5}",
      "{\"a\":1.}",
      "{\"a\":1e}",
      "{\"a\":1e+}",
      "{\"a\":0x10}",
      "{\"a\":--1}",
      "{\"a\":-}",
      "{\"a\":NaN}",
      "{\"a\":nan}",
      "{\"a\":Infinity}",
      "{\"a\":-Infinity}",
      "{\"a\":tru}",
      "{\"a\":True}",
      "{\"a\":nul}",
      "{\"a\":truefalse}",
      "{\"a\":\"\\x\"}",
      "{\"a\":\"\\u12\"}",
      "{\"a\":\"\\u12G4\"}",
      "{\"a\":\"\\u\"}",
      "{\"a\":\"\\",
      "{\"a\":\"abc}",
      "{\"a\":\"tab\there\"}",
      "{\"a\":\"nl\nx\"}",
      "{\"a\":\"\x01\"}",
      "// c\n{}",
      "/* c */{}",
      "#{}",
      "\xEF\xBB\xBF{}",
      "\x0b{}",
      "\f{}",
      "{}\x0b",
      "{\"a\":[1,2}",
      "{\"a\":{]}",
      "[}",
      "{\"a\":\"\\u0000\"}",
      "{\"a\":\"\\u0000x\"}",
      "{\"\\u0000\":1}",
      "{\"a\":\"\\uD800\"}",
      "{\"a\":\"\\uDC00\"}",
      "{\"a\":\"\\uD800\\u0041\"}",
      "{\"a\":\"\\uDC00\\uD800\"}",
      "{\"a\":\"\\uD800\\uD800\"}",
      "null",
      "true",
      "123",
      "\"s\"",
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad); i++) {
    assert_parse_error(bad[i], WX_JSON_ROOT_OBJECT);
    assert_parse_error(bad[i], WX_JSON_ROOT_ARRAY);
  }
  /* Raw DEL and C1 controls inside a string are legal JSON text. */
  g_autoptr(JsonParser) parser = parse_ok("{\"a\":\"\x7f\xc2\x80\"}", WX_JSON_ROOT_OBJECT);
  g_assert_cmpstr(wx_json_member_string(root_object(parser), "a"), ==, "\x7f\xc2\x80");
}

static void
assert_object_rejected_and_array_rejected(const char *text)
{
  assert_parse_error(text, WX_JSON_ROOT_OBJECT);
  assert_parse_error(text, WX_JSON_ROOT_ARRAY);
}

/* A repeated member name makes json-glib quadratic and the document ambiguous: refused. */
static void
test_json_duplicate_names(void)
{
  static const char *const duplicates[] = {
      "{\"a\":1,\"a\":2}",
      "{\"a\":1,\"a\":1}",
      "{\"a\":1,\"b\":2,\"a\":3}",
      "{\"\":1,\"\":2}",
      "{\"a\":1,\"\\u0061\":2}",         /* spelled differently, same name */
      "{\"\\u0061\":1,\"a\":2}",
      "{\"\\u00e9\":1,\"\xc3\xa9\":2}",
      "{\"\xc3\xa9\":1,\"\\u00E9\":2}",
      "{\"\\ud83d\\ude00\":1,\"\xf0\x9f\x98\x80\":2}",
      "{\"a\\/b\":1,\"a/b\":2}",
      "{\"a\\nb\":1,\"a\\u000ab\":2}",
      "{\"a\\\\b\":1,\"a\\u005cb\":2}",
      "{\"a\\\"\":1,\"a\\u0022\":2}",
      "{\"o\":{\"x\":1,\"x\":2}}",           /* in a nested object */
      "{\"o\":[{\"x\":1},{\"y\":1,\"y\":2}]}",
      "{\"o\":{\"x\":1},\"o\":{\"y\":2}}",   /* repeated name with object values */
      "{\"a\":{\"b\":1},\"c\":2,\"a\":3}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(duplicates); i++)
    assert_object_rejected_and_array_rejected(duplicates[i]);
  /* In an array's object as well. */
  assert_parse_error("[{\"a\":1,\"a\":2}]", WX_JSON_ROOT_ARRAY);
  assert_parse_error("[{\"a\":1},{\"b\":1,\"b\":2}]", WX_JSON_ROOT_ARRAY);
  assert_parse_error("[[{\"a\":1,\"a\":2}]]", WX_JSON_ROOT_ARRAY);

  /* The same name in different objects, and names that merely look alike, are fine. */
  static const char *const fine[] = {
      "{\"a\":{\"a\":1},\"b\":{\"a\":2}}",
      "{\"a\":1,\"A\":2}",
      "{\"a\":1,\"a \":2,\" a\":3,\"aa\":4,\"\":5}",
      "{\"a\":1,\"b\":{\"a\":2,\"b\":{\"a\":3}}}",
      "{\"\\u00e9\":1,\"e\":2,\"\\u00e8\":3}",
      "{\"a\\nb\":1,\"a\\\\nb\":2}",
      "{\"a\":[{\"x\":1},{\"x\":2},{\"x\":3}]}",
      "{\"x\":1,\"y\":{\"x\":1},\"z\":[{\"x\":1}]}",
  };
  for (guint i = 0; i < G_N_ELEMENTS(fine); i++) {
    g_autoptr(JsonParser) parser = parse_ok(fine[i], WX_JSON_ROOT_OBJECT);
    g_assert_nonnull(parser);
  }
  g_autoptr(JsonParser) arr = parse_ok("[{\"a\":1},{\"a\":2},{\"a\":3}]", WX_JSON_ROOT_ARRAY);
  g_assert_nonnull(arr);
  /* Names are scoped to an object: after one closes, its names are forgotten. */
  g_autoptr(JsonParser) reopened = parse_ok("{\"a\":{\"k\":1},\"b\":{\"k\":2},\"c\":[{\"k\":3},{\"k\":4}]}",
                                            WX_JSON_ROOT_OBJECT);
  g_assert_nonnull(reopened);
}

static char *
object_with_members(guint n, const char *prefix)
{
  GString *s = g_string_new("{");
  for (guint i = 0; i < n; i++)
    g_string_append_printf(s, "%s\"%s%u\":%u", i > 0 ? "," : "", prefix, i, i);
  g_string_append_c(s, '}');
  return g_string_free(s, FALSE);
}

static void
test_json_member_limit(void)
{
  g_assert_cmpuint(WX_JSON_PARSE_MAX_MEMBERS, ==, 1024);
  g_autofree char *at_limit = object_with_members(WX_JSON_PARSE_MAX_MEMBERS, "k");
  g_autofree char *over = object_with_members(WX_JSON_PARSE_MAX_MEMBERS + 1, "k");
  g_autoptr(JsonParser) p = parse_ok(at_limit, WX_JSON_ROOT_OBJECT);
  g_assert_cmpuint(json_object_get_size(root_object(p)), ==, WX_JSON_PARSE_MAX_MEMBERS);
  assert_parse_error(over, WX_JSON_ROOT_OBJECT);

  /* The limit is per object: a nest of objects that each sit at the limit is fine. */
  g_autofree char *inner = object_with_members(WX_JSON_PARSE_MAX_MEMBERS - 1, "i");
  g_autofree char *nested_at_limit = g_strdup_printf("{\"o1\":%s,\"o2\":%s,\"o3\":[%s,%s]}", inner, inner, inner, inner);
  g_autoptr(JsonParser) p2 = parse_ok(nested_at_limit, WX_JSON_ROOT_OBJECT);
  g_assert_nonnull(p2);
  /* ... and an inner object over the limit is refused. */
  g_autofree char *inner_over = g_strdup_printf("{\"o\":%s}", over);
  assert_parse_error(inner_over, WX_JSON_ROOT_OBJECT);
  /* Arrays have no member limit. */
  GString *big_array = g_string_new("[0");
  for (guint i = 1; i < 100000; i++)
    g_string_append_printf(big_array, ",%u", i);
  g_string_append_c(big_array, ']');
  g_autoptr(JsonParser) p3 = parse_ok(big_array->str, WX_JSON_ROOT_ARRAY);
  g_assert_cmpuint(json_array_get_length(json_node_get_array(json_parser_get_root(p3))), ==, 100000);
  g_string_free(big_array, TRUE);
}

/* Time of a parse that must be rejected or accepted quickly, in milliseconds. */
static gint64
parse_ms(const char *text, gsize len, gboolean expect_ok)
{
  gint64 start = g_get_monotonic_time();
  g_autoptr(GError) error = NULL;
  g_autoptr(JsonParser) parser =
      wx_json_parse((const guint8 *)text, len, len, WX_JSON_ROOT_OBJECT, &error);
  gint64 ms = (g_get_monotonic_time() - start) / 1000;
  g_assert_true((parser != NULL) == expect_ok);
  if (!expect_ok)
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  return ms;
}

/*
 * Time limit, in milliseconds, for a parse that must take one linear pass: @factor times the time the
 * same machine (and tool: valgrind, a sanitizer) needs for a 4 MiB valid array, plus one second. The
 * quadratic behaviour this guards against is ~1000 times slower than the baseline (minutes, not
 * milliseconds), so the bound separates the two whatever the speed of the environment.
 */
static gint64
limit_ms(gint64 factor)
{
  static gint64 baseline_ms = -1;
  if (baseline_ms < 0) {
    GString *array = g_string_sized_new(WX_HTTP_MAX_BODY_BYTES);
    g_string_append_c(array, '[');
    while (array->len + 3 < (gsize)WX_HTTP_MAX_BODY_BYTES)
      g_string_append(array, "0,");
    g_string_append(array, "0]");
    gint64 start = g_get_monotonic_time();
    g_autoptr(JsonParser) parser = wx_json_parse((const guint8 *)array->str, array->len, array->len,
                                                 WX_JSON_ROOT_ARRAY, NULL);
    baseline_ms = (g_get_monotonic_time() - start) / 1000;
    g_assert_nonnull(parser);
    g_string_free(array, TRUE);
  }
  return factor * baseline_ms + 1000;
}

/*
 * json-glib answers every repeated name with a linear search, so a 4 MiB body of repeated names took
 * minutes (~179 s for 184k distinct names followed by repeats of the last one). The gate refuses the
 * first repeat, so the time is that of one linear pass.
 */
static void
test_json_duplicate_flood_is_fast(void)
{
  const gsize cap = (gsize)WX_HTTP_MAX_BODY_BYTES;
  /* (a) one name repeated for the whole body, (b) many distinct names, then repeats of the last. */
  GString *flood = g_string_sized_new(cap);
  g_string_append(flood, "{\"k\":0");
  while (flood->len + 7 < cap)
    g_string_append(flood, ",\"k\":0");
  g_string_append_c(flood, '}');
  g_assert_cmpuint(flood->len, >, cap - 16);
  g_assert_cmpint(parse_ms(flood->str, flood->len, FALSE), <, limit_ms(20));
  g_string_free(flood, TRUE);

  GString *mixed = g_string_sized_new(cap);
  g_string_append(mixed, "{\"k0\":0");
  for (guint i = 1; i < WX_JSON_PARSE_MAX_MEMBERS; i++)
    g_string_append_printf(mixed, ",\"k%u\":0", i);
  while (mixed->len + 12 < cap)
    g_string_append(mixed, ",\"k1023\":0");
  g_string_append_c(mixed, '}');
  g_assert_cmpint(parse_ms(mixed->str, mixed->len, FALSE), <, limit_ms(20));
  g_string_free(mixed, TRUE);

  /* (c) one distinct member beyond the limit followed by 4 MiB of members: stops at the limit. */
  GString *many = g_string_sized_new(cap);
  g_string_append(many, "{\"k0\":0");
  for (guint i = 1; many->len + 16 < cap; i++)
    g_string_append_printf(many, ",\"k%u\":0", i);
  g_string_append_c(many, '}');
  g_assert_cmpint(parse_ms(many->str, many->len, FALSE), <, limit_ms(20));
  g_string_free(many, TRUE);

  /* (d) a large, valid document: 100000 small objects in an array, and 1024-member objects. */
  GString *objects = g_string_new("{\"a\":[");
  for (guint i = 0; i < 100000; i++)
    g_string_append_printf(objects, "%s{\"x\":%u,\"y\":[1,2,3]}", i > 0 ? "," : "", i);
  g_string_append(objects, "]}");
  g_assert_cmpint(parse_ms(objects->str, objects->len, TRUE), <, limit_ms(100));
  g_string_free(objects, TRUE);
}

/* 2^n names that all have the same g_str_hash value (djb2: "Ez" and "FY" collide, so every
 * concatenation of such blocks does): a hash-flooding attempt against json-glib's own tables. */
static char *
colliding_object(guint members)
{
  guint bits = 1;
  while ((1u << bits) < members)
    bits++;
  GString *s = g_string_new("{");
  for (guint i = 0; i < members; i++) {
    g_string_append(s, i > 0 ? ",\"" : "\"");
    for (guint b = 0; b < bits; b++)
      g_string_append(s, (i >> b) & 1 ? "FY" : "Ez");
    g_string_append(s, "\":0");
  }
  g_string_append_c(s, '}');
  return g_string_free(s, FALSE);
}

static void
test_json_hash_collisions_are_bounded(void)
{
  g_assert_cmpuint(g_str_hash("Ez"), ==, g_str_hash("FY")); /* the premise */
  g_autofree char *at_limit = colliding_object(WX_JSON_PARSE_MAX_MEMBERS);
  g_autofree char *over = colliding_object(WX_JSON_PARSE_MAX_MEMBERS + 1);
  /* Every name of the first object has the same hash; the bound keeps the cost trivial. */
  g_assert_cmpint(parse_ms(at_limit, strlen(at_limit), TRUE), <, limit_ms(20));
  g_assert_cmpint(parse_ms(over, strlen(over), FALSE), <, limit_ms(20));
  /* And the 1024 colliding names really are distinct members. */
  g_autoptr(JsonParser) p = parse_ok(at_limit, WX_JSON_ROOT_OBJECT);
  g_assert_cmpuint(json_object_get_size(root_object(p)), ==, WX_JSON_PARSE_MAX_MEMBERS);

  /* The most hash-flooding a body can hold: as many objects of colliding names as fit the cap. */
  gsize one = strlen(at_limit);
  GString *array = g_string_sized_new(WX_HTTP_MAX_BODY_BYTES);
  g_string_append_c(array, '[');
  for (guint i = 0; array->len + one + 2 < (gsize)WX_HTTP_MAX_BODY_BYTES; i++)
    g_string_append_printf(array, "%s%s", i > 0 ? "," : "", at_limit);
  g_string_append_c(array, ']');
  gint64 start = g_get_monotonic_time();
  g_autoptr(JsonParser) flooded =
      wx_json_parse((const guint8 *)array->str, array->len, array->len, WX_JSON_ROOT_ARRAY, NULL);
  gint64 ms = (g_get_monotonic_time() - start) / 1000;
  g_assert_nonnull(flooded);
  g_assert_cmpuint(json_array_get_length(json_node_get_array(json_parser_get_root(flooded))), >, 150);
  g_assert_cmpint(ms, <, limit_ms(500));
  g_string_free(array, TRUE);
}

static void
test_json_parse_rejects_encoding_and_size(void)
{
  g_autoptr(GError) error = NULL;
  /* Empty. */
  g_assert_null(wx_json_parse(NULL, 0, 10, WX_JSON_ROOT_OBJECT, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  g_assert_null(wx_json_parse((const guint8 *)"{}", 0, 10, WX_JSON_ROOT_OBJECT, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
  g_clear_error(&error);
  /* NULL error location is fine. */
  g_assert_null(wx_json_parse(NULL, 0, 10, WX_JSON_ROOT_OBJECT, NULL));

  /* Size: len == max_len is accepted, one more is not (nothing is examined). */
  g_autoptr(JsonParser) parser = wx_json_parse(BODY("{}"), 2, WX_JSON_ROOT_OBJECT, &error);
  g_assert_no_error(error);
  g_assert_nonnull(parser);
  assert_parse_error_len(BODY("{}"), 1, WX_JSON_ROOT_OBJECT);
  assert_parse_error_len(BODY("\xff\xff\xff"), 2, WX_JSON_ROOT_OBJECT); /* size before UTF-8 */
  g_assert_null(wx_json_parse(BODY("{}"), 1, WX_JSON_ROOT_OBJECT, &error));
  g_assert_nonnull(strstr(error->message, "too large"));
  g_clear_error(&error);

  /* Invalid UTF-8: stray bytes, overlong, truncated, surrogate, > U+10FFFF, embedded NUL. */
  static const struct {
    const char *data;
    gsize len;
  } bad_utf8[] = {
      {"{\"a\":\"\xff\"}", 8},
      {"{\"a\":\"\xc0\xaf\"}", 9},
      {"{\"a\":\"\xe2\x82\"}", 9},
      {"{\"a\":\"\xed\xa0\x80\"}", 10},
      {"{\"a\":\"\xf4\x90\x80\x80\"}", 11},
      {"{\"a\":\"\x80\"}", 8},
      {"{\"a\":\"a\0b\"}", 10},
      {"{}\0", 3},
      {"\0{}", 3},
  };
  for (guint i = 0; i < G_N_ELEMENTS(bad_utf8); i++) {
    g_assert_null(wx_json_parse((const guint8 *)bad_utf8[i].data, bad_utf8[i].len, 1024,
                                WX_JSON_ROOT_OBJECT, &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_PARSE);
    g_clear_error(&error);
  }

  /* Error messages never echo the body. */
  g_assert_null(wx_json_parse(BODY("{\"SECRET-TEXT\":}"), 1024, WX_JSON_ROOT_OBJECT, &error));
  g_assert_null(strstr(error->message, "SECRET"));
  g_clear_error(&error);
  g_assert_null(wx_json_parse(BODY("[\"SECRET-TEXT\"]"), 1024, WX_JSON_ROOT_OBJECT, &error));
  g_assert_null(strstr(error->message, "SECRET"));
  g_clear_error(&error);
  g_assert_null(wx_json_parse(BODY("\"SECRET-TEXT\""), 1024, WX_JSON_ROOT_OBJECT, &error));
  g_assert_null(strstr(error->message, "SECRET"));
  g_clear_error(&error);
}

static void
test_json_parse_programmer_errors(void)
{
  g_autoptr(GError) error = NULL;
  g_autoptr(GError) preset = g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "x");
  ASSERT_CRITICAL("wx_json_parse", g_assert_null(wx_json_parse(NULL, 5, 10, WX_JSON_ROOT_OBJECT, &error)));
  ASSERT_CRITICAL("wx_json_parse", g_assert_null(wx_json_parse(BODY("{}"), 0, WX_JSON_ROOT_OBJECT, &error)));
  ASSERT_CRITICAL("wx_json_parse",
                  g_assert_null(wx_json_parse(BODY("{}"), (gsize)G_MAXSSIZE + 1, WX_JSON_ROOT_OBJECT, &error)));
  ASSERT_CRITICAL("wx_json_parse", g_assert_null(wx_json_parse(BODY("{}"), 10, (WxJsonRoot)7, &error)));
  ASSERT_CRITICAL("wx_json_parse",
                  g_assert_null(wx_json_parse(BODY("{}"), 10, WX_JSON_ROOT_OBJECT, &preset)));
  g_assert_no_error(error);
}

/* A document of exactly @depth nested containers: arrays, or objects {"a":{"a":...{}...}}. */
static char *
nested(gboolean objects, guint depth)
{
  GString *s = g_string_new(NULL);
  for (guint i = 0; i + 1 < depth; i++)
    g_string_append(s, objects ? "{\"a\":" : "[");
  g_string_append(s, objects ? "{}" : "[]");
  for (guint i = 0; i + 1 < depth; i++)
    g_string_append_c(s, objects ? '}' : ']');
  return g_string_free(s, FALSE);
}

static void
test_json_parse_depth(void)
{
  g_assert_cmpuint(WX_JSON_PARSE_MAX_DEPTH, ==, 32);
  /* The root container is level 1: 32 levels are accepted, 33 are not. */
  for (guint objects = 0; objects < 2; objects++) {
    WxJsonRoot root = objects ? WX_JSON_ROOT_OBJECT : WX_JSON_ROOT_ARRAY;
    g_autofree char *one = nested(objects, 1);
    g_autofree char *at_limit = nested(objects, WX_JSON_PARSE_MAX_DEPTH);
    g_autofree char *over = nested(objects, WX_JSON_PARSE_MAX_DEPTH + 1);
    g_autoptr(JsonParser) p1 = parse_ok(one, root);
    g_autoptr(JsonParser) p2 = parse_ok(at_limit, root);
    assert_parse_error(over, root);
  }

  /* Hostile nesting: 200000 openers, unterminated, and a whole 4 MiB of them. */
  gsize big = 200000;
  g_autofree char *opens = g_malloc(big);
  memset(opens, '[', big);
  assert_parse_error_len((const guint8 *)opens, big, 1024 * 1024, WX_JSON_ROOT_ARRAY);
  assert_parse_error_len((const guint8 *)opens, big, 1024 * 1024, WX_JSON_ROOT_OBJECT);
  gsize huge = WX_HTTP_MAX_BODY_BYTES;
  g_autofree char *many = g_malloc(huge);
  memset(many, '{', huge);
  assert_parse_error_len((const guint8 *)many, huge, huge, WX_JSON_ROOT_OBJECT);
  g_autofree char *mixed = g_malloc(big);
  for (gsize i = 0; i < big; i++)
    mixed[i] = (i % 2) ? '[' : '{';
  assert_parse_error_len((const guint8 *)mixed, big, big, WX_JSON_ROOT_OBJECT);
  g_autofree char *quoted = g_malloc(big * 5);
  for (gsize i = 0; i < big; i++)
    memcpy(quoted + i * 5, "{\"a\":", 5);
  assert_parse_error_len((const guint8 *)quoted, big * 5, big * 5, WX_JSON_ROOT_OBJECT);
}

static void
test_json_accessors(void)
{
  g_autoptr(JsonParser) parser = parse_ok(
      "{\"o\":{\"x\":1},\"a\":[1,2],\"s\":\"text\",\"e\":\"\",\"n\":1.5,\"i\":-3,\"b\":true,\"z\":null,"
      "\"big\":12345678901234567890,\"nbig\":-12345678901234567890,\"max\":9223372036854775807,"
      "\"min\":-9223372036854775808,\"ok\":9223372036854775806,\"inf\":1e999,\"ninf\":-1e999,"
      "\"str\":\"12\"}",
      WX_JSON_ROOT_OBJECT);
  JsonObject *obj = root_object(parser);

  /* Types: only the right one is returned, everything else is NULL / FALSE. */
  g_assert_nonnull(wx_json_member_object(obj, "o"));
  g_assert_null(wx_json_member_object(obj, "a"));
  g_assert_null(wx_json_member_object(obj, "s"));
  g_assert_null(wx_json_member_object(obj, "z"));
  g_assert_null(wx_json_member_object(obj, "missing"));
  g_assert_nonnull(wx_json_member_array(obj, "a"));
  g_assert_cmpuint(json_array_get_length(wx_json_member_array(obj, "a")), ==, 2);
  g_assert_null(wx_json_member_array(obj, "o"));
  g_assert_null(wx_json_member_array(obj, "n"));
  g_assert_null(wx_json_member_array(obj, "z"));
  g_assert_null(wx_json_member_array(obj, "missing"));
  g_assert_cmpstr(wx_json_member_string(obj, "s"), ==, "text");
  g_assert_cmpstr(wx_json_member_string(obj, "e"), ==, "");
  g_assert_null(wx_json_member_string(obj, "n"));
  g_assert_null(wx_json_member_string(obj, "b"));
  g_assert_null(wx_json_member_string(obj, "o"));
  g_assert_null(wx_json_member_string(obj, "z"));
  g_assert_null(wx_json_member_string(obj, "missing"));

  /* NULL objects are tolerated. */
  g_assert_null(wx_json_member_object(NULL, "o"));
  g_assert_null(wx_json_member_array(NULL, "a"));
  g_assert_null(wx_json_member_string(NULL, "s"));
  double d = 99.0;
  g_assert_false(wx_json_member_number(NULL, "n", &d));
  g_assert_false(wx_json_node_number(NULL, &d));
  g_assert_false(wx_json_number_in_range(NULL, 0, 1, &d));
  g_assert_cmpfloat(d, ==, 99.0);

  /* Numbers. */
  g_assert_true(wx_json_member_number(obj, "n", &d));
  g_assert_cmpfloat(d, ==, 1.5);
  g_assert_true(wx_json_member_number(obj, "i", &d));
  g_assert_cmpfloat(d, ==, -3.0);
  g_assert_true(wx_json_member_number(obj, "ok", &d));
  g_assert_cmpfloat(d, ==, 9223372036854775806.0);
  d = 99.0;
  static const char *const refused[] = {"s",    "str", "b",   "z",   "o",    "a",   "missing", "e",
                                        "big",  "nbig", "max", "min", "inf",  "ninf"};
  for (guint i = 0; i < G_N_ELEMENTS(refused); i++) {
    g_assert_false(wx_json_member_number(obj, refused[i], &d));
    g_assert_cmpfloat(d, ==, 99.0); /* untouched on failure */
  }
  JsonNode *node = json_object_get_member(obj, "n");
  g_assert_true(wx_json_node_number(node, &d));
  g_assert_cmpfloat(d, ==, 1.5);
  g_assert_false(wx_json_node_number(json_object_get_member(obj, "s"), &d));

  /* NULL arguments that are programmer errors. */
  ASSERT_CRITICAL("wx_json_member_object", g_assert_null(wx_json_member_object(obj, NULL)));
  ASSERT_CRITICAL("wx_json_member_array", g_assert_null(wx_json_member_array(obj, NULL)));
  ASSERT_CRITICAL("wx_json_member_string", g_assert_null(wx_json_member_string(obj, NULL)));
  ASSERT_CRITICAL("wx_json_member_number", g_assert_false(wx_json_member_number(obj, NULL, &d)));
  ASSERT_CRITICAL("wx_json_member_number", g_assert_false(wx_json_member_number(obj, "n", NULL)));
  ASSERT_CRITICAL("wx_json_node_number", g_assert_false(wx_json_node_number(node, NULL)));
  ASSERT_CRITICAL("wx_json_number_in_range", g_assert_false(wx_json_number_in_range(node, 0, 2, NULL)));
}

static void
test_json_number_in_range(void)
{
  g_autoptr(JsonParser) parser =
      parse_ok("{\"v\":5,\"f\":5.5,\"neg\":-40.0,\"inf\":1e999,\"s\":\"5\"}", WX_JSON_ROOT_OBJECT);
  JsonObject *obj = root_object(parser);
  JsonNode *v = json_object_get_member(obj, "v");
  JsonNode *f = json_object_get_member(obj, "f");
  double d = -1.0;
  g_assert_true(wx_json_number_in_range(v, 5.0, 5.0, &d)); /* both bounds inclusive */
  g_assert_cmpfloat(d, ==, 5.0);
  g_assert_true(wx_json_number_in_range(f, 0.0, 5.5, &d));
  g_assert_cmpfloat(d, ==, 5.5);
  g_assert_true(wx_json_number_in_range(f, 5.5, 100.0, &d));
  d = -1.0;
  g_assert_false(wx_json_number_in_range(v, 5.1, 10.0, &d));
  g_assert_false(wx_json_number_in_range(v, 0.0, 4.9, &d));
  g_assert_false(wx_json_number_in_range(v, 10.0, 0.0, &d)); /* empty range */
  g_assert_false(wx_json_number_in_range(v, NAN, 10.0, &d));
  g_assert_false(wx_json_number_in_range(v, 0.0, NAN, &d));
  g_assert_false(wx_json_number_in_range(json_object_get_member(obj, "inf"), -INFINITY, INFINITY, &d));
  g_assert_false(wx_json_number_in_range(json_object_get_member(obj, "s"), 0.0, 10.0, &d));
  g_assert_cmpfloat(d, ==, -1.0); /* untouched on every failure */
  g_assert_true(wx_json_number_in_range(json_object_get_member(obj, "neg"), WX_TEMP_MIN_C,
                                        WX_TEMP_MAX_C, &d));
  g_assert_cmpfloat(d, ==, -40.0);
}

static void
test_json_error_reason_real(void)
{
  g_autoptr(JsonParser) parser = parse_ok(
      "{\"a\":{\"error\":true,\"reason\":\"Cannot initialize WeatherVariable\"},"
      "\"b\":{\"error\":true},"
      "\"c\":{\"error\":true,\"reason\":42},"
      "\"d\":{\"error\":false,\"reason\":\"no\"},"
      "\"e\":{\"error\":\"true\",\"reason\":\"no\"},"
      "\"f\":{\"reason\":\"no\"},"
      "\"g\":{\"error\":true,\"reason\":\"a\\u0001b\\u202ec\\u2066d\\u0085e\"},"
      "\"h\":{\"error\":true,\"reason\":\"\\u0007\\u202e\"},"
      "\"i\":{\"error\":true,\"reason\":\"\xf0\x9f\x98\x80\xf0\x9f\x98\x80\xf0\x9f\x98\x80\"},"
      "\"j\":{\"error\":1,\"reason\":\"no\"},"
      "\"k\":{\"error\":null,\"reason\":\"no\"},"
      "\"l\":{\"error\":true,\"reason\":\"%s%n %d\"}}",
      WX_JSON_ROOT_OBJECT);
  JsonObject *obj = root_object(parser);
  char *r;
  r = wx_json_error_reason(wx_json_member_object(obj, "a"), 80);
  g_assert_cmpstr(r, ==, "Cannot initialize WeatherVariable");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "a"), 6); /* cut to 6 characters */
  g_assert_cmpstr(r, ==, "Cannot");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "a"), 1);
  g_assert_cmpstr(r, ==, "C");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "b"), 80); /* error without reason */
  g_assert_cmpstr(r, ==, "");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "c"), 80); /* reason of the wrong type */
  g_assert_cmpstr(r, ==, "");
  g_free(r);
  const char *not_errors[] = {"d", "e", "f", "j", "k"};
  for (guint i = 0; i < G_N_ELEMENTS(not_errors); i++)
    g_assert_null(wx_json_error_reason(wx_json_member_object(obj, not_errors[i]), 80));
  g_assert_null(wx_json_error_reason(NULL, 80));
  /* Controls and bidi overrides are removed, then the text is cut. */
  r = wx_json_error_reason(wx_json_member_object(obj, "g"), 80);
  g_assert_cmpstr(r, ==, "abcde");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "g"), 3);
  g_assert_cmpstr(r, ==, "abc");
  g_free(r);
  r = wx_json_error_reason(wx_json_member_object(obj, "h"), 80);
  g_assert_cmpstr(r, ==, "");
  g_free(r);
  /* Cut on a character boundary, never inside a UTF-8 sequence. */
  r = wx_json_error_reason(wx_json_member_object(obj, "i"), 2);
  g_assert_cmpstr(r, ==, "\xf0\x9f\x98\x80\xf0\x9f\x98\x80");
  g_assert_true(g_utf8_validate(r, -1, NULL));
  g_free(r);
  /* A format string stays data. */
  r = wx_json_error_reason(wx_json_member_object(obj, "l"), 80);
  g_assert_cmpstr(r, ==, "%s%n %d");
  g_free(r);
  /* The longest accepted limit works on a long reason. */
  GString *long_reason = g_string_new("{\"error\":true,\"reason\":\"");
  for (guint i = 0; i < 5000; i++)
    g_string_append(long_reason, "\xf0\x9f\x98\x80");
  g_string_append(long_reason, "\"}");
  g_autoptr(JsonParser) lp = parse_ok(long_reason->str, WX_JSON_ROOT_OBJECT);
  r = wx_json_error_reason(root_object(lp), WX_JSON_REASON_CHARS_MAX);
  g_assert_cmpuint(g_utf8_strlen(r, -1), ==, WX_JSON_REASON_CHARS_MAX);
  g_assert_cmpuint(strlen(r), ==, WX_JSON_REASON_CHARS_MAX * 4);
  g_free(r);
  g_string_free(long_reason, TRUE);

  ASSERT_CRITICAL("wx_json_error_reason", g_assert_null(wx_json_error_reason(obj, 0)));
  ASSERT_CRITICAL("wx_json_error_reason",
                  g_assert_null(wx_json_error_reason(obj, WX_JSON_REASON_CHARS_MAX + 1)));
}

/* --- differential fuzz against an independent recursive reference --------- */

/* Reference RFC 8259 validator (recursive, structurally unlike the production
 * scanner). Reports the root kind through *root_kind: '{', '[' or 0. */
typedef struct {
  const char *p;
  const char *end;
} Ref;

/* Non-vacuity counters of the differential fuzz test. */
static guint fuzz_accepted, fuzz_dup_refused;

static void
ref_ws(Ref *r)
{
  while (r->p < r->end && strchr(" \t\r\n", *r->p) != NULL && *r->p != '\0')
    r->p++;
}

static int
ref_hex4(const char *p)
{
  int v = 0;
  for (int i = 0; i < 4; i++) {
    int c = (guchar)p[i];
    int digit;
    if (c >= '0' && c <= '9')
      digit = c - '0';
    else if (c >= 'a' && c <= 'f')
      digit = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F')
      digit = c - 'A' + 10;
    else
      return -1;
    v = v * 16 + digit;
  }
  return v;
}

static gboolean
ref_string(Ref *r)
{
  if (r->p >= r->end || *r->p != '"')
    return FALSE;
  r->p++;
  while (r->p < r->end) {
    guchar c = (guchar)*r->p++;
    if (c == '"')
      return TRUE;
    if (c < 0x20)
      return FALSE;
    if (c != '\\')
      continue;
    if (r->p >= r->end)
      return FALSE;
    char e = *r->p++;
    if (e == 'u') {
      if (r->end - r->p < 4)
        return FALSE;
      int v = ref_hex4(r->p);
      if (v <= 0) /* bad hex, or U+0000 (refused: a C string cannot hold it) */
        return FALSE;
      r->p += 4;
      if (v >= 0xDC00 && v <= 0xDFFF)
        return FALSE; /* lone low surrogate */
      if (v >= 0xD800 && v <= 0xDBFF) {
        if (r->end - r->p < 6 || r->p[0] != '\\' || r->p[1] != 'u')
          return FALSE;
        int lo = ref_hex4(r->p + 2);
        if (lo < 0xDC00 || lo > 0xDFFF)
          return FALSE;
        r->p += 6;
      }
    } else if (e == '\0' || strchr("\"\\/bfnrt", e) == NULL) {
      return FALSE;
    }
  }
  return FALSE;
}

static gboolean
ref_number(Ref *r)
{
  const char *p = r->p;
  if (p < r->end && *p == '-')
    p++;
  if (p >= r->end)
    return FALSE;
  if (*p == '0') {
    p++;
  } else if (*p >= '1' && *p <= '9') {
    while (p < r->end && g_ascii_isdigit(*p))
      p++;
  } else {
    return FALSE;
  }
  if (p < r->end && *p == '.') {
    p++;
    if (p >= r->end || !g_ascii_isdigit(*p))
      return FALSE;
    while (p < r->end && g_ascii_isdigit(*p))
      p++;
  }
  if (p < r->end && (*p == 'e' || *p == 'E')) {
    p++;
    if (p < r->end && (*p == '+' || *p == '-'))
      p++;
    if (p >= r->end || !g_ascii_isdigit(*p))
      return FALSE;
    while (p < r->end && g_ascii_isdigit(*p))
      p++;
  }
  r->p = p;
  return TRUE;
}

static gboolean ref_value(Ref *r, guint depth);

static gboolean
ref_word(Ref *r, const char *w)
{
  gsize n = strlen(w);
  if ((gsize)(r->end - r->p) < n || memcmp(r->p, w, n) != 0)
    return FALSE;
  r->p += n;
  return TRUE;
}

/* The decoded text of the (already validated) JSON string whose body is [p, end), where @end is
 * the closing quote. Written independently of the production scanner: a plain state machine. */
static char *
ref_decode(const char *p, const char *end)
{
  GString *out = g_string_new(NULL);
  while (p < end) {
    if (*p != '\\') {
      g_string_append_c(out, *p++);
      continue;
    }
    char e = p[1];
    p += 2;
    if (e == 'u') {
      gunichar v = (gunichar)ref_hex4(p);
      p += 4;
      if (v >= 0xD800 && v <= 0xDBFF) {
        gunichar lo = (gunichar)ref_hex4(p + 2);
        p += 6;
        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00);
      }
      g_string_append_unichar(out, v);
    } else {
      const char *from = "bfnrt";
      const char *to = "\b\f\n\r\t";
      const char *hit = strchr(from, e);
      g_string_append_c(out, (hit != NULL && e != '\0') ? to[hit - from] : e);
    }
  }
  return g_string_free(out, FALSE);
}

static gboolean
ref_container(Ref *r, guint depth, char open, char close)
{
  if (depth > WX_JSON_PARSE_MAX_DEPTH)
    return FALSE;
  r->p++; /* the opener */
  ref_ws(r);
  if (r->p < r->end && *r->p == close) {
    r->p++;
    return TRUE;
  }
  g_autoptr(GHashTable) names = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  for (;;) {
    ref_ws(r);
    if (open == '{') {
      const char *start = r->p;
      if (!ref_string(r))
        return FALSE;
      /* A repeated name, or more than WX_JSON_PARSE_MAX_MEMBERS members, is refused. */
      char *name = ref_decode(start + 1, r->p - 1);
      if (g_hash_table_contains(names, name) || g_hash_table_size(names) >= WX_JSON_PARSE_MAX_MEMBERS) {
        fuzz_dup_refused++;
        g_free(name);
        return FALSE;
      }
      g_hash_table_add(names, name);
      ref_ws(r);
      if (r->p >= r->end || *r->p != ':')
        return FALSE;
      r->p++;
      ref_ws(r);
    }
    if (!ref_value(r, depth + 1))
      return FALSE;
    ref_ws(r);
    if (r->p >= r->end)
      return FALSE;
    if (*r->p == ',') {
      r->p++;
      continue;
    }
    if (*r->p == close) {
      r->p++;
      return TRUE;
    }
    return FALSE;
  }
}

static gboolean
ref_value(Ref *r, guint depth)
{
  if (r->p >= r->end)
    return FALSE;
  switch (*r->p) {
  case '{':
    return ref_container(r, depth, '{', '}');
  case '[':
    return ref_container(r, depth, '[', ']');
  case '"':
    return ref_string(r);
  case 't':
    return ref_word(r, "true");
  case 'f':
    return ref_word(r, "false");
  case 'n':
    return ref_word(r, "null");
  default:
    return ref_number(r);
  }
}

/* Returns '{' or '[' for a document that is exactly one valid container, else 0. */
static char
ref_root_kind(const char *text, gsize len)
{
  Ref r = {text, text + len};
  ref_ws(&r);
  if (r.p >= r.end || (*r.p != '{' && *r.p != '['))
    return 0;
  char kind = *r.p;
  if (!ref_value(&r, 1))
    return 0;
  ref_ws(&r);
  return r.p == r.end ? kind : 0;
}

static void
assert_strings_valid(JsonNode *node)
{
  if (node == NULL)
    return;
  if (JSON_NODE_HOLDS_VALUE(node)) {
    if (json_node_get_value_type(node) == G_TYPE_STRING)
      g_assert_true(g_utf8_validate(json_node_get_string(node), -1, NULL));
  } else if (JSON_NODE_HOLDS_OBJECT(node)) {
    JsonObject *o = json_node_get_object(node);
    GList *members = json_object_get_members(o);
    for (GList *l = members; l != NULL; l = l->next) {
      g_assert_true(g_utf8_validate(l->data, -1, NULL));
      assert_strings_valid(json_object_get_member(o, l->data));
    }
    g_list_free(members);
  } else if (JSON_NODE_HOLDS_ARRAY(node)) {
    JsonArray *a = json_node_get_array(node);
    for (guint i = 0; i < json_array_get_length(a); i++)
      assert_strings_valid(json_array_get_element(a, i));
  }
}

/* Feeds @text (any bytes) to both implementations and compares. Texts that are
 * not valid UTF-8 are skipped by the reference side: production must reject. */
static void
differential(const char *text, gsize len)
{
  gboolean utf8 = g_utf8_validate(text, (gssize)len, NULL);
  char kind = utf8 ? ref_root_kind(text, len) : 0;
  g_autoptr(JsonParser) as_object = len > 0 ? wx_json_parse((const guint8 *)text, len, len, WX_JSON_ROOT_OBJECT, NULL) : NULL;
  g_autoptr(JsonParser) as_array = len > 0 ? wx_json_parse((const guint8 *)text, len, len, WX_JSON_ROOT_ARRAY, NULL) : NULL;
  if (kind != 0)
    fuzz_accepted++;
  if (kind == '{') {
    g_assert_nonnull(as_object);
    g_assert_null(as_array);
    assert_strings_valid(json_parser_get_root(as_object));
  } else if (kind == '[') {
    g_assert_nonnull(as_array);
    g_assert_null(as_object);
    assert_strings_valid(json_parser_get_root(as_array));
  } else {
    if (as_object != NULL || as_array != NULL) {
      g_printerr("production accepted what the reference rejects: %.*s\n", (int)MIN(len, (gsize)200), text);
      g_assert_null(as_object);
      g_assert_null(as_array);
    }
  }
}

/* Random valid-ish document built from grammar pieces. */
static void
gen_value(GRand *rng, GString *out, guint depth)
{
  switch (g_rand_int_range(rng, 0, depth > 6 ? 6 : 8)) {
  case 0:
    g_string_append(out, "null");
    break;
  case 1:
    g_string_append(out, g_rand_boolean(rng) ? "true" : "false");
    break;
  case 2: {
    static const char *const nums[] = {"0", "-0", "1", "-12", "3.25", "1e5", "-2.5E-3", "123456789012345678901",
                                       "1e999", "0.000001", "10", "99.5"};
    g_string_append(out, nums[g_rand_int_range(rng, 0, G_N_ELEMENTS(nums))]);
    break;
  }
  case 3:
  case 4:
  case 5: {
    static const char *const strs[] = {"\"\"", "\"abc\"", "\"\\u0041\"", "\"\\ud83d\\ude00\"", "\"\xc3\xa9\"",
                                       "\"a\\nb\"", "\"\\\\\"", "\"\\/\"", "\"x y\"", "\"\\u00e9\\u20ac\""};
    g_string_append(out, strs[g_rand_int_range(rng, 0, G_N_ELEMENTS(strs))]);
    break;
  }
  case 6:
  case 7: {
    gboolean object = g_rand_boolean(rng);
    g_string_append_c(out, object ? '{' : '[');
    guint n = (guint)g_rand_int_range(rng, 0, 4);
    for (guint i = 0; i < n; i++) {
      if (i > 0)
        g_string_append(out, g_rand_boolean(rng) ? "," : " , ");
      if (object) {
        /* Mostly unique names; sometimes a name from a small pool (repeats, other spellings). */
        static const char *const pool[] = {"\"a\"", "\"\\u0061\"", "\"b\"", "\"\\u00e9\"", "\"\xc3\xa9\"",
                                           "\"\"", "\"a\\/b\"", "\"a/b\"", "\"\\ud83d\\ude00\""};
        if (g_rand_int_range(rng, 0, 2) == 0)
          g_string_append(out, pool[g_rand_int_range(rng, 0, G_N_ELEMENTS(pool))]);
        else
          g_string_append_printf(out, "\"k%u\"", i);
        g_string_append_c(out, ':');
      }
      gen_value(rng, out, depth + 1);
    }
    g_string_append_c(out, object ? '}' : ']');
    break;
  }
  }
}

static void
test_json_differential_fuzz(void)
{
  GRand *rng = g_rand_new_with_seed(20261011);
  static const char *const tokens[] = {
      "{", "}", "[", "]", ",", ":", "\"", "\\", "\"a\"", "\"\\u0041\"", "\"\\ud83d\\ude00\"", "\"\\ud83d\"",
      "\"\\u0000\"", "1", "-", "0", "01", "1.5", "1e5", "1e", ".", "+", "true", "false", "null", "nul", "NaN",
      " ", "\n", "\t", "\r", "\x0b", "\xc3\xa9", "\xff", "\xef\xbb\xbf", "'", "/", "*", "#", "\\u", "e", "E", "x"};
  guint iterations = g_test_slow() ? 600000 : 150000;

  /* 1. Random token soup. */
  for (guint i = 0; i < iterations; i++) {
    GString *s = g_string_new(NULL);
    guint n = (guint)g_rand_int_range(rng, 1, 14);
    for (guint k = 0; k < n; k++)
      g_string_append(s, tokens[g_rand_int_range(rng, 0, G_N_ELEMENTS(tokens))]);
    differential(s->str, s->len);
    g_string_free(s, TRUE);
  }

  /* 2. Grammar-generated documents, valid and then damaged at a random byte. */
  for (guint i = 0; i < iterations; i++) {
    GString *s = g_string_new(NULL);
    g_string_append_c(s, g_rand_boolean(rng) ? '{' : '[');
    gboolean object = s->str[0] == '{';
    if (object)
      g_string_append(s, "\"k\":");
    gen_value(rng, s, 0);
    g_string_append_c(s, object ? '}' : ']');
    differential(s->str, s->len);
    for (guint m = 0; m < 3 && s->len > 0; m++) {
      gsize pos = (gsize)g_rand_int_range(rng, 0, (gint32)s->len);
      switch (g_rand_int_range(rng, 0, 3)) {
      case 0:
        s->str[pos] = (char)g_rand_int_range(rng, 1, 256);
        break;
      case 1:
        g_string_insert_c(s, (gssize)pos, tokens[g_rand_int_range(rng, 0, 12)][0]);
        break;
      default:
        g_string_erase(s, (gssize)pos, 1);
        break;
      }
      differential(s->str, s->len);
    }
    g_string_free(s, TRUE);
  }

  /* 3. Every prefix of a rich document (truncation), and every single-byte value. */
  const char *rich = "{\"a\":[1,2.5e3,\"x\\u00e9\\ud83d\\ude00\",{\"b\":null,\"c\":[true,false]}],\"d\":{\"e\":\"\\n\"}}";
  for (gsize n = 0; n <= strlen(rich); n++)
    differential(rich, n);
  for (int b = 0; b < 256; b++) {
    char one[3] = {(char)b, 0, 0};
    differential(one, 1);
    char wrapped[8] = {'{', '"', 'a', '"', ':', '"', (char)b, 0};
    char text[10];
    memcpy(text, wrapped, 7);
    text[7] = '"';
    text[8] = '}';
    differential(text, 9);
  }
  g_rand_free(rng);
  /* The property was exercised, not vacuous: many accepted documents, many refused repeats. */
  g_assert_cmpuint(fuzz_accepted, >, 10000);
  g_assert_cmpuint(fuzz_dup_refused, >, 1000);
}

/* Reads exactly len bytes: with a guard page right behind them any read past
 * the end faults. Every first byte and every truncation point. */
static void
test_json_guard_page(void)
{
  for (int b = 0; b < 256; b++) {
    Guarded g = guard_new(1);
    g.data[0] = (char)b;
    g_autoptr(JsonParser) p = wx_json_parse((const guint8 *)g.data, 1, 1, WX_JSON_ROOT_OBJECT, NULL);
    g_assert_null(p);
    guard_free(g);
  }
  const char *doc = "{\"a\":[1,2.5e3,\"x\\u00e9\\ud83d\\ude00\",{\"b\":null}],\"d\":\"\xc3\xa9\xf0\x9f\x98\x80\"}";
  gsize full = strlen(doc);
  for (gsize n = 1; n <= full; n++) {
    Guarded g = guard_new(n);
    memcpy(g.data, doc, n);
    g_autoptr(JsonParser) p = wx_json_parse((const guint8 *)g.data, n, full, WX_JSON_ROOT_OBJECT, NULL);
    g_assert_true((p != NULL) == (n == full));
    guard_free(g);
  }
  /* A string that ends in the middle of an escape and of a number. */
  const char *cuts[] = {"{\"a\":\"\\", "{\"a\":\"\\u00", "{\"a\":-", "{\"a\":1e", "{\"a\":tru", "{\"a\":\"\xf0\x9f"};
  for (guint i = 0; i < G_N_ELEMENTS(cuts); i++) {
    gsize n = strlen(cuts[i]);
    Guarded g = guard_new(n);
    memcpy(g.data, cuts[i], n);
    g_autoptr(JsonParser) p = wx_json_parse((const guint8 *)g.data, n, n, WX_JSON_ROOT_OBJECT, NULL);
    g_assert_null(p);
    guard_free(g);
  }
}

/* ------------------------------------------------------------------------ */
/* Part 2: pure WxHttp helpers                                              */
/* ------------------------------------------------------------------------ */

static void
test_path_validation(void)
{
  static const char *const accepted[] = {"/", "/a", "/v1/forecast?latitude=25.7617&longitude=-80.1918&x=a,b;c",
                                         "/a%20b?c=d%26e", "/a/b/c/", "/?x", "/..", "/a/../b",
                                         "/!$&'()*+,;=:@~._-", "/\"<>[]{}|^`"};
  for (guint i = 0; i < G_N_ELEMENTS(accepted); i++)
    g_assert_true(wx_http_path_is_valid(accepted[i]));

  static const char *const rejected[] = {
      "", "a", "?x", "x/y", "//", "//x", "//x/y", "/a b", "/a#b", "/#", "/a\\b", "\\", "/ ", " /", "/a\tb",
      "/a\nb", "/a\rb", "/a\r\nHost: evil", "/\x7f", "/\xc3\xa9", "/\x80", "/\xff", "http://evil/",
      "/a\x01", "/\x1f", "@evil.com/",
  };
  for (guint i = 0; i < G_N_ELEMENTS(rejected); i++)
    g_assert_false(wx_http_path_is_valid(rejected[i]));
  g_assert_false(wx_http_path_is_valid(NULL));

  /* Every byte value: only 0x21..0x7E minus '#' and '\\' may appear. */
  for (int b = 1; b < 256; b++) {
    char p[4] = {'/', 'a', (char)b, 0};
    gboolean expect = b > 0x20 && b < 0x7F && b != '#' && b != '\\';
    g_assert_true(wx_http_path_is_valid(p) == expect);
    char q[3] = {'/', (char)b, 0};
    g_assert_true(wx_http_path_is_valid(q) == (expect && b != '/'));
  }

  /* Length: exactly WX_HTTP_PATH_MAX bytes is fine, one more is not. */
  g_assert_cmpuint(WX_HTTP_PATH_MAX, ==, 2048);
  g_autofree char *max = g_malloc0(WX_HTTP_PATH_MAX + 2);
  memset(max, 'a', WX_HTTP_PATH_MAX);
  max[0] = '/';
  g_assert_true(wx_http_path_is_valid(max));
  max[WX_HTTP_PATH_MAX] = 'a';
  g_assert_false(wx_http_path_is_valid(max));
  g_assert_false(wx_http_path_is_valid("/"
                                       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                                       "\x01"));
}

/* The documented bound is WX_HTTP_PATH_MAX + 1 bytes: nothing beyond is read. */
static void
test_path_validation_guard_page(void)
{
  for (int b = 0; b < 256; b++) {
    /* Unterminated, exactly WX_HTTP_PATH_MAX + 1 readable bytes, no NUL anywhere. */
    Guarded g = guard_new(WX_HTTP_PATH_MAX + 1);
    memset(g.data, 'a', WX_HTTP_PATH_MAX + 1);
    g.data[0] = (char)(b == 0 ? 'b' : b);
    g_assert_false(wx_http_path_is_valid(g.data));
    g.data[0] = '/';
    g_assert_false(wx_http_path_is_valid(g.data));
    guard_free(g);
  }
  /* Terminated at the very end of the readable window: valid at max length. */
  Guarded g = guard_new(WX_HTTP_PATH_MAX + 1);
  memset(g.data, 'a', WX_HTTP_PATH_MAX);
  g.data[0] = '/';
  g.data[WX_HTTP_PATH_MAX] = '\0';
  g_assert_true(wx_http_path_is_valid(g.data));
  guard_free(g);
  /* Short strings terminated right at the guard. */
  for (gsize n = 1; n < 40; n++) {
    Guarded s = guard_new(n + 1);
    memset(s.data, 'x', n);
    s.data[0] = '/';
    s.data[n] = '\0';
    g_assert_true(wx_http_path_is_valid(s.data));
    guard_free(s);
  }
}

/* 1994-11-06T08:49:37Z, the RFC 9110 example date. */
#define EXAMPLE_DATE_S G_GINT64_CONSTANT(784111777)

static void
test_parse_expires(void)
{
  const gint64 t = EXAMPLE_DATE_S;
  const char *rfc1123 = "Sun, 06 Nov 1994 08:49:37 GMT";
  const char *rfc850 = "Sunday, 06-Nov-94 08:49:37 GMT";
  const char *asctime = "Sun Nov  6 08:49:37 1994";
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t - 1), ==, t);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t - 3600), ==, t);
  g_assert_cmpint(wx_http_parse_expires(rfc850, t - 1), ==, t);
  g_assert_cmpint(wx_http_parse_expires(asctime, t - 1), ==, t);
  /* Window: (now, now + 86400]. */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t), ==, 0);       /* not after now */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t + 1), ==, 0);   /* past */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t + 86400), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t - 86400), ==, t);     /* exactly 24 h ahead */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t - 86401), ==, 0);     /* 24 h and 1 s ahead */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, t - 86399), ==, t);
  /* Hostile clocks: no signed overflow whatever now_s is. */
  g_assert_cmpint(wx_http_parse_expires(rfc1123, G_MININT64), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, G_MAXINT64), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, G_MININT64 + 1), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, G_MAXINT64 - 1), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, 0), ==, 0);
  g_assert_cmpint(wx_http_parse_expires(rfc1123, -1), ==, 0);
  /* Garbage, absent, empty. */
  const char *garbage[] = {NULL, "", " ", "0", "-1", "99999999999999999999", "now", "Sun, 32 Nov 1994 08:49:37 GMT",
                           "Sun, 06 Nov 1994 25:49:37 GMT", "Sun, 06 Foo 1994 08:49:37 GMT", "\x01\x02",
                           "Sun, 06 Nov 1994 08:49:37 GMT garbage that is far too long to be a date but < 64",
                           "\xff\xfe", "Sun, 06 Nov 1994"};
  for (guint i = 0; i < G_N_ELEMENTS(garbage); i++)
    g_assert_cmpint(wx_http_parse_expires(garbage[i], t - 1), ==, 0);
  /* Longer than WX_HTTP_VALIDATOR_MAX bytes: refused even if it starts like a date. */
  g_autofree char *padded = g_malloc0(WX_HTTP_VALIDATOR_MAX + 2);
  memset(padded, ' ', WX_HTTP_VALIDATOR_MAX + 1);
  memcpy(padded, rfc1123, strlen(rfc1123));
  g_assert_cmpint(wx_http_parse_expires(padded, t - 1), ==, 0);
  /* The bound is a read bound as well. */
  for (gsize n = WX_HTTP_VALIDATOR_MAX + 1; n <= WX_HTTP_VALIDATOR_MAX + 1; n++) {
    Guarded g = guard_new(n);
    memset(g.data, 'x', n);
    g_assert_cmpint(wx_http_parse_expires(g.data, t - 1), ==, 0);
    memcpy(g.data, rfc1123, strlen(rfc1123));
    g_assert_cmpint(wx_http_parse_expires(g.data, t - 1), ==, 0);
    guard_free(g);
  }
  /* Terminated exactly at the end of the window (WX_HTTP_VALIDATOR_MAX bytes + NUL). */
  Guarded g = guard_new(WX_HTTP_VALIDATOR_MAX + 1);
  memset(g.data, ' ', WX_HTTP_VALIDATOR_MAX);
  memcpy(g.data, rfc1123, strlen(rfc1123));
  g.data[WX_HTTP_VALIDATOR_MAX] = '\0';
  (void)wx_http_parse_expires(g.data, t - 1); /* must not fault; the result is libsoup's call */
  guard_free(g);
  for (gsize n = 1; n < 40; n++) {
    Guarded s = guard_new(n + 1);
    memset(s.data, 'x', n);
    s.data[n] = '\0';
    g_assert_cmpint(wx_http_parse_expires(s.data, t - 1), ==, 0);
    guard_free(s);
  }
}

/* Differential property over many dates: result is t exactly when in the window. */
static void
test_parse_expires_window_property(void)
{
  GRand *rng = g_rand_new_with_seed(7);
  for (guint i = 0; i < 20000; i++) {
    gint64 t = (gint64)g_rand_int_range(rng, 946684800, 2000000000); /* 2000..2033 */
    g_autoptr(GDateTime) when = g_date_time_new_from_unix_utc(t);
    g_autofree char *text = g_date_time_format(when, "%a, %d %b %Y %H:%M:%S GMT");
    gint64 now = t + (gint64)g_rand_int_range(rng, -100000, 100000);
    gint64 expect = (t > now && t - now <= 86400) ? t : 0;
    g_assert_cmpint(wx_http_parse_expires(text, now), ==, expect);
  }
  g_rand_free(rng);
}

static void
test_constructor_policy(void)
{
  /* https only; plain http solely towards 127.0.0.1, ::1 and localhost. */
  const char *rejected[] = {
      "http://api.met.no", "http://example.com:8080", "ftp://127.0.0.1", "https://api.met.no/path",
      "https://api.met.no/x/", "https://user@api.met.no", "https://user:pw@api.met.no",
      "https://:@api.met.no", "https://api.met.no?x=1", "https://api.met.no?", "https://api.met.no#f",
      "https://api.met.no#", "api.met.no", "//api.met.no", "http://127.0.0.1.evil.com", "http://localhost.evil.com",
      "http://127.0.0.2", "http://127.1", "http://0x7f.1", "http://2130706433", "http://0.0.0.0",
      "http://[::2]", "http://[::ffff:127.0.0.1]", "http://", "https://", "https:///x", "file:///etc/passwd",
      "javascript:alert(1)", "", " ", " https://api.met.no", "https://api.met.no ", "https://a b.com",
      "https://api.met.no\\@evil.com", "https://api.met.no%2Fx", "https://api.met.no:0", "https://api.met.no:65536",
      "https://api.met.no:99999999999", "https://api.met.no:abc", "https://exa%6dple.com%2f", "https://-",
      "https://[fe80::1%25eth0]", "http://localhost@evil.com", "http://127.0.0.1@evil.com",
      "https://api.met.no/\n", "https://api.met.no\r\n", "https://api.met.no/%00", "https://\xc3\xa9.com\x01",
      "https://api.met.no//", "https://api.met.no/x/..//", "https://api.met.no.",
      "https://.api.met.no", "https://api..met.no", "https://api-.met.no", "https://-api.met.no",
      "https://api.met.no-", "https://a_b.com", "https://[::1]x", "https://[xyz::1]",
  };
  for (guint i = 0; i < G_N_ELEMENTS(rejected); i++) {
    g_autoptr(GError) error = NULL;
    WxHttp *http = wx_http_new_custom(rejected[i], UA, 1000, 0, 0, &error);
    if (http != NULL) {
      g_printerr("accepted base URL %s\n", rejected[i]);
      g_assert_null(http);
    }
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_null(strstr(error->message, "evil")); /* no echo of the rejected text */
    g_assert_null(wx_http_new_custom(rejected[i], UA, 1000, 0, 0, NULL)); /* NULL error is fine */
  }
  const char *accepted[] = {"https://api.met.no", "https://api.met.no/", "HTTPS://API.MET.NO", "https://api.met.no:443",
                            "https://api.met.no:8443/", "http://127.0.0.1:8080", "http://localhost", "http://LOCALHOST:9/",
                            "http://[::1]:9/", "http://[::1]", "https://api.open-meteo.com", "https://geocoding-api.open-meteo.com",
                            "https://1.2.3.4", "https://[2001:db8::1]:443", "https://%61pi.met.no", "https://xn--n-nga1b.com",
                            "https://\xc3\xbcn\xc3\xaf.com", "http://%6C%6F%63alhost", "https://api.met.no:",
                            "https://api.met.no/.", "https://api.met.no/./"};
  for (guint i = 0; i < G_N_ELEMENTS(accepted); i++) {
    g_autoptr(GError) error = NULL;
    WxHttp *http = wx_http_new_custom(accepted[i], UA, 1000, 0, 0, &error);
    g_assert_no_error(error);
    g_assert_nonnull(http);
    g_assert_true(WX_IS_HTTP(http));
    g_object_unref(http);
  }
  g_autoptr(WxHttp) def = wx_http_new("https://api.met.no", UA, NULL);
  g_assert_nonnull(def);

  /* Host labels: 63 bytes fine, 64 not; the whole name 253 bytes fine, 254 not. */
  g_autofree char *label63 = g_strnfill(63, 'a');
  g_autofree char *label64 = g_strnfill(64, 'a');
  g_autofree char *label61 = g_strnfill(61, 'a');
  g_autofree char *label62 = g_strnfill(62, 'a');
  g_autofree char *host253 = g_strjoin(".", label63, label63, label63, label61, NULL);
  g_autofree char *host254 = g_strjoin(".", label63, label63, label63, label62, NULL);
  g_assert_cmpuint(strlen(host253), ==, 253);
  g_assert_cmpuint(strlen(host254), ==, 254);
  struct {
    const char *host;
    gboolean accepted;
  } hosts[] = {{label63, TRUE}, {label64, FALSE}, {host253, TRUE}, {host254, FALSE}};
  for (guint i = 0; i < G_N_ELEMENTS(hosts); i++) {
    g_autofree char *url = g_strconcat("https://", hosts[i].host, NULL);
    g_autoptr(WxHttp) h = wx_http_new_custom(url, UA, 1000, 0, 0, NULL);
    g_assert_true((h != NULL) == hosts[i].accepted);
  }

  /* User-Agent: 1..200 printable ASCII. */
  g_autofree char *ua200 = g_strnfill(200, 'a');
  g_autofree char *ua201 = g_strnfill(201, 'a');
  const char *bad_ua[] = {"", "ua\r\nX-Evil: 1", "ua\n", "ua\t", "ua\x01", "ua\x7f", "ua\xc3\xa9", "\xff", ua201};
  for (guint i = 0; i < G_N_ELEMENTS(bad_ua); i++) {
    g_autoptr(GError) error = NULL;
    g_assert_null(wx_http_new_custom("https://api.met.no", bad_ua[i], 1000, 0, 0, &error));
    g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_nonnull(strstr(error->message, "User-Agent"));
  }
  g_autoptr(WxHttp) ua_ok = wx_http_new("https://api.met.no", ua200, NULL);
  g_assert_nonnull(ua_ok);
  g_autoptr(WxHttp) ua_space = wx_http_new("https://api.met.no", " weather app ~!", NULL);
  g_assert_nonnull(ua_space);

  /* Programmer errors. */
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom(NULL, UA, 1000, 0, 0, NULL)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", NULL, 1000, 0, 0, NULL)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", UA, 0, 0, 0, NULL)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", UA, 600001, 0, 0, NULL)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", UA, 1000, 600001, 0, NULL)));
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", UA, 1000, 0, 600001, NULL)));
  g_autoptr(GError) preset = g_error_new_literal(WX_ERROR, WX_ERROR_PARSE, "x");
  ASSERT_CRITICAL("wx_http_new_custom", g_assert_null(wx_http_new_custom("https://a.b", UA, 1000, 0, 0, &preset)));
  ASSERT_CRITICAL("wx_http_new", g_assert_null(wx_http_new(NULL, UA, NULL)));
  ASSERT_CRITICAL("wx_http_new", g_assert_null(wx_http_new("https://a.b", NULL, NULL)));
  /* The boundary values themselves are fine. */
  g_autoptr(WxHttp) lo = wx_http_new_custom("https://a.b", UA, 1, 0, 0, NULL);
  g_autoptr(WxHttp) hi = wx_http_new_custom("https://a.b", UA, 600000, 600000, 600000, NULL);
  g_assert_nonnull(lo);
  g_assert_nonnull(hi);
}

static void
test_constants(void)
{
  g_assert_cmpuint(WX_HTTP_TIMEOUT_MS, ==, 10000);
  g_assert_cmpuint(WX_HTTP_TOTAL_DEADLINE_MS, ==, 45000);
  g_assert_cmpuint(WX_HTTP_BACKOFF_BASE_MS, ==, 1000);
  g_assert_cmpuint(WX_HTTP_MAX_RETRIES, ==, 2);
  g_assert_cmpuint(WX_HTTP_MAX_BODY_BYTES, ==, 4 * 1024 * 1024);
  g_assert_cmpuint(WX_HTTP_MAX_INFLIGHT, ==, 16);
  g_assert_cmpuint(WX_HTTP_READ_CHUNK, ==, 16384);
}

/* ------------------------------------------------------------------------ */
/* Part 3: request layer against a loopback fake server                     */
/* ------------------------------------------------------------------------ */

typedef enum {
  STEP_RESPOND,      /* status + headers + body, then close */
  STEP_HANG,         /* read the request, never answer */
  STEP_CLOSE,        /* close without answering */
  STEP_BIG_STREAMED, /* 200, no Content-Length, `size` bytes of body (default 5 MiB), then close */
  STEP_BIG_DECLARED, /* 200 with a Content-Length of `size` bytes that are never sent in full */
  STEP_RAW,          /* body is the complete raw response, sent verbatim, then close */
  STEP_GZIP,         /* 200, body gzip-compressed with a matching Content-Length */
  STEP_BYTES,        /* body/size: the complete raw response (binary allowed), sent verbatim, then close */
  STEP_BYTES_HANG,   /* body/size, sent verbatim, then the connection stays open and silent */
  STEP_BYTES_SPLIT   /* body/size: the first `status` bytes now, the rest after delay_ms, then close */
} StepKind;

typedef struct {
  StepKind kind;
  guint status;
  const char *body;    /* NUL-terminated; NULL with `size` > 0: `size` blanks */
  const char *headers; /* extra header lines, each ending in CRLF, or NULL */
  gsize size;
  guint delay_ms;      /* STEP_RESPOND: wait this long before answering */
} Step;

typedef struct Fake Fake;

typedef struct {
  Fake *fake;
  GSocketConnection *connection;
  GString *request;
  guint8 buffer[2048];
  gsize big_remaining; /* STEP_BIG_STREAMED */
  gboolean active;     /* counted in fake->active */
  GBytes *pending;     /* STEP_RESPOND with a delay: the answer */
} Conn;

struct Fake {
  GSocketService *service;
  guint port;
  const Step *steps;
  guint n_steps;
  guint requests;
  GPtrArray *paths;     /* request target of every request (char *) */
  GPtrArray *heads;     /* complete head of every request (char *) */
  GArray *arrivals_us;  /* monotonic arrival time of every request (gint64) */
  GPtrArray *held;      /* Conn of hanging requests */
  GHashTable *conns;    /* every Conn with an operation in flight (set) */
  guint active;         /* requests between arrival and the end of their answer */
  guint max_active;
  gsize big_sent;       /* STEP_BIG_STREAMED: body bytes handed to the socket */
};

static void conn_read(Conn *conn);

static void
conn_free(Conn *conn)
{
  g_hash_table_remove(conn->fake->conns, conn);
  if (conn->active)
    conn->fake->active--;
  if (conn->connection != NULL) {
    (void)g_io_stream_close(G_IO_STREAM(conn->connection), NULL, NULL);
    g_object_unref(conn->connection);
  }
  g_clear_pointer(&conn->pending, g_bytes_unref);
  g_string_free(conn->request, TRUE);
  g_free(conn);
}

static void
write_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gsize written;
  (void)g_output_stream_write_all_finish(G_OUTPUT_STREAM(source), result, &written, &error);
  conn_free(conn);
}

static void
respond_bytes(Conn *conn, GBytes *bytes)
{
  GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn->connection));
  gsize len;
  const void *data = g_bytes_get_data(bytes, &len);
  /* The bytes stay alive with the stream until the write completes. */
  g_object_set_data_full(G_OBJECT(out), "wx-test-bytes", g_bytes_ref(bytes), (GDestroyNotify)g_bytes_unref);
  g_output_stream_write_all_async(out, data, len, G_PRIORITY_DEFAULT, NULL, write_done, conn);
}

static gboolean
on_delayed_answer(gpointer user_data)
{
  Conn *conn = user_data;
  GBytes *bytes = g_steal_pointer(&conn->pending);
  respond_bytes(conn, bytes);
  g_bytes_unref(bytes);
  return G_SOURCE_REMOVE;
}

static void big_chunk_done(GObject *source, GAsyncResult *result, gpointer user_data);

static void
big_next_chunk(Conn *conn)
{
  static guint8 chunk[64 * 1024];
  if (conn->big_remaining == 0) {
    conn_free(conn);
    return;
  }
  gsize n = MIN(conn->big_remaining, sizeof chunk);
  conn->big_remaining -= n;
  conn->fake->big_sent += n;
  g_output_stream_write_all_async(g_io_stream_get_output_stream(G_IO_STREAM(conn->connection)), chunk, n,
                                  G_PRIORITY_DEFAULT, NULL, big_chunk_done, conn);
}

static void
big_chunk_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gsize written;
  if (!g_output_stream_write_all_finish(G_OUTPUT_STREAM(source), result, &written, &error)) {
    conn_free(conn); /* the client gave up (cap reached) */
    return;
  }
  big_next_chunk(conn);
}

static GBytes *
gzip_of(const char *body, gsize size)
{
  g_autoptr(GConverter) gzip = G_CONVERTER(g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, -1));
  g_autoptr(GOutputStream) mem = g_memory_output_stream_new_resizable();
  g_autoptr(GOutputStream) zout = g_converter_output_stream_new(mem, gzip);
  g_autoptr(GError) zerror = NULL;
  g_autofree char *zeros = body == NULL ? g_malloc0(size) : NULL;
  g_assert_true(g_output_stream_write_all(zout, body != NULL ? body : zeros, size, NULL, NULL, &zerror));
  g_assert_true(g_output_stream_close(zout, NULL, &zerror));
  return g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(mem));
}

static void
handle_request(Conn *conn)
{
  Fake *fake = conn->fake;
  g_ptr_array_add(fake->heads, g_strdup(conn->request->str));
  const char *target = conn->request->str + 4; /* after "GET " */
  const char *end = strchr(target, ' ');
  g_ptr_array_add(fake->paths, end != NULL ? g_strndup(target, (gsize)(end - target)) : g_strdup(target));
  gint64 arrival = g_get_monotonic_time();
  g_array_append_val(fake->arrivals_us, arrival);
  guint index = MIN(fake->requests, fake->n_steps - 1);
  fake->requests++;
  conn->active = TRUE;
  fake->active++;
  fake->max_active = MAX(fake->max_active, fake->active);
  const Step *step = &fake->steps[index];

  switch (step->kind) {
  case STEP_RESPOND: {
    g_autofree char *blank = step->body == NULL ? g_strnfill(step->size, ' ') : NULL;
    const char *body = step->body != NULL ? step->body : blank;
    gsize body_len = step->body != NULL ? strlen(body) : step->size;
    g_autofree char *head = g_strdup_printf(
        "HTTP/1.1 %u X\r\nContent-Type: application/json\r\n%sContent-Length: %" G_GSIZE_FORMAT
        "\r\nConnection: close\r\n\r\n",
        step->status, step->headers != NULL ? step->headers : "", body_len);
    GByteArray *all = g_byte_array_new();
    g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
    g_byte_array_append(all, (const guint8 *)body, (guint)body_len);
    GBytes *bytes = g_byte_array_free_to_bytes(all);
    if (step->delay_ms > 0) {
      conn->pending = bytes;
      g_timeout_add(step->delay_ms, on_delayed_answer, conn);
    } else {
      respond_bytes(conn, bytes);
      g_bytes_unref(bytes);
    }
    break;
  }
  case STEP_RAW: {
    GBytes *bytes = g_bytes_new_static(step->body, strlen(step->body));
    respond_bytes(conn, bytes);
    g_bytes_unref(bytes);
    break;
  }
  case STEP_GZIP: {
    g_autoptr(GBytes) packed = gzip_of(step->body, step->body != NULL ? strlen(step->body) : step->size);
    g_autofree char *head = g_strdup_printf(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\n"
        "Content-Length: %" G_GSIZE_FORMAT "\r\nConnection: close\r\n\r\n",
        g_bytes_get_size(packed));
    GByteArray *all = g_byte_array_new();
    g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
    g_byte_array_append(all, g_bytes_get_data(packed, NULL), (guint)g_bytes_get_size(packed));
    GBytes *bytes = g_byte_array_free_to_bytes(all);
    respond_bytes(conn, bytes);
    g_bytes_unref(bytes);
    break;
  }
  case STEP_BYTES: {
    GBytes *bytes = g_bytes_new_static(step->body, step->size);
    respond_bytes(conn, bytes);
    g_bytes_unref(bytes);
    break;
  }
  case STEP_BYTES_SPLIT: {
    gsize first = step->status;
    g_autoptr(GError) error = NULL;
    (void)g_output_stream_write_all(g_io_stream_get_output_stream(G_IO_STREAM(conn->connection)),
                                    step->body, first, NULL, NULL, &error);
    conn->pending = g_bytes_new_static(step->body + first, step->size - first);
    g_timeout_add(step->delay_ms, on_delayed_answer, conn);
    break;
  }
  case STEP_BYTES_HANG: {
    const void *data = step->body;
    gsize len = step->size;
    g_autoptr(GError) error = NULL;
    (void)g_output_stream_write_all(g_io_stream_get_output_stream(G_IO_STREAM(conn->connection)), data, len,
                                    NULL, NULL, &error);
    g_hash_table_remove(fake->conns, conn); /* freed by fake_free(), like STEP_HANG */
    g_ptr_array_add(fake->held, conn);
    break;
  }
  case STEP_HANG:
    g_hash_table_remove(fake->conns, conn); /* nothing is pending on it: freed by fake_free() */
    g_ptr_array_add(fake->held, conn);
    break;
  case STEP_CLOSE:
    conn_free(conn);
    break;
  case STEP_BIG_STREAMED: {
    static const char head_text[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    conn->big_remaining = step->size > 0 ? step->size : (gsize)5 * 1024 * 1024;
    GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(conn->connection));
    g_autoptr(GError) error = NULL;
    (void)g_output_stream_write_all(out, head_text, strlen(head_text), NULL, NULL, &error);
    big_next_chunk(conn);
    break;
  }
  case STEP_BIG_DECLARED: {
    g_autofree char *text = g_strdup_printf(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %" G_GSIZE_FORMAT
        "\r\nConnection: close\r\n\r\n{}",
        step->size);
    GBytes *bytes = g_bytes_new(text, strlen(text));
    respond_bytes(conn, bytes);
    g_bytes_unref(bytes);
    break;
  }
  }
}

static void
read_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Conn *conn = user_data;
  g_autoptr(GError) error = NULL;
  gssize n = g_input_stream_read_finish(G_INPUT_STREAM(source), result, &error);
  if (n <= 0) {
    conn_free(conn);
    return;
  }
  g_string_append_len(conn->request, (const char *)conn->buffer, n);
  if (strstr(conn->request->str, "\r\n\r\n") != NULL)
    handle_request(conn);
  else
    conn_read(conn);
}

static void
conn_read(Conn *conn)
{
  g_input_stream_read_async(g_io_stream_get_input_stream(G_IO_STREAM(conn->connection)), conn->buffer,
                            sizeof conn->buffer, G_PRIORITY_DEFAULT, NULL, read_done, conn);
}

static gboolean
on_incoming(GSocketService *service, GSocketConnection *connection, GObject *source, gpointer user_data)
{
  (void)service;
  (void)source;
  Conn *conn = g_new0(Conn, 1);
  conn->fake = user_data;
  conn->connection = g_object_ref(connection);
  conn->request = g_string_new(NULL);
  g_hash_table_add(conn->fake->conns, conn);
  conn_read(conn);
  return TRUE;
}

/* A fake whose steps answer the requests in order; the last step repeats. */
static Fake *
fake_new(const Step *steps, guint n_steps)
{
  Fake *fake = g_new0(Fake, 1);
  fake->steps = steps;
  fake->n_steps = n_steps;
  fake->paths = g_ptr_array_new_with_free_func(g_free);
  fake->heads = g_ptr_array_new_with_free_func(g_free);
  fake->arrivals_us = g_array_new(FALSE, FALSE, sizeof(gint64));
  fake->held = g_ptr_array_new();
  fake->conns = g_hash_table_new(NULL, NULL);
  fake->service = g_socket_service_new();
  g_autoptr(GError) error = NULL;
  guint16 port = g_socket_listener_add_any_inet_port(G_SOCKET_LISTENER(fake->service), NULL, &error);
  g_assert_no_error(error);
  fake->port = port;
  g_signal_connect(fake->service, "incoming", G_CALLBACK(on_incoming), fake);
  g_socket_service_start(fake->service);
  return fake;
}

static void
fake_stop_listening(Fake *fake)
{
  g_socket_service_stop(fake->service);
  g_socket_listener_close(G_SOCKET_LISTENER(fake->service));
}

static void
fake_free(Fake *fake)
{
  fake_stop_listening(fake);
  /* Connections still being served (a client that gave up mid-body, a delayed answer) hold
   * callbacks that point at the fake: close them and let every callback run before freeing. */
  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init(&iter, fake->conns);
  while (g_hash_table_iter_next(&iter, &key, NULL))
    (void)g_io_stream_close(G_IO_STREAM(((Conn *)key)->connection), NULL, NULL);
  gint64 until = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
  while (g_hash_table_size(fake->conns) > 0 && g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, FALSE);
  g_assert_cmpuint(g_hash_table_size(fake->conns), ==, 0);
  g_object_unref(fake->service);
  for (guint i = 0; i < fake->held->len; i++)
    conn_free(g_ptr_array_index(fake->held, i));
  g_ptr_array_unref(fake->held);
  g_hash_table_unref(fake->conns);
  g_ptr_array_unref(fake->paths);
  g_ptr_array_unref(fake->heads);
  g_array_unref(fake->arrivals_us);
  g_free(fake);
}

static const char *
fake_path(const Fake *fake, guint index)
{
  g_assert_cmpuint(index, <, fake->paths->len);
  return g_ptr_array_index(fake->paths, index);
}

static const char *
fake_head(const Fake *fake, guint index)
{
  g_assert_cmpuint(index, <, fake->heads->len);
  return g_ptr_array_index(fake->heads, index);
}

static gint64
fake_arrival_us(const Fake *fake, guint index)
{
  return g_array_index(fake->arrivals_us, gint64, index);
}

static WxHttp *
http_for(const Fake *fake, guint timeout_ms, guint backoff_ms, guint gap_ms)
{
  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", fake->port);
  g_autoptr(GError) error = NULL;
  WxHttp *http = wx_http_new_custom(base, UA, timeout_ms, backoff_ms, gap_ms, &error);
  g_assert_no_error(error);
  g_assert_nonnull(http);
  return http;
}

typedef struct {
  gboolean done;
  WxHttpResponse *response;
  GError *error;
  gint64 finished_us;
  GCancellable *cancel_in_callback; /* on_done_cancel_first() cancels it first */
  WxHttp *finish_with;              /* set to finish on another object: see on_done() */
} Outcome;

static void
outcome_clear(Outcome *o)
{
  g_clear_pointer(&o->response, wx_http_response_free);
  g_clear_error(&o->error);
  o->done = FALSE;
}

static void
on_done(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  o->response = wx_http_get_finish(WX_HTTP(source), result, &o->error);
  o->finished_us = g_get_monotonic_time();
  o->done = TRUE;
}

static void
on_done_cancel_first(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  g_cancellable_cancel(o->cancel_in_callback);
  on_done(source, result, user_data);
}

static gint64
wait_for(Outcome *o, gint64 start_us)
{
  while (!o->done)
    g_main_context_iteration(NULL, TRUE);
  return (o->finished_us - start_us) / 1000;
}

static void
wait_all(Outcome *outs, guint count)
{
  for (;;) {
    gboolean all = TRUE;
    for (guint i = 0; i < count; i++)
      all = all && outs[i].done;
    if (all)
      return;
    g_main_context_iteration(NULL, TRUE);
  }
}

static gboolean
cancel_later(gpointer user_data)
{
  g_cancellable_cancel(G_CANCELLABLE(user_data));
  return G_SOURCE_REMOVE;
}

static void
spin(guint ms)
{
  gint64 until = g_get_monotonic_time() + (gint64)ms * 1000;
  while (g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, FALSE);
}

/* GET /x with the standard Accept; asserts the callback does not run before the call returns. */
static void
get(WxHttp *http, const char *path, const char *ims, GCancellable *cancellable, Outcome *o, gint64 *start_us)
{
  *start_us = g_get_monotonic_time();
  wx_http_get_async(http, path, JSON_ACCEPT, ims, cancellable, on_done, o);
  g_assert_false(o->done);
}

static const char *const kBody = "{\"ok\":true,\"SENTINEL-BODY-TEXT\":1}";

static void
assert_no_body_text(const GError *error)
{
  g_assert_null(strstr(error->message, "SENTINEL"));
}

static void
test_net_success_and_request_shape(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 10, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/v1/forecast?latitude=25.7617&longitude=-80.1918", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.response);
  g_assert_cmpuint(o.response->status, ==, 200);
  gsize len;
  const char *data = g_bytes_get_data(o.response->body, &len);
  g_assert_cmpmem(data, len, kBody, strlen(kBody));
  g_assert_cmpint(o.response->expires_s, ==, 0);
  g_assert_null(o.response->last_modified);
  g_assert_cmpuint(fake->requests, ==, 1);
  g_assert_cmpstr(fake_path(fake, 0), ==, "/v1/forecast?latitude=25.7617&longitude=-80.1918");

  /* Exactly one request line, GET, HTTP/1.1, and only the headers we expect. */
  const char *head = fake_head(fake, 0);
  g_assert_true(g_str_has_prefix(head, "GET /v1/forecast?latitude=25.7617&longitude=-80.1918 HTTP/1.1\r\n"));
  g_assert_true(g_str_has_suffix(head, "\r\n\r\n"));
  g_auto(GStrv) lines = g_strsplit(head, "\r\n", -1);
  guint request_lines = 0;
  gboolean saw_ua = FALSE, saw_accept = FALSE, saw_host = FALSE;
  for (guint i = 0; lines[i] != NULL && lines[i][0] != '\0'; i++) {
    if (g_str_has_prefix(lines[i], "GET ") || strstr(lines[i], " HTTP/1.") != NULL)
      request_lines++;
    if (i == 0)
      continue;
    const char *colon = strchr(lines[i], ':');
    g_assert_nonnull(colon);
    g_autofree char *name = g_ascii_strdown(lines[i], colon - lines[i]);
    /* Anything beyond this list (Cookie, Authorization, Referer, Origin, ...) is a violation. */
    g_assert_true(g_strv_contains((const char *const[]){"host", "user-agent", "accept", "accept-encoding",
                                                         "connection", NULL},
                                  name));
    if (g_str_equal(name, "user-agent")) {
      saw_ua = TRUE;
      g_assert_cmpstr(colon + 2, ==, UA);
    } else if (g_str_equal(name, "accept")) {
      saw_accept = TRUE;
      g_assert_cmpstr(colon + 2, ==, JSON_ACCEPT);
    } else if (g_str_equal(name, "host")) {
      saw_host = TRUE;
      g_autofree char *expected = g_strdup_printf("127.0.0.1:%u", fake->port);
      g_assert_cmpstr(colon + 2, ==, expected);
    }
  }
  g_assert_cmpuint(request_lines, ==, 1);
  g_assert_true(saw_ua && saw_accept && saw_host);
  for (const char *forbidden[] = {"Cookie", "Authorization", "Referer", "Origin", "Mozilla", "If-Modified-Since",
                                  "Proxy-Authorization", "X-", NULL},
       **f = forbidden;
       *f != NULL; f++)
    g_assert_null(g_strstr_len(head, -1, *f));
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_invalid_arguments_make_no_request(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 10, 0);
  g_autofree char *long_path = g_strnfill(WX_HTTP_PATH_MAX + 1, 'a');
  long_path[0] = '/';
  g_autofree char *long_ims = g_strnfill(WX_HTTP_VALIDATOR_MAX + 1, 'a');
  g_autofree char *long_accept = g_strnfill(WX_HTTP_HEADER_VALUE_MAX + 1, 'a');
  static const struct {
    const char *path;
    const char *accept;
    const char *ims;
  } cases[] = {
      {"//x", JSON_ACCEPT, NULL},
      {"/a b", JSON_ACCEPT, NULL},
      {"/a#b", JSON_ACCEPT, NULL},
      {"/a\x01", JSON_ACCEPT, NULL},
      {"/a\r\nHost: evil", JSON_ACCEPT, NULL},
      {"", JSON_ACCEPT, NULL},
      {"relative", JSON_ACCEPT, NULL},
      {"/a%zz", JSON_ACCEPT, NULL},
      {"/a%", JSON_ACCEPT, NULL},
      {"/ok", "", NULL},
      {"/ok", "application/json\r\nCookie: x=1", NULL},
      {"/ok", "application/json\n", NULL},
      {"/ok", "application/\xc3\xa9", NULL},
      {"/ok", JSON_ACCEPT, ""},
      {"/ok", JSON_ACCEPT, "Sun, 06 Nov 1994 08:49:37 GMT\r\nX: y"},
      {"/ok", JSON_ACCEPT, "\xc3\xa9"},
  };
  for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
    Outcome o = {0};
    gint64 start = g_get_monotonic_time();
    wx_http_get_async(http, cases[i].path, cases[i].accept, cases[i].ims, NULL, on_done, &o);
    g_assert_false(o.done);
    wait_for(&o, start);
    g_assert_null(o.response);
    g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    g_assert_null(strstr(o.error->message, "evil"));
    g_assert_null(strstr(o.error->message, "Cookie"));
    outcome_clear(&o);
  }
  struct {
    const char *path, *accept, *ims;
  } long_cases[] = {{long_path, JSON_ACCEPT, NULL}, {"/ok", long_accept, NULL}, {"/ok", JSON_ACCEPT, long_ims}};
  for (guint i = 0; i < G_N_ELEMENTS(long_cases); i++) {
    Outcome o = {0};
    gint64 start = g_get_monotonic_time();
    wx_http_get_async(http, long_cases[i].path, long_cases[i].accept, long_cases[i].ims, NULL, on_done, &o);
    g_assert_false(o.done);
    wait_for(&o, start);
    g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->requests, ==, 0);

  /* The boundary lengths are fine. */
  g_autofree char *max_path = g_strnfill(WX_HTTP_PATH_MAX, 'a');
  max_path[0] = '/';
  g_autofree char *max_ims = g_strnfill(WX_HTTP_VALIDATOR_MAX, 'a');
  g_autofree char *max_accept = g_strnfill(WX_HTTP_HEADER_VALUE_MAX, 'a');
  Outcome o = {0};
  gint64 start = g_get_monotonic_time();
  wx_http_get_async(http, max_path, max_accept, max_ims, NULL, on_done, &o);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  g_assert_cmpuint(fake->requests, ==, 1);
  fake_free(fake);
}

/* The callback must not run before the async call returns, even when the call
 * is made from inside a main-loop source (where GTask could complete inline). */
static gboolean
call_invalid_from_source(gpointer user_data)
{
  gpointer *args = user_data;
  Outcome *o = args[1];
  wx_http_get_async(args[0], "//bad", JSON_ACCEPT, NULL, NULL, on_done, o);
  g_assert_false(o->done);
  return G_SOURCE_REMOVE;
}

static void
test_net_callback_never_before_return(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 10, 0);
  Outcome o = {0};
  gpointer args[2] = {http, &o};
  g_idle_add_full(G_PRIORITY_HIGH, call_invalid_from_source, args, NULL);
  while (!o.done)
    g_main_context_iteration(NULL, TRUE);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&o);

  /* Pre-cancelled, from a source as well. */
  g_autoptr(GCancellable) cancelled = g_cancellable_new();
  g_cancellable_cancel(cancelled);
  gint64 start;
  get(http, "/x", NULL, cancelled, &o, &start);
  wait_for(&o, start);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  outcome_clear(&o);
  g_assert_cmpuint(fake->requests, ==, 0);
  fake_free(fake);
}

static void
test_net_get_programmer_errors(void)
{
  g_autoptr(WxHttp) http = wx_http_new("https://api.met.no", UA, NULL);
  Outcome o = {0};
  ASSERT_CRITICAL("wx_http_get_async", wx_http_get_async(NULL, "/x", JSON_ACCEPT, NULL, NULL, on_done, &o));
  ASSERT_CRITICAL("wx_http_get_async", wx_http_get_async(http, NULL, JSON_ACCEPT, NULL, NULL, on_done, &o));
  ASSERT_CRITICAL("wx_http_get_async", wx_http_get_async(http, "/x", NULL, NULL, NULL, on_done, &o));
  ASSERT_CRITICAL("wx_http_get_async",
                  wx_http_get_async(http, "/x", JSON_ACCEPT, NULL, (GCancellable *)http, on_done, &o));
  /* An instance made by a plain g_object_new() has no base URL and is refused. */
  WxHttp *raw = g_object_new(WX_TYPE_HTTP, NULL);
  ASSERT_CRITICAL("wx_http_get_async", wx_http_get_async(raw, "/x", JSON_ACCEPT, NULL, NULL, on_done, &o));
  g_object_unref(raw);
  g_assert_false(o.done);

  /* finish with a foreign result. */
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) other = http_for(fake, 2000, 10, 0);
  g_autoptr(GTask) foreign = g_task_new(other, NULL, NULL, NULL);
  ASSERT_CRITICAL("wx_http_get_finish", g_assert_null(wx_http_get_finish(http, G_ASYNC_RESULT(foreign), NULL)));
  ASSERT_CRITICAL("wx_http_get_finish", g_assert_null(wx_http_get_finish(NULL, G_ASYNC_RESULT(foreign), NULL)));
  g_autoptr(GTask) own_object_other_tag = g_task_new(other, NULL, NULL, NULL);
  ASSERT_CRITICAL("wx_http_get_finish",
                  g_assert_null(wx_http_get_finish(other, G_ASYNC_RESULT(own_object_other_tag), NULL)));
  fake_free(fake);
  wx_http_response_free(NULL); /* NULL is a no-op */
}

static void
run_failure_case(Step step, WxError code, guint expected_requests)
{
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, 30000, 5, 0); /* generous: valgrind inflates slowly */
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, WX_ERROR, (int)code);
  assert_no_body_text(o.error);
  g_assert_cmpuint(fake->requests, ==, expected_requests);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_status_mapping(void)
{
  /* Final failures are never retried. */
  run_failure_case((Step){STEP_RESPOND, 404, kBody, NULL, 0, 0}, WX_ERROR_NOT_FOUND, 1);
  run_failure_case((Step){STEP_RESPOND, 429, kBody, NULL, 0, 0}, WX_ERROR_RATE_LIMITED, 1);
  run_failure_case((Step){STEP_RESPOND, 400, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 401, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 403, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 410, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 422, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 301, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1); /* redirects not followed */
  run_failure_case((Step){STEP_RESPOND, 302, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 307, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 304, "", NULL, 0, 0}, WX_ERROR_HTTP, 1); /* 304 without If-Modified-Since */
  run_failure_case((Step){STEP_RAW, 0, "HTTP/1.1 600 X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", NULL, 0, 0},
                   WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RAW, 0, "HTTP/1.1 999 X\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}", NULL, 0, 0},
                   WX_ERROR_HTTP, 1);
  /* 5xx, closed connections and silence are retried WX_HTTP_MAX_RETRIES times. */
  run_failure_case((Step){STEP_RESPOND, 500, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES);
  run_failure_case((Step){STEP_RESPOND, 503, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES);
  run_failure_case((Step){STEP_RESPOND, 599, kBody, NULL, 0, 0}, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES);
  run_failure_case((Step){STEP_CLOSE, 0, NULL, NULL, 0, 0}, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES);
  /* Other 2xx are successes. */
  const guint ok[] = {200, 201, 202, 204, 206, 299};
  for (guint i = 0; i < G_N_ELEMENTS(ok); i++) {
    Step step = {STEP_RESPOND, ok[i], ok[i] == 204 ? "" : kBody, NULL, 0, 0};
    Fake *fake = fake_new(&step, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    g_assert_cmpuint(o.response->status, ==, ok[i]);
    outcome_clear(&o);
    fake_free(fake);
  }
}

static void
test_net_redirect_is_never_followed(void)
{
  Step other_script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *other = fake_new(other_script, 1);
  g_autofree char *headers = g_strdup_printf("Location: http://127.0.0.1:%u/stolen\r\n", other->port);
  const guint codes[] = {301, 302, 303, 307, 308};
  for (guint i = 0; i < G_N_ELEMENTS(codes); i++) {
    Step script[] = {{STEP_RESPOND, codes[i], "", headers, 0, 0}};
    Fake *fake = fake_new(script, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_null(o.response);
    g_assert_error(o.error, WX_ERROR, WX_ERROR_HTTP);
    g_assert_cmpuint(fake->requests, ==, 1);
    outcome_clear(&o);
    fake_free(fake);
  }
  g_assert_cmpuint(other->requests, ==, 0); /* the Location target was never contacted */
  fake_free(other);
}

static void
test_net_retry_then_success_with_backoff(void)
{
  Step script[] = {{STEP_RESPOND, 503, kBody, NULL, 0, 0}, {STEP_CLOSE, 0, NULL, NULL, 0, 0},
                   {STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 3);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 100, 0); /* waits 100 ms, then 200 ms */
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  gint64 elapsed_ms = wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.response);
  g_assert_cmpuint(fake->requests, ==, 3);
  g_assert_cmpint(elapsed_ms, >=, 295); /* 100 + 200 minus timer slack */
  /* The gaps between the arrivals are the back-offs. */
  g_assert_cmpint((fake_arrival_us(fake, 1) - fake_arrival_us(fake, 0)) / 1000, >=, 95);
  g_assert_cmpint((fake_arrival_us(fake, 2) - fake_arrival_us(fake, 1)) / 1000, >=, 195);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_backoff_doubles_and_failure_is_final(void)
{
  Step script[] = {{STEP_RESPOND, 502, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 80, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  gint64 elapsed_ms = wait_for(&o, start);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_HTTP);
  g_assert_cmpuint(fake->requests, ==, 3);
  g_assert_cmpint(elapsed_ms, >=, 235); /* 80 + 160 */
  g_assert_cmpint(elapsed_ms, <, 2000);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_connection_refused_is_network_error(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  fake_stop_listening(fake); /* connections are refused */
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_NETWORK);
  g_assert_cmpuint(fake->requests, ==, 0);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_per_attempt_timeout(void)
{
  Step script[] = {{STEP_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 150, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  gint64 elapsed_ms = wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fake->requests, ==, 1 + WX_HTTP_MAX_RETRIES);
  g_assert_cmpint(elapsed_ms, >=, 3 * 140); /* each attempt has its own deadline */
  g_assert_cmpint(elapsed_ms, <, 3000);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_body_cap(void)
{
  const gsize cap = WX_HTTP_MAX_BODY_BYTES;
  /* Declared Content-Length above the cap: refused before reading, final. */
  run_failure_case((Step){STEP_BIG_DECLARED, 0, NULL, NULL, cap + 1, 0}, WX_ERROR_PARSE, 1);
  run_failure_case((Step){STEP_BIG_DECLARED, 0, NULL, NULL, 50 * 1024 * 1024, 0}, WX_ERROR_PARSE, 1);
  /* Undeclared (streamed) bodies: one byte over the cap, and 5 MiB. */
  run_failure_case((Step){STEP_BIG_STREAMED, 0, NULL, NULL, cap + 1, 0}, WX_ERROR_PARSE, 1);
  run_failure_case((Step){STEP_BIG_STREAMED, 0, NULL, NULL, 5 * 1024 * 1024, 0}, WX_ERROR_PARSE, 1);
  run_failure_case((Step){STEP_RESPOND, 200, NULL, NULL, cap + 1, 0}, WX_ERROR_PARSE, 1);

  /* Exactly the cap is accepted, declared or streamed. */
  Step exact[] = {{STEP_RESPOND, 200, NULL, NULL, cap, 0}, {STEP_BIG_STREAMED, 0, NULL, NULL, cap, 0}};
  for (guint i = 0; i < G_N_ELEMENTS(exact); i++) {
    Fake *fake = fake_new(&exact[i], 1);
    g_autoptr(WxHttp) http = http_for(fake, 10000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    g_assert_cmpuint(g_bytes_get_size(o.response->body), ==, cap);
    outcome_clear(&o);
    fake_free(fake);
  }
}

static void
test_net_truncated_body(void)
{
  /* Declared 536 bytes, a complete-looking 36-byte JSON body, then EOF; and a cut JSON. */
  static const char valid_prefix[] =
      "HTTP/1.1 200 OK\r\nContent-Length: 536\r\nConnection: close\r\n\r\n{\"data\":null,\"status\":{\"rCode\":200}}";
  static const char cut_json[] = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{\"data\":";
  for (guint i = 0; i < 2; i++)
    run_failure_case((Step){STEP_RAW, 0, i == 0 ? valid_prefix : cut_json, NULL, 0, 0}, WX_ERROR_NETWORK,
                     1 + WX_HTTP_MAX_RETRIES); /* retryable */
}

/* How the body of a test response is framed. */
typedef enum {
  FR_CL,      /* Content-Length: @declared */
  FR_CHUNKED, /* Transfer-Encoding: chunked, one chunk that declares @declared bytes */
  FR_CLOSE    /* neither: the body ends when the server closes the connection */
} Framing;

/* A response with @status: the head (with @extra_headers, each line CRLF-terminated) framed as
 * @framing, then the first @send_len bytes of @payload; for FR_CHUNKED a chunk declaring @declared
 * bytes (omitted when 0), and the final empty chunk when @terminate. */
static GBytes *
framed_response(guint status, Framing framing, const char *extra_headers, const guint8 *payload,
                gsize send_len, gsize declared, gboolean terminate)
{
  g_autofree char *framing_header =
      framing == FR_CL ? g_strdup_printf("Content-Length: %" G_GSIZE_FORMAT "\r\n", declared)
                       : g_strdup(framing == FR_CHUNKED ? "Transfer-Encoding: chunked\r\n" : "");
  g_autofree char *head = g_strdup_printf(
      "HTTP/1.1 %u X\r\nContent-Type: application/json\r\n%s%sConnection: close\r\n\r\n", status,
      extra_headers, framing_header);
  GByteArray *all = g_byte_array_new();
  g_byte_array_append(all, (const guint8 *)head, (guint)strlen(head));
  if (framing == FR_CHUNKED) {
    if (declared > 0) {
      g_autofree char *size_line = g_strdup_printf("%" G_GSIZE_MODIFIER "x\r\n", declared);
      g_byte_array_append(all, (const guint8 *)size_line, (guint)strlen(size_line));
      g_byte_array_append(all, payload, (guint)send_len);
      if (send_len == declared)
        g_byte_array_append(all, (const guint8 *)"\r\n", 2);
    }
    if (terminate)
      g_byte_array_append(all, (const guint8 *)"0\r\n\r\n", 5);
  } else {
    g_byte_array_append(all, payload, (guint)send_len);
  }
  return g_byte_array_free_to_bytes(all);
}

/* A 200 response framed by Content-Length @declared that carries the first @send_len bytes. */
static GBytes *
response_with(const char *extra_headers, const guint8 *payload, gsize send_len, gsize declared)
{
  return framed_response(200, FR_CL, extra_headers, payload, send_len, declared, TRUE);
}

/* A chunked 200 response: one chunk that declares @declared_chunk bytes and carries @send_len of
 * @payload, then (when @terminate) the final empty chunk. */
static GBytes *
chunked_response(const char *extra_headers, const guint8 *payload, gsize send_len, gsize declared_chunk,
                 gboolean terminate)
{
  return framed_response(200, FR_CHUNKED, extra_headers, payload, send_len, declared_chunk, terminate);
}

#define OK_BODY (-1) /* run_step_case(): expect success */

/* When set, the next run_step_case() failure message must contain this text (then it is reset). */
static const char *expect_error_text;

/* Runs @step once per request, the request carrying If-Modified-Since @ims (NULL: none), and
 * checks the outcome: success with the body @expect_body (code OK_BODY), or the error @code after
 * exactly @expected_requests requests. */
static void
run_step_case_ims(Step step, const char *ims, int code, guint expected_requests, const char *expect_body,
                  guint timeout_ms)
{
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, timeout_ms, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", ims, NULL, &o, &start);
  wait_for(&o, start);
  if (code == OK_BODY) {
    g_assert_no_error(o.error);
    gsize len;
    const char *data = g_bytes_get_data(o.response->body, &len);
    g_assert_cmpmem(data, len, expect_body, strlen(expect_body));
  } else {
    g_assert_null(o.response);
    g_assert_error(o.error, WX_ERROR, code);
    assert_no_body_text(o.error);
    if (expect_error_text != NULL)
      g_assert_nonnull(strstr(o.error->message, expect_error_text));
  }
  expect_error_text = NULL;
  g_assert_cmpuint(fake->requests, ==, expected_requests);
  outcome_clear(&o);
  fake_free(fake);
}

/* run_step_case_ims() without If-Modified-Since. */
static void
run_step_case(Step step, int code, guint expected_requests, const char *expect_body, guint timeout_ms)
{
  run_step_case_ims(step, NULL, code, expected_requests, expect_body, timeout_ms);
}

/* Serves @response once per request (closing the connection) to a request that carries
 * If-Modified-Since @ims (NULL: none) and checks the outcome as run_step_case_ims() does. */
static void
run_bytes_case_ims(GBytes *response, const char *ims, int code, guint expected_requests,
                   const char *expect_body, guint timeout_ms)
{
  gsize response_len;
  const char *response_data = g_bytes_get_data(response, &response_len);
  run_step_case_ims((Step){STEP_BYTES, 0, response_data, NULL, response_len, 0}, ims, code, expected_requests,
                    expect_body, timeout_ms);
}

/* Serves @response once per request (closing the connection, or, with @hang, leaving it open
 * after the bytes) and checks the outcome as run_step_case() does. */
static void
run_bytes_case(GBytes *response, gboolean hang, int code, guint expected_requests, const char *expect_body,
               guint timeout_ms)
{
  gsize response_len;
  const char *response_data = g_bytes_get_data(response, &response_len);
  run_step_case((Step){hang ? STEP_BYTES_HANG : STEP_BYTES, 0, response_data, NULL, response_len, 0}, code,
                expected_requests, expect_body, timeout_ms);
}

/* Like run_bytes_case(), but the server sends the first @first bytes, waits @delay_ms and sends
 * the rest, so the client sees the two parts in separate reads. */
static void
run_split_case_delay(GBytes *response, gsize first, guint delay_ms, int code, guint expected_requests,
                     const char *expect_body)
{
  gsize response_len;
  const char *response_data = g_bytes_get_data(response, &response_len);
  g_assert_cmpuint(first, <, response_len);
  run_step_case((Step){STEP_BYTES_SPLIT, (guint)first, response_data, NULL, response_len, delay_ms}, code,
                expected_requests, expect_body, 5000);
}

/* run_split_case_delay() with a 100 ms pause. */
static void
run_split_case(GBytes *response, gsize first, int code, guint expected_requests, const char *expect_body)
{
  run_split_case_delay(response, first, 100, code, expected_requests, expect_body);
}

static const char kGzipJson[] =
    "{\"data\":null,\"status\":{\"rCode\":200},\"SENTINEL-BODY-TEXT\":[1,2,3,4,5,6,7,8,9,10,11,12]}";

/* Cut positions tried by default; every position when GLib runs the slow tests (-m slow). */
static gboolean
cut_position_wanted(gsize k, gsize n)
{
  return g_test_slow() || k < 3 || (k >= 9 && k <= 12) || k == n / 2 || (k + 12 >= n && k + 6 <= n) ||
         k + 3 >= n;
}

static void
test_net_gzip(void)
{
  /* Content-Length counts the compressed bytes: it must not be compared with the decoded length. */
  static const char json[] = "{\"data\":null,\"status\":{\"rCode\":200}}";
  Step step = {STEP_GZIP, 0, json, NULL, 0, 0};
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  gsize len;
  const char *data = g_bytes_get_data(o.response->body, &len);
  g_assert_cmpmem(data, len, json, strlen(json));
  g_assert_cmpuint(fake->requests, ==, 1);
  /* The client offers gzip and nothing else (libsoup's own deflate/br offer is switched off). */
  g_assert_nonnull(g_strstr_len(fake_head(fake, 0), -1, "\r\nAccept-Encoding: gzip\r\n"));
  g_assert_null(g_strstr_len(fake_head(fake, 0), -1, "deflate"));
  g_assert_null(g_strstr_len(fake_head(fake, 0), -1, ", br"));
  outcome_clear(&o);
  fake_free(fake);

  /* The cap applies AFTER decoding: ~5 KiB of gzip that inflate to 5 MiB are refused (a bomb). */
  run_failure_case((Step){STEP_GZIP, 0, NULL, NULL, (gsize)5 * 1024 * 1024, 0}, WX_ERROR_PARSE, 1);
  run_failure_case((Step){STEP_GZIP, 0, NULL, NULL, (gsize)WX_HTTP_MAX_BODY_BYTES + 1, 0}, WX_ERROR_PARSE, 1);
  run_failure_case((Step){STEP_GZIP, 0, NULL, NULL, (gsize)200 * 1024 * 1024, 0}, WX_ERROR_PARSE, 1);
  /* Exactly the cap, decoded, is fine. */
  Step exact = {STEP_GZIP, 0, NULL, NULL, (gsize)WX_HTTP_MAX_BODY_BYTES, 0};
  Fake *fake2 = fake_new(&exact, 1);
  g_autoptr(WxHttp) http2 = http_for(fake2, 60000, 5, 0);
  get(http2, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_cmpuint(g_bytes_get_size(o.response->body), ==, WX_HTTP_MAX_BODY_BYTES);
  outcome_clear(&o);
  fake_free(fake2);
}

/* A truncated gzip body is a failed transfer, whatever the HTTP framing says. */
static void
test_net_gzip_truncated(void)
{
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  const guint8 *z = g_bytes_get_data(packed, NULL);
  gsize n = g_bytes_get_size(packed);
  const char *gz = "Content-Encoding: gzip\r\n";
  g_assert_cmpuint(n, >, 30);

  /* Control: the complete body succeeds. */
  g_autoptr(GBytes) whole = response_with(gz, z, n, n);
  run_bytes_case(whole, FALSE, OK_BODY, 1, kGzipJson, 2000);

  guint tried = 0;
  for (gsize k = 0; k < n; k++) {
    if (!cut_position_wanted(k, n))
      continue;
    tried++;
    /* (a) the connection is cut: Content-Length promises more than arrives. */
    g_autoptr(GBytes) cut = response_with(gz, z, k, n);
    run_bytes_case(cut, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
    /* (b) the HTTP message is complete (Content-Length matches what is sent) but the gzip
     * stream is not: cut short anywhere, a missing trailer (k == n - 8) included. */
    g_autoptr(GBytes) short_body = response_with(gz, z, k, k);
    run_bytes_case(short_body, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  }
  g_assert_cmpuint(tried, >=, 12);

  /* The gzip stream is complete but the connection ended before the declared Content-Length: the
   * HTTP message itself is incomplete (and the cut may have taken a second member with it). */
  g_autoptr(GBytes) overdeclared = response_with(gz, z, n, n + 10);
  run_bytes_case(overdeclared, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  /* Corruption: a flipped bit in the data, in the CRC and in the length field. */
  const gsize flips[] = {n / 2, n - 8, n - 7, n - 4, n - 1};
  for (guint i = 0; i < G_N_ELEMENTS(flips); i++) {
    g_autofree guint8 *bad = g_memdup2(z, n);
    bad[flips[i]] ^= 0x01;
    g_autoptr(GBytes) corrupt = response_with(gz, bad, n, n);
    run_bytes_case(corrupt, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  }
  /* Not gzip at all, and an empty body that claims to be gzip. */
  g_autoptr(GBytes) not_gzip = response_with(gz, (const guint8 *)"plain text, not gzip", 20, 20);
  run_bytes_case(not_gzip, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  g_autoptr(GBytes) empty = response_with(gz, z, 0, 0);
  run_bytes_case(empty, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);

  /* Data after the end of the gzip stream (garbage, or a second member) is refused, not retried. */
  g_autofree guint8 *two = g_malloc(2 * n + 3);
  memcpy(two, z, n);
  memcpy(two + n, "xyz", 3);
  g_autoptr(GBytes) garbage = response_with(gz, two, n + 3, n + 3);
  run_bytes_case(garbage, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
  memcpy(two + n, z, n);
  g_autoptr(GBytes) second = response_with(gz, two, 2 * n, 2 * n);
  run_bytes_case(second, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
  g_autoptr(GBytes) one_byte = response_with(gz, two, n + 1, n + 1);
  run_bytes_case(one_byte, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
  /* The extra bytes arrive in a LATER read than the end of the gzip stream. */
  gsize garbage_len = g_bytes_get_size(garbage);
  run_split_case(garbage, garbage_len - 3, WX_ERROR_PARSE, 1, NULL);
  /* A complete body that merely arrives in two reads is fine. */
  g_autoptr(GBytes) in_two = response_with(gz, z, n, n);
  run_split_case(in_two, g_bytes_get_size(in_two) - n / 2, OK_BODY, 1, kGzipJson);

  /* The same cut, but the server keeps the connection open: the per-attempt deadline ends it. */
  g_autoptr(GBytes) stalled = response_with(gz, z, n / 2, n);
  run_bytes_case(stalled, TRUE, WX_ERROR_TIMEOUT, 1 + WX_HTTP_MAX_RETRIES, NULL, 300);
}

/* Chunked responses have no Content-Length; the framing and the gzip trailer carry the check. */
static void
test_net_chunked(void)
{
  const char json[] = "{\"chunked\":true}";
  const gsize jn = strlen(json);
  g_autoptr(GBytes) ok = chunked_response("", (const guint8 *)json, jn, jn, TRUE);
  run_bytes_case(ok, FALSE, OK_BODY, 1, json, 2000);
  /* A chunk that stops short, and a body that lacks its final chunk: libsoup refuses both. */
  g_autoptr(GBytes) short_chunk = chunked_response("", (const guint8 *)json, jn / 2, jn, FALSE);
  run_bytes_case(short_chunk, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  g_autoptr(GBytes) no_final = chunked_response("", (const guint8 *)json, jn, jn, FALSE);
  run_bytes_case(no_final, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);

  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  const guint8 *z = g_bytes_get_data(packed, NULL);
  gsize n = g_bytes_get_size(packed);
  const char *gz = "Content-Encoding: gzip\r\n";
  g_autoptr(GBytes) gz_ok = chunked_response(gz, z, n, n, TRUE);
  run_bytes_case(gz_ok, FALSE, OK_BODY, 1, kGzipJson, 2000);
  /* Properly framed chunks that carry a cut gzip stream, and a gzip stream missing its trailer. */
  for (gsize k = 1; k < n; k++) {
    if (!cut_position_wanted(k, n))
      continue;
    g_autoptr(GBytes) cut = chunked_response(gz, z, k, k, TRUE);
    run_bytes_case(cut, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  }
  /* Cut inside the chunk, and complete data without the final chunk. */
  g_autoptr(GBytes) gz_short_chunk = chunked_response(gz, z, n / 2, n, FALSE);
  run_bytes_case(gz_short_chunk, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  g_autoptr(GBytes) gz_no_final = chunked_response(gz, z, n, n, FALSE);
  run_bytes_case(gz_no_final, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  /* Garbage in a further chunk after the gzip stream is refused. */
  g_autofree guint8 *extra = g_malloc(n + 2);
  memcpy(extra, z, n);
  memcpy(extra + n, "zz", 2);
  g_autoptr(GBytes) gz_trailing = chunked_response(gz, extra, n + 2, n + 2, TRUE);
  run_bytes_case(gz_trailing, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
}

/*
 * Content-Encoding is a content-coding LIST (RFC 9110 5.6.1.2): blanks and empty elements are
 * dropped, "identity" is dropped, and what is left must be nothing or exactly one gzip/x-gzip
 * (case-insensitive); several header lines are one list. Anything else is a server ignoring
 * Accept-Encoding: WX_ERROR_PARSE, not retried.
 */
static void
test_net_content_coding(void)
{
  static const struct {
    const char *headers;
    gboolean gzip_body; /* the body is gzip-compressed (else plain text) */
    gboolean accepted;
  } rows[] = {
      /* No coding. */
      {"", FALSE, TRUE},
      {"Content-Encoding:\r\n", FALSE, TRUE},
      {"Content-Encoding: \r\n", FALSE, TRUE},
      {"Content-Encoding: ,\r\n", FALSE, TRUE},
      {"Content-Encoding: identity\r\n", FALSE, TRUE},
      {"Content-Encoding: IDENTITY, identity\r\n", FALSE, TRUE},
      {"Content-Encoding: identity,\r\n", FALSE, TRUE},
      /* gzip, in every spelling of the list. */
      {"Content-Encoding: gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: GZIP\r\n", TRUE, TRUE},
      {"Content-Encoding: GZip\r\n", TRUE, TRUE},
      {"Content-Encoding: x-gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: X-Gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: gzip,\r\n", TRUE, TRUE},
      {"Content-Encoding: , gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: ,gzip,,\r\n", TRUE, TRUE},
      {"Content-Encoding:  gzip \r\n", TRUE, TRUE},
      {"Content-Encoding: identity, gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: gzip, identity\r\n", TRUE, TRUE},
      {"Content-Encoding: identity\r\nContent-Encoding: gzip\r\n", TRUE, TRUE},
      {"Content-Encoding: gzip\r\nContent-Encoding: identity\r\n", TRUE, TRUE},
      {"Content-Encoding:\r\nContent-Encoding: gzip\r\n", TRUE, TRUE},
      /* Refused: another coding, a parameter, gzip twice, gzip with another coding. */
      {"Content-Encoding: gzip, gzip\r\n", TRUE, FALSE},
      {"Content-Encoding: gzip\r\nContent-Encoding: gzip\r\n", TRUE, FALSE},
      {"Content-Encoding: x-gzip, gzip\r\n", TRUE, FALSE},
      {"Content-Encoding: gzip;q=1\r\n", TRUE, FALSE},
      {"Content-Encoding: \"gzip\"\r\n", TRUE, FALSE},
      {"Content-Encoding: gzip gzip\r\n", TRUE, FALSE},
      {"Content-Encoding: gzip, br\r\n", TRUE, FALSE},
      {"Content-Encoding: br, gzip\r\n", TRUE, FALSE},
      {"Content-Encoding: deflate\r\n", FALSE, FALSE},
      {"Content-Encoding: br\r\n", FALSE, FALSE},
      {"Content-Encoding: compress\r\n", FALSE, FALSE},
      {"Content-Encoding: zstd\r\n", FALSE, FALSE},
      {"Content-Encoding: x-compress\r\n", FALSE, FALSE},
      {"Content-Encoding: identity, deflate\r\n", FALSE, FALSE},
      {"Content-Encoding: gzipp\r\n", TRUE, FALSE},
      {"Content-Encoding: gz\r\n", TRUE, FALSE},
  };
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  const guint8 *z = g_bytes_get_data(packed, NULL);
  gsize n = g_bytes_get_size(packed);
  for (guint i = 0; i < G_N_ELEMENTS(rows); i++) {
    const guint8 *payload = rows[i].gzip_body ? z : (const guint8 *)kBody;
    gsize len = rows[i].gzip_body ? n : strlen(kBody);
    g_autoptr(GBytes) response = response_with(rows[i].headers, payload, len, len);
    if (rows[i].accepted)
      run_bytes_case(response, FALSE, OK_BODY, 1, rows[i].gzip_body ? kGzipJson : kBody, 2000);
    else
      run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000); /* final: not retried */
  }
  /* The list is parsed whatever the framing. */
  g_autoptr(GBytes) chunked_ok = chunked_response("Content-Encoding: identity, gzip,\r\n", z, n, n, TRUE);
  run_bytes_case(chunked_ok, FALSE, OK_BODY, 1, kGzipJson, 2000);
  g_autoptr(GBytes) chunked_bad = chunked_response("Content-Encoding: gzip, gzip\r\n", z, n, n, TRUE);
  run_bytes_case(chunked_bad, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
}

static GBytes *
concat_bytes(GBytes *head, const guint8 *tail, gsize tail_len)
{
  GByteArray *all = g_byte_array_new();
  gsize head_len;
  const guint8 *head_data = g_bytes_get_data(head, &head_len);
  g_byte_array_append(all, head_data, (guint)head_len);
  g_byte_array_append(all, tail, (guint)tail_len);
  return g_byte_array_free_to_bytes(all);
}

/*
 * Bytes that arrive AFTER the gzip stream is complete are refused with WX_ERROR_PARSE (not
 * retried, 1 request) in every framing and every split: the complete stream goes out in one TCP
 * write and the extra bytes in a separate, later one. A server that declares a longer
 * Content-Length and then never sends the rest is a cut connection instead: WX_ERROR_NETWORK
 * (retried).
 */
static void
test_net_gzip_late_trailing_data(void)
{
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  const guint8 *z = g_bytes_get_data(packed, NULL);
  gsize n = g_bytes_get_size(packed);
  const char *gz = "Content-Encoding: gzip\r\n";
  const struct {
    const guint8 *data;
    gsize len;
  } trailers[] = {
      {(const guint8 *)"x", 1},        /* one garbage byte */
      {(const guint8 *)"\0\0\0\0", 4}, /* zero padding (some tools pad archives) */
      {(const guint8 *)"\n", 1},       /* a newline */
      {z, n},                          /* a second, valid gzip member */
  };
  const guint delays[] = {100, 700}; /* a short and a long idle gap */
  for (guint t = 0; t < G_N_ELEMENTS(trailers); t++) {
    for (guint d = 0; d < G_N_ELEMENTS(delays); d++) {
      if (d > 0 && t > 0)
        continue; /* the long gap once per framing is enough */
      const guint8 *tail = trailers[t].data;
      gsize tail_len = trailers[t].len;

      /* Content-Length covers the stream and the extra bytes. */
      g_autoptr(GBytes) with_tail = concat_bytes(packed, tail, tail_len);
      g_autoptr(GBytes) cl = framed_response(200, FR_CL, gz, g_bytes_get_data(with_tail, NULL), n + tail_len,
                                             n + tail_len, TRUE);
      expect_error_text = "continues after"; /* the guard, not the same-read check */
      run_split_case_delay(cl, g_bytes_get_size(cl) - tail_len, delays[d], WX_ERROR_PARSE, 1, NULL);

      /* Close-delimited. */
      g_autoptr(GBytes) close_delimited =
          framed_response(200, FR_CLOSE, gz, g_bytes_get_data(with_tail, NULL), n + tail_len, 0, TRUE);
      expect_error_text = "continues after";
      run_split_case_delay(close_delimited, g_bytes_get_size(close_delimited) - tail_len, delays[d],
                           WX_ERROR_PARSE, 1, NULL);

      /* Chunked: the stream is the first chunk, the extra bytes a second chunk. */
      g_autoptr(GBytes) first_chunk = chunked_response(gz, z, n, n, FALSE);
      g_autofree char *second_head = g_strdup_printf("%" G_GSIZE_MODIFIER "x\r\n", tail_len);
      g_autoptr(GBytes) with_head = concat_bytes(first_chunk, (const guint8 *)second_head, strlen(second_head));
      g_autoptr(GBytes) with_data = concat_bytes(with_head, tail, tail_len);
      g_autoptr(GBytes) chunked = concat_bytes(with_data, (const guint8 *)"\r\n0\r\n\r\n", 7);
      expect_error_text = "continues after";
      run_split_case_delay(chunked, g_bytes_get_size(first_chunk), delays[d], WX_ERROR_PARSE, 1, NULL);
    }
  }
  /* Control: the same split without extra bytes is a success. */
  g_autoptr(GBytes) clean = chunked_response(gz, z, n, n, TRUE);
  run_split_case(clean, g_bytes_get_size(clean) - 5, OK_BODY, 1, kGzipJson);
  /* A longer Content-Length than the gzip stream, never completed: a cut connection. */
  g_autoptr(GBytes) never = response_with(gz, z, n, n + 5);
  run_bytes_case(never, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
}

/* 204, 205 and a 304 to a conditional request carry no content: success with an EMPTY body, one
 * request, whatever Content-Encoding says (it describes content that does not exist) and with or
 * without a Content-Length of 0. */
static void
test_net_no_content_statuses(void)
{
  const char *codings[] = {"", "Content-Encoding: gzip\r\n", "Content-Encoding: br\r\n",
                           "Content-Encoding: deflate\r\n", "Content-Encoding: gzip, gzip\r\n",
                           "Content-Encoding: identity\r\n"};
  const struct {
    guint status;
    const char *ims; /* If-Modified-Since to send, or NULL */
  } statuses[] = {{204, NULL}, {205, NULL}, {304, "Sun, 06 Nov 1994 08:49:37 GMT"}};
  for (guint s = 0; s < G_N_ELEMENTS(statuses); s++) {
    for (guint c = 0; c < G_N_ELEMENTS(codings); c++) {
      for (guint f = 0; f < 2; f++) {
        g_autoptr(GBytes) response =
            framed_response(statuses[s].status, f == 0 ? FR_CL : FR_CLOSE, codings[c], NULL, 0, 0, TRUE);
        gsize len;
        const char *data = g_bytes_get_data(response, &len);
        Step step = {STEP_BYTES, 0, data, NULL, len, 0};
        Fake *fake = fake_new(&step, 1);
        g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
        Outcome o = {0};
        gint64 start;
        get(http, "/x", statuses[s].ims, NULL, &o, &start);
        wait_for(&o, start);
        g_assert_no_error(o.error);
        g_assert_cmpuint(o.response->status, ==, statuses[s].status);
        g_assert_nonnull(o.response->body);
        g_assert_cmpuint(g_bytes_get_size(o.response->body), ==, 0);
        g_assert_cmpuint(fake->requests, ==, 1);
        outcome_clear(&o);
        fake_free(fake);
      }
    }
  }
  /* A 200 with an empty body that CLAIMS to be gzip is not bodiless: its 20-byte empty member is
   * missing, so it is a failed transfer. The same 200 without a coding is an empty success. */
  g_autoptr(GBytes) empty_gzip = response_with("Content-Encoding: gzip\r\n", (const guint8 *)"", 0, 0);
  run_bytes_case(empty_gzip, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  g_autoptr(GBytes) empty_plain = response_with("", (const guint8 *)"", 0, 0);
  run_bytes_case(empty_plain, FALSE, OK_BODY, 1, "", 2000);
  /* A 304 that was NOT asked for is an error, with or without Content-Encoding. */
  run_failure_case((Step){STEP_RESPOND, 304, "", "Content-Encoding: gzip\r\n", 0, 0}, WX_ERROR_HTTP, 1);
  run_failure_case((Step){STEP_RESPOND, 304, "", NULL, 0, 0}, WX_ERROR_HTTP, 1);
}

/* ----------------------------------------------------------------------------------------------
 * Content-Length: overflowing, negative, malformed and repeated values
 * -------------------------------------------------------------------------------------------- */

/* A hostile Content-Length never reaches libsoup's number conversion: libsoup stores the unsigned
 * value in a signed 64 bit field and its body stream logs a GObject CRITICAL for a negative one,
 * so WxHttp validates the raw header when the status arrives and replaces or removes it before
 * libsoup converts it (wx-http.h). The tests below run with every critical and warning fatal in
 * every domain (g_test_init() sets that, test_net_criticals_are_fatal() checks it), so any log line
 * of that kind aborts the process and fails them; the cases are also run under
 * G_DEBUG=fatal-criticals,fatal-warnings. */

typedef enum {
  VK_LARGE,    /* PARSE "response too large" */
  VK_INVALID,  /* PARSE "invalid Content-Length" */
  VK_CONFLICT, /* PARSE "conflicting Content-Length values" */
  VK_FRAMING,  /* PARSE "unsupported response framing" (a Transfer-Encoding that is not exactly chunked) */
  VK_LENGTH,   /* a length equal to the payload size: success when the payload is complete */
  VK_CAP       /* the largest accepted length, more than the payload: a cut connection */
} ValueKind;

/* Replaces '@' by @n and '$' by @n + 1 in @tmpl. */
static char *
subst_length(const char *tmpl, gsize n)
{
  g_autofree char *a = g_strdup_printf("%" G_GSIZE_FORMAT, n);
  g_autofree char *b = g_strdup_printf("%" G_GSIZE_FORMAT, n + 1);
  GString *s = g_string_new(tmpl);
  g_string_replace(s, "@", a, 0);
  g_string_replace(s, "$", b, 0);
  return g_string_free(s, FALSE);
}

/* Serves a 200 whose head is @extra and whose body is @payload (first @send_len bytes, then the
 * connection closes) and checks the outcome the class @kind documents. */
static void
run_length_case(const char *extra, const guint8 *payload, gsize send_len, ValueKind kind, gboolean complete,
                const char *plain)
{
  g_autoptr(GBytes) response = framed_response(200, FR_CLOSE, extra, payload, send_len, 0, TRUE);
  switch (kind) {
  case VK_LARGE:
    expect_error_text = "response too large";
    run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    break;
  case VK_INVALID:
    expect_error_text = "invalid Content-Length";
    run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    break;
  case VK_CONFLICT:
    expect_error_text = "conflicting Content-Length";
    run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    break;
  case VK_FRAMING:
    expect_error_text = "unsupported response framing";
    run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    break;
  case VK_LENGTH:
    if (complete)
      run_bytes_case(response, FALSE, OK_BODY, 1, plain, 2000);
    else
      run_bytes_case(response, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
    break;
  case VK_CAP:
    run_bytes_case(response, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
    break;
  }
}

/* Content-Length is a single unsigned decimal number (RFC 9110 8.6) within the cap: an overflowing
 * value (which libsoup would wrap negative), a sign, hex, garbage or an empty value is a PARSE
 * failure BEFORE any body byte is read (one request, not retried), and a length that is valid but
 * not met by the body is a cut connection. Every value x {identity, gzip} x {complete, cut}. */
static void
test_net_content_length_values(void)
{
  static const struct {
    const char *value; /* '@' stands for the payload size */
    ValueKind kind;
  } values[] = {
      {"18446744073709551615", VK_LARGE},
      {"18446744073709551614", VK_LARGE},
      {"18446744073709551616", VK_LARGE},
      {"99999999999999999999999", VK_LARGE},
      {"9223372036854775808", VK_LARGE},
      {"9223372036854775807", VK_LARGE},
      {"4194305", VK_LARGE},
      {"0000000000000000000000004194305", VK_LARGE},
      {"4194304", VK_CAP},
      {"-1", VK_INVALID},
      {"-2", VK_INVALID},
      {"-9223372036854775808", VK_INVALID},
      {"+5", VK_INVALID},
      {"", VK_INVALID},
      {"5x", VK_INVALID},
      {"0x10", VK_INVALID},
      {"1e3", VK_INVALID},
      {"5 5", VK_INVALID},
      {"5.0", VK_INVALID},
      {"@, @", VK_LENGTH},
      {"@,@", VK_LENGTH},
      {"@, $", VK_CONFLICT},
      {"@ ,", VK_INVALID},
      {"@", VK_LENGTH},
      {" @ ", VK_LENGTH},
      {"00@", VK_LENGTH},
  };
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  for (guint g = 0; g < 2; g++) {
    gboolean gzip = g == 1;
    const guint8 *payload = gzip ? g_bytes_get_data(packed, NULL) : (const guint8 *)kBody;
    gsize len = gzip ? g_bytes_get_size(packed) : strlen(kBody);
    for (guint v = 0; v < G_N_ELEMENTS(values); v++) {
      for (guint complete = 0; complete < 2; complete++) {
        g_autofree char *value = subst_length(values[v].value, len);
        g_autofree char *extra =
            g_strdup_printf("%sContent-Length: %s\r\n", gzip ? "Content-Encoding: gzip\r\n" : "", value);
        g_test_message("gzip %d Content-Length '%s' complete %u", gzip, value, complete);
        run_length_case(extra, payload, complete ? len : len / 2, values[v].kind, complete, gzip ? kGzipJson : kBody);
      }
    }
  }
}

/* Several Content-Length lines and comma lists (RFC 9112 6.3): identical values are one value,
 * distinct ones an unrecoverable framing error; and with Transfer-Encoding the length is not
 * consulted at all. */
static void
test_net_content_length_repeated(void)
{
  static const struct {
    const char *lines; /* '@' = payload size, '$' = payload size + 1 */
    ValueKind kind;
  } rows[] = {
      {"Content-Length: @\r\nContent-Length: @\r\n", VK_LENGTH},
      {"Content-Length: @\r\nContent-Length: 00@\r\n", VK_LENGTH},
      {"Content-Length: 00@\r\nContent-Length: @\r\n", VK_LENGTH},
      {"Content-Length: @\r\nContent-Length: @\r\nContent-Length: @\r\n", VK_LENGTH},
      {"Content-Length: @\r\nContent-Length: $\r\n", VK_CONFLICT},
      {"Content-Length: $\r\nContent-Length: @\r\n", VK_CONFLICT},
      {"Content-Length: @\r\nContent-Length: $\r\nContent-Length: @\r\n", VK_CONFLICT},
      {"Content-Length: @\r\nContent-Length: 99999999999999999999999\r\n", VK_CONFLICT},
      {"Content-Length: 9223372036854775808\r\nContent-Length: @\r\n", VK_CONFLICT},
      {"Content-Length: 7\r\nContent-Length: 3\r\n", VK_CONFLICT},
      {"Content-Length: @\r\nContent-Length: \r\n", VK_INVALID},
      {"Content-Length: \r\nContent-Length: @\r\n", VK_INVALID},
      {"Content-Length: x\r\nContent-Length: @\r\n", VK_INVALID},
      {"Content-Length: @\r\nContent-Length: x\r\n", VK_INVALID},
      {"Content-Length: @, @\r\n", VK_LENGTH},
      {"Content-Length: @, $\r\n", VK_CONFLICT},
      /* A comma list is read by WxHttp in any line (libsoup only ever sees the one canonical
       * number it is rewritten to): blanks and tabs around its elements do not matter. */
      {"Content-Length: @ , @ \r\nContent-Length: @\r\n", VK_LENGTH},
      {"Content-Length: \t@\t,\t00@ ,@\r\nContent-Length: @\r\n", VK_LENGTH},
      {"Content-Length: @ , $ \r\nContent-Length: @\r\n", VK_CONFLICT},
      {"Content-Length: @ ,  \r\nContent-Length: @\r\n", VK_INVALID},
  };
  static const char *const ignored[] = {"Content-Length: 3\r\n",
                                        "Content-Length: 5x\r\n",
                                        "Content-Length: 9223372036854775808\r\n",
                                        "Content-Length: 18446744073709551615\r\n",
                                        "Content-Length: -1\r\n",
                                        "Content-Length: \r\n",
                                        "Content-Length: 7, 3\r\n",
                                        "Content-Length: @\r\nContent-Length: $\r\n"};
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  for (guint g = 0; g < 2; g++) {
    gboolean gzip = g == 1;
    const char *coding = gzip ? "Content-Encoding: gzip\r\n" : "";
    const guint8 *payload = gzip ? g_bytes_get_data(packed, NULL) : (const guint8 *)kBody;
    gsize len = gzip ? g_bytes_get_size(packed) : strlen(kBody);
    const char *plain = gzip ? kGzipJson : kBody;
    for (guint r = 0; r < G_N_ELEMENTS(rows); r++) {
      for (guint complete = 0; complete < 2; complete++) {
        g_autofree char *lines = subst_length(rows[r].lines, len);
        g_autofree char *extra = g_strconcat(coding, lines, NULL);
        g_test_message("gzip %d row %u complete %u", gzip, r, complete);
        run_length_case(extra, payload, complete ? len : len / 2, rows[r].kind, complete, plain);
      }
    }
    /* Transfer-Encoding: chunked wins: whatever Content-Length says, the chunked body is read. */
    for (guint r = 0; r < G_N_ELEMENTS(ignored); r++) {
      g_autofree char *lines = subst_length(ignored[r], len);
      g_autofree char *extra = g_strconcat(coding, lines, NULL);
      g_autoptr(GBytes) response = framed_response(200, FR_CHUNKED, extra, payload, len, len, TRUE);
      g_test_message("chunked gzip %d ignored row %u", gzip, r);
      run_bytes_case(response, FALSE, OK_BODY, 1, plain, 2000);
    }
  }
}

/* ---- Randomized Content-Length lines against an independent oracle ---- */

/* The oracle, written from RFC 9110 8.6 / RFC 9112 6.3 and the documented cap and working on the
 * decimal TEXT only (no conversion that could overflow): every comma separated element of every
 * line, trimmed of blanks and tabs, must be 1*DIGIT, all must have the same value, and the value
 * must not exceed the cap. Returns ORACLE_PARSE for any violation (a single line that libsoup
 * cannot frame, a comma list in the LAST line, is the same PARSE), else the length. */
#define ORACLE_PARSE (-1)

static gint64
oracle_length(char *const *lines, guint n_lines)
{
  g_autofree char *first = NULL; /* digits of the first element, leading zeros stripped */
  gsize first_len = 0;
  gboolean conflict = FALSE;
  for (guint l = 0; l < n_lines; l++) {
    g_auto(GStrv) elements = g_strsplit(lines[l], ",", -1);
    for (guint e = 0; elements[e] != NULL; e++) {
      const char *text = elements[e];
      while (*text == ' ' || *text == '\t')
        text++;
      gsize len = strlen(text);
      while (len > 0 && (text[len - 1] == ' ' || text[len - 1] == '\t'))
        len--;
      if (len == 0)
        return ORACLE_PARSE;
      for (gsize i = 0; i < len; i++)
        if (text[i] < '0' || text[i] > '9')
          return ORACLE_PARSE;
      while (len > 1 && *text == '0') {
        text++;
        len--;
      }
      if (first == NULL) {
        first = g_strndup(text, len);
        first_len = len;
      } else if (len != first_len || memcmp(text, first, len) != 0) {
        conflict = TRUE;
      }
    }
  }
  if (first == NULL || conflict)
    return ORACLE_PARSE; /* an empty line has no element at all: not a number */
  if (first_len > 7)
    return ORACLE_PARSE; /* more than 9999999 > 4194304 */
  gint64 value = 0;
  for (gsize i = 0; i < first_len; i++)
    value = value * 10 + (first[i] - '0');
  return value > WX_HTTP_MAX_BODY_BYTES ? ORACLE_PARSE : value;
}

static char *
random_length_value(GRand *rng, gsize payload_len)
{
  static const char *const specials[] = {"0",         "1",        "9223372036854775807",  "9223372036854775808",
                                         "18446744073709551615", "18446744073709551616", "4194304", "4194305",
                                         "-1",        "+1",       "0x1",                  "1e3",
                                         "5x",        " ",        "",                     ",",
                                         "1,",        ",1",       "00",                   "0000000000000000000000000001"};
  char *value;
  switch (g_rand_int_range(rng, 0, 7)) {
  case 0:
    value = g_strdup(specials[g_rand_int_range(rng, 0, G_N_ELEMENTS(specials))]);
    break;
  case 1:
    value = g_strdup_printf("%.*s%" G_GSIZE_FORMAT, (int)g_rand_int_range(rng, 0, 4), "000", payload_len);
    break;
  case 2:
    value = g_strdup_printf("%" G_GSIZE_FORMAT, payload_len + (g_rand_boolean(rng) ? 1 : 0) - (g_rand_boolean(rng) ? 1 : 0));
    break;
  case 3: {
    GString *digits = g_string_new(NULL);
    guint n = (guint)g_rand_int_range(rng, 1, 26);
    for (guint i = 0; i < n; i++)
      g_string_append_c(digits, (char)('0' + g_rand_int_range(rng, 0, 10)));
    value = g_string_free(digits, FALSE);
    break;
  }
  case 4:
    value = g_strdup_printf("%" G_GSIZE_FORMAT ", %" G_GSIZE_FORMAT, payload_len,
                            payload_len + (g_rand_boolean(rng) ? 1 : 0));
    break;
  case 5:
    value = g_strdup_printf("\t %" G_GSIZE_FORMAT " \t", payload_len);
    break;
  default:
    value = g_strdup_printf("%" G_GSIZE_FORMAT, payload_len);
    break;
  }
  return value;
}

static void
test_net_content_length_random(void)
{
  static const char *const names[] = {"Content-Length", "content-length", "CONTENT-LENGTH", "Content-length"};
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  GRand *rng = g_rand_new_with_seed(20261012);
  guint parse_cases = 0, length_cases = 0, ok_cases = 0;
  for (guint iteration = 0; iteration < 400; iteration++) {
    gboolean gzip = g_rand_boolean(rng);
    gboolean complete = g_rand_int_range(rng, 0, 4) != 0;
    const guint8 *payload = gzip ? g_bytes_get_data(packed, NULL) : (const guint8 *)kBody;
    gsize len = gzip ? g_bytes_get_size(packed) : strlen(kBody);
    gsize sent = complete ? len : len / 2;
    guint n_lines = (guint)g_rand_int_range(rng, 1, 4);
    char *lines[3] = {NULL, NULL, NULL};
    GString *head = g_string_new(gzip ? "Content-Encoding: gzip\r\n" : "");
    for (guint l = 0; l < n_lines; l++) {
      lines[l] = g_rand_int_range(rng, 0, 3) == 0 && l > 0 ? g_strdup(lines[0]) : random_length_value(rng, len);
      g_string_append_printf(head, "%s: %s\r\n", names[g_rand_int_range(rng, 0, G_N_ELEMENTS(names))], lines[l]);
    }
    g_test_message("iteration %u gzip %d complete %d lines %u: %s", iteration, gzip, complete, n_lines, head->str);
    gint64 expected = oracle_length(lines, n_lines);
    g_autoptr(GBytes) response = framed_response(200, FR_CLOSE, head->str, payload, sent, 0, TRUE);
    if (expected == ORACLE_PARSE) {
      parse_cases++;
      run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    } else if (gzip ? (gsize)expected == len && complete : (gsize)expected <= sent) {
      ok_cases++;
      g_autofree char *want = gzip ? g_strdup(kGzipJson) : g_strndup(kBody, (gsize)expected);
      run_bytes_case(response, FALSE, OK_BODY, 1, want, 2000);
    } else {
      length_cases++; /* a valid length the body does not meet: a cut connection */
      run_bytes_case(response, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
    }
    g_string_free(head, TRUE);
    for (guint l = 0; l < n_lines; l++)
      g_free(lines[l]);
  }
  g_rand_free(rng);
  /* Non-vacuity: all three kinds of outcome were exercised. */
  g_assert_cmpuint(parse_cases, >, 40);
  g_assert_cmpuint(ok_cases, >, 40);
  g_assert_cmpuint(length_cases, >, 20);
}

/* A status that carries no content (or an error status) decides the outcome, whatever the
 * Content-Length lines say: a bodiless success stays a success, an error stays that error. */
static void
test_net_content_length_vs_status(void)
{
  static const char *const lengths[] = {"Content-Length: 9223372036854775808\r\n",
                                        "Content-Length: 18446744073709551614\r\n",
                                        "Content-Length: 18446744073709551615\r\n",
                                        "Content-Length: -2\r\n",
                                        "Content-Length: -16\r\n",
                                        "Content-Length: 99999999999999999999\r\n",
                                        "Content-Length: 99999999999999999999999\r\n",
                                        "Content-Length: -1\r\n",
                                        "Content-Length: 5x\r\n",
                                        "Content-Length: \r\n",
                                        "Content-Length: 7, 3\r\n",
                                        "Content-Length: 3\r\nContent-Length: 7\r\n",
                                        "Content-Length: 9223372036854775808\r\nContent-Length: -2\r\n"};
  static const char *const codings[] = {"", "Content-Encoding: gzip\r\n"};
  static const char *const ims = "Sun, 06 Nov 1994 08:49:37 GMT";
  const struct {
    guint status;
    const char *ims;
    int code;
    guint requests;
  } cases[] = {
      {200, NULL, WX_ERROR_PARSE, 1},
      {204, NULL, OK_BODY, 1},
      {205, NULL, OK_BODY, 1},
      {304, ims, OK_BODY, 1},
      {304, NULL, WX_ERROR_HTTP, 1},
      {302, NULL, WX_ERROR_HTTP, 1},
      {404, NULL, WX_ERROR_NOT_FOUND, 1},
      {429, NULL, WX_ERROR_RATE_LIMITED, 1},
      {500, NULL, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES},
  };
  for (guint c = 0; c < G_N_ELEMENTS(cases); c++)
    for (guint l = 0; l < G_N_ELEMENTS(lengths); l++)
      for (guint k = 0; k < G_N_ELEMENTS(codings); k++) {
        gboolean bodiless = cases[c].code == OK_BODY;
        g_autofree char *extra = g_strconcat(codings[k], lengths[l], NULL);
        g_autoptr(GBytes) response = framed_response(cases[c].status, FR_CLOSE, extra,
                                                     (const guint8 *)kBody, bodiless ? 0 : strlen(kBody), 0, TRUE);
        g_test_message("status %u length %u coding %u", cases[c].status, l, k);
        run_bytes_case_ims(response, cases[c].ims, cases[c].code, cases[c].requests, "", 2000);
      }
}

/* libsoup repeats a request once after a 421 by itself (observed, 3.6.6): one or two requests
 * reach the server and the second response head must be neutralised as well. */
static void
test_net_content_length_after_421(void)
{
  static const char *const lengths[] = {"Content-Length: 9223372036854775808\r\n",
                                        "Content-Length: -2\r\n",
                                        "Content-Length: 18446744073709551614\r\n",
                                        "Content-Length: 5x\r\n"};
  for (guint l = 0; l < G_N_ELEMENTS(lengths); l++) {
    g_autoptr(GBytes) response =
        framed_response(421, FR_CLOSE, lengths[l], (const guint8 *)kBody, strlen(kBody), 0, TRUE);
    gsize len;
    const char *data = g_bytes_get_data(response, &len);
    Step step = {STEP_BYTES, 0, data, NULL, len, 0};
    Fake *fake = fake_new(&step, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_null(o.response);
    g_assert_error(o.error, WX_ERROR, WX_ERROR_HTTP);
    g_assert_cmpuint(fake->requests, >=, 1);
    g_assert_cmpuint(fake->requests, <=, 2);
    outcome_clear(&o);
    fake_free(fake);
  }
}

/* Transfer-Encoding is read as ONE list (several lines are joined) and must be exactly "chunked"
 * (case-insensitive, blanks around it ignored) for a response that carries content: libsoup
 * frames by the LAST line only, so "gzip" + "chunked", "bogus" + "chunked", "chunked" +
 * "identity" and "identity" + "chunked" would otherwise come back as a success with a body that
 * is still transfer-coded or raw chunk framing. Everything else, identity and empty values
 * included, is PARSE "unsupported response framing", before the body is read. The status
 * decides first. The body served is always a valid chunked encoding of kBody. */
static void
test_net_transfer_encoding_lines(void)
{
  static const struct {
    const char *lines;
    gboolean ok;
  } rows[] = {
      {"Transfer-Encoding: chunked\r\n", TRUE},
      {"Transfer-Encoding: Chunked\r\n", TRUE},
      {"transfer-encoding: CHUNKED\r\n", TRUE},
      {"Transfer-Encoding:  chunked \t\r\n", TRUE},
      {"Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", FALSE},
      {"Transfer-Encoding: bogus\r\nTransfer-Encoding: chunked\r\n", FALSE},
      {"Transfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n", FALSE},
      {"Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", FALSE},
      {"Transfer-Encoding: identity\r\nTransfer-Encoding: chunked\r\n", FALSE},
      {"Transfer-Encoding: chunked\r\nTransfer-Encoding: \r\n", FALSE},
      {"Transfer-Encoding: \r\nTransfer-Encoding: chunked\r\n", FALSE},
      {"Transfer-Encoding: gzip, chunked\r\n", FALSE},
      {"Transfer-Encoding: chunked, chunked\r\n", FALSE},
      {"Transfer-Encoding: chunked, identity\r\n", FALSE},
      {"Transfer-Encoding: identity, chunked\r\n", FALSE},
      {"Transfer-Encoding: identity\r\n", FALSE},
      {"Transfer-Encoding: bogus\r\n", FALSE},
      {"Transfer-Encoding: gzip\r\n", FALSE},
      {"Transfer-Encoding:\r\n", FALSE},
      {"Transfer-Encoding: chunked\r\nContent-Length: 9223372036854775808\r\n", TRUE},
      {"Transfer-Encoding: gzip\r\nContent-Length: 9223372036854775808\r\n", FALSE},
  };
  g_autofree char *chunked = g_strdup_printf("%zx\r\n%s\r\n0\r\n\r\n", strlen(kBody), kBody);
  for (guint r = 0; r < G_N_ELEMENTS(rows); r++) {
    g_test_message("row %u: %s", r, rows[r].lines);
    g_autoptr(GBytes) response =
        framed_response(200, FR_CLOSE, rows[r].lines, (const guint8 *)chunked, strlen(chunked), 0, TRUE);
    if (rows[r].ok) {
      run_bytes_case(response, FALSE, OK_BODY, 1, kBody, 2000);
    } else {
      expect_error_text = "unsupported response framing";
      run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
      /* the status decides first */
      const struct {
        guint status;
        int code;
        guint requests;
      } others[] = {{204, OK_BODY, 1},
                    {205, OK_BODY, 1},
                    {404, WX_ERROR_NOT_FOUND, 1},
                    {429, WX_ERROR_RATE_LIMITED, 1},
                    {500, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES},
                    {302, WX_ERROR_HTTP, 1}};
      for (guint s = 0; s < G_N_ELEMENTS(others); s++) {
        g_autoptr(GBytes) other = framed_response(others[s].status, FR_CLOSE, rows[r].lines,
                                                  (const guint8 *)chunked, strlen(chunked), 0, TRUE);
        run_bytes_case(other, FALSE, others[s].code, others[s].requests, "", 2000);
      }
    }
  }
}

/* Randomized Transfer-Encoding lines against an independent oracle: whatever the lines are (one
 * to three, any name case, any of these values, with hostile Content-Length lines that must not
 * matter), the response is accepted exactly when there is ONE line and it is "chunked" (any case,
 * blanks and tabs around it ignored); the joined list of several lines (libsoup joins them with
 * ", ") can never be exactly "chunked". Every other form is PARSE "unsupported response framing",
 * in one request. The body served is a valid chunked encoding of kBody. */
static void
test_net_transfer_encoding_random(void)
{
  static const char *const names[] = {"Transfer-Encoding", "transfer-encoding", "TRANSFER-ENCODING"};
  static const char *const values[] = {"chunked",  "Chunked",   "CHUNKED", " chunked ", "\tchunked\t", "gzip",
                                       "identity", "",          "bogus",   "chunked, chunked", "gzip, chunked",
                                       "chunked,", ",chunked",  ",",       "chunked;x", "xchunked", "chunke",
                                       "chunkedd"};
  static const char *const lengths[] = {"", "Content-Length: 3\r\n", "Content-Length: 9223372036854775808\r\n",
                                        "Content-Length: -2\r\n", "Content-Length: \r\n"};
  g_autofree char *chunked = g_strdup_printf("%zx\r\n%s\r\n0\r\n\r\n", strlen(kBody), kBody);
  GRand *rng = g_rand_new_with_seed(20261013);
  guint accepted = 0, rejected = 0, multi_line = 0;
  for (guint iteration = 0; iteration < 300; iteration++) {
    guint n_lines = (guint)g_rand_int_range(rng, 1, 4);
    GString *head = g_string_new(NULL);
    const char *first = NULL;
    for (guint l = 0; l < n_lines; l++) {
      const char *value = values[g_rand_int_range(rng, 0, G_N_ELEMENTS(values))];
      if (l == 0)
        first = value;
      g_string_append_printf(head, "%s: %s\r\n", names[g_rand_int_range(rng, 0, G_N_ELEMENTS(names))], value);
    }
    g_string_append(head, lengths[g_rand_int_range(rng, 0, G_N_ELEMENTS(lengths))]);
    g_autofree char *trimmed = g_strstrip(g_strdup(first));
    gboolean ok = n_lines == 1 && g_ascii_strcasecmp(trimmed, "chunked") == 0;
    g_test_message("iteration %u lines %u ok %d: %s", iteration, n_lines, ok, head->str);
    g_autoptr(GBytes) response =
        framed_response(200, FR_CLOSE, head->str, (const guint8 *)chunked, strlen(chunked), 0, TRUE);
    if (ok) {
      accepted++;
      run_bytes_case(response, FALSE, OK_BODY, 1, kBody, 2000);
    } else {
      rejected++;
      multi_line += n_lines > 1;
      expect_error_text = "unsupported response framing";
      run_bytes_case(response, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
    }
    g_string_free(head, TRUE);
  }
  g_rand_free(rng);
  /* Non-vacuity: both verdicts and the multi-line forms were exercised. */
  g_assert_cmpuint(accepted, >, 20);
  g_assert_cmpuint(rejected, >, 100);
  g_assert_cmpuint(multi_line, >, 50);
}

/* The tests above and below rely on every critical and warning being fatal (a libsoup critical for
 * a hostile Content-Length would otherwise only be printed): g_test_init() makes them so. */
static void
test_net_criticals_are_fatal(void)
{
  GLogLevelFlags fatal = g_log_set_always_fatal(G_LOG_FATAL_MASK);
  g_log_set_always_fatal(fatal);
  g_assert_true(fatal & G_LOG_LEVEL_CRITICAL);
  g_assert_true(fatal & G_LOG_LEVEL_WARNING);
}

/* Informational (1xx) heads come first and are skipped by libsoup: their framing headers never
 * decide anything, and the verdict is the FINAL head's, whichever order the hostile values
 * come in. */
static void
test_net_informational_heads(void)
{
  static const char *const hostile[] = {"9223372036854775808", "-2", "18446744073709551614", "5x", "7, 3"};
  const char body[] = "{\"ok\":true}";
  for (guint h = 0; h < G_N_ELEMENTS(hostile); h++) {
    for (guint kind = 100; kind <= 102; kind += 2) {
      /* hostile values only in the interim head: the final response is fine */
      g_autofree char *good = g_strdup_printf(
          "HTTP/1.1 %u X\r\nContent-Length: %s\r\nTransfer-Encoding: gzip\r\n\r\n"
          "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n%s",
          kind, hostile[h], body);
      g_autoptr(GBytes) response1 = g_bytes_new(good, strlen(good));
      run_bytes_case(response1, FALSE, OK_BODY, 1, body, 2000);
      /* hostile values in the final head only: it is rejected whatever the interim head said */
      g_autofree char *bad = g_strdup_printf(
          "HTTP/1.1 %u X\r\nContent-Length: 11\r\n\r\n"
          "HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s",
          kind, hostile[h], body);
      g_autoptr(GBytes) response2 = g_bytes_new(bad, strlen(bad));
      run_bytes_case(response2, FALSE, WX_ERROR_PARSE, 1, NULL, 2000);
      /* an error status after the interim head keeps its own error */
      g_autofree char *error = g_strdup_printf(
          "HTTP/1.1 %u X\r\n\r\nHTTP/1.1 404 NF\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s", kind,
          hostile[h], body);
      g_autoptr(GBytes) response3 = g_bytes_new(error, strlen(error));
      run_bytes_case(response3, FALSE, WX_ERROR_NOT_FOUND, 1, NULL, 2000);
    }
  }
}

/* ---- Connection reuse after a rejected response ---- */

typedef struct {
  GSocket *listener;
  guint port;
  GMutex mutex;
  GPtrArray *script; /* GBytes: the response to the n-th request; the last one repeats */
  GArray *conn_of;   /* guint: id of the connection that carried the n-th request */
  guint connections;
  GPtrArray *threads;
  GCancellable *stop; /* wakes the acceptor, which a plain close would leave blocked */
} KaServer;

typedef struct {
  KaServer *server;
  GSocket *socket;
  guint id;
} KaConn;

static gpointer
ka_connection(gpointer data)
{
  KaConn *conn = data;
  KaServer *server = conn->server;
  GString *buffer = g_string_new(NULL);
  g_socket_set_timeout(conn->socket, 3);
  for (;;) {
    char *end;
    while ((end = strstr(buffer->str, "\r\n\r\n")) == NULL) {
      char chunk[2048];
      gssize n = g_socket_receive(conn->socket, chunk, sizeof chunk, NULL, NULL);
      if (n <= 0)
        goto done;
      g_string_append_len(buffer, chunk, n);
    }
    g_string_erase(buffer, 0, (gssize)(end - buffer->str) + 4);
    g_mutex_lock(&server->mutex);
    guint index = server->conn_of->len;
    g_array_append_val(server->conn_of, conn->id);
    GBytes *reply = g_bytes_ref(g_ptr_array_index(server->script, MIN(index, server->script->len - 1)));
    g_mutex_unlock(&server->mutex);
    gsize len, off = 0;
    const char *data_out = g_bytes_get_data(reply, &len);
    while (off < len) {
      gssize n = g_socket_send(conn->socket, data_out + off, len - off, NULL, NULL);
      if (n <= 0)
        break;
      off += (gsize)n;
    }
    g_bytes_unref(reply);
  }
done:
  g_socket_close(conn->socket, NULL);
  g_object_unref(conn->socket);
  g_string_free(buffer, TRUE);
  g_free(conn);
  return NULL;
}

static gpointer
ka_accept(gpointer data)
{
  KaServer *server = data;
  for (;;) {
    GSocket *socket = g_socket_accept(server->listener, server->stop, NULL);
    if (socket == NULL)
      return NULL;
    KaConn *conn = g_new0(KaConn, 1);
    conn->server = server;
    conn->socket = socket;
    g_mutex_lock(&server->mutex);
    conn->id = ++server->connections;
    g_ptr_array_add(server->threads, g_thread_new("ka-conn", ka_connection, conn));
    g_mutex_unlock(&server->mutex);
  }
}

/* A response that rejects itself (its framing is hostile, or its status is an error) leaves its
 * body unread: the connection it came on must be closed, never reused, or the next request would
 * read that body as the start of its own response. The server keeps every connection open; each
 * request records the connection that carried it. */
static void
test_net_connection_not_reused_after_rejection(void)
{
  const char body[] = "{\"ok\":true}";
  g_autofree char *chunked = g_strdup_printf("%zx\r\n%s\r\n0\r\n\r\n", strlen(body), body);
  const struct {
    const char *head; /* head lines after the status line, no Connection header: keep-alive */
    const char *payload;
    gboolean rejected;
  } script[] = {
      {"200 OK\r\nContent-Length: 9223372036854775808\r\n", body, TRUE},
      {"200 OK\r\nContent-Length: 11\r\n", body, FALSE},
      {"200 OK\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n", chunked, TRUE},
      {"200 OK\r\nContent-Length: 11\r\n", body, FALSE},
      {"500 Internal Server Error\r\nContent-Length: -2\r\n", body, TRUE},
      {"500 Internal Server Error\r\nContent-Length: -2\r\n", body, TRUE},
      {"500 Internal Server Error\r\nContent-Length: -2\r\n", body, TRUE},
      {"200 OK\r\nContent-Length: 11\r\n", body, FALSE},
      {"200 OK\r\nContent-Length: 5x\r\n", body, TRUE},
      {"200 OK\r\nContent-Length: 11\r\n", body, FALSE},
      {"200 OK\r\nContent-Length: 7, 3\r\n", body, TRUE},
      {"200 OK\r\nContent-Length: 11\r\n", body, FALSE},
  };
  KaServer server = {0};
  g_mutex_init(&server.mutex);
  server.script = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
  server.conn_of = g_array_new(FALSE, FALSE, sizeof(guint));
  server.threads = g_ptr_array_new();
  server.stop = g_cancellable_new();
  for (guint i = 0; i < G_N_ELEMENTS(script); i++) {
    g_autofree char *with_blank = g_strdup_printf("HTTP/1.1 %s\r\n%s", script[i].head, script[i].payload);
    g_ptr_array_add(server.script, g_bytes_new(with_blank, strlen(with_blank)));
  }
  g_autoptr(GError) error = NULL;
  server.listener = g_socket_new(G_SOCKET_FAMILY_IPV4, G_SOCKET_TYPE_STREAM, G_SOCKET_PROTOCOL_DEFAULT, &error);
  g_assert_no_error(error);
  g_autoptr(GInetAddress) loopback = g_inet_address_new_loopback(G_SOCKET_FAMILY_IPV4);
  g_autoptr(GSocketAddress) address = g_inet_socket_address_new(loopback, 0);
  g_assert_true(g_socket_bind(server.listener, address, TRUE, &error));
  g_assert_true(g_socket_listen(server.listener, &error));
  g_autoptr(GSocketAddress) bound = g_socket_get_local_address(server.listener, &error);
  server.port = g_inet_socket_address_get_port(G_INET_SOCKET_ADDRESS(bound));
  GThread *acceptor = g_thread_new("ka-accept", ka_accept, &server);

  g_autofree char *base = g_strdup_printf("http://127.0.0.1:%u", server.port);
  WxHttp *http = wx_http_new_custom(base, UA, 3000, 5, 0, &error);
  g_assert_no_error(error);
  guint sent = 0;
  while (sent < G_N_ELEMENTS(script)) {
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    if (script[sent].rejected) {
      g_assert_null(o.response);
      g_assert_nonnull(o.error);
      sent += g_error_matches(o.error, WX_ERROR, WX_ERROR_HTTP) ? 1 + WX_HTTP_MAX_RETRIES : 1;
    } else {
      g_assert_no_error(o.error);
      g_assert_cmpmem(g_bytes_get_data(o.response->body, NULL), g_bytes_get_size(o.response->body), body,
                      strlen(body));
      sent++;
    }
    outcome_clear(&o);
  }
  g_clear_object(&http);
  g_cancellable_cancel(server.stop);
  g_socket_close(server.listener, NULL);
  g_thread_join(acceptor);
  for (guint i = 0; i < server.threads->len; i++)
    g_thread_join(g_ptr_array_index(server.threads, i));
  g_assert_cmpuint(server.conn_of->len, ==, G_N_ELEMENTS(script));
  guint reuse_after_good = 0;
  for (guint i = 0; i + 1 < G_N_ELEMENTS(script); i++) {
    guint this_conn = g_array_index(server.conn_of, guint, i);
    guint next_conn = g_array_index(server.conn_of, guint, i + 1);
    if (script[i].rejected)
      g_assert_cmpuint(next_conn, !=, this_conn);
    else if (next_conn == this_conn)
      reuse_after_good++;
  }
  g_test_message("connections %u, reused after a good response %u times", server.connections, reuse_after_good);
  g_object_unref(server.listener);
  g_ptr_array_free(server.threads, TRUE);
  g_ptr_array_free(server.script, TRUE);
  g_array_free(server.conn_of, TRUE);
  g_object_unref(server.stop);
  g_mutex_clear(&server.mutex);
}

/* libsoup reads a chunk-size line with strtoul(): text that is not hexadecimal is size 0, the last
 * chunk. A mangled FIRST line would make the whole body vanish, so an empty chunked body is a
 * failed transfer (NETWORK). A mangled line after the first chunk ends the body there: that is
 * libsoup's behaviour (documented in wx-http.h) and cannot be seen from here, so the test only
 * pins what may come back: an error, or exactly the chunk data that precedes the damage, never
 * anything else. */
static void
test_net_chunk_size_garbage(void)
{
  const char head[] = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
  /* No BLANK or whitespace-only size line: libsoup 3.6 then runs strtoul() over a line buffer it
   * never terminated (valgrind: "use of uninitialised value" inside libsoup), so its outcome is
   * not even deterministic. A hostile server can send one; the result stays whatever libsoup
   * makes of it. */
  static const char *const bad_sizes[] = {"zz", "-1", "x", ";", "g3", "\x01"};
  for (guint i = 0; i < G_N_ELEMENTS(bad_sizes); i++) {
    /* first chunk-size line damaged: nothing usable arrived */
    g_autofree char *first = g_strdup_printf("%s%s\r\nabc\r\n0\r\n\r\n", head, bad_sizes[i]);
    g_autoptr(GBytes) response = g_bytes_new(first, strlen(first));
    run_bytes_case(response, FALSE, WX_ERROR_NETWORK, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
    /* a later line damaged: an error, or just the first chunk */
    g_autofree char *later = g_strdup_printf("%s3\r\nabc\r\n%s\r\ndef\r\n0\r\n\r\n", head, bad_sizes[i]);
    g_autoptr(GBytes) response2 = g_bytes_new(later, strlen(later));
    gsize len;
    const char *data = g_bytes_get_data(response2, &len);
    Step step = {STEP_BYTES, 0, data, NULL, len, 0};
    Fake *fake = fake_new(&step, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    if (o.response != NULL) {
      gsize got_len;
      const char *got = g_bytes_get_data(o.response->body, &got_len);
      g_assert_cmpmem(got, got_len, "abc", 3);
    } else {
      g_assert_nonnull(o.error);
      g_assert_true(g_error_matches(o.error, WX_ERROR, WX_ERROR_NETWORK) ||
                    g_error_matches(o.error, WX_ERROR, WX_ERROR_PARSE));
    }
    outcome_clear(&o);
    fake_free(fake);
  }
}

/* Headers that are not read must not influence anything: whatever hostile Location, Retry-After,
 * Content-Type, Content-Range, cookies, credentials requests, alternative services or lookalikes
 * of the framing headers a 200 carries, the result is the body, after one request; a Retry-After
 * on a retried 503 does not stretch the back-off; an authentication challenge is a final
 * WX_ERROR_HTTP (nothing answers it). */
static void
test_net_unread_headers_are_ignored(void)
{
  static const char *const hostile[] = {"Location: http://evil.example/\r\n",
                                        "Content-Location: http://evil.example/x\r\n",
                                        "Retry-After: 3600\r\n",
                                        "Content-Type: text/html; charset=utf-7\r\n",
                                        "Content-Range: bytes 0-1/99999\r\n",
                                        "Set-Cookie: a=b; Domain=.example\r\n",
                                        "Alt-Svc: h3=\":443\"; ma=86400\r\n",
                                        "Trailer: Content-Length\r\n",
                                        "Link: <http://evil.example/>; rel=preload\r\n",
                                        "Refresh: 0; url=http://evil.example/\r\n",
                                        "Content-Disposition: attachment; filename=\"x\"\r\n",
                                        "X-Content-Length: 5\r\n",
                                        "Content-Length-X: 5\r\n",
                                        "X-Transfer-Encoding: chunked\r\n",
                                        "X-Content-Encoding: gzip\r\n",
                                        "Keep-Alive: timeout=0, max=0\r\n",
                                        "Strict-Transport-Security: max-age=0\r\n"};
  for (guint i = 0; i < G_N_ELEMENTS(hostile); i++) {
    g_autoptr(GBytes) response =
        framed_response(200, FR_CL, hostile[i], (const guint8 *)kBody, strlen(kBody), strlen(kBody), TRUE);
    g_test_message("header %s", hostile[i]);
    run_bytes_case(response, FALSE, OK_BODY, 1, kBody, 2000);
  }
  gint64 start = g_get_monotonic_time();
  g_autoptr(GBytes) overloaded =
      framed_response(503, FR_CL, "Retry-After: 3600\r\n", (const guint8 *)kBody, strlen(kBody), strlen(kBody), TRUE);
  run_bytes_case(overloaded, FALSE, WX_ERROR_HTTP, 1 + WX_HTTP_MAX_RETRIES, NULL, 2000);
  g_assert_cmpint(g_get_monotonic_time() - start, <, 20 * G_USEC_PER_SEC);
  g_autoptr(GBytes) limited =
      framed_response(429, FR_CL, "Retry-After: 3600\r\n", (const guint8 *)kBody, strlen(kBody), strlen(kBody), TRUE);
  run_bytes_case(limited, FALSE, WX_ERROR_RATE_LIMITED, 1, NULL, 2000);
  g_autoptr(GBytes) challenge =
      framed_response(401, FR_CL, "WWW-Authenticate: Basic realm=\"x\"\r\n", (const guint8 *)kBody, strlen(kBody),
                      strlen(kBody), TRUE);
  run_bytes_case(challenge, FALSE, WX_ERROR_HTTP, 1, NULL, 2000);
  g_autoptr(GBytes) proxy_challenge =
      framed_response(407, FR_CL, "Proxy-Authenticate: Basic realm=\"x\"\r\n", (const guint8 *)kBody, strlen(kBody),
                      strlen(kBody), TRUE);
  run_bytes_case(proxy_challenge, FALSE, WX_ERROR_HTTP, 1, NULL, 2000);
}

/* libsoup takes the end of the stream inside a header block as the end of the head (a cut head
 * would otherwise be an error). A 2xx response cut anywhere in its status line or headers, or
 * right after them, must therefore never be a success: whatever framing and coding it announces
 * (a missing blank line, a Content-Length cut short, a Transfer-Encoding or Content-Encoding cut
 * mid-word) it is WX_ERROR_NETWORK (nothing complete arrived) or WX_ERROR_PARSE (what arrived
 * names no framing or coding that can be followed). */
static void
test_net_truncated_head(void)
{
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  for (guint f = 0; f < 3; f++)
    for (guint g = 0; g < 2; g++) {
      const Framing framing = f == 0 ? FR_CL : f == 1 ? FR_CHUNKED : FR_CLOSE;
      const gboolean gzip = g == 1;
      const guint8 *payload = gzip ? g_bytes_get_data(packed, NULL) : (const guint8 *)kBody;
      gsize len = gzip ? g_bytes_get_size(packed) : strlen(kBody);
      g_autoptr(GBytes) response = framed_response(200, framing, gzip ? "Content-Encoding: gzip\r\n" : "",
                                                   payload, len, len, TRUE);
      gsize total;
      const char *data = g_bytes_get_data(response, &total);
      const char *blank = g_strstr_len(data, (gssize)total, "\r\n\r\n");
      g_assert_nonnull(blank);
      gsize head_len = (gsize)(blank - data) + 4;
      for (gsize k = 1; k <= head_len; k++) {
        if (!cut_position_wanted(k, head_len))
          continue;
        Step step = {STEP_BYTES, 0, data, NULL, k, 0};
        Fake *fake = fake_new(&step, 1);
        g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
        Outcome o = {0};
        gint64 start;
        get(http, "/x", NULL, NULL, &o, &start);
        wait_for(&o, start);
        if (o.response != NULL || o.error == NULL ||
            !(g_error_matches(o.error, WX_ERROR, WX_ERROR_NETWORK) ||
              g_error_matches(o.error, WX_ERROR, WX_ERROR_PARSE)))
          g_printerr("cut head: framing %d gzip %d after %zu of %zu head bytes: %s\n", framing, gzip, k, head_len,
                     o.error != NULL ? o.error->message : "SUCCESS");
        g_assert_null(o.response);
        g_assert_nonnull(o.error);
        g_assert_true(g_error_matches(o.error, WX_ERROR, WX_ERROR_NETWORK) ||
                      g_error_matches(o.error, WX_ERROR, WX_ERROR_PARSE));
        outcome_clear(&o);
        fake_free(fake);
      }
    }
}

/* ----------------------------------------------------------------------------------------------
 * The status x framing x Content-Encoding x payload table (documented in wx-http.h, "Result
 * table"): every combination is served by the fake and compared with an oracle written from the
 * documented rules, not from the implementation.
 * -------------------------------------------------------------------------------------------- */

typedef enum { CE_NONE, CE_GZIP, CE_IDENTITY, CE_BR, CE_BAD_LIST } Coding;
typedef enum { PL_COMPLETE, PL_TRUNCATED, PL_TRAILING, PL_EMPTY } PayloadKind;
/* How the Content-Length is falsified. DL_HONEST: the framing's own (or none); the others replace
 * it by lines of a response that is otherwise close-delimited. */
typedef enum {
  DL_HONEST,
  DL_HUGE,
  DL_OVERFLOW,
  DL_NEGATIVE,
  DL_EMPTY,
  DL_GARBAGE,
  DL_CONFLICT,
  DL_TE_GZIP,     /* "Transfer-Encoding: gzip" before the chunked framing's own line */
  DL_TE_BOGUS,    /* "Transfer-Encoding: bogus" before it */
  DL_TE_IDENTITY, /* "Transfer-Encoding: identity" before it */
  DL_TE_CHUNKED   /* "Transfer-Encoding: chunked" twice */
} Declared;

typedef struct {
  guint status;
  gboolean ims; /* the request carries If-Modified-Since */
  Framing framing;
  Coding coding;
  PayloadKind payload;
  Declared decl;
} Row;

static const char *
coding_header(Coding coding)
{
  switch (coding) {
  case CE_GZIP:
    return "Content-Encoding: gzip\r\n";
  case CE_IDENTITY:
    return "Content-Encoding: identity\r\n";
  case CE_BR:
    return "Content-Encoding: br\r\n";
  case CE_BAD_LIST:
    return "Content-Encoding: gzip, gzip\r\n";
  case CE_NONE:
  default:
    return "";
  }
}

static const char kTrail[] = "TRAIL";

static gboolean
row_is_no_content(const Row *row)
{
  return row->status == 204 || row->status == 205 || (row->status == 304 && row->ims);
}

/* The documented outcome of @row. *@code is OK_BODY or a WxError; *@body is the expected body of a
 * success (*@body_storage owns it when it is built). */
static void
table_oracle(const Row *row, int *code, guint *requests, const char **body, char **body_storage)
{
  *requests = 1;
  *body = "";
  *body_storage = NULL;
  *code = OK_BODY;
  gboolean gzip = row->coding == CE_GZIP;
  /* 1. Statuses that are errors, whatever the headers and the body say. */
  if (!row_is_no_content(row) && (row->status < 200 || row->status >= 300)) {
    *code = row->status == 404   ? WX_ERROR_NOT_FOUND
            : row->status == 429 ? WX_ERROR_RATE_LIMITED
                                 : WX_ERROR_HTTP;
    if (row->status >= 500 && row->status <= 599)
      *requests = 1 + WX_HTTP_MAX_RETRIES;
    return;
  }
  /* 2. No content: success, empty body, Content-Encoding not looked at. */
  if (row_is_no_content(row))
    return;
  /* 3. 2xx with content: a Content-Length that is not one valid number within the cap. */
  if (row->decl != DL_HONEST) {
    *code = WX_ERROR_PARSE;
    return;
  }
  /* 4. Then Content-Encoding. */
  if (row->coding == CE_BR || row->coding == CE_BAD_LIST) {
    *code = WX_ERROR_PARSE;
    return;
  }
  switch (row->payload) {
  case PL_COMPLETE:
    *body = gzip ? kGzipJson : kBody;
    return;
  case PL_EMPTY:
    /* a gzip body needs its member; an empty body of unknown length (close-delimited, chunked)
     * is not accepted as complete: it may be a head cut short or a mangled chunk size */
    if (gzip || row->framing != FR_CL) {
      *code = WX_ERROR_NETWORK;
      *requests = 1 + WX_HTTP_MAX_RETRIES;
    }
    return;
  case PL_TRUNCATED:
    if (gzip || row->framing != FR_CLOSE) { /* the cut is detected (close-delimited plain: not) */
      *code = WX_ERROR_NETWORK;
      *requests = 1 + WX_HTTP_MAX_RETRIES;
    } else {
      *body_storage = g_strndup(kBody, strlen(kBody) / 2);
      *body = *body_storage;
    }
    return;
  case PL_TRAILING:
    if (gzip) {
      *code = WX_ERROR_PARSE;
    } else {
      *body_storage = g_strconcat(kBody, kTrail, NULL);
      *body = *body_storage;
    }
    return;
  }
}

static char *
decl_header(Declared decl, gsize declared)
{
  switch (decl) {
  case DL_HUGE:
    return g_strdup("Content-Length: 9223372036854775808\r\n");
  case DL_OVERFLOW:
    return g_strdup("Content-Length: 99999999999999999999999\r\n");
  case DL_NEGATIVE:
    return g_strdup("Content-Length: -1\r\n");
  case DL_EMPTY:
    return g_strdup("Content-Length: \r\n");
  case DL_GARBAGE:
    return g_strdup("Content-Length: 5x\r\n");
  case DL_CONFLICT:
    return g_strdup_printf("Content-Length: %" G_GSIZE_FORMAT "\r\nContent-Length: %" G_GSIZE_FORMAT "\r\n",
                           declared, declared + 1);
  case DL_TE_GZIP:
    return g_strdup("Transfer-Encoding: gzip\r\n");
  case DL_TE_BOGUS:
    return g_strdup("Transfer-Encoding: bogus\r\n");
  case DL_TE_IDENTITY:
    return g_strdup("Transfer-Encoding: identity\r\n");
  case DL_TE_CHUNKED:
    return g_strdup("Transfer-Encoding: chunked\r\n");
  case DL_HONEST:
  default:
    return g_strdup("");
  }
}

/* Describes @row on stderr when @ok is false, then fails the assertion. */
#define ROW_CHECK(ok, row, what)                                                                 \
  G_STMT_START {                                                                                 \
    if (!(ok))                                                                                   \
      g_printerr("table row: status %u ims %d framing %d coding %d payload %d decl %d: %s\n",    \
                 (row)->status, (row)->ims, (row)->framing, (row)->coding, (row)->payload,       \
                 (row)->decl, what);                                                             \
    g_assert_true(ok);                                                                           \
  }                                                                                              \
  G_STMT_END

static void
table_run(const Row *row, const guint8 *z, gsize n)
{
  int code;
  guint requests;
  const char *body;
  g_autofree char *body_storage = NULL;
  table_oracle(row, &code, &requests, &body, &body_storage);

  /* The wire: gzip bytes for a gzip row, plain text otherwise, shaped by the payload kind. */
  g_autofree guint8 *data = NULL;
  gsize len;
  if (row->coding == CE_GZIP) {
    len = n;
    data = g_malloc(n + sizeof kTrail);
    memcpy(data, z, n);
  } else {
    len = strlen(kBody);
    data = g_malloc(len + sizeof kTrail);
    memcpy(data, kBody, len);
  }
  memcpy(data + len, kTrail, sizeof kTrail - 1);
  gsize send_len = len, declared = len;
  gboolean terminate = TRUE;
  switch (row->payload) {
  case PL_COMPLETE:
    break;
  case PL_TRUNCATED:
    send_len = len / 2;
    terminate = FALSE;
    break;
  case PL_TRAILING:
    send_len = declared = len + sizeof kTrail - 1;
    break;
  case PL_EMPTY:
    send_len = declared = 0;
    break;
  }
  if (row_is_no_content(row)) {
    send_len = declared = 0; /* nothing on the wire after the head */
  } else if (row->status < 200 || row->status >= 300) {
    memcpy(data, kBody, strlen(kBody)); /* error statuses carry a plain text body */
    send_len = declared = strlen(kBody);
  }
  g_autofree char *decl_lines = decl_header(row->decl, declared);
  g_autofree char *extra = g_strconcat(coding_header(row->coding), decl_lines, NULL);
  g_autoptr(GBytes) response =
      framed_response(row->status, row->framing, extra, data, send_len, declared, terminate);
  gsize response_len;
  const char *response_data = g_bytes_get_data(response, &response_len);
  Step step = {STEP_BYTES, 0, response_data, NULL, response_len, 0};
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 2, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", row->ims ? "Sun, 06 Nov 1994 08:49:37 GMT" : NULL, NULL, &o, &start);
  wait_for(&o, start);
  if (code == OK_BODY) {
    ROW_CHECK(o.error == NULL && o.response != NULL, row, o.error != NULL ? o.error->message : "no response");
    ROW_CHECK(o.response->status == row->status, row, "wrong status");
    gsize got_len;
    const char *got = g_bytes_get_data(o.response->body, &got_len);
    ROW_CHECK(got_len == strlen(body) && (got_len == 0 || memcmp(got, body, got_len) == 0), row, "wrong body");
  } else {
    ROW_CHECK(o.response == NULL && o.error != NULL && g_error_matches(o.error, WX_ERROR, code), row,
              o.error != NULL ? o.error->message : "unexpected success");
  }
  ROW_CHECK(fake->requests == requests, row, "wrong number of requests");
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_status_framing_table(void)
{
  g_autoptr(GBytes) packed = gzip_of(kGzipJson, strlen(kGzipJson));
  const guint8 *z = g_bytes_get_data(packed, NULL);
  gsize n = g_bytes_get_size(packed);
  const Coding codings[] = {CE_NONE, CE_GZIP, CE_IDENTITY, CE_BR, CE_BAD_LIST};
  const Framing all_framings[] = {FR_CL, FR_CHUNKED, FR_CLOSE};
  const Framing length_or_close[] = {FR_CL, FR_CLOSE};
  const PayloadKind payloads[] = {PL_COMPLETE, PL_TRUNCATED, PL_TRAILING, PL_EMPTY};
  guint rows_run = 0;

  /* Statuses with content: every framing x coding x payload. */
  const guint content_statuses[] = {200, 206};
  for (guint s = 0; s < G_N_ELEMENTS(content_statuses); s++)
    for (guint f = 0; f < G_N_ELEMENTS(all_framings); f++)
      for (guint c = 0; c < G_N_ELEMENTS(codings); c++)
        for (guint p = 0; p < G_N_ELEMENTS(payloads); p++) {
          Row row = {content_statuses[s], FALSE, all_framings[f], codings[c], payloads[p], DL_HONEST};
          table_run(&row, z, n);
          rows_run++;
        }
  /* Statuses without content, and error statuses: length-delimited or close-delimited. */
  const struct {
    guint status;
    gboolean ims;
  } other[] = {{204, FALSE}, {205, FALSE}, {304, TRUE}, {304, FALSE}, {301, FALSE}, {302, TRUE},
               {400, FALSE}, {404, FALSE}, {429, FALSE}, {500, FALSE}, {503, FALSE}, {599, FALSE}};
  for (guint s = 0; s < G_N_ELEMENTS(other); s++)
    for (guint f = 0; f < G_N_ELEMENTS(length_or_close); f++)
      for (guint c = 0; c < G_N_ELEMENTS(codings); c++) {
        Row row = {other[s].status, other[s].ims, length_or_close[f], codings[c], PL_COMPLETE, DL_HONEST};
        table_run(&row, z, n);
        rows_run++;
      }
  /* A falsified Content-Length (close-delimited otherwise): every status class x coding x payload
   * x kind of falsification. The status decides first, then the framing, then Content-Encoding.
   * Every critical or warning is fatal here, in every domain (g_test_init()). */
  const guint falsify_statuses[] = {200, 206, 204, 205, 304, 404, 500, 302};
  const Coding falsify_codings[] = {CE_NONE, CE_GZIP, CE_BR};
  const Declared kinds[] = {DL_HUGE,     DL_OVERFLOW, DL_NEGATIVE,    DL_EMPTY,       DL_GARBAGE,
                            DL_CONFLICT, DL_TE_GZIP,  DL_TE_BOGUS,    DL_TE_IDENTITY, DL_TE_CHUNKED};
  for (guint s = 0; s < G_N_ELEMENTS(falsify_statuses); s++)
    for (guint ims = 0; ims < (falsify_statuses[s] == 304 ? 2u : 1u); ims++)
      for (guint c = 0; c < G_N_ELEMENTS(falsify_codings); c++)
        for (guint p = 0; p < 2; p++)
          for (guint k = 0; k < G_N_ELEMENTS(kinds); k++) {
            Row row = {falsify_statuses[s], ims != 0, kinds[k] >= DL_TE_GZIP ? FR_CHUNKED : FR_CLOSE,
                       falsify_codings[c], p == 0 ? PL_COMPLETE : PL_TRUNCATED, kinds[k]};
            table_run(&row, z, n);
            rows_run++;
          }
  g_assert_cmpuint(rows_run, ==, 2 * 3 * 5 * 4 + 12 * 2 * 5 + 9 * 3 * 2 * 10);
}

/* The per-attempt deadline covers the body too: the head arrives, the body stalls (the server
 * sends part of it and then says nothing more). */
static void
test_net_timeout_covers_body(void)
{
  const char partial[] = "{\"a\":";
  g_autoptr(GBytes) response = response_with("", (const guint8 *)partial, strlen(partial), 100);
  run_bytes_case(response, TRUE, WX_ERROR_TIMEOUT, 1 + WX_HTTP_MAX_RETRIES, NULL, 200);
}

static void
test_net_cancel_during_request(void)
{
  Step script[] = {{STEP_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 10000, 5, 0);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, cancellable, &o, &start);
  g_timeout_add(100, cancel_later, cancellable);
  gint64 elapsed_ms = wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->requests, ==, 1);
  g_assert_cmpint(elapsed_ms, <, 2000);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_cancel_during_backoff(void)
{
  Step script[] = {{STEP_RESPOND, 503, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 30000, 0); /* would wait 30 s */
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, cancellable, &o, &start);
  g_timeout_add(300, cancel_later, cancellable);
  gint64 elapsed_ms = wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->requests, ==, 1);
  g_assert_cmpint(elapsed_ms, <, 3000);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_pre_cancelled(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  g_cancellable_cancel(cancellable);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, cancellable, &o, &start);
  wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->requests, ==, 0);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_cancel_before_finish(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  Outcome o = {0};
  o.cancel_in_callback = cancellable;
  wx_http_get_async(http, "/x", JSON_ACCEPT, NULL, cancellable, on_done_cancel_first, &o);
  while (!o.done)
    g_main_context_iteration(NULL, TRUE);
  /* The request had succeeded; cancelling before the finish call wins. */
  g_assert_null(o.response);
  g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->requests, ==, 1);
  outcome_clear(&o);
  fake_free(fake);
}

typedef struct {
  GCancellable *cancellable;
  guint delay_ms;
} ThreadCancel;

static gpointer
cancel_from_thread(gpointer data)
{
  ThreadCancel *tc = data;
  g_usleep((gulong)tc->delay_ms * 1000);
  g_cancellable_cancel(tc->cancellable);
  return NULL;
}

static void
test_net_cancel_from_other_thread(void)
{
  Step script[] = {{STEP_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 10000, 5, 0);
  for (guint round = 0; round < 3; round++) {
    g_autoptr(GCancellable) cancellable = g_cancellable_new();
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, cancellable, &o, &start);
    ThreadCancel tc = {cancellable, round == 0 ? 0 : 50 * round};
    GThread *thread = g_thread_new("wx-test-cancel", cancel_from_thread, &tc);
    gint64 elapsed_ms = wait_for(&o, start);
    g_thread_join(thread);
    g_assert_error(o.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_assert_cmpint(elapsed_ms, <, 3000);
    outcome_clear(&o);
  }
  fake_free(fake);
}

static void
on_weak_notify(gpointer data, GObject *where_the_object_was)
{
  (void)where_the_object_was;
  *(gboolean *)data = TRUE;
}

/* Drops the caller's reference and reports whether the object was finalized within @ms. */
static gboolean
released_within(gpointer object, guint ms)
{
  gboolean finalized = FALSE;
  g_object_weak_ref(G_OBJECT(object), on_weak_notify, &finalized);
  g_object_unref(object);
  gint64 deadline = g_get_monotonic_time() + (gint64)ms * 1000;
  while (!finalized && g_get_monotonic_time() < deadline)
    g_main_context_iteration(NULL, FALSE);
  return finalized;
}

static void
test_net_http_dropped_while_in_flight(void)
{
  /* The operation keeps the WxHttp alive until it completes. */
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 20}};
  Fake *fake = fake_new(script, 1);
  WxHttp *http = http_for(fake, 2000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  gboolean finalized = FALSE;
  g_object_weak_ref(G_OBJECT(http), on_weak_notify, &finalized);
  g_object_unref(http);
  g_assert_false(finalized); /* still referenced by the operation */
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.response);
  outcome_clear(&o);
  spin(50);
  g_assert_true(finalized); /* released once the operation and its callback are done */
  fake_free(fake);

  /* Dropped while in back-off, and while queued behind the pacing gap. */
  Step flaky[] = {{STEP_RESPOND, 503, kBody, NULL, 0, 0}, {STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake2 = fake_new(flaky, 2);
  WxHttp *backoff_http = http_for(fake2, 2000, 150, 0);
  get(backoff_http, "/x", NULL, NULL, &o, &start);
  spin(60); /* the first attempt failed, the back-off is pending */
  g_assert_cmpuint(fake2->requests, ==, 1);
  finalized = FALSE;
  g_object_weak_ref(G_OBJECT(backoff_http), on_weak_notify, &finalized);
  g_object_unref(backoff_http);
  g_assert_false(finalized);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_cmpuint(fake2->requests, ==, 2);
  outcome_clear(&o);
  spin(50);
  g_assert_true(finalized);
  fake_free(fake2);

  Step slow[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake3 = fake_new(slow, 1);
  WxHttp *paced = http_for(fake3, 2000, 5, 200);
  Outcome two[2] = {{0}};
  gint64 starts[2];
  get(paced, "/a", NULL, NULL, &two[0], &starts[0]);
  get(paced, "/b", NULL, NULL, &two[1], &starts[1]);
  finalized = FALSE;
  g_object_weak_ref(G_OBJECT(paced), on_weak_notify, &finalized);
  g_object_unref(paced);
  wait_all(two, 2);
  g_assert_no_error(two[0].error);
  g_assert_no_error(two[1].error);
  spin(50);
  g_assert_true(finalized);
  outcome_clear(&two[0]);
  outcome_clear(&two[1]);
  fake_free(fake3);
}

/* A completion callback that drops the last reference and starts a new request. */
typedef struct {
  Outcome first;
  Outcome second;
  WxHttp *http;
  gint64 start;
} Chain;

static void
on_chain_second(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Chain *chain = user_data;
  on_done(source, result, &chain->second);
}

static void
on_chain_first(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Chain *chain = user_data;
  on_done(source, result, &chain->first);
  /* Re-enter from inside a completion callback, then drop our reference. */
  wx_http_get_async(chain->http, "/second", JSON_ACCEPT, NULL, NULL, on_chain_second, chain);
  g_assert_false(chain->second.done);
  g_object_unref(chain->http);
  chain->http = NULL;
}

static void
test_net_reentrant_callback(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  Chain chain = {{0}, {0}, http_for(fake, 2000, 5, 0), 0};
  wx_http_get_async(chain.http, "/first", JSON_ACCEPT, NULL, NULL, on_chain_first, &chain);
  while (!chain.second.done)
    g_main_context_iteration(NULL, TRUE);
  g_assert_no_error(chain.first.error);
  g_assert_no_error(chain.second.error);
  g_assert_cmpuint(fake->requests, ==, 2);
  g_assert_cmpstr(fake_path(fake, 0), ==, "/first");
  g_assert_cmpstr(fake_path(fake, 1), ==, "/second");
  outcome_clear(&chain.first);
  outcome_clear(&chain.second);
  fake_free(fake);
}

static void
test_net_inflight_cap(void)
{
  Step hang[] = {{STEP_HANG, 0, NULL, NULL, 0, 0}};
  Fake *fake = fake_new(hang, 1);
  WxHttp *http = http_for(fake, 10000, 5, 0);
  GCancellable *cancels[WX_HTTP_MAX_INFLIGHT];
  Outcome outs[WX_HTTP_MAX_INFLIGHT] = {{0}};
  gint64 start;

  /* Fill the cap minus one with hanging requests. */
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT - 1; i++) {
    cancels[i] = g_cancellable_new();
    get(http, "/x", NULL, cancels[i], &outs[i], &start);
  }
  /* Invalid arguments are still reported as such (validation first). */
  Outcome refused = {0};
  wx_http_get_async(http, "//bad", JSON_ACCEPT, NULL, NULL, on_done, &refused);
  wait_for(&refused, g_get_monotonic_time());
  g_assert_error(refused.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&refused);

  /* One slot is left: accepted ... */
  cancels[WX_HTTP_MAX_INFLIGHT - 1] = g_cancellable_new();
  get(http, "/x", NULL, cancels[WX_HTTP_MAX_INFLIGHT - 1], &outs[WX_HTTP_MAX_INFLIGHT - 1], &start);
  /* ... and the next one is refused at once, with no network traffic. */
  guint sent_before = fake->requests;
  get(http, "/x", NULL, NULL, &refused, &start);
  gint64 elapsed_ms = wait_for(&refused, start);
  g_assert_null(refused.response);
  g_assert_error(refused.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  g_assert_cmpint(elapsed_ms, <, 1000);
  outcome_clear(&refused);
  g_assert_cmpuint(fake->requests, ==, sent_before);
  g_assert_cmpuint(fake->requests, <=, WX_HTTP_MAX_INFLIGHT);

  /* Completed operations release their slots. */
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++)
    g_cancellable_cancel(cancels[i]);
  wait_all(outs, WX_HTTP_MAX_INFLIGHT);
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    g_assert_error(outs[i].error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    outcome_clear(&outs[i]);
    g_object_unref(cancels[i]);
  }
  g_autoptr(GCancellable) again = g_cancellable_new();
  Outcome accepted = {0};
  get(http, "/x", NULL, again, &accepted, &start);
  g_cancellable_cancel(again);
  wait_for(&accepted, start);
  g_assert_error(accepted.error, G_IO_ERROR, G_IO_ERROR_CANCELLED); /* not RATE_LIMITED */
  outcome_clear(&accepted);
  g_assert_true(released_within(http, 2000));
  fake_free(fake);
}

/* Keeps every GAsyncResult it is given, without finishing it. */
typedef struct {
  GAsyncResult *kept[WX_HTTP_MAX_INFLIGHT];
  guint n;
} Keeper;

static void
on_keep_result(GObject *source, GAsyncResult *result, gpointer user_data)
{
  (void)source;
  Keeper *keeper = user_data;
  g_assert_cmpuint(keeper->n, <, WX_HTTP_MAX_INFLIGHT);
  keeper->kept[keeper->n++] = g_object_ref(result);
}

/* An operation occupies its admission slot until its GAsyncResult is released, not merely until
 * its callback has returned (wx-http.h, Admission). */
static void
test_net_inflight_slot_held_by_result(void)
{
  Step script[] = {{STEP_RESPOND, 200, "{}", NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 5, 0);
  Keeper keeper = {{NULL}, 0};
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++)
    wx_http_get_async(http, "/x", JSON_ACCEPT, NULL, NULL, on_keep_result, &keeper);
  while (keeper.n < WX_HTTP_MAX_INFLIGHT)
    g_main_context_iteration(NULL, TRUE);
  spin(50); /* every callback has returned; every result is kept */
  g_assert_cmpuint(fake->requests, ==, WX_HTTP_MAX_INFLIGHT);

  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  g_assert_cmpuint(fake->requests, ==, WX_HTTP_MAX_INFLIGHT); /* refused without traffic */
  outcome_clear(&o);

  /* Finishing the kept results does not release the slots either. */
  for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
    g_autoptr(GError) error = NULL;
    WxHttpResponse *response = wx_http_get_finish(http, keeper.kept[i], &error);
    g_assert_no_error(error);
    g_assert_cmpuint(response->status, ==, 200);
    wx_http_response_free(response);
  }
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_RATE_LIMITED);
  outcome_clear(&o);

  /* Releasing one result frees exactly one slot. */
  g_object_unref(keeper.kept[0]);
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  outcome_clear(&o);
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error); /* the operation just completed released its own slot again */
  outcome_clear(&o);
  for (guint i = 1; i < WX_HTTP_MAX_INFLIGHT; i++)
    g_object_unref(keeper.kept[i]);
  fake_free(fake);
}

/* GObject allows method calls until finalize: after g_object_run_dispose() the instance still
 * serves requests and still completes every operation exactly once. */
static void
test_net_http_after_dispose(void)
{
  Step script[] = {{STEP_RESPOND, 200, "{}", NULL, 0, 30}};
  Fake *fake = fake_new(script, 1);
  WxHttp *http = http_for(fake, 5000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/before", NULL, NULL, &o, &start); /* in flight while it is disposed */
  g_object_run_dispose(G_OBJECT(http));
  wait_for(&o, start);
  g_assert_no_error(o.error);
  outcome_clear(&o);

  g_object_run_dispose(G_OBJECT(http)); /* a second dispose is harmless */
  get(http, "/after", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_cmpuint(o.response->status, ==, 200);
  outcome_clear(&o);
  g_assert_cmpstr(fake_path(fake, 1), ==, "/after");
  wx_http_get_async(http, "//bad", JSON_ACCEPT, NULL, NULL, on_done, &o); /* arguments still checked */
  wait_for(&o, g_get_monotonic_time());
  g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
  outcome_clear(&o);
  g_assert_true(WX_IS_HTTP(http));
  g_object_unref(http);

  /* The same with pacing (queue and timer) and with a retry in back-off. */
  Step flaky[] = {{STEP_RESPOND, 503, "{}", NULL, 0, 0}, {STEP_RESPOND, 200, "{}", NULL, 0, 0}};
  Fake *fake2 = fake_new(flaky, 2);
  WxHttp *paced = http_for(fake2, 5000, 20, 100);
  Outcome two[2] = {{0}};
  gint64 starts[2];
  get(paced, "/a", NULL, NULL, &two[0], &starts[0]);
  get(paced, "/b", NULL, NULL, &two[1], &starts[1]);
  g_object_run_dispose(G_OBJECT(paced));
  wait_all(two, 2);
  g_assert_no_error(two[0].error); /* 503, back-off, 200 */
  g_assert_no_error(two[1].error);
  outcome_clear(&two[0]);
  outcome_clear(&two[1]);
  g_object_unref(paced);
  fake_free(fake2);
  fake_free(fake);
}

static void
test_net_if_modified_since_and_304(void)
{
  /* Not sent unless asked for. */
  Step ok[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(ok, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/a", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_null(g_strstr_len(fake_head(fake, 0), -1, "If-Modified-Since"));
  outcome_clear(&o);
  /* Sent verbatim when given. */
  get(http, "/b", "Sun, 06 Nov 1994 08:49:37 GMT", NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_nonnull(g_strstr_len(fake_head(fake, 1), -1, "If-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT\r\n"));
  g_assert_cmpuint(o.response->status, ==, 200);
  outcome_clear(&o);
  fake_free(fake);

  /* 304 to a conditional request: success, empty body, the new validators come through. */
  gint64 now = now_s();
  g_autoptr(GDateTime) soon = g_date_time_new_from_unix_utc(now + 3600);
  g_autofree char *expires = g_date_time_format(soon, "Expires: %a, %d %b %Y %H:%M:%S GMT\r\n");
  g_autofree char *headers = g_strconcat(expires, "Last-Modified: Mon, 07 Nov 1994 08:49:37 GMT\r\n", NULL);
  Step not_modified[] = {{STEP_RESPOND, 304, "", headers, 0, 0}};
  Fake *fake2 = fake_new(not_modified, 1);
  g_autoptr(WxHttp) http2 = http_for(fake2, 2000, 5, 0);
  get(http2, "/c", "Sun, 06 Nov 1994 08:49:37 GMT", NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_nonnull(o.response);
  g_assert_cmpuint(o.response->status, ==, 304);
  g_assert_nonnull(o.response->body);
  g_assert_cmpuint(g_bytes_get_size(o.response->body), ==, 0);
  g_assert_cmpint(o.response->expires_s, >=, now + 3600 - 2);
  g_assert_cmpint(o.response->expires_s, <=, now + 3600 + 2);
  g_assert_cmpstr(o.response->last_modified, ==, "Mon, 07 Nov 1994 08:49:37 GMT");
  g_assert_cmpuint(fake2->requests, ==, 1); /* a 304 is final, not retried */
  outcome_clear(&o);
  fake_free(fake2);
}

static void
test_net_expires_and_last_modified_headers(void)
{
  gint64 now = now_s();
  struct {
    gint64 offset; /* Expires relative to now; G_MININT64: no header; G_MAXINT64: garbage */
    gboolean valid;
  } expires_cases[] = {
      {3600, TRUE}, {60, TRUE}, {86400 - 120, TRUE}, {86400 + 120, FALSE}, {-3600, FALSE}, {-1, FALSE},
      {100 * 86400, FALSE}, {G_MININT64, FALSE}, {G_MAXINT64, FALSE},
  };
  for (guint i = 0; i < G_N_ELEMENTS(expires_cases); i++) {
    g_autofree char *headers = NULL;
    if (expires_cases[i].offset == G_MININT64) {
      headers = g_strdup("");
    } else if (expires_cases[i].offset == G_MAXINT64) {
      headers = g_strdup("Expires: not a date\r\n");
    } else {
      g_autoptr(GDateTime) when = g_date_time_new_from_unix_utc(now + expires_cases[i].offset);
      headers = g_date_time_format(when, "Expires: %a, %d %b %Y %H:%M:%S GMT\r\n");
    }
    Step step = {STEP_RESPOND, 200, kBody, headers, 0, 0};
    Fake *fake = fake_new(&step, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    if (expires_cases[i].valid) {
      g_assert_cmpint(o.response->expires_s, >=, now + expires_cases[i].offset - 2);
      g_assert_cmpint(o.response->expires_s, <=, now + expires_cases[i].offset + 2);
    } else {
      g_assert_cmpint(o.response->expires_s, ==, 0);
    }
    outcome_clear(&o);
    fake_free(fake);
  }

  /* Last-Modified: kept only when printable ASCII and <= 64 bytes. */
  g_autofree char *lm64 = g_strnfill(WX_HTTP_VALIDATOR_MAX, 'a');
  g_autofree char *lm65 = g_strnfill(WX_HTTP_VALIDATOR_MAX + 1, 'a');
  struct {
    const char *header;
    const char *expect; /* NULL: dropped */
  } lm_cases[] = {
      {"", NULL},
      {"Last-Modified: Sun, 06 Nov 1994 08:49:37 GMT\r\n", "Sun, 06 Nov 1994 08:49:37 GMT"},
      {"Last-Modified: x\r\n", "x"},
      {"Last-Modified: \r\n", NULL},
      {"Last-Modified: caf\xc3\xa9\r\n", NULL},
      {"Last-Modified: a\x01" "b\r\n", NULL},
      {"Last-Modified: a\x7f" "b\r\n", NULL},
  };
  for (guint i = 0; i < G_N_ELEMENTS(lm_cases) + 2; i++) {
    g_autofree char *dynamic = NULL;
    const char *header;
    const char *expect;
    if (i < G_N_ELEMENTS(lm_cases)) {
      header = lm_cases[i].header;
      expect = lm_cases[i].expect;
    } else if (i == G_N_ELEMENTS(lm_cases)) {
      dynamic = g_strdup_printf("Last-Modified: %s\r\n", lm64);
      header = dynamic;
      expect = lm64;
    } else {
      dynamic = g_strdup_printf("Last-Modified: %s\r\n", lm65);
      header = dynamic;
      expect = NULL;
    }
    Step step = {STEP_RESPOND, 200, kBody, header, 0, 0};
    Fake *fake = fake_new(&step, 1);
    g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    g_assert_cmpstr(o.response->last_modified, ==, expect);
    outcome_clear(&o);
    fake_free(fake);
  }

  /* Duplicate headers must not confuse or crash the parsing. */
  g_autoptr(GDateTime) soon = g_date_time_new_from_unix_utc(now + 600);
  g_autofree char *e1 = g_date_time_format(soon, "Expires: %a, %d %b %Y %H:%M:%S GMT\r\n");
  g_autofree char *dup = g_strconcat(e1, e1, "Last-Modified: a\r\nLast-Modified: b\r\n", NULL);
  Step step = {STEP_RESPOND, 200, kBody, dup, 0, 0};
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_true(o.response->last_modified == NULL ||
                g_str_equal(o.response->last_modified, "a") || g_str_equal(o.response->last_modified, "b"));
  outcome_clear(&o);
  fake_free(fake);
}

/* Reference RFC 3986 section 5.2.4 (remove_dot_segments) applied to the path part of @target;
 * the query is left alone. The URI layer is expected to do exactly this and nothing else. */
static char *
normalise_target(const char *target)
{
  const char *query = strchr(target, '?');
  g_autofree char *input = query != NULL ? g_strndup(target, (gsize)(query - target)) : g_strdup(target);
  GString *out = g_string_new(NULL);
  char *p = input;
  while (*p != '\0') {
    if (g_str_has_prefix(p, "../")) {
      p += 3;
    } else if (g_str_has_prefix(p, "./")) {
      p += 2;
    } else if (g_str_has_prefix(p, "/./")) {
      p += 2;
    } else if (g_str_equal(p, "/.")) {
      p[1] = '\0'; /* "/." -> "/" */
    } else if (g_str_has_prefix(p, "/../")) {
      p += 3; /* "/../x" -> "/x" */
      char *slash = strrchr(out->str, '/');
      if (slash != NULL)
        g_string_truncate(out, (gsize)(slash - out->str));
    } else if (g_str_equal(p, "/..")) {
      p[1] = '\0'; /* "/.." -> "/" */
      char *slash = strrchr(out->str, '/');
      if (slash != NULL)
        g_string_truncate(out, (gsize)(slash - out->str));
    } else if (g_str_equal(p, ".") || g_str_equal(p, "..")) {
      p += strlen(p);
    } else {
      char *next = strchr(p + (*p == '/' ? 1 : 0), '/');
      gsize n = next != NULL ? (gsize)(next - p) : strlen(p);
      g_string_append_len(out, p, (gssize)n);
      p += n;
    }
  }
  if (query != NULL)
    g_string_append(out, query);
  return g_string_free(out, FALSE);
}

/* Random request targets: every accepted one reaches the fake server (and only it) as the
 * target with dot segments removed, and always with the pinned Host. */
static void
test_net_host_pinning_fuzz(void)
{
  Step script[] = {{STEP_RESPOND, 200, "{}", NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  Fake *other = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  GRand *rng = g_rand_new_with_seed(11);
  static const char alphabet[] = "/?&=%@:.~-_+!$'()*,;[]{}|^\"<> \\#\t\xc3\xa9" "aZ09";
  guint sent = 0;
  for (guint i = 0; i < 600; i++) {
    gsize n = (gsize)g_rand_int_range(rng, 1, 14);
    char path[16] = {'/'};
    for (gsize k = 1; k < n; k++)
      path[k] = alphabet[g_rand_int_range(rng, 0, (gint32)sizeof alphabet - 1)];
    /* Sometimes aim at the other server through the authority. */
    g_autofree char *aimed = i % 7 == 0 ? g_strdup_printf("/@127.0.0.1:%u/x", other->port) : NULL;
    const char *target = aimed != NULL ? aimed : path;
    Outcome o = {0};
    gint64 start = g_get_monotonic_time();
    wx_http_get_async(http, target, JSON_ACCEPT, NULL, NULL, on_done, &o);
    wait_for(&o, start);
    if (!wx_http_path_is_valid(target)) {
      g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
    } else if (o.error != NULL) {
      /* Accepted by the validator but refused by the URI parser (a bad %-escape): nothing sent. */
      g_assert_error(o.error, WX_ERROR, WX_ERROR_INVALID_ARG);
      g_assert_nonnull(strchr(target, '%'));
    } else {
      g_autofree char *expected = normalise_target(target);
      g_assert_cmpstr(fake_path(fake, sent), ==, expected);
      sent++;
    }
    outcome_clear(&o);
  }
  g_assert_cmpuint(fake->requests, ==, sent);
  g_assert_cmpuint(sent, >, 100); /* the property was exercised, not vacuous */
  g_assert_cmpuint(other->requests, ==, 0);
  for (guint i = 0; i < fake->heads->len; i++) {
    g_autofree char *host = g_strdup_printf("\r\nHost: 127.0.0.1:%u\r\n", fake->port);
    g_assert_nonnull(g_strstr_len(fake_head(fake, i), -1, host));
  }
  g_rand_free(rng);
  fake_free(other);
  fake_free(fake);
}

/* Only the pinned origin is used: scheme/host normalisation reaches the wire as the pinned Host. */
static void
test_net_base_url_normalisation_on_the_wire(void)
{
  Step script[] = {{STEP_RESPOND, 200, "{}", NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  static const struct {
    const char *prefix;
    const char *suffix;
  } forms[] = {{"http://LOCALHOST:", ""}, {"http://localhost:", "/"}, {"HTTP://127.0.0.1:", ""},
               {"http://%6C%6F%63alhost:", ""}};
  for (guint i = 0; i < G_N_ELEMENTS(forms); i++) {
    g_autofree char *base = g_strdup_printf("%s%u%s", forms[i].prefix, fake->port, forms[i].suffix);
    g_autoptr(GError) error = NULL;
    g_autoptr(WxHttp) http = wx_http_new_custom(base, UA, 2000, 5, 0, &error);
    g_assert_no_error(error);
    Outcome o = {0};
    gint64 start;
    get(http, "/n", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    outcome_clear(&o);
    g_autofree char *host = g_strdup_printf("\r\nHost: %s:%u\r\n", i == 2 ? "127.0.0.1" : "localhost", fake->port);
    g_assert_nonnull(g_strstr_len(fake_head(fake, i), -1, host));
  }
  fake_free(fake);
}

/* --- pacing ---------------------------------------------------------------- */

static void
test_net_pacing_gap_and_single_wire(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 60}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 5, 150);
  Outcome outs[4] = {{0}};
  gint64 starts[4];
  for (guint i = 0; i < 4; i++)
    get(http, "/x", NULL, NULL, &outs[i], &starts[i]);
  wait_all(outs, 4);
  for (guint i = 0; i < 4; i++) {
    g_assert_no_error(outs[i].error);
    outcome_clear(&outs[i]);
  }
  g_assert_cmpuint(fake->requests, ==, 4);
  g_assert_cmpuint(fake->max_active, ==, 1); /* at most one on the wire */
  for (guint i = 1; i < 4; i++)
    g_assert_cmpint((fake_arrival_us(fake, i) - fake_arrival_us(fake, i - 1)) / 1000, >=, 130);
  fake_free(fake);
}

static void
test_net_pacing_off_runs_concurrently(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 300}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 5, 0);
  Outcome outs[2] = {{0}};
  gint64 starts[2];
  get(http, "/a", NULL, NULL, &outs[0], &starts[0]);
  get(http, "/b", NULL, NULL, &outs[1], &starts[1]);
  wait_all(outs, 2);
  g_assert_no_error(outs[0].error);
  g_assert_no_error(outs[1].error);
  g_assert_cmpuint(fake->max_active, ==, 2);
  g_assert_cmpint((MAX(outs[0].finished_us, outs[1].finished_us) - starts[0]) / 1000, <, 560);
  outcome_clear(&outs[0]);
  outcome_clear(&outs[1]);
  fake_free(fake);
}

static void
test_net_pacing_retry_waits_for_slot(void)
{
  Step script[] = {{STEP_RESPOND, 503, kBody, NULL, 0, 0}, {STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 2);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 0, 200); /* no back-off: only the gap */
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_no_error(o.error);
  g_assert_cmpuint(fake->requests, ==, 2);
  g_assert_cmpint((fake_arrival_us(fake, 1) - fake_arrival_us(fake, 0)) / 1000, >=, 180);
  outcome_clear(&o);
  fake_free(fake);
}

static void
test_net_cancel_while_queued(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 5, 600000); /* the second request would wait 10 minutes */
  Outcome first = {0}, second = {0};
  gint64 start, start2;
  get(http, "/a", NULL, NULL, &first, &start);
  wait_for(&first, start);
  g_assert_no_error(first.error);
  outcome_clear(&first);
  g_autoptr(GCancellable) cancellable = g_cancellable_new();
  get(http, "/b", NULL, cancellable, &second, &start2);
  g_timeout_add(100, cancel_later, cancellable);
  gint64 elapsed_ms = wait_for(&second, start2);
  g_assert_error(second.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpint(elapsed_ms, <, 3000);
  g_assert_cmpuint(fake->requests, ==, 1); /* nothing was sent for the queued request */
  outcome_clear(&second);
  fake_free(fake);
}

/* A queued request whose cancellable is cancelled from inside the previous completion callback. */
static void
on_done_then_cancel_other(GObject *source, GAsyncResult *result, gpointer user_data)
{
  Outcome *o = user_data;
  g_cancellable_cancel(o->cancel_in_callback);
  on_done(source, result, user_data);
}

static void
test_net_cancel_queued_from_completion_callback(void)
{
  Step script[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 5000, 5, 600000);
  g_autoptr(GCancellable) second_cancel = g_cancellable_new();
  Outcome first = {0}, second = {0};
  first.cancel_in_callback = second_cancel;
  gint64 start = g_get_monotonic_time();
  wx_http_get_async(http, "/a", JSON_ACCEPT, NULL, NULL, on_done_then_cancel_other, &first);
  wx_http_get_async(http, "/b", JSON_ACCEPT, NULL, second_cancel, on_done, &second);
  while (!first.done || !second.done)
    g_main_context_iteration(NULL, TRUE);
  g_assert_no_error(first.error);
  g_assert_error(second.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
  g_assert_cmpuint(fake->requests, ==, 1);
  g_assert_cmpint((second.finished_us - start) / 1000, <, 3000);
  outcome_clear(&first);
  outcome_clear(&second);
  fake_free(fake);
}

/* Sequential volume: slots and sources are released (leak/valgrind and cap checks). */
static void
test_net_many_sequential_requests(void)
{
  Step script[] = {{STEP_RESPOND, 200, "{}", NULL, 0, 0}};
  Fake *fake = fake_new(script, 1);
  g_autoptr(WxHttp) http = http_for(fake, 2000, 5, 0);
  for (guint i = 0; i < 80; i++) {
    Outcome o = {0};
    gint64 start;
    get(http, "/x", NULL, NULL, &o, &start);
    wait_for(&o, start);
    g_assert_no_error(o.error);
    outcome_clear(&o);
  }
  /* Batches larger than the cap, in waves. */
  for (guint wave = 0; wave < 3; wave++) {
    Outcome outs[WX_HTTP_MAX_INFLIGHT] = {{0}};
    gint64 start;
    for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++)
      get(http, "/x", NULL, NULL, &outs[i], &start);
    wait_all(outs, WX_HTTP_MAX_INFLIGHT);
    for (guint i = 0; i < WX_HTTP_MAX_INFLIGHT; i++) {
      g_assert_no_error(outs[i].error);
      outcome_clear(&outs[i]);
    }
  }
  fake_free(fake);
}

/* The cap is enforced while reading: a server that streams far more than the cap is not drained. */
static void
test_net_body_cap_stops_reading(void)
{
  const gsize cap = WX_HTTP_MAX_BODY_BYTES;
  const gsize offered = (gsize)512 * 1024 * 1024;
  Step step = {STEP_BIG_STREAMED, 0, NULL, NULL, offered, 0};
  Fake *fake = fake_new(&step, 1);
  g_autoptr(WxHttp) http = http_for(fake, 20000, 5, 0);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_PARSE);
  g_assert_cmpuint(fake->requests, ==, 1);
  outcome_clear(&o);
  spin(300);
  /* Only socket buffers worth of data beyond the cap were ever accepted by the kernel. */
  g_assert_cmpuint(fake->big_sent, >, cap);
  g_assert_cmpuint(fake->big_sent, <, cap + (gsize)64 * 1024 * 1024);
  g_assert_cmpuint(fake->big_sent, <, offered / 4);
  fake_free(fake);
}

/* --- TLS: certificates are verified ------------------------------------------ */

/* A throw-away self-signed certificate for CN/SAN 127.0.0.1 (EC P-256, test only). */
static const char kTestCertPem[] =
    "-----BEGIN CERTIFICATE-----\n"
    "MIIBkDCCATagAwIBAgIUEJ3+CPYfSGuGgV0zawMs0itrygEwCgYIKoZIzj0EAwIw\n"
    "FDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTAxMjAyMDg0NVoYDzIxMjYwOTE4\n"
    "MDIwODQ1WjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjO\n"
    "PQMBBwNCAATNCLIcH8kLhl6iNEvnts4Lpr5UK/txzONrTig7raO9HOy6IoFP2iMP\n"
    "ukUMH5AxeuW0pkgO0N9A7dsE9H6Wlu9Ho2QwYjAdBgNVHQ4EFgQULBp9fpv2H/OK\n"
    "fWqmzGD3HyZquV4wHwYDVR0jBBgwFoAULBp9fpv2H/OKfWqmzGD3HyZquV4wDwYD\n"
    "VR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMAoGCCqGSM49BAMCA0gAMEUC\n"
    "IQCzulUzzY8LyG1arq2em71QssNdR7lmMmjbTAMRcSugugIgD4kv9cNH3Wa3ZFZU\n"
    "qXp+gcAkyseh7WKuJY97HydSf0U=\n"
    "-----END CERTIFICATE-----\n"
    "-----BEGIN PRIVATE KEY-----\n"
    "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgHms+iuh/Ws2k3K/d\n"
    "cxkH0BTpruMSnhnsgJMNjPDjB6ehRANCAATNCLIcH8kLhl6iNEvnts4Lpr5UK/tx\n"
    "zONrTig7raO9HOy6IoFP2iMPukUMH5AxeuW0pkgO0N9A7dsE9H6Wlu9H\n"
    "-----END PRIVATE KEY-----\n";

typedef struct {
  GSocketService *service;
  GTlsCertificate *certificate;
  guint port;
  guint started;   /* TLS handshakes begun */
  guint completed; /* TLS handshakes that succeeded on the server side */
} TlsFake;

static void
on_tls_handshake(GObject *source, GAsyncResult *result, gpointer user_data)
{
  TlsFake *fake = user_data;
  g_autoptr(GError) error = NULL;
  if (g_tls_connection_handshake_finish(G_TLS_CONNECTION(source), result, &error))
    fake->completed++;
  (void)g_io_stream_close(G_IO_STREAM(source), NULL, NULL);
  g_object_unref(source);
}

static gboolean
on_tls_incoming(GSocketService *service, GSocketConnection *connection, GObject *source, gpointer user_data)
{
  (void)service;
  (void)source;
  TlsFake *fake = user_data;
  g_autoptr(GError) error = NULL;
  GIOStream *tls = g_tls_server_connection_new(G_IO_STREAM(connection), fake->certificate, &error);
  g_assert_no_error(error);
  fake->started++;
  g_tls_connection_handshake_async(G_TLS_CONNECTION(tls), G_PRIORITY_DEFAULT, NULL, on_tls_handshake, fake);
  return TRUE;
}

static void
on_control_connected(GObject *source, GAsyncResult *result, gpointer user_data)
{
  gboolean *ok = user_data;
  g_autoptr(GError) error = NULL;
  GSocketConnection *connection =
      g_socket_client_connect_to_host_finish(G_SOCKET_CLIENT(source), result, &error);
  *ok = connection != NULL;
  if (connection != NULL) {
    (void)g_io_stream_close(G_IO_STREAM(connection), NULL, NULL);
    g_object_unref(connection);
  }
}

/*
 * An HTTPS server presenting a self-signed certificate must be refused: the client verifies the
 * chain (a control client that does not verify does reach the same server), the failure is a
 * transport error that is retried like any other, and nothing is ever sent in clear text.
 */
static void
test_net_tls_certificate_is_verified(void)
{
  if (!g_tls_backend_supports_tls(g_tls_backend_get_default())) {
    g_test_skip("no TLS backend available");
    return;
  }
  TlsFake fake = {0};
  g_autoptr(GError) error = NULL;
  fake.certificate = g_tls_certificate_new_from_pem(kTestCertPem, -1, &error);
  g_assert_no_error(error);
  fake.service = g_socket_service_new();
  fake.port = g_socket_listener_add_any_inet_port(G_SOCKET_LISTENER(fake.service), NULL, &error);
  g_assert_no_error(error);
  g_signal_connect(fake.service, "incoming", G_CALLBACK(on_tls_incoming), &fake);
  g_socket_service_start(fake.service);

  /* Control: a TLS client that disables validation completes the handshake with this server. */
  g_autoptr(GSocketClient) lax = g_socket_client_new();
  g_socket_client_set_tls(lax, TRUE);
  g_socket_client_set_tls_validation_flags(lax, 0);
  gboolean connected = FALSE;
  g_socket_client_connect_to_host_async(lax, "127.0.0.1", (guint16)fake.port, NULL, on_control_connected,
                                        &connected);
  gint64 until = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
  while (fake.completed == 0 && g_get_monotonic_time() < until)
    g_main_context_iteration(NULL, FALSE);
  g_assert_cmpuint(fake.completed, >, 0);
  spin(50);
  g_assert_true(connected);

  /* WxHttp: https://127.0.0.1 with the untrusted certificate. */
  guint completed_before = fake.completed;
  guint started_before = fake.started;
  g_autofree char *base = g_strdup_printf("https://127.0.0.1:%u", fake.port);
  g_autoptr(WxHttp) http = wx_http_new_custom(base, UA, 3000, 5, 0, NULL);
  g_assert_nonnull(http);
  Outcome o = {0};
  gint64 start;
  get(http, "/x", NULL, NULL, &o, &start);
  wait_for(&o, start);
  g_assert_null(o.response);
  g_assert_error(o.error, WX_ERROR, WX_ERROR_NETWORK); /* TLS failure: retried, then final */
  g_assert_nonnull(g_strstr_len(o.error->message, -1, "certificate"));
  spin(100);
  g_assert_cmpuint(fake.started, >, started_before); /* the client did connect and start TLS */
  g_assert_cmpuint(fake.completed, ==, completed_before); /* but no handshake was completed */
  outcome_clear(&o);

  g_socket_service_stop(fake.service);
  g_socket_listener_close(G_SOCKET_LISTENER(fake.service));
  g_object_unref(fake.service);
  g_object_unref(fake.certificate);
}

/* --- whole-operation deadline (45 s of wall time; see the file comment) ----- */

static void
test_net_total_deadline(void)
{
  /* (a) one attempt that never finishes: the per-attempt timeout is longer than the deadline;
   * (b) an attempt that fails, then a back-off longer than the deadline;
   * (c) a request queued behind the pacing gap;
   * (d) per-attempt deadlines that fit twice (20 s + 1 s + 20 s + 2 s) but not a third time;
   * (e) a hanging request that the user cancels long before the deadline (control). */
  Step hang[] = {{STEP_HANG, 0, NULL, NULL, 0, 0}};
  Step fail503[] = {{STEP_RESPOND, 503, kBody, NULL, 0, 0}};
  Step ok[] = {{STEP_RESPOND, 200, kBody, NULL, 0, 0}};
  Fake *fa = fake_new(hang, 1), *fb = fake_new(fail503, 1), *fc = fake_new(ok, 1), *fd = fake_new(hang, 1);
  g_autoptr(WxHttp) ha = http_for(fa, 600000, 5, 0);
  g_autoptr(WxHttp) hb = http_for(fb, 2000, 600000, 0);
  g_autoptr(WxHttp) hc = http_for(fc, 2000, 5, 600000);
  g_autoptr(WxHttp) hd = http_for(fd, 20000, 1000, 0);
  Outcome oa = {0}, ob = {0}, oc1 = {0}, oc2 = {0}, od = {0};
  gint64 sa, sb, sc1, sc2, sd;
  get(ha, "/x", NULL, NULL, &oa, &sa);
  get(hb, "/x", NULL, NULL, &ob, &sb);
  get(hc, "/x", NULL, NULL, &oc1, &sc1);
  get(hc, "/y", NULL, NULL, &oc2, &sc2); /* waits for the 10 minute gap */
  get(hd, "/x", NULL, NULL, &od, &sd);
  while (!oa.done || !ob.done || !oc1.done || !oc2.done || !od.done)
    g_main_context_iteration(NULL, TRUE);

  gint64 ea = (oa.finished_us - sa) / 1000, eb = (ob.finished_us - sb) / 1000;
  gint64 ec = (oc2.finished_us - sc2) / 1000, ed = (od.finished_us - sd) / 1000;
  g_assert_error(oa.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fa->requests, ==, 1); /* no retry after the deadline */
  g_assert_error(ob.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fb->requests, ==, 1);
  g_assert_no_error(oc1.error);
  g_assert_error(oc2.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fc->requests, ==, 1);
  g_assert_error(od.error, WX_ERROR, WX_ERROR_TIMEOUT);
  g_assert_cmpuint(fd->requests, ==, 3);
  gint64 lo = WX_HTTP_TOTAL_DEADLINE_MS - 300, hi = WX_HTTP_TOTAL_DEADLINE_MS + 2500;
  g_assert_cmpint(ea, >=, lo);
  g_assert_cmpint(ea, <=, hi);
  g_assert_cmpint(eb, >=, lo);
  g_assert_cmpint(eb, <=, hi);
  g_assert_cmpint(ec, >=, lo);
  g_assert_cmpint(ec, <=, hi);
  g_assert_cmpint(ed, >=, lo);
  g_assert_cmpint(ed, <=, hi);
  assert_no_body_text(ob.error);
  outcome_clear(&oa);
  outcome_clear(&ob);
  outcome_clear(&oc1);
  outcome_clear(&oc2);
  outcome_clear(&od);
  fake_free(fa);
  fake_free(fb);
  fake_free(fc);
  fake_free(fd);
}

/* ------------------------------------------------------------------------ */

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  /* Loopback traffic must never be sent through a user's proxy settings. */
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  /* Library error messages are asserted in one place (the TLS test): keep them untranslated
   * whatever the environment says. */
  g_setenv("LANGUAGE", "C", TRUE);
  (void)setlocale(LC_ALL, "C");

  g_test_add_func("/http/json/accepts", test_json_parse_accepts);
  g_test_add_func("/http/json/rejects-grammar", test_json_parse_rejects_grammar);
  g_test_add_func("/http/json/duplicate-names", test_json_duplicate_names);
  g_test_add_func("/http/json/member-limit", test_json_member_limit);
  g_test_add_func("/http/json/duplicate-flood-is-fast", test_json_duplicate_flood_is_fast);
  g_test_add_func("/http/json/hash-collisions", test_json_hash_collisions_are_bounded);
  g_test_add_func("/http/json/rejects-encoding-size", test_json_parse_rejects_encoding_and_size);
  g_test_add_func("/http/json/programmer-errors", test_json_parse_programmer_errors);
  g_test_add_func("/http/json/depth", test_json_parse_depth);
  g_test_add_func("/http/json/accessors", test_json_accessors);
  g_test_add_func("/http/json/number-in-range", test_json_number_in_range);
  g_test_add_func("/http/json/error-reason", test_json_error_reason_real);
  g_test_add_func("/http/json/differential-fuzz", test_json_differential_fuzz);
  g_test_add_func("/http/json/guard-page", test_json_guard_page);
  g_test_add_func("/http/pure/constants", test_constants);
  g_test_add_func("/http/pure/path-validation", test_path_validation);
  g_test_add_func("/http/pure/path-validation-guard-page", test_path_validation_guard_page);
  g_test_add_func("/http/pure/parse-expires", test_parse_expires);
  g_test_add_func("/http/pure/parse-expires-window", test_parse_expires_window_property);
  g_test_add_func("/http/pure/constructor-policy", test_constructor_policy);
  g_test_add_func("/http/net/success-request-shape", test_net_success_and_request_shape);
  g_test_add_func("/http/net/invalid-args", test_net_invalid_arguments_make_no_request);
  g_test_add_func("/http/net/callback-never-before-return", test_net_callback_never_before_return);
  g_test_add_func("/http/net/programmer-errors", test_net_get_programmer_errors);
  g_test_add_func("/http/net/status-mapping", test_net_status_mapping);
  g_test_add_func("/http/net/redirects-not-followed", test_net_redirect_is_never_followed);
  g_test_add_func("/http/net/retry-backoff", test_net_retry_then_success_with_backoff);
  g_test_add_func("/http/net/backoff-doubles", test_net_backoff_doubles_and_failure_is_final);
  g_test_add_func("/http/net/refused", test_net_connection_refused_is_network_error);
  g_test_add_func("/http/net/per-attempt-timeout", test_net_per_attempt_timeout);
  g_test_add_func("/http/net/timeout-covers-body", test_net_timeout_covers_body);
  g_test_add_func("/http/net/body-cap", test_net_body_cap);
  g_test_add_func("/http/net/truncated-body", test_net_truncated_body);
  g_test_add_func("/http/net/gzip", test_net_gzip);
  g_test_add_func("/http/net/gzip-truncated", test_net_gzip_truncated);
  g_test_add_func("/http/net/chunked", test_net_chunked);
  g_test_add_func("/http/net/content-coding", test_net_content_coding);
  g_test_add_func("/http/net/gzip-late-trailing-data", test_net_gzip_late_trailing_data);
  g_test_add_func("/http/net/no-content-statuses", test_net_no_content_statuses);
  g_test_add_func("/http/net/content-length-values", test_net_content_length_values);
  g_test_add_func("/http/net/content-length-repeated", test_net_content_length_repeated);
  g_test_add_func("/http/net/content-length-vs-status", test_net_content_length_vs_status);
  g_test_add_func("/http/net/content-length-after-421", test_net_content_length_after_421);
  g_test_add_func("/http/net/transfer-encoding-lines", test_net_transfer_encoding_lines);
  g_test_add_func("/http/net/transfer-encoding-random", test_net_transfer_encoding_random);
  g_test_add_func("/http/net/criticals-are-fatal", test_net_criticals_are_fatal);
  g_test_add_func("/http/net/connection-not-reused", test_net_connection_not_reused_after_rejection);
  g_test_add_func("/http/net/informational-heads", test_net_informational_heads);
  g_test_add_func("/http/net/content-length-random", test_net_content_length_random);
  g_test_add_func("/http/net/truncated-head", test_net_truncated_head);
  g_test_add_func("/http/net/chunk-size-garbage", test_net_chunk_size_garbage);
  g_test_add_func("/http/net/unread-headers-ignored", test_net_unread_headers_are_ignored);
  g_test_add_func("/http/net/status-framing-table", test_net_status_framing_table);
  g_test_add_func("/http/net/cancel-request", test_net_cancel_during_request);
  g_test_add_func("/http/net/cancel-backoff", test_net_cancel_during_backoff);
  g_test_add_func("/http/net/pre-cancelled", test_net_pre_cancelled);
  g_test_add_func("/http/net/cancel-before-finish", test_net_cancel_before_finish);
  g_test_add_func("/http/net/cancel-other-thread", test_net_cancel_from_other_thread);
  g_test_add_func("/http/net/dropped-in-flight", test_net_http_dropped_while_in_flight);
  g_test_add_func("/http/net/reentrant-callback", test_net_reentrant_callback);
  g_test_add_func("/http/net/inflight-cap", test_net_inflight_cap);
  g_test_add_func("/http/net/inflight-slot-held-by-result", test_net_inflight_slot_held_by_result);
  g_test_add_func("/http/net/after-dispose", test_net_http_after_dispose);
  g_test_add_func("/http/net/if-modified-since-304", test_net_if_modified_since_and_304);
  g_test_add_func("/http/net/expires-last-modified", test_net_expires_and_last_modified_headers);
  g_test_add_func("/http/net/host-pinning-fuzz", test_net_host_pinning_fuzz);
  g_test_add_func("/http/net/base-url-normalisation", test_net_base_url_normalisation_on_the_wire);
  g_test_add_func("/http/net/pacing-gap", test_net_pacing_gap_and_single_wire);
  g_test_add_func("/http/net/pacing-off", test_net_pacing_off_runs_concurrently);
  g_test_add_func("/http/net/pacing-retry", test_net_pacing_retry_waits_for_slot);
  g_test_add_func("/http/net/cancel-queued", test_net_cancel_while_queued);
  g_test_add_func("/http/net/cancel-queued-from-callback", test_net_cancel_queued_from_completion_callback);
  g_test_add_func("/http/net/many-sequential", test_net_many_sequential_requests);
  g_test_add_func("/http/net/body-cap-stops-reading", test_net_body_cap_stops_reading);
  g_test_add_func("/http/net/tls-certificate-verified", test_net_tls_certificate_is_verified);
  g_test_add_func("/http/deadline/total", test_net_total_deadline);
  return g_test_run();
}
