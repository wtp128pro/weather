/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-store-json.h - the load pipeline and the JSON node readers shared by
 * WxPlaces, WxSettings and WxCache.
 *
 * Module-internal: nothing outside src/storage uses it. Every function here
 * is a pure reader of its arguments (or of one file) and holds no state, so
 * the three loaders cannot drift apart in how they gate, parse and read data.
 * None of them ever logs a GLib warning or critical because of file content.
 */
#ifndef WX_STORE_JSON_H
#define WX_STORE_JSON_H

#include <gio/gio.h>
#include <json-glib/json-glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/**
 * wx_store_load_json:
 * @path: (not nullable): file to load; non-empty, NUL-terminated.
 * @max_bytes: largest acceptable file size; must be less than G_MAXSIZE / 4.
 * @what: (not nullable): short document name ("places", "settings", "cache")
 *   used as the prefix of error messages.
 * @parser: (not nullable) (out) (transfer full): receives the parser that
 *   holds the parsed document; NULL on failure.
 * @error: (nullable): return location for a #GError.
 *
 * The common start of every loader: removes stale temporary files next to
 * @path (wx_file_remove_stale_temps()), reads the file with
 * wx_file_read_bounded(), runs wx_json_check_strict() with WX_JSON_MAX_DEPTH
 * BEFORE json-glib sees the bytes, and parses the text. Synchronous blocking
 * file I/O.
 *
 * Errors: G_FILE_ERROR / G_FILE_ERROR_NOENT when the file does not exist;
 * G_IO_ERROR / G_IO_ERROR_MESSAGE_TOO_LARGE above @max_bytes; the other
 * G_FILE_ERROR codes for I/O failures (see wx_file_read_bounded());
 * WX_ERROR / WX_ERROR_PARSE when the text is not strict JSON, is nested
 * deeper than WX_JSON_MAX_DEPTH or is rejected by the parser.
 *
 * Preconditions:
 *  - @path, @what are non-NULL and NUL-terminated; @path is non-empty;
 *    @max_bytes < G_MAXSIZE / 4; @parser is non-NULL; @error is NULL or
 *    points to a NULL #GError pointer. A violated precondition returns FALSE
 *    with a critical, sets *@parser to NULL when @parser is non-NULL and
 *    leaves @error untouched.
 * Postconditions:
 *  - on TRUE: *@parser is a parser owning the parsed document (its root may
 *    be any JSON value; the caller checks the shape);
 *  - on FALSE: *@parser is NULL and @error (if non-NULL) is set; no memory
 *    is leaked.
 * Thread affinity: any thread (blocks on disk I/O).
 * Ownership: arguments are borrowed for the call; the caller owns *@parser.
 *
 * Returns: TRUE if the file was read, passed the gate and parsed.
 */
gboolean wx_store_load_json(const char *path, gsize max_bytes, const char *what,
                            JsonParser **parser, GError **error);

/**
 * wx_store_root_object:
 * @root: (nullable): root node of a parsed document.
 * @what: (not nullable): document name for the error message.
 * @version: the only supported value of the "version" member.
 * @error: (nullable): return location for a #GError.
 *
 * Checks that @root is an object whose "version" member is the integer
 * @version.
 *
 * Preconditions:
 *  - @root is NULL or a node owned by a live parser; @what is NUL-terminated;
 *    @error is NULL or points to a NULL #GError pointer.
 * Postconditions:
 *  - nothing is modified; on FALSE @error (if non-NULL) is set to
 *    WX_ERROR / WX_ERROR_PARSE ("not an object", "missing or invalid
 *    version" or "unsupported version N").
 * Thread affinity: any thread.
 * Ownership: @root is borrowed; the returned object belongs to @root.
 *
 * Returns: (transfer none) (nullable): the root object, or NULL on failure.
 */
JsonObject *wx_store_root_object(JsonNode *root, const char *what, gint64 version,
                                 GError **error);

/**
 * wx_store_node_i64:
 * @n: (nullable): JSON node.
 * @out: (out): receives the value.
 *
 * Preconditions: @n is NULL or a node of a live parser; @out is non-NULL.
 * Postconditions: on TRUE *@out is the integer; on FALSE *@out is untouched.
 * Thread affinity: any thread.
 * Ownership: @n is borrowed.
 *
 * Returns: TRUE iff @n is a JSON integer value (a number written with a
 *   fraction or exponent is not an integer).
 */
gboolean wx_store_node_i64(JsonNode *n, gint64 *out);

/**
 * wx_store_node_double:
 * @n: (nullable): JSON node.
 * @allow_null: whether a JSON null is acceptable (read as NAN).
 * @out: (out): receives the value.
 *
 * Reads a finite number (integer or floating point), or null as NAN when
 * @allow_null.
 *
 * Preconditions: @n is NULL or a node of a live parser; @out is non-NULL.
 * Postconditions: *@out is meaningful only when the result is TRUE (it is
 *   written for null and number nodes, untouched for others).
 * Thread affinity: any thread.
 * Ownership: @n is borrowed.
 *
 * Returns: TRUE iff @n is a finite number, or a null with @allow_null.
 */
gboolean wx_store_node_double(JsonNode *n, gboolean allow_null, double *out);

/**
 * wx_store_node_bool:
 * @n: (nullable): JSON node.
 * @out: (out): receives the value.
 *
 * Preconditions: @n is NULL or a node of a live parser; @out is non-NULL.
 * Postconditions: on TRUE *@out is the boolean; on FALSE *@out is untouched.
 * Thread affinity: any thread.
 * Ownership: @n is borrowed.
 *
 * Returns: TRUE iff @n is a JSON boolean value.
 */
gboolean wx_store_node_bool(JsonNode *n, gboolean *out);

/**
 * wx_store_node_string:
 * @n: (nullable): JSON node.
 *
 * Preconditions: @n is NULL or a node of a live parser.
 * Postconditions: no state is changed.
 * Thread affinity: any thread.
 * Ownership: the string belongs to the node (valid as long as its parser).
 *
 * Returns: (transfer none) (nullable): the string value, or NULL if @n is not
 *   a string value (a JSON null is not a string).
 */
const char *wx_store_node_string(JsonNode *n);

/**
 * wx_store_node_object:
 * @n: (nullable): JSON node.
 *
 * Preconditions: @n is NULL or a node of a live parser.
 * Postconditions: no state is changed.
 * Thread affinity: any thread.
 * Ownership: the object belongs to the node.
 *
 * Returns: (transfer none) (nullable): the object, or NULL if @n is not an
 *   object.
 */
JsonObject *wx_store_node_object(JsonNode *n);

/**
 * wx_store_node_array:
 * @n: (nullable): JSON node.
 *
 * Preconditions: @n is NULL or a node of a live parser.
 * Postconditions: no state is changed.
 * Thread affinity: any thread.
 * Ownership: the array belongs to the node.
 *
 * Returns: (transfer none) (nullable): the array, or NULL if @n is not an
 *   array.
 */
JsonArray *wx_store_node_array(JsonNode *n);

/**
 * wx_store_pending_error:
 * @what: (not nullable): document name ("places", "settings", "cache").
 *
 * Builds the error reported while an asynchronous save is running.
 *
 * Preconditions: @what is NUL-terminated.
 * Postconditions: nothing else changes.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned error.
 *
 * Returns: (transfer full): a new G_IO_ERROR / G_IO_ERROR_PENDING error.
 */
GError *wx_store_pending_error(const char *what);

/**
 * wx_store_place_from_json:
 * @node: (nullable): a JSON node holding one stored place.
 *
 * Builds a place from the object written by wx_store_append_place(). Absent
 * optional members (admin1, country, country_code, timezone) are "". A
 * present member of the wrong type, a missing name, lat or lon, a non-finite
 * coordinate or any rule of wx_place_new() violated rejects the element.
 *
 * Preconditions:
 *  - @node is NULL or a node of a live parser.
 * Postconditions:
 *  - nothing is modified; no GLib message is logged.
 * Thread affinity: any thread.
 * Ownership: @node is borrowed; the caller owns the result.
 *
 * Returns: (transfer full) (nullable): the place (wx_place_free()), or NULL if
 *   the node is not a valid stored place.
 */
WxPlace *wx_store_place_from_json(JsonNode *node);

/**
 * wx_store_append_place:
 * @out: (not nullable): string the JSON object is appended to.
 * @place: (not nullable): a valid place.
 *
 * Appends {"name":..,"admin1":..,"country":..,"country_code":..,"lat":..,
 * "lon":..,"timezone":..} using wx_json_append_string() and
 * wx_json_append_double(), so the text passes wx_json_check_strict() and the
 * coordinates read back bit-identical.
 *
 * Preconditions:
 *  - @out is a valid #GString not used by another thread meanwhile; @place is
 *    a valid place (all strings non-NULL, as wx_place_new() guarantees).
 * Postconditions:
 *  - @out has grown by one object; @place is not modified.
 * Thread affinity: any thread (touches only @out).
 * Ownership: both arguments are borrowed for the call only.
 */
void wx_store_append_place(GString *out, const WxPlace *place);

G_END_DECLS

#endif /* WX_STORE_JSON_H */
