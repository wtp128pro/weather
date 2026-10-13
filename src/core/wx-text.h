/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-text.h - bounded, sanitising helpers for text that comes from outside the
 * process (provider responses, files, user input) before it is stored or
 * displayed.
 *
 * "Forbidden" characters, in every function below: Unicode control characters
 * (category Cc: C0, DEL, C1), line/paragraph separators U+2028/U+2029, and the
 * bidirectional formatting characters U+061C, U+200E, U+200F, U+202A..U+202E
 * and U+2066..U+2069 (they could reorder or spoof surrounding text).
 *
 * Pure functions; no global state.
 */
#ifndef WX_TEXT_H
#define WX_TEXT_H

#include <glib.h>

G_BEGIN_DECLS

/**
 * wx_sanitize_text:
 * @s: (nullable): text to clean.
 * @max_bytes: maximum length of the result in bytes (without the NUL).
 *
 * Produces a display-safe copy: forbidden characters are removed, every
 * invalid UTF-8 byte is replaced by U+FFFD (three bytes), and the result is
 * cut on a UTF-8 character boundary so that it never exceeds @max_bytes.
 *
 * Read bound: the string is read left to right and
 *  - nothing more is read once the output holds @max_bytes bytes (checked
 *    before the next byte is looked at) or after the first NUL;
 *  - a character is decided from its lead byte alone when that byte is ASCII
 *    or can never start a valid sequence (0x80..0xC1: stray continuation or
 *    overlong lead; 0xF5..0xFF: beyond U+10FFFF, the legacy 5- and 6-byte
 *    leads included): one byte is consumed and U+FFFD is produced;
 *  - a lead byte 0xC2..0xDF / 0xE0..0xEF / 0xF0..0xF4 is followed by at most
 *    1 / 2 / 3 more bytes, and examination stops at the first byte that is
 *    not a continuation byte (it is then not consumed): the lead byte alone
 *    is replaced by U+FFFD and the following bytes are examined afresh.
 * So no byte more than 3 positions beyond the lead byte of the character
 * being examined is ever read, for any byte values. A character that does not
 * fit ends the scan (the characters after it are never read).
 * Forbidden characters before the output is full must be skipped one by one,
 * so the cost is linear in the input consumed up to that point (a huge run of
 * forbidden characters at the very start is the only way to make it long).
 *
 * Preconditions:
 *  - @s is NULL or NUL-terminated (arbitrary bytes are fine). A buffer
 *    without terminator is safe only if reading stops inside it: the output
 *    is full, or the first character that does not fit is complete inside the
 *    buffer, before the buffer ends; a trailing lead byte 0xC2..0xF4 cut off
 *    by the end of the buffer is examined up to 3 bytes beyond itself, so
 *    the buffer must then be followed by 3 readable bytes.
 * Postconditions:
 *  - the result is valid UTF-8, contains no forbidden character and has at
 *    most @max_bytes bytes; it is "" for NULL, for empty input, for input
 *    that holds only forbidden characters, and for any @max_bytes smaller than
 *    the UTF-8 length of the first kept character (so up to 3: an astral
 *    character needs 4 bytes, a BMP character up to 3, and a replacement
 *    character 3).
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated string; never NULL; g_free() it.
 */
char *wx_sanitize_text(const char *s, gsize max_bytes);

/**
 * wx_text_is_usable_name:
 * @s: (nullable): candidate name.
 * @max: maximum accepted length in bytes (without the NUL).
 *
 * Decides whether @s may be used as a name (place, admin region, country)
 * without modification. At most the first @max + 1 bytes are read (a single
 * bounded search for the terminator comes first; a string without NUL in
 * that window is rejected before any byte is interpreted), whatever their
 * values.
 *
 * Preconditions:
 *  - @s is NULL or NUL-terminated (or has @max + 1 readable bytes).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @s is non-NULL, 1..@max bytes long, valid UTF-8, free of
 *   forbidden characters and contains at least one non-whitespace character.
 */
gboolean wx_text_is_usable_name(const char *s, gsize max);

/**
 * wx_truncated_copy:
 * @s: (nullable): text to copy.
 * @max_chars: maximum number of Unicode characters to keep.
 *
 * Copies at most @max_chars characters of @s (no ellipsis is added). The copy
 * ends before the first invalid UTF-8 sequence (a stray continuation byte, a
 * truncated or overlong form, a surrogate or a value above U+10FFFF),
 * so it is always valid UTF-8, but forbidden characters are NOT removed (use
 * wx_sanitize_text() for that).
 *
 * Read bound (same decoding rule as wx_sanitize_text()): the string is read
 * left to right; once @max_chars characters have been copied nothing more is
 * read (checked before the next byte is looked at). A character is decided
 * from its lead byte alone when that byte is ASCII or can never start a valid
 * sequence (0x80..0xC1, 0xF5..0xFF, the legacy 5- and 6-byte leads
 * included); a lead byte 0xC2..0xDF / 0xE0..0xEF / 0xF0..0xF4 is followed by
 * at most 1 / 2 / 3 more bytes, and examination stops at the first byte that
 * is not a continuation byte. So no byte more than 3 positions beyond the
 * lead byte of the character being examined is ever read, for any byte
 * values.
 *
 * Preconditions:
 *  - @s is NULL or NUL-terminated. A buffer without terminator is safe only
 *    if reading stops inside it, i.e. @max_chars characters (or an invalid
 *    sequence that ends inside the buffer) come before its end and the last
 *    character examined is not cut off by the end of the buffer; otherwise
 *    the buffer must be followed by 3 readable bytes.
 * Postconditions:
 *  - the result is a valid-UTF-8 prefix of @s with at most @max_chars
 *    characters; "" for NULL, for @max_chars of 0 and when @s starts with an
 *    invalid sequence.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned string.
 *
 * Returns: (transfer full): newly allocated string; never NULL; g_free() it.
 */
char *wx_truncated_copy(const char *s, gsize max_chars);

G_END_DECLS

#endif /* WX_TEXT_H */
