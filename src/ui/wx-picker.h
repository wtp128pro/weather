/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Copyright (C) 2026 wtp128pro */
/*
 * wx-picker.h - WxPicker: the "Add a city" window. The user types the name of
 * a city, the picker searches it online (through the WxService's geocoder)
 * and adds the chosen place to the user's places list.
 *
 * Layout (top to bottom): a text entry, an inline status line and the list of
 * results.
 *
 *  - Entry: a plain GtkEntry (named "wx-picker-search-entry", placeholder and
 *    accessible label "Search for a city") that accepts at most
 *    WX_PICKER_MAX_QUERY_CHARS characters AND at most WX_PICKER_MAX_QUERY_BYTES bytes of
 *    UTF-8 (an insertion that would exceed the byte limit is cut at a character boundary: the
 *    geocoder counts bytes, so the entry never holds a query it would refuse as too long);
 *    "activates-default" is off. It has
 *    the keyboard focus when the picker is created, so a window that is
 *    presented lets the user type at once.
 *  - Status line: a GtkLabel named "wx-picker-status", hidden while its text
 *    is empty. Its CSS class is "error" for errors (a failed search, a refused
 *    add) and "dim-label" for everything else.
 *  - Results: a GtkListView (named "wx-picker-results") inside a scrolled window, over a
 *    GListStore, without selection. Each row shows ONE label named "wx-picker-label" whose
 *    text is exactly wx_place_label() of the place, and a dim label named "wx-picker-added"
 *    with the text "Added" that is visible exactly while the place is in the places list
 *    (wx_places_index_of() of the place's key is not negative). The marker follows the
 *    places list: a change made elsewhere (its "changed" signal) is reflected in the rows at
 *    once. Each row is a focusable list item with the accessible label wx_place_label()
 *    (the same text as "wx-picker-label") and, while the place is in the places list, the
 *    accessible description "Added". The full label is also the tooltip of the label widget
 *    (long names are ellipsised).
 *
 * What the entry does:
 *  - The text of the entry is turned into the query that is searched: the characters the
 *    geocoder refuses (the forbidden characters of wx_sanitize_text(): control characters, line
 *    and paragraph separators and the bidirectional formatting marks, U+200E and U+200F among
 *    them, which text pasted from right-to-left pages often carries) are removed from it, then
 *    the surrounding ASCII whitespace (g_strstrip()). The entry itself keeps what the user typed.
 *  - A query that is empty: no request; the pending timer and the in-flight search are
 *    cancelled and the results list shows the suggestions
 *    (wx_suggested_places_new()) under the status text "Suggestions". A
 *    freshly created picker is in this state.
 *  - A query of fewer than WX_PICKER_MIN_QUERY_BYTES bytes (bytes, not characters), or one made
 *    of white space only that is not ASCII (no-break spaces, for example), which the geocoder
 *    refuses as well: no request; the timer and the in-flight search
 *    are cancelled, the results are cleared and the status text is "Type at
 *    least 2 letters". The picker thus never starts a search that the geocoder
 *    would refuse for its text.
 *  - Otherwise the search is debounced by WX_PICKER_SEARCH_DELAY_MS: every
 *    edit cancels the in-flight search and restarts the timer; when it fires
 *    the query is passed to wx_service_search_async() with a fresh
 *    GCancellable, the status text is "Searching\u2026" (U+2026) and the
 *    previous results stay until the answer arrives. Pressing Enter in the
 *    entry starts the search at once (the timer is cancelled), except that the
 *    key is ignored while the query is the one of the latest search and that
 *    search is still in flight or was answered, with results or with an error,
 *    less than WX_PICKER_SEARCH_DELAY_MS ago: a held-down Enter (key
 *    auto-repeat) thus never replaces a search that is running and starts at
 *    most one search per WX_PICKER_SEARCH_DELAY_MS, instead of one per key
 *    event. Every edit forgets the latest search (so Enter after an edit
 *    always searches), and so does a cancellation. After that delay Enter
 *    repeats the search, which is how a failed search is retried (a retry
 *    within the delay of the failure is ignored, like any other repeat).
 *    Enter in an entry whose query is empty or not searchable does nothing.
 *    At most one search is in flight. A completion is applied only if it
 *    belongs to the latest request, even when the geocoder ignored the
 *    cancellation.
 *  - Success: the places are listed in the service's order (WxService returns
 *    at most WX_GEOCODER_MAX_HITS of them, and so does the list); no place
 *    shows the status text "No results" (not an error), otherwise the status
 *    line is hidden. Failure: the results are cleared and the status text is
 *    "Search failed: <message>" with the CSS class "error"; the message is
 *    made safe with wx_sanitize_text() (control and bidi characters removed,
 *    invalid UTF-8 replaced, cut to WX_PICKER_MAX_MESSAGE_BYTES). A cancelled
 *    completion of the latest request is silent: the status line is hidden
 *    and no error is shown.
 *
 * Adding: activating a row (the list's "activate" signal, which the GTK list view emits
 * for Enter or Space on the focused row and for a double click) calls wx_places_add() with
 * the place of the row.
 *  - On success the picker emits "place-added" and closes itself with
 *    gtk_window_close().
 *  - When wx_places_add() refuses, the picker stays open, nothing is emitted
 *    and the status line (class "error") shows the reason: "You can save up to
 *    50 places" if the places list already holds WX_PLACE_MAX places (checked
 *    first); otherwise "Already in your places" when the key of the place is
 *    in the list or a place of the list lies closer than
 *    WX_PLACES_DUPLICATE_KM (wx_geo_distance_km()); otherwise "Could not add
 *    this place". The reason is worked out from the places list after the
 *    refusal, never from an error.
 *  - The picker never saves anything: persistence is the owner's job, which
 *    learns about the edit from "place-added" (and from the list's own
 *    "changed"). The picker never changes the places list from inside a
 *    "changed" handler of that list.
 *
 * Keyboard: everything is reachable without a mouse. Tab goes from the entry
 * to the results list (one stop for the whole list) and on; the arrow keys
 * move between the rows; Enter or Space on a row adds it; Escape closes the
 * window from any widget of it (a capture-phase key controller).
 *
 * Closing: Escape, the window's close button and gtk_window_close() emit
 * "close-request". Closing as such cancels nothing, because it does not mean
 * the window goes away: a handler may veto it, and gtk_window_set_hide_on_close()
 * only hides the window. The debounce timer and the in-flight search keep
 * running then. They are cancelled (the status text "Searching\u2026" is
 * removed) when the picker is destroyed, which is when GTK removes it from the
 * list of toplevel windows (gtk_window_destroy(), which the default close
 * handler calls, or the destruction of the transient parent with
 * destroy-with-parent), even if the owner still holds a reference of its
 * own, and at dispose. A destroyed picker issues no search, adds nothing and
 * emits nothing; an owner that keeps a reference to it must not reuse it. Late
 * completions of the service are dropped without touching the picker.
 *
 * Window: title "Add a city", default size 460x520, CSS class "wx-picker"
 * (node name "window"). It is not modal; transient-for, modal and
 * destroy-with-parent are the caller's choice.
 *
 * Threading: main thread only. Nothing blocks: the search is asynchronous, the
 * places calls are in-memory, there is no file or network I/O, and the only
 * timer is the debounce timer (g_timeout_add() on the default main context).
 *
 * CSS: the window has the class "wx-picker"; the status line uses the stock
 * classes "error" and "dim-label", and the "Added" marker "dim-label". The
 * named widgets are "wx-picker-search-entry", "wx-picker-status",
 * "wx-picker-results", "wx-picker-label" and "wx-picker-added"; the last two also carry
 * their name as CSS class (the style sheet's rules are for those classes).
 */
#ifndef WX_PICKER_H
#define WX_PICKER_H

#include <gtk/gtk.h>

#include "wx-places.h"
#include "wx-service.h"
#include "wx-types.h"

G_BEGIN_DECLS

/** Quiet time after the last edit of the entry before a search starts, in milliseconds. It is also
 *  how long after the answer of a search Enter does not repeat that search (see the file comment). */
#define WX_PICKER_SEARCH_DELAY_MS 300
/** Maximum number of characters of the entry. */
#define WX_PICKER_MAX_QUERY_CHARS 64
/** Maximum number of bytes (UTF-8) of the entry: the longest query the place search accepts. */
#define WX_PICKER_MAX_QUERY_BYTES 64
/** A query shorter than this (in bytes, after removing the forbidden characters and the
 *  surrounding ASCII whitespace) starts no search. */
#define WX_PICKER_MIN_QUERY_BYTES 2
/** Maximum byte length of the error text of a failed search shown inline. */
#define WX_PICKER_MAX_MESSAGE_BYTES 200

#define WX_TYPE_PICKER (wx_picker_get_type())
G_DECLARE_FINAL_TYPE(WxPicker, wx_picker, WX, PICKER, GtkWindow)

/**
 * WxPicker::place-added:
 * @self: the picker.
 * @key: the key (wx_place_key()) of the place that was added; valid only for
 *   the duration of the emission.
 *
 * Emitted synchronously, once per place that the picker itself added to the
 * places list (before it closes itself). It is NOT emitted for a refused add,
 * for changes made by anyone else, or once the picker is destroyed (a handler
 * of the places list's own "changed" signal that destroys the picker during the
 * add suppresses it; the add stands). Handlers may read the places list and
 * may close or destroy the picker; they MUST NOT change the places list
 * re-entrantly. The picker does not save the places list; a handler typically
 * schedules wx_places_save_async().
 */

/**
 * wx_picker_new:
 * @places: (not nullable): the user's places list. A reference is taken and
 *   released at dispose. Main thread only; the picker edits it through
 *   wx_places_add() and reads it through the other accessors.
 * @service: (not nullable): the service whose geocoder searches the cities. A
 *   reference is taken and released at dispose; only wx_service_search_async()
 *   and wx_service_search_finish() are used.
 *
 * Creates the picker window (not shown; call gtk_window_present(), and
 * gtk_window_set_transient_for() if wanted). Like gtk_window_new() the window
 * is owned by GTK's list of toplevels until gtk_window_destroy(); the caller
 * does not own a reference and must not unref it. Needs an initialised GTK
 * with a display. Must be called from the main thread.
 *
 * Preconditions:
 *  - GTK is initialised with a display; the call is made on the main thread.
 *  - @places satisfies WX_IS_PLACES() and @service satisfies WX_IS_SERVICE().
 * Postconditions:
 *  - on success the picker holds one reference each on @places and @service,
 *    is connected to the places list's "changed" signal (disconnected at
 *    dispose), shows the suggestions with the status text "Suggestions" and no
 *    search is pending.
 *  - on failure (a NULL or wrongly typed argument) a critical is logged,
 *    nothing is allocated and NULL is returned.
 * Thread affinity: main thread only.
 * Ownership: @places and @service are shared (the picker takes its own
 *   reference, the caller keeps its own); the returned window is owned by
 *   GTK's list of toplevels, not by the caller.
 *
 * Returns: (transfer none): the new window, or NULL (with a critical) if an
 *   argument is NULL or of the wrong type.
 */
GtkWidget *wx_picker_new(WxPlaces *places, WxService *service);

/**
 * wx_suggested_places_new:
 *
 * Builds the first-run suggestions: five well-known places of Florida, for the
 * picker's initial list and for the main window's empty state.
 *
 * Preconditions:
 *  - none.
 * Postconditions:
 *  - the array holds exactly these places in this order, all of them in
 *    Florida, United States (country code "US", time zone "America/New_York"),
 *    each built with wx_place_new(): Miami (25.7743, -80.1937), Orlando
 *    (28.5383, -81.3792), Tampa (27.9475, -82.4584), Jacksonville (30.3322,
 *    -81.6557) and Key West (24.5551, -81.7800).
 *  - no state is changed; every call returns a new, independent array.
 * Thread affinity: any thread (pure).
 * Ownership: the caller owns the returned array and its places.
 *
 * Returns: (transfer container) (element-type WxPlace): a new array whose free
 *   function is wx_place_free(); release with g_ptr_array_unref(). Never NULL.
 */
GPtrArray *wx_suggested_places_new(void);

G_END_DECLS

#endif /* WX_PICKER_H */
