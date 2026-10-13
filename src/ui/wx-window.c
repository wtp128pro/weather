/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/* wx-window.c - WxWindow: place list, detail pane, sources page, picker launcher. */
#include "wx-window.h"

#include "wx-detail.h"
#include "wx-picker.h"
#include "wx-row.h"
#include "wx-sources.h"

#define LIST_MIN_WIDTH 340
#define DETAIL_MIN_WIDTH 480

struct _WxWindow {
  GtkApplicationWindow parent_instance;

  WxApp *app; /* borrowed: the application outlives all its windows; never unreffed */
  GtkWidget *stack; /* "main" | "empty" */
  GtkWidget *detail;
  GtkWidget *sources;
  GtkWidget *units_button;
  GtkWidget *picker; /* weak pointer (g_object_add_weak_pointer): NULL once disposed */
  GtkSingleSelection *selection;
  WxRowItem *current;        /* strong: the selected item, NULL for none */
  gulong current_changed_id; /* its "changed" handler */
  WxForecast *sources_forecast; /* strong: what the sources page was last given */
  GPtrArray *suggestions;    /* WxPlace*, the first-run suggestions of the empty page */

  gboolean mapped;
  GdkToplevelState toplevel_state;
  gboolean reported_visible;
  GdkSurface *state_surface; /* the surface whose "notify::state" we listen to (borrowed) */
  gulong state_id;           /* that handler */
};

/*
 * G_DEFINE_FINAL_TYPE() below defines wx_window_get_type(), the static wx_window_parent_class
 * pointer and the static class initialiser that runs wx_window_class_init() once;
 * wx_window_init() is registered as the instance initialiser. The instance struct is _WxWindow
 * (WxWindow).
 */
G_DEFINE_FINAL_TYPE(WxWindow, wx_window, GTK_TYPE_APPLICATION_WINDOW)

/**
 * window_app:
 * @self: (not nullable): the window.
 *
 * Accessor for the borrowed application pointer.
 *
 * Preconditions:
 *  - @self is a WxWindow on which build_window() has run (it sets the pointer first); every caller
 *    is a handler that is connected inside or after build_window(). The application outlives its
 *    windows, so the pointer stays valid until the window is finalized, including while the window
 *    is being disposed.
 * Postconditions:
 *  - nothing is changed.
 * Thread affinity: main thread only.
 * Ownership: the application is not owned by the window; no reference is added.
 *
 * Returns: (transfer none): the application the window was built for.
 */
static WxApp *
window_app(WxWindow *self)
{
  return self->app;
}

/* ------------------------------------------------------------------------ */
/* Visibility and focus                                                     */
/* ------------------------------------------------------------------------ */

/**
 * report_visibility:
 * @self: (not nullable): the window.
 *
 * Reports to the application whether the window is mapped and neither minimised nor suspended;
 * only when the value differs from the last one reported.
 *
 * Preconditions:
 *  - @self is a built WxWindow (see window_app()).
 * Postconditions:
 *  - self->reported_visible equals the current visibility; wx_app_set_window_visible() was called
 *    iff it changed.
 * Thread affinity: main thread only.
 * Ownership: none (no pointers besides @self).
 */
static void
report_visibility(WxWindow *self)
{
  gboolean visible = self->mapped && (self->toplevel_state & (GDK_TOPLEVEL_STATE_MINIMIZED |
                                                              GDK_TOPLEVEL_STATE_SUSPENDED)) == 0;
  if (visible == self->reported_visible)
    return;
  self->reported_visible = visible;
  wx_app_set_window_visible(window_app(self), visible);
}

/**
 * read_toplevel_state:
 * @self: (not nullable): the window.
 *
 * Reads the GdkToplevel state of the window's surface (0 when it has no surface or the surface is
 * not a toplevel) and reports the resulting visibility.
 *
 * Preconditions:
 *  - @self is a built WxWindow.
 * Postconditions:
 *  - self->toplevel_state is the current state; report_visibility() ran.
 * Thread affinity: main thread only.
 * Ownership: the surface is borrowed from the widget for the call.
 */
static void
read_toplevel_state(WxWindow *self)
{
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(self));
  self->toplevel_state = (surface != NULL && GDK_IS_TOPLEVEL(surface))
                             ? gdk_toplevel_get_state(GDK_TOPLEVEL(surface))
                             : 0;
  report_visibility(self);
}

/**
 * on_surface_state:
 * @self: (not nullable): the window (the receiver of the swapped "notify::state" connection made
 *   by on_realize(); the GParamSpec and the surface the signal also passes are not used).
 *
 * Handler for state changes of the window's surface.
 *
 * Preconditions:
 *  - @self is a built WxWindow that is not finalized: the handler is connected with
 *    g_signal_connect_object(), and dispose disconnects it by data.
 * Postconditions:
 *  - the visibility was re-read and reported (read_toplevel_state()).
 * Thread affinity: main thread only.
 * Ownership: none (no pointers besides @self).
 */
static void
on_surface_state(WxWindow *self)
{
  read_toplevel_state(self);
}

/**
 * on_realize:
 * @widget: the window that was realized.
 * @user_data: unused (NULL).
 *
 * "realize" handler: starts listening to the state of the new surface. Each realization creates a
 * new surface, so the connection is made once per surface.
 *
 * Preconditions:
 *  - @widget is a WxWindow (the handler is only connected to the window itself) that has just been
 *    realized, so it has a surface and no surface handler of this file (the previous realization
 *    was undone by on_unrealize()).
 * Postconditions:
 *  - "notify::state" of the surface is connected to on_surface_state() with the window as receiver;
 *    state_surface and state_id identify the connection until on_unrealize() or
 *    wx_window_dispose() removes it.
 * Thread affinity: main thread only.
 * Ownership: @widget is borrowed; the surface is borrowed (the toolkit owns it).
 */
static void
on_realize(GtkWidget *widget, gpointer user_data)
{
  (void)user_data;
  WxWindow *self = WX_WINDOW(widget);
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(self));
  /* The class handler of "realize" runs first and creates the surface. */
  g_return_if_fail(surface != NULL);
  self->state_surface = surface;
  self->state_id =
      g_signal_connect_swapped(surface, "notify::state", G_CALLBACK(on_surface_state), self);
}

/**
 * on_unrealize:
 * @widget: the window that is being unrealized.
 * @user_data: unused (NULL).
 *
 * "unrealize" handler (runs before the toolkit destroys the surface): removes the surface handler
 * of on_realize().
 *
 * Preconditions:
 *  - @widget is a WxWindow.
 * Postconditions:
 *  - state_surface is NULL and the handler is disconnected (when there was one).
 * Thread affinity: main thread only.
 * Ownership: @widget is borrowed.
 */
static void
on_unrealize(GtkWidget *widget, gpointer user_data)
{
  (void)user_data;
  WxWindow *self = WX_WINDOW(widget);
  if (self->state_surface == NULL)
    return;
  g_signal_handler_disconnect(self->state_surface, self->state_id);
  self->state_surface = NULL;
  self->state_id = 0;
}

/**
 * on_map:
 * @widget: the window that was mapped.
 * @user_data: unused (NULL).
 *
 * "map" handler: marks the window mapped and reports the visibility.
 *
 * Preconditions:
 *  - @widget is a WxWindow. The handler stays connected until finalization; it only reports to
 *    the borrowed application, which outlives the window.
 * Postconditions:
 *  - self->mapped is TRUE and the state was re-read and reported.
 * Thread affinity: main thread only.
 * Ownership: @widget is borrowed.
 */
static void
on_map(GtkWidget *widget, gpointer user_data)
{
  (void)user_data;
  WxWindow *self = WX_WINDOW(widget);
  self->mapped = TRUE;
  read_toplevel_state(self);
}

/**
 * on_unmap:
 * @widget: the window that was unmapped.
 * @user_data: unused (NULL).
 *
 * "unmap" handler: marks the window not mapped and reports the visibility.
 *
 * Preconditions:
 *  - @widget is a WxWindow (see on_map()).
 * Postconditions:
 *  - self->mapped is FALSE and the visibility was reported.
 * Thread affinity: main thread only.
 * Ownership: @widget is borrowed.
 */
static void
on_unmap(GtkWidget *widget, gpointer user_data)
{
  (void)user_data;
  WxWindow *self = WX_WINDOW(widget);
  self->mapped = FALSE;
  report_visibility(self);
}

/**
 * on_active_changed:
 * @self: (not nullable): the window (the instance argument of the "notify::is-active" connection
 *   made in build_window(); the GParamSpec and user data (NULL) are not used).
 *
 * Tells the application when the window becomes the active window.
 *
 * Preconditions:
 *  - @self is a built WxWindow (the handler stays connected until finalization; the application
 *    it reports to outlives the window).
 * Postconditions:
 *  - wx_app_window_focused() was called iff the window is active; nothing else changed.
 * Thread affinity: main thread only.
 * Ownership: none (no pointers besides @self).
 */
static void
on_active_changed(WxWindow *self)
{
  if (gtk_window_is_active(GTK_WINDOW(self)))
    wx_app_window_focused(window_app(self));
}

/* ------------------------------------------------------------------------ */
/* Header bar: units, refresh                                               */
/* ------------------------------------------------------------------------ */

/**
 * update_units_button:
 * @self: (not nullable): the window.
 *
 * Shows the current unit system on the units button: "°F" with the tooltip "Switch to Celsius"
 * for imperial, "°C" with "Switch to Fahrenheit" for metric. Also called once by build_window().
 *
 * Preconditions:
 *  - @self is a built WxWindow whose units button exists.
 * Postconditions:
 *  - the button's label, tooltip and accessible label match wx_app_get_units().
 * Thread affinity: main thread only.
 * Ownership: none (no pointers besides @self).
 */
static void
update_units_button(WxWindow *self)
{
  gboolean imperial = wx_app_get_units(window_app(self)) == WX_UNITS_IMPERIAL;
  const char *tip = imperial ? "Switch to Celsius" : "Switch to Fahrenheit";
  gtk_button_set_label(GTK_BUTTON(self->units_button), imperial ? "\xC2\xB0" "F" : "\xC2\xB0" "C");
  gtk_widget_set_tooltip_text(self->units_button, tip);
  gtk_accessible_update_property(GTK_ACCESSIBLE(self->units_button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 tip, -1);
}

/**
 * update_refresh:
 * @self: (not nullable): the window.
 *
 * Enables the refresh action (and so the button) while a place is selected, it is not loading
 * and the network is available: a place that is loading is about to be fresh, and the
 * application drops a refresh of it anyway (see wx_app_refresh_selected(), which also drops the
 * ones that come too soon after the last request; the button stays enabled then). Also called
 * once by build_window().
 *
 * Preconditions:
 *  - @self is a built WxWindow.
 * Postconditions:
 *  - the "refresh" action is enabled iff self->current is set, it is not loading and the
 *    application is online.
 * Thread affinity: main thread only.
 * Ownership: none (no pointers besides @self).
 */
static void
update_refresh(WxWindow *self)
{
  GAction *action = g_action_map_lookup_action(G_ACTION_MAP(self), "refresh");
  g_simple_action_set_enabled(G_SIMPLE_ACTION(action),
                              self->current != NULL && !wx_row_item_get_loading(self->current) &&
                                  !wx_app_get_offline(window_app(self)));
}

/**
 * on_units_changed:
 * @self: (not nullable): the window (receiver of the swapped "notify::units" connection to the
 *   application; the GParamSpec and the application the signal also passes are not used).
 *
 * Follows the application's unit system.
 *
 * Preconditions:
 *  - @self is a built WxWindow; the connection is removed in wx_window_dispose().
 * Postconditions:
 *  - the units button shows the current unit.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
on_units_changed(WxWindow *self)
{
  update_units_button(self);
}

/**
 * on_offline_changed:
 * @self: (not nullable): the window (receiver of the swapped "notify::offline" connection to the
 *   application).
 *
 * Follows the application's network state.
 *
 * Preconditions:
 *  - @self is a built WxWindow; the connection is removed in wx_window_dispose().
 * Postconditions:
 *  - the refresh action's enabled state was re-evaluated.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
on_offline_changed(WxWindow *self)
{
  update_refresh(self);
}

/**
 * on_toggle_units:
 * @action: the activated action (unused).
 * @parameter: (nullable): unused (the action has none).
 * @user_data: (not nullable): the WxWindow.
 *
 * "win.toggle-units": switches between imperial and metric units.
 *
 * Preconditions:
 *  - @user_data is the window the action belongs to (the action dies with it).
 * Postconditions:
 *  - wx_app_set_units() was called with the other unit system.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed.
 */
static void
on_toggle_units(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  WxWindow *self = WX_WINDOW(user_data);
  WxApp *app = window_app(self);
  wx_app_set_units(app, wx_app_get_units(app) == WX_UNITS_IMPERIAL ? WX_UNITS_METRIC
                                                                   : WX_UNITS_IMPERIAL);
}

/**
 * on_refresh:
 * @action: the activated action (unused).
 * @parameter: (nullable): unused (the action has none).
 * @user_data: (not nullable): the WxWindow.
 *
 * "win.refresh": fetches the selected place again.
 *
 * Preconditions:
 *  - @user_data is the window the action belongs to.
 * Postconditions:
 *  - wx_app_refresh_selected() was called.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed.
 */
static void
on_refresh(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  wx_app_refresh_selected(window_app(WX_WINDOW(user_data)));
}

/* ------------------------------------------------------------------------ */
/* Selection, detail, sources                                               */
/* ------------------------------------------------------------------------ */

/**
 * update_sources:
 * @self: (not nullable): the window.
 *
 * Gives the sources page the forecast of the selected place (none without selection or forecast),
 * when it differs from the one it has.
 *
 * Preconditions:
 *  - @self is a built WxWindow with a live sources page (self->sources is not NULL); all callers
 *    are handlers that wx_window_dispose() disconnects before it clears self->sources.
 * Postconditions:
 *  - self->sources_forecast is the forecast of self->current (one reference held) and the page
 *    was given it; nothing happens when it already was.
 * Thread affinity: main thread only.
 * Ownership: the window holds its own reference on the forecast.
 */
static void
update_sources(WxWindow *self)
{
  WxForecast *forecast = self->current != NULL ? wx_row_item_get_forecast(self->current) : NULL;
  if (forecast == self->sources_forecast)
    return;
  WxForecast *ref = forecast != NULL ? wx_forecast_ref(forecast) : NULL;
  if (self->sources_forecast != NULL)
    wx_forecast_unref(self->sources_forecast);
  self->sources_forecast = ref;
  wx_sources_set_forecast(WX_SOURCES(self->sources), forecast);
}

/**
 * on_current_changed:
 * @self: (not nullable): the window (receiver of the swapped "changed" connection to the selected
 *   item).
 *
 * The selected item changed (a forecast arrived, it started or stopped loading, ...): the sources
 * page follows its forecast and the refresh action follows its loading state.
 *
 * Preconditions:
 *  - @self is a built WxWindow with a live sources page; the connection is removed when the item
 *    is deselected and in wx_window_dispose().
 * Postconditions:
 *  - update_sources() and update_refresh() ran.
 * Thread affinity: main thread only.
 * Ownership: none.
 */
static void
on_current_changed(WxWindow *self)
{
  update_sources(self);
  update_refresh(self);
}

/**
 * on_selected_item_changed:
 * @self: (not nullable): the window (receiver of the swapped "notify::selected-item" connection to
 *   the selection; the GParamSpec and the selection the signal also passes are not used).
 *
 * Follows the list's selection: stores the selected item (a strong reference), shows it in the
 * detail pane and on the sources page and reports it. Also called once by build_window().
 *
 * Preconditions:
 *  - @self is a built WxWindow with a selection and a live detail pane (the connection is removed
 *    in wx_window_dispose() before either is released).
 * Postconditions:
 *  - when the selected item differs from self->current: self->current holds a reference on the new
 *    item (or is NULL), the pane shows it and wx_app_select() was called; otherwise nothing is
 *    changed.
 * Thread affinity: main thread only.
 * Ownership: the item returned by the selection is borrowed; self->current takes its own
 *   reference.
 */
static void
on_selected_item_changed(WxWindow *self)
{
  WxRowItem *item = gtk_single_selection_get_selected_item(self->selection);
  if (item == self->current)
    return;
  if (self->current != NULL && self->current_changed_id != 0)
    g_signal_handler_disconnect(self->current, self->current_changed_id);
  self->current_changed_id = 0;
  g_set_object(&self->current, item);
  if (self->current != NULL)
    self->current_changed_id =
        g_signal_connect_swapped(self->current, "changed", G_CALLBACK(on_current_changed), self);
  wx_detail_set_item(WX_DETAIL(self->detail), self->current);
  update_sources(self);
  update_refresh(self);
  wx_app_select(window_app(self), self->current != NULL ? wx_row_item_get_key(self->current) : NULL);
}

/**
 * select_key:
 * @self: (not nullable): the window.
 * @key: (nullable): a place key, or NULL.
 *
 * Selects the row of the place with that key.
 *
 * Preconditions:
 *  - @self is a built WxWindow with a selection; @key is NULL or NUL-terminated.
 * Postconditions:
 *  - when the places hold @key and the item model has that many rows, the row is selected (the
 *    selection handler ran); otherwise nothing changes.
 * Thread affinity: main thread only.
 * Ownership: @key is borrowed for the call.
 */
static void
select_key(WxWindow *self, const char *key)
{
  gint index = wx_places_index_of(wx_app_get_places(window_app(self)), key);
  GListModel *items = wx_app_get_items(window_app(self));
  if (index >= 0 && (guint)index < g_list_model_get_n_items(items))
    gtk_single_selection_set_selected(self->selection, (guint)index);
}

/**
 * on_items_changed:
 * @model: the item model of the application.
 * @position: first changed position (unused).
 * @removed: number of removed items (unused).
 * @added: number of added items (unused).
 * @self: (not nullable): the window, user data of the connection made in build_window().
 *
 * Shows the main page when the model has items and the empty-state page otherwise. Also called
 * once by build_window() with zeros.
 *
 * Preconditions:
 *  - @self is a built WxWindow whose stack exists; the connection is removed in
 *    wx_window_dispose().
 * Postconditions:
 *  - the stack shows "main" iff g_list_model_get_n_items(@model) > 0, else "empty".
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_items_changed(GListModel *model, guint position, guint removed, guint added, WxWindow *self)
{
  (void)position;
  (void)removed;
  (void)added;
  gtk_stack_set_visible_child_name(GTK_STACK(self->stack),
                                   g_list_model_get_n_items(model) > 0 ? "main" : "empty");
}

/* ------------------------------------------------------------------------ */
/* Picker, about, suggestions                                               */
/* ------------------------------------------------------------------------ */

/**
 * on_place_added:
 * @picker: the picker (unused).
 * @key: (not nullable): the key of the place the picker added (a private copy).
 * @self: (not nullable): the window, user data of the connection made in on_add().
 *
 * "place-added" handler of the picker: selects the new place.
 *
 * Preconditions:
 *  - @self is a built WxWindow (the connection uses the window as its object).
 * Postconditions:
 *  - the new place's row is selected.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_place_added(WxPicker *picker, const char *key, WxWindow *self)
{
  (void)picker;
  select_key(self, key);
}

/**
 * on_add:
 * @action: the activated action (unused).
 * @parameter: (nullable): unused (the action has none).
 * @user_data: (not nullable): the WxWindow.
 *
 * "win.add": opens the picker, or presents it again when it is open already.
 *
 * Preconditions:
 *  - @user_data is the window the action belongs to, not disposed (the action dies with it).
 * Postconditions:
 *  - at most one picker exists: self->picker is the open picker (a weak pointer, cleared when the
 *    picker is disposed; the picker is transient for the window and destroyed with it).
 * Thread affinity: main thread only.
 * Ownership: the picker is owned by GTK's window list, not by the window; the window holds only
 *   the weak pointer, which wx_window_dispose() removes.
 */
static void
on_add(GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  (void)action;
  (void)parameter;
  WxWindow *self = WX_WINDOW(user_data);
  if (self->picker != NULL) {
    gtk_window_present(GTK_WINDOW(self->picker));
    return;
  }
  WxApp *app = window_app(self);
  GtkWidget *picker = wx_picker_new(wx_app_get_places(app), wx_app_get_service(app));
  /* wx_picker_new() returns NULL only for NULL or mistyped arguments (a critical): both come from
   * the application, which owns valid objects. */
  gtk_window_set_transient_for(GTK_WINDOW(picker), GTK_WINDOW(self));
  gtk_window_set_destroy_with_parent(GTK_WINDOW(picker), TRUE);
  g_signal_connect_object(picker, "place-added", G_CALLBACK(on_place_added), self, 0);
  self->picker = picker;
  g_object_add_weak_pointer(G_OBJECT(picker), (gpointer *)&self->picker);
  gtk_window_present(GTK_WINDOW(picker));
}

/**
 * on_suggestion_clicked:
 * @button: (not nullable): the suggestion button that was clicked; its "wx-index" data is the
 *   index into the window's suggestions.
 * @self: (not nullable): the window, user data of the connection made in build_empty_page().
 *
 * Saves the suggested city and selects it.
 *
 * Preconditions:
 *  - @self is a built WxWindow; the button's "wx-index" is below the number of suggestions (set by
 *    build_empty_page()).
 * Postconditions:
 *  - the place was added to the places (the application reacts to "changed") and its row
 *    selected; nothing else happens when the add is refused (a duplicate, a full list).
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_suggestion_clicked(GtkButton *button, WxWindow *self)
{
  guint index = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(button), "wx-index"));
  const WxPlace *place = g_ptr_array_index(self->suggestions, index);
  if (!wx_places_add(wx_app_get_places(window_app(self)), place))
    return;
  g_autofree char *key = wx_place_key(place);
  select_key(self, key);
}

/**
 * show_about:
 * @self: (not nullable): the window.
 *
 * Shows the about dialog (the sources page's About button).
 *
 * Preconditions:
 *  - @self is a built WxWindow.
 * Postconditions:
 *  - the about dialog is shown, transient for the window (GTK keeps one dialog per window).
 * Thread affinity: main thread only.
 * Ownership: the dialog is owned by GTK.
 */
static void
show_about(WxWindow *self)
{
  gtk_show_about_dialog(GTK_WINDOW(self), "program-name", "Weather", "version",
                        WX_APP_VERSION, "comments",
                        "Weather forecasts from several free sources, with the rain you "
                        "can expect and when.",
                        "copyright", "Copyright \xC2\xA9 2026 wtp128pro", "license-type",
                        GTK_LICENSE_GPL_3_0, "website", "https://github.com/wtp128pro/weather",
                        "logo-icon-name", WX_APP_ID, NULL);
}

/**
 * on_sources_about:
 * @sources: the sources page (unused).
 * @self: (not nullable): the window, user data of the connection made in build_window().
 *
 * "about-requested" handler of the sources page.
 *
 * Preconditions:
 *  - @self is a built WxWindow (the connection uses the window as its object).
 * Postconditions:
 *  - the about dialog is shown.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_sources_about(WxSources *sources, WxWindow *self)
{
  (void)sources;
  show_about(self);
}

/**
 * on_provider_toggled:
 * @sources: the sources page (unused).
 * @id: (not nullable): the provider id of the switch (a private copy).
 * @enabled: the state the user chose.
 * @self: (not nullable): the window, user data of the connection made in build_window().
 *
 * "provider-toggled" handler of the sources page: the application applies it to the registry, the
 * settings and the places' forecasts.
 *
 * Preconditions:
 *  - @self is a built WxWindow (the connection uses the window as its object).
 * Postconditions:
 *  - wx_app_set_provider_enabled() was called.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_provider_toggled(WxSources *sources, const char *id, gboolean enabled, WxWindow *self)
{
  (void)sources;
  wx_app_set_provider_enabled(window_app(self), id, enabled);
}

/* ------------------------------------------------------------------------ */
/* Rows                                                                     */
/* ------------------------------------------------------------------------ */

/**
 * on_row_remove:
 * @row: the row that asked (unused).
 * @key: (not nullable): the key of the row's item, a private copy made by the row.
 * @self: (not nullable): the window, user data of the connection made in on_factory_setup().
 *
 * "remove-requested" handler: removes the place from the list. The application reacts to the
 * places' "changed" signal.
 *
 * Preconditions:
 *  - @self is a built WxWindow. The connection is made with g_signal_connect_object() and is
 *    dropped when the window is finalized; rows only emit on user action.
 *  - @key is NUL-terminated. It is not trusted: wx_places_remove() reads at most 24 bytes and
 *    ignores anything that is not the key of a saved place.
 * Postconditions:
 *  - the place is removed from the list if it was present.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_row_remove(WxRow *row, const char *key, WxWindow *self)
{
  (void)row;
  wx_places_remove(wx_app_get_places(window_app(self)), key);
}

/**
 * on_row_move:
 * @row: the row that asked (unused).
 * @key: (not nullable): the key of the row's item, a private copy made by the row.
 * @delta: -1 (Move up) or +1 (Move down); any other value is handled by the range check below.
 * @self: (not nullable): the window, user data of the connection made in on_factory_setup().
 *
 * "move-requested" handler: moves the place by @delta positions in the list.
 *
 * Preconditions:
 *  - @self is a built WxWindow (see on_row_remove()); @key is NUL-terminated.
 * Postconditions:
 *  - when wx_places_index_of() finds @key (it validates the text) and index + @delta is inside
 *    [0, n_places) (computed in gint64, so it cannot overflow) the place was moved with
 *    wx_places_move(); otherwise nothing is changed.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_row_move(WxRow *row, const char *key, int delta, WxWindow *self)
{
  (void)row;
  WxPlaces *places = wx_app_get_places(window_app(self));
  gint from = wx_places_index_of(places, key);
  if (from < 0)
    return;
  gint64 to = (gint64)from + delta;
  if (to < 0 || to >= (gint64)wx_places_get_n_places(places))
    return;
  wx_places_move(places, (guint)from, (guint)to);
}

/**
 * on_row_reorder:
 * @row: the row that received the drop (unused).
 * @source: (not nullable): UNTRUSTED text carried by a drop (it may come from another
 *   application); a private copy made by the row.
 * @target: (not nullable): the key of the row that received the drop.
 * @self: (not nullable): the window, user data of the connection made in on_factory_setup().
 *
 * "reorder-requested" handler: moves the dropped place to the target's position.
 *
 * Preconditions:
 *  - @self is a built WxWindow (see on_row_remove()); @source and @target are NUL-terminated.
 * Postconditions:
 *  - both texts go through wx_places_index_of(), which looks at the first 24 bytes only and
 *    returns -1 for anything that is not the key of a saved place; only when both are saved
 *    places was the place moved with wx_places_move() (indices come from the list and are >= 0).
 *    Otherwise nothing is changed. Neither text is stored.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_row_reorder(WxRow *row, const char *source, const char *target, WxWindow *self)
{
  (void)row;
  WxPlaces *places = wx_app_get_places(window_app(self));
  gint from = wx_places_index_of(places, source); /* validates untrusted text */
  gint to = wx_places_index_of(places, target);
  if (from >= 0 && to >= 0)
    wx_places_move(places, (guint)from, (guint)to);
}

/**
 * on_factory_setup:
 * @factory: the list item factory (unused).
 * @list_item: the list item that needs a child.
 * @user_data: (not nullable): the WxWindow, passed as user data by g_signal_connect_object() in
 *   build_list_page(); the connection is dropped when the window is finalized.
 *
 * "setup" handler of the factory: creates a WxRow, connects its request signals to the window and
 * makes it the list item's child.
 *
 * Preconditions:
 *  - @list_item is a GtkListItem; @user_data is the WxWindow (the row handlers use it as the
 *    object of g_signal_connect_object(), so they never outlive it).
 * Postconditions:
 *  - @list_item's child is a new unbound WxRow.
 * Thread affinity: main thread only.
 * Ownership: the row is owned by @list_item (the floating reference is sunk by
 *   gtk_list_item_set_child()); @list_item and @user_data are borrowed.
 */
static void
on_factory_setup(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  GtkWidget *row = wx_row_new();
  g_signal_connect_object(row, "remove-requested", G_CALLBACK(on_row_remove), user_data, 0);
  g_signal_connect_object(row, "move-requested", G_CALLBACK(on_row_move), user_data, 0);
  g_signal_connect_object(row, "reorder-requested", G_CALLBACK(on_row_reorder), user_data, 0);
  gtk_list_item_set_child(list_item, row);
}

/**
 * on_factory_bind:
 * @factory: the list item factory (unused).
 * @list_item: the list item being bound.
 * @user_data: unused (NULL).
 *
 * "bind" handler of the factory: shows the list item's WxRowItem in its row. Pairs with
 * on_factory_unbind().
 *
 * Preconditions:
 *  - @list_item was set up by on_factory_setup() (its child is a WxRow) and holds a WxRowItem of
 *    the application's model.
 * Postconditions:
 *  - the row holds a reference on the item and follows its "changed" signal until unbound.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed; the row takes its own reference on the item.
 */
static void
on_factory_bind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  (void)user_data;
  wx_row_bind(WX_ROW(gtk_list_item_get_child(list_item)),
              WX_ROW_ITEM(gtk_list_item_get_item(list_item)));
}

/**
 * on_factory_unbind:
 * @factory: the list item factory (unused).
 * @list_item: the list item being unbound.
 * @user_data: unused (NULL).
 *
 * "unbind" handler of the factory: blanks the row and releases its item. Pairs with
 * on_factory_bind().
 *
 * Preconditions:
 *  - @list_item was set up by on_factory_setup() (its child is a WxRow).
 * Postconditions:
 *  - the row is unbound: its reference on the item and its "changed" handler are gone.
 * Thread affinity: main thread only.
 * Ownership: all parameters are borrowed for the call.
 */
static void
on_factory_unbind(GtkSignalListItemFactory *factory, GtkListItem *list_item, gpointer user_data)
{
  (void)factory;
  (void)user_data;
  wx_row_bind(WX_ROW(gtk_list_item_get_child(list_item)), NULL);
}

/* ------------------------------------------------------------------------ */
/* Construction                                                             */
/* ------------------------------------------------------------------------ */

/**
 * build_list_page:
 * @self: (not nullable): the window being built.
 * @app: (not nullable): the application.
 *
 * Builds the scrolled list view over the application's item model with a single, auto-selecting
 * selection and a signal factory (setup, bind, unbind).
 *
 * Preconditions:
 *  - called once by build_window() with @app == self->app, on a window whose selection is NULL.
 * Postconditions:
 *  - self->selection holds a reference on the new selection model; the list view holds its own
 *    reference on the selection and the selection on the item model; the factory is owned by the
 *    list view. The "setup" connection uses the window as its object; "bind"/"unbind" have no
 *    user data.
 * Thread affinity: main thread only.
 * Ownership: the model reference taken for the selection and the selection reference given to the
 *   list view are transferred; the returned widget is floating.
 *
 * Returns: (transfer floating): the scrolled window holding the list view.
 */
static GtkWidget *
build_list_page(WxWindow *self, WxApp *app)
{
  GListModel *items = wx_app_get_items(app);
  self->selection = gtk_single_selection_new(g_object_ref(items));
  gtk_single_selection_set_autoselect(self->selection, TRUE);
  gtk_single_selection_set_can_unselect(self->selection, FALSE);

  GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
  g_signal_connect_object(factory, "setup", G_CALLBACK(on_factory_setup), self, 0);
  g_signal_connect(factory, "bind", G_CALLBACK(on_factory_bind), NULL);
  g_signal_connect(factory, "unbind", G_CALLBACK(on_factory_unbind), NULL);
  GtkWidget *list = gtk_list_view_new(g_object_ref(GTK_SELECTION_MODEL(self->selection)), factory);
  gtk_list_view_set_show_separators(GTK_LIST_VIEW(list), TRUE);
  gtk_widget_set_name(list, "wx-place-list");
  gtk_widget_add_css_class(list, "wx-list");
  gtk_accessible_update_property(GTK_ACCESSIBLE(list), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "Saved places", -1);

  GtkWidget *scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER,
                                 GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), list);
  gtk_widget_set_size_request(scrolled, LIST_MIN_WIDTH, -1);
  return scrolled;
}

/**
 * build_empty_page:
 * @self: (not nullable): the window being built.
 *
 * Builds the first-run page: "No places yet", a hint, one button per suggested city and the
 * suggested-action "Add a city" button.
 *
 * Preconditions:
 *  - called once by build_window(), on a window whose suggestions are NULL.
 * Postconditions:
 *  - self->suggestions holds the suggested places; each suggestion button's "clicked" signal calls
 *    on_suggestion_clicked() and the search button activates "win.add", with the window as the
 *    (weakly tracked) receiver.
 * Thread affinity: main thread only.
 * Ownership: the returned widget is floating.
 *
 * Returns: (transfer floating): the page widget.
 */
static GtkWidget *
build_empty_page(WxWindow *self)
{
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
  gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
  gtk_widget_set_margin_start(box, 24);
  gtk_widget_set_margin_end(box, 24);

  GtkWidget *title = gtk_label_new("No places yet");
  gtk_widget_set_name(title, "wx-empty-title");
  gtk_widget_add_css_class(title, "wx-empty-title");
  GtkWidget *hint = gtk_label_new("Pick a city to see its weather and when it will rain.");
  gtk_widget_set_name(hint, "wx-empty-hint");
  gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
  gtk_label_set_justify(GTK_LABEL(hint), GTK_JUSTIFY_CENTER);
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_box_append(GTK_BOX(box), title);
  gtk_box_append(GTK_BOX(box), hint);

  GtkWidget *chips = gtk_flow_box_new();
  gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(chips), GTK_SELECTION_NONE);
  gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(chips), 5);
  gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(chips), FALSE);
  gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(chips), 8);
  gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(chips), 8);
  gtk_widget_set_halign(chips, GTK_ALIGN_CENTER);
  self->suggestions = wx_suggested_places_new();
  for (guint i = 0; i < self->suggestions->len; i++) {
    const WxPlace *place = g_ptr_array_index(self->suggestions, i);
    GtkWidget *chip = gtk_button_new_with_label(place->name);
    gtk_widget_set_name(chip, "wx-suggestion");
    gtk_widget_add_css_class(chip, "wx-chip");
    g_autofree char *label = wx_place_label(place);
    g_autofree char *tip = g_strdup_printf("Add %s", label);
    gtk_widget_set_tooltip_text(chip, tip);
    g_object_set_data(G_OBJECT(chip), "wx-index", GUINT_TO_POINTER(i));
    g_signal_connect_object(chip, "clicked", G_CALLBACK(on_suggestion_clicked), self, 0);
    gtk_flow_box_append(GTK_FLOW_BOX(chips), chip);
  }
  gtk_box_append(GTK_BOX(box), chips);

  GtkWidget *button = gtk_button_new_with_label("Add a city");
  gtk_widget_set_name(button, "wx-empty-add");
  gtk_widget_add_css_class(button, "suggested-action");
  gtk_widget_set_halign(button, GTK_ALIGN_CENTER);
  gtk_actionable_set_action_name(GTK_ACTIONABLE(button), "win.add");
  gtk_box_append(GTK_BOX(box), button);
  return box;
}

/**
 * build_header:
 * @self: (not nullable): the window being built.
 *
 * Builds the header bar: the Add button (start), the main menu button with the sources page, the
 * units button and the Refresh button (end).
 *
 * Preconditions:
 *  - called once by build_window(), after the actions exist.
 * Postconditions:
 *  - self->units_button and sources are set; the sources page's signals are connected with the
 *    window as the (weakly tracked) receiver; the header bar is the window's titlebar.
 * Thread affinity: main thread only.
 * Ownership: the widgets are owned by the header bar; the pointers in @self are borrowed.
 */
static void
build_header(WxWindow *self)
{
  GtkWidget *header = gtk_header_bar_new();

  /* "list-add-symbolic" and the other icon names are freedesktop standard names every icon theme
   * provides or inherits (GTK also ships Adwaita's copy as a fallback); an icon-only button needs
   * an explicit accessible label. */
  GtkWidget *add_button = gtk_button_new_from_icon_name("list-add-symbolic");
  gtk_widget_set_name(add_button, "wx-add-button");
  gtk_actionable_set_action_name(GTK_ACTIONABLE(add_button), "win.add");
  gtk_widget_set_tooltip_text(add_button, "Add a city (Ctrl+N)");
  gtk_accessible_update_property(GTK_ACCESSIBLE(add_button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "Add a city", -1);
  gtk_header_bar_pack_start(GTK_HEADER_BAR(header), add_button);

  GtkWidget *menu = gtk_menu_button_new();
  gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu), "open-menu-symbolic");
  gtk_widget_set_name(menu, "wx-menu-button");
  gtk_widget_set_tooltip_text(menu, "Data sources and about");
  gtk_accessible_update_property(GTK_ACCESSIBLE(menu), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "Data sources and about", -1);
  self->sources = wx_sources_new(wx_app_get_registry(self->app));
  g_signal_connect_object(self->sources, "provider-toggled", G_CALLBACK(on_provider_toggled), self,
                          0);
  g_signal_connect_object(self->sources, "about-requested", G_CALLBACK(on_sources_about), self, 0);
  gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), self->sources);
  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu);

  self->units_button = gtk_button_new();
  gtk_widget_set_name(self->units_button, "wx-units-button");
  gtk_actionable_set_action_name(GTK_ACTIONABLE(self->units_button), "win.toggle-units");
  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), self->units_button);
  update_units_button(self);

  GtkWidget *refresh_button = gtk_button_new_from_icon_name("view-refresh-symbolic");
  gtk_widget_set_name(refresh_button, "wx-refresh-button");
  gtk_actionable_set_action_name(GTK_ACTIONABLE(refresh_button), "win.refresh");
  gtk_widget_set_tooltip_text(refresh_button, "Refresh this place (F5)");
  gtk_accessible_update_property(GTK_ACCESSIBLE(refresh_button), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                 "Refresh", -1);
  gtk_header_bar_pack_end(GTK_HEADER_BAR(header), refresh_button);

  gtk_window_set_titlebar(GTK_WINDOW(self), header);
}

/**
 * build_window:
 * @self: (not nullable): the new window, straight from g_object_new().
 * @app: (not nullable): the application; borrowed, it must outlive the window.
 *
 * The application is not a construct property of GtkWindow, so the window is built here, after
 * g_object_new(), and added to the application last (by wx_window_new()). Creates the actions, the
 * header bar, the pages, the detail pane and the paned layout, connects the handlers and applies
 * the current items, offline state, units and selection.
 *
 * Preconditions:
 *  - called exactly once per window, by wx_window_new(), after WX_IS_APP(@app) was checked, on the
 *    main thread.
 * Postconditions:
 *  - self->app is @app (no reference taken); stack, detail, sources, units button and selection
 *    are set. The handlers on the application, the item model, the sources page, the selection
 *    and the selected item are connected with the window as the object (dropped at
 *    finalization) and are also disconnected by wx_window_dispose(); the handler on the surface,
 *    made by on_realize(), is removed by on_unrealize() or wx_window_dispose(). The actions of
 *    the buttons and (through on_factory_setup()) the handlers on the rows are connected the
 *    same way and live until finalization. The "realize", "unrealize", "map", "unmap" and
 *    "notify::is-active" handlers are plain connections without user data on the window itself
 *    and stay (they only report to the application or manage the surface handler).
 * Thread affinity: main thread only.
 * Ownership: @app is borrowed; children are owned by their containers.
 */
static void
build_window(WxWindow *self, WxApp *app)
{
  self->app = app;

  gtk_window_set_title(GTK_WINDOW(self), "Weather");
  gtk_window_set_default_size(GTK_WINDOW(self), 1040, 720);

  static const GActionEntry entries[] = {
      {.name = "add", .activate = on_add},
      {.name = "refresh", .activate = on_refresh},
      {.name = "toggle-units", .activate = on_toggle_units},
  };
  g_action_map_add_action_entries(G_ACTION_MAP(self), entries, G_N_ELEMENTS(entries), self);

  build_header(self);

  self->stack = gtk_stack_new();
  gtk_widget_set_name(self->stack, "wx-main-stack");
  gtk_stack_add_named(GTK_STACK(self->stack), build_empty_page(self), "empty");

  self->detail = wx_detail_new();
  gtk_widget_set_name(self->detail, "wx-detail");
  gtk_widget_set_size_request(self->detail, DETAIL_MIN_WIDTH, -1);
  GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
  gtk_paned_set_start_child(GTK_PANED(paned), build_list_page(self, app));
  gtk_paned_set_end_child(GTK_PANED(paned), self->detail);
  gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
  gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
  gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
  gtk_paned_set_position(GTK_PANED(paned), LIST_MIN_WIDTH);
  gtk_stack_add_named(GTK_STACK(self->stack), paned, "main");
  gtk_window_set_child(GTK_WINDOW(self), self->stack);

  GListModel *items = wx_app_get_items(app);
  g_signal_connect_object(items, "items-changed", G_CALLBACK(on_items_changed), self, 0);
  on_items_changed(items, 0, 0, 0, self);

  g_signal_connect_object(app, "notify::offline", G_CALLBACK(on_offline_changed), self,
                          G_CONNECT_SWAPPED);
  g_signal_connect_object(app, "notify::units", G_CALLBACK(on_units_changed), self,
                          G_CONNECT_SWAPPED);

  /* The persisted selection, else the first row (autoselect), is selected. */
  select_key(self, wx_app_get_selected(app));
  g_signal_connect_object(self->selection, "notify::selected-item",
                          G_CALLBACK(on_selected_item_changed), self, G_CONNECT_SWAPPED);
  on_selected_item_changed(self);
  update_refresh(self);

  g_signal_connect(self, "realize", G_CALLBACK(on_realize), NULL);
  g_signal_connect(self, "unrealize", G_CALLBACK(on_unrealize), NULL);
  g_signal_connect(self, "map", G_CALLBACK(on_map), NULL);
  g_signal_connect(self, "unmap", G_CALLBACK(on_unmap), NULL);
  g_signal_connect(self, "notify::is-active", G_CALLBACK(on_active_changed), NULL);
}

/**
 * wx_window_dispose:
 * @object: the window being disposed.
 *
 * GObject dispose vfunc. Disconnects every handler that has this window as its receiver (on the
 * application, the item model, the sources page, the selected item, the selection and the
 * surface; none is connected on the detail pane, which the window only feeds through
 * wx_detail_set_item()), so that nothing the toolkit emits while it takes the widgets apart
 * reaches the window; clears the detail and sources pointers, removes the weak pointer on the picker,
 * releases the current item, the sources forecast, the suggestions and the selection, then
 * chains up. May run more than once.
 *
 * Preconditions:
 *  - @object is a WxWindow; self->app is NULL (never built) or the live application: the
 *    application is borrowed and outlives the window, so using it here is safe.
 * Postconditions:
 *  - self->detail, self->sources, self->picker, self->current, self->sources_forecast,
 *    self->suggestions and self->selection are NULL; the parent dispose has run. A repeated call
 *    skips the parts already done (the application and surface disconnections are repeated and
 *    harmless).
 * Thread affinity: main thread only.
 * Ownership: the references on the current item, the forecast, the suggestions and the
 *   selection, and the picker weak pointer, are released; the application is not owned.
 */
static void
wx_window_dispose(GObject *object)
{
  WxWindow *self = WX_WINDOW(object);
  /* Every handler that has this window as its receiver is disconnected before the toolkit starts
   * to take the widgets apart: while it does, children (the list view and its selection) and the
   * surface may still emit signals, and none of them may reach a window that is being disposed.
   * The objects below are the application's and the window's own children: nothing but this file
   * connects the window as the data of a handler on them, so they are disconnected by data. The
   * surface is the toolkit's: its connections carry the window as their data too (GtkNative), so
   * only the one handler this file connected is removed, by id. Dispose may run more than once:
   * pointers to children are cleared after their use (the application is borrowed and outlives the
   * window). */
  if (self->app != NULL) {
    g_signal_handlers_disconnect_by_data(self->app, self);
    g_signal_handlers_disconnect_by_data(wx_app_get_items(self->app), self);
  }
  if (self->current != NULL)
    g_signal_handlers_disconnect_by_data(self->current, self);
  self->current_changed_id = 0;
  self->detail = NULL;
  if (self->sources != NULL) {
    g_signal_handlers_disconnect_by_data(self->sources, self);
    self->sources = NULL;
  }
  if (self->selection != NULL)
    g_signal_handlers_disconnect_by_data(self->selection, self);
  if (self->state_surface != NULL) {
    g_signal_handler_disconnect(self->state_surface, self->state_id);
    self->state_surface = NULL;
    self->state_id = 0;
  }

  if (self->picker != NULL) {
    g_object_remove_weak_pointer(G_OBJECT(self->picker), (gpointer *)&self->picker);
    self->picker = NULL;
  }
  g_clear_object(&self->current);
  g_clear_pointer(&self->sources_forecast, wx_forecast_unref);
  g_clear_pointer(&self->suggestions, g_ptr_array_unref);
  g_clear_object(&self->selection);
  G_OBJECT_CLASS(wx_window_parent_class)->dispose(object);
}

/**
 * wx_window_class_init:
 * @klass: (not nullable): the class structure being initialised.
 *
 * GObject class initialiser: installs dispose().
 *
 * Preconditions:
 *  - called once by GObject while the type is registered.
 * Postconditions:
 *  - the class dispose vfunc is wx_window_dispose().
 * Thread affinity: main thread only.
 * Ownership: @klass is owned by GObject.
 */
static void
wx_window_class_init(WxWindowClass *klass)
{
  GObjectClass *oc = G_OBJECT_CLASS(klass);
  oc->dispose = wx_window_dispose;
}

/**
 * wx_window_init:
 * @self: (not nullable): the new instance (zero-filled by GObject).
 *
 * GObject instance initialiser: nothing to do, the window is built by build_window() because the
 * application is not known yet.
 *
 * Preconditions:
 *  - called once by GObject for a new instance.
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread only.
 * Ownership: @self is owned by GObject.
 */
static void
wx_window_init(WxWindow *self)
{
  (void)self;
}

/* Documented in wx-window.h. */
GtkWidget *
wx_window_new(WxApp *app)
{
  g_return_val_if_fail(WX_IS_APP(app), NULL);
  WxWindow *self = g_object_new(WX_TYPE_WINDOW, NULL);
  build_window(self, app);
  gtk_window_set_application(GTK_WINDOW(self), GTK_APPLICATION(app));
  return GTK_WIDGET(self);
}
