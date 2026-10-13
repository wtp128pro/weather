/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-icons.h - mapping from a blended weather condition to a symbolic icon of
 * the standard (freedesktop / Adwaita) icon theme. GTK-free: it only returns
 * icon names; no image is bundled.
 */
#ifndef WX_ICONS_H
#define WX_ICONS_H

#include <glib.h>

#include "wx-types.h"

G_BEGIN_DECLS

/**
 * wx_icon_name:
 * @condition: a weather condition.
 * @is_day: TRUE for daylight, FALSE for night (only clear and mostly-clear /
 *   partly-cloudy skies have a night variant).
 *
 * Total mapping of every WxCondition value (including WX_COND_UNKNOWN and
 * out-of-range values, which are treated like WX_COND_UNKNOWN) to a symbolic
 * icon name present in the Adwaita icon theme:
 *  - UNKNOWN (and anything else): "dialog-question-symbolic";
 *  - CLEAR: "weather-clear-symbolic" / night "weather-clear-night-symbolic";
 *  - MOSTLY_CLEAR, PARTLY_CLOUDY: "weather-few-clouds-symbolic" / night
 *    "weather-few-clouds-night-symbolic";
 *  - MOSTLY_CLOUDY, OVERCAST: "weather-overcast-symbolic";
 *  - FOG: "weather-fog-symbolic";
 *  - DRIZZLE, LIGHT_RAIN, SHOWERS: "weather-showers-scattered-symbolic";
 *  - RAIN, HEAVY_RAIN: "weather-showers-symbolic";
 *  - THUNDERSTORM: "weather-storm-symbolic";
 *  - SNOW and SLEET: "weather-snow-symbolic" (Adwaita has no freezing-rain
 *    icon, so sleet shares the snow glyph instead of showing a missing icon).
 *
 * Preconditions:
 *  - none (a condition outside the enum is not a programmer error here: the
 *    value may come from a cache file).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: any thread (pure).
 * Ownership: the returned string is static; never free it.
 *
 * Returns: (transfer none): a non-NULL, NUL-terminated icon name ending in
 *   "-symbolic".
 */
const char *wx_icon_name(WxCondition condition, gboolean is_day);

G_END_DECLS

#endif /* WX_ICONS_H */
