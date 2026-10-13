/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-text.h"

#include <string.h>

/* The replacement character written for every invalid UTF-8 byte. */
#define WX_REPLACEMENT_CHAR 0xFFFD

/**
 * is_forbidden_char:
 * @c: a valid Unicode scalar value.
 *
 * Classifies a character as forbidden (see wx-text.h).
 *
 * Preconditions:
 *  - @c is a valid Unicode scalar value.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE for control, line/paragraph separator and bidi formatting
 *   characters.
 */
static gboolean
is_forbidden_char(gunichar c)
{
  switch (g_unichar_type(c)) {
  case G_UNICODE_CONTROL:
  case G_UNICODE_LINE_SEPARATOR:
  case G_UNICODE_PARAGRAPH_SEPARATOR:
    return TRUE;
  default:
    break;
  }
  return c == 0x061C || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) ||
         (c >= 0x2066 && c <= 0x2069);
}

/**
 * decode_char:
 * @p: current position inside a string, *@p != 0.
 * @c: (out): receives the character, or WX_REPLACEMENT_CHAR for invalid input.
 * @len: (out): receives the number of bytes the character occupies.
 *
 * Decodes one character with a hard bound on the bytes it looks at. A byte
 * below 0x80 is decided alone. A byte that can never start a valid sequence
 * (0x80..0xC1: stray continuation or overlong lead; 0xF5..0xFF: beyond
 * U+10FFFF, including the legacy 5- and 6-byte leads) is decided alone as
 * well. A lead byte 0xC2..0xDF / 0xE0..0xEF / 0xF0..0xF4 is followed by at
 * most 1 / 2 / 3 more bytes, and the decoder stops at the first byte that is
 * not a continuation byte. So at most 4 bytes starting at @p are examined,
 * never more, whatever their values (g_utf8_get_char_validated() would look
 * at up to 6 for the legacy leads, hence the explicit lead-byte filter and
 * the explicit length passed to it).
 *
 * An invalid, overlong, surrogate, out-of-range or truncated sequence yields
 * WX_REPLACEMENT_CHAR and consumes exactly ONE byte (the lead byte).
 *
 * Preconditions:
 *  - @p points to a readable byte that is not NUL; the bytes after it are
 *    read only as described above (a NUL among them ends the sequence).
 *    @c and @len are writable.
 * Postconditions:
 *  - *@len is 1..4 and never exceeds the bytes up to the first NUL.
 *  - *@c is a valid Unicode scalar value, never NUL.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @p starts a valid UTF-8 sequence (then *@c is that
 *   character); FALSE for invalid input (then *@c is WX_REPLACEMENT_CHAR and
 *   *@len is 1).
 */
static gboolean
decode_char(const char *p, gunichar *c, gsize *len)
{
  guchar lead = (guchar)*p;
  *len = 1;
  if (lead < 0x80) {
    *c = lead;
    return TRUE;
  }
  *c = WX_REPLACEMENT_CHAR;
  if (lead < 0xC2 || lead > 0xF4)
    return FALSE;
  gsize want = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4);
  gunichar v = g_utf8_get_char_validated(p, (gssize)want);
  if (v == (gunichar)-1 || v == (gunichar)-2) /* malformed / partial */
    return FALSE;
  *c = v; /* v >= 0x80: the lead byte rules out an overlong form of U+0000 */
  *len = want;
  return TRUE;
}

/* Documented in wx-text.h. */
char *
wx_sanitize_text(const char *s, gsize max_bytes)
{
  if (s == NULL || max_bytes == 0)
    return g_strdup("");

  GString *out = g_string_sized_new(MIN(max_bytes, (gsize)256) + 1);
  const char *p = s;
  /* Output full: whatever follows (forbidden or not) cannot change the result,
   * so stop (before even looking at the next byte) instead of scanning the
   * rest of a huge input. */
  while (out->len < max_bytes && *p != '\0') {
    gunichar c;
    gsize len;
    decode_char(p, &c, &len); /* an invalid sequence yields U+FFFD and one byte */
    p += len;
    if (is_forbidden_char(c))
      continue;
    char buf[6];
    gint n = g_unichar_to_utf8(c, buf);
    if (out->len + (gsize)n > max_bytes)
      break;
    g_string_append_len(out, buf, n);
  }
  return g_string_free(out, FALSE);
}

/* Documented in wx-text.h. */
gboolean
wx_text_is_usable_name(const char *s, gsize max)
{
  if (s == NULL || max == 0)
    return FALSE;
  const char *nul = memchr(s, '\0', max < G_MAXSIZE ? max + 1 : max);
  if (nul == NULL)
    return FALSE;
  gsize len = (gsize)(nul - s);
  if (len == 0 || !g_utf8_validate(s, (gssize)len, NULL))
    return FALSE;

  gboolean visible = FALSE;
  for (const char *p = s; p < nul; p = g_utf8_next_char(p)) {
    gunichar c = g_utf8_get_char(p);
    if (is_forbidden_char(c))
      return FALSE;
    if (!g_unichar_isspace(c))
      visible = TRUE;
  }
  return visible;
}

/* Documented in wx-text.h. */
char *
wx_truncated_copy(const char *s, gsize max_chars)
{
  if (s == NULL)
    return g_strdup("");
  const char *p = s;
  gsize n = 0;
  while (n < max_chars && *p != '\0') {
    gunichar c;
    gsize len;
    if (!decode_char(p, &c, &len))
      break;
    p += len;
    n++;
  }
  return g_strndup(s, (gsize)(p - s));
}
