/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-fake-provider.h - TEST-ONLY scripted implementations of WxProvider and
 * WxGeocoder, shared by the tests of every module that consumes the
 * interfaces (registry, service, ...). They live in the static library
 * `wx-net-testing` (meson dependency `net_testing_dep`), which is never
 * linked into the application, and they never touch the network.
 *
 * Both fakes honour the interface contract of wx-provider.h: the callback
 * never runs before the *_async call has returned, a cancellable that is
 * cancelled before or during the (optional) delay completes the operation
 * with G_IO_ERROR_CANCELLED, a place the fake provider does not cover is
 * WX_ERROR_UNSUPPORTED, a place that violates the wx_place_new() rules is
 * WX_ERROR_INVALID_ARG, and each operation keeps its fake alive until it
 * completes. They are main-thread objects (not thread-safe).
 */
#ifndef WX_FAKE_PROVIDER_H
#define WX_FAKE_PROVIDER_H

#include "wx-provider.h"

G_BEGIN_DECLS

#define WX_TYPE_FAKE_PROVIDER (wx_fake_provider_get_type())
G_DECLARE_FINAL_TYPE(WxFakeProvider, wx_fake_provider, WX, FAKE_PROVIDER, GObject)

/**
 * wx_fake_provider_new:
 * @id: the provider id to report. NOT validated here (the registry tests
 *   need invalid ids); wx_provider_get_id() returns it verbatim.
 *
 * Creates a provider named "Fake <id>" with the attribution "Fake data (<id>)"
 * and the attribution URL "https://example.invalid/", covering every place,
 * answering immediately with an empty WxSourceResult.
 *
 * Preconditions:
 *  - @id is non-NULL and NUL-terminated (violation: critical, NULL).
 * Postconditions:
 *  - the provider has no member, no scripted failure, no delay and a fetch
 *    count of 0.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference; @id is copied.
 *
 * Returns: (transfer full): the fake provider.
 */
WxFakeProvider *wx_fake_provider_new(const char *id);

/**
 * wx_fake_provider_set_covers:
 * @self: a WxFakeProvider.
 * @covers_all: TRUE to cover every place, FALSE to cover none.
 *
 * Chooses whether the provider covers every place or none.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_PROVIDER() (violation: critical, nothing
 *    changes).
 * Postconditions:
 *  - wx_provider_covers() answers @covers_all for every place from now on.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_fake_provider_set_covers(WxFakeProvider *self, gboolean covers_all);

/**
 * wx_fake_provider_add_member:
 * @self: a WxFakeProvider.
 * @member: a member to include in every successful fetch result.
 *
 * Adds a member that every successful fetch result will contain.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_PROVIDER(); @member is non-NULL (violation:
 *    critical, nothing changes).
 * Postconditions:
 *  - the provider holds its own reference to @member (so @member is shared
 *    and immutable from now on); every later successful fetch returns the
 *    members in the order they were added, each with its own reference.
 * Thread affinity: main thread only.
 * Ownership: a reference is added; the caller keeps its own.
 */
void wx_fake_provider_add_member(WxFakeProvider *self, WxMember *member);

/**
 * wx_fake_provider_fail_with:
 * @self: a WxFakeProvider.
 * @code: a WxError value to fail with, or -1 to succeed again.
 *
 * Scripts the failure that later fetches report, or turns it off.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_PROVIDER() and @code is -1 or a WxError
 *    (violation: critical, nothing changes).
 * Postconditions:
 *  - later fetches of covered, valid places fail with WX_ERROR/@code (after
 *    the delay), or succeed when @code is -1.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_fake_provider_fail_with(WxFakeProvider *self, int code);

/**
 * wx_fake_provider_set_delay_ms:
 * @self: a WxFakeProvider.
 * @delay_ms: time between the call and the completion; 0 completes at once.
 *
 * Sets how long a fetch takes to complete.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_PROVIDER() (violation: critical, nothing
 *    changes).
 * Postconditions:
 *  - later fetches complete after @delay_ms (a cancellation ends the wait
 *    earlier); a very large delay makes the provider "hang" until
 *    cancelled.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_fake_provider_set_delay_ms(WxFakeProvider *self, guint delay_ms);

/**
 * wx_fake_provider_get_fetch_count:
 * @self: a WxFakeProvider.
 *
 * Counts the fetches that reached the provider.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_PROVIDER() (violation: critical, 0).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: how many times wx_provider_fetch_async() reached this provider
 *   (every call, whatever its outcome).
 */
guint wx_fake_provider_get_fetch_count(WxFakeProvider *self);

#define WX_TYPE_FAKE_GEOCODER (wx_fake_geocoder_get_type())
G_DECLARE_FINAL_TYPE(WxFakeGeocoder, wx_fake_geocoder, WX, FAKE_GEOCODER, GObject)

/**
 * wx_fake_geocoder_new:
 *
 * Creates a geocoder that answers every search immediately with the places
 * added by wx_fake_geocoder_add_hit() (initially none).
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no hit, no scripted failure, no delay, search count 0.
 * Thread affinity: main thread only.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the fake geocoder.
 */
WxFakeGeocoder *wx_fake_geocoder_new(void);

/**
 * wx_fake_geocoder_add_hit:
 * @self: a WxFakeGeocoder.
 * @place: a place to include in every successful search result.
 *
 * Adds a place to every successful search result.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_GEOCODER(); @place is non-NULL and satisfies
 *    the wx_place_new() rules (violation: critical, nothing changes).
 * Postconditions:
 *  - a copy of @place is returned by every later successful search, after
 *    the earlier hits; at most WX_GEOCODER_MAX_HITS are returned (extra hits
 *    are kept but cut from the result).
 * Thread affinity: main thread only.
 * Ownership: @place is copied; the caller keeps it.
 */
void wx_fake_geocoder_add_hit(WxFakeGeocoder *self, const WxPlace *place);

/**
 * wx_fake_geocoder_fail_with:
 * @self: a WxFakeGeocoder.
 * @code: a WxError value to fail with, or -1 to succeed again.
 *
 * Scripts the failure that later searches report, or turns it off.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_GEOCODER() and @code is -1 or a WxError
 *    (violation: critical, nothing changes).
 * Postconditions:
 *  - later searches fail with WX_ERROR/@code (after the delay), or succeed
 *    when @code is -1.
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_fake_geocoder_fail_with(WxFakeGeocoder *self, int code);

/**
 * wx_fake_geocoder_set_delay_ms:
 * @self: a WxFakeGeocoder.
 * @delay_ms: time between the call and the completion; 0 completes at once.
 *
 * Sets how long a search takes to complete.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_GEOCODER() (violation: critical, nothing
 *    changes).
 * Postconditions:
 *  - later searches complete after @delay_ms (a cancellation ends the wait
 *    earlier).
 * Thread affinity: main thread only.
 * Ownership: nothing is retained.
 */
void wx_fake_geocoder_set_delay_ms(WxFakeGeocoder *self, guint delay_ms);

/**
 * wx_fake_geocoder_get_search_count:
 * @self: a WxFakeGeocoder.
 *
 * Counts the searches that reached the geocoder.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_FAKE_GEOCODER() (violation: critical, 0).
 * Postconditions:
 *  - nothing is modified.
 * Thread affinity: main thread only.
 * Ownership: none.
 *
 * Returns: how many times wx_geocoder_search_async() reached this geocoder.
 */
guint wx_fake_geocoder_get_search_count(WxFakeGeocoder *self);

G_END_DECLS

#endif /* WX_FAKE_PROVIDER_H */
