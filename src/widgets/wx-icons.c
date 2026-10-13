/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-icons.c - condition to icon-name mapping. See wx-icons.h for the contract. */
#include "wx-icons.h"

/* Documented in wx-icons.h. */
const char *
wx_icon_name(WxCondition condition, gboolean is_day)
{
  switch (condition) {
  case WX_COND_CLEAR:
    return is_day ? "weather-clear-symbolic" : "weather-clear-night-symbolic";
  case WX_COND_MOSTLY_CLEAR:
  case WX_COND_PARTLY_CLOUDY:
    return is_day ? "weather-few-clouds-symbolic" : "weather-few-clouds-night-symbolic";
  case WX_COND_MOSTLY_CLOUDY:
  case WX_COND_OVERCAST:
    return "weather-overcast-symbolic";
  case WX_COND_FOG:
    return "weather-fog-symbolic";
  case WX_COND_DRIZZLE:
  case WX_COND_LIGHT_RAIN:
  case WX_COND_SHOWERS:
    return "weather-showers-scattered-symbolic";
  case WX_COND_RAIN:
  case WX_COND_HEAVY_RAIN:
    return "weather-showers-symbolic";
  case WX_COND_THUNDERSTORM:
    return "weather-storm-symbolic";
  case WX_COND_SNOW:
  case WX_COND_SLEET:
    return "weather-snow-symbolic";
  case WX_COND_UNKNOWN:
  case WX_COND_COUNT:
  default:
    return "dialog-question-symbolic";
  }
}
