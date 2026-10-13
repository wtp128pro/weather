/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-sources.h - WxSources: the data-source status page of the app, the content of the main
 * menu popover of the header bar.
 *
 * Layout (a vertical box inside the popover, top to bottom; the widget names are the lookup
 * keys of the tests):
 *  - the title label "Data sources" (named "wx-sources-title");
 *  - one row (a box named "wx-sources-row") per registered provider, in
 *    wx_registry_list_providers() order. A row holds
 *      - a GtkSwitch named "wx-sources-switch" with the accessible label "Use <provider name>"
 *        (the sanitised name), active iff wx_registry_is_enabled() for the provider;
 *      - the provider name label "wx-sources-name": wx_provider_get_name() made display-safe
 *        by wx_sanitize_text() with WX_SOURCE_TEXT_MAX; if nothing is left of it the provider
 *        id is shown instead;
 *      - the status label "wx-sources-status" (see below);
 *      - the attribution label "wx-sources-attribution": wx_provider_get_attribution() made
 *        display-safe by wx_sanitize_text() with WX_SOURCE_TEXT_MAX. When
 *        wx_provider_get_attribution_url() is acceptable the label has use-markup and shows
 *        the text as a link to the URL; otherwise it is plain text (use-markup off). The label
 *        is hidden when nothing is left of the attribution text. A provider text (name,
 *        attribution, URL) that is NULL is treated like an empty one;
 *      - the licence label "wx-sources-licence", only for the provider ids of a small static
 *        table in wx-sources.c, hidden for every other id (see below).
 *  - the honesty note label "wx-sources-note";
 *  - the button "wx-sources-about" ("About Weather").
 *
 * The switch never changes the registry. A USER toggle of a switch only emits
 * "provider-toggled"; the owner decides, applies the change to the registry
 * (which emits "changed") and the switch follows the registry. When the owner refuses or
 * ignores a toggle the switch is put back to the registry's state before the toggle returns.
 * The popover follows the registry's "changed" signal: it appends the rows of providers
 * added after it was created (rows are never removed: the registry has no removal) and
 * re-synchronises every switch and status line, without emitting "provider-toggled".
 *
 * Status line of a provider (label "wx-sources-status"), first match wins:
 *  1. the provider is disabled in the registry: "Turned off" (this takes precedence over
 *     everything below, with or without a forecast);
 *  2. no forecast was set (or NULL): "No forecast loaded yet";
 *  3. the forecast has no entry (see wx_forecast_get_sources()) whose provider_id equals the
 *     provider's id, or its first such entry is skipped (WX_SRC_SKIPPED):
 *     "Not used for this place";
 *  4. the first such entry is OK: "Used for this place (N forecast models)" with N = n_members
 *     ("1 forecast model" when N is 1);
 *  5. the first such entry failed: "Could not load: <reason>" with the reason chosen by
 *     error_code: WX_ERROR_NETWORK "network error", WX_ERROR_TIMEOUT "timed out",
 *     WX_ERROR_HTTP "server error", WX_ERROR_RATE_LIMITED "rate limited", WX_ERROR_PARSE
 *     "unreadable answer", WX_ERROR_NOT_FOUND "no data", WX_ERROR_INVALID_ARG "invalid
 *     request", WX_ERROR_UNSUPPORTED "not available"; -1 and anything else: "unknown error".
 *
 * Acceptable attribution URL: it starts with "https://" followed by at least one more byte, is
 * at most WX_SOURCE_URL_MAX bytes, is valid UTF-8 and contains no forbidden character of
 * wx-text.h (control, line/paragraph separator, bidi formatting), no space character
 * (g_unichar_isspace()) and none of '<', '>' and '"'. Both the text and the URL are escaped with
 * g_markup_escape_text() before they enter the markup, so provider text can never break the
 * markup. An unacceptable URL is not repaired: the attribution is shown as plain text.
 *
 * Licence line: the table in wx-sources.c is keyed by provider id and is the only
 * provider-specific text of the module; an id that is not in it has no licence line and
 * behaves exactly like any other provider otherwise.
 *   "open-meteo": "Open-Meteo data is licensed CC BY 4.0" (the words "CC BY 4.0" link to
 *                 https://creativecommons.org/licenses/by/4.0/);
 *   "met-no":     "MET Norway data: CC BY 4.0 / NLOD" (the words "CC BY 4.0 / NLOD" link to
 *                 https://api.met.no/doc/License);
 *   "nws":        "NOAA/National Weather Service data is US government work, credited as a
 *                 courtesy" (no link).
 *
 * Honesty note (label "wx-sources-note"), exactly: "Forecasts blend several sources with
 * fixed, documented weights. These weights are rules of thumb, not statistics measured from
 * past accuracy, so no accuracy figure is claimed."
 *
 * About: activating the button emits "about-requested" and pops the popover down; showing the
 * dialog is the owner's job.
 *
 * Bounds: one row per registered provider, so at most WX_REGISTRY_MAX_PROVIDERS rows. Every
 * label wraps (word, or character for an unbreakable run) and requests at most
 * WX_SOURCES_MAX_WIDTH_CHARS characters of width, and displayed provider texts are at most
 * WX_SOURCE_TEXT_MAX bytes, so a hostile provider cannot make the popover grow without bound.
 *
 * Keyboard: the switches, the About button and the attribution and licence labels that hold a
 * link are focusable (gtk_widget_get_focusable()), so they take part in the focus chain.
 *
 * Lifetime: the popover holds a reference on the registry and is connected to its "changed"
 * signal from wx_sources_new() until dispose. At dispose (g_object_run_dispose() or the last
 * unref) it disconnects, releases the registry and forgets its rows and forecast data; from then
 * on every method is a no-op that touches no registry and a switch toggle emits nothing. No
 * timer, no I/O, no thread: main thread only. The one deferred piece of work is a single idle
 * callback, scheduled when a user toggle did not stick (the switch snapped back), which
 * republishes the switches' accessible "checked" state (GtkSwitch publishes the state it was
 * asked for after the handlers returned); it is removed at dispose.
 *
 * CSS: the popover has the style class "wx-sources"; labels use "wx-sources-title",
 * "wx-sources-name", "wx-sources-status", "wx-sources-attribution", "wx-sources-licence" and
 * "wx-sources-note" (the same as their widget names) plus the stock "dim-label" on status and
 * licence labels and "flat" on the About button; the rows use "wx-sources-row".
 */
#ifndef WX_SOURCES_H
#define WX_SOURCES_H

#include <gtk/gtk.h>

#include "wx-registry.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** The max-width-chars of every wrapping label of the popover. */
#define WX_SOURCES_MAX_WIDTH_CHARS 40

#define WX_TYPE_SOURCES (wx_sources_get_type())
G_DECLARE_FINAL_TYPE(WxSources, wx_sources, WX, SOURCES, GtkPopover)

/**
 * WxSources::provider-toggled:
 * @self: the popover.
 * @id: the provider id (const char *): a copy made for this emission, valid while the handlers
 *   run (copy it to keep it).
 * @enabled: (gboolean) the state the user asked for: the switch position after the toggle.
 *
 * Emitted synchronously, once per USER toggle of a provider switch (never for the updates the
 * popover makes itself when the registry changes), after the switch has moved and before the
 * toggle returns. The popover does not change the registry: a handler applies the request with
 * wx_registry_set_enabled(); whatever the registry says afterwards is what the switch shows
 * (a request that was not applied snaps back). A handler may call any registry function and may
 * dispose the popover (the toggle then touches nothing else; the owner must hold its own
 * reference on the toggled switch for that, because GtkSwitch uses it after the handlers return).
 */

/**
 * WxSources::about-requested:
 * @self: the popover.
 *
 * Emitted when the user activates the "About Weather" button, after the popover has been popped
 * down. The owner shows the About dialog.
 */

/**
 * wx_sources_new:
 * @registry: (not nullable): the registry whose providers are listed.
 *
 * Creates the popover (not shown, floating: hand it to gtk_menu_button_set_popover(), which
 * takes it over). Needs an initialised GTK with a display; main thread only.
 *
 * Preconditions:
 *  - GTK is initialised with a display; the call is made on the main thread.
 *  - @registry satisfies WX_IS_REGISTRY() (violation, including NULL: critical, NULL).
 * Postconditions:
 *  - on success the popover holds its own reference on @registry, has one row per provider of
 *    wx_registry_list_providers() in that order (none for an empty registry), each switch
 *    matching wx_registry_is_enabled(), each status line "Turned off" or "No forecast loaded
 *    yet", and follows the registry's "changed" signal.
 *  - on failure a critical is logged, nothing is allocated and NULL is returned.
 * Thread affinity: main thread only.
 * Ownership: @registry is shared (the popover takes its own reference, the caller keeps its
 *   own); the returned popover is floating (the caller sinks or hands it on).
 *
 * Returns: (transfer floating): the new popover, or NULL (with a critical) if @registry is NULL
 *   or of the wrong type.
 */
GtkWidget *wx_sources_new(WxRegistry *registry);

/**
 * wx_sources_set_forecast:
 * @self: a WxSources.
 * @forecast: (nullable): the forecast of the place that is selected, or NULL when there is none.
 *
 * Updates every provider's status line from the source statuses of @forecast (rules in the
 * file comment); NULL means "no forecast", which gives "No forecast loaded yet" (or "Turned
 * off"). The sources are read for this call only: what is displayed is copied, no reference
 * to @forecast is kept, so the caller may drop it at once. A later call replaces the earlier
 * forecast entirely.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_SOURCES() (violation: critical, nothing changes).
 *  - @forecast is NULL or a valid WxForecast.
 * Postconditions:
 *  - the status lines follow @forecast and the registry's current enabled flags; the status
 *    lines of later registry changes are computed from the same (copied) data.
 *  - after dispose nothing changes (no critical).
 * Thread affinity: main thread only.
 * Ownership: @forecast is borrowed for the call; the caller keeps its reference.
 */
void wx_sources_set_forecast(WxSources *self, const WxForecast *forecast);

G_END_DECLS

#endif /* WX_SOURCES_H */
