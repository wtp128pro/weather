/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-window.h - WxWindow: the main window.
 *
 * Layout: a header bar with an "Add" button (icon "+", Ctrl+N), the title, a
 * "Refresh" button (F5 / Ctrl+R), the units toggle (shows the current unit,
 * "°F" or "°C"; its tooltip names the other one: "Switch to Celsius" /
 * "Switch to Fahrenheit"; Ctrl+U) and the main menu button whose popover is
 * the sources page (WxSources: one switch per registered provider, status,
 * attribution links, the honest weights note, and "About Weather"). Below it
 * a stack of two pages:
 *
 *  - "empty" (no saved place, the first-run state): "No places yet", a hint,
 *    one button per suggested Florida city (Miami, Orlando, Tampa,
 *    Jacksonville, Key West; one click saves the city and selects it) and a
 *    suggested-action button "Add a city" (opens the picker).
 *  - "main": a GtkPaned whose start side is the place list and whose end side
 *    is the WxDetail pane.
 *
 * Place list: a GtkListView (GTK creates the row widgets) over WxApp's item
 * model, one WxRow per item, with a single selection (the
 * persisted selection, else the first row, is selected automatically, and
 * after a removal a neighbour is). Row actions (Remove, Move up, Move down)
 * and drag-and-drop reordering edit the WxPlaces; the window never saves
 * them: WxApp reacts to the places' "changed" signal (updates the list, the
 * scheduler and the debounced save), so edits are shown at once whoever made
 * them. A drop whose payload is not the key of a saved place is ignored.
 *
 * Detail pane: shows the selected item; the selection is forwarded to
 * wx_app_select(). The sources page shows the forecast of the selected place.
 *
 * "Add" opens one WxPicker (transient for the window, destroyed with it, not
 * modal); while it is open, "Add" presents it again instead of opening
 * another. A place added by the picker is selected.
 *
 * Refresh: the button and the action are enabled while a place is selected, it is not
 * loading and the network is available; they call wx_app_refresh_selected(), which drops a
 * refresh that comes too soon after the place's last request (the button stays enabled then).
 *
 * Actions of the window (the "win." group): "add", "refresh", "toggle-units".
 * Widget names (used by the tests): "wx-add-button", "wx-refresh-button",
 * "wx-units-button", "wx-menu-button", "wx-main-stack", "wx-place-list",
 * "wx-detail", "wx-empty-title", "wx-empty-hint", "wx-suggestion" (one per
 * suggested city), "wx-empty-add".
 *
 * Visibility for the refresh policy: the window reports to WxApp whether it
 * is mapped and neither minimised nor suspended (GdkToplevel state), and
 * reports when it becomes the active window.
 *
 * Threading: main thread only. The window must be created after the
 * application's start-up load has finished (WxApp does that).
 *
 * Teardown: when the window is disposed (closed, or destroyed by the
 * application at shutdown) it first disconnects every handler it has on the
 * selection, the item model, the application, the sources page, the selected item and the
 * surface, so no signal of those objects emitted while the toolkit takes the
 * widgets apart reaches the window or leads to wx_app_select(). (It connects
 * nothing on the detail pane.) Its own "map", "unmap" and "notify::is-active" handlers
 * stay: they only report visibility and focus, which WxApp ignores once it is shutting down.
 */
#ifndef WX_WINDOW_H
#define WX_WINDOW_H

#include <gtk/gtk.h>

#include "wx-app.h"

G_BEGIN_DECLS

/*
 * G_DECLARE_FINAL_TYPE() below declares the types WxWindow and WxWindowClass,
 * wx_window_get_type(), the inline cast function WX_WINDOW() and the inline type-check function
 * WX_IS_WINDOW(), and the g_autoptr() cleanup for WxWindow. WX_TYPE_WINDOW is defined here. The
 * type itself is defined by G_DEFINE_FINAL_TYPE() in wx-window.c.
 */
#define WX_TYPE_WINDOW (wx_window_get_type())
G_DECLARE_FINAL_TYPE(WxWindow, wx_window, WX, WINDOW, GtkApplicationWindow)

/**
 * wx_window_new:
 * @app: (not nullable): the application (must satisfy WX_IS_APP()); the window is added to it.
 *
 * Builds the window (header bar, pages, list, detail pane, sources page) and adds it to @app.
 *
 * Preconditions:
 *  - @app satisfies WX_IS_APP() (else: critical, NULL returned, nothing is created); GTK is
 *    initialised; main thread.
 *  - @app outlives the window: the window keeps a borrowed pointer to it (no reference) and uses
 *    it until it is finalized.
 *  - the application's start-up load has finished (see the file comment).
 * Postconditions:
 *  - the window is registered with @app (gtk_window_set_application()) and shows the
 *    application's current items; if there is at least one, the persisted selection (else the
 *    first) is selected and @app was told through wx_app_select(); it is not shown yet.
 * Thread affinity: main thread only.
 * Ownership: @app is borrowed (not referenced); the returned window is owned by the
 *   application's window list until it is closed or destroyed.
 *
 * Returns: (transfer none): the new window, not shown yet; call gtk_window_present(). NULL (with
 *   a critical) if @app is not a WxApp.
 */
GtkWidget *wx_window_new(WxApp *app);

G_END_DECLS

#endif /* WX_WINDOW_H */
