/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-fileio.h - crash-safe small-file persistence primitives.
 *
 * All functions are synchronous and meant for small files (the callers in
 * this module cap them at 1 MiB / 8 MiB). The file functions block on disk
 * I/O (including fsync). Deferring them to an idle or debounce handler does
 * NOT help: that handler still runs on the main thread. A UI thread MUST NOT
 * call them; run them on a worker thread (wx_cache_save_async(), wx_places_save_async() and
 * wx_settings_save_async() do) and use them directly only for start-up,
 * shutdown and tests. They hold no locks and touch no global state, so they
 * may run in any thread.
 */
#ifndef WX_FILEIO_H
#define WX_FILEIO_H

#include <glib.h>

G_BEGIN_DECLS

/** Deepest array/object nesting that the loaders of this module accept. */
#define WX_JSON_MAX_DEPTH 32

/** Infix of the temporary file names: "<path>" WX_TEMP_INFIX "XXXXXX". */
#define WX_TEMP_INFIX ".wx-tmp-"

/**
 * wx_file_write_atomic:
 * @path: (not nullable): destination file path; non-empty, NUL-terminated.
 *   Its parent directories are created (mode 0700) when missing; the mode of
 *   a directory that already exists is NOT changed.
 * @data: (nullable) (array length=len): the bytes to store (need not be
 *   NUL-terminated); may be NULL only when @len is 0.
 * @len: number of bytes in @data.
 * @error: (nullable): return location for a #GError in the G_FILE_ERROR
 *   domain, may be NULL.
 *
 * Replaces the content of @path so that readers observe either the complete
 * old file or the complete new file, never a partial one: the bytes are
 * written to a fresh temporary file "<path>.wx-tmp-XXXXXX" in the SAME directory
 * (created with mode 0600, so the stored file is private to the user),
 * fsync()ed, closed and then rename()d over @path. Afterwards the directory
 * is fsync()ed on a best-effort basis (a failure of that last step is
 * ignored). The mode of an existing @path is not preserved: the result
 * always has mode 0600. If @path is a symbolic link, the link itself is
 * replaced, not its target.
 *
 * On failure (@path unchanged, or its previous content still intact) the
 * temporary file is removed and @error is set. A process crash between
 * creating and renaming the temporary file can leave a stray
 * "<path>.wx-tmp-XXXXXX" file behind (so can exiting the process while a
 * write runs on a worker thread); it is never read by this module and is
 * removed by wx_file_remove_stale_temps().
 *
 * Preconditions:
 *  - @path is non-NULL, non-empty and NUL-terminated; @data is NULL only if
 *    @len == 0, otherwise it points to at least @len readable bytes;
 *    @error is NULL or points to a NULL #GError pointer. A violated
 *    precondition returns FALSE with a critical and does not touch @error.
 * Postconditions:
 *  - on TRUE: @path holds exactly the @len bytes of @data with mode 0600 and
 *    no temporary file of this call remains.
 *  - on FALSE: @error (if non-NULL) is set (G_FILE_ERROR_* mapped from errno);
 *    @path is unchanged; the temporary file of this call has been removed.
 *    Missing parent directories created before the failure stay.
 * Thread affinity: any thread (no locks, no global state; blocks on disk
 *   I/O including fsync).
 * Ownership: @path and @data are borrowed for the call only; nothing is
 *   retained; @error is filled by the callee (caller frees).
 *
 * Returns: TRUE if the new content has been renamed into place.
 */
gboolean wx_file_write_atomic(const char *path, const char *data, gsize len,
                               GError **error);

/**
 * wx_file_read_bounded:
 * @path: (not nullable): file path; non-empty, NUL-terminated; must name a
 *   regular file (or a symbolic link to one: symbolic links are followed).
 * @max_bytes: largest acceptable file size in bytes (0 accepts only an empty
 *   file); must be less than G_MAXSIZE / 4.
 * @contents: (not nullable) (out) (transfer full): receives a newly allocated
 *   buffer holding the file, followed by one extra NUL byte that is not
 *   counted in @length. Free with g_free(). Set to NULL on failure.
 * @length: (out) (optional): receives the number of file bytes (excluding the
 *   extra NUL). Set to 0 on failure.
 * @error: (nullable): return location for a #GError (G_FILE_ERROR domain, except
 *   as listed below), may be NULL.
 *
 * Reads the whole file but never reads more than @max_bytes + 1 bytes nor
 * allocates more than @max_bytes + 2, whatever the size the file claims or
 * grows to while being read.
 *
 * Errors: G_FILE_ERROR_NOENT if the file does not exist;
 * G_IO_ERROR / G_IO_ERROR_MESSAGE_TOO_LARGE if it holds more than @max_bytes
 * bytes; G_FILE_ERROR_INVAL if @path is not a regular file (devices and FIFOs
 * are never read); otherwise the G_FILE_ERROR code mapped from errno.
 *
 * Preconditions:
 *  - @path is non-NULL, non-empty and NUL-terminated; @contents is non-NULL;
 *    @max_bytes < G_MAXSIZE / 4 (this keeps every size computation inside the
 *    function free of overflow); @error is NULL or points to a NULL #GError
 *    pointer. A violated precondition returns FALSE with a critical and
 *    leaves @contents, @length and @error untouched.
 * Postconditions:
 *  - on TRUE: *@contents is a NUL-terminated buffer of *@length bytes
 *    (*@length <= @max_bytes); the file descriptor has been closed.
 *  - on FALSE: *@contents is NULL, *@length (if given) is 0, nothing is
 *    allocated, and @error (if non-NULL) is set.
 *  - a symbolic link at @path is followed (no O_NOFOLLOW); this is a known,
 *    documented property, not changed here.
 * Thread affinity: any thread (blocks on disk I/O).
 * Ownership: @path is borrowed; the buffer in *@contents is transferred to
 *   the caller.
 *
 * Returns: TRUE if the complete file was read.
 */
gboolean wx_file_read_bounded(const char *path, gsize max_bytes, char **contents,
                               gsize *length, GError **error);

/**
 * wx_file_remove_stale_temps:
 * @path: (not nullable): file path as given to wx_file_write_atomic();
 *   non-empty, NUL-terminated.
 *
 * Deletes the regular files named exactly "<path>.wx-tmp-" followed by six
 * ASCII letters/digits (the names wx_file_write_atomic() creates; no other
 * name is ever touched, so user copies like "<path>.backup", "<path>.old123"
 * or "<path>.2026Q3" are safe) that sit next to @path and were last modified
 * more than 60 seconds ago, i.e. residue of a crash or of an exit during a
 * write. Younger ones are kept so that a write in progress (even in another
 * process) is never disturbed. Best effort: errors are ignored and a missing
 * directory is not an error. Blocking directory I/O: call it from start-up
 * code (the load functions of this module do), not from the UI.
 *
 * The directory is opened once and every candidate is examined with
 * fstatat(AT_SYMLINK_NOFOLLOW) and removed with unlinkat() relative to that
 * directory descriptor, so a concurrent replacement of a path component of
 * the directory cannot redirect the removal. Only regular files qualify: a
 * symbolic link (even one that matches the name pattern) or a directory is
 * left alone and never followed. The check and the unlink of one name are
 * still two separate calls; a file replaced in between by another entry of
 * the same name could be removed, but unlinkat() without AT_REMOVEDIR never
 * removes a directory.
 *
 * Preconditions:
 *  - @path is non-NULL, non-empty and NUL-terminated (else: critical, nothing
 *    happens).
 * Postconditions:
 *  - every qualifying stale temporary file next to @path has been unlinked
 *    unless an error prevented it; no error is reported; the directory
 *    descriptor is closed; no other file is modified.
 * Thread affinity: any thread (blocks on directory I/O).
 * Ownership: @path is borrowed for the call only.
 */
void wx_file_remove_stale_temps(const char *path);

/**
 * wx_json_check_strict:
 * @text: (nullable) (array length=len): JSON text (need not be
 *   NUL-terminated); may be NULL only when @len is 0.
 * @len: number of bytes in @text.
 * @max_depth: deepest accepted nesting of [] and {}; at most 32.
 *
 * Linear, non-recursive, constant-memory (a 32-bit word of container kinds)
 * gate that the loaders run BEFORE json-glib sees the data. json-glib's default
 * scanner is more lenient than RFC 8259 (it accepts C and C++ comments and
 * single-quoted strings), so any difference between the scan's idea of "inside
 * a string" and the parser's would hide brackets. This function therefore
 * accepts only the strict token alphabet and fails closed on everything else:
 * - outside strings only space, \t, \n, \r, { } [ ] , : digits - + . e E and
 *   the letters of true/false/null are allowed (so ' / # NUL, other control
 *   bytes, non-ASCII bytes and other letters are rejected);
 * - inside "..." strings a backslash must be followed by one of "\/bfnrt or
 *   u plus four hex digits that are not all zero (the escape for U+0000 is
 *   rejected: json-glib would silently cut the string at it and hand the
 *   loaders a truncated prefix, and no document written by this module can
 *   contain it, because a C string cannot hold a NUL), raw bytes < 0x20 are
 *   rejected, bytes >= 0x80 pass (UTF-8 validity is the parser's job) and the
 *   string must be terminated;
 * - every closer must match the innermost open container and every container
 *   must be closed by the end of the text;
 * - opening a container deeper than @max_depth is rejected.
 * It does not check number or value grammar (e.g. "[1 2]" passes); the parser
 * does that, and by then the nesting is known to be at most @max_depth.
 *
 * Preconditions:
 *  - @text is NULL only if @len == 0, otherwise it points to at least @len
 *    readable bytes (the scan never reads at or past @text + @len; no NUL
 *    terminator is needed); @max_depth <= 32 (else: critical, FALSE).
 * Postconditions:
 *  - no state is changed; nothing is allocated.
 * Thread affinity: any thread (pure).
 * Ownership: @text is borrowed for the call only; nothing is retained.
 *
 * Returns: TRUE if the text passes all of the above.
 */
gboolean wx_json_check_strict(const char *text, gsize len, guint max_depth);

/**
 * wx_json_append_string:
 * @out: (not nullable): string the JSON string literal is appended to.
 * @s: (not nullable): NUL-terminated UTF-8 text.
 *
 * Appends @s as an RFC 8259 string literal, including the surrounding quotes:
 * '"' and '\\' get a backslash, every byte below 0x20 becomes "\u00xx" (lower
 * case hex), everything else (including 0x7f and bytes >= 0x80) is copied
 * unchanged. Every writer of this module uses it instead of json-glib's
 * JsonGenerator, whose escaping of some control bytes (U+001F in json-glib
 * 1.10.0 to 1.10.6) is incomplete: the loaders reject files with raw control
 * bytes inside strings (wx_json_check_strict()), and the module must never
 * write a file its own loader rejects. Thread-safe; touches only @out.
 *
 * Preconditions:
 *  - @out is a valid #GString not used by another thread meanwhile; @s is
 *    non-NULL and NUL-terminated (else: critical, nothing is appended). The
 *    text is not validated: bytes >= 0x80 are copied as they are.
 * Postconditions:
 *  - @out has grown by the quoted, escaped literal (at most 6 bytes per input
 *    byte plus 2); @s is not modified.
 * Thread affinity: any thread (touches only @out).
 * Ownership: @out stays owned by the caller; @s is borrowed.
 */
void wx_json_append_string(GString *out, const char *s);

/**
 * wx_json_append_double:
 * @out: (not nullable): string the JSON number is appended to.
 * @v: any double.
 *
 * Appends @v as a JSON number that reads back bit-identical: the shortest of
 * "%.15g", "%.16g" and "%.17g" (locale independent, '.' decimal point) that
 * round-trips through g_ascii_strtod(). A value that is not finite (NAN,
 * +-infinity: JSON has no such numbers) becomes the literal "null"; negative
 * zero becomes "-0.0" (a bare "-0" would be read back as the integer 0 and
 * lose its sign). The text contains only the characters [0-9+-.eE] or the
 * word null, so it always passes wx_json_check_strict().
 *
 * Preconditions:
 *  - @out is a valid #GString not used by another thread meanwhile (else:
 *    critical, nothing is appended).
 * Postconditions:
 *  - @out has grown by one JSON number or by "null" (at most 24 bytes).
 * Thread affinity: any thread (touches only @out).
 * Ownership: @out stays owned by the caller.
 */
void wx_json_append_double(GString *out, double v);

G_END_DECLS

#endif /* WX_FILEIO_H */
