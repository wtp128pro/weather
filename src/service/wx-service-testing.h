/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-service-testing.h - TEST SUPPORT for wx-service: a replaceable refresh
 * deadline, so the deadline paths can be tested without waiting 30 seconds.
 *
 * It exists only in the test flavour of the library (wx-service-testing,
 * wx-service.c compiled with -DWX_SERVICE_TESTING), which only the test
 * executables link. The production library and the application contain no
 * hook and no writable variable; test-service-production.c exercises the real
 * WX_SERVICE_DEADLINE_MS against the production flavour.
 */
#ifndef WX_SERVICE_TESTING_H
#define WX_SERVICE_TESTING_H

#include "wx-service.h"

G_BEGIN_DECLS

/**
 * wx_service_test_set_deadline_ms:
 * @deadline_ms: deadline, in milliseconds, of every refresh started from now
 *   on; 0 restores WX_SERVICE_DEADLINE_MS.
 *
 * Replaces the overall refresh deadline.
 *
 * Preconditions:
 *  - the test is single-threaded and no refresh is being started concurrently
 *    (a refresh already in flight keeps the deadline it started with).
 * Postconditions:
 *  - refreshes started later use @deadline_ms (and report it in the message
 *    of their timeout error).
 * Thread affinity: the single thread of a test.
 * Ownership: none.
 */
void wx_service_test_set_deadline_ms(guint deadline_ms);

G_END_DECLS

#endif /* WX_SERVICE_TESTING_H */
