/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
#include "wx-time.h"

#include <string.h>

#define WX_YEAR_MIN 2000
#define WX_YEAR_MAX 2100
/* Digits accepted in one duration component; 8 digits * 86400 cannot overflow. */
#define WX_DURATION_MAX_DIGITS 8

/**
 * is_digit:
 * @c: a byte.
 *
 * Locale-independent ASCII digit test (isdigit() depends on the locale).
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff @c is '0'..'9'.
 */
static gboolean
is_digit(char c)
{
  return c >= '0' && c <= '9';
}

/**
 * parse_fixed:
 * @p: start of the digits.
 * @n: number of digits, 1..9.
 * @out: (out): receives the value on success.
 *
 * Parses exactly @n ASCII digits.
 *
 * Preconditions:
 *  - @p has at least @n readable bytes (the callers have checked the length
 *    of the NUL-terminated string).
 * Postconditions:
 *  - @out is written only on TRUE.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff all @n bytes are digits.
 */
static gboolean
parse_fixed(const char *p, int n, int *out)
{
  int v = 0;
  for (int i = 0; i < n; i++) {
    if (!is_digit(p[i]))
      return FALSE;
    v = v * 10 + (p[i] - '0');
  }
  *out = v;
  return TRUE;
}

/**
 * is_leap_year:
 * @y: year.
 *
 * Preconditions: none.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE for Gregorian leap years.
 */
static gboolean
is_leap_year(int y)
{
  return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

/**
 * days_in_month:
 * @y: year.
 * @m: month 1..12.
 *
 * Preconditions: 1 <= @m <= 12.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the number of days of that month.
 */
static int
days_in_month(int y, int m)
{
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return (m == 2 && is_leap_year(y)) ? 29 : days[m - 1];
}

/**
 * days_from_civil:
 * @y: year.
 * @m: month 1..12.
 * @d: day 1..days_in_month().
 *
 * Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
 * algorithm; integer-only, locale and time-zone independent).
 *
 * Preconditions: a valid calendar date.
 * Postconditions: none.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: the day number (negative before 1970).
 */
static gint64
days_from_civil(int y, int m, int d)
{
  y -= (m <= 2);
  gint64 era = (y >= 0 ? y : y - 399) / 400;
  gint64 yoe = y - era * 400;
  gint64 doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  gint64 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

/* Documented in wx-time.h. */
gboolean
wx_time_parse_iso8601(const char *s, gint64 *t_s)
{
  g_return_val_if_fail(t_s != NULL, FALSE);
  if (s == NULL)
    return FALSE;
  const char *nul = memchr(s, '\0', WX_TIME_ISO8601_MAX_LEN + 1);
  if (nul == NULL)
    return FALSE;
  gsize len = (gsize)(nul - s);
  /* "YYYY-MM-DDTHH:MM:SSZ" is the shortest valid form. */
  if (len < 20)
    return FALSE;

  int year, month, day, hour, minute, second;
  if (s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':')
    return FALSE;
  if (!parse_fixed(s, 4, &year) || !parse_fixed(s + 5, 2, &month) ||
      !parse_fixed(s + 8, 2, &day) || !parse_fixed(s + 11, 2, &hour) ||
      !parse_fixed(s + 14, 2, &minute) || !parse_fixed(s + 17, 2, &second))
    return FALSE;
  if (year < WX_YEAR_MIN || year > WX_YEAR_MAX || month < 1 || month > 12 || day < 1 ||
      day > days_in_month(year, month) || hour > 23 || minute > 59 || second > 59)
    return FALSE;

  gsize pos = 19;
  if (s[pos] == '.') {
    pos++;
    gsize first = pos;
    while (pos < len && is_digit(s[pos]))
      pos++;
    if (pos == first)
      return FALSE;
  }

  gint64 offset_s = 0;
  if (s[pos] == 'Z') {
    if (pos + 1 != len)
      return FALSE;
  } else if (s[pos] == '+' || s[pos] == '-') {
    int oh, om;
    if (len - pos != 6 || s[pos + 3] != ':' || !parse_fixed(s + pos + 1, 2, &oh) ||
        !parse_fixed(s + pos + 4, 2, &om) || oh > 23 || om > 59)
      return FALSE;
    offset_s = (gint64)(oh * 3600 + om * 60);
    if (s[pos] == '-')
      offset_s = -offset_s;
  } else {
    return FALSE;
  }

  *t_s = days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset_s;
  return TRUE;
}

/* Documented in wx-time.h. */
gboolean
wx_time_parse_iso8601_duration(const char *s, gint64 *seconds)
{
  g_return_val_if_fail(seconds != NULL, FALSE);
  if (s == NULL || memchr(s, '\0', WX_TIME_DURATION_MAX_LEN + 1) == NULL)
    return FALSE;
  if (*s != 'P')
    return FALSE;

  const char *p = s + 1;
  gint64 total = 0;
  gboolean any = FALSE;
  gboolean in_time = FALSE;
  gboolean seen_days = FALSE;
  int last_rank = 0; /* 1 = H, 2 = M, 3 = S */

  while (*p != '\0') {
    if (*p == 'T') {
      /* Only one 'T', and it must be followed by a time component. */
      if (in_time || p[1] == '\0')
        return FALSE;
      in_time = TRUE;
      p++;
      continue;
    }
    int digits = 0;
    gint64 value = 0;
    while (is_digit(*p)) {
      if (++digits > WX_DURATION_MAX_DIGITS)
        return FALSE;
      value = value * 10 + (*p - '0');
      p++;
    }
    if (digits == 0)
      return FALSE;
    char unit = *p;
    if (unit == '\0')
      return FALSE;
    p++;
    if (!in_time) {
      if (unit != 'D' || seen_days)
        return FALSE;
      seen_days = TRUE;
      total += value * 86400;
    } else {
      int rank;
      gint64 mult;
      if (unit == 'H') {
        rank = 1;
        mult = 3600;
      } else if (unit == 'M') {
        rank = 2;
        mult = 60;
      } else if (unit == 'S') {
        rank = 3;
        mult = 1;
      } else {
        return FALSE;
      }
      if (rank <= last_rank)
        return FALSE;
      last_rank = rank;
      total += value * mult;
    }
    any = TRUE;
    if (total > WX_TIME_DURATION_MAX_S)
      return FALSE;
  }
  if (!any)
    return FALSE;
  *seconds = total;
  return TRUE;
}

/* Documented in wx-time.h. */
gboolean
wx_time_parse_interval(const char *s, gint64 *start_s, gint64 *duration_s)
{
  g_return_val_if_fail(start_s != NULL && duration_s != NULL, FALSE);
  if (s == NULL)
    return FALSE;
  const char *nul = memchr(s, '\0', WX_TIME_INTERVAL_MAX_LEN + 1);
  if (nul == NULL)
    return FALSE;
  const char *slash = memchr(s, '/', (gsize)(nul - s));
  if (slash == NULL || memchr(slash + 1, '/', (gsize)(nul - slash - 1)) != NULL)
    return FALSE;
  gsize start_len = (gsize)(slash - s);
  if (start_len > WX_TIME_ISO8601_MAX_LEN)
    return FALSE;

  char start_text[WX_TIME_ISO8601_MAX_LEN + 1];
  memcpy(start_text, s, start_len);
  start_text[start_len] = '\0';

  gint64 start, duration;
  if (!wx_time_parse_iso8601(start_text, &start) ||
      !wx_time_parse_iso8601_duration(slash + 1, &duration) || duration <= 0)
    return FALSE;
  *start_s = start;
  *duration_s = duration;
  return TRUE;
}
