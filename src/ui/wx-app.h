/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-app.h - WxApp: the GtkApplication of the weather app and the owner of its
 * data: the WxRegistry of data sources (and the place-search geocoder), the
 * WxService that fetches and blends forecasts, the WxPlaces / WxSettings /
 * WxCache (persistence), the list of WxRowItem shown by the window and the
 * WxScheduler that decides when to fetch.
 *
 * Wiring site. wx-app.c is the ONLY place that constructs concrete providers
 * (wx_nws_new(), wx_open_meteo_new(), wx_metno_new()) and the geocoder
 * (wx_open_meteo_geocoder_new()) and registers them: adding a data source to
 * the application is one implementation of WxProvider in its own directory
 * plus one line in the function that builds the default registry. A caller
 * that passes its own registry to wx_app_new_with_registry() replaces that
 * whole set.
 *
 * Threading: the application's own state is main-thread only. Worker threads
 * exist for file I/O only: a GTask worker reads the three files once at
 * start-up (until it has finished, see "Start-up", nothing else touches the
 * places, the settings and the cache), and every later save runs on a worker
 * thread as well: wx_places_save_async() / wx_settings_save_async() /
 * wx_cache_save_async() take a snapshot on the main thread and serialise and
 * write it on a worker (at most one save of each at a time; the completion
 * callback runs on the main thread). The "changed" signals that the start-up
 * load emits on the places and the settings are emitted on that worker
 * thread: the application connects its own handler only after the load has
 * finished, so none of its handlers runs on the worker. The application
 * itself issues no synchronous file or socket operation on the main thread
 * (the toolkit's and GIO's own initialisation is outside this). Every
 * function below must be called from the main thread, the thread that runs
 * the default main context.
 *
 * Start-up
 * --------
 * startup: the CSS is installed (from the compiled-in resource only), the
 * accelerators are registered and the files are loaded on a worker thread
 * (the application holds itself alive meanwhile). activate: the main window
 * is created and presented as soon as the load finished, so its first frame
 * already shows the cached forecasts (with their age, "Updated 3 h ago");
 * no network access precedes it. A file that is missing is normal (first
 * run); a file that cannot be read or parsed is logged with g_warning() and
 * treated as empty. The persisted unit system and the persisted disabled
 * providers are applied to the application and to the registry once the load
 * is done.
 *
 * Refreshing
 * ----------
 * The scheduler (wx-scheduler.h) is fed with the places, the window's
 * visibility and focus, the selection and the network state
 * (GNetworkMonitor); its actions are executed here: a wx_service_refresh_async()
 * request per FETCH with a GCancellable per request, cancelled on the
 * scheduler's CANCEL actions. A successful refresh replaces the forecast of
 * its item, clears the item's error text and stale flag and is stored in the cache; a failed
 * refresh keeps the forecast the item holds (cached or earlier), records the sanitised reason
 * on the item and marks it stale; a cancelled one changes neither. The stale flag of an item is
 * changed only by the outcome of a request of that place (OK clears it, FAILED sets it) or by
 * the removal of the place: starting, replacing or cancelling a refresh (Refresh button,
 * provider switch, hiding the window, losing the network) never clears it. While a request
 * is in flight the item is "loading". The refresh timer is at most one source, armed for the
 * earliest of the scheduler's next wakeup, the time a held-back forced refresh may start and the end
 * of a cool-down (see below); it is absent while none of them exists (window hidden, network
 * unavailable, or no place and nothing pending). Hiding the window or losing the network cancels
 * every request in flight. A place removed while a request is in flight has the late result
 * dropped.
 *
 * "Refresh" (wx_app_refresh_selected()) and a provider switch
 * (wx_app_set_provider_enabled()) have no scheduler input of their own: a forced refresh makes
 * the scheduler forget the place (wx_scheduler_set_places() without it, then with it again), so
 * it is a new place that is fetched at once, regardless of the freshness window. Forced
 * refreshes are rate limited per place: one is never started while the place is loading, nor
 * earlier than WX_APP_REFRESH_MIN_GAP_S seconds after the place's latest request started or
 * succeeded, nor earlier than WX_APP_RATE_LIMIT_COOLDOWN_S seconds after a refresh of the place
 * failed with WX_ERROR_RATE_LIMITED. The Refresh button's request that falls in such a period
 * is dropped; a provider switch marks every place as "to be asked again", however many
 * switches there are, and each place is then asked once, as soon as it is allowed (while the
 * window is visible and the network available; a request that the scheduler starts meanwhile
 * counts, since it uses the new set of sources). So N activations within one period start at
 * most one request per place.
 *
 * A place whose refresh failed with WX_ERROR_RATE_LIMITED is cooling down for
 * WX_APP_RATE_LIMIT_COOLDOWN_S seconds, and nothing the application does asks it again meanwhile:
 * it is kept out of the scheduler's set of places, so the scheduler's own rounds (window shown,
 * window focused, network back, periodic) do not reach it either. When the cool-down has ended
 * and the window is visible and the network available, the place is given back to the scheduler
 * (by the refresh timer, or by the next change of visibility or network state if it ended
 * meanwhile), which fetches it once, at once. All other places follow the scheduler's freshness
 * rules. Only a rate limit of a server counts: a provider's own refusal to send a request (the
 * 10-minute floor of MET Norway, the cap on requests in flight) is reported by the service as
 * another error (wx-service.h) and starts no cool-down, so such a place is asked again by the
 * scheduler's next round like after any other failure.
 *
 * Clock
 * -----
 * Everything time-dependent that the window shows (the rain hint, the "now"
 * conditions, "Updated N min ago") is derived from the "now" of the items.
 * While the window is visible AND the network is available one timer ticks every
 * WX_APP_CLOCK_TICK_S seconds and gives every item the current time; it does no I/O and
 * requests nothing. It is removed when the window is hidden or the network is lost (and at
 * shutdown), so a hidden or offline application arms no timer except a pending save. Every
 * change of visibility or of the network state gives the items the current time once, so
 * what is shown while the clock is not ticking is the state at the last transition.
 *
 * Persistence
 * -----------
 * Edits of the places (by the picker or the row actions), of the settings
 * (units, disabled providers, selection) and cache updates are saved
 * asynchronously at most once per WX_APP_SAVE_DELAY_MS (a one-shot timer armed
 * by the first change). At shutdown everything dirty is saved and the
 * application waits (running a nested main loop, at most
 * WX_APP_SHUTDOWN_WAIT_MS) for the saves and the cancelled requests to finish
 * before it returns from "shutdown". Requests and saves that have not
 * finished by then (a hung network or disk) are abandoned: they hold no
 * reference to the application, so it is finalized normally, and their late
 * completion only frees them.
 *
 * Disposal
 * --------
 * When the application is disposed (its last reference is dropped, or g_object_run_dispose(),
 * which also clears the weak references of the pending operations while the object lives on),
 * it is neutralised at once: it counts as shutting down (the functions below that change state
 * or start work, i.e. every one except the getters, then do nothing),
 * all its timers and handlers are removed, the scheduler is stopped and every request in flight
 * is cancelled and removed from the request table. A request that completes afterwards only
 * frees itself. The items and the other state stay valid until the object is finalized, so a
 * window that outlives the disposal can still read them.
 *
 * Items
 * -----
 * wx_app_get_items() is a GListModel of WxRowItem in places order. It follows
 * the places: whatever changes them (picker, row actions) is applied to the
 * model with a single items-changed emission that keeps the items of
 * unchanged places (and with them the list view's selection) alive. A new
 * item is painted from the cache; the forecast of a removed place leaves the
 * cache.
 */
#ifndef WX_APP_H
#define WX_APP_H

#include <gtk/gtk.h>

#include "wx-places.h"
#include "wx-registry.h"
#include "wx-service.h"
#include "wx-types.h"

G_BEGIN_DECLS

#define WX_APP_ID "io.github.wtp128pro.Weather"
/** A save is started this long after the first unsaved change (debounce). */
#define WX_APP_SAVE_DELAY_MS 3000
/** Upper bound of the wait for pending saves and cancelled requests at exit. */
#define WX_APP_SHUTDOWN_WAIT_MS 5000
/** Period of the display clock while the window is visible and online, in seconds. */
#define WX_APP_CLOCK_TICK_S 60
/** A forced refresh of a place is not started earlier than this after its latest request
 *  started or succeeded, in seconds. */
#define WX_APP_REFRESH_MIN_GAP_S 10
/** A forced refresh of a place is not started earlier than this after a refresh of it failed
 *  with WX_ERROR_RATE_LIMITED, in seconds. */
#define WX_APP_RATE_LIMIT_COOLDOWN_S 60

/*
 * G_DECLARE_FINAL_TYPE() declares: the WxApp typedef (instance struct _WxApp, defined in
 * wx-app.c), the WxAppClass typedef, GType wx_app_get_type(void), the static inline cast WX_APP()
 * and check WX_IS_APP(), and g_autoptr() support for WxApp and WxAppClass. WX_TYPE_APP below is
 * hand-written. wx_app_get_type() is thread-safe (GType registration is serialised).
 */
#define WX_TYPE_APP (wx_app_get_type())
G_DECLARE_FINAL_TYPE(WxApp, wx_app, WX, APP, GtkApplication)

/**
 * WxApp:offline:
 *
 * (readable, notify) TRUE while the network monitor reports no network.
 */

/**
 * WxApp:units:
 *
 * (readable, notify) The unit system, a WxUnits value (an int property).
 */

/**
 * wx_app_new:
 *
 * Creates the application object with the production data sources (the registry
 * that wx-app.c builds: National Weather Service, Open-Meteo and MET Norway, with
 * the Open-Meteo place search); nothing starts until g_application_run().
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the object has its registry, service, places, settings, cache, item model and
 *    scheduler (all empty, nothing read from disk, no request made); no timer exists.
 * Thread affinity: main thread.
 * Ownership: the caller owns the returned reference.
 *
 * Returns: (transfer full): the application (id WX_APP_ID, default flags). Run it
 *   with g_application_run().
 */
WxApp *wx_app_new(void);

/**
 * wx_app_new_with_registry:
 * @registry: (not nullable): the data sources (and the geocoder) to use instead of
 *   the production set.
 *
 * Like wx_app_new() over a registry of the caller's.
 *
 * Preconditions:
 *  - @registry satisfies WX_IS_REGISTRY() (otherwise critical, NULL returned).
 * Postconditions:
 *  - the application holds its own reference on @registry and builds its service on it;
 *    no provider is added or removed; otherwise as wx_app_new().
 * Thread affinity: main thread.
 * Ownership: @registry is shared (the application takes its own reference); the caller
 *   owns the returned reference.
 *
 * Returns: (transfer full) (nullable): the application.
 */
WxApp *wx_app_new_with_registry(WxRegistry *registry);

/**
 * wx_app_get_items:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The model of the places' items.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the model is owned by @self; no reference is added.
 *
 * Returns: (transfer none): the GListModel of WxRowItem, empty until the start-up load has
 *   finished.
 */
GListModel *wx_app_get_items(WxApp *self);

/**
 * wx_app_get_places:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The saved places.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, NULL returned).
 *  - the caller does not use the list before the start-up load has finished (the load runs
 *    on a worker thread that owns the list until then; the windows, the only callers, are
 *    created after it).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the list is owned by @self; no reference is added.
 *
 * Returns: (transfer none): the saved places. Edit it only with its own API from the main
 *   thread; the application reacts to "changed".
 */
WxPlaces *wx_app_get_places(WxApp *self);

/**
 * wx_app_get_registry:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The registry of data sources.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the registry is owned by @self; no reference is added.
 *
 * Returns: (transfer none): the registry of data sources.
 */
WxRegistry *wx_app_get_registry(WxApp *self);

/**
 * wx_app_get_service:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The forecast and place-search service.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the service is owned by @self; no reference is added.
 *
 * Returns: (transfer none): the forecast and place-search service.
 */
WxService *wx_app_get_service(WxApp *self);

/**
 * wx_app_get_offline:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * Whether the network is unavailable.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, FALSE returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none (no pointers).
 *
 * Returns: TRUE while the network is unavailable (property "offline").
 */
gboolean wx_app_get_offline(WxApp *self);

/**
 * wx_app_get_units:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The unit system.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, WX_UNITS_IMPERIAL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: none.
 *
 * Returns: the unit system (property "units"); imperial until the settings are loaded and
 *   whenever they say so.
 */
WxUnits wx_app_get_units(WxApp *self);

/**
 * wx_app_set_units:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 * @units: WX_UNITS_IMPERIAL or WX_UNITS_METRIC.
 *
 * Switches the unit system: every item is given the new units (the window follows the
 * items), the choice is stored in the settings and saved (debounced).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() and @units is a WxUnits member (otherwise critical,
 *    nothing happens); the start-up load has finished (the window, the only caller, exists
 *    only then).
 * Postconditions:
 *  - when the value differs: "units" was notified, every item holds @units, the settings
 *    hold @units and a save is scheduled; otherwise nothing happens. Nothing happens once
 *    the application is shutting down.
 * Thread affinity: main thread.
 * Ownership: none.
 */
void wx_app_set_units(WxApp *self, WxUnits units);

/**
 * wx_app_set_window_visible:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 * @visible: whether the main window is mapped and not minimised or suspended.
 *
 * Tells the scheduler; becoming visible triggers the refresh described in wx-scheduler.h (not
 * for a place that is cooling down after a rate limit: see "Refreshing")
 * and starts the display clock (while online), becoming invisible cancels the requests in
 * flight and stops the clock. A change gives the items the current time once.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, nothing happens).
 * Postconditions:
 *  - nothing happens once the application is shutting down; otherwise the scheduler has been
 *    told and the actions it produced have been executed (requests started or cancelled, the
 *    refresh timer re-armed); the display clock timer exists iff @visible and the network is
 *    available; forced refreshes that were waiting are served when they are allowed, and the
 *    places whose cool-down after a rate limit has ended are given back to the scheduler.
 * Thread affinity: main thread.
 * Ownership: none (no pointers besides @self).
 */
void wx_app_set_window_visible(WxApp *self, gboolean visible);

/**
 * wx_app_window_focused:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The main window became the active window (focus regained).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, nothing happens).
 * Postconditions:
 *  - nothing happens once the application is shutting down; otherwise the scheduler has been
 *    told (it starts an event round only while the window is visible and the network is
 *    available, and a place that is cooling down after a rate limit is not part of it: see
 *    "Refreshing") and its actions executed.
 * Thread affinity: main thread.
 * Ownership: none (no pointers besides @self).
 */
void wx_app_window_focused(WxApp *self);

/**
 * wx_app_get_selected:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The key of the place the detail pane shows.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, NULL returned).
 * Postconditions:
 *  - no state is changed.
 * Thread affinity: main thread.
 * Ownership: the string is owned by @self, valid until the next wx_app_select() or change of
 *   the places.
 *
 * Returns: (transfer none) (nullable): the key of the selected place (the key of an item of
 *   wx_app_get_items()), NULL for none. After the start-up load it is the persisted selection
 *   when that place still exists.
 */
const char *wx_app_get_selected(WxApp *self);

/**
 * wx_app_select:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 * @key: (nullable): the key of an item of wx_app_get_items() (as returned by
 *   wx_row_item_get_key()), or NULL for no selection. An unknown or invalid key counts as
 *   none.
 *
 * Declares which place the detail pane shows: the scheduler fetches it first, and the choice
 * is stored in the settings and saved (debounced). Does nothing once the application is
 * shutting down.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, nothing happens); @key is NULL or
 *    NUL-terminated.
 * Postconditions:
 *  - the application remembers the item's own key (a copy) as the selection, or none when @key
 *    matches no item; @key is not retained.
 * Thread affinity: main thread.
 * Ownership: @key is borrowed for the call only.
 */
void wx_app_select(WxApp *self, const char *key);

/**
 * wx_app_refresh_selected:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 *
 * The "Refresh" button: fetches the selected place again now, whatever its age, unless it is
 * loading or was started or succeeded less than WX_APP_REFRESH_MIN_GAP_S seconds ago or hit a
 * rate limit less than WX_APP_RATE_LIMIT_COOLDOWN_S seconds ago (see "Refreshing" in the file
 * comment): then the call is dropped.
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() (else: critical, nothing happens).
 * Postconditions:
 *  - nothing happens while shutting down, with no selected place, while the window is not
 *    visible, while the network is unavailable, or in the cases above; otherwise the scheduler
 *    has been told and its actions executed, so the place is loading.
 * Thread affinity: main thread.
 * Ownership: none.
 */
void wx_app_refresh_selected(WxApp *self);

/**
 * wx_app_set_provider_enabled:
 * @self: (not nullable): the application; must satisfy WX_IS_APP().
 * @id: (not nullable): a provider id of the registry.
 * @enabled: whether the provider takes part in refreshes.
 *
 * The switch of the sources page: enables or disables the provider in the registry, stores
 * the choice in the settings (saved, debounced) and asks every place again, so the forecasts
 * reflect the new set of sources (each place once, as soon as it is allowed: see "Refreshing"
 * in the file comment).
 *
 * Preconditions:
 *  - @self satisfies WX_IS_APP() and @id is non-NULL and NUL-terminated (otherwise critical,
 *    nothing happens). An id that no registered provider has is ignored.
 * Postconditions:
 *  - when the provider's flag differs: the registry, the settings and the saving schedule
 *    were updated and every place is marked to be asked again; the places that are allowed
 *    now are fetched at once while the window is visible and the network available, the others
 *    when they are allowed or when the window is visible and the network available again;
 *    otherwise nothing happens. Nothing happens once the application is shutting down.
 * Thread affinity: main thread.
 * Ownership: @id is borrowed for the call only.
 */
void wx_app_set_provider_enabled(WxApp *self, const char *id, gboolean enabled);

G_END_DECLS

#endif /* WX_APP_H */
