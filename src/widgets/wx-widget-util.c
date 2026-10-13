/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-widget-util.c - the held place zone of the widgets. See wx-widget-util.h. */
#include "wx-widget-util.h"

#include <string.h>

/* Documented in wx-widget-util.h. */
void
wx_held_zone_init(WxHeldZone *held)
{
  held->name[0] = '\0';
  held->zone = wx_format_zone_new("", NULL);
  held->resolved = TRUE;
}

/* Documented in wx-widget-util.h. */
gboolean
wx_held_zone_update(WxHeldZone *held, const char *tz)
{
  gboolean same_name = strcmp(held->name, tz) == 0;
  if (same_name && held->resolved)
    return FALSE;
  gboolean resolved;
  GTimeZone *zone = wx_format_zone_new(tz, &resolved);
  if (same_name && !resolved) { /* the retry failed again: keep the fallback we have */
    g_time_zone_unref(zone);
    return FALSE;
  }
  g_clear_pointer(&held->zone, g_time_zone_unref);
  held->zone = zone;
  held->resolved = resolved;
  g_strlcpy(held->name, tz, sizeof held->name);
  return TRUE;
}

/* Documented in wx-widget-util.h. */
void
wx_held_zone_clear(WxHeldZone *held)
{
  g_clear_pointer(&held->zone, g_time_zone_unref);
}
