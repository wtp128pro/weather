/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-time.h - strict, locale-independent parsers for the time formats the
 * weather providers return (RFC 3339 timestamps, ISO 8601 durations and the
 * NWS "start/duration" interval).
 *
 * Common rules: pure functions, no allocation, no global state, never read
 * more than WX_TIME_ISO8601_MAX_LEN (or the documented bound) + 1 bytes of
 * the input, outputs untouched unless the call returns TRUE.
 */
#ifndef WX_TIME_H
#define WX_TIME_H

#include <glib.h>

G_BEGIN_DECLS

/** Longest accepted timestamp, in bytes (without the NUL). */
#define WX_TIME_ISO8601_MAX_LEN 40
/** Longest accepted duration, in bytes (without the NUL). */
#define WX_TIME_DURATION_MAX_LEN 40
/** Longest accepted "start/duration" interval, in bytes (without the NUL). */
#define WX_TIME_INTERVAL_MAX_LEN 80
/** Largest accepted duration: 31 days, in seconds. */
#define WX_TIME_DURATION_MAX_S (31 * 86400)

/**
 * wx_time_parse_iso8601:
 * @s: (nullable): timestamp text.
 * @t_s: (out): receives UTC unix seconds on success; untouched on failure.
 *
 * Parses the strict RFC 3339 profile `YYYY-MM-DDTHH:MM:SS[.f+](Z|+HH:MM|-HH:MM)`.
 * The 'T' and 'Z' are upper case; a fraction needs at least one digit and is
 * truncated to whole seconds; the year is 2000..2100; the date must exist in
 * the proleptic Gregorian calendar (leap years honoured: 2000 and 2024 are
 * leap, 2100 is not); hour 00..23, minute 00..59, second 00..59 (a leap
 * second 60 is rejected); the offset is at most 23:59. Anything else, including
 * leading/trailing whitespace, a missing zone, lower case, a space separator,
 * or a length above WX_TIME_ISO8601_MAX_LEN, is rejected. The result is the
 * instant converted to UTC (offset subtracted); it may fall slightly outside
 * 2000..2100 when the offset pushes it over a year boundary.
 *
 * Preconditions:
 *  - @t_s is non-NULL and writable (NULL: critical, FALSE).
 *  - @s is NULL or NUL-terminated (or has WX_TIME_ISO8601_MAX_LEN + 1
 *    readable bytes).
 * Postconditions:
 *  - on TRUE *@t_s holds the instant; on FALSE it is untouched.
 * Thread affinity: any thread (pure; no locale or time-zone database use).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @s is a valid timestamp of the profile.
 */
gboolean wx_time_parse_iso8601(const char *s, gint64 *t_s);

/**
 * wx_time_parse_iso8601_duration:
 * @s: (nullable): duration text.
 * @seconds: (out): receives the length in seconds on success; untouched on
 *   failure.
 *
 * Parses `P[nD][T[nH][nM][nS]]`: unsigned integers of 1..8 digits, designators
 * upper case and in the order D, H, M, S; at least one component; a 'T' must
 * be followed by at least one time component. Years, months, weeks, fractions,
 * signs and whitespace are rejected. The total must not exceed
 * WX_TIME_DURATION_MAX_S (31 days); zero (e.g. "PT0S") is accepted. Length is
 * bounded by WX_TIME_DURATION_MAX_LEN.
 *
 * Preconditions:
 *  - @seconds is non-NULL and writable (NULL: critical, FALSE).
 *  - @s is NULL or NUL-terminated (or has WX_TIME_DURATION_MAX_LEN + 1
 *    readable bytes).
 * Postconditions:
 *  - on TRUE *@seconds is in [0, WX_TIME_DURATION_MAX_S]; on FALSE untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @s is a valid bounded duration.
 */
gboolean wx_time_parse_iso8601_duration(const char *s, gint64 *seconds);

/**
 * wx_time_parse_interval:
 * @s: (nullable): NWS style "start/duration", e.g. "2026-10-11T18:00:00+00:00/PT3H".
 * @start_s: (out): receives the start (UTC unix seconds) on success.
 * @duration_s: (out): receives the length in seconds on success.
 *
 * Parses exactly one '/' separating wx_time_parse_iso8601() and
 * wx_time_parse_iso8601_duration() text. Unlike the plain duration parser, a
 * zero duration is rejected (an empty interval carries no data).
 *
 * Preconditions:
 *  - @start_s and @duration_s are non-NULL and writable (NULL: critical,
 *    FALSE).
 *  - @s is NULL or NUL-terminated (or has WX_TIME_INTERVAL_MAX_LEN + 1
 *    readable bytes).
 * Postconditions:
 *  - on TRUE both outputs are set, *@duration_s in [1, WX_TIME_DURATION_MAX_S];
 *    on FALSE both are untouched.
 * Thread affinity: any thread (pure).
 * Ownership: nothing is retained.
 *
 * Returns: TRUE iff @s is a valid interval of at most
 *   WX_TIME_INTERVAL_MAX_LEN bytes.
 */
gboolean wx_time_parse_interval(const char *s, gint64 *start_s, gint64 *duration_s);

G_END_DECLS

#endif /* WX_TIME_H */
