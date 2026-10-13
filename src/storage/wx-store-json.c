/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-store-json.h"

#include <math.h>

#include "wx-fileio.h"
#include "wx-types.h"

/* Documented in wx-store-json.h. */
gboolean
wx_store_load_json(const char *path, gsize max_bytes, const char *what, JsonParser **parser,
                   GError **error)
{
  if (parser != NULL)
    *parser = NULL;
  g_return_val_if_fail(path != NULL && path[0] != '\0' && what != NULL && parser != NULL, FALSE);
  g_return_val_if_fail(error == NULL || *error == NULL, FALSE);
  g_return_val_if_fail(max_bytes < G_MAXSIZE / 4, FALSE);

  wx_file_remove_stale_temps(path);
  g_autofree char *text = NULL;
  gsize len = 0;
  if (!wx_file_read_bounded(path, max_bytes, &text, &len, error))
    return FALSE;
  if (!wx_json_check_strict(text, len, WX_JSON_MAX_DEPTH)) {
    g_set_error(error, WX_ERROR, WX_ERROR_PARSE, "%s: not strict JSON or nested deeper than %d",
                what, WX_JSON_MAX_DEPTH);
    return FALSE;
  }
  g_autoptr(JsonParser) p = json_parser_new();
  g_autoptr(GError) perr = NULL;
  if (!json_parser_load_from_data(p, text, (gssize)len, &perr)) {
    g_set_error(error, WX_ERROR, WX_ERROR_PARSE, "%s: %s", what, perr->message);
    return FALSE;
  }
  *parser = g_steal_pointer(&p);
  return TRUE;
}

/* Documented in wx-store-json.h. */
JsonObject *
wx_store_root_object(JsonNode *root, const char *what, gint64 version, GError **error)
{
  JsonObject *obj = wx_store_node_object(root);
  if (obj == NULL) {
    g_set_error(error, WX_ERROR, WX_ERROR_PARSE, "%s: top level is not an object", what);
    return NULL;
  }
  gint64 found;
  if (!wx_store_node_i64(json_object_get_member(obj, "version"), &found)) {
    g_set_error(error, WX_ERROR, WX_ERROR_PARSE, "%s: missing or invalid version", what);
    return NULL;
  }
  if (found != version) {
    g_set_error(error, WX_ERROR, WX_ERROR_PARSE, "%s: unsupported version %" G_GINT64_FORMAT, what,
                found);
    return NULL;
  }
  return obj;
}

/* Documented in wx-store-json.h. */
gboolean
wx_store_node_i64(JsonNode *n, gint64 *out)
{
  if (n == NULL || !JSON_NODE_HOLDS_VALUE(n) || json_node_get_value_type(n) != G_TYPE_INT64)
    return FALSE;
  *out = json_node_get_int(n);
  return TRUE;
}

/* Documented in wx-store-json.h. */
gboolean
wx_store_node_double(JsonNode *n, gboolean allow_null, double *out)
{
  if (n == NULL)
    return FALSE;
  if (JSON_NODE_HOLDS_NULL(n)) {
    *out = NAN;
    return allow_null;
  }
  if (!JSON_NODE_HOLDS_VALUE(n))
    return FALSE;
  GType t = json_node_get_value_type(n);
  if (t != G_TYPE_INT64 && t != G_TYPE_DOUBLE)
    return FALSE;
  *out = json_node_get_double(n);
  return isfinite(*out);
}

/* Documented in wx-store-json.h. */
gboolean
wx_store_node_bool(JsonNode *n, gboolean *out)
{
  if (n == NULL || !JSON_NODE_HOLDS_VALUE(n) || json_node_get_value_type(n) != G_TYPE_BOOLEAN)
    return FALSE;
  *out = json_node_get_boolean(n);
  return TRUE;
}

/* Documented in wx-store-json.h. */
const char *
wx_store_node_string(JsonNode *n)
{
  if (n == NULL || !JSON_NODE_HOLDS_VALUE(n) || json_node_get_value_type(n) != G_TYPE_STRING)
    return NULL;
  return json_node_get_string(n);
}

/* Documented in wx-store-json.h. */
JsonObject *
wx_store_node_object(JsonNode *n)
{
  return n != NULL && JSON_NODE_HOLDS_OBJECT(n) ? json_node_get_object(n) : NULL;
}

/* Documented in wx-store-json.h. */
JsonArray *
wx_store_node_array(JsonNode *n)
{
  return n != NULL && JSON_NODE_HOLDS_ARRAY(n) ? json_node_get_array(n) : NULL;
}

/* Documented in wx-store-json.h. */
GError *
wx_store_pending_error(const char *what)
{
  return g_error_new(G_IO_ERROR, G_IO_ERROR_PENDING, "%s: an asynchronous save is running", what);
}

/**
 * optional_string:
 * @o: (not nullable): a JSON object.
 * @member: (not nullable): member name.
 * @out: (out): receives the text.
 *
 * Reads an optional string member: absent means "".
 *
 * Preconditions:
 *  - @o belongs to a live parser; @member is NUL-terminated; @out non-NULL.
 * Postconditions:
 *  - on TRUE *@out is "" (absent) or the string owned by the document;
 *    on FALSE (present, but not a string) *@out is untouched.
 * Thread affinity: any thread.
 * Ownership: *@out is borrowed from the document.
 *
 * Returns: FALSE iff the member exists and is not a string.
 */
static gboolean
optional_string(JsonObject *o, const char *member, const char **out)
{
  JsonNode *n = json_object_get_member(o, member);
  if (n == NULL) {
    *out = "";
    return TRUE;
  }
  *out = wx_store_node_string(n);
  return *out != NULL;
}

/* Documented in wx-store-json.h. */
WxPlace *
wx_store_place_from_json(JsonNode *node)
{
  JsonObject *o = wx_store_node_object(node);
  if (o == NULL)
    return NULL;
  const char *name = wx_store_node_string(json_object_get_member(o, "name"));
  const char *admin1, *country, *code, *tz;
  double lat, lon;
  if (name == NULL || !optional_string(o, "admin1", &admin1) ||
      !optional_string(o, "country", &country) || !optional_string(o, "country_code", &code) ||
      !optional_string(o, "timezone", &tz) ||
      !wx_store_node_double(json_object_get_member(o, "lat"), FALSE, &lat) ||
      !wx_store_node_double(json_object_get_member(o, "lon"), FALSE, &lon))
    return NULL;
  return wx_place_new(name, admin1, country, code, lat, lon, tz, NULL);
}

/* Documented in wx-store-json.h. */
void
wx_store_append_place(GString *out, const WxPlace *place)
{
  g_string_append(out, "{\"name\": ");
  wx_json_append_string(out, place->name);
  g_string_append(out, ", \"admin1\": ");
  wx_json_append_string(out, place->admin1);
  g_string_append(out, ", \"country\": ");
  wx_json_append_string(out, place->country);
  g_string_append(out, ", \"country_code\": ");
  wx_json_append_string(out, place->country_code);
  g_string_append(out, ", \"lat\": ");
  wx_json_append_double(out, place->lat);
  g_string_append(out, ", \"lon\": ");
  wx_json_append_double(out, place->lon);
  g_string_append(out, ", \"timezone\": ");
  wx_json_append_string(out, place->timezone);
  g_string_append_c(out, '}');
}
