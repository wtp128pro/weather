/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-widget-util.h - private helpers shared by the three widget
 * implementations of this module (not part of any public API): the equality
 * of the compare-before-set setters and the held place zone.
 */
#ifndef WX_WIDGET_UTIL_H
#define WX_WIDGET_UTIL_H

#include <glib.h>
#include <math.h>

#include "wx-format.h"
#include "wx-types.h"

/**
 * wx_same_value:
 * @a: first value.
 * @b: second value.
 *
 * Equality for the compare-before-set setters, where an unknown value is NAN.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: none.
 *
 * Returns: TRUE iff both are NAN or both compare equal.
 */
static inline gboolean
wx_same_value(double a, double b)
{
  return (isnan(a) && isnan(b)) || a == b;
}

/**
 * WxHeldZone: the place time zone a widget keeps between set_forecast() calls,
 * so that no draw or unchanged call ever has to look a zone up. A failed
 * lookup leaves a UTC fallback with resolved == FALSE, which the next update
 * tries again (see wx_held_zone_update()).
 */
typedef struct {
  char name[WX_PLACE_TIMEZONE_MAX + 1]; /**< the name the zone below stands for, "" at the start */
  GTimeZone *zone;                      /**< owned; never NULL between init and clear */
  gboolean resolved;                    /**< FALSE: @zone is the fallback of a failed lookup of @name */
} WxHeldZone;

/**
 * wx_held_zone_init:
 * @held: (out): the holder to initialise.
 *
 * Preconditions:
 *  - @held is non-NULL, not yet initialised (or cleared).
 * Postconditions:
 *  - the zone is UTC for the name "" and resolved; no lookup is made.
 * Thread affinity: main thread only.
 * Ownership: the zone is owned by @held.
 */
void wx_held_zone_init(WxHeldZone *held);

/**
 * wx_held_zone_update:
 * @held: an initialised holder.
 * @tz: the place's zone name (NUL-terminated, at most WX_PLACE_TIMEZONE_MAX
 *   bytes; "" for none).
 *
 * Brings the held zone up to date with @tz. When the name differs from the
 * held one it is resolved (a new name reads its zoneinfo file once) and the
 * zone replaced. When the name is the same but the held zone is only the
 * fallback of a failed lookup, the lookup is retried: if it succeeds the
 * zone is replaced; if it fails again nothing changes (a retry within 30
 * seconds of the last failure makes no file access, see wx-format.h). A name
 * whose zone is resolved is never looked up again.
 *
 * Preconditions:
 *  - @held is initialised; @tz is non-NULL.
 * Postconditions:
 *  - held->name equals @tz and held->resolved tells whether the zone is real.
 * Thread affinity: main thread only (the setters).
 * Ownership: the zone stays owned by @held.
 *
 * Returns: TRUE iff the held zone or name changed, so that everything that
 *   depends on the zone (labels, day ends) must be rebuilt.
 */
gboolean wx_held_zone_update(WxHeldZone *held, const char *tz);

/**
 * wx_held_zone_clear:
 * @held: an initialised holder.
 *
 * Preconditions:
 *  - none (a cleared holder may be cleared again).
 * Postconditions:
 *  - the zone is released and NULL; wx_held_zone_update() must not be called
 *    again.
 * Thread affinity: main thread only.
 * Ownership: releases the zone.
 */
void wx_held_zone_clear(WxHeldZone *held);

#endif /* WX_WIDGET_UTIL_H */
