/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-metno-testing.h - TEST SUPPORT for wx-metno: a hook that replaces the
 * clock, so tests can pass the 10-minute floor, Expires times and the
 * 60-second throttle without waiting.
 *
 * The hook exists only in the test flavour of the library (wx-metno-testing,
 * wx-metno.c compiled with -DWX_METNO_TESTING), which only the test
 * executables link. The production library and the application contain no
 * writable function pointer.
 */
#ifndef WX_METNO_TESTING_H
#define WX_METNO_TESTING_H

#include <glib.h>

#include "wx-metno.h"

G_BEGIN_DECLS

/** Replacement for the system clock: UTC unix seconds. */
typedef gint64 (*WxMetnoClock)(void);

/**
 * wx_metno_test_set_clock:
 * @source: (nullable): clock used from now on by every WxMetno, or NULL for
 *   the system clock (g_get_real_time()).
 *
 * Replaces the time source of the cache floor, Expires handling and throttle.
 * Whatever the source returns is clamped to [0, G_MAXINT64 / 4].
 *
 * Preconditions:
 *  - called from the main thread while no WxMetno operation is being handled.
 * Postconditions:
 *  - later time readings come from @source.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained but the function pointer.
 */
void wx_metno_test_set_clock(WxMetnoClock source);

G_END_DECLS

#endif /* WX_METNO_TESTING_H */
