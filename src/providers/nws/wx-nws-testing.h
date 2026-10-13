/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-nws-testing.h - TEST SUPPORT for wx-nws: a replaceable monotonic clock.
 *
 * Exists only in the test flavour of the library (wx-nws-testing, wx-nws.c compiled with
 * -DWX_NWS_TESTING), which only the test executable links. The production library and the
 * application contain no hook and no writable function pointer. The 7-day grid cache lifetime
 * and the 5-second 429 back-off can only be tested by moving the clock.
 */
#ifndef WX_NWS_TESTING_H
#define WX_NWS_TESTING_H

#include "wx-nws.h"

G_BEGIN_DECLS

/** Replacement for g_get_monotonic_time() (microseconds). */
typedef gint64 (*WxNwsClock)(void);

/**
 * wx_nws_test_set_clock:
 * @clock: (nullable): clock used by the caches and the 429 back-off of every WxNws from now on,
 *   or NULL for g_get_monotonic_time().
 *
 * Preconditions:
 *  - the test is single-threaded.
 * Postconditions:
 *  - later time reads of wx-nws use @clock.
 * Thread affinity: the single thread of a test.
 * Ownership: nothing is retained.
 */
void wx_nws_test_set_clock(WxNwsClock clock);

G_END_DECLS

#endif /* WX_NWS_TESTING_H */
