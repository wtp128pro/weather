/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-format-testing.h - TEST SUPPORT for wx-format: a counter of zone loads and
 * hooks that replace the zone loader and the clock.
 *
 * These functions exist only in the test flavour of the library
 * (wx-format-testing, wx-format.c compiled with -DWX_FORMAT_TESTING), which
 * only the test executables link. The production library and the application
 * contain none of them, no counter and no writable function pointer.
 */
#ifndef WX_FORMAT_TESTING_H
#define WX_FORMAT_TESTING_H

#include <glib.h>

#include "wx-format.h"

G_BEGIN_DECLS

/** Replacement for g_time_zone_new_identifier(); returns a new reference or NULL. */
typedef GTimeZone *(*WxZoneLoader)(const char *name);
/** Replacement for g_get_monotonic_time() (microseconds). */
typedef gint64 (*WxZoneClock)(void);

/**
 * wx_format_zone_loads:
 *
 * Lets a test prove that formatting with an already loaded zone reads no
 * zoneinfo file.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (atomic counter).
 * Ownership: none.
 *
 * Returns: how many times a zone lookup (the loader, by default
 *   g_time_zone_new_identifier()) has been made by wx-format so far, failed
 *   ones included; "UTC", NULL, "" and ill-shaped names never count (they do
 *   no lookup), neither does a cache hit nor a name remembered as failed.
 */
guint wx_format_zone_loads(void);

/**
 * wx_format_test_set_hooks:
 * @loader: (nullable): zone loader to use from now on, or NULL for
 *   g_time_zone_new_identifier().
 * @clock: (nullable): monotonic clock used for the 30-second failure memory,
 *   or NULL for g_get_monotonic_time().
 *
 * Simulates a failing or slow zone load and the passing of time, and empties
 * the zone cache and the failure memory.
 *
 * Preconditions:
 *  - no other thread is formatting while the hooks change (the hook pointers
 *    are read under the cache mutex, but a load in progress keeps the loader
 *    it started with).
 * Postconditions:
 *  - the cache is empty and the hooks are as given.
 * Thread affinity: the single thread of a test.
 * Ownership: nothing is retained.
 */
void wx_format_test_set_hooks(WxZoneLoader loader, WxZoneClock clock);

G_END_DECLS

#endif /* WX_FORMAT_TESTING_H */
