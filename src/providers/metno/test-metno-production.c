/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * The production flavour of WxMetno (the library the application links, compiled without the
 * test hook): construction, identity, registration and the pure functions. The network behaviour
 * is covered by test-metno, which links the test flavour of the same source.
 *
 * Usage: test-metno-production FIXTURE_DIR [GLib test options]
 */
#include <gio/gio.h>
#include <glib.h>
#include <string.h>

#include "wx-metno.h"
#include "wx-registry.h"
#include "wx-types.h"

static const char *fixture_dir;

static void
test_production_provider(void)
{
  g_autoptr(WxMetno) metno = wx_metno_new();
  g_assert_nonnull(metno);
  WxProvider *provider = WX_PROVIDER(metno);
  g_assert_cmpstr(wx_provider_get_id(provider), ==, "met-no");
  g_assert_cmpstr(wx_provider_get_name(provider), ==, "MET Norway");
  g_assert_cmpstr(wx_provider_get_attribution(provider), ==, "Data from MET Norway");
  g_assert_cmpstr(wx_provider_get_attribution_url(provider), ==, "https://api.met.no/");
  g_autoptr(GError) error = NULL;
  g_autoptr(WxPlace) miami = wx_place_new("Miami", "Florida", "United States", "US", 25.7617, -80.1918,
                                          "America/New_York", &error);
  g_assert_no_error(error);
  g_assert_true(wx_provider_covers(provider, miami));
  g_autoptr(WxRegistry) registry = wx_registry_new();
  g_assert_true(wx_registry_add_provider(registry, provider, &error));
  g_assert_no_error(error);
  g_autoptr(GPtrArray) covering = wx_registry_list_covering(registry, miami);
  g_assert_cmpuint(covering->len, ==, 1);
  /* The production origin is https and fixed: another origin is only reachable through new_custom. */
  g_assert_null(wx_metno_new_custom("http://api.met.no", 1000, 1, &error));
  g_assert_error(error, WX_ERROR, WX_ERROR_INVALID_ARG);
}

static void
test_production_pure(void)
{
  g_autofree char *path = wx_metno_forecast_path(25.7617, -80.1918);
  g_assert_cmpstr(path, ==, "/weatherapi/locationforecast/2.0/complete?lat=25.7617&lon=-80.1918");
  g_autofree char *file = g_build_filename(fixture_dir, "complete_london.json", NULL);
  g_autofree char *text = NULL;
  gsize len;
  g_autoptr(GError) error = NULL;
  g_assert_true(g_file_get_contents(file, &text, &len, &error));
  g_autoptr(WxMember) member = wx_metno_parse_forecast((const guint8 *)text, len, 1791831600 + 100, &error);
  g_assert_no_error(error);
  g_assert_nonnull(member);
  g_assert_cmpuint(member->n_hours, ==, 92);
  g_assert_cmpint(wx_member_get_fetched_s(member), ==, 1791831700);
}

int
main(int argc, char **argv)
{
  g_test_init(&argc, &argv, NULL);
  if (argc < 2) {
    g_printerr("usage: %s FIXTURE_DIR [GLib test options]\n", argv[0]);
    return 1;
  }
  fixture_dir = argv[1];
  g_setenv("GIO_USE_PROXY_RESOLVER", "dummy", TRUE);
  g_test_add_func("/metno-production/provider", test_production_provider);
  g_test_add_func("/metno-production/pure", test_production_pure);
  return g_test_run();
}
